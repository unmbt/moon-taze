///|
/// A member declared by a `moon.work` file.
#derive(Eq, Debug)
pub struct WorkspaceMember {
  directory : String
  manifest : Manifest
  module_name : String
}

///|
/// A read-only workspace snapshot.
#derive(Eq, Debug)
pub struct Workspace {
  root : String
  path : String
  source : Bytes
  members : Array[WorkspaceMember]
}

///|
#derive(Eq, Debug)
pub struct WorkspaceParseResult {
  workspace : Workspace?
  diagnostics : Array[Diagnostic]
}

///|
fn workspace_string_values(source : Bytes) -> (Array[String], Bool) {
  let document = @moon_manifest.parse(
    Work,
    @utf8.decode_lossy(source),
    path="moon.work",
  )
  (document.members(), document.diagnostics.is_empty())
}

///|
/// Read and parse a MoonBit workspace (`moon.work`).
pub async fn read_workspace(path : String) -> WorkspaceParseResult {
  let source = @fs.read_binary(path) catch {
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
  let (paths, valid) = workspace_string_values(source)
  if !valid || paths.is_empty() {
    return {
      workspace: None,
      diagnostics: [
        diagnostic(
          "invalid_workspace",
          "moon.work must contain a non-empty members array",
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
          "workspace member must be a relative directory: \{relative}",
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
          "workspace member has no moon.mod: \{relative}",
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
    let bytes = @fs.read_binary(manifest_path) catch {
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
    let module_name = module_name_from_source(bytes)
    let parsed = parse_manifest(bytes, path=manifest_path, module_name~)
    diagnostics.append(parsed.diagnostics)
    match parsed.manifest {
      None => ()
      Some(manifest) =>
        if names.contains(manifest.module_name) {
          diagnostics.push(
            diagnostic(
              "duplicate_workspace_module",
              "workspace contains duplicate module name: \{manifest.module_name}",
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
