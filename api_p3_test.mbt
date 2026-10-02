///|
/// P3 lifecycle tests intentionally use only the public root-package API.
async test "P3 resolve is pure and callback order is deterministic" {
  let manifest = @moon-taze.parse_manifest(
    b"import {\"demo/lib@1.0.0\"}",
    path="moon.mod",
    module_name="demo/app",
  ).manifest.unwrap()
  let dependency = manifest.dependencies[0]
  let events : Array[String] = []
  let callbacks = @moon-taze.Callbacks::Callbacks(
    after_discovery=Some(plan => {
      events.push("discovered:\{plan.changes().length()}")
      ""
    }),
    dependency_resolved=Some(change => {
      events.push("resolved:\{change.dependency.name}")
      ""
    }),
  )
  async fn fetch(
    name : String,
  ) -> @moon-taze.ModuleMetadata raise @moon-taze.RegistryError {
    @moon-taze.ModuleMetadata(name, Some("1.1.0"), [
      @moon-taze.VersionMetadata("1.0.0", false, None, None),
      @moon-taze.VersionMetadata("1.1.0", false, None, None),
    ])
  }
  let plan = @moon-taze.check_manifest(
    manifest,
    mode=@moon-taze.UpdateMode::Default,
    fetch~,
    callbacks=Some(callbacks),
  )
  assert_eq(events, ["discovered:1", "resolved:demo/lib"])
  let policy = @moon-taze.Policy::Policy(@moon-taze.UpdateMode::Default)
  let change = @moon-taze.resolve(
    dependency,
    @moon-taze.ModuleMetadata("demo/lib", Some("1.1.0"), [
      @moon-taze.VersionMetadata("1.0.0", false, None, None),
      @moon-taze.VersionMetadata("1.1.0", false, None, None),
    ]),
    policy,
    now=0,
  )
  assert_eq(change.target, Some("1.1.0"))
}

///|
async test "P3 callback denial happens before the first write" {
  let root = @fs.tmpdir(prefix="moon-taze-p3-callback")
  defer @fs.rmdir(root, recursive=true)
  let path = root + "/moon.mod"
  let source = b"import {\"demo/lib@1.0.0\"}"
  @fs.write_file(path, source)
  let manifest = @moon-taze.parse_manifest(
    source,
    path~,
    module_name="demo/app",
  ).manifest.unwrap()
  async fn fetch(
    name : String,
  ) -> @moon-taze.ModuleMetadata raise @moon-taze.RegistryError {
    @moon-taze.ModuleMetadata(name, Some("1.1.0"), [
      @moon-taze.VersionMetadata("1.0.0", false, None, None),
      @moon-taze.VersionMetadata("1.1.0", false, None, None),
    ])
  }
  let plan = @moon-taze.check_manifest(manifest, mode=Default, fetch~)
  let callbacks = @moon-taze.Callbacks::Callbacks(
    before_apply=Some(_ => "consumer denied apply"),
  )
  let report = @moon-taze.apply(
    plan,
    plan.recommended_selection(),
    callbacks=Some(callbacks),
  )
  assert_eq(report.exit_code(), 2)
  assert_eq(report.diagnostics()[0].code, "callback_denied")
  assert_eq(@fs.read_file(path).binary(), source)
}

///|
async test "P3 post-write callback failure preserves the write report" {
  let root = @fs.tmpdir(prefix="moon-taze-p3-post-callback")
  defer @fs.rmdir(root, recursive=true)
  let path = root + "/moon.mod"
  let source = b"import {\"demo/lib@1.0.0\"}"
  @fs.write_file(path, source)
  let manifest = @moon-taze.parse_manifest(
    source,
    path~,
    module_name="demo/app",
  ).manifest.unwrap()
  async fn fetch(
    name : String,
  ) -> @moon-taze.ModuleMetadata raise @moon-taze.RegistryError {
    @moon-taze.ModuleMetadata(name, Some("1.1.0"), [
      @moon-taze.VersionMetadata("1.0.0", false, None, None),
      @moon-taze.VersionMetadata("1.1.0", false, None, None),
    ])
  }
  let plan = @moon-taze.check(manifest, fetch~)
  let seen_written = Ref(0)
  let callbacks = @moon-taze.Callbacks::Callbacks(
    file_applied=Some(_ => "consumer post-write failure"),
    after_run=Some(report => {
      seen_written.val = report.written_files()
      ""
    }),
  )
  let report = @moon-taze.apply(
    plan,
    plan.recommended_selection(),
    callbacks=Some(callbacks),
  )
  assert_true(report.status() is @moon-taze.ApplyStatus::Partial)
  assert_eq(report.written_files(), 1)
  assert_eq(seen_written.val, 1)
  assert_eq(report.diagnostics()[0].code, "callback_failed")
  assert_eq(@fs.read_file(path).binary(), b"import {\"demo/lib@1.1.0\"}")
}
