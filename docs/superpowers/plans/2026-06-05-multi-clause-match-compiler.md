# Multi-clause Match Compiler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compile a group of same-named function equations into a single function whose body is a decision tree over the arguments, with correct cross-clause fallthrough, plus exhaustiveness/redundancy warnings.

**Architecture:** A new pure module `Wok/IR/Match.hs` builds a Sestoft/Maranget decision tree (`Case`/`AltCon`/`AltLit`/`AltDefault`) from a clause matrix; each clause body becomes a `LetJoin` and every tree leaf `Jump`s to it (sharing via join points, not hash-consing). `TypedDecl` is widened from one `(params, body)` to a clause list; `finalizeGroupTyped` stops dropping clauses; `Elaborate.elabTopBind` wires the join points and calls the compiler. A parallel pure usefulness check emits two new warnings.

**Tech Stack:** Haskell, cabal, tasty/tasty-golden/tasty-hunit. ANF IR in `Wok.IR.Anf`; type-checker in `Wok.TypeChecking.*`. Spec: `docs/superpowers/specs/2026-06-05-multi-clause-match-compiler-design.md`.

**Conventions:** No emojis in code (repo rule). Work on a branch off `main` — `git checkout -b feat/multi-clause-match` before the first commit; review-before-merge to `main` is required. Run `hlint` on changed `src/**.hs` (exclude generated) before each commit. Golden files use the `.expected` extension and live beside their harness dirs under `test/`.

---

## Background the implementer needs

You are building a **pattern-match compiler for function heads**. Today wok mishandles multi-clause functions:

- `groupEquations` (`src/Wok/TypeChecking/Infer.hs:1994`) collects same-named equations and type-checks them all, but `finalizeGroupTyped` (`src/Wok/TypeChecking/Infer.hs:2126`) keeps only the FIRST clause's `(params, body)` and silently drops the rest (`Infer.hs:2131-2136`).
- `elabParam` (`src/Wok/IR/Elaborate.hs:202`) lowers a refutable head pattern to a `Case` with ONE alt and no fallback (`Elaborate.hs:213-219`), so a non-matching argument crashes at runtime.
- The only coverage check that exists is `NonExhaustiveRecordPattern` (`src/Wok/TypeChecking/Error.hs:132`).

### Key existing types (read these before starting)

ANF IR — `src/Wok/IR/Anf.hs`:
```haskell
data Atom = AVar Name | ALit Lit                              -- Anf.hs:39
data Lit  = LInt Integer | LStr Text | LChar Char | LUnit     -- Anf.hs:34
data Binder = Binder { bndName :: Name, bndMult :: Mult, bndType :: CType }  -- Anf.hs:31
data Expr
  = Ret Atom
  | Let Binder Rhs Expr
  | LetRec [(Binder, [Binder], Expr)] Expr
  | Case Atom [Alt]
  | LetJoin JoinId [Binder] Expr Expr   -- join j(ps)=jbody ; body   -- Anf.hs:59
  | Jump JoinId [Atom]
  | Handle Expr Handler
data Alt = AltCon Text [Binder] Expr | AltLit Lit Expr | AltDefault Expr  -- Anf.hs:64
data Mult = Unrestricted | Affine                             -- Anf.hs:28
```

Names / fresh supply — `src/Wok/IR/Name.hs`:
```haskell
type Fresh = State Int                 -- Name.hs:36
freshName :: Text -> Fresh Name        -- Name.hs:44
freshJoin :: Fresh JoinId              -- Name.hs:47
newtype JoinId = JoinId Unique         -- Name.hs:32 ; Unique = Unique Int (Name.hs:18)
```

Typed AST — `src/Wok/TypeChecking/Typed.hs`:
```haskell
data Tpat a = Tpat a (TpatF a)         -- Typed.hs:54
data TpatF a = TPVar Text | TPWild | TPLitI Integer | TPLitS Text | TPLitC Char
             | TPUnit | TPTuple [Tpat a] | TPList [Tpat a]
             | TPCon Text [Tpat a] | TPCons (Tpat a) (Tpat a)     -- Typed.hs:55-68
type TPat  = Tpat CType                 -- Typed.hs:73
type TExpr = Texp CType                 -- Typed.hs:71
data TLocalDecl a = TLocalDecl Text [Tpat a] (Texp a)            -- Typed.hs:49
-- TexpF has TLam [Tpat a] (Texp a) and TList [Texp a]           -- Typed.hs:20,28
```

TypedDecl (the type-checker output, **changed in Task 3**) — `src/Wok/TypeChecking/Infer.hs:2430`:
```haskell
data TypedDecl = TypedDecl
  { tdName     :: Text
  , tdScheme   :: Scheme
  , tdParams   :: [TPat]        -- <- removed in Task 3
  , tdBody     :: TExpr         -- <- removed in Task 3
  , tdEvidence :: [(Text, Constraint)]
  }
```

Env constructor metadata — `src/Wok/TypeChecking/Env.hs`:
```haskell
data ConInfo   = ConInfo { conScheme :: Scheme, conArity :: Int, conTyCon :: Text }  -- Env.hs:36
data TyConInfo = TyConInfo { tcKind :: Kind, tcArity :: Int, tcCons :: [Text] }      -- Env.hs:43
lookupCon   :: Text -> Env -> Maybe ConInfo     -- Env.hs:149
lookupTyCon :: Text -> Env -> Maybe TyConInfo   -- Env.hs:152
lookupRecordCon :: Text -> Env -> Maybe RecordConInfo  -- Env.hs:164
```

### Build & test commands

```bash
cabal build                                                   # compile
cabal test wok-tests                                          # full suite
cabal test wok-tests --test-options='-p "PatternCoverage"'    # one tasty pattern
cabal test wok-tests --test-options='--accept'                # accept new golden output
```
Golden harness wiring is in `test/Spec.hs`. ANF goldens compare `Anf.prettyModule` over `test/typecheck-examples/*.wok` against `test/anf-golden/*.expected` (`Spec.hs:149-152`, `227-235`). Run goldens execute programs from `test/run-examples/*.wok` against `test/run-golden/*.expected` (`Spec.hs:157-160`, `191-201`). Warnings are asserted in HUnit groups (e.g. `patternCoverageTests`, `Spec.hs:3162`), not rendered into goldens.

### Design decisions locked in (do not relitigate)

- **Decision tree, not tuple scrutinee, not backtracking automaton.** Sharing comes from join points.
- **Scope = function heads, top-level groups.** Body `case` expressions keep the existing `elabCaseAlt`/`elabPatF` path. Local (`where`/`let`) function clause groups are out of scope (the existing single-`TLocalDecl`-per-equation path is unchanged); only top-level groups built by `groupEquations` are compiled.
- **Routing rule:** a top-level clause group uses the cheap existing `elabParams` path **iff it has exactly one clause AND every head pattern is `TPVar`/`TPWild`/`TPUnit`, OR that single clause contains a record-constructor pattern**. Everything else (any refutable non-record head, or >1 clause) goes through `compileMatch`. This keeps every current golden byte-identical (no existing top-level example has a refutable non-record head) while fixing the real gaps.
- **Records out of scope for the matrix.** `compileMatch` (via `toMPat`) rejects a record-constructor column with a clear error. Records are single-constructor, so multi-clause dispatch on them is degenerate; single-clause record patterns stay on the existing projection path.
- **Fail leaf** = `Case (ALit LUnit) []` — an empty-alt `Case` that the interpreter resolves to `NonExhaustiveCase` at runtime, exactly as the current one-alt path fails today.
- **Variable bindings ride as join-point parameters.** Each clause body is `LetJoin k_i [vars...] = body`; each leaf `Jump`s with the matched atoms in left-to-right variable order (`rowOrder`).

---

## File structure

- **Create** `src/Wok/IR/Match.hs` — pure decision-tree compiler + usefulness check. Depends only on `Wok.IR.Anf`, `Wok.IR.Name`, `Wok.TypeChecking.Types`. No dependency on `Elaborate` or `Env` (avoids an import cycle; the env is injected as a `ConOracle`).
- **Modify** `wok.cabal` — add `Wok.IR.Match` to the library module list.
- **Modify** `src/Wok/TypeChecking/Infer.hs` — widen `TypedDecl` to a clause list; `finalizeGroupTyped` keeps all clauses; arity-agreement check in `inferTopLetGroup`; update `sigOnlyBindings`; emit coverage warnings.
- **Modify** `src/Wok/TypeChecking/Error.hs` — `ClauseArityMismatch` error; `NonExhaustiveMatch` + `RedundantClause` warnings.
- **Modify** `src/Wok/IR/Elaborate.hs` — `elabTopBind` routes through `compileMatch`; `isBodylessSig` reads the clause list; build the per-clause join points and the `ConOracle`.
- **Create** test fixtures under `test/typecheck-examples/`, `test/anf-golden/`, `test/run-examples/`, `test/run-golden/`; add unit-test groups to `test/Spec.hs`.

---

### Task 1: Pure decision-tree compiler core (`Wok/IR/Match.hs`)

**Goal:** A standalone, unit-tested function that turns a clause matrix into an ANF decision tree of `Case`/`AltCon`/`AltLit`/`AltDefault` with `Jump` leaves.

**Files:**
- Create: `src/Wok/IR/Match.hs`
- Modify: `wok.cabal` (register the module)
- Test: `test/Spec.hs` (new `matchCompilerTests` group)

**Acceptance Criteria:**
- [ ] `compileMatch` lowers a single-column constructor matrix to one `Case` with one `AltCon` per present constructor and an `AltDefault` only when the signature is incomplete.
- [ ] A two-column matrix lowers to nested `Case`s with correct cross-clause fallthrough.
- [ ] A literal column (`Just 0 / Just _ / Nothing`) tests the constructor once, then switches on the literal without re-testing the constructor.
- [ ] Variable/wildcard patterns bind the scrutinee atom and the leaf `Jump`s with atoms in `rowOrder`.

**Verify:** `cabal test wok-tests --test-options='-p "MatchCompiler"'` → all pass.

**Steps:**

- [ ] **Step 0: Branch**

```bash
cd /Users/zy/wokml
git checkout -b feat/multi-clause-match
```

- [ ] **Step 1: Write the module skeleton and types**

Create `src/Wok/IR/Match.hs`:
```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Pure decision-tree pattern-match compiler (Sestoft 1996 / Jacobs 2021
-- matrix construction with Maranget's necessity heuristic). Turns a clause
-- matrix into an ANF decision tree whose leaves Jump to per-clause join points.
-- Depends only on the IR and type vocabulary -- never on Elaborate or Env -- so
-- it can be unit-tested in isolation and cannot form an import cycle.
module Wok.IR.Match
  ( MPat (..)
  , MPatF (..)
  , Row (..)
  , ConOracle (..)
  , compileMatch
  , Coverage (..)
  , matchCoverage
  , tupleTag
  ) where

import Control.Monad (replicateM)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf (Alt (..), Atom (..), Binder (..), Expr (..), Lit (..), Mult (..))
import Wok.IR.Name (Fresh, JoinId, freshName)
import Wok.TypeChecking.Types (CType (..))

-- | A normalized head pattern carrying the type of the value it matches (so the
-- field binders we mint get meaningful types for the typed-ANF dump).
data MPat = MPat CType MPatF
  deriving (Show)

data MPatF
  = MVar (Maybe Text)   -- ^ variable @Just v@ or wildcard @Nothing@
  | MCon Text [MPat]    -- ^ data constructor / TupleN / Nil / Cons
  | MLit Lit            -- ^ literal
  deriving (Show)

-- | Per-constructor metadata the compiler needs, supplied by the caller from the
-- type environment so this module stays Env-free.
data ConOracle = ConOracle
  { coArity    :: Text -> Int           -- ^ field count of a constructor tag
  , coSiblings :: Text -> Maybe [Text]  -- ^ the COMPLETE sibling-tag set for the
                                        --   column's type, or 'Nothing' when the
                                        --   type has no finite signature (literals)
  }

-- | One clause row of the matrix.
data Row = Row
  { rowPats  :: [MPat]           -- ^ one entry per current column
  , rowSubst :: [(Text, Atom)]   -- ^ variable -> matched atom, accumulated
  , rowJoin  :: JoinId           -- ^ this clause body's join point
  , rowOrder :: [Text]           -- ^ join-param order (clause vars, left-to-right)
  , rowIndex :: Int              -- ^ original clause index (for diagnostics)
  }
  deriving (Show)

tupleTag :: Int -> Text
tupleTag n = Tx.pack ("Tuple" ++ show n)

-- | The match-failure leaf: an empty-alt Case the interpreter resolves to
-- NonExhaustiveCase at runtime (same failure mode the old one-alt path had).
failLeaf :: Expr
failLeaf = Case (ALit LUnit) []

removeAt :: Int -> [a] -> [a]
removeAt i xs = take i xs ++ drop (i + 1) xs

isWildP :: MPat -> Bool
isWildP (MPat _ (MVar _)) = True
isWildP _                 = False

mpatType :: MPat -> CType
mpatType (MPat t _) = t
```

- [ ] **Step 2: Write the failing test for a single constructor column**

Add to `test/Spec.hs` (import `qualified Wok.IR.Match as M`; `runFresh` and `Name`/`Anf`/`Ty` aliases are already imported — see `Spec.hs:34-41`):
```haskell
matchCompilerTests :: TestTree
matchCompilerTests = testGroup "MatchCompiler"
  [ testCase "single constructor column: one Case, complete signature, no default" $ do
      let oracle = M.ConOracle
            { M.coArity = \t -> if t == T.pack "Some" then 1 else 0
            , M.coSiblings = \_ -> Just [T.pack "None", T.pack "Some"] }
          ty = Ty.CTCon Ty.TcUnit []
          j0 = Name.JoinId (Name.Unique 100)
          j1 = Name.JoinId (Name.Unique 101)
          rows =
            [ M.Row [M.MPat ty (M.MCon (T.pack "None") [])] [] j0 [] 0
            , M.Row [M.MPat ty (M.MCon (T.pack "Some")
                       [M.MPat ty (M.MVar (Just (T.pack "x")))])] [] j1 [T.pack "x"] 1 ]
          expr = runFresh
            (M.compileMatch oracle [Anf.AVar (Name.Name (T.pack "m") (Name.Unique 1))] rows)
      case expr of
        Anf.Case _ alts -> do
          length alts @?= 2
          [ () | Anf.AltDefault _ <- alts ] @?= []
        other -> assertFailure ("expected Case, got: " ++ show other)
  ]
```
Register `matchCompilerTests` in the `defaultMain` list (near `Spec.hs:115`, beside `anfTests`).

- [ ] **Step 3: Run to verify it fails**

Run: `cabal test wok-tests --test-options='-p "MatchCompiler"'`
Expected: FAIL — `compileMatch` not defined.

- [ ] **Step 4: Implement `compileMatch` and helpers**

Append to `src/Wok/IR/Match.hs`:
```haskell
-- | Compile a clause matrix against a vector of scrutinee atoms into a decision
-- tree. The atom vector is aligned with the matrix columns; both shrink together
-- as columns are consumed.
compileMatch :: ConOracle -> [Atom] -> [Row] -> Fresh Expr
compileMatch _ _ [] = pure failLeaf                       -- no rows -> match failure
compileMatch oracle scruts rows@(r0 : _)
  | all isWildP (rowPats r0) = pure (jumpLeaf (bindRow scruts r0))  -- first row wins
  | otherwise = do
      let i = chooseColumn scruts rows
      switchOn oracle i scruts rows

-- Bind every variable column of a row to its current scrutinee atom.
bindRow :: [Atom] -> Row -> Row
bindRow scruts r =
  r { rowSubst = rowSubst r
        ++ [ (v, a) | (MPat _ (MVar (Just v)), a) <- zip (rowPats r) scruts ] }

-- Emit the clause body jump, supplying the matched atoms in join-param order.
jumpLeaf :: Row -> Expr
jumpLeaf r = Jump (rowJoin r) [ atomFor v | v <- rowOrder r ]
  where atomFor v = maybe (ALit LUnit) id (lookup v (rowSubst r))  -- always present

-- Necessity heuristic: prefer the leftmost column whose first non-wildcard
-- pattern is a constructor (dense tag switch) over a literal column; fall back to
-- the leftmost column with any non-wildcard pattern. Per Scott & Ramsey 2000 the
-- exact heuristic barely matters for human-written code, so this stays simple.
chooseColumn :: [Atom] -> [Row] -> Int
chooseColumn scruts rows =
  let cols         = [0 .. length scruts - 1]
      hasNonWild c = any (not . isWildP . (!! c) . rowPats) rows
      isConCol   c = any (\r -> case rowPats r !! c of MPat _ (MCon _ _) -> True; _ -> False) rows
      candidates   = filter hasNonWild cols
  in case filter isConCol candidates of
       (c : _) -> c
       []      -> head candidates    -- candidates non-empty: r0 is not all-wild

switchOn :: ConOracle -> Int -> [Atom] -> [Row] -> Fresh Expr
switchOn oracle i scruts rows = do
  let scrutI = scruts !! i
      others = removeAt i scruts
      heads  = nubHeads [ rowPats r !! i | r <- rows ]
  alts <- mapM (buildHeadAlt oracle i scrutI others rows) heads
  mDef <- buildDefault oracle i scrutI others rows heads
  pure (Case scrutI (alts ++ maybe [] (: []) mDef))

-- Distinct constructor/literal heads in first-seen order (variables ignored).
nubHeads :: [MPat] -> [MPatF]
nubHeads = go []
  where
    go seen [] = reverse seen
    go seen (MPat _ (MVar _) : ps) = go seen ps
    go seen (MPat _ h        : ps)
      | any (sameHead h) seen = go seen ps
      | otherwise             = go (h : seen) ps
    sameHead (MCon a _) (MCon b _) = a == b
    sameHead (MLit a)   (MLit b)   = a == b
    sameHead _          _          = False

buildHeadAlt :: ConOracle -> Int -> Atom -> [Atom] -> [Row] -> MPatF -> Fresh Alt
buildHeadAlt oracle i scrutI others rows (MCon c _) = do
  let arity     = coArity oracle c
      fieldTys  = fieldTypesOf c i rows arity
  fieldNames <- replicateM arity (freshName (Tx.pack "f"))
  let fieldAtoms   = map AVar fieldNames
      fieldBinders = zipWith (\n t -> Binder n Unrestricted t) fieldNames fieldTys
      rows'        = concatMap (specCon c arity i scrutI) rows
      scruts'      = fieldAtoms ++ others
  body <- compileMatch oracle scruts' rows'
  pure (AltCon c fieldBinders body)
buildHeadAlt oracle i scrutI others rows (MLit l) = do
  let rows' = concatMap (specLit l i scrutI) rows
  body <- compileMatch oracle others rows'
  pure (AltLit l body)
buildHeadAlt _ _ _ _ _ (MVar _) = error "Match.buildHeadAlt: variable is not a head"

-- The declared field types of constructor c, taken from the first row that
-- actually matches c (wildcard rows do not know the field types).
fieldTypesOf :: Text -> Int -> [Row] -> Int -> [CType]
fieldTypesOf c i rows arity =
  case [ map mpatType subs | r <- rows
                           , MPat _ (MCon c' subs) <- [rowPats r !! i], c' == c ] of
    (ts : _) -> ts
    []       -> replicate arity (CTCon (error "Match.fieldTypesOf: no field types") [])

-- Specialize a row against constructor c at column i.
specCon :: Text -> Int -> Int -> Atom -> Row -> [Row]
specCon c arity i scrutI r =
  case rowPats r !! i of
    MPat _ (MCon c' subs) | c' == c -> [ r { rowPats = subs ++ removeAt i (rowPats r) } ]
    MPat _ (MCon _ _) -> []
    MPat _ (MLit _)   -> []
    MPat _ (MVar mv)  ->
      [ r { rowPats  = replicate arity wildField ++ removeAt i (rowPats r)
          , rowSubst = bindVar mv scrutI (rowSubst r) } ]
  where wildField = MPat (CTCon (error "Match: wildcard field type") []) (MVar Nothing)
        -- a wildcard column never names a binder, so its CType is never read.

specLit :: Lit -> Int -> Atom -> Row -> [Row]
specLit l i scrutI r =
  case rowPats r !! i of
    MPat _ (MLit l') | l' == l -> [ r { rowPats = removeAt i (rowPats r) } ]
    MPat _ (MLit _)            -> []
    MPat _ (MCon _ _)          -> []
    MPat _ (MVar mv)           ->
      [ r { rowPats = removeAt i (rowPats r), rowSubst = bindVar mv scrutI (rowSubst r) } ]

-- The default sub-matrix: rows whose column i is a variable/wildcard. Needed when
-- the column's signature is incomplete (literals always; constructors only when
-- not every sibling tag is present among the heads).
buildDefault :: ConOracle -> Int -> Atom -> [Atom] -> [Row] -> [MPatF] -> Fresh (Maybe Alt)
buildDefault oracle i scrutI others rows heads
  | complete  = pure Nothing
  | otherwise = do
      let defRows = [ r { rowPats = removeAt i (rowPats r)
                        , rowSubst = bindVar mv scrutI (rowSubst r) }
                    | r <- rows, MPat _ (MVar mv) <- [rowPats r !! i] ]
      body <- compileMatch oracle others defRows
      pure (Just (AltDefault body))
  where complete = completeHeads oracle heads

completeHeads :: ConOracle -> [MPatF] -> Bool
completeHeads oracle heads =
  let conTags = [ c | MCon c _ <- heads ]
      hasLit  = not (null [ () | MLit _ <- heads ])
  in not hasLit && case conTags of
       []       -> False
       (c0 : _) -> case coSiblings oracle c0 of
         Nothing   -> False
         Just sibs -> all (`elem` conTags) sibs

bindVar :: Maybe Text -> Atom -> [(Text, Atom)] -> [(Text, Atom)]
bindVar Nothing  _ s = s
bindVar (Just v) a s = (v, a) : s
```

- [ ] **Step 5: Register the module in `wok.cabal`**

In `wok.cabal`, add `Wok.IR.Match` to the library's module list next to `Wok.IR.Elaborate` and `Wok.IR.Anf`.

- [ ] **Step 6: Run the single-column test to verify it passes**

Run: `cabal build && cabal test wok-tests --test-options='-p "MatchCompiler"'`
Expected: PASS.

- [ ] **Step 7: Add the two-column and literal-fallthrough tests**

Append cases to `matchCompilerTests`:
```haskell
  , testCase "two columns: nested Case with cross-clause fallthrough" $ do
      let oracle = M.ConOracle
            { M.coArity = \t -> if t == T.pack "Cons" then 2 else 0
            , M.coSiblings = \_ -> Just [T.pack "Nil", T.pack "Cons"] }
          ty = Ty.CTCon Ty.TcUnit []
          v  s = M.MPat ty (M.MVar (Just (T.pack s)))
          cons h t = M.MPat ty (M.MCon (T.pack "Cons") [h, t])
          wild = M.MPat ty (M.MVar Nothing)
          jA = Name.JoinId (Name.Unique 200); jB = Name.JoinId (Name.Unique 201)
          rows =
            [ M.Row [cons (v "x") (v "xs"), cons (v "y") (v "ys")] []
                    jA [T.pack "x", T.pack "xs", T.pack "y", T.pack "ys"] 0
            , M.Row [wild, wild] [] jB [] 1 ]
          a1 = Anf.AVar (Name.Name (T.pack "a") (Name.Unique 1))
          a2 = Anf.AVar (Name.Name (T.pack "b") (Name.Unique 2))
          expr = runFresh (M.compileMatch oracle [a1, a2] rows)
      case expr of
        Anf.Case _ alts -> assertBool "nested Case present" (any isNestedCase alts)
        other -> assertFailure ("expected Case, got: " ++ show other)

  , testCase "literal column tests constructor once then switches literal" $ do
      let oracle = M.ConOracle
            { M.coArity = \t -> if t == T.pack "Just" then 1 else 0
            , M.coSiblings = \_ -> Just [T.pack "Just", T.pack "Nothing"] }
          ty = Ty.CTCon Ty.TcUnit []
          just p = M.MPat ty (M.MCon (T.pack "Just") [p])
          lit0 = M.MPat ty (M.MLit (Anf.LInt 0))
          wild = M.MPat ty (M.MVar Nothing)
          none = M.MPat ty (M.MCon (T.pack "Nothing") [])
          j0 = Name.JoinId (Name.Unique 300); j1 = Name.JoinId (Name.Unique 301)
          j2 = Name.JoinId (Name.Unique 302)
          rows =
            [ M.Row [just lit0] [] j0 [] 0
            , M.Row [just wild] [] j1 [] 1
            , M.Row [none]      [] j2 [] 2 ]
          a1 = Anf.AVar (Name.Name (T.pack "m") (Name.Unique 1))
          expr = runFresh (M.compileMatch oracle [a1] rows)
      case expr of
        Anf.Case _ alts -> case [ e | Anf.AltCon c _ e <- alts, c == T.pack "Just" ] of
          (Anf.Case _ inner : _) ->
            assertBool "inner switch is on a literal"
              (any (\x -> case x of Anf.AltLit _ _ -> True; _ -> False) inner)
          _ -> assertFailure "expected a nested Case under AltCon Just"
        other -> assertFailure ("expected Case, got: " ++ show other)
  ]
  where
    isNestedCase (Anf.AltCon _ _ (Anf.Case _ _)) = True
    isNestedCase _                               = False
```

- [ ] **Step 8: Run all match-compiler tests**

Run: `cabal test wok-tests --test-options='-p "MatchCompiler"'`
Expected: PASS (all cases).

- [ ] **Step 9: hlint + commit**

```bash
hlint src/Wok/IR/Match.hs
git add src/Wok/IR/Match.hs wok.cabal test/Spec.hs
git commit -m "feat(ir): pure decision-tree match compiler core (Wok.IR.Match)"
```

---

### Task 2: Exhaustiveness + redundancy analysis (`matchCoverage`)

**Goal:** A pure function over the same matrix that reports redundant clause indices and whether the match is exhaustive, reusing the specialization machinery from Task 1.

**Files:**
- Modify: `src/Wok/IR/Match.hs` (add `Coverage`, `matchCoverage`)
- Test: `test/Spec.hs` (new `matchCoverageTests`)

**Acceptance Criteria:**
- [ ] `matchCoverage` reports `covExhaustive = False` for a single partial clause (`safeHead (x::xs)`).
- [ ] `matchCoverage` reports `covExhaustive = True` when every constructor of a finite type is covered.
- [ ] `matchCoverage` reports a redundant clause index when a later clause is shadowed by an earlier all-variable clause.
- [ ] Literal columns are always treated as non-exhaustive.

**Verify:** `cabal test wok-tests --test-options='-p "MatchCoverage"'` → pass.

**Steps:**

- [ ] **Step 1: Write the failing test**

Add to `test/Spec.hs`:
```haskell
matchCoverageTests :: TestTree
matchCoverageTests = testGroup "MatchCoverage"
  [ testCase "single partial clause is non-exhaustive" $ do
      let oracle = M.ConOracle
            { M.coArity = \t -> if t == T.pack "Cons" then 2 else 0
            , M.coSiblings = \_ -> Just [T.pack "Nil", T.pack "Cons"] }
          ty = Ty.CTCon Ty.TcUnit []
          cons = M.MPat ty (M.MCon (T.pack "Cons")
                   [M.MPat ty (M.MVar (Just (T.pack "x")))
                   ,M.MPat ty (M.MVar (Just (T.pack "xs")))])
          rows = [ M.Row [cons] [] (Name.JoinId (Name.Unique 1)) [T.pack "x", T.pack "xs"] 0 ]
          cov  = M.matchCoverage oracle 1 rows
      M.covExhaustive cov @?= False
      M.covRedundant cov @?= []

  , testCase "redundant later clause under an all-var clause" $ do
      let oracle = M.ConOracle { M.coArity = const 0, M.coSiblings = \_ -> Just [T.pack "A"] }
          ty = Ty.CTCon Ty.TcUnit []
          wild = M.MPat ty (M.MVar Nothing)
          a    = M.MPat ty (M.MCon (T.pack "A") [])
          rows = [ M.Row [wild] [] (Name.JoinId (Name.Unique 1)) [] 0
                 , M.Row [a]    [] (Name.JoinId (Name.Unique 2)) [] 1 ]
          cov  = M.matchCoverage oracle 1 rows
      M.covExhaustive cov @?= True
      M.covRedundant cov @?= [1]
  ]
```
Register `matchCoverageTests` in `defaultMain`.

- [ ] **Step 2: Run to verify it fails**

Run: `cabal test wok-tests --test-options='-p "MatchCoverage"'`
Expected: FAIL — `matchCoverage` not defined.

- [ ] **Step 3: Implement `matchCoverage`**

Add to `src/Wok/IR/Match.hs` (and export `Coverage (..)`, `matchCoverage`). It mirrors the `compileMatch` recursion but tracks only reached rows and whether a fail leaf is reachable; it reuses `chooseColumn`-style logic and `completeHeads`:
```haskell
-- | Result of the Maranget usefulness analysis over a clause matrix.
data Coverage = Coverage
  { covRedundant  :: [Int]   -- ^ original indices of clauses that can never match
  , covExhaustive :: Bool    -- ^ whether the matrix covers every input
  }
  deriving (Eq, Show)

-- | Analyse a matrix for redundancy and exhaustiveness. 'ncols' is the number of
-- argument columns. Patterns only -- no atoms -- so it does not thread scrutinees.
matchCoverage :: ConOracle -> Int -> [Row] -> Coverage
matchCoverage oracle ncols rows =
  let (reached, anyFail) = analyze ncols rows
  in Coverage { covRedundant  = [ rowIndex r | r <- rows, not (rowIndex r `Set.member` reached) ]
              , covExhaustive = not anyFail }
  where
    analyze :: Int -> [Row] -> (Set Int, Bool)
    analyze _ []          = (Set.empty, True)              -- fail reachable
    analyze n rws@(r0 : _)
      | all isWildP (rowPats r0) = (Set.singleton (rowIndex r0), False)
      | otherwise =
          let i     = pickCol n rws
              heads = nubHeads [ rowPats r !! i | r <- rws ]
              nR    = n - 1
              branch h =
                let rows' = case h of
                      MCon c _ -> concatMap (specConP c (coArity oracle c) i) rws
                      MLit l   -> concatMap (specLitP l i) rws
                      MVar _   -> []
                    n' = case h of MCon c _ -> coArity oracle c + nR; _ -> nR
                in analyze n' rows'
              brs = map branch heads
              (defR, defF)
                | completeHeads oracle heads = (Set.empty, False)
                | otherwise =
                    let defRows = [ r { rowPats = removeAt i (rowPats r) }
                                  | r <- rws, MPat _ (MVar _) <- [rowPats r !! i] ]
                    in analyze nR defRows
          in (Set.unions (defR : map fst brs), defF || any snd brs)

    pickCol n rws =
      let idxs       = [0 .. n - 1]
          hasNonWild c = any (not . isWildP . (!! c) . rowPats) rws
          isConCol   c = any (\r -> case rowPats r !! c of MPat _ (MCon _ _) -> True; _ -> False) rws
          cands      = filter hasNonWild idxs
      in case filter isConCol cands of (c : _) -> c; [] -> head cands

    specConP c arity i r = case rowPats r !! i of
      MPat _ (MCon c' subs) | c' == c -> [ r { rowPats = subs ++ removeAt i (rowPats r) } ]
      MPat _ (MCon _ _)               -> []
      MPat _ (MLit _)                 -> []
      MPat _ (MVar _)                 ->
        [ r { rowPats = replicate arity wildField ++ removeAt i (rowPats r) } ]
      where wildField = MPat (CTCon (error "Match.matchCoverage: wildcard type") []) (MVar Nothing)

    specLitP l i r = case rowPats r !! i of
      MPat _ (MLit l') | l' == l -> [ r { rowPats = removeAt i (rowPats r) } ]
      MPat _ (MLit _)            -> []
      MPat _ (MCon _ _)          -> []
      MPat _ (MVar _)            -> [ r { rowPats = removeAt i (rowPats r) } ]
```
The `specConP`/`specLitP`/`pickCol` here duplicate the value-level helpers because coverage threads no atoms. If you prefer strict DRY, factor a shared `specPats :: Text -> Int -> Int -> [MPat] -> Maybe [MPat]`; the duplication is small and localized, so either is acceptable.

- [ ] **Step 4: Run coverage tests to verify they pass**

Run: `cabal test wok-tests --test-options='-p "MatchCoverage"'`
Expected: PASS.

- [ ] **Step 5: hlint + commit**

```bash
hlint src/Wok/IR/Match.hs
git add src/Wok/IR/Match.hs test/Spec.hs
git commit -m "feat(ir): exhaustiveness + redundancy analysis over the clause matrix"
```

---

### Task 3: Widen `TypedDecl` to a clause list; keep all clauses in `finalizeGroupTyped`

**Goal:** `TypedDecl` carries `tdClauses :: [([TPat], TExpr)]` instead of a single `(tdParams, tdBody)`; `finalizeGroupTyped` freezes ALL clauses under one mapping; an arity-agreement check rejects clauses that disagree on argument count.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs` (`TypedDecl` at `:2430`; `finalizeGroupTyped` at `:2126`; `inferTopLetGroup` at `:2516`; `unTLam` at `:2254`)
- Modify: `src/Wok/TypeChecking/Error.hs` (`ClauseArityMismatch`)
- Modify: `src/Wok/IR/Elaborate.hs` (mechanical: read `tdClauses` in `isBodylessSig` and `elabTopBind` — full rewrite is Task 4; here just make it compile)
- Test: `test/Spec.hs` (arity-mismatch unit test; multi-clause-preserved unit test; existing typecheck goldens must stay green)

**Acceptance Criteria:**
- [ ] `TypedDecl` exposes `tdClauses :: [([TPat], TExpr)]`; `tdParams`/`tdBody` are gone.
- [ ] A single-clause binding round-trips as a one-element `tdClauses`.
- [ ] A multi-clause group keeps every clause (`length (tdClauses d) == n`).
- [ ] Clauses disagreeing on arity raise `ClauseArityMismatch`.
- [ ] All existing `typecheck success golden` tests pass unchanged.

**Verify:** `cabal test wok-tests --test-options='-p "typecheck success golden"'` and `-p "ClauseArity"` → pass.

**Steps:**

- [ ] **Step 1: Add the `ClauseArityMismatch` error**

In `src/Wok/TypeChecking/Error.hs`, add to `data TypeError` (near `ArityMismatch` at `:22`):
```haskell
  | ClauseArityMismatch SourceSpan Text Int Int
    -- ^ Two equations for the same name disagree on argument count.
    -- Args: position of the offending equation, function name, the first
    -- equation's arity, this equation's arity.
```
If `TypeError` has a hand-written pretty-printer, mirror the `ArityMismatch` rendering; if it only derives `Show`, no extra work.

- [ ] **Step 2: Write the failing arity-mismatch test**

Add to `test/Spec.hs` a group `clauseArityTests`. Reuse whatever inline-source inference helper the suite already has (search for how `typecheckFailHarness` / `expectOKWithWarnings` build, reorder, and run a module via `Pipeline.typecheckProgram` or `TC.inferProgramWith`) and adapt it to return the `Left TypeError`:
```haskell
clauseArityTests :: TestTree
clauseArityTests = testGroup "ClauseArity"
  [ testCase "equations disagreeing on arity are rejected" $ do
      let src = T.unlines
            [ "module Main", "import Std.Base"
            , "f : U64 -> U64 -> U64"
            , "f 0 = 0"           -- arity 1
            , "f x y = y"         -- arity 2
            ]
      err <- runInferLeft src   -- adapt to the suite's existing Left-returning runner
      assertBool ("expected ClauseArityMismatch, got: " ++ show err) (isClauseArity err)
  ]
  where isClauseArity e = case e of TErr.ClauseArityMismatch{} -> True; _ -> False
```
Register `clauseArityTests` in `defaultMain`.

- [ ] **Step 3: Run to verify it fails**

Run: `cabal test wok-tests --test-options='-p "ClauseArity"'`
Expected: FAIL (currently the second clause is dropped, no error).

- [ ] **Step 4: Add the arity check in `inferTopLetGroup`**

In `src/Wok/TypeChecking/Infer.hs`, inside `inferTopLetGroup` (`:2516`), right after `let groups = groupEquations eqns`, validate each group's equation arities using `lhsAtomPats` (already used at `:2270`):
```haskell
  -- Reject same-named equations that disagree on argument count before any
  -- further work; multi-clause compilation requires a uniform column count.
  forM_ groups $ \(gname, eqs) -> do
    let arities = [ (length (lhsAtomPats lhs), lhsPos lhs) | Abs.LDEqn lhs _ _ <- eqs ]
    case arities of
      []               -> pure ()
      ((a0, _) : rest) -> forM_ rest $ \(a, pos) ->
        when (a /= a0) $ throwError (ClauseArityMismatch pos gname a0 a)
```
Define a local `lhsPos :: Abs.FunLHS -> SourceSpan` that extracts the `BNFC'Position` from the LHS token (mirror how `funLHSName` at `:2007` destructures `Abs.FunLHS`; pull the position out of the `VarId`/`VarSym`/`FunName`). If extracting a precise position is awkward, `Nothing` is a valid `SourceSpan` (`SourceSpan = BNFC'Position`), but prefer the real one.

- [ ] **Step 5: Change `TypedDecl` and `finalizeGroupTyped` to keep all clauses**

Change the record (`:2430`):
```haskell
data TypedDecl = TypedDecl
  { tdName     :: Text
  , tdScheme   :: Scheme
  , tdClauses  :: [([TPat], TExpr)]   -- one entry per equation, in source order
  , tdEvidence :: [(Text, Constraint)]
  }
  deriving (Show)
```

Rewrite the start of `finalizeGroupTyped` (`:2130-2139`) to wrap EVERY clause under one synthetic root so CTGen numbering stays consistent across clauses (Risk #2 in the spec). Replace the first-clause extraction and the synthetic `TLam`:
```haskell
finalizeGroupTyped sigMap (name, tv, eqDecls, accCs) = do
  clausesS <- case eqDecls of
    [] -> error ("finalizeGroupTyped: no typed equations for " ++ Tx.unpack name)
    _  -> pure [ (ps, b) | Ty.TLocalDecl _ ps b <- eqDecls ]
  -- Freeze ALL clauses together under one mapping: a synthetic TLam whose params
  -- are every clause's params concatenated and whose body is a TList of every
  -- clause's body. The wrapper's annotation is the principal type 'tv'. Freezing
  -- is a structural traversal, so a single root gives every clause one consistent
  -- CTGen numbering.
  let arity      = length (fst (head clausesS))
      allParamsS = concatMap fst clausesS
      allBodiesS = map snd clausesS
      synthetic  = Ty.Texp tv (Ty.TLam allParamsS (Ty.Texp tv (Ty.TList allBodiesS)))
  -- ... the rest of both branches (signed at :2141, unsigned at :2212) is
  -- unchanged EXCEPT: where they currently do `let (ps, b) = unTLam name frozen`,
  -- do `let clauses = unClauses name arity frozen` instead, and build
  -- `TypedDecl { ..., tdClauses = clauses, ... }` (drop tdParams/tdBody).
```
Replace `unTLam` (`:2254`) with:
```haskell
-- | Recover the per-clause (params, body) list from the synthetic wrapper that
-- 'finalizeGroupTyped' froze: a TLam over all clauses' params concatenated, whose
-- body is a TList of all clauses' bodies. 'arity' (the uniform column count)
-- re-splits the concatenated params.
unClauses :: Text -> Int -> TExpr -> [([TPat], TExpr)]
unClauses _ arity (Ty.Texp _ (Ty.TLam allParams (Ty.Texp _ (Ty.TList bodies)))) =
  zip (chunk arity allParams) bodies
  where chunk _ [] = []
        chunk n xs = take n xs : chunk n (drop n xs)
unClauses name _ _ = error
  ("finalizeGroupTyped: synthetic clause wrapper lost its shape for " ++ Tx.unpack name)
```
Update BOTH `pure TypedDecl { ... }` sites (signed `:2210`, unsigned `:2239`) to use `tdClauses = unClauses name arity frozen` and drop `tdParams`/`tdBody`. The constraint/evidence logic (`promisedSet`, `accCs` validation, `evParams`) is untouched — it operates on `tv`/`accCs`, not on the surfaced body.

- [ ] **Step 6: Update `sigOnlyBindings` and any other `TypedDecl` constructions**

In `inferTopLetGroup` (`:2522-2531`), the bodyless sentinel becomes:
```haskell
        [ let s = sigMap Map.! n
          in TypedDecl { tdName = n, tdScheme = s
                       , tdClauses = [([], Ty.Texp (schemeBody s) (Ty.TVar n))]
                       , tdEvidence = [] }
        | n <- sigOnlyNames ]
```
Then grep for every other construction/field use and fix mechanically:
```bash
grep -rn "tdParams\|tdBody\|TypedDecl {" src/ test/
```

- [ ] **Step 7: Make `Elaborate` compile against the new shape (temporary; full rewrite in Task 4)**

In `src/Wok/IR/Elaborate.hs`:
- `isBodylessSig` (`:713`):
```haskell
isBodylessSig :: TypedDecl -> Bool
isBodylessSig td = case tdClauses td of
  [([], Texp _ (TVar v))] -> v == tdName td
  _                       -> False
```
- `elabTopBind` (`:735-737`): restore OLD behavior off the first clause so the build is green for single-clause programs:
```haskell
    (params, body) <- case tdClauses td of
      (c : _) -> pure c
      []      -> error ("elaborateModule: no clauses for " <> Tx.unpack (tdName td))
    (paramBinders, extender) <- elabParams params
    bodyExpr <- extender (elabTail body)
    pure (TopBind name (evBinders ++ paramBinders) bodyExpr)
```

- [ ] **Step 8: Build and run the full suite**

Run: `cabal build && cabal test wok-tests`
Expected: PASS. `typecheck success golden` unchanged; `ClauseArity` passes; `anf`/`run` goldens unchanged (single-clause behavior preserved).

- [ ] **Step 9: Add a multi-clause-preserved unit test**

Add `typedDeclClauseTests` to `test/Spec.hs`: infer an inline two-clause function and assert `length (TC.tdClauses d) == 2` for that binding. Register and run:
```bash
cabal test wok-tests --test-options='-p "typedDeclClause"'
```

- [ ] **Step 10: hlint + commit**

```bash
hlint src/Wok/TypeChecking/Infer.hs src/Wok/TypeChecking/Error.hs src/Wok/IR/Elaborate.hs
git add src/Wok/TypeChecking/Infer.hs src/Wok/TypeChecking/Error.hs src/Wok/IR/Elaborate.hs test/Spec.hs
git commit -m "feat(types): TypedDecl carries a clause list; arity-agreement check"
```

---

### Task 4: Elaborate function heads through the match compiler

**Goal:** `elabTopBind` builds one fresh param binder per column, a `LetJoin` per clause body, a `ConOracle` from `Env`, and calls `compileMatch`; single-variable-only (and single-clause record) heads keep the existing cheap path.

**Files:**
- Modify: `src/Wok/IR/Elaborate.hs` (`elabTopBind` at `:725`; add `compileClauses`, `toMPat`, `clauseVars`, `buildOracle`, `irrefutableHead`)
- Test: `test/typecheck-examples/11-multi-clause.wok` + `test/anf-golden/11-multi-clause.expected`; full suite

**Acceptance Criteria:**
- [ ] A multi-clause top-level function elaborates to a `Case` decision tree with one `LetJoin` per clause body.
- [ ] Each leaf is a `Jump` to the correct clause's join point with atoms in variable order.
- [ ] Single-variable-head and single-clause record functions produce byte-identical ANF (all existing `anf golden` / `typed-anf golden` pass).
- [ ] A multi-clause group containing a record-constructor column raises a clear error.

**Verify:** `cabal test wok-tests --test-options='-p "anf golden"'` (unchanged) and `-p "11-multi-clause"` → pass.

**Steps:**

- [ ] **Step 1: Add a failing ANF golden for a multi-clause function**

Create `test/typecheck-examples/11-multi-clause.wok`:
```
module Main
import Std.Base

zipSum : [U64] -> [U64] -> U64
zipSum (x :: xs) (y :: ys) = x + y + zipSum xs ys
zipSum _         _         = 0
```
Run WITHOUT `--accept` first:
Run: `cabal test wok-tests --test-options='-p "11-multi-clause"'`
Expected: FAIL — golden missing AND current elaboration only emits the first clause.

- [ ] **Step 2: Build the `ConOracle` from `Env`**

In `src/Wok/IR/Elaborate.hs`, extend imports and add:
```haskell
import Wok.IR.Match
  ( MPat (..), MPatF (..), Row (..), ConOracle (..), compileMatch, tupleTag )
import Wok.TypeChecking.Env (..., lookupTyCon, TyConInfo (..), conTyCon)  -- extend :17-19

-- | Build the constructor oracle the match compiler needs. Built-in structural
-- tags (TupleN, Nil/Cons) are answered directly; user constructors from the env.
buildOracle :: Env -> ConOracle
buildOracle env = ConOracle
  { coArity = \c ->
      case tupleArity c of
        Just n                       -> n
        Nothing
          | c == Tx.pack "Nil"       -> 0
          | c == Tx.pack "Cons"      -> 2
          | Just ci <- lookupCon c env -> conArity ci
          | otherwise                -> 0
  , coSiblings = \c ->
      case tupleArity c of
        Just n                       -> Just [tupleTag n]
        Nothing
          | c `elem` [Tx.pack "Nil", Tx.pack "Cons"] -> Just [Tx.pack "Nil", Tx.pack "Cons"]
          | Just ci <- lookupCon c env
          , Just ti <- lookupTyCon (conTyCon ci) env -> Just (tcCons ti)
          | otherwise                -> Nothing
  }
  where
    tupleArity t
      | Tx.isPrefixOf (Tx.pack "Tuple") t
      , [(n, "")] <- reads (Tx.unpack (Tx.drop 5 t)) = Just n
      | otherwise = Nothing
```

- [ ] **Step 3: Convert a `TPat` to an `MPat`; reject records**

Add:
```haskell
-- | Normalize a typed head pattern into the match compiler's MPat. Record
-- constructor patterns are rejected: records are single-constructor, so
-- multi-clause dispatch on them is degenerate, and the matrix has no projection
-- lowering. Single-clause record heads never reach here (cheap path).
toMPat :: Env -> TPat -> MPat
toMPat env (Tpat ty pnode) = MPat ty (go pnode)
  where
    go (TPVar v)    = MVar (Just v)
    go TPWild       = MVar Nothing
    go TPUnit       = MVar Nothing
    go (TPLitI i)   = MLit (LInt i)
    go (TPLitS s)   = MLit (LStr s)
    go (TPLitC c)   = MLit (LChar c)
    go (TPTuple ps) = MCon (tupleTag (length ps)) (map (toMPat env) ps)
    go (TPList [])  = MCon (Tx.pack "Nil") []
    go (TPList _)   = error "match: non-empty list literal pattern (use h :: t)"
    go (TPCons h t) = MCon (Tx.pack "Cons") [toMPat env h, toMPat env t]
    go (TPCon c ps) = case lookupRecordCon c env of
      Just _  -> error ("match: record-constructor pattern not supported in a "
                        <> "multi-clause / refutable head: " <> Tx.unpack c)
      Nothing -> MCon c (map (toMPat env) ps)
```

- [ ] **Step 4: Collect a clause's variable order (join-param order)**

Add:
```haskell
-- | The variables a head-pattern list binds, left-to-right: the order the
-- clause body's join point expects its params, and the order leaves Jump in.
clauseVars :: [TPat] -> [(Text, CType)]
clauseVars = concatMap patVars
  where
    patVars (Tpat ty (TPVar v))    = [(v, ty)]
    patVars (Tpat _  (TPTuple ps)) = concatMap patVars ps
    patVars (Tpat _  (TPList ps))  = concatMap patVars ps
    patVars (Tpat _  (TPCons h t)) = patVars h ++ patVars t
    patVars (Tpat _  (TPCon _ ps)) = concatMap patVars ps
    patVars _                      = []   -- wildcard / unit / literal bind nothing
```

- [ ] **Step 5: Write `compileClauses` — build join points and call the compiler**

Add:
```haskell
-- | Elaborate a clause group into a decision tree. Mints one fresh param binder
-- per column, one LetJoin per clause body (params = that clause's variables, L-to-R),
-- then asks the match compiler for the tree and wraps it in the joins.
compileClauses :: [([TPat], TExpr)] -> Elab ([Binder], Expr)
compileClauses clauses = do
  env <- asks ecEnv
  let colTypes = map (\(Tpat ty _) -> ty) (fst (head clauses))
      arity    = length colTypes
  paramNames <- mapM (const (bindFresh (Tx.pack "p"))) [1 .. arity]
  let paramBinders = zipWith (\n t -> Binder n Unrestricted t) paramNames colTypes
      scruts       = map AVar paramNames
  -- Per clause: mint a join id + a binder per bound variable, elaborate the body
  -- with those vars in scope. 'built' :: [(JoinId, [(Text, CType, Name)], Expr)]
  built <- mapM buildClauseJoin clauses
  let rows = [ Row { rowPats  = map (toMPat env) ps
                   , rowSubst = []
                   , rowJoin  = jid
                   , rowOrder = [ v | (v, _, _) <- vars ]
                   , rowIndex = ix }
             | (ix, (ps, _), (jid, vars, _)) <- zip3 [0 ..] clauses built ]
  tree <- lift (compileMatch (buildOracle env) scruts rows)
  let wrapped = foldr
        (\(jid, vars, jbody) acc ->
            LetJoin jid [ Binder n Unrestricted t | (_, t, n) <- vars ] jbody acc)
        tree built
  pure (paramBinders, wrapped)
  where
    buildClauseJoin (ps, body) = do
      jid <- lift freshJoin
      triples <- mapM (\(v, t) -> do n <- bindFresh v; pure (v, t, n)) (clauseVars ps)
      jbody <- withLocals [ (v, n) | (v, _, n) <- triples ] (elabTail body)
      pure (jid, triples, jbody)
```
`rowOrder` (variable names, from `clauseVars ps`) and the join binder order (`triples`, also from `clauseVars ps`) derive from the same list, so the Jump's positional atoms line up with the join params.

- [ ] **Step 6: Route `elabTopBind` between cheap path and match compiler**

Replace the temporary body from Task 3 Step 7 in `elabTopBind` (`:734-737`):
```haskell
  local (\ctx -> ctx { ecEvidence = evScope, ecEvidenceIdx = evIdx }) $ do
    env <- asks ecEnv
    (paramBinders, bodyExpr) <- case tdClauses td of
      [(params, body)]
        | all (irrefutableHead env) params -> do
            -- cheap path: single clause, all heads var/wild/unit or a record
            -- constructor pattern -> reuse elabParams verbatim (byte-identical ANF).
            (pbs, extender) <- elabParams params
            be <- extender (elabTail body)
            pure (pbs, be)
      clauses -> compileClauses clauses
    pure (TopBind name (evBinders ++ paramBinders) bodyExpr)
```
Add the routing predicate:
```haskell
-- | A head pattern the cheap 'elabParams' path handles without cross-clause
-- fallthrough: a plain variable / wildcard / unit, or a record constructor
-- pattern (single-constructor, irrefutable; kept on the projection path because
-- the matrix does not lower records).
irrefutableHead :: Env -> TPat -> Bool
irrefutableHead env (Tpat _ pnode) = case pnode of
  TPVar _   -> True
  TPWild    -> True
  TPUnit    -> True
  TPCon c _ -> case lookupRecordCon c env of Just _ -> True; Nothing -> False
  _         -> False
```
The cheap path triggers only for a SINGLE clause (the `[(params, body)]` pattern). Any multi-clause group falls to `compileClauses`, even when every head is a variable (two all-var clauses means the second is redundant — handled by `compileMatch`, warned by Task 5).

- [ ] **Step 7: Confirm imports**

Ensure `freshJoin` is imported from `Wok.IR.Name`; `bindFresh`, `withLocals`, `lift`, `elabParams`, `elabTail`, `lookupRecordCon` are already in scope. `compileMatch` runs in `Fresh = State Int` and `Elab = ReaderT ElabCtx (State Int)`, so `lift (compileMatch ...)` is correct.

- [ ] **Step 8: Generate and inspect the new golden**

Run: `cabal build && cabal test wok-tests --test-options='-p "11-multi-clause" --accept'`
Open `test/anf-golden/11-multi-clause.expected` and confirm by eye: a `Case` on the first param; the `Cons` branch nests a `Case` on the second param; two `join` definitions; `jump` leaves with the right atoms.

- [ ] **Step 9: Run the full suite — existing goldens must be unchanged**

Run: `cabal test wok-tests`
Expected: PASS. If any pre-existing `anf golden` / `typed-anf golden` changed, STOP — single-clause routing must be byte-identical. The only NEW golden is `11-multi-clause`.

- [ ] **Step 10: hlint + commit**

```bash
hlint src/Wok/IR/Elaborate.hs
git add src/Wok/IR/Elaborate.hs test/typecheck-examples/11-multi-clause.wok test/anf-golden/11-multi-clause.expected
git commit -m "feat(ir): elaborate multi-clause function heads via the match compiler"
```

---

### Task 5: Wire exhaustiveness + redundancy warnings into type checking

**Goal:** Emit `NonExhaustiveMatch` and `RedundantClause` warnings during type checking, computed by `matchCoverage` over the typed clauses, using a `ConOracle` built from the env.

**Files:**
- Modify: `src/Wok/TypeChecking/Error.hs` (two new `Warning` variants)
- Modify: `src/Wok/TypeChecking/Infer.hs` (run coverage in `inferTopLetGroup`; `addWarning`)
- Test: `test/Spec.hs` (new `matchWarningTests`)

**Acceptance Criteria:**
- [ ] A partial top-level function (`safeHead (x::xs)` only) emits exactly one `NonExhaustiveMatch` for that name.
- [ ] A fully-covered function emits no `NonExhaustiveMatch`.
- [ ] A shadowed later clause emits a `RedundantClause` naming the clause index.
- [ ] Warnings flow out through the same pipeline channel `BodylessBinding` uses.

**Verify:** `cabal test wok-tests --test-options='-p "MatchWarnings"'` → pass.

**Steps:**

- [ ] **Step 1: Add the warning variants**

In `src/Wok/TypeChecking/Error.hs`, extend `data Warning` (`:121`):
```haskell
  | NonExhaustiveMatch SourceSpan Text
    -- ^ A function's clause group does not cover all inputs. Args: position, name.
  | RedundantClause SourceSpan Text Int
    -- ^ A clause can never match (shadowed). Args: position, name, 0-based clause index.
```

- [ ] **Step 2: Write failing warning tests**

Add to `test/Spec.hs` (model on `patternCoverageTests` at `:3162`, which uses `expectOKWithWarnings`):
```haskell
matchWarningTests :: TestTree
matchWarningTests = testGroup "MatchWarnings"
  [ testCase "partial single clause warns non-exhaustive" $ do
      let src = T.unlines
            [ "module Main", "import Std.Base"
            , "safeHead : [U64] -> U64"
            , "safeHead (x :: xs) = x" ]
      (_, ws) <- expectOKWithWarnings src
      length [ () | TErr.NonExhaustiveMatch _ n <- ws, n == T.pack "safeHead" ] @?= 1

  , testCase "total function: no non-exhaustive warning" $ do
      let src = T.unlines
            [ "module Main", "import Std.Base"
            , "isNil : [U64] -> Bool"
            , "isNil []        = True"
            , "isNil (x :: xs) = False" ]
      (_, ws) <- expectOKWithWarnings src
      length [ () | TErr.NonExhaustiveMatch _ _ <- ws ] @?= 0

  , testCase "shadowed clause warns redundant" $ do
      let src = T.unlines
            [ "module Main", "import Std.Base"
            , "f : U64 -> U64"
            , "f x = x"
            , "f 0 = 0" ]
      (_, ws) <- expectOKWithWarnings src
      length [ () | TErr.RedundantClause _ n _ <- ws, n == T.pack "f" ] @?= 1
  ]
```
Confirm `expectOKWithWarnings` returns the entry module's warnings (used at `Spec.hs:3171`). Register `matchWarningTests`.

- [ ] **Step 3: Run to verify they fail**

Run: `cabal test wok-tests --test-options='-p "MatchWarnings"'`
Expected: FAIL — no such warnings emitted yet.

- [ ] **Step 4: Build a TC-side oracle and run coverage**

In `src/Wok/TypeChecking/Infer.hs`, add `buildMatchOracle :: Env -> ConOracle` (same logic as Task 4's `buildOracle`; import `Wok.IR.Match (ConOracle (..), Row (..), Coverage (..), matchCoverage)` and `MPat`/`MPatF`). Add `typedPatToMPat :: Env -> TPat -> MPat` (same as `toMPat`, but for coverage treat a record-constructor pattern as `MVar Nothing` — irrefutable — so a single record clause counts as total). Then in `inferTopLetGroup` (`:2516`), after `topResults` is built, emit warnings:
```haskell
  cenv <- currentEnv
  let oracle = buildMatchOracle cenv
  forM_ (zip groups topResults) $ \((gname, eqs), td) ->
    case tdClauses td of
      []      -> pure ()
      clauses -> do
        let arity = length (fst (head clauses))
            rows  = [ Row { rowPats  = map (typedPatToMPat cenv) ps
                          , rowSubst = []
                          , rowJoin  = JoinId (Unique 0)   -- unused by coverage
                          , rowOrder = []
                          , rowIndex = ix }
                    | (ix, (ps, _)) <- zip [0 ..] clauses ]
            cov = matchCoverage oracle arity rows
            pos = case eqs of (Abs.LDEqn lhs _ _ : _) -> lhsPos lhs; _ -> Nothing
        when (not (covExhaustive cov)) $ addWarning (NonExhaustiveMatch pos gname)
        forM_ (covRedundant cov) $ \ix -> addWarning (RedundantClause pos gname ix)
```
Reuse `lhsPos` from Task 3 Step 4. Import `JoinId (..)`/`Unique (..)` from `Wok.IR.Name` for the placeholder join. (`addWarning` writes to `ctxWarnings`, the same channel `BodylessBinding` uses at `:2535`.)

- [ ] **Step 5: Run the warning tests**

Run: `cabal build && cabal test wok-tests --test-options='-p "MatchWarnings"'`
Expected: PASS.

- [ ] **Step 6: Run the full suite (no regressions)**

Run: `cabal test wok-tests`
Expected: PASS. Existing `PatternCoverage` (record warnings) untouched; no new warnings on existing total functions. (If a previously-existing total single-clause function now warns, check `typedPatToMPat`/oracle handling of its constructors.)

- [ ] **Step 7: hlint + commit**

```bash
hlint src/Wok/TypeChecking/Error.hs src/Wok/TypeChecking/Infer.hs
git add src/Wok/TypeChecking/Error.hs src/Wok/TypeChecking/Infer.hs test/Spec.hs
git commit -m "feat(types): non-exhaustive + redundant-clause warnings via usefulness check"
```

---

### Task 6: End-to-end run goldens

**Goal:** Prove multi-clause functions execute correctly end-to-end (parse -> typecheck -> elaborate -> interpret), covering the spec's headline cases.

**Files:**
- Create: `test/run-examples/11-multi-clause-zip.wok`, `12-maybe-literal.wok`, `13-safe-head.wok`
- Create: corresponding `test/run-golden/*.expected` (auto-discovered, `Spec.hs:63`)

**Acceptance Criteria:**
- [ ] A two-column `zip`-style function returns the correct result.
- [ ] `Some 0 / Some _ / None` literal fallthrough returns the right branch per input without crashing.
- [ ] All three programs run and match their goldens.

**Verify:** `cabal test wok-tests --test-options='-p "run golden"'` → pass.

**Steps:**

- [ ] **Step 1: Create the zip program**

`test/run-examples/11-multi-clause-zip.wok`:
```
module Main
import Std.Base

sumPairs : [U64] -> [U64] -> U64
sumPairs (x :: xs) (y :: ys) = x + y + sumPairs xs ys
sumPairs _         _         = 0

main = sumPairs (1 :: 2 :: 3 :: []) (10 :: 20 :: 30 :: [])
```
Expected `66`. Check the rendered-value form against an existing run golden (e.g. `test/run-golden/04-list-length.expected`) before hand-writing.

- [ ] **Step 2: Create the literal-fallthrough program**

`test/run-examples/12-maybe-literal.wok`:
```
module Main
import Std.Base

describe : Option U64 -> U64
describe (Some 0) = 100
describe (Some _) = 200
describe None     = 300

main = describe (Some 0)
```
Expected `100`. Confirm the prelude spells the type `Option`/`Some`/`None` exactly — check `test/run-examples/06-maybe.wok`.

- [ ] **Step 3: Create the partial-but-reached safe-head program**

`test/run-examples/13-safe-head.wok`:
```
module Main
import Std.Base

headOr0 : [U64] -> U64
headOr0 (x :: xs) = x
headOr0 []        = 0

main = headOr0 (7 :: 8 :: [])
```
Expected `7`.

- [ ] **Step 4: Generate the goldens and inspect**

Run: `cabal test wok-tests --test-options='-p "run golden" --accept'`
Open each new `.expected` and confirm `66`, `100`, `7`. If any differs, the program is wrong — fix it, re-accept.

- [ ] **Step 5: Run the run-golden group fresh**

Run: `cabal test wok-tests --test-options='-p "run golden"'`
Expected: PASS (including the three new programs).

- [ ] **Step 6: Full suite + commit**

Run: `cabal test wok-tests`
Expected: PASS.
```bash
git add test/run-examples/11-multi-clause-zip.wok test/run-examples/12-maybe-literal.wok test/run-examples/13-safe-head.wok test/run-golden/11-multi-clause-zip.expected test/run-golden/12-maybe-literal.expected test/run-golden/13-safe-head.expected
git commit -m "test(run): end-to-end multi-clause goldens (zip, literal fallthrough, safe-head)"
```

- [ ] **Step 7: Update the silent-drop memory note**

Edit `/Users/zy/.claude/projects/-Users-zy-wokml/memory/multi-clause-not-implemented.md`: mark it resolved (top-level multi-clause now compiles via `Wok.IR.Match`), noting the residual limitations (records, local clause groups, body-`case` unification) so the index stays accurate. Update the `MEMORY.md` pointer line accordingly.

---

## Self-review notes

- **Spec coverage:** Component 1 (clause list + arity check) -> Task 3. Component 2 (`Wok/IR/Match.hs`, `compileMatch`) -> Task 1. Component 3 (Elaborate hookup, cheap path preserved) -> Task 4. Component 4 (exhaustiveness/redundancy warnings, new `Error.hs` variants) -> Tasks 2 + 5. Component 5 (golden tests: safeHead, zip, `Just 0`/`Just _`/`Nothing`, warnings, behavior-preservation sweep) -> Tasks 1/2 unit tests + Task 4 ANF golden + Task 5 warning tests + Task 6 run goldens; behavior-preservation = "full suite unchanged" gate in Tasks 3/4.
- **Non-goals respected:** no guards, no or-patterns, non-empty list literals still rejected (`toMPat`/`elabPatF`), no hash-consing (join points only).
- **Type consistency:** `compileMatch`, `matchCoverage`, `Coverage`, `Row`, `ConOracle`, `MPat`/`MPatF` used identically across Tasks 1, 2, 4, 5. `tdClauses` replaces `tdParams`/`tdBody` consistently from Task 3 onward. `ClauseArityMismatch`/`NonExhaustiveMatch`/`RedundantClause` introduced once and referenced by the matching tests.
- **Known residual limitations (documented, intentional):** record-constructor columns unsupported in multi-clause/refutable position; local (`where`/`let`) function clause groups unchanged; body `case` expressions still use the existing `elabCaseAlt` path (unifying them with the matrix compiler is future work, per the spec's effect-handler note); single-clause refutable non-record heads now route through the match compiler, gaining a proper fail leaf plus a `NonExhaustiveMatch` warning.
