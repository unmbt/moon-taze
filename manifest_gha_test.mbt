///|
test "github actions path matcher recognizes workflows and composite actions" {
  assert_true(@moon-taze.is_github_actions_path(".github/workflows/ci.yml"))
  assert_true(
    @moon-taze.is_github_actions_path("repo/.github/workflows/release.yaml"),
  )
  assert_true(
    @moon-taze.is_github_actions_path(".github/actions/setup/action.yml"),
  )
  assert_true(@moon-taze.is_github_actions_path("action.yaml"))
  assert_false(
    @moon-taze.is_github_actions_path(".github/workflows/sub/ci.yml"),
  )
  assert_false(@moon-taze.is_github_actions_path("moon.mod"))
}

///|
test "parse_uses handles tags, subpaths, sha pins, and ignores non-version refs" {
  let tag = @moon-taze.parse_uses("actions/checkout@v4").unwrap()
  assert_eq(tag.repo, "actions/checkout")
  assert_eq(tag.subpath, "")
  assert_eq(tag.tag, "v4")
  assert_eq(tag.style, Tag)

  let sub = @moon-taze.parse_uses("github/codeql-action/init@v3.26.0").unwrap()
  assert_eq(sub.repo, "github/codeql-action")
  assert_eq(sub.subpath, "/init")
  assert_eq(sub.tag, "v3.26.0")

  let sha = "a5ac7e51b41094c92402da3b24376905380afc29"
  let pinned = @moon-taze.parse_uses(
    "actions/checkout@\{sha}",
    comment=Some("# v4.1.6"),
  ).unwrap()
  assert_eq(pinned.style, Sha)
  assert_eq(pinned.tag, "v4.1.6")
  assert_eq(pinned.sha, Some(sha))

  assert_true(@moon-taze.parse_uses("actions/checkout@\{sha}") is None)
  assert_true(@moon-taze.parse_uses("./.github/actions/local") is None)
  assert_true(@moon-taze.parse_uses("docker://alpine:3.19") is None)
  assert_true(@moon-taze.parse_uses("actions/checkout@main") is None)
}

///|
test "github actions YAML parser extracts uses entries and skips run block scalars" {
  let yaml =
    #|name: CI
    #|jobs:
    #|  build:
    #|    steps:
    #|      - name: Checkout
    #|        uses: actions/checkout@v4
    #|      - uses: 'hustcer/setup-moonbit@v1.0.0'
    #|      - uses: actions/cache/restore@a5ac7e51b41094c92402da3b24376905380afc29 # v4.0.2
    #|      - { name: Flow, uses: "softprops/action-gh-release@v2" }
    #|      - name: Script containing uses
    #|        run: |
    #|          echo "uses: fake/ignored@v9"
    #|          uses: also/ignored@v9
    #|      - uses: ./local-action
    #|      - uses: docker://ubuntu:latest
    #|
  let parsed = @moon-taze.parse_github_actions_manifest(
    @utf8.encode(yaml),
    path=".github/workflows/ci.yml",
  )
  assert_eq(parsed.diagnostics.length(), 0)
  let manifest = parsed.manifest.unwrap()
  assert_eq(manifest.kind, GitHubActions)
  assert_eq(manifest.dependencies.length(), 4)
  assert_eq(manifest.dependencies.map(d => (d.name, d.version)), [
    ("actions/checkout", "v4"),
    ("hustcer/setup-moonbit", "v1.0.0"),
    ("actions/cache", "v4.0.2"),
    ("softprops/action-gh-release", "v2"),
  ])
  assert_eq(manifest.dependencies[2].gha.unwrap().subpath, "/restore")
  assert_eq(manifest.dependencies[2].gha.unwrap().style, Sha)
}

///|
async test "github actions lossless apply updates tags, sha pins, and preserves formatting" {
  let root = @fs.tmpdir(prefix="moon-taze-gha-apply")
  defer @fs.remove(root, recursive=true)
  let dir = root + "/.github/workflows"
  @fs.mkdir(dir, recursive=true)
  let path = dir + "/ci.yml"
  let old_sha = "1111111111111111111111111111111111111111"
  let new_sha = "2222222222222222222222222222222222222222"
  let checkout_sha = "3333333333333333333333333333333333333333"
  let source = @utf8.encode(
    "\uFEFF# keep comment\r\njobs:\r\n  a:\r\n    steps:\r\n      - uses: actions/checkout@v4\r\n      - uses: 'actions/cache/restore@\{old_sha}' # v4.0.0\r\n  b:\r\n    steps:\r\n      - uses: actions/checkout@v4\r\n",
  )
  @fs.write_binary(path, source)
  let manifest = @moon-taze.parse_github_actions_manifest(source, path~).manifest.unwrap()
  let plan = @moon-taze.check(
    manifest,
    options=@moon-taze.CheckOptions(mode=Major, cwd=root),
    fetch_gha=repo => {
      if repo == "actions/checkout" {
        @moon-taze.ModuleMetadata(repo, Some("v5"), [
          @moon-taze.VersionMetadata("v4", false, None, None, sha=Some(old_sha)),
          @moon-taze.VersionMetadata(
            "v5",
            false,
            None,
            None,
            sha=Some(checkout_sha),
          ),
        ])
      } else {
        @moon-taze.ModuleMetadata(repo, Some("v4.2.0"), [
          @moon-taze.VersionMetadata(
            "v4.0.0",
            false,
            None,
            None,
            sha=Some(old_sha),
          ),
          @moon-taze.VersionMetadata(
            "v4.2.0",
            false,
            None,
            None,
            sha=Some(new_sha),
          ),
        ])
      }
    },
  )
  assert_false(plan.has_errors())
  let report = @moon-taze.apply(plan, plan.recommended_selection())
  assert_eq(report.exit_code(), 0)
  assert_eq(report.written_files(), 1)
  let updated = @utf8.decode_lossy(@fs.read_binary(path))
  assert_eq(
    updated,
    "\uFEFF# keep comment\r\njobs:\r\n  a:\r\n    steps:\r\n      - uses: actions/checkout@v5\r\n      - uses: 'actions/cache/restore@\{new_sha}' # v4.2.0\r\n  b:\r\n    steps:\r\n      - uses: actions/checkout@v5\r\n",
  )
}

///|
async test "github actions sha style pins up-to-date tag references" {
  let root = @fs.tmpdir(prefix="moon-taze-gha-pin")
  defer @fs.remove(root, recursive=true)
  let path = root + "/action.yml"
  let sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  let source = @utf8.encode(
    "runs:\n  steps:\n    - uses: actions/checkout@v4\n",
  )
  @fs.write_binary(path, source)
  let manifest = @moon-taze.parse_github_actions_manifest(source, path~).manifest.unwrap()
  let plan = @moon-taze.check(
    manifest,
    options=@moon-taze.CheckOptions(mode=Default, gha_style=Sha, cwd=root),
    fetch_gha=repo => {
      @moon-taze.ModuleMetadata(repo, Some("v4"), [
        @moon-taze.VersionMetadata("v4", false, None, None, sha=Some(sha)),
      ])
    },
  )
  assert_eq(plan.changes()[0].status, UpdateAvailable)
  assert_eq(plan.changes()[0].diff, Some(Pin))
  let report = @moon-taze.apply(plan, plan.recommended_selection())
  assert_eq(report.exit_code(), 0)
  assert_eq(
    @fs.read_text(path),
    "runs:\n  steps:\n    - uses: actions/checkout@\{sha} # v4\n",
  )
}
