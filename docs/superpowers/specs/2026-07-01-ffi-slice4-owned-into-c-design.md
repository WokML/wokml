# FFI Slice 4 — `owned`-INTO-C (transfer-full argument, the move-out)

Status: DESIGNED (2026-07-01). Branches off `feat/ffi-borrow-in` (FFI Slice 3, the borrow
tier, not yet merged to main — this slice sits on the Slice-3 tip). Implements the fourth and
final quadrant of the GObject transfer matrix: handing a wok-owned buffer to a C function that
takes ownership of it. This is the axis orthogonal to the borrow tier — where borrow-in was
**locality** (do not let it escape its scope), this is **uniqueness** (do not touch it after
you give it away).

Links: `ffi-borrow-in-slice3` (the locality axis; the carrier machinery's affine half and the
death-test pattern; the `borrowClose` free technique reused here); `ffi-foreign-module-slice2`
(the `foreign module` surface + the `owned` RETURN disposition this parallels for an argument);
`ffi-bytes-in-slice1` (adopt = the reverse accounting: C-alloc'd / wok-freed); `array-slice-c-inplace-set`
(the runtime rc==1 uniqueness gate reused as the router); `fbip-reuse-slice1` (Perceus
drop-suppression = the move); `region-slice-r1` (the uncounted region arena — the F1
double-move soundness case).

---

## 1. Motivation and goal

The FFI arc has now covered three of the four ownership-transfer quadrants:

| | RETURN (C to wok) | ARGUMENT (wok to C) |
|---|---|---|
| **transfer none** | borrow return (Slice 3, `0xFFFA`) | borrow-out (Slice 2, memchr/strndup args) |
| **transfer full** | adopt return (Slice 1, `0xFFFB`) | **this slice** |

The missing quadrant is **transfer-full argument**: wok hands a C function a buffer wok owns,
and C takes ownership — it frees the buffer, or retains it past the call. After the call wok
must **not** free the buffer (C owns it now; a wok free would be a double-free) and must **not**
read it (C may already have freed it; a read would be a use-after-move). It is a **move /
consume**, not a borrow.

The decisive contrast with the borrow tier, and the reason this is a different design and not a
mirror of it:

- **The borrow tier protected against *escape* (locality).** A borrow is a reference to memory
  wok does not own; the danger is keeping the reference past the point where the owner reclaims
  it. There is no way to "copy your way out" of an escape — a borrow *is* a reference — so the
  borrow tier had to be a **compile-time gate** (the second-class carrier rule).
- **This slice protects against *touching-after-transfer* (uniqueness).** The buffer is wok's
  own owned `Bytes` — copyable data. When the buffer is *shared*, wok can hand C a fresh private
  copy and keep its original. This **copy fallback did not exist for the borrow**, and it is
  exactly what makes a *runtime router* — rather than a compile-time gate — the right mechanism
  (§4).

The Perceus tool for the move is **drop-suppression**: a transfer-full argument leaves wok's
refcount books, so wok must suppress the RC drop it would otherwise perform for that argument
(ownership has left wok).

### The bank-vs-cash framing

Consistent with the whole FFI arc.

- **Banks** (codegen-durable): the move-vs-copy *semantics*, the rc==1 *router*, the
  drop-suppression *contract*, the reverse-of-adopt *accounting*, and the *death-test matrix*.
- **Cash** (native backend): the **off-heap counted `Bytes` representation** (birth the buffer
  in libc `malloc` so a real third-party C `free` reclaims it zero-copy), static uniqueness
  promotion, and native marshalling (§10). The LuaJIT finding still holds: interpreted FFI is
  the slow path even in the reference implementation, so interpreter cycles spent on a sound
  move model cost nothing the asymptotic speed was ever going to keep.

---

## 2. SOTA grounding (surveyed 2026-07-01, primary sources; see §14)

A deep-research pass across GHC, OCaml/OxCaml, Zig, Koka, Rust, GObject, and NumPy converged on
one verdict for a managed runtime with **its own allocator**: **nobody makes third-party C free
the runtime's allocator.** The allocator-provenance constraint ("a buffer must be freed by the
allocator that made it") is solved, ranked by real-world prevalence:

1. **Documented ownership-transfer convention + paired re-adoption, same allocator round-trips.**
   Rust `CString::into_raw`/`from_raw`: the pointer *"must be returned to Rust and reconstituted
   using `from_raw`... one should not use the standard C `free()`"* (misuse risks *"allocator
   corruption"*). CONFIRMED.
2. **Allocate FFI-destined data in a C-compatible allocation from birth; managed heap holds only
   a handle.** GHC pinned `mallocForeignPtr` / `ByteString`; OCaml `Bigarray`; NumPy ndarray
   with a per-array `PyDataMem_Handler` stamping provenance *on the object*. CONFIRMED.
3. **Finalizer that calls the matching allocator, specifically to adopt foreign memory back.**
   GHC `PlainForeignPtr`, OCaml Bigarray `CAML_BA_MANAGED`→`free(data)`. CONFIRMED.
4. **Copy at the boundary** — the universal safe fallback.
5. **Shared/agreed allocator across an ecosystem** — rare, the *one* place raw pointers cross
   and the other side frees them: GObject transfer-full works **because GLib standardizes
   `g_malloc`/`g_free` ecosystem-wide**. CONFIRMED.

**The load-bearing precedent — Koka.** Koka is the one surveyed language in exactly wok's
position (Perceus RC, its own C-backend allocator, compiles to C: *"Lean and Koka use their own
memory allocator for the C backend"*). Its FFI model: values are **borrowed by default**, the C
binding receives an explicit `kk_context_t* ctx`, and the callee **explicitly drops values it is
meant to consume** — `kk_string_drop(x, ctx)`. That is exactly this slice's chosen interpreter
mechanism (§7.4): a runtime-aware consumer, ownership released through the runtime's own free.
Koka does **not** hand a raw RC pointer to a libc-`free`ing third party — because, like wok, its
allocator is not libc. (Confidence caveat: the Koka FFI ownership material is sourced from a
bindings guide, not the canonical spec; the research pass flagged it as the one unverified gap.
It is strongly indicative, and it matches the Perceus paper's own-allocator statement.)

**The verdict for wok:** keep the runtime allocator internal; at the C boundary either copy, or
birth FFI-destined buffers in a C-compatible allocation and expose only a handle plus a
documented transfer convention. This slice does exactly that — modelling the *semantics* now
(§7), deferring the off-heap birth rep to codegen (§10).

---

## 3. The crux: why the runtime rc==1 router, not a compile-time gate

Two mechanisms were weighed:

- **(A) A static affine/consume gate** — the transfer-full argument statically consumes the
  `Bytes`; a compile-time use-after-move check rejects any later use; Perceus statically
  suppresses the drop. A *gate*, like the borrow.
- **(B) A runtime rc==1 router** — reuse the shipped `arrayUnique` / `wok_rc` uniqueness peek
  (Array.set-in-place, FBIP): if the buffer is uniquely owned (rc==1), **move** it (suppress
  wok's drop); if shared (rc>1), **copy** it (hand C a fresh buffer, keep wok's original). A
  *router*, always-sound-by-copy, with no compile-time consume analysis and no use-after-move
  error class.

**Chosen: (B), the runtime rc==1 router.** The reasoning is the *copy-fallback asymmetry*:

- The borrow had **no** copy fallback (a borrow is a reference by nature) → it *had* to be a
  gate.
- A move-out **has** a copy fallback (the buffer is owned, copyable data) → a router is
  available, and it reuses the exact uniqueness machinery already shipped, needs **zero new
  compile-time analysis**, and invents **no new error class** (honoring "no surface lifetimes"
  maximally).

**Why (B) is sound with no gate — the load-bearing argument.** Perceus inserts a `dup` (refcount
bump) before any non-final use of a value. So at the transfer-full call site, the buffer's
runtime refcount is **1 if and only if this is genuinely the last use** (nobody reads it later);
if it *will* be read again, Perceus has already bumped it to ≥2. Therefore:

- rc==1 → move is safe: there is no later wok read to dangle.
- rc>1 → the shared case that would have been a use-after-move is silently, correctly **copied**.

A code-read confirmed there is **no uncounted alias to a native `Bytes`** that could make rc==1
while the buffer is still reachable elsewhere: E4 string views (`0xFFFD`) hold a Haskell-driven
count on their parent (the parent's rc reflects them → rc≥2 → copy); borrow views (`0xFFFA`)
point at *foreign* buffers, never a native `Bytes`; uncounted region/immediate addresses return
`False` from `arrayUnique` → always copy (§7.1). So rc==1 on a native `Bytes` really does mean
unique. (Caveat, pinned in §8: if a future slice ever adds an *uncounted* view over a native
`Bytes`, this guarantee must be re-checked — it is the one assumption the router leans on.)

Machinery confirmation (`src/Wok/IR/Multiplicity.hs`): the affine `cardOf` analysis that (A)
would need is structurally tied to continuation/handler-resume binders and operates over whole
`Expr` spines; it is *not* pointable at a plain `Bytes` value at a specific argument slot
without new machinery. So (A) is genuinely new analysis; (B) reuses a shipped peek. This
confirms the choice from the feasibility side as well as the design side.

---

## 4. Scope

### In scope (Slice 4)

1. **The `owned` transfer-full argument surface** — `owned` on a *parameter* type in a
   `foreign module` member signature (§6.1), a new grammar production (a type modifier), distinct
   from Slice 2's member-leading `owned` return keyword.
2. **The `MoveOut` argument-transfer tag** (§6.2) — the concept is renamed **"transfer"** (not
   "disposition"); `MoveOut` is the new argument-position transfer value, carried in an
   argument-transfer list beside Slice 2's return `bsReturn`/`fmiOwned`.
3. **The runtime rc==1 router** (§7.1) — reuse `arrayUnique`; rc==1 → move (suppress drop);
   rc>1 or uncounted → copy.
4. **Active drop-suppression** (§7.2) — suppress the post-call caller-drop in the move branch
   only; the FBIP/reuse pass treats a `MoveOut` argument as a consuming/terminal use.
5. **The blessed deterministic consume consumer** (§7.4) — a pure-read C checksum function;
   Haskell drives the `wok_free` synchronously after it returns (design (i-b)).
6. **The reverse-of-adopt accounting** (§7.6) — automatic under (i-b); the zero-copy move
   (unique case) pinned as a differential saving.
7. **The test suite** (§9) — a QuickCheck property layer (P1–P7, backend parity / semantic
   correctness / branch-invariance / copy fidelity / accounting balance / zero-copy saving /
   multi-consume, over random `Bytes`) plus the death-test matrix (double-free, use-after-move,
   region-double-move, each mutation-confirmed under `scripts/asan-runtime.sh interp`).

### Out of scope — deferred, recorded as first-class follow-ons

- **The codegen off-heap counted `Bytes` rep** (§10) — birth FFI-destined buffers in libc
  `malloc` so a real third-party C `free` reclaims them zero-copy. The "real" answer for
  arbitrary libc-`free` consumers; codegen-era.
- **Real third-party libc-`free` consumers.** This slice blesses only a wok-runtime-aware
  consumer (freed through `wok_free`); a genuine third-party consumer that frees with libc
  `free` needs the off-heap rep (allocator provenance, §7.3). Deferred with it.
- **Argument transfer-none** — already shipped as borrow-out (Slice 2, memchr/strndup args).
- **All *returns*** — already covered by copy (Tier 1), adopt (Slice 1), and borrow (Slice 3).
  Confirming: transfer-full **argument** is the whole of this slice.
- **A static `@consume`/affine mode over plain `Bytes`** (mechanism A) — the compile-time
  use-after-move gate; a larger generalization, deferred (the router subsumes its safety).
- **`owned`→`borrow` argument sub-moding**, `withForeignBytes`-style explicit scope combinators,
  and `owned`-INTO-C under a handler (inherits the R1 handler-free-modules limit) — later polish.

---

## 5. The model in one walk-through

```
foreign module Sink "c" where
  consume : owned Bytes -> U64 with IO    -- `owned` on the parameter = transfer-full argument

checksumOnce : Bytes -> U64
checksumOnce b = Sink.consume b           -- b is MOVED into C; b is unusable after this point

-- unique (rc==1): b's buffer is handed to C, wok's drop is suppressed, the buffer is freed once.
-- shared (rc>1): C receives a fresh copy; wok keeps b's original and drops it normally.
```

```
-- shared use: b is read again after the consume, so Perceus dup'd it (rc>=2 at the call)
useTwice : Bytes -> U64
useTwice b =
  let h = Sink.consume b in               -- rc>1 -> C gets a COPY, b lives on
  let n = Bytes.length b in               -- SAFE: b's original is intact
  h + n
```

There is **no** compile-time "you used a moved buffer" error: the shared case is silently,
correctly copied. The only observable difference between unique and shared is the zero-copy move
vs the copy — which the differential oracle pins as a real saving (§7.6, §9).

---

## 6. Design overview

The slice threads one new fact — *this argument is transfer-full* — from the surface
(`owned` on a parameter) through the blessed table (`MoveOut`) to the call marshalling (the
rc==1 router + drop-suppression), and provides one blessed consumer plus the accounting and
death-tests. No new type-checker analysis, no new IR pass — the router is a runtime branch on
the shipped `wok_rc` peek.

### 6.1 Surface and grammar

`owned` on a parameter type: `consume : owned Bytes -> U64 with IO`. This is a **new grammar
production** — a type modifier in argument position — distinct from Slice 2's member-leading
`owned` return keyword (`ForeignOwned VarId ForeignSym ":" Type`). (Resolves review finding F6:
parameter-position `owned` is *not* free reuse of the Slice-2 keyword; it needs its own
production + BNFC regen, mirroring how Slice 2's `owned` was added.) The modifier is admitted
**only** inside a `foreign module` member signature and **only** on a `Bytes`-typed parameter
for this slice (a non-`Bytes` `owned` parameter, or `owned` in ordinary wok code, is a clean
error — `owned` is boundary metadata, not linear surface syntax, exactly as in Slice 2).

### 6.2 The `MoveOut` transfer tag

The blessed signature (`src/Wok/FFI/Blessed.hs`) currently carries a return-only
`BlessedSig { bsReturn :: ReturnDisp }`. Extend it with an **argument-transfer list**
(one entry per parameter; the default is the existing borrow-out convention). The new value is
`MoveOut`. `ForeignMemberInfo` (`src/Wok/TypeChecking/Env.hs`, currently `fmiOwned :: Bool` for
the return) gains the parallel per-argument owned marker. The concept is renamed **transfer**
throughout the new code (the shipped `ReturnDisp`/`DispAdopt`/`DispBorrow` names are left
untouched — out of scope, working code).

### 6.3 The blessed member for this slice

`Sink.consume : owned Bytes -> U64 with IO` — the blessed allow-list gains one entry: library
tag `"wok"`, symbol `consume`, argument-transfer `[MoveOut]`, return `DispScalar`. It calls the
deterministic consumer (§7.4). This mirrors Slice 3's `lendBuffer` entry (a `"wok"`-tag blessed
producer), keeping the surface real (a `foreign module` member) rather than a bare prelude
intrinsic.

## 7. Design details

### 7.1 The runtime rc==1 router (resolves F1)

At a `MoveOut` argument, the marshalling peeks the buffer's runtime refcount via the shipped
`arrayUnique` (which reads `wok_rc` for a `CAddr`, or `cRc` for an `HAddr`):

- **rc==1 (unique, counted cell) → MOVE.** Hand C the buffer; suppress wok's post-call drop
  (§7.2); the buffer is freed exactly once (§7.4).
- **rc>1 (shared, counted cell) → COPY.** Allocate a fresh buffer, `memcpy` the bytes into it,
  hand C the copy; wok keeps its original and drops its own reference normally.
- **uncounted address → COPY.** `arrayUnique` returns `False` for `isUncounted` addresses
  (R1-region-allocated values) and for `Inline`/`InlineStr` immediates. These always copy.

**The "arena" disambiguation (the F1 fix).** "Arena" is overloaded in this codebase and the gist
conflated three meanings:

1. **The slab arena allocator** (`runtime/wok_rc.c`) backs *all* counted C cells, including every
   native `WokBytes`. A slab-allocated cell is a normal counted `CAddr` with a live `rc` field —
   `arrayUnique` peeks it and returns **True when unique**. This is the **move-eligible** case,
   **not** a copy case. (The gist's "arena → arrayUnique False" was wrong.)
2. **The R1 region / function-local arena** holds **uncounted** values (`isUncounted`).
   `arrayUnique` returns **False** → **always copy**.
3. **`Inline`/`InlineStr` immediates** (nullary constructors, interned tags) → `arrayUnique`
   **False** → copy. `Bytes` is never an immediate (see F5, §7.4), so this arm is exhaustiveness
   only for the `Bytes` router.

**The region double-move soundness note (the F1 soundness question).** Could a native `Bytes`
that lives in an R1 region be *moved* (rc==1) and then double-freed by the region's `arenaClose`?
No: a region-allocated value is **uncounted** (`isUncounted` True), so `arrayUnique` returns
`False` → the router takes the **copy** branch → C receives a fresh buffer it (Haskell) frees,
and the region's original is freed once by `arenaClose`. The move branch is entered **only** for
counted `CAddr` cells with a live `rc`, which are slab-allocated, not region-allocated. This
invariant — *move fires only for counted cells; uncounted always copies* — is the soundness
floor, and it gets a dedicated region-interaction death-test (§9).

### 7.2 Drop-suppression is active, and the FBIP interaction

> **IMPLEMENTATION REALITY (as shipped, confirmed by the whole-branch review):** the
> "actively suppress a post-call drop" framing below was superseded during implementation.
> There is **no** post-call Perceus drop to suppress: `ownedOccs` counts a foreign-call `Bytes`
> argument as an owned move, and the `Let` rule's `consumedHere` removes it from `delta`, so
> **Perceus emits no `__rc_drop` for the argument** — exactly as the existing `memchr` borrow-out
> arm already relies on. The RC dispatch is therefore the **sole dropper**, and the router simply
> performs the single free itself: MOVE = one `dropAddr b` (rc 1→0, frees once); COPY =
> `allocNBytes` a fresh copy, `dropAddr` the copy, `dropAddr b` (rc>1, decrements, original kept).
> This is sound and needs no suppression pass. The paragraphs below are retained for the design
> rationale; read "suppress the caller-drop" as "the dispatch owns the single free."

The existing **foreign** calling convention is borrow-out (Slice 2, memchr/strndup): the caller
**retains and drops after the call**. A `MoveOut` argument is the opposite and must **actively
suppress** that post-call drop — it is not a no-op:

- **rc==1 / move:** suppress the caller-drop (ownership left wok; the buffer is freed once by
  the consumer path, §7.4).
- **rc>1 / copy:** do **not** suppress — wok did not give away its buffer, it gave a copy, so
  wok drops its own reference normally.

So drop-suppression fires in the move branch **only**. This per-branch asymmetry is the single
most likely site for a double-free (suppress in the wrong branch, or fail to suppress in the
move branch) and gets the hardest review and a dedicated death-test.

**FBIP / reuse interaction (finding F4).** A `MoveOut` argument is a *consuming, terminal* use
of the buffer. The Perceus reuse post-pass (`reusePairing`) must see it as such, or it could
pair a moved-out cell for in-place FBIP reuse → use-after-move. The `MoveOut` argument is modeled
as a consuming use in the reuse/liveness pass.

### 7.3 Representation and the allocator-provenance finding (F1 root, F5)

A native `WokBytes` cell (`0xFFFC`, `runtime/wok_rc.h`) stores its bytes **inline-contiguous**
with the header (`offset 8 byte_len`, `offset 16 bytes[byte_len]`), and the cell is allocated
from **wok's slab arena** (only the `WOK_RC_MALLOC` build routes cells through libc `malloc`).
Two consequences that forbid naively handing C the pointer:

1. The bytes-pointer (`wok_bytes_data`, `cell+16`) is **not an allocation base** — a libc
   `free()` on it is heap corruption.
2. Even the cell base is not libc-malloc'd in the default (arena) build — a libc `free()` is an
   allocator mismatch.

This is why the interpreter frees through **`wok_free`** (design (i-b), §7.4), not libc `free`,
and why a real third-party libc-`free` consumer is deferred to the codegen off-heap rep (§10).

**Empty `Bytes` (finding F5).** `Bytes` is **always a cell**; an empty `Bytes` is a real
`0`-length `CAddr` (a 16-byte header), never an immediate. There is no "inline `Bytes`"
representation. The router treats empty `Bytes` like any other counted cell (move if unique,
copy if shared; the checksum of zero bytes is the FNV seed). The edge-case test targets
**empty (len 0)**, not a nonexistent inline `Bytes`.

### 7.4 The blessed consumer — design (i-b), synchronous free (resolves F3, F4)

The blessed consumer is a wok-runtime-aware C function that is **pure-read**, and the **Haskell
marshalling drives the free synchronously after it returns**:

```c
/* runtime/wok_rc.c: reads the cell's bytes, returns a deterministic checksum. Does NOT free. */
uint64_t wok_bytes_consume_checksum(const WokObj* cell);
```

- The C function reads `wok_bytes_data(cell)` / `wok_bytes_len(cell)` and returns an FNV-1a
  checksum (§7.5). **It does not call `free` or `wok_free`** (finding F4: in the (i-b) era the C
  consumer must not free; only Haskell frees — otherwise it double-frees against the
  Haskell-driven `wok_free`).
- The Haskell marshalling, after the C call returns, drives the buffer's free via `dropAddr` /
  `wok_free` **synchronously at the consume call site**.

**Not the `borrowClose` bracket (finding F3).** Slice 3's `borrowClose` / `KBorrowCloseRC` frees
at **activation exit** (a bracket, because a borrow lives across the body). A `MoveOut` buffer is
consumed **synchronously at the consume call** — C reads, returns, Haskell frees, the prim
returns its `U64`; there is no cross-body lifetime to bracket. This slice reuses the *technique*
(Haskell reads the pointer, then `wok_free`), **not** the activation bracket. The free *timing*
is load-bearing: the §9(a) double-free death-test and the §7.6 accounting balance both depend on
the free happening synchronously at the consume site.

This is the exact Koka `kk_string_drop` model (§2): ownership is released through the runtime's
own free, in runtime-aware code, never by handing a raw wok pointer to a libc-`free`ing third
party.

### 7.5 The deterministic checksum (resolves F2)

The consumer returns a **deterministic checksum** so the program has an observable result and the
three-backend differential oracle stays alive. The algorithm is **FNV-1a over the bytes**
(64-bit: offset basis `0xcbf29ce484222325`, prime `0x100000001b3`), specified once and computed
**identically in all three backends** (finding F2 — the oracle needs a Haskell reference, not
only the C one):

- **RC C-heap backend:** `wok_bytes_consume_checksum` (the C function above) computes FNV-1a over
  the real cell's bytes.
- **RC abstract-heap backend:** a Haskell mirror computes FNV-1a over the `NBytes` node's bytes
  (no real cell exists; there is no real memory to free — the abstract backend models the free
  as the accounting decrement only).
- **Pure interpreter backend:** the same Haskell FNV-1a over the `VBytes`/`ByteString` payload.

All three must return byte-identical checksums for identical input; the shared FNV-1a definition
lives in one place (a Haskell reference + the C mirror) so they cannot drift.

### 7.6 Accounting (reverse of adopt)

Under design (i-b) the free goes through `wok_free`, so the books balance **automatically** with
no new off-book stat:

- The move (rc==1) case: wok allocated the cell (`stAllocs++`, `stCurBytes += size`); the
  consumer path frees it via `wok_free` (`stFrees++`, `stCurBytes -= size`). Perceus's drop is
  suppressed, so the free happens exactly once. Net: balanced, no leak, no double-free.
- The copy (rc>1) case: wok allocates a fresh buffer for C (accounted as the transferred buffer,
  freed via `wok_free` by the consumer path) and keeps + normally drops its original.

This is the **reverse of adopt** (Slice 1: C-alloc'd / wok-freed, the off-heap buffer charged
only as the `0xFFFB` handle). Here the buffer is wok-alloc'd / freed-at-the-C-boundary, and
because the (i-b) free is `wok_free`, it stays *on* wok's books and balances — simpler than
adopt's off-book `stBorrowLentCur` because the (i-b) consumer uses wok's own allocator.

**The zero-copy saving pin (differential, not tautological).** On the C-heap backend, the move
(unique) path copies **0** buffer bytes; the copy (shared) path copies `len`. The oracle pins the
delta via `--dump-rc-stats` / `stPeakBytes`, comparing the two paths on identical data — a
differential saving between unique and shared, not a tautology.

---

## 8. Soundness invariants

1. **rc==1 ⟺ genuinely last use.** By Perceus dup-at-non-last-use; verified no uncounted alias to
   a native `Bytes` exists (§3). *Caveat:* revisit if any future slice adds an uncounted view
   over a native `Bytes` — the one assumption the router leans on.
2. **Move fires only for counted cells; uncounted always copies.** `arrayUnique` returns `False`
   for `isUncounted` (R1-region) and `Inline` addresses → copy. So a region-allocated `Bytes` is
   never moved, and `arenaClose` remains the sole free of the region original — no double-free
   (the F1 soundness note).
3. **Exactly one free per moved buffer.** Drop-suppression in the move branch only (§7.2); the
   consumer path frees once (§7.5). No double-free (never both wok's Perceus drop and the
   consumer free), no use-after-move (rc==1 implies no later read), no leak — except the deferred
   **abort-path leak** (if execution aborts between ownership-release and the consumer free the
   buffer leaks; memory-safe, the same class as the M2b raw-abort leak and the Slice-3 abort
   leak).
4. **The C consumer never frees; only Haskell frees** (the (i-b) contract, §7.4). This is what
   keeps the double-free death-test's window well-defined.
5. **Determinism preserved.** The blessed consumer is deterministic (FNV-1a checksum + a
   deterministic free schedule); the three backends agree on the observable checksum and on the
   logical stats.
6. **Slice-1/2/3 invariants untouched.** `0xFFFB`/`0xFFFC`/`0xFFFD`/`0xFFFA` tag dispatch, the
   adopt/copy/borrow paths, the `extern`/foreign-module gate, and `IO` discharge are unchanged;
   the move-out is a new argument-transfer branch, not a new tag.

---

## 9. Testing strategy

The correctness gate is the three-backend differential oracle (reference / RC-abstract /
RC-CHeap; checksum + logical stats), exercised by **two complementary layers**: **property-based
invariants** over random inputs (QuickCheck, §9.1) and **mutation-confirmed death-tests** under
ASan (§9.2). The two demos — the **owned/move** path (unique buffer, zero-copy) and the **copy**
path (shared buffer, boundary copy) — are the two program *templates* every property runs
against, so the property layer *is* the two-demo validation, generalized from two fixed inputs to
all inputs.

### 9.1 Property-based invariants (QuickCheck)

**Generator + mechanism.** `genBytes :: Gen [Word8]` — arbitrary byte lists with a `resize`d
length spanning empty (len 0), small, and large (multi-KB) buffers. `Test.QuickCheck.Monadic`
(`monadicIO`) drives the real C calls on the CHeap backend; `tasty-quickcheck` is the runner
(matching the repo's tasty + QuickCheck convention). The consumer is deterministic (FNV-1a +
deterministic free), so the properties are **reproducible — no flakiness**; and QuickCheck
**shrinking** minimizes any failing byte-pattern/length, which is exactly what a memory bug
needs.

**The two templates.** For each generated `bs`, the suite builds two wok programs — the
**unique/move** template `consume (mkBytes bs)` (the buffer's only use → rc==1 → move) and the
**shared/copy** template `let b = mkBytes bs in (consume b, Bytes.length b)` (b reused → rc≥2 →
copy) — and asserts:

- **P1 — backend parity.** `consume`'s checksum is identical across pure-interp, abstract-heap,
  and CHeap. (The oracle core.)
- **P2 — semantic correctness.** The checksum equals `referenceFNV1a bs` (a pure Haskell
  reference) — the backends agree on the *right* value, not merely with each other.
- **P3 — router branch-invariance.** The unique (move) and shared (copy) templates produce the
  *same* checksum: the router's branch never changes the observable result.
- **P4 — copy fidelity + non-interference (shared).** In the shared template the original `b`
  still reads as `bs` after the consume (the move/copy did not disturb it), and C's copy checksums
  equal the original.
- **P5 — accounting balance (no leak, no double-free).** After each template, `stAllocs ==
  stFrees` and `stLive == 0` on the abstract and CHeap backends; every allocated buffer (the
  original, and in the shared case the boundary copy) is freed exactly once.
- **P6 — zero-copy saving (differential).** The unique template charges `bytes-copied == 0`; the
  shared template charges `bytes-copied == length bs`. (The saving pin, generalized to hold over
  all inputs, not one fixed case.)
- **P7 — multi-consume.** For a generated arity `n`, consuming `b` into `n` `owned` arguments
  yields `n` independent copies, all freed, all checksums `== referenceFNV1a bs`; accounting
  balances.

These properties cover the whole move-out scope over random inputs. The same parity/accounting
property *shape* generalizes to the adopt/borrow/copy paths — a hook for a future FFI-wide
property suite (noted, not built here).

### 9.2 The death-test matrix (mutation-confirmed, ASan) — the load-bearing gate

The negative controls stay **targeted** (a mutation must *bite*, which is example-shaped, not
property-shaped), each run under `scripts/asan-runtime.sh interp` (GHC-under-ASan with
`WOK_RC_MALLOC`, so `wok_free` is libc `free`), over a small representative sample of `bs`
**including one random draw** so it is not a hard-coded special case:

- **Double-free:** mutate the router to *keep* wok's Perceus drop on an rc==1 move → wok
  `wok_free`s + the consumer path `wok_free`s the same cell → ASan double-free. Unmutated: clean.
- **Use-after-move:** mutate the router to *force move even when rc>1* (disable the copy branch),
  share the buffer, and read it **via a C read that is ASan-instrumented** (a C `memchr`/checksum
  over the buffer — **not** `peekElemOff`, which is not instrumented; the Slice-3 lesson) after
  the consumer free → ASan use-after-free. Unmutated: copies, clean.
- **Region double-move (the F1 case):** a `MoveOut` on a `Bytes` reachable through an R1 region;
  unmutated copies (uncounted → copy) so `arenaClose` is the sole free; mutate to force the move →
  ASan double-free, proving the uncounted→copy guard is load-bearing.

A vacuous control (a "move" that still reads live memory, or a read that is not ASan-instrumented)
is itself a test bug.

### 9.3 Corpus and wiring

`test/rc-ffi-owned/` mirroring `test/rc-ffi-foreign/` and `test/rc-ffi-borrow/`: the property
suite (§9.1), the death-test matrix (§9.2), and the two named example demos
(`consumeOwned`/`consumeShared`) kept as readable, fixed-input documentation of the two paths.
`test/Spec.hs` wiring; `scripts/asan-runtime.sh` link updated for the new C
(`wok_bytes_consume_checksum`).

---

## 10. Codegen / future direction (the "cash")

The interpreter slice banks the *semantics*; the native backend delivers the optimal, real
third-party version. One insight reshapes it and makes wok's story simpler than GHC's or
OCaml's:

**wok is RC, so the only cross-boundary problem is free-provenance, not address-stability.** GHC
and OCaml need pinning because their GC *moves* objects; wok's Perceus RC never relocates a live
cell, so a wok buffer already has a stable address (the Koka/Lean posture). Therefore:

- **Borrow-out (transfer-none, C reads during the call)** needs nothing special even at codegen —
  hand C the raw arena pointer for the call duration; RC keeps it alive; no pinning, no copy.
  (This is why Slice-2 borrow-out was easy, and it stays easy.)
- **Transfer-full out (C frees)** breaks *only* on free-provenance (C's `free` cannot reclaim a
  wok-arena buffer). This narrows the entire codegen design to "make the buffer freeable by the
  consumer's allocator."

**The codegen rep: one off-heap counted `Bytes`, serving two jobs.** A small wok-counted handle
whose payload lives in a **C-compatible allocation (libc `malloc`) from birth** — a
generalization of the existing adopt cell (`WokForeignBytes` `0xFFFB`, already "a counted handle
over a separate libc buffer"). It serves both:

1. **Transfer-full out:** hand C the raw payload pointer → C frees with libc `free` (provenance
   matches) → wok frees only the small handle. Zero-copy, no context API, works with *arbitrary*
   third-party C. (The GHC-`ByteString` / OCaml-`Bigarray` / NumPy-ndarray pattern.)
2. **Numeric/IO zero-copy:** the same off-heap buffer is what you pass to BLAS/LAPACK or a bulk
   `read`/`write` with no copy — wok holds the handle, the payload is a stable libc buffer.

**The mechanism at codegen: move-out is a calling convention, not new machinery.** Perceus
already places drops statically; a transfer-full argument selects the **owned/consumed calling
convention** for that argument ("the callee is responsible for release"), reinterpreted as "C
frees the raw buffer." Drop-suppression becomes simply "don't emit the decref." The rc==1 router
stays a cheap runtime peek (as `Array.set`/FBIP do at codegen), promoted to an unconditional move
where the uniqueness is provable statically (the cash optimization).

**Provenance matching.** The consumer's allocator is already declared on the surface — Slice 2's
`free "sym"` clause names *which* deallocator (`free`, `g_free`, …). The off-heap handle carries
the matching provenance for its payload (or standardizes on libc for the common case); move-out
marshalling hands the raw pointer on a match, copies into the consumer's allocator on a mismatch
(the NumPy NEP-49 provenance-on-object model, generalized to multiple allocators like GLib's
`g_free`).

**This retires the (i-b) `wok_free` path** for real third-party C: once the off-heap rep births
FFI-destined buffers in libc `malloc`, third-party C frees them directly with `free()` — no
`wok_free`, no heap handle, no blessed-runtime shim. The **blessed allow-list stays** as the
capability/trust anchor (which symbols may be called); only the allocator-coupling disappears.

Everything the interpreter slice banks — the router, the move-vs-copy semantics, the
drop-suppression contract, the reverse-of-adopt accounting, the death-test matrix — carries
forward unchanged; codegen only adds the off-heap rep, static uniqueness, and native marshalling.

---

## 11. Code touch-points (anchors for the plan)

- **Grammar/surface:** the `owned`-on-a-parameter production (a type modifier admitted only in a
  `foreign module` member signature) + BNFC regen; the parser/AST carry the per-parameter owned
  marker. (`grammar/*.cf`, `src/Wok/Syntax/*`, `src/Wok/TypeChecking/Infer.hs`.)
- **Blessed table:** `src/Wok/FFI/Blessed.hs` — extend `BlessedSig` with an argument-transfer
  list; add the `MoveOut` value and the `Sink.consume` entry.
- **Foreign member info:** `src/Wok/TypeChecking/Env.hs` — `ForeignMemberInfo` gains the
  per-argument owned marker beside `fmiOwned`.
- **Router + drop-suppression + accounting:** `src/Wok/Interp/RC/Value.hs` — reuse `arrayUnique`;
  the move/copy branch; suppress the caller-drop in the move branch; the synchronous
  `dropAddr`/`wok_free`; the reuse-pass consuming-use for `MoveOut`.
- **Consumer binding:** `src/Wok/Interp/RC/Prim.hs` — the `Sink.consume` host binding (C-heap
  arm calls `wok_bytes_consume_checksum` then drives the free; abstract arm computes the Haskell
  FNV-1a and models the free as the accounting decrement).
- **The checksum:** `runtime/wok_rc.c` + `runtime/wok_rc.h` — `wok_bytes_consume_checksum`
  (pure-read FNV-1a; does not free); the shared FNV-1a Haskell reference.
- **Tests:** `test/Spec.hs` wiring + `test/rc-ffi-owned/` corpus + the QuickCheck property suite
  (`genBytes`, `referenceFNV1a`, `tasty-quickcheck` + `monadicIO`) + the death-test matrix;
  `scripts/asan-runtime.sh` link update for the new C.

---

## 12. Risks and open questions

- **Per-branch drop-suppression correctness (the double-free site, the main risk).** Suppress in
  the move branch only; do not suppress in the copy branch. The hardest review; a dedicated
  death-test.
- **FBIP consuming-use integration.** The reuse pass must treat a `MoveOut` argument as terminal,
  or it double-uses a moved cell. Testable; reviewed against `reusePairing`.
- **The rc==1 caveat.** Sound *given* no uncounted alias to a native `Bytes` (§8.1); a future
  uncounted-view-over-`Bytes` slice must re-check this.
- **Region double-move (F1).** The uncounted→copy guard is the soundness floor for the R1
  interaction; a dedicated death-test proves it load-bearing.
- **Abstract-backend free modeling.** No real memory to free; the abstract arm models the free as
  the accounting decrement only, while the checksum is a real FNV-1a over the `NBytes` bytes —
  confirm parity with the C arm.
- **Grammar for `owned` on a parameter.** A new production; confirm it does not collide with the
  member-leading Slice-2 `owned` (position and context disambiguate: parameter-type modifier vs
  member-leading keyword).

---

## 13. Plan-phase notes (model-tier routing)

- **The `owned`-on-a-parameter grammar + BNFC regen + the `MoveOut` tag / blessed-table
  extension** is **standard** (mirrors Slice 2's `owned` production; mechanical once the
  production shape is fixed): Sonnet.
- **The rc==1 router + active drop-suppression + the FBIP consuming-use** is **frontier** — the
  soundness-critical, run-the-exploit piece (the double-free and region-double-move sites);
  inherit the session model (Opus).
- **The blessed consumer (`wok_bytes_consume_checksum`) + the FNV-1a Haskell reference + prim
  binding + prelude wiring** is **mechanical** once the design exists: Haiku.
- **The accounting + the QuickCheck property suite (§9.1) + the death-test matrix + oracle
  wiring** is **standard** (Sonnet); the property invariants (P1–P7) and the double-free,
  use-after-move, and region-double-move controls reviewed hardest.
- Per-task spec + code-quality reviewers at the standard tier; the final whole-branch deep review
  at session level (Opus) before any merge — the router soundness and the death-test matrix are
  the load-bearing gates — then `/code-review high`. No merge to main without the user's
  full-branch review (`review-before-merge`).

---

## 14. References (primary sources, surveyed 2026-07-01)

- **Rust FFI ownership:** [`CString`](https://doc.rust-lang.org/std/ffi/struct.CString.html)
  (`into_raw`/`from_raw`, "do not use the standard C `free()`", "allocator corruption");
  [Rustonomicon FFI](https://doc.rust-lang.org/nomicon/ffi.html). The re-adoption convention
  (answer (d)).
- **GObject/GLib transfer:**
  [GI annotations](https://gi.readthedocs.io/en/latest/annotations/giannotations.html)
  (transfer none/container/full);
  [Apertis memory management](https://www.apertis.org/guides/app_devel/memory_management/)
  (one owner, transferable). Works because GLib standardizes `g_malloc`/`g_free` — the one
  shared-allocator ecosystem.
- **GHC:** [GHC.ForeignPtr](https://hackage.haskell.org/package/base/docs/GHC-ForeignPtr.html)
  (`mallocForeignPtr` pinned, no finalizer; `PlainForeignPtr` finalizer for adopting foreign
  malloc); [bytestring](https://hackage-content.haskell.org/package/bytestring-0.12.2.0/docs/src/Data.ByteString.html)
  (pinned, FFI-ready); [GHC FFI users guide](https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/ffi.html)
  (`keepAlive#` across a syscall).
- **OCaml:** [Bigarray flags](https://github.com/ocaml/ocaml/blob/trunk/runtime/caml/bigarray.h)
  (`CAML_BA_MANAGED`/`CAML_BA_EXTERNAL`); [manual: custom blocks/finalizers](https://ocaml.org/manual/5.4/intfc.html);
  [caml_alloc_custom_mem PR](https://github.com/ocaml/ocaml/pull/1738).
- **OxCaml:** [stack allocation](https://oxcaml.org/documentation/stack-allocation/intro/)
  (`local` = compile-time escape gate); [Oxidizing OCaml: Locality](https://blog.janestreet.com/oxidizing-ocaml-locality/).
- **Koka (the load-bearing precedent):**
  [C bindings guide (Discussion #113)](https://github.com/koka-lang/koka/discussions/113)
  (`kk_context_t* ctx`, borrowed-by-default, `kk_string_drop`, `kk_string_cbuf_borrow` — the
  (i-b) model; confidence: bindings guide, not the canonical spec); the Perceus papers
  ([Perceus](https://xnning.github.io/papers/perceus.pdf),
  [TR](https://www.microsoft.com/en-us/research/uploads/prod/2020/11/perceus-tr-v1.pdf))
  ("Lean and Koka use their own memory allocator for the C backend").
- **NumPy:** [NEP-49](https://numpy.org/neps/nep-0049.html),
  [data memory](https://numpy.org/doc/stable/reference/c-api/data_memory.html) — per-array
  `PyDataMem_Handler`, provenance stamped on the object.
