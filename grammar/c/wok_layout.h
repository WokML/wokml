// wok_layout -- stage 2. A PURE function over token streams.
//
// This is the highest-leverage decision in the front end. Haskell's
// parse-error(t) rule requires the parser to feed back into the layout
// algorithm, which is genuine context-sensitivity and is why no two Haskell
// implementations agree on edge cases. Here there is no feedback edge at all:
// same input, same output, always.
//
// The filter knows THREE things -- a token's column, whether it opens or
// closes a bracket, and wok_token_is_continuation_lead(). It cannot name a
// keyword and does not include the AST.
//
// THE RULES (see docs/superpowers/specs/2026-08-03-c23-frontend-design.md 5.2)
//
//   L1  blank and comment-only lines produce nothing.
//   L2  while inside brackets, line starts produce nothing.
//   L3  ITEM LINE (first token is not a continuation lead): emit NEWLINE,
//       then INDENT / nothing / DEDENT* by column, and a dedent MUST land
//       exactly on an open level.
//   L4  CONTINUATION LINE (first token is a continuation lead): emit the
//       DEDENTs needed to close deeper levels, and NO NEWLINE. The logical
//       line continues.
//   L5  L4 performs no dedent-matching check. A continuation is not claiming
//       to start anything at a level, so there is no level to match. This is
//       what makes a hanging `in`, a leading `|` in a multi-line `type`, and
//       a leading `+` in a long capability row all legal.
//   L6  faults are REPAIRED here and never forwarded. Inconsistent dedent is
//       not a grammar error and has no business reaching the parser.
//   L7  BRACKET ABANDONMENT. Inside a bracket group, a line whose first token
//       is not a continuation lead and whose column is <= the block column
//       recorded when the outermost bracket opened cannot be a continuation
//       of anything inside it. Report the unclosed bracket AT ITS OPENING
//       POSITION, force-close, and re-process the line under L3. Indentation
//       is the independent witness that survives suppressed layout, and an
//       unclosed bracket is the one fault that otherwise collapses a whole
//       file into a single logical line.
//   L8  at EOF: NEWLINE, then a DEDENT per open level.

#pragma once

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <stdbool.h>
#include <stddef.h>

#include "wok_arena.h"
#include "wok_diag.h"
#include "wok_token.h"

#define WOK_LAYOUT_MAX_DEPTH 64

WokTokens wok_layout(WokTokens in, WokArena *, WokDiagSink *);

// The five invariants of 5.3, checked on EVERY emitted stream in a debug
// build and by the fuzzer in every build. They hold even for input that is
// full of layout faults -- that contract is what lets the parser be written
// with no defensive code.
//
//   1. INDENT/DEDENT are balanced and properly nested; empty at EOF.
//   2. pushed columns are strictly increasing.
//   3. no INDENT is immediately followed by a DEDENT -- every block region
//      holds at least one token. (Note that a DEDENT is NOT always preceded
//      by a NEWLINE: L4 emits DEDENTs with no item separator, which is the
//      whole point of a continuation line.)
//   4. no layout token appears between a bracket opener and its closer.
//      Checked only when `strict_brackets` is set, because the property is
//      not DEFINED for input whose brackets do not balance: L7 force-closes
//      an abandoned group and a later closer may still balance the stream.
//      Pass true for input known to be well formed (the corpus, the sweep),
//      false for adversarial or mutated input. Found by the mutation driver
//      on `f = (a` / `g = 1)`; inferring it from the diagnostic sink was
//      tried and is unsound, since the cap can swallow the bracket fault.
//   5. output length is bounded by 3n + MAX_DEPTH.
//
// Invariants 1, 2, 3 and 5 hold for EVERY input, however damaged. That is the
// contract that lets the parser be written with no defensive code.
//
// Returns true when the stream is well formed; otherwise fills err.
bool wok_layout_check(WokTokens out, usize input_n, bool strict_brackets,
                      char *err, usize err_len);

