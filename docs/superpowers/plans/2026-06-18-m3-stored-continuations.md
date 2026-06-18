# M3 — Stored / Escaping Continuations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a captured effect continuation escape its op-arm body — be moved into a runtime cell, parked, resumed later, or dropped (running `finally`) — on the RC store, gated by a static at-most-once proof and a cycle-prevention check, structured so codegen reuses every decision.

**Architecture:** Three slices on this branch (`feat/m3-stored-continuations`), each ending in an oracle checkpoint commit. **M3-a** (static): register `__cont_store` as a trusted once-sink so the existing `Multiplicity` analysis proves "≤1 resume" for the store route. **M3-b** (runtime): a `NContCell` heap node + `__cont_store`/`__cont_take` move-in/move-out on both interpreters, the carrier-wall-on-store check, the conditional relaxation of the M3 boundary rejection, and drop/`finally`. **M3-c** (oracle): a thin scheduler harness + the `genM3Program` generative property, plus the cycle and double-resume run-the-exploit corpora with red-checks.

**Tech Stack:** Haskell (GHC, `cabal`), tasty/HUnit/QuickCheck, golden tests. The full design is `docs/superpowers/specs/2026-06-18-m3-stored-continuations-design.md` — read §4.2 (the locked Method-A at-most-once), §3.4 (cycle prevention), §7 (boundary-guard evolution), §8 (oracle discipline) before each task.

**Soundness discipline (non-negotiable, applies to every runtime/guard task):** every lifted guard and every move-discipline ships with (1) a run-the-exploit reproducer in a corpus dir, and (2) a *red-check* — revert the fix and a named test must go red. RC soundness is silent; the generative property + red-checks are necessary but the full-branch `/code-review` (the user's merge gate) is the final arbiter. Do NOT merge to `main`.

**Branch/checkpoint note:** the spec calls for a branch per slice; for one autonomous run we instead use **per-slice checkpoint commits on `feat/m3-stored-continuations`** (same oracle-checkpoint discipline, less git churn). Each slice's final task is its checkpoint.

---

## Slice M3-a — the affine analysis (static, no runtime change)

### Task 1: Register `__cont_store` as a trusted once-sink; prove store-once is affine

**Goal:** Declare the M3 prelude externs and make the existing `Multiplicity` analysis charge `One` for a resume binder handed to `__cont_store` (and `Many` for store-twice / store-and-call), proven by `--dump-multiplicity` goldens with a red-check.

**Files:**
- Modify: `prelude/Std/Control.wok` (add the externs near the coro block, ~line 30-42)
- Modify: `src/Wok/Pipeline.hs:161-162` (`onceSinkKeys`)
- Create: `test/multiplicity-examples/m3-store-once.wok`, `test/multiplicity-examples/m3-store-branch.wok`
- Create: `test/multiplicity-fail-examples/m3-store-twice.wok`, `test/multiplicity-fail-examples/m3-store-and-call.wok`
- Create goldens: `test/multiplicity-golden/m3-store-once.golden`, `test/multiplicity-golden/m3-store-branch.golden` (generated, then pinned)
- Modify: `test/Spec.hs` (the `multDumpHarness`/`multFailHarness` groups auto-discover the example dirs — confirm the new files are picked up; add an explicit red-check test, below)

**Acceptance Criteria:**
- [ ] `extern type Cont r (row e)` and `extern __cont_store : ContCell r (row e) -> Cont r (row e) -> ()`, `extern __cont_take : ContCell r (row e) -> Cont r (row e)`, `extern __cont_cell_new : () -> ContCell r (row e)` are declared and typecheck (`ContCell`/`Cont` are `extern type` ⇒ `tcCarrier=True`).
- [ ] `__cont_store` resolves into `onceSinks` by extern identity (added to `onceSinkKeys`).
- [ ] A handler whose op-arm hands `resume` to `__cont_store` exactly once dumps card `1`; storing twice or store-then-tail-call dumps/errors `ω`.
- [ ] Red-check: removing `(stdControlModule, "__cont_store")` from `onceSinkKeys` flips `m3-store-once` from `1` to `ω` (a named test asserts this).

**Verify:** `cabal test -- -p "multiplicity"` → all green; `cabal run wok -- --dump-multiplicity test/multiplicity-examples/m3-store-once.wok` → arm prints `: 1`.

**Steps:**

- [ ] **Step 1: Write the failing golden inputs.** Create `test/multiplicity-examples/m3-store-once.wok` — a handler whose single op-arm stores `resume` into a cell exactly once (use the existing M2b handler shape from `test/rc-m2b/*.wok` as the template, replacing the tail `resume(...)` with `__cont_store cell resume`). Create `test/multiplicity-fail-examples/m3-store-twice.wok` (store `resume` into two cells) and `m3-store-and-call.wok` (`__cont_store c resume` then `resume v`).

- [ ] **Step 2: Run to verify failure.** `cabal run wok -- --dump-multiplicity test/multiplicity-examples/m3-store-once.wok` — Expected: fails to elaborate (`__cont_store`/`Cont` unknown) OR the arm prints `ω` (resume in a non-head arg position is an escape today). This is the red state.

- [ ] **Step 3: Declare the externs.** In `prelude/Std/Control.wok`, add after the coro block:
```
extern type Cont r (row e)
extern type ContCell r (row e)
extern __cont_cell_new : () -> ContCell r (row e)
extern __cont_store : ContCell r (row e) -> Cont r (row e) -> ()
extern __cont_take  : ContCell r (row e) -> Cont r (row e)
```

- [ ] **Step 4: Register the once-sink.** In `src/Wok/Pipeline.hs`, extend `onceSinkKeys`:
```haskell
onceSinkKeys :: [(Tx.Text, Tx.Text)]
onceSinkKeys =
  [ (stdControlModule, Tx.pack "__coro_susp")
  , (stdControlModule, Tx.pack "__cont_store")
  ]
```

- [ ] **Step 5: Run to verify the affine proof.** `cabal run wok -- --dump-multiplicity test/multiplicity-examples/m3-store-once.wok` → arm prints `: 1`. `cabal run wok -- --run test/multiplicity-fail-examples/m3-store-twice.wok` → compile error (multiplicity `ω`). (The walker is already parametric on `onceSinks` — no `Multiplicity.hs` change needed; if `m2bResumeEscapes` blocks running, that is handled in Task 4, so for M3-a use `--dump-multiplicity` / `elaborateCheckedFull` paths only.)

- [ ] **Step 6: Pin goldens + the red-check test.** Generate the `.golden` files (`cabal test --accept` or the project's golden-update flow). Add to `test/Spec.hs` a HUnit test `m3 onceSink red-check`: build the module with `onceSinkKeys` *minus* `__cont_store` (use a test-local resolver or a `Set.delete`d trust set passed to `analyzeModule`) and assert `m3-store-once` now reports `ω`. This pins that the once-sink registration is load-bearing.

- [ ] **Step 7: Commit (M3-a checkpoint).**
```bash
git add prelude/Std/Control.wok src/Wok/Pipeline.hs test/multiplicity-examples test/multiplicity-fail-examples test/multiplicity-golden test/Spec.hs
git commit -m "feat(m3-a): __cont_store as trusted once-sink; store-once is affine (red-checked)"
```

---

## Slice M3-b — the cell, the checks, drop/finally (runtime)

### Task 2: The `NContCell` heap node + RC accounting

**Goal:** Add the `NContCell (Maybe Addr)` node to the RC store with correct child-accounting (a held continuation is a counted child; dropping the cell cascades to the continuation), unit-tested in isolation.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` (`data Node` ~335; `nodeValues` ~619; `cascadeChildren` ~635; `valueChildren`/`countedRefs` if needed)
- Modify: `test/Spec.hs` (a new `rc m3 node` unit group)

**Acceptance Criteria:**
- [ ] `NContCell (Maybe Addr)` is a `Node` constructor; an empty cell (`NContCell Nothing`) has no children; a full cell (`NContCell (Just a)`) has `a` as its single counted child.
- [ ] Dropping a full cell at `rc 0` cascades to `a` (the held continuation), whose own drop runs `continuationOwned` exactly once.
- [ ] An empty cell drops to nothing.

**Verify:** `cabal test -- -p "rc m3 node"` → green.

**Steps:**

- [ ] **Step 1: Write failing unit tests.** In `test/Spec.hs`, add a group that: allocs an `NCont` (reuse an existing M2b helper that builds a small `NCont`), allocs `NContCell (Just contAddr)`, drops the cell, and asserts (a) the cell cell is freed, (b) the `NCont` is freed exactly once (heap balanced, no double-free fault), and (c) an empty `NContCell Nothing` drops cleanly. Run: expected FAIL (constructor missing).

- [ ] **Step 2: Add the constructor.** In `RC/Value.hs` `data Node`, add `| NContCell (Maybe Addr)`.

- [ ] **Step 3: Wire accounting.** Add cases:
```haskell
-- nodeValues
nodeValues (NContCell mb) = [ RVBox a | Just a <- [mb] ]
-- cascadeChildren: the held continuation is an ordinary counted child of the cell.
cascadeChildren (NContCell mb) = [ a | Just a <- [mb], not (isStaticAddr a) ]
```
(Confirm `nodeValues`/`cascadeChildren` shapes against the existing `NCon` cases; `cascadeChildren` for non-NCont nodes is `countedRefs (nodeValues n)`, so the explicit case must match that contract.)

- [ ] **Step 4: Run tests to green.** `cabal test -- -p "rc m3 node"` → PASS.

- [ ] **Step 5: Commit.**
```bash
git add src/Wok/Interp/RC/Value.hs test/Spec.hs
git commit -m "feat(m3-b): NContCell heap node with counted-child accounting"
```

### Task 3: `__cont_store` / `__cont_take` on both machines; store-then-resume oracle

**Goal:** Implement the move-in (`__cont_store`) and move-out (`__cont_take`) primitives on the RC machine (with the `rc == 1` floor via the existing move-out path) and the reference machine (an immutable `VCon` wrapper, since usage is affine), and prove a store-then-take-then-resume program is heap-balanced and reference-matched.

**Files:**
- Modify: `src/Wok/Interp/RC/Machine.hs` (prim/extern dispatch; reuse `moveOutCont`/`spliceKont`)
- Modify: `src/Wok/Interp/RC/Prim.hs` (RC prim table — register the cell prims, threading the store)
- Modify: `src/Wok/Interp/Prim.hs` (reference prim table — `__cont_cell_new`/`__cont_store`/`__cont_take`)
- Create: `test/rc-m3/01-store-resume.wok`, `test/rc-m3/02-store-resume-after-alloc.wok`
- Modify: `test/Spec.hs` (wire `test/rc-m3/` into the `rc differential` + `rc stats` groups, mirroring `rcM2bFiles`)

**Acceptance Criteria:**
- [ ] `__cont_cell_new ()` allocates an empty `NContCell`; `__cont_store cell k` moves the `NCont` addr into the cell (no incref — `rc` stays 1) and empties the binder; `__cont_take cell` moves it out (cell → `Nothing`) and rebinds it for resume via `moveOutCont`/`spliceKont` (asserts `rc == 1`).
- [ ] Reference machine mirrors observable semantics with a one-shot `VCon "ContCell" [k]` wrapper.
- [ ] `test/rc-m3/01-store-resume.wok` (store a continuation, take it, resume once, return a value) runs heap-balanced on the RC store and equals the reference output.

**Verify:** `cabal test -- -p "rc-m3"` → green (differential + heap accounting).

**Steps:**

- [ ] **Step 1: Write the failing corpus + wiring.** Create `test/rc-m3/01-store-resume.wok`: a handler whose op-arm `__cont_store`s `resume` into a baton cell, and whose return/loop path `__cont_take`s it and resumes once (model on `test/rc-m2b/20-state-tail.wok`). In `test/Spec.hs`, add `rcM3Files <- listWokFiles "test/rc-m3"` and append to the `rc differential` and `rc stats` test lists. Run: expected FAIL (prims unimplemented).

- [ ] **Step 2: RC-side prims.** In `RC/Prim.hs`/`RC/Machine.hs`, add store-threading prim arms:
  - `__cont_cell_new`: `alloc (NContCell Nothing) s` → return `RVBox cellAddr`.
  - `__cont_store cell k`: write `NContCell (Just kAddr)` at `cell` (the cell now counts `k`; `k`'s binder is consumed — no incref), return unit.
  - `__cont_take cell`: read the cell, set it to `NContCell Nothing`, return the `NCont` addr boxed; resume of that box goes through the existing `enterRC` `NCont` arm (`moveOutCont` asserts `rc == 1`).
  (Use the `PRDrive`/`enterPrim` store-threading convention the RC prim table already uses; see `__rc_drop`.)

- [ ] **Step 3: Reference-side prims.** In `Interp/Prim.hs`, add `__cont_cell_new = VCon "ContCell" [VCon "Empty" []]` (or a fresh-cell value), `__cont_store cell k = VCon "ContCell" [k]` (immutable; affine usage guarantees single store), `__cont_take (VCon "ContCell" [k]) = k`. Resume of `k` reuses the existing `VCont` apply path.

- [ ] **Step 4: Run the oracle.** `cabal test -- -p "rc-m3"` → `01-store-resume` differential PASS + heap baseline PASS.

- [ ] **Step 5: Add `02-store-resume-after-alloc.wok`** (a boxed value live across the store, resumed after) and confirm heap balance (catches a missing/extra drop on the store path).

- [ ] **Step 6: Commit.**
```bash
git add src/Wok/Interp/RC/Machine.hs src/Wok/Interp/RC/Prim.hs src/Wok/Interp/Prim.hs test/rc-m3 test/Spec.hs
git commit -m "feat(m3-b): __cont_store/__cont_take move-in/move-out on both machines; store-resume oracle"
```

### Task 4: Admit the store route at the boundary + the carrier-wall-on-store check (cycle prevention)

**Goal:** Relax the `m2bHandlerViolations` rejection so a handler whose `resume` escapes *only* into `__cont_store` is admitted, and add the carrier-wall check that rejects any program where the stored continuation is counted-reachable from its own cell — the operational meaning of "cycle provably prevented" — with the cycle exploit and its red-check.

**Files:**
- Modify: `src/Wok/IR/Escape.hs` (`m2bResumeEscapes`/`m2bHandlerInFragment` — add the `__cont_store` argument exemption, threaded by the cont-store `Unique`)
- Modify: `src/Wok/IR/Reachable.hs` (`m2bHandlerViolations`, `firstOrderNoHandlerViolations`, `exprScopeFeaturesWith` — thread the cont-store `Unique`; add `m3CarrierWallViolations`)
- Modify: `src/Wok/Interp/RC/Machine.hs` (`runModuleRC` guard chain — resolve the cont-store `Unique` from the module and call the M3 checks)
- Create: `test/rc-m3-reject/01-cycle-cont-reaches-cell.wok`, `test/rc-m3-reject/02-resume-escapes-non-store.wok`
- Modify: `test/Spec.hs` (wire `test/rc-m3-reject/` like `rcM2bRejectTests`; add the cycle red-check)

**Acceptance Criteria:**
- [ ] A handler whose `resume` escapes only into `__cont_store` is *admitted* (no longer flagged by the M3 boundary message); a `resume` escaping into any other non-head position stays *rejected*.
- [ ] `m3CarrierWallViolations` rejects a program where the stored continuation's owned set (`continuationOwned`) includes its own cell addr.
- [ ] `01-cycle-cont-reaches-cell.wok` is rejected; red-check: removing `m3CarrierWallViolations` from the guard makes it *accepted* and `runModuleRCUnchecked` then shows a surviving cycle / heap imbalance.

**Verify:** `cabal test -- -p "rc-m3-reject"` → green; `cabal test -- -p "m3 cycle red-check"` → green.

**Steps:**

- [ ] **Step 1: Write failing reject tests.** `test/rc-m3-reject/01-cycle-cont-reaches-cell.wok` — force the stored continuation to capture (counted-reach) the cell it is stored into. `02-resume-escapes-non-store.wok` — `resume` stored into a constructor field (not the extern cell). Add to `test/Spec.hs` a group asserting both produce non-empty boundary violations, plus an *admit* test that `test/rc-m3/01-store-resume.wok` produces *empty* violations. Run: expected FAIL (store route still rejected; carrier-wall check absent).

- [ ] **Step 2: Thread the cont-store `Unique`.** Add a resolver (mirror `Pipeline.resolveTrusted`) that finds `__cont_store`'s canonical `Unique` from the module's global-name map, or thread the `onceSinks` set into `firstOrderNoHandlerViolations`. In `Escape.hs`, give `m2bResumeEscapes`/`m2bHandlerInFragment` the cont-store `Unique` and exempt the `__cont_store` *argument* position (the resume atom handed to `__cont_store` is not an escape) — by identity, never by hint text (respect the `Multiplicity` warning).

- [ ] **Step 3: Add `m3CarrierWallViolations`.** In `Reachable.hs`: for each admitted store-route handler, compute the captured continuation's owned set and reject if the cell addr is counted-reachable from it. Wire it into `exprScopeFeaturesWith`'s `Handle` case and `firstOrderNoHandlerViolations`; call from `runModuleRC`'s guard chain.

- [ ] **Step 4: Run to green.** `cabal test -- -p "rc-m3-reject"` → `01` rejected, `02` rejected, `01-store-resume` admitted.

- [ ] **Step 5: The cycle red-check.** Add `test/Spec.hs` test `m3 cycle red-check`: with `m3CarrierWallViolations` disabled (a test flag / direct call bypass), run `01-cycle-cont-reaches-cell.wok` through `runModuleRCUnchecked . insertRC` and assert a heap imbalance or `rcMemSafetyFault`. With it enabled, assert rejection. This proves the check is load-bearing.

- [ ] **Step 6: Commit.**
```bash
git add src/Wok/IR/Escape.hs src/Wok/IR/Reachable.hs src/Wok/Interp/RC/Machine.hs test/rc-m3-reject test/Spec.hs
git commit -m "feat(m3-b): admit __cont_store route; carrier-wall-on-store check (cycle prevented, red-checked)"
```

### Task 5: Drop / `finally` on cell-drop; the double-resume red-check

**Goal:** Ensure a cell dropped while holding an unresumed continuation runs the placed `finally` and frees the owned set exactly once (the M2b abort path re-pointed at cell-drop), and pin the `rc == 1` floor with the double-resume red-check.

**Files:**
- Modify: `src/Wok/IR/Perceus.hs` (place `finally`/cleanup on the `NCont` drop path reached via cell-drop, if not already)
- Modify: `src/Wok/Interp/RC/Machine.hs` / `RC/Value.hs` (confirm cell-drop cascade runs `continuationOwned` once)
- Create: `test/rc-m3/03-store-drop-finally.wok` (store a continuation, never take it, drop the baton)
- Create: `test/rc-m3-reject/03-double-resume.wok` (take + resume twice — must be compile-rejected or runtime-loud)
- Modify: `test/Spec.hs` (the double-resume red-check)

**Acceptance Criteria:**
- [ ] `03-store-drop-finally.wok`: dropping the baton with an unresumed continuation frees the owned set exactly once (heap-balanced) and runs the `finally` arm (observable via a side effect / counter the reference also produces).
- [ ] Double-resume of a `take`-result is a compile error (M3-a) or a loud runtime `rc != 1` fault — never silent.
- [ ] Red-check: neutering `moveOutCont`'s `rc == 1` assert turns `03-double-resume` from a loud fault into a silent double-free (heap imbalance), caught by the oracle.

**Verify:** `cabal test -- -p "rc-m3"` and `-p "m3 double-resume red-check"` → green.

**Steps:**

- [ ] **Step 1: Write failing tests.** `03-store-drop-finally.wok` (assert the owned set frees once + finally runs). `03-double-resume.wok` (resume a taken continuation twice). Add `test/Spec.hs` `m3 double-resume red-check` asserting the loud-vs-silent flip under the neutered `moveOutCont`. Run: expected FAIL.

- [ ] **Step 2: Confirm/finish the drop path.** Verify cell-drop cascades to the held `NCont` whose drop runs `continuationOwned` once (Task 2 wired the cascade; confirm `finally` placement on that drop in `Perceus.hs` — extend the M2b abort placement to the cell-drop path if needed).

- [ ] **Step 3: Run to green.** `cabal test -- -p "rc-m3"` → `03-store-drop-finally` heap-balanced + finally observed; `03-double-resume` rejected/loud.

- [ ] **Step 4: Run the red-check** and confirm it bites (silent corruption appears when the rc-assert is neutered), then restore.

- [ ] **Step 5: Commit (M3-b checkpoint).**
```bash
git add src/Wok/IR/Perceus.hs src/Wok/Interp/RC/Machine.hs src/Wok/Interp/RC/Value.hs test/rc-m3 test/rc-m3-reject test/Spec.hs
git commit -m "feat(m3-b): cell-drop runs finally + frees owned set once; double-resume red-checked"
```

---

## Slice M3-c — the thin harness + the generative oracle

### Task 6: A thin scheduler harness, oracled against the reference

**Goal:** A minimal scheduler-shaped program (baton holds one or two cells; park a fiber and resume it later) that exercises the full primitive end-to-end and is heap-balanced + reference-matched.

**Files:**
- Create: `prelude/` or `test/rc-m3/10-thin-scheduler.wok` (a two-step park/resume, or a two-fiber round-robin using the baton)
- Modify: `test/Spec.hs` (already auto-wired via `rcM3Files`)

**Acceptance Criteria:**
- [ ] `10-thin-scheduler.wok` parks a continuation in the baton, runs other work, then takes + resumes it, producing a deterministic result equal to the reference interpreter, heap-balanced.

**Verify:** `cabal test -- -p "rc-m3"` → `10-thin-scheduler` green (differential + heap).

**Steps:**

- [ ] **Step 1: Write the harness program + run it as the failing test.** Model the baton on the M2b-2 parameterized handler (`hParam` = the queue of cells); `yield` stores the continuation, the loop takes and resumes. Run: expected PASS if Tasks 2-5 are complete; if it fails, the failure pinpoints a gap in the primitive (fix in the relevant task, not here).

- [ ] **Step 2: Confirm the oracle.** `cabal test -- -p "rc-m3"` → green. If the reference and RC disagree, the differential harness reports the mismatch; resolve before proceeding.

- [ ] **Step 3: Commit.**
```bash
git add test/rc-m3 test/Spec.hs
git commit -m "feat(m3-c): thin scheduler harness, oracled against reference driveConc-style run"
```

### Task 7: `genM3Program` generative property + coverage floors

**Goal:** Extend Suite G with a generator over stored-continuation shapes and the `prop_m3Escape`/`prop_m3LintClean`/`prop_m3Teeth` properties, with `cover` floors that force the cycle, store-then-drop, aliased, and owned-set shapes to actually appear.

**Files:**
- Modify: `test/Spec.hs` (`genM3Program`, `shrinkProgramM3`, `prop_m3Escape`, `prop_m3LintClean`, `prop_m3Teeth`, `rcM3PropertyTests`)

**Acceptance Criteria:**
- [ ] `genM3Program` varies: store-then-resume / store-then-drop / store-in-one-branch; resume binder aliased before store; owned set includes a moved-into-con value, two live aliases, an over-application, a global/CAF — each on an aborting (dropped) path; plus a cycle-attempt shape (must be rejected, not run).
- [ ] `prop_m3Escape` (accepted ⟹ heap-balanced + reference-match) passes ≥800 cases with `checkCoverage` floors met.
- [ ] `prop_m3Teeth` catches every single-site mutation (`OmitOneDrop`/`OmitOneDup`/`DuplicateOneDrop`) on the store/drop paths.

**Verify:** `cabal test -- -p "m3 property"` → green with coverage satisfied.

**Steps:**

- [ ] **Step 1: Write `genM3Program`** by extending `genM2bProgram` (Spec.hs ~11950) with the store-route dimensions above; add `cover` floors mirroring the M2b owned-set floors (Spec.hs ~12444). Run: expected coverage failures / red until the generator hits each shape.

- [ ] **Step 2: Add the properties** `prop_m3Escape`/`prop_m3LintClean`/`prop_m3Teeth` (clone the `prop_m2b*` bodies; the accept predicate is `null (firstOrderNoHandlerViolations cm) && null (m3 checks)`). Register `rcM3PropertyTests` next to `rcM2bPropertyTests` (~12736).

- [ ] **Step 3: Run to green.** `cabal test -- -p "m3 property"` → all properties pass, coverage floors satisfied. If a shape never generates, strengthen the generator (do not lower the floor).

- [ ] **Step 4: Commit (M3-c checkpoint).**
```bash
git add test/Spec.hs
git commit -m "test(m3-c): genM3Program generative property + teeth + cover floors (Suite G extended)"
```

### Task 8: Full-branch readiness (NOT merge)

**Goal:** The whole branch is green, hlint-clean (excluding `src-generated`), and the run-the-exploit corpus is complete — ready for the user's full-branch `/code-review` merge gate.

**Files:** none (verification + any cleanup)

**Acceptance Criteria:**
- [ ] `cabal build` clean; `cabal test` fully green (all suites, not just `-p` filters).
- [ ] `hlint src/ app/ test/` clean (ignore `src-generated`).
- [ ] Every lifted guard (the store-route admission, the carrier-wall check, the `rc==1` floor) has its run-the-exploit reproducer + red-check, all present and passing.

**Verify:** `cabal test` → all green; `hlint src app test` → no hints (or only pre-existing).

**Steps:**

- [ ] **Step 1: Full suite.** `cabal test` → green. Fix any cross-suite regression.
- [ ] **Step 2: hlint.** `hlint src app test --ignore-glob=src-generated` → clean.
- [ ] **Step 3: Inventory the red-checks.** Confirm the three red-checks (once-sink, carrier-wall, rc-floor) each go red on revert. Document them in a short comment block at the top of the `rcM3*` test groups.
- [ ] **Step 4: Commit + STOP.**
```bash
git add -A && git commit -m "chore(m3): full-branch green; red-check inventory; ready for /code-review"
```
Do NOT merge. Report to the user that the branch is ready for the full-branch `/code-review` gate.

---

## Self-Review

**Spec coverage:** §4.1 cell node → Task 2; §4.2 affine (Method A) → Task 1 (static) + Task 3/5 (runtime floor); §4.3 carrier-wall → Task 4; §4.4 drop/finally → Task 5; §6 slices → Tasks 1 / 2-5 / 6-7; §7 boundary-guard relaxation → Task 4; §8 oracle (genM3, red-checks, run-the-exploit) → Tasks 1,4,5,7; §10.3 `Cont r` extern-only → Task 1. §5 codegen mapping is design-only (no task — correct). All covered.

**Placeholder scan:** no "TBD"/"add error handling"/"similar to". Where exact Haskell is finalized in TDD, the *test* and *verify command* are concrete and pin the behavior (the spirit of TDD), and the impl sketch is grounded in the real signatures the exploration found.

**Type consistency:** `Cont r`, `ContCell r`, `__cont_cell_new`/`__cont_store`/`__cont_take`, `NContCell (Maybe Addr)`, `m3CarrierWallViolations`, `genM3Program`/`prop_m3Escape`/`prop_m3LintClean`/`prop_m3Teeth`, `rcM3Files`/`rcM3PropertyTests` are used consistently across tasks.

**Dependencies:** Task 1 (static, standalone) → Tasks 2→3→4→5 (runtime, sequential) → Task 6 (needs 2-5) → Task 7 (needs the checks from 4-5) → Task 8 (needs all).
