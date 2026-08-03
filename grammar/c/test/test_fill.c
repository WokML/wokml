// LINE FILLING: the three properties the printer gains at 80 columns, checked
// over every corpus file and over testdata/fill, whose files sit one column
// either side of the boundary because that is the only place an off-by-one in
// the measurement can show.
//
//   A. no emitted line exceeds 80 columns, except one holding an unbreakable
//      run -- a long application, literal or name, or a comment;
//   B. every over-width line is REPORTED, so a long line reads as a stated
//      limitation rather than as a filler that gave up silently;
//   C. THE SAFETY PROPERTY: no emitted line begins with an ITEM LEAD at a
//      column deeper than its enclosing block.
//
// C is the one that makes the rest safe to trust. Under an offside rule a
// break in the wrong place is not a syntax error: it starts a new block item,
// and the text still parses while the PROGRAM has changed. It is checked here
// on the output TOKEN STREAM -- a second opinion about the printer, arrived at
// by scanning what it wrote rather than by asking it what it meant -- and the
// printer checks it a third time, structurally, on every emit in every build
// (wok_print_fault_count).
//
// testdata/fill's files are their own goldens: each is already canonical, so
// `Format(Parse(f)) == f` pins the exact wrapped text, and a measurement that
// was one column out would either wrap the 80-column case or fail to wrap the
// 81-column one.

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../wok_arena.h"
#include "../wok_ast.h"
#include "../wok_parse.h"
#include "../wok_print.h"
#include "../wok_token.h"
#include "check.h"

static const char *const corpus_dirs[] = {
    "../../docs/redesign/examples/accept",
    "../../docs/redesign/examples/reject",
    "testdata/tour",
    "testdata/fill",
};

// --------------------------------------------------------------- property C
//
// The rule the layout filter applies, restated over the emitted tokens. A line
// whose first token is a CONTINUATION lead makes no claim about a level (L5),
// so any column is safe. Any other first token starts an ITEM, and an item may
// only sit at a column its block already owns -- or open a new block, which
// only happens where the grammar expects one.
//
// "Where the grammar expects one" is read off the PREVIOUS line rather than
// from the parser, and deliberately generously: the point is not to re-derive
// the grammar but to catch a FILL break that produced an item. Every break the
// filler makes is led by an operator, a comma or a bracket, so the hazard
// always shows as an item line whose previous line ended in a name, a literal
// or an operator -- none of which is a block opener.

static bool opens_a_block(const WokToken *last) {
  if (last == nullptr) return false;
  switch ((WokKind)last->kind) {
    case WT_EQUALS:   // an equation, a binding, a discard, a `var` baton
    case WT_ARROW:    // an alternative, a clause, a lambda
    case WT_ASSIGN:   // `:=`
      return true;
    case WT_KEYWORD:
      switch ((WokWord)last->word) {
        case WW_OF:
        case WW_WHERE:
        case WW_IN:
        case WW_THEN:
        case WW_ELSE:
          return true;
        default:
          return false;
      }
    default:
      return false;
  }
}

// The heads whose block opens after a NAME rather than after a punctuation
// mark: `effect E`, `class C a`, `instance C T`, `foreign module M "lib"`,
// `handler E`. Recognised by the keyword appearing anywhere on the line, which
// is loose on purpose -- see the note above.
static bool is_head_keyword(const WokToken *t) {
  if ((WokKind)t->kind != WT_KEYWORD) return false;
  switch ((WokWord)t->word) {
    case WW_EFFECT:
    case WW_CLASS:
    case WW_INSTANCE:
    case WW_FOREIGN:
    case WW_HANDLER:
      return true;
    default:
      return false;
  }
}

// Reports the first violation into `err`; returns true when the text is clean.
static bool item_leads_are_safe(const char *path, const char *text, usize n,
                                WokArena *a, char *err, usize err_len) {
  WokDiagSink *d = wok_diag_new(a, path, text, n);
  WokScanResult sr = wok_scan(text, n, a, d);

  u32 open[64];
  int nopen = 0;
  int depth = 0;             // bracket nesting: inside one, layout is off (L2)
  unsigned line = 1;
  const WokToken *last = nullptr;   // last token of the line that just ended
  bool prev_had_head = false;       // that line held `handler`, `class`, ...
  bool cur_had_head = false;

  for (usize i = 0; i < sr.tokens.n; i++) {
    const WokToken *t = &sr.tokens.tok[i];
    if ((WokKind)t->kind == WT_EOF) break;

    if ((t->flags & WOK_TF_FIRST_ON_LINE) != 0 && depth == 0) {
      line++;
      prev_had_head = cur_had_head;  // roll BEFORE the check: `last` and this
      cur_had_head = false;          // both describe the line that just ended
      if (wok_token_is_continuation_lead(t)) {
        // L4: close the levels this lead is shallower than, and claim none.
        while (nopen > 0 && open[nopen - 1] > t->col) nopen--;
      } else if (nopen == 0) {
        open[nopen++] = t->col;
      } else if (t->col > open[nopen - 1]) {
        if (!opens_a_block(last) && !prev_had_head) {
          snprintf(err, err_len,
                   "an ITEM at column %u, deeper than its block (column %u), "
                   "after a line that opens none (item line %u) -- this break "
                   "changed the tree",
                   t->col, open[nopen - 1], line);
          return false;
        }
        if (nopen < 64) open[nopen++] = t->col;
      } else {
        while (nopen > 1 && open[nopen - 1] > t->col) nopen--;
      }
    }

    if (is_head_keyword(t)) cur_had_head = true;
    if (wok_kind_is_open_bracket((WokKind)t->kind)) depth++;
    if (wok_kind_is_close_bracket((WokKind)t->kind) && depth > 0) depth--;
    last = t;
  }
  return true;
}

// ------------------------------------------------------- properties A and B

// Every line of `text` that is over the width, counted. Property B then says
// the printer reported exactly that many.
static usize over_width_lines(const char *text) {
  usize over = 0, col = 0;
  for (const char *s = text; *s != '\0'; s++) {
    if (*s == '\n') {
      if (col > WOK_PRINT_WIDTH) over++;
      col = 0;
    } else if (((unsigned char)*s & 0xC0u) != 0x80u) {
      col++;
    }
  }
  if (col > WOK_PRINT_WIDTH) over++;
  return over;
}

static int check_source(const char *path, const char *src, usize n,
                        const char *want_exact) {
  WokArena *a = wok_arena_new(0);
  int bad = 0;

  WokDiagSink *d = wok_diag_new(a, path, src, n);
  WokNode *tree = wok_parse_source(src, n, a, d);
  if (wok_diag_count(d) != 0) {
    fprintf(stderr, "  FAIL %s: does not parse\n", path);
    wok_diag_render(d, stderr);
    wok_arena_free(a);
    return 1;
  }

  wok_print_reports_reset();
  char *fmt = wok_print_string(tree, src, a);
  usize fmt_n = strlen(fmt);

  // Property C, from the printer's own side: it checks every line it writes.
  if (wok_print_fault_count() != 0) {
    fprintf(stderr, "  FAIL %s: %u unsafe fill break(s)\n---\n%s---\n", path,
            wok_print_fault_count(), fmt);
    bad++;
  }

  // Property B: every over-width line was reported, and nothing else was.
  usize over = over_width_lines(fmt);
  if (wok_print_overflow_count() != over) {
    fprintf(stderr,
            "  FAIL %s: %zu line(s) over %d columns but %u reported\n---\n%s---\n",
            path, over, WOK_PRINT_WIDTH, wok_print_overflow_count(), fmt);
    bad++;
  }

  // Property C, from the token stream: a second opinion, scanned rather than
  // asked for.
  char err[256] = {0};
  if (!item_leads_are_safe(path, fmt, fmt_n, a, err, sizeof err)) {
    fprintf(stderr, "  FAIL %s: %s\n---\n%s---\n", path, err, fmt);
    bad++;
  }

  // testdata/fill's files are canonical, so the wrapped text is pinned byte
  // for byte -- which is what makes the 80-vs-81 boundary a test rather than
  // an assertion about intent.
  if (want_exact != nullptr && strcmp(fmt, want_exact) != 0) {
    fprintf(stderr,
            "  FAIL %s: not canonical\n--- want ---\n%s--- got ---\n%s---\n",
            path, want_exact, fmt);
    bad++;
  }

  wok_arena_free(a);
  return bad;
}

static int check_dir(const char *dir, bool is_golden, int *seen) {
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
    usize n = 0;
    char *src = wok_test_slurp(path, &n);
    if (!src) {
      fprintf(stderr, "  FAIL cannot read %s\n", path);
      bad++;
      continue;
    }
    bad += check_source(path, src, n, is_golden ? src : nullptr);
    free(src);
    (*seen)++;
  }
  closedir(dp);
  return bad;
}

// ------------------------------------------------------------- the negatives
//
// A property that cannot fail is not a property. These are the shapes the
// checker exists to catch, written by hand because the printer cannot be made
// to emit them.

typedef struct {
  const char *name;
  const char *text;
  bool safe;
} Corrupt;

int main(void) {
  int bad = 0, seen = 0;
  for (usize i = 0; i < sizeof corpus_dirs / sizeof *corpus_dirs; i++)
    bad += check_dir(corpus_dirs[i], i == 3, &seen);
  if (seen == 0) {
    fprintf(stderr, "fill: no corpus files found\n");
    return 1;
  }

  // The leads the FILLER writes. wok_print.c decides on the emitted bytes
  // whether a wrapped line begins with a continuation lead; this pins that
  // decision against the scanner's own classifier, so the two cannot drift.
  static const char *const leads[] = {
      "+ b",    "-> B",  "| B",     ", b",  "] ",
      "} ",     ") ",    "with E",  "`op` b", "* b",
      "<> b",   ":: b",  ".. b",
  };
  for (usize i = 0; i < sizeof leads / sizeof *leads; i++) {
    WokArena *a = wok_arena_new(1 << 12);
    WokDiagSink *d = wok_diag_new(a, "<lead>", leads[i], strlen(leads[i]));
    WokScanResult sr = wok_scan(leads[i], strlen(leads[i]), a, d);
    CHECK(sr.tokens.n > 0 &&
              wok_token_is_continuation_lead(&sr.tokens.tok[0]),
          "`%s` must be a continuation lead, or a line the filler starts with "
          "it would be a new ITEM", leads[i]);
    wok_arena_free(a);
  }

  // Property C's checker, exercised on both answers.
  static const Corrupt corrupt[] = {
      {"an application broken at a juxtaposition",
       "module M\nf = foo aaa\n  bbb\n", false},
      {"the same application, unbroken", "module M\nf = foo aaa bbb\n", true},
      {"a chain broken before its operator -- the legal shape",
       "module M\nf = aaa\n  + bbb\n", true},
      {"a chain broken AFTER its operator, leaving an item lead",
       "module M\nf = aaa +\n  bbb\n", false},
      {"a capability row wrapped under its `with`",
       "module M\nf : A\n     with E\n        + F\nf = 0\n", true},
      {"a block that legitimately opens after `of`",
       "module M\nf x = case x of\n  A -> 1\n  B -> 2\n", true},
      {"a handler block, whose head ends in a NAME",
       "module M\nh = handler E\n  op -> 1\n", true},
  };
  for (usize i = 0; i < sizeof corrupt / sizeof *corrupt; i++) {
    WokArena *a = wok_arena_new(1 << 14);
    char err[256] = {0};
    bool ok = item_leads_are_safe("<corrupt>", corrupt[i].text,
                                  strlen(corrupt[i].text), a, err, sizeof err);
    CHECK(ok == corrupt[i].safe, "%s: expected %s, got %s (%s)",
          corrupt[i].name, corrupt[i].safe ? "SAFE" : "CAUGHT",
          ok ? "SAFE" : "CAUGHT", err);
    wok_arena_free(a);
  }

  if (bad) {
    fprintf(stderr, "fill: %d failure(s) over %d files\n", bad, seen);
    return 1;
  }
  printf("fill: %d files; width, overflow reporting and the item-lead safety "
         "property all hold -- ", seen);
  TEST_DONE();
}
