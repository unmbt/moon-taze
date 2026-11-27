///|
#derive(FromJson)
priv struct DiskCacheVersion {
  version : String
  yanked : Bool
  yanked_reason : String
  published_at : Int64
  sha : String
}

///|
#derive(FromJson)
priv struct DiskCacheEntry {
  kind : String
  registry : String
  module_name : String
  latest : String
  versions : Array[DiskCacheVersion]
  storedAt : Int64
}

///|
#derive(FromJson)
priv struct DiskCacheFile {
  schemaVersion : Int32
  entries : Array[DiskCacheEntry]
}

///|
const CACHE_TTL_MS : UInt64 = 1800000UL

///|
fn persistent_cache_path() -> String? {
  let base = match @env.get_env_var("LOCALAPPDATA") {
    Some(value) => Some(value)
    None =>
      match @env.get_env_var("XDG_CACHE_HOME") {
        Some(value) => Some(value)
        None =>
          match @env.get_env_var("HOME") {
            Some(value) => Some(value + "/.cache")
            None => @env.get_env_var("USERPROFILE")
          }
      }
  }
  base.map(value => value + "/moon-taze/cache-v2.json")
}

///|
fn mooncakes_cache_key(registry : String, name : String) -> String {
  "mooncakes|" + registry + "|" + name
}

///|
fn gha_cache_key(repo : String) -> String {
  "gha|https://api.github.com|" + repo
}

///|
fn cache_fresh(stored : UInt64, now : UInt64) -> Bool {
  now >= stored && now - stored < CACHE_TTL_MS
}

///|
async fn load_persistent_cache(
  path : String?,
  cache~ : Map[String, @taze.ModuleMetadata],
  cache_times~ : Map[String, UInt64],
  now~ : UInt64 = @env.now(),
  warn~ : (String) -> Unit = _ => (),
) -> Unit {
  guard path is Some(path) else { return }
  if !@fs.exists(path) {
    return
  }
  let text = @fs.read_text(path) catch {
    _ => {
      warn("cache_read_failed")
      return
    }
  }
  let json = @json.parse(text) catch {
    _ => {
      warn("cache_invalid")
      return
    }
  }
  let file : DiskCacheFile = @json.from_json(json) catch {
    _ => {
      warn("cache_invalid")
      return
    }
  }
  if file.schemaVersion != 2 {
    warn("cache_schema_unsupported")
    return
  }
  for entry in file.entries {
    if entry.storedAt < 0L ||
      !cache_fresh(entry.storedAt.reinterpret_as_uint64(), now) {
      continue
    }
    let versions = entry.versions.map(item => {
      @taze.VersionMetadata(
        item.version,
        item.yanked,
        if item.yanked_reason == "" {
          None
        } else {
          Some(item.yanked_reason)
        },
        if item.published_at < 0L {
          None
        } else {
          Some(item.published_at)
        },
        sha=if item.sha == "" { None } else { Some(item.sha) },
      )
    })
    let metadata = @taze.ModuleMetadata(
      entry.module_name,
      if entry.latest == "" {
        None
      } else {
        Some(entry.latest)
      },
      versions,
    )
    let valid = if entry.kind == "gha" {
      @taze.valid_gha_metadata(metadata, entry.module_name)
    } else {
      @taze.valid_metadata(metadata, entry.module_name)
    }
    if !valid {
      warn("cache_invalid_metadata")
      continue
    }
    let key = if entry.kind == "gha" {
      gha_cache_key(entry.module_name)
    } else {
      mooncakes_cache_key(entry.registry, entry.module_name)
    }
    cache[key] = metadata
    cache_times[key] = entry.storedAt.reinterpret_as_uint64()
  }
}

///|
fn cache_entry_json(
  kind : String,
  registry : String,
  metadata : @taze.ModuleMetadata,
  stored_at : UInt64,
) -> Json {
  let object : Map[String, Json] = Map([])
  object["kind"] = json_text(kind)
  object["registry"] = json_text(registry)
  object["module_name"] = json_text(metadata.module_name)
  object["latest"] = json_text(metadata.latest.unwrap_or(""))
  object["storedAt"] = Json::string(stored_at.to_string())
  object["versions"] = Json::array(
    metadata.versions.map(version => {
      let item : Map[String, Json] = Map([])
      item["version"] = json_text(version.version)
      item["yanked"] = Json::boolean(version.yanked)
      item["yanked_reason"] = json_text(version.yanked_reason.unwrap_or(""))
      item["published_at"] = Json::string(
        version.published_at.map(value => value.to_string()).unwrap_or("-1"),
      )
      item["sha"] = json_text(version.sha.unwrap_or(""))
      Json::object(item)
    }),
  )
  Json::object(object)
}

///|
async fn save_persistent_cache(
  path : String?,
  cache : Map[String, @taze.ModuleMetadata],
  cache_times : Map[String, UInt64],
  now~ : UInt64 = @env.now(),
  warn~ : (String) -> Unit = _ => (),
) -> Unit {
  guard path is Some(path) else { return }
  let directory = parent_path(path).unwrap_or("")
  if directory != "" && !@fs.exists(directory) {
    @fs.mkdir(directory, recursive=true) catch {
      _ =>
        if !@fs.exists(directory) {
          warn("cache_write_failed")
          return
        }
    }
  }
  let keys = cache.keys().to_array()
  keys.sort()
  let entries : Array[Json] = []
  for key in keys {
    guard cache.get(key) is Some(metadata) else { continue }
    guard cache_times.get(key) is Some(stored_at) && cache_fresh(stored_at, now) else {
      continue
    }
    let parts = Array::from_iter(key.split("|").map(StringView::to_owned))
    let (kind, registry) = if parts.length() >= 3 {
      (parts[0], parts[1])
    } else {
      ("mooncakes", "https://mooncakes.io")
    }
    let valid = if kind == "gha" {
      @taze.valid_gha_metadata(metadata, metadata.module_name)
    } else {
      @taze.valid_metadata(metadata, metadata.module_name)
    }
    if valid {
      entries.push(cache_entry_json(kind, registry, metadata, stored_at))
    }
  }
  let root : Map[String, Json] = Map([])
  root["schemaVersion"] = Json::number(2.0)
  root["entries"] = Json::array(entries)
  let temporary = path + ".tmp-\{@env.now()}-\{@async.now()}"
  let handle = @fs.open(
    temporary,
    mode=WriteOnly,
    create_mode=CreateNew,
    permission=0o600,
  ) catch {
    _ => {
      warn("cache_write_failed")
      return
    }
  }
  handle.close()
  defer @fs.remove(temporary, allow_missing=true)
  @fs.write_binary(
    temporary,
    @utf8.encode(Json::object(root).stringify()),
    create_mode=TruncateExisting,
  ) catch {
    _ => {
      warn("cache_write_failed")
      return
    }
  }
  @fs.rename(temporary, path, replace=true) catch {
    _ => warn("cache_write_failed")
  }
}
