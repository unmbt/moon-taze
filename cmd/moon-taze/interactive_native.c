#include <moonbit.h>
#include <stdint.h>
#include <stdio.h>

#ifdef _WIN32
#include <io.h>
#include <windows.h>
#else
#include <errno.h>
#include <termios.h>
#include <unistd.h>
#endif

#ifdef _WIN32
static DWORD moon_taze_saved_console_mode;
static int moon_taze_raw_active;
#else
static struct termios moon_taze_saved_termios;
static int moon_taze_raw_active;
#endif

MOONBIT_FFI_EXPORT int32_t moon_taze_stdin_isatty(void) {
#ifdef _WIN32
  return _isatty(_fileno(stdin)) != 0;
#else
  return isatty(STDIN_FILENO) != 0;
#endif
}

MOONBIT_FFI_EXPORT int32_t moon_taze_interactive_start(void) {
#ifdef _WIN32
  HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
  DWORD mode;
  if (input == INVALID_HANDLE_VALUE || !GetConsoleMode(input, &mode)) return (int32_t)GetLastError();
  moon_taze_saved_console_mode = mode;
  mode &= ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
  mode |= ENABLE_EXTENDED_FLAGS;
  if (!SetConsoleMode(input, mode)) return (int32_t)GetLastError();
#else
  if (tcgetattr(STDIN_FILENO, &moon_taze_saved_termios) != 0) return errno;
  struct termios raw = moon_taze_saved_termios;
  raw.c_lflag &= (tcflag_t)~(ICANON | ECHO | ISIG);
  raw.c_iflag &= (tcflag_t)~(IXON | ICRNL);
  raw.c_cc[VMIN] = 1;
  raw.c_cc[VTIME] = 0;
  if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0) return errno;
#endif
  moon_taze_raw_active = 1;
  return 0;
}

MOONBIT_FFI_EXPORT void moon_taze_interactive_stop(void) {
  if (!moon_taze_raw_active) return;
#ifdef _WIN32
  SetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), moon_taze_saved_console_mode);
#else
  tcsetattr(STDIN_FILENO, TCSAFLUSH, &moon_taze_saved_termios);
#endif
  moon_taze_raw_active = 0;
}
