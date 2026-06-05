# Effects Slice 1: `with`-prefix handlers + auto-resume/binder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `handle … of { … ; return v -> v }` handler form with a flat `with { arms } computation` prefix, make operation arms auto-resume by default and take control when they bind a continuation, and support value (arrow-less) operations — all running on the existing CEK interpreter.

**Architecture:** Surface change only; the typed AST (`THandle`/`TOpArm`/`TReturnArm`), the ANF (`Handle`/`Handler`/`OpArm`), and the runtime (`dispatchOp` already binds a reusable `resume`) are reused. `with { arms } rest` parses like a lambda (a prefix consuming the rest of the block as a trailing `Exp`) and routes to the existing `inferHandler`/`THandle` lowering. The continuation binder is the operation arm's `(arity+1)`-th pattern, split from the args semantically (the op's arity is known from its scheme), so no new grammar is needed for it. An arm with no binder keeps today's auto-wrap (`resume(body)`); an arm with a binder binds that name to the runtime continuation and is elaborated as-is, with its body typed at the handler's answer type `R`.

**Tech Stack:** BNFC grammar (`grammar/Wok.cf`) -> generated Happy/Alex parser (`src-generated/`), Haskell typechecker (`src/Wok/TypeChecking/Infer.hs`), ANF elaborator (`src/Wok/IR/Elaborate.hs`), CEK interpreter (`src/Wok/Interp/Machine.hs`), tasty-golden test suite (`test/Spec.hs`).

Implements **slice 1** of `docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md`. Surface design: `docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md` (sections 1, 4, 5, 6). Rejected alternatives: `effect-surface-syntax-final` memory.

---

## Build / test commands (reference)

- Regenerate parser after editing the grammar: `bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf`
  then reapply the two manual patches documented at the top of `grammar/Wok.cf` (the `Layout.hs` separator patch and the `Par.y` `NEListRecordFieldPat` patch).
- Build: `cabal build`
- Full test suite: `cabal test` (or `cabal run wok-tests`)
- Accept/regenerate golden files: `cabal run wok-tests -- --accept`
- Run one program: `cabal run wok -- <file.wok> --run` (prints the value of `main`)

---

## File structure

- `grammar/Wok.cf` — add `EWith`, add `HVArm`, remove `EHandle`/`HReturn`, free `resume`. (Task 1)
- `src-generated/GeneratedParser/Wok/*` — regenerated; reapply documented patches. (Task 1)
- `src/Wok/TypeChecking/Infer.hs` — route `EWith`; restructure `inferHandler` (answer type first, arity-split args/binder, body-type branch, resume binding). (Task 2)
- `src/Wok/TypeChecking/Typed.hs` — no shape change (`TOpArm` already carries the resume name). (Task 2, read-only confirm)
- `src/Wok/IR/Elaborate.hs` — `elabOpArm` branches on binder presence. (Task 3)
- `src/Wok/Interp/Machine.hs` — read-only confirm; no change expected. (Task 4)
- `test/run-examples/*.wok`, `test/typecheck-examples/*.wok`, `test/typecheck-fail-examples/*.wok`, goldens — new tests + migration. (Tasks 2–5)

---

### Task 1: Grammar — `with`-prefix handler, value arm, drop `handle`/`return`, free `resume`

**Goal:** The new surface parses and the old `handle`/`return` forms are gone.

**Files:**
- Modify: `grammar/Wok.cf:113` (ReservedKw), `grammar/Wok.cf:365-368` (handler productions)
- Regenerate: `src-generated/GeneratedParser/Wok/*`
- Create: `test/examples/26-with-handler.wok` (parse-golden input)

**Acceptance Criteria:**
- [ ] `EHandle` and `HReturn` productions removed; `handle`/`return` are no longer keywords.
- [ ] `EWith. Exp2 ::= "with" "{" [HandlerArm] "}" Exp ;` parses a prefix handler whose trailing `Exp` is the handled computation.
- [ ] `HVArm. HandlerArm ::= VarId "->" Exp ;` parses a value arm; `HArm` unchanged.
- [ ] `resume` removed from `ReservedKw` (usable as an ordinary binder name).
- [ ] Parser regenerates with no new shift/reduce or reduce/reduce conflicts beyond the documented ones; the two documented manual patches reapplied; `cabal build` succeeds.
- [ ] `test/examples/26-with-handler.wok` parses (appears in the parse-golden group).

**Verify:** `cabal build && cabal run wok -- test/examples/26-with-handler.wok --dump-anf` -> parses and dumps ANF without a parse error.

**Steps:**

- [ ] **Step 1: Edit `grammar/Wok.cf` — free `resume` from reserved words.**

Change line 112-113 from:

```
rules     ReservedKw ::= "contract" | "type" | "deriving" | "forall"
                       | "do" | "record" | "row" | "fun" | "ctl" | "resume" ;
```

to (drop `"resume"`; keep the rest):

```
rules     ReservedKw ::= "contract" | "type" | "deriving" | "forall"
                       | "do" | "record" | "row" | "fun" | "ctl" ;
```

- [ ] **Step 2: Edit `grammar/Wok.cf` — replace the handler productions.**

Replace lines 363-368:

```
-- Effect handlers. `of` is already a layout keyword, so the `{ ... }` block
-- is indentation-driven like `case ... of`.
EHandle.  Exp2 ::= "handle" Exp "of" "{" [HandlerArm] "}" ;
HArm.     HandlerArm ::= ConId "." VarId [AtomPat] "->" Exp ;
HReturn.  HandlerArm ::= "return" VarId "->" Exp ;
separator HandlerArm ";" ;
```

with:

```
-- Effect handlers: `with { arms } computation` (flat prefix). The handler block
-- uses EXPLICIT braces (`with` cannot be a layout keyword without breaking the
-- type-level `with` in `T -> R with E`). The trailing Exp is the handled
-- computation, consumed like a lambda body (EWith is Exp2, body is full Exp).
-- A value arm (HVArm) is the return clause; the `return` keyword is gone. The
-- optional continuation binder is the (arity+1)-th AtomPat on an operation arm,
-- split from the op's arguments by the typechecker (Task 2), so HArm is unchanged.
EWith.    Exp2 ::= "with" "{" [HandlerArm] "}" Exp ;
HArm.     HandlerArm ::= ConId "." VarId [AtomPat] "->" Exp ;
HVArm.    HandlerArm ::= VarId "->" Exp ;
separator HandlerArm ";" ;
```

- [ ] **Step 3: Regenerate the parser and reapply the documented patches.**

Run: `bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf`

Then reapply BOTH manual patches documented at `grammar/Wok.cf:13-56`:
1. `src-generated/GeneratedParser/Wok/Layout.hs` — split the `isLayoutOpen || isParenOpen` branch and add `maybeInsertSeparator` on the paren branch (binder `pt`, not `_`).
2. `src-generated/GeneratedParser/Wok/Par.y` — replace the right-recursive `ListRecordFieldPat` with the left-recursive `NEListRecordFieldPat` and update `PRecordOpen`.

Expected: BNFC reports the same conflict count as before the change (check `git diff` of the `.info`/build output if present). If `with` introduces a new conflict, it will be in the `Exp2` state; resolve by confirming `EWith`'s trailing `Exp` mirrors `ELam` (line 357) — both are `Exp2 ::= … Exp`, so the precedence handling is identical and no new conflict should appear.

- [ ] **Step 4: Create the parse test file.**

Create `test/examples/26-with-handler.wok`:

```
module Main
import Std.Base

effect Ask = { ask : U64 }

useAsk : () -> U64 with Ask
useAsk u = Ask.ask + 1

main : U64
main =
  with { Ask.ask -> 41 }
  useAsk ()
```

- [ ] **Step 5: Build and verify parsing.**

Run: `cabal build`
Expected: compiles (the typechecker/elaborator will not yet treat `EWith`; that is Tasks 2–3 — but the generated `Abs.hs` must define `EWith`, `HVArm` and drop `EHandle`/`HReturn`).

Run: `cabal run wok -- test/examples/26-with-handler.wok --dump-anf`
Expected: a parse error is NOT raised. A downstream "unhandled `EWith`" error from Infer/Elaborate IS expected at this point (those are Tasks 2–3). The point of this step is only that the new grammar parses.

- [ ] **Step 6: Commit.**

```bash
git add grammar/Wok.cf src-generated/GeneratedParser/Wok test/examples/26-with-handler.wok
git commit -m "feat(grammar): with-prefix handler, value arm; drop handle/return; free resume"
```

---

### Task 2: Typecheck — route `EWith`, arity-split binder, answer-type-first, resume typing

**Goal:** `with { arms } rest` type-checks: arms with no binder auto-resume (body : op result type); arms binding a continuation `k` have body : answer type `R` with `k : T -> R` under the outer ambient; value arms are the return clause.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs:1652` (route `EWith`), `src/Wok/TypeChecking/Infer.hs:1654-1730` (`inferHandler`)
- Test: `test/typecheck-examples/26-with-handler.wok`, `test/run-examples/16-exn-abort.wok`, `test/run-examples/17-choice-multishot.wok`

**Acceptance Criteria:**
- [ ] `Abs.EWith arms rest` routes to `inferHandler mono rest arms` (the trailing `Exp` is the handled computation).
- [ ] Operation arm with exactly the op's arity in patterns -> auto-resume, body unified with the op's result type, resume name empty (today's behavior).
- [ ] Operation arm with `arity + 1` patterns -> the extra pattern is the continuation binder; body unified with the handler answer type `R`; the binder is bound to `T -> R` in the arm's environment.
- [ ] More than `arity + 1` patterns on an arm -> a clear error (reuse `UnknownOperation` or add an arity error).
- [ ] Value arm (`HVArm`) is the return clause (was `HReturn`); the duplicate-value-arm check is preserved.
- [ ] Answer type `R` is one metavar shared by all binder arms and the value/return arm.

**Verify:** `cabal run wok -- test/run-examples/16-exn-abort.wok --run` -> `0`; `cabal run wok -- test/run-examples/17-choice-multishot.wok --run` -> `30`; `cabal test` typecheck-golden green for `26-with-handler`.

**Steps:**

- [ ] **Step 1: Write failing run tests (abort + multi-shot).**

Create `test/run-examples/16-exn-abort.wok`:

```
module Main
import Std.Base

effect Exn = { throw : String -> a }

risky : Bool -> U64 with Exn
risky b = if b then Exn.throw "boom" else 7

main : U64
main =
  with { Exn.throw msg k -> 0
         ; v -> v }
  risky True
```

Create `test/run-examples/17-choice-multishot.wok`:

```
module Main
import Std.Base

effect Choice = { flip : Bool }

pick : () -> U64 with Choice
pick u = if Choice.flip then 10 else 20

main : U64
main =
  with { Choice.flip k -> k True + k False
         ; v -> v }
  pick ()
```

Create golden files (will be filled by `--accept` after the impl): `test/run-golden/16-exn-abort.expected` containing `0`, and `test/run-golden/17-choice-multishot.expected` containing `30`.

- [ ] **Step 2: Run to confirm they fail.**

Run: `cabal run wok -- test/run-examples/16-exn-abort.wok --run`
Expected: FAIL — `EWith` not handled by Infer (error from the catch-all), confirming the feature is absent.

- [ ] **Step 3: Route `EWith` to `inferHandler`.**

In `src/Wok/TypeChecking/Infer.hs`, immediately after the `Abs.EHandle` line (1652) is removed/replaced, add:

```haskell
inferExprW mono (Abs.EWith arms rest) = inferHandler mono rest arms
```

(`Abs.EHandle` no longer exists after Task 1; delete its clause at line 1652.)

- [ ] **Step 4: Restructure `inferHandler` — allocate `R` first, split args/binder, branch body type.**

Replace the body of `inferHandler` (1655-1730) with this shape. Key changes from the current code are marked:

```haskell
inferHandler mono e arms = do
  env <- currentEnv
  let opArms = [ (en, op, ps, body, pos)
               | Abs.HArm (Abs.ConId (pos, en)) (Abs.VarId (_, op)) ps body <- arms ]
      -- HVArm replaces HReturn: a value arm `v -> body`.
      valArms = [ (pos, v, body)
                | Abs.HVArm (Abs.VarId (pos, v)) body <- arms ]
  case valArms of
    (_ : (pos2, _, _) : _) -> throwError (DuplicateReturnArm (Just pos2))
    _                      -> pure ()

  subAmbient0 <- freshRVar
  subRef <- liftST (newSTRef subAmbient0)
  (exprT, exprNode) <- withEffRow subRef (inferExprW mono e)

  -- CHANGED: allocate the handler answer type R up front so binder arms can
  -- type `resume : T -> R` before the value arm is processed.
  answerT <- freshTVar KStar

  let handledEffects = Data.List.nub [ en | (en, _, _, _, _) <- opArms ]
  -- (coverage check: unchanged from current lines 1674-1687)
  forM_ handledEffects $ \en -> ...   -- keep existing coverage block verbatim

  opArmNodes <- forM opArms $ \(en, op, ps, body, pos) ->
    case lookupEffect en env of
      Nothing -> throwError (MissingEffectDecl (Just pos) en)
      Just eInfo -> case Map.lookup op (eiOps eInfo) of
        Nothing -> throwError (UnknownOperation (Just pos) en op)
        Just opScheme -> do
          paramSubst <- instantiateParamSubst (eiParams eInfo)
          let opTy = substCTypeWith paramSubst (schemeBody opScheme)
              arity = arrowArity opTy            -- NEW helper, see Step 5
          -- CHANGED: split patterns into op args (arity) and optional binder.
          (argPs, binderPs) <- pure (splitAt arity ps)
          patResults <- mapM inferAtomPat argPs
          let pTys  = map (\(t, _, _) -> t) patResults
              binds = concatMap (\(_, b, _) -> b) patResults
              argPatNodes = map (\(_, _, n) -> n) patResults
              mono1 = foldr (\(n, t) m -> Map.insert n t m) mono binds
          mResult <- peelArrowsWithArgUnify opTy pTys
          resultTy <- case mResult of
            Just r  -> pure r
            Nothing -> throwError (UnknownOperation (Just pos) en op)
          case binderPs of
            [] -> do
              -- AUTO-RESUME (today's behavior): body has the op result type.
              (bodyT, bodyNode) <- inferExprW mono1 body
              unify (Just pos) bodyT resultTy
              pure (Ty.TOpArm en op argPatNodes Tx.empty bodyNode)
            [Abs.APVar (Abs.VarId (_, kname))] -> do
              -- CONTROL: bind resume : T -> R; body has the answer type R.
              let resumeTy = arrowT resultTy answerT     -- T -> R  (helper, Step 5)
                  mono2    = Map.insert kname resumeTy mono1
              (bodyT, bodyNode) <- inferExprW mono2 body
              unify (Just pos) bodyT answerT
              pure (Ty.TOpArm en op argPatNodes kname bodyNode)
            _ ->
              -- too many patterns, or a non-variable binder
              throwError (UnknownOperation (Just pos) en op)

  subRow <- liftST (readSTRef subRef)
  residual <- dischargeEffects subRow handledEffects
  emitRow Nothing residual

  case valArms of
    [] -> do
      -- No value arm: identity return, so answer type = handled value type.
      unify Nothing answerT exprT
      pure (answerT, Ty.Texp answerT (Ty.THandle exprNode opArmNodes))
    ((_, v, rb) : _) -> do
      let mono' = Map.insert v exprT mono
      (rT, rNode) <- inferExprW mono' rb
      unify Nothing rT answerT
      let retArm = Ty.TReturnArm (Ty.Tpat exprT (Ty.TPVar v)) rNode
      pure (answerT, Ty.Texp answerT (Ty.THandle exprNode (opArmNodes ++ [retArm])))
```

Note: `resume`'s codomain effect is already the outer ambient because arm bodies are inferred under the outer `mono`/ambient (not `subRef`), exactly as today. No extra row plumbing for `resume` is required.

- [ ] **Step 5: Add the small type helpers.**

In `src/Wok/TypeChecking/Infer.hs` (near other `Type` helpers), add:

```haskell
-- | Count leading arrow arguments of an operation type (its arity).
arrowArity :: Type s -> Int
arrowArity (TFun _ r) = 1 + arrowArity r
arrowArity _          = 0

-- | Build a single-argument function type T -> R.
arrowT :: Type s -> Type s -> Type s
arrowT a b = TFun a b
```

Adjust the `TFun` constructor name/shape to match the actual `Type` definition in `src/Wok/TypeChecking/*` (confirm by reading the `Type` data declaration; if the arrow constructor carries an effect row, build it with a fresh open row via the same helper the codebase uses to construct function types — search for existing `TFun`/arrow construction in `Infer.hs` and mirror it).

- [ ] **Step 6: Build, then run the new tests.**

Run: `cabal build`
Run: `cabal run wok -- test/run-examples/16-exn-abort.wok --run`  -> expected `0`
Run: `cabal run wok -- test/run-examples/17-choice-multishot.wok --run` -> expected `30`

If `17` does not yet produce `30`, the elaboration of the binder arm is not binding the continuation — that is Task 3; proceed there, then re-run.

- [ ] **Step 7: Add typecheck-golden input and accept goldens.**

Create `test/typecheck-examples/26-with-handler.wok` (same content as `test/examples/26-with-handler.wok` from Task 1).

Run: `cabal run wok-tests -- --accept` (regenerates typecheck/anf goldens for the new files)
Then: `cabal test` -> all green.

- [ ] **Step 8: Commit.**

```bash
git add src/Wok/TypeChecking/Infer.hs test/run-examples/16-exn-abort.wok test/run-examples/17-choice-multishot.wok test/run-golden test/typecheck-examples/26-with-handler.wok test/typecheck-golden test/anf-golden test/typed-anf-golden
git commit -m "feat(types): with-prefix handler, auto-resume default, binder takes control"
```

---

### Task 3: Elaborate — bind the continuation when present, auto-wrap when absent

**Goal:** An operation arm that binds a continuation name elaborates its body as-is (no auto-wrap), with the bound name referring to the runtime continuation; an arm with no binder keeps today's `let res = resume(body) in deliver res` wrap.

**Files:**
- Modify: `src/Wok/IR/Elaborate.hs:485-518` (`elabKF (THandle …)` and `elabOpArm`)

**Acceptance Criteria:**
- [ ] `elabKF` routes the `THandle` produced from `EWith` (already the same node — confirm no `EHandle`-specific assumption remains).
- [ ] When `TOpArm`'s resume name is empty: keep the existing auto-wrap (`resume(body)` then deliver).
- [ ] When `TOpArm`'s resume name is non-empty: bind that surface name to the fresh resume binder via `withLocal`, and elaborate the body directly under `tk` (no wrap), since the body already has the answer type.

**Verify:** `cabal run wok -- test/run-examples/17-choice-multishot.wok --run` -> `30`; `cabal run wok -- test/run-examples/16-exn-abort.wok --run` -> `0`; `cabal run wok -- test/run-examples/07-effect-ask.wok --run` -> `42` (auto-resume path still works after migration in Task 5).

**Steps:**

- [ ] **Step 1: Rewrite `elabOpArm` to branch on the resume name.**

Replace `elabOpArm` (`src/Wok/IR/Elaborate.hs:509-518`):

```haskell
    elabOpArm :: TailK -> (Text, Text, [TPat], Text, TExpr) -> Elab OpArm
    elabOpArm tk2 (effect, op, ps, resumeName, body) = do
      (argBinders, extender) <- elabParams ps
      resumeN <- bindFresh (Tx.pack "resume")
      armBody <-
        if Tx.null resumeName
          then
            -- AUTO-RESUME: let res = resume(body) in deliver res  (unchanged)
            extender $ normName body $ \v -> do
              res <- bindFresh (Tx.pack "res")
              pure (Let (Binder res Unrestricted (teType body))
                        (RApp (AVar resumeN) [v])
                        (deliverAtom tk2 (AVar res)))
          else
            -- CONTROL: bind the surface name to the resume binder; elaborate the
            -- body as-is (it already has the answer type R).
            extender $ withLocal resumeName resumeN (elabK tk2 body)
      pure (OpArm effect op argBinders (Binder resumeN Unrestricted (teType body)) armBody)
```

Note the source tuple now carries the resume name. Update the comprehension at `elabKF (THandle …)` (line 487-488) to extract it:

```haskell
  let opArmsSrc  = [ (effect, op, ps, resume, body)
                   | TOpArm effect op ps resume body <- arms ]
```

- [ ] **Step 2: Confirm `withLocal` signature.**

`withLocal` is already used by `elabReturnArm` (`src/Wok/IR/Elaborate.hs:502`: `withLocal v vN (elabK tk2 rb)`), binding a surface `Text` name to a `Name`. Reuse it exactly: `withLocal resumeName resumeN (elabK tk2 body)`.

- [ ] **Step 3: Build and run all three.**

Run: `cabal build`
Run: `cabal run wok -- test/run-examples/17-choice-multishot.wok --run` -> `30`
Run: `cabal run wok -- test/run-examples/16-exn-abort.wok --run` -> `0`

- [ ] **Step 4: Commit.**

```bash
git add src/Wok/IR/Elaborate.hs
git commit -m "feat(ir): bind continuation in binder arms; keep auto-wrap for binder-less arms"
```

---

### Task 4: Value operations end-to-end + runtime confirmation

**Goal:** Confirm an operation declared without an arrow (`ask : U64`) works: referenced as `Ask.ask` (performs the effect, yields the result), and dispatched at runtime with zero arguments.

**Files:**
- Read-only confirm: `src/Wok/Interp/Machine.hs:137-150` (`dispatchOp`), `src/Wok/TypeChecking/Infer.hs:1516-1534` (op reference typing)
- Test: `test/run-examples/18-value-op.wok`

**Acceptance Criteria:**
- [ ] `effect Ask = { ask : U64 }` (no arrow) parses and type-checks.
- [ ] `Ask.ask` used as an expression performs the effect and has type `U64`.
- [ ] A handler arm `Ask.ask -> 41` (zero arg patterns) auto-resumes; `Ask.ask k -> k 41` binds the continuation.
- [ ] `dispatchOp` runs a zero-argument operation without error.

**Verify:** `cabal run wok -- test/run-examples/18-value-op.wok --run` -> `42`.

**Steps:**

- [ ] **Step 1: Write the failing value-op test.**

Create `test/run-examples/18-value-op.wok`:

```
module Main
import Std.Base

effect Ask = { ask : U64 }

useAsk : () -> U64 with Ask
useAsk u = Ask.ask + 1

main : U64
main =
  with { Ask.ask k -> k 41 }
  useAsk ()
```

Create golden `test/run-golden/18-value-op.expected` containing `42`.

- [ ] **Step 2: Run to confirm behavior.**

Run: `cabal run wok -- test/run-examples/18-value-op.wok --run`
Expected after Tasks 1–3: `42`. The op-reference typing at `Infer.hs:1516-1534` already returns `opTy = schemeBody` (here `U64`) and emits the effect, so a value op needs no special typing. `peelArrowsWithArgUnify U64 []` returns `U64`, so `arrowArity = 0` and the binder split puts `k` as the continuation correctly.

- [ ] **Step 3: If `dispatchOp` errors on zero args, fix the arg binding.**

Read `src/Wok/Interp/Machine.hs:137-150`. `dispatchOp` binds `oaArgs oa` to `argVals`; for a value op both lists are empty, which `bindBinders [] []` handles. If a zero-arity perform path is missing (e.g. the operation is only ever produced via application), confirm the elaborator emits a `ROp`/operation node for a bare `EProj` value-op reference. If an error surfaces, the fix is localized to how `TProjCon` with no application lowers — make the elaborator emit the operation perform for a value-op reference, mirroring the applied case. (Expected: no change needed; this step is a guard.)

- [ ] **Step 4: Accept goldens, run suite.**

Run: `cabal run wok-tests -- --accept`
Run: `cabal test` -> green.

- [ ] **Step 5: Commit.**

```bash
git add test/run-examples/18-value-op.wok test/run-golden/18-value-op.expected src/Wok/Interp/Machine.hs src/Wok/IR/Elaborate.hs
git commit -m "feat: value operations (arrow-less ops) end-to-end"
```

(If Machine.hs/Elaborate.hs were not touched, drop them from the `git add`.)

---

### Task 5: Migrate existing handler examples and regenerate goldens

**Goal:** All pre-existing `handle … of … return` examples use the new `with` form; the full golden suite is green.

**Files:**
- Modify: `test/run-examples/07-effect-ask.wok`, `test/typecheck-examples/24-effects-handle.wok`, `test/typecheck-examples/25-effects-di.wok`, `test/examples/20-effects-syntax.wok`, `test/typecheck-fail-examples/17-handler-coverage.wok`, `test/typecheck-fail-examples/18-duplicate-return-arm.wok`
- Regenerate: all affected goldens under `test/*-golden/`

**Acceptance Criteria:**
- [ ] No `.wok` file under `test/` uses `handle`/`return` handler syntax.
- [ ] `07-effect-ask` produces `42` via the new syntax.
- [ ] The coverage-failure and duplicate-value-arm failure examples still fail with the expected diagnostics (rewritten to `with`).
- [ ] `cabal test` is fully green.

**Verify:** `rg -n "\bhandle\b|return " test/**/*.wok` -> no handler matches; `cabal test` -> all green.

**Steps:**

- [ ] **Step 1: Migrate `07-effect-ask.wok`.**

Rewrite `test/run-examples/07-effect-ask.wok` to:

```
module Main
import Std.Base

effect Ask = { ask : U64 }

useAsk : () -> U64 with Ask
useAsk u = Ask.ask + 1

main : U64
main =
  with { Ask.ask -> 41 }
  useAsk ()
```

(Golden `test/run-golden/07-effect-ask.expected` already contains `42`; no change.)

- [ ] **Step 2: Migrate the typecheck examples.**

`test/typecheck-examples/24-effects-handle.wok` — rewrite both handlers, e.g. `runIO`:

```
runIO : (() -> a with IO + eff e) -> a with eff e
runIO comp =
  with { IO.read p  -> p
       ; IO.write m -> () }
  comp ()
```

and `runIO2` likewise (no value arm). Apply the same transform to `25-effects-di.wok` (`logToIO`, `runIO`) and `20-effects-syntax.wok` (`handleDemo`): replace `handle (e) of { arms ; return v -> v }` with `with { arms ; v -> v } e`, dropping `return`.

- [ ] **Step 3: Migrate the failure examples.**

`test/typecheck-fail-examples/17-handler-coverage.wok` — rewrite to `with`, keeping it missing an operation arm so `HandlerCoverage` still fires.

`test/typecheck-fail-examples/18-duplicate-return-arm.wok` — rewrite with two value arms (`v -> v ; w -> w`) so `DuplicateReturnArm` still fires under the new `HVArm` split.

- [ ] **Step 4: Regenerate every affected golden.**

Run: `cabal run wok-tests -- --accept`

Then inspect the diffs of `test/typecheck-fail-golden/17-*.expected` and `18-*.expected` to confirm the SAME error class is reported (coverage / duplicate return). If a golden now shows a different (wrong) error, the migration changed semantics — fix the `.wok` so the intended error reproduces.

- [ ] **Step 5: Confirm no stale syntax and full green.**

Run: `rg -n "\bhandle\b" test` and `rg -n "return " test/**/*.wok` -> no handler-syntax matches.
Run: `cabal test` -> all green.

- [ ] **Step 6: Commit.**

```bash
git add test
git commit -m "test: migrate handler examples to with-prefix; regenerate goldens"
```

---

## Self-review notes

- **Spec coverage:** value ops (Task 4) = surface §1; `with`-prefix + scope-as-trailing-Exp (Task 1) = §4; auto-resume default / binder control (Tasks 2–3) = §5; value arm optional/identity (Task 2 Step 4 `[] -> unify answerT exprT`) = §6. The effect header (§4.3) and the lint (§8) are slice 2, intentionally out of scope. Bounded `(with H; e)`, parameterized handlers, scheduler are deferred per the roadmap.
- **`resume` typing:** `resume : T -> R`; its codomain effect is the outer ambient because binder-arm bodies are inferred under the outer `mono`/ambient, matching the surface spec's "outer effect row" requirement (§2 of the predecessor / `docs/koka.md`).
- **Arity-split risk:** the binder is the `(arity+1)`-th pattern; `arrowArity` on the op's (param-substituted) type gives the split point. For value ops arity is 0, so a single trailing pattern is the binder — exactly what `18-value-op.wok` exercises.
- **Type-helper caveat (Task 2 Step 5):** the exact arrow constructor (`TFun` arity/effect-row shape) must be confirmed against the real `Type` definition; mirror existing function-type construction in `Infer.hs`.
- **No placeholders:** every code step shows the code; the one guarded "expected no change" step (Task 4 Step 3) states the concrete fix if the guard trips.

## Cross-cutting deferred (NOT in this slice)

Forgotten-resume lint + `discard`, effect header, bounded `(with H; e)`, parameterized handlers, one-shot multiplicity check, scheduler/Future. See the roadmap.
