// wok_trivia -- see wok_trivia.h for what this is and why comments are not
// slots.
//
// THE SHAPE OF THE PASS
//
//   1. index the source's lines, because every attachment rule is stated in
//      lines and columns and the token stream has already thrown the blank
//      ones away;
//   2. walk the tree once, in PRINT order, recording every block ITEM and
//      every block SCOPE with an Euler timestamp;
//   3. give each comment a target, in source order;
//   4. lay the comments out in one pooled array so each item's leading and
//      trailing runs are contiguous.
//
// STEP 2 IS THE ONE THAT PAYS FOR THE PROPERTY. The Euler tour gives every
// possible target a POSITION IN THE PRINTED TEXT, and step 3 refuses to let
// that position go backwards. That is what makes
//
//   comments(Format(t)) == comments(t)     -- same texts, SAME ORDER
//
// true by construction rather than by inspection of cases: a rule that would
// move a comment behind one that preceded it in the source is overridden and
// the comment joins its predecessor instead.

// The prelude comes FIRST: it carries the POSIX feature-test macros, which
// have no effect once a system header has been read. wok_base.h hard-errors
// if it is reached too late.
#include "wok_base.h"

#include "wok_trivia.h"

#include <string.h>

// The tree is bounded by the parser's own depth cap; this is only a guard so
// a hostile or damaged tree cannot walk off the C stack.
enum { TRIVIA_MAX_DEPTH = 512 };

#define NO_SCOPE UINT32_MAX

// ------------------------------------------------------------------ lines

typedef struct {
  const char *src;
  usize n;
  u32 *start;  // start[i] is the offset of line i, 0-based
  u32 nlines;
} Lines;

static void lines_build(Lines *l, const char *src, usize n, WokArena *a) {
  u32 count = 1;
  for (usize i = 0; i < n; i++)
    if (src[i] == '\n') count++;
  l->src = src;
  l->n = n;
  l->nlines = count;
  l->start = WOK_NEW_N(a, u32, count);
  u32 k = 0;
  l->start[k++] = 0;
  for (usize i = 0; i < n; i++)
    if (src[i] == '\n' && k < count) l->start[k++] = (u32)i + 1;
}

static u32 line_of(const Lines *l, u32 off) {
  u32 lo = 0, hi = l->nlines - 1;
  while (lo < hi) {
    u32 mid = lo + (hi - lo + 1) / 2;
    if (l->start[mid] <= off)
      lo = mid;
    else
      hi = mid - 1;
  }
  return lo;
}

static u32 col_of(const Lines *l, u32 off) {
  return off - l->start[line_of(l, off)] + 1;
}

static bool is_blank_byte(char c) { return c == ' ' || c == '\t' || c == '\r'; }

// A line with nothing but whitespace on it -- the author's paragraph break.
static bool line_is_blank(const Lines *l, u32 line) {
  u32 from = l->start[line];
  u32 to = line + 1 < l->nlines ? l->start[line + 1] : (u32)l->n;
  for (u32 i = from; i < to; i++) {
    char c = l->src[i];
    if (c == '\n') break;
    if (!is_blank_byte(c)) return false;
  }
  return true;
}

// Rule 1's test: is this the first non-whitespace on its line?
static bool starts_its_line(const Lines *l, u32 off) {
  for (u32 i = l->start[line_of(l, off)]; i < off; i++)
    if (!is_blank_byte(l->src[i])) return false;
  return true;
}

// ------------------------------------------------------- the layout table
//
// ONE switch decides two things the walk needs, so a new node cannot be added
// without answering both. -Wswitch with no `default:` is what enforces that.
//
//   block_slot -- the SEQ that wok_print writes with p_seq_block, whose
//                 members are therefore block ITEMS. Every other SEQ (tuple
//                 elements, constructor arguments) holds no items.
//   open_mask  -- the slots wok_print enters WITHOUT brackets, so an indented
//                 block can still exist under them. Inside brackets layout is
//                 suspended (rule L2) and no comment can be written on a line
//                 of its own, so items reached through any other slot are
//                 marked FLAT and never receive trivia. Forgetting a slot
//                 here is safe -- it only pushes a comment outward to an
//                 enclosing item; inventing one is not.

typedef struct {
  i32 block_slot;
  u32 open_mask;
} TagLayout;

#define SL(x) (1u << (x))

static TagLayout tag_layout(WokTag t) {
  switch (t) {
    case N_Name:
    case N_ModPath:
    case D_Module:
    case D_Import:
    case D_Type:
    case D_Alias:
    case D_ExternType:
    case D_Sig:
    case D_Fixity:
    case H_FixRel:
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
    case S_Use:
    case H_ChainOp:
    case H_UseBind:
    case H_Field:
    case WOK_TAG_COUNT:
      return (TagLayout){-1, 0};

    case D_Effect:
      return (TagLayout){D_Effect__ops, SL(D_Effect__ops)};
    case D_Class:
      return (TagLayout){D_Class__body, SL(D_Class__body)};
    case D_Instance:
      return (TagLayout){D_Instance__body, SL(D_Instance__body)};
    case D_Foreign:
      return (TagLayout){D_Foreign__members, SL(D_Foreign__members)};
    case D_Equation:
      return (TagLayout){D_Equation__wheres,
                         SL(D_Equation__body) | SL(D_Equation__wheres)};
    case E_Lambda:
      return (TagLayout){-1, SL(E_Lambda__body)};
    case E_LetIn:
      return (TagLayout){-1, SL(E_LetIn__bind) | SL(E_LetIn__body)};
    case E_HandleIn:
      return (TagLayout){-1, SL(E_HandleIn__handler) | SL(E_HandleIn__body)};
    case E_UseIn:
      return (TagLayout){-1, SL(E_UseIn__body)};
    case E_If:
      return (TagLayout){
          -1, SL(E_If__cond) | SL(E_If__then_) | SL(E_If__else_)};
    case E_Case:
      return (TagLayout){E_Case__alts, SL(E_Case__scrut) | SL(E_Case__alts)};
    case E_Handler:
      return (TagLayout){E_Handler__clauses, SL(E_Handler__clauses)};
    case E_Assign:
      return (TagLayout){-1, SL(E_Assign__value)};
    case E_Block:
      return (TagLayout){E_Block__stmts, SL(E_Block__stmts)};
    case S_Let:
      return (TagLayout){-1, SL(S_Let__bind)};
    case S_Handle:
      return (TagLayout){-1, SL(S_Handle__handler)};
    case S_Discard:
      return (TagLayout){-1, SL(S_Discard__body)};
    case H_Bind:
      return (TagLayout){-1, SL(H_Bind__body)};
    case H_Alt:
      return (TagLayout){H_Alt__wheres, SL(H_Alt__body) | SL(H_Alt__wheres)};
    case H_Clause:
      return (TagLayout){-1, SL(H_Clause__body)};
    case W_File:
      return (TagLayout){W_File__decls, SL(W_File__decls)};
  }
  WOK_UNREACHABLE();
}

// A scope whose owner node can hold the comments that CLOSE it (rule 3) in
// its own trailing range. A `where` block is the exception: it has no node of
// its own -- its owner is the equation or alternative it hangs off, and that
// node's trailing range already belongs to the item itself. Its closing
// comments go to an enclosing block instead.
static bool scope_is_closable(WokTag t) {
  return t != D_Equation && t != H_Alt;
}

// The mirror of the above: an item may take a TRAILING comment only if its
// own trailing range is not already spoken for by a block it closes. An
// equation or alternative is safe even though it owns a `where`, because that
// block's closing comments were sent elsewhere.
static bool item_takes_trail(WokTag t) {
  return tag_layout(t).block_slot < 0 || !scope_is_closable(t);
}

bool wok_trivia_trail_closes_block(const WokNode *n) {
  return !item_takes_trail((WokTag)n->tag);
}

// ------------------------------------------------------- items and scopes

typedef struct {
  WokNode *node;
  u32 scope;
  u32 enter, exit;  // Euler timestamps: the item's place in the output
  u32 line, end_line, col;
  bool flat;
  bool first_in_scope;
} Item;

typedef struct {
  WokNode *owner;
  u32 parent;
  u32 item_col;
  u32 close;  // Euler timestamp of the point after the last item
  bool flat;
  bool closable;
} Scope;

typedef struct {
  WokArena *a;
  Lines lines;
  Item *item;
  u32 nitem, capitem;
  Scope *scope;
  u32 nscope, capscope;
  u32 clock;
} Builder;

static u32 push_item(Builder *b, WokNode *n, u32 scope, bool flat,
                          bool first) {
  if (b->nitem == b->capitem) {
    u32 next = b->capitem ? b->capitem * 2 : 32;
    Item *grown = WOK_NEW_N(b->a, Item, next);
    if (b->nitem) memcpy(grown, b->item, (usize)b->nitem * sizeof *grown);
    b->item = grown;
    b->capitem = next;
  }
  u32 last = n->len != 0 ? n->off + n->len - 1 : n->off;
  if (last >= b->lines.n) last = b->lines.n != 0 ? (u32)b->lines.n - 1 : 0;
  b->item[b->nitem] = (Item){.node = n,
                             .scope = scope,
                             .enter = 0,
                             .exit = 0,
                             .line = line_of(&b->lines, n->off),
                             .end_line = line_of(&b->lines, last),
                             .col = col_of(&b->lines, n->off),
                             .flat = flat,
                             .first_in_scope = first};
  return b->nitem++;
}

static u32 push_scope(Builder *b, WokNode *owner, u32 parent,
                           bool flat, u32 item_col) {
  if (b->nscope == b->capscope) {
    u32 next = b->capscope ? b->capscope * 2 : 16;
    Scope *grown = WOK_NEW_N(b->a, Scope, next);
    if (b->nscope) memcpy(grown, b->scope, (usize)b->nscope * sizeof *grown);
    b->scope = grown;
    b->capscope = next;
  }
  b->scope[b->nscope] = (Scope){.owner = owner,
                                .parent = parent,
                                .item_col = item_col,
                                .close = 0,
                                .flat = flat,
                                .closable =
                                    scope_is_closable((WokTag)owner->tag)};
  return b->nscope++;
}

static void walk_node(Builder *b, WokNode *n, u32 scope, bool flat,
                      u32 depth);

static void walk_scope(Builder *b, WokNode *owner, WokSeq seq, u32 parent,
                       bool flat, u32 depth) {
  u32 col = seq.n != 0 ? col_of(&b->lines, seq.items[0]->off)
                            : col_of(&b->lines, owner->off);
  u32 s = push_scope(b, owner, parent, flat, col);
  for (u32 i = 0; i < seq.n; i++) {
    u32 idx = push_item(b, seq.items[i], s, flat, i == 0);
    b->item[idx].enter = b->clock++;
    walk_node(b, seq.items[i], s, flat, depth + 1);
    b->item[idx].exit = b->clock++;
  }
  b->scope[s].close = b->clock++;
}

static void walk_node(Builder *b, WokNode *n, u32 scope, bool flat,
                      u32 depth) {
  if (depth >= TRIVIA_MAX_DEPTH) return;
  TagLayout layout = tag_layout((WokTag)n->tag);
  const WokNodeDesc *desc = &wok_node_desc[n->tag];
  for (u16 i = 0; i < desc->nfields; i++) {
    bool open = ((layout.open_mask >> i) & 1u) != 0;
    bool child_flat = flat || !open;
    switch (desc->fields[i].cls) {
      case WFC_NODE:
      case WFC_OPT: {
        WokNode *child = n->slot[i].node;
        if (child != nullptr) walk_node(b, child, scope, child_flat, depth + 1);
        break;
      }
      case WFC_SEQ: {
        WokSeq seq = wok_seq_unpack(n->slot[i].seq);
        if (layout.block_slot == (i32)i) {
          walk_scope(b, n, seq, scope, child_flat, depth);
        } else {
          for (u32 k = 0; k < seq.n; k++)
            walk_node(b, seq.items[k], scope, child_flat, depth + 1);
        }
        break;
      }
      case WFC_NAME:
      case WFC_TEXT:
      case WFC_INT:
      case WFC_FLAG:
      case WOK_FIELD_CLASS_COUNT:
        break;
    }
  }
}

// ------------------------------------------------------------- attachment

typedef enum { T_LEAD, T_TRAIL, T_CLOSE } TargetKind;

typedef struct {
  TargetKind kind;
  u32 idx;   // an item for T_LEAD/T_TRAIL, a scope for T_CLOSE
  u32 rank;  // where this lands in the printed text
} Target;

static u32 target_rank(const Builder *b, TargetKind k, u32 idx) {
  switch (k) {
    case T_LEAD:
      return b->item[idx].enter;
    case T_TRAIL:
      return b->item[idx].exit;
    case T_CLOSE:
      return b->scope[idx].close;
  }
  WOK_UNREACHABLE();
}

static WokNode *target_node(const Builder *b, const Target *t) {
  switch (t->kind) {
    case T_LEAD:
    case T_TRAIL:
      return b->item[t->idx].node;
    case T_CLOSE:
      return b->scope[t->idx].owner;
  }
  WOK_UNREACHABLE();
}

// Rule 2. The item this line's trailing comment belongs to is the last one
// that both begins and ENDS on the line, before the comment. An item that
// runs on -- because it opens a block whose own items follow -- is refused,
// because its trailing comment would be printed after that block and so after
// every comment written inside it.
// `before` is the count of items that begin left of the comment, which the
// caller advances monotonically; scanning back from it visits only the items
// on this one line.
static bool find_line_item(const Builder *b, u32 before, u32 line,
                           u32 coff, u32 *out) {
  for (u32 i = before; i-- > 0;) {
    const Item *it = &b->item[i];
    if (it->line < line) break;
    if (it->flat || it->end_line != line) continue;
    if (!item_takes_trail((WokTag)it->node->tag)) continue;
    if (it->node->off + it->node->len > coff) continue;
    *out = i;  // scanning backward, the first hit is the LAST on the line
    return true;
  }
  return false;
}

// Rule 3. The block a comment that follows no item belongs to is the
// innermost enclosing one whose ITEMS sit at or left of the comment. Column
// is the only evidence there is: the comment is inside whichever block its
// author indented it to.
static u32 choose_close_scope(const Builder *b, u32 before,
                                   u32 ccol) {
  u32 s = before != 0 ? b->item[before - 1].scope : NO_SCOPE;
  while (s != NO_SCOPE) {
    const Scope *sc = &b->scope[s];
    if (sc->closable && !sc->flat && sc->item_col <= ccol) return s;
    s = sc->parent;
  }
  return 0;  // scope 0 is the file's own: closable, never flat, column 1
}

// Is `outer` `inner` itself, or one of the blocks it nests inside?
static bool scope_encloses(const Builder *b, u32 outer, u32 inner) {
  while (inner != NO_SCOPE) {
    if (inner == outer) return true;
    inner = b->scope[inner].parent;
  }
  return false;
}

// ------------------------------------------------------- the entry table
//
// One entry per node that carries anything. Open addressing on the node
// pointer, sized so the table can never fill.

typedef struct {
  WokNode *key;
  u32 entry;
} MapSlot;

typedef struct {
  MapSlot *slot;
  u32 mask;
  WokTriviaEntry *entry;
  u32 nentry, capentry;
} EntryMap;

static u32 ptr_hash(const void *p) {
  u64 x = (u64)(uptr)p;
  x ^= x >> 33;
  x *= UINT64_C(0xFF51AFD7ED558CCD);
  x ^= x >> 29;
  return (u32)x;
}

static u32 entry_for(EntryMap *m, WokNode *n) {
  u32 i = ptr_hash(n) & m->mask;
  while (m->slot[i].key != nullptr) {
    if (m->slot[i].key == n) return m->slot[i].entry;
    i = (i + 1) & m->mask;
  }
  assert(m->nentry < m->capentry);  // sized for every possible target
  u32 e = m->nentry++;
  m->entry[e] = (WokTriviaEntry){0};
  m->slot[i] = (MapSlot){.key = n, .entry = e};
  n->trivia = e;
  return e;
}

// --------------------------------------------------------------- bindings
//
// wok_print is handed a tree and the buffer its spans point into, and must
// find this table from those alone. The binding is keyed on the file node AND
// gated on `trivia != 0`, which only this pass ever sets: a node the arena
// later hands out at the same address is freshly zeroed, so a stale binding
// can never be mistaken for a live one. The tool is one-shot and
// single-threaded by design (design section 1), exactly as the coverage
// instrument in wok_ast.c already assumes.

enum { TRIVIA_BINDINGS = 8 };

static struct {
  const WokNode *file;
  const WokTrivia *table;
} bindings[TRIVIA_BINDINGS];
static u32 binding_next;

static void bind_table(const WokNode *file, const WokTrivia *table) {
  for (u32 i = 0; i < TRIVIA_BINDINGS; i++)
    if (bindings[i].file == file) {
      bindings[i].table = table;
      return;
    }
  u32 i = binding_next++ % TRIVIA_BINDINGS;
  bindings[i].file = file;
  bindings[i].table = table;
}

const WokTrivia *wok_trivia_of(const WokNode *file) {
  if (file == nullptr || file->trivia == 0) return nullptr;
  for (u32 i = 0; i < TRIVIA_BINDINGS; i++)
    if (bindings[i].file == file) return bindings[i].table;
  return nullptr;
}

// ------------------------------------------------------------------ attach

const WokTrivia *wok_trivia_attach(WokNode *file, const char *src,
                                   usize src_len, const WokComment *comments,
                                   usize ncomments, WokArena *arena) {
  WokTrivia *table = WOK_NEW(arena, WokTrivia);
  *table = (WokTrivia){
      .entry = nullptr, .nentries = 0, .comment = nullptr, .ncomments = 0};

  Builder b = {.a = arena,
               .item = nullptr,
               .nitem = 0,
               .capitem = 0,
               .scope = nullptr,
               .nscope = 0,
               .capscope = 0,
               .clock = 0};
  lines_build(&b.lines, src, src_len, arena);
  // Scope 0 is the file's own block, and rule 3's last resort. A tree that is
  // not a whole file has no such block, so it takes no trivia at all.
  if (file->tag == W_File) walk_node(&b, file, NO_SCOPE, false, 0);
  if (b.nscope == 0) ncomments = 0;

  // Every node that can be a target, plus one so the file node always gets a
  // non-zero index -- that is what makes the binding check above sound.
  u32 cap = (u32)ncomments + b.nitem + 2;
  u32 size = 16;
  while (size < cap * 2) size *= 2;
  EntryMap map = {.slot = WOK_NEW_N(arena, MapSlot, size),
                  .mask = size - 1,
                  .entry = WOK_NEW_N(arena, WokTriviaEntry, cap),
                  .nentry = 0,
                  .capentry = cap};
  memset(map.slot, 0, (usize)size * sizeof *map.slot);
  map.entry[map.nentry++] = (WokTriviaEntry){0};  // the reserved sentinel
  (void)entry_for(&map, file);

  Target *target = WOK_NEW_N(arena, Target, ncomments + 1);
  bool have_prev = false;
  Target prev = {.kind = T_CLOSE, .idx = 0, .rank = 0};

  // Comments arrive in source order, so both cursors only ever move forward
  // and the whole pass is linear in items plus comments.
  u32 before = 0;  // items that begin left of the comment
  u32 next = 0;    // the first non-flat item that begins after it

  for (usize ci = 0; ci < ncomments; ci++) {
    const WokComment *c = &comments[ci];
    u32 coff = c->off;
    u32 cend = c->off + c->len;
    u32 cline = line_of(&b.lines, coff);
    u32 ccol = col_of(&b.lines, coff);
    while (before < b.nitem && b.item[before].node->off < coff) before++;
    while (next < b.nitem &&
           (b.item[next].flat || b.item[next].node->off < cend))
      next++;
    bool have_next = next < b.nitem;

    Target t = {.kind = T_CLOSE, .idx = 0, .rank = 0};
    u32 idx = 0;
    bool decided = false;

    if (!starts_its_line(&b.lines, coff) &&
        find_line_item(&b, before, cline, coff, &idx)) {
      t.kind = T_TRAIL;
      t.idx = idx;
      decided = true;
    }
    if (!decided && have_next && ccol <= b.item[next].col) {
      // Deeper than the item it precedes means the author left it inside the
      // block that just ended, not attached to what comes next.
      t.kind = T_LEAD;
      t.idx = next;
      decided = true;
    }
    if (!decided) {
      u32 s = choose_close_scope(&b, before, ccol);
      // A block only CLOSES if what follows is outside it. Between two items
      // of the same block, an over-indented comment is still that block's --
      // it leads the item it was written above.
      if (have_next && scope_encloses(&b, s, b.item[next].scope)) {
        t.kind = T_LEAD;
        t.idx = next;
      } else {
        t.kind = T_CLOSE;
        t.idx = s;
      }
    }
    t.rank = target_rank(&b, t.kind, t.idx);

    // The order guarantee. A rule that would print this comment before one
    // that preceded it in the source loses; the comment joins its predecessor.
    if (have_prev && t.rank < prev.rank) t = prev;
    target[ci] = t;
    prev = t;
    have_prev = true;
  }

  // blank_before, read off the source: the paragraph break above the item,
  // counting a leading comment block as part of the item.
  u32 *first_lead = WOK_NEW_N(arena, u32, b.nitem + 1);
  for (u32 i = 0; i <= b.nitem; i++) first_lead[i] = UINT32_MAX;
  for (usize ci = ncomments; ci-- > 0;)
    if (target[ci].kind == T_LEAD) first_lead[target[ci].idx] = (u32)ci;

  for (u32 i = 0; i < b.nitem; i++) {
    const Item *it = &b.item[i];
    // Only a break BETWEEN two items of one block is printable: the top level
    // already writes its own blank lines, and nothing precedes a block's
    // first item.
    if (it->flat || it->first_in_scope || it->scope == 0) continue;
    u32 line = first_lead[i] != UINT32_MAX
                        ? line_of(&b.lines, comments[first_lead[i]].off)
                        : it->line;
    if (line == 0 || !line_is_blank(&b.lines, line - 1)) continue;
    map.entry[entry_for(&map, it->node)].blank_before = 1;
  }

  // The pool. Ranks never decrease, so equal-ranked comments are adjacent and
  // every run below is contiguous without a second pass to prove it.
  WokComment *pool = WOK_NEW_N(arena, WokComment, ncomments + 1);
  for (usize ci = 0; ci < ncomments; ci++) {
    WokTriviaEntry *e = &map.entry[entry_for(&map, target_node(&b,
                                                               &target[ci]))];
    if (target[ci].kind == T_LEAD) {
      if (e->lead_n == 0) e->lead_first = (u32)ci;
      e->lead_n++;
    } else {
      if (e->trail_n == 0) e->trail_first = (u32)ci;
      e->trail_n++;
    }
    pool[ci] = comments[ci];
  }

  table->entry = map.entry;
  table->nentries = map.nentry;
  table->comment = pool;
  table->ncomments = (u32)ncomments;
  bind_table(file, table);
  return table;
}
