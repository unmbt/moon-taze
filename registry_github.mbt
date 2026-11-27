///|
const GITHUB_API_DEFAULT : String = "https://api.github.com"

///|
const GITHUB_MAX_TAG_PAGES : Int32 = 10

///|
let cached_gh_token : Ref[(Bool, String?)] = Ref((false, None))

///|
let gh_token_lock : @async.Semaphore = @async.Semaphore(1)

///|
/// Resolve a GitHub API token from `GITHUB_TOKEN`, `GH_TOKEN`, or `gh auth token`.
async fn resolve_github_token() -> String? noraise {
  match @env.get_env_var("GITHUB_TOKEN") {
    Some(token) if !token.is_empty() => return Some(token)
    _ => ()
  }
  match @env.get_env_var("GH_TOKEN") {
    Some(token) if !token.is_empty() => return Some(token)
    _ => ()
  }
  if cached_gh_token.val.0 {
    return cached_gh_token.val.1
  }
  gh_token_lock.acquire()
  defer gh_token_lock.release()
  if cached_gh_token.val.0 {
    return cached_gh_token.val.1
  }
  let fetched : String? = try {
    let result = @async.with_timeout_opt(5000, () => {
      @process.run(
        "gh",
        ["auth", "token"],
        inherit_env=true,
        stdout=Collect,
        stderr=Collect,
        accepted_exit_code=_ => true,
      )
    })
    match result {
      Some(out) if out.exit_code == 0 => {
        let value = out.stdout_text().trim().to_owned()
        if value.is_empty() {
          None
        } else {
          Some(value)
        }
      }
      _ => None
    }
  } catch {
    _ => None
  }
  cached_gh_token.val = (true, fetched)
  fetched
}

///|
async fn github_headers() -> Map[@http.CaseInsensitiveString, String] noraise {
  let headers : Map[@http.CaseInsensitiveString, String] = Map([])
  headers[CaseInsensitiveString("accept")] = "application/vnd.github+json"
  headers[CaseInsensitiveString("user-agent")] = "moon-taze"
  headers[CaseInsensitiveString("x-github-api-version")] = "2022-11-28"
  if resolve_github_token() is Some(token) {
    headers[CaseInsensitiveString("authorization")] = "Bearer \{token}"
  }
  headers
}

///|
fn parse_github_tags_page(
  json : Json,
) -> Array[(ParsedActionTag, String)] raise RegistryError {
  match json {
    Array(items) => {
      let parsed : Array[(ParsedActionTag, String)] = []
      for item in items {
        match item {
          Object(obj) => {
            let name = match obj.get("name") {
              Some(String(s)) => s
              _ => continue
            }
            let sha = match obj.get("commit") {
              Some(Object(commit)) =>
                match commit.get("sha") {
                  Some(String(s)) => s
                  _ => ""
                }
              _ => ""
            }
            if parse_action_tag(name) is Some(tag) {
              parsed.push((tag, sha))
            }
          }
          _ => ()
        }
      }
      parsed
    }
    _ => raise InvalidMetadata("GitHub tags response must be a JSON array")
  }
}

///|
fn parse_github_commit_date_json(json : Json) -> Int64? {
  match json {
    Object(root) =>
      match root.get("commit") {
        Some(Object(commit)) => {
          let committer_date = match commit.get("committer") {
            Some(Object(c)) =>
              match c.get("date") {
                Some(String(s)) => Some(s)
                _ => None
              }
            _ => None
          }
          let raw = match committer_date {
            Some(date) => Some(date)
            None =>
              match commit.get("author") {
                Some(Object(a)) =>
                  match a.get("date") {
                    Some(String(s)) => Some(s)
                    _ => None
                  }
                _ => None
              }
          }
          match raw {
            Some(value) => parse_rfc3339_ms(value)
            None => None
          }
        }
        _ => None
      }
    _ => None
  }
}

///|
/// Validate GitHub Actions metadata before storing it in cache or resolving.
pub fn valid_gha_metadata(value : ModuleMetadata, requested : String) -> Bool {
  if value.module_name != requested {
    return false
  }
  for item in value.versions {
    if parse_action_tag(item.version) is None {
      return false
    }
  }
  true
}

///|
/// Fetch paginated `v*` version tags and commit SHAs for a GitHub repository.
pub async fn query_github_tags(
  repo : String,
  api_root~ : String = GITHUB_API_DEFAULT,
  timeout_ms~ : Int32 = 5000,
) -> ModuleMetadata raise RegistryError {
  let headers = github_headers()
  let collected : Array[(ParsedActionTag, String)] = []
  let seen : Map[String, Unit] = Map([])
  for page in 1..<=GITHUB_MAX_TAG_PAGES {
    let url = "\{api_root}/repos/\{repo}/tags?per_page=100&page=\{page}"
    let response_text = @async.with_timeout_opt(timeout_ms, async fn() {
      let (response, body) = @http.get(url, headers~)
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
      if response.code == 403 &&
        response.headers.get(CaseInsensitiveString("x-ratelimit-remaining")) ==
        Some("0") {
        raise RequestFailed("rate_limited")
      }
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
    let raw_count = match json {
      Array(items) => items.length()
      _ => raise InvalidMetadata("GitHub tags response must be a JSON array")
    }
    if raw_count == 0 {
      break
    }
    for entry in parse_github_tags_page(json) {
      let (tag, sha) = entry
      if !seen.contains(tag.raw) {
        seen[tag.raw] = ()
        collected.push((tag, sha))
      }
    }
    if raw_count < 100 {
      break
    }
  }
  collected.sort_by((a, b) => compare_action_tag(a.0, b.0))
  let versions = collected.map(entry => {
    let (tag, sha) = entry
    {
      version: tag.raw,
      yanked: false,
      yanked_reason: None,
      published_at: None,
      sha: if sha.is_empty() {
        None
      } else {
        Some(sha)
      },
    }
  })
  let latest = if versions.is_empty() {
    None
  } else {
    Some(versions[versions.length() - 1].version)
  }
  { module_name: repo, latest, versions, }
}

///|
/// Fetch the commit publication timestamp (Unix ms) for a GitHub repository SHA.
pub async fn query_github_commit_date(
  repo : String,
  sha : String,
  api_root~ : String = GITHUB_API_DEFAULT,
  timeout_ms~ : Int32 = 5000,
) -> Int64? raise RegistryError {
  let headers = github_headers()
  let url = "\{api_root}/repos/\{repo}/commits/\{sha}"
  let response_text = @async.with_timeout_opt(timeout_ms, async fn() {
    let (response, body) = @http.get(url, headers~)
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
    if response.code == 403 &&
      response.headers.get(CaseInsensitiveString("x-ratelimit-remaining")) ==
      Some("0") {
      raise RequestFailed("rate_limited")
    }
    raise RequestFailed("HTTP \{response.code}")
  }
  let json = @json.parse(text) catch { _ => return None }
  parse_github_commit_date_json(json)
}
