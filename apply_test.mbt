///|
async fn fixture_plan(path : String, source : Bytes) -> @moon-taze.CheckPlan {
  let parsed = @moon-taze.parse_manifest(source, path~, module_name="demo/app")
  @moon-taze.check_manifest(parsed.manifest.unwrap(), mode=Major, fetch=name => {
    @moon-taze.ModuleMetadata::ModuleMetadata(name, Some("12.3.456"), [
      @moon-taze.VersionMetadata::VersionMetadata("12.3.456", false, None, None),
    ])
  })
}

///|
async test "P1b native write preserves bytes and repeated check preserves mtime" {
  let root = @fs.tmpdir(prefix="moon-taze-p1b")
  defer @fs.rmdir(root, recursive=true)
  let path = root + "/moon.mod"
  let source = @utf8.encode(
    "\uFEFF// 中文 😀\r\nname = \"demo/app\"\r\nimport { \"demo/a@1.0.0\", /*x*/ \"demo/b@0.1.2\" }\r\nimport {\"demo/c@2.0.0\"}\r\nother = \"demo/a@1.0.0\"",
  )
  @fs.write_file(path, source)
  let plan = fixture_plan(path, source)
  assert_false(plan.has_errors())
  let report = @moon-taze.apply(plan, plan.recommended_selection())
  assert_eq(
    report.exit_code(),
    0,
    msg=report.diagnostics.map(d => d.message).join("; "),
  )
  assert_true(report.status is Succeeded)
  assert_eq(report.written_files(), 1)
  assert_eq(report.files[0].changed_dependencies, 3)
  let expected = @utf8.encode(
    "\uFEFF// 中文 😀\r\nname = \"demo/app\"\r\nimport { \"demo/a@12.3.456\", /*x*/ \"demo/b@12.3.456\" }\r\nimport {\"demo/c@12.3.456\"}\r\nother = \"demo/a@1.0.0\"",
  )
  assert_eq(@fs.read_file(path).binary(), expected)
  let modified = @fs.mtime(path)
  let again = fixture_plan(path, expected)
  let noop = @moon-taze.apply(again, again.recommended_selection())
  assert_eq(noop.written_files(), 0)
  assert_eq(noop.exit_code(), 0)
  assert_eq(@fs.mtime(path), modified)
  assert_eq(@fs.readdir(root, include_hidden=true).length(), 1)
}

///|
async test "P1b snapshot conflict and lock conflict preserve user's bytes" {
  let root = @fs.tmpdir(prefix="moon-taze-p1b-conflict")
  defer @fs.rmdir(root, recursive=true)
  let path = root + "/moon.mod"
  let source = b"name = \"demo/app\"\nimport {\"demo/a@1.0.0\"}\n"
  @fs.write_file(path, source)
  let plan = fixture_plan(path, source)
  let edited = b"// edited\nname = \"demo/app\"\nimport {\"demo/a@1.0.0\"}\n"
  @fs.write_file(path, edited)
  let stale = @moon-taze.apply(plan, plan.recommended_selection())
  assert_eq(stale.exit_code(), 2)
  assert_eq(stale.diagnostics[0].code, "stale_plan")
  assert_eq(@fs.read_file(path).binary(), edited)
  assert_false(@fs.exists(path + ".moon-taze.lock"))
  @fs.write_file(path, source)
  @fs.write_file(path + ".moon-taze.lock", b"another owner")
  let locked = @moon-taze.apply(plan, plan.recommended_selection())
  assert_eq(locked.diagnostics[0].code, "write_conflict")
  assert_eq(@fs.read_file(path + ".moon-taze.lock").binary(), b"another owner")
  assert_eq(@fs.read_file(path).binary(), source)
  @fs.remove(path + ".moon-taze.lock")
  @fs.remove(path)
  let deleted = @moon-taze.apply(plan, plan.recommended_selection())
  assert_eq(deleted.diagnostics[0].code, "stale_plan")
  assert_eq(deleted.written_files(), 0)
  assert_eq(@fs.readdir(root, include_hidden=true).length(), 0)
}

///|
async test "P1b plans are detached and selections cannot cross plan boundaries" {
  let root = @fs.tmpdir(prefix="moon-taze-p1b-selection")
  defer @fs.rmdir(root, recursive=true)
  let path = root + "/moon.mod"
  let source = b"import {\"demo/a@1.0.0\", \"demo/b@1.0.0\"}"
  @fs.write_file(path, source)
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
    assert_eq(report.diagnostics[0].code, "invalid_selection")
    assert_eq(report.written_files(), 0)
    assert_eq(@fs.read_file(path).binary(), source)
  }
  let selected = @moon-taze.apply(
    plan,
    plan.selection([(path, "demo/b", "12.3.456")]),
  )
  assert_eq(selected.exit_code(), 0)
  assert_eq(
    @fs.read_file(path).binary(),
    b"import {\"demo/a@1.0.0\", \"demo/b@12.3.456\"}",
  )
}

///|
async test "P1b parse errors survive check_manifest and empty selection cannot hide them" {
  let source = b"import {\"demo/a@1.0.0\", \"demo/a@1.0.0\"}"
  let parsed = @moon-taze.parse_manifest(
    source,
    path="unused/moon.mod",
    module_name="demo/app",
  )
  let calls = Ref(0)
  let plan = @moon-taze.check_manifest(parsed.manifest.unwrap(), mode=Patch, fetch=name => {
    calls.val += 1
    @moon-taze.ModuleMetadata::ModuleMetadata(name, None, [])
  })
  assert_true(plan.has_errors())
  assert_eq(calls.val, 0)
  assert_eq(plan.diagnostics()[0].code, "duplicate_dependency")
  let report = @moon-taze.apply(plan, plan.selection([]))
  assert_eq(report.exit_code(), 2)
  assert_eq(report.diagnostics[0].code, "check_failed")
}
