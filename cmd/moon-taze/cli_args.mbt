///|
/// Declarative command line definition.  Keeping this separate from the
/// execution pipeline makes the argv contract testable without touching the
/// filesystem or registry.
fn cli_command() -> @argparse.Command {
  @argparse.Command(
    "moon-taze",
    about=(
      #|Check MoonBit module dependencies for available updates.
      #|Run without --write for a read-only preview.
    ),
    disable_help_flag=true,
    disable_version_flag=true,
    flags=[
      @argparse.FlagArg("help", short='h', about="Print help"),
      @argparse.FlagArg("version", short='V', about="Print version"),
      @argparse.FlagArg("write", short='w', about="Apply recommended updates"),
      @argparse.FlagArg(
        "interactive",
        short='I',
        about="Choose dependencies interactively",
      ),
      @argparse.FlagArg(
        "all",
        short='a',
        about="Show up-to-date and skipped dependencies",
      ),
      @argparse.FlagArg(
        "recursive",
        short='r',
        about="Discover nested moon.mod files",
      ),
      @argparse.FlagArg("json", about="Emit one machine-readable JSON report"),
      @argparse.FlagArg("silent", short='s', about="Suppress text diagnostics"),
      @argparse.FlagArg(
        "group",
        about="Group text output by manifest",
        negatable=true,
      ),
      @argparse.FlagArg(
        "verify",
        about="Run moon check after successful writes",
      ),
      @argparse.FlagArg(
        "force",
        short='f',
        about="Ignore and refresh the persistent cache",
        negatable=true,
      ),
      @argparse.FlagArg(
        "fail-on-outdated",
        about="Return 1 when updates are available",
        negatable=true,
      ),
      @argparse.FlagArg(
        "timediff",
        about="Show release time differences",
        negatable=true,
      ),
      @argparse.FlagArg("no-retry", about="Disable registry retries"),
    ],
    options=[
      @argparse.OptionArg(
        "cwd",
        short='C',
        about="Start discovery from DIR",
        allow_hyphen_values=true,
      ),
      @argparse.OptionArg(
        "include",
        short='n',
        about="Only check comma-separated module selectors",
        action=@argparse.OptionAction::Append,
      ),
      @argparse.OptionArg(
        "exclude",
        short='x',
        about="Skip comma-separated module selectors",
        action=@argparse.OptionAction::Append,
      ),
      @argparse.OptionArg("sort", about="Sort by name, diff, or release time"),
      @argparse.OptionArg(
        "maturity-period",
        about="Only use releases older than DAYS (bare flag means 7)",
        allow_hyphen_values=true,
      ),
      @argparse.OptionArg(
        "maturity-period-exclude",
        about="Exclude selectors from maturity filtering",
        action=@argparse.OptionAction::Append,
      ),
      @argparse.OptionArg(
        "retry",
        about="Retry transient registry failures COUNT times",
        allow_hyphen_values=true,
      ),
    ],
    positionals=[
      @argparse.PositionArg(
        "mode",
        about="default, major, minor, patch, latest, stable, newest, or next",
        num_args=@argparse.ValueRange(upper=1),
      ),
    ],
  )
}

///|
fn argv_without_program(args : Array[String]) -> Array[String] {
  if args.length() == 0 {
    []
  } else {
    args[1:].to_owned()
  }
}

///|
/// argparse options normally require a value.  Preserve the historical
/// `--maturity-period` shorthand by inserting its documented default before
/// parsing when the next token is another option, a mode, or the end of argv.
fn normalize_cli_argv(argv : Array[String]) -> Array[String] {
  let normalized : Array[String] = []
  let mut index = 0
  while index < argv.length() {
    let value = argv[index]
    normalized.push(value)
    if value == "--maturity-period" &&
      (
        index + 1 >= argv.length() ||
        argv[index + 1].has_prefix("-") ||
        parse_mode(argv[index + 1]) is Some(_)
      ) {
      normalized.push("7")
    }
    index += 1
  }
  normalized
}

///|
fn match_value(matches : @argparse.Matches, name : String) -> String? {
  match matches.values.get(name) {
    Some(values) => values.get(0)
    None => None
  }
}

///|
fn match_values(matches : @argparse.Matches, name : String) -> Array[String] {
  matches.values.get(name).unwrap_or([])
}

///|
fn match_flag(matches : @argparse.Matches, name : String) -> Bool {
  matches.flags.get(name).unwrap_or(false)
}

///|
fn match_seen_from_argv(matches : @argparse.Matches, name : String) -> Bool {
  matches.sources.get(name) is Some(@argparse.ValueSource::Argv)
}
