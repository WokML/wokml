// wok_diag -- a BATCH of faults, not the first one.
//
// One run yields a whole work list. Four rules keep the batch trustworthy:
// item granularity, resynchronisation at anchors (see wok_parse.c), cascade
// suppression at an already-reported position, and a cap.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "wok_arena.h"
#include "wok_base.h"

// Every code has a stable machine-readable spelling. Scanner and layout codes
// are faults the PARSER never sees: stage 2 repairs its own input (see
// wok_layout.h invariants), so an inconsistent dedent is never reported as a
// grammar error.
//
// Codes the front end does NOT emit and must not re-mint under another
// spelling: E-ABORT, E-SHADOW, E-AFFINE, E-ESCAPE, E-COVER, E-KIND,
// E-AMBIENT, E-DISCARD. Each belongs to an analysis downstream of the
// grammar (spec.md section 3), and each already has this spelling there.
// E-ARITY and E-VARSCOPE are SHARED: the front end raises the part decidable
// from the grammar and the effect declarations, the analyses raise the rest.
#define WOK_DIAG_CODES(X)                                                    \
  X(WOK_E_LEX_STRAY, "E-LEX-STRAY")                                          \
  X(WOK_E_LEX_TAB, "E-LEX-TAB")                                              \
  X(WOK_E_LEX_UNTERMINATED, "E-LEX-UNTERMINATED")                            \
  X(WOK_E_LEX_INT_RANGE, "E-LEX-INT-RANGE")                                  \
  X(WOK_E_LEX_UTF8, "E-LEX-UTF8")                                            \
  X(WOK_E_LEX_SEMI, "E-LEX-SEMI")                                            \
  X(WOK_E_LAY_DEDENT, "E-LAY-DEDENT")                                        \
  X(WOK_E_LAY_DEPTH, "E-LAY-DEPTH")                                          \
  X(WOK_E_LAY_BRACKET, "E-LAY-BRACKET")                                      \
  X(WOK_E_LAY_INDENT, "E-LAY-INDENT")                                        \
  X(WOK_E_LAY_EXPECTED_BLOCK, "E-LAY-EXPECTED-BLOCK")                        \
  X(WOK_E_PARSE, "E-PARSE")                                                  \
  X(WOK_E_DEPTH, "E-DEPTH")                                                  \
  X(WOK_E_HANDLE_LABEL, "E-HANDLE-LABEL")                                    \
  X(WOK_E_ARITY, "E-ARITY")                                                  \
  X(WOK_E_MIGRATE, "E-MIGRATE")                                              \
  X(WOK_E_RESERVED, "E-RESERVED")                                            \
  X(WOK_E_DUPLICATE, "E-DUPLICATE")                                          \
  X(WOK_E_FIXITY, "E-FIXITY")                                                \
  X(WOK_E_VARSCOPE, "E-VARSCOPE")                                            \
  X(WOK_E_TOO_MANY, "E-TOO-MANY")

typedef enum wok_diag_code : u16 {
#define WOK_X(name, text) name,
  WOK_DIAG_CODES(WOK_X)
#undef WOK_X
      WOK_DIAG_CODE_COUNT
} WokDiagCode;

WOK_READONLY const char *wok_diag_code_text(WokDiagCode);

#define WOK_DIAG_CAP 20

typedef struct {
  WokDiagCode code;
  u32 off;  // byte offset into the source
  u32 len;  // 0 when the span is a point
  const char *msg;
} WokDiag;

typedef struct WokDiagSink WokDiagSink;

// src must outlive the sink; the sink builds a line table from it lazily, so
// line and column are paid for only when a diagnostic is actually rendered.
WokDiagSink *wok_diag_new(WokArena *, const char *path, const char *src,
                          usize src_len);

// Adds a fault. Dropped when the position was already reported (cascade
// suppression) or the cap is reached, in which case a final E-TOO-MANY is
// recorded exactly once.
void wok_diag_add(WokDiagSink *, WokDiagCode, u32 off, u32 len,
                  const char *fmt, ...) WOK_PRINTF(5, 6);

// The same, for a message already built in full -- no format buffer, so no
// silent truncation. For messages that carry a table in continuation lines.
void wok_diag_add_text(WokDiagSink *, WokDiagCode, u32 off, u32 len,
                       const char *msg);

usize wok_diag_count(const WokDiagSink *);
const WokDiag *wok_diag_at(const WokDiagSink *, usize i);
bool wok_diag_full(const WokDiagSink *);

// Resolve a byte offset to 1-based line and column.
void wok_diag_position(const WokDiagSink *, u32 off, u32 *line,
                       u32 *col);

// `file:line:col: message` -- what every editor and CI log already jumps to.
void wok_diag_render(const WokDiagSink *, FILE *);

// JSON LINES: one self-contained object per line, NOT an array. Streamable, so
// a consumer can act on early diagnostics before later ones exist; greppable
// per line; and truncation-safe -- a cut-off file still holds whole records,
// where a truncated array is unparseable. No diagnostics means no output.
void wok_diag_render_jsonl(const WokDiagSink *, FILE *);

