// wok_utf8 -- the ONE place UTF-8 sequence structure is decided.
//
// It was written twice before this file existed: once in the scanner's
// whole-buffer validation, once in the JSON escaper. Two hand-written decoders
// is how you get a validator that accepts what a consumer rejects, and that
// divergence is silent. It sits BELOW both, because wok_token.h includes
// wok_diag.h and the dependency would otherwise be a cycle.
//
// Validation happens ONCE, when a source file is read. Everything downstream
// is UTF-8 clean by construction -- which is a property this module has to
// help maintain, not merely assume: see wok_utf8_truncate.

#pragma once

#include <stddef.h>

#include "wok_base.h"

// Length of the well-formed sequence at p, or 0 if it is ill-formed --
// unexpected byte, truncated, bad continuation, overlong, surrogate, or above
// U+10FFFF. `avail` is how many bytes remain, so a sequence running off the
// end reports ill-formed rather than reading past it.
WOK_READONLY usize wok_utf8_seq_len(const unsigned char *restrict p,
                                   usize avail);

// Offset of the first ill-formed byte, or n if the whole buffer is well
// formed. Carries an eight-byte-at-a-time ASCII fast path, which is where
// nearly all of the speed is on wok source.
WOK_READONLY usize wok_utf8_find_invalid(const unsigned char *restrict p,
                                        usize n);

// The largest length <= max that ends on a codepoint boundary.
//
// This exists because of a bug, and the bug happened on VALID input: the
// parser quotes a token into a diagnostic and caps it at 40 bytes, which cut a
// two-byte character in half and produced a message that was not UTF-8. A
// naive byte cap is wrong for any text a human might read.
WOK_READONLY usize wok_utf8_truncate(const unsigned char *restrict p, usize n,
                                    usize max);

