///|
/// Progress bar styled after upstream `taze` (`dep ████████░░░░ 3/8 name`).
priv struct ProgressBar {
  enabled : Bool
  mut label : String
  mut total : Int32
  mut current : Int32
  mut stopped : Bool
  style : Style
}

///|
fn progress_bar(
  total : Int32,
  enabled : Bool,
  color~ : Bool = true,
) -> Ref[ProgressBar] {
  Ref({
    enabled,
    label: "dep",
    total: if total < 0 {
      0
    } else {
      total
    },
    current: 0,
    stopped: false,
    style: Style::new(color),
  })
}

///|
fn progress_bar_render(bar : ProgressBar, name : String) -> String {
  let width = 32
  let total = if bar.total > 0 { bar.total } else { 1 }
  let current = if bar.current > bar.total { bar.total } else { bar.current }
  let filled = current * width / total
  let empty = width - filled
  let completed = Array::make(filled, "█").join("")
  let remaining = Array::make(empty, "░").join("")
  let label = bar.style.green(bar.label)
  let suffix = if name.is_empty() { "" } else { " " + bar.style.gray(name) }
  "\r\u001b[2K\{label} \{completed}\{remaining} \{current}/\{bar.total}\{suffix}"
}

///|
async fn write_terminal_raw(text : String) -> Unit noraise {
  @stdio.stdout.write(@utf8.encode(text)) catch {
    _ => ()
  }
}

///|
async fn progress_bar_start(bar : Ref[ProgressBar]) -> Unit noraise {
  if bar.val.enabled {
    write_terminal_raw("\u001b[?25l" + progress_bar_render(bar.val, ""))
  }
}

///|
async fn progress_bar_set_phase(
  bar : Ref[ProgressBar],
  label : String,
  total : Int32,
) -> Unit noraise {
  bar.val.label = label
  bar.val.total = if total < 0 { 0 } else { total }
  bar.val.current = 0
  if bar.val.enabled && !bar.val.stopped {
    write_terminal_raw(progress_bar_render(bar.val, ""))
  }
}

///|
async fn progress_bar_update(
  bar : Ref[ProgressBar],
  name : String,
) -> Unit noraise {
  if bar.val.current < bar.val.total {
    bar.val.current += 1
  }
  if bar.val.enabled {
    write_terminal_raw(progress_bar_render(bar.val, name))
  }
}

///|
async fn progress_bar_stop(bar : Ref[ProgressBar]) -> Unit noraise {
  if !bar.val.stopped {
    if bar.val.enabled {
      write_terminal_raw("\r\u001b[2K\u001b[?25h")
    }
    bar.val.stopped = true
  }
}
