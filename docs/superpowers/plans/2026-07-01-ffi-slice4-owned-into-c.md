# FFI Slice 4 — owned-INTO-C (move-out) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the transfer-full argument disposition (`owned` on a foreign-module parameter) so a wok-owned `Bytes` can be moved into a blessed C consumer, via a runtime rc==1 move/copy router, freed exactly once, with a QuickCheck property suite and ASan death-tests.

**Architecture:** A new `owned`-on-a-parameter grammar modifier (`TOwned`) carries a per-argument `MoveOut` transfer tag from the surface through the blessed table and `ForeignMemberInfo` into the `RForeignCall` IR node. At the RC dispatch site, a `consume` arm reads the buffer (deterministic FNV-1a checksum via a pure-read C function), then routes on `arrayUnique`: rc==1 frees the original (zero-copy move), rc>1 allocates a fresh copy for the consumer and frees that while decrementing the original (copy). The free is Haskell-driven and synchronous (design i-b) — the C consumer never frees.

**Tech Stack:** Haskell (GHC), BNFC grammar, a C runtime (`wok_rc.c`/`.h`), tasty + tasty-quickcheck + `Test.QuickCheck.Monadic`, ASan via `scripts/asan-runtime.sh interp` (`WOK_RC_MALLOC`).

**User decisions (already made):**
- Mechanism = (B) the runtime rc==1 router, not the static affine gate. "(B) is good because (A) seems like a big task to do."
- Consumer = design (i-b): "i-b is better" — the C consumer is pure-read; Haskell drives `wok_free` synchronously.
- Concept renamed "transfer" (not "disposition"); arg tag = `MoveOut`; surface keyword = `owned` on a parameter.
- Two demos = the two router branches (owned/move + shared/copy), both asserted; B-scratch and B-retain kept out of scope.
- "Write a series of property test to test this scope" — QuickCheck P1–P7 (added to spec §9.1).
- Death-tests: "Run-the-exploit death-tests are mandatory and must genuinely bite" — mutation-confirmed under ASan.

**Spec:** `docs/superpowers/specs/2026-07-01-ffi-slice4-owned-into-c-design.md` (committed `043cd2f`).

---

## Implementation model (refines spec §7.2 for the implementer)

The spec §7.2 speaks of "suppressing the caller-drop." The precise, faithful dispatch model — the one every task below assumes — is: **the RC dispatch owns the single free** (mirroring how the `memchr` borrow-out arm already calls `dropAddr bAddr` after the call). For `Sink.consume b`:

```
consume b:
  csum   = wok_bytes_consume_checksum(b)     -- pure read, does NOT free
  unique = arrayUnique b                       -- rc==1 peek (counted cell only; uncounted -> False)
  if unique:                                   -- MOVE (rc==1): 0 copy bytes
    dropAddr b                                 -- frees b exactly once (b given to C, freed at the boundary)
  else:                                        -- COPY (rc>1): len copy bytes
    copy = allocNBytes (bytesOf b)             -- fresh buffer modelling C's owned copy
    dropAddr copy                              -- frees the copy (models C freeing its owned buffer)
    dropAddr b                                 -- decrements b (wok keeps the original for the other holder)
  return csum
```

**The one linchpin the frontier task must verify first (Task 4, Step 1):** whether Perceus (`src/Wok/IR/Perceus.hs`) inserts its own drop for an `RForeignCall` `Bytes` argument, or whether the dispatch is the sole dropper (as the `memchr` arm implies). If Perceus also drops, the unmutated move already double-frees; if the dispatch is sole, the model above is complete. Resolve this against the real `memchr` behaviour before writing the `consume` arm.

---

## Task 0: `owned`-on-a-parameter grammar (`TOwned`) + BNFC regen

**Goal:** Add a `owned Type` type modifier so `consume : owned Bytes -> U64 with IO` parses, without breaking the existing member-leading `owned` (`FMOwned`).

**Files:**
- Modify: `grammar/Wok.cf` (add production near line 310; add a POST-REGEN NOTE near lines 60-64)
- Regenerate: `src-generated/GeneratedParser/Wok/Abs.hs` (+ Par.y, Lex.x, Layout.hs) via BNFC
- Reapply: the three documented manual post-regen patches (`grammar/Wok.cf:1-63`)

**Acceptance Criteria:**
- [ ] `grammar/Wok.cf` has `TOwned. Type2 ::= "owned" Type2 ;`
- [ ] BNFC regen produces `TOwned Type` in `data Type` (`Abs.hs`) with **zero** grammar conflicts
- [ ] The three manual post-regen patches are reapplied; a POST-REGEN NOTE for `TOwned` is added
- [ ] `cabal build exe:wok` succeeds; existing `foreign module` tests still parse (no regression on `FMOwned`)

**Verify:** `bnfc --haskell -d -o /tmp/bnfc-check grammar/Wok.cf 2>&1 | grep -i conflict` → no output (zero conflicts); then `cabal build exe:wok` → builds.

**Steps:**

- [ ] **Step 1: Add the production.** In `grammar/Wok.cf` near the `Type2` alternatives (after `TRowArg`, ~line 310), add:
```
TOwned.   Type2 ::= "owned" Type2 ;   -- FFI Slice 4: transfer-full argument modifier (owned Bytes)
```
- [ ] **Step 2: Conflict check BEFORE committing to regen.** Run:
```bash
bnfc --haskell -d -o /tmp/bnfc-check grammar/Wok.cf 2>&1 | grep -i conflict
```
Expected: no output. (`owned` is already a reserved keyword consumed by `FMOwned` before `:`; `TOwned` is only reachable after `:` inside a `Type`, a distinct LALR context — mirrors the `DExternData`/`DExternType` reasoning at `Wok.cf:60-64`.) If conflicts appear, STOP and escalate — the surface may need `owned` restricted to a dedicated foreign-type nonterminal.
- [ ] **Step 3: Regenerate** per `README.md:43`:
```bash
bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf
```
- [ ] **Step 4: Reapply the three mandatory manual patches** documented at `grammar/Wok.cf:1-63` (Layout.hs decl-separator fix; Par.y left-recursive `NEListRecordFieldPat`; Par.y empty-record-pattern rule). Then add a POST-REGEN NOTE near `Wok.cf:60-64` recording that `TOwned` needs no additional patch.
- [ ] **Step 5: Build.** `cabal build exe:wok` → succeeds.
- [ ] **Step 6: Commit.**
```bash
git add grammar/Wok.cf src-generated/
git commit -m "feat(ffi): owned-on-a-parameter grammar modifier (TOwned) for Slice 4 move-out"
```

```json:metadata
{"files": ["grammar/Wok.cf", "src-generated/GeneratedParser/Wok/Abs.hs"], "verifyCommand": "bnfc --haskell -d -o /tmp/bnfc-check grammar/Wok.cf 2>&1 | grep -i conflict; cabal build exe:wok", "acceptanceCriteria": ["TOwned production added", "zero grammar conflicts", "manual patches reapplied", "cabal build succeeds"], "modelTier": "standard"}
```

---

## Task 1: `MoveOut` transfer tag + blessed entry + `ForeignMemberInfo` threading

**Goal:** Carry a per-argument transfer marker from the surface `TOwned` into the blessed table and `ForeignMemberInfo`, and register the `("wok","consume")` blessed member.

**Files:**
- Modify: `src/Wok/FFI/Blessed.hs` (widen `BlessedSig`; add `ArgTransfer`/`MoveOut`; add `consume` entry)
- Modify: `src/Wok/TypeChecking/Env.hs:119-131` (`ForeignMemberInfo` gains `fmiArgTransfer`)
- Modify: `src/Wok/TypeChecking/Infer.hs:1303-1382` (`registerMember` records per-arg `MoveOut` from surface `TOwned`; coherence check)

**Acceptance Criteria:**
- [ ] `Blessed.hs`: `data ArgTransfer = TransferNone | MoveOut`; `BlessedSig` widened to `data BlessedSig = BlessedSig { bsReturn :: ReturnDisp, bsArgTransfer :: [ArgTransfer] }`; entry `((.."wok",.."consume"), BlessedSig DispScalar [MoveOut])`
- [ ] `ForeignMemberInfo` gains `fmiArgTransfer :: [ArgTransfer]`, set in `registerMember` by walking the surface `Abs.Type` arrow spine for `TOwned` occurrences
- [ ] A coherence check rejects `owned` (`TOwned`) on a non-`Bytes` parameter, or in a member with no blessed `MoveOut` position, with a clear `Error.hs` diagnostic (mirror `Infer.hs:1314-1371`)
- [ ] `cabal build exe:wok` succeeds; existing return-`owned` (`FMOwned`/`strndup`) path unchanged

**Verify:** `cabal build exe:wok` → builds; a `.wok` with `consume : owned Bytes -> U64 with IO` type-checks, and one with `owned U64` is rejected.

**Steps:**

- [ ] **Step 1: Widen `BlessedSig` and add the tag** in `src/Wok/FFI/Blessed.hs`. Change `newtype BlessedSig = BlessedSig { bsReturn :: ReturnDisp }` to:
```haskell
data ArgTransfer = TransferNone | MoveOut
  deriving (Eq, Show)

data BlessedSig = BlessedSig
  { bsReturn      :: ReturnDisp
  , bsArgTransfer :: [ArgTransfer]   -- ^ per-parameter; [] means all TransferNone (borrow-out)
  }
  deriving (Eq, Show)
```
Export `ArgTransfer (..)`. Update the three existing `blessedTable` entries to `BlessedSig <disp> []` (all-borrow-out), and add:
```haskell
, ((Tx.pack "wok", Tx.pack "consume"), BlessedSig DispScalar [MoveOut])
```
- [ ] **Step 2: Extend `ForeignMemberInfo`** in `src/Wok/TypeChecking/Env.hs:119-124`:
```haskell
data ForeignMemberInfo = ForeignMemberInfo
  { fmiScheme      :: Scheme
  , fmiSymbol      :: Text
  , fmiOwned       :: Bool
  , fmiArgTransfer :: [ArgTransfer]   -- ^ per-parameter transfer (FFI Slice 4); [] = all borrow-out
  }
  deriving (Eq, Show)
```
(Import `ArgTransfer` from `Wok.FFI.Blessed`.) Update every `ForeignMemberInfo { ... }` constructor site to set the new field.
- [ ] **Step 3: Record `TOwned` positions in `registerMember`** (`src/Wok/TypeChecking/Infer.hs:1303-1377`). Before `translateSig` strips modifiers, walk the surface `Abs.Type` arrow spine and emit one `ArgTransfer` per parameter (`MoveOut` where the parameter type is `Abs.TOwned _`, else `TransferNone`). Add a helper beside `finalReturnCType` (`Infer.hs:1379`):
```haskell
argTransfers :: Abs.Type -> [ArgTransfer]
argTransfers = go
  where
    go (Abs.TFun a rest)        = argOf a : go rest
    go (Abs.TWith a rest _)     = argOf a : go rest
    go _                        = []
    argOf (Abs.TOwned _)        = MoveOut
    argOf (Abs.TParen t)        = argOf t
    argOf _                     = TransferNone
```
Set `fmiArgTransfer = argTransfers ty` in the `minfo` record. Ensure `translateSig`/`typeToCType` tolerates `TOwned` by unwrapping it to its inner type (the modifier is metadata, not a distinct `CType`).
- [ ] **Step 4: Coherence check.** Alongside the existing `fmiOwned`/`DispBorrow` checks (`Infer.hs:1314-1371`), reject: (a) `MoveOut` on a parameter whose stripped type is not `Bytes`; (b) a member with a `TOwned` parameter that is not in the blessed table with a matching `MoveOut`. Add a diagnostic constructor to `src/Wok/TypeChecking/Error.hs` near lines 226-237 (mirror the disposition-mismatch messages), e.g. `ForeignOwnedArgNotBytes` / `ForeignOwnedArgNotBlessed`.
- [ ] **Step 5: Build + smoke.** `cabal build exe:wok`; hand-check that `consume : owned Bytes -> U64 with IO` type-checks and `bad : owned U64 -> U64 with IO` is rejected.
- [ ] **Step 6: Commit.**
```bash
git add src/Wok/FFI/Blessed.hs src/Wok/TypeChecking/Env.hs src/Wok/TypeChecking/Infer.hs src/Wok/TypeChecking/Error.hs
git commit -m "feat(ffi): MoveOut arg-transfer tag + blessed consume entry + fmiArgTransfer threading"
```

```json:metadata
{"files": ["src/Wok/FFI/Blessed.hs", "src/Wok/TypeChecking/Env.hs", "src/Wok/TypeChecking/Infer.hs", "src/Wok/TypeChecking/Error.hs"], "verifyCommand": "cabal build exe:wok", "acceptanceCriteria": ["ArgTransfer/MoveOut added and BlessedSig widened", "consume blessed entry present", "fmiArgTransfer set from surface TOwned", "coherence check rejects owned on non-Bytes param"], "modelTier": "standard"}
```

---

## Task 2: Thread `[ArgTransfer]` into the `RForeignCall` IR node

**Goal:** Add the per-argument transfer list to `RForeignCall` and thread it from elaboration, bumping every pattern-match site.

**Files:**
- Modify: `src/Wok/IR/Anf.hs:77-86` (add `[ArgTransfer]` field to `RForeignCall`)
- Modify: `src/Wok/IR/Elaborate.hs:408-434` (pass `bsArgTransfer bsig` / `fmiArgTransfer minfo` into the node)
- Modify (underscore bump only): `Anf.hs:167,296,545`; `IR/Reachable.hs:97,225`; `IR/Multiplicity.hs:181,205`; `IR/Escape.hs:193,627`; `Interp/Machine.hs:138`
- Modify (real logic, done in Task 4): `IR/Perceus.hs:215,1131,1170,1999`; `IR/ReusePairing.hs:202`; `Interp/RC/Machine.hs:378`

**Acceptance Criteria:**
- [ ] `RForeignCall` carries `[ArgTransfer]`; the standing comment at `Anf.hs:77-86` ("Task 6 will refine the borrow semantics of these args") is updated to reference this slice
- [ ] Every existing pattern-match site compiles (underscore-bumped where it ignores the field)
- [ ] Elaboration threads the real transfer list from the blessed sig / member info
- [ ] `cabal build` succeeds; no behavior change yet (the field is carried, not acted on until Task 4)

**Verify:** `cabal build` → builds with no warnings about incomplete `RForeignCall` patterns.

**Steps:**

- [ ] **Step 1: Add the field** at `Anf.hs:77`:
```haskell
| RForeignCall Text Text ReturnDisp [ArgTransfer] (Maybe Text) [Atom]
  -- ^ lib, symbol, return disposition, PER-ARG transfer (FFI Slice 4), free-symbol, args.
```
(Import `ArgTransfer` from `Wok.FFI.Blessed`.)
- [ ] **Step 2: Thread it in elaboration** (`Elaborate.hs:427-432`), extending the `RForeignCall` construction:
```haskell
k (RForeignCall (fmLib fmi) (fmiSymbol minfo) (bsReturn bsig)
                (bsArgTransfer bsig) (fmFree fmi) atoms)
```
(Use `bsArgTransfer bsig`; `fmiArgTransfer minfo` is the equivalent source if preferred — pick one and be consistent.)
- [ ] **Step 3: Underscore-bump the read-only sites.** At each of `Anf.hs:167,296,545`, `Reachable.hs:97,225`, `Multiplicity.hs:181,205`, `Escape.hs:193,627`, `Interp/Machine.hs:138`, change `RForeignCall _ _ _ _ as` to `RForeignCall _ _ _ _ _ as` (one extra wildcard for the new field). These analyses treat foreign args as ordinary sub-expressions — no logic change here.
- [ ] **Step 4: Placeholder-bump the Task-4 sites so the build stays green.** At `Perceus.hs:215,1131,1170,1999`, `ReusePairing.hs:202`, `Interp/RC/Machine.hs:378`, add the extra wildcard too (the real consuming-use / router logic lands in Task 4). Leave a `-- TODO(Slice4 Task4): MoveOut consuming-use` marker at the `ReusePairing.hs` and `Perceus.hs` sites.
- [ ] **Step 5: Build.** `cabal build` → succeeds.
- [ ] **Step 6: Commit.**
```bash
git add src/Wok/IR/ src/Wok/Interp/Machine.hs
git commit -m "feat(ffi): carry [ArgTransfer] on RForeignCall + thread from elaboration"
```

```json:metadata
{"files": ["src/Wok/IR/Anf.hs", "src/Wok/IR/Elaborate.hs", "src/Wok/IR/Reachable.hs", "src/Wok/IR/Multiplicity.hs", "src/Wok/IR/Escape.hs", "src/Wok/Interp/Machine.hs"], "verifyCommand": "cabal build", "acceptanceCriteria": ["RForeignCall carries [ArgTransfer]", "all pattern sites compile", "elaboration threads the real list"], "modelTier": "standard"}
```

---

## Task 3: The pure-read checksum consumer (C + Haskell FNV-1a reference)

**Goal:** Provide `wok_bytes_consume_checksum` (C, pure-read FNV-1a) plus a byte-identical Haskell reference for the abstract and pure backends. Independent of Tasks 0-2.

**Files:**
- Modify: `runtime/wok_rc.h` (declare, after line 140)
- Modify: `runtime/wok_rc.c` (define, after `wok_bytes_byte_get` ~line 1213)
- Modify: `src/Wok/Interp/RC/Heap.hs:61-64` (`foreign import ccall`)
- Modify: `src/Wok/Interp/ForeignModels.hs` (export `referenceFNV1a`)
- Modify: `src/Wok/Interp/Machine.hs:149-178` (reference-interp `consume` arm)

**Acceptance Criteria:**
- [ ] `wok_bytes_consume_checksum(const WokObj*)` computes 64-bit FNV-1a over the cell's bytes; does not free or mutate
- [ ] `referenceFNV1a :: ByteString -> Word64` in Haskell produces byte-identical results
- [ ] The reference interpreter models `("wok","consume")` as `referenceFNV1a` over the arg bytes (mirroring the `lendBuffer` model at `Machine.hs:167-177`)
- [ ] `cabal build` succeeds; a unit test asserts C and Haskell agree on a fixed vector (e.g. `[0x00,0x01,0x02]`)

**Verify:** `cabal build` then a `cabal test` case asserting `wokBytesConsumeChecksum` over a known buffer equals `referenceFNV1a` of the same bytes.

**Steps:**

- [ ] **Step 1: C declaration** in `runtime/wok_rc.h` after line 140:
```c
/* Pure-read FNV-1a (64-bit) over the cell's bytes. Does NOT free or mutate. (FFI Slice 4) */
uint64_t wok_bytes_consume_checksum(const WokObj* cell);
```
- [ ] **Step 2: C definition** in `runtime/wok_rc.c` after `wok_bytes_byte_get` (~line 1213):
```c
uint64_t wok_bytes_consume_checksum(const WokObj* cell) {
    assert((uint32_t)cell->tag == WOK_BYTES_TAG);
    uint64_t h = 0xcbf29ce484222325ULL;              /* FNV-1a offset basis */
    uint64_t len = wok_bytes_len(cell);
    const uint8_t* data = wok_bytes_data((WokObj*)cell);
    for (uint64_t i = 0; i < len; i++) { h ^= data[i]; h *= 0x100000001b3ULL; }
    return h;
}
```
- [ ] **Step 3: Haskell foreign import** in `src/Wok/Interp/RC/Heap.hs` after line 64:
```haskell
foreign import ccall unsafe "wok_bytes_consume_checksum"
  wokBytesConsumeChecksum :: Ptr WokObj -> IO Word64
```
- [ ] **Step 4: Haskell reference** — add to `src/Wok/Interp/ForeignModels.hs` (and export):
```haskell
referenceFNV1a :: ByteString -> Word64
referenceFNV1a = BS.foldl' step 0xcbf29ce484222325
  where step h b = (h `Data.Bits.xor` fromIntegral b) * 0x100000001b3
```
- [ ] **Step 5: Reference-interp arm** in `src/Wok/Interp/Machine.hs` `evalForeignCall` (~line 167, beside the `lendBuffer` model): for `(lib,sym) == ("wok","consume")` with a `VBytes bs` arg, return `VInt (fromIntegral (referenceFNV1a bs))`. Keep the "so all three backends agree" comment.
- [ ] **Step 6: Cross-check test.** Add a small `cabal test` case (in the Bytes suite, `test/Spec.hs` near the E6 property block ~24416) asserting: allocate a `WokBytes` of `[0,1,2,3,255]`, call `wokBytesConsumeChecksum`, assert `== referenceFNV1a (BS.pack [0,1,2,3,255])`.
- [ ] **Step 7: Commit.**
```bash
git add runtime/wok_rc.h runtime/wok_rc.c src/Wok/Interp/RC/Heap.hs src/Wok/Interp/ForeignModels.hs src/Wok/Interp/Machine.hs test/Spec.hs
git commit -m "feat(ffi): pure-read wok_bytes_consume_checksum + byte-identical Haskell FNV-1a reference"
```

```json:metadata
{"files": ["runtime/wok_rc.h", "runtime/wok_rc.c", "src/Wok/Interp/RC/Heap.hs", "src/Wok/Interp/ForeignModels.hs", "src/Wok/Interp/Machine.hs", "test/Spec.hs"], "verifyCommand": "cabal test --test-options='-p checksum'", "acceptanceCriteria": ["C FNV-1a consumer added (pure-read)", "Haskell referenceFNV1a byte-identical", "reference-interp consume arm", "C==Haskell cross-check test passes"], "modelTier": "mechanical"}
```

---

## Task 4: The rc==1 move/copy router + accounting + FBIP consuming-use (SOUNDNESS CORE)

**Goal:** Implement the `("wok","consume")` RC dispatch arm as the move/copy router, with the FBIP/reuse pass treating a `MoveOut` arg as a consuming use, so `Sink.consume b` runs correctly on all three backends and the accounting balances.

**Files:**
- Modify: `src/Wok/Interp/RC/Machine.hs:521-545` (add the `consume` dispatch arm beside `symLendBuffer`; `allocResult` scalar return)
- Modify: `src/Wok/Interp/RC/Prim.hs` (the abstract-backend consume helper, mirroring `allocBorrowDemoLend:1600`)
- Modify: `src/Wok/IR/Perceus.hs` and `src/Wok/IR/ReusePairing.hs:202` (MoveOut = consuming/terminal use)

**Acceptance Criteria:**
- [ ] `Sink.consume b` returns `referenceFNV1a`(b's bytes) on pure-interp, RC-abstract, and RC-CHeap — identical
- [ ] Move (rc==1): 0 copy bytes, the buffer freed exactly once (`stAllocs`/`stFrees` balance, `stLive == 0`)
- [ ] Copy (rc>1): a fresh buffer allocated (+`length b` copy bytes) and freed; the original decremented and still readable as its bytes
- [ ] The reuse pass never pairs a `MoveOut` cell for in-place reuse
- [ ] `scripts/asan-runtime.sh interp` runs the positive `consume` corpus clean (no leak, no double-free)

**Verify:** `cabal test` (the new `test/rc-ffi-owned/` oracle cases pass) and `scripts/asan-runtime.sh interp` (positive corpus clean).

**Steps:**

- [ ] **Step 1 (LINCHPIN — do first): Resolve the Perceus drop question.** Read `src/Wok/IR/Perceus.hs` at the `RForeignCall` sites (215, 1131, 1170, 1999) and confirm against the working `memchr` arm whether Perceus inserts a drop for a foreign-call `Bytes` arg or the dispatch is the sole dropper. Write the finding as a comment. The router in Step 3 assumes **the dispatch is the sole dropper**; if Perceus also drops, add the suppression here (make `MoveOut` args not receive a Perceus drop) so exactly one free occurs.
- [ ] **Step 2: FBIP consuming-use.** In `src/Wok/IR/ReusePairing.hs:202` (and the relevant `Perceus.hs` sites), mark a `MoveOut` argument as a consuming/terminal use so `reusePairing` cannot pair the cell for in-place reuse. Follow the existing "consuming use" treatment the pass already applies to constructor args.
- [ ] **Step 3: The dispatch arm** in `src/Wok/Interp/RC/Machine.hs`, beside `symLendBuffer` (~530), add `symConsume = Tx.pack "consume"` to the `where` clause and an arm implementing the model in "Implementation model" above:
```haskell
| lib == libWok, sym == symConsume =
    case vs of
      [RVBox bAddr] -> do
        csum   <- consumeChecksum bAddr s        -- pure read (Task 3 helper), returns Word64
        unique <- arrayUnique bAddr s
        s1 <- if unique
                then dropAddr bAddr s              -- MOVE: free the original once
                else do                            -- COPY: fresh buffer for C, freed; original decremented
                  (copyAddr, sC) <- copyBytesCell bAddr s
                  sC1 <- dropAddr copyAddr sC
                  dropAddr bAddr sC1
        cont (RVLit (LInt (fromIntegral csum))) s1
      _ -> throwE (PrimError (Tx.pack "consume (RC): expected (owned Bytes)"))
```
where `copyBytesCell` reads b's bytes (`H.wokBytesData`/`wokBytesLen`) and `allocNBytes` (`Value.hs:1999`) a fresh cell of the same bytes (this is the `length b` copy-bytes charge that P6 pins). `consumeChecksum` is the CHeap/AbstractHeap helper from Step 4.
- [ ] **Step 4: The backend-split checksum helper** in `src/Wok/Interp/RC/Prim.hs`, mirroring `allocBorrowDemoLend:1600`:
```haskell
consumeChecksum :: Addr -> Store -> RC Word64
consumeChecksum a s = case stBackend s of
  CHeap _      -> case a of
    CAddr p -> liftIO (H.wokBytesConsumeChecksum p)
    _       -> referenceFNV1a <$> readBytesPure a s   -- inline/rare
  AbstractHeap -> referenceFNV1a <$> readBytesPure a s
```
(`readBytesPure` extracts the `NBytes` payload from an abstract addr — reuse the existing abstract-bytes accessor.)
- [ ] **Step 5: Corpus.** Create `test/rc-ffi-owned/00-consume-unique.wok` (`Sink.consume` as the buffer's only use) and `01-consume-shared.wok` (buffer reused after consume). Wire them into `test/Spec.hs` (mirror `Spec.hs:472` `testGroup "rc-ffi-foreign"` and the `findByExtension` at 176). Assert 3-backend parity + the stat expectations (move: `stAllocs==stFrees`, 0 copy; shared: original readable).
- [ ] **Step 6: ASan positive.** Add `test/rc-ffi-owned/*.wok` (non-death) to the `asan-runtime.sh interp` positive loop (script lines 82-95) and confirm clean.
- [ ] **Step 7: Build + test + ASan.** `cabal build && cabal test` and `scripts/asan-runtime.sh interp`.
- [ ] **Step 8: Commit.**
```bash
git add src/Wok/Interp/RC/Machine.hs src/Wok/Interp/RC/Prim.hs src/Wok/IR/Perceus.hs src/Wok/IR/ReusePairing.hs test/rc-ffi-owned/ test/Spec.hs scripts/asan-runtime.sh
git commit -m "feat(ffi): rc==1 move/copy router for owned-INTO-C consume + FBIP consuming-use"
```

```json:metadata
{"files": ["src/Wok/Interp/RC/Machine.hs", "src/Wok/Interp/RC/Prim.hs", "src/Wok/IR/Perceus.hs", "src/Wok/IR/ReusePairing.hs", "test/rc-ffi-owned/00-consume-unique.wok", "test/rc-ffi-owned/01-consume-shared.wok", "test/Spec.hs"], "verifyCommand": "cabal test && scripts/asan-runtime.sh interp", "acceptanceCriteria": ["3-backend checksum parity for consume", "move: 0 copy bytes freed once; balance", "copy: fresh buffer freed + original decremented and readable", "reuse pass treats MoveOut as consuming", "ASan positive corpus clean"], "modelTier": "frontier"}
```

---

## Task 5: QuickCheck property suite (P1–P7)

**Goal:** Property-test the move-out scope over random `Bytes` on the differential oracle (the repo's first `monadicIO` usage), plus the two named demos.

**Files:**
- Modify: `test/Spec.hs` (new `testGroup "FFI Slice 4: owned-INTO-C properties"`, near the E6 Bytes property suite ~24416)
- Create: `test/rc-ffi-owned/consumeOwned.wok`, `test/rc-ffi-owned/consumeShared.wok` (readable fixed-input demos)

**Acceptance Criteria:**
- [ ] `genBytes :: Gen [Word8]` with `resize`d length (empty, small, multi-KB)
- [ ] P1 parity, P2 semantic (`== referenceFNV1a`), P3 branch-invariance (move==copy result), P4 copy fidelity + original intact, P5 accounting balance (`stAllocs==stFrees`, `stLive==0`), P6 saving (0 vs `len`), P7 multi-consume — all as `testProperty`
- [ ] The oracle is driven inside the property via `QC.ioProperty`/`monadicIO` calling `withBothBackends` (`Spec.hs:13392`) plus the pure reference interpreter
- [ ] `cabal test` green

**Verify:** `cabal test --test-options='-p "owned-INTO-C"'` → all properties pass.

**Steps:**

- [ ] **Step 1: Generator + reference.** In `test/Spec.hs`, add `genBytes = BS.pack <$> resize 4096 (listOf arbitrary)` and reuse `referenceFNV1a` (import from `ForeignModels`).
- [ ] **Step 2: The oracle runner.** Write a helper that, given a `.wok` template string and `bs`, materializes a temp program (or parameterizes an existing one), runs it on the pure reference interp, RC-abstract, and RC-CHeap, and returns `(refChecksum, absChecksum, cheapChecksum, absStats, cheapStats)`. Reuse `withBothBackends` (`Spec.hs:13392`) for the two RC backends and the `IM` reference path (`Spec.hs:51`). Wrap in `QC.ioProperty`.
- [ ] **Step 3: Properties P1–P7.** Each a `testProperty` over `genBytes` asserting the §9.1 invariant. For P3, run both the unique and shared templates and assert equal checksums; for P6, assert `cheapStats` copy-bytes `== 0` (unique) and `== BS.length bs` (shared); for P5, `stAllocs == stFrees && stLive == 0`; for P7, generate `n <- choose (1,4)` owned args.
- [ ] **Step 4: The two demos.** Add `consumeOwned.wok`/`consumeShared.wok` as fixed-input readable oracle cases (also referenced from the plan's §9.3 corpus).
- [ ] **Step 5: Build + test.** `cabal test`.
- [ ] **Step 6: Commit.**
```bash
git add test/Spec.hs test/rc-ffi-owned/consumeOwned.wok test/rc-ffi-owned/consumeShared.wok
git commit -m "test(ffi): QuickCheck property suite P1-P7 for owned-INTO-C move-out"
```

```json:metadata
{"files": ["test/Spec.hs", "test/rc-ffi-owned/consumeOwned.wok", "test/rc-ffi-owned/consumeShared.wok"], "verifyCommand": "cabal test --test-options='-p \"owned-INTO-C\"'", "acceptanceCriteria": ["genBytes generator + referenceFNV1a", "P1-P7 as testProperty over random Bytes", "oracle driven via ioProperty/withBothBackends + reference interp", "cabal test green"], "modelTier": "standard"}
```

---

## Task 6: The death-test matrix (mutation-confirmed under ASan)

**Goal:** Prove the router's soundness guards are load-bearing — double-free, use-after-move, and region-double-move each fault under ASan only when a mutation defeats the guard, and are clean otherwise.

> **USER-ORDERED GATE — NON-SKIPPABLE.** This task was requested by the user in the current conversation ("Run-the-exploit death-tests are mandatory and must genuinely bite"). It MUST NOT be closed by walking around it, by declaring it "verified inline", or by substituting a cheaper check. Close only after every item in `acceptanceCriteria` has been re-validated independently, with output captured.

**Files:**
- Modify: `wok.cabal` (a new `flag ffi-owned-noguard-negctrl`, mirroring `ffi-noclamp-negctrl:31`)
- Modify: `src/Wok/Interp/RC/Machine.hs` (CPP-gated mutation of the `consume` router under the flag)
- Create: `test/rc-ffi-owned/death-double-free.wok`, `death-use-after-move.wok`, `death-region-double-move.wok`
- Modify: `scripts/asan-runtime.sh` (a negative-control loop, mirroring lines 108-117 / 144-155)

**Acceptance Criteria:**
- [ ] **Double-free:** with the mutation flag on, a shared consume double-frees the buffer → ASan aborts nonzero; flag off → clean
- [ ] **Use-after-move:** with the mutation on (force move when rc>1), the sibling's later **C read** (an ASan-instrumented read — NOT `peekElemOff`) after the free → ASan use-after-free; flag off → clean
- [ ] **Region double-move:** a `MoveOut` on a `Bytes` reachable through an R1 region; unmutated copies (`arenaClose` sole free); mutated forces the move → ASan double-free; flag off → clean
- [ ] Each control is non-vacuous: the mutated read/free genuinely touches freed memory (verified by the ASan report naming the free + the access)
- [ ] `scripts/asan-runtime.sh interp` runs the full matrix: positive clean, each negative control faults under its flag

**Verify:** `scripts/asan-runtime.sh interp` → positive corpus clean; each `-fffi-owned-noguard-negctrl` build faults on its death `.wok` with a nonzero exit and an ASan use-after-free / double-free report.

**Steps:**

- [ ] **Step 1: The mutation flag.** Add to `wok.cabal` (near line 31):
```
flag ffi-owned-noguard-negctrl
  description: Mutation control: defeat the owned-INTO-C router guard for ASan death-tests. NEVER in production.
  default: False
  manual: True
```
Gate the corresponding CPP symbol in the `asan`/test stanza (mirror `WOK_FFI_NOCLAMP_NEGCTRL`).
- [ ] **Step 2: The CPP-gated mutations** in `src/Wok/Interp/RC/Machine.hs` `consume` arm. Under `#ifdef WOK_FFI_OWNED_NOGUARD_NEGCTRL`, replace the router with the force-move variant (always `dropAddr bAddr`, never copy) — this force-move-when-shared produces use-after-move on a sibling read and double-free on a sibling drop. Keep the unmutated path under `#else`.
- [ ] **Step 3: Death programs.** `death-use-after-move.wok`: build a shared `Bytes`, `Sink.consume` it, then read it via a C call (e.g. `Libc.memchr` — ASan-instrumented) → under the mutation, reads freed memory. `death-double-free.wok`: shared consume then let the sibling drop at scope end → double-free under the mutation. `death-region-double-move.wok`: a `MoveOut` on a region-reachable `Bytes` → under the mutation the move + `arenaClose` double-free.
- [ ] **Step 4: ASan wiring.** In `scripts/asan-runtime.sh`, add a negative-control loop (mirror lines 108-117 / 144-155): rebuild `cabal build -fasan -fffi-owned-noguard-negctrl exe:wok`, run each `test/rc-ffi-owned/death-*.wok`, assert nonzero exit + an ASan report. Confirm the unmutated build runs them clean (they must be well-typed, non-faulting without the mutation).
- [ ] **Step 5: Non-vacuity check.** Capture each ASan report and confirm it names the buffer free and the offending access (a report that fires on unrelated memory, or a `peekElemOff` read that ASan does not instrument, is a vacuous control — a test bug; fix it).
- [ ] **Step 6: Run the full matrix + capture output.** `scripts/asan-runtime.sh interp`, capturing the positive-clean and each negative-fault output.
- [ ] **Step 7: Commit.**
```bash
git add wok.cabal src/Wok/Interp/RC/Machine.hs test/rc-ffi-owned/death-*.wok scripts/asan-runtime.sh
git commit -m "test(ffi): mutation-confirmed ASan death-test matrix (double-free/UAM/region) for owned-INTO-C"
```

```json:metadata
{"files": ["wok.cabal", "src/Wok/Interp/RC/Machine.hs", "test/rc-ffi-owned/death-double-free.wok", "test/rc-ffi-owned/death-use-after-move.wok", "test/rc-ffi-owned/death-region-double-move.wok", "scripts/asan-runtime.sh"], "verifyCommand": "scripts/asan-runtime.sh interp", "acceptanceCriteria": ["double-free faults under the flag, clean without", "use-after-move faults via an ASan-instrumented C read, clean without", "region-double-move faults under the flag, clean without", "each control is non-vacuous (ASan names the free + access)", "positive corpus clean"], "modelTier": "standard", "userGate": true, "tags": ["user-gate"], "requiresUserSpecification": false, "requireEvidenceTokens": [["mutated", "flag-on", "-fffi-owned-noguard-negctrl"], ["unmutated", "flag-off", "clean"]]}
```

---

## Task dependency graph

- Task 1 blockedBy Task 0
- Task 2 blockedBy Task 1
- Task 3 blockedBy (none — independent C + Haskell reference)
- Task 4 blockedBy Task 2, Task 3
- Task 5 blockedBy Task 4
- Task 6 blockedBy Task 4

## Self-review notes

- **Spec coverage:** §6.1 surface → Task 0/1; §6.2 tag → Task 1; §7.1 router → Task 4; §7.2 drop-suppression/FBIP → Task 4 (Steps 1-3); §7.3 representation → Task 4 (copyBytesCell); §7.4 consumer → Task 3; §7.5 checksum → Task 3; §7.6 accounting → Task 4; §9.1 properties → Task 5; §9.2 death-tests → Task 6; §9.3 corpus → Tasks 4/5/6. §10 codegen is future-work (no task). All in-scope §4 items covered.
- **Key judgment call** (Task 4 Step 1): the Perceus drop-ownership question — flagged as the linchpin, resolved before the router is written.
- **First-of-its-kind:** `monadicIO` (Task 5) is the repo's first; the plan points at `withBothBackends` + the pure `Gen` property suites as the shapes to combine.
