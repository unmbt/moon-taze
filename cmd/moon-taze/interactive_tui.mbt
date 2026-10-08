///|
priv enum TuiPage {
  DependencyList
  VersionList(Int)
}

///|
priv struct TuiState {
  changes : Array[@taze.DependencyChange]
  targets : Array[String]
  checked : Array[Bool]
  mut selected : Int
  mut page : TuiPage
  mut version_index : Int
  scroll : Int
  mut version_scroll : Int
  mut selection : Array[(String, String, String)]?
  mut cancelled : Bool
}

///|
fn tui_scroll_to_selected(
  selected : Int,
  scroll : Int,
  length : Int,
  visible : Int,
) -> Int {
  if length == 0 || visible <= 0 {
    return 0
  }
  let max_scroll = if length > visible { length - visible } else { 0 }
  let mut result = scroll
  if selected < result {
    result = selected
  } else if selected >= result + visible {
    result = selected - visible + 1
  }
  if result < 0 {
    0
  } else if result > max_scroll {
    max_scroll
  } else {
    result
  }
}

///|
fn tui_list_lines(
  state : TuiState,
  published_at : Map[String, Int64],
  rows : Int,
) -> @tui.TuiNode {
  let visible = if rows > 4 { rows - 4 } else { 1 }
  let start = tui_scroll_to_selected(
    state.selected,
    state.scroll,
    state.changes.length(),
    visible,
  )
  let lines : Array[@tui.TuiNode] = [
    @tui.text(
      "moon-taze  ↑↓/jk move  space toggle  →/l versions  enter apply  esc/q cancel",
      fg="cyan",
      bold=true,
    ),
    @tui.text(
      "Selected updates are applied together; terminal size is re-read on every key.",
      fg="white",
    ),
  ]
  let end = if start + visible < state.changes.length() {
    start + visible
  } else {
    state.changes.length()
  }
  for index in start..<end {
    let change = state.changes[index]
    let target = state.targets[index]
    let marker = if state.checked[index] { "[x]" } else { "[ ]" }
    let pointer = if index == state.selected { ">" } else { " " }
    let current_age = format_release_age(
      published_at.get(change.dependency.name + "@" + change.dependency.version),
    )
    let target_age = format_release_age(
      published_at.get(change.dependency.name + "@" + target),
    )
    let text = "\{pointer} \{marker} \{change.dependency.name}  \{current_age} \{change.dependency.version} → \{target} \{target_age}"
    lines.push(
      @tui.text(
        text,
        fg=if index == state.selected { "yellow" } else { "white" },
        bold=index == state.selected,
      ),
    )
  }
  lines.push(
    @tui.text(
      "↑/↓ keeps the focused row visible; \{state.checked.filter(value => value).length()} selected",
      fg="green",
    ),
  )
  @tui.column(lines)
}

///|
fn tui_version_lines(
  state : TuiState,
  published_at : Map[String, Int64],
  rows : Int,
  change_index : Int,
) -> @tui.TuiNode {
  let change = state.changes[change_index]
  let versions : Array[String] = []
  let target = state.targets[change_index]
  if target != "" {
    versions.push(target)
  }
  for version in change.candidates {
    if !versions.contains(version) {
      versions.push(version)
    }
  }
  let visible = if rows > 4 { rows - 4 } else { 1 }
  let start = tui_scroll_to_selected(
    state.version_index,
    state.version_scroll,
    versions.length(),
    visible,
  )
  let lines : Array[@tui.TuiNode] = [
    @tui.text(
      "Select a version for \{change.dependency.name}",
      fg="cyan",
      bold=true,
    ),
    @tui.text(
      "current \{change.dependency.version}  ↑↓/jk move  enter confirm  esc/← cancel",
      fg="white",
    ),
  ]
  let end = if start + visible < versions.length() {
    start + visible
  } else {
    versions.length()
  }
  for index in start..<end {
    let version = versions[index]
    let age = format_release_age(
      published_at.get(change.dependency.name + "@" + version),
    )
    let pointer = if index == state.version_index { ">" } else { " " }
    lines.push(
      @tui.text(
        "\{pointer} \{change.dependency.version} → \{version} \{age}",
        fg=if index == state.version_index { "yellow" } else { "white" },
        bold=index == state.version_index,
      ),
    )
  }
  @tui.column(lines)
}

///|
fn tui_version_values(state : TuiState, index : Int) -> Array[String] {
  let values : Array[String] = []
  let target = state.targets[index]
  if target != "" {
    values.push(target)
  }
  for version in state.changes[index].candidates {
    if !values.contains(version) {
      values.push(version)
    }
  }
  values
}

///|
fn tui_handle_event(state : TuiState, event : @tui.InputEvent) -> Bool {
  if event.is_escape() ||
    event.is_ctrl_c() ||
    event.is_char('q') ||
    event.is_char('Q') {
    state.cancelled = true
    return false
  }
  match state.page {
    DependencyList =>
      if event.is_char(' ') {
        state.checked[state.selected] = !state.checked[state.selected]
      } else if event.is_char('a') || event.is_char('A') {
        let all = state.checked.all(value => value)
        for i in 0..<state.checked.length() {
          state.checked[i] = !all
        }
      } else if (event.is_char('j') || event.is_char('J')) ||
        event.is_arrow() is Some(@tui.SpecialKey::Down) {
        state.selected = (state.selected + 1) % state.changes.length()
      } else if (event.is_char('k') || event.is_char('K')) ||
        event.is_arrow() is Some(@tui.SpecialKey::Up) {
        state.selected = (state.selected - 1 + state.changes.length()) %
          state.changes.length()
      } else if (event.is_char('l') || event.is_char('L')) ||
        event.is_arrow() is Some(@tui.SpecialKey::Right) {
        let values = tui_version_values(state, state.selected)
        if !values.is_empty() {
          state.version_index = 0
          state.version_scroll = 0
          state.page = VersionList(state.selected)
        }
      } else if event.is_enter() {
        let items : Array[(String, String, String)] = []
        for i, change in state.changes {
          if state.checked[i] {
            items.push(
              (
                change.dependency.manifest,
                change.dependency.name,
                state.targets[i],
              ),
            )
          }
        }
        if !items.is_empty() {
          state.selection = Some(items)
        }
        return false
      }
    VersionList(change_index) => {
      let values = tui_version_values(state, change_index)
      if values.is_empty() {
        state.page = DependencyList
      } else if (event.is_char('j') || event.is_char('J')) ||
        event.is_arrow() is Some(@tui.SpecialKey::Down) {
        state.version_index = (state.version_index + 1) % values.length()
      } else if (event.is_char('k') || event.is_char('K')) ||
        event.is_arrow() is Some(@tui.SpecialKey::Up) {
        state.version_index = (state.version_index - 1 + values.length()) %
          values.length()
      } else if event.is_arrow() is Some(@tui.SpecialKey::Left) {
        state.page = DependencyList
      } else if event.is_enter() {
        state.targets[change_index] = values[state.version_index]
        state.checked[change_index] = true
        state.page = DependencyList
      }
    }
  }
  true
}

///|
fn interactive_selection_tui(
  plan : @taze.CheckPlan,
  emit~ : (String) -> Unit,
  published_at : Map[String, Int64],
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
  let state = TuiState::{
    changes,
    targets: changes.map(change => {
      change.target.unwrap_or(change.dependency.version)
    }),
    checked: Array::make(changes.length(), true),
    selected: 0,
    page: DependencyList,
    version_index: 0,
    scroll: 0,
    version_scroll: 0,
    selection: None,
    cancelled: false,
  }
  let (app, cleanup) = @tui.init_vnode_terminal(
    @tui.get_terminal_size().0,
    @tui.get_terminal_size().1,
    @tui.print_raw,
    mouse=false,
    raw_mode=true,
  )
  defer cleanup()
  fn render() {
    let (cols, rows) = @tui.get_terminal_size()
    let _ = cols
    app.resize(cols, rows)
    let node = match state.page {
      DependencyList => tui_list_lines(state, published_at, rows)
      VersionList(index) => tui_version_lines(state, published_at, rows, index)
    }
    @tui.print_raw(app.render_frame(node))
  }
  render()
  @tui.start_keypress_listener(fn(raw) {
    let event = @tui.parse_input(raw)
    if tui_handle_event(state, event) {
      render()
    } else {
      @tui.stop_keypress_listener()
    }
  })
  if state.cancelled || state.selection is None {
    return None
  }
  Some(plan.selection(state.selection.unwrap()))
}
