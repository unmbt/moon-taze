///|
priv struct VerificationResult {
  path : String
  passed : Bool
  exit_code : Int32
}

///|
async fn verify_directory(
  path : String,
  emit~ : (String) -> Unit,
) -> VerificationResult {
  try {
    let result = @process.run(
      "moon",
      ["check"],
      cwd=path,
      stdout=Collect,
      stderr=Collect,
      accepted_exit_code=_ => true,
    )
    if result.exit_code == 0 {
      { path, passed: true, exit_code: 0, }
    } else {
      emit(
        "error[verification_failed]: moon check exited \{result.exit_code} in \{path}",
      )
      { path, passed: false, exit_code: result.exit_code, }
    }
  } catch {
    error => {
      emit("error[moon_unavailable]: \{error}")
      { path, passed: false, exit_code: 2, }
    }
  }
}
