-- | Pure constraint resolver: maps a class name and a frozen class-argument
-- 'CType' (plus the set of in-scope quantified evidence-parameter indices) to
-- an 'Evidence' term, or a precise failure.
--
-- Used by BOTH the type-checker (to validate dischargeability) and elaboration
-- (to build the dictionary term). Must stay pure -- no TC\/ST.
module Wok.TypeChecking.Solve
  ( SolveError (..)
  , resolve
  , paramName
  ) where

import qualified Data.Map.Strict as Map
import           Data.Map.Strict (Map)
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text)
import qualified Data.Text as Tx
import           Wok.TypeChecking.Env (lookupInstances, iiHead, iiContext, iiDictName)
import           Wok.TypeChecking.Env (Env)
import           Wok.TypeChecking.Types (CType (..), Constraint (..), Evidence (..), TyCon)

-- | Resolver failure modes.
data SolveError
  = NoInst Text CType   -- ^ no instance for (class, type)
  | Ambiguous Text       -- ^ class-arg is a free type variable not in scope
  deriving (Eq, Show)

-- | Canonical evidence-parameter name shared with Task 7 (minting) and
-- Task 9 (binder lookup): @"d$" <> cls <> "$" <> show i@.
paramName :: Text -> Int -> Text
paramName cls i = Tx.pack "d$" <> cls <> Tx.pack "$" <> Tx.pack (show i)

-- | Resolve a single class constraint.
--
-- * 'CTGen' i in @params@ -> 'EvParam' (canonical name).
-- * 'CTGen' i NOT in @params@ -> 'Left' 'Ambiguous'.
-- * 'CTCon' c args -> find the matching instance, recurse on its context
--   (substituting the head's generic slots with the concrete args),
--   return 'EvGlobal' (no context) or 'EvApp' (with sub-evidence).
-- * Anything else -> 'Left' 'NoInst'.
resolve :: Env -> Set Int -> Text -> CType -> Either SolveError Evidence
resolve env params cls arg = case arg of
  CTGen i
    | i `Set.member` params -> Right (EvParam (paramName cls i))
    | otherwise             -> Left (Ambiguous cls)
  CTCon c _cargs ->
    case [ inst | inst <- lookupInstances cls env, headConEq (iiHead inst) c ] of
      (inst : _) -> do
        sub <- instMatch (iiHead inst) arg
        evs <- mapM (\ctx -> resolve env params (conClass ctx)
                              (applySub sub (conArg ctx)))
                    (iiContext inst)
        Right $ if null evs
                  then EvGlobal (iiDictName inst)
                  else EvApp   (iiDictName inst) evs
      [] -> Left (NoInst cls arg)
  _ -> Left (NoInst cls arg)
  where
    headConEq :: CType -> TyCon -> Bool
    headConEq (CTCon hc _) c = hc == c
    headConEq _            _ = False

-- | Match an instance head (which may contain 'CTGen' slots) against a
-- concrete argument, producing a substitution from generic indices to
-- concrete types.
--
-- Example:
-- > instMatch (CTCon (TcUser "Option") [CTGen 0]) (CTCon (TcUser "Option") [CTCon TcU64 []])
-- > = Right (Map.fromList [(0, CTCon TcU64 [])])
instMatch :: CType -> CType -> Either SolveError (Map Int CType)
instMatch (CTGen i) t = Right (Map.singleton i t)
instMatch (CTCon c1 as) (CTCon c2 bs)
  | c1 == c2 && length as == length bs =
      fmap Map.unions (mapM (uncurry instMatch) (zip as bs))
instMatch (CTArr a1 _ b1) (CTArr a2 _ b2) =
  Map.union <$> instMatch a1 a2 <*> instMatch b1 b2
instMatch (CTRecord t1 _) (CTRecord t2 _)
  | t1 == t2 = Right Map.empty
instMatch _ actual = Left (NoInst (Tx.pack "<instMatch>") actual)

-- | Apply a generic-index substitution to a 'CType'.
-- Rows are not substituted: constraints only range over @*@-kinded type
-- variables, never over row variables.
applySub :: Map Int CType -> CType -> CType
applySub m = go
  where
    go (CTGen i)     = Map.findWithDefault (CTGen i) i m
    go (CTCon c ts)  = CTCon c (map go ts)
    go (CTArr a r b) = CTArr (go a) r (go b)
    go (CTRecord t r) = CTRecord t r
