///|
/// Parse an RFC 3339 timestamp string into UTC Unix milliseconds.
pub fn parse_rfc3339_ms(value : String) -> Int64? {
  if value.length() < 20 ||
    value[4] != '-' ||
    value[7] != '-' ||
    value[10] != 'T' ||
    value[13] != ':' ||
    value[16] != ':' {
    return None
  }
  let parse = fn(raw : StringView) -> Int32? {
    if raw.is_empty() || !raw.to_owned().all(is_ascii_digit) {
      return None
    }
    Some(@string.parse_int(raw.to_owned())) catch {
      _ => None
    }
  }
  let year = parse(value[:4])
  let month = parse(value[5:7])
  let day = parse(value[8:10])
  let hour = parse(value[11:13])
  let minute = parse(value[14:16])
  let second = parse(value[17:19])
  guard year is Some(year) &&
    month is Some(month) &&
    day is Some(day) &&
    hour is Some(hour) &&
    minute is Some(minute) &&
    second is Some(second) else {
    return None
  }
  if month < 1 ||
    month > 12 ||
    day < 1 ||
    day > 31 ||
    hour > 23 ||
    minute > 59 ||
    second > 59 ||
    year < 1 {
    return None
  }
  let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  let days_in_month = match month {
    2 => if leap { 29 } else { 28 }
    4 | 6 | 9 | 11 => 30
    _ => 31
  }
  if day > days_in_month {
    return None
  }
  let mut index = 19
  let mut fraction_ms = 0
  if index < value.length() && value[index] == '.' {
    index += 1
    let start = index
    while index < value.length() && value[index] >= '0' && value[index] <= '9' {
      index += 1
    }
    if index == start {
      return None
    }
    let digits = value[start:index]
    let mut factor = 100
    for digit in digits {
      if factor > 0 {
        fraction_ms += (digit.to_int() - '0'.to_int()) * factor
        factor = factor / 10
      }
    }
  }
  let mut offset_minutes = 0
  if index < value.length() && value[index] == 'Z' {
    index += 1
  } else if index + 5 < value.length() &&
    (value[index] == '+' || value[index] == '-') &&
    value[index + 3] == ':' {
    let offset_hour = parse(value[index + 1:index + 3])
    let offset_minute = parse(value[index + 4:index + 6])
    guard offset_hour is Some(offset_hour) &&
      offset_minute is Some(offset_minute) else {
      return None
    }
    if offset_hour > 23 || offset_minute > 59 {
      return None
    }
    offset_minutes = offset_hour * 60 + offset_minute
    if value[index] == '-' {
      offset_minutes = -offset_minutes
    }
    index += 6
  } else {
    return None
  }
  if index != value.length() {
    return None
  }
  let y = year - (if month <= 2 { 1 } else { 0 })
  let era = y / 400
  let yoe = y - era * 400
  let month_prime = month + (if month > 2 { -3 } else { 9 })
  let day_of_year = (153 * month_prime + 2) / 5 + day - 1
  let day_of_era = yoe * 365 + yoe / 4 - yoe / 100 + day_of_year
  let days = era * 146097 + day_of_era - 719468
  Some(
    days.to_int64() * 86400000L +
    (hour * 3600000 + minute * 60000 + second * 1000 + fraction_ms).to_int64() -
    (offset_minutes * 60000).to_int64(),
  )
}

///|
/// Format the elapsed duration between two release timestamps.
pub fn format_time_diff(current : Int64?, target : Int64?) -> String {
  match (current, target) {
    (Some(current), Some(target)) => {
      let seconds = (target - current) / 1000L
      let sign = if seconds < 0L { "-" } else { "+" }
      let magnitude = if seconds < 0L { -seconds } else { seconds }
      if magnitude >= 86400L {
        "\{sign}\{magnitude / 86400L}d"
      } else if magnitude >= 3600L {
        "\{sign}\{magnitude / 3600L}h"
      } else if magnitude >= 60L {
        "\{sign}\{magnitude / 60L}m"
      } else {
        "\{sign}\{magnitude}s"
      }
    }
    _ => "unknown"
  }
}

///|
/// Format a release timestamp as a human-friendly age relative to `now`.
pub fn format_release_age(
  value : Int64?,
  now~ : Int64 = @async.now(),
) -> String {
  match value {
    None => "unknown"
    Some(published) => {
      let elapsed = now - published
      if elapsed < 3600000L {
        "<1h"
      } else if elapsed < 360000000L {
        "~\{(elapsed + 1800000L) / 3600000L}h"
      } else if elapsed < 2592000000L {
        "~\{(elapsed + 43200000L) / 86400000L}d"
      } else if elapsed < 31536000000L {
        "~\{(elapsed + 1296000000L) / 2592000000L}mo"
      } else {
        let tenths = (elapsed * 10L + 1576800000L) / 31536000000L
        "~\{tenths / 10L}.\{tenths % 10L}y"
      }
    }
  }
}

///|
/// Compute 1-based `(line, column)` for a UTF-8 byte offset.
fn line_column(source : Bytes, offset : Int32) -> (Int32, Int32) {
  let limit = if offset > source.length() { source.length() } else { offset }
  let mut line = 1
  let mut column = 1
  for index in 0..<limit {
    if source[index] == b'\n' {
      line += 1
      column = 1
    } else {
      column += 1
    }
  }
  (line, column)
}
