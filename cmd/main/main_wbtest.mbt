///|
fn cli_fixture_fetch(
  name : String,
) -> @taze.ModuleMetadata raise @taze.RegistryError {
  if name == "demo/broken" {
    raise @taze.registry_request_failed("offline failure")
  }
  @taze.ModuleMetadata(name, Some("1.0.12"), [
    @taze.VersionMetadata("1.0.0", false, None, None),
    @taze.VersionMetadata("1.0.12", false, None, None),
  ])
}

///|
async test "CLI preview write filtered update and repeat are offline and isolated" {
  let root = @fs.tmpdir(prefix="moon-taze-cli 空格 &")
  defer @fs.rmdir(root, recursive=true)
  let path = root + "/moon.mod"
  let source = b"name = \"demo/app\"\nimport {\"demo/a@1.0.0\", \"demo/b@1.0.0\"}"
  @fs.write_file(path, source)
  let output : Array[String] = []
  let emit = line => output.push(line)
  let calls : Array[String] = []
  let fetch : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError = name => {
    calls.push(name)
    cli_fixture_fetch(name)
  }
  assert_eq(run_cli(["moon-taze", "patch", "-C", root], fetch~, emit~), 0)
  assert_eq(@fs.read_file(path).binary(), source)
  assert_eq(@fs.readdir(root, include_hidden=true).length(), 1)
  assert_true(output.any(line => line.contains("1.0.0 -> 1.0.12")))
  output.clear()
  calls.clear()
  assert_eq(
    run_cli(
      ["moon-taze", "patch", "-C", root, "--write", "--include", "demo/a"],
      fetch~,
      emit~,
    ),
    0,
  )
  assert_eq(calls, ["demo/a"])
  assert_eq(
    @fs.read_file(path).binary(),
    b"name = \"demo/app\"\nimport {\"demo/a@1.0.12\", \"demo/b@1.0.0\"}",
  )
  assert_true(output.any(line => line == "apply succeeded: 1 files written"))
  let modified = @fs.mtime(path)
  output.clear()
  assert_eq(
    run_cli(
      ["moon-taze", "patch", "-C", root, "-w", "-x", "demo/b"],
      fetch~,
      emit~,
    ),
    0,
  )
  assert_eq(@fs.mtime(path), modified)
  assert_true(output.any(line => line == "apply succeeded: 0 files written"))
}

///|
async test "CLI errors prevent every write and unsupported arguments avoid queries" {
  let root = @fs.tmpdir(prefix="moon-taze-cli-errors")
  defer @fs.rmdir(root, recursive=true)
  let path = root + "/moon.mod"
  let source = b"name = \"demo/app\"\nimport {\"demo/a@1.0.0\", \"demo/broken@1.0.0\"}"
  @fs.write_file(path, source)
  let calls = Ref(0)
  let output : Array[String] = []
  let emit = line => output.push(line)
  let fetch : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError = name => {
    calls.val += 1
    cli_fixture_fetch(name)
  }
  assert_eq(
    run_cli(
      ["moon-taze", "patch", "-C", root, "-w", "--no-retry"],
      fetch~,
      emit~,
    ),
    2,
  )
  assert_eq(calls.val, 2)
  assert_eq(@fs.read_file(path).binary(), source)
  assert_true(output.any(line => line.contains("demo/a 1.0.0 -> 1.0.12")))
  calls.val = 0
  for option in ["--interactive", "--unknown"] {
    assert_eq(
      run_cli(["moon-taze", "-C", root, "-w", option], fetch~, emit~),
      2,
    )
  }
  assert_eq(run_cli(["moon-taze", "-C", root, "--verify"], fetch~, emit~), 2)
  assert_eq(calls.val, 0)
  output.clear()
  assert_eq(
    run_cli(
      ["moon-taze", "-C", root, "-w", "--json", "--no-retry"],
      fetch~,
      emit~,
    ),
    2,
  )
  assert_eq(calls.val, 2)
  assert_eq(output.length(), 1)
  let report_json = @json.parse(output[0])
  assert_true(report_json is Json::Object(_))
  calls.val = 0
  assert_eq(run_cli(["moon-taze", "-C", root, "--recursive"], fetch~, emit~), 2)
  calls.val = 0
  assert_eq(@fs.readdir(root, include_hidden=true).length(), 1)
  @fs.write_file(
    path, b"name = \"demo/app\"\nimport {\"demo/a@1.0.0\",\"demo/a@1.0.0\"}",
  )
  assert_eq(run_cli(["moon-taze", "-C", root, "-w"], fetch~, emit~), 2)
  assert_eq(calls.val, 0)
}

///|
async test "CLI loads one static config and lets command line selectors override it" {
  let root = @fs.tmpdir(prefix="moon-taze-config")
  defer @fs.rmdir(root, recursive=true)
  @fs.write_file(
    root + "/moon.mod",
    b"name = \"demo/app\"\nimport {\"demo/a@1.0.0\", \"demo/b@1.0.0\"}",
  )
  @fs.write_file(
    root + "/moon-taze.json",
    b"{\"include\":[\"demo/a\"],\"all\":true}",
  )
  let calls : Array[String] = []
  let output : Array[String] = []
  async fn fetch(
    name : String,
  ) -> @taze.ModuleMetadata raise @taze.RegistryError {
    calls.push(name)
    cli_fixture_fetch(name)
  }
  assert_eq(
    run_cli(["moon-taze", "-C", root], fetch~, emit=line => output.push(line)),
    0,
  )
  assert_eq(calls, ["demo/a"])
  assert_true(output.any(line => line.contains("demo/b skipped")))
  calls.clear()
  output.clear()
  assert_eq(
    run_cli(["moon-taze", "-C", root, "--include", "demo/b"], fetch~, emit=line => {
      output.push(line)
    }),
    0,
  )
  assert_eq(calls, ["demo/b"])
}

///|
async test "CLI retries transient registry failures and honors force cache bypass" {
  let root = @fs.tmpdir(prefix="moon-taze-retry")
  defer @fs.rmdir(root, recursive=true)
  @fs.write_file(
    root + "/moon.mod",
    b"name = \"demo/app\"\nimport {\"demo/a@1.0.0\"}",
  )
  let calls = Ref(0)
  let fetch : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError = _ => {
    calls.val += 1
    if calls.val <= 2 {
      raise @taze.registry_request_failed("HTTP 503")
    }
    cli_fixture_fetch("demo/a")
  }
  let output : Array[String] = []
  assert_eq(
    run_cli(["moon-taze", "-C", root, "--retry", "2"], fetch~, emit=line => {
      output.push(line)
    }),
    0,
  )
  assert_eq(calls.val, 3)
  let cache : Map[String, @taze.ModuleMetadata] = Map([])
  calls.val = 3
  assert_eq(run_cli(["moon-taze", "-C", root], fetch~, emit=_ => (), cache~), 0)
  assert_eq(calls.val, 4)
  assert_eq(run_cli(["moon-taze", "-C", root], fetch~, emit=_ => (), cache~), 0)
  assert_eq(calls.val, 4)
  assert_eq(
    run_cli(["moon-taze", "-C", root, "--force"], fetch~, emit=_ => (), cache~),
    0,
  )
  assert_eq(calls.val, 5)
}

///|
async test "CLI verify reports process result without contaminating JSON" {
  let root = @fs.tmpdir(prefix="moon-taze-verify")
  defer @fs.rmdir(root, recursive=true)
  @fs.write_file(
    root + "/moon.mod",
    b"name = \"demo/app\"\nimport {\"demo/a@1.0.0\"}",
  )
  let output : Array[String] = []
  let fetch : async (String) -> @taze.ModuleMetadata raise @taze.RegistryError = name => {
    cli_fixture_fetch(name)
  }
  let code = run_cli(
    ["moon-taze", "-C", root, "--write", "--verify", "--json", "--no-retry"],
    fetch~,
    emit=line => output.push(line),
  )
  assert_eq(code, 2)
  assert_eq(output.length(), 1)
  let value = @json.parse(output[0])
  assert_true(value is Json::Object(_))
  assert_true(output[0].contains("verification"))
}
