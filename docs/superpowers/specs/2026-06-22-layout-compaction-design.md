# Layout compaction — Slice 1 (8B header + raw descriptor-driven slots)

- **Date:** 2026-06-22
- **Status:** IMPLEMENTED (branch feat/layout-compaction). Implementation finding: wok
  constructors are **nominal/polymorphic**, so the same tag can appear with different slot
  kinds (`Tuple2(ptr,int)` vs `Tuple2(int,int)`) — the spec's "static typing keeps kinds
  consistent per tag" assumption was wrong. Resolved correctly: `allocNCon` records the
  first-seen kinds as the descriptor and **routes any kind-mismatch (or `arity > 255`) to the
  abstract heap**, so the descriptor is consistent for every C cell of a tag. Oracle stays
  bit-for-bit (1279 green); high-bit-`U64` is reachable from the surface (arbitrary-precision
  literals) and correctly falls back.
- **One line:** Shrink the C constructor cell from a 16B header + 16B `{tag,payload}`
  slots to an **8B header + 8B raw slots** classified by a **per-constructor descriptor**
  (no per-slot tag, no boxing, no runtime promotion — a high-bit `U64` falls back as today;
  full-range-inline deferred, §9), and flip the recursive
  free to a **C-driven, descriptor-bounded cascade** — all behind the private accessor
  ABI, validated by the existing differential oracle (corpus bit-for-bit identical).
- **Sources:** runtime/representation facts (Koka/Perceus, mimalloc, LuaJIT, GHC, Immix/LXR,
  LoCal) are grounded with citations in `docs/superpowers/runtime-knowledge-base.md`.

---

## 1. Goal and non-goals

### Goal

The arena slice (merged) left the cell representation deliberately uncompacted: 16B header
(`rc:64 + tag:32 + arity:32`) + 16B `{tag,payload}` slots. This slice halves it to the
Koka-proven shape — **8B header + 8B slots** (~50% smaller cells, ~2× cache density) — and
takes wok one specialization *past* Koka: because wok is **fully statically typed**, every
slot is a **raw** word classified by a **per-constructor descriptor**, with **no
self-describing tag word**.

The payoff of *this* slice is the **50% size reduction itself** plus the descriptor
infrastructure. The int encoding is **unchanged from today**: a value that fits `Int64`
is stored inline raw, and a high-bit `U64` (≥ 2⁶³) or a bignum still **falls back to the
abstract heap**. That fallback is **alloc-site heap selection, not runtime promotion** —
wok is functional, so a value is allocated once on whichever heap fits it and is **never
re-boxed**; incrementing constructs a fresh value allocated wherever *it* fits. Keeping a
*full-range* `U64` **inline** needs the descriptor to carry field **signedness** (a `U64`
≥ 2⁶³ and a negative `I64` share the same 64 bits, so decode needs the static field type) —
**deferred to a follow-up (§9)**, built only if the corpus actually uses high-bit `U64`.
This slice keeps the encoding *semantics* identical, so the differential oracle stays
bit-for-bit. (The contrast with the *tagged-word* regime still holds — it would
overflow-**promote** a value past 2⁶² at runtime; the descriptor regime never does.)

The descriptor that makes this work is also what lets the **C runtime do the recursive
free itself** (descriptor-bounded, no Haskell host at runtime) — the codegen-ready cascade
the arena spec deferred. That rides along here because the descriptor already encodes which
slots are pointers.

### Why this, why now

Layout compaction was the recorded next milestone after the arena. It sits behind the
**private accessor ABI** (`wok_tag`/`wok_arity`/`wok_slot_get`/`wok_slot_set`), so — like
the arena — the blast radius on the Haskell interpreter is contained: the machine's
`case`/projection sites are unchanged; only the marshalling boundary (`deref`/`alloc`) and
the C struct change. The differential oracle (`AbstractHeap ⟷ CHeap`) proves the compacted
layout produces byte-identical corpus output.

### Non-goals (explicitly out of scope — Slice 2 or deferred)

- **Nullary constructors as immediates** (`Nil`/`None`/`True`/`()` → 0 cells). This changes
  what a *value* is (`Addr`/`RCValue` grow an immediate form; dup/drop become no-ops on it),
  and it reintroduces a low-bit immediate-vs-pointer discriminator on sum-type slots.
  **Slice 2.**
- **Refcount / immortal unification** (saturating `rc` sentinel; retire the negative-`HAddr`
  static mechanism). **Slice 2.** This slice's `rc:32` is a plain counter — C cells are all
  dynamic (statics still live on the abstract heap as negative `HAddr`), so no sentinel is
  needed yet.
- **Pointer compression** (32-bit cell-index slots), **pointer-masking + page-aligned
  slabs**, **pointer-tagged scalars**, **refcount elision**. Allocator-track / deeper
  frontier; none is on the compaction path (the descriptor is reached by `tag` index, not by
  masking).
- **The pointers-first *physical reorder*.** We adopt the descriptor and keep `scan_count`
  in the header, but do **not** physically reorder fields pointers-first in Slice 1 (that
  adds a logical↔physical field remap to every access for a cascade speedup not worth it
  under the interpreter). The cascade walks the descriptor's pointer set. Pointers-first
  reorder is a deferred codegen optimization. *(Flaggable — §10.)*
- **Speed claims under the interpreter.** As before: correctness + ABI fidelity + the cache
  density of the layout are the deliverables; no end-to-end wall-clock claim.

---

## 2. Background: what exists today

The C cell (post-arena, `runtime/wok_rc.h`):

```c
typedef struct WokSlot { uint64_t tag; uint64_t payload; } WokSlot;   /* 16 B */
typedef struct WokObj  { uint64_t rc; uint32_t tag; uint32_t arity; WokSlot slots[]; } WokObj;
```

The Haskell marshalling (`Wok.Interp.RC.Value`):

- `encodeSlot :: RCValue -> Maybe (Word64, Word64)` — each slot stores a **self-describing**
  `(slotTag, payload)` pair. `wsLitInt`/`wsLitChar`/`wsLitUnit`/`wsCBox`/`wsHBox`.
- `decodeSlot :: (Word64, Word64) -> RCValue` — reads the slot tag, rebuilds the `RCValue`.
- Encode-or-fallback: if any field is non-encodable (`LStr`, **bignum `LInt`**,
  `RVRecMember`, `RVInst`), the whole `NCon` falls back to the abstract `IntMap` heap.
- Tag interning: `internTag :: Text -> Store -> (Word32, Store)` / `tagName` — a bijection
  `constructor ⟷ Word32`, keyed on the `APrim (Module,Name)` identity.
- `deref (CAddr p)` reads the cell's tag + slots from C and reconstructs an
  `NCon Text [RCValue]`.

The limitation this slice removes: the **16B self-describing slot** (half is a redundant
per-cell tag). The **`Int64`-fit fallback** in `encodeSlot` (a high-bit `U64` ≥ 2⁶³ goes to
the abstract heap) **stays unchanged** — range-widening is deferred (§9).

---

## 3. Design overview

### The compacted cell

```c
typedef struct WokObj {
    uint32_t rc;       /* plain counter (immortal sentinel is Slice 2) */
    uint16_t tag;      /* interned constructor id -> indexes the descriptor */
    uint8_t  arity;    /* 0..255 (constructors with >255 fields unsupported) */
    uint8_t  scan;     /* number of pointer slots (cascade hint) */
    uint64_t slots[];  /* arity raw 8-byte words */
} WokObj;              /* 8 B header + 8 B * arity */
```

`_Static_assert(sizeof(WokObj) == 8)`. The header fields are **private behind the accessor
ABI**; `wok_tag`/`wok_arity`/`wok_slot_get`/`wok_slot_set` keep their existing signatures and
do shift/mask internally — so **no ABI break** and no Haskell FFI signature change.

### A slot is a raw 8-byte word, classified by the descriptor

There is **no per-slot tag word**. The per-constructor **descriptor** (keyed by `tag`) says,
for each slot, its *kind*:

| descriptor slot kind | 8-byte word holds |
| -------------------- | ----------------- |
| `Scalar Int`         | the `Int64`-fitting value, raw (high-bit `U64` falls back, §9) |
| `Scalar Char`        | the code point |
| `Scalar Unit`        | `0` |
| `Pointer`            | a child address; **low bit = heap discriminator** (see below) |

**Scalar slots are fully raw** — the descriptor knows the kind, so there is no per-slot tag
and no boxing. The int **encoding semantics are unchanged** from today: an `Int64`-fitting
value is stored inline raw; a high-bit `U64` (≥ 2⁶³) or bignum makes the whole `NCon` fall
back to the abstract heap (alloc-site selection, **never runtime promotion** — wok is
functional, so nothing is re-boxed in place). Widening the inline range to a *full* `U64`
needs the descriptor to carry **signedness** (a `U64` ≥ 2⁶³ and a negative `I64` share the
same bits) and so is **deferred (§9)**. The headline of *this* slice is the 50% size shrink,
not range-widening — and the encoding semantics being identical is what keeps the oracle
bit-for-bit.

**Pointer slots carry one low bit** to distinguish the *runtime* heap of the child — a C cell
(`CAddr`, a real malloc'd pointer, naturally 8-aligned → low bits 0) vs an abstract-heap
child (`HAddr i`, stored as `(i << 1) | 1`, low bit 1). This is unavoidable and runtime-
dependent (the same `Box a` field can hold a C child or a fallback child), and it is the
*only* per-slot bit in the scheme; it rides free in the pointer's spare low bits. (This
mirrors Koka's low-bit field tag — here it discriminates heap, not pointer-vs-value.)

### The per-constructor descriptor — where the "header for integers" lives

Per the design discussion: the per-slot kind is a **per-constructor constant** (`Pair`'s
slot 0 is *always* a `U64`), so it is recorded **once** in a shared descriptor table keyed by
`tag`, **not** re-stamped 8 bytes per cell. The descriptor is wok's analogue of GHC's info
table — but reached by a 16-bit `tag` *index* rather than an 8-byte info *pointer*.

```haskell
data SlotKind = KScalarInt | KScalarChar | KScalarUnit | KPointer
data ConDescriptor = ConDescriptor
  { cdName  :: Text          -- for rendering / deref's NCon reconstruction
  , cdKinds :: [SlotKind]    -- one per slot, in source field order
  , cdScan  :: Int           -- count of KPointer slots (the header `scan`)
  }
```

It is built **at module load**, as an extension of `internTag`: interning a constructor to
its id also records its `ConDescriptor` (derived from the constructor's declared field
types). Immortal for the run. C never sees it; the **C cascade is handed the pointer-slot
indices** at the call boundary (see §4), or — for the interpreter — the Haskell cascade reads
the descriptor directly.

### Who walks children on free: C, descriptor-bounded (the cascade flip)

With the descriptor, the C runtime can do the recursive free itself. The cell knows its
`arity` and `scan`; the descriptor (or the pointer-slot index list passed at the boundary)
says which slots are pointers; each pointer slot's low bit routes C-child (recurse in C) vs
H-child (hand back to Haskell). The heap is **threaded** through the C recursion (Koka's
`ctx` model — passed once from Haskell at the cascade root), so no pointer-masking is needed.
Cross-heap edges still work: an H-child is returned to Haskell to drop on the abstract heap.

For the **interpreter**, the simplest correct form is: the Haskell cascade reads the dying
cell's slots + descriptor and routes each pointer child (C → FFI `wok_dec`/`wok_free`; H →
IntMap), exactly as today but driven by the descriptor instead of per-slot tags. The
**C-driven** form is the codegen-faithful version; this slice implements the C-driven cascade
for plain all-`Pointer`/`Scalar` constructors and keeps the Haskell cascade as the fallback
for cross-heap and structured (non-`NCon`) nodes. *(Flaggable scope — §10.)*

### Encode / decode become descriptor-driven

- `encodeSlotC :: RCValue -> Maybe (SlotKind, Word64)` — returns the slot's **kind** (to
  record in the descriptor) and the **single raw word** (no per-slot tag). `LInt n`: kind
  `KScalarInt`, the `Int64` bit pattern **if `n` fits `Int64`** — **encoding semantics
  unchanged from today**; a high-bit `U64` / bignum returns `Nothing` → fallback. `LChar`/
  `LUnit` as today. `CAddr p`: kind `KPointer`, the pointer bits (low bit 0). `HAddr i`: kind
  `KPointer`, `(i << 1) | 1` (low bit 1; the shift round-trips for negative/static `i` under
  arithmetic `>>`).
- `decodeSlotC :: SlotKind -> Word64 -> RCValue` — the inverse, driven by the descriptor's
  kind for that slot: the **kind** disambiguates scalar-vs-pointer, and (for `KPointer`) the
  **low bit** disambiguates C-vs-H.
- The encode-or-fallback rule is **unchanged**: a constructor whose every field encodes goes
  to C, otherwise the whole `NCon` to the abstract heap. `LStr`/bignum/**high-bit `U64`**/
  `RVRecMember`/`RVInst` still fall back — **no range-widening this slice** (§9). The kind is
  consistent per constructor (static typing), so it is recorded once at first intern.

---

## 4. The C side

- `wok_rc.h`: the compacted `WokObj` (above) + `_Static_assert(sizeof(WokObj)==8)`. The
  accessor signatures (`wok_tag`/`wok_arity`/`wok_slot_get`/`wok_slot_set`) are **unchanged**;
  they shift/mask the packed header and read/write the single 8-byte slot word.
  `wok_slot_get`/`set` lose the `tag` out-param's meaning (the slot is one word) — but to keep
  the ABI signature stable, the existing two-out-param `wok_slot_get` returns
  `(kind-from-descriptor-is-Haskell's-job, word)`; **simpler: change the slot accessors to
  one-word** `wok_slot_word_get/set` and update the (few) FFI call sites. *(Decision §10: keep
  the 16-byte-era two-param accessor as a thin shim, or migrate to one-word accessors. Lean:
  one-word accessors — the slot genuinely is one word now, and the FFI surface is small.)*
- The descriptor-bounded **C cascade**: `void wok_drop(WokHeap* h, WokObj* p, const uint8_t*
  ptr_slots, uint8_t nptr, <H-child callback>)` — dec rc; at 0, for each pointer slot route by
  the low bit (C child → recurse; H child → callback to Haskell); then `wok_free`. The
  `ptr_slots`/`nptr` come from the descriptor (passed from Haskell at the root; threaded in C).
- Endianness: the packed header uses explicit field types in a struct (the compiler handles
  layout); slot words are stored/loaded as `uint64_t` (no byte-order reinterpretation). The
  pointer low-bit tag is arithmetic, endianness-independent.
- Compiles under the existing `-Werror -Wconversion …` wall (shift/mask with explicit casts).

## 5. The Haskell side

- `ConDescriptor` table threaded in `Store` (built by `internTag`); `deref` consults it to
  rebuild `NCon` from raw slot words; `alloc`/`allocNCon` write raw words via the
  descriptor; `encodeSlotC`/`decodeSlotC` replace `encodeSlot`/`decodeSlot`.
- The machine's `case`/projection sites are **unchanged** (they consume the `NCon` that
  `deref` reconstructs).
- **Folded-in cleanups (optional, §10):** (a) the fake `Cell 0` rc that `readCCell` fabricates
  for C cells — compaction reworks `readCCell`, a natural place to stop fabricating a bogus
  rc; (b) a **phantom-typed `Addr`** making the abstract/C split a type fact rather than a
  runtime guard — but the immediate form arrives in Slice 2, so the richer phantom split is
  better landed there; Slice 1 may do the minimal `Cell 0` fix only.

## 6. The differential oracle

Unchanged methodology, and it is the whole safety net: every corpus program run through the
**C-compacted** backend must produce **byte-identical** rendered output to the abstract-store
backend, with `allocs`/`frees`/`peak` matching and `live == baseline` at clean end. Because
the compacted layout is a correctness-preserving reimplementation behind the accessor ABI,
any divergence is a compaction bug. Plus: a **descriptor round-trip property** (encode then
decode is identity over the encodable shapes — `Int64`-fit ints, char, unit, C/H pointers,
incl. the `HAddr` low-bit shift over negative/static addrs); a test that a **high-bit `U64`
still falls back** to the abstract heap (unchanged behavior, no promotion); cross-heap cascade
tests (C cell with an H child and vice versa); and the ASan/UBSan +
`WOK_RC_MALLOC` matrix extended to the compacted struct (`_Static_assert` on the 8B size;
shift/mask accessor correctness).

## 7. Task breakdown (each ships green)

- **Task 1 — the compacted C struct + accessors + static asserts.** `wok_rc.{c,h}`: 8B
  header, one-word slot accessors, `_Static_assert(sizeof(WokObj)==8)`. The standalone test +
  sanitizer matrix updated. Haskell FFI call sites (`Heap.hs`) adjusted to the one-word slot.
  No descriptor yet — slots still self-classified by the *Haskell* side passing kinds. Ships
  green against the oracle.
- **Task 2 — descriptor table + descriptor-driven Haskell marshalling.** `ConDescriptor`
  (per-slot `SlotKind`, derived from the `RCValue` kinds at first intern); `encodeSlotC`/
  `decodeSlotC` (one word, the `HAddr` low-bit shift); rework `readCCell`/`readCSlots`/
  `allocNCon` and the `dropAddr` cascade to be descriptor-driven (`decodeSlotC` instead of
  per-slot tags); the minimal `Cell 0` rc cleanup. **Encoding semantics unchanged.** Oracle +
  round-trip tests green.
- **Task 3 — oracle + tests + sanitizer.** Whole-corpus abstract⟷C-compacted parity; the
  round-trip property; the high-bit-`U64`-still-falls-back test; cross-heap cascade tests;
  extend the ASan/UBSan + `WOK_RC_MALLOC` matrix to the 8B struct (`_Static_assert(sizeof==8)`).
- **Task 4 — docs + memory.** Update `runtime/README.md` (the compacted layout, ABI unchanged),
  this spec → IMPLEMENTED, the memory note.

> The **C-driven cascade** (`wok_drop` in C) is **deferred** (§9): the Slice-1 cascade stays
> Haskell-driven but descriptor-based (per §10(c)), keeping the slice behind the accessor ABI
> with no new cross-heap C-callback surface. The C flip is the codegen-readiness follow-up.

## 8. Risks and mitigations

| Risk | Mitigation |
| ---- | ---------- |
| Shift/mask header packing corrupts a field | `_Static_assert` on size; accessor round-trip tests; the oracle diffs every corpus result. |
| Descriptor disagrees with a cell's actual layout | Single source: `internTag` builds the descriptor from the constructor's declared types; round-trip property; the oracle catches any mismatch as a divergence. |
| `HAddr` low-bit shift mis-round-trips a negative/static addr | Property: `(i<<1).|.1` then arithmetic `>>1` == `i` over negatives; the oracle exercises static-addr fields (globals as constructor children). |
| Pointer low-bit C/H tag aliases a real pointer bit | C pointers are ≥8-aligned (low 3 bits free); `_Static_assert(_Alignof(WokObj) >= 2)`; H addrs stored shifted. |
| C-driven cascade double-frees / leaks across heaps | Reuse the reviewed routing logic; Haskell fallback for cross-heap; stats parity makes any imbalance fail loudly; ASan + `WOK_RC_MALLOC` UAF oracle. |
| ABI drift breaks the FFI | Accessor signatures unchanged except the deliberate one-word slot migration (small, explicit call-site update). |

## 9. Explicitly deferred

- **Slice 2 (value-model):** nullary-as-immediate; refcount/immortal unification (saturating
  sentinel, retire negative-`HAddr`); the richer phantom-typed `Addr` (immediate/C/H as a type
  fact).
- **Allocator track:** pointer-masking + page/size-aligned slabs + block bitmap; mimalloc-v3.
- **Full-range-`U64`-inline (post-review scope, option B):** widen the inline int range past
  `Int64` so a high-bit `U64` (≥ 2⁶³) stays on the C heap instead of falling back. Needs the
  descriptor to carry field **signedness** (a `U64` ≥ 2⁶³ and a negative `I64` share the same
  64 bits), which needs the static field type — more than deriving the kind from runtime
  values. Build only if the corpus actually uses high-bit `U64`. No promotion is involved
  either way (alloc-site fallback, not runtime re-boxing).
- **C-driven cascade flip (`wok_drop` in C):** the codegen-readiness form of the descriptor
  cascade; the Slice-1 cascade stays Haskell-driven (descriptor-based). Adds a C recursive-free
  + cross-heap H-child callback.
- **Deeper:** pointer compression (32-bit cell-index slots), pointer-tagged scalars, refcount
  elision; the pointers-first *physical reorder* (codegen optimization).

## 10. Decisions resolved (override if needed)

Settled during brainstorming (2026-06-22), grounded in the LuaJIT-vs-Koka comparison:

1. **Follow Koka, not LuaJIT.** Koka is the proven Perceus runtime; LuaJIT gave the
   bit-packing discipline + the arena, not the cell shape (float-centric NaN-boxing, tracing
   GC, no native 64-bit int).
2. **Regime = raw descriptor-driven slots, not self-describing tagged words.** wok's static
   typing makes the descriptor free; the descriptor regime **never overflow-promotes** (a
   fixed-width machine int must not promote — the decisive reason). Full-range-`U64`-*inline*
   needs the descriptor to carry signedness and is **deferred (option B, §9)**; no-promotion
   holds today regardless, via alloc-site fallback (a high-bit `U64` is built on the abstract
   heap, never re-boxed).
3. **8B header** `rc:32 + tag:16 + arity:8 + scan:8`, private behind the accessor ABI.
4. **Descriptor lives in a shared static table** keyed by `tag`; cells carry only the index.
5. **C-driven cascade rides along** (the descriptor enables it); Haskell fallback for
   cross-heap / structured nodes.
6. **Pointer-masking + page alignment stay deferred** (allocator track; the descriptor is
   reached by index, the cascade threads the heap).

**Genuinely flaggable:** (a) the **pointers-first physical reorder** (we defer it; override to
do it now for codegen fidelity); (b) **one-word slot accessors** vs a two-param shim (lean:
one-word); (c) how much of the **C-driven cascade** lands in Slice 1 vs a follow-up (lean:
plain-constructor C cascade now, cross-heap stays Haskell); (d) whether the **`Cell 0` /
phantom-`Addr`** cleanups land here or in Slice 2 (lean: minimal `Cell 0` fix here, phantom
split in Slice 2).

---

## 11. What this slice unlocks — the extreme-performance roadmap (follow-on slices)

Why a wok-specific runtime can be **simpler *and* faster** than a general allocator: mimalloc
must be general — arbitrary sizes, many threads, no type info, `free(ptr)` with no context —
so it pays for sharded free-lists, size-class pages, and pointer-masking. wok knows what it
can't: every object is a constructor cell of **known layout** (the descriptor), single-threaded
per run, RC is **compiler-inserted** (dup/drop known statically), and the analyses know
**lifetime and uniqueness**. That lets wok skip machinery it can prove it doesn't need *and* do
optimizations a general allocator structurally cannot.

**This slice is the substrate** for those wins — the descriptor gives per-cell size + the
pointer-map; raw slots already unbox `Int64`-fitting scalars (no box, no indirection — full-
range-`U64`-inline deferred, §9);
the arena's LIFO same-arity reuse is the reuse hot path. The wins below are **separate
compiler/analysis slices that build on this one** — deliberately NOT folded in here (that would
conflate the cell-layout layer with the analysis layer and bloat the slice). Recorded so the
direction isn't lost:

- **FBIP — in-place reuse (the headline).** The compiler threads a dropped cell straight into a
  same-size alloc (`drop_reuse` → `alloc_at`), so `map`/`filter`/tree-insert/balance run with
  **zero allocation** — pure functional code at mutation speed. Needs the descriptor (size) +
  the one-shot/multiplicity proof that the drop and the alloc pair up.
- **Escape → stack / scoped-region allocation.** A cell proven not to escape its scope never
  touches the heap or the rc — a stack slot or a block-region freed at exit. wok's
  "escape = lifetime" analysis is the enabler; the biggest win for short-lived intermediates.
- **Reuse specialization + rc elision.** When uniqueness (`rc==1`) is proven statically, drop is
  a guaranteed free (no decrement) and dup/drop on borrowed reads vanish — the hot path does no
  rc work.
- **Monomorphize / unbox containers.** Specialize `List U64` so elements are inline (no
  per-element box / pointer-chase) — the descriptor regime extended to whole structures.

**Sequencing:** this compaction slice → FBIP (biggest single win, rides on the descriptor +
arena) → escape/region allocation → reuse specialization → monomorphization. Each its own
spec → plan → pipeline, validated against the differential oracle. None changes the Slice-1
scope above; they are the payoff it enables.
