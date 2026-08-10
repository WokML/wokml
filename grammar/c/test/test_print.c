// The CANONICAL PRINTER's five properties, over every corpus file and over a
// handful of inline sources that pin decisions the corpus does not reach.
//
// Property 1 is the load-bearing one. Under an offside rule a line break in
// the wrong place is NOT a syntax error: it turns an expression into a block
// or ends one early, so the reformatted text still parses and only the TREE
// shows the damage. Comparing text would pass while the program silently
// changed, which is why every check here goes through wok_sexpr_dump.
//
//   1. Dump(Parse(Format(t))) == Dump(t)      -- printing changed nothing
//   2. Format(Parse(Format(t))) == Format(t)  -- the formatter is a fixed
//                                                point, so --check never
//                                                flags a file it just wrote
//   3. hash(Parse(Format(t))) == hash(t)      -- the Merkle hash agrees
//   4. Format(t) parses with ZERO diagnostics
//   5. Format(t)'s token stream satisfies every layout invariant, checked
//      with strict_brackets because the output is known to be well formed
//
// The inline sources also pin ARROW ALIGNMENT exactly, including both sides
// of the WOK_PRINT_ALIGN_MAX guard, because alignment is the one part of the
// canonical form that depends on more than one item at a time and so is the
// one part that could break property 2.

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../wok_arena.h"
#include "../wok_ast.h"
#include "../wok_layout.h"
#include "../wok_parse.h"
#include "../wok_print.h"
#include "../wok_sexpr.h"
#include "../wok_token.h"
#include "check.h"

static const char *const dirs[] = {
    "../../test/redesign/accept",
    "../../test/redesign/reject",
    "testdata/tour",
    // The line-filling boundary cases. They belong here as well as in
    // test_fill: a WRAPPED file is the one shape where a break could have
    // changed the tree, so it must satisfy the same five properties as any
    // other source before its exact text is worth pinning.
    "testdata/fill",
};

typedef struct {
  WokNode *tree;
  char *dump;
  usize ndiag;
} Parsed;

static Parsed parse_one(const char *path, const char *src, usize n,
                        WokArena *a, bool show) {
  Parsed r = {0};
  WokDiagSink *d = wok_diag_new(a, path, src, n);
  r.tree = wok_parse_source(src, n, a, d);
  r.ndiag = wok_diag_count(d);
  if (r.ndiag != 0) {
    if (show) wok_diag_render(d, stderr);
    return r;
  }
  r.dump = wok_sexpr_dump_string(r.tree, src, a);
  return r;
}

// Property 5. The reformatted text is known to be well formed, so the
// bracket invariant is checked in its strict form.
static bool layout_ok(const char *path, const char *text, usize n,
                      WokArena *a, char *err, usize err_len) {
  WokDiagSink *d = wok_diag_new(a, path, text, n);
  WokScanResult scanned = wok_scan(text, n, a, d);
  WokTokens out = wok_layout(scanned.tokens, a, d);
  return wok_layout_check(out, scanned.tokens.n, true, err, err_len);
}

// The whole property set for one source text. Returns the number of failures.
static int check_source(const char *path, const char *src, usize n) {
  WokArena *a = wok_arena_new(0);
  int bad = 0;

  Parsed one = parse_one(path, src, n, a, true);
  if (one.ndiag != 0) {
    fprintf(stderr, "  FAIL %s: %zu diagnostic(s) on the original\n", path,
            one.ndiag);
    wok_arena_free(a);
    return 1;
  }

  char *fmt = wok_print_string(one.tree, src, a);
  usize fmt_n = strlen(fmt);

  // Property 4 -- and everything after it depends on this having held.
  Parsed two = parse_one(path, fmt, fmt_n, a, true);
  if (two.ndiag != 0) {
    fprintf(stderr, "  FAIL %s: formatted output has %zu diagnostic(s)\n---\n%s---\n",
            path, two.ndiag, fmt);
    wok_arena_free(a);
    return 1;
  }

  // Property 1.
  if (strcmp(one.dump, two.dump) != 0) {
    fprintf(stderr, "  FAIL %s: FORMATTING CHANGED THE TREE\n---\n%s---\n", path,
            fmt);
    bad++;
  }

  // Property 2.
  char *fmt2 = wok_print_string(two.tree, fmt, a);
  if (strcmp(fmt, fmt2) != 0) {
    fprintf(stderr, "  FAIL %s: formatter is not a fixed point\n---\n%s---\n%s---\n",
            path, fmt, fmt2);
    bad++;
  }

  // Property 5.
  char err[256] = {0};
  if (!layout_ok(path, fmt, fmt_n, a, err, sizeof err)) {
    fprintf(stderr, "  FAIL %s: layout invariant broken: %s\n---\n%s---\n", path,
            err, fmt);
    bad++;
  }

  // Canonical-form facts that hold for every file: no blank line opens the
  // text, and exactly one newline closes it.
  if (fmt_n != 0) {
    if (fmt[0] == '\n') {
      fprintf(stderr, "  FAIL %s: output starts with a blank line\n", path);
      bad++;
    }
    if (fmt[fmt_n - 1] != '\n' || (fmt_n > 1 && fmt[fmt_n - 2] == '\n')) {
      fprintf(stderr, "  FAIL %s: output must end in exactly one newline\n",
              path);
      bad++;
    }
  }

  wok_arena_free(a);
  return bad;
}

static int check_file(const char *path) {
  usize n = 0;
  char *src = wok_test_slurp(path, &n);
  if (!src) {
    fprintf(stderr, "  FAIL cannot read %s\n", path);
    return 1;
  }
  int bad = check_source(path, src, n);
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

// ------------------------------------------------------------ exact shapes
//
// Sources whose formatted text is pinned byte for byte. These are the cases
// the corpus does not reach, plus the two sides of the alignment guard.

typedef struct {
  const char *name;
  const char *src;
  const char *want;
} Golden;

static const Golden goldens[] = {
    // Arrow alignment with three arrow clauses of DIFFERENT head widths and
    // a `var` clause, which is headed by `=` and so takes no padding.
    {"align/handler",
     "module M\n"
     "state init = handler State\n"
     "  var cur = init\n"
     "  get -> cur\n"
     "  set x -> cur := x\n"
     "  return v -> (v, cur)\n",
     "module M\n"
     "\n"
     "state init = handler State\n"
     "  var cur = init\n"
     "  get      -> cur\n"
     "  set x    -> cur := x\n"
     "  return v -> (v, cur)\n"},

    // An item whose body is an indented block still CONTRIBUTES its head
    // width: `[]` pads to the width of `y :: ys`.
    {"align/case-with-block-body",
     "module M\n"
     "sumList xs = case xs of\n"
     "  [] -> ()\n"
     "  y :: ys ->\n"
     "    st.set (st.get + y)\n"
     "    sumList ys\n",
     "module M\n"
     "\n"
     "sumList xs = case xs of\n"
     "  []      -> ()\n"
     "  y :: ys ->\n"
     "    st.set (st.get + y)\n"
     "    sumList ys\n"},

    // The guard's inclusive side: a head of exactly WOK_PRINT_ALIGN_MAX
    // columns still aligns.
    {"align/guard-at-limit",
     "module M\n"
     "f x = case x of\n"
     "  Constructor aaaaa bbbbb cccccccc -> 1\n"
     "  [] -> 2\n",
     "module M\n"
     "\n"
     "f x = case x of\n"
     "  Constructor aaaaa bbbbb cccccccc -> 1\n"
     "  []                               -> 2\n"},

    // One column past it: the whole block falls back to a single space, so
    // one long pattern cannot push the block off the screen.
    {"align/guard-over-limit",
     "module M\n"
     "f x = case x of\n"
     "  Constructor aaaaa bbbbb ccccccccc -> 1\n"
     "  [] -> 2\n",
     "module M\n"
     "\n"
     "f x = case x of\n"
     "  Constructor aaaaa bbbbb ccccccccc -> 1\n"
     "  [] -> 2\n"},

    // Decision 2: an inline single-item block is rewritten as the indented
    // form, because that is the ONE spelling of that tree.
    {"block/inline-becomes-indented",
     "module M\n"
     "logging = handler Writer tell w -> e\n"
     "pick xs = case xs of [] -> 0\n"
     "foreign module Libc \"c\" puts : own Bytes -> U64\n"
     "one = 1 where x = 2\n",
     "module M\n"
     "\n"
     "logging = handler Writer\n"
     "  tell w -> e\n"
     "\n"
     "pick xs = case xs of\n"
     "  [] -> 0\n"
     "\n"
     "foreign module Libc \"c\"\n"
     "  puts : own Bytes -> U64\n"
     "\n"
     "one = 1\n"
     "  where\n"
     "    x = 2\n"},

    // Decision 5: brackets are RE-DERIVED from precedence, never stored, so
    // a redundant pair is dropped and a load-bearing one reappears. A chain
    // is FLAT, so `1 + 2 * 3` and `1 + (2 * 3)` are two different trees and
    // keep two different spellings.
    {"parens/rederived-from-precedence",
     "module M\n"
     "f = (((1)) + 2 * 3)\n"
     "f2 = ((1)) + ((2 * 3))\n"
     "g = (a + b) * c\n"
     "h : ((U64)) -> (U64 -> U64)\n"
     "k : (Show a) => a -> String\n"
     "m : (U64 -> U64) -> U64\n",
     "module M\n"
     "\n"
     "f = 1 + 2 * 3\n"
     "\n"
     "f2 = 1 + (2 * 3)\n"
     "\n"
     "g = (a + b) * c\n"
     "\n"
     "h : U64 -> U64 -> U64\n"
     "\n"
     "k : Show a => a -> String\n"
     "\n"
     "m : (U64 -> U64) -> U64\n"},

    // Decision 5, the other direction: backticks are re-derived from the
    // operator's spelling, on both an expression chain and a left-hand side.
    {"backticks/derived",
     "module M\n"
     "a `joinOn` b = a + b\n"
     "(<+>) x y = x `joinOn` y\n",
     "module M\n"
     "\n"
     "a `joinOn` b = a + b\n"
     "\n"
     "(<+>) x y = x `joinOn` y\n"},

    // A block item may not BEGIN with a continuation lead, so a leading
    // negation is bracketed even though precedence alone would not ask for
    // it. The `(-1)` alt is the corpus's own hand-written repair.
    {"lead/negation-bracketed",
     "module M\n"
     "f n = case n of\n"
     "  (-1) -> 2\n"
     "  _ -> 3\n"
     "g =\n"
     "  _ = (-n)\n"
     "  0\n",
     "module M\n"
     "\n"
     "f n = case n of\n"
     "  (-1) -> 2\n"
     "  _    -> 3\n"
     "\n"
     "g =\n"
     "  _ = -n\n"
     "  0\n"},

    // `where` sits one level under its item, which is exactly the body
    // block's column -- the only column that keeps it inside the region
    // parse_equation looks in.
    {"where/placement",
     "module M\n"
     "f n = n + bump\n"
     "  where\n"
     "    bump : U64\n"
     "    bump = 10\n"
     "g n =\n"
     "  let a = 1\n"
     "  a + bump\n"
     "  where\n"
     "    bump = 2\n",
     "module M\n"
     "\n"
     "f n = n + bump\n"
     "  where\n"
     "    bump : U64\n"
     "    bump = 10\n"
     "\n"
     "g n =\n"
     "  let a = 1\n"
     "  a + bump\n"
     "  where\n"
     "    bump = 2\n"},

    // LINE FILLING. A group that does not fit breaks at EVERY opportunity it
    // owns, and a group that does fit breaks at none -- so an already-wrapped
    // source is JOINED back up when it fits, which is the half of the rule a
    // width test alone would not reach.
    {"fill/joins-what-fits",
     "module M\n"
     "f = a\n"
     "  + b\n"
     "  + c\n"
     "g : A\n"
     "     with E\n"
     "        + F\n"
     "g = 0\n"
     "type T = A\n"
     "  | B\n"
     "xs = [ 1\n"
     "     , 2\n"
     "     ]\n",
     "module M\n"
     "\n"
     "f = a + b + c\n"
     "\n"
     "g : A with E + F\n"
     "g = 0\n"
     "\n"
     "type T = A | B\n"
     "\n"
     "xs = [1, 2]\n"},

    // A continuation lead after a block must start a new, SHALLOWER line:
    // `in` closes the binding's block, and `else` closes the `then` block.
    {"leads/after-a-block",
     "module M\n"
     "f =\n"
     "  let n =\n"
     "        seed ()\n"
     "        bump 1\n"
     "    in n * 2\n"
     "g loud n =\n"
     "  if loud\n"
     "    then\n"
     "      report n\n"
     "      n + 1\n"
     "    else n\n",
     "module M\n"
     "\n"
     "f =\n"
     "  let n =\n"
     "    seed ()\n"
     "    bump 1\n"
     "  in n * 2\n"
     "\n"
     "g loud n =\n"
     "  if loud\n"
     "    then\n"
     "      report n\n"
     "      n + 1\n"
     "    else n\n"},
};

int main(void) {
  int bad = 0, seen = 0;

  for (usize i = 0; i < sizeof dirs / sizeof *dirs; i++)
    bad += check_dir(dirs[i], &seen);

  if (seen == 0) {
    fprintf(stderr, "print: no corpus files found\n");
    return 1;
  }

  int golden_bad = 0;
  for (usize i = 0; i < sizeof goldens / sizeof *goldens; i++) {
    const Golden *g = &goldens[i];
    // Every golden also has to satisfy all five properties.
    golden_bad += check_source(g->name, g->src, strlen(g->src));

    WokArena *a = wok_arena_new(0);
    WokDiagSink *d = wok_diag_new(a, g->name, g->src, strlen(g->src));
    WokNode *t = wok_parse_source(g->src, strlen(g->src), a, d);
    if (wok_diag_count(d) != 0) {
      fprintf(stderr, "  FAIL %s: golden source does not parse\n", g->name);
      wok_diag_render(d, stderr);
      golden_bad++;
    } else {
      char *got = wok_print_string(t, g->src, a);
      if (strcmp(got, g->want) != 0) {
        fprintf(stderr,
                "  FAIL %s: canonical form differs\n--- want ---\n%s--- got ---\n%s---\n",
                g->name, g->want, got);
        golden_bad++;
      }
    }
    wok_arena_free(a);
  }
  bad += golden_bad;

  if (bad) {
    fprintf(stderr, "print: %d failure(s) over %d corpus files and %zu goldens\n",
            bad, seen, sizeof goldens / sizeof *goldens);
    return 1;
  }
  printf(
      "print: %d corpus files and %zu goldens; tree identity, fixed point, zero "
      "diagnostics and layout invariants all hold\n",
      seen, sizeof goldens / sizeof *goldens);
  return 0;
}
