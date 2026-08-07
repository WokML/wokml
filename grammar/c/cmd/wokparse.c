// wokparse -- the CLI.
//
//   wokparse FILE.wok              print the AST as an s-expression (any
//                                  parse-clean file dumps; stage-4 checks
//                                  belong to -check-only and -json)
//   wokparse -tokens FILE.wok      the token stream, with positions
//   wokparse -layout FILE.wok      the stream after the layout filter
//   wokparse -check-only FILE.wok  parse, resolve, report faults; print nothing else
//   wokparse -json FILE.wok        the same faults, one JSON object per line
//   wokparse -sexp -reorder FILE.wok
//                                  parse -> resolve -> reorder -> dump: the
//                                  s-expression carries precedence-RESOLVED
//                                  chains instead of flat ones. `-reorder`
//                                  is a modifier of `-sexp`, not a mode of
//                                  its own -- it is an error without it (see
//                                  docs/superpowers/specs/
//                                  2026-08-07-sexp-reorder-pass.md).
//
// Human diagnostics are `file:line:col: message`, which every editor and CI
// log already jumps to. A batch is printed, not the first fault.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../wok_arena.h"
#include "../wok_ast.h"
#include "../wok_diag.h"
#include "../wok_layout.h"
#include "../wok_parse.h"
#include "../wok_reorder.h"
#include "../wok_resolve.h"
#include "../wok_sexpr.h"
#include "../wok_token.h"

typedef enum { M_SEXP, M_TOKENS, M_LAYOUT, M_CHECK, M_JSON } Mode;

static char *slurp(const char *path, usize *n) {
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

static void print_tokens(WokTokens t, const char *src, const WokDiagSink *d) {
  for (usize i = 0; i < t.n; i++) {
    u32 line, col;
    wok_diag_position(d, t.tok[i].off, &line, &col);
    const char *nm = wok_kind_name((WokKind)t.tok[i].kind);
    printf("%4u:%-3u %-16s", line, col, nm);
    if (t.tok[i].word != WW_NONE)
      printf(" word=%s", wok_word_text((WokWord)t.tok[i].word));
    if (t.tok[i].len > 0 && (WokKind)t.tok[i].kind != WT_EOF)
      printf(" `%.*s`", (int)t.tok[i].len, src + t.tok[i].off);
    if ((t.tok[i].flags & WOK_TF_FIRST_ON_LINE) != 0) printf("  [line-start]");
    putchar('\n');
  }
}

int main(int argc, char **argv) {
  Mode mode = M_SEXP;
  bool saw_sexp = false;
  bool reorder = false;
  int argi = 1;
  for (; argi < argc && argv[argi][0] == '-'; argi++) {
    if (strcmp(argv[argi], "-tokens") == 0) mode = M_TOKENS;
    else if (strcmp(argv[argi], "-layout") == 0) mode = M_LAYOUT;
    else if (strcmp(argv[argi], "-check-only") == 0) mode = M_CHECK;
    else if (strcmp(argv[argi], "-sexp") == 0) { mode = M_SEXP; saw_sexp = true; }
    else if (strcmp(argv[argi], "-json") == 0) mode = M_JSON;
    else if (strcmp(argv[argi], "-reorder") == 0) reorder = true;
    else {
      fprintf(stderr, "wokparse: unknown flag %s\n", argv[argi]);
      return 2;
    }
  }
  if (argi >= argc) {
    fprintf(stderr, "usage: wokparse [-tokens|-layout|-sexp[-reorder]|"
                    "-check-only|-json] FILE.wok\n");
    return 2;
  }
  // `-reorder` reassociates the very chains `-sexp` dumps, so it means
  // nothing under any other mode -- and nothing implicitly either: -sexp is
  // the default mode, but a bare `wokparse -reorder FILE` did not ASK for
  // the dump `-reorder` modifies, so it is refused rather than guessed. The
  // MODE check (not just "was -sexp typed") is what catches `-sexp -json
  // -reorder`: a later mode flag overrides -sexp, and -reorder would
  // otherwise silently do nothing under the mode that won.
  if (reorder && (!saw_sexp || mode != M_SEXP)) {
    fprintf(stderr, "wokparse: -reorder requires -sexp\n");
    return 2;
  }

  int status = 0;
  for (; argi < argc; argi++) {
    usize n = 0;
    char *src = slurp(argv[argi], &n);
    if (!src) {
      fprintf(stderr, "wokparse: cannot read %s\n", argv[argi]);
      status = 2;
      continue;
    }
    WokArena *a = wok_arena_new(0);
    WokDiagSink *d = wok_diag_new(a, argv[argi], src, n);

    WokScanResult sr = wok_scan(src, n, a, d);
    WokTokens lay = wok_layout(sr.tokens, a, d);

    if (mode == M_TOKENS) {
      print_tokens(sr.tokens, src, d);
    } else if (mode == M_LAYOUT) {
      print_tokens(lay, src, d);
    } else {
      WokNode *file = wok_parse(lay, src, a, d);
      bool parsed = wok_diag_count(d) == 0;
      // Resolution runs only over a clean parse: a damaged tree has holes
      // where the names and counts belong, and the parse fault already said
      // the true thing about them. And it runs only in the CHECK modes, or
      // under -sexp -reorder where the reorder pass needs resolve's fixity
      // table -- plain -sexp stays the dump tool, and a stage-4 fault must
      // not cost the reader the very tree the fault is about.
      if (parsed && (mode == M_CHECK || mode == M_JSON)) {
        wok_resolve(file, src, a, d);
      } else if (parsed && mode == M_SEXP && reorder) {
        WokFixTable fix = {0};
        wok_resolve_fix(file, src, a, d, &fix);
        if (wok_diag_count(d) == 0)
          file = (WokNode *)wok_reorder(file, src, a, d, &fix);
      }
      if (mode == M_SEXP && parsed && wok_diag_count(d) == 0)
        wok_sexpr_dump(file, src, stdout);
    }

    if (wok_diag_count(d) > 0) {
      if (mode == M_JSON) wok_diag_render_jsonl(d, stdout);
      else wok_diag_render(d, stderr);
      status = 1;
    }
    // JSON Lines: no diagnostics means no output, not an empty container.

    wok_arena_free(a);
    free(src);
  }
  return status;
}
