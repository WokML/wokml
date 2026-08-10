// The UTF-8 decoder, against an independent reference model.
//
// wok_utf8.c is a table-driven DFA, chosen because it rejects overlong
// encodings, surrogates and out-of-range codepoints BY CONSTRUCTION rather
// than through three hand-written predicates. Its one real cost is that the
// table cannot be audited by eye.
//
// This is where that cost is paid. The hand-written decoder the DFA replaced
// is kept below as a REFERENCE MODEL and compared against it over EVERY 1-,
// 2- and 3-byte sequence -- 16,777,216 cases, exhaustive, not sampled. The
// same arrangement the layout filter uses, and for the same reason: a table
// nobody reads is fine exactly when something else checks it.

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../wok_utf8.h"
#include "check.h"

// ------------------------------------------------------- the reference model
//
// Structurally unlike the DFA on purpose: explicit lead-byte classification,
// an explicit continuation loop, and the three range predicates spelled out.
// A transcription slip in either one shows up on some sequence, and the sweep
// is exhaustive, so "some sequence" means "this sweep".
static usize ref_seq_len(const unsigned char *p, usize avail) {
  if (avail == 0) return 0;
  unsigned char c = p[0];
  if (c < 0x80) return 1;

  usize need;
  u32 cp;
  if ((c & 0xE0) == 0xC0) {
    need = 1;
    cp = c & 0x1Fu;
  } else if ((c & 0xF0) == 0xE0) {
    need = 2;
    cp = c & 0x0Fu;
  } else if ((c & 0xF8) == 0xF0) {
    need = 3;
    cp = c & 0x07u;
  } else {
    return 0;
  }
  if (need >= avail) return 0;
  for (usize k = 1; k <= need; k++) {
    if ((p[k] & 0xC0) != 0x80) return 0;
    cp = (cp << 6) | (p[k] & 0x3Fu);
  }
  bool overlong = (need == 1 && cp < 0x80) || (need == 2 && cp < 0x800) ||
                  (need == 3 && cp < 0x10000);
  if (overlong || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return 0;
  return need + 1;
}

int main(void) {
  // --- exhaustive: every 1-, 2- and 3-byte sequence ------------------------
  unsigned long disagreements = 0, first = 0;
  unsigned char b[4] = {0};
  for (unsigned long v = 0; v < (1ul << 24); v++) {
    b[0] = (unsigned char)(v >> 16);
    b[1] = (unsigned char)(v >> 8);
    b[2] = (unsigned char)v;
    if (wok_utf8_seq_len(b, 3) != ref_seq_len(b, 3)) {
      if (disagreements == 0) first = v;
      disagreements++;
    }
  }
  CHECK(disagreements == 0,
        "DFA and reference model disagree on %lu of 16777216 sequences; "
        "first at %06lx (dfa=%zu ref=%zu)",
        disagreements, first,
        (b[0] = (unsigned char)(first >> 16), b[1] = (unsigned char)(first >> 8),
         b[2] = (unsigned char)first, wok_utf8_seq_len(b, 3)),
        ref_seq_len(b, 3));

  // --- the classic attacks, named so a failure says what broke -------------
  struct {
    const unsigned char bytes[5];
    usize len;
    usize want;
    const char *why;
  } cases[] = {
      {{0x41}, 1, 1, "ASCII"},
      {{0xC3, 0xA9}, 2, 2, "e-acute, two bytes"},
      {{0xE2, 0x9C, 0x93}, 3, 3, "a check mark, three bytes"},
      {{0xF0, 0x9F, 0x92, 0xA9}, 4, 4, "four bytes"},
      {{0xC0, 0xAF}, 2, 0, "OVERLONG `/` -- the classic path-traversal smuggle"},
      {{0xE0, 0x80, 0xAF}, 3, 0, "overlong in three bytes"},
      {{0xF0, 0x80, 0x80, 0xAF}, 4, 0, "overlong in four bytes"},
      {{0xC1, 0xBF}, 2, 0, "overlong, highest two-byte form"},
      {{0xED, 0xA0, 0x80}, 3, 0, "U+D800, a UTF-16 surrogate half"},
      {{0xED, 0xBF, 0xBF}, 3, 0, "U+DFFF, the other end of the surrogates"},
      {{0xF4, 0x90, 0x80, 0x80}, 4, 0, "U+110000, past the last codepoint"},
      {{0xF5, 0x80, 0x80, 0x80}, 4, 0, "a lead byte above the legal range"},
      {{0x80}, 1, 0, "an orphan continuation byte"},
      {{0xC3}, 1, 0, "truncated: a lead with nothing after it"},
      {{0xE2, 0x9C}, 2, 0, "truncated: two of three bytes"},
      {{0xC3, 0x41}, 2, 0, "a lead followed by ASCII, not a continuation"},
      {{0xFE}, 1, 0, "0xFE is not a legal byte anywhere in UTF-8"},
      {{0xFF}, 1, 0, "0xFF likewise -- the byte that started all this"},
  };
  for (usize i = 0; i < sizeof cases / sizeof *cases; i++) {
    usize got = wok_utf8_seq_len(cases[i].bytes, cases[i].len);
    CHECK(got == cases[i].want, "%s: got %zu, expected %zu", cases[i].why, got,
          cases[i].want);
    CHECK(ref_seq_len(cases[i].bytes, cases[i].len) == cases[i].want,
          "%s: the REFERENCE MODEL is wrong, which invalidates the sweep",
          cases[i].why);
  }

  // --- find_invalid agrees with walking seq_len by hand --------------------
  {
    const unsigned char buf[] = {'a',  0xC3, 0xA9, 'b',  0xE2, 0x9C,
                                 0x93, 0xFF, 'c',  0x80, 'd'};
    usize n = sizeof buf;
    usize by_scan = 0;
    while (by_scan < n) {
      usize s = wok_utf8_seq_len(buf + by_scan, n - by_scan);
      if (s == 0) break;
      by_scan += s;
    }
    CHECK(wok_utf8_find_invalid(buf, n) == by_scan,
          "find_invalid (%zu) disagrees with a hand walk (%zu)",
          wok_utf8_find_invalid(buf, n), by_scan);
    CHECK(by_scan == 7, "the first bad byte is the 0xFF at offset 7, got %zu",
          by_scan);
  }
  {
    // The ASCII fast path must not skip past a bad byte sitting inside an
    // otherwise-ASCII run, at every alignment relative to its 8-byte stride.
    for (usize pad = 0; pad < 24; pad++) {
      unsigned char buf[64];
      memset(buf, 'x', sizeof buf);
      buf[pad] = 0xFF;
      CHECK(wok_utf8_find_invalid(buf, sizeof buf) == pad,
            "fast path missed a bad byte at offset %zu", pad);
    }
    unsigned char clean[64];
    memset(clean, 'x', sizeof clean);
    CHECK(wok_utf8_find_invalid(clean, sizeof clean) == sizeof clean,
          "a clean ASCII buffer must report no fault");
  }

  // --- truncate always lands on a boundary ---------------------------------
  {
    // 30 alphas: two bytes each, so a byte cap of 40 lands mid-character.
    unsigned char alphas[60];
    for (usize i = 0; i < 30; i++) {
      alphas[i * 2] = 0xCE;
      alphas[i * 2 + 1] = 0xB1;
    }
    for (usize max = 0; max <= 60; max++) {
      usize got = wok_utf8_truncate(alphas, 60, max);
      CHECK(got % 2 == 0, "truncate(%zu) returned %zu, which splits a "
                          "two-byte character",
            max, got);
      CHECK(got <= max, "truncate(%zu) returned %zu, past the cap", max, got);
      CHECK(wok_utf8_find_invalid(alphas, got) == got,
            "truncate(%zu) produced an ill-formed prefix", max);
    }
  }

  TEST_DONE();
}
