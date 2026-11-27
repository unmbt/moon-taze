///|
/// Kind of manifest file managed by `moon-taze`.
#derive(Eq, Debug)
pub(all) enum ManifestKind {
  MoonMod
  GitHubActions
}

///|
/// Source ecosystem of a dependency declaration.
#derive(Eq, Debug)
pub(all) enum DependencySource {
  Mooncakes
  GitHubActions
  LocalWorkspace
  Unsupported
}

///|
/// How GitHub Actions `uses:` references should be written on update.
#derive(Eq, Debug)
pub(all) enum GitHubActionStyle {
  Auto
  Tag
  Sha
}

///|
/// UTF-8 byte range and 1-based line/column position in the original source.
#derive(Eq, Debug)
pub(all) struct SourceSpan {
  start : Int32
  end : Int32
  line : Int32
  column : Int32
}

///|
/// GitHub Actions specific metadata extracted from a YAML `uses:` entry.
#derive(Eq, Debug)
pub struct GitHubActionRef {
  repo : String
  subpath : String
  style : GitHubActionStyle
  sha : String?
  value_span : SourceSpan
  quote : Char?
  comment_span : SourceSpan?
}

///|
/// A dependency declaration extracted from a manifest.
#derive(Eq, Debug)
pub struct Dependency {
  module_name : String
  manifest : String
  name : String
  version : String
  source : DependencySource
  span : SourceSpan
  gha : GitHubActionRef?
}

///|
/// A parsed manifest snapshot. `source` retains original UTF-8 bytes verbatim.
#derive(Eq, Debug)
pub struct Manifest {
  kind : ManifestKind
  module_name : String
  path : String
  source : Bytes
  dependencies : Array[Dependency]
}

///|
#derive(Eq, Debug)
pub struct ParseResult {
  manifest : Manifest?
  diagnostics : Array[Diagnostic]
}

///|
#derive(Eq, Debug)
pub(all) enum DiagnosticSeverity {
  Warning
  Error
}

///|
/// A stable, user-facing diagnostic.
#derive(Eq, Debug)
pub struct Diagnostic {
  severity : DiagnosticSeverity
  code : String
  message : String
  manifest : String?
  dependency : String?
  line : Int32?
  column : Int32?
}

///|
/// Construct a warning diagnostic for integrations that enrich a check plan.
pub fn warning_diagnostic(
  code : String,
  message : String,
  manifest : String?,
  dependency : String?,
  line : Int32?,
  column : Int32?,
) -> Diagnostic {
  warning(code, message, manifest, dependency, line, column)
}

///|
#derive(Eq, Debug)
pub(all) enum ChangeStatus {
  UpdateAvailable
  UpToDate
  NoCandidate
  Skipped
  Error
}

///|
#derive(Eq, Debug)
pub(all) enum DiffKind {
  Major
  Minor
  Patch
  Prerelease
  Pin
}

///|
/// Metadata for a single published version or GitHub Actions tag.
#derive(Eq, Debug)
pub struct VersionMetadata {
  version : String
  yanked : Bool
  yanked_reason : String?
  published_at : Int64?
  sha : String?
}

///|
/// Construct version metadata for an injected registry implementation.
pub fn VersionMetadata::VersionMetadata(
  version : String,
  yanked : Bool,
  yanked_reason : String?,
  published_at : Int64?,
  sha~ : String? = None,
) -> VersionMetadata {
  { version, yanked, yanked_reason, published_at, sha, }
}

///|
/// Metadata returned by a registry overview query (Mooncakes or GitHub).
#derive(Eq, Debug)
pub struct ModuleMetadata {
  module_name : String
  latest : String?
  versions : Array[VersionMetadata]
}

///|
/// Construct a module overview for an injected registry implementation.
pub fn ModuleMetadata::ModuleMetadata(
  module_name : String,
  latest : String?,
  versions : Array[VersionMetadata],
) -> ModuleMetadata {
  { module_name, latest, versions, }
}

///|
/// Result of resolving one dependency declaration.
#derive(Eq, Debug)
pub struct DependencyChange {
  dependency : Dependency
  mode : UpdateMode
  status : ChangeStatus
  target : String?
  target_sha : String?
  latest_available : String?
  candidates : Array[String]
  diff : DiffKind?
  reason : String?
  diagnostics : Array[Diagnostic]
}

///|
/// Pure selection policy used by `resolve`.
#derive(Eq, Debug)
pub struct Policy {
  mode : UpdateMode
  exclude : Array[String]
  maturity_days : Int32
  maturity_exclude : Array[String]
  gha_style : GitHubActionStyle
}

///|
pub fn Policy::Policy(
  mode : UpdateMode,
  exclude~ : Array[String] = [],
  maturity_days~ : Int32 = 0,
  maturity_exclude~ : Array[String] = [],
  gha_style~ : GitHubActionStyle = Auto,
) -> Policy {
  {
    mode,
    exclude: exclude.copy(),
    maturity_days: if maturity_days < 0 {
      0
    } else {
      maturity_days
    },
    maturity_exclude: maturity_exclude.copy(),
    gha_style,
  }
}

///|
/// Release-time policy used by `newest`/`next` and maturity-aware resolution.
#derive(Eq, Debug)
pub struct ReleaseOptions {
  now_ms : Int64
  maturity_days : Int32
  maturity_exclude : Array[String]
}

///|
pub fn ReleaseOptions::ReleaseOptions(
  now_ms : Int64,
  maturity_days : Int32,
  maturity_exclude~ : Array[String] = [],
) -> ReleaseOptions {
  {
    now_ms,
    maturity_days: if maturity_days < 0 {
      0
    } else {
      maturity_days
    },
    maturity_exclude: maturity_exclude.copy(),
  }
}

///|
/// Unified options for `check` and `check_manifests`.
pub struct CheckOptions {
  mode : UpdateMode
  include_selectors : Array[String]
  exclude_selectors : Array[String]
  local_modules : Array[String]
  release : ReleaseOptions
  gha_style : GitHubActionStyle
  cwd : String
  callbacks : Callbacks?
}

///|
pub fn CheckOptions::CheckOptions(
  mode~ : UpdateMode = Default,
  include_selectors~ : Array[String] = [],
  exclude_selectors~ : Array[String] = [],
  local_modules~ : Array[String] = [],
  release~ : ReleaseOptions = ReleaseOptions(0L, 0),
  gha_style~ : GitHubActionStyle = Auto,
  cwd~ : String = @env.current_dir().unwrap_or("."),
  callbacks~ : Callbacks? = None,
) -> CheckOptions {
  {
    mode,
    include_selectors: include_selectors.copy(),
    exclude_selectors: exclude_selectors.copy(),
    local_modules: local_modules.copy(),
    release,
    gha_style,
    cwd,
    callbacks,
  }
}

///|
/// Lifecycle callbacks. Returning a non-empty string converts the event into a
/// diagnostic and vetoes/marks the operation accordingly.
pub struct Callbacks {
  after_discovery : ((CheckPlan) -> String)?
  dependency_resolved : ((DependencyChange) -> String)?
  before_apply : ((Selection) -> String)?
  file_applied : ((FileApplyResult) -> String)?
  after_run : ((ApplyReport) -> String)?
}

///|
pub fn Callbacks::Callbacks(
  after_discovery~ : ((CheckPlan) -> String)? = None,
  dependency_resolved~ : ((DependencyChange) -> String)? = None,
  before_apply~ : ((Selection) -> String)? = None,
  file_applied~ : ((FileApplyResult) -> String)? = None,
  after_run~ : ((ApplyReport) -> String)? = None,
) -> Callbacks {
  {
    after_discovery,
    dependency_resolved,
    before_apply,
    file_applied,
    after_run,
  }
}

///|
/// A deterministic clock port for tests and time-aware consumers.
pub struct Clock {
  now_ms : () -> Int64
}

///|
pub fn Clock::Clock(now_ms : () -> Int64) -> Clock {
  { now_ms, }
}

///|
/// An in-memory check result. Selections belong strictly to one live `CheckPlan`.
pub struct CheckPlan {
  priv entries : Array[DependencyChange]
  priv issues : Array[Diagnostic]
  priv snapshots : Array[Manifest]
  priv identity : Ref[Int32]
  priv cwd : String
  priv gha_style : GitHubActionStyle
}

///|
/// A selection bound to one live `CheckPlan`.
pub struct Selection {
  priv identity : Ref[Int32]
  priv items : Array[(String, String, String)]
}

///|
pub fn CheckPlan::changes(self : CheckPlan) -> Array[DependencyChange] {
  self.entries.map(copy_change)
}

///|
pub fn CheckPlan::diagnostics(self : CheckPlan) -> Array[Diagnostic] {
  self.issues.copy()
}

///|
pub fn CheckPlan::has_errors(self : CheckPlan) -> Bool {
  has_error_diagnostics(self.issues) || self.entries.any(c => c.status == Error)
}

///|
/// Select `(manifest_path, dependency_name, target_version)` tuples.
/// Invalid selections are diagnosed by `apply` before any filesystem writes.
pub fn CheckPlan::selection(
  self : CheckPlan,
  items : Array[(String, String, String)],
) -> Selection {
  { identity: self.identity, items: items.copy(), }
}

///|
/// Select every recommended update; skipped and up-to-date entries stay untouched.
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
/// Return selected tuples as a detached copy for callback consumers.
pub fn Selection::items(self : Selection) -> Array[(String, String, String)] {
  self.items.copy()
}

///|
#derive(Eq, Debug)
pub(all) enum ApplyStatus {
  Succeeded
  Failed
  Partial
  Cancelled
}

///|
#derive(Eq, Debug)
pub(all) enum FileApplyStatus {
  Written
  Unchanged
  Failed
  NotAttempted
}

///|
#derive(Eq, Debug)
pub struct FileApplyResult {
  manifest : String
  status : FileApplyStatus
  changed_dependencies : Int32
}

///|
pub fn FileApplyResult::manifest(self : FileApplyResult) -> String {
  self.manifest
}

///|
pub fn FileApplyResult::status(self : FileApplyResult) -> FileApplyStatus {
  self.status
}

///|
pub fn FileApplyResult::changed_dependencies(self : FileApplyResult) -> Int32 {
  self.changed_dependencies
}

///|
/// Reports actual commits, including partial success. No implicit rollback occurs.
pub struct ApplyReport {
  status : ApplyStatus
  files : Array[FileApplyResult]
  diagnostics : Array[Diagnostic]
}

///|
pub fn ApplyReport::written_files(self : ApplyReport) -> Int32 {
  self.files.filter(f => f.status == Written).length()
}

///|
pub fn ApplyReport::exit_code(self : ApplyReport) -> Int32 {
  if self.status == Failed ||
    self.status == Partial ||
    has_error_diagnostics(self.diagnostics) {
    2
  } else {
    0
  }
}

///|
pub fn ApplyReport::files(self : ApplyReport) -> Array[FileApplyResult] {
  self.files.copy()
}

///|
pub fn ApplyReport::diagnostics(self : ApplyReport) -> Array[Diagnostic] {
  self.diagnostics.copy()
}

///|
pub fn ApplyReport::status(self : ApplyReport) -> ApplyStatus {
  self.status
}

///|
#derive(Debug)
pub suberror RegistryError {
  RequestFailed(String)
  InvalidMetadata(String)
}

///|
/// Construct a deterministic registry failure for tests and fake registries.
pub fn registry_request_failed(message : String) -> RegistryError {
  RequestFailed(message)
}

///|
#derive(Debug)
pub suberror ResolveError {
  InvalidMetadata(String)
}

///|
fn copy_change(change : DependencyChange) -> DependencyChange {
  {
    ..change,
    candidates: change.candidates.copy(),
    diagnostics: change.diagnostics.copy(),
  }
}

///|
fn make_plan(
  snapshots : Array[Manifest],
  changes : Array[DependencyChange],
  diagnostics : Array[Diagnostic],
  cwd~ : String = @env.current_dir().unwrap_or("."),
  gha_style~ : GitHubActionStyle = Auto,
) -> CheckPlan {
  {
    snapshots: snapshots.map(m => { ..m, dependencies: m.dependencies.copy(), }),
    entries: changes.map(copy_change),
    issues: diagnostics.copy(),
    identity: Ref(0),
    cwd,
    gha_style,
  }
}

///|
fn diagnostic(
  code : String,
  message : String,
  manifest : String?,
  dependency : String?,
  line : Int32?,
  column : Int32?,
) -> Diagnostic {
  { severity: Error, code, message, manifest, dependency, line, column, }
}

///|
fn warning(
  code : String,
  message : String,
  manifest : String?,
  dependency : String?,
  line : Int32?,
  column : Int32?,
) -> Diagnostic {
  { severity: Warning, code, message, manifest, dependency, line, column, }
}

///|
fn has_error_diagnostics(diagnostics : Array[Diagnostic]) -> Bool {
  diagnostics.any(item => item.severity == Error)
}

///|
fn dispatch_check_callbacks(
  plan : CheckPlan,
  callbacks : Callbacks?,
) -> CheckPlan {
  match callbacks {
    None => plan
    Some(callbacks) => {
      let issues = plan.issues.copy()
      let entries = plan.entries.map(copy_change)
      match callbacks.after_discovery {
        Some(callback) => {
          let message = callback(plan)
          if message != "" {
            issues.push(
              diagnostic("callback_failed", message, None, None, None, None),
            )
          }
        }
        None => ()
      }
      for i, change in entries {
        match callbacks.dependency_resolved {
          Some(callback) => {
            let message = callback(change)
            if message != "" {
              let diag = diagnostic(
                "callback_failed",
                message,
                Some(change.dependency.manifest),
                Some(change.dependency.name),
                Some(change.dependency.span.line),
                Some(change.dependency.span.column),
              )
              issues.push(diag)
              let nested = change.diagnostics.copy()
              nested.push(diag)
              entries[i] = { ..change, status: Error, diagnostics: nested, }
            }
          }
          None => ()
        }
      }
      { ..plan, entries, issues, }
    }
  }
}
