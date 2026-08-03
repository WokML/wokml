#include "wok_shape.h"

#include <string.h>

#include "wok_token.h"

typedef struct {
  u32 off, len;
  bool first_on_line;
  bool cont_lead;  // this item is a token the layout filter reads as a
                   // CONTINUATION lead, so its line is a wrapped one
} Item;

typedef struct {
  char *buf;
  usize len, cap;
} Out;

static void put(Out *o, const char *p, usize n) {
  if (o->len + n >= o->cap) return;  // cap is a proved bound; see wok_shape
  memcpy(o->buf + o->len, p, n);
  o->len += n;
}

static void put_c(Out *o, char c) { put(o, &c, 1); }

// A comment's column, and whether it opens its line. WokComment carries only a
// span, so both are recovered from the source. Tabs cannot appear in
// indentation (the scanner rejects them), so counting bytes back to the
// newline gives the exact column.
static u32 line_col(const char *src, u32 off, bool *first) {
  u32 col = 1;
  u32 i = off;
  bool only_space = true;
  while (i > 0 && src[i - 1] != '\n') {
    i--;
    col++;
    if (src[i] != ' ' && src[i] != '\t') only_space = false;
  }
  *first = only_space;
  return col;
}

char *wok_shape(const char *restrict src, usize src_len, WokArena *arena,
                WokDiagSink *diag) {
  WokScanResult sr = wok_scan(src, src_len, arena, diag);

  // Every emitted byte is either a source byte, one clamped space, or one
  // newline per line, so twice the source plus a small constant is a bound.
  Out o = {.cap = src_len * 2 + 64, .len = 0};
  o.buf = WOK_NEW_N(arena, char, o.cap);

  usize ti = 0, ci = 0;
  const WokToken *prev = nullptr;
  u32 prev_end = 0;
  bool wrote_anything = false;

  for (;;) {
    // Merge the token stream and the comment list by source position. A
    // comment is a first-class item here: a formatter that dropped one must
    // not be reported as canonical.
    bool have_tok = ti < sr.tokens.n &&
                    (WokKind)sr.tokens.tok[ti].kind != WT_EOF;
    bool have_com = ci < sr.ncomments;
    if (!have_tok && !have_com) break;

    Item it;
    if (have_tok && (!have_com || sr.tokens.tok[ti].off < sr.comments[ci].off)) {
      const WokToken *t = &sr.tokens.tok[ti++];
      it = (Item){.off = t->off,
                  .len = t->len,
                  .first_on_line = (t->flags & WOK_TF_FIRST_ON_LINE) != 0,
                  .cont_lead = wok_token_is_continuation_lead(t)};
      prev = t;
    } else {
      const WokComment *c = &sr.comments[ci++];
      bool first = false;
      (void)line_col(src, c->off, &first);
      it = (Item){.off = c->off, .len = c->len, .first_on_line = first,
                  .cont_lead = false};
      prev = nullptr;
    }

    if (it.first_on_line) {
      if (wrote_anything) put_c(&o, '\n');
      if (it.cont_lead) {
        // A WRAPPED line, and the one place indentation is not local: the
        // filler aligns a capability row under its `with`, so renaming the
        // function moves that column and reflows every continuation line
        // under it. Comparing those columns exactly would fail --check on a
        // rename, which is the churn arrow alignment was already exempted to
        // avoid. WHERE the break falls is still compared -- that is line
        // structure, and this line begins where it began.
        put_c(&o, ' ');
      } else {
        bool ignored = false;
        u32 col = prev && prev->off == it.off
                           ? prev->col
                           : line_col(src, it.off, &ignored);
        for (u32 k = 1; k < col; k++) put_c(&o, ' ');  // exactly
      }
    } else if (wrote_anything) {
      // Interior gap, clamped: this is the whole trick.
      if (it.off > prev_end) put_c(&o, ' ');
    }

    // A block comment may span lines; its interior is copied verbatim, since
    // reflowing it would be a change the formatter is not allowed to make.
    put(&o, src + it.off, it.len);
    prev_end = it.off + it.len;
    wrote_anything = true;
  }

  o.buf[o.len < o.cap ? o.len : o.cap - 1] = '\0';
  return o.buf;
}
