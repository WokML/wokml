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

Two structs, both exactly 16 bytes, locked with `_Static_assert` so a layout drift fails
the compile rather than corrupting silently.

```c
typedef struct WokSlot {           // 16 bytes
    uint64_t tag;                  // WokSlotTag (see below)
    uint64_t payload;              // value | C pointer bits | Haskell Addr int
} WokSlot;

typedef struct WokObj {
    uint64_t rc;                   // reference count (>= 1 while live)
    uint32_t tag;                  // interned constructor id (opaque to C)
    uint32_t arity;                // number of slots
    WokSlot  slots[];              // flexible array member, `arity` entries
} WokObj;
```

- The 16-byte header (`rc:64 + tag:32 + arity:32`) plus `arity` 16-byte slots is the
  total cell size: `16 + 16 * arity` bytes.
- `tag` is an interned `uint32` id. **C never interprets it.** The constructor's identity
  (the APrim `(Module, Name)`) stays on the Haskell side; Haskell interns it to an id
  before `wok_alloc` and maps it back after `wok_tag` (`internTag` / `tagName` in
  `Wok.Interp.RC.Value`).
- `rc` is unsigned. `wok_dec` on an already-zero cell, and `wok_free` on a cell whose
  `rc != 0`, are trapped invariant violations (`abort()`) — the C analogues of the
  interpreter's `Left RuntimeError` double-free / premature-free guards.
- These are the deliberately *uncompacted* forms (correctness-first). The compaction to
  an 8-byte header and an 8-byte tagged-word slot is a separately designed later slice
  and, because the fields are private behind the accessor functions, is not an ABI break.

## Slot-tag encoding

A slot holds one machine word of payload, so not every `RCValue` fits. The encoding is
the bijection `encodeSlot` / `decodeSlot` (in `Wok.Interp.RC.Value`), with tag constants
defined in `Wok.Interp.RC.Heap`:

| `WokSlotTag` | value | `payload` holds | `RCValue` shape |
| ------------ | ----- | --------------- | --------------- |
| `wsLitInt`   | `0`   | `int64` bit pattern | `RVLit (LInt n)`, `n` fits in `Int64` |
| `wsLitChar`  | `1`   | code point          | `RVLit (LChar c)` |
| `wsLitUnit`  | `2`   | `0`                 | `RVLit LUnit` |
| `wsCBox`     | `3`   | `WokObj*` bits      | `RVBox (CAddr p)` — another C cell |
| `wsHBox`     | `4`   | Haskell `Addr` int  | `RVBox (HAddr i)` — IntMap-resident node |

### Encodable-or-fallback rule

These `RCValue` shapes are **not encodable** and have no slot tag:

- `RVLit (LStr _)` — strings
- `RVLit (LInt n)` where `n` does **not** fit in `Int64` (bignum)
- `RVRecMember _ _ _`
- `RVInst _ _`

At `alloc` time, if **any** field of an `NCon` fails to encode, the whole constructor is
allocated on the Haskell `IntMap` heap (as before this slice) and handed back as an
`HAddr`. Everything downstream already dispatches on `Addr`, so the fallback costs no
extra code path and guarantees correctness for the rare cases. C-side `LStr`/bignum
support is a later slice if the corpus ever needs it.

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
