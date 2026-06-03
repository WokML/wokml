{-# LANGUAGE DeriveTraversable #-}
module Wok.TypeChecking.Typed
  ( Texp (..), TexpF (..)
  , Tpat (..), TpatF (..)
  , TAlt (..), THandlerArm (..), TLocalDecl (..)
  , TExprS, TExpr, TPatS, TPat
  ) where

import Data.Text (Text)
import Wok.TypeChecking.Types (Type, CType)

-- | An annotated expression node: its type annotation @a@ plus the node.
data Texp a = Texp a (TexpF a)
  deriving (Show, Functor, Foldable, Traversable)

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
  deriving (Show, Functor, Foldable, Traversable)

data TAlt a = TAlt (Tpat a) [TLocalDecl a] (Texp a)   -- pattern, where, body
  deriving (Show, Functor, Foldable, Traversable)

data THandlerArm a
  = TReturnArm (Tpat a) (Texp a)
  | TOpArm Text Text [Tpat a] Text (Texp a)   -- effect, op, args, resume-name, body
  deriving (Show, Functor, Foldable, Traversable)

-- | A local binding (let / where entry): name, params, body. (Sigs carry no
-- runtime content and are dropped during typed-AST construction.)
data TLocalDecl a = TLocalDecl Text [Tpat a] (Texp a)
  deriving (Show, Functor, Foldable, Traversable)

data Tpat a = Tpat a (TpatF a)
  deriving (Show, Functor, Foldable, Traversable)

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
  deriving (Show, Functor, Foldable, Traversable)

type TExprS s = Texp (Type s)
type TExpr    = Texp CType
type TPatS  s = Tpat (Type s)
type TPat     = Tpat CType
