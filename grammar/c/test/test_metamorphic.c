// H3 -- the metamorphic properties. This is what replaces a second
// implementation as an oracle.
//
// The load-bearing one is RE-INDENTATION INVARIANCE. Under an offside rule a
// line break or an indent in the wrong place is NOT a syntax error: it turns
// an expression into a block, or ends one early. The file still parses, and
// only the tree shows the damage. Comparing text would pass. So the test
// perturbs layout in a way that must be meaning-preserving, and compares
// TREES.
//
// Doubling every line's indentation preserves both the ordering and the
// equality of columns, which is all the filter's rules ever consult, so the
// dump must come out byte-identical.

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../wok_arena.h"
#include "../wok_ast.h"
#include "../wok_parse.h"
#include "../wok_sexpr.h"
#include "check.h"

static const char *const dirs[] = {
    "../../docs/redesign/examples/accept",
    "../../docs/redesign/examples/reject",
    "testdata/tour",
};

// Doubles the leading spaces of every line. Lines at column 1 stay at column
// 1, so the top level is unmoved and every nested level moves apart uniformly.
static char *reindent(const char *src, usize n, usize *out_n) {
  char *out = (char *)malloc(n * 2 + 2);
  if (!out) return nullptr;
  usize o = 0;
  usize i = 0;
  while (i < n) {
    usize spaces = 0;
    while (i + spaces < n && src[i + spaces] == ' ') spaces++;
    for (usize k = 0; k < spaces * 2; k++) out[o++] = ' ';
    i += spaces;
    while (i < n && src[i] != '\n') out[o++] = src[i++];
    if (i < n) out[o++] = src[i++];
  }
  out[o] = '\0';
  *out_n = o;
  return out;
}

static char *parse_and_dump(const char *path, const char *src, usize n,
                            WokArena *a, usize *ndiag) {
  WokDiagSink *d = wok_diag_new(a, path, src, n);
  WokNode *file = wok_parse_source(src, n, a, d);
  *ndiag = wok_diag_count(d);
  if (*ndiag != 0) {
    wok_diag_render(d, stderr);
    return nullptr;
  }
  return wok_sexpr_dump_string(file, src, a);
}

static int check_file(const char *path) {
  usize n = 0;
  char *src = wok_test_slurp(path, &n);
  if (!src) {
    fprintf(stderr, "  FAIL cannot read %s\n", path);
    return 1;
  }
  int bad = 0;
  WokArena *a = wok_arena_new(0);

  usize nd = 0;
  char *dump1 = parse_and_dump(path, src, n, a, &nd);
  if (!dump1) {
    fprintf(stderr, "  FAIL %s: %zu diagnostic(s) on the original\n", path, nd);
    bad++;
  }

  // Property 1 -- re-indentation invariance.
  usize n2 = 0;
  char *wide = reindent(src, n, &n2);
  if (dump1 && wide) {
    char *dump2 = parse_and_dump(path, wide, n2, a, &nd);
    if (!dump2) {
      fprintf(stderr, "  FAIL %s: re-indented copy failed to parse\n", path);
      bad++;
    } else if (strcmp(dump1, dump2) != 0) {
      fprintf(stderr, "  FAIL %s: doubling indentation CHANGED THE TREE\n", path);
      bad++;
    }
  }
  free(wide);

  // Property 2 -- the dump forgot no field.
  if (dump1) {
    WokDiagSink *rd = wok_diag_new(a, path, dump1, strlen(dump1));
    const char *text = nullptr;
    WokNode *back = wok_sexpr_read(dump1, strlen(dump1), a, rd, &text);
    if (!back) {
      fprintf(stderr, "  FAIL %s: dump did not read back\n", path);
      wok_diag_render(rd, stderr);
      bad++;
    } else {
      char *dump3 = wok_sexpr_dump_string(back, text, a);
      if (!dump3 || strcmp(dump1, dump3) != 0) {
        fprintf(stderr, "  FAIL %s: Dump(Read(Dump(t))) != Dump(t)\n", path);
        bad++;
      }
    }
  }

  wok_arena_free(a);
  free(src);
  return bad;
}

static int check_dir(const char *dir, int *seen) {
  DIR *dp = opendir(dir);
  if (!dp) {
    fprintf(stderr, "  FAIL cannot open %s\n", dir);
    return 1;
  }
  int bad = 0;
  struct dirent *e;
  while ((e = readdir(dp)) != nullptr) {
    usize len = strlen(e->d_name);
    if (len < 5 || strcmp(e->d_name + len - 4, ".wok") != 0) continue;
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
    bad += check_file(path);
    (*seen)++;
  }
  closedir(dp);
  return bad;
}

int main(void) {
  int bad = 0, seen = 0;
  for (usize i = 0; i < sizeof dirs / sizeof *dirs; i++)
    bad += check_dir(dirs[i], &seen);
  if (seen == 0) {
    fprintf(stderr, "metamorphic: no files found\n");
    return 1;
  }
  if (bad) {
    fprintf(stderr, "metamorphic: %d failure(s) over %d files\n", bad, seen);
    return 1;
  }
  printf("metamorphic: %d files, re-indentation invariant and dump round-trips\n",
         seen);
  return 0;
}
