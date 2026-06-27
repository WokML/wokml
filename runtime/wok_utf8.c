/* UTF-8 validation via Bjoern Hoehrmann's DFA decoder.
   Copyright (c) 2008-2009 Bjoern Hoehrmann <bjoern@hoehrmann.de>
   See http://bjoern.hoehrmann.de/utf-8/decoder/dfa/  (MIT license) */
#include "wok_rc.h"
#include <stdint.h>

#define WOK_UTF8_ACCEPT 0u
#define WOK_UTF8_REJECT 12u

static const uint8_t wok_utf8d[] = {
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
  7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7, 7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
  8,8,2,2,2,2,2,2,2,2,2,2,2,2,2,2, 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
  10,3,3,3,3,3,3,3,3,3,3,3,3,4,3,3, 11,6,6,6,5,8,8,8,8,8,8,8,8,8,8,8,
  0,12,24,36,60,96,84,12,12,12,48,72, 12,12,12,12,12,12,12,12,12,12,12,12,
  12, 0,12,12,12,12,12, 0,12, 0,12,12, 12,24,12,12,12,12,12,24,12,24,12,12,
  12,12,12,12,12,12,12,24,12,12,12,12, 12,24,12,12,12,12,12,12,12,24,12,12,
  12,12,12,12,12,12,12,36,12,36,12,12, 12,36,12,12,12,12,12,36,12,36,12,12,
  12,36,12,12,12,12,12,12,12,12,12,12,
};

/* Returns 1 if [bytes, bytes+len) is well-formed UTF-8 (rejects overlong,
   surrogates, > U+10FFFF, bad/truncated continuations). Empty buffer is valid. */
int wok_validate_utf8(const uint8_t *bytes, uint64_t len) {
  uint32_t state = WOK_UTF8_ACCEPT;
  for (uint64_t i = 0; i < len; i++) {
    uint32_t type = wok_utf8d[bytes[i]];
    state = wok_utf8d[256u + state + type];
    if (state == WOK_UTF8_REJECT) return 0;
  }
  return state == WOK_UTF8_ACCEPT ? 1 : 0;
}
