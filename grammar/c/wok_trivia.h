// wok_trivia -- comments, attached to the tree so the formatter can put them
// back (design section 5).
//
// The scanner already collects comments into a side list. This pass decides
// which ITEM each one belongs to: declaration, statement, handler clause,
// case alternative -- the same granularity error recovery resynchronises to,
// which is not a coincidence, it is the unit a reader thinks in.
//
// COMMENTS ARE NOT PART OF A PROGRAM'S IDENTITY. Two files differing only in
// their comments are the same program, so a comment is never a slot, never in
// the dump, and never in the hash the safety interlock compares. Putting one
// there would make the interlock assert something false. Preservation is its
// own property instead:
//
//   comments(Format(t)) == comments(t)     -- same texts, same order
//
// The storage costs nothing: WokNode already had four bytes of padding
// between `nslots` and its 8-byte-aligned slot array, and that is exactly a
// uint32 index into the side table below. A tree with no comments is byte for
// byte the tree that existed before this file.

#pragma once

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <stddef.h>
#include <stdint.h>

#include "wok_arena.h"
#include "wok_ast.h"
#include "wok_token.h"

// `lead_*` and `trail_*` are ranges into WokTrivia::comment. `blank_before` is
// the author's paragraph break, capped at one: everything above one blank line
// collapses, and the comment block counts as part of the item, so a blank line
// ABOVE a leading comment is what is recorded.
typedef struct {
  u32 lead_first, lead_n;
  u32 trail_first, trail_n;
  u8 blank_before;
} WokTriviaEntry;

typedef struct {
  WokTriviaEntry *entry;  // entry[0] is a reserved empty sentinel, so a
                          // node's `trivia == 0` can mean "none"
  u32 nentries;
  WokComment *comment;
  u32 ncomments;
} WokTrivia;

// Attaches `comments` to `file` and returns the table its `trivia` indices
// index into. The table is also BOUND to `file`, so wok_print can find it
// from the tree alone; see wok_trivia_of.
const WokTrivia *wok_trivia_attach(WokNode *file, const char *src,
                                   usize src_len, const WokComment *comments,
                                   usize ncomments, WokArena *arena);

// The table bound to `file`, or nullptr for a tree that never went through
// wok_trivia_attach. A tree parsed with wok_parse (no scan result, so no
// comments) answers nullptr and prints exactly as it did before.
const WokTrivia *wok_trivia_of(const WokNode *file);

// True when a node's TRAILING range holds the comments that close a block it
// owns (rule 3) rather than a comment written after the item itself. The two
// can never both apply to one node, and a printer that wrote the range in
// both places would emit every such comment twice.
bool wok_trivia_trail_closes_block(const WokNode *);

// The entry for one node, or nullptr when it carries no trivia.
static inline const WokTriviaEntry *wok_trivia_lookup(const WokTrivia *t,
                                                      const WokNode *n) {
  if (t == nullptr || n->trivia == 0 || n->trivia >= t->nentries)
    return nullptr;
  return &t->entry[n->trivia];
}

