// The layout filter over real source: the v2 conformance corpus and the
// syntax tour must lay out with zero faults, and every emitted stream must
// satisfy the invariants.
//
// Also pins the ADVERSARIAL fixtures in testdata/layout-bad/, each of which
// carries the diagnostic code it must produce as its first line. A filter
// that stops catching a fault is as bad as one that invents one.

#include <stdio.h>
#include <string.h>

#include "../wok_arena.h"
#include "../wok_layout.h"
#include "../wok_token.h"
#include "check.h"

static const char *const good_dirs[] = {
    "../../test/redesign/accept",
    "../../test/redesign/reject",
    "testdata/tour",
};

// Runs the first two stages. Returns the diagnostic count; fills `codes` with
// the codes seen.
static usize run_stages(const char *path, const char *src, usize n,
                         WokDiagCode *codes, usize max_codes, char *err,
                         usize err_len, bool *invariants_ok, bool strict) {
  WokArena *a = wok_arena_new(0);
  WokDiagSink *d = wok_diag_new(a, path, src, n);
  WokScanResult sr = wok_scan(src, n, a, d);
  WokTokens out = wok_layout(sr.tokens, a, d);
  *invariants_ok = wok_layout_check(out, sr.tokens.n, strict, err, err_len);
  usize nd = wok_diag_count(d);
  for (usize i = 0; i < nd && i < max_codes; i++)
    codes[i] = wok_diag_at(d, i)->code;
  wok_arena_free(a);
  return nd;
}

static int clean_one(const char *path, void *ctx) {
  (void)ctx;
  usize n = 0;
  char *src = wok_test_slurp(path, &n);
  if (!src) {
    fprintf(stderr, "  FAIL cannot read %s\n", path);
    return 1;
  }
  int bad = 0;
  WokDiagCode codes[32];
  char err[256] = {0};
  bool inv = false;
  usize nd = run_stages(path, src, n, codes, 32, err, sizeof err, &inv, true);
  if (!inv) {
    fprintf(stderr, "  FAIL %s: %s\n", path, err);
    bad++;
  }
  if (nd != 0) {
    fprintf(stderr, "  FAIL %s: %zu layout/lex fault(s), first is %s\n", path,
            nd, wok_diag_code_text(codes[0]));
    bad++;
  }
  free(src);
  return bad;
}

static int check_dir(const char *dir) {
  int seen = 0;
  int bad = wok_test_walk(dir, clean_one, nullptr, &seen);
  if (seen == 0) {
    fprintf(stderr, "  FAIL %s contained no .wok files\n", dir);
    bad++;
  } else {
    printf("  %-42s %2d files clean\n", dir, seen);
  }
  return bad;
}

// Each fixture's first line is `-- EXPECT: <CODE>`; that code must appear.
static int caught_one(const char *path, void *ctx) {
  (void)ctx;
  usize n = 0;
  char *src = wok_test_slurp(path, &n);
  if (!src) {
    fprintf(stderr, "  FAIL cannot read %s\n", path);
    return 1;
  }
  int bad = 0;
  char want[64];
  wok_test_expect_code(src, want, sizeof want);

  WokDiagCode codes[32];
  char err[256] = {0};
  bool inv = false;
  usize nd = run_stages(path, src, n, codes, 32, err, sizeof err, &inv, false);

  // The contract that lets the parser be defensive-free: even a file full
  // of layout faults yields a WELL FORMED stream.
  if (!inv) {
    fprintf(stderr, "  FAIL %s: repaired stream broke an invariant: %s\n",
            path, err);
    bad++;
  }
  bool found = false;
  for (usize i = 0; i < nd && i < 32; i++)
    if (strcmp(wok_diag_code_text(codes[i]), want) == 0) found = true;
  if (!found) {
    fprintf(stderr, "  FAIL %s: expected %s, got %zu diagnostic(s)", path,
            want, nd);
    for (usize i = 0; i < nd && i < 32; i++)
      fprintf(stderr, " %s", wok_diag_code_text(codes[i]));
    fputc('\n', stderr);
    bad++;
  }
  free(src);
  return bad;
}

static int check_bad_dir(void) {
  const char *dir = "testdata/layout-bad";
  int seen = 0;
  int bad = wok_test_walk(dir, caught_one, nullptr, &seen);
  if (seen == 0) {
    fprintf(stderr, "  FAIL %s contained no fixtures\n", dir);
    bad++;
  } else {
    printf("  %-42s %2d fixtures caught\n", dir, seen);
  }
  return bad;
}

int main(void) {
  int bad = 0;
  for (usize i = 0; i < sizeof good_dirs / sizeof *good_dirs; i++)
    bad += check_dir(good_dirs[i]);
  bad += check_bad_dir();
  if (bad) {
    fprintf(stderr, "corpus: %d failure(s)\n", bad);
    return 1;
  }
  printf("corpus: clean\n");
  return 0;
}
