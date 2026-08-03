// wok_parse -- stage 3. Recursive descent over the post-layout token stream.
//
// One function per production in section 7 of the frontend design spec, named
// after the production. Nothing here reads a token's bytes to make a decision:
// every choice is a kind or a word compare, so a misspelling fails to compile.
//
// Two rules of FORM are enforced (they are grammar facts, not analyses):
//   - a `handle` STATEMENT must write its label (P1/D13);
//   - a `once` clause's continuation binder must be a plain lowercase name
//     (D14), which is what lets a later pass compare pattern count to arity.
//
// Operator chains stay FLAT. src/Wok/Reordering.hs owns fixity, so no
// precedence table lives here.

#include "wok_parse.h"

#include "wok_utf8.h"

#include <stdio.h>

#include "wok_layout.h"
#include "wok_trivia.h"

// ---------------------------------------------------------------- state

typedef struct {
  const WokToken *tok;
  usize n;
  usize i;
  const char *src;
  WokArena *a;
  WokDiagSink *d;
  u32 depth;
  // A NEWLINE that closed a nested block is also the enclosing block's item
  // separator; closing the inner block carries it out here.
  bool sep;
  // The current item is damaged. One message per item is the whole recovery
  // contract, so every report site is gated on this.
  bool panic;
  // `own`/`lend`/`copy` are contextual: they are transfer modes only at the
  // head of a foreign member's signature type, and ordinary names everywhere
  // else (spec.md section 2 writes `Bytes.copy` itself).
  bool foreign_sig;
  u32 last_end;
  char desc[64];
} P;

// ---------------------------------------------------------------- cursor

static const WokToken *cur(const P *p) { return &p->tok[p->i]; }

static WokKind kind_at(const P *p, usize k) {
  usize j = p->i + k;
  if (j >= p->n) j = p->n - 1;
  return (WokKind)p->tok[j].kind;
}

static WokWord word_at(const P *p, usize k) {
  usize j = p->i + k;
  if (j >= p->n) j = p->n - 1;
  return (WokWord)p->tok[j].word;
}

static bool at(const P *p, WokKind k) { return (WokKind)cur(p)->kind == k; }

static bool at_word(const P *p, WokWord w) { return (WokWord)cur(p)->word == w; }

static void bump(P *p) {
  const WokToken *t = cur(p);
  if (t->len > 0) p->last_end = t->off + t->len;
  if (p->i + 1 < p->n) p->i++;
}

static u32 span_end(const P *p) { return p->last_end; }

static WokSpan tok_span(const WokToken *t) { return wok_span(t->off, t->len); }

// Allocates and marks production coverage in one place, so a form no corpus
// file reaches names itself rather than sitting silently uncovered.
static WokNode *mk(P *p, WokTag tag, u32 start, u32 end) {
  wok_cover_mark(tag);
  return wok_node(p->a, tag, start, end > start ? end - start : 0);
}

// ------------------------------------------------------------ diagnostics

static const char *tok_desc(P *p, const WokToken *t) {
  if ((WokKind)t->kind == WT_EOF) return "end of file";
  if ((WokKind)t->kind == WT_NEWLINE) return "end of line";
  if ((WokKind)t->kind == WT_INDENT) return "an indented block";
  if ((WokKind)t->kind == WT_DEDENT) return "the end of a block";
  // A BYTE cap would cut a multi-byte character in half and put an
  // ill-formed sequence into the message -- on valid input.
  usize len = wok_utf8_truncate((const unsigned char *)p->src + t->off,
                                 t->len, 40);
  snprintf(p->desc, sizeof p->desc, "`%.*s`", (int)len, p->src + t->off);
  return p->desc;
}

// E1. A layout token carries the position of the token it PRECEDES --
// wok_layout.c builds it from the next token, which is right for the block
// rule and wrong for blame. Reporting one sends the reader to the line AFTER
// the broken one, which is usually a perfectly good declaration.
//
// So a fault on a layout token is blamed at the end of the last thing the
// author actually wrote, which is where a missing `=` or `->` belongs. All
// layout tokens have len 0, and `bump` only advances `last_end` past tokens
// with len > 0, so that field is already exactly what is wanted.
static WokSpan blame(const P *p, const WokToken *t) {
  if (t->len == 0) return wok_span(p->last_end, 0);
  return wok_span(t->off, t->len);
}

static void perr_at(P *p, WokDiagCode code, const WokToken *t,
                    const char *msg) {
  if (p->panic) return;
  WokSpan b = blame(p, t);
  wok_diag_add(p->d, code, b.off, b.len, "%s", msg);
  p->panic = true;
}

// Reports without entering panic: the item is otherwise complete, so keeping
// its node is worth more than discarding it, and no second message can follow.
static void perr_form(P *p, WokDiagCode code, const WokToken *t,
                      const char *msg) {
  if (p->panic) return;
  WokSpan b = blame(p, t);
  wok_diag_add(p->d, code, b.off, b.len, "%s", msg);
}

static void perr_expect(P *p, const char *what) {
  if (p->panic) return;
  const WokToken *t = cur(p);
  if ((WokKind)t->kind == WT_INDENT) {
    // D-LAY-3. The corpus contains zero of these, which is what lets the
    // parser carry no continuation machinery at all.
    wok_diag_add(p->d, WOK_E_LAY_INDENT, blame(p, t).off, blame(p, t).len,
                 "unexpected indentation; to continue a line, begin it with "
                 "an operator, or bracket the expression");
  } else {
    WokSpan b = blame(p, t);
    wok_diag_add(p->d, WOK_E_PARSE, b.off, b.len, "expected %s, found %s",
                 what, tok_desc(p, t));
  }
  p->panic = true;
}

// TIER 1 (single-token insert / delete / substitute local repair, Diekmann &
// Tratt CPCT+ with a fixed budget) WOULD GO HERE, between the report and the
// caller's fallback. It is a later slice; today every fault falls straight
// through to tier 2 region discard in the block-item loop.

static bool expect(P *p, WokKind k, const char *what) {
  if (at(p, k)) {
    bump(p);
    return true;
  }
  perr_expect(p, what);
  return false;
}

static bool expect_word(P *p, WokWord w, const char *what) {
  if (at_word(p, w)) {
    bump(p);
    return true;
  }
  perr_expect(p, what);
  return false;
}

static WokSpan take_kind(P *p, WokKind k, const char *what) {
  const WokToken *t = cur(p);
  if ((WokKind)t->kind == k) {
    bump(p);
    return tok_span(t);
  }
  perr_expect(p, what);
  return wok_span(t->off, 0);
}

static WokSpan take_any_name(P *p, const char *what) {
  const WokToken *t = cur(p);
  if ((WokKind)t->kind == WT_VARID || (WokKind)t->kind == WT_CONID) {
    bump(p);
    return tok_span(t);
  }
  perr_expect(p, what);
  return wok_span(t->off, 0);
}

// Bounded recursion: `((((((...` exhausting the C stack is the second classic
// parser CVE after literal overflow, and <stdckdint.h> only covers the first.
static bool enter(P *p) {
  if (p->depth >= WOK_PARSE_MAX_DEPTH) {
    if (!p->panic) {
      const WokToken *t = cur(p);
      wok_diag_add(p->d, WOK_E_DEPTH, t->off, t->len,
                   "nested deeper than %d levels", WOK_PARSE_MAX_DEPTH);
      p->panic = true;
    }
    return false;
  }
  p->depth++;
  return true;
}

static void leave(P *p) { p->depth--; }

static WokNode *mk_error(P *p, WokTag tag, u32 start) {
  WokNode *n = mk(p, tag, start, span_end(p));
  WokSpan text = wok_span(start, n->len);
  if (tag == D_Error)
    D_Error_set_text(n, text);
  else
    E_Error_set_text(n, text);
  return n;
}

static WokNode *mk_err(P *p) { return mk_error(p, E_Error, cur(p)->off); }

// -------------------------------------------------------------- the block
//
// BLOCK(x) := NEWLINE INDENT x (NEWLINE x)* DEDENT | x
//
// Called ONLY where the grammar already owes a block: after `=`, `of`, `->`,
// `where`, `in`, `:=`, and after an effect / class / instance / foreign module
// / handler head. A DEDENT is not always preceded by a NEWLINE -- a
// continuation line emits its DEDENTs with no item separator, which is the
// whole point of rule L4.

typedef struct {
  bool indented;
} Block;

static Block block_begin(P *p) {
  Block b = {.indented = false};
  if (p->panic) return b;
  if (at(p, WT_NEWLINE) && kind_at(p, 1) == WT_INDENT) {
    bump(p);
    bump(p);
    b.indented = true;
  } else if (at(p, WT_NEWLINE) || at(p, WT_DEDENT) || at(p, WT_EOF)) {
    perr_at(p, WOK_E_LAY_EXPECTED_BLOCK, cur(p),
            "expected a body here: write it on this line, or on the next line "
            "indented further");
  }
  return b;
}

static bool block_next(P *p, const Block *b) {
  if (!b->indented) return false;
  if (at(p, WT_DEDENT)) return false;
  if (p->sep) {
    p->sep = false;
    return true;
  }
  if (at(p, WT_NEWLINE)) {
    if (kind_at(p, 1) == WT_DEDENT) return false;
    bump(p);
    return true;
  }
  // A continuation lead (`where`, `in`, ...) belongs to the caller.
  return false;
}

static void block_end(P *p, const Block *b) {
  if (!b->indented) return;
  bool sep = p->sep;
  p->sep = false;
  if (at(p, WT_NEWLINE) && kind_at(p, 1) == WT_DEDENT) {
    bump(p);
    sep = true;
  }
  if (at(p, WT_DEDENT))
    bump(p);
  else if (!at(p, WT_EOF))
    perr_expect(p, "the end of this block");
  p->sep = sep;
}

// ---------------------------------------------------------------- recovery
//
// TIER 2 -- region discard (de Jonge / Kats / Visser / Soderberg). Abandon the
// item, emit an error node so the block skeleton survives, skip to the next
// NEWLINE at this block's level or to its DEDENT. DEDENT is a free
// synchronisation point: it is arithmetic from columns, not a guess about what
// a closing brace meant, so a damaged item can never swallow its block.

static void resync_to_boundary(P *p) {
  int br = 0, ind = 0;
  for (;;) {
    WokKind k = (WokKind)cur(p)->kind;
    if (k == WT_EOF) return;
    if (br == 0) {
      if (k == WT_INDENT) {
        ind++;
        bump(p);
        continue;
      }
      if (k == WT_DEDENT) {
        if (ind == 0) return;
        ind--;
        bump(p);
        continue;
      }
      if (k == WT_NEWLINE) {
        if (ind == 0) return;
        // The NEWLINE that precedes a run of DEDENTs is the separator of every
        // level it closes, including ours. Consume exactly the ones we skipped
        // into and hand the separator to the block loop.
        int d = 0;
        while (kind_at(p, (usize)d + 1) == WT_DEDENT) d++;
        if (d >= ind) {
          bump(p);
          for (int j = 0; j < ind; j++) bump(p);
          ind = 0;
          if ((WokKind)cur(p)->kind == WT_DEDENT) return;
          p->sep = true;
          return;
        }
        bump(p);
        continue;
      }
    }
    if (wok_kind_is_open_bracket(k))
      br++;
    else if (wok_kind_is_close_bracket(k) && br > 0)
      br--;
    bump(p);
  }
}

static bool word_starts_decl(WokWord w) {
  return w == WW_MODULE || w == WW_IMPORT || w == WW_TYPE || w == WW_ALIAS ||
         w == WW_EFFECT || w == WW_CLASS || w == WW_INSTANCE ||
         w == WW_FOREIGN || w == WW_EXTERN;
}

// Forward-only declarations (D23) are what make a signature the strongest
// anchor available: `name :` at a block column can never be the tail of a
// damaged item.
static bool at_decl_anchor(const P *p, usize j) {
  if (j >= p->n) return false;
  const WokToken *t = &p->tok[j];
  // E4. resync_to_boundary stops at a NEWLINE at the block's OWN level, and
  // the layout filter emits one exactly where an item begins -- so the
  // boundary is already exact and the anchor's only job is to reject
  // WRECKAGE. A `)` or `->` stranded at the block column cannot start a
  // declaration, and those are precisely the CONTINUATION LEADS, which is a
  // question the scanner already answers.
  //
  // The previous rule accepted only a declaration keyword or `name :`. That
  // made a damaged EQUATION not an anchor, so recovery walked over every one
  // it met: five broken equations in a row reported only the first, and the
  // batch stopped early exactly when a file was uniformly broken.
  // A KEYWORD still has to be a declaration keyword: `let` or `case` at the
  // top level is not a fresh declaration, it is wreckage from a damaged one.
  if ((WokKind)t->kind == WT_KEYWORD) return word_starts_decl((WokWord)t->word);
  return !wok_token_is_continuation_lead(t);
}

static void resync_decl(P *p) {
  for (;;) {
    resync_to_boundary(p);
    if (!at(p, WT_NEWLINE)) return;
    if (kind_at(p, 1) == WT_DEDENT) return;
    if (at_decl_anchor(p, p->i + 1)) return;
    bump(p);
  }
}

// ------------------------------------------------------------ predicates

static bool starts_atom(const P *p) {
  WokKind k = (WokKind)cur(p)->kind;
  return k == WT_VARID || k == WT_CONID || k == WT_INT || k == WT_STRING ||
         k == WT_CHAR || k == WT_LPAREN || k == WT_LBRACKET;
}

static bool starts_atompat(const P *p) {
  WokKind k = (WokKind)cur(p)->kind;
  if (k == WT_VARID || k == WT_CONID || k == WT_UNDERSCORE || k == WT_INT ||
      k == WT_STRING || k == WT_CHAR || k == WT_LPAREN || k == WT_LBRACKET)
    return true;
  // `-` Int is the only pattern an operator can begin.
  if (k == WT_VARSYM) return kind_at(p, 1) == WT_INT;
  return false;
}

static bool starts_atomtype(const P *p) {
  WokKind k = (WokKind)cur(p)->kind;
  return k == WT_VARID || k == WT_CONID || k == WT_LPAREN || k == WT_LBRACKET;
}

static bool starts_typaram(const P *p) {
  if (at(p, WT_VARID)) return true;
  return at(p, WT_LPAREN) && word_at(p, 1) == WW_ROW;
}

static bool at_infixop(const P *p) {
  WokKind k = (WokKind)cur(p)->kind;
  if (k == WT_VARSYM || k == WT_COLONCOLON) return true;
  return k == WT_BACKTICK && kind_at(p, 1) == WT_VARID &&
         kind_at(p, 2) == WT_BACKTICK;
}

// ------------------------------------------------------------- prototypes

static WokNode *parse_name(P *p);
static WokNode *parse_modpath(P *p);
static WokNode *parse_decl(P *p);
static WokNode *parse_sig_or_equation(P *p);
static WokNode *parse_type(P *p);
static WokNode *parse_arrow(P *p);
static WokNode *parse_typeapp(P *p);
static WokNode *parse_atomtype(P *p);
static WokSeq parse_row(P *p);
static WokNode *parse_rowentry(P *p);
static WokNode *parse_pat(P *p);
static WokNode *parse_patapp(P *p);
static WokNode *parse_atompat(P *p);
static WokNode *parse_expr(P *p);
static WokNode *parse_chain(P *p);
static WokNode *parse_app(P *p);
static WokNode *parse_atom(P *p);
static WokNode *parse_stmt(P *p);
static WokNode *parse_body(P *p);
static WokNode *parse_bind(P *p);
static WokNode *parse_alt(P *p);
static WokNode *parse_clause(P *p);
static WokSeq parse_where(P *p);

// ------------------------------------------------------------ block lists

typedef WokNode *(*ItemFn)(P *);

static WokSeq parse_block_list(P *p, const Block *b, ItemFn item,
                               bool decl_block) {
  WokNodeBuf buf;
  wok_buf_init(&buf, p->a);
  do {
    usize before = p->i;
    u32 start = cur(p)->off;
    WokNode *n = item(p);
    if (p->panic) {
      if (decl_block)
        resync_decl(p);
      else
        resync_to_boundary(p);
      n = mk_error(p, decl_block ? D_Error : E_Error, start);
      p->panic = false;
    }
    wok_buf_push(&buf, n);
    if (p->i == before && !at(p, WT_EOF) && !at(p, WT_NEWLINE) &&
        !at(p, WT_DEDENT))
      bump(p);
  } while (block_next(p, b));
  return wok_buf_seq(&buf);
}

// A body is `expr | E_Block`. E_Block is used whenever the indented form was
// taken -- even for one statement -- so a printer can re-derive line breaks.
static WokNode *parse_block_body(P *p, const Block *b) {
  if (!b->indented) return parse_expr(p);
  u32 start = cur(p)->off;
  WokSeq stmts = parse_block_list(p, b, parse_stmt, false);
  WokNode *n = mk(p, E_Block, start, span_end(p));
  E_Block_set_stmts(n, stmts);
  return n;
}

static WokNode *parse_body(P *p) {
  Block b = block_begin(p);
  WokNode *n = parse_block_body(p, &b);
  block_end(p, &b);
  return n;
}

static WokSeq parse_where(P *p) {
  bump(p);  // `where`
  Block b = block_begin(p);
  WokSeq s = parse_block_list(p, &b, parse_sig_or_equation, true);
  block_end(p, &b);
  return s;
}

// ------------------------------------------------------------------ names

static WokNode *parse_name(P *p) {
  const WokToken *t = cur(p);
  u32 start = t->off;
  bool upper = (WokKind)t->kind == WT_CONID;
  WokSpan text;
  if (upper || (WokKind)t->kind == WT_VARID) {
    text = tok_span(t);
    bump(p);
  } else {
    perr_expect(p, "a name");
    text = wok_span(t->off, 0);
    upper = false;
  }
  WokNode *n = mk(p, N_Name, start, span_end(p));
  N_Name_set_text(n, text);
  N_Name_set_upper(n, upper);
  return n;
}

static WokNode *parse_modpath(P *p) {
  u32 start = cur(p)->off;
  WokNodeBuf parts;
  wok_buf_init(&parts, p->a);
  wok_buf_push(&parts, parse_name(p));
  while (at(p, WT_DOT) && kind_at(p, 1) == WT_CONID && !p->panic) {
    bump(p);
    wok_buf_push(&parts, parse_name(p));
  }
  WokNode *n = mk(p, N_ModPath, start, span_end(p));
  N_ModPath_set_parts(n, wok_buf_seq(&parts));
  return n;
}

// ------------------------------------------------------------------ types

static WokNode *parse_type(P *p) {
  if (!enter(p)) return mk_err(p);
  u32 start = cur(p)->off;
  WokNode *lhs = parse_arrow(p);
  WokNode *r = lhs;
  if (at(p, WT_FATARROW)) {
    bump(p);
    WokNode *body = parse_type(p);
    r = mk(p, T_Qual, start, span_end(p));
    T_Qual_set_ctx(r, lhs);
    T_Qual_set_body(r, body);
  } else if (at_word(p, WW_WITH)) {
    bump(p);
    WokSeq row = parse_row(p);
    r = mk(p, T_With, start, span_end(p));
    T_With_set_body(r, lhs);
    T_With_set_row(r, row);
  }
  leave(p);
  return r;
}

static WokNode *parse_arrow(P *p) {
  if (!enter(p)) return mk_err(p);
  u32 start = cur(p)->off;
  WokNode *l = parse_typeapp(p);
  WokNode *r = l;
  if (at(p, WT_ARROW)) {
    bump(p);
    WokNode *to = parse_arrow(p);
    r = mk(p, T_Fun, start, span_end(p));
    T_Fun_set_from(r, l);
    T_Fun_set_to(r, to);
  }
  leave(p);
  return r;
}

static WokNode *parse_typeapp(P *p) {
  u32 start = cur(p)->off;
  u64 mode = WOK_TRANSFER_OWN;
  bool transfer = false;
  if (p->foreign_sig && at(p, WT_VARID)) {
    WokWord w = (WokWord)cur(p)->word;
    if (w == WW_OWN) {
      mode = WOK_TRANSFER_OWN;
      transfer = true;
    } else if (w == WW_LEND) {
      mode = WOK_TRANSFER_LEND;
      transfer = true;
    } else if (w == WW_COPY) {
      mode = WOK_TRANSFER_COPY;
      transfer = true;
    }
    if (transfer) bump(p);
  }
  WokNode *t = parse_atomtype(p);
  while (starts_atomtype(p) && !p->panic) {
    WokNode *arg = parse_atomtype(p);
    WokNode *app = mk(p, T_App, start, span_end(p));
    T_App_set_fn(app, t);
    T_App_set_arg(app, arg);
    t = app;
  }
  if (transfer) {
    WokNode *tr = mk(p, T_Transfer, start, span_end(p));
    T_Transfer_set_mode(tr, mode);
    T_Transfer_set_body(tr, t);
    t = tr;
  }
  return t;
}

static WokNode *parse_atomtype(P *p) {
  if (!enter(p)) return mk_err(p);
  u32 start = cur(p)->off;
  WokNode *r;
  if (at(p, WT_VARID)) {
    const WokToken *t = cur(p);
    bump(p);
    r = mk(p, T_Var, start, span_end(p));
    T_Var_set_name(r, tok_span(t));
  } else if (at(p, WT_CONID)) {
    WokNode *path = parse_modpath(p);
    r = mk(p, T_Con, start, span_end(p));
    T_Con_set_path(r, path);
  } else if (at(p, WT_LBRACKET)) {
    bump(p);
    WokNode *elem = parse_type(p);
    expect(p, WT_RBRACKET, "`]` to close this list type");
    r = mk(p, T_List, start, span_end(p));
    T_List_set_elem(r, elem);
  } else if (at(p, WT_LPAREN)) {
    bump(p);
    if (at(p, WT_RPAREN)) {
      bump(p);
      r = mk(p, T_Unit, start, span_end(p));
    } else if (at_word(p, WW_ROW) && kind_at(p, 1) == WT_VARID &&
               kind_at(p, 2) == WT_RPAREN) {
      bump(p);
      const WokToken *v = cur(p);
      bump(p);
      bump(p);
      r = mk(p, T_RowArg, start, span_end(p));
      T_RowArg_set_name(r, tok_span(v));
    } else {
      WokNodeBuf items;
      wok_buf_init(&items, p->a);
      wok_buf_push(&items, parse_type(p));
      while (at(p, WT_COMMA) && !p->panic) {
        bump(p);
        wok_buf_push(&items, parse_type(p));
      }
      expect(p, WT_RPAREN, "`)` to close this type");
      if (wok_buf_count(&items) == 1) {
        r = wok_buf_at(&items, 0);
      } else {
        r = mk(p, T_Tuple, start, span_end(p));
        T_Tuple_set_items(r, wok_buf_seq(&items));
      }
    }
  } else {
    perr_expect(p, "a type");
    r = mk_err(p);
  }
  leave(p);
  return r;
}

static WokSeq parse_row(P *p) {
  WokNodeBuf buf;
  wok_buf_init(&buf, p->a);
  wok_buf_push(&buf, parse_rowentry(p));
  while (at_word(p, WW_PLUS) && !p->panic) {
    bump(p);
    wok_buf_push(&buf, parse_rowentry(p));
  }
  return wok_buf_seq(&buf);
}

static WokNode *parse_rowentry(P *p) {
  u32 start = cur(p)->off;
  WokNode *n;
  if (at(p, WT_LPAREN) && kind_at(p, 1) == WT_VARID &&
      kind_at(p, 2) == WT_COLON) {
    // A role obligation (D20). The label is lowercase by construction.
    bump(p);
    const WokToken *label = cur(p);
    bump(p);
    bump(p);
    WokNode *ty = parse_typeapp(p);
    expect(p, WT_RPAREN, "`)` to close this role obligation");
    n = mk(p, H_RowEntry, start, span_end(p));
    H_RowEntry_set_kind(n, WOK_ROW_ROLE);
    H_RowEntry_set_label(n, tok_span(label));
    H_RowEntry_set_type(n, ty);
  } else if (at_word(p, WW_EFF) && kind_at(p, 1) == WT_VARID) {
    bump(p);
    const WokToken *v = cur(p);
    bump(p);
    n = mk(p, H_RowEntry, start, span_end(p));
    H_RowEntry_set_kind(n, WOK_ROW_VAR);
    H_RowEntry_set_label(n, tok_span(v));
    H_RowEntry_set_type(n, nullptr);
  } else {
    WokNode *ty = parse_typeapp(p);
    n = mk(p, H_RowEntry, start, span_end(p));
    H_RowEntry_set_kind(n, WOK_ROW_SLOT);
    H_RowEntry_set_label(n, wok_span(start, 0));
    H_RowEntry_set_type(n, ty);
  }
  return n;
}

// --------------------------------------------------------------- patterns

static WokNode *parse_fieldpat(P *p) {
  u32 start = cur(p)->off;
  WokSpan name = take_kind(p, WT_VARID, "a field name");
  WokNode *pat;
  if (at(p, WT_EQUALS)) {
    bump(p);
    pat = parse_pat(p);
  } else {
    // Punned: `{ x }` binds the field to its own name.
    pat = mk(p, P_Var, start, span_end(p));
    P_Var_set_name(pat, name);
  }
  WokNode *n = mk(p, H_FieldPat, start, span_end(p));
  H_FieldPat_set_name(n, name);
  H_FieldPat_set_pat(n, pat);
  return n;
}

static WokNode *parse_record_pat(P *p, u32 start, WokNode *path) {
  bump(p);  // `{`
  bool is_open = false;
  WokSpan rest = wok_span(start, 0);
  if (at(p, WT_DOTDOT)) {
    bump(p);
    is_open = true;
    if (at(p, WT_VARID)) {
      rest = tok_span(cur(p));
      bump(p);
    }
    if (at(p, WT_COMMA)) bump(p);
  }
  WokNodeBuf fields;
  wok_buf_init(&fields, p->a);
  if (!at(p, WT_RBRACE) && !p->panic) {
    wok_buf_push(&fields, parse_fieldpat(p));
    while (at(p, WT_COMMA) && !p->panic) {
      bump(p);
      wok_buf_push(&fields, parse_fieldpat(p));
    }
  }
  expect(p, WT_RBRACE, "`}` to close this record pattern");
  WokNode *n = mk(p, P_Record, start, span_end(p));
  P_Record_set_path(n, path);
  P_Record_set_fields(n, wok_buf_seq(&fields));
  P_Record_set_is_open(n, is_open);
  P_Record_set_rest(n, rest);
  return n;
}

static WokNode *parse_as_tail(P *p, WokNode *inner, u32 start) {
  while (at_word(p, WW_AS) && !p->panic) {
    bump(p);
    WokSpan name = take_kind(p, WT_VARID, "a name after `as`");
    WokNode *n = mk(p, P_As, start, span_end(p));
    P_As_set_pat(n, inner);
    P_As_set_name(n, name);
    inner = n;
  }
  return inner;
}

static WokNode *parse_atompat(P *p) {
  if (!enter(p)) return mk_err(p);
  u32 start = cur(p)->off;
  WokNode *r;
  if (at(p, WT_VARID)) {
    const WokToken *t = cur(p);
    bump(p);
    r = mk(p, P_Var, start, span_end(p));
    P_Var_set_name(r, tok_span(t));
  } else if (at(p, WT_UNDERSCORE)) {
    bump(p);
    r = mk(p, P_Wild, start, span_end(p));
  } else if (at(p, WT_INT)) {
    const WokToken *t = cur(p);
    u64 v = 0;
    (void)wok_token_int_value(p->src, t, p->d, &v);
    bump(p);
    r = mk(p, P_Int, start, span_end(p));
    P_Int_set_value(r, v);
    P_Int_set_negative(r, false);
  } else if (at(p, WT_VARSYM) && kind_at(p, 1) == WT_INT) {
    bump(p);
    const WokToken *t = cur(p);
    u64 v = 0;
    (void)wok_token_int_value(p->src, t, p->d, &v);
    bump(p);
    r = mk(p, P_Int, start, span_end(p));
    P_Int_set_value(r, v);
    P_Int_set_negative(r, true);
  } else if (at(p, WT_STRING)) {
    const WokToken *t = cur(p);
    bump(p);
    r = mk(p, P_Str, start, span_end(p));
    P_Str_set_text(r, tok_span(t));
  } else if (at(p, WT_CHAR)) {
    const WokToken *t = cur(p);
    bump(p);
    r = mk(p, P_Char, start, span_end(p));
    P_Char_set_text(r, tok_span(t));
  } else if (at(p, WT_CONID)) {
    WokNode *path = parse_modpath(p);
    if (at(p, WT_LBRACE)) {
      r = parse_record_pat(p, start, path);
    } else {
      r = mk(p, P_Con, start, span_end(p));
      P_Con_set_path(r, path);
      P_Con_set_args(r, wok_seq_empty());
    }
  } else if (at(p, WT_LPAREN)) {
    bump(p);
    if (at(p, WT_RPAREN)) {
      bump(p);
      r = mk(p, P_Unit, start, span_end(p));
    } else {
      WokNodeBuf items;
      wok_buf_init(&items, p->a);
      wok_buf_push(&items, parse_pat(p));
      while (at(p, WT_COMMA) && !p->panic) {
        bump(p);
        wok_buf_push(&items, parse_pat(p));
      }
      expect(p, WT_RPAREN, "`)` to close this pattern");
      if (wok_buf_count(&items) == 1) {
        r = wok_buf_at(&items, 0);
      } else {
        r = mk(p, P_Tuple, start, span_end(p));
        P_Tuple_set_items(r, wok_buf_seq(&items));
      }
    }
  } else if (at(p, WT_LBRACKET)) {
    bump(p);
    WokNodeBuf items;
    wok_buf_init(&items, p->a);
    if (!at(p, WT_RBRACKET) && !p->panic) {
      wok_buf_push(&items, parse_pat(p));
      while (at(p, WT_COMMA) && !p->panic) {
        bump(p);
        wok_buf_push(&items, parse_pat(p));
      }
    }
    expect(p, WT_RBRACKET, "`]` to close this list pattern");
    r = mk(p, P_List, start, span_end(p));
    P_List_set_items(r, wok_buf_seq(&items));
  } else {
    perr_expect(p, "a pattern");
    r = mk_err(p);
  }
  r = parse_as_tail(p, r, start);
  leave(p);
  return r;
}

static WokNode *parse_patapp(P *p) {
  if (!at(p, WT_CONID)) return parse_atompat(p);
  u32 start = cur(p)->off;
  WokNode *path = parse_modpath(p);
  if (at(p, WT_LBRACE))
    return parse_as_tail(p, parse_record_pat(p, start, path), start);
  if (!starts_atompat(p)) {
    WokNode *bare = mk(p, P_Con, start, span_end(p));
    P_Con_set_path(bare, path);
    P_Con_set_args(bare, wok_seq_empty());
    return parse_as_tail(p, bare, start);
  }
  WokNodeBuf args;
  wok_buf_init(&args, p->a);
  while (starts_atompat(p) && !p->panic) wok_buf_push(&args, parse_atompat(p));
  WokNode *n = mk(p, P_Con, start, span_end(p));
  P_Con_set_path(n, path);
  P_Con_set_args(n, wok_buf_seq(&args));
  return n;
}

static WokNode *parse_pat(P *p) {
  if (!enter(p)) return mk_err(p);
  u32 start = cur(p)->off;
  WokNode *head = parse_patapp(p);
  WokNode *r = head;
  if (at(p, WT_COLONCOLON)) {
    bump(p);
    WokNode *tail = parse_pat(p);
    r = mk(p, P_Cons, start, span_end(p));
    P_Cons_set_head(r, head);
    P_Cons_set_tail(r, tail);
  }
  leave(p);
  return r;
}

// ------------------------------------------------------------ expressions

static WokNode *parse_field(P *p) {
  u32 start = cur(p)->off;
  WokSpan name = take_kind(p, WT_VARID, "a field name");
  WokNode *value;
  if (at(p, WT_EQUALS)) {
    bump(p);
    value = parse_expr(p);
  } else {
    value = mk(p, E_Var, start, span_end(p));
    E_Var_set_name(value, name);
  }
  WokNode *n = mk(p, H_Field, start, span_end(p));
  H_Field_set_name(n, name);
  H_Field_set_value(n, value);
  return n;
}

static WokNode *parse_record_expr(P *p, u32 start, WokNode *path) {
  bump(p);  // `{`
  WokNode *spread = nullptr;
  if (at(p, WT_DOTDOT)) {
    bump(p);
    spread = parse_expr(p);
    if (at(p, WT_COMMA)) bump(p);
  }
  WokNodeBuf fields;
  wok_buf_init(&fields, p->a);
  if (!at(p, WT_RBRACE) && !p->panic) {
    wok_buf_push(&fields, parse_field(p));
    while (at(p, WT_COMMA) && !p->panic) {
      bump(p);
      wok_buf_push(&fields, parse_field(p));
    }
  }
  expect(p, WT_RBRACE, "`}` to close this record");
  WokNode *n = mk(p, E_Record, start, span_end(p));
  E_Record_set_path(n, path);
  E_Record_set_spread(n, spread);
  E_Record_set_fields(n, wok_buf_seq(&fields));
  return n;
}

static bool is_con_atom(const WokNode *n) {
  if (n->tag == E_Con) return true;
  return n->tag == E_Dot && E_Dot_upper(n);
}

static WokNode *parse_atom(P *p) {
  if (!enter(p)) return mk_err(p);
  u32 start = cur(p)->off;
  WokNode *r;
  if (at(p, WT_VARID)) {
    const WokToken *t = cur(p);
    bump(p);
    r = mk(p, E_Var, start, span_end(p));
    E_Var_set_name(r, tok_span(t));
  } else if (at(p, WT_CONID)) {
    const WokToken *t = cur(p);
    bump(p);
    r = mk(p, E_Con, start, span_end(p));
    E_Con_set_name(r, tok_span(t));
  } else if (at(p, WT_INT)) {
    const WokToken *t = cur(p);
    u64 v = 0;
    (void)wok_token_int_value(p->src, t, p->d, &v);
    bump(p);
    r = mk(p, E_Int, start, span_end(p));
    E_Int_set_value(r, v);
  } else if (at(p, WT_STRING)) {
    const WokToken *t = cur(p);
    bump(p);
    r = mk(p, E_Str, start, span_end(p));
    E_Str_set_text(r, tok_span(t));
  } else if (at(p, WT_CHAR)) {
    const WokToken *t = cur(p);
    bump(p);
    r = mk(p, E_Char, start, span_end(p));
    E_Char_set_text(r, tok_span(t));
  } else if (at(p, WT_LPAREN)) {
    bump(p);
    if (at(p, WT_RPAREN)) {
      bump(p);
      r = mk(p, E_Unit, start, span_end(p));
    } else if (at(p, WT_VARSYM) && kind_at(p, 1) == WT_RPAREN) {
      const WokToken *t = cur(p);
      bump(p);
      bump(p);
      r = mk(p, E_OpRef, start, span_end(p));
      E_OpRef_set_name(r, tok_span(t));
    } else {
      WokNodeBuf items;
      wok_buf_init(&items, p->a);
      wok_buf_push(&items, parse_expr(p));
      while (at(p, WT_COMMA) && !p->panic) {
        bump(p);
        wok_buf_push(&items, parse_expr(p));
      }
      expect(p, WT_RPAREN, "`)` to close this expression");
      if (wok_buf_count(&items) == 1) {
        r = wok_buf_at(&items, 0);
      } else {
        r = mk(p, E_Tuple, start, span_end(p));
        E_Tuple_set_items(r, wok_buf_seq(&items));
      }
    }
  } else if (at(p, WT_LBRACKET)) {
    bump(p);
    WokNodeBuf items;
    wok_buf_init(&items, p->a);
    if (!at(p, WT_RBRACKET) && !p->panic) {
      wok_buf_push(&items, parse_expr(p));
      while (at(p, WT_COMMA) && !p->panic) {
        bump(p);
        wok_buf_push(&items, parse_expr(p));
      }
    }
    expect(p, WT_RBRACKET, "`]` to close this list");
    r = mk(p, E_List, start, span_end(p));
    E_List_set_items(r, wok_buf_seq(&items));
  } else {
    perr_expect(p, "an expression");
    r = mk_err(p);
  }
  // ONE Dot node for `M.f`, `st.get` and `p.x`: spec 1.5 resolves qualifier /
  // label / projection later, and its collision rule needs them
  // undistinguished at parse time.
  while (!p->panic) {
    if (at(p, WT_DOT) &&
        (kind_at(p, 1) == WT_VARID || kind_at(p, 1) == WT_CONID)) {
      bump(p);
      const WokToken *t = cur(p);
      bool upper = (WokKind)t->kind == WT_CONID;
      bump(p);
      WokNode *dot = mk(p, E_Dot, start, span_end(p));
      E_Dot_set_recv(dot, r);
      E_Dot_set_name(dot, tok_span(t));
      E_Dot_set_upper(dot, upper);
      r = dot;
      continue;
    }
    if (at(p, WT_LBRACE) && is_con_atom(r)) {
      r = parse_record_expr(p, start, r);
      continue;
    }
    break;
  }
  leave(p);
  return r;
}

static WokNode *parse_app(P *p) {
  if (!enter(p)) return mk_err(p);
  u32 start = cur(p)->off;
  WokNode *r;
  if (at(p, WT_VARSYM)) {
    // In operand position the only prefix operator is `-` (D-LEX-1): negation
    // is never glued to its literal, so this needs no text compare.
    bump(p);
    WokNode *body = parse_app(p);
    r = mk(p, E_Neg, start, span_end(p));
    E_Neg_set_body(r, body);
  } else {
    r = parse_atom(p);
    while (starts_atom(p) && !p->panic) {
      WokNode *arg = parse_atom(p);
      WokNode *app = mk(p, E_App, start, span_end(p));
      E_App_set_fn(app, r);
      E_App_set_arg(app, arg);
      r = app;
    }
  }
  leave(p);
  return r;
}

static WokNode *parse_chain(P *p) {
  u32 start = cur(p)->off;
  WokNode *head = parse_app(p);
  WokNodeBuf ops;
  wok_buf_init(&ops, p->a);
  while (at_infixop(p) && !p->panic) {
    u32 ostart = cur(p)->off;
    WokSpan name;
    bool backtick = false;
    if (at(p, WT_BACKTICK)) {
      bump(p);
      name = tok_span(cur(p));
      backtick = true;
      bump(p);
      expect(p, WT_BACKTICK, "a closing backtick");
    } else {
      name = tok_span(cur(p));
      bump(p);
    }
    WokNode *rhs = parse_app(p);
    WokNode *op = mk(p, H_ChainOp, ostart, span_end(p));
    H_ChainOp_set_op(op, name);
    H_ChainOp_set_backtick(op, backtick);
    H_ChainOp_set_rhs(op, rhs);
    wok_buf_push(&ops, op);
  }
  if (wok_buf_count(&ops) == 0) return head;
  WokNode *n = mk(p, E_Chain, start, span_end(p));
  E_Chain_set_head(n, head);
  E_Chain_set_ops(n, wok_buf_seq(&ops));
  return n;
}

static WokNode *parse_lambda(P *p) {
  u32 start = cur(p)->off;
  bump(p);  // `\`
  WokNodeBuf params;
  wok_buf_init(&params, p->a);
  while (starts_atompat(p) && !p->panic)
    wok_buf_push(&params, parse_atompat(p));
  expect(p, WT_ARROW, "`->` after the lambda's parameters");
  WokNode *body = parse_body(p);
  WokNode *n = mk(p, E_Lambda, start, span_end(p));
  E_Lambda_set_params(n, wok_buf_seq(&params));
  E_Lambda_set_body(n, body);
  return n;
}

static WokNode *parse_if(P *p) {
  u32 start = cur(p)->off;
  bump(p);  // `if`
  WokNode *cond = parse_expr(p);
  expect_word(p, WW_THEN, "`then` after the condition");
  WokNode *then_ = parse_body(p);
  expect_word(p, WW_ELSE, "`else` after the `then` branch");
  WokNode *else_ = parse_body(p);
  WokNode *n = mk(p, E_If, start, span_end(p));
  E_If_set_cond(n, cond);
  E_If_set_then_(n, then_);
  E_If_set_else_(n, else_);
  return n;
}

static WokNode *parse_case(P *p) {
  u32 start = cur(p)->off;
  bump(p);  // `case`
  WokNode *scrut = parse_expr(p);
  expect_word(p, WW_OF, "`of` after the scrutinee");
  Block b = block_begin(p);
  WokSeq alts = parse_block_list(p, &b, parse_alt, false);
  block_end(p, &b);
  WokNode *n = mk(p, E_Case, start, span_end(p));
  E_Case_set_scrut(n, scrut);
  E_Case_set_alts(n, alts);
  return n;
}

static WokNode *parse_handler(P *p) {
  u32 start = cur(p)->off;
  bump(p);  // `handler`
  // `handler E` names its effect MANDATORILY (C3).
  WokSpan effect = take_kind(p, WT_CONID, "the effect this handler handles");
  Block b = block_begin(p);
  WokSeq clauses = parse_block_list(p, &b, parse_clause, false);
  block_end(p, &b);
  WokNode *n = mk(p, E_Handler, start, span_end(p));
  E_Handler_set_effect(n, effect);
  E_Handler_set_clauses(n, clauses);
  return n;
}

static WokSeq parse_usebinds(P *p) {
  WokNodeBuf buf;
  wok_buf_init(&buf, p->a);
  for (;;) {
    u32 start = cur(p)->off;
    WokSpan from = take_any_name(p, "the label to bridge from");
    expect_word(p, WW_AS, "`as` between the two labels");
    WokSpan to = take_any_name(p, "the label to bridge to");
    WokNode *n = mk(p, H_UseBind, start, span_end(p));
    H_UseBind_set_from(n, from);
    H_UseBind_set_to(n, to);
    wok_buf_push(&buf, n);
    if (p->panic || !at(p, WT_COMMA)) break;
    bump(p);
  }
  return wok_buf_seq(&buf);
}

// A label is written only when a name is immediately followed by `=`.
static bool at_handle_label(const P *p) {
  return (at(p, WT_VARID) || at(p, WT_CONID)) && kind_at(p, 1) == WT_EQUALS;
}

static WokNode *parse_expr(P *p) {
  if (!enter(p)) return mk_err(p);
  u32 start = cur(p)->off;
  WokNode *r;
  if (at(p, WT_LAMBDA)) {
    r = parse_lambda(p);
  } else if (at_word(p, WW_LET)) {
    bump(p);
    WokNode *bind = parse_bind(p);
    expect_word(p, WW_IN, "`in` after this binding");
    WokNode *body = parse_body(p);
    r = mk(p, E_LetIn, start, span_end(p));
    E_LetIn_set_bind(r, bind);
    E_LetIn_set_body(r, body);
  } else if (at_word(p, WW_HANDLE)) {
    bump(p);
    // The delimited inline form MAY elide the label (D13 two-tier); the
    // default is then read off the handler's type.
    WokSpan label = wok_span(start, 0);
    if (at_handle_label(p)) {
      label = tok_span(cur(p));
      bump(p);
      bump(p);
    }
    WokNode *handler = parse_expr(p);
    expect_word(p, WW_IN, "`in` after the handler of this `handle`");
    WokNode *body = parse_body(p);
    r = mk(p, E_HandleIn, start, span_end(p));
    E_HandleIn_set_label(r, label);
    E_HandleIn_set_handler(r, handler);
    E_HandleIn_set_body(r, body);
  } else if (at_word(p, WW_USE)) {
    bump(p);
    WokSeq binds = parse_usebinds(p);
    expect_word(p, WW_IN, "`in` after these bridges");
    WokNode *body = parse_body(p);
    r = mk(p, E_UseIn, start, span_end(p));
    E_UseIn_set_binds(r, binds);
    E_UseIn_set_body(r, body);
  } else if (at_word(p, WW_IF)) {
    r = parse_if(p);
  } else if (at_word(p, WW_CASE)) {
    r = parse_case(p);
  } else if (at_word(p, WW_HANDLER)) {
    r = parse_handler(p);
  } else {
    r = parse_chain(p);
    if (at(p, WT_ASSIGN)) {
      bump(p);
      WokNode *value = parse_body(p);
      WokNode *asn = mk(p, E_Assign, start, span_end(p));
      E_Assign_set_target(asn, r);
      E_Assign_set_value(asn, value);
      r = asn;
    }
  }
  leave(p);
  return r;
}

// --------------------------------------------------------------- statements

static WokNode *parse_bind(P *p) {
  u32 start = cur(p)->off;
  WokNode *lhs;
  if (at(p, WT_VARID)) {
    const WokToken *t = cur(p);
    bump(p);
    WokNodeBuf args;
    wok_buf_init(&args, p->a);
    while (starts_atompat(p) && !p->panic)
      wok_buf_push(&args, parse_atompat(p));
    lhs = mk(p, L_Prefix, start, span_end(p));
    L_Prefix_set_name(lhs, tok_span(t));
    L_Prefix_set_paren(lhs, false);
    L_Prefix_set_args(lhs, wok_buf_seq(&args));
  } else {
    lhs = parse_pat(p);
  }
  expect(p, WT_EQUALS, "`=` in this binding");
  WokNode *body = parse_body(p);
  WokNode *n = mk(p, H_Bind, start, span_end(p));
  H_Bind_set_lhs(n, lhs);
  H_Bind_set_body(n, body);
  return n;
}

static WokNode *parse_stmt(P *p) {
  if (!enter(p)) return mk_err(p);
  u32 start = cur(p)->off;
  const WokToken *lead = cur(p);
  WokNode *r;
  if (at_word(p, WW_LET)) {
    bump(p);
    WokNode *bind = parse_bind(p);
    // `in` is a continuation lead, so it arrives with no NEWLINE before it:
    // after the binding, simply look at the current token.
    if (at_word(p, WW_IN)) {
      bump(p);
      WokNode *body = parse_body(p);
      r = mk(p, E_LetIn, start, span_end(p));
      E_LetIn_set_bind(r, bind);
      E_LetIn_set_body(r, body);
    } else {
      r = mk(p, S_Let, start, span_end(p));
      S_Let_set_bind(r, bind);
    }
  } else if (at_word(p, WW_HANDLE)) {
    bump(p);
    WokSpan label = wok_span(start, 0);
    bool has_label = at_handle_label(p);
    if (has_label) {
      label = tok_span(cur(p));
      bump(p);
      bump(p);
    }
    WokNode *handler = parse_expr(p);
    if (at_word(p, WW_IN)) {
      bump(p);
      WokNode *body = parse_body(p);
      r = mk(p, E_HandleIn, start, span_end(p));
      E_HandleIn_set_label(r, label);
      E_HandleIn_set_handler(r, handler);
      E_HandleIn_set_body(r, body);
    } else {
      if (!has_label)
        perr_form(p, WOK_E_HANDLE_LABEL, lead,
                  "a `handle` statement must name the label it binds: write "
                  "`handle <label> = <handler>`");
      r = mk(p, S_Handle, start, span_end(p));
      S_Handle_set_label(r, label);
      S_Handle_set_handler(r, handler);
    }
  } else if (at_word(p, WW_USE)) {
    bump(p);
    WokSeq binds = parse_usebinds(p);
    if (at_word(p, WW_IN)) {
      bump(p);
      WokNode *body = parse_body(p);
      r = mk(p, E_UseIn, start, span_end(p));
      E_UseIn_set_binds(r, binds);
      E_UseIn_set_body(r, body);
    } else {
      r = mk(p, S_Use, start, span_end(p));
      S_Use_set_binds(r, binds);
    }
  } else if (at(p, WT_UNDERSCORE) && kind_at(p, 1) == WT_EQUALS) {
    bump(p);
    bump(p);
    WokNode *body = parse_body(p);
    r = mk(p, S_Discard, start, span_end(p));
    S_Discard_set_body(r, body);
  } else {
    r = parse_expr(p);
  }
  leave(p);
  return r;
}

static WokNode *parse_alt(P *p) {
  u32 start = cur(p)->off;
  WokNode *pat = parse_pat(p);
  expect(p, WT_ARROW, "`->` after the pattern of this alternative");
  Block b = block_begin(p);
  WokNode *body = parse_block_body(p, &b);
  WokSeq wheres = wok_seq_empty();
  if (at_word(p, WW_WHERE)) wheres = parse_where(p);
  block_end(p, &b);
  WokNode *n = mk(p, H_Alt, start, span_end(p));
  H_Alt_set_pat(n, pat);
  H_Alt_set_body(n, body);
  H_Alt_set_wheres(n, wheres);
  return n;
}

// ------------------------------------------------------------ handler clause

static WokNode *parse_clause(P *p) {
  u32 start = cur(p)->off;
  u64 kind = WOK_CLAUSE_PLAIN;
  WokSpan name = wok_span(start, 0);
  WokSpan k = wok_span(start, 0);
  WokNodeBuf pats;
  wok_buf_init(&pats, p->a);
  WokNode *body = nullptr;

  if (at_word(p, WW_VAR)) {
    bump(p);
    kind = WOK_CLAUSE_VAR;
    name = take_kind(p, WT_VARID, "the baton's name after `var`");
    expect(p, WT_EQUALS, "`=` after the baton's name");
    body = parse_body(p);
  } else if (at_word(p, WW_RETURN)) {
    bump(p);
    kind = WOK_CLAUSE_RETURN;
    wok_buf_push(&pats, parse_pat(p));
    expect(p, WT_ARROW, "`->` after the return clause's pattern");
    body = parse_body(p);
  } else if (at_word(p, WW_ONCE)) {
    bump(p);
    kind = WOK_CLAUSE_ONCE;
    name = take_kind(p, WT_VARID, "the operation's name after `once`");
    WokNodeBuf all;
    wok_buf_init(&all, p->a);
    while (starts_atompat(p) && !p->panic) wok_buf_push(&all, parse_atompat(p));
    // D14: the LAST binder IS the continuation, and it must be a plain
    // lowercase name -- anything else is unwritable rather than reinterpreted.
    if (wok_buf_count(&all) == 0 || wok_buf_at(&all, wok_buf_count(&all) - 1)->tag != P_Var) {
      perr_form(p, WOK_E_ONCE_BINDER, cur(p),
                "the last binder of a `once` clause is its continuation and "
                "must be a plain lowercase name");
      for (u32 j = 0; j < wok_buf_count(&all); j++) wok_buf_push(&pats, wok_buf_at(&all, j));
    } else {
      k = P_Var_name(wok_buf_at(&all, wok_buf_count(&all) - 1));
      for (u32 j = 0; j + 1 < wok_buf_count(&all); j++)
        wok_buf_push(&pats, wok_buf_at(&all, j));
    }
    expect(p, WT_ARROW, "`->` after the clause's binders");
    body = parse_body(p);
  } else {
    name = take_kind(p, WT_VARID, "an operation name");
    while (starts_atompat(p) && !p->panic)
      wok_buf_push(&pats, parse_atompat(p));
    expect(p, WT_ARROW, "`->` after the clause's patterns");
    body = parse_body(p);
  }

  WokNode *n = mk(p, H_Clause, start, span_end(p));
  H_Clause_set_kind(n, kind);
  H_Clause_set_name(n, name);
  H_Clause_set_pats(n, wok_buf_seq(&pats));
  H_Clause_set_k(n, k);
  H_Clause_set_body(n, body ? body : mk_err(p));
  return n;
}

// -------------------------------------------------------------- declarations

static WokNode *parse_typaram(P *p) {
  u32 start = cur(p)->off;
  bool is_row = false;
  WokSpan name;
  if (at(p, WT_LPAREN)) {
    bump(p);
    expect_word(p, WW_ROW, "`row` inside this parameter");
    name = take_kind(p, WT_VARID, "a row-variable name");
    expect(p, WT_RPAREN, "`)` to close this row parameter");
    is_row = true;
  } else {
    name = take_kind(p, WT_VARID, "a type parameter");
  }
  WokNode *n = mk(p, H_TyParam, start, span_end(p));
  H_TyParam_set_name(n, name);
  H_TyParam_set_is_row(n, is_row);
  return n;
}

static WokSeq parse_typarams(P *p) {
  WokNodeBuf buf;
  wok_buf_init(&buf, p->a);
  while (starts_typaram(p) && !p->panic) wok_buf_push(&buf, parse_typaram(p));
  return wok_buf_seq(&buf);
}

static WokNode *parse_fieldtype(P *p) {
  u32 start = cur(p)->off;
  WokSpan name = take_kind(p, WT_VARID, "a field name");
  expect(p, WT_COLON, "`:` after the field name");
  WokNode *type = parse_type(p);
  WokNode *n = mk(p, H_FieldType, start, span_end(p));
  H_FieldType_set_name(n, name);
  H_FieldType_set_type(n, type);
  return n;
}

static WokSeq parse_fieldtypes(P *p) {
  bump(p);  // `{`
  WokNodeBuf buf;
  wok_buf_init(&buf, p->a);
  if (!at(p, WT_RBRACE) && !p->panic) {
    wok_buf_push(&buf, parse_fieldtype(p));
    while (at(p, WT_COMMA) && !p->panic) {
      bump(p);
      wok_buf_push(&buf, parse_fieldtype(p));
    }
  }
  expect(p, WT_RBRACE, "`}` to close these fields");
  return wok_buf_seq(&buf);
}

static WokNode *parse_condef(P *p) {
  u32 start = cur(p)->off;
  WokSpan name = wok_span(start, 0);
  WokSeq args = wok_seq_empty();
  WokSeq fields = wok_seq_empty();
  bool is_record = false;
  if (at(p, WT_LBRACE)) {
    // The elided record form: `type Wrapped = { value : U64 }`.
    fields = parse_fieldtypes(p);
    is_record = true;
  } else {
    name = take_kind(p, WT_CONID, "a constructor name");
    if (at(p, WT_LBRACE)) {
      fields = parse_fieldtypes(p);
      is_record = true;
    } else {
      WokNodeBuf buf;
      wok_buf_init(&buf, p->a);
      while (starts_atomtype(p) && !p->panic)
        wok_buf_push(&buf, parse_atomtype(p));
      args = wok_buf_seq(&buf);
    }
  }
  WokNode *n = mk(p, H_ConDef, start, span_end(p));
  H_ConDef_set_name(n, name);
  H_ConDef_set_args(n, args);
  H_ConDef_set_fields(n, fields);
  H_ConDef_set_is_record(n, is_record);
  return n;
}

static WokNode *parse_signame(P *p) {
  u32 start = cur(p)->off;
  bool paren = false;
  WokSpan name;
  if (at(p, WT_LPAREN)) {
    bump(p);
    name = take_kind(p, WT_VARSYM, "an operator name");
    expect(p, WT_RPAREN, "`)` after the operator name");
    paren = true;
  } else {
    name = take_kind(p, WT_VARID, "a name being declared");
  }
  WokNode *n = mk(p, H_SigName, start, span_end(p));
  H_SigName_set_name(n, name);
  H_SigName_set_paren(n, paren);
  return n;
}

static WokNode *parse_sig(P *p, bool is_extern, u32 start) {
  WokNodeBuf names;
  wok_buf_init(&names, p->a);
  wok_buf_push(&names, parse_signame(p));
  while (at(p, WT_COMMA) && !p->panic) {
    bump(p);
    wok_buf_push(&names, parse_signame(p));
  }
  expect(p, WT_COLON, "`:` between the names and their type");
  WokNode *type = parse_type(p);
  WokNode *n = mk(p, D_Sig, start, span_end(p));
  D_Sig_set_names(n, wok_buf_seq(&names));
  D_Sig_set_type(n, type);
  D_Sig_set_is_extern(n, is_extern);
  return n;
}

static WokNode *parse_lhs(P *p) {
  u32 start = cur(p)->off;
  bool paren = at(p, WT_LPAREN) && kind_at(p, 1) == WT_VARSYM &&
               kind_at(p, 2) == WT_RPAREN;
  bool prefix = at(p, WT_VARID) && kind_at(p, 1) != WT_VARSYM &&
                kind_at(p, 1) != WT_BACKTICK;
  if (paren || prefix) {
    WokSpan name;
    if (paren) {
      bump(p);
      name = tok_span(cur(p));
      bump(p);
      bump(p);
    } else {
      name = tok_span(cur(p));
      bump(p);
    }
    WokNodeBuf args;
    wok_buf_init(&args, p->a);
    while (starts_atompat(p) && !p->panic)
      wok_buf_push(&args, parse_atompat(p));
    WokNode *n = mk(p, L_Prefix, start, span_end(p));
    L_Prefix_set_name(n, name);
    L_Prefix_set_paren(n, paren);
    L_Prefix_set_args(n, wok_buf_seq(&args));
    return n;
  }
  WokNode *left = parse_atompat(p);
  WokSpan op = wok_span(cur(p)->off, 0);
  bool backtick = false;
  if (at(p, WT_BACKTICK)) {
    bump(p);
    op = tok_span(cur(p));
    backtick = true;
    bump(p);
    expect(p, WT_BACKTICK, "a closing backtick");
  } else if (at(p, WT_VARSYM)) {
    op = tok_span(cur(p));
    bump(p);
  } else {
    perr_expect(p, "an infix operator in this left-hand side");
  }
  WokNode *right = parse_atompat(p);
  WokNode *n = mk(p, L_Infix, start, span_end(p));
  L_Infix_set_left(n, left);
  L_Infix_set_op(n, op);
  L_Infix_set_backtick(n, backtick);
  L_Infix_set_right(n, right);
  return n;
}

static WokNode *parse_equation(P *p) {
  u32 start = cur(p)->off;
  WokNode *lhs = parse_lhs(p);
  expect(p, WT_EQUALS, "`=` after the left-hand side");
  Block b = block_begin(p);
  WokNode *body = parse_block_body(p, &b);
  // `where` is a continuation lead, so it arrives inside the body's block
  // region with no separator before it.
  WokSeq wheres = wok_seq_empty();
  if (at_word(p, WW_WHERE)) wheres = parse_where(p);
  block_end(p, &b);
  WokNode *n = mk(p, D_Equation, start, span_end(p));
  D_Equation_set_lhs(n, lhs);
  D_Equation_set_body(n, body);
  D_Equation_set_wheres(n, wheres);
  return n;
}

// `:` before `=` at bracket depth zero is the only thing that separates a
// signature from an equation, and forward-only declarations (D23) guarantee
// one of the two appears on the item's first logical line.
static bool item_is_sig(const P *p) {
  int br = 0;
  for (usize j = p->i; j < p->n; j++) {
    WokKind k = (WokKind)p->tok[j].kind;
    if (br == 0) {
      if (k == WT_NEWLINE || k == WT_INDENT || k == WT_DEDENT || k == WT_EOF)
        return false;
      if (k == WT_COLON) return true;
      if (k == WT_EQUALS) return false;
    }
    if (wok_kind_is_open_bracket(k))
      br++;
    else if (wok_kind_is_close_bracket(k) && br > 0)
      br--;
  }
  return false;
}

static WokNode *parse_sig_or_equation(P *p) {
  u32 start = cur(p)->off;
  if (item_is_sig(p)) return parse_sig(p, false, start);
  return parse_equation(p);
}

static WokNode *parse_module_decl(P *p) {
  u32 start = cur(p)->off;
  bump(p);
  WokNode *path = parse_modpath(p);
  WokNode *n = mk(p, D_Module, start, span_end(p));
  D_Module_set_path(n, path);
  return n;
}

static WokNode *parse_import_decl(P *p) {
  u32 start = cur(p)->off;
  bump(p);
  WokNode *path = parse_modpath(p);
  WokNodeBuf names;
  wok_buf_init(&names, p->a);
  if (at(p, WT_LPAREN)) {
    bump(p);
    if (!at(p, WT_RPAREN) && !p->panic) {
      wok_buf_push(&names, parse_name(p));
      while (at(p, WT_COMMA) && !p->panic) {
        bump(p);
        wok_buf_push(&names, parse_name(p));
      }
    }
    expect(p, WT_RPAREN, "`)` to close the import list");
  }
  WokNode *alias = nullptr;
  if (at_word(p, WW_AS)) {
    bump(p);
    alias = parse_name(p);
  }
  WokNode *n = mk(p, D_Import, start, span_end(p));
  D_Import_set_path(n, path);
  D_Import_set_names(n, wok_buf_seq(&names));
  D_Import_set_alias(n, alias);
  return n;
}

static WokNode *parse_type_decl(P *p) {
  u32 start = cur(p)->off;
  bump(p);
  WokSpan name = take_kind(p, WT_CONID, "a type name");
  WokSeq params = parse_typarams(p);
  expect(p, WT_EQUALS, "`=` before the constructors");
  WokNodeBuf cons;
  wok_buf_init(&cons, p->a);
  wok_buf_push(&cons, parse_condef(p));
  while (at(p, WT_BAR) && !p->panic) {
    bump(p);
    wok_buf_push(&cons, parse_condef(p));
  }
  WokNode *n = mk(p, D_Type, start, span_end(p));
  D_Type_set_name(n, name);
  D_Type_set_params(n, params);
  D_Type_set_cons(n, wok_buf_seq(&cons));
  return n;
}

static WokNode *parse_alias_decl(P *p) {
  u32 start = cur(p)->off;
  bump(p);
  WokSpan name = take_kind(p, WT_CONID, "an alias name");
  WokSeq params = parse_typarams(p);
  expect(p, WT_EQUALS, "`=` before the aliased type");
  WokNode *body = parse_type(p);
  WokNode *n = mk(p, D_Alias, start, span_end(p));
  D_Alias_set_name(n, name);
  D_Alias_set_params(n, params);
  D_Alias_set_body(n, body);
  return n;
}

static WokNode *parse_opsig(P *p) {
  u32 start = cur(p)->off;
  WokSpan name = take_kind(p, WT_VARID, "an operation name");
  expect(p, WT_COLON, "`:` after the operation name");
  WokNode *type = parse_type(p);
  WokNode *n = mk(p, H_OpSig, start, span_end(p));
  H_OpSig_set_name(n, name);
  H_OpSig_set_type(n, type);
  return n;
}

static WokNode *parse_effect_decl(P *p) {
  u32 start = cur(p)->off;
  bump(p);
  WokSpan name = take_kind(p, WT_CONID, "an effect name");
  WokSeq params = parse_typarams(p);
  Block b = block_begin(p);
  WokSeq ops = parse_block_list(p, &b, parse_opsig, true);
  block_end(p, &b);
  WokNode *n = mk(p, D_Effect, start, span_end(p));
  D_Effect_set_name(n, name);
  D_Effect_set_params(n, params);
  D_Effect_set_ops(n, ops);
  return n;
}

static WokNode *parse_class_decl(P *p) {
  u32 start = cur(p)->off;
  bump(p);
  WokSpan name = take_kind(p, WT_CONID, "a class name");
  WokSeq params = parse_typarams(p);
  Block b = block_begin(p);
  WokSeq body = parse_block_list(p, &b, parse_sig_or_equation, true);
  block_end(p, &b);
  WokNode *n = mk(p, D_Class, start, span_end(p));
  D_Class_set_name(n, name);
  D_Class_set_params(n, params);
  D_Class_set_body(n, body);
  return n;
}

static WokNode *parse_instance_decl(P *p) {
  u32 start = cur(p)->off;
  bump(p);
  WokNode *ctx = nullptr;
  if (at(p, WT_LPAREN)) {
    bump(p);
    ctx = parse_type(p);
    expect(p, WT_RPAREN, "`)` to close the instance context");
    expect(p, WT_FATARROW, "`=>` after the instance context");
  }
  WokSpan name = take_kind(p, WT_CONID, "a class name");
  WokNodeBuf args;
  wok_buf_init(&args, p->a);
  while (starts_atomtype(p) && !p->panic)
    wok_buf_push(&args, parse_atomtype(p));
  Block b = block_begin(p);
  WokSeq body = parse_block_list(p, &b, parse_sig_or_equation, true);
  block_end(p, &b);
  WokNode *n = mk(p, D_Instance, start, span_end(p));
  D_Instance_set_ctx(n, ctx);
  D_Instance_set_name(n, name);
  D_Instance_set_args(n, wok_buf_seq(&args));
  D_Instance_set_body(n, body);
  return n;
}

static WokNode *parse_foreign_member(P *p) {
  u32 start = cur(p)->off;
  WokSpan name = take_kind(p, WT_VARID, "a foreign member name");
  WokSpan symbol = wok_span(start, 0);
  if (at(p, WT_STRING)) {
    symbol = tok_span(cur(p));
    bump(p);
  }
  expect(p, WT_COLON, "`:` after the foreign member name");
  bool saved = p->foreign_sig;
  p->foreign_sig = true;
  WokNode *type = parse_type(p);
  p->foreign_sig = saved;
  WokNode *n = mk(p, H_ForeignMember, start, span_end(p));
  H_ForeignMember_set_name(n, name);
  H_ForeignMember_set_symbol(n, symbol);
  H_ForeignMember_set_type(n, type);
  return n;
}

static WokNode *parse_foreign_decl(P *p) {
  u32 start = cur(p)->off;
  bump(p);  // `foreign`
  expect_word(p, WW_MODULE, "`module` after `foreign`");
  WokSpan name = take_kind(p, WT_CONID, "the foreign module's name");
  WokSpan lib = take_kind(p, WT_STRING, "the library name as a string");
  Block b = block_begin(p);
  WokSeq members = parse_block_list(p, &b, parse_foreign_member, true);
  block_end(p, &b);
  WokNode *n = mk(p, D_Foreign, start, span_end(p));
  D_Foreign_set_name(n, name);
  D_Foreign_set_lib(n, lib);
  D_Foreign_set_members(n, members);
  return n;
}

static WokNode *parse_extern_decl(P *p) {
  u32 start = cur(p)->off;
  bump(p);  // `extern`
  if (at_word(p, WW_TYPE)) {
    bump(p);
    WokSpan name = take_kind(p, WT_CONID, "a type name");
    WokSeq params = parse_typarams(p);
    WokNode *n = mk(p, D_ExternType, start, span_end(p));
    D_ExternType_set_name(n, name);
    D_ExternType_set_params(n, params);
    return n;
  }
  // `extern` marks a compiler hole: analyses trust the MARKER, never a name.
  return parse_sig(p, true, start);
}

static WokNode *parse_decl(P *p) {
  if (!enter(p)) return mk_error(p, D_Error, cur(p)->off);
  WokNode *r;
  if (at(p, WT_KEYWORD)) {
    WokWord w = (WokWord)cur(p)->word;
    if (w == WW_MODULE)
      r = parse_module_decl(p);
    else if (w == WW_IMPORT)
      r = parse_import_decl(p);
    else if (w == WW_TYPE)
      r = parse_type_decl(p);
    else if (w == WW_ALIAS)
      r = parse_alias_decl(p);
    else if (w == WW_EFFECT)
      r = parse_effect_decl(p);
    else if (w == WW_CLASS)
      r = parse_class_decl(p);
    else if (w == WW_INSTANCE)
      r = parse_instance_decl(p);
    else if (w == WW_FOREIGN)
      r = parse_foreign_decl(p);
    else if (w == WW_EXTERN)
      r = parse_extern_decl(p);
    else {
      perr_expect(p, "a declaration");
      r = mk_error(p, D_Error, cur(p)->off);
    }
  } else {
    r = parse_sig_or_equation(p);
  }
  leave(p);
  return r;
}

// ---------------------------------------------------------------- the file

static WokNode *parse_file(P *p) {
  WokNodeBuf decls;
  wok_buf_init(&decls, p->a);
  while (!at(p, WT_EOF)) {
    if (at(p, WT_NEWLINE) || at(p, WT_DEDENT)) {
      bump(p);
      continue;
    }
    usize before = p->i;
    u32 start = cur(p)->off;
    WokNode *decl = parse_decl(p);
    if (p->panic) {
      resync_decl(p);
      decl = mk_error(p, D_Error, start);
      p->panic = false;
    }
    wok_buf_push(&decls, decl);
    if (p->sep) {
      p->sep = false;
    } else if (at(p, WT_NEWLINE)) {
      bump(p);
    } else if (!at(p, WT_EOF)) {
      perr_expect(p, "the end of this declaration");
      resync_decl(p);
      p->panic = false;
      p->sep = false;
      if (at(p, WT_NEWLINE)) bump(p);
    }
    if (p->i == before && !at(p, WT_EOF)) bump(p);
  }
  WokNode *n = mk(p, W_File, 0, span_end(p));
  W_File_set_decls(n, wok_buf_seq(&decls));
  return n;
}

WokNode *wok_parse(WokTokens tokens, const char *src, WokArena *arena,
                   WokDiagSink *diag) {
  P p = {.tok = tokens.tok,
         .n = tokens.n,
         .i = 0,
         .src = src,
         .a = arena,
         .d = diag};
  return parse_file(&p);
}

WokNode *wok_parse_source(const char *src, usize src_len, WokArena *arena,
                          WokDiagSink *diag) {
  WokScanResult scanned = wok_scan(src, src_len, arena, diag);
  WokTokens laid_out = wok_layout(scanned.tokens, arena, diag);
  WokNode *file = wok_parse(laid_out, src, arena, diag);
  // The comments the scanner set aside become trivia here, and nowhere else:
  // a tree that never went through this entry point simply has none.
  (void)wok_trivia_attach(file, src, src_len, scanned.comments,
                          scanned.ncomments, arena);
  return file;
}
