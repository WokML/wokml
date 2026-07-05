# Rung-3 Rework: Scoped Rigid Skolemization of Trapped Effect Vars — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the rung-1/2/3 effect-laundering apparatus with scoped rigid skolemization of trapped effect-row signature variables, then reclassify tests and regenerate goldens.

**Architecture:** A polarity-aware classifier (`dischargeableRowVars`) marks a signature effect-row var "trapped" iff it has no positive (result-spine) `with eff e` channel; `freezeSigSkolems` rigidifies trapped vars, so performing one launders to `{}` and the declared rigid skolem clashes at the `finalizeGroup`/`finalizeGroupTyped` reconciliation. This deletes the ~300-line eager structural apparatus. The prototype is already in the tree behind the `rigidKEffectSkolems` switch (currently OFF).

**Tech Stack:** Haskell (GHC 9.10.3), cabal; wok type-checker (`src/Wok/TypeChecking/{Infer,Unify,Monad}.hs`); tasty/Hspec/QuickCheck golden suite (`test/Spec.hs`).

**User decisions (already made):**
- "A for me" — chose the record/judge direction, which the C1 gate then refined into scoped rigid skolemization; user then approved scoped-rigid after the harder verification ("Do it for me" / "Run it for me").
- Diagnostic reuses `UndischargedEffect` (spec D3) so death-test golden SHAPE stays stable.
- The 6 subsumed death tests get a `with eff e` channel to isolate their original bug, and their leaking forms are kept as NEW laundering death tests (spec D4).

**Spec:** `docs/superpowers/specs/2026-07-03-rung3-rework-scoped-rigid-trapped-effect-skolemization-spec.md`
**Evidence:** `docs/superpowers/2026-07-03-rung3-rework-C1-prototype-findings.md`

**Build/run reference:**
- Build: `cabal build exe:wok 2>&1 | tail` (NOTE: `cabal build wok` is AMBIGUOUS — always use `exe:wok`).
- Typecheck a file: `BIN=$(cabal list-bin exe:wok); wok_datadir=$PWD "$BIN" file.wok` — ACCEPT prints schemes; a leak prints `typecheck in Main: <Error>`.
- Full suite: `cabal test wok-tests 2>&1 | tail -5`.
- Reproducers live in `/private/tmp/claude-501/-Users-zy-wokml/8b54ffc4-f94b-4a1d-b231-3c9cadec14e2/scratchpad/repro/{A-1,FP-1,FN-1,FN-2,FN-3,FN-4,A-2,PROBE-1,PROBE-2}.wok`.

---

## File Structure

- `src/Wok/TypeChecking/Infer.hs` — the mechanism (classifier + `freezeSigSkolems` arm, already present); DELETE the apparatus (Task 1); add the diagnostic mapping (Task 2).
- `src/Wok/TypeChecking/Monad.hs` — DELETE the four `TCCtx` apparatus fields + accessors + exports; shrink the `runTC` constructor (Task 1).
- `test/typecheck-examples/` + `test/typecheck-fail-examples/` — new fixtures; reclassified fixtures (Task 3).
- `test/typecheck-fail-golden/`, `test/typed-anf-golden/` — regenerated goldens (Task 3).

---

### Task 1: Swap the laundering detector (enable scoped-rigid, delete the apparatus)

**Goal:** Make scoped rigid skolemization unconditional and delete the entire rung-1/2/3 structural apparatus, so the 9 reproducers get correct verdicts and no accept-corpus program regresses.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs` (remove switch; delete apparatus per spec §4)
- Modify: `src/Wok/TypeChecking/Monad.hs` (delete 4 TCCtx fields + accessors + exports; shrink `runTC`)

**Acceptance Criteria:**
- [ ] `dischargeableRowVars` + the trapped-only rigid arm in `freezeSigSkolems` are UNCONDITIONAL (the `rigidKEffectSkolems` constant and its two uses are gone).
- [ ] All apparatus symbols are deleted (spec §4): `emitResidualTail`, `callerRootRefs`, `reprRowRef`, the `emitRow` `TVar`/`KEffect` residual arm (reverted to `_ -> pure ()`), the `inferExprWChecked` ELam root logic + `peelLamArrows`, the `inferNormalApp` beta-redex special-case, the `typeEquationWith` root/underClosed/lambda-param installs, the `inferProgramTC` pending-residual drain; `Monad.hs` `ctxCallerResidualRoots`/`ctxUnderClosedEqn`/`ctxLambdaParams`/`ctxPendingResiduals` + accessors (`withCallerRoots`/`currentCallerResidualRoots`/`withUnderClosedEqn`/`currentUnderClosedEqn`/`withLambdaParams`/`currentLambdaParams`/`recordPendingResidual`/`takePendingResiduals`) + their export-list entries + the `runTC` constructor arguments.
- [ ] `cabal build exe:wok` succeeds; `hlint` clean on the two files.
- [ ] `grep -rnE 'callerRootRefs|emitResidualTail|ctxLambdaParams|ctxCallerResidualRoots|ctxPendingResiduals|ctxUnderClosedEqn|recordPendingResidual|takePendingResiduals|rigidKEffectSkolems' src/` returns NOTHING (AS3 dangling-ref check).
- [ ] The 9 reproducers give correct verdicts: A-1/FP-1/PROBE-2 ACCEPT; FN-1/FN-2/FN-3/FN-4/A-2/PROBE-1 REJECT.
- [ ] Every `test/typecheck-examples/*.wok` still ACCEPTs (0 regressions) and every `test/typecheck-fail-examples/*.wok` still REJECTs (verdict only — golden TEXT churn is expected and handled in Task 3).

**Verify:**
```
cabal build exe:wok 2>&1 | tail -3
BIN=$(cabal list-bin exe:wok)
D=/private/tmp/claude-501/-Users-zy-wokml/8b54ffc4-f94b-4a1d-b231-3c9cadec14e2/scratchpad/repro
for f in A-1 FP-1 PROBE-2; do wok_datadir=$PWD "$BIN" "$D/$f.wok" >/dev/null 2>&1 && echo "$f ACCEPT-ok" || echo "$f WRONG"; done
for f in FN-1 FN-2 FN-3 FN-4 A-2 PROBE-1; do wok_datadir=$PWD "$BIN" "$D/$f.wok" 2>&1 | grep -q 'typecheck in' && echo "$f REJECT-ok" || echo "$f WRONG"; done
grep -rnE 'callerRootRefs|emitResidualTail|ctxLambdaParams|rigidKEffectSkolems' src/ && echo "DANGLING" || echo "clean"
```
Expected: A-1/FP-1/PROBE-2 ACCEPT-ok; FN-1..PROBE-1 REJECT-ok; `clean`.

**Steps:**

- [ ] **Step 1: Make the classifier arm unconditional.** In `src/Wok/TypeChecking/Infer.hs` `freezeSigSkolems`, change the guard from `if rigidKEffectSkolems && not (Set.member i discharg)` to `if not (Set.member i discharg)`, and delete the `rigidKEffectSkolems :: Bool` / `rigidKEffectSkolems = False` definition (near line 358) and its C1-switch comment.

- [ ] **Step 2: Revert the `emitRow` residual arm.** In `emitRow` (the `TVar ref` case that calls `emitResidualTail`), replace the `Unbound _ _ KEffect -> emitResidualTail sp ref` line with the pre-apparatus behavior: fold the KEffect case into the catch-all so the whole `TVar ref` arm is `_ -> pure ()`. Delete the `emitResidualTail`, `callerRootRefs`, and `reprRowRef` function definitions and the `emitResidualTail _ _ | rigidKEffectSkolems = pure ()` prototype line.

- [ ] **Step 3: Remove the checking-mode + seed apparatus.** Delete: the `inferExprWChecked` ELam root logic (`peelLamArrows` call + `callerRootRefs`/`withCallerRoots` in that arm) and the `peelLamArrows` definition; the `inferNormalApp` beta-redex `lam@Abs.ELam{}` special-case (revert `inferNormalApp` to head-first `inferExprW mono f` for all heads); the `typeEquationWith` installs (`ownRoots`/`inherited`/`roots`/`declClosed`/`underClosed` computation + the `withUnderClosedEqn (withLambdaParams (withCallerRoots ...))` wrapping — run the body directly under `withEffRow effRef runBody`); the `inferProgramTC` pending-residual drain (`takePendingResiduals` + the `UndischargedEffect` throw). Use spec §4 as the checklist.

- [ ] **Step 3b: Preserve genuine `UndischargedEffect` behavior.** NOTE: the concrete-effect wall (`emitEffect` throwing `UndischargedEffect sp label` for a real named effect under a closed row) is NOT part of the apparatus — leave it untouched. Only the RESIDUAL-TAIL (bare row var) path is deleted.

- [ ] **Step 4: Delete the `Monad.hs` fields.** Remove the four `TCCtx` record fields (`ctxCallerResidualRoots`, `ctxUnderClosedEqn`, `ctxLambdaParams`, `ctxPendingResiduals`), the eight accessor definitions, their export-list entries (lines ~27-34), and the corresponding arguments in the `runTC` initial-`TCCtx` construction. Remove now-dead imports in `Infer.hs` (`recordPendingResidual`, `takePendingResiduals`, `currentCallerResidualRoots`, `withCallerRoots`, `currentUnderClosedEqn`, `withUnderClosedEqn`, `currentLambdaParams`, `withLambdaParams`).

- [ ] **Step 5: Build and chase dangling refs.**
```
cabal build exe:wok 2>&1 | tail -20
```
Fix every "not in scope" / "unused" until clean. Then:
```
grep -rnE 'callerRootRefs|emitResidualTail|reprRowRef|ctxLambdaParams|ctxCallerResidualRoots|ctxPendingResiduals|ctxUnderClosedEqn|recordPendingResidual|takePendingResiduals|peelLamArrows|rigidKEffectSkolems' src/
```
Expected: no output.

- [ ] **Step 6: hlint.**
```
hlint src/Wok/TypeChecking/Infer.hs src/Wok/TypeChecking/Monad.hs
```
Expected: "No hints" (or only pre-existing, unrelated hints — do not touch `src-generated`).

- [ ] **Step 7: Verify verdicts** (run the **Verify** block above). All 9 reproducers correct; dangling check `clean`.

- [ ] **Step 8: Verify no accept-corpus regression.**
```
BIN=$(cabal list-bin exe:wok)
for f in test/typecheck-examples/*.wok; do wok_datadir=$PWD "$BIN" "$f" 2>&1 | grep -q 'typecheck in' && echo "REGRESSION: $f"; done; echo "accept-corpus scan done"
```
Expected: only "accept-corpus scan done" (no REGRESSION lines).

- [ ] **Step 9: Commit.**
```
git add src/Wok/TypeChecking/Infer.hs src/Wok/TypeChecking/Monad.hs
git commit -m "feat(effects): scoped rigid skolemization of trapped effect vars; delete rung-1/2/3 apparatus"
```

```json:metadata
{"files": ["src/Wok/TypeChecking/Infer.hs", "src/Wok/TypeChecking/Monad.hs"], "verifyCommand": "cabal build exe:wok && grep -rnE 'callerRootRefs|emitResidualTail|rigidKEffectSkolems' src/ || echo clean", "acceptanceCriteria": ["classifier arm unconditional, switch removed", "all apparatus symbols deleted (spec §4)", "build + hlint clean", "no dangling refs", "9 reproducers correct verdicts", "0 accept-corpus regressions"], "modelTier": "frontier"}
```

---

### Task 2: Positioned laundering diagnostic (spec D3)

**Goal:** Map the trapped-skolem reconciliation failure from a raw unpositioned `RigidEscape` to a positioned `UndischargedEffect <defnSpan> "e"`, so the laundering error is user-legible and the death-test goldens stay stable in shape.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs` (`finalizeGroup` ~`:3540`, `finalizeGroupTyped` ~`:3603`)

**Acceptance Criteria:**
- [ ] A trapped-effect leak reports `UndischargedEffect (Just (line,col)) "e"` positioned at the binding's definition site, NOT `RigidEscape Nothing <uniq>`.
- [ ] A genuine KStar over-promise (e.g. `id : a -> a; id x = x + 1`) still reports its existing error (unchanged) — the remap fires ONLY for a KEffect skolem minted from a trapped var of the signature being reconciled.
- [ ] Build + hlint clean.

**Verify:**
```
cabal build exe:wok 2>&1 | tail -3
BIN=$(cabal list-bin exe:wok)
wok_datadir=$PWD "$BIN" test/typecheck-fail-examples/resume-launders-undeclared.wok 2>&1 | grep -oE 'UndischargedEffect \(Just \([0-9]+,[0-9]+\)\) "e"' && echo "positioned-ok"
```
Expected: prints an `UndischargedEffect (Just (L,C)) "e"` line then `positioned-ok`.

**Steps:**

- [ ] **Step 1: Record trapped skolem uniqs.** `freezeSigSkolems` already returns `Map Int Int` (var-index → skolem uniq) for KStar; extend it (or add a sibling return) so the caller knows WHICH minted skolem uniqs came from TRAPPED KEffect vars. Concretely: in `freezeSigSkolems`, collect the set of uniqs minted in the trapped KEffect arm and return it alongside (e.g. widen the result to `(Type s, Map Int Int, Set Int)` where the new `Set Int` is the trapped-skolem uniqs), updating both call sites.

- [ ] **Step 2: Catch + remap at reconciliation.** In `finalizeGroup` and `finalizeGroupTyped`, wrap `unify Nothing declT tv` in `catchError`. On `RigidEscape _ u` where `u` is in the trapped-skolem-uniq set, rethrow `UndischargedEffect defnSpan (Tx.pack "e")`. Any other error rethrows unchanged. Example shape (adapt to the two call sites):
```haskell
unify Nothing declT tv `catchError` \case
  RigidEscape _ u | Set.member u trappedUniqs ->
    throwError (UndischargedEffect defnSpan (Tx.pack "e"))
  e -> throwError e
```

- [ ] **Step 3: Thread the definition span.** `finalizeGroup`/`finalizeGroupTyped` receive the binding name; obtain the binding's source span (from the `TypedDecl`/equation nodes available there — Q1) and pass it as `defnSpan`. If no span is reachable without invasive threading, use the innermost equation node's span; capture the concrete choice in a code comment.

- [ ] **Step 4: Build, hlint, verify** (run the **Verify** block). Confirm `positioned-ok` and that a KStar over-promise is unaffected:
```
printf 'module Main\nimport Std.Base\nid2 : a -> a\nid2 x = x + 1\nmain : U64\nmain = 0\n' > /tmp/kstar.wok
wok_datadir=$PWD "$BIN" /tmp/kstar.wok 2>&1 | grep -qi 'RigidEscape\|Mismatch' && echo "kstar-unchanged-ok"; rm -f /tmp/kstar.wok
```
Expected: `kstar-unchanged-ok`.

- [ ] **Step 5: Commit.**
```
git add src/Wok/TypeChecking/Infer.hs
git commit -m "feat(effects): positioned UndischargedEffect diagnostic for trapped-effect laundering"
```

```json:metadata
{"files": ["src/Wok/TypeChecking/Infer.hs"], "verifyCommand": "BIN=$(cabal list-bin exe:wok); wok_datadir=$PWD $BIN test/typecheck-fail-examples/resume-launders-undeclared.wok 2>&1 | grep -oE 'UndischargedEffect \\(Just'", "acceptanceCriteria": ["trapped leak reports positioned UndischargedEffect (Just (l,c)) \"e\"", "KStar over-promise error unchanged", "build + hlint clean"], "modelTier": "standard"}
```

---

### Task 3: Reclassify tests, add fixtures, regenerate goldens (spec D4, §9)

**Goal:** Bring the whole 2135-test suite green under the new mechanism: reclassify the 6 subsumed death tests, migrate the false-negative/false-positive reproducers into the corpus, add the Q3 two-named-effect fixtures, and regenerate all affected goldens.

**Files:**
- Modify (add `with eff e`): `test/typecheck-fail-examples/{future-recursive-consume,future-await-twice,future-helper-double-consume,future-resume-then-cancel,future-reperform-unhandled,conc-producer-capture}.wok`
- Create: `test/typecheck-fail-examples/{fn-letbound-lambda,fn-siglocal-mk,fn-combinator-wrapped,fn-inner-open-local,a2-nested-sigless,probe1-closed-return}.wok` (from FN-1/FN-2/FN-3/FN-4/A-2/PROBE-1) + `test/typecheck-fail-examples/launder-two-named-leak.wok` + the 6 leaking forms of the reclassified tests as `launder-*.wok`
- Create: `test/typecheck-examples/{a1-pure-apply,fp1-open-return-arrow,probe2-sigless-outer,two-named-effects-ok}.wok` (from A-1/FP-1/PROBE-2 + Q3 accept)
- Regenerate: `test/typecheck-fail-golden/*.expected`, `test/typed-anf-golden/*.expected` (the 27 churned + new fixtures)

**Acceptance Criteria:**
- [ ] The 6 reclassified tests reject via their ORIGINAL error (`FutureConsumedTwice`/`CarrierEscape`), NOT `UndischargedEffect` (proves the one-shot/carrier analyses are still guarded).
- [ ] New fail-examples (FN-1..PROBE-1 + 6 leaking forms + two-named leak) reject with `UndischargedEffect (Just ...) "e"`.
- [ ] New examples (A-1/FP-1/PROBE-2 + two-named-effects-ok) accept.
- [ ] Q3: a program with TWO DIFFERENT named effect instances coexisting accepts; a leak variant rejects.
- [ ] Full suite green: `cabal test wok-tests` → `0 ... failed` / all suites pass.

**Verify:** `cabal test wok-tests 2>&1 | tail -5` → "X out of X tests" with 0 failures.

**Steps:**

- [ ] **Step 1: Reclassify the 6 subsumed tests.** To each, add a `with eff e` channel on the declared result so it no longer leaks, isolating its original bug. E.g. `future-await-twice.wok`: change `bad : Step U64 U64 U64 (row e) -> U64` to `bad : Step U64 U64 U64 (row e) -> U64 with eff e`. Confirm each now rejects via its original error:
```
BIN=$(cabal list-bin exe:wok)
for t in future-recursive-consume future-await-twice future-helper-double-consume future-resume-then-cancel; do
  wok_datadir=$PWD "$BIN" test/typecheck-fail-examples/$t.wok 2>&1 | grep -q 'FutureConsumedTwice' && echo "$t one-shot-ok" || echo "$t WRONG"; done
for t in future-reperform-unhandled conc-producer-capture; do
  wok_datadir=$PWD "$BIN" test/typecheck-fail-examples/$t.wok 2>&1 | grep -q 'CarrierEscape' && echo "$t carrier-ok" || echo "$t WRONG"; done
```
Expected: all `*-ok`.

- [ ] **Step 2: Add the leaking forms as NEW laundering death tests.** For each reclassified test, add a sibling `test/typecheck-fail-examples/launder-<name>.wok` that keeps the CLOSED signature (the leaking form) with the `module Main`/`import Std.Base`/`import Std.Control`/`main : U64`/`main = 0` wrapper, so the laundering path stays covered. Confirm each rejects with `UndischargedEffect`.

- [ ] **Step 3: Migrate the FN/FP reproducers into the corpus.** Copy the 6 rejecting reproducers (FN-1/FN-2/FN-3/FN-4/A-2/PROBE-1) from the scratchpad into `test/typecheck-fail-examples/` under descriptive names with an explanatory header comment each (what shape it pins). Copy the 3 accepting reproducers (A-1/FP-1/PROBE-2) into `test/typecheck-examples/`.

- [ ] **Step 4: Add the Q3 two-named-effect fixtures.** Create `test/typecheck-examples/two-named-effects-ok.wok` (two DIFFERENT named effect instances coexisting in one function, must ACCEPT — model on `test/typecheck-examples/44-named-instance.wok`) and `test/typecheck-fail-examples/launder-two-named-leak.wok` (a trapped effect performed while only a different named channel is declared, must REJECT with `UndischargedEffect`). Verify both verdicts by hand.

- [ ] **Step 5: Regenerate goldens.** The harness writes `.expected` from actual output on first run for a new fixture, and diffs thereafter. For the CHURNED goldens (the 21 `typecheck-fail-golden` + 5 `typed-anf-golden`), regenerate by deleting the stale `.expected` and re-running, OR by the repo's golden-accept mechanism. Confirm the regenerated death-test goldens carry `UndischargedEffect (Just ...) "e"` (positioned), not `RigidEscape`.
```
# inspect a regenerated golden
cat test/typecheck-fail-golden/resume-launders-undeclared.expected
```
Expected: a positioned `UndischargedEffect (Just (L,C)) "e"` line.

- [ ] **Step 6: Full suite green.**
```
cabal test wok-tests 2>&1 | tail -5
```
Expected: `0` failures.

- [ ] **Step 7: Commit.**
```
git add test/
git commit -m "test(effects): reclassify subsumed death tests, add trapped-effect fixtures, regen goldens"
```

```json:metadata
{"files": ["test/typecheck-fail-examples/", "test/typecheck-examples/", "test/typecheck-fail-golden/", "test/typed-anf-golden/"], "verifyCommand": "cabal test wok-tests 2>&1 | tail -5", "acceptanceCriteria": ["6 reclassified tests reject via original FutureConsumedTwice/CarrierEscape", "new fail-examples reject via positioned UndischargedEffect", "new accept fixtures + two-named-effects-ok accept", "full 2135-suite green"], "modelTier": "standard"}
```

---

### Task 4: Full-branch review + merge (the load-bearing gate)

**Goal:** One thorough whole-branch adversarial soundness pass + user `/code-review`, then merge per the CLAUDE.md workflow.

**Files:** none (review + merge).

**Acceptance Criteria:**
- [ ] Whole-branch Opus adversarial review with RUNNABLE reproducers + test-soundness pass (no vacuous/loophole tests; the reclassified tests genuinely guard their original checks): no unresolved correctness finding.
- [ ] `hlint` clean (ignoring `src-generated`); full suite green.
- [ ] User-run `/code-review` addressed.
- [ ] Merged to `main` per the CLAUDE.md finishing-a-development-branch flow.

**Verify:** `cabal test wok-tests 2>&1 | tail -3` green + reviewer verdict SHIP + user `/code-review` clean.

**Steps:**

- [ ] **Step 1: Whole-branch adversarial review.** Dispatch an Opus reviewer over the full branch diff hunting real failure modes with runnable reproducers (soundness: a valid program wrongly rejected; completeness: a leak accepted), and a test-soundness pass. Fix what it surfaces; persist each verdict (commit per fix).
- [ ] **Step 2: Inline lint + conventions.** `hlint` the changed files; eyeball CLAUDE.md conventions (Strict repo, no field bangs, type sigs on top-level defs).
- [ ] **Step 3: Hand off to the user for `/code-review`** and address findings.
- [ ] **Step 4: Merge** per `superpowers-extended-cc:finishing-a-development-branch`.

```json:metadata
{"files": [], "verifyCommand": "cabal test wok-tests 2>&1 | tail -3", "acceptanceCriteria": ["whole-branch adversarial review SHIP (runnable reproducers + test-soundness)", "hlint clean + suite green", "user /code-review addressed", "merged to main"], "modelTier": "frontier"}
```

---

## Self-Review

- **Spec coverage:** D1/D2 (mechanism + switch removal) → Task 1; §4 delete list → Task 1; D3 diagnostic → Task 2; D4 reclassification + §9 regression bar + Q3 → Task 3; §11 phase 5 (review+merge) → Task 4. All covered.
- **Placeholder scan:** none (Q1 span-source is a bounded implementation choice with a stated fallback; Q2 delete-if-unused is a grep-driven decision inside Task 1).
- **Type consistency:** `dischargeableRowVars`, `freezeSigSkolems`, `UndischargedEffect`, `RigidEscape` used consistently; Task 2's widened `freezeSigSkolems` return is threaded to both `finalizeGroup`/`finalizeGroupTyped`.
