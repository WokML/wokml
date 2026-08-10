// Stage 4 over the conformance corpus. Two obligations, and the SECOND is
// the load-bearing one:
//
//   1. every reject file whose fault the front end can see reports it, with
//      the code its `-- EXPECT:` line names;
//   2. every OTHER file -- all 12 accepts, the tour, and the ten rejects
//      whose faults belong to a later analysis -- reports NOTHING.
//
// (2) matters more than (1) because a resolution pass that fires on a file
// whose fault is E-SHADOW or E-ESCAPE is worse than one that stays silent:
// the analysis that owns that fault is the one that knows the right message,
// and a wrong early message is what a reader acts on first.
//
// Which faults this stage can see is stated as a SET OF CODES (the checks
// implemented here), and each fixture's `-- EXPECT:` header says which code
// it carries -- so the file-level expectations are derived, not hand-kept.
// E-LABEL is in the registry and appears on two reject files, and neither
// fault is one this stage can see, so E-LABEL is not in the set.

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <stdio.h>
#include <string.h>

#include "../wok_arena.h"
#include "../wok_ast.h"
#include "../wok_diag.h"
#include "../wok_parse.h"
#include "../wok_resolve.h"
#include "check.h"

// The codes stage 4 RAISES -- a fact about which checks are implemented
// here, stated once per code instead of once per fixture. Which fixture
// carries which code is the fixture's own `-- EXPECT:` header, read the way
// test_parse_corpus.c reads it, so a new reject file with one of these
// codes joins the suite by existing.
//
// E-ARITY and E-VARSCOPE are SHARED codes (wok_diag.h): the front end
// raises the part decidable from the grammar and the declarations, the
// analyses raise the rest. Today every reject fixture carrying them is
// front-end-visible. If one arrives whose fault belongs downstream, this
// suite fails LOUDLY on it -- the right default for a checker test -- and
// the resolution is an explicit exception here, with the reason.
static const char *const stage4_codes[] = {"E-ARITY", "E-VARSCOPE"};

static bool stage4_raises(const char *code) {
  for (usize i = 0; i < sizeof stage4_codes / sizeof *stage4_codes; i++)
    if (strcmp(stage4_codes[i], code) == 0) return true;
  return false;
}

// One corpus file: parse, resolve, compare against what its own EXPECT
// header says filtered by the stage-4 code set. ctx is the rejects flag.
static int resolve_one(const char *path, void *vctx) {
  bool rejects = *(const bool *)vctx;
  usize n = 0;
  char *src = wok_test_slurp(path, &n);
  if (!src) {
    fprintf(stderr, "  FAIL cannot read %s\n", path);
    return 1;
  }
  int bad = 0;
  WokArena *a = wok_arena_new(0);
  WokDiagSink *d = wok_diag_new(a, path, src, n);
  WokNode *file = wok_parse_source(src, n, a, d);
  if (wok_diag_count(d) != 0) {
    fprintf(stderr, "  FAIL %s: does not parse; stage 4 never ran\n", path);
    wok_diag_render(d, stderr);
    bad++;
  } else {
    wok_resolve(file, src, a, d);
    char code[64];
    wok_test_expect_code(src, code, sizeof code);
    const char *want = rejects && stage4_raises(code) ? code : nullptr;
    usize got = wok_diag_count(d);
    if (!want && got != 0) {
      fprintf(stderr, "  FAIL %s: %zu diagnostic(s), expected silence\n",
              path, got);
      wok_diag_render(d, stderr);
      bad++;
    } else if (want) {
      if (got != 1) {
        fprintf(stderr, "  FAIL %s: expected exactly 1 %s, got %zu\n", path,
                want, got);
        wok_diag_render(d, stderr);
        bad++;
      } else if (strcmp(wok_diag_code_text(wok_diag_at(d, 0)->code), want) !=
                 0) {
        fprintf(stderr, "  FAIL %s: expected %s, got %s\n", path, want,
                wok_diag_code_text(wok_diag_at(d, 0)->code));
        bad++;
      }
    }
  }
  wok_arena_free(a);
  free(src);
  return bad;
}

// The arity itself, on hand-written pairs, because the corpus exercises only
// the counts its programs happen to use. The bracketed argument of
// `(U64 -> U64) -> U64` is the one that decides reject/02, and a spine walk
// that counted arrows anywhere would call it two.
typedef struct {
  const char *src;
  const char *want;  // nullptr for "no diagnostic"
} Case;

static const Case cases[] = {
    // A nullary op: `get : s` takes no argument, so a binder is one too many.
    {"module M\neffect E\n  get : U64\nh : U64\nh = handler E\n  get -> 1\n",
     nullptr},
    {"module M\neffect E\n  get : U64\nh : U64\nh = handler E\n  get x -> 1\n",
     "E-ARITY"},
    // The argument's own arrow is inside a bracket and is not on the spine.
    {"module M\neffect E\n  call : (U64 -> U64) -> U64\nh : U64\n"
     "h = handler E\n  call f, k -> k (f 41)\n",
     nullptr},
    {"module M\neffect E\n  call : (U64 -> U64) -> U64\nh : U64\n"
     "h = handler E\n  call f k -> k (f 41)\n",
     "E-ARITY"},
    // Two arguments, control: the count is taken LEFT of the comma only.
    {"module M\neffect E\n  put : U64 -> U64 -> ()\nh : U64\nh = handler E\n"
     "  put a b, k -> k ()\n",
     nullptr},
    {"module M\neffect E\n  put : U64 -> U64 -> ()\nh : U64\nh = handler E\n"
     "  put a, k -> k ()\n",
     "E-ARITY"},
    // `abort` counts at op arity, and the continuation position does not
    // exist to be filled.
    {"module M\neffect E\n  quit : U64 -> Never\nh : U64\nh = handler E\n"
     "  abort quit n -> 0\n",
     nullptr},
    {"module M\neffect E\n  quit : U64 -> Never\nh : U64\nh = handler E\n"
     "  abort quit n k -> 0\n",
     "E-ARITY"},
    // Several clauses for one op are legal with refutable patterns, but they
    // merge into one arm, so they cannot resume differently.
    {"module M\neffect E\n  req : U64 -> U64\nh : U64\nh = handler E\n"
     "  req 0, k -> k 1\n  req n, k -> k n\n",
     nullptr},
    {"module M\neffect E\n  req : U64 -> U64\nh : U64\nh = handler E\n"
     "  req 0, k -> k 1\n  req n -> n\n",
     "E-ARITY"},
    // ...and the disagreement is ONE fault per op, however many later
    // clauses repeat the other kind.
    {"module M\neffect E\n  req : U64 -> U64\nh : U64\nh = handler E\n"
     "  req 0 -> 0\n  req 1, k -> k 1\n  req n, k -> k n\n",
     "E-ARITY"},
    // A same-file ALIAS can hide arrows, so the arity walk expands it: the
    // correct clause for `set : Setter` is not a false E-ARITY...
    {"module M\nalias Setter = U64 -> ()\neffect E\n  set : Setter\n"
     "h : U64\nh = handler E\n  set x -> ()\n",
     nullptr},
    // ...and the count it yields is still CHECKED.
    {"module M\nalias Setter = U64 -> ()\neffect E\n  set : Setter\n"
     "h : U64\nh = handler E\n  set -> ()\n",
     "E-ARITY"},
    // A parameterized alias would need substitution to expand, so the arity
    // is UNKNOWN and nothing is checked -- a skipped check, not a guess.
    {"module M\nalias F a = a -> ()\neffect E\n  set : F U64\n"
     "h : U64\nh = handler E\n  set x -> ()\n",
     nullptr},
    // An alias cycle comes out unknown rather than hanging the walk.
    {"module M\nalias A = A\neffect E\n  op : A\n"
     "h : U64\nh = handler E\n  op x y -> 1\n",
     nullptr},
    // An op the effect does not declare, and an undeclared effect: both are
    // held until the registry names a code for them (slice spec section 2).
    {"module M\neffect E\n  req : U64 -> U64\nh : U64\nh = handler E\n"
     "  nosuch x y z -> 1\n",
     nullptr},
    {"module M\nh : U64\nh = handler Nope\n  req x y z -> 1\n", nullptr},
    // A reserved word in op-name position is a PARSE-time fault, so it is
    // reported before this stage would ever see the clause.
    {"module M\neffect E\n  once : U64 -> U64\nh : U64\nh = 1\n",
     "E-RESERVED"},
    // TWO NAMESPACES. An op name is scoped inside its effect, so two effects
    // may both declare `get` and nothing here compares them...
    {"module M\neffect E\n  get : U64\neffect F\n  get : U64\nh : U64\n"
     "h = handler E\n  get -> 1\n",
     nullptr},
    // ...while an effect name is global to the file, so declaring one twice
    // is a redeclaration, reported at the SECOND and naming the first.
    {"module M\neffect E\n  get : U64\neffect E\n  get : U64\nh : U64\n"
     "h = handler E\n  get -> 1\n",
     "E-DUPLICATE"},
    // FIXITY. The order is partial, so the checks are about the ORDER being
    // one, not about levels being consistent.
    {"module M\nfixity + left\nfixity * left tighter than +\n"
     "f : U64\nf = 1 + 2 * 3\n",
     nullptr},
    // Both spellings of one edge, and a chain that uses both operators.
    {"module M\nfixity + left\nfixity * left looser than +\n"
     "f : U64\nf = 1 + 2 * 3\n",
     nullptr},
    // A run of ONE operator needs no order at all: ties are associativity.
    {"module M\nfixity ++ right\nf : U64\nf = 1 ++ 2 ++ 3\n", nullptr},
    // Two `fixity` lines for one operator.
    {"module M\nfixity + left\nfixity + right\nf : U64\nf = 1\n",
     "E-DUPLICATE"},
    // A dropped duplicate contributes NOTHING: `*` is named only by the
    // loser, so it stays UNKNOWN at the use site and the chain is skipped --
    // one fault, the duplicate, not a second about an operator the winning
    // table never heard of.
    {"module M\nfixity + left\nfixity + right tighter than *\n"
     "f : U64\nf = 1 + 2 * 3\n",
     "E-DUPLICATE"},
    // Self-reference is the one-node cycle, and the closure finds it with the
    // same bit as any other.
    {"module M\nfixity + left tighter than +\nf : U64\nf = 1\n", "E-FIXITY"},
    {"module M\nfixity a left tighter than b\nfixity b left tighter than c\n"
     "fixity c left tighter than a\nf : U64\nf = 1\n",
     "E-FIXITY"},
    // Declared, but with no path between them and nothing looser standing
    // between the occurrences: the chain has no loosest operator, and that
    // is a fault about the CHAIN, at the use site.
    {"module M\nfixity + left\nfixity ++ right\nf : U64\nf = 1 ++ 2 + 3\n",
     "E-FIXITY"},
    // ...and one fault per chain, not one per pair.
    {"module M\nfixity + left\nfixity ++ right\nf : U64\n"
     "f = 1 ++ 2 + 3 ++ 4\n",
     "E-FIXITY"},
    // THE SHIELD RULE. `*` and `/` are unrelated, but the `+` standing
    // between them is looser than both: the split at `+` separates them
    // before they ever compete, so the chain reassociates fine.
    {"module M\nfixity + left\nfixity * left tighter than +\n"
     "fixity / left tighter than +\nf : U64\nf = 2 * 3 + 8 / 4\n",
     nullptr},
    // Same operators, no shield between the occurrences: positional, and
    // the position is the difference.
    {"module M\nfixity + left\nfixity * left tighter than +\n"
     "fixity / left tighter than +\nf : U64\nf = 2 * 3 / 4 + 8\n",
     "E-FIXITY"},
    // Per OCCURRENCE pair, not per distinct pair: the first `*` is shielded
    // from `/` by the `+`, the second `*` is not.
    {"module M\nfixity + left\nfixity * left tighter than +\n"
     "fixity / left tighter than +\nf : U64\nf = 1 * 2 + 3 * 4 / 5\n",
     "E-FIXITY"},
    // An UNKNOWN occurrence between an incomparable pair may be a shield --
    // it may be looser than both -- so partial knowledge stays silent.
    {"module M\nfixity + left\nfixity ++ right\nf : U64\n"
     "f = 1 ++ 2 <?> 3 + 4\n",
     nullptr},
    // PARTIAL KNOWLEDGE. An operator this file never declares is skipped,
    // because `fixity` lives in the module that defines the operator and this
    // tool reads one file. Reporting it would fire on every real program.
    {"module M\nfixity + left\nf : U64\nf = 1 <?> 2 + 3\n", nullptr},
    {"module M\nf : U64\nf = 1 ++ 2 + 3\n", nullptr},
    // A relation naming a neighbour declared later in the same file still
    // resolves: the table is built from the whole file before anything is
    // asked of it.
    {"module M\nfixity * left tighter than +\nfixity + left\n"
     "f : U64\nf = 1 + 2 * 3\n",
     nullptr},
    // WRITE-LOCALITY (D27). The plain case: a baton written in a clause body
    // of the handler that declares it.
    {"module M\neffect E\n  set : U64 -> ()\nh : U64\nh = handler E\n"
     "  var cur = 0\n  set x -> cur := x\n",
     nullptr},
    // A block, a `case` arm and an `if` branch form no function, so a write
    // inside one is still in the clause body it was written in.
    {"module M\neffect E\n  set : U64 -> ()\nh : U64\nh = handler E\n"
     "  var cur = 0\n  set x -> case x == 0 of\n    True  -> cur := 1\n"
     "    False -> cur := x\n",
     nullptr},
    // A LAMBDA is a boundary: the slot never travels, so a write from inside
    // one would be an escaping mutable reference.
    {"module M\neffect E\n  set : U64 -> ()\nh : U64\nh = handler E\n"
     "  var cur = 0\n  set x -> apply (\\y -> cur := y)\n",
     "E-VARSCOPE"},
    // So is a NESTED HANDLER LITERAL, for the same reason plus C9: handler
    // values are first class.
    {"module M\neffect E\n  set : U64 -> ()\neffect F\n  get : U64\n"
     "h : U64\nh = handler E\n  var cur = 0\n"
     "  set x -> inner (handler F get -> cur := 1)\n",
     "E-VARSCOPE"},
    // A local function equation is the third boundary.
    {"module M\neffect E\n  set : U64 -> ()\nh : U64\nh = handler E\n"
     "  var cur = 0\n  set x ->\n    let bump y = cur := y\n    bump x\n",
     "E-VARSCOPE"},
    // No frame anywhere: ordinary code mutating an ordinary let.
    {"module M\nf : U64\nf =\n  let s = 5\n  s := 6\n  s\n", "E-VARSCOPE"},
    // A name that is not bound at all still gets the frame answer, because
    // the missing thing is the `var`, not the value.
    {"module M\nf : U64\nf =\n  s := 6\n  0\n", "E-VARSCOPE"},
    // D26's rebind idiom is NOT a write and must stay silent -- accept/11 in
    // miniature. Each `off` reads the outer one and shadows it.
    {"module M\ng : U64 -> U64\ng n = n\nf : U64\nf =\n  let off = 0\n"
     "  let a = g off\n  let off = off + 4\n  g off\n",
     nullptr},
    // A DESTRUCTURING let binds several names for the rest of the block.
    // The names must survive the binding statement (the env chain is
    // re-homed off the walker's stack -- this case is the ASan regression
    // for the dangling-env bug), and each resolves as a VALUE.
    {"module M\neffect E\n  set : U64 -> ()\nh : U64\nh = handler E\n"
     "  var cur = 0\n  set x ->\n    let (a, b) = x\n    cur := b\n",
     nullptr},
    {"module M\neffect E\n  set : U64 -> ()\nh : U64\nh = handler E\n"
     "  var cur = 0\n  set x ->\n    let (a, b) = x\n    a := 1\n",
     "E-VARSCOPE"},
    // A `handle` label is a VALUE binding the walk must see: a capability
    // shadowing a `var` baton turns a later write into a write to the
    // capability -- the exact idiom the repair message recommends.
    {"module M\neffect E\n  set : U64 -> ()\nh : U64\nh = handler E\n"
     "  var cur = 0\n  set x ->\n    handle cur = state 0\n    cur := x\n",
     "E-VARSCOPE"},
    // ...and so is a `use ... as` name, in its inline form.
    {"module M\neffect E\n  set : U64 -> ()\nh : U64\nh = handler E\n"
     "  var cur = 0\n  set x ->\n    use q as cur in cur := x\n",
     "E-VARSCOPE"},
    // A baton is in scope in the clause body of a LATER clause too: a frame
    // is one activation, not a sequence of bindings.
    {"module M\neffect E\n  get : U64\n  set : U64 -> ()\nh : U64\n"
     "h = handler E\n  get   -> 0\n  set x -> cur := x\n  var cur = 0\n",
     nullptr},
    // First declaration wins, and it wins by being the only one in the table:
    // the duplicate is dropped, so the clause is checked against arity 1 and
    // the second declaration's arity 2 never gets a say. One fault, not two.
    {"module M\neffect E\n  set : U64 -> ()\neffect E\n  set : U64 -> U64 -> ()\n"
     "h : U64\nh = handler E\n  set x -> ()\n",
     "E-DUPLICATE"},
};

// A dropped duplicate's edges die with it. The second `fixity +` line is
// reported AND its `tighter than *` edge stays out of the table, so the
// chain still has no order between `+` and `*` -- two faults, in emission
// order. Before the fix, the loser's edge leaked in and silenced the second.
typedef struct {
  const char *src;
  const char *want[2];
} TwoFaultCase;

static const TwoFaultCase two_fault_cases[] = {
    {"module M\nfixity + left\nfixity + right tighter than *\n"
     "fixity * left\nf : U64\nf = 1 + 2 * 3\n",
     {"E-DUPLICATE", "E-FIXITY"}},
    // A write buried in a malformed `:=` target is still a write: the
    // malformed target is one fault, and the inner `s := y` -- a fault in
    // any position -- is not hidden by its parent also being wrong.
    {"module M\nf : U64\nf =\n  g (\\y -> s := y) := 1\n  0\n",
     {"E-VARSCOPE", "E-VARSCOPE"}},
};

static int check_two_fault_cases(void) {
  int bad = 0;
  for (usize i = 0; i < sizeof two_fault_cases / sizeof *two_fault_cases;
       i++) {
    const TwoFaultCase *c = &two_fault_cases[i];
    usize n = strlen(c->src);
    WokArena *a = wok_arena_new(0);
    WokDiagSink *d = wok_diag_new(a, "<case>", c->src, n);
    WokNode *file = wok_parse_source(c->src, n, a, d);
    if (wok_diag_count(d) == 0) wok_resolve(file, c->src, a, d);
    usize got = wok_diag_count(d);
    if (got != 2) {
      fprintf(stderr, "  FAIL two-fault case %zu: expected 2, got %zu\n", i,
              got);
      wok_diag_render(d, stderr);
      bad++;
    } else {
      for (usize k = 0; k < 2; k++) {
        const char *code = wok_diag_code_text(wok_diag_at(d, k)->code);
        if (strcmp(code, c->want[k]) != 0) {
          fprintf(stderr, "  FAIL two-fault case %zu: diag %zu is %s, "
                  "expected %s\n", i, k, code, c->want[k]);
          bad++;
        }
      }
    }
    wok_arena_free(a);
  }
  return bad;
}

// Saturation is REPORTED, not silent: past 64 tracked names the checker's
// answers would be wrong, so the front end says so once (E-DEPTH, the
// implementation-capacity code) instead of proceeding on a dropped binder.
// Sources with 65 binders are built by loops, not spelled out.
static int expect_one_depth(const char *label, const char *src) {
  usize n = strlen(src);
  WokArena *a = wok_arena_new(0);
  WokDiagSink *d = wok_diag_new(a, "<case>", src, n);
  WokNode *file = wok_parse_source(src, n, a, d);
  int bad = 0;
  if (wok_diag_count(d) != 0) {
    fprintf(stderr, "  FAIL %s: does not parse\n", label);
    wok_diag_render(d, stderr);
    bad = 1;
  } else {
    wok_resolve(file, src, a, d);
    if (wok_diag_count(d) != 1 ||
        strcmp(wok_diag_code_text(wok_diag_at(d, 0)->code), "E-DEPTH") != 0) {
      fprintf(stderr, "  FAIL %s: expected exactly 1 E-DEPTH, got %zu\n",
              label, wok_diag_count(d));
      wok_diag_render(d, stderr);
      bad = 1;
    }
  }
  wok_arena_free(a);
  return bad;
}

static int check_capacity(void) {
  int bad = 0;
  char src[8192];
  usize at;

  // A pattern binding 65 names.
  at = (usize)snprintf(src, sizeof src, "module M\nf : U64\nf =\n  let (");
  for (int i = 0; i < 65; i++)
    at += (usize)snprintf(src + at, sizeof src - at, "%sa%d", i ? ", " : "", i);
  at += (usize)snprintf(src + at, sizeof src - at, ") = g\n  a0\n");
  bad += expect_one_depth("pattern capacity", src);

  // A handler declaring 65 `var` slots.
  at = (usize)snprintf(src, sizeof src,
                       "module M\neffect E\n  get : U64\nh : U64\n"
                       "h = handler E\n  get -> 0\n");
  for (int i = 0; i < 65; i++)
    at += (usize)snprintf(src + at, sizeof src - at, "  var v%d = 0\n", i);
  bad += expect_one_depth("baton capacity", src);

  // A block with 65 `let` bindings.
  at = (usize)snprintf(src, sizeof src, "module M\nf : U64\nf =\n");
  for (int i = 0; i < 65; i++)
    at += (usize)snprintf(src + at, sizeof src - at, "  let v%d = %d\n", i, i);
  at += (usize)snprintf(src + at, sizeof src - at, "  v0\n");
  bad += expect_one_depth("block let capacity", src);

  return bad;
}

// The VOICE regressions: E-VARSCOPE is one code with several differently
// worded raise sites, so these pin WHICH voice a case selects, via the
// phrase macros the resolver itself builds the message from (wok_resolve.h)
// -- rewording stays free, mis-selection does not.
typedef struct {
  const char *what;
  const char *src;
  const char *phrase;
} VoiceCase;

static const VoiceCase voice_cases[] = {
    // A write inside a `var` initialiser is a TIMING fault, not "no such
    // var": the slot exists in the source, just not yet in time.
    {"init write",
     "module M\neffect E\n  get : U64\nh : U64\nh = handler E\n"
     "  get -> 0\n  var a = 0\n  var b = (a := 1)\n",
     WOK_VOICE_INIT_WRITE},
    // An op arg shadowing an OUTER frame's baton must get the boundary
    // voice, not the shadow voice: un-shadowing would not license the write,
    // so "rename the binder" is not the repair.
    {"cross-frame shadow",
     "module M\neffect E\n  set : U64 -> ()\neffect F\n  op : U64 -> ()\n"
     "h : U64\nh = handler E\n  var cur = 0\n"
     "  set x -> inner (handler F op cur -> cur := 1)\n",
     WOK_VOICE_OUTSIDE_FRAME},
};

static int check_voices(void) {
  int bad = 0;
  for (usize i = 0; i < sizeof voice_cases / sizeof *voice_cases; i++) {
    const VoiceCase *v = &voice_cases[i];
    usize n = strlen(v->src);
    WokArena *a = wok_arena_new(0);
    WokDiagSink *d = wok_diag_new(a, "<case>", v->src, n);
    WokNode *file = wok_parse_source(v->src, n, a, d);
    if (wok_diag_count(d) == 0) wok_resolve(file, v->src, a, d);
    if (wok_diag_count(d) != 1 ||
        strcmp(wok_diag_code_text(wok_diag_at(d, 0)->code), "E-VARSCOPE") !=
            0 ||
        strstr(wok_diag_at(d, 0)->msg, v->phrase) == nullptr) {
      fprintf(stderr, "  FAIL voice `%s`: expected 1 E-VARSCOPE saying "
              "\"%s\"\n", v->what, v->phrase);
      wok_diag_render(d, stderr);
      bad++;
    }
    wok_arena_free(a);
  }
  return bad;
}

static int check_cases(void) {
  int bad = 0;
  for (usize i = 0; i < sizeof cases / sizeof *cases; i++) {
    usize n = strlen(cases[i].src);
    WokArena *a = wok_arena_new(0);
    WokDiagSink *d = wok_diag_new(a, "<case>", cases[i].src, n);
    WokNode *file = wok_parse_source(cases[i].src, n, a, d);
    if (wok_diag_count(d) == 0) wok_resolve(file, cases[i].src, a, d);
    usize got = wok_diag_count(d);
    if (!cases[i].want && got != 0) {
      fprintf(stderr, "  FAIL case %zu: expected silence, got %zu\n", i, got);
      wok_diag_render(d, stderr);
      bad++;
    } else if (cases[i].want) {
      if (got != 1) {
        fprintf(stderr, "  FAIL case %zu: expected 1 %s, got %zu\n", i,
                cases[i].want, got);
        wok_diag_render(d, stderr);
        bad++;
      } else if (strcmp(wok_diag_code_text(wok_diag_at(d, 0)->code),
                        cases[i].want) != 0) {
        fprintf(stderr, "  FAIL case %zu: expected %s, got %s\n", i,
                cases[i].want, wok_diag_code_text(wok_diag_at(d, 0)->code));
        bad++;
      }
    }
    wok_arena_free(a);
  }
  return bad;
}

int main(void) {
  int bad = 0, seen = 0;
  bool accepts = false, rejects = true;
  bad += wok_test_walk("../../test/redesign/accept", resolve_one,
                       &accepts, &seen);
  bad += wok_test_walk("../../test/redesign/reject", resolve_one,
                       &rejects, &seen);
  bad += wok_test_walk("testdata/tour", resolve_one, &accepts, &seen);
  // fill/ too: this suite is the ONLY resolver gate that runs under plain
  // `make test` (test_fill parses and prints, it never resolves), so a fill
  // fixture that trips a stage-4 check must fail here, not only in the
  // heavyweight sanitize loop.
  bad += wok_test_walk("testdata/fill", resolve_one, &accepts, &seen);
  bad += check_cases();
  bad += check_two_fault_cases();
  bad += check_capacity();
  bad += check_voices();
  if (seen < 47) {
    fprintf(stderr, "resolve: only %d corpus files seen\n", seen);
    bad++;
  }
  if (bad) {
    fprintf(stderr, "resolve: %d failure(s)\n", bad);
    return 1;
  }
  printf("resolve: %d corpus files, %zu cases\n", seen,
         sizeof cases / sizeof *cases);
  return 0;
}
