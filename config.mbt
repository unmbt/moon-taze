///|
/// Static configuration loaded from the single `moon-taze.json` at the
/// invocation root. CLI parsing and write/verify decisions remain in the CLI.
pub struct Config {
  pub mode : String?
  pub recursive : Bool?
  pub all : Bool?
  pub include : Array[String]?
  pub exclude : Array[String]?
  pub ignoreOtherWorkspaces : Bool?
  pub retry : Int?
  pub force : Bool?
  pub failOnOutdated : Bool?
  pub timediff : Bool?
  pub maturityPeriod : Int?
  pub maturityPeriodExclude : Array[String]?
} derive(FromJson, Debug, Eq)

///|
pub struct ConfigResult {
  pub config : Config?
  pub diagnostics : Array[Diagnostic]
} derive(Debug, Eq)

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
/// Parse one configuration file without executing any user supplied code.
pub async fn read_config(path : String) -> ConfigResult {
  let data = @fs.read_file(path) catch {
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
  let text = data.text()
  match duplicate_top_level_key(text) {
    Some(key) =>
      return {
        config: None,
        diagnostics: [
          diagnostic(
            "invalid_config",
            "duplicate configuration key: {key}",
            Some(path),
            None,
            None,
            None,
          ),
        ],
      }
    None => ()
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
  match value {
    Json::Object(object) => {
      let allowed = [
        "mode", "recursive", "all", "include", "exclude", "ignoreOtherWorkspaces",
        "retry", "force", "failOnOutdated", "timediff", "maturityPeriod", "maturityPeriodExclude",
      ]
      for key in object.keys() {
        if !allowed.contains(key) {
          return {
            config: None,
            diagnostics: [
              diagnostic(
                "invalid_config",
                "unknown configuration key: {key}",
                Some(path),
                None,
                None,
                None,
              ),
            ],
          }
        }
      }
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
  let config : Config = @json.from_json(value) catch {
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
