// E2 -- error BATCHING: every fault reported, at the right line, with the
// sound declarations around it left intact.
//
// The existing testdata/parse-bad fixtures each contain exactly ONE fault, so
// nothing before this exercised the batch at all. These contain several, and
// each states two things in its header:
//
//   -- EXPECT-LINES: 6 11 16    the line of every diagnostic, in order
//   -- EXPECT-SOUND: 7          top-level declarations that still parsed
//
// The first is what E1 was for: before it, a fault whose offending token was a
// layout token got blamed on the FOLLOWING line, because wok_layout.c builds a
// layout token from the token it precedes. Two of the three faults in fixture
// 01 pointed at a perfectly good declaration.
//
// The second is what makes recovery worth having: a batch that reports the
// right lines but discards half the file is not a work list.

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../wok_arena.h"
#include "../wok_ast.h"
#include "../wok_parse.h"
#include "check.h"

#define DIR_ "testdata/parse-batch"
#define MAX_EXPECT 32

// Reads `-- EXPECT-<key>:` from the header. Returns the count parsed.
static usize expect_list(const char *src, const char *key, u32 *out,
                         usize max) {
  char needle[64];
  snprintf(needle, sizeof needle, "-- EXPECT-%s:", key);
  const char *p = strstr(src, needle);
  if (!p) return SIZE_MAX;  // absent, which is different from empty
  p += strlen(needle);
  usize n = 0;
  while (*p && *p != '\n' && n < max) {
    while (*p == ' ') p++;
    if (*p < '0' || *p > '9') break;
    u32 v = 0;
    while (*p >= '0' && *p <= '9') v = v * 10 + (u32)(*p++ - '0');
    out[n++] = v;
  }
  return n;
}

static u32 sound_decls(const WokNode *file) {
  if (!file || file->tag != W_File) return 0;
  WokSeq decls = W_File_decls(file);
  u32 sound = 0;
  for (u32 i = 0; i < decls.n; i++)
    if (decls.items[i]->tag != D_Error && decls.items[i]->tag != E_Error)
      sound++;
  return sound;
}

int main(void) {
  DIR *dp = opendir(DIR_);
  CHECK(dp != nullptr, "cannot open %s", DIR_);
  if (!dp) TEST_DONE();

  int seen = 0;
  struct dirent *e;
  while ((e = readdir(dp)) != nullptr) {
    usize len = strlen(e->d_name);
    if (len < 5 || strcmp(e->d_name + len - 4, ".wok") != 0) continue;
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", DIR_, e->d_name);
    usize n = 0;
    char *src = wok_test_slurp(path, &n);
    CHECK(src != nullptr, "cannot read %s", path);
    if (!src) continue;
    seen++;

    u32 want[MAX_EXPECT];
    usize nwant = expect_list(src, "LINES", want, MAX_EXPECT);
    CHECK(nwant != SIZE_MAX, "%s has no -- EXPECT-LINES header", e->d_name);

    WokArena *a = wok_arena_new(0);
    WokDiagSink *d = wok_diag_new(a, path, src, n);
    WokNode *file = wok_parse_source(src, n, a, d);

    // Every fault, at the line the header names, in order. An exact match
    // also pins "one diagnostic per damaged item": a cascade would show up
    // as an extra entry.
    usize got = wok_diag_count(d);
    CHECK(got == nwant, "%s: %zu diagnostics, header expects %zu", e->d_name,
          got, nwant);
    for (usize i = 0; i < got && i < nwant; i++) {
      u32 line = 0, col = 0;
      wok_diag_position(d, wok_diag_at(d, i)->off, &line, &col);
      CHECK(line == want[i],
            "%s: diagnostic %zu is blamed on line %u, but the fault is on "
            "line %u\n      message: %s",
            e->d_name, i, line, want[i], wok_diag_at(d, i)->msg);
    }

    // The declarations recovery did NOT eat.
    u32 want_sound[1];
    usize ns = expect_list(src, "SOUND", want_sound, 1);
    if (ns != SIZE_MAX && ns == 1) {
      u32 sound = sound_decls(file);
      CHECK(sound == want_sound[0],
            "%s: %u sound declarations survived, header expects %u -- "
            "recovery ate more than the damaged items",
            e->d_name, sound, want_sound[0]);
    }

    // Whatever survived, a damaged file must still report a non-zero fault
    // count. A repair-free parser must never silently bless broken input.
    CHECK(got > 0, "%s: a fixture with faults reported none", e->d_name);

    wok_arena_free(a);
    free(src);
  }
  closedir(dp);
  CHECK(seen >= 5, "%s held %d fixtures, expected at least 5", DIR_, seen);
  TEST_DONE();
}
