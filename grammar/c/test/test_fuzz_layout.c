// A deterministic mutation driver for the layout properties.
//
// libFuzzer is better at finding inputs; this is better at being RUN. It uses
// a fixed seed, so a failure reproduces exactly, and it needs no runtime that
// Apple's Command Line Tools decline to ship. test/fuzz_layout.c remains the
// libFuzzer entry point for a machine with a full LLVM.

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "check.h"
#include "layout_props.h"

#define MAX_SEEDS 64
#define MAX_INPUT 16384

static u64 rng_state = 0x9E3779B97F4A7C15ull;

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

// Mutations chosen to hit what a layout filter actually cares about: columns,
// line breaks, and brackets. A generic byte-flipper spends most of its time
// inside identifiers, where nothing interesting lives.
static usize mutate(const unsigned char *in, usize n, unsigned char *out) {
  static const unsigned char interesting[] = {' ', '\n', '\t', '(', ')', '[',
                                              ']', '{',  '}',  '-', '|', '='};
  usize len = n > MAX_INPUT ? MAX_INPUT : n;
  memcpy(out, in, len);
  int rounds = 1 + (int)rng_below(6);
  for (int r = 0; r < rounds; r++) {
    switch (rng_next() % 4) {
      case 0:  // substitute an interesting byte
        if (len) out[rng_below(len)] = interesting[rng_below(sizeof interesting)];
        break;
      case 1:  // delete a byte
        if (len) {
          usize at = rng_below(len);
          memmove(out + at, out + at + 1, len - at - 1);
          len--;
        }
        break;
      case 2:  // insert an interesting byte
        if (len + 1 < MAX_INPUT) {
          usize at = rng_below(len + 1);
          memmove(out + at + 1, out + at, len - at);
          out[at] = interesting[rng_below(sizeof interesting)];
          len++;
        }
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
  load_dir("../../test/redesign/accept");
  load_dir("../../test/redesign/reject");
  load_dir("testdata/tour");
  load_dir("testdata/layout-bad");
  CHECK(nseeds > 0, "no seed files found");
  if (nseeds == 0) TEST_DONE();

  unsigned char *buf = (unsigned char *)malloc(MAX_INPUT);
  CHECK(buf != nullptr, "out of memory");
  if (!buf) TEST_DONE();

  const int iterations = 20000;
  for (int i = 0; i < iterations; i++) {
    usize s = rng_below(nseeds);
    usize n = mutate(seeds[s].bytes, seeds[s].n, buf);
    const char *fail = wok_layout_properties(buf, n);
    CHECK(fail == nullptr, "mutation %d of seed %zu: %s", i, s,
          fail ? fail : "");
    if (fail) break;
  }

  // Pure noise, including bytes no valid wok file contains.
  for (int i = 0; i < 2000; i++) {
    usize n = rng_below(256);
    for (usize k = 0; k < n; k++) buf[k] = (unsigned char)(rng_next() & 0xFF);
    const char *fail = wok_layout_properties(buf, n);
    CHECK(fail == nullptr, "random input %d: %s", i, fail ? fail : "");
    if (fail) break;
  }

  free(buf);
  for (usize i = 0; i < nseeds; i++) free(seeds[i].bytes);
  printf("22000 mutated and random inputs, all properties held\n");
  TEST_DONE();
}
