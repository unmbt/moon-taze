///|
/// A member declared by a `moon.work` file.
pub struct WorkspaceMember {
  pub directory : String
  pub manifest : Manifest
  pub module_name : String
} derive(Debug, Eq)

///|
/// A read-only workspace snapshot. The source bytes are retained for stale-plan
/// checks by callers that choose to apply a combined plan.
pub struct Workspace {
  pub root : String
  pub path : String
  pub source : Bytes
  pub members : Array[WorkspaceMember]
} derive(Debug, Eq)

///|
pub struct WorkspaceParseResult {
  pub workspace : Workspace?
  pub diagnostics : Array[Diagnostic]
} derive(Debug, Eq)

///|
fn workspace_string_values(source : Bytes) -> (Array[String], Bool) {
  let values : Array[String] = []
  let mut body_start : Int? = None
  let mut index = 0
  while index + 1 < source.length() {
    if source[index] == b'/' && source[index + 1] == b'/' {
      index += 2
      while index < source.length() && source[index] != b'\n' {
        index += 1
      }
      continue
    }
    if source[index] == b'/' && source[index + 1] == b'*' {
      index += 2
      while index + 1 < source.length() &&
            !(source[index] == b'*' && source[index + 1] == b'/') {
        index += 1
      }
      index += 2
      continue
    }
    if source[index] == b'{' {
      body_start = Some(index)
      break
    }
    index += 1
  }
  match body_start {
    None => (values, false)
    Some(start_body) => {
      let end_body = find_matching_brace(source, start_body).unwrap_or(
        source.length(),
      )
      index = start_body + 1
      while index < end_body {
        if source[index] == b'/' &&
          index + 1 < end_body &&
          source[index + 1] == b'/' {
          index += 2
          while index < end_body && source[index] != b'\n' {
            index += 1
          }
          continue
        }
        if source[index] == b'/' &&
          index + 1 < end_body &&
          source[index + 1] == b'*' {
          index += 2
          while index + 1 < end_body &&
                !(source[index] == b'*' && source[index + 1] == b'/') {
            index += 1
          }
          index += 2
          continue
        }
        if source[index] == b'"' {
          let string_start = index
          index += 1
          let mut escaped = false
          while index < end_body {
            if escaped {
              escaped = false
            } else if source[index] == b'\\' {
              escaped = true
            } else if source[index] == b'"' {
              break
            }
            index += 1
          }
          if index < end_body {
            match decode_string(source, string_start, index) {
              Some(value) => values.push(value)
              None => ()
            }
          }
        }
        index += 1
      }
      (values, true)
    }
  }
}

///|
/// Read and parse a MoonBit workspace. Members are explicit directories; no
/// glob expansion is performed.
pub async fn read_workspace(path : String) -> WorkspaceParseResult {
  let data = @fs.read_file(path) catch {
    error =>
      return {
        workspace: None,
        diagnostics: [
          diagnostic(
            "workspace_read_error",
            error.to_string(),
            Some(path),
            None,
            None,
            None,
          ),
        ],
      }
  }
  let source = data.binary()
  let root = match path.rev_split_once("/") {
    Some((left, _)) => if left == "" { "/" } else { left.to_owned() }
    None =>
      match path.rev_split_once("\\") {
        Some((left, _)) =>
          if left.length() == 2 {
            left.to_owned() + "\\"
          } else {
            left.to_owned()
          }
        None => "."
      }
  }
  let (paths, has_block) = workspace_string_values(source)
  if !has_block || paths.is_empty() {
    return {
      workspace: None,
      diagnostics: [
        diagnostic(
          "invalid_workspace",
          "moon.work must contain a non-empty workspace block",
          Some(path),
          None,
          None,
          None,
        ),
      ],
    }
  }
  let members : Array[WorkspaceMember] = []
  let diagnostics : Array[Diagnostic] = []
  let names : Map[String, String] = Map([])
  for relative in paths {
    if relative == "" ||
      relative.has_prefix("/") ||
      relative.has_prefix("\\") ||
      (relative.length() >= 2 && relative[1] == ':') {
      diagnostics.push(
        diagnostic(
          "invalid_workspace_member",
          "workspace member must be a relative directory: {relative}",
          Some(path),
          Some(relative),
          None,
          None,
        ),
      )
      continue
    }
    let directory = root + "/" + relative
    let manifest_path = directory + "/moon.mod"
    if !@fs.exists(manifest_path) {
      diagnostics.push(
        diagnostic(
          "workspace_member_missing",
          "workspace member has no moon.mod: {relative}",
          Some(path),
          Some(relative),
          None,
          None,
        ),
      )
      continue
    }
    let old_path = directory + "/moon.mod.json"
    if @fs.exists(old_path) {
      diagnostics.push(
        diagnostic(
          "ambiguous_manifest",
          "workspace member contains moon.mod and moon.mod.json",
          Some(manifest_path),
          None,
          None,
          None,
        ),
      )
      continue
    }
    let bytes = @fs.read_file(manifest_path) catch {
      error => {
        diagnostics.push(
          diagnostic(
            "manifest_read_error",
            error.to_string(),
            Some(manifest_path),
            None,
            None,
            None,
          ),
        )
        continue
      }
    }
    let module_name = module_name_from_source(bytes.binary())
    let parsed = parse_manifest(
      bytes.binary(),
      path=manifest_path,
      module_name~,
    )
    for item in parsed.diagnostics {
      diagnostics.push(item)
    }
    match parsed.manifest {
      None => ()
      Some(manifest) =>
        if names.contains(manifest.module_name) {
          diagnostics.push(
            diagnostic(
              "duplicate_workspace_module",
              "workspace contains duplicate module name: {manifest.module_name}",
              Some(manifest_path),
              Some(manifest.module_name),
              None,
              None,
            ),
          )
        } else {
          names[manifest.module_name] = manifest_path
          members.push({
            directory,
            manifest,
            module_name: manifest.module_name,
          })
        }
    }
  }
  if has_error_diagnostics(diagnostics) {
    { workspace: None, diagnostics, }
  } else {
    { workspace: Some({ root, path, source, members, }), diagnostics, }
  }
}
