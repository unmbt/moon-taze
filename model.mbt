///|
/// Source of a dependency reference.
pub enum DependencySource {
  Registry
  LocalWorkspace
  Unsupported
} derive(Debug, Eq)

///|
/// UTF-8 source position and byte range.
pub struct SourceSpan {
  pub start : Int
  pub end : Int
  pub line : Int
  pub column : Int
} derive(Debug, Eq)

///|
/// A dependency declaration extracted from a manifest.
pub struct Dependency {
  pub module : String
  pub manifest : String
  pub name : String
  pub version : String
  pub source : DependencySource
  pub span : SourceSpan
} derive(Debug, Eq)

///|
pub enum DiagnosticSeverity {
  Warning
  Error
} derive(Debug, Eq)

///|
/// A stable, user-facing diagnostic.
pub struct Diagnostic {
  pub severity : DiagnosticSeverity
  pub code : String
  pub message : String
  pub manifest : String?
  pub dependency : String?
  pub line : Int?
  pub column : Int?
} derive(Debug, Eq)

///|
/// Construct a warning for integrations that enrich a check result with
/// presentation-time information such as optional release timestamps.
pub fn warning_diagnostic(
  code : String,
  message : String,
  manifest : String?,
  dependency : String?,
  line : Int?,
  column : Int?,
) -> Diagnostic {
  warning(code, message, manifest, dependency, line, column)
}

///|
pub enum ChangeStatus {
  UpdateAvailable
  UpToDate
  NoCandidate
  Skipped
  Error
} derive(Debug, Eq)

///|
pub enum DiffKind {
  Major
  Minor
  Patch
  Prerelease
} derive(Debug, Eq)

///|
/// Metadata returned by a Registry overview request.
pub struct VersionMetadata {
  pub version : String
  pub yanked : Bool
  pub yanked_reason : String?
  pub published_at : Int64?
} derive(Debug, Eq)

///|
pub struct ModuleMetadata {
  pub module : String
  pub latest : String?
  pub versions : Array[VersionMetadata]
} derive(Debug, Eq)

///|
/// Construct registry metadata for an injected registry implementation.
pub fn VersionMetadata::VersionMetadata(
  version : String,
  yanked : Bool,
  yanked_reason : String?,
  published_at : Int64?,
) -> VersionMetadata {
  { version, yanked, yanked_reason, published_at, }
}

///|
/// Construct a module overview for an injected registry implementation.
pub fn ModuleMetadata::ModuleMetadata(
  module : String,
  latest : String?,
  versions : Array[VersionMetadata],
) -> ModuleMetadata {
  { module, latest, versions, }
}

///|
/// The result of resolving one dependency.
pub struct DependencyChange {
  pub dependency : Dependency
  pub mode : UpdateMode
  pub status : ChangeStatus
  pub target : String?
  pub candidates : Array[String]
  pub diff : DiffKind?
  pub reason : String?
  pub diagnostics : Array[Diagnostic]
} derive(Debug, Eq)

///|
/// An in-memory check result. Use the accessors; selections belong to this plan.
pub struct CheckPlan {
  priv entries : Array[DependencyChange]
  priv issues : Array[Diagnostic]
  priv snapshots : Array[Manifest]
  priv identity : Ref[Int]
  priv cwd : String
}

///|
/// Policy used by the pure `resolve` entry point.  It contains only selection
/// rules; registry access and filesystem effects stay outside the policy.
pub struct Policy {
  pub mode : UpdateMode
  pub exclude : Array[String]
  pub maturity_days : Int
  pub maturity_exclude : Array[String]
} derive(Debug, Eq)

///|
pub fn Policy::Policy(
  mode : UpdateMode,
  exclude? : Array[String] = [],
  maturity_days? : Int = 0,
  maturity_exclude? : Array[String] = [],
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
  }
}

///|
/// A callback returns an empty string when the event is accepted. Any
/// non-empty string becomes a stable callback diagnostic.
pub struct Callbacks {
  pub after_discovery : ((CheckPlan) -> String)?
  pub dependency_resolved : ((DependencyChange) -> String)?
  pub before_apply : ((Selection) -> String)?
  pub file_applied : ((FileApplyResult) -> String)?
  pub after_run : ((ApplyReport) -> String)?
}

///|
/// Construct an empty callback set.  Callers can fill only the events they
/// need while preserving a single check/resolve/apply lifecycle contract.
pub fn Callbacks::Callbacks(
  after_discovery? : ((CheckPlan) -> String)? = None,
  dependency_resolved? : ((DependencyChange) -> String)? = None,
  before_apply? : ((Selection) -> String)? = None,
  file_applied? : ((FileApplyResult) -> String)? = None,
  after_run? : ((ApplyReport) -> String)? = None,
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
  cwd? : String = @env.current_dir().unwrap_or("."),
) -> CheckPlan {
  {
    snapshots: snapshots.map(m => { ..m, dependencies: m.dependencies.copy(), }),
    entries: changes.map(copy_change),
    issues: diagnostics.copy(),
    identity: Ref(0),
    cwd,
  }
}

///|
/// Return a detached copy, including nested candidate and diagnostic arrays.
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
/// Return the selected tuples as a detached array for callback consumers.
pub fn Selection::items(self : Selection) -> Array[(String, String, String)] {
  self.items.copy()
}

///|
/// A clock port reserved for time-aware strategies introduced after P1a.
pub struct Clock {
  pub now_ms : () -> Int64
}

///|
/// Construct a deterministic clock port for tests or future strategies.
pub fn Clock::Clock(now_ms : () -> Int64) -> Clock {
  { now_ms, }
}

///|
/// Release-time policy used by newest/next and maturity-aware resolution.
pub struct ReleaseOptions {
  pub now_ms : Int64
  pub maturity_days : Int
  pub maturity_exclude : Array[String]
} derive(Debug, Eq)

///|
/// Construct deterministic release-time options for tests and callers.
pub fn ReleaseOptions::ReleaseOptions(
  now_ms : Int64,
  maturity_days : Int,
  maturity_exclude? : Array[String] = [],
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
fn diagnostic(
  code : String,
  message : String,
  manifest : String?,
  dependency : String?,
  line : Int?,
  column : Int?,
) -> Diagnostic {
  {
    severity: DiagnosticSeverity::Error,
    code,
    message,
    manifest,
    dependency,
    line,
    column,
  }
}

///|
fn warning(
  code : String,
  message : String,
  manifest : String?,
  dependency : String?,
  line : Int?,
  column : Int?,
) -> Diagnostic {
  {
    severity: DiagnosticSeverity::Warning,
    code,
    message,
    manifest,
    dependency,
    line,
    column,
  }
}

///|
/// Dispatch check-side callbacks in a fixed order.  Callback failures become
/// plan diagnostics, so a consumer cannot accidentally apply a vetoed plan.
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
              issues.push(
                diagnostic(
                  "callback_failed",
                  message,
                  Some(change.dependency.manifest),
                  Some(change.dependency.name),
                  Some(change.dependency.span.line),
                  Some(change.dependency.span.column),
                ),
              )
              let nested = change.diagnostics.copy()
              nested.push(
                diagnostic(
                  "callback_failed",
                  message,
                  Some(change.dependency.manifest),
                  Some(change.dependency.name),
                  Some(change.dependency.span.line),
                  Some(change.dependency.span.column),
                ),
              )
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
