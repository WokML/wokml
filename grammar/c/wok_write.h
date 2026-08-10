// wok_write -- replacing a source file without ever being able to damage it.
//
// A formatter's worst failure is not a crash: it is leaving your source
// truncated. `fopen(path, "wb")` destroys the file's contents at OPEN, so any
// crash, full disk or interrupted write between the open and the last byte
// leaves nothing to recover. That is a bigger hazard than the concurrent-edit
// race, and it happens without anyone else touching the file.
//
// So: write a temporary in the SAME directory (same filesystem, so the rename
// is atomic), then rename it over the target. A reader never observes a
// partial file, and a crash leaves the original untouched plus a stray temp.
//
// On top of that sits the owner's rule -- do not clobber an edit we never saw.
// The file is stamped when read and re-stamped immediately before the rename;
// if it moved, we refuse. The decision is a PURE function of the two stamps so
// it can be tested without racing anything, which is the part that was
// previously untestable.

#pragma once

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Identity of a file at a moment. The byte hash is the authority; size and
// mtime are cheap corroboration that also catch a same-length edit whose hash
// happens to be read from a stale page cache.
typedef struct {
  u64 hash;
  u64 size;
  i64 mtime_sec;
  i64 mtime_nsec;
  bool valid;
} WokFileStamp;

typedef enum {
  WOK_WRITE_OK = 0,        // replaced
  WOK_WRITE_UNCHANGED,     // already identical; the file was not touched
  WOK_WRITE_MOVED,         // it changed under us; refused, their edit wins
  WOK_WRITE_FAILED,        // I/O error; the original is intact
} WokWriteResult;

WOK_READONLY u64 wok_byte_hash(const char *restrict bytes, usize n);

// Stamps a file by path. `valid` is false when it cannot be read.
WokFileStamp wok_file_stamp(const char *path);

// THE DECISION, pure and therefore testable: may we replace a file whose
// stamp was `at_read` and is now `now`?
bool wok_write_permitted(WokFileStamp at_read, WokFileStamp now);

// Replaces `path` with `data`, atomically, refusing if the file no longer
// matches `at_read`. Preserves the original's permission bits.
WokWriteResult wok_write_atomic(const char *path, const char *data, usize n,
                                WokFileStamp at_read);

