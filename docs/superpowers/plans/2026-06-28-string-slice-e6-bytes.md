# String Slice E6 — `Bytes` + validated `String` construction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a raw `Bytes` type and a UTF-8-validated `fromBytes`/`toBytes` gate to wok, on a new `WokBytes` C cell, with two cross-checked validators.

**Architecture:** `Bytes` is monomorphic flat bytes — a `String` without the UTF-8 invariant — so it reuses the WokString C-cell framework (distinct tag `0xFFFC`, identical layout, shared size-class allocator) rather than the polymorphic `Array`. `fromBytes` validates via `Data.Text.Encoding.decodeUtf8'` (Haskell, the oracle anchor) on the reference + abstract-heap paths and via a Höhrmann DFA in C on the C-heap path; the two are cross-checked by the differential oracle.

**Tech Stack:** Haskell (GHC, `-Werror -Wincomplete-patterns` on hand-written code), C (`-std=c17`), `text-2.1.3`, tasty/hspec/QuickCheck, the wok RC runtime.

**User decisions (already made):**
- "U64 for now but I want U8 in future" — `fromList : [U64] -> Bytes`; U8 + `Num` typeclass is a deferred slice.
- "i want to include the dfa validator in this slice" — C Höhrmann DFA ships now, beside `decodeUtf8'`.
- "go" on the spec; "Run it autonomously for me" — subagent-driven, no execution-method gate.
- Representation Option A (distinct cell); out-of-range `fromList` element traps (`PrimError`); simdutf and StringZilla rejected as validators.

**Spec:** `docs/superpowers/specs/2026-06-28-string-slice-e6-bytes-design.md`

---

## File structure

| File | Responsibility | Task |
|------|----------------|------|
| `runtime/wok_rc.h` | `WOK_BYTES_TAG` + `wok_bytes_*`/`wok_validate_utf8` decls | 1, 2 |
| `runtime/wok_rc.c` | `wok_bytes_*` accessors + `wok_free` arm | 1 |
| `runtime/wok_utf8.c` (new) | Höhrmann DFA `wok_validate_utf8` | 2 |
| `runtime/test/wok_rc_test.c` | C-level validator sanity cases | 2 |
| `wok.cabal` | `c-sources` (+`wok_utf8.c`), `data-files` (+`Std/Bytes.wok`) | 1, 2, 5 |
| `src/Wok/Interp/Utf8.hs` | `validateUtf8` (Haskell anchor) | 3 |
| `src/Wok/TypeChecking/{Builtins,Types,Infer,Class}.hs`, `src/Wok/IR/Anf.hs` | `Bytes` tycon / `TcBytes` | 4 |
| `src/Wok/IR/PrimNames.hs` | `stdBytesModule` + prim name constants | 5 |
| `prelude/Std/Bytes.wok` (new), `prelude/Std/Base.wok` | surface externs + `eqBytes`/`instance Eq Bytes` | 5 |
| `src/Wok/Prelude.hs`, `src/Wok/Loader.hs` | load/register `Std.Bytes` | 5 |
| `src/Wok/Interp/Value.hs`, `src/Wok/Interp/Prim.hs` | `VBytes` + reference prims | 6 |
| `src/Wok/Interp/RC/{Value,Heap,Prim}.hs` | `NBytes` + plumbing + RC prims | 7 |
| `test/rc-bytes/` (new), `test/Spec.hs` | corpus + harness + agreement + properties | 8 |

---

### Task 1: C runtime — `WokBytes` cell

**Goal:** A `WokBytes` C cell (tag `0xFFFC`, layout-identical to `WokString`) with allocator/accessors and an explicit `wok_free` dispatch arm.

**Files:**
- Modify: `runtime/wok_rc.h` (tag + decls)
- Modify: `runtime/wok_rc.c` (accessors + `wok_free` arm at the tag-dispatch block ~`:676-693`)

**Acceptance Criteria:**
- [ ] `WOK_BYTES_TAG 0xFFFCu` defined; reserved-tag comment (`wok_rc.h:85-86`) updated to list it.
- [ ] `wok_bytes_alloc/len/data/byte_get` declared and implemented, layout-identical to the `wok_string_*` family.
- [ ] `wok_free` has an explicit `WOK_BYTES_TAG` arm (same size-class math as `WokString`).
- [ ] `cabal build` succeeds (C compiles + links).

**Verify:** `cabal build 2>&1 | tail -5` → no errors.

**Steps:**

- [ ] **Step 1: Add the tag + decls in `runtime/wok_rc.h`.** Beside `WOK_STRING_VIEW_TAG 0xFFFDu` (`:134`):
```c
#define WOK_BYTES_TAG 0xFFFCu
/* WokBytes: identical layout to WokString (8B header, byte_len at +8, packed
   bytes), but NO UTF-8 invariant. Distinct tag so wok_free / deref dispatch and
   prim tag-guards stay unambiguous. */
WokObj  *wok_bytes_alloc(WokHeap *h, uint64_t byte_len);
uint64_t wok_bytes_len(const WokObj *p);
uint8_t *wok_bytes_data(WokObj *p);
uint64_t wok_bytes_byte_get(const WokObj *p, uint64_t i);
```
Update the reserved-tag comment (`:85-86`) to read `... 0xFFFF, 0xFFFE, 0xFFFD, or 0xFFFC`.

- [ ] **Step 2: Implement accessors in `runtime/wok_rc.c`**, mirroring the `wok_string_alloc`/`wok_string_len`/`wok_string_data`/`wok_string_byte_get` definitions exactly (same cell-bytes/size-class helpers `wok_string_cell_bytes`/`wok_string_class`), substituting `WOK_BYTES_TAG` for `WOK_STRING_TAG`. The byte payload starts at offset 8 just like `WokString`.

- [ ] **Step 3: Add the `wok_free` dispatch arm.** In `wok_free` (~`:676-693`), beside the `WOK_STRING_TAG` case, add:
```c
} else if (tag == WOK_BYTES_TAG) {
    /* identical layout to WokString: same cell-bytes/size-class */
    size_t cb  = wok_string_cell_bytes(wok_bytes_len(p));
    uint32_t cl = wok_string_class(wok_bytes_len(p));
    wok_free_cell(h, p, cb, cl);   /* mirror the WOK_STRING_TAG branch's free call */
}
```
(Match the exact free/return mechanics of the `WOK_STRING_TAG` branch — read it and copy its shape.)

- [ ] **Step 4: Build.** Run: `cabal build 2>&1 | tail -5` → no errors. Commit:
```bash
git add runtime/wok_rc.h runtime/wok_rc.c
git commit -m "feat(bytes): WokBytes C cell (tag 0xFFFC, wok_free arm)"
```

```json:metadata
{"files": ["runtime/wok_rc.h", "runtime/wok_rc.c"], "verifyCommand": "cabal build 2>&1 | tail -5", "acceptanceCriteria": ["WOK_BYTES_TAG 0xFFFC defined + comment updated", "wok_bytes_* accessors mirror wok_string_*", "wok_free has explicit WOK_BYTES_TAG arm", "cabal build succeeds"], "modelTier": "standard"}
```

---

### Task 2: C runtime — Höhrmann DFA validator

**Goal:** A correct, fast full-buffer UTF-8 validator in C, exposed as `wok_validate_utf8`.

**Files:**
- Create: `runtime/wok_utf8.c`
- Modify: `runtime/wok_rc.h` (decl)
- Modify: `wok.cabal` (`c-sources` += `runtime/wok_utf8.c`)
- Modify: `runtime/test/wok_rc_test.c` (sanity cases)

**Acceptance Criteria:**
- [ ] `int wok_validate_utf8(const uint8_t *bytes, uint64_t len)` returns 1 for valid UTF-8 (incl. empty), 0 for each of: overlong, lone continuation, > U+10FFFF, lone surrogate, truncated multibyte.
- [ ] Added to `wok.cabal` `c-sources`; `cabal build` succeeds.

**Verify:** `cabal build 2>&1 | tail -5` → no errors. (Authoritative correctness cross-check is the Haskell↔C agreement test in Task 8.)

**Steps:**

- [ ] **Step 1: Create `runtime/wok_utf8.c`** with Björn Höhrmann's public-domain UTF-8 DFA:
```c
/* UTF-8 validation via Bjoern Hoehrmann's DFA decoder.
   Copyright (c) 2008-2009 Bjoern Hoehrmann <bjoern@hoehrmann.de>
   See http://bjoern.hoehrmann.de/utf-8/decoder/dfa/  (MIT license) */
#include <stdint.h>

#define WOK_UTF8_ACCEPT 0u
#define WOK_UTF8_REJECT 12u

static const uint8_t wok_utf8d[] = {
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
  1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, 9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
  7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7, 7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
  8,8,2,2,2,2,2,2,2,2,2,2,2,2,2,2, 2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
  10,3,3,3,3,3,3,3,3,3,3,3,3,4,3,3, 11,6,6,6,5,8,8,8,8,8,8,8,8,8,8,8,
  0,12,24,36,60,96,84,12,12,12,48,72, 12,12,12,12,12,12,12,12,12,12,12,12,
  12, 0,12,12,12,12,12, 0,12, 0,12,12, 12,24,12,12,12,12,12,24,12,24,12,12,
  12,12,12,12,12,12,12,24,12,12,12,12, 12,24,12,12,12,12,12,12,12,24,12,12,
  12,12,12,12,12,12,12,36,12,36,12,12, 12,36,12,12,12,12,12,36,12,36,12,12,
  12,36,12,12,12,12,12,12,12,12,12,12,
};

/* Returns 1 if [bytes, bytes+len) is well-formed UTF-8 (rejects overlong,
   surrogates, > U+10FFFF, bad/truncated continuations). Empty buffer is valid. */
int wok_validate_utf8(const uint8_t *bytes, uint64_t len) {
  uint32_t state = WOK_UTF8_ACCEPT;
  for (uint64_t i = 0; i < len; i++) {
    uint32_t type = wok_utf8d[bytes[i]];
    state = wok_utf8d[256u + state + type];
    if (state == WOK_UTF8_REJECT) return 0;
  }
  return state == WOK_UTF8_ACCEPT ? 1 : 0;
}
```

- [ ] **Step 2: Declare in `runtime/wok_rc.h`** (near the `wok_bytes_*` decls):
```c
int wok_validate_utf8(const uint8_t *bytes, uint64_t len);
```

- [ ] **Step 3: Add to `wok.cabal` `c-sources`** (`:118`), after `runtime/wok_str_ops.c`:
```
                      runtime/wok_utf8.c
```

- [ ] **Step 4: Add sanity cases to `runtime/test/wok_rc_test.c`** asserting `wok_validate_utf8` returns 1 for `""`, `"A"`, `"\xC3\xA9"` (é), and 0 for `"\xC0\x80"`, `"\x80"`, `"\xF7\xBF\xBF\xBF"`, `"\xED\xA0\x80"`, `"\xE2\x82"` — mirroring the existing assertion style in that file.

- [ ] **Step 5: Build + commit.** Run: `cabal build 2>&1 | tail -5` → no errors.
```bash
git add runtime/wok_utf8.c runtime/wok_rc.h runtime/test/wok_rc_test.c wok.cabal
git commit -m "feat(bytes): Hoehrmann DFA UTF-8 validator (wok_validate_utf8)"
```

```json:metadata
{"files": ["runtime/wok_utf8.c", "runtime/wok_rc.h", "wok.cabal", "runtime/test/wok_rc_test.c"], "verifyCommand": "cabal build 2>&1 | tail -5", "acceptanceCriteria": ["wok_validate_utf8 rejects the four classes + truncated, accepts valid incl empty", "added to cabal c-sources", "cabal build succeeds"], "modelTier": "mechanical"}
```

---

### Task 3: Haskell validator `validateUtf8` (oracle anchor)

**Goal:** A shared Haskell UTF-8 validator used by the reference + abstract-heap paths and as the cross-check oracle.

**Files:**
- Modify: `src/Wok/Interp/Utf8.hs` (add `validateUtf8`, export it)
- Test: `test/Spec.hs` (unit cases — may be folded into Task 8; here add a minimal `validateUtf8` hspec group)

**Acceptance Criteria:**
- [ ] `validateUtf8 :: ByteString -> Bool` returns `True` for valid UTF-8 (incl. empty), `False` for the four invalid classes.
- [ ] Exported from `Wok.Interp.Utf8`.

**Verify:** `cabal test 2>&1 | grep -iE "validateUtf8|FAIL|passed" | tail -20`

**Steps:**

- [ ] **Step 1: Add to `src/Wok/Interp/Utf8.hs`** (it already handles `ByteString`; ensure `import qualified Data.Text.Encoding as TxEnc` and `import Data.ByteString (ByteString)` are present), and add `validateUtf8` to the module export list:
```haskell
-- | True iff the bytes are well-formed UTF-8 (rejects overlong, lone
-- continuation, > U+10FFFF, lone surrogate). The reference/abstract-heap gate
-- for Std.Bytes.fromBytes and the oracle anchor the C DFA must match.
validateUtf8 :: ByteString -> Bool
validateUtf8 bs = case TxEnc.decodeUtf8' bs of
  Right _ -> True
  Left  _ -> False
```

- [ ] **Step 2: Write the failing test** (hspec) in `test/Spec.hs` (or its Task-8 home):
```haskell
describe "Wok.Interp.Utf8.validateUtf8" $ do
  it "accepts valid UTF-8" $ do
    validateUtf8 (BS.pack [])                         `shouldBe` True
    validateUtf8 (BS.pack [0x41])                     `shouldBe` True
    validateUtf8 (BS.pack [0xC3,0xA9])               `shouldBe` True   -- é
    validateUtf8 (BS.pack [0xF0,0x9F,0x98,0x80])     `shouldBe` True   -- emoji
  it "rejects the four ill-formedness classes" $ do
    validateUtf8 (BS.pack [0xC0,0x80])               `shouldBe` False  -- overlong
    validateUtf8 (BS.pack [0x80])                     `shouldBe` False  -- lone cont
    validateUtf8 (BS.pack [0xF7,0xBF,0xBF,0xBF])     `shouldBe` False  -- > U+10FFFF
    validateUtf8 (BS.pack [0xED,0xA0,0x80])          `shouldBe` False  -- surrogate
    validateUtf8 (BS.pack [0xE2,0x82])               `shouldBe` False  -- truncated
```

- [ ] **Step 3: Run** `cabal test 2>&1 | grep -iE "validateUtf8|FAIL" | tail` → PASS. Commit:
```bash
git add src/Wok/Interp/Utf8.hs test/Spec.hs
git commit -m "feat(bytes): validateUtf8 Haskell UTF-8 gate via decodeUtf8'"
```

```json:metadata
{"files": ["src/Wok/Interp/Utf8.hs", "test/Spec.hs"], "verifyCommand": "cabal test 2>&1 | grep -iE 'validateUtf8|FAIL|passed' | tail -20", "acceptanceCriteria": ["validateUtf8 accepts valid incl empty", "rejects overlong/lone-cont/>10FFFF/surrogate", "exported from Wok.Interp.Utf8"], "modelTier": "mechanical"}
```

---

### Task 4: Type system — `Bytes` tycon

**Goal:** `Bytes` is a known nullary builtin type (`TcBytes`) recognized by the type checker and pretty-printers.

**Files:**
- Modify: `src/Wok/TypeChecking/Builtins.hs:34` (tycon entry)
- Modify: `src/Wok/TypeChecking/Types.hs:45` (`TcBytes` constructor)
- Modify: `src/Wok/TypeChecking/Infer.hs` (name→TyCon `:827`-area; `prettyCType` `:3771`)
- Modify: `src/Wok/TypeChecking/Class.hs` (`tyConKey` `:176`-area; name→TyCon `:296`-area)
- Modify: `src/Wok/IR/Anf.hs:392` (`prettyCTypeLocal`)

**Acceptance Criteria:**
- [ ] `("Bytes", TyConInfo KStar 0 [] False [])` added beside `String`.
- [ ] `TcBytes` added to the `TyCon` sum and handled in every `-Wincomplete-patterns` match site (build is the check).
- [ ] `cabal build` succeeds (exhaustiveness satisfied).

**Verify:** `cabal build 2>&1 | tail -5` → no errors.

**Steps:**

- [ ] **Step 1: `Builtins.hs:34`** add after the `String` entry:
```haskell
      , ("Bytes",  TyConInfo KStar 0 [] False [])
```
- [ ] **Step 2: `Types.hs`** add `| TcBytes` to the `TyCon` sum (beside `TcU32`).
- [ ] **Step 3: name↔TyCon maps.** `Infer.hs` (~`:827`): `| name == Tx.pack "Bytes" = TcBytes`. `Class.hs` (~`:296`): same. `Class.hs` `tyConKey` (~`:176`): `tyConKey TcBytes = Tx.pack "Bytes"`.
- [ ] **Step 4: pretty-printers.** `Infer.hs:3771`: `prettyCType (CTCon TcBytes []) = Tx.pack "Bytes"`. `Anf.hs:392`: `prettyCTypeLocal (CTCon TcBytes []) = Tx.pack "Bytes"`.
- [ ] **Step 5: build** (fix any other exhaustiveness sites GHC flags for `TcBytes`). Run: `cabal build 2>&1 | tail -5`. Commit:
```bash
git add src/Wok/TypeChecking/Builtins.hs src/Wok/TypeChecking/Types.hs src/Wok/TypeChecking/Infer.hs src/Wok/TypeChecking/Class.hs src/Wok/IR/Anf.hs
git commit -m "feat(bytes): Bytes builtin tycon (TcBytes)"
```

```json:metadata
{"files": ["src/Wok/TypeChecking/Builtins.hs", "src/Wok/TypeChecking/Types.hs", "src/Wok/TypeChecking/Infer.hs", "src/Wok/TypeChecking/Class.hs", "src/Wok/IR/Anf.hs"], "verifyCommand": "cabal build 2>&1 | tail -5", "acceptanceCriteria": ["Bytes tycon added beside String", "TcBytes handled at all -Wincomplete-patterns sites", "cabal build succeeds"], "modelTier": "standard"}
```

---

### Task 5: Prim names + `Std.Bytes` prelude wiring

**Goal:** `Std.Bytes` exists as a loadable prelude module with the six externs, plus `eqBytes`/`instance Eq Bytes`, and prim-name constants.

**Files:**
- Modify: `src/Wok/IR/PrimNames.hs` (`stdBytesModule` + name constants + `eqBytesName`)
- Create: `prelude/Std/Bytes.wok`
- Modify: `prelude/Std/Base.wok` (`extern eqBytes` + `instance Eq Bytes`)
- Modify: `src/Wok/Prelude.hs` (`stdBytesName` + `stdBytesText` reader, mirror `stdStringText` `:61-69`)
- Modify: `src/Wok/Loader.hs` (`stdBytesLM` parse + insert, mirror `stdStringLM` `:81`)
- Modify: `wok.cabal:14` (`data-files` += `prelude/Std/Bytes.wok`)

**Acceptance Criteria:**
- [ ] A wok program with `import Std.Bytes` typechecks (the externs resolve).
- [ ] `cabal build` succeeds.

**Verify:** `cabal build 2>&1 | tail -5` → no errors.

**Steps:**

- [ ] **Step 1: `PrimNames.hs`** add (mirror `stdStringModule` + name constants):
```haskell
stdBytesModule :: Text
stdBytesModule = Tx.pack "Std.Bytes"

bytesFromListName, bytesToListName, bytesLengthName, bytesIndexName,
  bytesFromBytesName, bytesToBytesName :: Text
bytesFromListName  = Tx.pack "fromList"
bytesToListName    = Tx.pack "toList"
bytesLengthName    = Tx.pack "length"
bytesIndexName     = Tx.pack "index"
bytesFromBytesName = Tx.pack "fromBytes"
bytesToBytesName   = Tx.pack "toBytes"

eqBytesName :: Text
eqBytesName = Tx.pack "eqBytes"
```
- [ ] **Step 2: Create `prelude/Std/Bytes.wok`:**
```wok
module Std.Bytes
import Std.Base

-- A raw, unverified byte buffer (not necessarily valid UTF-8).
extern fromList  : [U64] -> Bytes        -- element > 255 traps
extern toList    : Bytes -> [U64]
extern length    : Bytes -> U64
extern index     : Bytes -> U64 -> U64   -- byte at i (0-255); OOB traps
extern fromBytes : Bytes -> Option String -- Some iff valid UTF-8
extern toBytes   : String -> Bytes
```
- [ ] **Step 3: `prelude/Std/Base.wok`** add beside `eqString`/`instance Eq String`:
```wok
extern eqBytes : Bytes -> Bytes -> Bool

instance Eq Bytes where
  eq x y = eqBytes x y
```
(Match the exact `instance Eq String` shape already in the file.)
- [ ] **Step 4: `Prelude.hs`** add `stdBytesName = Tx.pack "Std.Bytes"` and `stdBytesText` reading `prelude/Std/Bytes.wok` via `Paths_wok.getDataFileName` (mirror `stdStringText` `:61-69`). Export them.
- [ ] **Step 5: `Loader.hs`** parse `stdBytesLM <- liftEither (parseAndPrep "<Std.Bytes>" Embedded stdBytesText)` and insert it into the loaded-module set alongside `stdStringLM` (mirror `:79-81` and wherever `stdStringLM` is added to the map/topo input).
- [ ] **Step 6: `wok.cabal:14`** add `prelude/Std/Bytes.wok` to `data-files`.
- [ ] **Step 7: build + commit.** Run: `cabal build 2>&1 | tail -5`.
```bash
git add src/Wok/IR/PrimNames.hs prelude/Std/Bytes.wok prelude/Std/Base.wok src/Wok/Prelude.hs src/Wok/Loader.hs wok.cabal
git commit -m "feat(bytes): Std.Bytes module wiring + eqBytes + prim names"
```

```json:metadata
{"files": ["src/Wok/IR/PrimNames.hs", "prelude/Std/Bytes.wok", "prelude/Std/Base.wok", "src/Wok/Prelude.hs", "src/Wok/Loader.hs", "wok.cabal"], "verifyCommand": "cabal build 2>&1 | tail -5", "acceptanceCriteria": ["Std.Bytes loads + typechecks on import", "eqBytes + instance Eq Bytes added", "stdBytesModule + name constants added", "data-files updated"], "modelTier": "standard"}
```

---

### Task 6: Reference interpreter — `VBytes` + prims

**Goal:** The reference interpreter represents `Bytes` as `VBytes ByteString` and implements all seven prims.

**Files:**
- Modify: `src/Wok/Interp/Value.hs` (`VBytes ByteString` ctor + every match site, incl. `renderValue`)
- Modify: `src/Wok/Interp/Prim.hs` (the prims + registration in the reference prim table)

**Acceptance Criteria:**
- [ ] `VBytes ByteString` added; all `-Wincomplete-patterns` `Value` match sites handle it.
- [ ] `fromList`/`toList`/`length`/`index`/`eqBytes`/`fromBytes`/`toBytes` implemented and registered; `fromBytes` uses `validateUtf8`; `fromList` element > 255 and OOB `index` raise `PrimError`.
- [ ] `cabal build` succeeds.

**Verify:** `cabal build 2>&1 | tail -5` → no errors. (Behavioral coverage in Task 8.)

**Steps:**

- [ ] **Step 1: `Value.hs:57`** add `| VBytes ByteString` to `Value`. Build to enumerate every non-exhaustive match (`renderValue` `:208-235`, equality/eval sites) and handle each — `renderValue (VBytes bs)` renders as `Tx.pack ("Bytes" <> show (BS.unpack bs))` (choose a format and reuse it identically in Task 7's `renderRCValue`).
- [ ] **Step 2: Implement the prims in `Prim.hs`** (mirror `stringByteAtP`/`arrayFromListP` shapes). Strings are `VLit (LStr t)`; bytes are `VBytes bs`. Sketch:
```haskell
bytesFromListP = mkPrim PN.bytesFromListName 1 $ \args -> case args of
  [xs] -> do ws <- collectBytes xs            -- reuse collectList; each elem must be 0..255 else PrimError
             Right (PRDone (VBytes (BS.pack ws)))
  _ -> Left (ArityError PN.bytesFromListName)
bytesLengthP  = mkPrim PN.bytesLengthName 1 $ \[VBytes bs] -> Right (PRDone (VLit (LInt (fromIntegral (BS.length bs)))))
bytesIndexP   = mkPrim PN.bytesIndexName 2 $ \[VBytes bs, iv] -> do i <- asU64Index iv
                                                                    if i >= BS.length bs then Left (PrimError ...)
                                                                    else Right (PRDone (VLit (LInt (fromIntegral (BS.index bs i)))))
bytesToBytesP   = mkPrim PN.bytesToBytesName 1 $ \[VLit (LStr t)] -> Right (PRDone (VBytes (TxEnc.encodeUtf8 t)))
bytesFromBytesP = mkPrim PN.bytesFromBytesName 1 $ \[VBytes bs] ->
  Right (PRDone (if validateUtf8 bs then VCon (Tx.pack "Some") [VLit (LStr (TxEnc.decodeUtf8 bs))]
                                    else VCon (Tx.pack "None") []))
eqBytesP = mkPrim PN.eqBytesName 2 $ \[VBytes a, VBytes b] -> Right (PRDone (boolValue (a == b)))
-- bytesToListP: foldr over VCon "Cons"/"Nil" of each byte as VLit (LInt ...)
```
Handle the non-matching argument cases with `PrimError`/`ArityError` exactly as the string prims do. Register all seven in the reference prim table (the list that includes `stringByteAtP`).
- [ ] **Step 3: build + commit.** Run: `cabal build 2>&1 | tail -5`.
```bash
git add src/Wok/Interp/Value.hs src/Wok/Interp/Prim.hs
git commit -m "feat(bytes): reference interpreter VBytes + prims"
```

```json:metadata
{"files": ["src/Wok/Interp/Value.hs", "src/Wok/Interp/Prim.hs"], "verifyCommand": "cabal build 2>&1 | tail -5", "acceptanceCriteria": ["VBytes ctor + all match sites incl renderValue", "all 7 prims implemented + registered", "fromBytes uses validateUtf8; out-of-range/OOB -> PrimError", "cabal build succeeds"], "modelTier": "standard"}
```

---

### Task 7: RC interpreter — `NBytes` + plumbing + prims

**Goal:** The RC interpreter represents `Bytes` as `NBytes ByteString` (abstract heap) / `WokBytes` cell (C heap), with full RC plumbing and the seven prims; the C-heap `fromBytes` uses `wok_validate_utf8`.

**Files:**
- Modify: `src/Wok/Interp/RC/Value.hs` (`NBytes`, `wokBytesTag`, `internTag` skip, `deref`/`derefPure` arms, `renderRCValue`, free-cascade)
- Modify: `src/Wok/Interp/RC/Heap.hs` (FFI bindings: `wok_bytes_alloc/len/data/byte_get`, `wok_validate_utf8`)
- Modify: `src/Wok/Interp/RC/Prim.hs` (the seven prims, abstract + C-heap paths; registration)

**Acceptance Criteria:**
- [ ] `NBytes ByteString` added; `wokBytesTag = 0xFFFC`; `internTag` skips `0xFFFC`; `deref`/`derefPure` reconstruct `NBytes` from a `WokBytes` cell; `renderRCValue` matches Task-6 format; free-cascade handles `NBytes`.
- [ ] FFI bindings added; C-heap `fromBytes` calls `wok_validate_utf8`, abstract path uses `validateUtf8`.
- [ ] All seven prims registered; prims consume/drop operands per RC discipline.
- [ ] `cabal build` succeeds.

**Verify:** `cabal build 2>&1 | tail -5` → no errors. (Behavioral + parity coverage in Task 8.)

**Steps:**

- [ ] **Step 1: `RC/Value.hs` plumbing.** Add `| NBytes ByteString` to `Node` (beside `NString` `:681`). Define `wokBytesTag :: Word32; wokBytesTag = 0xFFFC` beside the other tag constants. In `internTag` (`:1011-1029`) add the fourth descending skip step for `wokBytesTag` (skip lowest reserved tag first), and update its comment. In `deref` (`:1966-1992`) and `derefPure` (~`:2069`) add a `wokBytesTag` arm reconstructing `NBytes` by reading the cell bytes (mirror the `wokStringTag` arm, using `wokBytesLen`/`wokBytesData`). Add `renderRCValue (NBytes bs)` using the SAME format string as Task 6's `renderValue (VBytes bs)`. Handle any free-cascade / node-walk match sites GHC flags for `NBytes` (no boxed children → treat like `NString`).
- [ ] **Step 2: `RC/Heap.hs` FFI** (mirror `wok_string_*` `:45-49`):
```haskell
foreign import ccall unsafe "wok_bytes_alloc"    wokBytesAlloc   :: Ptr WokHeap -> Word64 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_bytes_len"      wokBytesLen     :: Ptr WokObj -> IO Word64
foreign import ccall unsafe "wok_bytes_data"     wokBytesData    :: Ptr WokObj -> IO (Ptr Word8)
foreign import ccall unsafe "wok_bytes_byte_get" wokBytesByteGet :: Ptr WokObj -> Word64 -> IO Word64
foreign import ccall unsafe "wok_validate_utf8"  wokValidateUtf8 :: Ptr Word8 -> Word64 -> IO Int
```
Export them.
- [ ] **Step 3: `RC/Prim.hs` prims** (mirror `stringByteLength`/`stringByteAt`/`arrayFromList`). Add a `bytesBytes :: RCValue -> Store -> RC ByteString` helper (mirror `stringBytes`, reading `NBytes` / the `WokBytes` cell). Implement the seven prims threading the `Store`, dropping operands. `fromList` uses `collectList` then validates each element ∈ 0..255 (`PrimError` otherwise) and allocs an `NBytes`/`WokBytes`. `fromBytes`: on `AbstractHeap` use `validateUtf8`; on `CHeap` read the cell pointer+len and call `wokValidateUtf8`; build a `String` (`NString`/`WokString`) on success, `Some`/`None` con cells either way. `toBytes` reads `stringBytes` and allocs a bytes cell. `toList` uses `buildList` (`:686`). Register all seven in `rcPrimTable` (the `rcStringPrims`-style list / table).
- [ ] **Step 4: build + commit.** Run: `cabal build 2>&1 | tail -5`.
```bash
git add src/Wok/Interp/RC/Value.hs src/Wok/Interp/RC/Heap.hs src/Wok/Interp/RC/Prim.hs
git commit -m "feat(bytes): RC interpreter NBytes + WokBytes plumbing + prims"
```

```json:metadata
{"files": ["src/Wok/Interp/RC/Value.hs", "src/Wok/Interp/RC/Heap.hs", "src/Wok/Interp/RC/Prim.hs"], "verifyCommand": "cabal build 2>&1 | tail -5", "acceptanceCriteria": ["NBytes + wokBytesTag + internTag skip + deref/derefPure arms + renderRCValue + free-cascade", "FFI bindings incl wok_validate_utf8", "7 prims (abstract + C-heap paths) registered, RC drop discipline", "cabal build succeeds"], "modelTier": "standard"}
```

---

### Task 8: Tests — corpus, harness, agreement, properties

**Goal:** Full differential + property + agreement coverage proving validation correctness and cross-backend parity.

**Files:**
- Create: `test/rc-bytes/*.wok` (corpus)
- Modify: `test/Spec.hs` (harness wiring; `interpPrimTests` `:4705-4722`; Haskell↔C agreement; QuickCheck)

**Acceptance Criteria:**
- [ ] `test/rc-bytes/` corpus covers: valid → `Some` (ASCII/2/3/4-byte/mixed/empty/boundary scalars), invalid → `None` (overlong, lone continuation, > U+10FFFF, lone surrogate, truncated), `fromList`/`toList` round-trip, `length`/`index` (+OOB trap), `fromList` out-of-range trap, `eqBytes`.
- [ ] Wired into differential (ref vs RC), alloc-stats, C-backend parity, and run-golden harnesses.
- [ ] `interpPrimTests` lists all six `Std.Bytes` externs + `eqBytes`.
- [ ] Haskell↔C validator agreement test over the full corpus; QuickCheck properties (`validateUtf8` ≡ `wok_validate_utf8` on `[Word8]`; `fromBytes (toBytes s) == Some s'`; `toList ∘ fromList` id on byte lists).
- [ ] `cabal test` all green.

**Verify:** `cabal test 2>&1 | tail -25` → all suites pass.

**Steps:**

- [ ] **Step 1: Write the corpus** under `test/rc-bytes/`, mirroring `test/rc-string/` program style (each `.wok` produces an observable `U64`/`Bool`). Cover every bullet in the AC. Example `01-validate-valid.wok`:
```wok
module Main
import Std.Base
import Std.Bytes
main : U64
main = case fromBytes (fromList [0x41, 0xC3, 0xA9]) of
  Some _ -> 1
  None   -> 0
```
and `02-validate-invalid.wok` returning `0` for `fromList [0xC0, 0x80]`, etc.
- [ ] **Step 2: Wire harnesses in `test/Spec.hs`** — add `rcBytesFiles` (and a fold/golden subset) to the differential (`rcDifferentialHarness`), stats (`rcStatsHarness`), C-parity (`rcCBackendParity`), and `run golden` (`:295`) groups, mirroring `rcStringFiles`/`rcStringFoldFiles`.
- [ ] **Step 3: Update `interpPrimTests`** (`:4705-4722`) to include `(Std.Bytes, fromList/toList/length/index/fromBytes/toBytes)` and `(Std.Base, eqBytes)`.
- [ ] **Step 4: Agreement + property tests** — an hspec group running both `validateUtf8` and (via `wokValidateUtf8` over a pinned buffer) the C DFA across the corpus asserting equality; QuickCheck `prop_validators_agree`, `prop_frombytes_tobytes_roundtrip`, `prop_tolist_fromlist_id`.
- [ ] **Step 5: Run + commit.** Run: `cabal test 2>&1 | tail -25` → green.
```bash
git add test/rc-bytes test/Spec.hs
git commit -m "test(bytes): validation corpus + oracle parity + validator agreement + properties"
```

```json:metadata
{"files": ["test/rc-bytes/", "test/Spec.hs"], "verifyCommand": "cabal test 2>&1 | tail -25", "acceptanceCriteria": ["corpus covers valid->Some + four-invalid->None + round-trips + OOB/out-of-range traps + eqBytes", "wired into differential/stats/C-parity/run-golden", "interpPrimTests lists all new prims", "Haskell<->C agreement + QuickCheck properties", "cabal test green"], "modelTier": "standard"}
```

---

## Self-review

**Spec coverage:** §3 type+rep → T4 (types), T6 (`VBytes`), T7 (`NBytes`/cell/plumbing). §3.3 tag plumbing (`internTag`/`wok_free`/`deref`) → T1 (`wok_free`), T7 (`internTag`/`deref`). §4 surface → T5 (names/prelude), T6/T7 (impls). §5 validator → T2 (C DFA), T3 (Haskell), T7 (C-heap wiring), T8 (cross-check). §6 conversions → T6/T7. §7 soundness → exercised by T8. §8 tests → T8. §9 file map → all tasks. All sections covered.

**Placeholder scan:** New/load-bearing code (DFA, `validateUtf8`, tags, prelude module, prim sketches) is shown; "mirror existing X at file:line" points at concrete source the implementer reads (not another task), which is actionable for standard-tier subagents. No TBD/TODO.

**Type consistency:** `validateUtf8 :: ByteString -> Bool` (T3) used in T6/T7. `wok_validate_utf8(const uint8_t*, uint64_t) -> int` (T2) bound as `wokValidateUtf8 :: Ptr Word8 -> Word64 -> IO Int` (T7). `VBytes`/`NBytes` carry `ByteString`; render format chosen in T6 and reused in T7. Prim name constants (T5) referenced in T6/T7/T8. `WOK_BYTES_TAG`/`wokBytesTag` = `0xFFFC` throughout.

**Dependencies:** T5→T4; T6→{T3,T4,T5}; T7→{T1,T2,T3,T4,T5}; T8→{T6,T7}. T1/T2/T3/T4 have no prerequisites.
