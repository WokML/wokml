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
