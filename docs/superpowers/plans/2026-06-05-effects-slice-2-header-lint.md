# Effects Slice 2: effect header + forgotten-resume lint + `Never` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the optional effect header (`with E1 E2 { … }`), the forgotten-resume lint with a `_` (wildcard) suppressor and a `Never` non-returning marker, and a dedicated `MalformedHandlerArm` error — on top of the slice-1 `with`-prefix handler.

**Architecture:** Four mostly-independent pieces. `Never` is a new built-in tycon `TcNever` whose perform-site result freshens to a type variable (bottom elimination). The effect header is two new grammar productions (`EWithH`, and `HUArm` replacing `HVArm`) plus header-aware arm classification in `inferHandler`. The lint is one `Warning` constructor emitted from the binder-control branch of `inferHandler`, keyed on "named binder unreferenced ∧ result ≠ `Never`," suppressed by a `_` (wildcard) binder. `MalformedHandlerArm` replaces a misleading `UnknownOperation` throw. The typed AST, ANF, and runtime are reused unchanged except where noted.

**Tech Stack:** BNFC grammar (`grammar/Wok.cf`) → generated Happy/Alex parser (`src-generated/`), Haskell typechecker (`src/Wok/TypeChecking/Infer.hs`, `Error.hs`, `Class.hs`, `Types.hs`, `Builtins.hs`), ANF printer (`src/Wok/IR/Anf.hs`), tasty-golden suite (`test/Spec.hs`).

Implements **slice 2** of `docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md`. Design: `docs/superpowers/specs/2026-06-05-effects-slice-2-design.md`. Slice-1 plan (template): `docs/superpowers/plans/2026-06-05-effects-slice-1-with-resume.md`.

Branch: `feat/effects-slice-2-header-lint` (already created off `main`). Full-branch review before any merge (standing rule).

---

## Build / test commands (reference)

- Regenerate parser after editing the grammar: `bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf`, then reapply the two manual patches documented at `grammar/Wok.cf:13-56` (the `Layout.hs` separator patch and the `Par.y` `NEListRecordFieldPat` patch).
- Build: `cabal build`
- Full test suite: `cabal test` (or `cabal run wok-tests`)
- Accept/regenerate golden files: `cabal run wok-tests -- --accept` (read diffs before accepting)
- Run one program: `cabal run wok -- <file.wok> --run` (prints the value of `main`); `--dump-anf` to dump ANF.

---

## File structure

- `src/Wok/TypeChecking/Types.hs` — add `TcNever` to `data TyCon`. (Task 1)
- `src/Wok/TypeChecking/Class.hs` — `tyConKey`/name-resolver cases for `Never`. (Task 1)
- `src/Wok/TypeChecking/Builtins.hs` — register `Never` tycon. (Task 1)
- `src/Wok/IR/Anf.hs` — `prettyCTypeLocal` case for `Never`. (Task 1)
- `src/Wok/TypeChecking/Infer.hs` — `resolveTyCon`/`prettyCType` for `Never`; perform-site freshening (Task 1); `MalformedHandlerArm` throw (Task 2); route `EWithH`, header-aware arm classification, coverage contract, empty-handler error (Task 4); forgotten-resume lint (Task 5).
- `src/Wok/TypeChecking/Error.hs` — `MalformedHandlerArm` (Task 2); header errors + `EmptyHandler` (Task 4); `ForgottenResume` warning (Task 5); render cases.
- `grammar/Wok.cf` + `src-generated/GeneratedParser/Wok/*` — header grammar. (Task 3)
- `test/**/*.wok`, `test/*-golden/` — fixtures + migration + corpus reconcile. (Tasks 1–6)
- `docs/.../2026-06-05-effect-handler-surface-syntax.md`, `effect-surface-syntax-final` memory — reconcile `_`/`Never`. (Task 6)

---

### Task 1: `Never` built-in type + bottom elimination at perform sites

**Goal:** `effect Exn = { throw : String -> Never }` type-checks, an abort handler runs, and `Exn.throw "boom"` is usable where any type is expected (`if b then Exn.throw "boom" else 7`).

**Files:**
- Modify: `src/Wok/TypeChecking/Types.hs:43-53`, `src/Wok/TypeChecking/Class.hs:175,288`, `src/Wok/TypeChecking/Builtins.hs:30-37`, `src/Wok/IR/Anf.hs:349`, `src/Wok/TypeChecking/Infer.hs:731-740` (`resolveTyCon`), `src/Wok/TypeChecking/Infer.hs:2890` (`prettyCType`), `src/Wok/TypeChecking/Infer.hs:1516-1534` (op-reference freshening)
- Create: `test/run-examples/19-exn-never.wok`, `test/run-golden/19-exn-never.expected`

**Acceptance Criteria:**
- [ ] `Never` resolves as a type in op signatures; `effect Exn = { throw : String -> Never }` registers.
- [ ] `Exn.throw "boom"` has a fresh (polymorphic) result type at each use, so `if b then Exn.throw "boom" else 7 : U64` type-checks.
- [ ] A binder arm `Exn.throw msg k -> 0` aborts; `19-exn-never.wok` runs to `0`.
- [ ] `cabal build` clean (no non-exhaustive-pattern warnings from the new `TcNever`).

**Verify:** `cabal run wok -- test/run-examples/19-exn-never.wok --run` → `0`; `cabal test` green.

**Steps:**

- [ ] **Step 1: Write the failing run test.**

Create `test/run-examples/19-exn-never.wok`:

```
module Main
import Std.Base

effect Exn = { throw : String -> Never }

risky : Bool -> U64 with Exn
risky b = if b then Exn.throw "boom" else 7

main : U64
main =
  with { Exn.throw msg k -> 0
         ; v -> v }
  risky True
```

Create `test/run-golden/19-exn-never.expected` containing exactly:

```
0
```

- [ ] **Step 2: Run to confirm it fails.**

Run: `cabal run wok -- test/run-examples/19-exn-never.wok --run`
Expected: FAIL — `Never` is an unknown tycon (resolves to `TcUser "Never"` with no registration / kind error), or a unify failure `Never` vs `U64`.

- [ ] **Step 3: Add `TcNever` to the `TyCon` enum.**

In `src/Wok/TypeChecking/Types.hs`, in `data TyCon` (lines 43-53), add `| TcNever` after `| TcString`:

```haskell
data TyCon
  = TcU64
  | TcU32
  | TcChar
  | TcString
  | TcNever
  | TcBool
  | TcUnit
  | TcTuple Int
  | TcList
  | TcUser Text
  deriving (Eq, Ord, Show)
```

- [ ] **Step 4: Add the name↔tycon mappings and pretty-printers (mirror every `TcString` site).**

`src/Wok/TypeChecking/Class.hs:175` — add after the `TcString` line:

```haskell
tyConKey TcNever      = Tx.pack "Never"
```

`src/Wok/TypeChecking/Class.hs:288` — in the name→TyCon guard, add after the `String` line:

```haskell
  | name == Tx.pack "Never"  = TcNever
```

`src/Wok/TypeChecking/Infer.hs:736` — in `resolveTyCon`, add after the `String` line:

```haskell
  | name == Tx.pack "Never"  = TcNever
```

`src/Wok/TypeChecking/Infer.hs:2890` — add after the `prettyCType (CTCon TcString [])` line:

```haskell
prettyCType (CTCon TcNever []) = Tx.pack "Never"
```

`src/Wok/IR/Anf.hs:349` — add after the `prettyCTypeLocal (CTCon TcString [])` line:

```haskell
prettyCTypeLocal (CTCon TcNever [])  = Tx.pack "Never"
```

- [ ] **Step 5: Register `Never` in the tycon environment.**

`src/Wok/TypeChecking/Builtins.hs:30-37` — add `Never` to `tyConEntries`:

```haskell
      , ("String", TyConInfo KStar 0 [])
      , ("Never",  TyConInfo KStar 0 [])
```

- [ ] **Step 6: Build; resolve any non-exhaustive-pattern fallout.**

Run: `cabal build`
Expected: compiles. If GHC reports incomplete patterns for any other `TyCon` match (there should be none beyond the four sites above — `tyConKey`, the two `prettyCType`/`prettyCTypeLocal`, the two resolvers), add a `Never` case mirroring `String` at that site.

- [ ] **Step 7: Add perform-site bottom elimination.**

In `src/Wok/TypeChecking/Infer.hs`, the effect-operation reference case (`inferExprW mono (Abs.EProj (Abs.ECon …) …)`, lines 1516-1534) computes `opTy = substCTypeWith paramSubst (schemeBody opScheme)`. After that binding, freshen a `Never` result so each perform is polymorphic. Add a helper near `resolveTyCon`:

```haskell
-- | Bottom elimination: if an operation's result type is `Never`, replace it
-- with a fresh type variable so each perform of a non-returning operation is
-- usable at any type (ex-falso). Non-`Never` results are returned unchanged.
freshenNeverResult :: Type s -> TC s (Type s)
freshenNeverResult ty = do
  ty' <- force ty
  case ty' of
    TArr a r b -> TArr a r <$> freshenNeverResult b
    TCon TcNever [] -> freshTVar KStar
    _ -> pure ty'
```

Then in the op-reference case, wrap `opTy`:

```haskell
          paramSubst <- instantiateParamSubst (eiParams eInfo)
          opTy0 <- pure (substCTypeWith paramSubst (schemeBody opScheme))
          opTy  <- freshenNeverResult opTy0
```

(Use `opTy` for both the returned type and the existing `labelTy`/`emitEffect` logic, unchanged.)

- [ ] **Step 8: Run the test.**

Run: `cabal run wok -- test/run-examples/19-exn-never.wok --run`
Expected: `0`. (`Exn.throw "boom"` now has a fresh result unifying with `U64`; the handler aborts to `0`.)

Run: `cabal run wok-tests -- --accept` then `cabal test` → green (review any new golden).

- [ ] **Step 9: Commit.**

```bash
git add src/Wok/TypeChecking/Types.hs src/Wok/TypeChecking/Class.hs src/Wok/TypeChecking/Builtins.hs src/Wok/IR/Anf.hs src/Wok/TypeChecking/Infer.hs test/run-examples/19-exn-never.wok test/run-golden/19-exn-never.expected test/anf-golden test/typed-anf-golden
git commit -m "feat(types): Never bottom type + perform-site bottom elimination"
```

---

### Task 2: `MalformedHandlerArm` error (roadmap follow-up #2)

**Goal:** A handler arm for a known operation with an invalid pattern shape (more than `arity + 1` patterns, or a non-variable continuation binder) reports a dedicated error, not the misleading `UnknownOperation`.

**Files:**
- Modify: `src/Wok/TypeChecking/Error.hs` (add constructor + render case), `src/Wok/TypeChecking/Infer.hs:1743-1746` (throw site)
- Create: `test/typecheck-fail-examples/20-malformed-handler-arm.wok`, `test/typecheck-fail-golden/20-malformed-handler-arm.expected`

**Acceptance Criteria:**
- [ ] An arm like `Exn.throw msg k extra -> …` (too many patterns) reports `MalformedHandlerArm` naming the effect+op, not `UnknownOperation`.
- [ ] The message states the expected shape (op args, plus an optional variable continuation binder).
- [ ] `cabal test` green.

**Verify:** `cabal run wok -- test/typecheck-fail-examples/20-malformed-handler-arm.wok --run` → error mentioning `MalformedHandlerArm` / "malformed handler arm".

**Steps:**

- [ ] **Step 1: Write the failing typecheck-fail test.**

Create `test/typecheck-fail-examples/20-malformed-handler-arm.wok`:

```
module Main
import Std.Base

effect Exn = { throw : String -> Never }

risky : Bool -> U64 with Exn
risky b = if b then Exn.throw "boom" else 7

main : U64
main =
  with { Exn.throw msg k extra -> 0
         ; v -> v }
  risky True
```

- [ ] **Step 2: Add the error constructor.**

In `src/Wok/TypeChecking/Error.hs`, in `data TypeError`, add after the `UnknownOperation` constructor (line 82):

```haskell
  | MalformedHandlerArm SourceSpan Text Text
    -- ^ A handler arm for a KNOWN operation has an invalid pattern shape:
    --   more than (op arity + 1) patterns, or a non-variable continuation
    --   binder. Args: position, effect name, operation name.
```

- [ ] **Step 3: Add the render case.**

Find where `UnknownOperation` is rendered (grep `UnknownOperation` in `src/Wok/TypeChecking/Error.hs`; it appears in the `renderTypeError`/`prettyTypeError`/`Show`-style function). Add a sibling case:

```haskell
renderTypeError (MalformedHandlerArm sp en op) =
  withPos sp $ "malformed handler arm for " <> en <> "." <> op
    <> ": expected the operation's arguments and an optional variable "
    <> "continuation binder"
```

(Mirror the exact helper names / position-formatting used by the `UnknownOperation` case at that site.)

- [ ] **Step 4: Replace the throw site.**

In `src/Wok/TypeChecking/Infer.hs`, the operation-arm binder `case` fallthrough (currently lines 1743-1746):

```haskell
            _ ->
              -- More than `arity + 1` patterns, or a non-variable continuation
              -- binder: not a valid operation arm shape.
              throwError (UnknownOperation (Just pos) en op)
```

Change the thrown error to:

```haskell
            _ ->
              throwError (MalformedHandlerArm (Just pos) en op)
```

- [ ] **Step 5: Build, run, accept golden.**

Run: `cabal build`
Run: `cabal run wok -- test/typecheck-fail-examples/20-malformed-handler-arm.wok --run`
Expected: the malformed-handler-arm error.
Run: `cabal run wok-tests -- --accept`; inspect `test/typecheck-fail-golden/20-malformed-handler-arm.expected` shows the new error; `cabal test` → green.

- [ ] **Step 6: Commit.**

```bash
git add src/Wok/TypeChecking/Error.hs src/Wok/TypeChecking/Infer.hs test/typecheck-fail-examples/20-malformed-handler-arm.wok test/typecheck-fail-golden/20-malformed-handler-arm.expected
git commit -m "feat(tc): dedicated MalformedHandlerArm error (was UnknownOperation)"
```

---

### Task 3: Effect-header grammar (`with E1 E2 { … }`, unqualified arms)

**Goal:** `with State { get -> 0 ; set s -> () } e` parses; the headerless `with { … } e` still parses; the value arm and unqualified op arm share one production.

**Files:**
- Modify: `grammar/Wok.cf:370-373`
- Regenerate: `src-generated/GeneratedParser/Wok/*` (reapply the two documented patches)
- Create: `test/examples/27-with-header.wok`

**Acceptance Criteria:**
- [ ] `EWithH. Exp2 ::= "with" ConId [ConId] "{" [HandlerArm] "}" Exp ;` parses a headed handler (≥1 effect, no empty-header ambiguity with `EWith`).
- [ ] `HUArm. HandlerArm ::= VarId [AtomPat] "->" Exp ;` replaces `HVArm`, covering both value arms and unqualified op arms.
- [ ] `HArm` (qualified) and `EWith` (headerless) unchanged.
- [ ] Parser regenerates with no new conflicts beyond the documented ones; both manual patches reapplied; `cabal build` succeeds.
- [ ] `test/examples/27-with-header.wok` parses.

**Verify:** `cabal build && cabal run wok -- test/examples/27-with-header.wok --dump-anf` → parses (a downstream "unhandled `EWithH`" type error is expected until Task 4).

**Steps:**

- [ ] **Step 1: Edit the handler productions.**

In `grammar/Wok.cf`, replace lines 370-373:

```
EWith.    Exp2 ::= "with" "{" [HandlerArm] "}" Exp ;
HArm.     HandlerArm ::= ConId "." VarId [AtomPat] "->" Exp ;
HVArm.    HandlerArm ::= VarId "->" Exp ;
separator HandlerArm ";" ;
```

with:

```
-- Headerless handler (slice 1): every arm is dot-qualified.
EWith.    Exp2 ::= "with" "{" [HandlerArm] "}" Exp ;
-- Headed handler (slice 2): a non-empty ConId run names the handled effects so
-- arms may drop the qualifier. The first ConId is mandatory (so an empty header
-- cannot collide with EWith); the rest is a whitespace-separated [ConId] tail.
EWithH.   Exp2 ::= "with" ConId [ConId] "{" [HandlerArm] "}" Exp ;
-- Qualified operation arm (unchanged).
HArm.     HandlerArm ::= ConId "." VarId [AtomPat] "->" Exp ;
-- Unqualified arm: covers BOTH the value arm (`v -> e`, zero AtomPats) and an
-- unqualified operation arm (`get -> e`, `set s -> e`). The typechecker (Task 4)
-- classifies each by resolving the head name against the header. Replaces HVArm.
HUArm.    HandlerArm ::= VarId [AtomPat] "->" Exp ;
separator HandlerArm ";" ;
separator ConId "" ;
```

(`separator ConId ""` declares the whitespace-separated `[ConId]` list, mirroring `separator VarId ""` at line 128. `[ConId]` is a new list category; no other production uses it, so this is safe.)

- [ ] **Step 2: Regenerate the parser and reapply both documented patches.**

Run: `bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf`

Then reapply BOTH manual patches documented at `grammar/Wok.cf:13-56`:
1. `src-generated/GeneratedParser/Wok/Layout.hs` — split the `isLayoutOpen || isParenOpen` branch; add `maybeInsertSeparator` on the paren branch (binder `pt`, not `_`).
2. `src-generated/GeneratedParser/Wok/Par.y` — replace right-recursive `ListRecordFieldPat` with left-recursive `NEListRecordFieldPat`; update `PRecordOpen`.

Expected: BNFC reports the same conflict count as before. `EWithH` shares its prefix with `EWith` but diverges on the token after `with` (`ConId` vs `{`), and `HUArm` vs `HArm` diverge on the first token (`VarId` vs `ConId`) — neither should add a conflict. If a new conflict appears, it is in the `Exp2` / `HandlerArm` state; confirm the productions match the shapes above (the mandatory-first-`ConId` is what prevents the empty-header/`EWith` clash).

- [ ] **Step 3: Create the parse test file.**

Create `test/examples/27-with-header.wok`:

```
module Main
import Std.Base

effect State s = { get : s ; set : s -> () }

prog : () -> U64 with State U64
prog u = State.get

main : U64
main =
  with State { get   -> 0
             ; set s -> () }
  prog ()
```

- [ ] **Step 4: Build and verify parsing.**

Run: `cabal build` → the generated `Abs.hs` must define `EWithH`, `HUArm` and drop `HVArm`.
Run: `cabal run wok -- test/examples/27-with-header.wok --dump-anf`
Expected: NOT a parse error. A downstream "unhandled `EWithH`" / non-exhaustive `inferExprW` error IS expected here (Task 4). Also expected: `cabal build` will flag non-exhaustive matches on `Abs.HVArm` (now gone) and missing `Abs.EWithH`/`Abs.HUArm` in `Infer.hs` and `Elaborate.hs` — those are fixed in Task 4. To keep this task's build green, add temporary catch-alls is NOT allowed; instead, this task's "build succeeds" criterion is satisfied once the generated parser compiles. The `Infer.hs`/`Elaborate.hs` references to `HVArm` are updated in Task 4 Step 1 (do them now if `cabal build` fails on this task, committing them with Task 4).

> Note: because `HVArm` is referenced in `Infer.hs` (`inferHandler`'s `retArms`) and possibly `Elaborate.hs`, the project will not fully build until those references move to `HUArm` (Task 4 Step 1). If you run tasks strictly in order, fold Task 4 Step 1 into this commit so `cabal build` is green before committing. The acceptance check "parser regenerates + `Abs.hs` defines the new constructors" can be verified from the generated sources even if the full build waits for Task 4 Step 1.

- [ ] **Step 5: Commit (grammar + regenerated parser, plus the `HVArm`→`HUArm` reference move if needed for a green build).**

```bash
git add grammar/Wok.cf src-generated/GeneratedParser/Wok test/examples/27-with-header.wok
git commit -m "feat(grammar): effect header (with E { }), unqualified arm production"
```

---

### Task 4: Header typechecking — route, classify, resolve, coverage contract

**Goal:** `with State { get -> 0 ; set s -> () } e` type-checks (unqualified arms resolve to `State`); ambiguity and out-of-header qualification error; the header is a strict coverage contract; an empty handler errors.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs` (route `EWithH`, `HVArm`→`HUArm`, classification, header resolution, coverage, empty-handler), `src/Wok/TypeChecking/Error.hs` (header errors + `EmptyHandler` + render cases), `src/Wok/IR/Elaborate.hs` (if it references `HVArm`)
- Create: `test/typecheck-examples/28-with-header.wok`, `test/typecheck-fail-examples/{21-header-ambiguous,22-header-coverage,23-effect-not-in-header,24-empty-handler}.wok` + matching goldens

**Acceptance Criteria:**
- [ ] `Abs.EWithH h hs arms e` routes to `inferHandler mono (h:hs names) e arms`; `Abs.EWith` routes with `[]`.
- [ ] Unqualified arm head matching exactly one header effect → op arm for that effect; zero matches with no patterns → the value arm; ≥2 matches → `HandlerOpAmbiguous`.
- [ ] Unqualified arm with patterns but no matching header op → `UnknownUnqualifiedOp`.
- [ ] Qualified arm naming an effect not in a non-empty header → `HandlerEffectNotInHeader`.
- [ ] With a header, the handled set is the header; every op of every header effect must be covered (`HandlerCoverage`).
- [ ] `with { }` / `with E { }` with zero arms → `EmptyHandler`.
- [ ] `28-with-header.wok` type-checks; the four fail examples produce their respective errors.

**Verify:** `cabal run wok -- test/examples/27-with-header.wok --run` → `0`; `cabal test` green.

**Steps:**

- [ ] **Step 1: Move `HVArm` references to `HUArm` and add the error constructors.**

In `src/Wok/TypeChecking/Infer.hs` `inferHandler`, the `retArms` comprehension currently matches `Abs.HVArm`. It is replaced by the classification in Step 3 below; remove the old `opArms`/`retArms` comprehensions (lines 1659-1661). If `src/Wok/IR/Elaborate.hs` pattern-matches `Abs.HVArm` anywhere, it does not (handler arms reach Elaborate as the typed `THandlerArm`, not `Abs`); confirm with `grep -rn "HVArm" src/`.

In `src/Wok/TypeChecking/Error.hs`, add to `data TypeError` (after `MalformedHandlerArm` from Task 2):

```haskell
  | HandlerOpAmbiguous SourceSpan Text [Text]
    -- ^ An unqualified handler-arm op name is declared by more than one header
    --   effect. Args: position, op name, candidate effect names. Re-qualify.
  | UnknownUnqualifiedOp SourceSpan Text
    -- ^ An unqualified handler arm with arguments names no operation of any
    --   header effect. Args: position, op name.
  | HandlerEffectNotInHeader SourceSpan Text
    -- ^ A qualified handler arm names an effect absent from the (non-empty)
    --   header, which is a strict "exactly these effects" contract. Args:
    --   position, effect name.
  | EmptyHandler SourceSpan
    -- ^ A `with { }` / `with E { }` with zero arms handles nothing. Args: position.
```

Add render cases mirroring the `UnknownOperation` site:

```haskell
renderTypeError (HandlerOpAmbiguous sp op ens) =
  withPos sp $ "operation `" <> op <> "` is ambiguous between effects "
    <> Tx.intercalate ", " ens <> "; qualify it (e.g. " <> head ens <> "." <> op <> ")"
renderTypeError (UnknownUnqualifiedOp sp op) =
  withPos sp $ "no handled effect declares operation `" <> op <> "`"
renderTypeError (HandlerEffectNotInHeader sp en) =
  withPos sp $ "effect " <> en <> " is not in the handler header"
renderTypeError (EmptyHandler sp) =
  withPos sp $ "a handler must have at least one arm"
```

- [ ] **Step 2: Route both handler forms.**

Replace the `EWith` routing line (`src/Wok/TypeChecking/Infer.hs:1653`) with both:

```haskell
inferExprW mono (Abs.EWith arms e) = inferHandler mono [] e arms
inferExprW mono (Abs.EWithH (Abs.ConId (_, h)) hs arms e) =
  inferHandler mono (h : [ n | Abs.ConId (_, n) <- hs ]) e arms
```

Change `inferHandler`'s signature to take the header:

```haskell
inferHandler :: Map.Map Text (Type s) -> [Text] -> Abs.Exp -> [Abs.HandlerArm] -> TC s (Type s, TExprS s)
inferHandler mono header e arms = do
```

- [ ] **Step 3: Classify arms (qualified op / unqualified op / value), with header resolution.**

Replace the old `opArms`/`retArms` comprehensions with a classifier. Add this near `inferHandler`:

```haskell
-- | An operation arm resolved to a concrete (effect, op): heads, patterns, body, pos.
data ArmClass
  = OpArmC Text Text [Abs.AtomPat] Abs.Exp (Int, Int)
  | ValArmC (Int, Int) Text Abs.Exp

classifyArm :: Env -> [Text] -> Abs.HandlerArm -> TC s ArmClass
classifyArm env header arm = case arm of
  Abs.HArm (Abs.ConId (pos, en)) (Abs.VarId (_, op)) ps body -> do
    -- Qualified: must be in the header when a header is present.
    unless (null header || en `elem` header) $
      throwError (HandlerEffectNotInHeader (Just pos) en)
    pure (OpArmC en op ps body pos)
  Abs.HUArm (Abs.VarId (pos, name)) ps body ->
    case [ en | en <- header, declaresOp env en name ] of
      [en] -> pure (OpArmC en name ps body pos)
      []   -> if null ps
                then pure (ValArmC pos name body)
                else throwError (UnknownUnqualifiedOp (Just pos) name)
      ens  -> throwError (HandlerOpAmbiguous (Just pos) name ens)
  where
    declaresOp e en op =
      case lookupEffect en e of
        Just eInfo -> Map.member op (eiOps eInfo)
        Nothing    -> False
```

Then in `inferHandler`, after `env <- currentEnv`:

```haskell
  when (null arms) $
    throwError (EmptyHandler Nothing)
  classified <- mapM (classifyArm env header) arms
  let opArms  = [ (en, op, ps, body, pos) | OpArmC en op ps body pos <- classified ]
      valArms = [ (pos, v, body)          | ValArmC pos v body        <- classified ]
  case valArms of
    (_ : (pos2, _, _) : _) -> throwError (DuplicateReturnArm (Just pos2))
    _                      -> pure ()
```

(`EmptyHandler Nothing` for the zero-arm case has no per-arm position; if a position is desired, thread the `with` keyword position — optional.)

- [ ] **Step 4: Use the header as the handled set; keep the rest of `inferHandler`.**

Where `handledEffects` is computed (currently `Data.List.nub [ en | (en, _, _, _, _) <- opArms ]`), make the header authoritative when present:

```haskell
  let handledEffects = if null header
                         then Data.List.nub [ en | (en, _, _, _, _) <- opArms ]
                         else header
```

The existing coverage loop (`forM_ handledEffects …`), the per-arm typing loop, `dischargeEffects`, and the value-arm/answer-type logic are unchanged — they already consume `opArms`/`valArms` (renamed from `retArms`; rename uses accordingly).

- [ ] **Step 5: Write the tests.**

Create `test/typecheck-examples/28-with-header.wok` (same content as `test/examples/27-with-header.wok`).

Create `test/typecheck-fail-examples/21-header-ambiguous.wok`:

```
module Main
import Std.Base

effect Reader = { ask : U64 }
effect Config = { ask : U64 }

prog : () -> U64 with Reader + Config
prog u = Reader.ask + Config.ask

main : U64
main =
  with Reader Config { ask -> 0 }
  prog ()
```

Create `test/typecheck-fail-examples/22-header-coverage.wok` (header names `State`, only `get` covered):

```
module Main
import Std.Base

effect State s = { get : s ; set : s -> () }

prog : () -> U64 with State U64
prog u = State.get

main : U64
main =
  with State { get -> 0 }
  prog ()
```

Create `test/typecheck-fail-examples/23-effect-not-in-header.wok`:

```
module Main
import Std.Base

effect State s = { get : s ; set : s -> () }
effect Ask    = { ask : U64 }

prog : () -> U64 with State U64
prog u = State.get

main : U64
main =
  with State { get -> 0 ; set s -> () ; Ask.ask -> 1 }
  prog ()
```

Create `test/typecheck-fail-examples/24-empty-handler.wok`:

```
module Main
import Std.Base

effect Ask = { ask : U64 }

prog : () -> U64 with Ask
prog u = Ask.ask

main : U64
main =
  with { }
  prog ()
```

- [ ] **Step 6: Build, run, accept goldens.**

Run: `cabal build`
Run: `cabal run wok -- test/examples/27-with-header.wok --run` → `0`
Run each fail example with `--run` and confirm the intended error:
- `21-header-ambiguous` → `HandlerOpAmbiguous`
- `22-header-coverage` → `HandlerCoverage` (missing `set`)
- `23-effect-not-in-header` → `HandlerEffectNotInHeader`
- `24-empty-handler` → `EmptyHandler`
Run: `cabal run wok-tests -- --accept`; inspect each new golden; `cabal test` → green.

- [ ] **Step 7: Commit.**

```bash
git add src/Wok/TypeChecking/Infer.hs src/Wok/TypeChecking/Error.hs test/typecheck-examples/28-with-header.wok test/typecheck-fail-examples/21-header-ambiguous.wok test/typecheck-fail-examples/22-header-coverage.wok test/typecheck-fail-examples/23-effect-not-in-header.wok test/typecheck-fail-examples/24-empty-handler.wok test/typecheck-golden test/typecheck-fail-golden test/anf-golden test/typed-anf-golden
git commit -m "feat(tc): effect header resolution, coverage contract, empty-handler error"
```

---

### Task 5: Forgotten-resume lint (`Never`-exempt, `_`-suppressed)

**Goal:** A binder arm that binds a *named* continuation, never references it, on a *returning* operation, emits a `ForgottenResume` warning; a `_` (wildcard) binder suppresses it; a `Never`-result op is exempt; an escaping continuation (references `k`) does not warn.

**Files:**
- Modify: `src/Wok/TypeChecking/Error.hs` (`Warning` constructor + render), `src/Wok/TypeChecking/Infer.hs` (binder branch: accept `APWild`, occurrence check, emit warning)
- Create: `test/run-examples/{25-lint-forgotten-warn,26-lint-discard-wildcard,27-lint-escaping}.wok` + goldens (warnings appear in golden output)

**Acceptance Criteria:**
- [ ] `State.get k -> initialState` (k unreferenced, returning) emits a `ForgottenResume` warning.
- [ ] `State.get _ -> initialState` emits no warning.
- [ ] `Exn.throw msg k -> 0` (result `Never`) emits no warning.
- [ ] An escaping `Op.x args k -> SomeCon k` (references `k`) emits no warning.
- [ ] The lint is a warning: every example above still type-checks and runs.

**Verify:** `cabal run wok -- test/run-examples/25-lint-forgotten-warn.wok --run` → runs AND prints/records the warning; `cabal test` green.

**Steps:**

- [ ] **Step 1: Write the failing tests.**

Create `test/run-examples/25-lint-forgotten-warn.wok` (returning op `get`, named binder dropped → warns; still runs):

```
module Main
import Std.Base

effect State s = { get : s ; set : s -> () }

prog : () -> U64 with State U64
prog u = State.get

main : U64
main =
  with { State.get k    -> 0
         State.set s k   -> 0
         v               -> v }
  prog ()
```

Create `test/run-examples/26-lint-discard-wildcard.wok` (wildcard binder → no warning):

```
module Main
import Std.Base

effect State s = { get : s ; set : s -> () }

prog : () -> U64 with State U64
prog u = State.get

main : U64
main =
  with { State.get _   -> 0
         State.set s _  -> 0
         v              -> v }
  prog ()
```

Create `test/run-examples/27-lint-escaping.wok` (references `k` → no warning):

```
module Main
import Std.Base

data Parked = Blocked U64

effect Async = { await : U64 -> U64 }

prog : () -> U64 with Async
prog u = Async.await 7

main : Parked
main =
  with { Async.await fut k -> Blocked fut
         v                 -> Blocked 0 }
  prog ()
```

(In `27`, `k` is referenced — wait, `Blocked fut` does not reference `k`. Adjust so it does: use `Blocked fut` → change `Parked` to carry the continuation is not expressible without existentials. Instead reference `k` trivially by resuming under a guard: make the body `k fut` to reference `k`, which resumes — no warning, and the program runs. Use:)

Replace `27`'s handler body to reference `k`:

```
main : U64
main =
  with { Async.await fut k -> k fut
         v                 -> v }
  prog ()
```

Golden `test/run-golden/27-lint-escaping.expected` containing `7`.

For `25` and `26`, the value of `main` is `0` (handler aborts get). Goldens `25-…`/`26-…` contain `0`. The DIFFERENCE between 25 and 26 is the presence/absence of the warning in the typecheck-warning golden stream (see Step 4 for how warnings are asserted).

- [ ] **Step 2: Add the warning constructor + render.**

In `src/Wok/TypeChecking/Error.hs`, add to `data Warning` (after `RedundantClause`, line 149):

```haskell
  | ForgottenResume SourceSpan Text Text
    -- ^ An operation arm binds a NAMED continuation never referenced in its
    --   body, on a RETURNING operation (result /= Never). Args: position,
    --   effect, operation. Suppress with a `_` (wildcard) binder.
```

Add its render case wherever `Warning` is rendered (grep `RowShadow` in `Error.hs` for the render function):

```haskell
renderWarning (ForgottenResume sp en op) =
  withPos sp $ "continuation bound in arm " <> en <> "." <> op
    <> " is never used; did you mean to resume, or to abort? "
    <> "(use `_` to discard intentionally)"
```

- [ ] **Step 3: Add the occurrence check + handle the wildcard binder.**

Add a helper near `inferHandler` that tests whether a name is referenced in a typed body. Conservative: ignores shadowing (only ever suppresses, never false-positives).

```haskell
-- | Does the typed expression reference the given (surface) variable name?
-- Used by the forgotten-resume lint; conservative (shadowing ignored, so it
-- only ever SUPPRESSES the warning, never raises a false positive).
texpMentions :: Text -> Texp a -> Bool
texpMentions name = goE
  where
    goE (Ty.Texp _ f) = goF f
    goF f = case f of
      Ty.TVar n        -> n == name
      Ty.TQVar n _     -> n == name
      Ty.TParenOp _    -> False
      Ty.TLitI _       -> False
      Ty.TLitS _       -> False
      Ty.TLitC _       -> False
      Ty.TUnit         -> False
      Ty.TCon _        -> False
      Ty.TProjCon _ _  -> False
      Ty.TApp h xs     -> goE h || any goE xs
      Ty.TLam _ b      -> goE b
      Ty.TIf a b c     -> goE a || goE b || goE c
      Ty.TTuple xs     -> any goE xs
      Ty.TList xs      -> any goE xs
      Ty.TProj e _     -> goE e
      Ty.TRecord _ fs  -> any (goE . snd) fs
      Ty.TRecordExt _ e fs -> goE e || any (goE . snd) fs
      Ty.TLet ds b     -> any goD ds || goE b
      Ty.TCase e alts  -> goE e || any goA alts
      Ty.THandle e arms -> goE e || any goArm arms
    goD (Ty.TLocalDecl _ _ b) = goE b
    goA (Ty.TAlt _ ds b)      = any goD ds || goE b
    goArm (Ty.TReturnArm _ b)       = goE b
    goArm (Ty.TOpArm _ _ _ _ b)     = goE b
```

In `inferHandler`'s binder-arm `case` (the `binderPs` match), add the wildcard arm and the lint to the named arm. Replace the binder `case` (lines 1723-1746) with:

```haskell
          case binderPs of
            [] -> do
              -- AUTO-RESUME: body has the op result type.
              (bodyT, bodyNode) <- inferExprW mono1 body
              unify (Just pos) bodyT resultTy
              pure (Ty.TOpArm en op argPatNodes Tx.empty bodyNode)
            [Abs.APWild] -> do
              -- WILDCARD DISCARD: bind nothing, body has the answer type R,
              -- never lint. (Resume name empty signals no surface binder; the
              -- elaborator still generates a runtime resume Name.)
              (bodyT, bodyNode) <- inferExprW mono1 body
              unify (Just pos) bodyT answerT
              pure (Ty.TOpArm en op argPatNodes (Tx.pack "_") bodyNode)
            [Abs.APVar (Abs.VarId (_, kname))] -> do
              resumeRow <- freshRVar
              let resumeTy = arrowT resultTy resumeRow answerT
                  mono2    = Map.insert kname resumeTy mono1
              (bodyT, bodyNode) <- inferExprW mono2 body
              unify (Just pos) bodyT answerT
              -- Forgotten-resume lint: named binder, unreferenced, returning op.
              resultTy' <- force resultTy
              let isNever = case resultTy' of TCon TcNever [] -> True; _ -> False
              unless (isNever || texpMentions kname bodyNode) $
                addWarning (ForgottenResume (Just pos) en op)
              pure (Ty.TOpArm en op argPatNodes kname bodyNode)
            _ ->
              throwError (MalformedHandlerArm (Just pos) en op)
```

> Elaboration note: `TOpArm … (Tx.pack "_") …` uses a non-empty resume name, which routes the wildcard arm through the elaborator's CONTROL branch (`Elaborate.hs:522`, `withLocal "_" resumeN …`). Binding the surface name `_` is harmless (the body never references it). Confirm `cabal run wok -- test/run-examples/26-lint-discard-wildcard.wok --run` → `0`. If `withLocal "_"` is rejected or shadows the wildcard pattern, instead pass the empty resume name for the wildcard arm AND make the elaborator's auto-wrap path conditional on the typed body's type — simplest is to keep `"_"` and verify it runs (expected to work, since `_` is just a `Text` key in the local env).

- [ ] **Step 4: Assert warnings in goldens.**

Determine how the test harness surfaces warnings (grep `Warning`/`warnings` in `test/Spec.hs`). If warnings are already rendered into a golden stream, `25-lint-forgotten-warn` will show the `ForgottenResume` line and `26`/`27` will not. If warnings are NOT currently asserted by any golden, add a minimal assertion: extend the run/typecheck golden for these three files to include rendered warnings (mirror how `NonExhaustiveMatch`/`RowShadow` warnings are surfaced in existing goldens — grep `test/` for an existing warning golden to copy the format).

Run: `cabal build`
Run: `cabal run wok -- test/run-examples/25-lint-forgotten-warn.wok --run` → `0` + a `ForgottenResume` warning.
Run: `cabal run wok -- test/run-examples/26-lint-discard-wildcard.wok --run` → `0`, no warning.
Run: `cabal run wok -- test/run-examples/27-lint-escaping.wok --run` → `7`, no warning.
Run: `cabal run wok-tests -- --accept`; inspect goldens (confirm warning present only for `25`); `cabal test` → green.

- [ ] **Step 5: Commit.**

```bash
git add src/Wok/TypeChecking/Error.hs src/Wok/TypeChecking/Infer.hs test/run-examples/25-lint-forgotten-warn.wok test/run-examples/26-lint-discard-wildcard.wok test/run-examples/27-lint-escaping.wok test/run-golden test/anf-golden test/typed-anf-golden
git commit -m "feat(tc): forgotten-resume lint (Never-exempt, wildcard-suppressed)"
```

---

### Task 6: Migrate `Exn` examples + reconcile the design corpus + final green

**Goal:** Existing `Exn` examples use `throw : String -> Never` (no phantom param); the surface spec and memory say `_`/`Never` (not `discard`/output-only param); the whole suite is green.

**Files:**
- Modify: `test/run-examples/16-exn-abort.wok` (and its golden if changed), any `test/typecheck-examples/*.wok` using `effect Exn a = { throw : String -> a }`
- Modify: `docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md` (§1, §8), `docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md` (follow-ups #2/#4 → done), memory `effect-surface-syntax-final`

**Acceptance Criteria:**
- [ ] No `.wok` uses `effect Exn a = { throw : String -> a }` (phantom param); all use `effect Exn = { throw : String -> Never }`.
- [ ] Surface-spec §1 (non-returning = `Never` result, not op-quantified result var) and §8 (suppressor is `_`, not `discard`) updated.
- [ ] Roadmap follow-ups #2 and #4 marked resolved; the slice-2 status set appropriately.
- [ ] The `effect-surface-syntax-final` memory updated (`_` suppressor; `Never` non-returning marker).
- [ ] `cabal test` fully green.

**Verify:** `rg -n "throw : String -> a" test docs` → no matches; `rg -n "\bdiscard\b" docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md` → no suppressor matches; `cabal test` → green.

**Steps:**

- [ ] **Step 1: Migrate `16-exn-abort.wok`.**

Rewrite `test/run-examples/16-exn-abort.wok` to drop the phantom param:

```
module Main
import Std.Base

effect Exn = { throw : String -> Never }

risky : Bool -> U64 with Exn
risky b = if b then Exn.throw "boom" else 7

main : U64
main =
  with { Exn.throw msg k -> 0
         ; v -> v }
  risky True
```

(Golden `test/run-golden/16-exn-abort.expected` already contains `0`; unchanged.)

- [ ] **Step 2: Find and migrate any other phantom-param `Exn`.**

Run: `rg -n "throw : String -> a|effect Exn a" test`
For each hit, rewrite to `effect Exn = { throw : String -> Never }` and update the using function's signature/body so it still type-checks (the `with Exn` row no longer carries a param: `with Exn`, not `with Exn U64`).

- [ ] **Step 3: Reconcile surface spec §1 and §8.**

In `docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md`:
- §1: change the `Exn` example and the "non-returning operation" definition from "result is an operation-quantified type variable occurring only in result position" to "result type is `Never` (wok's bottom type)".
- §8: change the suppressor from `discard` to `_` (the wildcard binder); keep the "binder unreferenced, not never-called" wording and the `Never`-exempt clause.

- [ ] **Step 4: Update the roadmap and memory.**

In `docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md`: mark follow-ups #2 (MalformedHandlerArm — done) and #4 (non-returning discriminator — resolved via `Never`) as resolved; set the slice-2 status row to reflect implementation.

Update the `effect-surface-syntax-final` memory file (`/Users/zy/.claude/projects/-Users-zy-wokml/memory/effect-surface-syntax-final.md`): the forgotten-resume bullet now says suppressor `_` (not `discard`) and non-returning = `Never` result (not output-only effect param); note slice 2 implemented the header + lint + `Never`.

- [ ] **Step 5: Full green + no stale syntax.**

Run: `rg -n "throw : String -> a|effect Exn a" test docs` → no matches.
Run: `cabal run wok-tests -- --accept` (only if intended diffs); `cabal test` → all green.

- [ ] **Step 6: Commit.**

```bash
git add test docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md
git commit -m "docs+test: migrate Exn to Never; reconcile surface spec/roadmap to _/Never"
```

(The memory file is outside the repo; update it with the Write tool, not a git commit.)

---

## Self-review

- **Spec coverage:**
  - §2 `Never` + bottom elimination → Task 1.
  - §2.3 lint discriminator (result is `Never`) → Task 5 (`isNever`).
  - §3 header (grammar, resolution, ambiguity, coverage contract, value/op disambiguation, empty-handler) → Tasks 3 (grammar) + 4 (typecheck).
  - §4 lint + `_` suppressor → Task 5.
  - §5 `MalformedHandlerArm` → Task 2.
  - §6 migration + corpus reconcile → Task 6.
  - §7 deferred items → not built (correct).
- **Placeholder scan:** the one soft spot is Task 5 Step 4 (how warnings are surfaced in goldens) and Task 2/4 render-case helper names — both instruct "grep the existing sibling (`RowShadow`/`UnknownOperation`) and mirror its exact format," which is concrete given those siblings exist. No `TODO`/`TBD`.
- **Type consistency:** `inferHandler` gains a `[Text]` header arg (Tasks 4); `texpMentions :: Text -> Texp a -> Bool` (Task 5) matches the `TexpF` constructors in `Typed.hs:18-39`; `freshenNeverResult` uses `TArr`/`TCon TcNever []` per `Types.hs`; error/warning constructors are referenced exactly as declared.
- **Ordering / dependencies:** 1 → 2 → 3 → 4 → 5 → 6. Task 4 depends on Task 3's `EWithH`/`HUArm` (and the `HVArm`→`HUArm` reference move, flagged in Task 3 Step 4 / Task 4 Step 1). Task 5 depends on Task 1's `TcNever`. Task 6 depends on all.
- **Risk front-loading:** the grammar (Task 3) is the conflict risk and is third; it could move earlier, but Tasks 1–2 are independent and low-risk, so the order keeps each commit green. The subtle typing risk (`Never` bottom elimination) is Task 1, first.
