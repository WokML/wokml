# String Slice E1: Simple String (flat UTF-8 bytes) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace wok's placeholder `String` (inline `Text`, no runtime cell) with a real flat-UTF-8-byte `String` on a dedicated C cell, plus six operations and the differential oracle.

**Architecture:** A new `WokString` C cell mirrors the shipped `WokArray` cell (same RC prefix, byte-size-class free-list, two backends) but with a packed byte body. The RC interpreter gains an `NString ByteString` node; the reference interpreter keeps `Text`. The existing differential oracle proves the two RC backends agree bit-for-bit.

**Tech Stack:** C runtime (`runtime/wok_rc.{c,h}`), GHC Haskell (the RC + reference interpreters), tasty/Hspec/QuickCheck.

**Spec:** `docs/superpowers/specs/2026-06-25-string-slice-e1-design.md` (READ IT — every task references it).

**User decisions (already made):** byte storage + Unicode-first codepoint ops + byte-native escape hatch; valid-UTF-8-only with `Text` as the reference model; concat is `append` not `(++)` ("I am okay with that name"); Lean A — first-order E1, no bulk iteration (`chars`/`fromChars`/`foldChars` are E2); `Eq String` instance in `Std.Base`; execute autonomously.

---

### Task 1: `WokString` C cell

**Goal:** Add a real C string cell to the runtime, on both allocator backends, sharing the byte-size-class free-list with `WokArray`/`NCon`.

**Files:**
- Modify: `runtime/wok_rc.h` (the `WokArray` block is the template, `:73-93`)
- Modify: `runtime/wok_rc.c` (mirror `wok_array_alloc` at `:358` (malloc) and `:612` (slab); extend `wok_free`'s tag dispatch at `:237` and `:586`)
- Modify/add: the C standalone test (mirror the `WokArray` coverage in `runtime/wok_arena_test.c` or the array C test)

**Acceptance Criteria:**
- [ ] `WOK_STRING_TAG = 0xFFFEu` defined; cell layout = 8B RC prefix + `uint64 byte_len` at offset 8 + packed `uint8` body at offset 16.
- [ ] `wok_string_alloc(h, byte_len)` (rc=1, tag=`WOK_STRING_TAG`, arity=0, scan=0), `wok_string_len`, `wok_string_data` (returns `uint8_t*` to body), `wok_string_byte_get`.
- [ ] Cell byte size = `16 + 8*ceil(byte_len/8)` (8-rounded); size class = `cell_bytes/8 - 1`; routes via the shared free-list (class < 64) else malloc — identical guard pattern to `wok_array_class`.
- [ ] `wok_free` dispatches `WOK_STRING_TAG` → string size/class on BOTH backends; `cur_bytes`/`peak_bytes` charge the rounded size; `WOK_PHYS_ADD`/`WOK_LOGICAL_MARK` updated as in `wok_array_alloc`.
- [ ] C standalone test: alloc/fill/read-back/free a string; balanced allocs==frees, live==0 at teardown; size-class sharing with an array of the same byte size.

**Verify:** `make -C runtime test` (or the project's C-test target) → all pass; `scripts/asan-runtime.sh` clean.

**Steps:**
- [ ] **Step 1 (test first):** add a C test that allocs a `WokString` of a few byte lengths (0, 1, 7, 8, 9, 500), writes bytes via `wok_string_data`, reads via `wok_string_byte_get`, checks `wok_string_len`, frees, asserts `wok_stat_live==0` and `wok_stat_allocs==wok_stat_frees`. Run → fails to compile (symbols absent).
- [ ] **Step 2:** in `wok_rc.h`, after the `WokArray` block, add the `WokString` layout comment, `#define WOK_STRING_TAG 0xFFFEu`, and the four prototypes (`wok_string_alloc`/`_len`/`_data`/`_byte_get`).
- [ ] **Step 3:** in `wok_rc.c`, add `wok_string_cell_bytes(byte_len)` = `16 + 8*((byte_len+7)/8)` with the same `size_t`-overflow abort as `wok_array_cell_bytes` (`:47`), and (slab backend, `#ifndef WOK_RC_MALLOC`) `wok_string_class(byte_len)` = `cell_bytes/8 - 1` with the no-wrap guard pattern of `wok_array_class` (`:62`).
- [ ] **Step 4:** add `wok_string_alloc` on BOTH backends, mirroring `wok_array_alloc` (`:358` malloc, `:612` slab): route by class to free-list/bump/malloc, stamp `rc=1; tag=WOK_STRING_TAG; arity=0; scan=0`, write `byte_len` at offset 8, leave body undef; update `allocs/live/peak/cur_bytes/peak_bytes` + `WOK_PHYS_ADD`(large path)/`WOK_LOGICAL_MARK`.
- [ ] **Step 5:** extend `wok_free`'s tag dispatch on BOTH backends (`:237`, `:586`): add `else if (tag == WOK_STRING_TAG) { bytes = wok_string_cell_bytes(byte_len_read_at_offset_8); cls = wok_string_class(...); }` before the arity `else`.
- [ ] **Step 6:** add the shared accessors `wok_string_len`/`wok_string_data`/`wok_string_byte_get` (no allocator involvement), mirroring `wok_array_len`/`_slot_get` at `:800`. Reserve `0xFFFE` alongside `0xFFFF` wherever the array tag's reservation is documented.
- [ ] **Step 7:** run the C test (pass) + `scripts/asan-runtime.sh` (clean). Commit.

```json:metadata
{"files": ["runtime/wok_rc.h", "runtime/wok_rc.c", "runtime/wok_arena_test.c"], "verifyCommand": "scripts/asan-runtime.sh", "acceptanceCriteria": ["WOK_STRING_TAG + cell layout", "wok_string_alloc/len/data/byte_get on both backends", "8-rounded size class shared with WokArray", "wok_free string branch both backends", "C standalone test balanced + ASan clean"], "modelTier": "standard"}
```

---

### Task 2: FFI bindings + `NString` node + alloc/render (both RC backends)

**Goal:** Surface the C string cell to the RC interpreter as an `NString ByteString` node, allocated on CHeap (real cell) and AbstractHeap (mirror), rendered identically to the reference.

**Files:**
- Modify: `src/Wok/Interp/RC/Heap.hs` (mirror the `wokArray*` imports at `:38-42`)
- Modify: `src/Wok/Interp/RC/Value.hs` (`NArray` at `:633` is the template; `nodeCEligible` `:1560`, `wouldBeCBytes` `:1585`, `alloc` dispatch `:1397`, the renderer `:2282`)

**Acceptance Criteria:**
- [ ] `wokStringAlloc :: Ptr WokHeap -> Word64 -> IO (Ptr WokObj)`, `wokStringLen`, `wokStringData :: Ptr WokObj -> IO (Ptr Word8)`, `wokStringByteGet` imported and exported.
- [ ] `NString ByteString` constructor added to the node type (strict field; repo is StrictData — no bang needed).
- [ ] `nodeCEligible (NString _) = False`; `wouldBeCBytes (NString bs) = 16 + 8 * ((BS.length bs + 7) ediv 8)`.
- [ ] `alloc (NString bs)`: CHeap → `allocNString` (`wok_string_alloc` then `memcpy` `bs` into `wok_string_data`); AbstractHeap → `allocPure` charging `wouldBeCBytes`.
- [ ] Drop cascade for `NString` is empty (no child refs); `dropAddr` frees the cell at rc 0.
- [ ] RC renderer prints an `NString` identically to the reference `VLit (LStr …)` form (verify against `renderLit`/`renderValue`).
- [ ] **(carryover from Task 1 spec review)** `internTag` (`Value.hs:931`) reserves `0xFFFE` (`WOK_STRING_TAG`) as well as `0xFFFF` (`wokArrayTag`): add a `wokStringTag = 0xFFFE` constant and skip BOTH reserved tags, else ~65534 constructors would intern a tag colliding with the string cell.

**Verify:** `cabal build` clean; a temporary unit test that allocs an `NString` on both backends and round-trips bytes passes.

**Steps:**
- [ ] **Step 1:** add the four `foreign import ccall unsafe` lines to `Heap.hs` mirroring `wokArrayAlloc`/`wokArrayLen`/`wokArraySlotGet` (`:38-42`); export them.
- [ ] **Step 2:** add `NString ByteString` to the RC node ADT beside `NArray` (`Value.hs:633`); add the import of `Data.ByteString` (qualified `BS`) if absent.
- [ ] **Step 3:** add `nodeCEligible (NString _) = False` and `wouldBeCBytes (NString bs) = 16 + 8 * ((BS.length bs + 7) ediv 8)`.
- [ ] **Step 4:** add `allocNString` (CHeap) using `wokStringAlloc` + `wokStringData` + a `memcpy`/`pokeArray` of the bytes; wire the `alloc (NString bs)` two-path dispatch mirroring `alloc (NArray vs)` at `:1397`.
- [ ] **Step 5:** wire the drop/cascade so `NString` has no children (mirror how a childless node is handled); confirm `dropAddr` on an `NString` just frees.
- [ ] **Step 6:** add the `NString` case to the RC renderer matching the reference string render byte-for-byte.
- [ ] **Step 7:** TDD a unit test (both backends): build `NString "héllo"` (multi-byte), assert `byte_len`, read bytes back, drop, assert balanced stats. `cabal test` (or a focused module). Commit.

```json:metadata
{"files": ["src/Wok/Interp/RC/Heap.hs", "src/Wok/Interp/RC/Value.hs"], "verifyCommand": "cabal build all 2>&1 | tail -5", "acceptanceCriteria": ["wokString* FFI imported+exported", "NString ByteString node", "nodeCEligible False + wouldBeCBytes rounded", "alloc two-path (CHeap memcpy + AbstractHeap mirror)", "empty drop cascade", "render parity with reference"], "modelTier": "standard"}
```

---

### Task 3: String becomes a counted cell (literal allocation + analysis flips)

**Goal:** Make string literals allocate `NString` cells and make every analysis treat `String` as a boxed, reference-counted, heap-only value — auditing the `isBoxedType` ripple.

**Files:**
- Modify: `src/Wok/Interp/RC/Machine.hs` (literal eval — `LStr` → allocate `NString`; `litText` is at `:670`)
- Modify: `src/Wok/IR/Escape.hs` (`isBoxedType (CTCon TcString []) = True`, `:123`)
- Modify: `src/Wok/IR/ReusePairing.hs` (`slotClassOf (CTCon TcString []) = KPointer`, `:92`)
- Modify: `src/Wok/IR/Region.hs` (route every `NString`/String-typed allocation to Heap, never Arena)
- Audit only: `src/Wok/IR/Perceus.hs`, `src/Wok/IR/Reachable.hs`

**Acceptance Criteria:**
- [ ] Evaluating `ALit (LStr s)` in the RC interpreter allocates an `NString` cell (UTF-8-encode `s`); the reference interpreter still yields `VLit (LStr s)`.
- [ ] `isBoxedType (CTCon TcString []) = True`; Perceus now inserts `__rc_dup`/`__rc_drop` for String binders; Reachable tracks them as boxed locals.
- [ ] `slotClassOf (CTCon TcString []) = KPointer`.
- [ ] Region pass routes String allocations to Heap (the `(tag,arity)`-shaped arena bump cannot hold a byte cell); Region R1's handler-free-module gating is unchanged.
- [ ] The full existing suite stays green (no handler-module regression from the boxed-local change); a string literal built and dropped shows balanced allocs/frees on the oracle.

**Verify:** `cabal test` → full suite green; the oracle shows balanced alloc/free for a `let s = "hi" in ()`-style program on both backends.

**Steps:**
- [ ] **Step 1 (test first):** add an oracle test: a program that binds a string literal and discards it must report `allocs == frees`, `live == 0` on both RC backends, with `peak_bytes` = the rounded cell size. Run → fails (literal is still inline; or unbalanced once boxed without dup/drop).
- [ ] **Step 2:** change literal evaluation so `ALit (LStr s)` allocates an `NString (encodeUtf8 s)` cell. Keep the reference interpreter as `VLit (LStr s)`.
- [ ] **Step 3:** flip `isBoxedType (CTCon TcString []) = True` (`Escape.hs:123`). Build; run the suite.
- [ ] **Step 4:** flip `slotClassOf (CTCon TcString []) = KPointer` (`ReusePairing.hs:92`).
- [ ] **Step 5:** in `Region.hs`, ensure a String-typed / `NString` allocation is always placed Heap (never Arena). Add/adjust the routing so the arena candidacy excludes strings; confirm by reading the handler-free gate is untouched.
- [ ] **Step 6:** AUDIT `Perceus.hs` (`boxedBinder` sites) and `Reachable.hs` (boundary guard): confirm the flip's effects are correct (dup/drop now emitted for String binders; boundary tracking includes them). Run the FULL suite; investigate any handler-module failure. If the ripple proves to need design judgment beyond these steps, report BLOCKED for tier escalation.
- [ ] **Step 7:** the new oracle test passes; full suite green; ASan clean. Commit.

```json:metadata
{"files": ["src/Wok/Interp/RC/Machine.hs", "src/Wok/IR/Escape.hs", "src/Wok/IR/ReusePairing.hs", "src/Wok/IR/Region.hs"], "verifyCommand": "cabal test 2>&1 | tail -20", "acceptanceCriteria": ["LStr literal allocates NString", "isBoxedType TcString True", "slotClassOf TcString KPointer", "Region routes String to Heap; R1 gate unchanged", "full suite green; balanced alloc/free oracle"], "modelTier": "frontier"}
```

---

### Task 4: The six operations (both backends) + prelude + Eq String

**Goal:** Implement `length`/`index`/`byteLength`/`byteAt`/`append`/`eqString` in both interpreters, register the names, and add the `Std.String` prelude + `Eq String` instance.

**Files:**
- Modify: `src/Wok/IR/PrimNames.hs` (add `stdStringModule` + the six name constants, mirroring the Array block `:131-164`)
- Modify: `src/Wok/Interp/Prim.hs` (reference impls over `VLit (LStr Text)`, mirror `:317-391`)
- Modify: `src/Wok/Interp/RC/Prim.hs` (RC impls over `NString`/cell, mirror `:471-590`)
- Create: `prelude/Std/String.wok`
- Modify: `prelude/Std/Base.wok` (`extern eqString` + `instance Eq String`)

**Acceptance Criteria:**
- [ ] `Std.String` exports `length`, `index`, `byteLength`, `byteAt`, `append` with the spec §5.1 signatures.
- [ ] Reference impls: `length`=`Text.length`, `index`=codepoint index (OOB→`PrimError`), `byteLength`=`BS.length . encodeUtf8`, `byteAt`=UTF-8 byte (OOB→`PrimError`), `append`=`Text.append`, `eqString`=`(==)` on `Text`.
- [ ] RC impls over `NString`: byte ops O(1) from the cell; codepoint ops decode UTF-8 (no tables); `append` allocs a new cell of `len a + len b` and `memcpy`s both bodies; all consume their args per the Array convention; `append` is +1 alloc, the rest 0.
- [ ] `Eq String` instance lives in `Std.Base` (cross-module-instance limit); `==` on strings works.
- [ ] A wok program using each op runs identically on all three backends.

**Verify:** `cabal test` → a string-ops smoke program passes the oracle on all three backends.

**Steps:**
- [ ] **Step 1:** add to `PrimNames.hs`: `stdStringModule = "Std.String"` and `stringLengthName`/`stringIndexName`/`stringByteLengthName`/`stringByteAtName`/`stringAppendName`/`eqStringName`; export them (mirror the Array block).
- [ ] **Step 2 (test first):** write a wok smoke program (`length "héllo"`, `byteLength "héllo"`, `index`, `byteAt`, `append`, `==`) and an oracle test asserting all three backends agree. Run → fails (prims unregistered).
- [ ] **Step 3:** reference impls in `Interp/Prim.hs` over `VLit (LStr Text)` (use `Data.Text`/`Data.Text.Encoding`), each `mkPrim PN.<name> <arity>`, mirroring `arrayLengthP`/`arrayIndexP` shape; register them in the reference prim table.
- [ ] **Step 4:** RC impls in `Interp/RC/Prim.hs` over `NString` (decode helper for codepoints; bounds-check; `append` allocs via `alloc (NString (a<>b))`), each `RCPrim PN.<name> <arity> []`, mirroring `arrayIndex`/`arrayLength`/`arrayNew`; register them.
- [ ] **Step 5:** create `prelude/Std/String.wok` with the five externs; add `extern eqString` + `instance Eq String where (==) = eqString` to `prelude/Std/Base.wok`.
- [ ] **Step 6:** run the oracle smoke test on all three backends (pass); full suite green. Commit.

```json:metadata
{"files": ["src/Wok/IR/PrimNames.hs", "src/Wok/Interp/Prim.hs", "src/Wok/Interp/RC/Prim.hs", "prelude/Std/String.wok", "prelude/Std/Base.wok"], "verifyCommand": "cabal test 2>&1 | tail -20", "acceptanceCriteria": ["PrimNames: stdStringModule + 6 names", "reference impls over Text", "RC impls over NString (append +1 alloc, rest 0)", "Std.String prelude + Eq String in Std.Base", "three-backend oracle agreement"], "modelTier": "standard"}
```

---

### Task 5: Differential oracle corpus + QuickCheck properties

**Goal:** Prove E1 correct and memory-faithful with a string program corpus through all three backends plus the spec §8 properties.

**Files:**
- Modify/add: the oracle test module that drives Array (the String corpus joins it) + a QuickCheck properties module.

**Acceptance Criteria:**
- [ ] Corpus programs (literals, `append` chains, `length`/`byteLength` on ASCII + multi-byte, `index`/`byteAt` boundaries, `==`) run through reference + RC AbstractHeap + RC CHeap with byte-identical output and matching `allocs`/`frees`/`peak`/`peak_bytes`.
- [ ] QuickCheck properties: `byteLength s >= length s` (`==` iff all-ASCII); `length (append a b) == length a + length b`; `byteLength (append a b) == byteLength a + byteLength b`; `append` associativity; `eqString` reflexive/symmetric and equal-iff-same-codepoints; `index`/`byteAt` agree with the `Text` reference at sampled in-bounds offsets; OOB raises `PrimError` on every backend.
- [ ] Generators produce multi-byte UTF-8 (not just ASCII) to exercise boundaries.

**Verify:** `cabal test` → the whole suite green; `scripts/asan-runtime.sh` clean.

**Steps:**
- [ ] **Step 1:** add the corpus programs to the differential oracle harness used by Array; assert tri-backend output + memory parity.
- [ ] **Step 2:** add the QuickCheck property module with a multi-byte-UTF-8 `Gen` and the properties above (each checked against the `Text` reference).
- [ ] **Step 3:** run the full suite + ASan; fix any divergence (a divergence is a real bug in Tasks 1-4, not the test). Commit.

```json:metadata
{"files": ["test/oracle", "test/properties"], "verifyCommand": "cabal test 2>&1 | tail -20 && scripts/asan-runtime.sh", "acceptanceCriteria": ["tri-backend corpus parity (output + allocs/frees/peak/peak_bytes)", "QuickCheck properties incl multi-byte UTF-8", "OOB raises PrimError on all backends", "suite green + ASan clean"], "modelTier": "standard"}
```

---

## Notes for execution
- **Order:** 1 → 2 → 3 → 4 → 5 (each builds on the prior; not parallelizable — overlapping files + dependency).
- **Routing:** Tasks 1/2/4/5 = standard (Sonnet); Task 3 = frontier (Opus) for the `isBoxedType` ripple audit; reviewers (spec + quality) at standard (Sonnet); the final whole-branch review at session level.
- **Gate before merge:** after Task 5, run `hlint` (ignore `src-generated`), the Opus deep review (test soundness specifically), and `/code-review high` (full branch). Fix what they surface. Do NOT merge to `main` without the full-branch review (`[[review-before-merge]]`).
