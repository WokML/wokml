# M2a-2 — Shared-Env Recursive Closures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the RC interpreter's cyclic `letrec` closure representation (the uncounted "region" knot) with a shared-environment + code-pointer representation, under a uniform borrow-on-call convention, so that all escaping recursive-group shapes (#1–#4) become ordinary acyclic reference counting and their boundary-guard rejections come down.

**Architecture:** Recursion lives in *code* (a static group-code cell + an inline `RVRecMember` value resolving siblings by index), data is a DAG (one shared env cell `E` holding captures once). Every function call *borrows* its function value (dropped at last use by Perceus), so a bare `RVRecMember` escapes and is called externally with no wrapper. Soundness is bisimulation to acyclic Perceus. Full design: `docs/superpowers/specs/2026-06-15-m2a-2-shared-env-recursive-closures-design.md` (+ companion reasoning doc).

**Tech Stack:** Haskell (GHC, Strict+StrictData repo-wide — never add `!`, only `~` for laziness), tasty + Hspec + QuickCheck, `cabal`/`stack` per repo. Modules: `Wok.Interp.RC.{Value,Machine,Prim}`, `Wok.IR.{Perceus,Reachable,Escape,Anf}`, `test/Spec.hs`.

**Branch base:** off `feat/m2a-1-owned-borrowed-captures` (M2a-1 not yet merged to `main`). Create `feat/m2a-2-shared-env-recursive-closures`.

**Staging rationale (read before starting):** the change is coupled, so it is sequenced into five stages that each reach green:

1. **Stage 1 (Task 1)** — uniform borrow-on-call on the *existing* representation. Isolates the convention change; the whole existing corpus must stay green.
2. **Stage 2 (Tasks 2–4)** — add the shared-env representation and route `letrec` through it, while the boundary guard *still* rejects escaping shapes (so only non-escaping `letrec` exercises the new code).
3. **Stage 3 (Task 5)** — take down the #2/#3/#4 escape guards; Suite G generates and *runs* the now-admitted escaping shapes.
4. **Stage 4 (Task 6)** — the #1 (consuming-capture) verification gate; remove `consumeViol` only if the former unsound corpus runs heap-balanced.
5. **Stage 5 (Task 7)** — retire dead region machinery and regenerate Suite B goldens.

**Verify-command convention:** the repo's test runner is invoked as `<RUNNER> <args>` where `<RUNNER>` is whatever the repo uses (`cabal test`, `stack test`, or `cabal run wok-test --`). Each task's Verify line uses tasty's `-p` pattern selector (`--test-arguments '-p "/pattern/"'` for cabal, `--ta '-p "/pattern/"'` for stack). The first step of Task 1 pins the exact runner; reuse it verbatim thereafter.

---

### Task 0: Branch, baseline, pin the test runner

**Goal:** Establish the working branch and a known-green baseline, and record the exact test command used by every later task.

**Files:**
- None modified (branch + baseline only).

**Acceptance Criteria:**
- [ ] Branch `feat/m2a-2-shared-env-recursive-closures` exists, based on `feat/m2a-1-owned-borrowed-captures`.
- [ ] The full suite is green at baseline; the exact green count is recorded.
- [ ] The exact test runner invocation is recorded in this task's notes for reuse.

**Verify:** full test suite passes at baseline (record the green count, expected 1058).

**Steps:**

- [ ] **Step 1: Create the branch**

```bash
git checkout feat/m2a-1-owned-borrowed-captures
git checkout -b feat/m2a-2-shared-env-recursive-closures
```

- [ ] **Step 2: Determine and run the test runner**

Try, in order, the first that the repo supports (inspect `*.cabal`/`stack.yaml`/`Makefile` to choose):

```bash
cabal test 2>&1 | tail -20
# or: stack test 2>&1 | tail -20
```

Expected: all tests pass (record the count, e.g. `1058 examples, 0 failures` or tasty's `All N tests passed`).

- [ ] **Step 3: Record the runner**

Write the working command into the commit message of Step 4 (e.g. `RUNNER=cabal test`). Every later task's "Verify" reuses it.

- [ ] **Step 4: Commit the branch point (no code change)**

```bash
git commit --allow-empty -m "chore(rc): branch M2a-2 off M2a-1; baseline green (RUNNER=<cmd>)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 1: Uniform borrow-on-call (existing representation)

**Goal:** Change the calling convention so applying any function value *borrows* it (no consume); Perceus drops function values at their last use instead of relying on the call to consume them. Keep the existing region/closure representation. The whole corpus stays green.

**Files:**
- Modify: `src/Wok/Interp/RC/Machine.hs` — `enterRC` (the `NClosure` branch, ~lines 199–261): remove the `consume` (incref-owned-captures-then-`dropAddr`-cell) logic; bind params + captures and evaluate the body without consuming or increfing.
- Modify: `src/Wok/IR/Perceus.hs` — the application/`RApp` handling in `ownExpr`/`ownRhs` (the head atom is currently treated as a consumed move; make it a borrow so the standard last-use drop machinery emits the drop for the function binder).
- Modify: `src/Wok/Interp/RC/Value.hs` — `enterRC`/`closureOwnedBoxed` interactions only if needed (no representation change).
- Test: `test/Spec.hs` — add a borrow-convention regression group (below).

**Acceptance Criteria:**
- [ ] `enterRC` no longer drops the closure cell or increfs owned captures on an exact-arity call; the cell stays live (dropped later at the caller's last use).
- [ ] A closure called N times is dup'd 0 times and dropped exactly once (at last use); heap stays balanced.
- [ ] The full existing corpus is green (values unchanged, heap-balanced). Suite B `peakLive` goldens may shift; regenerate within this task and review each diff.
- [ ] `balanceLint`/`lintInstrumented` are clean on the existing corpus under the new convention.

**Verify:** full suite green; specifically `<RUNNER> -p "/borrow-on-call/"` passes and `-p "/Suite B/"` passes with reviewed golden updates.

**Steps:**

- [ ] **Step 1: Write the failing borrow-convention test**

Add to `test/Spec.hs` (a new `testGroup "borrow-on-call"`). This program calls one closure twice; under borrow it needs zero dups and one drop, and must be heap-balanced:

```haskell
-- main = let f = \x -> x + 1
--        let a = f 10
--        let b = f 20      -- f used twice; borrow => no dup, drop at last use
--        in a + b
borrowOnCallTwiceBalanced :: Assertion
borrowOnCallTwiceBalanced = do
  let intTy = Ty.CTCon Ty.TcU64 []
      nm h u = Name (T.pack h) (Unique u)
      fLam = RLam [Binder (nm "x" 1) Unrestricted intTy]
               (Let (Binder (nm "x1" 2) Unrestricted intTy)
                    (RApp (primName (T.pack "+")) [AVar (nm "x" 1), ALit (LInt 1)])
                 (Ret (AVar (nm "x1" 2))))
      body =
        Let (Binder (nm "f" 3) Unrestricted (Ty.CTCon (Ty.TcUser (T.pack "Fun")) [])) fLam
          (Let (Binder (nm "a" 4) Unrestricted intTy) (RApp (AVar (nm "f" 3)) [ALit (LInt 10)])
            (Let (Binder (nm "b" 5) Unrestricted intTy) (RApp (AVar (nm "f" 3)) [ALit (LInt 20)])
              (Let (Binder (nm "s" 6) Unrestricted intTy)
                   (RApp (primName (T.pack "+")) [AVar (nm "a" 4), AVar (nm "b" 5)])
                (Ret (AVar (nm "s" 6))))))
      cm     = CoreModule [TopBind (nm "main" 1000000) [] body]
      pruned = pruneToReachable cm
  -- 1. boundary accepts (closures are in-fragment)
  assertBool "must be accepted" (null (firstOrderNoHandlerViolations pruned))
  -- 2. runs sound + heap-balanced + matches reference
  case (Interp.runModule pruned, RCM.runModuleRC (Perceus.insertRC pruned)) of
    (Right v, Right run) -> do
      assertEqual "value" (Interp.renderValue v) (RCM.rcOutput run)
      let st = RCM.rcStats run
      assertEqual "heap empty"   (St.stLive st)                       (RCM.rcBaseline run)
      assertEqual "balanced" (St.stAllocs st - St.stFrees st)         (RCM.rcBaseline run)
    other -> assertFailure ("interpreter disagreement: " <> show other)
  -- 3. static lint clean
  assertEqual "balanceLint clean" [] (Perceus.balanceLint pruned)
```

Register it: add `testCase "closure called twice is borrow-balanced" borrowOnCallTwiceBalanced` to a new `borrowOnCallTests :: TestTree` and wire `borrowOnCallTests` into the top-level tasty tree next to the other RC groups.

- [ ] **Step 2: Run to verify the test exists and observe current behavior**

Run: `<RUNNER> -p "/borrow-on-call/"`
Expected: under the *current* consume-on-call convention this may already pass (the program is balanced either way); its purpose is to lock the convention. If it passes now, proceed — Step 5's lint/golden checks are what actually pin the convention. If it fails, note the failure mode.

- [ ] **Step 3: Make `enterRC` borrow (no consume) for `NClosure`**

In `src/Wok/Interp/RC/Machine.hs`, the `enterRC` `NClosure` branch currently computes `consume` (incref owned captures, then `dropAddr addr`). Replace the exact-arity (`EQ`) path so it neither increfs captures nor drops the cell:

```haskell
      cl@(NClosure cenv ps body _) -> do
        let np = length ps; na = length args
        case compare na np of
          EQ ->
            -- BORROW: do not consume the closure value. The caller's binder owns it
            -- and Perceus drops it at last use; the cell stays live through the body
            -- (its binding lives in the suspended caller scope), so captures can be
            -- read directly from cenv. A consuming use of a capture inside the body
            -- is dup'd by Perceus at that use (dup-on-consume).
            Right (REval body (RCScope (bindRCBinders ps args cenv) Map.empty) k s)
          LT -> do
            -- Partial application under borrow: build a fresh closure capturing dup'd
            -- copies of the shared captures plus the supplied args; the original is
            -- NOT consumed (dropped later at last use). Dup each boxed shared capture.
            let cenv'    = bindRCBinders (take na ps) args cenv
            s' <- foldM (flip incref) s (closureOwnedBoxed cl)
            let (a', s'') = alloc (mkClosure cenv' (drop na ps) body s') s'
            Right (RReturn (RVBox a') k s'')
          GT ->
            Right (REval body (RCScope (bindRCBinders ps args cenv) Map.empty)
                     (KAppRC (drop np args) k) s)
```

Note: the `_` borrowed-set field of `NClosure` is now irrelevant for the EQ path (no cascade-on-call); it is retired in Task 7. The `mkClosure` call in `LT` is retained for now and simplified in Task 7.

- [ ] **Step 4: Make Perceus treat the `RApp` head as a borrow**

In `src/Wok/IR/Perceus.hs`, the application handling currently treats the head atom of `RApp f as` as a consumed move (it is exempt from `escapingAtomsRhs`, and the call is assumed to release it). Change `ownRhs`/`ownExpr` so the head `f` is a *use* (borrow), not a move: do not mark `f` consumed by the call; let the standard last-use analysis (the `neededLater`/dead-binder drop logic already in the `Let` rule) insert `__rc_drop f` at `f`'s last use. Concretely, the head occurrence must be added to the "owned occurrences that are reads, not moves" so the existing dead-after-last-use path drops it. Keep argument handling unchanged (args stay owned/moved as today).

```haskell
-- In the RApp case of ownRhs: the head 'f' is BORROWED (a read), not moved.
-- Add 'f's unique to the set of borrowed reads for this RHS so it participates in
-- last-use accounting like any other read; do NOT add it to moveAtoms.
-- Arguments 'as' keep their current owned/move treatment.
```

(The implementer follows the existing structure: wherever the head was previously excluded from drops because "the call consumes it", instead include it in the normal last-use drop set. The `borrowOnCallTwiceBalanced` test and `balanceLint` pin correctness.)

- [ ] **Step 5: Run the test, the lint, and the full suite; regenerate Suite B**

Run: `<RUNNER> -p "/borrow-on-call/"` → Expected: PASS.
Run: `<RUNNER>` (full suite) → Expected: all green except possibly Suite B `peakLive`/`frees-timing` goldens. For each shifted golden, confirm `allocs - frees` is unchanged (totals must not change; only `peakLive` may rise because function values now live to last use). Regenerate via the repo's golden-update mechanism (e.g. `--accept` / `--golden-reset`, or the `--dump-rc-stats` CLI used by Suite B) and review each diff.
Run: `<RUNNER> -p "/balanceLint/"` (or the lint property) → Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add src/Wok/Interp/RC/Machine.hs src/Wok/IR/Perceus.hs test/Spec.hs <regenerated goldens>
git commit -m "feat(rc): uniform borrow-on-call (function values dropped at last use)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Add the shared-env representation to the RC store

**Goal:** Add the `RVRecMember` value, the `NGroupCode`/`NEnv` nodes, the `valueChildren` abstraction, and route `incref`/`dropAddr`/`boxedChildren`/rendering through it. Purely additive — nothing produces these values yet, so the existing corpus stays green.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` — `RCValue` (+`RVRecMember Addr Int Addr`), `Node` (+`NGroupCode [(Binder,[Binder],Expr)]`, +`NEnv (Map Unique RCValue)`), add `valueChildren`, route `boxedChildren`/`nodeValues`/`incref`/`dropAddr`, add a static empty-env sentinel and `renderRCValue` case, export the new symbols.
- Test: `test/Spec.hs` — a unit test exercising `valueChildren` and dup/drop on a hand-built `RVRecMember` (below).

**Acceptance Criteria:**
- [ ] `RVRecMember`, `NGroupCode`, `NEnv` compile and are exported.
- [ ] `valueChildren (RVRecMember _ _ e) == [e]`, `valueChildren (RVBox a) == [a]`, `valueChildren (RVLit _) == []`.
- [ ] `incref`/`dropAddr` on an `RVRecMember` act on its env addr; on a capture-free member (sentinel env, static addr) they are no-ops.
- [ ] `renderRCValue` renders an `RVRecMember` as `"<closure>"`.
- [ ] Full existing corpus green (new variants unused).

**Verify:** `<RUNNER> -p "/rvrecmember-rep/"` passes and full suite green.

**Steps:**

- [ ] **Step 1: Write failing representation unit tests**

Add to `test/Spec.hs` (`testGroup "rvrecmember-rep"`):

```haskell
rvRecMemberChildren :: Assertion
rvRecMemberChildren = do
  assertEqual "lit has no children"   [] (St.valueChildren (RVLit LUnit))
  assertEqual "box child"             [7] (St.valueChildren (RVBox 7))
  assertEqual "recmember counts env"  [9] (St.valueChildren (St.RVRecMember (-5) 0 9))

rvRecMemberDropCountsEnv :: Assertion
rvRecMemberDropCountsEnv = do
  -- alloc an env cell at rc=1; an RVRecMember referencing it; drop the member
  -- => env freed.
  let (e, s0) = St.alloc (St.NEnv Map.empty) St.emptyStore
  case St.dropAddr e s0 of                  -- direct drop of the env addr
    Right s1 -> assertEqual "env freed" 0 (St.stLive (St.stStats s1))
    Left err -> assertFailure (show err)
```

Register them under `rvRecMemberRepTests :: TestTree` wired into the tasty tree.

- [ ] **Step 2: Run to confirm failure (symbols missing)**

Run: `<RUNNER> -p "/rvrecmember-rep/"`
Expected: compile error / FAIL — `RVRecMember`, `NEnv`, `valueChildren` not in scope.

- [ ] **Step 3: Extend `RCValue` and `Node`, add `valueChildren` and the sentinel**

In `src/Wok/Interp/RC/Value.hs`:

```haskell
data RCValue
  = RVLit Lit
  | RVBox Addr
  | RVRecMember Addr Int Addr          -- groupAddr (static), index, envAddr (counted)
  deriving (Eq, Show)

data Node
  = NCon Text [RCValue]
  | NRecord Text (Map Text RCValue)
  | NClosure REnv [Binder] Expr (Set Unique)
  | NGroupCode [(Binder, [Binder], Expr)]      -- static immortal "code label"
  | NEnv (Map Unique RCValue)                  -- the one shared captured-env cell
  deriving (Eq, Show)

-- Counted addrs reachable directly from a value (single source of truth).
valueChildren :: RCValue -> [Addr]
valueChildren (RVLit _)           = []
valueChildren (RVBox a)           = [a]
valueChildren (RVRecMember _ _ e) = [e]
```

Add a static empty-env sentinel installed once into the static region (a negative addr holding `NEnv Map.empty`); expose it so `LetRec` eval (Task 3) can use it for capture-free groups. Export `RVRecMember`, `NGroupCode`, `NEnv`, `valueChildren`, and the sentinel accessor.

- [ ] **Step 4: Route children/rendering through `valueChildren`**

Update `boxedChildren`/`nodeValues` so a node's counted children are the concat of `valueChildren` over its fields, and add the new nodes:

```haskell
nodeValues :: Node -> [RCValue]
nodeValues (NCon _ vs)          = vs
nodeValues (NRecord _ m)        = Map.elems m
nodeValues (NClosure env _ _ _) = Map.elems env
nodeValues (NGroupCode _)       = []          -- static code, no counted children
nodeValues (NEnv m)             = Map.elems m

boxedChildren :: Node -> [Addr]
boxedChildren = concatMap valueChildren . nodeValues
```

Add `renderRCValue` / `renderNode` cases:

```haskell
renderRCValue s (RVRecMember _ _ _) = Right (Tx.pack "<closure>")
-- renderNode for NGroupCode/NEnv: not user-observable; render as "<closure>"/"<env>"
renderNode _ (NGroupCode _) = Right (Tx.pack "<closure>")
renderNode _ (NEnv _)       = Right (Tx.pack "<env>")
```

Confirm `incref`/`dropAddr` operate via addresses already; add a helper so a *value*-level dup/drop uses `valueChildren` (used by the dup/drop prims in Task 3).

- [ ] **Step 5: Run tests + full suite**

Run: `<RUNNER> -p "/rvrecmember-rep/"` → Expected: PASS.
Run: `<RUNNER>` → Expected: full suite green (new variants unused, no behavior change).

- [ ] **Step 6: Commit**

```bash
git add src/Wok/Interp/RC/Value.hs test/Spec.hs
git commit -m "feat(rc): add RVRecMember/NEnv/NGroupCode + valueChildren (representation only)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Evaluate `letrec` via shared env + code pointer

**Goal:** Make `evalExprRC (LetRec …)` install the group code as a static cell, allocate one shared env `E` (or use the sentinel when capture-free), bind members as inline `RVRecMember`, and make `enterRC` handle `RVRecMember` by reconstructing the sibling scope and entering the member's code (borrow, no consume, no allocation). The boundary guard still rejects escaping shapes, so only non-escaping `letrec` exercises this path.

**Files:**
- Modify: `src/Wok/Interp/RC/Machine.hs` — `evalExprRC` `LetRec` branch (replace the `allocLetRecGroup`/knot construction, ~lines 95–127); `enterRC` (+`RVRecMember` case).
- Test: `test/Spec.hs` — non-escaping mutually-recursive group runs sound under the new representation (below).

**Acceptance Criteria:**
- [ ] A non-escaping mutually-recursive group computes the same value as the reference interpreter and is heap-balanced.
- [ ] A capture-free recursive group allocates **zero** dynamic group cells (no `E`, members inline).
- [ ] A capturing group allocates exactly one `E` cell, freed once at scope exit.
- [ ] Sibling calls allocate nothing (inline reconstruction).
- [ ] Existing non-escaping `letrec` corpus green under the new representation.

**Verify:** `<RUNNER> -p "/sharedenv-eval/"` passes; full non-escaping `letrec` corpus green.

**Steps:**

- [ ] **Step 1: Write failing eval tests**

Add (`testGroup "sharedenv-eval"`): a two-member mutually-recursive group called locally (non-escaping), asserting value-match + heap-balance, plus a capture-free variant asserting zero group allocation.

```haskell
-- main = letrec even n = case n of 0 -> 1 ; _ -> odd  (n-1)
--               odd  n = case n of 0 -> 0 ; _ -> even (n-1)
--        in even 4         -- non-escaping; capture-free
sharedEnvMutualBalanced :: Assertion
sharedEnvMutualBalanced = do
  let cm = mutualEvenOdd 4          -- helper builds the ANF above (see below)
      pruned = pruneToReachable cm
  assertBool "accepted" (null (firstOrderNoHandlerViolations pruned))
  case (Interp.runModule pruned, RCM.runModuleRC (Perceus.insertRC pruned)) of
    (Right v, Right run) -> do
      assertEqual "value" (Interp.renderValue v) (RCM.rcOutput run)
      assertEqual "heap empty" (St.stLive (RCM.rcStats run)) (RCM.rcBaseline run)
      -- capture-free => zero dynamic group allocation beyond literals/case cells
      -- (assert no NEnv allocated: peak excludes a shared-env cell)
    other -> assertFailure (show other)
```

Provide `mutualEvenOdd :: Integer -> CoreModule` in the test module, building the two-member `LetRec` directly in ANF (mirroring `genMutualGroup` in Suite G but with literal base cases and no capture).

- [ ] **Step 2: Run to confirm failure**

Run: `<RUNNER> -p "/sharedenv-eval/"`
Expected: FAIL — current `LetRec` eval still builds the knot (`allocLetRecGroup`); the new-representation assertions (zero `E` for capture-free) fail, or the build still references region cells.

- [ ] **Step 3: Rewrite `evalExprRC (LetRec defs body)`**

```haskell
  LetRec defs body ->
    let -- 1. install group code as a static immortal cell (code pointer)
        (gAddr, sg) = allocStatic (NGroupCode defs) s
        groupU = Set.fromList [ binderUnique b | (b,_,_) <- defs ]
        -- 2. captured-local union (free vars of any member minus params/group binders)
        caps = Set.unions
                 [ (freeVarsExpr bdy `Set.difference`
                     Set.fromList (map binderUnique ps)) `Set.difference` groupU
                 | (_, ps, bdy) <- defs ]
        capList = Set.toList caps
        -- 3. shared env E (or sentinel if capture-free)
        (envAddr, sEnv)
          | null capList = (emptyEnvSentinel, sg)         -- static, no alloc
          | otherwise    =
              let fields = Map.fromList
                    [ (u, v) | u <- capList, Just v <- [Map.lookup u (rscEnv sc)] ]
              in alloc (NEnv fields) sg
        -- 4. bind each member to an inline RVRecMember
        groupEnv = foldl' (\e ((b,_,_), i) ->
                             bindRCBinder b (RVRecMember gAddr i envAddr) e)
                          (rscEnv sc) (zip defs [0 ..])
    in Right (REval body sc { rscEnv = groupEnv } k sEnv)
```

- [ ] **Step 4: Add the `RVRecMember` case to `enterRC`**

```haskell
enterRC prims fv args k s = case fv of
  RVRecMember gAddr i envAddr -> do
    gc <- deref gAddr s
    case cNode gc of
      NGroupCode defs -> do
        let (_, ps, body) = defs !! i
            np = length ps; na = length args
            -- env fields (borrowed: read, not increfed)
            envFields = case deref envAddr s of
                          Right c | NEnv m <- cNode c -> m
                          _                           -> Map.empty
            -- siblings reconstructed inline (no allocation), borrowed
            sibs = Map.fromList
                     [ (binderUnique b, RVRecMember gAddr j envAddr)
                     | ((b,_,_), j) <- zip defs [0 ..] ]
            callEnv extra = Map.unions [ Map.fromList (zip (map binderUnique ps) extra)
                                       , sibs, envFields ]
        case compare na np of
          EQ -> Right (REval body (RCScope (callEnv args) Map.empty) k s)   -- BORROW
          GT -> let (use, over) = splitAt np args
                in Right (REval body (RCScope (callEnv use) Map.empty)
                            (KAppRC over k) s)
          LT -> -- partial app: ordinary closure capturing the RVRecMember + args
                let cl = mkClosure (Map.fromList ((binderUnique memberSelf, fv)
                                                   : zip (map binderUnique (take na ps)) args))
                                   (drop na ps) body s
                    (a', s') = alloc cl s
                in Right (RReturn (RVBox a') k s')
      _ -> Left (NotAFunction (Tx.pack "group code addr is not NGroupCode"))
  RVBox addr -> {- existing NClosure path from Task 1 -}
  RVLit _    -> Left (NotAFunction (Tx.pack "applied a literal"))
```

(The `LT` partial-application body is refined during TDD so the captured `RVRecMember` is re-applied correctly; `memberSelf` is a fresh binder naming `fv` in the partial closure. This is the named verification corner from the spec; the partial-app test in Task 5 pins it.)

- [ ] **Step 5: Run the eval tests + non-escaping corpus**

Run: `<RUNNER> -p "/sharedenv-eval/"` → Expected: PASS (value-match, heap empty, zero `E` for capture-free).
Run: `<RUNNER> -p "/letrec/"` (existing non-escaping `letrec` corpus) → Expected: green.

- [ ] **Step 6: Commit**

```bash
git add src/Wok/Interp/RC/Machine.hs test/Spec.hs
git commit -m "feat(rc): evaluate letrec via shared env + code pointer (RVRecMember)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Simplify the Perceus `LetRec` instrumentation

**Goal:** Make Perceus treat a `letrec` group as one synthetic owned value `E` (born `rc=1`, dropped at the body's last use) with captures borrowed into member bodies (dup-on-consume), and members as ordinary borrowed/owned values. Remove the region special-casing and the multiset capture accounting (`capOcc`/capture `dups`) and the region `ctxExempt` for the new path. Boundary guard still rejects escaping shapes, so coverage stays within non-escaping `letrec`.

**Files:**
- Modify: `src/Wok/IR/Perceus.hs` — `ownExpr (LetRec …)` (~lines 643–711): drop `groupBoxed`/region handling; treat `E` as a synthetic owned binding with a last-use drop; bind captures as borrowed-with-dup-on-consume; member references ordinary (call-head borrow from Task 1, escaping occurrence = move+dup).
- Modify: `src/Wok/IR/Perceus.hs` — `coveredExpr`/`coveredRhsIn` `LetRec` cases (~263–318): the new representation is always covered (it is ordinary acyclic RC); simplify to remove `capturesRegion`/`region` threading for the non-effect fragment.
- Test: `test/Spec.hs` — non-escaping capturing group is `balanceLint`-clean and heap-balanced.

**Acceptance Criteria:**
- [ ] A non-escaping group that *borrows* an enclosing capture is `balanceLint`-clean and heap-balanced (capture freed exactly once with `E`).
- [ ] No per-member multiset dups are emitted (a capture shared by k members is held once in `E`).
- [ ] `prop_m2a1LintClean` stays green on the non-escaping generator.

**Verify:** `<RUNNER> -p "/sharedenv-pass/"` passes; `<RUNNER> -p "/Suite G/"` (non-escaping subset) green.

**Steps:**

- [ ] **Step 1: Write failing pass test**

```haskell
-- main = let c = Box(42)
--        letrec f n = case n of 0 -> caseRead c ; _ -> g (n-1)
--               g n = case n of 0 -> caseRead c ; _ -> f (n-1)
--        in let r = f 3 in r        -- non-escaping; both members BORROW-read c
sharedEnvCaptureBorrowBalanced :: Assertion
sharedEnvCaptureBorrowBalanced = do
  let cm = mutualBorrowCapture 3            -- helper builds the ANF above
      pruned = pruneToReachable cm
  assertBool "accepted" (null (firstOrderNoHandlerViolations pruned))
  assertEqual "lint clean" [] (Perceus.balanceLint pruned)
  case (Interp.runModule pruned, RCM.runModuleRC (Perceus.insertRC pruned)) of
    (Right v, Right run) -> do
      assertEqual "value" (Interp.renderValue v) (RCM.rcOutput run)
      assertEqual "heap empty" (St.stLive (RCM.rcStats run)) (RCM.rcBaseline run)
    other -> assertFailure (show other)
```

`mutualBorrowCapture` builds a two-member group where each base case reads `c` as a `Case` scrutinee keeping no boxed child (a borrow-read), `c` a boxed `Box(42)` enclosing local; the group is called and the result is a scalar.

- [ ] **Step 2: Run to confirm failure**

Run: `<RUNNER> -p "/sharedenv-pass/"`
Expected: FAIL — the current pass emits the region multiset `dups`/`groupBoxed` drops keyed on the old representation, so accounting against the new single-`E` runtime is unbalanced (double-free or leak in `runModuleRC`, or non-empty `balanceLint`).

- [ ] **Step 3: Rewrite `ownExpr (LetRec defs body)`**

```haskell
ownExpr ctx sup delta (LetRec defs body) =
  let groupU  = Set.fromList [ binderUnique b | (b,_,_) <- defs ]
      env     = ctxEnv ctx
      -- captured enclosing locals (boxed, in delta) = E's fields, owned by E
      caps    = Set.unions
                  [ (freeVarsExpr bdy `Set.difference` Set.fromList (map binderUnique ps))
                      `Set.difference` groupU
                  | (_, ps, bdy) <- defs ]
      boxedCaps = Set.fromList
                    [ u | u <- Set.toList (caps `Set.intersection` delta)
                        , Just b <- [Map.lookup u env], boxedBinder b ]
      laterBody = freeVarsExpr body
      -- E owns each captured local ONCE (no per-member multiset). A capture that
      -- also survives into the body needs one dup; otherwise it is moved into E.
      dupPlan   = [ (u, 1) | u <- Set.toList boxedCaps, u `Set.member` laterBody ]
      consumed  = Set.filter (`Set.notMember` laterBody) boxedCaps
      -- members are ordinary values bound in the body; their call-head uses are
      -- borrows (Task 1), escaping uses are moves; captures are borrowed into the
      -- member bodies (dup-on-consume) via dCtx's borrowed set.
      onDef sp (b, ps, dbody) =
        let dEnv = Map.fromList [ (binderUnique p, p) | p <- ps ]
                     `Map.union` Map.fromList [ (binderUnique g, g) | (g,_,_) <- defs ]
                     `Map.union` env
            -- BORROWED into the member body: siblings + E's captured fields.
            -- 'ctxBorrow' marks them read-only-with-dup-on-consume (NOT fully exempt):
            -- a consuming use emits a dup at that use (per-execution), the #1 fix.
            dCtx = (Ctx dEnv Map.empty Set.empty)
                     { ctxBorrow = groupU `Set.union` boxedCaps }
            dDelta = Set.fromList [ binderUnique p | p <- ps, boxedBinder p ]
            (sp', dbody') = ownExpr dCtx sp dDelta dbody
        in (sp', (b, ps, dbody'))
      (sup1, defs') = mapAccumLPairs onDef sup defs
      -- E is a synthetic owned value: born at LetRec, dropped at body's last use.
      -- Model it as an owned binder 'eU' added to the body delta; the standard
      -- last-use machinery drops it (its drop lowers to dropAddr on E at runtime).
      bodyDelta = (delta `Set.difference` consumed) `Set.union` Set.singleton syntheticEnvUnique
      (sup2, body') = ownExpr ctx sup1 bodyDelta body
      (sup3, dups)  = mkDupsForVars sup2 env dupPlan
  in (sup3, foldr ($) (LetRec defs' body') dups)
```

Introduce `ctxBorrow` in `Ctx` (the borrowed-with-dup-on-consume set) replacing the old `ctxExempt` semantics for captures/siblings: an occurrence of a `ctxBorrow` var in a *consuming* position emits a dup (reusing the existing dup machinery), in a *borrow* position (call head, borrow-read scrutinee) emits nothing, and it is never dropped inside the member body. Wire the synthetic `E` drop (`syntheticEnvUnique`) so the instrumented IR carries a `__rc_drop` that the runtime maps to `dropAddr envAddr` — coordinate the exact lowering with Task 3 (the simplest scheme: the pass emits no explicit `E` drop and the runtime drops `E` when the last member binding in scope is dropped; choose ONE owner and document it). The `sharedEnvCaptureBorrowBalanced` test and `balanceLint` pin correctness.

- [ ] **Step 4: Simplify `coveredExpr`/`coveredRhsIn` for `LetRec`**

The new representation is ordinary acyclic RC, so a `LetRec` whose bodies are covered is covered (drop the `capturesRegion`/`region` threading; keep only the effect-fragment checks). Update `coveredExpr (LetRec …)` to recurse into member bodies and the body without region bookkeeping.

- [ ] **Step 5: Run pass test + non-escaping Suite G subset**

Run: `<RUNNER> -p "/sharedenv-pass/"` → Expected: PASS.
Run: `<RUNNER> -p "/Suite G/"` → Expected: the non-escaping (ACCEPT) generated programs are lint-clean + heap-balanced; escaping ones are still REJECTED by the boundary (unchanged this task).

- [ ] **Step 6: Commit**

```bash
git add src/Wok/IR/Perceus.hs test/Spec.hs
git commit -m "feat(rc): Perceus letrec as one owned shared-env + borrowed captures (dup-on-consume)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Take down the #2/#3/#4 escape guards; Suite G runs the escaping shapes

**Goal:** Remove `escapeViol`, `crossRegionViol`, and `siblingEscapeViol` from the boundary guard, and extend Suite G to *generate and run* the now-admitted escaping shapes as ACCEPT-and-must-run-sound. `consumeViol` (#1) stays for now (Task 6).

**Files:**
- Modify: `src/Wok/IR/Reachable.hs` — `exprScopeFeaturesWith`: delete the `siblingEscapeViol` (the `Let` clause), `escapeViol` and `crossRegionViol` (the `LetRec` clause); keep `consumeViol` and the `Handle`/`ROp` rejections.
- Modify: `test/Spec.hs` — Suite G generator: flip the escaping variants from REJECT-expected to ACCEPT-and-run-sound; add cross-region (escaping + non-escaping), mutually-recursive escaping, conditional escape, and multi-escape shapes.
- Test: `test/Spec.hs` — `prop_m2a1Escape` now runs the escaping programs.

**Acceptance Criteria:**
- [ ] Every Suite G escaping shape (returned / con / record / list / nested-closure / alias / cross-region / mutual-escaping / conditional / multi-escape) is boundary-ACCEPTED, runs via `runModuleRCUnchecked (insertRC (pruneToReachable cm))`, is heap-balanced, and matches the reference interpreter.
- [ ] The former reproducers (the `mk u = let f … in let h = \m -> f(m+1) in 0` escape; the nested-letrec cross-region) now pass.
- [ ] `prop_m2a1Teeth` fault-injection catches single-site mutations on the new shapes.
- [ ] Full suite green.

**Verify:** `<RUNNER> -p "/Suite G/"` passes including escaping shapes; full suite green.

**Steps:**

- [ ] **Step 1: Extend Suite G to generate escaping shapes as ACCEPT-and-run-sound**

In `test/Spec.hs`, the existing `closureFlowBody` already emits `FlowReturn`/`FlowCon`/`FlowRecord`/`FlowList`/`FlowNestedClosure`. Change `prop_m2a1Escape` so that for these flows the program is **expected ACCEPTED** and is asserted heap-balanced + value-matching (today they are expected REJECTED). Add generators for cross-region (an inner group capturing an outer member that escapes), a mutually-recursive escaping group (the knot-stays-acyclic check), conditional escape (`Case` with one escaping arm), and multi-escape (`Pair(f, f)`). Reuse `genMutualGroup`/`genSiblingGroup`.

```haskell
-- prop_m2a1Escape (revised core): accepted ⟹ sound; AND the escaping shapes are
-- now expected to be accepted (no longer skipped).
prop_m2a1Escape =
  forAllShrink genM2a2Program shrinkProgram $ \cm0 ->
    let cm = pruneToReachable cm0
        accepted = null (firstOrderNoHandlerViolations cm)
    in counterexample (report cm accepted) $
         if not accepted
           then property True
           else case (Interp.runModule cm, RCM.runModuleRCUnchecked (Perceus.insertRC cm)) of
                  (Right v, Right run) ->
                    Interp.renderValue v == RCM.rcOutput run
                      && St.stLive (RCM.rcStats run) == RCM.rcBaseline run
                      && St.stAllocs (RCM.rcStats run) - St.stFrees (RCM.rcStats run)
                           == RCM.rcBaseline run
                  (Left _, Left _) -> True
                  _ -> False
```

- [ ] **Step 2: Run to confirm failure (guards still reject)**

Run: `<RUNNER> -p "/Suite G/"`
Expected: FAIL — escaping shapes are still REJECTED by the boundary (`escapeViol`/`crossRegionViol`/`siblingEscapeViol`), so `accepted == False` where the revised property expects acceptance, or the run assertions never execute.

- [ ] **Step 3: Remove the three escape guards from `Reachable`**

In `src/Wok/IR/Reachable.hs`, `exprScopeFeaturesWith`:
- delete the `siblingEscapeViol` branch in the `Let` case (and the `rhsCapturesSibling`/`rlamSiblingCaptureEscapes` usage there);
- delete `escapeViol` and `crossRegionViol` in the `LetRec` case;
- keep `consumeViol` (Task 6) and the `Handle`/`ROp` rejections.

```haskell
      Anf.LetRec defs body ->
        let lr' = Set.union lr (Set.fromList [ Anf.binderUnique b | (b,_,_) <- defs ])
            consumeViol
              | letRecMemberConsumesCapture defs bsc =
                  [Tx.pack "LetRec member consumes (moves) an enclosing capture; \
                           \only borrowed reads are supported (M2a-2 Task 6 gate)"]
              | otherwise = []
        in consumeViol
             ++ concat [ go lr' bsc d | (_,_,d) <- defs ]
             ++ go lr' bsc body
      Anf.Let b r body ->
        let bsc' = if isBoxedType (Anf.bndType b)
                     then Set.insert (Anf.binderUnique b) bsc else bsc
        in rhs lr bsc r ++ go lr bsc' body      -- no siblingEscapeViol
```

- [ ] **Step 4: Run Suite G + full suite**

Run: `<RUNNER> -p "/Suite G/"` → Expected: PASS — escaping shapes accepted, run sound, heap-balanced, value-matching; teeth catch mutations.
Run: `<RUNNER>` → Expected: full suite green.

- [ ] **Step 5: Add the carried-forward reproducers as explicit cases**

Add the M1.5/M2a-1 reproducers (the drop-without-call closure escape; the nested-letrec cross-region leak) as named `testCase`s asserting ACCEPT + heap-balanced, so each removed guard ships with its former exploit now passing.

- [ ] **Step 6: Commit**

```bash
git add src/Wok/IR/Reachable.hs test/Spec.hs
git commit -m "feat(rc): admit escaping recursive-group shapes (#2/#3/#4); Suite G runs them

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: #1 consuming-capture gate — verify, then remove `consumeViol`

**Goal:** Verify that consuming captures are sound under borrow-from-`E` + dup-on-consume (the former unsound corpus runs heap-balanced), then remove `consumeViol`. If verification fails, stop and keep `consumeViol` (the slice still ships #2/#3/#4).

**Files:**
- Modify: `test/Spec.hs` — Suite G generator: emit consuming-capture shapes (single + two-member, both base cases consume) as ACCEPT-and-run-sound; convert `rcM2a1ConsumeCaptureRejected` into `rcM2a2ConsumeCaptureSound` (heap-balanced).
- Modify: `src/Wok/IR/Reachable.hs` — remove `consumeViol` (only after the gate passes).
- Modify: `src/Wok/IR/Escape.hs` — `letRecMemberConsumesCapture`/`consumingOccs` may be retired or repurposed (the pass now dups-on-consume rather than rejecting); keep `escapingAtoms`/`nonHeadOccs` (still used for owned-vs-borrow occurrence classification).

**Acceptance Criteria:**
- [ ] The two-member-both-base-cases-consume counterexample (`test/rc-m2a1/33` analogue) runs heap-balanced under `runModuleRCUnchecked`, matching the reference interpreter, for several recursion depths.
- [ ] `consumeViol` removed; consuming-capture programs are boundary-ACCEPTED and run sound.
- [ ] If the gate fails, `consumeViol` is retained and this task is marked blocked with the failing reproducer recorded (the slice still ships #2/#3/#4).

**Verify:** `<RUNNER> -p "/consuming-capture/"` passes (sound, heap-balanced).

**Steps:**

- [ ] **Step 1: Write the consuming-capture soundness test (the M2a-1 counterexample)**

Convert the existing `rcM2a1ConsumeCaptureRejected` into a soundness assertion. Build the two-member group where both base cases MOVE `cap` into a `Box` and destructure it, the recursion terminating in one base case, and assert heap-balance under `runModuleRCUnchecked` for depths 0..4:

```haskell
rcM2a2ConsumeCaptureSound :: Assertion
rcM2a2ConsumeCaptureSound =
  mapM_ check [0,1,2,3,4]
  where
    check depth = do
      let cm = twoMemberConsumingGroup depth     -- the rc-m2a1/33 two-member analogue
          pruned = pruneToReachable cm
      assertBool ("accepted d=" <> show depth) (null (firstOrderNoHandlerViolations pruned))
      case (Interp.runModule pruned, RCM.runModuleRCUnchecked (Perceus.insertRC pruned)) of
        (Right v, Right run) -> do
          assertEqual ("value d=" <> show depth) (Interp.renderValue v) (RCM.rcOutput run)
          assertEqual ("heap empty d=" <> show depth)
            (St.stLive (RCM.rcStats run)) (RCM.rcBaseline run)
          assertEqual ("balanced d=" <> show depth)
            (St.stAllocs (RCM.rcStats run) - St.stFrees (RCM.rcStats run))
            (RCM.rcBaseline run)
        other -> assertFailure ("d=" <> show depth <> ": " <> show other)
```

Provide `twoMemberConsumingGroup :: Integer -> CoreModule` (lift the body already hand-built in `rcM2a1ConsumeCaptureRejected`).

- [ ] **Step 2: Run the gate WITH `consumeViol` still in place (expect REJECT, so run-via-Unchecked)**

Run: `<RUNNER> -p "/consuming-capture/"`
Expected: with `consumeViol` present the program is still boundary-REJECTED, so the `assertBool "accepted"` line fails — *but* the `runModuleRCUnchecked` heap-balance lines exercise the pass+runtime directly (bypassing the guard). If those balance lines PASS for all depths, the mechanism is verified and we may remove the guard (Step 3). If any balance line FAILS, STOP: the #1 mechanism is unsound as built; keep `consumeViol`, record the failing depth, and mark the task blocked.

- [ ] **Step 3: Remove `consumeViol` (only if Step 2's balance lines passed)**

In `src/Wok/IR/Reachable.hs`, delete the `consumeViol` branch in the `LetRec` case. Now consuming-capture programs are accepted.

- [ ] **Step 4: Re-run the gate (expect full PASS)**

Run: `<RUNNER> -p "/consuming-capture/"` → Expected: PASS (accepted + heap-balanced + value-matching at all depths).
Run: `<RUNNER>` → Expected: full suite green.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/IR/Reachable.hs src/Wok/IR/Escape.hs test/Spec.hs
git commit -m "feat(rc): admit #1 consuming captures via borrow-from-E + dup-on-consume

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Retire region machinery; regenerate Suite B goldens

**Goal:** Delete the now-dead uncounted-region apparatus and the per-member multiset/borrowed-capture closure machinery, regenerate the Suite B allocation goldens for the new representation, and leave the tree hlint-clean and fully green.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` — remove `allocLetRecGroup`, `writeRegionCell`, `regionPlaceholder`, `stRegionOf`, `stNextRegion`, `isRegionAddr`, the region branch of `isBorrowedAddr`/`countedChildren`, `mkClosure`'s borrowed-set / `closureBorrowed` / `closureOwnedBoxed` (if unused after Task 1's partial-app path is simplified). `countedChildren` becomes "skip static, recurse otherwise".
- Modify: `src/Wok/IR/Perceus.hs` — remove `capOcc`/capture `dups`, the region `ctxExempt`, and any `region`-threading left in `coveredExpr`.
- Modify: `src/Wok/IR/Escape.hs` — remove predicates no longer referenced (`letRecEnclosingCaptureEscapes`, `rlamSiblingCaptureEscapes`, `letRecMemberEscapes`, `rawEnclosingFv`, `letRecMemberConsumesCapture`, `consumingOccs`) once all call sites are gone; keep `escapingAtomsRhs`/`nonHeadOccs`/`isBoxedType` if still used.
- Modify: Suite B golden files (regenerate).

**Acceptance Criteria:**
- [ ] No references remain to the removed region symbols (build + `hlint` clean, ignoring `src-generated`).
- [ ] `countedChildren` skips static only; no region logic remains.
- [ ] Suite B goldens regenerated for the new representation and each diff reviewed for plausibility (capture-free groups show fewer allocs; capturing groups show one `E` cell).
- [ ] Full suite green.

**Verify:** `<RUNNER>` full suite green; `hlint src/ --ignore-glob=src-generated` clean.

**Steps:**

- [ ] **Step 1: Delete dead region code**

Remove the symbols listed above from `Value.hs`/`Perceus.hs`/`Escape.hs`. Simplify `countedChildren`:

```haskell
countedChildren :: Addr -> Node -> Store -> [Addr]
countedChildren _parent n _s = filter (not . isStaticAddr) (boxedChildren n)
```

Remove `stRegionOf`/`stNextRegion` from `Store` and `emptyStore`.

- [ ] **Step 2: Build and fix all references**

Run: `<RUNNER>` (build) → Expected: compile errors at each dead-symbol reference; fix each (they should all be in code paths replaced by Tasks 1–6). Iterate until it builds.

- [ ] **Step 3: Regenerate Suite B goldens**

Run the Suite B golden-update mechanism (the `--dump-rc-stats` CLI / tasty `--accept`). For each regenerated golden, confirm the new numbers are plausible: capture-free recursive groups drop to zero group allocations; capturing groups allocate one `NEnv`. Review every diff; do not blanket-accept.

- [ ] **Step 4: hlint + full suite**

Run: `hlint src/ --ignore-glob=src-generated` → Expected: clean (no new warnings).
Run: `<RUNNER>` → Expected: full suite green.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/Interp/RC/Value.hs src/Wok/IR/Perceus.hs src/Wok/IR/Escape.hs test/ <goldens>
git commit -m "refactor(rc): retire uncounted-region machinery; regenerate Suite B goldens

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Spec §3.1 (RVRecMember/valueChildren) → Task 2. §3.2 (NGroupCode), §3.3 (NEnv, sentinel), §3.4 (LetRec eval) → Tasks 2–3. §3.5 (uniform borrow-on-call, sibling resolution) → Tasks 1, 3. §3.6 (escape = ordinary move, no wrapper) → Tasks 1, 5. §3.7 (E lifecycle, #1 mechanism) → Tasks 4, 6. §3.8 (retire) → Task 7. §4 (pass) → Tasks 1, 4. §5 (boundary guard) → Tasks 5, 6. §6 (soundness/bisimulation) → exercised by the Suite G heap-balance+differential properties in Tasks 5–6. §8 (verification plan) → Tasks 5–7. Decisions D1 (Task 1), D2 (Task 6), D3 (Task 3, per-eval install accepted). No spec section is unmapped.

**Placeholder scan:** the partial-application `LT` body in Task 3 and the synthetic-`E`-drop lowering in Task 4 are flagged as TDD-refined verification corners with the exact test that pins them, not vague placeholders. The `mutualEvenOdd`/`mutualBorrowCapture`/`twoMemberConsumingGroup` helpers are specified by their ANF shape (and the corpus they lift from). No "TBD/add error handling/similar to Task N" left.

**Type consistency:** `RVRecMember Addr Int Addr`, `valueChildren`, `NEnv`, `NGroupCode` are named identically across Tasks 2/3/7. `firstOrderNoHandlerViolations`, `runModuleRC`, `runModuleRCUnchecked`, `rcStats`/`rcOutput`/`rcBaseline`, `stLive`/`stAllocs`/`stFrees`, `balanceLint`, `insertRC`, `pruneToReachable` match the symbols read from the current source. `ctxBorrow` (Task 4) is a new `Ctx` field introduced once and used consistently.

**Risk notes carried into tasks:** Task 1 is the highest-risk (convention change, may shift Suite B peak) and is isolated first; Task 6 is a hard gate that can fail-safe (keep `consumeViol`, still ship #2/#3/#4).
