///|
/// A parsed manifest snapshot for the read-only milestone.
pub struct Manifest {
  pub module_name : String
  pub path : String
  pub source : Bytes
  pub dependencies : Array[Dependency]
} derive(Debug, Eq)

///|
pub struct ParseResult {
  pub manifest : Manifest?
  pub diagnostics : Array[Diagnostic]
} derive(Debug, Eq)

///|
fn is_space_byte(value : Byte) -> Bool {
  value == b' ' || value == b'\t' || value == b'\r' || value == b'\n'
}

///|
fn is_ident_byte(value : Byte) -> Bool {
  value == b'_' ||
  value == b'-' ||
  (value >= b'a' && value <= b'z') ||
  (value >= b'A' && value <= b'Z') ||
  (value >= b'0' && value <= b'9') ||
  value == b'/'
}

///|
fn skip_space(source : Bytes, start : Int) -> Int {
  let mut index = start
  while index < source.length() && is_space_byte(source[index]) {
    index += 1
  }
  index
}

///|
fn skip_trivia(source : Bytes, start : Int) -> Int {
  let mut index = start
  let mut again = true
  while again {
    index = skip_space(source, index)
    if index + 1 < source.length() &&
      source[index] == b'/' &&
      source[index + 1] == b'/' {
      index += 2
      while index < source.length() && source[index] != b'\n' {
        index += 1
      }
    } else if index + 1 < source.length() &&
      source[index] == b'/' &&
      source[index + 1] == b'*' {
      index += 2
      while index + 1 < source.length() &&
            !(source[index] == b'*' && source[index + 1] == b'/') {
        index += 1
      }
      if index + 1 < source.length() {
        index += 2
      }
    } else {
      again = false
    }
  }
  index
}

///|
fn line_column(source : Bytes, offset : Int) -> (Int, Int) {
  let mut line = 1
  let mut column = 1
  for index in 0..<offset {
    if source[index] == b'\n' {
      line += 1
      column = 1
    } else {
      column += 1
    }
  }
  (line, column)
}

///|
fn find_matching_brace(source : Bytes, start : Int) -> Int? {
  let mut depth = 0
  let mut index = start
  let mut in_string = false
  let mut escaped = false
  let mut line_comment = false
  let mut block_comment = false
  while index < source.length() {
    let current = source[index]
    let next = if index + 1 < source.length() {
      source[index + 1]
    } else {
      b'\x00'
    }
    if line_comment {
      if current == b'\n' {
        line_comment = false
      }
    } else if block_comment {
      if current == b'*' && next == b'/' {
        block_comment = false
        index += 1
      }
    } else if in_string {
      if escaped {
        escaped = false
      } else if current == b'\\' {
        escaped = true
      } else if current == b'"' {
        in_string = false
      }
    } else if current == b'/' && next == b'/' {
      line_comment = true
      index += 1
    } else if current == b'/' && next == b'*' {
      block_comment = true
      index += 1
    } else if current == b'"' {
      in_string = true
    } else if current == b'{' {
      depth += 1
    } else if current == b'}' {
      depth -= 1
      if depth == 0 {
        return Some(index)
      }
    }
    index += 1
  }
  None
}

///|
fn decode_string(source : Bytes, start : Int, end : Int) -> String? {
  let result = StringBuilder()
  let mut index = start + 1
  while index < end {
    let current = source[index]
    if current == b'\\' {
      if index + 1 >= end {
        return None
      }
      let escaped = source[index + 1]
      let value = match escaped {
        b'"' => '"'
        b'\\' => '\\'
        b'n' => '\n'
        b'r' => '\r'
        b't' => '\t'
        _ => return None
      }
      result.write_char(value)
      index += 2
    } else {
      // Decode complete UTF-8 runs.  Splitting at non-ASCII bytes would turn
      // a valid multibyte character into replacement characters and would
      // make dependency names differ from the manifest text.
      let mut last = index + 1
      while last < end && source[last] != b'\\' {
        last += 1
      }
      result.write_string(
        @utf8.decode_lossy(Bytes::clamped_view(source, start=index, end=last)),
      )
      index = last
    }
  }
  Some(result.to_string())
}

///|
fn parse_dependency_text(value : String) -> (String, String)? {
  let split = value.rev_split_once("@")
  match split {
    Some((left, right)) => {
      let name = left.to_owned()
      let version = right.to_owned()
      let invalid_name = name == "" ||
        name.contains("\\") ||
        name.contains("://") ||
        name.contains("@") ||
        name.contains("?") ||
        name.contains("#") ||
        name
        .split("/")
        .any(segment => segment == "" || segment == "." || segment == "..")
      let invalid_version = version == "" ||
        version.contains("/") ||
        version.contains("^") ||
        version.contains("~") ||
        version.contains(" ") ||
        version.contains("://")
      if invalid_name || invalid_version {
        None
      } else {
        Some((name, version))
      }
    }
    None => None
  }
}

///|
fn find_unescaped_at(source : Bytes, start : Int, end : Int) -> Int? {
  let mut result : Int? = None
  let mut index = start
  let mut escaped = false
  while index < end {
    if escaped {
      escaped = false
    } else if source[index] == b'\\' {
      escaped = true
    } else if source[index] == b'@' {
      result = Some(index)
    }
    index += 1
  }
  result
}

///|
fn add_dependency(
  dependencies : Array[Dependency],
  diagnostics : Array[Diagnostic],
  dependency : Dependency,
) -> Unit {
  for existing in dependencies {
    if existing.name == dependency.name {
      diagnostics.push(
        diagnostic(
          "duplicate_dependency",
          "dependency is declared more than once",
          Some(dependency.manifest),
          Some(dependency.name),
          Some(dependency.span.line),
          Some(dependency.span.column),
        ),
      )
      return
    }
  }
  dependencies.push(dependency)
}

///|
/// Parse ordinary imports from a `moon.mod` byte snapshot.
pub fn parse_manifest(
  source : Bytes,
  path~ : String,
  module_name~ : String,
) -> ParseResult {
  let dependencies : Array[Dependency] = []
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
  ignore(
    @utf8.decode(source, ignore_bom=true) catch {
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
    },
  )
  let mut index = if source.length() >= 3 &&
    source[0] == 0xef &&
    source[1] == 0xbb &&
    source[2] == 0xbf {
    3
  } else {
    0
  }
  let manifest_start = skip_trivia(source, index)
  if manifest_start < source.length() && source[manifest_start] == b'{' {
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
  let mut nesting = 0
  let mut paren_nesting = 0
  let mut bracket_nesting = 0
  while index < source.length() {
    if source[index] == b'/' &&
      index + 1 < source.length() &&
      source[index + 1] == b'/' {
      index += 2
      while index < source.length() && source[index] != b'\n' {
        index += 1
      }
      continue
    }
    if source[index] == b'/' &&
      index + 1 < source.length() &&
      source[index + 1] == b'*' {
      index += 2
      let mut closed = false
      while index + 1 < source.length() {
        if source[index] == b'*' && source[index + 1] == b'/' {
          index += 2
          closed = true
          break
        }
        index += 1
      }
      if !closed {
        diagnostics.push(
          diagnostic(
            "invalid_manifest",
            "unterminated comment",
            Some(path),
            None,
            None,
            None,
          ),
        )
        break
      }
      continue
    }
    if source[index] == b'"' {
      let begin = index
      index += 1
      let mut closed = false
      while index < source.length() {
        if source[index] == b'\\' {
          index += 2
        } else if source[index] == b'"' {
          index += 1
          closed = true
          break
        } else {
          index += 1
        }
      }
      if !closed {
        let (line, column) = line_column(source, begin)
        diagnostics.push(
          diagnostic(
            "invalid_manifest",
            "unterminated string",
            Some(path),
            None,
            Some(line),
            Some(column),
          ),
        )
        break
      }
      continue
    }
    if nesting == 0 &&
      paren_nesting == 0 &&
      bracket_nesting == 0 &&
      source[index] == b'i' &&
      index + 6 <= source.length() {
      let is_import = source[index] == b'i' &&
        source[index + 1] == b'm' &&
        source[index + 2] == b'p' &&
        source[index + 3] == b'o' &&
        source[index + 4] == b'r' &&
        source[index + 5] == b't'
      let before_ok = index == 0 || !is_ident_byte(source[index - 1])
      let after_ok = index + 6 == source.length() ||
        !is_ident_byte(source[index + 6])
      if is_import && before_ok && after_ok {
        let open = skip_trivia(source, index + 6)
        if open < source.length() && source[open] == b'{' {
          match find_matching_brace(source, open) {
            Some(close) => {
              let after_import = skip_trivia(source, close + 1)
              let has_for_suffix = after_import + 3 <= source.length() &&
                source[after_import] == b'f' &&
                source[after_import + 1] == b'o' &&
                source[after_import + 2] == b'r' &&
                (
                  after_import + 3 == source.length() ||
                  !is_ident_byte(source[after_import + 3])
                )
              if has_for_suffix {
                let (line, column) = line_column(source, index)
                diagnostics.push(
                  warning(
                    "unsupported_dependency_kind",
                    "only ordinary import blocks are supported",
                    Some(path),
                    None,
                    Some(line),
                    Some(column),
                  ),
                )
                index = close + 1
                continue
              }
              let mut cursor = open + 1
              while cursor < close {
                if source[cursor] == b'"' {
                  let begin = cursor
                  cursor += 1
                  let mut escaped = false
                  while cursor < close {
                    if escaped {
                      escaped = false
                    } else if source[cursor] == b'\\' {
                      escaped = true
                    } else if source[cursor] == b'"' {
                      break
                    }
                    cursor += 1
                  }
                  if cursor >= close {
                    diagnostics.push(
                      diagnostic(
                        "invalid_manifest",
                        "unterminated string",
                        Some(path),
                        None,
                        None,
                        None,
                      ),
                    )
                    break
                  }
                  match decode_string(source, begin, cursor) {
                    Some(value) =>
                      match parse_dependency_text(value) {
                        Some((name, version)) => {
                          let (line, column) = line_column(source, begin)
                          let parsed_version : SemVer? = Some(
                            parse_version(version),
                          ) catch {
                            _ => None
                          }
                          match parsed_version {
                            Some(_) =>
                              match
                                find_unescaped_at(source, begin + 1, cursor) {
                                Some(at) => {
                                  let dependency = {
                                    module: module_name,
                                    manifest: path,
                                    name,
                                    version,
                                    source: Registry,
                                    span: {
                                      start: at + 1,
                                      end: cursor,
                                      line,
                                      column,
                                    },
                                  }
                                  add_dependency(
                                    dependencies, diagnostics, dependency,
                                  )
                                }
                                None =>
                                  diagnostics.push(
                                    diagnostic(
                                      "unsupported_dependency_spec",
                                      "dependency must be module@version",
                                      Some(path),
                                      Some(name),
                                      Some(line),
                                      Some(column),
                                    ),
                                  )
                              }
                            None =>
                              diagnostics.push(
                                diagnostic(
                                  "unsupported_dependency_spec",
                                  "dependency must use a complete SemVer version",
                                  Some(path),
                                  Some(name),
                                  Some(line),
                                  Some(column),
                                ),
                              )
                          }
                        }
                        None =>
                          diagnostics.push(
                            diagnostic(
                              "unsupported_dependency_spec",
                              "dependency must be module@version",
                              Some(path),
                              None,
                              None,
                              None,
                            ),
                          )
                      }
                    None =>
                      diagnostics.push(
                        diagnostic(
                          "invalid_manifest",
                          "invalid string escape",
                          Some(path),
                          None,
                          None,
                          None,
                        ),
                      )
                  }
                } else if source[cursor] == b'/' &&
                  cursor + 1 < close &&
                  source[cursor + 1] == b'/' {
                  cursor += 2
                  while cursor < close && source[cursor] != b'\n' {
                    cursor += 1
                  }
                } else if source[cursor] == b'/' &&
                  cursor + 1 < close &&
                  source[cursor + 1] == b'*' {
                  cursor += 2
                  while cursor + 1 < close &&
                        !(source[cursor] == b'*' && source[cursor + 1] == b'/') {
                    cursor += 1
                  }
                  if cursor + 1 >= close {
                    diagnostics.push(
                      diagnostic(
                        "invalid_manifest",
                        "unterminated comment",
                        Some(path),
                        None,
                        None,
                        None,
                      ),
                    )
                    cursor = close
                  } else {
                    cursor += 2
                  }
                }
                cursor += 1
              }
              index = close + 1
              continue
            }
            None =>
              diagnostics.push(
                diagnostic(
                  "invalid_manifest",
                  "unterminated import block",
                  Some(path),
                  None,
                  None,
                  None,
                ),
              )
          }
          if find_matching_brace(source, open) is None {
            index = source.length()
            continue
          }
        } else {
          let (line, column) = line_column(source, index)
          diagnostics.push(
            warning(
              "unsupported_dependency_kind",
              "only ordinary import blocks are supported",
              Some(path),
              None,
              Some(line),
              Some(column),
            ),
          )
        }
      }
    }
    if source[index] == b'{' {
      nesting += 1
    } else if source[index] == b'}' && nesting > 0 {
      nesting -= 1
    } else if source[index] == b'}' {
      let (line, column) = line_column(source, index)
      diagnostics.push(
        diagnostic(
          "invalid_manifest",
          "unexpected closing brace",
          Some(path),
          None,
          Some(line),
          Some(column),
        ),
      )
    }
    if source[index] == b'(' {
      paren_nesting += 1
    } else if source[index] == b')' && paren_nesting > 0 {
      paren_nesting -= 1
    } else if source[index] == b')' {
      let (line, column) = line_column(source, index)
      diagnostics.push(
        diagnostic(
          "invalid_manifest",
          "unexpected closing parenthesis",
          Some(path),
          None,
          Some(line),
          Some(column),
        ),
      )
    } else if source[index] == b'[' {
      bracket_nesting += 1
    } else if source[index] == b']' && bracket_nesting > 0 {
      bracket_nesting -= 1
    } else if source[index] == b']' {
      let (line, column) = line_column(source, index)
      diagnostics.push(
        diagnostic(
          "invalid_manifest",
          "unexpected closing bracket",
          Some(path),
          None,
          Some(line),
          Some(column),
        ),
      )
    }
    index += 1
  }
  if nesting != 0 || paren_nesting != 0 || bracket_nesting != 0 {
    diagnostics.push(
      diagnostic(
        "invalid_manifest",
        "unterminated structure",
        Some(path),
        None,
        None,
        None,
      ),
    )
  }
  let manifest = { module_name, path, source, dependencies, }
  { manifest: Some(manifest), diagnostics, }
}
