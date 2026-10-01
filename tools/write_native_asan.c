// ASan harness for the C adapter only; it does not link or modify the MoonBit runtime.
// Borrowed inputs are ordinary NUL-terminated UTF-8; returned Bytes use instrumented malloc.
#include "../write_native.c"
#include <assert.h>

moonbit_bytes_t moonbit_make_bytes(int32_t size, int value) {
  assert(size >= 0);
  moonbit_bytes_t bytes = malloc((size_t)size + 1);
  assert(bytes);
  memset(bytes, value, (size_t)size);
  bytes[size] = 0;
  return bytes;
}

static void remove_fixture(char *path) {
#ifdef _WIN32
  wchar_t *p = wide((moonbit_bytes_t)path);
  assert(p && DeleteFileW(p));
  free(p);
#else
  assert(unlink(path) == 0);
#endif
}

int main(int argc, char **argv) {
  assert(argc == 2); // runner creates and owns this isolated directory
  char source[4096], temp[4096];
  assert(snprintf(source, sizeof(source), "%s/source.moon.mod", argv[1]) < (int)sizeof(source));
  assert(snprintf(temp, sizeof(temp), "%s/temp.moon.mod", argv[1]) < (int)sizeof(temp));
  for (int i = 0; i < 200; i++) {
    moonbit_bytes_t a = moon_taze_create((moonbit_bytes_t)source);
    assert(a[0] == 'F');
    moonbit_bytes_t id = moon_taze_identity((moonbit_bytes_t)source);
    assert(strcmp((char *)a, (char *)id) == 0);
    free(id); free(a);
    moonbit_bytes_t conflict = moon_taze_create((moonbit_bytes_t)source);
    assert(strcmp((char *)conflict, "exists") == 0); free(conflict);
    moonbit_bytes_t b = moon_taze_create((moonbit_bytes_t)temp);
    assert(b[0] == 'F'); free(b);
    assert(moon_taze_inspect((moonbit_bytes_t)source) == 0);
    assert(moon_taze_copy_permissions((moonbit_bytes_t)source, (moonbit_bytes_t)temp) == 0);
    assert(moon_taze_replace((moonbit_bytes_t)temp, (moonbit_bytes_t)source) == 0);
    moonbit_bytes_t missing = moon_taze_identity((moonbit_bytes_t)temp);
    assert(missing[0] == 'E'); free(missing);
    assert(moon_taze_replace((moonbit_bytes_t)temp, (moonbit_bytes_t)source) != 0);
    assert(moon_taze_copy_permissions((moonbit_bytes_t)temp, (moonbit_bytes_t)source) != 0);
    remove_fixture(source);
  }
#ifdef _WIN32
  moonbit_bytes_t invalid = moon_taze_create((moonbit_bytes_t)"\xff");
  assert(invalid[0] == 'E'); free(invalid);
#endif
  puts("native adapter ASan: 200 replacement/error-path cycles passed");
  return 0;
}
