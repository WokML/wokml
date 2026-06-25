# wok C runtime (`wok_rc`)

A byte-dumb, `malloc`-backed C heap for wok's reference-counted constructor cells
(`NCon`), reached from the RC interpreter (`Wok.Interp.RC.*`) over FFI.

This document is the **durable ABI contract** the runtime exposes. The current sole
client is the RC interpreter, but the layout and the function ABI are deliberately the
same surface a **future codegen backend will emit calls against**. Treat everything
below as a contract:

> **This layout and ABI is the contract future codegen emits against. Changing any of
> it (struct layout, slot-tag encoding, or a function signature) requires a coordinated
> codegen update — it is not a free internal refactor.**

Design rationale lives in
`docs/superpowers/specs/2026-06-21-c-runtime-allocator-ncon-design.md`. The files are
`runtime/wok_rc.h` (ABI) and `runtime/wok_rc.c` (implementation).

---

## Object and slot layout

An **8-byte header** plus one **8-byte raw word per slot** (no per-slot tag), locked with
`_Static_assert(sizeof(WokObj) == 8)` so a layout drift fails the compile.

```c
typedef struct WokObj {
    uint32_t rc;       // reference count (>= 1 while live)
    uint16_t tag;      // interned constructor id (opaque to C) -> indexes the Haskell descriptor
    uint8_t  arity;    // number of slots (0..255)
    uint8_t  scan;     // RESERVED for a future C cascade (always 0 today; no write path)
    uint64_t slots[];  // `arity` raw 8-byte words
} WokObj;
```

- Total cell size is `8 + 8 * arity` bytes — ~50% smaller than the original 16B header +
  16B slots, ~2x cache density.
- A slot is **one raw `uint64`**; there is no self-describing tag word. The per-slot *kind*
  (int / char / unit / pointer) is hoisted into a shared **per-constructor descriptor** on
  the Haskell side (`stConDesc :: IntMap [SlotKind]`, keyed by `tag`) — recorded once per
  constructor instead of re-stamped in every cell. `tag` is the index into it (wok's
  analogue of an info-table pointer, but a 16-bit index).
- `tag` is a `uint16` interned id — **C never interprets it**; the constructor's identity
  (the APrim `(Module, Name)`) stays Haskell-side (`internTag`/`tagName`). `wok_alloc`
  asserts `tag < 65536 && arity < 256` before packing.
- `rc` is unsigned (32-bit). `wok_dec` on a zero cell / `wok_free` on a non-zero cell abort
  (the C analogues of the double-free / premature-free guards).
- The header fields are **private behind the accessor ABI**, so the compaction is not a
  layout ABI break. The slot accessors themselves became **one word**
  (`wok_slot_set(p,i,word)` / `wok_slot_get(p,i)->uint64`) — the one deliberate
  accessor-signature change.
- A **nullary constructor** (zero fields: `Nil`/`None`/`True`/`False`/any `data T = A`) is
  **never a cell**. It is an **inline immediate** (`RVBox (Inline tag)`): the interned tag
  rides directly in the slot/binding word (low 2 bits `11`; see the slot table), so the C
  heap never holds an arity-0 cell. `wok_alloc` is therefore only ever called with
  `arity >= 1`. Constructing a nullary value allocates nothing and dup/drop on it are no-ops
  (it is uncounted). The additive `wok_stat_peak_bytes` accessor reports the high-water live
  bytes (`Σ 8 + 8*arity`) for benchmarking; it does not affect the ABI.

## Slot encoding (descriptor-driven)

A slot is one raw `uint64`; its meaning comes from the constructor's **descriptor**, not
from the slot. `decodeSlotC :: SlotKind -> Word64 -> RCValue` is driven by the recorded kind;
`encodeSlotC :: RCValue -> Maybe (SlotKind, Word64)` is its inverse. **Encoding semantics are
unchanged from the 16B era** — no range-widening, no promotion:

| `SlotKind` | the raw word holds | `RCValue` shape |
| ---------- | ------------------ | --------------- |
| `KLitInt`  | `int64` bit pattern | `RVLit (LInt n)`, `n` fits in `Int64` |
| `KLitChar` | code point          | `RVLit (LChar c)` |
| `KLitUnit` | `0`                 | `RVLit LUnit` |
| `KPointer` (low 2 bits `00`) | `WokObj*` bits     | `RVBox (CAddr p)` — another C cell |
| `KPointer` (low 2 bits `01`) | `(i << 2) \| 1`    | `RVBox (HAddr i)` — IntMap-resident node |
| `KPointer` (low 2 bits `11`) | `(tag << 2) \| 3`  | `RVBox (Inline tag)` — a **nullary constructor as an inline immediate**, NO cell |

The kind distinguishes scalar-vs-pointer (a per-constructor constant); for a pointer slot the
**low 2 bits** discriminate three runtime pointer-classes (Koka-style, bit 0 = pointer-vs-value):
a C cell (`CAddr`, ≥8-aligned → `00`, read as-is), an abstract-heap child (`HAddr`, stored
`(i << 2) | 1` → `01`, decoded by arithmetic `>> 2` so negatives sign-extend), or an **inline
immediate** (`Inline tag`, stored `(tag << 2) | 3` → `11`, decoded `>> 2`). The `10`
combination is never produced. This split is runtime-dependent (the same `Maybe a` field holds
a `Some` pointer in one cell and a `None` immediate in another), so it stays in the word; the
descriptor still records the slot as a single `KPointer` kind — `KPointer` subsumes
"pointer-or-immediate".

### Encodable-or-fallback rule

The whole `NCon` falls back to the Haskell `IntMap` heap (as an `HAddr`) when ANY of:

- a field is `RVLit (LStr _)`, a bignum / high-bit-`U64` `RVLit (LInt n)` (doesn't fit
  `Int64`), `RVRecMember`, or `RVInst` (not encodable — unchanged);
- the constructor's slot kinds **differ from a previously-recorded descriptor** for the same
  tag. wok constructors are nominal/polymorphic, so the same name can appear at different
  instantiations (`Tuple2(ptr,int)` vs `Tuple2(int,int)`); first-kind-seen wins the C heap,
  the rest fall back — keeping the descriptor consistent for every C cell of a tag;
- `arity > 255` (exceeds the `uint8` arity field).

The fallback is alloc-site heap selection (everything downstream dispatches on `Addr`), and
is **never runtime promotion** — a value is built once on whichever heap fits it.

## WokArray cell (boxed arrays)

An array is the first **runtime-sized** cell: its length is a value, not a compile-time
constant, so it cannot fit in the `uint8 arity` field. A `WokArray` is a **16-byte header**
plus a runtime number of 8-byte slots (cf. `NCon`'s 8-byte header + arity-many slots). It reuses
the `WokObj` struct (same 8-byte prefix, so `wok_dup`/`wok_dec`/`wok_tag` work unchanged); there is
no separate `WokArray` typedef. `tag == WOK_ARRAY_TAG` marks it an array, the `arity` byte is
repurposed to hold `elemkind`, and the element count `len` lives at offset 8 with the slots at
offset 16:

```c
/* layout (reinterprets WokObj; no separate struct) */
offset 0   uint32_t rc        /* reference count (>= 1 while live)                              */
offset 4   uint16_t tag       /* WOK_ARRAY_TAG = 0xFFFF                                          */
offset 6   uint8_t  elemkind  /* the WokObj `arity` byte, repurposed: element SlotKind (uniform) */
offset 7   uint8_t  scan      /* unchanged WokObj field (reserved, 0)                            */
offset 8   uint64_t len       /* element count                                                  */
offset 16  uint64_t slots[]   /* `len` raw 8-byte words                                          */
```

- Total cell size is `16 + 8 * len` bytes.
- The `tag` is always `WOK_ARRAY_TAG` (0xFFFF), reserved Haskell-side (`internTag`).
- The `elemkind` (a `SlotKind`) is uniform: all slots decode the same way (raw int, char, unit,
  or pointer). Teardown is driven by `elemkind`: raw-lit kinds (`KLitInt`/`KLitChar`/`KLitUnit`)
  mean zero counted children (uncounted drop), while `KPointer` means each slot is reference-counted
  (`CAddr` or `HAddr`) or an inline immediate and must be dropped per the slot-encoding rules.
- Slots reuse the same inline-or-pointer 2-bit encoding as `NCon` slots: scalar values inline
  (`KLitInt`/`KLitChar`/`KLitUnit`) or pointer-scheme (`KPointer` with low-2-bits discriminating
  `CAddr`/`HAddr`/`Inline`).

### Byte-size class unification

Both `NCon` and `WokArray` share the slab arena via a **unified byte-size class**: `class = bytes/8 - 1`.

- An `NCon` of arity `a` has size `8 + 8*a` → class `a` (unchanged).
- A `WokArray` of length `L` has size `16 + 8*L` → class `L+1`.
- Arrays and NCons of the same class share `freelist[class]`: a WokArray of length `L` can
  reuse a freed NCon of arity `L+1` (both occupy `(L+1)*8 + 8` bytes), and vice versa.
  This is shape-agnostic recycling.

Arrays with `len <= 62` (≤ 512 B) use the slab arena; `len >= 63` (> 512 B) bypass the arena
and call `malloc` directly (the same threshold that applies to `NCon` arity).

### ABI

```c
WokObj*  wok_array_alloc(WokHeap* h, uint64_t len, uint8_t elemkind);  // rc=1, tag=WOK_ARRAY_TAG
uint64_t wok_array_len(const WokObj* p);       // WOK_PURE
uint32_t wok_array_elemkind(const WokObj* p);  // WOK_PURE
void     wok_array_slot_set(WokObj* p, uint64_t i, uint64_t word);
uint64_t wok_array_slot_get(const WokObj* p, uint64_t i);  // WOK_PURE
```

Slots hold the same pre-encoded 8-byte words as `NCon` slots: `wok_array_slot_set`/`get` move a
single raw `word` in/out (at offset `16 + 8*i`). The 2-bit slot encoding/decoding is done
Haskell-side (`encodeSlotC`/`decodeSlotC`) using the cell's `elemkind`; the C side treats the
word as opaque.

### Unified byte accounting

The `wok_stat_peak_bytes` counter now accounts for both NCon and WokArray cells:

- An `NCon` of arity `a` charges `8 + 8*a` bytes.
- A `WokArray` of length `L` charges `16 + 8*L` bytes.

The C runtime re-derives the byte size from the cell header at free time — `wok_free` reads the
`tag` first: `WOK_ARRAY_TAG` → `16 + 8*len`, otherwise `8 + 8*arity` — so it stores no per-cell
byte field. (The Haskell abstract heap is the side that stores a per-`Cell` `cBytes`: a
descriptor-mismatch fallback there charges 0 bytes, so re-deriving via `wouldBeCBytes` would be
unsound. That is an abstract-interpreter detail, not part of the C ABI.)

The differential oracle validates that abstract-interpreter `stPeakBytes` matches the C
runtime's `wok_stat_peak_bytes` on all test-suite runs.

## Self-policing PHYSICAL-memory invariant

The oracle above checks **logical** accounting (live bytes via `cur_bytes`/`peak_bytes`,
`allocs`/`frees`). It is structurally **blind to physical memory** — the slabs the runtime
holds from the OS. A bug can grow slabs **without bound** (O(number of cycles)) while the byte
accounting stays perfectly balanced; LeakSanitizer misses it too (the slabs are freed at heap
teardown, just accumulated during the run). This is a whole *class* of bug, not one site.

Rather than chase it with one ad-hoc bounded-ness test per allocator, the allocator
**self-polices**: it tracks its own physical high-water and asserts a bound against the logical
high-water, so **every test that runs the runtime checks the class for free** (the whole suite,
under sanitizers).

### `wok_stat_peak_physical_bytes`

```c
uint64_t wok_stat_peak_physical_bytes(const WokHeap* h);  // WOK_PURE
```

The high-water **physical** bytes the heap held from the OS — every slab `malloc`
(`WOK_ARENA_SIZE` each, counted and arena regions) plus every large-object/array `malloc`
(arity ≥ 64 / len ≥ 63). On the `WOK_RC_MALLOC` backend (one `malloc` per cell) physical tracks
logical closely. Distinct from `peak_bytes` (logical live bytes): `peak_physical` is the
structural memory the process retained at its worst, regardless of how densely the logical bytes
packed into the slabs. **Additive**, mirroring `wok_stat_peak_bytes`; bound Haskell-side as
`wokStatPeakPhysicalBytes`. The **tracking is always-on** (two adds at the malloc boundary —
cheap), present in both the interpreter build and the sanitizer build.

### The bound (heuristic, debug/sanitizer-build only)

A bump+free-list allocator packs densely, so physical high-water stays within a bounded factor
of logical high-water, plus an additive slab-granularity headroom for small programs (a tiny
program holds whole slabs against a few bytes of logical data — that ratio is unbounded, which
is why the additive term, not a pure ratio, is needed):

```
peak_physical_bytes  <=  K * peak_logical_bytes  +  C * WOK_ARENA_SIZE
```

`peak_logical_bytes` is the high-water of total live logical bytes (counted `cur_bytes` + arena
`arena_bytes`, the peak of the **sum**). **K = 4, C = 8** (8 slabs = 512 KiB). K covers the
trailing half-empty slab of each region plus free-list slack (~2x measured) with headroom; C is
the slab-granularity floor for small programs and arena nesting depth. Measured per-heap margins:
the heaviest workloads (T10 grow-heavy 200-cycle arena, 9000-cell deep lists, large arrays,
counted+arena concurrent) all sit at ≥ 4.2x slack under the bound, while a seeded slab-orphaning
leak blows straight past it.

The bound is checked where it is cheap and catches early — at each slab `malloc` (after the
physical high-water updates) and at `wok_heap_free`. On violation it prints
`peak_physical=… peak_logical=… bound=…` and `abort()`s.

**Gating.** Only the `abort()` assertion is gated, behind `WOK_RC_CHECK_PHYSICAL` — a *release*
build must never abort on a memory heuristic. `scripts/asan-runtime.sh` defines it (plus
`WOK_RC_PHYSICAL_TEST_HOOK`) so the assertion is active across all of T1–T10 + the deep tests —
the "checked everywhere for free" payoff. The cabal/interpreter build (`wok.cabal`, `-O3`) does
**not** define it, so the interpreter gets the cheap tracking without the heuristic abort.

### Negative + positive controls

`runtime/test/wok_arena_test.c` carries the permanent controls:

- **T11 (negative control, death test):** a test-only hook `wok_test_orphan_slabs(h, n)`
  (compiled only under `WOK_RC_PHYSICAL_TEST_HOOK`) mallocs `n` slabs and folds them into the
  physical high-water with **no** logical allocation — exactly the slab-orphaning shape. Under
  `WOK_TEST_DEATH=physical` the invariant `abort()` **must** fire (SIGABRT / exit 134). The asan
  script runs this and fails if it does *not* abort (a regression that left the assertion inert).
- **T12 (positive control):** a grow-heavy-then-free workload (T10-shaped) where the invariant
  holds — `peak_physical` stays bounded (~2 slabs, recycled, not O(cycles)) and never trips.

> **Interpreter-era / codegen-transitional.** This entire physical-memory concern —
> slabs, free-lists, the bump arena, and this invariant — is **replaced when codegen lands**
> (the arena becomes a stack frame, etc.). It is deliberately a **cheap runtime self-check**, not
> long-lived test infrastructure: it exists to police the interpreter-era allocator, and it goes
> away with the model it polices.

## Per-activation arena tier (uncounted, Region Slice R1)

An **uncounted arena** is a separate bump region within the `WokHeap`, dedicated to storing
**provably non-escaping function-local allocations**. Region cells live for the duration of
their activation and are reclaimed wholesale in O(1) when the activation ends, with no
reference-counting overhead.

### Motivation

Function-local allocations (scratch cohorts created and consumed within a function body)
need not pay the full RC tax — per-cell `dup`/`drop` writes + the cascade walk on drop.
An arena routes these to a *separate, uncounted tier* (identical cell layout, inert RC),
reclaimed in bulk at scope close via a fast frontier reset. The win is measurable in the
differential oracle: reduced counted `allocs`/`frees` for any module that routes locally-
bound values to the arena, and a new `arena_bytes`/`arena_peak` stat tracking the arena's
high-water usage.

### ABI

An arena is opened at the start of a function body and closed at every exit (normal return
and all tail-call jumps):

```c
uint32_t wok_arena_open(WokHeap* h);                                /* push checkpoint; returns depth handle */
WokObj*  wok_arena_alloc(WokHeap* h, uint32_t tag, uint32_t arity); /* uncounted bump alloc in innermost arena */
void     wok_arena_close(WokHeap* h, uint32_t handle);              /* assert handle == top of stack; reset frontier */

uint64_t wok_stat_arena_bytes(const WokHeap* h);   /* WOK_PURE; current arena usage (sum of live cells) */
uint64_t wok_stat_arena_peak(const WokHeap* h);    /* WOK_PURE; high-water arena bytes */
```

- `wok_arena_open` pushes the current arena frontier and returns a depth handle.
- `wok_arena_alloc` bump-allocates an **uncounted cell** in the innermost open arena (RC field
  unused; cell layout identical to a counted `NCon`). The cell consumes 8 + 8*arity bytes.
- `wok_arena_close` asserts the handle matches the checkpoint stack's top and **resets the
  arena frontier** to the saved checkpoint, reclaiming all arena cells in O(1). A mismatched
  handle aborts loudly (a fence against LIFO violations).

### The separate arena region

The arena is a **distinct bump allocator** within `WokHeap` — its own slabs and frontier
pointer, never interleaved with the **counted RC slab allocator**. This is essential:
- During an open scope, the interpreter may allocate both `Arena` cells (non-escaping) and
  `Heap` cells (escaping values) in program order.
- If both bumped one shared frontier, resetting it at close would retroactively reclaim
  counted cells allocated *after* the checkpoint — a use-after-free. Separate regions make
  close reset *only* arena cells.
- A counted cell is freed individually via `wok_free` (unchanged) when its RC reaches zero.
  Arena cells have no refcount lifecycle; they are freed only by `wok_arena_close`.

### Uncounted cells: inert dup/drop

A cell allocated via `wok_arena_alloc` has its RC field **unused**. The interpreter's
`wok_dup`/`wok_dec` functions recognize arena addresses via a private `isUncountedAddr`
predicate and **do nothing** (making the Perceus pass's drop-on-last-use safe, even if
Perceus emits a drop on an arena binder — the drop is a runtime no-op). The cell is never
freed individually; it is reclaimed only by `wok_arena_close`.

### Close: scan-out then O(1) reset (the core win)

An arena cell may hold **counted children** (e.g., a constructor `Box` with a field holding
a counted RC-heap value). Before closing:

1. **Scan-out:** for each arena cell at this depth, extract its counted children (via the
   cell's descriptor), call `wok_dec` on each, and if any RC reaches zero, cascade the
   normal recursive free (exactly as the program would if the cell were being dropped).
   Arena cells of the same depth that are children are **skipped** (uncounted; they die in
   the bulk reset).
2. **Bulk reset:** reset the arena's frontier to the checkpoint, reclaiming all arena cells
   at this depth in one operation.

The **fast path** (pure-data cohort: all `Inline` or arena children) has an empty scan-out
and is O(1). The **general path** pays only for the counted children that must cascade
anyway.

### Arena statistics

Arena bytes are tracked separately from the counted RC heap:
- `wok_stat_arena_bytes` — current usage (sum of 8 + 8*arity for each live arena cell).
- `wok_stat_arena_peak` — high-water bytes during the run.
- The counted heap's `wok_stat_allocs` / `wok_stat_frees` / `wok_stat_peak_bytes` are
  **unaffected** by arena cells (they use separate counters), so the differential oracle can
  compare reduced counted stats between backends.

### Nesting and LIFO discipline

Opens and closes are **LIFO** (a checkpoint stack), mirroring the runtime call stack. Each
open returns a depth handle; `close` asserts the handle matches the stack's top. A mismatched
close (e.g., closing a parent scope before a child) aborts the runtime. Nested arenas reuse
the same region; the frontier is restored per-checkpoint.

### Cross-backend equivalence

Both the C runtime (`wok_arena_*` calls) and the abstract-heap interpreter (a mirrored
`stArena` address set with scan-out logic) implement the same uncounted semantics, so the
differential oracle validates:
- Output byte-identical for both backends.
- Reduced counted `allocs`/`frees` match between backends (the headline win).
- `arena_bytes` and `arena_peak` match between backends.
- **Arena-leak invariant:** `arena_bytes` returns to its pre-open value after each close;
  every open is matched by a close.

## Function ABI

All state lives in a per-run, opaque `WokHeap` context — there is **no global runtime
state**, so parallel `tasty` runs never share mutable C state. One heap is created at the
start of a module run and freed at its end.

```c
WokHeap* wok_heap_new(void);                      // fresh per-run context
void     wok_heap_free(WokHeap* h);               // tear down; warns on residual live cells

WokObj*  wok_alloc(WokHeap* h, uint32_t tag, uint32_t arity);  // header + slots, rc = 1, slots undef
void     wok_dup(WokObj* p);                      // rc++
uint64_t wok_dec(WokObj* p);                      // rc--, returns NEW rc; does NOT free
uint32_t wok_rc(const WokObj* p);                 // WOK_PURE; non-destructive refcount peek
void     wok_free(WokHeap* h, WokObj* p);         // free the cell (caller reads slots first)

void     wok_slot_set(WokObj* p, uint32_t i, uint64_t tag, uint64_t payload);
void     wok_slot_get(const WokObj* p, uint32_t i,
                      uint64_t* restrict tag, uint64_t* restrict payload);

uint32_t wok_tag(const WokObj* p);                // WOK_PURE
uint32_t wok_arity(const WokObj* p);              // WOK_PURE

uint64_t wok_stat_allocs(const WokHeap* h);       // WOK_PURE
uint64_t wok_stat_frees(const WokHeap* h);        // WOK_PURE
int64_t  wok_stat_live(const WokHeap* h);         // WOK_PURE
int64_t  wok_stat_peak(const WokHeap* h);         // WOK_PURE
uint64_t wok_stat_peak_bytes(const WokHeap* h);          // WOK_PURE; logical live-byte high-water
uint64_t wok_stat_peak_physical_bytes(const WokHeap* h); // WOK_PURE; physical (OS-held) high-water
```

Notes on the contract:

- `wok_dec` is split from `wok_free` deliberately. `wok_dec` only decrements and returns
  the new count; it never frees. When the count reaches zero the caller reads the slots,
  routes the children, and *then* calls `wok_free`. This mirrors the interpreter's
  `dropAddr` ordering (collect children → delete the cell → process the children) and is
  what makes the Haskell-driven recursive free safe.
- `WOK_PURE` is `__attribute__((pure))` (no observable side effect, result depends only
  on args + memory). It is applied to the read-only accessors and the four stat readers.
  `wok_slot_get` takes `restrict` out-pointers (`tag` and `payload` never alias).
- `wok_free` carries a premature-free guard: freeing a cell whose `rc != 0` aborts.
- `wok_heap_free` warns to stderr if any cell is still live at teardown (see the cosmetic
  note in the spec's follow-ups — a live count equal to the CAF baseline is legitimate,
  not a leak).
- Allocation failure (`malloc` returns `NULL`) aborts the runtime. There is no graceful
  path; modelling one would be over-engineering for a research interpreter.

## The "byte-dumb" contract

The C runtime is deliberately ignorant of wok's value model:

- **C never follows a slot payload as a pointer.** `wok_slot_get` hands back the raw
  `(tag, payload)` words; it does not chase a `wsCBox` payload, dup it, or free it. The C
  layer manages exactly one cell at a time: its header, its refcount, and its raw slot
  bytes.
- **The Haskell host drives the recursive free (cascade).** On a drop-to-zero, the
  interpreter reads the dying cell's slots back via `wok_slot_get`, runs the *existing*
  `countedRefs . nodeValues` logic to find the counted children, routes each child to
  whichever heap it lives in (`CAddr` → FFI `wok_dec`/`wok_free`; `HAddr` → the IntMap
  path), and only then calls `wok_free`. None of the twice-reviewed continuation
  owned-set logic is rewritten; cross-heap edges (`NCon "Box" [closure]`) just work.
- **The allocator is a per-run slab arena.** `wok_alloc` reuses a same-arity freed cell
  from a LIFO free list (the FBIP fast path) or bump-allocates within a 64 KiB slab;
  constructors of `arity >= 64` fall back to a direct `malloc`. `wok_free` recycles the
  cell to `freelist[arity]` (or `free`s the large path). `wok_heap_free` walks the slab
  list (O(slabs) bulk teardown). The cell representation and the entire function ABI above
  are unchanged — only the bytes' provenance changed. Because bulk teardown means a
  *logical* leak of a slab cell is no longer a real `malloc` leak, the stat-based
  `live == baseline` differential check is the load-bearing leak detector (LeakSanitizer
  still sees large-cell leaks). The slice-1 one-`malloc`-per-cell allocator is retained
  behind `-DWOK_RC_MALLOC` purely as a use-after-free oracle and microbench baseline (not
  in the Haskell path); poison-on-free is `-DWOK_RC_POISON`. **Swapping the allocator does
  not change the ABI above.**

## Soundness signal

The C path's correctness is proven by a **differential oracle**, not by a sanitizer over
the Haskell-driven path. The same corpus runs under both the abstract `IntMap` heap and
the C-backed heap; their rendered results must be byte-identical and their
`allocs`/`frees`/`peak` stats must match exactly, with `live == baseline` at a clean
run's end. Identical alloc/free counts is a strong structural proof: no leak, no
double-free, no missing or extra drop.

`scripts/asan-runtime.sh` runs ASan/UBSan over the C runtime's own standalone test
(`runtime/test`), not over the Haskell C-backed interpreter (that is fiddly through GHC's
RTS). The Haskell C-path soundness signal is the differential parity above.
