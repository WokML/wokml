// wok_layout -- stage 2. See wok_layout.h for the rules; this file implements
// them and nothing else.
//
// It includes wok_token.h for the token shape and the continuation-lead
// predicate, and it must never learn what a keyword is. If this file ever
// needs to know a spelling, the design has gone wrong.

#include "wok_layout.h"

#include <stdio.h>
#include <string.h>

typedef struct {
  WokToken *out;
  usize n, cap;
  u32 stack[WOK_LAYOUT_MAX_DEPTH];
  u32 top;
  WokDiagSink *diag;
} Filter;

static void put(Filter *f, WokKind k, const WokToken *at) {
  // The bound is proved, not hoped for: see invariant 5.
  if (f->n >= f->cap) WOK_UNREACHABLE();
  f->out[f->n++] = (WokToken){.off = at->off,
                              .len = 0,
                              .col = at->col,
                              .kind = (u8)k,
                              .word = WW_NONE,
                              .flags = 0};
}

static void put_token(Filter *f, const WokToken *t) {
  if (f->n >= f->cap) WOK_UNREACHABLE();
  f->out[f->n++] = *t;
}

// Pop every level deeper than c, emitting a DEDENT for each. Shared by L3 and
// L4 -- the difference between them is what happens AFTER the pop, not during.
static void pop_to(Filter *f, u32 c, const WokToken *at) {
  while (f->top > 0 && f->stack[f->top] > c) {
    f->top--;
    put(f, WT_DEDENT, at);
  }
}

WokTokens wok_layout(WokTokens in, WokArena *arena, WokDiagSink *diag) {
  Filter f = {.diag = diag};
  f.stack[0] = 1;
  // 3n + MAX_DEPTH: each input token contributes itself and at most one
  // NEWLINE, total DEDENTs cannot exceed total INDENTs which cannot exceed
  // the line count, and EOF closes at most MAX_DEPTH levels.
  f.cap = in.n * 3 + WOK_LAYOUT_MAX_DEPTH + 8;
  f.out = WOK_NEW_N(arena, WokToken, f.cap);

  u32 bracket = 0;
  u32 bracket_block_col = 0;
  const WokToken *bracket_open = nullptr;
  bool first_logical = true;

  for (usize i = 0; i < in.n; i++) {
    const WokToken *t = &in.tok[i];

    if ((WokKind)t->kind == WT_EOF) {
      if (bracket > 0 && bracket_open)
        wok_diag_add(diag, WOK_E_LAY_BRACKET, bracket_open->off, 1,
                     "unclosed bracket; it is still open at end of file");
      if (!first_logical) put(&f, WT_NEWLINE, t);
      pop_to(&f, 0, t);
      put_token(&f, t);
      break;
    }

    if ((t->flags & WOK_TF_FIRST_ON_LINE) != 0) {
      // L7 -- bracket abandonment. Layout is suppressed inside brackets, so an
      // unclosed opener would otherwise swallow the rest of the file into one
      // logical line. Indentation is the independent witness that survives:
      // a line STARTING AN ITEM at or left of the block column that was
      // current when the bracket opened cannot be inside it.
      if (bracket > 0 && !wok_token_is_continuation_lead(t) &&
          t->col <= bracket_block_col) {
        wok_diag_add(diag, WOK_E_LAY_BRACKET, bracket_open->off, 1,
                     "unclosed bracket; a new item begins at column %u, "
                     "which cannot be inside it",
                     t->col);
        bracket = 0;
        bracket_open = nullptr;
      }

      if (bracket == 0) {
        u32 c = t->col;
        if (wok_token_is_continuation_lead(t)) {
          // L4/L5. Close deeper regions, emit NO item separator, and do NOT
          // check the landing column: a continuation is not claiming to start
          // anything at a level, so there is no level for it to match. This
          // is what admits a hanging `in`, a leading `|`, a leading `+`.
          pop_to(&f, c, t);
        } else {
          // L3. A new item.
          if (!first_logical) put(&f, WT_NEWLINE, t);
          if (c > f.stack[f.top]) {
            if (f.top + 1 >= WOK_LAYOUT_MAX_DEPTH) {
              wok_diag_add(diag, WOK_E_LAY_DEPTH, t->off, t->len,
                           "indentation nested deeper than %d levels",
                           WOK_LAYOUT_MAX_DEPTH);
            } else {
              f.stack[++f.top] = c;
              put(&f, WT_INDENT, t);
            }
          } else if (c < f.stack[f.top]) {
            pop_to(&f, c, t);
            if (f.stack[f.top] != c) {
              // L6 -- repaired here, never forwarded. An inconsistent dedent
              // is not a grammar error and must not reach the parser.
              wok_diag_add(diag, WOK_E_LAY_DEDENT, t->off, t->len,
                           "this line starts at column %u, which matches no "
                           "open indentation level (nearest is %u)",
                           t->col, f.stack[f.top]);
              if (f.top + 1 < WOK_LAYOUT_MAX_DEPTH) {
                f.stack[++f.top] = c;
                put(&f, WT_INDENT, t);  // keeps the stream balanced
              }
            }
          }
        }
        first_logical = false;
      }
    }

    if (wok_kind_is_open_bracket((WokKind)t->kind)) {
      if (bracket == 0) {
        bracket_block_col = f.stack[f.top];
        bracket_open = t;
      }
      bracket++;
    } else if (wok_kind_is_close_bracket((WokKind)t->kind)) {
      if (bracket > 0) {
        bracket--;
        if (bracket == 0) bracket_open = nullptr;
      }
    }

    put_token(&f, t);
  }

  return (WokTokens){.tok = f.out, .n = f.n};
}

// ------------------------------------------------------------ invariants

bool wok_layout_check(WokTokens out, usize input_n, bool strict_brackets,
                      char *err, usize err_len) {
#define FAIL(...)                        \
  do {                                   \
    snprintf(err, err_len, __VA_ARGS__); \
    return false;                        \
  } while (0)

  if (out.n == 0) FAIL("empty output stream");
  if (out.tok[out.n - 1].kind != WT_EOF) FAIL("stream does not end at WT_EOF");
  if (out.n > input_n * 3 + WOK_LAYOUT_MAX_DEPTH + 8)
    FAIL("invariant 5: output %zu exceeds the bound for input %zu", out.n,
         input_n);

  u32 depth = 0;
  u32 cols[WOK_LAYOUT_MAX_DEPTH + 1];
  cols[0] = 1;
  u32 bracket = 0;
  bool balanced_brackets = true;
  usize layout_inside_brackets = SIZE_MAX;

  for (usize i = 0; i < out.n; i++) {
    WokKind k = (WokKind)out.tok[i].kind;
    if (k == WT_INDENT) {
      if (depth + 1 > WOK_LAYOUT_MAX_DEPTH) FAIL("invariant 1: depth overflow");
      // invariant 2 -- pushed columns strictly increase.
      if (out.tok[i].col <= cols[depth])
        FAIL("invariant 2: INDENT at column %u does not exceed enclosing %u",
             out.tok[i].col, cols[depth]);
      cols[++depth] = out.tok[i].col;
      // invariant 3 -- no empty block region.
      if (i + 1 < out.n && out.tok[i + 1].kind == WT_DEDENT)
        FAIL("invariant 3: INDENT immediately followed by DEDENT at %zu", i);
    } else if (k == WT_DEDENT) {
      if (depth == 0) FAIL("invariant 1: DEDENT with no matching INDENT at %zu", i);
      depth--;
    }
    if (bracket > 0 && (k == WT_INDENT || k == WT_DEDENT || k == WT_NEWLINE) &&
        layout_inside_brackets == SIZE_MAX)
      layout_inside_brackets = i;
    if (wok_kind_is_open_bracket(k)) bracket++;
    else if (wok_kind_is_close_bracket(k)) {
      if (bracket == 0) balanced_brackets = false;
      else bracket--;
    }
  }
  if (bracket != 0) balanced_brackets = false;

  if (depth != 0) FAIL("invariant 1: %u INDENT(s) never closed", depth);
  if (strict_brackets && balanced_brackets && layout_inside_brackets != SIZE_MAX)
    FAIL("invariant 4: layout token inside a bracket group at %zu",
         layout_inside_brackets);
  return true;
#undef FAIL
}
