# Algebraic Effects v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Light up the v1 algebraic-effects surface (effect declarations, `with`-clause effect rows, qualified operation calls, and `handle … of` handlers) in the Wok type-checker, reusing the existing Leijen-2005 row machinery. Type-checking only — no runtime.

**Architecture:** Effect rows ride the dormant effect-row slot already present on the arrow (`TArr (Type s) (Row s) (Type s)` / `CTArr CType CRow CType`) and unify with the existing `unifyRow`/`rewriteRow`. Effect declarations register an `EffectInfo` in a new `envEffects` namespace. A `with` clause translates to the arrow's `Row`; an operation call `E.op` requires `E`'s label in the ambient row; a handler discharges the handled effect's labels from the row. Effect bodies parse exactly like record `data` bodies via the existing `Wok.RecordLayout` block-form pre-pass.

**Tech Stack:** Haskell (GHC 9.10, GHC2024), BNFC + Alex + Happy (grammar), `tasty`/`tasty-golden`/`tasty-hunit` (tests). Spec: `docs/superpowers/specs/2026-05-31-algebraic-effects-v1-surface-design.md`.

---

## File structure

| File | Responsibility | Change |
| --- | --- | --- |
| `grammar/Wok.cf` | Surface grammar | Add effect decls, `with`-arrows, effect rows, anonymous record tail, handlers; new keywords |
| `src/GeneratedParser/Wok/*` | BNFC output | Regenerate; reapply documented layout/Par.y patches |
| `src/Wok/RecordLayout.hs` | Block-form brace pre-pass | Classify the effect-decl `= {` brace as a record (comma) brace |
| `src/Wok/TypeChecking/Types.hs` | Type/row representation | No change (slot already exists); reused |
| `src/Wok/TypeChecking/Env.hs` | Typing environment | Add `envEffects :: Map Text EffectInfo`, `EffectInfo`, `NsEffect` |
| `src/Wok/TypeChecking/Error.hs` | Error/warning variants | Add effect error variants |
| `src/Wok/TypeChecking/Unify.hs` | Unification | Reused as-is |
| `src/Wok/TypeChecking/Infer.hs` | Inference + sig translation + printing | Effect decls, `with` translation, op-call typing, handler typing, effect-row printing |
| `test/typecheck-examples/*.wok` + `test/typecheck-golden/*.expected` | Success goldens | New fixtures (20–25) |
| `test/typecheck-fail-examples/*.wok` + `test/typecheck-fail-golden/*.expected` | Failure goldens | New fixtures |
| `test/Spec.hs` | Unit tests | Effect-typing unit tests |

**Milestones:** M1 = Tasks 1–8 (declarations, `with`-arrows, operation calls). M2 = Tasks 9–11 (handlers). Grammar for both milestones lands in Task 1 (one regen); the `handle` AST node is given a "not yet supported" stub in M1 and implemented in M2.

---

## Task 1: Grammar additions + regenerate parser

**Goal:** Parse all v1 effect syntax (decls, `with`-arrows, effect rows, anonymous record tail, handlers) and round-trip it through pretty-printing.

**Files:**
- Modify: `grammar/Wok.cf`
- Regenerate: `src/GeneratedParser/Wok/*`
- Test: `test/examples/20-effects-syntax.wok` + `test/golden/20-effects-syntax.expected`

**Acceptance Criteria:**
- [ ] `cabal build` succeeds after regeneration + patches
- [ ] A file exercising every new form parses and round-trips (parse → print → re-parse) identically
- [ ] `cabal test` existing suite still green (no regressions in records/HM goldens)

**Steps:**

- [ ] **Step 1: Add the round-trip fixture (the failing test)**

Create `test/examples/20-effects-syntax.wok`:

```
module Main

effect IO = { read : String -> String, write : String -> () }

effect State a = {
  get : () -> a
  set : a -> ()
}

greet : String -> () with IO
runIO : (() -> a with IO + eff e) -> a with eff e
logIt : () -> () with IO + ..
both : () -> () with IO + State U64

handleDemo comp = handle (comp ()) of
  IO.read p -> readDisk p
  IO.write m -> printStdout m
  return v -> v
```

- [ ] **Step 2: Run the round-trip test, expect FAIL (parse error)**

Run: `cabal test --test-options='--pattern "20-effects-syntax"'`
Expected: FAIL — current grammar has no `effect`/`with`/`handle`.

- [ ] **Step 3: Add the grammar productions**

In `grammar/Wok.cf`:

Add the effect declaration (body reuses `RecordFieldType`), placed near `DData`:

```
DEffect.  Decl ::= "effect" ConId [VarId] "=" "{" [RecordFieldType] "}" ;
```

Refactor the arrow layer so `with` binds looser than `->` (replace the existing `TFun. Type ::= Type1 "->" Type ;` / `_. Type ::= Type1 ;` pair):

```
TWith.    Type ::= ArrowChain "with" EffectRow ;
_.        Type ::= ArrowChain ;
TFun.     ArrowChain ::= Type1 "->" ArrowChain ;
_.        ArrowChain ::= Type1 ;
```

Add effect rows (atoms joined by `+`, optional named/anonymous tail; bare tail allowed):

```
ERAtom.     EffectAtom ::= ConId [Type2] ;
EROne.      EffectRow ::= EffectAtom ;
ERPlus.     EffectRow ::= EffectAtom "+" EffectRow ;
ERVarOnly.  EffectRow ::= "eff" VarId ;
ERWildOnly. EffectRow ::= ".." ;
```

Add the anonymous record tail (symmetry with effects), next to `RCAnon`/`RCVar`:

```
RCWild.   RowContrib ::= ".." ;
```

Add handlers (reusing the layout-enabled `of`):

```
EHandle.  Exp2 ::= "handle" Exp "of" "{" [HandlerArm] "}" ;
HArm.     HandlerArm ::= ConId "." VarId [AtomPat] "->" Exp ;
HReturn.  HandlerArm ::= "return" VarId "->" Exp ;
separator HandlerArm ";" ;
```

Move `effect`, `with`, `handle`, `eff`, `return` OUT of any reserved-word list and into these real productions (they are new keywords by virtue of appearing as literals). Keep `fun`, `ctl`, `resume` reserved (add to the `ReservedKw` rule alongside the existing `row`):

```
rules ReservedKw ::= "contract" | "type" | "class" | "instance"
                   | "deriving" | "forall" | "do" | "record" | "row"
                   | "fun" | "ctl" | "resume" ;
```

Add `"of"` to the layout list if `handle … of` needs it — `of` is already there (`layout "let", "where", "of" ;`), so no change.

- [ ] **Step 4: Regenerate and reapply the documented patches**

Run:
```bash
bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf
```
(Match the existing output directory the repo uses — confirm with `git status` which `src-generated`/`src/GeneratedParser` path the build references in `wok.cabal`.)

Reapply the two manual patches the README documents (they are wiped by regen):
1. **`Layout.hs`** — split the combined `isLayoutOpen || isParenOpen` branch so the paren branch calls `maybeInsertSeparator` (see the `grammar/Wok.cf` header comment "POST-REGEN NOTE" #1).
2. **`Par.y`** — replace the right-recursive `ListRecordFieldPat` with the left-recursive `NEListRecordFieldPat` for `PRecordOpen` (see "POST-REGEN NOTE" #2).

- [ ] **Step 5: Build**

Run: `cabal build`
Expected: success; note the shift/reduce conflict count (README baseline is 28 — the new `with`/`handle` rules each start with a distinct keyword, so expect no large increase; record any change).

- [ ] **Step 6: Run round-trip test, expect PASS**

Run: `cabal test --test-options='--pattern "20-effects-syntax"'`
Expected: PASS (or, on first run, generate the golden: `cabal test --test-options=--accept` then inspect `test/golden/20-effects-syntax.expected` for fidelity and re-run).

- [ ] **Step 7: Commit**

```bash
git add grammar/Wok.cf src-generated test/examples/20-effects-syntax.wok test/golden/20-effects-syntax.expected
git commit -m "feat(grammar): effect decls, with-arrows, effect rows, handlers"
```

---

## Task 2: Verify block-form effect bodies (no code change expected)

**Goal:** Confirm block-form effect bodies (newline-separated ops, newline after `{`) get virtual commas via the existing pre-pass — no `RecordLayout` change should be needed.

**Why probably zero code:** `src/Wok/RecordLayout.hs` already triggers block mode for any `{` preceded by a `ConId`, `=`, or `+` (`isRecordBraceTrigger = isConId t || isEquals t || isPlusSym t`, `RecordLayout.hs:73-74`). The effect-decl `{` follows `=` (index 10), so it is *already* a record-context brace. There is no `classifyBrace` function — the logic is `isRecordBraceTrigger` + the `go` walker.

**Files:**
- Test only: `test/Spec.hs` (a layout unit test); the `State a` block in `test/examples/20-effects-syntax.wok` already exercises it.
- Modify (only if Step 1 fails): `src/Wok/RecordLayout.hs`.

**Acceptance Criteria:**
- [ ] `effect State a = { get : () -> a ⏎ set : a -> () }` (newline-separated, no commas) parses
- [ ] Inline and mixed comma/newline forms still parse
- [ ] `19-block-form-records` golden unchanged

**Steps:**

- [ ] **Step 1: Run the block-form effect fixture (expect it already PASSES)**

The `State a` block in `20-effects-syntax.wok` is newline-separated. Because `=` is already a record-brace trigger, this should parse with no change.

Run: `cabal test --test-options='--pattern "20-effects-syntax"'`
Expected: PASS. **If it passes, skip Step 2.**

- [ ] **Step 2: Only if Step 1 fails** — diagnose why the `=`-triggered block mode didn't apply (e.g. a comment/keyword token between `=` and `{`, or the `effect` keyword token interfering). Adjust `isRecordBraceTrigger`/`go` in `RecordLayout.hs` minimally to cover the effect-decl `{`, then re-run.

- [ ] **Step 3: Add a layout unit test**

In `test/Spec.hs`, add a parse test asserting the block-form effect decl parses to the same AST as its inline comma form (mirror the existing block-form-records parse tests).

- [ ] **Step 4: Guard against record regressions**

Run: `cabal test --test-options='--pattern "block-form-records"'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test/Spec.hs   # + src/Wok/RecordLayout.hs only if Step 2 was needed
git commit -m "test(layout): block-form effect bodies parse via existing pre-pass"
```

---

## Task 3: Env — effect namespace

**Goal:** The typing environment can store and look up declared effects.

**Files:**
- Modify: `src/Wok/TypeChecking/Env.hs`
- Test: `test/Spec.hs` (env unit test)

**Acceptance Criteria:**
- [ ] `EffectInfo` records an effect's type params and its operations' schemes
- [ ] `lookupEffect`/`extendEffect` work; `overlayEnvs` reports effect-name collisions via a new `NsEffect` tag
- [ ] `cabal build` green

**Steps:**

- [ ] **Step 1: Add the type and field (write the code)**

In `src/Wok/TypeChecking/Env.hs`:

```haskell
-- | A declared effect: its type parameters and its operations.
data EffectInfo = EffectInfo
  { eiParams :: [(Int, Kind)]        -- ^ universally-quantified params (e.g. State a)
  , eiOps    :: Map Text Scheme      -- ^ operation name -> operation type scheme
  }
  deriving (Eq, Show)
```

Add the field to `Env`:

```haskell
data Env = Env
  { envVars       :: Map Text Scheme
  , envCons       :: Map Text ConInfo
  , envTyCons     :: Map Text TyConInfo
  , envRecordCons :: Map Text RecordConInfo
  , envEffects    :: Map Text EffectInfo
  }
  deriving (Eq, Show)
```

Update `emptyEnv`:

```haskell
emptyEnv = Env Map.empty Map.empty Map.empty Map.empty Map.empty
```

Add accessors:

```haskell
lookupEffect :: Text -> Env -> Maybe EffectInfo
lookupEffect k = Map.lookup k . envEffects

extendEffect :: Text -> EffectInfo -> Env -> Env
extendEffect k v e = e { envEffects = Map.insert k v (envEffects e) }
```

Add `NsEffect` to `EnvNs` and extend `overlayEnvs` (add `efClash`/the `NsEffect` clause and thread the fifth map through the deconstruction and `Map.union`):

```haskell
data EnvNs = NsVar | NsCon | NsTyCon | NsRecordCon | NsEffect
  deriving (Eq, Ord, Show)
```

Export `EffectInfo (..)`, `lookupEffect`, `extendEffect` from the module header.

- [ ] **Step 2: Add the env unit test**

In `test/Spec.hs` (env test group):

```haskell
testCase "extendEffect then lookupEffect round-trips" $ do
  let ei  = TC.EffectInfo [] (Map.fromList [(T.pack "read", readScheme)])
      env = TC.extendEffect (T.pack "IO") ei TC.emptyEnv
  TC.lookupEffect (T.pack "IO") env @?= Just ei
```

(Define `readScheme` as any simple `Scheme` already used elsewhere in the test module.)

- [ ] **Step 3: Build + test**

Run: `cabal test --test-options='--pattern "extendEffect"'`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/TypeChecking/Env.hs test/Spec.hs
git commit -m "feat(env): envEffects namespace + EffectInfo"
```

---

## Task 4: Infer — process effect declarations

**Goal:** A `DEffect` declaration populates `envEffects` with an `EffectInfo` (params + per-op schemes).

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs`
- Test: `test/Spec.hs`

**Acceptance Criteria:**
- [ ] `effect IO = { read : String -> String, write : String -> () }` registers `IO` with ops `read`, `write` carrying their translated schemes
- [ ] Effect with params (`effect State a = …`) records the param in `eiParams` and the param is in scope inside op types
- [ ] Duplicate operation names within one effect → error

**Steps:**

- [ ] **Step 1: Locate the decl-processing pass to mirror**

Read the existing record-form `data` decl handler in `src/Wok/TypeChecking/Infer.hs` (the function that builds `RecordConInfo` and calls `translateSig`/`translateType` — search for `RecordConInfo` and `ConDefRec`). The effect handler mirrors it: same parameter-binding (`[VarId]` → fresh `CTGen`/`KStar` slots), same per-field type translation (each `RecordFieldType` → a `Scheme`).

- [ ] **Step 2: Write `processEffectDecls`**

Add a function that folds `DEffect` decls into the env. Signature:

```haskell
processEffectDecl :: Env -> Abs.Decl -> Either TypeError Env
-- for Abs.DEffect conId params fields:
--   1. bind each VarId param to a fresh CTGen index with KStar
--   2. translate each `RecordFieldType (name : type)` to a Scheme over those params
--      (reuse the same type-translation used for record field types / sigs)
--   3. reject duplicate op names (DuplicateOperation error)
--   4. extendEffect conName (EffectInfo params opMap) env
```

Wire it into the same top-level fold that processes data/sig decls (search for where `DData` is handled in the module's decl loop, e.g. in `Wok.TypeChecking` or `Wok.Pipeline`), so effects are registered before sigs/bodies are checked.

- [ ] **Step 3: Test (parse → process → assert env)**

In `test/Spec.hs`, add a test that runs the decl processor on:

```haskell
"effect IO = { read : String -> String, write : String -> () }"
```
and asserts `lookupEffect "IO"` returns an `EffectInfo` whose `eiOps` has keys `{"read","write"}` and whose `read` scheme prints (via `prettyScheme`) as `String -> String`.

Run: `cabal test --test-options='--pattern "effect IO"'`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs test/Spec.hs
git commit -m "feat(infer): register effect declarations in envEffects"
```

---

## Task 5: Infer — translate the `with` clause to the arrow's effect row

**Goal:** A `with` clause on an arrow becomes the arrow's `Row` slot (closed labels, `+ eff e` named tail, `+ ..` anonymous tail), with `eff`/`row` kept domain-separate.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs`
- Test: `test/Spec.hs`

**Acceptance Criteria:**
- [ ] `A -> B with IO` translates to `CTArr A (CRExtend "IO" <unit> CREmpty) B`
- [ ] `with IO + Logger` nests both labels closed; `with IO + eff e` ends in a `KEffect` `CRGen`; `with IO + ..` ends in a fresh single-use `CRGen`
- [ ] Repeated `eff e` in one sig share one `CRGen`; two `..` get distinct slots
- [ ] An `eff` variable used in a record extension, or a `row` variable used in a `with` clause, is rejected (kind/domain error)

**Steps:**

- [ ] **Step 1: Locate the sig/type translator to extend**

Read `translateSig`/`translateType` in `Infer.hs` — specifically the `Abs.TFun a b -> CTArr <$> … <*> pure CREmpty <*> …` case (the spec quotes it at `Infer.hs:275`) and the `TExtend` (record `+`) case that already handles `row r` / `RCAnon`. The new `Abs.TWith chain row` case mirrors `TFun` but fills the arrow's `CRow` from the `with` clause instead of `CREmpty`; the `RCWild` record case mirrors `RCVar` but generates a fresh anonymous slot.

- [ ] **Step 2: Write `translateEffectRow`**

```haskell
-- Build a CRow from an Abs.EffectRow. Labels close the row; `eff e`/`..`
-- supply an open CRGen tail. `eff e` names are interned per-sig (shared
-- slot); `..` mints a fresh slot each occurrence.
translateEffectRow :: <translation context> -> Abs.EffectRow -> ... CRow
--   EROne atom            -> CRExtend (atomLabel atom) (atomArg atom) CREmpty
--   ERPlus atom rest      -> CRExtend (atomLabel atom) (atomArg atom) (translateEffectRow rest)
--   ERVarOnly e           -> CRGen (effVarSlot e)      -- shared, KEffect
--   ERWildOnly            -> CRGen (freshAnonSlot)     -- distinct, KEffect
```

`atomArg` is the effect's type argument when present (`State U64` → `U64`), else the unit type. Reuse the existing per-sig variable-interning the record translator already uses for `row r` so `eff e` shares a slot across positions, and tag these slots `KEffect`.

For `TWith chain row`: translate `chain` to the arrow spine, then set the *outermost* arrow's `CRow` to `translateEffectRow row`. (Per the spec, `A -> B -> C with E` = the whole chain carries `E` on its result arrow.)

- [ ] **Step 3: Enforce the domain split**

When translating a record `TExtend` whose `RowContrib` is a `row r`, ensure the slot is tagged as a record-row var; when translating a `with` clause `eff e`, tag it effect-row. If a name declared `eff` appears in a record tail (or `row` in a `with`), raise `RowDomainMismatch`. (Track the two namespaces during sig translation.)

- [ ] **Step 4: Tests (parse sig → translate → assert CType)**

In `test/Spec.hs` add cases asserting the translated `CType`/`CRow` shape, mirroring the existing "Point + row r translates to CTRecord with CRGen tail" test:

```haskell
"greet : String -> () with IO"        -- CTArr String (CRExtend "IO" Unit CREmpty) ()
"f : (() -> a with IO + eff e) -> a with eff e"  -- both eff e share one CRGen
"g : () -> () with IO + .."            -- ends in a fresh CRGen
```
And a failing case: `"bad : Point + eff e -> U64"` → `RowDomainMismatch`.

Run: `cabal test --test-options='--pattern "with IO"'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs test/Spec.hs
git commit -m "feat(infer): translate with-clause to arrow effect row; eff/row domain split"
```

---

## Task 6: Infer — operation-call typing + handler stub

**Goal:** Calling `E.op` types as `E`'s operation and requires `E` in the ambient effect row; `handle` parses but is rejected with a clear "not yet supported" error until M2.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs`
- Test: `test/Spec.hs`

**Acceptance Criteria:**
- [ ] `IO.write m` types as the `write` op and adds `IO` to the enclosing function's row
- [ ] A function whose body calls `IO.write` but whose sig has no `IO` (and a closed row) errors with `UndischargedEffect`
- [ ] `E.op` where `E` is not an effect, or `op` not an operation of `E`, errors (`UnknownOperation`)
- [ ] `handle … of …` produces `HandlersNotYetSupported` (replaced in M2), so the build is total

**Steps:**

- [ ] **Step 1: Locate the `EProj` inference case**

Read the `EProj` (field access, `p.x`) inference case in `Infer.hs` (search `EProj`; the spec references record field access via `rewriteRowStrict` around `Infer.hs:782`). Operation calls reuse the same surface node: `EProj (ECon E) (VarId op)`. Add a branch *before* the record-field path: if the head is `ECon E` and `E ∈ envEffects` and `op ∈ eiOps`, treat it as an operation; otherwise fall through to the existing module/field logic.

- [ ] **Step 2: Implement operation-call typing**

```haskell
-- when EProj head is an effect constructor E with operation op:
--   1. instantiate (eiOps ! op) to a function type  A1..An -> B
--   2. the expression's type is that function type (it is applied like any fn)
--   3. require E's label in the AMBIENT effect row:
--        unifyRow ambientRow (RowExtend "E" <effectArg> freshTailVar)
--      i.e. rewriteRow "E" ambientRow (introduce if the tail is open)
```

The "ambient effect row" is the effect row of the function currently being checked. Thread it the way the body's effect is already accumulated (the function-body inference already builds arrows with `RowEmpty`; introduce a current-effect `Row` that operation calls unify into, and that becomes the function's row at generalization). If a sig fixed a closed row lacking `E`, the `rewriteRow` against a closed row fails → surface as `UndischargedEffect`.

- [ ] **Step 3: Add the `EHandle` stub**

```haskell
inferExpr ... (Abs.EHandle _ _) = throwError (HandlersNotYetSupported <span>)
```

(Keeps the inferencer total now that the grammar accepts `handle`.)

- [ ] **Step 4: Tests**

In `test/Spec.hs`, end-to-end (parse module → typecheck → assert inferred scheme or error):

```haskell
-- propagation: body calls IO.write, sig open -> IO appears in inferred row
[ "effect IO = { write : String -> () }"
, "shout : String -> () with IO + .."
, "shout s = IO.write s" ]            -- typechecks

-- undischarged: closed pure sig but calls IO -> error
[ "effect IO = { write : String -> () }"
, "bad : String -> ()"
, "bad s = IO.write s" ]              -- UndischargedEffect

-- unknown op
[ "effect IO = { write : String -> () }"
, "bad s = IO.read s" ]              -- UnknownOperation
```

Run: `cabal test --test-options='--pattern "operation"'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs test/Spec.hs
git commit -m "feat(infer): operation-call typing + handler stub"
```

---

## Task 7: Error — effect error variants

**Goal:** Dedicated, well-rendered error variants for the effect paths.

**Files:**
- Modify: `src/Wok/TypeChecking/Error.hs`
- Test: covered by Tasks 5/6/9 fail cases

**Acceptance Criteria:**
- [ ] New `TypeError` constructors: `MissingEffectDecl`, `UndischargedEffect`, `UnknownOperation`, `RowDomainMismatch`, `HandlersNotYetSupported`, `HandlerCoverage`, `DuplicateOperation`
- [ ] Each has a `Show`/pretty rendering consistent with existing variants (carry a `SourceSpan` + names)

**Steps:**

- [ ] **Step 1: Add the constructors (mirror existing variants)**

Read the existing `TypeError` data type in `Error.hs` (it already has `BareRowVar SourceSpan Text`, `RowMismatch`, `NominalMismatch`, etc.). Add, following the same field conventions:

```haskell
  | MissingEffectDecl   SourceSpan Text          -- `with FooBar` where FooBar isn't an effect
  | UndischargedEffect  SourceSpan Text          -- op used but effect absent from a closed row
  | UnknownOperation    SourceSpan Text Text     -- effect name, op name
  | RowDomainMismatch   SourceSpan Text           -- eff var in record tail or vice versa
  | DuplicateOperation  SourceSpan Text Text      -- effect name, op name
  | HandlerCoverage     SourceSpan Text [Text]    -- effect, missing op names
  | HandlersNotYetSupported SourceSpan
```

Add matching cases to the error pretty-printer / `Show` instance used by the test harness.

- [ ] **Step 2: Build**

Run: `cabal build`
Expected: success; the inferencer references compile.

- [ ] **Step 3: Commit**

```bash
git add src/Wok/TypeChecking/Error.hs
git commit -m "feat(error): effect-typing error variants"
```

---

## Task 8: M1 golden fixtures + suite

**Goal:** End-to-end success/fail golden coverage for M1 (decls, arrows, calls, purity).

**Files:**
- Create: `test/typecheck-examples/{20-effects-decl,21-effects-arrow,22-effects-pure,23-effects-calls}.wok` + matching `test/typecheck-golden/*.expected`
- Create: fail fixtures under `test/typecheck-fail-examples/` + `test/typecheck-fail-golden/`

**Acceptance Criteria:**
- [ ] Each success fixture typechecks and its inferred-signature golden matches
- [ ] Each fail fixture errors with the expected message golden

**Steps:**

- [ ] **Step 1: Write success fixtures**

`23-effects-calls.wok`:
```
module Main
import Std.Base

effect IO = { read : String -> String, write : String -> () }

shout : String -> () with IO + ..
shout s = IO.write s
```

(Plus `20`/`21`/`22` per the spec's test table — declarations parse, arrow forms parse+typecheck, pure function has empty row.)

- [ ] **Step 2: Generate + inspect goldens**

Run: `cabal test --test-options=--accept`
Then **inspect** each new `.expected` (e.g. `23-effects-calls.expected` should show `shout : String -> () with IO + eff <name>` per the Task-10 printer; if Task 10 isn't merged yet, accept the current rendering and tighten in Task 10).

- [ ] **Step 3: Write fail fixtures**

Under `test/typecheck-fail-examples/`: undeclared `with FooBar`; pure-sig-calls-IO (`UndischargedEffect`); `eff` var in a record tail (`RowDomainMismatch`). Accept their `.expected` error goldens and verify the messages read correctly.

- [ ] **Step 4: Full suite green**

Run: `cabal test`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add test/typecheck-examples test/typecheck-golden test/typecheck-fail-examples test/typecheck-fail-golden
git commit -m "test(effects): M1 golden + fail fixtures"
```

---

## Task 9: Infer — handler typing (M2)

**Goal:** `handle e of { arms; return v -> r }` discharges the handled effect(s) from the row, checks coverage, types transparent arms, and folds arm-body effects into the result row.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs` (replace the `HandlersNotYetSupported` stub)
- Test: `test/Spec.hs`

**Acceptance Criteria:**
- [ ] `runIO : (() -> a with IO + eff e) -> a with eff e` typechecks; result row excludes `IO`
- [ ] Effect-translating handler (`Logger.log m -> IO.write m`) discharges `Logger`, adds `IO` to the result row
- [ ] A handler missing an operation of the handled effect → `HandlerCoverage`
- [ ] `return v -> r` sets the handle's result type (default identity)

**Steps:**

- [ ] **Step 1: Implement `inferHandler`** (replace the stub from Task 6)

```haskell
-- handle EXPR of { E.op args -> body ... ; return v -> r }
--  1. infer EXPR : tau with ambient effect rho
--  2. collect handled effects E_i from arm heads; for each, all its ops must
--     have an arm  (else HandlerCoverage E missingOps)
--  3. discharge each E_i's label from rho via rewriteRow -> rho'
--  4. for each arm `E.op args -> body`:
--       bind args to the op's argument types;
--       check `body` against the op's RESULT type (transparent / auto-resume);
--       unify body's effect into rho'   (arms may invoke other effects)
--  5. return arm `return v -> r`: bind v : tau; result type = type of r;
--       default (no arm) => result type tau
--  6. handle expression : <result type> with rho'
```

Reuse `rewriteRow`/`unifyRow` for discharge and effect merging; reuse `lookupEffect`/`eiOps` for coverage and op types.

- [ ] **Step 2: Tests (end-to-end)**

```haskell
-- discharge: IO removed from result row
[ "effect IO = { read : String -> String, write : String -> () }"
, "runIO : (() -> a with IO + eff e) -> a with eff e"
, "runIO comp = handle (comp ()) of"
, "  IO.read p -> p"
, "  IO.write m -> ()"
, "  return v -> v" ]                 -- typechecks; runIO result row = eff e (no IO)

-- translation: Logger -> IO
[ "effect Logger = { log : String -> () }"
, "effect IO = { write : String -> () }"
, "logToIO : (() -> a with Logger + eff e) -> a with IO + eff e"
, "logToIO c = handle (c ()) of"
, "  Logger.log m -> IO.write m"
, "  return v -> v" ]                 -- typechecks; Logger discharged, IO added

-- coverage failure: missing `write` arm
[ ... only IO.read arm ... ]          -- HandlerCoverage
```

Run: `cabal test --test-options='--pattern "handle"'`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs test/Spec.hs
git commit -m "feat(infer): handler typing (discharge, coverage, transparent arms)"
```

---

## Task 10: Infer — print effect rows in `with` form

**Goal:** `prettyCType` renders an arrow's non-empty effect row as a `with` clause so golden output reads like source and round-trips.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs` (`prettyCType`/`prettyCRow`)
- Test: tighten the goldens from Tasks 8/9

**Acceptance Criteria:**
- [ ] `CTArr a CREmpty b` → `a -> b` (unchanged)
- [ ] `CTArr a r b` (non-empty) → `a -> b with <labels> [+ eff eN]`
- [ ] Record rows still print `Point { … }` (unchanged); effect-row labels print without the field syntax

**Steps:**

- [ ] **Step 1: Replace the dormant `-< >-` branch (write the code)**

In `prettyCType` (currently `Infer.hs:1671-1680`):

```haskell
prettyCType (CTArr a CREmpty b) =
  Tx.concat [prettyCTypeArg a, Tx.pack " -> ", prettyCType b]
prettyCType (CTArr a r b) =
  Tx.concat
    [ prettyCTypeArg a, Tx.pack " -> ", prettyCType b
    , Tx.pack " with ", prettyEffectRow r ]
```

Add `prettyEffectRow` (labels joined by ` + `, open tail as ` + eff <name>`):

```haskell
prettyEffectRow :: CRow -> Text
prettyEffectRow = go True
  where
    go _ CREmpty           = Tx.empty
    go first (CRExtend l _ rest) =
      (if first then l else Tx.concat [Tx.pack " + ", l]) <> go False rest
    go first (CRGen i) =
      Tx.concat [if first then Tx.empty else Tx.pack " + ", Tx.pack "eff ", varName i]
```

(Effect labels omit type-arg printing in v1 for brevity; revisit if a fixture needs `State U64` shown. Record-row printing via `prettyCRow` in `CTRecord` is untouched.)

- [ ] **Step 2: Re-accept and inspect goldens**

Run: `cabal test --test-options=--accept`
Inspect `23-effects-calls.expected` → `shout : String -> () with IO + eff a` (or similar); `runIO` golden shows `… -> a with eff a` (IO discharged).

- [ ] **Step 3: Full suite green**

Run: `cabal test`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs test/typecheck-golden
git commit -m "feat(infer): print arrow effect rows in with-form"
```

---

## Task 11: M2 golden fixtures (handlers + DI)

**Goal:** End-to-end golden coverage for handlers and the dependency-injection pattern.

**Files:**
- Create: `test/typecheck-examples/{24-effects-handle,25-effects-di}.wok` + goldens
- Create: a coverage-failure fail fixture

**Acceptance Criteria:**
- [ ] `24-effects-handle.wok` (a `runIO`-style handler) typechecks; golden shows the discharged row
- [ ] `25-effects-di.wok` (Logger→IO translation, `main` reaching empty row) typechecks
- [ ] A non-exhaustive handler fail fixture errors with `HandlerCoverage`

**Steps:**

- [ ] **Step 1: Write fixtures**

`25-effects-di.wok`:
```
module Main
import Std.Base

effect Logger = { log : String -> () }
effect IO = { write : String -> () }

greet : () -> () with Logger + eff e
greet () = Logger.log "hello"

logToIO : (() -> a with Logger + eff e) -> a with IO + eff e
logToIO c = handle (c ()) of
  Logger.log m -> IO.write m
  return v -> v
```

- [ ] **Step 2: Accept + inspect + fail fixture**

Run: `cabal test --test-options=--accept`; inspect goldens. Add the coverage-failure fixture under `test/typecheck-fail-examples/` and verify its `HandlerCoverage` message.

- [ ] **Step 3: Full suite green**

Run: `cabal test`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add test/typecheck-examples test/typecheck-golden test/typecheck-fail-examples test/typecheck-fail-golden
git commit -m "test(effects): M2 handler + DI golden fixtures"
```

---

## Self-review notes

- **Spec coverage:** effect decls (T1,T2,T4), `with`-arrows + `eff e`/`..` (T1,T5), eff/row domain split (T5), operation calls (T6), handlers + discharge + coverage + translation (T9), `return` arm (T9), printing (T10), all test-plan fixtures (T8,T11). Deferred items (ctl/resume/runtime/auto-open) are intentionally absent.
- **Reused as-is:** `unifyRow`/`rewriteRow`/`bindRowVar` (Unify), the arrow row slot (Types) — no changes needed, consistent across tasks.
- **Type consistency:** `EffectInfo{eiParams,eiOps}`, `envEffects`, `lookupEffect`/`extendEffect`, `translateEffectRow`, `prettyEffectRow`, and the seven new `TypeError` variants are named identically wherever referenced.
- **Known dependency on regen output:** Task 2 needs the `=` token index from the regenerated `Lex` table (Task 1); Task 1 must precede it.
