// The rosters, checked against what the scanner actually produces.
//
// A roster checked against another hand-written roster is not checked at all,
// so every check here goes through the real scanner.

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <string.h>

#include "../wok_arena.h"
#include "../wok_token.h"
#include "check.h"

// The readable definitions the bitmaps must agree with, for all 256 bytes.
static bool ref_sym(unsigned char c) {
  return strchr("!#$%&*+-/:<=>?@^|~", (char)c) != nullptr && c != '\0';
}
static bool ref_ident_start(unsigned char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}
static bool ref_ident_cont(unsigned char c) {
  return ref_ident_start(c) || (c >= '0' && c <= '9') || c == '\'';
}

static WokTokens scan_str(const char *s, WokArena *a, WokDiagSink **out_d) {
  usize n = strlen(s);
  WokDiagSink *d = wok_diag_new(a, "<roster>", s, n);
  if (out_d) *out_d = d;
  return wok_scan(s, n, a, d).tokens;
}

int main(void) {
  // --- character classes, exhaustively over the byte space -----------------
  for (int i = 0; i < 256; i++) {
    unsigned char c = (unsigned char)i;
    CHECK(wok_test_is_sym(c) == ref_sym(c), "is_sym disagrees on 0x%02x", i);
    CHECK(wok_test_is_ident_start(c) == ref_ident_start(c),
          "is_ident_start disagrees on 0x%02x", i);
    CHECK(wok_test_is_ident_cont(c) == ref_ident_cont(c),
          "is_ident_cont disagrees on 0x%02x", i);
  }

  // --- every Kind has a name ----------------------------------------------
  for (int k = 0; k < WOK_KIND_COUNT; k++) {
    const char *nm = wok_kind_name((WokKind)k);
    CHECK(nm && nm[0] == 'W', "kind %d has no name", k);
  }

  // --- every Word is PRODUCIBLE -------------------------------------------
  // A word with no spelling, or one that lexes as a different kind, is a
  // branch in the parser that can never fire.
  for (int w = WW_NONE + 1; w < WOK_WORD_COUNT; w++) {
    const char *text = wok_word_text((WokWord)w);
    CHECK(text && text[0] != '\0', "word %d has no spelling", w);
    if (!text || !text[0]) continue;

    WokArena *a = wok_arena_new(1 << 12);
    WokTokens t = scan_str(text, a, nullptr);
    CHECK(t.n == 2, "scanning `%s` gave %zu tokens, expected 1 plus EOF", text,
          t.n);
    if (t.n == 2) {
      CHECK(t.tok[0].word == w, "scanning `%s` produced word %u, expected %d",
            text, t.tok[0].word, w);
      CHECK((WokKind)t.tok[0].kind == wok_word_kind((WokWord)w),
            "scanning `%s` produced kind %s, roster says %s", text,
            wok_kind_name((WokKind)t.tok[0].kind),
            wok_kind_name(wok_word_kind((WokWord)w)));
    }
    wok_arena_free(a);
  }

  // --- contextual words stay ordinary identifiers --------------------------
  // spec.md section 2 writes `Bytes.copy` itself; reserving `copy` would take
  // the name from the program that needs it.
  {
    WokArena *a = wok_arena_new(1 << 12);
    WokTokens t = scan_str("copy own lend row eff", a, nullptr);
    for (usize i = 0; i + 1 < t.n; i++)
      CHECK((WokKind)t.tok[i].kind == WT_VARID,
            "contextual word %zu lexed as %s, must stay WT_VARID", i,
            wok_kind_name((WokKind)t.tok[i].kind));
    wok_arena_free(a);
  }

  // --- the line-comment rule ----------------------------------------------
  // Taking the maximal operator run FIRST is what stops `-->` becoming a
  // comment. This is the bug a regexp rule table reintroduces every time the
  // operator charset gains a character.
  {
    struct {
      const char *src;
      usize want_tokens;  // excluding EOF
      const char *note;
    } cases[] = {
        {"-- a comment", 0, "two dashes start a comment"},
        {"--- also a comment", 0, "three dashes too"},
        {"--> x", 2, "`-->` is an operator, not a comment"},
        {"- 1", 2, "a single dash is an operator"},
        {"a -- b", 1, "comment ends the line"},
        {"{- {- nested -} -} x", 1, "nested block comments close correctly"},
    };
    for (usize i = 0; i < sizeof cases / sizeof *cases; i++) {
      WokArena *a = wok_arena_new(1 << 12);
      WokTokens t = scan_str(cases[i].src, a, nullptr);
      CHECK(t.n == cases[i].want_tokens + 1, "`%s`: %zu tokens, expected %zu (%s)",
            cases[i].src, t.n - 1, cases[i].want_tokens, cases[i].note);
      wok_arena_free(a);
    }
  }

  // --- reserved operator runs are recognised after the run, not by prefix --
  {
    struct { const char *src; WokKind want; } cases[] = {
        {"->", WT_ARROW},   {"=>", WT_FATARROW}, {"=", WT_EQUALS},
        {":", WT_COLON},    {"::", WT_COLONCOLON}, {":=", WT_ASSIGN},
        {"|", WT_BAR},      {"->>", WT_VARSYM},  {"==", WT_VARSYM},
        {"|||", WT_VARSYM}, {"<+>", WT_VARSYM},  {"+", WT_VARSYM},
    };
    for (usize i = 0; i < sizeof cases / sizeof *cases; i++) {
      WokArena *a = wok_arena_new(1 << 12);
      WokTokens t = scan_str(cases[i].src, a, nullptr);
      CHECK(t.n == 2 && (WokKind)t.tok[0].kind == cases[i].want,
            "`%s` lexed as %s, expected %s", cases[i].src,
            t.n == 2 ? wok_kind_name((WokKind)t.tok[0].kind) : "<split>",
            wok_kind_name(cases[i].want));
      wok_arena_free(a);
    }
  }

  // --- `_` is the wildcard; `_foo` is a name -------------------------------
  {
    WokArena *a = wok_arena_new(1 << 12);
    WokTokens t = scan_str("_ _foo", a, nullptr);
    CHECK(t.n == 3, "`_ _foo` gave %zu tokens", t.n);
    if (t.n == 3) {
      CHECK((WokKind)t.tok[0].kind == WT_UNDERSCORE, "`_` is the wildcard");
      CHECK((WokKind)t.tok[1].kind == WT_VARID, "`_foo` is a name");
    }
    wok_arena_free(a);
  }

  // --- case of the first character decides ConId vs VarId ------------------
  {
    WokArena *a = wok_arena_new(1 << 12);
    WokTokens t = scan_str("State state _x x'", a, nullptr);
    CHECK(t.n == 5, "expected four tokens plus EOF, got %zu", t.n);
    if (t.n == 5) {
      CHECK((WokKind)t.tok[0].kind == WT_CONID, "`State` is a ConId");
      CHECK((WokKind)t.tok[1].kind == WT_VARID, "`state` is a VarId");
      CHECK((WokKind)t.tok[2].kind == WT_VARID, "`_x` is a VarId");
      CHECK((WokKind)t.tok[3].kind == WT_VARID, "`x'` is a VarId");
    }
    wok_arena_free(a);
  }

  // --- negation is never glued (D-LEX-1) -----------------------------------
  {
    WokArena *a = wok_arena_new(1 << 12);
    WokTokens t = scan_str("1-2", a, nullptr);
    CHECK(t.n == 4, "`1-2` must lex as three tokens (subtraction), got %zu",
          t.n - 1);
    wok_arena_free(a);
  }

  // --- integer literals are range-checked ----------------------------------
  {
    struct { const char *src; bool ok; } cases[] = {
        {"0", true},
        {"18446744073709551615", true},   // U64 max
        {"18446744073709551616", false},  // one past
        {"99999999999999999999999", false},
    };
    for (usize i = 0; i < sizeof cases / sizeof *cases; i++) {
      WokArena *a = wok_arena_new(1 << 12);
      WokDiagSink *d = nullptr;
      WokTokens t = scan_str(cases[i].src, a, &d);
      u64 v = 0;
      bool ok = wok_token_int_value(cases[i].src, &t.tok[0], d, &v);
      CHECK(ok == cases[i].ok, "`%s`: range check said %d, expected %d",
            cases[i].src, (int)ok, (int)cases[i].ok);
      wok_arena_free(a);
    }
  }

  // --- `;` gets a targeted diagnostic (D22) --------------------------------
  {
    WokArena *a = wok_arena_new(1 << 12);
    WokDiagSink *d = nullptr;
    scan_str("a ; b", a, &d);
    CHECK(wok_diag_count(d) == 1 &&
              wok_diag_at(d, 0)->code == WOK_E_LEX_SEMI,
          "`;` must produce E-LEX-SEMI, got %zu diagnostics",
          wok_diag_count(d));
    wok_arena_free(a);
  }

  TEST_DONE();
}
