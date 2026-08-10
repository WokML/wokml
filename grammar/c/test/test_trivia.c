// COMMENT TRIVIA -- the property that decides whether `wok fmt` can be run
// over a file a human wrote and kept.
//
// The formatter's existing contract is about the PROGRAM: reformatting must
// not change the tree. Comments are deliberately outside that contract --
// two files differing only in their comments are the same program, so the
// dump and the hash cannot see them. Preservation is therefore its own
// property, and this file is where it is asserted:
//
//   1. comments(Format(t)) == comments(t)      -- same texts, SAME ORDER
//   2. Dump(Parse(Format(t))) == Dump(t)       -- and none of it leaked into
//                                                 program identity
//   3. Format(Parse(Format(t))) == Format(t)   -- still a fixed point
//   4. Format(t) parses with zero diagnostics
//   5. the trivia index is still free: sizeof(WokNode) == 16
//
// Property 1 alone would pass a formatter that attached every comment to the
// wrong item in a consistent order, so the goldens below pin each attachment
// rule of design section 5 to an exact text as well.

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
#include "../wok_diag.h"
#include "../wok_parse.h"
#include "../wok_print.h"
#include "../wok_sexpr.h"
#include "../wok_token.h"
#include "../wok_trivia.h"
#include "check.h"

// Property 5, restated where a reader of this file will see it: the index
// lives in padding the header already had, so a tree with no comments costs
// exactly what it cost before trivia existed.
static_assert(sizeof(WokNode) == 16, "the trivia index must stay free");
static_assert(offsetof(WokNode, slot) == 16, "slots still follow the header");

static const char *const dirs[] = {
    "testdata/trivia",
    "../../test/redesign/accept",
    "../../test/redesign/reject",
    "testdata/tour",
};

// ------------------------------------------------------- comment extraction

enum { MAX_COMMENTS = 512 };

typedef struct {
  const char *at[MAX_COMMENTS];
  usize len[MAX_COMMENTS];
  usize n;
  bool overflow;
} Comments;

// Trailing blanks are not part of what the author wrote, and the printer
// drops them rather than leave whitespace at the end of a line, so the
// comparison is over the text a reader sees.
static usize rtrim(const char *p, usize len) {
  while (len != 0 && (p[len - 1] == ' ' || p[len - 1] == '\t' ||
                      p[len - 1] == '\r'))
    len--;
  return len;
}

static Comments comments_of(const char *path, const char *src, usize n,
                            WokArena *a) {
  Comments c = {.n = 0, .overflow = false};
  WokDiagSink *d = wok_diag_new(a, path, src, n);
  WokScanResult sr = wok_scan(src, n, a, d);
  for (usize i = 0; i < sr.ncomments; i++) {
    if (c.n == MAX_COMMENTS) {
      c.overflow = true;
      break;
    }
    c.at[c.n] = src + sr.comments[i].off;
    c.len[c.n] = rtrim(c.at[c.n], sr.comments[i].len);
    c.n++;
  }
  return c;
}

static bool comments_equal(const Comments *x, const Comments *y, usize *where) {
  if (x->n != y->n) {
    *where = x->n < y->n ? x->n : y->n;
    return false;
  }
  for (usize i = 0; i < x->n; i++)
    if (x->len[i] != y->len[i] || memcmp(x->at[i], y->at[i], x->len[i]) != 0) {
      *where = i;
      return false;
    }
  return true;
}

static void show(FILE *out, const Comments *c, usize i) {
  if (i >= c->n) {
    (void)fprintf(out, "<none>");
    return;
  }
  (void)fwrite(c->at[i], 1, c->len[i], out);
}

// -------------------------------------------------------------- properties

static int check_source(const char *path, const char *src, usize n,
                        bool require_comments) {
  WokArena *a = wok_arena_new(0);
  int bad = 0;

  WokDiagSink *d = wok_diag_new(a, path, src, n);
  WokNode *tree = wok_parse_source(src, n, a, d);
  if (wok_diag_count(d) != 0) {
    (void)fprintf(stderr, "  FAIL %s: the original does not parse\n", path);
    wok_diag_render(d, stderr);
    wok_arena_free(a);
    return 1;
  }
  char *dump_one = wok_sexpr_dump_string(tree, src, a);
  char *fmt = wok_print_string(tree, src, a);
  usize fmt_n = strlen(fmt);

  // Property 4.
  WokDiagSink *d2 = wok_diag_new(a, path, fmt, fmt_n);
  WokNode *again = wok_parse_source(fmt, fmt_n, a, d2);
  if (wok_diag_count(d2) != 0) {
    (void)fprintf(stderr,
                  "  FAIL %s: formatted output has %zu diagnostic(s)\n---\n%s---\n",
                  path, wok_diag_count(d2), fmt);
    wok_diag_render(d2, stderr);
    wok_arena_free(a);
    return 1;
  }

  // Property 1.
  Comments before = comments_of(path, src, n, a);
  Comments after = comments_of(path, fmt, fmt_n, a);
  usize where = 0;
  if (before.overflow || after.overflow) {
    (void)fprintf(stderr, "  FAIL %s: more than %d comments\n", path,
                  MAX_COMMENTS);
    bad++;
  } else if (!comments_equal(&before, &after, &where)) {
    (void)fprintf(stderr, "  FAIL %s: comment %zu of %zu changed\n    was: ",
                  path, where, before.n);
    show(stderr, &before, where);
    (void)fprintf(stderr, "\n    now: ");
    show(stderr, &after, where);
    (void)fprintf(stderr, "\n    (%zu comments in, %zu out)\n---\n%s---\n",
                  before.n, after.n, fmt);
    bad++;
  } else if (require_comments && before.n == 0) {
    (void)fprintf(stderr, "  FAIL %s: no comments, so this file proves nothing\n",
                  path);
    bad++;
  }

  // Property 2. The dump is the canonical identity of a program; comments are
  // not part of it, and this is what says so.
  char *dump_two = wok_sexpr_dump_string(again, fmt, a);
  if (dump_one == nullptr || dump_two == nullptr ||
      strcmp(dump_one, dump_two) != 0) {
    (void)fprintf(stderr, "  FAIL %s: comments leaked into the PROGRAM\n", path);
    bad++;
  }

  // Property 3.
  char *fmt2 = wok_print_string(again, fmt, a);
  if (strcmp(fmt, fmt2) != 0) {
    (void)fprintf(stderr,
                  "  FAIL %s: not a fixed point with comments\n---\n%s---\n%s---\n",
                  path, fmt, fmt2);
    bad++;
  }

  wok_arena_free(a);
  return bad;
}

static int check_file(const char *path, bool require_comments) {
  usize n = 0;
  char *src = wok_test_slurp(path, &n);
  if (src == nullptr) {
    (void)fprintf(stderr, "  FAIL cannot read %s\n", path);
    return 1;
  }
  int bad = check_source(path, src, n, require_comments);
  free(src);
  return bad;
}

static int check_dir(const char *dir, int *seen) {
  DIR *dp = opendir(dir);
  if (dp == nullptr) {
    (void)fprintf(stderr, "  FAIL cannot open %s\n", dir);
    return 1;
  }
  int bad = 0;
  struct dirent *e;
  while ((e = readdir(dp)) != nullptr) {
    usize len = strlen(e->d_name);
    if (len < 5 || strcmp(e->d_name + len - 4, ".wok") != 0) continue;
    char path[1024];
    (void)snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
    // Every corpus file in these directories carries comments; a file that
    // lost the lot would otherwise pass property 1 by having none on both
    // sides.
    bad += check_file(path, true);
    (*seen)++;
  }
  closedir(dp);
  return bad;
}

// ----------------------------------------------------------------- goldens
//
// One per attachment rule of design section 5, pinned to an exact text. This
// is what stops a consistent but WRONG attachment from satisfying the round
// trip: the order would still hold while every comment sat on the wrong item.

typedef struct {
  const char *name;
  const char *src;
  const char *want;
} Golden;

static const Golden goldens[] = {
    // Rule 1, at all four granularities the rule names.
    {"rule1/leading",
     "module M\n"
     "-- leads a declaration\n"
     "f =\n"
     "  -- leads a statement\n"
     "  1\n"
     "g x = case x of\n"
     "  -- leads an alternative\n"
     "  A -> 1\n"
     "h = handler St\n"
     "  -- leads a clause\n"
     "  get -> 1\n",
     "module M\n"
     "\n"
     "-- leads a declaration\n"
     "f =\n"
     "  -- leads a statement\n"
     "  1\n"
     "\n"
     "g x = case x of\n"
     "  -- leads an alternative\n"
     "  A -> 1\n"
     "\n"
     "h = handler St\n"
     "  -- leads a clause\n"
     "  get -> 1\n"},

    // Rule 2. Two spaces, always -- trailing comments are NOT aligned, for
    // the same reason `--check` ignores arrow alignment: it is non-local.
    {"rule2/trailing",
     "module M\n"
     "f = 1     -- trails a declaration\n"
     "g x = case x of\n"
     "  A -> 1 -- trails an alternative\n"
     "h = handler St\n"
     "  get -> 1        -- trails a clause\n",
     "module M\n"
     "\n"
     "f = 1  -- trails a declaration\n"
     "\n"
     "g x = case x of\n"
     "  A -> 1  -- trails an alternative\n"
     "\n"
     "h = handler St\n"
     "  get -> 1  -- trails a clause\n"},

    // Rule 3, in both of its forms: the end of a block and the end of a file.
    {"rule3/closes-block-and-file",
     "module M\n"
     "f =\n"
     "  let a = 1\n"
     "  a\n"
     "  -- closes the block\n"
     "g = 2\n"
     "-- closes the file\n",
     "module M\n"
     "\n"
     "f =\n"
     "  let a = 1\n"
     "  a\n"
     "  -- closes the block\n"
     "\n"
     "g = 2\n"
     "-- closes the file\n"},

    // Rule 4. One blank line survives between two items of a block; two or
    // more collapse to one; the block's first item keeps none, because
    // decision 4 forbids a block that opens with a blank line.
    {"rule4/blank-before",
     "module M\n"
     "f =\n"
     "\n"
     "  let a = 1\n"
     "\n"
     "  let b = 2\n"
     "\n"
     "\n"
     "\n"
     "  a + b\n",
     "module M\n"
     "\n"
     "f =\n"
     "  let a = 1\n"
     "\n"
     "  let b = 2\n"
     "\n"
     "  a + b\n"},

    // Rule 4 again: the comment block counts as part of the item, so the
    // blank line ABOVE a leading comment is the one that is recorded.
    {"rule4/blank-above-a-comment",
     "module M\n"
     "f =\n"
     "  let a = 1\n"
     "\n"
     "  -- leads the next statement\n"
     "  a\n",
     "module M\n"
     "\n"
     "f =\n"
     "  let a = 1\n"
     "\n"
     "  -- leads the next statement\n"
     "  a\n"},

    // A comment on the very first line, with nothing above it: the output
    // must not open with a blank line.
    {"edge/first-line-of-file",
     "-- the first line\n"
     "module M\n"
     "f = 1\n",
     "-- the first line\n"
     "module M\n"
     "\n"
     "f = 1\n"},

    // Indented past the item it precedes: the author left it inside the block
    // that just ended, so it closes that block rather than leading what comes
    // next. Between two items of ONE block it stays a leading comment, which
    // the second half of this golden pins.
    {"rule3/deeper-than-the-next-item",
     "module M\n"
     "f x =\n"
     "  case x of\n"
     "    A -> 1\n"
     "  -- closes the case, not a lead for g\n"
     "g x = case x of\n"
     "  A -> 1\n"
     "      -- between two alternatives of one block\n"
     "  B -> 2\n",
     "module M\n"
     "\n"
     "f x =\n"
     "  case x of\n"
     "    A -> 1\n"
     "  -- closes the case, not a lead for g\n"
     "\n"
     "g x = case x of\n"
     "  A -> 1\n"
     "  -- between two alternatives of one block\n"
     "  B -> 2\n"},

    // A block comment is emitted VERBATIM, interior line breaks and original
    // interior columns included. A formatter may move a comment; it may not
    // rewrite one.
    {"edge/block-comment",
     "module M\n"
     "{- a block comment\n"
     "   over three lines\n"
     "   not reflowed -}\n"
     "f = 1 {- and one that trails -}\n",
     "module M\n"
     "\n"
     "{- a block comment\n"
     "   over three lines\n"
     "   not reflowed -}\n"
     "f = 1  {- and one that trails -}\n"},

    // A signature and its equation are ONE unit, so no blank line is written
    // between them -- and a comment between them does not introduce one.
    {"edge/comment-inside-one-unit",
     "module M\n"
     "f : U64\n"
     "-- between a signature and its equation\n"
     "f = 1\n",
     "module M\n"
     "\n"
     "f : U64\n"
     "-- between a signature and its equation\n"
     "f = 1\n"},
};

static int check_golden(const Golden *g) {
  WokArena *a = wok_arena_new(0);
  usize n = strlen(g->src);
  WokDiagSink *d = wok_diag_new(a, g->name, g->src, n);
  WokNode *tree = wok_parse_source(g->src, n, a, d);
  int bad = 0;
  if (wok_diag_count(d) != 0) {
    (void)fprintf(stderr, "  FAIL %s: source does not parse\n", g->name);
    wok_diag_render(d, stderr);
    wok_arena_free(a);
    return 1;
  }
  char *got = wok_print_string(tree, g->src, a);
  if (strcmp(got, g->want) != 0) {
    (void)fprintf(stderr, "  FAIL %s\n--- want ---\n%s--- got ---\n%s---\n",
                  g->name, g->want, got);
    bad++;
  }
  wok_arena_free(a);
  // A golden is pinned to an exact text already; one of them deliberately
  // carries no comment at all, to pin the blank-line rule on its own.
  bad += check_source(g->name, g->src, n, false);
  return bad;
}

int main(void) {
  int bad = 0, seen = 0;
  for (usize i = 0; i < sizeof dirs / sizeof *dirs; i++)
    bad += check_dir(dirs[i], &seen);
  if (seen == 0) {
    (void)fprintf(stderr, "trivia: no corpus files found\n");
    return 1;
  }
  for (usize i = 0; i < sizeof goldens / sizeof *goldens; i++)
    bad += check_golden(&goldens[i]);

  if (bad != 0) {
    (void)fprintf(stderr, "trivia: %d failure(s) over %d files and %zu goldens\n",
                  bad, seen, sizeof goldens / sizeof *goldens);
    return 1;
  }
  (void)printf(
      "trivia: %d files and %zu goldens; comment text and order preserved, "
      "program identity untouched, fixed point holds\n",
      seen, sizeof goldens / sizeof *goldens);
  return 0;
}
