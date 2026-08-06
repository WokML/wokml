// wok_print -- see wok_print.h for the contract and the canonical decisions.
//
// The printer INVERTS wok_parse.c production by production, so its three
// precedence ladders are copies of that file's call graph, not a second
// opinion about it:
//
//   type > arrow > typeapp > atomtype
//   expr > chain  > app     > atom
//   pat  > patapp > atompat
//
// Two facts about the language shape everything here.
//
// FACT ONE: a block is opened by COLUMN, so only the LAST thing on a line
// may open one. Every construct with a continuation lead after a body
// (`in`, `then`, `else`, `where`) therefore has two shapes, and which one is
// used is decided by opens_block() on the part that precedes the lead --
// never by a width budget.
//
// FACT TWO: inside brackets layout is suspended (L2), so a newline emitted
// there produces NO layout token and a block written there would silently
// flatten. `flat` marks that region: within it no BLOCK may be opened.
// Since the parser cannot BUILD an indented block inside brackets either,
// the two restrictions match exactly, and a tree that violates this could
// not have come from a parse. A FILL break is a different thing and is legal
// there -- see "line filling" below.
//
// FACT THREE, which decides the whole of line filling: a line break CHANGES
// THE PARSE. A new line whose first token is an ITEM LEAD either starts a new
// block item (the tree silently changed) or is rejected outright for being
// deeper than its block. Only two breaks are safe, and the filler makes no
// others:
//
//   * immediately before a CONTINUATION LEAD, which L4 answers with DEDENTs
//     and no separator, so the logical line continues; and
//   * anywhere inside a bracket group, where L2 suspends layout entirely.
//
// Application juxtaposition owns no separator, so it cannot be broken and a
// long application stays long. Manufacturing a break point by adding
// parentheses is deliberately NOT done: punctuation the author did not write
// is a worse trade than one long line.

#include "wok_print.h"

#include <inttypes.h>
#include <stdint.h>
#include <string.h>

#include "wok_base.h"
#include "wok_token.h"
#include "wok_trivia.h"

// ------------------------------------------------------------------- sink
//
// One algorithm, three destinations: a FILE, an arena-backed growable
// buffer, and a MEASURE-ONLY sink. The third is what alignment needs: the
// width of every head in a block must be known before the first head is
// written, and re-rendering into a counter is cheaper than teaching every
// head printer to report its own width.

typedef struct {
  bool to_file;
  bool count_only;
  FILE *file;
  WokArena *arena;
  char *buf;
  usize len, cap;

  const char *src;
  const char *path;     // named in an overflow report; null means <input>
  const WokTrivia *tv;  // the comments, or null for a tree that has none
  usize cols;  // columns written on the current line, in codepoints
  u32 depth;
  bool quiet;  // measuring: a fault is reported by the real pass, not twice

  // ---- line filling ----
  bool nofill;      // measuring a flat width: never introduce a break
  bool nl_seen;     // a line was broken during the measurement
  bool check_lead;  // the next byte written opens a FILL line
  u32 line;         // 1-based output line, for the overflow report
  bool line_over;     // this line has already crossed the width
  bool in_comment;    // writing a comment, which is copied verbatim
  bool over_comment;  // the crossing happened inside one
  u16 over_tag;  // the construct blamed for that crossing

  // The open block columns, innermost last. A block is the ONLY thing that
  // may hold items at a column of its own, so this is the whole of what the
  // safety property compares against.
  u16 blk[WOK_PRINT_BLOCK_MAX];
  int nblk;

  // The nodes currently being written, outermost first. Read only to NAME
  // the construct in an overflow report.
  u16 tstack[WOK_PRINT_MAX_DEPTH];
  int tn;
} Pr;

// The two latches; see wok_print.h for why they are process-wide.
static unsigned print_faults = 0;
static unsigned print_overflows = 0;
static unsigned print_unprintables = 0;

unsigned wok_print_fault_count(void) { return print_faults; }
unsigned wok_print_overflow_count(void) { return print_overflows; }
unsigned wok_print_unprintable_count(void) { return print_unprintables; }
void wok_print_reports_reset(void) {
  print_faults = 0;
  print_overflows = 0;
  print_unprintables = 0;
}

// A break that would change the tree rather than the text. Counted in every
// build, because a caller about to overwrite a source file has to be able to
// ask whether this happened.
static void fault(Pr *p, const char *what) {
  if (p->count_only) return;
  print_faults++;
  if (p->quiet) return;
  (void)fprintf(stderr, "wok_print: INTERNAL: %s:%d: %s\n",
                p->path ? p->path : "<input>", p->line, what);
}

static void sink_reserve(Pr *p, usize extra) {
  if (p->len + extra <= p->cap) return;
  usize new_cap = p->cap ? p->cap * 2 : 256;
  while (new_cap < p->len + extra) new_cap *= 2;
  char *grown = WOK_NEW_N(p->arena, char, new_cap);
  if (p->len) memcpy(grown, p->buf, p->len);
  p->buf = grown;
  p->cap = new_cap;
}

// THE LEAD TEST, applied to the bytes the filler is about to write. It answers
// the same question wok_token_is_continuation_lead answers about a scanned
// token, for the far smaller set of leads a fill break can produce; test_fill
// pins the two against each other for every one of them, which is what keeps
// this from becoming a second, drifting opinion about the lexis.
//
// The symbol charset itself is NOT restated here -- wok_token.c owns it, and a
// second copy is precisely how `-->` stops being a comment in one of them.
static bool lead_is_continuation(const char *s, usize n) {
  if (n == 0) return false;
  unsigned char c0 = (unsigned char)s[0];
  // Every symbol run scans as an operator, and every operator is a lead. A
  // run of two or more dashes is a COMMENT, whose line produces no token at
  // all (L1), so it is safe on the same side of the answer.
  if (wok_test_is_sym(c0)) return true;
  switch (c0) {
    case ',':
    case '.':
    case '`':
    case ')':
    case ']':
    case '}':
      return true;
    default:
      break;
  }
  // The keywords that can never begin a block item.
  static const char *const words[] = {"with", "in",    "then", "else",
                                      "where", "of",   "as"};
  for (usize k = 0; k < sizeof words / sizeof *words; k++) {
    usize wl = strlen(words[k]);
    if (n < wl || memcmp(s, words[k], wl) != 0) continue;
    // A prefix is not the word: `within` begins an item.
    if (n == wl) return true;
    unsigned char after = (unsigned char)s[wl];
    if (!wok_test_is_ident_cont(after)) return true;
  }
  return false;
}

// The construct an over-width line is blamed on: the innermost node being
// written when the line crossed the width, which for an unbreakable run names
// the long application, literal or identifier directly.
static void blame(Pr *p) {
  p->over_comment = p->in_comment;
  p->over_tag = p->tn > 0 ? p->tstack[p->tn - 1] : (u16)W_File;
}

// Property 2: an overflow is STATED, so a long line reads as a limitation the
// printer names rather than as a formatter bug. It is never an error -- there
// is no other text this tree could have.
static void report_overflow(Pr *p) {
  print_overflows++;
  if (p->quiet) return;
  const char *where = p->path ? p->path : "<input>";
  if (p->over_comment) {
    (void)fprintf(stderr,
                  "wok_print: %s:%d: %zu columns over the %d-column width: a "
                  "comment, which a formatter may move but not rewrite\n",
                  where, p->line, p->cols, WOK_PRINT_WIDTH);
    return;
  }
  (void)fprintf(stderr,
                "wok_print: %s:%d: %zu columns over the %d-column width: an "
                "unbreakable run in %s -- juxtaposition, a literal and a name "
                "own no separator to break at\n",
                where, p->line, p->cols, WOK_PRINT_WIDTH,
                wok_node_desc[p->over_tag].tag);
}

static void put_n(Pr *p, const char *s, usize n) {
  // The first bytes after a fill break must be a continuation lead, or the
  // new line is a new ITEM and the tree just changed. Checked on the bytes
  // themselves rather than on what the caller meant to write.
  if (p->check_lead && n != 0) {
    p->check_lead = false;
    if (!lead_is_continuation(s, n))
      fault(p, "a filled line does not begin with a continuation lead");
  }
  // Columns are counted in codepoints rather than bytes so a non-ASCII
  // literal in a pattern does not skew a block's alignment.
  for (usize i = 0; i < n; i++) {
    unsigned char ch = (unsigned char)s[i];
    if (ch == '\n') {
      p->nl_seen = true;
      if (!p->count_only) {
        if (p->cols > WOK_PRINT_WIDTH) report_overflow(p);
        p->line++;
        p->line_over = false;
      }
      p->cols = 0;
    } else if ((ch & 0xC0u) != 0x80u) {
      p->cols++;
      if (!p->count_only && !p->line_over && p->cols > WOK_PRINT_WIDTH) {
        p->line_over = true;
        blame(p);
      }
    }
  }
  if (p->count_only) return;
  if (p->to_file) {
    (void)fwrite(s, 1, n, p->file);
    return;
  }
  sink_reserve(p, n);
  memcpy(p->buf + p->len, s, n);
  p->len += n;
}

static void put_c(Pr *p, char c) { put_n(p, &c, 1); }

static void put_z(Pr *p, const char *s) { put_n(p, s, strlen(s)); }

static void put_span(Pr *p, WokSpan s) { put_n(p, p->src + s.off, s.len); }

static void put_uint(Pr *p, u64 v) {
  char buf[32];
  int len = snprintf(buf, sizeof buf, "%" PRIu64, v);
  put_n(p, buf, (usize)(len < 0 ? 0 : len));
}

static void put_spaces(Pr *p, usize n) {
  for (usize i = 0; i < n; i++) put_c(p, ' ');
}

// What a new line CLAIMS to be. The layout filter reads that claim off the
// line's first token, so stating it here is what makes it checkable.
typedef enum {
  LN_ITEM,     // a block item: its column must be its block's own column
  LN_LEAD,     // a hanging continuation lead (`in`, `then`, `else`, `where`)
  LN_COMMENT,  // a comment-only line, which produces no token at all (L1)
} LineKind;

// The innermost open block's column, or 0 for the top level, whose items sit
// at column 0 and which no p_seq_block pushes. SIZE_MAX once nesting has
// outrun the tracked depth: a tree that deep cannot have come from a parse
// (the layout filter caps block nesting), and switching the check off is
// better than reporting a violation the printer did not commit.
static usize block_col(const Pr *p) {
  if (p->nblk > WOK_PRINT_BLOCK_MAX) return SIZE_MAX;
  return p->nblk > 0 ? p->blk[p->nblk - 1] : 0;
}

// A line break plus `ind` levels of indentation. With nl_fill below, the ONLY
// place a newline is written, so "never inside brackets" and "an item line
// sits at its block's column" are both properties of these two functions.
static void nl(Pr *p, u32 ind, LineKind kind) {
  // THE SAFETY PROPERTY, first half. An item line at any column but its
  // block's own either opens a block the parser does not expect or starts an
  // item in the wrong one; a continuation lead makes no such claim (L5) and
  // is deliberately allowed to sit shallower, which is how a hanging `in`
  // closes the binding's block.
  usize bc = block_col(p);
  if (kind == LN_ITEM && bc != SIZE_MAX && (usize)ind * 2 != bc)
    fault(p, "a block item is not at its block's column");
  put_c(p, '\n');
  for (u32 i = 0; i < ind; i++) put_n(p, "  ", 2);
}

// A FILL break: a new line at absolute column `col`, whose first token the
// caller writes next. `in_bracket` says layout is suspended here (L2), where
// no column can mean anything; everywhere else the new line must be STRICTLY
// DEEPER than the enclosing block, since a continuation lead at or above that
// column emits DEDENTs (L4) and closes the block early.
static void nl_fill(Pr *p, usize col, bool in_bracket) {
  usize bc = block_col(p);
  if (!in_bracket && bc != SIZE_MAX && col <= bc)
    fault(p, "a filled line is not deeper than its block");
  put_c(p, '\n');
  put_spaces(p, col);
  p->check_lead = true;  // the next bytes written are checked, in put_n
}

static bool is_trailing_blank(char c) {
  return c == ' ' || c == '\t' || c == '\r';
}

// A node the printer cannot render in canonical form. Reported rather than
// silently mangled, and the text that follows is expected to fail to
// re-parse -- exactly like the violation it is reporting.
static void unprintable(Pr *p, const char *what) {
  // Counted BEFORE the quiet check and skipped on a measuring pass, exactly as
  // `fault` is: every node is rendered at least twice, once into a width
  // counter and once for real, so counting on the measuring pass would double
  // every answer.
  if (p->count_only) return;
  print_unprintables++;
  if (p->quiet) return;
  (void)fprintf(stderr, "wok_print: %s cannot be written in canonical form\n",
                what);
}

// ----------------------------------------------------------------- trivia
//
// The comments, put back. wok_trivia decided WHICH item each one belongs to;
// this decides only how it is written, and the whole of that is: a leading
// comment occupies the item's own line at the item's own indentation, and a
// trailing one follows the item after two spaces.
//
// A block comment is emitted VERBATIM, interior line breaks and all. A
// formatter may move a comment; it may not rewrite one.

static const WokTriviaEntry *trivia_of(const Pr *p, const WokNode *n) {
  return wok_trivia_lookup(p->tv, n);
}

static void put_comment(Pr *p, u32 index) {
  const WokComment *c = &p->tv->comment[index];
  // Blanks at the end of a comment are not part of what the author wrote, and
  // leaving them would put trailing whitespace on the line.
  usize len = c->len;
  while (len != 0 && is_trailing_blank(p->src[c->off + len - 1])) len--;
  p->in_comment = true;  // an over-width comment is not an unbreakable RUN
  put_n(p, p->src + c->off, len);
  p->in_comment = false;
}

// The paragraph break and the leading comments of one block item, each on its
// own line at `ind`. The item's own line break is the caller's.
static void p_lead(Pr *p, const WokTriviaEntry *e, u32 ind, bool blank_ok) {
  if (e == nullptr) return;
  if (blank_ok && e->blank_before != 0) put_c(p, '\n');
  for (u32 k = 0; k < e->lead_n; k++) {
    nl(p, ind, LN_COMMENT);
    put_comment(p, e->lead_first + k);
  }
}

// The comment written after an item, on the item's own line. A node whose
// trailing range belongs to a block it CLOSES is skipped here and written by
// p_block_close instead; writing both would print the comment twice.
static void p_trail(Pr *p, const WokNode *n, const WokTriviaEntry *e) {
  if (e == nullptr || wok_trivia_trail_closes_block(n)) return;
  for (u32 k = 0; k < e->trail_n; k++) {
    put_z(p, "  ");
    put_comment(p, e->trail_first + k);
  }
}

// Rule 3: the comments that followed a block's last item, written at that
// block's own indentation.
static void p_block_close(Pr *p, const WokNode *owner, u32 ind) {
  if (owner == nullptr) return;
  const WokTriviaEntry *e = trivia_of(p, owner);
  if (e == nullptr) return;
  for (u32 k = 0; k < e->trail_n; k++) {
    nl(p, ind, LN_COMMENT);
    put_comment(p, e->trail_first + k);
  }
}

// ------------------------------------------------------------- precedence
//
// One ladder per family. The numbers of two families are never compared,
// because a node is only ever asked for the level its own family uses.

enum { TP_TYPE = 0, TP_ARROW = 1, TP_APP = 2, TP_ATOM = 3 };
enum { PP_PAT = 0, PP_APP = 1, PP_ATOM = 2 };
// EP_NEG sits BETWEEN the chain and the application, and it is not cosmetic.
// parse_app has two arms -- `- <the whole application to the right>`, and a
// juxtaposition of atoms -- and they share a rung without being
// interchangeable: a leading `-` SWALLOWS the rest of the rung, so negation is
// legal only at the HEAD of an application spine, never as the function of
// one. On one rung the printer wrote `E_App(E_Neg a, b)` as `-a b`, which
// reads back as `-(a b)`; the split is what asks for the bracket, and it also
// subsumes the hand-written case that used to keep `- -x` from lexing as a
// comment opener.
enum { EP_EXPR = 0, EP_CHAIN = 1, EP_NEG = 2, EP_APP = 3, EP_ATOM = 4 };

// Nodes that occupy no position where re-association is possible. It must be
// at least the top rung of EVERY ladder above, so that a node which cannot
// re-associate is never bracketed wherever it is placed. Inserting a rung and
// forgetting to raise this would put brackets around an N_Name in a module
// path or an H_ChainOp -- where a bracket is SYNTAX, not grouping -- so the
// invariant is asserted rather than described.
enum { PREC_FIXED = 4 };
static_assert(PREC_FIXED >= TP_ATOM && PREC_FIXED >= PP_ATOM &&
                  PREC_FIXED >= EP_ATOM,
              "PREC_FIXED must top every ladder; see the note above");

typedef struct {
  u32 prec;    // the level this position demands
  u32 ind;     // indentation of the line this node's head sits on
  bool flat;   // inside brackets: no BLOCK may be opened here
  bool lead;   // this node writes the FIRST token of its line
  bool brk;    // this node must break EVERY separator it owns
  usize pad;  // arrow alignment target, in columns; 0 for none
  // Columns that will CERTAINLY follow this node on its line: what the
  // unbreakable construct around it still has to write before the next place
  // a break is even possible. "Fits in the columns remaining" means remaining
  // after that, or a group measures itself, fits, and is then pushed over the
  // width by the juxtaposition it sits inside.
  usize rest;
  // The column a wrapped line inside this region takes, or 0 to derive it
  // from `ind`. Set by a bracketed group for its own contents, so a chain
  // wrapped inside a wrapped list lands under that list's items rather than
  // under the enclosing ITEM, where it would read as belonging to neither.
  usize wrap;
} Ctx;

static u32 node_prec(const WokNode *n) {
  switch ((WokTag)n->tag) {
    // Positions where a parenthesis would be meaningless or illegal.
    case N_Name:
    case N_ModPath:
    case D_Module:
    case D_Import:
    case D_Type:
    case D_Alias:
    case D_Effect:
    case D_Class:
    case D_Instance:
    case D_Foreign:
    case D_Fixity:
    case H_FixRel:
    case D_ExternType:
    case D_Sig:
    case D_Equation:
    case D_Error:
    case H_TyParam:
    case H_ConDef:
    case H_FieldType:
    case H_OpSig:
    case H_ForeignMember:
    case H_SigName:
    case L_Prefix:
    case L_Infix:
    case H_RowEntry:
    case H_FieldPat:
    case H_ChainOp:
    case H_Bind:
    case H_UseBind:
    case H_Alt:
    case H_Clause:
    case H_Field:
    case S_Let:
    case S_Handle:
    case S_Use:
    case S_Discard:
    case W_File:
      return PREC_FIXED;

    case T_Var:
    case T_Con:
    case T_List:
    case T_Tuple:
    case T_Unit:
    case T_RowArg:
      return TP_ATOM;
    case T_App:
    case T_Transfer:
      return TP_APP;
    case T_Fun:
      return TP_ARROW;
    case T_Qual:
    case T_With:
      return TP_TYPE;

    case P_Var:
    case P_Wild:
    case P_Int:
    case P_Str:
    case P_Char:
    case P_Tuple:
    case P_List:
    case P_Unit:
    case P_As:
    case P_Record:
      return PP_ATOM;
    // A bare constructor IS an atompat; an applied one is not.
    case P_Con:
      return P_Con_args(n).n != 0 ? PP_APP : PP_ATOM;
    case P_Cons:
      return PP_PAT;

    case E_Var:
    case E_Con:
    case E_Int:
    case E_Str:
    case E_Char:
    case E_Unit:
    case E_OpRef:
    case E_Dot:
    case E_List:
    case E_Tuple:
    case E_Record:
    case E_Error:
      return EP_ATOM;
    case E_App:
      return EP_APP;
    case E_Neg:
      return EP_NEG;
    case E_Chain:
      return EP_CHAIN;
    case E_Lambda:
    case E_LetIn:
    case E_HandleIn:
    case E_UseIn:
    case E_If:
    case E_Case:
    case E_Handler:
    case E_Assign:
    case E_Block:
      return EP_EXPR;

    case WOK_TAG_COUNT:
      break;
  }
  WOK_UNREACHABLE();
}

// Does this node begin with `-`? There are TWO positions where that is misread,
// and only `-` can arise in either: prefix negation, and a negative integer
// pattern.
//
//   1. the first token of a block ITEM. The layout filter reads an operator
//      lead as a CONTINUATION, so the line would join the previous one instead
//      of starting an item. Bracketing it is the repair the corpus already
//      writes by hand (`(-1) -> 2`).
//   2. the first ARGUMENT of a prefix left-hand side. parse_lhs decides
//      prefix-vs-infix on the single token after the name, so `f -1 = 2` is
//      read as the infix equation `f - 1 = 2` -- a different program that
//      still parses. A binding does not need the bracket (parse_bind has no
//      such lookahead), but the printer cannot tell an equation's left-hand
//      side from a binding's, so it writes the safe one for both.
static bool needs_lead_paren(const WokNode *n) {
  if (n->tag == E_Neg) return true;
  return n->tag == P_Int && P_Int_negative(n);
}

// True when writing `n` at indent i leaves the cursor inside an indented
// block, so a following continuation lead (`in`, `then`, `else`, `where`)
// must start a new line shallower than that block. Written as a loop rather
// than a recursion because it descends only the LAST position of a node, and
// the loop cannot outrun the C stack.
static bool opens_block(const WokNode *n) {
  for (int guard = 0; guard < WOK_PRINT_MAX_DEPTH; guard++) {
    switch ((WokTag)n->tag) {
      case E_Block:
      case E_Case:
      case E_Handler:
        return true;
      case E_LetIn:
        n = E_LetIn_body(n);
        break;
      case E_HandleIn:
        n = E_HandleIn_body(n);
        break;
      case E_UseIn:
        n = E_UseIn_body(n);
        break;
      case E_Lambda:
        n = E_Lambda_body(n);
        break;
      case E_If:
        n = E_If_else_(n);
        break;
      case E_Assign:
        n = E_Assign_value(n);
        break;

      case N_Name:
      case N_ModPath:
      case D_Module:
      case D_Import:
      case D_Type:
      case D_Alias:
      case D_Effect:
      case D_Class:
      case D_Instance:
      case D_Foreign:
      case D_Fixity:
      case H_FixRel:
      case D_ExternType:
      case D_Sig:
      case D_Equation:
      case D_Error:
      case H_TyParam:
      case H_ConDef:
      case H_FieldType:
      case H_OpSig:
      case H_ForeignMember:
      case H_SigName:
      case L_Prefix:
      case L_Infix:
      case T_Var:
      case T_Con:
      case T_App:
      case T_Fun:
      case T_Qual:
      case T_With:
      case T_List:
      case T_Tuple:
      case T_Unit:
      case T_RowArg:
      case T_Transfer:
      case H_RowEntry:
      case P_Var:
      case P_Wild:
      case P_Int:
      case P_Str:
      case P_Char:
      case P_Con:
      case P_Cons:
      case P_Tuple:
      case P_List:
      case P_Unit:
      case P_As:
      case P_Record:
      case H_FieldPat:
      case E_Var:
      case E_Con:
      case E_Int:
      case E_Str:
      case E_Char:
      case E_Unit:
      case E_OpRef:
      case E_App:
      case E_Chain:
      case E_Dot:
      case E_Neg:
      case E_List:
      case E_Tuple:
      case E_Record:
      case E_Error:
      case S_Let:
      case S_Handle:
      case S_Use:
      case S_Discard:
      case H_ChainOp:
      case H_Bind:
      case H_UseBind:
      case H_Alt:
      case H_Clause:
      case H_Field:
      case W_File:
      case WOK_TAG_COUNT:
        return false;
    }
  }
  return false;
}

// --------------------------------------------------------------- helpers

static void p_node(Pr *p, const WokNode *n, Ctx c);

// Every child starts with `brk` cleared: a group decides for itself whether it
// fits, so breaking an outer chain does not force an inner list to break.
//
// `rest` is cleared too, and that is exact rather than merely safe wherever a
// GROUP is the parent: if the group fit, everything inside it fit with room
// for the group's own `rest`, and if the group broke, this child is the last
// thing on its line. Only the UNBREAKABLE constructs -- juxtaposition, `.`,
// an arrow head -- have to pass a reserve on, and they say so with sub_rest.
static Ctx sub(Ctx c, u32 prec) {
  c.prec = prec;
  c.lead = false;
  c.brk = false;
  c.pad = 0;
  c.rest = 0;
  return c;
}

// Keeps `lead`: this child writes the first token of the parent's line.
static Ctx lead_sub(Ctx c, u32 prec) {
  c.prec = prec;
  c.brk = false;
  c.pad = 0;
  c.rest = 0;
  return c;
}

static Ctx sub_rest(Ctx c, u32 prec, usize extra) {
  usize keep = c.rest + extra;
  Ctx r = sub(c, prec);
  r.rest = keep;
  return r;
}

static Ctx lead_rest(Ctx c, u32 prec, usize extra) {
  usize keep = c.rest + extra;
  Ctx r = lead_sub(c, prec);
  r.rest = keep;
  return r;
}

// Everything inside a bracket group. Layout is suspended there, so `flat` is
// what stops a BLOCK from being written where it would silently flatten.
static Ctx bracket(Ctx c, u32 prec) {
  c.prec = prec;
  c.flat = true;
  c.lead = false;
  c.brk = false;
  c.pad = 0;
  c.rest = 0;
  return c;
}

static bool span_eq(const Pr *p, WokSpan a, WokSpan b) {
  return a.len == b.len && memcmp(p->src + a.off, p->src + b.off, a.len) == 0;
}

// A signature and the equation it describes are ONE unit to a reader, and
// D23 makes the ordering law. A blank line between them, as "one blank line
// between top-level items" would give, reads as two unrelated declarations.
// Same for a run of imports under a module header.
static bool decls_are_one_unit(const Pr *p, const WokNode *prev,
                               const WokNode *cur) {
  if ((prev->tag == D_Module || prev->tag == D_Import) &&
      (cur->tag == D_Module || cur->tag == D_Import))
    return true;
  // A run of `fixity` lines is one unit for the same reason a run of imports
  // is: each line is a fact about one operator, and the table they build is
  // read as a block. prelude/Base.wok writes twelve of them together.
  if (prev->tag == D_Fixity && cur->tag == D_Fixity) return true;
  if (prev->tag != D_Sig || cur->tag != D_Equation) return false;
  const WokNode *lhs = D_Equation_lhs(cur);
  if (lhs->tag != L_Prefix) return false;  // an infix LHS names no signature
  WokSpan want = L_Prefix_name(lhs);
  WokSeq names = D_Sig_names(prev);
  for (u32 i = 0; i < names.n; i++)
    if (span_eq(p, H_SigName_name(names.items[i]), want)) return true;
  return false;
}

// Backticks are a fact about the operator's SPELLING, not a stored bit: a
// name can only have been written between backticks, a symbol run only bare.
static bool op_is_backticked(const Pr *p, WokSpan op) {
  unsigned char c0 = op.len != 0 ? (unsigned char)p->src[op.off] : '+';
  return (c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z') || c0 == '_' ||
         c0 >= 0x80;
}

static void p_op(Pr *p, WokSpan op) {
  if (op_is_backticked(p, op)) {
    put_c(p, '`');
    put_span(p, op);
    put_c(p, '`');
  } else {
    put_span(p, op);
  }
}

// The columns p_op will write for `op`, backticks included.
static usize op_cols(const Pr *p, WokSpan op) {
  return op.len + (op_is_backticked(p, op) ? 2u : 0u);
}

static void p_list(Pr *p, WokSeq s, Ctx c, const char *sep) {
  for (u32 i = 0; i < s.n; i++) {
    if (i != 0) put_z(p, sep);
    p_node(p, s.items[i], c);
  }
}

// Defined with the filler below; declared here because juxtaposition has to
// tell each argument how much of the line the arguments after it will take.
static usize flat_after(const Pr *p, const WokNode *n, Ctx c);

// Space-separated arguments, each at `prec`. Juxtaposition owns no separator,
// so every one of these arguments is UNCONDITIONALLY on this line: an
// argument's reserve is the flat width of the ones that follow it.
// `guard_first` marks the one caller whose FIRST argument sits in a position
// where a leading `-` is misread; see needs_lead_paren. Every other caller
// passes false, and says so at the call site rather than leaving it to be
// inferred from a default.
static void p_args(Pr *p, WokSeq s, Ctx c, u32 prec, bool guard_first) {
  for (u32 i = 0; i < s.n; i++) {
    usize after = 0;
    for (u32 j = i + 1; j < s.n; j++)
      after += 1 + flat_after(p, s.items[j], sub(c, prec));
    put_c(p, ' ');
    Ctx ac = sub_rest(c, prec, after);
    ac.lead = guard_first && i == 0;
    p_node(p, s.items[i], ac);
  }
}

// ----------------------------------------------------------- line filling
//
// The GROUPS: the nodes that own a separator the layout filter reads as a
// continuation lead, plus the bracketed lists, where layout is suspended
// outright. Every other node is unbreakable, so a long one overflows and says
// so. A group with one element owns no separator and so owns no break.

static bool is_group(const WokNode *n) {
  switch ((WokTag)n->tag) {
    case E_Chain:
      return E_Chain_ops(n).n != 0;
    case T_With:
    case T_Fun:
      return true;
    case D_Type:
      return D_Type_cons(n).n > 1;
    case E_List:
      return E_List_items(n).n > 1;
    case E_Tuple:
      return E_Tuple_items(n).n > 1;
    case T_Tuple:
      return T_Tuple_items(n).n > 1;
    case P_List:
      return P_List_items(n).n > 1;
    case P_Tuple:
      return P_Tuple_items(n).n > 1;
    case E_Record:
      return E_Record_fields(n).n + (E_Record_spread(n) != nullptr ? 1u : 0u) >
             1u;
    case P_Record:
      return P_Record_fields(n).n + (P_Record_is_open(n) ? 1u : 0u) > 1u;
    case H_ConDef:
      return H_ConDef_is_record(n) && H_ConDef_fields(n).n > 1;

    case N_Name:
    case N_ModPath:
    case D_Module:
    case D_Import:
    case D_Alias:
    case D_Effect:
    case D_Class:
    case D_Instance:
    case D_Foreign:
    case D_ExternType:
    case D_Sig:
    case D_Fixity:
    case H_FixRel:
    case D_Equation:
    case D_Error:
    case H_TyParam:
    case H_FieldType:
    case H_OpSig:
    case H_ForeignMember:
    case H_SigName:
    case L_Prefix:
    case L_Infix:
    case T_Var:
    case T_Con:
    case T_App:
    case T_Qual:
    case T_List:
    case T_Unit:
    case T_RowArg:
    case T_Transfer:
    case H_RowEntry:
    case P_Var:
    case P_Wild:
    case P_Int:
    case P_Str:
    case P_Char:
    case P_Con:
    case P_Cons:
    case P_Unit:
    case P_As:
    case H_FieldPat:
    case E_Var:
    case E_Con:
    case E_Int:
    case E_Str:
    case E_Char:
    case E_Unit:
    case E_OpRef:
    case E_App:
    case E_Dot:
    case E_Neg:
    case E_Lambda:
    case E_LetIn:
    case E_HandleIn:
    case E_UseIn:
    case E_If:
    case E_Case:
    case E_Handler:
    case E_Assign:
    case E_Block:
    case E_Error:
    case S_Let:
    case S_Handle:
    case S_Use:
    case S_Discard:
    case H_ChainOp:
    case H_Bind:
    case H_UseBind:
    case H_Alt:
    case H_Clause:
    case H_Field:
    case W_File:
    case WOK_TAG_COUNT:
      return false;
  }
  WOK_UNREACHABLE();
}

// The width `n` would occupy written on one line. Re-rendering into a counter
// is what the measure-only sink is for; `nofill` makes the measured pass take
// the flat arm of every group, so a measurement never recurses into another.
// A subtree that HAS to break a line -- a `case` written after `->`, say --
// has no flat width at all, and m.cols would report only its last line's,
// which is smaller than the truth. WOK_PRINT_UNBOUNDED says so instead.
enum { WOK_PRINT_UNBOUNDED = WOK_PRINT_WIDTH * 100 };

static usize flat_cols(const Pr *p, const WokNode *n, Ctx c) {
  Pr m = *p;
  m.to_file = false;
  m.count_only = true;
  m.file = nullptr;
  m.buf = nullptr;
  m.len = 0;
  m.cap = 0;
  m.cols = 0;
  m.quiet = true;
  m.nofill = true;
  m.nl_seen = false;
  p_node(&m, n, c);
  return m.nl_seen ? (usize)WOK_PRINT_UNBOUNDED : m.cols;
}

// The same width, or 0 during a measuring pass. A measuring pass never breaks,
// so it never needs to know what follows -- and asking would make measuring a
// juxtaposition cost one measurement per argument per level.
static usize flat_after(const Pr *p, const WokNode *n, Ctx c) {
  return p->nofill ? 0 : flat_cols(p, n, c);
}

// THE DECISION, and the whole of it: a group that does not fit in the columns
// remaining breaks at EVERY opportunity it owns. It depends only on the tree
// and on the column reached so far -- never on the text already emitted --
// which is what leaves the fixed point a corollary of tree identity rather
// than a separate risk.
static bool decide_break(const Pr *p, const WokNode *n, Ctx c) {
  if (p->nofill) return false;
  if (!is_group(n)) return false;
  return p->cols + flat_cols(p, n, c) + c.rest > WOK_PRINT_WIDTH;
}

// True when p_body will write `body` on the current line rather than as an
// indented block of its own.
static bool body_is_inline(const WokNode *body, bool flat) {
  return !(body->tag == E_Block && !flat);
}

// The columns p_body will add to the CURRENT line: the space and the body
// itself, or nothing when the body is a block of its own.
static usize body_cols(const Pr *p, const WokNode *body, Ctx c) {
  if (!body_is_inline(body, c.flat)) return 0;
  usize w = flat_after(p, body, sub(c, EP_EXPR));
  // A body that opens a block of its own reserves nothing measurable: only
  // its FIRST line shares this one, and a reserve is a claim about this line.
  // Under-reserving can only leave a line over the width, which is reported;
  // over-reserving would wrap a head for an overflow no wrap can fix.
  return w >= (usize)WOK_PRINT_UNBOUNDED ? 0 : 1 + w;
}

// Where a wrapped line starts. A capability row aligns under its own `with`
// (decision 1); everything else takes the item's indent plus one level, which
// is local and therefore stable under a rename.
static usize cont_col(Ctx c) {
  return c.wrap != 0 ? c.wrap : (usize)c.ind * 2 + 2;
}

// A bracketed, comma-separated group. The separator LEADS its line, so every
// wrapped line begins with a continuation lead -- which is what keeps L7's
// bracket-abandonment rule from firing on a wrapped element and what lets
// wok_shape clamp the alignment instead of enforcing it.
typedef struct {
  usize col;  // the opener's column; separators and the closer align on it
  bool brk;
} Group;

static Group group_open(Pr *p, const char *open, bool brk) {
  Group g = {.col = p->cols, .brk = brk};
  usize n = strlen(open);
  put_n(p, open, n);
  // `[ a` rather than `[a`, so the first item clears the separator column.
  if (brk && open[n - 1] != ' ') put_c(p, ' ');
  return g;
}

// The context for one item of `g`. Layout is suspended inside the brackets,
// so what this fixes is legibility, not legality.
static Ctx group_item(Ctx c, u32 prec, Group g) {
  Ctx r = bracket(c, prec);
  r.wrap = g.col + 2;
  return r;
}

static void group_sep(Pr *p, Group g) {
  if (g.brk) nl_fill(p, g.col, true);
  put_z(p, ", ");
}

static void group_close(Pr *p, Group g, const char *close) {
  if (!g.brk) {
    put_z(p, close);
    return;
  }
  nl_fill(p, g.col, true);
  put_z(p, close[0] == ' ' ? close + 1 : close);
}

// ------------------------------------------------------- arrow alignment

static bool is_arrow_headed(const WokNode *n) {
  if (n->tag == H_Alt) return true;
  return n->tag == H_Clause && H_Clause_kind(n) != WOK_CLAUSE_VAR;
}

// Everything left of the `->` of an arrow-headed item. Factored out because
// a block must measure every head before it writes any of them.
static void p_arrow_head(Pr *p, const WokNode *n, Ctx c) {
  if (n->tag == H_Alt) {
    p_node(p, H_Alt_pat(n), lead_rest(c, PP_PAT, 0));
    return;
  }
  switch (H_Clause_kind(n)) {
    case WOK_CLAUSE_CONTROL:
      put_span(p, H_Clause_name(n));
      // `, k` still follows every pattern on this line, and it is two columns
      // wider than the name, so a binder run wraps at the right place.
      c.rest += 2 + H_Clause_k(n).len;
      p_args(p, H_Clause_pats(n), c, PP_ATOM, false);
      put_z(p, ", ");
      put_span(p, H_Clause_k(n));
      return;
    case WOK_CLAUSE_ABORT:
      put_z(p, "abort ");
      put_span(p, H_Clause_name(n));
      p_args(p, H_Clause_pats(n), c, PP_ATOM, false);
      return;
    case WOK_CLAUSE_RETURN:
      put_z(p, "return");
      p_args(p, H_Clause_pats(n), c, PP_ATOM, false);
      return;
    case WOK_CLAUSE_PLAIN:
      put_span(p, H_Clause_name(n));
      p_args(p, H_Clause_pats(n), c, PP_ATOM, false);
      return;
    case WOK_CLAUSE_VAR:
      break;
  }
  WOK_UNREACHABLE();
}

// What an arrow head still has to share its line with: the alignment padding
// that follows it, the ` ->`, and the body when the body is written inline.
//
// Counting the body is the Wadler reading of "the columns remaining", and it
// is what makes a wide pattern wrap when a two-character body tips the line
// over. Its one wart: a head holding a breakable group, followed by a long
// UNBREAKABLE body, wraps for an overflow the wrap cannot fix. That is
// cosmetic, and the alternative -- ignoring the body -- leaves the far more
// common case silently over the width.
static usize head_cols(const Pr *p, const WokNode *n, Ctx c);

static Ctx head_ctx(const Pr *p, const WokNode *n, Ctx c, const WokNode *body) {
  usize head = head_cols(p, n, c);
  usize slack = c.pad > head ? c.pad - head : 0;
  c.rest += slack + 3 + body_cols(p, body, c);
  return c;
}

static usize head_cols(const Pr *p, const WokNode *n, Ctx c) {
  Pr m = *p;
  m.to_file = false;
  m.count_only = true;
  m.file = nullptr;
  m.buf = nullptr;
  m.len = 0;
  m.cap = 0;
  m.cols = 0;
  m.quiet = true;
  m.nofill = true;  // a head never breaks a line, so measuring cannot either
  c.flat = true;
  c.pad = 0;
  p_arrow_head(&m, n, c);
  return m.cols;
}

// ------------------------------------------------------------ block forms

// A seq block, ALWAYS in the indented form at `ind` -- unless `flat`, where
// no indented form exists because layout is suspended inside brackets.
// `align` marks the two blocks whose arrows line up (decision 6).
//
// `owner` is the node whose trailing trivia closes the block (rule 3), or
// null for a `where`, which has no node of its own. Inside brackets no
// comment can be attached at all -- wok_trivia marks those items FLAT and
// gives them none -- so the flat arm has no trivia to write.
static void p_seq_block(Pr *p, const WokNode *owner, WokSeq seq, u32 ind,
                        bool flat, bool align) {
  Ctx ic = {.prec = 0, .ind = ind, .flat = flat, .lead = true, .brk = false,
            .pad = 0};

  if (flat) {
    // The parser can only have built a ONE-item block here, because L2
    // suppresses every layout token between the brackets.
    if (seq.n != 1) unprintable(p, "a multi-item block inside brackets");
    for (u32 i = 0; i < seq.n; i++) {
      put_c(p, ' ');
      p_node(p, seq.items[i], (Ctx){
                                  .prec = 0, .ind = ind, .flat = true,
                                  .lead = false, .brk = false, .pad = 0});
    }
    return;
  }

  // This block's own column, which every item line of it must sit on and
  // every filled line inside it must clear.
  if (p->nblk < WOK_PRINT_BLOCK_MAX) p->blk[p->nblk] = (u16)(ind * 2);
  p->nblk++;

  if (align) {
    usize widest = 0;
    for (u32 i = 0; i < seq.n; i++) {
      if (!is_arrow_headed(seq.items[i])) continue;
      usize w = head_cols(p, seq.items[i], ic);
      if (w > widest) widest = w;
    }
    // One long pattern must not push a whole block off the screen.
    if (widest <= WOK_PRINT_ALIGN_MAX) ic.pad = widest;
  }

  for (u32 i = 0; i < seq.n; i++) {
    const WokTriviaEntry *e = trivia_of(p, seq.items[i]);
    // Nothing precedes the first item, so its paragraph break has nowhere to
    // go; decision 4's "no blank line at the start of a block" still holds.
    p_lead(p, e, ind, i != 0);
    nl(p, ind, LN_ITEM);
    p_node(p, seq.items[i], ic);
    p_trail(p, seq.items[i], e);
  }
  p_block_close(p, owner, ind);
  p->nblk--;
}

// The right-hand side of `=` or `->`. A block body is the tree's own
// statement, so it is written indented; anything else follows on the line.
// `rest` is what the caller still writes after it on that line -- the ` in`
// of a `let`, the ` else` of an `if`.
static void p_body(Pr *p, const WokNode *body, u32 ind, bool flat,
                   usize rest) {
  if (!body_is_inline(body, flat)) {
    p_seq_block(p, body, E_Block_stmts(body), ind + 1, false, false);
    return;
  }
  put_c(p, ' ');
  p_node(p, body,
         (Ctx){.prec = EP_EXPR, .ind = ind, .flat = flat, .lead = false,
               .brk = false, .pad = 0, .rest = rest});
}

// `where` sits one level under its item, and its bindings one level under
// that. That column is exactly the body block's own column, which is what
// keeps `where` INSIDE the body's block region -- where parse_equation and
// parse_alt look for it -- instead of dedenting past it.
static void p_wheres(Pr *p, WokSeq w, u32 ind, bool flat) {
  if (w.n == 0) return;
  if (flat) {
    put_z(p, " where");
    p_seq_block(p, nullptr, w, ind, true, false);
    return;
  }
  nl(p, ind + 1, LN_LEAD);
  put_z(p, "where");
  p_seq_block(p, nullptr, w, ind + 2, false, false);
}

// An inline body that OPENS a block must be pushed one level deeper when a
// `where` follows, so the `where` line closes that block rather than landing
// level with it.
static u32 body_indent(const WokNode *body, WokSeq wheres, u32 ind) {
  if (wheres.n == 0 || body->tag == E_Block) return ind;
  return ind + 1;
}

// ------------------------------------------------------------- the switch

// `if` needs its three parts written in one of two shapes; keeping it out of
// the giant switch keeps that decision readable.
static void p_if(Pr *p, const WokNode *n, Ctx c);

static void p_node_inner(Pr *p, const WokNode *n, Ctx c) {
  switch ((WokTag)n->tag) {
    // ------------------------------------------------------------- names
    case N_Name:
      put_span(p, N_Name_text(n));
      return;
    case N_ModPath:
      p_list(p, N_ModPath_parts(n), sub(c, PREC_FIXED), ".");
      return;

    // ------------------------------------------------------ declarations
    case D_Module:
      put_z(p, "module ");
      p_node(p, D_Module_path(n), sub(c, PREC_FIXED));
      return;
    case D_Import: {
      put_z(p, "import ");
      p_node(p, D_Import_path(n), sub(c, PREC_FIXED));
      WokSeq names = D_Import_names(n);
      if (names.n != 0) {
        put_z(p, " (");
        p_list(p, names, bracket(c, PREC_FIXED), ", ");
        put_c(p, ')');
      }
      if (D_Import_alias(n) != nullptr) {
        put_z(p, " as ");
        p_node(p, D_Import_alias(n), sub(c, PREC_FIXED));
      }
      return;
    }
    case D_Type: {
      put_z(p, "type ");
      put_span(p, D_Type_name(n));
      p_args(p, D_Type_params(n), c, PREC_FIXED, false);
      put_z(p, " = ");
      // The FIRST alternative stays on the `=` line: a break before it would
      // put an item lead at the head of the next line. Every later one is led
      // by its `|`, which is a continuation lead and so may lead a line.
      WokSeq cons = D_Type_cons(n);
      for (u32 i = 0; i < cons.n; i++) {
        if (i != 0) {
          if (c.brk) {
            nl_fill(p, cont_col(c), c.flat);
            put_z(p, "| ");
          } else {
            put_z(p, " | ");
          }
        }
        p_node(p, cons.items[i], sub(c, PREC_FIXED));
      }
      return;
    }
    case D_Alias:
      put_z(p, "alias ");
      put_span(p, D_Alias_name(n));
      p_args(p, D_Alias_params(n), c, PREC_FIXED, false);
      put_z(p, " = ");
      p_node(p, D_Alias_body(n), sub(c, TP_TYPE));
      return;
    case D_Effect:
      put_z(p, "effect ");
      put_span(p, D_Effect_name(n));
      p_args(p, D_Effect_params(n), c, PREC_FIXED, false);
      p_seq_block(p, n, D_Effect_ops(n), c.ind + 1, c.flat, false);
      return;
    case D_Class:
      put_z(p, "class ");
      put_span(p, D_Class_name(n));
      p_args(p, D_Class_params(n), c, PREC_FIXED, false);
      p_seq_block(p, n, D_Class_body(n), c.ind + 1, c.flat, false);
      return;
    case D_Instance:
      put_z(p, "instance ");
      // The head's context is parenthesised by the GRAMMAR, not by
      // precedence: parse_instance_decl demands the brackets.
      if (D_Instance_ctx(n) != nullptr) {
        put_c(p, '(');
        p_node(p, D_Instance_ctx(n), bracket(c, TP_TYPE));
        put_z(p, ") => ");
      }
      put_span(p, D_Instance_name(n));
      p_args(p, D_Instance_args(n), c, TP_ATOM, false);
      p_seq_block(p, n, D_Instance_body(n), c.ind + 1, c.flat, false);
      return;
    case D_Foreign:
      put_z(p, "foreign module ");
      put_span(p, D_Foreign_name(n));
      put_c(p, ' ');
      put_span(p, D_Foreign_lib(n));
      p_seq_block(p, n, D_Foreign_members(n), c.ind + 1, c.flat, false);
      return;
    case D_ExternType:
      put_z(p, "extern type ");
      put_span(p, D_ExternType_name(n));
      p_args(p, D_ExternType_params(n), c, PREC_FIXED, false);
      return;
    case D_Sig:
      if (D_Sig_is_extern(n)) put_z(p, "extern ");
      p_list(p, D_Sig_names(n), sub(c, PREC_FIXED), ", ");
      put_z(p, " : ");
      p_node(p, D_Sig_type(n), sub(c, TP_TYPE));
      return;
    // `fixity + left tighter than *`. One line, never filled: the relations
    // are a sentence, and breaking `tighter than` across lines would put a
    // continuation lead where the reader expects the rest of a phrase.
    case D_Fixity: {
      put_z(p, "fixity ");
      put_span(p, D_Fixity_name(n));
      put_z(p, D_Fixity_assoc(n) == WOK_ASSOC_RIGHT ? " right" : " left");
      WokSeq rels = D_Fixity_rels(n);
      for (u32 i = 0; i < rels.n; i++) {
        put_c(p, ' ');
        p_node(p, rels.items[i], sub(c, PREC_FIXED));
      }
      return;
    }
    case H_FixRel:
      put_z(p, H_FixRel_sense(n) == WOK_FIXREL_LOOSER ? "looser than "
                                                      : "tighter than ");
      put_span(p, H_FixRel_name(n));
      return;
    case D_Equation: {
      WokSeq wheres = D_Equation_wheres(n);
      const WokNode *body = D_Equation_body(n);
      p_node(p, D_Equation_lhs(n), lead_sub(c, PP_PAT));
      put_z(p, " =");
      p_body(p, body, body_indent(body, wheres, c.ind), c.flat, 0);
      p_wheres(p, wheres, c.ind, c.flat);
      return;
    }
    case D_Error:
      // A damaged item has no canonical form; its source text is the only
      // faithful rendering, and a file holding one is not fit to format.
      unprintable(p, "a damaged declaration");
      put_span(p, D_Error_text(n));
      return;

    // ----------------------------------------------- declaration helpers
    case H_TyParam:
      if (H_TyParam_is_row(n)) {
        put_z(p, "(row ");
        put_span(p, H_TyParam_name(n));
        put_c(p, ')');
      } else {
        put_span(p, H_TyParam_name(n));
      }
      return;
    case H_ConDef: {
      WokSpan name = H_ConDef_name(n);
      if (!wok_span_empty(name)) put_span(p, name);
      if (H_ConDef_is_record(n)) {
        WokSeq fields = H_ConDef_fields(n);
        if (!wok_span_empty(name)) put_c(p, ' ');
        if (fields.n == 0) {
          put_z(p, "{}");
        } else {
          Group g = group_open(p, "{ ", c.brk);
          for (u32 i = 0; i < fields.n; i++) {
            if (i != 0) group_sep(p, g);
            p_node(p, fields.items[i], group_item(c, PREC_FIXED, g));
          }
          group_close(p, g, " }");
        }
      } else {
        p_args(p, H_ConDef_args(n), c, TP_ATOM, false);
      }
      return;
    }
    case H_FieldType:
      put_span(p, H_FieldType_name(n));
      put_z(p, " : ");
      p_node(p, H_FieldType_type(n), sub(c, TP_TYPE));
      return;
    case H_OpSig:
      put_span(p, H_OpSig_name(n));
      put_z(p, " : ");
      p_node(p, H_OpSig_type(n), sub(c, TP_TYPE));
      return;
    case H_ForeignMember: {
      put_span(p, H_ForeignMember_name(n));
      WokSpan sym = H_ForeignMember_symbol(n);
      if (!wok_span_empty(sym)) {
        put_c(p, ' ');
        put_span(p, sym);
      }
      put_z(p, " : ");
      p_node(p, H_ForeignMember_type(n), sub(c, TP_TYPE));
      return;
    }
    case H_SigName:
      if (H_SigName_paren(n)) {
        put_c(p, '(');
        put_span(p, H_SigName_name(n));
        put_c(p, ')');
      } else {
        put_span(p, H_SigName_name(n));
      }
      return;
    case L_Prefix:
      if (L_Prefix_paren(n)) {
        put_c(p, '(');
        put_span(p, L_Prefix_name(n));
        put_c(p, ')');
      } else {
        put_span(p, L_Prefix_name(n));
      }
      p_args(p, L_Prefix_args(n), c, PP_ATOM, !L_Prefix_paren(n));
      return;
    case L_Infix: {
      const WokNode *right = L_Infix_right(n);
      WokSpan op = L_Infix_op(n);
      p_node(p, L_Infix_left(n),
             lead_rest(c, PP_ATOM,
                       2 + op_cols(p, op) +
                           flat_after(p, right, sub(c, PP_ATOM))));
      put_c(p, ' ');
      p_op(p, op);
      put_c(p, ' ');
      p_node(p, right, sub(c, PP_ATOM));
      return;
    }

    // ------------------------------------------------------------- types
    case T_Var:
      put_span(p, T_Var_name(n));
      return;
    case T_Con:
      p_node(p, T_Con_path(n), sub(c, PREC_FIXED));
      return;
    case T_App: {
      const WokNode *arg = T_App_arg(n);
      p_node(p, T_App_fn(n), sub_rest(c, TP_APP,
                                      1 + flat_after(p, arg, sub(c, TP_ATOM))));
      put_c(p, ' ');
      p_node(p, arg, sub(c, TP_ATOM));
      return;
    }
    case T_Fun: {
      if (!c.brk) {
        p_node(p, T_Fun_from(n), sub(c, TP_APP));
        put_z(p, " -> ");
        p_node(p, T_Fun_to(n), sub(c, TP_ARROW));
        return;
      }
      // The whole arrow SPINE is one group, so every `->` in it breaks --
      // walked here rather than left to the nested T_Fun, which would measure
      // itself against the width freed by the break and decide to stay flat.
      const WokNode *cur = n;
      p_node(p, T_Fun_from(cur), sub(c, TP_APP));
      for (;;) {
        const WokNode *to = T_Fun_to(cur);
        nl_fill(p, cont_col(c), c.flat);
        put_z(p, "-> ");
        if (to->tag != T_Fun) {
          p_node(p, to, sub(c, TP_ARROW));
          return;
        }
        p_node(p, T_Fun_from(to), sub(c, TP_APP));
        cur = to;
      }
    }
    case T_Qual: {
      const WokNode *body = T_Qual_body(n);
      p_node(p, T_Qual_ctx(n),
             sub_rest(c, TP_ARROW, 4 + flat_after(p, body, sub(c, TP_TYPE))));
      put_z(p, " => ");
      p_node(p, body, sub(c, TP_TYPE));
      return;
    }
    case T_With: {
      // Decision 1: a wrapped capability row ALIGNS under its own `with`, and
      // the `+` entries align under each other. `with` is a fixed anchor --
      // renaming a row entry does not move it -- so the reflow is bounded,
      // and wok_shape clamps the indentation of a continuation line anyway.
      usize start = p->cols;  // the column the whole type begins on
      p_node(p, T_With_body(n), sub(c, TP_ARROW));
      WokSeq row = T_With_row(n);
      if (!c.brk) {
        put_z(p, " with ");
        p_list(p, row, sub(c, PREC_FIXED), " + ");
        return;
      }
      // The alignment guard, for the same reason decision 6 has one: one long
      // NAME must not push a whole row off the screen. The `with` column is
      // set by what precedes the type, so a long function name would carry
      // every row entry right with it. When alignment does not leave the
      // widest entry room, the row falls back to the fixed item indent.
      usize widest = 0;
      for (u32 i = 0; i < row.n; i++) {
        usize w = flat_cols(p, row.items[i], sub(c, PREC_FIXED));
        if (w > widest) widest = w;
      }
      // `with ` is five columns, and every entry begins in that column.
      usize wcol = start;
      if (!c.flat && (wcol <= block_col(p) ||
                      wcol + 5 + widest > WOK_PRINT_WIDTH))
        wcol = cont_col(c);
      nl_fill(p, wcol, c.flat);
      put_z(p, "with ");
      for (u32 i = 0; i < row.n; i++) {
        if (i != 0) {
          // `+ ` is two columns, and `with ` is five: three deeper than the
          // `with` puts the entries in one column.
          nl_fill(p, wcol + 3, c.flat);
          put_z(p, "+ ");
        }
        p_node(p, row.items[i], sub(c, PREC_FIXED));
      }
      return;
    }
    case T_List:
      put_c(p, '[');
      p_node(p, T_List_elem(n), bracket(c, TP_TYPE));
      put_c(p, ']');
      return;
    case T_Tuple: {
      WokSeq items = T_Tuple_items(n);
      Group g = group_open(p, "(", c.brk);
      for (u32 i = 0; i < items.n; i++) {
        if (i != 0) group_sep(p, g);
        p_node(p, items.items[i], group_item(c, TP_TYPE, g));
      }
      group_close(p, g, ")");
      return;
    }
    case T_Unit:
      put_z(p, "()");
      return;
    case T_RowArg:
      put_z(p, "(row ");
      put_span(p, T_RowArg_name(n));
      put_c(p, ')');
      return;
    case T_Transfer:
      switch (T_Transfer_mode(n)) {
        case WOK_TRANSFER_OWN:
          put_z(p, "own ");
          break;
        case WOK_TRANSFER_LEND:
          put_z(p, "lend ");
          break;
        case WOK_TRANSFER_COPY:
          put_z(p, "copy ");
          break;
        default:
          unprintable(p, "an unknown FFI transfer mode");
          break;
      }
      p_node(p, T_Transfer_body(n), sub_rest(c, TP_APP, 0));
      return;
    case H_RowEntry:
      switch (H_RowEntry_kind(n)) {
        case WOK_ROW_ROLE:
          put_c(p, '(');
          put_span(p, H_RowEntry_label(n));
          put_z(p, " : ");
          p_node(p, H_RowEntry_type(n), bracket(c, TP_APP));
          put_c(p, ')');
          return;
        case WOK_ROW_VAR:
          put_z(p, "eff ");
          put_span(p, H_RowEntry_label(n));
          return;
        case WOK_ROW_SLOT:
          // parse_rowentry reads a SLOT at typeapp level, so anything
          // looser has to be bracketed to survive the round trip.
          p_node(p, H_RowEntry_type(n), sub(c, TP_APP));
          return;
        default:
          unprintable(p, "an unknown row entry kind");
          return;
      }

    // ---------------------------------------------------------- patterns
    case P_Var:
      put_span(p, P_Var_name(n));
      return;
    case P_Wild:
      put_c(p, '_');
      return;
    case P_Int:
      if (P_Int_negative(n)) put_c(p, '-');
      put_uint(p, P_Int_value(n));
      return;
    case P_Str:
      put_span(p, P_Str_text(n));
      return;
    case P_Char:
      put_span(p, P_Char_text(n));
      return;
    case P_Con:
      p_node(p, P_Con_path(n), lead_sub(c, PREC_FIXED));
      p_args(p, P_Con_args(n), c, PP_ATOM, false);
      return;
    case P_Cons: {
      const WokNode *tail = P_Cons_tail(n);
      p_node(p, P_Cons_head(n),
             lead_rest(c, PP_APP, 4 + flat_after(p, tail, sub(c, PP_PAT))));
      put_z(p, " :: ");
      p_node(p, tail, sub(c, PP_PAT));
      return;
    }
    case P_Tuple: {
      WokSeq items = P_Tuple_items(n);
      Group g = group_open(p, "(", c.brk);
      for (u32 i = 0; i < items.n; i++) {
        if (i != 0) group_sep(p, g);
        p_node(p, items.items[i], group_item(c, PP_PAT, g));
      }
      group_close(p, g, ")");
      return;
    }
    case P_List: {
      WokSeq items = P_List_items(n);
      Group g = group_open(p, "[", c.brk);
      for (u32 i = 0; i < items.n; i++) {
        if (i != 0) group_sep(p, g);
        p_node(p, items.items[i], group_item(c, PP_PAT, g));
      }
      group_close(p, g, "]");
      return;
    }
    case P_Unit:
      put_z(p, "()");
      return;
    case P_As:
      p_node(p, P_As_pat(n),
             lead_rest(c, PP_ATOM, 4 + P_As_name(n).len));
      put_z(p, " as ");
      put_span(p, P_As_name(n));
      return;
    case P_Record: {
      WokSeq fields = P_Record_fields(n);
      bool open = P_Record_is_open(n);
      p_node(p, P_Record_path(n), lead_sub(c, PREC_FIXED));
      put_c(p, ' ');
      if (!open && fields.n == 0) {
        put_z(p, "{}");
        return;
      }
      Group g = group_open(p, "{ ", c.brk);
      bool first = true;
      if (open) {
        put_z(p, "..");
        WokSpan rest = P_Record_rest(n);
        if (!wok_span_empty(rest)) {
          put_c(p, ' ');
          put_span(p, rest);
        }
        first = false;
      }
      for (u32 i = 0; i < fields.n; i++) {
        if (!first) group_sep(p, g);
        first = false;
        p_node(p, fields.items[i], group_item(c, PREC_FIXED, g));
      }
      group_close(p, g, " }");
      return;
    }
    case H_FieldPat: {
      WokSpan name = H_FieldPat_name(n);
      const WokNode *pat = H_FieldPat_pat(n);
      // `{ x }` and `{ x = x }` are one tree; the punned spelling is the
      // canonical one.
      if (pat->tag == P_Var && span_eq(p, P_Var_name(pat), name)) {
        put_span(p, name);
        return;
      }
      put_span(p, name);
      put_z(p, " = ");
      p_node(p, pat, bracket(c, PP_PAT));
      return;
    }

    // ------------------------------------------------------- expressions
    case E_Var:
      put_span(p, E_Var_name(n));
      return;
    case E_Con:
      put_span(p, E_Con_name(n));
      return;
    case E_Int:
      put_uint(p, E_Int_value(n));
      return;
    case E_Str:
      put_span(p, E_Str_text(n));
      return;
    case E_Char:
      put_span(p, E_Char_text(n));
      return;
    case E_Unit:
      put_z(p, "()");
      return;
    case E_OpRef:
      put_c(p, '(');
      put_span(p, E_OpRef_name(n));
      put_c(p, ')');
      return;
    case E_App: {
      const WokNode *arg = E_App_arg(n);
      p_node(p, E_App_fn(n),
             lead_rest(c, EP_APP, 1 + flat_after(p, arg, sub(c, EP_ATOM))));
      put_c(p, ' ');
      p_node(p, arg, sub(c, EP_ATOM));
      return;
    }
    case E_Chain: {
      // EP_NEG, not EP_APP: `-a + b` is one chain whose head is a negation,
      // and a spine head is exactly where negation is legal bare.
      p_node(p, E_Chain_head(n), lead_sub(c, EP_NEG));
      WokSeq ops = E_Chain_ops(n);
      for (u32 i = 0; i < ops.n; i++) {
        // Every operand is separated by an OPERATOR, which is the one token
        // class the layout filter reads as continuing the line.
        if (c.brk)
          nl_fill(p, cont_col(c), c.flat);
        else
          put_c(p, ' ');
        p_node(p, ops.items[i], sub(c, PREC_FIXED));
      }
      return;
    }
    case H_ChainOp:
      p_op(p, H_ChainOp_op(n));
      put_c(p, ' ');
      p_node(p, H_ChainOp_rhs(n), sub(c, EP_NEG));  // `a + -b`
      return;
    case E_Dot:
      p_node(p, E_Dot_recv(n), lead_rest(c, EP_ATOM, 1 + E_Dot_name(n).len));
      put_c(p, '.');
      put_span(p, E_Dot_name(n));
      return;
    case E_Neg:
      put_c(p, '-');
      // Negation takes the whole application to its right, so its body is an
      // application spine. A nested negation is looser than that and brackets
      // itself, which is also what keeps `- -x` from lexing as the comment
      // opener `--`; the ladder states it, so no case here has to.
      p_node(p, E_Neg_body(n), sub_rest(c, EP_APP, 0));
      return;
    case E_List: {
      WokSeq items = E_List_items(n);
      Group g = group_open(p, "[", c.brk);
      for (u32 i = 0; i < items.n; i++) {
        if (i != 0) group_sep(p, g);
        p_node(p, items.items[i], group_item(c, EP_EXPR, g));
      }
      group_close(p, g, "]");
      return;
    }
    case E_Tuple: {
      WokSeq items = E_Tuple_items(n);
      Group g = group_open(p, "(", c.brk);
      for (u32 i = 0; i < items.n; i++) {
        if (i != 0) group_sep(p, g);
        p_node(p, items.items[i], group_item(c, EP_EXPR, g));
      }
      group_close(p, g, ")");
      return;
    }
    case E_Lambda: {
      put_c(p, '\\');
      WokSeq params = E_Lambda_params(n);
      for (u32 i = 0; i < params.n; i++) {
        if (i != 0) put_c(p, ' ');
        p_node(p, params.items[i], sub(c, PP_ATOM));
      }
      put_z(p, " ->");
      p_body(p, E_Lambda_body(n), c.ind, c.flat, c.rest);
      return;
    }
    case E_LetIn: {
      const WokNode *bind = E_LetIn_bind(n);
      const WokNode *lbody = E_LetIn_body(n);
      bool hang = !c.flat && opens_block(H_Bind_body(bind));
      put_z(p, "let ");
      p_node(p, bind,
             hang ? sub(c, PREC_FIXED)
                  : sub_rest(c, PREC_FIXED, 3 + body_cols(p, lbody, c)));
      // `in` closes the binding's block, so it must start a line SHALLOWER
      // than that block when there is one.
      if (hang) {
        nl(p, c.ind, LN_LEAD);
        put_z(p, "in");
      } else {
        put_z(p, " in");
      }
      p_body(p, lbody, c.ind, c.flat, c.rest);
      return;
    }
    case E_HandleIn: {
      const WokNode *handler = E_HandleIn_handler(n);
      WokSpan label = E_HandleIn_label(n);
      put_z(p, "handle ");
      if (!wok_span_empty(label)) {
        put_span(p, label);
        put_z(p, " = ");
      }
      p_node(p, handler, sub(c, EP_EXPR));
      if (!c.flat && opens_block(handler)) {
        nl(p, c.ind, LN_LEAD);
        put_z(p, "in");
      } else {
        put_z(p, " in");
      }
      p_body(p, E_HandleIn_body(n), c.ind, c.flat, c.rest);
      return;
    }
    case E_UseIn:
      put_z(p, "use ");
      p_list(p, E_UseIn_binds(n), sub(c, PREC_FIXED), ", ");
      put_z(p, " in");
      p_body(p, E_UseIn_body(n), c.ind, c.flat, c.rest);
      return;
    case E_If:
      p_if(p, n, c);
      return;
    case E_Case: {
      const WokNode *scrut = E_Case_scrut(n);
      bool split = !c.flat && opens_block(scrut);
      put_z(p, "case ");
      {
        Ctx sc = sub(c, EP_EXPR);
        if (split) sc.ind = c.ind + 1;
        p_node(p, scrut, sc);
      }
      if (split) {
        nl(p, c.ind + 1, LN_LEAD);
        put_z(p, "of");
      } else {
        put_z(p, " of");
      }
      p_seq_block(p, n, E_Case_alts(n), c.ind + 1, c.flat, true);
      return;
    }
    case E_Handler:
      put_z(p, "handler ");
      put_span(p, E_Handler_effect(n));
      p_seq_block(p, n, E_Handler_clauses(n), c.ind + 1, c.flat, true);
      return;
    case E_Assign:
      p_node(p, E_Assign_target(n), lead_sub(c, EP_CHAIN));
      put_z(p, " :=");
      p_body(p, E_Assign_value(n), c.ind, c.flat, c.rest);
      return;
    case E_Record: {
      WokSeq fields = E_Record_fields(n);
      const WokNode *spread = E_Record_spread(n);
      p_node(p, E_Record_path(n), lead_sub(c, EP_ATOM));
      put_c(p, ' ');
      if (spread == nullptr && fields.n == 0) {
        put_z(p, "{}");
        return;
      }
      Group g = group_open(p, "{ ", c.brk);
      bool first = true;
      if (spread != nullptr) {
        put_z(p, ".. ");
        p_node(p, spread, group_item(c, EP_EXPR, g));
        first = false;
      }
      for (u32 i = 0; i < fields.n; i++) {
        if (!first) group_sep(p, g);
        first = false;
        p_node(p, fields.items[i], group_item(c, PREC_FIXED, g));
      }
      group_close(p, g, " }");
      return;
    }
    case E_Block:
      // Reached only when a block sits somewhere p_body did not place it.
      p_seq_block(p, n, E_Block_stmts(n), c.ind + 1, c.flat, false);
      return;
    case E_Error:
      unprintable(p, "a damaged expression");
      put_span(p, E_Error_text(n));
      return;

    // -------------------------------------------------------- statements
    case S_Let:
      put_z(p, "let ");
      p_node(p, S_Let_bind(n), sub(c, PREC_FIXED));
      return;
    case S_Handle:
      put_z(p, "handle ");
      put_span(p, S_Handle_label(n));
      put_z(p, " = ");
      p_node(p, S_Handle_handler(n), sub(c, EP_EXPR));
      return;
    case S_Use:
      put_z(p, "use ");
      p_list(p, S_Use_binds(n), sub(c, PREC_FIXED), ", ");
      return;
    case S_Discard:
      put_z(p, "_ =");
      p_body(p, S_Discard_body(n), c.ind, c.flat, c.rest);
      return;

    // ------------------------------------------------ expression helpers
    case H_Bind:
      p_node(p, H_Bind_lhs(n), lead_sub(c, PP_PAT));
      put_z(p, " =");
      p_body(p, H_Bind_body(n), c.ind, c.flat, c.rest);
      return;
    case H_UseBind:
      put_span(p, H_UseBind_from(n));
      put_z(p, " as ");
      put_span(p, H_UseBind_to(n));
      return;
    case H_Alt: {
      WokSeq wheres = H_Alt_wheres(n);
      const WokNode *body = H_Alt_body(n);
      usize start = p->cols;
      p_arrow_head(p, n, head_ctx(p, n, c, body));
      if (c.pad > p->cols - start) put_spaces(p, c.pad - (p->cols - start));
      put_z(p, " ->");
      p_body(p, body, body_indent(body, wheres, c.ind), c.flat, 0);
      p_wheres(p, wheres, c.ind, c.flat);
      return;
    }
    case H_Clause: {
      if (H_Clause_kind(n) == WOK_CLAUSE_VAR) {
        // A baton is headed by `=`, so it joins no alignment group.
        put_z(p, "var ");
        put_span(p, H_Clause_name(n));
        put_z(p, " =");
        p_body(p, H_Clause_body(n), c.ind, c.flat, c.rest);
        return;
      }
      usize start = p->cols;
      p_arrow_head(p, n, head_ctx(p, n, c, H_Clause_body(n)));
      if (c.pad > p->cols - start) put_spaces(p, c.pad - (p->cols - start));
      put_z(p, " ->");
      p_body(p, H_Clause_body(n), c.ind, c.flat, c.rest);
      return;
    }
    case H_Field: {
      WokSpan name = H_Field_name(n);
      const WokNode *value = H_Field_value(n);
      if (value->tag == E_Var && span_eq(p, E_Var_name(value), name)) {
        put_span(p, name);
        return;
      }
      put_span(p, name);
      put_z(p, " = ");
      p_node(p, value, bracket(c, EP_EXPR));
      return;
    }

    // -------------------------------------------------------------- file
    case W_File: {
      WokSeq decls = W_File_decls(n);
      for (u32 i = 0; i < decls.n; i++) {
        // One blank line between top-level items, except where two of them
        // are really one unit (a signature and its equation, a run of imports).
        // Decision 4 owns the blank line here, so a declaration's recorded
        // paragraph break is not consulted -- honouring both would print two.
        if (i != 0 && !decls_are_one_unit(p, decls.items[i - 1], decls.items[i]))
          put_c(p, '\n');
        const WokTriviaEntry *e = trivia_of(p, decls.items[i]);
        if (e != nullptr)
          for (u32 k = 0; k < e->lead_n; k++) {
            put_comment(p, e->lead_first + k);
            put_c(p, '\n');
          }
        p_node(p, decls.items[i],
               (Ctx){.prec = 0, .ind = 0, .flat = false, .lead = true,
                     .brk = false, .pad = 0});
        p_trail(p, decls.items[i], e);
        put_c(p, '\n');
      }
      // Rule 3 at the top level: a comment with no declaration after it.
      const WokTriviaEntry *fe = trivia_of(p, n);
      if (fe != nullptr)
        for (u32 k = 0; k < fe->trail_n; k++) {
          put_comment(p, fe->trail_first + k);
          put_c(p, '\n');
        }
      return;
    }

    case WOK_TAG_COUNT:
      break;
  }
  WOK_UNREACHABLE();
}

static void p_if(Pr *p, const WokNode *n, Ctx c) {
  const WokNode *cond = E_If_cond(n);
  const WokNode *then_ = E_If_then_(n);
  const WokNode *else_ = E_If_else_(n);
  bool split = !c.flat && (opens_block(cond) || opens_block(then_));

  put_z(p, "if ");
  {
    Ctx sc = split ? sub(c, EP_EXPR)
                   : sub_rest(c, EP_EXPR, 5 + body_cols(p, then_, c));
    if (split) sc.ind = c.ind + 1;
    p_node(p, cond, sc);
  }
  if (!split) {
    put_z(p, " then");
    p_body(p, then_, c.ind, c.flat, 5 + body_cols(p, else_, c) + c.rest);
    put_z(p, " else");
    p_body(p, else_, c.ind, c.flat, c.rest);
    return;
  }
  nl(p, c.ind + 1, LN_LEAD);
  put_z(p, "then");
  p_body(p, then_, c.ind + 1, c.flat, 0);
  nl(p, c.ind + 1, LN_LEAD);
  put_z(p, "else");
  p_body(p, else_, c.ind + 1, c.flat, c.rest);
}

static void p_node(Pr *p, const WokNode *n, Ctx c) {
  if (p->depth >= WOK_PRINT_MAX_DEPTH) {
    unprintable(p, "a tree nested past the printer's depth cap");
    put_z(p, "!DEPTH");
    return;
  }
  // Measured BEFORE the depth is charged, so the measuring pass re-enters at
  // the same depth this one is at and cannot exhaust the cap by halving it.
  bool brk = decide_break(p, n, c);
  p->depth++;
  p->tstack[p->tn++] = n->tag;

  bool paren = node_prec(n) < c.prec || (c.lead && needs_lead_paren(n));
  if (paren) {
    put_c(p, '(');
    c.prec = 0;
    c.flat = true;  // a bracket group suspends layout: rule L2
    c.lead = false;
  }
  c.brk = brk;
  p_node_inner(p, n, c);
  if (paren) put_c(p, ')');

  p->tn--;
  p->depth--;
}

// ---------------------------------------------------------------- public

static const Ctx TOP = {.prec = 0, .ind = 0, .flat = false, .lead = true,
                        .brk = false, .pad = 0};

void wok_print(const WokNode *file, const char *src, FILE *out) {
  Pr p = {.to_file = true, .file = out, .src = src, .line = 1,
          .tv = wok_trivia_of(file)};
  p_node(&p, file, TOP);
  // A W_File closes every declaration with a newline of its own.
  if (file->tag != W_File) put_c(&p, '\n');
}

char *wok_print_string(const WokNode *file, const char *src, WokArena *arena) {
  return wok_print_string_named(file, src, arena, nullptr);
}

char *wok_print_string_named(const WokNode *file, const char *src,
                             WokArena *arena, const char *path) {
  Pr p = {.arena = arena, .src = src, .path = path, .line = 1,
          .tv = wok_trivia_of(file)};
  p_node(&p, file, TOP);
  if (file->tag != W_File) put_c(&p, '\n');
  sink_reserve(&p, 1);
  p.buf[p.len] = '\0';
  return p.buf;
}
