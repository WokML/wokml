// wok_shape -- what `wok fmt --check` compares.
//
// The linter cannot be text equality with the formatter's output, because the
// formatter ALIGNS arrows and alignment is deliberately not part of the
// standard (owner decision). Alignment is NON-LOCAL: renaming one op reflows
// every sibling's padding, so enforcing it would turn a one-token rename into
// a whole-block diff and a CI failure over nothing.
//
// So --check compares the SHAPE of two texts:
//
//   per line: the exact indentation -- unless the line's first token is a
//   CONTINUATION LEAD, when the indentation is clamped too -- then every
//   token and comment with inter-item gaps clamped to at most one space.
//
// The continuation-lead exemption is the same decision applied to the line
// filler. A wrapped capability row aligns under its `with`, so renaming the
// function moves that column and reflows every line under it; comparing those
// columns exactly would turn a one-token rename into a CI failure over
// nothing. WHERE the filler broke is still compared -- that is line
// structure, not indentation -- so the width standard stays enforced. Remove
// the one condition in wok_shape.c to enforce wrapped indentation too, if the
// churn turns out to be tolerable in practice.
//
// Clamping to min(gap, 1) rather than dropping whitespace is what keeps the
// rest of the standard enforced. `a+b` (gap 0) still differs from `a + b`
// (gap 1), so operator spacing is checked; indentation is compared exactly, so
// a three-space indent is still a violation; only runs of two or more spaces --
// which is exactly what alignment padding is -- become invisible.
//
// Computed over TOKENS AND COMMENTS, never raw bytes, for two reasons:
// a string literal containing two spaces can never be mistaken for padding,
// and a deleted or moved comment IS a difference the linter must report.

#pragma once

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <stddef.h>

#include "wok_arena.h"
#include "wok_diag.h"

// Returns an arena-allocated NUL-terminated normal form. Two texts are
// canonically equivalent exactly when their shapes compare equal with strcmp.
char *wok_shape(const char *restrict src, usize src_len, WokArena *,
                WokDiagSink *);

