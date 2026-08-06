---
spec: grammar/c — fixity
status: F1, F2 and F3 IMPLEMENTED; F4 (the rewrite) and F5 (imports) NOT STARTED
depends: 2026-08-03-c23-frontend-design.md, src/Wok/Reordering.hs, grammar/Wok.cf
---

# Reading the fixity order, and checking it, before reordering anything

## 1. The fact everything follows from

wok's fixity is a **partial order over a graph**, not a ladder of numbered
levels:

```wok
fixity + left
fixity * left tighter than +
fixity == left looser than +
```

`x -> y` means "x binds tighter than y", and an edge is stated from either
end — `a tighter than b` and `b looser than a` are the same edge. `compareOps`
in `src/Wok/Reordering.hs` answers by reachability and returns
`Tighter | Looser | Equal | Incomparable`, where **`Equal` means literally the
same operator** (there are no cross-operator equivalence classes) and
**`Incomparable` is a fault at the use site**, never a tie broken by a default.

Two consequences that decide the implementation:

- **Associativity only ever settles a run of ONE operator.** Every other tie
  is impossible by construction.
- **The reassociation is not shunting-yard and not precedence climbing.** It is:
  find the chain's LOOSEST operator, split there, recurse both sides. Ties
  (same operator) go rightmost for left-assoc, leftmost for right-assoc.

## 2. What shipped

**F1 — the declaration** (`a5c86b6`). `WW_FIXITY` is a keyword; `left`,
`right`, `tighter`, `looser` and `than` are **contextual varids**, for the
reason `own` and `copy` are — they are ordinary names anywhere else, and
reserving them would cost every program that has one. New `D_Fixity` node with
an `alpha` flag recording the operator's spelling (a symbol run, or an
identifier meant for backticks), and an `H_FixRel` helper per relation.
Associativity is required: there is no `none` tier.

**F2 — the table** (`7847653`). Operators interned to indices; edges into a bit
matrix; **one Warshall closure**. Not for speed at this size — the closure
answers both of the stage's questions with the same bits:

- comparison is `bit(a,b)` / `bit(b,a)`;
- a **cycle is `bit(a,a)`**, a node that reaches itself, so circularity needs
  no second algorithm and self-reference is just its one-node case. (The
  Haskell side needs an SCC pass plus a BFS per query for the same two
  answers.)

Reported once per ring, at the member declared first, naming the ring in
declaration order — the closure knows *which* operators are mutually
reachable and no longer knows by what route, and a made-up route would be a
worse answer than the set.

**F3 — the use site** (same commit; REVISED by
`2026-08-06-fixity-shield-rule.md`). As shipped, every pair of operators in
one chain had to be comparable — too strict: it faulted `2 * 3 + 8 / 4`,
which the Haskell reorderer accepts, because the `+` between `*` and `/`
splits them apart before they ever compete. The rule now is the SHIELD rule:
an incomparable pair of occurrences is a fault only when no occurrence
between them is strictly looser than both. One fault per chain, not one per
pair, and the diagnostic carries the declared order as continuation lines.

## 3. The decision that shapes F3, and it is the same one the effect table made

**An operator with no table entry is SKIPPED, not reported undeclared.**
`fixity` lives in the module that defines the operator; `+` comes from Base;
this tool reads one file. A check that fired on every file in the corpus and
was wrong about all of them is worse than no check. The Haskell side reports
`UndeclaredOperator` because it runs with the imports resolved — the C side
will too, the day F5 lands, and not before.

Held for the same reason: `UnresolvedNeighbor` (a `tighter than` naming an
operator this file cannot see may name an imported one).

Safe under partial knowledge, and therefore implemented: redeclaration,
self-reference, cycles among operators the file declares, and incomparability
between two operators the file declares.

## 4. A finding about the prelude, not about this code

`prelude/Base.wok` has `fixity ++ right` and **no relation to anything**. So
`xs ++ ys + z` is genuinely incomparable in wok today and must be bracketed.
The checker says so. Whether that is the intended surface is a language
question.

## 5. Two things to decide before F4

**`::` has no spellable fixity.** The C parser accepts it as a chain operator
(`at_infixop`: `WT_VARSYM || WT_COLONCOLON`) and `accept/04` writes
`x :: k ()`. But `:` is not in `Wok.cf`'s VarSym charset and
`FixName ::= VarSym | VarId`, so `fixity ::` is unwritable and Base declares
nothing for it. Today F3 skips it as an unknown operator, which is correct
under partial knowledge and stops being correct at F5. Options: seed built-in
entries before the file's own declarations, or extend `FixName` to name
reserved tokens. Note expression-level `::` is a v2 addition the Haskell
grammar does not have at all (`PCons` is patterns only).

**The reordered tree must not be the formatter's tree.** `wokfmt` round-trips
text; reassociating before printing would rewrite the author's brackets and
break `Parse(Format(t)) == t`. F4 should return a second tree for downstream
consumers and leave the parse tree alone — which also means `wok_print.c`'s
`EP_*` ladder keeps assuming flat chains and needs no fixity at all.

## 6. F4 and F5, when a consumer exists

**F4 — the rewrite.** `reorderChain` is ~40 lines: `findLoosest`, split,
recurse, and a `combineInfix` that brackets a nested chain. The C target
shape is a nested `E_Chain` of one `H_ChainOp` each. It is the *easiest* part
of this job and the least urgent: **nothing inside `grammar/c` consumes a tree
semantically yet**, so today it would produce a tree with no reader.

**F5 — external tables.** `wok_reorder(file, src, arena, sink, external)`.
The entries need an **origin** field, the same one `overlayEnvs` and
`overlayFixities` key on: a diamond re-export merges (identical entry, same
origin, seen twice) while a genuine cross-module redeclaration errors. Without
origin, every re-export reads as `E-DUPLICATE`.
