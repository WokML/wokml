# M3 — Stored / Escaping Continuations on the RC Store (design)

Status: **Design direction**, brainstormed 2026-06-18. Fifth RC/Perceus slice, building on
the merged M2 line ([[m2b-2-parameterized-handlers]], [[m2b-1-continuation-frames]],
[[m2-continuation-aware-drop-plan]]). Consumes [[one-shot-as-law-multiplicity]] and the
direction doc `2026-06-11-resume-site-control-and-heap-continuations-design.md`. The
companion visual design is `docs/m3-design.html`.

This spans a static analysis, a runtime mechanism, and a thin harness; it is decomposed into
three sub-slices (§6), each its own branch and oracle checkpoint. It does **not** build the
compiled backend — but every structural decision is evaluated for codegen reuse (§5), which is
the overriding goal.

---

## 0. Summary

M3 lets a captured continuation **escape its op-arm body**: be moved into a runtime cell, parked,
and later resumed — or dropped. Today the boundary guard rejects exactly this
(`Reachable.m2bHandlerViolations`: *"effect op arm whose resume ESCAPES its body
(first-class/stored continuation; M3)"*). M3 lifts that guard for the provably-affine,
cycle-free, extern-cell route, and keeps rejecting everything else.

Four facts make this a small, sound slice rather than a runtime redesign:

1. **The cycle is prevented, not collected.** A stored continuation closes an RC cycle only if it
   holds a *counted* edge back to the cell it is parked in. Under second-class handlers (the
   queue is the scheduler handler's private baton), token indirection (promise/channel handles are
   `U64` ids), and the maintained carrier wall, that edge cannot form. **No region partition, no
   weak references, no Bacon-Rajan.** An allocator plus the runtime suffice.
2. **The at-most-once law reuses existing machinery.** "≤ 1 resume across all aliases" reduces to:
   the resume binder flows into a trusted once-sink `extern` (`__cont_store`) at most once
   (the `Multiplicity` `onceSinks` mechanism, today serving `__coro_susp`), plus the runtime
   move-discipline (`store`/`take`/resume are moves, `rc == 1`). No new heap-alias analysis.
3. **Drop runs `finally`.** A cell dropped while holding a continuation cascades to the `NCont`,
   which runs its owned-set free once (the M2b abort path) plus the placed `finally` (the M2 RAII
   drop-hook seam, activated minimally).
4. **The owned set is already the codegen frame.** `continuationOwned` returns the flat `[Addr]`
   that *is* the closure-converted continuation frame's field layout. Interpreter `NCont` is the
   oracle for the compiled register-spill stacklet.

Acceptance: a continuation stored in a cell and resumed later is heap-balanced and matches the
reference interpreter; a dropped-unresumed stored continuation runs `finally` and frees once; the
cycle exploit is **provably rejected** (run-the-exploit + red-check). One-shot stays the law;
multi-shot stays a compile error.

---

## 1. Verified ground truth (checked against `main`, 2026-06-18)

- **The allocator already exists and models a real heap.** `RC/Value.hs`: `Store { stCells ::
  IntMap Cell, stNext, stNextStatic, stDead :: IntSet, stStats }`; `type Addr = Int` (handles are
  **indices, not pointers**); `alloc` bumps `stNext` or reuses; refcounts per cell;
  `isStaticAddr a = a < 0` is the one existing region (static, immortal, uncounted —
  `incref`/`dropAddr` no-op on negatives, `countedRefs` filters them).
- **The continuation machinery exists** (M2b, merged): `Node` has `NCont RCKont (Handler,Int,
  RCScope)`; `RCKont` has `KHandleRC`; `continuationOwned :: RCKont -> [Addr]`; `moveOutCont`
  (resume move-out, asserts `rc == 1`); `spliceKont`; `cascadeChildren (NCont) =
  continuationOwned`. Resume = move frames back; abort = free the owned set once.
- **The guard M3 relaxes** is `Reachable.m2bHandlerViolations` (`Reachable.hs:358-360`), derived
  from `Escape.m2bResumeEscapes` / `Escape.m2bHandlerInFragment`: it rejects any op-arm whose
  resume binder occurs outside a saturated-call head.
- **The analysis M3 extends** is `Multiplicity` (`Card {Zero,One,Many}`, `cardOf`,
  `cardOfWithTrust`, `analyzeModule`). It already has a **trusted once-sink** mechanism:
  `onceSinks :: Set Unique`, resolved by **extern identity** (currently only `__coro_susp`), with
  the axiom "resume binder handed to a once-sink ⇒ `One`." A strong in-code warning forbids
  broadening it except by genuine prelude extern identity.
- **The extern convention** (`Std/Control.wok`): `extern __coro_susp`, `__coro_resume`,
  `__coro_cancel`, `__drive_conc` — prelude-only trust anchors. `__cont_store`/`__cont_take`
  follow this convention ([[extern-primitive-declarations]]: touching continuations is a gated
  privilege).
- **The reference oracle exists**: `Sched.driveConc` runs the existing `Conc`/`Fiber`/`Promise`/
  `Chan` scheduler on the *reference* machine, with carriers (`VCont`) held in **Haskell**
  (`schReady`/`schCells`/`schChans`), outside the wok heap. M3 does **not** port it.
- **NOT on `main`:** there is no general region machinery (`isRegionAddr`/`stRegionOf` absent —
  grep-verified). M2a-2's regions are unmerged/absent. M3 depends on neither.

---

## 2. The decisions (locked during the brainstorm)

### 2.1 Scope

M3 = the **stored-continuation primitive** (`store`/`take` an escaping continuation into a
runtime cell, resume later, or drop) + a **thin scheduler-shaped harness** to exercise and oracle
it. The live `Conc`/`Fiber`/`Promise`/`Chan` runtime stays **provider-held** (`driveConc`) as the
trusted path and reference oracle. Deferred and pinned: the full `Conc` port onto the RC store;
the self-hosting wok scheduler (Provider C, where the queue becomes a first-class wok value and
the cycle genuinely returns); the region/arena performance layer.

### 2.2 The interpreter is the runtime — and the oracle. The three-actor split.

There is no native runtime yet (codegen deferred); the RC store **is** the runtime, deliberately
shaped as a real allocator so the native one is a swap-in. Three actors, one-way dependencies:

- **Perceus pass (compile time):** *places* every `dup`/`drop`/move; computes the owned set from
  the `Escape` classifier. Runtime-agnostic. **Shared verbatim with codegen.**
- **Runtime (eval time):** captures the frame prefix into an `NCont`, splices on resume, computes
  the owned set to free on drop, resolves handlers, runs `store`/`take`. It *decides* the moves
  and *calls* the allocator. Domain-aware.
- **Allocator (eval time):** `alloc/incref/drop/deref` + free-list reuse. Domain-agnostic — it has
  never heard of a continuation.

The dependency flows down only: runtime → allocator. This is the same split codegen inherits.

### 2.3 The cycle is prevented, not collected

A continuation cell does not introduce an RC cycle, because no fiber can obtain a *counted* edge
to the cell it is parked in (the routes-blocked argument, §3.4). So M3 builds **no** cycle
collector. "Cycle provably prevented" = a boundary check rejects any program that would form the
edge (§4.3), verified by building the exploit (revert the check ⇒ the leak appears).

### 2.4 Affine on the storage operation

The at-most-once guarantee lives on the `store`/`take` operations (move-in/move-out, `rc == 1`),
not on tracking the continuation through the heap. This is distinct from effect honesty (the
load-bearing residual row, "Option B") — that pillar makes a resume driver's *signature* surface
the parked effects but counts nothing; under M3's scope the handler is dynamically present at
resume (resume-site, §3.1), so the row stays decorative and **Option B is not in M3**. M3 is the
*counting* pillar only.

---

## 3. Thesis and invariants

### 3.1 What a stored continuation is, and where it lives

A scheduler is a **parameterized handler** (M2b-2). Its parameter (baton) holds the run state —
the queue of parked continuations and any promise/channel cells. A fiber's `yield`/`await` is an
op of that effect: the handler **captures** the continuation (the M2b `NCont` — the `above`
frames between the op and the handler), **stores** it into a cell in its baton, and the op-arm
continues the scheduler loop, which later **takes** a cell and **resumes** it.

The continuation therefore **outlives the op-arm invocation** (it is stored, not tail-called) but
is **resumed within the handler's dynamic extent** (a later loop iteration, with the handler still
on the stack). This is **resume-site** semantics: the resumed tail's effects resolve to the
scheduler handler that is dynamically present — no first-class carrier, no load-bearing row
needed. The case where a continuation is resumed *after its handler returns* (a sibling scope, a
cross-scheduler hand-off) is the deferred self-hosting case.

> **CRITICAL EMPIRICAL FINDING (Task 4 probe, `8358ecc`): the baton-park-resume model above is
> NOT HM-expressible today.** Putting the cell in the baton (`hParam`) — the only state shared
> across arms, and thus the only way one arm can resume what another stored — forces the handler's
> answer type `r` to occur inside the baton's own type (`r ~ (… ContCell r …)`), an **OccursCheck**
> at elaboration (fires even at `Unit` answer type). The complementary route (cell bound as an
> enclosing local) typechecks but is rejected by the static carrier-wall check. So the **expressible
> sound fragment today is only**: a **fresh-local** cell, `store → take → resume WITHIN one
> op-arm`, plus `store → drop` (park-and-abandon). "Resume from a *later point*" (the actual
> scheduler) needs the parked-continuation type **decoupled from the handler's answer** — an
> existential/Step-typed cell (cf. the coro `Suspension`, whose continuation is typed `b → Step`,
> not `b → r`) or a provider-held token-indirected queue. This is the deferred self-hosting
> boundary, now pinned with a precise type-level cause. The §4.2 move discipline, the cycle
> prevention (§3.4/§4.3), and the within-extent primitive all hold and ship; the cross-arm
> scheduler harness (§6 M3-c) is rescoped accordingly. See §10 item 7.

### 3.2 `store` = move-in; `take` = move-out; drop = `finally` + owned-set free

- **`store cell k`** moves the continuation `k` (an `NCont`, `rc == 1`) into the cell. No `dup`:
  the binder `k` is consumed. `__cont_store` is a **trusted once-sink** extern.
- **`take cell`** moves the continuation out (cell emptied), `rc` stays 1. `__cont_take` re-binds
  it; resuming the result runs the M2b `moveOutCont`/`spliceKont` path (asserts `rc == 1`).
- **drop** of a cell still holding a continuation cascades to the `NCont`, whose drop runs
  `continuationOwned` (free the owned set once) plus the placed `finally` instructions (the M2
  RAII drop-hook seam, activated minimally — full RAII resource types stay deferred).

### 3.3 Invariants preserved (never cross into under-rejection)

1. **No counted cycle, ever** (M2 §3.4 Invariant 1). Re-verified for the cell: the captured frames
   are *moved* (not aliased) into `NCont`; the cell holds the `NCont` with a counted edge; the
   `NCont` holds no counted edge back to the cell (§3.4).
2. **The carrier wall holds, narrowed by exactly one admitted route.** No `RVBox`→`NCont` in a
   constructor / record / `NEnv` capture / handler-parameter *value* slot — **except** the
   extern-cell route (`__cont_store`). All general-data embeddings stay rejected
   (conservative-reject-then-admit).
3. **One-shot is the law.** M3 introduces no multi-shot. The affine proof (§4.2) plus the runtime
   move-discipline keep every reified continuation resumed at most once; a provable second resume
   is a compile error.
4. **Conservative analysis.** When the pass cannot prove safety, it refuses. M3 shrinks refusal
   only for the proven fragment; it never trades soundness for coverage.

### 3.4 Why no counted cycle forms

For `cell → k → cell` to be a *counted* cycle, `k` must hold a counted edge to its cell. Every
route is blocked:

| route by which `k` could reach its cell | blocked by |
|---|---|
| capture the scheduler's run-queue | second-class handlers — the queue is the handler's private baton; a fiber performs ops, it never holds the handler or baton |
| capture a promise / channel | token indirection — those are plain `U64` ids, not counted pointers to cells |
| embed the continuation in looping data | the carrier wall — no `NCont` in con/record/env/param slots |
| smuggle it as a channel payload | the payload restriction + the "continuation cannot cross the transport" backstop |
| reach the `store`/`take` cell itself | the cell is an extern-runtime primitive in the baton, not a wok value a fiber can name |

The only unblocked route — make the queue a first-class wok value fibers capture (the
self-hosting scheduler) — is deferred. So Bacon-Rajan stays genuinely unneeded; the carrier-wall
check is the whole defense.

---

## 4. Representation and runtime (the crux)

### 4.1 The continuation cell + the `store`/`take` primitives

A new minimal node holds one continuation:

```
data Node = … | NContCell (Maybe Addr)   -- an affine one-shot slot: empty | holding an NCont
```

`NContCell` is *not* general cell-mutation: it goes empty → holding → empty (filled once, emptied
once), never overwrites a live value, so it forges no cycle (the affine/one-shot flavor of the
M2 trilemma). Two prelude externs, recognized by identity:

```
extern __cont_store : ContCell r -> Cont r -> ()      -- move-in (trusted once-sink)
extern __cont_take  : ContCell r -> Cont r            -- move-out (rc==1 on resume)
```

The cell is created and held in the scheduler handler's baton (`hParam`); the harness's queue
(§6, M3-c) is a small structure of such cells. **`ContCell r` is the `extern type` carrier**
(opaque, runtime-owned, `tcCarrier`/second-class as `Suspension` is), backed at runtime by an
`NContCell` holding an `NCont` boxed as `RVBox`. **Implementation refinement (M3-a, commit
`c3440fa`):** the continuation itself is passed as a plain **function** `(b -> r with eff e)`,
mirroring `__coro_susp`'s continuation slot — NOT a separate `Cont r` type — because the op-arm
`resume` binder is function-typed in elaboration and a distinct carrier slot would need a
coercion (the §10.3 wiring). The escape restriction on `resume` therefore rests on the **boundary
guard** (`m2bResumeEscapes`, relaxed in §7/Task 4 to admit ONLY the `__cont_store` argument
position) plus the runtime carrier-wall check (§4.3) — the type system no longer independently
walls it. See §10.3 for the defense-in-depth note this raises for Task 4.

`RC/Machine.hs` gains: an `evalRhsRC` arm for `__cont_store` (move the `NCont` addr into the
`NContCell`, consume the binder, no incref) and `__cont_take` (move it out, empty the cell, rebind
for a subsequent resume via the existing `moveOutCont`/`spliceKont`). The reference
`Interp/Machine.hs` gets the mirror so the differential oracle has both sides.

### 4.2 The affine analysis (M3-a) — extend the trusted once-sink set

**Decision (resolves the §10.1 open question): the runtime move-discipline is the soundness
floor; the static `onceSinks` gate is a conservative early-rejection layer on top.** This was
chosen over a *fully-static single-`take` proof on the cell handle* on both axes the choice was
weighed on — soundness and future bug-finding — and for the same reason: a dynamic conservation
backstop catches multi-resume in shapes the static analysis (and its test generator) never
anticipated, which is precisely the green-shipping silent-failure class the M2 line was bitten by
twice. A fully-static proof concentrates all soundness in one hard, undecidable-in-general
analysis with **no** backstop, so a hole in it is a silent double-free. The move-discipline, by
contrast, fails **loud and local** (an `rc != 1` assert at the resume site + a heap-balance
violation) and reuses already-proven machinery rather than introducing a novel affine analysis.

"≤ 1 resume across all aliases" is therefore proven in two cooperating layers:

- **Runtime move-discipline (the soundness floor).** `store`/`take`/resume are moves; the `NCont`
  lives in the cell with `rc == 1`; `take` empties the slot; `moveOutCont` asserts `rc == 1`. So
  even an aliased cell handle yields the continuation at most once (a second `take` finds an empty
  slot; a slipped second resume hits `rc != 1` and errors loudly). This is a hard, local
  conservation invariant that holds regardless of how aliased the program is — the universal net.
- **Static `Multiplicity` gate (conservative early rejection).** Add `__cont_store` to `onceSinks`
  **by extern identity** (the exact mechanism that admits `__coro_susp`; respect the in-code
  warning — never by hint text). Then the resume binder handed to `__cont_store` is charged `One`,
  and the existing accounting rejects the simple violations *at compile time*: resume stored
  **and** tail-called ⇒ `addC` ⇒ `Many` ⇒ reject; stored in two cells (directly or via an alias
  `let k2 = resume`) ⇒ `addC` ⇒ `Many` ⇒ reject; stored in one branch xor another ⇒ `joinC` ⇒
  `One`. No new heap-alias analysis: storing **consumes** the binder, so any later use is a
  use-after-move the `addC` over-count already forbids.

The static layer turns the *provable* violations into compile errors (the law's earliness); the
runtime floor guarantees *no* multi-shot ever runs even for violations the static layer cannot
prove (e.g. resuming a `take`-result twice, which `oaResume`'s Card does not follow). Soundness
must **never depend** on the static layer; it may be opportunistically strengthened later (track
take-result resume sites) for clearer/earlier errors, but the floor stays the `rc == 1` move-out.

This combined check **is** codegen's contify-vs-reify decider: a continuation flowing into
`__cont_store` escapes ⇒ reify; everything else contifies. The asset is shared, not duplicated.

### 4.3 The carrier-wall check on `store`

Add a boundary check (extending the M2b-2 carrier-wall check): the `NCont` handed to
`__cont_store` must **not be counted-reachable from its own cell** — i.e. the cell may not appear
in the continuation's owned set (`continuationOwned`). Under §3.4 this holds structurally for the
baton model, but it is **checked, not assumed** (the M2 lesson). Reject if violated. This is the
operational meaning of "cycle provably prevented."

### 4.4 Drop / finally

No new drop path: a dropped `NContCell` cascades (`cascadeChildren`) to its held `NCont` addr,
whose drop already runs `continuationOwned` once (M2b abort path). M3 adds the **`finally` seam**:
the Perceus pass places the handler's `finally`/cleanup instructions so they run on the `NCont`
drop. M3 activates the seam minimally (run placed cleanup on cell-drop); first-order resource
types behind RAII stay deferred ([[m2-continuation-aware-drop-plan]] #5).

### 4.5 B-ready seam

The owned set (`continuationOwned`, a flat `[Addr]`) is the manifest codegen reads as the
register-spill frame's fields — same `Escape` classifier, at compile time. The interpreter's
linked `RCKont` prefix and codegen's flat frame are reconciled by the classifier, so the flat,
cache-friendly layout is a backend swap, not an interpreter rewrite. `store`/`take` are moves on a
unique-owned slot ⇒ in codegen a pointer store/load with no `dup` ⇒ the slot is reuse-eligible
(one-shot ⇒ Perceus reuse ⇒ zero-alloc stepping).

---

## 5. Codegen-readiness mapping (the overriding goal)

| M3 piece | interpreter (runtime today) | codegen (the reuse, no revamp) |
|---|---|---|
| allocator | `IntMap` store, bump + free-set, refcounts | native slab / size-class allocator; **same** `alloc/incref/drop/reuse` interface |
| owned set | `continuationOwned` from live frames | closure-converted frame fields, precomputed — **same** `Escape` classifier |
| continuation | `NCont` (linked prefix) | register-spill stacklet frame; fields = owned set |
| `store`/`take` | `NContCell` + move-in/out externs | heap slot holding a unique (`rc 1`) cont pointer; moves, no `dup` |
| carrier-wall check | boundary predicate at elaboration | **same** compile-time check ⇒ generated code structurally cycle-free (zero runtime cost) |
| affine `take` | `Card`/`onceSinks` on the resume binder | the **same** analysis is contify-vs-reify |
| handler dispatch | `findHandler` Kont-walk | evidence passing (the `RVInst` handles, generalized) |
| drop / `finally` | abort path on cell-drop | placed `finally` + placed frees; one-shot ⇒ slot reuse |

**Performance invariants** (state them as invariants, not just correctness): (1) the continuation
frame stays flat/unboxed (live state inline, boxed children as index fields) so codegen frames are
cache-optimal; (2) `store`/`take` are moves, never `dup` — this is what *licenses* slot reuse;
(3) dispatch is structured toward evidence, never an O(depth) walk codegen discards. These three
are simultaneously the soundness decisions and the performance-ceiling decisions.

**The §4.2 floor carries no hot-path cost.** The `rc == 1` move-out check stays **always live in
the interpreter** (the oracle's bug-catching net), but in codegen it is **elided wherever the
static `onceSinks` layer proves single-resume** — standard Perceus drop-specialization, gated on a
proof the interpreter already validated. So on every statically-provable path (the tight
generator/scheduler loops) the binary is identical to a fully-static scheme; the check survives
only on paths a static-only scheme would have to *reject*. Method A thus matches a fully-static
scheme's binary performance and additionally keeps the development-time backstop — it is not a
performance trade.

---

## 6. Sub-slice decomposition (mirror M2a/M2b; one branch + oracle each, off `main`)

- **M3-a — the affine analysis.** Add `__cont_store` to `onceSinks` by extern identity; the
  `Card` accounting admits store-once and rejects store-twice / store-and-call. Red-checkable; it
  is the contify-vs-reify decider. Test artifact: `--dump-multiplicity` goldens over stored-resume
  programs (the analysis is a frontend gate, tested directly, never via "does it run"). No runtime
  change. Oracle checkpoint: the multiplicity goldens + the reject corpus.
- **M3-b — the cell + checks + drop.** `NContCell`, `__cont_store`/`__cont_take` on both machines,
  the carrier-wall-on-store check, the `finally` seam on cell-drop, and the conditional relaxation
  of `m2bHandlerViolations` (§7). Oracle checkpoint: `test/rc-m3/` — store-then-resume
  heap-balanced and reference-matched; dropped-unresumed runs `finally` and frees once; the cycle
  exploit rejected (red-check).
- **M3-c — a thin harness.** A minimal scheduler handler whose baton is a small queue of
  `NContCell`s (e.g. a two-fiber round-robin or a one-slot park/unpark), exercised end-to-end and
  oracled against `Sched.driveConc` running the same program. Confirms the primitive composes into
  the scheduler shape without porting the `Conc` runtime.

Each slice ships its run-the-exploit reproducers and red-checks before its checkpoint; the
full-branch `/code-review` is the user's merge gate per slice ([[review-before-merge]]).

---

## 7. Boundary-guard evolution

`Reachable.m2bHandlerViolations` currently rejects any escaping resume. M3 makes the rejection
**conditional**: an escaping resume is admitted iff (a) it escapes *only* into `__cont_store`
(the extern-cell route — every other escape position stays rejected), (b) the `Multiplicity`
affine check passes (resume into store is `One`, no other occurrence), and (c) the carrier-wall
check (§4.3) passes. Concretely, `m2bResumeEscapes`/`m2bHandlerInFragment` gain an exemption for
the `__cont_store` argument position (mirroring the `__coro_susp` once-sink exemption already in
the multiplicity walker), and `m2bHandlerViolations` consults the affine + carrier-wall results.

Unchanged and still rejected: escaping resume in any non-`__cont_store` position; the
enclosing-boxed-local arm capture (M2b-1 reject `08`/`09`); the LetRec deferrals; general
`NCont`-in-data embeddings. The Perceus coverage predicate (`coveredExpr (Handle …)`) widens in
lockstep so admitted fragments route onto the RC store.

The acceptance predicate becomes `null (multiplicityErrors cm) && null (handlerFragmentViolations
cm) && null (carrierWallViolations cm)`. The generative property (§8) quantifies only over
programs satisfying all three.

---

## 8. Testing and the oracle (non-negotiable)

The hard-won discipline: RC soundness is a silent, type-unenforced conservation law; the
**stored-continuation double-resume** and the **stored-continuation cycle** are the new
silent-failure frontiers. Plain reasoning ("store-once is obviously affine") is exactly the
confident-but-wrong shape that shipped green-broken twice in M2b. The reliable method is
**run-the-exploit**: build the program, run `runModuleRCUnchecked . insertRC`, assert heap balance
AND reference agreement, driven by an adversarial generator — not hand-picked cases.

- **Extend Suite G** with `genM3Program`: handler programs that capture a continuation and then
  (dimensions, each with `cover` floors) — store-then-resume; store-then-drop (the `finally`/owned-
  set path); store in one branch xor another; alias the resume binder before store; multiple cells
  in the baton; a continuation captured under non-trivial `above` (nested `Let`/`Case`/handler);
  a stored continuation whose owned set includes a moved-into-con value, two live aliases, an
  over-application, and a global/CAF (the §4.2 owned-set failure modes, on the drop path).
- **Properties:** `prop_m3Escape` (accepted ⟹ heap-balanced + reference-match), `prop_m3Teeth`
  (mutation caught — e.g. neutering the `take` move-out to leave `rc>1`, or making cell-drop skip
  `continuationOwned`, goes red), `prop_m3LintClean`.
- **The cycle exploit (the headline).** A program where the stored continuation's owned set would
  include its own cell (forced past the structural guards). Assert the carrier-wall check
  **rejects** it; red-check: remove the check ⇒ build it ⇒ a surviving cycle / heap imbalance
  appears. This is the literal proof of "cycle provably prevented."
- **The double-resume exploit.** Programs that try to resume a stored continuation twice (store +
  tail-call; store into two cells via an alias; resume a `take` result twice). Assert each is a
  compile error (M3-a) or runtime-safe via the emptied slot (M3-b); red-check: drop `__cont_store`
  from `onceSinks` ⇒ the alias-store program must change verdict.
- **On-disk corpus `test/rc-m3/`** with filename-encoded verdicts, including every lifted guard's
  exact reproducer, now passing and heap-balanced.
- **Harden the both-fail branch** as M2 did: an `NContCell`/`NCont` double-free or UAF must not
  hide behind an unrelated reference failure (`rcMemSafetyFault` covers the classes; add cell-
  specific fault strings if introduced).
- **Adversarial review that BUILDS the triggering program is mandatory before merge** (lesson:
  M2b-1 and M2b-2 each shipped a green-broken bug a generative oracle missed; the full-branch
  run-the-exploit review caught both). Budget several rounds. Per-task reviews do not substitute
  for the user's full-branch `/code-review` merge gate.

---

## 9. Invariants to CHECK during implementation (not assume)

- **Carrier wall on `store`:** add the boundary check that the `NCont` handed to `__cont_store` is
  not in its own cell's reachable owned set; verify with the cycle exploit.
- **Move, not copy:** `__cont_store` increfs nothing; `__cont_take` moves out with no `dup`;
  verify the captured frames are *moved* into the `NCont` (M2b invariant, re-checked for the
  store path) so no counted cycle and `rc == 1` holds at resume.
- **Once-sink by identity:** `__cont_store` is trusted only by its resolved extern `Unique`, never
  by hint text (respect the `Multiplicity` warning); a user binding named `__cont_store` is not
  trusted.
- **Drop runs the owned set exactly once** on the cell-drop path, deduped by `(Unique, Addr)` (the
  M2b-2 dedup fix) — verify with a stored continuation whose owned set has two live aliases.
- **`finally` placement** runs on `NCont` drop on the cell path, not double-run on resume.

---

## 10. Risks and open questions

1. **At-most-once enforcement — RESOLVED (§4.2):** the runtime move-discipline (`rc == 1`
   move-out) is the soundness floor, with the static `onceSinks` gate as conservative early
   rejection; chosen over a fully-static single-`take` proof because the dynamic backstop fails
   loud-and-local and catches un-generated shapes, whereas a static-only proof is a silent single
   point of failure. Still a soundness-critical surface: it ships only with the double-resume
   exploit run and red-checked (neuter `moveOutCont`'s rc-check ⇒ the exploit must go from
   loud-error to silent-corruption), never on reasoning.
2. **Resume-site sufficiency.** M3 relies on the scheduler handler being dynamically present at
   resume (§3.1). Verify the harness keeps it present across a loop iteration; the resume-after-
   handler-returns case stays rejected (deferred), and the boundary guard must actually reject it
   (a stored continuation taken after the `Handle` exits).
3. **`Cont r` surface typing — RESOLVED: extern-only opaque carrier.** `Cont r` is an
   `extern type` (the existing `tcCarrier` second-class affine mechanism, as `Suspension` uses),
   admitted only through `__cont_store`/`__cont_take` — **not** a general first-class continuation
   value. Two reasons: (a) it keeps the carrier wall maximally closed (second-class typing already
   prevents escape into first-class data; the runtime check §4.3 backstops the typecheckable
   routes), and (b) — the decisive one — an opaque extern leaves the **representation entirely
   runtime-owned**, so the stacklet layout, slot reuse, and any future specialization can be
   optimized by the runtime/codegen without a user-observable semantics freezing them. The exact
   wiring of the op-arm resume binder to `Cont r` is an M3-b plan detail.

   **Refinement (M3-a, `c3440fa`):** in implementation the carrier is `ContCell r` (the
   `extern type`), and the continuation flows as a plain function `(b -> r with eff e)` (the
   `__coro_susp` precedent), NOT a distinct `Cont r` type — the function-typed `resume` binder
   would otherwise need a coercion. Consequence: the "no escape into first-class data" wall on
   `resume` is enforced ONLY by the boundary guard (`m2bResumeEscapes`, Task 4), not redundantly by
   second-class typing. **Defense-in-depth flag for Task 4:** §4.2's philosophy is "never rest
   soundness on a single static analysis." So Task 4 must (a) make the `m2bResumeEscapes`
   relaxation admit *exactly* the `__cont_store` argument position and nothing else (a hard
   compile reject for any other escape), and (b) pair it with the runtime carrier-wall check (§4.3)
   so the cycle/escape wall has the two independent layers the type-level `Cont r` would have
   given. Re-introducing `Cont r` as a typed wall remains an option if Task 4 finds the
   guard-only wall too fragile.
4. **Named-instance interaction** (direction doc §9.3): a captured instance op resumed under a
   different instance — out of M3 scope (single thin harness), pinned for the self-hosting slice.
5. **Region/arena performance layer** — deferred; it is a codegen-time perf structure, never a
   soundness mechanism, and returns only with the self-hosting scheduler.
6. **DISCOVERED pre-existing M2b leak (NOT M3's, but flagged for the user's full-branch review).**
   Task 3's adversarial review proved a leak present on the parent commit with **zero M3
   primitives**: a *resumable* (non-`Never`) op-arm that **discards** its `resume` binder (an abort
   in a resumable op) does not free the captured continuation's owned set — a silent leak
   (differential passes; only the heap-stats harness catches it). The M2b corpus never exercised it
   because it only used `Never`-typed `throw` for abort. Minimal repro: `effect Choose = { choose :
   U64 -> U64 }` with arm `choose b k -> 88` and a boxed value live across the op (leaks the shell +
   owned set). **Consequences for M3:** (a) it is out of scope to FIX here (M3 doesn't touch the raw
   op-arm abort path; M3's *cell*-drop path, Task-3 shape H, frees correctly); (b) Task 7's
   `genM3Program` must scope to the **store route** (store→resume, store→cell-drop) and NOT generate
   the raw-resumable-abort shape, else the property fails on this pre-existing bug — document the
   exclusion with a pointer here; (c) surface it to the user as a tracked repo bug.

**Task-3 decomposition note (`429ea26`):** Task 3 necessarily pulled forward the **Perceus
coverage widening** + the `Escape` store-route exemption predicates (`m2bResumeEscapesWith` /
`m2bHandlerInFragmentStore`) — without RC instrumentation the store-route bind leaks/double-frees,
so the oracle could not be heap-balanced otherwise (spec §7 "coverage widens in lockstep"). This
was kept **strictly decoupled from the boundary guard**: `m2bHandlerViolations` still uses the
non-exempting predicate, so production `runModuleRC` STILL REJECTS the store route. Therefore
**Task 4's remaining scope** is exactly: relax the *guard* (`m2bHandlerViolations`) to use the
store-route predicate, AND add `m3CarrierWallViolations` (the cycle-prevention check) + the cycle
exploit/red-check. The Escape exemption + Perceus coverage already exist and are adversarially
verified sound on the resume path.

**Functional cell (`429ea26`):** `__cont_store` returns the *filled* cell (functional/immutable
model) rather than mutating-and-returning-`()`, so the reference machine needs no mutable cell
store (it models the cell as an immutable `VCon "ContCell" [k]`); the RC machine overwrites the
`NContCell` in place via `writeNode` (rc preserved). Both agree because the returned handle is the
same identity on the RC side.

---

## 11. Glossary (layman terms)

- **Stored / escaping continuation:** the "rest of a paused fiber," saved as a value and resumed
  later, instead of resumed immediately in place.
- **Cell / baton:** the scheduler's private scratch space (the handler's parameter) where paused
  fibers wait. A fiber never holds it, which is why no loop (cycle) forms.
- **Owned set:** exactly the heap values a paused fiber is responsible for freeing — not everything
  it can see. Freed once on drop; the same list is the compiled fiber's struct fields.
- **Move-in / move-out:** handing the continuation to the cell gives it away (you can't use it
  after); taking it back is the only way to resume it, and you can only take it once.
- **Once-sink:** a trusted prelude operation that is allowed to "consume" a continuation exactly
  once; the analysis charges it as one use. `__coro_susp` is one today; `__cont_store` joins it.
- **Prevented, not collected:** we make the leak-forming program impossible to write (a compile-
  time rejection), rather than building a garbage collector to clean a leak up afterwards.
- **Contify vs reify:** if a paused fiber never really escapes, the compiler keeps it on the
  machine stack (free); only genuinely escaping ones become heap objects. The same affine check
  decides which.

---

## 12. M3 as shipped: deliverables, the expressibility boundary, and the next milestone

This section consolidates what M3 actually delivered (Tasks 1–8 on `feat/m3-stored-continuations`)
against what it deliberately did not, so the boundary is explicit for the full-branch review.

### What M3 delivers (the codegen-ready primitive — sound and reviewed)
- A captured effect continuation can be **moved into an RC heap cell** (`__cont_store`, a trusted
  once-sink), **taken back** (`__cont_take`, move-out), **resumed once** (the `moveOutCont` `rc==1`
  floor), or **dropped** (cell-drop cascades to the owned set, freed exactly once — the §4.4
  drop/`finally` seam).
- **At-most-once is enforced (§4.2 Method A):** the runtime `rc==1` move-out is the soundness
  floor; the static `onceSinks` gate rejects the provable violations early. Red-checked
  (incref/double-resume → loud fault; neuter the floor → silent double-free caught by the oracle).
- **The cycle is prevented, not collected (§3.4/§4.3):** the **static fresh-local rule**
  (`m3CarrierWallViolations`) is the **complete cycle wall** — it rejects every non-fresh-cell
  store, and every cycle needs at least one non-fresh cell, so it rejects every cycle. The other
  two checks are subordinate (not independent complete walls): the runtime `__cont_store` owned-set
  check is a **single-level operational backstop** (one-hop, subsumed by the static rule), and the
  type-level **OccursCheck** is a **generic infinite-type check** that *incidentally* blocks the
  direct surface self-store (empirically the actual blocker for surface programs). No
  region/weak-ref/Bacon-Rajan.
- **Verified by an adversarial generative oracle (§8):** `genM3Program` (800 cases) over the
  owned-set shapes (moved-into-con, two aliases, nested-above, CAF, store-resume, store-drop),
  `prop_m3Escape`/`prop_m3LintClean`/`prop_m3Teeth`, all cover floors met. The oracle itself found
  and closed a `balanceLint`/`insertRC` `__cont_take` drift (now a shared predicate).
- **Codegen-ready (§5):** the owned set is the closure-converted frame; `store`/`take` are moves
  (reuse-eligible); the cycle prevention is ownership-topology, inherited by any lowering.

### The expressibility boundary (the honest limit)
The **expressible sound fragment today** is: a **fresh-local** cell, `store → take → resume`
**within one op-arm**, and `store → drop`. The cross-arm **scheduler** pattern — store in one arm,
resume from a *later* point — is **NOT HM-expressible**: it requires the cell in the handler's
baton, which makes the answer type `r` occur in its own baton type (OccursCheck; §3.1 note). So M3
ships the *primitive*, not an in-wok scheduler over it.

### What ships the scheduler TODAY (so users are not blocked)
`Std.Control` already ships a working scheduler — `Conc`/`Async`/`Fiber`/`Promise`/`Chan` over the
`driveConc` runtime (provider-held, coroutine `Step`-typed carriers, which is *why* it avoids the
OccursCheck). Users **bring their own concurrency logic over that layer today**, and the default
scheduler ships in the standard library. M3 does not change or replace it.

### The named next milestone (the in-wok scheduler over M3's primitive)
To write a scheduler **in wok** over the raw `resume` primitive (the self-hosting, codegen-target
path), the parked-continuation type must be **decoupled from the handler's answer** — an
existential or `Step`-typed cell (mirroring how `Suspension` types its continuation `b → Step`, not
`b → r`). That is a type-system extension (wok has no existentials/higher-rank today) and is the
explicit successor milestone. Until then, M3's primitive + the coro/`Conc` scheduler cover the
ground.

### Tracked finding for the full-branch review
A **pre-existing M2b leak** (NOT introduced by M3; present with zero M3 primitives): a *resumable*
op-arm that discards its `resume` binder leaks the captured owned set (silent; only the heap-stats
harness catches it). See §10 item 6 for the minimal repro. Out of M3's scope to fix; surfaced for a
decision.
