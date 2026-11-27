///|
async fn fixture_plan(path : String, source : Bytes) -> @moon-taze.CheckPlan {
  let parsed = @moon-taze.parse_manifest(source, path~, module_name="demo/app")
  @moon-taze.check(
    parsed.manifest.unwrap(),
    options=@moon-taze.CheckOptions(mode=Major),
    fetch=name => {
      @moon-taze.ModuleMetadata(name, Some("12.3.456"), [
        @moon-taze.VersionMetadata("12.3.456", false, None, None),
      ])
    },
  )
}

///|
async test "native write preserves bytes and repeated check preserves mtime" {
  let root = @fs.tmpdir(prefix="moon-taze-apply")
  defer @fs.remove(root, recursive=true)
  let path = root + "/moon.mod"
  let source = @utf8.encode(
    "\uFEFF// 中文 😀\r\nname = \"demo/app\"\r\nimport {\r\n  \"demo/a@1.0.0\", // keep comment\r\n  \"demo/b@0.1.2\",\r\n}\r\ndescription = \"demo/a@1.0.0\"",
  )
  @fs.write_binary(path, source)
  let plan = fixture_plan(path, source)
  assert_false(plan.has_errors())
  let report = @moon-taze.apply(plan, plan.recommended_selection())
  assert_eq(
    report.exit_code(),
    0,
    msg=report.diagnostics().map(d => d.message).join("; "),
  )
  assert_eq(report.status(), Succeeded)
  assert_eq(report.written_files(), 1)
  assert_eq(report.files()[0].changed_dependencies(), 2)
  let expected = @utf8.encode(
    "\uFEFF// 中文 😀\r\nname = \"demo/app\"\r\nimport {\r\n  \"demo/a@12.3.456\", // keep comment\r\n  \"demo/b@12.3.456\",\r\n}\r\ndescription = \"demo/a@1.0.0\"",
  )
  assert_eq(@fs.read_binary(path), expected)
  let modified = @fs.mtime(path)
  let again = fixture_plan(path, expected)
  let noop = @moon-taze.apply(again, again.recommended_selection())
  assert_eq(noop.written_files(), 0)
  assert_eq(noop.exit_code(), 0)
  assert_eq(@fs.mtime(path), modified)
  assert_eq(@fs.readdir(root, include_hidden=true).length(), 1)
}

///|
async test "snapshot conflict and lock conflict preserve user bytes" {
  let root = @fs.tmpdir(prefix="moon-taze-conflict")
  defer @fs.remove(root, recursive=true)
  let path = root + "/moon.mod"
  let source = b"name = \"demo/app\"\nimport {\"demo/a@1.0.0\"}\n"
  @fs.write_binary(path, source)
  let plan = fixture_plan(path, source)
  let edited = b"// edited\nname = \"demo/app\"\nimport {\"demo/a@1.0.0\"}\n"
  @fs.write_binary(path, edited)
  let stale = @moon-taze.apply(plan, plan.recommended_selection())
  assert_eq(stale.exit_code(), 2)
  assert_eq(stale.diagnostics()[0].code, "stale_plan")
  assert_eq(@fs.read_binary(path), edited)
  assert_false(@fs.exists(path + ".moon-taze.lock"))

  @fs.write_binary(path, source)
  @fs.write_binary(path + ".moon-taze.lock", b"another owner")
  let locked = @moon-taze.apply(plan, plan.recommended_selection())
  assert_eq(locked.diagnostics()[0].code, "write_conflict")
  assert_eq(@fs.read_binary(path + ".moon-taze.lock"), b"another owner")
  assert_eq(@fs.read_binary(path), source)

  @fs.remove(path + ".moon-taze.lock")
  @fs.remove(path)
  let deleted = @moon-taze.apply(plan, plan.recommended_selection())
  assert_eq(deleted.diagnostics()[0].code, "stale_plan")
  assert_eq(deleted.written_files(), 0)
  assert_eq(@fs.readdir(root, include_hidden=true).length(), 0)
}

///|
async test "plans are detached and selections cannot cross plan boundaries" {
  let root = @fs.tmpdir(prefix="moon-taze-selection")
  defer @fs.remove(root, recursive=true)
  let path = root + "/moon.mod"
  let source = b"import {\"demo/a@1.0.0\", \"demo/b@1.0.0\"}"
  @fs.write_binary(path, source)
  let plan = fixture_plan(path, source)
  let other = fixture_plan(path, source)
  let exposed = plan.changes()
  exposed[0].candidates.clear()
  exposed[0].diagnostics.clear()
  exposed.clear()
  plan.diagnostics().clear()
  assert_eq(plan.changes().length(), 2)
  assert_eq(plan.changes()[0].candidates.length(), 1)

  let bad_selections = [
    other.recommended_selection(),
    plan.selection([(path, "demo/a", "99.0.0")]),
    plan.selection([(path, "demo/a", "1.0.0")]),
    plan.selection([(path + ".other", "demo/a", "12.3.456")]),
    plan.selection([(path, "demo/a", "12.3.456"), (path, "demo/a", "12.3.456")]),
  ]
  for selection in bad_selections {
    let report = @moon-taze.apply(plan, selection)
    assert_eq(report.diagnostics()[0].code, "invalid_selection")
    assert_eq(report.written_files(), 0)
    assert_eq(@fs.read_binary(path), source)
  }
  let selected = @moon-taze.apply(
    plan,
    plan.selection([(path, "demo/b", "12.3.456")]),
  )
  assert_eq(selected.exit_code(), 0)
  assert_eq(
    @fs.read_binary(path),
    b"import {\"demo/a@1.0.0\", \"demo/b@12.3.456\"}",
  )
}

///|
async test "parse errors survive check and callbacks control apply lifecycle" {
  let dup_source = b"import {\"demo/a@1.0.0\", \"demo/a@1.0.0\"}"
  let parsed = @moon-taze.parse_manifest(
    dup_source,
    path="unused/moon.mod",
    module_name="demo/app",
  )
  let calls = Ref(0)
  let bad_plan = @moon-taze.check(
    parsed.manifest.unwrap(),
    options=@moon-taze.CheckOptions(mode=Patch),
    fetch=name => {
      calls.val += 1
      @moon-taze.ModuleMetadata(name, None, [])
    },
  )
  assert_true(bad_plan.has_errors())
  assert_eq(calls.val, 0)
  assert_eq(bad_plan.diagnostics()[0].code, "duplicate_dependency")
  let rejected = @moon-taze.apply(bad_plan, bad_plan.selection([]))
  assert_eq(rejected.exit_code(), 2)
  assert_eq(rejected.diagnostics()[0].code, "check_failed")

  let root = @fs.tmpdir(prefix="moon-taze-callbacks")
  defer @fs.remove(root, recursive=true)
  let path = root + "/moon.mod"
  let source = b"import {\"demo/lib@1.0.0\"}"
  @fs.write_binary(path, source)
  let manifest = @moon-taze.parse_manifest(
    source,
    path~,
    module_name="demo/app",
  ).manifest.unwrap()
  let plan = @moon-taze.check(manifest, fetch=name => {
    @moon-taze.ModuleMetadata(name, Some("1.1.0"), [
      @moon-taze.VersionMetadata("1.0.0", false, None, None),
      @moon-taze.VersionMetadata("1.1.0", false, None, None),
    ])
  })
  let denied = @moon-taze.apply(
    plan,
    plan.recommended_selection(),
    callbacks=Some(
      @moon-taze.Callbacks(before_apply=Some(_ => "consumer denied apply")),
    ),
  )
  assert_eq(denied.exit_code(), 2)
  assert_eq(denied.diagnostics()[0].code, "callback_denied")
  assert_eq(@fs.read_binary(path), source)

  let seen_written = Ref(0)
  let post_fail = @moon-taze.apply(
    plan,
    plan.recommended_selection(),
    callbacks=Some(
      @moon-taze.Callbacks(
        file_applied=Some(_ => "consumer post-write failure"),
        after_run=Some(report => {
          seen_written.val = report.written_files()
          ""
        }),
      ),
    ),
  )
  assert_eq(post_fail.status(), Partial)
  assert_eq(post_fail.written_files(), 1)
  assert_eq(seen_written.val, 1)
  assert_eq(post_fail.diagnostics()[0].code, "callback_failed")
  assert_eq(@fs.read_binary(path), b"import {\"demo/lib@1.1.0\"}")
}

///|
async test "manual selection allows opting into NoCandidate upgrades and uses chosen GHA tag SHA" {
  let root = @fs.tmpdir(prefix="moon-taze-custom-selection")
  defer @fs.remove(root, recursive=true)
  @fs.mkdir(root + "/.github/workflows", recursive=true)
  let mod_path = root + "/moon.mod"
  let ci_path = root + "/.github/workflows/ci.yml"
  @fs.write_binary(
    mod_path, b"name = \"demo/app\"\nimport { \"demo/lib@1.0.0\" }\n",
  )
  @fs.write_binary(
    ci_path, b"jobs:\n  build:\n    steps:\n      - uses: actions/checkout@v4.1.0\n",
  )
  let mod_manifest = @moon-taze.parse_manifest(
    @fs.read_binary(mod_path),
    path=mod_path,
    module_name="demo/app",
  ).manifest.unwrap()
  let gha_manifest = @moon-taze.parse_github_actions_manifest(
    @fs.read_binary(ci_path),
    path=ci_path,
  ).manifest.unwrap()
  let sha_v420 = "4444444444444444444444444444444444444444"
  let sha_v500 = "5555555555555555555555555555555555555555"
  let plan = @moon-taze.check_manifests(
    [mod_manifest, gha_manifest],
    options=@moon-taze.CheckOptions(mode=Default, gha_style=Sha, cwd=root),
    fetch=name => {
      @moon-taze.ModuleMetadata(name, Some("2.0.0"), [
        @moon-taze.VersionMetadata("1.0.0", false, None, None),
        @moon-taze.VersionMetadata("2.0.0", false, None, None),
      ])
    },
    fetch_gha=repo => {
      @moon-taze.ModuleMetadata(repo, Some("v5.0.0"), [
        @moon-taze.VersionMetadata(
          "v4.1.0",
          false,
          None,
          None,
          sha=Some(sha_v420),
        ),
        @moon-taze.VersionMetadata(
          "v4.2.0",
          false,
          None,
          None,
          sha=Some(sha_v420),
        ),
        @moon-taze.VersionMetadata(
          "v5.0.0",
          false,
          None,
          None,
          sha=Some(sha_v500),
        ),
      ])
    },
  )
  // Default mode leaves `demo/lib@1.0.0` as NoCandidate (only 2.0.0 major exists),
  // and recommends `v4.2.0` (sha_v420) for actions/checkout.
  assert_eq(plan.changes()[0].status, NoCandidate)
  assert_eq(plan.changes()[1].target, Some("v4.2.0"))
  assert_eq(plan.changes()[1].target_sha, Some(sha_v420))

  // Interactive user opts into 2.0.0 and switches actions/checkout to v5.0.0.
  let report = @moon-taze.apply(
    plan,
    plan.selection([
      (mod_path, "demo/lib", "2.0.0"),
      (ci_path, "actions/checkout", "v5.0.0"),
    ]),
  )
  assert_eq(report.exit_code(), 0)
  assert_eq(report.written_files(), 2)
  assert_true(@fs.read_text(mod_path).contains("demo/lib@2.0.0"))
  let written_ci = @fs.read_text(ci_path)
  assert_true(written_ci.contains("actions/checkout@\{sha_v500} # v5.0.0"))
  assert_false(written_ci.contains(sha_v420))
}
