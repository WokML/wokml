# String Slice E5 (half 1) — Codepoint Iteration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add O(n), effect-sound codepoint iteration to wok strings — `foldChars` (wok library code) over two first-order decode primitives, plus `singleton` — with no machine-core change.

**Architecture:** Decompose iteration into (1) first-order prims `decodeCharAt`/`charWidthAt` that handle ONE codepoint at a byte offset, and (2) `foldChars` written as an ordinary recursive wok function. The wok loop's progress lives in the real continuation, so effectful fold closures are captured by the existing machinery — zero new continuation surface. Both interpreters (reference + RC) get the prims; correctness is pinned by absolute run-goldens (the differential oracle alone is blind to bugs in the shared `foldChars` wok code).

**Tech Stack:** Haskell (GHC), wok interpreter (CEK abstract machine + RC/Perceus twin), tasty/HUnit/tasty-golden tests, cabal.

**User decisions (already made):**
- Scope = `foldChars` + `singleton` only (codepoint iteration). "Yes for 1."
- DECOMPOSE into first-order prims + a wok driver; do NOT build the rejected "prim-calls-closure machine frame." (The big course-correction.)
- No string builder / in-place mutation / "pre-size output" — deferred; not needed for iteration ("we don't need a string buffer for map").
- Keep names `decodeCharAt`/`charWidthAt` (byte-offset), and the minimal `eqU64`-tiling termination (no `ltU64` added). "Good" (my leans accepted).
- `chars`/`fromChars`, the fusable stream layer, and the list-representation discussion are deferred to a separate session.

Spec: `docs/superpowers/specs/2026-06-27-string-slice-e5-design.md`. Visual: `docs/string-codepoint-iteration.html`.

**Build:** `cabal build` · **Test:** `cabal test wok-tests` · subset: `cabal test wok-tests --test-options='-p "<pattern>"'`

---

## File Structure

- `src/Wok/Interp/Utf8.hs` — NEW. Pure UTF-8 single-codepoint decode helpers (machine-agnostic).
- `src/Wok/IR/PrimNames.hs` — 3 new `(Std.String, name)` prim names.
- `src/Wok/Interp/RC/Prim.hs` — RC implementations of the 3 prims + register in `rcStringPrims`.
- `src/Wok/Interp/Prim.hs` — reference implementations + register in `stringPrims`.
- `prelude/Std/String.wok` — 3 `extern`s + `foldChars`/`foldCharsGo`.
- `wok.cabal` — add `Wok.Interp.Utf8` to the library's exposed/other-modules.
- `test/rc-string-fold/*.wok` — NEW dir: functional + decode + effect death-test programs.
- `test/rc-string-oob/*.wok` — OOB / non-boundary error programs.
- `test/run-golden/*.expected` — absolute expected outputs (generated via `--accept`, then verified).
- `test/Spec.hs` — wire `test/rc-string-fold` into rc-differential + rc-stats + rcCBackendParity + run-golden.

---

### Task 1: Pure UTF-8 decode helpers

**Goal:** A pure, machine-agnostic module that decodes one UTF-8 codepoint at a byte index and reports its width, rejecting non-boundary offsets.

**Files:**
- Create: `src/Wok/Interp/Utf8.hs`
- Modify: `wok.cabal` (add `Wok.Interp.Utf8` to the library `other-modules` / `exposed-modules`, wherever `Wok.Interp.Prim` is listed)

**Acceptance Criteria:**
- [ ] `utf8Width :: Word8 -> Either RuntimeError Int` returns 1/2/3/4 for lead bytes; `Left` for a continuation byte (0x80–0xBF) and for an invalid lead (≥0xF8).
- [ ] `decodeCharAt :: ByteString -> Int -> Either RuntimeError (Char, Int)` returns `(codepoint, width)` for a valid lead at index `i`, `Left` if the byte at `i` is a continuation byte. O(1) (reads only the lead + its continuation bytes).
- [ ] `cabal build` succeeds.

**Verify:** `cabal build` → compiles with no errors.

**Steps:**

- [ ] **Step 1: Create the module.**

```haskell
module Wok.Interp.Utf8
  ( utf8Width
  , decodeCharAt
  ) where

import Data.Bits ((.&.), (.|.), shiftL)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Char (chr)
import qualified Data.Text as Tx
import Data.Word (Word8)
import Wok.Interp.Value (RuntimeError (PrimError))

-- | Byte width (1..4) implied by a UTF-8 lead byte. 'Left' on a continuation
-- byte (0x80..0xBF) -- i.e. not a codepoint boundary -- or an invalid lead.
utf8Width :: Word8 -> Either RuntimeError Int
utf8Width b
  | b < 0x80  = Right 1
  | b < 0xC0  = Left (PrimError (Tx.pack "utf8: byte offset is not a codepoint boundary"))
  | b < 0xE0  = Right 2
  | b < 0xF0  = Right 3
  | b < 0xF8  = Right 4
  | otherwise = Left (PrimError (Tx.pack "utf8: invalid lead byte"))

-- | Decode the single codepoint whose UTF-8 encoding begins at byte index @i@.
-- Returns @(codepoint, byteWidth)@. O(1). 'Left' if the byte at @i@ is itself a
-- continuation byte (not a boundary). The caller guarantees @0 <= i < length@;
-- the String invariant (valid UTF-8) guarantees the continuation bytes at
-- @i+1..@ exist. Single lead-byte dispatch lives in 'utf8Width' (DRY).
decodeCharAt :: ByteString -> Int -> Either RuntimeError (Char, Int)
decodeCharAt bs i = do
  let b0 = BS.index bs i
  w <- utf8Width b0
  let cont k = fromIntegral (BS.index bs (i + k) .&. 0x3F) :: Int
      cp = case w of
        1 -> fromIntegral b0
        2 -> (fromIntegral (b0 .&. 0x1F) `shiftL` 6)  .|. cont 1
        3 -> (fromIntegral (b0 .&. 0x0F) `shiftL` 12) .|. (cont 1 `shiftL` 6) .|. cont 2
        _ -> (fromIntegral (b0 .&. 0x07) `shiftL` 18) .|. (cont 1 `shiftL` 12)
                                                      .|. (cont 2 `shiftL` 6)  .|. cont 3
  Right (chr cp, w)
```

- [ ] **Step 2: Register the module in `wok.cabal`.** Find the library stanza listing `Wok.Interp.Prim` / `Wok.Interp.RC.Prim` and add `Wok.Interp.Utf8` alongside (same `exposed-modules`/`other-modules` list).

- [ ] **Step 3: Build.**

Run: `cabal build`
Expected: success, no errors. (`Wok.Interp.Value` exports `RuntimeError(..)` incl. `PrimError`; confirm the import resolves.)

- [ ] **Step 4: Commit.**

```bash
git add src/Wok/Interp/Utf8.hs wok.cabal
git commit -m "feat(string): pure UTF-8 single-codepoint decode helpers (E5 Task 1)"
```

```json:metadata
{"files": ["src/Wok/Interp/Utf8.hs", "wok.cabal"], "verifyCommand": "cabal build", "acceptanceCriteria": ["utf8Width returns 1-4 for leads, Left for continuation/invalid", "decodeCharAt returns (codepoint,width), Left at a continuation byte", "cabal build succeeds"], "modelTier": "mechanical"}
```

---

### Task 2: The three primitives (both machines)

**Goal:** Register `decodeCharAt`, `charWidthAt`, `singleton` as `(Std.String, name)` primitives in BOTH the reference and RC interpreters, decoding via the Task-1 helpers.

**Files:**
- Modify: `src/Wok/IR/PrimNames.hs` (3 names + exports)
- Modify: `src/Wok/Interp/RC/Prim.hs` (3 RC prims + `rcStringPrims`)
- Modify: `src/Wok/Interp/Prim.hs` (3 reference prims + `stringPrims`)

**Acceptance Criteria:**
- [ ] `PrimNames.hs` exports `decodeCharAtName`, `charWidthAtName`, `singletonName` (each `Tx.pack "<name>"`).
- [ ] RC + reference each define the 3 prims and add them to `rcStringPrims` / `stringPrims`.
- [ ] Decode/width consume the string argument (RC: `dropAddr`) exactly like `stringByteAt`; `singleton` allocates via `alloc (NString …)` (inlines for ≤7 bytes); the `Char` arg/result are immediates.
- [ ] `cabal build` succeeds.

**Verify:** `cabal build` → compiles. (Behavioural verification lands in Task 4–5.)

**Steps:**

- [ ] **Step 1: Add prim names to `src/Wok/IR/PrimNames.hs`.** Next to `stringSliceName` (and its export near line 72), add:

```haskell
decodeCharAtName :: Text
decodeCharAtName = Tx.pack "decodeCharAt"

charWidthAtName :: Text
charWidthAtName = Tx.pack "charWidthAt"

singletonName :: Text
singletonName = Tx.pack "singleton"
```

Add `decodeCharAtName`, `charWidthAtName`, `singletonName` to the module export list.

- [ ] **Step 2: Add RC prims to `src/Wok/Interp/RC/Prim.hs`.** Import the helpers (top of file): `import qualified Wok.Interp.Utf8 as Utf8`. Model offset-resolution + the bounds check EXACTLY on `stringByteAt` (RC/Prim.hs:789–824) — use the identical index helper it uses (it rejects negatives; the snippet below names it `asStringIndex` — match whatever `stringByteAt` actually calls). Add:

```haskell
decodeCharAtRC :: RCPrim
decodeCharAtRC = RCPrim PN.decodeCharAtName 2 [] $ \args s -> case args of
  [sv@(RVBox a), iv] -> do
    bs <- stringBytes sv s
    i  <- asStringIndex iv   -- same helper stringByteAt uses; rejects negative
    if i >= BS.length bs
      then throwE (PrimError (Tx.pack "String.decodeCharAt: out of bounds"))
      else do
        (c, _w) <- liftRC (Utf8.decodeCharAt bs i)
        s1 <- dropAddr a s
        pure (PRDone (RVLit (LChar c)), s1)
  _ -> throwE (ArityError PN.decodeCharAtName)

charWidthAtRC :: RCPrim
charWidthAtRC = RCPrim PN.charWidthAtName 2 [] $ \args s -> case args of
  [sv@(RVBox a), iv] -> do
    bs <- stringBytes sv s
    i  <- asStringIndex iv
    if i >= BS.length bs
      then throwE (PrimError (Tx.pack "String.charWidthAt: out of bounds"))
      else do
        w  <- liftRC (Utf8.utf8Width (BS.index bs i))
        s1 <- dropAddr a s
        pure (PRDone (RVLit (LInt (toInteger w))), s1)
  _ -> throwE (ArityError PN.charWidthAtName)

singletonRC :: RCPrim
singletonRC = RCPrim PN.singletonName 1 [] $ \args s -> case args of
  [RVLit (LChar c)] -> do
    let bs = TxEnc.encodeUtf8 (Tx.singleton c)
    (na, s1) <- alloc (NString bs) s
    pure (PRDone (RVBox na), s1)
  _ -> throwE (ArityError PN.singletonName)
```

Add `decodeCharAtRC, charWidthAtRC, singletonRC` to the `rcStringPrims` list (RC/Prim.hs:100–101). Confirm `liftRC :: Either RuntimeError a -> RC a` is the module idiom (NOT `liftEither`); if the exact name differs, use whatever lifts `Either RuntimeError` into `RC` in this file.

- [ ] **Step 3: Add reference prims to `src/Wok/Interp/Prim.hs`.** Import `import qualified Wok.Interp.Utf8 as Utf8`. Model on `stringByteAtP` (Prim.hs:477) — strings are `VLit (LStr t)`, offset via `asU64Index`. Add:

```haskell
decodeCharAtP :: Prim
decodeCharAtP = mkPrim PN.decodeCharAtName 2 $ \args -> case args of
  [VLit (LStr t), iv] -> do
    i <- asU64Index iv
    let bs = TxEnc.encodeUtf8 t
    if i >= BS.length bs
      then Left (PrimError (Tx.pack "String.decodeCharAt: out of bounds"))
      else do
        (c, _w) <- Utf8.decodeCharAt bs i
        Right (PRDone (VLit (LChar c)))
  [v, _] -> Left (PrimError (Tx.pack "String.decodeCharAt: not a string: " <> renderValue v))
  _      -> Left (ArityError PN.decodeCharAtName)

charWidthAtP :: Prim
charWidthAtP = mkPrim PN.charWidthAtName 2 $ \args -> case args of
  [VLit (LStr t), iv] -> do
    i <- asU64Index iv
    let bs = TxEnc.encodeUtf8 t
    if i >= BS.length bs
      then Left (PrimError (Tx.pack "String.charWidthAt: out of bounds"))
      else do
        w <- Utf8.utf8Width (BS.index bs i)
        Right (PRDone (VLit (LInt (fromIntegral w))))
  [v, _] -> Left (PrimError (Tx.pack "String.charWidthAt: not a string: " <> renderValue v))
  _      -> Left (ArityError PN.charWidthAtName)

singletonP :: Prim
singletonP = mkPrim PN.singletonName 1 $ \args -> case args of
  [VLit (LChar c)] -> Right (PRDone (VLit (LStr (Tx.singleton c))))
  _                -> Left (ArityError PN.singletonName)
```

Add `decodeCharAtP, charWidthAtP, singletonP` to the `stringPrims` list (Prim.hs:76).

- [ ] **Step 4: Build.**

Run: `cabal build`
Expected: success. Both `(Std.String, "decodeCharAt")` etc. now resolve in both prim tables.

- [ ] **Step 5: Commit.**

```bash
git add src/Wok/IR/PrimNames.hs src/Wok/Interp/RC/Prim.hs src/Wok/Interp/Prim.hs
git commit -m "feat(string): decodeCharAt/charWidthAt/singleton prims, both machines (E5 Task 2)"
```

```json:metadata
{"files": ["src/Wok/IR/PrimNames.hs", "src/Wok/Interp/RC/Prim.hs", "src/Wok/Interp/Prim.hs"], "verifyCommand": "cabal build", "acceptanceCriteria": ["3 prim names exported", "RC + reference prims defined and registered", "decode/width consume the string; singleton allocs inline", "cabal build succeeds"], "modelTier": "standard"}
```

---

### Task 3: `Std.String` surface — `foldChars` + `singleton`

**Goal:** Expose the prims and define `foldChars` as effect-polymorphic wok library code, terminating via `eqU64`-tiling.

**Files:**
- Modify: `prelude/Std/String.wok`

**Acceptance Criteria:**
- [ ] Three `extern`s declared (`decodeCharAt`, `charWidthAt`, `singleton`).
- [ ] `foldChars`/`foldCharsGo` defined with the effect-polymorphic signature; a PURE program (`e` = empty) AND an effectful one (`e = Emit`) both typecheck and run.
- [ ] `foldChars`-counts-length on `"hello"` returns `5`, and on `"café€"` returns `5` (multibyte width handled), on the reference machine.

**Verify:** `cabal build` succeeds; the smoke program below prints `5` via the reference run harness.

**Steps:**

- [ ] **Step 1: Add to `prelude/Std/String.wok`** (after the E4 slice externs):

```
-- Codepoint iteration (Slice E5). Offsets are BYTE offsets into the UTF-8 buffer.
extern decodeCharAt : String -> U64 -> Char   -- codepoint starting at byte offset
extern charWidthAt  : String -> U64 -> U64    -- byte width (1..4) of that codepoint
extern singleton    : Char -> String          -- one codepoint as a string

-- foldChars: left fold over codepoints, single pass (O(n)). Effect-polymorphic:
-- the closure may perform effects; foldChars performs exactly those. (Same shape
-- as Std.Control's higher-order fns, e.g. `reader`/`state`.)
foldChars : (s -> Char -> s with eff e) -> s -> String -> s with eff e
foldChars f acc str = foldCharsGo f acc str 0 (byteLength str)

foldCharsGo : (s -> Char -> s with eff e) -> s -> String -> U64 -> U64 -> s with eff e
foldCharsGo f acc str off end =
  case eqU64 off end of
    True  -> acc
    False -> foldCharsGo f (f acc (decodeCharAt str off)) str (off + charWidthAt str off) end
```

If the bare `with eff e` row is rejected on the closure arrow, mirror the exact placement from `prelude/Std/Control.wok:5-17` (`reader`/`state`).

- [ ] **Step 2: Smoke-test the surface.** Create a temporary program `test/rc-string-fold/01-count-ascii.wok` (kept — it becomes a Task-4 corpus file):

```
module Main
import Std.Base
import Std.String

inc : U64 -> Char -> U64
inc n c = n + 1

main : U64
main = foldChars inc 0 "hello"
```

Run it through the reference run harness (the same one `runProgramHarness`/`Interp.runModule` uses — e.g. the project's run entrypoint on this file).
Expected output: `5`.

- [ ] **Step 3: Multibyte smoke check.** Temporarily change `main` to `foldChars inc 0 "café€"` and run.
Expected output: `5` (c,a,f,é,€ = 5 codepoints across 8 bytes — proves `charWidthAt` advances correctly). Revert `main` to `"hello"` for the committed Task-4 file (or keep a separate file in Task 4).

- [ ] **Step 4: Commit.**

```bash
git add prelude/Std/String.wok
git commit -m "feat(string): foldChars + singleton/decode externs in Std.String (E5 Task 3)"
```

```json:metadata
{"files": ["prelude/Std/String.wok"], "verifyCommand": "cabal build", "acceptanceCriteria": ["3 externs declared", "foldChars effect-polymorphic, pure + effectful both typecheck", "count on hello = 5, on cafe-euro = 5"], "modelTier": "standard"}
```

---

### Task 4: Functional, decode, and OOB tests

**Goal:** Pin absolute correctness of `foldChars`/`decodeCharAt`/`charWidthAt`/`singleton` with run-goldens, cross-machine differential, and alloc-balance — plus error-path coverage.

**Files:**
- Create: `test/rc-string-fold/*.wok` (functional + decode programs)
- Create: `test/rc-string-oob/*.wok` (error programs)
- Create: `test/run-golden/*.expected` (generated via `--accept`, then verified)
- Modify: `test/Spec.hs` (wire `test/rc-string-fold`)

**Acceptance Criteria:**
- [ ] `test/rc-string-fold` is wired into `rc differential`, `rc stats` (heap accounting), `rcCBackendParity`, AND the run-golden group.
- [ ] All run-goldens match hand-computed expected values (listed below) — verified by inspection, not blind `--accept`.
- [ ] OOB + non-boundary programs raise a `PrimError` on both machines (both-fail = agreement in `rc differential`).
- [ ] `cabal test wok-tests` passes.

**Verify:** `cabal test wok-tests --test-options='-p "rc-string-fold"'` and `-p "rc-string-oob"` → all green; goldens match the expected table.

**Steps:**

- [ ] **Step 1: Create the functional/decode corpus** in `test/rc-string-fold/` (keep `01-count-ascii.wok` from Task 3). Each `main` returns a value with a known golden:

`02-count-multibyte.wok` → expected `5`:
```
module Main
import Std.Base
import Std.String
inc : U64 -> Char -> U64
inc n c = n + 1
main : U64
main = foldChars inc 0 "café€"
```

`03-count-empty.wok` → expected `0`:
```
module Main
import Std.Base
import Std.String
inc : U64 -> Char -> U64
inc n c = n + 1
main : U64
main = foldChars inc 0 ""
```

`04-decode-ascii.wok` → expected `'b'`:
```
module Main
import Std.Base
import Std.String
main : Char
main = decodeCharAt "abc" 1
```

`05-decode-multibyte.wok` → expected the codepoint é (renders as the Haskell `show` of '\233'):
```
module Main
import Std.Base
import Std.String
main : Char
main = decodeCharAt "café" 3
```

`06-charwidth-multibyte.wok` → expected `2`:
```
module Main
import Std.Base
import Std.String
main : U64
main = charWidthAt "café" 3
```

`07-singleton-roundtrip.wok` → expected `True`:
```
module Main
import Std.Base
import Std.String
main : Bool
main = eqString (singleton (index "abc" 0)) "a"
```

`08-singleton-multibyte-bytelength.wok` → expected `2`:
```
module Main
import Std.Base
import Std.String
main : U64
main = byteLength (singleton (index "café" 3))
```

- [ ] **Step 2: Create the error corpus** in `test/rc-string-oob/`:

`decode-oob.wok` (offset past end → out-of-bounds PrimError):
```
module Main
import Std.Base
import Std.String
main : Char
main = decodeCharAt "abc" 5
```

`charwidth-oob.wok` (out-of-bounds PrimError):
```
module Main
import Std.Base
import Std.String
main : U64
main = charWidthAt "abc" 9
```

`decode-continuation.wok` (byte 4 of "café" is é's 2nd byte = continuation → not-a-boundary PrimError):
```
module Main
import Std.Base
import Std.String
main : Char
main = decodeCharAt "café" 4
```

- [ ] **Step 3: Wire `test/rc-string-fold` into `test/Spec.hs`.** Mirror how `rcStringFiles` is wired (Spec.hs ~151):
  1. Add `rcStringFoldFiles <- findByExtension [".wok"] "test/rc-string-fold"` next to `rcStringFiles`.
  2. Add `++ rcStringFoldFiles` to the `rc differential` corpus list (Spec.hs ~318).
  3. Add `++ rcStringFoldFiles` to the `rc stats` → `heap accounting` corpus list (~323).
  4. Add `++ rcStringFoldFiles` to the `rcCBackendParity` corpus list (~332).
  5. Add a run-golden entry in the same group as `runFiles` (Spec.hs ~292): `goldenVsString (takeBaseName f) (runGoldenFor f) (runProgramHarness f) | f <- rcStringFoldFiles`. (`runGoldenFor` maps each file to `test/run-golden/<base>.expected`.)
  (`rcStringOobFiles` already feeds `rc differential` — no new wiring; just add the files.)

- [ ] **Step 4: Generate and VERIFY goldens.**

Run: `cabal test wok-tests --test-options='--accept -p "rc-string-fold"'`
Then INSPECT each `test/run-golden/<base>.expected` and confirm it equals the expected value: `01`→`5`, `02`→`5`, `03`→`0`, `04`→`'b'`, `05`→ the `show` of é (codepoint 233), `06`→`2`, `07`→`True`, `08`→`2`. If any differs, the implementation (not the golden) is wrong — fix the code, do not edit the golden to match.

- [ ] **Step 5: Run the full new test set.**

Run: `cabal test wok-tests --test-options='-p "rc-string-fold"'` then `-p "rc-string-oob"`
Expected: all green (differential agreement, heap balance, C-backend parity, goldens; OOB both-fail agreement).

- [ ] **Step 6: Commit.**

```bash
git add test/rc-string-fold test/rc-string-oob test/run-golden test/Spec.hs
git commit -m "test(string): foldChars/decode/singleton corpus + OOB, run-golden + oracle (E5 Task 4)"
```

```json:metadata
{"files": ["test/rc-string-fold", "test/rc-string-oob", "test/run-golden", "test/Spec.hs"], "verifyCommand": "cabal test wok-tests --test-options='-p \"rc-string\"'", "acceptanceCriteria": ["rc-string-fold wired to differential+stats+cbackend+run-golden", "goldens match expected table by inspection", "OOB + non-boundary raise PrimError (both-fail agreement)", "cabal test passes"], "modelTier": "standard"}
```

---

### Task 5: Effect-soundness death-test (the soundness gate)

**Goal:** Prove the decomposition is effect-sound — a `foldChars` whose closure performs an effect on every (incl. non-final) character, with the handler resuming one-shot, collects ALL characters back. If the wok driver lost iterations after the first effect, this fails. Must also be leak-free under the heap oracle and sanitizers.

**Files:**
- Create: `test/rc-string-fold/11-effect-collect.wok` (landed as 11-; 09/10 are the 4-byte tests)
- Create: `test/run-golden/11-effect-collect.expected` (generated, verified)

**Acceptance Criteria:**
- [ ] A handler-driven `foldChars` over `"café"` reconstructs the exact string `"café"` via one-shot resume (per R4, `emit` fires on non-final characters so "the rest of the fold" is non-trivial).
- [ ] Passes `rc differential` (both machines agree), `rc stats` heap accounting (allocs == frees, live == 0 — no leak across the captures/resumes), and `rcCBackendParity`.
- [ ] The sanitizer (ASan/LSan) gate stays clean (run it the way the E4 string slice did).

**Verify:** `cabal test wok-tests --test-options='-p "11-effect-collect"'` → green; sanitizer gate clean.

**Steps:**

- [ ] **Step 1: Write the death-test program** `test/rc-string-fold/11-effect-collect.wok`. (Handler syntax mirrors `test/rc-m2b/02-except-abort.wok`: `with self = E { op args k -> … ; v -> … } in body`, where `k ()` resumes one-shot.)

```
module Main
import Std.Base
import Std.String

-- Effect-soundness death-test (E5): the fold closure performs `emit` on EACH
-- codepoint. The handler resumes one-shot and prepends each char to the resumed
-- result, so the collected string == the original IFF every iteration ran after
-- the first (non-final) effect. A lost-iterations bug yields a short string.
effect Emit = { emit : Char -> () }

-- closure threads the (unboxed) instance as the accumulator, emitting each char.
step : Emit -> Char -> Emit with Emit
step e c = let u = e.emit c in e

emitAll : Emit -> String -> Emit with Emit
emitAll e s = foldChars step e s

-- collect: one-shot resume; result = char0 ++ (char1 ++ ( ... ++ "")) = original.
collect : String -> String
collect s =
  with self = Emit { emit ch k -> append (singleton ch) (k ()) ; v -> "" } in
  emitAll self s

main : String
main = collect "café"
```

- [ ] **Step 2: Generate + verify the golden.**

Run: `cabal test wok-tests --test-options='--accept -p "11-effect-collect"'`
Inspect `test/run-golden/11-effect-collect.expected`: it MUST be the rendering of `"café"` (the `show` form with é as `\233`). If it is `"c"`, `""`, or any truncation, the fold is dropping iterations after the effect — a real soundness bug; fix the implementation, never the golden.

- [ ] **Step 3: Run the oracle + heap balance.**

Run: `cabal test wok-tests --test-options='-p "11-effect-collect"'`
Expected: green across `rc differential`, `rc stats` heap accounting (no leak through the NCont captures/one-shot resumes — this is P6), and `rcCBackendParity`.

- [ ] **Step 4: Sanitizer gate.** Run the ASan/LSan build+test the same way the E4 string slice did (the C-backend sanitizer gate). Expected: clean (no leaks/UAF).

- [ ] **Step 5: Commit.**

```bash
git add test/rc-string-fold/11-effect-collect.wok test/run-golden/11-effect-collect.expected
git commit -m "test(string): effect-soundness death-test for foldChars + resume (E5 Task 5)"
```

```json:metadata
{"files": ["test/rc-string-fold/11-effect-collect.wok", "test/run-golden/11-effect-collect.expected"], "verifyCommand": "cabal test wok-tests --test-options='-p \"11-effect-collect\"'", "acceptanceCriteria": ["handler-driven foldChars over cafe reconstructs cafe via one-shot resume", "passes differential + heap balance + cbackend parity", "sanitizer gate clean"], "modelTier": "standard"}
```

---

## Self-Review

**Spec coverage:** §3 surface → Tasks 2+3. §4.1 helpers → Task 1. §4.2 prims → Task 2. §4.3 singleton → Task 2. §4.4 termination → Task 3. §4.5 names/registration → Task 2. §5 properties: P1 (round-trip)→T4 #07/#08; P2 (fold=decode-all)→T4 #01/#02; P3 (single pass)→T4 #02; P4 (machine agreement)→T4/T5 differential; P5 (effect-soundness)→T5; P6 (RC balance)→T4/T5 stats. §6 testing → Tasks 4+5. §7 honesty → no task (documentation). §8 files → all covered. §9 R1 (poly + effect-poly) → Task 3 explicitly. R2/R3 → user-decided (keep names / minimal eqU64). R4 → Task 5. No gaps.

**Placeholder scan:** No TBD/TODO. The two helper-name uncertainties (`asStringIndex`, `liftRC`) are pinned to "use what `stringByteAt` uses in that file" with the exact model line — concrete, not vague.

**Type consistency:** `foldChars`/`foldCharsGo` signatures identical across spec and plan (effect-polymorphic). Prim names consistent (`decodeCharAtName`/`charWidthAtName`/`singletonName`). `RVLit (LChar c)` / `VLit (LChar c)` used per machine. `eqU64` termination consistent.

---
