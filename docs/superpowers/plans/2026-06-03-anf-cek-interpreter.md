# ANF CEK Interpreter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute an elaborated `CoreModule` (Scope B output) so a `.wok` program actually runs — including algebraic-effect handlers — validated by golden program-output tests. No codegen.

**Architecture:** A small-step CEK/CESK machine over `Wok.IR.Anf.Expr`. The control is an `Expr` (or a returning `Value`), the environment maps `Unique -> Value`, and the continuation `Kont` is an explicit heap-allocated stack of frames. Effect handlers are `KHandle` frames; an operation captures the delimited continuation between the call and its handler as a re-invocable `VCont`, which is exactly why CEK was chosen over a host-recursion evaluator (multi-shot `resume` and abort fall out for free). v1 is **pure**: no IO primitives; `main` runs to a `Value` that is rendered. Effects are discharged entirely by user handlers.

**Tech Stack:** Haskell (GHC2024, `Strict`/`StrictData`), `Data.Map.Strict` keyed on `Wok.IR.Name.Unique`, `tasty`/`tasty-hunit` for unit tests, `tasty-golden` for program-output goldens. New modules live under `src/Wok/Interp/`.

---

## Design decisions (read before Task 1)

These are settled; do not re-litigate them while implementing.

- **Pure machine, pure prims.** No `IO`. The machine is `step :: PrimTable -> Config -> Either RuntimeError Step`. `main` must take no arguments and evaluate to a `Value`. Any effects in `main` must be fully discharged by handlers. (IO/`print` is explicitly future work.)
- **Value resolution.** An `AVar n` resolves by `nameUniq n` in the environment first; if absent, by `nameHint n` in the `PrimTable` (this is how bodyless globals like `+` become `VPrim`); else `UnboundVar`. Local uniques never collide with prim hints because prim names are never *bound* in the env.
- **Constructors are tags, never env entries.** Elaboration emits `RCon "True" []`, `RCon "Cons" [..]`, `RCon "Tuple2" [..]`, etc. Bool/list/tuple are just `VCon`. No constructor ever flows through the environment or the prim table.
- **Currying.** `RApp` is n-ary but NOT guaranteed saturated for functions (only constructors are saturated by elaboration). `enter` handles under-application (returns a partial `VClosure`), exact application, and over-application (pushes a `KApp` frame).
- **Recursive knot needs a lazy field.** Top-level mutual recursion and `LetRec` build an environment whose closures capture that same environment. Under the repo-wide `StrictData`, `Data.Map.Strict.insert` forces inserted values to WHNF; if `VClosure`'s env field were strict this would loop. The env field is therefore declared lazy with a leading `~`. This is load-bearing — keep it.
- **Deep handlers, multi-shot.** On an operation, the frames between the op and the nearest matching `KHandle` are captured as a builder `Kont -> Kont`. `resume v` (called at continuation `kCur`) runs `Return v (above (KHandle h hScope kCur))` — i.e. the delimited frames spliced over the *re-installed* handler whose below-continuation is the resume call's own continuation. Because the builder, handler, and scope are immutable, `resume` is naturally multi-shot, and not calling it is abort.
- **Surface handlers always auto-resume.** Scope B's elaborator wraps every op arm as `let res = resume(armValue) in deliver res`. So source-level golden programs exercise only single auto-resume. Abort and multi-shot are proven by machine-level unit tests that construct `Handler`/`OpArm` ANF directly.
- **Module layout.** `Wok/Interp/Value.hs` (all mutually-recursive runtime types + rendering + atom resolution), `Wok/Interp/Prim.hs` (the primitive table), `Wok/Interp/Machine.hs` (`step`/`run`/`enter`/effect dispatch/`runModule`), `Wok/Interp.hs` (thin facade re-export). `Value`, `Kont`, `Prim`, and `JoinPoint` are mutually recursive, so they MUST share one module.

---

## File structure

| File | Responsibility |
|------|----------------|
| `src/Wok/Interp/Value.hs` (create) | Runtime `Value`, `Env`, `Scope`, `JoinEnv`/`JoinPoint`, `Kont`, `Config`, `Step`, `Prim`, `PrimResult`, `PrimTable`, `RuntimeError`; `resolveAtom`, `bindBinder`, `bindBinders`, `renderValue`. |
| `src/Wok/Interp/Prim.hs` (create) | `primTable :: PrimTable` — native impls of `+ - * / div mod == /= && || ++ $`. |
| `src/Wok/Interp/Machine.hs` (create) | `step`, `run`, `enter`, `evalExpr`/`evalRhs`/`matchAlts`, effect dispatch (`findHandler`, `dispatchOp`), `runModule`, `evalExprWith` (test seam). |
| `src/Wok/Interp.hs` (create) | Facade: re-export `runModule`, `renderValue`, `RuntimeError`. |
| `wok.cabal` (modify) | Add the four modules to `exposed-modules`. |
| `app/Main.hs` (modify) | Add `--run` CLI mode. |
| `test/Spec.hs` (modify) | New test groups + `run golden` group. |
| `test/run-examples/*.wok` (create) | Runnable fixtures with `main`. |
| `test/run-golden/*.expected` (create) | Golden rendered outputs. |

---

## Task 1: Runtime value types, environment, rendering

**Goal:** Create `Wok/Interp/Value.hs` with the mutually-recursive runtime types, atom resolution, binder helpers, and a deterministic `renderValue`; wire the module into cabal.

**Files:**
- Create: `src/Wok/Interp/Value.hs`
- Modify: `wok.cabal` (add `Wok.Interp.Value` to library `exposed-modules`)
- Test: `test/Spec.hs` (add `interpValueTests`, register it in `main`)

**Acceptance Criteria:**
- [ ] `cabal build` succeeds with the new module.
- [ ] `renderValue` renders ints, strings, unit, `True`/`False`, lists, tuples, records, and opaque values deterministically.
- [ ] `resolveAtom` resolves a local binding by `Unique`, falls back to the prim table by hint, and errors `UnboundVar` otherwise.
- [ ] `interpValueTests` passes.

**Verify:** `cabal test --test-options='-p "InterpValue"'` → all cases pass.

**Steps:**

- [ ] **Step 1: Write `src/Wok/Interp/Value.hs`**

```haskell
module Wok.Interp.Value
  ( Value (..)
  , Env
  , JoinEnv
  , JoinPoint (..)
  , Scope (..)
  , emptyScope
  , Kont (..)
  , Config (..)
  , Step (..)
  , Prim (..)
  , PrimResult (..)
  , PrimTable
  , RuntimeError (..)
  , resolveAtom
  , bindBinder
  , bindBinders
  , renderValue
  ) where

import Data.List (foldl')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf (Atom (..), Binder (..), Expr, Handler (..), Lit (..))
import Wok.IR.Name (JoinId, Name (..), Unique, nameHint, nameUniq)

-- | Environment: identity (Unique) -> runtime value.
type Env = Map Unique Value

-- | Join points in scope (local labelled continuations).
type JoinEnv = Map JoinId JoinPoint

-- | Primitive lookup table, keyed by the bodyless global's hint text.
type PrimTable = Map Text Prim

-- | A lexical scope: term bindings plus join points.
data Scope = Scope { scEnv :: Env, scJoins :: JoinEnv }

emptyScope :: Scope
emptyScope = Scope Map.empty Map.empty

-- | Runtime values. NOTE: the VClosure environment field is LAZY (leading ~)
-- so the recursive knot for top-level mutual recursion and LetRec can be tied
-- under the repo-wide StrictData (Data.Map.Strict.insert forces values to WHNF;
-- a strict env field would make the self-referential insert diverge).
data Value
  = VLit Lit
  | VCon Text [Value]
  | VRecord Text (Map Text Value)
  | VClosure ~Env [Binder] Expr
  | VPrim Prim
  | VCont (Kont -> Kont)   -- a captured deep continuation; arg is the post-resume kont

-- | A primitive: name (= hint), arity, args accumulated so far (for currying),
-- and the saturated implementation.
data Prim = Prim
  { primName  :: Text
  , primArity :: Int
  , primArgs  :: [Value]
  , primFn    :: [Value] -> Either RuntimeError PrimResult
  }

-- | A saturated primitive either produces a value or asks the machine to apply
-- one value to others (this is how ($) is expressed without host recursion).
data PrimResult = PRDone Value | PRApply Value [Value]

-- | A labelled local continuation: the scope and continuation captured where
-- the join was defined, plus its parameters and body.
data JoinPoint = JoinPoint Scope [Binder] Expr Kont

-- | The continuation stack.
data Kont
  = KDone
  | KLet Binder Expr Scope Kont   -- bind the produced value to Binder, then run Expr in Scope
  | KApp [Value] Kont             -- over-application: apply the produced value to these args
  | KHandle Handler Scope Kont    -- effect delimiter

-- | Machine configuration.
data Config
  = Eval Expr Scope Kont
  | Return Value Kont

-- | One step result.
data Step = More Config | Done Value

data RuntimeError
  = UnboundVar Text
  | NotAFunction Text
  | NonExhaustiveCase Text
  | NoMatchingHandler Text Text
  | BadProjection Text
  | PrimError Text
  | ArityError Text
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Atom resolution and binder helpers

-- | Resolve an atom: literal -> value; variable -> env by Unique, else prim
-- table by hint, else UnboundVar.
resolveAtom :: PrimTable -> Scope -> Atom -> Either RuntimeError Value
resolveAtom _     _  (ALit l) = Right (VLit l)
resolveAtom prims sc (AVar n) =
  case Map.lookup (nameUniq n) (scEnv sc) of
    Just v  -> Right v
    Nothing -> case Map.lookup (nameHint n) prims of
      Just p  -> Right (VPrim p)
      Nothing -> Left (UnboundVar (nameHint n))

bindBinder :: Binder -> Value -> Env -> Env
bindBinder b v = Map.insert (nameUniq (bndName b)) v

bindBinders :: [Binder] -> [Value] -> Env -> Env
bindBinders bs vs env = foldl' (\e (b, v) -> bindBinder b v e) env (zip bs vs)

-- ---------------------------------------------------------------------------
-- Rendering (deterministic; used by tests and program output)

renderValue :: Value -> Text
renderValue (VLit l) = renderLit l
renderValue (VCon "Nil" [])        = Tx.pack "[]"
renderValue v@(VCon "Cons" [_, _]) = renderList v
renderValue (VCon tag vs)
  | Just n <- tupleArity tag, length vs == n =
      Tx.pack "(" <> Tx.intercalate (Tx.pack ", ") (map renderValue vs) <> Tx.pack ")"
renderValue (VCon c [])  = c
renderValue (VCon c vs)  =
  c <> Tx.pack "(" <> Tx.intercalate (Tx.pack ", ") (map renderValue vs) <> Tx.pack ")"
renderValue (VRecord t m) =
  t <> Tx.pack " { "
    <> Tx.intercalate (Tx.pack ", ")
         [ l <> Tx.pack " = " <> renderValue fv | (l, fv) <- Map.toList m ]
    <> Tx.pack " }"
renderValue VClosure{} = Tx.pack "<closure>"
renderValue VPrim{}    = Tx.pack "<builtin>"
renderValue VCont{}    = Tx.pack "<continuation>"

renderLit :: Lit -> Text
renderLit (LInt n)  = Tx.pack (show n)
renderLit (LStr s)  = Tx.pack (show s)
renderLit (LChar c) = Tx.pack (show c)
renderLit LUnit     = Tx.pack "()"

-- | Render a proper Cons/Nil list as [a, b, c]. An improper tail renders the
-- remainder after a '|' so malformed lists are still total and visible.
renderList :: Value -> Text
renderList = go []
  where
    go acc (VCon "Nil" [])        = Tx.pack "[" <> Tx.intercalate (Tx.pack ", ") (reverse acc) <> Tx.pack "]"
    go acc (VCon "Cons" [h, t])   = go (renderValue h : acc) t
    go acc other                  =
      Tx.pack "[" <> Tx.intercalate (Tx.pack ", ") (reverse acc)
        <> Tx.pack " | " <> renderValue other <> Tx.pack "]"

-- | If the tag is "TupleN", return N.
tupleArity :: Text -> Maybe Int
tupleArity t = case Tx.stripPrefix (Tx.pack "Tuple") t of
  Just rest | not (Tx.null rest), Tx.all (`elem` ['0' .. '9']) rest -> Just (read (Tx.unpack rest))
  _ -> Nothing
```

- [ ] **Step 2: Add the module to `wok.cabal`**

In the hand-written `library` stanza's `exposed-modules`, add (after `Wok.IR.Elaborate`):

```
        Wok.Interp.Value
```

- [ ] **Step 3: Verify it builds**

Run: `cabal build`
Expected: compiles cleanly (no warnings — the library is `-Werror`).

- [ ] **Step 4: Write `interpValueTests` in `test/Spec.hs`**

Add this import near the other interp-relevant imports (top of `test/Spec.hs`):

```haskell
import qualified Wok.Interp.Value as IV
```

Add the test group (place it after `anfTests` in the file):

```haskell
interpValueTests :: TestTree
interpValueTests = testGroup "InterpValue"
  [ testCase "render int" $
      IV.renderValue (IV.VLit (Anf.LInt 42)) @?= T.pack "42"
  , testCase "render unit" $
      IV.renderValue (IV.VLit Anf.LUnit) @?= T.pack "()"
  , testCase "render True" $
      IV.renderValue (IV.VCon (T.pack "True") []) @?= T.pack "True"
  , testCase "render empty list" $
      IV.renderValue (IV.VCon (T.pack "Nil") []) @?= T.pack "[]"
  , testCase "render cons list [1, 2]" $
      let lst = IV.VCon (T.pack "Cons")
                  [ IV.VLit (Anf.LInt 1)
                  , IV.VCon (T.pack "Cons") [IV.VLit (Anf.LInt 2), IV.VCon (T.pack "Nil") []] ]
      in IV.renderValue lst @?= T.pack "[1, 2]"
  , testCase "render tuple (1, 2)" $
      IV.renderValue (IV.VCon (T.pack "Tuple2") [IV.VLit (Anf.LInt 1), IV.VLit (Anf.LInt 2)])
        @?= T.pack "(1, 2)"
  , testCase "render saturated constructor" $
      IV.renderValue (IV.VCon (T.pack "Some") [IV.VLit (Anf.LInt 7)])
        @?= T.pack "Some(7)"
  , testCase "resolveAtom: local binding wins by Unique" $
      let n  = runFresh (freshName (T.pack "x"))
          sc = IV.Scope (Map.fromList [(nameUniqOf n, IV.VLit (Anf.LInt 9))]) Map.empty
      in case IV.resolveAtom Map.empty sc (Anf.AVar n) of
           Right v -> IV.renderValue v @?= T.pack "9"
           Left e  -> assertFailure (show e)
  , testCase "resolveAtom: falls back to prim table by hint" $
      let n  = runFresh (freshName (T.pack "+"))
          p  = IV.Prim (T.pack "+") 2 [] (\_ -> Left (IV.PrimError (T.pack "unused")))
          pt = Map.fromList [(T.pack "+", p)]
      in case IV.resolveAtom pt IV.emptyScope (Anf.AVar n) of
           Right (IV.VPrim q) -> IV.primName q @?= T.pack "+"
           Right _            -> assertFailure "expected VPrim"
           Left e             -> assertFailure (show e)
  , testCase "resolveAtom: unbound errors" $
      let n = runFresh (freshName (T.pack "ghost"))
      in IV.resolveAtom Map.empty IV.emptyScope (Anf.AVar n)
           @?= Left (IV.UnboundVar (T.pack "ghost"))
  ]
  where
    nameUniqOf = Name.nameUniq
```

Add the helper import if not present:

```haskell
import qualified Wok.IR.Name as Name
```

Register `interpValueTests` in the big `testGroup "wok" [ ... ]` list in `main` (add it after `anfTests`).

- [ ] **Step 5: Run the tests**

Run: `cabal test --test-options='-p "InterpValue"'`
Expected: `InterpValue` group all pass.

- [ ] **Step 6: Commit**

```bash
git add src/Wok/Interp/Value.hs wok.cabal test/Spec.hs
git commit -m "feat(interp): runtime Value types, env, and renderValue"
```

---

## Task 2: Primitive table

**Goal:** Create `Wok/Interp/Prim.hs` providing native implementations for every bodyless `Std.Base` operator, keyed by hint text.

**Files:**
- Create: `src/Wok/Interp/Prim.hs`
- Modify: `wok.cabal` (add `Wok.Interp.Prim`)
- Test: `test/Spec.hs` (add `interpPrimTests`, register in `main`)

**Acceptance Criteria:**
- [ ] `primTable` contains exactly `+ - * / div mod == /= && || ++ $`.
- [ ] Arithmetic, comparison (returns `VCon True/False`), boolean, list-append, and `$` impls are correct.
- [ ] Division/modulo by zero produces a `PrimError`, not a Haskell exception.
- [ ] `interpPrimTests` passes.

**Verify:** `cabal test --test-options='-p "InterpPrim"'` → all cases pass.

**Steps:**

- [ ] **Step 1: Write `src/Wok/Interp/Prim.hs`**

```haskell
module Wok.Interp.Prim
  ( primTable
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf (Lit (..))
import Wok.Interp.Value
  ( Prim (..), PrimResult (..), PrimTable, RuntimeError (..), Value (..), renderValue )

primTable :: PrimTable
primTable = Map.fromList [ (primName p, p) | p <- prims ]

prims :: [Prim]
prims =
  [ arith (Tx.pack "+")   (+)
  , arith (Tx.pack "-")   (-)
  , arith (Tx.pack "*")   (*)
  , divLike (Tx.pack "/")
  , divLike (Tx.pack "div")
  , modLike (Tx.pack "mod")
  , cmp (Tx.pack "==") (==)
  , cmp (Tx.pack "/=") (/=)
  , boolOp (Tx.pack "&&") (&&)
  , boolOp (Tx.pack "||") (||)
  , appendP
  , dollarP
  ]

mkPrim :: Text -> Int -> ([Value] -> Either RuntimeError PrimResult) -> Prim
mkPrim name arity fn = Prim name arity [] fn

asInt :: Value -> Either RuntimeError Integer
asInt (VLit (LInt n)) = Right n
asInt v = Left (PrimError (Tx.pack "expected U64, got " <> renderValue v))

asBool :: Value -> Either RuntimeError Bool
asBool (VCon t []) | t == Tx.pack "True"  = Right True
                   | t == Tx.pack "False" = Right False
asBool v = Left (PrimError (Tx.pack "expected Bool, got " <> renderValue v))

boolVal :: Bool -> Value
boolVal True  = VCon (Tx.pack "True") []
boolVal False = VCon (Tx.pack "False") []

arith :: Text -> (Integer -> Integer -> Integer) -> Prim
arith name op = mkPrim name 2 $ \args -> case args of
  [a, b] -> do x <- asInt a; y <- asInt b; Right (PRDone (VLit (LInt (op x y))))
  _      -> Left (ArityError name)

divLike :: Text -> Prim
divLike name = mkPrim name 2 $ \args -> case args of
  [a, b] -> do
    x <- asInt a; y <- asInt b
    if y == 0 then Left (PrimError (name <> Tx.pack ": division by zero"))
              else Right (PRDone (VLit (LInt (x `div` y))))
  _ -> Left (ArityError name)

modLike :: Text -> Prim
modLike name = mkPrim name 2 $ \args -> case args of
  [a, b] -> do
    x <- asInt a; y <- asInt b
    if y == 0 then Left (PrimError (name <> Tx.pack ": modulo by zero"))
              else Right (PRDone (VLit (LInt (x `mod` y))))
  _ -> Left (ArityError name)

cmp :: Text -> (Integer -> Integer -> Bool) -> Prim
cmp name op = mkPrim name 2 $ \args -> case args of
  [a, b] -> do x <- asInt a; y <- asInt b; Right (PRDone (boolVal (op x y)))
  _      -> Left (ArityError name)

boolOp :: Text -> (Bool -> Bool -> Bool) -> Prim
boolOp name op = mkPrim name 2 $ \args -> case args of
  [a, b] -> do x <- asBool a; y <- asBool b; Right (PRDone (boolVal (op x y)))
  _      -> Left (ArityError name)

-- | (++) : append two Cons/Nil lists.
appendP :: Prim
appendP = mkPrim (Tx.pack "++") 2 $ \args -> case args of
  [xs, ys] -> PRDone <$> appendVal xs ys
  _        -> Left (ArityError (Tx.pack "++"))
  where
    appendVal v ys
      | VCon t []      <- v, t == Tx.pack "Nil"  = Right ys
      | VCon t [h, tl] <- v, t == Tx.pack "Cons" = do
          rest <- appendVal tl ys
          Right (VCon (Tx.pack "Cons") [h, rest])
      | otherwise = Left (PrimError (Tx.pack "++: not a list: " <> renderValue v))

-- | ($) : apply the first argument (a function) to the second.
dollarP :: Prim
dollarP = mkPrim (Tx.pack "$") 2 $ \args -> case args of
  [f, x] -> Right (PRApply f [x])
  _      -> Left (ArityError (Tx.pack "$"))
```

- [ ] **Step 2: Add `Wok.Interp.Prim` to `wok.cabal` `exposed-modules`.**

- [ ] **Step 3: Build**

Run: `cabal build`
Expected: compiles cleanly.

- [ ] **Step 4: Write `interpPrimTests` in `test/Spec.hs`**

Add import:

```haskell
import qualified Wok.Interp.Prim as IP
```

Add the group (after `interpValueTests`), plus a small helper to invoke a saturated prim:

```haskell
-- Invoke a prim from the table by name with fully-applied args (test helper).
runPrim :: Text -> [IV.Value] -> Either IV.RuntimeError IV.PrimResult
runPrim name args =
  case Map.lookup name IP.primTable of
    Nothing -> Left (IV.UnboundVar name)
    Just p  -> IV.primFn p args

li :: Integer -> IV.Value
li = IV.VLit . Anf.LInt

interpPrimTests :: TestTree
interpPrimTests = testGroup "InterpPrim"
  [ testCase "table has exactly the bodyless operators" $
      Data.List.sort (Map.keys IP.primTable)
        @?= Data.List.sort (map T.pack ["+","-","*","/","div","mod","==","/=","&&","||","++","$"])
  , testCase "addition" $
      case runPrim (T.pack "+") [li 2, li 3] of
        Right (IV.PRDone v) -> IV.renderValue v @?= T.pack "5"
        other -> assertFailure (show2 other)
  , testCase "equality true" $
      case runPrim (T.pack "==") [li 4, li 4] of
        Right (IV.PRDone v) -> IV.renderValue v @?= T.pack "True"
        other -> assertFailure (show2 other)
  , testCase "equality false" $
      case runPrim (T.pack "==") [li 4, li 5] of
        Right (IV.PRDone v) -> IV.renderValue v @?= T.pack "False"
        other -> assertFailure (show2 other)
  , testCase "boolean and" $
      case runPrim (T.pack "&&") [IV.VCon (T.pack "True") [], IV.VCon (T.pack "False") []] of
        Right (IV.PRDone v) -> IV.renderValue v @?= T.pack "False"
        other -> assertFailure (show2 other)
  , testCase "division by zero is a PrimError" $
      case runPrim (T.pack "div") [li 1, li 0] of
        Left (IV.PrimError _) -> pure ()
        other -> assertFailure (show2 other)
  , testCase "list append" $
      let mkList = foldr (\x acc -> IV.VCon (T.pack "Cons") [li x, acc]) (IV.VCon (T.pack "Nil") [])
      in case runPrim (T.pack "++") [mkList [1,2], mkList [3]] of
           Right (IV.PRDone v) -> IV.renderValue v @?= T.pack "[1, 2, 3]"
           other -> assertFailure (show2 other)
  , testCase "dollar requests an application" $
      case runPrim (T.pack "$") [IV.VCon (T.pack "K") [], li 1] of
        Right (IV.PRApply (IV.VCon t []) [arg]) -> do
          t @?= T.pack "K"
          IV.renderValue arg @?= T.pack "1"
        other -> assertFailure (show2 other)
  ]
  where
    show2 (Left e)  = "Left " <> show e
    show2 (Right _) = "Right <prim-result>"
```

Register `interpPrimTests` in `main`'s test list.

- [ ] **Step 5: Run**

Run: `cabal test --test-options='-p "InterpPrim"'`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/Wok/Interp/Prim.hs wok.cabal test/Spec.hs
git commit -m "feat(interp): primitive table for Std.Base operators"
```

---

## Task 3: CEK machine core (no effects)

**Goal:** Create `Wok/Interp/Machine.hs` with the small-step machine for every non-effect form (`Ret`, `Let`/`Rhs`, `Case`, `LetRec`, `LetJoin`/`Jump`), the `enter` apply path (currying + over-application), the `run` driver, and a pure test seam `evalExprWith`.

**Files:**
- Create: `src/Wok/Interp/Machine.hs`
- Modify: `wok.cabal` (add `Wok.Interp.Machine`)
- Test: `test/Spec.hs` (add `interpMachineTests`, register in `main`)

**Acceptance Criteria:**
- [ ] `evalExprWith` runs pure ANF programs: literals, lets, applications (exact / partial / over), constructors, records + projection, case (con/lit/default), `LetRec`, `LetJoin`/`Jump`.
- [ ] Currying works: a partially applied closure is a value that can be applied later; over-application chains via `KApp`.
- [ ] Record projection is label-based: each label returns its own field independent of insertion order; a missing label yields `BadProjection`.
- [ ] A non-exhaustive case and an unbound jump produce the right `RuntimeError`.
- [ ] `interpMachineTests` passes.

**Verify:** `cabal test --test-options='-p "InterpMachine"'` → all cases pass.

**Steps:**

- [ ] **Step 1: Write `src/Wok/Interp/Machine.hs` (non-effect forms only; the `ROp`/`Handle` cases come in Task 4)**

```haskell
module Wok.Interp.Machine
  ( step
  , run
  , enter
  , evalExprWith
  , runModule
  ) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf
  ( Alt (..), Atom, Binder (..), CoreModule (..), Expr (..), Handler (..)
  , OpArm (..), Rhs (..), TopBind (..) )
import Wok.IR.Name (JoinId (..), Unique (..), nameHint, nameUniq)
import Wok.Interp.Prim (primTable)
import Wok.Interp.Value

-- | Single small-step. Halts on Return into KDone.
step :: PrimTable -> Config -> Either RuntimeError Step
step _     (Return v KDone) = Right (Done v)
step prims cfg              = More <$> transition prims cfg

-- | The non-halting transition: always yields the next Config.
transition :: PrimTable -> Config -> Either RuntimeError Config
transition prims (Return v k)      = returnTo prims v k
transition prims (Eval expr sc k)  = evalExpr prims expr sc k

-- | Deliver a value to a continuation frame.
returnTo :: PrimTable -> Value -> Kont -> Either RuntimeError Config
returnTo _     _ KDone               = Left (PrimError (Tx.pack "internal: returnTo KDone"))
returnTo _     v (KLet b body sc k)  =
  Right (Eval body sc { scEnv = bindBinder b v (scEnv sc) } k)
returnTo prims v (KApp args k)       = enter prims v args k
returnTo _     v (KHandle h hsc k)   =
  -- Normal completion of a handled computation: run the return arm.
  let (rb, rbody) = hReturn h
  in Right (Eval rbody hsc { scEnv = bindBinder rb v (scEnv hsc) } k)

evalExpr :: PrimTable -> Expr -> Scope -> Kont -> Either RuntimeError Config
evalExpr prims expr sc k = case expr of
  Ret a -> do
    v <- resolveAtom prims sc a
    Right (Return v k)

  Let b rhs body -> evalRhs prims b rhs body sc k

  Case a alts -> do
    v <- resolveAtom prims sc a
    matchAlts v alts sc k

  LetRec defs body ->
    -- Tie the recursive knot: each closure captures the post-binding env'.
    -- env' is self-referential; VClosure's lazy env field keeps this productive.
    let env' = foldr addDef (scEnv sc) defs
        addDef (b, ps, bdy) e = Map.insert (nameUniq (bndName b)) (VClosure env' ps bdy) e
    in Right (Eval body sc { scEnv = env' } k)

  LetJoin j ps jb body ->
    let jp = JoinPoint sc ps jb k
    in Right (Eval body sc { scJoins = Map.insert j jp (scJoins sc) } k)

  Jump j args -> do
    vs <- mapM (resolveAtom prims sc) args
    case Map.lookup j (scJoins sc) of
      Nothing -> Left (UnboundVar (renderJoin j))
      Just (JoinPoint jsc ps jbody jk) ->
        Right (Eval jbody jsc { scEnv = bindBinders ps vs (scEnv jsc) } jk)

  Handle e h -> Right (Eval e sc (KHandle h sc k))   -- dispatch lands in Task 4

evalRhs :: PrimTable -> Binder -> Rhs -> Expr -> Scope -> Kont -> Either RuntimeError Config
evalRhs prims b rhs body sc k = case rhs of
  RAtom a -> resolveAtom prims sc a >>= cont
  RCon c as -> do vs <- mapM (resolveAtom prims sc) as; cont (VCon c vs)
  RLam ps e -> cont (VClosure (scEnv sc) ps e)
  RRecord t flds -> do
    vs <- mapM (\(l, a) -> (,) l <$> resolveAtom prims sc a) flds
    cont (VRecord t (Map.fromList vs))
  RProj l a -> do
    v <- resolveAtom prims sc a
    case v of
      VRecord _ m -> maybe (Left (BadProjection l)) cont (Map.lookup l m)
      _           -> Left (BadProjection l)
  RApp f as -> do
    fv <- resolveAtom prims sc f
    vs <- mapM (resolveAtom prims sc) as
    enter prims fv vs (KLet b body sc k)
  ROp lbl op as -> do
    vs <- mapM (resolveAtom prims sc) as
    dispatchOp lbl op vs (KLet b body sc k)   -- defined in Task 4
  where
    cont v = Right (Eval body sc { scEnv = bindBinder b v (scEnv sc) } k)

-- | Apply a value to args, continuing with k. Handles currying for closures
-- and accumulation for prims; over-application chains via KApp.
enter :: PrimTable -> Value -> [Value] -> Kont -> Either RuntimeError Config
enter prims fv args k = case fv of
  VClosure cenv ps body ->
    let np = length ps; na = length args in
    case compare na np of
      EQ -> Right (Eval body (Scope (bindBinders ps args cenv) Map.empty) k)
      LT -> Right (Return (VClosure (bindBinders (take na ps) args cenv) (drop na ps) body) k)
      GT -> let (use, over) = splitAt np args
            in Right (Eval body (Scope (bindBinders ps use cenv) Map.empty) (KApp over k))
  VPrim p ->
    let combined = primArgs p ++ args in
    if length combined < primArity p
      then Right (Return (VPrim p { primArgs = combined }) k)
      else let (use, over) = splitAt (primArity p) combined in do
        r <- primFn p use
        case r of
          PRDone v        -> if null over then Right (Return v k) else enter prims v over k
          PRApply g gargs -> enter prims g (gargs ++ over) k
  VCont kb -> case args of
    [v] -> Right (Return v (kb k))
    _   -> Left (ArityError (Tx.pack "continuation expects exactly one argument"))
  _ -> Left (NotAFunction (renderValue fv))

matchAlts :: Value -> [Alt] -> Scope -> Kont -> Either RuntimeError Config
matchAlts v alts sc k = go alts
  where
    go [] = Left (NonExhaustiveCase (renderValue v))
    go (AltCon c bs e : rest) = case v of
      VCon c' vs | c' == c && length bs == length vs ->
        Right (Eval e sc { scEnv = bindBinders bs vs (scEnv sc) } k)
      _ -> go rest
    go (AltLit l e : rest) = case v of
      VLit l' | l' == l -> Right (Eval e sc k)
      _ -> go rest
    go (AltDefault e : _) = Right (Eval e sc k)

-- | Effect dispatch — full body lands in Task 4. The Task-3 stub keeps the
-- module total and compiling; no Task-3 test reaches it.
dispatchOp :: Text -> Text -> [Value] -> Kont -> Either RuntimeError Config
dispatchOp lbl op _ _ = Left (NoMatchingHandler lbl op)

renderJoin :: JoinId -> Text
renderJoin (JoinId (Unique i)) = Tx.pack "j" <> Tx.pack (show i)

-- | Run a configuration to a final value.
run :: PrimTable -> Config -> Either RuntimeError Value
run prims = loop
  where
    loop cfg = do
      s <- step prims cfg
      case s of
        Done v -> Right v
        More c -> loop c

-- | Pure test seam: evaluate an Expr in a given environment.
evalExprWith :: Env -> Expr -> Either RuntimeError Value
evalExprWith env e = run primTable (Eval e (Scope env Map.empty) KDone)

-- | Whole-module entry — implemented in Task 5.
runModule :: CoreModule -> Either RuntimeError Value
runModule (CoreModule binds) =
  let gEnv = foldr addBind Map.empty binds
      addBind (TopBind n ps body) e = Map.insert (nameUniq n) (VClosure gEnv ps body) e
  in case [ tb | tb@(TopBind n _ _) <- binds, nameHint n == Tx.pack "main" ] of
       (TopBind _ [] body : _) -> run primTable (Eval body (Scope gEnv Map.empty) KDone)
       (TopBind{}        : _)  -> Left (ArityError (Tx.pack "main must take no arguments"))
       []                      -> Left (UnboundVar (Tx.pack "main"))
```

Note: `runModule` is written here in full (it is small and shares `gEnv`), but it is exercised by tests only in Task 5. `dispatchOp`/`Handle` get their real behaviour in Task 4.

- [ ] **Step 2: Add `Wok.Interp.Machine` to `wok.cabal` `exposed-modules`.**

- [ ] **Step 3: Build**

Run: `cabal build`
Expected: compiles cleanly.

- [ ] **Step 4: Write `interpMachineTests` in `test/Spec.hs`**

Add import:

```haskell
import qualified Wok.Interp.Machine as IM
```

Add the group (after `interpPrimTests`). These build ANF directly with `runFresh`/`freshName`, mirroring `anfTests`:

```haskell
interpMachineTests :: TestTree
interpMachineTests = testGroup "InterpMachine"
  [ testCase "Ret literal" $
      assertEval Map.empty (Anf.Ret (Anf.ALit (Anf.LInt 7))) (T.pack "7")

  , testCase "let then ret" $
      let (e, _) = runFresh $ do
            x <- freshName (T.pack "x")
            let b = Anf.Binder x Anf.Unrestricted
            pure (Anf.Let b (Anf.RAtom (Anf.ALit (Anf.LInt 3))) (Anf.Ret (Anf.AVar x)), x)
      in assertEval Map.empty e (T.pack "3")

  , testCase "primitive application 2 + 3" $
      let nplus = runFresh (freshName (T.pack "+"))
          (e, _) = runFresh $ do
            t <- freshName (T.pack "t")
            np <- freshName (T.pack "+")
            let b = Anf.Binder t Anf.Unrestricted
            pure ( Anf.Let b (Anf.RApp (Anf.AVar np) [Anf.ALit (Anf.LInt 2), Anf.ALit (Anf.LInt 3)])
                            (Anf.Ret (Anf.AVar t))
                 , nplus )
      in assertEval Map.empty e (T.pack "5")

  , testCase "closure: identity applied to 9" $
      -- let id = \x -> x ; let r = id 9 ; ret r
      let e = runFresh $ do
            x  <- freshName (T.pack "x")
            i  <- freshName (T.pack "id")
            r  <- freshName (T.pack "r")
            let lam = Anf.RLam [Anf.Binder x Anf.Unrestricted] (Anf.Ret (Anf.AVar x))
            pure $ Anf.Let (Anf.Binder i Anf.Unrestricted) lam
                     (Anf.Let (Anf.Binder r Anf.Unrestricted)
                              (Anf.RApp (Anf.AVar i) [Anf.ALit (Anf.LInt 9)])
                              (Anf.Ret (Anf.AVar r)))
      in assertEval Map.empty e (T.pack "9")

  , testCase "currying: (\\x y -> x) applied to one arg is a value, then applied again" $
      -- let k = \x y -> x ; let k1 = k 1 ; let r = k1 2 ; ret r
      let e = runFresh $ do
            x <- freshName (T.pack "x"); y <- freshName (T.pack "y")
            k <- freshName (T.pack "k"); k1 <- freshName (T.pack "k1"); r <- freshName (T.pack "r")
            let lam = Anf.RLam [Anf.Binder x Anf.Unrestricted, Anf.Binder y Anf.Unrestricted]
                               (Anf.Ret (Anf.AVar x))
            pure $ Anf.Let (Anf.Binder k Anf.Unrestricted) lam
                     (Anf.Let (Anf.Binder k1 Anf.Unrestricted) (Anf.RApp (Anf.AVar k) [Anf.ALit (Anf.LInt 1)])
                       (Anf.Let (Anf.Binder r Anf.Unrestricted) (Anf.RApp (Anf.AVar k1) [Anf.ALit (Anf.LInt 2)])
                         (Anf.Ret (Anf.AVar r))))
      in assertEval Map.empty e (T.pack "1")

  , testCase "case on literal selects the matching arm" $
      let e = Anf.Case (Anf.ALit (Anf.LInt 0))
                [ Anf.AltLit (Anf.LInt 0) (Anf.Ret (Anf.ALit (Anf.LInt 100)))
                , Anf.AltDefault (Anf.Ret (Anf.ALit (Anf.LInt 200))) ]
      in assertEval Map.empty e (T.pack "100")

  , testCase "case on constructor binds fields" $
      -- case (Pair 1 2) of Pair a b -> b
      let e = runFresh $ do
            a <- freshName (T.pack "a"); b <- freshName (T.pack "b"); p <- freshName (T.pack "p")
            pure $ Anf.Let (Anf.Binder p Anf.Unrestricted)
                     (Anf.RCon (T.pack "Pair") [Anf.ALit (Anf.LInt 1), Anf.ALit (Anf.LInt 2)])
                     (Anf.Case (Anf.AVar p)
                       [ Anf.AltCon (T.pack "Pair")
                           [Anf.Binder a Anf.Unrestricted, Anf.Binder b Anf.Unrestricted]
                           (Anf.Ret (Anf.AVar b)) ])
      in assertEval Map.empty e (T.pack "2")

  , testCase "record projection returns each field by label (order-independent invariant)" $
      -- Invariant: projecting label L on a record returns exactly the atom bound
      -- to L, for EVERY label, regardless of field insertion order. Fields are
      -- declared in non-sorted order with distinct values, so a position-based
      -- (rather than label-based) projection bug returns the wrong number and is
      -- caught. Missing label must be a clean BadProjection, not a crash.
      let proj label = runFresh $ do
            r <- freshName (T.pack "r"); p <- freshName (T.pack "p")
            pure $ Anf.Let (Anf.Binder r Anf.Unrestricted)
                     (Anf.RRecord (T.pack "T")
                        [ (T.pack "c", Anf.ALit (Anf.LInt 30))
                        , (T.pack "a", Anf.ALit (Anf.LInt 10))
                        , (T.pack "b", Anf.ALit (Anf.LInt 20)) ])
                     (Anf.Let (Anf.Binder p Anf.Unrestricted)
                        (Anf.RProj label (Anf.AVar r))
                        (Anf.Ret (Anf.AVar p)))
          check label expected =
            case IM.evalExprWith Map.empty (proj label) of
              Right v -> IV.renderValue v @?= expected
              Left e  -> assertFailure ("projection " <> T.unpack label <> " failed: " <> show e)
      in do
        check (T.pack "a") (T.pack "10")
        check (T.pack "b") (T.pack "20")
        check (T.pack "c") (T.pack "30")
        case IM.evalExprWith Map.empty (proj (T.pack "zzz")) of
          Left (IV.BadProjection l) -> l @?= T.pack "zzz"
          other -> assertFailure ("expected BadProjection, got " <> show other)

  , testCase "letrec: countdown sums to 0 via recursion (even/odd style)" $
      -- letrec loop n = case n of { 0 -> 0 ; _ -> loop (n-1) } ; ret (loop 3)
      let e = runFresh $ do
            loop <- freshName (T.pack "loop"); n <- freshName (T.pack "n")
            nm   <- freshName (T.pack "-");    t <- freshName (T.pack "t")
            r    <- freshName (T.pack "r")
            let body = Anf.Case (Anf.AVar n)
                  [ Anf.AltLit (Anf.LInt 0) (Anf.Ret (Anf.ALit (Anf.LInt 0)))
                  , Anf.AltDefault
                      (Anf.Let (Anf.Binder t Anf.Unrestricted)
                        (Anf.RApp (Anf.AVar nm) [Anf.AVar n, Anf.ALit (Anf.LInt 1)])
                        (Anf.Let (Anf.Binder r Anf.Unrestricted)
                          (Anf.RApp (Anf.AVar loop) [Anf.AVar t])
                          (Anf.Ret (Anf.AVar r)))) ]
            top <- freshName (T.pack "out")
            pure $ Anf.LetRec [(Anf.Binder loop Anf.Unrestricted, [Anf.Binder n Anf.Unrestricted], body)]
                     (Anf.Let (Anf.Binder top Anf.Unrestricted)
                       (Anf.RApp (Anf.AVar loop) [Anf.ALit (Anf.LInt 3)])
                       (Anf.Ret (Anf.AVar top)))
      in assertEval Map.empty e (T.pack "0")

  , testCase "letjoin/jump merges branches" $
      -- join j(r) = ret r ; case 1 of { 0 -> jump j 10 ; _ -> jump j 20 }
      let e = runFresh $ do
            j <- freshJoin; r <- freshName (T.pack "r")
            pure $ Anf.LetJoin j [Anf.Binder r Anf.Unrestricted] (Anf.Ret (Anf.AVar r))
                     (Anf.Case (Anf.ALit (Anf.LInt 1))
                       [ Anf.AltLit (Anf.LInt 0) (Anf.Jump j [Anf.ALit (Anf.LInt 10)])
                       , Anf.AltDefault (Anf.Jump j [Anf.ALit (Anf.LInt 20)]) ])
      in assertEval Map.empty e (T.pack "20")

  , testCase "non-exhaustive case errors" $
      let e = Anf.Case (Anf.ALit (Anf.LInt 5)) [ Anf.AltLit (Anf.LInt 0) (Anf.Ret (Anf.ALit (Anf.LInt 1))) ]
      in case IM.evalExprWith Map.empty e of
           Left (IV.NonExhaustiveCase _) -> pure ()
           other -> assertFailure ("expected NonExhaustiveCase, got " <> show other)
  ]
  where
    assertEval env e expected =
      case IM.evalExprWith env e of
        Right v -> IV.renderValue v @?= expected
        Left err -> assertFailure ("eval failed: " <> show err)
```

Add `freshJoin` to the existing `Wok.IR.Name` import line in `test/Spec.hs`.

Register `interpMachineTests` in `main`.

- [ ] **Step 5: Run**

Run: `cabal test --test-options='-p "InterpMachine"'`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/Wok/Interp/Machine.hs wok.cabal test/Spec.hs
git commit -m "feat(interp): CEK machine core (pure forms, currying, joins)"
```

---

## Task 4: Effect operations and handler frames

**Goal:** Implement effect dispatch in `Machine.hs`: an operation captures the delimited continuation up to its nearest matching `KHandle`, binds the op args and a multi-shot `resume`, and runs the arm under the handler's below-continuation; deep handlers re-install on resume.

**Files:**
- Modify: `src/Wok/Interp/Machine.hs` (replace the `dispatchOp` stub; add `findHandler`, `lookupOpArm`)
- Test: `test/Spec.hs` (add `interpEffectTests`, register in `main`)

**Acceptance Criteria:**
- [ ] An operation transfers control to the nearest matching handler; unmatched ops error `NoMatchingHandler`.
- [ ] Auto-resume (`let res = resume v in ...`) returns the downstream value back into the arm and on to the handler's below-continuation.
- [ ] Abort (arm never calls `resume`) discards the delimited continuation and yields the arm's value.
- [ ] Multi-shot (`resume` invoked twice) re-runs the captured continuation independently each time.
- [ ] Deep re-installation: a computation performing the operation twice is handled both times (the second op proves resume re-installs the handler).
- [ ] The return arm transforms the final value of a normally-completing handled computation.
- [ ] `interpEffectTests` passes.

**Verify:** `cabal test --test-options='-p "InterpEffect"'` → all cases pass.

**Steps:**

- [ ] **Step 1: Replace the `dispatchOp` stub in `Machine.hs` and add helpers**

Replace the Task-3 stub:

```haskell
dispatchOp :: Text -> Text -> [Value] -> Kont -> Either RuntimeError Config
dispatchOp lbl op _ _ = Left (NoMatchingHandler lbl op)
```

with:

```haskell
-- | An operation: find the nearest matching handler, capture the delimited
-- continuation above it as a builder, bind the op args and a (deep, multi-shot)
-- resume, and run the arm under the handler's below-continuation.
dispatchOp :: Text -> Text -> [Value] -> Kont -> Either RuntimeError Config
dispatchOp lbl op argVals kCur =
  case findHandler lbl op kCur of
    Nothing -> Left (NoMatchingHandler lbl op)
    Just (above, h, hsc, kBelow) ->
      case lookupOpArm lbl op h of
        Nothing -> Left (NoMatchingHandler lbl op)
        Just oa ->
          -- resume v (called at continuation `after`) re-runs the delimited
          -- frames with the handler RE-INSTALLED over `after` (deep handler).
          let resumeVal = VCont (\after -> above (KHandle h hsc after))
              env1 = bindBinders (oaArgs oa) argVals (scEnv hsc)
              env2 = bindBinder (oaResume oa) resumeVal env1
          in Right (Eval (oaBody oa) (Scope env2 (scJoins hsc)) kBelow)

-- | Walk outward from the operation's continuation to the nearest KHandle that
-- covers (label, op). Returns: a builder that re-prepends the frames above the
-- handler, the matched handler, its captured scope, and the continuation below.
findHandler :: Text -> Text -> Kont -> Maybe (Kont -> Kont, Handler, Scope, Kont)
findHandler lbl op = go id
  where
    go _   KDone               = Nothing
    go acc (KLet b e sc k)     = go (acc . KLet b e sc) k
    go acc (KApp vs k)         = go (acc . KApp vs) k
    go acc (KHandle h sc k)
      | covers h               = Just (acc, h, sc, k)
      | otherwise              = go (acc . KHandle h sc) k
      where covers hh = any (\a -> oaLabel a == lbl && oaOp a == op) (hOps hh)

lookupOpArm :: Text -> Text -> Handler -> Maybe OpArm
lookupOpArm lbl op h =
  case [ a | a <- hOps h, oaLabel a == lbl, oaOp a == op ] of
    (a : _) -> Just a
    []      -> Nothing
```

Note: `bindBinder (oaResume oa) resumeVal` — `oaResume` is a `Binder`, so `bindBinder` applies directly.

- [ ] **Step 2: Build**

Run: `cabal build`
Expected: compiles cleanly.

- [ ] **Step 3: Write `interpEffectTests` in `test/Spec.hs`**

These construct `Handler`/`OpArm` ANF directly, so they can exercise abort and multi-shot (which surface syntax cannot express). Add the group after `interpMachineTests`:

```haskell
interpEffectTests :: TestTree
interpEffectTests = testGroup "InterpEffect"
  [ testCase "auto-resume: handler returns the resumed downstream value" $
      -- handle ( let a = Ask.ask () in ret a ) of
      --   Ask.ask(p, resume) -> let res = resume 41 in ret res
      --   return v -> v
      let e = runFresh $ do
            a <- freshName (T.pack "a")
            p <- freshName (T.pack "p"); resume <- freshName (T.pack "resume")
            res <- freshName (T.pack "res"); v <- freshName (T.pack "v")
            let comp = Anf.Let (Anf.Binder a Anf.Unrestricted)
                         (Anf.ROp (T.pack "Ask") (T.pack "ask") [Anf.ALit Anf.LUnit])
                         (Anf.Ret (Anf.AVar a))
                arm = Anf.OpArm (T.pack "Ask") (T.pack "ask")
                        [Anf.Binder p Anf.Unrestricted]
                        (Anf.Binder resume Anf.Unrestricted)
                        (Anf.Let (Anf.Binder res Anf.Unrestricted)
                          (Anf.RApp (Anf.AVar resume) [Anf.ALit (Anf.LInt 41)])
                          (Anf.Ret (Anf.AVar res)))
                hdlr = Anf.Handler (Anf.Binder v Anf.Unrestricted, Anf.Ret (Anf.AVar v)) [arm]
            pure (Anf.Handle comp hdlr)
      in assertEval Map.empty e (T.pack "41")

  , testCase "return arm transforms a normally-completing computation" $
      -- handle (ret 5) of return v -> let r = v + 100 ; ret r   (no ops)
      let e = runFresh $ do
            v <- freshName (T.pack "v"); r <- freshName (T.pack "r"); np <- freshName (T.pack "+")
            let retArm = Anf.Let (Anf.Binder r Anf.Unrestricted)
                           (Anf.RApp (Anf.AVar np) [Anf.AVar v, Anf.ALit (Anf.LInt 100)])
                           (Anf.Ret (Anf.AVar r))
                hdlr = Anf.Handler (Anf.Binder v Anf.Unrestricted, retArm) []
            pure (Anf.Handle (Anf.Ret (Anf.ALit (Anf.LInt 5))) hdlr)
      in assertEval Map.empty e (T.pack "105")

  , testCase "abort: arm ignores resume and returns its own value" $
      -- handle ( let a = Abort.abort () in ret a ) of
      --   Abort.abort(p, resume) -> ret 7      (resume unused)
      --   return v -> v
      let e = runFresh $ do
            a <- freshName (T.pack "a"); p <- freshName (T.pack "p")
            resume <- freshName (T.pack "resume"); v <- freshName (T.pack "v")
            let comp = Anf.Let (Anf.Binder a Anf.Unrestricted)
                         (Anf.ROp (T.pack "Abort") (T.pack "abort") [Anf.ALit Anf.LUnit])
                         (Anf.Ret (Anf.AVar a))
                arm = Anf.OpArm (T.pack "Abort") (T.pack "abort")
                        [Anf.Binder p Anf.Unrestricted]
                        (Anf.Binder resume Anf.Unrestricted)
                        (Anf.Ret (Anf.ALit (Anf.LInt 7)))
                hdlr = Anf.Handler (Anf.Binder v Anf.Unrestricted, Anf.Ret (Anf.AVar v)) [arm]
            pure (Anf.Handle comp hdlr)
      in assertEval Map.empty e (T.pack "7")

  , testCase "multi-shot: resume invoked twice, results summed" $
      -- handle ( let b = Flip.flip () in case b of { 0 -> ret 10 ; _ -> ret 20 } ) of
      --   Flip.flip(p, resume) ->
      --       let r0 = resume 0 in let r1 = resume 1 in let s = r0 + r1 in ret s
      --   return v -> v
      -- resume 0 -> downstream picks 10 ; resume 1 -> downstream picks 20 ; sum 30.
      let e = runFresh $ do
            b <- freshName (T.pack "b"); p <- freshName (T.pack "p")
            resume <- freshName (T.pack "resume")
            r0 <- freshName (T.pack "r0"); r1 <- freshName (T.pack "r1")
            s <- freshName (T.pack "s"); v <- freshName (T.pack "v"); np <- freshName (T.pack "+")
            let comp = Anf.Let (Anf.Binder b Anf.Unrestricted)
                         (Anf.ROp (T.pack "Flip") (T.pack "flip") [Anf.ALit Anf.LUnit])
                         (Anf.Case (Anf.AVar b)
                           [ Anf.AltLit (Anf.LInt 0) (Anf.Ret (Anf.ALit (Anf.LInt 10)))
                           , Anf.AltDefault (Anf.Ret (Anf.ALit (Anf.LInt 20))) ])
                armBody =
                  Anf.Let (Anf.Binder r0 Anf.Unrestricted) (Anf.RApp (Anf.AVar resume) [Anf.ALit (Anf.LInt 0)])
                    (Anf.Let (Anf.Binder r1 Anf.Unrestricted) (Anf.RApp (Anf.AVar resume) [Anf.ALit (Anf.LInt 1)])
                      (Anf.Let (Anf.Binder s Anf.Unrestricted) (Anf.RApp (Anf.AVar np) [Anf.AVar r0, Anf.AVar r1])
                        (Anf.Ret (Anf.AVar s))))
                arm = Anf.OpArm (T.pack "Flip") (T.pack "flip")
                        [Anf.Binder p Anf.Unrestricted] (Anf.Binder resume Anf.Unrestricted) armBody
                hdlr = Anf.Handler (Anf.Binder v Anf.Unrestricted, Anf.Ret (Anf.AVar v)) [arm]
            pure (Anf.Handle comp hdlr)
      in assertEval Map.empty e (T.pack "30")

  , testCase "deep handler: handler is re-installed so a SECOND op is still handled" $
      -- handle ( let x = E.op () in let y = E.op () in let s = x + y in ret s ) of
      --   E.op(p, resume) -> let r = resume 1 in ret r       (single auto-resume)
      --   return v -> v
      -- The computation performs E.op TWICE in sequence. The second op only
      -- finds a handler because resume re-installs the KHandle frame (deep
      -- semantics). A broken re-install surfaces NoMatchingHandler on the
      -- second op, so the expected value 2 (= 1 + 1) is the discriminator.
      -- Low-effort: reuses the auto-resume arm shape; no multi-shot machinery.
      let e = runFresh $ do
            x <- freshName (T.pack "x"); y <- freshName (T.pack "y"); s <- freshName (T.pack "s")
            p <- freshName (T.pack "p"); resume <- freshName (T.pack "resume")
            r <- freshName (T.pack "r"); v <- freshName (T.pack "v"); np <- freshName (T.pack "+")
            let comp =
                  Anf.Let (Anf.Binder x Anf.Unrestricted)
                    (Anf.ROp (T.pack "E") (T.pack "op") [Anf.ALit Anf.LUnit])
                    (Anf.Let (Anf.Binder y Anf.Unrestricted)
                      (Anf.ROp (T.pack "E") (T.pack "op") [Anf.ALit Anf.LUnit])
                      (Anf.Let (Anf.Binder s Anf.Unrestricted)
                        (Anf.RApp (Anf.AVar np) [Anf.AVar x, Anf.AVar y])
                        (Anf.Ret (Anf.AVar s))))
                arm = Anf.OpArm (T.pack "E") (T.pack "op")
                        [Anf.Binder p Anf.Unrestricted] (Anf.Binder resume Anf.Unrestricted)
                        (Anf.Let (Anf.Binder r Anf.Unrestricted)
                          (Anf.RApp (Anf.AVar resume) [Anf.ALit (Anf.LInt 1)])
                          (Anf.Ret (Anf.AVar r)))
                hdlr = Anf.Handler (Anf.Binder v Anf.Unrestricted, Anf.Ret (Anf.AVar v)) [arm]
            pure (Anf.Handle comp hdlr)
      in assertEval Map.empty e (T.pack "2")

  , testCase "unhandled operation errors" $
      let e = runFresh $ do
            a <- freshName (T.pack "a")
            pure $ Anf.Let (Anf.Binder a Anf.Unrestricted)
                     (Anf.ROp (T.pack "Ask") (T.pack "ask") [Anf.ALit Anf.LUnit])
                     (Anf.Ret (Anf.AVar a))
      in case IM.evalExprWith Map.empty e of
           Left (IV.NoMatchingHandler l o) -> (l, o) @?= (T.pack "Ask", T.pack "ask")
           other -> assertFailure ("expected NoMatchingHandler, got " <> show other)
  ]
  where
    assertEval env e expected =
      case IM.evalExprWith env e of
        Right v -> IV.renderValue v @?= expected
        Left err -> assertFailure ("eval failed: " <> show err)
```

Register `interpEffectTests` in `main`.

- [ ] **Step 4: Run**

Run: `cabal test --test-options='-p "InterpEffect"'`
Expected: all five cases pass (especially `multi-shot ... 30` — this is the proof the continuation is re-invocable).

- [ ] **Step 5: Commit**

```bash
git add src/Wok/Interp/Machine.hs test/Spec.hs
git commit -m "feat(interp): algebraic-effect dispatch with deep, multi-shot resume"
```

---

## Task 5: Program entry, facade, and CLI `--run`

**Goal:** Expose a clean facade (`Wok.Interp`) and a `wok --run <entry.wok>` mode that elaborates the entry module, runs `main`, and prints the rendered result; verify end-to-end through the real pipeline.

**Files:**
- Create: `src/Wok/Interp.hs`
- Modify: `wok.cabal` (add `Wok.Interp`)
- Modify: `app/Main.hs` (add `ModeRun`)
- Test: `test/Spec.hs` (add `interpEntryTests`, register in `main`)

**Acceptance Criteria:**
- [ ] `Wok.Interp` re-exports `runModule`, `renderValue`, `RuntimeError`.
- [ ] `runModule` finds `main` (0-arity), runs it, and returns the value; missing/parameterised `main` errors clearly.
- [ ] `wok --run examples/<f>.wok` prints the rendered result to stdout; errors go to stderr with non-zero exit.
- [ ] `interpEntryTests` runs a real `.wok` source string through load → elaborate → run.

**Verify:** `cabal test --test-options='-p "InterpEntry"'` → passes; and `cabal run wok -- --run test/run-examples/01-arith.wok` (after Task 6 fixtures exist) prints `5`.

**Steps:**

- [ ] **Step 1: Write `src/Wok/Interp.hs`**

```haskell
-- | Public facade for the ANF CEK interpreter. The interpreter runs an
-- elaborated CoreModule (Scope B output) to a runtime Value. v1 is pure:
-- main must be 0-arity and any effects must be discharged by handlers.
module Wok.Interp
  ( runModule
  , renderValue
  , RuntimeError (..)
  ) where

import Wok.Interp.Machine (runModule)
import Wok.Interp.Value (RuntimeError (..), renderValue)
```

- [ ] **Step 2: Add `Wok.Interp` to `wok.cabal` `exposed-modules`.**

- [ ] **Step 3: Wire `--run` into `app/Main.hs`**

Change the mode type:

```haskell
data CliMode = ModePrintSchemes | ModeDumpAnf | ModeRun
```

Update `usage`:

```haskell
usage :: String
usage = "usage: wok <entry.wok> [-I <file.wok>]... [--dump-anf | --run]"
```

Add a parse clause in `parseCli`'s `go` (next to the `--dump-anf` clause):

```haskell
    go e        xs _  ("--run" : rest)      = go e xs ModeRun rest
```

Add the run branch in `runApp`'s `case mode of` (alongside `ModeDumpAnf`):

```haskell
      ModeRun -> case Pipeline.elaborateProgram entryName ms of
        Left msg -> hPutStrLn stderr msg >> exitFailure
        Right cm -> case Interp.runModule cm of
          Left rerr -> hPutStrLn stderr ("runtime error: " <> show rerr) >> exitFailure
          Right v   -> TIO.putStrLn (Interp.renderValue v)
```

Add the import near the other `Wok.*` imports:

```haskell
import qualified Wok.Interp as Interp
```

- [ ] **Step 4: Build**

Run: `cabal build`
Expected: compiles cleanly (the executable and library both build).

- [ ] **Step 5: Write `interpEntryTests` in `test/Spec.hs`**

This drives a source string through the same pipeline the CLI uses. Add a helper that mirrors `anfElaborateHarness` but runs the module:

```haskell
-- Load + elaborate + run a single-file program given as source text.
-- Writes the source to a temp path so Loader.loadProgram can read it.
runSourceToValue :: Text -> IO (Either String Text)
runSourceToValue src = do
  let path = "test/.interp-tmp.wok"
  TIO.writeFile path src
  result <- Loader.loadProgram path []
  removeFileIfExists path
  case result of
    Left lerr -> pure (Left ("loader: " <> show lerr))
    Right (entryName, ms) ->
      case Pipeline.elaborateProgram entryName ms of
        Left s  -> pure (Left ("elaborate: " <> s))
        Right cm -> case Interp.runModule cm of
          Left rerr -> pure (Left ("runtime: " <> show rerr))
          Right v   -> pure (Right (Interp.renderValue v))

removeFileIfExists :: FilePath -> IO ()
removeFileIfExists p = Dir.doesFileExist p >>= \yes -> Control.Monad.when yes (Dir.removeFile p)

interpEntryTests :: TestTree
interpEntryTests = testGroup "InterpEntry"
  [ testCase "arithmetic main" $ do
      r <- runSourceToValue (T.unlines
             [ T.pack "module Main"
             , T.pack "import Std.Base"
             , T.pack "main = 2 + 3 * 4" ])
      r @?= Right (T.pack "14")
  , testCase "recursive factorial" $ do
      r <- runSourceToValue (T.unlines
             [ T.pack "module Main"
             , T.pack "import Std.Base"
             , T.pack "fact n = case n of"
             , T.pack "  0 -> 1"
             , T.pack "  _ -> n * fact (n - 1)"
             , T.pack "main = fact 5" ])
      r @?= Right (T.pack "120")
  , testCase "missing main errors" $ do
      r <- runSourceToValue (T.unlines
             [ T.pack "module Main"
             , T.pack "import Std.Base"
             , T.pack "notMain = 1" ])
      case r of
        Left msg -> assertBool ("expected main error: " <> msg)
                      (Data.List.isInfixOf "main" msg)
        Right v  -> assertFailure ("expected failure, got " <> T.unpack v)
  ]
```

Add imports:

```haskell
import qualified System.Directory as Dir
import qualified Control.Monad
```

Register `interpEntryTests` in `main`.

- [ ] **Step 6: Run**

Run: `cabal test --test-options='-p "InterpEntry"'`
Expected: all pass (`14`, `120`, and the missing-main error).

- [ ] **Step 7: Commit**

```bash
git add src/Wok/Interp.hs wok.cabal app/Main.hs test/Spec.hs
git commit -m "feat(interp): Wok.Interp facade, runModule entry, wok --run CLI"
```

---

## Task 6: Golden program-output corpus

**Goal:** A `tasty-golden` corpus of runnable `.wok` programs (each with a 0-arity `main`) whose rendered output is checked, mirroring the existing `anf golden` harness — including at least one auto-resume effect program.

**Files:**
- Create: `test/run-examples/*.wok` (the fixtures below)
- Create: `test/run-golden/*.expected` (generated, then verified)
- Modify: `test/Spec.hs` (add the `run golden` group + harness)

**Acceptance Criteria:**
- [ ] A `run golden` test group runs every `test/run-examples/*.wok` through load → elaborate → run → render.
- [ ] Each fixture has a committed `.expected` whose contents match the hand-computed result.
- [ ] At least one fixture exercises an effect handler (auto-resume).

**Verify:** `cabal test --test-options='-p "run golden"'` → all golden comparisons pass.

**Steps:**

- [ ] **Step 1: Add the harness + golden-path helpers to `test/Spec.hs`**

```haskell
runGoldenFor :: FilePath -> FilePath
runGoldenFor f =
  replaceDirectory (replaceExtension f ".expected") "test/run-golden"

runProgramHarness :: FilePath -> IO BL.ByteString
runProgramHarness path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> pure (BL.pack ("loader: " <> show lerr <> "\n"))
    Right (entryName, ms) ->
      case Pipeline.elaborateProgram entryName ms of
        Left s  -> pure (BL.pack ("elaborate: " <> s <> "\n"))
        Right cm -> case Interp.runModule cm of
          Left rerr -> pure (BL.pack ("runtime error: " <> show rerr <> "\n"))
          Right v   -> pure (BL.pack (T.unpack (Interp.renderValue v) <> "\n"))
```

In `main`, discover the fixtures and register the group (add near the `anf golden` group):

```haskell
  runFiles <- findByExtension [".wok"] "test/run-examples"
```

```haskell
    , testGroup "run golden"
        [ goldenVsString (takeBaseName f) (runGoldenFor f) (runProgramHarness f)
        | f <- runFiles
        ]
```

- [ ] **Step 2: Create the fixture programs**

`test/run-examples/01-arith.wok`:

```
module Main
import Std.Base

main = 2 + 3 * 4
```

`test/run-examples/02-factorial.wok`:

```
module Main
import Std.Base

fact : U64 -> U64
fact n = case n of
  0 -> 1
  _ -> n * fact (n - 1)

main = fact 5
```

`test/run-examples/03-mutual-rec.wok`:

```
module Main
import Std.Base

even : U64 -> Bool
even n = case n of
  0 -> True
  _ -> odd (n - 1)

odd : U64 -> Bool
odd n = case n of
  0 -> False
  _ -> even (n - 1)

main = even 10
```

`test/run-examples/04-list-length.wok`:

```
module Main
import Std.Base

len : [a] -> U64
len xs = case xs of
  []      -> 0
  _ :: ys -> 1 + len ys

main = len [10, 20, 30]
```

`test/run-examples/05-list-append.wok`:

```
module Main
import Std.Base

main = [1, 2] ++ [3, 4]
```

`test/run-examples/06-maybe.wok`:

```
module Main
import Std.Base

unwrapOr : Option a -> a -> a
unwrapOr o d = case o of
  Some x -> x
  None   -> d

main = unwrapOr (Some 7) 0
```

`test/run-examples/07-effect-ask.wok`:

```
module Main
import Std.Base

effect Ask = { ask : () -> U64 }

useAsk : () -> U64 with Ask
useAsk u = Ask.ask () + 1

main : U64
main = handle (useAsk ()) of
  Ask.ask p -> 41
  return v -> v
```

- [ ] **Step 3: Generate the golden files, then verify each by hand**

Run the corpus once with `--accept` to write the `.expected` files:

Run: `cabal test --test-options='-p "run golden" --accept'`

Then confirm each generated golden matches the hand-computed value below (open each file and check):

| Fixture | Expected `.expected` content |
|---------|------------------------------|
| `01-arith.expected` | `14` |
| `02-factorial.expected` | `120` |
| `03-mutual-rec.expected` | `True` |
| `04-list-length.expected` | `3` |
| `05-list-append.expected` | `[1, 2, 3, 4]` |
| `06-maybe.expected` | `7` |
| `07-effect-ask.expected` | `42` |

(Each file ends with a trailing newline, matching the harness's `<> "\n"`.) If any generated value differs from this table, that is a real bug — debug the interpreter, do NOT edit the table to match.

- [ ] **Step 4: Re-run without `--accept` to confirm the goldens are stable**

Run: `cabal test --test-options='-p "run golden"'`
Expected: all `run golden` cases pass.

- [ ] **Step 5: Commit**

```bash
git add test/run-examples test/run-golden test/Spec.hs
git commit -m "test(interp): golden program-output corpus (pure + effect handler)"
```

---

## Task 7 (optional, stretch): Whole-program elaboration for cross-module calls

**Goal:** Let runnable programs call prelude/cross-module *functions* (e.g. `id`, `const`) by elaborating every loaded module's bindings into one `CoreModule` under a single shared global-name map, so references across modules share identity.

> Skip this task for the initial milestone. Tasks 1–6 deliver a working interpreter whose corpus uses operators (prims), constructors, and the program's own functions — which is everything except prelude/cross-module *function bodies*. Do this task only when a program needs to call `id`/`const`/another module's function.

**Why it is needed:** `Pipeline.elaborateProgram` elaborates only the entry module's AST, so prelude functions get a global `Name` but no `TopBind`. `elaborateModule` also mints fresh global names per call, so calling it per module would give the same global different `Unique`s in different modules — references would not match. Whole-program elaboration must mint global names ONCE and share them.

**Files:**
- Modify: `src/Wok/IR/Elaborate.hs` (add `elaborateModulesShared`)
- Modify: `src/Wok/Pipeline.hs` (add `elaborateProgramFull`)
- Test: `test/Spec.hs` (add `interpWholeProgramTests`)

**Acceptance Criteria:**
- [ ] `elaborateProgramFull` returns a `CoreModule` containing every module's `TopBind`s, with cross-module references resolving to the same `Name` as the definition site.
- [ ] A program whose `main` calls `id` (defined in `Std.Base`) runs and returns the argument.

**Steps:**

- [ ] **Step 1: Add `elaborateModulesShared` to `Elaborate.hs`**

```haskell
-- | Elaborate several modules into one CoreModule, minting global names ONCE
-- from the union of all modules' value-level vars so cross-module references
-- share identity. Each module elaborates with its OWN env (for constructor
-- arities, record fields, effect ops) but the SHARED globals map.
elaborateModulesShared :: [(Env, Abs.Module)] -> CoreModule
elaborateModulesShared mods =
  runFresh $ do
    let allVarNames = Map.keys (Map.unions [ envVars env | (env, _) <- mods ])
    gpairs <- mapM (\t -> (,) t <$> freshName t) allVarNames
    let globals = Map.fromList gpairs
    binds <- concat <$> mapM (elabOne globals) mods
    pure (CoreModule binds)
  where
    elabOne globals (env, Abs.Module decls) =
      let eqns = [ (lhs, body, mw) | Abs.DEqn lhs body mw <- decls ]
      in mapM (\(lhs, body, mw) ->
                 runReaderT (elabTopBind lhs body mw) (ElabCtx env Map.empty globals)) eqns
```

Export `elaborateModulesShared` from the module's export list. (`envVars` is already imported from `Wok.TypeChecking.Env`; if not, add it.)

- [ ] **Step 2: Add `elaborateProgramFull` to `Pipeline.hs`**

`runPipelineFold` already returns a `Map ModuleName ModResult` carrying each module's `mrEnvOut` and `mrAst`. Add:

```haskell
-- | Elaborate ALL loaded modules into one whole-program CoreModule, sharing a
-- single global-name map so cross-module references resolve consistently.
elaborateProgramFull
  :: ModuleName
  -> [LoadedModule]
  -> Either String CoreModule
elaborateProgramFull entryName ms = do
  (resultMap, _warns) <- runPipelineFold entryName ms
  let mods = [ (mrEnvOut mr, mrAst mr) | mr <- Map.elems resultMap ]
  Right (elaborateModulesShared mods)
```

Export `elaborateProgramFull`; import `elaborateModulesShared`.

- [ ] **Step 3: Add `interpWholeProgramTests`**

```haskell
interpWholeProgramTests :: TestTree
interpWholeProgramTests = testGroup "InterpWholeProgram"
  [ testCase "main calls prelude id" $ do
      let path = "test/.interp-tmp-wp.wok"
      TIO.writeFile path (T.unlines
        [ T.pack "module Main"
        , T.pack "import Std.Base"
        , T.pack "main = id 99" ])
      result <- Loader.loadProgram path []
      removeFileIfExists path
      case result of
        Left lerr -> assertFailure ("loader: " <> show lerr)
        Right (entryName, ms) -> case Pipeline.elaborateProgramFull entryName ms of
          Left s  -> assertFailure ("elaborate: " <> s)
          Right cm -> case Interp.runModule cm of
            Left rerr -> assertFailure ("runtime: " <> show rerr)
            Right v   -> Interp.renderValue v @?= T.pack "99"
  ]
```

Register it in `main`. (Keep `--run` on `elaborateProgram`; switch to `elaborateProgramFull` only if/when the CLI should support cross-module calls — note that decision in the commit message.)

- [ ] **Step 4: Build, test, commit**

```bash
cabal test --test-options='-p "InterpWholeProgram"'
git add src/Wok/IR/Elaborate.hs src/Wok/Pipeline.hs test/Spec.hs
git commit -m "feat(interp): whole-program elaboration for cross-module function calls"
```

---

## Self-review (run after the plan, before execution)

**Spec coverage vs. the sketch (`2026-06-03-anf-interpreter-sketch.md`):**

| Sketch task | Covered by |
|-------------|-----------|
| Task 1 (values + environment) | Task 1 |
| Task 2 (CEK core, no effects) | Task 3 |
| Task 3 (builtins/primitives) | Task 2 |
| Task 4 (effect ops + handler frames) | Task 4 |
| Task 5 (program entry + output) | Task 5 |
| Task 6 (golden corpus) | Task 6 |
| Sketch open Q: multi-shot resume safety | Task 4 multi-shot test (immutable builder/handler/scope) |
| Sketch open Q: `main`'s ambient effects | Resolved: v1 pure, `main` 0-arity, effects discharged by handlers (Design decisions) |
| Sketch open Q: tail behavior / trampoline | `run` is already a heap `loop` over `Config`; `Jump` reuses the stored kont (no growth). Noted in Design + Task 3. |
| Sketch open Q: typed values | Type-erased, matches Scope B. |

**Type-consistency check (names used across tasks):**
- `Scope { scEnv, scJoins }`, `bindBinder`, `bindBinders`, `resolveAtom`, `renderValue` — defined Task 1, used Tasks 3–6. Consistent.
- `Prim { primName, primArity, primArgs, primFn }`, `PRDone`/`PRApply` — defined Task 1, populated Task 2, consumed by `enter` Task 3. Consistent.
- `Kont` frames `KDone/KLet/KApp/KHandle` — defined Task 1, produced/consumed Tasks 3–4. `KHandle Handler Scope Kont` shape matches `findHandler`/`returnTo`. Consistent.
- `VCont (Kont -> Kont)` — produced in `dispatchOp` (Task 4), consumed in `enter` (Task 3). Consistent (Task 3 ships `enter`'s `VCont` arm before Task 4 produces one; harmless).
- `runModule`/`evalExprWith` — defined Task 3, exercised Tasks 4–6. Consistent.
- `dispatchOp` stub (Task 3) → real (Task 4): same signature `Text -> Text -> [Value] -> Kont -> Either RuntimeError Config`. Consistent.

**Placeholder scan:** no `TBD`/"add error handling"/"similar to"; every code step carries complete code; every test step carries complete test bodies and exact expected strings.

**Known sharp edges (documented, not gaps):**
- 0-arity non-`main` CAF constants used as cross-binding values are not forced (they resolve to `VClosure _ [] _`). The corpus avoids them; `main` itself is the only 0-arity binding that is run (via `enter`/direct `Eval`). If a CAF need arises, force 0-arg closures at use sites in a follow-up.
- The `run golden` harness uses `elaborateProgram` (entry-module only); cross-module function calls require Task 7.
