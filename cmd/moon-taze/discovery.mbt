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
  if @fs.exists(start + "\\moon.mod.json") ||
    @fs.exists(start + "/moon.mod.json") {
    return None
  }
  if @fs.exists(start + "\\moon.work") || @fs.exists(start + "/moon.work") {
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
fn is_ignored_dir(path : String) -> Bool {
  let normalized = path.replace_all(old="\\", new="/")
  normalized.contains("/_build") ||
  normalized.contains("/.git/") ||
  normalized.has_suffix("/.git") ||
  normalized.contains("/.mooncakes") ||
  normalized.contains("/node_modules") ||
  normalized.contains("/target")
}

///|
async fn discover_github_actions_paths(
  root : String,
  recursive~ : Bool,
) -> Array[String] {
  let found : Array[String] = []
  let seen : Map[String, Unit] = Map([])
  fn add_if_new(path : String) {
    let key = path.replace_all(old="\\", new="/")
    if !seen.contains(key) {
      seen[key] = ()
      found.push(path)
    }
  }
  if recursive {
    @fs.walk(
      root,
      (directory, files) => {
        if is_ignored_dir(directory) {
          return
        }
        for name in files {
          let full = directory + "/" + name
          if @taze.is_github_actions_path(full) {
            add_if_new(full)
          }
        }
      },
      max_concurrency=1,
    ) catch {
      _ => ()
    }
  } else {
    // Non-recursive: `.github/workflows/*.{yml,yaml}`, `.github/actions/**/action.{yml,yaml}`,
    // and top-level `action.{yml,yaml}`.
    let workflows_dir = root + "/.github/workflows"
    if @fs.exists(workflows_dir) {
      let entries = @fs.readdir(workflows_dir, sort=true) catch { _ => [] }
      for name in entries {
        let lower = name.to_lower()
        if lower.has_suffix(".yml") || lower.has_suffix(".yaml") {
          add_if_new(workflows_dir + "/" + name)
        }
      }
    }
    let actions_dir = root + "/.github/actions"
    if @fs.exists(actions_dir) {
      @fs.walk(
        actions_dir,
        (directory, files) => {
          for name in files {
            let lower = name.to_lower()
            if lower == "action.yml" || lower == "action.yaml" {
              add_if_new(directory + "/" + name)
            }
          }
        },
        max_concurrency=1,
      ) catch {
        _ => ()
      }
    }
    for name in ["action.yml", "action.yaml"] {
      let candidate = root + "/" + name
      if @fs.exists(candidate) {
        add_if_new(candidate)
      }
    }
  }
  found.sort()
  found
}
