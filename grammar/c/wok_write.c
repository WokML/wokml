#include "wok_write.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/// [TODO]: Make this into include? As this hash function will be use very often
/// [TODO]: Maybe we can use Fxhash which consume 8 bytes at a time instead of 1
WOK_READONLY u64 wok_byte_hash(const char *restrict bytes, usize n) {
  u64 h = UINT64_C(0xCBF29CE484222325);
  for (usize i = 0; i < n; i++) {
    h ^= (unsigned char)bytes[i];
    h *= UINT64_C(0x100000001B3);
  }
  return h;
}

WokFileStamp wok_file_stamp(const char *path) {
  WokFileStamp s = {0};
  struct stat st;
  if (stat(path, &st) != 0) return s;
  FILE *fp = fopen(path, "rb");
  if (!fp) return s;
  if (fseek(fp, 0, SEEK_END) != 0) {
    fclose(fp);
    return s;
  }
  long sz = ftell(fp);
  if (sz < 0) {
    fclose(fp);
    return s;
  }
  rewind(fp);
  char *buf = (char *)malloc((usize)sz + 1);
  if (!buf) {
    fclose(fp);
    return s;
  }
  usize got = fread(buf, 1, (usize)sz, fp);
  fclose(fp);
  s.hash = wok_byte_hash(buf, got);
  s.size = (u64)got;
#if defined(__APPLE__)
  s.mtime_sec = st.st_mtimespec.tv_sec;
  s.mtime_nsec = st.st_mtimespec.tv_nsec;
#else
  s.mtime_sec = st.st_mtim.tv_sec;
  s.mtime_nsec = st.st_mtim.tv_nsec;
#endif
  s.valid = true;
  free(buf);
  return s;
}

bool wok_write_permitted(WokFileStamp at_read, WokFileStamp now) {
  // An unreadable file at either end is not something we may overwrite: we
  // cannot show it is the file we formatted.
  if (!at_read.valid || !now.valid) return false;
  return at_read.hash == now.hash && at_read.size == now.size;
}

WokWriteResult wok_write_atomic(const char *path, const char *data, usize n,
                                WokFileStamp at_read) {
  WokFileStamp now = wok_file_stamp(path);
  if (!wok_write_permitted(at_read, now)) return WOK_WRITE_MOVED;

  // Already canonical: do not touch the file at all, so mtimes stay meaningful
  // and a build system is not woken up by a formatter that changed nothing.
  if (now.size == (u64)n && wok_byte_hash(data, n) == now.hash)
    return WOK_WRITE_UNCHANGED;

  // The temp must share a directory with the target, or rename() crosses a
  // filesystem boundary and stops being atomic.
  usize plen = strlen(path);
  char *tmp = (char *)malloc(plen + 16);
  if (!tmp) return WOK_WRITE_FAILED;
  snprintf(tmp, plen + 16, "%s.wokfmt.tmp", path);

  FILE *out = fopen(tmp, "wb");
  if (!out) {
    free(tmp);
    return WOK_WRITE_FAILED;
  }
  bool ok = fwrite(data, 1, n, out) == n;
  if (fclose(out) != 0) ok = false;

  if (ok) {
    struct stat st;
    if (stat(path, &st) == 0) chmod(tmp, st.st_mode & 07777);
    // Last check before the swap. The window between here and rename() cannot
    // be closed without a filesystem compare-and-swap, which POSIX does not
    // provide; it is now bounded by a single syscall rather than by the whole
    // format.
    WokFileStamp again = wok_file_stamp(path);
    if (!wok_write_permitted(at_read, again)) {
      unlink(tmp);
      free(tmp);
      return WOK_WRITE_MOVED;
    }
    if (rename(tmp, path) != 0) ok = false;
  }

  if (!ok) {
    unlink(tmp);  // the original is untouched either way
    free(tmp);
    return WOK_WRITE_FAILED;
  }
  free(tmp);
  return WOK_WRITE_OK;
}
