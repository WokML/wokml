-- | Compiler-assisted codemod for the once\/return retrofit.
--
-- Rewrites every handler arm in the .wok corpus to the DECLARED clause kinds
-- introduced by the retrofit: a control arm gains the @once@ keyword, a value
-- arm gains @return@. Plain auto-resume arms and handler params are untouched.
--
-- Text matching cannot do this. In one line of "Std\/Control.wok",
--
-- > with self = State { var s = i ; get -> s ; set x k -> k x () ; v -> (v, s) }
--
-- @get -> s@ and @v -> (v, s)@ are the same shape -- an identifier, an arrow, a
-- body, zero binders -- and receive OPPOSITE treatment: @get@ is a declared
-- arity-0 operation of @State@ and stays plain, while @v@ names no operation
-- and becomes @return v@. Only the effect declaration separates them.
--
-- So classification runs off the real parser and the real effect table. The
-- typechecker is NOT needed: an operation's arity is the number of leading
-- arrows in its declared type, which 'arityOf' counts syntactically. That
-- agrees with @Wok.TypeChecking.Infer.arrowArity@ because @translateConArg@
-- maps both @TFun@ and @TWith@ to @CTArr@ and treats @TParen@ as transparent.
--
-- The rewrite carries two machine certificates, both checked before anything
-- is written:
--
-- * FIDELITY: re-parsing the edited text yields exactly the AST the classifier
--   intended. Checked by comparing @printTree@ of the re-parsed module against
--   @printTree@ of the module the traversal rebuilt. 'printTree' ignores
--   source positions, which is what makes the comparison meaningful -- every
--   insertion shifts the columns of the tokens after it on its line.
--
-- * IDEMPOTENCE: a second run over the rewritten corpus proposes no edits.
--   Holds by construction (converted arms classify as 'VConverted') and is
--   verified by re-running the tool.
--
-- Arms the classifier cannot place are left alone and REPORTED, never skipped
-- silently: the corpus deliberately contains malformed fixtures, and a real
-- miss must not be able to hide among them.
--
-- Usage, from the repository root:
--
-- > cabal run -v0 exe:wok-codemod              -- dry run: certificates + summary
-- > cabal run -v0 exe:wok-codemod -- --audit   -- also dump the per-arm audit trail
-- > cabal run -v0 exe:wok-codemod -- --apply   -- write the rewritten files
module Main (main) where

import Control.Monad (foldM, forM, unless)
import Control.Monad.State.Strict (State, modify', runState)
import qualified Data.ByteString as BS
import Data.Either (partitionEithers)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import System.Directory (doesDirectoryExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath (takeExtension, (</>))

import GeneratedParser.Wok.Abs
import GeneratedParser.Wok.Print (printTree)
import Wok.Parsing (parse)

-- ---------------------------------------------------------------------------
-- The arity table
-- ---------------------------------------------------------------------------

-- | What a file can see of the effect declarations around it.
--
-- 'efArity' maps (effect name, operation name) to arity. The value is a SET so
-- that two declarations of one effect disagreeing about an operation's arity
-- is detectable rather than silently resolved; a non-singleton entry makes
-- every arm mentioning it unclassifiable.
--
-- 'efNames' records every effect name declared in scope, including one with no
-- operations. It is what distinguishes "this name is not an operation of
-- State" from "State itself is not declared here" -- a distinction the value
-- arm rule depends on (see 'classifyArm').
data Effects = Effects
  { efArity :: Map (Text, Text) (Set Int)
  , efNames :: Set Text
  }

instance Semigroup Effects where
  -- Left-biased on arities, matching 'Map.union': a local declaration wins
  -- over an imported one, which is what a reader of that file sees.
  a <> b = Effects (Map.union (efArity a) (efArity b))
                   (Set.union (efNames a) (efNames b))

instance Monoid Effects where
  mempty = Effects Map.empty Set.empty

-- | Leading-arrow count of a declared operation type.
--
-- Mirrors @Wok.TypeChecking.Infer.arrowArity@ over the surface syntax:
-- @TFun@ and @TWith@ are both arrows (@translateConArg@ maps each to
-- @CTArr@); @TParen@ and @TQual@ are transparent; everything else is a result
-- type. A value operation such as @ask : U64@ has arity 0.
arityOf :: Type -> Int
arityOf ty = case ty of
  TParen t    -> arityOf t
  TQual _ t   -> arityOf t
  TFun _ b    -> 1 + arityOf b
  TWith _ b _ -> 1 + arityOf b
  TApp{}      -> 0
  TVar{}      -> 0
  TCon{}      -> 0
  TList{}     -> 0
  TTuple{}    -> 0
  TUnit       -> 0
  TRowArg{}   -> 0
  TOwned{}    -> 0
  TExtend{}   -> 0

-- | Collect one module's own @effect@ declarations.
effectArities :: Module -> Effects
effectArities (Module decls) = Effects
    { efArity = Map.fromListWith Set.union (concatMap ops decls)
    , efNames = Set.fromList (concatMap names decls)
    }
  where
    ops d = case d of
      DEffect (ConId (_, en)) _params fields ->
        [ ((en, op), Set.singleton (arityOf ty))
        | RFType (VarId (_, op)) ty <- fields
        ]
      DLocal inner -> ops inner
      _            -> []

    names d = case d of
      DEffect (ConId (_, en)) _ _ -> [en]
      DLocal inner                -> names inner
      _                           -> []

-- | The module a file declares, if it declares one.
moduleName :: Module -> Maybe Text
moduleName (Module decls) =
  case [ modPathText mp | DModule mp <- decls ] of
    (n : _) -> Just n
    []      -> Nothing

-- | The modules a file imports.
moduleImports :: Module -> [Text]
moduleImports (Module decls) = [ modPathText mp | DImport mp _ <- decls ]

modPathText :: ModPath -> Text
modPathText (MPName (ConId (_, n)))    = n
modPathText (MPDot mp (ConId (_, n)))  = modPathText mp <> "." <> n

-- | Effect names are MODULE-SCOPED, so the arity table must be resolved per
-- file rather than globally. The corpus declares @effect Tick@ in many
-- fixtures with deliberately different arities (@tick : U64@ in one,
-- @tick : U64 -> U64@ in another); a single global table conflates them and
-- makes every such arm unclassifiable.
--
-- Visible arities are the file's OWN declarations unioned with the transitive
-- closure of its imports. 'Map.union' is left-biased, so a local declaration
-- wins -- which is what a reader of that file sees.
visibleArities
  :: Map Text (Effects, [Text])  -- ^ module name -> (own effects, imports)
  -> Module
  -> Effects
visibleArities modules m =
    mconcat (effectArities m : map ownOf (closure Set.empty (moduleImports m)))
  where
    ownOf n = maybe mempty fst (Map.lookup n modules)

    closure _    []       = []
    closure seen (n : ns)
      | n `Set.member` seen = closure seen ns
      | otherwise =
          let seen'  = Set.insert n seen
              nested = maybe [] snd (Map.lookup n modules)
          in n : closure seen' (nested ++ ns)

-- ---------------------------------------------------------------------------
-- Edits and the audit trail
-- ---------------------------------------------------------------------------

-- | A single insertion at a 1-based (line, column) CHARACTER position.
--
-- Columns are character indices, not byte offsets: the generated lexer's
-- @alexMove@ advances one column per 'Char'. The corpus contains no tabs and
-- 42 files contain non-ASCII, so all indexing here goes through 'Data.Text'.
data Edit = Edit
  { eLine :: Int
  , eCol  :: Int
  , eText :: Text
  }

-- | What the classifier decided about one arm.
data Verdict
  = VPlain Text Text Int
    -- ^ Auto-resume arm: binder count equals arity. Effect, op, arity.
  | VOnce Text Text Int
    -- ^ Control arm: binder count is arity + 1. Gains @once@.
  | VReturn Text
    -- ^ Value arm: names no operation, binds nothing. Gains @return@.
  | VConverted Text
    -- ^ Already carries a declared kind, or is a handler param. Left alone.
  | VRefused Text
    -- ^ Unclassifiable. Left alone and reported.

-- | One audit-trail entry per handler arm in the corpus.
data Report = Report
  { rPath    :: FilePath
  , rLine    :: Int
  , rCol     :: Int
  , rHead    :: Text
  , rBinders :: Int
  , rVerdict :: Verdict
  }

data Acc = Acc
  { accEdits   :: [Edit]
  , accReports :: [Report]
  }

type M = State Acc

emit :: Maybe Edit -> Report -> M ()
emit mEdit rep = modify' $ \acc -> Acc
  { accEdits   = maybe id (:) mEdit (accEdits acc)
  , accReports = rep : accReports acc
  }

-- ---------------------------------------------------------------------------
-- Classification: the mapping, as a total decision function
-- ---------------------------------------------------------------------------

-- | Classify one arm and rebuild it with its declared kind applied.
--
-- @header@ is the block's header effect list: the names after @with@ in
-- @with E F { ... }@, or the single name in @with h = E { ... }@. A headerless
-- @with { ... }@ block has none, so its unqualified arms can only be value
-- arms; qualified arms resolve through the effect table either way.
--
-- The value-arm rule -- an unqualified head that names no operation and binds
-- nothing is a value arm -- is sound ONLY when every header effect actually
-- resolves. If a header effect is undeclared in scope, "names no operation of
-- State" is indistinguishable from "State's operations are unknown", and
-- @get -> s@ would be silently rewritten to @return get -> s@. The corpus
-- contains such files: parse-only pretty-printer fixtures like
-- test/examples/28-with-named.wok reference @State@ without declaring it and
-- never reach the typechecker, so nothing downstream would catch the error.
-- Those blocks are refused whole.
classifyArm :: Effects -> [Text] -> HandlerArm -> M HandlerArm
classifyArm table header arm = case arm of
  HArm con@(ConId (pos, en)) op@(VarId (_, opName)) ps body -> do
    body' <- goExp table body
    let n     = length ps
        rep v = Report "" (fst pos) (snd pos) (en <> "." <> opName) n v
    case arityLookup table en opName of
      Left why -> do
        emit Nothing (rep (VRefused why))
        pure (HArm con op ps body')
      Right ar
        | n == ar -> do
            emit Nothing (rep (VPlain en opName ar))
            pure (HArm con op ps body')
        | n == ar + 1 -> do
            emit (Just (Edit (fst pos) (snd pos) "once ")) (rep (VOnce en opName ar))
            pure (HOnceArm con op ps body')
        | otherwise -> do
            emit Nothing (rep (VRefused (arityWhy ar n)))
            pure (HArm con op ps body')

  HUArm v@(VarId (pos, name)) ps body -> do
    body' <- goExp table body
    let n         = length ps
        rep vd    = Report "" (fst pos) (snd pos) name n vd
        unresolved = [ en | en <- header, not (en `Set.member` efNames table) ]
    case [ (en, ar) | en <- header, Right ar <- [arityLookup table en name] ] of
      _ | not (null unresolved) -> do
            emit Nothing (rep (VRefused
              ("header effect " <> T.intercalate ", " unresolved
               <> " is not declared in scope, so this block's operations are \
                  \unknown")))
            pure (HUArm v ps body')
      [(en, ar)]
        | n == ar -> do
            emit Nothing (rep (VPlain en name ar))
            pure (HUArm v ps body')
        | n == ar + 1 -> do
            emit (Just (Edit (fst pos) (snd pos) "once ")) (rep (VOnce en name ar))
            pure (HOnceUArm v ps body')
        | otherwise -> do
            emit Nothing (rep (VRefused (arityWhy ar n)))
            pure (HUArm v ps body')
      []
        | n == 0 -> do
            emit (Just (Edit (fst pos) (snd pos) "return ")) (rep (VReturn name))
            pure (HRetArm (APVar v) body')
        | otherwise -> do
            emit Nothing (rep (VRefused
              ("names no operation of " <> headerText header <> " yet binds "
               <> tshow n <> " pattern(s)")))
            pure (HUArm v ps body')
      matches -> do
        emit Nothing (rep (VRefused
          ("ambiguous: declared by " <> T.intercalate ", " (map fst matches))))
        pure (HUArm v ps body')

  HOnceArm con@(ConId (pos, en)) op@(VarId (_, opName)) ps body -> do
    body' <- goExp table body
    emit Nothing (Report "" (fst pos) (snd pos) (en <> "." <> opName)
                    (length ps) (VConverted "once"))
    pure (HOnceArm con op ps body')

  HOnceUArm v@(VarId (pos, name)) ps body -> do
    body' <- goExp table body
    emit Nothing (Report "" (fst pos) (snd pos) name (length ps) (VConverted "once"))
    pure (HOnceUArm v ps body')

  HRetArm bp body -> do
    body' <- goExp table body
    emit Nothing (Report "" (atomPatLine bp) (atomPatCol bp) (atomPatText bp)
                    0 (VConverted "return"))
    pure (HRetArm bp body')

  HParam v@(VarId (pos, name)) initE -> do
    initE' <- goExp table initE
    emit Nothing (Report "" (fst pos) (snd pos) name 0 (VConverted "param"))
    pure (HParam v initE')

  HParamV v@(VarId (pos, name)) initE -> do
    initE' <- goExp table initE
    emit Nothing (Report "" (fst pos) (snd pos) name 0 (VConverted "var"))
    pure (HParamV v initE')

arityWhy :: Int -> Int -> Text
arityWhy ar n =
  "binds " <> tshow n <> " pattern(s); arity " <> tshow ar <> " admits only "
    <> tshow ar <> " (plain) or " <> tshow (ar + 1) <> " (once)"

headerText :: [Text] -> Text
headerText [] = "the block (no header effects)"
headerText hs = T.intercalate "/" hs

arityLookup :: Effects -> Text -> Text -> Either Text Int
arityLookup table en op = case Map.lookup (en, op) (efArity table) of
  Nothing -> Left ("no declaration found for " <> en <> "." <> op)
  Just s  -> case Set.toList s of
    [a] -> Right a
    as  -> Left ("conflicting declared arities for " <> en <> "." <> op <> ": "
                 <> T.intercalate ", " (map tshow as))

-- Positions for an already-converted @return@ arm are best-effort: only a
-- variable binder carries one. Nothing is edited on these paths, so a missing
-- position costs an audit line's precision and nothing more.
atomPatLine :: AtomPat -> Int
atomPatLine (APVar (VarId (p, _))) = fst p
atomPatLine _                      = 0

atomPatCol :: AtomPat -> Int
atomPatCol (APVar (VarId (p, _))) = snd p
atomPatCol _                      = 0

atomPatText :: AtomPat -> Text
atomPatText (APVar (VarId (_, n))) = n
atomPatText _                      = "<pattern>"

-- ---------------------------------------------------------------------------
-- The rewriting traversal
-- ---------------------------------------------------------------------------
--
-- Every constructor is matched without a catch-all, so grammar growth surfaces
-- here as an incomplete-pattern build error rather than as arms the codemod
-- silently walks past. This mirrors the discipline of
-- @Wok.TypeChecking.Infer.shadowsName@.

goExp :: Effects -> Exp -> M Exp
goExp t e = case e of
  EWith arms body ->
    EWith <$> mapM (classifyArm t []) arms <*> goExp t body
  EWithH con extras arms body ->
    EWithH con extras
      <$> mapM (classifyArm t (map conText (con : extras))) arms
      <*> goExp t body
  EWithNamedH v con arms body ->
    EWithNamedH v con
      <$> mapM (classifyArm t [conText con]) arms
      <*> goExp t body

  EHandlerV con arms ->
    EHandlerV con <$> mapM (classifyArm t [conText con]) arms
  EHandleV h args body ->
    EHandleV <$> goExp t h <*> mapM (goWithArg t) args <*> goExp t body
  EHandleN v h args body ->
    EHandleN v <$> goExp t h <*> mapM (goWithArg t) args <*> goExp t body

  EWithRun v args body    -> EWithRun v <$> mapM (goWithArg t) args <*> goExp t body
  EWithNamed v r args body -> EWithNamed v r <$> mapM (goWithArg t) args <*> goExp t body

  EExpr h tl       -> EExpr <$> goExp t h <*> mapM (goInfixTail t) tl
  EApp f a         -> EApp <$> goExp t f <*> goExp t a
  EProj x f        -> (`EProj` f) <$> goExp t x
  EProjC x f       -> (`EProjC` f) <$> goExp t x
  ERecord c fs     -> ERecord c <$> mapM (goField t) fs
  ERecordExt c x m -> ERecordExt c <$> goExp t x <*> goTrailing t m
  EParen x         -> EParen <$> goExp t x
  EList xs         -> EList <$> mapM (goExp t) xs
  ETuple x xs      -> ETuple <$> goExp t x <*> mapM (goExp t) xs
  ELam ps b        -> ELam ps <$> goExp t b
  ELet ds b        -> ELet <$> mapM (goLocal t) ds <*> goExp t b
  ECase s alts     -> ECase <$> goExp t s <*> mapM (goAlt t) alts
  EIf c a b        -> EIf <$> goExp t c <*> goExp t a <*> goExp t b

  EVar{}     -> pure e
  ECon{}     -> pure e
  ELitI{}    -> pure e
  ELitS{}    -> pure e
  ELitC{}    -> pure e
  EParenOp{} -> pure e
  EUnit      -> pure e

goWithArg :: Effects -> WithArg -> M WithArg
goWithArg t (WRArg x) = WRArg <$> goExp t x

goInfixTail :: Effects -> InfixTail -> M InfixTail
goInfixTail t (ITail op x) = ITail op <$> goExp t x

goField :: Effects -> RecordFieldExpr -> M RecordFieldExpr
goField t (RFExpr n x) = RFExpr n <$> goExp t x

goTrailing :: Effects -> MaybeTrailing -> M MaybeTrailing
goTrailing _ TFNone      = pure TFNone
goTrailing t (TFSome fs) = TFSome <$> mapM (goField t) fs

goWhere :: Effects -> MaybeWhere -> M MaybeWhere
goWhere _ NoWhere     = pure NoWhere
goWhere t (WithWh ds) = WithWh <$> mapM (goLocal t) ds

goLocal :: Effects -> LocalDecl -> M LocalDecl
goLocal t d = case d of
  LDEqn lhs b w -> LDEqn lhs <$> goExp t b <*> goWhere t w
  LDPat p ps b  -> LDPat p ps <$> goExp t b
  LDSig{}       -> pure d

goAlt :: Effects -> Alt -> M Alt
goAlt t (AltC p b w) = AltC p <$> goExp t b <*> goWhere t w

goDecl :: Effects -> Decl -> M Decl
goDecl t d = case d of
  DEqn lhs b w   -> DEqn lhs <$> goExp t b <*> goWhere t w
  DClass c ps es -> DClass c ps <$> mapM (goClassEntry t) es
  DInstance h es -> DInstance h <$> mapM (goInstEntry t) es
  DLocal inner   -> DLocal <$> goDecl t inner

  DSig{}        -> pure d
  DExtern{}     -> pure d
  DData{}       -> pure d
  DExternData{} -> pure d
  DExternType{} -> pure d
  DEffect{}     -> pure d
  DFixity{}     -> pure d
  DForeign{}    -> pure d
  DModule{}     -> pure d
  DImport{}     -> pure d
  DUse{}        -> pure d
  DReserved{}   -> pure d

goClassEntry :: Effects -> ClassEntry -> M ClassEntry
goClassEntry t entry = case entry of
  CEDefault lhs b -> CEDefault lhs <$> goExp t b
  CESig{}         -> pure entry

goInstEntry :: Effects -> InstEntry -> M InstEntry
goInstEntry t (IEImpl lhs b) = IEImpl lhs <$> goExp t b

rewriteModule :: Effects -> Module -> (Module, [Edit], [Report])
rewriteModule t (Module ds) =
  let (ds', acc) = runState (mapM (goDecl t) ds) (Acc [] [])
  in (Module ds', reverse (accEdits acc), reverse (accReports acc))

conText :: ConId -> Text
conText (ConId (_, n)) = n

-- ---------------------------------------------------------------------------
-- Applying edits
-- ---------------------------------------------------------------------------

-- | Insert every edit, per line, in DESCENDING column order.
--
-- One-line handler blocks routinely carry four arms, so ascending order would
-- invalidate the recorded column of every later insertion on the same line.
applyEdits :: [Edit] -> Text -> Either Text Text
applyEdits edits src =
    T.intercalate "\n" <$> mapM step (zip [1 :: Int ..] (T.splitOn "\n" src))
  where
    byLine = Map.fromListWith (++) [ (eLine e, [e]) | e <- edits ]

    step (i, l) = case Map.lookup i byLine of
      Nothing -> Right l
      Just es -> foldM insertOne l (sortOn (Down . eCol) es)

    insertOne l e
      | eCol e < 1 || eCol e - 1 > T.length l =
          Left ("edit column " <> tshow (eCol e) <> " out of range on line "
                <> tshow (eLine e) <> " (length " <> tshow (T.length l) <> ")")
      | otherwise =
          let (a, b) = T.splitAt (eCol e - 1) l
          in Right (a <> eText e <> b)

-- ---------------------------------------------------------------------------
-- Driver
-- ---------------------------------------------------------------------------

data Outcome = Outcome
  { oPath     :: FilePath
  , oRewrite  :: Maybe Text
  , oReports  :: [Report]
  }

main :: IO ()
main = do
  args <- getArgs
  let apply     = "--apply" `elem` args
      wantAudit = "--audit" `elem` args

  files    <- wokFiles "."
  contents <- forM files $ \p -> (,) p <$> readUtf8 p

  let (skipped, live) = partitionEithers
        [ if skipMarker `T.isInfixOf` src then Left p else Right (p, src)
        | (p, src) <- contents
        ]

  parsed <- forM live $ \(p, src) -> pure (p, src, parse src)

  let ok       = [ (p, src, m) | (p, src, Right m) <- parsed ]
      failures = [ (p, err)    | (p, _, Left err)  <- parsed ]
      -- Import targets are library modules with unique names. Entry modules
      -- are all called Main and are never imported, so they are excluded
      -- rather than merged into one meaningless blob.
      modules  = Map.fromList
                   [ (n, (effectArities m, moduleImports m))
                   | (_, _, m) <- ok
                   , Just n <- [moduleName m]
                   , n /= "Main"
                   ]

  putStrLn ("scanned " <> show (length files) <> " .wok files; parsed "
            <> show (length ok) <> ", failed " <> show (length failures))
  putStrLn ("importable modules declaring effects: "
            <> show (Map.size (Map.filter (not . Map.null . efArity . fst) modules)))

  unless (null skipped) $ do
    putStrLn ("\n-- FILES OPTING OUT via `" <> T.unpack skipMarker <> "` --")
    mapM_ (putStrLn . ("  " <>)) skipped

  unless (null failures) $ do
    putStrLn "\n-- FILES THAT DID NOT PARSE (left untouched) --"
    mapM_ (\(p, err) -> putStrLn ("  " <> p <> ": " <> firstLine err)) failures

  outcomes <- forM ok $ \(p, src, m) -> do
    let (m', edits, reports) = rewriteModule (visibleArities modules m) m
        reports'             = map (\r -> r { rPath = p }) reports
    case edits of
      [] -> pure (Outcome p Nothing reports')
      _  -> case applyEdits edits src of
        Left err -> die ("EDIT FAILURE " <> p <> ": " <> T.unpack err)
        Right newSrc -> case parse newSrc of
          Left err ->
            die ("FIDELITY FAILURE " <> p
                 <> ": rewritten text does not parse: " <> firstLine err)
          Right actual
            | printTree actual /= printTree m' ->
                die ("FIDELITY FAILURE " <> p
                     <> ": rewritten AST differs from the intended promotion")
            | otherwise -> pure (Outcome p (Just newSrc) reports')

  let allReports = concatMap oReports outcomes
      touched    = [ (oPath o, s) | o <- outcomes, Just s <- [oRewrite o] ]

  summarize allReports
  when' wantAudit $ do
    putStrLn "\n-- AUDIT TRAIL (every arm in the corpus) --"
    mapM_ (putStrLn . renderReport) (sortOn rPath allReports)

  putStrLn ("\nfiles with edits: " <> show (length touched))
  putStrLn ("fidelity certificate: PASSED for all " <> show (length touched)
            <> " rewritten files")

  if apply
    then do
      mapM_ (uncurry TIO.writeFile) touched
      putStrLn "applied."
    else putStrLn "dry run; nothing written. Re-run with --apply."
  where
    when' c act = if c then act else pure ()

-- | A file carrying this marker is left entirely alone.
--
-- The mapping is a total function on arm shapes, so a fixture that DELIBERATELY
-- holds a mis-shaped arm is indistinguishable from un-migrated source. The
-- clearest case is test/typecheck-fail-examples/57-plain-arm-extra-binder.wok:
-- a plain arm binding arity + 1 patterns, which is exactly the shape the
-- mapping promotes to `once` -- so a re-run would silently repair the fixture
-- and delete the regression it exists to pin.
--
-- The marker is how such a file says so, at the file, where a reader needs it,
-- rather than the tool special-casing paths. Skips are always reported.
skipMarker :: Text
skipMarker = "codemod: skip"

die :: String -> IO a
die msg = putStrLn msg >> exitFailure

firstLine :: String -> String
firstLine = takeWhile (/= '\n')

summarize :: [Report] -> IO ()
summarize reports = do
  putStrLn "\n-- CLASSIFICATION --"
  putStrLn ("  arms seen            " <> show (length reports))
  putStrLn ("  insert `once `       " <> show (count isOnce))
  putStrLn ("  insert `return `     " <> show (count isReturn))
  putStrLn ("  plain (unchanged)    " <> show (count isPlain))
  putStrLn ("  already converted    " <> show (count isConverted))
  putStrLn ("  REFUSED (reported)   " <> show (count isRefused))
  let refusals = [ r | r <- reports, isRefused (rVerdict r) ]
  unless (null refusals) $ do
    putStrLn "\n-- REFUSED ARMS (left untouched, listed in full) --"
    mapM_ (putStrLn . ("  " <>) . renderReport) refusals
  where
    count f = length (filter (f . rVerdict) reports)

    isOnce      VOnce{}      = True
    isOnce      _            = False
    isReturn    VReturn{}    = True
    isReturn    _            = False
    isPlain     VPlain{}     = True
    isPlain     _            = False
    isConverted VConverted{} = True
    isConverted _            = False
    isRefused   VRefused{}   = True
    isRefused   _            = False

renderReport :: Report -> String
renderReport r =
  rPath r <> ":" <> show (rLine r) <> ":" <> show (rCol r)
    <> "  " <> T.unpack (T.justifyLeft 22 ' ' (rHead r))
    <> " binders=" <> show (rBinders r)
    <> "  " <> T.unpack (renderVerdict (rVerdict r))

renderVerdict :: Verdict -> Text
renderVerdict v = case v of
  VPlain en op ar -> "PLAIN     " <> en <> "." <> op <> " arity=" <> tshow ar
  VOnce en op ar  -> "ONCE      " <> en <> "." <> op <> " arity=" <> tshow ar
  VReturn n       -> "RETURN    value arm `" <> n <> "`"
  VConverted what -> "CONVERTED " <> what
  VRefused why    -> "REFUSED   " <> why

-- ---------------------------------------------------------------------------
-- Filesystem
-- ---------------------------------------------------------------------------

wokFiles :: FilePath -> IO [FilePath]
wokFiles = go
  where
    go dir = do
      entries <- listDirectory dir
      fmap concat . forM entries $ \entry -> do
        let path = dir </> entry
        isDir <- doesDirectoryExist path
        if isDir
          then if entry `elem` skipDirs then pure [] else go path
          else pure [ path | takeExtension entry == ".wok" ]
    skipDirs = [".git", "dist-newstyle", ".stack-work"]

-- | Read as UTF-8 explicitly rather than trusting the ambient locale: 42 files
-- in the corpus contain non-ASCII text.
readUtf8 :: FilePath -> IO Text
readUtf8 p = TE.decodeUtf8 <$> BS.readFile p

tshow :: Show a => a -> Text
tshow = T.pack . show
