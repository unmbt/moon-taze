///|
/// A SemVer 2.0.0 value used by the offline selection engine.
pub struct SemVer {
  pub major : Int
  pub minor : Int
  pub patch : Int
  pub prerelease : Array[String]
  pub build : Array[String]
} derive(Debug, Eq)

///|
/// Update strategies supported by the first read-only milestone.
pub(all) enum UpdateMode {
  Default
  Major
  Minor
  Patch
  Latest
  Stable
  Newest
  Next
} derive(Debug, Eq)

///|
/// A malformed SemVer string.
pub suberror SemVerError {
  InvalidVersion(String)
}

///|
fn is_ascii_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
fn valid_identifier(value : String, numeric~ : Bool) -> Bool {
  if value == "" {
    false
  } else if numeric {
    if value.length() > 1 && value[0] == '0' {
      false
    } else {
      value.all(is_ascii_digit)
    }
  } else {
    value.all(c => {
      is_ascii_digit(c) ||
      (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      c == '-'
    })
  }
}

///|
fn parse_identifiers(
  value : String,
  numeric~ : Bool,
) -> Array[String] raise SemVerError {
  let result : Array[String] = []
  for item in value.split(".") {
    let part = item.to_owned()
    if !valid_identifier(part, numeric~) {
      raise SemVerError::InvalidVersion(value)
    }
    result.push(part)
  }
  result
}

///|
/// Parse a complete SemVer 2.0.0 string.
pub fn parse_version(source : String) -> SemVer raise SemVerError {
  let source = source
  let (without_build, build) = match source.split_once("+") {
    Some((left, right)) => (left.to_owned(), Some(right.to_owned()))
    None => (source, None)
  }
  if build is Some("") {
    raise SemVerError::InvalidVersion(source)
  }
  let (core, prerelease) = match without_build.split_once("-") {
    Some((left, right)) => (left.to_owned(), Some(right.to_owned()))
    None => (without_build, None)
  }
  let core_parts = Array::from_iter(core.split(".").map(StringView::to_owned))
  if core_parts.length() != 3 ||
    !core_parts.all(part => valid_identifier(part, numeric=true)) {
    raise SemVerError::InvalidVersion(source)
  }
  let major = @string.parse_int(core_parts[0]) catch {
    _ => raise SemVerError::InvalidVersion(source)
  }
  let minor = @string.parse_int(core_parts[1]) catch {
    _ => raise SemVerError::InvalidVersion(source)
  }
  let patch = @string.parse_int(core_parts[2]) catch {
    _ => raise SemVerError::InvalidVersion(source)
  }
  let pre = match prerelease {
    Some(value) => {
      // Numeric prerelease identifiers have the same leading-zero rule as
      // numeric core identifiers.  Passing numeric=false here would accept
      // `01`, which is not SemVer 2.0.0.
      let result : Array[String] = []
      for item in value.split(".") {
        let part = item.to_owned()
        let numeric = part.all(is_ascii_digit)
        if !valid_identifier(part, numeric~) {
          raise SemVerError::InvalidVersion(source)
        }
        result.push(part)
      }
      result
    }
    None => []
  }
  let build_parts = match build {
    Some(value) => parse_identifiers(value, numeric=false)
    None => []
  }
  { major, minor, patch, prerelease: pre, build: build_parts, }
}

///|
/// Render a SemVer value without changing its precedence.
pub fn SemVer::to_string(self : SemVer) -> String {
  let core = "\{self.major}.\{self.minor}.\{self.patch}"
  let with_pre = if self.prerelease.is_empty() {
    core
  } else {
    core + "-" + self.prerelease.join(".")
  }
  if self.build.is_empty() {
    with_pre
  } else {
    with_pre + "+" + self.build.join(".")
  }
}

///|
fn compare_identifier(left : String, right : String) -> Int {
  let left_numeric = left.all(is_ascii_digit)
  let right_numeric = right.all(is_ascii_digit)
  if left_numeric && right_numeric {
    if left.length() != right.length() {
      left.length().compare(right.length())
    } else {
      left.compare(right)
    }
  } else if left_numeric && !right_numeric {
    -1
  } else if !left_numeric && right_numeric {
    1
  } else {
    left.compare(right)
  }
}

///|
/// Compare SemVer values. Build metadata is intentionally ignored.
pub fn SemVer::compare(left : SemVer, right : SemVer) -> Int {
  let major = left.major.compare(right.major)
  if major != 0 {
    major
  } else {
    let minor = left.minor.compare(right.minor)
    if minor != 0 {
      minor
    } else {
      let patch = left.patch.compare(right.patch)
      if patch != 0 {
        patch
      } else if left.prerelease.is_empty() && right.prerelease.is_empty() {
        0
      } else if left.prerelease.is_empty() {
        1
      } else if right.prerelease.is_empty() {
        -1
      } else {
        compare_prerelease(left.prerelease, right.prerelease)
      }
    }
  }
}

///|
fn compare_prerelease(left : Array[String], right : Array[String]) -> Int {
  let limit = if left.length() < right.length() {
    left.length()
  } else {
    right.length()
  }
  for i in 0..<limit {
    let result = compare_identifier(left[i], right[i])
    if result != 0 {
      return result
    }
  }
  left.length().compare(right.length())
}

///|
fn is_prerelease(version : SemVer) -> Bool {
  !version.prerelease.is_empty()
}

///|
fn in_caret_range(current : SemVer, candidate : SemVer) -> Bool {
  if candidate.major > current.major {
    false
  } else if current.major > 0 {
    candidate.major == current.major
  } else if current.minor > 0 {
    candidate.major == 0 && candidate.minor == current.minor
  } else {
    candidate.major == 0 &&
    candidate.minor == 0 &&
    candidate.patch == current.patch
  }
}

///|
fn in_patch_range(current : SemVer, candidate : SemVer) -> Bool {
  candidate.major == current.major && candidate.minor == current.minor
}

///|
fn eligible_prerelease(
  current : SemVer,
  candidate : SemVer,
  mode : UpdateMode,
) -> Bool {
  if mode == UpdateMode::Stable {
    !is_prerelease(candidate)
  } else if !is_prerelease(current) {
    !is_prerelease(candidate)
  } else if is_prerelease(candidate) {
    candidate.major == current.major &&
    candidate.minor == current.minor &&
    candidate.patch == current.patch
  } else {
    // A prerelease may advance to any stable version admitted by the
    // strategy's range; the range check itself is applied by the caller.
    true
  }
}

///|
fn select_max(candidates : Array[SemVer]) -> SemVer? {
  if candidates.is_empty() {
    None
  } else {
    let mut result = candidates[0]
    for candidate in candidates {
      if SemVer::compare(candidate, result) > 0 ||
        (
          SemVer::compare(candidate, result) == 0 &&
          candidate.to_string() > result.to_string()
        ) {
        result = candidate
      }
    }
    Some(result)
  }
}

///|
/// Select a target from a module's versions using the first milestone modes.
pub fn select_version(
  current : SemVer,
  versions : Array[SemVer],
  latest? : SemVer,
  mode~ : UpdateMode,
) -> SemVer? {
  let latest_is_prerelease = match latest {
    Some(pointer) => is_prerelease(pointer)
    None => false
  }
  let latest_allows_prerelease = mode == UpdateMode::Latest &&
    (is_prerelease(current) || latest_is_prerelease)
  let candidates = versions.filter(candidate => {
    let prerelease_ok = latest_allows_prerelease ||
      eligible_prerelease(current, candidate, mode)
    if SemVer::compare(candidate, current) <= 0 || !prerelease_ok {
      false
    } else if mode == UpdateMode::Patch {
      in_patch_range(current, candidate)
    } else if mode == UpdateMode::Default ||
      mode == UpdateMode::Minor ||
      mode == UpdateMode::Stable {
      in_caret_range(current, candidate)
    } else {
      true
    }
  })
  if mode == UpdateMode::Latest {
    match latest {
      Some(pointer) => {
        let capped = candidates.filter(candidate => {
          SemVer::compare(candidate, pointer) <= 0
        })
        select_max(capped)
      }
      None => select_max(candidates)
    }
  } else {
    // The registry's latest pointer is a cap only when it belongs to the
    // strategy's normal candidate range.  A major-mode request must still be
    // able to cross a latest pointer that is outside the caret range; stable
    // mode intentionally has no cap.
    let capped = match latest {
      Some(pointer) if mode != UpdateMode::Stable => {
        let pointer_is_eligible = SemVer::compare(pointer, current) > 0 &&
          eligible_prerelease(current, pointer, mode) &&
          (
            mode == UpdateMode::Major ||
            (mode == UpdateMode::Patch && in_patch_range(current, pointer)) ||
            (
              (mode == UpdateMode::Default || mode == UpdateMode::Minor) &&
              in_caret_range(current, pointer)
            )
          )
        if pointer_is_eligible {
          candidates.filter(candidate => {
            SemVer::compare(candidate, pointer) <= 0
          })
        } else {
          candidates
        }
      }
      _ => candidates
    }
    select_max(capped)
  }
}

///|
/// Parse and select in one step for callers that only have strings.
pub fn choose_version(
  current : String,
  versions : Array[String],
  mode~ : UpdateMode,
) -> String? raise SemVerError {
  let current = parse_version(current)
  let parsed = versions.map(v => parse_version(v))
  select_version(current, parsed, mode~).map(v => v.to_string())
}
