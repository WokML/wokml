# String Slice E3: small-string optimization (inline short strings) — Design Spec

**Date:** 2026-06-26
**Status:** Approved for planning (brainstorm converged; alignment review passed — every code reference confirmed real, the bit-2 slot scheme proven sound, the exhaustive `Addr`-match touch-points enumerated).
**Predecessor:** String Slice E2 (`2026-06-26-string-slice-e2-design.md`, the StringZilla byte-ops + dogfooded search layer this builds on).
**Companions:** `docs/string-memory-layout.html` (the current vs. E3 layout), `docs/beating-the-c-stack.html` (the allocation-tier ladder this slice adds a rung to).

---

## 1. Goal & scope

Make short strings (≤ 7 UTF-8 bytes) live **inline in the one-word value**, with **zero heap allocation** and **no reference counting** — a faithful continuation of the slice-2 "nullary constructor as inline immediate" mechanism (`Addr Inline Word32`). A short string stops touching the heap: no `WokString` cell, no allocation, no `rc` traffic, no separate cache line. Longer strings keep today's `WokString` cell unchanged.

**In scope (E3):**
- A new inline `Addr` variant `InlineStr !ByteString` (invariant: length ≤ 7), wrapped as `RVBox (InlineStr bs)`.
- The **two hinges**: intercept at the shared `alloc (NString bs)` chokepoint (route length ≤ 7 to `InlineStr`); synthesize at `deref` (`deref (InlineStr bs)` returns an `NString bs` node) — so every existing string operation keeps working unchanged.
- `InlineStr` is **uncounted** (`isUncounted`), so dup/drop are no-ops.
- The exhaustive set of `Addr`-matching arms a new constructor forces (compile-enforced under `-Werror`).
- The **slot encoding** for a short string that is a *field* of a C-heap cell: a sub-tag inside the existing `11` `Inline` 2-bit slot class, requiring a paired change to `encodeSlotC`/`decodeSlotC`.
- Short string **literals** in owning positions fold to immediates automatically (literal evaluation routes through `alloc (NString …)`); optionally seed short literal CAFs as static immediates.
- Oracle + QuickCheck extensions proving the inline savings and cross-representation correctness.

**Out of scope (boundary made explicit):**
- **Anything wider than one machine word.** StringZilla's 22-byte `sz_string_t` SSO requires a string value to be 4 words (32 bytes) by value, which collides head-on with wok's uniform one-word slot AND with reference-count sharing (a by-value struct can't be rc-shared; the on-stack `start` is self-referential and not `memcpy`-able). That is a separate value-model epic, not E3. (See `docs/string-memory-layout.html` §5.)
- **Codepoint iteration** — `chars`/`fromChars`/`foldChars` (the prim-calls-closure machine frame), still deferred.
- **E4** — zero-copy views + table-driven Unicode (case/normalize/grapheme).
- **Rope / chunked-tree / RRB string representation** — the wrong tool for a compiler runtime (read/concat/slice-heavy, not mid-string editing), and a tree of shared chunks fights RC promptness (the same wall `docs/trmc-and-list-representation.html` recorded for chunked lists).

---

## 2. Background — where E2 left things

`String` is a flat UTF-8 byte buffer on a dedicated `WokString` C cell (tag `0xFFFE`), mirrored on the abstract heap as an `NString ByteString` node. The value held everywhere (local, argument, constructor field) is **one machine word**: a `CAddr` pointer (low slot bits `00`) or an `HAddr` abstract index (`01`). E2 added StringZilla byte-ops (`indexOfFromRaw`/`hash`/`editDistance`) and a dogfooded search layer; all of them read a string's bytes through one helper, `stringBytes` (`src/Wok/Interp/RC/Prim.hs:707`), which derefs the address and pulls the `NString` payload.

**The slice-2 precedent E3 mirrors exactly** (nullary constructors as inline immediates, merged `15481e7`):
- `Addr = HAddr Int | CAddr (Ptr WokObj) | Inline Word32` (`Value.hs:159`).
- Intercept at the shared `alloc` chokepoint: `alloc (NCon con []) = pure (allocInline con s)` (`Value.hs:1422`) — no cell, no stat bump, both backends.
- Synthesize at deref: `deref (Inline tid) = Cell 0 (NCon (tagName tid s) []) 0` (`Value.hs:1741`), `derefPure` likewise (`Value.hs:1837`).
- Uncounted: `isInline` (`Value.hs:1092`), `isUncounted = isStaticAddr || isInline` (`Value.hs:1110`) ⇒ `incref`/`dropAddr`/`dropReuse` are no-ops on it.
- 2-bit slot tag in `KPointer`: `00` `CAddr` (any even word), `01` `HAddr` (`(i<<2)|1`), `11` `Inline` (`(tid<<2)|3`); `encodeSlotC` `Value.hs:1045`, `decodeSlotC` `Value.hs:1066`.

E3 reuses every piece of this machinery and adds one new address variant beside `Inline`.

---

## 3. Decisions (converged in brainstorm 2026-06-26)

1. **Ceiling fixed at `maxInlineStr = 7` bytes.** This is the bit-layout maximum for a one-word value (62 payload bits − 3 control/length bits ⇒ 7 bytes of text). Hardcoded as a named constant and documented; NOT runtime-tunable. Going wider means widening the string value past one word — the out-of-scope epic.
2. **Representation `InlineStr !ByteString`**, invariant `BS.length ≤ 7`, wrapped as `RVBox (InlineStr bs)`. It stays an `RVBox` at the value level, so it is type-level `String` exactly as before — no `isBoxedType` / Escape / Region / Perceus ripple. `ByteString` (not `ShortByteString`) so `deref` reconstructs `NString bs` with no conversion; the strict field avoids a thunk. (ShortByteString is a possible later micro-optimization if short-string pinned-buffer churn ever shows up; not now.)
3. **Uncounted.** `isInline` and `isUncounted` include `InlineStr`; every reference-count operation treats it as inert, exactly as for the nullary `Inline` immediate and static addresses. dup and drop of a short string are no-ops.
4. **The two hinges (why E3 is small):**
   - **alloc interception** at the shared chokepoint:
     ```
     alloc (NString bs) s | BS.length bs <= maxInlineStr = pure (InlineStr bs, s)   -- NO cell, NO recordAlloc, BOTH backends
                          | otherwise                    = <existing heap path>     -- CHeap → allocNString; AbstractHeap → allocPure
     ```
     (`alloc :: Node -> Store -> RC (Addr, Store)`; the caller wraps the returned `Addr` in `RVBox`, so a short string becomes `RVBox (InlineStr bs)`.)
   - **deref synthesis**: `deref (InlineStr bs) s = pure (Cell 0 (NString bs) 0)` and `derefPure (InlineStr bs) s = Right (Cell 0 (NString bs) 0)`.
   - Because `stringBytes → deref → NString bytes` is the single funnel for every string op/prim (`length`, `index`, `byteLength`, `byteAt`, `append`, `eqString`, and the E2 `indexOfFromRaw`/`hash`/`editDistance`), they ALL keep working unchanged on a short string.
5. **Slot encoding (a short string as a constructor field).** A field must pack into one 64-bit slot. The 2-bit tag space is full (`00`/`01`/`11`), so sub-discriminate inside the `11` `Inline` class by **stealing bit 2**. This is a PAIRED CHANGE to the existing nullary encoding, not just an addition:
   - **Existing nullary `Inline`** changes from `(tid << 2) | 0b11` to **`(tid << 3) | 0b011`** — bit 2 becomes always 0. Sound: `tid ≤ 65535` (16 bits, gated by the `tid >= 65536` fallback in `allocNCon`); 61 bits of headroom remain after `<<3`.
   - **New inline string**: `0b111 | (len << 3) | (bytesWord << 6)`, where `len ∈ 0..7` (3 bits) and `bytesWord` packs the ≤ 7 bytes little-endian (≤ 56 bits). Total used: 3 (control) + 3 (length) + 56 (bytes) = 62 bits; fits in 64 with 2 spare.
   - `decodeSlotC`'s `KPointer` `11`-class branch must first test bit 2: `0` ⇒ nullary (`tid = w >> 3`); `1` ⇒ inline string (`len = (w >> 3) .&. 0x7`, bytes = next `len` bytes of `w >> 6`).
   - **The C runtime is byte-dumb** (stores the slot word verbatim), so it needs ZERO change. `stConDesc` is unaffected — `InlineStr` reuses the `KPointer` slot kind with a new sub-encoding, not a new `SlotKind`.
6. **Short literals fold automatically.** Owning-position string literals route through `resolveRCAtomAlloc (ALit (LStr s)) = alloc (NString (encodeUtf8 s))` (`Value.hs`), so the alloc interception makes ≤ 7-byte literals `InlineStr` for free — no literal-specific code in the common case. A case scrutinee literal stays `RVLit (LStr s)` (unchanged; non-owning), and an `InlineStr` *variable* scrutinee matches a string-literal alt because `goNode` derefs to `NString` and compares (the B1 fix, `Machine.hs:701`). **Optional refinement:** relax the `reserveStatic` exclusion `not (isLStr l)` (`Machine.hs:1087/1092/1146`) for ≤ 7-byte literals so a top-level CAF like `foo = "/"` seeds as a STATIC immediate instead of allocating on first eval, mirroring nullary CAFs. (Optional because the alloc interception already banks the per-eval win.)
7. **Length-only decision at the shared chokepoint** ⇒ both RC backends (AbstractHeap, CHeap) decide inline-vs-heap identically ⇒ the differential oracle stays bit-for-bit.

---

## 4. Architecture / touch-points

### 4.1 `src/Wok/Interp/RC/Value.hs` — the address variant and its arms

Adding `InlineStr` to `Addr` makes every `Addr`-matching function non-exhaustive. The repo builds with `-Werror` + `-Wincomplete-patterns` (`wok.cabal`), so each site below is a **compile-enforced** edit, not an optional one. Almost all mirror the existing `Inline` arm.

**Core (the new behaviour):**
- `data Addr = … | InlineStr !ByteString` (`:159`).
- `isInline (InlineStr _) = True` (`:1092`); `isUncounted` then covers it via `isInline`.
- `isStaticAddr (InlineStr _) = False` (`:1086`).
- `isArenaAddr (InlineStr _) _ = False` (`:1120`).
- `alloc (NString bs)` interception (`:1427`) — Decision 4.
- `deref (InlineStr bs)` and `derefPure (InlineStr bs)` synthesis (`:1741` / `:1837`) — Decision 4.
- `encodeSlotC` / `decodeSlotC` bit-2 paired change (`:1045` / `:1066`) — Decision 5.

**No-op / error arms (mirror the existing `Inline` arm at each site):**
- `incref (InlineStr _) = pure` (`:1872`); `increfPure (InlineStr _) = Right` (`:1879`).
- `dropAddr` go-loop: `go (InlineStr _ : rest) s = go rest s` (`:1903`). **Highest-priority arm** — every string prim calls `dropAddr` on its owned string address; for a short string that address is `InlineStr bs`, so a missing arm is both a build failure and (hypothetically) a runtime non-exhaustive crash on the hot string path.
- `dropAddrStepPure (InlineStr _) s = Right (Nothing, s)` (`:2027`).
- `dropReuse (InlineStr _) s = pure (RVReuse Nothing, s)` (`:2136`) — uncounted, never a reuse donor.
- `freeReservation (InlineStr _, _) s = pure s` (`:553`) — never reserved.
- `moveOutContPure (InlineStr _) _ = Left …` (`:600`) — an inline immediate is not a continuation.
- `writeStatic (InlineStr _) _ _ = error …` (`:1673`); `writeNodePure (InlineStr _) _ _ = Left …` (`:1690`) — no cell to overwrite.
- `allocAt (InlineStr _) …` error arm (`:2237`, beside the existing `Inline _` arm).
- `arrayUnique (InlineStr _) _ = pure False` (`:2526`); `arraySetSlotInPlace (InlineStr _) … = error/Left` (`:2566`) — a string is never an in-place-mutable array shell.
- `valueChildren` needs **no** change: `RVBox a` already returns `[a]`, and `countedRefs` filters out the uncounted `InlineStr`, so a short string contributes nothing to dup/drop cascades.

### 4.2 `src/Wok/Interp/RC/Prim.hs` — the prim layer

- `stringBytes` (`:707`) is unchanged — it derefs and reads `NString`, which the synthesis arm provides.
- `byteAt` O(1) fast-path (`:772`) matches `RVBox (CAddr p)` to call `wokStringByteGet`. An `InlineStr` does NOT match `CAddr`, so it **falls through** to the catch-all byte path (`stringBytes → deref → BS.index`). No new arm needed; the spec records fall-through as the chosen behaviour.
- `append` (`:811`) builds the concatenated `ByteString` then calls `alloc (NString cat)`, so it routes inline-vs-heap automatically by the result length. No change expected; verified by the oracle (`"ab"++"cd"` ⇒ inline, longer ⇒ heap).
- The E2 ops (`indexOfFromRaw`/`hash`/`editDistance`) have no `CAddr` fast-path — they already go through `stringBytes` — so they work on `InlineStr` unchanged.

### 4.3 `src/Wok/Interp/RC/Machine.hs` — literals

- Owning-position literals: automatic via `resolveRCAtomAlloc` (Decision 6); no change.
- `matchAltsRC` / `goNode` (`:701`): an `InlineStr` variable scrutinee derefs to `NString` and matches `LStr` alts (B1 fix path) — no change.
- **Optional:** relax `reserveStatic`'s `not (isLStr l)` exclusion (`:1087/1092/1146`) for ≤ 7-byte literals, seeding a static `InlineStr` immediate. Implement only if it stays a small, contained change; otherwise defer (the win is already banked per-eval).

### 4.4 What explicitly does NOT change

The C runtime (`runtime/wok_rc.{c,h}` — byte-dumb, stores the slot word verbatim), `Escape`/`Reachable`/`Region`/`ReusePairing`/Perceus, `isBoxedType`, `wouldBeCBytes`/`nodeCEligible` (never see an `InlineStr` — there is no cell), and the bodies of every string op.

---

## 5. The E3 surface

No new wok-surface functions. E3 is a pure runtime-representation change: `Std.String` is byte-for-byte the same source, and all E1/E2 ops behave identically. The E1/E2 name-collision caveats (spec E1 §10) are unchanged.

---

## 6. The differential oracle

Reuses the existing three-way harness (RC AbstractHeap vs RC CHeap vs the `Data.Text` reference) over output + `allocs`/`frees`/`peak`/`peak_bytes`.

- **The savings are the new assertion.** Programs built from short strings allocate **0 wok cells** for those strings on both RC backends (the `alloc` interception never calls `recordAlloc`), so `allocs`/`frees`/`peak`/`peak_bytes` drop accordingly. A corpus program that previously allocated N `WokString` cells for N short literals now allocates 0; the oracle pins the exact new counts.
- **Output parity is unchanged** — the reference backend (`Data.Text`) produces identical observable output; inline-ness is invisible above the byte level.
- **Backend agreement is by construction** — the length-only decision at the shared chokepoint makes AbstractHeap and CHeap choose inline-vs-heap identically, so they stay bit-for-bit on counts and output.
- **Physical-invariant assertion** (sanitizer build) is unaffected: no new C allocation path is introduced (inline strings never reach the C heap).

---

## 7. Testing strategy

- **Oracle corpus** (`test/rc-string/`): programs exercising short strings (`""`, `"/"`, `"Hi"`, a 7-byte string, an 8-byte string), short-string *fields* of constructors (forcing the slot path), `append` across the 7↔8 boundary, equality between an inline and a heap string with equal bytes, and case-match on an inline-backed string variable. Each runs through all three backends; the short-string programs additionally assert the **0-cell** allocation counts.
- **QuickCheck properties:**
  - **Byte round-trip:** for any `bs` with `BS.length bs ≤ 7`, building a string then reading its bytes back yields `bs` (the inline encode → `deref` synthesis is the identity on bytes).
  - **The 7↔8 boundary:** a ≤ 7-byte string allocates 0 cells; an 8-byte string allocates exactly one `WokString` cell — on both RC backends.
  - **Slot round-trip:** an inline string stored as a constructor field and read back equals the original (exercises `encodeSlotC`/`decodeSlotC`, including a nullary immediate as a sibling field to prove the bit-2 split does not cross-talk).
  - **Cross-representation equality:** `eqString` agrees with byte equality regardless of whether each side is inline or heap (equality stays BYTE-based; inline canonicalization is a nicety, never relied on).
  - **append:** `append a b` has the bytes of `a <> b` and is inline iff `BS.length (a<>b) ≤ 7`; all E1/E2 ops (`length`/`index`/`byteAt`/`indexOf`/`contains`/`count`/`hash`/`editDistance`) on inline inputs match the reference.
  - **Decode totality:** `decodeSlotC` covers all four `KPointer` cases (`00` / `01` / `11`+bit2=0 / `11`+bit2=1) and the nullary `tid` still round-trips after the `<<3`/`>>3` change.
- **Backends:** every property driven on AbstractHeap and CHeap (`onBothBackends`) and compared to the reference, as in E1/E2.
- **Sanitizers:** ASan/LSan clean (`scripts/asan-runtime.sh`), including the physical invariant. (No new C path; inline strings are pure Haskell-side address values.)

---

## 8. Codegen transfer

The inline word IS the codegen-era representation: a tagged value word that carries ≤ 7 bytes of text directly, no cell. The interpreter models the eventual 62-bit packing through the slot encode/decode pair; at codegen the same packing becomes the machine representation of a short `String`, and the `deref` synthesis becomes a branch on the value-word tag. Nothing in E3 needs redoing for codegen — it is the same "bank the value-model change now, cash the speed at codegen" pattern E2 used for SIMD. The wall-clock win (no pointer indirection, no `rc` traffic, better locality) is a codegen-era benefit; the interpreter realizes the **allocation-count** win immediately (and the oracle measures it).

---

## 9. Risks & known limitations

- **7-byte ceiling is small** — declared, not hidden; it is the one-word value-model limit. A bigger inline budget (toward StringZilla's 22 bytes) requires widening the string value past one word, which fights BOTH the uniform one-word slot AND reference-count sharing — a separate epic with its own brainstorm (`docs/string-memory-layout.html` §5).
- **The slot-encoding change is a breaking modification of the existing nullary-`Inline` encoding**, not a pure addition: `encodeSlotC` and `decodeSlotC` both change from `<<2`/`>>2` to `<<3`/`>>3` for the `11` class, with bit 2 as the sub-tag. Internal-only (no persisted format), sound (≤ 16-bit tags, 61 bits headroom). The full encode/decode pair is written out in §3.5; the decode-totality test (§7) pins all four cases.
- **Equality must stay byte-based.** Two equal short strings DO share the same `InlineStr` representation (canonical packing), so `Addr` equality happens to coincide for them — but heap strings with equal bytes have different addresses, so `eqString` must never shortcut on `Addr` equality. Tested by the cross-representation equality property.
- **`byteAt` must fall through, not skip.** The `CAddr` fast-path must let an `InlineStr` reach the byte path; a regression would surface as a "String: not a string" error. Pinned by a `byteAt`-on-inline test.
- **Empty string `""` becomes inline (0 bytes).** Today it costs a 16-byte cell; under E3 it is an `InlineStr ""` immediate — the cleanest win, and a corpus case.
- **Theoretical-unreachable, documented not guarded** (matching the E1/E2 precedent and CLAUDE.md "do not guard impossible inputs"): the `maxInlineStr = 7` constant is the single source of truth; the bit-packing assumes `len ≤ 7`, enforced solely at the `alloc` interception, so no downstream re-check is added.
