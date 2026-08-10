// libFuzzer entry point for stages 1 and 2. The properties live in
// layout_props.h and are shared with test/test_fuzz_layout.c, which runs the
// same checks under a deterministic driver on machines with no libFuzzer
// runtime (Apple's Command Line Tools ship none).
//
//   cd grammar/c && make fuzz && ./test/fuzz_layout -max_len=8192 corpus/

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "layout_props.h"

int LLVMFuzzerTestOneInput(const u8 *data, usize size);

int LLVMFuzzerTestOneInput(const u8 *data, usize size) {
  const char *fail = wok_layout_properties(data, size);
  if (fail) {
    fprintf(stderr, "%s\n", fail);
    abort();
  }
  return 0;
}
