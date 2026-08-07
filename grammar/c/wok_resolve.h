// wok_resolve -- stage 4. The checks that need the DECLARATIONS and nothing
// more: no types, no inference, no fixity.
//
// spec-min section 4 splits its checks by what each one needs to see. The
// parser owns the ones decidable from the grammar alone. This owns the ones
// decidable once the effect declarations of the file are in hand -- op
// arities, and which ops an effect has at all. Everything past that (E-COVER
// needs the argument type's constructor set; E-ABORT, E-SHADOW, E-AFFINE and
// E-ESCAPE need the analyses) belongs downstream and is not attempted here.
//
// Run it ONLY over a clean parse. A damaged tree has holes where the names
// and patterns should be, so every count it reports is a count the author
// never wrote -- and the parse fault already said the true thing.

#pragma once

#include "wok_arena.h"
#include "wok_ast.h"
#include "wok_diag.h"

// Reports into the sink; adds nothing to the tree. `src` is the buffer every
// NAME span in the tree points into -- the same contract as wok_sexpr_dump.
void wok_resolve(const WokNode *file, const char *src, WokArena *,
                 WokDiagSink *);

// A read-only view of the fixity table wok_resolve builds: the partial order
// (a Warshall-closed bitset) plus each operator's own declared associativity.
// The reorder pass (wok_reorder.c) takes this as an EXPLICIT PARAMETER rather
// than reaching into resolve's own state, so a later loader-merged table
// (many files' fixities overlaid) drops in without the pass changing shape --
// see docs/superpowers/specs/2026-08-07-sexp-reorder-pass.md, the F5 note.
// Everything an instance points at is arena-owned; the handle does not
// outlive the arena wok_resolve_fix was given.
typedef struct {
  WokSpan name;
  u64 assoc;     // WOK_ASSOC_LEFT / WOK_ASSOC_RIGHT
  u32 decl_off;  // the WINNING `fixity` declaration's name offset, or
                 // UINT32_MAX for a name known only as someone else's
                 // neighbour -- it never declared an order of its own.
} WokFixOp;

typedef struct {
  const WokFixOp *ops;
  u32 n;
  const u64 *edge;  // n rows of `words` u64s; bit (i,j) = op i binds
                    // tighter than op j, closed (Warshall)
  u32 words;
} WokFixTable;

// The same checks as wok_resolve, and additionally hands the fixity table it
// built back through `out_fix` (may be nullptr, for callers with no use for
// it) -- the table is a byproduct resolve already computes, not extra work
// for the caller that needs it.
void wok_resolve_fix(const WokNode *file, const char *src, WokArena *,
                     WokDiagSink *, WokFixTable *out_fix);

// The D27 write-fault VOICES, as the one phrase that names each diagnosis.
// Shared with the tests that pin WHICH voice a case selects: E-VARSCOPE is
// one code with several differently-worded raise sites, so without these the
// tests would have to freeze whole sentences into accidental API. Rewording
// a message is free as long as its phrase moves with it.
#define WOK_VOICE_INIT_WRITE "cannot be written from a `var` initialiser"
#define WOK_VOICE_OUTSIDE_FRAME \
  "belongs to a handler frame this write is outside"
