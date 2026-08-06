// A test harness small enough to read in one sitting.

#pragma once

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "wok_base.h"

static int wok_test_failures = 0;
static int wok_test_checks = 0;

#define CHECK(cond, ...)                                       \
  do {                                                         \
    wok_test_checks++;                                         \
    if (!(cond)) {                                             \
      wok_test_failures++;                                     \
      fprintf(stderr, "  FAIL %s:%d: ", __FILE__, __LINE__);   \
      fprintf(stderr, __VA_ARGS__);                            \
      fputc('\n', stderr);                                     \
      if (wok_test_failures > 20) {                            \
        fprintf(stderr, "  (too many failures)\n");            \
        return 1;                                              \
      }                                                        \
    }                                                          \
  } while (0)

#define TEST_DONE()                                                       \
  do {                                                                    \
    if (wok_test_failures == 0) {                                         \
      printf("%d checks passed\n", wok_test_checks);                      \
      return 0;                                                           \
    }                                                                     \
    fprintf(stderr, "%d of %d checks FAILED\n", wok_test_failures,        \
            wok_test_checks);                                             \
    return 1;                                                             \
  } while (0)

#include <dirent.h>

// ONE corpus walker for every suite. Six verbatim copies of this loop lived
// across the test files, and a corpus-layout change missed in one copy made
// that suite silently stop covering new fixtures instead of failing to
// build. Visits each `*.wok` in readdir order; `fn` returns its failure
// count; `seen` (optional) counts files visited.
static inline int wok_test_walk(const char *dir,
                                int (*fn)(const char *path, void *ctx),
                                void *ctx, int *seen) {
  DIR *dp = opendir(dir);
  if (!dp) {
    fprintf(stderr, "  FAIL cannot open %s\n", dir);
    return 1;
  }
  int bad = 0;
  struct dirent *e;
  while ((e = readdir(dp)) != nullptr) {
    usize len = strlen(e->d_name);
    if (len < 5 || strcmp(e->d_name + len - 4, ".wok") != 0) continue;
    char path[1024];
    (void)snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
    bad += fn(path, ctx);
    if (seen) (*seen)++;
  }
  closedir(dp);
  return bad;
}

// The fixture's own statement of its fault: the code token of its
// `-- EXPECT:` header, or empty when it has none. The marker protocol lives
// here and nowhere else.
static inline void wok_test_expect_code(const char *src, char *want,
                                        usize cap) {
  want[0] = '\0';
  const char *marker = strstr(src, "-- EXPECT: ");
  if (!marker) return;
  marker += strlen("-- EXPECT: ");
  usize k = 0;
  while (k + 1 < cap && marker[k] && marker[k] != '\n' && marker[k] != ' ')
    k++;
  memcpy(want, marker, k);
  want[k] = '\0';
}

static inline char *wok_test_slurp(const char *path, usize *n) {
  FILE *fp = fopen(path, "rb");
  if (!fp) return nullptr;
  if (fseek(fp, 0, SEEK_END) != 0) {
    fclose(fp);
    return nullptr;
  }
  long sz = ftell(fp);
  if (sz < 0) {
    fclose(fp);
    return nullptr;
  }
  rewind(fp);
  char *buf = (char *)malloc((usize)sz + 1);
  if (!buf) {
    fclose(fp);
    return nullptr;
  }
  usize got = fread(buf, 1, (usize)sz, fp);
  buf[got] = '\0';
  *n = got;
  fclose(fp);
  return buf;
}

