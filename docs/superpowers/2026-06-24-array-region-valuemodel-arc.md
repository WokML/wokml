# Array + Region value-model arc — design exploration & research

**Date:** 2026-06-24
**Status:** exploration captured; only **Slice A** is being specced now (see
`docs/superpowers/specs/2026-06-24-array-slice-a-design.md`). Everything below Slice A
is a recorded *direction*, not a commitment.
**Companion visuals:**
`docs/region-memory-design.html` (region design space) and
`docs/array-boxed-vs-unboxed.html` (boxed vs unboxed, annotated with Koka). Served locally
during the brainstorm via `python3 -m http.server` from `docs/`.

This document records the design space worked through while scoping fixed-size arrays as a
value-model citizen on the wok RC runtime. It exists so the long-horizon reasoning (regions,
LoCal serialization, the performance judgment) is preserved as the seed for future specs,
while keeping the immediate slice small.

---

## 1 · The arc (slice ladder)

Each rung is sound and useful on its own; later rungs hang off earlier ones.

1. **Slice A — boxed `Array a` on the abstract heap.** `new`/`fromList`/`toList`/`index`/
   `length`/copy-on-write `set`/`resize`. RC-managed, oracle-covered, no C cell. *This is the
   only rung being specced now.* It is the same design as Koka's `vector<a>` (see §4).
2. **Slice B — the real C `WokArray` cell.** A distinct large-object layout with a runtime-width
   `uint64 len` (the first wok value whose size is not `8 + 8·uint8`), its own `wok_array_*`
   ABI, allocated through the existing `WokHeap*` seam (so it is already region-ready). Oracle
   then proves abstract-vs-C byte+stat identity.
3. **Slice C — in-place `set` under `rc == 1`.** The FBIP runtime gate applied to a slot write:
   mutate-if-unique-else-copy. Reuses the `rc == 1` gate, *not* the `drop_reuse`/`alloc_at`
   pairing.
4. **Slice D — unboxed / flat arrays.** `Array U64`/`Array Char`/`Array <fixed struct>` packed
   inline with a per-element stride. The first serialization entry point; also the first place
   the boxing/cache win is measurable (alloc-count now, cache later at codegen).
5. **Region epic** — effect-scoped arenas (see §5, §6). Default **R** (RC-referenceable) +
   escape-routing; optional **F** (forbid-escape) fast tier. Copy-out (**D**) is deliberately
   never built.
6. **LoCal-serialized regions** — offset-linked, headerless DATA inside a region (see §7). The
   codegen-era endgame.
7. **String = flat bytes** — Koka's `kk_bytes_t` shape, *not* boxed `Array Char` (see §4, §9).

---

## 2 · The central representation departure

`WokObj` is `rc32 | tag16 | arity8 | scan8` then `slots[]` (`runtime/wok_rc.h`). `arity` is a
**`uint8` entry count** (number of 8-byte slots), max 255; cell size = `8 + 8·arity`
(`wok_cell_bytes`, `WOK_GRANULE = 8`). The arena buckets free-lists by arity (`< 64` → slab,
`>= 64` → `malloc`).

An array's length is a **runtime value**, unbounded by the `uint8` arity and with nowhere in the
header to live. So an array **cannot be an `NCon`**: it is the first **runtime-sized** citizen.
Slice A sidesteps this entirely by keeping `NArray` on the abstract `IntMap` heap (length =
`length vs`); Slice B introduces the wide-header C cell.

---

## 3 · The slot model (three buckets)

A slot is always 8 bytes; the per-constructor descriptor (`SlotKind`) plus a 2-bit low tag on
pointer slots says how to read it. Three buckets, not two:

- **Inline, uncounted** — word scalars (`KLitInt`/`KLitChar`/`KLitUnit`) and **all nullary
  constructors** as `Inline` immediates (`True`/`False`, `Nil`, `None`, enums; low bits `11`).
  `dup`/`drop` are no-ops.
- **Boxed, counted** — constructors-with-fields, records, tuples, closures (`NClosure`),
  recursive-group envs (`NEnv`), continuations (`NCont`/`NContCell`), strings, big integers, and
  the future `Array` cell. Slot = `CAddr` (low bits `00`) or non-negative `HAddr` (low bits
  `01`); `dup`/`drop` adjust the refcount.
- **Referenced, uncounted** — static/immortal cells (top-level binds / CAFs, the empty-env
  sentinel) at negative `HAddr`. Referenced out, but `isUncounted` makes `dup`/`drop` no-ops.

Odd ones: `RVInst` (unboxed identity pair, uncounted, but not C-slot-encodable → forces its
`NCon` to the abstract heap) and `RVReuse` (transient affine token).

**Consequence for arrays:** teardown cost is governed by the *element bucket*, not by
boxed-vs-unboxed representation. `Array U64`/`Array Bool` (inline/uncounted elements) have **no
counted children** → essentially O(1) teardown even while boxed. `Array String`/`Array <struct>`
(boxed/counted elements) cascade O(N). Unboxed packing (Slice D) then adds locality/memory wins
on top, not drop-count wins.

---

## 4 · Boxed vs unboxed — and what Koka actually does

Verified from the kklib headers (`vector.h`, `box.h`, `bytes.h`):

- **`vector<a>` is boxed** — `kk_box_t vec[]`, a contiguous run of pointer-sized boxed words.
  `kk_box_t` is one machine word; **LSB discriminates** pointer (0) from inline value (1, stored
  `n*2+1`). Small ints/bools/enums inline; structs/big-ints are pointers. *This is exactly wok's
  8-byte slot* (wok uses a 2-bit tag instead of 1-bit). So **wok's boxed `Array a` = Koka's
  `vector`.**
- **Koka does NOT pack structs inline into a vector.** `vector<Vec4>` is N pointers to N heap
  blocks. Even the Perceus reference language stops at boxed-word arrays for the general case.
- **Koka's `string` is NOT `vector<char>`.** It is `kk_bytes_t` — a flat `uint8_t` buffer (4
  reps incl. a small-string optimization, ≤7 bytes inline), a dedicated unboxed type, precisely
  because a boxed char-vector would be wasteful.

**The two array layouts:**
- **Boxed (`Array a`, Slice A/B):** each slot = pointer to a cell; polymorphic, elements
  shareable; `index` returns a pointer + dup (reference semantics). Indirection + per-element
  cell/header + per-element RC.
- **Flat/unboxed (Slice D):** struct stored inline with a stride (`Array U64` = stride 1; a
  32-byte `Vec4` = stride 4); contiguous, no per-element pointer/cell/RC; `index` copies the
  bytes out (value semantics). Needs a concrete monomorphic element layout; a per-element
  slot-kind vector if the struct holds pointers. (`[]Point` vs `[]*Point`.)

---

## 5 · Region design space (the memory-management options)

Effects decide **where** a value lives; RC decides **when** it dies. Keeping them separate is
what makes the safe design safe. Four ways to free a region:

- **F — forbid-escape.** Region values are second-class (uncounted), bulk-freed at scope close;
  escape is a **compile error** (the existing `Carrier.hs` check, the `Future` template).
  Fast + simple, but restrictive.
- **R — RC-referenceable.** Region values are normal counted RC values; the arena is reclaimed
  when its live-count hits 0 (RC-driven). Escape **just works** (an escapee keeps the arena
  alive). Simplest/safest, but pays full per-object RC; the arena is a locality/footprint
  optimization, not a skip-RC speed win.
- **R + escape (recommended).** Allocation-site routing: provably-local → uncounted arena
  (bulk-freed); might-escape → RC heap (counted). Recovers the skip-RC speed for the provable
  case, **needs no copy-out** (the escapee is *born* in the RC heap), **no compile errors**
  (unprovable degrades gracefully to RC). This is Tofte–Talpin / Go-style escape routing, and
  the most wok-native option ("lifetime as analysis").
- **D — copy-out promotion.** Arena-first, copy survivors out at the boundary. Optimistic +
  flexible, but needs a deep-copy walker + a *novel* soundness proof. **Deliberately not built.**

**Tradeoff triangle** — {escape allowed, skip-RC speed, simple (no copy machinery)}; any single
design gets two. Escape analysis is a *third axis* that lets R+escape reach all three, paying in
analysis precision/effort instead.

**Cost of R (why it's slower than skipping RC):** RC's real cost is write traffic — every
`dup`/`drop` writes a header, and teardown is **O(N) drops** vs a true region's **O(1)**
bulk-free. The gap is large only for deeply-boxed cohorts; for flat/unboxed data it nearly
vanishes (drop already O(1)). In wok this is oracle-visible: the differential oracle counts
`frees`.

---

## 6 · Route 1 feasibility — deep-research verdict

Research question: can sound effect-scoped bulk-free regions be had **without lifetime-in-types**
(no `Array r a`, no rank-N ST trick) for a Perceus + algebraic-effects language? 22 primary
sources, 25 claims adversarially verified (24/25 unanimous, 0 killed).

**Verdict: yes, but only as a hybrid** — second-class + escape analysis carry the
stack-disciplined case with no type machinery; a dynamic fallback is *mandatory* for anything
that escapes. wok's leaner answer (forbid-escape / R+escape routing) discharges the fallback by
**rejection or up-front routing**, so the fallback can be vacuous.

- **Tofte–Talpin / ML Kit:** region inference is a static analysis; `letregion` = arena +
  O(1) pop. Soundness side condition: free a region only if its region var is free in neither
  the type env nor the result type — i.e. *nothing escaping resides in the arena*. Precision
  pitfalls: the "Ground Rule" (values live to scope end even if dead earlier) and escaping-put
  space leaks — both **neutralized by wok's RC default**, *if* arena values stay counted.
- **Cyclone:** proves **pure lexical scoping is insufficient** once escaping constructs exist
  (closures/existentials — and for wok, escaping/multi-shot continuations); when it relaxed LIFO
  to dynamic regions it **added a runtime check**. wok's analogue is the `rc == 1` gate. Cyclone
  also layers RC on its region/affine discipline via one shared flow analysis (prior art that
  RC + region coexist).
- **Effekt / System C (closest precedent):** all blocks/capabilities are **second-class**
  (cannot return/store), no region/effect tag in the type; effect safety = "capabilities shall
  not escape their handler." The authors **explicitly recommend** "region appears in the type
  only on escape." BUT Effekt's escape mechanism is **boxing** (region into the type), *not* RC +
  copy-out — so wok's RC fallback is wok's own contribution, argued fresh.

**Soundness obligations:** O1 nothing reachable after close resides in the arena; O2 anything
not provably local must be promoted/routed-out before close (wok: *rejected or routed to RC*,
the conservative-safe direction); O3 captured continuations must not resume into a freed region
nor carry region pointers past close (wok's `Carrier.hs` + `Multiplicity.hs` already forbid
this).

**Open problems (the Region epic's research agenda):** count ownership at the region boundary;
whether one-shot/multiplicity suffices for captured-continuation soundness or copy-out is forced;
the shape of the soundness theorem (Effekt-preservation / Cyclone garbage-stack analogue over
wok's CPS IR with escape + `rc==1` gate); region pollution under long-lived handlers (RC default
neutralizes it only if arena values stay counted, else need an ML-Kit `resetRegion` analogue).

**wok's existing machinery covers most of it:** the second-class carrier check (`Carrier.hs`,
the `Future` template), the multiplicity/one-shot analysis (`Multiplicity.hs`), and the
handler abort/resume hooks (`KHandleRC`, `cascadeChildren`, `moveOutCont`). Missing: runtime
arena scoping (`wok_heap_checkpoint`/`reset` or a sub-`WokHeap`) and IR-level alloc routing.

---

## 7 · LoCal-in-region (the serialization endgame)

LoCal/Gibbon serializes a whole structure into a flat preorder buffer — no per-node header, no
inter-node pointers, cursor traversal. Its blocker in wok is that **per-object RC needs a
per-object header**, which a serialized buffer lacks. **A region dissolves that blocker**:
region-granular lifetime means nodes inside need no per-node refcount, so they can be
headerless/serialized/offset-linked. *Serialized DATA is sound only inside a region.*

A spectrum (the user's "offset to next Cons" is the Gibbon random-access point):

| representation | "next" reference | RC granularity | random access | serializable | mutation |
|---|---|---|---|---|---|
| boxed (today) | 8B absolute pointer | per-object | O(1) | no | FBIP in-place |
| based / offset | region-relative offset | region | O(1) `base+off` | yes | harder |
| Gibbon random-access | inline + shortcut offset | region | O(1) skip | yes | append |
| pure LoCal | implicit (cursor) | region | O(scan) | yes | write-once |

Constraints: region-RC only; random access degrades for variable-size fields (offsets
mitigate); mutation/FBIP hard (write-once favoring); cycles forbidden; outbound references to the
RC heap must be scanned by type-directed buffer-walking at region-free; **DATA only** (closures/
continuations/env-maps are STATE and stay boxed). For arrays: serialization with **fixed-size
elements is exactly the flat unboxed array** (Slice D, O(1) index); variable-size element arrays
can't keep O(1) index serialized. The full win is a **codegen-era** thing (Gibbon's speedups are
compiled traversals; wok is an interpreter today).

---

## 8 · Performance judgment (will eliminating boxing / pointer-chasing pay off?)

**Yes in principle, and potentially large — but conditional, and two of three conditions are
not yet true in wok.** The lever is the memory wall: pointer-chasing is a dependent-load chain
the prefetcher can't hide; boxing wastes cache density; contiguous/unboxed enables prefetch +
SIMD. Multi-× speedups on memory-bound traversals are routine (Gibbon is the existence proof).

Conditions: (1) **codegen** — in the interpreter, interpretation overhead dominates guest-data
layout, so the cache win is largely invisible until native code (missing); (2) **memory-bound
workloads** — huge for data-intensive traversals, ~nil for control-heavy code (unknown);
(3) **measurement** — wok's alloc/free counts are blind to cache misses; confirming needs
wall-clock + cache benchmarks on a real backend (missing). Perceus already elides most RC
*traffic*, so the remaining target is allocation overhead + cache density + indirection.

**Recommendation:** treat unboxing/serialization as a **high-value codegen-era investment**.
Build the foundations now (Slice A→D, regions) because they're the right shape regardless; make
**Slice D** the first measurable taste (alloc-count now, cache later); **defer LoCal** until
there is a backend to realize it and a benchmark that demands it. Let measurement — not faith —
drive the aggressive parts.

---

## 9 · String (Slice E)

`String` and string literals are **untouched** by the array slices. String stays its own
`TcString` type with literals as non-C-encodable abstract-heap values. When `String` is
eventually rebuilt (Slice E), Koka's `kk_bytes_t` evidence (§4) is decisive: make it a
**dedicated flat unboxed byte buffer with small-string optimization**, not a boxed `Array Char`.

---

## 10 · Decisions locked / deferred

**Locked:**
- Slice A = RC-managed, type-system-first boxed `Array a` on the abstract heap. Ships first.
- Regions are a separate epic, *after* Slice B; **R + escape-routing** is the recommended model;
  **copy-out is never built**.
- `String` redesign is deferred (Slice E), and will be flat-bytes, not `Array Char`.
- Effects choose *where*; RC decides *when*.

**Deferred (with explicit triggers):** C cell (B), in-place `set` (C), unboxed/flat (D — the
first perf-measurable rung), regions (R/F), LoCal serialization (codegen-era), String (E).
