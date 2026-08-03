// The properties stages 1 and 2 must satisfy for ANY input, valid wok or not.
//
// Shared by two drivers: the libFuzzer target (test/fuzz_layout.c) and the
// deterministic mutation driver (test/test_fuzz_layout.c). Apple's Command
// Line Tools ship no libFuzzer runtime, so the properties would otherwise
// only ever run on a machine with a full LLVM -- which is to say, rarely.

#pragma once

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../wok_arena.h"
#include "../wok_layout.h"
#include "../wok_token.h"

// Returns nullptr when every property holds, else a description of the first
// violation (in a static buffer -- single-threaded driver, by design).
static inline const char *wok_layout_properties(const u8 *data,
                                                usize size) {
  static char msg[512];
  if (size > (1u << 20)) return nullptr;

  WokArena *a = wok_arena_new(0);
  WokDiagSink *d = wok_diag_new(a, "<fuzz>", (const char *)data, size);
  WokScanResult sr = wok_scan((const char *)data, size, a, d);
  WokTokens out = wok_layout(sr.tokens, a, d);

  const char *fail = nullptr;
  char err[256];

  // P1 -- the stream contract holds even for input full of faults. This is
  // what lets the parser be written with no defensive code.
  if (!wok_layout_check(out, sr.tokens.n, false, err, sizeof err)) {
    snprintf(msg, sizeof msg, "layout invariant broken: %s", err);
    fail = msg;
  }

  // P2 -- the cap is a promise, not a suggestion.
  if (!fail && wok_diag_count(d) > WOK_DIAG_CAP + 1) {
    snprintf(msg, sizeof msg, "diagnostic cap exceeded: %zu",
             wok_diag_count(d));
    fail = msg;
  }

  // P3 -- CONSERVATION. Every non-layout token in the output is a token the
  // scanner produced, unaltered and in order. A filter that invented or
  // dropped a token would still satisfy the structural invariants, so this is
  // checked separately.
  if (!fail) {
    usize in_i = 0;
    for (usize i = 0; i < out.n && !fail; i++) {
      WokKind k = (WokKind)out.tok[i].kind;
      if (k == WT_NEWLINE || k == WT_INDENT || k == WT_DEDENT) continue;
      if (in_i >= sr.tokens.n) {
        snprintf(msg, sizeof msg, "filter emitted more tokens than it received");
        fail = msg;
        break;
      }
      if (memcmp(&out.tok[i], &sr.tokens.tok[in_i], sizeof(WokToken)) != 0) {
        snprintf(msg, sizeof msg, "filter altered source token %zu", in_i);
        fail = msg;
        break;
      }
      in_i++;
    }
    if (!fail && in_i != sr.tokens.n) {
      snprintf(msg, sizeof msg, "filter dropped %zu token(s)",
               sr.tokens.n - in_i);
      fail = msg;
    }
  }

  // P4 -- PURITY. The filter is a pure function of its input, so running it
  // twice on the same tokens must give the identical stream. This is the
  // property the whole three-stage split exists to make true, and it is the
  // one a stray static or a reused buffer would break.
  if (!fail) {
    WokTokens again = wok_layout(sr.tokens, a, d);
    if (again.n != out.n) {
      snprintf(msg, sizeof msg, "filter is not pure: %zu vs %zu tokens",
               again.n, out.n);
      fail = msg;
    } else if (memcmp(again.tok, out.tok, out.n * sizeof(WokToken)) != 0) {
      snprintf(msg, sizeof msg, "filter is not pure: streams differ");
      fail = msg;
    }
  }

  wok_arena_free(a);
  return fail;
}

