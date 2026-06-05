-- | Pure decision-tree pattern-match compiler (Sestoft 1996 / Jacobs 2021
-- matrix construction with a leftmost-constructor-column heuristic; necessity
-- scoring is unnecessary for human-written matches per Scott & Ramsey 2000).
-- Turns a clause matrix into an ANF decision tree whose leaves Jump to
-- per-clause join points.  Depends only on the IR and type vocabulary --
-- never on Elaborate or Env -- so it can be unit-tested in isolation and
-- cannot form an import cycle.
module Wok.IR.Match
  ( MPat (..)
  , MPatF (..)
  , Row (..)
  , ConOracle (..)
  , Coverage (..)
  , compileMatch
  , matchCoverage
  , tupleTag
  ) where

import Control.Monad (replicateM)
import Data.Maybe (fromMaybe, maybeToList)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Anf (Alt (..), Atom (..), Binder (..), Expr (..), Lit (..), Mult (..))
import Wok.IR.Name (Fresh, JoinId, freshName)
import Wok.TypeChecking.Types (CType (..), TyCon (..))

data MPat = MPat CType MPatF
  deriving (Show)

data MPatF
  = MVar (Maybe Text)   -- variable (Just v) or wildcard (Nothing)
  | MCon Text [MPat]    -- data constructor / TupleN / Nil / Cons
  | MLit Lit            -- literal
  deriving (Show)

data ConOracle = ConOracle
  { coArity    :: Text -> Int           -- field count of a constructor tag
  , coSiblings :: Text -> Maybe [Text]  -- complete sibling-tag set, or Nothing for
                                        -- types with no finite signature (literals)
  }

-- | Invariant: @length rowPats == length scruts@ for every 'Row' passed to
-- 'compileMatch'; the partial @(!! i)@ indexing in 'chooseColumn' and
-- 'switchOn' relies on this.
data Row = Row
  { rowPats  :: [MPat]
  , rowSubst :: [(Text, Atom)]
  , rowJoin  :: JoinId
  , rowOrder :: [Text]
  , rowIndex :: Int
  }
  deriving (Show)

-- Canonical definition of the tuple constructor tag. NOTE: Elaborate.hs has a
-- local copy; that copy will be collapsed to import this one in Task 4.
tupleTag :: Int -> Text
tupleTag n = Tx.pack ("Tuple" ++ show n)

failLeaf :: Expr
failLeaf = Case (ALit LUnit) []

removeAt :: Int -> [a] -> [a]
removeAt i xs = take i xs ++ drop (i + 1) xs

isWildP :: MPat -> Bool
isWildP (MPat _ (MVar _)) = True
isWildP _                 = False

mpatType :: MPat -> CType
mpatType (MPat t _) = t

compileMatch :: ConOracle -> [Atom] -> [Row] -> Fresh Expr
compileMatch _ _ [] = pure failLeaf
compileMatch oracle scruts rows@(r0 : _)
  | all isWildP (rowPats r0) = pure (jumpLeaf (bindRow scruts r0))
  | otherwise = do
      let i = chooseColumn scruts rows
      switchOn oracle i scruts rows

bindRow :: [Atom] -> Row -> Row
bindRow scruts r =
  r { rowSubst = rowSubst r
        ++ [ (v, a) | (MPat _ (MVar (Just v)), a) <- zip (rowPats r) scruts ] }

jumpLeaf :: Row -> Expr
jumpLeaf r = Jump (rowJoin r) [ atomFor v | v <- rowOrder r ]
  where
    atomFor v =
      fromMaybe (error ("Match.jumpLeaf: unbound clause variable " <> Tx.unpack v))
                (lookup v (rowSubst r))

-- | Choose the scrutinee column to switch on next.
--
-- Heuristic: prefer the leftmost column whose first non-wildcard pattern is a
-- constructor (enabling a dense tag switch) over a literal column; fall back
-- to the leftmost column with any non-wildcard pattern if no constructor
-- column exists.  The all-wildcard-first-row case is already dispatched by
-- 'compileMatch' before 'switchOn' is reached, so the @[]@ fallback below is
-- unreachable in practice.
chooseColumn :: [Atom] -> [Row] -> Int
chooseColumn scruts rows =
  let cols         = [0 .. length scruts - 1]
      hasNonWild c = not (all (isWildP . (!! c) . rowPats) rows)
      isConCol   c = any (\r -> case rowPats r !! c of MPat _ (MCon _ _) -> True; _ -> False) rows
      candidates   = filter hasNonWild cols
  in case filter isConCol candidates of
       (c : _) -> c
       []      -> case candidates of
                    (c : _) -> c
                    -- Unreachable: compileMatch handles the all-wildcard case.
                    []      -> 0

switchOn :: ConOracle -> Int -> [Atom] -> [Row] -> Fresh Expr
switchOn oracle i scruts rows = do
  let scrutI = scruts !! i
      others = removeAt i scruts
      heads  = nubHeads [ rowPats r !! i | r <- rows ]
  alts <- mapM (buildHeadAlt oracle i scrutI others rows) heads
  mDef <- buildDefault oracle i scrutI others rows heads
  pure (Case scrutI (alts ++ maybeToList mDef))

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
  let arity    = coArity oracle c
      fieldTys = fieldTypesOf c i rows arity
  fieldNames <- replicateM arity (freshName (Tx.pack "f"))
  let fieldAtoms   = map AVar fieldNames
      fieldBinders = zipWith (`Binder` Unrestricted) fieldNames fieldTys
      rows'        = concatMap (specCon c arity i scrutI) rows
      scruts'      = fieldAtoms ++ others
  body <- compileMatch oracle scruts' rows'
  pure (AltCon c fieldBinders body)
buildHeadAlt oracle i scrutI others rows (MLit l) = do
  let rows' = concatMap (specLit l i scrutI) rows
  body <- compileMatch oracle others rows'
  pure (AltLit l body)
buildHeadAlt _ _ _ _ _ (MVar _) = error "Match.buildHeadAlt: variable is not a head"

fieldTypesOf :: Text -> Int -> [Row] -> Int -> [CType]
fieldTypesOf c i rows arity =
  case [ map mpatType subs | r <- rows
                           , MPat _ (MCon c' subs) <- [rowPats r !! i], c' == c ] of
    (ts : _) -> ts
    []       -> replicate arity (CTCon TcUnit [])

specCon :: Text -> Int -> Int -> Atom -> Row -> [Row]
specCon c arity i scrutI r =
  case rowPats r !! i of
    MPat _ (MCon c' subs) | c' == c -> [ r { rowPats = subs ++ removeAt i (rowPats r) } ]
    MPat _ (MCon _ _) -> []
    MPat _ (MLit _)   -> []
    MPat _ (MVar mv)  ->
      [ r { rowPats  = replicate arity wildField ++ removeAt i (rowPats r)
          , rowSubst = bindVar mv scrutI (rowSubst r) } ]
  where wildField = MPat (CTCon TcUnit []) (MVar Nothing)

specLit :: Lit -> Int -> Atom -> Row -> [Row]
specLit l i scrutI r =
  case rowPats r !! i of
    MPat _ (MLit l') | l' == l -> [ r { rowPats = removeAt i (rowPats r) } ]
    MPat _ (MLit _)            -> []
    MPat _ (MCon _ _)          -> []
    MPat _ (MVar mv)           ->
      [ r { rowPats = removeAt i (rowPats r), rowSubst = bindVar mv scrutI (rowSubst r) } ]

buildDefault :: ConOracle -> Int -> Atom -> [Atom] -> [Row] -> [MPatF] -> Fresh (Maybe Alt)
buildDefault oracle i scrutI others rows heads
  | completeHeads oracle heads = pure Nothing
  | otherwise = do
      let defRows = [ r { rowPats = removeAt i (rowPats r)
                        , rowSubst = bindVar mv scrutI (rowSubst r) }
                    | r <- rows, MPat _ (MVar mv) <- [rowPats r !! i] ]
      body <- compileMatch oracle others defRows
      pure (Just (AltDefault body))

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

-- | Result of the Maranget usefulness analysis over a clause matrix.
data Coverage = Coverage
  { covRedundant  :: [Int]   -- ^ original indices of clauses that can never match
  , covExhaustive :: Bool    -- ^ whether the matrix covers every input
  }
  deriving (Eq, Show)

-- | Analyse a matrix for redundancy and exhaustiveness. 'ncols' is the number of
-- argument columns. Mirrors the 'compileMatch' recursion but tracks only which
-- rows are reached at a success leaf and whether any failure leaf is reachable.
-- Patterns only -- no atoms -- so it does not thread scrutinees.
matchCoverage :: ConOracle -> Int -> [Row] -> Coverage
matchCoverage oracle ncols rows =
  let (reached, anyFail) = analyze ncols rows
  in Coverage
       { covRedundant  = [ rowIndex r | r <- rows, not (rowIndex r `Set.member` reached) ]
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

    -- pickCol / specConP / specLitP are deliberate pattern-only copies of the
    -- atom-threading chooseColumn / specCon / specLit used by compileMatch: the
    -- coverage analysis carries no scrutinee atoms, so it cannot reuse them
    -- directly. Keep the two families in sync if either changes.
    pickCol n rws =
      let idxs         = [0 .. n - 1]
          hasNonWild c = not (all (isWildP . (!! c) . rowPats) rws)
          isConCol   c = any (\r -> case rowPats r !! c of MPat _ (MCon _ _) -> True; _ -> False) rws
          cands        = filter hasNonWild idxs
      in case filter isConCol cands of
           (c : _) -> c
           []      -> case cands of (c : _) -> c; [] -> 0   -- avoid partial head

    specConP c arity i r = case rowPats r !! i of
      MPat _ (MCon c' subs) | c' == c -> [ r { rowPats = subs ++ removeAt i (rowPats r) } ]
      MPat _ (MCon _ _)               -> []
      MPat _ (MLit _)                 -> []
      MPat _ (MVar _)                 ->
        [ r { rowPats = replicate arity wildField ++ removeAt i (rowPats r) } ]
      where wildField = MPat (CTCon TcUnit []) (MVar Nothing)
        -- NB: CTCon TcUnit [] is a never-read placeholder type. StrictData forces
        -- the field, so a lazy `error` thunk cannot be used here (matches Task 1).

    specLitP l i r = case rowPats r !! i of
      MPat _ (MLit l') | l' == l -> [ r { rowPats = removeAt i (rowPats r) } ]
      MPat _ (MLit _)            -> []
      MPat _ (MCon _ _)          -> []
      MPat _ (MVar _)            -> [ r { rowPats = removeAt i (rowPats r) } ]
