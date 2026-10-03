///|
fn usage() -> String {
  let text =
    #|moon-taze [default|major|minor|patch|latest|stable|newest|next] [options]
    #|
    #|Options: -C/--cwd, -w/--write, -I/--interactive, -a/--all, -r/--recursive, --json, --silent, --group/--no-group, --sort, --timediff/--no-timediff, --maturity-period, --maturity-period-exclude, --verify, --fail-on-outdated, --retry, --no-retry, -f/--force, --no-force, -l/--include-locked, -n/--include, -x/--exclude, -h/--help, -V/--version.
    #|Default is read-only. --write applies all recommended updates to one moon.mod.
    #|--interactive selects dependencies and candidates, then confirms before applying.
  text
}

///|
fn app_version() -> String {
  let marker = "version = \""
  guard moon_mod.find(marker) is Some(start) else { return "unknown" }
  let rest = moon_mod[start + marker.length():]
  guard rest.find("\"") is Some(length) else { return "unknown" }
  rest[:length].to_owned()
}

///|
#cfg(target="native")
extern "C" fn terminate_process(code : Int) = "exit"

///|
#cfg(target="native")
extern "C" fn moon_taze_stdin_isatty() -> Bool = "moon_taze_stdin_isatty"

///|
#cfg(target="native")
fn interactive_terminal_available() -> Bool {
  moon_taze_stdin_isatty()
}

///|
priv suberror CliError {
  CliError(String)
}

///|
fn cli_error(message : String) -> Unit raise {
  raise CliError(message)
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
  // A workspace root is its own discovery boundary even when it does not
  // contain a root moon.mod; its explicit members become the check scope.
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
    "newest" => Some(@taze.UpdateMode::Newest)
    "next" => Some(@taze.UpdateMode::Next)
    _ => None
  }
}

///|
fn diff_rank(value : @taze.DiffKind?) -> Int {
  match value {
    None => 0
    Some(Prerelease) => 1
    Some(Patch) => 2
    Some(Minor) => 3
    Some(Major) => 4
  }
}

///|
fn sort_changes(
  changes : Array[@taze.DependencyChange],
  sort_mode : String,
  published_at? : Map[String, Int64] = Map([]),
) -> Array[@taze.DependencyChange] {
  let result = changes.copy()
  result.sort_by((left, right) => {
    let status_rank = fn(change : @taze.DependencyChange) -> Int {
      match change.status {
        UpdateAvailable => 0
        UpToDate => 1
        NoCandidate => 2
        Skipped => 3
        Error => 4
      }
    }
    let time_key = fn(change : @taze.DependencyChange) -> Int64? {
      let version = match sort_mode {
        "time-asc" | "time-desc" =>
          change.target.unwrap_or(change.dependency.version)
        _ => return None
      }
      published_at.get(change.dependency.name + "@" + version)
    }
    let compare_time = fn(
      left_time : Int64?,
      right_time : Int64?,
      descending : Bool,
    ) -> Int {
      match (left_time, right_time) {
        (None, None) => 0
        (None, Some(_)) => 1
        (Some(_), None) => -1
        (Some(left_value), Some(right_value)) =>
          if descending {
            right_value.compare(left_value)
          } else {
            left_value.compare(right_value)
          }
      }
    }
    let comparison = match sort_mode {
      "name-asc" => left.dependency.name.compare(right.dependency.name)
      "name-desc" => right.dependency.name.compare(left.dependency.name)
      "diff-asc" => diff_rank(left.diff).compare(diff_rank(right.diff))
      "diff-desc" => diff_rank(right.diff).compare(diff_rank(left.diff))
      "time-asc" => {
        let status = status_rank(left).compare(status_rank(right))
        if status == 0 {
          compare_time(time_key(left), time_key(right), false)
        } else {
          status
        }
      }
      "time-desc" => {
        let status = status_rank(left).compare(status_rank(right))
        if status == 0 {
          compare_time(time_key(left), time_key(right), true)
        } else {
          status
        }
      }
      _ => 0
    }
    if comparison != 0 {
      comparison
    } else {
      let by_name = left.dependency.name.compare(right.dependency.name)
      if by_name != 0 {
        by_name
      } else {
        let by_manifest = left.dependency.manifest.compare(
          right.dependency.manifest,
        )
        if by_manifest != 0 {
          by_manifest
        } else {
          left.dependency.version.compare(right.dependency.version)
        }
      }
    }
  })
  result
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
fn json_text(value : String) -> Json {
  Json::string(value)
}

///|
fn json_optional(value : String?) -> Json {
  match value {
    Some(value) => json_text(value)
    None => Json::null()
  }
}

///|
fn format_time_diff(current : Int64?, target : Int64?) -> String {
  match (current, target) {
    (Some(current), Some(target)) => {
      let seconds = (target - current) / 1000
      let sign = if seconds < 0 { "-" } else { "+" }
      let magnitude = if seconds < 0 { -seconds } else { seconds }
      if magnitude >= 86400 {
        "\{sign}\{magnitude / 86400}d"
      } else if magnitude >= 3600 {
        "\{sign}\{magnitude / 3600}h"
      } else if magnitude >= 60 {
        "\{sign}\{magnitude / 60}m"
      } else {
        "\{sign}\{magnitude}s"
      }
    }
    _ => "unknown"
  }
}

///|
async fn interactive_read_line() -> String? {
  @stdio.stdin.read_until("\n") catch {
    _ => None
  }
}

///|
fn interactive_indices(line : String, count : Int) -> Array[Int] raise {
  let value = line.trim().to_owned()
  if value == "a" || value == "A" {
    let result : Array[Int] = []
    for index in 0..<count {
      result.push(index)
    }
    return result
  }
  if value == "" {
    cli_error("interactive_invalid_selection: choose at least one dependency")
  }
  let result : Array[Int] = []
  for part in value.split(",") {
    let token = part.trim().to_owned()
    let parsed = @string.parse_int(token) catch { _ => -1 }
    if parsed < 1 || parsed > count {
      cli_error(
        "interactive_invalid_selection: invalid dependency number {token}",
      )
    }
    let index = parsed - 1
    if !result.contains(index) {
      result.push(index)
    }
  }
  result
}

///|
fn interactive_target(
  change : @taze.DependencyChange,
  line : String,
) -> String? raise {
  let value = line.trim().to_owned()
  let target = change.target.unwrap_or("")
  if value == "" {
    if target == "" {
      cli_error(
        "interactive_invalid_candidate: dependency has no recommended candidate",
      )
    }
    return Some(target)
  }
  if value == "q" || value == "Q" {
    return None
  }
  let parsed = @string.parse_int(value) catch { _ => 0 }
  if parsed >= 1 && parsed <= change.candidates.length() {
    return Some(change.candidates[parsed - 1])
  }
  if change.candidates.contains(value) {
    return Some(value)
  }
  if value == target {
    return Some(value)
  }
  cli_error("interactive_invalid_candidate: invalid candidate \{value}")
  None
}

///|
/// Drive the small line-oriented TUI.  All writes remain behind the final
/// confirmation and the returned selection is still validated by `apply`.
async fn interactive_selection(
  plan : @taze.CheckPlan,
  emit~ : (String) -> Unit,
) -> @taze.Selection? {
  let changes = plan
    .changes()
    .filter(change => {
      change.status is UpdateAvailable && change.target is Some(_)
    })
  if changes.is_empty() {
    emit("No updates available")
    return None
  }
  emit("Interactive mode: available updates")
  for index, change in changes {
    let target = change.target.unwrap_or("?")
    emit(
      "\{index + 1}) \{change.dependency.name} \{change.dependency.version} -> \{target}",
    )
    if !change.candidates.is_empty() {
      emit("   candidates: \{change.candidates.join(", ")}")
    }
  }
  emit("Select dependencies (numbers separated by comma, a=all, q=cancel):")
  let selected_line = match interactive_read_line() {
    Some(value) => value
    None => {
      emit("cancelled")
      return None
    }
  }
  let trimmed = selected_line.trim().to_owned()
  if trimmed == "q" || trimmed == "Q" {
    emit("cancelled")
    return None
  }
  let selected_indices = interactive_indices(selected_line, changes.length())
  let items : Array[(String, String, String)] = []
  for index in selected_indices {
    let change = changes[index]
    let mut target = change.target.unwrap_or("")
    if change.candidates.length() > 1 {
      emit(
        "Candidate for \{change.dependency.name} (number, version, or Enter for \{target}):",
      )
      let candidate_line = match interactive_read_line() {
        Some(value) => value
        None => {
          emit("cancelled")
          return None
        }
      }
      match interactive_target(change, candidate_line) {
        Some(value) => target = value
        None => {
          emit("cancelled")
          return None
        }
      }
    }
    items.push((change.dependency.manifest, change.dependency.name, target))
  }
  if items.is_empty() {
    emit("cancelled")
    return None
  }
  emit("Apply \{items.length()} selected update(s)? [y/N]")
  let confirmation = match interactive_read_line() {
    Some(value) => value.trim().to_owned()
    None => ""
  }
  if confirmation == "y" ||
    confirmation == "Y" ||
    confirmation == "yes" ||
    confirmation == "YES" {
    Some(plan.selection(items))
  } else {
    emit("cancelled")
    None
  }
}

///|
fn json_diagnostic(value : @taze.Diagnostic) -> Json {
  let object : Map[String, Json] = Map([])
  object["severity"] = json_text(
    match value.severity {
      Warning => "warning"
      Error => "error"
    },
  )
  object["code"] = json_text(value.code)
  object["message"] = json_text(value.message)
  object["manifest"] = json_optional(value.manifest)
  object["dependency"] = json_optional(value.dependency)
  object["line"] = match value.line {
    Some(value) => Json::number(value.to_double())
    None => Json::null()
  }
  object["column"] = match value.column {
    Some(value) => Json::number(value.to_double())
    None => Json::null()
  }
  Json::object(object)
}

///|
fn json_change(
  value : @taze.DependencyChange,
  published_at? : Map[String, Int64] = Map([]),
) -> Json {
  let object : Map[String, Json] = Map([])
  object["name"] = json_text(value.dependency.name)
  object["current"] = json_text(value.dependency.version)
  object["target"] = json_optional(value.target)
  object["mode"] = json_text(mode_name(value.mode))
  object["status"] = json_text(
    match value.status {
      UpdateAvailable => "update_available"
      UpToDate => "up_to_date"
      NoCandidate => "no_candidate"
      Skipped => "skipped"
      Error => "error"
    },
  )
  object["diff"] = match value.diff {
    Some(Major) => json_text("major")
    Some(Minor) => json_text("minor")
    Some(Patch) => json_text("patch")
    Some(Prerelease) => json_text("prerelease")
    None => Json::null()
  }
  object["reason"] = json_optional(value.reason)
  object["selected"] = Json::boolean(false)
  object["applied"] = Json::boolean(false)
  let current_time = published_at.get(
    value.dependency.name + "@" + value.dependency.version,
  )
  let target_time = match value.target {
    Some(target) => published_at.get(value.dependency.name + "@" + target)
    None => None
  }
  object["currentPublishedAt"] = match current_time {
    Some(value) => Json::number(value.to_double())
    None => Json::null()
  }
  object["targetPublishedAt"] = match target_time {
    Some(value) => Json::number(value.to_double())
    None => Json::null()
  }
  object["timeDiffSeconds"] = match (current_time, target_time) {
    (Some(current), Some(target)) =>
      Json::number((target - current).to_double() / 1000.0)
    _ => Json::null()
  }
  Json::object(object)
}

///|
fn json_apply_status(value : @taze.ApplyStatus) -> String {
  match value {
    Succeeded => "succeeded"
    Failed => "failed"
    Partial => "partial"
    Cancelled => "cancelled"
  }
}

///|
fn json_file_status(value : @taze.FileApplyStatus) -> String {
  match value {
    Written => "written"
    Unchanged => "unchanged"
    Failed => "failed"
    NotAttempted => "not_attempted"
  }
}

///|
struct VerificationResult {
  path : String
  passed : Bool
  exit_code : Int
}

///|
fn render_json(
  plan : @taze.CheckPlan,
  mode : @taze.UpdateMode,
  report : @taze.ApplyReport?,
  verification : Array[VerificationResult],
  fail_on_outdated : Bool,
  published_at? : Map[String, Int64] = Map([]),
  extra_diagnostics? : Array[@taze.Diagnostic] = [],
) -> String {
  let changes = plan.changes()
  let project_paths : Array[String] = []
  for change in changes {
    if !project_paths.contains(change.dependency.manifest) {
      project_paths.push(change.dependency.manifest)
    }
  }
  project_paths.sort()
  let projects : Array[Json] = []
  for path in project_paths {
    let dependencies = changes
      .filter(change => change.dependency.manifest == path)
      .map(change => json_change(change, published_at~))
    let object : Map[String, Json] = Map([])
    object["manifest"] = json_text(path)
    let mut module_name = ""
    for change in changes {
      if change.dependency.manifest == path {
        module_name = change.dependency.module
        break
      }
    }
    object["module"] = json_text(module_name)
    object["dependencies"] = Json::array(dependencies)
    projects.push(Json::object(object))
  }
  let mut updates = 0
  let mut skipped = 0
  for change in changes {
    match change.status {
      UpdateAvailable => updates += 1
      Skipped => skipped += 1
      _ => ()
    }
  }
  let mut errors = 0
  for item in plan.diagnostics() {
    match item.severity {
      Error => errors += 1
      _ => ()
    }
  }
  let summary : Map[String, Json] = Map([])
  summary["checked"] = Json::number((changes.length() - skipped).to_double())
  summary["updates"] = Json::number(updates.to_double())
  summary["skipped"] = Json::number(skipped.to_double())
  summary["errors"] = Json::number(errors.to_double())
  summary["writtenFiles"] = Json::number(
    match report {
      Some(value) => value.written_files().to_double()
      None => 0.0
    },
  )
  let diagnostic_values = plan.diagnostics()
  diagnostic_values.append(extra_diagnostics)
  match report {
    Some(value) => diagnostic_values.append(value.diagnostics())
    None => ()
  }
  let diagnostics = diagnostic_values.map(json_diagnostic)
  let apply : Map[String, Json] = Map([])
  apply["status"] = match report {
    Some(value) => json_text(json_apply_status(value.status()))
    None => json_text("not_requested")
  }
  let files = match report {
    Some(value) =>
      value
      .files()
      .map(file => {
        let item : Map[String, Json] = Map([])
        item["manifest"] = json_text(file.manifest())
        item["status"] = json_text(json_file_status(file.status()))
        item["changedDependencies"] = Json::number(
          file.changed_dependencies().to_double(),
        )
        Json::object(item)
      })
    None => []
  }
  apply["files"] = Json::array(files)
  apply["verification"] = Json::array(
    verification.map(value => {
      let item : Map[String, Json] = Map([])
      item["path"] = json_text(value.path)
      item["status"] = json_text(if value.passed { "passed" } else { "failed" })
      item["exitCode"] = Json::number(value.exit_code.to_double())
      Json::object(item)
    }),
  )
  let root : Map[String, Json] = Map([])
  root["schemaVersion"] = Json::number(1.0)
  root["mode"] = json_text(mode_name(mode))
  let apply_error = match report {
    Some(value) =>
      match value.status() {
        Succeeded => false
        _ => true
      }
    None => false
  }
  let fail_outdated = fail_on_outdated && updates > 0
  root["status"] = json_text(
    if errors > 0 || apply_error || verification.any(item => !item.passed) {
      "error"
    } else {
      "ok"
    },
  )
  root["projects"] = Json::array(projects)
  root["summary"] = Json::object(summary)
  root["diagnostics"] = Json::array(diagnostics)
  root["apply"] = Json::object(apply)
  root["exitCode"] = Json::number(
    match report {
      Some(value) =>
        if value.exit_code() != 0 || verification.any(item => !item.passed) {
          2.0
        } else if fail_outdated {
          1.0
        } else {
          0.0
        }
      None => if errors > 0 { 2.0 } else if fail_outdated { 1.0 } else { 0.0 }
    },
  )
  Json::object(root).stringify()
}

///|
fn render_cli_error_json(message : String) -> String {
  let root : Map[String, Json] = Map([])
  root["schemaVersion"] = Json::number(1.0)
  root["mode"] = Json::null()
  root["status"] = json_text("error")
  root["projects"] = Json::array([])
  let summary : Map[String, Json] = Map([])
  summary["checked"] = Json::number(0.0)
  summary["updates"] = Json::number(0.0)
  summary["skipped"] = Json::number(0.0)
  summary["errors"] = Json::number(1.0)
  summary["writtenFiles"] = Json::number(0.0)
  root["summary"] = Json::object(summary)
  let diagnostic : Map[String, Json] = Map([])
  diagnostic["severity"] = json_text("error")
  diagnostic["code"] = json_text("cli_error")
  diagnostic["message"] = json_text(message)
  diagnostic["manifest"] = Json::null()
  diagnostic["dependency"] = Json::null()
  diagnostic["line"] = Json::null()
  diagnostic["column"] = Json::null()
  root["diagnostics"] = Json::array([Json::object(diagnostic)])
  let apply : Map[String, Json] = Map([])
  apply["status"] = json_text("not_requested")
  apply["files"] = Json::array([])
  apply["verification"] = Json::array([])
  root["apply"] = Json::object(apply)
  root["exitCode"] = Json::number(2.0)
  Json::object(root).stringify()
}

///|
fn retryable_cli_registry_error(error : @taze.RegistryError) -> Bool {
  match error {
    @taze.RegistryError::InvalidMetadata(_) => false
    @taze.RegistryError::RequestFailed(message) =>
      message == "request_timeout" ||
      message.has_prefix("HTTP 408") ||
      message.has_prefix("HTTP 429") ||
      message.has_prefix("HTTP 5")
  }
}

///|
fn retry_after_ms(error : @taze.RegistryError) -> Int? {
  match error {
    @taze.RegistryError::RequestFailed(message) =>
      match message.split_once("|retry-after-ms=") {
        Some((_, value)) =>
          Some(@string.parse_int(value.to_owned())) catch {
            _ => None
          }
        None => None
      }
    @taze.RegistryError::InvalidMetadata(_) => None
  }
}

///|
async fn verify_directory(path : String, emit~ : (String) -> Unit) -> Bool {
  let (code, _, _) = @process.collect_output("moon", ["check"], cwd=path) catch {
    error => {
      emit("error[moon_unavailable]: {error}")
      return false
    }
  }
  if code == 0 {
    true
  } else {
    emit("error[verification_failed]: moon check exited {code} in {path}")
    false
  }
}

///|
async fn fetch_with_retries(
  fetch~ : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError,
  name : String,
  retries : Int,
  delay_ms? : Int = 0,
) -> @taze.ModuleMetadata raise @taze.RegistryError {
  fetch_with_retries_attempt(fetch~, name, retries, delay_ms, 0)
}

///|
async fn fetch_with_retries_attempt(
  fetch~ : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError,
  name : String,
  retries : Int,
  delay_ms : Int,
  attempt : Int,
) -> @taze.ModuleMetadata raise @taze.RegistryError {
  fetch(name) catch {
    error => {
      if !retryable_cli_registry_error(error) || attempt >= retries {
        raise error
      }
      let retry_after = retry_after_ms(error)
      let delay = match retry_after {
        Some(value) if value >= 0 => value
        _ => {
          let mut value = delay_ms
          for _ in 0..<attempt {
            value = value * 2
          }
          value
        }
      }
      if delay > 0 {
        @async.sleep(delay) catch {
          _ => ()
        }
      }
      fetch_with_retries_attempt(fetch~, name, retries, delay_ms, attempt + 1)
    }
  }
}

///|
async fn fetch_mooncakes_version_cli(
  module : String,
  version : String,
) -> @taze.VersionMetadata? raise @taze.RegistryError {
  Some(
    @taze.query_mooncakes_version(root="https://mooncakes.io", module, version),
  )
}

///|
async fn no_version_timestamp(
  _module : String,
  _version : String,
) -> @taze.VersionMetadata? raise @taze.RegistryError {
  None
}

///|
async fn fetch_version_with_retries(
  fetch_version~ : async (String, String) -> @taze.VersionMetadata? raise @taze.RegistryError,
  module : String,
  version : String,
  retries : Int,
  delay_ms : Int,
) -> @taze.VersionMetadata? raise @taze.RegistryError {
  fetch_version_with_retries_attempt(
    fetch_version~,
    module,
    version,
    retries,
    delay_ms,
    0,
  )
}

///|
async fn fetch_version_with_retries_attempt(
  fetch_version~ : async (String, String) -> @taze.VersionMetadata? raise @taze.RegistryError,
  module : String,
  version : String,
  retries : Int,
  delay_ms : Int,
  attempt : Int,
) -> @taze.VersionMetadata? raise @taze.RegistryError {
  fetch_version(module, version) catch {
    error => {
      if !retryable_cli_registry_error(error) || attempt >= retries {
        raise error
      }
      let delay = match retry_after_ms(error) {
        Some(value) if value >= 0 => value
        _ => {
          let mut computed = delay_ms
          for _ in 0..<attempt {
            computed = computed * 2
          }
          computed
        }
      }
      if delay > 0 {
        @async.sleep(delay) catch {
          _ => ()
        }
      }
      fetch_version_with_retries_attempt(
        fetch_version~,
        module,
        version,
        retries,
        delay_ms,
        attempt + 1,
      )
    }
  }
}

///|
/// Fill the overview with detail timestamps only when a caller requested
/// time-sensitive behavior. Detail responses are shared across all consumers
/// in one CLI invocation, including missing timestamps.
async fn enrich_release_times(
  metadata : @taze.ModuleMetadata,
  fetch_version : async (String, String) -> @taze.VersionMetadata? raise @taze.RegistryError,
  detail_times : Map[String, Int64],
  detail_missing : Map[String, Bool],
  retries : Int,
  delay_ms : Int,
) -> @taze.ModuleMetadata raise @taze.RegistryError {
  let versions = metadata.versions.copy()
  for index in 0..<versions.length() {
    let item = versions[index]
    let key = metadata.module + "@" + item.version
    match item.published_at {
      Some(value) => detail_times[key] = value
      None if detail_times.contains(key) || detail_missing.contains(key) => ()
      None => {
        let timestamp = fetch_version_with_retries(
          fetch_version~,
          metadata.module,
          item.version,
          retries,
          delay_ms,
        )
        match timestamp {
          Some(value) => {
            match value.published_at {
              Some(published_at) => detail_times[key] = published_at
              None => detail_missing[key] = true
            }
            versions[index] = value
          }
          None => detail_missing[key] = true
        }
      }
    }
  }
  @taze.ModuleMetadata::ModuleMetadata(
    metadata.module,
    metadata.latest,
    versions,
  )
}

///|
async fn run_cli(
  args : Array[String],
  fetch~ : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError,
  emit~ : (String) -> Unit,
  cache? : Map[String, @taze.ModuleMetadata] = Map([]),
  cache_times? : Map[String, UInt64] = Map([]),
  cache_path? : String? = None,
  retry_delay_ms? : Int = 0,
  fetch_version? : async (String, String) -> @taze.VersionMetadata? raise @taze.RegistryError = no_version_timestamp,
  interactive_tty? : Bool? = None,
) -> Int {
  run_cli_inner(
    args,
    fetch~,
    emit~,
    cache~,
    cache_times,
    cache_path,
    retry_delay_ms,
    fetch_version,
    interactive_tty,
  ) catch {
    CliError(message) => {
      if args.any(item => item == "--json") {
        emit(render_cli_error_json(message))
      } else {
        emit(message)
      }
      2
    }
    error =>
      if @async.is_cancellation_error(error) {
        if args.any(item => item == "--json") {
          emit(render_cli_error_json("cancelled"))
        } else {
          emit("cancelled")
        }
        0
      } else {
        if args.any(item => item == "--json") {
          emit(render_cli_error_json("\{error}"))
        } else {
          emit("error: \{error}")
        }
        2
      }
  }
}

///|

///|
async fn run_cli_inner(
  args : Array[String],
  fetch~ : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError,
  emit~ : (String) -> Unit,
  cache~ : Map[String, @taze.ModuleMetadata],
  cache_times : Map[String, UInt64],
  cache_path : String?,
  retry_delay_ms : Int,
  fetch_version : async (String, String) -> @taze.VersionMetadata? raise @taze.RegistryError,
  interactive_tty : Bool?,
) -> Int {
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    emit(usage())
    return 0
  }
  if args.length() == 2 && args[1] == "-V" {
    emit(app_version())
    return 0
  }
  if args.length() == 2 && args[1] == "--version" {
    emit("moon-taze {app_version()}")
    return 0
  }
  let mut mode = @taze.UpdateMode::Default
  let mut cwd = @env.current_dir().unwrap_or(".")
  let mut show_all = false
  let mut write = false
  let mut interactive = false
  let mut json_output = false
  let mut silent = false
  let mut verify = false
  let mut retry_count = 4
  let mut retry_seen = false
  let mut force = false
  let mut force_seen = false
  let mut fail_on_outdated = false
  let mut fail_on_outdated_seen = false
  let mut maturity_days = 0
  let mut maturity_seen = false
  let mut timediff = false
  let mut timediff_seen = false
  let maturity_exclude : Array[String] = []
  let mut maturity_exclude_seen = false
  let mut recursive = false
  let mut recursive_seen = false
  let mut group_output = false
  let mut sort_mode = "name-asc"
  let mut all_seen = false
  let include : Array[String] = []
  let exclude : Array[String] = []
  let mut mode_seen = false
  let mut index = 1
  while index < args.length() {
    let arg = args[index]
    if arg == "-a" || arg == "--all" {
      show_all = true
      all_seen = true
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
    } else if arg == "-w" || arg == "--write" {
      write = true
    } else if arg == "-I" || arg == "--interactive" {
      interactive = true
    } else if arg == "-r" || arg == "--recursive" {
      recursive = true
      recursive_seen = true
    } else if arg == "--json" {
      json_output = true
    } else if arg == "--silent" || arg == "-s" {
      silent = true
    } else if arg == "--group" || arg == "--no-group" {
      group_output = arg == "--group"
    } else if arg == "--sort" {
      if index + 1 >= args.length() {
        cli_error("missing value for --sort")
      }
      index += 1
      match args[index] {
        "diff-asc"
        | "diff-desc"
        | "name-asc"
        | "name-desc"
        | "time-asc"
        | "time-desc" => sort_mode = args[index]
        _ => cli_error("invalid sort value: {args[index]}")
      }
    } else if arg == "--verify" {
      verify = true
    } else if arg == "--force" || arg == "-f" {
      force = true
      force_seen = true
    } else if arg == "--no-force" {
      force = false
      force_seen = true
    } else if arg == "--fail-on-outdated" {
      fail_on_outdated = true
      fail_on_outdated_seen = true
    } else if arg == "--no-fail-on-outdated" {
      fail_on_outdated = false
      fail_on_outdated_seen = true
    } else if arg == "--timediff" {
      timediff = true
      timediff_seen = true
    } else if arg == "--no-timediff" {
      timediff = false
      timediff_seen = true
    } else if arg == "--maturity-period" {
      maturity_seen = true
      if index + 1 < args.length() && !args[index + 1].has_prefix("-") {
        index += 1
        maturity_days = @string.parse_int(args[index]) catch { _ => -1 }
        if maturity_days < 0 {
          cli_error("invalid maturity period: \{args[index]}")
        }
      } else {
        maturity_days = 7
      }
    } else if arg == "--maturity-period-exclude" {
      if index + 1 >= args.length() {
        cli_error("missing value for --maturity-period-exclude")
      }
      index += 1
      append_selectors(maturity_exclude, args[index])
      maturity_exclude_seen = true
    } else if arg == "--no-retry" {
      retry_count = 0
      retry_seen = true
    } else if arg == "--retry" {
      if index + 1 >= args.length() {
        cli_error("missing value for --retry")
      }
      index += 1
      retry_count = @string.parse_int(args[index]) catch { _ => -1 }
      if retry_count < 0 {
        cli_error("invalid retry count: \{args[index]}")
      }
      retry_seen = true
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
  // Machine-readable output must never block on a terminal prompt.
  if json_output {
    interactive = false
  }
  if interactive {
    match interactive_tty {
      Some(true) => ()
      _ => cli_error("interactive_requires_tty: --interactive requires a TTY")
    }
  }
  cwd = @fs.realpath(cwd) catch { _ => cwd }
  let manifest_path = match find_manifest(cwd) {
    Some(path) => {
      let manifest_dir = parent_path(path).unwrap_or(cwd)
      let old_path = manifest_dir + "\\moon.mod.json"
      let old_path_slash = manifest_dir + "/moon.mod.json"
      if @fs.exists(old_path) || @fs.exists(old_path_slash) {
        cli_error("ambiguous_manifest: both moon.mod and moon.mod.json exist")
        return 2
      }
      path
    }
    None =>
      match find_workspace(cwd) {
        Some(workspace) => workspace + "/moon.work"
        None =>
          match find_legacy_manifest(cwd) {
            Some(path) => {
              cli_error(
                "unsupported_manifest: moon.mod.json is not supported at \{path}",
              )
              ""
            }
            None => {
              cli_error("no_manifest: no moon.mod found from \{cwd}")
              ""
            }
          }
      }
  }
  let workspace_path = find_workspace(cwd)
  let config_root = match workspace_path {
    Some(path) => parent_path(path).unwrap_or(cwd)
    None => parent_path(manifest_path).unwrap_or(cwd)
  }
  let config_path = config_root + "/moon-taze.json"
  if @fs.exists(config_path) {
    let loaded = @taze.read_config(config_path)
    if !json_output && !silent {
      for issue in loaded.diagnostics {
        emit("error[\{issue.code}]: \{issue.message}")
      }
    }
    if loaded.config is None {
      cli_error("invalid_config")
    }
    let config = loaded.config.unwrap()
    match config.mode {
      Some(value) =>
        if !mode_seen {
          match parse_mode(value) {
            Some(parsed) => mode = parsed
            None => cli_error("invalid_config: unknown mode {value}")
          }
        }
      None => ()
    }
    if !recursive_seen {
      match config.recursive {
        Some(value) => recursive = value
        None => ()
      }
    }
    if !all_seen {
      match config.all {
        Some(value) => show_all = value
        None => ()
      }
    }
    if include.is_empty() {
      match config.include {
        Some(values) => include.append(values)
        None => ()
      }
    }
    if exclude.is_empty() {
      match config.exclude {
        Some(values) => exclude.append(values)
        None => ()
      }
    }
    if !retry_seen {
      match config.retry {
        Some(value) => {
          if value < 0 {
            cli_error("invalid_config: retry must be non-negative")
          }
          retry_count = value
        }
        None => ()
      }
    }
    if !force_seen {
      match config.force {
        Some(value) => force = value
        None => ()
      }
    }
    if !fail_on_outdated_seen {
      match config.failOnOutdated {
        Some(value) => fail_on_outdated = value
        None => ()
      }
    }
    if !timediff_seen {
      match config.timediff {
        Some(value) => timediff = value
        None => ()
      }
    }
    if !maturity_seen {
      match config.maturityPeriod {
        Some(value) => {
          if value < 0 {
            cli_error("invalid_config: maturityPeriod must be non-negative")
          }
          maturity_days = value
        }
        None => ()
      }
    }
    if !maturity_exclude_seen {
      match config.maturityPeriodExclude {
        Some(values) => maturity_exclude.append(values)
        None => ()
      }
    }
  }
  if verify && !write {
    cli_error("invalid_option: --verify requires --write")
  }
  for selector in maturity_exclude {
    if !@taze.selector_valid(selector) {
      cli_error("invalid maturity exclusion: \{selector}")
    }
  }
  let manifests : Array[@taze.Manifest] = []
  let local_modules : Array[String] = []
  let mut workspace_root : String? = None
  match workspace_path {
    Some(path) => {
      let parsed_workspace = @taze.read_workspace(path)
      if !json_output && !silent {
        for diagnostic in parsed_workspace.diagnostics {
          let level = match diagnostic.severity {
            Warning => "warning"
            Error => "error"
          }
          emit("\{level}[\{diagnostic.code}]: \{diagnostic.message}")
        }
      }
      if parsed_workspace.workspace is None {
        cli_error("invalid_workspace")
      }
      let workspace = parsed_workspace.workspace.unwrap()
      workspace_root = Some(workspace.root)
      for member in workspace.members {
        local_modules.push(member.module_name)
      }
      // At the workspace root, explicit members define the check scope. From
      // inside a member, keep the usual nearest-module behavior.
      let normalized_cwd = @fs.realpath(cwd) catch { _ => cwd }
      let normalized_root = @fs.realpath(workspace.root) catch {
        _ => workspace.root
      }
      if normalized_cwd == normalized_root {
        for member in workspace.members {
          manifests.push(member.manifest)
        }
      }
    }
    None => ()
  }
  if manifests.is_empty() {
    let data = @fs.read_file(manifest_path) catch {
      error => {
        cli_error("manifest_read_error: \{error}")
        return 2
      }
    }
    let source = data.binary()
    let module_name = module_name_from_source(source)
    let parsed = @taze.parse_manifest(source, path=manifest_path, module_name~)
    guard parsed.manifest is Some(manifest) else {
      if !json_output && !silent {
        for diagnostic in parsed.diagnostics {
          emit("error[\{diagnostic.code}]: \{diagnostic.message}")
        }
      }
      return 2
    }
    manifests.push(manifest)
  }
  if recursive {
    let scan_root = match workspace_root {
      Some(value) => value
      None => cwd
    }
    let discovered : Array[String] = []
    @fs.walk(
      scan_root,
      async fn(directory, _) {
        if directory.contains("/_build") ||
          directory.contains("\\_build") ||
          directory.contains("/.git") ||
          directory.contains("\\.git") ||
          directory.contains("/.mooncakes") ||
          directory.contains("\\.mooncakes") {
          ()
        } else {
          let candidate = directory + "/moon.mod"
          if @fs.exists(candidate) {
            discovered.push(candidate)
          }
        }
      },
      max_concurrency=1,
    )
    discovered.sort()
    for path in discovered {
      if !manifests.any(item => item.path == path) {
        let data = @fs.read_file(path) catch { _ => continue }
        let source = data.binary()
        let module_name = module_name_from_source(source)
        let parsed = @taze.parse_manifest(source, path~, module_name~)
        match parsed.manifest {
          Some(manifest) => manifests.push(manifest)
          None =>
            if !json_output && !silent {
              for diagnostic in parsed.diagnostics {
                emit("error[\{diagnostic.code}]: \{diagnostic.message}")
              }
            }
        }
      }
    }
  }
  let need_release_times = timediff ||
    sort_mode == "time-asc" ||
    sort_mode == "time-desc" ||
    maturity_days > 0 ||
    mode == @taze.UpdateMode::Newest ||
    mode == @taze.UpdateMode::Next
  let detail_times : Map[String, Int64] = Map([])
  let detail_missing : Map[String, Bool] = Map([])
  let effective_fetch : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError = name => {
    let registry_root = "https://mooncakes.io"
    let key = cache_key(registry_root, name)
    if !force {
      match cache.get(key) {
        Some(value) =>
          return if need_release_times {
            enrich_release_times(
              value, fetch_version, detail_times, detail_missing, retry_count, retry_delay_ms,
            )
          } else {
            value
          }
        None =>
          // Read the old process-local key shape during the transition to
          // registry-scoped persistent cache entries.
          match cache.get(name) {
            Some(value) =>
              return if need_release_times {
                enrich_release_times(
                  value, fetch_version, detail_times, detail_missing, retry_count,
                  retry_delay_ms,
                )
              } else {
                value
              }
            None => ()
          }
      }
    }
    let value = fetch_with_retries(
      fetch~,
      name,
      retry_count,
      delay_ms=retry_delay_ms,
    )
    let enriched = if need_release_times {
      enrich_release_times(
        value, fetch_version, detail_times, detail_missing, retry_count, retry_delay_ms,
      )
    } else {
      value
    }
    cache[key] = enriched
    cache_times[key] = @env.now()
    save_persistent_cache(cache_path, cache, cache_times) catch {
      _ => ()
    }
    enriched
  }
  let release_options = @taze.ReleaseOptions::ReleaseOptions(
    @env.now().reinterpret_as_int64(),
    maturity_days,
    maturity_exclude~,
  )
  let plan = @taze.check_manifests_timed_filtered(
    manifests,
    local_modules,
    mode~,
    include~,
    exclude~,
    options=release_options,
    cwd~,
    fetch=effective_fetch,
  )
  if !json_output && !silent {
    for diagnostic in plan.diagnostics() {
      let level = match diagnostic.severity {
        Warning => "warning"
        Error => "error"
      }
      emit("\{level}[\{diagnostic.code}]: \{diagnostic.message}")
    }
  }
  let extra_diagnostics : Array[@taze.Diagnostic] = []
  if timediff {
    for change in plan.changes() {
      match change.target {
        Some(target) => {
          let current_key = change.dependency.name +
            "@" +
            change.dependency.version
          let target_key = change.dependency.name + "@" + target
          if !detail_times.contains(current_key) ||
            !detail_times.contains(target_key) {
            extra_diagnostics.push(
              @taze.warning_diagnostic(
                "unknown_release_time",
                "current or target release time is unavailable for timediff",
                Some(change.dependency.manifest),
                Some(change.dependency.name),
                Some(change.dependency.span.line),
                Some(change.dependency.span.column),
              ),
            )
          }
        }
        None => ()
      }
    }
  }
  if !json_output && !silent {
    for diagnostic in extra_diagnostics {
      emit("warning[\{diagnostic.code}]: \{diagnostic.message}")
    }
  }
  let changes = sort_changes(
    plan.changes(),
    sort_mode,
    published_at=detail_times,
  )
  let mut grouped_manifest : String? = None
  for change in changes {
    if json_output || silent {
      continue
    }
    if group_output && grouped_manifest != Some(change.dependency.manifest) {
      grouped_manifest = Some(change.dependency.manifest)
      emit("[{change.dependency.manifest}]")
    }
    match change.status {
      UpdateAvailable => {
        let target = change.target.unwrap_or("?")
        let mode_text = mode_name(change.mode)
        let timediff_text = if timediff {
          let current = detail_times.get(
            change.dependency.name + "@" + change.dependency.version,
          )
          let target_time = detail_times.get(
            change.dependency.name + "@" + target,
          )
          " timediff=\{format_time_diff(current, target_time)}"
        } else {
          ""
        }
        emit(
          "\{change.dependency.name} \{change.dependency.version} -> \{target} (\{mode_text})\{timediff_text}",
        )
      }
      UpToDate =>
        if show_all {
          emit(
            "\{change.dependency.name} \{change.dependency.version} up-to-date",
          )
        }
      NoCandidate => emit("\{change.dependency.name} no candidate")
      Skipped =>
        if show_all {
          let reason = change.reason.unwrap_or("filtered")
          emit("\{change.dependency.name} skipped (\{reason})")
        }
      Error => ()
    }
  }
  if plan.has_errors() {
    if json_output {
      emit(
        render_json(
          plan,
          mode,
          None,
          [],
          fail_on_outdated,
          published_at=detail_times,
          extra_diagnostics~,
        ),
      )
      return 2
    }
    cli_error("check failed")
  }
  let mut interactive_selection_result : @taze.Selection? = None
  if interactive {
    match interactive_selection(plan, emit~) {
      Some(selection) => {
        interactive_selection_result = Some(selection)
        write = true
      }
      None => return 0
    }
  }
  if write {
    let selection = interactive_selection_result.unwrap_or(
      plan.recommended_selection(),
    )
    let report = @taze.apply(plan, selection)
    let verification : Array[VerificationResult] = []
    if verify && report.status() == Succeeded && report.written_files() > 0 {
      let verify_emit : (String) -> Unit = if json_output {
        _ => ()
      } else {
        emit
      }
      match workspace_root {
        Some(root) => {
          let passed = verify_directory(root, emit=verify_emit)
          verification.push({
            path: root,
            passed,
            exit_code: if passed {
              0
            } else {
              2
            },
          })
        }
        None => {
          let directories : Array[String] = []
          for file in report.files() {
            if file.status() == Written {
              let directory = parent_path(file.manifest()).unwrap_or(cwd)
              if !directories.contains(directory) {
                directories.push(directory)
              }
            }
          }
          directories.sort()
          for directory in directories {
            let passed = verify_directory(directory, emit=verify_emit)
            verification.push({
              path: directory,
              passed,
              exit_code: if passed {
                0
              } else {
                2
              },
            })
          }
        }
      }
    }
    if json_output {
      emit(
        render_json(
          plan,
          mode,
          Some(report),
          verification,
          fail_on_outdated,
          published_at=detail_times,
          extra_diagnostics~,
        ),
      )
      if report.exit_code() != 0 || verification.any(item => !item.passed) {
        return 2
      }
      if fail_on_outdated &&
        plan.changes().any(item => item.status is UpdateAvailable) {
        return 1
      }
      return 0
    }
    if !silent {
      for diagnostic in report.diagnostics {
        emit("error[\{diagnostic.code}]: \{diagnostic.message}")
      }
      for file in report.files {
        let status = match file.status {
          Written => "written"
          Unchanged => "unchanged"
          Failed => "failed"
          NotAttempted => "not_attempted"
        }
        emit(
          "\{status}: \{file.manifest} (\{file.changed_dependencies} dependencies)",
        )
      }
      let status = match report.status {
        Succeeded => "succeeded"
        Failed => "failed"
        Partial => "partial"
        Cancelled => "cancelled"
      }
      emit("apply \{status}: \{report.written_files()} files written")
    }
    if report.exit_code() != 0 || verification.any(item => !item.passed) {
      return 2
    }
    if fail_on_outdated &&
      plan.changes().any(item => item.status is UpdateAvailable) {
      return 1
    }
    return 0
  }
  if json_output {
    emit(
      render_json(
        plan,
        mode,
        None,
        [],
        fail_on_outdated,
        published_at=detail_times,
        extra_diagnostics~,
      ),
    )
  }
  if fail_on_outdated &&
    plan.changes().any(item => item.status is UpdateAvailable) {
    1
  } else {
    0
  }
}

///|
async fn main {
  let cache : Map[String, @taze.ModuleMetadata] = Map([])
  let cache_times : Map[String, UInt64] = Map([])
  let cache_path = persistent_cache_path()
  load_persistent_cache(cache_path, cache~, cache_times~)
  let code = run_cli(
    @env.args(),
    fetch=name => @taze.query_mooncakes(root="https://mooncakes.io", name),
    emit=println,
    cache~,
    cache_times~,
    cache_path~,
    retry_delay_ms=1000,
    fetch_version=fetch_mooncakes_version_cli,
    interactive_tty=Some(interactive_terminal_available()),
  )
  if code != 0 {
    terminate_process(code)
  }
}
