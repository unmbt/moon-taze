///|
/// Lightweight zero-dependency ANSI SGR styling & table alignment engine
/// modeled 1:1 after upstream `taze` (`ansis` + `formatTable` + `colorizeVersionDiff`).
priv struct Style {
  enabled : Bool
}

///|
fn Style::new(enabled : Bool) -> Style {
  { enabled, }
}

///|
fn should_use_color(stdout_tty : Bool) -> Bool {
  if @env.get_env_var("NO_COLOR") is Some(v) && !v.is_empty() {
    return false
  }
  if @env.get_env_var("FORCE_COLOR") is Some(v) && !v.is_empty() && v != "0" {
    return true
  }
  if @env.get_env_var("TERM") == Some("dumb") {
    return false
  }
  stdout_tty
}

///|
fn Style::wrap(self : Style, open : String, text : String) -> String {
  if !self.enabled || text.is_empty() {
    text
  } else {
    "\u001b[\{open}m\{text}\u001b[0m"
  }
}

///|
fn Style::red(self : Style, text : String) -> String {
  self.wrap("31", text)
}

///|
fn Style::green(self : Style, text : String) -> String {
  self.wrap("32", text)
}

///|
fn Style::bold_green(self : Style, text : String) -> String {
  self.wrap("1;32", text)
}

///|
fn Style::yellow(self : Style, text : String) -> String {
  self.wrap("33", text)
}

///|
fn Style::blue(self : Style, text : String) -> String {
  self.wrap("34", text)
}

///|
fn Style::magenta(self : Style, text : String) -> String {
  self.wrap("35", text)
}

///|
fn Style::cyan(self : Style, text : String) -> String {
  self.wrap("36", text)
}

///|
fn Style::gray(self : Style, text : String) -> String {
  self.wrap("90", text)
}

///|
fn Style::dim(self : Style, text : String) -> String {
  self.wrap("2", text)
}

///|
fn Style::dim_gray(self : Style, text : String) -> String {
  self.wrap("2;90", text)
}

///|
fn Style::dim_magenta(self : Style, text : String) -> String {
  self.wrap("2;35", text)
}

///|
fn Style::gray_strikethrough(self : Style, text : String) -> String {
  self.wrap("90;9", text)
}

///|
fn Style::underline_red(self : Style, text : String) -> String {
  self.wrap("31;4", text)
}

///|
fn Style::inverse_red_bold(self : Style, text : String) -> String {
  self.wrap("7;1;31", text)
}

///|
fn Style::color_for_diff(
  self : Style,
  diff : @taze.DiffKind,
  text : String,
) -> String {
  match diff {
    Major => self.red(text)
    Minor => self.cyan(text)
    Patch => self.green(text)
    Pin => self.blue(text)
    Prerelease => self.magenta(text)
  }
}

///|
/// Strip ANSI CSI escape sequences (`\x1b[...m` etc.) for visual width calculation.
fn strip_ansi(str : String) -> String {
  let out = StringBuilder()
  let len = str.length()
  let mut i = 0
  while i < len {
    if str[i] == '\u001b' && i + 1 < len && str[i + 1] == '[' {
      i += 2
      while i < len {
        let code = str[i].to_int()
        i += 1
        if code >= 0x40 && code <= 0x7e {
          break
        }
      }
    } else {
      out.write_char(str[i].to_int().unsafe_to_char())
      i += 1
    }
  }
  out.to_string()
}

///|
/// Compute visual display width ignoring ANSI escapes and combining marks.
fn visual_length(str : String) -> Int32 {
  if str.is_empty() {
    return 0
  }
  let plain = strip_ansi(str)
  let mut width = 0
  for ch in plain {
    let code = ch.to_int()
    if code <= 0x1f || (code >= 0x7f && code <= 0x9f) {
      continue
    }
    if code >= 0x300 && code <= 0x36f {
      continue
    }
    width += 1
  }
  width
}

///|
fn repeat_spaces(count : Int32) -> String {
  if count <= 0 {
    ""
  } else {
    Array::make(count, " ").join("")
  }
}

///|
fn visual_pad_start(str : String, target_width : Int32) -> String {
  let pad = target_width - visual_length(str)
  if pad <= 0 {
    str
  } else {
    repeat_spaces(pad) + str
  }
}

///|
fn visual_pad_end(str : String, target_width : Int32) -> String {
  let pad = target_width - visual_length(str)
  if pad <= 0 {
    str
  } else {
    str + repeat_spaces(pad)
  }
}

///|
/// Format rows into aligned columns using `align` (`'L'` left, `'R'` right),
/// trimming trailing spaces from each formatted row.
fn format_table(
  rows : Array[Array[String]],
  align : String,
  spaces~ : String = "  ",
) -> Array[String] {
  let max_len : Array[Int32] = []
  for row in rows {
    for i, cell in row {
      let width = visual_length(cell)
      while max_len.length() <= i {
        max_len.push(0)
      }
      if width > max_len[i] {
        max_len[i] = width
      }
    }
  }
  rows.map(row => {
    let cols : Array[String] = []
    for i, cell in row {
      let is_right = i < align.length() && align[i] == 'R'
      let padded = if is_right {
        visual_pad_start(cell, max_len[i])
      } else {
        visual_pad_end(cell, max_len[i])
      }
      cols.push(padded)
    }
    let line = cols.join(spaces)
    line.trim_end(chars=" ").to_owned()
  })
}

///|
/// Highlight only the changed suffix of `to` relative to `from`, matching
/// upstream `taze`'s `colorizeVersionDiff` (`10.14.0 -> 10.` + `cyan("15.0")`).
fn colorize_version_diff(
  style : Style,
  from : String,
  to : String,
  diff : @taze.DiffKind?,
) -> String {
  let diff_kind = diff.unwrap_or(Patch)
  let parts_to = Array::from_iter(to.split(".").map(StringView::to_owned))
  let parts_from = Array::from_iter(from.split(".").map(StringView::to_owned))
  let mut first_diff = parts_to.length()
  for i in 0..<parts_to.length() {
    let from_part = parts_from.get(i).unwrap_or("")
    if parts_to[i] != from_part {
      first_diff = i
      break
    }
  }
  if first_diff == 0 {
    return style.color_for_diff(diff_kind, to)
  }
  if first_diff >= parts_to.length() {
    return to
  }
  let unchanged : Array[String] = []
  let changed : Array[String] = []
  for i in 0..<first_diff {
    unchanged.push(parts_to[i])
  }
  for i in first_diff..<parts_to.length() {
    changed.push(parts_to[i])
  }
  let prefix = unchanged.join(".") + "."
  let suffix = style.color_for_diff(diff_kind, changed.join("."))
  prefix + suffix
}

///|
/// Format a release timestamp age with upstream `taze`'s color scale.
/// Returns `""` when timestamp is unavailable (never prints `"unknown"`).
fn format_colored_age(
  style : Style,
  published_at : Int64?,
  now~ : Int64 = @async.now(),
) -> String {
  match published_at {
    None => ""
    Some(published) => {
      let elapsed = now - published
      if elapsed < 3600000L {
        style.gray("<1h")
      } else if elapsed < 360000000L {
        style.green("~\{(elapsed + 1800000L) / 3600000L}h")
      } else if elapsed < 2592000000L {
        style.green("~\{(elapsed + 43200000L) / 86400000L}d")
      } else if elapsed < 31536000000L {
        style.yellow("~\{(elapsed + 1296000000L) / 2592000000L}mo")
      } else {
        let tenths = (elapsed * 10L + 1576800000L) / 31536000000L
        let whole = tenths / 10L
        let frac = tenths % 10L
        if frac == 0L {
          style.red("~\{whole}y")
        } else {
          style.red("~\{whole}.\{frac}y")
        }
      }
    }
  }
}
