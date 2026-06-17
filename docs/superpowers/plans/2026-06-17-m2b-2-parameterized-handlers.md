# M2b-2 Parameterized Handlers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lift the RC interpreter's effect-handler support to parameterized handlers (`hParam`), two-argument `resume`, and value/non-tail position, keeping the counted store heap-balanced — acceptance: the full `Std.Control` `state` get/set runner in both tail and value position, returning `(v, s)` heap-balanced.

**Architecture:** The handler parameter is a *baton* owned by whichever arm runs (Model B): every parameter drop is a compiler-placed `__rc_drop` (or a consume-by-operation), the runtime only does own-new on re-install and cascades dead cells. The one runtime-computed thing stays the `NCont` child-set (owned set), widened for the nested case. Slice 2a (parameter + two-arg resume + #3 fix + carrier wall, tail) lands first with the #3 owned-set fix *before* admission; slice 2b adds value-position (`answerRebind`). Reference interpreter `Wok.Interp.Machine` is the differential oracle; the Suite-G generative property is the durable soundness net.

**Tech Stack:** Haskell (GHC), tasty + Hspec + QuickCheck (`test/Spec.hs`), `cabal test wok-tests`.

**Spec:** `docs/superpowers/specs/2026-06-17-m2b-2-parameterized-handlers-design.md`.

**Branch:** `feat/m2b-2-parameterized-handlers` (off the M2b-1 tip). No merge to main by the implementer.

**Run a focused subset:** `cabal test wok-tests --test-options='-p "m2b"'` (tasty pattern match). Full suite: `cabal test wok-tests`.

---

## File map

| File | Responsibility | Tasks |
|---|---|---|
| `src/Wok/Interp/RC/Value.hs` | `continuationOwned` — owned-set walker; the #3 nested-handler-param fix | 1 |
| `src/Wok/IR/Escape.hs` | `m2bHandlerInFragment` — drop `hParam` then `hAnswerJoin` rejection | 2, 5 |
| `src/Wok/IR/Reachable.hs` | `m2bHandlerViolations` — same admission widening, precise messages | 2, 5 |
| `src/Wok/IR/Perceus.hs` | `ownExpr (Handle)` consumes `hParam`; `ownOpArm`/return arm own `hParam`; lint mirror | 2 |
| `src/Wok/Interp/RC/Machine.hs` | `enterRC` `NCont` two-arg resume arm (own-new); `answerRebindRC` | 3, 5 |
| `test/rc-m2b/*.wok` | run-corpus (auto-discovered → `assertRcAgrees`) | 4, 6 |
| `test/rc-m2b-reject/*.wok` | boundary-reject corpus (carrier wall) | 4 |
| `test/Spec.hs` | `genM2bProgram` extensions, unit test for #3, corpus wiring | 1, 4, 6 |

---

## Slice 2a — parameter + two-arg resume + #3 fix + carrier wall (tail position)

### Task 1: The #3 fix — nested passive handler parameter joins the `NCont` child-set

**Goal:** `continuationOwned` frees a nested *parameterized* handler's parameter when an enclosing continuation aborts. Lands the soundness fix *before* admission so no unsound window opens.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` (`continuationOwned`, the `KHandleRC` arm of `go`, ~line 240)
- Test: `test/Spec.hs` (new unit test in the m2b group)

**Acceptance Criteria:**
- [ ] `continuationOwned` over a prefix containing `KHandleRC h _ hsc k` where `hParam h = Just pb` and `hsc` binds `pb` to a dynamic `RVBox a` includes `a` in the result.
- [ ] A no-parameter nested `KHandleRC` (`hParam h = Nothing`) contributes nothing (M2b-1 behaviour unchanged).
- [ ] The nested-param address participates in `Unique` dedup (not double-counted with an aliasing named frame binder).
- [ ] Red-check: reverting the arm to `go k` makes the new unit test fail.

**Verify:** `cabal test wok-tests --test-options='-p "continuationOwned"'` → PASS

**Steps:**

- [ ] **Step 1: Write the failing unit test** in `test/Spec.hs` (a pure test — no Store needed; `continuationOwned :: RCKont -> [Addr]`). Build a minimal `Handler` with `hParam = Just pb` and an `RCScope` binding `pb` to `RVBox 7`, wrap it in `KHandleRC h 0 sc KDoneRC`, and assert the owned set is `[7]`. Add a companion assertion that `hParam = Nothing` yields `[]`.

```haskell
-- in the m2b unit-test group
testCase "continuationOwned frees a nested parameterized handler's param (#3)" $ do
  let pb   = Binder (Name (Tx.pack "s") (Unique 900)) someBoxedTy
      hParamHandler = Handler { hReturn = (vb, Ret (AVar (bndName vb)))
                              , hOps = [], hAnswerJoin = Nothing
                              , hParam = Just pb, hSelf = Nothing }
      sc   = RCScope (Map.fromList [(nameUniq (bndName pb), RVBox 7)]) Map.empty
      k    = KHandleRC hParamHandler 0 sc KDoneRC
  continuationOwned k @?= [7]
```
(Reuse an existing boxed-type helper / `Binder` builder already present in `Spec.hs`; if none, build the `CType` inline as the other unit tests do.)

- [ ] **Step 2: Run to verify it fails.** `cabal test wok-tests --test-options='-p "continuationOwned"'` → FAIL (current arm returns `[]`).

- [ ] **Step 3: Implement** the `KHandleRC` arm in `continuationOwned`'s `go`:

```haskell
-- Wok.Interp.RC.Value, continuationOwned, replacing  go (KHandleRC _ _ _ k) = go k
go (KHandleRC h _ hsc k) =
  [ (Just (binderUnique pb), a)
  | Just pb <- [hParam h]
  , Just v  <- [Map.lookup (binderUnique pb) (rscEnv hsc)]
  , a       <- countedRefs [v] ]
  ++ go k
```
Update the `-- !!! M2b-2 PREREQUISITE` comment above it to record that the nested param is now processed (drop the "skip" wording; keep the note that only the *parameter* is owned, the rest of `hsc` is owned elsewhere). `hParam`/`binderUnique` are already imported (`Wok.IR.Anf`); `Handler(..)` field `hParam` is in scope via the existing `Handler` import.

- [ ] **Step 4: Run to verify it passes.** `cabal test wok-tests --test-options='-p "continuationOwned"'` → PASS.

- [ ] **Step 5: Red-check** (manual, then revert): temporarily restore `go (KHandleRC _ _ _ k) = go k`, confirm the test FAILS, restore the fix.

- [ ] **Step 6: Commit.**
```bash
git add src/Wok/Interp/RC/Value.hs test/Spec.hs
git commit -m "fix(rc): continuationOwned frees a nested parameterized handler's param (M2b-2 #3)"
```

---

### Task 2: Perceus parameter ownership (the baton) + admission

**Goal:** The pass instruments parameterized handlers correctly (parameter consumed at the `Handle`, owned by the arm that runs, all drops compiler-placed) and the boundary admits `hParam` in tail position. Verified by a `--dump-perceus` golden — no runtime needed.

**Files:**
- Modify: `src/Wok/IR/Escape.hs` (`m2bHandlerInFragment`, ~line 642)
- Modify: `src/Wok/IR/Reachable.hs` (`m2bHandlerViolations`, ~line 357)
- Modify: `src/Wok/IR/Perceus.hs` (`ownExpr (Handle …)` ~line 875; `ownOpArm` ~line 904; return-arm seeding ~line 880; the `checkExpr` lint mirror)
- Test: `test/perceus-golden/` (new golden) + wiring already auto-discovers `perceus` goldens; if a dedicated m2b golden dir is used, follow the existing golden harness in `Spec.hs`.

**Acceptance Criteria:**
- [ ] `m2bHandlerInFragment` admits `hParam = Just _` (tail, non-escaping resume) and still rejects `hAnswerJoin = Just _`.
- [ ] `m2bHandlerViolations` no longer reports `hParam`; still reports value-position and escaping resume.
- [ ] `--dump-perceus` of `runState` shows: no drop of `s` after the `Handle` (parameter consumed at the `Handle`); the `set` arm drops the old parameter only if boxed; `get`/return arms consume it with no spurious drop.
- [ ] Existing M2b-1 no-param goldens are unchanged (no regression in arm instrumentation).

**Verify:** `cabal test wok-tests --test-options='-p "perceus"'` → PASS; and `cabal run -v0 wok -- test/run-examples/40-state-param.wok --dump-perceus` shows the expected instrumentation.

**Steps:**

- [ ] **Step 1: Write the failing golden.** Capture the *intended* `--dump-perceus` of a small boxed-parameter handler (use a `State [U64]`-style runner so the `set`-arm drop is a real boxed drop, making the golden meaningful). Place the program under `test/run-examples/` (or the perceus-golden source dir the harness uses) and add its `.expected`. The golden will FAIL until the pass changes land.

- [ ] **Step 2: Admit `hParam`** in `Wok.IR.Escape.m2bHandlerInFragment`:
```haskell
m2bHandlerInFragment h =
  isNothing (hAnswerJoin h)                       -- still tail-only (value position = slice 2b)
    && all (\oa -> not (m2bResumeEscapes (oaResume oa) (oaBody oa))) (hOps h)
```
Update the module-level fragment comment (drop "no handler parameter"; keep "tail position, non-escaping resume"). In `Wok.IR.Reachable.m2bHandlerViolations`, delete the `hParam` clause; keep the `hAnswerJoin` and resume-escape clauses.

- [ ] **Step 3: Consume the parameter at the `Handle`** in `Wok.IR.Perceus.ownExpr (Handle e h)`. When `hParam h = Just pb` and `boxedBinder pb`: remove `binderUnique pb` from the `delta` handed to `e` (so `e` does not drop it) and ensure it is not dropped by the enclosing scope after the `Handle` (it is consumed inward). Concretely, in the `m2bHandlerInFragment h` branch, compute `let pbU = [ binderUnique pb | Just pb <- [hParam h], boxedBinder pb ]` and instrument `e` under `delta `Set.difference` Set.fromList pbU`. (The `Handle` is the tail of `runState`'s body, so there is no post-`Handle` code to also guard, but keeping the subtraction at `e` is the general-correct form.)

- [ ] **Step 4: Own the parameter in the arms** that run. In the return-arm seeding (the `retDelta`/`retCtx` lines), add `pb` (boxed) to `retDelta` and bind it in `retCtx`:
```haskell
retDelta = Set.fromList ([ binderUnique rb | boxedBinder rb ]
                         ++ [ binderUnique pb | Just pb <- [hParam h], boxedBinder pb ])
retCtx   = foldr ctxBind (armCtxReset ctx) (rb : [ pb | Just pb <- [hParam h] ])
```
In `ownOpArm`, give the arm ownership of `pb` too:
```haskell
ownOpArm ctx hParamB sup (OpArm lbl op args resume body) =
  let bs       = args ++ [resume] ++ maybe [] pure hParamB
      armCtx   = (ctxBinds bs (armCtxReset ctx))
                   { ctxResume = Set.singleton (binderUnique resume) }
      armDelta = Set.fromList [ binderUnique b | b <- bs, boxedBinder b ]
      ...
```
Thread `hParam h` into the `mapAccumLPairs (ownOpArm ctx (hParam h)) sup2 (hOps h)` call. The parameter is now an owned binder of whichever arm runs; existing last-use placement does the rest (`set`'s dead old param → drop; `get`/return's use → consume).

- [ ] **Step 5: Mirror in the lint** (`checkExpr`'s `Handle`/op-arm path): seed the same parameter into the per-path owned counts so the balance lint agrees with `ownExpr`. (Find the `checkExpr` analogue of `ownOpArm`/the return-arm seeding and add `hParam` identically.)

- [ ] **Step 6: Run goldens.** `cabal test wok-tests --test-options='-p "perceus"'` → PASS (new golden green, no M2b-1 golden regressions). Inspect `--dump-perceus` of `40-state-param.wok` to confirm the parameter is consumed-at-`Handle` and dropped only where dead-and-boxed.

- [ ] **Step 7: Commit.**
```bash
git add src/Wok/IR/Escape.hs src/Wok/IR/Reachable.hs src/Wok/IR/Perceus.hs test/
git commit -m "feat(rc): Perceus owns the handler parameter (baton); admit hParam in tail position"
```

---

### Task 3: Runtime two-argument resume (own-new on re-install)

**Goal:** Applying a parameterized continuation rebinds the parameter slot (pure own-new) and delivers the result; `State` get/set runs heap-balanced end-to-end.

**Files:**
- Modify: `src/Wok/Interp/RC/Machine.hs` (`enterRC` `NCont` arm, ~line 398)
- Test: `test/rc-m2b/20-state-tail.wok` (new; auto-discovered → `assertRcAgrees`)

**Acceptance Criteria:**
- [ ] The `NCont` arm dispatches on `hParam h`: `Nothing` → one-arg (M2b-1, unchanged); `Just pb` → two-arg `[newParam, result]`, rebinding `hsc[pb]` to `newParam` and delivering `result`.
- [ ] No `dropAddr` of the old parameter in the resume arm (own-new only) — assert by code inspection + the heap-balance oracle.
- [ ] Arity mismatch (`Just pb` with one arg, or `Nothing` with two) is a loud `ArityError`.
- [ ] `test/rc-m2b/20-state-tail.wok` is heap-balanced and matches the reference (`assertRcAgrees`).

**Verify:** `cabal test wok-tests --test-options='-p "rc-m2b/20"'` → PASS (or run the full `-p "m2b"` group).

**Steps:**

- [ ] **Step 1: Write the failing corpus program** `test/rc-m2b/20-state-tail.wok` — a `runState` runner used in **tail** position (`main = runState 100 prog`, `prog` does `get`/`set`/`get`, returns `(v, s)`). Model it on `test/run-examples/40-state-param.wok`. Being in `test/rc-m2b/` it is auto-run by `assertRcAgrees`. It will FAIL until the runtime arm lands.

- [ ] **Step 2: Run to verify it fails.** `cabal test wok-tests --test-options='-p "rc-m2b/20"'` → FAIL (one-arg-only `NCont` arm hits the arity error / wrong value).

- [ ] **Step 3: Implement** the two-arg `NCont` arm in `enterRC`, replacing the current `NCont{} -> case args of [v] -> …`:
```haskell
NCont{} -> do
  (prefix, (h, hTag, hsc), s') <- moveOutCont addr s   -- frees the shell, asserts rc == 1
  case (hParam h, args) of
    (Nothing, [v]) ->
      Right (RReturn v (spliceKont prefix (KHandleRC h hTag hsc k)) s')
    (Just pb, [newParam, result]) ->
      let hsc' = hsc { rscEnv = bindRCBinder pb newParam (rscEnv hsc) }   -- own-new, pure move
          k'   = spliceKont prefix (KHandleRC h hTag hsc' k)
      in Right (RReturn result k' s')
    _ -> Left (ArityError (Tx.pack "resume arity does not match handler parameter"))
```
`hParam`/`bindRCBinder` are already in scope. Note `moveOutCont` runs once and yields `h`, so the arity is decided from the handler, mirroring the reference `VCont`/`VContP` split.

- [ ] **Step 4: Run to verify it passes.** `cabal test wok-tests --test-options='-p "rc-m2b/20"'` → PASS (heap-balanced, matches reference).

- [ ] **Step 5: Regression.** `cabal test wok-tests --test-options='-p "m2b"'` → existing M2b-1 corpus + the new program all green.

- [ ] **Step 6: Commit.**
```bash
git add src/Wok/Interp/RC/Machine.hs test/rc-m2b/20-state-tail.wok
git commit -m "feat(rc): two-arg resume (own-new param re-install); State get/set tail heap-balanced"
```

---

### Task 4: 2a acceptance corpus + generator (CHECKPOINT)

**Goal:** Prove 2a sound at scale: Writer, nested State+Reader, the #3 nested-abort exploit end-to-end, the carrier-wall reject, and the Suite-G generator extended with parameterized shapes. This is the 2a oracle checkpoint.

**Files:**
- Create: `test/rc-m2b/21-writer.wok`, `test/rc-m2b/22-nested-state-reader.wok`, `test/rc-m2b/23-nested-state-abort.wok`
- Create: `test/rc-m2b-reject/13-carrier-wall-param-reject.wok`
- Modify: `test/Spec.hs` (`genM2bProgram` + `cover` floors; wire the new reject case into `rcM2bRejectTests`)

**Acceptance Criteria:**
- [ ] `21-writer.wok` (`tell w k -> k (log ++ w) ()`, boxed `[w]` parameter) heap-balanced.
- [ ] `22-nested-state-reader.wok` (a parameterized `State` with a `Reader` in scope) heap-balanced.
- [ ] `23-nested-state-abort.wok` — boxed-parameter nested `State` inside an outer aborting handler; the inner parameter is freed exactly once (heap-balanced). Red-check: reverting Task 1 makes this go red.
- [ ] `13-carrier-wall-param-reject.wok` — an arm that seats a continuation into the parameter (`op(x, resume) -> resume(resume, ())`) is rejected by `firstOrderNoHandlerViolations`. Red-check: removing the resume-escape guard admits it.
- [ ] `genM2bProgram` emits: `hParam` present/absent, one/two-arg resume, a boxed parameter dropped on a `set`-to-constant path, a nested parameterized handler in an aborting prefix. `checkCoverage` floors assert each shape is non-vacuously hit.
- [ ] `prop_m2bEscape`/`prop_m2bTeeth`/`prop_m2bLintClean` pass with the widened generator.

**Verify:** `cabal test wok-tests --test-options='-p "m2b"'` → PASS; then full `cabal test wok-tests` → all green.

**Steps:**

- [ ] **Step 1: Add the run-corpus programs** (`21`, `22`, `23`) under `test/rc-m2b/` — they are auto-discovered and run through `assertRcAgrees`. Author `23` so the inner `State` parameter is **boxed** and the op is handled by the **outer** handler (so the inner `KHandleRC` is in the captured prefix) and the outer **aborts**.

- [ ] **Step 2: Add the carrier-wall reject** `test/rc-m2b-reject/13-carrier-wall-param-reject.wok` and wire an assertion into `rcM2bRejectTests` (mirror the existing `08`/`09`/`12` entries: `boundaryViolationsOf … >>= assertBool … (not (null vs))`).

- [ ] **Step 3: Extend `genM2bProgram`** in `test/Spec.hs` with the parameterized dimensions and add `cover`/`checkCoverage` floors (mirror the existing M2b-1 `cover` calls). The generator's arms must be **non-constant** (the M2b-1 lesson: constant-bodied arms missed the capture UAF) — generate `set`/`get`/`tell`-shaped arms with a boxed parameter and an abort variant.

- [ ] **Step 4: Run the m2b group and red-checks.** `cabal test wok-tests --test-options='-p "m2b"'` → PASS. Perform the two red-checks (revert Task 1 → `23` red; remove resume-escape guard → `13` admitted), then restore.

- [ ] **Step 5: Full suite.** `cabal test wok-tests` → all green (no regression across the ~1120 existing tests).

- [ ] **Step 6: Commit + checkpoint.**
```bash
git add test/rc-m2b/ test/rc-m2b-reject/ test/Spec.hs
git commit -m "test(rc): 2a acceptance (Writer, nested State+Reader, #3 abort exploit, carrier wall) + generator"
```
**2a CHECKPOINT** — surface heap-balance/oracle results and the red-check outcomes before starting 2b.

---

## Slice 2b — value / non-tail position (`answerRebind`)

### Task 5: RC-balanced `answerRebind` + value-position admission

**Goal:** A resumed sub-run's answer is delivered to the resume call site (not the static post-handler continuation), RC-balanced; `State` in value position runs heap-balanced.

**Files:**
- Modify: `src/Wok/Interp/RC/Machine.hs` (`enterRC` `NCont` arm — apply `answerRebindRC` to the re-installed scope; add the helper)
- Modify: `src/Wok/IR/Escape.hs` (`m2bHandlerInFragment` — drop the `hAnswerJoin` rejection)
- Modify: `src/Wok/IR/Reachable.hs` (`m2bHandlerViolations` — drop the value-position clause)
- Test: `test/rc-m2b/24-state-value.wok`, `test/rc-m2b/25-value-abort.wok`

**Acceptance Criteria:**
- [ ] `answerRebindRC` rebinds the answer-join in the re-installed scope to a single-param identity join continuing at the resume site `k`, mirroring the reference `answerRebind` (`Machine.hs:199`), for both one-arg and two-arg resume.
- [ ] `m2bHandlerInFragment`/`m2bHandlerViolations` admit value position (`hAnswerJoin = Just _`); escaping resume (M3) still rejected.
- [ ] `24-state-value.wok` (`let r = runState 0 prog in <use r>`) heap-balanced and matches the reference.
- [ ] `25-value-abort.wok` (a value-position handler whose op aborts) heap-balanced.
- [ ] No counted value is leaked/double-freed by the rebind (heap-balance oracle confirms).

**Verify:** `cabal test wok-tests --test-options='-p "rc-m2b/24|rc-m2b/25"'` → PASS.

**Steps:**

- [ ] **Step 1: Write the failing corpus programs** `24-state-value.wok` and `25-value-abort.wok` under `test/rc-m2b/`. These FAIL initially because value-position handlers are still boundary-rejected (so Perceus does not instrument them → wrong/unbalanced).

- [ ] **Step 2: Admit value position.** In `m2bHandlerInFragment`, drop the `isNothing (hAnswerJoin h)` conjunct (now: non-escaping resume only). In `m2bHandlerViolations`, delete the `hAnswerJoin` clause. Update comments to record value position is in-fragment.

- [ ] **Step 3: Implement `answerRebindRC`** in `Wok.Interp.RC.Machine` and apply it in the `NCont` arm to the re-installed scope (composing with the own-new param rebind from Task 3):
```haskell
answerRebindRC :: Handler -> RCKont -> RCScope -> RCScope
answerRebindRC h after sc =
  case hAnswerJoin h of
    Just j
      | Just (RCJoin _ ps _ _) <- Map.lookup j (rscJoins sc)
      , (pb0 : _) <- ps ->
          sc { rscJoins = Map.insert j
                 (RCJoin sc ps (Ret (AVar (bndName pb0))) after)
                 (rscJoins sc) }
    _ -> sc
```
In the `NCont` arm, wrap the re-installed `hsc`/`hsc'` with `answerRebindRC h k` before `spliceKont` (apply to both the `Nothing` and `Just pb` branches; `k` is the reference's `after`).

- [ ] **Step 4: Run to verify it passes.** `cabal test wok-tests --test-options='-p "rc-m2b/24|rc-m2b/25"'` → PASS (heap-balanced, matches reference).

- [ ] **Step 5: Regression.** `cabal test wok-tests --test-options='-p "m2b"'` → all green.

- [ ] **Step 6: Commit.**
```bash
git add src/Wok/Interp/RC/Machine.hs src/Wok/IR/Escape.hs src/Wok/IR/Reachable.hs test/rc-m2b/
git commit -m "feat(rc): RC-balanced answerRebind; admit value-position handlers; State value-position heap-balanced"
```

---

### Task 6: 2b acceptance + generator value-position dimension (CHECKPOINT)

**Goal:** Prove value position sound at scale: extend the generator with a value-position dimension (including value-position abort) and confirm the property + full suite. This is the 2b oracle checkpoint.

**Files:**
- Modify: `test/Spec.hs` (`genM2bProgram` value-position dimension + `cover` floors)
- Create: any additional value-position corpus programs needed to anchor the property's coverage

**Acceptance Criteria:**
- [ ] `genM2bProgram` emits value-position handlers (handler under a `case`/join) and value-position aborts; `checkCoverage` floors: "non-tail resume run", "value-position abort run".
- [ ] `prop_m2bEscape`/`prop_m2bTeeth`/`prop_m2bLintClean` pass with the value-position dimension.
- [ ] Full `cabal test wok-tests` green.

**Verify:** `cabal test wok-tests` → all green.

**Steps:**

- [ ] **Step 1: Extend `genM2bProgram`** with the value-position dimension (wrap a generated handler in a `case`/value context so `hAnswerJoin = Just _`) and an abort-in-value-position arm. Add `cover` floors.

- [ ] **Step 2: Run the property.** `cabal test wok-tests --test-options='-p "m2b"'` → PASS with the new coverage non-vacuous.

- [ ] **Step 3: Full suite.** `cabal test wok-tests` → all green.

- [ ] **Step 4: Commit + checkpoint.**
```bash
git add test/Spec.hs test/rc-m2b/
git commit -m "test(rc): 2b generative coverage (value position + value-position abort)"
```
**2b CHECKPOINT** — surface results. Then hand off for the user's full-branch `/code-review` and merge gate (no merge by the implementer).

---

## Self-review notes (coverage against the spec)

- §1 baton model → Tasks 2 (Perceus ownership), 3 (own-new runtime). §3.4 #3 → Task 1. §3.5 carrier wall → Task 4. §3.6 admission → Tasks 2/5. §4 value position → Task 5. §6 oracle/generator → Tasks 4/6. All spec sections map to a task.
- Ordering invariant: the #3 fix (Task 1) precedes admission (Task 2), so admission never outruns the owned-set fix.
- Each lifted rejection ships with a reproducer + red-check (Tasks 1, 4). Each runtime change is gated by the heap-balance oracle (Tasks 3, 5) and the generator (Tasks 4, 6).
