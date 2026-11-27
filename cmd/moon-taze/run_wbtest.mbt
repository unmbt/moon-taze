///|
async test "CLI interactive flag requires TTY in text mode and is ignored in JSON mode" {
  let root = @fs.tmpdir(prefix="moon-taze-cli-interactive")
  defer @fs.remove(root, recursive=true)
  @fs.write_binary(root + "/moon.mod", b"name = \"demo/app\"\n")
  let text_out : Array[String] = []
  let text_code = run_cli(
    ["moon-taze", "-I", "-C", root],
    fetch=name => @taze.ModuleMetadata(name, None, []),
    emit=line => text_out.push(line),
    interactive_tty=Some(false),
    color=Some(false),
  )
  assert_eq(text_code, 2)
  assert_true(text_out.any(line => line.contains("not_interactive")))

  let json_out : Array[String] = []
  let json_code = run_cli(
    ["moon-taze", "--interactive", "--json", "-C", root],
    fetch=name => @taze.ModuleMetadata(name, None, []),
    emit=line => json_out.push(line),
  )
  assert_eq(json_code, 0)
  assert_eq(json_out.length(), 1)
  assert_true(json_out[0].contains("\"status\":\"ok\""))
}

///|
async test "CLI interactive TUI supports per-dep version picker, NoCandidate opt-in, GHA SHA lookup, on-demand ages, and confirms" {
  let root = @fs.tmpdir(prefix="moon-taze-cli-tui-e2e")
  defer @fs.remove(root, recursive=true)
  @fs.mkdir(root + "/.github/workflows", recursive=true)
  let mod_path = root + "/moon.mod"
  let ci_path = root + "/.github/workflows/ci.yml"
  @fs.write_binary(
    mod_path, b"name = \"acme/app\"\nimport {\n  \"acme/minor-lib@1.0.0\",\n  \"acme/major-only@1.0.0\",\n  \"acme/patch-lib@0.2.1\",\n}\n",
  )
  @fs.write_binary(
    ci_path, b"jobs:\n  build:\n    steps:\n      - uses: actions/checkout@v4.1.0\n",
  )
  let now = 1000000000000L
  let day = 86400000L
  let sha_v420 = "4444444444444444444444444444444444444444"
  let sha_v500 = "5555555555555555555555555555555555555555"
  let verified_dirs : Array[String] = []

  // Initial diff-asc order in `acme/app` (import):
  //   0: acme/major-only (Major 2.1.0, unchecked NoCandidate)
  //   1: acme/minor-lib  (Minor 1.2.0, checked)
  //   2: acme/patch-lib  (Patch 0.2.3, checked)
  // Plus `.github/workflows/ci.yml` (github-actions):
  //   3: actions/checkout (Minor v4.2.0, checked)
  //
  // Key sequence:
  // - On cursor 0 (acme/major-only): Right -> choices [latest=2.1.0, major=2.0.0] -> Down (2.0.0) -> Enter (opts in & sets 2.0.0)
  // - Down to cursor 1 (acme/minor-lib): Right -> choices [minor=1.2.0, latest=2.0.0, minor=1.1.0] -> Down -> Down (1.1.0) -> Enter
  // - Down to cursor 2 (acme/patch-lib): Space (unchecks acme/patch-lib)
  // - Down to cursor 3 (actions/checkout): Right -> choices [minor=v4.2.0, major=v5.0.0] -> Down (v5.0.0) -> Enter
  // - Enter to confirm list
  // - 'y' on "write to moon.mod and GitHub Actions?"
  // - 'y' on "run moon check now?"
  let vt = @clack_term.VirtualTerminal(
    [
      b"\x1b[C", b"\x1b[B", b"\r", b"\x1b[B", b"\x1b[C", b"\x1b[B", b"\x1b[B", b"\r",
      b"\x1b[B", b" ", b"\x1b[B", b"\x1b[C", b"\x1b[B", b"\r", b"\r", b"y", b"y",
    ],
    cols=100,
    rows=30,
    tty=true,
  )
  let session = @clack_prompts.Session(term=vt, color_level=None)
  let output : Array[String] = []
  let code = run_cli(
    ["moon-taze", "-I", "--github-actions-style", "sha", "-C", root],
    fetch=name => {
      if name == "acme/minor-lib" {
        @taze.ModuleMetadata(name, Some("2.0.0"), [
          @taze.VersionMetadata("1.0.0", false, None, None),
          @taze.VersionMetadata("1.1.0", false, None, None),
          @taze.VersionMetadata("1.2.0", false, None, None),
          @taze.VersionMetadata("2.0.0", false, None, None),
        ])
      } else if name == "acme/major-only" {
        @taze.ModuleMetadata(name, Some("2.1.0"), [
          @taze.VersionMetadata("1.0.0", false, None, None),
          @taze.VersionMetadata("2.0.0", false, None, None),
          @taze.VersionMetadata("2.1.0", false, None, None),
        ])
      } else {
        @taze.ModuleMetadata(name, Some("0.2.3"), [
          @taze.VersionMetadata("0.2.1", false, None, None),
          @taze.VersionMetadata("0.2.3", false, None, None),
        ])
      }
    },
    fetch_version=(_, version) => {
      let age = if version == "1.0.0" || version == "0.2.1" {
        30L * day
      } else if version == "1.1.0" {
        12L * day
      } else {
        5L * day
      }
      Some(@taze.VersionMetadata(version, false, None, Some(now - age)))
    },
    fetch_gha=repo => {
      @taze.ModuleMetadata(repo, Some("v5.0.0"), [
        @taze.VersionMetadata("v4.1.0", false, None, None, sha=Some(sha_v420)),
        @taze.VersionMetadata("v4.2.0", false, None, None, sha=Some(sha_v420)),
        @taze.VersionMetadata("v5.0.0", false, None, None, sha=Some(sha_v500)),
      ])
    },
    fetch_gha_commit_date=(_, sha) => {
      if sha == sha_v500 {
        Some(now - 3L * day)
      } else {
        Some(now - 10L * day)
      }
    },
    emit=line => output.push(line),
    color=Some(false),
    now_ms=Some(now),
    session=Some(session),
    run_verify=Some((dir, _) => {
      verified_dirs.push(dir)
      { path: dir, passed: true, exit_code: 0, }
    }),
  )
  assert_eq(code, 0)
  assert_false(vt.in_raw_mode())

  // Verify TUI frames rendered list header, version picker header, and live age progress bar.
  let term_out = vt.all_output()
  assert_true(term_out.contains("to change version"))
  assert_true(term_out.contains("Select a version for acme/minor-lib"))
  assert_true(term_out.contains("age "))

  // Verify written files reflect exact per-dependency selections and SHAs.
  let mod_text = @fs.read_text(mod_path)
  assert_true(mod_text.contains("acme/minor-lib@1.1.0"))
  assert_true(mod_text.contains("acme/major-only@2.0.0"))
  assert_true(mod_text.contains("acme/patch-lib@0.2.1"))
  let ci_text = @fs.read_text(ci_path)
  assert_true(ci_text.contains("actions/checkout@\{sha_v500} # v5.0.0"))
  assert_false(ci_text.contains(sha_v420))

  // Verify `moon check` confirmation executed.
  assert_eq(verified_dirs.length(), 1)
}

///|
async test "CLI interactive cancel and write decline leave manifests untouched" {
  let root = @fs.tmpdir(prefix="moon-taze-cli-tui-cancel")
  defer @fs.remove(root, recursive=true)
  let mod_path = root + "/moon.mod"
  let original = b"name = \"acme/app\"\nimport { \"acme/lib@1.0.0\" }\n"
  @fs.write_binary(mod_path, original)
  let fetch : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError = name => {
    @taze.ModuleMetadata(name, Some("1.2.0"), [
      @taze.VersionMetadata("1.0.0", false, None, None),
      @taze.VersionMetadata("1.2.0", false, None, None),
    ])
  }

  // 1. Pressing 'q' cancels cleanly without writing.
  let vt_cancel = @clack_term.VirtualTerminal(
    [b"q"],
    cols=80,
    rows=20,
    tty=true,
  )
  let cancel_code = run_cli(
    ["moon-taze", "-I", "-C", root],
    fetch~,
    emit=_ => (),
    color=Some(false),
    session=Some(@clack_prompts.Session(term=vt_cancel, color_level=None)),
  )
  assert_eq(cancel_code, 0)
  assert_eq(@fs.read_binary(mod_path), original)

  // 2. Confirming selection then declining write ('n') prints tip and leaves disk untouched.
  let vt_no = @clack_term.VirtualTerminal(
    [b"\r", b"n"],
    cols=80,
    rows=20,
    tty=true,
  )
  let no_out : Array[String] = []
  let no_code = run_cli(
    ["moon-taze", "-I", "-C", root],
    fetch~,
    emit=line => no_out.push(line),
    color=Some(false),
    session=Some(@clack_prompts.Session(term=vt_no, color_level=None)),
  )
  assert_eq(no_code, 0)
  assert_eq(@fs.read_binary(mod_path), original)
  assert_true(no_out.any(line => line.contains("Add -w to write to moon.mod")))
}

///|
async fn wait_until(cond : () -> Bool, timeout_ms~ : Int32 = 5000) -> Bool {
  let mut elapsed = 0
  while !cond() && elapsed < timeout_ms {
    @async.sleep(5)
    elapsed += 5
  }
  cond()
}

///|
async test "CLI interactive version picker renders immediately with progress bar, updates live, and stays non-blocking" {
  let root = @fs.tmpdir(prefix="moon-taze-cli-tui-nonblocking")
  defer @fs.remove(root, recursive=true)
  let mod_path = root + "/moon.mod"
  @fs.write_binary(
    mod_path, b"name = \"acme/app\"\nimport { \"acme/lib@1.0.0\" }\n",
  )
  let frames : Array[String] = []
  let fetched : Array[String] = []
  let gate_110 = @async.Semaphore(1)
  let gate_200 = @async.Semaphore(1)
  gate_110.acquire()
  gate_200.acquire()
  let ct = @clack_term.CallbackTerminal(
    on_write=chunk => frames.push(chunk.to_owned()),
    cols=100,
    rows=24,
    tty=true,
  )
  let session = @clack_prompts.Session(term=ct, color_level=None)
  let now = 1000000000000L
  let day = 86400000L
  let code_ref : Ref[Int32] = Ref(-1)
  @async.with_task_group(group => {
    group.spawn_bg(async fn() {
      code_ref.val = run_cli(
        ["moon-taze", "-I", "-C", root],
        fetch=name => {
          @taze.ModuleMetadata(name, Some("2.0.0"), [
            @taze.VersionMetadata("1.0.0", false, None, None),
            @taze.VersionMetadata("1.1.0", false, None, None),
            @taze.VersionMetadata("1.2.0", false, None, None),
            @taze.VersionMetadata("2.0.0", false, None, None),
          ])
        },
        fetch_version=(name, version) => {
          fetched.push(name + "@" + version)
          if version == "1.1.0" {
            gate_110.acquire()
            Some(
              @taze.VersionMetadata(version, false, None, Some(now - 12L * day)),
            )
          } else if version == "2.0.0" {
            gate_200.acquire()
            Some(
              @taze.VersionMetadata(version, false, None, Some(now - 3L * day)),
            )
          } else {
            Some(
              @taze.VersionMetadata(version, false, None, Some(now - 30L * day)),
            )
          }
        },
        emit=_ => (),
        color=Some(false),
        now_ms=Some(now),
        session=Some(session),
      )
    })
    // Deterministically wait for the initial list view before sending Right.
    assert_true(wait_until(() => frames.join("").contains("to change version")))
    ct.push_input(b"\x1b[C")
    // Both 1.1.0 and 2.0.0 are blocked on semaphores, yet version picker + 0/2 progress bar MUST render immediately.
    assert_true(
      wait_until(() => {
        let s = frames.join("")
        s.contains("Select a version for acme/lib") &&
        s.contains("age ") &&
        s.contains("0/2")
      }),
    )
    // Release only 1.1.0: picker must live-redraw 1/2 + ~12d while 2.0.0 stays blocked.
    gate_110.release()
    assert_true(
      wait_until(() => {
        let s = frames.join("")
        s.contains("1/2") && s.contains("~12d")
      }),
    )
    assert_true(fetched.contains("acme/lib@1.1.0"))
    // While 2.0.0 is STILL blocked, user can move down to 2.0.0 and confirm immediately.
    ct.push_input(b"\x1b[B")
    ct.push_input(b"\r")
    ct.push_input(b"\r")
    ct.push_input(b"y")
    ct.push_input(b"n")
  })
  assert_eq(code_ref.val, 0)
  assert_false(ct.in_raw_mode())
  assert_true(@fs.read_text(mod_path).contains("acme/lib@2.0.0"))
}

///|
async test "CLI 1:1 taze text output renders grouped packages, available hint, up-to-date summary, and footer tips" {
  let root = @fs.tmpdir(prefix="moon-taze-cli-taze-ui")
  defer @fs.remove(root, recursive=true)
  @fs.mkdir(root + "/.github/workflows", recursive=true)
  @fs.write_binary(
    root + "/moon.mod",
    b"name = \"acme/app\"\nimport {\n  \"acme/minor-lib@1.0.0\",\n  \"acme/patch-lib@0.2.1\",\n}\n",
  )
  @fs.write_binary(
    root + "/.github/workflows/ci.yml",
    b"name: CI\njobs:\n  build:\n    steps:\n      - uses: actions/checkout@v4.1.0\n",
  )
  @fs.write_binary(
    root + "/.github/workflows/clean.yml",
    b"name: Clean\njobs:\n  lint:\n    steps:\n      - uses: actions/setup-node@v4\n",
  )
  let now = 1000000000000L
  let day = 86400000L
  let sha_checkout = "4444444444444444444444444444444444444444"
  let output : Array[String] = []
  let code = run_cli(
    ["moon-taze", "-C", root],
    fetch=name => {
      if name == "acme/minor-lib" {
        @taze.ModuleMetadata(name, Some("2.0.0"), [
          @taze.VersionMetadata("1.0.0", false, None, None),
          @taze.VersionMetadata("1.2.0", false, None, None),
          @taze.VersionMetadata("2.0.0", false, None, None),
        ])
      } else {
        @taze.ModuleMetadata(name, Some("0.2.3"), [
          @taze.VersionMetadata("0.2.1", false, None, None),
          @taze.VersionMetadata("0.2.3", false, None, None),
        ])
      }
    },
    fetch_version=(_, version) => {
      let age = if version == "1.0.0" || version == "0.2.1" {
        30L * day
      } else {
        10L * day
      }
      Some(@taze.VersionMetadata(version, false, None, Some(now - age)))
    },
    fetch_gha=repo => {
      if repo == "actions/checkout" {
        @taze.ModuleMetadata(repo, Some("v5"), [
          @taze.VersionMetadata(
            "v4.1.0",
            false,
            None,
            None,
            sha=Some(sha_checkout),
          ),
          @taze.VersionMetadata(
            "v4.2.0",
            false,
            None,
            None,
            sha=Some(sha_checkout),
          ),
          @taze.VersionMetadata("v5", false, None, None, sha=Some(sha_checkout)),
        ])
      } else {
        @taze.ModuleMetadata(repo, Some("v4"), [
          @taze.VersionMetadata("v4", false, None, None),
        ])
      }
    },
    fetch_gha_commit_date=(_, _) => Some(now - 9L * day),
    emit=line => output.push(line),
    color=Some(false),
    now_ms=Some(now),
  )
  assert_eq(code, 0)
  let text = output.join("\n")
  assert_true(text.contains("acme/app - 1 minor, 1 patch"))
  assert_true(text.contains("  import"))
  assert_true(text.contains("(2.0.0 available)"))
  assert_true(text.contains(".github/workflows/ci.yml - 1 minor"))
  assert_true(text.contains("  github-actions"))
  assert_true(text.contains("v4.1.0  →  v4.2.0  ~9d"))
  assert_true(
    text.contains("dependencies are already up-to-date in one package"),
  )
  assert_true(text.contains("Run moon-taze major to check major updates"))
  assert_true(text.contains("Add -w to write to moon.mod and GitHub Actions"))
}

///|
async test "CLI previews and writes both moon.mod and GitHub Actions workflows" {
  let root = @fs.tmpdir(prefix="moon-taze-cli-gha")
  defer @fs.remove(root, recursive=true)
  @fs.mkdir(root + "/.github/workflows", recursive=true)
  let mod_path = root + "/moon.mod"
  let ci_path = root + "/.github/workflows/ci.yml"
  @fs.write_binary(
    mod_path, b"name = \"demo/app\"\nimport { \"demo/lib@1.0.0\" }\n",
  )
  @fs.write_binary(
    ci_path,
    @utf8.encode(
      "name: CI\njobs:\n  build:\n    steps:\n      - uses: actions/checkout@v4\n",
    ),
  )
  let gha_sha = "4444444444444444444444444444444444444444"
  let output : Array[String] = []
  let code = run_cli(
    ["moon-taze", "major", "-C", root, "-w"],
    fetch=name => {
      @taze.ModuleMetadata(name, Some("2.0.0"), [
        @taze.VersionMetadata("1.0.0", false, None, None),
        @taze.VersionMetadata("2.0.0", false, None, None),
      ])
    },
    fetch_gha=repo => {
      @taze.ModuleMetadata(repo, Some("v5"), [
        @taze.VersionMetadata("v4", false, None, None, sha=Some(gha_sha)),
        @taze.VersionMetadata("v5", false, None, None, sha=Some(gha_sha)),
      ])
    },
    emit=line => output.push(line),
    color=Some(false),
  )
  assert_eq(code, 0)
  assert_true(@fs.read_text(mod_path).contains("demo/lib@2.0.0"))
  assert_true(@fs.read_text(ci_path).contains("actions/checkout@v5"))
  let text = output.join("\n")
  assert_true(text.contains(".github/workflows/ci.yml - 1 major"))
  assert_true(
    text.contains(
      "ℹ changes written to moon.mod and GitHub Actions, run moon check to verify.",
    ),
  )
}

///|
async test "CLI renders dedicated ERROR block for registry failures" {
  let root = @fs.tmpdir(prefix="moon-taze-cli-errblock")
  defer @fs.remove(root, recursive=true)
  @fs.write_binary(
    root + "/moon.mod",
    b"name = \"demo/app\"\nimport { \"demo/missing@1.0.0\", \"demo/timeout@1.0.0\" }\n",
  )
  let output : Array[String] = []
  let code = run_cli(
    ["moon-taze", "-C", root, "--no-retry"],
    fetch=name => {
      if name == "demo/missing" {
        raise @taze.registry_request_failed("HTTP 404")
      } else {
        raise @taze.registry_request_failed("request_timeout")
      }
    },
    emit=line => output.push(line),
    color=Some(false),
  )
  assert_eq(code, 2)
  let text = output.join("\n")
  assert_true(text.contains(" ERROR "))
  assert_true(text.contains("> demo/missing not found"))
  assert_true(text.contains("> demo/timeout request timeout"))
}

///|
async test "CLI supports repositories with only GitHub Actions workflows and --no-github-actions" {
  let root = @fs.tmpdir(prefix="moon-taze-cli-gha-only")
  defer @fs.remove(root, recursive=true)
  @fs.mkdir(root + "/.git")
  @fs.mkdir(root + "/.github/workflows", recursive=true)
  @fs.write_binary(
    root + "/.github/workflows/ci.yml",
    b"jobs:\n  test:\n    steps:\n      - uses: actions/checkout@v4\n",
  )
  let gha_calls = Ref(0)
  let out : Array[String] = []
  let ok_code = run_cli(
    ["moon-taze", "major", "-C", root, "--json"],
    fetch=name => @taze.ModuleMetadata(name, None, []),
    fetch_gha=repo => {
      gha_calls.val += 1
      @taze.ModuleMetadata(repo, Some("v5"), [
        @taze.VersionMetadata("v4", false, None, None),
        @taze.VersionMetadata("v5", false, None, None),
      ])
    },
    emit=line => out.push(line),
  )
  assert_eq(ok_code, 0)
  assert_eq(gha_calls.val, 1)
  assert_true(out[0].contains("\"kind\":\"github-actions\""))
  assert_false(out[0].contains("\u001b["))

  let disabled_out : Array[String] = []
  let no_manifest_code = run_cli(
    ["moon-taze", "--no-github-actions", "-C", root],
    fetch=name => @taze.ModuleMetadata(name, None, []),
    emit=line => disabled_out.push(line),
    color=Some(false),
  )
  assert_eq(no_manifest_code, 2)
  assert_true(disabled_out.any(line => line.contains("no_manifest")))
}

///|
async test "CLI timediff enriches detail timestamps once and emits JSON fields" {
  let root = @fs.tmpdir(prefix="moon-taze-cli-timediff")
  defer @fs.remove(root, recursive=true)
  @fs.write_binary(
    root + "/moon.mod",
    b"name = \"demo/app\"\nimport {\"demo/lib@1.0.0\"}",
  )
  let detail_calls : Array[String] = []
  let fetch : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError = name => {
    @taze.ModuleMetadata(name, Some("1.1.0"), [
      @taze.VersionMetadata("1.0.0", false, None, None),
      @taze.VersionMetadata("1.1.0", false, None, None),
    ])
  }
  let detail : async (String, String) -> @taze.VersionMetadata? raise @taze.RegistryError = (
    name,
    version,
  ) => {
    detail_calls.push(name + "@" + version)
    let ts = if version == "1.0.0" { 0L } else { 86400000L }
    Some(@taze.VersionMetadata(version, false, None, Some(ts)))
  }
  let text_output : Array[String] = []
  assert_eq(
    run_cli(
      ["moon-taze", "-C", root],
      fetch~,
      emit=line => text_output.push(line),
      fetch_version=detail,
      color=Some(false),
      now_ms=Some(172800000L),
    ),
    0,
  )
  assert_true(
    text_output.any(line => line.contains("~48h") && line.contains("~24h")),
  )
  assert_eq(detail_calls, ["demo/lib@1.0.0", "demo/lib@1.1.0"])

  detail_calls.clear()
  let json_output : Array[String] = []
  assert_eq(
    run_cli(
      ["moon-taze", "-C", root, "--json"],
      fetch~,
      emit=line => json_output.push(line),
      fetch_version=detail,
    ),
    0,
  )
  assert_eq(json_output.length(), 1)
  assert_true(json_output[0].contains("\"currentPublishedAt\":0"))
  assert_true(json_output[0].contains("\"timeDiffSeconds\":86400"))
}

///|
async test "CLI persistent cache-v2 stores and reloads Mooncakes and GitHub metadata" {
  let root = @fs.tmpdir(prefix="moon-taze-cli-cache")
  defer @fs.remove(root, recursive=true)
  let cache_file = root + "/cache-v2.json"
  let cache : Map[String, @taze.ModuleMetadata] = Map([])
  let cache_times : Map[String, UInt64] = Map([])
  let now = @env.now()
  let mc_key = mooncakes_cache_key("https://mooncakes.io", "demo/lib")
  let gha_key = gha_cache_key("actions/checkout")
  cache[mc_key] = @taze.ModuleMetadata("demo/lib", Some("1.1.0"), [
    @taze.VersionMetadata("1.1.0", false, None, Some(1000L)),
  ])
  cache_times[mc_key] = now
  cache[gha_key] = @taze.ModuleMetadata("actions/checkout", Some("v5"), [
    @taze.VersionMetadata("v5", false, None, None, sha=Some("1234")),
  ])
  cache_times[gha_key] = now
  save_persistent_cache(Some(cache_file), cache, cache_times, now~)

  let reloaded : Map[String, @taze.ModuleMetadata] = Map([])
  let reloaded_times : Map[String, UInt64] = Map([])
  load_persistent_cache(
    Some(cache_file),
    cache=reloaded,
    cache_times=reloaded_times,
    now~,
  )
  assert_eq(reloaded.get(mc_key), cache.get(mc_key))
  assert_eq(reloaded.get(gha_key), cache.get(gha_key))
}

///|
async test "CLI persists display ages to cache and skips refetches on warm runs" {
  let root = @fs.tmpdir(prefix="moon-taze-cli-age-cache")
  defer @fs.remove(root, recursive=true)
  @fs.write_binary(
    root + "/moon.mod",
    b"name = \"demo/app\"\nimport {\"demo/lib@1.0.0\"}\n",
  )
  let cache_file = root + "/cache-v2.json"
  let cache : Map[String, @taze.ModuleMetadata] = Map([])
  let cache_times : Map[String, UInt64] = Map([])
  let fetch_calls = Ref(0)
  let detail_calls = Ref(0)
  let now = 172800000L
  let out1 : Array[String] = []
  assert_eq(
    run_cli(
      ["moon-taze", "-C", root],
      fetch=name => {
        fetch_calls.val += 1
        @taze.ModuleMetadata(name, Some("1.1.0"), [
          @taze.VersionMetadata("1.0.0", false, None, None),
          @taze.VersionMetadata("1.1.0", false, None, None),
        ])
      },
      fetch_version=(_, version) => {
        detail_calls.val += 1
        let ts = if version == "1.0.0" { 0L } else { 86400000L }
        Some(@taze.VersionMetadata(version, false, None, Some(ts)))
      },
      emit=line => out1.push(line),
      cache~,
      cache_times~,
      cache_path=Some(cache_file),
      color=Some(false),
      now_ms=Some(now),
    ),
    0,
  )
  assert_eq(fetch_calls.val, 1)
  assert_eq(detail_calls.val, 2)
  assert_true(out1.any(line => line.contains("~48h") && line.contains("~24h")))

  // Reload from disk into fresh cache maps and run again: zero network calls!
  let warm_cache : Map[String, @taze.ModuleMetadata] = Map([])
  let warm_times : Map[String, UInt64] = Map([])
  load_persistent_cache(
    Some(cache_file),
    cache=warm_cache,
    cache_times=warm_times,
  )
  let out2 : Array[String] = []
  assert_eq(
    run_cli(
      ["moon-taze", "-C", root],
      fetch=name => {
        fetch_calls.val += 1
        @taze.ModuleMetadata(name, None, [])
      },
      fetch_version=(_, _) => {
        detail_calls.val += 1
        None
      },
      emit=line => out2.push(line),
      cache=warm_cache,
      cache_times=warm_times,
      cache_path=Some(cache_file),
      color=Some(false),
      now_ms=Some(now),
    ),
    0,
  )
  assert_eq(fetch_calls.val, 1)
  assert_eq(detail_calls.val, 2)
  assert_true(out2.any(line => line.contains("~48h") && line.contains("~24h")))
}
