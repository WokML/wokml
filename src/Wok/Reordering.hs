-- | Operator-precedence stage: build the fixity table from a parsed
-- 'Module', then reassociate its flat infix chains into precedence trees.
module Wok.Reordering
  ( -- * Fixity table
    OpKind(..)
  , OpInfo(..)
  , FixityTable
  , emptyFixityTable
  , entriesOf
  , lookupOp
  , FixityError(..)
  , buildFixityTable
  , overlayFixities
  , assocOf
  , kindOf
  , Order(..)
  , compareOps
    -- * Infix-chain reordering
  , ReorderError(..)
  , ReorderedModule(..)
  , reorderModule
  , reorderModuleWith
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Graph as G
import Data.Text (Text)
import GeneratedParser.Wok.Abs

-- ---------------------------------------------------------------------
-- Fixity table: built from the DFixity declarations in a parsed Module.
-- ---------------------------------------------------------------------

data OpKind = Sym | Alpha
  deriving (Eq, Show)

data OpInfo = OpInfo
  { opAssoc   :: FixAssoc
  , opKind    :: OpKind
  , opTighter :: [Text]
  , opLooser  :: [Text]
  , opPos     :: BNFC'Position
  }
  deriving (Show)

newtype FixityTable = FixityTable { entriesOf :: Map.Map Text OpInfo }
  deriving (Show)

-- | An empty fixity table. Identity for 'overlayFixities' and the
-- starting accumulator used by the module loader.
emptyFixityTable :: FixityTable
emptyFixityTable = FixityTable Map.empty

lookupOp :: FixityTable -> Text -> Maybe OpInfo
lookupOp (FixityTable m) k = Map.lookup k m

data FixityError
  = RedeclaredOp Text BNFC'Position BNFC'Position
  | SelfReference Text BNFC'Position
  | UnresolvedNeighbor Text Text BNFC'Position
  | CycleInOrder [Text]
  deriving (Eq, Show)

data Order = Tighter | Looser | Equal | Incomparable
  deriving (Eq, Show)

buildFixityTable :: Module -> Either [FixityError] FixityTable
buildFixityTable (Module decls) =
  let (table, decErrs) = foldl' collect (Map.empty, []) decls
      neighborErrs     = checkNeighbors table
      cycleErrs        = checkCycles table
      allErrs          = decErrs ++ neighborErrs ++ cycleErrs
  in if null allErrs
       then Right (FixityTable table)
       else Left allErrs
  where
    collect (m, errs) (DFixity fn assoc rels) =
      let (name, kind, pos) = fixNameInfo fn
          (tighter, looser) = partitionRels rels
          info = OpInfo
            { opAssoc   = assoc
            , opKind    = kind
            , opTighter = tighter
            , opLooser  = looser
            , opPos     = pos
            }
          selfErrs
            | name `elem` tighter || name `elem` looser = [SelfReference name pos]
            | otherwise                                 = []
          (m', redeclErrs) = case Map.lookup name m of
            Just prev -> (m, [RedeclaredOp name (opPos prev) pos])
            Nothing   -> (Map.insert name info m, [])
      in (m', errs ++ selfErrs ++ redeclErrs)
    collect acc _ = acc

-- | Left-biased union of two fixity tables. On any operator name that
-- appears in BOTH, returns 'RedeclaredOp name posA posB' (one entry per
-- offending operator), with @posA@ taken from the first table and
-- @posB@ from the second. Used by the module loader to detect cross-
-- module fixity conflicts when merging imports' tables.
overlayFixities
  :: FixityTable -> FixityTable -> Either [FixityError] FixityTable
overlayFixities (FixityTable a) (FixityTable b) =
  let clashes = Map.intersectionWithKey
                  (\k ai bi -> RedeclaredOp k (opPos ai) (opPos bi))
                  a b
  in case Map.elems clashes of
       [] -> Right (FixityTable (Map.union a b))
       es -> Left es

checkNeighbors :: Map.Map Text OpInfo -> [FixityError]
checkNeighbors m =
  [ UnresolvedNeighbor name n (opPos info)
  | (name, info) <- Map.toList m
  , n <- opTighter info ++ opLooser info
  , not (Map.member n m)
  ]

-- SCC here because we can do detect all cycles in one pass.
checkCycles :: Map.Map Text OpInfo -> [FixityError]
checkCycles m =
  let nodes = [ (k, k, filter (/= k) (outEdgesIn m k)) | k <- Map.keys m ]
  in [ CycleInOrder cs | G.CyclicSCC cs <- G.stronglyConnComp nodes ]

-- Direct edges: x -> y means x binds tighter than y.
-- Out-edges of k come from two sources:
--   1. opTighter on entry k itself (k is declared tighter than those)
--   2. opLooser on any other entry j that mentions k (j looser than k => k tighter than j)
outEdgesIn :: Map.Map Text OpInfo -> Text -> [Text]
outEdgesIn m k =
  let fromTighter = maybe [] opTighter (Map.lookup k m)
      fromLooser  = [ k' | (k', info) <- Map.toList m, k `elem` opLooser info ]
  in fromTighter ++ fromLooser

fixNameInfo :: FixName -> (Text, OpKind, BNFC'Position)
fixNameInfo (FNSym   (VarSym (p, s))) = (s, Sym,   Just p)
fixNameInfo (FNAlpha (VarId  (p, s))) = (s, Alpha, Just p)

partitionRels :: [FixRel] -> ([Text], [Text])
partitionRels = foldr step ([], [])
  where
    step (FRTight fn) (t, l) = let (n, _, _) = fixNameInfo fn in (n : t, l)
    step (FRLoose fn) (t, l) = let (n, _, _) = fixNameInfo fn in (t, n : l)

assocOf :: FixityTable -> Text -> Maybe FixAssoc
assocOf t k = opAssoc <$> lookupOp t k

kindOf :: FixityTable -> Text -> Maybe OpKind
kindOf t k = opKind <$> lookupOp t k

compareOps :: FixityTable -> Text -> Text -> Order
compareOps (FixityTable m) a b
  | a == b                                       = Equal
  | not (Map.member a m) || not (Map.member b m) = Incomparable
  | reachable a b                                = Tighter
  | reachable b a                                = Looser
  | otherwise                                    = Incomparable
  where
    reachable src dst = bfs (Set.singleton src) [src]
      where
        bfs _ [] = False
        bfs visited (x : xs)
          | dst `elem` next = True
          | otherwise       = bfs visited' (xs ++ newNodes)
          where
            next     = outEdgesIn m x
            newNodes = filter (`Set.notMember` visited) next
            visited' = foldr Set.insert visited newNodes

-- ---------------------------------------------------------------------
-- Reordering: reassociate flat infix chains using the fixity table.
-- ---------------------------------------------------------------------

-- | Errors produced while reordering flat infix chains.
data ReorderError
  = FixityErr FixityError
  | UndeclaredOperator Text BNFC'Position
  | IncomparableOps Text Text BNFC'Position
  deriving (Show)

data ReorderedModule = ReorderedModule
  { reorderedAst      :: Module
  , reorderedFixities :: FixityTable
  }

-- | Reorder a module's expressions against an *externally supplied*
-- fixity table. The external table is overlaid (left-biased; conflicts
-- reported as 'RedeclaredOp' lifted via 'FixityErr') with the module's
-- own DFixity decls. Used by the module loader to thread imported
-- modules' fixities into the importer's reordering pass.
--
-- The single-module 'reorderModule' is now a thin wrapper that passes
-- 'emptyFixityTable' as the external table.
reorderModuleWith
  :: FixityTable -> Module -> Either [ReorderError] Module
reorderModuleWith externalTable m = do
  ownTable <- mapLeft (map FixityErr) (buildFixityTable m)
  merged   <- mapLeft (map FixityErr) (overlayFixities externalTable ownTable)
  reorderAst merged m

reorderModule :: Module -> Either [ReorderError] ReorderedModule
reorderModule m = do
  table <- mapLeft (map FixityErr) (buildFixityTable m)
  ast   <- reorderModuleWith emptyFixityTable m
  Right (ReorderedModule ast table)

mapLeft :: (e -> e') -> Either e a -> Either e' a
mapLeft f = either (Left . f) Right

-- AST walk: reorder every EExpr in the module bottom-up.

reorderAst :: FixityTable -> Module -> Either [ReorderError] Module
reorderAst t (Module ds) = Module <$> traverse (reorderDecl t) ds

reorderDecl :: FixityTable -> Decl -> Either [ReorderError] Decl
reorderDecl t (DEqn lhs e mw) = DEqn lhs <$> reorderExp t e <*> reorderMW t mw
reorderDecl _ d@(DSig{})      = Right d
reorderDecl _ d@(DData{})     = Right d
reorderDecl _ d@(DEffect{})   = Right d  -- operation types contain no exprs to reorder
reorderDecl _ d@(DClass{})    = Right d  -- fully typechecked + desugared downstream; passed through here
reorderDecl _ d@(DInstance{}) = Right d  -- fully typechecked + desugared downstream; passed through here
reorderDecl _ d@(DFixity{})   = Right d
reorderDecl _ d@(DModule{})   = Right d
reorderDecl _ d@(DImport{})   = Right d
reorderDecl _ d@(DUse{})      = Right d
reorderDecl t (DLocal d)      = DLocal <$> reorderDecl t d
reorderDecl _ d@(DReserved{}) = Right d

reorderLocalDecl :: FixityTable -> LocalDecl -> Either [ReorderError] LocalDecl
reorderLocalDecl t (LDEqn lhs e mw) = LDEqn lhs <$> reorderExp t e <*> reorderMW t mw
reorderLocalDecl t (LDPat p ps e)   = LDPat p ps <$> reorderExp t e
reorderLocalDecl _ d@(LDSig{})      = Right d

reorderMW :: FixityTable -> MaybeWhere -> Either [ReorderError] MaybeWhere
reorderMW _ NoWhere     = Right NoWhere
reorderMW t (WithWh ds) = WithWh <$> traverse (reorderLocalDecl t) ds

reorderAlt :: FixityTable -> Alt -> Either [ReorderError] Alt
reorderAlt t (AltC p e mw) = AltC p <$> reorderExp t e <*> reorderMW t mw

reorderExp :: FixityTable -> Exp -> Either [ReorderError] Exp
reorderExp t (EExpr h tails) = do
  h'     <- reorderExp t h
  tails' <- traverse (reorderTail t) tails
  case tails' of
    [] -> Right h'
    _  -> mapLeft (: []) (reorderChain t h' tails')
reorderExp t (EApp f x)      = EApp <$> reorderExp t f <*> reorderExp t x
reorderExp t (EParen e)      = EParen <$> reorderExp t e
reorderExp t (EList es)      = EList <$> traverse (reorderExp t) es
reorderExp t (ETuple e es)   = ETuple <$> reorderExp t e <*> traverse (reorderExp t) es
reorderExp t (ELam ps body)  = ELam ps <$> reorderExp t body
reorderExp t (ELet lds body) = ELet <$> traverse (reorderLocalDecl t) lds <*> reorderExp t body
reorderExp t (ECase s alts)  = ECase <$> reorderExp t s <*> traverse (reorderAlt t) alts
reorderExp t (EIf a b c)     = EIf <$> reorderExp t a <*> reorderExp t b <*> reorderExp t c
reorderExp t (EProj e s)     = (\e' -> EProj e' s)  <$> reorderExp t e
reorderExp t (EProjC e s)    = (\e' -> EProjC e' s) <$> reorderExp t e
reorderExp _ e               = Right e

reorderTail :: FixityTable -> InfixTail -> Either [ReorderError] InfixTail
reorderTail t (ITail op rhs) = ITail op <$> reorderExp t rhs

-- ---------------------------------------------------------------------
-- Chain resolution: split a flat chain at the loosest operator and recurse.
-- Equal precedence in this language means "same operator name" (the partial
-- order has no cross-operator equivalence classes), so left-assoc ties pick
-- the rightmost split and right-assoc ties pick the leftmost.
-- ---------------------------------------------------------------------

reorderChain :: FixityTable -> Exp -> [InfixTail] -> Either ReorderError Exp
reorderChain _ h [] = Right h
reorderChain t h tails = do
  mapM_ (checkDeclared t) tails
  idx <- findLoosest t tails
  case splitAt idx tails of
    (leftTails, ITail splitOp splitRhs : rightTails) -> do
      leftExpr  <- reorderChain t h leftTails
      rightExpr <- reorderChain t splitRhs rightTails
      Right (combineInfix leftExpr splitOp rightExpr)
    _ -> error "reorderChain: findLoosest returned out-of-range index"

checkDeclared :: FixityTable -> InfixTail -> Either ReorderError ()
checkDeclared t (ITail op _) =
  let (name, pos) = infixOpInfo op
  in case lookupOp t name of
       Just _  -> Right ()
       Nothing -> Left (UndeclaredOperator name pos)

findLoosest :: FixityTable -> [InfixTail] -> Either ReorderError Int
findLoosest _ []                   = error "findLoosest: empty tails"
findLoosest t (ITail op0 _ : rest) = go 0 op0 1 rest
  where
    go bestIdx _ _ [] = Right bestIdx
    go bestIdx bestOp i (ITail op _ : xs) = do
      let (curName, curPos) = infixOpInfo op
          (bestName, _)     = infixOpInfo bestOp
      case compareOps t curName bestName of
        Tighter      -> go bestIdx bestOp (i + 1) xs
        Looser       -> go i op (i + 1) xs
        Equal ->
          case assocOf t bestName of
            Just FALeft  -> go i op (i + 1) xs
            Just FARight -> go bestIdx bestOp (i + 1) xs
            Nothing      -> go bestIdx bestOp (i + 1) xs
        Incomparable -> Left (IncomparableOps bestName curName curPos)

combineInfix :: Exp -> InfixOp -> Exp -> Exp
combineInfix lhs op rhs = EExpr (wrap lhs) [ITail op (wrap rhs)]
  where
    wrap e@(EExpr _ (_ : _)) = EParen e
    wrap e                   = e

infixOpInfo :: InfixOp -> (Text, BNFC'Position)
infixOpInfo (IOSym (VarSym (p, s))) = (s, Just p)
infixOpInfo (IOBT  (VarId  (p, s))) = (s, Just p)
