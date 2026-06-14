# Perceus Interpreter M1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up Perceus-style reference counting on the wok interpreter as a correctness oracle for dup/drop placement (no-handler/first-order-data fragment), with the allocator exposed as a small store interface.

**Architecture:** A new **independent** RC interpreter (`Wok.Interp.RC.*`) executes ANF instrumented by a new Core->Core **Perceus pass** (`Wok.IR.Perceus`) over an explicit owned `Store` (handles + refcounts + free-via-tombstone). The existing CEK interpreter is left untouched as the trusted reference; correctness is validated *differentially* (same output) plus heap-empty / no-UAF / no-double-free assertions. Reuse/FBIP, borrow hints, continuations-RC, and codegen are out of scope.

**Tech Stack:** Haskell (GHC2024, Strict/StrictData), `Data.IntMap.Strict`/`Data.IntSet`, `tasty` + `tasty-golden` + `tasty-hunit` + `tasty-quickcheck`, HPC (`cabal test --enable-coverage`). Design spec: `docs/superpowers/specs/2026-06-14-perceus-interpreter-static-analysis-design.md`.

**Module map (created):**
- `src/Wok/Interp/RC/Store.hs` — `Addr`, `Node`, `Cell`, `Store`, `Stats`, `alloc`, `deref`, `incref`, `dropAddr` (iterative).
- `src/Wok/Interp/RC/Value.hs` — `RCValue`, `RCPrim`, `RCPrimResult` (incl. `PRStore`), `renderRCValue`, atom resolution.
- `src/Wok/Interp/RC/Prim.hs` — `rcPrimTable` with `__rc_dup`/`__rc_drop`.
- `src/Wok/Interp/RC/Machine.hs` — store-threaded CEK; `runModuleRC`.
- `src/Wok/IR/Perceus.hs` — the dup/drop insertion pass + `prettyPerceus` + balance lint.
- Test corpus dir `test/rc-examples/`, goldens `test/rc-perceus-golden/` and `test/rc-stats-golden/`.

**Wiring note (deliberate simplification vs spec wording):** the spec describes `dup`/`drop` as prelude `extern`s. Because the reference interpreter runs the *pre-Perceus* ANF and only the RC interpreter runs the instrumented ANF, M1 wires them as **compiler-internal prim names** (`__rc_dup`/`__rc_drop`, resolved by `rcPrimTable` via the existing hint fallback in `resolveAtom`), exactly like the `__coro_*` intrinsics. No prelude/typechecker change. The store *interface* is identical to the spec; only the binding is internal.

---

### Task 0: RC Store core types + alloc/deref

**Goal:** The owned-heap data types and pure allocate/deref operations (no RC behavior yet).

**Files:**
- Create: `src/Wok/Interp/RC/Store.hs`
- Modify: `wok.cabal` (add `Wok.Interp.RC.Store` to library `exposed-modules`)
- Test: `test/Spec.hs` (new `testGroup "rc store"`)

**Acceptance Criteria:**
- [ ] `alloc` returns a fresh monotonic `Addr` and bumps `stAllocs`/`stLive`/`stPeak`.
- [ ] `deref` of a live addr returns its `Cell`; of a dead/absent addr returns `Left (PrimError ...)`.
- [ ] `stLive` reflects live (non-dead) cells.

**Verify:** `cabal test --test-options='-p "rc store"'` -> PASS

**Steps:**

- [ ] **Step 1: Write the failing test** (add to `test/Spec.hs`, and add `rcStoreTests` to the top-level `testGroup "wok"` list)

```haskell
-- in test/Spec.hs (new import)
import qualified Wok.Interp.RC.Store as St
import Wok.IR.Anf (Lit (..))

rcStoreTests :: TestTree
rcStoreTests = testGroup "rc store"
  [ testCase "alloc gives fresh addrs and counts" $ do
      let s0 = St.emptyStore
          (a, s1) = St.alloc (St.NCon (T.pack "Nil") []) s0
          (b, s2) = St.alloc (St.NCon (T.pack "Nil") []) s1
      a @?= 0
      b @?= 1
      St.stLive (St.stStats s2) @?= 2
      St.stAllocs (St.stStats s2) @?= 2
  , testCase "deref reads a live cell" $ do
      let (a, s1) = St.alloc (St.NCon (T.pack "True") []) St.emptyStore
      case St.deref a s1 of
        Right c  -> St.cNode c @?= St.NCon (T.pack "True") []
        Left e   -> assertFailure ("unexpected: " <> show e)
  , testCase "deref of absent addr fails" $
      case St.deref 99 St.emptyStore of
        Left _  -> pure ()
        Right _ -> assertFailure "expected failure on absent addr"
  ]
```

- [ ] **Step 2: Run to verify it fails** — `cabal build` fails ("module Wok.Interp.RC.Store not found").

- [ ] **Step 3: Implement `src/Wok/Interp/RC/Store.hs`**

```haskell
module Wok.Interp.RC.Store
  ( Addr, Node (..), Cell (..), Stats (..), Store (..)
  , emptyStore, alloc, deref, incref, dropAddr
  ) where

import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IM
import Data.IntSet (IntSet)
import qualified Data.IntSet as IS
import Data.Map.Strict (Map)
import Data.Text (Text)
import Wok.IR.Anf (Binder, Expr)
import Wok.Interp.Value (RuntimeError (..))   -- reuse the shared error type
import qualified Data.Text as Tx

type Addr = Int

-- A boxed runtime node. RCValue is defined in Wok.Interp.RC.Value; to avoid a
-- cycle, Store is parameterized over the value type via the field positions
-- below being filled with RCValue at the Machine layer. For M1 we keep Node
-- monomorphic over RCValue by importing it; see note.
data Node
  = NCon Text [RCV]
  | NRecord Text (Map Text RCV)
  | NClosure REnv [Binder] Expr

-- To keep Store self-contained, RCV/REnv are re-exported aliases set in Value.
-- (Implementer: define RCValue in Value.hs and `type RCV = RCValue`,
--  `type REnv = Map Unique RCValue`; import them here. If the import cycle
--  bites, move Node into Value.hs and keep only Addr/Cell/Stats/Store here.)
```

NOTE for the implementer: Haskell module cycles. `Node` references `RCValue`, and the `Machine` references both. Resolve by **defining `RCValue`, `Node`, `Cell`, `Store` all in `Wok.Interp.RC.Value`** (one module, no cycle), and keeping `Store.hs` only if you prefer a split with `{-# SOURCE #-}`. The plan below assumes the **single-module** resolution: put Store types in `Value.hs` (Task 2) and make this Task 0 define the **non-value-dependent** core (`Stats`, and the allocator state machine over an abstract node) plus its tests using a placeholder node. Simplest concrete choice: **fold Store into Value.hs** and run Task 0's tests against the combined module. Adjust the import in the test to `Wok.Interp.RC.Value as St`.

- [ ] **Step 4: Implement the allocator (in whichever module holds the types)**

```haskell
data Stats = Stats { stAllocs, stFrees, stLive, stPeak :: !Int }
data Cell  = Cell { cRc :: !Int, cNode :: !Node }
data Store = Store
  { stCells :: !(IntMap Cell)
  , stNext  :: !Addr
  , stDead  :: !IntSet
  , stStats :: !Stats
  }

emptyStore :: Store
emptyStore = Store IM.empty 0 IS.empty (Stats 0 0 0 0)

alloc :: Node -> Store -> (Addr, Store)
alloc n s =
  let a  = stNext s
      st = stStats s
      live = stLive st + 1
      st' = st { stAllocs = stAllocs st + 1, stLive = live, stPeak = max (stPeak st) live }
  in (a, s { stCells = IM.insert a (Cell 1 n) (stCells s), stNext = a + 1, stStats = st' })

deref :: Addr -> Store -> Either RuntimeError Cell
deref a s
  | IS.member a (stDead s) = Left (PrimError (Tx.pack ("use-after-free: addr " <> show a)))
  | otherwise = case IM.lookup a (stCells s) of
      Just c  -> Right c
      Nothing -> Left (PrimError (Tx.pack ("dangling addr " <> show a)))
```

- [ ] **Step 5: Run** — `cabal test --test-options='-p "rc store"'` -> PASS. **Commit**: `git commit -am "feat(rc): owned-heap store types + alloc/deref"`

---

### Task 1: dup/drop on the store (iterative, with tombstone traps)

**Goal:** `incref` and `dropAddr` (iterative worklist; recursive child release at rc==0; tombstone), with UAF/double-free as `Left`.

**Files:**
- Modify: the module holding Store types (`src/Wok/Interp/RC/Value.hs` per the single-module resolution)
- Test: `test/Spec.hs` (extend `rc store` group)

**Acceptance Criteria:**
- [ ] `incref` bumps `cRc`; `dropAddr` decrements; at 0 recursively drops boxed children then tombstones (`stDead`, `stFrees`, `stLive`).
- [ ] `dropAddr` of a dead addr -> `Left` (double-free). `deref` after free -> `Left` (UAF).
- [ ] Dropping a deep list of length N frees N cells **without host-stack overflow** (iterative).

**Verify:** `cabal test --test-options='-p "rc store"'` -> PASS

**Steps:**

- [ ] **Step 1: Write failing tests**

```haskell
rcDropTests :: TestTree
rcDropTests = testGroup "rc drop"
  [ testCase "drop frees a unique leaf" $ do
      let (a, s1) = St.alloc (St.NCon (T.pack "Nil") []) St.emptyStore
      case St.dropAddr a s1 of
        Right s2 -> do St.stFrees (St.stStats s2) @?= 1
                       St.stLive  (St.stStats s2) @?= 0
                       case St.deref a s2 of { Left _ -> pure (); Right _ -> assertFailure "UAF not trapped" }
        Left e   -> assertFailure (show e)
  , testCase "double free is trapped" $ do
      let (a, s1) = St.alloc (St.NCon (T.pack "Nil") []) St.emptyStore
          Right s2 = St.dropAddr a s1
      case St.dropAddr a s2 of { Left _ -> pure (); Right _ -> assertFailure "double-free not trapped" }
  , testCase "drop recursively frees children" $ do
      let (h, s1) = St.alloc (St.NCon (T.pack "Nil") []) St.emptyStore
          (t, s2) = St.alloc (St.NCon (T.pack "Nil") []) s1
          (c, s3) = St.alloc (St.NCon (T.pack "Cons") [St.RVBox h, St.RVBox t]) s2
          Right s4 = St.dropAddr c s3
      St.stLive (St.stStats s4) @?= 0
  , testCase "deep list drops iteratively (no stack overflow)" $ do
      let n = 200000
          build 0 s = St.alloc (St.NCon (T.pack "Nil") []) s
          build k s = let (rest, s') = build (k-1) s
                      in St.alloc (St.NCon (T.pack "Cons") [St.RVLit (LInt (fromIntegral k)), St.RVBox rest]) s'
          (top, s1) = build n St.emptyStore
          Right s2 = St.dropAddr top s1
      St.stLive (St.stStats s2) @?= 0
  ]
```

- [ ] **Step 2: Run to verify it fails** (functions undefined).

- [ ] **Step 3: Implement `incref`/`dropAddr` (iterative)**

```haskell
incref :: Addr -> Store -> Either RuntimeError Store
incref a s = do
  c <- deref a s
  Right s { stCells = IM.insert a c { cRc = cRc c + 1 } (stCells s) }

-- Iterative: a worklist of addrs to decrement. Freeing a cell pushes its boxed
-- children onto the worklist instead of recursing on the host stack.
dropAddr :: Addr -> Store -> Either RuntimeError Store
dropAddr a0 s0 = go [a0] s0
  where
    go [] s = Right s
    go (a : rest) s
      | IS.member a (stDead s) = Left (PrimError (Tx.pack ("double-free: addr " <> show a)))
      | otherwise = case IM.lookup a (stCells s) of
          Nothing -> Left (PrimError (Tx.pack ("drop of dangling addr " <> show a)))
          Just c
            | cRc c > 1 ->
                go rest s { stCells = IM.insert a c { cRc = cRc c - 1 } (stCells s) }
            | otherwise ->  -- rc == 1 -> free
                let kids = boxedChildren (cNode c)
                    st   = stStats s
                    s'   = s { stCells = IM.delete a (stCells s)
                             , stDead  = IS.insert a (stDead s)
                             , stStats = st { stFrees = stFrees st + 1, stLive = stLive st - 1 } }
                in go (kids ++ rest) s'

boxedChildren :: Node -> [Addr]
boxedChildren n = [ a | RVBox a <- nodeValues n ]

nodeValues :: Node -> [RCValue]
nodeValues (NCon _ vs)    = vs
nodeValues (NRecord _ m)  = Map.elems m
nodeValues (NClosure env _ _) = Map.elems env
```

- [ ] **Step 4: Run** — `cabal test --test-options='-p "rc"'` -> PASS (incl. deep-list).
- [ ] **Step 5: Commit** — `git commit -am "feat(rc): iterative dup/drop with tombstone UAF/double-free traps"`

---

### Task 2: RC Value + store-threaded CEK machine (first-order data)

**Goal:** An RC interpreter that evaluates the no-handler ANF fragment over the store, executing `__rc_dup`/`__rc_drop`, with store-aware rendering. Validated on a **hand-instrumented** ANF.

**Files:**
- Modify/Create: `src/Wok/Interp/RC/Value.hs` (RCValue, Node/Cell/Store, RCPrim/RCPrimResult incl. `PRStore`, `renderRCValue`, `resolveRCAtom`), `src/Wok/Interp/RC/Prim.hs` (`rcPrimTable`), `src/Wok/Interp/RC/Machine.hs`
- Modify: `wok.cabal` (expose the three modules)
- Test: `test/Spec.hs` (`testGroup "rc machine"`)

**Acceptance Criteria:**
- [ ] Evaluates `Ret`/`Let`/`RAtom`/`RApp`/`RCon`/`RRecord`/`RProj`/`Case` over the store; `RCon`/`RRecord`/`RLam` allocate; `RProj`/`Case` deref.
- [ ] `__rc_dup` increfs (no-op on `RVLit`) and returns the value; `__rc_drop` drops and returns unit; both thread the store via `PRStore`.
- [ ] On a hand-instrumented program, output matches a reference value AND `stLive == 0` after the result is rendered+dropped.

**Verify:** `cabal test --test-options='-p "rc machine"'` -> PASS

**Steps:**

- [ ] **Step 1: Define the RC value/prim types** (in `Value.hs`)

```haskell
data RCValue = RVLit Lit | RVBox Addr
  deriving (Eq, Show)

type REnv = Map Unique RCValue
data RCScope = RCScope { rscEnv :: REnv, rscJoins :: Map JoinId RCJoin }

data RCPrim = RCPrim { rpName :: Text, rpArity :: Int, rpArgs :: [RCValue]
                     , rpFn :: [RCValue] -> Store -> Either RuntimeError (RCPrimResult, Store) }
data RCPrimResult = PRDone RCValue | PRApply RCValue [RCValue]
```

(`PRStore` is folded into `rpFn` returning the updated `Store` — simpler than a separate constructor. dup/drop are just prims whose `rpFn` reads/writes the store.)

- [ ] **Step 2: Implement `rcPrimTable`** (in `Prim.hs`) — arithmetic etc. mirror the reference `Prim.hs` (operate on `RVLit`), plus:

```haskell
rcDup :: RCPrim
rcDup = RCPrim (Tx.pack "__rc_dup") 1 [] $ \args s -> case args of
  [v@(RVBox a)] -> do s' <- incref a s; Right (PRDone v, s')
  [v@(RVLit _)] -> Right (PRDone v, s)
  _ -> Left (ArityError (Tx.pack "__rc_dup"))

rcDrop :: RCPrim
rcDrop = RCPrim (Tx.pack "__rc_drop") 1 [] $ \args s -> case args of
  [RVBox a]   -> do s' <- dropAddr a s; Right (PRDone (RVLit LUnit), s')
  [RVLit _]   -> Right (PRDone (RVLit LUnit), s)
  _ -> Left (ArityError (Tx.pack "__rc_drop"))
```

- [ ] **Step 3: Implement the store-threaded machine** (`Machine.hs`) — same CEK shape as the reference but every step threads `Store`. Core (allocation + prim dispatch + match):

```haskell
-- Config carries the store. Eval/Return as in the reference, plus Store.
data RCConfig = REval Expr RCScope RCKont Store | RReturn RCValue RCKont Store

evalRhsRC :: RCPrimTable -> RCBinder -> Rhs -> Expr -> RCScope -> RCKont -> Store
          -> Either RuntimeError RCConfig
evalRhsRC prims b rhs body sc k s = case rhs of
  RCon c as -> do vs <- mapM (resolveRCAtom prims sc) as
                  let (a, s') = alloc (NCon c vs) s
                  cont (RVBox a) s'
  RRecord t flds -> do vs <- mapM (\(l,a) -> (,) l <$> resolveRCAtom prims sc a) flds
                       let (a, s') = alloc (NRecord t (Map.fromList vs)) s
                       cont (RVBox a) s'
  RLam ps e -> let (a, s') = alloc (NClosure (rscEnv sc) ps e) s in cont (RVBox a) s'
  RProj l a -> do v <- resolveRCAtom prims sc a
                  case v of
                    RVBox addr -> do c <- deref addr s
                                     case cNode c of
                                       NRecord _ m | Just fv <- Map.lookup l m -> cont fv s
                                       _ -> Left (BadProjection l)
                    _ -> Left (BadProjection l)
  RAtom a -> do v <- resolveRCAtom prims sc a; cont v s
  RApp f as -> do fv <- resolveRCAtom prims sc f
                  vs <- mapM (resolveRCAtom prims sc) as
                  enterRC prims fv vs (KLetRC b body sc k) s
  ROp{} -> Left (PrimError (Tx.pack "rc M1: effects not supported (no-handler fragment)"))
  where cont v s' = Right (REval body sc { rscEnv = bindRC b v (rscEnv sc) } k s')
```

`Case` derefs the scrutinee handle and matches over the `NCon` node; `enterRC` mirrors the reference `enter` (closures from `NClosure` cells, prim currying, `rpFn` threading the store).

- [ ] **Step 4: store-aware `renderRCValue`** — derefs handles to reproduce the reference `renderValue` text exactly (lists as `[..]`, tuples as `(..)`, etc.). Copy the reference rendering logic, derefing `RVBox`.

- [ ] **Step 5: Write the test (hand-instrumented program)** — build an ANF that allocates a pair, projects, and drops the unused half; assert output and `stLive == 0`.

```haskell
rcMachineTests :: TestTree
rcMachineTests = testCase "hand-instrumented pair: output + heap empty" $ do
  -- let p = Tuple2 1 2 in let _ = drop p ... (concrete ANF built here)
  -- run via runExprRC; assert rendered result and St.stLive == 0
  pure ()   -- implementer fills the concrete ANF per the shapes above
```

(Implementer: construct the `Expr` with `Anf` constructors directly — `Let` binders with fresh `Unique`s — exercising alloc + `__rc_drop`; assert the rendered value equals the expected string and `stLive (stStats finalStore) == 0`.)

- [ ] **Step 6: Run + Commit** — `cabal test --test-options='-p "rc machine"'` -> PASS. `git commit -am "feat(rc): store-threaded CEK for first-order data + dup/drop prims"`

---

### Task 3: Globals static region + result handling + `runModuleRC`

**Goal:** Whole-module RC entry: top-level binds in a static (uncounted, excluded-from-live) region; result rendered then dropped; heap-empty asserted.

**Files:** Modify `src/Wok/Interp/RC/Machine.hs`; Test `test/Spec.hs`.

**Acceptance Criteria:**
- [ ] `runModuleRC :: CoreModule -> Either RuntimeError (Text, Stats)` returns rendered output + final stats.
- [ ] Top-level binds are allocated once into a static region; references to them are never dup/drop'd; they are excluded from `stLive`.
- [ ] After rendering the result and dropping it, `stLive == 0` for a program with no globals retained.

**Verify:** `cabal test --test-options='-p "rc module"'` -> PASS

**Steps:** (1) build a static `REnv` from `cmBinds` (mirroring reference `runModule`'s gEnv, but globals tagged static so dup/drop skip them and they don't count in `stLive`); (2) run `main`; (3) `renderRCValue` the result, then `dropAddr` it (if boxed), then read `stStats`; (4) test on a hand-instrumented module asserting `stLive == 0`; (5) commit `feat(rc): runModuleRC with static globals + result drop + heap-empty`.

---

### Task 4: LetRec uncounted region

**Goal:** Local `LetRec` groups allocate with intra-group edges uncounted; dropped as a unit at scope exit (the no-counted-back-edge invariant).

**Files:** Modify `src/Wok/Interp/RC/Machine.hs`, `src/Wok/Interp/RC/Value.hs` (region tag on closure cells or a side region-table); Test `test/Spec.hs`.

**Acceptance Criteria:**
- [ ] A program using local mutual recursion runs and ends `stLive == 0`.
- [ ] Dropping a group member does not double-free or leak siblings (intra-group edges are not counted).

**Verify:** `cabal test --test-options='-p "rc letrec"'` -> PASS

**Steps:** represent a letrec group as cells sharing a `region` id; `dropAddr` does not traverse a child edge whose target is in the same region; the region is freed as a unit when its external refcount hits 0. Unit-test with `letrec even=…odd…; odd=…even… in even 4` (hand-instrumented). Commit `feat(rc): letrec uncounted-region allocation + group drop`.

---

### Task 5: Perceus pass — straight-line insertion (`Wok.IR.Perceus`)

**Goal:** The Core->Core pass for `Ret`/`Let`/`RAtom`/`RApp`/`RCon`/`RRecord`/`RProj`, with backward last-use liveness, plus `prettyPerceus` and a balance lint.

**Files:** Create `src/Wok/IR/Perceus.hs`; Modify `wok.cabal`; Modify `app/Main.hs` (add `--dump-perceus`); Test `test/Spec.hs` + goldens `test/rc-perceus-golden/`.

**Acceptance Criteria:**
- [ ] `insertRC :: CoreModule -> CoreModule` inserts `__rc_dup` before each non-last use of a boxed binder and `__rc_drop` at each boxed binder's last use / unused-binding point.
- [ ] Globals and (Task 7) letrec groups are exempt.
- [ ] `balanceLint :: CoreModule -> [Text]` returns `[]` (every owned binder reaches exactly one consume on every path).
- [ ] `--dump-perceus file.wok` prints the annotated ANF; golden-stable.

**Verify:** `cabal test --test-options='-p "perceus"'` -> PASS

**Steps:**

- [ ] **Step 1: Failing golden** — add `perceusFiles <- findByExtension [".wok"] "test/rc-examples"` and a `testGroup "perceus golden"` running `perceusDumpHarness` (load -> `elaborateProgramFull` -> `Perceus.insertRC` -> `Perceus.prettyPerceus`) against `test/rc-perceus-golden/`. Plus a HUnit `perceus lint` group asserting `Perceus.balanceLint cm == []` for each corpus file.

- [ ] **Step 2: Implement the core insertion** — backward pass returning, for each subexpression, the inserted-`Expr` plus the **owned set consumed** within it. Key signatures and the linear-rhs rule:

```haskell
-- owned set = boxed local Uniques that must be consumed exactly once
insertRC :: CoreModule -> CoreModule
insertRC (CoreModule bs) = CoreModule (map onBind bs)
  where onBind tb = tb { tbBody = ownExpr (paramsOwned (tbParams tb)) (tbBody tb) }

-- ownExpr e Δ: rewrite e so every var in Δ is consumed exactly once within e.
-- Returns the rewritten expr. Uses freeVarsExpr to know future uses.
ownExpr :: Set Unique -> Expr -> Expr
ownExpr delta (Ret a) =
  -- result var (if boxed) is moved out; everything else in Δ is dead -> drop.
  dropsFor (delta `Set.difference` atomVars a) (Ret a)
ownExpr delta (Let b rhs body) =
  let usedLater = freeVarsExpr body
      -- operands of rhs used again later get a dup; rhs consumes the rest
      (rhs', dups) = dupNonLastUses usedLater rhs
      delta' = addBoxed b (delta `Set.difference` rhsConsumes rhs)
  in foldr letDup (Let b rhs' (ownExpr delta' body)) dups
ownExpr delta e = ... -- Case/LetJoin/Jump/LetRec/Handle: Tasks 6,7
```

with helpers `dropsFor` (wrap an expr in `let _ = __rc_drop x` lets), `letDup` (prepend `let x' = __rc_dup x`), `dupNonLastUses`, `rhsConsumes`, `addBoxed` (only boxed-typed binders, via `bndType`), and `mkDrop`/`mkDup` minting fresh `Unique`s and emitting `RApp (AVar dropName) [AVar x]`. `freeVarsExpr` is the standard ANF free-var walk.

- [ ] **Step 3: `prettyPerceus`** = `Anf.prettyModule` over the instrumented module (reuse the existing pretty-printer; `__rc_dup`/`__rc_drop` print as ordinary apps).

- [ ] **Step 4: `balanceLint`** — walk each binder; assert exactly one consume on every path (a consume = appears as a move operand, a `__rc_drop` arg, or the `Ret` result). Return human-readable violations.

- [ ] **Step 5: `--dump-perceus` in `app/Main.hs`** — new `CliMode`, mirrors `--dump-anf` but runs `insertRC` first.

- [ ] **Step 6: Run, accept goldens, commit** — `cabal test --test-options='-p "perceus" --accept'` then `-p "perceus"` -> PASS. `git commit -am "feat(perceus): straight-line dup/drop insertion + dump + balance lint"`

---

### Task 6: Perceus `Case` — own-children / drop-parent + branch reconciliation

**Goal:** Extend `insertRC` to `Case`.

**Files:** Modify `src/Wok/IR/Perceus.hs`; Test goldens + lint over `test/rc-examples/` programs with matches.

**Acceptance Criteria:**
- [ ] Each `AltCon` dups the matched-out children it keeps, then drops the parent shell at the match.
- [ ] An owned var dead in a particular alt is dropped at that alt's entry (drop-on-dead-branch); all alts consume the same Δ.

**Verify:** `cabal test --test-options='-p "perceus"'` -> PASS

**Steps:** implement the `Case` case of `ownExpr`:

```haskell
ownExpr delta (Case a alts)
  | scr <- atomVar a =
      let deltaInAlt childBinders =
            (delta `Set.difference` Set.singleton scr) `Set.union` boxedBinders childBinders
          onAlt (AltCon c bs body) =
            let kept   = filter (boxedUsedIn body) bs
                body'  = ownExpr (deltaInAlt bs) body
            in AltCon c bs (foldr (dupBinder) (dropParentThen scr body') kept)
          onAlt (AltLit l body)  = AltLit l (dropParentThen scr (ownExpr delta body))
          onAlt (AltDefault body)= AltDefault (dropParentThen scr (ownExpr delta body))
      in Case a (map onAlt alts)
```

where `dropParentThen scr e` prepends `let _ = __rc_drop scr` (only if `scr` is owned and boxed). Reconcile dead-in-this-alt owned vars by `dropsFor` at alt entry. Run/accept goldens; verify `balanceLint == []`. Commit `feat(perceus): Case own-children/drop-parent + branch reconciliation`.

---

### Task 7: Perceus `LetJoin`/`Jump` reconciliation + LetRec/global exemptions

**Goal:** Handle join points (the careful part) and mark letrec-group + global references RC-exempt.

**Files:** Modify `src/Wok/IR/Perceus.hs`; Test goldens + lint over multi-clause / local-recursion corpus programs.

**Acceptance Criteria:**
- [ ] Each join's expected owned set is computed once; every `Jump` reconciles to it (drop owned-but-not-passed vars before the jump).
- [ ] References to top-level binds and to letrec-group siblings emit no dup/drop.
- [ ] `balanceLint == []` across the corpus including multi-clause functions.

**Verify:** `cabal test --test-options='-p "perceus"'` -> PASS

**Steps:** compute join-param owned sets; in `Jump j as`, drop `delta \ atomVars as`; in `LetJoin`, own the join body under its params' owned set; thread the join's expected Δ so all jump sites agree (fixpoint if a join is reached from sites with differing Δ — pick the intersection-of-live and drop the difference per site). Exempt globals (top-level `Unique`) and letrec-group binders from `addBoxed`/dup/drop. Accept goldens; commit `feat(perceus): join-point reconciliation + letrec/global RC exemptions`.

---

### Task 8: Wire pass into pipeline + Suite A differential run

**Goal:** Run the no-handler corpus through reference (pre-Perceus) and RC (post-Perceus) interpreters; assert identical output.

**Files:** Modify `test/Spec.hs`; Create `test/rc-examples/*.wok` (curated no-handler programs).

**Acceptance Criteria:**
- [ ] A `no-handler guard` rejects any `test/rc-examples` file whose elaborated ANF contains `Handle`/`ROp` (fails the test loudly).
- [ ] For each corpus file: `renderValue (reference runModule)` == `fst (runModuleRC (insertRC cm))`.

**Verify:** `cabal test --test-options='-p "rc differential"'` -> PASS

**Steps:**

- [ ] **Step 1** — seed `test/rc-examples/` with the no-handler survivors (literals, arithmetic, lists, records, pattern-match, multi-clause, collatz) copied from `test/run-examples`, plus a few new ones.
- [ ] **Step 2** — harness:

```haskell
rcDifferentialHarness :: FilePath -> IO BL.ByteString
rcDifferentialHarness path = do
  Right (entryName, ms) <- Loader.loadProgram path []
  let Right cm = Pipeline.elaborateProgramFull entryName ms
  Control.Monad.when (hasHandlerOrOp cm) $ assertFailure (path <> ": not a no-handler program")
  let refOut = either (T.pack . show) Interp.renderValue (Interp.runModule cm)
      rcOut  = either (T.pack . show) fst (Machine.runModuleRC (Perceus.insertRC cm))
  refOut @?= rcOut
  pure (BL.pack (T.unpack rcOut <> "\n"))
```

- [ ] **Step 3** — run/commit `feat(rc): Suite A differential run over no-handler corpus`.

---

### Task 9: Suite B — heap accounting + `--dump-rc-stats` golden

**Goal:** Assert heap-empty + balanced counts per program; pin allocation behavior.

**Files:** Modify `test/Spec.hs`; Create `test/rc-stats-golden/`; Modify `app/Main.hs` (`--dump-rc-stats`).

**Acceptance Criteria:**
- [ ] For each corpus file: after `runModuleRC`, `stLive == 0` and `stAllocs == stFrees`.
- [ ] `--dump-rc-stats` prints `allocs/frees/peakLive`; golden-stable.

**Verify:** `cabal test --test-options='-p "rc stats"'` -> PASS. Commit `feat(rc): Suite B heap accounting + stats golden`.

---

### Task 10: Suite C(b) — fault injection (oracle-has-teeth)

**Goal:** Prove the oracle catches the bug classes by deliberately breaking the pass and asserting failure.

**Files:** Modify `src/Wok/IR/Perceus.hs` (a `Mutation` debug knob: `OmitOneDrop | OmitOneDup | DuplicateOneDrop`, gated, never on by default); Test `test/Spec.hs`.

**Acceptance Criteria:**
- [ ] With `OmitOneDrop`, Suite B reports a leak (`stLive > 0`) on at least one corpus file.
- [ ] With `OmitOneDup` on a shared value, the RC run trips UAF/double-free (`Left`).
- [ ] With `DuplicateOneDrop`, the RC run trips double-free.

**Verify:** `cabal test --test-options='-p "rc teeth"'` -> PASS (each mutation asserted to FAIL the oracle). Commit `test(rc): Suite C fault-injection proves oracle has teeth`.

---

### Task 11: Suite D + E — analysis goldens + rule-by-rule micro-programs

**Goal:** Golden the `--dump-perceus` output and add targeted micro-programs.

**Files:** Create `test/rc-examples/micro-*.wok`; goldens in `test/rc-perceus-golden/`; Test `test/Spec.hs`.

**Acceptance Criteria:**
- [ ] Micro-programs exist and pass A+B+D: shared subterm (`let x=…; pair x x`), conditional consume, linear pass-through, nested match, record field ownership, local mutual recursion, multi-clause join, deep list.
- [ ] `--dump-perceus` goldens stable; `balanceLint == []`.

**Verify:** `cabal test --test-options='-p "perceus" ; -p "rc"'` -> PASS. Commit `test(rc): Suite D goldens + Suite E rule-by-rule micro-programs`.

---

### Task 12: Suite F — property-based + HPC coverage

**Goal:** Random first-order ANF differential + heap-empty; drive coverage.

**Files:** Modify `wok.cabal` (test dep `tasty-quickcheck`); Test `test/Spec.hs` (a `Gen Expr` for the first-order fragment + property).

**Acceptance Criteria:**
- [ ] A generator produces well-scoped first-order ANF (Lit/Con/Record/Proj/Case/Let/App over a small set of nullary+binary constructors), elaborated-equivalent enough to run.
- [ ] Property: for every generated program, reference output == RC output AND `stLive == 0` AND no UAF/double-free.
- [ ] `cabal test --enable-coverage` produces an HPC report; new modules driven toward full expression coverage (gaps noted).

**Verify:** `cabal test --test-options='-p "rc property"'` -> PASS; `cabal test --enable-coverage` -> HPC report generated. Commit `test(rc): Suite F property-based differential + HPC coverage`.

---

## Self-Review

- **Spec coverage:** Store API + tombstone (Tasks 0,1) ✓ §4; dup/drop externs (Tasks 1,2) ✓ §4; analysis Strategy 2 + rules (Tasks 5,6,7) ✓ §5; Kont-ownership is *dormant* in M1 (no-handler fragment) — specified in §5/§7, intentionally not implemented here ✓; separate independent RC interpreter (Tasks 2-4) ✓ §6; iterative drop (Task 1) ✓ §6.6; letrec uncounted region (Tasks 4,7) ✓ §2.4/§6.7; globals static (Tasks 3,7) ✓ §6.8; result render-then-drop (Task 3) ✓ §6.9; Suites A-F + HPC (Tasks 8-12) ✓ §8.
- **Placeholder scan:** the few `pure ()`/`...` markers are explicitly labeled "implementer fills the concrete ANF/cases per the shapes above" with the surrounding real code and types given — they are construction stubs for test fixtures, not hand-wavy logic. Acceptable; the algorithm code is concrete.
- **Type consistency:** `RCValue`/`RVLit`/`RVBox`, `Node`/`NCon`/`NRecord`/`NClosure`, `Cell{cRc,cNode}`, `Store{stCells,stNext,stDead,stStats}`, `Stats{stAllocs,stFrees,stLive,stPeak}`, `alloc`/`deref`/`incref`/`dropAddr`, `insertRC`/`prettyPerceus`/`balanceLint`, `runModuleRC`, `__rc_dup`/`__rc_drop` — used consistently across tasks.
- **Module-cycle caveat** flagged in Task 0 (fold Store types into `Value.hs` if the cycle bites).

## Careful spots (from spec §9)
Join-point reconciliation (Task 7) — may warrant a focused follow-up if differing-Δ joins get hairy; letrec region representation (Task 4); result final-drop ordering (Task 3); iterative drop (Task 1, done first deliberately); address recycling is OUT of M1.
