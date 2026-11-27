///|
/// Match upstream `taze` diff ordering: major (0) -> minor (1) -> patch (2) -> pin (3) -> prerelease (4) -> none (5).
fn diff_rank(value : @taze.DiffKind?) -> Int32 {
  match value {
    Some(Major) => 0
    Some(Minor) => 1
    Some(Patch) => 2
    Some(Pin) => 3
    Some(Prerelease) => 4
    None => 5
  }
}

///|
fn sort_changes(
  changes : Array[@taze.DependencyChange],
  sort_mode : String,
  published_at~ : Map[String, Int64] = Map([]),
) -> Array[@taze.DependencyChange] {
  let result = changes.copy()
  result.sort_by((left, right) => {
    let status_rank = fn(change : @taze.DependencyChange) -> Int32 {
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
    ) -> Int32 {
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
fn relative_display_path(path : String, root : String) -> String {
  let norm_path = path.replace_all(old="\\", new="/")
  let norm_root = root
    .replace_all(old="\\", new="/")
    .trim_end(chars="/")
    .to_owned()
  if norm_root.is_empty() {
    return norm_path
  }
  let prefix = norm_root + "/"
  if norm_path.has_prefix(prefix) {
    return norm_path[prefix.length():].to_owned()
  }
  // Windows drive-letter case insensitivity fallback.
  if norm_path.to_lower().has_prefix(prefix.to_lower()) {
    return norm_path[prefix.length():].to_owned()
  }
  norm_path
}

///|
fn manifest_display_title(manifest : @taze.Manifest, root : String) -> String {
  match manifest.kind {
    GitHubActions => relative_display_path(manifest.path, root)
    MoonMod =>
      if manifest.module_name.is_empty() {
        relative_display_path(manifest.path, root)
      } else {
        manifest.module_name
      }
  }
}

///|
fn section_label(source : @taze.DependencySource) -> String {
  match source {
    GitHubActions => "github-actions"
    LocalWorkspace => "workspace"
    _ => "import"
  }
}

///|
fn short_source_label(source : @taze.DependencySource) -> String {
  match source {
    GitHubActions => "github-actions"
    LocalWorkspace => "workspace"
    _ => ""
  }
}

///|
fn render_diff_summary(
  style : Style,
  changes : Array[@taze.DependencyChange],
) -> String {
  let mut major = 0
  let mut minor = 0
  let mut patch = 0
  let mut pin = 0
  let mut pre = 0
  for change in changes {
    if change.status == UpdateAvailable {
      match change.diff {
        Some(Major) => major += 1
        Some(Minor) => minor += 1
        Some(Patch) => patch += 1
        Some(Pin) => pin += 1
        Some(Prerelease) => pre += 1
        None => ()
      }
    }
  }
  let parts : Array[String] = []
  if major > 0 {
    parts.push("\{style.red(major.to_string())} major")
  }
  if minor > 0 {
    parts.push("\{style.cyan(minor.to_string())} minor")
  }
  if patch > 0 {
    parts.push("\{style.green(patch.to_string())} patch")
  }
  if pin > 0 {
    parts.push("\{style.blue(pin.to_string())} pin")
  }
  if pre > 0 {
    parts.push("\{style.magenta(pre.to_string())} prerelease")
  }
  if parts.is_empty() {
    style.dim("no change")
  } else {
    parts.join(", ")
  }
}

///|
fn render_change_row(
  style : Style,
  change : @taze.DependencyChange,
  grouped : Bool,
  show_ages : Bool,
  detail_times : Map[String, Int64],
  now : Int64,
) -> Array[String] {
  let is_update = change.status == UpdateAvailable && change.target is Some(_)
  let name_cell = "  " +
    (if is_update {
      change.dependency.name
    } else {
      style.gray(change.dependency.name)
    })
  let type_cell = if grouped {
    ""
  } else {
    style.gray(short_source_label(change.dependency.source))
  }
  let current_ts = detail_times.get(
    change.dependency.name + "@" + change.dependency.version,
  )
  let current_age_cell = if show_ages {
    format_colored_age(style, current_ts, now~)
  } else {
    ""
  }
  let current_ver_cell = style.gray(change.dependency.version)
  let arrow_cell = if is_update { style.dim_gray("→") } else { "" }
  let target_cell = match (change.status, change.target) {
    (UpdateAvailable, Some(target)) =>
      if change.diff == Some(Pin) {
        let short_sha = match change.target_sha {
          Some(sha) if sha.length() >= 7 => sha[:7].to_owned()
          Some(sha) => sha
          None => target
        }
        style.blue(short_sha) + " " + style.dim("# \{target}")
      } else {
        colorize_version_diff(
          style,
          change.dependency.version,
          target,
          change.diff,
        )
      }
    (UpToDate, _) => style.gray("✓")
    (Skipped, _) => style.dim(change.reason.unwrap_or("skipped"))
    (NoCandidate, _) => style.gray_strikethrough(change.dependency.version)
    _ => ""
  }
  let target_age_cell = match (is_update && show_ages, change.target) {
    (true, Some(target)) =>
      format_colored_age(
        style,
        detail_times.get(change.dependency.name + "@" + target),
        now~,
      )
    _ => ""
  }
  let available_cell = match change.latest_available {
    Some(latest) if Some(latest) != change.target =>
      style.dim_magenta("(\{latest} available)")
    _ => ""
  }
  [
    name_cell, type_cell, current_age_cell, current_ver_cell, arrow_cell, target_cell,
    target_age_cell, available_cell,
  ]
}

///|
fn render_resolve_error_lines(
  style : Style,
  change : @taze.DependencyChange,
) -> Array[String] {
  let lines : Array[String] = []
  let name = change.dependency.name
  let reason = change.reason.unwrap_or("unknown_error")
  if reason == "module_not_found" {
    lines.push(style.red("> " + style.underline_red(name) + " not found"))
  } else {
    let label = if reason == "rate_limited" {
      "rate limited"
    } else if reason == "request_timeout" {
      "request timeout"
    } else {
      "unknown error"
    }
    lines.push(style.red("> " + style.underline_red(name) + " " + label))
    if !change.diagnostics.is_empty() {
      lines.push(style.red(change.diagnostics[0].message))
    }
  }
  lines
}

///|
fn target_files_label(
  manifests : Array[@taze.Manifest],
  changes : Array[@taze.DependencyChange],
) -> String {
  let mut has_moon = false
  let mut has_gha = false
  for change in changes {
    if change.status == UpdateAvailable {
      match change.dependency.source {
        GitHubActions => has_gha = true
        _ => has_moon = true
      }
    }
  }
  if !has_moon && !has_gha {
    for m in manifests {
      match m.kind {
        GitHubActions => has_gha = true
        MoonMod => has_moon = true
      }
    }
  }
  match (has_moon, has_gha) {
    (true, true) => "moon.mod and GitHub Actions"
    (false, true) => "GitHub Actions"
    _ => "moon.mod"
  }
}

///|
/// Render the full 1:1 upstream `taze` terminal preview output.
fn render_text_report(
  manifests : Array[@taze.Manifest],
  plan : @taze.CheckPlan,
  options : CliOptions,
  detail_times : Map[String, Int64],
  extra_diagnostics : Array[@taze.Diagnostic],
  style : Style,
  now~ : Int64 = @async.now(),
  emit~ : (String) -> Unit,
) -> Unit {
  if options.json_output || options.silent {
    return
  }
  let all_changes = plan.changes()
  let lines : Array[String] = []
  let err_lines : Array[String] = []
  let mut packages_with_updates = 0
  let mut packages_with_errors = 0
  let mut total_packages = 0

  for manifest in manifests {
    total_packages += 1
    let pkg_changes = all_changes.filter(c => {
      c.dependency.manifest == manifest.path
    })
    let pkg_errors = pkg_changes.filter(c => c.status == Error)
    if !pkg_errors.is_empty() {
      packages_with_errors += 1
      for err_change in pkg_errors {
        err_lines.append(render_resolve_error_lines(style, err_change))
      }
    }
    let pkg_updates = pkg_changes.filter(c => c.status == UpdateAvailable)
    if !pkg_updates.is_empty() {
      packages_with_updates += 1
    }
    let visible = if options.show_all {
      pkg_changes.filter(c => c.status != Error)
    } else {
      pkg_updates
    }
    let title = manifest_display_title(manifest, options.cwd)
    let rel_path = relative_display_path(manifest.path, options.cwd)
    if !visible.is_empty() {
      let sorted = sort_changes(
        visible,
        options.sort_mode,
        published_at=detail_times,
      )
      let diff_summary = render_diff_summary(style, sorted)
      if lines.is_empty() {
        lines.push("")
      }
      let dash = style.dim("-")
      lines.push("\{style.cyan(title)} \{dash} \{diff_summary}")
      lines.push("")
      let rows = sorted.map(change => {
        render_change_row(
          style,
          change,
          options.group_output,
          options.timediff,
          detail_times,
          now,
        )
      })
      let table = format_table(rows, "LLRRRRRLL")
      if options.group_output {
        let sections : Array[String] = ["import", "workspace", "github-actions"]
        for section in sections {
          let section_rows : Array[String] = []
          for i, change in sorted {
            if section_label(change.dependency.source) == section {
              section_rows.push("  " + table[i])
            }
          }
          if !section_rows.is_empty() {
            if !lines.is_empty() && lines[lines.length() - 1] != "" {
              lines.push("")
            }
            lines.push("  " + style.blue(section))
            lines.append(section_rows)
          }
        }
      } else {
        lines.append(table)
      }
      lines.push("")
    } else if options.show_all && pkg_errors.is_empty() {
      if lines.is_empty() {
        lines.push("")
      }
      let subtitle = if rel_path == title {
        ""
      } else {
        " " + style.dim(rel_path)
      }
      lines.push("\{style.cyan(title)}\{subtitle}")
      lines.push("")
      lines.push(style.gray("  ✓ up to date"))
      lines.push("")
    }
  }

  // Collect plan-level error diagnostics that weren't tied to a dependency change.
  for diag in plan.diagnostics() {
    if diag.severity is Error && diag.dependency is None {
      let loc = diag.manifest.unwrap_or("manifest")
      err_lines.push(
        style.red("> " + style.underline_red(loc) + " " + diag.code),
      )
      err_lines.push(style.red(diag.message))
    }
  }

  // Show warnings cleanly when `--all` or explicitly relevant.
  let warnings : Array[@taze.Diagnostic] = []
  for diag in plan.diagnostics() {
    if diag.severity is Warning {
      warnings.push(diag)
    }
  }
  for diag in extra_diagnostics {
    if diag.severity is Warning {
      warnings.push(diag)
    }
  }

  let has_updates = packages_with_updates > 0
  if !has_updates && !options.show_all {
    if err_lines.is_empty() {
      emit(style.green("dependencies are already up-to-date"))
    }
  } else {
    for line in lines {
      emit(line)
    }
    if !options.show_all {
      let up_to_date_count = total_packages -
        packages_with_updates -
        packages_with_errors
      if up_to_date_count == 1 {
        emit(style.green("dependencies are already up-to-date in one package"))
        emit("")
      } else if up_to_date_count > 1 {
        emit(
          style.green(
            "dependencies are already up-to-date in \{up_to_date_count} packages",
          ),
        )
        emit("")
      }
    }
  }

  if !warnings.is_empty() && options.show_all {
    for diag in warnings {
      emit(style.yellow("warning[\{diag.code}]: \{diag.message}"))
    }
  }

  if !err_lines.is_empty() {
    emit(style.inverse_red_bold(" ERROR "))
    emit("")
    for line in err_lines {
      emit(line)
    }
    emit("")
  }

  // Footer tips matching upstream `taze`.
  if !options.write && has_updates && !plan.has_errors() {
    emit("")
    if options.mode == Default {
      let cmd_hint = style.cyan("moon-taze major")
      emit("Run \{cmd_hint} to check major updates")
    }
    let files_label = target_files_label(manifests, all_changes)
    let write_flag = style.green("-w")
    emit("Add \{write_flag} to write to \{files_label}")
    emit("")
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
  published_at~ : Map[String, Int64] = Map([]),
) -> Json {
  let object : Map[String, Json] = Map([])
  object["name"] = json_text(value.dependency.name)
  object["source"] = json_text(
    match value.dependency.source {
      Mooncakes => "mooncakes"
      GitHubActions => "github-actions"
      LocalWorkspace => "local_workspace"
      Unsupported => "unsupported"
    },
  )
  object["current"] = json_text(value.dependency.version)
  object["target"] = json_optional(value.target)
  object["targetSha"] = json_optional(value.target_sha)
  object["latestAvailable"] = json_optional(value.latest_available)
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
    Some(Pin) => json_text("pin")
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
fn render_json(
  plan : @taze.CheckPlan,
  mode : @taze.UpdateMode,
  report : @taze.ApplyReport?,
  verification : Array[VerificationResult],
  fail_on_outdated : Bool,
  published_at~ : Map[String, Int64] = Map([]),
  extra_diagnostics~ : Array[@taze.Diagnostic] = [],
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
    let project_changes = changes.filter(change => {
      change.dependency.manifest == path
    })
    let dependencies = project_changes.map(change => {
      json_change(change, published_at~)
    })
    let object : Map[String, Json] = Map([])
    object["manifest"] = json_text(path)
    let first = project_changes[0]
    object["module"] = json_text(first.dependency.module_name)
    object["kind"] = json_text(
      match first.dependency.source {
        GitHubActions => "github-actions"
        _ => "moon-mod"
      },
    )
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
    if item.severity is Error {
      errors += 1
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
  if report is Some(value) {
    diagnostic_values.append(value.diagnostics())
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
    Some(value) => !(value.status() is Succeeded)
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
fn render_cli_error_json(code : String, message : String) -> String {
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
  let diag : Map[String, Json] = Map([])
  diag["severity"] = json_text("error")
  diag["code"] = json_text(code)
  diag["message"] = json_text(message)
  diag["manifest"] = Json::null()
  diag["dependency"] = Json::null()
  diag["line"] = Json::null()
  diag["column"] = Json::null()
  root["diagnostics"] = Json::array([Json::object(diag)])
  let apply : Map[String, Json] = Map([])
  apply["status"] = json_text("not_requested")
  apply["files"] = Json::array([])
  apply["verification"] = Json::array([])
  root["apply"] = Json::object(apply)
  root["exitCode"] = Json::number(2.0)
  Json::object(root).stringify()
}
