// Unit tests for wok_shape -- the normal form `wok fmt --check` compares.
//
// Every case is stated as a PAIR plus a verdict, because the function's whole
// contract is which differences it hides and which it must not. A test that
// only asserted "these two are equal" would be satisfied by a function that
// returns the empty string.

#include <string.h>

#include "../wok_arena.h"
#include "../wok_shape.h"
#include "check.h"

static char *shape(const char *src, WokArena *a) {
  WokDiagSink *d = wok_diag_new(a, "<shape>", src, strlen(src));
  return wok_shape(src, strlen(src), a, d);
}

typedef struct {
  const char *a;
  const char *b;
  bool same;
  const char *why;
} Pair;

int main(void) {
  static const Pair cases[] = {
      // ---- what --check MUST IGNORE -------------------------------------
      {"get      -> cur\n", "get -> cur\n", true,
       "arrow alignment padding is not part of the standard"},
      {"f x    = 1\n", "f x = 1\n", true, "any run of >=2 spaces collapses"},
      {"a  +  b\n", "a + b\n", true, "padding around an operator"},
      {"f = 1   \n", "f = 1\n", true, "trailing whitespace"},
      {"f = 1\n\n\ng = 2\n", "f = 1\ng = 2\n", true,
       "blank lines are not tokens; the printer decides them"},

      // ---- 7a: a WRAPPED line's indentation ------------------------------
      // The filler aligns a capability row under its own `with`, so renaming
      // the function moves that column and reflows every line under it.
      // Comparing those columns exactly would fail --check on a rename --
      // exactly the churn arrow alignment was exempted to avoid -- so a line
      // whose first token is a CONTINUATION lead has its indentation clamped.
      {"f : A\n     with E\n        + F\n", "f : A\n  with E\n  + F\n", true,
       "a wrapped capability row's alignment is not part of the standard"},
      {"f = a\n     + b\n", "f = a\n  + b\n", true,
       "nor a wrapped chain's"},
      {"type T = A\n  | B\n", "type T = A\n         | B\n", true,
       "nor a wrapped alternative's"},
      {"xs = [ a\n     , b\n     ]\n", "xs = [ a\n , b\n ]\n", true,
       "nor a wrapped list's, whose separators lead their lines too"},

      // ---- what --check MUST STILL CATCH ---------------------------------
      // The other half of 7a: only INDENTATION is exempt. Whether a break
      // happened at all, and where, is line structure and is still compared.
      {"f = a + b\n", "f = a\n  + b\n", false,
       "WHERE the filler broke is still enforced; only the column is not"},
      {"f = a\n  + b\n  + c\n", "f = a\n  + b + c\n", false,
       "all-or-nothing per group: two breaks are not one"},
      {"f = 1\n  -- note\n", "f = 1\n   -- note\n", false,
       "a comment is not a continuation lead, so its column is still exact"},
      {"a+b\n", "a + b\n", false,
       "gap 0 vs gap 1 is operator spacing, which IS the standard"},
      {"  get -> cur\n", "   get -> cur\n", false,
       "indentation is compared exactly: 2 spaces vs 3"},
      {"f = 1\ng = 2\n", "f = 1 g = 2\n", false, "line structure"},
      {"f = 1\n", "f = 2\n", false, "the program itself"},
      {"f = a\n", "f = b\n", false, "an identifier"},

      // ---- literals are tokens, so their interior is untouchable ---------
      {"f = \"a  b\"\n", "f = \"a b\"\n", false,
       "two spaces INSIDE a string literal are content, not padding"},
      {"f = \"  x\"\n", "f = \" x\"\n", false,
       "leading spaces inside a literal are content"},
      {"f = \"a -> b\"\n", "f = \"a  -> b\"\n", false,
       "an arrow inside a literal is not an arrow to align"},

      // ---- comments are items, not whitespace ----------------------------
      // This is what stops --check calling a file canonical after the
      // formatter has deleted every comment in it.
      {"-- note\nf = 1\n", "f = 1\n", false, "a DELETED comment is a difference"},
      {"-- one\nf = 1\n", "-- two\nf = 1\n", false, "comment text"},
      {"f = 1 -- trailing\n", "-- trailing\nf = 1\n", false,
       "a MOVED comment is a difference"},
      {"f = 1   -- pad\n", "f = 1 -- pad\n", true,
       "but padding BEFORE a trailing comment is still just padding"},
      {"{- block -}\nf = 1\n", "f = 1\n", false, "a deleted block comment"},
      {"{- a\n   b -}\nf = 1\n", "{- a\n   b -}\nf = 1\n", true,
       "a multi-line block comment's interior is copied verbatim"},

      // ---- degenerate inputs ---------------------------------------------
      {"", "", true, "empty"},
      {"", "f = 1\n", false, "empty vs not"},
      {"-- only a comment\n", "-- only a comment\n", true, "comment-only file"},
      {"\n\n\n", "", true, "whitespace-only file has no items"},
  };

  for (usize i = 0; i < sizeof cases / sizeof *cases; i++) {
    WokArena *a = wok_arena_new(1 << 14);
    char *sa = shape(cases[i].a, a);
    char *sb = shape(cases[i].b, a);
    bool eq = strcmp(sa, sb) == 0;
    CHECK(eq == cases[i].same,
          "%s: expected %s\n      a = <<%s>>  shape <<%s>>\n"
          "      b = <<%s>>  shape <<%s>>",
          cases[i].why, cases[i].same ? "SAME" : "DIFFERENT", cases[i].a, sa,
          cases[i].b, sb);
    wok_arena_free(a);
  }

  // Determinism: the same input must shape identically every time, or
  // --check would be flaky.
  {
    WokArena *a = wok_arena_new(1 << 14);
    const char *src = "module M\nf : U64\nf = 1 + 2  -- hi\n";
    CHECK(strcmp(shape(src, a), shape(src, a)) == 0, "shape is not deterministic");
    wok_arena_free(a);
  }

  // Idempotence: a shape is already in normal form, so shaping it again must
  // be a no-op. This is what lets --check compare two shapes rather than
  // needing a fixed point.
  {
    WokArena *a = wok_arena_new(1 << 14);
    const char *src = "f  x   = 1\n  get      -> cur\n";
    char *once = shape(src, a);
    char *twice = shape(once, a);
    CHECK(strcmp(once, twice) == 0,
          "shape is not idempotent:\n  once  <<%s>>\n  twice <<%s>>", once,
          twice);
    wok_arena_free(a);
  }

  TEST_DONE();
}
