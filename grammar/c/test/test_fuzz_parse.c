// Mutation driver for the WHOLE front end: scan -> layout -> parse -> dump.
//
// The layout driver next door proves stage 2's properties; this one exists
// because the parser is the largest hand-written surface in the package and
// the only one that walks a tree it just built. Two properties beyond "did
// not crash":
//
//   - the diagnostic cap holds, so a hostile file cannot make the tool spin;
//   - ANY input that parses cleanly must round-trip through the dump. A parser
//     that accepts nonsense and builds a malformed tree passes a crash test
//     and fails this one.

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../wok_arena.h"
#include "../wok_ast.h"
#include "../wok_parse.h"
#include "../wok_sexpr.h"
#include "check.h"
#include "parse_props.h"

#define MAX_SEEDS 64
#define MAX_INPUT 16384

static u64 rng_state = 0xD1B54A32D192ED03ull;

static u64 rng_next(void) {
  rng_state ^= rng_state << 13;
  rng_state ^= rng_state >> 7;
  rng_state ^= rng_state << 17;
  return rng_state;
}
static usize rng_below(usize n) { return n ? (usize)(rng_next() % n) : 0; }

typedef struct {
  unsigned char *bytes;
  usize n;
} Seed;

static Seed seeds[MAX_SEEDS];
static usize nseeds;

static void load_dir(const char *dir) {
  DIR *dp = opendir(dir);
  if (!dp) return;
  struct dirent *e;
  while ((e = readdir(dp)) != nullptr && nseeds < MAX_SEEDS) {
    usize len = strlen(e->d_name);
    if (len < 5 || strcmp(e->d_name + len - 4, ".wok") != 0) continue;
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
    usize n = 0;
    char *src = wok_test_slurp(path, &n);
    if (!src) continue;
    if (n > MAX_INPUT) n = MAX_INPUT;
    seeds[nseeds].bytes = (unsigned char *)src;
    seeds[nseeds].n = n;
    nseeds++;
  }
  closedir(dp);
}

// Weighted towards what a PARSER cares about: keywords, delimiters, arrows.
static usize mutate(const unsigned char *in, usize n, unsigned char *out) {
  static const char *const frags[] = {
      "handle ", "handler ", "once ", "return ", "var ", "where ", "in ",
      "case ", " of", "->", "=>", ":=", "::", "..", "|", "(", ")", "[", "]",
      "{", "}", "\n", "  ", "\t", "\"", "`", "\\", ",", "="};
  usize len = n > MAX_INPUT ? MAX_INPUT : n;
  memcpy(out, in, len);
  int rounds = 1 + (int)rng_below(8);
  for (int r = 0; r < rounds; r++) {
    switch (rng_next() % 4) {
      case 0: {  // splice a fragment in
        const char *f = frags[rng_below(sizeof frags / sizeof *frags)];
        usize fl = strlen(f);
        if (len + fl < MAX_INPUT) {
          usize at = rng_below(len + 1);
          memmove(out + at + fl, out + at, len - at);
          memcpy(out + at, f, fl);
          len += fl;
        }
        break;
      }
      case 1:  // delete a run
        if (len) {
          usize at = rng_below(len);
          usize k = 1 + rng_below(len - at);
          memmove(out + at, out + at + k, len - at - k);
          len -= k;
        }
        break;
      case 2:  // flip a byte
        if (len) out[rng_below(len)] ^= (unsigned char)(1u << rng_below(8));
        break;
      case 3:  // truncate
        if (len) len = rng_below(len);
        break;
      default:
        break;
    }
  }
  return len;
}


int main(void) {
  load_dir("../../docs/redesign/examples/accept");
  load_dir("../../docs/redesign/examples/reject");
  load_dir("testdata/tour");
  load_dir("testdata/parse-bad");
  load_dir("testdata/layout-bad");
  CHECK(nseeds > 0, "no seed files found");
  if (nseeds == 0) TEST_DONE();

  unsigned char *buf = (unsigned char *)malloc(MAX_INPUT);
  CHECK(buf != nullptr, "out of memory");
  if (!buf) TEST_DONE();

  int clean_parses = 0;
  for (int i = 0; i < 12000; i++) {
    usize s = rng_below(nseeds);
    usize n = mutate(seeds[s].bytes, seeds[s].n, buf);
    const char *fail = wok_parse_properties(buf, n, &clean_parses);
    CHECK(fail == nullptr, "mutation %d of seed %zu: %s", i, s,
          fail ? fail : "");
    if (fail) break;
  }

  for (int i = 0; i < 2000; i++) {
    usize n = rng_below(512);
    for (usize k = 0; k < n; k++) buf[k] = (unsigned char)(rng_next() & 0xFF);
    const char *fail = wok_parse_properties(buf, n, &clean_parses);
    CHECK(fail == nullptr, "random input %d: %s", i, fail ? fail : "");
    if (fail) break;
  }

  free(buf);
  for (usize i = 0; i < nseeds; i++) free(seeds[i].bytes);
  printf("14000 mutated and random inputs through the full front end "
         "(%d clean parses round-tripped)\n",
         clean_parses);
  TEST_DONE();
}
