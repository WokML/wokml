{-# LANGUAGE OverloadedStrings #-}

-- | The initial typing environment: built-in type constructors,
-- built-in data constructors (True/False), and the schemes of
-- primitive operators that user code can reference by name.
module Wok.TypeChecking.Builtins
  ( initialEnv
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Text
import Data.Text (Text)
import Wok.TypeChecking.Env (ConInfo (..), Env (..), TyConInfo (..), emptyEnv)
import Wok.TypeChecking.Types
  ( CRow (..), CType (..), Kind (..), Scheme (..), TyCon (..) )

initialEnv :: Env
initialEnv = emptyEnv
  { envTyCons = Map.fromList tyConEntries
  , envCons   = Map.fromList conEntries
  , envVars   = Map.fromList varEntries
  }
  where
    listKind :: Kind
    listKind = KArrow KStar KStar

    tyConEntries :: [(Text, TyConInfo)]
    tyConEntries =
      [ ("Int",    TyConInfo KStar 0 [])
      , ("Char",   TyConInfo KStar 0 [])
      , ("String", TyConInfo KStar 0 [])
      , ("Bool",   TyConInfo KStar 0 ["True", "False"])
      , ("()",     TyConInfo KStar 0 [])
      , ("[]",     TyConInfo listKind 1 [])
      ] ++ [ (tupleName n, TyConInfo (tupleKind n) n []) | n <- [2 .. 16] ]

    tupleName :: Int -> Text
    tupleName n = "(" <> Data.Text.replicate (n - 1) "," <> ")"

    tupleKind :: Int -> Kind
    tupleKind n = foldr KArrow KStar (replicate n KStar)

    conEntries :: [(Text, ConInfo)]
    conEntries =
      [ ("True",  ConInfo (Scheme [] (CTCon TcBool [])) 0 "Bool")
      , ("False", ConInfo (Scheme [] (CTCon TcBool [])) 0 "Bool")
      ]

    varEntries :: [(Text, Scheme)]
    varEntries =
      [ ("+",   intBinop)
      , ("-",   intBinop)
      , ("*",   intBinop)
      , ("/",   intBinop)
      , ("div", intBinop)
      , ("mod", intBinop)
      , ("==",  intToBool)
      , ("/=",  intToBool)
      , ("&&",  boolBinop)
      , ("||",  boolBinop)
      , ("++",  listConcat)
      , ("$",   dollar)
      ]

    intBinop :: Scheme
    intBinop = Scheme []
      (CTArr (CTCon TcInt []) CREmpty
        (CTArr (CTCon TcInt []) CREmpty (CTCon TcInt [])))

    intToBool :: Scheme
    intToBool = Scheme []
      (CTArr (CTCon TcInt []) CREmpty
        (CTArr (CTCon TcInt []) CREmpty (CTCon TcBool [])))

    boolBinop :: Scheme
    boolBinop = Scheme []
      (CTArr (CTCon TcBool []) CREmpty
        (CTArr (CTCon TcBool []) CREmpty (CTCon TcBool [])))

    listConcat :: Scheme
    listConcat = Scheme [(0, KStar)]
      (CTArr (CTCon TcList [CTGen 0]) CREmpty
        (CTArr (CTCon TcList [CTGen 0]) CREmpty (CTCon TcList [CTGen 0])))

    dollar :: Scheme
    dollar = Scheme [(0, KStar), (1, KStar)]
      (CTArr (CTArr (CTGen 0) CREmpty (CTGen 1)) CREmpty
        (CTArr (CTGen 0) CREmpty (CTGen 1)))
