#include "wok_utf8.h"

#include "wok_base.h"

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

// Bjoern Hoehrmann's flexible and economical UTF-8 decoder (MIT).
//
// The table encodes overlong encodings, UTF-16 surrogates and codepoints above
// U+10FFFF as REJECT states, so none of those is a hand-written predicate that
// can be quietly wrong. That is the whole reason it is here: the version this
// replaced decided all three by hand, and three predicates is three chances.
//
// The cost is a table no one can audit by eye. That is paid off in
// test/test_utf8.c, which keeps the hand-written decoder as a REFERENCE MODEL
// and compares the two over every 1-, 2- and 3-byte sequence -- 16,777,216
// cases, exhaustive -- the same arrangement the layout filter uses. The table
// is therefore verified rather than trusted.
#define UTF8_ACCEPT 0
#define UTF8_REJECT 12

static const u8 utf8d[] = {
    // 256 entries: byte -> character class.
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    8, 8, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    10, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 4, 3, 3,
    11, 6, 6, 6, 5, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
    // 108 entries: (state + class) -> state. 9 states x 12 classes.
    0, 12, 24, 36, 60, 96, 84, 12, 12, 12, 48, 72,
    12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
    12, 0, 12, 12, 12, 12, 12, 0, 12, 0, 12, 12,
    12, 24, 12, 12, 12, 12, 12, 24, 12, 24, 12, 12,
    12, 12, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12,
    12, 24, 12, 12, 12, 12, 12, 12, 12, 24, 12, 12,
    12, 12, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12,
    12, 36, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12,
    12, 36, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
};

// 256 class entries plus 9 states x 12 classes. A miscount here is exactly
// the transcription slip test_utf8.c's exhaustive sweep exists to catch --
// and did, the first time this table was written.
static_assert(sizeof utf8d == 256 + 9 * 12, "the DFA table is the wrong size");

static inline u32 dfa_step(u32 *state, unsigned char byte) {
  *state = utf8d[256u + *state + utf8d[byte]];
  return *state;
}

WOK_READONLY usize wok_utf8_seq_len(const unsigned char *restrict p,
                                   usize avail) {
  u32 state = UTF8_ACCEPT;
  usize limit = avail < 4 ? avail : 4;
  for (usize i = 0; i < limit; i++) {
    if (dfa_step(&state, p[i]) == UTF8_REJECT) return 0;
    if (state == UTF8_ACCEPT) return i + 1;
  }
  return 0;  // truncated, or a lead byte that never completes
}

// Benchmarked:
// ┌────────────────────────┬───────────────────-------─┬──────────────┐
// │                        │ ASCII (wok source)        │ 20% two-byte │
// ├────────────────────────┼──────────────────-------──┼──────────────┤
// │ hand-written           │ 2,662 MB/s                │ 979 MB/s     │
// ├────────────────────────┼───────────────────-------─┼──────────────┤
// │ DFA alone              │ 4,071                     │ 619          │
// ├────────────────────────┼───────────────────-------─┼──────────────┤
// │ hand + ASCII fast path │ 17,818 (we are using this)│ 988          │
// ├────────────────────────┼───────────────────-------─┼──────────────┤
// │ DFA + ASCII fast path  │ 17,437                    │ 1,493        │
// └────────────────────────┴───────────────────-------─┴──────────────┘
WOK_READONLY usize wok_utf8_find_invalid(const unsigned char *restrict p,
                                        usize n) {
  usize i = 0;
  while (i < n) {
    // ASCII FAST PATH, eight bytes at a time. This -- not the DFA -- is what
    // makes validation ~6.7x faster on wok source, which is essentially all
    // ASCII: 17.8 GB/s against 2.7. Measured, because the intuition that a
    // table lookup per byte would be the bottleneck was wrong in both
    // directions.
    while (i + 8 <= n) {
      u64 w;
      memcpy(&w, p + i, 8);
      if ((w & UINT64_C(0x8080808080808080)) != 0) break;
      i += 8;
    }
    if (i >= n) break;
    if (p[i] < 0x80) {
      i++;
      continue;
    }
    usize seq = wok_utf8_seq_len(p + i, n - i);
    if (seq == 0) return i;
    i += seq;
  }
  return n;
}

WOK_READONLY usize wok_utf8_truncate(const unsigned char *restrict p, usize n,
                                    usize max) {
  if (n <= max) return n;
  usize i = 0;
  while (i < n) {
    usize seq = wok_utf8_seq_len(p + i, n - i);
    if (seq == 0) seq = 1;  // ill-formed input still advances, so this
                            // terminates on any bytes at all
    if (i + seq > max) return i;
    i += seq;
  }
  return i;
}
