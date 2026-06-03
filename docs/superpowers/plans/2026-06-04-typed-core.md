# Typed Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Carry inferred types from the type checker into the IR — inference emits a `CType`-annotated typed AST, elaboration consumes it, and ANF binders carry types — with zero change to runtime behavior.

**Architecture:** A new parameterized typed-AST functor (annotation = `Type s` during inference, `CType` after freezing) is built by `inferExprW`/`inferAtomPat` in lockstep with the existing type computation. The whole tree for a top-level binding is frozen ONCE, at that binding's `generalize`, sharing the same `freezeQuantify` mapping the scheme uses. Elaboration is retargeted from `Abs.Exp` to the frozen typed AST and stamps each `Binder` it mints with the node's type.

**Tech Stack:** Haskell (GHC 9.10, `Strict`/`StrictData`), `mtl`, `ST` for inference cells, `tasty`/golden tests, BNFC `Abs`. Reuses `Wok.TypeChecking.Types.CType` directly in the IR.

**Spec:** `docs/superpowers/specs/2026-06-04-typed-core-design.md`

---

## Design refinement vs. the spec (read once)

The spec says node types freeze "reusing the same `freezeQuantify` mapping the scheme uses." Implementation detail discovered while planning: `freezeQuantify` (`Infer.hs:64`) **errors on any var at level <= outer** (it assumes every var it sees is generalizable). A node inside a nested `let` can reference a variable that is monomorphic relative to that inner let. Therefore:

- **Freeze the entire typed tree of a top-level binding ONCE, at the TOP-LEVEL `generalize`** (outer = the top level, e.g. `Level 0`). There is no enclosing scope above a top-level binding, so every variable in its tree is either concrete or at level > outer (generalizable) — no level-`<=`-outer var can appear, and the error case cannot fire.
- Inner `let`-groups still generalize their own schemes exactly as today (unchanged); they do NOT freeze nodes. The node freeze for the whole tree is deferred to the top.
- The resulting per-node `CTGen` numbering is globally consistent **within the binding's tree**. It need not match an inner let-binding's separately-stored scheme numbering — the IR is trusted and never re-checked (no Lint), so intra-tree consistency is all that is required.

This is the single subtle correctness point; Task 1 implements it and Task 7's golden over a `let`-polymorphic fixture guards it.

---

## File structure

- `src/Wok/TypeChecking/Typed.hs` — NEW. The parameterized typed AST (`Texp a`, `Tpat a`), its `Abs.Exp`-mirroring node functor, and the frozen aliases `TExprS s`/`TExpr`, `TPatS s`/`TPat`. One responsibility: the typed tree shape.
- `src/Wok/TypeChecking/Infer.hs` — MODIFY. `inferExprW`/`inferExprWChecked`/`inferAtomPat`/`inferPat` build typed nodes; `generalizeTyped` + `zonkTexp` freeze a tree; `typeEquationWith`/`inferLetGroup`/`finalizeGroup`/`inferProgramTC` thread and freeze typed bodies; `TypedDecl` gains typed params/where/body.
- `src/Wok/TypeChecking/Unify.hs` — MODIFY (small). Export a node-level freeze helper if needed (reuse `freeze`/`freezeQuantify`).
- `src/Wok/IR/Anf.hs` — MODIFY. `Binder` gains `bndType :: CType`; pretty-printer gains a typed rendering.
- `src/Wok/IR/Elaborate.hs` — MODIFY. Retarget every walker from `Abs.Exp`/`Abs` to `TExpr`/typed decls; stamp binder types.
- `src/Wok/Pipeline.hs` — MODIFY. Carry typed decls through; `elaborateProgram`/`elaborateProgramFull` consume them.
- `app/Main.hs` — MODIFY (small). `--dump-anf` renders typed ANF; optional `--dump-typed-ast`.
- `test/Spec.hs` — MODIFY. New unit groups (`TypedAst`, `Zonk`) and a `typed-anf golden` group; existing goldens must stay green.
- `test/typed-anf-golden/*.expected` — NEW goldens.

---

## Task 0: Typed AST datatype module

**Goal:** A parameterized typed AST that mirrors the elaboration-reachable `Abs.Exp`/pattern forms, with annotation = `Type s` (during inference) or `CType` (frozen).

**Files:**
- Create: `src/Wok/TypeChecking/Typed.hs`
- Modify: `wok.cabal` (add `Wok.TypeChecking.Typed` to `exposed-modules`)
- Test: `test/Spec.hs` (group `TypedAst`)

**Acceptance Criteria:**
- [ ] `Texp a`/`Tpat a` are `Functor`/`Foldable`/`Traversable` (so freezing is a `traverse`).
- [ ] The node functor has exactly one constructor per elaboration-reachable `Abs.Exp` form (enumerated below) and per name-binding pattern form.
- [ ] `TExprS s = Texp (Type s)`, `TExpr = Texp CType`, `TPatS s = Tpat (Type s)`, `TPat = Tpat CType` aliases exist.
- [ ] `cabal build` succeeds; `TypedAst` test passes.

**Verify:** `cabal test --test-options='-p TypedAst'` → pass.

**Steps:**

- [ ] **Step 1: Write the module.** Annotation rides on every node and pattern; children are themselves annotated nodes, so a single `traverse` freezes the whole tree.

```haskell
{-# LANGUAGE DeriveTraversable #-}
module Wok.TypeChecking.Typed
  ( Texp (..), TexpF (..)
  , Tpat (..), TpatF (..)
  , TAlt (..), THandlerArm (..), TLocalDecl (..)
  , TExprS, TExpr, TPatS, TPat
  ) where

import Data.Text (Text)
import qualified GeneratedParser.Wok.Abs as Abs
import Wok.TypeChecking.Types (Type, CType)

-- | An annotated expression node: its type annotation @a@ plus the node.
data Texp a = Texp a (TexpF a)
  deriving (Functor, Foldable, Traversable)

-- | One constructor per elaboration-reachable Abs.Exp form. Children are
-- themselves Texp, so the annotation covers every subexpression.
data TexpF a
  = TLitI Integer
  | TLitS Text
  | TLitC Char
  | TUnit
  | TVar Text                       -- resolved at elaboration via Env/scope
  | TCon Text                       -- nullary or head of a saturated app
  | TApp (Texp a) [Texp a]          -- spine head + args (collected)
  | TLam [Tpat a] (Texp a)
  | TIf (Texp a) (Texp a) (Texp a)
  | TTuple [Texp a]
  | TList [Texp a]
  | TParenOp Text                   -- (==) used as a value
  | TProj (Texp a) Text             -- record field projection
  | TProjCon Text Text              -- E.op effect projection (label, op)
  | TRecord Text [(Text, Texp a)]
  | TRecordExt Text (Texp a) [(Text, Texp a)]
  | TLet [TLocalDecl a] (Texp a)
  | TCase (Texp a) [TAlt a]
  | THandle (Texp a) [THandlerArm a]
  deriving (Functor, Foldable, Traversable)

data TAlt a = TAlt (Tpat a) [TLocalDecl a] (Texp a)   -- pattern, where, body
  deriving (Functor, Foldable, Traversable)

data THandlerArm a
  = TReturnArm (Tpat a) (Texp a)
  | TOpArm Text Text [Tpat a] Text (Texp a)   -- effect, op, args, resume-name, body
  deriving (Functor, Foldable, Traversable)

-- | A local binding (let / where entry): name, params, body. (Sigs carry no
-- runtime content and are dropped during typed-AST construction.)
data TLocalDecl a = TLocalDecl Text [Tpat a] (Texp a)
  deriving (Functor, Foldable, Traversable)

data Tpat a = Tpat a (TpatF a)
  deriving (Functor, Foldable, Traversable)

data TpatF a
  = TPVar Text
  | TPWild
  | TPLitI Integer
  | TPLitS Text
  | TPLitC Char
  | TPUnit
  | TPTuple [Tpat a]
  | TPList [Tpat a]
  | TPCon Text [Tpat a]      -- constructor applied to sub-patterns
  | TPCons (Tpat a) (Tpat a) -- h :: t
  deriving (Functor, Foldable, Traversable)

type TExprS s = Texp (Type s)
type TExpr    = Texp CType
type TPatS  s = Tpat (Type s)
type TPat     = Tpat CType
```

- [ ] **Step 2: Register in `wok.cabal`.** Add `Wok.TypeChecking.Typed` to the library `exposed-modules` (alongside `Wok.TypeChecking.Types`).

- [ ] **Step 3: Write the `TypedAst` test** (constructs a node and checks `fmap`/`traverse` reach the annotation).

```haskell
testGroup "TypedAst"
  [ testCase "fmap rewrites every annotation" $
      let e = Texp (1 :: Int) (TApp (Texp 2 (TVar (Tx.pack "f")))
                                    [Texp 3 (TLitI 0)])
          e' = fmap (* 10) e
      in sum e' @?= 60   -- Foldable sum over annotations: 10+20+30
  ]
```

- [ ] **Step 4: Build + commit.**

```bash
cabal test --test-options='-p TypedAst'
git add src/Wok/TypeChecking/Typed.hs wok.cabal test/Spec.hs
git commit -m "feat(types): parameterized typed-AST datatype (Texp/Tpat)"
```

---

## Task 1: `generalizeTyped` + whole-tree zonk

**Goal:** Freeze a `TExprS s` tree to `TExpr` using the SAME `freezeQuantify` mapping that produces the binding's scheme, in one pass at the top-level outer level.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs`
- Test: `test/Spec.hs` (group `Zonk`)

**Acceptance Criteria:**
- [ ] `generalizeTyped :: Type s -> TExprS s -> TC s (Scheme, TExpr)` returns the scheme AND the frozen tree, sharing one `nextRef`/`seenRef`/`kindsRef` set.
- [ ] A polymorphic body's node annotations use the SAME `CTGen` indices as the scheme (e.g. `id`'s body `TVar x` annotation equals the scheme's domain `CTGen`).
- [ ] A monomorphic body's nodes freeze to concrete `CType` (e.g. arithmetic nodes are `CTCon TcU64 []`).
- [ ] `Zonk` test passes.

**Verify:** `cabal test --test-options='-p Zonk'` → pass.

**Steps:**

- [ ] **Step 1: Add `generalizeTyped` alongside the existing `generalize`** (leave `generalize` untouched — it stays the no-tree path). The new function creates one ref-set and freezes the principal type AND every node annotation with it. Because node freezing can discover quantifiers the principal type did not mention (e.g. a quantifier used only inside a subexpression), the scheme's `schemeVars` must be read from `kindsRef` AFTER the tree is frozen, not before:

```haskell
generalizeTyped :: Type s -> TExprS s -> TC s (Scheme, TExpr)
generalizeTyped t tree = do
  Level outer <- currentLevel
  liftST $ do
    nextRef  <- newSTRef 0
    seenRef  <- newSTRef (Map.empty :: Map.Map Int Int)
    kindsRef <- newSTRef ([] :: [(Int, Kind)])
    let goT = freezeQuantify outer nextRef seenRef kindsRef
    body   <- goT t                       -- principal type first
    tree'  <- traverse goT tree           -- then every node annotation
    pairs  <- readSTRef kindsRef          -- read quantifiers AFTER both
    pure (Scheme (reverse pairs) body, tree')
```

- [ ] **Step 2: Write the `Zonk` test.** Build a tiny `id`-like tree by hand using a fresh TVar at level > outer, plus a monomorphic `U64` node, and assert the frozen annotations.

```haskell
testGroup "Zonk"
  [ testCase "polymorphic body node shares the scheme's CTGen" $
      let r = runTC_ B.initialEnv $ enterLevel $ do
                a <- freshTVar KStar                       -- the 'a' of id
                let fnTy = TArr a RowEmpty a
                    tree = Texp a (TVar (Tx.pack "x"))      -- body: x : a
                (sch, tree') <- generalizeTyped fnTy tree
                let Texp ann _ = tree'
                pure (schemeBody sch, ann)
      in case r of
           Right (CTArr d _ _, ann) -> ann @?= d   -- node type == domain
           other -> assertFailure (show other)
  , testCase "monomorphic node freezes to concrete CType" $
      let r = runTC_ B.initialEnv $ enterLevel $ do
                let tree = Texp (TCon TcU64 []) (TLitI 1)
                (_, Texp ann _) <- generalizeTyped (TCon TcU64 []) tree
                pure ann
      in r @?= Right (CTCon TcU64 [])
  ]
```

- [ ] **Step 3: Run + commit.**

```bash
cabal test --test-options='-p Zonk'
git add src/Wok/TypeChecking/Infer.hs test/Spec.hs
git commit -m "feat(types): generalizeTyped freezes a typed tree with the scheme's mapping"
```

---

## Task 2: `inferExprW`/patterns build typed nodes

**Goal:** Every expression and pattern inference case returns its typed node alongside the `Type s` it already computes.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs`
- Test: `test/Spec.hs` (group `InferTyped`)

**Acceptance Criteria:**
- [ ] `inferExprW :: Map Text (Type s) -> Abs.Exp -> TC s (Type s, TExprS s)` and `inferExprWChecked` likewise; every existing case is converted.
- [ ] `inferAtomPat`/`inferPat` return their `TPatS s` alongside `(Type s, binds)`.
- [ ] The node's annotation is exactly the `Type s` the case returns (no separate computation).
- [ ] All cases in the enumeration below are covered; build is warning-clean on incomplete patterns.

**Verify:** builds; `cabal test --test-options='-p InferTyped'` → pass.

**The transformation pattern.** Each case currently ends by returning a `Type s`. Convert it to return `(ty, Texp ty node)` where `node` is built from the typed children. Recursive calls now yield `(_, child)`; thread the children into the node. The TYPE logic is unchanged — only the node is added. Worked examples:

```haskell
-- Literals: type unchanged, node is the literal.
inferExprW _ (Abs.ELitI (Abs.WokInt (_, t))) =
  let ty = TCon TcU64 [] in pure (ty, Texp ty (TLitI (readInt t)))
inferExprW _ Abs.EUnit =
  let ty = TCon TcUnit [] in pure (ty, Texp ty TUnit)

-- Variable: same lookup/instantiation; node is TVar name.
inferExprW mono (Abs.EVar (Abs.VarId (pos, name))) = do
  ty <- ...existing lookup+instantiate...        -- UNCHANGED
  pure (ty, Texp ty (TVar name))

-- Application: collect the spine (existing helper), infer head + args,
-- thread typed children. Type logic UNCHANGED.
inferExprW mono (Abs.EApp f x) = do
  (headE, argEs)        <- ...collectSpine...      -- existing
  (headTy, headT)       <- inferExprW mono headE
  (argTys, argTs)       <- unzip <$> mapM (inferExprW mono) argEs
  resTy                 <- ...existing unify of headTy against argTys...
  let node = case headE of
        Abs.ECon (Abs.ConId (_, c)) -> TApp (Texp headTy (TCon c)) argTs
        _                           -> TApp headT argTs
  pure (resTy, Texp resTy node)

-- If: UNCHANGED unification; node TIf.
inferExprW mono (Abs.EIf c a b) = do
  (_, cT) <- inferExprW mono c            -- still unified to Bool as before
  (ta, aT) <- inferExprW mono a
  (tb, bT) <- inferExprW mono b
  ...existing unify ta tb -> resTy...
  pure (resTy, Texp resTy (TIf cT aT bT))
```

Pattern example:

```haskell
inferAtomPat (Abs.APVar (Abs.VarId (_, x))) = do
  tv <- freshTVar KStar
  pure (tv, [(x, tv)], Tpat tv (TPVar x))
inferAtomPat (Abs.APLitI _) =
  let ty = TCon TcU64 [] in pure (ty, [], Tpat ty (TPLitI 0))  -- value unused downstream
```

**Steps:**

- [ ] **Step 1: Change the signatures** of `inferExprW`, `inferExprWChecked`, `inferAtomPat`, `inferPat` (and any local `where`-helpers that return a body type, e.g. branch/alt helpers) to also return the typed node. Let the compiler's non-exhaustive/`unused` errors drive the conversion.

- [ ] **Step 2: Convert every `inferExprW` / `inferExprWChecked` case.** Exhaustive list (from `Infer.hs:1150-1390` and `962-1105`): `ELitI`, `ELitS`, `ELitC`, `EUnit`, `EVar`, `ECon`, `EParen` (unwrap; reuse child node, keep child type), `EParenOp`, `EApp`, `EIf`, `ETuple`, `EList` (empty + cons), `ELam`, `EExpr` (operator chain — build `TApp` of the resolved operator over the folded args), `EProj` (effect-op head → `TProjCon`; else `TProj`), `EProjC`, `ERecord`, `ERecordExt`, `ELet` (→ `TLet` with `TLocalDecl`s from the group), `ECase` (→ `TCase` with `TAlt`s), `EHandle` (→ `THandle` with `THandlerArm`s). For `EParen`, return `(childTy, childNode)` directly (no wrapper node) so the printed tree is not cluttered.

- [ ] **Step 3: Convert `inferAtomPat`/`inferPat`** for every form: `APVar`, `APWild`, `APLitI`, `APLitS`, `APLitC`, `PUnit`, `APTuple`, `APList`, `APParen`, `PApp` (constructor + sub-pats → `TPCon`), `PCons` (→ `TPCons`), `APCon` (nullary → `TPCon c []`).

- [ ] **Step 4: Write `InferTyped` tests** asserting node shape + annotation for representative inputs (run through `runTC_`/`inferExprW` with an empty mono map).

```haskell
testGroup "InferTyped"
  [ testCase "literal node carries U64" $
      case runTC_ B.initialEnv (inferExprW Map.empty (Abs.ELitI (Abs.WokInt ((0,0), Tx.pack "1")))) of
        Right (_, Texp ann (TLitI 1)) -> ann @?= TCon TcU64 [] `seqTypeEq` ()   -- compare via force/freeze helper
        other -> assertFailure (show other)
  , testCase "application builds a TApp spine" $
      ... assert TApp head [arg] shape ...
  ]
```

  (Comparing `Type s` directly is awkward; assert on the *node shape* and, where a concrete type is expected, freeze the annotation with a small `freeze`-based helper before `@?=`.)

- [ ] **Step 5: Run + commit.**

```bash
cabal test --test-options='-p InferTyped'
git commit -am "feat(types): inferExprW and pattern inference build typed nodes"
```

---

## Task 3: Thread + freeze typed bodies; extend `TypedDecl`

**Goal:** Carry each equation's typed body up to its top-level `generalize`, freeze the whole tree there, and surface it on `TypedDecl`.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs`
- Test: `test/Spec.hs` (group `TypedDeclBody`)

**Acceptance Criteria:**
- [ ] `TypedDecl` gains `tdParams :: [TPat]`, `tdWhere :: [TLocalDecl CType]` (frozen), and `tdBody :: TExpr`.
- [ ] `typeEquationWith` returns the typed body (and typed params/where) alongside the `Type s`.
- [ ] `finalizeGroup` (top-level) freezes params+where+body together with `generalizeTyped`'s shared mapping; inner `inferLetGroup` does NOT freeze nodes.
- [ ] `inferProgramTC`/`inferProgramWith` populate the new `TypedDecl` fields; signature stays `Either TypeError (Env, [TypedDecl], [Warning])`.
- [ ] `TypedDeclBody` test passes.

**Verify:** `cabal test --test-options='-p TypedDeclBody'` → pass.

**Steps:**

- [ ] **Step 1: Extend `TypedDecl`.**

```haskell
data TypedDecl = TypedDecl
  { tdName   :: Text
  , tdScheme :: Scheme
  , tdParams :: [TPat]              -- frozen
  , tdWhere  :: [TLocalDecl CType]  -- frozen
  , tdBody   :: TExpr               -- frozen
  } deriving (Show)
```

  Drop the `Eq` derive if `TExpr` is not `Eq` (it is not, since `CType` is `Eq` but the functor derive may need it — add `deriving (Eq, Show)` on `Texp`/`Tpat` if cheap; otherwise compare via a projection in tests).

- [ ] **Step 2: Thread the unfrozen tree out of `typeEquationWith`.** It currently returns `Type s`; change to return `(Type s, [TPatS s], [TLocalDecl (Type s)], TExprS s)` — the function/body type plus the unfrozen typed params, where-decls, and body. The pattern results from `inferAtomPat` already give `TPatS s`; the `withWhere`/`inferLetGroup` path yields the where `TLocalDecl`s; the body inference yields `TExprS s`.

- [ ] **Step 3: Freeze at the TOP-LEVEL `finalizeGroup` only.** In `finalizeGroup` (`Infer.hs:1807`), the generalize branch becomes:

```haskell
-- was: gen <- generalize tv
(gen, bodyT) <- generalizeTyped tv bodyTreeS         -- bodyTreeS threaded in
-- params/where freeze with the SAME mapping: fold them into one tree, or
-- run generalizeTyped once over a synthetic node wrapping (params, where, body).
```

  To freeze params/where/body with ONE shared mapping, wrap them as children of a throwaway top node and freeze that, then unwrap. Concretely, build `Texp tv (TLet whereS (TLam paramsS bodyS))` as the synthetic tree, run `generalizeTyped tv synthetic`, then destructure the frozen `Texp _ (TLet where' (TLam params' body'))`. This guarantees identical `CTGen` numbering across params, where, and body. Inner `inferLetGroup`/`finalizeGroup` (non-top) keep returning `Type s` trees unfrozen.

- [ ] **Step 4: Populate `TypedDecl` in `inferProgramTC`** (`Infer.hs:2000+`) from the frozen pieces returned by the top-level `finalizeGroup`.

- [ ] **Step 5: Write `TypedDeclBody` test** — infer a tiny module and assert `tdBody`'s root node shape and a frozen annotation.

```haskell
testGroup "TypedDeclBody"
  [ testCase "id's body node type equals its scheme domain" $ do
      -- module: id x = x   (no sig)
      ... build Abs.Module, run inferProgramWith ...
      -- assert: tdScheme is forall a. a -> a, and tdBody root annotation == domain CTGen
  ]
```

- [ ] **Step 6: Run + commit.**

```bash
cabal test --test-options='-p TypedDeclBody'
git commit -am "feat(types): thread and freeze typed equation bodies onto TypedDecl"
```

---

## Task 4: `Binder` carries a type + typed pretty-print

**Goal:** `Anf.Binder` gains `bndType :: CType`; the printer can render types; `Anf` unit tests updated.

**Files:**
- Modify: `src/Wok/IR/Anf.hs`
- Test: `test/Spec.hs` (group `Anf`)

**Acceptance Criteria:**
- [ ] `data Binder = Binder { bndName :: Name, bndMult :: Mult, bndType :: CType }`.
- [ ] A new `prettyModuleTyped :: CoreModule -> Text` renders binders as `name : type`; existing `prettyModule` stays erased (unchanged output).
- [ ] `Anf` unit tests construct `Binder` with the new field and pass.

**Verify:** `cabal test --test-options='-p Anf'` → pass.

**Steps:**

- [ ] **Step 1: Add the field** and import `CType`/`prettyCType`:

```haskell
import Wok.TypeChecking.Types (CType)
import Wok.TypeChecking.Infer (prettyCType)   -- already exported (Infer.hs:18)

data Binder = Binder { bndName :: Name, bndMult :: Mult, bndType :: CType }
  deriving (Eq, Show)
```

- [ ] **Step 2: Add the typed renderer.** Mirror `prettyModule`/`prettyExpr` but render each binder as `nameHint b <> " : " <> prettyCType (bndType b)`. Keep `prettyModule` byte-for-byte as is (erased). Factor the shared structure behind a `Bool` (render types?) or a small printer record so the two share code (DRY).

- [ ] **Step 3: Update the existing `Anf` test** to construct `Binder name Unrestricted (CTCon TcU64 [])` and add one assertion on `prettyModuleTyped`.

- [ ] **Step 4: Run + commit.**

```bash
cabal test --test-options='-p Anf'
git commit -am "feat(ir): Binder carries a CType; add typed ANF pretty-printer"
```

---

## Task 5: Elaboration consumes the typed AST

**Goal:** Retarget elaboration from `Abs.Exp`/`Abs.Module` to `TExpr`/`[TypedDecl]`; stamp every minted `Binder` with the node's type.

**Files:**
- Modify: `src/Wok/IR/Elaborate.hs`
- Test: `test/Spec.hs` (groups `ElaborateBasic`/`ElaborateControl`/`ElaborateRecords`/`ElaborateEffects`/`ElaborateModule` — update fixtures to typed input)

**Acceptance Criteria:**
- [ ] `elabRhs`/`elabK`/`elabTail`/`resolveVar`-callers walk `TExpr`/`TPat`/`TLocalDecl`/`TAlt`/`THandlerArm` instead of `Abs.*`.
- [ ] `elaborateModule`/`elaborateModulesShared` take typed decls: `elaborateModule :: Env -> [TypedDecl] -> CoreModule`, `elaborateModulesShared :: [(Env, [TypedDecl])] -> CoreModule`.
- [ ] Every `Binder` is built with `bndType` taken from the corresponding `Texp`/`Tpat` annotation (params, lets, case fields, lambda params, and the fresh ANF temporaries — a temp naming a subexpression gets that subexpression's `teType`).
- [ ] `elaborateExprForTest :: Env -> TExpr -> Expr` (test seam updated).
- [ ] All elaboration unit groups pass.

**Verify:** `cabal test --test-options='-p Elaborate'` → all elaboration groups pass.

**The transformation pattern.** Where elaboration matched `Abs.ELitI`, it now matches `Texp ty (TLitI n)` and `ty` is in scope for any binder it mints. The ANF normalizer's `normName` mints a fresh temp for a non-atomic RHS — give that temp `bndType = ty` of the node being named:

```haskell
-- before: normName :: Abs.Exp -> (Atom -> Elab Expr) -> Elab Expr
normName :: TExpr -> (Atom -> Elab Expr) -> Elab Expr
normName e@(Texp ty _) k = elabRhs e $ \rhs -> case rhs of
  RAtom a -> k a
  _       -> do n <- bindFresh (Tx.pack "t")
                Let (Binder n Unrestricted ty) rhs <$> k (AVar n)

-- a binder from a typed pattern:
binderOfPat :: Tpat CType -> Name -> Binder
binderOfPat (Tpat ty _) n = Binder n Unrestricted ty
```

**Steps:**

- [ ] **Step 1: Update `ElabCtx` imports** to use `Wok.TypeChecking.Typed`; remove the `Abs` import where no longer needed (effect/record forms now arrive as `TProjCon`/`TRecord` nodes, so the `Env` lookups for arity/fields/effect-ops stay, but constructor/effect *detection* is already encoded in the node, simplifying several cases).

- [ ] **Step 2: Convert `elabRhs`/`elabK`/`elabTail`** case-by-case over `TexpF`, matching the same constructor set as Task 0. Mint every `Binder`/`Alt` field/`RLam` param/`LetJoin` param with the node-or-pattern type. The join-point result binder (`viaJoin`) gets the compound's `teType`.

- [ ] **Step 3: Convert pattern compilation** to walk `Tpat`, binding constructor fields to `Binder`s typed from the sub-pattern annotations.

- [ ] **Step 4: Convert `elaborateModule`/`elaborateModulesShared`/`elabTopBind`** to take `[TypedDecl]`: top-level param binders come from `tdParams`, the where-decls from `tdWhere`, the body from `tdBody`; `globals` is still minted from `envVars`.

- [ ] **Step 5: Update every elaboration unit test** to feed typed input. Add a tiny test helper that runs `inferExprW` (now typed) + freezes via `generalizeTyped` to produce a `TExpr` from a source `Abs.Exp`, so tests can stay expression-oriented:

```haskell
typedExprForTest :: Env -> Abs.Exp -> TExpr
typedExprForTest env e = case runTC_ env (enterLevel $ do
    (ty, tree) <- inferExprW Map.empty e
    snd <$> generalizeTyped ty tree) of
  Right t -> t
  Left err -> error (show err)
```

- [ ] **Step 6: Run + commit.**

```bash
cabal test --test-options='-p Elaborate'
git commit -am "feat(ir): elaborate from the typed AST; binders carry types"
```

---

## Task 6: Pipeline wiring + dump path

**Goal:** Pass typed decls from typecheck to elaboration through the pipeline; render typed ANF.

**Files:**
- Modify: `src/Wok/Pipeline.hs`, `app/Main.hs`
- Test: `test/Spec.hs` (existing pipeline/interp groups must stay green)

**Acceptance Criteria:**
- [ ] `runPipelineFold`'s per-module `ModResult` carries `[TypedDecl]` (it already runs inference, which now returns them).
- [ ] `elaborateProgram`/`elaborateProgramFull` build `CoreModule` from typed decls (calling the new `elaborateModule`/`elaborateModulesShared` signatures).
- [ ] `wok --dump-anf` prints typed ANF (`prettyModuleTyped`); `--run` behavior unchanged.
- [ ] `InterpEntry`/`InterpWholeProgram`/`run golden`/`anf golden` groups stay green.

**Verify:** `cabal test` → all green; `cabal run wok -- --run test/run-examples/01-arith.wok` prints `5`.

**Steps:**

- [ ] **Step 1: Carry typed decls in `ModResult`.** Add a field `mrTyped :: [TypedDecl]` populated from `inferProgramWith`'s result (already computed; just retain it).

- [ ] **Step 2: Rewrite `elaborateProgram`/`elaborateProgramFull`** to gather `(mrEnvOut, mrTyped)` per module and call `elaborateModule`/`elaborateModulesShared` with typed decls instead of `mrAst`.

- [ ] **Step 3: `--dump-anf` uses `prettyModuleTyped`** (`app/Main.hs:56-58`). Leave `--run` on the same elaboration path (now typed under the hood).

- [ ] **Step 4: Run full suite + commit.**

```bash
cabal test
git commit -am "feat(pipeline): elaborate from typed decls; --dump-anf shows types"
```

---

## Task 7: Typed golden corpus + regression guard

**Goal:** Pin the typed ANF for the success corpus; confirm the whole refactor is behavior-preserving.

**Files:**
- Modify: `test/Spec.hs` (group `typed-anf golden`)
- Create: `test/typed-anf-golden/*.expected`

**Acceptance Criteria:**
- [ ] A `typed-anf golden` group runs each `test/typecheck-examples/*.wok` through typecheck → elaborate → `prettyModuleTyped` and compares to `test/typed-anf-golden/<name>.expected`.
- [ ] Goldens manually inspected: `id`/`const` show shared `CTGen` params; arithmetic binders are `U64`; list/`Option` binders carry constructed types; a `let`-polymorphic fixture's inner binder types are internally consistent (the Design-refinement guard).
- [ ] The existing `anf golden` (erased) and all `run golden` outputs are UNCHANGED — the behavior-preservation proof.

**Verify:** `cabal test` → all pass (including unchanged erased + run goldens).

**Steps:**

- [ ] **Step 1: Add the `typed-anf golden` harness** mirroring the existing `anf golden` group but calling `prettyModuleTyped`.

- [ ] **Step 2: Generate goldens, inspect by hand, then re-run clean.**

```bash
cabal test --test-options="-p 'typed-anf golden' --accept"
cabal test --test-options="-p 'typed-anf golden'"   # second run clean
```

- [ ] **Step 3: Confirm erased + run goldens are untouched** (no `--accept` needed for them; they must already pass). If any erased/run golden changed, STOP — behavior was not preserved; investigate before committing.

- [ ] **Step 4: Commit.**

```bash
git add test/Spec.hs test/typed-anf-golden/
git commit -m "test(types): typed ANF golden corpus; behavior-preservation guard"
```

---

## Self-review checklist (run after implementation)

1. **Coverage:** every `Abs.Exp`/pattern constructor reachable from a typechecked program has a `TexpF`/`TpatF` node, an `inferExprW`/`inferAtomPat` case that builds it, and an elaboration case that consumes it. List any missing.
2. **Zonk soundness:** the whole top-level binding tree is frozen ONCE at top-level `generalize`; no inner `inferLetGroup` freezes nodes; `freezeQuantify`'s level-`<=`-outer error never fires (verified by the full suite + the let-polymorphic golden).
3. **Behavior preservation:** erased `anf golden` and `run golden` outputs are byte-identical to before this plan.
4. **Type-name consistency:** `generalizeTyped`, `Texp`/`Tpat`, `TExpr`/`TPat`, `tdBody`/`tdParams`/`tdWhere`, `bndType`, `prettyModuleTyped` are spelled identically across all tasks.
