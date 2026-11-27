///|
#cfg(target="native")
extern "C" fn terminate_process(code : Int32) = "exit"

///|
#cfg(target="native")
extern "C" fn moon_taze_stdin_isatty() -> Bool = "moon_taze_stdin_isatty"

///|
#cfg(target="native")
extern "C" fn moon_taze_stdout_isatty() -> Bool = "moon_taze_stdout_isatty"

///|
#cfg(target="native")
extern "C" fn moon_taze_get_console_output_cp() -> UInt32 = "moon_taze_get_console_output_cp"

///|
#cfg(target="native")
extern "C" fn moon_taze_set_console_output_cp(cp : UInt32) = "moon_taze_set_console_output_cp"

///|
#cfg(target="native")
fn interactive_terminal_available() -> Bool {
  moon_taze_stdin_isatty()
}

///|
#cfg(target="native")
fn stdout_terminal_available() -> Bool {
  moon_taze_stdout_isatty()
}

///|
#cfg(target="native")
fn restore_console_output_cp(cp : UInt32) -> Unit {
  if cp != 0U {
    moon_taze_set_console_output_cp(cp)
  }
}

///|
async fn fetch_mooncakes_version_cli(
  module_name : String,
  version : String,
) -> @taze.VersionMetadata? raise @taze.RegistryError {
  Some(
    @taze.query_mooncakes_version(
      root="https://mooncakes.io",
      module_name,
      version,
    ),
  )
}

///|
async fn default_gha_fetch_cli(
  repo : String,
) -> @taze.ModuleMetadata raise @taze.RegistryError {
  @taze.query_github_tags(repo)
}

///|
async fn default_gha_commit_date_cli(
  repo : String,
  sha : String,
) -> Int64? raise @taze.RegistryError {
  @taze.query_github_commit_date(repo, sha)
}

///|
async fn enrich_release_times(
  metadata : @taze.ModuleMetadata,
  fetch_version : async (String, String) -> @taze.VersionMetadata? raise @taze.RegistryError,
  detail_times : Map[String, Int64],
  detail_missing : Map[String, Bool],
  retries : Int32,
  delay_ms : Int32,
) -> @taze.ModuleMetadata raise @taze.RegistryError {
  let versions = metadata.versions.copy()
  for index in 0..<versions.length() {
    let item = versions[index]
    let key = metadata.module_name + "@" + item.version
    match item.published_at {
      Some(value) => detail_times[key] = value
      None if detail_times.contains(key) || detail_missing.contains(key) => ()
      None => {
        let timestamp = @taze.retry_registry(retries~, delay_ms~, () => {
          fetch_version(metadata.module_name, item.version)
        })
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
  @taze.ModuleMetadata(metadata.module_name, metadata.latest, versions)
}

///|
async fn enrich_gha_release_times(
  metadata : @taze.ModuleMetadata,
  fetch_commit_date : async (String, String) -> Int64? raise @taze.RegistryError,
  detail_times : Map[String, Int64],
  detail_missing : Map[String, Bool],
  retries : Int32,
  delay_ms : Int32,
) -> @taze.ModuleMetadata noraise {
  let versions = metadata.versions.copy()
  for index in 0..<versions.length() {
    let item = versions[index]
    let key = metadata.module_name + "@" + item.version
    match item.published_at {
      Some(value) => detail_times[key] = value
      None if detail_times.contains(key) || detail_missing.contains(key) => ()
      None =>
        if item.sha is Some(sha) {
          let ts = @taze.retry_registry(retries~, delay_ms~, () => {
            fetch_commit_date(metadata.module_name, sha)
          }) catch {
            _ => None
          }
          match ts {
            Some(published_at) => {
              detail_times[key] = published_at
              versions[index] = @taze.VersionMetadata(
                item.version,
                item.yanked,
                item.yanked_reason,
                Some(published_at),
                sha=item.sha,
              )
            }
            None => detail_missing[key] = true
          }
        }
    }
  }
  @taze.ModuleMetadata(metadata.module_name, metadata.latest, versions)
}

///|
priv enum AgeFetchTask {
  MooncakesAge(String, String)
  GitHubAge(String, String, String)
}

///|
fn seed_detail_times_from_cache(
  cache : Map[String, @taze.ModuleMetadata],
  detail_times : Map[String, Int64],
) -> Unit {
  for _, metadata in cache {
    for item in metadata.versions {
      if item.published_at is Some(ts) {
        detail_times[metadata.module_name + "@" + item.version] = ts
      }
    }
  }
}

///|
fn apply_detail_times_to_cache(
  cache : Map[String, @taze.ModuleMetadata],
  detail_times : Map[String, Int64],
) -> Bool {
  let mut updated_any = false
  let keys = cache.keys().to_array()
  for key in keys {
    guard cache.get(key) is Some(metadata) else { continue }
    let mut changed = false
    let versions = metadata.versions.copy()
    for i in 0..<versions.length() {
      let item = versions[i]
      if item.published_at is None {
        let time_key = metadata.module_name + "@" + item.version
        if detail_times.get(time_key) is Some(ts) {
          versions[i] = @taze.VersionMetadata(
            item.version,
            item.yanked,
            item.yanked_reason,
            Some(ts),
            sha=item.sha,
          )
          changed = true
        }
      }
    }
    if changed {
      cache[key] = @taze.ModuleMetadata(
        metadata.module_name,
        metadata.latest,
        versions,
      )
      updated_any = true
    }
  }
  updated_any
}

///|
async fn merge_config(
  options : CliOptions,
  config_root : String,
  emit~ : (String) -> Unit,
) -> Unit {
  let config_path = config_root + "/moon-taze.json"
  if !@fs.exists(config_path) {
    return
  }
  let loaded = @taze.read_config(config_path)
  if !options.json_output && !options.silent {
    for issue in loaded.diagnostics {
      emit("error[\{issue.code}]: \{issue.message}")
    }
  }
  guard loaded.config is Some(config) else {
    cli_error("invalid_config")
    return
  }
  if config.mode is Some(value) && !options.mode_seen {
    match parse_mode(value) {
      Some(parsed) => options.mode = parsed
      None => cli_error("invalid_config: unknown mode \{value}")
    }
  }
  if !options.recursive_seen && config.recursive is Some(value) {
    options.recursive = value
  }
  if !options.all_seen && config.all is Some(value) {
    options.show_all = value
  }
  if options.include_selectors.is_empty() &&
    config.include_selectors is Some(values) {
    options.include_selectors.append(values)
  }
  if options.exclude_selectors.is_empty() && config.exclude is Some(values) {
    options.exclude_selectors.append(values)
  }
  if !options.retry_seen && config.retry is Some(value) {
    if value < 0 {
      cli_error("invalid_config: retry must be non-negative")
    }
    options.retry_count = value
  }
  if !options.force_seen && config.force is Some(value) {
    options.force = value
  }
  if !options.fail_on_outdated_seen && config.failOnOutdated is Some(value) {
    options.fail_on_outdated = value
  }
  if !options.timediff_seen && config.timediff is Some(value) {
    options.timediff = value
  }
  if !options.maturity_seen && config.maturityPeriod is Some(value) {
    if value < 0 {
      cli_error("invalid_config: maturityPeriod must be non-negative")
    }
    options.maturity_days = value
  }
  if !options.maturity_exclude_seen &&
    config.maturityPeriodExclude is Some(values) {
    options.maturity_exclude.append(values)
  }
  let (gha_enabled, gha_style) = config.resolve_github_actions() catch {
    err => {
      cli_error("invalid_config: \{err}")
      (None, None)
    }
  }
  if !options.github_actions_seen && gha_enabled is Some(value) {
    options.github_actions = value
  }
  if !options.github_actions_style_seen && gha_style is Some(value) {
    options.github_actions_style = value
  }
}

///|
async fn run_cli(
  args : Array[String],
  fetch~ : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError,
  emit~ : (String) -> Unit,
  cache~ : Map[String, @taze.ModuleMetadata] = Map([]),
  cache_times~ : Map[String, UInt64] = Map([]),
  cache_path~ : String? = None,
  retry_delay_ms~ : Int32 = 0,
  fetch_version~ : async (String, String) -> @taze.VersionMetadata? raise @taze.RegistryError = (
    _,
    _,
  ) => None,
  fetch_gha~ : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError = default_gha_fetch_cli,
  fetch_gha_commit_date~ : async (String, String) -> Int64? raise @taze.RegistryError = (
    _,
    _,
  ) => None,
  interactive_tty~ : Bool? = None,
  color~ : Bool? = None,
  now_ms~ : Int64? = None,
  session~ : @clack_prompts.Session? = None,
  run_verify~ : (async (String, (String) -> Unit) -> VerificationResult)? = None,
) -> Int32 {
  run_cli_inner(
    args,
    fetch~,
    emit~,
    cache~,
    cache_times,
    cache_path,
    retry_delay_ms,
    fetch_version,
    fetch_gha,
    fetch_gha_commit_date,
    interactive_tty,
    color,
    now_ms,
    session,
    run_verify,
  ) catch {
    CliError(code~, message~) => {
      if args.any(item => item == "--json") {
        emit(render_cli_error_json(code, message))
      } else {
        emit("error[\{code}]: \{message}")
      }
      2
    }
    error => {
      if args.any(item => item == "--json") {
        emit(render_cli_error_json("cli_error", "\{error}"))
      } else {
        emit("error: \{error}")
      }
      2
    }
  }
}

///|
async fn run_cli_inner(
  args : Array[String],
  fetch~ : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError,
  emit~ : (String) -> Unit,
  cache~ : Map[String, @taze.ModuleMetadata],
  cache_times : Map[String, UInt64],
  cache_path : String?,
  retry_delay_ms : Int32,
  fetch_version : async (String, String) -> @taze.VersionMetadata? raise @taze.RegistryError,
  fetch_gha : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError,
  fetch_gha_commit_date : async (String, String) -> Int64? raise @taze.RegistryError,
  interactive_tty : Bool?,
  color : Bool?,
  now_ms : Int64?,
  session : @clack_prompts.Session?,
  run_verify : (async (String, (String) -> Unit) -> VerificationResult)?,
) -> Int32 {
  let options = match parse_cli_args(args) {
    Help(text) => {
      emit(text)
      return 0
    }
    Version(text) => {
      emit(text)
      return 0
    }
    Parsed(opts) => opts
  }
  options.cwd = @fs.realpath(options.cwd) catch { _ => options.cwd }
  let manifest_path = match find_manifest(options.cwd) {
    Some(path) => {
      let manifest_dir = parent_path(path).unwrap_or(options.cwd)
      if @fs.exists(manifest_dir + "\\moon.mod.json") ||
        @fs.exists(manifest_dir + "/moon.mod.json") {
        cli_error("ambiguous_manifest: both moon.mod and moon.mod.json exist")
      }
      Some(path)
    }
    None => None
  }
  let workspace_path = find_workspace(options.cwd)
  let config_root = match workspace_path {
    Some(path) => parent_path(path).unwrap_or(options.cwd)
    None =>
      match manifest_path {
        Some(path) => parent_path(path).unwrap_or(options.cwd)
        None => options.cwd
      }
  }
  merge_config(options, config_root, emit~)
  if options.verify && !options.write && !options.interactive {
    cli_error("invalid_option: --verify requires --write or --interactive")
  }
  let effective_interactive = options.interactive && !options.json_output
  let use_color = match color {
    Some(flag) => flag && !options.json_output
    None =>
      !options.json_output && should_use_color(interactive_tty.unwrap_or(false))
  }
  let interactive_session : @clack_prompts.Session? = if effective_interactive {
    match session {
      Some(s) => {
        if !s.is_interactive() {
          cli_error(
            "interactive mode (-I/--interactive) requires an interactive terminal",
            code="not_interactive",
          )
        }
        Some(s)
      }
      None => {
        let color_level : @clack_ansi.ColorLevel = if use_color {
          Ansi16
        } else {
          None
        }
        let s = @clack_prompts.Session(color_level~, non_interactive=Fail)
        if !interactive_tty.unwrap_or(false) || !s.is_interactive() {
          cli_error(
            "interactive mode (-I/--interactive) requires an interactive terminal",
            code="not_interactive",
          )
        }
        Some(s)
      }
    }
  } else {
    None
  }
  for selector in options.maturity_exclude {
    if !@taze.selector_valid(selector) {
      cli_error("invalid maturity exclusion: \{selector}")
    }
  }
  let manifests : Array[@taze.Manifest] = []
  let local_modules : Array[String] = []
  let mut workspace_root : String? = None
  if workspace_path is Some(path) {
    let parsed_workspace = @taze.read_workspace(path)
    if !options.json_output && !options.silent {
      for diag in parsed_workspace.diagnostics {
        let level = match diag.severity {
          Warning => "warning"
          Error => "error"
        }
        emit("\{level}[\{diag.code}]: \{diag.message}")
      }
    }
    guard parsed_workspace.workspace is Some(workspace) else {
      cli_error("invalid_workspace")
      return 2
    }
    workspace_root = Some(workspace.root)
    for item in workspace.members {
      local_modules.push(item.module_name)
    }
    let normalized_cwd = @fs.realpath(options.cwd) catch { _ => options.cwd }
    let normalized_root = @fs.realpath(workspace.root) catch {
      _ => workspace.root
    }
    if normalized_cwd == normalized_root {
      for item in workspace.members {
        manifests.push(item.manifest)
      }
    }
  }
  if manifests.is_empty() && manifest_path is Some(path) {
    let source = @fs.read_binary(path) catch {
      error => {
        cli_error("manifest_read_error: \{error}")
        b""
      }
    }
    let module_name = @taze.module_name_from_source(source)
    let parsed = @taze.parse_manifest(source, path~, module_name~)
    guard parsed.manifest is Some(manifest) else {
      if !options.json_output && !options.silent {
        for diag in parsed.diagnostics {
          emit("error[\{diag.code}]: \{diag.message}")
        }
      }
      return 2
    }
    manifests.push(manifest)
  }
  if options.recursive {
    let scan_root = workspace_root.unwrap_or(options.cwd)
    let discovered : Array[String] = []
    @fs.walk(
      scan_root,
      async fn(directory, _) {
        if !is_ignored_dir(directory) {
          let candidate = directory + "/moon.mod"
          if @fs.exists(candidate) {
            discovered.push(candidate)
          }
        }
      },
      max_concurrency=1,
    ) catch {
      _ => ()
    }
    discovered.sort()
    for path in discovered {
      if !manifests.any(item => item.path == path) {
        let source = @fs.read_binary(path) catch { _ => continue }
        let module_name = @taze.module_name_from_source(source)
        let parsed = @taze.parse_manifest(source, path~, module_name~)
        match parsed.manifest {
          Some(manifest) => manifests.push(manifest)
          None =>
            if !options.json_output && !options.silent {
              for diag in parsed.diagnostics {
                emit("error[\{diag.code}]: \{diag.message}")
              }
            }
        }
      }
    }
  }
  // Discover GitHub Actions workflows & composite actions if enabled.
  if options.github_actions {
    let gha_root = workspace_root.unwrap_or(config_root)
    let gha_paths = discover_github_actions_paths(
      gha_root,
      recursive=options.recursive,
    )
    for path in gha_paths {
      let source = @fs.read_binary(path) catch { _ => continue }
      let parsed = @taze.parse_github_actions_manifest(source, path~)
      if parsed.manifest is Some(manifest) && !manifest.dependencies.is_empty() {
        manifests.push(manifest)
      }
    }
  }
  if manifests.is_empty() {
    match find_legacy_manifest(options.cwd) {
      Some(path) =>
        cli_error(
          "unsupported_manifest: moon.mod.json is not supported at \{path}",
        )
      None => cli_error("no_manifest: no moon.mod found from \{options.cwd}")
    }
  }
  let unique_targets : Map[String, Unit] = Map([])
  for manifest in manifests {
    for dep in manifest.dependencies {
      let tag = match dep.source {
        GitHubActions => "gha:" + dep.name
        _ => "mc:" + dep.name
      }
      unique_targets[tag] = ()
    }
  }
  let progress_total = unique_targets.length()
  let progress_enabled = match interactive_tty {
    Some(true) => !options.json_output && !options.silent && progress_total > 0
    _ => false
  }
  let style = Style::new(use_color)
  let progress = progress_bar(progress_total, progress_enabled, color=use_color)
  progress_bar_start(progress)
  defer @async.protect_from_cancel(() => progress_bar_stop(progress))
  let need_release_times = options.sort_mode == "time-asc" ||
    options.sort_mode == "time-desc" ||
    options.maturity_days > 0 ||
    options.mode == Newest ||
    options.mode == Next
  let detail_times : Map[String, Int64] = Map([])
  let detail_missing : Map[String, Bool] = Map([])
  if !options.force {
    seed_detail_times_from_cache(cache, detail_times)
  }
  let cache_dirty = Ref(false)
  let effective_fetch : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError = name => {
    defer (@async.protect_from_cancel(() => progress_bar_update(progress, name)) catch {
      _ => ()
    })
    let registry_root = "https://mooncakes.io"
    let key = mooncakes_cache_key(registry_root, name)
    if !options.force {
      let cached = match cache.get(key) {
        Some(value) => Some(value)
        None => cache.get(name)
      }
      if cached is Some(value) {
        return if need_release_times {
          enrich_release_times(
            value,
            fetch_version,
            detail_times,
            detail_missing,
            options.retry_count,
            retry_delay_ms,
          )
        } else {
          value
        }
      }
    }
    let value = @taze.retry_registry(
      retries=options.retry_count,
      delay_ms=retry_delay_ms,
      () => fetch(name),
    )
    let enriched = if need_release_times {
      enrich_release_times(
        value,
        fetch_version,
        detail_times,
        detail_missing,
        options.retry_count,
        retry_delay_ms,
      )
    } else {
      value
    }
    cache[key] = enriched
    cache_times[key] = @env.now()
    cache_dirty.val = true
    enriched
  }
  let effective_fetch_gha : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError = repo => {
    defer (@async.protect_from_cancel(() => progress_bar_update(progress, repo)) catch {
      _ => ()
    })
    let key = gha_cache_key(repo)
    if !options.force && cache.get(key) is Some(value) {
      return if need_release_times {
        enrich_gha_release_times(
          value,
          fetch_gha_commit_date,
          detail_times,
          detail_missing,
          options.retry_count,
          retry_delay_ms,
        )
      } else {
        value
      }
    }
    let value = @taze.retry_registry(
      retries=options.retry_count,
      delay_ms=retry_delay_ms,
      () => fetch_gha(repo),
    )
    let enriched = if need_release_times {
      enrich_gha_release_times(
        value,
        fetch_gha_commit_date,
        detail_times,
        detail_missing,
        options.retry_count,
        retry_delay_ms,
      )
    } else {
      value
    }
    cache[key] = enriched
    cache_times[key] = @env.now()
    cache_dirty.val = true
    enriched
  }
  let release = @taze.ReleaseOptions(
    @env.now().reinterpret_as_int64(),
    options.maturity_days,
    maturity_exclude=options.maturity_exclude,
  )
  let check_options = @taze.CheckOptions(
    mode=options.mode,
    include_selectors=options.include_selectors,
    exclude_selectors=options.exclude_selectors,
    local_modules~,
    release~,
    gha_style=options.github_actions_style,
    cwd=options.cwd,
  )
  let plan = @taze.check_manifests(
    manifests,
    options=check_options,
    fetch=effective_fetch,
    fetch_gha=effective_fetch_gha,
  )
  if cache_dirty.val {
    save_persistent_cache(cache_path, cache, cache_times) catch {
      _ => ()
    }
    cache_dirty.val = false
  }
  let extra_diagnostics : Array[@taze.Diagnostic] = []
  // Lazily and concurrently fetch display ages ONLY for displayed current/target
  // versions not already present in cache, keeping the progress bar live.
  let fetch_display_ages = options.timediff &&
    (!options.silent || options.json_output)
  if fetch_display_ages {
    let age_tasks : Array[AgeFetchTask] = []
    let age_seen : Map[String, Unit] = Map([])
    for change in plan.changes() {
      let interactive_latest = effective_interactive &&
        change.status is NoCandidate &&
        change.latest_available is Some(_)
      let should_display = change.status is UpdateAvailable ||
        interactive_latest ||
        (options.show_all && change.status is UpToDate)
      if !should_display {
        continue
      }
      match change.dependency.source {
        Mooncakes => {
          let versions = [change.dependency.version]
          if change.target is Some(target) && !versions.contains(target) {
            versions.push(target)
          }
          if interactive_latest &&
            change.latest_available is Some(latest) &&
            !versions.contains(latest) {
            versions.push(latest)
          }
          for version in versions {
            let key = change.dependency.name + "@" + version
            if !detail_times.contains(key) &&
              !detail_missing.contains(key) &&
              !age_seen.contains(key) {
              age_seen[key] = ()
              age_tasks.push(MooncakesAge(change.dependency.name, version))
            }
          }
        }
        GitHubActions => {
          let gha_targets : Array[(String, String)] = []
          if change.target is Some(target) && change.target_sha is Some(sha) {
            gha_targets.push((target, sha))
          }
          if interactive_latest &&
            change.latest_available is Some(latest) &&
            change.candidate_shas.get(latest) is Some(sha) {
            gha_targets.push((latest, sha))
          }
          for item in gha_targets {
            let (target, sha) = item
            let key = change.dependency.name + "@" + target
            if !detail_times.contains(key) &&
              !detail_missing.contains(key) &&
              !age_seen.contains(key) {
              age_seen[key] = ()
              age_tasks.push(GitHubAge(change.dependency.name, target, sha))
            }
          }
        }
        _ => ()
      }
    }
    if !age_tasks.is_empty() {
      progress_bar_set_phase(progress, "age", age_tasks.length())
      let age_retries = if options.retry_count > 1 {
        1
      } else {
        options.retry_count
      }
      let sem = @async.Semaphore(8)
      @async.with_task_group(group => {
        for task in age_tasks {
          group.spawn_bg(async fn() {
            sem.acquire()
            defer sem.release()
            match task {
              MooncakesAge(name, version) => {
                let key = name + "@" + version
                defer (@async.protect_from_cancel(() => {
                  progress_bar_update(progress, key)
                }) catch {
                  _ => ()
                })
                let detail = @taze.retry_registry(
                  retries=age_retries,
                  delay_ms=retry_delay_ms,
                  () => fetch_version(name, version),
                ) catch {
                  _ => None
                }
                match detail {
                  Some(value) if value.published_at is Some(time) =>
                    detail_times[key] = time
                  _ => detail_missing[key] = true
                }
              }
              GitHubAge(repo, target, sha) => {
                let key = repo + "@" + target
                defer (@async.protect_from_cancel(() => {
                  progress_bar_update(progress, key)
                }) catch {
                  _ => ()
                })
                let ts = @taze.retry_registry(
                  retries=age_retries,
                  delay_ms=retry_delay_ms,
                  () => fetch_gha_commit_date(repo, sha),
                ) catch {
                  _ => None
                }
                match ts {
                  Some(time) => detail_times[key] = time
                  None => detail_missing[key] = true
                }
              }
            }
          })
        }
      }) catch {
        _ => ()
      }
      if apply_detail_times_to_cache(cache, detail_times) {
        save_persistent_cache(cache_path, cache, cache_times) catch {
          _ => ()
        }
      }
    }
  }
  progress_bar_stop(progress)
  let display_now = now_ms.unwrap_or(@env.now().reinterpret_as_int64())
  if plan.has_errors() {
    render_text_report(
      manifests,
      plan,
      options,
      detail_times,
      extra_diagnostics,
      style,
      now=display_now,
      emit~,
    )
    if options.json_output {
      emit(
        render_json(
          plan,
          options.mode,
          None,
          [],
          options.fail_on_outdated,
          published_at=detail_times,
          extra_diagnostics~,
        ),
      )
    }
    return 2
  }
  if interactive_session is Some(active_session) {
    let outcome = run_interactive_picker(
      manifests, plan, options, detail_times, detail_missing, cache, cache_times,
      cache_path, fetch_version, fetch_gha_commit_date, retry_delay_ms, style, display_now,
      active_session,
    ) catch {
      @clack_term.TermError::NotInteractive(msg) => {
        cli_error(msg, code="not_interactive")
        Cancelled
      }
      @clack_term.TermError::EndOfInput => Cancelled
      @clack_term.TermError::IoFailure(msg) => {
        cli_error(msg, code="tty_error")
        Cancelled
      }
    }
    match outcome {
      NoCandidates => {
        render_text_report(
          manifests,
          plan,
          options,
          detail_times,
          extra_diagnostics,
          style,
          now=display_now,
          emit~,
        )
        return 0
      }
      Cancelled => return 0
      Confirmed(picked) => {
        if picked.selected_tuples.is_empty() {
          if !options.silent {
            emit(style.green("dependencies are already up-to-date"))
          }
          return 0
        }
        render_changes_report(
          manifests,
          picked.display_changes,
          plan.diagnostics(),
          false,
          options,
          detail_times,
          extra_diagnostics,
          style,
          now=display_now,
          show_footer_tips=false,
          emit~,
        )
        let files_label = target_files_label(manifests, picked.display_changes)
        let should_write = if options.write {
          true
        } else {
          let confirm_res = @clack_prompts.confirm(
            "write to \{files_label}?",
            initial_value=true,
            session=active_session,
          ) catch {
            _ => Cancelled
          }
          match confirm_res {
            Submitted(true) => true
            Submitted(false) => {
              if !options.silent {
                emit("")
                if options.mode == Default {
                  let cmd_hint = style.cyan("moon-taze major")
                  emit("Run \{cmd_hint} to check major updates")
                }
                let write_flag = style.green("-w")
                emit("Add \{write_flag} to write to \{files_label}")
                emit("")
              }
              return if options.fail_on_outdated { 1 } else { 0 }
            }
            Cancelled | StepBack => return 0
          }
        }
        if !should_write {
          return if options.fail_on_outdated { 1 } else { 0 }
        }
        let report = @taze.apply(plan, plan.selection(picked.selected_tuples))
        if !options.silent {
          if !report.diagnostics().is_empty() {
            emit(style.inverse_red_bold(" ERROR "))
            emit("")
            for diag in report.diagnostics() {
              emit(style.red("> [\{diag.code}] \{diag.message}"))
            }
            emit("")
          } else if report.written_files() > 0 {
            emit(style.yellow("ℹ changes written to \{files_label}"))
          }
        }
        let verification : Array[VerificationResult] = []
        if report.status() == Succeeded && report.written_files() > 0 {
          let written_moon_dirs : Array[String] = []
          for file in report.files() {
            if file.status() == Written &&
              !@taze.is_github_actions_path(file.manifest()) {
              let directory = parent_path(file.manifest()).unwrap_or(
                options.cwd,
              )
              if !written_moon_dirs.contains(directory) {
                written_moon_dirs.push(directory)
              }
            }
          }
          if !written_moon_dirs.is_empty() {
            let should_verify = if options.verify {
              true
            } else {
              let verify_res = @clack_prompts.confirm(
                "run moon check now?",
                initial_value=true,
                session=active_session,
              ) catch {
                _ => Cancelled
              }
              match verify_res {
                Submitted(true) => true
                _ => false
              }
            }
            if should_verify {
              let verify_fn = match run_verify {
                Some(f) => f
                None => async fn(dir, out) { verify_directory(dir, emit=out) }
              }
              match workspace_root {
                Some(root) => verification.push(verify_fn(root, emit))
                None => {
                  written_moon_dirs.sort()
                  for directory in written_moon_dirs {
                    verification.push(verify_fn(directory, emit))
                  }
                }
              }
            }
          }
        }
        if report.exit_code() != 0 || verification.any(item => !item.passed) {
          return 2
        }
        if options.fail_on_outdated {
          return 1
        }
        return 0
      }
    }
  }
  render_text_report(
    manifests,
    plan,
    options,
    detail_times,
    extra_diagnostics,
    style,
    now=display_now,
    emit~,
  )
  if options.write {
    let report = @taze.apply(plan, plan.recommended_selection())
    let verification : Array[VerificationResult] = []
    if options.verify &&
      report.status() == Succeeded &&
      report.written_files() > 0 {
      let verify_emit : (String) -> Unit = if options.json_output {
        _ => ()
      } else {
        emit
      }
      let verify_fn = match run_verify {
        Some(f) => f
        None => async fn(dir, out) { verify_directory(dir, emit=out) }
      }
      let written_moon_dirs : Array[String] = []
      for file in report.files() {
        if file.status() == Written &&
          !@taze.is_github_actions_path(file.manifest()) {
          let directory = parent_path(file.manifest()).unwrap_or(options.cwd)
          if !written_moon_dirs.contains(directory) {
            written_moon_dirs.push(directory)
          }
        }
      }
      if !written_moon_dirs.is_empty() {
        match workspace_root {
          Some(root) => verification.push(verify_fn(root, verify_emit))
          None => {
            written_moon_dirs.sort()
            for directory in written_moon_dirs {
              verification.push(verify_fn(directory, verify_emit))
            }
          }
        }
      }
    }
    if options.json_output {
      emit(
        render_json(
          plan,
          options.mode,
          Some(report),
          verification,
          options.fail_on_outdated,
          published_at=detail_times,
          extra_diagnostics~,
        ),
      )
    } else if !options.silent {
      if !report.diagnostics().is_empty() {
        emit(style.inverse_red_bold(" ERROR "))
        emit("")
        for diag in report.diagnostics() {
          emit(style.red("> [\{diag.code}] \{diag.message}"))
        }
        emit("")
      } else if report.written_files() > 0 {
        let files_label = target_files_label(manifests, plan.changes())
        let has_moon_written = report
          .files()
          .any(f => {
            f.status() == Written && !@taze.is_github_actions_path(f.manifest())
          })
        if !options.verify && has_moon_written {
          emit(
            style.yellow("ℹ changes written to \{files_label}, run ") +
            style.cyan("moon check") +
            style.yellow(" to verify."),
          )
        } else {
          emit(style.yellow("ℹ changes written to \{files_label}"))
        }
      }
    }
    if report.exit_code() != 0 || verification.any(item => !item.passed) {
      return 2
    }
    if options.fail_on_outdated &&
      plan.changes().any(item => item.status is UpdateAvailable) {
      return 1
    }
    return 0
  }
  if options.json_output {
    emit(
      render_json(
        plan,
        options.mode,
        None,
        [],
        options.fail_on_outdated,
        published_at=detail_times,
        extra_diagnostics~,
      ),
    )
  }
  if options.fail_on_outdated &&
    plan.changes().any(item => item.status is UpdateAvailable) {
    1
  } else {
    0
  }
}

///|
async fn main {
  let old_cp = moon_taze_get_console_output_cp()
  if old_cp != 0U {
    moon_taze_set_console_output_cp(65001U)
  }
  defer restore_console_output_cp(old_cp)
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
    fetch_gha=default_gha_fetch_cli,
    fetch_gha_commit_date=default_gha_commit_date_cli,
    interactive_tty=Some(interactive_terminal_available()),
    color=Some(should_use_color(stdout_terminal_available())),
  )
  if code != 0 {
    terminate_process(code)
  }
}
