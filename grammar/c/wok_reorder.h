// wok_reorder -- the precedence-resolution pass. See
// docs/superpowers/specs/2026-08-07-sexp-reorder-pass.md for the contract:
// this is a transliteration of Wok.Reordering's reorderChain / findLoosest /
// combineInfix (src/Wok/Reordering.hs), kept in lockstep by construction so a
// differential test can compare its output tree against Haskell's.
//
// Run ONLY after a clean parse and a clean wok_resolve_fix: a chain that
// already faulted stage 4 (a bad handler, a `:=` outside its frame) has
// nothing more useful to say about its own fixity, and the fixity TABLE
// resolve builds is this pass's only input.

#pragma once

#include "wok_arena.h"
#include "wok_ast.h"
#include "wok_diag.h"
#include "wok_resolve.h"

// Reassociates every E_Chain reachable from `file` into precedence-nested
// chains of exactly one H_ChainOp each, against `fix` (as built by
// wok_resolve_fix on the SAME file). The walk is bottom-up and generic: it
// visits every NODE/OPT/SEQ child of every node, so a chain under a lambda, a
// case arm, a where-clause or a list literal is reached the same way a
// top-level equation's body is.
//
// A subtree with no E_Chain in it is returned UNCHANGED (same pointer) --
// nodes are immutable, so this pass never mutates `file`, only builds new
// ancestors along the path to whatever it did change. Diagnostics go to `d`,
// same code (E-FIXITY) and quoting convention as wok_resolve's check_chain;
// on any diagnostic the returned tree is unfit to dump -- check
// wok_diag_count(d) before using it, the same way a caller already must
// after wok_parse.
const WokNode *wok_reorder(const WokNode *file, const char *src, WokArena *,
                           WokDiagSink *, const WokFixTable *fix);
