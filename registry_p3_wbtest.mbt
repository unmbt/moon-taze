///|
test "P3 RFC3339 detail timestamps normalize to UTC milliseconds" {
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
test "P3 detail metadata preserves missing publication time and validates identity" {
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
