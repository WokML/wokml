# Slice A — fixed-size `Array a` (boxed, abstract heap)

**Date:** 2026-06-24
**Status:** spec, approved for autonomous implementation (interpreter-level change).
**Context doc:** `docs/superpowers/2026-06-24-array-region-valuemodel-arc.md` (the full
value-model arc; Slices B–E, regions, LoCal, String are deferred there).
**Companions:** `docs/array-boxed-vs-unboxed.html`, `docs/region-memory-design.html`.

## 1 · Goal & non-goals

Add a fixed-size, homogeneous, indexable `Array a` as a first-class, type-checked citizen on
the RC interpreter, with correct reference-count accounting validated by the differential
oracle. This is the same design as Koka's `vector<a>`: a contiguous run of **boxed** element
slots, each a counted child.

**In scope (Slice A):** the `NArray` node on the abstract heap; the `Array a` type; the seven
ops `new`/`fromList`/`toList`/`index`/`length`/`set`/`resize`; bounds-checked access; the
`Std.Array` prelude; unit + property + differential-oracle tests.

**Out of scope (deferred, see the arc doc):** the C `WokArray` cell (Slice B); in-place `set`
under `rc == 1` (Slice C); unboxed/flat packing (Slice D); regions; LoCal serialization;
`String` redesign. `set` is **copy-on-write only**; `resize` **requires a fill value**.

## 2 · Architecture

A new heap node:

```haskell
data Node = ... | NArray [RCValue]
```

routed to the **abstract `IntMap` heap on both backends** (exactly like `NClosure`/`NEnv`/
`NCont` today — `alloc` keeps non-`NCon` nodes on the abstract heap). There is **no C cell** in
Slice A. The array's length is `length vs`.

Elements are **boxed**: each slot is an `RCValue`, a counted child reached through the existing
`countedRefs`/cascade. An array's cell owns one reference to each *counted* element (inline/
uncounted elements — `U64`, `Char`, nullary immediates — contribute nothing to the cascade).

**Asymptotics caveat (deliberate):** the abstract model uses a Haskell list, so `index` is
O(i) and `length` is O(n) *in the reference interpreter*. This is irrelevant to the oracle
(which checks output + alloc/free/peak, never wall-clock). The O(1) `index`/`length` promise is
a property of the *value-model design*, realized by the C cell in Slice B. Slice A pins
**semantics and RC accounting**, not interpreter asymptotics.

## 3 · Type system & surface

- `Types.hs`: add `TcArray` to `TyCon`.
- `Builtins.hs`: register `("Array", TyConInfo (KArrow KStar KStar) 1 [] False [KStar])`
  (kind `* -> *`, arity 1, no user constructors, not a carrier).
- `Infer.hs` `nameToCon`: `"Array" -> TcArray`.
- New `prelude/Std/Array.wok`:

```
module Std.Array
import Std.Base

extern type Array a

extern Array.new      : U64 -> a -> Array a
extern Array.fromList : [a] -> Array a
extern Array.toList   : Array a -> [a]
extern Array.index    : Array a -> U64 -> a
extern Array.length   : Array a -> U64
extern Array.set      : Array a -> U64 -> a -> Array a
extern Array.resize   : Array a -> U64 -> a -> Array a
```

- `Prelude.hs`: add `stdArrayName`/`stdArraySource` loaders; register `prelude/Std/Array.wok`
  as a cabal data-file.
- `PrimNames.hs`: name constants, matched by qualified `(Std.Array, <name>)` identity (the
  extern convention), not by hint.

The index type is `U64`. Element type `a` is fully polymorphic.

## 4 · Operations & RC semantics (the soundness core)

**Convention (verified against `Escape.hs` + `enterPrim`):** a prim *owns* its arguments
(operands escape / move in); it must drop them or transfer them into the result. The Perceus
pass inserts `dup` for any value used more than once, so "consume" is always balanced. Each prim
is store-threading: `rpFn :: [RCValue] -> Store -> RC (RCPrimResult, Store)`, returning
`(PRDone result, s')`.

Let `n = length arr`. The precise dup/drop sequence per op:

- **`new k v`** — `k : U64` (uncounted), `v` owned (1 ref). The result owns `k` refs to `v`.
  If `k == 0`: `drop v`; `alloc (NArray [])`. Else: `incref v` ×(k−1) so the array holds `k`
  refs; `alloc (NArray (replicate k v))`. Net **+1 alloc**.
- **`fromList xs`** — `incref` each element as it is collected (the array acquires its own ref);
  build `NArray`; `dropAddr xs` (the list head). The list cascade releases the spine and the
  original element refs, so each element nets **transfer** (our +1, list −1). Works for unique
  *and* shared `xs` (shared: spine survives, array holds independent +1s). Net **+1 alloc**,
  spine freed when unique.
- **`toList arr`** — for each element `incref` it into a fresh `Cons` cell; build the list;
  `dropAddr arr` (cascade releases arr's element refs + the array cell). Net **+N alloc** (cons
  cells), **−1** (array) when unique.
- **`index arr i`** — bounds: `i >= n` → `PrimError "Array.index: out of bounds"`. Else
  `el = arr[i]`; `incref el` (result owns it); `dropAddr arr` (consume). Unique arr: cascade
  frees the array and drops every *other* element; `el` survives via the incref. Shared arr:
  decrement only; `el` carries our +1. Returns `el`. Net **0 alloc**.
- **`length arr`** — `len = n`; `dropAddr arr` (consume); return `RVLit (LInt len)`. Net **0**.
- **`set arr i v`** (copy-on-write) — bounds: `i >= n` → `PrimError`. Build the new element
  list: slot `i` = `v` (moved in), every other slot `j` = `arr[j]` with `incref arr[j]`
  (n−1 increfs); `alloc (NArray new)`; `dropAddr arr` (consume → cascade drops each `arr[j]`:
  j≠i nets 0, old `arr[i]` released). Net **+1 alloc**. Correct for unique and shared input.
- **`resize arr m fill`** — `m : U64`, `fill` owned. Let `t = min(m, n)`, `k = max(0, m − n)`
  (new slots). Build length-`m` list: `j < t` → `arr[j]` with `incref`; `j` in `[t, m)` → `fill`
  (the array needs `k` refs to it). `fill`: if `k >= 1`, `incref fill` ×(k−1) (we contribute the
  last ref by moving the arg in); if `k == 0`, `drop fill`. `alloc (NArray new)`;
  `dropAddr arr` (cascade: copied prefix nets 0; truncated tail `[t, n)` released). Net **+1**.

No partial functions: every list index is guarded by the preceding bounds check; the
implementation must not use `!!`/`head` unguarded.

## 5 · Bounds & error handling

`index` and `set` validate `i < n` and raise the existing `PrimError` (a `RuntimeError`) with a
clear message on violation — the same path other runtime errors use. `resize` has no index to
check (any target length is valid; a huge `m` is a normal large allocation). Validation happens
at the prim boundary; internal list access after the check is total.

## 6 · Descriptor & cascade integration

- `nodeValues (NArray vs) = vs`.
- `cascadeChildren` keeps its generic fall-through (`countedRefs (nodeValues other)`), so
  freeing an array drops each counted element exactly once; uncounted elements are skipped by
  `isUncounted`. **No new cascade path** and no `NCont`-style special case.
- `dup` of an array address bumps only the array cell's rc; elements are shared via the cell
  (identical to `NCon`). The drop cascade is the single release path.
- Extend the store-aware renderers (`renderRCValue*`) for `NArray` (e.g. `[a, b, c]`-style).
- `NArray` is never C-eligible (`nodeCEligible` stays `False` for it) and is never a reuse
  donor/target in this slice.

## 7 · Differential oracle requirements

Every array corpus program runs on both backends. In Slice A `NArray` lives on the abstract
heap on *both* (the C backend also stores it in the `IntMap`), so:

- **output is byte-identical** between backends, and
- **`alloc`/`free`/`peak` match exactly**, equal to the per-op table in §4
  (`new`/`fromList`/`set`/`resize` = +1 alloc; `index`/`length` = 0; `toList` = +N; array free =
  1 free + cascade of counted elements).

This proves arrays do not desync the oracle and pins the alloc accounting. The richer
abstract-vs-C-cell byte+stat identity test arrives with Slice B.

## 8 · Testing

- **Store-algebra unit tests** (`alloc`/`incref`/`dropAddr`/cascade on `NArray`): build, dup,
  drop, cascade with boxed-counted elements (e.g. `Array String`) *and* inline-uncounted
  elements (e.g. `Array U64`) — assert `stLive` returns to baseline and no double-free.
- **Hspec** per prim: behaviour + the bounds-error path for `index`/`set`.
- **QuickCheck properties:**
  - `toList (fromList xs) == xs`
  - `index (set a i v) i == v`
  - `j /= i ==> index (set a i v) j == index a j`
  - `length (new k v) == k`
  - `length (set a i v) == length a`
  - `length (resize a m f) == m`
  - growing then indexing the new tail yields the fill; shrinking drops the tail
  - out-of-bounds `index`/`set` raise `PrimError`
- **Differential-oracle corpus**: small `.wok` programs exercising each op and the §4 alloc
  table; assert byte-identical output + matching `alloc/free/peak` on both backends. Heap must
  return to baseline (no leak, no double-free) at program end.

All tests via tasty (Hspec + QuickCheck). No temporary fixes; tests must be coherent to this
spec and documented.

## 9 · Files touched

- `src/Wok/Interp/RC/Value.hs` — `NArray` node; `nodeValues`; renderers; (cascade unchanged).
- `src/Wok/Interp/RC/Prim.hs` — the seven prims + `prims` list entries.
- `src/Wok/IR/PrimNames.hs` — qualified `(Std.Array, …)` name constants.
- `src/Wok/TypeChecking/Types.hs` — `TcArray`.
- `src/Wok/TypeChecking/Builtins.hs` — register `Array`.
- `src/Wok/TypeChecking/Infer.hs` — `nameToCon`.
- `prelude/Std/Array.wok` — new module.
- `src/Wok/Prelude.hs` — `stdArray*` loaders.
- the cabal file — register the prelude data-file.
- `test/...` — unit, property, oracle suites.

## 10 · Acceptance criteria

- [ ] `Array a` type-checks; the seven ops have the §3 signatures; misuse is a type error.
- [ ] All seven ops behave per §4; bounds violations raise `PrimError`.
- [ ] RC accounting matches §4 exactly; heap returns to baseline at program end (no leak, no
      double-free) on every test and corpus program.
- [ ] The differential oracle is byte-identical and stat-identical on both backends for all
      array corpus programs.
- [ ] Full suite green (the existing count plus the new tests); ASan/sanitizer clean where the
      C runtime is exercised (unchanged in Slice A, but the harness still runs).
- [ ] No partial functions; `src/` style (Strict/StrictData, explicit exports, qualified
      imports, type signatures, hlint-clean excluding `src-generated`).
