///|
async fn batch_fixture(root : String, count : Int) -> CheckPlan {
  let snapshots = []
  let entries = []
  let issues = []
  for i in 0..<count {
    let path = root + "/\{i}.moon.mod"
    let source = b"name = \"demo/app\"\nimport {\"demo/lib@1.0.0\"}\n"
    @fs.write_file(path, source)
    let parsed = parse_manifest(source, path~, module_name="demo/app")
    let plan = check_manifest(parsed.manifest.unwrap(), mode=Patch, fetch=name => {
      ModuleMetadata(name, Some("1.0.12"), [
        VersionMetadata("1.0.0", false, None, None),
        VersionMetadata("1.0.12", false, None, None),
      ])
    })
    snapshots.append(plan.snapshots)
    entries.append(plan.entries)
    issues.append(plan.issues)
  }
  make_plan(snapshots, entries, issues)
}

///|
async fn assert_originals(plan : CheckPlan) -> Unit {
  for snapshot in plan.snapshots {
    assert_eq(@fs.read_file(snapshot.path).binary(), snapshot.source)
  }
}

///|
async test "AC-042 second temporary create or write failure commits nothing" {
  for create_failure in [true, false] {
    let root = @fs.tmpdir(prefix="moon-taze-prepare-failure")
    defer @fs.rmdir(root, recursive=true)
    let plan = batch_fixture(root, 3)
    let native = native_write_services()
    let created = Ref(0)
    let staged = Ref(0)
    let io = {
      ..native,
      create: path => {
        if path.has_suffix(".tmp") {
          created.val += 1
          if create_failure && created.val == 2 {
            write_error("write_failed", "injected create failure")
          }
        }
        (native.create)(path)
      },
      stage: (path, file, bytes) => {
        staged.val += 1
        if !create_failure && staged.val == 2 {
          @fs.write_file(file.path, b"partially written")
          write_error("write_failed", "injected disk full")
        }
        (native.stage)(path, file, bytes)
      },
    }
    let result = apply_with_services(
      plan,
      plan.recommended_selection(),
      io,
      None,
    )
    assert_true(result.status is Failed)
    assert_eq(result.written_files(), 0)
    assert_eq(result.exit_code(), 2)
    assert_originals(plan)
    assert_eq(@fs.readdir(root, include_hidden=true).length(), 3)
  }
}

///|
async test "AC-043 second replacement failure retains exact partial result" {
  let root = @fs.tmpdir(prefix="moon-taze-partial")
  defer @fs.rmdir(root, recursive=true)
  let plan = batch_fixture(root, 3)
  let native = native_write_services()
  let calls = Ref(0)
  let io = {
    ..native,
    replace: (file, path) => {
      calls.val += 1
      if calls.val == 2 {
        write_error("write_failed", "injected replace failure")
      }
      (native.replace)(file, path)
    },
  }
  let result = apply_with_services(plan, plan.recommended_selection(), io, None)
  assert_true(result.status is Partial)
  assert_eq(result.exit_code(), 2)
  assert_eq(result.written_files(), 1)
  assert_eq(calls.val, 2)
  assert_true(result.files[0].status is Written)
  assert_true(result.files[1].status is Failed)
  assert_true(result.files[2].status is NotAttempted)
  assert_eq(result.files[0].changed_dependencies, 1)
  assert_true(@fs.read_file(plan.snapshots[0].path).text().contains("1.0.12"))
  for i in 1..<3 {
    assert_eq(
      @fs.read_file(plan.snapshots[i].path).binary(),
      plan.snapshots[i].source,
    )
  }
  assert_eq(@fs.readdir(root, include_hidden=true).length(), 3)
}

///|
async test "AC-041 edit after preparation cancels every commit with accurate path" {
  let root = @fs.tmpdir(prefix="moon-taze-stale-batch")
  defer @fs.rmdir(root, recursive=true)
  let plan = batch_fixture(root, 3)
  let native = native_write_services()
  let edited_path = plan.snapshots[0].path
  let edited = b"// user's new content\n"
  let io = {
    ..native,
    before_commit: () => @fs.write_file(edited_path, edited),
  }
  let result = apply_with_services(plan, plan.recommended_selection(), io, None)
  assert_eq(result.written_files(), 0)
  assert_eq(result.diagnostics[0].code, "stale_plan")
  assert_eq(result.diagnostics[0].manifest, Some(@fs.realpath(edited_path)))
  assert_eq(@fs.read_file(edited_path).binary(), edited)
  for i in 1..<3 {
    assert_eq(
      @fs.read_file(plan.snapshots[i].path).binary(),
      plan.snapshots[i].source,
    )
  }
  assert_eq(@fs.readdir(root, include_hidden=true).length(), 3)
}

///|
async test "cancellation before first commit and after one commit stops at boundaries" {
  for after_commit in [false, true] {
    let root = @fs.tmpdir(prefix="moon-taze-cancel")
    defer @fs.rmdir(root, recursive=true)
    let plan = batch_fixture(root, 3)
    let native = native_write_services()
    let cancelled = Ref(false)
    let calls = Ref(0)
    let io = {
      ..native,
      cancelled: () => cancelled.val,
      before_commit: () => if !after_commit { cancelled.val = true },
      replace: (file, path) => {
        (native.replace)(file, path)
        calls.val += 1
        cancelled.val = true
      },
    }
    let result = apply_with_services(
      plan,
      plan.recommended_selection(),
      io,
      None,
    )
    if after_commit {
      assert_true(result.status is Partial)
      assert_eq(result.written_files(), 1)
      assert_eq(result.exit_code(), 2)
      assert_eq(calls.val, 1)
      assert_true(result.files[0].status is Written)
    } else {
      assert_true(result.status is Cancelled)
      assert_eq(result.exit_code(), 0)
      assert_eq(calls.val, 0)
      assert_originals(plan)
    }
    assert_true(result.files[1].status is NotAttempted)
    assert_true(result.files[2].status is NotAttempted)
    assert_eq(@fs.readdir(root, include_hidden=true).length(), 3)
  }
}

///|
async test "real async cancellation cleans resources while preserving the report" {
  let root = @fs.tmpdir(prefix="moon-taze-async-cancel")
  defer @fs.rmdir(root, recursive=true)
  let plan = batch_fixture(root, 1)
  let reached = @async.Mutex()
  reached.acquire()
  let native = native_write_services()
  let io = {
    ..native,
    before_commit: () => {
      reached.release()
      @async.sleep(60000)
    },
  }
  let result = @async.with_task_group(group => {
    let task = group.spawn(() => {
      apply_with_services(plan, plan.recommended_selection(), io, None)
    })
    @async.with_timeout(5000, () => reached.acquire())
    reached.release()
    task.cancel()
    task.wait()
  })
  assert_true(result.status is Cancelled)
  assert_eq(result.written_files(), 0)
  assert_originals(plan)
  assert_eq(@fs.readdir(root, include_hidden=true).length(), 1)
}

///|
async test "overlapping spans and malformed selections cause zero IO" {
  let source = b"import {\"demo/a@1.0.0\",\"demo/b@1.0.0\"}"
  let manifest = parse_manifest(
    source,
    path="/fake/moon.mod",
    module_name="demo/app",
  ).manifest.unwrap()
  let plan = check_manifest(manifest, mode=Patch, fetch=name => {
    ModuleMetadata(name, Some("1.0.12"), [
      VersionMetadata("1.0.12", false, None, None),
    ])
  })
  let snapshot = plan.snapshots[0]
  snapshot.dependencies[1] = {
    ..snapshot.dependencies[1],
    span: snapshot.dependencies[0].span,
  }
  let calls = Ref(0)
  let io = {
    ..native_write_services(),
    normalize: path => {
      calls.val += 1
      path
    },
  }
  let result = apply_with_services(plan, plan.recommended_selection(), io, None)
  assert_eq(result.diagnostics[0].code, "invalid_selection")
  assert_eq(calls.val, 0)
  let empty = apply_with_services(plan, plan.selection([]), io, None)
  assert_true(empty.status is Succeeded)
  assert_eq(calls.val, 0)
}

///|
async test "second lock conflict releases first lock without removing another owner's lock" {
  let root = @fs.tmpdir(prefix="moon-taze-lock-batch")
  defer @fs.rmdir(root, recursive=true)
  let plan = batch_fixture(root, 3)
  let occupied = plan.snapshots[1].path + ".moon-taze.lock"
  @fs.write_file(occupied, b"other process")
  let result = apply(plan, plan.recommended_selection())
  assert_eq(result.diagnostics[0].code, "write_conflict")
  assert_originals(plan)
  assert_false(@fs.exists(plan.snapshots[0].path + ".moon-taze.lock"))
  assert_eq(@fs.read_file(occupied).binary(), b"other process")
  assert_eq(@fs.readdir(root, include_hidden=true).length(), 4)
}

///|
async test "unsafe target and unavailable atomic replacement never truncate a manifest" {
  for unsafe_target in [true, false] {
    let root = @fs.tmpdir(prefix="moon-taze-unsafe")
    defer @fs.rmdir(root, recursive=true)
    let plan = batch_fixture(root, 1)
    let native = native_write_services()
    let io = {
      ..native,
      inspect: path => {
        if unsafe_target {
          write_error("unsafe_write_target", "injected symlink target")
        }
        (native.inspect)(path)
      },
      replace: (_, _) => {
        write_error("write_failed", "atomic replacement unsupported")
      },
    }
    let report = apply_with_services(
      plan,
      plan.recommended_selection(),
      io,
      None,
    )
    assert_eq(report.exit_code(), 2)
    assert_eq(report.written_files(), 0)
    assert_eq(
      report.diagnostics[0].code,
      if unsafe_target {
        "unsafe_write_target"
      } else {
        "write_failed"
      },
    )
    assert_originals(plan)
    assert_eq(@fs.readdir(root, include_hidden=true).length(), 1)
  }
}

///|
test "relative paths stay anchored to check cwd and drive-relative paths fail" {
  assert_eq(checked_path("moon.mod", "D:/original"), "D:/original/moon.mod")
  assert_eq(checked_path("/root/moon.mod", "/other"), "/root/moon.mod")
  assert_eq(checked_path("/root/moon.mod", "D:/original"), "D:/root/moon.mod")
  assert_eq(
    checked_path("\\\\server\\share\\moon.mod", "D:/original"),
    "\\\\server\\share\\moon.mod",
  )
  try checked_path("C:moon.mod", "D:/original") catch {
    WriteError(code, _, _) => assert_eq(code, "unsafe_write_target")
    error => raise error
  } noraise {
    _ => fail("expected ambiguous path rejection")
  }
}
