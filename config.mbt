///|
/// Static configuration loaded from `moon-taze.json` at the project or workspace root.
#derive(Eq, Debug)
pub struct Config {
  mode : String?
  recursive : Bool?
  all : Bool?
  include_selectors : Array[String]?
  exclude : Array[String]?
  ignoreOtherWorkspaces : Bool?
  retry : Int32?
  force : Bool?
  failOnOutdated : Bool?
  timediff : Bool?
  maturityPeriod : Int32?
  maturityPeriodExclude : Array[String]?
  githubActions : Json?
  githubActionsStyle : String?
}

///|
fn decode_optional_string(
  obj : Map[String, Json],
  key : String,
) -> String? raise {
  match obj.get(key) {
    None | Some(Null) => None
    Some(String(s)) => Some(s)
    Some(_) => fail("\{key} must be a string")
  }
}

///|
fn decode_optional_bool(obj : Map[String, Json], key : String) -> Bool? raise {
  match obj.get(key) {
    None | Some(Null) => None
    Some(True) => Some(true)
    Some(False) => Some(false)
    Some(_) => fail("\{key} must be a boolean")
  }
}

///|
fn decode_optional_int(obj : Map[String, Json], key : String) -> Int32? raise {
  match obj.get(key) {
    None | Some(Null) => None
    Some(Number(n, ..)) => {
      let i = n.to_int()
      if i.to_double() != n {
        fail("\{key} must be an integer")
      }
      Some(i)
    }
    Some(_) => fail("\{key} must be an integer")
  }
}

///|
fn decode_optional_strings(
  obj : Map[String, Json],
  key : String,
) -> Array[String]? raise {
  match obj.get(key) {
    None | Some(Null) => None
    Some(Array(items)) => {
      let result : Array[String] = []
      for item in items {
        match item {
          String(s) => result.push(s)
          _ => fail("\{key} must be an array of strings")
        }
      }
      Some(result)
    }
    Some(_) => fail("\{key} must be an array of strings")
  }
}

///|
fn decode_config(obj : Map[String, Json]) -> Config raise {
  {
    mode: decode_optional_string(obj, "mode"),
    recursive: decode_optional_bool(obj, "recursive"),
    all: decode_optional_bool(obj, "all"),
    include_selectors: decode_optional_strings(obj, "include"),
    exclude: decode_optional_strings(obj, "exclude"),
    ignoreOtherWorkspaces: decode_optional_bool(obj, "ignoreOtherWorkspaces"),
    retry: decode_optional_int(obj, "retry"),
    force: decode_optional_bool(obj, "force"),
    failOnOutdated: decode_optional_bool(obj, "failOnOutdated"),
    timediff: decode_optional_bool(obj, "timediff"),
    maturityPeriod: decode_optional_int(obj, "maturityPeriod"),
    maturityPeriodExclude: decode_optional_strings(obj, "maturityPeriodExclude"),
    githubActions: obj.get("githubActions"),
    githubActionsStyle: decode_optional_string(obj, "githubActionsStyle"),
  }
}

///|
#derive(Eq, Debug)
pub struct ConfigResult {
  config : Config?
  diagnostics : Array[Diagnostic]
}

///|
fn duplicate_top_level_key(text : String) -> String? {
  let keys : Array[String] = []
  let mut depth = 0
  let mut index = 0
  while index < text.length() {
    let c = text[index]
    if c == '"' {
      let start = index + 1
      index += 1
      let mut escaped = false
      while index < text.length() {
        let current = text[index]
        if escaped {
          escaped = false
        } else if current == '\\' {
          escaped = true
        } else if current == '"' {
          break
        }
        index += 1
      }
      if depth == 1 {
        let mut after = index + 1
        while after < text.length() &&
              (
                text[after] == ' ' ||
                text[after] == '\n' ||
                text[after] == '\r' ||
                text[after] == '\t'
              ) {
          after += 1
        }
        if after < text.length() && text[after] == ':' {
          let key = text[start:index].to_owned()
          if keys.contains(key) {
            return Some(key)
          }
          keys.push(key)
        }
      }
    } else if c == '{' || c == '[' {
      depth += 1
    } else if c == '}' || c == ']' {
      if depth > 0 {
        depth -= 1
      }
    }
    index += 1
  }
  None
}

///|
/// Resolve GitHub Actions enabled flag and style from a `Config`.
/// Returns `Err(message)` when `githubActions` or `githubActionsStyle` is malformed.
pub fn Config::resolve_github_actions(
  self : Config,
) -> (Bool?, GitHubActionStyle?) raise {
  let mut enabled : Bool? = None
  let mut style : GitHubActionStyle? = None
  match self.githubActions {
    None | Some(Null) => ()
    Some(True) => enabled = Some(true)
    Some(False) => enabled = Some(false)
    Some(Object(obj)) => {
      enabled = Some(true)
      for key, value in obj {
        match (key, value) {
          ("style", String(s)) =>
            match parse_gha_style(s) {
              Some(parsed) => style = Some(parsed)
              None => fail("invalid githubActions.style: \{s}")
            }
          _ => fail("unknown or invalid githubActions field: \{key}")
        }
      }
    }
    Some(_) => fail("githubActions must be a boolean or an object")
  }
  match self.githubActionsStyle {
    None => ()
    Some(s) =>
      match parse_gha_style(s) {
        Some(parsed) => style = Some(parsed)
        None => fail("invalid githubActionsStyle: \{s}")
      }
  }
  (enabled, style)
}

///|
/// Parse a GitHub Actions write style name (`auto` | `tag` | `sha`).
pub fn parse_gha_style(value : String) -> GitHubActionStyle? {
  match value {
    "auto" => Some(Auto)
    "tag" => Some(Tag)
    "sha" => Some(Sha)
    _ => None
  }
}

///|
/// Parse one `moon-taze.json` configuration file without executing user code.
pub async fn read_config(path : String) -> ConfigResult {
  let text = @fs.read_text(path) catch {
    error =>
      return {
        config: None,
        diagnostics: [
          diagnostic(
            "config_read_error",
            error.to_string(),
            Some(path),
            None,
            None,
            None,
          ),
        ],
      }
  }
  if duplicate_top_level_key(text) is Some(key) {
    return {
      config: None,
      diagnostics: [
        diagnostic(
          "invalid_config",
          "duplicate configuration key: \{key}",
          Some(path),
          None,
          None,
          None,
        ),
      ],
    }
  }
  let value = @json.parse(text) catch {
    error =>
      return {
        config: None,
        diagnostics: [
          diagnostic(
            "invalid_config",
            error.to_string(),
            Some(path),
            None,
            None,
            None,
          ),
        ],
      }
  }
  let object = match value {
    Object(object) => {
      let allowed = [
        "mode", "recursive", "all", "include", "exclude", "ignoreOtherWorkspaces",
        "retry", "force", "failOnOutdated", "timediff", "maturityPeriod", "maturityPeriodExclude",
        "githubActions", "githubActionsStyle",
      ]
      for key in object.keys() {
        if !allowed.contains(key) {
          return {
            config: None,
            diagnostics: [
              diagnostic(
                "invalid_config",
                "unknown configuration key: \{key}",
                Some(path),
                None,
                None,
                None,
              ),
            ],
          }
        }
      }
      object
    }
    _ =>
      return {
        config: None,
        diagnostics: [
          diagnostic(
            "invalid_config",
            "configuration root must be a JSON object",
            Some(path),
            None,
            None,
            None,
          ),
        ],
      }
  }
  let config : Config = decode_config(object) catch {
    error =>
      return {
        config: None,
        diagnostics: [
          diagnostic(
            "invalid_config",
            error.to_string(),
            Some(path),
            None,
            None,
            None,
          ),
        ],
      }
  }
  { config: Some(config), diagnostics: [], }
}
