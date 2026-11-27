///|
fn matches_glob(pattern : String, value : String) -> Bool {
  let mut pattern_index = 0
  let mut value_index = 0
  let mut star_index = -1
  let mut star_value_index = 0
  while value_index < value.length() {
    if pattern_index < pattern.length() &&
      (
        pattern[pattern_index] == '*' ||
        pattern[pattern_index] == value[value_index]
      ) {
      if pattern[pattern_index] == '*' {
        star_index = pattern_index
        star_value_index = value_index
      }
      pattern_index += 1
      value_index += 1
    } else if star_index >= 0 {
      pattern_index = star_index + 1
      star_value_index += 1
      value_index = star_value_index
    } else {
      return false
    }
  }
  while pattern_index < pattern.length() && pattern[pattern_index] == '*' {
    pattern_index += 1
  }
  pattern_index == pattern.length()
}

///|
fn parse_int_option(value : String) -> Int32? {
  Some(@string.parse_int(value)) catch {
    _ => None
  }
}

///|
fn parse_filter_version(raw : String) -> SemVer? {
  let clean = match raw.strip_prefix("v") {
    Some(rest) => rest.to_owned()
    None => raw
  }
  let parts = Array::from_iter(clean.split(".").map(StringView::to_owned))
  if parts.length() == 1 && parse_int_option(parts[0]) is Some(major) {
    Some(parse_version("\{major}.0.0")) catch {
      _ => None
    }
  } else if parts.length() == 2 &&
    parse_int_option(parts[0]) is Some(major) &&
    parse_int_option(parts[1]) is Some(minor) {
    Some(parse_version("\{major}.\{minor}.0")) catch {
      _ => None
    }
  } else {
    Some(parse_version(clean)) catch {
      _ => None
    }
  }
}

///|
fn name_selector_valid(value : String) -> Bool {
  value != "" &&
  !value.contains("@") &&
  !value.contains("?") &&
  !value.contains("#") &&
  !value.contains("://") &&
  !value
  .split("/")
  .any(segment => segment == "" || segment == "." || segment == "..")
}

///|
fn version_filter_matches(current : String, filter : String) -> Bool {
  if filter == "" || filter == "*" || filter == "x" || filter == "X" {
    return true
  }
  let current_version : SemVer? = match parse_action_tag(current) {
    Some(tag) => Some(action_tag_to_semver(tag))
    None => Some(parse_version(current)) catch { _ => None }
  }
  match current_version {
    None => false
    Some(current_version) => {
      let (operator, raw) = if filter.has_prefix("^") || filter.has_prefix("~") {
        (filter[:1].to_owned(), filter[1:].to_owned())
      } else {
        ("", filter)
      }
      let clean = match raw.strip_prefix("v") {
        Some(rest) => rest.to_owned()
        None => raw
      }
      let parts = Array::from_iter(clean.split(".").map(StringView::to_owned))
      let target : SemVer? = parse_filter_version(raw)
      match target {
        None => false
        Some(target) if operator == "^" =>
          SemVer::compare(current_version, target) >= 0 &&
          in_caret_range(target, current_version)
        Some(target) if operator == "~" =>
          SemVer::compare(current_version, target) >= 0 &&
          in_patch_range(target, current_version)
        Some(target) if parts.length() < 3 =>
          if parts.length() == 1 {
            current_version.major == target.major
          } else {
            current_version.major == target.major &&
            current_version.minor == target.minor
          }
        Some(target) => SemVer::compare(current_version, target) == 0
      }
    }
  }
}

///|
/// Validate a dependency selector (`name`, `scope/*`, or `name@version-range`).
pub fn selector_valid(selector : String) -> Bool {
  match selector.rev_split_once("@") {
    None => name_selector_valid(selector)
    Some((name, version)) =>
      if !name_selector_valid(name.to_owned()) || version == "" {
        false
      } else if version == "*" || version == "x" || version == "X" {
        true
      } else {
        let raw = if version.has_prefix("^") || version.has_prefix("~") {
          version[1:].to_owned()
        } else {
          version.to_owned()
        }
        let clean = match raw.strip_prefix("v") {
          Some(rest) => rest.to_owned()
          None => raw
        }
        let parts = Array::from_iter(clean.split(".").map(StringView::to_owned))
        (
          (parts.length() == 1 || parts.length() == 2) &&
          parts.all(part => parse_int_option(part) is Some(_))
        ) ||
        (Some(parse_version(clean)) catch { _ => None }) is Some(_)
      }
  }
}

///|
fn filter_matches(dependency : Dependency, selector : String) -> Bool {
  match selector.rev_split_once("@") {
    None => matches_glob(selector, dependency.name)
    Some((name, version)) =>
      matches_glob(name.to_owned(), dependency.name) &&
      version_filter_matches(dependency.version, version.to_owned())
  }
}

///|
fn selector_has_version(selector : String) -> Bool {
  selector.rev_split_once("@") is Some(_)
}

///|
fn selector_matches_version(
  name : String,
  version : String,
  selector : String,
) -> Bool {
  match selector.rev_split_once("@") {
    None => false
    Some((selector_name, selector_version)) =>
      matches_glob(selector_name.to_owned(), name) &&
      version_filter_matches(version, selector_version.to_owned())
  }
}
