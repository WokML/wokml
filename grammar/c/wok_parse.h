// wok_parse -- stage 3. Recursive descent, one function per production.
//
// It enforces only what is a matter of FORM. Everything that needs a TABLE --
// op arities, coverage, escape (E-COVER, E-ESCAPE ...) -- is a later pass's
// job, and the AST is shaped to make those passes easy: row entries record
// slot / role / row-variable, a control clause keeps its continuation
// separate, and the statement and inline forms of handle/let/use are distinct
// nodes.
//
// Three rules of form ARE enforced here, because they are grammar facts:
//   - a `handle` STATEMENT must write its label (P1/D13; the delimited
//     inline form may elide it);
//   - a control clause binds exactly one bare lowercase name after its comma
//     (C8/D14; a pattern there is unwritable, and E-ARITY says so);
//   - `once` at clause-head position is the v1 spelling and gets the
//     migration diagnostic (D25). That is the ONLY position where the word
//     means anything; everywhere else it is an ordinary name.

#pragma once

#include <stdbool.h>
#include <stddef.h>

#include "wok_base.h"

#include "wok_arena.h"
#include "wok_ast.h"
#include "wok_diag.h"
#include "wok_token.h"

// Guards against a deeply nested `((((((...` exhausting the C stack, which is
// the second classic parser CVE after literal overflow.
#define WOK_PARSE_MAX_DEPTH 200

// Parses a stream that has already been through wok_layout. Always returns a
// W_File node; a partial tree is returned for inspection, but a non-zero
// diagnostic count means DO NOT trust it.
WokNode *wok_parse(WokTokens tokens, const char *src, WokArena *,
                   WokDiagSink *);

// scan -> layout -> parse, the whole front end.
WokNode *wok_parse_source(const char *src, usize src_len, WokArena *,
                          WokDiagSink *);

