///|
#borrow(path)
extern "C" fn native_inspect(path : Bytes) -> Int = "moon_taze_inspect"

///|
#borrow(path)
extern "C" fn native_identity(path : Bytes) -> Bytes = "moon_taze_identity"

///|
#borrow(path)
extern "C" fn native_create(path : Bytes) -> Bytes = "moon_taze_create"

///|
#borrow(source, temporary)
extern "C" fn native_copy_permissions(source : Bytes, temporary : Bytes) -> Int = "moon_taze_copy_permissions"

///|
#borrow(temporary, destination)
extern "C" fn native_replace(temporary : Bytes, destination : Bytes) -> Int = "moon_taze_replace"

///|
extern "C" fn native_process_id() -> Int = "moon_taze_process_id"

///|
let write_serial : Ref[Int] = Ref(0)

///|
fn native_path(path : String) -> Bytes raise {
  if path.contains("\u0000") {
    write_error("unsafe_write_target", "path contains a NUL character")
  }
  @utf8.encode(path)
}

///|
fn check_native_result(code : Int, operation : String) -> Unit raise {
  if code == -1 {
    write_error(
      "unsafe_write_target",
      "manifest is not a regular non-symlink file: " + operation,
    )
  } else if code == -3 {
    write_error("stale_plan", "checked manifest no longer exists: " + operation)
  } else if code != 0 {
    write_error("write_failed", "\{operation}: native error \{code}")
  }
}

///|
fn require_owned(file : OwnedFile) -> Unit raise {
  if native_identity(native_path(file.path)) != file.identity {
    write_error(
      "write_conflict",
      "owned temporary file changed identity: \{file.path}",
    )
  }
}

///|
fn native_write_services() -> WriteServices {
  write_serial.val += 1
  let run_id = "\{native_process_id()}-\{@async.now()}-\{write_serial.val}"
  {
    normalize: path => @fs.realpath(path),
    inspect: path => {
      check_native_result(native_inspect(native_path(path)), path)
    },
    read: path => @fs.read_file(path).binary(),
    create: path => {
      let identity = native_create(native_path(path))
      let result = @utf8.decode_lossy(identity)
      if result == "exists" {
        write_error(
          "write_conflict",
          "file already exists; do not remove it until its owning process has ended: \{path}",
        )
      } else if result.has_prefix("E:") {
        write_error(
          "write_failed",
          "exclusive create failed at \{path}: \{result}",
        )
      }
      { path, identity, }
    },
    write_lock: (file, token) => {
      require_owned(file)
      @fs.write_file(file.path, token, create_mode=OpenExisting, sync=Full)
    },
    stage: (source, file, content) => {
      require_owned(file)
      check_native_result(
        native_copy_permissions(native_path(source), native_path(file.path)),
        "copy permissions for \{source}",
      )
      @fs.write_file(
        file.path,
        content,
        create_mode=TruncateExisting,
        sync=Full,
      )
      // A write can clear POSIX set-id bits; restore metadata after writing too.
      check_native_result(
        native_copy_permissions(native_path(source), native_path(file.path)),
        "restore permissions for \{source}",
      )
      let handle = @fs.open(file.path, mode=ReadWrite)
      defer handle.close()
      handle.sync(only_data=false)
    },
    replace: (file, path) => {
      require_owned(file)
      check_native_result(
        native_replace(native_path(file.path), native_path(path)),
        "atomic replacement of \{path}",
      )
    },
    cleanup: file => {
      let current = native_identity(native_path(file.path))
      if current == file.identity {
        @fs.remove(file.path)
      } else if @fs.exists(file.path) {
        write_error(
          "write_conflict",
          "cleanup refused: owned file was replaced at \{file.path}",
        )
      }
    },
    before_commit: () => (),
    cancelled: @async.is_being_cancelled,
    run_id,
  }
}
