///|
priv struct OwnedFile {
  path : String
  identity : Bytes
}

///|
// Internal IO boundary; production CLI and fault-injection tests use this engine.
priv struct WriteServices {
  normalize : async (String) -> String
  inspect : async (String) -> Unit
  read : async (String) -> Bytes
  create : async (String) -> OwnedFile
  write_lock : async (OwnedFile, Bytes) -> Unit
  stage : async (String, OwnedFile, Bytes) -> Unit
  replace : async (OwnedFile, String) -> Unit
  cleanup : async (OwnedFile) -> Unit
  before_commit : async () -> Unit
  cancelled : () -> Bool
  run_id : String
}

///|
priv struct PendingWrite {
  path : String
  patch : PreparedManifest
  mut temporary : OwnedFile?
}

///|
// Resolve relative paths against the check's cwd, even if the host changes cwd later.
fn checked_path(path : String, cwd : String) -> String raise {
  if path.length() >= 2 && path[1] == ':' {
    if path.length() < 3 || (path[2] != '/' && path[2] != '\\') {
      write_error(
        "unsafe_write_target",
        "drive-relative manifest paths are ambiguous: \{path}",
      )
    }
    return path
  }
  if path.has_prefix("\\\\") || path.has_prefix("//") {
    return path
  }
  if path.has_prefix("/") || path.has_prefix("\\") {
    if cwd.length() >= 2 && cwd[1] == ':' {
      return cwd[:2].to_owned() + path
    }
    if cwd.has_prefix("\\\\") {
      write_error(
        "unsafe_write_target",
        "use a fully qualified UNC manifest path: \{path}",
      )
    }
    return path
  }
  cwd + "/" + path
}

///|
async fn verify_snapshots(
  snapshots : Array[(String, Bytes)],
  services : WriteServices,
) -> Unit {
  for (path, expected) in snapshots {
    let actual = (services.read)(path) catch {
      error => {
        if @async.is_cancellation_error(error) {
          raise error
        }
        write_error(
          "stale_plan",
          "cannot reread checked manifest: \{path}",
          manifest=path,
        )
        b""
      }
    }
    if actual != expected {
      write_error(
        "stale_plan",
        "manifest changed since check: \{path}",
        manifest=path,
      )
    }
  }
}

///|
async fn apply_with_services(
  plan : CheckPlan,
  selection : Selection,
  services : WriteServices,
  callbacks : Callbacks?,
) -> ApplyReport {
  let files : Array[FileApplyResult] = []
  let diagnostics : Array[Diagnostic] = []
  let owned : Array[OwnedFile] = []
  let pending : Array[PendingWrite] = []
  let mut active : String? = None
  let mut was_cancelled = false
  let mut failed = false
  try {
    let patches = prepare_patches(plan, selection)
    match callbacks {
      Some(callbacks) =>
        match callbacks.before_apply {
          Some(callback) => {
            let message = callback(selection)
            if message != "" {
              write_error("callback_denied", message)
            }
          }
          None => ()
        }
      None => ()
    }
    if patches.is_empty() {
      let report = {
        status: Succeeded,
        files: plan.snapshots.map(snapshot => {
          manifest: snapshot.path,
          status: Unchanged,
          changed_dependencies: 0,
        }),
        diagnostics: [],
      }
      return dispatch_after_run(report, callbacks)
    }
    let snapshots : Array[(String, Bytes)] = []
    let seen : Map[String, Unit] = Map([])
    for snapshot in plan.snapshots {
      files.push({
        manifest: snapshot.path,
        status: if patches.any(p => p.snapshot.path == snapshot.path) {
          NotAttempted
        } else {
          Unchanged
        },
        changed_dependencies: 0,
      })
    }
    for i, snapshot in plan.snapshots {
      active = Some(snapshot.path)
      let input_path = checked_path(snapshot.path, plan.cwd)
      // Inspect the original leaf before realpath can follow a symlink.
      if patches.any(p => p.snapshot.path == snapshot.path) {
        (services.inspect)(input_path)
      }
      let path = (services.normalize)(input_path)
      files[i] = { ..files[i], manifest: path, }
      active = Some(path)
      if seen.contains(path) {
        write_error(
          "invalid_selection",
          "duplicate normalized manifest path: \{path}",
        )
      }
      seen[path] = ()
      snapshots.push((path, snapshot.source))
      match patches.iter().find_first(p => p.snapshot.path == snapshot.path) {
        Some(patch) => pending.push({ path, patch, temporary: None, })
        None => ()
      }
    }
    pending.sort_by((a, b) => a.path.compare(b.path))
    // Every ownership acquisition is shielded through registration for cleanup.
    for item in pending {
      active = Some(item.path)
      if (services.cancelled)() {
        was_cancelled = true
        break
      }
      @async.protect_from_cancel(() => {
        let lock = (services.create)(item.path + ".moon-taze.lock")
        owned.push(lock)
        (services.write_lock)(
          lock,
          @utf8.encode("moon-taze-p1b " + services.run_id + "\n"),
        )
      })
    }
    if !was_cancelled {
      verify_snapshots(snapshots, services)
      for item in pending {
        active = Some(item.path)
        if (services.cancelled)() {
          was_cancelled = true
          break
        }
        @async.protect_from_cancel(() => {
          let temporary = (services.create)(
            item.path + ".moon-taze." + services.run_id + ".tmp",
          )
          owned.push(temporary)
          item.temporary = Some(temporary)
        })
        (services.stage)(item.path, item.temporary.unwrap(), item.patch.output)
      }
    }
    was_cancelled = was_cancelled || (services.cancelled)()
    if !was_cancelled {
      (services.before_commit)()
      verify_snapshots(snapshots, services)
      for item in pending {
        active = Some(item.path)
        if (services.cancelled)() {
          was_cancelled = true
          break
        }
        (services.inspect)(item.path)
        verify_snapshots([(item.path, item.patch.snapshot.source)], services)
        // Commit and its accounting are one cancellation-protected operation.
        @async.protect_from_cancel(() => {
          (services.replace)(item.temporary.unwrap(), item.path)
          for i, file in files {
            if file.manifest == item.path {
              files[i] = {
                manifest: item.path,
                status: Written,
                changed_dependencies: item.patch.count,
              }
            }
          }
        })
        match callbacks {
          Some(callbacks) =>
            match callbacks.file_applied {
              Some(callback) =>
                match
                  files.iter().find_first(file => file.manifest == item.path) {
                  Some(file) => {
                    let message = callback(file)
                    if message != "" {
                      write_error("callback_failed", message)
                    }
                  }
                  None => ()
                }
              None => ()
            }
          None => ()
        }
      }
    }
  } catch {
    error =>
      if @async.is_cancellation_error(error) {
        was_cancelled = true
      } else {
        failed = true
        let (code, message, path) = match error {
          WriteError(code, message, path) => (code, message, path)
          _ => ("write_failed", error.to_string(), None)
        }
        if path is Some(_) {
          active = path
        }
        diagnostics.push(diagnostic(code, message, active, None, None, None))
        if active is Some(path) {
          let mut recorded = false
          for i, file in files {
            if file.manifest == path {
              recorded = true
              if file.status != Written {
                files[i] = { ..file, status: Failed, }
              }
            }
          }
          if !recorded {
            files.push({
              manifest: path,
              status: Failed,
              changed_dependencies: 0,
            })
          }
        }
      }
  }
  // Cleanup must run even when the parent task is already cancelled.
  @async.protect_from_cancel(() => {
    for i = owned.length() - 1; i >= 0; i = i - 1 {
      (services.cleanup)(owned[i]) catch {
        error => {
          failed = true
          diagnostics.push(
            diagnostic(
              "write_failed",
              "cleanup failed: \{error}",
              Some(owned[i].path),
              None,
              None,
              None,
            ),
          )
        }
      }
    }
  })
  was_cancelled = was_cancelled || (services.cancelled)()
  let written = files.any(f => f.status == Written)
  let status = if failed || was_cancelled {
    if written {
      Partial
    } else if failed {
      Failed
    } else {
      Cancelled
    }
  } else {
    Succeeded
  }
  files.sort_by((a, b) => a.manifest.compare(b.manifest))
  dispatch_after_run({ status, files, diagnostics, }, callbacks)
}

///|
fn dispatch_after_run(
  report : ApplyReport,
  callbacks : Callbacks?,
) -> ApplyReport {
  match callbacks {
    Some(callbacks) =>
      match callbacks.after_run {
        Some(callback) => {
          let message = callback(report)
          if message == "" {
            report
          } else {
            let diagnostics = report.diagnostics.copy()
            diagnostics.push(
              diagnostic("callback_failed", message, None, None, None, None),
            )
            let status = if report.written_files() > 0 {
              ApplyStatus::Partial
            } else {
              ApplyStatus::Failed
            }
            { ..report, status, diagnostics, }
          }
        }
        None => report
      }
    None => report
  }
}

///|
/// Apply a live plan using the Native writer. Failures retain all commit results.
///
/// An empty valid selection succeeds without filesystem writes:
/// ```mbt check
/// async test {
///   let manifest = @moon-taze.parse_manifest(
///     b"name = \"demo/app\"",
///     path="moon.mod",
///     module_name="demo/app",
///   ).manifest.unwrap()
///   let plan = @moon-taze.check_manifest(manifest, mode=Patch, fetch=name => {
///     @moon-taze.ModuleMetadata(name, None, [])
///   })
///   let report = @moon-taze.apply(plan, plan.recommended_selection())
///   assert_eq(report.written_files(), 0)
///   assert_eq(report.exit_code(), 0)
/// }
/// ```
pub async fn apply(
  plan : CheckPlan,
  selection : Selection,
  callbacks? : Callbacks? = None,
) -> ApplyReport {
  apply_with_services(plan, selection, native_write_services(), callbacks)
}
