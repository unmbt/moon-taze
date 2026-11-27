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
    target_sha: None,
    latest_available: None,
    candidates: [],
    diff: None,
    reason: Some("invalid_metadata"),
    diagnostics: [diag],
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
    target_sha: None,
    latest_available: None,
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
    target_sha: None,
    latest_available: None,
    candidates: [],
    diff: None,
    reason: Some("invalid_filter"),
    diagnostics: [diag],
  }
}

///|
fn release_exempt(
  dependency : Dependency,
  version : String,
  selectors : Array[String],
) -> Bool {
  selectors.any(selector => {
    if selector_has_version(selector) {
      selector_matches_version(dependency.name, version, selector)
    } else {
      matches_glob(selector, dependency.name)
    }
  })
}

///|
fn compute_mooncakes_latest_available(
  current : SemVer,
  target : SemVer?,
  available : Array[SemVer],
  latest : SemVer?,
) -> String? {
  let baseline = match target {
    Some(t) => t
    None => current
  }
  let best_stable = select_version(baseline, available, latest?, mode=Major)
  match best_stable {
    Some(best) if SemVer::compare(best, baseline) > 0 => Some(best.to_string())
    _ => None
  }
}

///|
fn compute_gha_latest_available(
  current_tag : String,
  target_tag : String?,
  all_tags : Array[String],
) -> String? {
  let baseline = target_tag.unwrap_or(current_tag)
  match select_action_target(baseline, all_tags, Major) {
    Some(best) if best.tag != baseline => Some(best.tag)
    _ => None
  }
}

///|
fn resolve_dependency_mooncakes_standard(
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
        target_sha: None,
        latest_available: None,
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
        _ =>
          return invalid_metadata_change(
            dependency, mode, "registry returned an invalid version",
          )
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
    Some(value) =>
      match (Some(parse_version(value)) catch { _ => None }) {
        Some(version) => Some(version)
        None =>
          return invalid_metadata_change(
            dependency, mode, "registry returned an invalid latest version",
          )
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
      match (Some(parse_version(item.version)) catch { _ => None }) {
        Some(value) => SemVer::compare(value, current) > 0
        None => false
      }
    }
  })
  let latest_available = compute_mooncakes_latest_available(
    current, target, available, latest,
  )
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
        target_sha: None,
        latest_available,
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
        target_sha: None,
        latest_available,
        candidates: candidate_names,
        diff: Some(diff_kind(current, version)),
        reason: None,
        diagnostics: metadata_diagnostics,
      }
  }
}

///|
fn resolve_dependency_mooncakes_timed(
  dependency : Dependency,
  metadata : ModuleMetadata,
  mode : UpdateMode,
  exclude~ : Array[String],
  options~ : ReleaseOptions,
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
        target_sha: None,
        latest_available: None,
        candidates: [],
        diff: None,
        reason: Some("invalid_version"),
        diagnostics: [diag],
      }
    }
  }
  let diagnostics : Array[Diagnostic] = []
  let current_in_registry = metadata.versions.any(item => {
    item.version == dependency.version
  })
  let current_yanked = metadata.versions.any(item => {
    item.version == dependency.version && item.yanked
  })
  if !current_in_registry {
    diagnostics.push(
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
    diagnostics.push(
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
  let require_time = mode == Newest || mode == Next
  let maturity_ms = options.maturity_days.to_int64() * 86400000L
  let candidates : Array[(SemVer, VersionMetadata)] = []
  let candidate_names : Array[String] = []
  for item in metadata.versions {
    if item.yanked ||
      exclude.any(selector => {
        selector_has_version(selector) &&
        selector_matches_version(dependency.name, item.version, selector)
      }) {
      continue
    }
    let parsed = parse_version(item.version) catch {
      _ => {
        diagnostics.push(
          diagnostic(
            "invalid_metadata",
            "registry returned an invalid version",
            Some(dependency.manifest),
            Some(dependency.name),
            Some(dependency.span.line),
            Some(dependency.span.column),
          ),
        )
        continue
      }
    }
    if SemVer::compare(parsed, current) <= 0 {
      continue
    }
    candidate_names.push(item.version)
    if require_time &&
      (
        item.published_at is None ||
        item.published_at.unwrap() > options.now_ms ||
        item.published_at.unwrap() < 0L
      ) {
      diagnostics.push(
        diagnostic(
          "incomplete_release_times",
          "newest and next require valid release times for every candidate",
          Some(dependency.manifest),
          Some(dependency.name),
          Some(dependency.span.line),
          Some(dependency.span.column),
        ),
      )
      return {
        dependency,
        mode,
        status: Error,
        target: None,
        target_sha: None,
        latest_available: None,
        candidates: candidate_names,
        diff: None,
        reason: Some("incomplete_release_times"),
        diagnostics,
      }
    }
    if options.maturity_days > 0 &&
      !release_exempt(dependency, item.version, options.maturity_exclude) {
      match item.published_at {
        Some(published) if published >= 0L &&
          published < options.now_ms - maturity_ms => ()
        _ => {
          diagnostics.push(
            warning(
              "unknown_release_time",
              "candidate release is missing or has not reached the maturity period",
              Some(dependency.manifest),
              Some(dependency.name),
              Some(dependency.span.line),
              Some(dependency.span.column),
            ),
          )
          continue
        }
      }
    }
    candidates.push((parsed, item))
  }
  if mode == Next {
    diagnostics.push(
      warning(
        "next_tag_unavailable",
        "registry does not expose a verified next tag; using newest release time",
        Some(dependency.manifest),
        Some(dependency.name),
        Some(dependency.span.line),
        Some(dependency.span.column),
      ),
    )
  }
  let target : SemVer? = if require_time {
    let mut selected : (SemVer, VersionMetadata)? = None
    for candidate in candidates {
      if candidate.1.published_at is Some(published) {
        match selected {
          None => selected = Some(candidate)
          Some(previous) => {
            let prev_time = previous.1.published_at.unwrap()
            if published > prev_time ||
              (
                published == prev_time &&
                (
                  SemVer::compare(candidate.0, previous.0) > 0 ||
                  (
                    SemVer::compare(candidate.0, previous.0) == 0 &&
                    candidate.0.to_string() > previous.0.to_string()
                  )
                )
              ) {
              selected = Some(candidate)
            }
          }
        }
      }
    }
    selected.map(item => item.0)
  } else {
    select_version(current, candidates.map(item => item.0), mode~)
  }
  let timed_available = candidates.map(item => item.0)
  let latest_available = compute_mooncakes_latest_available(
    current,
    target,
    timed_available,
    None,
  )
  match target {
    Some(target) =>
      {
        dependency,
        mode,
        status: UpdateAvailable,
        target: Some(target.to_string()),
        target_sha: None,
        latest_available,
        candidates: candidate_names,
        diff: Some(diff_kind(current, target)),
        reason: None,
        diagnostics,
      }
    None =>
      {
        dependency,
        mode,
        status: if candidate_names.is_empty() {
          UpToDate
        } else {
          NoCandidate
        },
        target: None,
        target_sha: None,
        latest_available,
        candidates: candidate_names,
        diff: None,
        reason: if candidate_names.is_empty() {
          None
        } else {
          Some("no_candidate")
        },
        diagnostics,
      }
  }
}

///|
fn resolve_dependency_gha(
  dependency : Dependency,
  metadata : ModuleMetadata,
  mode : UpdateMode,
  exclude~ : Array[String],
  options~ : ReleaseOptions,
  gha_style~ : GitHubActionStyle,
) -> DependencyChange {
  let sha_map : Map[String, String] = Map([])
  let time_map : Map[String, Int64] = Map([])
  let all_tags : Array[String] = []
  for item in metadata.versions {
    all_tags.push(item.version)
    if item.sha is Some(sha) {
      sha_map[item.version] = sha
    }
    if item.published_at is Some(ts) {
      time_map[item.version] = ts
    }
  }
  let maturity_ms = options.maturity_days.to_int64() * 86400000L
  let diagnostics : Array[Diagnostic] = []
  let picked = select_action_target(dependency.version, all_tags, mode, reject=tag => {
    if exclude.any(selector => {
        selector_has_version(selector) &&
        selector_matches_version(dependency.name, tag.raw, selector)
      }) {
      return true
    }
    if options.maturity_days > 0 &&
      !release_exempt(dependency, tag.raw, options.maturity_exclude) {
      match time_map.get(tag.raw) {
        Some(published) if published >= 0L &&
          published < options.now_ms - maturity_ms => false
        _ => {
          diagnostics.push(
            warning(
              "unknown_release_time",
              "GitHub Action tag is missing or has not reached the maturity period",
              Some(dependency.manifest),
              Some(dependency.name),
              Some(dependency.span.line),
              Some(dependency.span.column),
            ),
          )
          true
        }
      }
    } else {
      false
    }
  })
  match picked {
    Some(target) if target.tag != dependency.version => {
      let target_sha = match sha_map.get(target.tag) {
        Some(sha) => Some(sha)
        None => sha_map.get(target.resolved_tag)
      }
      let latest_available = compute_gha_latest_available(
        dependency.version,
        Some(target.tag),
        all_tags,
      )
      {
        dependency,
        mode,
        status: UpdateAvailable,
        target: Some(target.tag),
        target_sha,
        latest_available,
        candidates: all_tags,
        diff: action_diff_kind(dependency.version, target.tag),
        reason: None,
        diagnostics,
      }
    }
    _ => {
      let latest_available = compute_gha_latest_available(
        dependency.version,
        None,
        all_tags,
      )
      // With `gha_style == Sha`, convert an up-to-date tag reference to a
      // commit-SHA pin when the current tag's SHA is known.
      if gha_style == Sha &&
        dependency.gha is Some(info) &&
        info.style == Tag &&
        sha_map.get(dependency.version) is Some(sha) {
        return {
          dependency,
          mode,
          status: UpdateAvailable,
          target: Some(dependency.version),
          target_sha: Some(sha),
          latest_available,
          candidates: all_tags,
          diff: Some(Pin),
          reason: None,
          diagnostics,
        }
      }
      let has_higher = match parse_action_tag(dependency.version) {
        Some(current) =>
          all_tags.any(raw => {
            match parse_action_tag(raw) {
              Some(t) =>
                compare_action_tag(t, { ..current, prerelease: false, }) > 0
              None => false
            }
          })
        None => false
      }
      {
        dependency,
        mode,
        status: if has_higher {
          NoCandidate
        } else {
          UpToDate
        },
        target: None,
        target_sha: None,
        latest_available,
        candidates: all_tags,
        diff: None,
        reason: if has_higher {
          Some("no_candidate")
        } else {
          None
        },
        diagnostics,
      }
    }
  }
}

///|
fn resolve_dependency(
  dependency : Dependency,
  metadata : ModuleMetadata,
  mode : UpdateMode,
  exclude~ : Array[String],
  options~ : ReleaseOptions,
  gha_style~ : GitHubActionStyle,
) -> DependencyChange {
  match dependency.source {
    GitHubActions =>
      resolve_dependency_gha(
        dependency,
        metadata,
        mode,
        exclude~,
        options~,
        gha_style~,
      )
    _ =>
      if mode == Newest || mode == Next || options.maturity_days > 0 {
        resolve_dependency_mooncakes_timed(
          dependency,
          metadata,
          mode,
          exclude~,
          options~,
        )
      } else {
        resolve_dependency_mooncakes_standard(
          dependency,
          metadata,
          mode,
          exclude~,
        )
      }
  }
}

///|
/// Resolve one dependency without performing registry or filesystem IO.
pub fn resolve(
  dependency : Dependency,
  metadata : ModuleMetadata,
  policy : Policy,
  now~ : Int64,
) -> DependencyChange raise ResolveError {
  match dependency.source {
    GitHubActions =>
      if !valid_gha_metadata(metadata, dependency.name) {
        raise InvalidMetadata("invalid GitHub Actions metadata")
      }
    _ =>
      if metadata_is_valid(metadata, dependency.name) is Some(reason) {
        raise InvalidMetadata(reason)
      }
  }
  resolve_dependency(
    dependency,
    metadata,
    policy.mode,
    exclude=policy.exclude,
    options=ReleaseOptions(
      now,
      policy.maturity_days,
      maturity_exclude=policy.maturity_exclude,
    ),
    gha_style=policy.gha_style,
  )
}

///|
priv enum FetchResult {
  FetchSuccess(ModuleMetadata)
  FetchFailure(RegistryError)
}

///|
async fn default_mooncakes_fetch(
  name : String,
) -> ModuleMetadata raise RegistryError {
  query_mooncakes(root="https://mooncakes.io", name)
}

///|
async fn default_gha_fetch(repo : String) -> ModuleMetadata raise RegistryError {
  query_github_tags(repo)
}

///|
/// Build a check plan for a single manifest.
pub async fn check(
  manifest : Manifest,
  options~ : CheckOptions = CheckOptions(),
  fetch~ : async (String) -> ModuleMetadata raise RegistryError = default_mooncakes_fetch,
  fetch_gha~ : async (String) -> ModuleMetadata raise RegistryError = default_gha_fetch,
) -> CheckPlan {
  check_manifests([manifest], options~, fetch~, fetch_gha~)
}

///|
const FETCH_MAX_CONCURRENCY : Int32 = 8

///|
fn has_invalid_selectors(options : CheckOptions) -> Bool {
  for selector in options.include_selectors {
    if !name_selector_valid(selector) || selector_has_version(selector) {
      return true
    }
  }
  for selector in options.exclude_selectors {
    if !selector_valid(selector) {
      return true
    }
  }
  false
}

///|
/// Build one unified plan for multiple manifests (MoonBit + GitHub Actions),
/// deduplicating and concurrently prefetching registry requests across all manifests.
pub async fn check_manifests(
  manifests : Array[Manifest],
  options~ : CheckOptions = CheckOptions(),
  fetch~ : async (String) -> ModuleMetadata raise RegistryError = default_mooncakes_fetch,
  fetch_gha~ : async (String) -> ModuleMetadata raise RegistryError = default_gha_fetch,
) -> CheckPlan {
  let locals : Map[String, Unit] = Map([])
  for name in options.local_modules {
    locals[name] = ()
  }
  let fetched_mooncakes : Map[String, FetchResult] = Map([])
  let fetched_gha : Map[String, FetchResult] = Map([])
  if !has_invalid_selectors(options) {
    let mooncakes_targets : Array[String] = []
    let mooncakes_seen : Map[String, Unit] = Map([])
    let gha_targets : Array[String] = []
    let gha_seen : Map[String, Unit] = Map([])
    for manifest in manifests {
      let parsed = match manifest.kind {
        MoonMod =>
          parse_manifest(
            manifest.source,
            path=manifest.path,
            module_name=manifest.module_name,
          )
        GitHubActions =>
          parse_github_actions_manifest(manifest.source, path=manifest.path)
      }
      if has_error_diagnostics(parsed.diagnostics) {
        continue
      }
      guard parsed.manifest is Some(parsed_manifest) else { continue }
      for dependency in parsed_manifest.dependencies {
        if options.exclude_selectors.any(selector => {
            !selector_has_version(selector) &&
            filter_matches(dependency, selector)
          }) {
          continue
        }
        if !options.include_selectors.is_empty() &&
          !options.include_selectors.any(selector => {
            filter_matches(dependency, selector)
          }) {
          continue
        }
        if dependency.source == Mooncakes && locals.contains(dependency.name) {
          continue
        }
        match dependency.source {
          GitHubActions =>
            if !gha_seen.contains(dependency.name) {
              gha_seen[dependency.name] = ()
              gha_targets.push(dependency.name)
            }
          _ =>
            if !mooncakes_seen.contains(dependency.name) {
              mooncakes_seen[dependency.name] = ()
              mooncakes_targets.push(dependency.name)
            }
        }
      }
    }
    if !mooncakes_targets.is_empty() || !gha_targets.is_empty() {
      let sem = @async.Semaphore(FETCH_MAX_CONCURRENCY)
      @async.with_task_group(group => {
        for name in mooncakes_targets {
          group.spawn_bg(async fn() {
            sem.acquire()
            defer sem.release()
            let value : FetchResult = FetchSuccess(fetch(name)) catch {
              error => FetchFailure(error)
            }
            fetched_mooncakes[name] = value
          })
        }
        for repo in gha_targets {
          group.spawn_bg(async fn() {
            sem.acquire()
            defer sem.release()
            let value : FetchResult = FetchSuccess(fetch_gha(repo)) catch {
              error => FetchFailure(error)
            }
            fetched_gha[repo] = value
          })
        }
      }) catch {
        _ => ()
      }
    }
  }
  let snapshots : Array[Manifest] = []
  let entries : Array[DependencyChange] = []
  let diagnostics : Array[Diagnostic] = []
  for manifest in manifests {
    let item = check_single_manifest_internal(
      manifest,
      options~,
      local_modules=locals,
      fetched_mooncakes~,
      fetched_gha~,
      fetch~,
      fetch_gha~,
    )
    snapshots.append(item.snapshots)
    entries.append(item.entries)
    diagnostics.append(item.issues)
  }
  dispatch_check_callbacks(
    make_plan(
      snapshots,
      entries,
      diagnostics,
      cwd=options.cwd,
      gha_style=options.gha_style,
    ),
    options.callbacks,
  )
}

///|
async fn check_single_manifest_internal(
  manifest : Manifest,
  options~ : CheckOptions,
  local_modules~ : Map[String, Unit],
  fetched_mooncakes~ : Map[String, FetchResult],
  fetched_gha~ : Map[String, FetchResult],
  fetch~ : async (String) -> ModuleMetadata raise RegistryError,
  fetch_gha~ : async (String) -> ModuleMetadata raise RegistryError,
) -> CheckPlan {
  // Reparse authoritative source bytes so callers cannot mutate `dependencies`
  // to bypass diagnostics or desync spans.
  let parsed = match manifest.kind {
    MoonMod =>
      parse_manifest(
        manifest.source,
        path=manifest.path,
        module_name=manifest.module_name,
      )
    GitHubActions =>
      parse_github_actions_manifest(manifest.source, path=manifest.path)
  }
  if has_error_diagnostics(parsed.diagnostics) {
    return make_plan([], [], parsed.diagnostics, cwd=options.cwd)
  }
  let manifest = parsed.manifest.unwrap()
  let mut invalid_selector : String? = None
  for selector in options.include_selectors {
    if (!name_selector_valid(selector) || selector_has_version(selector)) &&
      invalid_selector is None {
      invalid_selector = Some(selector)
    }
  }
  for selector in options.exclude_selectors {
    if !selector_valid(selector) && invalid_selector is None {
      invalid_selector = Some(selector)
    }
  }
  if invalid_selector is Some(selector) {
    let changes = manifest.dependencies.map(dependency => {
      selector_error_change(dependency, options.mode, selector)
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
    return make_plan([manifest], changes, diagnostics, cwd=options.cwd)
  }
  let changes : Array[DependencyChange] = []
  let diagnostics : Array[Diagnostic] = parsed.diagnostics.copy()
  for dependency in manifest.dependencies {
    if options.exclude_selectors.any(selector => {
        !selector_has_version(selector) && filter_matches(dependency, selector)
      }) {
      changes.push(skipped_change(dependency, options.mode, "excluded"))
      continue
    }
    if !options.include_selectors.is_empty() &&
      !options.include_selectors.any(selector => {
        filter_matches(dependency, selector)
      }) {
      changes.push(skipped_change(dependency, options.mode, "not_included"))
      continue
    }
    if dependency.source == Mooncakes && local_modules.contains(dependency.name) {
      let local_dependency = { ..dependency, source: LocalWorkspace, }
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
        mode: options.mode,
        status: Skipped,
        target: None,
        target_sha: None,
        latest_available: None,
        candidates: [],
        diff: None,
        reason: Some("local_workspace"),
        diagnostics: [note],
      })
      diagnostics.push(note)
      continue
    }
    let fetched_value = match dependency.source {
      GitHubActions =>
        match fetched_gha.get(dependency.name) {
          Some(value) => value
          None => {
            let value : FetchResult = FetchSuccess(fetch_gha(dependency.name)) catch {
              error => FetchFailure(error)
            }
            fetched_gha[dependency.name] = value
            value
          }
        }
      _ =>
        match fetched_mooncakes.get(dependency.name) {
          Some(value) => value
          None => {
            let value : FetchResult = FetchSuccess(fetch(dependency.name)) catch {
              error => FetchFailure(error)
            }
            fetched_mooncakes[dependency.name] = value
            value
          }
        }
    }
    match fetched_value {
      FetchSuccess(metadata) => {
        let change = match dependency.source {
          GitHubActions =>
            if !valid_gha_metadata(metadata, dependency.name) {
              invalid_metadata_change(
                dependency,
                options.mode,
                "invalid GitHub Actions metadata",
              )
            } else {
              resolve_dependency(
                dependency,
                metadata,
                options.mode,
                exclude=options.exclude_selectors,
                options=options.release,
                gha_style=options.gha_style,
              )
            }
          _ =>
            match metadata_is_valid(metadata, dependency.name) {
              Some(reason) =>
                invalid_metadata_change(dependency, options.mode, reason)
              None =>
                resolve_dependency(
                  dependency,
                  metadata,
                  options.mode,
                  exclude=options.exclude_selectors,
                  options=options.release,
                  gha_style=options.gha_style,
                )
            }
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
          mode: options.mode,
          status: Error,
          target: None,
          target_sha: None,
          latest_available: None,
          candidates: [],
          diff: None,
          reason: Some(error.code()),
          diagnostics: [diag],
        })
      }
    }
  }
  make_plan(
    [manifest],
    changes,
    diagnostics,
    cwd=options.cwd,
    gha_style=options.gha_style,
  )
}

///|
/// Read a manifest (`moon.mod` or GitHub Actions YAML) from disk and check it.
pub async fn check_path(
  path : String,
  module_name~ : String = "",
  options~ : CheckOptions = CheckOptions(),
) -> CheckPlan {
  let source = @fs.read_binary(path) catch {
    error => {
      let diag = diagnostic(
        "manifest_read_error",
        error.to_string(),
        Some(path),
        None,
        None,
        None,
      )
      return make_plan([], [], [diag], cwd=options.cwd)
    }
  }
  let parsed = if is_github_actions_path(path) {
    parse_github_actions_manifest(source, path~)
  } else {
    let resolved_name = if module_name.is_empty() {
      module_name_from_source(source)
    } else {
      module_name
    }
    parse_manifest(source, path~, module_name=resolved_name)
  }
  match parsed.manifest {
    None => make_plan([], [], parsed.diagnostics, cwd=options.cwd)
    Some(manifest) => {
      if has_error_diagnostics(parsed.diagnostics) {
        return make_plan([], [], parsed.diagnostics, cwd=options.cwd)
      }
      check(manifest, options~)
    }
  }
}
