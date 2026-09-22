///|
fn usage() -> String {
  let text =
    #|moon-taze [default|major|minor|patch|latest|stable] [options]
    #|
    #|Read-only P1a options: -C/--cwd, -a/--all, -l/--include-locked, -n/--include, -x/--exclude, -h/--help, --version.
    #|Write, workspace, recursive, JSON, cache, time and TUI options are not yet supported.
  text
}

///|
#cfg(target="native")
extern "C" fn terminate_process(code : Int) = "exit"

///|
#cfg(target="native")
fn cli_error(message : String) -> Unit {
  println(message)
  terminate_process(2)
}

///|
#cfg(not(target="native"))
fn cli_error(message : String) -> Unit {
  fail(message)
}

///|
fn parent_path(path : String) -> String? {
  let mut index = path.length() - 1
  while index >= 0 {
    let c = path[index]
    if c == '/' || c == '\\' {
      if index == 0 {
        return Some(path[:1].to_owned())
      }
      return Some(path[:index].to_owned())
    }
    index -= 1
  }
  None
}

///|
async fn has_git_boundary(path : String) -> Bool {
  @fs.exists(path + "\\.git") || @fs.exists(path + "/.git")
}

///|
async fn find_legacy_manifest(start : String) -> String? {
  let candidate = start + "\\moon.mod.json"
  if @fs.exists(candidate) {
    return Some(candidate)
  }
  let candidate_slash = start + "/moon.mod.json"
  if @fs.exists(candidate_slash) {
    return Some(candidate_slash)
  }
  if has_git_boundary(start) {
    return None
  }
  match parent_path(start) {
    None => None
    Some(parent) =>
      if parent == start {
        None
      } else {
        find_legacy_manifest(parent)
      }
  }
}

///|
async fn find_manifest(start : String) -> String? {
  let candidate = start + "\\moon.mod"
  if @fs.exists(candidate) {
    return Some(candidate)
  }
  let candidate_slash = start + "/moon.mod"
  if @fs.exists(candidate_slash) {
    return Some(candidate_slash)
  }
  // A legacy manifest is a module boundary for discovery.  Stop here so a
  // parent moon.mod cannot silently win over the nearest unsupported project.
  if @fs.exists(start + "\\moon.mod.json") ||
    @fs.exists(start + "/moon.mod.json") {
    return None
  }
  if has_git_boundary(start) {
    return None
  }
  match parent_path(start) {
    None => None
    Some(parent) => if parent == start { None } else { find_manifest(parent) }
  }
}

///|
async fn find_workspace(start : String) -> String? {
  let candidate = start + "\\moon.work"
  if @fs.exists(candidate) {
    return Some(candidate)
  }
  let candidate_slash = start + "/moon.work"
  if @fs.exists(candidate_slash) {
    return Some(candidate_slash)
  }
  if has_git_boundary(start) {
    return None
  }
  match parent_path(start) {
    None => None
    Some(parent) => if parent == start { None } else { find_workspace(parent) }
  }
}

///|
fn module_name_from_source(source : Bytes) -> String {
  let text = if source.length() >= 3 &&
    source[0] == 0xef &&
    source[1] == 0xbb &&
    source[2] == 0xbf {
    @utf8.decode_lossy(source[3:])
  } else {
    @utf8.decode_lossy(source)
  }
  for line in text.split("\n") {
    let line = line.trim().to_owned()
    if line.has_prefix("name") &&
      (
        line.length() == 4 ||
        line[4] == ' ' ||
        line[4] == '\t' ||
        line[4] == '='
      ) {
      match line.split_once("=") {
        Some((_, right)) => {
          let value = right.trim()
          if value.length() >= 2 && value[0] == '"' {
            let mut index = 1
            let mut escaped = false
            while index < value.length() {
              if escaped {
                escaped = false
              } else if value[index] == '\\' {
                escaped = true
              } else if value[index] == '"' {
                return value[1:index].to_owned()
              }
              index += 1
            }
          }
        }
        None => ()
      }
    }
  }
  ""
}

///|
fn mode_name(mode : @taze.UpdateMode) -> String {
  match mode {
    Default => "default"
    Major => "major"
    Minor => "minor"
    Patch => "patch"
    Latest => "latest"
    Stable => "stable"
    Newest => "newest"
    Next => "next"
  }
}

///|
fn parse_mode(name : String) -> @taze.UpdateMode? {
  match name {
    "default" => Some(@taze.UpdateMode::Default)
    "major" => Some(@taze.UpdateMode::Major)
    "minor" => Some(@taze.UpdateMode::Minor)
    "patch" => Some(@taze.UpdateMode::Patch)
    "latest" => Some(@taze.UpdateMode::Latest)
    "stable" => Some(@taze.UpdateMode::Stable)
    _ => None
  }
}

///|
fn append_selectors(target : Array[String], value : String) -> Unit {
  for item in value.split(",") {
    let selector = item.trim().to_owned()
    if selector != "" {
      target.push(selector)
    }
  }
}

///|
async fn main {
  let args = @env.args()
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage())
    return
  }
  if args.length() == 2 && args[1] == "--version" {
    println("moon-taze 0.1.0-p1a")
    return
  }
  let mut mode = @taze.UpdateMode::Default
  let mut cwd = @env.current_dir().unwrap_or(".")
  let mut show_all = false
  let include : Array[String] = []
  let exclude : Array[String] = []
  let mut mode_seen = false
  let mut index = 1
  while index < args.length() {
    let arg = args[index]
    if arg == "-a" || arg == "--all" {
      show_all = true
    } else if arg == "-l" || arg == "--include-locked" {
      // Bare versions are already part of the read-only P1a input.
      ()
    } else if arg == "-n" ||
      arg == "--include" ||
      arg == "-x" ||
      arg == "--exclude" {
      if index + 1 >= args.length() {
        cli_error("missing value for \{arg}")
      }
      index += 1
      if arg == "-n" || arg == "--include" {
        append_selectors(include, args[index])
      } else {
        append_selectors(exclude, args[index])
      }
    } else if arg == "-w" ||
      arg == "--write" ||
      arg == "-r" ||
      arg == "--recursive" ||
      arg == "--json" ||
      arg == "-I" ||
      arg == "--interactive" {
      cli_error("unsupported option in P1a: \{arg}")
    } else if arg == "-C" || arg == "--cwd" {
      if index + 1 >= args.length() {
        cli_error("missing value for \{arg}")
      }
      index += 1
      cwd = args[index]
    } else if arg.has_prefix("-") {
      cli_error("unknown option: \{arg}")
    } else if !mode_seen {
      match parse_mode(arg) {
        Some(value) => {
          mode = value
          mode_seen = true
        }
        None => cli_error("unknown update mode: \{arg}")
      }
    } else {
      cli_error("unexpected argument: \{arg}")
    }
    index += 1
  }
  cwd = @fs.realpath(cwd) catch { _ => cwd }
  let manifest_path = match find_manifest(cwd) {
    Some(path) => {
      let manifest_dir = parent_path(path).unwrap_or(cwd)
      let old_path = manifest_dir + "\\moon.mod.json"
      let old_path_slash = manifest_dir + "/moon.mod.json"
      if @fs.exists(old_path) || @fs.exists(old_path_slash) {
        cli_error("ambiguous_manifest: both moon.mod and moon.mod.json exist")
        return
      }
      path
    }
    None => {
      match find_legacy_manifest(cwd) {
        Some(path) =>
          cli_error(
            "unsupported_manifest: moon.mod.json is not supported at \{path}",
          )
        None => cli_error("no_manifest: no moon.mod found from \{cwd}")
      }
      return
    }
  }
  match find_workspace(cwd) {
    Some(workspace) => {
      cli_error("workspace_not_supported_yet: \{workspace}")
      return
    }
    None => ()
  }
  let data = @fs.read_file(manifest_path) catch {
    error => {
      cli_error("manifest_read_error: \{error}")
      return
    }
  }
  let source = data.binary()
  let module_name = module_name_from_source(source)
  let plan = @taze.check_path_filtered(
    manifest_path,
    module_name~,
    mode~,
    include~,
    exclude~,
  )
  for diagnostic in plan.diagnostics {
    let level = match diagnostic.severity {
      Warning => "warning"
      Error => "error"
    }
    println("\{level}[\{diagnostic.code}]: \{diagnostic.message}")
  }
  for change in plan.changes {
    match change.status {
      UpdateAvailable => {
        let target = change.target.unwrap_or("?")
        let mode_text = mode_name(change.mode)
        println(
          "\{change.dependency.name} \{change.dependency.version} -> \{target} (\{mode_text})",
        )
      }
      UpToDate =>
        if show_all {
          println(
            "\{change.dependency.name} \{change.dependency.version} up-to-date",
          )
        }
      NoCandidate => println("\{change.dependency.name} no candidate")
      Skipped =>
        if show_all {
          let reason = change.reason.unwrap_or("filtered")
          println("\{change.dependency.name} skipped (\{reason})")
        }
      Error => ()
    }
  }
  if plan.has_errors {
    cli_error("check failed")
  }
}
