# Slice C — in-place `Array.set` under `rc == 1`

**Date:** 2026-06-24
**Status:** spec, pending user review before plan generation.
**Context docs:**
- `docs/superpowers/2026-06-24-array-region-valuemodel-arc.md` (the value-model arc; this is Slice C / rung 3 of that ladder — "Reuses the `rc == 1` gate, *not* the `drop_reuse`/`alloc_at` pairing").
- `docs/superpowers/specs/2026-06-24-array-slice-b-c-cell-design.md` (Slice B — the real C `WokArray` cell this slice mutates).
- `docs/superpowers/specs/2026-06-24-array-slice-a-design.md` §4 (the per-op dup/drop table; `set` was copy-on-write only).
**Companion visual:** `docs/array-slice-c-inplace-set.html` (the brainstorm: copy-vs-in-place, the gate, the cross-backend oracle invariant, the static-addr trap).

## 0 · Provenance (how we got to this scope)

The brainstorm converged on a single, self-contained optimization: give `Array.set` a fast path
that **mutates the array's slot in place when the array is uniquely owned (`rc == 1`)**, falling
back to the existing copy-on-write when it is shared. The observable semantics are unchanged
(`set arr i v` returns an array equal to `arr` with slot `i` holding `v`); only the allocation
behavior changes — **0 array allocations in the unique case** versus the current `+1` copy.

This is the FBIP `rc == 1` runtime gate applied to a slot write. It reuses the **gate** that the
FBIP reuse slice (`fbip-reuse-slice1`) already established and that the differential oracle already
proves cross-backend-consistent at `drop_reuse` sites. It deliberately does **not** reuse the
`drop_reuse`/`alloc_at` token pairing: arrays stay FBIP-excluded
(`nodeCEligible (NArray _) = False`), Perceus never emits a reuse token for an array, and no FBIP
code is touched. Only `set` gains the fast path; `resize` (which changes length, a genuinely
different allocation) stays copy-only.

Four design axes were settled with the user:

1. **The uniqueness probe is a non-destructive peek.** A new **general** C function `wok_rc`
   (reads the shared-prefix `rc` field at offset 0 — works on any cell, including `WokArray`) is
   the read-only sibling of the existing general shared-prefix ops `wok_dup`/`wok_dec`/`wok_tag`.
   On the abstract backend the peek is the existing `cRc` from a deref. *Not* a dec-then-restore
   hack; *not* routing through FBIP tokens.
2. **The decision lives in one shared chokepoint** (`arrayUnique`) that hides the backend dispatch
   and returns a single `Bool` — the "`nodeCEligible` discipline." Uniqueness is heap state (the
   refcount), so the function is *not* pure (it reads the store / lifts IO); that is the one way it
   differs from `nodeCEligible`. Its cross-backend identity rests on the refcount being maintained
   in lockstep, not on value-purity.
3. **The in-place writer dispatches on address** — `CAddr` → `wok_array_slot_set`; `HAddr`
   (abstract) → replace the node at the same address with the same `rc`/same `cBytes` and **no**
   `recordAlloc`/`recordFree`. Both yield `0 alloc / 0 free / no peak spike`.
4. **The crux is the cross-backend oracle invariant.** In-place and copy produce different
   `alloc`/`free`/`peak`/`peak_bytes`, so the `rc == 1` decision must come out bit-for-bit
   identical on both backends.

## 1 · Goal & non-goals

### Goal
Add a unique-array fast path to `Array.set` on the RC interpreter: when the input array is
provably uniquely owned and the new element is encodable, mutate slot `i` in place (drop the old
element, move the new one in, leave the other `n−1` slots untouched) and return the same handle —
`0 array alloc`, `0 array free`, no `peak_bytes` spike. Otherwise fall back to the existing
copy-on-write path. The decision is made by a single shared predicate that is identical on both
backends, so the differential oracle stays green.

### In scope
- A general non-destructive refcount peek `wok_rc` in `runtime/wok_rc.{c,h}` (a new function in the
  existing files; **no new files**), with a `wokRc` FFI binding in `Heap.hs`.
- A shared `arrayUnique :: Addr -> Store -> RC Bool` decision function in `Value.hs`
  (static-guarded, `CAddr` → `wokRc` peek, `HAddr` → `derefPure` `cRc`).
- An in-place slot writer in `Value.hs` dispatching on address (`CAddr` slot-set; `HAddr`
  node-replace-at-same-addr), reading+decoding the old slot to drop it (reusing the existing decode
  path), with no `recordAlloc`/`recordFree`.
- `arraySet` in `Prim.hs` split into the gated in-place path and the existing copy path.
- Tests: the existing `set` store-algebra unit test updated to assert `0 alloc` for the unique case
  plus a new sibling shared-array assertion (`+1 alloc`); a new shared-set differential-oracle
  corpus program (the copy-path coverage) plus a boxed-element in-place corpus program (the
  C-backend counted-old-element drop); the existing QuickCheck `set` properties run unchanged on the
  abstract backend (the C path is covered by the differential corpus + the C `wok_rc` unit test); a
  C unit test for `wok_rc`.

### Out of scope (deferred, with explicit triggers)
- **In-place `resize`** (length-changing) and any in-place `new`/`fromList`. `set` is the only op
  getting the fast path this slice.
- **FBIP token reuse for arrays.** Arrays stay FBIP-excluded; `drop_reuse`/`alloc_at` and
  `nodeCEligible`/`nodeArity` for `NArray` are untouched.
- **Slice D (unboxed/flat), regions, LoCal, String.** Unchanged from the arc.
- **Changing the `Int ≥ 2^63` edge behavior.** A non-encodable `v` degrades to the copy path,
  exactly as Slice B already behaves (§4).

## 2 · Architecture

### Two backends, one decision
`Array.set` runs on both backends (the C backend is production; the abstract `NArray` on the
`IntMap` is the differential oracle's reference, Slice B §2). The same `arraySet` Haskell code runs
on both; `deref`/`alloc`/`dropAddr` dispatch internally on `stBackend`. On the abstract backend an
array handle is an `HAddr`; on the C backend it is a `CAddr` pointing at a `WokArray` cell.

The flow:

```
set arr i v
  └─ bounds: i >= n  -> PrimError (array untouched)        [unchanged]
  └─ gate: arrayUnique a s  &&  isJust (encodeSlotC v)
       ├─ TRUE  -> in-place: drop old arr[i], write v, survivors untouched   (0 alloc / 0 free)
       └─ FALSE -> copy-on-write: alloc new array, incref survivors, dropAddr a   (+1 alloc)  [unchanged]
```

The copy branch is byte-for-byte the current Slice B `arraySet`. The only new control flow is the
gate and the in-place branch.

## 3 · The uniqueness probe

### The C peek (`wok_rc`)
The refcount lives in the shared 8-byte `WokObj` prefix at offset 0 (`uint32_t rc`), identical for
`NCon` cells and `WokArray` cells. The only current reader, `wok_dec`, *decrements*. `set` keeps
the array (it does not consume a reference to decide uniqueness), so it needs a non-destructive
read:

```c
WOK_PURE uint32_t wok_rc(const WokObj* p);   /* returns p->rc; does NOT modify it */
```

This is general (works on any cell), consistent with `wok_dup`/`wok_dec`/`wok_tag` (all general
shared-prefix ops, all already reused on array cells). Bound in `Heap.hs`:

```haskell
foreign import ccall unsafe "wok_rc" wokRc :: Ptr WokObj -> IO Word32
```

### The shared decision (`arrayUnique`)
`readCCell` returns a `Cell` whose `cRc` is a meaningless placeholder `0` for a C cell (the real
count is in the C cell), so the probe must dispatch on address kind. It also must reject
static/immortal arrays before reading any count:

```haskell
-- | True iff the array at 'a' is safe to mutate in place: it is a dynamic,
-- counted cell whose refcount is exactly 1 (the caller's owned reference is the
-- only one). Static/immortal addresses (negative HAddr, uncounted) read "rc 1"
-- but are shared forever, so they are NEVER unique here -- guarded FIRST, exactly
-- as 'dropReuse' guards its donor.
arrayUnique :: Addr -> Store -> RC Bool
arrayUnique a _ | isStaticAddr a = pure False         -- immortal: never in-place
arrayUnique (CAddr p) _          = (== 1) <$> liftIO (wokRc p)
arrayUnique a@(HAddr _) s        = do
  c <- liftRC (derefPure a s)                         -- derefPure rejects CAddr; reached only for HAddr
  pure (cRc c == 1)
arrayUnique (Inline _) _         = pure False          -- an array handle is never Inline; defensive
```

Notes:
- `arrayUnique` is in the `RC` monad because the `CAddr` arm lifts IO (`wokRc`). The static guard
  comes first so a negative `HAddr` never reaches `derefPure`, and the `CAddr`/`HAddr` split keeps
  `derefPure` (which errors on `CAddr`) on the `HAddr`-only path.
- `Inline` cannot be an array handle (arrays are always boxed `CAddr`/`HAddr`); the arm is
  defensive and returns `False`.

### Why the two backends agree
Both backends maintain the array cell's refcount in lockstep: every `dup`/`drop` fires at the same
shared Haskell call site (`incref`/`dropAddr`), which dispatches to `wok_dup`/`wok_dec` (C) or the
`cRc ± 1` update (abstract). Slice B's oracle already proves the aggregate `alloc`/`free`/`peak`
match, and FBIP already relies on this same `rc == 1` agreement at `drop_reuse` sites (a divergent
decision there would diverge the alloc count). `arrayUnique` reads the same lockstep quantity at a
new site, so it returns the same `Bool` on both backends by construction.

## 4 · The gate

The in-place path is taken iff **both**:

1. `arrayUnique a s` — not static/immortal, and `rc == 1`.
2. `isJust (encodeSlotC v)` — the new element is encodable as a slot word.

Condition 2 is included as a **global** gate condition, not a `CAddr`-only guard, and not because
the abstract backend needs it (the abstract in-place write stores the `RCValue` directly). It is
hoisted into the shared gate so the **path decision is identical on both backends**: the C backend's
in-place write requires an encodable word (`wok_array_slot_set` takes a `uint64`), so if `v` is not
encodable the C backend cannot mutate in place; to keep the decision identical, the abstract backend
must take the same (copy) branch. `encodeSlotC` is a pure function of `v`, so it evaluates
identically on both backends.

The only value that is non-encodable for an element of an existing C array is an `Int ≥ 2^63`
(`encodeSlotC (RVLit (LInt n))` uses `toIntegralSized`, which fails past `Int64`). For such a `v`,
**both** backends take the copy path — which is **exactly Slice B's pre-existing behavior**
(`set` with a `≥ 2^63` element already routes through the copy path, where the C backend's
`allocNArray` raises `PrimError` and the abstract backend succeeds; that program already desyncs the
oracle in Slice B and is therefore not a valid corpus program). Slice C introduces **no new edge
behavior**: it degrades to copy in exactly the case Slice B already did.

**`elemkind` consistency is guaranteed by monomorphism (no extra check).** A `WokArray`'s `elemkind`
(set at allocation from the first element) is uniform because `Array a` is monomorphic. Every value
of a single type `a` encodes to one fixed `SlotKind`: `U64`/`U32` → `KLitInt`, `Char` → `KLitChar`,
`Unit` → `KLitUnit`, and any boxed/sum type → `KPointer` (with the 2-bit low tag distinguishing
`Inline`/`CAddr`/`HAddr` *within* `KPointer`). So the `SlotKind` of `v` provably equals the array's
stored `elemkind`, and the in-place slot write cannot create a slot the later decode misreads. No
`elemkind`-match condition is needed in the gate.

## 5 · The in-place writer

A single `Value.hs` writer dispatches on the array's address, performs the heap write, and
**returns the old element** for the caller to drop. `Prim.hs`'s `arraySet` then drops it via the
existing `dropValue` helper. This split respects the module layering — `Value.hs` is imported *by*
`Prim.hs`, so the writer cannot call `dropValue` (which lives in `Prim.hs`); it uses `Value.hs`'s
own `dropAddr`/store primitives for the write and hands the old element back. The order is
therefore **read old → write new → (return) → drop old** (alias-robust even though the prim owns
`v` independently): the new reference is installed before the old one is released.

```haskell
-- | Overwrite slot 'i' of the array at 'a' with 'v', in place, returning the OLD
-- element (the caller drops it). The cell's rc / length / cBytes are unchanged and
-- NO recordAlloc/recordFree is performed (0 alloc / 0 free). Precondition (the
-- caller's gate): the array is unique ('arrayUnique') and 'v' is encodable.
arraySetSlotInPlace :: Addr -> Int -> RCValue -> Store -> RC (RCValue, Store)
```

### `CAddr` (C cell)
1. Read the array's `elemkind` (`wok_array_elemkind`).
2. Read the **single** old slot word (`wok_array_slot_get p i`) and decode it
   (`decodeSlotC elemkind word`) — the same per-slot decode `readCArraySlots` uses internally, **not**
   the whole-array `readCArrayValues` wrapper — to obtain `oldEl`.
3. Write the new element: `encodeSlotC v = Just (_, word)` (guaranteed by the gate); `wok_array_slot_set p i word`.
4. Return `(oldEl, s)` — the store is unchanged except for the in-place slot; `RVBox (CAddr p)`
   stays the array handle, `rc` unchanged.

### `HAddr` (abstract cell)
1. `derefPure` the cell to get the element list `vs` and its `Cell rc node cBytes`.
2. `oldEl = atIndex i vs` (the existing total accessor; `Just` is guaranteed by the preceding bounds
   check — fail loudly through the RC error channel otherwise, never a partial function).
3. `newVs = [ if j == i then v else el | (j, el) <- zip [0..] vs ]`.
4. Replace the node at the same address with the same `rc` and same `cBytes`, **no** stat change:
   `IM.insert i (Cell rc (NArray newVs) cBytes) (stCells s)`.
5. Return `(oldEl, s')`.

### In `Prim.hs` `arraySet`
```haskell
(oldEl, s1) <- arraySetSlotInPlace a i v s   -- write new, get old
s2          <- dropValue oldEl s1            -- release the array's old ref (cascade if counted)
pure (PRDone (RVBox a), s2)                   -- same handle, rc unchanged
```

`dropValue oldEl` drops the array's old reference (cascading if `oldEl` is counted and hits 0);
uncounted `oldEl` (raw-lit / `Inline`) is a no-op. Both paths leave the `n−1` survivors untouched
(no incref, no drop), so the only RC traffic is the single `oldEl` drop and the move-in of `v`
(consumed, no incref). The length is unchanged, so `cBytes` (`16 + 8n`) is unchanged and
`peak_bytes` does not move.

## 6 · Operations & RC / stat accounting

`set` is the only op that changes. The element-level effect is **identical** in both paths (old
`arr[i]` dropped, `v` moved in); the only difference is the array cell and the survivor traffic.

| `set arr i v` on a array of length `n` | array alloc | array free | survivors (`n−1`) | old `arr[i]` | new `v` | `peak_bytes` |
|---|---|---|---|---|---|---|
| copy-on-write (shared, or non-encodable `v`) | +1 | 0 (shared: decrement only) | `n−1` increfs (new array's refs) | retained by old array | moved into new array | spikes `+16+8n` (both arrays briefly live) |
| copy-on-write (unique input, the old default) | +1 | +1 | `n−1` incref then `n−1` cascade-drop (net 0) | released | moved into new array | spikes `+16+8n` |
| **in-place (unique + encodable, Slice C)** | **0** | **0** | **untouched** | **released** | **moved into same slot** | **no spike** |

So switching a unique `set` from copy to in-place removes `+1 alloc`, `+1 free`, the `n−1`
incref/drop churn, and the transient `peak_bytes` spike. The released-old / moved-in-`v` effect is
preserved.

The other six ops (`new`/`fromList`/`toList`/`index`/`length`/`resize`) are unchanged (Slice A §4 /
Slice B §4).

## 7 · The oracle invariant (the crux)

In-place and copy produce different `alloc`/`free`/`peak`/`peak_bytes`. The differential oracle runs
every array corpus program on both backends and asserts they match; correctness therefore requires
the path decision to be identical on both backends. It is (§3): `arrayUnique` reads the lockstep
refcount and `encodeSlotC` is pure.

**What changes in the oracle, precisely:**
- The array corpus hits only the **differential** oracle (abstract == C parity on
  `alloc`/`frees`/`peak`/`peak_bytes` and byte-identical output). There are **no absolute golden
  files** for the array corpus (`rcArrayFiles` is not in the stats-golden group). So the differential
  parity **self-adjusts**: when a unique `set` now takes the in-place path, *both* backends report the
  lower figures, and parity still holds. No golden file needs updating.
- The single **absolute** assertion that changes is the store-algebra unit test for `set` (§10),
  which currently hard-asserts `+1 alloc` on a unique array.

**The test obligation that makes the agreement *checked*, not merely argued:** the corpus must
exercise **both** branches — a unique-input `set` (in-place: `0 alloc`) and a shared-input `set`
(copy: `+1 alloc`). The existing `test/rc-array/05-set-index.wok` is a unique chain (every
intermediate array is unique → all in-place); a **new** shared-set program is added (§10) so the
copy path is covered and any cross-backend disagreement on the gate would diverge the stats and fail
the differential immediately.

## 8 · Soundness

- **`rc == 1` ⇒ sole owner ⇒ mutation unobservable.** When `arrayUnique` is true, the prim's owned
  reference is the only reference to the array — no other binding, structure slot, or continuation
  frame holds it (the Perceus/FBIP invariant; Perceus inserts a `dup` for any additional use, so a
  still-needed array has `rc > 1` at the `set` site and takes the copy path). Mutating its slot
  cannot be observed by anyone else, so the result is observationally equal to the copy.
- **Static/immortal guard.** A top-level CAF array is a negative `HAddr`, uncounted; its count reads
  "1" but it is shared for the program's lifetime. `arrayUnique` guards `isStaticAddr` first and
  returns `False`, forcing the copy path — exactly the discipline `dropReuse` uses for donors.
- **Bounds before mutation.** `i >= n` raises `PrimError` with the array untouched, byte-identical
  to the copy path's error: no partial write, no leak.
- **Old-element release + alias order.** The old `arr[i]` is dropped exactly once (the array's old
  reference), matching the copy path's cascade. `v` is moved in (no incref), matching the copy
  path's move-into-new-array. The read-old → write-new → drop-old order is alias-robust even if `v`
  is the same object as the old element.
- **No `recordAlloc`/`recordFree`.** The in-place path allocates and frees no array cell; the cell's
  `rc`, length, and `cBytes` are preserved, so the eventual ordinary `dropAddr` of the array still
  balances.

## 9 · The C ABI addition

```c
/* Non-destructive refcount peek. General (shared WokObj prefix at offset 0), the
   read-only sibling of wok_dup/wok_dec. Used by the rc==1 in-place Array.set gate. */
WOK_PURE uint32_t wok_rc(const WokObj* p);
```

Additive; no existing signature changes. (Naming note: `wok_rc` shares the stem of the source file
`wok_rc.c`; this is cosmetic and accepted. `wok_rc_peek` was considered and rejected for keeping the
naming parallel to `wok_dup`/`wok_dec`/`wok_tag`.)

## 10 · Files touched

- `runtime/wok_rc.h` — declare `wok_rc` (additive).
- `runtime/wok_rc.c` — define `wok_rc` (`return p->rc;`); a standalone unit test asserting it reads
  the count without mutating it (alloc → `wok_rc == 1`; `wok_dup` → `wok_rc == 2`; `wok_dec` →
  `wok_rc == 1`), under ASan/UBSan via `scripts/asan-runtime.sh`.
- `src/Wok/Interp/RC/Heap.hs` — the `wokRc` FFI import (added to the export list).
- `src/Wok/Interp/RC/Value.hs` — `arrayUnique` (shared decision, static-guarded, `RC` monad) and
  `arraySetSlotInPlace` (dispatch `CAddr`/`HAddr`; read+decode the single old slot via
  `wokArraySlotGet` + `decodeSlotC`; write new; **return** the old element; no
  `recordAlloc`/`recordFree`); both added to the module export list.
- `src/Wok/Interp/RC/Prim.hs` — `arraySet` split: bounds check (unchanged) → gate
  (`arrayUnique && isJust (encodeSlotC v)`) → `arraySetSlotInPlace` then `dropValue` the returned
  old element, else the existing copy path verbatim.
- `test/Spec.hs` — update the `set` store-algebra unit test to assert `0 alloc` on a unique array and
  add a sibling shared-array assertion (`+1 alloc`); array QuickCheck properties run unchanged on
  both backends.
- `test/rc-array/09-set-shared.wok` (new) — a shared-input `set` (dup the array reference, then `set`
  on the shared copy) exercising the copy-on-write fallback; output + `alloc`/`free`/`peak`/
  `peak_bytes` parity on both backends; heap returns to baseline.
- `docs/array-slice-c-inplace-set.html` — the companion visual (already written).
- `runtime/README.md` — document `wok_rc` in the ABI list.

No new type, no surface change, no prelude change, no FBIP code change.

## 11 · Testing

- **C unit test** (`runtime/test`, ASan/UBSan + LeakSanitizer): `wok_rc` round-trip
  (alloc=1, after `wok_dup`=2, after `wok_dec`=1) confirming it is non-destructive; works on both an
  `NCon` cell and a `WokArray` cell.
- **Store-algebra unit tests** (`Value.hs` path): update the existing `set` test to assert the unique
  case allocates `0` (in-place) and the old element is dropped exactly once; add a shared-array case
  (`dup` the array, then `set`) asserting `+1 alloc` (copy) and that the original array still reads
  its old value at `i` (no in-place mutation of a shared array). Assert `stLive` returns to baseline
  and no double-free in both cases, for an inline-element array (`Array U64`) and a boxed-element
  array (`Array String`).
- **QuickCheck properties (unchanged, abstract backend; the C in-place path is covered by the
  differential corpus + the `wok_rc` C unit test):** `index (set a i v) i == v`;
  `j /= i ==> index (set a i v) j == index a j`; `length (set a i v) == length a`. These hold
  identically whether `set` mutated in place or copied — they pin the *semantics*, which the fast
  path preserves.
- **Differential-oracle corpus:** the existing `test/rc-array/05-set-index.wok` (now exercising the
  in-place path on its unique chain), the new `test/rc-array/09-set-shared.wok` (the copy fallback),
  and `test/rc-array/10-set-boxed-unique.wok` (the in-place path replacing a *counted* `CAddr` old
  element — `Some k` — pinning the C-backend counted-old-element drop that the uncounted-`None` case
  in 08 does not cover). Both backends must agree on byte-identical output and on
  `alloc`/`frees`/`peak`/`peak_bytes`; heap returns to baseline (`stLive == baseline`,
  `wok_stat_live == 0`).

All via tasty (Hspec + QuickCheck). No temporary fixes; tests coherent to this spec and documented.

## 12 · Task breakdown (each ships green)
> Native tasks + model tiers assigned at the writing-plans step. Indicative tiers below.

1. **`wok_rc` C function + ABI + standalone test** (`wok_rc.{c,h}`, `runtime/test`,
   `scripts/asan-runtime.sh`): declare/define the peek, ASan/UBSan-green non-destructive test on an
   `NCon` and a `WokArray`. Ships green; Haskell unchanged still builds. — *mechanical*.
2. **`wokRc` FFI binding** (`Heap.hs`). — *mechanical*.
3. **`arrayUnique` + `arraySetSlotInPlace`** (`Value.hs`): the shared static-guarded decision and the
   address-dispatched in-place slot write (read+decode old, write new, return old, no stat change),
   with module exports. — *standard*.
4. **Gate `arraySet`** (`Prim.hs`): wire the gate and the in-place branch; keep the copy branch
   verbatim. — *standard*.
5. **Tests**: update the `set` store-algebra unit test (unique `0 alloc` + shared `+1 alloc`); add
   `test/rc-array/09-set-shared.wok` + `test/rc-array/10-set-boxed-unique.wok`; run the QuickCheck `set` properties on the abstract backend; full
   suite + ASan green. — *standard*.
6. **Docs + memory**: `runtime/README.md` (the `wok_rc` ABI), the `array-slice-b-c-cell` memory note
   (mark Slice C), the arc doc (mark Slice C done); clean up scaffolding. — *mechanical*.

## 13 · Decisions locked / deferred

**Locked:**
- `Array.set` mutates in place under `arrayUnique a s && isJust (encodeSlotC v)`; else copy-on-write
  (the existing path, verbatim).
- The uniqueness probe is a non-destructive peek: general `wok_rc` (C) + `cRc` (abstract), behind
  the single `arrayUnique` chokepoint, static-guarded first.
- The in-place writer dispatches on address (`CAddr` slot-set / `HAddr` node-replace-at-same-addr),
  no `recordAlloc`/`recordFree`, old element dropped once, survivors untouched.
- The cross-backend path decision is identical by construction (lockstep refcount + pure
  `encodeSlotC`); the array corpus is differential-only (no golden files); both branches are covered
  by the corpus.
- FBIP code untouched; arrays stay FBIP-excluded. `resize` stays copy-only.

**Deferred (with triggers):** in-place `resize` / length-changing reuse; FBIP token reuse for arrays;
Slice D (unboxed/flat); regions / LoCal; String; any change to the `Int ≥ 2^63` edge.
