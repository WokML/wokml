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

