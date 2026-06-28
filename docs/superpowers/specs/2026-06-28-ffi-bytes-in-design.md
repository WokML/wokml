# FFI bytes-in — the C→RC ownership handoff (Slice 1, host-blessed)

Status: DRAFT (brainstorm converged 2026-06-28; pending user review of this spec,
then plan + execute). Builds on E6 (`Bytes` + validated `fromBytes`/`toBytes`),
which is FF-able to `main` on `feat/string-slice-e6-bytes`.

Links: `string-architecture-slice-e` (E6 section), `extern-primitive-declarations`,
`array-slice-b-c-cell`, `string-architecture-slice-e` (E4 view router),
`region-slice-r1`, `c-runtime-data-vs-state-split`.

---

## 1. Motivation and goal

E6 built the validated boundary `fromBytes : Bytes -> Option String` — the one door
through which raw bytes may become a `String`. It is deliberately producer-agnostic.
This slice supplies the first *real* producer: a byte buffer that originates **outside
the wok allocator** (a libc `malloc`, a real C function, eventually a file/socket) and
must be brought into the reference-counted runtime as a `Bytes` value.

The genuinely new problem is **the C→RC ownership handoff**: who allocates the cell,
how the runtime adopts or copies the foreign buffer, how it refcounts it, and how it
frees across the FFI boundary without leak, double-free, or use-after-free.

This slice is pure **banking**: the ownership model it establishes is codegen-durable
(it survives unchanged into a future native backend). It deliberately does **not** build
the user-facing FFI surface or the optimal call path — see §3.

### The bank-vs-cash framing (kept in view, not acted on)

The research (LuaJIT FFI internals, cross-checked against Rust/OCaml/GHC/Zig) is
unambiguous that an *optimal* foreign call — no trampoline, no marshalling, the C-ABI
call inlined into machine code — is a **codegen** property. LuaJIT's own cost model
(Mike Pall, 2012): a JIT-compiled FFI call is ~20–30× faster than the classic API, but
an *interpreted* FFI call is ~5× *slower*, and "no effort has been put in to make the
FFI fast for the no-JIT case ... I doubt it's worth the trouble." Building dynamic
`dlopen`/`libffi` machinery in wok's tree-walking interpreter would therefore be both
*throwaway* (codegen lowers calls completely differently) and *slow*. The optimal call
is the "cash" we collect once a QBE/SSA backend exists; this slice collects none of it
and intentionally leaves it parked.

The interpreter's honest, correct, and reasonably cheap FFI path is the GHC
`unsafe foreign import` pattern (the same mechanism that already binds StringZilla and
the `wok_rc` runtime): statically-linked host bindings, non-reentrant (cannot touch
continuations), no `dlopen`. This slice uses exactly that.

---

## 2. Background: the current cell model and the gap

E6's `Bytes`:

- builtin tycon `TcBytes` (`src/Wok/TypeChecking/Builtins.hs:35`);
- reference interpreter node `VBytes ByteString` (`src/Wok/Interp/Value.hs:71`);
- RC interpreter node `NBytes ByteString` (`src/Wok/Interp/RC/Value.hs:695`);
- C cell `WokBytes`, tag `0xFFFC` (`runtime/wok_rc.h`), layout: 8B header
  (`rc:u32, tag:u16, arity:u8, scan:u8`) + 8B `byte_len` + inline bytes at offset 16;
  allocate via `wok_bytes_alloc(h, byte_len)`, data pointer **derived** as
  `wok_bytes_data(p) = (char*)p + 16` (`runtime/wok_rc.c:847`).

The handoff path that already exists (and that Tier 1 reuses verbatim):
`alloc (NBytes bs)` dispatches on backend (`RC/Value.hs:1633`); on `CHeap` it calls
`allocNBytes` (`RC/Value.hs:1782`) which does `wokBytesAlloc` → `wokBytesData` → `memcpy`
→ `recordAlloc (wouldBeCBytes (NBytes bs))`. FFI bindings: `RC/Heap.hs:55-59`.

**The gap.** Every wok cell stores its payload *inline* and derives the data pointer
from the cell address. There is no `data_ptr` field, no destructor slot, no
`adopt`/`from_raw` anywhere in the runtime. So today a cell **cannot point at foreign
memory** — its bytes always live inside a wok-allocated cell. Tier 2 (adoption) is
exactly the work of lifting that restriction, soundly.

---

## 3. Scope

### In scope (Slice 1)

1. **Tier 1 — copy-in.** Bring a foreign `(ptr, len)` into a normal `WokBytes` cell by
   `memcpy`; the foreign side frees its own buffer. Reuses `allocNBytes`.
2. **Tier 2 — adopt.** A new cell that *points at* the foreign buffer and frees it via a
   foreign free at refcount-zero (the deterministic `ffi.gc(ptr, C.free)` analogue). In
   this slice the foreign free is hardcoded as libc `free` (the *declared* destructor is
   Slice 2).
3. A **host-blessed deterministic producer** that genuinely allocates off-heap memory on
   the C backend, exercising both tiers, with content fixed so the differential oracle
   bites.
4. Integration with the existing `fromBytes` gate (no change to `fromBytes` itself).
5. The **off-heap byte accounting** that keeps the differential oracle's `peak_bytes`
   in parity across backends for the adopt path.

### Out of scope — deferred, recorded as first-class follow-ons

- **The Path-C FFI surface (Slice 2):** `foreign module Libc "c" where ...` accessed as
  `Libc.read`, resolved by a small FFI-local `lookupForeignModule` rule mirroring the
  existing effect-operation dot (`Infer.hs:1775`); the `IO` ground effect; the
  user-allowed `extern` gate flip; the `using free` destructor clause (its exact form —
  bare symbol vs `lib`+`symbol` — is a Slice-2 decision) that becomes the user-facing face
  of the Tier-1-vs-Tier-2 decision. A C library maps to a
  *module* (a namespace), never to an effect — namespace and capability stay orthogonal
  (the module says *where* a symbol lives; `with IO` says *that* it touches the world).
- **The "reference"/borrow tier (future):** zero-copy *borrow* of a foreign buffer —
  the E4 string-view router (`Window | Counted | Copy`) applied to foreign memory, gated
  by the activation-scoped escape analysis. Because wok cannot *prove* a foreign
  buffer's lifetime, the safe shape is a *scoped* borrow: `withForeignBytes buf (\b -> …)`
  where the borrowed `Bytes` is valid only inside the callback and the escape analysis
  guarantees it cannot leak (GHC `withForeignPtr` / Rust closure-scoped borrow). At
  codegen this lowers to a bare fat pointer (true zero-overhead); in the interpreter it
  always-counts (sound, not yet zero-cost), exactly as E4 views do.
- **The optimal call (codegen "cash"):** `dlopen`/`libffi`, inlined C-ABI calls,
  allocation-sinking. Only meaningful once the native backend exists.
- **General declared destructors:** calling an arbitrary C free named by `using free`
  needs a `foreign import ccall "dynamic"` trampoline; Slice 1 hardcodes libc `free`.

---

## 4. Design

### 4.1 The two tiers and how they are differentiated

The C type signature cannot decide copy-vs-adopt. It decides only **value vs reference**:
a by-value scalar (`U64`, `Bool`) has no buffer and no ownership question; a by-reference
buffer (`Bytes`, `String`) is the only case where "who frees this?" arises. *Within* the
reference case the type is silent — a `uint8_t*` may point at a static buffer (never
free, copy), a transferred `malloc` (adopt+free), a caller-owned buffer, or a
borrow-until-next-call. This is the load-bearing LuaJIT finding: owned and foreign
pointers are representationally indistinguishable, which is exactly why every safe FFI
makes the human **declare** the policy (Rust `from_raw` vs `to_vec` vs `CStr`; GHC
`newForeignPtr` vs `peek` vs `newForeignPtr_`; OCaml `MANAGED` vs `EXTERNAL`; LuaJIT
`ffi.gc`).

So the policy is always a **declared contract**, never inferred:

- **Slice 1:** the contract is declared *in the Haskell host binding* — a copy-in
  producer calls the Tier-1 path; an adopt producer calls the Tier-2 path. The binding
  author knows the C function's contract because they wrote the binding.
- **Slice 2:** the `using free` clause on a `foreign module` member is the user-facing
  face of the same decision; absence → copy (Tier 1, the safe default), presence →
  adopt (Tier 2).

Copy is the default and is *never wrong* (just a `memcpy` cost). Adopt is the opt-in
optimization and an *unchecked assertion* that the buffer is heap-owned and transfers to
wok; declaring it on a non-heap pointer is UB exactly as in every other FFI.

### 4.2 Tier 1 — copy-in (reuses the existing path)

On `CHeap`: the producer obtains a genuinely foreign buffer (real libc `malloc`, filled
deterministically), the Tier-1 path `memcpy`s it into a fresh `WokBytes` cell via the
existing `allocNBytes`, and the producer frees the foreign buffer immediately. The
result is an ordinary wok-owned `WokBytes` (`CAddr`), refcounted and freed normally. On
the abstract and reference backends there is no real foreign memory; the producer yields
the deterministic `NBytes`/`VBytes` directly. No new runtime machinery.

### 4.3 Tier 2 — adopt (the new mechanism)

A new C cell holds a pointer to foreign memory rather than inline bytes.

- **New tag** `WOK_FOREIGN_BYTES_TAG = 0xFFFB` (next reserved id below `WokBytes`'
  `0xFFFC`). Fixed 24 B layout (size class 2, shared with `NCon` arity-2):
  - offset 0: 8 B header (`rc, tag=0xFFFB, arity=0, scan=0`);
  - offset 8: 8 B `data_ptr` — the **foreign** buffer pointer;
  - offset 16: 8 B `byte_len`.
  The **tag**, not the (zero) arity, is the sole discriminant: `wok_free` must branch on
  `0xFFFB` **before** its arity-based size-class fallback (mirroring the existing
  `0xFFFC`/`0xFFFD` arms in `wok_rc.c`), else it would size the cell as
  `wok_cell_bytes(0)` = 8 B and recycle it to the wrong free-list.
- **Allocator** `wok_foreign_bytes_alloc(h, data_ptr, byte_len)`: allocates the fixed
  24 B cell, stores `data_ptr` and `byte_len`, `rc=1`, and charges its **real 24 B** to
  `cur_bytes` (the normal "charge = cell size" rule — no override). The `n`-byte foreign
  buffer is **not** charged to the logical byte stat; it is foreign memory (see §4.6).
- **Byte access is tag-dispatched.** Every `Bytes` op reads bytes through the one
  accessor the E6 Bytes prims already funnel through; it must branch on the cell tag:
  `WokBytes` (`0xFFFC`) → bytes at offset 16 (today's path); `WokForeignBytes` (`0xFFFB`)
  → `byte_len` bytes at the stored `data_ptr`. This mirrors the E4 fix where `byteAt`'s
  `CAddr` fast-path had to tag-guard against a view cell. Because all ops funnel through
  this accessor, `length`/`index`/`fromBytes`/`toBytes`/`eqBytes` work transparently on
  adopted buffers with no per-op changes.
- **Haskell-driven drop with the foreign free.** At refcount-zero, `dropAddr` for a
  foreign-bytes cell: (1) reads `data_ptr` via a new accessor `wok_foreign_bytes_ptr`,
  (2) calls libc `free` on it (a direct `foreign import ccall "free"`; no dynamic
  trampoline while the destructor is fixed), (3) `wok_free`s the 24 B cell (which
  un-charges its 24 B and recycles it to class 2). `wok_free` never dereferences
  `data_ptr` (byte-dumb, recycles by size class, `scan=0`), so there is no double-free and
  the foreign pointer is never chased by C — exactly the `WokStringView`
  Haskell-driven-drop convention. Free ordering: foreign buffer first, then the cell.

### 4.4 RC node and backend modeling

- Reference interpreter: both tiers produce `VBytes bs` (a pure model; ownership is not
  observable here).
- RC abstract heap: Tier 1 (copy) produces `NBytes bs` charged `wouldBeCBytes(n)`;
  Tier 2 (adopt) produces a **distinct** node `NForeignBytes bs` that *holds* `bs` (so
  byte ops and output stay correct) but charges a **fixed 24 B** — the handle — modeling
  that the buffer is foreign. The distinct node is what makes the abstract backend's
  `peak_bytes` track the C backend's 24 B handle rather than the buffer (§4.6); it is
  therefore load-bearing, not optional.
- RC C heap: Tier 1 → `WokBytes` (`CAddr`, `0xFFFC`); Tier 2 → `WokForeignBytes`
  (`CAddr`, `0xFFFB`) pointing at the real foreign buffer. The C tag is the sole
  discriminant for both the byte accessor and the `dropAddr` free path.

### 4.5 The host-blessed producer (transitional test vehicle)

Two prelude-only intrinsic prims (`extern`, `__`-prefixed per the `__coro_susp` /
`__cont_store` convention), one per tier, declared in `Std.Bytes` (or a small
`Std.Foreign` module):

- `__ffi_demo_copy  : U64 -> Bytes` — Tier 1: malloc a buffer of the given length, fill
  with a deterministic pattern (e.g. byte `i = i mod 256`), copy-in, free the buffer.
- `__ffi_demo_adopt : U64 -> Bytes` — Tier 2: malloc + fill identically, adopt the
  pointer (no copy), register libc `free` as the refcount-zero destructor.

They are **pure-typed** in Slice 1 because (a) the `IO` ground effect does not exist yet
(it arrives with the Slice-2 surface) and (b) the differential oracle requires
determinism. Their purpose is to exercise the *memory-ownership path*, not I/O. They are
explicitly transitional: Slice 2 generalizes them into user-declared `foreign module`
members; real effectful producers (file/socket reads) arrive with `with IO`. Both
producers feed `fromBytes` unchanged.

### 4.6 Accounting — the adopt cell charges its handle, not the foreign buffer

The differential oracle compares the Haskell-side stats (`recordAlloc`,
`RC/Value.hs:831`) against the C `wok_stat_peak_bytes` (`test/Spec.hs`'s rc-bytes oracle
compares `stPeakBytes` against `wokStatPeakBytes`); they are independent counters that
must agree. For `WokBytes` they match because `wouldBeCBytes(n)` equals the inline cell
size.

For the adopt path the foreign buffer lives **off the wok heap**, so only the 24 B handle
cell is wok-managed. Every backend therefore charges a **fixed 24 B** for an adopted
value (its handle) and does **not** count the `n`-byte foreign buffer in the logical byte
stat. This is exactly truthful (those bytes are foreign) and needs **no** override of the
usual "charge = cell size" rule: the C `wok_foreign_bytes_alloc` charges its real 24 B,
the abstract `NForeignBytes` charges a fixed 24 B, and `recordAlloc`/`recordFree` do
likewise. The earlier "charge as if it were a `WokBytes`" idea is explicitly
**rejected** — it would force `wok_free` to size the cell from `byte_len` and mis-route a
24 B cell to a large free-list class.

Consequence and benefit: an adopt of an `n`-byte buffer reports `peak_bytes` lower than a
copy of the same buffer by exactly `wouldBeCBytes(n) - 24`, and the oracle **pins that
zero-copy saving** on both RC backends — directly mirroring the E4 string-view "exact
`peak_bytes` no-copy savings" invariant, so the oracle can *see* and *enforce* the point
of adoption. The foreign buffer's physical bytes are not tracked by wok stats (foreign
memory); tracking them would be a `peak_physical_bytes`/codegen concern, deferred with the
optimal-call work.

---

## 5. Soundness invariants

1. **`fromBytes` stays the only door into `String`.** Foreign bytes are `Bytes`, not
   `String`; they become a `String` only through the E6 UTF-8 gate. The E5 latent `chr`
   item stays unnecessary (no new raw-byte path into `String`).
2. **Region fence extended.** `Region.isStringType` (`src/Wok/IR/Region.hs:512`) already
   routes `TcBytes` to the counted Heap and never the activation arena; the new
   foreign-bytes cell is the same `TcBytes` type, so it inherits the fence. Verify the
   fence covers the adopt path (an escaping adopted `Bytes` routed to an arena would be a
   UAF — the same class E6's review caught).
3. **No double-free / no UAF across the boundary.** The foreign buffer is freed exactly
   once (Haskell-driven drop), the cell header recycled once (`wok_free`), and `wok_free`
   never touches `data_ptr`. Free ordering: foreign free, then cell free.
4. **No C-chase.** `scan=0`; C never follows `data_ptr` as a pointer. Consistent with the
   `c-runtime-data-vs-state-split` convention (this is DATA, freed by a foreign free; the
   handoff does not require codegen).
5. **Allocator-mismatch rule.** An adopted buffer is freed by the *foreign* free
   (libc `free` here), **never** by `wok_free` / the wok slab allocator — the hard
   constraint Rust encodes as "can't `Vec::from_raw_parts` a C-malloc'd buffer."
6. **Reserved-tag exclusion.** `0xFFFB` must be added to the constructor-interning skip
   set (`internTag` in `src/Wok/Interp/RC/Value.hs`, currently skipping
   `0xFFFC`/`0xFFFD`/`0xFFFE`/`0xFFFF` around lines ~1026-1037) and to the reserved-tag
   comment in `runtime/wok_rc.h`. Otherwise a program interning enough constructors could
   be assigned `0xFFFB`, and both the Haskell `dropAddr` and the C `wok_free` tag
   dispatches would misread that `NCon` as a foreign-bytes cell — a silent corruption.

---

## 6. Testing strategy

The differential oracle (reference / RC-abstract / RC-CHeap, output + stats) is the
correctness gate, as in every prior slice.

1. **Differential parity (output + logical stats)** across all three backends for both
   producers feeding `fromBytes` and the existing `length`/`index`/`toBytes`/`eqBytes`
   ops. Copy and adopt produce identical observable bytes and identical logical
   `peak_bytes` (§4.6), so the oracle validates both uniformly.
2. **Off-heap accounting parity.** A test pinning that an adopted `Bytes` of length `n`
   charges and un-charges exactly `wouldBeCBytes(n)`, and that live/peak return to
   baseline after the value dies (no logical leak).
3. **CHeap free-path soundness (the adopt-specific teeth):**
   - ASan/UBSan/LSan across arena / malloc-UAF-oracle / poison-on-free backends, with a
     direct C lifecycle test for `wok_foreign_bytes_alloc` → adopt → drop. Update
     `scripts/asan-runtime.sh` to link any new C (mirror the E6 `wok_utf8.c` lesson —
     a missing link silently darkens the sanitizer gate).
   - A **destructor-runs-exactly-once death test**: instrument the foreign free (a
     counter / a sentinel allocator) and assert it fires once, at refcount-zero, for an
     adopted buffer that is dup'd then dropped; and that a copy-in buffer's source is
     freed by the producer (not by wok's drop).
   - A negative control: forcing the adopt path to skip the foreign free (or to call
     `wok_free` on `data_ptr`) must trip LSan (leak) / ASan (bad free) — proving the
     test has teeth.
4. **Determinism.** The producers fill a fixed pattern so all three backends agree;
   real nondeterministic I/O is a codegen-era integration concern and is excluded here
   precisely because it would blind the oracle.
5. **Corpus.** A `test/rc-ffi-bytes/` directory mirroring `test/rc-bytes/`: copy/adopt
   round-trips through `fromBytes` (valid and invalid UTF-8), length/index on adopted
   buffers, eqBytes across copy vs adopt vs `fromList`, dup/drop balance.

---

## 7. Code touch-points (anchors for the plan)

- C runtime: `runtime/wok_rc.h` (new `WOK_FOREIGN_BYTES_TAG 0xFFFB`, the 3 accessor
  decls, and extend the reserved-tag comment to list five tags); `runtime/wok_rc.c`
  (`wok_foreign_bytes_alloc`, `wok_foreign_bytes_ptr`, `wok_foreign_bytes_len`, and a
  `wok_free` arm for `0xFFFB` that dispatches **before** the arity fallback and recycles a
  fixed 24 B class-2 cell). Keep this in `wok_rc.c` (not a new file) so the existing
  `scripts/asan-runtime.sh` link already covers it; if a new `.c` file is added it MUST be
  added to that script (the E6 `wok_utf8.c` lesson). `runtime/test/*` C lifecycle test.
- FFI bindings: `src/Wok/Interp/RC/Heap.hs` (imports for the three new C functions and a
  `foreign import ccall "free"`; the existing bytes imports are at lines ~55-58).
- RC interpreter: `src/Wok/Interp/RC/Value.hs` (the new `NForeignBytes` node; add `0xFFFB`
  to the `internTag` skip set near the existing reserved-tag guards ~1026-1037 plus a
  `wokForeignBytesTag` constant beside `wokBytesTag`; `alloc`/`allocForeignBytes` charging
  a fixed 24 B; the `dropAddr` arm doing foreign-free-then-`wok_free`);
  `src/Wok/Interp/RC/Prim.hs` (the two producer prims; tag-dispatch the existing Bytes
  byte-accessor), and the reference `src/Wok/Interp/Prim.hs` + `Value.hs` mirror.
- Prim registration: follow the **exact** pattern E6 used for `fromBytes`/`toBytes`
  (names in `src/Wok/IR/PrimNames.hs` if any analysis keys on them, plus the
  `(module, name)` dispatch tables in `Prim.hs`/`RC/Prim.hs`).
- Prelude: extend `prelude/Std/Bytes.wok` with the two `__`-prefixed intrinsic `extern`
  decls (no new module for Slice 1).
- Region: the `TcBytes` fence is at `src/Wok/IR/Region.hs:513-514`; confirm it covers the
  adopt path (an escaping adopted `Bytes` must route to the counted Heap, never the arena).
- Tests: `test/Spec.hs` wiring + `test/rc-ffi-bytes/` corpus + property tests.

---

## 8. Risks and open questions

- **RC node shape.** Whether to add `NForeignBytes` or carry an "adopted" provenance flag
  on `NBytes`. Leaning to a distinct variant for clarity and exhaustiveness checking
  (`-Werror`), but the plan can decide; the invariant in §4.4 is what matters.
- **New prelude module vs extending `Std.Bytes`.** A `Std.Foreign` keeps FFI fixtures
  separate from the pure `Bytes` API; extending `Std.Bytes` is fewer moving parts. Lean
  to extending `Std.Bytes` for Slice 1 (two `__`-prefixed intrinsics), revisit when the
  Slice-2 surface lands.
- **Producer permanence.** The `__ffi_demo_*` prims are transitional fixtures, not a
  durable public API. Mark them clearly; Slice 2 supersedes them.
- **Sanitizer link drift.** E6 already showed a missing `wok_utf8.c` link silently
  darkened the C sanitizer gate; the new C file/functions must be added to every build
  and sanitizer path.

---

## 9. Plan-phase notes (model-tier routing)

- The C runtime cell + drop + accounting and the RC adopt path are **standard**
  (multi-file integration, the genuinely-new design): Sonnet, escalate to frontier if
  the adopt/accounting interplay needs design judgment.
- The producer prims, prim registration, and prelude decls are **mechanical** once the
  runtime exists (complete spec, 1–2 files): Haiku.
- The test corpus + oracle wiring is **standard** (Sonnet); the destructor death-test
  with teeth is the one to review hardest (frontier-reviewed for soundness, per the
  established "run-the-exploit verifier" discipline).
- Per-task spec + code-quality reviewers at the standard tier; the final whole-branch
  deep review at session level (Opus) before any merge, then `/code-review high`.
