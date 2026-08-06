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
// equality of LINE-LEADING columns, and nothing else. That was enough while
// columns were read by the layout filter alone. It is not enough for a
// HANGING body, which anchors an indented block to the column of a token that
// is not at the start of its line (see parse_block_body): doubling moves the
// block and leaves the anchor behind.
//
//     add x, k -> let t = t + x        add x, k -> let t = t + x
//                 t := 9                                   t := 9
//
// The conclusion is that doubling is not a re-indentation of THIS language,
// not that the anchor is wrong -- the anchor is the offside rule, and the alt
// body in spec-min section 6's `race` needs it to claim its continuation
// rather than the clause body two levels out.
//
// A constant SHIFT of every line, which would preserve differences as well and
// so be valid for any file, was tried and is not available: the top level is
// pinned at column 1, so shifting it produces an INDENT where no block is due.
//
// So a file that hangs is doubled in its CANONICAL form instead, which has no
// hanging body -- the formatter writes a multi-statement body as a block under
// its head. The tree is the same one (test_print pins Dump(Parse(Format(t)))
// == Dump(t)), so the property compares against the same dump either way, and
// which files take that route is COMPUTED (has_hanging_block), not listed.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../wok_arena.h"
#include "../wok_ast.h"
#include "../wok_parse.h"
#include "../wok_print.h"
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

// A block whose FIRST statement shares a line with the head that owns it --
// `-> let t = t + x` and the rest indented under the `let`. Exact rather than
// heuristic: a body of one statement is not an E_Block at all, so every
// E_Block came either from a block opened on its own line (only spaces before
// it) or from a hanging one (its head before it).
static bool has_hanging_block(const WokNode *n, const char *src) {
  if (!n) return false;
  if (n->tag == E_Block) {
    u32 i = n->off;
    while (i > 0 && src[i - 1] != '\n') {
      if (src[i - 1] != ' ') return true;
      i--;
    }
  }
  const WokNodeDesc *desc = &wok_node_desc[n->tag];
  for (u16 i = 0; i < desc->nfields; i++) {
    switch (desc->fields[i].cls) {
      case WFC_NODE:
      case WFC_OPT:
        if (has_hanging_block(n->slot[i].node, src)) return true;
        break;
      case WFC_SEQ: {
        WokSeq s = wok_seq_unpack(n->slot[i].seq);
        for (u32 j = 0; j < s.n; j++)
          if (has_hanging_block(s.items[j], src)) return true;
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
  return false;
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
  WokDiagSink *d0 = wok_diag_new(a, path, src, n);
  WokNode *tree1 = wok_parse_source(src, n, a, d0);
  char *dump1 = nullptr;
  if (wok_diag_count(d0) != 0) {
    fprintf(stderr, "  FAIL %s: %zu diagnostic(s) on the original\n", path,
            wok_diag_count(d0));
    wok_diag_render(d0, stderr);
    bad++;
  } else {
    dump1 = wok_sexpr_dump_string(tree1, src, a);
  }

  // Property 1 -- re-indentation invariance.
  if (dump1) {
    const char *base = src;
    usize base_n = n;
    if (has_hanging_block(tree1, src)) {
      char *canon = wok_print_string(tree1, src, a);
      if (canon) {
        base = canon;
        base_n = strlen(canon);
      }
    }
    usize n2 = 0;
    char *wide = reindent(base, base_n, &n2);
    if (wide) {
      char *dump2 = parse_and_dump(path, wide, n2, a, &nd);
      if (!dump2) {
        fprintf(stderr, "  FAIL %s: re-indented copy failed to parse\n", path);
        bad++;
      } else if (strcmp(dump1, dump2) != 0) {
        fprintf(stderr, "  FAIL %s: doubling indentation CHANGED THE TREE\n",
                path);
        bad++;
      }
      free(wide);
    }
  }

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

static int check_file_cb(const char *path, void *ctx) {
  (void)ctx;
  return check_file(path);
}

int main(void) {
  int bad = 0, seen = 0;
  for (usize i = 0; i < sizeof dirs / sizeof *dirs; i++)
    bad += wok_test_walk(dirs[i], check_file_cb, nullptr, &seen);
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
