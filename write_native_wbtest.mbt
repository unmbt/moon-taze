///|
async test "Native preserves Windows ACL and rejects readonly files" {
  if @env.get_env_var("OS") != Some("Windows_NT") {
    return
  }
  let root = @fs.tmpdir(prefix="moon-taze-acl")
  defer @fs.rmdir(root, recursive=true)
  let plan = batch_fixture(root, 1)
  let path = @fs.realpath(plan.snapshots[0].path)
  let (user_code, user, _) = @process.collect_output(
    "whoami.exe",
    [],
    inherit_env=true,
  )
  assert_eq(user_code, 0)
  let account = user.text().trim().to_owned()
  let (acl_code, _, _) = @process.collect_output(
    "icacls.exe",
    [path, "/inheritance:r", "/grant:r", account + ":(F)"],
    inherit_env=true,
  )
  assert_eq(acl_code, 0)
  let (before_code, before, _) = @process.collect_output(
    "icacls.exe",
    [path],
    inherit_env=true,
  )
  assert_eq(before_code, 0)
  let result = apply(plan, plan.recommended_selection())
  assert_eq(result.exit_code(), 0)
  let (after_code, after, _) = @process.collect_output(
    "icacls.exe",
    [path],
    inherit_env=true,
  )
  assert_eq(after_code, 0)
  assert_eq(after.binary(), before.binary())
  let fresh = batch_fixture(root, 1)
  let (code, _, _) = @process.collect_output(
    "attrib.exe",
    ["+R", path],
    inherit_env=true,
  )
  assert_eq(code, 0)
  defer ignore(
    @process.collect_output("attrib.exe", ["-R", path], inherit_env=true),
  )
  let denied = apply(fresh, fresh.recommended_selection())
  assert_eq(denied.exit_code(), 2)
  assert_eq(denied.written_files(), 0)
  assert_originals(fresh)
  assert_eq(@fs.readdir(root, include_hidden=true).length(), 1)
}

///|
#skip("requires file-symlink privilege on Windows; run explicitly with --include-skipped")
async test "Native rejects symlink leaf without following it for a write" {
  let root = @fs.tmpdir(prefix="moon-taze-symlink")
  defer @fs.rmdir(root, recursive=true)
  let plan = batch_fixture(root, 1)
  let target = plan.snapshots[0].path
  let link_path = root + "/moon.mod"
  @fs.symlink(link_path, target~, force_symlink=true)
  let manifest = parse_manifest(
    @fs.read_file(link_path).binary(),
    path=link_path,
    module_name="demo/app",
  ).manifest.unwrap()
  let linked = check_manifest(manifest, mode=Patch, fetch=name => {
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
async test "Native simultaneous writer encounters lock while first writer commits" {
  let root = @fs.tmpdir(prefix="moon-taze-concurrent")
  defer @fs.rmdir(root, recursive=true)
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
  let (first, second) = @async.with_task_group(group => {
    let task = group.spawn(() => {
      apply_with_services(plan, plan.recommended_selection(), first_io)
    })
    @async.with_timeout(5000, () => ready.acquire())
    ready.release()
    let second = apply(plan, plan.recommended_selection())
    proceed.release()
    (task.wait(), second)
  })
  assert_true(first.status is Succeeded)
  assert_eq(first.written_files(), 1)
  assert_true(second.status is Failed)
  assert_eq(second.diagnostics[0].code, "write_conflict")
  assert_eq(@fs.readdir(root, include_hidden=true).length(), 1)
}

///|
async test "Native cleanup never removes replacement resources owned by another run" {
  let root = @fs.tmpdir(prefix="moon-taze-ownership")
  defer @fs.rmdir(root, recursive=true)
  let native = native_write_services()
  let path = root + "/moon.mod.moon-taze.lock"
  let owned = (native.create)(path)
  // Keep the original inode alive at another path to exclude immediate id reuse.
  @fs.rename(path, root + "/old.lock", replace=false)
  @fs.write_file(path, b"other process")
  try (native.cleanup)(owned) catch {
    WriteError(code, _, _) => assert_eq(code, "write_conflict")
    error => raise error
  } noraise {
    _ => fail("expected ownership conflict")
  }
  assert_eq(@fs.read_file(path).binary(), b"other process")
}
