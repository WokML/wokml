-- | The irreducible pre-environment. Everything spellable in Wok lives
-- in Std.Base (loaded by Wok.Loader before user code). Only the tycons
-- that cannot be expressed in surface Wok stay here:
--
--   * U64                  -- opaque machine integer
--   * ()                   -- unit; parens aren't a ConId
--   * []                   -- cons list; brackets aren't a ConId
--   * (,), (,,), ... (16-tuple) -- parens aren't a ConId
--
-- No constructors, no operator schemes, no helpers.
module Wok.TypeChecking.Builtins
  ( initialEnv
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Text
import Data.Text (Text)
import Wok.TypeChecking.Env (Env (..), TyConInfo (..), ConInfo (..), emptyEnv)
import Wok.TypeChecking.Types
  ( Kind (..)
  , CType (..)
  , CRow (..)
  , TyCon (..)
  , Scheme (..)
  )

initialEnv :: Env
initialEnv = emptyEnv
  { envTyCons = Map.fromList tyConEntries
  , envCons   = Map.fromList conEntries
  }
  where
    listKind :: Kind
    listKind = KArrow KStar KStar

    suspensionKind :: Kind
    suspensionKind = KArrow KStar (KArrow KStar (KArrow KStar KStar))

    stepKind :: Kind
    stepKind = KArrow KStar (KArrow KStar (KArrow KStar KStar))

    tyConEntries :: [(Text, TyConInfo)]
    tyConEntries =
      [ ("U64",    TyConInfo KStar 0 [])
      , ("U32",    TyConInfo KStar 0 [])
      , ("String", TyConInfo KStar 0 [])
      , ("Never",  TyConInfo KStar 0 [])
      , ("Char",   TyConInfo KStar 0 [])
      , ("()",     TyConInfo KStar 0 [])
      , ("[]",     TyConInfo listKind 1 [])
      , ("Suspension", TyConInfo suspensionKind 3 [])
      , ("Step", TyConInfo stepKind 3 [Data.Text.pack "Completed", Data.Text.pack "Suspended"])
      ] ++ [ (tupleName n, TyConInfo (tupleKind n) n []) | n <- [2 .. 16] ]

    -- | The built-in transparent ADT
    -- @Step a b r = Completed r | Suspended a (Suspension a b r)@.
    -- @CTGen 0@ = a, @CTGen 1@ = b, @CTGen 2@ = r. The constructors' runtime
    -- tags coincide with the prims' VCon tags ("Completed"/"Suspended").
    stepTy :: CType
    stepTy = CTCon TcStep [CTGen 0, CTGen 1, CTGen 2]

    suspTy :: CType
    suspTy = CTCon TcSuspension [CTGen 0, CTGen 1, CTGen 2]

    vars3 :: [(Int, Kind)]
    vars3 = [(0, KStar), (1, KStar), (2, KStar)]

    arr :: CType -> CType -> CType
    arr d c = CTArr d CREmpty c

    conEntries :: [(Text, ConInfo)]
    conEntries =
      [ ( Data.Text.pack "Completed"
        , ConInfo (Scheme vars3 [] (arr (CTGen 2) stepTy)) 1 (Data.Text.pack "Step") )
      , ( Data.Text.pack "Suspended"
        , ConInfo (Scheme vars3 [] (arr (CTGen 0) (arr suspTy stepTy))) 2 (Data.Text.pack "Step") )
      ]

    tupleName :: Int -> Text
    tupleName n = "(" <> Data.Text.replicate (n - 1) "," <> ")"

    tupleKind :: Int -> Kind
    tupleKind n = foldr KArrow KStar (replicate n KStar)
