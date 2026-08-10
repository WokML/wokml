// wok_sexpr -- a generic s-expression dump and reader for the wok AST.
//
// Both directions are one walk over wok_node_desc[]. There is NO per-tag
// code here: every node prints and parses purely from its WokFieldDesc
// list, which is why adding a node to wok_ast.h never touches this file.
//
// Format (see docs at the call site / design doc for the full grammar):
//   (TAG field1 field2 ...)   -- fields in declaration order, always nfields
//                                 of them, even for a nullary node: (T_Unit).
//   WFC_NODE  -> the child's s-expression (never absent; see below).
//   WFC_OPT   -> (none) or (some X).
//   WFC_SEQ   -> (seq X1 X2 ...), always tagged, (seq) when empty.
//   WFC_NAME/WFC_TEXT -> a quoted, escaped view of the source span.
//   WFC_INT   -> decimal.
//   WFC_FLAG  -> #t or #f.
// The dump carries no positions: two files differing only in layout dump
// identically, which is what makes the dump usable as a canonical identity
// for a program (e.g. for diffing two parses of reformatted source).
//
// A null WFC_NODE field is a contract violation (every NODE field is
// required), not a normal input shape. The dumper cannot repair it, so it
// reports the violation to stderr and writes the placeholder atom `(!null)`
// in its place rather than crashing; the resulting text is expected to be
// unparseable, exactly like the violation it is reporting.
//
// The reader is the dumper run backwards, and just as strict: an unknown
// head tag, a wrong field count, a field of the wrong shape, a child of the
// wrong FAMILY, or an unterminated list or string literal are all reported
// through the sink and fail the whole parse (nullptr). The family check is
// the one that needs saying, because a class check alone does not make it:
// it asks whether a child is PRESENT, never what the child is, so a type in
// an expression slot used to read back clean and print as a different
// program. wok_ast.h carries the family each field demands; this compares it
// against the family the child's tag belongs to. The two error nodes are
// wildcards -- the parser plants damage wherever a production gives up, so a
// damaged parse's dump must still read back. Recursion depth (which tracks real C call
// stack depth in both directions) is capped; exceeding it is reported
// rather than left to overflow the stack.
//
// The out_src mechanism: because a dump carries no positions, every node
// wok_sexpr_read builds gets off=0, len=0, and its NAME/TEXT spans cannot
// point back into `text` (the dump), since a decoded string is generally a
// different length than its escaped spelling. Instead the reader owns one
// arena-allocated, NUL-terminated byte buffer -- a string pool -- and as it
// decodes each NAME/TEXT literal it appends the decoded bytes to that pool
// and stores the span (offset, length) *into the pool* on the node. The
// whole pool is handed back through *out_src once the parse succeeds, so
// every span in the returned tree is valid against that one buffer, the
// same way every span in a freshly parsed source file is valid against that
// file's buffer.

#pragma once

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include <stdio.h>

#include "wok_arena.h"
#include "wok_ast.h"
#include "wok_diag.h"

// Dump. `src` is the source buffer the NAME/TEXT spans in `node` point into.
void wok_sexpr_dump(const WokNode *node, const char *src, FILE *out);

// Dump to an arena-allocated, NUL-terminated string (for tests and for
// round-tripping through wok_sexpr_read).
char *wok_sexpr_dump_string(const WokNode *node, const char *src,
                            WokArena *arena);

// Read. Parses `text[0..n)` -- one dumped node -- back into a tree in
// `arena`. Returns nullptr on error, after reporting at least one
// diagnostic to `diag`. On success, *out_src is set to the reader's decoded
// string pool (see above); every NAME/TEXT span in the returned tree indexes
// that buffer, not `text`. *out_src is left unset on failure.
WokNode *wok_sexpr_read(const char *text, usize n, WokArena *arena,
                        WokDiagSink *diag, const char **out_src);

