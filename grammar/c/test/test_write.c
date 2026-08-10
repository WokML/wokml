// Interlock B, tested deterministically.
//
// The previous implementation could only be reviewed, not tested: its check
// was welded to a re-read, and the race window is microseconds wide. Splitting
// the DECISION out as a pure function of two stamps makes every case reachable
// without racing anything, and the atomic-replace behaviour is testable by
// simply doing it.

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "../wok_write.h"
#include "check.h"

#define TMPDIR "/tmp/wok_write_test"

static void put_file(const char *path, const char *text) {
  FILE *f = fopen(path, "wb");
  if (f) {
    fwrite(text, 1, strlen(text), f);
    fclose(f);
  }
}

static char *get_file(const char *path) {
  static char buf[4096];
  FILE *f = fopen(path, "rb");
  if (!f) return nullptr;
  usize n = fread(buf, 1, sizeof buf - 1, f);
  buf[n] = '\0';
  fclose(f);
  return buf;
}

static bool exists(const char *path) { return access(path, F_OK) == 0; }

int main(void) {
  mkdir(TMPDIR, 0755);
  const char *p = TMPDIR "/f.wok";
  const char *tmp = TMPDIR "/f.wok.wokfmt.tmp";

  // ---- the pure decision, every case ------------------------------------
  {
    WokFileStamp a = {.hash = 1, .size = 10, .valid = true};
    WokFileStamp same = {.hash = 1, .size = 10, .valid = true};
    WokFileStamp diff_hash = {.hash = 2, .size = 10, .valid = true};
    WokFileStamp diff_size = {.hash = 1, .size = 11, .valid = true};
    WokFileStamp gone = {.valid = false};

    CHECK(wok_write_permitted(a, same), "identical stamps must permit a write");
    CHECK(!wok_write_permitted(a, diff_hash), "a changed hash must refuse");
    CHECK(!wok_write_permitted(a, diff_size), "a changed size must refuse");
    CHECK(!wok_write_permitted(a, gone),
          "a file that vanished must refuse, not be recreated");
    CHECK(!wok_write_permitted(gone, same),
          "a file we never read must refuse");
  }

  // ---- a normal replacement ---------------------------------------------
  {
    put_file(p, "old contents\n");
    WokFileStamp at_read = wok_file_stamp(p);
    CHECK(at_read.valid, "stamping a real file must succeed");
    WokWriteResult r = wok_write_atomic(p, "new contents\n", 13, at_read);
    CHECK(r == WOK_WRITE_OK, "a clean replace must report OK, got %d", (int)r);
    CHECK(strcmp(get_file(p), "new contents\n") == 0, "content was not replaced");
    CHECK(!exists(tmp), "the temporary file must not survive a success");
  }

  // ---- INTERLOCK B: the file moved under us ------------------------------
  // This is the case that previously had no test at all.
  {
    put_file(p, "original\n");
    WokFileStamp at_read = wok_file_stamp(p);
    put_file(p, "someone else edited this\n");  // the concurrent save
    WokWriteResult r = wok_write_atomic(p, "formatted\n", 10, at_read);
    CHECK(r == WOK_WRITE_MOVED, "a changed file must be refused, got %d", (int)r);
    CHECK(strcmp(get_file(p), "someone else edited this\n") == 0,
          "THEIR EDIT MUST SURVIVE; we must never clobber a change we did not "
          "see");
    CHECK(!exists(tmp), "a refused write must leave no temporary behind");
  }

  // ---- a same-length edit is still caught --------------------------------
  // Size alone would miss this; the hash is the authority.
  {
    put_file(p, "aaaa\n");
    WokFileStamp at_read = wok_file_stamp(p);
    put_file(p, "bbbb\n");
    WokWriteResult r = wok_write_atomic(p, "cccc\n", 5, at_read);
    CHECK(r == WOK_WRITE_MOVED, "a same-length edit must still be refused");
    CHECK(strcmp(get_file(p), "bbbb\n") == 0, "their same-length edit survived");
  }

  // ---- already canonical: do not touch the file --------------------------
  // A formatter that rewrites identical bytes wakes up every build system
  // watching the tree.
  {
    put_file(p, "same\n");
    WokFileStamp at_read = wok_file_stamp(p);
    struct stat before;
    stat(p, &before);
    WokWriteResult r = wok_write_atomic(p, "same\n", 5, at_read);
    CHECK(r == WOK_WRITE_UNCHANGED, "identical content must report UNCHANGED");
    struct stat after;
    stat(p, &after);
    CHECK(before.st_ino == after.st_ino,
          "an unchanged file must not be replaced at all");
  }

  // ---- permissions are preserved across the swap -------------------------
  // rename() takes the TEMP file's mode, so an executable or read-only bit
  // would silently change if we did not copy it.
  {
    put_file(p, "x\n");
    chmod(p, 0640);
    WokFileStamp at_read = wok_file_stamp(p);
    wok_write_atomic(p, "yy\n", 3, at_read);
    struct stat st;
    stat(p, &st);
    CHECK((st.st_mode & 07777) == 0640,
          "mode changed across the replace: %o", st.st_mode & 07777);
  }

  // ---- a vanished file is not resurrected --------------------------------
  {
    put_file(p, "here\n");
    WokFileStamp at_read = wok_file_stamp(p);
    unlink(p);
    WokWriteResult r = wok_write_atomic(p, "back\n", 5, at_read);
    CHECK(r == WOK_WRITE_MOVED, "a deleted file must not be recreated");
    CHECK(!exists(p), "the file must stay deleted");
  }

  unlink(p);
  unlink(tmp);
  rmdir(TMPDIR);
  TEST_DONE();
}
