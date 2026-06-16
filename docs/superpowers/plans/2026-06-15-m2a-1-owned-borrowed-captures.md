# M2a-1 — Owned-vs-Borrowed Closure Captures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Perceus pass and RC store sound for the *non-escaping* parts of deferred cases #1 (a LetRec member consuming an enclosing capture) and #4 (a standalone `RLam` capturing a LetRec sibling) by giving the closure representation an owned-vs-borrowed capture distinction, plus dup-per-consuming-use.

**Architecture:** A closure node today captures all free vars uniformly, and the RC store cascade-drops every boxed capture on closure drop. That double-frees region siblings (the group drop frees them too). M2a-1 splits a closure's captures into **owned** (cascade-freed on closure drop) and **borrowed** (region siblings, never cascaded — the group owns them), threaded from the pass (which already knows siblings via `ctxExempt`) into the runtime node (which today only has the global `isRegionAddr` property). A member that *moves* an enclosing capture gets a `__rc_dup` per consuming use at the build site. The four reject-guards remain for the *escaping* sub-cases; an escape detector narrows #1/#4 so only escapes are refused.

**Tech Stack:** Haskell, Tasty (HUnit + tasty-golden), `cabal test wok-tests`. Key modules: `Wok.Interp.RC.Value`, `Wok.Interp.RC.Machine`, `Wok.IR.Perceus`, `Wok.IR.Reachable`. Validation methodology is the existing RC oracle: Suite A (Perceus golden), Suite B (heap-accounting + stats golden), Suite C (fault-injection teeth), Suite D (differential vs reference interpreter), plus `balanceLint`.

**Scope note:** This plan covers slice M2a-1 only. M2a-2 (region-lifetime promotion) and M2b (continuations) get their own plans after their predecessor merges, per spec §3 and `[[review-before-merge]]`. Spec: `docs/superpowers/specs/2026-06-15-m2-continuation-aware-drop-design.md`.

**Methodology note for the implementer:** This is a subtle reference-counting analysis change. The project's correctness oracle is `balanceLint` (path-aware ownership audit) + Suite D (differential execution against the GC-backed reference interpreter) + Suite C (the oracle must catch injected `OmitOneDrop`/`OmitOneDup`/`DuplicateOneDrop` mutations). Every task is TDD against that oracle: add the reproducer to the corpus, watch it fail (leak/double-free/lint violation), implement, watch it pass, confirm the teeth still bite. Do not hand-fabricate dup/drop placement and assume it is right — let `balanceLint` and the differential oracle drive it.

---

### Task 1: Add the two reproducer corpus programs and confirm the guards reject them

**Goal:** Land the exact #1 and #4 reproducers as corpus files and assert the current behavior (rejected at the RC boundary), so the guard-narrowing in later tasks has a red-to-green target.

**Files:**
- Create: `test/rc-examples/NN-consuming-capture-nonescape.wok` (case #1, non-escaping)
- Create: `test/rc-examples/NN-rlam-sibling-nonescape.wok` (case #4, non-escaping)
- Test: `test/Spec.hs` (add two `testCase`s near the existing RC boundary-guard tests)

**Acceptance Criteria:**
- [ ] Both `.wok` programs load and elaborate (they are valid wok).
- [ ] `firstOrderNoHandlerViolations` currently returns a non-empty list for both (the guard has teeth).
- [ ] A test asserts the current rejection messages, pinning the baseline.

**Verify:** `cabal test wok-tests --test-show-details=direct -k "m2a-1 baseline"` -> PASS (asserting current rejection).

**Steps:**

- [ ] **Step 1: Write the #1 reproducer** (`test/rc-examples/NN-consuming-capture-nonescape.wok`). The member moves the capture `b` via `peek b`, and the group does NOT escape (result is an `Int`):

```
module Main
import Std.Base

peek p = 0

main =
  let b = Box 6
  in letrec go k = case k of
       0 -> peek b
       _ -> 1 + go (k - 1)
  in go 3
```

- [ ] **Step 2: Write the #4 reproducer** (`test/rc-examples/NN-rlam-sibling-nonescape.wok`). A standalone `RLam` `h` captures sibling `f`; `h` is dropped without being called; result is an `Int` (no escape):

```
module Main
import Std.Base

mk u =
  let f n = case n of
        0 -> u
        _ -> f (n - 1)
  in let h = \m -> f (m + 1)
  in 0

main = mk 7
```

- [ ] **Step 3: Add a baseline test to `test/Spec.hs`** asserting both are currently rejected. Mirror the existing boundary-guard test style (it calls `firstOrderNoHandlerViolations` on the elaborated module):

```haskell
test_m2a1Baseline :: TestTree
test_m2a1Baseline = testGroup "m2a-1 baseline (guards reject pre-implementation)"
  [ testCase "consuming-capture non-escape is rejected" $ do
      vs <- boundaryViolationsOf "test/rc-examples/NN-consuming-capture-nonescape.wok"
      assertBool "expected a rejection" (not (null vs))
  , testCase "rlam-sibling non-escape is rejected" $ do
      vs <- boundaryViolationsOf "test/rc-examples/NN-rlam-sibling-nonescape.wok"
      assertBool "expected a rejection" (not (null vs))
  ]
```

(Add a small `boundaryViolationsOf :: FilePath -> IO [Text]` helper next to the existing boundary tests that runs `Loader.loadProgram` -> `Pipeline.elaborateProgramFull` -> `Reachable.firstOrderNoHandlerViolations`. If an equivalent helper already exists, reuse it.)

- [ ] **Step 4: Run and verify it passes** (the guards still reject, so the baseline assertions hold):

Run: `cabal test wok-tests --test-show-details=direct -k "m2a-1 baseline"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test/rc-examples/NN-consuming-capture-nonescape.wok \
        test/rc-examples/NN-rlam-sibling-nonescape.wok test/Spec.hs
git commit -m "test(rc): M2a-1 reproducer corpus + current-rejection baseline"
```

---

### Task 2: Owned/borrowed capture representation in the RC store

**Goal:** Teach the closure node and the drop cascade that a closure can hold *borrowed* (region-sibling) captures that it must NOT cascade-free, decided per-closure rather than via the global `isRegionAddr`.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` (`NClosure` at `:112`; `countedChildren` at `:366-372`)
- Modify: `src/Wok/Interp/RC/Machine.hs` (`enterRC` consume/incref at `:194-250`; `NClosure` construction in `LetRec` at `:94-126` and in the partial-application `LT` branch)
- Test: `test/Spec.hs` (a direct-store unit test)

**Acceptance Criteria:**
- [ ] `NClosure` carries the set of borrowed captures (region siblings) distinctly from owned captures.
- [ ] On closure drop, borrowed captures are NOT enqueued by the cascade; owned captures are.
- [ ] `enterRC`'s `consume` increfs only OWNED captures (borrowed ones stay owned by their group/static lifetime).
- [ ] A direct-store unit test builds a closure with one owned and one borrowed boxed capture, drops it, and asserts only the owned child is freed.

**Verify:** `cabal test wok-tests --test-show-details=direct -k "closure owned-borrowed store"` -> PASS.

**Steps:**

- [ ] **Step 1: Extend `NClosure`** to record borrowed captures. Minimal change — add a borrowed-set field (the `Unique`s, or the `Addr`s, of region-sibling captures):

```haskell
-- src/Wok/Interp/RC/Value.hs
| NClosure REnv [Binder] Expr (Set Unique)
  -- ^ Final field: the captured Uniques that are BORROWED (region siblings /
  -- static). Owned captures cascade on closure drop; borrowed ones do not --
  -- they are released by the group drop / static lifetime. Replaces the global
  -- 'isRegionAddr' shortcut with a per-closure decision (M2a-1).
```

- [ ] **Step 2: Make `countedChildren` skip a closure's borrowed captures.** Today it skips same-region siblings via `stRegionOf`; extend it so a closure node's own borrowed set is also excluded:

```haskell
countedChildren :: Addr -> Node -> Store -> [Addr]
countedChildren parent n s =
  let base = case IM.lookup parent (stRegionOf s) of
               Nothing     -> boxedChildren n
               Just region -> filter (not . sameRegionSibling region) (boxedChildren n)
  in case n of
       NClosure cenv _ _ borrowed ->
         let borrowedAddrs = [ a | (u, RVBox a) <- Map.toList cenv, u `Set.member` borrowed ]
         in filter (`notElem` borrowedAddrs) base
       _ -> base
  where
    sameRegionSibling region a = IM.lookup a (stRegionOf s) == Just region
```

- [ ] **Step 3: Update `enterRC`** (`Machine.hs:194-250`) so `captured` (the set increfed by `consume`) is only the OWNED boxed captures, and update all `NClosure` constructions (the `LetRec` build at `:94-126`, the partial-application `LT` branch) to pass the borrowed set. For LetRec members, the borrowed set is the sibling group `Unique`s present in the captured env.

- [ ] **Step 4: Write the direct-store unit test** in `test/Spec.hs`, mirroring the existing direct-store tests. Allocate two boxed children, build a closure owning one and borrowing the other, `dropAddr` the closure, assert the owned child is dead and the borrowed child is live:

```haskell
test_closureOwnedBorrowedStore :: TestTree
test_closureOwnedBorrowedStore = testCase "closure owned-borrowed store: borrowed capture not cascaded" $ do
  let s0           = emptyStore
      (ownedA, s1) = alloc (NCon (T.pack "Box") [RVLit (LInt 1)]) s0
      (borrA,  s2) = alloc (NCon (T.pack "Box") [RVLit (LInt 2)]) s1
      cenv         = Map.fromList [(u1, RVBox ownedA), (u2, RVBox borrA)]
      (clA, s3)    = alloc (NClosure cenv [] (Ret (AVar n1)) (Set.singleton u2)) s2
  case dropAddr clA s3 of
    Left e   -> assertFailure (show e)
    Right s4 -> do
      assertBool "owned child freed"  (IS.member ownedA (stDead s4))
      assertBool "borrowed child live" (not (IS.member borrA (stDead s4)))
```

(Use whatever `Unique`/`Name` constructors the existing direct-store tests use; match their imports.)

- [ ] **Step 5: Run, verify pass, commit**

Run: `cabal test wok-tests --test-show-details=direct -k "closure owned-borrowed store"`
Expected: PASS.

```bash
git add src/Wok/Interp/RC/Value.hs src/Wok/Interp/RC/Machine.hs test/Spec.hs
git commit -m "feat(rc): owned-vs-borrowed closure captures in the RC store"
```

---

### Task 3: Pass-side classification + dup-per-consuming-use

**Goal:** Make `Wok.IR.Perceus` tag a closure's region-sibling captures as borrowed (instead of leaving them implicitly exempt) and emit `__rc_dup` once per *consuming* use of an enclosing capture by a LetRec member, so the region keeps its owning unit.

**Files:**
- Modify: `src/Wok/IR/Perceus.hs` (`ownRhs` RLam build `:1038-1051`; `ownedOccs` `:997-1021`; `moveAtoms` `:1590-1600`; the LetRec instrumentation around `:836-895`; `ctxExempt` usage)
- Test: `test/Spec.hs` (Suite A golden auto-discovers the Task 1 corpus once they are no longer rejected — but they are still rejected until Task 5; so this task's test target is `balanceLint` on hand-built modules)

**Acceptance Criteria:**
- [ ] The instrumented closure carries the borrowed-capture set computed from `ctxExempt`.
- [ ] A LetRec member that moves an enclosing capture emits a build-site `__rc_dup` per consuming use (via the existing `ownedOccs`/`mkDupsForVars` machinery, extended to count consuming uses of `ctxExempt`-but-enclosing captures).
- [ ] `balanceLint` reports zero violations on a hand-built module matching the #1 and #4 reproducer shapes.
- [ ] Suite C teeth still bite: `lintInstrumented (insertRCMutated OmitOneDup ...)` and `OmitOneDrop` on these shapes are non-empty.

**Verify:** `cabal test wok-tests --test-show-details=direct -k "m2a-1 lint"` -> PASS.

**Steps:**

- [ ] **Step 1: Compute the borrowed set in `ownRhs (RLam ...)`** (`:1038`). Today `capsBoxed` excludes `ctxExempt` entirely. Split instead: owned boxed captures (as today) drive the move accounting; the `ctxExempt`-intersecting boxed captures become the borrowed set carried on the emitted closure. Thread the borrowed set through to the IR closure node so the interpreter's `NClosure` receives it.

- [ ] **Step 2: Count consuming uses for the dup plan.** Today `ownedOccs`/`moveAtoms` exclude `ctxExempt` members. For a LetRec member body, a consuming occurrence of an enclosing capture (everything except a `Case` scrutinee keeping no boxed child — see `letRecMemberConsumesCapture` at `:320`) must contribute a dup at the build site. Extend the LetRec dup plan (`:856-895`, the `need(u)`/`dups(u)` computation) to add one unit per consuming use of an enclosing capture, so each move is balanced.

- [ ] **Step 3: Add the lint test** in `test/Spec.hs`. Build (or load+elaborate) modules of the #1 and #4 shapes and assert `balanceLint` is clean, plus the teeth:

```haskell
test_m2a1Lint :: TestTree
test_m2a1Lint = testGroup "m2a-1 lint"
  [ testCase "consuming-capture non-escape lints clean" $ do
      cm <- elaboratedModuleOf "test/rc-examples/NN-consuming-capture-nonescape.wok"
      Perceus.balanceLint cm @?= []
  , testCase "rlam-sibling non-escape lints clean" $ do
      cm <- elaboratedModuleOf "test/rc-examples/NN-rlam-sibling-nonescape.wok"
      Perceus.balanceLint cm @?= []
  , testCase "teeth: OmitOneDup is caught on consuming-capture shape" $ do
      cm <- elaboratedModuleOf "test/rc-examples/NN-consuming-capture-nonescape.wok"
      assertBool "expected a lint violation"
        (not (null (Perceus.lintInstrumented (Perceus.insertRCMutated Perceus.OmitOneDup cm))))
  ]
```

(Add `elaboratedModuleOf :: FilePath -> IO CoreModule` next to `perceusLintHarness` if no equivalent exists; it runs `Loader.loadProgram` -> `Pipeline.elaborateProgramFull`. Note: `balanceLint` calls `insertRC` itself, so pass it the RAW elaborated module, not a pre-instrumented one.)

- [ ] **Step 4: Run, verify pass, commit**

Run: `cabal test wok-tests --test-show-details=direct -k "m2a-1 lint"`
Expected: PASS.

```bash
git add src/Wok/IR/Perceus.hs test/Spec.hs
git commit -m "feat(perceus): borrowed-capture tagging + dup-per-consuming-use"
```

---

### Task 4: `balanceLint` extension for the owned/borrowed split

**Goal:** Make the path-aware lint aware that a closure's borrowed captures are not consumed by the closure drop, so it neither demands a drop for them nor flags them as leaks.

**Files:**
- Modify: `src/Wok/IR/Perceus.hs` (`lintInstrumented`/`checkExpr` closure handling `:1456-1472`; LetRec handling `:1475-1511`)
- Test: covered by Task 3's `test_m2a1Lint` (clean + teeth); add one focused teeth case here for the borrowed path.

**Acceptance Criteria:**
- [ ] The closure-build lint seeds only OWNED boxed captures at +1 (borrowed ones excluded), matching the runtime's `enterRC` incref behavior.
- [ ] A `DuplicateOneDrop` mutation that drops a borrowed capture is caught (over-consume).
- [ ] No false leak is reported for a borrowed capture surviving the closure drop.

**Verify:** `cabal test wok-tests --test-show-details=direct -k "m2a-1 lint"` -> PASS (now including the borrowed teeth case).

**Steps:**

- [ ] **Step 1: Update the closure-capture seed** (`:1456-1472`). Today `capsB` is all boxed owned captures. Exclude the borrowed set so the lint's `cnt0` only seeds owned captures at +1; the borrowed captures are read-only borrows in the body.

- [ ] **Step 2: Update LetRec lint** (`:1475-1511`) so a member's borrowed enclosing captures are treated as exempt borrows (as today) but the build-site dups from Task 3 are accounted, keeping the `need(u)` arithmetic balanced.

- [ ] **Step 3: Add the borrowed-path teeth case** to `test_m2a1Lint`:

```haskell
  , testCase "teeth: DuplicateOneDrop on borrowed capture is caught" $ do
      cm <- elaboratedModuleOf "test/rc-examples/NN-rlam-sibling-nonescape.wok"
      assertBool "expected an over-consume violation"
        (not (null (Perceus.lintInstrumented (Perceus.insertRCMutated Perceus.DuplicateOneDrop cm))))
```

- [ ] **Step 4: Run, verify pass, commit**

Run: `cabal test wok-tests --test-show-details=direct -k "m2a-1 lint"`
Expected: PASS.

```bash
git add src/Wok/IR/Perceus.hs test/Spec.hs
git commit -m "feat(perceus): balanceLint owned/borrowed capture split"
```

---

### Task 5: Add an escape detector and narrow the #1/#4 guards to escapes only

**Goal:** Let the non-escaping #1 and #4 programs through the RC boundary (so they run under the full oracle), while still rejecting the escaping sub-cases (those are M2a-2). This requires a conservative escape detector reused later by M2a-2.

**Files:**
- Modify: `src/Wok/IR/Perceus.hs` (add `closureCaptureEscapes`/`memberConsumeEscapes` predicate next to `letRecEnclosingCaptureEscapes` at `:281`; export it)
- Modify: `src/Wok/IR/Reachable.hs` (`exprScopeFeaturesWith`: the inline #4 check at `:188`; the #1 check at `:234`)
- Test: `test/Spec.hs` (flip the Task 1 baseline test; the corpus now flows through Suites A/B/D)

**Acceptance Criteria:**
- [ ] A standalone `RLam` capturing a sibling is rejected ONLY if the closure escapes its `LetRec` scope; the non-escaping #4 reproducer is accepted.
- [ ] A member consuming an enclosing capture is rejected ONLY if a member escapes; the non-escaping #1 reproducer is accepted.
- [ ] The Task 1 baseline test is updated to assert the non-escaping cases are now ACCEPTED, and a new test asserts an *escaping* variant is still rejected.
- [ ] Suites A, B, D now exercise both reproducers and pass (golden files generated and reviewed; differential output matches the reference interpreter; heap accounting balances: `stLive == rcBaseline`, `stAllocs - stFrees == rcBaseline`).

**Verify:** `cabal test wok-tests --test-show-details=direct -k "rc"` -> PASS (full RC suite, including the new corpus).

**Steps:**

- [ ] **Step 1: Add the escape predicate** in `Perceus.hs`. For #4: does the capturing `RLam` flow to a position that outlives the enclosing `LetRec` (returned, stored in an escaping con/record, passed to a call whose result escapes, jumped out)? For #1: reuse the escape arm of `letRecEnclosingCaptureEscapes`. Be conservative: if escape cannot be ruled out, report escape (reject). Export the predicate for M2a-2.

- [ ] **Step 2: Narrow the guards in `Reachable.hs`.** At `:188` (the inline #4 check) gate the rejection on the escape predicate. At `:234` (the #1 check via `letRecMemberConsumesCapture`) gate on the escape arm. Keep #2 (`letRecEnclosingCaptureEscapes`) and #3 (`rawEnclosingFv`) rejecting as before — they are M2a-2.

- [ ] **Step 3: Flip the baseline test and add an escaping-variant rejection test:**

```haskell
test_m2a1GuardsNarrowed :: TestTree
test_m2a1GuardsNarrowed = testGroup "m2a-1 guards narrowed to escapes"
  [ testCase "consuming-capture non-escape now accepted" $ do
      vs <- boundaryViolationsOf "test/rc-examples/NN-consuming-capture-nonescape.wok"
      vs @?= []
  , testCase "rlam-sibling non-escape now accepted" $ do
      vs <- boundaryViolationsOf "test/rc-examples/NN-rlam-sibling-nonescape.wok"
      vs @?= []
  , testCase "escaping rlam-sibling still rejected" $ do
      vs <- boundaryViolationsOf "test/rc-examples/NN-rlam-sibling-escape.wok"
      assertBool "expected a rejection" (not (null vs))
  ]
```

Create `test/rc-examples/NN-rlam-sibling-escape.wok` as the escaping variant (return `h` instead of `0`):

```
module Main
import Std.Base

mk u =
  let f n = case n of
        0 -> u
        _ -> f (n - 1)
  in \m -> f (m + 1)     -- the closure ESCAPES mk's LetRec scope

main = (mk 7) 2
```

(Delete or rename the now-obsolete `test_m2a1Baseline` from Task 1.)

- [ ] **Step 4: Generate and review golden files.** First run creates `test/rc-perceus-golden/NN-*.expected` and `test/rc-stats-golden/NN-*.expected` for the two non-escaping corpus files. Inspect them: the Perceus dump must show the dup-per-consuming-use and the borrowed-capture tagging; the stats must balance.

Run: `cabal test wok-tests --test-show-details=direct -k "rc"`
Expected: first run writes goldens (some golden tests "fail" by creating files); second run PASS across Suites A-E.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/IR/Perceus.hs src/Wok/IR/Reachable.hs test/Spec.hs \
        test/rc-examples/NN-rlam-sibling-escape.wok \
        test/rc-perceus-golden/ test/rc-stats-golden/
git commit -m "feat(rc): narrow #1/#4 guards to escapes; M2a-1 reproducers run green"
```

---

### Task 6: Full-suite regression + slice wrap-up

**Goal:** Confirm the whole test suite is green and the slice is review-ready.

**Files:** none (verification only)

**Acceptance Criteria:**
- [ ] `cabal test wok-tests` is fully green (no regressions in the ~1019 existing tests).
- [ ] `hlint` is clean on the touched modules (ignoring `src-generated`).
- [ ] The four deferred-guard statuses are documented: #1/#4 narrowed to escapes; #2/#3 unchanged (M2a-2).

**Verify:** `cabal test wok-tests --test-show-details=direct` -> all PASS.

**Steps:**

- [ ] **Step 1: Run the full suite**

Run: `cabal test wok-tests --test-show-details=direct`
Expected: all PASS.

- [ ] **Step 2: Lint the touched modules**

Run: `hlint src/Wok/IR/Perceus.hs src/Wok/IR/Reachable.hs src/Wok/Interp/RC/Value.hs src/Wok/Interp/RC/Machine.hs`
Expected: no hints (or only pre-existing, readability-justified ones).

- [ ] **Step 3: Request full-branch review** (per `[[review-before-merge]]`) before merging M2a-1 to main. Do not merge without it.

- [ ] **Step 4: Commit any lint fixes**

```bash
git add -A
git commit -m "chore(rc): hlint cleanup for M2a-1"
```

---

## Self-Review

**Spec coverage (against spec §4.1):**
- Owned/borrowed `NClosure` split -> Task 2. Dup-per-consuming-use -> Task 3. `ctxExempt` "never touch" -> "borrow-correct dup/drop" -> Tasks 3-4. `balanceLint` owned/borrowed -> Task 4. Removes non-escaping #1/#4, narrows guards -> Task 5. The escape detector that M2a-2 reuses -> Task 5 (exported). All §4.1 requirements have a task.
- Out of scope and correctly excluded: region-lifetime promotion (#2/#3, M2a-2), continuations/effects (M2b).

**Placeholder scan:** Corpus file numbers use `NN-` as an explicit "pick the next free index" instruction, not a content placeholder. All test code is concrete and uses the real harness symbols (`perceusLintHarness`, `balanceLint`, `lintInstrumented`, `insertRCMutated`, `OmitOneDup`/`OmitOneDrop`/`DuplicateOneDrop`, `dropAddr`, `alloc`, golden directories). Implementation steps name exact symbols and line ranges; where the precise dup-placement diff is genuinely TDD-discovered, the task specifies the *behavior* plus the oracle that proves it (`balanceLint` clean + Suite D differential + Suite C teeth) — the project's actual validation method, not a hand-waved "add error handling."

**Type/name consistency:** `NClosure` gains one `Set Unique` field, used consistently in Value.hs (`countedChildren`), Machine.hs (construction + `enterRC`), and the Task 2 unit test. The escape predicate is introduced in Perceus.hs and consumed in Reachable.hs (Task 5). `elaboratedModuleOf`/`boundaryViolationsOf` helpers are introduced once (Tasks 1, 3) and reused.

**Known uncertainty flagged for the implementer:** the exact arity of `NClosure` construction sites and the precise `need(u)`/`dups(u)` arithmetic extension are confirmed against `Machine.hs:94-126` and `Perceus.hs:836-895` respectively, but the dup-placement is validated by the oracle, not asserted blind.
