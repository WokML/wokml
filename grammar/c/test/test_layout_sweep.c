// The exhaustive layout sweep.
//
// This test is the reason stage 2 is a separate, pure function over token
// streams. It never touches a source file: it SYNTHESISES token streams
// directly, so the whole input space of the layout rule can be enumerated
// rather than sampled.
//
// Two things are checked for every synthesised stream:
//
//   1. the five invariants of wok_layout.h 5.3, which are stated
//      independently of how the filter is implemented -- balance, strictly
//      increasing levels, no empty block region, no layout token inside
//      brackets, and the output bound;
//   2. agreement, token for token, with a reference model written separately
//      below over COLUMNS rather than tokens.
//
// The reference model is an executable statement of the rule, not a second
// derivation of it. Its value is that a transcription slip in either one
// shows up on some sequence, and the sweep is exhaustive, so "some sequence"
// means "this sweep".

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <stdio.h>

#include "../wok_arena.h"
#include "../wok_layout.h"
#include "../wok_token.h"
#include "check.h"

#define MAX_LINES 8

// ----------------------------------------------------- the reference model

typedef struct {
  unsigned char col;
  bool cont;  // this line begins with a continuation lead
} RefLine;

typedef struct {
  WokKind kind[256];
  usize n;
} RefOut;

static void ref_emit(RefOut *o, WokKind k) {
  if (o->n < 256) o->kind[o->n++] = k;
}

// L1-L8, restated over a column sequence.
static bool ref_layout(const RefLine *lines, usize nlines, RefOut *o) {
  int stack[WOK_LAYOUT_MAX_DEPTH];
  int top = 0;
  stack[0] = 1;
  bool first = true;
  bool fault = false;
  o->n = 0;

  for (usize i = 0; i < nlines; i++) {
    int c = lines[i].col;
    if (lines[i].cont) {
      // L4/L5: close deeper levels, no separator, no landing check.
      while (top > 0 && stack[top] > c) {
        top--;
        ref_emit(o, WT_DEDENT);
      }
    } else {
      // L3.
      if (!first) ref_emit(o, WT_NEWLINE);
      if (c > stack[top]) {
        stack[++top] = c;
        ref_emit(o, WT_INDENT);
      } else if (c < stack[top]) {
        while (top > 0 && stack[top] > c) {
          top--;
          ref_emit(o, WT_DEDENT);
        }
        if (stack[top] != c) {
          fault = true;  // L6: reported, then repaired by adopting c
          stack[++top] = c;
          ref_emit(o, WT_INDENT);
        }
      }
    }
    first = false;
    ref_emit(o, lines[i].cont ? WT_VARSYM : WT_VARID);
  }

  // L8.
  if (!first) ref_emit(o, WT_NEWLINE);
  while (top > 0) {
    top--;
    ref_emit(o, WT_DEDENT);
  }
  ref_emit(o, WT_EOF);
  return fault;
}

// ------------------------------------------------------------- the sweep

// A synthesised stream: one token per line, at the given column. A
// continuation line uses WT_VARSYM (an operator lead); an item line uses
// WT_VARID. Neither carries a spelling, which is the point -- the filter
// cannot be reading one.
static WokTokens synth(const RefLine *lines, usize nlines, WokArena *a) {
  WokToken *t = WOK_NEW_N(a, WokToken, nlines + 1);
  for (usize i = 0; i < nlines; i++) {
    t[i] = (WokToken){.off = (u32)i,
                      .len = 1,
                      .col = lines[i].col,
                      .kind = (u8)(lines[i].cont ? WT_VARSYM : WT_VARID),
                      .word = WW_NONE,
                      .flags = WOK_TF_FIRST_ON_LINE};
  }
  t[nlines] = (WokToken){.off = (u32)nlines,
                         .len = 0,
                         .col = 1,
                         .kind = (u8)WT_EOF,
                         .word = WW_NONE,
                         .flags = WOK_TF_FIRST_ON_LINE};
  return (WokTokens){.tok = t, .n = nlines + 1};
}

static const char *kind_short(WokKind k) {
  switch (k) {
    case WT_NEWLINE: return "NL";
    case WT_INDENT: return "IN";
    case WT_DEDENT: return "DE";
    case WT_EOF: return "EOF";
    default: return "tok";
  }
}

static int run_one(const RefLine *lines, usize nlines, unsigned long id,
                   int *faults_seen) {
  WokArena *a = wok_arena_new(1 << 16);
  WokDiagSink *d = wok_diag_new(a, "<sweep>", "", 0);
  WokTokens in = synth(lines, nlines, a);
  WokTokens out = wok_layout(in, a, d);

  char err[256];
  int rc = 0;
  if (!wok_layout_check(out, in.n, true, err, sizeof err)) {
    fprintf(stderr, "  FAIL seq %lu: %s\n", id, err);
    rc = 1;
  }

  RefOut ref;
  bool ref_fault = ref_layout(lines, nlines, &ref);
  if (ref_fault) (*faults_seen)++;

  bool got_fault = wok_diag_count(d) > 0;
  if (got_fault != ref_fault) {
    fprintf(stderr, "  FAIL seq %lu: fault mismatch (filter=%d model=%d)\n", id,
            (int)got_fault, (int)ref_fault);
    rc = 1;
  }
  if (out.n != ref.n) {
    fprintf(stderr, "  FAIL seq %lu: length %zu vs model %zu\n", id, out.n,
            ref.n);
    rc = 1;
  } else {
    for (usize i = 0; i < out.n; i++) {
      if ((WokKind)out.tok[i].kind != ref.kind[i]) {
        fprintf(stderr, "  FAIL seq %lu: token %zu is %s, model says %s\n", id,
                i, kind_short((WokKind)out.tok[i].kind),
                kind_short(ref.kind[i]));
        rc = 1;
        break;
      }
    }
  }
  wok_arena_free(a);
  return rc;
}

int main(void) {
  unsigned long tried = 0, failed = 0;
  int faults = 0;

  // Sweep A: every column sequence of length 6 over columns 1..4, item leads
  // only. 4^6 = 4096.
  for (unsigned long v = 0; v < 4096; v++) {
    RefLine lines[6];
    unsigned long x = v;
    for (int i = 0; i < 6; i++) {
      lines[i] = (RefLine){.col = (unsigned char)(x % 4 + 1), .cont = false};
      x /= 4;
    }
    tried++;
    failed += (unsigned long)run_one(lines, 6, v, &faults);
    if (failed > 10) break;
  }

  // Sweep B: every (column, continuation) sequence of length 5 over columns
  // 1..4. 8^5 = 32768. This is what exhausts L4 and L5 -- the rule that a
  // continuation line closes deeper levels and is exempt from dedent
  // matching, which is the whole reason surface-tour's hanging `in` is legal.
  for (unsigned long v = 0; v < 32768 && failed <= 10; v++) {
    RefLine lines[5];
    unsigned long x = v;
    for (int i = 0; i < 5; i++) {
      lines[i] = (RefLine){.col = (unsigned char)(x % 4 + 1),
                           .cont = ((x / 4) % 2) != 0};
      x /= 8;
    }
    tried++;
    failed += (unsigned long)run_one(lines, 5, 1000000UL + v, &faults);
  }

  if (failed) {
    fprintf(stderr, "sweep: %lu of %lu sequences FAILED\n", failed, tried);
    return 1;
  }
  printf("sweep: %lu sequences, filter and model agree token for token "
         "(%d layout faults exercised)\n",
         tried, faults);
  return 0;
}
