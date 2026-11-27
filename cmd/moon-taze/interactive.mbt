///|
/// 1:1 upstream `taze` interactive TUI built on `unmbt/clack` (`BodyView::CustomLines`
/// + `run_prompt` + `confirm`).
priv struct InteractiveDep {
  id : String
  change : @taze.DependencyChange
  mut checked : Bool
  mut target : String
  mut target_sha : String?
  mut diff : @taze.DiffKind?
}

///|
priv struct VersionChoice {
  label : String
  version : String
  sha : String?
  diff : @taze.DiffKind?
}

///|
priv enum InteractiveViewMode {
  ListView
  VersionPicker(
    dep_id~ : String,
    choices~ : Array[VersionChoice],
    cursor~ : Int32,
  )
}

///|
priv struct InteractiveResult {
  selected_tuples : Array[(String, String, String)]
  display_changes : Array[@taze.DependencyChange]
}

///|
priv enum InteractiveOutcome {
  NoCandidates
  Cancelled
  Confirmed(InteractiveResult)
}

///|
fn interactive_dep_id(manifest : String, name : String) -> String {
  manifest + "\u0000" + name
}

///|
fn compute_dep_diff(
  dep : @taze.Dependency,
  target : String,
  is_pin~ : Bool = false,
) -> @taze.DiffKind? {
  if is_pin {
    return Some(Pin)
  }
  match dep.source {
    GitHubActions => @taze.action_diff_kind(dep.version, target)
    _ => @taze.semver_diff_kind(dep.version, target)
  }
}

///|
fn diff_kind_label(diff : @taze.DiffKind?) -> String {
  match diff {
    Some(Major) => "major"
    Some(Minor) => "minor"
    Some(Patch) => "patch"
    Some(Prerelease) => "prerelease"
    Some(Pin) => "pin"
    None => "version"
  }
}

///|
fn build_version_choices(dep : InteractiveDep) -> Array[VersionChoice] {
  let choices : Array[VersionChoice] = []
  let seen_versions : Map[String, Unit] = Map([])
  let change = dep.change
  let current = change.dependency.version
  fn push_choice(
    label : String,
    version : String,
    sha : String?,
    diff : @taze.DiffKind?,
  ) -> Unit {
    if seen_versions.contains(version) {
      return
    }
    seen_versions[version] = ()
    choices.push({ label, version, sha, diff, })
  }

  match change.dependency.source {
    GitHubActions => {
      if change.diff == Some(Pin) && change.target == Some(current) {
        push_choice("pin", current, change.target_sha, Some(Pin))
      }
      // Range shortcuts (patch, minor, major) preserving tag granularity.
      let range_modes : Array[(String, @taze.UpdateMode)] = [
        ("patch", Patch),
        ("minor", Minor),
        ("major", Major),
      ]
      for pair in range_modes {
        let (label, mode) = pair
        if @taze.select_action_target(current, change.candidates, mode)
          is Some(picked) &&
          picked.tag != current {
          let sha = match change.candidate_shas.get(picked.tag) {
            Some(s) => Some(s)
            None => change.candidate_shas.get(picked.resolved_tag)
          }
          push_choice(
            label,
            picked.tag,
            sha,
            @taze.action_diff_kind(current, picked.tag),
          )
        }
      }
      // Remaining newer concrete tags, newest first.
      if @taze.parse_action_tag(current) is Some(curr_tag) {
        let newer : Array[@taze.ParsedActionTag] = []
        let tag_seen : Map[String, Unit] = Map([])
        for raw in change.candidates {
          if tag_seen.contains(raw) {
            continue
          }
          if @taze.parse_action_tag(raw) is Some(parsed) {
            let is_newer = parsed.major > curr_tag.major ||
              (parsed.major == curr_tag.major && parsed.minor > curr_tag.minor) ||
              (
                parsed.major == curr_tag.major &&
                parsed.minor == curr_tag.minor &&
                parsed.patch > curr_tag.patch
              ) ||
              (
                parsed.major == curr_tag.major &&
                parsed.minor == curr_tag.minor &&
                parsed.patch == curr_tag.patch &&
                curr_tag.prerelease &&
                !parsed.prerelease
              )
            if is_newer {
              tag_seen[raw] = ()
              newer.push(parsed)
            }
          }
        }
        newer.sort_by((a, b) => {
          let maj = b.major.compare(a.major)
          if maj != 0 {
            return maj
          }
          let min = b.minor.compare(a.minor)
          if min != 0 {
            return min
          }
          let pat = b.patch.compare(a.patch)
          if pat != 0 {
            return pat
          }
          if a.prerelease != b.prerelease {
            if a.prerelease {
              1
            } else {
              -1
            }
          } else {
            b.raw.compare(a.raw)
          }
        })
        for tag in newer {
          let diff = @taze.action_diff_kind(current, tag.raw)
          push_choice(
            diff_kind_label(diff),
            tag.raw,
            change.candidate_shas.get(tag.raw),
            diff,
          )
        }
      }
    }
    _ => {
      let parsed_current = @taze.parse_version(current) catch {
        _ => return choices
      }
      let parsed_newer : Array[@taze.SemVer] = []
      let ver_seen : Map[String, Unit] = Map([])
      for raw in change.candidates {
        if ver_seen.contains(raw) {
          continue
        }
        let parsed = @taze.parse_version(raw) catch { _ => continue }
        if @taze.SemVer::compare(parsed, parsed_current) > 0 {
          ver_seen[raw] = ()
          parsed_newer.push(parsed)
        }
      }
      // Range shortcuts (patch, minor, major/latest) matching upstream `taze`.
      let range_modes : Array[(String, @taze.UpdateMode)] = [
        ("patch", Patch),
        ("minor", Minor),
        ("latest", Major),
      ]
      for pair in range_modes {
        let (label, mode) = pair
        if @taze.select_version(parsed_current, parsed_newer, mode~)
          is Some(picked) {
          let ver = picked.to_string()
          push_choice(label, ver, None, @taze.semver_diff_kind(current, ver))
        }
      }
      // All remaining newer versions sorted newest-first so any exact version can be picked.
      parsed_newer.sort_by((a, b) => @taze.SemVer::compare(b, a))
      for v in parsed_newer {
        let ver = v.to_string()
        let diff = @taze.semver_diff_kind(current, ver)
        push_choice(diff_kind_label(diff), ver, None, diff)
      }
    }
  }
  choices
}

///|
fn interactive_dep_to_change(dep : InteractiveDep) -> @taze.DependencyChange {
  dep.change.with_target(dep.target, target_sha=dep.target_sha, diff=dep.diff)
}

///|
priv struct AgeLoadProgress {
  gen : Int32
  dep_id : String
  total : Int32
  mut completed : Int32
  mut current : String
  mut spinner_idx : Int32
}

///|
priv struct TazeInteractiveModel {
  manifests : Array[@taze.Manifest]
  all_plan_changes : Array[@taze.DependencyChange]
  deps : Array[InteractiveDep]
  options : CliOptions
  detail_times : Map[String, Int64]
  detail_missing : Map[String, Bool]
  style : Style
  now : Int64
  mut cursor : Int32
  mut mode : InteractiveViewMode
  mut phase : @clack_core.PromptPhase
  mut fetch_gen : Int32
  mut age_progress : AgeLoadProgress?
  mut pending_age_fetch : (Int32, Array[AgeFetchTask])?
}

///|
fn build_interactive_deps(
  manifests : Array[@taze.Manifest],
  plan_changes : Array[@taze.DependencyChange],
) -> Array[InteractiveDep] {
  let deps : Array[InteractiveDep] = []
  let seen : Map[String, Unit] = Map([])
  for manifest in manifests {
    for change in plan_changes {
      if change.dependency.manifest != manifest.path {
        continue
      }
      let id = interactive_dep_id(
        change.dependency.manifest,
        change.dependency.name,
      )
      if seen.contains(id) {
        continue
      }
      match (change.status, change.target, change.latest_available) {
        (UpdateAvailable, Some(target), _) => {
          seen[id] = ()
          deps.push({
            id,
            change,
            checked: true,
            target,
            target_sha: change.target_sha,
            diff: change.diff,
          })
        }
        (NoCandidate, _, Some(latest)) => {
          // Match upstream `taze`: show available higher versions (e.g. major in default mode)
          // unchecked by default so the user can opt-in or pick another version interactively.
          seen[id] = ()
          deps.push({
            id,
            change,
            checked: false,
            target: latest,
            target_sha: change.candidate_shas.get(latest),
            diff: compute_dep_diff(change.dependency, latest),
          })
        }
        _ => ()
      }
    }
  }
  deps
}

///|
fn TazeInteractiveModel::ordered_deps(
  self : TazeInteractiveModel,
) -> Array[InteractiveDep] {
  let ordered : Array[InteractiveDep] = []
  for manifest in self.manifests {
    let pkg_deps = self.deps.filter(d => {
      d.change.dependency.manifest == manifest.path
    })
    if pkg_deps.is_empty() {
      continue
    }
    let synthetic = pkg_deps.map(interactive_dep_to_change)
    let sorted = sort_changes(
      synthetic,
      self.options.sort_mode,
      published_at=self.detail_times,
    )
    let sorted_deps : Array[InteractiveDep] = []
    for ch in sorted {
      let id = interactive_dep_id(ch.dependency.manifest, ch.dependency.name)
      for d in pkg_deps {
        if d.id == id {
          sorted_deps.push(d)
          break
        }
      }
    }
    if self.options.group_output {
      let sections : Array[String] = ["import", "workspace", "github-actions"]
      for section in sections {
        for d in sorted_deps {
          if section_label(d.change.dependency.source) == section {
            ordered.push(d)
          }
        }
      }
    } else {
      ordered.append(sorted_deps)
    }
  }
  ordered
}

///|
fn TazeInteractiveModel::find_dep_by_id(
  self : TazeInteractiveModel,
  id : String,
) -> InteractiveDep? {
  for d in self.deps {
    if d.id == id {
      return Some(d)
    }
  }
  None
}

///|
fn TazeInteractiveModel::anchor_cursor_to_id(
  self : TazeInteractiveModel,
  id : String,
) -> Unit {
  let ordered = self.ordered_deps()
  for i, d in ordered {
    if d.id == id {
      self.cursor = i
      return
    }
  }
  if self.cursor >= ordered.length() && ordered.length() > 0 {
    self.cursor = ordered.length() - 1
  }
}

///|
fn TazeInteractiveModel::build_result(
  self : TazeInteractiveModel,
) -> InteractiveResult {
  let selected_tuples : Array[(String, String, String)] = []
  let chosen_by_id : Map[String, InteractiveDep] = Map([])
  for d in self.deps {
    if d.checked {
      selected_tuples.push(
        (d.change.dependency.manifest, d.change.dependency.name, d.target),
      )
      chosen_by_id[d.id] = d
    }
  }
  let display_changes : Array[@taze.DependencyChange] = []
  for change in self.all_plan_changes {
    let id = interactive_dep_id(
      change.dependency.manifest,
      change.dependency.name,
    )
    match chosen_by_id.get(id) {
      Some(picked) =>
        display_changes.push(
          change.with_target(
            picked.target,
            target_sha=picked.target_sha,
            diff=picked.diff,
          ),
        )
      None =>
        if change.status == UpdateAvailable {
          display_changes.push(change.as_skipped("unselected"))
        } else {
          display_changes.push(change)
        }
    }
  }
  { selected_tuples, display_changes, }
}

///|
fn TazeInteractiveModel::take_pending_age_fetch(
  self : TazeInteractiveModel,
) -> (Int32, Array[AgeFetchTask])? {
  let pending = self.pending_age_fetch
  self.pending_age_fetch = None
  pending
}

///|
fn collect_uncached_age_tasks(
  dep : InteractiveDep,
  choices : Array[VersionChoice],
  detail_times : Map[String, Int64],
  detail_missing : Map[String, Bool],
) -> Array[AgeFetchTask] {
  let tasks : Array[AgeFetchTask] = []
  let seen : Map[String, Unit] = Map([])
  let dep_name = dep.change.dependency.name
  match dep.change.dependency.source {
    Mooncakes => {
      let versions : Array[String] = [dep.change.dependency.version]
      for c in choices {
        if !versions.contains(c.version) {
          versions.push(c.version)
        }
      }
      for version in versions {
        let key = dep_name + "@" + version
        if !detail_times.contains(key) &&
          !detail_missing.contains(key) &&
          !seen.contains(key) {
          seen[key] = ()
          tasks.push(MooncakesAge(dep_name, version))
        }
      }
    }
    GitHubActions =>
      for c in choices {
        if c.sha is Some(sha) {
          let key = dep_name + "@" + c.version
          if !detail_times.contains(key) &&
            !detail_missing.contains(key) &&
            !seen.contains(key) {
            seen[key] = ()
            tasks.push(GitHubAge(dep_name, c.version, sha))
          }
        }
      }
    _ => ()
  }
  tasks
}

///|
fn render_age_progress_footer(
  style : Style,
  progress : AgeLoadProgress,
) -> Array[String] {
  let frames : Array[String] = ["◒", "◐", "◓", "◑"]
  let spin = frames[progress.spinner_idx % frames.length()]
  let width = 20
  let total = if progress.total > 0 { progress.total } else { 1 }
  let done = if progress.completed > progress.total {
    progress.total
  } else {
    progress.completed
  }
  let filled = done * width / total
  let empty = width - filled
  let bar = Array::make(filled, "█").join("") +
    Array::make(empty, "░").join("")
  let suffix = if progress.current.is_empty() {
    ""
  } else {
    " " + style.gray(progress.current)
  }
  let block = style.dim_gray("┃")
  [
    "",
    "\{block} \{style.cyan(spin)} \{style.green("age")} \{bar} \{done}/\{progress.total}\{suffix}",
  ]
}

///|
fn TazeInteractiveModel::render_interactive_row(
  self : TazeInteractiveModel,
  dep : InteractiveDep,
  is_cursor : Bool,
) -> Array[String] {
  let style = self.style
  let pointer = if is_cursor { style.cyan("❯ ") } else { "  " }
  let check = if dep.checked { style.green("◉") } else { style.gray("◌") }
  let name_cell = "\{pointer}\{check} " +
    (if dep.checked {
      dep.change.dependency.name
    } else {
      style.gray(dep.change.dependency.name)
    })
  let type_cell = if self.options.group_output {
    ""
  } else {
    style.gray(short_source_label(dep.change.dependency.source))
  }
  let current_ts = self.detail_times.get(
    dep.change.dependency.name + "@" + dep.change.dependency.version,
  )
  let current_age_cell = if self.options.timediff {
    format_colored_age(style, current_ts, now=self.now)
  } else {
    ""
  }
  let current_ver_cell = style.gray(dep.change.dependency.version)
  let arrow_cell = if dep.checked { style.dim_gray("→") } else { "" }
  let target_cell = if dep.checked {
    if dep.diff == Some(Pin) {
      let short_sha = match dep.target_sha {
        Some(sha) if sha.length() >= 7 => sha[:7].to_owned()
        Some(sha) => sha
        None => dep.target
      }
      style.blue(short_sha) + " " + style.dim("# \{dep.target}")
    } else {
      colorize_version_diff(
        style,
        dep.change.dependency.version,
        dep.target,
        dep.diff,
      )
    }
  } else {
    style.gray_strikethrough(dep.target)
  }
  let target_age_cell = if dep.checked && self.options.timediff {
    format_colored_age(
      style,
      self.detail_times.get(dep.change.dependency.name + "@" + dep.target),
      now=self.now,
    )
  } else {
    ""
  }
  let available_cell = match dep.change.latest_available {
    Some(latest) if latest != dep.target =>
      style.dim_magenta("(\{latest} available)")
    _ => ""
  }
  [
    name_cell, type_cell, current_age_cell, current_ver_cell, arrow_cell, target_cell,
    target_age_cell, available_cell,
  ]
}

///|
fn TazeInteractiveModel::render_list_view(
  self : TazeInteractiveModel,
) -> @clack_core.FrameSpec {
  let style = self.style
  let block = style.dim_gray("┃")
  let y = fn(s : String) -> String { style.bold_green(s) }
  let header : Array[String] = [
    "\{block} \{y("↑↓")}\{style.gray(" to select, ")}\{y("space")}\{style.gray(" to toggle, ")}\{y("→")}\{style.gray(" to change version")}",
    "\{block} \{y("enter")}\{style.gray(" to confirm, ")}\{y("esc")}\{style.gray(" to cancel, ")}\{y("a")}\{style.gray(" to select/unselect all")}",
    "",
  ]
  let ordered = self.ordered_deps()
  let focused_id = if self.cursor >= 0 && self.cursor < ordered.length() {
    Some(ordered[self.cursor].id)
  } else {
    None
  }
  let body_lines : Array[String] = []
  let mut cursor_line : Int32 = 0

  for manifest in self.manifests {
    let pkg_deps = ordered.filter(d => {
      d.change.dependency.manifest == manifest.path
    })
    if pkg_deps.is_empty() {
      continue
    }
    let checked_changes = pkg_deps
      .filter(d => d.checked)
      .map(interactive_dep_to_change)
    let title = manifest_display_title(manifest, self.options.cwd)
    let diff_summary = render_diff_summary(style, checked_changes)
    let dash = style.dim("-")
    body_lines.push("\{style.cyan(title)} \{dash} \{diff_summary}")
    body_lines.push("")

    let rows = pkg_deps.map(d => {
      self.render_interactive_row(d, focused_id == Some(d.id))
    })
    let table = format_table(rows, "LLRRRRRLL")
    if self.options.group_output {
      let sections : Array[String] = ["import", "workspace", "github-actions"]
      for section in sections {
        let mut emitted_header = false
        for i, d in pkg_deps {
          if section_label(d.change.dependency.source) == section {
            if !emitted_header {
              if !body_lines.is_empty() &&
                body_lines[body_lines.length() - 1] != "" {
                body_lines.push("")
              }
              body_lines.push("  " + style.blue(section))
              emitted_header = true
            }
            if focused_id == Some(d.id) {
              cursor_line = body_lines.length()
            }
            body_lines.push("  " + table[i])
          }
        }
      }
    } else {
      for i, d in pkg_deps {
        if focused_id == Some(d.id) {
          cursor_line = body_lines.length()
        }
        body_lines.push(table[i])
      }
    }
    body_lines.push("")
  }

  {
    phase: self.phase,
    message: "",
    body: CustomLines(
      header~,
      lines=body_lines,
      cursor_line=Some(cursor_line),
      footer=[],
      clear_on_submit=true,
    ),
    submitted_summary: None,
    with_guide: false,
    max_rows: None,
  }
}

///|
fn TazeInteractiveModel::render_version_picker(
  self : TazeInteractiveModel,
  dep_id : String,
  choices : Array[VersionChoice],
  v_cursor : Int32,
) -> @clack_core.FrameSpec {
  let style = self.style
  let block = style.dim_gray("┃")
  let y = fn(s : String) -> String { style.bold_green(s) }
  guard self.find_dep_by_id(dep_id) is Some(dep) else {
    return self.render_list_view()
  }
  let dep_name = dep.change.dependency.name
  let current = dep.change.dependency.version
  let header : Array[String] = [
    "\{block} \{style.gray("Select a version for ")}\{style.bold_green(dep_name)}\{style.gray(" (current \{current})")}",
    "\{block} \{y("↑↓")}\{style.gray(" to select, ")}\{y("enter/←")}\{style.gray(" to confirm, ")}\{y("esc")}\{style.gray(" to back")}",
    "",
  ]
  let current_ts = self.detail_times.get(dep_name + "@" + current)
  let current_age = if self.options.timediff {
    format_colored_age(style, current_ts, now=self.now)
  } else {
    ""
  }
  let rows : Array[Array[String]] = []
  for idx, choice in choices {
    let is_cur = idx == v_cursor
    let label_cell = (if is_cur { style.cyan("❯ ") } else { "  " }) +
      (if is_cur { choice.label } else { style.gray(choice.label) })
    let target_cell = if choice.diff == Some(Pin) {
      let short_sha = match choice.sha {
        Some(sha) if sha.length() >= 7 => sha[:7].to_owned()
        Some(sha) => sha
        None => choice.version
      }
      style.blue(short_sha) + " " + style.dim("# \{choice.version}")
    } else {
      colorize_version_diff(style, current, choice.version, choice.diff)
    }
    let target_age = if self.options.timediff {
      format_colored_age(
        style,
        self.detail_times.get(dep_name + "@" + choice.version),
        now=self.now,
      )
    } else {
      ""
    }
    rows.push([
      label_cell,
      current_age,
      style.gray(current),
      style.dim_gray("→"),
      target_cell,
      target_age,
    ])
  }
  let lines = format_table(rows, "LRRRRR")
  let footer : Array[String] = match self.age_progress {
    Some(prog) if prog.dep_id == dep_id &&
      prog.gen == self.fetch_gen &&
      prog.completed < prog.total => render_age_progress_footer(style, prog)
    _ => []
  }
  {
    phase: self.phase,
    message: "",
    body: CustomLines(
      header~,
      lines~,
      cursor_line=Some(v_cursor),
      footer~,
      clear_on_submit=true,
    ),
    submitted_summary: None,
    with_guide: false,
    max_rows: None,
  }
}

///|
fn TazeInteractiveModel::view(
  self : TazeInteractiveModel,
) -> @clack_core.FrameSpec {
  match self.mode {
    ListView => self.render_list_view()
    VersionPicker(dep_id~, choices~, cursor~) =>
      self.render_version_picker(dep_id, choices, cursor)
  }
}

///|
fn TazeInteractiveModel::on_key(
  self : TazeInteractiveModel,
  ev : @clack_core.KeyEvent,
) -> @clack_core.PromptOutcome[InteractiveResult]? {
  if ev.ctrl && (ev.code == Char('c') || ev.code == Char('C')) {
    self.phase = Cancelled
    return Some(Cancelled)
  }
  if self.phase == Initial {
    self.phase = Active
  }
  match self.mode {
    ListView => {
      let ordered = self.ordered_deps()
      let total = ordered.length()
      if total == 0 {
        self.phase = Cancelled
        return Some(Cancelled)
      }
      match ev.code {
        Escape | Char('q') | Char('Q') if !ev.ctrl && !ev.alt => {
          self.phase = Cancelled
          return Some(Cancelled)
        }
        Enter => {
          self.phase = Submitted
          return Some(Submitted(self.build_result()))
        }
        Up => self.cursor = (self.cursor - 1 + total) % total
        Down => self.cursor = (self.cursor + 1) % total
        Char('k') if !ev.ctrl && !ev.alt =>
          self.cursor = (self.cursor - 1 + total) % total
        Char('j') if !ev.ctrl && !ev.alt =>
          self.cursor = (self.cursor + 1) % total
        Home => self.cursor = 0
        End => self.cursor = total - 1
        PageUp => {
          let next = self.cursor - 10
          self.cursor = if next < 0 { 0 } else { next }
        }
        PageDown => {
          let next = self.cursor + 10
          self.cursor = if next >= total { total - 1 } else { next }
        }
        Space => {
          let dep = ordered[self.cursor]
          dep.checked = !dep.checked
        }
        Char('a') | Char('A') if !ev.ctrl && !ev.alt => {
          let all_checked = ordered.all(d => d.checked)
          for d in ordered {
            d.checked = !all_checked
          }
        }
        Char('i') | Char('I') if !ev.ctrl && !ev.alt =>
          for d in ordered {
            d.checked = !d.checked
          }
        Right | Char('l') if !ev.ctrl && !ev.alt => {
          let dep = ordered[self.cursor]
          let choices = build_version_choices(dep)
          if !choices.is_empty() {
            let mut initial_cursor : Int32 = 0
            for idx, c in choices {
              if c.version == dep.target {
                initial_cursor = idx
                break
              }
            }
            self.mode = VersionPicker(
              dep_id=dep.id,
              choices~,
              cursor=initial_cursor,
            )
            self.fetch_gen += 1
            if self.options.timediff {
              let tasks = collect_uncached_age_tasks(
                dep,
                choices,
                self.detail_times,
                self.detail_missing,
              )
              if !tasks.is_empty() {
                self.age_progress = Some({
                  gen: self.fetch_gen,
                  dep_id: dep.id,
                  total: tasks.length(),
                  completed: 0,
                  current: "",
                  spinner_idx: 0,
                })
                self.pending_age_fetch = Some((self.fetch_gen, tasks))
              } else {
                self.age_progress = None
                self.pending_age_fetch = None
              }
            }
          }
        }
        _ => ()
      }
      None
    }
    VersionPicker(dep_id~, choices~, cursor~) => {
      let total = choices.length()
      if total == 0 {
        self.fetch_gen += 1
        self.age_progress = None
        self.pending_age_fetch = None
        self.mode = ListView
        self.anchor_cursor_to_id(dep_id)
        return None
      }
      match ev.code {
        Escape | Char('q') | Char('Q') if !ev.ctrl && !ev.alt => {
          self.fetch_gen += 1
          self.age_progress = None
          self.pending_age_fetch = None
          self.mode = ListView
          self.anchor_cursor_to_id(dep_id)
        }
        Up =>
          self.mode = VersionPicker(
            dep_id~,
            choices~,
            cursor=(cursor - 1 + total) % total,
          )
        Down =>
          self.mode = VersionPicker(
            dep_id~,
            choices~,
            cursor=(cursor + 1) % total,
          )
        Char('k') if !ev.ctrl && !ev.alt =>
          self.mode = VersionPicker(
            dep_id~,
            choices~,
            cursor=(cursor - 1 + total) % total,
          )
        Char('j') if !ev.ctrl && !ev.alt =>
          self.mode = VersionPicker(
            dep_id~,
            choices~,
            cursor=(cursor + 1) % total,
          )
        Home => self.mode = VersionPicker(dep_id~, choices~, cursor=0)
        End => self.mode = VersionPicker(dep_id~, choices~, cursor=total - 1)
        Enter | Left | Right => {
          let picked = choices[cursor]
          if self.find_dep_by_id(dep_id) is Some(dep) {
            dep.target = picked.version
            dep.target_sha = picked.sha
            dep.diff = picked.diff
            dep.checked = true
          }
          self.fetch_gen += 1
          self.age_progress = None
          self.pending_age_fetch = None
          self.mode = ListView
          self.anchor_cursor_to_id(dep_id)
        }
        Char('h') | Char('l') if !ev.ctrl && !ev.alt => {
          let picked = choices[cursor]
          if self.find_dep_by_id(dep_id) is Some(dep) {
            dep.target = picked.version
            dep.target_sha = picked.sha
            dep.diff = picked.diff
            dep.checked = true
          }
          self.fetch_gen += 1
          self.age_progress = None
          self.pending_age_fetch = None
          self.mode = ListView
          self.anchor_cursor_to_id(dep_id)
        }
        _ => ()
      }
      None
    }
  }
}

///|
fn TazeInteractiveModel::as_adapter(
  self : TazeInteractiveModel,
) -> @clack_core.PromptAdapter[InteractiveResult] {
  @clack_core.PromptAdapter(on_key=fn(ev, _) { self.on_key(ev) }, view=fn() {
    self.view()
  })
}

///|
async fn fetch_candidate_ages_live(
  model : TazeInteractiveModel,
  my_gen : Int32,
  tasks : Array[AgeFetchTask],
  detail_times : Map[String, Int64],
  detail_missing : Map[String, Bool],
  cache : Map[String, @taze.ModuleMetadata],
  cache_times : Map[String, UInt64],
  cache_path : String?,
  fetch_version : async (String, String) -> @taze.VersionMetadata? raise @taze.RegistryError,
  fetch_gha_commit_date : async (String, String) -> Int64? raise @taze.RegistryError,
  retry_count : Int32,
  retry_delay_ms : Int32,
  redraw : async () -> Unit noraise,
) -> Unit noraise {
  if tasks.is_empty() {
    return
  }
  let age_retries = if retry_count > 1 { 1 } else { retry_count }
  let sem = @async.Semaphore(8)
  @async.with_task_group(group => {
    group.spawn_bg(no_wait=true, allow_failure=true, async fn() {
      for ;; {
        @async.sleep(80)
        if model.fetch_gen != my_gen {
          break
        }
        match model.age_progress {
          Some(prog) if prog.gen == my_gen && prog.completed < prog.total => {
            prog.spinner_idx = (prog.spinner_idx + 1) % 4
            redraw()
          }
          _ => break
        }
      }
    })
    for task in tasks {
      group.spawn_bg(async fn() {
        sem.acquire()
        defer sem.release()
        if model.fetch_gen != my_gen {
          return
        }
        match task {
          MooncakesAge(name, version) => {
            let key = name + "@" + version
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
            if model.age_progress is Some(prog) && prog.gen == my_gen {
              prog.completed += 1
              prog.current = version
              redraw()
            }
          }
          GitHubAge(repo, target, sha) => {
            let key = repo + "@" + target
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
            if model.age_progress is Some(prog) && prog.gen == my_gen {
              prog.completed += 1
              prog.current = target
              redraw()
            }
          }
        }
      })
    }
  }) catch {
    _ => ()
  }
  if model.age_progress is Some(prog) && prog.gen == my_gen {
    model.age_progress = None
    redraw()
  }
  if apply_detail_times_to_cache(cache, detail_times) {
    save_persistent_cache(cache_path, cache, cache_times) catch {
      _ => ()
    }
  }
}

///|
async fn run_interactive_picker(
  manifests : Array[@taze.Manifest],
  plan : @taze.CheckPlan,
  options : CliOptions,
  detail_times : Map[String, Int64],
  detail_missing : Map[String, Bool],
  cache : Map[String, @taze.ModuleMetadata],
  cache_times : Map[String, UInt64],
  cache_path : String?,
  fetch_version : async (String, String) -> @taze.VersionMetadata? raise @taze.RegistryError,
  fetch_gha_commit_date : async (String, String) -> Int64? raise @taze.RegistryError,
  retry_delay_ms : Int32,
  style : Style,
  now : Int64,
  session : @clack_prompts.Session,
) -> InteractiveOutcome raise @clack_term.TermError {
  let all_plan_changes = plan.changes()
  let deps = build_interactive_deps(manifests, all_plan_changes)
  if deps.is_empty() {
    return NoCandidates
  }
  let model : TazeInteractiveModel = {
    manifests,
    all_plan_changes,
    deps,
    options,
    detail_times,
    detail_missing,
    style,
    now,
    cursor: 0,
    mode: ListView,
    phase: Initial,
    fetch_gen: 0,
    age_progress: None,
    pending_age_fetch: None,
  }
  let outcome = @clack_prompts.run_prompt(
    model.as_adapter(),
    on_background=async fn(redraw) noraise {
      if model.take_pending_age_fetch() is Some((my_gen, tasks)) {
        fetch_candidate_ages_live(
          model,
          my_gen,
          tasks,
          detail_times,
          detail_missing,
          cache,
          cache_times,
          cache_path,
          fetch_version,
          fetch_gha_commit_date,
          options.retry_count,
          retry_delay_ms,
          redraw,
        )
      }
    },
    session~,
  )
  match outcome {
    Submitted(res) => Confirmed(res)
    Cancelled | StepBack => Cancelled
  }
}
