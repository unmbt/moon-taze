///|
test "moon.mod parser ignores comments and detects duplicates" {
  let source : Bytes = @utf8.encode(
    (
      #|name = "demo/app"
      #|import {
      #|  "demo/lib@1.2.3", // real
      #|  "demo/lib@1.2.3", // duplicate
      #|}
      #|description = "import { \"fake/x@9.9.9\" }"
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
  let manifest = result.manifest.unwrap()
  assert_eq(manifest.dependencies.length(), 1)
  assert_eq(manifest.dependencies[0].name, "demo/lib")
  assert_eq(manifest.dependencies[0].version, "1.2.3")
}

///|
test "moon.mod parser rejects unsupported versions, bad names, and legacy JSON" {
  let caret = @moon-taze.parse_manifest(
    @utf8.encode("import { \"demo/lib@^1.2.3\" }"),
    path="moon.mod",
    module_name="demo/app",
  )
  assert_true(
    caret.diagnostics.any(d => d.code == "unsupported_dependency_spec"),
  )

  let bad_name = @moon-taze.parse_manifest(
    @utf8.encode(
      (
        #|import {
        #|  // "fake/comment@9.9.9"
        #|  "demo/lib@1.2.3", // "fake/inline@9.9.9"
        #|  "demo/lib?query@1.2.4",
        #|}
      ),
    ),
    path="moon.mod",
    module_name="demo/app",
  )
  assert_eq(bad_name.manifest.unwrap().dependencies.length(), 1)
  assert_true(
    bad_name.diagnostics.any(d => d.code == "unsupported_dependency_spec"),
  )

  let legacy = @moon-taze.parse_manifest(
    @utf8.encode("{\"name\":\"demo/app\",\"dependencies\":{}}"),
    path="moon.mod.json",
    module_name="demo/app",
  )
  assert_true(legacy.manifest is None)
  assert_eq(legacy.diagnostics[0].code, "unsupported_manifest")
}

///|
test "moon.mod spans use UTF-8 byte offsets" {
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
  let manifest = result.manifest.unwrap()
  assert_eq(manifest.dependencies.length(), 1)
  let dep = manifest.dependencies[0]
  let expected_start = @utf8.encode(
    "name = \"demo/app\"\ndescription = \"中文\"\nimport { \"demo/lib@",
  ).length()
  assert_eq(dep.span.start, expected_start)
  assert_eq(
    source[dep.span.start:dep.span.end].to_owned(),
    @utf8.encode("1.2.3"),
  )
}

///|
async test "workspace members are local and shared registry requests are deduplicated" {
  let root = @fs.tmpdir(prefix="moon-taze-workspace")
  defer @fs.remove(root, recursive=true)
  let work = root + "/moon.work"
  @fs.write_binary(
    work,
    @utf8.encode(
      (
        #|// the string in this comment is not a member: "ignored"
        #|members = ["apps/a", "libs/b"]
      ),
    ),
  )
  @fs.mkdir(root + "/apps/a", recursive=true)
  @fs.mkdir(root + "/libs/b", recursive=true)
  @fs.write_binary(
    root + "/apps/a/moon.mod",
    @utf8.encode(
      "name = \"demo/a\"\nimport { \"demo/b@1.0.0\", \"demo/ext@1.0.0\" }",
    ),
  )
  @fs.write_binary(
    root + "/libs/b/moon.mod",
    @utf8.encode("name = \"demo/b\"\nimport { \"demo/ext@1.0.0\" }"),
  )
  let parsed = @moon-taze.read_workspace(work)
  let workspace = parsed.workspace.unwrap()
  assert_eq(workspace.members.map(item => item.module_name), [
    "demo/a", "demo/b",
  ])
  let calls : Array[String] = []
  let plan = @moon-taze.check_manifests(
    workspace.members.map(item => item.manifest),
    options=@moon-taze.CheckOptions(
      mode=Default,
      local_modules=["demo/a", "demo/b"],
      cwd=root,
    ),
    fetch=name => {
      calls.push(name)
      @moon-taze.ModuleMetadata(name, Some("1.1.0"), [
        @moon-taze.VersionMetadata("1.0.0", false, None, None),
        @moon-taze.VersionMetadata("1.1.0", false, None, None),
      ])
    },
  )
  assert_eq(calls, ["demo/ext"])
  let changes = plan.changes()
  assert_true(
    changes.any(change => {
      change.dependency.name == "demo/b" &&
      change.dependency.source == LocalWorkspace &&
      change.reason == Some("local_workspace")
    }),
  )
}
