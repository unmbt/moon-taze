///|
pub suberror RegistryError {
  RequestFailed(String)
  InvalidMetadata(String)
} derive(Debug)

///|
/// Create a deterministic registry failure for FakeRegistry implementations.
pub fn registry_request_failed(message : String) -> RegistryError {
  RegistryError::RequestFailed(message)
}

///|
fn RegistryError::message(self : RegistryError) -> String {
  match self {
    RequestFailed(value) => value
    InvalidMetadata(value) => value
  }
}

///|
fn RegistryError::code(self : RegistryError) -> String {
  match self {
    RequestFailed(message) if message == "request_timeout" => "request_timeout"
    RequestFailed(message) if message.has_prefix("HTTP 404") =>
      "module_not_found"
    RequestFailed(_) => "http_error"
    InvalidMetadata(_) => "invalid_metadata"
  }
}

///|
struct RegistryOverview {
  module : String
  latest_version : String?
  versions : Array[RegistryVersion]
} derive(FromJson, Debug)

///|
struct RegistryVersion {
  version : String
  yanked : Bool
  yanked_reason : Json
} derive(FromJson, Debug)

///|
fn optional_reason(value : Json) -> String? raise RegistryError {
  match value {
    Json::Null => None
    Json::String(reason) => Some(reason)
    _ =>
      raise RegistryError::InvalidMetadata(
        "yanked_reason must be a string or null",
      )
  }
}

///|
fn registry_url(root : String, module : String) -> String {
  let encoded = module.replace(old="/", new="%2F")
  root + "/api/v0/modules/" + encoded
}

///|
fn metadata_from_overview(
  value : RegistryOverview,
  requested : String,
) -> ModuleMetadata raise RegistryError {
  if value.module != requested {
    raise RegistryError::InvalidMetadata("module mismatch")
  }
  let seen : Map[String, Bool] = Map([])
  let versions : Array[VersionMetadata] = []
  for item in value.versions {
    if seen.contains(item.version) {
      raise RegistryError::InvalidMetadata("duplicate version")
    }
    let parsed = parse_version(item.version) catch {
      _ => raise RegistryError::InvalidMetadata("invalid version")
    }
    ignore(parsed)
    seen[item.version] = true
    versions.push({
      version: item.version,
      yanked: item.yanked,
      yanked_reason: optional_reason(item.yanked_reason),
      published_at: None,
    })
  }
  match value.latest_version {
    None => { module: requested, latest: None, versions, }
    Some(latest) => {
      let latest_version = parse_version(latest) catch {
        _ => raise RegistryError::InvalidMetadata("invalid latest version")
      }
      if !seen.contains(latest_version.to_string()) && !seen.contains(latest) {
        raise RegistryError::InvalidMetadata(
          "latest version is absent from versions",
        )
      }
      { module: requested, latest: Some(latest), versions, }
    }
  }
}

///|
/// Query the Mooncakes overview endpoint with system certificate verification.
pub async fn query_mooncakes(
  root~ : String,
  module : String,
) -> ModuleMetadata raise RegistryError {
  let url = registry_url(root, module)
  let response_body = @async.with_timeout_opt(5000, () => @http.get(url)) catch {
    @async.TimeoutError => raise RegistryError::RequestFailed("request_timeout")
    err => raise RegistryError::RequestFailed(err.to_string())
  }
  let (response, body) = match response_body {
    None => raise RegistryError::RequestFailed("request_timeout")
    Some(value) => value
  }
  let text = body.text() catch {
    err => raise RegistryError::RequestFailed(err.to_string())
  }
  if response.code < 200 || response.code >= 300 {
    raise RegistryError::RequestFailed("HTTP \{response.code}")
  }
  let json = @json.parse(text) catch {
    _ => raise RegistryError::InvalidMetadata("invalid JSON")
  }
  let overview : RegistryOverview = @json.from_json(json) catch {
    err =>
      raise RegistryError::InvalidMetadata("invalid metadata schema: \{err}")
  }
  metadata_from_overview(overview, module)
}

///|
fn retryable_registry_error(error : RegistryError) -> Bool {
  match error {
    InvalidMetadata(_) => false
    RequestFailed(message) =>
      message == "request_timeout" ||
      message.has_prefix("HTTP 408") ||
      message.has_prefix("HTTP 429") ||
      message.has_prefix("HTTP 5")
  }
}

///|
/// Query Mooncakes with bounded exponential retry for transient failures.
/// The first request is immediate; retry number `n` waits `delay_ms * 2^n`.
/// A zero retry count disables retries and is useful for deterministic CI.
pub async fn query_mooncakes_retry(
  root~ : String,
  module : String,
  retries~ : Int,
  delay_ms~ : Int,
) -> ModuleMetadata raise RegistryError {
  let max_retries = if retries < 0 { 0 } else { retries }
  let base_delay = if delay_ms < 0 { 0 } else { delay_ms }
  query_mooncakes_retry_attempt(root~, module, max_retries, base_delay, 0)
}

///|
async fn query_mooncakes_retry_attempt(
  root~ : String,
  module : String,
  max_retries : Int,
  base_delay : Int,
  attempt : Int,
) -> ModuleMetadata raise RegistryError {
  query_mooncakes(root~, module) catch {
    error => {
      if !retryable_registry_error(error) || attempt >= max_retries {
        raise error
      }
      let mut delay = base_delay
      for _ in 0..<attempt {
        delay = delay * 2
      }
      if delay > 0 {
        @async.sleep(delay) catch {
          _ => ()
        }
      }
      query_mooncakes_retry_attempt(
        root~,
        module,
        max_retries,
        base_delay,
        attempt + 1,
      )
    }
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
fn invalid_metadata_change(
  dependency : Dependency,
  mode : UpdateMode,
  reason : String,
) -> DependencyChange {
  let diag = diagnostic(
    "invalid_metadata",
    reason,
    Some(dependency.manifest),
    Some(dependency.name),
    Some(dependency.span.line),
    Some(dependency.span.column),
  )
  {
    dependency,
    mode,
    status: Error,
    target: None,
    candidates: [],
    diff: None,
    reason: Some("invalid_metadata"),
    diagnostics: [diag],
  }
}

///|
fn metadata_is_valid(metadata : ModuleMetadata, requested : String) -> String? {
  if metadata.module != requested {
    return Some("registry module does not match the requested module")
  }
  let seen : Map[String, Bool] = Map([])
  for item in metadata.versions {
    let parsed = Some(parse_version(item.version)) catch { _ => None }
    if parsed is None {
      return Some("registry returned an invalid version")
    }
    if seen.contains(item.version) {
      return Some("registry returned a duplicate version")
    }
    seen[item.version] = true
  }
  match metadata.latest {
    None => None
    Some(value) => {
      let parsed = parse_version(value) catch {
        _ => return Some("registry returned an invalid latest version")
      }
      if !seen.contains(value) && !seen.contains(parsed.to_string()) {
        Some("latest version is absent from registry metadata")
      } else {
        None
      }
    }
  }
}

///|
fn has_error_diagnostics(diagnostics : Array[Diagnostic]) -> Bool {
  diagnostics.any(item => item.severity == DiagnosticSeverity::Error)
}

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
fn parse_int_option(value : String) -> Int? {
  Some(@string.parse_int(value)) catch {
    _ => None
  }
}

///|
fn parse_filter_version(raw : String) -> SemVer? {
  let parts = Array::from_iter(raw.split(".").map(StringView::to_owned))
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
    Some(parse_version(raw)) catch {
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
  let current_version : SemVer? = Some(parse_version(current)) catch {
    _ => None
  }
  match current_version {
    None => false
    Some(current_version) => {
      let (operator, raw) = if filter.has_prefix("^") || filter.has_prefix("~") {
        (filter[:1].to_owned(), filter[1:].to_owned())
      } else {
        ("", filter)
      }
      let parts = Array::from_iter(raw.split(".").map(StringView::to_owned))
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
/// Validate the intentionally small P1a selector grammar.
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
        let parts = Array::from_iter(raw.split(".").map(StringView::to_owned))
        (
          (parts.length() == 1 || parts.length() == 2) &&
          parts.all(part => parse_int_option(part) is Some(_))
        ) ||
        (Some(parse_version(raw)) catch { _ => None }) is Some(_)
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

///|
fn skipped_change(
  dependency : Dependency,
  mode : UpdateMode,
  reason : String,
) -> DependencyChange {
  {
    dependency,
    mode,
    status: Skipped,
    target: None,
    candidates: [],
    diff: None,
    reason: Some(reason),
    diagnostics: [],
  }
}

///|
fn selector_error_change(
  dependency : Dependency,
  mode : UpdateMode,
  selector : String,
) -> DependencyChange {
  let diag = diagnostic(
    "invalid_filter",
    "unsupported dependency selector: \{selector}",
    Some(dependency.manifest),
    Some(dependency.name),
    Some(dependency.span.line),
    Some(dependency.span.column),
  )
  {
    dependency,
    mode,
    status: Error,
    target: None,
    candidates: [],
    diff: None,
    reason: Some("invalid_filter"),
    diagnostics: [diag],
  }
}

///|
fn resolve_dependency(
  dependency : Dependency,
  metadata : ModuleMetadata,
  mode : UpdateMode,
  exclude~ : Array[String],
) -> DependencyChange {
  let current = parse_version(dependency.version) catch {
    _ => {
      let diag = diagnostic(
        "invalid_version",
        "invalid declared version",
        Some(dependency.manifest),
        Some(dependency.name),
        Some(dependency.span.line),
        Some(dependency.span.column),
      )
      return {
        dependency,
        mode,
        status: Error,
        target: None,
        candidates: [],
        diff: None,
        reason: Some("invalid_version"),
        diagnostics: [diag],
      }
    }
  }
  let metadata_diagnostics : Array[Diagnostic] = []
  let current_in_registry = metadata.versions.any(item => {
    item.version == dependency.version
  })
  let current_yanked = metadata.versions.any(item => {
    item.version == dependency.version && item.yanked
  })
  if !current_in_registry {
    metadata_diagnostics.push(
      warning(
        "current_version_missing",
        "declared version is not present in registry metadata",
        Some(dependency.manifest),
        Some(dependency.name),
        Some(dependency.span.line),
        Some(dependency.span.column),
      ),
    )
  } else if current_yanked {
    metadata_diagnostics.push(
      warning(
        "current_version_yanked",
        "declared version is withdrawn; newer eligible versions may still be selected",
        Some(dependency.manifest),
        Some(dependency.name),
        Some(dependency.span.line),
        Some(dependency.span.column),
      ),
    )
  }
  let available : Array[SemVer] = []
  for item in metadata.versions {
    if !item.yanked {
      let parsed = parse_version(item.version) catch {
        _ => {
          let diag = diagnostic(
            "invalid_metadata",
            "registry returned an invalid version",
            Some(dependency.manifest),
            Some(dependency.name),
            Some(dependency.span.line),
            Some(dependency.span.column),
          )
          return {
            dependency,
            mode,
            status: Error,
            target: None,
            candidates: [],
            diff: None,
            reason: Some("invalid_metadata"),
            diagnostics: [diag],
          }
        }
      }
      if !exclude.any(selector => {
          selector_has_version(selector) &&
          selector_matches_version(dependency.name, item.version, selector)
        }) {
        available.push(parsed)
      }
    }
  }
  let candidate_names = available.map(v => v.to_string())
  let latest : SemVer? = match metadata.latest {
    None => None
    Some(value) => {
      let parsed : SemVer? = Some(parse_version(value)) catch { _ => None }
      match parsed {
        Some(version) => Some(version)
        None => {
          let diag = diagnostic(
            "invalid_metadata",
            "registry returned an invalid latest version",
            Some(dependency.manifest),
            Some(dependency.name),
            Some(dependency.span.line),
            Some(dependency.span.column),
          )
          return {
            dependency,
            mode,
            status: Error,
            target: None,
            candidates: [],
            diff: None,
            reason: Some("invalid_metadata"),
            diagnostics: [diag],
          }
        }
      }
    }
  }
  let target = match latest {
    None => select_version(current, available, mode~)
    Some(value) => select_version(current, available, latest=value, mode~)
  }
  let has_higher_unfiltered = metadata.versions.any(item => {
    if item.yanked {
      false
    } else {
      let parsed : SemVer? = Some(parse_version(item.version)) catch {
        _ => None
      }
      match parsed {
        Some(value) => SemVer::compare(value, current) > 0
        None => false
      }
    }
  })
  match target {
    None =>
      {
        dependency,
        mode,
        status: if has_higher_unfiltered {
          NoCandidate
        } else {
          UpToDate
        },
        target: None,
        candidates: candidate_names,
        diff: None,
        reason: if has_higher_unfiltered {
          Some("no_candidate")
        } else {
          None
        },
        diagnostics: metadata_diagnostics,
      }
    Some(version) =>
      {
        dependency,
        mode,
        status: UpdateAvailable,
        target: Some(version.to_string()),
        candidates: candidate_names,
        diff: Some(diff_kind(current, version)),
        reason: None,
        diagnostics: metadata_diagnostics,
      }
  }
}

///|
priv enum FetchResult {
  FetchSuccess(ModuleMetadata)
  FetchFailure(RegistryError)
}

///|
/// Build a complete plan using an injected Registry function. This is the offline test seam.
pub async fn check_manifest(
  manifest : Manifest,
  mode~ : UpdateMode,
  fetch~ : async (String) -> ModuleMetadata raise RegistryError,
) -> CheckPlan {
  check_manifest_filtered(manifest, mode~, include=[], exclude=[], fetch~)
}

///|
/// Build a check plan while applying name and version selectors before fetches.
pub async fn check_manifest_filtered(
  manifest : Manifest,
  mode~ : UpdateMode,
  include~ : Array[String],
  exclude~ : Array[String],
  fetch~ : async (String) -> ModuleMetadata raise RegistryError,
) -> CheckPlan {
  check_manifest_filtered_internal(
    manifest,
    mode~,
    include~,
    exclude~,
    local_modules=Map([]),
    fetched=Map([]),
    fetch~,
  )
}

///|
/// Build one plan for several manifests while sharing registry requests.
/// `local_modules` contains the complete workspace member-name set, including
/// members that are outside the selected check range.
pub async fn check_manifests_filtered(
  manifests : Array[Manifest],
  local_modules : Array[String],
  mode~ : UpdateMode,
  include~ : Array[String],
  exclude~ : Array[String],
  cwd? : String = @env.current_dir().unwrap_or("."),
  fetch~ : async (String) -> ModuleMetadata raise RegistryError,
) -> CheckPlan {
  let locals : Map[String, Unit] = Map([])
  for name in local_modules {
    locals[name] = ()
  }
  let fetched : Map[String, FetchResult] = Map([])
  let snapshots : Array[Manifest] = []
  let entries : Array[DependencyChange] = []
  let diagnostics : Array[Diagnostic] = []
  for manifest in manifests {
    let item = check_manifest_filtered_internal(
      manifest,
      mode~,
      include~,
      exclude~,
      local_modules=locals,
      fetched~,
      fetch~,
    )
    snapshots.append(item.snapshots)
    entries.append(item.entries)
    diagnostics.append(item.issues)
  }
  make_plan(snapshots, entries, diagnostics, cwd~)
}

///|
/// Internal implementation shared by single-manifest and workspace checks.
async fn check_manifest_filtered_internal(
  manifest : Manifest,
  mode~ : UpdateMode,
  include~ : Array[String],
  exclude~ : Array[String],
  local_modules~ : Map[String, Unit],
  fetched~ : Map[String, FetchResult],
  fetch~ : async (String) -> ModuleMetadata raise RegistryError,
) -> CheckPlan {
  // Reparse authoritative bytes: callers can mutate Manifest.dependencies.
  let checked_cwd = @env.current_dir().unwrap_or(".")
  let parsed = parse_manifest(
    manifest.source,
    path=manifest.path,
    module_name=manifest.module_name,
  )
  if has_error_diagnostics(parsed.diagnostics) {
    return make_plan([], [], parsed.diagnostics)
  }
  let manifest = parsed.manifest.unwrap()
  if mode == UpdateMode::Newest || mode == UpdateMode::Next {
    let changes = manifest.dependencies.map(dependency => {
      let diag = diagnostic(
        "unsupported_mode",
        "newest and next require release-time metadata and are not available in P1a",
        Some(dependency.manifest),
        Some(dependency.name),
        Some(dependency.span.line),
        Some(dependency.span.column),
      )
      {
        dependency,
        mode,
        status: Error,
        target: None,
        candidates: [],
        diff: None,
        reason: Some("unsupported_mode"),
        diagnostics: [diag],
      }
    })
    let diagnostics : Array[Diagnostic] = []
    for change in changes {
      diagnostics.append(change.diagnostics)
    }
    if diagnostics.is_empty() {
      diagnostics.push(
        diagnostic(
          "unsupported_mode",
          "newest and next require release-time metadata and are not available in P1a",
          Some(manifest.path),
          None,
          None,
          None,
        ),
      )
    }
    return make_plan([manifest], changes, diagnostics, cwd=checked_cwd)
  }
  let mut invalid_selector : String? = None
  for selector in include {
    if (!name_selector_valid(selector) || selector_has_version(selector)) &&
      invalid_selector is None {
      invalid_selector = Some(selector)
    }
  }
  for selector in exclude {
    if !selector_valid(selector) && invalid_selector is None {
      invalid_selector = Some(selector)
    }
  }
  match invalid_selector {
    Some(selector) => {
      let changes = manifest.dependencies.map(dependency => {
        selector_error_change(dependency, mode, selector)
      })
      let diagnostics : Array[Diagnostic] = []
      for change in changes {
        diagnostics.append(change.diagnostics)
      }
      if diagnostics.is_empty() {
        diagnostics.push(
          diagnostic(
            "invalid_filter",
            "unsupported dependency selector: \{selector}",
            Some(manifest.path),
            None,
            None,
            None,
          ),
        )
      }
      return make_plan([manifest], changes, diagnostics, cwd=checked_cwd)
    }
    None => ()
  }
  let changes : Array[DependencyChange] = []
  let diagnostics : Array[Diagnostic] = parsed.diagnostics.copy()
  for dependency in manifest.dependencies {
    if exclude.any(selector => {
        !selector_has_version(selector) && filter_matches(dependency, selector)
      }) {
      changes.push(skipped_change(dependency, mode, "excluded"))
      continue
    }
    if !include.is_empty() &&
      !include.any(selector => filter_matches(dependency, selector)) {
      changes.push(skipped_change(dependency, mode, "not_included"))
      continue
    }
    if local_modules.contains(dependency.name) {
      let local_dependency = {
        ..dependency,
        source: DependencySource::LocalWorkspace,
      }
      let note = warning(
        "local_workspace",
        "dependency is provided by a member of the current workspace",
        Some(dependency.manifest),
        Some(dependency.name),
        Some(dependency.span.line),
        Some(dependency.span.column),
      )
      changes.push({
        dependency: local_dependency,
        mode,
        status: Skipped,
        target: None,
        candidates: [],
        diff: None,
        reason: Some("local_workspace"),
        diagnostics: [note],
      })
      diagnostics.push(note)
      continue
    }
    let fetched_value = match fetched.get(dependency.name) {
      Some(value) => value
      None => {
        let value : FetchResult = FetchSuccess(fetch(dependency.name)) catch {
          error => FetchFailure(error)
        }
        fetched[dependency.name] = value
        value
      }
    }
    match fetched_value {
      FetchSuccess(metadata) => {
        let change = match metadata_is_valid(metadata, dependency.name) {
          Some(reason) => invalid_metadata_change(dependency, mode, reason)
          None => resolve_dependency(dependency, metadata, mode, exclude~)
        }
        diagnostics.append(change.diagnostics)
        changes.push(change)
      }
      FetchFailure(error) => {
        let diag = diagnostic(
          error.code(),
          error.message(),
          Some(dependency.manifest),
          Some(dependency.name),
          Some(dependency.span.line),
          Some(dependency.span.column),
        )
        diagnostics.push(diag)
        changes.push({
          dependency,
          mode,
          status: Error,
          target: None,
          candidates: [],
          diff: None,
          reason: Some(error.code()),
          diagnostics: [diag],
        })
      }
    }
  }
  make_plan([manifest], changes, diagnostics, cwd=checked_cwd)
}

///|
/// Read a manifest through the Native FS adapter and run the real Mooncakes query.
pub async fn check_path(
  path : String,
  module_name~ : String,
  mode~ : UpdateMode,
) -> CheckPlan {
  check_path_filtered(path, module_name~, mode~, include=[], exclude=[])
}

///|
/// Read and check one manifest with selectors applied before registry access.
pub async fn check_path_filtered(
  path : String,
  module_name~ : String,
  mode~ : UpdateMode,
  include~ : Array[String],
  exclude~ : Array[String],
) -> CheckPlan {
  let data = @fs.read_file(path) catch {
    error => {
      let diag = diagnostic(
        "manifest_read_error",
        error.to_string(),
        Some(path),
        None,
        None,
        None,
      )
      return make_plan([], [], [diag])
    }
  }
  let source = data.binary()
  let parsed = parse_manifest(source, path~, module_name~)
  match parsed.manifest {
    None => make_plan([], [], parsed.diagnostics)
    Some(manifest) => {
      if has_error_diagnostics(parsed.diagnostics) {
        return make_plan([], [], parsed.diagnostics)
      }
      check_manifest_filtered(manifest, mode~, include~, exclude~, fetch=module => {
        query_mooncakes(root="https://mooncakes.io", module)
      })
    }
  }
}
