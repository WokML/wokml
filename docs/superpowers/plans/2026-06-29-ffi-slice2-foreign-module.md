# FFI Slice 2 — Foreign-Module Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give wok a user-facing FFI surface — a `foreign module Libc "c" free "free" where …` construct accessed as `Libc.member`, calling real deterministic libc through a blessed allow-list, with a new `IO` ground effect and an `owned`/`free` ownership surface that rides on the existing Perceus RC + escape analysis.

**Architecture:** A new `DForeign` grammar construct (mirroring `DClass`'s `where`-block, layout-virtual via the existing `where` keyword) registers a per-file foreign-module namespace in `envForeignModules`; `Libc.member` resolves through a `lookupForeignModule` arm beside the effect-operation dot (`Infer.hs:1795`). Members carry `with IO` (a new ground effect, discharged only at the program entry point). A foreign-member application elaborates to a new `AForeign` IR node carrying `(lib, symbol, disposition, freeSym)`; the runtime dispatches `(lib,symbol)` against a blessed allow-list (`memchr`, `strndup`) implemented via `foreign import ccall` on the C heap plus faithful Haskell models on the abstract/reference backends, reusing Slice 1's adopt machinery (`WokForeignBytes`, rc-zero foreign free) for `owned` returns.

**Tech Stack:** Haskell (GHC), BNFC (`bnfc --haskell -d --text-token`), Alex/Happy, the `wok_rc` C runtime, hspec/tasty + the differential oracle in `test/Spec.hs`, ASan/UBSan/LSan via `scripts/asan-runtime.sh`.

**User decisions (already made):**
- Honesty boundary "A": real deterministic libc only, blessed allow-list, no `dlopen`; unblessed symbols recognized-but-rejected with a clean error; the differential oracle stays alive. ("I think A.")
- Real libc WITH the wok→C borrow-out direction included. ("locking in A.")
- Surface "Design Y": one dedicated `foreign module` construct; `extern` stays prelude-only and untouched. ("OK locking in Y first.")
- Finaliser = GObject transfer model: `owned` return (transfer full → adopt) + `free "sym"` module header (deallocator); absence → copy. Rides on Perceus RC + escape analysis, NO new ownership analysis; `owned` is boundary metadata, not linear surface syntax. ("Greatttt, let's go with this.")
- `IO` is a Koka-style ground effect: no ops, un-handleable, un-forgeable, discharged only at the entry point, zero runtime cost. ("Sounds good.")
- Blessed set = `memchr` + `strndup` (length-explicit, byte-pure, deterministic); `strlen`/`strdup` excluded (NUL overread on wok's non-NUL-terminated `Bytes`). ("Run it autonomously.")
- Run autonomously (subagent-driven, this session); stop before merge to main for the user's own full-branch review (`review-before-merge`).

**Scope note (planner decision, deviates slightly from spec §3 item 7):** the Slice-1 `__ffi_demo_copy`/`__ffi_demo_adopt` intrinsics are **kept** as internal Tier-1/Tier-2 C-path test fixtures (not retired). Reason: the blessed surface set has no clean deterministic *copy-return* (transfer-none-return) libc function (`strndup` always transfers; exposing it without `owned` would leak), so retiring `__ffi_demo_copy` would drop Tier-1 copy-in coverage and break the `test/rc-ffi-bytes` corpus. The surface supersedes them for *users*; they remain as fixtures until a real copy-return consumer exists (deferred).

**Base branch:** `feat/ffi-foreign-module` (off `feat/ffi-bytes-in` tip `3bea88d`). Spec: `docs/superpowers/specs/2026-06-29-ffi-slice2-foreign-module-design.md`.

---

## File Structure

- `grammar/Wok.cf` — new `DForeign` + `ForeignFree` + `ForeignMember` + `ForeignSym` productions; new reserved keywords `foreign`/`owned`/`free`.
- `src-generated/GeneratedParser/Wok/{Abs,Par.y,Lex.x,Print,Layout,Doc.txt}.hs` — BNFC-regenerated; re-apply the three documented post-regen patches.
- `src/Wok/TypeChecking/Builtins.hs` — seed the `IO` ground effect into the initial environment.
- `src/Wok/TypeChecking/Env.hs` — `envForeignModules`, `ForeignModuleInfo`, `lookupForeignModule`.
- `src/Wok/TypeChecking/Infer.hs` — `EProj` foreign-module arm (`:1795`); entry-point `IO` discharge (new pass in `inferProgramTC` `:~3288`); `with`-handler-over-`IO` rejection; foreign-module registration during program setup; blessed-symbol honesty check.
- `src/Wok/TypeChecking/Error.hs` — new diagnostics: `ForeignSymbolNotBlessed`, `ForeignModuleMemberUnknown`, `IOEffectNotHandleable`, `AmbiguousProjectionHead`.
- `src/Wok/FFI/Blessed.hs` (NEW) — the blessed allow-list: `(lib, symbol) → BlessedSig` (arg/return marshalling shape + disposition), shared by the typecheck honesty check and the runtime dispatch.
- `src/Wok/IR/Anf.hs` — new `AForeign` representation (lib, symbol, disposition, freeSym).
- `src/Wok/IR/Elaborate.hs` — elaborate a resolved foreign-member application to `AForeign`.
- `src/Wok/Interp/Prim.hs` + `src/Wok/Interp/Value.hs` — reference-interpreter foreign-call execution (pure Haskell models).
- `src/Wok/Interp/RC/Prim.hs` + `src/Wok/Interp/RC/Value.hs` + `src/Wok/Interp/RC/Heap.hs` — RC abstract + C-heap foreign-call execution; `foreign import ccall` for `memchr`/`strndup`; borrow-out marshalling; copy/adopt disposition (reuse Slice-1 `allocNBytes` / `allocForeignBytes` / `dropAddr`).
- `runtime/` — only if a borrow-out helper is needed; prefer pure GHC `foreign import ccall` over new C.
- `test/Spec.hs`, `test/rc-ffi-foreign/` (NEW corpus), `scripts/asan-runtime.sh` — tests + sanitizer wiring.

---

### Task 1: Grammar — the `foreign module` construct + BNFC regen

**Goal:** Parse `foreign module Libc "c" free "free" where <indented members>` into a new `DForeign` AST node, members optionally `owned` with an optional symbol-override string.

**Files:**
- Modify: `grammar/Wok.cf` (after `DInstance` at `:108`; mirror the `DClass`/`ClassEntry` pattern)
- Regenerate: `src-generated/GeneratedParser/Wok/{Abs.hs,Par.y,Lex.x,Print.hs,Layout.hs,Doc.txt}`
- Test: the project's parser test harness (find it: `grep -rn "parseModule\|parseAndPrep\|golden" test/ | head`); add a parse golden/unit for the new construct.

**Acceptance Criteria:**
- [ ] `foreign module Libc "c" free "free" where` + indented members parses to `DForeign (ConId "Libc") "c" (FFSym "free") [members]`.
- [ ] A member `memchr : Bytes -> U64 -> U64 -> U64 with IO` parses to a plain `ForeignMember`; `owned strndup : Bytes -> U64 -> Bytes with IO` parses with the `owned` flag; `open64 "open64" : …` parses with the symbol override.
- [ ] A header with no `free` clause parses to `FFNone`.
- [ ] `foreign`, `owned`, `free` are reserved (not valid `VarId`); all existing tests still parse (full build green).

**Verify:** `cabal build 2>&1 | tail -5` (no errors) and `cabal test --test-options='--match "/parser/"' 2>&1 | tail -20` (new parse test PASS, all existing PASS). If there is no parser-tagged suite, `cabal test 2>&1 | tail -20` and confirm no regression beyond the known-pre-existing `perceus golden` failures.

**Steps:**

- [ ] **Step 1: Add the grammar productions.** In `grammar/Wok.cf`, immediately after the `DInstance` line (`:108`), add (mirrors `DClass` + `ClassEntry`; `where` is already a layout keyword so the block is layout-virtual — see `:105-106`):

```
-- Foreign module: a namespaced group of FFI bindings to a C library (Slice 2).
-- `where "{" ... "}"` is layout-virtual (where is a layout keyword). The library
-- string selects the host binding set; `free String` (optional) names the
-- deallocator for `owned` (transfer-full) members. A member's C symbol defaults
-- to its name; an optional leading string overrides it. `owned` on a member =
-- transfer full (adopt + free at rc-zero); its absence = copy (transfer none).
DForeign.   Decl ::= "foreign" "module" ConId String ForeignFree "where" "{" [ForeignMember] "}" ;
FFNone.     ForeignFree ::= ;
FFSym.      ForeignFree ::= "free" String ;
FMPlain.    ForeignMember ::= VarId ForeignSym ":" Type ;
FMOwned.    ForeignMember ::= "owned" VarId ForeignSym ":" Type ;
FSNone.     ForeignSym ::= ;
FSName.     ForeignSym ::= String ;
separator   ForeignMember ";" ;
```

- [ ] **Step 2: Regenerate with BNFC.** Run exactly the command documented in `wok.cabal:65`:

```bash
cd /Users/zy/wokml
~/.cabal/bin/bnfc --haskell -d --text-token -o src-generated grammar/Wok.cf
```

- [ ] **Step 3: Re-apply the THREE documented post-regen patches.** BNFC overwrites the generated files; re-apply the patches described verbatim in the `grammar/Wok.cf` header (`:13-79`). Use `git diff src-generated/` to see what bnfc changed, then restore the patched forms:
  1. `Layout.hs` — split the `isLayoutOpen || isParenOpen` branch; add `maybeInsertSeparator` only on the paren branch; lambda binder must be `pt` not `_` (grammar `:13-28`).
  2. `Par.y` — left-recursive `NEListRecordFieldPat`; route both `PRecord` and `PRecordOpen` through it with `reverse` (grammar `:30-60`).
  3. `Par.y` — hand-add the empty-record `ConId '{' '}'` AtomPat alternative (grammar `:62-73`).

  Confirm with: `git diff src-generated/GeneratedParser/Wok/Layout.hs` shows the `pt`/paren split, and `Par.y` shows `NEListRecordFieldPat` + the `ConId '{' '}'` rule. The new `DForeign`/`ForeignMember`/`ForeignSym`/`ForeignFree` data + happy rules need NO extra patch (`foreign`/`owned`/`free`/`where`/`String` all disambiguate by one-token lookahead, like `DExternData` did — grammar `:75-79`).

- [ ] **Step 4: Build (happy/alex regenerate `Par.hs`/`Lex.hs`).**

```bash
cabal build 2>&1 | tail -8
```
Expected: builds clean. If happy reports a shift/reduce conflict involving `ForeignMember`/`ForeignSym`, the optional `ForeignSym` (String vs `:`) needs no fix (one-token lookahead); a conflict means a patch was dropped — recheck Step 3.

- [ ] **Step 5: Write the parse test.** Locate the parser test entry (`grep -rn "Abs.DForeign\|Abs.DClass\|parseAndPrep\|describe \"parser\"" src test | head`). Add a unit asserting the three member forms parse. Example shape (adapt to the harness):

```haskell
it "parses a foreign module with owned + symbol-override members" $ do
  let src = unlines
        [ "module Main"
        , "foreign module Libc \"c\" free \"free\" where"
        , "  memchr : Bytes -> U64 -> U64 -> U64 with IO"
        , "  owned strndup : Bytes -> U64 -> Bytes with IO"
        , "  open64 \"open64\" : U64 -> U64 with IO"
        ]
  case parseModuleSource src of            -- use the project's real parse entry
    Right (Module decls) ->
      any isForeignDecl decls `shouldBe` True
    Left e -> expectationFailure (show e)
```

- [ ] **Step 6: Run the parse test + full build.**

```bash
cabal test 2>&1 | tail -20
```
Expected: new parse test PASS; no new failures (the only acceptable reds are the known pre-existing `perceus golden`/`perceus handler golden` from the base branch).

- [ ] **Step 7: Commit.**

```bash
git add grammar/Wok.cf src-generated/ test/
git commit -m "feat(ffi): foreign module grammar construct + BNFC regen (Task 1)"
```

```json:metadata
{"files": ["grammar/Wok.cf", "src-generated/GeneratedParser/Wok/Abs.hs", "src-generated/GeneratedParser/Wok/Par.y", "src-generated/GeneratedParser/Wok/Layout.hs"], "verifyCommand": "cabal build 2>&1 | tail -8 && cabal test 2>&1 | tail -20", "acceptanceCriteria": ["foreign module ... where parses to DForeign", "owned + symbol-override members parse", "no-free header parses to FFNone", "foreign/owned/free reserved; full build green"], "modelTier": "standard"}
```

---

### Task 2: The `IO` ground effect — registration + entry-point discharge

**Goal:** `with IO` type-checks (a registered ground effect with no ops); `IO` is permitted unhandled only at the program entry point; a `with`-handler over `IO` is rejected; all other unhandled effects still error.

**Files:**
- Modify: `src/Wok/TypeChecking/Builtins.hs` (seed `IO` alongside the builtin tycons)
- Modify: `src/Wok/TypeChecking/Infer.hs` (new post-`closeRow` entry-point pass in `inferProgramTC` `:~3288`; `with`-handler-over-`IO` rejection near the handler inference)
- Modify: `src/Wok/TypeChecking/Error.hs` (`IOEffectNotHandleable`)
- Test: `test/` typecheck suite (find via `grep -rn "UndischargedEffect\|describe \"typecheck\"\|inferProgram" test | head`)

**Acceptance Criteria:**
- [ ] A signature `f : U64 -> U64 with IO` type-checks (the name `IO` resolves to the ground effect).
- [ ] A top-level entry binding whose body's row contains `IO` type-checks (IO discharged at entry); the SAME `IO` in a non-entry binding's final closed row is reported normally.
- [ ] A different unhandled effect (e.g. `State`) in any binding still throws `UndischargedEffect` (no loosening).
- [ ] A `with`-handler block over `IO` throws `IOEffectNotHandleable`.

**Verify:** `cabal test --test-options='--match "/IO effect/"' 2>&1 | tail -20` (or the typecheck suite) → all PASS.

**Steps:**

- [ ] **Step 1: Seed the `IO` ground effect.** In `Builtins.hs`, where builtin effects/tycons are added to the initial `Env` (find: `grep -n "envEffects\|EffectInfo\|TcBytes\|initialEnv\|builtinEffects" src/Wok/TypeChecking/Builtins.hs`), add an `EffectInfo` named `IO` with an EMPTY op map and zero type params. Mirror an existing builtin effect registration if one exists; otherwise construct the `EffectInfo` the same way `lookupEffect`'s consumers expect (empty `eiOps`). Add a doc comment: "IO — the ground effect: no ops, never handled, discharged only at the program entry point."

- [ ] **Step 2: Write the failing tests.** Add to the typecheck suite:

```haskell
describe "IO effect" $ do
  it "type-checks a sig with `with IO`" $
    typeChecks "module Main\nf : U64 -> U64 with IO\nf x = x"  -- using a foreign call later; for now a bare sig must resolve IO
      `shouldBe` Right ()
  it "permits IO unhandled at the entry binding" $
    typeChecks entryUsesIOProgram `shouldBe` Right ()
  it "still rejects a different unhandled effect" $
    typeCheckError forgottenStateProgram `shouldSatisfy` isUndischargedEffect
  it "rejects a handler over IO" $
    typeCheckError handleIOProgram `shouldSatisfy` isIOEffectNotHandleable
```
Run: `cabal test --test-options='--match "/IO effect/"'` → FAIL (IO unregistered / no discharge).

- [ ] **Step 3: Implement the entry-point discharge.** In `inferProgramTC` (`Infer.hs:~3288`), AFTER the per-binding `closeRow` (`:3168`) / `UndischargedEffect` (`:2486`) handling, add a pass that: identifies the entry binding (the `--run` target, or the binding named `main` — match the convention the runner uses; find via `grep -rn "\"main\"\|runTarget\|entryPoint\|--run" src | head`), and for THAT binding only, treats `IO` as already-discharged (filter `IO` out of the must-be-handled set before the `UndischargedEffect` throw). Do NOT modify the existing throw for any other binding/effect. Add a comment pointing at the spec §4.3.

  Note on layering: if the existing per-binding loop throws `UndischargedEffect` eagerly (before the entry is known), refactor minimally so the entry binding's `IO` is exempted — e.g. compute the entry name first, then pass an `ioExempt :: Bool` into the close for that binding. Keep the change surgical.

- [ ] **Step 4: Reject handlers over IO.** Where a `with`-handler block resolves its handled effect (find: `grep -n "lookupEffect\|handler\|HandleW\|inferHandle" src/Wok/TypeChecking/Infer.hs | head`), if the handled effect is `IO`, `throwError (IOEffectNotHandleable sp)`. (IO has no ops, so this also fails naturally; the explicit error gives a clear message.) Add `IOEffectNotHandleable SourceSpan` to `Error.hs` with a message like "IO is a ground effect and cannot be handled; it is discharged by running the program."

- [ ] **Step 5: Run tests to green.** `cabal test --test-options='--match "/IO effect/"'` → PASS. Full `cabal test 2>&1 | tail -20` → no new reds.

- [ ] **Step 6: Commit.**

```bash
git add src/Wok/TypeChecking/ test/
git commit -m "feat(ffi): IO ground effect + entry-point discharge (Task 2)"
```

```json:metadata
{"files": ["src/Wok/TypeChecking/Builtins.hs", "src/Wok/TypeChecking/Infer.hs", "src/Wok/TypeChecking/Error.hs"], "verifyCommand": "cabal test --test-options='--match \"/IO effect/\"' 2>&1 | tail -20", "acceptanceCriteria": ["with IO type-checks", "IO discharged only at entry", "other unhandled effects still error", "handler over IO rejected"], "modelTier": "standard"}
```

---

### Task 3: Foreign-module registration + `lookupForeignModule` + `Libc.member` resolution + blessed honesty check

**Goal:** A `DForeign` in a program registers `Libc` into `envForeignModules`; `Libc.member` resolves to the member's declared type (carrying `with IO`); an unblessed `(lib,symbol)` is a clean compile error; an unknown member or a head that is both an effect and a foreign module errors clearly.

**Files:**
- Create: `src/Wok/FFI/Blessed.hs` (the allow-list, shared with the runtime)
- Modify: `src/Wok/TypeChecking/Env.hs` (`ForeignModuleInfo`, `envForeignModules`, `lookupForeignModule` beside `lookupEffect:223`)
- Modify: `src/Wok/TypeChecking/Infer.hs` (collect `DForeign` during program setup; `EProj` arm at the `inferProjection` fallback call `:1795`)
- Modify: `src/Wok/TypeChecking/Error.hs` (`ForeignSymbolNotBlessed`, `ForeignModuleMemberUnknown`, `AmbiguousProjectionHead`)
- Test: typecheck suite

**Acceptance Criteria:**
- [ ] `Libc.memchr` (declared in a file's `foreign module Libc "c" …`) resolves to `Bytes -> U64 -> U64 -> U64 with IO`; applying it emits `IO`.
- [ ] `Libc.strndup` resolves with the `owned` disposition recorded.
- [ ] A `foreign module Bad "c" where frob : U64 -> U64 with IO` (symbol `("c","frob")` not blessed) → `ForeignSymbolNotBlessed`.
- [ ] `Libc.nope` (unknown member) → `ForeignModuleMemberUnknown`; a `ConId` that is both an effect and a foreign module → `AmbiguousProjectionHead`.
- [ ] A non-foreign-module head still falls through to record/named-perform projection unchanged.

**Verify:** `cabal test --test-options='--match "/foreign resolution/"' 2>&1 | tail -20` → PASS.

**Steps:**

- [ ] **Step 1: Define the blessed allow-list.** Create `src/Wok/FFI/Blessed.hs`:

```haskell
module Wok.FFI.Blessed
  ( BlessedSig(..), ReturnDisp(..), blessedTable, lookupBlessed ) where

import qualified Data.Map.Strict as Map
import           Data.Text (Text)

-- | How a foreign call's RETURN buffer is taken into the RC runtime.
data ReturnDisp
  = DispScalar             -- ^ returns a U64; no buffer, no ownership question
  | DispCopy               -- ^ transfer none: copy the bytes into a WokBytes cell
  | DispAdopt              -- ^ transfer full: adopt the foreign buffer, free at rc-zero
  deriving (Eq, Show)

-- | A blessed (lib,symbol): its return disposition. (Argument marshalling is
-- determined by the wok type at the call site; only buffer args borrow-out.)
data BlessedSig = BlessedSig { bsReturn :: ReturnDisp }
  deriving (Eq, Show)

blessedTable :: Map.Map (Text, Text) BlessedSig
blessedTable = Map.fromList
  [ (("c", "memchr"),  BlessedSig DispScalar)
  , (("c", "strndup"), BlessedSig DispAdopt)
  ]

lookupBlessed :: Text -> Text -> Maybe BlessedSig
lookupBlessed lib sym = Map.lookup (lib, sym) blessedTable
```

- [ ] **Step 2: Add the env structures.** In `Env.hs` near `lookupEffect` (`:223`):

```haskell
data ForeignModuleInfo = ForeignModuleInfo
  { fmiLib     :: Text                       -- ^ library string, e.g. "c"
  , fmiFree    :: Maybe Text                 -- ^ deallocator symbol from `free "..."`
  , fmiMembers :: Map.Map Text ForeignMember -- ^ member name -> resolved member
  }

data ForeignMember = ForeignMember
  { fmSymbol :: Text       -- ^ C symbol (member name or override)
  , fmType   :: CType      -- ^ declared wok type (carries `with IO`)
  , fmOwned  :: Bool       -- ^ `owned` => adopt; else copy
  }

-- in Env: envForeignModules :: Map.Map Text ForeignModuleInfo
lookupForeignModule :: Text -> Env -> Maybe ForeignModuleInfo
lookupForeignModule k = Map.lookup k . envForeignModules
```
Add `envForeignModules` to the `Env` record with an empty-map default everywhere `Env` is constructed.

- [ ] **Step 3: Register `DForeign` during program setup.** In `inferProgramTC` (before expression inference), fold each `Abs.DForeign con lib free members` into `envForeignModules`. For each member: compute the symbol (override or member name); type-check its declared `Type` to a `CType`; record `fmOwned`. **Honesty check:** `case lookupBlessed lib sym of Nothing -> throwError (ForeignSymbolNotBlessed pos lib sym); Just bs -> ...`. If `fmOwned` but `free` is absent → a clear error ("owned member requires a `free` clause on the module"). Reject a `ConId` already present in `envEffects` (`AmbiguousProjectionHead`).

- [ ] **Step 4: Add the `EProj` foreign-module arm.** At `Infer.hs:1795` (the `inferProjection` fallback for `EProj (ECon ename) (VarId label)`), BEFORE falling through, try `lookupForeignModule ename`:

```haskell
-- (after the effect-op `lookupEffect` arm, before inferProjection fallback)
case lookupForeignModule ename env of
  Just fmi
    | Just m <- Map.lookup label (fmiMembers fmi) -> do
        ty <- instantiateForeignMember m           -- fresh-instantiate fmType
        pure (ty, foreignProjNode ename label)     -- carry (ename,label) for elaboration
    | otherwise -> throwError (ForeignModuleMemberUnknown pos ename label)
  Nothing -> <existing inferProjection fallback>
```
Applying the resulting arrow type emits `IO` by ordinary application inference (no special handling). The `foreignProjNode` records `(foreignModuleName, memberName)` so elaboration (Task 5) can recover `(lib, symbol, owned, free)` from `envForeignModules`.

- [ ] **Step 5: Tests.** Add `describe "foreign resolution"` covering all five acceptance criteria (resolve memchr/strndup, unblessed error, unknown-member error, ambiguous-head error, non-foreign fallthrough). Write them failing first, then green.

- [ ] **Step 6: Commit.**

```bash
git add src/Wok/FFI/ src/Wok/TypeChecking/ test/ wok.cabal
git commit -m "feat(ffi): foreign-module registration + lookupForeignModule resolution + blessed honesty check (Task 3)"
```
(Remember to add `Wok.FFI.Blessed` to `wok.cabal`'s exposed/other-modules.)

```json:metadata
{"files": ["src/Wok/FFI/Blessed.hs", "src/Wok/TypeChecking/Env.hs", "src/Wok/TypeChecking/Infer.hs", "src/Wok/TypeChecking/Error.hs", "wok.cabal"], "verifyCommand": "cabal test --test-options='--match \"/foreign resolution/\"' 2>&1 | tail -20", "acceptanceCriteria": ["Libc.memchr/strndup resolve with disposition", "unblessed symbol errors", "unknown member errors", "ambiguous head errors", "non-foreign fallthrough unchanged"], "modelTier": "standard"}
```

---

### Task 4: Gate-flip verification — foreign members user-allowed; bare `extern` still rejected

**Goal:** Confirm (with tests) that a user file may declare a `foreign module` while a user-file bare `extern` still errors — i.e. the capability is the construct, and the existing `ExternNotAllowed` gate is untouched and unbypassed.

**Files:**
- Modify (only if needed): `src/Wok/TypeChecking/Infer.hs` (the gate at `:3340-3346` / `externDecls` `:3411-3418` — confirm `DForeign` is NOT collected by `externDecls`; add a guard ONLY if it is)
- Test: typecheck suite

**Acceptance Criteria:**
- [ ] A `UserFile` containing a `foreign module Libc "c" …` compiles (no `ExternNotAllowed`).
- [ ] A `UserFile` containing a bare `extern f : U64 -> U64` still throws `ExternNotAllowed`.
- [ ] An `Embedded` (prelude) bare `extern` still works (no regression).

**Verify:** `cabal test --test-options='--match "/extern gate/"' 2>&1 | tail -20` → PASS.

**Steps:**

- [ ] **Step 1: Verify the gate scope.** Read `externDecls` (`Infer.hs:3411-3418`): it matches `Abs.DExtern` (and `DLocal` recursion). Confirm it does NOT match `Abs.DForeign`. If it doesn't (expected), the gate already ignores foreign modules — no code change.

- [ ] **Step 2: Write the both-directions tests.**

```haskell
describe "extern gate" $ do
  it "allows a foreign module in a user file" $
    typeChecksUserFile foreignModuleUserProgram `shouldBe` Right ()
  it "still rejects a bare extern in a user file" $
    typeCheckErrorUserFile bareExternUserProgram `shouldSatisfy` isExternNotAllowed
```
Run → the foreign-module test should already PASS (Task 3); the bare-extern test should already PASS (gate unchanged). If the foreign-module test fails with `ExternNotAllowed`, add a guard in `inferProgramTC` so `DForeign` members bypass `externDecls` (they have their own user-allowed path).

- [ ] **Step 3: Run + commit.**

```bash
cabal test --test-options='--match "/extern gate/"' 2>&1 | tail -20
git add src/Wok/TypeChecking/ test/
git commit -m "test(ffi): gate-flip both directions (foreign allowed, bare extern rejected) (Task 4)"
```

```json:metadata
{"files": ["src/Wok/TypeChecking/Infer.hs", "test/Spec.hs"], "verifyCommand": "cabal test --test-options='--match \"/extern gate/\"' 2>&1 | tail -20", "acceptanceCriteria": ["foreign module allowed in user file", "bare extern still rejected in user file", "embedded extern unregressed"], "modelTier": "mechanical"}
```

---

### Task 5: Foreign-call IR + elaboration + reference-interpreter execution

**Goal:** A resolved foreign-member application elaborates to an `AForeign` node carrying `(lib, symbol, disposition, freeSym)`; the reference interpreter executes `Libc.memchr`/`Libc.strndup` via faithful pure Haskell models.

**Files:**
- Modify: `src/Wok/IR/Anf.hs` (the `AForeign` representation, near `APrim` `:49-54`)
- Modify: `src/Wok/IR/Elaborate.hs` (emit `AForeign` for a foreign-member application; near the `APrim` routing `:87-92`)
- Modify: `src/Wok/Interp/Prim.hs` + `src/Wok/Interp/Value.hs` (reference-interpreter foreign-call evaluation + the `memchr`/`strndup` models)
- Test: a reference-backend execution test through the surface

**Acceptance Criteria:**
- [ ] `AForeign` carries `(lib, symbol, ReturnDisp, Maybe freeSym)` and is traversed by the existing analyses as a strict call that BORROWS its `Bytes` args (caller retains ownership) and produces a fresh result.
- [ ] On the reference backend, `Libc.memchr (fromList [65,66,67]) 66 3` returns `1`; `Libc.memchr … 99 3` returns `3` (absent → n).
- [ ] On the reference backend, `Libc.strndup (fromList [1,2,3,4]) 2` returns a `Bytes` equal to `fromList [1,2]`; with `n` ≥ length and no NUL, returns the full copy.

**Verify:** `cabal test --test-options='--match "/foreign reference/"' 2>&1 | tail -20` → PASS.

**Steps:**

- [ ] **Step 1: Add the `AForeign` representation.** In `Anf.hs`, add a foreign-call form. A foreign call is NOT an `APrim` (which is a trusted prelude extern; analyses key trusted-once-sinks on `APrim`). Add a distinct expression/atom variant, e.g. in the `Expr` call forms:

```haskell
-- A user-declared foreign call. Distinct from APrim: never a trusted once-sink;
-- carries the resolved C symbol + how its return buffer enters the RC runtime.
-- Args are BORROWED (read-only; the caller retains ownership). lib/sym key the
-- blessed host binding; disp says copy/adopt/scalar; freeSym is the deallocator
-- for the adopt case.
data ForeignCall = ForeignCall
  { fcLib  :: Text, fcSym :: Text
  , fcDisp :: ReturnDisp           -- from Wok.FFI.Blessed
  , fcFree :: Maybe Text
  , fcArgs :: [Atom]
  }
```
Wire it into the IR call-evaluation traversal (free-vars, pretty-print, any fold over calls) treating `fcArgs` as borrowed reads. Import `ReturnDisp` from `Wok.FFI.Blessed`.

- [ ] **Step 2: Elaborate foreign-member applications.** In `Elaborate.hs`, when the head of an application is a resolved foreign-member projection (the `foreignProjNode` from Task 3 step 4), look up `(lib, free, member{symbol,owned})` from the registered foreign module, map `owned`+return-type to `ReturnDisp` (`owned` → `DispAdopt`; non-buffer return → `DispScalar`; buffer return without `owned` → `DispCopy`), and emit `ForeignCall`. The blessed `bsReturn` from `lookupBlessed` must agree with the type-derived disposition (assert/prefer the blessed one — it is the contract of record).

- [ ] **Step 3: Reference models.** In `Interp/Prim.hs` (or the reference eval of a `ForeignCall`), implement the two host models purely (no C), dispatching on `(lib,sym)`:

```haskell
-- ("c","memchr"): (buf, byte, n) -> offset of first (byte .&. 0xFF) in buf[0..n), else n
foreignMemchr :: ByteString -> Word64 -> Word64 -> Word64
foreignMemchr bs byte n =
  let n'  = fromIntegral (min n (fromIntegral (BS.length bs)))
      tgt = fromIntegral (byte .&. 0xFF)
  in maybe (fromIntegral n') fromIntegral (BS.elemIndex tgt (BS.take n' bs))

-- ("c","strndup"): (buf, n) -> first min(n, strnlen) bytes (NUL excluded)
foreignStrndup :: ByteString -> Word64 -> ByteString
foreignStrndup bs n =
  let capped = BS.take (fromIntegral n) bs
  in BS.takeWhile (/= 0) capped
```
The `memchr` result is a `VU64`; the `strndup` result is `VBytes` (reference backend has no ownership). Dispatch an unblessed `(lib,sym)` to an `error`/`PrimError` "not available in the interpreter" (defensive; typecheck already rejected it).

- [ ] **Step 4: Tests (failing → green).** Add `describe "foreign reference"` with the three acceptance cases; run on the reference backend only.

- [ ] **Step 5: Commit.**

```bash
git add src/Wok/IR/ src/Wok/Interp/Prim.hs src/Wok/Interp/Value.hs test/
git commit -m "feat(ffi): AForeign IR + elaboration + reference-interp foreign calls (Task 5)"
```

```json:metadata
{"files": ["src/Wok/IR/Anf.hs", "src/Wok/IR/Elaborate.hs", "src/Wok/Interp/Prim.hs", "src/Wok/Interp/Value.hs"], "verifyCommand": "cabal test --test-options='--match \"/foreign reference/\"' 2>&1 | tail -20", "acceptanceCriteria": ["AForeign carries lib/sym/disp/free; args borrowed", "memchr reference model correct (present + absent)", "strndup reference model correct (truncate + full copy)"], "modelTier": "standard"}
```

---

### Task 6: RC backends — real `foreign import ccall` + borrow-out + copy/adopt + differential parity

**Goal:** `Libc.memchr`/`Libc.strndup` execute on both RC backends — the abstract heap (faithful models, adopt charges the 24 B handle) and the C heap (real `foreign import ccall "memchr"/"strndup"`, borrow-out of the wok buffer, `strndup`'s malloc'd result adopted and freed at rc-zero) — with the differential oracle (output + logical stats) green across all three backends.

**Files:**
- Modify: `src/Wok/Interp/RC/Heap.hs` (`foreign import ccall unsafe "memchr"` / `"strndup"`; reuse Slice-1 `wok_foreign_bytes_alloc`/`_ptr`/`_len` imports)
- Modify: `src/Wok/Interp/RC/Prim.hs` + `src/Wok/Interp/RC/Value.hs` (RC `ForeignCall` evaluation: abstract models + C-heap real calls; borrow-out marshalling; `DispAdopt` → Slice-1 `allocForeignBytes` + module deallocator at rc-zero; `DispCopy` → `allocNBytes`; `DispScalar` → U64)
- Test: `test/Spec.hs` differential-oracle wiring for the two surface functions

**Acceptance Criteria:**
- [ ] All three backends agree on output for `Libc.memchr`/`Libc.strndup` across present/absent, truncate/full, and NUL-bearing inputs.
- [ ] All three backends agree on logical `peak_bytes`; an adopted `strndup` result charges the fixed 24 B handle (Slice-1 §4.6), and the oracle PINS the zero-copy saving vs an equivalent copy.
- [ ] The borrowed `Bytes` argument's refcount/lifetime is unchanged by the call (it is dropped normally at end of scope, exactly once); C never frees it.
- [ ] `strndup`'s adopted handle is initialized with the TRUE returned length (NUL excluded), never `n`.

**Verify:** `cabal test --test-options='--match "/rc-ffi-foreign/"' 2>&1 | tail -30` → PASS across reference/abstract/CHeap.

**Steps:**

- [ ] **Step 1: C bindings.** In `RC/Heap.hs`, add:

```haskell
foreign import ccall unsafe "string.h memchr"
  c_memchr :: Ptr Word8 -> CInt -> CSize -> IO (Ptr Word8)
foreign import ccall unsafe "string.h strndup"
  c_strndup :: Ptr Word8 -> CSize -> IO (Ptr Word8)
-- strlen on strndup's NUL-terminated result, to recover the true length:
foreign import ccall unsafe "string.h strlen"
  c_strlen :: Ptr Word8 -> IO CSize
```
(Slice-1's `wok_foreign_bytes_alloc`/`_ptr`/`_len` imports already exist in this module — reuse them.)

- [ ] **Step 2: RC abstract models.** In the RC `ForeignCall` evaluation, on the abstract heap dispatch `(lib,sym)` to the SAME pure models as the reference backend (Task 5 step 3), but produce RC nodes: `memchr` → scalar; `strndup` → `NForeignBytes bs` (Slice-1 adopt node) charging the fixed 24 B handle, where `bs` is the `foreignStrndup` result. This keeps abstract `peak_bytes` tracking the handle, not the foreign buffer.

- [ ] **Step 3: C-heap real calls + borrow-out.** On `CHeap`, evaluate `ForeignCall`:
  - Resolve each `Bytes` argument to its cell, take the inline data pointer (`wok_bytes_data` for a `WokBytes`, or the Slice-1 foreign-bytes accessor for an adopted arg) and its length. This is the **borrow-out**: pass the pointer to C for the synchronous call only; do NOT consume or free the wok cell. After the call, drop the arg normally (it was borrowed → its refcount path is unchanged).
  - `memchr`: `p <- c_memchr argPtr (fromIntegral byte) (fromIntegral (min n len))`; result = if `p == nullPtr` then `n'` else `p `minusPtr` argPtr` (as `Word64`). Produce the scalar.
  - `strndup`: `p <- c_strndup argPtr (fromIntegral n)`; `len <- c_strlen p` (safe — strndup NUL-terminates); wrap `p` in a `WokForeignBytes` via `allocForeignBytes p len` (Slice-1), recording the module deallocator (`free`) as the rc-zero destructor. The handle charges 24 B; `len` is the true byte count, never `n`. The abstract-side `NForeignBytes` and the C-side handle must hold/expose identical bytes (`deref` reconstructs them — Slice 1).
  - `DispCopy` (not used by the blessed set yet, but implement for completeness): `memcpy` the foreign buffer into a `WokBytes` via `allocNBytes`, then free the foreign original. (No blessed function exercises this; keep it a small, tested-by-construction branch or `error "no blessed copy-return symbol"` until one exists — prefer implementing it so it is ready.)

- [ ] **Step 4: Borrow-out soundness wiring.** Ensure the RC dup/drop placement treats `ForeignCall` args as borrowed: the call reads them; the caller's ownership is unchanged; the normal end-of-scope drop frees them exactly once. (Interpreter "always counts" — no zero-cost borrow yet; soundness is the bar, per E4.) Verify the escape fence: an `owned Bytes` result is `TcBytes` → `Region.isStringType` routes it to the counted heap, never an arena (Slice 1 §5.2) — confirm, do not change.

- [ ] **Step 5: Differential oracle wiring + tests.** Add `test/rc-ffi-foreign/` programs (Step from Task 7 creates the full corpus; here add at least the parity smoke cases) and wire them into the `test/Spec.hs` rc-bytes-style oracle (compare reference vs abstract vs CHeap output + `stPeakBytes`/`wokStatPeakBytes`). Include an adopt-vs-copy `peak_bytes` saving pin (de-tautologized: pin the concrete `24` for the handle and `16+8*ceil(len/8)` for an equivalent copy, per Slice 1).

- [ ] **Step 6: Build with the C runtime + run.**

```bash
cabal test --test-options='--match "/rc-ffi-foreign/"' 2>&1 | tail -30
```
Expected: PASS on all three backends.

- [ ] **Step 7: Commit.**

```bash
git add src/Wok/Interp/RC/ test/
git commit -m "feat(ffi): RC foreign calls (real ccall memchr/strndup) + borrow-out + adopt + oracle parity (Task 6)"
```

```json:metadata
{"files": ["src/Wok/Interp/RC/Heap.hs", "src/Wok/Interp/RC/Prim.hs", "src/Wok/Interp/RC/Value.hs", "test/Spec.hs"], "verifyCommand": "cabal test --test-options='--match \"/rc-ffi-foreign/\"' 2>&1 | tail -30", "acceptanceCriteria": ["3-backend output parity", "3-backend peak_bytes parity + adopt 24B handle saving pinned", "borrowed arg lifetime unchanged; C never frees it", "strndup adopt uses true length not n"], "modelTier": "standard"}
```

---

### Task 7: Soundness tests, corpus, sanitizers, and end-to-end negatives

**Goal:** The adopt/borrow soundness has teeth (death tests + negative controls + sanitizers), the corpus mirrors `test/rc-ffi-bytes`, and the gate/honesty/IO negatives are pinned.

**Files:**
- Create: `test/rc-ffi-foreign/*.wok` (corpus)
- Modify: `test/Spec.hs` (corpus wiring, death tests, negatives)
- Modify: `scripts/asan-runtime.sh` (link any new C — likely none, since we use libc `memchr`/`strndup` + Slice-1's C; confirm the foreign-bytes lifecycle is covered)

**Acceptance Criteria:**
- [ ] Dup-then-drop of an adopted `Libc.strndup` result frees the foreign buffer EXACTLY once (mutation-confirmed: inject a double-free → SIGABRT under the CHeap/libc run).
- [ ] Negative control: skipping the foreign free → LSan leak; calling `wok_free` on `data_ptr` → ASan bad-free (proves the test has teeth).
- [ ] Borrow-out: ASan/UBSan over `Libc.memchr`/`strndup` show no overread of the borrowed buffer and the lent buffer is not freed by C.
- [ ] Negatives: unblessed symbol → clean compile error; bare extern in user file → `ExternNotAllowed`; handler over IO → `IOEffectNotHandleable`; a forgotten non-IO effect → `UndischargedEffect`.
- [ ] ASan/UBSan/LSan clean across arena / malloc-UAF / poison-on-free backends.

**Verify:** `cabal test --test-options='--match "/rc-ffi-foreign/"' 2>&1 | tail -30` PASS; `bash scripts/asan-runtime.sh 2>&1 | tail -20` clean.

**Steps:**

- [ ] **Step 1: Corpus.** Create `test/rc-ffi-foreign/` mirroring `test/rc-ffi-bytes/`: `01-memchr-present`, `02-memchr-absent`, `03-strndup-truncate`, `04-strndup-full`, `05-strndup-nul`, `06-roundtrip-fromBytes` (feed `strndup` result into `fromBytes`), `07-soundness-dup-share` (dup an adopted result, two drops, free once), `08-borrow-arg-survives` (use the borrowed arg after the call → unchanged). Each is a `module Main` with an inline `foreign module Libc "c" free "free" where …`. Wire them into the oracle.

- [ ] **Step 2: Adopt death test + negative control.** Port `test/rc-ffi-bytes/07-soundness-dup-share` semantics to `Libc.strndup`. Add the negative-control toggles (a gated build flag or a direct C lifecycle test) asserting: skip-free → LSan, wrong-free → ASan. Mutation-confirm by temporarily injecting a double-free and observing SIGABRT (document the observation in a comment; revert the injection).

- [ ] **Step 3: Borrow-out sanitizer test.** A direct test that runs `Libc.memchr`/`strndup` on a wok buffer under ASan and asserts no overread (length-bounded reads) and that the borrowed cell is intact afterwards. Ensure `scripts/asan-runtime.sh` links every C path exercised (Slice-1 `wok_rc.c` already linked; libc needs no extra link). If a new `.c` is added, add it to the script (the E6 `wok_utf8.c` lesson).

- [ ] **Step 4: Negatives.** Add typecheck negative tests (unblessed symbol, bare extern in user file, handler over IO, forgotten non-IO effect) if not already covered by Tasks 2-4; assert the specific error constructors.

- [ ] **Step 5: Run the full gate.**

```bash
cabal test 2>&1 | tail -30                       # only known pre-existing perceus-golden reds allowed
bash scripts/asan-runtime.sh 2>&1 | tail -20     # ASan/UBSan/LSan clean
```

- [ ] **Step 6: Commit.**

```bash
git add test/ scripts/asan-runtime.sh
git commit -m "test(ffi): foreign-module corpus + adopt/borrow death tests + sanitizers + negatives (Task 7)"
```

```json:metadata
{"files": ["test/rc-ffi-foreign", "test/Spec.hs", "scripts/asan-runtime.sh"], "verifyCommand": "cabal test 2>&1 | tail -30 && bash scripts/asan-runtime.sh 2>&1 | tail -20", "acceptanceCriteria": ["adopt freed exactly once (mutation-confirmed SIGABRT)", "negative controls trip LSan/ASan", "borrow-out no overread; lent buffer intact", "unblessed/bare-extern/IO-handler/forgotten-effect negatives pinned", "ASan/UBSan/LSan clean"], "modelTier": "standard"}
```

---

## Self-Review

**Spec coverage:**
- §4.1 foreign-module construct → Task 1 (grammar) + Task 3 (registration). ✓
- §4.2 owned/free transfer model → Task 3 (record `owned`/`free`) + Task 5/6 (disposition → copy/adopt). ✓
- §4.3 IO ground effect → Task 2. ✓
- §4.4 lookupForeignModule resolution → Task 3. ✓
- §4.5 gate flip → Task 4. ✓
- §4.6 blessed allow-list + marshalling (memchr/strndup, borrow-out, NUL finding) → Task 3 (allow-list) + Task 5 (models) + Task 6 (real ccall + borrow-out + true-length adopt). ✓
- §4.7 backend modeling → Task 5 (reference) + Task 6 (abstract + CHeap). ✓
- §5 soundness invariants → Task 6 (escape fence, borrow-out) + Task 7 (death tests, teeth). ✓
- §6 testing → Tasks 1-7 verify blocks + Task 7 corpus. ✓
- §3 deferrals (borrow tier, opaque types, arg-transfer, dlopen, retirement) → not built, recorded. ✓ (Retirement explicitly re-scoped to "keep as fixtures" in the header.)

**Placeholder scan:** No "TBD"/"implement later". Integration steps cite exact files, anchors, and the pattern to mirror (`DClass`, Slice-1 adopt node, the effect-op dot), with concrete test code — these are concrete instructions, not placeholders. The one `DispCopy` branch with no blessed consumer is implemented-for-readiness, flagged.

**Type consistency:** `ReturnDisp` (`Wok.FFI.Blessed`) used consistently in Tasks 3/5/6. `ForeignModuleInfo`/`ForeignMember` fields (`fmiLib`/`fmiFree`/`fmiMembers`; `fmSymbol`/`fmType`/`fmOwned`) consistent across Tasks 3/5. `ForeignCall` fields (`fcLib`/`fcSym`/`fcDisp`/`fcFree`/`fcArgs`) consistent across Tasks 5/6. Error constructors (`ForeignSymbolNotBlessed`, `ForeignModuleMemberUnknown`, `AmbiguousProjectionHead`, `IOEffectNotHandleable`) consistent across Tasks 2/3/4/7.

**Dependencies:** 1→3, 2→3, 3→4, 3→5, 5→6, 6→7. Tasks 1 and 2 are independent (parallelizable).
