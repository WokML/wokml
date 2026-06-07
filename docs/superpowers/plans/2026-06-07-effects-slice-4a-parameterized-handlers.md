# Effects Slice 4a: Parameterized Handlers + `with … in` + `Control.Wok` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `State` (and any handler-local-parameter effect) clean and composable via real parameterized handlers, plus a terse `with … in` runner surface and a `Control.Wok` mtl prelude.

**Architecture:** A handler may declare a local parameter as a `name = init` block entry; it lives in the handler's captured scope `hsc` and is re-installed (with the new value) on the slice-3 deep resume via a new two-argument continuation `VContP`. Auto-resume threads the parameter unchanged; a parameter change takes control and calls `resume(newParam, result)`. The `with <runner> in <body>` form desugars to `runner (\_ -> body)`. `Control.Wok` ships `Reader`/`Writer`/`State`/`Except` + terse runners as a second embedded prelude.

**Tech Stack:** Haskell (GHC, cabal), BNFC-generated parser (`grammar/Wok.cf` → `src-generated/`), tasty/tasty-golden test suite (`test/Spec.hs`), wok `.wok` source goldens.

**Design source:** `docs/superpowers/specs/2026-06-07-effects-slice-4a-parameterized-handlers-design.md`.

**Two front-loaded risks** (do not defer): (1) nested different-effect composition — Task 5 is the gate; (2) the dangling-`in` layout behaviour — verified in Task 1.

**Build/verify commands:**
- Build: `cabal build`
- Full suite: `cabal test` (572 tests green at slice start — never let this regress on non-parameterized handlers)
- Run a wok file: `cabal run -v0 wok -- <file.wok> --run`
- Dump ANF: `cabal run -v0 wok -- <file.wok> --dump-anf`
- Accept goldens (read diffs first): `cabal run wok-tests -- --accept`
- After any grammar change: `bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf`, then reapply the two manual patches documented at `grammar/Wok.cf:13-56` (Layout.hs separator split; Par.y left-recursive `NEListRecordFieldPat`), then confirm the shift/reduce conflict count is unchanged.

---

### Task 1: Grammar — `HParam` block entry and `EWithRun` (`with … in`)

**Goal:** Parse `with State { s = 0 ; … } body` (param as a block entry) and `with state 0 in body` (runner sugar), with no new parser conflicts and correct dangling-`in` layout.

**Files:**
- Modify: `grammar/Wok.cf` (add two productions near the existing `EWith`/`HArm` rules, ~lines 371-382)
- Regenerate: `src-generated/GeneratedParser/Wok/*` (via `bnfc`)
- Modify (reapply patches): `src-generated/GeneratedParser/Wok/Layout.hs`, `src-generated/GeneratedParser/Wok/Par.y`
- Test: `test/parse-examples/` (if present) or a temporary `--dump-anf`/parse smoke check (see steps)

**Acceptance Criteria:**
- [ ] `with State { s = 0 ; get -> s ; set x k -> k x () ; v -> (v, s) } body` parses.
- [ ] `with state 0 in body` and `with writer in body` parse; the dangling `in` (no enclosing `let`) does not mis-close layout.
- [ ] `bnfc` regen + the two manual patches reapplied; shift/reduce conflict count unchanged from `main`.
- [ ] `cabal build` succeeds; `cabal test` still green (no behaviour change yet — these are additive productions).

**Verify:** `cabal build && cabal run -v0 wok -- /tmp/parse-smoke.wok --dump-anf` (parses; ANF dump is allowed to be wrong-typed at this stage — we only assert it *parses*). Then `cabal test`.

**Steps:**

- [ ] **Step 1: Record the baseline conflict count.** On a clean `main`-derived tree run the regen and capture conflicts:

```bash
bnfc --haskell -d -p GeneratedParser --text-token -o /tmp/bnfc-baseline grammar/Wok.cf 2>&1 | grep -i conflict || echo "no conflicts reported"
```

Note the number (e.g. "N shift/reduce"). This is the baseline to preserve.

- [ ] **Step 2: Add the two productions to `grammar/Wok.cf`.** After the `HUArm` rule (~line 381) add the param entry; after `EWithH` (~line 375) add the runner form:

```
-- Handler-local parameter: a `name = init` seed entry inside the handler block.
-- `=` distinguishes it from the `->` of op/value arms (HUArm/HArm). slice 4a.
HParam.   HandlerArm ::= VarId "=" Exp ;

-- Runner sugar: `with <runner> <args> in <body>` ≡ `<runner> <args> (\_ -> <body>)`.
-- VarId-headed (lowercase runner fn) so it never collides with EWithH (ConId-headed)
-- or EWith (`{`-headed). slice 4a.
EWithRun. Exp2 ::= "with" VarId [WithArg] "in" Exp ;
WRArg.    WithArg ::= Exp2 ;
separator WithArg "" ;
```

(Keep `HParam` listed among the `HandlerArm` alternatives so the existing `separator HandlerArm ";"` applies.)

- [ ] **Step 3: Regenerate and reapply the manual patches.**

```bash
bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf
```

Then reapply, per `grammar/Wok.cf:13-56`: (a) the `Layout.hs` `res` split that adds `maybeInsertSeparator` only on the paren-open branch; (b) the `Par.y` left-recursive `NEListRecordFieldPat` for `PRecordOpen`. Diff against the previous `src-generated` to confirm only the intended deltas plus the two new productions appear.

- [ ] **Step 4: Confirm conflict count unchanged.** Re-run the `grep -i conflict` from Step 1 against the real regen output. If `HParam` introduced a `VarId "=" …` vs `VarId [AtomPat] "->" …` (HUArm) conflict, it should resolve as a clean shift on the lookahead token (`=` vs `->`/AtomPat); if the count rose, STOP and report — the fallback is to gate `HParam` behind a distinct keyword, which needs a design note.

- [ ] **Step 5: Write the parse smoke file and verify both new forms parse, including dangling `in`.**

```
-- /tmp/parse-smoke.wok
module Main
import Std.Base

effect State s = { get : s, set : s -> () }

runner : s -> (() -> a with State s + eff e) -> (a, s) with eff e
runner i c = with State { s = i ; get -> s ; set x k -> k x () ; v -> (v, s) } c ()

prog : () -> U64 with State U64
prog u = let a = State.get in State.set (a + 1)

main : (U64, U64)
main =
  with runner 0 in
  prog ()
```

Run: `cabal run -v0 wok -- /tmp/parse-smoke.wok --dump-anf`
Expected: it **parses** (no `parse error`/`syntax error`). It may still fail later phases — that is fine here; assert only that parsing succeeds. The two `in`s (the `with … in` and the body's `let … in`) must both be accepted.

- [ ] **Step 6: Run the full suite (no regression).**

Run: `cabal test`
Expected: 572 tests still pass (additive grammar; no semantics changed yet).

- [ ] **Step 7: Commit.**

```bash
git add grammar/Wok.cf src-generated/
git commit -m "feat(grammar): HParam block entry + with…in runner form (slice 4a)"
```

---

### Task 2: ANF `hParam` field + runtime `VContP` two-argument resume

**Goal:** Carry the handler parameter through the runtime: store it in `hsc`, re-install it with the new value on deep resume, via a two-argument continuation. No behaviour change for non-parameterized handlers.

**Files:**
- Modify: `src/Wok/IR/Anf.hs` (`Handler` record `+hParam`, `collectHandler`, `renderHandler`)
- Modify: `src/Wok/Interp/Value.hs` (`Value` `+VContP`, its `Eq`/`Show`/`renderValue` arms)
- Modify: `src/Wok/Interp/Machine.hs` (`enter` `VContP` case; `dispatchOp` param rebind)

**Acceptance Criteria:**
- [ ] `Handler` has `hParam :: Maybe Binder`; all constructors/patterns updated (it is `Nothing` everywhere today).
- [ ] `VContP (Value -> Kont -> Kont)` exists; `enter` delivers `result` through `f param k` for exactly two args, errors otherwise.
- [ ] `dispatchOp` builds a `VContP` for a parameterized handler that rebinds the parameter in `hsc'` *and* applies the slice-3 answer-join rebind; for `hParam = Nothing` it builds the existing one-arg `VCont` unchanged.
- [ ] `cabal test` still green (existing handlers all carry `hParam = Nothing`).

**Verify:** `cabal build && cabal test` → 572 pass.

**Steps:**

- [ ] **Step 1: Extend `Handler` in `Anf.hs`.** Change the record (`src/Wok/IR/Anf.hs:70-78`) to add the field and update the two walkers:

```haskell
data Handler = Handler
  { hReturn :: (Binder, Expr)
  , hOps :: [OpArm]
  , hAnswerJoin :: Maybe JoinId
  , hParam :: Maybe Binder          -- ^ handler-local parameter (slice 4a); Nothing = ordinary
  } deriving (Eq, Show)
```

Update `collectHandler` (`Anf.hs:145-149`) to fold the parameter binder when present:

```haskell
collectHandler :: Handler -> HintTable -> HintTable
collectHandler (Handler ret ops _ mparam) t =
  let (rb, re) = ret
      t0 = maybe t (`insertBinder` t) mparam
      t1 = collectExpr re (insertBinder rb t0)
  in foldr collectOpArm t1 ops
```

Update the `renderHandler` pattern (`Anf.hs:315`) to accept the extra field (rendering is metadata; optionally print `param <name> = …` but not required for behaviour):

```haskell
renderHandler fmt tbl (Handler (rb, re) ops _ _) =
  ...   -- body unchanged
```

- [ ] **Step 2: Add `VContP` to `Value.hs`.** In `src/Wok/Interp/Value.hs:47-53` add the constructor:

```haskell
  | VContP (Value -> Kont -> Kont)   -- parameter-aware resume: \newParam after -> kont
```

Add its `Eq` arm (`Value.hs:60-67`, functions are never equal):

```haskell
  VContP{}     == VContP{}     = False
```

Add its `renderValue` arm (`Value.hs:150-152`):

```haskell
renderValue VContP{}   = Tx.pack "<continuation>"
```

- [ ] **Step 3: Add the `enter` case in `Machine.hs`.** After the `VCont` case (`Machine.hs:116-118`) add:

```haskell
  VContP f -> case args of
    [param, result] -> Right (Return result (f param k))
    _ -> Left (ArityError (Tx.pack "parameterized continuation expects exactly two arguments"))
```

- [ ] **Step 4: Build the parameterized resume in `dispatchOp`.** In `Machine.hs:152-172`, replace the single `reinstall`/`resumeVal` with a branch on `hParam h`. Keep the existing one-arg path for `Nothing`; for `Just pb` produce a `VContP` that *also* rebinds the parameter:

```haskell
          let answerRebind after sc =
                case hAnswerJoin h of
                  Just j
                    | Just (JoinPoint _ ps _ _) <- Map.lookup j (scJoins sc)
                    , (pb0 : _) <- ps ->
                        sc { scJoins =
                               Map.insert j
                                 (JoinPoint sc ps (Ret (AVar (bndName pb0))) after)
                                 (scJoins sc) }
                  _ -> sc
              resumeVal = case hParam h of
                Nothing ->
                  VCont (\after -> above (KHandle h (answerRebind after hsc) after))
                Just pb ->
                  VContP (\newParam after ->
                    let hsc' = (answerRebind after hsc)
                                 { scEnv = bindBinder pb newParam (scEnv hsc) }
                    in above (KHandle h hsc' after))
              env1 = bindBinders (oaArgs oa) argVals (scEnv hsc)
              env2 = bindBinder (oaResume oa) resumeVal env1
          in Right (Eval (oaBody oa) (Scope env2 (scJoins hsc)) kBelow)
```

(`answerRebind` is the slice-3 rebind refactored to take the scope; for `Just pb` the `scEnv` param rebind is layered on top. Note the param rebind reads `scEnv hsc` — the *original* captured env — so each resume starts from the handler's captured bindings with only the parameter replaced.)

- [ ] **Step 5: Build and run the full suite.**

Run: `cabal build && cabal test`
Expected: 572 pass. Every existing handler is `hParam = Nothing`, so `resumeVal` takes the unchanged `VCont` path; `VContP` is dead until elaboration produces it.

- [ ] **Step 6: Commit.**

```bash
git add src/Wok/IR/Anf.hs src/Wok/Interp/Value.hs src/Wok/Interp/Machine.hs
git commit -m "feat(runtime): hParam + VContP two-arg resume (slice 4a)"
```

---

### Task 3: Typing — parameterized handler in `inferHandler`

**Goal:** Type a handler with a `name = init` entry: bind the parameter `σ` in arm/value-arm scope, type `init : σ`, and type `resume : σ -> T -> R` in control arms.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs` (`ArmClass` `+ParamArmC`, `classifyArm`, `inferHandler`)
- Modify: `src/Wok/TypeChecking/Typed.hs` (`THandlerArm` `+TParamArm`)
- Test: `test/typecheck-examples/43-state-param.wok` (+ golden under `test/typecheck-golden/`)

**Acceptance Criteria:**
- [ ] A handler block may contain one `name = init` entry; `classifyArm` recognises `Abs.HParam`.
- [ ] In a parameterized handler the parameter name is in scope (type `σ`) in every op arm and in the value arm; `init` is checked at `σ`.
- [ ] Control-arm `resume` is typed `σ -> T -> R`; `set x k -> k x ()` checks; a swapped `k () x` fails to typecheck when `σ ≠ ()`.
- [ ] The typed node carries the parameter (a `TParamArm name initNode`) for elaboration.
- [ ] `cabal test` green; the new typecheck golden is stable.

**Verify:** `cabal run -v0 wok -- test/typecheck-examples/43-state-param.wok` (typechecks); `cabal test`.

**Steps:**

- [ ] **Step 1: Add the Typed arm.** In `src/Wok/TypeChecking/Typed.hs:44-46`:

```haskell
data THandlerArm a
  = TReturnArm (Tpat a) (Texp a)
  | TOpArm Text Text [Tpat a] Text (Texp a)
  | TParamArm Text (Texp a)            -- handler-local param: name + checked init (slice 4a)
```

- [ ] **Step 2: Classify `HParam`.** In `Infer.hs`, extend `ArmClass` (`:1673-1675`) and `classifyArm` (`:1677`):

```haskell
data ArmClass
  = OpArmC Text Text [Abs.AtomPat] Abs.Exp (Int, Int)
  | ValArmC Text Abs.Exp (Int, Int)
  | ParamArmC Text Abs.Exp (Int, Int)   -- slice 4a
```

```haskell
classifyArm env header arm = case arm of
  Abs.HParam (Abs.VarId (pos, name)) initExp ->
    pure (ParamArmC name initExp pos)
  Abs.HArm ... -- unchanged
  Abs.HUArm ... -- unchanged
```

- [ ] **Step 3: Thread the parameter through `inferHandler`.** In `inferHandler` (`Infer.hs:1737-1883`):

  1. After `classified <- mapM (classifyArm env header) arms` collect the param:

```haskell
  let paramArms = [ (name, initE, pos) | ParamArmC name initE pos <- classified ]
  mParam <- case paramArms of
    []                 -> pure Nothing
    [(name, initE, _)] -> do
      paramTy <- freshTVar KStar
      (initT, initNode) <- inferExprW mono initE
      unify Nothing initT paramTy
      pure (Just (name, paramTy, initNode))
    ((_, _, p2) : _ : _) -> throwError (DuplicateReturnArm (Just p2))  -- reuse "duplicate" style; or add a dedicated error
```

  2. Build the arm-typing environment with the parameter bound, and use it wherever the op arms and the value arm are inferred (replace `mono`-derived envs with one that includes the param):

```haskell
  let monoP = case mParam of
        Just (name, ty, _) -> Map.insert name ty mono
        Nothing            -> mono
```

  Use `monoP` as the base when building `mono1`/`mono2` for op arms (`Infer.hs:1816`, `:1848`) and `mono'` for the value arm (`Infer.hs:1876`).

  3. In the **control** arm branch (`Infer.hs:1840-1858`), when `mParam` is `Just (_, paramTy, _)`, give `resume` the extra leading arrow:

```haskell
              resumeRow <- freshRVar
              r0 <- freshRVar        -- pure-ish row for the partial first application
              let resumeTy = case mParam of
                    Just (_, paramTy, _) -> arrowT paramTy r0 (arrowT resultTy resumeRow answerT)
                    Nothing              -> arrowT resultTy resumeRow answerT
                  mono2 = Map.insert kname resumeTy mono1   -- mono1 = op-arg-extended monoP (Step 3.2)
```

  (Auto-resume arms are unchanged at the type level — body still checked at `resultTy`; the elaborator adds the two-argument wrap.)

  4. Emit `TParamArm name initNode` into the produced `THandle` arm list when `mParam` is present, so elaboration sees it. Add it alongside `opArmNodes` in both `THandle` results (`Infer.hs:1874`, `:1883`).

- [ ] **Step 4: Write the typecheck example + golden.**

```
-- test/typecheck-examples/43-state-param.wok
module Main
import Std.Base

effect State s = { get : s, set : s -> () }

runState : s -> (() -> a with State s + eff e) -> (a, s) with eff e
runState i c = with State { s = i ; get -> s ; set x k -> k x () ; v -> (v, s) } c ()

prog : () -> U64 with State U64
prog u = let a = State.get in State.set (a + 1)

main : (U64, U64)
main = runState 0 prog
```

Run: `cabal run -v0 wok -- test/typecheck-examples/43-state-param.wok` → typechecks (prints the inferred result, no error). Then generate the golden:

```bash
cabal run wok-tests -- --accept    # READ the diff for 43-state-param first
```

- [ ] **Step 5: Add a negative typecheck (swapped resume args).** Create `test/typecheck-fail-examples/44-state-swapped-resume.wok` with `set x k -> k () x` and confirm it is rejected (`() : σ` fails when `σ = U64`):

```
-- test/typecheck-fail-examples/44-state-swapped-resume.wok
module Main
import Std.Base
effect State s = { get : s, set : s -> () }
bad : s -> (() -> a with State s + eff e) -> (a, s) with eff e
bad i c = with State { s = i ; get -> s ; set x k -> k () x ; v -> (v, s) } c ()
main : U64
main = 0
```

Run `cabal run wok-tests -- --accept` and confirm the fail-golden records a type error (read the diff).

- [ ] **Step 6: Full suite + commit.**

```bash
cabal test
git add src/Wok/TypeChecking/Typed.hs src/Wok/TypeChecking/Infer.hs test/typecheck-examples/43-state-param.wok test/typecheck-golden/43-state-param.expected test/typecheck-fail-examples/44-state-swapped-resume.wok test/typecheck-fail-golden/44-state-swapped-resume.expected
git commit -m "feat(tc): parameterized handler typing — resume σ→T→R (slice 4a)"
```

---

### Task 4: Elaboration — lower the parameter + auto-resume two-arg pass

**Goal:** Lower a parameterized handler to `let s = init in Handle comp (Handler … (Just s_binder))`, and make auto-resume arms pass the current parameter: `resume(<param>, body)`. End-to-end, a single-State program runs and returns `(value, finalState)`.

**Files:**
- Modify: `src/Wok/IR/Elaborate.hs` (`elabKF … (THandle …)`: collect `TParamArm`, build `hParam`, two-arg auto-resume)
- Test: `test/run-examples/40-state-param.wok` (+ `test/run-golden/40-state-param.expected`)

**Acceptance Criteria:**
- [ ] A `TParamArm name init` lowers to a fresh binder `pb`, a `let pb = <init>` wrapping the `Handle`, and `hParam = Just pb` on the `Handler`.
- [ ] Auto-resume arm bodies in a parameterized handler lower to `let res = resume(pb, body) in deliver res` (two-argument `RApp`); control arms are unchanged.
- [ ] `40-state-param.wok` runs to the expected `(value, finalState)` pair.
- [ ] `cabal test` green.

**Verify:** `cabal run -v0 wok -- test/run-examples/40-state-param.wok --run` → the expected pair.

**Steps:**

- [ ] **Step 1: Collect the param in `elabKF (THandle …)`.** In `src/Wok/IR/Elaborate.hs:486-500` add a param source list and a fresh binder, and thread it into the `Handler`:

```haskell
elabKF tk _ (THandle e arms) = do
  let opArmsSrc  = [ (effect, op, ps, resume, body)
                   | TOpArm effect op ps resume body <- arms ]
      retArmsSrc = [ (pat, body) | TReturnArm pat body <- arms ]
      paramSrc   = [ (name, initE) | TParamArm name initE <- arms ]
  handledBody <- elabK TRet e
  mParam <- case paramSrc of
    []               -> pure Nothing
    ((name, initE):_) -> do
      pn <- bindFresh name
      pure (Just (pn, name, initE))
  opArms <- mapM (elabOpArm tk mParam) opArmsSrc
  retArm <- ...   -- unchanged, but elaborated with the param name in scope (see Step 3)
  let answerJoin = case tk of TJump j -> Just j ; TRet -> Nothing
      hParamB    = fmap (\(pn,_,_) -> Binder pn Unrestricted (teType e)) mParam   -- type refined below
      core       = Handle handledBody (Handler retArm opArms answerJoin hParamB)
  case mParam of
    Nothing            -> pure core
    Just (pn, _, initE) -> do
      initRhs <- ...   -- elaborate initE to an Rhs via elabRhs / normName
      pure (Let (Binder pn Unrestricted (teType initE)) initRhs core)
```

For the init lowering, reuse the existing value-position machinery: `normName initE (\a -> pure (Let (Binder pn …) (RAtom a) core))` (or `elabRhs initE` if it is a compound). Use the simplest form that matches existing `elabLocalDecls` value-binding lowering at `Elaborate.hs:555+`.

- [ ] **Step 2: Make the param name resolvable inside arms.** When elaborating each op arm and the value arm, the surface param name must map to the fresh binder `pn`. Wrap the arm elaboration in `withLocal name pn (…)` (the same combinator the resume binder uses, `Elaborate.hs:528`). Apply it around `elabOpArm` bodies and the return-arm body when `mParam = Just (pn, name, _)`.

- [ ] **Step 3: Two-argument auto-resume.** Change `elabOpArm` (`Elaborate.hs:512-535`) to take `mParam` and, in the **auto-resume** branch (`Tx.null resumeName`, `:519-524`), pass the current parameter:

```haskell
    elabOpArm :: TailK -> Maybe (Name, Text, TExpr) -> (Text, Text, [TPat], Text, TExpr) -> Elab OpArm
    elabOpArm tk2 mParam (effect, op, ps, resumeName, body) = do
      (argBinders, extender) <- elabParams ps
      resumeN <- bindFresh (Tx.pack "resume")
      armBody <-
        if Tx.null resumeName
          then extender $ normName body $ \v -> do
                 res <- bindFresh (Tx.pack "res")
                 let call = case mParam of
                       Just (pn, _, _) -> RApp (AVar resumeN) [AVar pn, v]   -- resume(param, body)
                       Nothing         -> RApp (AVar resumeN) [v]            -- slice-1 one-arg
                 pure (Let (Binder res Unrestricted (teType body)) call
                           (deliverAtom tk2 (AVar res)))
          else extender $ withLocal resumeName resumeN (elabK tk2 body)
      pure (OpArm effect op argBinders (Binder resumeN Unrestricted (teType body)) armBody)
```

(The control branch is unchanged — `set x k -> k x ()` already elaborates `k x ()` to `RApp k [x, ()]`, which the runtime `VContP` `enter` case consumes.)

- [ ] **Step 4: Refine the `hParam` binder type.** Use the parameter's inferred type if available; if elaboration does not carry it, `teType initE` is the seed's type and is adequate for the untyped interpreter (the field is read only for `Maybe`-ness at runtime, not for its inner type). Keep `Binder pn Unrestricted (teType initE)`.

- [ ] **Step 5: Write the end-to-end run example + golden.**

```
-- test/run-examples/40-state-param.wok
module Main
import Std.Base

effect State s = { get : s, set : s -> () }

runState : s -> (() -> a with State s + eff e) -> (a, s) with eff e
runState i c = with State { s = i ; get -> s ; set x k -> k x () ; v -> (v, s) } c ()

prog : () -> U64 with State U64
prog u =
  let a = State.get in
  let b = State.set (a + 5) in
  let c = State.get in
  a + c

main : (U64, U64)
main = runState 100 prog
```

Run: `cabal run -v0 wok -- test/run-examples/40-state-param.wok --run`
Expected: `(205, 105)` (a=100, set 105, c=105 → a+c=205; final state 105).

Then `cabal run wok-tests -- --accept` (read the `40-state-param` diff; it should be `(205, 105)`).

- [ ] **Step 6: Full suite + commit.**

```bash
cabal test
git add src/Wok/IR/Elaborate.hs test/run-examples/40-state-param.wok test/run-golden/40-state-param.expected
git commit -m "feat(elab): lower parameterized handler + two-arg auto-resume (slice 4a)"
```

---

### Task 5: Nested composition gate (RISK 1)

**Goal:** Prove the real mechanism composes where the encoding failed — two parameterized handlers of *different* effects, interleaved operations, both parameters threaded correctly, in both nesting orders.

**Files:**
- Test: `test/run-examples/41-state-writer-nested.wok`, `test/run-examples/42-writer-state-nested.wok` (+ goldens)

**Acceptance Criteria:**
- [ ] `state` outside / `writer` inside → `((205, [100, 105]), 105)`.
- [ ] `writer` outside / `state` inside → `((205, 105), [100, 105])`.
- [ ] Both run via the real parameterized mechanism (no answer-type encoding).

**Verify:** `cabal run -v0 wok -- test/run-examples/41-state-writer-nested.wok --run` → `((205, [100, 105]), 105)`.

**Steps:**

- [ ] **Step 1: Write the two nested examples.**

```
-- test/run-examples/41-state-writer-nested.wok   (state OUTSIDE, writer INSIDE)
module Main
import Std.Base

effect State  s = { get : s, set : s -> () }
effect Writer w = { tell : w -> () }

state  : s -> (() -> a with State s + eff e) -> (a, s) with eff e
state  i c = with State  { s = i ;   get -> s ; set x k -> k x () ; v -> (v, s) } c ()

writer : (() -> a with Writer [w] + eff e) -> (a, [w]) with eff e
writer c = with Writer { log = [] ; tell w k -> k (log ++ w) () ; v -> (v, log) } c ()

both : () -> U64 with State U64 + Writer [U64]
both u =
  let a  = State.get in
  let x1 = Writer.tell [a] in
  let x2 = State.set (a + 5) in
  let b  = State.get in
  let x3 = Writer.tell [b] in
  a + b

main : ((U64, [U64]), U64)
main = state 100 (\u -> writer both)
```

```
-- test/run-examples/42-writer-state-nested.wok   (writer OUTSIDE, state INSIDE)
module Main
import Std.Base

effect State  s = { get : s, set : s -> () }
effect Writer w = { tell : w -> () }

state  : s -> (() -> a with State s + eff e) -> (a, s) with eff e
state  i c = with State  { s = i ;   get -> s ; set x k -> k x () ; v -> (v, s) } c ()

writer : (() -> a with Writer [w] + eff e) -> (a, [w]) with eff e
writer c = with Writer { log = [] ; tell w k -> k (log ++ w) () ; v -> (v, log) } c ()

both : () -> U64 with State U64 + Writer [U64]
both u =
  let a  = State.get in
  let x1 = Writer.tell [a] in
  let x2 = State.set (a + 5) in
  let b  = State.get in
  let x3 = Writer.tell [b] in
  a + b

main : ((U64, U64), [U64])
main = writer (\u -> state 100 both)
```

- [ ] **Step 2: Run both and confirm the parameters thread.**

Run: `cabal run -v0 wok -- test/run-examples/41-state-writer-nested.wok --run`
Expected: `((205, [100, 105]), 105)`

Run: `cabal run -v0 wok -- test/run-examples/42-writer-state-nested.wok --run`
Expected: `((205, 105), [100, 105])`

If either drops a parameter (e.g. `[]` or `100`), STOP — the runtime re-install in Task 2 Step 4 is wrong (likely `answerRebind`/`scEnv` reading a stale scope). Fix Task 2 before proceeding; this is the gate.

- [ ] **Step 3: Accept goldens + full suite + commit.**

```bash
cabal run wok-tests -- --accept    # read the 41/42 diffs
cabal test
git add test/run-examples/41-state-writer-nested.wok test/run-examples/42-writer-state-nested.wok test/run-golden/41-state-writer-nested.expected test/run-golden/42-writer-state-nested.expected
git commit -m "test(effects): nested parameterized-handler composition gate (slice 4a)"
```

---

### Task 6: `with … in` runner sugar

**Goal:** Desugar `with <runner> <args> in <body>` to `<runner> <args> (\_ -> <body>)`, reusing existing application/lambda typing and elaboration.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs` (`inferExprW` case for `Abs.EWithRun`)
- Test: `test/run-examples/45-with-in-sugar.wok` (+ golden)

**Acceptance Criteria:**
- [ ] `with f a b in body` typechecks and runs exactly as `f a b (\_ -> body)`.
- [ ] Stacked `with … in / with … in / body` nests outer-to-inner.
- [ ] `cabal test` green.

**Verify:** `cabal run -v0 wok -- test/run-examples/45-with-in-sugar.wok --run` → expected pair.

**Steps:**

- [ ] **Step 1: Desugar in `inferExprW`.** Next to the `EWith`/`EWithH` cases (`Infer.hs:1665-1667`) add:

```haskell
inferExprW mono (Abs.EWithRun (Abs.VarId (_, f)) wargs body) =
  let runner = foldl (\acc (Abs.WRArg a) -> Abs.EApp acc a) (Abs.EVar (mkVarId f)) wargs
      thunk  = Abs.ELam [Abs.APWild] body
  in inferExprW mono (Abs.EApp runner thunk)
```

(`mkVarId` rebuilds an `Abs.VarId` token with a dummy position from the name `f` — follow how other synthesized `Abs` nodes are built in this module; if a position is required, reuse the `with` keyword's position threaded into `EWithRun`. If the generated `EWithRun` carries the `VarId` token directly, use it as-is rather than rebuilding.)

- [ ] **Step 2: Write the sugar example + golden.**

```
-- test/run-examples/45-with-in-sugar.wok
module Main
import Std.Base

effect State s = { get : s, set : s -> () }

state : s -> (() -> a with State s + eff e) -> (a, s) with eff e
state i c = with State { s = i ; get -> s ; set x k -> k x () ; v -> (v, s) } c ()

main : (U64, U64)
main =
  with state 100 in
  let a = State.get in
  let b = State.set (a + 5) in
  State.get
```

Run: `cabal run -v0 wok -- test/run-examples/45-with-in-sugar.wok --run`
Expected: `(105, 105)` (a=100, set 105, final get 105; final state 105).

- [ ] **Step 3: Accept golden, full suite, commit.**

```bash
cabal run wok-tests -- --accept    # read the 45 diff
cabal test
git add src/Wok/TypeChecking/Infer.hs test/run-examples/45-with-in-sugar.wok test/run-golden/45-with-in-sugar.expected
git commit -m "feat(tc): with…in runner sugar desugars to runner (\\_ -> body) (slice 4a)"
```

---

### Task 7: `Control.Wok` prelude + loader embedding + usage goldens

**Goal:** Ship the mtl quartet (`Reader`/`Writer`/`State`/`Except`) + terse runners as a second embedded prelude, usable via `import Control.Wok` and the `with … in` sugar.

**Files:**
- Create: `prelude/Control/Wok.wok`
- Modify: `src/Wok/Prelude.hs` (add `controlWokName`/`controlWokSource`)
- Modify: `src/Wok/Loader.hs` (insert the second embedded module into the map)
- Modify: `wokml.cabal` (add `prelude/Control/Wok.wok` to data-files)
- Test: `test/run-examples/46-control-wok-mtl.wok`, `test/run-examples/47-state-runner-eval-exec.wok` (+ goldens)

**Acceptance Criteria:**
- [ ] `import Control.Wok` resolves with no `-I`; `Control.Wok` imports `Std.Base`.
- [ ] The mtl demo runs and returns the expected nested result; reordering the stack changes the result as documented.
- [ ] `run`/`eval`/`exec` variants differ only by value arm and return the right shapes.
- [ ] `cabal test` green.

**Verify:** `cabal run -v0 wok -- test/run-examples/46-control-wok-mtl.wok --run` → expected; `cabal test`.

**Steps:**

- [ ] **Step 1: Write the prelude.** Create `prelude/Control/Wok.wok`:

```
module Control.Wok
import Std.Base

effect Reader r = { ask : r }
reader : r -> (() -> a with Reader r + eff e) -> a with eff e
reader e c = with Reader { ask -> e } c ()

effect State s = { get : s, set : s -> () }
state : s -> (() -> a with State s + eff e) -> (a, s) with eff e
state i c = with State { s = i ; get -> s ; set x k -> k x () ; v -> (v, s) } c ()

evalState : s -> (() -> a with State s + eff e) -> a with eff e
evalState i c = with State { s = i ; get -> s ; set x k -> k x () ; v -> v } c ()

execState : s -> (() -> a with State s + eff e) -> s with eff e
execState i c = with State { s = i ; get -> s ; set x k -> k x () ; v -> s } c ()

effect Writer w = { tell : w -> () }
writer : (() -> a with Writer [w] + eff e) -> (a, [w]) with eff e
writer c = with Writer { log = [] ; tell w k -> k (log ++ w) () ; v -> (v, log) } c ()

effect Except e = { throw : e -> Never }
except : (() -> a with Except e + eff r) -> Result a e with eff r
except c = with Except { throw e k -> Err e ; v -> Ok v } c ()
```

- [ ] **Step 2: Expose its source in `Prelude.hs`.** Add alongside `preludeSource` (`src/Wok/Prelude.hs`):

```haskell
controlWokName :: Text
controlWokName = Tx.pack "Control.Wok"

controlWokSource :: IO Text
controlWokSource = do
  path <- Paths_wok.getDataFileName "prelude/Control/Wok.wok"
  TIO.readFile path
```

Export both from the module list.

- [ ] **Step 3: Insert it in the loader.** In `src/Wok/Loader.hs:74-78`, load and prepend the second embedded module:

```haskell
  preludeText    <- liftIO Prelude.preludeSource
  preludeLM      <- liftEither (parseAndPrep "<Std.Base>" Embedded preludeText)
  controlWokText <- liftIO Prelude.controlWokSource
  controlWokLM   <- liftEither (parseAndPrep "<Control.Wok>" Embedded controlWokText)
  extraLMs       <- traverse (ExceptT . loadOne) extras
  ...
  mm             <- liftEither (buildMap (preludeLM : controlWokLM : extraLMs ++ [entryLM]))
```

(`buildMap`/the topo-sort already handle `Control.Wok`'s `import Std.Base`. A user file not importing `Control.Wok` simply never references it; confirm an unused embedded module is harmless — it is, the map is keyed by module name and only imported modules are pulled into a program.)

- [ ] **Step 4: Add the data-file.** In `wokml.cabal`, under `data-files:`, add:

```
data-files:
    prelude/Std/Base.wok
    prelude/Control/Wok.wok
```

- [ ] **Step 5: The mtl demo.**

```
-- test/run-examples/46-control-wok-mtl.wok
module Main
import Std.Base
import Control.Wok

step : U64 -> U64 with Reader U64 + Writer [U64] + State U64 + Except String
step n =
  let limit = Reader.ask in
  let cur   = State.get in
  let next  = cur + n in
  if next > limit
    then Except.throw "over budget"
    else let x1 = State.set next in
         let x2 = Writer.tell [n] in
         next

prog : () -> U64 with Reader U64 + Writer [U64] + State U64 + Except String
prog u = let a = step 10 in let b = step 20 in step 30

main : Option ((U64, U64), [U64])
main =
  with except in
  with reader 100 in
  with writer in
  with state 0 in
  let r = prog () in
  Some r
```

Run: `cabal run -v0 wok -- test/run-examples/46-control-wok-mtl.wok --run`
Expected: `Some ((60, 60), [10, 20, 30])` (running total 10→30→60 ≤ 100, log [10,20,30], no throw).

(Note: `except`/`writer` take no seed, so they appear as `with except in` / `with writer in`. The value arm of `except` wraps in `Some`/`Ok`; here the explicit `Some r` plus `except`'s `Ok`/`Err` reshape compose — verify the exact nesting against the run and adjust the annotation to the produced shape if the `Some`/`Ok` layering differs; the **golden records whatever the mechanism produces**, the point is it runs without losing state/log.)

- [ ] **Step 6: run/eval/exec shapes.**

```
-- test/run-examples/47-state-runner-eval-exec.wok
module Main
import Std.Base
import Control.Wok

prog : () -> U64 with State U64
prog u = let a = State.get in let b = State.set (a + 5) in State.get

main : ((U64, U64), U64, U64)
main =
  let r = state 100 prog in        -- (105, 105)
  let v = evalState 100 prog in    -- 105
  let s = execState 100 prog in    -- 105
  (r, v, s)
```

Run: `cabal run -v0 wok -- test/run-examples/47-state-runner-eval-exec.wok --run`
Expected: `((105, 105), 105, 105)`.

- [ ] **Step 7: Accept goldens, full suite, commit.**

```bash
cabal run wok-tests -- --accept    # read 46 and 47 diffs carefully
cabal test
git add prelude/Control/Wok.wok src/Wok/Prelude.hs src/Wok/Loader.hs wokml.cabal test/run-examples/46-control-wok-mtl.wok test/run-examples/47-state-runner-eval-exec.wok test/run-golden/46-control-wok-mtl.expected test/run-golden/47-state-runner-eval-exec.expected
git commit -m "feat(prelude): Control.Wok mtl quartet as a second embedded prelude (slice 4a)"
```

---

### Task 8: Docs reconciliation + branch review prep

**Goal:** Update the surface spec and roadmap to record slice 4a as shipped, and prepare the full-branch review.

**Files:**
- Modify: `docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md` (§11 — move "parameterized handlers" from deferred to shipped; note `with … in` + `Control.Wok` mtl)
- Modify: `docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md` (status board 4a → DONE with the final green test count)

**Acceptance Criteria:**
- [ ] Surface spec §11 reflects shipped parameterized handlers (in-block `name = init`), the `with … in` runner sugar, and `Control.Wok` (mtl half); concurrency stays deferred.
- [ ] ROADMAP status board: slice 4a → DONE (N tests green); 4b stays deferred.
- [ ] `cabal test` green; final green count recorded.

**Verify:** `cabal test` (record the count); docs read consistently.

**Steps:**

- [ ] **Step 1: Update the surface spec §11.** In `docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md`, move the "Parameterized handlers" bullet from the deferred list to a "Shipped (slice 4a)" entry, stating the in-block `name = init` seed, two-arg `resume(newParam, result)`, the `with … in` runner sugar, and `Control.Wok`'s mtl runners. Keep scheduler/`spawn`/`par`/`Future`/general-`Monoid` `Writer` in the deferred list.

- [ ] **Step 2: Update the ROADMAP.** In `docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md` status board, set the 4a row to `DONE — merged to main (N tests green)` (fill N from the final `cabal test`). Leave 4b deferred.

- [ ] **Step 3: Final suite + commit.**

```bash
cabal test
git add docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md
git commit -m "docs(effects): record slice 4a as shipped (parameterized handlers + with…in + Control.Wok)"
```

- [ ] **Step 4: Request full-branch review.** Per the standing rule, run a full-branch review (`superpowers-extended-cc:requesting-code-review` or the project's review flow) before any merge to `main`. Do not merge until the review passes.

---

## Notes for the executor

- **TDD anchor order:** Task 1 nails the layout/grammar risk; Tasks 2→4 build the mechanism and prove a single parameterized State end-to-end; **Task 5 is the composition gate** — if it fails, the bug is in Task 2's `dispatchOp` re-install, not in Task 5. Do not paper over a Task-5 failure by editing the test.
- **Never regress** the 572 non-parameterized tests — every change in Tasks 2–4 is gated on `cabal test` staying green for `hParam = Nothing` handlers.
- **Goldens:** always read the `--accept` diff before accepting; the run-golden output format is whatever `renderValue` produces (e.g. `(205, 105)`, `[10, 20, 30]`, `Some (...)`).
- **Grammar fallback:** if Task 1 Step 4 shows new conflicts from `EWithRun`/`EWithH` overlap, the VarId-headed `EWithRun` form already avoids the ConId collision; if `HParam` vs `HUArm` conflicts, confirm the `=`-vs-`->` lookahead is a clean shift before proceeding.
