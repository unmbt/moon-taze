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
} derive(FromJson, Debug, Eq)

///|
pub struct ConfigResult {
  pub config : Config?
  pub diagnostics : Array[Diagnostic]
} derive(Debug, Eq)

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
  let value = @json.parse(data.text()) catch {
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
        "retry", "force",
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
