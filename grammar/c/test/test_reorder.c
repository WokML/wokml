// Unit tests for wok_reorder -- the fixity-reassociation pass. Where
// test_resolve.c pins stage 4 (the checks decidable from declarations
// alone), this pins the pass that runs AFTER a clean stage 4: parse ->
// wok_resolve_fix -> wok_reorder, the exact sequence cmd/wokparse.c drives
// for `-sexp -reorder`. Nothing here reads the differential harness (that
// is test/Spec.hs, Haskell-side, env-gated); this file's job is to make the
// C harness self-sufficient about the pass's own contract, stated in
// wok_reorder.h:
//
//   - a resolved chain is nested E_Chain nodes with exactly one H_ChainOp
//     each (the singleton-ops invariant);
//   - the walk is bottom-up and generic, over every NODE/OPT/SEQ child,
//     regardless of what family demands one;
//   - a subtree with no E_Chain in it comes back as the SAME pointer --
//     copy-on-write, not a fresh tree every time;
//   - a diagnostic means the tree is unfit to dump, but the tree itself is
//     still returned (unchanged, per the point above).
//
// Every case builds its source inline and runs it through the real pipeline
// -- no fixtures, no golden files -- so a shape assertion here is checked
// against the actual tree the pass built, not a hand-drawn picture of it.

#include <stdio.h>
#include <string.h>

#include "../wok_arena.h"
#include "../wok_ast.h"
#include "../wok_diag.h"
#include "../wok_parse.h"
#include "../wok_reorder.h"
#include "../wok_resolve.h"

// ---------------------------------------------------------------- plumbing

// Runs the real pipeline over one inline source string. `parsed` is the tree
// BEFORE reorder ever touches it (kept so a test can tell a rebuilt node
// from an untouched one by pointer, and can read a chain's ORIGINAL flat ops
// count where that matters); `result` is wok_reorder's return value, which
// is `parsed` itself whenever parsing or resolve already faulted -- the
// pass never runs over a tree stage 4 has not cleared.
typedef struct {
  WokArena *a;
  WokDiagSink *d;
  const char *src;
  const WokNode *parsed;
  const WokNode *result;
} Run;

static Run run_reorder(const char *src) {
  usize n = strlen(src);
  WokArena *a = wok_arena_new(0);
  WokDiagSink *d = wok_diag_new(a, "<case>", src, n);
  WokNode *file = wok_parse_source(src, n, a, d);
  Run r = {.a = a, .d = d, .src = src, .parsed = file, .result = file};
  if (wok_diag_count(d) != 0) return r;
  WokFixTable fix = {0};
  wok_resolve_fix(file, src, a, d, &fix);
  if (wok_diag_count(d) != 0) return r;
  r.result = wok_reorder(file, src, a, d, &fix);
  return r;
}

static void run_free(Run *r) { wok_arena_free(r->a); }

static bool span_is(const char *src, WokSpan sp, const char *text) {
  usize len = strlen(text);
  return sp.len == len && memcmp(src + sp.off, text, len) == 0;
}

// The equation body named `name` -- works on either the pre- or
// post-reorder tree, since reorder never changes a decl's shape, only what
// hangs under it.
static const WokNode *eq_body(const WokNode *file, const char *src,
                              const char *name) {
  WokSeq decls = W_File_decls(file);
  for (u32 i = 0; i < decls.n; i++) {
    const WokNode *decl = decls.items[i];
    if (decl->tag != D_Equation) continue;
    const WokNode *lhs = D_Equation_lhs(decl);
    if (lhs->tag == L_Prefix && span_is(src, L_Prefix_name(lhs), name))
      return D_Equation_body(decl);
  }
  return nullptr;
}

// `n` must be a chain with exactly one op (the invariant every RESOLVED
// chain in the output holds). Returns the singleton H_ChainOp, or nullptr
// with *bad incremented -- callers read its op/backtick/rhs, and the
// chain's own head, from there.
static const WokNode *chain1(const WokNode *n, const char *what, int *bad) {
  if (!n || n->tag != E_Chain) {
    (*bad)++;
    fprintf(stderr, "  FAIL %s: expected E_Chain, got tag %d\n", what,
            n ? n->tag : -1);
    return nullptr;
  }
  WokSeq ops = E_Chain_ops(n);
  if (ops.n != 1) {
    (*bad)++;
    fprintf(stderr, "  FAIL %s: singleton-ops invariant broken, %u ops\n",
            what, ops.n);
    return nullptr;
  }
  return ops.items[0];
}

static void expect_op(const WokNode *op, const char *src, const char *what,
                      const char *name, bool backtick, int *bad) {
  if (!op) return;
  WokSpan sp = H_ChainOp_op(op);
  bool bt = H_ChainOp_backtick(op);
  if (!span_is(src, sp, name) || bt != backtick) {
    (*bad)++;
    fprintf(stderr,
            "  FAIL %s: expected op `%s` backtick=%d, got `%.*s` "
            "backtick=%d\n",
            what, name, backtick, (int)sp.len, src + sp.off, bt);
  }
}

static int check_int(const WokNode *n, u64 want) {
  if (!n || n->tag != E_Int || E_Int_value(n) != want) {
    fprintf(stderr, "  FAIL: expected E_Int %llu, got %s\n",
            (unsigned long long)want,
            n && n->tag == E_Int ? "a different value" : "a non-E_Int node");
    return 1;
  }
  return 0;
}

static int check_var(const WokNode *n, const char *src, const char *name) {
  if (!n || n->tag != E_Var || !span_is(src, E_Var_name(n), name)) {
    fprintf(stderr, "  FAIL: expected E_Var `%s`, got %s\n", name,
            n && n->tag == E_Var ? "a different name" : "a non-E_Var node");
    return 1;
  }
  return 0;
}

// combineInfix's synthesized span: leftmost operand start to rightmost
// operand end.
static int check_span_covers(const WokNode *chain, const WokNode *lhs,
                             const WokNode *rhs, const char *what) {
  if (chain->off != lhs->off ||
      chain->off + chain->len != rhs->off + rhs->len) {
    fprintf(stderr,
            "  FAIL %s: span [%u,%u) does not cover [%u,%u)\n", what,
            chain->off, chain->off + chain->len, lhs->off,
            rhs->off + rhs->len);
    return 1;
  }
  return 0;
}

// ---------------------------------------------------------------- 1 & 4: shape + spans

// The spec's shield example: `+` looser than both `*` and `/`, so the flat
// 4-op chain resolves into two nested one-op chains under a single top op --
// E_Chain(E_Chain(2,*,3), +, E_Chain(8,/,4)). The same walk pins the
// synthesized-span rule on both inner chains, since their leaves are exactly
// the E_Int pair each span must cover end to end.
static int check_shield_shape(void) {
  int bad = 0;
  const char *src =
      "fixity + left\n"
      "fixity * left tighter than +\n"
      "fixity / left tighter than +\n"
      "f = 2 * 3 + 8 / 4\n";
  Run r = run_reorder(src);
  if (wok_diag_count(r.d) != 0) {
    fprintf(stderr, "  FAIL shield shape: unexpected diagnostic(s)\n");
    wok_diag_render(r.d, stderr);
    bad++;
    run_free(&r);
    return bad;
  }

  const WokNode *body = eq_body(r.result, r.src, "f");
  const WokNode *top_op = chain1(body, "shield top", &bad);
  expect_op(top_op, r.src, "shield top", "+", false, &bad);

  const WokNode *mul_chain = body ? E_Chain_head(body) : nullptr;
  const WokNode *mul_op = chain1(mul_chain, "shield mul", &bad);
  expect_op(mul_op, r.src, "shield mul", "*", false, &bad);
  const WokNode *two = mul_chain ? E_Chain_head(mul_chain) : nullptr;
  const WokNode *three = mul_op ? H_ChainOp_rhs(mul_op) : nullptr;
  bad += check_int(two, 2);
  bad += check_int(three, 3);

  const WokNode *div_chain = top_op ? H_ChainOp_rhs(top_op) : nullptr;
  const WokNode *div_op = chain1(div_chain, "shield div", &bad);
  expect_op(div_op, r.src, "shield div", "/", false, &bad);
  const WokNode *eight = div_chain ? E_Chain_head(div_chain) : nullptr;
  const WokNode *four = div_op ? H_ChainOp_rhs(div_op) : nullptr;
  bad += check_int(eight, 8);
  bad += check_int(four, 4);

  if (mul_chain && two && three)
    bad += check_span_covers(mul_chain, two, three, "shield mul-chain span");
  if (div_chain && eight && four)
    bad += check_span_covers(div_chain, eight, four, "shield div-chain span");
  if (body && mul_chain && div_chain)
    bad += check_span_covers(body, mul_chain, div_chain, "shield top-chain span");

  run_free(&r);
  return bad;
}

// -------------------------------------------------------------- 2: associativity ties

// Equal precedence (same operator, no cross-operator equivalence classes)
// resolves by ASSOCIATIVITY, mirroring findLoosest's Equal arm: left-assoc
// takes the rightmost occurrence as the split point, so the top op is the
// LAST `-` and its head is the nested `a - b`; right-assoc takes the
// leftmost, so the top op is the FIRST `^` and its rhs is the nested `b ^ c`.
static int check_assoc_ties(void) {
  int bad = 0;

  {
    const char *src = "fixity - left\nf = a - b - c\n";
    Run r = run_reorder(src);
    if (wok_diag_count(r.d) != 0) {
      fprintf(stderr, "  FAIL left-assoc tie: unexpected diagnostic(s)\n");
      wok_diag_render(r.d, stderr);
      bad++;
    } else {
      const WokNode *body = eq_body(r.result, r.src, "f");
      const WokNode *top_op = chain1(body, "left-tie top", &bad);
      expect_op(top_op, r.src, "left-tie top", "-", false, &bad);
      const WokNode *inner = body ? E_Chain_head(body) : nullptr;
      const WokNode *inner_op = chain1(inner, "left-tie inner", &bad);
      expect_op(inner_op, r.src, "left-tie inner", "-", false, &bad);
      if (inner) bad += check_var(E_Chain_head(inner), r.src, "a");
      if (inner_op) bad += check_var(H_ChainOp_rhs(inner_op), r.src, "b");
      if (top_op) bad += check_var(H_ChainOp_rhs(top_op), r.src, "c");
    }
    run_free(&r);
  }

  {
    const char *src = "fixity ^ right\nf = a ^ b ^ c\n";
    Run r = run_reorder(src);
    if (wok_diag_count(r.d) != 0) {
      fprintf(stderr, "  FAIL right-assoc tie: unexpected diagnostic(s)\n");
      wok_diag_render(r.d, stderr);
      bad++;
    } else {
      const WokNode *body = eq_body(r.result, r.src, "f");
      const WokNode *top_op = chain1(body, "right-tie top", &bad);
      expect_op(top_op, r.src, "right-tie top", "^", false, &bad);
      if (body) bad += check_var(E_Chain_head(body), r.src, "a");
      const WokNode *inner = top_op ? H_ChainOp_rhs(top_op) : nullptr;
      const WokNode *inner_op = chain1(inner, "right-tie inner", &bad);
      expect_op(inner_op, r.src, "right-tie inner", "^", false, &bad);
      if (inner) bad += check_var(E_Chain_head(inner), r.src, "b");
      if (inner_op) bad += check_var(H_ChainOp_rhs(inner_op), r.src, "c");
    }
    run_free(&r);
  }

  return bad;
}

// -------------------------------------------------------------- 3: copy-on-write

// The header's contract: "unchanged subtrees are returned as the SAME
// pointer." Two shapes pin it: a two-decl file where only one decl holds a
// chain (the untouched decl's pointer survives; the touched one does not),
// and a chain-free file (the whole root survives).
static int check_cow_sharing(void) {
  int bad = 0;

  {
    const char *src = "noop = 42\nfixity + left\nf = 1 + 2\n";
    Run r = run_reorder(src);
    if (wok_diag_count(r.d) != 0) {
      fprintf(stderr, "  FAIL cow sharing: unexpected diagnostic(s)\n");
      wok_diag_render(r.d, stderr);
      bad++;
    } else {
      WokSeq before = W_File_decls(r.parsed);
      WokSeq after = W_File_decls(r.result);
      if (before.n != 3 || after.n != 3) {
        fprintf(stderr,
                "  FAIL cow sharing: expected 3 decls before/after, got "
                "%u/%u\n",
                before.n, after.n);
        bad++;
      } else {
        // decls[0] is `noop`, which holds no chain: untouched, same pointer.
        if (before.items[0] != after.items[0]) {
          fprintf(stderr,
                  "  FAIL cow sharing: untouched decl `noop` was rebuilt\n");
          bad++;
        }
        // decls[2] is `f`, which holds the chain: touched, fresh pointer.
        if (before.items[2] == after.items[2]) {
          fprintf(stderr,
                  "  FAIL cow sharing: touched decl `f` kept its old "
                  "pointer\n");
          bad++;
        }
      }
    }
    run_free(&r);
  }

  {
    const char *src = "fixity + left\nf = 1\ng = 2\n";
    Run r = run_reorder(src);
    if (wok_diag_count(r.d) != 0) {
      fprintf(stderr, "  FAIL no-chain identity: unexpected diagnostic(s)\n");
      wok_diag_render(r.d, stderr);
      bad++;
    } else if (r.result != r.parsed) {
      fprintf(stderr,
              "  FAIL no-chain identity: root pointer changed although the "
              "file has no chain\n");
      bad++;
    }
    run_free(&r);
  }

  return bad;
}

// -------------------------------------------------------------- 5(d): backtick

// Backtick is a SURFACE fact carried on H_ChainOp, not part of the
// operator's table identity (wok_reorder.c's file header: `div` here is the
// same table entry a bare `div` chain would look up). The rebuilt op must
// still carry the flag forward.
static int check_backtick(void) {
  int bad = 0;
  const char *src =
      "fixity + left\n"
      "fixity div left tighter than +\n"
      "f = a + b `div` c\n";
  Run r = run_reorder(src);
  if (wok_diag_count(r.d) != 0) {
    fprintf(stderr, "  FAIL backtick: unexpected diagnostic(s)\n");
    wok_diag_render(r.d, stderr);
    bad++;
    run_free(&r);
    return bad;
  }
  const WokNode *body = eq_body(r.result, r.src, "f");
  const WokNode *top_op = chain1(body, "backtick top", &bad);
  expect_op(top_op, r.src, "backtick top", "+", false, &bad);
  const WokNode *inner = top_op ? H_ChainOp_rhs(top_op) : nullptr;
  const WokNode *inner_op = chain1(inner, "backtick inner", &bad);
  expect_op(inner_op, r.src, "backtick inner", "div", /*backtick=*/true, &bad);
  run_free(&r);
  return bad;
}

// -------------------------------------------------------------- 5(a-c): diagnostics

static int check_diagnostics(void) {
  int bad = 0;

  // (a) An operator with NO table entry at all: one diagnostic, anchored at
  // the operator's own span (check mode SKIPS this silently; reorder mode
  // is strict). The tree comes back unrebuilt -- "unfit to dump", per
  // wok_reorder.h, not absent.
  {
    const char *src = "f = a # b\n";
    Run r = run_reorder(src);
    const WokNode *op = chain1(eq_body(r.parsed, r.src, "f"), "undeclared op",
                               &bad);
    if (wok_diag_count(r.d) != 1) {
      fprintf(stderr,
              "  FAIL undeclared operator: expected 1 diagnostic, got %zu\n",
              wok_diag_count(r.d));
      wok_diag_render(r.d, stderr);
      bad++;
    } else {
      const WokDiag *diag = wok_diag_at(r.d, 0);
      if (strcmp(wok_diag_code_text(diag->code), "E-FIXITY") != 0) {
        fprintf(stderr,
                "  FAIL undeclared operator: expected E-FIXITY, got %s\n",
                wok_diag_code_text(diag->code));
        bad++;
      }
      if (op) {
        WokSpan want = H_ChainOp_op(op);
        if (diag->off != want.off || diag->len != want.len) {
          fprintf(stderr,
                  "  FAIL undeclared operator: diagnostic span [%u,%u) != "
                  "operator span [%u,%u)\n",
                  diag->off, diag->off + diag->len, want.off,
                  want.off + want.len);
          bad++;
        }
      }
    }
    if (r.result != r.parsed) {
      fprintf(stderr,
              "  FAIL undeclared operator: tree was rebuilt despite the "
              "fault\n");
      bad++;
    }
    run_free(&r);
  }

  // (b) The whole-table scan, not a per-occurrence check: a placeholder
  // neighbour (named only as another operator's `tighter than`/`looser
  // than` target, with no `fixity` declaration of its own) faults the
  // module whether or not it is ever used in a chain -- even when the file
  // has no chain at all.
  {
    const char *src = "fixity + left tighter than *\ng = 1 + 2\n";
    Run r = run_reorder(src);
    if (wok_diag_count(r.d) != 1) {
      fprintf(stderr,
              "  FAIL neighbour-unused: expected 1 diagnostic, got %zu\n",
              wok_diag_count(r.d));
      wok_diag_render(r.d, stderr);
      bad++;
    }
    if (r.result != r.parsed) {
      fprintf(stderr,
              "  FAIL neighbour-unused: tree was rebuilt despite the "
              "fault\n");
      bad++;
    }
    run_free(&r);
  }
  {
    const char *src = "fixity + left tighter than *\nf = 0\n";
    Run r = run_reorder(src);
    if (wok_diag_count(r.d) != 1) {
      fprintf(stderr,
              "  FAIL neighbour-no-chain: expected 1 diagnostic, got %zu\n",
              wok_diag_count(r.d));
      wok_diag_render(r.d, stderr);
      bad++;
    }
    if (r.result != r.parsed) {
      fprintf(stderr,
              "  FAIL neighbour-no-chain: tree was rebuilt despite the "
              "fault\n");
      bad++;
    }
    run_free(&r);
  }

  // (c) TWO placeholders batch into TWO diagnostics -- the scan does not
  // stop at the first, mirroring Haskell's buildFixityTable collecting one
  // UnresolvedNeighbor per offending relation.
  {
    const char *src =
        "fixity + left tighter than *\n"
        "fixity - left tighter than /\n"
        "f = 0\n";
    Run r = run_reorder(src);
    if (wok_diag_count(r.d) != 2) {
      fprintf(stderr,
              "  FAIL two placeholders: expected 2 diagnostics, got %zu\n",
              wok_diag_count(r.d));
      wok_diag_render(r.d, stderr);
      bad++;
    } else {
      bool saw_star = false, saw_slash = false;
      for (usize i = 0; i < 2; i++) {
        const WokDiag *diag = wok_diag_at(r.d, i);
        if (strcmp(wok_diag_code_text(diag->code), "E-FIXITY") != 0) {
          fprintf(stderr,
                  "  FAIL two placeholders: diag %zu is %s, not E-FIXITY\n",
                  i, wok_diag_code_text(diag->code));
          bad++;
        }
        if (diag->len == 1 && src[diag->off] == '*') saw_star = true;
        if (diag->len == 1 && src[diag->off] == '/') saw_slash = true;
      }
      if (!saw_star || !saw_slash) {
        fprintf(stderr,
                "  FAIL two placeholders: expected one diagnostic naming "
                "`*` and one naming `/`, batched together\n");
        bad++;
      }
    }
    run_free(&r);
  }

  return bad;
}

// -------------------------------------------------------------- 6: nested reach

// Walks `f`'s body down to the chain buried inside a lambda inside a case
// alternative. Works on either the pre- or post-reorder tree: before
// reorder the chain is flat (2 ops), after it is nested (1 op) -- so a
// caller comparing the two proves the generic walk actually descended this
// far, rather than the top-level equation body being the only thing that
// ever gets visited.
static const WokNode *deep_chain(const WokNode *file, const char *src,
                                 int *bad) {
  const WokNode *body = eq_body(file, src, "f");
  if (!body || body->tag != E_Case) {
    (*bad)++;
    fprintf(stderr, "  FAIL nested reach: expected E_Case body, got tag %d\n",
            body ? body->tag : -1);
    return nullptr;
  }
  WokSeq alts = E_Case_alts(body);
  if (alts.n != 1) {
    (*bad)++;
    fprintf(stderr, "  FAIL nested reach: expected 1 case alt, got %u\n",
            alts.n);
    return nullptr;
  }
  const WokNode *alt_body = H_Alt_body(alts.items[0]);
  if (!alt_body || alt_body->tag != E_Lambda) {
    (*bad)++;
    fprintf(stderr,
            "  FAIL nested reach: expected E_Lambda alt body, got tag %d\n",
            alt_body ? alt_body->tag : -1);
    return nullptr;
  }
  const WokNode *lam_body = E_Lambda_body(alt_body);
  if (!lam_body || lam_body->tag != E_Chain) {
    (*bad)++;
    fprintf(stderr,
            "  FAIL nested reach: expected E_Chain lambda body, got tag "
            "%d\n",
            lam_body ? lam_body->tag : -1);
    return nullptr;
  }
  return lam_body;
}

static int check_nested_reach(void) {
  int bad = 0;
  const char *src =
      "fixity + left\n"
      "fixity * left tighter than +\n"
      "f = case 0 of\n"
      "  x -> \\y -> 1 + 2 * y\n";
  Run r = run_reorder(src);
  if (wok_diag_count(r.d) != 0) {
    fprintf(stderr, "  FAIL nested reach: unexpected diagnostic(s)\n");
    wok_diag_render(r.d, stderr);
    bad++;
    run_free(&r);
    return bad;
  }

  const WokNode *before = deep_chain(r.parsed, r.src, &bad);
  const WokNode *after = deep_chain(r.result, r.src, &bad);
  if (before && after) {
    WokSeq ops_before = E_Chain_ops(before);
    WokSeq ops_after = E_Chain_ops(after);
    if (ops_before.n != 2) {
      fprintf(stderr,
              "  FAIL nested reach: pre-reorder chain should be flat (2 "
              "ops), got %u\n",
              ops_before.n);
      bad++;
    }
    if (ops_after.n != 1) {
      fprintf(stderr,
              "  FAIL nested reach: post-reorder chain should be singleton "
              "(1 op), got %u\n",
              ops_after.n);
      bad++;
    }
    if (before == after) {
      fprintf(stderr, "  FAIL nested reach: chain node was not rebuilt\n");
      bad++;
    }
    const WokNode *top_op = chain1(after, "nested top", &bad);
    expect_op(top_op, r.src, "nested top", "+", false, &bad);
    const WokNode *inner = top_op ? H_ChainOp_rhs(top_op) : nullptr;
    const WokNode *inner_op = chain1(inner, "nested inner", &bad);
    expect_op(inner_op, r.src, "nested inner", "*", false, &bad);
  }
  run_free(&r);
  return bad;
}

// ---------------------------------------------------------------------- main

int main(void) {
  int bad = 0;
  bad += check_shield_shape();
  bad += check_assoc_ties();
  bad += check_cow_sharing();
  bad += check_backtick();
  bad += check_diagnostics();
  bad += check_nested_reach();
  if (bad) {
    fprintf(stderr, "reorder: %d failure(s)\n", bad);
    return 1;
  }
  printf("reorder: shape, ties, cow sharing, backtick, diagnostics, nested "
        "reach -- all clean\n");
  return 0;
}
