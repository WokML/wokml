# ANF Elaboration Implementation Plan (Scope B)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lower a typechecked `Abs.Module` into a desugared, scope-resolved ANF intermediate representation, dumpable and golden-tested, ready for an interpreter (Scope C).

**Architecture:** A new type-erased `Wok.IR.*` namespace. `Wok.IR.Name` provides opaque `Unique` identity (`Name` = hint + unique; distinct `JoinId`) minted from a deterministic pure counter. `Wok.IR.Anf` is the ANF datatype (atoms / value-RHS / control-Expr enforce ANF by construction) plus a pretty-printer for goldens. `Wok.IR.Elaborate` walks the surface AST with `Env`-driven name resolution and continuation-passing ANF normalization, desugaring records (label-keyed), effects (name-dispatched), `where`/sections/operator-chains, and patterns. Inference (`Wok.TypeChecking.Infer`) is **not modified** — elaboration runs after `inferProgramWith` confirms well-typedness, so it can treat impossible cases as panics.

**Tech Stack:** Haskell (GHC 9.10, `Strict`/`StrictData` on — no field bangs), `mtl` (`ReaderT`/`State` for the `Elab` monad), `tasty`/golden tests, BNFC-generated `GeneratedParser.Wok.Abs`.

---

## Design decisions (read once)

- **Type-erased v1.** Binders carry `Name` + `Mult` only. Records are label-keyed (`RRecord`/`RProj` by `Text` label) and effect operations dispatch by name, so elaboration needs the `Env` namespaces (`envCons`, `envEffects`, `envRecordCons`, `envTyCons`) and local scope, never per-node inferred types. `Infer.hs` is untouched.
- **Identity is opaque.** `Unique` is a `newtype` over `Int` whose `Ord` exists only to key `IntMap`/`Map`; no pass may treat it as a rank or dense index. `Name` equality is on the unique alone; the text hint is for dumps only. Internal binder/join uniques are regenerated per elaboration and never leak into external (top-level) identity, which stays `(module, source-name)`.
- **Determinism.** The unique supply is a pure `State Int` counter (no `IORef`/`unsafePerformIO`), so ANF dumps are reproducible for goldens. Pretty-print binders as `hint`, disambiguating to `hint.N` only on hint collision within a dump.
- **ANF by construction.** Function/constructor/op arguments are always `Atom`s. Any compound (`if`/`case`/`handle`) appearing in value position is bound via a **join point** that both branches `Jump` to with the result — never by duplicating the continuation.
- **Mult.** `Unrestricted` for every binder in v1 (no surface multiplicity syntax exists). The slot is the future no-dup hook.

## File structure

- `src/Wok/IR/Name.hs` — `Unique`, `Name`, `JoinId`, the `Fresh`/`Elab` supply primitives. One responsibility: identity.
- `src/Wok/IR/Anf.hs` — the ANF datatype + pretty-printer. One responsibility: the IR and its rendering.
- `src/Wok/IR/Elaborate.hs` — `Env -> Abs.Module -> CoreModule`: resolve + desugar + normalize. The workhorse.
- `wok.cabal` — register the three modules.
- `app/Main.hs` — add an ANF dump path (gated behind a flag or a new mode).
- `src/Wok/Pipeline.hs` — expose elaboration after typecheck for the dump path and tests.
- `test/Spec.hs` — unit groups (`IRName`, `Anf`, `Elaborate*`) and the `anf golden` group.
- `test/anf-golden/` — golden ANF dumps for `test/typecheck-examples/*.wok`.

---

## Task 0: Bootstrap modules and cabal wiring

**Goal:** Three compiling empty modules registered in cabal; build stays green.

**Files:**
- Create: `src/Wok/IR/Name.hs`, `src/Wok/IR/Anf.hs`, `src/Wok/IR/Elaborate.hs`
- Modify: `wok.cabal`

**Acceptance Criteria:**
- [ ] Three modules listed under `exposed-modules`/`other-modules`.
- [ ] `cabal build` succeeds.
- [ ] No new default-extensions needed (Strict/StrictData already centralized).

**Verify:** `cabal build` → `Up to date` / success, no warnings about missing modules.

**Steps:**

- [ ] **Step 1: Stub the three modules**

```haskell
-- src/Wok/IR/Name.hs
module Wok.IR.Name () where
```
```haskell
-- src/Wok/IR/Anf.hs
module Wok.IR.Anf () where
```
```haskell
-- src/Wok/IR/Elaborate.hs
module Wok.IR.Elaborate () where
```

- [ ] **Step 2: Register in `wok.cabal`**

Add to the library `exposed-modules:` list (alongside `Wok.TypeChecking`):
```
Wok.IR.Name
Wok.IR.Anf
Wok.IR.Elaborate
```

- [ ] **Step 3: Build**

Run: `cabal build`
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/IR/ wok.cabal
git commit -m "build(ir): scaffold Wok.IR.{Name,Anf,Elaborate} modules"
```

---

## Task 1: `Wok.IR.Name` — opaque identity + deterministic supply

**Goal:** `Unique`/`Name`/`JoinId` with identity-only equality and a pure fresh-name supply.

**Files:**
- Modify: `src/Wok/IR/Name.hs`
- Test: `test/Spec.hs` (group `IRName`)

**Acceptance Criteria:**
- [ ] `Name` `Eq`/`Ord` compares the unique only; hint is ignored.
- [ ] `freshName`/`freshJoin` produce monotonically distinct uniques from a `State Int`.
- [ ] Two `Name`s with same hint but different unique are unequal; same unique different hint are equal.
- [ ] No `IORef`/`unsafePerformIO`.

**Verify:** `cabal test --test-options="-p IRName"` → all pass.

**Steps:**

- [ ] **Step 1: Write the module**

```haskell
module Wok.IR.Name
  ( Unique (..)
  , Name (..)
  , JoinId (..)
  , Fresh
  , runFresh
  , freshUnique
  , freshName
  , freshJoin
  , nameText
  ) where

import Control.Monad.State.Strict (State, runState, state)
import Data.Text (Text)
import qualified Data.Text as Tx

-- | Opaque identity token. Ord exists ONLY to key Map/IntMap; ordering and
-- contiguity carry no meaning and no pass may rely on them.
newtype Unique = Unique Int
  deriving (Eq, Ord, Show)

-- | A term-level name: a human hint for dumps/errors plus an identity.
-- Eq/Ord are on the unique ALONE.
data Name = Name { nameHint :: Text, nameUniq :: Unique }
  deriving (Show)

instance Eq Name where
  a == b = nameUniq a == nameUniq b
instance Ord Name where
  compare a b = compare (nameUniq a) (nameUniq b)

-- | Join-point label. Its own type so a Jump cannot target a value binder.
newtype JoinId = JoinId Unique
  deriving (Eq, Ord, Show)

-- | Deterministic pure supply (no IO).
type Fresh = State Int

runFresh :: Fresh a -> a
runFresh m = fst (runState m 0)

freshUnique :: Fresh Unique
freshUnique = state (\n -> (Unique n, n + 1))

freshName :: Text -> Fresh Name
freshName hint = Name hint <$> freshUnique

freshJoin :: Fresh JoinId
freshJoin = JoinId <$> freshUnique

-- | The display text for a name (hint only; callers disambiguate on collision).
nameText :: Name -> Text
nameText = nameHint
```

- [ ] **Step 2: Add the `IRName` test group to `test/Spec.hs`**

```haskell
-- in the tasty tree, a new testGroup "IRName"
testGroup "IRName"
  [ testCase "same unique, different hint => equal" $
      let (a, b) = runFresh $ do
            u <- freshUnique
            pure (Name (Tx.pack "x") u, Name (Tx.pack "y") u)
      in a @?= b
  , testCase "different unique => unequal" $
      let (a, b) = runFresh $ do
            x <- freshName (Tx.pack "x")
            y <- freshName (Tx.pack "x")
            pure (x, y)
      in assertBool "distinct" (a /= b)
  , testCase "supply is monotonic and deterministic" $
      let us = runFresh (mapM (const freshUnique) [1 :: Int .. 3])
      in us @?= [Unique 0, Unique 1, Unique 2]
  ]
```

- [ ] **Step 3: Run, expect pass**

Run: `cabal test --test-options="-p IRName"`
Expected: 3 tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/IR/Name.hs test/Spec.hs
git commit -m "feat(ir): opaque Unique/Name/JoinId + deterministic fresh supply"
```

---

## Task 2: `Wok.IR.Anf` — the ANF datatype + pretty-printer

**Goal:** The ANF IR (ANF-by-construction) and a deterministic renderer for goldens.

**Files:**
- Modify: `src/Wok/IR/Anf.hs`
- Test: `test/Spec.hs` (group `Anf`)

**Acceptance Criteria:**
- [ ] Datatype matches the design (atoms / RHS / control-Expr split; join points; handlers with `resume` binder).
- [ ] `prettyExpr` renders a hand-built term to stable text.
- [ ] Binder hints disambiguate to `hint.N` only on collision within a render.

**Verify:** `cabal test --test-options="-p Anf"` → pass.

**Steps:**

- [ ] **Step 1: Write the datatype**

```haskell
module Wok.IR.Anf
  ( Mult (..)
  , Binder (..)
  , Lit (..)
  , Atom (..)
  , Rhs (..)
  , Expr (..)
  , Alt (..)
  , Handler (..)
  , OpArm (..)
  , TopBind (..)
  , CoreModule (..)
  , prettyModule
  , prettyExpr
  ) where

import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Name (Name, JoinId (..), Unique (..), nameHint, nameUniq)

-- | Multiplicity. v1 always Unrestricted; Affine is the future no-dup hook.
data Mult = Unrestricted | Affine
  deriving (Eq, Show)

data Binder = Binder { bndName :: Name, bndMult :: Mult }
  deriving (Eq, Show)

data Lit = LInt Integer | LStr Text | LChar Char | LUnit
  deriving (Eq, Show)

-- | Trivial, pure, effect-free values. The ONLY things allowed as call args,
-- constructor fields, scrutinees, jump args.
data Atom = AVar Name | ALit Lit
  deriving (Eq, Show)

-- | Value-producing computations: the RHS of a strict Let. May allocate or
-- perform an effect. Never nested as a subexpression.
data Rhs
  = RAtom Atom                    -- x = y
  | RApp Atom [Atom]              -- f a b      (n-ary; saturated by elaboration)
  | RCon Text [Atom]             -- Cons x xs  (constructor tag + fields)
  | RLam [Binder] Expr           -- \x y -> e  (a value: closure)
  | ROp Text Text [Atom]         -- E.op a     (effect label, op name, args)
  | RRecord Text [(Text, Atom)]  -- T { l = a } (nominal tag + labelled fields)
  | RProj Text Atom              -- a.l        (label projection)
  deriving (Eq, Show)

-- | Block / control structure. Strict: Let = evaluate-now sequencing.
data Expr
  = Ret Atom
  | Let Binder Rhs Expr
  | LetRec [(Binder, [Binder], Expr)] Expr   -- mutually-rec FUNCTIONS only
  | Case Atom [Alt]
  | LetJoin JoinId [Binder] Expr Expr        -- join j(ps)=jbody ; body
  | Jump JoinId [Atom]
  | Handle Expr Handler
  deriving (Eq, Show)

data Alt
  = AltCon Text [Binder] Expr
  | AltLit Lit Expr
  | AltDefault Expr
  deriving (Eq, Show)

data Handler = Handler
  { hReturn :: (Binder, Expr)
  , hOps :: [OpArm]
  } deriving (Eq, Show)

data OpArm = OpArm
  { oaLabel :: Text
  , oaOp :: Text
  , oaArgs :: [Binder]
  , oaResume :: Binder
  , oaBody :: Expr
  } deriving (Eq, Show)

data TopBind = TopBind { tbName :: Name, tbParams :: [Binder], tbBody :: Expr }
  deriving (Eq, Show)

newtype CoreModule = CoreModule { cmBinds :: [TopBind] }
  deriving (Eq, Show)
```

- [ ] **Step 2: Write the pretty-printer**

Render with explicit `let`/`in`, `case ... of`, `join`/`jump`, `handle ... { ... }`. Binder display: collect all binder hints in the term; for any hint used by more than one distinct unique, suffix `.N` where N is the unique's `Int`. Keep it total and deterministic. Minimum viable renderer:

```haskell
prettyModule :: CoreModule -> Text
prettyModule (CoreModule bs) = Tx.intercalate (Tx.pack "\n\n") (map prettyTop bs)

prettyTop :: TopBind -> Text
prettyTop (TopBind n ps b) =
  Tx.concat [nameHint n, Tx.pack " ", Tx.unwords (map (nameHint . bndName) ps)
            , Tx.pack " =\n", indent 1 (prettyExpr b)]

-- prettyExpr, prettyRhs, prettyAtom, prettyAlt, prettyHandler ... (full,
-- no placeholders). Atoms: AVar -> hint, ALit -> literal text. Let ->
-- "let <b> = <rhs>\n<body>". Case -> "case <atom> of\n  <alts>". Jump ->
-- "jump j<u>(<atoms>)". Handle -> "handle\n  <body>\nwith { return x -> ..;
-- E.op(args, k) -> .. }".
```

(The implementer writes every constructor's branch; the round-trip test below pins the exact format chosen.)

- [ ] **Step 3: Write the `Anf` test**

```haskell
testGroup "Anf"
  [ testCase "renders a let/case term stably" $
      let (m) = runFresh $ do
            x  <- freshName (Tx.pack "x")
            r  <- freshName (Tx.pack "r")
            f  <- freshName (Tx.pack "f")
            -- f x = let r = x in case r of { 0 -> 1 ; _ -> r }
            let body = Let (Binder r Unrestricted) (RAtom (AVar x))
                         (Case (AVar r)
                            [ AltLit (LInt 0) (Ret (ALit (LInt 1)))
                            , AltDefault (Ret (AVar r)) ])
            pure (CoreModule [TopBind f [Binder x Unrestricted] body])
      in prettyModule m @?= Tx.pack
           "f x =\n  let r = x\n  case r of\n    0 -> 1\n    _ -> r"
  ]
```

(Adjust the expected string to the exact format the implementer commits; the point is a pinned, deterministic render.)

- [ ] **Step 4: Run + commit**

Run: `cabal test --test-options="-p Anf"` → pass.
```bash
git add src/Wok/IR/Anf.hs test/Spec.hs
git commit -m "feat(ir): ANF datatype + deterministic pretty-printer"
```

---

## Task 3: Elaboration scaffold + simple expressions

**Goal:** The `Elab` monad (global `Env` + local scope + fresh supply) and continuation-passing ANF normalization for the non-compound expression forms.

**Files:**
- Modify: `src/Wok/IR/Elaborate.hs`
- Test: `test/Spec.hs` (group `ElaborateBasic`)

**Acceptance Criteria:**
- [ ] `Elab` = `ReaderT ElabCtx Fresh` with `ElabCtx { ecEnv :: Env, ecScope :: Map Text Name }`.
- [ ] `normalizeName`/`normalizeAtom` realize the standard ANF "name this subexpression" combinator.
- [ ] Literals, `EVar` (scope then global), `ECon` (nullary/saturated), `EApp` spine, `ELam`, `EIf`, `ETuple`, `EList`, `EParen` elaborate to ANF.
- [ ] `EIf`/value-position compounds introduce a join point (see Task 4 for the shared helper; basic `EIf` in tail position needs none).

**Verify:** `cabal test --test-options="-p ElaborateBasic"` → pass.

**Steps:**

- [ ] **Step 1: Monad + entry points**

```haskell
module Wok.IR.Elaborate
  ( elaborateModule
  , elaborateExprForTest   -- test seam: Env -> Abs.Exp -> Expr
  ) where

import Control.Monad.Reader
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Tx
import qualified GeneratedParser.Wok.Abs as Abs
import Wok.IR.Anf
import Wok.IR.Name
import Wok.TypeChecking.Env (Env (..))

data ElabCtx = ElabCtx { ecEnv :: Env, ecScope :: Map.Map Text Name }

type Elab = ReaderT ElabCtx Fresh

withLocal :: Text -> Name -> Elab a -> Elab a
withLocal t n = local (\c -> c { ecScope = Map.insert t n (ecScope c) })

bindFresh :: Text -> Elab Name
bindFresh t = lift (freshName t)
```

- [ ] **Step 2: The ANF normalizer (continuation-passing)**

```haskell
-- Elaborate an Abs.Exp, then hand a representing Atom to the continuation,
-- emitting Lets for any intermediate computation. This is the classic ANF
-- "normalize" combinator (Flanagan et al).
normName :: Abs.Exp -> (Atom -> Elab Expr) -> Elab Expr
normName e k = elabRhs e $ \rhs -> case rhs of
  RAtom a -> k a
  _       -> do n <- bindFresh (Tx.pack "t")
                Let (Binder n Unrestricted) rhs <$> k (AVar n)

-- Elaborate an Abs.Exp to a single Rhs (naming its sub-parts first), then
-- continue. Value-producing forms go here.
elabRhs :: Abs.Exp -> (Rhs -> Elab Expr) -> Elab Expr
```

Show the simple cases fully:

```haskell
elabRhs (Abs.ELitI (Abs.WokInt (_, t))) k = k (RAtom (ALit (LInt (readInt t))))
elabRhs (Abs.ELitS s)                   k = k (RAtom (ALit (LStr (Tx.pack s))))
elabRhs (Abs.ELitC c)                   k = k (RAtom (ALit (LChar c)))
elabRhs Abs.EUnit                       k = k (RAtom (ALit LUnit))
elabRhs (Abs.EParen e)                  k = elabRhs e k
elabRhs (Abs.EVar (Abs.VarId (_, t)))   k = do
  scope <- asks ecScope
  case Map.lookup t scope of
    Just n  -> k (RAtom (AVar n))
    Nothing -> k (RAtom (AVar (globalName t)))   -- top-level/builtin
elabRhs (Abs.EApp f x) k =
  collectSpine (Abs.EApp f x) $ \headE args ->
    normName headE $ \ha ->
      normAll args $ \aas -> case headE of
        Abs.ECon (Abs.ConId (_, c)) -> k (RCon c aas)   -- saturated constructor
        _                           -> k (RApp ha aas)
-- ELam, EIf, ETuple, EList: shown in full by the implementer following the
-- same pattern. ETuple -> RCon (tupleTag n) atoms ; EList -> desugar to
-- Cons/Nil RCon chain ; ELam -> RLam (map binder ps) <$> elabTail body.
```

Helpers to define fully: `collectSpine` (unwind `EApp`), `normAll` (thread `normName` over a list), `elabTail :: Abs.Exp -> Elab Expr` (elaborate in tail position: `elabRhs e (pure . rhsToTail)` where a trivial RHS becomes `Ret`/the RHS is `Let`-bound then `Ret`), `globalName`, `readInt`, `tupleTag`, `consTag`/`nilTag`.

- [ ] **Step 3: `elaborateExprForTest`**

```haskell
elaborateExprForTest :: Env -> Abs.Exp -> Expr
elaborateExprForTest env e =
  runFresh (runReaderT (elabTail e) (ElabCtx env Map.empty))
```

- [ ] **Step 4: Tests**

```haskell
testGroup "ElaborateBasic"
  [ testCase "literal" $
      elaborateExprForTest emptyEnv (Abs.ELitI (Abs.WokInt ((0,0), Tx.pack "1")))
        @?= Ret (ALit (LInt 1))
  , testCase "application names its argument" $
      -- f (g 1)  =>  let t = g 1 in f t   (shape assertion)
      ... assert the Let/RApp structure ...
  ]
```

- [ ] **Step 5: Run + commit**

Run: `cabal test --test-options="-p ElaborateBasic"` → pass.
```bash
git add src/Wok/IR/Elaborate.hs test/Spec.hs
git commit -m "feat(ir): Elab monad + ANF normalization for simple expressions"
```

---

## Task 4: `let`, `where`, `case`, patterns, join points

**Goal:** Elaborate binding and branching forms; introduce join points for value-position branches; compile patterns.

**Files:**
- Modify: `src/Wok/IR/Elaborate.hs`
- Test: `test/Spec.hs` (group `ElaborateControl`)

**Acceptance Criteria:**
- [ ] `ELet`/`where` (`WithWh`) become nested `Let`/`LetRec` (mutually-recursive function groups detected → `LetRec`; single non-function → `Let`).
- [ ] `ECase` in tail position → `Case`; in value position → `LetJoin j [r] <body-with-r> (Case scrut alts-jumping-to-j)`.
- [ ] Patterns (`PAtom`/`PApp`/`PCons`, atoms incl. `APTuple`/`APList`/literals) compile to `Alt`s binding constructor fields; nested patterns desugar to nested `Case`.
- [ ] `EIf` reuses the case machinery over `True`/`False` constructors.

**Verify:** `cabal test --test-options="-p ElaborateControl"` → pass.

**Steps:**

- [ ] **Step 1: The join-point helper**

```haskell
-- Elaborate a compound (case/if/handle) that must yield a value to `k`.
-- Introduce a join point the branches jump to with the result.
viaJoin :: (Elab Expr) -> (Atom -> Elab Expr) -> Elab Expr
viaJoin elabCompoundTail k = do
  j <- lift freshJoin
  r <- bindFresh (Tx.pack "r")
  rest <- k (AVar r)
  comp <- local id elabCompoundTail   -- compound elaborated in tail pos,
                                       -- its tails are `Jump j [result]`
  pure (LetJoin j [Binder r Unrestricted] rest comp)
```

The compound's tail elaboration must end each branch with `Jump j [atom]` instead of `Ret atom`. Thread a "tail target" (either `Ret` or `Jump j`) through `elabTail`/`elabBranch` — define `data TailK = TRet | TJump JoinId` and `emitTail :: TailK -> Atom -> Expr`.

- [ ] **Step 2: `ELet` / `where`**

Show full elaboration: convert `[LocalDecl]` to bindings. `LDEqn (LHSPre (FNBare f) ps) body wh` with `ps` non-empty → a function binding (`RLam`); recursive group of such → `LetRec`. `LDEqn (LHSPre (FNBare x) []) body NoWhere` → a value `Let`. `where` clauses attach to their equation by elaborating the body under the where-bindings' scope.

- [ ] **Step 3: `ECase` + patterns**

Full code for: scrutinee `normName`d to an atom; each `AltC pat rhs wh` → `elabAlt`. `elabAlt` matches the pattern's head constructor/literal, binds fields to fresh `Binder`s (extending scope), recurses for nested sub-patterns via nested `Case`. Cover `PAtom (APVar/APWild/APLitI/APLitS/APLitC/PUnit/APTuple/APList/APParen)`, `PApp modPath ap aps` (constructor with args), `PCons` (list cons → `Cons` constructor alt).

- [ ] **Step 4: Tests** (let-polymorphism shape, case on a 2-constructor type producing nested binders, value-position case introducing a `LetJoin`).

- [ ] **Step 5: Run + commit**

Run: `cabal test --test-options="-p ElaborateControl"` → pass.
```bash
git commit -am "feat(ir): elaborate let/where/case with join points and pattern compilation"
```

---

## Task 5: Records — construction, projection, patterns

**Goal:** Desugar record forms to label-keyed `RRecord`/`RProj` and record patterns to `AltCon` over labelled fields.

**Files:**
- Modify: `src/Wok/IR/Elaborate.hs`
- Test: `test/Spec.hs` (group `ElaborateRecords`)

**Acceptance Criteria:**
- [ ] `ERecord (ConId T) fields` → `RRecord T [(label, atom)]` (fields normalized to atoms, in declared order looked up from `envRecordCons`).
- [ ] `ERecordExt T spread (TFSome extra)` → spread normalized, then extended/overwritten with `extra` fields (label-keyed merge).
- [ ] `EProj e (VarId l)` where `e` is not an effect head → `RProj l atom`.
- [ ] Record patterns `PRecord`/`PRecordOpen`/`PRecordWild` bind named fields by label.

**Verify:** `cabal test --test-options="-p ElaborateRecords"` → pass.

**Steps:** Full elaboration of each form. For declared field order, read `envRecordCons env` (the `RecordConInfo`) to canonicalize `[(label, atom)]` order so dumps are stable. Spread merge: normalize the spread to an atom, then emit an `RRecord` whose fields are the spread's projected fields overwritten by the extras — for v1 keep it simple by emitting `RProj`s for each declared label of the spread's nominal type then overriding. (Document the chosen lowering in a comment; pin it with the golden.)

- [ ] **Commit:** `git commit -am "feat(ir): elaborate record construction, projection, and patterns"`

---

## Task 6: Effects — operation calls, handlers, operator chains

**Goal:** Desugar effect operations and handlers, plus the remaining surface forms (operator chains, sections).

**Files:**
- Modify: `src/Wok/IR/Elaborate.hs`
- Test: `test/Spec.hs` (group `ElaborateEffects`)

**Acceptance Criteria:**
- [ ] `EProj (ECon E) (VarId op)` where `E` is in `envEffects` and `op` in its ops → applied as `ROp E op atoms` (collect the application spine around the projection).
- [ ] `EHandle e arms` → `Handle <elab e tail> (Handler {hReturn, hOps})`; `HArm (ConId E) (VarId op-or-resume?) aps body` binds op args + a fresh `resume` binder; `HReturn x body` is the return arm. (Map `HArm`'s fields to `(E, op, args, resume, body)` per the grammar: `HArm ConId VarId [AtomPat] Exp` — `VarId` is the bound `resume`.)
- [ ] `EExpr head tails` (post-reorder infix chain) folds left into nested `RApp` of the resolved operator name; `EParenOp sym` → the operator as a value (`RAtom (AVar (globalName sym))`).

**Verify:** `cabal test --test-options="-p ElaborateEffects"` → pass.

**Steps:** Full code. Effect detection mirrors `Infer.hs:1253` (`inferExprW (Abs.EProj headE@(Abs.ECon ...) ...)`): look the `ConId` up in `envEffects`; if present and the label is an operation, it is an op-call, else a record projection. `EExpr` folding: each `ITail (IOSym s) rhs` / `ITail (IOBT v) rhs` applies operator `s`/v\` to the running lhs and `rhs` (both normalized to atoms). Operators resolve to `globalName`.

- [ ] **Commit:** `git commit -am "feat(ir): elaborate effect operations, handlers, and operator chains"`

---

## Task 7: Top-level module elaboration + pipeline wiring

**Goal:** Elaborate a whole `Abs.Module` to `CoreModule` and expose an ANF dump from the pipeline / `wok` executable.

**Files:**
- Modify: `src/Wok/IR/Elaborate.hs`, `src/Wok/Pipeline.hs`, `app/Main.hs`
- Test: `test/Spec.hs` (group `ElaborateModule`)

**Acceptance Criteria:**
- [ ] `elaborateModule :: Env -> Abs.Module -> CoreModule` turns each `DEqn`/value equation into a `TopBind` (params from `LHSPre`); `DData`/`DEffect`/`DSig`/fixity/imports contribute only to the `Env` (already built by typecheck) and emit no `TopBind`.
- [ ] Mutually-recursive top-level functions all become sibling `TopBind`s (top level is implicitly recursive — names resolve via `globalName`).
- [ ] `Pipeline` exposes `elaborateProgram :: Env -> Abs.Module -> CoreModule` for the dump path and tests.
- [ ] `wok --dump-anf file.wok` (or a chosen flag) prints `prettyModule` after a successful typecheck; type errors still take the existing path.

**Verify:** `cabal run wok -- --dump-anf examples/types-tour.wok` prints ANF; `cabal test --test-options="-p ElaborateModule"` → pass.

**Steps:** Full code for `elaborateModule` (fold over decls, elaborate each function equation's body in tail position with its parameters in scope), the `Pipeline` export, and a minimal `Main` flag dispatch reusing the existing typecheck pipeline to obtain `(Env, Abs.Module)` before elaborating.

- [ ] **Commit:** `git commit -am "feat(ir): top-level ANF elaboration + wok --dump-anf"`

---

## Task 8: Golden ANF corpus

**Goal:** Pin ANF output for the existing success fixtures so elaboration changes are reviewable.

**Files:**
- Modify: `test/Spec.hs` (group `anf golden`)
- Create: `test/anf-golden/*.expected`

**Acceptance Criteria:**
- [ ] A tasty-golden group runs every `test/typecheck-examples/*.wok` through `typecheck → elaborateProgram → prettyModule` and compares to `test/anf-golden/<name>.expected`.
- [ ] `cabal test --test-options="-p 'anf golden' --accept"` writes initial goldens; a second run is clean.
- [ ] Goldens manually inspected: identity/arithmetic/lists/maybe/records/effects-handle look correct (ANF named, join points where expected, `resume` bound in handler arms).

**Verify:** `cabal test --test-options="-p 'anf golden'"` → all pass; full `cabal test` green.

**Steps:** Add the golden harness mirroring the existing `typecheck golden` group (reuse its module-loading path). Generate goldens with `--accept`, inspect, commit.

- [ ] **Commit:** `git commit -am "test(ir): golden ANF dumps for the success corpus"`

---

## Self-review checklist (run after implementation)

1. **Coverage:** every `Abs.Exp` constructor reachable from a typechecked program has an `elabRhs`/`elabTail` case (literals, var, con, app, proj, record, recordext, paren, parenop, unit, list, tuple, lam, let, case, if, handle, expr-chain). List any missing.
2. **Placeholder scan:** no `RProj`/`ROp`/`RRecord` left as `error "TODO"`; the pretty-printer is total over every constructor.
3. **Name consistency:** `globalName`, `bindFresh`, `normName`, `elabTail`, `viaJoin`, `TailK` used identically across tasks.
4. **Determinism:** no `Map.toList`-order leakage into dumps without an explicit sort; record fields canonicalized to declared order.
