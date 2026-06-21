# C Runtime Allocator under the RC Interpreter (NCon-first) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `NCon` constructor cells of the RC interpreter onto a real `malloc`-backed C heap reached over FFI, with the Haskell host driving the free-cascade, validated bit-for-bit against the retained abstract-store interpreter.

**Architecture:** A tiny "byte-dumb" C runtime (`runtime/wok_rc.c`) owns allocation, the refcount, and the raw field slots for one node kind (`NCon`); the Haskell RC interpreter keeps every structured node (closures, continuations) on its existing `IntMap` heap and keeps driving the recursive free (so cross-heap edges route themselves). The RC interpreter is first threaded into `IO` honestly to its public boundary (no `unsafePerformIO`); then a `HeapBackend` selector in `Store` lets the abstract and C heaps coexist so a differential oracle can diff result + allocation stats over the whole corpus.

**Tech Stack:** Haskell (GHC2024, `cabal`, `tasty`/`Hspec`/`QuickCheck`), C17 (`cabal` `c-sources`, held to `HPC-C.md`), GHC FFI (`foreign import ccall unsafe`).

**User decisions (already made):**
- "prove correctness first then we try to compact it" — slice 1 keeps the 16-byte header/slot; compaction is a later slice.
- Decision 1: slice-1 allocator is plain `malloc`/`free` (isolate the RC cascade as the variable under test); wok-specific pool / mimalloc deferred.
- Decision 2: `scan_count` deferred into the layout-compaction slice.
- Sequencing: `IO` threaded honestly to the public boundary; no `unsafePerformIO`; per-run `WokHeap*` context, no global state.
- C standard C17; fallback boundary keeps `LStr`/bignum/`RVRecMember`/`RVInst`-bearing constructors on the Haskell heap.

**Spec:** `docs/superpowers/specs/2026-06-21-c-runtime-allocator-ncon-design.md`
**Research:** `docs/superpowers/2026-06-21-mimalloc-koka-allocator-research.md`, `docs/superpowers/2026-06-21-packed-data-local-research.md`

---

## File Structure

| File | Responsibility | Tasks |
| --- | --- | --- |
| `src/Wok/Interp/RC/Value.hs` | `RC` monad alias; `Store`/`Cell`/`Node`/`RCValue`; `Addr` sum; `HeapBackend`; `alloc`/`incref`/`dropAddr`/`deref`; slot encode/decode | 0, 2 |
| `src/Wok/Interp/RC/Machine.hs` | `transition`/`stepRC`/`returnToRC`/`runRC`/`runExprRC`/`runModuleRC*`; `NCon` build site | 0, 2 |
| `src/Wok/Interp/RC/Prim.hs` | `rcPrimTable`, `rcDup`/`rcDrop`, nullary-`NCon` build site | 0, 2 |
| `src/Wok/Interp/RC/Heap.hs` | **new** — raw FFI to the C runtime; opaque `WokObj`/`WokHeap` phantom types; slot-tag constants (no dependency on `RCValue`) | 1 |
| `runtime/wok_rc.h` | **new** — the C ABI (struct layout + function declarations) | 1 |
| `runtime/wok_rc.c` | **new** — the byte-dumb allocator implementation | 1 |
| `runtime/test/wok_rc_test.c` | **new** — standalone C unit test (sanitizer target) | 1 |
| `scripts/asan-runtime.sh` | **new** — compile+run the C test under ASan/UBSan/LSan | 1 |
| `wok.cabal` | add `c-sources`/`include-dirs`/`cc-options` + the `Wok.Interp.RC.Heap` module | 1 |
| `app/Main.hs` | adapt the `runModuleRC` call to `IO`; select the C backend | 0, 2 |
| `test/Spec.hs` | adapt RC call sites to `IO`; differential oracle + targeted tests | 0, 3 |

**Module dependency note (avoids an import cycle):** `Wok.Interp.RC.Heap` depends on nothing from `Wok.Interp.RC.Value` (it exposes only raw FFI + opaque `Ptr` types + `Word64` slot-tag constants). `Value` imports `Heap` for the `Ptr WokObj`/`Ptr WokHeap` types and owns the `RCValue <-> slot` encode/decode (because that needs `RCValue`).

---

## Task 0: Thread `IO` through the RC interpreter to its public boundary

**Goal:** Move the entire RC interpreter into `ExceptT RuntimeError IO`, with the heap still the pure `IntMap` — no C, no behavior change — so the FFI calls added in Task 2 have a home and the IO refactor is proven green in isolation.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` (add `RC` alias; lift `alloc`/`incref`/`dropAddr`/`deref`/`writeNode`/`writeStatic`/`mkClosure` callers as needed)
- Modify: `src/Wok/Interp/RC/Machine.hs` (`transition`/`stepRC`/`returnToRC`/`runRC`/`runExprRC`/`runModuleRC`/`runModuleRCUnchecked`)
- Modify: `src/Wok/Interp/RC/Prim.hs` (`RCPrim` `rpFn` field type; `rcDup`/`rcDrop` and all prim bodies)
- Modify: `app/Main.hs:95` (the `runModuleRC` call site)
- Modify: `test/Spec.hs` (every `runModuleRC` / `runModuleRCUnchecked` / `runExprRC` call site)

**Acceptance Criteria:**
- [ ] `alloc`, `incref`, `dropAddr`, `deref`, `transition`, `stepRC`, `returnToRC`, `runRC`, `runExprRC` are typed in `RC = ExceptT RuntimeError IO`.
- [ ] `runModuleRC`, `runModuleRCUnchecked :: CoreModule -> IO (Either RuntimeError RCRun)`; `runExprRC :: ... -> IO (Either RuntimeError (RCValue, Store))`.
- [ ] `RCPrim.rpFn :: [RCValue] -> Store -> RC (RCPrimResult, Store)`.
- [ ] No `unsafePerformIO` anywhere in `src/Wok/Interp/RC/`.
- [ ] Heap is still the `IntMap` (`alloc`/`incref`/`dropAddr` bodies unchanged except for monad wrapping); zero behavior change.

**Verify:** `cabal test 2>&1 | tail -20` → full suite green (same pass count as before the change).

**Steps:**

- [ ] **Step 1: Add the `RC` monad alias and helpers in `Value.hs`.** Add to the export list and module body:

```haskell
import Control.Monad.Trans.Except (ExceptT, except, throwE)
import Control.Monad.IO.Class (liftIO)  -- used in Task 2

-- | The RC interpreter monad: explicit error over IO. IO is required because the
-- (Task 2) C allocator is genuinely effectful; threading it honestly to the
-- public boundary is the sanctioned design (no unsafePerformIO). See spec §5.
type RC a = ExceptT RuntimeError IO a

-- | Lift an existing pure @Either RuntimeError@ result into 'RC'.
liftRC :: Either RuntimeError a -> RC a
liftRC = except
```

- [ ] **Step 2: Lift the store ops in `Value.hs` to `RC`, bodies unchanged.** Mechanical rule applied to `alloc`/`incref`/`dropAddr`/`deref`/`writeNode`/`writeStatic` and any helper threading `Store`:
  - signature `... -> Either RuntimeError a` becomes `... -> RC a`; a total `... -> (a, Store)` (like `alloc`) becomes `... -> RC (a, Store)`.
  - `Right x` becomes `pure x`; `Left e` becomes `throwE e`; a pure tuple return becomes `pure (a, s)`.
  - a nested call `s' <- incref a s` stays as-is (now both are `RC`); a call to a still-pure `Either` helper becomes `x <- liftRC (helper ...)`.

  Concretely, `incref` and `dropAddr` and `alloc` become:

```haskell
incref :: Addr -> Store -> RC Store
incref a s
  | isStaticAddr a = pure s
  | otherwise = do
      c <- liftRC (deref' a s)            -- deref' = the pure IntMap lookup (renamed; see note)
      pure s { stCells = IM.insert a c { cRc = cRc c + 1 } (stCells s) }

alloc :: Node -> Store -> RC (Addr, Store)
alloc n s =
  let a = stNext s; st = stStats s; live = stLive st + 1
      st' = st { stAllocs = stAllocs st + 1, stLive = live, stPeak = max (stPeak st) live }
  in pure ( a, s { stCells = IM.insert a (Cell 1 n) (stCells s), stNext = a + 1, stStats = st' } )
```

  Note: keep the pure `IntMap` body of `deref`/`dropAddr` available (e.g. inline) — only the *outer* type becomes `RC`; the `IntMap`/`IntSet` logic is byte-for-byte the same. `dropAddr`'s worklist `go` becomes `RC`-returning but its branches are unchanged except `Right`→`pure`, `Left`→`throwE`.

- [ ] **Step 3: Lift `Machine.hs` driver chain to `RC`.** Change signatures and wrap returns:

```haskell
transition  :: RCPrimTable -> RCConfig -> RC RCConfig
stepRC      :: RCPrimTable -> RCConfig -> RC RCStep
returnToRC  :: RCPrimTable -> RCValue -> RCKont -> Store -> RC RCConfig
runRC       :: RCPrimTable -> RCConfig -> RC (RCValue, Store)
runExprRC   :: RCPrimTable -> REnv -> Store -> Expr -> IO (Either RuntimeError (RCValue, Store))
```

  Inside `transition`/`returnToRC`, every `let (a, s') = alloc n s` becomes `(a, s') <- alloc n s` (now `RC`), and every `s' <- dropAddr a s` / `s' <- incref a s` stays (now `RC`). `Right x` → `pure x`, `Left e` → `throwE e`. `runExprRC` runs the loop in `RC` then `runExceptT`s at the boundary:

```haskell
runExprRC prims env s e = runExceptT $ do
  cfg0 <- buildInitialConfig prims env s e   -- whatever the current first-config construction is
  runRC prims cfg0
```

- [ ] **Step 4: Lift `Prim.hs`.** Change the field type and every prim body:

```haskell
-- in Value.hs (RCPrim definition):
data RCPrim = RCPrim
  { rpName  :: Text
  , rpArity :: Int
  , rpArgs  :: [RCValue]
  , rpFn    :: [RCValue] -> Store -> RC (RCPrimResult, Store)
  }
```

  Then in `Prim.hs`, every handler's `\args s -> ... Right (..., s')` becomes `\args s -> ... pure (..., s')`, `Left e` becomes `throwE e`, and inner `s' <- incref a s` / `s' <- dropAddr a s` stay (now `RC`). Example (`rcDup`):

```haskell
rcDup = RCPrim PN.rcDupName 1 [] $ \args s -> case args of
  [v@(RVBox a)]            -> do s' <- incref a s; pure (PRDone v, s')
  [v@(RVLit _)]            -> pure (PRDone v, s)
  [v@(RVRecMember _ _ e)]  -> do s' <- incref e s; pure (PRDone v, s')
  [v@(RVInst _ _)]         -> pure (PRDone v, s)
  _                        -> throwE (ArityError (Tx.pack "__rc_dup"))
```

- [ ] **Step 5: Convert the entry points to return `IO (Either …)`.** `runModuleRCUnchecked` runs its `do` in `RC` and `runExceptT`s; `runModuleRC` becomes `IO`:

```haskell
runModuleRC :: CoreModule -> IO (Either RuntimeError RCRun)
runModuleRC cm = case firstOrderNoHandlerViolations cm of
  (v:vs) -> pure (Left (PrimError (Tx.pack "RC interpreter: ...unsupported feature:\n"
                       <> Tx.intercalate (Tx.pack "\n") (v:vs))))
  []     -> runModuleRCUnchecked cm

runModuleRCUnchecked :: CoreModule -> IO (Either RuntimeError RCRun)
runModuleRCUnchecked (CoreModule binds) = runExceptT $ do
  let (knotEnv, addrs, s0) = reserveStatic binds
  (staticEnv, s1) <- installBinds rcPrimTable knotEnv binds s0 knotEnv addrs  -- now RC-typed
  let baseline = stLive (stStats s1)
  case [ tb | tb@(TopBind n _ _) <- binds, nameHint n == Tx.pack "main" ] of
    (TopBind _ [] body : _) -> do
      (v, s2) <- ExceptT (runExprRC rcPrimTable staticEnv s1 body)
      txt <- liftRC (renderRCValue s2 v)
      s3  <- foldM (flip dropAddr) s2 (valueChildren v)
      pure (RCRun txt (stStats s3) baseline)
    (TopBind{} : _) -> throwE (ArityError (Tx.pack "main must take no arguments"))
    []              -> throwE (UnboundVar (Tx.pack "main"))
```

- [ ] **Step 6: Adapt `app/Main.hs:95`.** `case RCM.runModuleRC … of` becomes:

```haskell
          rcResult <- RCM.runModuleRC (Perceus.insertRC (pruneToReachable cm))
          case rcResult of
            -- ... existing Left/Right arms unchanged ...
```

- [ ] **Step 7: Adapt every `test/Spec.hs` RC call site.** Each is already inside a tasty `testCase "..." $ do` block, so the rewrite is mechanical: `case RCM.runModuleRC x of` → `RCM.runModuleRC x >>= \case`, and `case (Interp.runModule cm, RCM.runModuleRC y) of (ref, rc) ->` → `do rc <- RCM.runModuleRC y; case (Interp.runModule cm, rc) of …`. Same for `runModuleRCUnchecked` and `runExprRC`. Add `{-# LANGUAGE LambdaCase #-}` to `test/Spec.hs` if not present.

- [ ] **Step 8: Build and run the full suite.**

Run: `cabal build all && cabal test 2>&1 | tail -20`
Expected: compiles; full suite green with the same number of passing tests as before Task 0 (behavior-preserving).

- [ ] **Step 9: Commit.**

```bash
git add src/Wok/Interp/RC/Value.hs src/Wok/Interp/RC/Machine.hs src/Wok/Interp/RC/Prim.hs app/Main.hs test/Spec.hs
git commit -m "refactor(rc): thread IO through the RC interpreter to the public boundary (no behavior change)"
```

---

## Task 1: The C runtime + build wiring + FFI bindings + sanitizer test

**Goal:** A standalone, byte-dumb C allocator implementing the spec §4 ABI, compiled into the library, with raw Haskell FFI bindings and both a Haskell round-trip test and a sanitizer-clean standalone C test.

**Files:**
- Create: `runtime/wok_rc.h`, `runtime/wok_rc.c`, `runtime/test/wok_rc_test.c`, `scripts/asan-runtime.sh`
- Create: `src/Wok/Interp/RC/Heap.hs`
- Modify: `wok.cabal` (the hand-written `library` stanza)
- Test: a new `Wok.Interp.RC.Heap` round-trip group in `test/Spec.hs`

**Acceptance Criteria:**
- [ ] `runtime/wok_rc.c` compiles under the `HPC-C.md` flag wall (`-std=c17 -O3 -fstrict-aliasing -Wstrict-aliasing=2 -fwrapv -Werror -Wall -Wextra -Wpedantic -Wconversion -Wdouble-promotion -Wstrict-prototypes -Wformat-security`) with zero warnings.
- [ ] `_Static_assert(sizeof(WokSlot) == 16)` and `_Static_assert(sizeof(WokObj) == 16)` hold.
- [ ] FFI round-trip test: alloc a 2-slot cell, set/get both slots, `wok_dup` then `wok_dec` returns the right counts, `wok_free`, and stats report `allocs==1, frees==1, live==0, peak==1`.
- [ ] `scripts/asan-runtime.sh` exits 0 (ASan + UBSan + LSan clean).

**Verify:** `cabal test --test-options='-p "/wok-rc-heap/"' 2>&1 | tail -10` → green; and `bash scripts/asan-runtime.sh` → `OK` exit 0.

**Steps:**

- [ ] **Step 1: Write `runtime/wok_rc.h`.**

```c
#ifndef WOK_RC_H
#define WOK_RC_H
#include <stdint.h>
#include <stddef.h>

#if defined(__GNUC__) || defined(__clang__)
#  define WOK_UNLIKELY(x) __builtin_expect(!!(x), 0)
#else
#  define WOK_UNLIKELY(x) (x)
#endif

typedef struct WokSlot { uint64_t tag; uint64_t payload; } WokSlot;

typedef struct WokObj {
    uint64_t rc;
    uint32_t tag;
    uint32_t arity;
    WokSlot  slots[];   /* flexible array member, `arity` entries */
} WokObj;

typedef struct WokHeap WokHeap;   /* opaque per-run context */

WokHeap* wok_heap_new(void);
void     wok_heap_free(WokHeap* h);                 /* warns if live != 0 */
WokObj*  wok_alloc(WokHeap* h, uint32_t tag, uint32_t arity);
void     wok_dup(WokObj* p);
uint64_t wok_dec(WokObj* p);                        /* rc--, returns NEW rc; no free */
void     wok_free(WokHeap* h, WokObj* p);
void     wok_slot_set(WokObj* p, uint32_t i, uint64_t tag, uint64_t payload);
void     wok_slot_get(const WokObj* p, uint32_t i, uint64_t* tag, uint64_t* payload);
uint32_t wok_tag(const WokObj* p);
uint32_t wok_arity(const WokObj* p);

uint64_t wok_stat_allocs(const WokHeap* h);
uint64_t wok_stat_frees(const WokHeap* h);
int64_t  wok_stat_live(const WokHeap* h);
int64_t  wok_stat_peak(const WokHeap* h);

#endif /* WOK_RC_H */
```

- [ ] **Step 2: Write `runtime/wok_rc.c`.** Byte-dumb: it never follows a slot payload as a pointer (the Haskell host drives the cascade), so there is no strict-aliasing surface in slice 1.

```c
#include "wok_rc.h"
#include <stdlib.h>
#include <stdio.h>

_Static_assert(sizeof(WokSlot) == 16, "WokSlot must be 16 bytes");
_Static_assert(sizeof(WokObj)  == 16, "WokObj header must be 16 bytes");

struct WokHeap {
    uint64_t allocs;
    uint64_t frees;
    int64_t  live;
    int64_t  peak;
};

WokHeap* wok_heap_new(void) {
    WokHeap* h = (WokHeap*)calloc(1, sizeof(WokHeap));
    if (WOK_UNLIKELY(h == NULL)) { abort(); }
    return h;
}

void wok_heap_free(WokHeap* h) {
    if (WOK_UNLIKELY(h->live != 0)) {
        fprintf(stderr, "wok_rc: heap freed with %lld live cells (leak)\n", (long long)h->live);
    }
    free(h);
}

WokObj* wok_alloc(WokHeap* h, uint32_t tag, uint32_t arity) {
    size_t bytes = sizeof(WokObj) + (size_t)arity * sizeof(WokSlot);
    WokObj* p = (WokObj*)malloc(bytes);
    if (WOK_UNLIKELY(p == NULL)) { abort(); }
    p->rc = 1u;
    p->tag = tag;
    p->arity = arity;
    h->allocs += 1u;
    h->live   += 1;
    if (h->live > h->peak) { h->peak = h->live; }
    return p;
}

void wok_dup(WokObj* p) { p->rc += 1u; }

uint64_t wok_dec(WokObj* p) {
    if (WOK_UNLIKELY(p->rc == 0u)) {
        fprintf(stderr, "wok_rc: wok_dec on rc==0 (double-free)\n");
        abort();
    }
    p->rc -= 1u;
    return p->rc;
}

void wok_free(WokHeap* h, WokObj* p) {
    h->frees += 1u;
    h->live  -= 1;
    free(p);
}

void wok_slot_set(WokObj* p, uint32_t i, uint64_t tag, uint64_t payload) {
    p->slots[i].tag = tag;
    p->slots[i].payload = payload;
}

void wok_slot_get(const WokObj* p, uint32_t i, uint64_t* tag, uint64_t* payload) {
    *tag = p->slots[i].tag;
    *payload = p->slots[i].payload;
}

uint32_t wok_tag(const WokObj* p)   { return p->tag; }
uint32_t wok_arity(const WokObj* p) { return p->arity; }

uint64_t wok_stat_allocs(const WokHeap* h) { return h->allocs; }
uint64_t wok_stat_frees(const WokHeap* h)  { return h->frees; }
int64_t  wok_stat_live(const WokHeap* h)   { return h->live; }
int64_t  wok_stat_peak(const WokHeap* h)   { return h->peak; }
```

- [ ] **Step 3: Wire `wok.cabal`.** In the hand-written `library` stanza (the one with `import: strict`, NOT `library wok-generated`), add the new module to its module list (next to `Wok.Interp.RC.Value`) and add the C build fields:

```cabal
    c-sources:        runtime/wok_rc.c
    include-dirs:     runtime
    cc-options:       -std=c17 -O3 -fstrict-aliasing -Wstrict-aliasing=2 -fwrapv
                      -Werror -Wall -Wextra -Wpedantic -Wconversion
                      -Wdouble-promotion -Wstrict-prototypes -Wformat-security
```

- [ ] **Step 4: Write `src/Wok/Interp/RC/Heap.hs`** (raw FFI; no `RCValue` dependency):

```haskell
{-# LANGUAGE ForeignFunctionInterface #-}
module Wok.Interp.RC.Heap
  ( WokObj, WokHeap
  , wokHeapNew, wokHeapFree
  , wokAlloc, wokDup, wokDec, wokFree
  , wokSlotSet, wokSlotGet, wokTag, wokArity
  , wokStatAllocs, wokStatFrees, wokStatLive, wokStatPeak
  , wsLitInt, wsLitChar, wsLitUnit, wsCBox, wsHBox
  ) where

import Foreign.Ptr (Ptr)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Storable (peek)
import Data.Word (Word32, Word64)
import Data.Int (Int64)

data WokObj   -- phantom: pointer to a C cell
data WokHeap  -- phantom: pointer to a per-run heap context

-- Slot tags (must mirror the §5 encoding; kept here as the single source).
wsLitInt, wsLitChar, wsLitUnit, wsCBox, wsHBox :: Word64
wsLitInt = 0; wsLitChar = 1; wsLitUnit = 2; wsCBox = 3; wsHBox = 4

foreign import ccall unsafe "wok_heap_new"  wokHeapNew  :: IO (Ptr WokHeap)
foreign import ccall unsafe "wok_heap_free" wokHeapFree :: Ptr WokHeap -> IO ()
foreign import ccall unsafe "wok_alloc"     wokAlloc    :: Ptr WokHeap -> Word32 -> Word32 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_dup"       wokDup      :: Ptr WokObj -> IO ()
foreign import ccall unsafe "wok_dec"       wokDec      :: Ptr WokObj -> IO Word64
foreign import ccall unsafe "wok_free"      wokFree     :: Ptr WokHeap -> Ptr WokObj -> IO ()
foreign import ccall unsafe "wok_slot_set"  wokSlotSet  :: Ptr WokObj -> Word32 -> Word64 -> Word64 -> IO ()
foreign import ccall unsafe "wok_tag"       wokTag      :: Ptr WokObj -> IO Word32
foreign import ccall unsafe "wok_arity"     wokArity    :: Ptr WokObj -> IO Word32
foreign import ccall unsafe "wok_stat_allocs" wokStatAllocs :: Ptr WokHeap -> IO Word64
foreign import ccall unsafe "wok_stat_frees"  wokStatFrees  :: Ptr WokHeap -> IO Word64
foreign import ccall unsafe "wok_stat_live"   wokStatLive   :: Ptr WokHeap -> IO Int64
foreign import ccall unsafe "wok_stat_peak"   wokStatPeak   :: Ptr WokHeap -> IO Int64

foreign import ccall unsafe "wok_slot_get"
  c_wok_slot_get :: Ptr WokObj -> Word32 -> Ptr Word64 -> Ptr Word64 -> IO ()

-- | Read slot @i@ as @(tag, payload)@ (the C side uses out-params).
wokSlotGet :: Ptr WokObj -> Word32 -> IO (Word64, Word64)
wokSlotGet p i = alloca $ \tp -> alloca $ \pp -> do
  c_wok_slot_get p i tp pp
  (,) <$> peek tp <*> peek pp
```

- [ ] **Step 5: Write the Hspec/tasty round-trip test** in `test/Spec.hs` (new group `wok-rc-heap`). Place it in the existing tasty tree alongside the other RC groups:

```haskell
import qualified Wok.Interp.RC.Heap as Heap
import Foreign.Ptr (nullPtr)

wokRcHeapTests :: TestTree
wokRcHeapTests = testGroup "wok-rc-heap (raw C runtime FFI)"
  [ testCase "alloc/set/get/dup/dec/free round-trip + stats" $ do
      h <- Heap.wokHeapNew
      p <- Heap.wokAlloc h 7 2                       -- tag=7, arity=2
      Heap.wokSlotSet p 0 Heap.wsLitInt 42
      Heap.wokSlotSet p 1 Heap.wsLitUnit 0
      t  <- Heap.wokTag p
      ar <- Heap.wokArity p
      s0 <- Heap.wokSlotGet p 0
      s1 <- Heap.wokSlotGet p 1
      assertEqual "tag" 7 t
      assertEqual "arity" 2 ar
      assertEqual "slot0" (Heap.wsLitInt, 42) s0
      assertEqual "slot1" (Heap.wsLitUnit, 0) s1
      Heap.wokDup p
      rc1 <- Heap.wokDec p                            -- 2 -> 1
      assertEqual "rc after dup+dec" 1 rc1
      rc0 <- Heap.wokDec p                            -- 1 -> 0
      assertEqual "rc at zero" 0 rc0
      Heap.wokFree h p
      allocs <- Heap.wokStatAllocs h
      frees  <- Heap.wokStatFrees h
      live   <- Heap.wokStatLive h
      peak   <- Heap.wokStatPeak h
      assertEqual "allocs" 1 allocs
      assertEqual "frees"  1 frees
      assertEqual "live"   0 live
      assertEqual "peak"   1 peak
      Heap.wokHeapFree h
  ]
```
  Add `wokRcHeapTests` to the top-level tasty `testGroup` list.

- [ ] **Step 6: Write `runtime/test/wok_rc_test.c`** (standalone sanitizer target — same scenario, no Haskell):

```c
#include "wok_rc.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    WokHeap* h = wok_heap_new();
    WokObj* p = wok_alloc(h, 7u, 2u);
    wok_slot_set(p, 0u, 0u /*WS_LIT_INT*/, 42u);
    wok_slot_set(p, 1u, 2u /*WS_LIT_UNIT*/, 0u);
    assert(wok_tag(p) == 7u);
    assert(wok_arity(p) == 2u);
    uint64_t t, v;
    wok_slot_get(p, 0u, &t, &v);
    assert(t == 0u && v == 42u);
    wok_dup(p);
    assert(wok_dec(p) == 1u);
    assert(wok_dec(p) == 0u);
    wok_free(h, p);
    assert(wok_stat_allocs(h) == 1u);
    assert(wok_stat_frees(h) == 1u);
    assert(wok_stat_live(h) == 0);
    assert(wok_stat_peak(h) == 1);
    wok_heap_free(h);
    printf("OK\n");
    return 0;
}
```

- [ ] **Step 7: Write `scripts/asan-runtime.sh`.**

```bash
#!/usr/bin/env bash
set -euo pipefail
cc -std=c17 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
   -Wall -Wextra -Wpedantic -Iruntime \
   runtime/wok_rc.c runtime/test/wok_rc_test.c -o /tmp/wok_rc_test
ASAN_OPTIONS=detect_leaks=1 /tmp/wok_rc_test
```
  Then `chmod +x scripts/asan-runtime.sh`.

- [ ] **Step 8: Build, test, sanitize.**

Run: `cabal build all && cabal test --test-options='-p "/wok-rc-heap/"' 2>&1 | tail -10`
Expected: the `wok-rc-heap` group passes.
Run: `bash scripts/asan-runtime.sh`
Expected: prints `OK`, exit 0, no sanitizer report.

- [ ] **Step 9: Commit.**

```bash
git add runtime/ scripts/asan-runtime.sh src/Wok/Interp/RC/Heap.hs wok.cabal test/Spec.hs
git commit -m "feat(rc): byte-dumb C allocator + FFI bindings + sanitizer test (HPC-C)"
```

---

## Task 2: Add the C-backed `NCon` path alongside the abstract store

**Goal:** Make `NCon` cells allocate in the C heap when the backend is `C` and all fields are encodable; teach `incref`/`dropAddr`/`deref` the `CAddr` path with the Haskell-driven cascade; keep the abstract path retained for the oracle.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` (`Addr` sum; `HeapBackend`; `Store` field; `isStaticAddr`; `alloc`/`incref`/`dropAddr`/`deref` backend branches; `encodeSlot`/`decodeSlot`; tag interning)
- Modify: `src/Wok/Interp/RC/Machine.hs` (the `NCon` build at `alloc (NCon c vs)`; pass interning through `Store`)
- Modify: `src/Wok/Interp/RC/Prim.hs` (the nullary `NCon` build at `alloc (NCon tag [])`)
- Modify: `app/Main.hs` (create a C `WokHeap` and select `CHeap` backend for the production run)

**Acceptance Criteria:**
- [ ] `data Addr = HAddr !Int | CAddr !(Ptr WokObj)`; `isStaticAddr (HAddr i) = i < 0`, `isStaticAddr (CAddr _) = False`.
- [ ] `Store` carries `stBackend :: HeapBackend` and a constructor-tag interning table; `data HeapBackend = AbstractHeap | CHeap !(Ptr WokHeap)`.
- [ ] With `CHeap`, an `NCon` all of whose fields are encodable allocates in C and is returned as `CAddr`; a non-encodable field makes the whole `NCon` fall back to `HAddr`.
- [ ] `deref (CAddr p)` reconstructs `NCon Text [RCValue]` from C; `incref`/`dropAddr` dispatch on `Addr`; the cascade on a freed C cell drops each counted child via the same `countedRefs` logic, routing `HAddr` children to the IntMap path and `CAddr` children to `wok_drop`.
- [ ] The whole existing corpus run through the `CHeap` backend produces byte-identical results (Task 3 formalizes the diff; this AC is "it runs and matches" on a spot check).

**Verify:** `cabal test 2>&1 | tail -20` → full suite green (the existing RC corpus tests now also exercise the C backend via the harness wired in Task 3; here, confirm no regression).

**Steps:**

- [ ] **Step 1: `Addr` becomes a sum** in `Value.hs`. Replace `type Addr = Int` with:

```haskell
import Wok.Interp.RC.Heap (WokObj, WokHeap)
import Foreign.Ptr (Ptr)

data Addr = HAddr !Int | CAddr !(Ptr WokObj)
  deriving (Eq, Ord, Show)

isStaticAddr :: Addr -> Bool
isStaticAddr (HAddr i) = i < 0
isStaticAddr (CAddr _) = False
```
  Then follow the compiler: every `IM.lookup a`, `IM.insert a`, `IS.member a`, `IS.insert a`, and `stNext`/`stNextStatic` use must pattern-match `HAddr i` to recover the `Int` key (C cells never enter the `IntMap`/`IntSet`). `valueChildren`/`countedRefs`/`RVBox`/`RVRecMember` are unchanged (they carry `Addr` opaquely).

- [ ] **Step 2: Add the backend + interning to `Store`** in `Value.hs`:

```haskell
data HeapBackend = AbstractHeap | CHeap !(Ptr WokHeap)

data Store = Store
  { stCells      :: IntMap Cell
  , stNext       :: Int
  , stNextStatic :: Int
  , stDead       :: IntSet
  , stStats      :: Stats
  , stBackend    :: HeapBackend          -- NEW
  , stTagIntern  :: (Map Text Word32, IntMap Text)  -- NEW: name<->id bijection
  }
```
  Update `emptyStore` to `AbstractHeap` + empty interning. Add `internTag :: Text -> Store -> (Word32, Store)` (assign the next free id on first sight) and `tagName :: Word32 -> Store -> Text` (reverse lookup). Keep `stStats` aggregated across both heaps so totals are directly comparable: when allocating in C, also bump `stStats` so abstract-vs-C totals line up.

- [ ] **Step 3: Slot encode/decode** in `Value.hs` (the §5 rule; `Nothing` = not encodable → fallback):

```haskell
import Data.Word (Word64, Word32)
import Foreign.Ptr (ptrToWordPtr, wordPtrToPtr, WordPtr(..))
import qualified Wok.Interp.RC.Heap as H
import Data.Bits (toIntegralSized)

encodeSlot :: RCValue -> Maybe (Word64, Word64)
encodeSlot (RVLit (LInt n))  = (\w -> (H.wsLitInt,  fromIntegral w)) <$> (toIntegralSized n :: Maybe Int64)
encodeSlot (RVLit (LChar c)) = Just (H.wsLitChar, fromIntegral (fromEnum c))
encodeSlot (RVLit LUnit)     = Just (H.wsLitUnit, 0)
encodeSlot (RVBox (CAddr p)) = Just (H.wsCBox, fromIntegral (ptrToWordPtr p))
encodeSlot (RVBox (HAddr i)) = Just (H.wsHBox, fromIntegral i)
encodeSlot _                 = Nothing      -- LStr / bignum LInt / RVRecMember / RVInst

decodeSlot :: (Word64, Word64) -> RCValue
decodeSlot (t, p)
  | t == H.wsLitInt  = RVLit (LInt (fromIntegral (fromIntegral p :: Int64)))
  | t == H.wsLitChar = RVLit (LChar (toEnum (fromIntegral p)))
  | t == H.wsLitUnit = RVLit LUnit
  | t == H.wsCBox    = RVBox (CAddr (wordPtrToPtr (WordPtr (fromIntegral p))))
  | t == H.wsHBox    = RVBox (HAddr (fromIntegral p))
  | otherwise        = error "decodeSlot: unknown slot tag"   -- impossible: we wrote it
```

- [ ] **Step 4: Backend-aware `alloc` for `NCon`** in `Value.hs`. Keep the existing pure path as `allocAbstract`; add the C path. Only `NCon` is eligible; everything else uses the abstract path and returns `HAddr`:

```haskell
allocNCon :: Text -> [RCValue] -> Store -> RC (Addr, Store)
allocNCon con vs s = case stBackend s of
  AbstractHeap -> allocAbstract (NCon con vs) s
  CHeap hp     -> case traverse encodeSlot vs of
    Nothing       -> allocAbstract (NCon con vs) s            -- fallback: a field isn't encodable
    Just encoded  -> do
      let (tid, s1) = internTag con s
          n         = length vs
      p <- liftIO (H.wokAlloc hp tid (fromIntegral n))
      liftIO $ mapM_ (\(i,(t,pl)) -> H.wokSlotSet p (fromIntegral i) t pl) (zip [0..] encoded)
      pure (CAddr p, bumpAllocStats s1)                       -- mirror the abstract stats bump
  where
    bumpAllocStats st = let g = stStats st; live = stLive g + 1
                        in st { stStats = g { stAllocs = stAllocs g + 1
                                            , stLive = live, stPeak = max (stPeak g) live } }

-- allocAbstract is the old `alloc` body (returns HAddr), lifted to RC in Task 0.
allocAbstract :: Node -> Store -> RC (Addr, Store)
allocAbstract n s = ...   -- existing IntMap body, returning (HAddr a, s')
```
  Keep a general `alloc :: Node -> Store -> RC (Addr, Store)` that routes `NCon` through `allocNCon` and all other nodes through `allocAbstract`, so the existing call sites in `Machine.hs` (`alloc (NCon c vs)`, `alloc (NClosure …)`, etc.) need no change beyond already being in `RC`.

- [ ] **Step 5: Backend-aware `incref`/`dropAddr`/`deref`** in `Value.hs`:

```haskell
incref :: Addr -> Store -> RC Store
incref (CAddr p) s = do liftIO (H.wokDup p); pure s
incref (HAddr i) s | i < 0     = pure s
                   | otherwise = ...   -- existing IntMap bump on key i

dropAddr :: Addr -> Store -> RC Store
dropAddr a0 s0 = go [a0] s0
  where
    go [] s = pure s
    go (CAddr p : rest) s = do
      newrc <- liftIO (H.wokDec p)
      if newrc /= 0
        then go rest (decLiveNoFree s)            -- not zero: nothing freed (stats unchanged)
        else do
          ar <- liftIO (H.wokArity p)
          raw <- liftIO (mapM (H.wokSlotGet p) [0 .. ar - 1])
          let kids = countedRefs (map decodeSlot raw)   -- CAddr + HAddr children, statics filtered
          liftIO (H.wokFree (heapPtr s) p)
          go (kids ++ rest) (bumpFreeStats s)
    go (HAddr i : rest) s
      | i < 0     = go rest s                     -- static: inert
      | otherwise = ...                           -- existing IntMap dec/free/cascade on key i

deref :: Addr -> Store -> RC Cell
deref (CAddr p) s = do
  tid <- liftIO (H.wokTag p)
  ar  <- liftIO (H.wokArity p)
  raw <- liftIO (mapM (H.wokSlotGet p) [0 .. ar - 1])
  pure (Cell 0 (NCon (tagName tid s) (map decodeSlot raw)))   -- rc field unused by readers
deref (HAddr i) s = ...                            -- existing IntMap lookup on key i
```
  Notes: `heapPtr s` extracts the `Ptr WokHeap` from `CHeap`. `bumpFreeStats`/`decLiveNoFree` mirror the abstract path's stat updates so totals match. `countedRefs` already filters statics and returns the counted `Addr`s; each is routed by `go` to the right heap — this is the cross-heap cascade, for free.

- [ ] **Step 6: Thread interning into the build sites.** `Machine.hs`'s `alloc (NCon c vs) s` and `Prim.hs`'s `alloc (NCon tag []) s` already call the general `alloc`; no change beyond Task 0's monad lift. Confirm `internTag` is invoked inside `allocNCon` (Step 4), so the build sites stay untouched.

- [ ] **Step 7: Select the C backend in `app/Main.hs`.** Before running, create a heap and thread the backend in. Since `runModuleRC` builds its own `Store` via `reserveStatic`/`emptyStore`, add a backend parameter: `runModuleRCWith :: HeapBackend -> CoreModule -> IO (Either RuntimeError RCRun)` (the existing `runModuleRC` = `runModuleRCWith AbstractHeap`), and have `reserveStatic`/`emptyStore` seed `stBackend`. In `Main.hs`:

```haskell
          hp <- Heap.wokHeapNew
          rcResult <- RCM.runModuleRCWith (St.CHeap hp) (Perceus.insertRC (pruneToReachable cm))
          Heap.wokHeapFree hp
          case rcResult of ...
```

- [ ] **Step 8: Build and run the full suite (spot check, no regression).**

Run: `cabal build all && cabal test 2>&1 | tail -20`
Expected: full suite green (the abstract-backed corpus tests still pass; the C path is exercised by `Main` and by the harness added in Task 3).

- [ ] **Step 9: Commit.**

```bash
git add src/Wok/Interp/RC/Value.hs src/Wok/Interp/RC/Machine.hs src/Wok/Interp/RC/Prim.hs app/Main.hs
git commit -m "feat(rc): C-backed NCon path alongside the abstract store (Haskell-driven cascade)"
```

---

## Task 3: Differential oracle + targeted tests + sanitizers

> **USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation ("prove correctness first then we try to compact it"). It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Goal:** Prove the C backend is bit-for-bit correct by running the whole corpus through both backends and diffing result + allocation stats, plus targeted cross-heap / fallback / deep-cascade tests, plus a sanitizer pass.

**Files:**
- Modify: `test/Spec.hs` (a `rc-c-backend-parity` group + targeted tests)
- Modify: `scripts/asan-runtime.sh` is already present from Task 1 (reused)

**Acceptance Criteria:**
- [ ] For every in-scope corpus program, `runModuleRCWith AbstractHeap` and `runModuleRCWith (CHeap …)` produce the **byte-identical** `rcOutput`.
- [ ] For every such program, the two backends report **identical** `stAllocs`, `stFrees`, and `stPeak`, and both end with dynamic-heap `stLive == rcBaseline` (no leak, no double-free).
- [ ] Cross-heap cascade test: a constructor holding a closure (a `CAddr` `NCon` with an `HAddr` child) and a closure capturing a constructor both free with balanced stats and no sanitizer error.
- [ ] Fallback test: a constructor with an `LStr` field is allocated as `HAddr` (stays on the abstract heap) and the program still produces the correct result with balanced stats.
- [ ] Deep-list test (e.g. 100k cons cells) builds and frees through the C backend with `live` returning to baseline (cascade is a worklist, not C recursion — no stack overflow).
- [ ] `bash scripts/asan-runtime.sh` exits 0.

**Verify:** `cabal test --test-options='-p "/rc-c-backend-parity/"' 2>&1 | tail -20` → green; `bash scripts/asan-runtime.sh` → `OK`.

**Steps:**

- [ ] **Step 1: Write the parity harness** in `test/Spec.hs`. Reuse the existing corpus list / `rcStatsPrepare` helper that the abstract-store tests already use; for each prepared module, run both backends and assert equality:

```haskell
rcCBackendParity :: TestTree
rcCBackendParity = testGroup "rc-c-backend-parity"
  [ testCase name $ do
      let cm = Perceus.insertRC instrumented
      absR <- RCM.runModuleRCWith St.AbstractHeap cm
      hp   <- Heap.wokHeapNew
      cR   <- RCM.runModuleRCWith (St.CHeap hp) cm
      Heap.wokHeapFree hp
      case (absR, cR) of
        (Right a, Right c) -> do
          assertEqual (name <> ": output parity")  (RCM.rcOutput a) (RCM.rcOutput c)
          assertEqual (name <> ": allocs parity")  (stAllocs (RCM.rcStats a)) (stAllocs (RCM.rcStats c))
          assertEqual (name <> ": frees parity")   (stFrees  (RCM.rcStats a)) (stFrees  (RCM.rcStats c))
          assertEqual (name <> ": peak parity")    (stPeak   (RCM.rcStats a)) (stPeak   (RCM.rcStats c))
          assertEqual (name <> ": no leak (C)")    (RCM.rcBaseline c) (stLive (RCM.rcStats c))
        other -> assertFailure (name <> ": backend disagreement: " <> show other)
  | (name, instrumented) <- rcCorpus    -- the existing in-scope corpus pairs
  ]
```
  (Use the same corpus source the abstract RC corpus group already iterates; factor it to a shared `rcCorpus :: [(String, CoreModule)]` if it isn't already a value.)

- [ ] **Step 2: Cross-heap cascade test.** Hand-build (or take from the corpus) a program whose value is a constructor holding a closure, and one where a closure captures a constructor; run through `CHeap`, assert balanced stats:

```haskell
  , testCase "cross-heap: NCon holding a closure frees balanced" $ do
      hp <- Heap.wokHeapNew
      r  <- RCM.runModuleRCWith (St.CHeap hp) crossHeapModule  -- builds `Box (\x -> x)` then drops it
      live <- Heap.wokStatLive hp
      Heap.wokHeapFree hp
      case r of
        Right run -> assertEqual "no leak" (RCM.rcBaseline run) (stLive (RCM.rcStats run))
        Left e    -> assertFailure (show e)
```

- [ ] **Step 3: Fallback test.** A constructor with an `LStr` field must stay on the abstract heap. Assert the program result is correct and stats balance (the `CHeap` run must still succeed because `allocNCon` falls back to `HAddr`):

```haskell
  , testCase "fallback: LStr-bearing constructor stays on Haskell heap" $ do
      hp <- Heap.wokHeapNew
      r  <- RCM.runModuleRCWith (St.CHeap hp) strFieldModule   -- builds e.g. `Tagged "hi" 1`
      Heap.wokHeapFree hp
      case r of
        Right run -> do
          assertEqual "result" expectedStrFieldOutput (RCM.rcOutput run)
          assertEqual "no leak" (RCM.rcBaseline run) (stLive (RCM.rcStats run))
        Left e -> assertFailure (show e)
```

- [ ] **Step 4: Deep-list test** (worklist cascade, no stack blowup):

```haskell
  , testCase "deep list (100k) builds and frees through C backend" $ do
      hp <- Heap.wokHeapNew
      r  <- RCM.runModuleRCWith (St.CHeap hp) (deepListModule 100000)  -- sum of [1..100000] or length
      Heap.wokHeapFree hp
      case r of
        Right run -> assertEqual "no leak" (RCM.rcBaseline run) (stLive (RCM.rcStats run))
        Left e    -> assertFailure (show e)
```

- [ ] **Step 5: Add a slot encode/decode QuickCheck property** (round-trip for encodable values):

```haskell
  , testProperty "encodeSlot/decodeSlot round-trips encodable RCValues" $
      \(EncodableRCValue v) -> Just v == fmap decodeSlot (encodeSlot v)
```
  with a small `newtype EncodableRCValue` generator producing `RVLit (LInt small)`, `RVLit (LChar c)`, `RVLit LUnit`, `RVBox (HAddr i)` (CAddr is a raw pointer — skip in the pure property).

- [ ] **Step 6: Add the groups to the tasty tree, build, test, sanitize.**

Run: `cabal test --test-options='-p "/rc-c-backend-parity/"' 2>&1 | tail -20`
Expected: every corpus program passes output + stats parity; cross-heap, fallback, deep-list, and the property all green.
Run: `bash scripts/asan-runtime.sh`
Expected: `OK`.

- [ ] **Step 7: Commit.**

```bash
git add test/Spec.hs
git commit -m "test(rc): C-backend differential oracle (output+stats parity) + cross-heap/fallback/deep tests"
```

---

## Task 4: Docs, memory, and cleanup

**Goal:** Record the pinned ABI as the codegen contract, update the project memory, and remove any scaffolding.

**Files:**
- Create: `runtime/README.md` (the ABI as the durable codegen contract)
- Modify: `docs/superpowers/specs/2026-06-21-c-runtime-allocator-ncon-design.md` (mark status: IMPLEMENTED)
- Modify: `/Users/zy/.claude/projects/-Users-zy-wokml/memory/MEMORY.md` (+ a new memory file)

**Acceptance Criteria:**
- [ ] `runtime/README.md` documents the `WokObj`/`WokSlot` layout, the slot-tag encoding, and the function ABI, labelled as the contract future codegen emits against.
- [ ] The spec status line reads IMPLEMENTED with the merge commit referenced.
- [ ] A memory file records: NCon-on-C-heap shipped, Haskell-drives-cascade, both-backends-oracle, plain-malloc (pool/mimalloc deferred), and the deferred layout-compaction + allocator slices.

**Verify:** `cabal test 2>&1 | tail -5` (still green) and `git status` clean except intended docs.

**Steps:**

- [ ] **Step 1: Write `runtime/README.md`** summarizing the ABI from spec §4 and stating it is the contract codegen will emit calls against (so the layout must not change without a coordinated codegen update).

- [ ] **Step 2: Flip the spec status** line `**Status:** DRAFT — pending user review` to `**Status:** IMPLEMENTED (feat/c-runtime-allocator-ncon)`.

- [ ] **Step 3: Add a memory file** `c-runtime-ncon-allocator.md` under the memory dir and a one-line pointer in `MEMORY.md`, capturing the decisions and the deferred slices (layout compaction, language-specific allocator, packed-data far-future).

- [ ] **Step 4: Final full suite + commit.**

```bash
cabal test 2>&1 | tail -5
git add runtime/README.md docs/superpowers/specs/2026-06-21-c-runtime-allocator-ncon-design.md
git commit -m "docs(rc): pin the C runtime ABI as the codegen contract; mark spec implemented"
```

---

## Notes for the implementer

- **Why `unsafe` FFI:** the C runtime never calls back into Haskell (the cascade is Haskell-driven), so `unsafe` imports are correct and avoid safe-call overhead. Keep `-threaded` (already in `wok.cabal`).
- **Stats are aggregated across both heaps** so the abstract-vs-C totals are directly comparable; every C alloc/free must mirror the abstract path's `stStats` update (Steps 4–5 of Task 2).
- **No arena in slice 1, by design:** `malloc`-per-cell with no bulk teardown is the strictest leak test — the RC cascade is the only thing that frees, so a missing drop shows up immediately as `stLive != baseline`.
- **The `Addr`-sum change is compiler-guided:** after editing the `data Addr` definition, `cabal build` will point at every `IntMap`/`IntSet` site that must destructure `HAddr i`.
