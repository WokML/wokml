// wok_token -- the token rosters and the scanner.
//
// The division of labour with the parser is deliberate: THE SCANNER RESOLVES
// EVERYTHING THAT DEPENDS ON THE SOURCE TEXT; the parser only ever looks at
// fields of a token. No production reads a token's bytes to make a decision --
// text is carried into the AST or quoted in a diagnostic, never compared.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "wok_arena.h"
#include "wok_base.h"
#include "wok_diag.h"

// ---------------------------------------------------------------- kinds
//
// One roster. Every table keyed by a kind carries a static_assert against
// WOK_KIND_COUNT, and no switch over a kind may carry a `default:` label --
// that is what turns a missing enumerator into -Werror=switch.

#define WOK_KINDS(X)                                                      \
  X(WT_EOF)                                                               \
  /* layout tokens: produced by stage 2, never by the scanner */          \
  X(WT_NEWLINE) X(WT_INDENT) X(WT_DEDENT)                                 \
  /* open lexical classes */                                              \
  X(WT_VARID) X(WT_CONID) X(WT_VARSYM) X(WT_KEYWORD)                      \
  X(WT_INT) X(WT_STRING) X(WT_CHAR)                                       \
  /* brackets */                                                          \
  X(WT_LPAREN) X(WT_RPAREN) X(WT_LBRACKET) X(WT_RBRACKET)                 \
  X(WT_LBRACE) X(WT_RBRACE)                                               \
  /* fixed punctuation */                                                 \
  X(WT_COMMA) X(WT_DOT) X(WT_DOTDOT) X(WT_BACKTICK)                       \
  X(WT_UNDERSCORE) X(WT_LAMBDA)                                           \
  /* reserved operator runs, carved out of WT_VARSYM by table lookup */   \
  X(WT_ARROW) X(WT_FATARROW) X(WT_EQUALS) X(WT_COLON)                     \
  X(WT_COLONCOLON) X(WT_ASSIGN) X(WT_BAR)                                 \
  /* v2 has no statement separator; scanned only to diagnose it (D22) */  \
  X(WT_SEMI)                                                              \
  X(WT_BAD)

typedef enum wok_kind : unsigned char {
#define WOK_X(name) name,
  WOK_KINDS(WOK_X)
#undef WOK_X
      WOK_KIND_COUNT
} WokKind;

static_assert(WOK_KIND_COUNT <= 255, "kind must fit in one byte");

WOK_READONLY const char *wok_kind_name(WokKind);

// ---------------------------------------------------------------- words
//
// The interned identity of a NAMED SPELLING. Three registers stay apart
// without a second roster because each records the kind it is emitted as:
//
//   WT_KEYWORD -- reserved; never a variable.
//   WT_VARID   -- CONTEXTUAL; an ordinary identifier that carries its tag, so
//                 the one production that wants it matches an integer and
//                 every other production sees a plain name. `own`/`lend`/
//                 `copy` must be contextual: spec.md section 2 writes
//                 `Bytes.copy` itself.
//   WT_VARSYM  -- a user operator that one production happens to name; `+`
//                 stays freely redefinable.
//
// Matching a word is an integer compare, and `wok_word_is(t, WW_HANLDE)`
// fails to COMPILE where a string comparison would compile, run, and simply
// never be true.

#define WOK_WORDS(X)                                                      \
  /* --- ML skeleton: the ordinary word on familiar ground (D10) --- */   \
  X(WW_MODULE, "module", WT_KEYWORD)                                      \
  X(WW_IMPORT, "import", WT_KEYWORD)                                      \
  X(WW_AS, "as", WT_KEYWORD)                                              \
  X(WW_TYPE, "type", WT_KEYWORD)                                          \
  X(WW_ALIAS, "alias", WT_KEYWORD)                                        \
  X(WW_CLASS, "class", WT_KEYWORD)                                        \
  X(WW_INSTANCE, "instance", WT_KEYWORD)                                  \
  X(WW_LET, "let", WT_KEYWORD)                                            \
  X(WW_IN, "in", WT_KEYWORD)                                              \
  X(WW_CASE, "case", WT_KEYWORD)                                          \
  X(WW_OF, "of", WT_KEYWORD)                                              \
  X(WW_IF, "if", WT_KEYWORD)                                              \
  X(WW_THEN, "then", WT_KEYWORD)                                          \
  X(WW_ELSE, "else", WT_KEYWORD)                                          \
  X(WW_WHERE, "where", WT_KEYWORD)                                        \
  /* --- law words: the keyword states the promise (D10) --- */           \
  X(WW_EFFECT, "effect", WT_KEYWORD)                                      \
  X(WW_HANDLER, "handler", WT_KEYWORD)                                    \
  X(WW_HANDLE, "handle", WT_KEYWORD)                                      \
  X(WW_USE, "use", WT_KEYWORD)                                            \
  X(WW_ABORT, "abort", WT_KEYWORD)                                        \
  X(WW_RETURN, "return", WT_KEYWORD)                                      \
  X(WW_VAR, "var", WT_KEYWORD)                                            \
  X(WW_WITH, "with", WT_KEYWORD)                                          \
  X(WW_FOREIGN, "foreign", WT_KEYWORD)                                    \
  X(WW_EXTERN, "extern", WT_KEYWORD)                                      \
  X(WW_FIXITY, "fixity", WT_KEYWORD)                                      \
  /* --- contextual: tagged, but still ordinary identifiers --- */        \
  /* `once` is CUT (D25): reserved at CLAUSE-HEAD position only, where */  \
  /* parse_clause reads the tag to emit the v1-migration diagnostic. */    \
  X(WW_ONCE, "once", WT_VARID)                                            \
  X(WW_OWN, "own", WT_VARID)                                              \
  X(WW_LEND, "lend", WT_VARID)                                            \
  X(WW_COPY, "copy", WT_VARID)                                            \
  /* the five words of a `fixity` line. Contextual for the same reason */ \
  /* `own` is: `left`, `right` and `than` are ordinary names anywhere */  \
  /* else, and reserving them would cost every program that has one. */   \
  X(WW_LEFT, "left", WT_VARID)                                            \
  X(WW_RIGHT, "right", WT_VARID)                                          \
  X(WW_TIGHTER, "tighter", WT_VARID)                                      \
  X(WW_LOOSER, "looser", WT_VARID)                                        \
  X(WW_THAN, "than", WT_VARID)                                            \
  X(WW_ROW, "row", WT_VARID)                                              \
  X(WW_EFF, "eff", WT_VARID)                                              \
  /* --- an operator run one production reads by name --- */              \
  X(WW_PLUS, "+", WT_VARSYM)

typedef enum wok_word : unsigned char {
  WW_NONE = 0,
#define WOK_X(name, text, kind) name,
  WOK_WORDS(WOK_X)
#undef WOK_X
      WOK_WORD_COUNT
} WokWord;

static_assert(WOK_WORD_COUNT <= 255, "word must fit in one byte");

WOK_READONLY const char *wok_word_text(WokWord);
WOK_READONLY WokKind wok_word_kind(WokWord);

// ---------------------------------------------------------------- token

enum {
  WOK_TF_FIRST_ON_LINE = 1u << 0,  // this token opens its physical line
  WOK_TF_HAS_ESCAPE = 1u << 1,     // literal text differs from source bytes
};

typedef struct {
  u32 off;  // byte offset into the source; text is never copied
  u32 len;
  u32 col;  // 1-based; tabs are rejected in indentation, so this is exact
  u8 kind;  // WokKind
  u8 word;  // WokWord, or WW_NONE
  u16 flags;
} WokToken;

static_assert(sizeof(WokToken) == 16, "token is the hot array; keep it 16 bytes");

typedef struct {
  WokToken *tok;
  usize n;  // always >= 1; the last token is WT_EOF and is never consumed past
} WokTokens;

// Comments are collected into a side list rather than discarded, so attaching
// them as trivia does not have to re-open the scanner. wok_trivia_attach
// consumes this list; the tokens themselves never mention a comment.
typedef struct {
  u32 off, len;
  bool block;  // {- -} rather than --
} WokComment;

typedef struct {
  WokTokens tokens;
  WokComment *comments;
  usize ncomments;
} WokScanResult;

WokScanResult wok_scan(const char *src, usize src_len, WokArena *,
                       WokDiagSink *);

// ------------------------------------------------- lexical classification

// Static inline, not out-of-line: these are asked once per token, and
// profiling showed the calls themselves on the clock (~5% of a parse).
WOK_PURE static inline bool wok_kind_is_open_bracket(WokKind k) {
  return k == WT_LPAREN || k == WT_LBRACKET || k == WT_LBRACE;
}
WOK_PURE static inline bool wok_kind_is_close_bracket(WokKind k) {
  return k == WT_RPAREN || k == WT_RBRACKET || k == WT_RBRACE;
}

// THE predicate stage 2 is built on: a token that can never BEGIN a block
// item, and therefore marks its line as a CONTINUATION of the previous one.
// It lives here, not in wok_layout.c, because it is a lexical fact -- the
// layout filter must not be able to name a keyword.
//
// Two things hold this down, and a third does not.
//
//   - -Wswitch. The switch below carries no `default:`, over the kinds OR the
//     words, so a token added to either roster does not COMPILE until someone
//     classifies it here. That is the load-bearing half, and it is the reason
//     no roster test is needed to say every token has an answer.
//   - test_fill pins the PRINTER's own copy of this question against this one
//     for every lead a fill break can produce, so the two cannot drift into a
//     second opinion about the lexis.
//
// What is NOT checked is that each answer is RIGHT -- that a token called a
// lead cannot in fact begin an item. A wrong answer there compiles, and under
// an offside rule it is silent: the line joins the previous one instead of
// starting an item, and only the tree shows it. Checking it needs the FIRST
// set of the grammar, and the only honest source for that is a generator that
// builds items rather than a second list typed out beside this one -- so if it
// is ever written, it belongs in test_generative, which already builds items
// across 80 of the schema's 82 tags.
WOK_READONLY static inline bool wok_token_is_continuation_lead(
    const WokToken *t) {
  switch ((WokKind)t->kind) {
    // Every operator lead. No prefix operator exists except `-`, and a line
    // beginning with `-` is subtraction continuing the previous line -- the
    // same call v2 already made when it decided `1-2` is subtraction.
    case WT_VARSYM:
    case WT_ARROW:
    case WT_FATARROW:
    case WT_EQUALS:
    case WT_COLON:
    case WT_COLONCOLON:
    case WT_ASSIGN:
    case WT_BAR:
    case WT_COMMA:
    case WT_DOT:
    case WT_DOTDOT:
    case WT_BACKTICK:
    case WT_RPAREN:
    case WT_RBRACKET:
    case WT_RBRACE:
      return true;
    // Words that can never begin a block item.
    case WT_KEYWORD:
      switch ((WokWord)t->word) {
        case WW_WHERE:
        case WW_IN:
        case WW_THEN:
        case WW_ELSE:
        case WW_OF:
        case WW_AS:
        case WW_WITH:
          return true;
        case WW_NONE:
        case WW_MODULE:
        case WW_IMPORT:
        case WW_TYPE:
        case WW_ALIAS:
        case WW_CLASS:
        case WW_INSTANCE:
        case WW_LET:
        case WW_CASE:
        case WW_IF:
        case WW_EFFECT:
        case WW_HANDLER:
        case WW_HANDLE:
        case WW_USE:
        case WW_ABORT:
        case WW_ONCE:
        case WW_RETURN:
        case WW_VAR:
        case WW_FOREIGN:
        case WW_EXTERN:
        case WW_FIXITY:
        case WW_OWN:
        case WW_LEND:
        case WW_COPY:
        case WW_ROW:
        case WW_EFF:
        case WW_LEFT:
        case WW_RIGHT:
        case WW_TIGHTER:
        case WW_LOOSER:
        case WW_THAN:
        case WW_PLUS:
        case WOK_WORD_COUNT:
          return false;
      }
      WOK_UNREACHABLE();
    case WT_EOF:
    case WT_NEWLINE:
    case WT_INDENT:
    case WT_DEDENT:
    case WT_VARID:
    case WT_CONID:
    case WT_INT:
    case WT_STRING:
    case WT_CHAR:
    case WT_LPAREN:
    case WT_LBRACKET:
    case WT_LBRACE:
    case WT_UNDERSCORE:
    case WT_LAMBDA:
    case WT_SEMI:
    case WT_BAD:
    case WOK_KIND_COUNT:
      return false;
  }
  WOK_UNREACHABLE();
}

// Decodes an integer literal, reporting E-LEX-INT-RANGE on overflow past U64.
// Uses ckd_mul/ckd_add where available: literal conversion is where parsers
// get CVEs, and this is a defect-class elimination rather than a style choice.
bool wok_token_int_value(const char *src, const WokToken *, WokDiagSink *,
                         u64 *out);

static inline const char *wok_token_text(const char *src, const WokToken *t) {
  return src + t->off;
}

// Test hooks. The symbol charset is a bitmap for speed; test_roster.c checks
// it against the readable definition for all 256 byte values, which is what
// makes a hand-written bitmap safe. wok_print.c also reads two of them, so the
// filler's lead test cannot grow a second opinion about the charset.
bool wok_test_is_sym(unsigned char);
bool wok_test_is_ident_start(unsigned char);
bool wok_test_is_ident_cont(unsigned char);

