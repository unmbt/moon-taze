# `unmbt/moon-taze`

> A fast, reliable, lossless dependency update tool for **MoonBit** (`moon.mod` / `moon.work`) and **GitHub Actions** (`.github/workflows/*.yml`, `action.yml`) — inspired by [taze](https://github.com/antfu-collective/taze).

**English** | [简体中文](README.zh-CN.md)

---

## Features

- **MoonBit & GitHub Actions in one pass** — checks `moon.mod` dependencies against [mooncakes.io](https://mooncakes.io) and GitHub Actions `uses:` references (`.github/workflows/*.{yml,yaml}`, `action.{yml,yaml}`) against the GitHub API.
- **Byte-for-byte lossless edits** — powered by [`unmbt/moon-manifest`](https://github.com/unmbt/moon-manifest) for `moon.mod` and a zero-dependency span-based YAML editor for GitHub Actions. Preserves BOM, CRLF/LF, comments, quotes, indentation, and untouched lines verbatim.
- **Atomic, crash-safe writes** — exclusive sidecar locks, stale-plan byte verification, permission/ACL preservation, and atomic same-directory replacement (no truncate-in-place fallback).
- **Rich update strategies** — `default`, `minor`, `patch`, `major`, `latest`, `stable`, `newest`, `next`, plus `--maturity-period` cooldowns, `--timediff`, release ages, and `--github-actions-style auto | tag | sha` (including SHA pinning).
- **Workspace & CI friendly** — understands `moon.work` local workspace members, `-r/--recursive` discovery, `moon-taze.json` static config, persistent TTL caching (`cache-v2.json`), `--json` machine-readable output, `--fail-on-outdated`, and `-w --verify` (`moon check`).
- **Built for MoonBit `v1.0.0-rc1`** — powered by `moonbitlang/core/async` and [`unmbt/cac`](https://github.com/unmbt/cac), with zero broken third-party dependencies.

> [!NOTE]
> Interactive TUI mode (`-I` / `--interactive`) is temporarily unavailable while terminal UI dependencies catch up to MoonBit `v1.0.0-rc1`. Passing `-I` or `--interactive` returns a `not_implemented` error (exit code `2`).

---

## Installation

### Via MoonBit (`moon install`)

```sh
moon install unmbt/moon-taze/cmd/moon-taze
moon-taze --help
moon-taze -V
```

Ensure `~/.moon/bin` is in your `PATH`.

### Prebuilt Native Binaries

```sh
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/unmbt/moon-taze/master/scripts/install.sh | bash

# Windows PowerShell
irm https://raw.githubusercontent.com/unmbt/moon-taze/master/scripts/install.ps1 | iex
```

---

## CLI Usage

```sh
# Preview compatible updates (read-only by default)
moon-taze

# Check major updates across a workspace or nested modules
moon-taze major -r --group

# Apply recommended updates and verify with `moon check`
moon-taze -w --verify

# Pin GitHub Actions references to commit SHAs with version comments
moon-taze --github-actions-style sha -w

# Disable GitHub Actions checks (MoonBit manifests only)
moon-taze --no-github-actions

# CI mode: JSON output + exit code 1 when updates are available
moon-taze --json --fail-on-outdated
```

### Options Reference

| Flag | Description |
| :--- | :--- |
| `[mode]` | `default` \| `major` \| `minor` \| `patch` \| `latest` \| `stable` \| `newest` \| `next` |
| `-C, --cwd <dir>` | Start discovery from `dir` |
| `-w, --write` | Apply recommended updates losslessly |
| `-a, --all` | Show up-to-date and skipped dependencies |
| `-r, --recursive` | Recursively discover nested `moon.mod` and GitHub Actions files |
| `-n, --include <deps>` | Only check matching comma-separated selectors (`scope/*`) |
| `-x, --exclude <deps>` | Skip matching selectors; supports version ranges (`foo/bar@1`) |
| `--no-github-actions` | Disable GitHub Actions workflow/action checks |
| `--github-actions-style <style>` | Write style for actions: `auto` (default) \| `tag` \| `sha` |
| `--sort <type>` | `name-asc` \| `name-desc` \| `diff-asc` \| `diff-desc` \| `time-asc` \| `time-desc` |
| `--group` | Group text output by manifest path |
| `--timediff` | Show release time difference between current and target versions |
| `--maturity-period [days]` | Ignore releases younger than `days` (bare flag defaults to `7`) |
| `--maturity-period-exclude <deps>` | Exempt selectors from maturity filtering |
| `--retry [times]` / `--no-retry` | Retry transient registry failures (default: `4`) |
| `-f, --force` | Bypass and refresh the 30-minute persistent cache |
| `--verify` | Run `moon check` after successful `moon.mod` writes (requires `-w`) |
| `--json` | Emit one machine-readable JSON v1 report |
| `--fail-on-outdated` | Exit with code `1` when updates are available |
| `-s, --silent` | Suppress text diagnostics |
| `-V, --version` | Print bare module version |

### Configuration (`moon-taze.json`)

Place an optional `moon-taze.json` at your project or workspace root (CLI flags always take precedence):

```json
{
  "mode": "minor",
  "recursive": false,
  "exclude": ["legacy/*"],
  "maturityPeriod": 3,
  "githubActions": {
    "style": "auto"
  }
}
```

For GitHub Actions API requests, `moon-taze` automatically reads `GITHUB_TOKEN`, `GH_TOKEN`, or falls back to `gh auth token` when available to avoid anonymous rate limits.

---

## Library Usage

Add `unmbt/moon-taze` to your MoonBit project to embed offline-testable dependency checking and lossless updates:

### Pure SemVer & GitHub Actions Resolution

```mbt check
///|
test "resolve MoonBit and GitHub Actions versions" {
  // SemVer 2.0.0 strategy selection
  let next = @moon-taze.choose_version(
    "0.2.3",
    ["0.2.3", "0.2.9", "0.3.0", "1.0.0"],
    mode=Default,
  )
  assert_eq(next, Some("0.2.9"))

  // GitHub Actions tag granularity preservation
  let action_next = @moon-taze.select_action_target(
    "v4",
    ["v4", "v4.2.0", "v5", "v5.0.0"],
    Major,
  )
  assert_eq(action_next.map(t => t.tag), Some("v5"))
}
```

### Offline Check Plan & Selection

```mbt check
///|
async test "check manifest with an injected registry" {
  let manifest = @moon-taze.parse_manifest(
    b"name = \"acme/app\"\nimport { \"acme/lib@1.0.0\" }\n",
    path="moon.mod",
    module_name="acme/app",
  ).manifest.unwrap()

  let plan = @moon-taze.check(
    manifest,
    options=@moon-taze.CheckOptions(mode=Minor),
    fetch=name => {
      @moon-taze.ModuleMetadata(name, Some("1.2.0"), [
        @moon-taze.VersionMetadata("1.0.0", false, None, None),
        @moon-taze.VersionMetadata("1.2.0", false, None, None),
      ])
    },
  )

  assert_false(plan.has_errors())
  assert_eq(plan.changes()[0].target, Some("1.2.0"))
  assert_eq(plan.recommended_selection().items(), [
    ("moon.mod", "acme/lib", "1.2.0"),
  ])
}
```

---

## Architecture & Development

See [docs/DESIGN.md](docs/DESIGN.md) for the complete architecture diagram, manifest/registry contracts, and atomic write invariants.

```sh
moon check --target native
moon test --target native
moon build --target native
moon run --target native tools/cli_smoke.mbtx
moon run --target native tools/release_check.mbtx
```

## License

[MIT](LICENSE)
