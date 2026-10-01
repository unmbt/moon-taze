///|
/// A selection is bound to one live check plan; it cannot be deserialized.
pub struct Selection {
  priv identity : Ref[Int]
  priv items : Array[(String, String, String)]
}

///|
/// Select (manifest path, dependency name, target version) tuples.
/// Invalid selections are diagnosed by apply before any filesystem writes.
pub fn CheckPlan::selection(
  self : CheckPlan,
  items : Array[(String, String, String)],
) -> Selection {
  { identity: self.identity, items: items.copy(), }
}

///|
/// Select every recommended update; skipped and unchanged dependencies stay untouched.
pub fn CheckPlan::recommended_selection(self : CheckPlan) -> Selection {
  let items = []
  for change in self.entries {
    if change.status == UpdateAvailable && change.target is Some(target) {
      items.push((change.dependency.manifest, change.dependency.name, target))
    }
  }
  self.selection(items)
}

///|
pub(all) enum ApplyStatus {
  Succeeded
  Failed
  Partial
  Cancelled
} derive(Debug, Eq)

///|
pub(all) enum FileApplyStatus {
  Written
  Unchanged
  Failed
  NotAttempted
} derive(Debug, Eq)

///|
pub struct FileApplyResult {
  manifest : String
  status : FileApplyStatus
  changed_dependencies : Int
}

///|
/// Reports actual commits, including partial success. No implicit rollback occurs.
pub struct ApplyReport {
  status : ApplyStatus
  files : Array[FileApplyResult]
  diagnostics : Array[Diagnostic]
}

///|
pub fn ApplyReport::written_files(self : ApplyReport) -> Int {
  self.files.filter(f => f.status == Written).length()
}

///|
pub fn ApplyReport::exit_code(self : ApplyReport) -> Int {
  if self.status == Failed ||
    self.status == Partial ||
    has_error_diagnostics(self.diagnostics) {
    2
  } else {
    0
  }
}

///|
priv suberror WriteError {
  WriteError(String, String, String?)
}

///|
fn write_error(
  code : String,
  message : String,
  manifest? : String,
) -> Unit raise {
  raise WriteError(code, message, manifest)
}

///|
priv struct PreparedManifest {
  snapshot : Manifest
  output : Bytes
  count : Int
}

///|
fn prepare_patches(
  plan : CheckPlan,
  selection : Selection,
) -> Array[PreparedManifest] raise {
  if plan.has_errors() {
    write_error("check_failed", "a plan with errors cannot be applied")
  }
  if !physical_equal(plan.identity, selection.identity) {
    write_error(
      "invalid_selection", "selection belongs to a different check plan",
    )
  }
  let selected : Map[(String, String), String] = Map([])
  for (path, name, target) in selection.items {
    let key = (path, name)
    if selected.contains(key) {
      write_error(
        "invalid_selection",
        "duplicate dependency selection: \{name}",
      )
    }
    let change = plan.entries
      .iter()
      .find_first(c => {
        c.dependency.manifest == path && c.dependency.name == name
      })
    guard change is Some(change) else {
      write_error(
        "invalid_selection",
        "dependency does not belong to this plan: \{name}",
      )
      continue
    }
    if change.status != UpdateAvailable ||
      !change.candidates.contains(target) ||
      parse_version(target).compare(parse_version(change.dependency.version)) <=
      0 {
      write_error(
        "invalid_selection",
        "target is not a newer eligible candidate: \{name}@\{target}",
      )
    }
    selected[key] = target
  }
  let prepared = []
  for snapshot in plan.snapshots {
    let patches = snapshot.dependencies.filter(d => {
      selected.contains((d.manifest, d.name))
    })
    if patches.is_empty() {
      continue
    }
    patches.sort_by((a, b) => a.span.start.compare(b.span.start))
    let mut previous_end = 0
    for dep in patches {
      let span = dep.span
      if span.start < previous_end ||
        span.start < 0 ||
        span.end <= span.start ||
        span.end > snapshot.source.length() {
        write_error("invalid_selection", "invalid or overlapping version spans")
      }
      if snapshot.source[span.start:span.end] != @utf8.encode(dep.version)[:] {
        write_error(
          "invalid_selection", "version span does not match the checked source",
        )
      }
      previous_end = span.end
    }
    let mut output = snapshot.source
    for i = patches.length() - 1; i >= 0; i = i - 1 {
      let dep = patches[i]
      let bytes = Buffer()
      bytes.write_bytes(output[:dep.span.start])
      bytes.write_bytes(@utf8.encode(selected[(dep.manifest, dep.name)]))
      bytes.write_bytes(output[dep.span.end:])
      output = bytes.to_bytes()
    }
    let parsed = parse_manifest(
      output,
      path=snapshot.path,
      module_name=snapshot.module_name,
    )
    guard parsed.manifest is Some(updated) &&
      !has_error_diagnostics(parsed.diagnostics) else {
      write_error("invalid_selection", "patched manifest did not parse")
      continue
    }
    if updated.dependencies.length() != snapshot.dependencies.length() {
      write_error(
        "invalid_selection", "patched manifest changed the dependency set",
      )
    }
    for i, dep in snapshot.dependencies {
      let expected = selected
        .get((dep.manifest, dep.name))
        .unwrap_or(dep.version)
      let actual = updated.dependencies[i]
      if actual.name != dep.name ||
        actual.version != expected ||
        actual.module != dep.module {
        write_error(
          "invalid_selection", "patched manifest changed an unselected declaration",
        )
      }
    }
    prepared.push({ snapshot, output, count: patches.length(), })
  }
  if prepared.fold(init=0, (n, p) => n + p.count) != selected.length() {
    write_error("invalid_selection", "selection has no unique source snapshot")
  }
  prepared
}
