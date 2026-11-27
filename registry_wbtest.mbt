///|
test "RFC3339 detail timestamps normalize to UTC milliseconds" {
  let utc = parse_rfc3339_ms("2026-09-20T10:01:15.264715+00:00")
  let east = parse_rfc3339_ms("2026-09-20T12:01:15.264+02:00")
  let west = parse_rfc3339_ms("2026-09-20T02:01:15.264-08:00")
  assert_true(utc is Some(_))
  assert_eq(utc, east)
  assert_eq(utc, west)
  assert_eq(parse_rfc3339_ms("2026-09-20T10:01:15Zx"), None)
  assert_eq(parse_rfc3339_ms("2026-09-20T10:01:15."), None)
}

///|
test "Mooncakes detail metadata preserves missing publication time and validates identity" {
  let missing = metadata_from_detail(
    @json.parse(
      "{\"module\":\"demo/lib\",\"version\":\"1.2.3\",\"yanked\":false,\"yanked_reason\":null,\"metadata\":{}}",
    ),
    "demo/lib",
    "1.2.3",
  )
  assert_eq(missing.published_at, None)
  let with_time = metadata_from_detail(
    @json.parse(
      "{\"module\":\"demo/lib\",\"version\":\"1.2.3\",\"yanked\":true,\"yanked_reason\":\"withdrawn\",\"metadata\":{\"created_at\":\"2026-09-20T10:01:15Z\"}}",
    ),
    "demo/lib",
    "1.2.3",
  )
  assert_true(with_time.published_at is Some(_))
  assert_true(with_time.yanked)
  assert_eq(with_time.yanked_reason, Some("withdrawn"))
}

///|
test "GitHub tags and commit date JSON parsers filter v-prefixed tags" {
  let tags_json = @json.parse(
    "[{\"name\":\"v4\",\"commit\":{\"sha\":\"aaa\"}},{\"name\":\"main\",\"commit\":{\"sha\":\"bbb\"}},{\"name\":\"v4.1.0\",\"commit\":{\"sha\":\"ccc\"}}]",
  )
  let tags = parse_github_tags_page(tags_json)
  assert_eq(tags.length(), 2)
  assert_eq(tags[0].0.raw, "v4")
  assert_eq(tags[0].1, "aaa")
  assert_eq(tags[1].0.raw, "v4.1.0")
  assert_eq(tags[1].1, "ccc")

  let commit_json = @json.parse(
    "{\"commit\":{\"committer\":{\"date\":\"2026-09-20T10:01:15Z\"}}}",
  )
  assert_eq(
    parse_github_commit_date_json(commit_json),
    parse_rfc3339_ms("2026-09-20T10:01:15Z"),
  )
}
