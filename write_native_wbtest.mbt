///|
async test "native preserves Windows ACL and rejects readonly files" {
  if @env.get_env_var("OS") != Some("Windows_NT") {
    return
  }
  let root = @fs.tmpdir(prefix="moon-taze-acl")
  defer @fs.remove(root, recursive=true)
  let plan = batch_fixture(root, 1)
  let path = @fs.realpath(plan.snapshots[0].path)
  let user = @process.run("whoami.exe", [], inherit_env=true, stdout=Collect)
  let account = user.stdout_text().trim().to_owned()
  ignore(
    @process.run(
      "icacls.exe",
      [path, "/inheritance:r", "/grant:r", account + ":(F)"],
      inherit_env=true,
    ),
  )
  let before = @process.run(
    "icacls.exe",
    [path],
    inherit_env=true,
    stdout=Collect,
  )
  let result = apply(plan, plan.recommended_selection())
  assert_eq(result.exit_code(), 0)
  let after = @process.run(
    "icacls.exe",
    [path],
    inherit_env=true,
    stdout=Collect,
  )
  assert_eq(after.stdout_binary(), before.stdout_binary())

  let fresh = batch_fixture(root, 1)
  ignore(@process.run("attrib.exe", ["+R", path], inherit_env=true))
  defer @async.protect_from_cancel(() => {
    ignore(
      @process.run("attrib.exe", ["-R", path], inherit_env=true) catch {
        _ => return
      },
    )
  })
  let denied = apply(fresh, fresh.recommended_selection())
  assert_eq(denied.exit_code(), 2)
  assert_eq(denied.written_files(), 0)
  assert_originals(fresh)
  assert_eq(@fs.readdir(root, include_hidden=true).length(), 1)
}

///|
#skip("requires file-symlink privilege on Windows; run explicitly with --include-skipped")
async test "native rejects symlink leaf without following it for a write" {
  let root = @fs.tmpdir(prefix="moon-taze-symlink")
  defer @fs.remove(root, recursive=true)
  let plan = batch_fixture(root, 1)
  let target = plan.snapshots[0].path
  let link_path = root + "/moon.mod"
  @fs.symlink(link_path, target~, force_symlink=true)
  let manifest = parse_manifest(
    @fs.read_binary(link_path),
    path=link_path,
    module_name="demo/app",
  ).manifest.unwrap()
  let linked = check(manifest, options=CheckOptions(mode=Patch), fetch=name => {
    ModuleMetadata(name, Some("1.0.12"), [
      VersionMetadata("1.0.12", false, None, None),
    ])
  })
  let result = apply(linked, linked.recommended_selection())
  assert_eq(result.exit_code(), 2)
  assert_eq(result.diagnostics[0].code, "unsafe_write_target")
  assert_true(@fs.kind(link_path, follow_symlink=false) is SymLink)
  assert_originals(plan)
}

///|
async test "native simultaneous writer encounters lock while first writer commits" {
  let root = @fs.tmpdir(prefix="moon-taze-concurrent")
  defer @fs.remove(root, recursive=true)
  let plan = batch_fixture(root, 1)
  let ready = @async.Mutex()
  let proceed = @async.Mutex()
  ready.acquire()
  proceed.acquire()
  let first_io = {
    ..native_write_services(),
    before_commit: () => {
      ready.release()
      proceed.acquire()
      proceed.release()
    },
  }
  let mut first : ApplyReport? = None
  let mut second : ApplyReport? = None
  @async.with_task_group(group => {
    let task = group.spawn(() => {
      apply_with_services(plan, plan.recommended_selection(), first_io, None)
    })
    @async.with_timeout(5000, () => ready.acquire())
    ready.release()
    second = Some(apply(plan, plan.recommended_selection()))
    proceed.release()
    first = Some(task.wait())
  })
  let first = first.unwrap()
  let second = second.unwrap()
  assert_eq(first.status, Succeeded)
  assert_eq(first.written_files(), 1)
  assert_eq(second.status, Failed)
  assert_eq(second.diagnostics[0].code, "write_conflict")
  assert_eq(@fs.readdir(root, include_hidden=true).length(), 1)
}

///|
async test "native cleanup never removes replacement resources owned by another run" {
  let root = @fs.tmpdir(prefix="moon-taze-ownership")
  defer @fs.remove(root, recursive=true)
  let native = native_write_services()
  let path = root + "/moon.mod.moon-taze.lock"
  let owned = (native.create)(path)
  @fs.rename(path, root + "/old.lock", replace=false)
  @fs.write_binary(path, b"other process")
  try (native.cleanup)(owned) catch {
    WriteError(code, _, _) => assert_eq(code, "write_conflict")
    error => raise error
  } noraise {
    _ => fail("expected ownership conflict")
  }
  assert_eq(@fs.read_binary(path), b"other process")
}
