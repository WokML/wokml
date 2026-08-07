// wok_reorder -- see wok_reorder.h.
//
// A transliteration of Wok.Reordering's reorderChain / findLoosest /
// combineInfix, not a reimplementation from the doc prose: the Haskell
// source (src/Wok/Reordering.hs) is read alongside every function below, and
// the two are meant to be read side by side. Divergence is a bug, caught by
// the differential test on the Haskell side (test/Spec.hs), not adjudicated
// here.
//
// TABLE-FIRST, TREE-SECOND. Haskell's buildFixityTable runs checkNeighbors
// over the WHOLE table before reorderAst ever looks at an expression: a
// `fixity` relation naming a neighbour that never gets its own `fixity` head
// is a fault of the FILE, not of any particular use site -- it fails a
// module with zero chains just as surely as one with a thousand. wok_reorder
// mirrors that ordering explicitly (check_neighbours, called once at entry,
// before reorder_node takes a single step): a placeholder anywhere in the
// table stops the pass right there. The per-occurrence checks inside
// reorder_chain therefore only ever see a placeholder-free table -- an
// operator reaching that point is either genuinely undeclared (no entry at
// all) or fully declared, never "known but only as someone else's neighbour".
//
// TREE SHAPE. Haskell's combineInfix wraps an already-chained operand in
// EParen before nesting it, because its surface grammar keeps "a chain" and
// "a parenthesized chain used as an operand" as distinct constructors. This
// AST has no such node -- wok_print.h already documents that parentheses are
// RE-DERIVED at print time, never stored -- so an E_Chain nests directly
// wherever EXPR is demanded (E_Chain's own `head` and H_ChainOp's `rhs` both
// declare that family). No wrapper is built; the s-expression dump makes the
// nesting visible through bracket structure alone.

#include "wok_reorder.h"

#include <string.h>

// The walk's working context: the table it consults, the source every span
// in the tree points into, the arena new nodes are built in, and the sink
// diagnostics go to. One instance, threaded by pointer, exactly like R in
// wok_resolve.c -- but this one holds no mutable table-building state,
// because the table already exists by the time this pass runs.
typedef struct {
  const WokFixTable *fix;
  const char *src;
  WokArena *a;
  WokDiagSink *d;
} RO;

#define SPAN(ro, s) (int)(s).len, (ro)->src + (s).off

static bool span_eq(const RO *ro, WokSpan a, WokSpan b) {
  return a.len == b.len && memcmp(ro->src + a.off, ro->src + b.off, a.len) == 0;
}

// Linear scan, not a hash index: the table this pass reads is the one file's
// own `fixity` declarations, small by construction (spec: "Performance"),
// and the reorder pass has no need of resolve's NameIdx to get O(1) here.
static u32 fix_find(const RO *ro, WokSpan name) {
  for (u32 i = 0; i < ro->fix->n; i++)
    if (span_eq(ro, ro->fix->ops[i].name, name)) return i;
  return UINT32_MAX;
}

static bool fix_tighter(const RO *ro, u32 i, u32 j) {
  return (ro->fix->edge[(usize)i * ro->fix->words + j / 64] >> (j % 64) & 1u) !=
         0;
}

// One flat chain slot, with its rhs ALREADY reordered -- reorder_node walks
// bottom-up, so by the time an E_Chain node is handed to reorder_chain every
// child it owns is done. `fix_idx` is resolved once per chain (checkDeclared,
// mirrored) rather than re-looked-up at every comparison in the scan.
typedef struct {
  WokSpan name;
  bool backtick;
  WokNode *rhs;
  u32 fix_idx;
} Tail;

typedef enum { ORD_TIGHTER, ORD_LOOSER, ORD_EQUAL, ORD_INCOMPARABLE } Order;

// compareOps, transliterated. Argument order matters: `a` is the occurrence
// under the scan's cursor, `b` is the current loosest-so-far, exactly as
// Haskell's findLoosest calls `compareOps t curName bestName`. Tighter means
// a binds TIGHTER than b (b remains loosest); Looser means a binds LOOSER
// (a becomes the new loosest).
static Order compare_ops(const RO *ro, WokSpan a, u32 ai, WokSpan b, u32 bi) {
  if (span_eq(ro, a, b)) return ORD_EQUAL;
  if (fix_tighter(ro, ai, bi)) return ORD_TIGHTER;
  if (fix_tighter(ro, bi, ai)) return ORD_LOOSER;
  return ORD_INCOMPARABLE;
}

static void diag_undeclared(RO *ro, WokSpan name) {
  wok_diag_add(ro->d, WOK_E_FIXITY, name.off, name.len,
              "`%.*s` has no `fixity` declaration; reorder mode cannot place "
              "it in a chain without one",
              SPAN(ro, name));
}

static void diag_neighbour_only(RO *ro, WokSpan name) {
  wok_diag_add(ro->d, WOK_E_FIXITY, name.off, name.len,
              "`%.*s` is named only as another operator's neighbour and has "
              "no `fixity` declaration of its own",
              SPAN(ro, name));
}

// checkNeighbors, transliterated: a whole-table scan, run ONCE before any
// chain is visited (see the file header). Every placeholder gets its own
// diagnostic -- Haskell's buildFixityTable collects one UnresolvedNeighbor
// per offending relation, and a batch here is truer to that than stopping at
// the first. The anchor is the placeholder's own name span: Haskell anchors
// at the DECLARING head's position instead, but the verdict-level contract
// (spec: "chain-level agreement on the message is NOT required, only the
// verdict") does not ask the two to match spans, and the placeholder's own
// span is the only position this table actually retains for it.
static bool check_neighbours(RO *ro) {
  bool ok = true;
  for (u32 i = 0; i < ro->fix->n; i++) {
    if (ro->fix->ops[i].decl_off != UINT32_MAX) continue;
    diag_neighbour_only(ro, ro->fix->ops[i].name);
    ok = false;
  }
  return ok;
}

// The wording shape check_chain uses for its E-FIXITY: both occurrences
// quoted with their own line:col, so the reader does not have to hunt the
// other end of a long chain. The "shield" clause of check_chain's message
// does not apply here -- this fault comes from the greedy scan finding two
// occurrences with no order between them at all, not from a missing looser
// operator between two related ones -- so the repair advice is the general
// one: bracket, or declare an order.
static void diag_incomparable(RO *ro, WokSpan best, WokSpan cur) {
  u32 bl = 0, bc = 0, cl = 0, cc = 0;
  wok_diag_position(ro->d, best.off, &bl, &bc);
  wok_diag_position(ro->d, cur.off, &cl, &cc);
  wok_diag_add(ro->d, WOK_E_FIXITY, cur.off, cur.len,
              "`%.*s` (%u:%u) and `%.*s` (%u:%u) have no declared order: "
              "bracket the chain, or relate them with `tighter than`",
              SPAN(ro, best), bl, bc, SPAN(ro, cur), cl, cc);
}

// findLoosest, transliterated. Returns UINT32_MAX when the scan hit an
// incomparable pair -- the diagnostic already fired, and the caller's job is
// only to stop, not to guess a split point a fault has no good answer for.
static u32 find_loosest(RO *ro, const Tail *tails, u32 n) {
  u32 best = 0;
  for (u32 i = 1; i < n; i++) {
    Order ord = compare_ops(ro, tails[i].name, tails[i].fix_idx,
                             tails[best].name, tails[best].fix_idx);
    switch (ord) {
      case ORD_TIGHTER:
        break;  // the running loosest stands
      case ORD_LOOSER:
        best = i;
        break;
      case ORD_EQUAL:
        // Equal means the SAME operator (no cross-operator equivalence
        // classes), so its own declared associativity settles the tie:
        // left-assoc takes the rightmost occurrence scanned so far,
        // right-assoc keeps the leftmost.
        if (ro->fix->ops[tails[best].fix_idx].assoc == WOK_ASSOC_LEFT)
          best = i;
        break;
      case ORD_INCOMPARABLE:
        diag_incomparable(ro, tails[best].name, tails[i].name);
        return UINT32_MAX;
    }
  }
  return best;
}

// combineInfix, transliterated (see the file header for why there is no
// EParen step). The synthesized span covers the operands, leftmost start to
// rightmost end, so a diagnostic raised against this node downstream still
// points somewhere sane.
static WokNode *combine_infix(RO *ro, WokNode *lhs, WokSpan op, bool backtick,
                              WokNode *rhs) {
  u32 start = lhs->off;
  u32 end = rhs->off + rhs->len;
  WokNode *opn = wok_node(ro->a, H_ChainOp, op.off, end - op.off);
  H_ChainOp_set_op(opn, op);
  H_ChainOp_set_backtick(opn, backtick);
  H_ChainOp_set_rhs(opn, rhs);
  WokNode *chain = wok_node(ro->a, E_Chain, start, end - start);
  E_Chain_set_head(chain, lhs);
  WokNode *one_op[1] = {opn};
  E_Chain_set_ops(chain, wok_seq(ro->a, one_op, 1));
  return chain;
}

// reorderChain's split-and-recurse, transliterated: find the loosest,
// splitAt there, recurse into both halves over the SAME flat array (never a
// tree already rebuilt by an earlier split), rebuild. A single-tail slice
// still goes through find_loosest (a no-op scan, best = 0) rather than being
// special-cased -- which is exactly why a one-op chain "already resolved"
// needs no separate code path (see wok_reorder.h / the spec's note on it).
static WokNode *reorder_split(RO *ro, WokNode *h, const Tail *tails, u32 n) {
  if (n == 0) return h;
  u32 idx = find_loosest(ro, tails, n);
  if (idx == UINT32_MAX) return h;
  WokNode *left = reorder_split(ro, h, tails, idx);
  const Tail *split = &tails[idx];
  WokNode *right = reorder_split(ro, split->rhs, tails + idx + 1, n - idx - 1);
  return combine_infix(ro, left, split->name, split->backtick, right);
}

// checkDeclared, transliterated, over every occurrence in the chain -- one
// fault per chain (the codebase's convention, matching check_chain's "one
// chain, one fault"), then find_loosest runs on the validated tails. `n`'s
// head and every op's rhs have already been reordered by the caller.
//
// NO placeholder check here: check_neighbours already rejected the whole
// file, before this walk started, if the table held ANY entry with
// decl_off == UINT32_MAX. So an `idx` reaching this point past the
// no-entry-at-all check names an operator with a winning `fixity`
// declaration of its own -- "known but only as a neighbour" cannot occur by
// the time any chain is visited.
static WokNode *reorder_chain(RO *ro, WokNode *n) {
  WokSeq ops = E_Chain_ops(n);
  Tail *tails = ops.n ? WOK_NEW_N(ro->a, Tail, ops.n) : nullptr;
  for (u32 i = 0; i < ops.n; i++) {
    WokNode *op = ops.items[i];
    WokSpan name = H_ChainOp_op(op);
    u32 idx = fix_find(ro, name);
    if (idx == UINT32_MAX) {
      diag_undeclared(ro, name);
      return n;
    }
    tails[i] = (Tail){.name = name, .backtick = H_ChainOp_backtick(op),
                      .rhs = H_ChainOp_rhs(op), .fix_idx = idx};
  }
  return reorder_split(ro, E_Chain_head(n), tails, ops.n);
}

static WokNode *reorder_node(RO *ro, WokNode *n);

// The copy-on-write invariant, in one place: the fresh slot block is
// allocated on the FIRST child that actually changes, and starts as a byte
// copy of the original so untouched siblings keep their slots. Both slot
// walkers below write through this, so the allocate-before-first-write
// rule cannot drift between them.
static WokSlot *ensure_fresh(RO *ro, const WokNode *n, WokSlot **fresh) {
  if (!*fresh) {
    *fresh = WOK_NEW_N(ro->a, WokSlot, n->nslots);
    memcpy(*fresh, n->slot, (usize)n->nslots * sizeof(WokSlot));
  }
  return *fresh;
}

// A node's own NODE/OPT field, reordered; a subtree fixity never touches
// costs nothing beyond the pointer comparisons.
static void reorder_child_slot(RO *ro, WokNode *n, WokSlot **fresh, u16 i) {
  WokNode *child = n->slot[i].node;
  WokNode *rebuilt = reorder_node(ro, child);
  if (rebuilt == child) return;
  ensure_fresh(ro, n, fresh)[i].node = rebuilt;
}

static void reorder_seq_slot(RO *ro, WokNode *n, WokSlot **fresh, u16 i) {
  WokSeq q = wok_seq_unpack(n->slot[i].seq);
  WokNode **rebuilt = nullptr;
  for (u32 j = 0; j < q.n; j++) {
    WokNode *r = reorder_node(ro, q.items[j]);
    if (r == q.items[j]) continue;
    if (!rebuilt) {
      rebuilt = WOK_NEW_N(ro->a, WokNode *, q.n);
      memcpy(rebuilt, q.items, (usize)q.n * sizeof(WokNode *));
    }
    rebuilt[j] = r;
  }
  if (!rebuilt) return;
  ensure_fresh(ro, n, fresh)[i].seq = wok_seq(ro->a, rebuilt, q.n).items;
}

// The generic bottom-up walk. Every NODE/OPT/SEQ child is visited regardless
// of the FAMILY it demands -- a type or a pattern can never hold an E_Chain,
// so recursing into one is a guaranteed no-op, and that is cheaper to accept
// than to hand-enumerate every EXPR-bearing field the schema has (which is
// what the spec's "everything that can contain an E_Chain" is asking for: no
// construct is special-cased into or out of this walk). NAME/TEXT/INT/FLAG
// hold no child. No `default:` -- WOK_FIELD_CLASS_COUNT is listed so a field
// class added later fails the build here, the same discipline wok_resolve.c
// uses in sc_node.
static WokNode *reorder_node(RO *ro, WokNode *n) {
  if (!n) return nullptr;
  const WokNodeDesc *desc = &wok_node_desc[n->tag];
  WokSlot *fresh = nullptr;
  for (u16 i = 0; i < desc->nfields; i++) {
    switch (desc->fields[i].cls) {
      case WFC_NODE:
      case WFC_OPT:
        reorder_child_slot(ro, n, &fresh, i);
        break;
      case WFC_SEQ:
        reorder_seq_slot(ro, n, &fresh, i);
        break;
      case WFC_NAME:
      case WFC_TEXT:
      case WFC_INT:
      case WFC_FLAG:
      case WOK_FIELD_CLASS_COUNT:
        break;
    }
  }
  WokNode *base = n;
  if (fresh) {
    base = wok_node(ro->a, (WokTag)n->tag, n->off, n->len);
    memcpy(base->slot, fresh, (usize)n->nslots * sizeof(WokSlot));
  }
  if (base->tag == E_Chain) return reorder_chain(ro, base);
  return base;
}

const WokNode *wok_reorder(const WokNode *file, const char *src, WokArena *a,
                           WokDiagSink *d, const WokFixTable *fix) {
  RO ro = {.fix = fix, .src = src, .a = a, .d = d};
  // Table first, tree second (see the file header): a placeholder anywhere
  // in the table faults the whole file before a single node is walked, the
  // same way Haskell's buildFixityTable fails before reorderAst runs at all.
  if (!check_neighbours(&ro)) return file;
  return reorder_node(&ro, (WokNode *)file);
}
