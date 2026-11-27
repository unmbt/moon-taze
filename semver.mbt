///|
/// A SemVer 2.0.0 value used by the offline selection engine.
#derive(Eq, Debug)
pub struct SemVer {
  major : Int32
  minor : Int32
  patch : Int32
  prerelease : Array[String]
  build : Array[String]
}

///|
/// Update strategies supported by `moon-taze`.
#derive(Eq, Debug)
pub(all) enum UpdateMode {
  Default
  Major
  Minor
  Patch
  Latest
  Stable
  Newest
  Next
}

///|
/// A malformed SemVer string.
#derive(Debug)
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
      raise InvalidVersion(value)
    }
    result.push(part)
  }
  result
}

///|
/// Parse a complete SemVer 2.0.0 string.
pub fn parse_version(source : String) -> SemVer raise SemVerError {
  let (without_build, build) = match source.split_once("+") {
    Some((left, right)) => (left.to_owned(), Some(right.to_owned()))
    None => (source, None)
  }
  if build is Some("") {
    raise InvalidVersion(source)
  }
  let (core, prerelease) = match without_build.split_once("-") {
    Some((left, right)) => (left.to_owned(), Some(right.to_owned()))
    None => (without_build, None)
  }
  let core_parts = Array::from_iter(core.split(".").map(StringView::to_owned))
  if core_parts.length() != 3 ||
    !core_parts.all(part => valid_identifier(part, numeric=true)) {
    raise InvalidVersion(source)
  }
  let major = @string.parse_int(core_parts[0]) catch {
    _ => raise InvalidVersion(source)
  }
  let minor = @string.parse_int(core_parts[1]) catch {
    _ => raise InvalidVersion(source)
  }
  let patch = @string.parse_int(core_parts[2]) catch {
    _ => raise InvalidVersion(source)
  }
  let pre = match prerelease {
    Some(value) => {
      let result : Array[String] = []
      for item in value.split(".") {
        let part = item.to_owned()
        let numeric = part.all(is_ascii_digit)
        if !valid_identifier(part, numeric~) {
          raise InvalidVersion(source)
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
fn compare_identifier(left : String, right : String) -> Int32 {
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
pub fn SemVer::compare(left : SemVer, right : SemVer) -> Int32 {
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
fn compare_prerelease(left : Array[String], right : Array[String]) -> Int32 {
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
  if mode == Stable {
    !is_prerelease(candidate)
  } else if !is_prerelease(current) {
    !is_prerelease(candidate)
  } else if is_prerelease(candidate) {
    candidate.major == current.major &&
    candidate.minor == current.minor &&
    candidate.patch == current.patch
  } else {
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
fn diff_kind(current : SemVer, target : SemVer) -> DiffKind {
  if current.major != target.major {
    Major
  } else if current.minor != target.minor {
    Minor
  } else if current.patch != target.patch {
    Patch
  } else {
    Prerelease
  }
}

///|
/// Compute the semantic diff kind between two SemVer strings.
pub fn semver_diff_kind(current : String, target : String) -> DiffKind? {
  let curr = parse_version(current) catch { _ => return None }
  let next = parse_version(target) catch { _ => return None }
  if SemVer::compare(next, curr) == 0 {
    None
  } else {
    Some(diff_kind(curr, next))
  }
}

///|
/// Select a target from a module's versions using the requested update mode.
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
  let latest_allows_prerelease = mode == Latest &&
    (is_prerelease(current) || latest_is_prerelease)
  let candidates = versions.filter(candidate => {
    let prerelease_ok = latest_allows_prerelease ||
      eligible_prerelease(current, candidate, mode)
    if SemVer::compare(candidate, current) <= 0 || !prerelease_ok {
      false
    } else if mode == Patch {
      in_patch_range(current, candidate)
    } else if mode == Default || mode == Minor || mode == Stable {
      in_caret_range(current, candidate)
    } else {
      true
    }
  })
  if mode == Latest {
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
    let capped = match latest {
      Some(pointer) if mode != Stable => {
        let pointer_is_eligible = SemVer::compare(pointer, current) > 0 &&
          eligible_prerelease(current, pointer, mode) &&
          (
            mode == Major ||
            (mode == Patch && in_patch_range(current, pointer)) ||
            (
              (mode == Default || mode == Minor) &&
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

///|
/// Parsed v-prefixed GitHub Actions tag (`v4`, `v4.2`, `v4.2.1`, `v4.2.1-rc.1`).
#derive(Eq, Debug)
pub struct ParsedActionTag {
  raw : String
  major : Int32
  minor : Int32
  patch : Int32
  segments : Int32
  prerelease : Bool
}

///|
/// Parse a v-prefixed GitHub Actions version tag.
/// Only tags beginning with `v` followed by a digit are accepted.
pub fn parse_action_tag(tag : String) -> ParsedActionTag? {
  if tag.length() < 2 || tag[0] != 'v' {
    return None
  }
  let rest = tag[1:].to_owned()
  let without_build = match rest.split_once("+") {
    Some((left, right)) => {
      if right.is_empty() {
        return None
      }
      left.to_owned()
    }
    None => rest
  }
  let (core, prerelease) = match without_build.split_once("-") {
    Some((left, right)) => {
      if right.is_empty() {
        return None
      }
      (left.to_owned(), true)
    }
    None => (without_build, false)
  }
  let parts = Array::from_iter(core.split(".").map(StringView::to_owned))
  if parts.is_empty() || parts.length() > 3 {
    return None
  }
  for part in parts {
    if part.is_empty() || !part.all(is_ascii_digit) {
      return None
    }
  }
  let major = @string.parse_int(parts[0]) catch { _ => return None }
  let minor = if parts.length() >= 2 {
    @string.parse_int(parts[1]) catch {
      _ => return None
    }
  } else {
    0
  }
  let patch = if parts.length() >= 3 {
    @string.parse_int(parts[2]) catch {
      _ => return None
    }
  } else {
    0
  }
  Some({ raw: tag, major, minor, patch, segments: parts.length(), prerelease, })
}

///|
fn compare_action_tag(a : ParsedActionTag, b : ParsedActionTag) -> Int32 {
  let maj = a.major.compare(b.major)
  if maj != 0 {
    return maj
  }
  let min = a.minor.compare(b.minor)
  if min != 0 {
    return min
  }
  let pat = a.patch.compare(b.patch)
  if pat != 0 {
    return pat
  }
  if a.prerelease != b.prerelease {
    if a.prerelease {
      -1
    } else {
      1
    }
  } else {
    a.raw.compare(b.raw)
  }
}

///|
fn action_tag_to_semver(tag : ParsedActionTag) -> SemVer {
  {
    major: tag.major,
    minor: tag.minor,
    patch: tag.patch,
    prerelease: if tag.prerelease {
      ["pre"]
    } else {
      []
    },
    build: [],
  }
}

///|
/// Compute the semantic diff kind between two GitHub Actions version tags.
pub fn action_diff_kind(current : String, target : String) -> DiffKind? {
  match (parse_action_tag(current), parse_action_tag(target)) {
    (Some(c), Some(t)) =>
      if c.major != t.major {
        Some(Major)
      } else if c.minor != t.minor {
        Some(Minor)
      } else if c.patch != t.patch {
        Some(Patch)
      } else if c.prerelease != t.prerelease || c.raw != t.raw {
        Some(Prerelease)
      } else {
        None
      }
    _ => None
  }
}

///|
/// Selected GitHub Actions target, preserving the reference's tag granularity.
#derive(Eq, Debug)
pub struct SelectedActionTarget {
  tag : String
  resolved_tag : String
}

///|
/// Select the next GitHub Actions version tag honoring update mode and
/// preserving the granularity of `current_tag` (`v4` -> `v5`, `v4.1.1` -> `v4.2.0`).
pub fn select_action_target(
  current_tag : String,
  tags : Array[String],
  mode : UpdateMode,
  reject~ : (ParsedActionTag) -> Bool = _ => false,
) -> SelectedActionTarget? {
  let current = match parse_action_tag(current_tag) {
    Some(value) => value
    None => return None
  }
  let allow_prerelease = mode == Newest || mode == Next || current.prerelease
  let known : Map[String, Unit] = Map([])
  let parsed : Array[ParsedActionTag] = []
  for tag in tags {
    known[tag] = ()
    if parse_action_tag(tag) is Some(item) {
      parsed.push(item)
    }
  }
  let baseline = { ..current, prerelease: false, }
  let candidates = parsed.filter(t => {
    if !allow_prerelease && t.prerelease {
      return false
    }
    if reject(t) {
      return false
    }
    if compare_action_tag(t, baseline) <= 0 {
      return false
    }
    match mode {
      Patch => t.major == current.major && t.minor == current.minor
      Minor | Default | Stable => t.major == current.major
      Major | Latest | Newest | Next => true
    }
  })
  if candidates.is_empty() {
    return None
  }
  candidates.sort_by(compare_action_tag)
  let best = candidates[candidates.length() - 1]
  let desired = match current.segments {
    1 => "v\{best.major}"
    2 => "v\{best.major}.\{best.minor}"
    _ => "v\{best.major}.\{best.minor}.\{best.patch}"
  }
  let tag = if known.contains(desired) { desired } else { best.raw }
  Some({ tag, resolved_tag: best.raw, })
}
