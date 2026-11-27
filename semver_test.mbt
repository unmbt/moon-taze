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
test "semver rejects numeric leading zeros and compares long numeric prereleases" {
  let invalid = ["1.0.0-01", "1.0.0-alpha.01", "01.0.0", "1.0.00"]
  for value in invalid {
    let result = Some(@moon-taze.parse_version(value)) catch { _ => None }
    assert_true(result is None)
  }
  let left = @moon-taze.parse_version("1.0.0-999999999999999999999")
  let right = @moon-taze.parse_version("1.0.0-1000000000000000000000")
  assert_true(@moon-taze.SemVer::compare(left, right) < 0)
}

///|
test "semver selection follows zero major boundaries and strategy caps" {
  let versions = ["0.2.3", "0.2.9", "0.3.0", "1.0.0"]
  assert_eq(
    @moon-taze.choose_version("0.2.3", versions, mode=Default),
    Some("0.2.9"),
  )
  assert_eq(
    @moon-taze.choose_version("0.2.3", versions, mode=Patch),
    Some("0.2.9"),
  )
  assert_eq(
    @moon-taze.choose_version("0.2.3", versions, mode=Major),
    Some("1.0.0"),
  )
  let v2 = ["1.2.4", "1.3.0", "1.9.0", "2.0.0", "2.1.0-beta.1", "3.0.0"]
  assert_eq(@moon-taze.choose_version("1.2.0", v2, mode=Default), Some("1.9.0"))
  assert_eq(@moon-taze.choose_version("1.2.0", v2, mode=Major), Some("3.0.0"))
  let current = @moon-taze.parse_version("1.2.0")
  let parsed = v2.map(v => @moon-taze.parse_version(v))
  let cap = @moon-taze.parse_version("1.3.0")
  assert_eq(
    @moon-taze.select_version(current, parsed, latest=cap, mode=Default).map(v => {
      v.to_string()
    }),
    Some("1.3.0"),
  )
  assert_eq(
    @moon-taze.choose_version("1.2.0", ["1.3.0-rc.1", "1.2.4"], mode=Stable),
    Some("1.2.4"),
  )
  assert_eq(
    @moon-taze.choose_version(
      "1.2.3-beta.2",
      ["1.2.3-beta.10", "1.2.3", "1.3.0-rc.1", "1.3.0"],
      mode=Default,
    ),
    Some("1.3.0"),
  )
}

///|
test "github action tag parsing and granularity-preserving selection" {
  assert_true(@moon-taze.parse_action_tag("main") is None)
  assert_true(@moon-taze.parse_action_tag("4.1.0") is None)
  let v4 = @moon-taze.parse_action_tag("v4").unwrap()
  assert_eq((v4.major, v4.minor, v4.patch, v4.segments), (4, 0, 0, 1))
  let tags = ["v4", "v4.1.0", "v4.2.0", "v5", "v5.0.0", "v5.1.0-rc.1"]
  assert_eq(
    @moon-taze.select_action_target("v4", tags, Major).map(t => t.tag),
    Some("v5"),
  )
  assert_eq(
    @moon-taze.select_action_target("v4.1.0", tags, Default).map(t => t.tag),
    Some("v4.2.0"),
  )
  assert_eq(@moon-taze.select_action_target("v4.1.0", tags, Patch), None)
  assert_eq(
    @moon-taze.select_action_target("v4.1.0", ["v4.1.0", "v5.0.0"], Major).map(t => {
      t.tag
    }),
    Some("v5.0.0"),
  )
  assert_eq(@moon-taze.action_diff_kind("v4", "v5"), Some(Major))
  assert_eq(@moon-taze.action_diff_kind("v4.1.0", "v4.2.0"), Some(Minor))
}
