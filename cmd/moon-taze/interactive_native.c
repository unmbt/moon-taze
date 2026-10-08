#include <moonbit.h>
#include <stdint.h>
#include <stdio.h>

#ifdef _WIN32
#include <io.h>
#include <windows.h>
#else
#include <unistd.h>
#endif

MOONBIT_FFI_EXPORT int32_t moon_taze_stdin_isatty(void) {
#ifdef _WIN32
  return _isatty(_fileno(stdin)) != 0;
#else
  return isatty(STDIN_FILENO) != 0;
#endif
}

MOONBIT_FFI_EXPORT uint32_t moon_taze_get_console_output_cp(void) {
#ifdef _WIN32
  return (uint32_t)GetConsoleOutputCP();
#else
  return 0;
#endif
}

MOONBIT_FFI_EXPORT void moon_taze_set_console_output_cp(uint32_t cp) {
#ifdef _WIN32
  if (cp != 0) {
    SetConsoleOutputCP((UINT)cp);
    SetConsoleCP((UINT)cp);
  }
#else
  (void)cp;
#endif
}
