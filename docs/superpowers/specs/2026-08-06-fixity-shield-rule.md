---
spec: grammar/c — fixity F3 revision: the shield rule, and the table in the message
status: IMPLEMENTED (unmerged), pending review
depends: 2026-08-06-fixity-front-end.md, src/Wok/Reordering.hs
---

# The shield rule: which incomparable pairs are actually faults

## 1. What F3 got wrong, shown with the real prelude

F3 shipped requiring EVERY pair of operators in one chain to be comparable.
With the prelude's own declarations (`* tighter than +`, `/ tighter than +`,
no relation between `*` and `/`):

```wok
f = 2 * 3 + 8 / 4
```

is faulted by the C checker and reordered without complaint by
`src/Wok/Reordering.hs`. Ordinary arithmetic, rejected by one front end and
accepted by the other. All-pairs is the wrong rule, and the Haskell scan is
not the right replacement either: it reports whatever pair its left-to-right
walk trips on, which is an artifact of walk order, not a semantics.

## 2. Start from what a chain means

A chain's meaning is fixed by the split rule: find the loosest operator,
split there, recurse. So a chain is well-formed **iff every subchain the
recursion visits has a unique loosest operator**. That is the denotation.
It collapses into a local, non-recursive rule:

> An incomparable pair of operator OCCURRENCES is licensed iff some
> occurrence positionally BETWEEN them is strictly looser than both.
> Call that occurrence a **shield**.

In `2 * 3 + 8 / 4`, the `+` between `*` and `/` shields them: the split at
`+` separates them before they ever compete. In `2 * 3 / 4 + 8` nothing
stands between `*` and `/`: fault. Same operator set, different answer —
the rule is positional, and that is correct; no set-based rule can say it.

Equivalence with the denotation, both directions:

- **Shielded ⇒ well-formed.** If two minimal operators of a (sub)chain were
  incomparable, their shield would be a present operator looser than both,
  contradicting minimality — so a unique loosest exists. Splitting there
  keeps every surviving pair's shield inside its segment (the shield cannot
  be the split operator without separating the pair). Induction down.
- **Unshielded ⇒ stuck.** The split operator at each level is strictly
  looser than both members of the pair and is neither of them, so — having
  no occurrence between them — it never separates them. They descend
  together, the level's loosest is deleted from the operator set each time,
  and eventually the two are minimal together with no minimum.

The rule is per OCCURRENCE pair, not per distinct-op pair: in
`a * b + c * d / e` the first `*` is shielded from `/` by the `+`, the
second is not, and the split semantics genuinely gets stuck on the right
segment. Occurrence-level is not pedantry.

## 3. Why this formulation, and not a port of `findLoosest`

- **It survives partial knowledge; the recursive splitter does not.** The
  splitter must place every operator to find a minimum, so one unknown
  operator poisons the whole chain. The shield rule is per-pair: check only
  known incomparable pairs, and treat an unknown occurrence between them as
  a possible shield — no fault, because it might be looser than both, and a
  check that can be wrong is worse than no check (the F3 principle). At F5,
  with full tables, the grace clause evaporates with no code change.
- **Order-independent.** The fault set is a property of the chain, not of a
  walk direction.
- **The diagnostic explains itself.** Not "no declared order — bracket it"
  but "these two meet with nothing looser between them".
- **Checker and rewriter cannot drift.** F4's reorderer is the range split;
  F3's checker is the shield rule; their agreement is a theorem with a
  QuickCheck-shaped statement the generative suite can pin: for chains over
  fully-known operators, shield-check accepts iff the range split completes.

Accept/reject agrees with the Haskell reorderer on fully-known chains (its
scan faults exactly when some level lacks a unique minimum, though it
attributes the fault by scan order). So this revision closes the divergence
without treating the Haskell code as the oracle: both sides now answer to
the denotation, and the Haskell side can later adopt the shield rule for
its messages.

## 4. The duplicate's edges die with it

`build_fixity` pass 1 reports a second `fixity` line for one operator and
keeps the first declaration's associativity — but pass 2 still recorded the
loser's `tighter than` edges into the matrix, silencing chain faults the
winner's table would have raised. Confirmed by running it. The fix is one
guard: pass 2 skips a declaration whose head's recorded `decl_off` is not
its own name offset.

A re-check after the fix found the leak's second half: pass 1 still interned
the loser's NEIGHBOURS as placeholders. A neighbour named only by a dropped
duplicate then sat in the table edge-less — found by `fix_find`, so use
sites read it as known-but-incomparable and faulted chains the winner's
table would leave unknown and skip (and the table note printed the ghost).
Pass 1 now skips the loser's relations too. A dropped duplicate contributes
NOTHING — no assoc, no edges, no names — which is what the E-DUPLICATE
message promised, and what the effect table already does.

## 5. The table rides in the message

When a fixity fault is reported — a cycle, or an unshielded pair — the
diagnostic carries the order the checker was using, as continuation lines:

```
mix.wok:6:15: `*` (6:11) and `/` (6:15) have no declared order and nothing
looser stands between them: bracket the chain, or relate them with
`tighter than`
  the order this file declares:
    fixity + left
    fixity * left tighter than +
    fixity / left tighter than +
```

Both OCCURRENCES are located, not only the one the span points at: in a
long chain the other end is the thing the reader hunts for. And an operator
known only from someone else's `tighter than` clause gets a row of its own
(`+ (named only as a neighbour)`), because the table printed must be
everything the table knows.

Decisions, and why:

- **In the same diagnostic, not a second one.** The sink suppresses a
  second diagnostic at the same offset, the harness pins fault cases to
  exactly one diagnostic, and a JSONL consumer gets the table attached to
  the fault it explains instead of a floating note.
- **Verbatim declaration slices, in declaration order.** Each line is the
  source text of one winning `fixity` declaration (`WokNode.off/len` — the
  span field's stated purpose). No re-rendering, the author's own spelling
  of `tighter`/`looser`, and dropped duplicates are excluded because they
  are not in the table — the table printed is the table consulted.
- **Built once per file, on first fault, cached.** Fault-free files pay
  nothing.
- **E-DUPLICATE keeps its two-position message.** It already names both
  sites, which is the whole repair; attaching the table would also force
  duplicate reporting to be deferred until after the winner set is final.
  Revisit if wanted.
- The sink gains `wok_diag_add_text` (cap and cascade logic shared with
  `wok_diag_add`, no 512-byte format buffer), because a message carrying a
  table must not be silently truncated by the formatting path.

## 6. Tests

New `test_resolve.c` cases; the harness grows a second expected-code slot
for the one case that legitimately reports two faults:

1. `2 * 3 + 8 / 4` under `*`,`/` both tighter than `+` — SILENCE (the case
   F3 wrongly faulted).
2. `2 * 3 / 4 + 8`, same declarations — E-FIXITY (positional: no shield).
3. `1 * 2 + 3 * 4 / 5` — E-FIXITY (occurrence-level: the second `*` is
   unshielded even though the first is shielded).
4. `1 ++ 2 <?> 3 + 4` with `++`,`+` declared unrelated — SILENCE (unknown
   occurrence between them may be a shield).
5. The duplicate-edge leak: `fixity + left` / `fixity + right tighter
   than *` / `fixity * left`, chain `1 + 2 * 3` — E-DUPLICATE then
   E-FIXITY, because the loser's edge no longer relates `+` to `*`.

Existing cases stay green: all-pairs-comparable chains have no incomparable
pairs; `1 ++ 2 + 3` and its two-chain variant remain faults (adjacent,
no shield).

## 7. Out of scope, recorded

`1 + 2 - 3` stays a fault under any use-site rule: `+` and `-` are
incomparable and nothing can stand between adjacent occurrences. That is a
gap in the RELATION language — the order can say tighter and looser but
not "same level", and choosing either direction would silently change
meaning. If wok wants ordinary arithmetic unbracketed, the fix is a third
relation (`fixity - left same as +`) forming equivalence classes with one
checked constraint: a class agrees on associativity, or ties have no
tiebreak. The shield rule reads through classes unchanged. A language
call, to be made before F4 decides what trees same-level runs produce.
