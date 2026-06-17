# M2b — Continuations + Effects on the RC Store (design)

Status: design, pending implementation. Date: 2026-06-17. Author: brainstorm with Claude.
Predecessor: `docs/superpowers/specs/2026-06-15-m2-continuation-aware-drop-design.md` (the
M2 umbrella design; M2a-1 + M2a-2 merged on main, HEAD ~`607b56d`).

> **Supersedes** §4.3 of the M2 umbrella doc. That section assumed M2b's Perceus input
> would be a CPS / explicit-capture IR form. There is no such IR: continuation capture is
> performed dynamically by the CEK machine (`dispatchOp`/`findHandler` walk the live
> `Kont`). This doc records the decision to take the **runtime-centric approach, built
> B-ready** (see §2), and details the design that follows from it.

## 0. Summary

M2b is the third slice of the M2 reference-counting (RC) milestone. Effect *semantics*
already exist on the **reference** interpreter (`Wok.Interp.Machine`): it has `KHandle`
frames, reifies captured continuations as `VCont`/`VContP` at runtime in `dispatchOp`,
and resolves handlers by walking the `Kont` in `findHandler`. The **RC** interpreter
(`Wok.Interp.RC.Machine`) currently *rejects* effects outright (`Handle`/`ROp` →
`"rc M1: effects not supported"`). M2b brings reference counting **to** those existing
semantics; it does **not** redesign effects.

The job: teach the RC store to reference-count **effect-handler frames** and **reified
(escaping-within-the-handler) continuations** soundly, lifting the no-handler restriction,
and ship a `State` handler running heap-balanced as the acceptance case. The reference
interpreter is the differential heap-balance oracle throughout.

Two sub-slices (mirroring the M2a-1 / M2a-2 split):

- **M2b-1** — the prerequisite `freeVarsExpr (Handle)` fix; a counted handler frame in the
  RC store; the **tail-resume** and **abort (no-resume)** paths for **no-parameter,
  one-argument** handlers. Acceptance: `Reader`/`ask`, a tail-resuming writer, and
  `Except`/abort, all heap-balanced against the reference interpreter.
- **M2b-2** — handler **parameter** (`hParam`), **two-argument** `resume` (`VContP`),
  **non-tail / value-position** resume (the `hAnswerJoin` answer-redirect), and the
  carrier-wall check. Acceptance: the full `State` `get`/`set` runner, with both tail and
  non-tail resume, heap-balanced.

Each sub-slice is its own branch with its own full-branch `/code-review` before merge to
main (repo culture; `[[review-before-merge]]`).

## 1. Verified ground truth

Confirmed against the repo on 2026-06-17 (memories are point-in-time; these were
re-checked against current code):

- **RC interpreter rejects effects.** `Wok.Interp.RC.Machine` line ~165 (`Handle`) and
  ~207 (`ROp`) both return `Left (PrimError "rc M1: effects not supported (no-handler
  fragment)")`. `RCKont = KDoneRC | KLetRC | KAppRC | KDropCellRC` — **no `KHandle`
  analogue** (`Wok.Interp.RC.Value` ~131).
- **Reference interpreter runs effects fully.** `Kont` has `KHandle Handler !Int Scope
  Kont` (`Wok.Interp.Value` ~106). `Value` has `VCont (Kont -> Kont)` and `VContP (Value
  -> Kont -> Kont)` (~59). `dispatchOp` (`Wok.Interp.Machine` ~178) captures the delimited
  continuation via `findHandler`'s `above :: Kont -> Kont` builder, binds `oaResume` to a
  `VCont`/`VContP`, and runs the arm under `kBelow`. `findHandler` (~227) walks the `Kont`
  outward to the nearest matching `KHandle`. Resume re-prepends `above` and re-installs
  `KHandle h hTag …`. `answerRebind` redirects a value-position handler's answer join to
  the resume call site.
- **Prerequisite bug confirmed live.** `Wok.IR.Anf.freeVarsExpr (Handle e _) =
  freeVarsExpr e` (Anf.hs:455) drops the handler arms' free variables. (Note:
  `Reachable.exprUniques` *does* include the handler arms, so the reachability graph is
  fine; only the capture computation is wrong — harmless today only because effects are
  walled off.)
- **One-shot is the law and is enforced.** `Wok.IR.Multiplicity.analyzeModule` is wired
  into `Pipeline.elaborateCheckedFull` (the `--run` path, `Pipeline.hs` ~174-184); a
  `Many`-card resume is a compile error (`renderMultiplicityError`). Inter-procedural
  one-shot inference is merged (`60b8fea`) and a verified one-shot break is fixed
  (`7996488`). M2b **consumes** this guarantee; it does not re-analyze.
- **Counted-children single source of truth.** `Wok.Interp.RC.Value.valueChildren`
  enumerates a value's counted children; `countedRefs = concatMap (filter (not .
  isStaticAddr) . valueChildren)`; `nodeValues` enumerates a node's values; `dropAddr`
  cascades via `countedRefs . nodeValues`. Acquire and release must be symmetric over this
  one enumeration. Any new counted value/node shape must be absorbed here, in one place.
- **Escape analysis single source of truth.** `Wok.IR.Escape.escapeWalk` (parameterised by
  an `RhsStep` policy) backs both `escapesFrom` and `captureEscapesBody`; `escapingAtomsRhs`
  is the position enumerator. Extend these; do not fork.
- **Differential oracle.** `test/Spec.hs`: `assertRcAgrees` (~8204) runs
  `Interp.runModule` vs `RCM.runModuleRCUnchecked . Perceus.insertRC` and asserts output
  equality **and** heap balance (`stLive == baseline`, `allocs - frees == baseline`), with
  `rcMemSafetyFault` (~8271) catching RC-only double-free/UAF/dangling/NEnv faults hidden
  behind a reference failure. Suite G's `prop_m2a1Escape` (~11108) is the generative
  accepted⟹sound property over `genM2a1Program` (~9320); `prop_m2a1Teeth` (mutation) and
  `prop_m2a1LintClean` round it out. The RC corpus lives in `test/rc-m2a1/`.
- **Elaborated handler shapes** (Explore-confirmed):
  - *Tail resume, no param* (`test/anf-golden/24-effects-handle.expected`):
    `IO.read(p, resume.1) -> let res.1 = resume.1(p) in res.1` — `hAnswerJoin = Nothing`;
    the arm tail-returns the resume result.
  - *Abort, no resume* (`test/run-examples/16-exn-abort.wok`):
    `Exn.throw msg k -> None` — `k` bound, never applied; arm returns a different-typed value.
  - *State, param + two-arg resume + tail* (`test/rc-perceus-golden/10-local-mutual-rec.expected`):
    `with self = { return v -> (v, s); State.get(resume.1) -> resume.1(s, s);
    State.set(x, resume.2) -> resume.2(x, ()) }` over a seeded `let s = i`. `hParam = s`;
    `resume` is two-argument (`newParam`, `result`).
  - *Non-tail / value position* (`test/anf-golden/coro-residual-handled.expected`):
    the `with` wraps a `case`; `hAnswerJoin = Just j`; the resume result is delivered to a
    join point rather than tail-returned.

## 2. The decision: A (runtime-centric), built B-ready

Two directions were considered:

- **(A) Runtime-centric hybrid.** The handler frame and the reified continuation become
  counted objects in the RC machine; the machine performs *move-out-on-resume* and
  *cascade-on-drop*. Perceus's only new static job is to place the **drop of the `resume`
  binder** over the op-arm body by ordinary last-use, guarded by Multiplicity's
  "resume is affine" guarantee. No new IR pass.
- **(B) Explicit-capture pass.** A new IR transformation reifies the delimited
  continuation as an explicit IR binder *before* Perceus, making dup/drop placement fully
  static (closer to the eventual selective-CPS compiled backend).

**Decision: A, built B-ready.** Rationale:

- The expensive, soundness-critical parts are **shared** and built once in A: the model
  (*resume = move captured frames back into the live computation; drop = cascade-release
  them; one-shot ⇒ no dup*), the invariants, the `freeVarsExpr` fix, the Multiplicity
  integration, the `State` acceptance test, and the Suite G generative oracle. None is
  thrown away on the road to B.
- The genuinely new work in B — static handler resolution (evidence passing) replacing the
  runtime `findHandler` walk, and contify-vs-reify — is **codegen-specific and unavoidable
  regardless of A**. Compiled native code cannot walk a live interpreter stack. A simply
  does not pay that cost yet, and does not add to it.
- A becomes the **oracle for B**: when codegen arrives, the explicit-capture lowering is
  validated against the RC interpreter A produces — the exact pattern already used
  (reference interpreter is the oracle for the RC interpreter).
- The backend (QBE/Fable) and the scheduler/runtime are explicitly deferred in the
  roadmap (`[[higher-ir-direction]]`, `[[effect-compilation-strategy]]`). "B now" would
  build codegen-frontend machinery ahead of the milestone that needs it.

**B-readiness is a hard design constraint, not an aspiration.** The risk of A is *split
soundness*: cleverness living in the runtime that no static analysis captures, which B
would have to reverse-engineer. To neutralize it:

> **The move-vs-cascade decision and the drop placement are computed STATICALLY by Perceus
> over the op-arm body. The runtime continuation object only EXECUTES those decisions** (a
> dumb mechanism: "this disposal is a move" vs "this disposal is a cascade"). Then B is
> "construct the continuation at compile time instead of run time, reuse the same ownership
> decisions" — not "re-derive what the machine was secretly doing."

## 3. Thesis and invariants

### 3.1 The continuation as a counted heap object

A **reified delimited continuation** is the slice of the machine state between an
operation site and its handler, *plus* the handler frame it re-installs on resume (exactly
what the reference `dispatchOp` captures: `above` + a re-installed `KHandle`). M2b
represents it as a **new counted heap node** — call it `NCont` — analogous to M2a-2's
shared `NEnv`:

- `NCont` stores the captured frame chain (host `RCKont`/`RCScope` data) and the handler
  to re-install.
- Its counted children are **NOT** "every value in the captured scopes." A runtime scope is
  a `Map` that mixes *owned*, *borrowed*, *already-moved (stale)*, and *global* bindings;
  cascading all of them double-frees the borrowed/moved/global ones (see §4.2 for the
  worked counterexample). The children that a dropped continuation must free are precisely
  its **owned set** — the values the continuation's own pending drop/move instructions would
  have consumed had it run. Computing that set exactly is the **owned-set mechanism**, the
  crux of M2b; it is specified in §4.2.
- `NCont` is a new counted **node** shape (reached via an ordinary `RVBox` handle — no new
  `RCValue` constructor). It is learned in one place, but the cascade does **not** route
  through the generic `nodeValues`/`dropAddr` path (that would free all scope values).
  Instead a dedicated `continuationOwned` query (§4.2) computes the owned set, and the abort
  path frees exactly that.

### 3.2 Resume = move-out; drop = cascade (driven by one-shot)

Because one-shot is the law, the continuation is an **affine** value (resume card ≤ 1).
The `resume` binder in the op-arm body has two mutually-exclusive fates, both statically
visible to Perceus:

- **Resume (card `One` on that path):** `resume` is applied. The application is the
  *consume*. The machine **moves** the captured frames back: re-prepend `above`, re-install
  the handler, **delete the `NCont` shell WITHOUT cascading its children** (the children's
  refcounts are unchanged — ownership transferred to the now-live frames). One-shot
  guarantees the `NCont` refcount is 1 at this point, so the move-free is sound.
- **No-resume (card `Zero` path — abort / handler-returns-without-resume):** Perceus places
  `__rc_drop resume` at the end of that path. That frees the `NCont`'s **owned set** (§4.2)
  — the values the never-run continuation would itself have dropped/moved — each once, then
  frees the shell. (NOT a blind cascade of the captured scopes.)

So the *static* decision is drop placement (`__rc_drop resume` on no-resume paths;
resume-application is the consume on resume paths). The *runtime* mechanism distinguishes
the **resume-application** (move-out: a new `enterRC` arm for an `NCont` handle) from the
**`__rc_drop`** (cascade: the existing `dropAddr`). This is the B-ready seam.

Capture introduces no count change: at `dispatchOp`, the frames the live computation held
are *moved* into the freshly-allocated `NCont` (rc = 1), so no incref of the children is
needed — they were already owned by the (now suspended) frames.

### 3.3 The handler frame and its parameter

The RC `KHandle`-analogue frame owns the handler's captured scope (the handler closure's
env) and, when present, the handler **parameter** value (`hParam`, e.g. `State`'s `s`).

- **Normal completion** of the handled expression delivers the value into the handler
  frame; the **return arm** runs (`hReturn`), which consumes the param/scope values per its
  own Perceus instrumentation (`State`'s `(v, s)` consumes `s`).
- **An op fires:** the handler frame is captured INTO the `NCont` (the reference's
  `resumeVal` closes over `h`/`hsc`). So on **abort** (drop `NCont`) the handler's param and
  scope are released by the cascade; on **resume** they flow back with the re-installed
  handler.
- **`set` (two-arg resume, M2b-2):** `resume(newParam, result)` rebinds the handler param
  to `newParam`. This is **drop-old / own-new** on the param slot: the old param value is
  dropped, the new one owned. (Binding-mutation, not cell-mutation — Invariant below.)

### 3.4 Invariants M2b must preserve (never cross into under-rejection)

Carried from M2 §2.2, with the carrier wall now load-bearing for *soundness*:

1. **No counted cycles, ever.** Every counted edge is a DAG edge. A continuation holds its
   captured frames; the frames do not point back at the continuation. Verify this holds
   once `NCont` exists.
2. **No counted edge into a region / arena / FFI cell.** Reached by static reference or
   opaque token only. `countedRefs` already filters `isStaticAddr`; `NCont`'s children
   inherit this.
3. **A continuation is never embeddable in the data it owns (the carrier wall).** No
   `NCont` handle (`RVBox`→`NCont`) in a constructor field, record field, `NEnv` capture,
   or handler-parameter slot. This is what prevents `state → cont → frame → state` cycles.
   With `NCont` now a counted value, this must be **checked at the boundary**, not assumed
   (M2b-2 carrier-wall check).
4. **Conservative analysis.** When the pass cannot prove safety, it refuses. M2b shrinks
   refusal; it never trades soundness for coverage. Conservative-reject-then-admit staging:
   ship the proven-sound fragment, keep rejecting the rest, pinned by tests.

### 3.5 Why no counted cycle forms through handlers

`State` is **binding-mutation** (rebind a handler-frame parameter to an already-complete
immutable value — `set` replaces the `s` slot's value), **not cell-mutation** (rewriting a
live field of a shared cell). Only cell-mutation forges cycles. The carrier wall
(Invariant 3) blocks the one remaining cycle shape (`state → cont → frame → state`) by
forbidding a continuation handle inside a state slot. So Bacon-Rajan trial deletion stays
genuinely **unneeded** — to be re-verified once `NCont` is a counted value.

## 4. Representation and runtime (the crux)

### 4.1 `RCKont` gains a handler frame

Mirror the reference `KHandle Handler !Int Scope Kont`:

```
data RCKont
  = KDoneRC
  | KLetRC Binder Expr RCScope RCKont
  | KAppRC [RCValue] RCKont
  | KDropCellRC Addr RCKont
  | KHandleRC Handler Int RCScope RCKont   -- NEW: effect delimiter (counted scope)
```

`returnToRC` gains the `KHandleRC` arm = run the return arm (mirror reference `returnTo`'s
`KHandle`). `evalExprRC` gains the `Handle e h` arm = install `KHandleRC` (mirror reference
`evalExpr`'s `Handle`, including the `hSelf`/`VInst` self-instance binding and `kontDepth`
tag). `evalRhsRC` gains the `ROp` arm = the RC `dispatchOp`.

### 4.2 The owned-set mechanism (the crux)

**The problem.** When a continuation is dropped without resuming (abort), we must free
**exactly** the heap values it was responsible for freeing. The captured frames' scopes are
`Map`s that mix four kinds of binding, only one of which the continuation owns:

| kind | who frees it | in the captured scope? |
|---|---|---|
| **owned** (binder's pending drop/move is inside the continuation) | the continuation | yes — free on abort |
| **borrowed** (e.g. M2a-2 reconstructed-member `BorrowCaptures` env; a call head under borrow-on-call is owned-and-dropped, so NOT this row) | its real owner elsewhere | yes — must NOT free |
| **moved-away / stale** (last use preceded the op; binder still in the `Map`) | the new holder it was moved into | yes — must NOT free |
| **global / static** | never freed | yes — must NOT free |

Worked counterexample (why "free all scope values" is unsound):

```
let x = Box 1 in      -- x owns cell A
let y = Con x in      -- x MOVED into y; now y owns A; the name x is still in the scope Map
... E.op 0            -- continuation captured here; scope has both x (stale) and y
```

Cascading the scope frees `A` twice — once via stale `x`, once via `y`'s child. **Double-free.**

**The definition.** For a captured continuation = frames `[f₁ … fₙ]` (op site outward to the
matching handler), its **owned set** is the multiset of addresses the continuation's *own*
pending instructions would consume when it runs:

- For each `KLetRC r body sc` frame: the addresses `sc[v]` for each variable `v` that is
  **free in `body`** (i.e. bound *before* the op — this excludes moved-away/stale bindings,
  whose last use preceded the op so they are not free) **and** occurs in an **owning
  position**. Owning vs borrowing is the classification **already centralized in
  `Wok.IR.Escape`** (the `escapingAtomsRhs` / borrow-predicate family — the single source of
  truth that drives the pass's own drop placement): a saturated call **head**, a `Case`
  scrutinee that keeps no boxed child, and an M2a-2 `BorrowCaptures` capture are **borrows**
  (excluded); every other occurrence (constructor/record/list field, non-head call argument,
  projection parent, op argument, alias, return/jump, or anything the pass drops at last use)
  is **owning** (included).
- Plus `KAppRC` over-args (owned, moved-in, pending application) and `KDropCellRC`'s pending
  address.
- **Deduplicated by binder identity (`Unique`)** across frames: a value live across several
  frames is owned by one binder → freed **once**; two *distinct* aliasing binders (`let a =
  x` with both live, which the pass `dup`'d) are owned separately → freed **twice**, matching
  the refcount.

This is implemented as one query, `continuationOwned :: [captured frames] -> Store ->
[Addr]`, that **reuses (and, where the borrow exclusions need it, extends) the `Wok.IR.Escape`
single source of truth** — so the runtime's notion of "owned" can never drift from the pass's
drop placement. (Equivalent characterization, the intuition: the owned set is exactly the set
of values the pass's pending `__rc_drop`/move instructions inside the captured continuation
would consume. Resume runs them; abort runs them *virtually*.)

> **B-readiness.** The explicit-capture (B) form would build the continuation object with its
> **fields = exactly this owned set**, computed by the same `Escape` classifier *at compile
> time*. The runtime-A owned set is the same set, computed at capture/abort time from the
> frames + the same classifier. Moving to B = "precompute this set into the object's fields";
> the set and the accounting (below) are unchanged. This is the concrete content of the
> "minimal slice of B" — the manifest the pass hands the runtime.

### 4.3 Capture / resume / abort accounting (no double-count)

```
data Node = … | NCont <captured-frame-prefix> <handler-reinstall-info>
```

The captured prefix is stored **concretely** (the `above` frames as an `RCKont` terminated by
a splice marker), so the **one** structure serves both the owned-set query (§4.2) and the
resume splice — they cannot diverge (the M2a-class trap is storing the owned set separately
from the frames).

- **CAPTURE** (`dispatchOp`): **move** the `above` frames into a fresh `NCont` cell (rc = 1).
  **Incref nothing** — the values stay owned by their binders inside the captured frames.
  Bind `oaResume` to `RVBox <NCont addr>`; run the op arm under `kBelow`.
- **RESUME** (Task 5; applying the `NCont` handle): **splice** the captured frames back onto
  the live `Kont`, re-install the handler, deliver the resume argument; **discard the `NCont`
  shell WITHOUT freeing the owned set** (the frames moved back; their own pending
  drops/moves fire as they run). One-shot guarantees rc = 1, so the shell free consumes the
  single owner. No incref, no cascade of children.
- **ABORT** (Task 4; Perceus `__rc_drop resume` on the `NCont`): free **`continuationOwned`**
  (§4.2), each address once; then free the shell. This *simulates* the pending instructions
  that will never run.

Either path frees the owned set **exactly once** — resume via the continuation's own
instructions, abort via the explicit owned-set free. There is no "transfer ownership into the
object and back out" dance, so there is **no double-count against the drops already baked into
the continuation body**: those instructions are the sole owners on resume, and are *simulated*
(not duplicated) on abort.

### 4.4 The RC `dispatchOp` / `findHandler`

Port the reference `dispatchOp`/`findHandler` to the RC machine, threading the store:

- `findHandler` walks `RCKont` outward to the nearest matching `KHandleRC` (same
  ambient-vs-named `instOk` logic, same `hTag`/`RVInst` routing), returning the concrete
  captured prefix, the handler + tag + `hsc`, and `kBelow`.
- Capture / resume / abort follow §4.3.

### 4.5.0 Level 1 vs level 2, and why level 1 is the better codegen foundation (decision)

Two ways to realize the owned set were weighed (decide deliberately, do not re-open by
accident):

- **Level 1 (chosen):** the runtime computes the owned set at capture/abort by evaluating the
  static `Wok.IR.Escape` classifier over each captured frame's body (which is already in the
  IR). Static *knowledge*, evaluated lazily — not runtime guesswork.
- **Level 2 (rejected for M2b):** the pass materializes each frame's owned-live set into the
  IR (a `Let`/`Expr` annotation or side-table) so the runtime only unions.

The deciding argument is the bridge to codegen. The planned compiled backend (selective CPS,
reified continuation; `[[effect-compilation-strategy]]`) obtains the continuation's
captured/owned set by **closure-converting the continuation and classifying its captured
fields with the same owning/borrow rules** — it does **not** read a pre-baked owned-set
annotation. Therefore:

- The artifacts codegen actually reuses are (1) the owning/borrow **classifier** (the
  `Escape` SSOT), (2) the **model** (resume = move ownership back; drop = free owned set;
  one-shot = affine), and (3) the **oracle** (RC interpreter + heap balance + generator).
  All three are produced identically by level 1 and level 2.
- Level 2's extra — the materialized owned set — is the one artifact codegen will **bypass**
  (it recomputes via closure conversion), so it adds no codegen-usable information while
  introducing a **second definition of "owned" that can drift from the classifier** — exactly
  the M2a-class failure (two representations of one fact diverging).

So level 1 is both more sound (one source of truth) and no worse for codegen. The highest-
value codegen investment is making the classifier the single definition that the interpreter
(A, evaluates at capture) and codegen (B, evaluates at compile time on the CPS'd continuation)
both consume. If codegen later wants a materialized owned set, it derives it from the
classifier then — no drift carried through M2b.

**Resume needs no owned set at all (either level).** Capture moves the frames in with no
incref (every value stays owned by its binder, its pending drop still in the IR inside the
frozen frame); resume splices the frames back and discards the object shell **without**
cascading children (they moved back; their own drops fire as the frames run). One-shot makes
the shell free the final reference (assert `rc == 1`). The deferred drops simply resume their
normal schedule. For codegen, resume = invoke the continuation closure; the same reified
continuation serves both resume and drop.

### 4.5 B-ready seam summary

- **Static (Perceus, over the op-arm body):** treat `resume` as an affine owned boxed local;
  place `__rc_drop resume` on every no-resume path; the resume application is the consume.
  (Done in Task 2.)
- **Static (`Wok.IR.Escape`):** the owning-vs-borrowing classifier that `continuationOwned`
  reuses — the same SSOT the pass uses for drop placement. The owned-set decision is
  therefore a *static* property the runtime merely *evaluates*; it is not runtime cleverness.
- **Runtime (RC machine):** capture = move; resume = splice + discard shell; abort = free
  `continuationOwned`. The RAII drop-hook seam (`[[m2-continuation-aware-drop-plan]]` §7.4,
  deferred) is a one-line addition at the abort free site — built as a seam, not a hook.

## 5. Sub-slice decomposition

### 5.1 M2b-1 — counted handler frame; tail-resume + abort; no param, one-arg

**Includes the prerequisite:** fix `freeVarsExpr (Handle e _)` to union the handler arms'
free vars (return body + each op body, minus their binders), so a closure/group enclosing a
handler computes its captures correctly. Verify against the reference interpreter that no
existing capture accounting regresses.

**Scope:** handlers with `hParam = Nothing`, one-argument `resume`, `hAnswerJoin = Nothing`
(tail position). Two op-arm fates:
- **Tail resume:** `op(args, resume) -> … resume(x) …` where the resume result tail-returns.
- **Abort (no resume):** `op(args, k) -> <value>` where `k` is never applied (Perceus drops
  it → `NCont` cascade).

**Acceptance (heap-balanced against the reference):**
- `Reader`/`ask` (tail resume with a constant; auto-resume elaborates `ask -> e` to
  `ask(resume) -> resume(e)`).
- A synthetic no-param tail-resume effect, e.g. `effect Tick = { tick : () }` with handler
  `{ tick k -> k () }` (tail resume, no args, no accumulator).
- `Except`/`throw` abort (`throw e k -> Err e`; `k` never applied).
- Nested handlers; an op fired from inside a `Let`/`Case` so `above` is non-trivial.

(`Writer` is **not** an M2b-1 case: `tell w k -> k (log ++ w) ()` carries an accumulator
param and a two-arg resume, so it belongs to M2b-2 alongside `State`.)

**Boundary guard:** admit this fragment; **reject** `hParam ≠ Nothing`, two-arg resume,
value-position (`hAnswerJoin = Just _`), and any continuation that is stored/escapes the
handler's dynamic extent (M3). Each rejection pinned by a test.

### 5.2 M2b-2 — param + two-arg resume + non-tail/value position; full `State`

**Scope:** `hParam` (drop-old/own-new on `set`), `VContP` two-argument resume, value-position
handlers with the `hAnswerJoin` answer-redirect (`answerRebind`), and the carrier-wall check
(reject `RVBox`→`NCont` in any con/record/`NEnv`/param slot).

**Acceptance (heap-balanced):** the `Std.Control` `state` runner — `get`/`set` with both a
tail-resume program and a non-tail (value-position) program — returning `(v, s)` with the
heap returning to baseline. Plus `Writer` with its `[w]` accumulator (param), and nested
`State`+`Reader`.

### 5.3 Deferred to M3 (stay sound-rejected, pinned)

First-class / stored / escaping continuations (the scheduler: `VCont` stored in
`schReady`/promise cells/channels) — needs the unbuilt affine-through-aliasing analysis
(`[[explicit-resume-effect-laundering]]`, Option B). M2b covers continuations
resumed-or-dropped **within** a handler's dynamic extent only.

## 6. Boundary-guard evolution

`Reachable.firstOrderNoHandlerViolations` today rejects all `Handle`/`ROp`. M2b turns it
into a **supported-handler-fragment** predicate (keep the existing LetRec deferral checks
untouched):

- M2b-1 admits: `Handle`/`ROp` where every reachable handler has `hParam = Nothing`,
  one-arg resume, tail position, and no continuation escapes the handler's dynamic extent.
- M2b-2 widens to: `hParam`, two-arg resume, value position; still rejects escaping/stored
  continuations and anything outside the proven fragment.
- The differential/stats harnesses already pre-filter on this predicate, so admitting a
  fragment automatically routes those corpus programs onto the RC store.

The Multiplicity `Many`-card rejection happens upstream (`elaborateCheckedFull`); the M2b
acceptance predicate is `null (multiplicityErrors cm) && null (handlerFragmentViolations
cm)`. The generative property quantifies only over programs satisfying both.

## 7. Testing and the oracle (non-negotiable)

The hard-won discipline (stated repeatedly in the M2a memories): RC soundness is a
non-local, silent, type-unenforced conservation law; plain reasoning produces
confident-but-wrong "it's sound" conclusions. The reliable method is **run-the-exploit**:
build the program, run `runModuleRCUnchecked . insertRC`, assert heap balance AND reference
agreement, driven by an **adversarial generative property**, not hand-picked cases.

- **Extend Suite G** with `genM2bProgram`: a generator producing handler programs across
  the dimensions — tail vs non-tail resume, abort (no resume), resume-in-a-branch, op fired
  under non-trivial `above` (inside `Let`/`Case`/nested handler), number of ops, handler
  param present/absent (M2b-2), one vs two-arg resume (M2b-2), nesting of handlers. Add a
  `prop_m2bEscape` (accepted⟹heap-balanced + reference-match), `prop_m2bTeeth` (mutation
  caught), `prop_m2bLintClean`. Add `cover`/`checkCoverage` floors so non-vacuity is
  explicit (e.g. "abort path run", "non-tail resume run", "op under non-trivial above").
- **The generator MUST stress the owned-set failure modes (§4.2), or the abort path ships
  green-broken.** These are the shapes that distinguish the correct owned set from the naive
  "free all scope values," so each must appear (with `cover` floors) in an **aborting**
  program (the path where the owned set is freed manually):
  - a value **moved** into a constructor/record before the op, then aborted (catches
    freeing the stale binder → double-free);
  - a value **live across two captured frames** (op fired in a nested call below the
    handler), then aborted (catches per-frame over-counting → double-free);
  - **two distinct aliases** of one cell both live (`let a = x` with a `dup`), then aborted
    (catches dedup-by-address → leak);
  - an **M2a-2 recursive shared-env closure** whose borrowed env is in scope at the op, then
    aborted (catches freeing a `BorrowCaptures` borrow → double-free) — this is the case a
    `freeVars`-only owned set would get wrong, forcing the `Escape` owning/borrow classifier;
  - an **over-application** (`KAppRC`) pending across the op, then aborted (catches missing
    the moved-in over-args → leak);
  - a **global/CAF reference** in the captured scope, then aborted (catches freeing a static
    addr — should be a no-op via `isStaticAddr`, but pin it).
- **`assertRcAgrees` reused as-is** for a new on-disk corpus `test/rc-m2b/`, each file a
  handler program with a filename-encoded verdict, including the exact reproducers each
  lifted guard used to reject — now passing, heap-balanced.
- **Run-the-exploit per removed guard.** Every guard that comes down ships with its
  triggering program + a `balanceLint`/heap-balance assertion.
- **Adversarial review that BUILDS the triggering program** is mandatory before merge
  (lesson: a research subagent's "verified sound" was empirically wrong; two M2a reviews
  each found a green-shipping double-free). Budget several review rounds.
- **Harden the both-fail branch** exactly as M2a did: an `NCont` double-free/UAF must not
  hide behind an unrelated reference failure (`rcMemSafetyFault` already covers
  double-free/UAF/dangling/`is not NEnv`/`internal:`; add `NCont`-specific fault strings if
  any are introduced).

## 8. Invariants to CHECK during implementation (not assume)

- **Carrier wall (Invariant 3):** add a boundary check that no `RVBox`→`NCont` lands in a
  con/record field, `NEnv` capture, or handler-param slot. Verify with an exploit attempt.
- **No counted cycle through `NCont`:** the captured frames must not transitively hold the
  `NCont` handle. Verify the frames are *moved* (not aliased) into `NCont`.
- **`freeVarsExpr` fix:** confirm against the reference interpreter that handler-enclosing
  closures' captures are now correct and that no previously-passing program regresses.
- **Owned-set correctness (§4.2) — the crux invariant.** `continuationOwned` must equal the
  set of values the captured continuation's own pending drop/move instructions would
  consume: free *fewer* → leak, free *more* (a borrow/stale/global) → double-free. It is
  computed from the **one** concrete captured-frame structure (shared with the resume splice,
  so they cannot diverge) via the `Wok.IR.Escape` SSOT classifier. Pin every owned-set
  failure mode (§7: moved, live-across-frames, aliased, M2a-2 borrow, `KAppRC`, global) with
  an *aborting* generated case AND a red-check (revert the classifier exclusion ⟹ property
  goes red). This is where the milestone is most likely to ship confident-but-wrong.
- **Capture/resume/abort balance:** capture increfs nothing; resume discards the shell
  without freeing the owned set (the spliced frames' own instructions fire); abort frees the
  owned set once. The same owned set is freed exactly once on either path — verify on the
  resume-across-alloc and abort-drops-captured corpus AND the generator.
- **`KDropCellRC` interaction:** the existing deferred-consume frame must compose with
  `KHandleRC`/`NCont` (e.g. an over-applied member returning across a handler boundary).

## 9. Risks and open questions

- The `freeVarsExpr` fix may surface previously-hidden free-var accounting in handler arms;
  the M2 doc flags this. Verify against the reference interpreter early.
- `NCont` is a new counted **node** shape AND it is the first node whose free does **not**
  route through the generic `nodeValues`/`dropAddr` cascade (it uses `continuationOwned`
  instead — §4.2). Both facts are M2a-class footguns: a new shape unaccounted-for at some
  site, and a bespoke free path. Mitigation: keep `continuationOwned` the *only* place the
  owned set is computed; share the captured-frame structure between it and the resume splice;
  and exercise `NCont` heavily in the generator (not hand-picked cases).
- The `answerRebind` (value-position resume) manipulates scopes; ensure the rebind does not
  drop/duplicate counted values. M2b-2 focus.
- Two-arg resume drop-old/own-new on the param slot is a move that the pass must account
  for; confirm with the oracle.
- Confirm the RC test harness elaboration path enforces one-shot (or that the generator
  filters multi-shot), so no multi-shot program reaches the move-out model.

## 10. Glossary (layman terms)

- **Reified continuation.** A saved copy of "the rest of the computation between an effect
  operation and its handler." M2b makes it a counted heap object that *owns* the paused
  computation's live values.
- **Move-out vs cascade.** Resuming hands the paused values back to the now-running
  computation (move, no free). Dropping a never-resumed continuation frees them (cascade).
  One-shot guarantees exactly one of these happens.
- **Handler frame.** The marker on the stack that says "effects of this kind are handled
  here." It owns the handler's parameter (e.g. the current `State` value) and scope.
- **Binding-mutation vs cell-mutation.** `State`'s `set` rebinds the parameter slot to a new
  finished value (safe, no cycle). Rewriting a field of a live shared cell (cell-mutation)
  would forge cycles — not what `State` does.
- **B-ready.** A is built so the ownership decisions are static (in Perceus); the runtime
  only executes them. The future explicit-capture pass (B) reuses those decisions instead of
  re-deriving them.
