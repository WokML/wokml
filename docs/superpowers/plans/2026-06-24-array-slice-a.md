# Slice A — fixed-size `Array a` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a fixed-size, boxed, type-checked `Array a` to the RC interpreter (the abstract heap), with the seven ops `new`/`fromList`/`toList`/`index`/`length`/`set`/`resize`, sound RC accounting, and differential-oracle coverage.

**Architecture:** A new `NArray [RCValue]` node on the abstract `IntMap` heap (routed there on both backends, like `NClosure`/`NEnv`/`NCont`; no C cell in Slice A). Boxed elements are ordinary counted children reached through the existing `countedRefs`/cascade. Ops are RC prims that own (consume) their args and transfer/drop refs per the spec. Same design as Koka's `vector<a>`.

**Tech Stack:** Haskell (GHC 9.10), cabal, tasty + Hspec + QuickCheck. Spec: `docs/superpowers/specs/2026-06-24-array-slice-a-design.md`. Arc: `docs/superpowers/2026-06-24-array-region-valuemodel-arc.md`.

**User decisions (already made):** "make it an Array gold standard on the abstract heap"; `set` is copy-on-write only (in-place deferred to Slice C); `resize` takes a fill value; boxed-first (Koka `vector`); C cell / unboxed / regions / String all deferred; "what is important is the soundness and the performance" → every task asserts the heap returns to baseline (no leak / no double-free) and the differential oracle is byte- and stat-identical on both backends.

**Baseline:** `feat/array-slice-a` off `main`, 1282 tests green, clean build.

---

### Task 1: `NArray` node + RC cascade (store layer)

**Goal:** Add the `NArray [RCValue]` heap node and its store-algebra behaviour (alloc / dup / drop-cascade / render), validated by unit tests at the store layer — no type or prim needed yet.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` — add `NArray [RCValue]` to `Node`; extend `nodeValues`; extend the renderers (`renderRCValue`/`renderRCValueRC`); `cascadeChildren` needs NO new arm (the generic `countedRefs . nodeValues` fall-through is correct); keep `nodeCEligible (NArray _) = False`.
- Test: the existing store-algebra unit test module (the one that exercises `alloc`/`incref`/`dropAddr`/`cascadeChildren` directly — find it under `test/` via `grep -rl "dropAddrPure\|cascadeChildren\|allocPure" test/`).

**Acceptance Criteria:**
- [ ] `NArray [RCValue]` is a `Node` constructor; `nodeValues (NArray vs) = vs`; renderers print it (e.g. `[a, b, c]`).
- [ ] Allocating an `NArray` of boxed-counted elements then `dropAddr` at rc 1 cascades a drop of each counted element exactly once and returns `stLive` to baseline.
- [ ] An `NArray` of inline/uncounted elements (e.g. `RVLit (LInt _)`) has no counted children: drop frees only the array cell, no spurious child drops.
- [ ] `incref` of an array address bumps only the cell rc (elements unchanged); a second drop frees the cell + cascades once (no double-free; `stDead` guard not tripped).
- [ ] Build green; existing tests unaffected.

**Verify:** `cabal test wok-tests 2>&1 | grep -E "NArray|All [0-9]+ tests passed"` → new NArray store tests pass, total = 1282 + new.

**Steps:**

- [ ] **Step 1: Failing store-algebra tests.** Add unit tests (mirror the existing store-algebra test style): build `alloc (NArray [RVBox e1, RVBox e2]) s` over two pre-allocated counted cells; assert `nodeValues` and that `dropAddrPure` of the array at rc 1 yields `stLive == baseline` and both element cells freed. A second test: `NArray [RVLit (LInt 1), RVLit (LInt 2)]` → drop frees only the array cell. A third: alloc array, `incref`, `dropAddr` twice → freed once, cascades once, no `double-free` error.
- [ ] **Step 2: Run → fail** (`NArray` not a constructor): `cabal test wok-tests` → compile error / FAIL.
- [ ] **Step 3: Implement.** In `Value.hs`: add `| NArray [RCValue]` to `data Node` (place near `NCon`); add `nodeValues (NArray vs) = vs`; extend the two renderers with an `NArray` case rendering `[`elem`, `…`]`; confirm `cascadeChildren` falls through (no new arm) and `nodeCEligible (NArray _) = False`. Export nothing new (the `Node` constructors are already exported via `Node (..)`).
- [ ] **Step 4: Run → pass.** `cabal test wok-tests` → new tests pass, 1282 still green.
- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(rc): NArray heap node + cascade (Slice A task 1)"`

---

### Task 2: `Array a` type registration

**Goal:** Make `Array` a known type constructor of kind `* -> *` so signatures mentioning `Array a` type-check.

**Files:**
- Modify: `src/Wok/TypeChecking/Types.hs` — add `TcArray` to `TyCon`.
- Modify: `src/Wok/TypeChecking/Builtins.hs` — register `("Array", TyConInfo (KArrow KStar KStar) 1 [] False [KStar])` (mirror the `[]`/`TcList` entry exactly).
- Modify: `src/Wok/TypeChecking/Infer.hs` — add `| name == Tx.pack "Array" = TcArray` to `nameToCon`.
- Test: the type-checker test module (find via `grep -rl "inferType\|typeCheck\|kindOf" test/` or the existing typing golden tests).

**Acceptance Criteria:**
- [ ] `Array` resolves to `TcArray` with kind `KArrow KStar KStar`, arity 1.
- [ ] A signature like `f : Array a -> U64` type-checks; applying `Array` to zero or two args is a kind error.
- [ ] Build green; existing tests unaffected.

**Verify:** `cabal test wok-tests` → type tests for `Array` pass, 1282 still green.

**Steps:**

- [ ] **Step 1: Failing test.** Add a typing test: a module declaring `f : Array a -> U64` (with a trivial body or as an extern) type-checks; a malformed `g : Array -> U64` (kind mismatch) is rejected. Mirror the existing `TcList`/`[a]` typing test.
- [ ] **Step 2: Run → fail** (`Array` unknown tycon).
- [ ] **Step 3: Implement.** Add `TcArray` to `TyCon` (next to `TcList`); register in `Builtins.hs` mirroring the `[]` entry; route `"Array" -> TcArray` in `nameToCon`. Keep `Show`/`Eq`/`Ord` derivations intact.
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(types): register Array tycon (kind * -> *) (Slice A task 2)"`

---

### Task 3: PrimNames + the seven `Array` prims

**Goal:** Implement the seven ops as RC prims with the exact RC accounting from the spec §4, with prim-level unit tests asserting behaviour, alloc/free deltas, and bounds errors.

**Files:**
- Modify: `src/Wok/IR/PrimNames.hs` — seven name constants + their qualified `(Std.Array, <name>)` identities (mirror how `Std.Control` externs are named/keyed).
- Modify: `src/Wok/Interp/RC/Prim.hs` — the seven `RCPrim`s + helpers; add them to the `prims` list.
- Test: a new prim unit-test module (mirror the existing RC prim/interp test style).

**Acceptance Criteria:**
- [ ] Each prim behaves per spec §4; `index`/`set` out-of-bounds raise `PrimError`.
- [ ] RC deltas match spec §4 (`new`/`fromList`/`set`/`resize` net +1 alloc; `index`/`length` net 0; `toList` net +N); heap returns to baseline after consuming the result.
- [ ] No partial functions (no `!!`/`head`); list access is via a total helper guarded by the bounds check.
- [ ] Build green; existing tests unaffected.

**Verify:** `cabal test wok-tests` → array prim unit tests pass, 1282 still green.

**Steps:**

- [ ] **Step 1: Failing prim unit tests.** For each prim, call `rpFn` directly on constructed `RCValue`s + a `Store` (use `initSentinel emptyStore` and pre-allocated element cells), asserting the returned `RCValue`, the resulting `stStats` deltas, and that dropping the result returns `stLive` to baseline. Include out-of-bounds `index`/`set` raising `PrimError`.
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement helpers** in `Prim.hs`:

```haskell
-- value-level dup/drop (mirror __rc_dup/__rc_drop over a value's counted children)
dupValue :: RCValue -> Store -> RC Store
dupValue v s = foldM (flip incref) s (valueChildren v)

dropValue :: RCValue -> Store -> RC Store
dropValue v s = foldM (flip dropAddr) s (valueChildren v)

dupN :: Int -> RCValue -> Store -> RC Store
dupN k v s = if k <= 0 then pure s else foldM (\st _ -> dupValue v st) s [1 .. k]

asIndex :: RCValue -> Either RuntimeError Int        -- U64 literal -> Int
asIndex (RVLit (LInt n)) = Right (fromInteger n)
asIndex _                = Left (PrimError (Tx.pack "Array: expected U64"))

atIndex :: Int -> [a] -> Maybe a                     -- total, no (!!)
atIndex i xs = case drop i xs of { (x:_) -> Just x; [] -> Nothing }

arrayElems :: RCValue -> Store -> RC [RCValue]        -- deref an array handle
arrayElems (RVBox a) s = do
  c <- deref a s
  case cNode c of
    NArray vs -> pure vs
    _         -> throwE (PrimError (Tx.pack "Array: not an array"))
arrayElems _ _ = throwE (PrimError (Tx.pack "Array: not an array"))
```

- [ ] **Step 4: Implement the prims** (exact RC sequences — the soundness core):

```haskell
arrayNew = RCPrim PN.arrayNewName 2 [] $ \args s -> case args of
  [kv, v] -> do
    k <- liftRC (asIndex kv)
    if k <= 0
      then do s1 <- dropValue v s
              (a, s2) <- alloc (NArray []) s1
              pure (PRDone (RVBox a), s2)
      else do s1 <- dupN (k - 1) v s                       -- array owns k refs to v; we have 1
              (a, s2) <- alloc (NArray (replicate k v)) s1
              pure (PRDone (RVBox a), s2)
  _ -> throwE (ArityError (Tx.pack "Array.new"))

arrayLength = RCPrim PN.arrayLengthName 1 [] $ \args s -> case args of
  [arr@(RVBox a)] -> do
    vs <- arrayElems arr s
    s1 <- dropAddr a s                                     -- consume the array
    pure (PRDone (RVLit (LInt (toInteger (length vs)))), s1)
  _ -> throwE (ArityError (Tx.pack "Array.length"))

arrayIndex = RCPrim PN.arrayIndexName 2 [] $ \args s -> case args of
  [arr@(RVBox a), iv] -> do
    i  <- liftRC (asIndex iv)
    vs <- arrayElems arr s
    case atIndex i vs of
      Nothing -> throwE (PrimError (Tx.pack "Array.index: out of bounds"))
      Just el -> do s1 <- dupValue el s                    -- result owns the element
                    s2 <- dropAddr a s1                    -- consume the array (cascade frees the rest)
                    pure (PRDone el, s2)
  _ -> throwE (ArityError (Tx.pack "Array.index"))

arraySet = RCPrim PN.arraySetName 3 [] $ \args s -> case args of
  [arr@(RVBox a), iv, v] -> do
    i  <- liftRC (asIndex iv)
    vs <- arrayElems arr s
    if i < 0 || i >= length vs
      then throwE (PrimError (Tx.pack "Array.set: out of bounds"))
      else do
        let new = [ if j == i then v else el | (j, el) <- zip [0 ..] vs ]
        s1 <- foldM (\st (j, el) -> if j == i then pure st else dupValue el st)
                    s (zip [0 :: Int ..] vs)               -- dup survivors (j /= i)
        (na, s2) <- alloc (NArray new) s1
        s3 <- dropAddr a s2                                -- consume input; cascade drops old arr[i]
        pure (PRDone (RVBox na), s3)
  _ -> throwE (ArityError (Tx.pack "Array.set"))

arrayResize = RCPrim PN.arrayResizeName 3 [] $ \args s -> case args of
  [arr@(RVBox a), mv, fill] -> do
    m  <- liftRC (asIndex mv)
    vs <- arrayElems arr s
    let n    = length vs
        t    = max 0 (min m n)
        k    = max 0 (m - n)
        kept = take t vs
        new  = kept ++ replicate k fill
    s1 <- foldM (flip dupValue) s kept                     -- dup kept survivors
    s2 <- if k <= 0 then dropValue fill s1 else dupN (k - 1) fill s1
    (na, s3) <- alloc (NArray new) s2
    s4 <- dropAddr a s3                                    -- cascade: kept net 0, truncated tail released
    pure (PRDone (RVBox na), s4)
  _ -> throwE (ArityError (Tx.pack "Array.resize"))

-- fromList / toList walk the "Cons"/"Nil" spine (confirmed names; Nil may be an Inline immediate,
-- which deref synthesizes to NCon "Nil" []).
arrayFromList = RCPrim PN.arrayFromListName 1 [] $ \args s -> case args of
  [xs] -> do
    (elems, s1) <- collectList xs s                        -- dup each head into the array
    (na, s2)    <- alloc (NArray elems) s1
    s3          <- dropValue xs s2                         -- drop list head; cascade frees spine + orig refs
    pure (PRDone (RVBox na), s3)
  _ -> throwE (ArityError (Tx.pack "Array.fromList"))

arrayToList = RCPrim PN.arrayToListName 1 [] $ \args s -> case args of
  [arr@(RVBox a)] -> do
    vs        <- arrayElems arr s
    (lst, s1) <- buildList vs s                            -- dup each element into a fresh Cons
    s2        <- dropAddr a s1                             -- cascade releases arr's element refs + cell
    pure (PRDone lst, s2)
  _ -> throwE (ArityError (Tx.pack "Array.toList"))

-- collectList: walk Cons/Nil, dup each head so the array owns its own ref.
collectList :: RCValue -> Store -> RC ([RCValue], Store)
collectList v s = case v of
  RVBox a -> do
    c <- deref a s
    case cNode c of
      NCon con [h, t] | con == Tx.pack "Cons" -> do
        s1 <- dupValue h s
        (rest, s2) <- collectList t s1
        pure (h : rest, s2)
      NCon con _ | con == Tx.pack "Nil" -> pure ([], s)
      _ -> throwE (PrimError (Tx.pack "Array.fromList: not a list"))
  _ -> throwE (PrimError (Tx.pack "Array.fromList: not a list"))

-- buildList: foldr, dup each element into a Cons cell; Nil is alloc (NCon "Nil" []) -> Inline (no alloc).
buildList :: [RCValue] -> Store -> RC (RCValue, Store)
buildList vs s0 = do
  (nil, s1) <- alloc (NCon (Tx.pack "Nil") []) s0
  go vs (RVBox nil, s1)
  where
    go []       acc        = pure acc
    go (x : xs) (tl, st)   = do
      (rest, st1) <- go xs (tl, st)
      st2 <- dupValue x st1
      (cell, st3) <- alloc (NCon (Tx.pack "Cons") [x, rest]) st2
      pure (RVBox cell, st3)
```

  Then add all seven to the `prims` list. NOTE: verify `valueChildren`, `liftRC`, `foldM` (`Control.Monad`) are imported in `Prim.hs`; add imports as needed.

- [ ] **Step 5: Run → pass; commit.** `cabal test wok-tests` → green. `git add -A && git commit -m "feat(rc): Array prims new/fromList/toList/index/length/set/resize (Slice A task 3)"`

---

### Task 4: `Std.Array` prelude + wiring (end-to-end)

**Goal:** Surface the ops to user code: a `Std.Array` prelude module whose externs resolve to the prims, loaded by the compiler. A `.wok` program can `import Std.Array`, build/index/update an array, and run.

**Files:**
- Create: `prelude/Std/Array.wok` — the module + externs (mirror `Std/Base.wok` extern syntax: bare names).
- Modify: `src/Wok/Prelude.hs` — add `stdArrayName`/`stdArraySource` loaders (mirror `stdControl*`).
- Modify: `wok.cabal` — register `prelude/Std/Array.wok` in `data-files` (and ensure `Std.Array` is loaded alongside `Std.Base`/`Std.Control` wherever the prelude set is assembled — follow how `Std.Control` is wired).
- Test: an end-to-end corpus `.wok` under a new `test/rc-array/` exercising each op + expected output.

**Acceptance Criteria:**
- [ ] `prelude/Std/Array.wok` declares `Array a` (as an extern/opaque type or via the registered tycon) and the seven externs with spec §3 signatures; the prim table keys them by `(Std.Array, <name>)`.
- [ ] A `.wok` program `import`ing `Std.Array` that does `new`/`set`/`index`/`length`/`fromList`/`toList`/`resize` type-checks, runs, and prints the expected values.
- [ ] Build green; existing tests unaffected.

**Verify:** `cabal test wok-tests` → the rc-array end-to-end test passes; 1282 still green.

**Steps:**

- [ ] **Step 1: Failing e2e test.** Add `test/rc-array/01-basic.wok` (build an array, set a slot, index it, print) and wire it into `Spec.hs` the way the existing `rc-examples`/`rc-c-backend` corpus is driven. Expected stdout asserted. Run → fail (no `Std.Array`).
- [ ] **Step 2: Write the prelude.** `prelude/Std/Array.wok`:

```
module Std.Array
import Std.Base

extern type Array a

extern new      : U64 -> a -> Array a
extern fromList : [a] -> Array a
extern toList   : Array a -> [a]
extern index    : Array a -> U64 -> a
extern length   : Array a -> U64
extern set      : Array a -> U64 -> a -> Array a
extern resize   : Array a -> U64 -> a -> Array a
```

  (If `extern type Array a` is not accepted syntax, follow whatever the registered tycon needs — the tycon is already known from Task 2; the externs only need to reference it. Match the exact extern-keying convention so the prim names line up with `PrimNames`.)

- [ ] **Step 3: Wire the loader.** `Prelude.hs`: add `stdArrayName = Tx.pack "Std.Array"` and `stdArraySource` reading `prelude/Std/Array.wok` (mirror `stdControlSource`). Register the data-file in `wok.cabal`. Ensure the module is loaded into the prelude set (follow `Std.Control`).
- [ ] **Step 4: Run → pass.** `cabal test wok-tests` → e2e passes, 1282 green.
- [ ] **Step 5: Commit.** `git add -A && git commit -m "feat(prelude): Std.Array module + wiring (Slice A task 4)"`

---

### Task 5: QuickCheck properties + differential-oracle corpus

**Goal:** Pin the semantics with properties and prove byte+stat parity on both backends.

**Files:**
- Test: QuickCheck property module (mirror existing QuickCheck tests); corpus `.wok` under `test/rc-array/` run through the differential oracle (both `AbstractHeap` and `CHeap` backends), following the `test/rc-c-backend/` harness.

**Acceptance Criteria:**
- [ ] Properties hold: `toList (fromList xs) == xs`; `index (set a i v) i == v`; `j /= i ==> index (set a i v) j == index a j`; `length (new k v) == k`; `length (set a i v) == length a`; `length (resize a m f) == m`; grow-then-index-tail yields the fill; out-of-bounds raises.
- [ ] Each corpus program produces **byte-identical output AND matching `alloc`/`free`/`peak`** on both backends, matching the spec §4 alloc table; heap returns to baseline (no leak, no double-free) at program end.
- [ ] Full suite green; the C-backend / sanitizer harness (unchanged in Slice A) still passes.

**Verify:** `cabal test wok-tests` → all array properties + oracle corpus pass; total = 1282 + new, all green. If a sanitizer script exists (`scripts/asan-runtime.sh`), it is clean.

**Steps:**

- [ ] **Step 1: Properties.** Add the QuickCheck properties above (generate small element types — `U64`, `Bool` (immediate), `String` (boxed) — to cover all three slot buckets). Run → some fail if any accounting is off; fix in Task 3/this task.
- [ ] **Step 2: Oracle corpus.** Add `test/rc-array/*.wok` covering each op and the §4 alloc deltas; assert both backends are byte-identical and stat-identical and return to baseline. Mirror `test/rc-c-backend/` driving.
- [ ] **Step 3: Run → pass.** `cabal test wok-tests` → green.
- [ ] **Step 4: Commit.** `git add -A && git commit -m "test(rc): Array properties + differential-oracle corpus (Slice A task 5)"`

---

## Self-review notes

- **Spec coverage:** §2 node → T1; §3 type+prelude → T2,T4; §4 ops+RC → T3 (+ properties T5); §5 bounds → T3; §6 cascade → T1; §7 oracle → T5; §8 tests → T1,T3,T5. No gaps.
- **Type consistency:** `NArray`, `arrayElems`, `dupValue`/`dropValue`/`dupN`, `asIndex`, `atIndex`, `collectList`, `buildList`, `PN.array*Name` used consistently across tasks.
- **Verify the two assumptions during T3/T4:** (a) list ctor names `"Cons"`/`"Nil"` (confirmed at `Value.hs:1224`, `Elaborate.hs:202`); (b) the exact extern-keying / surface-name convention (mirror `Std.Control`). Neither changes the RC accounting.
