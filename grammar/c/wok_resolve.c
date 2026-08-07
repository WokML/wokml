// wok_resolve -- see wok_resolve.h.

#include "wok_resolve.h"

#include <stdarg.h>
#include <string.h>

// ---------------------------------------------------------- the effect table
//
// Two passes over the file's declarations: count, then fill. The alternative,
// a growable buffer, would buy nothing -- a file's effects are all declared
// before anything is checked, so there is no incremental case to serve.

typedef struct {
  WokSpan name;
  u32 arity;
  bool known;  // false when the type goes through something this file
               // cannot expand -- then the count would be a guess, so no
               // clause is checked against it
} Op;

// A same-file `alias` can put arrows behind a name (`alias Setter = U64 ->
// ()`), so the arity walk must see through it or a correct clause gets a
// confidently wrong count.
typedef struct {
  WokSpan name;
  const WokNode *body;
  bool nullary;  // only a parameterless alias is expandable by substitution
} Alias;

typedef struct {
  WokSpan name;
  Op *ops;
  u32 nops;
} Eff;

// ---------------------------------------------------------- the fixity table
//
// wok's fixity is a PARTIAL ORDER, not a ladder of numbered levels: `fixity *
// left tighter than +` states one edge, and two operators with no path
// between them are INCOMPARABLE -- which is a fault at the use site, never a
// tie broken by a default. `Equal` means the same operator, so associativity
// only ever settles a run of one.
//
// The order is stored as a bit matrix and closed ONCE with Warshall, rather
// than answered per query by a graph search. That is not for speed at this
// size; it is because the closure answers the two questions this stage has
// with the same bits. Comparison is `bit(a,b)` / `bit(b,a)`, and a CYCLE is
// `bit(a,a)` -- a node that reaches itself -- so the circularity check needs
// no second algorithm and self-reference is just its one-node case.
// FixOp is WokFixTable's element type (wok_resolve.h): the table this stage
// builds IS the handle the reorder pass consults, so there is one struct, not
// a private one shaped like a public one. `decl_off` doubles as "where it was
// declared" for the already-has-a-fixity diagnostic below.
typedef WokFixOp FixOp;

typedef struct {
  FixOp *ops;
  u32 n;
  u64 *edge;   // n rows of `words` u64s; bit (i,j) = i binds tighter than j
  u32 words;
} Fix;

// ------------------------------------------------------------- name index
//
// The three declaration tables (effects, fixity operators, aliases) used to
// be searched by linear scan. Fine at hand-written sizes, QUADRATIC the
// moment a table grows with the file: a 20k-effect file spent three quarters
// of its whole runtime in find_effect's memcmps. One small open-addressing
// index serves all three -- FNV-1a over the name's bytes, power-of-two
// capacity at load <= 1/2 (so probing always terminates), parallel key/entry
// arrays, and no deletion because nothing is ever removed from a table.
// "First declaration wins" holds by construction: a name is added only when
// it is not already present.
typedef struct {
  WokSpan *key;  // key[k] = the name stored at slot k
  u32 *entry;    // entry[k] = index into the backing table; UINT32_MAX free
  u32 mask;
} NameIdx;

typedef struct {
  const char *src;
  WokDiagSink *d;
  const WokNode *file;
  WokArena *arena;
  Eff *effs;
  u32 neffs;
  Alias *aliases;
  u32 naliases;
  Fix fix;
  NameIdx eff_idx;
  NameIdx fix_idx;
  NameIdx alias_idx;
  const char *fix_note;  // the declared order, rendered once on first fault
} R;

static bool fix_bit(const Fix *f, u32 i, u32 j) {
  return (f->edge[(usize)i * f->words + j / 64] >> (j % 64) & 1u) != 0;
}

static void fix_set(Fix *f, u32 i, u32 j) {
  f->edge[(usize)i * f->words + j / 64] |= UINT64_C(1) << (j % 64);
}

static bool span_eq(const R *r, WokSpan a, WokSpan b) {
  return a.len == b.len && memcmp(r->src + a.off, r->src + b.off, a.len) == 0;
}

static u32 name_hash(const R *r, WokSpan s) {
  u32 h = 2166136261u;  // FNV-1a
  for (u32 i = 0; i < s.len; i++) {
    h ^= (unsigned char)r->src[s.off + i];
    h *= 16777619u;
  }
  return h;
}

// max_entries is an UPPER BOUND known before any insert (every table counts
// its declarations first), so capacity is fixed and there is no rehash.
static void idx_init(NameIdx *ix, WokArena *a, u32 max_entries) {
  u32 cap = 8;
  while (cap < max_entries * 2) cap *= 2;
  ix->key = WOK_NEW_N(a, WokSpan, cap);
  ix->entry = WOK_NEW_N(a, u32, cap);
  ix->mask = cap - 1;
  for (u32 i = 0; i < cap; i++) ix->entry[i] = UINT32_MAX;
}

static u32 idx_find(const R *r, const NameIdx *ix, WokSpan name) {
  for (u32 k = name_hash(r, name) & ix->mask;; k = (k + 1) & ix->mask) {
    if (ix->entry[k] == UINT32_MAX) return UINT32_MAX;
    if (span_eq(r, ix->key[k], name)) return ix->entry[k];
  }
}

// The caller has already established absence (every table does a find first,
// because a duplicate is either reported or skipped before anything is
// added), so this only claims a free slot.
static void idx_add(const R *r, NameIdx *ix, WokSpan name, u32 entry) {
  u32 k = name_hash(r, name) & ix->mask;
  while (ix->entry[k] != UINT32_MAX) k = (k + 1) & ix->mask;
  ix->key[k] = name;
  ix->entry[k] = entry;
}

// A NAME span quoted into a message. Spans view the source and are not
// NUL-terminated, so every message that names something goes through `%.*s`.
#define SPAN(r, s) (int)(s).len, (r)->src + (s).off

static void build_aliases(R *r, const WokNode *file, WokArena *a) {
  WokSeq decls = W_File_decls(file);
  u32 n = 0;
  for (u32 i = 0; i < decls.n; i++)
    if (decls.items[i]->tag == D_Alias) n++;
  r->naliases = 0;
  r->aliases = n ? WOK_NEW_N(a, Alias, n) : nullptr;
  idx_init(&r->alias_idx, a, n);
  for (u32 i = 0; i < decls.n; i++) {
    const WokNode *d = decls.items[i];
    if (d->tag != D_Alias) continue;
    WokSpan name = D_Alias_name(d);
    // First declaration wins, as everywhere: a redeclared alias is skipped.
    if (idx_find(r, &r->alias_idx, name) != UINT32_MAX) continue;
    idx_add(r, &r->alias_idx, name, r->naliases);
    r->aliases[r->naliases++] =
        (Alias){.name = name, .body = D_Alias_body(d),
                .nullary = D_Alias_params(d).n == 0};
  }
}

// The single unqualified name a T_Con spells, or a zero span. A qualified
// path is left alone: it cannot name a same-file alias.
static WokSpan tcon_bare_name(const WokNode *t) {
  const WokNode *path = T_Con_path(t);
  if (path && path->tag == N_ModPath) {
    WokSeq parts = N_ModPath_parts(path);
    if (parts.n == 1 && parts.items[0]->tag == N_Name)
      return N_Name_text(parts.items[0]);
  }
  return wok_span(0, 0);
}

static const Alias *find_alias(const R *r, WokSpan name) {
  if (name.len == 0) return nullptr;
  u32 i = idx_find(r, &r->alias_idx, name);
  return i == UINT32_MAX ? nullptr : &r->aliases[i];
}

// The op's ARITY is the length of its type's arrow spine. `get : s` takes
// none, `set : s -> ()` takes one, and `call : (U64 -> U64) -> U64` takes one
// -- the argument's own arrow is inside a bracket, so it is not on the spine,
// which is exactly the distinction reject/02 turns on.
//
// A row (`op : a -> b with E`) or a context (`Eq a => ...`) wraps the type
// without changing its spine, so both are stepped through rather than
// counted. A terminal that names a same-file parameterless alias is expanded
// and the walk continues -- the alias may hide more arrows. A parameterized
// or applied alias would need substitution to expand, so the arity is
// UNKNOWN (false) and the caller checks nothing: a skipped check is the
// partial-knowledge answer, a guessed count is a wrong E-ARITY on valid
// code. The fuel bounds alias cycles (`alias A = A`), which also come out
// unknown rather than hanging the walk.
static bool arrow_arity(const R *r, const WokNode *t, u32 *out) {
  u32 n = 0;
  u32 fuel = 32;
  while (t) {
    if (t->tag == T_Fun) {
      n++;
      t = T_Fun_to(t);
    } else if (t->tag == T_With) {
      t = T_With_body(t);
    } else if (t->tag == T_Qual) {
      t = T_Qual_body(t);
    } else {
      const WokNode *head = t;
      bool applied = false;
      while (head && head->tag == T_App) {
        head = T_App_fn(head);
        applied = true;
      }
      const Alias *al = head && head->tag == T_Con
                            ? find_alias(r, tcon_bare_name(head))
                            : nullptr;
      if (!al) break;  // a data type: the spine ends here
      if (applied || !al->nullary || fuel-- == 0) return false;
      t = al->body;
    }
  }
  *out = n;
  return true;
}

static Eff *find_effect_mut(R *r, WokSpan name) {
  u32 i = idx_find(r, &r->eff_idx, name);
  return i == UINT32_MAX ? nullptr : &r->effs[i];
}

// TWO NAMESPACES, and the table's shape says which is which. An EFFECT name
// is global to the file, so a second declaration of it is a redeclaration.
// An OP name is scoped INSIDE its effect -- it is reached as `State.get`, or
// ambiently through a label that names the effect -- so `State.get` and
// `Reader.get` are two different ops that happen to share a spelling, and
// nothing here compares one effect's ops against another's.
//
// The duplicate is reported and DROPPED rather than appended, which is what
// makes "first declaration wins" a property of the table rather than of the
// order find_effect happens to scan in.
static void build_table(R *r, const WokNode *file, WokArena *a) {
  WokSeq decls = W_File_decls(file);
  u32 n = 0;
  for (u32 i = 0; i < decls.n; i++)
    if (decls.items[i]->tag == D_Effect) n++;
  r->neffs = 0;
  r->effs = n ? WOK_NEW_N(a, Eff, n) : nullptr;
  idx_init(&r->eff_idx, a, n);
  for (u32 i = 0; i < decls.n; i++) {
    const WokNode *d = decls.items[i];
    if (d->tag != D_Effect) continue;
    WokSpan name = D_Effect_name(d);
    const Eff *first = find_effect_mut(r, name);
    if (first) {
      u32 line = 0, col = 0;
      wok_diag_position(r->d, first->name.off, &line, &col);
      wok_diag_add(r->d, WOK_E_DUPLICATE, name.off, name.len,
                   "effect `%.*s` is already declared at %u:%u", SPAN(r, name),
                   line, col);
      continue;
    }
    WokSeq ops = D_Effect_ops(d);
    idx_add(r, &r->eff_idx, name, r->neffs);
    Eff *e = &r->effs[r->neffs++];
    e->name = name;
    e->nops = 0;
    e->ops = ops.n ? WOK_NEW_N(a, Op, ops.n) : nullptr;
    for (u32 j = 0; j < ops.n; j++) {
      if (ops.items[j]->tag != H_OpSig) continue;
      Op *op = &e->ops[e->nops++];
      op->name = H_OpSig_name(ops.items[j]);
      op->arity = 0;
      op->known = arrow_arity(r, H_OpSig_type(ops.items[j]), &op->arity);
    }
  }
}

static const Eff *find_effect(const R *r, WokSpan name) {
  u32 i = idx_find(r, &r->eff_idx, name);
  return i == UINT32_MAX ? nullptr : &r->effs[i];
}

// ------------------------------------------------------- fixity, built once

// Operator identity is the SPELLING, and `alpha` is not part of it: an
// identifier and a symbol run are drawn from disjoint character sets, so two
// operators that spell the same are the same operator, whichever way they
// were written.
static u32 fix_find(const R *r, WokSpan name) {
  // Guarded: build_fixity returns before initialising the index when the
  // file declares no fixity at all, and use sites still ask.
  if (r->fix.n == 0) return UINT32_MAX;
  return idx_find(r, &r->fix_idx, name);
}

// The WINNER predicate, in one place: whether this `fixity` declaration is
// the one the table kept (a dropped duplicate contributes nothing). Pass 2's
// edges and the diagnostic's printed table both ask THIS function, because
// "the table printed is the table consulted" is only a guarantee while the
// two cannot drift -- and F5 is already specced to change this rule to an
// origin-keyed merge, which must then change it for both askers at once.
static bool fix_is_winner(const R *r, const WokNode *d) {
  u32 head = fix_find(r, D_Fixity_name(d));
  return head != UINT32_MAX &&
         r->fix.ops[head].decl_off == D_Fixity_name(d).off;
}

static void build_fixity(R *r, const WokNode *file, WokArena *a) {
  WokSeq decls = W_File_decls(file);
  u32 cap = 0;
  for (u32 i = 0; i < decls.n; i++) {
    if (decls.items[i]->tag != D_Fixity) continue;
    cap += 1 + D_Fixity_rels(decls.items[i]).n;  // the head, and every neighbour
  }
  if (cap == 0) return;
  r->fix.ops = WOK_NEW_N(a, FixOp, cap);
  r->fix.n = 0;
  idx_init(&r->fix_idx, a, cap);

  // Pass 1: every operator NAMED anywhere by a WINNING declaration gets an
  // index, so a relation can point at one declared later in the file. Only a
  // `fixity` head carries an associativity; a name that appears solely as a
  // neighbour is a placeholder and stays out of the redeclaration check.
  //
  // A dropped duplicate contributes NOTHING -- not edges (pass 2), and not
  // placeholders either: a neighbour named only by the loser would otherwise
  // sit in the table edge-less, read as known-but-incomparable at use sites
  // the winner's table would leave unknown and skip.
  for (u32 i = 0; i < decls.n; i++) {
    const WokNode *d = decls.items[i];
    if (d->tag != D_Fixity) continue;
    WokSpan name = D_Fixity_name(d);
    u32 at = fix_find(r, name);
    if (at != UINT32_MAX && r->fix.ops[at].decl_off != UINT32_MAX) {
      u32 line = 0, col = 0;
      wok_diag_position(r->d, r->fix.ops[at].decl_off, &line, &col);
      wok_diag_add(r->d, WOK_E_DUPLICATE, name.off, name.len,
                   "operator `%.*s` already has a fixity at %u:%u",
                   SPAN(r, name), line, col);
      continue;
    }
    if (at != UINT32_MAX) {
      r->fix.ops[at].assoc = D_Fixity_assoc(d);
      r->fix.ops[at].decl_off = name.off;
    } else {
      idx_add(r, &r->fix_idx, name, r->fix.n);
      r->fix.ops[r->fix.n++] = (FixOp){.name = name,
                                       .assoc = D_Fixity_assoc(d),
                                       .decl_off = name.off};
    }
    WokSeq rels = D_Fixity_rels(d);
    for (u32 j = 0; j < rels.n; j++) {
      WokSpan nb = H_FixRel_name(rels.items[j]);
      if (fix_find(r, nb) != UINT32_MAX) continue;
      idx_add(r, &r->fix_idx, nb, r->fix.n);
      r->fix.ops[r->fix.n++] =
          (FixOp){.name = nb, .assoc = WOK_ASSOC_LEFT, .decl_off = UINT32_MAX};
    }
  }

  // Pass 2: the edges. `a tighter than b` and `b looser than a` are the same
  // edge stated from opposite ends, which is why the sense is recorded rather
  // than normalised away at parse time -- the spelling is the author's.
  r->fix.words = (r->fix.n + 63) / 64;
  r->fix.edge = WOK_NEW_N(a, u64, (usize)r->fix.n * r->fix.words);
  for (usize i = 0; i < (usize)r->fix.n * r->fix.words; i++) r->fix.edge[i] = 0;
  for (u32 i = 0; i < decls.n; i++) {
    const WokNode *d = decls.items[i];
    if (d->tag != D_Fixity) continue;
    // A dropped duplicate's edges die with it: first declaration wins the
    // EDGES, not only the associativity, which is what the E-DUPLICATE
    // message promised.
    if (!fix_is_winner(r, d)) continue;
    u32 head = fix_find(r, D_Fixity_name(d));
    WokSeq rels = D_Fixity_rels(d);
    for (u32 j = 0; j < rels.n; j++) {
      u32 nb = fix_find(r, H_FixRel_name(rels.items[j]));
      if (nb == UINT32_MAX) continue;
      if (H_FixRel_sense(rels.items[j]) == WOK_FIXREL_TIGHTER)
        fix_set(&r->fix, head, nb);
      else
        fix_set(&r->fix, nb, head);
    }
  }

  // Warshall, one row-OR per (k, i): if i reaches k, i reaches everything k
  // does. O(n^3/64) on words, over an n that is the operator count of one
  // file.
  for (u32 k = 0; k < r->fix.n; k++)
    for (u32 i = 0; i < r->fix.n; i++) {
      if (!fix_bit(&r->fix, i, k)) continue;
      for (u32 w = 0; w < r->fix.words; w++)
        r->fix.edge[(usize)i * r->fix.words + w] |=
            r->fix.edge[(usize)k * r->fix.words + w];
    }
}

// A fixity fault carries the order the checker was using, as continuation
// lines: one verbatim source slice per WINNING `fixity` declaration, in
// declaration order. Verbatim, because the table printed must be the table
// consulted -- the author's own spelling of `tighter`/`looser`, and a
// dropped duplicate absent because it is not in the table. Built once per
// file, on the first fault; fault-free files never pay for it.
static const char *fixity_note(R *r) {
  if (r->fix_note) return r->fix_note;
  static const char header[] = "\n  the order this file declares:";
  static const char nb[] = " (named only as a neighbour)";
  // The WALK happens once, into line records; measuring and filling are then
  // dumb loops over the records, so the winner predicate and the byte
  // accounting cannot drift apart. A line is the verbatim source of one
  // winning declaration, or -- because the table printed must be everything
  // the table knows -- the bare name of an operator known only from someone
  // else's `tighter than` clause, marked as such.
  typedef struct {
    WokSpan text;
    bool neighbour;
  } Line;
  WokSeq decls = W_File_decls(r->file);
  Line *lines = WOK_NEW_N(r->arena, Line, decls.n + r->fix.n);
  u32 nlines = 0;
  for (u32 i = 0; i < decls.n; i++) {
    const WokNode *d = decls.items[i];
    if (d->tag != D_Fixity) continue;
    if (!fix_is_winner(r, d)) continue;
    lines[nlines++] = (Line){.text = wok_span(d->off, d->len),
                             .neighbour = false};
  }
  for (u32 i = 0; i < r->fix.n; i++)
    if (r->fix.ops[i].decl_off == UINT32_MAX)
      lines[nlines++] = (Line){.text = r->fix.ops[i].name, .neighbour = true};

  usize len = sizeof header - 1;
  for (u32 i = 0; i < nlines; i++)
    len += 5 + lines[i].text.len + (lines[i].neighbour ? sizeof nb - 1 : 0);
  char *note = WOK_NEW_N(r->arena, char, len + 1);
  usize at = sizeof header - 1;
  memcpy(note, header, at);
  for (u32 i = 0; i < nlines; i++) {
    memcpy(note + at, "\n    ", 5);
    memcpy(note + at + 5, r->src + lines[i].text.off, lines[i].text.len);
    at += 5 + lines[i].text.len;
    if (lines[i].neighbour) {
      memcpy(note + at, nb, sizeof nb - 1);
      at += sizeof nb - 1;
    }
  }
  note[at] = '\0';
  r->fix_note = note;
  return note;
}

// An E-FIXITY with the note appended. The head is bounded (a message and at
// most a ring of names); the note is not, so the assembled message goes to
// the sink through the non-formatting path rather than a format buffer.
WOK_PRINTF(4, 5)
static void diag_fixity(R *r, u32 off, u32 len, const char *fmt, ...) {
  char head[768];
  va_list ap;
  va_start(ap, fmt);
  (void)vsnprintf(head, sizeof head, fmt, ap);
  va_end(ap);
  const char *note = fixity_note(r);
  usize nhead = strlen(head), nnote = strlen(note);
  char *msg = WOK_NEW_N(r->arena, char, nhead + nnote + 1);
  memcpy(msg, head, nhead);
  memcpy(msg + nhead, note, nnote + 1);
  wok_diag_add_text(r->d, WOK_E_FIXITY, off, len, msg);
}

// A CYCLE is a node that reaches itself, and the closure has already found
// every one. Reported once per cycle rather than once per member -- at the
// member declared first -- and the whole ring is named, because "`a` is
// circular" without the rest of it is not a repair.
static void check_fixity_cycles(R *r) {
  const Fix *f = &r->fix;
  for (u32 i = 0; i < f->n; i++) {
    if (!fix_bit(f, i, i)) continue;
    bool first = true;
    for (u32 j = 0; j < i; j++)
      if (fix_bit(f, j, j) && fix_bit(f, i, j) && fix_bit(f, j, i)) first = false;
    if (!first) continue;
    // The ring is listed in declaration order, not walked as a path: the
    // closure knows WHICH operators are mutually reachable and no longer
    // knows by what route, and a made-up route would be a worse answer than
    // the set.
    char ring[256];
    usize at = 0;
    u32 members = 0;
    for (u32 j = 0; j < f->n && at + 2 < sizeof ring; j++) {
      if (j != i && !(fix_bit(f, i, j) && fix_bit(f, j, i))) continue;
      members++;
      int put = snprintf(ring + at, sizeof ring - at, "%s`%.*s`",
                         at == 0 ? "" : ", ", SPAN(r, f->ops[j].name));
      if (put < 0) break;
      at += (usize)put;
    }
    if (members <= 1)
      diag_fixity(r, f->ops[i].name.off, f->ops[i].name.len,
                  "`%.*s` is declared tighter than itself",
                  SPAN(r, f->ops[i].name));
    else
      diag_fixity(r, f->ops[i].name.off, f->ops[i].name.len,
                  "the fixity order is circular through %s, so no operator in "
                  "it is loosest",
                  ring);
  }
}

static const Op *find_op(const R *r, const Eff *e, WokSpan name) {
  for (u32 i = 0; i < e->nops; i++)
    if (span_eq(r, e->ops[i].name, name)) return &e->ops[i];
  return nullptr;
}

// ------------------------------------------------------------ clause arities
//
// The count compared is the PATTERN count, one per argument position before
// any destructuring, for every clause kind alike -- that is what C8's second
// amendment buys, and it is why the continuation lives outside `pats`.

static const char *kind_word(u64 kind) {
  if (kind == WOK_CLAUSE_CONTROL) return "control";
  if (kind == WOK_CLAUSE_ABORT) return "abort";
  return "plain";
}

static void check_arity(const R *r, const WokNode *clause, const Op *op) {
  u64 kind = H_Clause_kind(clause);
  WokSpan name = H_Clause_name(clause);
  u32 got = H_Clause_pats(clause).n;
  if (got == op->arity) return;

  // A count of one gets a singular noun. It is one conditional, and a
  // message that says "binds 1 names" reads as a tool that was not finished.
  const char *plural = op->arity == 1 ? "" : "s";
  const char *bound = got == 1 ? "" : "s";
  if (kind == WOK_CLAUSE_ABORT) {
    // The mechanical mis-migration: the keyword swapped to `abort` and the v1
    // continuation binder kept. Naming what abort does NOT bind is the whole
    // repair, so it is in the message rather than a hint (reject/12).
    wok_diag_add(r->d, WOK_E_ARITY, name.off, name.len,
                 "`abort %.*s` binds %u name%s but needs %u (%u argument%s; "
                 "abort binds no continuation)",
                 SPAN(r, name), got, bound, op->arity, op->arity, plural);
    return;
  }
  if (kind == WOK_CLAUSE_CONTROL) {
    wok_diag_add(r->d, WOK_E_ARITY, name.off, name.len,
                 "control clause `%.*s` binds %u name%s before the `,` but "
                 "the op takes %u argument%s; the continuation is the name "
                 "after it",
                 SPAN(r, name), got, bound, op->arity, plural);
    return;
  }
  // A comma-less head is a plain clause, full stop (D25) -- so a v1 control
  // arm arrives here as a plain one binding a name too many, and the hint is
  // the edit that makes it the control clause it was meant to be.
  if (got == op->arity + 1)
    wok_diag_add(r->d, WOK_E_ARITY, name.off, name.len,
                 "plain clause `%.*s` binds %u name%s but the op takes %u "
                 "argument%s; for the control reading write `,` before the "
                 "last one",
                 SPAN(r, name), got, bound, op->arity, plural);
  else
    wok_diag_add(r->d, WOK_E_ARITY, name.off, name.len,
                 "plain clause `%.*s` binds %u name%s but the op takes %u "
                 "argument%s",
                 SPAN(r, name), got, bound, op->arity, plural);
}

// Clauses for ONE op may be several, with refutable patterns, and they
// desugar to one clause plus a `case` (D14). That merge is only meaningful if
// they agree on what the arm DOES: plain arms auto-resume, control and abort
// arms do not, and no desugaring reconciles the two.
static void check_kind_agreement(const R *r, const WokNode *handler) {
  WokSeq cs = E_Handler_clauses(handler);
  for (u32 i = 0; i < cs.n; i++) {
    const WokNode *a = cs.items[i];
    if (a->tag != H_Clause) continue;
    u64 ka = H_Clause_kind(a);
    if (ka == WOK_CLAUSE_VAR || ka == WOK_CLAUSE_RETURN) continue;
    // Only the FIRST clause of an op speaks for it: one op, one fault, not
    // one per later clause of the other kind.
    bool first = true;
    for (u32 h = 0; h < i && first; h++) {
      const WokNode *e = cs.items[h];
      if (e->tag != H_Clause) continue;
      u64 ke = H_Clause_kind(e);
      if (ke == WOK_CLAUSE_VAR || ke == WOK_CLAUSE_RETURN) continue;
      if (span_eq(r, H_Clause_name(e), H_Clause_name(a))) first = false;
    }
    if (!first) continue;
    for (u32 j = i + 1; j < cs.n; j++) {
      const WokNode *b = cs.items[j];
      if (b->tag != H_Clause) continue;
      u64 kb = H_Clause_kind(b);
      if (kb == WOK_CLAUSE_VAR || kb == WOK_CLAUSE_RETURN) continue;
      if (!span_eq(r, H_Clause_name(a), H_Clause_name(b))) continue;
      bool plain_a = ka == WOK_CLAUSE_PLAIN;
      bool plain_b = kb == WOK_CLAUSE_PLAIN;
      if (plain_a == plain_b) continue;
      WokSpan at = H_Clause_name(b);
      wok_diag_add(r->d, WOK_E_ARITY, at.off, at.len,
                   "the clauses for `%.*s` disagree: this one is %s and an "
                   "earlier one is %s -- they merge into one arm, so they "
                   "cannot resume differently",
                   SPAN(r, at), kind_word(kb), kind_word(ka));
      break;
    }
  }
}

static void check_handler(const R *r, const WokNode *handler) {
  const Eff *e = find_effect(r, E_Handler_effect(handler));
  // An UNDECLARED effect, and an op the effect does not declare, are both
  // name-resolution faults that spec.md's registry has no code for. Reporting
  // them under a code invented here would put a spelling into machine-readable
  // output that the registry would then have to adopt or break, so the checks
  // wait on that decision rather than guessing (see the slice spec, section 2).
  if (!e) return;
  check_kind_agreement(r, handler);
  WokSeq cs = E_Handler_clauses(handler);
  for (u32 i = 0; i < cs.n; i++) {
    const WokNode *c = cs.items[i];
    if (c->tag != H_Clause) continue;
    u64 kind = H_Clause_kind(c);
    if (kind == WOK_CLAUSE_VAR || kind == WOK_CLAUSE_RETURN) continue;
    const Op *op = find_op(r, e, H_Clause_name(c));
    if (op && op->known) check_arity(r, c, op);
  }
}

// -------------------------------------------------------- fixity, at the use
//
// THE SHIELD RULE. A chain means what the split rule says: find the loosest
// operator, split there, recurse -- well-formed iff every subchain visited
// has a unique loosest. That recursive condition collapses into a local one:
// an incomparable pair of operator OCCURRENCES is licensed iff some
// occurrence positionally BETWEEN them is strictly looser than both (a
// SHIELD -- the split there separates the pair before they ever compete).
// So `2 * 3 + 8 / 4` is fine with `*` and `/` unrelated, and `2 * 3 / 4 + 8`
// is not: same operators, and the position is the difference. Per occurrence
// pair, not per distinct pair -- in `a * b + c * d / e` only the first `*`
// is shielded, and the split genuinely gets stuck on the right segment.
//
// PARTIAL KNOWLEDGE. An operator with no entry is SKIPPED, not reported:
// this is a one-file tool, `fixity` lives in the module that defines the
// operator, and `+` comes from Base. The same honesty licenses an UNKNOWN
// occurrence as a shield -- it may be looser than both, and a check that can
// be wrong is worse than no check. Both graces expire the day an external
// table arrives with the imports (F5).
static void check_chain(R *r, const WokNode *chain) {
  WokSeq ops = E_Chain_ops(chain);
  if (ops.n < 2 || r->fix.n == 0) return;
  for (u32 i = 0; i < ops.n; i++) {
    u32 a = fix_find(r, H_ChainOp_op(ops.items[i]));
    if (a == UINT32_MAX) continue;
    for (u32 j = i + 1; j < ops.n; j++) {
      u32 b = fix_find(r, H_ChainOp_op(ops.items[j]));
      if (b == UINT32_MAX || a == b) continue;
      if (fix_bit(&r->fix, a, b) || fix_bit(&r->fix, b, a)) continue;
      bool shielded = false;
      for (u32 k = i + 1; k < j && !shielded; k++) {
        u32 c = fix_find(r, H_ChainOp_op(ops.items[k]));
        shielded = c == UINT32_MAX ||
                   (fix_bit(&r->fix, a, c) && fix_bit(&r->fix, b, c));
      }
      if (shielded) continue;
      // Both OCCURRENCES are located, not just the one the span points at:
      // in a long chain the other end is the thing the reader hunts for.
      WokSpan fst = H_ChainOp_op(ops.items[i]);
      WokSpan at = H_ChainOp_op(ops.items[j]);
      u32 fl = 0, fc = 0;
      wok_diag_position(r->d, fst.off, &fl, &fc);
      u32 sl = 0, sc = 0;
      wok_diag_position(r->d, at.off, &sl, &sc);
      diag_fixity(r, at.off, at.len,
                  "`%.*s` (%u:%u) and `%.*s` (%u:%u) have no declared order "
                  "and nothing looser stands between them: bracket the "
                  "chain, or relate them with `tighter than`",
                  SPAN(r, fst), fl, fc, SPAN(r, at), sl, sc);
      return;  // one chain, one fault: the rest of it says the same thing
    }
  }
}

// --------------------------------------------------------- write-locality
//
// D27: `:=` is not an assignment operator. It is a handler's private write to
// its own activation frame, and the scope rule is what licenses its absence
// from effect rows. The target must be a `var` of the handler whose CLAUSE
// BODY is the write's nearest enclosing function-forming construct.
//
// FUNCTION-FORMING, and therefore a boundary: a lambda, a local function
// equation, a handler literal. NOT boundaries: blocks, `case` arms, `if`
// branches -- they form no function, so a write inside one is still in the
// clause body it was written in. A handler literal is a boundary because
// handler values are first class (C9): one capturing an outer baton's write
// would be an escaping mutable reference.
//
// Clause-body resolution order is args -> batons -> enclosing (D27,
// normative), and the environment is a linked list on the C stack, so that
// order is just the order things are pushed.

typedef struct Scope Scope;
struct Scope {
  const Scope *up;
  WokSpan name;  // the binding site; its .off is quoted when a diagnostic
                 // names where something was bound
  bool baton;
  u32 frame;  // the handler activation a baton belongs to; 0 for a value
};

typedef struct {
  R *r;  // mutable: check_chain caches the fixity note on first fault
  const Scope *env;
  const Scope *init_batons;  // when inside a `var` INITIALISER: the frame's
                             // batons, visible for DIAGNOSIS only -- an
                             // initialiser runs where the handler value is
                             // built, before the frame exists, so they are
                             // deliberately not in `env`
  u32 frame;   // the frame whose clause body we are DIRECTLY in; 0 = none
  u32 nframe;  // frames seen, so each handler literal gets its own identity
} SC;

static const Scope *lookup(const SC *c, WokSpan name) {
  for (const Scope *s = c->env; s; s = s->up)
    if (span_eq(c->r, s->name, name)) return s;
  return nullptr;
}

// The baton this name would have found if nothing shadowed it. Only asked
// once a write has already failed, to tell "there is no such slot" from "you
// shadowed the slot", which are different mistakes with different repairs.
static const Scope *lookup_baton(const SC *c, WokSpan name) {
  for (const Scope *s = c->env; s; s = s->up)
    if (s->baton && span_eq(c->r, s->name, name)) return s;
  return nullptr;
}

static void sc_node(SC *c, const WokNode *n);

// A VALUE binding pushed from a construct the generic walk cannot see:
// `handle` labels and `use ... as` names are NAME fields, not patterns, so
// without this a capability that shadows a `var` baton is invisible and a
// later write to the name is blessed against the baton -- the exact idiom
// the E-VARSCOPE repair message recommends (`handle s = state 0 ... s.set`).
// Arena-allocated because the binding outlives the pushing frame.
static const Scope *push_value(SC *c, WokSpan name) {
  Scope *s = WOK_NEW(c->r->arena, Scope);
  *s = (Scope){.up = c->env, .name = name, .baton = false, .frame = 0};
  return s;
}

// Every variable a pattern binds, in one pass. Constructors, records and `as`
// all just carry sub-patterns, so the generic walk finds them.
//
// A binder past the cap is REPORTED, not silently dropped: a dropped binder
// makes a later write look unbound (or un-shadowed), and a wrong answer is
// worse than an admitted limit. Reported once per store -- the count parks
// at cap+1 as the already-said marker.
static void bind_pattern(SC *c, const WokNode *p, Scope *store, u32 *nstore,
                         u32 cap) {
  if (!p || *nstore > cap) return;
  if (p->tag == P_Var || p->tag == P_As) {
    WokSpan name = p->tag == P_Var ? P_Var_name(p) : P_As_name(p);
    if (*nstore == cap) {
      wok_diag_add(c->r->d, WOK_E_DEPTH, name.off, name.len,
                   "more than %u names bound in one scope; the front end "
                   "tracks only that many, so give some their own function",
                   cap);
      *nstore = cap + 1;
      return;
    }
    Scope *s = &store[(*nstore)++];
    *s = (Scope){.up = c->env, .name = name, .baton = false, .frame = 0};
    c->env = s;
    if (p->tag == P_As) bind_pattern(c, P_As_pat(p), store, nstore, cap);
    return;
  }
  const WokNodeDesc *d = &wok_node_desc[p->tag];
  for (u16 i = 0; i < d->nfields; i++) {
    if (d->fields[i].family != WFAM_PAT && d->fields[i].family != WFAM_FIELDPAT)
      continue;
    switch (d->fields[i].cls) {
      case WFC_NODE:
      case WFC_OPT:
        bind_pattern(c, p->slot[i].node, store, nstore, cap);
        break;
      case WFC_SEQ: {
        WokSeq q = wok_seq_unpack(p->slot[i].seq);
        for (u32 j = 0; j < q.n; j++)
          bind_pattern(c, q.items[j], store, nstore, cap);
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

// A pattern binds at most this many names before the walk stops recording
// them. A binder past the cap makes a write look unbound, so the cap is set
// far above any pattern a person writes rather than at a plausible number.
enum { SC_MAX_BINDERS = 64 };

static void check_assign(SC *c, const WokNode *n) {
  const WokNode *target = E_Assign_target(n);
  sc_node(c, E_Assign_value(n));
  if (!target || target->tag != E_Var) {
    // `f x := e`, `(a, b) := e`: nothing that names a slot. The pyramid's
    // first line -- `=` names a value, forever -- is the repair. The span is
    // the TARGET's own, and its subtree is still walked: a write buried in a
    // malformed target (`g (\y -> s := y) := 1`) is a fault in any position,
    // and skipping it because its parent is also wrong would hide it.
    if (target)
      wok_diag_add(c->r->d, WOK_E_VARSCOPE, target->off, target->len,
                   "the target of `:=` must be a `var` baton's name");
    else
      wok_diag_add(c->r->d, WOK_E_VARSCOPE, n->off, n->len,
                   "the target of `:=` must be a `var` baton's name");
    sc_node(c, target);
    return;
  }
  WokSpan name = E_Var_name(target);
  const Scope *found = lookup(c, name);

  if (found && found->baton && found->frame == c->frame && c->frame != 0)
    return;  // the write is in the clause body of the handler that declares it

  u32 line = 0, col = 0;
  if (found && !found->baton) {
    const Scope *baton = lookup_baton(c, name);
    if (baton && baton->frame == c->frame && c->frame != 0) {
      // D26 composed with D27: `let cur = cur + 1` read the SLOT and shadowed
      // it with an arm-local value, so the write now targets the value. The
      // shadow site is the whole diagnostic -- without it the reader sees a
      // var they can point at and a message saying it is not one. THIS FRAME
      // only: the shadow voice promises that un-shadowing repairs the write,
      // and that is true only of the frame the write is directly in.
      wok_diag_position(c->r->d, found->name.off, &line, &col);
      u32 vline = 0, vcol = 0;
      wok_diag_position(c->r->d, baton->name.off, &vline, &vcol);
      wok_diag_add(c->r->d, WOK_E_VARSCOPE, name.off, name.len,
                   "`%.*s` is a value here, not a slot: the var declared at "
                   "%u:%u is shadowed by the binding at %u:%u",
                   SPAN(c->r, name), vline, vcol, line, col);
      return;
    }
    if (baton) {
      // A baton exists but in ANOTHER frame: un-shadowing would only turn
      // this fault into the cross-frame one, so the boundary is the
      // diagnosis and the shadow is not mentioned.
      wok_diag_position(c->r->d, baton->name.off, &line, &col);
      wok_diag_add(c->r->d, WOK_E_VARSCOPE, name.off, name.len,
                   "the var `%.*s` (declared %u:%u) " WOK_VOICE_OUTSIDE_FRAME
                   ": a lambda, a local function or a nested handler stands "
                   "between them; snapshot the value, or route the write "
                   "through an op",
                   SPAN(c->r, name), line, col);
      return;
    }
    wok_diag_position(c->r->d, found->name.off, &line, &col);
    wok_diag_add(c->r->d, WOK_E_VARSCOPE, name.off, name.len,
                 "`:=` target `%.*s` (bound %u:%u) is not a `var` baton of an "
                 "enclosing handler; `:=` is handler frame state, not general "
                 "mutation",
                 SPAN(c->r, name), line, col);
    return;
  }
  if (found && found->baton) {
    wok_diag_position(c->r->d, found->name.off, &line, &col);
    wok_diag_add(c->r->d, WOK_E_VARSCOPE, name.off, name.len,
                 "the var `%.*s` (declared %u:%u) " WOK_VOICE_OUTSIDE_FRAME
                 ": a lambda, a local function or a nested handler stands "
                 "between them; snapshot the value, or route the write "
                 "through an op",
                 SPAN(c->r, name), line, col);
    return;
  }
  // Not in scope at all -- but a `var` INITIALISER is a special not-in-scope:
  // the slot exists in the source, just not yet in time. Saying "no var" to
  // someone pointing at one two lines up is the wrong voice; the timing is
  // the diagnosis.
  for (const Scope *s = c->init_batons; s; s = s->up) {
    if (!s->baton || !span_eq(c->r, s->name, name)) continue;
    wok_diag_position(c->r->d, s->name.off, &line, &col);
    wok_diag_add(c->r->d, WOK_E_VARSCOPE, name.off, name.len,
                 "the var `%.*s` (declared %u:%u) " WOK_VOICE_INIT_WRITE
                 ": initialisers run where the handler value is built, "
                 "before the frame exists",
                 SPAN(c->r, name), line, col);
    return;
  }
  wok_diag_add(c->r->d, WOK_E_VARSCOPE, name.off, name.len,
               "no `var %.*s` is in scope here; mutation in ordinary code goes "
               "through an effect (`handle s = state 0` ... `s.set x`)",
               SPAN(c->r, name));
}

// A handler literal. Its `var` clauses declare the frame's slots, and they
// are in scope in every OTHER clause's body -- including the ones declared
// after it, since a frame is one activation and not a sequence of bindings.
static void sc_handler(SC *c, const WokNode *n) {
  check_handler(c->r, n);  // the declaration-side checks: arity, clause kinds
  WokSeq cs = E_Handler_clauses(n);
  SC inner = *c;
  inner.nframe = c->nframe + 1;
  u32 frame = inner.nframe;

  Scope batons[SC_MAX_BINDERS];
  u32 nb = 0;
  for (u32 i = 0; i < cs.n; i++) {
    const WokNode *cl = cs.items[i];
    if (cl->tag != H_Clause || H_Clause_kind(cl) != WOK_CLAUSE_VAR) continue;
    if (nb == SC_MAX_BINDERS) {
      // A dropped baton makes every write to it look unbound; say the real
      // reason once instead.
      WokSpan at = H_Clause_name(cl);
      wok_diag_add(c->r->d, WOK_E_DEPTH, at.off, at.len,
                   "this handler declares more than %u `var` slots; the "
                   "front end tracks only that many",
                   (u32)SC_MAX_BINDERS);
      break;
    }
    Scope *s = &batons[nb++];
    *s = (Scope){.up = inner.env, .name = H_Clause_name(cl), .baton = true,
                 .frame = frame};
    inner.env = s;
  }

  for (u32 i = 0; i < cs.n; i++) {
    const WokNode *cl = cs.items[i];
    if (cl->tag != H_Clause) continue;
    SC arm = inner;
    if (H_Clause_kind(cl) == WOK_CLAUSE_VAR) {
      // The initialiser is evaluated where the handler VALUE is built, not
      // inside its own frame: a baton cannot be written before it exists.
      // The frame's batons ride along for DIAGNOSIS only, so a write to one
      // is refused in the timing voice rather than as "no such var".
      SC init = *c;
      init.nframe = inner.nframe;
      init.init_batons = inner.env;
      sc_node(&init, H_Clause_body(cl));
      // Fold the counter back like the arm walk does: a handler literal
      // inside an initialiser must not share a frame id with one in a later
      // arm.
      if (init.nframe > inner.nframe) inner.nframe = init.nframe;
      continue;
    }
    arm.frame = frame;
    Scope args[SC_MAX_BINDERS];
    u32 na = 0;
    WokSeq pats = H_Clause_pats(cl);
    for (u32 j = 0; j < pats.n; j++)
      bind_pattern(&arm, pats.items[j], args, &na, SC_MAX_BINDERS);
    Scope k;
    WokSpan kn = H_Clause_k(cl);
    if (kn.len != 0) {
      k = (Scope){.up = arm.env, .name = kn, .baton = false, .frame = 0};
      arm.env = &k;
    }
    sc_node(&arm, H_Clause_body(cl));
    if (arm.nframe > inner.nframe) inner.nframe = arm.nframe;
  }
  c->nframe = inner.nframe;
}

// A binding. D26 decides the two halves: WITH parameters it is a function
// equation -- recursive, and its body is a function-forming BOUNDARY. WITHOUT
// them it is a value binding -- non-recursive, so its right-hand side is
// walked in the enclosing scope, which is what makes `let off = off + 4` the
// rebind idiom rather than a loop.
static void sc_bind(SC *c, const WokNode *bind, Scope *slot) {
  const WokNode *lhs = H_Bind_lhs(bind);
  const WokNode *body = H_Bind_body(bind);
  bool is_function = lhs && lhs->tag == L_Prefix && L_Prefix_args(lhs).n != 0;

  if (is_function) {
    SC in = *c;
    in.frame = 0;  // a local function equation is a boundary
    Scope self = {.up = in.env, .name = L_Prefix_name(lhs), .baton = false,
                  .frame = 0};
    in.env = &self;
    Scope args[SC_MAX_BINDERS];
    u32 na = 0;
    WokSeq ps = L_Prefix_args(lhs);
    for (u32 j = 0; j < ps.n; j++)
      bind_pattern(&in, ps.items[j], args, &na, SC_MAX_BINDERS);
    sc_node(&in, body);
    c->nframe = in.nframe;
    *slot = (Scope){.up = c->env, .name = L_Prefix_name(lhs), .baton = false,
                    .frame = 0};
    c->env = slot;
    return;
  }

  sc_node(c, body);  // NON-recursive: the right-hand side reads the outside
  if (lhs && lhs->tag == L_Prefix) {
    *slot = (Scope){.up = c->env, .name = L_Prefix_name(lhs), .baton = false,
                    .frame = 0};
    c->env = slot;
  } else if (lhs) {
    // A destructuring binding's names are needed for the REST of the block,
    // so the chain the pattern pushed onto this frame is re-homed into the
    // arena, which outlives the walk. bind_pattern pushes sequentially, so
    // the chain is store[0..n-1] in push order over the pre-bind env.
    Scope store[SC_MAX_BINDERS];
    u32 n = 0;
    const Scope *before = c->env;
    bind_pattern(c, lhs, store, &n, SC_MAX_BINDERS);
    if (n == 0) {
      c->env = before;  // nothing bound: `let _ = e` leaves the block as-is
      return;
    }
    if (n > SC_MAX_BINDERS) n = SC_MAX_BINDERS;  // saturation marker clamped
    Scope *live = WOK_NEW_N(c->r->arena, Scope, n);
    memcpy(live, store, n * sizeof(Scope));
    live[0].up = before;
    for (u32 i = 1; i < n; i++) live[i].up = &live[i - 1];
    c->env = &live[n - 1];
  }
}

// A block scopes SEQUENTIALLY: a `let` is visible to the statements after it
// and to nothing before it. Blocks are not boundaries, so the frame carries
// straight through -- which is what lets a clause body be several lines.
static void sc_block(SC *c, WokSeq stmts) {
  SC in = *c;
  Scope slots[SC_MAX_BINDERS];
  u32 used = 0;
  for (u32 i = 0; i < stmts.n; i++) {
    const WokNode *s = stmts.items[i];
    if (s && s->tag == S_Handle) {
      sc_node(&in, S_Handle_handler(s));
      // A zero-length label is parse-error recovery (the missing label was
      // already faulted), not a binding; same guard as E_HandleIn's elision.
      WokSpan hl = S_Handle_label(s);
      if (hl.len != 0) in.env = push_value(&in, hl);
      continue;
    }
    if (s && s->tag == S_Use) {
      WokSeq bs = S_Use_binds(s);
      for (u32 j = 0; j < bs.n; j++) {
        if (bs.items[j]->tag != H_UseBind) continue;
        WokSpan to = H_UseBind_to(bs.items[j]);
        if (to.len != 0) in.env = push_value(&in, to);
      }
      continue;
    }
    if (s && s->tag == S_Let) {
      if (used < SC_MAX_BINDERS) {
        sc_bind(&in, S_Let_bind(s), &slots[used++]);
        continue;
      }
      if (used == SC_MAX_BINDERS) {
        // An unrecorded let makes later writes to its name resolve past it;
        // say the real reason once, then keep walking without binding.
        wok_diag_add(c->r->d, WOK_E_DEPTH, s->off, s->len,
                     "this block has more than %u `let` bindings; the front "
                     "end tracks only that many",
                     (u32)SC_MAX_BINDERS);
        used++;
      }
    }
    sc_node(&in, s);
  }
  c->nframe = in.nframe;
}

static void sc_node(SC *c, const WokNode *n) {
  if (!n) return;
  if (n->tag == E_Chain) check_chain(c->r, n);  // then children, generically
  switch (n->tag) {
    case E_Assign:
      check_assign(c, n);
      return;
    case E_Handler:
      sc_handler(c, n);
      return;
    case E_Block:
      sc_block(c, E_Block_stmts(n));
      return;
    case E_Lambda: {
      SC in = *c;
      in.frame = 0;  // a lambda is a boundary
      Scope store[SC_MAX_BINDERS];
      u32 nb = 0;
      WokSeq ps = E_Lambda_params(n);
      for (u32 j = 0; j < ps.n; j++)
        bind_pattern(&in, ps.items[j], store, &nb, SC_MAX_BINDERS);
      sc_node(&in, E_Lambda_body(n));
      c->nframe = in.nframe;
      return;
    }
    case E_LetIn: {
      SC in = *c;
      Scope slot;
      sc_bind(&in, E_LetIn_bind(n), &slot);
      sc_node(&in, E_LetIn_body(n));
      c->nframe = in.nframe;
      return;
    }
    case E_HandleIn: {
      sc_node(c, E_HandleIn_handler(n));  // the handler reads the outside
      SC in = *c;
      WokSpan label = E_HandleIn_label(n);
      if (label.len != 0) in.env = push_value(&in, label);  // empty = elided
      sc_node(&in, E_HandleIn_body(n));
      c->nframe = in.nframe;
      return;
    }
    case E_UseIn: {
      SC in = *c;
      WokSeq bs = E_UseIn_binds(n);
      for (u32 j = 0; j < bs.n; j++) {
        if (bs.items[j]->tag != H_UseBind) continue;
        WokSpan to = H_UseBind_to(bs.items[j]);
        if (to.len != 0) in.env = push_value(&in, to);
      }
      sc_node(&in, E_UseIn_body(n));
      c->nframe = in.nframe;
      return;
    }
    case H_Alt: {
      SC in = *c;
      Scope store[SC_MAX_BINDERS];
      u32 nb = 0;
      bind_pattern(&in, H_Alt_pat(n), store, &nb, SC_MAX_BINDERS);
      // A `where` holds local function equations, which are boundaries of
      // their own; sc_decl handles that.
      WokSeq w = H_Alt_wheres(n);
      for (u32 j = 0; j < w.n; j++) sc_node(&in, w.items[j]);
      sc_node(&in, H_Alt_body(n));
      c->nframe = in.nframe;
      return;
    }
    case D_Equation: {
      SC in = *c;
      in.frame = 0;  // a top-level or local equation is a boundary
      const WokNode *lhs = D_Equation_lhs(n);
      Scope store[SC_MAX_BINDERS];
      u32 nb = 0;
      if (lhs && lhs->tag == L_Prefix) {
        WokSeq ps = L_Prefix_args(lhs);
        for (u32 j = 0; j < ps.n; j++)
          bind_pattern(&in, ps.items[j], store, &nb, SC_MAX_BINDERS);
      } else if (lhs && lhs->tag == L_Infix) {
        bind_pattern(&in, L_Infix_left(lhs), store, &nb, SC_MAX_BINDERS);
        bind_pattern(&in, L_Infix_right(lhs), store, &nb, SC_MAX_BINDERS);
      }
      WokSeq w = D_Equation_wheres(n);
      for (u32 j = 0; j < w.n; j++) sc_node(&in, w.items[j]);
      sc_node(&in, D_Equation_body(n));
      c->nframe = in.nframe;
      return;
    }
    default:
      break;
  }
  // Everything else is TRANSPARENT: it binds nothing and forms no function,
  // so the frame and the environment pass straight through. `case` scrutinees,
  // `if` branches, applications, tuples, records -- all of them.
  const WokNodeDesc *d = &wok_node_desc[n->tag];
  for (u16 i = 0; i < d->nfields; i++) {
    switch (d->fields[i].cls) {
      case WFC_NODE:
      case WFC_OPT:
        sc_node(c, n->slot[i].node);
        break;
      case WFC_SEQ: {
        WokSeq q = wok_seq_unpack(n->slot[i].seq);
        for (u32 j = 0; j < q.n; j++) sc_node(c, q.items[j]);
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

void wok_resolve_fix(const WokNode *file, const char *src, WokArena *a,
                     WokDiagSink *d, WokFixTable *out_fix) {
  if (!file || file->tag != W_File) {
    if (out_fix) *out_fix = (WokFixTable){0};
    return;
  }
  R r = {.src = src, .d = d, .file = file, .arena = a, .effs = nullptr,
         .neffs = 0, .fix = {0}, .fix_note = nullptr};
  build_aliases(&r, file, a);
  build_table(&r, file, a);
  build_fixity(&r, file, a);
  check_fixity_cycles(&r);
  // ONE traversal: the sc walk visits every node (its default arm recurses
  // generically), so the chain and handler checks ride it instead of paying
  // a second full pass. Diagnostics therefore arrive in TREE order, not
  // check-kind order.
  SC sc = {.r = &r, .env = nullptr, .frame = 0, .nframe = 0};
  sc_node(&sc, (WokNode *)file);
  if (out_fix)
    *out_fix = (WokFixTable){.ops = r.fix.ops, .n = r.fix.n,
                             .edge = r.fix.edge, .words = r.fix.words};
}

void wok_resolve(const WokNode *file, const char *src, WokArena *a,
                 WokDiagSink *d) {
  wok_resolve_fix(file, src, a, d, nullptr);
}
