///|
/// Extract the module name from a `moon.mod` UTF-8 byte snapshot.
pub fn module_name_from_source(source : Bytes) -> String {
  @moon_manifest.parse(Mod, @utf8.decode_lossy(source), path="moon.mod")
  .module_name()
  .unwrap_or("")
}

///|
fn is_valid_module_name(name : String) -> Bool {
  name != "" &&
  !name.contains("\\") &&
  !name.contains("://") &&
  !name.contains("@") &&
  !name.contains("?") &&
  !name.contains("#") &&
  !name
  .split("/")
  .any(segment => segment == "" || segment == "." || segment == "..")
}

///|
fn is_valid_raw_version_spec(version : String) -> Bool {
  version != "" &&
  !version.contains("/") &&
  !version.contains("^") &&
  !version.contains("~") &&
  !version.contains(" ") &&
  !version.contains("://")
}

///|
fn is_legacy_json_source(source : Bytes) -> Bool {
  let mut index = if source.length() >= 3 &&
    source[0] == 0xef &&
    source[1] == 0xbb &&
    source[2] == 0xbf {
    3
  } else {
    0
  }
  while index < source.length() {
    let b = source[index]
    if b == b' ' || b == b'\t' || b == b'\r' || b == b'\n' {
      index += 1
    } else {
      return b == b'{'
    }
  }
  false
}

///|
fn classify_manifest_diagnostic(
  source : Bytes,
  path : String,
  item : @moon_manifest.Diagnostic,
) -> Diagnostic {
  let (line, column) = line_column(source, item.start)
  let msg = item.message
  if msg.has_prefix("Duplicate dependency") {
    diagnostic(
      "duplicate_dependency",
      msg,
      Some(path),
      None,
      Some(line),
      Some(column),
    )
  } else if msg.has_prefix("Invalid module import") ||
    msg.has_prefix("Unsupported module import") {
    diagnostic(
      "unsupported_dependency_spec",
      msg,
      Some(path),
      None,
      Some(line),
      Some(column),
    )
  } else if msg.contains("`test-import`") || msg.contains("`wbtest-import`") {
    warning(
      "unsupported_dependency_kind",
      msg,
      Some(path),
      None,
      Some(line),
      Some(column),
    )
  } else {
    diagnostic(
      "invalid_manifest",
      msg,
      Some(path),
      None,
      Some(line),
      Some(column),
    )
  }
}

///|
/// Parse ordinary imports from a `moon.mod` byte snapshot via `unmbt/moon-manifest`.
pub fn parse_manifest(
  source : Bytes,
  path~ : String,
  module_name~ : String,
) -> ParseResult {
  let diagnostics : Array[Diagnostic] = []
  if module_name == "" {
    diagnostics.push(
      diagnostic(
        "invalid_manifest",
        "manifest is missing a module name",
        Some(path),
        None,
        None,
        None,
      ),
    )
    return { manifest: None, diagnostics, }
  }
  if (source.length() >= 2 && source[0] == 0xff && source[1] == 0xfe) ||
    (source.length() >= 2 && source[0] == 0xfe && source[1] == 0xff) {
    diagnostics.push(
      diagnostic(
        "invalid_manifest",
        "manifest must be UTF-8",
        Some(path),
        None,
        None,
        None,
      ),
    )
    return { manifest: None, diagnostics, }
  }
  let text = @utf8.decode(source) catch {
    _ => {
      diagnostics.push(
        diagnostic(
          "invalid_manifest",
          "manifest must be valid UTF-8",
          Some(path),
          None,
          None,
          None,
        ),
      )
      return { manifest: None, diagnostics, }
    }
  }
  if is_legacy_json_source(source) {
    diagnostics.push(
      diagnostic(
        "unsupported_manifest",
        "legacy JSON manifests are not supported",
        Some(path),
        None,
        None,
        None,
      ),
    )
    return { manifest: None, diagnostics, }
  }
  let document = @moon_manifest.parse(Mod, text, path~)
  for item in document.diagnostics {
    diagnostics.push(classify_manifest_diagnostic(source, path, item))
  }
  let dependencies : Array[Dependency] = []
  let seen : Map[String, Unit] = Map([])
  for dep in document.dependencies() {
    let (line, column) = line_column(source, dep.span.start)
    if !is_valid_module_name(dep.name) ||
      !is_valid_raw_version_spec(dep.version) {
      diagnostics.push(
        diagnostic(
          "unsupported_dependency_spec",
          "dependency must be module@version",
          Some(path),
          Some(dep.name),
          Some(line),
          Some(column),
        ),
      )
      continue
    }
    let parsed_version : SemVer? = Some(parse_version(dep.version)) catch {
      _ => None
    }
    if parsed_version is None {
      diagnostics.push(
        diagnostic(
          "unsupported_dependency_spec",
          "dependency must use a complete SemVer version",
          Some(path),
          Some(dep.name),
          Some(line),
          Some(column),
        ),
      )
      continue
    }
    if seen.contains(dep.name) {
      continue
    }
    seen[dep.name] = ()
    dependencies.push({
      module_name,
      manifest: path,
      name: dep.name,
      version: dep.version,
      source: Mooncakes,
      span: {
        start: dep.version_span.start,
        end: dep.version_span.end,
        line,
        column,
      },
      gha: None,
    })
  }
  let manifest : Manifest = {
    kind: MoonMod,
    module_name,
    path,
    source,
    dependencies,
  }
  { manifest: Some(manifest), diagnostics, }
}

///|
/// Apply dependency version updates to a `moon.mod` snapshot using `unmbt/moon-manifest`.
fn patch_moon_manifest(
  snapshot : Manifest,
  updates : Array[(String, String)],
) -> Bytes raise {
  let text = @utf8.decode(snapshot.source) catch {
    _ => {
      write_error("invalid_selection", "manifest source is not valid UTF-8")
      ""
    }
  }
  let document = @moon_manifest.parse(Mod, text, path=snapshot.path)
  document.replace_dependency_versions(updates) catch {
    err => {
      write_error(
        "invalid_selection",
        "failed to patch moon.mod via moon-manifest: \{Repr(err)}",
      )
      b""
    }
  }
}
