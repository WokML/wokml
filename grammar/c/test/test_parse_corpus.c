// The parser over real source. Three obligations:
//
//   1. every file in the v2 conformance corpus and the syntax tour parses with
//      ZERO diagnostics (the reject/ files are semantically rejected but
//      SYNTACTICALLY VALID, so they exercise the grammar just as hard);
//   2. the result is a W_File whose decls sequence is non-empty;
//   3. every fixture in testdata/parse-bad/ produces the code named on its
//      first line, EXACTLY ONE diagnostic rather than a cascade, and still
//      parses the declarations that follow the damaged one.
//
// (3) is the property that makes recovery believable: item granularity plus a
// DEDENT synchronisation point means a damaged item can never swallow its
// block, and the last declaration in each fixture is a good one.

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <stdio.h>
#include <string.h>

#include "../wok_arena.h"
#include "../wok_ast.h"
#include "../wok_parse.h"
#include "check.h"

static const char *const good_dirs[] = {
    "../../test/redesign/accept",
    "../../test/redesign/reject",
    "testdata/tour",
};

static int count_error_nodes(const WokNode *n) {
  if (!n) return 0;
  int total = (n->tag == D_Error || n->tag == E_Error) ? 1 : 0;
  const WokNodeDesc *desc = &wok_node_desc[n->tag];
  for (u16 i = 0; i < desc->nfields; i++) {
    switch (desc->fields[i].cls) {
      case WFC_NODE:
      case WFC_OPT:
        total += count_error_nodes(n->slot[i].node);
        break;
      case WFC_SEQ: {
        WokSeq s = wok_seq_unpack(n->slot[i].seq);
        for (u32 j = 0; j < s.n; j++) total += count_error_nodes(s.items[j]);
        break;
      }
      case WFC_NAME:
      case WFC_TEXT:
      case WFC_INT:
      case WFC_FLAG:
      case WOK_FIELD_CLASS_COUNT:
        break;
    }
  }
  return total;
}

static int good_one(const char *path, void *ctx) {
  (void)ctx;
  int bad = 0;
  usize n = 0;
  char *src = wok_test_slurp(path, &n);
  if (!src) {
    fprintf(stderr, "  FAIL cannot read %s\n", path);
    return 1;
  }
  WokArena *a = wok_arena_new(0);
  WokDiagSink *d = wok_diag_new(a, path, src, n);
  WokNode *file = wok_parse_source(src, n, a, d);
  usize nd = wok_diag_count(d);
  if (nd != 0) {
    fprintf(stderr, "  FAIL %s: %zu diagnostic(s)\n", path, nd);
    wok_diag_render(d, stderr);
    bad++;
  }
  if (!file || file->tag != W_File) {
    fprintf(stderr, "  FAIL %s: parse did not return a W_File\n", path);
    bad++;
  } else if (W_File_decls(file).n == 0) {
    fprintf(stderr, "  FAIL %s: W_File has no declarations\n", path);
    bad++;
  }
  wok_arena_free(a);
  free(src);
  return bad;
}

static int check_good_dir(const char *dir) {
  int seen = 0;
  int bad = wok_test_walk(dir, good_one, nullptr, &seen);
  if (seen == 0) {
    fprintf(stderr, "  FAIL %s contained no .wok files\n", dir);
    bad++;
  } else {
    printf("  %-42s %2d files clean\n", dir, seen);
  }
  return bad;
}

static int bad_one(const char *path, void *ctx) {
  (void)ctx;
  int bad = 0;
  usize n = 0;
  char *src = wok_test_slurp(path, &n);
  if (!src) {
    fprintf(stderr, "  FAIL cannot read %s\n", path);
    return 1;
  }

  char want[64];
  wok_test_expect_code(src, want, sizeof want);

  WokArena *a = wok_arena_new(0);
  WokDiagSink *d = wok_diag_new(a, path, src, n);
  WokNode *file = wok_parse_source(src, n, a, d);
  usize nd = wok_diag_count(d);

  // Item granularity: one damaged item, one message. A cascade here means
  // the parser is inventing faults that were never in the source.
  if (nd != 1) {
    fprintf(stderr, "  FAIL %s: expected exactly 1 diagnostic, got %zu\n",
            path, nd);
    wok_diag_render(d, stderr);
    bad++;
  }
  bool found = false;
  for (usize i = 0; i < nd; i++)
    if (strcmp(wok_diag_code_text(wok_diag_at(d, i)->code), want) == 0)
      found = true;
  if (!found) {
    fprintf(stderr, "  FAIL %s: expected %s, got", path, want);
    for (usize i = 0; i < nd; i++)
      fprintf(stderr, " %s", wok_diag_code_text(wok_diag_at(d, i)->code));
    fputc('\n', stderr);
    bad++;
  }

  if (!file || file->tag != W_File) {
    fprintf(stderr, "  FAIL %s: parse did not return a W_File\n", path);
    bad++;
  } else {
    WokSeq decls = W_File_decls(file);
    if (decls.n < 3) {
      fprintf(stderr, "  FAIL %s: only %u declaration(s) survived\n", path,
              decls.n);
      bad++;
    } else {
      // Recovery: the declaration AFTER the damaged one still parses, and
      // does so as a real equation rather than another error region.
      const WokNode *last = decls.items[decls.n - 1];
      if (last->tag != D_Equation) {
        fprintf(stderr,
                "  FAIL %s: the declaration after the damaged item is %s, "
                "not D_Equation\n",
                path, wok_node_desc[last->tag].tag);
        bad++;
      }
      if (count_error_nodes(last) != 0) {
        fprintf(stderr, "  FAIL %s: the recovered declaration is damaged\n",
                path);
        bad++;
      }
    }
  }
  wok_arena_free(a);
  free(src);
  return bad;
}

static int check_bad_dir(void) {
  const char *dir = "testdata/parse-bad";
  int seen = 0;
  int bad = wok_test_walk(dir, bad_one, nullptr, &seen);
  if (seen < 5) {
    fprintf(stderr, "  FAIL %s needs at least 5 fixtures, found %d\n", dir,
            seen);
    bad++;
  } else {
    printf("  %-42s %2d fixtures recovered\n", dir, seen);
  }
  return bad;
}

int main(void) {
  int bad = 0;
  wok_cover_reset();
  for (usize i = 0; i < sizeof good_dirs / sizeof *good_dirs; i++)
    bad += check_good_dir(good_dirs[i]);
  bad += check_bad_dir();

  // Production coverage, reported rather than enforced: H4 turns this into a
  // build failure in a later slice, once the tour is complete.
  const WokTag *missing = nullptr;
  usize nmissing = wok_cover_missing(&missing);
  if (nmissing) {
    printf("  coverage: %zu production(s) unreached:", nmissing);
    for (usize i = 0; i < nmissing; i++)
      printf(" %s", wok_node_desc[missing[i]].tag);
    putchar('\n');
  } else {
    printf("  coverage: every production reached\n");
  }

  if (bad) {
    fprintf(stderr, "parse corpus: %d failure(s)\n", bad);
    return 1;
  }
  printf("parse corpus: clean\n");
  return 0;
}
