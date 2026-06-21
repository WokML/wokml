# C runtime allocator under the RC interpreter (NCon-first)

- **Date:** 2026-06-21
- **Status:** IMPLEMENTED (branch feat/c-runtime-allocator-ncon)
- **One line:** Replace the RC interpreter's abstract Haskell `IntMap` heap with a real,
  `malloc`-backed C heap reached over FFI, migrating the constructor node `NCon` first,
  with the interpreter still driving the free-cascade and the existing abstract-store
  interpreter retained as a differential oracle.

---

## 1. Goal and non-goals

### Goal

Make wok's reference-counting *real*. Today `__rc_dup`/`__rc_drop` execute against an
abstract heap — a `Data.IntMap` of `Cell { cRc, cNode }` (`Wok.Interp.RC.Value`). That
proves the Perceus dup/drop discipline *balances*, but it can never actually segfault: a
use-after-free is just a missing map key, and "free" is `IM.delete`. It does not prove the
design survives real `malloc`/`free`, real pointer aliasing, or real in-place reuse.

This slice puts the **constructor objects (`NCon`)** of a running program into a real
C-allocated heap, with the refcount and payload slots living in C memory, reached from the
interpreter over FFI. The interpreter remains the execution engine; nothing is emitted as
machine code yet. The C runtime built here is the **durable artifact a future codegen path
reuses** — codegen will emit calls to the same ABI.

### Why this, why now

The previously-considered fork was "M3 (escaping continuations) vs Codegen (the B
lowering)" (see `docs/m3-vs-codegen.html`). The decision recorded there does not bind this
work: the goal now is to reach a *codegen-ready runtime* without taking on codegen's second
hard half (the lowering) yet.

Codegen secretly bundles two independent hard problems: (1) a real **runtime** — allocator,
heap layouts, `incref`/`decref`/`free`, in-place reuse; and (2) the **lowering** of ANF to
emitted code. (1) is the novel, risky half — this project's own history records multiple
green-shipping double-frees that only adversarial review caught. (2) for a pure subset is
standard textbook work. This slice does the risky half **first**, under the interpreter,
where it stays fully introspectable, and keeps dogfooding alive the whole time (codegen-first
would have split program execution across two engines until effects were lowered).

### Non-goals (explicitly out of scope for this slice)

- **Arrays.** A flat array node is the natural *second* migrant; it is deferred to a
  follow-up so this slice validates the C heap against the entire existing corpus before any
  new surface-language work.
- **Closures and continuations in C.** `NClosure`, `NCont`, `NContCell`, `NGroupCode`, `NEnv`
  hold native Haskell payloads (`Expr` ASTs, `RCKont` frame stacks, `Map`s) that cannot be
  flattened into C slots without serializing the interpreter. They stay on the Haskell heap.
- **Descriptor-driven C cascade ("let C do the recursive free itself").** That is the
  codegen-ready *hardening* (§9). This slice keeps the cascade brain in Haskell.
- **Emitting code / a backend.** No instructions are emitted.
- **Speed.** A real allocator under a tree-walker is still a tree-walker. No performance
  claim is made or measured here; correctness and ABI fidelity are the deliverables.
- **Effects.** The effect machinery is untouched.

---

## 2. Background: what exists today

Two interpreters coexist:

- `Wok.Interp.*` — the plain interpreter. `VCon Text [Value]`, no refcounts, GHC-heap values.
- `Wok.Interp.RC.*` — the **RC interpreter** (M1). Executes `__rc_dup`/`__rc_drop` against an
  abstract refcounted store. This is the interpreter being modified.

The RC heap (`Wok.Interp.RC.Value`):

```haskell
type Addr  = Int                                   -- IntMap key; <0 = static/immortal
data Cell  = Cell { cRc :: Int, cNode :: Node }
data Store = Store { stCells :: IntMap Cell, stNext, stNextStatic :: Addr
                   , stDead :: IntSet, stStats :: Stats }

data Node  = NCon Text [RCValue] | NRecord Text (Map Text RCValue)
           | NClosure REnv [Binder] Expr CaptureMode | NGroupCode [...] | NEnv (Map ...)
           | NCont RCKont (Handler,Int,RCScope) | NContCell (Maybe Addr)

data RCValue = RVLit Lit | RVBox Addr | RVRecMember Addr Int Addr | RVInst Unique Int
data Lit     = LInt Integer | LStr Text | LChar Char | LUnit

alloc    :: Node -> Store -> (Addr, Store)               -- rc = 1
incref   :: Addr -> Store -> Either RuntimeError Store   -- bump; static = inert
dropAddr :: Addr -> Store -> Either RuntimeError Store   -- dec; at 0: cascade + free
```

`dropAddr` frees at zero and walks `cascadeChildren (cNode c)`:

```haskell
cascadeChildren (NCont prefix _) = continuationOwned prefix          -- bespoke owned-set
cascadeChildren other            = countedRefs (nodeValues other)    -- generic
nodeValues (NCon _ vs) = vs                                          -- the case we migrate
```

The whole RC machine is **pure**: `stepRC/returnToRC/runRC :: ... -> Either RuntimeError ...`,
threading `Store` by hand. `Stats` already counts `allocs/frees/live/peak`.

`alloc (NCon ...)` is called at exactly two sites — `RC/Machine.hs:203` (constructor
application) and `RC/Prim.hs:335` (nullary constructor prim). `deref` is the single read
boundary. `incref`/`dropAddr` are called from the `__rc_dup`/`__rc_drop` prims
(`RC/Prim.hs:58,76`) and a handful of machine sites; they already dispatch on `Addr`.

---

## 3. Design overview

### The heap is unavoidably split — and that is fine

Constructors and (later) arrays have *slot-vector* payloads — a flat list of `RCValue`. Those
can live in C. Closures and continuations hold native Haskell structures and cannot. So the
heap splits: **`NCon` in C, structured nodes in the Haskell `IntMap`.** The split nodes are
exactly the deferred effect machinery, so the line is clean.

### Who walks children on free: Haskell, still

A split heap means cross-heap edges are inevitable — `NCon "Box" [closure]` is a C cell whose
slot points at a Haskell-resident closure. The resolution: **C owns allocation, the refcount,
and the raw slots; Haskell keeps driving the cascade.** On a drop-to-zero, Haskell reads the
freed cell's slots back, runs the *existing* `countedRefs . nodeValues` logic, and routes each
counted child to whichever heap it lives in (C child → FFI `wok_drop`; Haskell child →
existing `IntMap` path). Cross-heap edges "just work," and none of the twice-reviewed
continuation owned-set logic is rewritten.

### `deref` is the marshalling boundary

The machine consumes `Node` values via `deref`. For a C address, `deref` reconstructs an
`NCon Text [RCValue]` by reading the cell's tag and slots from C and decoding them. Every
machine site that pattern-matches `Node` (e.g. `case` dispatch) is therefore **unchanged** —
only `deref`, `alloc`, `incref`, `dropAddr` learn about C. `deref` is where bytes become a
`Node` and back.

### One worked example

`[1, 2]` builds three `NCon` cells. After migration they are three `malloc`'d `WokObj`s:

```
C cell P_A:  tag=Nil  arity=0
C cell P_B:  tag=Cons arity=2  slots=[ LIT_INT 2 ,  CBOX P_A ]
C cell P_C:  tag=Cons arity=2  slots=[ LIT_INT 1 ,  CBOX P_B ]    rc=1 each
```

Dropping the list: `dropAddr (CAddr P_C)` → `wok_dec P_C` returns 0 → Haskell reads P_C's
slots → `countedRefs` yields `[CAddr P_B]` (the `LIT_INT 1` slot is inert) → `wok_free P_C` →
recurse on `CAddr P_B` → … → `wok_free P_A`. Exactly the existing cascade, now over real
memory.

---

## 4. The C runtime (held to `HPC-C.md`)

### Dialect and flags

- **Standard: C17** (decided). Universally supported by GCC/Clang under a `-Werror -Wpedantic`
  wall in 2026; gives flexible array members, `_Static_assert`, `restrict`, `<stdint.h>`.
  C23 migration later is mechanical and noted as a non-goal now.
- **Flags** (the integer/pointer subset of `HPC-C.md`; the runtime has no floating point, so
  the `-ffast-math` / `-fno-associative-math` family is N/A and omitted):
  ```
  -std=c17 -O3 -fstrict-aliasing -Wstrict-aliasing=2 -fwrapv
  -Werror -Wall -Wextra -Wpedantic -Wconversion -Wdouble-promotion
  -Wstrict-prototypes -Wformat-security
  ```
- **Strict aliasing obeyed, not disabled.** Any byte reinterpretation (a slot payload read
  back as a pointer) goes through `memcpy` into a typed temporary — the blessed, single-`mov`
  idiom — never a raw cast. `restrict` on hot pointers; `__builtin_expect`-based
  `LIKELY/UNLIKELY` macros mark the rc==0 free path UNLIKELY; `wok_tag`/`wok_arity` are
  `__attribute__((const))`.
- **Sanitizer build** in CI: a second compile at `-O1 -fsanitize=address,undefined` with
  LeakSanitizer, run over the whole corpus. Real use-after-free / leak / UB is caught here,
  not inferred.

### Object and slot layout (the pinned ABI)

```c
typedef struct WokSlot {           // 16 bytes, correctness-first; NaN-boxing deferred (§9)
    uint64_t tag;                  // WokSlotTag
    uint64_t payload;              // value | C-pointer-bits | Haskell-addr int
} WokSlot;

typedef struct WokObj {
    uint64_t rc;                   // reference count (>=1 while live)
    uint32_t tag;                  // interned constructor id (opaque to C)
    uint32_t arity;                // number of slots
    WokSlot  slots[];              // flexible array member, `arity` entries
} WokObj;

typedef enum WokSlotTag {          // the encodable RCValue shapes (§5)
    WS_LIT_INT  = 0,               // payload = int64 bit-pattern (fits-in-64 LInt)
    WS_LIT_CHAR = 1,               // payload = code point
    WS_LIT_UNIT = 2,
    WS_CBOX     = 3,               // payload = WokObj*  (another C cell)
    WS_HBOX     = 4                // payload = Haskell Addr (Int into the IntMap heap)
} WokSlotTag;
```

`tag` is an interned `uint32` id, never interpreted by C — the constructor's *identity* stays
in Haskell (the APrim `(Module, Name)` interning, §5). `rc` is unsigned; underflow on
`wok_dec` of an already-zero cell is a trapped invariant violation (the C analogue of the
existing `double-free` `Left`).

The 16-byte header (`rc:64 + tag:32 + arity:32`) and 16-byte slot are deliberately the
*uncompacted* forms — they halve under the deferred layout-compaction slice (§9). Slice 1
keeps them wide for clarity while the RC cascade is being proven.

### Allocator (slice 1): plain `malloc` / `free` (Decision 1)

Behind `wok_alloc`/`wok_free`, slice 1 uses plain `malloc`/`free` — deliberately, to **isolate
the variable under test**. The risky, unproven thing here is the RC cascade (IO threading, slot
encode/decode, cross-heap recursive free), not the allocator. With a *trusted* allocator, any
memory bug the oracle catches is unambiguously in our RC logic — not split between our cascade
and a hand-rolled free-list we'd also be debugging. Furthermore, `malloc`-per-cell with **no
per-run arena** is the *strictest* leak test: the RC cascade is the only thing that frees
memory, so a single missing drop surfaces immediately as `stStats` live != 0 (an arena would
*mask* it by bulk-freeing at run end). So `wok_heap_new` only inits per-run stats, `wok_alloc`
= `malloc`, `wok_free` = `free`, and `wok_heap_free` asserts live == 0 and frees nothing (the
cascade already did). mimalloc is rejected for slice 1 specifically: its v2 heaps may only
*allocate* from the creating thread, which races silently under GHC's thread-migrating RTS.

The wok-tailored allocator is a *later* slice (§9 "Language-specific allocator"), validated
against this malloc-backed run as oracle.

### The ABI (the entire FFI surface)

All state lives in a per-run **`WokHeap` context** — there is no global runtime state. One
heap is created at the start of a module run and freed at its end, so parallel `tasty` runs
never share mutable C state. (`WokHeap` is opaque to Haskell; it owns the allocation arena and
the per-run `WokStats`.)

```c
WokHeap* wok_heap_new(void);                          // fresh per-run context
void     wok_heap_free(WokHeap* h);                   // tear down; reports residual live cells

WokObj*  wok_alloc(WokHeap* h, uint32_t tag, uint32_t arity);  // header+slots, rc=1, slots undef
void     wok_dup(WokObj* p);                          // rc++
uint64_t wok_dec(WokObj* p);                          // rc--, returns NEW rc; does NOT free
void     wok_free(WokHeap* h, WokObj* p);             // free the cell (caller reads slots first)
void     wok_slot_set(WokObj* p, uint32_t i, uint64_t tag, uint64_t payload);
void     wok_slot_get(const WokObj* p, uint32_t i, uint64_t* tag, uint64_t* payload);
uint32_t wok_tag(const WokObj* p);
uint32_t wok_arity(const WokObj* p);
WokStats wok_stats(const WokHeap* h);                 // {allocs,frees,live,peak} for the oracle
```

The split (`wok_dec` returns the new count without freeing; the caller reads slots, then calls
`wok_free`) mirrors the existing `dropAddr` ordering: collect children, delete the cell, then
process the children. Allocation failure (`malloc` returns NULL) aborts the runtime — there is
no graceful path, and modelling one would be over-engineering for a research interpreter. The
Haskell `Store` carries the live run's `Ptr WokHeap` handle, created in `runModuleRC` and freed
when the run completes.

---

## 5. The Haskell side

### `Addr` becomes a sum (eliminate the invalid state)

```haskell
data Addr = HAddr !Int            -- IntMap-resident node (dynamic >=0, static <0 as today)
          | CAddr !(Ptr WokObj)   -- real C cell
```

This unifies the interface: `RVBox (CAddr p)` is a C constructor, `RVBox (HAddr i)` a Haskell
node; `valueChildren (RVBox a) = [a]` and `countedRefs` are **untouched**. `isStaticAddr
(HAddr i) = i < 0`; `isStaticAddr (CAddr _) = False`. The Store's `IntMap`/`IntSet` continue
to key on the `Int` inside `HAddr`; `CAddr` cells never enter them. The change is mechanical
(the compiler finds every site) and concentrated in `alloc`/`incref`/`dropAddr`/`deref` plus
the `Int`-keyed map accesses.

### Slot encode/decode and the encodable-or-fallback rule

A 16-byte slot holds one machine word of payload, so not every `RCValue` fits. The rule:

| `RCValue` field            | Encoding                          |
| -------------------------- | --------------------------------- |
| `RVLit (LInt n)`, `n` in `Int64` | `WS_LIT_INT`                 |
| `RVLit (LChar c)`          | `WS_LIT_CHAR`                     |
| `RVLit LUnit`              | `WS_LIT_UNIT`                     |
| `RVBox (CAddr p)`          | `WS_CBOX`                         |
| `RVBox (HAddr i)`          | `WS_HBOX`                         |
| `RVLit (LStr _)`, bignum `LInt`, `RVRecMember`, `RVInst` | **not encodable** |

**Fallback:** at `alloc` time, if *any* field is not encodable, the whole `NCon` is allocated
on the Haskell `IntMap` heap (as today) and returned as an `HAddr`. Everything downstream
already dispatches on `Addr`, so the fallback falls out for free and costs no extra code path.
In practice real programs build constructors from literals and pointers, so the C path covers
the overwhelming majority; the fallback guarantees correctness for the rare cases without
fattening the slot or adding a side-table. (`LStr` and bignum support in C is a later slice if
the corpus ever needs it.)

### Tag interning

A Haskell-side bijection `ConIdentity <-> Word32` (keyed on the APrim `(Module, Name)`
identity from the #12 work). `alloc` interns the constructor to its id and passes it to
`wok_alloc`; `deref` reads `wok_tag` and maps the id back to the `Text`/identity for `case`
matching and rendering. C stores the id opaquely.

### Purity: thread `IO` honestly to the public boundary (decided)

Real `malloc`/`free` is `IO`. Two unsound shortcuts are both rejected:

- **Pure foreign imports.** A pure signature promises "same args → same result, no effect."
  `wok_alloc` breaks it (each call returns a fresh distinct pointer), so GHC is entitled to
  CSE two allocations into one alias, float an `alloc` out of a loop, or DCE a `drop` whose
  result is unused. The optimizer is correct given the false promise; "being careful" cannot
  fix a violated contract.
- **A single `unsafePerformIO` at the run boundary.** Sound *today* (the run is observably
  pure), but a latent footgun: the day a run stops being self-contained — a shared heap, a
  pointer leaking into the result — the purity claim silently goes false with no type error to
  catch it.

So the FFI imports are `IO` (and `unsafe` — the C runtime never calls back into Haskell, since
the cascade is Haskell-driven), and `IO` is threaded **honestly all the way to the public
boundary**: `alloc/incref/dropAddr/deref/stepRC/returnToRC/runRC` move from `Either
RuntimeError a` to `ExceptT RuntimeError IO a`, and the entry points become

```haskell
runModuleRC          :: CoreModule -> IO (Either RuntimeError RCRun)
runModuleRCUnchecked :: CoreModule -> IO (Either RuntimeError RCRun)
runExprRC            :: RCPrimTable -> REnv -> Store -> Expr
                     -> IO (Either RuntimeError (RCValue, Store))
```

The type now tells the truth and there is nothing subtle to get wrong later. The blast radius
is small because **every caller already runs in `IO`**: `app/Main.hs` is inside `main`, and all
`test/Spec.hs` sites are inside tasty `testCase "..." $ do` blocks (no QuickCheck property runs
the RC interpreter purely). Adapting them is the mechanical rewrite `case runModuleRC x of …`
→ `runModuleRC x >>= \case …`, staying in the same do-block.

This is the largest mechanical change in the slice and is sequenced **first** (Task 0), behind
the *old* Haskell heap (no C yet), so it ships green and behavior-preserving before any FFI is
introduced. It also aligns the interpreter with how a real (and codegen'd) runtime executes.

---

## 6. The differential oracle

Both heap backends coexist for this slice — the abstract-store path is *retained, not
replaced* — selected by a `HeapBackend` field threaded in `Store` (§7 Task 2). That lets the
oracle run the same program both ways and diff. Verification has two legs:

1. **Result parity.** Every program in the corpus, run through the C-backed RC interpreter,
   produces the byte-identical rendered result the plain interpreter (`Interp.runModule`)
   produces — the existing M1 differential pattern, extended to the C backend.
2. **Stats parity + balance.** Run the same program under both the abstract-store and the
   C-backed backend; their `allocs`, `frees`, and `peak` must match exactly, and `live` at a
   clean run's end must be 0. Identical alloc/free counts is a strong structural proof: no
   leak, no double-free, no missing or extra drop. This is nearly free because both backends
   already maintain `Stats`. (Balance alone could miss a symmetric miss — an absent alloc *and*
   its absent free — which is exactly what the exact-count diff against the abstract store
   catches.)

Plus targeted tests: cross-heap cascade (a C `NCon` field holding a Haskell closure, and a
closure capturing a C `NCon`); the fallback path (a constructor with an `LStr`/`RVInst`
field); deep list build/drop (cascade depth); and the sanitizer corpus run (§4) for real
memory safety.

---

## 7. Task breakdown (each ships green)

> Native tasks are created at the writing-plans step, after this spec is approved.

- **Task 0 — IO-thread the RC interpreter to the public boundary.** Move `alloc/incref/
  dropAddr/deref/stepRC/returnToRC/runRC` to `ExceptT RuntimeError IO`; `runModuleRC` /
  `runModuleRCUnchecked` / `runExprRC` return `IO (...)`. Heap still the Haskell `IntMap` — no
  C yet, no behavior change. Adapt the `IO`-native callers (`app/Main.hs`, `test/Spec.hs`
  `testCase` blocks) by the `>>= \case` rewrite. Full suite green; de-risks the IO thread in
  isolation.
- **Task 1 — C runtime + build wiring.** `runtime/wok_rc.{c,h}` implementing the §4 ABI;
  cabal `c-sources` / `cc-options` / `include-dirs`; the sanitizer build target; Haskell
  `foreign import ccall` bindings + `Ptr WokObj` in a new `Wok.Interp.RC.Heap`.
- **Task 2 — Add the C-backed `NCon` path (alongside the abstract store).** `Addr` sum; slot
  encode/decode; the encodable-or-fallback rule; a `HeapBackend = Abstract | C !(Ptr WokHeap)`
  field in `Store` so the abstract path is *retained* for the oracle; the two `alloc (NCon
  ...)` sites and `deref`/`incref`/`dropAddr` branch on the backend, with the Haskell-driven
  cascade for the `CAddr` path; tag interning. The production runner (`app/Main.hs`) selects
  `C`; the oracle (Task 3) runs both.
- **Task 3 — Oracle + tests + sanitizers.** Result + stats parity harness across both
  interpreters over the whole corpus; targeted cross-heap / fallback / deep-cascade tests;
  CI sanitizer run.
- **Task 4 — Docs + memory.** Record the pinned ABI as the codegen contract; update the
  relevant memory notes; clean up scaffolding.

---

## 8. Risks and mitigations

| Risk | Mitigation |
| ---- | ---------- |
| IO refactor churn destabilizes a 1200-test-green interpreter | Task 0 isolates it behind the old heap; ship green before any C. |
| Slot encode/decode bug corrupts values silently | Stats + result parity over the whole corpus; ASan/UBSan; `_Static_assert` on layout sizes. |
| Cross-heap cascade double-frees or leaks | Haskell drives the cascade (reuses reviewed logic); dedicated cross-heap tests; stats parity makes any imbalance fail loudly. |
| Honest-IO threading churns many call sites | Blast radius is mechanical (`>>= \case`) and contained: every RC-run caller is already in `IO` (`main`, tasty `testCase`). Both unsound shortcuts (pure imports, boundary `unsafePerformIO`) are explicitly rejected. |
| Global C state races under parallel `tasty` | No globals: per-run `WokHeap*` context, created/freed per module run. |
| Tag-id drift between alloc and deref | Single interning bijection keyed on APrim identity; round-trip property test. |

---

## 9. Explicitly deferred (the codegen-ready hardening, and beyond)

- **Descriptor-driven C cascade.** Register a per-constructor layout (arity + which slots are
  counted pointers) so C does the full recursive free itself for plain data — the form codegen
  emits against. It is a *fast path over the Haskell cascade*, not a replacement (cross-heap
  and continuation frees still need the Haskell brain), so it layers cleanly later.
- **Arrays** as the second slot-vector node (flat, often unboxed elements, the place in-place
  reuse / FBIP matters most) — the dogfooding payoff.
- **Closures / continuations in C** (needs a code-pointer + serialized-frame representation).
- **Layout compaction (one slice, ~50% smaller cells, ~2x cache density).** Done together,
  with benchmarks: pack the header into **8 bytes** (`rc:32` with saturating overflow ->
  immortal, `tag:16`, `arity:8`, `scan_count:8` — the leftover byte absorbs the scan count for
  free); shrink each field slot from the 16-byte `{tag,payload}` pair to a **single 8-byte
  tagged word** (low-/spare-bit pointer-vs-value tag, as Koka does); adopt the
  **pointers-first** convention so `scan_count` enables the descriptor-driven C cascade above.
  All behind the private accessor ABI (`wok_tag`/`wok_arity`/slot get/set) -> no ABI break.
  Cost (why it's out of the correctness slice): shift/mask accessors + manual byte layout
  (endianness).
  - **Further packing frontier (deeper layer — touches the *value representation*, not just the
    struct):** **nullary constructors as immediates** — `Nil`/`None`/`True`/`()` become tagged
    values with **zero allocation**, eliminating the most common heap objects entirely (Koka
    does this); **pointer-tagged small scalars** — a scalar field carries its tag in spare
    pointer bits, no cell and no separate tag word; **refcount elision** for provably-unique
    objects (ties into the existing one-shot / multiplicity analysis). These change what a
    field can *hold*, so some interact with the ABI's value model — a separate design pass
    after the struct-level compaction above.
- **Language-specific allocator (the "allocator slice").** Replace slice-1 `malloc`/`free`
  with a wok-tailored pool: exact arity-keyed size classes (`16 + 16*arity` -> 16/32/48/64…,
  zero rounding waste, few hot classes), a per-run slab arena with O(1) bulk teardown, and LIFO
  same-class reuse (the FBIP substrate). Decide hand-rolled-pool vs mimalloc first-class heaps
  (v3, or v2 + bound-thread per heap) with benchmarks; validate against the slice-1
  malloc-backed oracle.
- **Emitting code.** The lowering half, against this now-real runtime.
- **Packed/serialized representation (LoCal/Gibbon) — far-future, *separate model*.** An opt-in
  `packed` representation for immutable AST-shaped types, sitting *beside* the RC heap (it is an
  opposing ownership model — region-level RC + write-once + scan/offset access — not a variant
  of our cells). Only pays off post-codegen and conflicts with per-value RC / sharing / random
  access / FBIP, so the hard cases would be forbidden, not solved. See
  `../2026-06-21-packed-data-local-research.md`.

---

## 10. Decisions resolved (override if needed)

Settled during design (2026-06-21), validated against the mimalloc/Koka research
(`../2026-06-21-mimalloc-koka-allocator-research.md`):

1. **Sequencing: `IO` threaded honestly to the public boundary** (no `unsafePerformIO`); per-run
   `WokHeap*` context, no global state (§4, §5).
2. **Decision 1 — slice-1 allocator is plain `malloc`/`free`**, to isolate the RC cascade as the
   variable under test; the wok-specific pool / mimalloc is the deferred "allocator slice"
   (§4, §9).
3. **Decision 2 — `scan_count` deferred** into the consolidated layout-compaction slice (it's an
   optimization, and the header is private behind the accessor ABI, so adding it later is no ABI
   change) (§9).
4. **Header/slot stay uncompacted (16 B each) in slice 1**; the 8-byte-header + 8-byte-slot
   compaction (~50% smaller cells) and the further frontier (nullary-as-immediate, etc.) are one
   designed later slice (§9).

Still genuinely flaggable: **C standard** decided as C17 (override for C23); the **fallback
boundary** keeps `LStr`/bignum/`RVRecMember`/`RVInst`-bearing constructors on the Haskell heap
(override to encode any in C from day one).

---

## 11. Post-implementation follow-ups

Surfaced during implementation and review; deliberately deferred so they are not lost.
None of these is a correctness bug — all four interpreter legs and the differential oracle
are green (full suite 1278 passing). The pinned ABI is documented in `runtime/README.md`.

- **Two renderers to consolidate.** Task 2 added `renderRCValueRC`, an `IO`-twin of the
  pure `renderRCValue`, because the pure renderer's `derefPure` rejects `CAddr` (a C cell
  read is `IO`). The two are currently byte-identical and **must stay in sync** by hand.
  Future cleanup: collapse them into a single renderer parameterized over the deref action
  (e.g. `Monad m => (Addr -> m Cell) -> ...`), so the pure and IO paths share one body.
- **`Value.hs` size.** `Wok.Interp.RC.Value` grew ~33%: it now also holds the C-encoding
  block (`internTag` / `tagName` / `encodeSlot` / `decodeSlot` / `readCCell` / `readCSlots`).
  Once the abstract/C boundary stabilizes, consider extracting that block into a small
  `Wok.Interp.RC.CSlot` module to keep `Value.hs` focused on the abstract store.
- **Cosmetic C teardown warning.** `wok_heap_free` prints `heap freed with N live cells
  (leak)` to stderr for CAF-baseline programs whose immortal value-CAF cells are
  legitimately live at run end (`stLive == rcBaseline > 0`). This is **not** a leak and
  does not fail any test. A future change could suppress the warning when
  `live == baseline`, or have the CLI drop the baseline before teardown.
- **`runExprRC` boundary round-trip.** Internal callers wrap/unwrap `runExprRC`'s
  `IO (Either ...)` (e.g. `ExceptT (runExprRC ...)`). As more internal callers appear, a
  future cleanup could expose an internal `RC`-typed (`ExceptT RuntimeError IO`) variant to
  avoid the `IO (Either ...)` round-trip at each call site.
- **Sanitizer scope.** `scripts/asan-runtime.sh` sanitizes the C runtime's own standalone
  test, not the Haskell C-backed interpreter under ASan (which is fiddly through GHC's RTS).
  The Haskell C-path soundness signal is therefore the **differential parity** — exact stat
  match against the abstract-store oracle, plus no C-side abort — not ASan over the
  interpreter.
