// Narrow Native filesystem adapter. Never removes a destination before replacing it.
#include <moonbit.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#ifdef _MSC_VER
#pragma comment(lib, "advapi32.lib")
#endif
#else
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/xattr.h>
#elif defined(__APPLE__)
#include <copyfile.h>
#endif
#endif

static moonbit_bytes_t reply(const char *text) {
  size_t n = strlen(text);
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)n, 0);
  memcpy(out, text, n);
  return out;
}
static moonbit_bytes_t error_reply(unsigned long code) {
  char text[64];
  snprintf(text, sizeof(text), "E:%lu", code);
  return reply(text);
}

#ifdef _WIN32
static wchar_t *wide(moonbit_bytes_t path) {
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (char *)path, -1, NULL, 0);
  if (!count) return NULL;
  wchar_t *result = malloc((size_t)count * sizeof(wchar_t));
  if (!result) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); return NULL; }
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, (char *)path, -1, result, count)) {
    DWORD err = GetLastError(); free(result); SetLastError(err); return NULL;
  }
  return result;
}
static moonbit_bytes_t handle_identity(HANDLE handle) {
  BY_HANDLE_FILE_INFORMATION info;
  if (!GetFileInformationByHandle(handle, &info)) return error_reply(GetLastError());
  char text[128];
  snprintf(text, sizeof(text), "F:%lu:%lu:%lu", (unsigned long)info.dwVolumeSerialNumber,
    (unsigned long)info.nFileIndexHigh, (unsigned long)info.nFileIndexLow);
  return reply(text);
}
#else
static moonbit_bytes_t stat_identity(const struct stat *info) {
  char text[128];
  snprintf(text, sizeof(text), "F:%llu:%llu", (unsigned long long)info->st_dev,
    (unsigned long long)info->st_ino);
  return reply(text);
}
#endif

MOONBIT_FFI_EXPORT int32_t moon_taze_process_id(void) {
#ifdef _WIN32
  return (int32_t)GetCurrentProcessId();
#else
  return (int32_t)getpid();
#endif
}

// -1: unsafe target; -2: read-only; -3: vanished snapshot; positive: OS error.
MOONBIT_FFI_EXPORT int32_t moon_taze_inspect(moonbit_bytes_t path) {
#ifdef _WIN32
  wchar_t *p = wide(path); if (!p) return (int32_t)GetLastError();
  DWORD attrs = GetFileAttributesW(p); DWORD err = GetLastError(); free(p);
  if (attrs == INVALID_FILE_ATTRIBUTES) return (err == ERROR_FILE_NOT_FOUND || err == ERROR_PATH_NOT_FOUND) ? -3 : (int32_t)err;
  if (attrs & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) return -1;
  if (attrs & FILE_ATTRIBUTE_READONLY) return -2;
  return 0;
#else
  struct stat info;
  if (lstat((char *)path, &info) != 0) return (errno == ENOENT || errno == ENOTDIR) ? -3 : errno;
  if (!S_ISREG(info.st_mode)) return -1;
  if (!(info.st_mode & 0222)) return -2;
  return 0;
#endif
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moon_taze_identity(moonbit_bytes_t path) {
#ifdef _WIN32
  wchar_t *p = wide(path); if (!p) return error_reply(GetLastError());
  HANDLE h = CreateFileW(p, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, NULL);
  DWORD err = GetLastError(); free(p);
  if (h == INVALID_HANDLE_VALUE) return error_reply(err);
  moonbit_bytes_t result = handle_identity(h); CloseHandle(h); return result;
#else
  struct stat info;
  if (lstat((char *)path, &info) != 0) return error_reply(errno);
  return stat_identity(&info);
#endif
}

MOONBIT_FFI_EXPORT moonbit_bytes_t moon_taze_create(moonbit_bytes_t path) {
#ifdef _WIN32
  wchar_t *p = wide(path); if (!p) return error_reply(GetLastError());
  HANDLE h = CreateFileW(p, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
  DWORD err = GetLastError();
  if (h == INVALID_HANDLE_VALUE) {
    free(p);
    if (err == ERROR_FILE_EXISTS || err == ERROR_ALREADY_EXISTS) return reply("exists");
    return error_reply(err);
  }
  moonbit_bytes_t result = handle_identity(h);
  CloseHandle(h);
  if (result[0] == 'E') DeleteFileW(p); // still our newly-created, empty file
  free(p); return result;
#else
  int fd = open((char *)path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0) return errno == EEXIST ? reply("exists") : error_reply(errno);
  struct stat info;
  if (fstat(fd, &info) != 0) {
    int err = errno; close(fd); unlink((char *)path); return error_reply(err);
  }
  close(fd); return stat_identity(&info);
#endif
}

// Copy permission metadata before any dependency data is written into the temp file.
MOONBIT_FFI_EXPORT int32_t moon_taze_copy_permissions(moonbit_bytes_t source, moonbit_bytes_t temporary) {
#ifdef _WIN32
  wchar_t *src = wide(source); if (!src) return (int32_t)GetLastError();
  wchar_t *dst = wide(temporary); if (!dst) { DWORD err = GetLastError(); free(src); return (int32_t)err; }
  DWORD size = 0;
  // Reading or assigning owner/group metadata requires WRITE_OWNER privileges
  // that ordinary users do not have on otherwise writable files.  The DACL is
  // the permission metadata needed for a normal replacement and can be copied
  // by the file owner without elevating the CLI.
  SECURITY_INFORMATION flags = DACL_SECURITY_INFORMATION;
  GetFileSecurityW(src, flags, NULL, 0, &size);
  DWORD err = GetLastError();
  if (err != ERROR_INSUFFICIENT_BUFFER || !size) { free(src); free(dst); return (int32_t)err; }
  PSECURITY_DESCRIPTOR security = malloc(size);
  if (!security) { free(src); free(dst); return ERROR_NOT_ENOUGH_MEMORY; }
  if (!GetFileSecurityW(src, flags, security, size, &size)) {
    err = GetLastError();
  } else {
    SECURITY_DESCRIPTOR_CONTROL control; DWORD revision;
    if (!GetSecurityDescriptorControl(security, &control, &revision)) { err = GetLastError(); }
    else {
      flags |= (control & SE_DACL_PROTECTED) ? PROTECTED_DACL_SECURITY_INFORMATION : UNPROTECTED_DACL_SECURITY_INFORMATION;
      err = SetFileSecurityW(dst, flags, security) ? 0 : GetLastError();
    }
  }
  free(security); free(src); free(dst); return (int32_t)err;
#else
  struct stat info;
  int src = open((char *)source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (src < 0) return errno;
  int dst = open((char *)temporary, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
  if (dst < 0) { int err = errno; close(src); return err; }
  int err = 0;
  if (fstat(src, &info) != 0 || fchown(dst, info.st_uid, info.st_gid) != 0 || fchmod(dst, info.st_mode & 07777) != 0) err = errno;
#ifdef __linux__
  if (!err) {
    // The new temp may have inherited an ACL absent from the source.
    if (fgetxattr(src, "system.posix_acl_access", NULL, 0) < 0 && errno == ENODATA) {
      if (fremovexattr(dst, "system.posix_acl_access") != 0 && errno != ENODATA && errno != ENOTSUP) err = errno;
    }
  }
  if (!err) {
    ssize_t length = flistxattr(src, NULL, 0);
    if (length < 0 && errno != ENOTSUP) err = errno;
    if (length > 0) {
      char *names = malloc((size_t)length);
      if (!names) err = ENOMEM;
      else {
        ssize_t got = flistxattr(src, names, (size_t)length);
        if (got < 0) err = errno;
        else for (ssize_t i = 0; i < got && !err; i += (ssize_t)strlen(names + i) + 1) {
          ssize_t size = fgetxattr(src, names + i, NULL, 0);
          if (size < 0) { err = errno; break; }
          void *value = malloc(size ? (size_t)size : 1);
          if (!value) { err = ENOMEM; break; }
          ssize_t read_size = fgetxattr(src, names + i, value, (size_t)size);
          if (read_size < 0 || fsetxattr(dst, names + i, value, (size_t)read_size, 0) != 0) err = errno;
          free(value);
        }
        free(names);
      }
    }
  }
#elif defined(__APPLE__)
  if (!err && fcopyfile(src, dst, NULL, COPYFILE_ACL | COPYFILE_XATTR) != 0) err = errno;
#else
  if (!err) err = ENOTSUP;
#endif
  close(src); close(dst); return err;
#endif
}

MOONBIT_FFI_EXPORT int32_t moon_taze_replace(moonbit_bytes_t temporary, moonbit_bytes_t destination) {
#ifdef _WIN32
  wchar_t *src = wide(temporary); if (!src) return (int32_t)GetLastError();
  wchar_t *dst = wide(destination); if (!dst) { DWORD err = GetLastError(); free(src); return (int32_t)err; }
  HANDLE h = CreateFileW(src, DELETE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
    NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
  DWORD err = GetLastError(); free(src);
  if (h == INVALID_HANDLE_VALUE) { free(dst); return (int32_t)err; }
  size_t len = wcslen(dst) * sizeof(wchar_t);
  FILE_RENAME_INFO *info = calloc(1, sizeof(FILE_RENAME_INFO) + len + sizeof(wchar_t));
  if (!info) { CloseHandle(h); free(dst); return ERROR_NOT_ENOUGH_MEMORY; }
  info->Flags = 3; // FILE_RENAME_REPLACE_IF_EXISTS | FILE_RENAME_POSIX_SEMANTICS
  info->FileNameLength = (DWORD)len;
  memcpy(info->FileName, dst, len);
  err = SetFileInformationByHandle(h, FileRenameInfoEx, info, (DWORD)(sizeof(FILE_RENAME_INFO) + len + sizeof(wchar_t))) ? 0 : GetLastError();
  free(info); free(dst); CloseHandle(h);
  return (int32_t)err; // No copy/delete or older-system fallback.
#else
  return rename((char *)temporary, (char *)destination) == 0 ? 0 : errno;
#endif
}
