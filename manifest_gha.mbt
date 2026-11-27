///|
/// Parsed `uses:` reference from a GitHub Actions workflow or composite action.
#derive(Eq, Debug)
pub struct ParsedUses {
  repo : String
  subpath : String
  tag : String
  style : GitHubActionStyle
  sha : String?
}

///|
/// Return true when `path` is a GitHub Actions workflow or action manifest path.
pub fn is_github_actions_path(path : String) -> Bool {
  let normalized = path.replace_all(old="\\", new="/")
  let lower = normalized.to_lower()
  if lower.has_suffix("/action.yml") ||
    lower.has_suffix("/action.yaml") ||
    lower == "action.yml" ||
    lower == "action.yaml" {
    return true
  }
  match lower.find(".github/workflows/") {
    Some(idx) => {
      let at_boundary = idx == 0 || lower[idx - 1] == '/'
      let rest = lower[idx + 18:].to_owned()
      at_boundary &&
      !rest.contains("/") &&
      (rest.has_suffix(".yml") || rest.has_suffix(".yaml"))
    }
    None => false
  }
}

///|
fn is_hex_sha40(value : String) -> Bool {
  if value.length() != 40 {
    return false
  }
  for c in value {
    let ok = (c >= '0' && c <= '9') ||
      (c >= 'a' && c <= 'f') ||
      (c >= 'A' && c <= 'F')
    if !ok {
      return false
    }
  }
  true
}

///|
fn is_tag_char(c : Char) -> Bool {
  (c >= '0' && c <= '9') ||
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  c == '.' ||
  c == '-' ||
  c == '+' ||
  c == '_'
}

///|
fn extract_version_from_comment(comment : String?) -> String? {
  match comment {
    None => None
    Some(raw) => {
      let text = match raw.strip_prefix("#") {
        Some(rest) => rest.to_owned()
        None => raw
      }
      let mut i = 0
      while i < text.length() {
        let prev_ok = i == 0 ||
          text[i - 1] == ' ' ||
          text[i - 1] == '\t' ||
          text[i - 1] == '('
        if prev_ok &&
          text[i] == 'v' &&
          i + 1 < text.length() &&
          text[i + 1] >= '0' &&
          text[i + 1] <= '9' {
          let start = i
          i += 1
          while i < text.length() &&
                is_tag_char(text[i].to_int().unsafe_to_char()) {
            i += 1
          }
          let candidate = text[start:i].to_owned()
          if parse_action_tag(candidate) is Some(_) {
            return Some(candidate)
          }
        } else {
          i += 1
        }
      }
      None
    }
  }
}

///|
/// Parse a GitHub Actions `uses:` value and optional trailing inline comment.
/// Skips local actions (`./...`), Docker actions (`docker://...`), branch refs,
/// non-`v` tags, and SHA pins without a `# vX.Y.Z` version comment.
pub fn parse_uses(uses : String, comment~ : String? = None) -> ParsedUses? {
  let trimmed = uses.trim().to_owned()
  if trimmed.has_prefix(".") || trimmed.has_prefix("docker://") {
    return None
  }
  let (spec, ref_part) = match trimmed.rev_split_once("@") {
    Some((left, right)) if !left.is_empty() && !right.is_empty() =>
      (left.to_owned(), right.to_owned())
    _ => return None
  }
  let segments = Array::from_iter(spec.split("/").map(StringView::to_owned))
  if segments.length() < 2 || segments[0].is_empty() || segments[1].is_empty() {
    return None
  }
  let repo = "\{segments[0]}/\{segments[1]}"
  let subpath = if segments.length() > 2 {
    let rest : Array[String] = []
    for i in 2..<segments.length() {
      rest.push(segments[i])
    }
    "/" + rest.join("/")
  } else {
    ""
  }
  if is_hex_sha40(ref_part) {
    match extract_version_from_comment(comment) {
      Some(tag) =>
        Some({ repo, subpath, tag, style: Sha, sha: Some(ref_part), })
      None => None
    }
  } else if parse_action_tag(ref_part) is Some(_) {
    Some({ repo, subpath, tag: ref_part, style: Tag, sha: None, })
  } else {
    None
  }
}

///|
/// Format a GitHub Actions `uses:` reference string.
pub fn format_uses(
  repo : String,
  subpath : String,
  ref_name : String,
) -> String {
  "\{repo}\{subpath}@\{ref_name}"
}

///|
fn is_yaml_block_scalar_indicator(value_after_colon : String) -> Bool {
  let trimmed = value_after_colon.trim().to_owned()
  if trimmed.is_empty() {
    return false
  }
  let first = trimmed[0]
  if first != '|' && first != '>' {
    return false
  }
  let mut idx = 1
  while idx < trimmed.length() {
    let ch = trimmed[idx]
    if ch == '-' || ch == '+' || (ch >= '1' && ch <= '9') {
      idx += 1
    } else if ch == ' ' || ch == '\t' {
      let rest = trimmed[idx:].trim()
      return rest.is_empty() || rest.has_prefix("#")
    } else if ch == '#' {
      return true
    } else {
      return false
    }
  }
  true
}

///|
fn line_indent(bytes : Bytes, line_start : Int32, line_end : Int32) -> Int32 {
  let mut i = line_start
  while i < line_end && bytes[i] == b' ' {
    i += 1
  }
  i - line_start
}

///|
fn is_blank_or_comment_line(
  bytes : Bytes,
  line_start : Int32,
  line_end : Int32,
) -> Bool {
  let mut i = line_start
  while i < line_end && (bytes[i] == b' ' || bytes[i] == b'\t') {
    i += 1
  }
  i >= line_end || bytes[i] == b'#'
}

///|
fn skip_hws(bytes : Bytes, start : Int32, end : Int32) -> Int32 {
  let mut i = start
  while i < end && (bytes[i] == b' ' || bytes[i] == b'\t') {
    i += 1
  }
  i
}

///|
fn matches_uses_key(bytes : Bytes, pos : Int32, end : Int32) -> Int32? {
  if pos + 4 <= end &&
    bytes[pos] == b'u' &&
    bytes[pos + 1] == b's' &&
    bytes[pos + 2] == b'e' &&
    bytes[pos + 3] == b's' {
    let after_key = skip_hws(bytes, pos + 4, end)
    if after_key < end && bytes[after_key] == b':' {
      if after_key + 1 == end ||
        bytes[after_key + 1] == b' ' ||
        bytes[after_key + 1] == b'\t' {
        return Some(after_key + 1)
      }
    }
  }
  None
}

///|
fn parse_uses_on_slice(
  source : Bytes,
  value_start_hint : Int32,
  limit : Int32,
  in_flow : Bool,
) -> (String, Int32, Int32, Char?, (Int32, Int32, String)?)? {
  let val_start = skip_hws(source, value_start_hint, limit)
  if val_start >= limit || source[val_start] == b'#' {
    return None
  }
  if source[val_start] == b'\'' || source[val_start] == b'"' {
    let quote_byte = source[val_start]
    let quote_char = if quote_byte == b'\'' { '\'' } else { '"' }
    let mut i = val_start + 1
    let mut closed = false
    while i < limit {
      if quote_byte == b'"' && source[i] == b'\\' {
        i += 2
        continue
      }
      if quote_byte == b'\'' &&
        source[i] == b'\'' &&
        i + 1 < limit &&
        source[i + 1] == b'\'' {
        i += 2
        continue
      }
      if source[i] == quote_byte {
        closed = true
        break
      }
      i += 1
    }
    if !closed {
      return None
    }
    let val_end = i + 1
    let raw_value = @utf8.decode_lossy(
      source.exact_view(start=val_start + 1, end=i),
    )
    let comment = if in_flow {
      None
    } else {
      let after = skip_hws(source, val_end, limit)
      if after < limit && source[after] == b'#' {
        let comment_text = @utf8.decode_lossy(
          source.exact_view(start=after, end=limit),
        )
        Some((after, limit, comment_text))
      } else {
        None
      }
    }
    return Some((raw_value, val_start, val_end, Some(quote_char), comment))
  }
  let mut i = val_start
  let mut comment_start : Int32? = None
  while i < limit {
    let b = source[i]
    if in_flow && (b == b',' || b == b'}') {
      break
    }
    if b == b'#' &&
      i > val_start &&
      (source[i - 1] == b' ' || source[i - 1] == b'\t') {
      comment_start = Some(i)
      break
    }
    i += 1
  }
  let mut val_end = i
  while val_end > val_start &&
        (source[val_end - 1] == b' ' || source[val_end - 1] == b'\t') {
    val_end -= 1
  }
  if val_end <= val_start {
    return None
  }
  let raw_value = @utf8.decode_lossy(
    source.exact_view(start=val_start, end=val_end),
  )
  let comment = match comment_start {
    Some(cs) => {
      let comment_text = @utf8.decode_lossy(
        source.exact_view(start=cs, end=limit),
      )
      Some((cs, limit, comment_text))
    }
    None => None
  }
  Some((raw_value, val_start, val_end, None, comment))
}

///|
/// Parse GitHub Actions `uses:` entries from a YAML byte snapshot losslessly.
pub fn parse_github_actions_manifest(
  source : Bytes,
  path~ : String,
) -> ParseResult {
  let diagnostics : Array[Diagnostic] = []
  if (source.length() >= 2 && source[0] == 0xff && source[1] == 0xfe) ||
    (source.length() >= 2 && source[0] == 0xfe && source[1] == 0xff) {
    diagnostics.push(
      diagnostic(
        "invalid_manifest",
        "workflow file must be UTF-8",
        Some(path),
        None,
        None,
        None,
      ),
    )
    return { manifest: None, diagnostics, }
  }
  ignore(
    @utf8.decode(source) catch {
      _ => {
        diagnostics.push(
          diagnostic(
            "invalid_manifest",
            "workflow file must be valid UTF-8",
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
  let dependencies : Array[Dependency] = []
  let mut pos = if source.length() >= 3 &&
    source[0] == 0xef &&
    source[1] == 0xbb &&
    source[2] == 0xbf {
    3
  } else {
    0
  }
  let mut block_scalar_parent_indent : Int32? = None
  while pos < source.length() {
    let line_start = pos
    while pos < source.length() && source[pos] != b'\n' {
      pos += 1
    }
    let line_end = if pos > line_start && source[pos - 1] == b'\r' {
      pos - 1
    } else {
      pos
    }
    if pos < source.length() && source[pos] == b'\n' {
      pos += 1
    }
    if is_blank_or_comment_line(source, line_start, line_end) {
      continue
    }
    let indent = line_indent(source, line_start, line_end)
    if block_scalar_parent_indent is Some(parent_indent) {
      if indent > parent_indent {
        continue
      } else {
        block_scalar_parent_indent = None
      }
    }
    let mut cursor = line_start + indent
    if cursor + 1 < line_end &&
      source[cursor] == b'-' &&
      (source[cursor + 1] == b' ' || source[cursor + 1] == b'\t') {
      cursor = skip_hws(source, cursor + 1, line_end)
    }
    // Check direct `uses:` mapping key on this line.
    if matches_uses_key(source, cursor, line_end) is Some(after_colon) {
      match parse_uses_on_slice(source, after_colon, line_end, false) {
        Some((raw_value, val_start, val_end, quote, comment)) => {
          let comment_text = comment.map(c => c.2)
          if parse_uses(raw_value, comment=comment_text) is Some(parsed) {
            let (line, column) = line_column(source, val_start)
            let value_span : SourceSpan = {
              start: val_start,
              end: val_end,
              line,
              column,
            }
            let comment_span = comment.map(c => {
              let (cl, cc) = line_column(source, c.0)
              { start: c.0, end: c.1, line: cl, column: cc, }
            })
            dependencies.push({
              module_name: path,
              manifest: path,
              name: parsed.repo,
              version: parsed.tag,
              source: GitHubActions,
              span: value_span,
              gha: Some({
                repo: parsed.repo,
                subpath: parsed.subpath,
                style: parsed.style,
                sha: parsed.sha,
                value_span,
                quote,
                comment_span,
              }),
            })
          }
        }
        None => ()
      }
      continue
    }
    // Check inline flow mapping `{ ..., uses: ... }`.
    if cursor < line_end && source[cursor] == b'{' {
      let mut scan = cursor + 1
      while scan < line_end {
        if source[scan] == b'\'' || source[scan] == b'"' {
          let q = source[scan]
          scan += 1
          while scan < line_end {
            if q == b'"' && source[scan] == b'\\' {
              scan += 2
              continue
            }
            if source[scan] == q {
              scan += 1
              break
            }
            scan += 1
          }
          continue
        }
        let prev_ok = scan == cursor + 1 ||
          source[scan - 1] == b'{' ||
          source[scan - 1] == b',' ||
          source[scan - 1] == b' ' ||
          source[scan - 1] == b'\t'
        if prev_ok &&
          matches_uses_key(source, scan, line_end) is Some(after_colon) {
          if parse_uses_on_slice(source, after_colon, line_end, true)
            is Some((raw_value, val_start, val_end, quote, _)) {
            if parse_uses(raw_value) is Some(parsed) {
              let (line, column) = line_column(source, val_start)
              let value_span : SourceSpan = {
                start: val_start,
                end: val_end,
                line,
                column,
              }
              dependencies.push({
                module_name: path,
                manifest: path,
                name: parsed.repo,
                version: parsed.tag,
                source: GitHubActions,
                span: value_span,
                gha: Some({
                  repo: parsed.repo,
                  subpath: parsed.subpath,
                  style: parsed.style,
                  sha: parsed.sha,
                  value_span,
                  quote,
                  comment_span: None,
                }),
              })
            }
          }
        }
        scan += 1
      }
      continue
    }
    // Detect YAML block scalar introduction (`key: |`, `key: >-`, etc.) so
    // embedded script contents (e.g. `run: |`) are skipped safely.
    let line_text = @utf8.decode_lossy(
      source.exact_view(start=cursor, end=line_end),
    )
    if line_text.split_once(":") is Some((_, rhs)) {
      if is_yaml_block_scalar_indicator(rhs.to_owned()) {
        block_scalar_parent_indent = Some(indent)
      }
    }
  }
  let manifest : Manifest = {
    kind: GitHubActions,
    module_name: path,
    path,
    source,
    dependencies,
  }
  { manifest: Some(manifest), diagnostics, }
}

///|
fn wrap_yaml_scalar(value : String, quote : Char?) -> String {
  match quote {
    Some('\'') => "'\{value}'"
    Some('"') => "\"\{value}\""
    _ => value
  }
}

///|
/// Apply lossless span replacements to a GitHub Actions workflow/action file.
fn patch_gha_manifest(
  snapshot : Manifest,
  updates : Array[(Dependency, String, String?)],
  configured_style : GitHubActionStyle,
) -> (Bytes, Int32) raise {
  let edits : Array[(Int32, Int32, String)] = []
  let mut changed = 0
  for item in updates {
    let (dep, target_tag, target_sha) = item
    guard dep.gha is Some(info) else { continue }
    let effective_style = match configured_style {
      Auto => info.style
      explicit => explicit
    }
    match effective_style {
      Sha =>
        match target_sha {
          None => continue
          Some(sha) => {
            let formatted = wrap_yaml_scalar(
              format_uses(info.repo, info.subpath, sha),
              info.quote,
            )
            let end_offset = match info.comment_span {
              Some(cspan) => cspan.end
              None => info.value_span.end
            }
            edits.push(
              (
                info.value_span.start,
                end_offset,
                "\{formatted} # \{target_tag}",
              ),
            )
            changed += 1
          }
        }
      Tag | Auto => {
        let formatted = wrap_yaml_scalar(
          format_uses(info.repo, info.subpath, target_tag),
          info.quote,
        )
        let end_offset = match info.comment_span {
          Some(cspan) if info.style == Sha => cspan.end
          _ => info.value_span.end
        }
        edits.push((info.value_span.start, end_offset, formatted))
        changed += 1
      }
    }
  }
  if edits.is_empty() {
    return (snapshot.source, 0)
  }
  edits.sort_by((a, b) => {
    if a.0 != b.0 {
      a.0.compare(b.0)
    } else {
      a.1.compare(b.1)
    }
  })
  let source_len = snapshot.source.length()
  let mut previous_end = 0
  for edit in edits {
    let (start, end, _) = edit
    if start < previous_end || start < 0 || end < start || end > source_len {
      write_error(
        "invalid_selection", "invalid or overlapping GitHub Actions spans",
      )
    }
    previous_end = end
  }
  let buf = Buffer(capacity=source_len)
  let mut cursor = 0
  for edit in edits {
    let (start, end, replacement) = edit
    buf
    ..write_bytesview(snapshot.source.exact_view(start=cursor, end=start))
    .write_string_utf8(replacement)
    cursor = end
  }
  buf.write_bytesview(snapshot.source.exact_view(start=cursor))
  (buf.to_bytes(), changed)
}
