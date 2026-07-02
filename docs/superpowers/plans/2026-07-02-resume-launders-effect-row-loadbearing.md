# Resume-launders-effects (load-bearing residual row, Option B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a leftover bare residual effect-row variable obligate the enclosing function's declared effect row, closing the "resume launders effects" type hole — type-checker only.

**Architecture:** Record-then-defer. `emitRow`'s open-tail catch-all either unifies a performed bare residual into an OPEN ambient (satisfied) or, under a CLOSED ambient, records a pending obligation in TC state; a new module-level post-pass — sequenced AFTER the existing carrier/affine post-passes so multiplicity errors win — throws `UndischargedEffect` for any unsatisfied obligation. No runtime, IR, grammar, or new-error-variant change.

**Tech Stack:** Haskell (GHC), the wok type checker (`src/Wok/TypeChecking/`), tasty + tasty-golden test suite (`cabal test wok-tests`), wok prelude/test `.wok` corpus.

**User decisions (already made):**
- "reuse UndischargedEffect" — no new error variant.
- "run residual check after multiplicity checks" — multiplicity/carrier errors take precedence.
- Explicit only; `with eff _` opt-in DEFERRED (from the decision doc).
- Unbundled from first-class carriers; type-only slice (overrides the June design doc timing).

**Spec:** `docs/superpowers/specs/2026-07-02-resume-launders-effect-row-loadbearing-spec.md`

---

## File Structure

- `src/Wok/TypeChecking/Monad.hs` — add a per-module pending-residual accumulator to TC state.
- `src/Wok/TypeChecking/Infer.hs` — (a) `emitRow` catch-all records/unifies; (b) new post-pass in `inferProgramWith` after `checkFutureAffine` throws the deferred obligation.
- `test/typecheck-examples/coro-resume-driver.wok` + 3 goldens — the conscious flip.
- `test/run-examples/coro-step-{range,zip}.wok` — add `with eff e` (run-goldens must stay unchanged).
- `test/typecheck-fail-examples/resume-launders-undeclared.wok` (NEW) + golden — the death test.
- `test/typecheck-fail-golden/*.expected` — regen only where the first-fired error legitimately changes for the 5 driver-calling fail-examples.

## Test commands (shared)

- Full suite: `cabal test wok-tests 2>&1 | tail -30`
- Filtered by name: `cabal test wok-tests --test-options='-p "<pattern>"' 2>&1 | tail -30`
- Regenerate goldens (tasty-golden): append `--accept`, e.g.
  `cabal test wok-tests --test-options='--accept -p "coro-resume-driver"'`

Build once, reuse the binary across filtered runs where possible (no ASan needed — no runtime touch).

---

### Task 1: Load-bearing residual obligation (emitter + deferred verdict)

**Goal:** A function that performs a bare residual row variable under a closed declared row is rejected with `UndischargedEffect`, but only after the carrier/affine checks pass.

**Files:**
- Modify: `src/Wok/TypeChecking/Monad.hs` (add pending-residual STRef to TC state + accessor)
- Modify: `src/Wok/TypeChecking/Infer.hs:2932-2939` (`emitRow` catch-all)
- Modify: `src/Wok/TypeChecking/Infer.hs:3842-3846` (new post-pass after `checkFutureAffine`)
- Test: `test/typecheck-fail-examples/resume-launders-undeclared.wok` (added in Task 3; T1 is verified by the existing `coro-resume-driver` flip + full suite)

**Acceptance Criteria:**
- [ ] `emitRow`'s open-tail catch-all, on a forced UNBOUND `KEffect` row variable: if the current ambient forces to an OPEN tail, unifies the residual into it (no record); if the ambient is CLOSED (`RowEmpty`), records `(span, residualLabel)` into the new accumulator WITHOUT throwing and WITHOUT unifying.
- [ ] A new post-pass in `inferProgramWith`, placed AFTER the `checkFutureAffine` loop (currently `Infer.hs:3842-3844`), throws `UndischargedEffect span label` for the first pending obligation if any exist.
- [ ] `checkCarriers`/`checkFutureAffine` still run before the new post-pass (multiplicity wins).
- [ ] No new constructor added to `TCError` (reuse `UndischargedEffect`).
- [ ] The accumulator is per-module (reset/created fresh per `inferProgramWith` invocation) so obligations don't leak across modules.

**Verify:** `cabal test wok-tests 2>&1 | tail -30` → the only failures are the pre-planned golden flips handled in Tasks 2-4 (coro-resume-driver + possibly some fail-goldens); no unexpected regressions elsewhere.

**Steps:**

- [ ] **Step 1: Add the accumulator to TC state.** In `src/Wok/TypeChecking/Monad.hs`, add a field to the TC state record holding pending residual obligations, e.g. `tcPendingResidual :: STRef s [(SourceSpan, Text)]`, initialized to `[]` where the state is constructed. Add a helper `recordResidualObligation :: SourceSpan -> Text -> TC s ()` that appends, and `takePendingResidual :: TC s [(SourceSpan, Text)]` that reads it. Match the existing STRef-field style in that module (follow how other mutable TC state fields are declared and threaded).

- [ ] **Step 2: Make `emitRow`'s catch-all load-bearing.** In `src/Wok/TypeChecking/Infer.hs` at `emitRow` (2932-2939), replace the `_ -> pure ()` arm so it inspects the forced row:
  - If it forces to an unbound `TVar` of `Kind KEffect` (a bare residual tail): read the current ambient (the same ambient `emitEffect` reads at ~2903). Force it. If the ambient forces to an open tail (unbound `KEffect` `TVar`), `unify` the residual tail into the ambient tail. Otherwise (ambient is `RowEmpty`/closed), call `recordResidualObligation sp <label>` where `<label>` is a residual descriptor (the row-var's printed name, or a fixed descriptor if unnamed — keep it consistent with how `UndischargedEffect`'s `Text` reads for concrete labels).
  - Keep `RowEmpty` → `pure ()` (a closed empty residual performs nothing).
  - Do NOT throw here.
  Guard precisely on "unbound `KEffect` var" so a residual already resolved to concrete handled labels never records.

- [ ] **Step 3: Add the deferred verdict post-pass.** In `inferProgramWith`, immediately AFTER the `forM_ tds $ \td -> ... checkFutureAffine ...` block (ends `Infer.hs:3844`) and BEFORE `let finalEnv = ...` (3845), read the accumulator and throw the first obligation:

```haskell
    pending <- takePendingResidual
    case pending of
      ((sp, lbl) : _) -> throwError (UndischargedEffect sp lbl)
      []              -> pure ()
```

  This guarantees carrier/affine errors (thrown in the loops above) win.

- [ ] **Step 4: Build.** Run: `cabal build wok 2>&1 | tail -20`. Expected: compiles clean (fix any type errors from the state-field threading).

- [ ] **Step 5: Run the suite to confirm the intended flips and no collateral.** Run: `cabal test wok-tests 2>&1 | tail -40`. Expected: `coro-resume-driver` typecheck/anf/typed-anf goldens now FAIL (scheme carries the residual) — that is the conscious flip fixed in Task 2. `coro-step-range`/`coro-step-zip` FAIL typechecking until Task 2 adds `with eff e`. No OTHER success-golden or run-golden regresses. If anything else breaks, STOP and diagnose (likely a false-positive recording — tighten the Step-2 guard).

- [ ] **Step 6: Commit.**

```bash
git add src/Wok/TypeChecking/Monad.hs src/Wok/TypeChecking/Infer.hs
git commit -m "feat(effects): make residual effect row load-bearing (Option B, deferred verdict)"
```

---

### Task 2: Migrate the flipping consumers + regen the marker golden

**Goal:** The 3 programs that legitimately perform a residual declare `with eff e`; the conscious `coro-resume-driver` golden flips; the two run-goldens stay byte-identical.

**Files:**
- Modify: `test/typecheck-examples/coro-resume-driver.wok:20` (`replay` sig)
- Modify: `test/run-examples/coro-step-range.wok` (`sumGen` sig)
- Modify: `test/run-examples/coro-step-zip.wok` (`zipSum` sig)
- Regen: `test/typecheck-golden/coro-resume-driver.expected`, `test/anf-golden/coro-resume-driver.expected`, `test/typed-anf-golden/coro-resume-driver.expected`
- Assert unchanged: `test/run-golden/coro-step-range.expected`, `test/run-golden/coro-step-zip.expected`

**Acceptance Criteria:**
- [ ] `replay : Suspension U64 U64 U64 (row e) -> U64 with eff e`
- [ ] `sumGen : Step U64 () () (row e) -> U64 with eff e`
- [ ] `zipSum : Step U64 () () (row e) -> Step U64 () () (row e) -> U64 with eff e`
- [ ] The 3 `coro-resume-driver` goldens regen to schemes carrying the residual.
- [ ] `coro-step-range`/`coro-step-zip` RUN and their run-goldens are unchanged (compile-time-only proof).

**Verify:** `cabal test wok-tests --test-options='-p "coro-step-range" -p "coro-step-zip" -p "coro-resume-driver"' 2>&1 | tail -30` → PASS

**Steps:**

- [ ] **Step 1: Add `with eff e` to the three signatures.** Edit each file's helper signature to append `with eff e`:
  - `coro-resume-driver.wok:20`: `replay : Suspension U64 U64 U64 (row e) -> U64 with eff e`
  - `coro-step-range.wok` (`sumGen`): `sumGen : Step U64 () () (row e) -> U64 with eff e`
  - `coro-step-zip.wok` (`zipSum`): `zipSum : Step U64 () () (row e) -> Step U64 () () (row e) -> U64 with eff e`

- [ ] **Step 2: Confirm the run-goldens are UNCHANGED first (the key proof).** Run: `cabal test wok-tests --test-options='-p "coro-step-range" -p "coro-step-zip"' 2>&1 | tail -20`. Expected: PASS with NO golden diff. If a run-golden differs, STOP — the change is not compile-time-only; investigate before proceeding.

- [ ] **Step 3: Regen the coro-resume-driver goldens.** Run: `cabal test wok-tests --test-options='--accept -p "coro-resume-driver"' 2>&1 | tail -20`. Then inspect the diff: the typecheck golden's `replay` scheme must now show `with eff e` (or the equivalent residual in the printed scheme), not `forall a. … -> U64`.

- [ ] **Step 4: Re-run the trio clean.** Run the Verify command. Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add test/typecheck-examples/coro-resume-driver.wok test/run-examples/coro-step-range.wok test/run-examples/coro-step-zip.wok test/typecheck-golden/coro-resume-driver.expected test/anf-golden/coro-resume-driver.expected test/typed-anf-golden/coro-resume-driver.expected
git commit -m "test(effects): declare with eff e on residual-consuming drivers; flip coro-resume-driver golden"
```

---

### Task 3: Death test — undeclared residual is rejected

**Goal:** A resume driver that omits `with eff e` while performing a residual is rejected with `UndischargedEffect`, with no other error masking it.

**Files:**
- Create: `test/typecheck-fail-examples/resume-launders-undeclared.wok`
- Create: `test/typecheck-fail-golden/resume-launders-undeclared.expected`

**Acceptance Criteria:**
- [ ] The `.wok` performs a residual via `run` but declares no `with eff e`, and has NO multiplicity/carrier violation (single consumption).
- [ ] Type-checking it fails with `UndischargedEffect`.
- [ ] The golden matches the rendered error.

**Verify:** `cabal test wok-tests --test-options='-p "resume-launders-undeclared"' 2>&1 | tail -20` → PASS

**Steps:**

- [ ] **Step 1: Write the death test.**

```
module Main
import Std.Base
import Std.Control
-- Load-bearing residual (Option B): `drive` performs the parked tail's effects
-- via `run` but declares none. Post-slice this is rejected with UndischargedEffect.
-- Single consumption -> no FutureConsumedTwice/CarrierEscape to mask it.
drive : Suspension U64 U64 U64 (row e) -> U64
drive g = run g 0
main : U64
main = 0
```

- [ ] **Step 2: Generate the golden.** Run: `cabal test wok-tests --test-options='--accept -p "resume-launders-undeclared"' 2>&1 | tail -10`. Inspect: the golden must name `UndischargedEffect` (not `CarrierEscape`/`FutureConsumedTwice`). If it names a carrier error, the `.wok` accidentally double-consumes — simplify until the residual check is what fires.

- [ ] **Step 3: Verify.** Run the Verify command. Expected: PASS.

- [ ] **Step 4: Commit.**

```bash
git add test/typecheck-fail-examples/resume-launders-undeclared.wok test/typecheck-fail-golden/resume-launders-undeclared.expected
git commit -m "test(effects): death test for undeclared resume residual (UndischargedEffect)"
```

---

### Task 4: Error-ordering triage on the driver-calling fail-examples

**Goal:** Confirm the 5 driver-calling fail-examples keep their original first-fired error (multiplicity wins), regen only legitimately-changed goldens, and confirm the 2 non-driver fail-examples are byte-identical.

**Files:**
- Assert/regen: `test/typecheck-fail-golden/{future-recursive-consume,future-resume-then-cancel,future-await-twice,future-helper-double-consume,conc-producer-capture}.expected`
- Assert UNCHANGED: `test/typecheck-fail-golden/{future-reperform-unhandled,producer-thunk-userfile}.expected`

**Acceptance Criteria:**
- [ ] Each of the 5 driver-calling fail-examples still fails; its first-fired error is still the carrier/affine one (per the deferred-verdict design), so its golden is UNCHANGED. If any golden legitimately changed, the change is reviewed and justified in the commit message.
- [ ] `future-reperform-unhandled` and `producer-thunk-userfile` goldens are byte-identical (no change) — any diff is a red flag, not an accepted regen.

**Verify:** `cabal test wok-tests --test-options='-p "future-" -p "producer-thunk-userfile" -p "conc-producer-capture"' 2>&1 | tail -30` → PASS

**Steps:**

- [ ] **Step 1: Run the fail-golden group and read diffs (do NOT accept yet).** Run: `cabal test wok-tests --test-options='-p "future-" -p "producer-thunk-userfile" -p "conc-producer-capture"' 2>&1 | tail -40`. Expected per the design: all PASS unchanged (deferred verdict means the pre-existing carrier/affine error still fires first).

- [ ] **Step 2: If any of the 5 driver-callers changed,** inspect whether the new first error is `UndischargedEffect`. If so, that means the carrier/affine check did NOT fire for that program (it was not actually a double-consume) — decide case-by-case: either the golden legitimately becomes `UndischargedEffect` (accept + justify) or the ordering guarantee is violated (STOP, fix Task 1's post-pass placement). Regen only justified cases: `cabal test wok-tests --test-options='--accept -p "<name>"'`.

- [ ] **Step 3: Assert the 2 non-driver files are untouched.** Confirm `git status` shows NO change to `future-reperform-unhandled.expected` or `producer-thunk-userfile.expected`. If either changed, STOP — this violates the spec (§7); the recording guard is over-firing.

- [ ] **Step 4: Full suite green.** Run: `cabal test wok-tests 2>&1 | tail -30`. Expected: all green.

- [ ] **Step 5: Commit (only if goldens changed; otherwise this task is assertion-only).**

```bash
git add test/typecheck-fail-golden/
git commit -m "test(effects): error-ordering triage for residual vs multiplicity (multiplicity wins)"
```

---

## Self-Review

- **Spec coverage:** §4 design → Task 1. §7 migration (3 flips) → Task 2. §8 death test → Task 3. §5/§7 fail-example ordering → Task 4. §6 compile-time proof → Task 2 Step 2 (run-goldens unchanged). §9 error identity (reuse `UndischargedEffect`) → Task 1 AC. All covered.
- **Placeholder scan:** T1 is frontier (design judgment on state threading + the `closeRow` caveat) — steps give concrete direction and the post-pass code; the emitter arm is described precisely against cited line numbers rather than as a full literal patch, which is appropriate for a frontier task. T2/T3/T4 have exact edits and commands.
- **Type consistency:** `recordResidualObligation`/`takePendingResidual`/`tcPendingResidual` used consistently across Task 1 steps; `UndischargedEffect SourceSpan Text` matches `Error.hs`.
