#include <moonbit.h>
#include <stdint.h>
#include <stdio.h>

#ifdef _WIN32
#include <io.h>
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
