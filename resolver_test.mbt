///|
async test "resolver queries dependencies, retains errors, and rejects invalid metadata" {
  let source : Bytes = @utf8.encode(
    (
      #|import {
      #|  "demo/lib@1.2.0",
      #|  "demo/missing@1.0.0",
      #|}
    ),
  )
  let manifest = @moon-taze.parse_manifest(
    source,
    path="moon.mod",
    module_name="demo/app",
  ).manifest.unwrap()
  let calls : Array[String] = []
  let plan = @moon-taze.check(
    manifest,
    options=@moon-taze.CheckOptions(mode=Default),
    fetch=name => {
      calls.push(name)
      if name == "demo/missing" {
        raise @moon-taze.registry_request_failed("HTTP 404")
      }
      @moon-taze.ModuleMetadata(name, Some("1.3.0"), [
        @moon-taze.VersionMetadata("1.2.0", false, None, None),
        @moon-taze.VersionMetadata("1.3.0", false, None, None),
      ])
    },
  )
  assert_eq(calls.length(), 2)
  assert_true(plan.has_errors())
  assert_eq(plan.changes()[0].status, UpdateAvailable)
  assert_eq(plan.changes()[1].status, Error)
  assert_eq(plan.changes()[1].reason, Some("module_not_found"))

  let single = @moon-taze.parse_manifest(
    @utf8.encode("import { \"demo/lib@0.0.3\" }"),
    path="moon.mod",
    module_name="demo/app",
  ).manifest.unwrap()
  let invalid_plan = @moon-taze.check(single, fetch=_ => {
    @moon-taze.ModuleMetadata("other/lib", None, [])
  })
  assert_true(invalid_plan.has_errors())
  assert_eq(invalid_plan.changes()[0].reason, Some("invalid_metadata"))

  let no_candidate = @moon-taze.check(single, fetch=name => {
    @moon-taze.ModuleMetadata(name, Some("0.1.0"), [
      @moon-taze.VersionMetadata("0.0.4", false, None, None),
      @moon-taze.VersionMetadata("0.1.0", false, None, None),
    ])
  })
  assert_eq(no_candidate.changes()[0].status, NoCandidate)
  assert_false(no_candidate.has_errors())
}

///|
async test "selectors skip dependencies before registry requests and filter candidate versions" {
  let source = @utf8.encode(
    (
      #|import {
      #|  "demo/lib@1.2.0",
      #|  "other/lib@1.0.0",
      #|}
    ),
  )
  let manifest = @moon-taze.parse_manifest(
    source,
    path="moon.mod",
    module_name="demo/app",
  ).manifest.unwrap()
  let calls : Array[String] = []
  let skipped_plan = @moon-taze.check(
    manifest,
    options=@moon-taze.CheckOptions(include_selectors=["demo/*"], exclude_selectors=[
      "demo/lib",
    ]),
    fetch=name => {
      calls.push(name)
      @moon-taze.ModuleMetadata(name, None, [])
    },
  )
  assert_eq(calls.length(), 0)
  assert_true(skipped_plan.changes().all(c => c.status == Skipped))

  let single = @moon-taze.parse_manifest(
    @utf8.encode("import { \"demo/lib@1.2.0\" }"),
    path="moon.mod",
    module_name="demo/app",
  ).manifest.unwrap()
  let fetch_versions : async (String) -> @moon-taze.ModuleMetadata raise @moon-taze.RegistryError = name => {
    @moon-taze.ModuleMetadata(name, Some("1.4.0"), [
      @moon-taze.VersionMetadata("1.2.0", false, None, None),
      @moon-taze.VersionMetadata("1.3.0", false, None, None),
      @moon-taze.VersionMetadata("1.4.0", false, None, None),
    ])
  }
  let filtered = @moon-taze.check(
    single,
    options=@moon-taze.CheckOptions(mode=Major, exclude_selectors=[
      "demo/lib@1.3.0",
    ]),
    fetch=fetch_versions,
  )
  assert_eq(filtered.changes()[0].target, Some("1.4.0"))
  let blocked = @moon-taze.check(
    single,
    options=@moon-taze.CheckOptions(mode=Major, exclude_selectors=["demo/lib@1"]),
    fetch=fetch_versions,
  )
  assert_eq(blocked.changes()[0].status, NoCandidate)
}

///|
async test "newest uses release time, enforces missing timestamps, and respects maturity boundary" {
  let manifest = @moon-taze.parse_manifest(
    @utf8.encode("import { \"demo/lib@1.0.0\" }"),
    path="moon.mod",
    module_name="demo/app",
  ).manifest.unwrap()
  let now = 200000000L
  let timed_fetch : async (String) -> @moon-taze.ModuleMetadata raise @moon-taze.RegistryError = name => {
    @moon-taze.ModuleMetadata(name, Some("1.9.0"), [
      @moon-taze.VersionMetadata("1.0.0", false, None, Some(1000000L)),
      @moon-taze.VersionMetadata("1.2.0", false, None, Some(113600000L)),
      @moon-taze.VersionMetadata("1.9.0", false, None, Some(100000000L)),
    ])
  }
  let newest = @moon-taze.check(
    manifest,
    options=@moon-taze.CheckOptions(
      mode=Newest,
      release=@moon-taze.ReleaseOptions(now, 0),
    ),
    fetch=timed_fetch,
  )
  assert_eq(newest.changes()[0].target, Some("1.2.0"))

  let mature = @moon-taze.check(
    manifest,
    options=@moon-taze.CheckOptions(
      mode=Default,
      release=@moon-taze.ReleaseOptions(now, 1),
    ),
    fetch=timed_fetch,
  )
  assert_eq(mature.changes()[0].target, Some("1.9.0"))
  assert_true(
    mature.changes()[0].diagnostics.any(d => d.code == "unknown_release_time"),
  )

  let missing_times = @moon-taze.check(
    manifest,
    options=@moon-taze.CheckOptions(
      mode=Newest,
      release=@moon-taze.ReleaseOptions(now, 0),
    ),
    fetch=name => {
      @moon-taze.ModuleMetadata(name, None, [
        @moon-taze.VersionMetadata("1.0.0", false, None, None),
        @moon-taze.VersionMetadata("1.1.0", false, None, None),
      ])
    },
  )
  assert_true(missing_times.has_errors())
  assert_eq(missing_times.changes()[0].reason, Some("incomplete_release_times"))
}

///|
async test "pure resolve and deterministic check callback order" {
  let manifest = @moon-taze.parse_manifest(
    b"import {\"demo/lib@1.0.0\"}",
    path="moon.mod",
    module_name="demo/app",
  ).manifest.unwrap()
  let dependency = manifest.dependencies[0]
  let events : Array[String] = []
  let callbacks = @moon-taze.Callbacks(
    after_discovery=Some(plan => {
      events.push("discovered:\{plan.changes().length()}")
      ""
    }),
    dependency_resolved=Some(change => {
      events.push("resolved:\{change.dependency.name}")
      ""
    }),
  )
  let _ = @moon-taze.check(
    manifest,
    options=@moon-taze.CheckOptions(callbacks=Some(callbacks)),
    fetch=name => {
      @moon-taze.ModuleMetadata(name, Some("1.1.0"), [
        @moon-taze.VersionMetadata("1.0.0", false, None, None),
        @moon-taze.VersionMetadata("1.1.0", false, None, None),
      ])
    },
  )
  assert_eq(events, ["discovered:1", "resolved:demo/lib"])
  let change = @moon-taze.resolve(
    dependency,
    @moon-taze.ModuleMetadata("demo/lib", Some("1.1.0"), [
      @moon-taze.VersionMetadata("1.0.0", false, None, None),
      @moon-taze.VersionMetadata("1.1.0", false, None, None),
    ]),
    @moon-taze.Policy(Default),
    now=0L,
  )
  assert_eq(change.target, Some("1.1.0"))
}
