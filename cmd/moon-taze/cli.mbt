///|
priv suberror CliError {
  CliError(code~ : String, message~ : String)
}

///|
fn cli_error(
  message : String,
  code~ : String = "cli_error",
) -> Unit raise CliError {
  raise CliError(code~, message~)
}

///|
priv enum CliParseOutcome {
  Help(String)
  Version(String)
  Parsed(CliOptions)
}

///|
priv struct CliOptions {
  mut mode : @taze.UpdateMode
  mode_seen : Bool
  mut cwd : String
  mut show_all : Bool
  all_seen : Bool
  write : Bool
  json_output : Bool
  silent : Bool
  verify : Bool
  mut retry_count : Int32
  retry_seen : Bool
  mut force : Bool
  force_seen : Bool
  mut fail_on_outdated : Bool
  fail_on_outdated_seen : Bool
  mut maturity_days : Int32
  maturity_seen : Bool
  mut timediff : Bool
  timediff_seen : Bool
  maturity_exclude : Array[String]
  maturity_exclude_seen : Bool
  mut recursive : Bool
  recursive_seen : Bool
  group_output : Bool
  sort_mode : String
  include_selectors : Array[String]
  exclude_selectors : Array[String]
  mut github_actions : Bool
  github_actions_seen : Bool
  mut github_actions_style : @taze.GitHubActionStyle
  github_actions_style_seen : Bool
}

///|
fn build_cli() -> @cac.CAC {
  let cli = @cac.new(name="moon-taze")
  cli
  .command(
    "[mode]",
    description="Check MoonBit and GitHub Actions dependencies for updates (mode: default | major | minor | patch | latest | stable | newest | next)",
  )
  .option("-C, --cwd <dir>", "Start discovery from DIR")
  .option("-w, --write", "Apply recommended updates")
  .option(
    "-I, --interactive", "Choose dependencies interactively (not implemented yet)",
  )
  .option("-a, --all", "Show up-to-date and skipped dependencies")
  .option(
    "-r, --recursive", "Discover nested moon.mod and GitHub Actions files",
  )
  .option("--json", "Emit one machine-readable JSON report")
  .option("-s, --silent", "Suppress text diagnostics")
  .option(
    "--group",
    "Group dependencies by source (default: true)",
    default=Json::boolean(true),
  )
  .option("--verify", "Run moon check after successful moon.mod writes")
  .option("-f, --force", "Ignore and refresh the persistent cache")
  .option("--fail-on-outdated", "Return exit code 1 when updates are available")
  .option(
    "--timediff",
    "Show release ages for versions (default: true)",
    default=Json::boolean(true),
  )
  .option(
    "--no-github-actions", "Disable checking GitHub Actions workflows and actions",
  )
  .option(
    "--github-actions-style <style>", "How to write updated GitHub Actions: auto | tag | sha",
  )
  .option(
    "-n, --include <deps>",
    "Only check comma-separated dependency selectors",
    option_type=Strings,
  )
  .option(
    "-x, --exclude <deps>",
    "Skip comma-separated dependency selectors (supports name@range)",
    option_type=Strings,
  )
  .option(
    "--sort <type>", "Sort by name-asc|name-desc|diff-asc|diff-desc|time-asc|time-desc",
  )
  .option(
    "--maturity-period [days]", "Only use releases older than DAYS (bare flag means 7)",
  )
  .option(
    "--maturity-period-exclude <deps>",
    "Exclude selectors from maturity filtering",
    option_type=Strings,
  )
  .option(
    "--retry [times]", "Retry transient registry failures COUNT times (default: 4)",
  )
  .option("--no-retry", "Disable registry retries")
  |> ignore
  cli.help().version(VERSION, custom_flags="-V, --version") |> ignore
  cli
}

///|
fn argv_without_program(args : Array[String]) -> Array[String] {
  if args.is_empty() {
    []
  } else {
    args[1:].to_owned()
  }
}

///|
fn raw_has_flag(
  argv : Array[String],
  long_name : String,
  short_name~ : String? = None,
) -> Bool {
  let pos_flag = "--" + long_name
  let neg_flag = "--no-" + long_name
  for arg in argv {
    if arg == "--" {
      break
    }
    if arg == pos_flag ||
      arg.has_prefix(pos_flag + "=") ||
      arg == neg_flag ||
      arg.has_prefix(neg_flag + "=") {
      return true
    }
    if short_name is Some(short) {
      if arg == "-" + short {
        return true
      }
    }
  }
  false
}

///|
fn append_selectors(target : Array[String], value : String) -> Unit {
  for item in value.split(",") {
    let selector = item.trim().to_owned()
    if selector != "" {
      target.push(selector)
    }
  }
}

///|
fn mode_name(mode : @taze.UpdateMode) -> String {
  match mode {
    Default => "default"
    Major => "major"
    Minor => "minor"
    Patch => "patch"
    Latest => "latest"
    Stable => "stable"
    Newest => "newest"
    Next => "next"
  }
}

///|
fn parse_mode(name : String) -> @taze.UpdateMode? {
  match name {
    "default" => Some(Default)
    "major" => Some(Major)
    "minor" => Some(Minor)
    "patch" => Some(Patch)
    "latest" => Some(Latest)
    "stable" => Some(Stable)
    "newest" => Some(Newest)
    "next" => Some(Next)
    _ => None
  }
}

///|
fn parse_optional_int_option(
  ctx : @cac.Context,
  key : String,
  default_when_bare : Int32,
  label : String,
) -> Int32 raise CliError {
  match ctx.get(key) {
    None | Some(Null) => default_when_bare
    Some(True) => default_when_bare
    Some(False) => 0
    Some(Number(n, ..)) => {
      let value = n.to_int()
      if value < 0 || value.to_double() != n {
        cli_error("invalid \{label}: \{n}")
      }
      value
    }
    Some(String(raw)) => {
      let parsed = @string.parse_int(raw) catch {
        _ => {
          cli_error("invalid \{label}: \{raw}")
          -1
        }
      }
      if parsed < 0 {
        cli_error("invalid \{label}: \{raw}")
      }
      parsed
    }
    Some(other) => {
      cli_error("invalid \{label}: \{other.stringify()}")
      0
    }
  }
}

///|
fn parse_cli_args(args : Array[String]) -> CliParseOutcome raise CliError {
  let argv = argv_without_program(args)
  let cli = build_cli()
  let outcome = cli.parse(argv~, run=false) catch {
    err => raise CliError(code="cli_error", message="\{err}")
  }
  match outcome {
    Help(text) => Help(text)
    Version(_) => Version(VERSION)
    Matched(ctx) => {
      if ctx.bool("interactive") {
        cli_error(
          "interactive mode (-I/--interactive) is not implemented yet",
          code="not_implemented",
        )
      }
      let mut mode = @taze.UpdateMode::Default
      let mut mode_seen = false
      if ctx.arg("mode") is Some(value) {
        match parse_mode(value) {
          Some(parsed) => {
            mode = parsed
            mode_seen = true
          }
          None => cli_error("unknown update mode: \{value}")
        }
      }
      let cwd = ctx.string("cwd").unwrap_or(@env.current_dir().unwrap_or("."))
      let sort_mode = match ctx.string("sort") {
        Some(value) =>
          match value {
            "diff-asc"
            | "diff-desc"
            | "name-asc"
            | "name-desc"
            | "time-asc"
            | "time-desc" => value
            _ => {
              cli_error("invalid sort value: \{value}")
              "diff-asc"
            }
          }
        None => "diff-asc"
      }
      let github_actions_style_seen = raw_has_flag(argv, "github-actions-style")
      let github_actions_style = match ctx.string("githubActionsStyle") {
        Some(value) =>
          match @taze.parse_gha_style(value) {
            Some(parsed) => parsed
            None => {
              cli_error(
                "invalid --github-actions-style: \{value}. Use auto | tag | sha",
              )
              Auto
            }
          }
        None => Auto
      }
      let retry_seen = raw_has_flag(argv, "retry")
      let retry_count = if retry_seen {
        parse_optional_int_option(ctx, "retry", 4, "retry count")
      } else {
        4
      }
      let maturity_seen = raw_has_flag(argv, "maturity-period")
      let maturity_days = if maturity_seen {
        parse_optional_int_option(ctx, "maturityPeriod", 7, "maturity period")
      } else {
        0
      }
      let include_selectors : Array[String] = []
      for item in ctx.strings("include") {
        append_selectors(include_selectors, item)
      }
      let exclude_selectors : Array[String] = []
      for item in ctx.strings("exclude") {
        append_selectors(exclude_selectors, item)
      }
      let maturity_exclude : Array[String] = []
      for item in ctx.strings("maturityPeriodExclude") {
        append_selectors(maturity_exclude, item)
      }
      let github_actions_seen = raw_has_flag(argv, "github-actions")
      let github_actions = if github_actions_seen {
        ctx.bool("githubActions", default=true)
      } else {
        true
      }
      Parsed({
        mode,
        mode_seen,
        cwd,
        show_all: ctx.bool("all"),
        all_seen: raw_has_flag(argv, "all", short_name=Some("a")),
        write: ctx.bool("write"),
        json_output: ctx.bool("json"),
        silent: ctx.bool("silent"),
        verify: ctx.bool("verify"),
        retry_count,
        retry_seen,
        force: ctx.bool("force"),
        force_seen: raw_has_flag(argv, "force", short_name=Some("f")),
        fail_on_outdated: ctx.bool("failOnOutdated"),
        fail_on_outdated_seen: raw_has_flag(argv, "fail-on-outdated"),
        maturity_days,
        maturity_seen,
        timediff: ctx.bool("timediff", default=true),
        timediff_seen: raw_has_flag(argv, "timediff"),
        maturity_exclude,
        maturity_exclude_seen: raw_has_flag(argv, "maturity-period-exclude"),
        recursive: ctx.bool("recursive"),
        recursive_seen: raw_has_flag(argv, "recursive", short_name=Some("r")),
        group_output: ctx.bool("group", default=true),
        sort_mode,
        include_selectors,
        exclude_selectors,
        github_actions,
        github_actions_seen,
        github_actions_style,
        github_actions_style_seen,
      })
    }
  }
}
