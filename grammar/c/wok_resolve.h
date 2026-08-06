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

// The D27 write-fault VOICES, as the one phrase that names each diagnosis.
// Shared with the tests that pin WHICH voice a case selects: E-VARSCOPE is
// one code with several differently-worded raise sites, so without these the
// tests would have to freeze whole sentences into accidental API. Rewording
// a message is free as long as its phrase moves with it.
#define WOK_VOICE_INIT_WRITE "cannot be written from a `var` initialiser"
#define WOK_VOICE_OUTSIDE_FRAME \
  "belongs to a handler frame this write is outside"
