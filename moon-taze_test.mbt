// Blackbox tests run against the package's public API. Use `@moon-taze` to import.
// Prefer high-level behaviors over implementation details.
// Run `moon test` to execute and `moon test --update` to refresh snapshots.

///|
test "semver ordering and build metadata" {
  let beta2 = @moon-taze.parse_version("1.0.0-beta.2")
  let beta10 = @moon-taze.parse_version("1.0.0-beta.10")
  let beta_a = @moon-taze.parse_version("1.0.0-beta.a")
  let stable = @moon-taze.parse_version("1.0.0")
  assert_true(@moon-taze.SemVer::compare(beta2, beta10) < 0)
  assert_true(@moon-taze.SemVer::compare(beta10, beta_a) < 0)
  assert_true(@moon-taze.SemVer::compare(beta_a, stable) < 0)
  let build1 = @moon-taze.parse_version("1.0.0+one")
  let build2 = @moon-taze.parse_version("1.0.0+two")
  assert_eq(@moon-taze.SemVer::compare(build1, build2), 0)
}

///|
test "semver selection follows zero major boundaries" {
  let versions = ["0.2.3", "0.2.9", "0.3.0", "1.0.0"]
  inspect(
    @moon-taze.choose_version("0.2.3", versions, mode=Default),
    content="Some(0.2.9)",
  )
  inspect(
    @moon-taze.choose_version("0.2.3", versions, mode=Patch),
    content="Some(0.2.9)",
  )
  inspect(
    @moon-taze.choose_version("0.2.3", versions, mode=Major),
    content="Some(1.0.0)",
  )
}

///|
test "manifest parser ignores comments and detects duplicates" {
  let source : Bytes = @utf8.encode(
    (
      #|name = "demo/app"
      #|import {
      #|  "demo/lib@1.2.3", // real
      #|  "demo/lib@1.2.3", // duplicate
      #|}
      #|metadata = "import { \"fake/x@9.9.9\" }"
    ),
  )
  let result = @moon-taze.parse_manifest(
    source,
    path="moon.mod",
    module_name="demo/app",
  )
  assert_true(result.manifest is Some(_))
  assert_eq(result.diagnostics.length(), 1)
  assert_eq(result.diagnostics[0].code, "duplicate_dependency")
  match result.manifest {
    Some(manifest) => {
      assert_eq(manifest.dependencies.length(), 1)
      assert_eq(manifest.dependencies[0].name, "demo/lib")
      assert_eq(manifest.dependencies[0].version, "1.2.3")
    }
    None => fail("expected manifest")
  }
}

///|
test "manifest parser rejects unsupported versions" {
  let source : Bytes = @utf8.encode("import { \"demo/lib@^1.2.3\" }")
  let result = @moon-taze.parse_manifest(
    source,
    path="moon.mod",
    module_name="demo/app",
  )
  inspect(result.diagnostics.length(), content="1")
  if result.diagnostics.length() > 0 {
    assert_eq(result.diagnostics[0].code, "unsupported_dependency_spec")
  }
}

///|
test "manifest parser skips comments inside imports and rejects bad names" {
  let source : Bytes = @utf8.encode(
    (
      #|import /* leading */ {
      #|  // "fake/comment@9.9.9"
      #|  "demo/lib@1.2.3", /* "fake/block@9.9.9" */
      #|  "demo/lib?query@1.2.4"
      #|}
    ),
  )
  let result = @moon-taze.parse_manifest(
    source,
    path="moon.mod",
    module_name="demo/app",
  )
  assert_eq(result.manifest.unwrap().dependencies.length(), 1)
  assert_eq(result.diagnostics.length(), 1)
  assert_eq(result.diagnostics[0].code, "unsupported_dependency_spec")
}

///|
test "manifest parser rejects legacy JSON" {
  let result = @moon-taze.parse_manifest(
    @utf8.encode("{\"name\":\"demo/app\",\"dependencies\":{}}"),
    path="moon.mod.json",
    module_name="demo/app",
  )
  assert_true(result.manifest is None)
  assert_eq(result.diagnostics[0].code, "unsupported_manifest")
}

///|
test "manifest parser warns for non-ordinary imports" {
  let result = @moon-taze.parse_manifest(
    @utf8.encode("import \"binary/module\""),
    path="moon.mod",
    module_name="demo/app",
  )
  assert_eq(result.manifest.unwrap().dependencies.length(), 0)
  assert_eq(result.diagnostics.length(), 1)
  assert_eq(result.diagnostics[0].code, "unsupported_dependency_kind")
}

///|
test "manifest parser skips import syntax inside expressions" {
  let source : Bytes = @utf8.encode(
    (
      #|metadata = make(
      #|  import { "fake/module@9.9.9" },
      #|)
      #|import { "demo/lib@1.2.3" } for "test"
      #|import { "demo/real@1.2.3" }
    ),
  )
  let result = @moon-taze.parse_manifest(
    source,
    path="moon.mod",
    module_name="demo/app",
  )
  assert_eq(result.manifest.unwrap().dependencies.length(), 1)
  assert_eq(result.manifest.unwrap().dependencies[0].name, "demo/real")
  assert_true(
    result.diagnostics.any(d => d.code == "unsupported_dependency_kind"),
  )
}

///|
test "manifest parser reports unterminated structures" {
  let result = @moon-taze.parse_manifest(
    @utf8.encode("metadata = { \"description\": \"unfinished\""),
    path="moon.mod",
    module_name="demo/app",
  )
  assert_true(result.diagnostics.any(d => d.code == "invalid_manifest"))
}

///|
test "semver rejects numeric prerelease leading zeros" {
  let invalid = ["1.0.0-01", "1.0.0-alpha.01", "01.0.0", "1.0.00"]
  for value in invalid {
    let result = Some(@moon-taze.parse_version(value)) catch { _ => None }
    assert_true(result is None)
  }
}

///|
test "semver strategy caps and prerelease rules" {
  let versions = ["1.2.4", "1.3.0", "1.9.0", "2.0.0", "2.1.0-beta.1", "3.0.0"]
  inspect(
    @moon-taze.choose_version("1.2.0", versions, mode=Default),
    content="Some(1.9.0)",
  )
  inspect(
    @moon-taze.choose_version("1.2.0", versions, mode=Major),
    content="Some(3.0.0)",
  )
  let current = @moon-taze.parse_version("1.2.0")
  let parsed = versions.map(v => @moon-taze.parse_version(v))
  let cap = @moon-taze.parse_version("1.3.0")
  let selected = @moon-taze.select_version(
    current,
    parsed,
    latest=cap,
    mode=Default,
  )
  inspect(selected.map(v => v.to_string()), content="Some(1.3.0)")
  let stable = @moon-taze.choose_version(
    "1.2.0",
    ["1.3.0-rc.1", "1.2.4"],
    mode=Stable,
  )
  inspect(stable, content="Some(1.2.4)")
  inspect(
    @moon-taze.choose_version(
      "1.2.3-beta.2",
      ["1.2.3-beta.10", "1.2.3", "1.3.0-rc.1", "1.3.0"],
      mode=Default,
    ),
    content="Some(1.3.0)",
  )
}

///|
test "numeric prerelease comparison handles long identifiers" {
  let left = @moon-taze.parse_version("1.0.0-999999999999999999999")
  let right = @moon-taze.parse_version("1.0.0-1000000000000000000000")
  assert_true(@moon-taze.SemVer::compare(left, right) < 0)
}

///|
test "manifest spans use UTF-8 byte offsets" {
  let source : Bytes = @utf8.encode(
    (
      #|name = "demo/app"
      #|description = "中文"
      #|import { "demo/lib@1.2.3" }
    ),
  )
  let result = @moon-taze.parse_manifest(
    source,
    path="moon.mod",
    module_name="demo/app",
  )
  match result.manifest {
    Some(manifest) => {
      assert_eq(manifest.dependencies.length(), 1)
      let dependency = manifest.dependencies[0]
      let version_bytes = @utf8.encode("1.2.3")
      let expected_start = @utf8.encode(
        "name = \"demo/app\"\ndescription = \"中文\"\nimport { \"demo/lib@",
      ).length()
      assert_eq(dependency.span.start, expected_start)
      assert_eq(
        source[dependency.span.start:dependency.span.end].to_owned(),
        version_bytes,
      )
    }
    None => fail("expected manifest")
  }
}

///|
async test "fake registry queries dependencies and retains errors" {
  let source : Bytes = @utf8.encode(
    (
      #|import {
      #|  "demo/lib@1.2.0",
      #|  "demo/missing@1.0.0",
      #|}
    ),
  )
  let parsed = @moon-taze.parse_manifest(
    source,
    path="moon.mod",
    module_name="demo/app",
  )
  match parsed.manifest {
    Some(manifest) => {
      let calls : Array[String] = []
      async fn fetch(
        name : String,
      ) -> @moon-taze.ModuleMetadata raise @moon-taze.RegistryError {
        calls.push(name)
        if name == "demo/missing" {
          raise @moon-taze.registry_request_failed("404")
        }
        @moon-taze.ModuleMetadata::ModuleMetadata(name, Some("1.3.0"), [
          @moon-taze.VersionMetadata::VersionMetadata(
            "1.2.0",
            false,
            None,
            None,
          ),
          @moon-taze.VersionMetadata::VersionMetadata(
            "1.3.0",
            false,
            None,
            None,
          ),
        ])
      }
      let plan = @moon-taze.check_manifest(manifest, mode=Default, fetch~)
      assert_eq(calls.length(), 2)
      assert_eq(plan.changes().length(), 2)
      assert_true(plan.has_errors())
      assert_true(
        plan.changes()[0].status is @moon-taze.ChangeStatus::UpdateAvailable,
      )
      assert_true(plan.changes()[1].status is @moon-taze.ChangeStatus::Error)
    }
    None => fail("expected manifest")
  }
}

///|
async test "fake registry rejects invalid metadata and reports no candidate" {
  let source : Bytes = @utf8.encode("import { \"demo/lib@0.0.3\" }")
  let parsed = @moon-taze.parse_manifest(
    source,
    path="moon.mod",
    module_name="demo/app",
  )
  match parsed.manifest {
    Some(manifest) => {
      async fn invalid_fetch(
        _ : String,
      ) -> @moon-taze.ModuleMetadata raise @moon-taze.RegistryError {
        @moon-taze.ModuleMetadata::ModuleMetadata("other/lib", None, [])
      }
      let invalid_plan = @moon-taze.check_manifest(
        manifest,
        mode=Default,
        fetch=invalid_fetch,
      )
      assert_true(invalid_plan.has_errors())
      assert_eq(invalid_plan.changes()[0].reason, Some("invalid_metadata"))

      async fn range_fetch(
        name : String,
      ) -> @moon-taze.ModuleMetadata raise @moon-taze.RegistryError {
        @moon-taze.ModuleMetadata::ModuleMetadata(name, Some("0.1.0"), [
          @moon-taze.VersionMetadata::VersionMetadata(
            "0.0.4",
            false,
            None,
            None,
          ),
          @moon-taze.VersionMetadata::VersionMetadata(
            "0.1.0",
            false,
            None,
            None,
          ),
        ])
      }
      let no_candidate = @moon-taze.check_manifest(
        manifest,
        mode=Default,
        fetch=range_fetch,
      )
      assert_true(
        no_candidate.changes()[0].status is @moon-taze.ChangeStatus::NoCandidate,
      )
      assert_eq(no_candidate.has_errors(), false)
    }
    None => fail("expected manifest")
  }
}

///|
async test "selectors skip dependencies before registry requests" {
  let source : Bytes = @utf8.encode(
    (
      #|import {
      #|  "demo/lib@1.2.0",
      #|  "other/lib@1.0.0",
      #|}
    ),
  )
  let parsed = @moon-taze.parse_manifest(
    source,
    path="moon.mod",
    module_name="demo/app",
  )
  let calls : Array[String] = []
  async fn fetch(
    name : String,
  ) -> @moon-taze.ModuleMetadata raise @moon-taze.RegistryError {
    calls.push(name)
    @moon-taze.ModuleMetadata::ModuleMetadata(name, Some("1.3.0"), [
      @moon-taze.VersionMetadata::VersionMetadata("1.2.0", false, None, None),
      @moon-taze.VersionMetadata::VersionMetadata("1.3.0", false, None, None),
    ])
  }
  let plan = @moon-taze.check_manifest_filtered(
    parsed.manifest.unwrap(),
    mode=Default,
    include=["demo/*"],
    exclude=["demo/lib"],
    fetch~,
  )
  assert_eq(calls.length(), 0)
  assert_true(
    plan
    .changes()
    .all(change => change.status is @moon-taze.ChangeStatus::Skipped),
  )
}

///|
async test "workspace members are local and shared registry requests are deduplicated" {
  let root = @fs.tmpdir(prefix="moon-taze-workspace")
  defer @fs.rmdir(root, recursive=true)
  let work = root + "/moon.work"
  @fs.write_file(
    work,
    @utf8.encode(
      (
        #|// the string in this comment is not a member: "ignored"
        #|workspace {
        #|  "apps/a",
        #|  "libs/b",
        #|}
      ),
    ),
  )
  @fs.mkdir(root + "/apps/a", recursive=true)
  @fs.mkdir(root + "/libs/b", recursive=true)
  @fs.write_file(
    root + "/apps/a/moon.mod",
    @utf8.encode(
      "name = \"demo/a\"\nimport { \"demo/b@1.0.0\", \"demo/ext@1.0.0\" }",
    ),
  )
  @fs.write_file(
    root + "/libs/b/moon.mod",
    @utf8.encode("name = \"demo/b\"\nimport { \"demo/ext@1.0.0\" }"),
  )
  let parsed = @moon-taze.read_workspace(work)
  assert_true(parsed.workspace is Some(_))
  let workspace = parsed.workspace.unwrap()
  assert_eq(workspace.members.map(member => member.module_name), [
    "demo/a", "demo/b",
  ])
  let calls : Array[String] = []
  async fn fetch(
    name : String,
  ) -> @moon-taze.ModuleMetadata raise @moon-taze.RegistryError {
    calls.push(name)
    @moon-taze.ModuleMetadata::ModuleMetadata(name, Some("1.1.0"), [
      @moon-taze.VersionMetadata::VersionMetadata("1.0.0", false, None, None),
      @moon-taze.VersionMetadata::VersionMetadata("1.1.0", false, None, None),
    ])
  }
  let plan = @moon-taze.check_manifests_filtered(
    workspace.members.map(member => member.manifest),
    ["demo/a", "demo/b"],
    mode=Default,
    include=[],
    exclude=[],
    cwd=root,
    fetch~,
  )
  assert_eq(calls, ["demo/ext"])
  let changes = plan.changes()
  assert_true(
    changes.any(change => {
      change.dependency.name == "demo/b" &&
      change.dependency.source is @moon-taze.DependencySource::LocalWorkspace
    }),
  )
  assert_true(changes.any(change => change.reason == Some("local_workspace")))
}

///|
async test "version selectors filter candidates after metadata fetch" {
  let source : Bytes = @utf8.encode("import { \"demo/lib@1.2.0\" }")
  let manifest = @moon-taze.parse_manifest(
    source,
    path="moon.mod",
    module_name="demo/app",
  ).manifest.unwrap()
  let calls : Array[String] = []
  async fn fetch(
    name : String,
  ) -> @moon-taze.ModuleMetadata raise @moon-taze.RegistryError {
    calls.push(name)
    @moon-taze.ModuleMetadata::ModuleMetadata(name, Some("1.4.0"), [
      @moon-taze.VersionMetadata::VersionMetadata("1.2.0", false, None, None),
      @moon-taze.VersionMetadata::VersionMetadata("1.3.0", false, None, None),
      @moon-taze.VersionMetadata::VersionMetadata("1.4.0", false, None, None),
    ])
  }
  let plan = @moon-taze.check_manifest_filtered(
    manifest,
    mode=Major,
    include=[],
    exclude=["demo/lib@1.3.0"],
    fetch~,
  )
  assert_eq(calls.length(), 1)
  assert_eq(plan.changes()[0].target, Some("1.4.0"))
  let blocked = @moon-taze.check_manifest_filtered(
    manifest,
    mode=Major,
    include=[],
    exclude=["demo/lib@1"],
    fetch~,
  )
  assert_true(
    blocked.changes()[0].status is @moon-taze.ChangeStatus::NoCandidate,
  )
}
