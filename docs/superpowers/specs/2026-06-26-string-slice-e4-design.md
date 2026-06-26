# String Slice E4: zero-copy slices + borrow-passing — Design Spec

**Date:** 2026-06-26
**Status:** Approved for planning (brainstorm converged 2026-06-26; alignment review passed — every code reference confirmed real, the C-cascade story corrected from a non-existent `scan` path to the established Haskell-driven `WokArray` pattern, the windowing relocated from `deref` to the prim layer).
**Predecessor:** String Slice E3 (`2026-06-26-string-slice-e3-design.md`, the small-string-optimization inline-`InlineStr` layer this builds on). E1 (`WokString` C cell) and E2 (StringZilla byte-ops) underneath.
**Companions:** `docs/string-memory-layout.html` (the current cell layout), `docs/beating-the-c-stack.html` (the allocation-tier ladder this slice adds a rung to), `docs/borrowership-granularity.html` (the borrow ladder L2→L6 this slice advances to L5).

---

## 0. Scope rename

The original "E4 = views + Unicode" (named out-of-scope in the E3 spec §1) is **split into three independent slices**:

- **E4 (this spec) = zero-copy slices + borrow-passing.** The string-view value model and the L5 borrow rung.
- **E5 = the fusable iterator pipeline** (`chars`/`bytes`/`split`/`map`/`filter` over the existing `Std.Control` `Step`/`Coro` machinery; stream fusion deferred to codegen). The codepoint-iteration layer (`chars`/`foldChars`) deferred since E1 lands here.
- **E6 = table-driven Unicode** (case folding, normalization, grapheme clusters).

They are separable; this slice deliberately keeps the memory-safety mechanism isolated so it gets the full review budget alone.

---

## 1. Goal & scope

Give wok a **zero-copy substring**: `slice s a b` produces a `String` that is an offset+length **window into `s`'s existing byte buffer**, sharing the parent's lifetime instead of copying the bytes. This is the L5 "borrow-passing" rung of the borrowership ladder — and the load-bearing idea is that **borrow-vs-own is a runtime *representation* the compiler routes to by escape analysis, never a surface-language type or lifetime annotation.**

**In scope (E4):**
- Two prims: `slice : String -> U64 -> U64 -> String` (codepoint-indexed) and `byteSlice : String -> U64 -> U64 -> String` (byte-indexed). `take`/`drop` as wok library functions over `slice`.
- A new isolated abstract node `NStringView !Addr !Int !Int` (parent address, **byte** offset, **byte** length) and a paired C cell `WokStringView` (tag `WOK_STRING_VIEW_TAG`).
- The **routing**: `SliceRep = Window | Counted | Copy`, decided per allocation-binder by reusing `Wok.IR.Escape`/`Wok.IR.Region` (the same per-`let`-binder analysis that routes `Arena | Heap`).
- The **interpreter-soundness invariant**: the interpreter realizes both `Window` and `Counted` as a **counted** window (always increfs the parent), so a routing bug can never produce a use-after-free at runtime. The interpreter cashes the **no-copy** win; the **no-refcount** win is codegen-era.
- The exhaustive set of `Node`-/`Addr`-matching arms a new node constructor forces under `-Werror`.
- A **five-layer soundness test suite** (death-test build with teeth + negative control; independent routing oracle; the 3-way differential oracle on output + exact counts + leak balance; QuickCheck properties incl. borrow-out survival and nested-flatten; hand-written adversarial UAF-exploit programs).

**Out of scope (boundary made explicit):**
- **The fusable iterator pipeline and stream fusion** → E5. Fusion is a compile-time code-generation transformation; wok's IR has analysis passes only (no optimizer/inliner/rewrite pass), so fusion has nothing to fire in yet. The `Step`/`Coro` representation it would reuse already exists in `prelude/Std/Control.wok`.
- **Table-driven Unicode** (case/normalize/grapheme) → E6.
- **Truly-zero-cost (no-refcount) windows** → codegen-era. At codegen a view becomes a fat pointer (`ptr + offset + len` in registers/stack); the interpreter measures the proxy (no new byte buffer allocated).
- **Array views.** `Array` mutates in place under `rc==1`; a borrowed window into a mutable buffer must coordinate with that in-place `set`, which strings sidestep by being immutable. Generalizing the view node to arrays is deferred until a real second consumer earns it (the borrow *routing* is already general, so that is a cheap future move).

---

## 2. Background — where E3 left things, and the borrow ladder

A `String` value is **one machine word** that is one of three things, all read through a single funnel (`stringBytes → deref → bytes`, `Prim.hs:707`):
- an **`InlineStr !ByteString`** (E3): ≤ 7 UTF-8 bytes packed in the word, no heap, uncounted (`Value.hs:162`).
- a **`CAddr`/`HAddr`** pointing at a **`WokString`** cell (E1): a 16-byte header (`rc`/`tag`/`reserved`/`scan`/`byte_len`) followed by inline packed bytes, tag `WOK_STRING_TAG = 0xFFFE` (`wok_rc.h:97-111`). Mirrored abstractly as `NString ByteString` (`Value.hs:657`).

Because every op reads bytes through `stringBytes`, each new representation (E1 cell, E3 inline) "just worked" on `length`/`index`/`byteAt`/`append`/`eqString`/`hash`/`editDistance` with no per-op change. E4 adds a fourth representation — the **view** — and preserves that property.

**The borrowership ladder** (`docs/borrowership-granularity.html`): L2 = coarse second-class-by-default; R1 (L3→L4) = inferred function-local arenas (Go-style escape analysis, `Region.hs`); **L5 = borrow-passing (this slice)**; L6 = lifetimes-in-types (**rejected** — keeps lifetimes out of the surface). Strings are the right place to land L5 because **strings are immutable** (`append` allocates fresh; there is no in-place string mutation), which deletes the mutable-aliasing problem that forces Rust's `&mut`/`&` exclusion and surface lifetimes: a window into an immutable buffer is valid for exactly as long as the buffer is alive, and "alive" is precisely what the reference count guarantees.

---

## 3. Decisions (converged in brainstorm 2026-06-26, corrections from alignment review folded in)

**D1 — Router, not gate.** Borrow is a runtime *representation* routed by escape analysis, not a surface type. `SliceRep = Window | Counted | Copy`. Rust's borrow checker is a *gate* (it rejects programs it cannot prove safe, which forces lifetimes onto the surface); wok's is a *router* (it degrades the representation to a refcount, or a copy, when it cannot prove static safety). The conservative answers (`Counted`/`Copy`) are **always safe**, exactly mirroring `Region.hs`'s rule that `Heap` is always safe and over-tagging `Arena` is the only unsafe direction (`Region.hs:14-19`). No surface-language change; the type of a slice is always plain `String`.

**D2 — The interpreter always counts.** In the interpreter era (all we can run today) **both `Window` and `Counted` are realized as a counted window** — the `slice`/`byteSlice` prim *always* `incref`s the parent. Consequence: a routing bug can never cause a use-after-free at runtime, because nothing is ever actually uncounted. The interpreter cashes the **no-copy** win (a window allocates a fixed-size 32-byte view cell and zero new byte buffer, versus `Copy`'s `16 + N` byte cell + memcpy); the **no-refcount** win (dropping even the `incref`/`drop`) is codegen-era. This is the E3 "bank the value-model now, cash the speed at codegen" pattern. The `Window` rep exists in the routing plan and is exercised *only* by the death-test build (§8 layer 1).

**D3 — Isolated `NStringView` node; general routing.** Add a dedicated abstract node `NStringView !Addr !Int !Int` (parent addr, byte offset, byte len) — chosen for **isolation/safety over conceptual minimalism**, so that `-Werror`'s exhaustiveness check forces every `Node`-matching site to handle the view explicitly, and the view never leaks into generic `NCon` machinery (FBIP reuse, slot encoding, match). The borrow *routing* (`SliceRep`) lives generally in `Escape`/`Region` and is reusable for any future consumer; **no general buffer-view node** is introduced (YAGNI; array views deferred). The view is **counted, not uncounted** (unlike `InlineStr`): `nodeValues (NStringView p _ _) = [RVBox p]`, so the **generic** `cascadeChildren = countedRefs . nodeValues` (`Value.hs:2153`) yields `[p]` and a drop of the view decrefs the parent — no special `cascadeChildren` arm needed.

**D4 — Windowing lives at the prim layer, not `deref`.** `NStringView` is a *cell* (a `Node`), not an `Addr` variant like `InlineStr`. `deref` returns the `NStringView` node unchanged; the windowing happens in **`stringBytes`** (`Prim.hs:707`), which gains an arm: `NStringView` → read the parent's bytes (deref parent → `NString parentBytes`) → `BS.take len (BS.drop off parentBytes)`. `ByteString` slicing is **O(1)** (it adjusts offset/length over the shared buffer — no copy), so this preserves zero-copy. Putting the windowing in `deref` instead would synthesize a fresh sub-`ByteString` on *every* deref, defeating the goal. Every other string op reaches bytes through `stringBytes`, so all of `length`/`index`/`byteAt`/`append`/`eqString`/`indexOfFromRaw`/`hash`/`editDistance` work on a view unchanged.

**D5 — Surface and semantics.**
- `slice s start len` — **codepoint-indexed**. Locating the byte boundaries requires decoding UTF-8 up to `start` and `start+len` codepoints (O(n)); the resulting window is zero-copy. **Saturating bounds** (total, never errors on range): `start' = min(start, codepointLen)`, `end' = min(start+len, codepointLen)`; an empty result if `start ≥ codepointLen`. Always UTF-8-valid by construction (boundaries fall on codepoint edges).
- `byteSlice s start len` — **byte-indexed**, O(1) to locate. **Saturating bounds** on `[0, byteLen]`, then a **validity check**: the window's start and end must each fall on a UTF-8 codepoint boundary (the byte at each is not a continuation byte `0x80..0xBF`). If either splits a multibyte codepoint → **`PrimError`** (a loud error, never a silent snap — a snap would violate the `NString` valid-UTF-8 invariant, `Value.hs:658`).
- `take`/`drop` — wok library functions over `slice` in `Std.String`. No new prims.
- Rationale for saturating slices vs erroring point-access (`index`/`byteAt` error out-of-bounds, `rc-string-oob/`): a range has a sensible clamp, a point access does not.

**D6 — Representation decision procedure (where the corner cases live).**
```
slice/byteSlice produces window bytes wb (an O(1) BS slice of the parent bytes):
  | BS.length wb <= maxInlineStr (7)  -> InlineStr wb        -- 0 cells, ALWAYS (cheapest), regardless of escape
  | parent is InlineStr               -> InlineStr wb        -- a <=7-byte parent yields a <=7-byte window; falls in the line above
  | otherwise (parent is a counted cell, window > 7 bytes):
      let p = the parent Addr; off,len = byte offset/length
      case sliceRep(binder) of
        Window  -> NStringView p off len ; incref p   -- interpreter realizes as Counted (D2)
        Counted -> NStringView p off len ; incref p
        Copy    -> alloc (NString wb)                  -- independent copy; used when p cannot be referenced
```
- **Slice of an `InlineStr`** can never be an `NStringView` (no counted cell to reference) — its window is ≤ 7 bytes, so it is always another `InlineStr`. Explicit.
- **Flatten-on-construction is a CORRECTNESS requirement, not an optimization.** A view always points at the **root** buffer, never at another view: `slice (NStringView root o l) c d` produces `NStringView root (o+c) d`. A non-flattened chain (view → view → root) can dangle the root if the middle view's count reaches zero before the outer's. Pinned by a dedicated test (§8).
- **`Copy` fallback** is the unconditionally-safe answer for the case where the parent cannot be reference-counted — e.g. an arena-born (uncounted) parent that the view outlives. **Task-4 finding (a strengthening):** this case is in fact *structurally unreachable* through `planRegions` — a slice's parent appears as a (non-head) argument of the slice call, which is an escaping position, so the region analysis always routes the parent `Heap`/counted, never `Arena` (the string-binder fence forces the same independently). Hence `parentArena` is always `False` and `Copy` never fires in the current pipeline: **a view's parent is always counted, so every view is `Window` or `Counted` — both zero-copy.** `Copy` is retained as a documented, directly-unit-tested safe fallback for codegen / a future borrowing prim, not guarded away (the E1–E3 document-don't-guard convention).

**D7 — Strings-first because immutable.** (See §2.) Array views explicitly not generalized.

**D8 — The C drop is Haskell-driven (correction).** The `scan` field in the C header is **reserved and never read** — there is no working C-side cascade (`wok_rc.h:22-26`; `wok_free` does no child iteration, `wok_rc.c:271-289`). `WokStringView`'s parent-drop therefore follows the **established `WokArray` pattern**: `dropAddr`'s `CAddr` branch (`Value.hs:1969`) reads the view cell's parent-pointer slot Haskell-side, decrefs the parent (recursively via `dropAddr`), then computes the cell's byte size and calls `wok_free`. `scan` stays `0`. This is **not new C infrastructure** — it mirrors how `WokArray` (also `scan=0`) drops its elements.

---

## 4. Architecture / touch-points

Adding `NStringView` to `Node` makes every `Node`-matching function non-exhaustive; `-Werror` + `-Wincomplete-patterns` makes each a **compile-enforced** edit.

### 4.1 `src/Wok/Interp/RC/Value.hs` — the node, its arms, alloc & drop

**Core (new behaviour):**
- `data Node = … | NStringView !Addr !Int !Int` (`:643` region; parent addr, byte offset, byte len).
- `nodeValues (NStringView p _ _) = [RVBox p]` (`:2127`) — the parent is the one counted child; the generic `cascadeChildren` (`:2153`) then drops it. **No special `cascadeChildren` arm.**
- `allocNStringView` — a dedicated alloc path beside `allocNString`/`allocNArray` (`:1580`/`:1607`): `CHeap` → `wok_string_view_alloc(parentPtr, off, len)` (FFI), increfs parent; `AbstractHeap` → `allocPure (NStringView …)`. The `slice` prim calls this (it is not reached via `alloc (NString …)`).
- `deref`/`derefPure` (`:1790`/`:1888`): an `NStringView` lives in a cell reached via `HAddr`/`CAddr`; these return the cell whose `cNode` is the `NStringView` **unchanged** (windowing is the prim layer's job, D4). The `CAddr` case must read the view cell's three fields from C memory.
- `dropAddr` `CAddr` dispatch (`:1969-2000`): a **third tag branch** after `wokArrayTag`/`wokStringTag` for `WOK_STRING_VIEW_TAG` — read parent pointer slot, `dropAddr` the parent, compute the 32-byte cell size, `wok_free`.

**No-op / error / classification arms (mirror the nearest existing arm):**
- `isUncounted` / `isInline` (`:1157`/`:1138`): `NStringView` is **counted** → not added to either (a view participates in dup/drop). (`isInline` is `Addr`-keyed; `NStringView` is a `Node`, so no arm there — noted to avoid confusion.)
- `nodeCEligible (NStringView …) = False` (`:1662`) — has its own dedicated alloc path (like `NString`).
- `wouldBeCBytes (NStringView …)` (`:1684`) — the view cell's byte size: header 8B + parent-ptr 8B + offset 8B + len 8B = **32B fixed**.
- `valueChildren` needs no change (`RVBox a → [a]`); a view *cell* is referenced by an `RVBox` like any boxed value.

**The C cell** (`runtime/wok_rc.{c,h}`):
- `WOK_STRING_VIEW_TAG` (a new reserved tag beside `0xFFFE`).
- Layout: 8-byte header (`rc`/`tag`/`reserved`/`scan=0`) + `parent` pointer (8B) + `offset` (8B) + `len` (8B) = 32B.
- `wok_string_view_alloc(WokHeap*, WokObj* parent, uint64 off, uint64 len)` (malloc + arena backends, mirroring `wok_string_alloc` at `:712`/`:417`), and accessors `wok_string_view_parent`/`_offset`/`_len`.
- `wok_free` (`:271`) gains a `WOK_STRING_VIEW_TAG` size arm (fixed 32B). It does **not** drop the parent (that is Haskell-driven, D8).

### 4.2 `src/Wok/IR/Escape.hs` + `src/Wok/IR/Region.hs` — the routing

- The routing is **per-`let`-binder**, the same granularity as `Region.hs` (it answers "does this binder escape its activation?", not a new per-call-site analysis). A `let v = slice s i j in …` binder is classified by the existing `arenaEscapes`/`escapesFrom` (`Escape.hs:528`/`:498`): does-not-escape → `Window`-eligible; escapes → `Counted`.
- Concretely: add `SliceRep = Window | Counted | Copy` and surface it in the `RegionPlan` (mirroring `Placement = Arena | Heap`, `Region.hs:49`) keyed by the view binder's `Unique`. A `Window` requires the binder to be `Arena`-eligible (non-escaping) **and** the parent to be referenceable; otherwise `Counted`; `Copy` only when the parent is unreferenceable.
- This is a **new consumer** of the existing escape analysis, not a change to its granularity. `Escape.hs` stays the single source of truth.

### 4.3 `src/Wok/Interp/RC/Prim.hs` — the prims

- `stringBytes` (`:707`) gains the `NStringView` arm (D4): deref parent → `NString pb` → `BS.take len (BS.drop off pb)`.
- New `stringSlice` (codepoint) and `stringByteSlice` (byte) prims, registered in `rcStringPrims` (`:97`). Each: read the parent via `stringBytes` (for `slice`, decode UTF-8 to map codepoint indices → byte offsets); compute the window; run the D6 decision procedure; `incref` the parent on the `NStringView` path; drop the input string address per the standard prim convention.
- `stringByteAt`'s `CAddr` fast-path (`:782`) must be `WokString`-only. **Task-6 finding (a real bug + fix):** a view *cell* on the CHeap is itself a `CAddr` (to a `WokStringView`, tag `0xFFFD`), so it DID match the bare `CAddr p` fast-path and got read via `wokStringLen`/`wokStringByteGet` as if it were a `WokString` (tag `0xFFFE`, different layout) — a silent wrong-answer / over-read. The original spec's "an `NStringView` does not match `CAddr`-with-string-tag" was aspirational; Task 3 matched a bare `CAddr` without the tag check. **Fix:** the fast-path now reads the cell tag and only fires when it is `wokStringTag`; a `WokStringView` (or any other tag) falls through to `stringByteAtViaBytes` (`stringBytes → deref → window → BS.index`), which handles views correctly. Any sibling prim with a `CAddr`-`WokString` fast-path is tag-guarded the same way. (An `InlineStr` is an in-word `Addr`, never a `CAddr`, so it was never affected.)
- `eqString` (`:818`), `stringAppend` (`:803`), `stringLength`/`stringIndex` (`:727`): unchanged — all reach bytes via `stringBytes`, which now handles views.

### 4.4 `prelude/Std/String.wok`
- `extern slice : String -> U64 -> U64 -> String` and `extern byteSlice : String -> U64 -> U64 -> String` (after `editDistance`, `:25`).
- `take s n = slice s 0 n` and `drop s n = slice s n (length s)` (library functions, dogfooding `slice`).

### 4.5 `src/Wok/Interp/RC/Machine.hs` — the death-test hook
- A build-flagged mode (the sanitizer/test build) in which `Window`-routed slices are realized **genuinely uncounted** (no parent `incref`) and a read of a view whose parent has been freed trips a runtime invariant (§8 layer 1). The release/normal path always counts (D2).

### 4.6 What explicitly does NOT change
`Reachable`/`ReusePairing`/`Multiplicity`/`Perceus` (a view is an ordinary counted boxed value to them; its single counted child flows through the existing `nodeValues`/`countedRefs` machinery), `isBoxedType (TcString)` (already `True`, E1), `wok_free`'s parent-drop (Haskell-driven), and the bodies of every existing string op.

---

## 5. The surface

| Function | Type | Semantics |
|---|---|---|
| `slice` | `String -> U64 -> U64 -> String` | codepoint window `[start, start+len)`, saturating bounds, always UTF-8-valid |
| `byteSlice` | `String -> U64 -> U64 -> String` | byte window `[start, start+len)`, saturating bounds, **`PrimError` if a boundary splits a codepoint** |
| `take` (lib) | `String -> U64 -> String` | `slice s 0 n` |
| `drop` (lib) | `String -> U64 -> String` | `slice s n (length s)` |

The E1/E2 name-collision caveats (E1 §10) are unchanged; `slice`/`byteSlice` live in `Std.String` keyed `(module,name)`.

---

## 6. Routing summary (the L5 mechanism in one place)

`SliceRep`, per view binder, from the existing per-binder escape analysis:
- **`Window`** — binder does not escape AND parent is referenceable. *Interpreter realizes as `Counted`* (D2). Codegen: a borrowed fat pointer, no rc.
- **`Counted`** — binder escapes (returned / stored / captured) but the parent is referenceable. A counted window: `incref` parent on birth, `drop` decrefs on death. Zero byte-copy.
- **`Copy`** — parent unreferenceable (arena-born parent + escaping view). `alloc (NString windowBytes)`: an independent copy. Always safe.

The same expression `slice s a b : String` compiles to any of the three; the surface never says which.

---

## 7. The differential oracle

Reuses the existing three-way harness (RC AbstractHeap vs RC CHeap vs the `Data.Text` reference) over output + `allocs`/`frees`/`peak`/`peak_bytes`.

- **Output parity** — a view's bytes equal the reference substring (`Data.Text` codepoint slice for `slice`; byte slice for `byteSlice`); inline/cell/view representation is invisible above the byte level.
- **The no-copy savings (the new assertion)** — a `Window`/`Counted` slice of a long string allocates **one fixed 32-byte view cell and zero new byte buffer** (`peak_bytes` rises by 32, not by the windowed length), versus `Copy`/materialized which allocates `16 + N`. The oracle pins the **exact** counts and `peak_bytes`, on both RC backends.
- **Routing-annotation parity** — both backends derive the same `SliceRep` (the analysis is backend-independent), so they stay bit-for-bit on counts and output.
- **Leak balance** — the counted window's drop decrefs the parent; `frees`/`peak` return to baseline; ASan/LSan + the `wok_stat_peak_physical_bytes` invariant clean (no new unbounded C path).

---

## 8. Testing strategy — five overlapping layers (the strengthened core)

Soundness is the priority; the layers overlap so a bug must evade all of them. Driven on **both** RC backends (`onBothBackends`) and compared to the `Data.Text` reference, as in E1–E3. Existing harnesses to extend: `test/rc-string/` (26-file corpus), `test/rc-string-oob/`, and the `Spec.hs` blocks `rcStringNodeTests`/`rcStringCCellTests`/`rcStringPrimTests`/`rcStringPropertyTests` (+ the inline-string blocks).

1. **Death-test build with teeth.** A build-flagged test mode that detects a mis-routed `Window` slice — one tagged `Window` despite escaping. **Implementation refinement (Task 5 finding):** the naive "model `Window` as genuinely uncounted + check parent-live-on-read" design produces FALSE POSITIVES — in the counted interpreter the slice prim *consumes* its parent (Perceus drops the parent at the slice), so dropping the view's `incref` would free the parent at the slice even for *correct non-escaping* code (an interpreter-model artifact, not a real codegen UAF, since at codegen the parent is a frame-lived second-class value). The sound death-test must instead detect the thing `Window` actually claims: **a `Window`-routed view must not outlive its birth activation.** It keeps the view counted (so correct code never false-frees the parent) and, under the flag, registers each `Window` view in its birth activation and asserts at activation return that none are still alive — reusing the activation-close hook shape of R1's `KArenaCloseRC`. A non-escaping view dies before return (passes); an escaping view is still alive at return → **fires**. A **permanent negative control** — a slice deliberately forced to `Window` despite escaping — must trip it, proving the teeth are real (the R1 `closeSkippingScanOut` / orphan-slab precedent). The hard constraint: **zero false positives on the correct corpus, real teeth on the negative control.**
2. **Independent routing oracle.** A separately-derived expected `SliceRep` for each slice site, asserted against the planner — a routing bug surfaces as a *mismatch*, not only as a UAF.
3. **Differential oracle** (§7): output parity, the exact 0-new-bytes savings, routing parity, leak balance.
4. **QuickCheck properties:**
   - **Borrow-out survival** — a slice returned from a function and stored in a cons cell still reads correct bytes after the parent's *original* binding is dropped (it survives via the count).
   - **Nested-flatten** — `slice (slice s a b) c d` equals the reference `Data.Text` double-slice byte-for-byte, **and** the result is a single `NStringView` over the **root** buffer (assert no two-hop view→view→root chain).
   - **Window round-trip** — `slice s i n` has the bytes of the reference codepoint-substring.
   - **UTF-8 validity preserved** — every `slice` result is valid UTF-8; `byteSlice` on a split boundary errors.
   - **Op-transparency** — every E1/E2 op (`length`/`index`/`byteAt`/`append`/`indexOf`/`contains`/`count`/`hash`/`editDistance`/`eqString`) on a view matches the same op on the materialized copy.
   - **Cross-type equality** — `eqString` agrees with byte equality for every pair drawn from {view, `WokString` cell, `InlineStr`} (the E3 `CAddr`-vs-`InlineStr` coverage, extended with the view).
5. **Adversarial exploit programs** (hand-written, mandatory for a soundness surface — the async/region lesson "run-the-exploit verifiers are mandatory"): slice escapes via a closure; stored slice + parent rebound and dropped; slice-of-slice with the middle view dying first; a view fed to `append` whose result outlives both operands. Each must be **sound when counted** and **caught by the death-test when deliberately mis-routed**.

- **Sanitizers:** ASan/LSan clean (`scripts/asan-runtime.sh`) + the `peak_physical_bytes` invariant. A `byteSlice` corpus specifically exercises multi-byte (2/3/4-byte UTF-8) boundaries to confirm the split-codepoint error fires.
- **Gate:** full-branch Opus deep review (test soundness reviewed on Opus) + `/code-review high` before any merge — the gate that has historically caught what green tests did not.

---

## 9. Codegen transfer

The two durable artifacts are backend-agnostic: the **routing is an IR annotation** (`SliceRep`) and the **mechanism** (borrow-vs-count-vs-copy by escape) is general. At codegen a `Window` view becomes a **fat pointer** (`ptr + byteoffset + bytelen`, no rc, no cell — a register/stack value); a `Counted` view becomes the same fat pointer plus the parent's rc edge; the prim-layer windowing becomes pointer arithmetic. The interpreter realizes the **allocation-count / no-byte-copy** win now (a 32-byte view cell, no buffer); the **no-refcount** win (the `Window` path) is codegen-era. Nothing in E4 needs redoing for codegen — same "bank the value-model now, cash the speed at codegen" pattern as E2 (SIMD) and E3 (inline word). The node-vs-cell representation choice is interpreter-era and **disposable**; the routing annotation is the lasting thing.

---

## 10. Risks & known limitations

- **The view is the first string-family cell with a counted child.** Mitigated by following the established `WokArray` Haskell-driven drop (D8) — not new C cascade infrastructure. The `scan` field stays dead; setting `scan=1` and expecting C to drop the parent would **silently leak** (the alignment-review hazard) — the spec forbids it.
- **`slice` locate is O(n)** (codepoint → byte). Honest: the window is zero-copy, but finding codepoint boundaries decodes UTF-8. `byteSlice` is the O(1) escape hatch. Consistent with `index`/`length` already being O(n) codepoint ops.
- **The interpreter realizes no-copy, not no-refcount.** A `Window` slice still pays one `incref`/`drop` in the interpreter (D2). The no-rc win is codegen-era and exercised only by the death-test build's analysis. Stated, not hidden.
- **Coverage ceiling.** Only slices the escape analysis proves non-escaping route `Window` (the no-rc class at codegen); escaping slices route `Counted` (still zero-copy, one rc). This is the same coarse-borrow (L2/L5) ceiling the region work documented; widening it is a later rung.
- **`Copy` fallback is unobservable-rare** (arena-born parent + escaping view). It is the unconditionally-safe answer and is exercised by a targeted test, not left to chance.
- **Theoretical-unreachable, documented not guarded** (the E1–E3 / CLAUDE.md precedent): `maxInlineStr = 7` remains the single source of truth for the ≤7-byte inline branch in the D6 procedure; no downstream re-check is added.
