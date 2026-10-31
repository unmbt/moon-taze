///|
/// A small, dependency-free progress bar for the terminal path. It writes
/// directly to the terminal so normal CLI output can keep using the
/// caller-provided line emitter.
priv struct ProgressBar {
  enabled : Bool
  total : Int
  mut current : Int
  mut stopped : Bool
}

///|
fn progress_bar(total : Int, enabled : Bool) -> Ref[ProgressBar] {
  Ref({
    enabled,
    total: if total < 0 {
      0
    } else {
      total
    },
    current: 0,
    stopped: false,
  })
}

///|
fn progress_bar_render(bar : ProgressBar, name : String) -> String {
  let width = 28
  let total = if bar.total > 0 { bar.total } else { 1 }
  let current = if bar.current > bar.total { bar.total } else { bar.current }
  let filled = current * width / total
  let empty = width - filled
  let completed = Array::make(filled, "━").join("")
  let remaining = Array::make(empty, "─").join("")
  "\r\u001b[2KResolving [\{completed}\{remaining}] \{current}/\{bar.total} \{name}"
}

///|
fn progress_bar_start(bar : Ref[ProgressBar]) -> Unit {
  if bar.val.enabled {
    @tui.print_raw("\u001b[?25l" + progress_bar_render(bar.val, ""))
  }
}

///|
fn progress_bar_update(bar : Ref[ProgressBar], name : String) -> Unit {
  if bar.val.current < bar.val.total {
    bar.val.current += 1
  }
  if bar.val.enabled {
    @tui.print_raw(progress_bar_render(bar.val, name))
  }
}

///|
fn progress_bar_stop(bar : Ref[ProgressBar]) -> Unit {
  if !bar.val.stopped {
    if bar.val.enabled {
      @tui.print_raw("\r\u001b[2K\u001b[?25h\n")
    }
    bar.val.stopped = true
  }
}

///|
test "progress count never exceeds its total" {
  let bar = progress_bar(2, false)
  progress_bar_update(bar, "demo/a")
  progress_bar_update(bar, "demo/b")
  progress_bar_update(bar, "demo/c")
  assert_eq(bar.val.current, 2)
  assert_true(progress_bar_render(bar.val, "demo/c").contains("2/2"))
  progress_bar_stop(bar)
  assert_true(bar.val.stopped)
}
