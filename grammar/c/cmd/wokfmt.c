// wok fmt -- the canonical formatter, and the linter that is the same thing
// asking a question.
//
//   wok fmt FILE...            print the canonical form to stdout
//   wok fmt -w FILE...         rewrite each file in place
//   wok fmt --check FILE...    exit non-zero if any file is not canonical
//   wok fmt --pipe < FILE      source on stdin, canonical form on stdout
//   wok fmt --pipe --check     ... the verdict only, as an exit code
//
// The tool is one-shot by design. Measured: process creation costs 1.46 ms and
// is indistinguishable from an empty binary; a 750-file project checks in
// 11.7 ms. There is nothing a cache could save that is worth the staleness it
// would risk.

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../wok_arena.h"
#include "../wok_ast.h"
#include "../wok_diag.h"
#include "../wok_parse.h"
#include "../wok_print.h"
#include "../wok_sexpr.h"
#include "../wok_shape.h"
#include "../wok_write.h"
#include "../wok_token.h"

typedef enum { M_STDOUT, M_WRITE, M_CHECK } Mode;

static char *slurp(const char *path, usize *n) {
  FILE *fp = fopen(path, "rb");
  if (!fp) return nullptr;
  if (fseek(fp, 0, SEEK_END) != 0) { fclose(fp); return nullptr; }
  long sz = ftell(fp);
  if (sz < 0) { fclose(fp); return nullptr; }
  rewind(fp);
  char *b = (char *)malloc((usize)sz + 1);
  if (!b) { fclose(fp); return nullptr; }
  usize got = fread(b, 1, (usize)sz, fp);
  b[got] = '\0';
  *n = got;
  fclose(fp);
  return b;
}


// `stamp` is nullptr in PIPE mode: there is no file to guard against a
// concurrent edit and none to replace, so interlock B does not apply. Every
// other check does -- a pipe is not an excuse to skip the safety properties.
static int process_text(const char *path, const char *src, usize n, Mode mode,
                        const WokFileStamp *stamp) {

  WokArena *a = wok_arena_new(0);
  WokDiagSink *d = wok_diag_new(a, path, src, n);
  WokNode *tree = wok_parse_source(src, n, a, d);
  if (wok_diag_count(d) != 0) {
    wok_diag_render(d, stderr);
    wok_arena_free(a);
      return 1;  // input that does not parse has no canonical form
  }

  wok_print_reports_reset();
  char *formatted = wok_print_string_named(tree, src, a, path);
  usize fn = strlen(formatted);

  // INTERLOCK A0: the printer's own safety property. A line break that is not
  // a continuation line changes the tree rather than the text, and the printer
  // says so at the moment it writes one.
  int rc = 0;
  // INTERLOCK A0b: a node with no canonical form at all. Until this counter
  // existed the only guard was that such a tree can reach here solely from a
  // parse that already reported a diagnostic -- true, but by ORDERING rather
  // than by check, so it held only as long as nobody added a second way in.
  if (wok_print_unprintable_count() != 0) {
    fprintf(stderr, "wok fmt: INTERNAL: %s holds a node with no canonical "
                    "form; refusing to write\n", path);
    rc = 2;
  }
  if (rc == 0 && wok_print_fault_count() != 0) {
    fprintf(stderr, "wok fmt: INTERNAL: %s was filled with an unsafe line "
                    "break; refusing to write\n", path);
    rc = 2;
  }

  // INTERLOCK A: did formatting change the PROGRAM? The dump is the canonical,
  // position-free identity of a program, so comparing dumps answers exactly
  // that -- and unlike a fingerprint, it can say what differed.
  WokDiagSink *rd = wok_diag_new(a, path, formatted, fn);
  WokNode *reparsed = wok_parse_source(formatted, fn, a, rd);
  if (rc != 0) {
    // already refused
  } else if (wok_diag_count(rd) != 0) {
    fprintf(stderr, "wok fmt: INTERNAL: %s does not re-parse after formatting; "
                    "refusing to write\n", path);
    wok_diag_render(rd, stderr);
    rc = 2;
  } else {
    char *before = wok_sexpr_dump_string(tree, src, a);
    char *after = wok_sexpr_dump_string(reparsed, formatted, a);
    if (!before || !after || strcmp(before, after) != 0) {
      fprintf(stderr, "wok fmt: INTERNAL: formatting %s would CHANGE THE "
                      "PROGRAM; refusing to write\n", path);
      rc = 2;
    }
  }

  if (rc == 0) {
    if (mode == M_CHECK) {
      WokDiagSink *sd = wok_diag_new(a, path, src, n);
      char *want = wok_shape(formatted, fn, a, sd);
      char *have = wok_shape(src, n, a, sd);
      if (strcmp(want, have) != 0) {
        // In pipe mode stdout is the payload channel, so the name would be
        // noise: an agent reads the exit code.
        if (stamp != nullptr) printf("%s\n", path);
        rc = 1;
      }
    } else if (mode == M_STDOUT) {
      fwrite(formatted, 1, fn, stdout);
    } else {
      // INTERLOCK B, the owner's rule, plus an atomic replace: the file is
      // written to a temporary and renamed, so no crash or full disk can
      // leave the user's source truncated, and a concurrent save is refused
      // rather than clobbered.
      switch (wok_write_atomic(path, formatted, fn, *stamp)) {
        case WOK_WRITE_OK:
        case WOK_WRITE_UNCHANGED:
          break;
        case WOK_WRITE_MOVED:
          fprintf(stderr, "wok fmt: %s changed on disk while formatting; "
                          "not written\n", path);
          rc = 2;
          break;
        case WOK_WRITE_FAILED:
          fprintf(stderr, "wok fmt: could not write %s; it is unchanged\n", path);
          rc = 2;
          break;
      }
    }
  }

  wok_arena_free(a);
  return rc;
}

static int process_file(const char *path, Mode mode) {
  usize n = 0;
  char *src = slurp(path, &n);
  if (!src) {
    fprintf(stderr, "wok fmt: cannot read %s\n", path);
    return 2;
  }
  WokFileStamp at_read = wok_file_stamp(path);
  int rc = process_text(path, src, n, mode, &at_read);
  free(src);
  return rc;
}

// --pipe: source on stdin, canonical form on stdout. For an agent or an editor
// that has the text in hand and does not want to invent a temporary file.
static int process_stdin(Mode mode) {
  usize cap = 1 << 16, n = 0;
  char *src = (char *)malloc(cap);
  if (!src) return 2;
  for (;;) {
    if (n == cap) {
      cap *= 2;
      char *bigger = (char *)realloc(src, cap);
      if (!bigger) { free(src); return 2; }
      src = bigger;
    }
    usize got = fread(src + n, 1, cap - n, stdin);
    n += got;
    if (got == 0) break;
  }
  src[n < cap ? n : cap - 1] = '\0';
  int rc = process_text("<stdin>", src, n, mode, nullptr);
  free(src);
  return rc;
}

int main(int argc, char **argv) {
  Mode mode = M_STDOUT;
  bool pipe_mode = false;
  int i = 1;
  for (; i < argc && argv[i][0] == '-' && argv[i][1] != '\0'; i++) {
    if (strcmp(argv[i], "-w") == 0) mode = M_WRITE;
    else if (strcmp(argv[i], "--check") == 0) mode = M_CHECK;
    else if (strcmp(argv[i], "--pipe") == 0) pipe_mode = true;
    else {
      fprintf(stderr, "wok fmt: unknown flag %s\n", argv[i]);
      return 2;
    }
  }

  if (pipe_mode) {
    if (mode == M_WRITE) {
      fprintf(stderr, "wok fmt: --pipe has no file to write; use --pipe alone "
                      "for the formatted text, or --pipe --check for the "
                      "verdict\n");
      return 2;
    }
    if (i < argc) {
      fprintf(stderr, "wok fmt: --pipe reads stdin; do not also name files\n");
      return 2;
    }
    return process_stdin(mode);
  }

  if (i >= argc) {
    fprintf(stderr, "usage: wokfmt [-w|--check] FILE...\n"
                    "       wokfmt --pipe [--check] < FILE\n");
    return 2;
  }
  int worst = 0;
  for (; i < argc; i++) {
    int rc = process_file(argv[i], mode);
    if (rc > worst) worst = rc;
  }
  return worst;
}
