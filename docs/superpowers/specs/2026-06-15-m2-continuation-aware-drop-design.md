# M2 — Continuation-Aware Drop + LetRec/Closure Escape (design)

Status: design, pending implementation. Date: 2026-06-15. Author: brainstorm with Claude.
Predecessor: `docs/superpowers/specs/2026-06-14-m1.5-closures-perceus-design.md` (M1.5, merged at `371e4f8`).

## 0. Summary

M2 finishes the reference-counting (RC) story for the wok interpreter. It has two
jobs:

1. Make the Perceus pass and the RC store **sound for the four deferred
   LetRec/closure escape cases** from M1.5, so their reject-guards can come down.
2. Bring **effect handlers and one-shot continuations onto the counted RC store**,
   with **continuation-aware drop**: a captured continuation owns its delimited
   frames' values; on resume they flow back, on drop-without-resume (cancel /
   race-loser / handler-returns-without-resume / orphan) the captured set is
   released.

The unifying claim, pressure-tested during brainstorm and adopted here: the four
LetRec deferrals and continuation-aware drop are **the same problem**. The cheap
model pins a region's lifetime to a *lexical or dynamic extent* (a `LetRec` scope,
a handler delimiter, an arena scope). Escape breaks the pin. The fix is **promoting
the escaping region to a counted unit whose lifetime is driven by the escapee's
refcount**.

This milestone is split into three slices: **M2a-1** (closure representation),
**M2a-2** (region-lifetime promotion), **M2b** (continuations + effects).

## 1. Verified ground truth

The following were confirmed against the repo and memory before this design was
settled. They are the premises the design relies on; if any drifts, revisit.

- M1 and M1.5 are merged to main at `371e4f8`. 1019 tests green at merge.
- The RC interpreter (`Wok.Interp.RC.{Value,Machine,Prim}`) rejects effects:
  `Machine.hs` errors on `Handle` and `ROp` with `"rc M1: effects not supported
  (no-handler fragment)"`. `RCKont` has `KDoneRC | KLetRC | KAppRC` and **no
  `KHandle` analogue**. There is **no scheduler** and **no finalizer/drop-hook** in
  the RC store today.
- The boundary guard `Wok.IR.Reachable.firstOrderNoHandlerViolations` /
  `exprScopeFeaturesWith` rejects any reachable `Handle`/`ROp` and the four escape
  cases below.
- The one-shot law is analyzed in `Wok.IR.Multiplicity`: `Card = Zero | One | Many`;
  `analyzeModule` emits `MultishotResume` for any arm whose resume card is `Many`
  (a compile error). M2 **consumes** this; it does not redo it.
- Bacon-Rajan trial deletion is documented UNNEEDED unless wok adds mutable refs /
  laziness / co-inductive types / multi-shot. M2 keeps it unneeded (see Section 6).
- `Wok.IR.Anf.freeVarsExpr (Handle e _) = freeVarsExpr e` **drops the handler arms'
  free vars** (`Anf.hs:455`). Harmless while effects are walled off; must be fixed
  before effects enter the RC fragment (M2b pre-step).

### 1.1 The four deferred cases and their reject-predicates

| # | Case | Predicate / site | M1.5 section |
|---|------|------------------|--------------|
| 1 | A LetRec member *consumes* (moves) an enclosing capture | `letRecMemberConsumesCapture` (`Perceus.hs:320`) | 5.3 |
| 2 | A member captures an enclosing local AND a member escapes the scope | `letRecEnclosingCaptureEscapes` (`Perceus.hs:281`) | 5.1 / 5.7 |
| 3 | An inner LetRec member captures an OUTER group's member (cross-region) | `rawEnclosingFv` + `capturesRegion` (`Perceus.hs:515`, `499`) | 5.5 |
| 4 | A standalone `RLam` captures a LetRec sibling | inline in `Reachable.exprScopeFeaturesWith:188` | 5.7 / 5.1 |

The borrow model today (`ctxExempt`, `Perceus.hs:588`) treats a member's enclosing
captures and siblings as exempt from move/dup/drop — sound only for *borrowed
reads* (a `Case` scrutinee keeping no boxed child). Every other use is conservatively
rejected.

## 2. Thesis and invariants

### 2.1 Why "no counted cycle" survives escape

The brainstorm corrected one load-bearing piece of the original thesis. An escaping
LetRec member does **not** form a counted cycle. The knot's intra-region edges are
uncounted *by construction* and stay uncounted on escape: `allocLetRecGroup` stamps a
shared region id (`stRegionOf`, persistent — entries never removed, even on free),
and `countedChildren` filters same-region siblings before the drop cascade. None of
that depends on whether the group escaped. So the "no counted back-edge" invariant
holds on escape; **Bacon-Rajan stays genuinely unneeded**.

What actually breaks on escape is narrower: the region's lifetime is pinned to lexical
scope (`allocLetRecGroup` at `LetRec` entry; whole group dropped as a unit at scope
exit). Escape breaks *"region lifetime = lexical scope"*, leaving either a leaked
captured local or a dangling sibling under a still-live escapee. The fix is
**lifetime promotion**, not cycle collection.

### 2.2 Invariants M2 must preserve (never cross into under-rejection)

1. **No counted cycles, ever.** Every counted edge is a DAG edge.
2. **No counted edge into a region / arena / FFI cell.** Those are reached by static
   reference or opaque token only.
3. **A continuation is never embeddable into the data it owns.** No `VCont` in a
   constructor field or a state slot. This is the carrier wall, now load-bearing for
   *soundness*, not just typing: it is what prevents `state -> cont -> frame -> state`.
4. **Conservative analysis.** When the pass cannot prove safety, it still refuses.
   M2 shrinks refusal; it never trades soundness for coverage.

## 3. Decomposition (settled)

Three independently shippable slices, each with its own full-branch review (repo
culture; see `[[review-before-merge]]`).

| Slice | Headline | Removes guards | Brainstorm tension |
|-------|----------|----------------|--------------------|
| M2a-1 | Owned-vs-borrowed closure representation | #4 (non-escaping); #1 DEFERRED (see 4.1) | owned vs borrowed |
| M2a-2 | Region-lifetime promotion on escape | #2, #3, #4 (escaping parts) | the cycle/region problem |
| M2b   | Continuations + effects on the RC store | the effects guard | continuation drop placement |

> **Update (2026-06-15, post-implementation):** M2a-1 shipped #4 (closure captures a
> sibling) plus the uniform Invariant-2 cascade, the alias handling, and the escape
> detector. **#1 (a member CONSUMING an enclosing capture) was DEFERRED** — see the
> revised §4.1. A property-based generator (Suite G) proved the dup-per-consuming-use
> approach unsound at scale; the honest fix needs borrow-passing, a later slice.

**Design constraint (borrowed from the "one unified milestone" alternative we
rejected for scope):** M2a-2 defines the **promotion interface** once, so M2b reuses
it verbatim for the delimited-frame "region". This is what stops M2a from
over-fitting to function groups.

Rejected alternatives: continuation-first (builds the hard escape machinery in the
hardest setting, no isolated validation); single all-at-once milestone (closure-rep
+ region-lifetime + Kont-on-RC + CPS placement + Multiplicity + the `freeVarsExpr`
fix in one reviewable unit — too large, long time-to-green, violates slice culture).

## 4. Slice designs

### 4.1 M2a-1 — owned vs borrowed captures (closure representation) — AS SHIPPED

**Problem.** A closure (or constructor/record) that holds a region-sibling capture
cascade-drops it *and* the group drops it — a double-free (#4). Separately, a member
that MOVES an enclosing capture double-frees against the group cascade (#1).

**What shipped (sound, proven at scale by Suite G):**
- **Owned vs borrowed captures.** `NClosure` records a borrowed-capture set, and the
  drop cascade `countedChildren` is **uniformly** address-based: it skips any child
  that is `isRegionAddr` or `isStaticAddr`, for `NClosure`/`NCon`/`NRecord` alike
  (the **Invariant-2** rule "no counted edge into a region" — a container of any kind
  never frees a region/static child; the group frees its members once at scope exit).
- **Escape detector.** `rlamSiblingCaptureEscapes` / `letRecMemberEscapes`: a tracked
  sibling free in a nested closure body, or in any non-call-head RHS position
  (`RCon`/`RRecord`/`RApp`-arg/`RProj`/alias), counts as an escape. The boundary guard
  rejects a sibling that escapes (region-lifetime extension is M2a-2); admits the
  non-escaping #4 (closure/con/record/alias holding a sibling, dropped locally).
- **Alias handling.** `let x = <sibling>` propagates exempt/borrow-ness through the
  alias binder (no dup, no drop); an escaping alias is rejected.

**#1 (consuming an enclosing capture) is DEFERRED — and why.** The original plan was
"dup-per-consuming-use": emit one `__rc_dup` per consuming use so each move and the
group cascade each own a unit. A property-based generator (Suite G) proved this
**unsound at scale**: the number of times a borrowed capture is consumed at runtime
is **dynamic and statically undecidable** — it depends on how many times each member
is *called* and which branch *fires*. A two-member mutually-recursive group where both
base cases consume the capture terminates in exactly ONE base case, so `SUM`-over-members
over-counts → **leak**; `MAX` would under-count when the body calls both members →
**use-after-free**; even a single consuming member UAFs if the body calls it twice.
There is no static count that is simultaneously leak-free and UAF-free for arbitrary
call patterns. The properly-sound mechanism is **borrow-passing** (the callee borrows
the capture instead of taking ownership) — a calling-convention feature beyond this
slice. So M2a-1 **restores the M1.5 line**: only borrowed *reads* of an enclosing
capture are admitted; any *consuming* use is rejected at the boundary (`#1` guard
fires on `letRecMemberConsumesCapture`, regardless of escape). `consumingUseCount`,
the dup-per-consuming-use plan, and the matching `balanceLint` accounting were removed.

**Removes.** The non-escaping part of #4 (and the local-drop con/record variant via
Invariant-2). #1 stays rejected; #2/#3 stay rejected (M2a-2).

### 4.2 M2a-2 — region-lifetime promotion on escape

**Problem.** A LetRec group whose member escapes its scope (#2, escaping-#4) leaks
the captured local or dangles a sibling, because the region is freed wholesale at
scope exit while an escapee still points in. Cross-region capture (#3) is the same
shape across a lifetime boundary.

**Change — the promotion interface.** On escape (reuse `letRecEnclosingCaptureEscapes`):
- The escaping member, plus the transitive sibling/capture set it holds alive, is
  **promoted from uncounted-region to genuinely-counted ownership**: a normal counted
  sub-graph with real counted DAG edges. The knot *among escapees* is still resolved
  to static/direct edges (no counted back-edge), so Invariant 1 holds.
- Its lifetime is now driven by the escapee's refcount, not lexical scope.
- The non-escaping remainder of the group keeps the cheap wholesale-region treatment.
- Cross-region (#3) becomes a counted edge from the inner promoted unit to the outer
  member — sound because the outer member is, by construction, longer-lived.

**Runtime.** A small addition: a region member can be marked "promoted" (treated as
counted). No runtime graph algorithm; the rewrite is static (mark escaping members,
emit counted alloc + dup/drop for them).

**Removes.** #2, #3, and the escaping sub-case of #4. After this slice all four
M1.5 reject-guards come down.

**This slice IS the promotion interface M2b reuses.**

### 4.3 M2b — continuations + effects on the RC store

**Pre-step.** Fix `freeVarsExpr (Handle e _)` (`Anf.hs:455`) to include the handler
arms' free vars.

**Kont frames as counted objects.** Mirror the reference interpreter's
`KDone | KLet | KApp | KHandle` (`Wok.Interp.Value:101`) onto the counted store. Each
frame **owns** the RC values in its captured `Scope` (`scEnv`). A captured (delimited)
continuation is the chain of frames from the op site up to its matching `KHandle`,
represented as a **counted continuation object** that owns those frames' values.

**Drop over the explicit-capture CPS form, not the surface CFG (the crux).** Because
one-shot is the law, the continuation is an **affine value** (resume card <= 1). Run
Perceus over the explicit-capture representation where the continuation is a
first-class binder with a clear last use, so the two mutually-exclusive consumers are
visible:
- **resume** (card `One` on that path): the continuation is **moved**; its owned set
  flows back into the running computation.
- **drop-without-resume** (card `Zero` path — cancel, race-loser,
  handler-returns-without-resume, orphan): the continuation is **released**;
  recursive-drop of its frames runs.

Placing drops on the surface CFG would hide the cancel-vs-resume branch, giving either
a double-free (both consume) or a leak (neither). M2b's Perceus input must therefore
be the CPS/explicit-capture form (see `[[effect-compilation-strategy]]`: stackless
selective CPS, contify-vs-reify). Open scope item: confirm the elaborator already
produces a clean explicit-capture handler representation, or that becomes M2b work.

**Multiplicity integration.** Consume `Wok.IR.Multiplicity` directly:
`armCard == Many` is already a compile error (never reaches RC); `Zero` ->
always-drop; `One` -> resume-consumes-on-the-resume-path, drop on the other. No
re-analysis.

**`State` effect acceptance case.** Scoped mutable state is **not a new category** —
it is this case. A `KHandle` frame owns its parameter value; `set` is
drop-old/own-new on the slot; dropping the frame drops the state value. This must
ship as an explicit acceptance test, and it depends on Invariant 3 holding (no
`VCont` can land in a state slot, else `state -> cont -> frame -> state` cycles).

**Removes.** The effects guard in `Reachable` and `Machine`.

## 5. Recommended calls on the open tensions

- **Finalizers (#5): recursive-release only in M2b; build the seam, not the hook.**
  A dropped continuation owns wok values; releasing it is the existing `dropAddr`
  cascade over counted frames. No finalizer needed for M2b proper. **Design the
  frame-drop path so a drop-hook is a one-line seam to add later** — that seam is
  exactly what RAII resource drop / cancel cleanup (`Std/Control.wok` ~181,
  currently a deferred no-op) and FFI cell reclamation (Sections 7.1, 7.4) plug
  into. M2 does not implement the hook.
- **First-class / stored continuations (#6): defer to M3.** Storing a `VCont` in the
  scheduler (`schReady` / promise cells / channels, `Wok.Interp.Sched`) needs the
  unbuilt affine-through-aliasing analysis (`[[explicit-resume-effect-laundering]]`,
  Option B). M2b covers continuations resumed-or-dropped *within* a handler's dynamic
  extent. The scheduler's existing daemonic-drop semantics (race-losers dropped at
  root completion) become "drop the counted continuation" once M3 lands.

## 6. Testing and guard-removal sequencing

- **Oracle suites.** Extend the existing A-F generators with escape/consume/
  cross-region corpora (M2a) and a handler/continuation corpus (M2b).
  Differential-test the RC store against the reference interpreter
  (`Wok.Interp.Machine`).
- **Run-the-exploit verifiers are mandatory** for every soundness claim (lesson from
  `[[async-slice3-provider-model]]`). Each removed guard ships with the exact
  reproducer it used to reject, now passing, plus a `balanceLint` assertion.
- **Guards come down progressively.** M2a-1 narrows #1/#4 to the escaping sub-case;
  M2a-2 removes #1-#4; M2b removes the effects guard.
- **Reproducers to carry forward** (from M1.5 spec): the `peek b` consuming-capture
  double-free (#1/#3); the `mk u = let f ... in let h = \m -> f (m+1) in 0`
  drop-without-call double-free (#4); the nested-letrec cross-region leak (#3).

## 7. Future directions (recorded, out of M2 scope)

These belong to the deferred real backend (`[[higher-ir-direction]]`, QBE/Fable).
M2 stays an analysis milestone; the runtime-agnostic placement analysis is precisely
what lets these be chosen later without redoing M2.

### 7.1 Cell-mutation: three flavors and the trilemma

wok already has mutable state via the `State` effect — but that is **binding-mutation**
(rebind a handler-frame parameter to an already-complete immutable value), not
**cell-mutation** (update a data field in place). Only cell-mutation forges cycles.

For genuine cell-mutation there are three flavors:

- **(a) Scoped token-arena via a provider effect.** `Ref a = Ref U64` (first-class
  plain data); backing cells live in a provider table keyed by the token, scoped by
  `with mem in`. Edges into a cell are index lookups, not counted pointers, so **no
  counted cycle reaches the RC store**. Cost: wholesale-free at scope exit (an
  arena/region allocator); leak-until-scope-exit for churn within the scope.
- **(b) True heap `IORef`.** `Ref a` is a boxed mutable cell — a real counted
  pointer whose field is rewritten in place. This **forges counted cycles** and
  requires Bacon-Rajan. It "works" under the reference interpreter (GHC tracing GC
  collects the cycle) and is uncollectable under the RC store. The GC-vs-RC split is
  the design boundary. **Not offered.**
- **(c) FFI `refIO` behind effect handlers — the sanctioned path.** A real FFI
  mutable cell, exposed only through handler ops (`mem.new/read/write`) with an
  opaque handle. Safe iff the **copy/weak-edge payload discipline** holds: cells
  store only copied, effect-free first-order data (the same restriction `Chan a`/
  `Promise a` already enforce), so **no mutable cell ever holds an owning counted
  reference back into the RC heap**. Two admissible sub-disciplines for inter-cell
  references: (i) cells store pure data only (no handles -> no links -> no cycles);
  (ii) handles stored in cells are *weak ids* with one strong RC'd owner per cell
  (the Rust `Rc`/`Weak` pattern) -> cycles only through weak edges, which RC neither
  counts nor follows; a `read` of a reclaimed weak id is a detectable dangling-handle
  error. The handler *is* the marshalling boundary that makes the discipline
  enforceable (wok code never gets a raw counted pointer to a cell).

**The trilemma.** For a mutable arena you pick two of: *cheap* (uncounted, no RC
traffic) / *mid-run individual reclamation* / *collects cyclic mutable garbage*. Pure
Perceus buys *cheap + wholesale-only* (a) or *cheap + mid-run-for-acyclic* (counted
cells); the third corner needs a scoped Bacon-Rajan collector.

**Mid-run reclaim + bump allocator.** Under flavor (c) with RC'd handles: Perceus
drops a handle at last use, and the **finalizer seam (#5)** frees the FFI/arena cell
on the last drop. Allocation is a bump-pointer; reclaimed slots go on a free-list (a
pool allocator). Mutation also pushes part of the accounting into the `write`
primitive's runtime semantics (drop-old, own-new), because reachability through a
mutated heap is invisible to static last-use.

### 7.2 Scoped arenas generalize the existing region allocator

The `LetRec` uncounted region is already a baby arena (group allocated together,
freed together, intra-group edges uncounted, no per-member refcount on the knot). A
user-facing scoped arena (`with mem in`) is the same idea generalized — same
allocator, same wholesale-free, same uncounted intra-arena edges, same
escape-promotion machinery (M2a-2). It inherits the same three boundaries: escape ->
promote/extend; cross-arena reference -> the #3 shape; unbounded churn ->
leak-until-scope-exit.

### 7.3 Allocator and lifetime tiers

- **Fragmentation.** RC is non-moving (no back-pointers -> cannot compact), so it
  fragments like `malloc`/`free`. Perceus's **reuse analysis (FBIP)** fuses
  same-shape drop-then-alloc into in-place reuse, eliminating the dominant churn;
  **size-class / pool allocators** bound the residual. wok's small, shape-uniform
  nodes suit size classes. "No compaction for raw counted cells" is the accepted cost
  of scan-freedom.
- **Generations are a GC import RC mostly does not need.** Generational GC exists to
  amortize *tracing*; Perceus never traces, so survival-cohort promotion has no
  motivation. The RC-native analogs: (A) **static lifetime tiers already present** —
  static/immortal (top-level, negative addresses) = oldest gen; region/arena = middle
  tier; ordinary counted = young gen — decided at compile time, not by survival;
  (B) **escape-driven promotion = M2a-2** (static, not survival-driven);
  (C) **token-indirected compaction** — the one RC-compatible path to defragmentation:
  token (`U64`) -> table-slot has a single indirection point, so token-arena cells
  are relocatable (rewrite the table slot, every token still resolves), with zero
  pointer-rewriting in the RC heap. Available *only* for the token-indirected tier,
  never for raw counted cells. This is the novel synthesis of the generational
  instinct worth pursuing on the backend.

### 7.4 Resource finalization: RAII, scope-based (decision)

Decision (2026-06-15): external-resource cleanup (e.g. `close fd`) uses **RAII
drop**, NOT a language-level `finally`. Cleanup is a property of the resource's
*type*: when the owning value is dropped, the runtime runs its cleanup — exactly
Rust's `Drop` / C++ destructors, and a natural fit for Perceus, which already
inserts the drop at last-use / scope exit. This **unifies both resource tiers under
the one #5 finalizer seam**: a *scoped* resource is cleaned up because Perceus drops
it at scope exit; an *escaping* resource is cleaned up at its last drop wherever that
falls. No `try`/`finally` construct, no user-written `bracket`.

- **Close-on-cancel is free from M2b:** cancel / race-loss drops the continuation,
  which drops the frames, which drops the resource value, which runs its RAII
  cleanup.
- **Two RAII disciplines (carried from Rust's experience):** (1) a drop's cleanup is
  restricted to first-order, non-continuation-capturing effects — a drop must not
  resume (this also keeps Invariant 3 intact); (2) a cleanup that fails on the
  cancel path has nowhere to propagate, so it is swallowed/logged ("destructors must
  not throw").
- **Open (library/runtime mechanism, deferred):** how a resource type declares its
  drop behavior — likely an `extern` resource type with an `extern` cleanup function
  (`[[extern-primitive-declarations]]`), invoked by the runtime finalizer hook at the
  seam. Decide when the FFI / first-class-resource tier lands.

### 7.5 Manual resources: non-owning tokens + explicit `close`

The complement to §7.4. When a resource must NOT be auto-dropped (it outlives
scopes, is stored, or is handed to/from C), represent it as a **non-owning token**
behind a provider effect, not as an owning RAII value. The drop slides off it: a
token like `data Fd = Fd U64` is plain effect-free first-order data, so Perceus
drops the token box (closing nothing) and the real fd — which lives on the FFI /
provider side, keyed by the id — is released ONLY by an explicit `close` operation
the user writes. Manual management is the *default* for tokens, not a bolt-on to
suppress RAII; no annotation needed.

- **Effect shape:** a provider effect (e.g. `Files`) with `open`/`read`/`close`
  operations; each is an `extern` FFI call (`[[extern-primitive-declarations]]`).
  `close` IS the explicit drop pattern — an ordinary operation in user control flow,
  never compiler-inserted. The token satisfies the payload restriction, so it is
  first-class and can escape freely.
- **Bridge between the tiers (Rust `into_raw`/`from_raw`):** `detach : Owning -> Fd`
  suppresses the RAII drop and yields a raw token the user now manages; `adopt : Fd
  -> Owning` puts a raw token back under RAII. `detach` is the precise "do not
  auto-drop this anymore" operation; this is the FFI ownership-handoff seam.
- **Cost + safety nets:** manual means a forgotten `close` leaks. Two optional,
  philosophy-consistent mitigations: (1) a scoped provider (`with Files in ...`)
  owns the fd *table* and closes leftovers at scope exit (nest at `main` for
  program-lifetime resources); (2) an affine "must-close" LINT reusing
  `Wok.IR.Multiplicity` — warn (not a hard linear type, which the project rejects)
  if an `open` token is not `close`d on every path; a use-after-`close` is
  detectable via the weak-id / dead-slot pattern (§7.1).

## 8. Risks and open questions

- M2a-1's owned/borrowed split touching `balanceLint` is the fiddliest analysis
  change; budget review time.
- M2b assumes a clean explicit-capture handler representation for CPS-form drop
  placement. Confirm the elaborator produces one, or add it to M2b scope.
- The carrier-wall invariant (Invariant 3) must be **checked**, not assumed, once
  `VCont` becomes a counted value.
- The `freeVarsExpr (Handle)` fix may surface previously-hidden free-var accounting
  in handler arms; verify against the reference interpreter.

## 9. Glossary (layman terms)

- **Region / arena.** A group of heap cells with a shared id that are born and freed
  together, with the back-pointers between them not refcounted. Today: a local
  `LetRec` group. Cheap because there is no per-cell counting and freeing is wholesale.
- **Escape.** A value outliving the scope that was supposed to free it. The single
  thing that breaks the cheap model across LetRec, closures, continuations, and arenas.
- **Promotion.** Moving an escaping value from cheap region-lifetime to genuine
  refcounted ownership, so its lifetime follows its refcount instead of a scope.
- **Continuation-aware drop.** Treating a saved continuation as an owner of the
  values on its slice of the stack: resume hands them back, drop-without-resume
  releases them.
- **Binding-mutation vs cell-mutation.** Rebinding a slot to a finished value (safe,
  what `State` does) vs rewriting a field of a live cell in place (forges cycles).
