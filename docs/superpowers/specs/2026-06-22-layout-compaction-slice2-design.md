# Layout compaction — Slice 2 (nullary constructors as inline immediates)

- **Date:** 2026-06-22
- **Status:** IMPLEMENTED (branch `feat/layout-compaction-slice2`, 1282 green, sanitizers
  clean on all three C variants; local, not pushed; pending full-branch `/code-review`).
- **Implementation findings (2026-06-23):**
  - *Containment held end-to-end.* `alloc` intercepts nullary `NCon` → `Inline tid` (no stat
    bump, both backends); `deref` synthesizes it back. `matchAltsRC`/`RProj`/`asBool`/
    `allocBool`/CAF binding were untouched, as designed.
  - *Rendering stayed unchanged (§3 intent held).* The pure core `derefPure (Inline tid)`
    **synthesizes** the nullary `NCon` directly (`tagName` is pure), exactly as the IO `deref`
    does — so the generic `RVBox a` renderer path covers immediates and `goVal`/`spine` carry
    no inline special-case. (A first cut instead made `derefPure (Inline _)` a `Left` with
    explicit renderer arms, on a "pure cores reject non-`HAddr`" reading; that was reverted
    because reading an immediate's value IS a meaningful pure operation — `derefPure` joins
    `increfPure`/`dropAddrStepPure`, which already handle `Inline` benignly, rather than the
    genuine category-errors `writeNodePure`/`moveOutContPure`.)
  - *`==` cannot appear in `--dump-rc-stats` bench programs.* The `Eq` typeclass desugars `==`
    into a CAF method bound as `RAtom (APrim "eqU64")`, which the M1 RC machine rejects in
    value position (`resolveRCAtom` → `UnboundPrim`). Bench programs use literal patterns
    (`case n of 0 -> …; _ -> …`) or direct `eqU64` calls. Pre-existing M1 limitation, not a
    regression.
  - *`--dump-rc-stats` reports the abstract `Stats` (cell counts), not the C byte counter.*
    `wok_stat_peak_bytes` ships as a C-side observable (+ standalone-test coverage + a Haskell
    `wokStatPeakBytes` binding for future consumers); the benchmark reports analytical bytes,
    exact because the oracle proves both backends' cell populations identical. The CLI golden
    format was left untouched (no spurious golden shift).
  - *Measured win (`bench/RESULTS.md`):* tree −50.1% allocs / −20.1% bytes; bools −100% allocs
    (boolean churn eliminated); maybes −62.7% allocs; list −1.0% (the honest control).
- **One line:** A zero-field constructor (`Nil`, `None`, `True`, `False`, `Leaf`, any
  user `data T = A`) stops being an 8-byte heap cell and becomes an **inline immediate** —
  the constructor tag baked directly into the slot/word that holds it, with **zero heap
  cells**. These are the most common heap objects, so this is the biggest alloc-count win
  of the compaction track. The change lives in the **shared value model** (a new `Addr`
  case + the two marshalling chokepoints `alloc`/`deref`), applied identically on both
  backends, so the differential oracle stays bit-for-bit.
- **Scope:** nullary-as-immediate **only**. The two related value-model cleanups
  (rc/immortal unification; phantom-typed `Addr`) are **deferred to their own later
  slices** (§11) — they are orthogonal to immediates and would conflate two value-model
  changes against the oracle at once.
- **Sources:** `docs/superpowers/runtime-knowledge-base.md` (Koka low-bit value scheme
  [R1], GHC info tables, niche/immediate prior art); the Slice 1 spec
  `2026-06-22-layout-compaction-design.md`; `runtime/README.md` (the cell/slot contract).

---

## 1. Goal and non-goals

### Goal

Slice 1 shrank the cell to an 8B header + one raw `uint64` per slot, classified by a
per-constructor descriptor. A nullary constructor under Slice 1 is still a *cell*: an 8B
header with zero slots, reached by a pointer. This slice removes that cell entirely.

A nullary constructor becomes an **immediate**: a value stored directly in the word that
would otherwise hold a pointer to it (a parent cell's slot, or a binding in the
interpreter's environment). No header, no slot, no allocation, no free, no pointer-chase.
The constructor's identity travels as its interned tag, inline.

This is the **niche/immediate** representation Koka uses for its value scheme (low bit
distinguishes pointer from inline value) [R1], specialised to wok: wok already stores
`Int64`-fitting scalars raw in slots, and `LUnit` is already an unboxed literal — this
slice extends "no cell" to the remaining zero-field constructors.

### Why this, why now

`Nil` terminates every list, `None` is every absent optional, `True`/`False` are every
boolean (and wok allocates a fresh boolean cell on *every* comparison — see `allocBool`),
and empty `Leaf`s are roughly half the cells of any tree. Eliminating these is the largest
single reduction in allocation count and a ~20% / ~50%-of-cells reduction in resident
memory on tree-shaped data (§7 benchmark). It was the recorded next milestone after the
Slice 1 cell compaction.

### Non-goals (explicitly out of scope — later slices or deferred)

- **rc/immortal unification** (retire the negative-`HAddr` static mechanism; adopt a
  Koka-style saturating `rc` sentinel `INT32_MIN`). Orthogonal: it changes how *static*
  cells are represented, lives entirely on the abstract heap, and has nothing to do with
  immediates. **Its own later slice** (§11). The only overlap — a shared "uncounted" notion
  — is handled minimally here (§3, `isUncounted`).
- **Phantom-typed `Addr`** (make abstract/C/immediate a type-level fact enforced by the
  compiler). GHC's `-Wincomplete-patterns` already forces every `Addr`-matching function to
  handle the new case, so the marginal safety does not justify the GADT/type-parameter
  machinery now. **Deferred** (§11); revisit only if the 3-way split proves error-prone.
- **Full-range-`U64`-inline**, the **C-driven `wok_drop` cascade**, pointer
  compression/masking, FBIP, escape analysis — all unchanged from the Slice 1 deferred
  list. None is on this slice's path.
- **No flat/unboxed inline sums** (storing a whole `Maybe a` inline in its parent, sized to
  the largest variant). That reintroduces per-field padding to remove a pointer-hop — the
  opposite trade. It is the deferred "monomorphize/unbox containers" frontier, not this
  slice. wok stays a boxed sum-of-products; this slice only takes the *nullary* variants to
  zero bytes.
- **Interpreter wall-clock speed claims.** As in every prior runtime slice: the deliverable
  is correctness + the alloc-count/byte reductions (deterministic, oracle-backed). The
  tree-walking interpreter's overhead dwarfs cell layout, so no end-to-end wall-clock claim
  is made. A C-level alloc microbench may report a real per-alloc time number (§7).

---

## 2. Background: what exists today

The value model (`Wok.Interp.RC.Value`):

```haskell
data Addr = HAddr Int | CAddr (Ptr WokObj)            -- abstract-heap index | C pointer
data RCValue = RVLit Lit | RVBox Addr | RVRecMember .. | RVInst ..
```

A nullary constructor today is `RVBox a` where `a` is a real cell:

- **AbstractHeap backend:** `alloc (NCon "Nil" []) s` → `allocPure` → `HAddr i`, bumps
  stats (alloc + 1, live + 1). The cell is `Cell 1 (NCon "Nil" [])`.
- **CHeap backend:** `allocNCon` → `traverse encodeSlotC []` succeeds (empty) →
  `wokAlloc hp tid 0` → `CAddr p`, bumps stats. An 8B header cell with zero slots.

Both backends allocate a cell for every nullary constructor, so their alloc/free/peak
stats match — which is what the differential oracle checks.

Every machine site that reads a constructor reaches it through the two marshalling
chokepoints `alloc`/`deref`:

- `matchAltsRC` (case dispatch): `RVBox addr -> deref addr s; goNode (cNode c)`.
- `RProj` (record projection): `RVBox addr -> deref addr s; case cNode c of NRecord ..`.
- `asBool`/`allocBool` (`Wok.Interp.RC.Prim`): `deref` a boxed `NCon "True"/"False" []`;
  `alloc (NCon tag [])` to build one.
- rendering (`renderValueWith`): `RVBox a -> deref a; goNode`.
- the CAF/top-level binding path (`runModuleRC`): forces and `deref`s the result node.

This is the containment lever Slice 1 relied on, and it is what keeps Slice 2 from
touching the machine.

The slot encoding (Slice 1) packs a slot as one raw `uint64`, classified by the
descriptor's `SlotKind`. A `KPointer` slot uses **one low bit** as the heap discriminator:
`CAddr` (8-aligned → low bit 0) vs `HAddr` (stored `(i << 1) | 1` → low bit 1).

---

## 3. Design overview

### The value model — `Addr` grows a third case

```haskell
data Addr = HAddr Int | CAddr (Ptr WokObj) | Inline Word32
  deriving (Eq, Ord, Show)
```

`HAddr`/`CAddr` name *which heap* the value lives on; `Inline` names *no heap — the value
lives inline*, carrying the **interned constructor tag** (the same `Word32` `internTag`
produces and the C slot encoding packs). A nullary constructor value is `RVBox (Inline
tag)`: a "box" that points at nothing — the constructor is written into the word itself.

Naming note: `Inline` deliberately drops the `…Addr` suffix that `HAddr`/`CAddr` carry,
because an immediate is genuinely *not* an address. Putting it inside `Addr` is a
deliberate, contained white lie: it lets `RVBox (Inline tag)` flow through the existing
`deref`/`RVBox` paths so the machine is untouched (Considered alternatives: `Nullary`,
`Unboxed` — `Inline` chosen as the location-axis parallel to "abstract heap / C heap /
inline", and to avoid `Imm` reading as "immutable" and `Unboxed` colliding with the raw
scalar unboxing that already exists.)

### The two chokepoints carry the whole slice

The interception is in `alloc` (the backend-aware, machine-facing entry), **before** the
backend split — so it is backend-agnostic by construction:

```haskell
alloc (NCon con []) s = pure (allocInline con s)   -- nullary: inline, both backends
alloc (NCon con vs) s = allocNCon con vs s          -- non-nullary: unchanged (C-or-abstract)
alloc n             s = pure (allocPure n s)         -- other nodes: unchanged

allocInline :: Text -> Store -> (Addr, Store)
allocInline con s = let (tid, s') = internTag con s in (Inline tid, s')
--  NO recordAlloc: an immediate is on no heap, so it bumps no allocation stat.
```

`internTag` runs on **both** backends now (the abstract path previously never interned).
This is stat-invisible: interning touches only `stTagFwd`/`stTagRev`, never `stStats`, and
the tag id never reaches rendered output (names round-trip through `tagName`).

`deref` synthesises the nullary `NCon` back on demand, exactly the way Slice 1's `deref`
reconstructs a C cell:

```haskell
deref (CAddr p)    s = liftIO (readCCell p s)
deref a@(HAddr _)  s = liftRC (derefPure a s)
deref (Inline tag) s = pure (Cell 0 (NCon (tagName tag s) []))   -- rc placeholder 0
```

The `Cell 0` rc placeholder is the same meaningless-rc convention C cells already use; no
reader consults the rc of an `Inline`-derived cell (the rc-reading consumers
`increfPure`/`dropAddrStepPure`/`moveOutContPure` all reject or short-circuit non-`HAddr`
addresses first — see below).

**Consequence:** `matchAltsRC`, `RProj`, `asBool`, `allocBool`, rendering, and the CAF path
are all **unchanged** — they reach a constructor only through `alloc`/`deref`. The pure
abstract algebra (`allocPure`) is *not* changed, so the store-algebra unit tests that call
`allocPure`/`dropAddrPure` directly never see `Inline` (no runtime path constructs a
nullary constructor through `allocPure`; the machine always goes through `alloc`).

### Uncounted handling — reuse the static-cell precedent

An immediate is **uncounted**: it owns no cell, so dup/drop are no-ops and it contributes
no counted child. This is exactly how static (negative-`HAddr`) addresses and `RVInst`
already behave. The change is to extend the single counted-refs filter point:

```haskell
isInline :: Addr -> Bool
isInline (Inline _) = True
isInline _          = False

-- the predicate the counted-refs filter / owned-set / CAF guard use:
isUncounted :: Addr -> Bool
isUncounted a = isStaticAddr a || isInline a
```

- `incref (Inline _) s = pure s` — no-op (new arm on the IO wrapper, before `increfPure`).
- `dropAddr` worklist: `go (Inline _ : rest) s = go rest s` — skip (no cascade, no stats).
- `countedRefs` filters on `isUncounted` instead of `isStaticAddr`, so an `Inline` child is
  never acquired or released. `closureOwnedBoxed` and the `runModuleRC` CAF guard
  (`not (isStaticAddr dynAddr)` → `not (isUncounted dynAddr)`) likewise treat an `Inline`
  result as already-immortal, binding it as-is (an `Inline` CAF needs no `writeStatic`
  copy).
- `isStaticAddr` keeps its precise meaning (HAddr `i < 0`); `dropAddrStepPure`/`increfPure`
  keep using it because an `Inline` is short-circuited by the IO wrappers before reaching
  those pure cores.

The Perceus pass still emits `__rc_dup`/`__rc_drop` on a `Maybe a`/`Bool` binding
statically (it cannot know at compile time whether the value is `None` or `Some`). At
runtime `dropAddr`/`incref` dispatch on the `Addr` kind: `Inline` → no-op, `HAddr`/`CAddr`
→ real work. The *same* drop instruction handles both outcomes — exactly as a drop of a
static `HAddr` is already a runtime no-op. Both backends run the same deterministic program
and therefore acquire/release the same counts, so the oracle stays balanced.

### Slot encoding — a 2-bit low tag (the only bit-level change)

A sum-type field (e.g. `Maybe a`) holds, **at runtime**, either an immediate (`None`) or a
pointer (a `Some` cell), so the slot word needs a runtime three-way discriminator:
C-pointer / abstract-index / immediate. Slice 1's one low bit becomes two
(Koka-style: bit 0 = pointer-vs-value) [R1]:

```
  bits 63..2                         b1 b0
  +-------------------------------+----+----+
  |  pointer / index / con-tag    | b1 | b0 |
  +-------------------------------+----+----+

  b1 b0 = x0  -> CAddr     : the bare pointer (8-aligned -> low 3 bits 000). Decode reads only b0.
  b1 b0 = 01  -> HAddr     : abstract index, (i << 2) | 1 ; decode arithmetic >> 2.
  b1 b0 = 11  -> Inline    : a nullary constructor, (tag << 2) | 3 ; decode tag = w >> 2.
  b1 b0 = 10  -> unused (never produced).
```

```haskell
encodeSlotC (RVLit (LInt n))     = (KLitInt,) . fromIntegral <$> toIntegralSized n  -- unchanged
encodeSlotC (RVLit (LChar c))    = Just (KLitChar, fromIntegral (fromEnum c))        -- unchanged
encodeSlotC (RVLit LUnit)        = Just (KLitUnit, 0)                                 -- unchanged
encodeSlotC (RVBox (CAddr p))    = Just (KPointer, fromIntegral (ptrToWordPtr p))     -- low bits 00
encodeSlotC (RVBox (HAddr i))    = Just (KPointer, fromIntegral ((i `shiftL` 2) .|. 1))   -- was << 1
encodeSlotC (RVBox (Inline tag)) = Just (KPointer, (fromIntegral tag `shiftL` 2) .|. 3)   -- NEW
encodeSlotC _                    = Nothing

decodeSlotC KPointer w
  | w .&. 1 == 0 = RVBox (CAddr (wordPtrToPtr (WordPtr (fromIntegral w))))            -- 00
  | w .&. 2 == 0 = RVBox (HAddr (fromIntegral ((fromIntegral w :: Int64) `shiftR` 2))) -- 01
  | otherwise    = RVBox (Inline (fromIntegral (w `shiftR` 2)))                        -- 11
```

The con tag occupies 62 bits and needs only 16 — never overflows. The `HAddr` index loses
one bit (62-bit range); the abstract heap never approaches that.

### The descriptor — `KPointer` subsumes "pointer-or-immediate"

The per-constructor descriptor (`stConDesc`, keyed by tag) is **unchanged**. A sum-type
field is recorded as `KPointer` exactly as in Slice 1; `KPointer` now means
"pointer-or-immediate — inspect the low 2 bits at decode." **No new `SlotKind` variant.**

Why a new descriptor kind would not work: the same field is a pointer in one cell and an
immediate in another *at runtime* (a `Maybe a` holding `Some x` vs `None`), but the
descriptor is a per-constructor *static* fact — it cannot know. The discriminator must be a
runtime bit. Crucially, this also keeps the Slice 1 **first-kind-wins** fallback intact: a
field that is sometimes a pointer and sometimes an immediate records the *same* kind
(`KPointer`) either way, so immediates never trigger a spurious kind-mismatch fallback. An
all-immediate field (e.g. `Bool`) is simply a `KPointer` slot whose words always carry
`b1 b0 = 11`.

### The cascade skips immediates

When a C cell is freed (`dropAddr`'s `CAddr` arm), its slots are decoded by
`readCConValues` → `decodeSlotC`; an immediate slot decodes to `RVBox (Inline tag)`, which
`countedRefs` drops via `isUncounted`. So the immediate is **not** enqueued for free — no
double-free, no leak. The abstract path is identical: `cascadeChildren (NCon _ vs) =
countedRefs vs` filters the `Inline` children. Confirmed for a mixed list
`Cons 1 (Cons 2 Nil)`: freeing it frees 2 `Cons` cells and 0 `Nil` cells, identically on
both backends.

---

## 4. The C side

**The C runtime's cell/slot behaviour needs no change.** It is byte-dumb: it stores a raw
`uint64` per slot and never interprets one (the README "byte-dumb contract"). An immediate
is just a `uint64` with low bits `11`; `wok_slot_set`/`wok_slot_get` move it verbatim, and
the Haskell-driven cascade does all routing. The `WokObj` cell layout, the slot accessors,
and every public function signature are **unchanged** — no ABI break.

The one C addition is additive observability for the benchmark (§7), confined to the
**opaque** `WokHeap` (callers never see its layout, so private counter fields are not an
ABI change), mirroring the existing `wok_stat_reused`/`wok_stat_slabs`:

```c
WOK_PURE uint64_t wok_stat_peak_bytes(const WokHeap* h);   /* high-water live bytes */
```

`wok_alloc`/`wok_free` (in **both** the arena and `WOK_RC_MALLOC` builds) track
`cur_bytes += wok_cell_bytes(arity)` / `-=` and raise `peak_bytes`; the new accessor returns
it. This is a pure counter; it does not touch the slot encoding or the oracle's correctness
check. (It only ever sees non-nullary cells now, so its baseline is naturally the
post-Slice-2 footprint.)

---

## 5. The Haskell side

Changed (all in `Wok.Interp.RC.Value` unless noted):

- `Addr` gains `Inline Word32`; `isInline`/`isUncounted` added.
- `alloc` intercepts nullary `NCon`; `allocInline` interns + returns `Inline` with no stat
  bump. `allocPure`/`allocNCon` unchanged for non-nullary nodes.
- `deref` gains the `Inline` arm (synthesises the nullary `NCon`).
- `incref` gains the `Inline` no-op arm; `dropAddr` worklist gains the `Inline` skip arm.
- `countedRefs` / `closureOwnedBoxed` filter on `isUncounted`; the `runModuleRC` CAF guard
  (`Wok.Interp.RC.Machine`) switches `isStaticAddr` → `isUncounted` at the one binding site.
- `encodeSlotC`/`decodeSlotC` adopt the 2-bit low tag (`HAddr` shift `<< 1` → `<< 2`; new
  `Inline` case).

Unchanged: `matchAltsRC`, `RProj`, `nodeValues`, `cascadeChildren`, `nodeTag`,
`asBool`/`allocBool`, `renderValueWith`, the `stConDesc` descriptor and its first-kind-wins
logic, the M2b/M3 continuation machinery (an `Inline` never enters an owned set, a
continuation, or a cont-cell — `countedRefs` filters it before it could).

---

## 6. The differential oracle

Unchanged methodology, and it is the whole safety net. Both backends now intercept nullary
constructors at the shared `alloc` chokepoint, so they stop allocating those cells **in
lockstep** — every corpus program produces byte-identical rendered output and identical
`allocs`/`frees`/`peak` (cell counts), with `live == baseline` at a clean end. Because the
immediate change is a shared value-model change applied before the backend split, any
divergence is a bug.

New / updated tests:

- **Slot round-trip property** refreshed for the 2-bit scheme: `decodeSlotC . encodeSlotC`
  is identity over the encodable shapes, now including the `HAddr` `<< 2` shift over
  negative/static indices and the new `Inline` case; and the three low-tag classes never
  alias (a `CAddr`'s `00`, an `HAddr`'s `01`, an `Inline`'s `11` are mutually exclusive).
- **Zero-cell property:** a nullary constructor allocates **zero** cells and frees zero on
  *both* backends (stats unchanged across its construction), and round-trips through
  `deref` to the right `NCon name []` (renders identically — `Nil` → `[]`, `None` → `None`,
  `True` → `True`).
- **Mixed pointer/immediate field:** a `Maybe`/list/tree with both present and empty
  variants renders identically and balances `live == baseline` on both backends (the
  cascade-skips-immediates check).
- **Goldens re-baselined:** the `--dump-rc-stats` goldens shift downward (fewer allocs);
  both backends shift identically, so the abstract⟷C diff still agrees. This is expected
  fallout, not a regression — the re-baseline lands in **Task 1** (where nullary allocations
  vanish), with the Δ justified per changed number. (Task 2 moves immediate-bearing
  constructors from abstract-fallback back to C-inline but changes no alloc *count*, so it
  shifts no `--dump-rc-stats` golden.)
- The ASan/UBSan + `WOK_RC_MALLOC` matrix is unaffected: the `WokObj` layout and the slot
  accessor signatures are unchanged, and `WokHeap` gains only private counter fields. The
  new `wok_stat_peak_bytes` is exercised by the standalone test.

---

## 7. The microbenchmark (first-class deliverable)

**What is measured:** the deterministic, oracle-backed win — allocation count, free count,
peak-live cells, and peak-live **bytes**. **Not** interpreter wall-clock (the interpreter
overhead swamps layout; a "% faster" number would be noise).

**Harness:** the existing `--dump-rc-stats` mode (already a Suite B golden, printing
`allocs / frees / peakLive / baseline`), extended to also report peak bytes from
`wok_stat_peak_bytes` (C backend) — equal to the analytical `Σ (8 + 8·arity)` over the live
population, which the oracle proves identical between backends. Run each corpus program
before and after Slice 2; tabulate Δ and % reduction.

**Corpus — four programs, each isolating one case:**

| program | shape | the win it measures | expected |
| ------- | ----- | ------------------- | -------- |
| `bench/tree.wok`   | build + fold a depth-d tree (`Node`/`Leaf`) | resident bytes + cell count | ~20% bytes, ~50% cells |
| `bench/bools.wok`  | filter/`all`/sort producing many booleans   | allocation churn            | boolean allocs → 0 |
| `bench/maybes.wok` | a list of `Maybe` with many `None`          | mixed pointer/immediate     | per-`None` cell removed |
| `bench/list.wok`   | a long plain list (**control**)             | the `Nil` constant only     | small, ~one cell |

The `list` control is included deliberately so the report does not oversell — the single
`Nil` amortises away on long lists.

**Optional C-level time number:** the arena's standalone microbench can measure the cost of
N arity-0 `wok_alloc`/`wok_free` pairs — the allocator work that disappears — giving a
legitimate real time figure ("eliminating ~N arity-0 alloc/free pairs saves ≈X µs of
allocator work") without any interpreter wall-clock claim.

Concrete analytical figures (cell = `8 + 8·arity`):

| structure | before | after | bytes | cells |
| --------- | ------ | ----- | ----- | ----- |
| `[1..10]` | 248 B | 240 B | −8 B (−3%) | 11→10 |
| `[Some 1, None, Some 3, None]` | 152 B | 128 B | −24 B (−16%) | 9→6 |
| tree depth 3 (7 `Node`, 8 `Leaf`) | 288 B | 224 B | −64 B (−22%) | 15→7 |
| tree depth 4 (15 `Node`, 16 `Leaf`) | 608 B | 480 B | −128 B (−21%) | 31→15 |
| sort 100 ints (boolean churn) | ~664 bool allocs | 0 | — | −664 allocs |

---

## 8. Task breakdown (each ships green)

- **Task 1 — value model + chokepoints.** `Addr` gains `Inline`; `isInline`/`isUncounted`;
  `alloc`/`allocInline` interception (both backends, no stat bump); `deref` synthesis;
  `incref`/`dropAddr` `Inline` arms; `countedRefs`/`closureOwnedBoxed`/CAF-guard switch to
  `isUncounted`. **No `encodeSlotC` change yet** — so a constructor that *contains* an
  immediate field harmlessly returns `Nothing` from the catch-all and falls back to the
  abstract heap on the C backend, which the abstract backend does too (identical total
  allocs), while a bare nullary constructor allocates zero cells on both. This task is green
  on its own against the oracle, and carries the **zero-cell property test** and the
  **`--dump-rc-stats` golden re-baseline** (the only place alloc counts shift).
- **Task 2 — slot encoding (the 2-bit low tag).** `encodeSlotC`/`decodeSlotC` adopt the
  2-bit scheme (`HAddr` `<< 2`; new `Inline` case). This is what lets an immediate live
  *inside* a C cell's slot (e.g. `Cons 2 Nil`'s tail) instead of forcing the parent to fall
  back. Changes no alloc count (only the heap a parent lands on), so no golden shifts.
  Carries the **refreshed round-trip property** (the `<< 2` shift over negative/static
  indices, the `Inline` case, low-tag mutual exclusivity) and the **mixed pointer/immediate
  cascade test** (an immediate inside a freed C cell is skipped, `live == baseline`).
- **Task 3 — whole-corpus oracle parity.** The abstract⟷C-compacted parity over the full
  corpus (byte-identical output, matching `allocs`/`frees`/`peak`, `live == baseline`) — the
  integration backstop that catches anything the per-task unit properties miss; existing
  cross-heap cascade tests stay green.
- **Task 4 — benchmark.** `wok_stat_peak_bytes` (additive C counter + standalone-test
  coverage); the four `bench/*.wok` programs; the `--dump-rc-stats` report extended with
  peak bytes; the before/after Δ table. No wall-clock claim.
- **Task 5 — docs + memory.** Update `runtime/README.md` (the slot now encodes three
  classes via the 2-bit low tag; nullary constructors are immediates, no cell); this spec →
  IMPLEMENTED; the memory note.

---

## 9. Risks and mitigations

| Risk | Mitigation |
| ---- | ---------- |
| An `Inline` reaches an rc-reading consumer (`increfPure`/`dropAddrStepPure`/`moveOutContPure`) and reads the bogus `Cell 0` rc | The IO wrappers `incref`/`dropAddr` short-circuit `Inline` *before* the pure core; the pure cores already reject non-`HAddr`. An `Inline` never enters an owned set/continuation (`countedRefs` filters it). |
| The 2-bit low tag aliases a real pointer bit | C cells are ≥8-aligned (low 3 bits 0), so `b1 b0 = 00` for `CAddr`; `HAddr`/`Inline` are stored shifted. The round-trip property asserts mutual exclusivity. |
| `HAddr` `<< 2` mis-round-trips a negative/static index | Arithmetic `>> 2` sign-extends; property test over negative/static indices (globals as constructor children). |
| Abstract and C backends diverge on a nullary constructor | The interception is in shared `alloc` before the backend split — both produce `Inline` identically; the oracle diffs every corpus result and the zero-cell property pins it. |
| A nullary constructor reaches `allocPure` (raw abstract algebra) and becomes a real cell instead of an `Inline` | No runtime path does this — the machine always goes through `alloc`. The store-algebra unit tests intentionally use `allocPure` (testing the IntMap algebra, not immediates) and never see `Inline`; documented invariant. |
| Cascade double-frees/leaks an immediate | An immediate decodes to `RVBox (Inline tag)`, filtered by `isUncounted` in `countedRefs`; the mixed-field balance test (`live == baseline`) and the stat parity make any imbalance fail loudly. |
| `--dump-rc-stats` goldens silently wrong after re-baseline | Both backends shift identically (oracle diff still agrees); the re-baseline is a reviewed task with the Δ table justifying every changed number. |

---

## 10. Decisions resolved (override if needed)

Settled during brainstorming (2026-06-22):

1. **Scope = nullary-as-immediate only.** rc/immortal unification and phantom-`Addr` are
   deferred to their own slices (orthogonal; bundling conflates value-model changes).
2. **`Addr` grows `Inline Word32`** (not `RCValue` grows a new variant) — so the existing
   `deref`/`RVBox` paths carry it and the machine is untouched. Name `Inline` (not
   `AImm`/`Unboxed`/`Nullary`): location-axis parallel to abstract-heap/C-heap, no
   "immutable"/scalar-unbox confusion.
3. **2-bit low slot tag** (`00` CAddr, `01` HAddr, `11` Inline), Koka-style bit 0 =
   pointer-vs-value. `KPointer` subsumes pointer-or-immediate; no new `SlotKind`.
4. **C runtime unchanged** (byte-dumb); the only C addition is the additive
   `wok_stat_peak_bytes` observability counter.
5. **Immediates are uncounted**, reusing the static/`RVInst` precedent (`isUncounted` =
   static ∨ inline); dup/drop are runtime no-ops on them with no new machinery.
6. **Benchmark is a first-class deliverable** (alloc-count + bytes via `--dump-rc-stats` +
   `wok_stat_peak_bytes`); **no interpreter wall-clock claim**.

**Genuinely flaggable:** (a) the exact spelling of the uncounted predicate (`isUncounted`
helper vs widening `isStaticAddr`'s meaning — lean: a distinct `isUncounted`, keeping
`isStaticAddr` precise); (b) whether to also compute abstract-side peak bytes natively or
rely on the C counter (lean: C counter + analytical equality, since the oracle proves the
populations match).

---

## 11. What this slice unlocks

Immediates remove the most common heap objects, which compounds with the deferred frontier:

- **FBIP / reuse** now has fewer tiny cells competing for the arena's arity-0 free list (and
  the boolean churn that polluted it is gone) — the reuse hot path is cleaner.
- **Escape analysis:** a nullary result that used to be a short-lived heap cell is now a
  register-resident immediate for free — one fewer thing escape analysis must reason about.
- **Monomorphize / unbox containers** (the flat/unboxed frontier) is the *other* direction
  (remove the pointer-hop at a per-field padding cost); immediates are the boxed-and-lean
  direction taken to its limit for empty variants. The two compose: a monomorphised
  `List U64` still benefits from a nullary `Nil` immediate terminator.

Sequencing is unchanged from the Slice 1 spec (§11 there): compaction → immediates (this
slice) → FBIP → escape/region → reuse specialization → monomorphization. The two deferred
value-model cleanups land as their own slices: **rc/immortal unification** (the simpler
one, the natural next step — retire the negative-`HAddr` static mechanism for a saturating
`rc` sentinel), and the **phantom-typed `Addr`** (conditional — taken up only if the 3-way
`HAddr`/`CAddr`/`Inline` split proves error-prone in practice). The **C-driven `wok_drop`
cascade** remains the codegen-readiness follow-up.
