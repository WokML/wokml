// The properties the WHOLE front end must satisfy for any input: scan ->
// layout -> parse -> dump.
//
// Shared by two drivers, exactly as layout_props.h is: test_fuzz_parse.c runs
// them under a deterministic seeded mutator that works everywhere, and
// fuzz_parse.c is the libFuzzer entry point for a machine with a full LLVM.
// Apple's Command Line Tools ship no libFuzzer runtime, which is how the
// `fuzz` target came to reference a file that did not exist.

#pragma once

#include <stdio.h>
#include <string.h>

#include "../wok_arena.h"
#include "../wok_ast.h"
#include "../wok_parse.h"
#include "../wok_sexpr.h"

static inline const char *wok_parse_properties(const unsigned char *data,
                                              usize n, int *clean) {
  static char msg[512];
  WokArena *a = wok_arena_new(0);
  WokDiagSink *d = wok_diag_new(a, "<fuzz>", (const char *)data, n);
  WokNode *file = wok_parse_source((const char *)data, n, a, d);
  const char *fail = nullptr;

  if (wok_diag_count(d) > WOK_DIAG_CAP + 1) {
    snprintf(msg, sizeof msg, "diagnostic cap exceeded: %zu",
             wok_diag_count(d));
    fail = msg;
  } else if (!file) {
    snprintf(msg, sizeof msg, "parser returned no file node");
    fail = msg;
  } else if (wok_diag_count(d) == 0) {
    (*clean)++;
    // Accepted input must produce a tree the dump can state and read back.
    char *dump1 = wok_sexpr_dump_string(file, (const char *)data, a);
    if (!dump1) {
      snprintf(msg, sizeof msg, "clean parse produced an undumpable tree");
      fail = msg;
    } else {
      WokDiagSink *rd = wok_diag_new(a, "<dump>", dump1, strlen(dump1));
      const char *text = nullptr;
      WokNode *back = wok_sexpr_read(dump1, strlen(dump1), a, rd, &text);
      if (!back) {
        snprintf(msg, sizeof msg, "clean parse: dump did not read back");
        fail = msg;
      } else {
        char *dump2 = wok_sexpr_dump_string(back, text, a);
        if (!dump2 || strcmp(dump1, dump2) != 0) {
          snprintf(msg, sizeof msg, "clean parse: dump did not round-trip");
          fail = msg;
        }
      }
    }
  }
  wok_arena_free(a);
  return fail;
}
