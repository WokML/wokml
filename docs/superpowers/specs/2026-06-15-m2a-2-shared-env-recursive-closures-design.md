# M2a-2 — shared-env recursive closures (design)

Status: design, pending review. Date: 2026-06-15. Author: brainstorm with Claude.
Companion rationale: `2026-06-15-m2a-2-shared-env-recursive-closures-reasoning.md`
(the full reasoning chain, why the "promoted region via the knot" realization was
rejected, and the §10 addendum locking in uniform borrow-on-call + #1 — read it first
if the *why* matters).
Supersedes: the M2a-2 sketch in
`2026-06-15-m2-continuation-aware-drop-design.md` §4.2 (the "promoted region" stays as
the *semantic* framing; its *runtime realization* changes from an uncounted knot to a
shared environment with code pointers, and the escaping cases are admitted rather than
deferred).

Builds on: M1/M1.5 RC interpreter (`Wok.Interp.RC.{Value,Machine,Prim}`), the Perceus
pass (`Wok.IR.Perceus`), the boundary guard (`Wok.IR.Reachable`), the escape analysis
(`Wok.IR.Escape`), and Suite G (`test/Spec.hs`). Branch base: off
`feat/m2a-1-owned-borrowed-captures` (M2a-1 is NOT yet merged to `main`).

Notation: `══>` counted edge; `┄┄>` uncounted/borrow edge; `[X]` heap cell.

---

## 1. Summary

M2a-2 admits the escaping `letrec` shapes that M1.5/M2a-1 reject — **all four**
historical deferrals (#1 consuming captures, #2 capture-and-escape, #3 cross-region,
#4 closure-captures-sibling) — by **changing how the RC interpreter represents a local
mutually-recursive group**. Instead of N closure cells whose environments point at
each other (a refcount **cycle**, dodged today by an uncounted "region" freed wholesale
at scope exit), a group becomes:

- **one shared environment cell `E`** holding the group's captured enclosing locals
  (ordinary, reference-counted, freed exactly once); and
- **inline recursive-member values** `RVRecMember(groupAddr, index, envAddr)` that
  resolve siblings through a **code pointer** (the group's code, installed as a static
  immortal cell), not through a stored sibling closure.

The recursion lives in the *code* (known/direct calls via the code pointer), so the
*data* is a **DAG** — acyclic by construction. Two convention choices make the rest
ordinary:

- **Uniform borrow-on-call** (Decision D1, locked): calling *any* function value
  (member or closure) **borrows** it — never consumes it; function values are dropped
  at their last use by the pass. This removes the need for any escape-site wrapper: a
  bare `RVRecMember` escapes and is called externally with matching semantics.
- **Captures are borrowed** into member bodies, with **dup-on-consume**. This is the
  genuine borrow-passing that admits #1 (Decision D2, verification-gated): the capture
  lives once in `E`, a consuming use dups it *inside the body, per-execution*, so the
  runtime count is right by construction — fixing the exact failure that deferred #1.

The entire "uncounted region" apparatus and the multiset capture accounting **retire**.
Soundness is established by **bisimulation to acyclic Perceus** (Koka's published model,
with borrowed function values and borrowed captures — both standard Perceus features),
not a bespoke invariant.

"Promoted region" stays the intuition/vocabulary (a clump that gains a refcounted
lifetime on escape); "shared env + code pointers, everything borrowed" is the
realization.

---

## 2. Scope

**In scope (guards taken down, now sound):**

- **#2** — a member captures an enclosing local AND a member escapes.
- **#3** — an inner group captures an outer group's member (cross-region), **both**
  the escaping and non-escaping sub-cases (ordinary DAG edges here; no contagion
  analysis).
- **#4** — a standalone closure (or alias) captures a sibling and escapes.
- **#1** — a member *consumes* (moves) an enclosing capture, admitted via
  borrow-from-`E` + dup-on-consume (§3.7, §4). **Verification-gated** (Decision D2): the
  `consumeViol` guard is removed only after the former unsound corpus runs
  heap-balanced. If verification unexpectedly fails, #1 alone stays rejected.

**Out of scope:** effects and continuations (M2b); genuine cell-mutation cycles (M2
spec §7.1, unchanged). No new cycle collector — the design keeps Bacon-Rajan unneeded
by construction.

This slice is a **representation + calling-convention change to M1's closure model**,
larger than an incremental patch: it reworks `enterRC`/the pass's call-head handling
(uniform borrow), replaces the region representation, and regenerates Suite B goldens.
Accepted deliberately for the cleanest, most complete, backend-aligned end state
(reasoning doc §8, §10.4).

---

## 3. Runtime design (`Wok.Interp.RC.Value` + `Wok.Interp.RC.Machine`)

### 3.1 Values

Extend `RCValue` with one inline variant:

```
   data RCValue
     = RVLit Lit
     | RVBox Addr
     | RVRecMember Addr Int Addr      -- groupAddr (static), index, envAddr (counted)
```

`RVRecMember g i e` is a recursive-member value: `g` is the static immortal address of
the group's installed code; `i` selects the member; `e` is the shared env cell (or a
sentinel for capture-free groups, §3.3). Its **counted child is `e` only**; `g` is
static (skipped).

`RVRecMember` is a genuine third value category, **not** a `Lit`. It is inline (copied
by value, never its own heap cell) *like* a `Lit`, but it **owns a counted reference**
(its env), so dup/drop must act on it. The taxonomy is "what are this value's counted
children?":

```
   variant                inline?   counted children      dup/drop
   ────────────────────   ───────   ───────────────────   ──────────────────
   RVLit Lit              yes       none                  no-op
   RVRecMember g i e       yes       [e] (the shared env)  incref/drop e
   RVBox a                no        [a] (the cell)        incref/drop a
```

Treating `RVRecMember` as a `Lit` would make dup/drop no-ops and **leak `E`** — a
soundness bug. The one case that genuinely *is* `Lit`-like is a **capture-free**
member: its `e` is the static empty-env sentinel (§3.3), so `valueChildren` yields a
static addr and dup/drop collapse to no-ops — a single variant spans both ends.

Centralize child enumeration so every consumer agrees (the
`Wok.IR.Escape`-consolidation lesson):

```
   valueChildren :: RCValue -> [Addr]      -- counted addrs reachable from a value
   valueChildren (RVLit _)            = []
   valueChildren (RVBox a)            = [a]
   valueChildren (RVRecMember _ _ e)  = [e]
```

`boxedChildren`/`nodeValues` and `incref`/`dropAddr` route through `valueChildren`, so
a constructor/record field holding an `RVRecMember` cascades into `e` on drop and a
dup/drop of a member value operates on `e`. Rendering adds its own case
(`RVRecMember → "<closure>"`, matching the reference interpreter so the differential
oracle is unperturbed); an `RVRecMember` is never a valid `Case` scrutinee (a function
value is not matched by constructor patterns).

`RVRecMember` establishes a reusable representation category — an **inline fat value
that owns counted children** — distinct from both unboxed scalars (`RVLit`) and heap
pointers (`RVBox`). M2b's captured-continuation value is expected to reuse this category
(an inline handle owning counted frame references), so keep the category and
`valueChildren` general rather than `RVRecMember`-specific.

### 3.2 The group code as a static cell

Install each `letrec` group's code (`[(Binder,[Binder],Expr)]`) **once** as a static
immortal cell (negative address, via `allocStatic`) referenced by `groupAddr`:

```
   data Node = … | NGroupCode [(Binder,[Binder],Expr)]
```

`NGroupCode` lives only at static addresses — never counted, dropped, or cascaded into.
It is a code label. (Per-evaluation install is correct; interning identical group code
is an optimization, Decision D3.)

### 3.3 The shared env cell `E`

`E` is an ordinary counted cell holding the group's captured enclosing locals, **once**:

```
   data Node = … | NEnv (Map Unique RCValue)
```

`E`'s fields are the values of enclosing free variables captured by *any* member
(`union over members of (FV(body_i) \ params_i \ groupBinders)`, restricted to the
enclosing scope). `E` is reference-counted normally; its drop cascades into its
captured fields exactly once — **no per-member multiset**.

**Capture-free groups allocate no `E`.** If the capture union is empty, members are
`RVRecMember(groupAddr, i, sentinel)` for a fixed static "empty env" `sentinel`. Such a
group allocates **zero** dynamic cells — strictly cheaper than the knot model and the
M2a-1 region (both allocated N cells).

**"Capture-free" means no enclosing local — boxed _or_ unboxed (BLOCKER 2 reconciliation).**
The counted-env predicate is *captures any bound enclosing local*. A group that captures
**only unboxed** locals (e.g. corpus 36's `f n = case n of 0 -> u; _ -> f (n-1)` with
`u : U64`) still allocates **one** counted `E`: the unboxed value must be stored in `E` so
the member body can resolve it, and the single cell needs exactly one drop regardless of
field boxedness. The pass does **not** re-derive boxedness for env existence; it represents
`E` by the group's member-0 unit and unconditionally emits one `__rc_dup`/`__rc_drop` of it
per escape / scope-exit, which the runtime resolves to `incref`/`dropAddr envAddr` —
no-ops on the sentinel, one ref op on a real cell. So both sides agree by routing through
`valueChildren`/`dropAddr`, not a duplicated predicate. The pass's boxed-only `memberCaps`
filter governs only the capture-**move** accounting (which owned units are moved into `E`
and dup-planned); unboxed locals are never reference-counted, so they need storage for
evaluation but no move/dup.

### 3.4 `LetRec` evaluation

Replace the knot construction in `evalExprRC (LetRec defs body)`:

1. Install the group code as a static cell → `groupAddr` (or reuse if interned).
2. Compute the captured-local union; if non-empty, `alloc (NEnv capturedFields)` → `E`
   (rc = 1, the scope's owning handle); else `E := sentinel`.
3. Bind each member `f_i` in the body scope to `RVRecMember(groupAddr, i, E)` — these
   are inline values; **no per-member heap cell, no knot**.
4. Evaluate `body`.

No `allocLetRecGroup`, no region id.

### 3.5 Calling a function value: uniform borrow (no consume)

`enterRC` borrows the function value in **all** cases — it never drops the value and
never increfs its captures on call:

- **`RVRecMember g i E`** applied: look up `g` → `NGroupCode defs`; take member
  `i = (b_i, ps_i, body_i)`; build the call scope = args bound to `ps_i` + captured
  locals **borrowed** from `E`'s fields + **every sibling** `f_j ↦ RVRecMember(g,j,E)`
  (inline, **no allocation**); evaluate `body_i`. A sibling reference used as a call
  head is therefore a **known call** — direct entry with `E`, no value consumed, no
  heap edge. This is what keeps the heap acyclic.
- **`NClosure cenv ps body`** applied: bind `ps` to args + captured values **borrowed**
  from `cenv`; evaluate `body`. The cell is **not** dropped and captures are **not**
  increfed.

In both cases the function value stays owned by its binder and is dropped at its last
use by the pass (§4). It is alive throughout its own call (its binding lives in the
suspended caller scope), so borrowing its captures during the body is safe.

Scope note: **borrow applies to the function value at the call head only.** Argument
passing keeps its current ownership treatment; borrowed-*parameter* analysis is a
separate, deferred Perceus feature and is out of scope here.

Partial application / over-application follow standard borrow accounting: a partial
application reads the original value (borrow) and builds a fresh closure capturing
dup'd copies of the shared captures plus the supplied args; the original is dropped at
its last use. (`RVRecMember` partial application produces an ordinary `NClosure`
capturing the member — acyclic. This path is a named verification corner, §8/D2.)

### 3.6 Escape is an ordinary move (no wrapper)

Because all calls borrow, an escaping member needs no special treatment: a member used
in a non-call-head position (returned, stored in a con/record/list, passed as a
non-head argument, captured by a nested closure, aliased) is an ordinary **move** of
the `RVRecMember` value into that position — exactly as for any value. If the same
member is also needed elsewhere in an owned position, the pass emits a dup
(`incref e`). An escaped `RVRecMember` is callable anywhere: `g` is static, `E` is kept
alive by the escaped value's own counted reference. No closure-conversion, no wrapper,
no per-escape allocation. (`RVRecMember` `══>` `E` is a DAG; cross-region #3 is just
`E_inner ══> RVRecMember(outer) ══> E_outer`, inner younger than outer.)

### 3.7 Refcount lifecycle of `E`, and the #1 mechanism

`E` is an ordinary owned value:

- born `rc = 1` at `LetRec` eval (the scope's handle);
- each escaping/owned member occurrence that survives dups `E` (`incref e`);
- at `LetRec` scope exit the scope's handle is dropped;
- function values (including escaped members) are dropped at last use → `dropAddr e`;
- when `E.rc → 0`, `E` is freed and its captured-local fields cascade once.

Non-escaping group (no owned member occurrences): `E.rc` returns to 0 at scope exit →
freed there. Escaping group: `E` outlives the scope, freed at the last reference's
drop. This is the "promoted region" semantics realized as the refcount of one ordinary
cell.

**#1 (consuming captures)** is the borrow-from-`E` discipline: `E`'s captured fields are
bound into member bodies as **borrows**. A consuming use of a capture dups it
(`incref`) *inside the body* before the move — so the dup runs **once per execution** of
that use, and the runtime count matches regardless of how many times (and which) members
are called. This is the genuine borrow-passing the M2a-1 deferral required; it fixes the
build-site static-count failure (SUM leaked, MAX UAF'd). `E` keeps its own ref; the
dup'd copies flow out and are dropped by their holders. (Concrete trace in the reasoning
doc §10.2.)

### 3.8 What retires

The knot gone and the convention uniform, the following M1/M2a-1 machinery is removed or
reduced to no-ops: `allocLetRecGroup`, `writeRegionCell`, `regionPlaceholder`,
`stRegionOf`, `stNextRegion`, `isRegionAddr`, the region branch of `isBorrowedAddr`, the
region-skip in `countedChildren` (now skips static only), `mkClosure`'s borrowed-capture
set / `closureBorrowed` / `closureOwnedBoxed`, the consume-on-call logic in `enterRC`
(replaced by borrow + pass-inserted last-use drops), and the multiset capture accounting
in the pass (`capOcc`, the capture `dups` plan). `countedChildren` becomes "skip static,
recurse into everything else" — ordinary acyclic refcounting.

---

## 4. Pass design (`Wok.IR.Perceus`)

The pass simplifies: members, `E`, and closures are ordinary values under one borrow
convention.

- **Call-head is a borrow, not a move.** The head of `RApp f as` no longer consumes
  `f`; `f` is owned by its binder and dropped at its **last use** by the standard
  last-use machinery (which already places drops for ordinary values). This replaces the
  current "the call consumes the head" treatment in `ownExpr`/`moveAtoms`. Arguments are
  unchanged (still owned).
- **`LetRec` instrumentation** drops the region special-casing. `E` is a *synthetic*
  owned value: born `rc = 1` (the scope handle), and the pass inserts a synthetic drop
  of `E` at the `LetRec` body's exit — its last use — exactly as for a hidden
  `let`-binding (no user binder names it). Member-body scope bindings (siblings, `E`'s
  captured fields) are **borrows** — bound without an incref and discarded with the
  scope, valid because the function value holding `E` is alive (borrowed, not consumed)
  for the body's duration. Captured locals are moved into `E` at build unless they
  survive into the body (then dup'd once — ordinary, not per-member). Member references
  are ordinary: a call-head occurrence is a borrow (a known call, emit nothing for the
  value), an owned/escaping occurrence is a move with a dup (`incref e`) if needed.
- **Captures are borrowed into member bodies** (`E`'s fields), so a consuming use gets a
  dup-on-consume by the standard borrowed-value rule. This is the #1 mechanism (§3.7) —
  it replaces the former "borrowed-read-only, fully exempt" `ctxExempt` treatment with
  "borrowed, dup-on-consume."
- No `__rc_promote` marker, no `C=N` seed, no `ctxExempt` region set.
- `balanceLint`/`lintInstrumented` need no special LetRec cases beyond treating
  `RVRecMember`/`NEnv` as ordinary values; verify they stay clean (§8).

---

## 5. Boundary guard (`Wok.IR.Reachable`)

Remove the LetRec escape/consume rejections that this design makes sound:

- `escapeViol` (#2) — removed.
- `crossRegionViol` (#3) — removed (both sub-cases are ordinary DAG edges).
- `siblingEscapeViol` (escaping #4) — removed.
- `consumeViol` (#1) — removed **after** Decision D2 verification passes (the former
  unsound corpus runs heap-balanced); otherwise retained as the sole LetRec rejection.

The only guards that remain are the genuine out-of-fragment ones: `Handle` and `ROp`
(effects, M2b). After this slice the RC fragment is "first-order, no effect handlers,"
with **no LetRec restriction**.

---

## 6. Soundness

The argument is **bisimulation to acyclic Perceus**, not a bespoke invariant:

1. **Acyclic by construction.** Every counted heap edge points younger→older: a member
   value ══> `E`; `E` ══> its captured locals (older enclosing values); cross-region
   `E_inner` ══> an outer member ══> `E_outer` (inner younger). The recursion edges
   (`f → g`) are **code pointers**, not heap edges, so they cannot close a counted
   cycle. No counted cycle can form ⟹ plain reference counting is complete ⟹
   Bacon-Rajan stays unneeded.
2. **Ordinary Perceus on a DAG, with borrowed function values and borrowed captures.**
   Both borrowing forms are standard Perceus features covered by the published
   correctness result; the dup/drop machinery already implements ordinary RC. M2a-2
   removes special cases rather than adding them, so it stays inside that result. The
   borrow convention changes *where* dup/drop fall (last-use drops, dup-on-consume), not
   the heap's edge structure.
3. **M2 invariants preserved.** Invariant 1 (no counted cycles) — by construction.
   Invariant 2 (no counted edge into region/static) — there is no region; only static is
   special, skipped as before. Invariant 4 (conservative) — the only remaining
   rejections are genuine out-of-fragment features (effects); #1 is removed only on
   passing verification.

The differential oracle still holds: the RC interpreter's `RVRecMember`/`NEnv`
representation diverges from the reference interpreter's lazy-knot `VClosure`, but both
compute the same observable values and render closures identically, so
`prop_rcDifferential` / Suite G output comparisons are unaffected (verify, §8).

---

## 7. The interface for M2b

The shared-env model is the seam M2b reuses. A captured continuation is a delimited
slice of frames allocated together that may escape into a scheduler; it maps onto the
same shape: a shared env-like unit (the frames' owned values) referenced through
code/handle pointers, freed by ordinary refcount when the last external reference (the
scheduler's hold, or the resume site) drops. M2b inherits **acyclic by construction**
rather than a bespoke region-promotion mechanism — the carrier-wall invariant (no
`VCont` inside the data it owns) keeps the frame graph a DAG, exactly as the
recursion-in-code rule does here. Name the runtime pieces generically (`NEnv`,
code-pointer reference) so M2b does not re-derive them.

---

## 8. Verification plan (mandatory run-the-exploit)

Discipline carried from M2a-1 (five latent bugs that example tests missed): every
admitted shape ships with a run-the-exploit check, and the generative property *runs*
the now-admitted programs.

- **Suite G generator** (`test/Spec.hs`) extends to emit the now-*admitted* shapes as
  **ACCEPT-and-must-run-sound**: returned / con-/record-/list-stored /
  nested-escaping-closure / aliased members; **cross-region** (inner captures outer,
  both escaping and non-escaping); a **mutually-recursive escaping** group;
  **conditional escape** (one branch escapes, one not); **multi-escape** (same member
  escaping more than once); and the **consuming-capture (#1)** shapes — including the
  two-member-both-base-cases-consume counterexample that defeated M2a-1's build-site
  dup. `prop_m2a1Escape` asserts: boundary-accepted ⟹
  `runModuleRCUnchecked (insertRC (pruneToReachable cm))` succeeds, is heap-balanced
  (`stLive == baseline` AND `allocs - frees == baseline`), AND matches the reference
  interpreter's value.
- **#1 gate (Decision D2):** the former unsound corpus (e.g. `test/rc-m2a1/33` and the
  two-member consuming group) must now run **heap-balanced** before `consumeViol` is
  removed. If it does not, #1 stays rejected and this gate fails loudly.
- **Capture-free recursive groups** must show **zero** group allocation (the `E`-less
  path) — a dedicated accounting assertion (the new common-case win).
- **Uniform-borrow regression:** the existing corpus (currently 1058) must stay green
  under borrow-on-call — same observable values, heap-balanced. Suite B alloc/free
  totals are largely unchanged by the convention (it shifts dup/drop *timing*, not
  alloc/free totals); peak and the LetRec representation change *do* shift goldens.
- **Partial application / over-application** under borrow, for both `NClosure` and
  `RVRecMember`, get explicit reproducers (the named convention corner).
- **`prop_m2a1Teeth`** fault-injection (OmitOneDrop/OmitOneDup/DuplicateOneDrop) extends
  to the new shapes.
- **Suite B goldens regenerate** (one `E` cell or zero instead of N member cells; new
  last-use function-value drops). Each regenerated golden is reviewed for plausibility,
  not blindly accepted.
- The full suite stays green.

---

## 9. Decisions and open questions

- **D1 — calling convention: uniform borrow-on-call (LOCKED).** Every call borrows the
  function value; function values are dropped at last use; no wrappers; a bare
  `RVRecMember` escapes freely. Recorded fallback: closure-convert members at escape
  sites into ordinary wrapper closures (keeps consume-on-call, contained blast radius) —
  adopt only if the convention change proves too costly. (Reasoning doc §7, §10.3.)
- **D2 — #1 admitted via borrow-passing (verification-gated).** Mechanism settled
  (borrow-from-`E` + dup-on-consume, §3.7); `consumeViol` removed only after the former
  unsound corpus runs heap-balanced (§8). Open only as a verification gate, not as a
  design question.
- **D3 — group-code interning.** Per-evaluation `NGroupCode` install is correct; interning
  identical group code is a deferred optimization (does not affect the dynamic-heap
  oracle, only static-cell counts under loops).
- **Open — reference-interpreter parity.** Confirm `RVRecMember`/`NEnv` results match
  `Wok.Interp.Machine` across the corpus (output oracle). Expected fine; must check.

---

## 10. Risks

- Largest risk is **scope/regression from the calling-convention change**: borrow-on-call
  reworks `enterRC` and the pass's call-head handling for *all* closures, plus the
  representation change reopens M1's closure model and regenerates Suite B. Mitigate by
  keeping the *reference* interpreter unchanged and leaning on the differential + heap
  oracles to catch divergence early; stage the convention change and the representation
  change as separately reviewable steps if the red-test window grows.
- `RVRecMember` threads through every place that scans `RCValue` for boxed children,
  dup/drop, rendering, and Case scrutiny — mechanical but broad; `valueChildren`
  centralizes it (one source of truth).
- **Borrow-on-call timing**: a function value must stay live through its own call so its
  captures can be borrowed; the pass must place its last-use drop *after* the call
  returns, never before the body. Partial application under borrow needs the dup-on-share
  accounting (§3.5). Both are named verification corners.
- **D2 (#1)** is verification-gated; do not remove `consumeViol` until the corpus runs
  heap-balanced.

---

## 11. Future directions (recorded, out of scope)

- **Lambda-lift recursive groups to top-level static code** and **register-passed
  environments** are the compiled-backend forms this slice approximates; `RVRecMember`
  is the interpreter stand-in for a code label, and uniform borrow-on-call is already the
  backend-aligned convention. When the backend (`[[higher-ir-direction]]`, QBE/Fable)
  lands, the interpreter-side sibling reconstruction gives way to direct known calls.
- **Borrowed-parameter analysis** (borrowing arguments, not just the function value) is
  the natural next Perceus refinement, deferred here to bound scope.
- **From-main region/usage DCE** (interprocedural escape/usage analysis) could later
  *demote* provably-unobserved escapes — an optimization atop this sound base, kept
  separate because a wrong demotion is a UAF; the M2 spec's coarse `pruneToReachable` is
  the existing bind-granularity precedent.

---

## 12. Glossary (layman terms)

- **Recursion in code vs. in data.** Mutual recursion implemented as direct calls to
  static code (a code pointer) versus closures that store each other (a heap cycle). This
  design keeps it in the code.
- **Known vs. unknown call.** A call whose target is statically determined
  (self/sibling/top-level → direct, no closure value) versus a call through a first-class
  function value.
- **`RVRecMember`.** The inline recursive-member value: static code pointer + which
  member + shared-env address. Lets a sibling reference resolve to *code*, not a cyclic
  closure cell.
- **Shared env `E`.** One heap cell holding a recursive group's captured enclosing locals
  (once), reference-counted normally. The "unit" whose lifetime is the group's.
- **Borrow-on-call.** Calling a function value reads (borrows) it rather than consuming
  it; the value is dropped at its last use. The uniform convention here.
- **Borrow-passing / dup-on-consume.** A capture is owned once by `E` and lent (borrowed)
  to each member invocation; a consuming use dups it on the spot, per-execution. The
  mechanism that admits #1.
- **Bisimulation to acyclic Perceus.** The soundness method: show this behaves like
  ordinary reference counting on an acyclic heap (with standard borrowing), which the
  literature already proves correct — rather than defending a hand-built invariant.

---

## 13. Deferred: #1 consuming captures (verification gate, 2026-06-16)

A soundness gate empirically tested whether consuming captures (#1) are NOW sound under
the shared-env borrow model. **Verdict: DEFERRED-AS-EXPECTED.** `consumeViol` stays in
`Wok.IR.Reachable.exprScopeFeaturesWith` unchanged; no test was weakened.

### Reproducer

The two-member-both-consume group Suite G originally used (`rcM2a1ConsumeCaptureRejected`):

```
main = let cap = Tuple2(9,5)
       letrec lrf k1 = case k1 of 0 -> <move cap into Box, read back, return px>
                                  _ -> lrg (k1 - 1)
              lrg k2 = case k2 of 0 -> <move cap into Box, read back, return py>
                                  _ -> lrf (k2 - 1)
       let lrr = lrf <depth> in lrr
```

The boundary guard was temporarily bypassed (`consumeViol = []`) and the pass + unchecked
RC interpreter run directly: `runModuleRCUnchecked (insertRC (pruneToReachable cm))`.

### Measurement

| variant                          | depth (initial arg) | ref / rc value | baseline | live | allocs | frees | value-match | runtime-balanced |
|----------------------------------|---------------------|----------------|----------|------|--------|-------|-------------|------------------|
| simple (base cases consume)      | 0                   | 9              | 0        | 0    | 3      | 3     | yes         | yes              |
| simple                           | 1                   | 5              | 0        | 0    | 3      | 3     | yes         | yes              |
| simple                           | 2                   | 9              | 0        | 0    | 3      | 3     | yes         | yes              |
| simple                           | 3                   | 5              | 0        | 0    | 3      | 3     | yes         | yes              |
| simple                           | 4                   | 9              | 0        | 0    | 3      | 3     | yes         | yes              |
| hard (recursive arm consumes too)| 0                   | 9              | 0        | 0    | 3      | 3     | yes         | yes              |
| hard                             | 1                   | 14             | 0        | 0    | 4      | 4     | yes         | yes              |
| hard                             | 2                   | 23             | 0        | 0    | 5      | 5     | yes         | yes              |
| hard                             | 3                   | 28             | 0        | 0    | 6      | 6     | yes         | yes              |
| hard                             | 4                   | 37             | 0        | 0    | 7      | 7     | yes         | yes              |

Runtime is heap-balanced and value-correct at every depth — the dynamic dup-on-consume DOES
land per-execution (the instrumented ANF shows `let _dup = __rc_dup(cap)` INSIDE each
consuming base/rec arm, not at the build site, so only the taken path dups).

### Why it is still UNSOUND in general (the static oracle disagrees)

With `consumeViol` bypassed, Suite G's **`prop_m2a1LintClean` went RED**, and the
compile-time balance oracle (`balanceLint`) flags even the SIMPLE reproducer:
`["main: leak of u0 (1 unit(s) never consumed)"]` (u0 = `cap`).

Root cause: the capture `cap` is moved into the shared env `E` exactly ONCE (one consume of
its single owned unit), and `E` is released by one env-drop at group scope exit. But each
member's consuming base/rec arm independently emits `__rc_dup(cap)` and a matching
cascade-drop. The path-TAKEN at runtime balances because exactly one base case fires and the
dynamic dups match that path. The **path-insensitive multiset accounting** that underwrites
soundness for ALL call patterns cannot reconcile it: it sees the capture's owned unit moved
into `E`, plus per-arm dup/drop pairs, with no statically-balanced bind-level ledger. The
failure is acute in the **nested/escaping** case the property surfaced (an inner
consuming-capture group whose member is RETURNED through an OUTER group): the inner `E` is
never dropped because the inner member escapes, so `cap`'s move into `E` genuinely leaks and
no dynamic path repairs it. Runtime "balanced" there only because `main` returned the
uncalled closure and the leak path was never executed — the classic necessary-not-sufficient
trap.

### What additional mechanism is needed

The shared-env model alone is insufficient. Sound #1 needs the capture to be **borrow-passed**
rather than moved-into-`E`-then-dynamically-dup'd: the enclosing region keeps owning the
capture, lends a borrow to each member invocation, and a consuming use dups against the
*owning region* with a bind-level ledger that `balanceLint` can certify path-insensitively —
equivalently, **continuation-aware drops** that thread the per-execution dup/drop obligation
through the call so the static accounting matches the dynamic one regardless of which member
terminates the recursion or whether the group escapes. Until that lands, `consumeViol`
rejects ANY consuming use of an enclosing capture (escaping or not); a rejected program is
never compiled and is therefore sound.

Regression teeth: `rcM2a1ConsumeCaptureRejected` now additionally asserts
`balanceLint (insertRC pruned)` is non-empty on the bypass reproducer — if a future change
ever makes the dup-on-consume emission "lint clean" by weakening the oracle rather than by
adding borrow-passing, this assertion catches it.

---

## 14. Retain/release unification (partial application of a shared-env member, 2026-06-16)

`valueChildren` is the single source of truth: capture-incref and the free-cascade
share one enumeration (`countedRefs`), so every value shape (`RVBox`, `RVRecMember`,
any future variant) is retained exactly as it is released. The drop cascade
(`dropAddr`) routes through `countedRefs (nodeValues n)`; the borrowed-Set on
`NClosure` — and `borrowedCaptures`/`closureBorrowed`/`countedChildren`/`boxedChildren`/
`isBorrowedAddr` — are removed, because `isStaticAddr` is the single
borrowed-vs-owned predicate for the *free*. A capture's address being dynamic vs
static is what the cascade keys on; there is no parallel set to drift.

**Moves are bound without incref but consumed by the drop.** A moved argument's
reference transfers from the caller; it is *not* incref'd on the cell's build but *is*
released by the cell's drop cascade — that is how the move is consumed. Captures are
the opposite: a cell *acquires* one ref to each capture where the capture enters the
cell (a Perceus `__rc_dup` at an escaping capture, or the build-time incref in
`enterRC`'s partial-application branches) and the cascade releases it.

**Body-seed vs cell-cascade are two distinct matched pairs.** Whether a closure
*body* receives ownership of its captures on entry is a separate question from what
the *cell* owns. An `RLam` body owns its boxed captures (Perceus seeds them `+1` and
drops them at last use), so `enterRC`'s `increfOwned` hands the body that ownership
(`closureOwnedBoxed` = the dynamic `RVBox` captures). A **member-body partial
closure** (the partial application of an `RVRecMember`) has the member body, which
*borrows* its siblings and captured locals (a member never consumes a capture — #1 is
deferred) and emits no drops for them; so its `CaptureMode` is `BorrowCaptures` and
`closureOwnedBoxed` is empty — the body-seed incref must touch nothing, or the
unmatched incref leaks the shared env. The cell nonetheless owns one ref to each
capture (acquired at the partial-application build), released by the cascade. The
original report's "make `closureOwnedBoxed` = `countedRefs (env)`" conflated these two
pairs; doing so leaks the env for every borrowed-`RVRecMember` capture (an `RLam`
that captures an escaping sibling, and the member-body partial closure). The
`CaptureMode` distinction is the minimal sound encoding of the body's capture
discipline.

**The bug and its closure.** Partial application of a multi-arity member double-freed
the shared env: the cascade was `RVRecMember`-aware while the build acquired nothing.
The fix acquires the `RVRecMember`/`NEnv` captures at every point a partial-application
cell takes them — both the `RVRecMember` LT branch and the `NClosure` LT branch
(which now acquires *all* shared captures uniformly and propagates `CaptureMode`, so a
partial-of-a-partial of a member closure stays sound) — and releases the floating env
handle for an unnamed intermediate. A non-sentinel dead/dangling env deref in the
`RVRecMember` arm is a `Left`, not a silent `Map.empty` (no UAF-as-`UnboundVar`
laundering). Suite G gained an arity + saturation dimension (`M2PartialMember`) and a
`checkCoverage` floor so the partial-application class is generated, run, and proven
sound — not silently dropped.

## 15. Deferred: nested capturing groups (verification gate, 2026-06-16)

A `LetRec` group **nested inside an enclosing `LetRec` member body** that captures
an enclosing **boxed local** double-frees that local — whether the inner group
**escapes** the local (returns it) or only **borrow-reads** it. This is a distinct
class from #1 (consuming captures) and #3 (cross-region): the captured value is an
ordinary enclosing local, not a sibling group member, and the inner group's use of
it is borrow-safe. The boundary guard now **rejects** it (a rejected program is never
compiled, so it is sound); the fix is deferred.

### Reproducers (both verified via `runModuleRCUnchecked`: reference returns 7, RC double-frees `addr 0`)

```
-- CLAIM 1 (escape): inner group RETURNS the enclosing local b
main = let b = Box 7 in
       letrec f k = (letrec h j = Ret b in let r = h 0 in Ret r)
       in let res = f 0 in case res of Box v -> Ret v

-- CLAIM 2 (borrow-read): inner group only READS the enclosing local b
main = let b = Box 7 in
       letrec f k = (letrec h j = (case b of Box v -> Ret v) in let r = h 0 in Ret r)
       in let res = f 0 in Ret res
```

### Root cause

Each `LetRec` group materializes its **own** `NEnv` copying the captures it needs.
Nesting one capturing group inside another's member body puts the **same enclosing
local in multiple counted `NEnv` cells** — and the inner `NEnv` is rebuilt **per
entry of the enclosing member**. The inner `NEnv`'s cascade reference to the
enclosing local is **not backed by an incref**: the pass treats a member-body
capture as borrowed/moved-once (a member never consumes a capture; #1 is deferred),
so neither the pass nor `enterRC` increfs the enclosing local where the inner env
acquires it. At scope exit the inner env's cascade frees the local once and the
enclosing scope frees it again — a double-free.

A **flat** (non-nested) group capturing an enclosing local is sound: one env cell,
one cascade, the local freed exactly once. A group sequenced in an enclosing
`LetRec`'s **continuation body** (not a member body) is also sound: it runs once, so
its single env cascade is balanced. Only a group nested in a **member body** (rebuilt
per member entry) is unsound.

### Boundary guard

In `Wok.IR.Reachable.exprScopeFeaturesWith`, a fourth threaded flag `mb` marks
"currently inside an enclosing `LetRec` MEMBER body" (set when descending into a def
RHS, **not** propagated into the continuation body). At a `LetRec` node the guard
rejects iff `mb` holds **and** `rawEnclosingFv defs ∩ bsc` is non-empty (the inner
group captures an enclosing boxed local — distinct from `∩ lr`, the cross-region #3
check). The existing `crossRegionViol` (#3) and `consumeViol` (#1) are unchanged.

### Fix direction

Unify `NEnv` construction's field-incref with the move-vs-copy distinction for nested
**re-capture**: when an inner env acquires an enclosing local that is also held by an
outer counted env, emit the acquiring incref (a `__rc_dup` where the inner env takes
the capture, balanced by the inner env's cascade). The alternative is to **share the
enclosing env by reference** instead of copying the local into a second `NEnv`, so
there is exactly one counted cell per local across the nesting. Either unifies with
the M2a-2 borrow-from-E discipline (§3.7) once nested re-capture is handled.
