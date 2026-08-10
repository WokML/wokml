// wok_print -- THE CANONICAL PRINTER. One program, one text.
//
// This is what makes the package a FORMATTER and a LINTER rather than a
// parser with a debug dump. `wok_sexpr` writes the TREE; this writes the
// PROGRAM, and it writes exactly one text for each tree.
//
// THE CONTRACT
//
//   Dump(Parse(Print(t)))       == Dump(t)          -- meaning preserved
//   Print(Parse(Print(t)))      == Print(t)         -- a fixed point
//   Parse(Print(t)) reports zero diagnostics, and its token stream satisfies
//   every wok_layout invariant.
//
// The first is the load-bearing one. Under an offside rule a line break in
// the wrong place is not a syntax error: it turns an expression into a block
// or ends one early, so the output still parses and only the tree shows the
// damage. Comparing text would pass while the program silently changed.
//
// The contract holds for trees a PARSE produced. It does not extend to every
// tree the schema can express -- a damaged node, a multi-item block inside
// brackets, a tree past the depth cap -- and wok_print_unprintable_count()
// below is how a caller asks whether it met one.
//
// THE CANONICAL DECISIONS
//
//   1. Two spaces per indentation level. Never tabs.
//   2. A block is ALWAYS the indented form, one item per line -- never the
//      inline single-item spelling. The inline form is a second spelling of
//      one tree, and this design refuses two spellings of one thing (D20).
//      The single exception is forced by the language: inside brackets
//      layout is suspended (rule L2), so no indented block EXISTS there.
//   3. LINE FILLING at 80 columns, at the two break points an offside rule
//      leaves legal: immediately before a CONTINUATION LEAD, and anywhere
//      inside a bracket group. Per group: measure the flat width, emit flat
//      if it fits, otherwise break at EVERY opportunity in that group.
//      All-or-nothing per group; nested groups decide independently.
//      Application juxtaposition owns no separator and so cannot be broken:
//      a long application stays long, and says so on stderr.
//   4. Exactly one blank line between top-level declarations, none at the
//      start, exactly one newline at end of file. Inside a block the only
//      blank line written is an author's PARAGRAPH BREAK, capped at one and
//      never before a block's first item (wok_trivia's rule 4).
//   5. Parentheses and backticks are RE-DERIVED, never stored. Parens appear
//      only where the tree would otherwise re-parse differently; an
//      alphabetic operator can only have been written `` `add` `` and a
//      symbolic one only bare, so the spelling decides.
//   6. Within a handler-clause block or a case-alternative block, the `->`
//      of every arrow-headed item lines up on the widest head in that block.
//      A `var` clause is headed by `=`, not `->`, so it takes no padding. If
//      the widest head exceeds WOK_PRINT_ALIGN_MAX columns the whole block
//      falls back to a single space, so one long pattern cannot push a block
//      off the screen.
//
// COMMENTS come back through wok_trivia, which attaches them to the tree as
// side data the dump and the hash cannot see. The printer writes them where
// wok_trivia put them; where each one goes is that file's decision, not this
// one's.

#pragma once

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <stdio.h>

#include "wok_arena.h"
#include "wok_ast.h"

// Real C call-stack depth is bounded by this in both directions; past it the
// printer reports and emits a marker that will, correctly, fail to re-parse.
#define WOK_PRINT_MAX_DEPTH 256

// The alignment guard of decision 6, in columns.
#define WOK_PRINT_ALIGN_MAX 32

// Decision 3's width. NOT CONFIGURABLE, on purpose: a formatter that defines
// a standard has one width for the same reason it has one indent. A --width
// flag turns "this file is canonical" into "canonical under whose settings?".
#define WOK_PRINT_WIDTH 80

// Deepest block nesting the safety check tracks. Blocks are bounded by the
// layout filter's own depth cap, so this cannot be exceeded by a parsed tree.
#define WOK_PRINT_BLOCK_MAX 64

// `src` is the buffer every NAME/TEXT span in the tree points into -- the
// same contract as wok_sexpr_dump.
void wok_print(const WokNode *file, const char *src, FILE *out);

// The same text, into an arena-allocated NUL-terminated string.
char *wok_print_string(const WokNode *file, const char *src, WokArena *arena);

// The same, naming the file that overflow reports point at. A null `path`
// reports as `<input>`.
char *wok_print_string_named(const WokNode *file, const char *src,
                             WokArena *arena, const char *path);

// THE SAFETY PROPERTY, counted. A fill break that landed on a line which does
// not begin with a continuation lead, or which is not strictly deeper than
// its enclosing block, would silently change the tree rather than the text.
// Both halves are checked on the bytes actually written, on every emit, in
// every build; each violation is reported to stderr and counted here. A
// caller that is about to WRITE the text must refuse when this is non-zero.
//
// A process-wide latch rather than a return value: it must be checkable after
// a call that has no other reason to report anything, and the tool is
// one-shot and single-threaded.
unsigned wok_print_fault_count(void);

// The over-width lines the last emit REPORTED. A line can exceed the width
// only by holding an unbreakable run -- a long application, literal or name,
// or a comment, which a formatter may move but not rewrite -- and every one
// of them says so on stderr, so a long line reads as a stated limitation
// rather than as a filler that gave up silently.
unsigned wok_print_overflow_count(void);

// A node with NO canonical form: a damaged declaration or expression, a tree
// past the depth cap, or a corrupted one -- a multi-item block where layout is
// suspended, an out-of-range transfer mode or row kind. The text written in its
// place is the raw source or a marker, and is expected NOT to re-parse.
//
// This is the third of the three, and the reason it exists: the other two say
// the printer did something questionable to a tree it could write. This says
// the tree could not be written at all, which is the answer a caller about to
// SAVE a file actually needs, and it used to be available only as prose on
// stderr.
unsigned wok_print_unprintable_count(void);

void wok_print_reports_reset(void);

