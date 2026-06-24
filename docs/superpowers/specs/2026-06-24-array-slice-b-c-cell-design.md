# Slice B — `Array a` on a real C cell (`WokArray`), byte-size-class placement

**Date:** 2026-06-24
**Status:** spec, pending user review before plan generation.
**Context docs:**
- `docs/superpowers/2026-06-24-array-region-valuemodel-arc.md` (the value-model arc; this is Slice B of that ladder).
- `docs/superpowers/specs/2026-06-24-array-slice-a-design.md` (Slice A — the boxed `Array a` on the abstract heap, which this slice completes).
- `docs/superpowers/specs/2026-06-21-c-runtime-arena-allocator-design.md` (the slab arena this reuses).
**Companion visual:** `docs/array-vec-handle-buffer.html` (the brainstorm: representation forks, the findings that led here).

## 0 · Provenance (how we got to this scope)

The brainstorm started from "byte-size-class arena placement + capacity rounding for unboxed
arrays." Pushing it through the actual codebase collapsed it to something smaller and sounder:

- **Finding 1 — wok has only `U64` and `U32`**, and `U32` is represented identically to `U64`
  (a single `LInt Integer` at the IR level; the `u32` prim is the identity). There are **no
  sub-word integers, no signed integers, and no floats**. So an unboxed "packed numeric scalar"
  array has no element types that would be denser than a word.
- **Finding 2 — for `U64`/`U32`, Slice A's boxed array is already inline.** A scalar element is
  an `RVLit` (no per-element cell, no pointer); at the C level it already packs into a raw 8-byte
  slot (`encodeSlotC` → `KLitInt`). So a "flat" array of the scalars we have would be bit-for-bit
  identical to the boxed one. Genuine unboxing only pays for *multi-word value structs* or
  *sub-word types* — both of which need language features wok does not have yet.
- **Finding 3 — the abstract heap tracks only cell counts.** `Stats` has
  `stAllocs/stFrees/stLive/stPeak`; there is **no byte tracking**. `peak_bytes` is currently a
  C-only benchmark stat. So "keep the oracle bit-for-bit incl `peak_bytes`" (the brief's invariant)
  is *new scope*, not an inherited property.

The resulting target, confirmed with the user: **stop simulating the array in the interpreter and
give `Array a` a real C allocator cell** — the C `WokArray` that Slice A deferred. Because the only
scalar types are word-sized, the C cell with 8-byte slots is *already flat for scalars* (the
integer sits inline in the block) and *already correct for boxed elements* (the slot holds a
pointer). That is exactly Koka's `vector`. So:

- **No new type and no `Array`/`Vector` rename.** The flat-vs-boxed split dissolves: there is one
  representation today (8-byte slots, inline-or-pointer), and it *is* flat for scalars. `Array a`
  stays the one polymorphic array type. (The rename was predicated on a genuinely-unboxed second
  representation, which is deferred with the types that would justify it.)
- **The abstract `NArray` is retained, demoted to the differential oracle's reference model** (not
  a shipping representation). The real (C) backend runs on the C cell; the abstract backend keeps
  `NArray` on the `IntMap` purely so the oracle can cross-check the new C memory surface
  bit-for-bit. (User decision: keep the oracle, drop `NArray`'s shipping role.)

## 1 · Goal & non-goals

### Goal
Replace the interpreter-resident representation of `Array a` (Slice A's abstract `NArray`, on the
CHeap path) with a real C cell — `WokArray` — allocated through the existing `WokHeap*` arena seam,
placed by **total byte size** (small → the existing word-count free-list, large → `malloc`), with
`peak_bytes` elevated to a **shared, bit-for-bit oracle invariant**. The user-facing `Array a` is
unchanged in type and behaviour; only its runtime representation on the C backend changes from "an
`IntMap` node" to "a real allocator cell."

### In scope
- The C `WokArray` cell layout + a `wok_array_*` ABI in `runtime/wok_rc.{c,h}`.
- Byte-size-class placement for array cells, reusing the existing arena free-list (shared with
  same-byte-size `NCon`s); `malloc` fallback for large arrays.
- Routing the CHeap backend's `NArray` allocation to the C cell; `dup`/`drop`/cascade via the
  array's C slots (reusing the existing 2-bit slot encoding).
- The seven ops (`new`/`fromList`/`toList`/`index`/`length`/`set`/`resize`) backed by the C cell,
  with the Slice A §4 RC semantics preserved.
- **`peak_bytes` elevated to a shared oracle invariant**: byte tracking added to the abstract
  `Stats`, a shared pure `cellBytes`/`wouldBeCBytes`, and the differential oracle checking
  `peak_bytes` in addition to `alloc`/`free`/`peak`.
- C-cell unit tests under ASan/UBSan + the differential oracle over the array corpus.

### Out of scope (deferred, with explicit triggers)
- **Sub-word / float / signed scalar types** (`U8`/`U16`/`I*`/`F32`/`F64`). A separate language
  feature; until it lands, every element slot is 8 bytes and the stride is uniformly 8.
- **Genuinely-unboxed multi-word value structs** (`Array Vec4` packed inline by value + the
  element layout descriptor + materialize-on-`index`). The "flat vs boxed" distinction re-activates
  here.
- **Capacity rounding / a `sizeClass` that rounds.** With stride 8, every array byte size is a
  multiple of 8, so the size class is exact and rounding is a no-op. The rounding machinery is
  introduced with sub-word types.
- **The `Sized` kind + pure-wok generic library ops** (`map`/`fold`/… in `.wok`). Needs a way to
  state "element is sized" in a generic signature; deferred.
- **Length-indexed `ArrayOf n a`.** A type-system epic; the runtime `len` we keep here is exactly
  what a future phantom or runtime-relevant `n` would wrap, so this slice does not block it.
- **In-place `set` under `rc == 1`** (Slice C); **regions / LoCal** (the region epic).
- **A coarse large-tier (geometric) size class** for arrays > 512 B. Large arrays `malloc` as today.

## 2 · Architecture

### Two backends, one of them now real
- **CHeap backend (production / `app/Main.hs`):** `NArray` allocation routes to a real C
  `WokArray` cell (mirroring how `NCon` routes to `wok_alloc`). The array's bytes live in the
  arena/`malloc`; the `Addr` for an array is a `CAddr` pointing at the cell.
- **AbstractHeap backend (oracle reference, tests only):** `NArray` stays on the `IntMap` exactly
  as in Slice A. This is the simple, obviously-correct model the C cell is cross-checked against.

The differential oracle runs every array corpus program on both and proves byte-identical output +
matching `alloc`/`free`/`peak`/**`peak_bytes`**.

### Why a distinct cell (not an `NCon`)
An `NCon`'s slot count is its `arity`, a `uint8` (max 255), and the header has nowhere to put a
runtime length. An array's length is a runtime value, so it is the **first wok value whose size is
not `8 + 8·uint8`** (arc §2). It needs a wider header carrying a runtime `len`.

## 3 · The C cell layout & ABI

### Layout
```
offset 0   uint32 rc       \
offset 4   uint16 tag       |  8-byte prefix, WokObj-compatible: the shared
offset 6   uint8  elemkind  > wok_dup / wok_dec / wok_tag read offsets 0-7;
offset 7   uint8  scan      /   tag == WOK_ARRAY_TAG marks an array; elemkind = the
                                element SlotKind (uniform across the array, see below)
offset 8   uint64 len       <-  runtime element count (word 2)
offset 16  uint64 slots[len] <- len 8-byte slots; encoding given by elemkind
```
- **Byte size = `16 + 8·len`** (always a multiple of 8, so the size class is exact).
- The 8-byte prefix is binary-compatible with `WokObj`, so `wok_dup`/`wok_dec`/`wok_tag` work
  unchanged. The `arity` byte (offset 6) is **repurposed as `elemkind`**: the element's `SlotKind`,
  uniform across the array because `Array a` is monomorphic (every slot holds a value of the one
  type `a`). This single byte drives both teardown and decode (§6).
- **Discriminator:** the reserved tag value `WOK_ARRAY_TAG = 0xFFFF`. `wok_free` and the deref path
  read `tag` **first**: `tag == WOK_ARRAY_TAG` ⇒ array (read `len` from offset 8; `len` slots),
  else `NCon` (slot count = `arity`). The value is **reserved Haskell-side**: `internTag` allocates
  constructor tags from 0 and never returns `0xFFFF`, guarded so the constructor count stays below
  `0xFFFF`. (A C `_Static_assert` cannot enforce a runtime-interned quantity — this was a review fix.)
- **Slots** are encoded by `encodeSlotC`, with the applicable encoding given by the header
  `elemkind` (not guessed per slot): a **raw-lit** kind (`KLitInt`/`KLitChar`/`KLitUnit`, e.g.
  `Array U64`/`U32`) stores a raw word and is **uncounted** — teardown skips every slot, no decode;
  a **pointer-scheme** kind (any boxed/sum type, e.g. `Array String`, `Array (Maybe U64)`) stores
  each slot with the 2-bit low tag (`00` CAddr / `01` HAddr / `11` Inline), and teardown drops the
  counted ones (`CAddr`/`HAddr`), skips `Inline`. One `elemkind` is correct because `a` fixes the
  category for the whole array. (Raw-lit slots carry no 2-bit tag, so they **cannot** be discerned
  per-slot — hence `elemkind` lives in the header; this was a review fix.)
- **Free-list link overlay is safe:** a freed cell's first 8 bytes hold the arena `next` link; the
  smallest array block (`len = 0`) is 16 B, comfortably ≥ the 8-byte link, exactly like an `NCon`.

### ABI additions (`wok_rc.h`)
```c
#define WOK_ARRAY_TAG 0xFFFFu   /* reserved tag marking an array cell (also reserved Haskell-side) */

WokObj*  wok_array_alloc(WokHeap* h, uint64_t len, uint8_t elemkind);  /* rc=1, tag=ARRAY, slots undef */
WOK_PURE uint64_t wok_array_len(const WokObj* p);
WOK_PURE uint32_t wok_array_elemkind(const WokObj* p);
void     wok_array_slot_set(WokObj* p, uint64_t i, uint64_t word);
WOK_PURE uint64_t wok_array_slot_get(const WokObj* p, uint64_t i);
```
Existing `wok_dup`/`wok_dec`/`wok_tag` are reused (no signature change). `wok_free` gains an
internal dispatch that reads `tag` **first**: `tag == WOK_ARRAY_TAG ⇒ bytes = 16 + 8·len` (read
`len`), else `bytes = 8 + 8·arity`. Without this, `wok_free` on an array would read the unused
`arity`/`elemkind` byte and route to the wrong size class — so the C task must land the dispatch
before any `WokArray` is freed.

### Byte-size-class placement (reuses the arena)
The arena free-list is keyed by a class index. Unify it as **`class = bytes/8 − 1`**:
- `NCon` arity `a`: `bytes = 8 + 8a ⇒ class = a` (unchanged — the current code's `arity` index).
- `WokArray` len `L`: `bytes = 16 + 8L ⇒ class = L + 1`.

So an array of len `L` shares `freelist[L+1]` with an `NCon` of arity `L+1` (identical byte size) —
shape-agnostic recycling, no new free-list machinery. `wok_array_alloc` and `wok_free` compute the
class from byte size; `class < WOK_NUM_CLASSES (64)` ⇒ arena (free-list pop, else bump), else
`malloc`. Arrays with `len ≤ 62` (byte size ≤ 512) recycle in the arena; larger arrays `malloc`,
exactly the existing large-object policy.

`_Static_assert`s: the 16-byte header keeps 8-alignment; an array at the class boundary
(`len = 62`, 512 B) fits a slab. (The `WOK_ARRAY_TAG` reservation is enforced Haskell-side in
`internTag`, not by a C assert — it is a runtime-interned quantity.)

## 4 · Operations & RC semantics

Behaviour and the dup/drop accounting are exactly Slice A §4 (the prim *owns* its arguments;
Perceus inserts `dup` for shared uses; each prim drops or transfers). Only the storage changes:
`NArray`'s elements are now the C cell's `len` slots, each encoded via `encodeSlotC`/decoded on
read. Let `n = wok_array_len(arr)`.

- **`new k v`** — `wok_array_alloc k`; write slot `i` = encode(`v`) for `i ∈ [0,k)`, `incref v`
  ×(k−1) (the array holds `k` refs; the arg supplies one), or `drop v` if `k == 0`. Net **+1 array
  alloc**.
- **`fromList xs`** — `wok_array_alloc (length xs)`; write/`incref` each element into its slot;
  `dropAddr` the list spine. Net **+1**.
- **`toList arr`** — read each slot, `incref` the counted ones into fresh `Cons` cells; build the
  list; `dropAddr arr`. Net **+N** cons cells, −1 array when unique.
- **`index arr i`** — bounds: `i ≥ n ⇒ PrimError`. Else decode slot `i`; `incref` if counted;
  `dropAddr arr`. Net **0**.
- **`length arr`** — `n = wok_array_len arr`; `dropAddr arr`; return `RVLit (LInt n)`. Net **0**.
- **`set arr i v`** (copy-on-write) — bounds: `i ≥ n ⇒ PrimError`. `wok_array_alloc n`; copy slots
  with `j = i ↦ v` (moved in) and `j ≠ i ↦ arr[j]` (`incref`); `dropAddr arr`. Net **+1**.
- **`resize arr m fill`** — `wok_array_alloc m`; `j < min(m,n) ↦ arr[j]` (`incref`),
  `j ∈ [n,m) ↦ fill`; `incref fill` ×(k−1) where `k = max(0, m−n)`, or `drop fill` if `k==0`;
  `dropAddr arr`. Net **+1**.

No partial functions: every slot access is guarded by the preceding bounds check.

## 5 · Bounds & error handling
`index`/`set` validate `i < n` and raise the existing `PrimError` (a `RuntimeError`) on violation,
same path as Slice A. `resize` accepts any target length (a huge `m` is a normal large allocation).
Validation at the prim boundary; internal slot access after the check is total.

## 6 · Descriptor & cascade integration
- An array cell is **recognized directly by `WOK_ARRAY_TAG`, not via `stConDesc`** (whose
  per-(constructor, slot) `[SlotKind]` shape does not fit a runtime-length array). The cell is
  self-describing: `len` at offset 8, the element `SlotKind` in `elemkind` at offset 6.
- **C-layer cascade (a new dispatch).** Today the `CAddr` arm of `dropAddr` assumes "a `CAddr` is
  always an `NCon`" and calls the descriptor-driven `readCConValues`. It gains a `WOK_ARRAY_TAG`
  branch: read `len` and `elemkind`; if `elemkind` is a **raw-lit** kind, free the cell with **no
  child drops**; if **pointer-scheme**, loop `wok_array_slot_get`, `dropAddr` the `CAddr`/`HAddr`
  slots (skip `Inline`), then `wok_free`. This is a new branch at the **C-decode layer** (the
  existing "CAddr is always NCon" comment must be updated); there is **no new `cascadeChildren`
  path** on the abstract side. The same `WOK_ARRAY_TAG` branch is needed in `deref`/`readCCell`
  (so `index`/`toList`/render read array slots) — see §4/§9.
- **FBIP stays array-free.** `nodeCEligible (NArray _) = False` and `nodeArity _ = 0` are unchanged,
  so Perceus never emits `drop_reuse` for an array and `dropReuse`'s `CAddr` arm never sees
  `WOK_ARRAY_TAG`. Only the regular `dropAddr`/`deref` `CAddr` paths get the array branch; arrays
  are never a reuse donor or target in this slice.
- `dup` of an array bumps only the cell's rc (shared prefix); elements are shared via the cell,
  identical to `NCon`.
- The abstract `NArray` keeps Slice A's `nodeValues (NArray vs) = vs` and the generic cascade
  fall-through (the oracle reference is unchanged).
- Extend the C-cell decoder/renderers so a `CAddr` with `WOK_ARRAY_TAG` (using `elemkind` to decode
  each slot) renders as `[a, b, c]`, byte-identical to the abstract `NArray` renderer.

## 7 · `peak_bytes` as a shared oracle invariant

Today `peak_bytes` is C-only (`cur_bytes`/`peak_bytes` in `WokHeap`); the abstract `Stats` tracks
only cell counts. To make `peak_bytes` a bit-for-bit oracle invariant:

- Add `stCurBytes`/`stPeakBytes` to the abstract `Stats`.
- Add a **shared pure** `wouldBeCBytes :: Node -> Int`: the bytes a node occupies *as a C cell*, or
  0 if it never becomes one. `NCon` (C-eligible) ⇒ `8 + 8·arity`; `NArray` ⇒ `16 + 8·len`;
  every abstract-only node (`NClosure`/`NEnv`/`NCont`/non-eligible `NCon`) ⇒ `0`. This mirrors C
  exactly: C charges `8 + 8·arity` in `wok_alloc` and `16 + 8·len` in `wok_array_alloc`, and never
  charges for abstract-only nodes.
- `recordAlloc :: Int -> Stats -> Stats` and `recordFree :: Int -> Stats -> Stats` gain an `Int`
  byte-delta parameter (the node's `wouldBeCBytes`), maintaining `stCurBytes` (±) and `stPeakBytes`
  (high-water) alongside the cell counters. The ~10 call sites — the two `recordAlloc` sites
  (`allocNCon`, `allocPure`) and the `recordFree`/`bumpFreeStats` sites (`dropAddrStepPure`,
  `freeReservation`, `moveOutContPure`, `allocAt`, and the `CAddr` drop path) — each compute the
  delta from the node being allocated/freed.
- **Oracle read:** on the CHeap backend `peak_bytes` is read from C (`wokStatPeakBytes`); on the
  AbstractHeap backend from `stPeakBytes`. They must be equal. Because both backends process the
  same program in the same order with identical per-node byte sizes, the high-water marks match
  (the same argument that already makes cell-count `peak` match).

This is the component that makes the *byte layout* — the point of "a real allocator layout" —
checkable, and it is the brief's named invariant ("bit-for-bit incl `peak_bytes`").

## 8 · Differential oracle requirements
For every array corpus program, on both backends:
- **Output byte-identical** (the C-cell renderer matches the abstract `NArray` renderer).
- **`alloc`/`free`/`peak` match exactly**, equal to the §4 per-op table (an array is **one** cell;
  inline-scalar elements add no cells; boxed elements are separate cells on both backends).
- **`peak_bytes` matches exactly** (§7), equal to the high-water of `Σ wouldBeCBytes`. The harness
  reads `wokStatPeakBytes` from the C heap **before** `wok_heap_free` (the `WokHeap` is freed in a
  `finally`); the abstract figure is `stPeakBytes`. The two must be equal.
- Heap returns to baseline at program end (no leak, no double-free): `stLive == baseline` and
  `wok_stat_live == 0`.

This proves the new C memory cell is faithful to the simple reference over the whole corpus.

## 9 · Testing
- **C-cell unit tests** (`runtime/test`, ASan/UBSan + LeakSanitizer via `scripts/asan-runtime.sh`):
  `wok_array_alloc`/`len`/`slot_get`/`slot_set` round-trips; byte-size-class routing (a freed
  len-`L` array and a freed arity-`(L+1)` `NCon` share `freelist[L+1]` — pointer-identity reuse);
  the large path (`len ≥ 63` ⇒ `malloc`, frees individually); slab-boundary bump; bulk teardown
  with no leak; the `WOK_ARRAY_TAG` free-dispatch (array byte size computed from `len`, not arity).
- **Reuse Slice A's behavioural + property tests against the C backend** (this is "use those tests
  to test the new implementation"): the Hspec per-prim + bounds-error tests and the QuickCheck
  properties (`toList (fromList xs) == xs`; `index (set a i v) i == v`;
  `j /= i ==> index (set a i v) j == index a j`; `length (new k v) == k`;
  `length (set a i v) == length a`; `length (resize a m f) == m`; grow/shrink tail behaviour;
  out-of-bounds raises `PrimError`) run on the CHeap backend.
- **Differential-oracle corpus** (`test/rc-array`, `test/rc-array-oob`): byte-identical output +
  matching `alloc`/`free`/`peak`/`peak_bytes` on both backends, for `Array U64`/`U32` (inline
  elements) **and** `Array [U64]`/`Array String` (boxed elements — exercises the counted-slot
  cascade). Heap returns to baseline.
- **Store-algebra unit tests** updated: the abstract `NArray` store-algebra tests stay (oracle
  reference); add C-cell-side `alloc`/`dup`/`dropAddr`/cascade assertions for the array `CAddr`
  path (inline-element array ⇒ empty cascade; boxed-element array ⇒ each child dropped once).

All via tasty (Hspec + QuickCheck). No temporary fixes; tests coherent to this spec and documented.

## 10 · Files touched
- `runtime/wok_rc.h` — `WOK_ARRAY_TAG`, the four `wok_array_*` signatures (additive).
- `runtime/wok_rc.c` — the `WokArray` cell, `wok_array_alloc` (byte-size-class routing),
  `wok_array_len`/`slot_get`/`slot_set`, `wok_free` array dispatch, `cur_bytes`/`peak_bytes`
  for arrays, the new `_Static_assert`s; the standalone `runtime/test` + `scripts/asan-runtime.sh`.
- `src/Wok/Interp/RC/Heap.hs` — FFI imports for the `wok_array_*` ABI.
- `src/Wok/Interp/RC/Value.hs` — route CHeap `NArray` alloc to the C cell (a new `alloc` branch,
  not via `allocNCon`); `internTag` reserves `0xFFFF` (`WOK_ARRAY_TAG`); array `CAddr` branch in
  `dropAddr`/`deref`/`readCCell` keyed on `elemkind` (`dropReuse` left NCon-only, arrays excluded
  from FBIP); decode/render; `Stats` gains `stCurBytes`/`stPeakBytes`; `wouldBeCBytes`;
  byte-aware `recordAlloc`/`recordFree`.
- `src/Wok/Interp/RC/Prim.hs` — the seven prims read/write C-cell slots on the CHeap backend
  (abstract path unchanged).
- the differential-oracle harness — assert `peak_bytes` equality (read C vs abstract `stPeakBytes`).
- `test/...` — C-cell unit tests; behavioural/property tests run on the C backend; oracle corpus
  extended with boxed-element arrays; store-algebra C-cell assertions.
- `runtime/README.md` — document the `WokArray` cell + the unified byte-size class.

No `Array → Vector` rename. No type-system change. No new prelude module (the existing `Std.Array`
+ `Array a` are unchanged in surface).

## 11 · Task breakdown (each ships green)
> Native tasks + model tiers are assigned at the writing-plans step. Indicative tiers below.

1. **C `WokArray` cell + ABI + standalone tests** (`wok_rc.{c,h}`, `runtime/test`,
   `scripts/asan-runtime.sh`): layout, `wok_array_*`, `wok_free` dispatch, byte-size-class routing,
   `peak_bytes` for arrays, static asserts; ASan/UBSan green. Ships green: C side passes; Haskell
   unchanged still builds. — *standard*.
2. **FFI bindings** (`Heap.hs`): the four `wok_array_*` imports. — *mechanical*.
3. **Route CHeap `NArray` to the C cell + cascade/dup/drop + decode/render** (`Value.hs`):
   descriptor registration, slot encode/decode reuse, array `CAddr` cascade. — *standard*.
4. **`peak_bytes` elevation** (`Value.hs` + oracle harness): `stCurBytes`/`stPeakBytes`,
   `wouldBeCBytes`, byte-aware `recordAlloc`/`recordFree`, oracle `peak_bytes` check. — *standard*.
5. **The seven prims on the C cell** (`Prim.hs`): C-slot read/write per §4, abstract path intact.
   — *standard*.
6. **Tests**: C-cell unit tests; Slice A behavioural/property tests on the C backend; oracle corpus
   incl. boxed-element arrays; store-algebra C-cell assertions; full suite + ASan green. — *standard*.
7. **Docs + memory**: `runtime/README.md`, the `array-slice-a-merged` memory note, the arc doc
   (mark Slice B done); clean up scaffolding. — *mechanical*.

## 12 · Decisions locked / deferred
**Locked:**
- `Array a` gets a real C `WokArray` cell on the CHeap backend; the abstract `NArray` is retained
  **only** as the differential oracle's reference.
- One polymorphic `Array a` type; **no rename**, no new type, no allowlist (the flat-vs-boxed split
  dissolves under wok's current types).
- 16-byte header with a runtime `len`; 8-byte slots reusing the 2-bit encoding; `WOK_ARRAY_TAG`
  discriminator; byte-size class `= bytes/8 − 1`, shared free-list with equal-size `NCon`s; large
  arrays `malloc`.
- `peak_bytes` elevated to a bit-for-bit oracle invariant via abstract byte tracking + shared
  `wouldBeCBytes`.

**Deferred (with triggers):** sub-word/float/signed scalar types; genuinely-unboxed multi-word
struct packing (`Array Vec4` + layout descriptor + materialize-on-`index`); capacity rounding /
rounding `sizeClass`; the `Sized` kind + pure-wok generic ops; length-indexed `ArrayOf n a`;
in-place `set` under `rc == 1` (Slice C); regions / LoCal; a geometric large-tier size class.

## 13 · Future direction
The runtime `len` kept here is exactly what a future **length-indexed `ArrayOf n a`** would wrap
(phantom or runtime-relevant `n`), so this slice founds that type-system epic without a runtime
change. Genuinely-unboxed elements (multi-word structs, sub-word scalars) reactivate the flat-vs-
boxed distinction and the `sizeClass` rounding; they layer on this same cell + ABI when the element
types exist.
