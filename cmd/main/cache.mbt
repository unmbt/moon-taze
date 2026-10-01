///|
priv struct DiskCacheVersion {
  version : String
  yanked : Bool
  yanked_reason : String
  published_at : Int64
} derive(FromJson)

///|
priv struct DiskCacheEntry {
  registry : String
  module : String
  latest : String
  versions : Array[DiskCacheVersion]
  storedAt : Int64
} derive(FromJson)

///|
priv struct DiskCacheFile {
  schemaVersion : Int
  entries : Array[DiskCacheEntry]
} derive(FromJson)

///|
const CACHE_TTL_MS : UInt64 = 1800000

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
            None =>
              match @env.get_env_var("USERPROFILE") {
                Some(value) => Some(value)
                None => None
              }
          }
      }
  }
  base.map(value => value + "/moon-taze/cache-v1.json")
}

///|
fn cache_key(registry : String, name : String) -> String {
  registry + "|overview|" + name
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
  registry? : String = "https://mooncakes.io",
  now? : UInt64 = @env.now(),
  warn? : (String) -> Unit = _ => (),
) -> Unit {
  match path {
    None => ()
    Some(path) => {
      if !@fs.exists(path) {
        return
      }
      let data = @fs.read_file(path) catch {
        _ => {
          warn("cache_read_failed")
          return
        }
      }
      let json = @json.parse(data.text()) catch {
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
      if file.schemaVersion != 1 {
        warn("cache_schema_unsupported")
        return
      }
      for entry in file.entries {
        if entry.registry == registry &&
          entry.storedAt >= 0 &&
          cache_fresh(entry.storedAt.reinterpret_as_uint64(), now) {
          let versions = entry.versions.map(item => {
            @taze.VersionMetadata(
              item.version,
              item.yanked,
              if item.yanked_reason == "" {
                None
              } else {
                Some(item.yanked_reason)
              },
              if item.published_at < 0 {
                None
              } else {
                Some(item.published_at)
              },
            )
          })
          let metadata = @taze.ModuleMetadata(
            entry.module,
            if entry.latest == "" {
              None
            } else {
              Some(entry.latest)
            },
            versions,
          )
          if !@taze.valid_metadata(metadata, entry.module) {
            warn("cache_invalid_metadata")
            continue
          }
          let key = cache_key(registry, entry.module)
          cache[key] = metadata
          cache_times[key] = entry.storedAt.reinterpret_as_uint64()
        }
      }
    }
  }
}

///|
fn cache_entry_json(
  registry : String,
  metadata : @taze.ModuleMetadata,
  stored_at : UInt64,
) -> Json {
  let object : Map[String, Json] = Map([])
  object["registry"] = json_text(registry)
  object["module"] = json_text(metadata.module)
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
  registry? : String = "https://mooncakes.io",
  now? : UInt64 = @env.now(),
  warn? : (String) -> Unit = _ => (),
) -> Unit {
  match path {
    None => ()
    Some(path) => {
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
      let modules : Array[String] = []
      for key in keys {
        let module_name = if key.has_prefix(registry + "|overview|") {
          key[registry.length() + 10:].to_owned()
        } else {
          key
        }
        if !modules.contains(module_name) {
          modules.push(module_name)
        }
      }
      modules.sort()
      let entries : Array[Json] = []
      for module_name in modules {
        let key = cache_key(registry, module_name)
        let metadata = match cache.get(key) {
          Some(value) => Some(value)
          None => cache.get(module_name)
        }
        let time_key = if cache_times.contains(key) { key } else { module_name }
        match metadata {
          Some(metadata) =>
            if cache_times.get(time_key) is Some(stored_at) &&
              cache_fresh(stored_at, now) &&
              @taze.valid_metadata(metadata, module_name) {
              entries.push(cache_entry_json(registry, metadata, stored_at))
            }
          None => ()
        }
      }
      let root : Map[String, Json] = Map([])
      root["schemaVersion"] = Json::number(1.0)
      root["entries"] = Json::array(entries)
      // Exclusive creation prevents concurrent writers from sharing a temporary file.
      let temporary = path + ".tmp-\{@env.now()}-\{@async.now()}"
      let handle = @fs.open(
        temporary,
        mode=@fs.Mode::WriteOnly,
        create_mode=@fs.CreateMode::CreateNew,
        permission=0o600,
      ) catch {
        _ => {
          warn("cache_write_failed")
          return
        }
      }
      handle.close()
      defer cleanup_cache_temp(temporary)
      @fs.write_file(
        temporary,
        @utf8.encode(Json::object(root).stringify()),
        create_mode=@fs.CreateMode::TruncateExisting,
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
  }
}

///|
async fn cleanup_cache_temp(path : String) -> Unit {
  @fs.remove(path) catch {
    _ => ()
  }
}
