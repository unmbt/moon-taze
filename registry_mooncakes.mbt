///|
fn RegistryError::message(self : RegistryError) -> String {
  match self {
    RequestFailed(value) => value
    InvalidMetadata(value) => value
  }
}

///|
fn RegistryError::code(self : RegistryError) -> String {
  match self {
    RequestFailed(message) if message == "request_timeout" => "request_timeout"
    RequestFailed(message) if message == "rate_limited" => "rate_limited"
    RequestFailed(message) if message.has_prefix("HTTP 404") =>
      "module_not_found"
    RequestFailed(_) => "http_error"
    InvalidMetadata(_) => "invalid_metadata"
  }
}

///|
/// Return true if a `RegistryError` is transient and eligible for retry.
pub fn is_retryable_registry_error(error : RegistryError) -> Bool {
  match error {
    InvalidMetadata(_) => false
    RequestFailed(message) =>
      message == "request_timeout" ||
      message.has_prefix("HTTP 408") ||
      message.has_prefix("HTTP 429") ||
      message.has_prefix("HTTP 5")
  }
}

///|
fn retry_after_header(value : String) -> String {
  let seconds : Int32? = Some(@string.parse_int(value)) catch { _ => None }
  match seconds {
    Some(value) if value >= 0 => "|retry-after-ms=\{value * 1000}"
    _ => ""
  }
}

///|
fn retry_after_delay(error : RegistryError) -> Int32? {
  match error {
    RequestFailed(message) =>
      match message.split_once("|retry-after-ms=") {
        Some((_, value)) =>
          Some(@string.parse_int(value.to_owned())) catch {
            _ => None
          }
        None => None
      }
    InvalidMetadata(_) => None
  }
}

///|
/// Execute a registry operation with bounded exponential backoff retry.
pub async fn[T] retry_registry(
  retries~ : Int32,
  delay_ms~ : Int32,
  action : async () -> T raise RegistryError,
) -> T raise RegistryError {
  let max_retries = if retries < 0 { 0 } else { retries }
  let base_delay = if delay_ms < 0 { 0 } else { delay_ms }
  let mut attempt = 0
  for ;; {
    try action() catch {
      error => {
        if !is_retryable_registry_error(error) || attempt >= max_retries {
          raise error
        }
        let delay = match retry_after_delay(error) {
          Some(value) if value >= 0 => value
          _ => {
            let mut computed = base_delay
            for _ in 0..<attempt {
              computed = computed * 2
            }
            computed
          }
        }
        if delay > 0 {
          @async.sleep(delay)
        }
        attempt += 1
      }
    } noraise {
      result => return result
    }
  }
}

///|
priv struct RegistryOverview {
  module_ : String
  latest_version : String?
  versions : Array[RegistryVersion]
}

///|
#derive(FromJson)
priv struct RegistryVersion {
  version : String
  yanked : Bool
  yanked_reason : Json
}

///|
priv struct RegistryDetail {
  module_ : String
  version : String
  yanked : Bool
  yanked_reason : Json
  metadata : Json?
}

///|
fn optional_reason(value : Json) -> String? raise RegistryError {
  match value {
    Null => None
    String(reason) => Some(reason)
    _ => raise InvalidMetadata("yanked_reason must be a string or null")
  }
}

///|
fn registry_url(root : String, module_name : String) -> String {
  let encoded = module_name.replace(old="/", new="%2F")
  root + "/api/v0/modules/" + encoded
}

///|
fn registry_version_url(
  root : String,
  module_name : String,
  version : String,
) -> String {
  registry_url(root, module_name) + "%40" + version.replace(old="+", new="%2B")
}

///|
fn detail_created_at(value : Json?) -> String? raise RegistryError {
  match value {
    Some(Object(object)) =>
      match object.get("created_at") {
        Some(String(created_at)) => Some(created_at)
        None | Some(Null) => None
        _ => raise InvalidMetadata("created_at must be a string or null")
      }
    None | Some(Null) => None
    _ => raise InvalidMetadata("metadata must be an object or null")
  }
}

///|
fn decode_overview_json(json : Json) -> RegistryOverview raise RegistryError {
  match json {
    Object(obj) => {
      let module_ = match obj.get("module") {
        Some(String(s)) => s
        _ => raise InvalidMetadata("invalid metadata schema: missing module")
      }
      let latest_version : String? = match obj.get("latest_version") {
        None | Some(Null) => None
        Some(String(s)) => Some(s)
        _ =>
          raise InvalidMetadata(
            "invalid metadata schema: latest_version must be string or null",
          )
      }
      let versions : Array[RegistryVersion] = match obj.get("versions") {
        Some(raw_versions) =>
          @json.from_json(raw_versions) catch {
            err => raise InvalidMetadata("invalid metadata schema: \{err}")
          }
        None =>
          raise InvalidMetadata("invalid metadata schema: missing versions")
      }
      { module_, latest_version, versions, }
    }
    _ => raise InvalidMetadata("invalid metadata schema: expected JSON object")
  }
}

///|
fn decode_detail_json(json : Json) -> RegistryDetail raise RegistryError {
  match json {
    Object(obj) => {
      let module_ = match obj.get("module") {
        Some(String(s)) => s
        _ => raise InvalidMetadata("invalid metadata schema: missing module")
      }
      let version = match obj.get("version") {
        Some(String(s)) => s
        _ => raise InvalidMetadata("invalid metadata schema: missing version")
      }
      let yanked = match obj.get("yanked") {
        Some(True) => true
        Some(False) => false
        _ => raise InvalidMetadata("invalid metadata schema: missing yanked")
      }
      let yanked_reason = obj.get("yanked_reason").unwrap_or(Json::null())
      let metadata = obj.get("metadata")
      { module_, version, yanked, yanked_reason, metadata, }
    }
    _ => raise InvalidMetadata("invalid metadata schema: expected JSON object")
  }
}

///|
fn metadata_from_overview(
  value : RegistryOverview,
  requested : String,
) -> ModuleMetadata raise RegistryError {
  if value.module_ != requested {
    raise InvalidMetadata("module mismatch")
  }
  let seen : Map[String, Bool] = Map([])
  let versions : Array[VersionMetadata] = []
  for item in value.versions {
    if seen.contains(item.version) {
      raise InvalidMetadata("duplicate version")
    }
    let parsed = parse_version(item.version) catch {
      _ => raise InvalidMetadata("invalid version")
    }
    ignore(parsed)
    seen[item.version] = true
    versions.push({
      version: item.version,
      yanked: item.yanked,
      yanked_reason: optional_reason(item.yanked_reason),
      published_at: None,
      sha: None,
    })
  }
  match value.latest_version {
    None => { module_name: requested, latest: None, versions, }
    Some(latest) => {
      let latest_version = parse_version(latest) catch {
        _ => raise InvalidMetadata("invalid latest version")
      }
      if !seen.contains(latest_version.to_string()) && !seen.contains(latest) {
        raise InvalidMetadata("latest version is absent from versions")
      }
      { module_name: requested, latest: Some(latest), versions, }
    }
  }
}

///|
fn metadata_from_detail(
  json : Json,
  module_name : String,
  version : String,
) -> VersionMetadata raise RegistryError {
  let detail = decode_detail_json(json)
  if detail.module_ != module_name {
    raise InvalidMetadata("detail module mismatch")
  }
  if detail.version != version {
    raise InvalidMetadata("detail version mismatch")
  }
  let published_at = match detail_created_at(detail.metadata) {
    Some(value) =>
      match parse_rfc3339_ms(value) {
        Some(timestamp) => Some(timestamp)
        None => raise InvalidMetadata("invalid created_at")
      }
    None => None
  }
  {
    version,
    yanked: detail.yanked,
    yanked_reason: optional_reason(detail.yanked_reason),
    published_at,
    sha: None,
  }
}

///|
/// Validate successful Mooncakes metadata before it enters a persistent cache.
pub fn valid_metadata(value : ModuleMetadata, requested : String) -> Bool {
  metadata_is_valid(value, requested) is None
}

///|
fn metadata_is_valid(metadata : ModuleMetadata, requested : String) -> String? {
  if metadata.module_name != requested {
    return Some("registry module does not match the requested module")
  }
  let seen : Map[String, Bool] = Map([])
  for item in metadata.versions {
    let parsed = Some(parse_version(item.version)) catch { _ => None }
    if parsed is None {
      return Some("registry returned an invalid version")
    }
    if seen.contains(item.version) {
      return Some("registry returned a duplicate version")
    }
    seen[item.version] = true
  }
  match metadata.latest {
    None => None
    Some(value) => {
      let parsed = parse_version(value) catch {
        _ => return Some("registry returned an invalid latest version")
      }
      if !seen.contains(value) && !seen.contains(parsed.to_string()) {
        Some("latest version is absent from registry metadata")
      } else {
        None
      }
    }
  }
}

///|
/// Query the Mooncakes overview endpoint.
pub async fn query_mooncakes(
  root~ : String,
  module_name : String,
) -> ModuleMetadata raise RegistryError {
  let url = registry_url(root, module_name)
  let response_text = @async.with_timeout_opt(5000, async fn() {
    let (response, body) = @http.get(url)
    let text = body.text()
    (response, text)
  }) catch {
    @async.TimeoutError => raise RequestFailed("request_timeout")
    err => raise RequestFailed(err.to_string())
  }
  let (response, text) = match response_text {
    None => raise RequestFailed("request_timeout")
    Some(value) => value
  }
  if response.code < 200 || response.code >= 300 {
    let retry_after = match
      response.headers.get(CaseInsensitiveString("retry-after")) {
      Some(value) => retry_after_header(value)
      None => ""
    }
    raise RequestFailed("HTTP \{response.code}\{retry_after}")
  }
  let json = @json.parse(text) catch {
    _ => raise InvalidMetadata("invalid JSON")
  }
  let overview = decode_overview_json(json)
  metadata_from_overview(overview, module_name)
}

///|
/// Query one Mooncakes version detail, including withdrawal status and UTC
/// publication time in Unix milliseconds.
pub async fn query_mooncakes_version(
  root~ : String,
  module_name : String,
  version : String,
) -> VersionMetadata raise RegistryError {
  ignore(
    parse_version(version) catch {
      _ => raise InvalidMetadata("invalid requested version")
    },
  )
  let url = registry_version_url(root, module_name, version)
  let response_text = @async.with_timeout_opt(5000, async fn() {
    let (response, body) = @http.get(url)
    let text = body.text()
    (response, text)
  }) catch {
    @async.TimeoutError => raise RequestFailed("request_timeout")
    err => raise RequestFailed(err.to_string())
  }
  let (response, text) = match response_text {
    None => raise RequestFailed("request_timeout")
    Some(value) => value
  }
  if response.code < 200 || response.code >= 300 {
    let retry_after = match
      response.headers.get(CaseInsensitiveString("retry-after")) {
      Some(value) => retry_after_header(value)
      None => ""
    }
    raise RequestFailed("HTTP \{response.code}\{retry_after}")
  }
  let json = @json.parse(text) catch {
    _ => raise InvalidMetadata("invalid JSON")
  }
  metadata_from_detail(json, module_name, version)
}

///|
/// Query Mooncakes with bounded exponential retry for transient failures.
pub async fn query_mooncakes_retry(
  root~ : String,
  module_name : String,
  retries~ : Int32,
  delay_ms~ : Int32,
) -> ModuleMetadata raise RegistryError {
  retry_registry(retries~, delay_ms~, () => query_mooncakes(root~, module_name))
}
