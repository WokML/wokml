# Conc Handle Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the cross-scheduler handle id collision in the Conc layer (silent wrong values through three doors: nested `runConc`, sequential escape, CAF escape) by making every handle id globally unique and turning foreign-handle use into a clean runtime error.

**Architecture:** A fresh-id supply (`IdSupply = Integer`) threads through the interpreter's `step`/`enter`/`run` alongside `Config`; `driveConc` seeds its `schNextId` from it and returns the consumed amount, so nested drives mint disjoint ids. Lazy CAF forcing runs in separate `run` calls the supply cannot reach, so each interpreter entry (main + each zero-arity bind) seeds from a disjoint region: `id = region(16 bits) | counter(48 bits)`. Validation is the existing per-scheduler map lookup: a miss now means "not minted by this scheduler" and errors. Spec: `docs/superpowers/specs/2026-06-13-conc-handle-identity-design.md`.

**Tech Stack:** Haskell (GHC, cabal), tasty-golden test suite (`cabal test`, `--test-options=--accept` to regenerate goldens), wok fixtures under `test/run-examples/` + `test/run-golden/`.

**Branch:** all work on `fix/conc-handle-identity` off `main`. Full-branch review required before merge (project rule).

**Verification protocol (spec section 7):** the negative fixtures are committed FIRST with goldens that record today's silent wrong values (run-the-exploit evidence, in history); the fix tasks then flip those goldens to errors. A fix task is correct only if the goldens it flips match the predictions written in that task.

---

### Task 1: Exploit fixtures with before-goldens

**Goal:** Six run-example fixtures that document the bug as it exists today (five silent wrong values, one already-working nesting case), committed green.

**Files:**
- Create: `test/run-examples/conc-foreign-nested-await.wok`
- Create: `test/run-examples/conc-foreign-nested-chan.wok`
- Create: `test/run-examples/conc-foreign-sequential-await.wok`
- Create: `test/run-examples/conc-foreign-inner-escape.wok`
- Create: `test/run-examples/conc-foreign-caf-escape.wok`
- Create: `test/run-examples/conc-nested-own-handles.wok`
- Create (via `--accept`, then inspect): the six matching `test/run-golden/*.expected`

**Acceptance Criteria:**
- [ ] All six fixtures typecheck and run; suite is green at 809 (803 + 6)
- [ ] Before-goldens are exactly: `99`, `7`, `7`, `42`, `7`, `49` (in the file order above) — each a documented WRONG value except the last
- [ ] Each fixture's header comment names the door it exercises and the expected post-fix behavior

**Verify:** `cabal test --test-options='-p conc-'` then full `cabal test` → all pass

**Steps:**

- [ ] **Step 1: Branch**

```bash
git checkout -b fix/conc-handle-identity
```

- [ ] **Step 2: Write the six fixtures**

Note on style: helpers carry explicit `with Conc` signatures because a pure
lambda's closed row does not unify with `Conc` under the strict unifier (same
pattern as `test/run-examples/conc-async-await.wok`). Multi-line `let ... in`
layout follows `prelude/Std/Control.wok` (`raceAny`); if the parser rejects a
line break, join that `let`-chain onto one line — do not otherwise restructure.

`test/run-examples/conc-foreign-nested-await.wok`:

```
module Main
import Std.Base
import Std.Control

-- Door 1 (nested runConc): an OUTER promise awaited under an INNER runConc.
-- Today the inner scheduler silently serves its own same-numbered cell and
-- this program returns 99 (the wrong promise's value). After the handle
-- identity fix it is a runtime error: the handle is not owned by the inner
-- scheduler. Spec: 2026-06-13-conc-handle-identity-design.md section 1.

outerVal : () -> U64 with Conc
outerVal u = 42

innerVal : () -> U64 with Conc
innerVal u = 99

main : U64
main = runConc (\ () ->
  let p = async outerVal in
  runConc (\ () ->
    let q = async innerVal in
    await p))
```

`test/run-examples/conc-foreign-nested-chan.wok`:

```
module Main
import Std.Base
import Std.Control

-- Door 1, channel arm: a send on an OUTER channel under an INNER runConc is
-- silently delivered to the inner scheduler's same-numbered channel, so the
-- recv on the unrelated inner channel returns 7 (cross-delivery). After the
-- fix the send is a runtime error (channel not owned by this scheduler).

main : U64
main = runConc (\ () ->
  let ch = newChan () in
  runConc (\ () ->
    let ch2 = newChan () in
    let ignored = send ch 7 in
    recv ch2))
```

(Plan correction from Task 1 execution: `_` is not a valid wok let-binder —
parse error — so the discard binding is named `ignored`.)

`test/run-examples/conc-foreign-sequential-await.wok`:

```
module Main
import Std.Base
import Std.Control

-- Door 2 (sequential escape, NO nesting): a promise returned out of one
-- runConc and awaited inside a later sibling that has minted its own
-- same-numbered promise. Today this silently returns the sibling's 7 instead
-- of 42. After the fix it is a runtime error.

fortyTwo : () -> U64 with Conc
fortyTwo u = 42

seven : () -> U64 with Conc
seven u = 7

main : U64
main =
  let p = runConc (\ () -> async fortyTwo) in
  runConc (\ () -> let q = async seven in await p)
```

`test/run-examples/conc-foreign-inner-escape.wok`:

```
module Main
import Std.Base
import Std.Control

-- Door 1, symmetric direction: an INNER runConc's promise escapes as its
-- result and is awaited by the OUTER scheduler, which has minted its own
-- same-numbered promise. Today this silently returns the outer 42 instead of
-- the inner task's 7. After the fix it is a runtime error.

fortyTwo : () -> U64 with Conc
fortyTwo u = 42

seven : () -> U64 with Conc
seven u = 7

main : U64
main = runConc (\ () ->
  let p = async fortyTwo in
  let q = runConc (\ () -> async seven) in
  await q)
```

`test/run-examples/conc-foreign-caf-escape.wok`:

```
module Main
import Std.Base
import Std.Control

-- Door 3 (CAF escape): a top-level constant runs runConc in its own lazily
-- forced interpreter entry; its escaped promise collides with main's
-- scheduler. Today this silently returns 7 instead of 42. After the
-- per-entry region fix it is a runtime error.

fortyTwo : () -> U64 with Conc
fortyTwo u = 42

seven : () -> U64 with Conc
seven u = 7

top : Promise U64
top = runConc (\ () -> async fortyTwo)

main : U64
main = runConc (\ () -> let q = async seven in await top)
```

`test/run-examples/conc-nested-own-handles.wok`:

```
module Main
import Std.Base
import Std.Control

-- POSITIVE: nested runConc where each level uses only its own handles is
-- legitimate (a deterministic subworld) and must keep working, before and
-- after the handle identity fix. Locks "nesting is supported, not forbidden"
-- and (post-fix) that the id supply threads through a nested drive and back.

fortyTwo : () -> U64 with Conc
fortyTwo u = 42

seven : () -> U64 with Conc
seven u = 7

nested : () -> U64 with Conc
nested u =
  let a = async fortyTwo in
  let x = runConc (\ () -> let b = async seven in await b) in
  let r = await a in
  r + x

main : U64
main = runConc nested
```

- [ ] **Step 3: Generate goldens and verify they record the documented wrong values**

```bash
cabal test --test-options='--accept -p conc-'
for f in conc-foreign-nested-await conc-foreign-nested-chan conc-foreign-sequential-await conc-foreign-inner-escape conc-foreign-caf-escape conc-nested-own-handles; do echo "== $f"; cat test/run-golden/$f.expected; done
```

Expected output, in order: `99`, `7`, `7`, `42`, `7`, `49`.
Any other value (especially an error) means the exploit does not reproduce as
the spec describes — STOP and investigate before proceeding; do not accept a
golden you cannot explain.

- [ ] **Step 4: Full suite green**

Run: `cabal test`
Expected: all 809 pass.

- [ ] **Step 5: Commit**

```bash
git add test/run-examples/conc-*.wok test/run-golden/conc-*.expected
git commit -m "test(conc): exploit fixtures for cross-scheduler handle collision (before-goldens record the silent wrong values)"
```

---

### Task 2: Thread the id supply through the machine (no behavior change)

**Goal:** `IdSupply` threads through `step`/`enter`/`run` and through `driveConc`'s callbacks; every entry point seeds 0; observable behavior is byte-identical (suite green, goldens untouched).

**Files:**
- Modify: `src/Wok/Interp/Value.hs` (add `IdSupply`, `idRegionBound`)
- Modify: `src/Wok/Interp/Machine.hs` (thread supply; signatures of `step`/`transition`/`returnTo`/`evalExpr`/`evalRhs`/`enter`/`run`; entry points)
- Modify: `src/Wok/Interp/Sched.hs` (`Enter`/`Run` types, `driveConc` accepts and returns the supply; internal threading through `startCoro`/`resumeCoro`; scheduler still seeds 0 in this task)

**Acceptance Criteria:**
- [ ] `cabal build` clean (warnings as before)
- [ ] Full suite green at 809 with NO golden changes (`git status` shows no modified `.expected`)
- [ ] `runModule`/`evalExprWith` keep their external signatures (`Either RuntimeError Value`)

**Verify:** `cabal test` → 809 pass; `git diff --stat test/` → empty

**Steps:**

- [ ] **Step 1: Add the supply type to `src/Wok/Interp/Value.hs`**

Next to the `Config`/`Step` definitions (around line 121), add and export:

```haskell
-- | Program-wide fresh-id supply for Conc handle ids, threaded through the
-- machine so nested driveConc instances mint disjoint ids. Integer (not Word64)
-- to match LInt; ids stay below 2^64 via the per-entry region scheme.
type IdSupply = Integer

-- | Size of one interpreter-entry id region (main, each forced CAF). Handle
-- id = regionIndex * idRegionBound + localCounter. 16 region bits / 48
-- counter bits inside the wok-visible U64.
idRegionBound :: Integer
idRegionBound = 2 ^ (48 :: Int)
```

Add `IdSupply` and `idRegionBound` to the module export list.

- [ ] **Step 2: Thread the supply through `src/Wok/Interp/Machine.hs`**

New signatures (the supply rides beside the result; only `enter`'s `PRDrive`
arm will ever change it — in Task 3):

```haskell
step :: PrimTable -> IdSupply -> Config -> Either RuntimeError (Step, IdSupply)
step _     sup (Return v KDone) = Right (Done v, sup)
step prims sup cfg              = do
  (c, sup') <- transition prims sup cfg
  Right (More c, sup')

transition :: PrimTable -> IdSupply -> Config -> Either RuntimeError (Config, IdSupply)
transition prims sup (Return v k)      = returnTo prims sup v k
transition prims sup (Eval expr sc k)  = evalExpr prims sup expr sc k

returnTo :: PrimTable -> IdSupply -> Value -> Kont -> Either RuntimeError (Config, IdSupply)
```

`returnTo`: the `KApp` arm becomes `enter prims sup v args k`; the other three
arms keep their existing right-hand sides wrapped as `Right (<old Config>, sup)`
(`KDone` stays `Left`).

`evalExpr prims sup expr sc k`: the `Let` arm becomes
`evalRhs prims sup b rhs body sc k`; every other arm (`Ret`, `Case`, `LetRec`,
`LetJoin`, `Jump`, `Handle`) keeps its existing logic and wraps its final
`Right cfg` as `Right (cfg, sup)`. `matchAlts` and `dispatchOp` are NOT
threaded — they never reach `enter`; where `evalExpr`/`evalRhs` call them, bind
the `Config` and return `(cfg, sup)`:

```haskell
  Case a alts -> do
    v <- resolveAtom prims sc a
    cfg <- matchAlts v alts sc k
    Right (cfg, sup)
```

`evalRhs prims sup b rhs body sc k`: the `RApp` arm becomes
`enter prims sup fv vs (KLet b body sc k)`; the `ROp` arm binds
`cfg <- dispatchOp mTarget lbl op vs (KLet b body sc k)` and returns
`(cfg, sup)`; the local `cont v` helper returns `Right (Eval body ... k, sup)`.

`enter`:

```haskell
enter :: PrimTable -> IdSupply -> Value -> [Value] -> Kont -> Either RuntimeError (Config, IdSupply)
enter prims sup fv args k = case fv of
  -- VClosure arms: same Configs, paired with sup (the GT arm builds a KApp
  -- frame, it does not recurse into enter)
  VPrim p ->
    let combined = primArgs p ++ args in
    if length combined < primArity p
      then Right (Return (VPrim p { primArgs = combined }) k, sup)
      else let (use, over) = splitAt (primArity p) combined in do
        r <- primFn p use
        case r of
          PRDone v        -> if null over then Right (Return v k, sup) else enter prims sup v over k
          PRApply g gargs -> enter prims sup g (gargs ++ over) k
          PRDrive thunk   -> do
            (v, sup') <- Sched.driveConc enter run prims sup thunk
            if null over then Right (Return v k, sup') else enter prims sup' v over k
  -- VCont / VContP / NotAFunction arms: unchanged logic, paired with sup
```

`run`:

```haskell
run :: PrimTable -> IdSupply -> Config -> Either RuntimeError (Value, IdSupply)
run prims = loop
  where
    loop sup cfg = do
      (s, sup') <- step prims sup cfg
      case s of
        Done v -> Right (v, sup')
        More c -> loop sup' c
```

Entry points (all seed 0 in this task; Task 4 adds regions):

```haskell
evalExprWith :: Env -> Expr -> Either RuntimeError Value
evalExprWith env e = fst <$> run primTable 0 (Eval e (Scope env Map.empty) KDone)
```

In `runModule`: `forceTop body = case run primTable 0 (Eval body (Scope gEnv Map.empty) KDone) of Right (v, _) -> v; Left err -> throw (CafFailure err)` and the main case becomes `catchCaf (\() -> fst <$> run primTable 0 (Eval body (Scope gEnv Map.empty) KDone))`.

- [ ] **Step 3: Thread the supply through `src/Wok/Interp/Sched.hs`**

```haskell
type Enter = PrimTable -> IdSupply -> Value -> [Value] -> Kont -> Either RuntimeError (Config, IdSupply)
type Run   = PrimTable -> IdSupply -> Config -> Either RuntimeError (Value, IdSupply)

driveConc :: Enter -> Run -> PrimTable -> IdSupply -> Value -> Either RuntimeError (Value, IdSupply)
```

Import `IdSupply` from `Wok.Interp.Value`. Inside `driveConc`, `startCoro` and
`resumeCoro` take and return the supply:

```haskell
startCoro :: IdSupply -> Value -> Either RuntimeError (Value, IdSupply)
startCoro sup starter = do
  (cfg, sup1) <- enterF prims sup starter [VLit LUnit] KDone
  runF prims sup1 cfg

resumeCoro :: IdSupply -> Value -> Value -> Either RuntimeError (Value, IdSupply)
resumeCoro sup carrier resumeVal = do
  (cfg, sup1) <- enterF prims sup carrier [resumeVal] KDone
  runF prims sup1 cfg
```

In THIS task the machine supply and `schNextId` stay separate (Task 3 merges
them): carry the machine supply through `processStep` as an explicit pair.
Change `processStep` to
`processStep :: IdSupply -> Owner -> Value -> Sched -> Either RuntimeError (Sched, IdSupply)`;
the `ReqSpawn`/`ReqAsync` arms call `startCoro sup childStarter` and pass the
returned supply on; every arm that does not start a coro returns `(st', sup)`.
The main loop:

```haskell
driveConc enterF runF prims sup0 rootStarter = do
  (rootStep, sup1) <- startCoro sup0 rootStarter
  (st0, sup2) <- processStep sup1 Root rootStep (Sched 0 Seq.empty Map.empty Map.empty Nothing)
  loop sup2 st0
  where
    loop sup st = case schResult st of
      Just r  -> Right (r, sup)
      Nothing -> case Seq.viewl (schReady st) of
        EmptyL    -> {- existing deadlock / drained errors, unchanged -}
        (owner, resumeVal, carrier) :< rest -> do
          let st' = st { schReady = rest }
          (nextStep, supA) <- resumeCoro sup carrier resumeVal
          (st'', supB) <- processStep supA owner nextStep st'
          loop supB st''
```

`Sched` still seeds `schNextId = 0` — behavior identical to main.

- [ ] **Step 4: Check for other callers of the changed internals**

```bash
grep -rn "Machine.run\|Machine.enter\|Machine.step\b" src app test --include="*.hs" | grep -v "Wok/Interp/Machine.hs\|Wok/Interp/Sched.hs"
```

Expected: no hits (`runModule`/`evalExprWith` keep their signatures; `Sched`
receives `enter`/`run` by injection). Any hit must be updated to pass/discard
a supply seeded 0.

- [ ] **Step 5: Build and full suite**

Run: `cabal build && cabal test`
Expected: 809 pass, `git diff --stat test/` empty.

- [ ] **Step 6: Commit**

```bash
git add src/Wok/Interp/Value.hs src/Wok/Interp/Machine.hs src/Wok/Interp/Sched.hs
git commit -m "refactor(interp): thread an IdSupply through step/enter/run and driveConc (no behavior change)"
```

---

### Task 3: Globally unique handle ids + ownership errors (fixes doors 1 and 2)

**Goal:** `driveConc` seeds `schNextId` from the threaded supply and returns it; foreign handles error at the existing lookup-miss branches; fixtures 1-4 flip from wrong values to errors.

**Files:**
- Modify: `src/Wok/Interp/Sched.hs`
- Modify: `test/run-golden/conc-foreign-nested-await.expected`, `conc-foreign-nested-chan.expected`, `conc-foreign-sequential-await.expected`, `conc-foreign-inner-escape.expected` (via `--accept` + inspection)

**Acceptance Criteria:**
- [ ] Fixtures 1-4 now golden the predicted errors (exact texts in Step 3)
- [ ] `conc-foreign-caf-escape` STILL goldens `7` (door 3 is Task 4's job — confirm, do not "fix" it here)
- [ ] `conc-nested-own-handles` STILL goldens `49`, byte-identical
- [ ] All other goldens untouched; suite green at 809

**Verify:** `cabal test` → 809 pass; `git diff test/run-golden/` shows exactly the four predicted flips

**Steps:**

- [ ] **Step 1: Merge the counter — `schNextId` IS the supply**

In `driveConc`, seed the scheduler from the incoming supply and drop the
separate supply thread added in Task 2 (the pair-threading through
`processStep` collapses back into `Sched`):

```haskell
driveConc enterF runF prims sup0 rootStarter = do
  (rootStep, sup1) <- startCoro sup0 rootStarter
  st0 <- processStep Root rootStep (Sched sup1 Seq.empty Map.empty Map.empty Nothing)
  loop st0
  where
    loop st = case schResult st of
      Just r  -> Right (r, schNextId st)
      Nothing -> case Seq.viewl (schReady st) of
        EmptyL -> {- existing deadlock / drained errors, unchanged -}
        (owner, resumeVal, carrier) :< rest -> do
          let st' = st { schReady = rest }
          (nextStep, supA) <- resumeCoro (schNextId st') carrier resumeVal
          st'' <- processStep owner nextStep st' { schNextId = supA }
          loop st''
```

`processStep` returns to its Task-1 shape
(`Owner -> Value -> Sched -> Either RuntimeError Sched`); the supply travels
inside `Sched`. Add a `mint` helper (the wrap guard lands in Task 4 — keep the
`Either` shape now so Task 4 only edits the body):

```haskell
-- | Mint a fresh handle id from the scheduler's view of the global supply.
mint :: Sched -> Either RuntimeError (Integer, Sched)
mint st = let i = schNextId st in Right (i, st { schNextId = i + 1 })
```

The three minting arms become (spawn shown; async also inserts its `Pending`
cell, newChan its `ChanState`, exactly as today):

```haskell
VCon rt [starterT] | rt == reqSpawnTag -> do
  (fid, st1) <- mint st
  childStarter <- unTransport starterT
  (childStep, supA) <- startCoro (schNextId st1) childStarter
  st2 <- processStep Detached childStep st1 { schNextId = supA }
  Right (enqueue owner (transport (VLit (LInt fid))) carrier st2)
```

(The child's first segment may itself nest a `runConc`, so the post-start
supply `supA` must be written back before folding the child's step.)

- [ ] **Step 2: Upgrade the lookup-miss errors**

The three `Nothing` branches (`ReqAwait` on `schCells`; `ReqSend`/`ReqRecv` on
`schChans`) become:

```haskell
Left (PrimError (Tx.pack "conc: promise not owned by this scheduler (created by another runConc, or forged): " <> Tx.pack (show pid)))
```

and for both channel arms:

```haskell
Left (PrimError (Tx.pack "conc: channel not owned by this scheduler (created by another runConc, or forged): " <> Tx.pack (show cid)))
```

Leave `fulfil on unknown promise` and `promise fulfilled twice` unchanged —
those are internal invariants, not user-reachable ownership errors. First
confirm no existing golden depends on the old texts:

```bash
grep -rn "unknown promise\|unknown channel" test/
```

Expected: no hits.

- [ ] **Step 3: Re-golden and verify the predicted flips**

```bash
cabal test --test-options='--accept -p conc-foreign'
git diff test/run-golden/
```

Expected — exactly these four files change, to exactly these contents
(id arithmetic: main seeds 0; outer mints first, nested drives continue from
the threaded supply):

- `conc-foreign-nested-await.expected`:
  `runtime error: PrimError "conc: promise not owned by this scheduler (created by another runConc, or forged): 0"`
- `conc-foreign-nested-chan.expected`:
  `runtime error: PrimError "conc: channel not owned by this scheduler (created by another runConc, or forged): 0"`
- `conc-foreign-sequential-await.expected`:
  `runtime error: PrimError "conc: promise not owned by this scheduler (created by another runConc, or forged): 0"`
- `conc-foreign-inner-escape.expected`:
  `runtime error: PrimError "conc: promise not owned by this scheduler (created by another runConc, or forged): 1"`

`conc-foreign-caf-escape.expected` must still read `7` and
`conc-nested-own-handles.expected` must still read `49`. A deviation from any
prediction means the threading is wrong — STOP and debug (do not accept).

- [ ] **Step 4: Full suite**

Run: `cabal test`
Expected: 809 pass; `git diff --stat test/` shows only the four flipped goldens.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/Interp/Sched.hs test/run-golden/
git commit -m "fix(conc): globally unique handle ids; foreign handles error instead of aliasing (doors 1+2)"
```

---

### Task 4: Per-entry CAF id regions (fixes door 3)

**Goal:** Each interpreter entry seeds its supply from a disjoint 48-bit region, closing the CAF-escape door; the mint wrap guard lands.

**Files:**
- Modify: `src/Wok/Interp/Machine.hs` (`runModule` region seeding + CAF-count guard)
- Modify: `src/Wok/Interp/Sched.hs` (`mint` wrap guard)
- Modify: `test/run-golden/conc-foreign-caf-escape.expected` (via `--accept` + inspection)

**Acceptance Criteria:**
- [ ] `conc-foreign-caf-escape` flips to the ownership error with a region-sized id (>= 2^48)
- [ ] More than 65535 zero-arity binds is a clean `Left`, not a wrapped id
- [ ] `conc-nested-own-handles` still `49`; suite green at 809

**Verify:** `cabal test` → 809 pass; `git diff test/run-golden/` shows exactly the one flip

**Steps:**

- [ ] **Step 1: Region seeding in `runModule`**

Zero-arity binds (CAFs — this includes prelude instance dictionaries, so
region indices are not predictable from the user file alone) each get the next
region; main's explicit run keeps region 0:

```haskell
runModule :: CoreModule -> Either RuntimeError Value
runModule (CoreModule binds)
  | length cafUniqs > 65535 =
      Left (PrimError (Tx.pack "too many top-level constants for the conc handle id-region scheme (max 65535)"))
  | otherwise =
      let gEnv = MapL.fromList (map entry binds)
          entry (TopBind n ps body)
            | null ps   = (nameUniq n, forceTop (cafSeed Map.! nameUniq n) body)
            | otherwise = (nameUniq n, VClosure gEnv ps body)
          forceTop seed body =
            case run primTable seed (Eval body (Scope gEnv Map.empty) KDone) of
              Right (v, _) -> v
              Left err     -> throw (CafFailure err)
      in case [ tb | tb@(TopBind n _ _) <- binds, nameHint n == Tx.pack "main" ] of
           (TopBind _ [] body : _) ->
             catchCaf (\() -> fst <$> run primTable 0 (Eval body (Scope gEnv Map.empty) KDone))
           (TopBind{}         : _) -> Left (ArityError (Tx.pack "main must take no arguments"))
           []                      -> Left (UnboundVar (Tx.pack "main"))
  where
    cafUniqs = [ nameUniq n | TopBind n ps _ <- binds, null ps ]
    cafSeed  = Map.fromList (zip cafUniqs (map (* idRegionBound) [1 ..]))
```

(`Map` here is `Data.Map.Strict`, already imported as `Map`; the `cafSeed`
lookup with `Map.!` is total because `cafSeed` is built from exactly the
zero-arity binds that `entry` consults it for.)

- [ ] **Step 2: Wrap guard in `mint` (`src/Wok/Interp/Sched.hs`)**

Import `idRegionBound` from `Wok.Interp.Value` and replace `mint`'s body:

```haskell
-- | Mint a fresh handle id. Refuses to wrap into the next entry's region
-- (2^48 ids per interpreter entry; unreachable in practice, loud if reached).
mint :: Sched -> Either RuntimeError (Integer, Sched)
mint st =
  let i    = schNextId st
      next = i + 1
  in if next `mod` idRegionBound == 0
       then Left (PrimError (Tx.pack "conc: handle id space exhausted for this interpreter entry"))
       else Right (i, st { schNextId = next })
```

- [ ] **Step 3: Re-golden the CAF fixture and verify**

```bash
cabal test --test-options='--accept -p conc-foreign-caf-escape'
cat test/run-golden/conc-foreign-caf-escape.expected
```

Expected: the promise-not-owned error whose id is `N * 281474976710656` for
some `N >= 1` (the exact region index depends on how many prelude dictionary
CAFs precede `top` in bind order — verify the id is an exact multiple of
2^48 = 281474976710656, i.e. a region base, since `top`'s drive mints its
promise as the region's first id). If the golden still reads `7`, the CAF run
is not getting its region seed — STOP and debug `runModule`.

- [ ] **Step 4: Full suite**

Run: `cabal test`
Expected: 809 pass; only the one golden changed.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/Interp/Machine.hs src/Wok/Interp/Sched.hs test/run-golden/conc-foreign-caf-escape.expected
git commit -m "fix(conc): per-entry CAF id regions + mint wrap guard (door 3)"
```

---

### Task 5: Documentation ride-alongs

**Goal:** The slice-3 spec, the new spec, and the prelude comments reflect the shipped behavior.

**Files:**
- Modify: `docs/superpowers/specs/2026-06-12-slice-3-runtime-provided-concurrency-design.md` (section 11 entry; sections 3.4/6 notes)
- Modify: `docs/superpowers/specs/2026-06-13-conc-handle-identity-design.md` (status line)
- Modify: `prelude/Std/Control.wok` (doc comments at `__drive_conc`/`runConc`)

**Acceptance Criteria:**
- [ ] Slice-3 section 11's "Nested `runConc` id-space collision" entry is rewritten as RESOLVED, names all three doors, and points to the new spec
- [ ] No remaining "avoid nesting" guidance anywhere in the repo
- [ ] Suite still green (prelude comment change must not disturb anything)

**Verify:** `grep -rn "avoid nesting" docs prelude src` → no hits; `cabal test` → 809 pass

**Steps:**

- [ ] **Step 1: Rewrite the slice-3 section 11 entry**

Replace the "Nested `runConc` id-space collision" bullet in
`docs/superpowers/specs/2026-06-12-slice-3-runtime-provided-concurrency-design.md`
with:

```markdown
- **Cross-scheduler handle identity — RESOLVED (2026-06-13).** Handle ids are
  now globally unique (machine-threaded supply + per-entry CAF regions), and a
  handle used outside its minting scheduler is a runtime error ("not owned by
  this scheduler") instead of silently aliasing a same-numbered cell. The
  original entry covered only nested `runConc`; the fix also closed two doors
  it missed (a handle escaping `runConc`'s result into a sibling, and a CAF's
  scheduler colliding with main's). Nesting itself is supported. This makes
  the section 3.4 prim-trust obligation and the section 6 validation promise
  real in Provider A (both were vacuous under colliding ids). Design + rejected
  alternatives: `2026-06-13-conc-handle-identity-design.md`.
```

- [ ] **Step 2: Status line in the new spec**

In `docs/superpowers/specs/2026-06-13-conc-handle-identity-design.md`, change
the Status line to: `Status: **Implemented** (branch fix/conc-handle-identity), 2026-06-13. Closes ...` (keep the rest of the sentence).

- [ ] **Step 3: Prelude comment**

In `prelude/Std/Control.wok`, after the existing residual-effect LIMITATION
paragraph above `runConc`, add:

```
-- Handle identity: Fiber/Promise/Chan handles are bound to the scheduler
-- instance that minted them. Using a handle under a different runConc (nested
-- or later) is a runtime error ("not owned by this scheduler"), never a
-- silent delivery. Nested runConc with its own handles is supported.
```

- [ ] **Step 4: Verify and commit**

```bash
grep -rn "avoid nesting" docs prelude src
cabal test
git add docs/superpowers/specs prelude/Std/Control.wok
git commit -m "docs(conc): mark handle-identity limitation resolved; prelude note on scheduler-bound handles"
```

---

### Task 6: Final verification sweep

**Goal:** Evidence the branch matches the spec before requesting full-branch review.

**Files:** none modified (verification only; fix anything found)

**Acceptance Criteria:**
- [ ] Full suite green at 809 from a clean build
- [ ] Diff scope matches spec section 5: only `Value.hs`/`Machine.hs`/`Sched.hs` in `src/`, fixtures/goldens in `test/`, docs, `Control.wok` comment
- [ ] The six conc goldens read, in fixture order: ownership error (id 0), channel ownership error (id 0), ownership error (id 0), ownership error (id 1), ownership error (region-base id), `49`

**Verify:** commands below, outputs as stated

**Steps:**

- [ ] **Step 1: Clean build + full suite**

```bash
cabal clean && cabal build && cabal test
```

Expected: 809 pass, no new warnings beyond main's baseline.

- [ ] **Step 2: Diff scope check**

```bash
git diff --stat main...HEAD
```

Expected files only: `src/Wok/Interp/{Value,Machine,Sched}.hs`,
`test/run-examples/conc-*.wok` (6 new), `test/run-golden/conc-*.expected`
(6 new), `docs/superpowers/specs/*` (2), `prelude/Std/Control.wok`,
`docs/superpowers/plans/2026-06-13-conc-handle-identity.md*`. Anything else
is scope creep — justify or revert.

- [ ] **Step 3: Re-read the six goldens against the acceptance list**

```bash
for f in test/run-golden/conc-foreign-*.expected test/run-golden/conc-nested-own-handles.expected; do echo "== $f"; cat "$f"; done
```

- [ ] **Step 4: Hand off to full-branch review**

Do NOT merge. Per project rule, request a full-branch code review of
`fix/conc-handle-identity` (the user triggers it); per the slice-3 lesson,
reviewers of this surface must RUN candidate exploits, not just reason about
them.
