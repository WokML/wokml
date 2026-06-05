# Multi-clause functions via a decision-tree match compiler

Date: 2026-06-05
Status: Design approved, pending spec review

## Problem

wok silently mishandles pattern matching in function heads:

1. **Multi-clause functions drop all but the first clause.** `groupEquations`
   (`src/Wok/TypeChecking/Infer.hs`) collects same-named equations (even
   non-adjacent) and typechecks all of them with unified types, but
   `finalizeGroupTyped` surfaces only the FIRST clause's params/body onto the
   `TypedDecl`. Later clauses are dropped before ANF. No error, no warning.
2. **Single-clause refutable head patterns are partial with no warning.**
   `elabParam` (`src/Wok/IR/Elaborate.hs`) lowers a refutable head pattern to a
   `Case` with ONE alt and no fallback, so a non-matching argument crashes at
   runtime with `NonExhaustiveCase`.
3. **No general exhaustiveness/redundancy checking exists.** The only check is a
   record-specific `NonExhaustiveRecordPattern` warning (`checkRecordPattern`).

The root cause is the same: there is no pattern-match compiler. Function heads
cannot dispatch across clauses, and the elaborator cannot express fallthrough
between alternatives (the known "backtracking gap").

## Goals

- Compile a group of same-named equations into a single function whose body is a
  decision tree over the arguments, with correct cross-clause fallthrough.
- Support multi-argument clauses (multiple pattern columns) directly.
- Emit exhaustiveness and redundant-clause warnings as a near-free by-product.
- Produce allocation-free, branch-and-jump output suitable for the future native
  / self-hosting backend.

## Non-goals

- Guards (the grammar has none: `DEqn ::= FunLHS "=" Exp MaybeWhere`).
- Or-patterns (not in the surface grammar today).
- Non-empty list-literal patterns `[x, y]` — already rejected by `elabPatF`;
  this work inherits that limitation, it does not fix or worsen it.
- Hash-consing / a separate DAG pass. Sharing comes from join points instead
  (see "Sharing").

## Approach: decision tree, not tuple, not backtracking automaton

Compile the clause matrix to a **decision tree** (each sub-term tested at most
once per path), following the Sestoft 1996 / Jules Jacobs 2021 matrix
construction with Maranget's necessity heuristic for column choice. Rationale
(researched 2026-06-05):

- A **tuple scrutinee** (`case (a,b) of ...`) heap-allocates a tuple per call and
  still needs the same matrix logic inside the tuple alt. Rejected.
- A **backtracking automaton** (OCaml backend, Le Fessant-Maranget 2001) is
  compact but re-tests sub-terms. Decision trees are faster at runtime, which
  matters for the native target.
- The decision tree's only real downside — code-size explosion from duplicated
  subtrees — is neutralized by wok's existing join points (see "Sharing"), so the
  tree is strictly the right choice here.
- Per Scott & Ramsey 2000, column heuristics barely affect human-written code
  (within a few %); the wrong heuristic only hurts machine-generated matches
  (2-20x). So: one decent heuristic, no further investment.

## Algorithm

Input: a clause matrix. Rows are clauses; columns are argument positions. Each
row carries the (already type-checked) clause body, bound to a join point.

State: a vector of scrutinee `Atom`s (initially the function's argument binders;
field binders as we descend) aligned with the matrix columns.

- **No columns left** -> first row wins: `Jump k_body`. Any remaining rows are
  redundant -> emit a redundant-clause warning.
- **No rows left** -> match failure leaf: `NonExhaustiveCase` (or a shared `fail`
  join point). Reaching this from a complete column switch means the match is
  non-exhaustive -> warning.
- **Otherwise** choose a column (heuristic below):
  - all-wildcard column -> drop it (record variable bindings), recurse;
  - else emit `case scrut_i of` with:
    - one `AltCon c [fresh field binders]` per head constructor present
      (specialize: rows whose entry is `c` contribute sub-patterns; wildcard rows
      contribute wildcards), recurse into each;
    - one `AltLit l` per literal present (for `AltLit` columns), recurse;
    - an `AltDefault` built from the wildcard rows when the constructor/literal
      set is not exhaustive for the column's type, recurse.

Variable bindings ride as **join-point parameters**: each clause body is
`LetJoin k_i (vars...) = body`, and each leaf `Jump`s with the matched atoms. No
extra `let`s, no body duplication.

### Column-choice heuristic

1. **Necessity / needed-columns** (Maranget primary).
2. **Constructor-before-literal** tiebreak: prefer columns that lower to a dense
   tag switch (`AltCon`, O(1)) over literal columns (`AltLit`, comparison chain).
3. **Leftmost** as the final deterministic tiebreak.

## Output IR

Only existing ANF nodes: `Case` / `AltCon` / `AltLit` / `AltDefault` for the
tree, `LetJoin` / `Jump` for clause bodies and shared subtrees, threaded through
the existing `TailK = TRet | TJump JoinId` mechanism. No new IR types.

## Sharing

By construction via join points, NOT hash-consing. This reuses the exact pattern
`normName` (`Elaborate.hs:118-128`) already uses to make compound expressions in
value position converge to a single merge point: allocate one `LetJoin` per
clause body, give every decision-tree leaf the tail `TJump k_clause`. The match
compiler becomes the second user of that pattern.

No hash function is introduced. wok uses `Data.Map.Strict` (Ord-keyed)
throughout and no `hashable`/`unordered-containers`. If sharing of identical
*internal* sub-trees is ever wanted (a later optimization, not this spec), use an
`Ord`-keyed `Data.Map DecisionNode JoinId` to memoize — reusing existing `Ord`,
dependency-free.

## Relationship to effect handlers

Operation arms and value arms of the unified `case` are partitioned *upstream*
into `hOps` (runtime handler dispatch on `(effect-label, op-name)`) and
`hReturn` (a value `Case` compiled by this match compiler). They never share a
matrix — operations are intercepted mid-evaluation (continuation capture), values
arrive at completion. So this match compiler only ever sees value patterns;
operation dispatch stays the runtime's job. (A future O(1) keyed dispatch table
for `hOps` is out of scope here.)

## Components and changes

1. **Typed AST carries a clause list.** `TLocalDecl` / `TypedDecl` change from a
   single `(params, body)` to a list of clauses `[([TPat], TExpr)]` (one per
   equation). `finalizeGroupTyped` stops dropping and keeps all typed clauses;
   their types are already unified so the scheme is unchanged. Add an
   arity-agreement check across a group's clauses (error if equations disagree on
   argument count). Confirm the top-level grouping path mirrors `groupEquations`.

2. **New module `Wok/IR/Match.hs`.** Pure decision-tree compiler:
   `compileMatch :: [Binder] -> [([TPat], JoinId)] -> Elab Expr` (or equivalent),
   implementing the algorithm above. Returns an `Expr` of `Case`/`LetJoin`/`Jump`.
   Also exposes the exhaustiveness/redundancy results.

3. **`Elaborate` hookup.** Function / top-level elaboration binds one fresh param
   per column, emits a `LetJoin` per clause body, and calls `compileMatch`.
   Single-variable-only heads keep the existing cheap direct path (no `case`).

4. **Exhaustiveness + redundancy warnings.** Maranget usefulness check reusing the
   same matrix machinery. New warning variants in `TypeChecking/Error.hs`
   (non-exhaustive match; redundant clause). Closes the coverage gap.

5. **Tests.** Golden tests for: `safeHead` (single column, partial -> warning),
   `zip` (two columns, fallthrough), `Just 0 / Just _ / Nothing` (literal
   fallthrough without re-testing the constructor), exhaustiveness and
   redundant-clause warnings, and a behavior-preservation sweep proving existing
   single-clause functions still elaborate and run identically.

## Scope

Build the full multi-column compiler now (multi-argument falls out of the matrix
uniformly). No artificial single-column slice.

## Risks

- Touching `TypedDecl`'s shape ripples through every consumer of typed decls.
  Mitigated by keeping the single-clause shape representable (a one-element list)
  so most consumers change mechanically.
- The freeze/generalization logic in `finalizeGroupTyped` currently assumes one
  surfaced body; it must fold over all clause bodies under one mapping. Needs care
  to keep `tdScheme` and per-node `CTGen` numbering consistent.
