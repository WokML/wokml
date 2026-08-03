// libFuzzer entry point for the whole front end. The properties live in
// parse_props.h and are shared with test/test_fuzz_parse.c, which runs them
// under a deterministic driver on machines with no libFuzzer runtime.
//
//   cd grammar/c && make fuzz && ./test/fuzz_parse -max_len=8192 corpus/

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "parse_props.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, usize size);

int LLVMFuzzerTestOneInput(const uint8_t *data, usize size) {
  int clean = 0;
  const char *fail = wok_parse_properties(data, size, &clean);
  if (fail) {
    fprintf(stderr, "%s\n", fail);
    abort();
  }
  return 0;
}
