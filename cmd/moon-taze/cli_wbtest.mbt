///|
test "cac CLI help, bare version, defaults, and core options" {
  let help = parse_cli_args(["moon-taze", "--help"])
  assert_true(help is Help(_))
  let version = parse_cli_args(["moon-taze", "-V"])
  match version {
    Version(v) => assert_eq(v, VERSION)
    _ => fail("expected Version")
  }
  match parse_cli_args(["moon-taze"]) {
    Parsed(defaults) => {
      assert_eq(defaults.mode, Default)
      assert_true(defaults.group_output)
      assert_true(defaults.timediff)
      assert_eq(defaults.sort_mode, "diff-asc")
      assert_true(defaults.github_actions)
    }
    _ => fail("expected Parsed defaults")
  }
  match
    parse_cli_args([
      "moon-taze", "major", "-w", "-a", "-r", "--no-group", "--no-timediff", "--maturity-period",
      "--no-retry", "--no-github-actions", "--github-actions-style", "sha", "-n",
      "a/b,c/d", "-x", "e/f@1",
    ]) {
    Parsed(opts) => {
      assert_eq(opts.mode, Major)
      assert_true(opts.write)
      assert_true(opts.show_all)
      assert_true(opts.recursive)
      assert_false(opts.group_output)
      assert_false(opts.timediff)
      assert_eq(opts.maturity_days, 7)
      assert_eq(opts.retry_count, 0)
      assert_false(opts.github_actions)
      assert_eq(opts.github_actions_style, Sha)
      assert_eq(opts.include_selectors, ["a/b", "c/d"])
      assert_eq(opts.exclude_selectors, ["e/f@1"])
    }
    _ => fail("expected Parsed")
  }
}

///|
test "interactive flag fails fast with not_implemented error" {
  for flag in ["-I", "--interactive"] {
    try ignore(parse_cli_args(["moon-taze", flag])) catch {
      CliError(code~, message~) => {
        assert_eq(code, "not_implemented")
        assert_true(message.contains("not implemented"))
      }
    } noraise {
      _ => fail("expected not_implemented error for \{flag}")
    }
  }
}

///|
async test "progress bar clamps count and renders taze style" {
  let bar = progress_bar(2, false, color=false)
  progress_bar_update(bar, "demo/a")
  progress_bar_update(bar, "demo/b")
  progress_bar_update(bar, "demo/c")
  assert_eq(bar.val.current, 2)
  let rendered = progress_bar_render(bar.val, "demo/c")
  assert_true(rendered.contains("dep "))
  assert_true(rendered.contains("2/2 demo/c"))
  progress_bar_stop(bar)
  assert_true(bar.val.stopped)
}

///|
test "ANSI strip, visual length, aligned table, and partial version diff coloring" {
  let style = Style::new(true)
  let colored = style.cyan("unmbt/moon-taze")
  assert_eq(strip_ansi(colored), "unmbt/moon-taze")
  assert_eq(visual_length(colored), 15)

  let table = format_table(
    [
      [style.cyan("a"), style.gray("1.0.0"), style.green("1.0.1")],
      ["longer-pkg", style.gray("10.14.0"), style.cyan("10.15.0")],
    ],
    "LRR",
  )
  assert_eq(strip_ansi(table[0]), "a             1.0.0    1.0.1")
  assert_eq(strip_ansi(table[1]), "longer-pkg  10.14.0  10.15.0")

  // Only changed suffix gets colored.
  let minor_diff = colorize_version_diff(
    style,
    "10.14.0",
    "10.15.0",
    Some(Minor),
  )
  assert_eq(minor_diff, "10." + style.cyan("15.0"))
  let patch_diff = colorize_version_diff(style, "0.23.5", "0.23.7", Some(Patch))
  assert_eq(patch_diff, "0.23." + style.green("7"))
  let major_diff = colorize_version_diff(style, "v4", "v5", Some(Major))
  assert_eq(major_diff, style.red("v5"))
}

///|
test "colored release ages match taze thresholds and omit missing timestamps" {
  let plain = Style::new(false)
  let colored = Style::new(true)
  assert_eq(format_colored_age(plain, None, now=0L), "")
  assert_eq(format_colored_age(colored, Some(0L), now=0L), colored.gray("<1h"))
  assert_eq(
    format_colored_age(colored, Some(0L), now=7200000L),
    colored.green("~2h"),
  )
  assert_eq(
    format_colored_age(colored, Some(0L), now=864000000L),
    colored.green("~10d"),
  )
  assert_eq(
    format_colored_age(colored, Some(0L), now=5184000000L),
    colored.yellow("~2mo"),
  )
  assert_eq(
    format_colored_age(colored, Some(0L), now=31536000000L),
    colored.red("~1y"),
  )
  assert_eq(
    format_colored_age(colored, Some(0L), now=47304000000L),
    colored.red("~1.5y"),
  )
}
