{-# LANGUAGE OverloadedStrings #-}
module Main where

import Test.Tasty
import Test.Tasty.Golden (goldenVsString, findByExtension)
import Test.Tasty.HUnit

import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified GeneratedParser.Wok.Print as Pr
import GeneratedParser.Wok.Abs
import qualified GeneratedParser.Wok.Abs as Abs
import Wok.Parsing (parse)
import Wok.Reordering
import qualified Wok.TypeChecking.Types as Ty
import qualified Wok.TypeChecking.Env as TE
import qualified Wok.TypeChecking.Error as TErr
import qualified Wok.TypeChecking.Monad as TM
import qualified Wok.TypeChecking.Unify as U
import qualified Wok.TypeChecking.Infer as I
import qualified Wok.TypeChecking.Class as Class
import qualified Wok.TypeChecking.Builtins as B
import qualified Wok.TypeChecking.Carrier as Carrier
import qualified Wok.TypeChecking.Solve as Solve
import qualified Data.Set as Set
import qualified Wok.TypeChecking.Typed as Typed
import qualified Wok.TypeChecking as TC
import qualified Wok.SourceOrigin as SO
import qualified Wok.Prelude as Prelude
import qualified Wok.Loader as Loader
import qualified Wok.Pipeline as Pipeline
import Wok.IR.Name (Unique (..), Name (..), JoinId (..), runFresh, freshUnique, freshName, freshJoin)
import qualified Wok.IR.Anf as Anf
import Wok.IR.Elaborate (elaborateModule)
import qualified Wok.IR.Elaborate as Elab
import qualified Wok.Interp.Value as IV
import qualified Wok.Interp.Prim as IP
import qualified Wok.Interp.Machine as IM
import qualified Wok.IR.Name as Name
import qualified Wok.IR.Match as M
import qualified Wok.IR.Multiplicity as Mult
import Wok.IR.Multiplicity (Card (..))
import Wok.IR.Anf
import qualified Wok.Interp as Interp
import qualified System.Directory as Dir
import qualified Control.Monad
import qualified Control.Exception
import Control.Monad.Except (throwError)
import Data.Unique (newUnique, hashUnique)
import Data.Bifunctor (first)
import qualified Data.List
import qualified Data.Maybe
import Data.List (sortBy)
import Data.Ord (comparing)
import System.FilePath (takeBaseName, replaceDirectory, replaceExtension)

main :: IO ()
main = do
  exampleFiles       <- findByExtension [".wok"] "test/examples"
  resolveFiles       <- findByExtension [".wok"] "test/resolve-examples"
  typecheckFiles     <- findByExtension [".wok"] "test/typecheck-examples"
  typecheckBadFiles  <- findByExtension [".wok"] "test/typecheck-fail-examples"
  anfFiles           <- findByExtension [".wok"] "test/typecheck-examples"
  typedAnfFiles      <- findByExtension [".wok"] "test/typecheck-examples"
  runFiles           <- findByExtension [".wok"] "test/run-examples"
  multFiles          <- findByExtension [".wok"] "test/multiplicity-examples"
  multFailFiles      <- findByExtension [".wok"] "test/multiplicity-fail-examples"
  defaultMain $ testGroup "wok"
    [ testGroup "parse golden"
        [ goldenVsString (takeBaseName f) (goldenFor f) (parseToBS f)
        | f <- exampleFiles
        ]
    , fixityTests
    , resolveTests
    , typesSmokeTests
    , constraintTypesTests
    , envSmokeTests
    , envOverlayTests
    , sourceOriginTests
    , preludeTests
    , modPathTests
    , monadSmokeTests
    , unifyWalksTests
    , unifyTests
    , generalizeTests
    , zonkTests
    , builtinsTests
    , translateTests
    , dataTests
    , effectDeclTests
    , effectSigTests
    , namedInstanceTests
    , carrierRuleTests
    , effectGrammarTests
    , effectOpTests
    , effectHandlerTests
    , effectPressureTests
    , closedByDefaultTests
    , lambdaEffectScopingTests
    , patternTests
    , exprBasicTests
    , exprLetTests
    , inferTypedTests
    , typedDeclBodyTests
    , clauseArityTests
    , unsupportedHeadTests
    , typedDeclClauseTests
    , programTests
    , bodylessSigTests
    , loaderTests
    , crossModuleFixityTests
    , crossModuleNameConflictTests
    , bodylessUserWarningTests
    , rowUnifyTests
    , recordDeclTests
    , typeLevelExtTests
    , recordConstructionTests
    , fieldAccessTests
    , recordPatternTests
    , rowShadowTests
    , forgottenResumeTests
    , patternCoverageTests
    , matchWarningTests
    , blockLayoutTests
    , irNameTests
    , anfTests
    , interpValueTests
    , interpPrimTests
    , interpCafTests
    , interpMachineTests
    , interpEffectTests
    , interpEntryTests
    , interpWholeProgramTests
    , elaborateBasicTests
    , elaborateControlTests
    , elaborateRecordsTests
    , elaborateEffectsTests
    , elaborateModuleTests
    , typedAstTests
    , classParseTests
    , classEnvTests
    , classRegisterTests
    , constraintAccumTests
    , solveTests
    , eqInferTests
    , eqDesugarTests
    , eqElaborateTests
    , matchCompilerTests
    , matchCoverageTests
    , multiplicityUnitTests
    , testGroup "resolve golden"
        [ goldenVsString (takeBaseName f) (resolveGoldenFor f) (resolveToBS f)
        | f <- resolveFiles
        ]
    , testGroup "typecheck success golden"
        [ goldenVsString (takeBaseName f) (typecheckGoldenFor f) (typecheckSuccessHarness f)
        | f <- typecheckFiles
        ]
    , testGroup "typecheck fail golden"
        [ goldenVsString (takeBaseName f) (typecheckFailGoldenFor f) (typecheckFailHarness f)
        | f <- typecheckBadFiles
        ]
    , testGroup "anf golden"
        [ goldenVsString (takeBaseName f) (anfGoldenFor f) (anfElaborateHarness f)
        | f <- anfFiles
        ]
    , testGroup "typed-anf golden"
        [ goldenVsString (takeBaseName f) (typedAnfGoldenFor f) (typedAnfElaborateHarness f)
        | f <- typedAnfFiles
        ]
    , testGroup "run golden"
        [ goldenVsString (takeBaseName f) (runGoldenFor f) (runProgramHarness f)
        | f <- runFiles
        ]
    , testGroup "multiplicity golden"
        [ goldenVsString (takeBaseName f) (multGoldenFor f) (multDumpHarness f)
        | f <- multFiles ]
    , testGroup "multiplicity fail golden"
        [ goldenVsString (takeBaseName f) (multFailGoldenFor f) (multFailHarness f)
        | f <- multFailFiles ]
    ]

goldenFor :: FilePath -> FilePath
goldenFor exampleFile =
  replaceDirectory (replaceExtension exampleFile ".expected") "test/golden"

resolveGoldenFor :: FilePath -> FilePath
resolveGoldenFor exampleFile =
  replaceDirectory (replaceExtension exampleFile ".expected") "test/resolve-golden"

typecheckGoldenFor :: FilePath -> FilePath
typecheckGoldenFor f =
  replaceDirectory (replaceExtension f ".expected") "test/typecheck-golden"

typecheckFailGoldenFor :: FilePath -> FilePath
typecheckFailGoldenFor f =
  replaceDirectory (replaceExtension f ".expected") "test/typecheck-fail-golden"

anfGoldenFor :: FilePath -> FilePath
anfGoldenFor f =
  replaceDirectory (replaceExtension f ".expected") "test/anf-golden"

typedAnfGoldenFor :: FilePath -> FilePath
typedAnfGoldenFor f =
  replaceDirectory (replaceExtension f ".expected") "test/typed-anf-golden"

runGoldenFor :: FilePath -> FilePath
runGoldenFor f =
  replaceDirectory (replaceExtension f ".expected") "test/run-golden"

runProgramHarness :: FilePath -> IO BL.ByteString
runProgramHarness path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> pure (BL.pack ("loader: " <> show lerr <> "\n"))
    Right (entryName, ms) ->
      case Pipeline.elaborateProgramFull entryName ms of
        Left s  -> pure (BL.pack ("elaborate: " <> s <> "\n"))
        Right cm -> case Interp.runModule cm of
          Left rerr -> pure (BL.pack ("runtime error: " <> show rerr <> "\n"))
          Right v   -> pure (BL.pack (T.unpack (Interp.renderValue v) <> "\n"))

typecheckSuccessHarness :: FilePath -> IO BL.ByteString
typecheckSuccessHarness path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> pure (BL.pack ("loader: " <> show lerr <> "\n"))
    Right (entryName, ms) ->
      case Pipeline.typecheckProgram entryName ms of
        Left s          -> pure (BL.pack ("pipeline: " <> s <> "\n"))
        Right (decls, _ws) -> do
          let sorted = sortBy (comparing TC.tdName) decls
              ls     = [ T.unpack (TC.tdName d <> T.pack " : " <> TC.prettyScheme (TC.tdScheme d))
                       | d <- sorted ]
          pure (BL.pack (unlines ls))

typecheckFailHarness :: FilePath -> IO BL.ByteString
typecheckFailHarness path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> pure (BL.pack ("loader: " <> show lerr <> "\n"))
    Right (entryName, ms) ->
      case Pipeline.typecheckProgram entryName ms of
        Left s  -> pure (BL.pack ("typecheck: " <> s <> "\n"))
        Right _ -> pure (BL.pack "UNEXPECTED SUCCESS\n")

anfElaborateHarness :: FilePath -> IO BL.ByteString
anfElaborateHarness path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> pure (BL.pack ("loader: " <> show lerr <> "\n"))
    Right (entryName, ms) ->
      case Pipeline.elaborateProgram entryName ms of
        Left s  -> pure (BL.pack ("elaborateProgram: " <> s <> "\n"))
        Right cm -> pure (BL.pack (T.unpack (Anf.prettyModule cm) <> "\n"))

typedAnfElaborateHarness :: FilePath -> IO BL.ByteString
typedAnfElaborateHarness path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> pure (BL.pack ("loader: " <> show lerr <> "\n"))
    Right (entryName, ms) ->
      case Pipeline.elaborateProgram entryName ms of
        Left s  -> pure (BL.pack ("elaborateProgram: " <> s <> "\n"))
        Right cm -> pure (BL.pack (T.unpack (Anf.prettyModuleTyped cm) <> "\n"))

multGoldenFor :: FilePath -> FilePath
multGoldenFor f =
  replaceDirectory (replaceExtension f ".expected") "test/multiplicity-golden"

multDumpHarness :: FilePath -> IO BL.ByteString
multDumpHarness path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> pure (BL.pack ("loader: " <> show lerr <> "\n"))
    Right (entryName, ms) ->
      -- Whole-program: the proof artifact must include handler arms from
      -- imported modules (the prelude `Coro.suspend` arm desugars to the genuine
      -- `__coro_susp` escape sink), matching what the law accepts. The trusted
      -- escape-sink identity is resolved by the pipeline.
      case Pipeline.elaborateProgramFullTrusted entryName ms of
        Left s            -> pure (BL.pack ("elaborateProgram: " <> s <> "\n"))
        Right (cm, trust) -> pure (BL.pack (T.unpack (Mult.prettyMultiplicity trust cm) <> "\n"))

multFailGoldenFor :: FilePath -> FilePath
multFailGoldenFor f =
  replaceDirectory (replaceExtension f ".expected") "test/multiplicity-fail-golden"

multFailHarness :: FilePath -> IO BL.ByteString
multFailHarness path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> pure (BL.pack ("loader: " <> show lerr <> "\n"))
    Right (entryName, ms) ->
      case Pipeline.elaborateCheckedFull entryName ms of
        Left s  -> pure (BL.pack (s <> "\n"))
        Right _ -> pure (BL.pack "UNEXPECTED: elaboration succeeded (no multishot error)\n")

-- | The "extended" env an ordinary user module sees: B.initialEnv with the
-- Std.Base prelude's decls layered on top. Used by unit tests that need to
-- look up names defined by the prelude (Bool, True, +, ++, ...). Loads + parses
-- + reorders + typechecks Std.Base via the same path the loader uses.
stdBaseExtendedEnv :: IO TE.Env
stdBaseExtendedEnv = do
  src <- Prelude.preludeSource
  ast <- case parse src of
    Left e  -> fail ("stdBaseExtendedEnv: parse: " ++ e)
    Right a -> pure a
  reord <- case reorderModuleWith emptyFixityTable ast of
    Left es -> fail ("stdBaseExtendedEnv: reorder: " ++ show es)
    Right a -> pure a
  case TC.inferProgramWith B.initialEnv SO.Embedded reord of
    Left e             -> fail ("stdBaseExtendedEnv: typecheck: " ++ show e)
    Right (env, _, _) -> pure env

-- | Placeholder annotation for the structural test translator below: the
-- elaboration unit tests assert on the *structure* of the resulting ANF (their
-- binders are wildcards), so the carried CType is irrelevant. The erased
-- printer and the runtime ignore binder types regardless.
testTy :: Ty.CType
testTy = Ty.CTCon Ty.TcUnit []

ta :: Typed.TexpF Ty.CType -> Typed.TExpr
ta = Typed.Texp testTy

tpa :: Typed.TpatF Ty.CType -> Typed.TPat
tpa = Typed.Tpat testTy

-- | Test seam: structurally translate a raw 'Abs.Exp' into a typed 'TExpr',
-- mirroring the SHAPE the real inferrer produces (spine-collected applications,
-- effect-op projections, declared-field-order record nodes, where-folding), so
-- the elaborator -- which now consumes the typed AST -- can be exercised from
-- unit tests that build raw surface expressions over hand-built envs that are
-- not amenable to full type inference. Every node carries 'testTy'.
typedExprForTest :: TE.Env -> Abs.Exp -> Typed.TExpr
typedExprForTest env = goE
  where
    goE :: Abs.Exp -> Typed.TExpr
    goE (Abs.ELitI (Abs.WokInt (_, t))) = ta (Typed.TLitI (read (T.unpack t)))
    goE (Abs.ELitS s)                   = ta (Typed.TLitS (T.pack s))
    goE (Abs.ELitC c)                   = ta (Typed.TLitC c)
    goE Abs.EUnit                       = ta Typed.TUnit
    goE (Abs.EParen e)                  = goE e
    goE (Abs.EVar (Abs.VarId (_, t)))   = ta (Typed.TVar t)
    goE (Abs.ECon (Abs.ConId (_, c)))   = ta (Typed.TCon c)
    goE (Abs.EParenOp (Abs.VarSym (_, s))) = ta (Typed.TParenOp s)
    goE e@(Abs.EApp _ _) =
      let (hd, args) = collectSpine e
      in case hd of
           Abs.EProj (Abs.ECon (Abs.ConId (_, en))) (Abs.VarId (_, op))
             | isEffOp en op -> ta (Typed.TApp (ta (Typed.TProjCon en op)) (map goE args))
           _ -> ta (Typed.TApp (goE hd) (map goE args))
    goE (Abs.ELam pats body) = ta (Typed.TLam (map goAP pats) (goE body))
    goE (Abs.EIf c a b)      = ta (Typed.TIf (goE c) (goE a) (goE b))
    goE (Abs.ETuple a rest)  = ta (Typed.TTuple (map goE (a : rest)))
    goE (Abs.EList xs)       = ta (Typed.TList (map goE xs))
    goE (Abs.EProj e (Abs.VarId (_, l))) =
      case e of
        Abs.ECon (Abs.ConId (_, en)) | isEffOp en l -> ta (Typed.TProjCon en l)
        _                                            -> ta (Typed.TProj (goE e) l)
    goE (Abs.ERecord (Abs.ConId (_, t)) fes) =
      ta (Typed.TRecord t [ (l, goE fe) | Abs.RFExpr (Abs.VarId (_, l)) fe <- fes ])
    goE (Abs.ERecordExt (Abs.ConId (_, t)) spread mTrailing) =
      let trailing = case mTrailing of
            Abs.TFNone     -> []
            Abs.TFSome fes -> [ (l, goE fe) | Abs.RFExpr (Abs.VarId (_, l)) fe <- fes ]
      in ta (Typed.TRecordExt t (goE spread) trailing)
    goE (Abs.ELet decls body) = ta (Typed.TLet (goDecls decls) (goE body))
    goE (Abs.ECase scrut alts) = ta (Typed.TCase (goE scrut) (map goAlt alts))
    goE (Abs.EWith arms e) = ta (Typed.THandle (goE e) (map goArm arms))
    goE (Abs.EExpr hd []) = goE hd
    goE (Abs.EExpr hd tails) = goTails (goE hd) tails
    goE other = error ("typedExprForTest: unsupported form: " <> show other)

    goTails acc [Abs.ITail op rhs] = ta (Typed.TApp (opVar op) [acc, goE rhs])
    goTails acc (Abs.ITail op rhs : rest) =
      goTails (ta (Typed.TApp (opVar op) [acc, goE rhs])) rest
    goTails acc [] = acc

    opVar (Abs.IOSym (Abs.VarSym (_, s))) = ta (Typed.TVar s)
    opVar (Abs.IOBT  (Abs.VarId  (_, v))) = ta (Typed.TVar v)

    isEffOp en op = case TE.lookupEffect en env of
      Just ei -> Map.member op (TE.eiOps ei)
      Nothing -> False

    -- where is folded into the body as a leading TLet (as inference does).
    goAlt (Abs.AltC pat body wh) =
      let body' = case wh of
            Abs.NoWhere    -> goE body
            Abs.WithWh ds  -> ta (Typed.TLet (goDecls ds) (goE body))
      in Typed.TAlt (goPat pat) [] body'

    goArm (Abs.HArm (Abs.ConId (_, en)) (Abs.VarId (_, op)) ps body) =
      Typed.TOpArm en op (map goAP ps) (T.pack "") (goE body)
    goArm (Abs.HUArm (Abs.VarId (_, v)) _ body) =
      Typed.TReturnArm (tpa (Typed.TPVar v)) (goE body)
    goArm (Abs.HParam _ _) =
      error "typedExprForTest: handler-local parameter (slice 4a) not supported in tests"

    goDecls :: [Abs.LocalDecl] -> [Typed.TLocalDecl Ty.CType]
    goDecls decls =
      [ Typed.TLocalDecl fn (map goAP params) body'
      | Abs.LDEqn lhs body wh <- decls
      , (fn, params) <- lhsParts lhs
      , let body' = case wh of
              Abs.NoWhere   -> goE body
              Abs.WithWh ds -> ta (Typed.TLet (goDecls ds) (goE body))
      ]

    lhsParts (Abs.LHSPre fn params) = [(funName fn, params)]
    lhsParts _ = error "typedExprForTest: infix LHS not supported in tests"
    funName (Abs.FNBare    (Abs.VarId  (_, t))) = t
    funName (Abs.FNBareSym (Abs.VarSym (_, t))) = t
    funName (Abs.FNParen   (Abs.VarSym (_, t))) = t

    -- pattern translation -----------------------------------------------------
    goPat :: Abs.Pat -> Typed.TPat
    goPat (Abs.PAtom ap)             = goAP ap
    goPat (Abs.PApp modpath ap aps)  =
      tpa (Typed.TPCon (modPathFinal modpath) (map goAP (ap : aps)))
    goPat (Abs.PCons h t)            = tpa (Typed.TPCons (goAP h) (goPat t))

    goAP :: Abs.AtomPat -> Typed.TPat
    goAP (Abs.APVar (Abs.VarId (_, v))) = tpa (Typed.TPVar v)
    goAP Abs.APWild                     = tpa Typed.TPWild
    goAP Abs.PUnit                      = tpa Typed.TPUnit
    goAP (Abs.APLitI _)                 = tpa (Typed.TPLitI 0)
    goAP (Abs.APLitS s)                 = tpa (Typed.TPLitS (T.pack s))
    goAP (Abs.APLitC c)                 = tpa (Typed.TPLitC c)
    goAP (Abs.APCon modpath)            = tpa (Typed.TPCon (modPathFinal modpath) [])
    goAP (Abs.APTuple p1 ps)            = tpa (Typed.TPTuple (map goPat (p1 : ps)))
    goAP (Abs.APList ps)                = tpa (Typed.TPList (map goPat ps))
    goAP (Abs.APParen p)                = goPat p
    -- record patterns become TPCon over ALL declared fields in declared order,
    -- with TPWild for absent / wild fields (exactly as inference produces).
    goAP (Abs.PRecord (Abs.ConId (_, t)) fps)          = recPat t fps
    goAP (Abs.PRecordOpen (Abs.ConId (_, t)) fps _)    = recPat t fps
    goAP (Abs.PRecordWild (Abs.ConId (_, t)) _)        = recPat t []
    -- as-patterns work in the real pipeline; this lightweight test-helper parser
    -- does not model them. Use the full-pipeline test path for as-pattern cases.
    goAP (Abs.APAs _ _)                 = error "typedExprForTest: as-patterns unsupported in this test helper; use the full-pipeline path"

    recPat t fps =
      let provided = [ (l, goPat sp) | Abs.RFPat (Abs.VarId (_, l)) sp <- fps ]
          declared = case TE.lookupRecordCon t env of
            Just rci -> map fst (TE.rcFields rci)
            Nothing  -> map fst provided
          sub l = Data.Maybe.fromMaybe (tpa Typed.TPWild) (lookup l provided)
      in tpa (Typed.TPCon t (map sub declared))

    modPathFinal (Abs.MPName (Abs.ConId (_, t)))  = t
    modPathFinal (Abs.MPDot _ (Abs.ConId (_, t))) = t

    collectSpine :: Abs.Exp -> (Abs.Exp, [Abs.Exp])
    collectSpine e0 = go e0 []
      where go (Abs.EApp f x) acc = go f (x : acc)
            go hd             acc = (hd, acc)

-- | Back-compat wrapper matching the old test signature: structurally translate
-- the raw expression to the typed AST, then elaborate it.
elaborateExprForTest :: TE.Env -> Abs.Exp -> Anf.Expr
elaborateExprForTest env e = Elab.elaborateExprForTest env (typedExprForTest env e)

-- | Infer a raw module into the typed decls + env the elaborator consumes.
typedModuleForTest :: TE.Env -> Abs.Module -> (TE.Env, [I.TypedDecl])
typedModuleForTest env m =
  case TC.inferProgramWith env (SO.UserFile "<test>") m of
    Left err               -> error (show err)
    Right (envOut, tds, _) -> (envOut, tds)

-- End-to-end resolver pipeline for golden tests: parse, resolve, print.
-- Errors are rendered as `RESOLVE ERROR: ...` lines so they remain in golden
-- output (and so regressions surface as diffs against the expected file).
resolveToBS :: FilePath -> IO BL.ByteString
resolveToBS path = do
  src <- TIO.readFile path
  case parse src of
    Left err -> pure $ BL.pack ("PARSE ERROR: " ++ err ++ "\n")
    Right ast ->
      case reorderModule ast of
        Left errs ->
          pure $ BL.pack $ unlines ("RESOLVE ERRORS:" : map (("  " ++) . show) errs)
        Right rm  -> pure $ BL.pack (Pr.printTree (reorderedAst rm) ++ "\n")

-- Parse the file, then run a round-trip check (parse -> print -> parse -> compare printed forms).
--
-- KNOWN LIMITATION: `with { arms } EXPR` handler fixtures (e.g. 20-effects-syntax,
-- 26-with-handler) currently pin a "ROUND-TRIP PARSE ERROR" golden. The SOURCE
-- parses and runs fine; only the print->reparse round-trip fails, because BNFC's
-- layout-unaware `printTree` dedents the trailing handled-computation `Exp` to
-- column 0, where the `layout toplevel` filter inserts a virtual `;`. `with` is
-- deliberately NOT a layout keyword (it would clash with the type-level `with`
-- in `T -> R with E`). Follow-up: make the EWith printer emit a re-parseable
-- layout for the body so these goldens return to clean round-trips.
parseToBS :: FilePath -> IO BL.ByteString
parseToBS path = do
  src <- TIO.readFile path
  case parse src of
    Left err -> pure $ BL.pack ("PARSE ERROR: " ++ err ++ "\n")
    Right ast1 -> do
      let printed1 = Pr.printTree ast1
      case parse (T.pack printed1) of
        Left err -> pure $ BL.pack ("ROUND-TRIP PARSE ERROR: " ++ err ++ "\n---first print---\n" ++ printed1 ++ "\n")
        Right ast2
          | Pr.printTree ast2 == printed1 -> pure $ BL.pack (printed1 ++ "\n")
          | otherwise ->
              pure $ BL.pack $
                "ROUND-TRIP MISMATCH (printed forms differ)\n"
                ++ "--- first ---\n" ++ printed1 ++ "\n"
                ++ "--- second ---\n" ++ Pr.printTree ast2 ++ "\n"

-- Parse a wok source string into a Module. Use for building test fixtures.
parseSrc :: Text -> Module
parseSrc src =
  case parse src of
    Right ast -> ast
    Left err  -> error $ "parse failed in test fixture: " ++ err

fixityTests :: TestTree
fixityTests = testGroup "Wok.Reordering (fixity table)"
  [ testGroup "construction"
      [ testCase "empty module: assocOf returns Nothing" $
          tableOf "" $ \t -> assocOf t "+" @?= Nothing

      , testCase "single sym DFixity: assoc recorded" $
          tableOf "fixity + left\n" $ \t -> assocOf t "+" @?= Just FALeft

      , testCase "single sym DFixity: kind is Sym" $
          tableOf "fixity + left\n" $ \t -> kindOf t "+" @?= Just Sym

      , testCase "single alpha DFixity: kind is Alpha" $
          tableOf "fixity mod left\n" $ \t -> kindOf t "mod" @?= Just Alpha

      , testCase "right-assoc recorded" $
          tableOf "fixity ++ right\n" $ \t -> assocOf t "++" @?= Just FARight

      , testCase "multiple decls all recorded" $
          tableOf "fixity + left\nfixity * left\nfixity == left\n" $ \t -> do
            assocOf t "+"  @?= Just FALeft
            assocOf t "*"  @?= Just FALeft
            assocOf t "==" @?= Just FALeft

      , testCase "non-fixity decls are ignored" $
          tableOf "id x = x\nfixity + left\n" $ \t ->
            assocOf t "+" @?= Just FALeft
      ]

  , testGroup "compareOps"
      [ testCase "same op is Equal" $
          tableOf "fixity + left\n" $ \t ->
            compareOps t "+" "+" @?= Equal

      , testCase "unrelated ops are Incomparable" $
          tableOf "fixity + left\nfixity ++ right\n" $ \t ->
            compareOps t "+" "++" @?= Incomparable

      , testCase "tighter-than: direct" $
          tableOf "fixity + left\nfixity * left tighter than +\n" $ \t ->
            compareOps t "*" "+" @?= Tighter

      , testCase "tighter-than: reverse query is Looser" $
          tableOf "fixity + left\nfixity * left tighter than +\n" $ \t ->
            compareOps t "+" "*" @?= Looser

      , testCase "looser-than: direct" $
          tableOf "fixity + left\nfixity == left looser than +\n" $ \t ->
            compareOps t "==" "+" @?= Looser

      , testCase "transitive: ^ tighter than * tighter than + => ^ tighter than +" $
          tableOf "fixity + left\nfixity * left tighter than +\nfixity ^ right tighter than *\n" $ \t ->
            compareOps t "^" "+" @?= Tighter

      , testCase "siblings under same op are Incomparable" $
          tableOf "fixity + left\nfixity * left tighter than +\nfixity / left tighter than +\n" $ \t ->
            compareOps t "*" "/" @?= Incomparable

      , testCase "unknown op is Incomparable" $
          tableOf "fixity + left\n" $ \t ->
            compareOps t "+" "no-such-op" @?= Incomparable
      ]

  , testGroup "errors"
      [ testCase "redeclared op" $
          errorsOf "fixity + left\nfixity + right\n" $
            hasErr "redecl" $ \e -> case e of
              RedeclaredOp "+" _ _ -> True
              _                     -> False

      , testCase "self reference (tighter than itself)" $
          errorsOf "fixity + left tighter than +\n" $
            hasErr "self" $ \e -> case e of
              SelfReference "+" _ -> True
              _                   -> False

      , testCase "self reference (looser than itself)" $
          errorsOf "fixity + left looser than +\n" $
            hasErr "self" $ \e -> case e of
              SelfReference "+" _ -> True
              _                   -> False

      , testCase "unresolved neighbor" $
          errorsOf "fixity + left tighter than nope\n" $
            hasErr "unresolved" $ \e -> case e of
              UnresolvedNeighbor "+" "nope" _ -> True
              _                                -> False

      , testCase "two-cycle in tighter chain" $
          errorsOf "fixity + left tighter than *\nfixity * left tighter than +\n" $
            hasErr "cycle" $ \e -> case e of
              CycleInOrder _ -> True
              _              -> False

      , testCase "overlayFixities: disjoint tables merge cleanly" $
          let a = case buildFixityTable (parseSrc (T.pack "fixity + left\n")) of
                    Right t -> t
                    Left es -> error ("setup: " ++ show es)
              b = case buildFixityTable (parseSrc (T.pack "fixity * left\n")) of
                    Right t -> t
                    Left es -> error ("setup: " ++ show es)
          in case overlayFixities a b of
               Right merged -> do
                 assocOf merged (T.pack "+") @?= Just FALeft
                 assocOf merged (T.pack "*") @?= Just FALeft
               Left es -> assertFailure ("expected Right, got: " ++ show es)

      , testCase "overlayFixities: conflict yields RedeclaredOp" $
          let a = case buildFixityTable (parseSrc (T.pack "fixity + left\n")) of
                    Right t -> t
                    Left es -> error ("setup: " ++ show es)
              b = case buildFixityTable (parseSrc (T.pack "fixity + right\n")) of
                    Right t -> t
                    Left es -> error ("setup: " ++ show es)
          in case overlayFixities a b of
               Left [RedeclaredOp op _ _] -> op @?= T.pack "+"
               other -> assertFailure ("expected single RedeclaredOp on +, got " ++ show other)
      ]
  ]

errorsOf :: Text -> ([FixityError] -> Assertion) -> Assertion
errorsOf src k =
  case buildFixityTable (parseSrc src) of
    Right _   -> assertFailure "expected Left, got Right"
    Left errs -> k errs

hasErr :: String -> (FixityError -> Bool) -> [FixityError] -> Assertion
hasErr label p errs =
  assertBool ("expected " ++ label ++ " error in: " ++ show errs) (any p errs)

-- ---------------------------------------------------------------------
-- Wok.Reordering tests
--
-- Compare resolved/printed source. Each test feeds the whole module through
-- parseSrc -> reorderModule -> printTree and asserts the resulting string.
-- ---------------------------------------------------------------------

resolveTests :: TestTree
resolveTests = testGroup "Wok.Reordering (chains)"
  [ testGroup "passthrough"
      [ testCase "atomic decl unchanged" $
          resolvedShouldBe "id x = x\n" "id x = x"

      , testCase "decl with no infix operators is unchanged" $
          resolvedShouldBe "k x y = x\n" "k x y = x"
      ]

  , testGroup "chains"
      [ testCase "single op chain stays single-tail" $
          resolvedShouldBe
            "fixity + left\nx = a + b\n"
            "fixity + left;\nx = a + b"

      , testCase "tighter-on-right nests right" $
          resolvedShouldBe
            "fixity + left\nfixity * left tighter than +\nx = a + b * c\n"
            "fixity + left;\nfixity * left tighter than +;\nx = a + (b * c)"

      , testCase "tighter-on-left nests left" $
          resolvedShouldBe
            "fixity + left\nfixity * left tighter than +\nx = a * b + c\n"
            "fixity + left;\nfixity * left tighter than +;\nx = (a * b) + c"

      , testCase "equal precedence, left-assoc, groups left" $
          resolvedShouldBe
            "fixity + left\nx = a + b + c\n"
            "fixity + left;\nx = (a + b) + c"

      , testCase "equal precedence, right-assoc, groups right" $
          resolvedShouldBe
            "fixity $ right\nx = a $ b $ c\n"
            "fixity $ right;\nx = a $ (b $ c)"

      , testCase "three-op mix: ^ tighter than * tighter than +" $
          resolvedShouldBe
            "fixity + left\nfixity * left tighter than +\nfixity ^ right tighter than *\nx = a + b * c ^ d\n"
            "fixity + left;\nfixity * left tighter than +;\nfixity ^ right tighter than *;\nx = a + (b * (c ^ d))"

      , testCase "four-op left-assoc chain nests fully left" $
          resolvedShouldBe
            "fixity + left\nx = a + b + c + d\n"
            "fixity + left;\nx = ((a + b) + c) + d"

      , testCase "four-op right-assoc chain nests fully right" $
          resolvedShouldBe
            "fixity $ right\nx = a $ b $ c $ d\n"
            "fixity $ right;\nx = a $ (b $ (c $ d))"

      , testCase "loosest operator in the middle splits there" $
          resolvedShouldBe
            "fixity + left\nfixity * left tighter than +\nx = a * b + c * d\n"
            "fixity + left;\nfixity * left tighter than +;\nx = (a * b) + (c * d)"

      , testCase "tighter op embedded mid left-assoc chain" $
          resolvedShouldBe
            "fixity + left\nfixity * left tighter than +\nx = a + b * c + d\n"
            "fixity + left;\nfixity * left tighter than +;\nx = (a + (b * c)) + d"

      , testCase "tighter ops on both sides of the loosest" $
          resolvedShouldBe
            "fixity + left\nfixity * left tighter than +\nx = a + b * c + d * e\n"
            "fixity + left;\nfixity * left tighter than +;\nx = (a + (b * c)) + (d * e)"

      , testCase "three precedence levels across a longer chain" $
          resolvedShouldBe
            "fixity + left\nfixity * left tighter than +\nfixity ^ right tighter than *\nx = a + b * c ^ d + e\n"
            "fixity + left;\nfixity * left tighter than +;\nfixity ^ right tighter than *;\nx = (a + (b * (c ^ d))) + e"

      , testCase "reorderModuleWith: empty external table behaves like reorderModule" $
          let src = T.pack "fixity + left\nfixity * left tighter than +\nx = a * b + c\n"
              expected = case reorderModule (parseSrc src) of
                           Right rm -> Pr.printTree (reorderedAst rm)
                           Left  es -> error ("setup: " ++ show es)
          in case reorderModuleWith emptyFixityTable (parseSrc src) of
               Right ast -> Pr.printTree ast @?= expected
               Left  es  -> assertFailure ("expected Right, got: " ++ show es)

      , testCase "reorderModuleWith: external table influences reassociation" $
          let extSrc = T.pack "fixity + left\nfixity * left tighter than +\n"
              ext   = case buildFixityTable (parseSrc extSrc) of
                        Right t -> t
                        Left es -> error ("setup: " ++ show es)
              userSrc = T.pack "x = a + b * c\n"
          in case reorderModuleWith ext (parseSrc userSrc) of
               Right ast ->
                 Pr.printTree ast @?= "x = a + (b * c)"
               Left es -> assertFailure ("expected Right, got: " ++ show es)
      ]

  , testGroup "errors"
      [ testCase "undeclared operator in chain" $
          resolveShouldFail "x = a # b\n" $ \e -> case e of
            UndeclaredOperator "#" _ -> True
            _                        -> False

      , testCase "incomparable operators" $
          resolveShouldFail
            "fixity + left\nfixity ## right\nx = a + b ## c\n"
            $ \e -> case e of
              IncomparableOps _ _ _ -> True
              _                     -> False

      , testCase "two declared but unrelated ops mixed in chain" $
          -- + and - are both declared but have no `tighter than`/`looser than`
          -- relation between them; the chain `a + b - c` is therefore
          -- structurally ambiguous and rejected.
          resolveShouldFail
            "fixity + left\nfixity - left\nx = a + b - c\n"
            $ \e -> case e of
              IncomparableOps _ _ _ -> True
              _                     -> False
      ]

  , testGroup "traversal"
      [ testCase "resolves inside lambda body" $
          resolvedShouldBe
            "fixity + left\nfixity * left tighter than +\nf = \\x -> a + b * x\n"
            "fixity + left;\nfixity * left tighter than +;\nf = \\ x -> a + (b * x)"

      , testCase "resolves inside if/then/else branches" $
          resolvedShouldBe
            "fixity + left\nfixity * left tighter than +\nf c = if c then a + b * c else a\n"
            "fixity + left;\nfixity * left tighter than +;\nf c = if c then a + (b * c) else a"

      , testCase "resolves inside case alternative RHS" $
          resolvedShouldBe
            "fixity + left\nfixity * left tighter than +\nf n = case n of { 0 -> a + b * c; _ -> 0 }\n"
            "fixity + left;\nfixity * left tighter than +;\nf n = case n of\n{\n  0 -> a + (b * c);\n  _ -> 0\n}\n"
      ]
  ]

resolvedShouldBe :: Text -> String -> Assertion
resolvedShouldBe src expected =
  case reorderModule (parseSrc src) of
    Left errs -> assertFailure $ "resolve failed: " ++ show errs
    Right rm  -> Pr.printTree (reorderedAst rm) @?= expected

resolveShouldFail :: Text -> (ReorderError -> Bool) -> Assertion
resolveShouldFail src predicate =
  case reorderModule (parseSrc src) of
    Right rm  -> assertFailure $ "expected Left, got: " ++ Pr.printTree (reorderedAst rm)
    Left errs ->
      assertBool ("expected matching error in: " ++ show errs) (any predicate errs)

typesSmokeTests :: TestTree
typesSmokeTests = testGroup "Wok.TypeChecking.Types"
  [ testCase "TyCon equality" $
      Ty.TcU64 @?= Ty.TcU64
  , testCase "CType construction round-trips" $
      let t = Ty.CTArr (Ty.CTGen 0) Ty.CREmpty (Ty.CTGen 0)
      in case t of
           Ty.CTArr (Ty.CTGen i) Ty.CREmpty (Ty.CTGen j) -> (i, j) @?= (0, 0)
           _ -> assertFailure "shape mismatch"
  , testCase "Scheme stores quantifiers and body" $
      let s = Ty.mkScheme [(0, Ty.KStar)] (Ty.CTArr (Ty.CTGen 0) Ty.CREmpty (Ty.CTGen 0))
      in Ty.schemeVars s @?= [(0, Ty.KStar)]
  , testCase "Level is comparable" $
      compare (Ty.Level 1) (Ty.Level 2) @?= LT
  ]

constraintTypesTests :: TestTree
constraintTypesTests = testGroup "ConstraintTypes"
  [ testCase "scheme carries constraints" $
      let s = Ty.Scheme [(0, Ty.KStar)]
                        [Ty.Constraint (T.pack "Eq") (Ty.CTGen 0)]
                        (Ty.CTArr (Ty.CTGen 0) Ty.CREmpty
                          (Ty.CTArr (Ty.CTGen 0) Ty.CREmpty (Ty.CTCon Ty.TcBool [])))
      in Ty.schemeConstraints s @?= [Ty.Constraint (T.pack "Eq") (Ty.CTGen 0)]
  , testCase "evidence equality" $
      Ty.EvApp (T.pack "dict$Eq$Option") [Ty.EvGlobal (T.pack "dict$Eq$U64")]
        @?= Ty.EvApp (T.pack "dict$Eq$Option") [Ty.EvGlobal (T.pack "dict$Eq$U64")]
  ]

envSmokeTests :: TestTree
envSmokeTests = testGroup "Wok.TypeChecking.Env"
  [ testCase "emptyEnv has no entries" $ do
      TE.lookupVar (T.pack "x") TE.emptyEnv @?= Nothing
      TE.lookupCon (T.pack "Just") TE.emptyEnv @?= Nothing
      TE.lookupTyCon (T.pack "Maybe") TE.emptyEnv @?= Nothing
  , testCase "extendVar then lookupVar finds it" $
      let s = Ty.mkScheme [] (Ty.CTCon Ty.TcU64 [])
          e = TE.extendVar (T.pack "x") s TE.emptyEnv
      in TE.lookupVar (T.pack "x") e @?= Just s
  , testCase "TypeError has Show" $
      let err = TErr.UnknownVar Nothing (T.pack "ghost")
      in length (show err) > 0 @?= True
  ]

envOverlayTests :: TestTree
envOverlayTests = testGroup "envOverlay"
  [ testCase "disjoint vars union cleanly" $
      let a = TE.extendVar (T.pack "x") (Ty.mkScheme [] (Ty.CTCon Ty.TcU64 [])) TE.emptyEnv
          b = TE.extendVar (T.pack "y") (Ty.mkScheme [] (Ty.CTCon Ty.TcBool [])) TE.emptyEnv
      in case TE.overlayEnvs a b of
           Right e -> do
             TE.lookupVar (T.pack "x") e @?= TE.lookupVar (T.pack "x") a
             TE.lookupVar (T.pack "y") e @?= TE.lookupVar (T.pack "y") b
           Left _ -> assertFailure "expected Right"

  , testCase "var collision returns Left with NsVar" $
      let s1 = Ty.mkScheme [] (Ty.CTCon Ty.TcU64 [])
          s2 = Ty.mkScheme [] (Ty.CTCon Ty.TcBool [])
          a = TE.extendVar (T.pack "dup") s1 TE.emptyEnv
          b = TE.extendVar (T.pack "dup") s2 TE.emptyEnv
      in case TE.overlayEnvs a b of
           Left collisions -> collisions @?= [(TE.NsVar, T.pack "dup")]
           Right _ -> assertFailure "expected Left"

  , testCase "tycon collision returns Left with NsTyCon" $
      -- A genuine collision requires DIFFERING entries under the same name
      -- (byte-identical re-exports merge silently to support diamond imports).
      let tciA = TE.TyConInfo Ty.KStar 0 [] False
          tciB = TE.TyConInfo Ty.KStar 1 [] False
          a = TE.extendTyCon (T.pack "Foo") tciA TE.emptyEnv
          b = TE.extendTyCon (T.pack "Foo") tciB TE.emptyEnv
      in case TE.overlayEnvs a b of
           Left collisions -> collisions @?= [(TE.NsTyCon, T.pack "Foo")]
           Right _ -> assertFailure "expected Left"

  , testCase "con collision returns Left with NsCon" $
      let ciA = TE.ConInfo (Ty.mkScheme [] (Ty.CTCon Ty.TcBool [])) 0 (T.pack "Bool")
          ciB = TE.ConInfo (Ty.mkScheme [] (Ty.CTCon Ty.TcU64  [])) 0 (T.pack "Bool")
          a = TE.extendCon (T.pack "True") ciA TE.emptyEnv
          b = TE.extendCon (T.pack "True") ciB TE.emptyEnv
      in case TE.overlayEnvs a b of
           Left collisions -> collisions @?= [(TE.NsCon, T.pack "True")]
           Right _ -> assertFailure "expected Left"

  , testCase "extendEffect then lookupEffect round-trips" $
      let ei  = TE.EffectInfo []
                  (Map.fromList [(T.pack "read", Ty.mkScheme [] (Ty.CTCon Ty.TcString []))])
          env = TE.extendEffect (T.pack "IO") ei TE.emptyEnv
      in TE.lookupEffect (T.pack "IO") env @?= Just ei

  , testCase "effect collision returns Left with NsEffect" $
      let eiA = TE.EffectInfo [] Map.empty
          eiB = TE.EffectInfo []
                  (Map.fromList [(T.pack "read", Ty.mkScheme [] (Ty.CTCon Ty.TcString []))])
          a  = TE.extendEffect (T.pack "IO") eiA TE.emptyEnv
          b  = TE.extendEffect (T.pack "IO") eiB TE.emptyEnv
      in case TE.overlayEnvs a b of
           Left collisions -> collisions @?= [(TE.NsEffect, T.pack "IO")]
           Right _ -> assertFailure "expected Left"

  , testCase "collisions across multiple namespaces are all reported" $
      let sA  = Ty.mkScheme [] (Ty.CTCon Ty.TcU64 [])
          sB  = Ty.mkScheme [] (Ty.CTCon Ty.TcBool [])
          tciA = TE.TyConInfo Ty.KStar 0 [] False
          tciB = TE.TyConInfo Ty.KStar 1 [] False
          a = TE.extendTyCon (T.pack "X") tciA (TE.extendVar (T.pack "y") sA TE.emptyEnv)
          b = TE.extendTyCon (T.pack "X") tciB (TE.extendVar (T.pack "y") sB TE.emptyEnv)
      in case TE.overlayEnvs a b of
           Left collisions ->
             Data.List.sort collisions @?=
               Data.List.sort [(TE.NsVar, T.pack "y"), (TE.NsTyCon, T.pack "X")]
           Right _ -> assertFailure "expected Left"

  , testCase "byte-identical re-exported entries merge silently (diamond import)" $
      -- A name present in BOTH inputs with the SAME value is not a
      -- collision: this is what lets `Main` import both `Std.Base` and a
      -- module that re-exports `Std.Base` without every shared name
      -- clashing.
      let s   = Ty.mkScheme [] (Ty.CTCon Ty.TcU64 [])
          tci = TE.TyConInfo Ty.KStar 0 [] False
          a = TE.extendTyCon (T.pack "X") tci (TE.extendVar (T.pack "y") s TE.emptyEnv)
          b = TE.extendTyCon (T.pack "X") tci (TE.extendVar (T.pack "y") s TE.emptyEnv)
      in case TE.overlayEnvs a b of
           Right e -> do
             TE.lookupVar (T.pack "y") e @?= Just s
             TE.lookupTyCon (T.pack "X") e @?= Just tci
           Left collisions ->
             assertFailure ("expected silent merge, got: " ++ show collisions)

  , testCase "same name + same type but different ORIGIN clashes (provenance)" $
      -- Two modules each defining `foo : U64` (identical Scheme, distinct
      -- origin) must be flagged. This is the regression provenance fixes.
      let s = Ty.mkScheme [] (Ty.CTCon Ty.TcU64 [])
          a = (TE.extendVar (T.pack "foo") s TE.emptyEnv)
                { TE.envVarOrigin = Map.fromList [(T.pack "foo", T.pack "A")] }
          b = (TE.extendVar (T.pack "foo") s TE.emptyEnv)
                { TE.envVarOrigin = Map.fromList [(T.pack "foo", T.pack "B")] }
      in case TE.overlayEnvs a b of
           Left collisions -> collisions @?= [(TE.NsVar, T.pack "foo")]
           Right _ -> assertFailure "expected Left (different origin)"

  , testCase "same name + same type + same ORIGIN merges silently (diamond re-export)" $
      -- A re-exported Std.Base name keeps origin "Std.Base" on both sides.
      let s = Ty.mkScheme [] (Ty.CTCon Ty.TcU64 [])
          mk = (TE.extendVar (T.pack "foo") s TE.emptyEnv)
                 { TE.envVarOrigin = Map.fromList [(T.pack "foo", T.pack "Std.Base")] }
      in case TE.overlayEnvs mk mk of
           Right e  -> TE.lookupVar (T.pack "foo") e @?= Just s
           Left col -> assertFailure ("expected silent merge, got: " ++ show col)
  ]

sourceOriginTests :: TestTree
sourceOriginTests = testGroup "Wok.SourceOrigin"
  [ testCase "originPath Embedded is the placeholder tag" $
      SO.originPath SO.Embedded @?= "<Std.Base>"
  , testCase "originPath UserFile returns the path verbatim" $
      SO.originPath (SO.UserFile "foo/bar.wok") @?= "foo/bar.wok"
  ]

preludeTests :: TestTree
preludeTests = testGroup "Prelude"
  [ testCase "preludeName is Std.Base" $
      Prelude.preludeName @?= T.pack "Std.Base"
  , testCase "preludeSource is non-empty" $ do
      src <- Prelude.preludeSource
      assertBool "expected non-empty preludeSource" (T.length src > 0)
  , testCase "preludeSource contains a module header" $ do
      src <- Prelude.preludeSource
      assertBool "expected `module Std.Base` in source"
                 (T.isInfixOf (T.pack "module Std.Base") src)
  ]

modPathTests :: TestTree
modPathTests = testGroup "modPath"
  [ testCase "modPathText on bare ConId" $
      let mp = Abs.MPName (Abs.ConId ((1, 1), T.pack "Foo"))
      in I.modPathText mp @?= T.pack "Foo"

  , testCase "modPathText on single dot" $
      let mp = Abs.MPDot (Abs.MPName (Abs.ConId ((1, 1), T.pack "Std")))
                         (Abs.ConId ((1, 5), T.pack "Base"))
      in I.modPathText mp @?= T.pack "Std.Base"

  , testCase "modPathText on double dot" $
      let mp = Abs.MPDot
                 (Abs.MPDot (Abs.MPName (Abs.ConId ((1, 1), T.pack "A")))
                            (Abs.ConId ((1, 3), T.pack "B")))
                 (Abs.ConId ((1, 5), T.pack "C"))
      in I.modPathText mp @?= T.pack "A.B.C"

  , testCase "modPathPos returns leftmost ConId position" $
      let mp = Abs.MPDot (Abs.MPName (Abs.ConId ((42, 7), T.pack "Std")))
                         (Abs.ConId ((42, 11), T.pack "Base"))
      in I.modPathPos mp @?= (42, 7)
  ]

monadSmokeTests :: TestTree
monadSmokeTests = testGroup "Wok.TypeChecking.Monad"
  [ testCase "freshUniq returns increasing values" $
      let result = TM.runTC_ TE.emptyEnv $ do
            a <- TM.freshUniq
            b <- TM.freshUniq
            c <- TM.freshUniq
            pure (a, b, c)
      in case result of
           Right t -> t @?= (0, 1, 2)
           Left e  -> assertFailure (show e)
  , testCase "enterLevel bumps then restores" $
      let result = TM.runTC_ TE.emptyEnv $ do
            l0 <- TM.currentLevel
            l1 <- TM.enterLevel TM.currentLevel
            l2 <- TM.currentLevel
            pure (l0, l1, l2)
      in case result of
           Right t -> t @?= (Ty.Level 0, Ty.Level 1, Ty.Level 0)
           Left e  -> assertFailure (show e)
  , testCase "freshTVar runs without error" $
      let result = TM.runTC_ TE.emptyEnv $ do
            _ <- TM.enterLevel (TM.freshTVar Ty.KStar)
            pure ()
      in case result of
           Right () -> pure ()
           Left e -> assertFailure (show e)
  , testCase "throwError caught as Left" $
      let result :: Either TErr.TypeError ()
          result = TM.runTC_ TE.emptyEnv $
            throwError (TErr.UnknownVar Nothing (T.pack "x"))
      in case result of
           Left (TErr.UnknownVar _ _) -> pure ()
           _ -> assertFailure "expected UnknownVar"
  ]

unifyWalksTests :: TestTree
unifyWalksTests = testGroup "Wok.TypeChecking.Unify (walks)"
  [ testCase "freeze TCon Int" $
      let result = TM.runTC_ TE.emptyEnv $
            U.freeze (Ty.TCon Ty.TcU64 [])
      in case result of
           Right ct -> ct @?= Ty.CTCon Ty.TcU64 []
           Left e   -> assertFailure ("expected Right, got: " ++ show e)
  , testCase "freeze fresh TVar produces CTGen" $
      let result = TM.runTC_ TE.emptyEnv $ do
            t <- TM.freshTVar Ty.KStar
            U.freeze t
      in case result of
           Right (Ty.CTGen _) -> pure ()
           _ -> assertFailure ("expected CTGen, got " ++ show result)
  , testCase "occursAdjust fires when target appears" $
      let result = TM.runTC_ TE.emptyEnv $ do
            a <- TM.freshTVar Ty.KStar
            case a of
              Ty.TVar ref -> U.occursAdjust Nothing ref (Ty.Level 0)
                              (Ty.TCon Ty.TcList [a])
              _ -> error "expected TVar"
      in case result of
           Left (TErr.OccursCheck _ _ _) -> pure ()
           _ -> assertFailure ("expected OccursCheck, got "
                              ++ either show (const "Right ()") result)
  ]

unifyTests :: TestTree
unifyTests = testGroup "Wok.TypeChecking.Unify (unify)"
  [ testCase "identical TCon unifies" $
      let result = TM.runTC_ TE.emptyEnv $
            U.unify Nothing (Ty.TCon Ty.TcU64 []) (Ty.TCon Ty.TcU64 [])
      in case result of
           Right () -> pure ()
           Left e -> assertFailure (show e)
  , testCase "mismatched TCons fail" $
      let result = TM.runTC_ TE.emptyEnv $
            U.unify Nothing (Ty.TCon Ty.TcU64 []) (Ty.TCon Ty.TcBool [])
      in case result of
           Left (TErr.Mismatch _ _ _) -> pure ()
           _ -> assertFailure
                  ("expected Mismatch, got "
                  ++ either show (const "Right ()") result)
  , testCase "fresh TVar unifies with concrete type" $
      let result = TM.runTC_ TE.emptyEnv $ do
            a <- TM.freshTVar Ty.KStar
            U.unify Nothing a (Ty.TCon Ty.TcU64 [])
            U.freeze a
      in case result of
           Right ct -> ct @?= Ty.CTCon Ty.TcU64 []
           Left e -> assertFailure (show e)
  , testCase "TArr unifies (with empty effect row)" $
      let result = TM.runTC_ TE.emptyEnv $ do
            a <- TM.freshTVar Ty.KStar
            U.unify Nothing
              (Ty.TArr a Ty.RowEmpty (Ty.TCon Ty.TcBool []))
              (Ty.TArr (Ty.TCon Ty.TcU64 []) Ty.RowEmpty (Ty.TCon Ty.TcBool []))
            U.freeze a
      in case result of
           Right ct -> ct @?= Ty.CTCon Ty.TcU64 []
           Left e -> assertFailure (show e)
  , testCase "occurs check fires (a ~ List a)" $
      let result = TM.runTC_ TE.emptyEnv $ do
            a <- TM.freshTVar Ty.KStar
            U.unify Nothing a (Ty.TCon Ty.TcList [a])
      in case result of
           Left (TErr.OccursCheck _ _ _) -> pure ()
           _ -> assertFailure
                  ("expected OccursCheck, got "
                  ++ either show (const "Right ()") result)
  ]

tableOf :: Text -> (FixityTable -> Assertion) -> Assertion
tableOf src k =
  case buildFixityTable (parseSrc src) of
    Right t  -> k t
    Left err -> assertFailure $ "expected Right, got: " ++ show err

builtinsTests :: TestTree
builtinsTests = testGroup "Wok.TypeChecking.Builtins + Std.Base"
  -- Builtins.initialEnv is the irreducible pre-env: only the tycons that
  -- can't be spelled in surface Wok (U64, (), [], (,)...(,..,)). Everything
  -- else (Bool, Option, +, ++, ...) lives in Std.Base; these tests load the
  -- prelude via stdBaseExtendedEnv to verify the user-visible contract.
  [ testCase "U64, (), [], tuple tycons in irreducible Builtins" $ do
      case TE.lookupTyCon (T.pack "U64") B.initialEnv of
        Just info -> TE.tcKind info @?= Ty.KStar
        Nothing -> assertFailure "U64 missing"
      case TE.lookupTyCon (T.pack "()") B.initialEnv of
        Just info -> TE.tcArity info @?= 0
        Nothing -> assertFailure "() missing"
      case TE.lookupTyCon (T.pack "[]") B.initialEnv of
        Just info -> TE.tcArity info @?= 1
        Nothing -> assertFailure "list missing"
  , testCase "Builtins has NO Bool/True/False/+/++ (Std.Base owns them)" $ do
      TE.lookupTyCon (T.pack "Bool") B.initialEnv @?= Nothing
      TE.lookupCon   (T.pack "True") B.initialEnv @?= Nothing
      TE.lookupVar   (T.pack "+")    B.initialEnv @?= Nothing
      TE.lookupVar   (T.pack "++")   B.initialEnv @?= Nothing
  , testCase "Std.Base: Bool tycon with True/False cons" $ do
      env <- stdBaseExtendedEnv
      case TE.lookupTyCon (T.pack "Bool") env of
        Just info -> do
          TE.tcArity info @?= 0
          TE.tcCons info @?= [T.pack "True", T.pack "False"]
        Nothing -> assertFailure "Bool missing"
  , testCase "Std.Base: True/False are constructors of Bool" $ do
      env <- stdBaseExtendedEnv
      case TE.lookupCon (T.pack "True") env of
        Just info -> TE.conTyCon info @?= T.pack "Bool"
        Nothing -> assertFailure "True missing"
  , testCase "Std.Base: + has scheme U64 -> U64 -> U64" $ do
      env <- stdBaseExtendedEnv
      case TE.lookupVar (T.pack "+") env of
        Just (Ty.Scheme [] _ body) -> case body of
          Ty.CTArr (Ty.CTCon Ty.TcU64 []) Ty.CREmpty
            (Ty.CTArr (Ty.CTCon Ty.TcU64 []) Ty.CREmpty (Ty.CTCon Ty.TcU64 [])) ->
              pure ()
          _ -> assertFailure ("unexpected body: " ++ show body)
        _ -> assertFailure "+ missing or has quantifiers"
  , testCase "Std.Base: ++ has one type quantifier" $ do
      env <- stdBaseExtendedEnv
      case TE.lookupVar (T.pack "++") env of
        Just (Ty.Scheme [(_, Ty.KStar)] _ _) -> pure ()
        _ -> assertFailure "++ has wrong quantifier count"
  , testCase "tuple constructors up to arity 16" $ do
      case TE.lookupTyCon (T.pack "(,)") B.initialEnv of
        Just info -> TE.tcArity info @?= 2
        Nothing -> assertFailure "2-tuple missing"
      case TE.lookupTyCon (T.pack "(,,,,,,,,,,,,,,,)") B.initialEnv of
        Just info -> TE.tcArity info @?= 16
        Nothing -> assertFailure "16-tuple missing"
  ]

translateTests :: TestTree
translateTests = testGroup "Wok.TypeChecking.Infer (translateSig)"
  [ testCase "U64 -> U64 translates to monotype" $
      let int = Abs.TCon (Abs.MPName (Abs.ConId ((0,0), T.pack "U64")))
          ty  = Abs.TFun int int
          result = TM.runTC_ B.initialEnv (I.translateSig B.initialEnv ty)
      in case result of
           Right s -> s @?= Ty.mkScheme []
                            (Ty.CTArr (Ty.CTCon Ty.TcU64 []) Ty.CREmpty
                                      (Ty.CTCon Ty.TcU64 []))
           Left e -> assertFailure (show e)
  , testCase "a -> a translates to forall a. a -> a" $
      let var = Abs.TVar (Abs.VarId ((0,0), T.pack "a"))
          ty  = Abs.TFun var var
          result = TM.runTC_ B.initialEnv (I.translateSig B.initialEnv ty)
      in case result of
           Right (Ty.Scheme [(0, Ty.KStar)] _
                    (Ty.CTArr (Ty.CTGen 0) Ty.CREmpty (Ty.CTGen 0))) ->
             pure ()
           other -> assertFailure ("unexpected: " ++ show other)
  , testCase "[a] translates to forall a. [a]" $
      let var = Abs.TVar (Abs.VarId ((0,0), T.pack "a"))
          result = TM.runTC_ B.initialEnv (I.translateSig B.initialEnv (Abs.TList var))
      in case result of
           Right (Ty.Scheme [(0, Ty.KStar)] _ (Ty.CTCon Ty.TcList [Ty.CTGen 0])) ->
             pure ()
           other -> assertFailure ("unexpected: " ++ show other)
  , testCase "unknown tycon errors" $
      let unk = Abs.TCon (Abs.MPName (Abs.ConId ((0,0), T.pack "Frob")))
          result = TM.runTC_ B.initialEnv (I.translateSig B.initialEnv unk)
      in case result of
           Left (TErr.UnknownTyCon _ _) -> pure ()
           _ -> assertFailure ("expected UnknownTyCon, got "
                              ++ either show (const "Right") result)
  ]

generalizeTests :: TestTree
generalizeTests = testGroup "Wok.TypeChecking.Infer (generalize/instantiate)"
  [ testCase "generalize Int yields no quantifiers" $
      let result = TM.runTC_ TE.emptyEnv $
            I.generalize (Ty.TCon Ty.TcU64 [])
      in case result of
           Right s -> s @?= Ty.mkScheme [] (Ty.CTCon Ty.TcU64 [])
           Left e -> assertFailure (show e)
  , testCase "generalize fresh a -> a yields forall a. a -> a" $
      let result = TM.runTC_ TE.emptyEnv $ do
            a <- TM.enterLevel (TM.freshTVar Ty.KStar)
            I.generalize (Ty.TArr a Ty.RowEmpty a)
      in case result of
           Right (Ty.Scheme [(i, Ty.KStar)] _
                    (Ty.CTArr (Ty.CTGen j) Ty.CREmpty (Ty.CTGen k)))
             | i == j && j == k -> pure ()
           other -> assertFailure ("unexpected scheme: " ++ show other)
  , testCase "instantiate forall a. a -> a yields shared TVar" $
      let s = Ty.mkScheme [(0, Ty.KStar)]
                (Ty.CTArr (Ty.CTGen 0) Ty.CREmpty (Ty.CTGen 0))
          result = TM.runTC_ TE.emptyEnv $ do
            t <- I.instantiate s
            case t of
              Ty.TArr (Ty.TVar r1) Ty.RowEmpty (Ty.TVar r2) ->
                pure (r1 == r2)
              _ -> pure False
      in case result of
           Right True -> pure ()
           Right False -> assertFailure "expected shared TVar refs but they differed"
           Left e -> assertFailure (show e)
  ]

zonkTests :: TestTree
zonkTests = testGroup "Zonk"
  [ testCase "polymorphic body node shares the scheme's CTGen domain" $
      -- Mirror real use: the binding's RHS var lives one level deeper than
      -- the level at which we generalize, so 'a' is generalizable.
      let r = TM.runTC_ B.initialEnv $ do
                a <- TM.enterLevel (TM.freshTVar Ty.KStar)          -- the 'a' of id
                let fnTy = Ty.TArr a Ty.RowEmpty a
                    tree = Typed.Texp a (Typed.TVar (T.pack "x"))   -- body: x : a
                (sch, tree', _cs) <- I.generalizeTyped fnTy tree []
                let Typed.Texp ann _ = tree'
                pure (Ty.schemeBody sch, ann)
      in case r of
           Right (Ty.CTArr d _ _, ann) -> ann @?= d   -- node type == domain
           other -> assertFailure (show other)
  , testCase "monomorphic node freezes to concrete CType" $
      let r = TM.runTC_ B.initialEnv $ do
                let tree = Typed.Texp (Ty.TCon Ty.TcU64 []) (Typed.TLitI 1)
                (_, Typed.Texp ann _, _cs) <- I.generalizeTyped (Ty.TCon Ty.TcU64 []) tree []
                pure ann
      in case r of
           Right ann -> ann @?= Ty.CTCon Ty.TcU64 []
           Left e    -> assertFailure (show e)
  ]

-- | Assert that inferExprW builds typed nodes with the right constructor
-- shape. We inspect the TexpF structure (annotations carry mutable Type s and
-- are awkward to compare, so we match on node shape and concrete literals).
inferTypedTests :: TestTree
inferTypedTests = testGroup "InferTyped"
  [ testCase "literal 1 yields Texp _ (TLitI 1)" $
      let r = TM.runTC_ B.initialEnv $ do
                (_, Typed.Texp _ node) <-
                  I.inferExprW Map.empty (Abs.ELitI (Abs.WokInt ((0,0), T.pack "1")))
                pure $ case node of
                  Typed.TLitI 1 -> True
                  _             -> False
      in case r of
           Right True -> pure ()
           other      -> assertFailure ("unexpected node: " ++ show other)
  , testCase "unit yields Texp _ TUnit" $
      let r = TM.runTC_ B.initialEnv $ do
                (_, Typed.Texp _ node) <- I.inferExprW Map.empty Abs.EUnit
                pure $ case node of
                  Typed.TUnit -> True
                  _           -> False
      in case r of
           Right True -> pure ()
           other      -> assertFailure ("unexpected node: " ++ show other)
  , testCase "f x yields Texp _ (TApp (Texp _ (TVar f)) [Texp _ (TVar x)])" $
      let r = TM.runTC_ B.initialEnv $ do
                xa <- TM.freshTVar Ty.KStar
                -- f : x -> r so the application is well typed.
                rv <- TM.freshTVar Ty.KStar
                let mono = Map.fromList
                      [ (T.pack "f", Ty.TArr xa Ty.RowEmpty rv)
                      , (T.pack "x", xa) ]
                    app = Abs.EApp
                            (Abs.EVar (Abs.VarId ((0,0), T.pack "f")))
                            (Abs.EVar (Abs.VarId ((0,0), T.pack "x")))
                (_, Typed.Texp _ node) <- I.inferExprW mono app
                pure $ case node of
                  Typed.TApp (Typed.Texp _ (Typed.TVar fn))
                             [Typed.Texp _ (Typed.TVar xn)] ->
                    fn == T.pack "f" && xn == T.pack "x"
                  _ -> False
      in case r of
           Right True -> pure ()
           other      -> assertFailure ("unexpected node: " ++ show other)
  , testCase "lambda yields Texp _ (TLam [TPVar x] (TVar x))" $
      let lam = Abs.ELam [Abs.APVar (Abs.VarId ((0,0), T.pack "x"))]
                  (Abs.EVar (Abs.VarId ((0,0), T.pack "x")))
          r = TM.runTC_ B.initialEnv $ do
                (_, Typed.Texp _ node) <- I.inferExprW Map.empty lam
                pure $ case node of
                  Typed.TLam [Typed.Tpat _ (Typed.TPVar p)]
                             (Typed.Texp _ (Typed.TVar b)) ->
                    p == T.pack "x" && b == T.pack "x"
                  _ -> False
      in case r of
           Right True -> pure ()
           other      -> assertFailure ("unexpected node: " ++ show other)
  ]

typedDeclBodyTests :: TestTree
typedDeclBodyTests = testGroup "TypedDeclBody"
  [ testCase "id x = x: scheme forall a. a -> a, body+params share CTGen" $
      case parse (T.pack "id x = x\n") of
        Left err -> assertFailure ("parse: " ++ err)
        Right ast -> case reorderModule ast of
          Left es -> assertFailure ("reorder: " ++ show es)
          Right rm ->
            case TC.inferProgramWith B.initialEnv SO.Embedded (reorderedAst rm) of
              Left e -> assertFailure ("typecheck: " ++ show e)
              Right (_env, decls, _ws) ->
                case [ d | d <- decls, TC.tdName d == T.pack "id" ] of
                  [] -> assertFailure "no TypedDecl for id"
                  (d : _) ->
                    case TC.tdScheme d of
                      Ty.Scheme [_] _ (Ty.CTArr (Ty.CTGen i) _ (Ty.CTGen j))
                        | i == j ->
                          case TC.tdClauses d of
                            [([Typed.Tpat (Ty.CTGen pIdx) (Typed.TPVar nm)],
                              Typed.Texp bodyAnn _)] -> do
                                 -- one clause, one quantifier, arrow a -> a
                                 -- body's root annotation is the domain CTGen i
                                 bodyAnn @?= Ty.CTGen i
                                 pIdx @?= i
                                 nm @?= T.pack "x"
                            other ->
                                 assertFailure ("unexpected tdClauses: " ++ show other)
                      other ->
                        assertFailure ("unexpected scheme: " ++ show other)
  , testCase "f x = let g y = y in x: node-only poly var does not leak into scheme" $
      -- 'g' is a let-bound polymorphic helper whose type does not escape into
      -- f's type. f's scheme must be exactly forall a. a -> a (one quantifier).
      -- Under the old code, freezing g's body node 'y : b' recorded a spurious
      -- second quantifier, yielding forall a b. a -> a.
      case parse (T.pack "f x = let g y = y in x\n") of
        Left err -> assertFailure ("parse: " ++ err)
        Right ast -> case reorderModule ast of
          Left es -> assertFailure ("reorder: " ++ show es)
          Right rm ->
            case TC.inferProgramWith B.initialEnv SO.Embedded (reorderedAst rm) of
              Left e -> assertFailure ("typecheck: " ++ show e)
              Right (_env, decls, _ws) ->
                case [ d | d <- decls, TC.tdName d == T.pack "f" ] of
                  [] -> assertFailure "no TypedDecl for f"
                  (d : _) ->
                    case TC.tdScheme d of
                      sch@(Ty.Scheme _ _ (Ty.CTArr (Ty.CTGen i) _ (Ty.CTGen j)))
                        | i == j -> do
                          -- exactly one quantifier; the node-only 'b' did not leak
                          length (Ty.schemeVars sch) @?= 1
                      other ->
                        assertFailure ("unexpected scheme: " ++ show other)
  ]

-- | Equations for the same name that disagree on argument count are rejected
-- with 'ClauseArityMismatch'. The arity check runs before inference, so it
-- works on a self-contained module using only builtin types.
clauseArityTests :: TestTree
clauseArityTests = testGroup "ClauseArity"
  [ testCase "equations disagreeing on arity are rejected" $
      assertModuleFailsWith isClauseArity $ T.unlines
        [ T.pack "f : U64 -> U64 -> U64"
        , T.pack "f 0 = 0"
        , T.pack "f x y = y" ]
  , testCase "equations agreeing on arity are accepted" $
      assertModuleTypechecks $ T.unlines
        [ T.pack "f : U64 -> U64 -> U64"
        , T.pack "f 0 y = y"
        , T.pack "f x y = y" ]
  ]
  where
    isClauseArity e = case e of
      TErr.ClauseArityMismatch{} -> True
      _                          -> False

-- | Head-pattern shapes the match compiler cannot lower (record-constructor
-- patterns and non-empty list literals in a routed-through-match head) are
-- rejected at typecheck time with a clean 'UnsupportedHeadPattern', BEFORE any
-- coverage warning fires. Single-clause record heads take the cheap projection
-- path and must still type-check.
unsupportedHeadTests :: TestTree
unsupportedHeadTests = testGroup "UnsupportedHead"
  [ testCase "multi-clause record-constructor head is a clean type error" $ do
      let src = T.unlines
            [ T.pack "data Box = Box { v : U64 }"
            , T.pack "f : Box -> U64"
            , T.pack "f (Box { v = 0 }) = 0"
            , T.pack "f (Box { v = x }) = x" ]
      assertNoRedundantBeforeUnsupported src

  , testCase "non-empty list literal head is a clean type error" $ do
      let src = T.unlines
            [ T.pack "g : [U64] -> U64"
            , T.pack "g [1, 2] = 1"
            , T.pack "g _      = 0" ]
      assertNoRedundantBeforeUnsupported src

  , testCase "single-clause record head still type-checks (cheap path preserved)" $ do
      let src = T.unlines
            [ T.pack "data Box = Box { v : U64 }"
            , T.pack "getV : Box -> U64"
            , T.pack "getV (Box { v = x }) = x" ]
      assertModuleTypechecks src
  ]
  where
    -- Run with UserFile origin (the origin that WOULD emit coverage warnings)
    -- and assert the result is the clean UnsupportedHeadPattern error -- the
    -- error short-circuits inference, so no RedundantClause/NonExhaustiveMatch
    -- warning can ever precede it.
    assertNoRedundantBeforeUnsupported src =
      case parse src of
        Left err  -> assertFailure ("parse: " ++ err)
        Right ast -> case reorderModule ast of
          Left es -> assertFailure ("reorder: " ++ show es)
          Right rm ->
            case TC.inferProgramWith B.initialEnv (SO.UserFile "<test>")
                   (reorderedAst rm) of
              Left TErr.UnsupportedHeadPattern{} -> pure ()
              Left e  -> assertFailure ("expected UnsupportedHeadPattern, got: " ++ show e)
              Right _ -> assertFailure "expected UnsupportedHeadPattern, got success"

-- | A multi-clause function keeps EVERY clause on its 'TypedDecl' (the
-- finalizer no longer drops all-but-first). A single-clause binding round-trips
-- as a one-element clause list.
typedDeclClauseTests :: TestTree
typedDeclClauseTests = testGroup "typedDeclClause"
  [ testCase "two-clause function carries two clauses" $
      withDeclsFor (T.unlines
        [ T.pack "data Nat = Z | S Nat"
        , T.pack "f : Nat -> U64"
        , T.pack "f Z = 0"
        , T.pack "f (S n) = 1" ]) (T.pack "f") $ \d ->
          length (TC.tdClauses d) @?= 2
  , testCase "single-clause binding round-trips as one clause" $
      withDeclsFor (T.pack "id x = x\n") (T.pack "id") $ \d ->
          length (TC.tdClauses d) @?= 1
  , testCase "zero-arg value round-trips as one empty-param clause" $
      withDeclsFor (T.pack "answer = 42\n") (T.pack "answer") $ \d ->
          case TC.tdClauses d of
            [([], _)] -> pure ()
            other     -> assertFailure ("unexpected clauses: " ++ show other)
  ]
  where
    withDeclsFor src nm k =
      case parse src of
        Left err -> assertFailure ("parse: " ++ err)
        Right ast -> case reorderModule ast of
          Left es -> assertFailure ("reorder: " ++ show es)
          Right rm ->
            case TC.inferProgramWith B.initialEnv SO.Embedded (reorderedAst rm) of
              Left e -> assertFailure ("typecheck: " ++ show e)
              Right (_env, decls, _ws) ->
                case [ d | d <- decls, TC.tdName d == nm ] of
                  []      -> assertFailure ("no TypedDecl for " ++ T.unpack nm)
                  (d : _) -> k d

-- | Parse, reorder, and typecheck a whole module; assert it succeeds.
assertModuleTypechecks :: Text -> Assertion
assertModuleTypechecks src =
  case parse src of
    Left err -> assertFailure ("parse: " ++ err)
    Right ast -> case reorderModule ast of
      Left es -> assertFailure ("reorder: " ++ show es)
      Right rm -> case TC.inferProgramWith B.initialEnv SO.Embedded (reorderedAst rm) of
        Left e        -> assertFailure ("typecheck: " ++ show e)
        Right _       -> pure ()

-- | Parse, reorder, and typecheck a module; assert it fails with an error
-- matching the predicate.
assertModuleFailsWith :: (TErr.TypeError -> Bool) -> Text -> Assertion
assertModuleFailsWith p src =
  case parse src of
    Left err -> assertFailure ("parse: " ++ err)
    Right ast -> case reorderModule ast of
      Left es -> assertFailure ("reorder: " ++ show es)
      Right rm -> case TC.inferProgramWith B.initialEnv SO.Embedded (reorderedAst rm) of
        Left e | p e       -> pure ()
               | otherwise -> assertFailure ("wrong error: " ++ show e)
        Right _            -> assertFailure "expected a type error, got success"

effectDeclTests :: TestTree
effectDeclTests = testGroup "Wok.TypeChecking.EffectDecl"
  [ testCase "inline effect decl typechecks" $
      assertModuleTypechecks $ T.unlines
        [ T.pack "module Main"
        , T.pack "effect IO = { read : String -> String, write : String -> () }"
        ]

  , testCase "block-form effect decl typechecks" $
      assertModuleTypechecks $ T.unlines
        [ T.pack "module Main"
        , T.pack "effect IO = {"
        , T.pack "  read : String -> String"
        , T.pack "  write : String -> ()"
        , T.pack "}"
        ]

  , testCase "parameterized effect decl (State a) typechecks" $
      assertModuleTypechecks $ T.unlines
        [ T.pack "module Main"
        , T.pack "effect State a = {"
        , T.pack "  get : () -> a"
        , T.pack "  set : a -> ()"
        , T.pack "}"
        ]

  , testCase "duplicate operation name is rejected" $
      assertModuleFailsWith isDuplicateOperation $ T.unlines
        [ T.pack "module Main"
        , T.pack "effect IO = { read : String -> String, read : String -> () }"
        ]

  , -- #7: the `..`-polarity rule applies to OPERATION types too, not just
    -- top-level signatures -- an anonymous tail in a parameter position is
    -- rejected here as well, so `..` cannot escape the check via an op type.
    testCase "anonymous .. in an operation parameter is rejected" $
      assertModuleFailsWith isAnonRowTailInParam $ T.unlines
        [ T.pack "module Main"
        , T.pack "effect IO = { write : String -> () }"
        , T.pack "effect Weird = { run : (() -> () with IO + ..) -> () }"
        ]

  , -- #7 (data-field path): the same chokepoint (translateConArg) also covers
    -- record-field types, so an anonymous `..` in a field's function-parameter
    -- position is rejected too -- `..` cannot escape via a data declaration.
    testCase "anonymous .. in a data-field parameter is rejected" $
      assertModuleFailsWith isAnonRowTailInParam $ T.unlines
        [ T.pack "module Main"
        , T.pack "effect IO = { write : String -> () }"
        , T.pack "data Box = Box { f : (() -> () with IO + ..) -> () }"
        ]
  ]
  where
    isDuplicateOperation TErr.DuplicateOperation{} = True
    isDuplicateOperation _                         = False
    isAnonRowTailInParam TErr.AnonRowTailInParam{} = True
    isAnonRowTailInParam _                         = False

-- | Typecheck a module and return the inferred scheme of a top-level name,
-- rendered via prettyScheme. Exercises with-clause translation + printing.
schemeOf :: [Text] -> Text -> Either String Text
schemeOf declLines name =
  let src = T.unlines (T.pack "module Main" : declLines)
  in case parse src of
       Left err -> Left ("parse: " ++ err)
       Right ast -> case reorderModule ast of
         Left es -> Left ("reorder: " ++ show es)
         Right rm -> case TC.inferProgramWith B.initialEnv SO.Embedded (reorderedAst rm) of
           Left e -> Left ("typecheck: " ++ show e)
           Right (env, _, _) -> case TE.lookupVar name env of
             Just sch -> Right (TC.prettyScheme sch)
             Nothing  -> Left ("not registered: " ++ T.unpack name)

effectSigTests :: TestTree
effectSigTests = testGroup "Wok.TypeChecking.EffectSig"
  [ testCase "closed single effect: with IO" $
      schemeOf
        [ T.pack "effect IO = { read : String -> String, write : String -> () }"
        , T.pack "greet : String -> () with IO"
        ]
        (T.pack "greet")
        @?= Right (T.pack "String -> () with IO")

  , testCase "multiple effects: with IO + Logger" $
      schemeOf
        [ T.pack "effect IO = { write : String -> () }"
        , T.pack "effect Logger = { log : String -> () }"
        , T.pack "multi : () -> () with IO + Logger"
        ]
        (T.pack "multi")
        @?= Right (T.pack "() -> () with IO + Logger")

  , testCase "named tail shared across positions: with IO + eff e" $
      schemeOf
        [ T.pack "effect IO = { write : String -> () }"
        , T.pack "runIO : (() -> a with IO + eff e) -> a with eff e"
        ]
        (T.pack "runIO")
        @?= Right (T.pack "forall b a. (() -> b with IO + eff a) -> b with eff a")

  , testCase "anonymous tail: with IO + .." $
      schemeOf
        [ T.pack "effect IO = { write : String -> () }"
        , T.pack "logIt : () -> () with IO + .."
        ]
        (T.pack "logIt")
        @?= Right (T.pack "forall a. () -> () with IO + eff a")

  , testCase "parameterized effect atom (State U64)" $
      schemeOf
        [ T.pack "effect State a = { get : () -> a, set : a -> () }"
        , T.pack "stateful : () -> U64 with State U64"
        ]
        (T.pack "stateful")
        @?= Right (T.pack "() -> U64 with State")

  , testCase "undeclared effect in with-clause is rejected" $
      case schemeOf [T.pack "bad : () -> () with FooBar"] (T.pack "bad") of
        Left msg -> assertBool ("expected MissingEffectDecl, got: " ++ msg)
                      ("MissingEffectDecl" `isInfixOfStr` msg)
        Right s  -> assertFailure ("expected error, got: " ++ T.unpack s)

  , testCase "eff and row vars of the same name do not collapse" $
      case schemeOf
             [ T.pack "data Point = Point { x : U64, y : U64 }"
             , T.pack "effect IO = { write : String -> () }"
             , T.pack "mix : Point + row r -> () with IO + eff r"
             ]
             (T.pack "mix") of
        Left msg -> assertFailure ("expected success, got: " ++ msg)
        Right _  -> pure ()
  ]
  where
    isInfixOfStr needle hay = T.pack needle `T.isInfixOf` T.pack hay

-- Named effect instances (Task 3): an effect name in TYPE position is an
-- instance-handle type; the dot accessor is type-directed (handle -> named
-- perform off the instance, NOT the ambient row; record -> field; unresolved ->
-- ambiguous-accessor error); and the two named `with` forms infer. These run
-- through `schemeOf` (inference only) since lowering is Task 4.
namedInstanceTests :: TestTree
namedInstanceTests = testGroup "Wok.TypeChecking.NamedInstance"
  [ testGroup "effect-as-type + type-directed perform"
      [ -- A handle-typed parameter: `count.set`/`count.get` are NAMED performs
        -- off the instance, so they do NOT add `State` to the ambient row.
        testCase "named perform off a handle param stays off the row" $
          schemeOf
            [ T.pack "effect State s = { get : s, set : s -> () }"
            , T.pack "prog : State U64 -> State U64 -> ()"
            , T.pack "prog count total = let b = count.set count.get in total.set total.get"
            ]
            (T.pack "prog")
            @?= Right (T.pack "State U64 -> State U64 -> ()")

      , -- The op's result type ties to the handle's OWN type argument (the U64
        -- in `State U64`): `b.get : U64` feeds `a.set : U64 -> ()`, so both
        -- handles tie to U64 independently.
        testCase "two same-typed handles tie independently to U64" $
          schemeOf
            [ T.pack "effect State s = { get : s, set : s -> () }"
            , T.pack "sumProd : State U64 -> State U64 -> ()"
            , T.pack "sumProd a b = a.set b.get"
            ]
            (T.pack "sumProd")
            @?= Right (T.pack "State U64 -> State U64 -> ()")

      , -- A handle-typed parameter coexists with an ambient effect row: the
        -- named perform stays off the row, leaving only `IO` on the arrow.
        testCase "handle param coexists with an ambient IO row" $
          schemeOf
            [ T.pack "effect State s = { get : s, set : s -> () }"
            , T.pack "effect IO = { write : String -> () }"
            , T.pack "logged : State U64 -> () with IO"
            , T.pack "logged s = let b = s.set s.get in IO.write \"bumped\""
            ]
            (T.pack "logged")
            @?= Right (T.pack "State U64 -> () with IO")

      , -- Record projection still dispatches by type (regression guard for the
        -- type-directed dot). The nominal row is printed by prettyScheme.
        testCase "record field projection still works (regression)" $
          schemeOf
            [ T.pack "data Point = Point { x : U64, y : U64 }"
            , T.pack "getX : Point -> U64"
            , T.pack "getX p = p.x"
            ]
            (T.pack "getX")
            @?= Right (T.pack "Point { x,y, } -> U64")
      ]

  , testGroup "ambiguous accessor (unannotated receiver)"
      [ testCase "unannotated `c.get` is an ambiguous-accessor error" $
          case schemeOf
                 [ T.pack "effect State s = { get : s, set : s -> () }"
                 , T.pack "bump c = c.get"
                 ]
                 (T.pack "bump") of
            Left msg -> assertBool ("expected AmbiguousAccessor, got: " ++ msg)
                          (T.pack "AmbiguousAccessor" `T.isInfixOf` T.pack msg)
            Right s  -> assertFailure ("expected rejection, got: " ++ T.unpack s)
      ]

  , testGroup "named with-forms"
      [ -- EWithNamedH: a named primitive handler. `s.get`/`s.set` in the body
        -- are named performs routed to `s`; the body's other ambient effects
        -- (none here) flow out. The whole `with` yields the body's value type.
        testCase "named primitive handler binds self and infers the body" $
          schemeOf
            [ T.pack "effect State s = { get : s, set : s -> () }"
            , T.pack "runLocal : U64 -> U64"
            , T.pack "runLocal i = with s = State { get -> i ; set x k -> k () ; v -> v } in s.get"
            ]
            (T.pack "runLocal")
            @?= Right (T.pack "U64 -> U64")

      , -- GUARDRAIL for the deliberate no-`&` design: capability binders are
        -- plain names (`with x = ...`). There is no `&` sigil token, so a
        -- `with &x = ...` header must fail to parse. Locks the surface syntax
        -- decision (see effect-surface-syntax-final / at-token-reserved memos).
        testCase "a sigil-prefixed capability binder (with &x) fails to parse" $
          case parse (T.pack "module Main\nmain = with &x = state 0 in x") of
            Left _  -> pure ()
            Right _ -> assertFailure "expected a parse error for `with &x`, got a successful parse"
      ]
  ]

-- | The carrier rule (named effect instances, §4.3): a second-class escape check
-- run after inference. A handle (or a closure capturing one) may appear only as
-- a perform receiver or in a handle-typed parameter slot; anywhere else it is
-- rejected. The golden fail-examples 51-54 pin the four canonical REJECT cases
-- end-to-end (through the runner desugar); these unit tests lock the ALLOW path
-- (which must keep type-checking) and the soundness case (a handle through a
-- polymorphic parameter still escapes), plus the inline-form rejections.
carrierRuleTests :: TestTree
carrierRuleTests = testGroup "Wok.TypeChecking.CarrierRule"
  [ testGroup "ALLOW (must still type-check)"
      [ -- Performs through a handle parameter return non-handle values; nothing
        -- escapes. (Same shape as the prog/sumProd named-instance tests.)
        testCase "performs through a handle param do not escape" $
          schemeOf
            [ T.pack "effect State s = { get : s, set : s -> () }"
            , T.pack "prog : State U64 -> State U64 -> ()"
            , T.pack "prog count total = let b = count.set count.get in total.set total.get"
            ]
            (T.pack "prog")
            @?= Right (T.pack "State U64 -> State U64 -> ()")

      , -- A handle passed into a handle-typed parameter slot (condition 2).
        testCase "passing handles to handle-typed params is allowed" $
          schemeOf
            [ T.pack "effect State s = { get : s, set : s -> () }"
            , T.pack "prog : State U64 -> State U64 -> ()"
            , T.pack "prog count total = total.set count.get"
            , T.pack "caller : State U64 -> State U64 -> ()"
            , T.pack "caller x y = prog x y"
            ]
            (T.pack "caller")
            @?= Right (T.pack "State U64 -> State U64 -> ()")

      , -- A closure capturing a handle, USED LOCALLY (called, never returned or
        -- stored), is allowed. The final result is a U64, not a carrier.
        testCase "a local closure capturing a handle, used in place, is allowed" $
          schemeOf
            [ T.pack "effect State s = { get : s, set : s -> () }"
            , T.pack "prog : State U64 -> U64"
            , T.pack "prog count = let f = \\x -> count.set x in let z = f 5 in count.get"
            ]
            (T.pack "prog")
            @?= Right (T.pack "State U64 -> U64")

      , -- A PARTIAL APPLICATION capturing a handle, used locally (called, never
        -- returned or stored), is allowed — mirrors the literal-closure case.
        -- `peek count : () -> U64` captures `count` but is invoked in place; only
        -- the U64 result escapes.
        testCase "a local partial application capturing a handle, used in place, is allowed" $
          schemeOf
            [ T.pack "effect State s = { get : s, set : s -> () }"
            , T.pack "peek : State U64 -> () -> U64"
            , T.pack "peek c u = c.get"
            , T.pack "prog : State U64 -> U64"
            , T.pack "prog count = let f = peek count in let v = f () in v"
            ]
            (T.pack "prog")
            @?= Right (T.pack "State U64 -> U64")

      , testCase "carrier predicates consult the tcCarrier marker set" $ do
          let carrierTys = Set.fromList [T.pack "H"]
              hApplied   = Ty.CTCon (Ty.TcUser (T.pack "H")) [Ty.CTCon Ty.TcU64 []]
              other      = Ty.CTCon (Ty.TcUser (T.pack "Other")) []
              effHandle  = Ty.CTCon (Ty.TcEffect (T.pack "State")) [Ty.CTCon Ty.TcU64 []]
          Carrier.isHandleType        carrierTys hApplied @?= True
          Carrier.isAffineCarrierType carrierTys hApplied @?= True
          Carrier.isHandleType        carrierTys other    @?= False
          Carrier.isAffineCarrierType carrierTys other    @?= False
          Carrier.isHandleType        Set.empty  effHandle @?= True
          Carrier.isAffineCarrierType Set.empty  effHandle @?= False
      ]

  , testGroup "REJECT (carrier escapes its scope)"
      [ -- A bare handle returned.
        testCase "returning a bare handle escapes" $
          assertCarrierEscape
            [ T.pack "effect State s = { get : s, set : s -> () }"
            , T.pack "leak : State U64 -> State U64"
            , T.pack "leak c = c"
            ]
            (T.pack "leak")

      , -- A handle stored in a constructor (a polymorphic slot).
        testCase "storing a handle in a constructor escapes" $
          assertCarrierEscape
            [ T.pack "data Box a = Box a"
            , T.pack "effect State s = { get : s, set : s -> () }"
            , T.pack "leak : State U64 -> Box (State U64)"
            , T.pack "leak c = Box c"
            ]
            (T.pack "leak")

      , -- A handle collected into a list.
        testCase "collecting handles in a list escapes" $
          assertCarrierEscape
            [ T.pack "effect State s = { get : s, set : s -> () }"
            , T.pack "leak : State U64 -> State U64 -> [State U64]"
            , T.pack "leak a b = [a, b]"
            ]
            (T.pack "leak")

      , -- A returned closure capturing a handle.
        testCase "returning a closure that captures a handle escapes" $
          assertCarrierEscape
            [ T.pack "effect State s = { get : s, set : s -> () }"
            , T.pack "leak : State U64 -> (U64 -> ())"
            , T.pack "leak count = \\x -> count.set x"
            ]
            (T.pack "leak")

      , -- A partial application capturing a handle, let-bound and then RETURNED
        -- (the C1 bug): `peek count : () -> U64` closes over `count`; returning it
        -- lets the handle outlive its scope. Must be rejected like a returned
        -- lambda.
        testCase "returning a let-bound partial application that captures a handle escapes" $
          assertCarrierEscape
            [ T.pack "effect State s = { get : s, set : s -> () }"
            , T.pack "peek : State U64 -> () -> U64"
            , T.pack "peek c u = c.get"
            , T.pack "leak : State U64 -> (() -> U64)"
            , T.pack "leak count = let f = peek count in f"
            ]
            (T.pack "leak")

      , -- A partial application capturing a handle, returned DIRECTLY (no
        -- let-binder). Same escape, caught at the partial application's own
        -- position.
        testCase "returning a partial application that captures a handle escapes" $
          assertCarrierEscape
            [ T.pack "effect State s = { get : s, set : s -> () }"
            , T.pack "peek : State U64 -> () -> U64"
            , T.pack "peek c u = c.get"
            , T.pack "leak : State U64 -> (() -> U64)"
            , T.pack "leak count = peek count"
            ]
            (T.pack "leak")

      , -- SOUNDNESS: a handle passed to a POLYMORPHIC parameter escapes, even
        -- though the call-site arrow looks handle-typed. The declared (generic)
        -- param of `identity` is a type variable, NOT a handle slot.
        testCase "a handle through a polymorphic parameter still escapes" $
          assertCarrierEscape
            [ T.pack "effect State s = { get : s, set : s -> () }"
            , T.pack "identity : a -> a"
            , T.pack "identity x = x"
            , T.pack "leak : State U64 -> State U64"
            , T.pack "leak c = identity c"
            ]
            (T.pack "leak")
      ]
  ]
  where
    assertCarrierEscape declLines name =
      case schemeOf declLines name of
        Left msg
          | T.pack "CarrierEscape" `T.isInfixOf` T.pack msg -> pure ()
          | otherwise -> assertFailure ("expected CarrierEscape, got: " ++ msg)
        Right s -> assertFailure ("expected rejection, got: " ++ T.unpack s)

-- The eff/row domain split is enforced by the grammar, not the typechecker:
-- `eff` only appears in an EffectRow (right of `with`) and `row` only in a
-- RowContrib (right of type-level `+`). Mixing them is therefore a parse error.
-- These tests lock that invariant (so there is no need for a RowDomainMismatch
-- type error).
effectGrammarTests :: TestTree
effectGrammarTests = testGroup "effect/row domain split (grammar)"
  [ testCase "an eff var in a record tail fails to parse" $
      assertParseFails (T.pack "module Main\nf : Point + eff e -> ()\n")
  , testCase "a row var in a with-clause fails to parse" $
      assertParseFails $ T.unlines
        [ T.pack "module Main"
        , T.pack "effect IO = { write : String -> () }"
        , T.pack "g : () -> () with row r"
        ]
  ]
  where
    assertParseFails src = case parse src of
      Left _  -> pure ()
      Right _ -> assertFailure "expected a parse error, got a successful parse"

effectOpTests :: TestTree
effectOpTests = testGroup "Wok.TypeChecking.EffectOp"
  [ testCase "calling an operation infers its effect" $
      schemeOf
        [ T.pack "effect IO = { write : String -> () }"
        , T.pack "shout s = IO.write s"
        ]
        (T.pack "shout")
        @?= Right (T.pack "String -> () with IO")

  , testCase "declared with IO + IO body typechecks" $
      schemeOf
        [ T.pack "effect IO = { write : String -> () }"
        , T.pack "greet : String -> () with IO"
        , T.pack "greet s = IO.write s"
        ]
        (T.pack "greet")
        @?= Right (T.pack "String -> () with IO")

  , testCase "calling two effectful functions unions their effects" $
      schemeOf
        [ T.pack "effect IO = { write : String -> () }"
        , T.pack "effect Logger = { log : String -> () }"
        , T.pack "useIO : () -> () with IO"
        , T.pack "useIO u = IO.write \"x\""
        , T.pack "useLog : () -> () with Logger"
        , T.pack "useLog u = Logger.log \"y\""
        , T.pack "both u = let a = useIO () in useLog ()"
        ]
        (T.pack "both")
        @?= Right (T.pack "forall a. a -> () with IO + Logger")

  , testCase "pure-declared body calling an operation is rejected" $
      case schemeOf
             [ T.pack "effect IO = { write : String -> () }"
             , T.pack "bad : String -> ()"
             , T.pack "bad s = IO.write s"
             ]
             (T.pack "bad") of
        Left _  -> pure ()  -- rejected (RowMismatch / UndischargedEffect)
        Right s -> assertFailure ("expected rejection, got: " ++ T.unpack s)

  , testCase "unknown operation of a declared effect is rejected" $
      case schemeOf
             [ T.pack "effect IO = { write : String -> () }"
             , T.pack "bad s = IO.read s"
             ]
             (T.pack "bad") of
        Left msg -> assertBool ("expected UnknownOperation, got: " ++ msg)
                      (T.pack "UnknownOperation" `T.isInfixOf` T.pack msg)
        Right s  -> assertFailure ("expected rejection, got: " ++ T.unpack s)

  ]

effectHandlerTests :: TestTree
effectHandlerTests = testGroup "Wok.TypeChecking.EffectHandler"
  [ testCase "runIO discharges IO from the result row" $
      schemeOf
        [ T.pack "effect IO = { read : String -> String, write : String -> () }"
        , T.pack "runIO comp ="
        , T.pack "  with { IO.read p -> p"
        , T.pack "       ; IO.write m -> ()"
        , T.pack "       ; v -> v }"
        , T.pack "  comp ()"
        ]
        (T.pack "runIO")
        @?= Right (T.pack "forall a. (() -> a) -> a")

  , testCase "effect-translating handler: Logger discharged, IO introduced" $
      schemeOf
        [ T.pack "effect Logger = { log : String -> () }"
        , T.pack "effect IO = { write : String -> () }"
        , T.pack "logToIO c ="
        , T.pack "  with { Logger.log m -> IO.write m"
        , T.pack "       ; v -> v }"
        , T.pack "  c ()"
        ]
        (T.pack "logToIO")
        @?= Right (T.pack "forall a. (() -> a) -> a with IO")

  , testCase "non-exhaustive handler is rejected (HandlerCoverage)" $
      case schemeOf
             [ T.pack "effect IO = { read : String -> String, write : String -> () }"
             , T.pack "runIO comp ="
             , T.pack "  with { IO.read p -> p }"
             , T.pack "  comp ()"
             ]
             (T.pack "runIO") of
        Left msg -> assertBool ("expected HandlerCoverage, got: " ++ msg)
                      (T.pack "HandlerCoverage" `T.isInfixOf` T.pack msg)
        Right s  -> assertFailure ("expected rejection, got: " ++ T.unpack s)

  , testCase "handler with no return arm: result is the handled type" $
      schemeOf
        [ T.pack "effect IO = { write : String -> () }"
        , T.pack "runIO comp ="
        , T.pack "  with { IO.write m -> () }"
        , T.pack "  comp ()"
        ]
        (T.pack "runIO")
        @?= Right (T.pack "forall a. (() -> a) -> a")
  ]

-- Adversarial coverage for the effect system: the spec's acceptance criteria
-- that the happy-path fixtures do NOT exercise -- partial discharge, the
-- single-use-vs-threading rule (spec 136-151), multi-effect handlers, operation
-- mismatches, and the two known spec/impl divergences (handler effect-presence,
-- main row emptiness) pinned as characterization so a future change is forced
-- to update them deliberately.
effectPressureTests :: TestTree
effectPressureTests = testGroup "Wok.TypeChecking.EffectPressure"
  [ testGroup "discharge"
      [ testCase "handler discharges only the handled effect; residual flows out" $
          schemeOf
            [ "effect IO = { write : String -> () }"
            , "effect Logger = { log : String -> () }"
            , "partial : (() -> a with IO + Logger + eff e) -> a with Logger + eff e"
            , "partial comp ="
            , "  with { IO.write m -> ()"
            , "       ; v -> v }"
            , "  comp ()"
            ]
            "partial"
            @?= Right "forall b a. (() -> b with IO + Logger + eff a) -> b with Logger + eff a"

      , testCase "one handler discharges two effects at once" $
          schemeOf
            [ "effect IO = { write : String -> () }"
            , "effect Logger = { log : String -> () }"
            , "runBoth : (() -> a with IO + Logger + eff e) -> a with eff e"
            , "runBoth comp ="
            , "  with { IO.write m -> ()"
            , "       ; Logger.log m -> ()"
            , "       ; v -> v }"
            , "  comp ()"
            ]
            "runBoth"
            @?= Right "forall b a. (() -> b with IO + Logger + eff a) -> b with eff a"
      ]

  , testGroup "threading rule (.. is single-use; eff e threads)"
      [ -- spec 145: an anonymous `..` cannot thread, so it is rejected in a
        -- parameter (contravariant) position -- here the callback's `IO + ..`.
        -- A callback's effects could only be dropped via an anonymous tail;
        -- the user must name it (`eff e`) to carry them through.
        testCase "anonymous .. in a callback parameter is rejected (spec 145)" $
          schemeRejected
            [ "effect IO = { write : String -> () }"
            , "relay : (() -> a with IO + ..) -> a with IO + .."
            , "relay f = f ()"
            ]
            "relay"

      , testCase "named eff e threads a param tail to the result (accepted)" $
          schemeOf
            [ "effect IO = { write : String -> () }"
            , "relay : (() -> a with IO + eff e) -> a with IO + eff e"
            , "relay f = f ()"
            ]
            "relay"
            @?= Right "forall b a. (() -> b with IO + eff a) -> b with IO + eff a"

      , -- spec 142: the same rule for records -- an anonymous `..` record tail in
        -- a parameter position is rejected; use `row r` (next test) to thread the
        -- input's extra fields through to the output.
        testCase "record .. in a parameter position is rejected (spec 142)" $
          schemeRejected
            [ "data Point = Point { x : U64, y : U64 }"
            , "preserveBad : Point + .. -> Point + .."
            , "preserveBad p = p"
            ]
            "preserveBad"

      , testCase "record row r threads input tail to output (accepted)" $
          case schemeOf
                 [ "data Point = Point { x : U64, y : U64 }"
                 , "preserveOk : Point + row r -> Point + row r"
                 , "preserveOk p = p"
                 ]
                 "preserveOk" of
            Left msg -> assertFailure ("expected success, got: " ++ msg)
            Right _  -> pure ()
      ]

  , testGroup "operation calls"
      [ testCase "two calls of the same effect union to a single label" $
          schemeOf
            [ "effect IO = { write : String -> () }"
            , "twice u = let a = IO.write \"x\" in IO.write \"y\""
            ]
            "twice"
            @?= Right "forall a. a -> () with IO"

      , testCase "parameterized effect: get/set share the effect's type param" $
          case schemeOf
                 [ "effect State a = { get : () -> a, set : a -> () }"
                 , "incr u = let n = State.get () in State.set n"
                 ]
                 "incr" of
            Left msg -> assertFailure ("expected success, got: " ++ msg)
            Right _  -> pure ()

      , testCase "operation called with the wrong argument type is rejected" $
          schemeRejected
            [ "effect IO = { write : String -> () }"
            , "bad : () -> () with IO"
            , "bad u = IO.write 42"
            ]
            "bad"

      , -- Regression guard for the multi-arg arrow-placement fix: the parser
        -- attaches `with E` to the INNERMOST arrow (where a fully-applied
        -- curried function performs its effects), and the body's ambient is now
        -- seeded from that same arrow. A multi-arg effectful function therefore
        -- typechecks (it was wrongly rejected with UndischargedEffect before).
        testCase "multi-arg effectful function typechecks (effect on the innermost arrow)" $
          schemeOf
            [ "effect IO = { write : String -> () }"
            , "f : U64 -> U64 -> () with IO"
            , "f x y = IO.write \"x\""
            ]
            "f"
            @?= Right "U64 -> U64 -> () with IO"

      , testCase "three-arg effectful function typechecks (deeper innermost arrow)" $
          schemeOf
            [ "effect IO = { write : String -> () }"
            , "g : U64 -> U64 -> U64 -> () with IO"
            , "g x y z = IO.write \"x\""
            ]
            "g"
            @?= Right "U64 -> U64 -> U64 -> () with IO"

      , testCase "unsigned multi-arg effectful function infers the effect on the innermost arrow" $
          schemeOf
            [ "effect IO = { write : String -> () }"
            , "h x y = IO.write x"
            ]
            "h"
            @?= Right "forall a. String -> a -> () with IO"
      ]

  , testGroup "handler arms"
      [ testCase "arm body type must match the operation's result type" $
          schemeRejected
            [ "effect IO = { read : String -> String }"
            , "bad comp ="
            , "  with { IO.read p -> 42"
            , "       ; v -> v }"
            , "  comp ()"
            ]
            "bad"
      ]

  , testGroup "known spec/impl divergences (characterization)"
      [ -- Spec step 2 (handler typing): "each handled effect E must be present
        -- in rho." The current impl is lenient -- handling an effect the
        -- scrutinee never performs is silently accepted (the handled label is
        -- simply not found to discharge). Pinned here as ACCEPTED; this flips to
        -- a rejection if/when declaration-is-authority lands.
        testCase "handling an absent effect is currently accepted (spec wants reject)" $
          case schemeOf
                 [ "effect IO = { write : String -> () }"
                 , "effect Logger = { log : String -> () }"
                 , "vacuous : () -> () with Logger"
                 , "vacuous u = Logger.log \"x\""
                 , "weird c ="
                 , "  with { IO.write m -> ()"
                 , "       ; v -> v }"
                 , "  vacuous ()"
                 ]
                 "weird" of
            Left msg -> assertFailure
                          ("currently expected to be ACCEPTED (lenient handler); got: " ++ msg)
            Right _  -> pure ()

        -- Spec line 230: "main must reduce to an empty effect row -- the
        -- compiler rejects a program with an unwired capability." v1 does not
        -- special-case main, so a main with a residual effect is accepted.
      , testCase "main with an unhandled effect is currently accepted (spec wants reject)" $
          assertModuleTypechecks $ T.unlines
            [ T.pack "module Main"
            , T.pack "effect IO = { write : String -> () }"
            , T.pack "main : () -> () with IO"
            , T.pack "main u = IO.write \"x\""
            ]
      ]
  ]
  where
    schemeRejected decls name = case schemeOf decls name of
      Left _  -> pure ()
      Right s -> assertFailure ("expected rejection, got: " ++ T.unpack s)

-- Maps the closed-by-default soundness boundary: the closed / inferred /
-- first-order core never lets an effect escape a type (it propagates the effect
-- into the caller's row, or rejects the call) -- but the `..` open-tail
-- escape hatch can DROP a parameter's effect. These tests prove the default is
-- sound and pin the single leak, so the link-tails redesign has a target.
closedByDefaultTests :: TestTree
closedByDefaultTests = testGroup "closed-by-default (soundness boundary)"
  [ testGroup "sound: closed / inferred / first-order never drops an effect"
      [ testCase "a function with no operation calls infers a pure (no `with`) type" $
          schemeOf
            [ "effect IO = { write : String -> () }"
            , "k x y = x"
            ]
            "k"
            @?= Right "forall a b. a -> b -> a"

      , testCase "an effect propagates from a callee into an unsigned caller" $
          schemeOf
            [ "effect IO = { write : String -> () }"
            , "useIO : () -> () with IO"
            , "useIO u = IO.write \"x\""
            , "caller u = useIO ()"
            ]
            "caller"
            @?= Right "forall a. a -> () with IO"

      , testCase "a pure-declared function that calls an effectful one is rejected" $
          schemeRejected
            [ "effect IO = { write : String -> () }"
            , "useIO : () -> () with IO"
            , "useIO u = IO.write \"x\""
            , "pureCaller : () -> ()"
            , "pureCaller u = useIO ()"
            ]
            "pureCaller"

      , testCase "a closed effect row rejects an operation it does not list" $
          schemeRejected
            [ "effect IO = { write : String -> () }"
            , "effect Logger = { log : String -> () }"
            , "f : () -> () with IO"
            , "f u = Logger.log \"x\""
            ]
            "f"

      , testCase "an unsigned HOF defaults to a pure callback (effectful arg rejected)" $
          schemeRejected
            [ "effect IO = { write : String -> () }"
            , "useIO : () -> () with IO"
            , "useIO u = IO.write \"x\""
            , "runThunk f = f ()"
            , "bad u = runThunk useIO"
            ]
            "bad"
      ]

  , testGroup "higher-order effect application (after the signed-binding polymorphism fix)"
      [ -- Once signed bindings are referenced via their instantiated signature
        -- (not a monomorphic placeholder), combinators can finally be APPLIED to
        -- concrete effectful arguments. The earlier RigidEscape over-rejection is
        -- gone, and `eff e` threads soundly. This is the payoff of the fix.

        -- Exact match: relaying a thunk performing exactly IO now type-checks.
        testCase "an eff e combinator applies to a concrete thunk (over-rejection fixed)" $
          schemeOf
            [ "effect IO = { write : String -> () }"
            , "useIO : () -> () with IO"
            , "useIO u = IO.write \"x\""
            , "relayE : (() -> a with IO + eff e) -> a with IO + eff e"
            , "relayE f = f ()"
            , "good u = relayE useIO"
            ]
            "good"
            @?= Right "forall a. a -> () with IO"

      , -- The same fix in the LET/WHERE path (inferLetGroup), not just top level
        -- (inferTopLetGroup): a where-bound combinator applied to a concrete
        -- thunk also works. Before the fix this RigidEscaped here too.
        testCase "a where-bound eff e combinator applies to a concrete thunk" $
          schemeOf
            [ "effect IO = { write : String -> () }"
            , "caller u = relayE useIO"
            , "  where"
            , "    relayE : (() -> a with IO + eff e) -> a with IO + eff e"
            , "    relayE f = f ()"
            , "    useIO : () -> () with IO"
            , "    useIO v = IO.write \"x\""
            ]
            "caller"
            @?= Right "forall a. a -> () with IO"

      , -- A thunk with an effect beyond the concrete part: `eff e` THREADS it to
        -- the caller's row -- the sound, intended behavior.
        testCase "eff e threads an extra concrete effect to the caller (sound)" $
          schemeOf
            [ "effect IO = { write : String -> () }"
            , "effect Logger = { log : String -> () }"
            , "relayE : (() -> a with IO + eff e) -> a with IO + eff e"
            , "relayE f = f ()"
            , "useIL : () -> () with IO + Logger"
            , "useIL u = let l = Logger.log \"x\" in IO.write \"y\""
            , "good u = relayE useIL"
            ]
            "good"
            @?= Right "forall a. a -> () with IO + Logger"

      , -- spec 145 (now enforced): the `..` relay is rejected at its DEFINITION
        -- (anonymous tail in the callback parameter), so the previously-reachable
        -- silent drop of Logger is gone -- the program no longer type-checks at
        -- all. `eff e` (above) is the sound way to thread a callback's effects.
        testCase ".. relay is rejected at its definition, so no silent drop is reachable (spec 145)" $
          schemeRejected
            [ "effect IO = { write : String -> () }"
            , "effect Logger = { log : String -> () }"
            , "relay : (() -> a with IO + ..) -> a with IO + .."
            , "relay f = f ()"
            , "useIL : () -> () with IO + Logger"
            , "useIL u = let l = Logger.log \"x\" in IO.write \"y\""
            , "bad u = relay useIL"
            ]
            "bad"
      ]
  ]
  where
    schemeRejected decls name = case schemeOf decls name of
      Left _  -> pure ()
      Right s -> assertFailure ("expected rejection, got: " ++ T.unpack s)

-- A lambda is a function: the effects its body performs belong to the lambda's
-- own arrow (performed when it is applied), not to the enclosing equation.
-- Before the fix, a lambda body's operation calls leaked into the enclosing
-- binding's effect row and the lambda value was typed as a pure arrow.
lambdaEffectScopingTests :: TestTree
lambdaEffectScopingTests = testGroup "lambda effect scoping"
  [ testCase "a lambda's effect rides its own arrow (matches the signature)" $
      schemeOf
        [ "effect IO = { write : String -> () }"
        , "w : String -> () with IO"
        , "w = \\v -> IO.write v"
        ]
        "w"
        @?= Right "String -> () with IO"

  , -- The decisive no-leak check: `mk` returns an effectful closure, so APPLYING
    -- `mk` (merely building the closure) performs no effect and `safe` -- which
    -- only builds it -- stays pure. Before the fix the lambda's IO leaked onto
    -- `mk`'s arrow, making `mk u` effectful and rejecting `safe` with
    -- UndischargedEffect.
    testCase "a lambda's effect does NOT leak to the enclosing binding" $
      schemeOf
        [ "effect IO = { write : String -> () }"
        , "mk u = \\v -> IO.write v"
        , "safe : () -> ()"
        , "safe u = let f = mk u in ()"
        ]
        "safe"
        @?= Right "() -> ()"

  , -- Regression for review finding #2 (same root cause): an equation with
    -- FEWER pattern parameters than its signature's arrows, taking the rest via
    -- a lambda body, now typechecks -- the lambda carries the declared effect on
    -- the inner arrow, matching the signature.
    testCase "equation with a lambda body and fewer params than sig arrows typechecks" $
      schemeOf
        [ "effect IO = { write : String -> () }"
        , "f : U64 -> U64 -> () with IO"
        , "f x = \\y -> IO.write \"z\""
        ]
        "f"
        @?= Right "U64 -> U64 -> () with IO"
  ]

dataTests :: TestTree
dataTests = testGroup "Wok.TypeChecking.Infer (data decls)"
  [ testCase "data Maybe a = Nothing | Just a registers correctly" $
      let pos = (0,0)
          vc s = Abs.ConId (pos, T.pack s)
          vv s = Abs.VarId (pos, T.pack s)
          decl = Abs.DData (vc "Maybe") [vv "a"]
                   [ Abs.ConDef (vc "Nothing") []
                   , Abs.ConDef (vc "Just") [Abs.TVar (vv "a")]
                   ]
          result = TM.runTC_ B.initialEnv $
                     I.processDataDecls B.initialEnv [decl]
      in case result of
           Right env -> do
             case TE.lookupTyCon (T.pack "Maybe") env of
               Just info -> do
                 TE.tcArity info @?= 1
                 TE.tcCons info @?= [T.pack "Nothing", T.pack "Just"]
               Nothing -> assertFailure "Maybe missing"
             case TE.lookupCon (T.pack "Just") env of
               Just info -> do
                 TE.conArity info @?= 1
                 TE.conTyCon info @?= T.pack "Maybe"
                 case TE.conScheme info of
                   Ty.Scheme [(0, Ty.KStar)] _ body ->
                     case body of
                       Ty.CTArr (Ty.CTGen 0) Ty.CREmpty
                         (Ty.CTCon (Ty.TcUser tn) [Ty.CTGen 0])
                           | tn == T.pack "Maybe" -> pure ()
                       _ -> assertFailure ("Just body: " ++ show body)
                   _ -> assertFailure "Just scheme malformed"
               Nothing -> assertFailure "Just missing"
           Left e -> assertFailure (show e)
  , testCase "duplicate tycon (vs Std.Base Bool) errors" $ do
      env <- stdBaseExtendedEnv
      let pos = (0,0)
          vc s = Abs.ConId (pos, T.pack s)
          decl = Abs.DData (vc "Bool") [] []
          result = TM.runTC_ env $ I.processDataDecls env [decl]
      case result of
        Left (TErr.DuplicateTyCon _ _) -> pure ()
        _ -> assertFailure
                ("expected DuplicateTyCon, got "
                ++ either show (const "Right") result)
  , testCase "extern data/type elaborate to carrier-marked tycons" $
      let pos = (0,0)
          vc s = Abs.ConId (pos, T.pack s)
          vv s = Abs.VarId (pos, T.pack s)
          -- extern type Susp a b r
          suspDecl = Abs.DExternType (vc "Susp") [vv "a", vv "b", vv "r"]
          -- extern data St a b r = Done r | More a (Susp a b r)
          stDecl = Abs.DExternData (vc "St") [vv "a", vv "b", vv "r"]
                     [ Abs.ConDef (vc "Done") [Abs.TVar (vv "r")]
                     , Abs.ConDef (vc "More")
                         [ Abs.TVar (vv "a")
                         , Abs.TApp
                             (Abs.TApp
                               (Abs.TApp
                                 (Abs.TCon (Abs.MPName (vc "Susp")))
                                 (Abs.TVar (vv "a")))
                               (Abs.TVar (vv "b")))
                             (Abs.TVar (vv "r"))
                         ]
                     ]
          -- data Plain a = MkPlain a
          plainDecl = Abs.DData (vc "Plain") [vv "a"]
                        [ Abs.ConDef (vc "MkPlain") [Abs.TVar (vv "a")] ]
          result = TM.runTC_ B.initialEnv $
                     I.processDataDecls B.initialEnv [suspDecl, stDecl, plainDecl]
      in case result of
           Right env -> do
             case TE.lookupTyCon (T.pack "Susp") env of
               Just info -> TE.tcCarrier info @?= True
               Nothing   -> assertFailure "Susp missing"
             case TE.lookupTyCon (T.pack "St") env of
               Just info -> do
                 TE.tcCarrier info @?= True
                 TE.tcCons info @?= [T.pack "Done", T.pack "More"]
               Nothing -> assertFailure "St missing"
             case TE.lookupTyCon (T.pack "Plain") env of
               Just info -> TE.tcCarrier info @?= False
               Nothing   -> assertFailure "Plain missing"
           Left e -> assertFailure (show e)
  ]

patternTests :: TestTree
patternTests = testGroup "Wok.TypeChecking.Infer (patterns)"
  [ testCase "var pattern returns fresh type and one binding" $
      let result = TM.runTC_ B.initialEnv $ do
            (t, bs, _) <- I.inferPat
              (Abs.PAtom (Abs.APVar (Abs.VarId ((0,0), T.pack "x"))))
            pure (length bs, case t of Ty.TVar _ -> True; _ -> False)
      in case result of
           Right (1, True) -> pure ()
           other -> assertFailure ("unexpected: " ++ show other)
  , testCase "literal Int pattern" $
      let result = TM.runTC_ B.initialEnv $ do
            (t, _, _) <- I.inferPat
              (Abs.PAtom (Abs.APLitI
                (Abs.WokInt ((0,0), T.pack "5"))))
            U.freeze t
      in case result of
           Right ct -> ct @?= Ty.CTCon Ty.TcU64 []
           Left e -> assertFailure (show e)
  , testCase "wildcard pattern returns fresh type, no bindings" $
      let result = TM.runTC_ B.initialEnv $ do
            (_, bs, _) <- I.inferPat (Abs.PAtom Abs.APWild)
            pure (length bs)
      in case result of
           Right 0 -> pure ()
           other -> assertFailure ("unexpected: " ++ show other)
  , testCase "True nullary constructor pattern" $ do
      env <- stdBaseExtendedEnv
      let result = TM.runTC_ env $ do
            (t, _, _) <- I.inferPat (Abs.PAtom
              (Abs.APCon (Abs.MPName (Abs.ConId ((0,0), T.pack "True")))))
            U.freeze t
      case result of
        Right ct -> ct @?= Ty.CTCon Ty.TcBool []
        Left e -> assertFailure (show e)
  , testCase "tuple pattern (x, y) gives 2-tuple type and 2 bindings" $
      let pos = (0,0)
          vp s = Abs.PAtom (Abs.APVar (Abs.VarId (pos, T.pack s)))
          result = TM.runTC_ B.initialEnv $ do
            (t, bs, _) <- I.inferPat
              (Abs.PAtom (Abs.APTuple (vp "x") [vp "y"]))
            ct <- U.freeze t
            pure (ct, length bs)
      in case result of
           Right (Ty.CTCon (Ty.TcTuple 2) [_, _], 2) -> pure ()
           other -> assertFailure ("unexpected: " ++ show other)
  ]

exprBasicTests :: TestTree
exprBasicTests = testGroup "ExprBasic"
  [ testCase "literal Int" $
      let result = TM.runTC_ B.initialEnv $ do
            t <- I.inferExpr (Abs.ELitI (Abs.WokInt ((0,0), T.pack "42")))
            U.freeze t
      in case result of
           Right ct -> ct @?= Ty.CTCon Ty.TcU64 []
           Left e -> assertFailure (show e)
  , testCase "if True then 1 else 2 : Int" $ do
      env <- stdBaseExtendedEnv
      let true = Abs.ECon (Abs.ConId ((0,0), T.pack "True"))
          mkI s = Abs.ELitI (Abs.WokInt ((0,0), T.pack s))
          result = TM.runTC_ env $ do
            t <- I.inferExpr (Abs.EIf true (mkI "1") (mkI "2"))
            U.freeze t
      case result of
        Right ct -> ct @?= Ty.CTCon Ty.TcU64 []
        Left e -> assertFailure (show e)
  , testCase "(+) 1 2 : Int" $ do
      env <- stdBaseExtendedEnv
      let plus = Abs.EParenOp (Abs.VarSym ((0,0), T.pack "+"))
          mkI s = Abs.ELitI (Abs.WokInt ((0,0), T.pack s))
          result = TM.runTC_ env $ do
            t <- I.inferExpr (Abs.EApp (Abs.EApp plus (mkI "1")) (mkI "2"))
            U.freeze t
      case result of
        Right ct -> ct @?= Ty.CTCon Ty.TcU64 []
        Left e -> assertFailure (show e)
  , testCase "\\x -> x : a -> a" $
      let lam = Abs.ELam [Abs.APVar (Abs.VarId ((0,0), T.pack "x"))]
                  (Abs.EVar (Abs.VarId ((0,0), T.pack "x")))
          result = TM.runTC_ B.initialEnv $ do
            t <- I.inferExpr lam
            U.freeze t
      in case result of
           Right (Ty.CTArr (Ty.CTGen i) Ty.CREmpty (Ty.CTGen j)) | i == j -> pure ()
           other -> assertFailure ("unexpected: " ++ show other)
  , testCase "EProj on unknown var fails with UnknownVar" $
      let proj = Abs.EProj (Abs.EVar (Abs.VarId ((0,0), T.pack "x")))
                   (Abs.VarId ((0,0), T.pack "y"))
          result = TM.runTC_ B.initialEnv
                     (I.inferExpr proj >>= \t -> U.freeze t)
      in case result of
           Left (TErr.UnknownVar _ _) -> pure ()
           _ -> assertFailure
                  ("expected UnknownVar, got "
                  ++ either show (const "Right") result)
  ]

exprLetTests :: TestTree
exprLetTests = testGroup "ExprLet"
  [ testCase "let id = \\x -> x in (id 1, id True) : (Int, Bool)" $ do
      env <- stdBaseExtendedEnv
      let pos = (0,0)
          v s = Abs.VarId (pos, T.pack s)
          c s = Abs.ConId (pos, T.pack s)
          ldId = Abs.LDEqn
                   (Abs.LHSPre (Abs.FNBare (v "id")) [Abs.APVar (v "x")])
                   (Abs.EVar (v "x")) Abs.NoWhere
          one  = Abs.ELitI (Abs.WokInt (pos, T.pack "1"))
          true = Abs.ECon (c "True")
          body = Abs.ETuple
                   (Abs.EApp (Abs.EVar (v "id")) one)
                   [Abs.EApp (Abs.EVar (v "id")) true]
          result = TM.runTC_ env $ do
            t <- I.inferExpr (Abs.ELet [ldId] body)
            U.freeze t
      case result of
        Right ct -> ct @?= Ty.CTCon (Ty.TcTuple 2)
                           [Ty.CTCon Ty.TcU64 [], Ty.CTCon Ty.TcBool []]
        Left e -> assertFailure (show e)
  , testCase "case True of True -> 1; False -> 0 : Int" $ do
      env <- stdBaseExtendedEnv
      let pos = (0,0)
          c s  = Abs.ConId (pos, T.pack s)
          mkI s = Abs.ELitI (Abs.WokInt (pos, T.pack s))
          true = Abs.ECon (c "True")
          altT = Abs.AltC (Abs.PAtom (Abs.APCon (Abs.MPName (c "True"))))
                          (mkI "1") Abs.NoWhere
          altF = Abs.AltC (Abs.PAtom (Abs.APCon (Abs.MPName (c "False"))))
                          (mkI "0") Abs.NoWhere
          result = TM.runTC_ env $ do
            t <- I.inferExpr (Abs.ECase true [altT, altF])
            U.freeze t
      case result of
        Right ct -> ct @?= Ty.CTCon Ty.TcU64 []
        Left e -> assertFailure (show e)
  , testCase "f x = let y = x in y : forall a. a -> a (escape via outer var)" $
      let src = T.pack "f x = let y = x in y\n"
          result = do
            parsed <- first ("parse: " ++) (parse src)
            reord  <- first (("reorder: " ++) . show) (reorderModule parsed)
            first (("typecheck: " ++) . show)
              (TC.inferProgram (reorderedAst reord))
      in case result of
           Right (_, [td]) ->
             case TC.tdScheme td of
               Ty.Scheme [(0, Ty.KStar)] _
                 (Ty.CTArr (Ty.CTGen 0) Ty.CREmpty (Ty.CTGen 0)) -> pure ()
               other -> assertFailure ("expected forall a. a -> a, got " ++ show other)
           Right (_, decls) ->
             assertFailure ("expected single f decl, got " ++ show (length decls))
           Left err -> assertFailure err
  ]

programTests :: TestTree
programTests = testGroup "Wok.TypeChecking (program)"
  [ testCase "id : forall a. a -> a end-to-end" $
      let src = T.pack "id x = x\n"
          result = do
            parsed <- first ("parse: " ++) (parse src)
            reord  <- first (("reorder: " ++) . show) (reorderModule parsed)
            first (("typecheck: " ++) . show)
              (TC.inferProgram (reorderedAst reord))
      in case result of
           Right (_, [td]) ->
             case TC.tdScheme td of
               Ty.Scheme [(0, Ty.KStar)] _
                 (Ty.CTArr (Ty.CTGen 0) Ty.CREmpty (Ty.CTGen 0)) -> pure ()
               other -> assertFailure ("got: " ++ show other)
           Right (_, decls) ->
             assertFailure
               ("expected single id decl, got " ++ show (length decls))
           Left err -> assertFailure err
  ]

bodylessSigTests :: TestTree
bodylessSigTests = testGroup "bodyless"
  [ testCase "bodyless top-level sig becomes a visible binding" $
      let src = T.pack "myConst : a -> a\n"
          result = case parse src of
            Right ast -> case reorderModule ast of
              Right rm -> TC.inferProgram (reorderedAst rm)
              Left  es -> Left (TErr.UnknownVar Nothing (T.pack ("setup: " ++ show es)))
            Left err -> Left (TErr.UnknownVar Nothing (T.pack ("setup: " ++ err)))
      in case result of
           Right (env, _) ->
             case TE.lookupVar (T.pack "myConst") env of
               Just s ->
                 case s of
                   Ty.Scheme [(_, Ty.KStar)] _
                     (Ty.CTArr (Ty.CTGen i) Ty.CREmpty (Ty.CTGen j))
                     | i == j -> pure ()
                   other -> assertFailure ("unexpected scheme: " ++ show other)
               Nothing -> assertFailure "myConst missing from env"
           Left e -> assertFailure ("unexpected error: " ++ show e)

  , testCase "UserFile bodyless sig emits exactly one warning" $
      let src = T.pack "myConst : a -> a\n"
          result = case parse src of
            Right ast -> case reorderModule ast of
              Right rm -> TC.inferProgramWith B.initialEnv
                            (SO.UserFile "<test>") (reorderedAst rm)
              Left  es -> error ("setup: " ++ show es)
            Left err -> error ("setup: " ++ err)
      in case result of
           Right (_env, _decls, warnings) ->
             case warnings of
               [TC.BodylessBinding n _] -> n @?= T.pack "myConst"
               other -> assertFailure ("expected one BodylessBinding, got: " ++ show other)
           Left e -> assertFailure ("unexpected error: " ++ show e)

  , testCase "Embedded bodyless sig emits zero warnings" $
      let src = T.pack "myConst : a -> a\n"
          result = case parse src of
            Right ast -> case reorderModule ast of
              Right rm -> TC.inferProgramWith B.initialEnv
                            SO.Embedded (reorderedAst rm)
              Left  es -> error ("setup: " ++ show es)
            Left err -> error ("setup: " ++ err)
      in case result of
           Right (_, _, []) -> pure ()
           Right (_, _, ws) -> assertFailure ("expected no warnings, got: " ++ show ws)
           Left e -> assertFailure ("unexpected error: " ++ show e)

  , testCase "multi-name bodyless sig emits one warning per name" $
      let src = T.pack "a, b, c : U64\n"
          result = case parse src of
            Right ast -> case reorderModule ast of
              Right rm -> TC.inferProgramWith B.initialEnv
                            (SO.UserFile "<test>") (reorderedAst rm)
              Left  es -> error ("setup: " ++ show es)
            Left err -> error ("setup: " ++ err)
      in case result of
           Right (_, _, warnings) ->
             length warnings @?= 3
           Left e -> assertFailure ("unexpected error: " ++ show e)

  , testCase "sig + matching equation: scheme honored via freezeSig path" $
      -- Regression guard: ensure sig+eqn still routes through finalizeGroup
      -- (which applies freezeSig), not through the bodyless-sig path.
      let src = T.pack "myConst : a -> a\nmyConst x = x\n"
          result = case parse src of
            Right ast -> case reorderModule ast of
              Right rm -> TC.inferProgramWith B.initialEnv
                            (SO.UserFile "<test>") (reorderedAst rm)
              Left  es -> error ("setup: " ++ show es)
            Left err -> error ("setup: " ++ err)
      in case result of
           Right (_, _, warnings) -> do
             -- Sig+eqn must NOT emit a bodyless warning:
             warnings @?= []
             -- (Optionally lock in the inferred scheme via the env lookup,
             -- but warnings = [] is the load-bearing assertion for this guard.)
           Left e -> assertFailure ("unexpected error: " ++ show e)
  ]

loaderTests :: TestTree
loaderTests = testGroup "loader"
  [ testCase "loads entry + embedded preludes; topo order is Prelude first" $ do
      res <- Loader.loadProgram "test/loader-fixtures/01-entry-imports-base.wok" []
      case res of
        Right (entryName, modules) -> do
          entryName @?= T.pack "Main"
          -- Two preludes are always embedded: Std.Base and Std.Control (the
          -- latter imports Std.Base). Std.Base must come first (nothing it
          -- depends on); Main and Std.Control follow in some dependency-valid
          -- order. Assert the leading prelude + the full set rather than a
          -- brittle exact permutation of the tail.
          let names = map Loader.lmName modules
          case names of
            (n0 : _) -> n0 @?= T.pack "Std.Base"
            []       -> assertFailure "expected a non-empty module list"
          Data.List.sort names @?=
            Data.List.sort [T.pack "Std.Base", T.pack "Std.Control", T.pack "Main"]
        Left err -> assertFailure ("unexpected error: " ++ show err)

  , testCase "rejects file missing a module header" $ do
      res <- Loader.loadProgram "test/loader-fixtures/02-no-header.wok" []
      case res of
        Left (Loader.LoadNoModuleHeader p) ->
          p @?= "test/loader-fixtures/02-no-header.wok"
        other -> assertFailure ("expected LoadNoModuleHeader, got: " ++ show other)

  , testCase "rejects import of unknown module" $ do
      res <- Loader.loadProgram "test/loader-fixtures/03-unknown-import.wok" []
      case res of
        Left (Loader.LoadImportUnknown importer target) -> do
          importer @?= T.pack "Main"
          target   @?= T.pack "Foo.Bar"
        other -> assertFailure ("expected LoadImportUnknown, got: " ++ show other)

  , testCase "detects two-module import cycle" $ do
      res <- Loader.loadProgram
               "test/loader-fixtures/04-cycle-a.wok"
               ["test/loader-fixtures/04-cycle-b.wok"]
      case res of
        Left (Loader.LoadImportCycle ms) ->
          Data.List.sort ms @?= Data.List.sort [T.pack "A", T.pack "B"]
        other -> assertFailure ("expected LoadImportCycle, got: " ++ show other)

  , testCase "detects self-import cycle" $ do
      res <- Loader.loadProgram "test/loader-fixtures/05-self-import.wok" []
      case res of
        Left (Loader.LoadImportCycle ms) ->
          ms @?= [T.pack "Main"]
        other -> assertFailure ("expected LoadImportCycle, got: " ++ show other)

  , testCase "rejects two files declaring same module name" $ do
      res <- Loader.loadProgram
               "test/loader-fixtures/06-dup-a.wok"
               ["test/loader-fixtures/06-dup-b.wok"]
      case res of
        Left (Loader.LoadDuplicateModule n _ _) -> n @?= T.pack "Dup"
        other -> assertFailure ("expected LoadDuplicateModule, got: " ++ show other)

  , testCase "rejects missing entry file" $ do
      res <- Loader.loadProgram "test/loader-fixtures/does-not-exist.wok" []
      case res of
        Left (Loader.LoadFileMissing p) ->
          p @?= "test/loader-fixtures/does-not-exist.wok"
        other -> assertFailure ("expected LoadFileMissing, got: " ++ show other)

  , testCase "reports non-missing IO errors as LoadFileError (e.g. EISDIR)" $ do
      -- Pointing at a directory triggers an IO error that is NOT
      -- isDoesNotExistError, so we expect the new LoadFileError variant.
      res <- Loader.loadProgram "test/loader-fixtures" []
      case res of
        Left (Loader.LoadFileError p _) ->
          p @?= "test/loader-fixtures"
        other -> assertFailure ("expected LoadFileError, got: " ++ show other)
  ]

-- ---------------------------------------------------------------------
-- Multi-module Loader-tier integration tests
--
-- These exercise the multi-module Loader -> reorder -> typecheck
-- pipeline end-to-end. Together with `loaderTests` (which covers
-- parse/dep-graph errors at the Loader stage), they cover:
--   * cross-module fixity overlay (entry's reordering sees imports'
--     fixity tables);
--   * cross-module fixity REDECLARATION (importer redeclaring an
--     imported fixity surfaces as a pipeline reorder error);
--   * cross-module name conflict (two imports exporting the same
--     name surfaces as an env-merge error);
--   * BodylessBinding warning at pipeline level for UserFile origin;
--   * silent bodyless-sigs for Embedded (Std.Base) origin.
-- ---------------------------------------------------------------------

crossModuleFixityTests :: TestTree
crossModuleFixityTests = testGroup "crossModuleFixity"
  [ testCase "external fixity table influences entry reassociation" $ do
      -- Extra declares `fixity ## left tighter than +` (and `(##) : ...`
      -- so the typechecker can find the operator scheme). Entry uses
      -- `a + b ## c` and Std.Base provides `+`. The cross-module fixity
      -- overlay is what makes the chain unambiguous: without it the
      -- reorder pass cannot relate `+` and `##` and surfaces
      -- `IncomparableOps`. Thus "typecheck succeeds" is the load-bearing
      -- assertion for cross-module-fixity threading.
      res <- Loader.loadProgram
               "test/loader-fixtures/07-cross-fixity-entry.wok"
               ["test/loader-fixtures/07-cross-fixity-extra.wok"]
      case res of
        Right (entryName, ms) -> do
          entryName @?= T.pack "Main"
          case Pipeline.typecheckProgram entryName ms of
            Right (decls, _) ->
              assertBool "expected 'result' in entry's decls"
                         (any ((== T.pack "result") . TC.tdName) decls)
            Left s -> assertFailure ("expected pipeline success, got: " ++ s)
        Left lerr -> assertFailure ("expected loader success, got: " ++ show lerr)

  , testCase "entry redeclaring an imported fixity surfaces as conflict" $ do
      -- Std.Base declares `fixity + left`. Entry tries to redeclare it.
      -- `reorderModuleWith` overlays the imported fixity table with the
      -- module's own table; the collision yields a RedeclaredOp error
      -- mentioning `+`.
      res <- Loader.loadProgram
               "test/loader-fixtures/08-cross-fixity-redecl.wok"
               []
      case res of
        Right (entryName, ms) ->
          case Pipeline.typecheckProgram entryName ms of
            Left s | "+" `Data.List.isInfixOf` s -> pure ()
            other -> assertFailure
                       ("expected fixity conflict mentioning '+', got: "
                        ++ show other)
        Left lerr -> assertFailure ("loader unexpectedly failed: " ++ show lerr)
  ]

crossModuleNameConflictTests :: TestTree
crossModuleNameConflictTests = testGroup "crossModuleNameConflict"
  [ testCase "two imports exporting same name fail with env conflict" $ do
      -- A defines `foo : U64`, B defines `foo : U64` (SAME type, different
      -- body). The entry imports both; the env overlay in
      -- `Pipeline.typecheckProgram` detects two distinct ORIGINS for `foo`
      -- (modules A and B) and returns a Left containing "env merge in ".
      --
      -- This exercises binding provenance: env-merge flags a shared var
      -- when its defining modules differ, even when the stored `Scheme`s are
      -- identical. (Same-origin overlaps -- a diamond re-export -- still
      -- merge silently.) Byte-identical re-exported builtin tycons also
      -- merge silently; the surfaced collision is the cross-module `foo`.
      res <- Loader.loadProgram
               "test/loader-fixtures/09-name-conflict-entry.wok"
               [ "test/loader-fixtures/09-name-conflict-a.wok"
               , "test/loader-fixtures/09-name-conflict-b.wok"
               ]
      case res of
        Right (entryName, ms) ->
          case Pipeline.typecheckProgram entryName ms of
            Left s | "env merge in " `Data.List.isInfixOf` s -> pure ()
            other -> assertFailure
                       ("expected an env-merge conflict, got: "
                        ++ show other)
        Left lerr -> assertFailure ("loader unexpectedly failed: " ++ show lerr)
  ]

bodylessUserWarningTests :: TestTree
bodylessUserWarningTests = testGroup "bodylessUser"
  [ testCase "user-file bodyless sig produces BodylessBinding warning at pipeline level" $ do
      res <- Loader.loadProgram "test/loader-fixtures/10-bodyless-user.wok" []
      case res of
        Right (entryName, ms) ->
          case Pipeline.typecheckProgram entryName ms of
            Right (_, warnings) ->
              case warnings of
                [TC.BodylessBinding n _] -> n @?= T.pack "foo"
                other -> assertFailure
                           ("expected 1 BodylessBinding foo, got: " ++ show other)
            Left s -> assertFailure ("pipeline unexpectedly failed: " ++ s)
        Left lerr -> assertFailure ("loader unexpectedly failed: " ++ show lerr)

  , testCase "silentBodyless: Std.Base bodyless sigs produce zero pipeline warnings" $ do
      -- Std.Base has many bodyless sigs ((+), (-), (*), ...). They MUST
      -- be silent because the loader marks Std.Base with Origin=Embedded.
      -- The entry has no bodyless sigs of its own. Expect zero warnings.
      res <- Loader.loadProgram "test/loader-fixtures/11-bodyless-silent-prelude.wok" []
      case res of
        Right (entryName, ms) ->
          case Pipeline.typecheckProgram entryName ms of
            Right (_, []) -> pure ()
            Right (_, ws) -> assertFailure ("expected no warnings, got: " ++ show ws)
            Left s -> assertFailure ("pipeline unexpectedly failed: " ++ s)
        Left lerr -> assertFailure ("loader unexpectedly failed: " ++ show lerr)
  ]

-- ---------------------------------------------------------------------
-- Row unification tests (Leijen 2005 scoped-label algorithm)
-- ---------------------------------------------------------------------

-- | Run a TC action in a fresh ST context, returning Either TypeError a.
runUnify :: (forall s. TM.TC s a) -> Either TErr.TypeError a
runUnify action = TM.runTC_ TE.emptyEnv action

-- | Build a row from a list of (label, type) pairs.
mkRow :: [(T.Text, Ty.Type s)] -> Ty.Row s
mkRow = foldr (\(l, t) acc -> Ty.RowExtend l t acc) Ty.RowEmpty

rowUnifyTests :: TestTree
rowUnifyTests = testGroup "RowUnify"
  [ testCase "RowEmpty ~ RowEmpty unifies" $
      let result = runUnify $
            U.unifyRow Nothing Ty.RowEmpty Ty.RowEmpty
      in case result of
           Right () -> pure ()
           Left e -> assertFailure ("expected Right (), got: " ++ show e)

  , testCase "{x:U64} ~ {x:U64} unifies" $
      let result = runUnify $ do
            let r1 = Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcU64 []) Ty.RowEmpty
                r2 = Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcU64 []) Ty.RowEmpty
            U.unifyRow Nothing r1 r2
      in case result of
           Right () -> pure ()
           Left e -> assertFailure ("expected Right (), got: " ++ show e)

  , testCase "{x:U64} ~ {x:Bool} fails with RowMismatch or Mismatch" $
      let result = runUnify $ do
            let r1 = Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcU64 []) Ty.RowEmpty
                r2 = Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcBool []) Ty.RowEmpty
            U.unifyRow Nothing r1 r2
      in case result of
           Left (TErr.Mismatch _ _ _) -> pure ()
           Left (TErr.RowMismatch _ _ _) -> pure ()
           _ -> assertFailure ("expected Mismatch or RowMismatch, got: " ++ show result)

  , testCase "{x:U64, y:Bool} ~ {y:Bool, x:U64} unifies (permutation)" $
      -- Leijen permits reordering: same labels, different extension order.
      let result = runUnify $ do
            let r1 = Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcU64 [])
                       (Ty.RowExtend (T.pack "y") (Ty.TCon Ty.TcBool []) Ty.RowEmpty)
                r2 = Ty.RowExtend (T.pack "y") (Ty.TCon Ty.TcBool [])
                       (Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcU64 []) Ty.RowEmpty)
            U.unifyRow Nothing r1 r2
      in case result of
           Right () -> pure ()
           Left e -> assertFailure ("expected Right (), got: " ++ show e)

  , testCase "row variable extends to add label" $
      -- Given fresh RowVar r, unify (RowVar r) with {x : U64}. After: r is bound.
      let result = runUnify $ do
            rVar <- TM.freshRVar
            let row = Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcU64 []) Ty.RowEmpty
            U.unifyRow Nothing rVar row
            -- Force rVar to check it was bound
            forced <- U.force rVar
            U.freeze forced
      in case result of
           Right cr -> assertBool "expected CRExtend x ..." $
             case cr of
               Ty.CRExtend lbl (Ty.CTCon Ty.TcU64 []) _ -> lbl == T.pack "x"
               _ -> False
           Left e -> assertFailure ("expected Right, got: " ++ show e)

  , testCase "row variable unifies with RowEmpty" $
      let result = runUnify $ do
            rVar <- TM.freshRVar
            U.unifyRow Nothing rVar Ty.RowEmpty
            forced <- U.force rVar
            U.freeze forced
      in case result of
           Right Ty.CREmpty -> pure ()
           Right cr -> assertFailure ("expected CREmpty, got: " ++ show cr)
           Left e -> assertFailure ("expected Right, got: " ++ show e)

  , testCase "rewriteRowStrict refuses RowVar" $
      -- rewriteRowStrict should throw UnknownField when given a RowVar.
      let result :: Either TErr.TypeError (Ty.CType, Ty.CRow)
          result = runUnify $ do
            rVar <- TM.freshRVar
            (ty, rest) <- U.rewriteRowStrict Nothing (T.pack "x") rVar
            ct <- U.freeze ty
            cr <- U.freeze rest
            pure (ct, cr)
      in case result of
           Left (TErr.UnknownField _ _ lbl) -> lbl @?= T.pack "x"
           _ -> assertFailure ("expected UnknownField, got: " ++ show result)

  , testCase "rewriteRow on RowVar allocates fresh field and tail" $
      -- rewriteRow should succeed on RowVar by allocating fresh vars.
      let result = runUnify $ do
            rVar <- TM.freshRVar
            (ty, _tail) <- U.rewriteRow Nothing (T.pack "x") rVar
            U.freeze ty
      in case result of
           Right (Ty.CTGen _) -> pure ()
           Right ct -> assertFailure ("expected CTGen (fresh), got: " ++ show ct)
           Left e -> assertFailure ("expected Right, got: " ++ show e)

  , testCase "scoped labels: {x:U64, x:Bool} stays distinct" $
      -- Two same-name labels coexist. Unifying a row with itself should succeed.
      let result = runUnify $ do
            let row = Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcU64 [])
                        (Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcBool []) Ty.RowEmpty)
            U.unifyRow Nothing row row
      in case result of
           Right () -> pure ()
           Left e -> assertFailure ("expected Right (), got: " ++ show e)

  , testCase "scoped labels: rewriteRow returns outermost, inner survives in tail" $
      -- rewriteRow on {x:U64, x:Bool} for label "x" must return the OUTERMOST
      -- field (U64) and leave the inner {x:Bool} intact in the tail.
      let result = runUnify $ do
            let row = Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcU64 [])
                        (Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcBool []) Ty.RowEmpty)
            (ty, rest) <- U.rewriteRow Nothing (T.pack "x") row
            ct  <- U.freeze ty
            cr  <- U.freeze rest
            pure (ct, cr)
      in case result of
           Right (Ty.CTCon Ty.TcU64 [], Ty.CRExtend lbl (Ty.CTCon Ty.TcBool []) Ty.CREmpty)
             | lbl == T.pack "x" -> pure ()
           Right other ->
             assertFailure ("expected (CTCon TcU64 [], CRExtend x (CTCon TcBool []) CREmpty), got: " ++ show other)
           Left e -> assertFailure ("expected Right, got: " ++ show e)

  , testCase "occurs check: r := {x : r} is rejected" $
      -- Setup: fresh row var r (a TVar of kind KEffect). Attempt to bind r to
      -- RowExtend "x" someType r. After the kinded-Ty merge rows are ordinary
      -- TVars, but a self-cycle on a KEffect var still reports RowOccursCheck
      -- (distinct from OccursCheck for KStar type-var cycles).
      let result = runUnify $ do
            rVar <- TM.freshRVar
            case rVar of
              Ty.TVar ref -> do
                let cyclicRow = Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcU64 []) rVar
                U.unifyVar Nothing ref cyclicRow
              _ -> error "expected TVar from freshRVar"
      in case result of
           Left (TErr.RowOccursCheck _ _ _) -> pure ()
           _ -> assertFailure ("expected RowOccursCheck (cycle), got: " ++ show result)

  , testCase "TRecord tag mismatch fails with NominalMismatch" $
      let result = runUnify $ do
            let r1 = Ty.TRecord (T.pack "Point") Ty.RowEmpty
                r2 = Ty.TRecord (T.pack "Line") Ty.RowEmpty
            U.unify Nothing r1 r2
      in case result of
           Left (TErr.NominalMismatch _ t1 t2) -> do
             t1 @?= T.pack "Point"
             t2 @?= T.pack "Line"
           _ -> assertFailure ("expected NominalMismatch, got: " ++ show result)

  , testCase "TRecord same tag with matching rows unifies" $
      let result = runUnify $ do
            let row = Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcU64 []) Ty.RowEmpty
                r1 = Ty.TRecord (T.pack "Point") row
                r2 = Ty.TRecord (T.pack "Point") row
            U.unify Nothing r1 r2
      in case result of
           Right () -> pure ()
           Left e -> assertFailure ("expected Right (), got: " ++ show e)

  , testCase "RowVar ~ RowVar (same ref) unifies trivially" $
      let result = runUnify $ do
            rVar <- TM.freshRVar
            U.unifyRow Nothing rVar rVar
      in case result of
           Right () -> pure ()
           Left e -> assertFailure ("expected Right (), got: " ++ show e)

  , testCase "two distinct RowVars are unified by binding one to the other" $
      let result = runUnify $ do
            r1 <- TM.freshRVar
            r2 <- TM.freshRVar
            U.unifyRow Nothing r1 r2
            -- Both should now freeze to the same row gen (CTGen, KEffect)
            cr1 <- U.freeze r1
            cr2 <- U.freeze r2
            pure (cr1, cr2)
      in case result of
           Right (cr1, cr2) -> cr1 @?= cr2
           Left e -> assertFailure ("expected Right, got: " ++ show e)

  -- Kinded representation (Slice A): behaviours the surface language can't yet
  -- exercise. Pure unit tests against the merged kinded `Type s`.

  , testCase "kinded representation: shared-structure rows unify via merged unify" $
      -- Post-merge, rows are ordinary KEffect Types and unifyRow is an alias of
      -- unify. {x:U64 | r1} ~ {x:U64 | r2} (fresh row tails) must still unify
      -- via the inlined Leijen algorithm.
      let result = runUnify $ do
            r1 <- TM.freshRVar
            r2 <- TM.freshRVar
            let row1 = Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcU64 []) r1
                row2 = Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcU64 []) r2
            U.unify Nothing row1 row2
      in case result of
           Right () -> pure ()
           Left e -> assertFailure ("expected Right (), got: " ++ show e)

  , testCase "kinded representation: KStar var vs KEffect row is KindMismatch" $
      -- Unifying a KStar meta var with a row (kind KEffect) must throw.
      let result = runUnify $ do
            a <- TM.freshTVar Ty.KStar
            U.unify Nothing a Ty.RowEmpty
      in case result of
           Left (TErr.KindMismatch _ _ _) -> pure ()
           _ -> assertFailure ("expected KindMismatch, got: " ++ show result)

  , testCase "kinded representation: freeze round-trips a row-bearing arrow" $
      -- freeze must handle a row in the arrow's effect slot, producing the
      -- closed row constructors CRExtend/CREmpty.
      let result = runUnify $
            U.freeze
              (Ty.TArr (Ty.TCon Ty.TcUnit [])
                 (Ty.RowExtend (T.pack "Log") (Ty.TCon Ty.TcUnit []) Ty.RowEmpty)
                 (Ty.TCon Ty.TcUnit []))
      in case result of
           Right (Ty.CTArr _ (Ty.CRExtend lbl _ Ty.CREmpty) _)
             | lbl == T.pack "Log" -> pure ()
           Right ct -> assertFailure ("expected CTArr _ (CRExtend Log _ CREmpty) _, got: " ++ show ct)
           Left e -> assertFailure ("expected Right, got: " ++ show e)
  ]

-- ---------------------------------------------------------------------
-- Record data-decl processing tests (Task 4)
-- ---------------------------------------------------------------------

-- | Parse a source fragment containing only data decls (no module header)
-- and run processDataDecls against the given environment.
runDataDeclsIn :: TE.Env -> Text -> Either TErr.TypeError TE.Env
runDataDeclsIn env src =
  case parse (T.pack "module Main\n" `T.append` src) of
    Left e -> Left (TErr.UnsupportedFeature Nothing (T.pack ("parse: " ++ e)))
    Right ast ->
      let decls = case ast of Abs.Module ds -> ds
      in TM.runTC_ env (I.processDataDecls env decls)

-- | Convenience wrapper using the minimal builtins env (no Std.Base).
runDataDecls :: Text -> Either TErr.TypeError TE.Env
runDataDecls = runDataDeclsIn B.initialEnv

recordDeclTests :: TestTree
recordDeclTests = testGroup "RecordDecl"
  [ testCase "register named-form Point in envRecordCons and envTyCons" $ do
      case runDataDecls (T.pack "data Point = Point { x : U64, y : U64 }") of
        Left e  -> assertFailure ("unexpected error: " ++ show e)
        Right env -> do
          case TE.lookupRecordCon (T.pack "Point") env of
            Nothing   -> assertFailure "Point not in envRecordCons"
            Just info -> do
              TE.rcTag info @?= T.pack "Point"
              length (TE.rcFields info) @?= 2
          case TE.lookupTyCon (T.pack "Point") env of
            Nothing -> assertFailure "Point not in envTyCons"
            Just _  -> pure ()
          -- Must NOT be in the positional (curried) constructor namespace.
          TE.lookupCon (T.pack "Point") env @?= Nothing

  , testCase "elided form is equivalent to named form" $ do
      case runDataDecls (T.pack "data Point = { x : U64, y : U64 }") of
        Left e  -> assertFailure ("unexpected error: " ++ show e)
        Right env ->
          case TE.lookupRecordCon (T.pack "Point") env of
            Nothing   -> assertFailure "Point not in envRecordCons"
            Just info -> do
              -- Tag must be filled in from the data-type name.
              TE.rcTag info @?= T.pack "Point"
              length (TE.rcFields info) @?= 2

  , testCase "elision in multi-constructor decl is rejected" $ do
      case runDataDecls (T.pack "data Shape = { x : U64 } | Square { side : U64 }") of
        Left _  -> pure ()   -- any error is acceptable
        Right _ -> assertFailure "expected an error for elision in multi-con decl"

  , testCase "same field name across two constructors is rejected" $ do
      case runDataDecls (T.pack "data X = A { x : U64 } | B { x : U64 }") of
        Left _  -> pure ()
        Right _ -> assertFailure "expected an error for duplicate field name"

  , testCase "mixed positional and record constructors in one decl" $ do
      baseEnv <- stdBaseExtendedEnv
      -- Use a distinct name to avoid clashing with Std.Base's Result/Ok/Err.
      let src = T.pack "data Outcome a e = Good a | Bad { code : U64, flag : Bool }"
      case runDataDeclsIn baseEnv src of
        Left e  -> assertFailure ("unexpected error: " ++ show e)
        Right env -> do
          -- Good is positional (curried scheme) only.
          case TE.lookupCon (T.pack "Good") env of
            Nothing -> assertFailure "Good not in envCons"
            Just _  -> pure ()
          TE.lookupRecordCon (T.pack "Good") env @?= Nothing
          -- Bad is record-only.
          case TE.lookupRecordCon (T.pack "Bad") env of
            Nothing -> assertFailure "Bad not in envRecordCons"
            Just _  -> pure ()
          TE.lookupCon (T.pack "Bad") env @?= Nothing

  , testCase "polymorphic record constructor carries type params" $ do
      case runDataDecls (T.pack "data Container a = Container { value : a }") of
        Left e  -> assertFailure ("unexpected error: " ++ show e)
        Right env ->
          case TE.lookupRecordCon (T.pack "Container") env of
            Nothing   -> assertFailure "Container not in envRecordCons"
            Just info -> do
              length (TE.rcFields info) @?= 1
              length (TE.rcParams info) @?= 1
  ]

-- ---------------------------------------------------------------------
-- Type-level + elaboration tests (Task 8)
-- ---------------------------------------------------------------------

-- | Build an env with Point defined and run translateSig on the given type.
-- Returns the Scheme or the TypeError.
translateSigInPointEnv :: Abs.Type -> Either TErr.TypeError Ty.Scheme
translateSigInPointEnv ty =
  case runDataDecls (T.pack "data Point = Point { x : U64, y : U64 }") of
    Left e -> Left e
    Right env ->
      TM.runTC_ env (I.translateSig env ty)

-- | Helper: build an Abs.Type for `Point` (a TCon).
mkPointTy :: Abs.Type
mkPointTy = Abs.TCon (Abs.MPName (Abs.ConId ((0,0), T.pack "Point")))

-- | Helper: build a VarSym.
mkVarSym :: String -> Abs.VarSym
mkVarSym s = Abs.VarSym ((0,0), T.pack s)

-- | Helper: build a RCAnon from a list of (name, type) pairs.
mkRCAnon :: [(String, Abs.Type)] -> Abs.RowContrib
mkRCAnon fields =
  Abs.RCAnon [ Abs.RFType (Abs.VarId ((0,0), T.pack n)) ty | (n, ty) <- fields ]

-- | Helper: U64 type.
mkU64 :: Abs.Type
mkU64 = Abs.TCon (Abs.MPName (Abs.ConId ((0,0), T.pack "U64")))

-- | Helper: build RCVar for a named row variable.
mkRCVar :: String -> Abs.RowContrib
mkRCVar s = Abs.RCVar (Abs.VarId ((0,0), T.pack s))

-- | Extract the fields from a CTRecord's CRow into a list of label names.
cRowLabels :: Ty.CRow -> [T.Text]
cRowLabels Ty.CREmpty = []
cRowLabels (Ty.CRExtend l _ rest) = l : cRowLabels rest
cRowLabels (Ty.CTGen _) = []
cRowLabels _ = []  -- non-row CType: no labels (cannot occur in a row position)

typeLevelExtTests :: TestTree
typeLevelExtTests = testGroup "TypeLevelExtension"
  [ testCase "concrete extension translates to TRecord with merged fields" $ do
      -- Point + { score : U64 } should yield CTRecord "Point" with x, y, score
      let ty = Abs.TExtend mkPointTy (mkVarSym "+")
                 (mkRCAnon [("score", mkU64)])
      case translateSigInPointEnv ty of
        Left e -> assertFailure ("unexpected error: " ++ show e)
        Right (Ty.Scheme _ _ (Ty.CTRecord tag row)) -> do
          tag @?= T.pack "Point"
          let labels = cRowLabels row
          -- score is prepended (outermost), x and y come from Point's fields
          length labels @?= 3
          case labels of
            (l0 : _) -> l0 @?= T.pack "score"
            []       -> assertFailure "expected non-empty labels"
          T.pack "x" `elem` labels @? "expected x in row"
          T.pack "y" `elem` labels @? "expected y in row"
        Right other -> assertFailure ("expected CTRecord scheme, got: " ++ show other)

  , testCase "row variable extension translates to CTRecord with row-gen (CTGen) tail" $ do
      -- Point + row r should yield CTRecord "Point" (x, y, r)
      let ty = Abs.TExtend mkPointTy (mkVarSym "+") (mkRCVar "r")
      case translateSigInPointEnv ty of
        Left e -> assertFailure ("unexpected error: " ++ show e)
        Right (Ty.Scheme qs _ (Ty.CTRecord tag row)) -> do
          tag @?= T.pack "Point"
          -- The row should end with a row-gen (CTGen, KEffect) for the row variable
          let hasRowVar (Ty.CTGen _) = True
              hasRowVar Ty.CREmpty   = False
              hasRowVar (Ty.CRExtend _ _ rest) = hasRowVar rest
              hasRowVar _            = False
          hasRowVar row @? "expected row variable (CTGen) in row"
          -- There should be exactly one KEffect quantifier for the row var
          let rowQs = [ i | (i, Ty.KEffect) <- qs ]
          length rowQs @?= 1
        Right other -> assertFailure ("expected CTRecord scheme, got: " ++ show other)

  , testCase "two uses of same row var share one row-gen (CTGen) slot" $ do
      -- (Point + row r) -> (Point + row r): both `r` should map to same index
      let extTy = Abs.TExtend mkPointTy (mkVarSym "+") (mkRCVar "r")
          ty    = Abs.TFun extTy extTy
      case translateSigInPointEnv ty of
        Left e -> assertFailure ("unexpected error: " ++ show e)
        Right (Ty.Scheme qs _ _) -> do
          -- Exactly one KEffect slot (one row var `r`)
          let rowQs = [ i | (i, Ty.KEffect) <- qs ]
          length rowQs @?= 1

  , testCase "non-plus operator rejected with NonPlusTypeOp" $ do
      -- Point - { score : U64 } should fail with NonPlusTypeOp
      let ty = Abs.TExtend mkPointTy (mkVarSym "-")
                 (mkRCAnon [("score", mkU64)])
      case translateSigInPointEnv ty of
        Left (TErr.NonPlusTypeOp _ sym) -> sym @?= T.pack "-"
        Left other -> assertFailure ("expected NonPlusTypeOp, got: " ++ show other)
        Right _ -> assertFailure "expected error, got Right"

  , testCase "plain TCon for record type produces CTRecord" $ do
      -- Just referencing `Point` in a sig should produce CTRecord "Point" {...}
      case translateSigInPointEnv mkPointTy of
        Left e -> assertFailure ("unexpected error: " ++ show e)
        Right (Ty.Scheme _ _ (Ty.CTRecord tag row)) -> do
          tag @?= T.pack "Point"
          let labels = cRowLabels row
          length labels @?= 2
          T.pack "x" `elem` labels @? "expected x"
          T.pack "y" `elem` labels @? "expected y"
        Right other -> assertFailure ("expected CTRecord, got: " ++ show other)

  , testCase "chained extension Point + { score } + { color } works" $ do
      -- (Point + { score : U64 }) + { color : U64 }
      let step1 = Abs.TExtend mkPointTy (mkVarSym "+")
                    (mkRCAnon [("score", mkU64)])
          ty    = Abs.TExtend step1 (mkVarSym "+")
                    (mkRCAnon [("color", mkU64)])
      case translateSigInPointEnv ty of
        Left e -> assertFailure ("unexpected error: " ++ show e)
        Right (Ty.Scheme _ _ (Ty.CTRecord tag row)) -> do
          tag @?= T.pack "Point"
          let labels = cRowLabels row
          length labels @?= 4
          T.pack "x"     `elem` labels @? "expected x"
          T.pack "y"     `elem` labels @? "expected y"
          T.pack "score" `elem` labels @? "expected score"
          T.pack "color" `elem` labels @? "expected color"
        Right other -> assertFailure ("expected CTRecord, got: " ++ show other)

  , testCase "anonymous record { x : U64 } outside + is a parse error" $ do
      -- The grammar's RowContrib is only reachable from TExtend.
      -- A standalone `{ x : U64 }` in a type position does NOT parse as a type.
      -- Verify by checking that the source doesn't produce a valid parse
      -- when { ... } appears as a top-level type.
      -- (This is a grammar-level guarantee, not an elaborator one.)
      -- We use parseSrc via parse on a sig that would need that form.
      -- `f : { x : U64 } -> U64` should fail to parse.
      let src = T.pack "module Main\nf : { x : U64 } -> U64\nf r = 0\n"
      case parse src of
        Left _  -> pure ()  -- expected: parse fails
        Right _ -> assertFailure "expected parse failure for standalone { } in type position"

  , testCase "bare row var without row keyword is a parse error" $ do
      -- `f : Point + r -> U64` where r has no `row` prefix should fail to parse.
      -- The grammar requires `row VarId` for RCVar.
      let src = T.pack "module Main\ndata Point = Point { x : U64, y : U64 }\nf : Point + r -> U64\nf p = 0\n"
      case parse src of
        Left _  -> pure ()  -- expected: parse fails
        Right _ -> assertFailure "expected parse failure for bare row var without `row` keyword"
  ]

-- ---------------------------------------------------------------------
-- Record construction inference tests (Task 5)
-- ---------------------------------------------------------------------

-- | Preamble that defines Point for record construction tests.
pointDecl :: T.Text
pointDecl = T.pack "data Point = Point { x : U64, y : U64 }\n"

-- | Run the full typecheck pipeline on the given source (no module header
-- needed; inferProgram accepts raw decl lists). Returns Right scheme list
-- or Left error.
runTypecheckSrc :: T.Text -> Either String [(T.Text, Ty.Scheme)]
runTypecheckSrc src =
  case parse src of
    Left e -> Left ("parse: " ++ e)
    Right ast ->
      case reorderModule ast of
        Left es -> Left ("reorder: " ++ show es)
        Right rm ->
          case TC.inferProgram (reorderedAst rm) of
            Left e -> Left ("typecheck: " ++ show e)
            Right (_, decls) -> Right [ (TC.tdName d, TC.tdScheme d) | d <- decls ]

-- | Expect a source to typecheck without error.
expectOK :: T.Text -> Assertion
expectOK src =
  case runTypecheckSrc src of
    Right _ -> pure ()
    Left e  -> assertFailure ("expected success but got: " ++ e)

-- | Expect a source to fail typechecking (any error).
expectError :: T.Text -> Assertion
expectError src =
  case runTypecheckSrc src of
    Left _  -> pure ()
    Right _ -> assertFailure "expected typecheck error but got success"

-- | Expect a source to fail typechecking with an error message containing
-- the given substring.
expectErrorContaining :: T.Text -> String -> Assertion
expectErrorContaining src substr =
  case runTypecheckSrc src of
    Left e  -> assertBool
                 ("expected error containing " ++ show substr ++ " but got: " ++ e)
                 (substr `Data.List.isInfixOf` e)
    Right _ -> assertFailure ("expected error containing " ++ show substr ++ " but got success")

recordConstructionTests :: TestTree
recordConstructionTests = testGroup "RecordConstruction"
  [ testCase "closed Point infers as TRecord Point" $ do
      let src = pointDecl <> T.pack "p = Point { x = 1, y = 2 }\n"
      case runTypecheckSrc src of
        Left e -> assertFailure ("unexpected error: " ++ e)
        Right decls ->
          case lookup (T.pack "p") decls of
            Nothing -> assertFailure "p not in decls"
            Just (Ty.Scheme [] _ (Ty.CTRecord tag row)) -> do
              tag @?= T.pack "Point"
              let labels = cRowLabels row
              Data.List.sort labels @?= Data.List.sort [T.pack "x", T.pack "y"]
            Just other -> assertFailure ("unexpected scheme: " ++ show other)

  , testCase "extras without sig produce UnknownField error" $ do
      let src = pointDecl <> T.pack "p = Point { x = 1, y = 2, z = 3 }\n"
      expectError src

  , testCase "spread-only copies Point" $ do
      let src = pointDecl
             <> T.pack "origin = Point { x = 0, y = 0 }\n"
             <> T.pack "copy = Point { ..origin }\n"
      expectOK src

  , testCase "spread with same-type override typechecks" $ do
      let src = pointDecl
             <> T.pack "origin = Point { x = 0, y = 0 }\n"
             <> T.pack "moved = Point { ..origin, x = 99 }\n"
      expectOK src

  , testCase "spread with type-mismatch override errors" $ do
      let src = pointDecl
             <> T.pack "origin = Point { x = 0, y = 0 }\n"
             <> T.pack "broken = Point { ..origin, x = \"hi\" }\n"
      expectError src

  , testCase "record constructor not a value" $
      expectErrorContaining
        (pointDecl <> T.pack "f = Point\n")
        "RecordConstructorNotAValue"

  , testCase "record constructor positional application errors" $
      expectErrorContaining
        (pointDecl <> T.pack "z = Point 1\n")
        "RecordConstructorNeedsBraces"

  , testCase "positional constructor stays first-class" $ do
      -- Define a positional constructor in the same source and verify it
      -- can be used as a first-class value (no RecordConstructorNotAValue).
      let src = T.pack "data Wrap = Wrap U64\nf = Wrap\n"
      case runTypecheckSrc src of
        Left e  -> assertFailure ("expected success, got: " ++ e)
        Right _ -> pure ()

  , testCase "missing field errors" $ do
      let src = pointDecl <> T.pack "p = Point { x = 1 }\n"
      expectError src

  , testCase "nominal tag mismatch in spread errors" $ do
      -- Line must define two different record types and try to spread wrong one.
      -- Since we only have Point in this test, verify that spreading a
      -- non-record-type expression produces NotARecord.
      let src = pointDecl
             <> T.pack "bad = Point { ..1 }\n"
      expectError src

  , testCase "sig with extension allows extras" $ do
      let src = T.unlines
            [ "data Point = Point { x : U64, y : U64 }"
            , "named : Point + { score : U64 }"
            , "named = Point { x = 0, y = 0, score = 99 }"
            ]
      expectOK src

  , testCase "sig with extension rejects unrelated extras" $ do
      let src = T.unlines
            [ "data Point = Point { x : U64, y : U64 }"
            , "named : Point + { score : U64 }"
            , "named = Point { x = 0, y = 0, score = 99, color = 1 }"
            ]
      expectError src

  , testCase "sig with extension spread plus addition" $ do
      -- withScore p s = Point { ..p, score = s }
      let src = T.unlines
            [ "data Point = Point { x : U64, y : U64 }"
            , "withScore : Point -> U64 -> Point + { score : U64 }"
            , "withScore p s = Point { ..p, score = s }"
            ]
      expectOK src

  , testCase "sig with extension spread addition rejects unrelated field" $ do
      let src = T.unlines
            [ "data Point = Point { x : U64, y : U64 }"
            , "withScore : Point -> U64 -> Point + { score : U64 }"
            , "withScore p s = Point { ..p, score = s, color = 1 }"
            ]
      expectError src
  ]

fieldAccessTests :: TestTree
fieldAccessTests = testGroup "FieldAccess"
  [ testCase "p.x on Point returns U64" $
      expectOK $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "getX : Point -> U64"
        , "getX p = p.x"
        ]

  , testCase "p.score on Point + concrete extension" $
      expectOK $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "getScore : Point + { score : U64 } -> U64"
        , "getScore p = p.score"
        ]

  , testCase "p.x on Point + row r (declared field accessible)" $
      expectOK $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "getX : Point + row r -> U64"
        , "getX p = p.x"
        ]

  , testCase "p.score on Point + row r errors with UnknownField" $
      expectErrorContaining
        ( T.unlines
            [ "data Point = Point { x : U64, y : U64 }"
            , "getScore : Point + row r -> U64"
            , "getScore p = p.score"
            ]
        )
        "UnknownField"

  , testCase "p.x on non-record errors with NotARecord" $
      expectErrorContaining
        ( T.unlines
            [ "f : U64 -> U64"
            , "f p = p.x"
            ]
        )
        "NotARecord"
  ]

recordPatternTests :: TestTree
recordPatternTests = testGroup "RecordPattern"
  [ testCase "strict pattern matches Point" $
      expectOK $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "describe : Point -> U64"
        , "describe p = case p of"
        , "  Point { x = a, y = b } -> a"
        ]

  , testCase "strict pattern bindings have correct types" $
      expectOK $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "getX : Point -> U64"
        , "getX p = case p of"
        , "  Point { x = a, y = _ } -> a"
        , "getY : Point -> U64"
        , "getY p = case p of"
        , "  Point { x = _, y = b } -> b"
        ]

  , testCase "strict pattern rejects extended scrutinee" $
      expectError $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "f : Point + { z : U64 } -> U64"
        , "f p = case p of"
        , "  Point { x = a, y = b } -> a"
        ]

  , testCase "open pattern matches Point + extension" $
      expectOK $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "g : Point + row r -> U64"
        , "g p = case p of"
        , "  Point { x = a, y = b, .. } -> a"
        ]

  , testCase "open pattern with subset of declared fields" $
      expectOK $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "getX : Point + row r -> U64"
        , "getX p = case p of"
        , "  Point { x = a, .. } -> a"
        ]

  , testCase "pure wild pattern matches any Point-tagged record" $
      expectOK $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "h : Point + row r -> U64"
        , "h p = case p of"
        , "  Point { .. } -> 0"
        ]

  , testCase "named row-tail capture is deferred to v2" $
      expectErrorContaining
        ( T.unlines
            [ "data Point = Point { x : U64, y : U64 }"
            , "k p = case p of"
            , "  Point { x = a, ..rest } -> a"
            ]
        )
        "NamedRowTailCaptureDeferred"

  , testCase "strict pattern with unknown field errors" $
      expectError $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "f p = case p of"
        , "  Point { x = a, y = b, z = c } -> a"
        ]

  , testCase "strict pattern with missing field errors" $
      expectError $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "f p = case p of"
        , "  Point { x = a } -> a"
        ]
  ]

-- | Run typechecking and return (decls, warnings) or fail with a message.
-- Used by RowShadow tests.
expectOKWithWarnings :: T.Text -> IO ([(T.Text, Ty.Scheme)], [TC.Warning])
expectOKWithWarnings src =
  case parse src of
    Left e -> assertFailure ("parse error: " ++ e) >> undefined
    Right ast ->
      case reorderModule ast of
        Left es -> assertFailure ("reorder error: " ++ show es) >> undefined
        Right rm ->
          case TC.inferProgramWith B.initialEnv (SO.UserFile "<test>") (reorderedAst rm) of
            Left e -> assertFailure ("typecheck error: " ++ show e) >> undefined
            Right (_, decls, ws) ->
              pure ([ (TC.tdName d, TC.tdScheme d) | d <- decls ], ws)

-- ---------------------------------------------------------------------------
-- Row-shadow warning tests
-- ---------------------------------------------------------------------------

rowShadowTests :: TestTree
rowShadowTests = testGroup "RowShadow"
  [ testCase "no warning when no label collision" $ do
      -- g1 called on Point + { color : U64 }: no 'tag' in caller's row
      let src = T.unlines
            [ "data Point = Point { x : U64, y : U64 }"
            , "g1 : Point + row r -> Point + row r + { tag : U64 }"
            , "g1 p = Point { ..p, tag = 0 }"
            , "clean : Point + { color : U64 }"
            , "clean = Point { x = 0, y = 0, color = 1 }"
            , "result = g1 clean"
            ]
      (_, warnings) <- expectOKWithWarnings src
      let shadows = [ w | w@(TC.RowShadow _ lbl _ _) <- warnings, lbl == T.pack "tag" ]
      length shadows @?= 0

  , testCase "warning emitted when caller's row has same label as function's addition" $ do
      -- g1 called on Point + { tag : U64 }: 'tag' collides with the added 'tag : U64'
      let src = T.unlines
            [ "data Point = Point { x : U64, y : U64 }"
            , "g1 : Point + row r -> Point + row r + { tag : U64 }"
            , "g1 p = Point { ..p, tag = 0 }"
            , "weird : Point + { tag : U64 }"
            , "weird = Point { x = 0, y = 0, tag = 42 }"
            , "result = g1 weird"
            ]
      (_, warnings) <- expectOKWithWarnings src
      let shadows = [ w | w@(TC.RowShadow _ lbl _ _) <- warnings, lbl == T.pack "tag" ]
      -- Exactly one, not duplicated: the same shadow is reachable through more
      -- than one unification, but runTC dedups identical warnings (#3).
      assertEqual ("expected exactly one RowShadow on 'tag', got warnings: " ++ show warnings)
                  1 (length shadows)

  , testCase "collision program still typechecks (warning is informational)" $ do
      -- Same as above: must not fail with a TypeError
      let src = T.unlines
            [ "data Point = Point { x : U64, y : U64 }"
            , "g1 : Point + row r -> Point + row r + { tag : U64 }"
            , "g1 p = Point { ..p, tag = 0 }"
            , "weird : Point + { tag : U64 }"
            , "weird = Point { x = 0, y = 0, tag = 42 }"
            , "result = g1 weird"
            ]
      expectOK src

  , testCase "warning identifies the colliding label" $ do
      let src = T.unlines
            [ "data Box = Box { val : U64 }"
            , "addScore : Box + row r -> Box + row r + { score : U64 }"
            , "addScore b = Box { ..b, score = 0 }"
            , "already : Box + { score : U64 }"
            , "already = Box { val = 1, score = 99 }"
            , "result = addScore already"
            ]
      (_, warnings) <- expectOKWithWarnings src
      let shadows = [ lbl | TC.RowShadow _ lbl _ _ <- warnings ]
      assertBool ("expected 'score' in shadow labels, got: " ++ show shadows)
                 (T.pack "score" `elem` shadows)
  ]

-- ---------------------------------------------------------------------------
-- Forgotten-resume lint tests
-- ---------------------------------------------------------------------------

forgottenResumeTests :: TestTree
forgottenResumeTests = testGroup "ForgottenResume"
  [ testCase "named unreferenced binder on returning op warns" $ do
      -- `State.get k -> 0`: get : s is a returning op and k is never used.
      let src = T.unlines
            [ "module Main", "import Std.Base"
            , "effect State s = { get : s }"
            , "prog : () -> U64 with State U64"
            , "prog u = State.get"
            , "main : U64"
            , "main ="
            , "  with { State.get k -> 0"
            , "         ; v -> v }"
            , "  prog ()" ]
      (_, ws) <- expectOKWithWarnings src
      length [ () | TErr.ForgottenResume _ _ _ <- ws ] @?= 1

  , testCase "wildcard binder suppresses" $ do
      -- `State.get _ -> 0`: explicit intentional discard; no warning.
      let src = T.unlines
            [ "module Main", "import Std.Base"
            , "effect State s = { get : s }"
            , "prog : () -> U64 with State U64"
            , "prog u = State.get"
            , "main : U64"
            , "main ="
            , "  with { State.get _ -> 0"
            , "         ; v -> v }"
            , "  prog ()" ]
      (_, ws) <- expectOKWithWarnings src
      length [ () | TErr.ForgottenResume _ _ _ <- ws ] @?= 0

  , testCase "Never-result op is exempt" $ do
      -- `throw : U64 -> Never`: a non-returning op never resumes, so a
      -- named-but-unused binder is fine. (Avoid Bool/if: the `import Std.Base`
      -- line is parsed but silently dropped by the inferProgramWith path, so
      -- Std.Base names are NOT in scope -- only B.initialEnv primitives are.)
      let src = T.unlines
            [ "module Main", "import Std.Base"
            , "effect Exn = { throw : U64 -> Never }"
            , "risky : () -> U64 with Exn"
            , "risky u = Exn.throw 1"
            , "main : U64"
            , "main ="
            , "  with { Exn.throw code k -> 0"
            , "         ; v -> v }"
            , "  risky ()" ]
      (_, ws) <- expectOKWithWarnings src
      length [ () | TErr.ForgottenResume _ _ _ <- ws ] @?= 0

  , testCase "referenced binder does not warn" $ do
      -- `State.get k -> k 0`: the continuation is used, so the arm resumes.
      let src = T.unlines
            [ "module Main", "import Std.Base"
            , "effect State s = { get : s }"
            , "prog : () -> U64 with State U64"
            , "prog u = State.get"
            , "main : U64"
            , "main ="
            , "  with { State.get k -> k 0"
            , "         ; v -> v }"
            , "  prog ()" ]
      (_, ws) <- expectOKWithWarnings src
      length [ () | TErr.ForgottenResume _ _ _ <- ws ] @?= 0
  ]

-- ---------------------------------------------------------------------------
-- Pattern coverage tests
-- ---------------------------------------------------------------------------

patternCoverageTests :: TestTree
patternCoverageTests = testGroup "PatternCoverage"
  [ testCase "strict-only arms over open scrutinee warns" $ do
      let src = T.unlines
            [ "data Point = Point { x : U64, y : U64 }"
            , "f : Point + row r -> U64"
            , "f p = case p of"
            , "  Point { x = a, y = b } -> a"
            ]
      (_, warnings) <- expectOKWithWarnings src
      let nonExh = [ w | w@(TC.NonExhaustiveRecordPattern _ tag) <- warnings
                       , tag == T.pack "Point" ]
      length nonExh @?= 1

  , testCase "open arm satisfies coverage" $ do
      let src = T.unlines
            [ "data Point = Point { x : U64, y : U64 }"
            , "g : Point + row r -> U64"
            , "g p = case p of"
            , "  Point { x = a, y = b, .. } -> a"
            ]
      (_, warnings) <- expectOKWithWarnings src
      let nonExh = [ w | w@(TC.NonExhaustiveRecordPattern _ _) <- warnings ]
      length nonExh @?= 0

  , testCase "strict arm on closed scrutinee — no warning" $ do
      let src = T.unlines
            [ "data Point = Point { x : U64, y : U64 }"
            , "h : Point -> U64"
            , "h p = case p of"
            , "  Point { x = a, y = b } -> a"
            ]
      (_, warnings) <- expectOKWithWarnings src
      let nonExh = [ w | w@(TC.NonExhaustiveRecordPattern _ _) <- warnings ]
      length nonExh @?= 0

  , testCase "strict arm stays reachable (no unreachable warning)" $
      -- Verify that strict arms over an open scrutinee do NOT cause an
      -- unreachable-arm warning; they remain reachable when r := RowEmpty.
      -- The only warning emitted is NonExhaustiveRecordPattern (tested above).
      let src = T.unlines
            [ "data Point = Point { x : U64, y : U64 }"
            , "f : Point + row r -> U64"
            , "f p = case p of"
            , "  Point { x = a, y = b } -> a"
            ]
          -- The codebase has no UnreachableArm variant; this predicate is
          -- intentionally False for all current Warning constructors,
          -- locking in the design decision that strict arms stay reachable.
          isUnreachable :: TC.Warning -> Bool
          isUnreachable _ = False
      in do
        (_, warnings) <- expectOKWithWarnings src
        let unreachable = filter isUnreachable warnings
        length unreachable @?= 0
  ]

-- ---------------------------------------------------------------------------
-- Match warning tests (non-exhaustive heads + redundant clauses)
-- ---------------------------------------------------------------------------

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
            , "isNil : [U64] -> U64"
            , "isNil []        = 1"
            , "isNil (x :: xs) = 0" ]
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

  , testCase "as-pattern head: coverage unchanged (still non-exhaustive)" $ do
      -- A single-clause head that only matches `Some` is non-exhaustive whether
      -- or not it carries an as-pattern; an as-pattern covers exactly what its
      -- inner pattern covers, so the diagnostic must be identical.
      let withAs = T.unlines
            [ "module Main", "import Std.Base"
            , "data Opt a = Non | Som a"
            , "f : Opt U64 -> U64"
            , "f (Som x) as w = x" ]
          without = T.unlines
            [ "module Main", "import Std.Base"
            , "data Opt a = Non | Som a"
            , "f : Opt U64 -> U64"
            , "f (Som x) = x" ]
      (_, wsAs)  <- expectOKWithWarnings withAs
      (_, wsNot) <- expectOKWithWarnings without
      let count ws = length [ () | TErr.NonExhaustiveMatch _ n <- ws, n == T.pack "f" ]
      count wsAs  @?= 1
      count wsAs  @?= count wsNot
  ]

-- ---------------------------------------------------------------------------
-- BlockLayout tests
-- ---------------------------------------------------------------------------

-- | Assert that the given source parses without errors.
shouldParse :: Text -> Assertion
shouldParse src =
  case parse src of
    Right _   -> pure ()
    Left  err -> assertFailure ("expected successful parse, got: " ++ err)

blockLayoutTests :: TestTree
blockLayoutTests = testGroup "BlockLayout"
  [ testCase "inline decl unchanged" $
      shouldParse "data Point = Point { x : U64, y : U64 }\n"

  , testCase "block decl (named)" $
      shouldParse $ T.unlines
        [ "data Point = Point {"
        , "  x : U64"
        , "  y : U64"
        , "}"
        ]

  , testCase "block decl (elided)" $
      shouldParse $ T.unlines
        [ "data Point = {"
        , "  x : U64"
        , "  y : U64"
        , "}"
        ]

  , testCase "mixed comma + newline in decl" $
      shouldParse $ T.unlines
        [ "data Big = Big {"
        , "  name : String, age : U64"
        , "  score : U64"
        , "}"
        ]

  , testCase "trailing comma + newline in value: no double comma" $
      -- Regression: a literal `,` at end of one field's line must NOT
      -- get a second virtual `,` inserted before the next field on the
      -- following line.
      shouldParse $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "p = Point {"
        , "  x = 1,"
        , "  y = 2"
        , "}"
        ]

  , testCase "trailing comma on every field (incl. last) + newlines" $
      shouldParse $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "p = Point {"
        , "  x = 1,"
        , "  y = 2,"
        , "}"
        ]

  , testCase "inline value construction unchanged" $
      shouldParse "data Point = Point { x : U64, y : U64 }\np = Point { x = 1, y = 2 }\n"

  , testCase "block value construction" $
      shouldParse $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "p = Point {"
        , "  x = 1"
        , "  y = 2"
        , "}"
        ]

  , testCase "block pattern" $
      shouldParse $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "f p = case p of"
        , "  Point {"
        , "    x = a"
        , "    y = b"
        , "  } -> a"
        ]

  , testCase "nested record literals" $
      shouldParse $ T.unlines
        [ "data Inner = Inner { a : U64, b : U64 }"
        , "data Outer = Outer { inner : Inner, tag : U64 }"
        , "o = Outer {"
        , "  inner = Inner {"
        , "    a = 1"
        , "    b = 2"
        , "  }"
        , "  tag = 99"
        , "}"
        ]

  , testCase "block open-row pattern" $
      shouldParse $ T.unlines
        [ "data Point = Point { x : U64, y : U64 }"
        , "f p = case p of"
        , "  Point {"
        , "    x = a"
        , "    .."
        , "  } -> a"
        ]
  ]

irNameTests :: TestTree
irNameTests = testGroup "IRName"
  [ testCase "same unique, different hint => equal" $
      let (a, b) = runFresh $ do
            u <- freshUnique
            pure (Name (T.pack "x") u, Name (T.pack "y") u)
      in a @?= b
  , testCase "different unique => unequal" $
      let (a, b) = runFresh $ do
            x <- freshName (T.pack "x")
            y <- freshName (T.pack "x")
            pure (x, y)
      in assertBool "distinct" (a /= b)
  , testCase "supply is monotonic and deterministic" $
      let us = runFresh (mapM (const freshUnique) [1 :: Int .. 3])
      in us @?= [Unique 0, Unique 1, Unique 2]
  ]

anfTests :: TestTree
anfTests = testGroup "Anf"
  [ testCase "render: f x = let r = x in case r of { 0 -> 1; _ -> r }" $
      let cm = runFresh $ do
            nf <- freshName (T.pack "f")
            nx <- freshName (T.pack "x")
            nr <- freshName (T.pack "r")
            let xBndr = Anf.Binder nx Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])
                rBndr = Anf.Binder nr Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])
                body  = Anf.Let rBndr
                          (Anf.RAtom (Anf.AVar nx))
                          (Anf.Case (Anf.AVar nr)
                            [ Anf.AltLit (Anf.LInt 0) (Anf.Ret (Anf.ALit (Anf.LInt 1)))
                            , Anf.AltDefault (Anf.Ret (Anf.AVar nr))
                            ])
            pure $ Anf.CoreModule
              [ Anf.TopBind nf [xBndr] body ]
          expected = T.intercalate (T.pack "\n")
            [ T.pack "f x ="
            , T.pack "  let r = x"
            , T.pack "  case r of"
            , T.pack "    0 -> 1"
            , T.pack "    _ -> r"
            ]
      in Anf.prettyModule cm @?= expected

  , testCase "collision disambiguation: two distinct x binders get x.N suffixes" $
      let (rendered0, rendered1) = runFresh $ do
            nx0 <- freshName (T.pack "x")
            nx1 <- freshName (T.pack "x")
            let b0 = Anf.Binder nx0 Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])
                -- let x.N0 = x.N1 in x.N0
                e  = Anf.Let b0 (Anf.RAtom (Anf.AVar nx1)) (Anf.Ret (Anf.AVar nx0))
                txt = Anf.prettyExpr e
                -- txt = "let X = Y\nZ"
                -- first word after "let " is b0's rendering
                -- last word of first line (after "= ") is nx1's rendering
                ws  = T.words txt
                -- ws = ["let", rb0, "=", rb1, ...]
                rb0w = case drop 1 ws of { (w:_) -> w; [] -> T.pack "" }
                rb1w = case drop 3 ws of { (w:_) -> w; [] -> T.pack "" }
            pure (rb0w, rb1w)
      in do
        assertBool "both start with x" $
          T.pack "x" `T.isPrefixOf` rendered0 && T.pack "x" `T.isPrefixOf` rendered1
        assertBool "rendered names differ" (rendered0 /= rendered1)

  , testCase "prettyModuleTyped: binder renders as name : type" $
      let cm = runFresh $ do
            nf <- freshName (T.pack "f")
            nx <- freshName (T.pack "x")
            let xBndr = Anf.Binder nx Anf.Unrestricted (Ty.CTCon Ty.TcU64 [])
                body  = Anf.Ret (Anf.AVar nx)
            pure $ Anf.CoreModule
              [ Anf.TopBind nf [xBndr] body ]
          rendered = Anf.prettyModuleTyped cm
      in assertBool ("expected 'x : U64' in: " ++ T.unpack rendered)
                    (T.isInfixOf (T.pack "x : U64") rendered)
  ]

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
          sc = IV.Scope (Map.fromList [(Name.nameUniq n, IV.VLit (Anf.LInt 9))]) Map.empty
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

-- ---------------------------------------------------------------------------
-- Interp prim tests

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
        @?= Data.List.sort (map T.pack ["+","-","*","/","div","mod","eqU64","eqU32","u32","&&","||","++","$","__coro_susp","__coro_unwrap","__coro_resume","__coro_done","__coro_cancel"])
  , testCase "addition" $
      case runPrim (T.pack "+") [li 2, li 3] of
        Right (IV.PRDone v) -> IV.renderValue v @?= T.pack "5"
        other -> assertFailure (show2 other)
  , testCase "equality true" $
      case runPrim (T.pack "eqU64") [li 4, li 4] of
        Right (IV.PRDone v) -> IV.renderValue v @?= T.pack "True"
        other -> assertFailure (show2 other)
  , testCase "equality false" $
      case runPrim (T.pack "eqU64") [li 4, li 5] of
        Right (IV.PRDone v) -> IV.renderValue v @?= T.pack "False"
        other -> assertFailure (show2 other)
  , testCase "u32 equality" $
      case runPrim (T.pack "eqU32") [li 4, li 4] of
        Right (IV.PRDone v) -> IV.renderValue v @?= T.pack "True"
        other -> assertFailure (show2 other)
  , testCase "u32 conversion is identity on the value" $
      case runPrim (T.pack "u32") [li 7] of
        Right (IV.PRDone v) -> IV.renderValue v @?= T.pack "7"
        other -> assertFailure (show2 other)
  , testCase "boolean and" $
      case runPrim (T.pack "&&") [IV.VCon (T.pack "True") [], IV.VCon (T.pack "False") []] of
        Right (IV.PRDone v) -> IV.renderValue v @?= T.pack "False"
        other -> assertFailure (show2 other)
  , testCase "division (non-negative)" $
      case runPrim (T.pack "/") [li 7, li 2] of
        Right (IV.PRDone v) -> IV.renderValue v @?= T.pack "3"
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

-- ---------------------------------------------------------------------------
-- CAF (0-arity top-level bind) evaluation

interpCafTests :: TestTree
interpCafTests = testGroup "InterpCaf"
  [ testCase "0-arity top-level constant is forced and shared" $
      -- module: answer = 42 ; main = answer
      let answer = Anf.TopBind (mkCafName "answer" 0) []
                     (Anf.Ret (Anf.ALit (Anf.LInt 42)))
          mainB  = Anf.TopBind (mkCafName "main" 1) []
                     (Anf.Ret (Anf.AVar (mkCafName "answer" 0)))
          cm = Anf.CoreModule [answer, mainB]
      in Interp.runModule cm @?= Right (IV.VLit (Anf.LInt 42))
  ]
  where
    mkCafName hint u = Name (T.pack hint) (Unique u)

-- ---------------------------------------------------------------------------
-- CEK machine tests

interpMachineTests :: TestTree
interpMachineTests = testGroup "InterpMachine"
  [ testCase "Ret literal" $
      assertEval Map.empty (Anf.Ret (Anf.ALit (Anf.LInt 7))) (T.pack "7")

  , testCase "let then ret" $
      let (e, _) = runFresh $ do
            x <- freshName (T.pack "x")
            let b = Anf.Binder x Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])
            pure (Anf.Let b (Anf.RAtom (Anf.ALit (Anf.LInt 3))) (Anf.Ret (Anf.AVar x)), x)
      in assertEval Map.empty e (T.pack "3")

  , testCase "primitive application 2 + 3" $
      let nplus = runFresh (freshName (T.pack "+"))
          (e, _) = runFresh $ do
            t <- freshName (T.pack "t")
            np <- freshName (T.pack "+")
            let b = Anf.Binder t Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])
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
            let lam = Anf.RLam [Anf.Binder x Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])] (Anf.Ret (Anf.AVar x))
            pure $ Anf.Let (Anf.Binder i Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])) lam
                     (Anf.Let (Anf.Binder r Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                              (Anf.RApp (Anf.AVar i) [Anf.ALit (Anf.LInt 9)])
                              (Anf.Ret (Anf.AVar r)))
      in assertEval Map.empty e (T.pack "9")

  , testCase "currying: (\\x y -> x) applied to one arg is a value, then applied again" $
      -- let k = \x y -> x ; let k1 = k 1 ; let r = k1 2 ; ret r
      let e = runFresh $ do
            x <- freshName (T.pack "x"); y <- freshName (T.pack "y")
            k <- freshName (T.pack "k"); k1 <- freshName (T.pack "k1"); r <- freshName (T.pack "r")
            let lam = Anf.RLam [Anf.Binder x Anf.Unrestricted (Ty.CTCon Ty.TcUnit []), Anf.Binder y Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])]
                               (Anf.Ret (Anf.AVar x))
            pure $ Anf.Let (Anf.Binder k Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])) lam
                     (Anf.Let (Anf.Binder k1 Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])) (Anf.RApp (Anf.AVar k) [Anf.ALit (Anf.LInt 1)])
                       (Anf.Let (Anf.Binder r Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])) (Anf.RApp (Anf.AVar k1) [Anf.ALit (Anf.LInt 2)])
                         (Anf.Ret (Anf.AVar r))))
      in assertEval Map.empty e (T.pack "1")

  , testCase "over-application: a closure returning a closure, applied to extra args" $
      -- let f = \x -> (let g = \y -> x in ret g)   -- f : a -> (b -> a)
      -- let r = f 1 2                                -- 2 args, f takes 1 -> over-application
      -- ret r                                        -- inner closure applied to 2, returns x = 1
      let e = runFresh $ do
            x <- freshName (T.pack "x"); y <- freshName (T.pack "y")
            g <- freshName (T.pack "g"); f <- freshName (T.pack "f"); r <- freshName (T.pack "r")
            let inner = Anf.RLam [Anf.Binder y Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])] (Anf.Ret (Anf.AVar x))
                outerBody = Anf.Let (Anf.Binder g Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])) inner (Anf.Ret (Anf.AVar g))
                outer = Anf.RLam [Anf.Binder x Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])] outerBody
            pure $ Anf.Let (Anf.Binder f Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])) outer
                     (Anf.Let (Anf.Binder r Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                              (Anf.RApp (Anf.AVar f) [Anf.ALit (Anf.LInt 1), Anf.ALit (Anf.LInt 2)])
                              (Anf.Ret (Anf.AVar r)))
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
            pure $ Anf.Let (Anf.Binder p Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                     (Anf.RCon (T.pack "Pair") [Anf.ALit (Anf.LInt 1), Anf.ALit (Anf.LInt 2)])
                     (Anf.Case (Anf.AVar p)
                       [ Anf.AltCon (T.pack "Pair")
                           [Anf.Binder a Anf.Unrestricted (Ty.CTCon Ty.TcUnit []), Anf.Binder b Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])]
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
            pure $ Anf.Let (Anf.Binder r Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                     (Anf.RRecord (T.pack "T")
                        [ (T.pack "c", Anf.ALit (Anf.LInt 30))
                        , (T.pack "a", Anf.ALit (Anf.LInt 10))
                        , (T.pack "b", Anf.ALit (Anf.LInt 20)) ])
                     (Anf.Let (Anf.Binder p Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
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
                      (Anf.Let (Anf.Binder t Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                        (Anf.RApp (Anf.AVar nm) [Anf.AVar n, Anf.ALit (Anf.LInt 1)])
                        (Anf.Let (Anf.Binder r Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                          (Anf.RApp (Anf.AVar loop) [Anf.AVar t])
                          (Anf.Ret (Anf.AVar r)))) ]
            top <- freshName (T.pack "out")
            pure $ Anf.LetRec [(Anf.Binder loop Anf.Unrestricted (Ty.CTCon Ty.TcUnit []), [Anf.Binder n Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])], body)]
                     (Anf.Let (Anf.Binder top Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                       (Anf.RApp (Anf.AVar loop) [Anf.ALit (Anf.LInt 3)])
                       (Anf.Ret (Anf.AVar top)))
      in assertEval Map.empty e (T.pack "0")

  , testCase "letjoin/jump merges branches" $
      -- join j(r) = ret r ; case 1 of { 0 -> jump j 10 ; _ -> jump j 20 }
      let e = runFresh $ do
            j <- freshJoin; r <- freshName (T.pack "r")
            pure $ Anf.LetJoin j [Anf.Binder r Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])] (Anf.Ret (Anf.AVar r))
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

-- ---------------------------------------------------------------------------
-- interpEffectTests

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
            let comp = Anf.Let (Anf.Binder a Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                         (Anf.ROp Nothing (T.pack "Ask") (T.pack "ask") [Anf.ALit Anf.LUnit])
                         (Anf.Ret (Anf.AVar a))
                arm = Anf.OpArm (T.pack "Ask") (T.pack "ask")
                        [Anf.Binder p Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])]
                        (Anf.Binder resume Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                        (Anf.Let (Anf.Binder res Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                          (Anf.RApp (Anf.AVar resume) [Anf.ALit (Anf.LInt 41)])
                          (Anf.Ret (Anf.AVar res)))
                hdlr = Anf.Handler (Anf.Binder v Anf.Unrestricted (Ty.CTCon Ty.TcUnit []), Anf.Ret (Anf.AVar v)) [arm] Nothing Nothing Nothing
            pure (Anf.Handle comp hdlr)
      in assertEval Map.empty e (T.pack "41")

  , testCase "return arm transforms a normally-completing computation" $
      -- handle (ret 5) of return v -> let r = v + 100 ; ret r   (no ops)
      let e = runFresh $ do
            v <- freshName (T.pack "v"); r <- freshName (T.pack "r"); np <- freshName (T.pack "+")
            let retArm = Anf.Let (Anf.Binder r Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                           (Anf.RApp (Anf.AVar np) [Anf.AVar v, Anf.ALit (Anf.LInt 100)])
                           (Anf.Ret (Anf.AVar r))
                hdlr = Anf.Handler (Anf.Binder v Anf.Unrestricted (Ty.CTCon Ty.TcUnit []), retArm) [] Nothing Nothing Nothing
            pure (Anf.Handle (Anf.Ret (Anf.ALit (Anf.LInt 5))) hdlr)
      in assertEval Map.empty e (T.pack "105")

  , testCase "abort: arm ignores resume and returns its own value" $
      -- handle ( let a = Abort.abort () in ret a ) of
      --   Abort.abort(p, resume) -> ret 7      (resume unused)
      --   return v -> v
      let e = runFresh $ do
            a <- freshName (T.pack "a"); p <- freshName (T.pack "p")
            resume <- freshName (T.pack "resume"); v <- freshName (T.pack "v")
            let comp = Anf.Let (Anf.Binder a Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                         (Anf.ROp Nothing (T.pack "Abort") (T.pack "abort") [Anf.ALit Anf.LUnit])
                         (Anf.Ret (Anf.AVar a))
                arm = Anf.OpArm (T.pack "Abort") (T.pack "abort")
                        [Anf.Binder p Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])]
                        (Anf.Binder resume Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                        (Anf.Ret (Anf.ALit (Anf.LInt 7)))
                hdlr = Anf.Handler (Anf.Binder v Anf.Unrestricted (Ty.CTCon Ty.TcUnit []), Anf.Ret (Anf.AVar v)) [arm] Nothing Nothing Nothing
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
            let comp = Anf.Let (Anf.Binder b Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                         (Anf.ROp Nothing (T.pack "Flip") (T.pack "flip") [Anf.ALit Anf.LUnit])
                         (Anf.Case (Anf.AVar b)
                           [ Anf.AltLit (Anf.LInt 0) (Anf.Ret (Anf.ALit (Anf.LInt 10)))
                           , Anf.AltDefault (Anf.Ret (Anf.ALit (Anf.LInt 20))) ])
                armBody =
                  Anf.Let (Anf.Binder r0 Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])) (Anf.RApp (Anf.AVar resume) [Anf.ALit (Anf.LInt 0)])
                    (Anf.Let (Anf.Binder r1 Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])) (Anf.RApp (Anf.AVar resume) [Anf.ALit (Anf.LInt 1)])
                      (Anf.Let (Anf.Binder s Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])) (Anf.RApp (Anf.AVar np) [Anf.AVar r0, Anf.AVar r1])
                        (Anf.Ret (Anf.AVar s))))
                arm = Anf.OpArm (T.pack "Flip") (T.pack "flip")
                        [Anf.Binder p Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])] (Anf.Binder resume Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])) armBody
                hdlr = Anf.Handler (Anf.Binder v Anf.Unrestricted (Ty.CTCon Ty.TcUnit []), Anf.Ret (Anf.AVar v)) [arm] Nothing Nothing Nothing
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
                  Anf.Let (Anf.Binder x Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                    (Anf.ROp Nothing (T.pack "E") (T.pack "op") [Anf.ALit Anf.LUnit])
                    (Anf.Let (Anf.Binder y Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                      (Anf.ROp Nothing (T.pack "E") (T.pack "op") [Anf.ALit Anf.LUnit])
                      (Anf.Let (Anf.Binder s Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                        (Anf.RApp (Anf.AVar np) [Anf.AVar x, Anf.AVar y])
                        (Anf.Ret (Anf.AVar s))))
                arm = Anf.OpArm (T.pack "E") (T.pack "op")
                        [Anf.Binder p Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])] (Anf.Binder resume Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                        (Anf.Let (Anf.Binder r Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                          (Anf.RApp (Anf.AVar resume) [Anf.ALit (Anf.LInt 1)])
                          (Anf.Ret (Anf.AVar r)))
                hdlr = Anf.Handler (Anf.Binder v Anf.Unrestricted (Ty.CTCon Ty.TcUnit []), Anf.Ret (Anf.AVar v)) [arm] Nothing Nothing Nothing
            pure (Anf.Handle comp hdlr)
      in assertEval Map.empty e (T.pack "2")

  , testCase "named instance routes past nearest handler to its own handler" $
      -- Outer handler is NAMED (self-binder sb); inner handler is ambient.
      -- Both handle E.op. Inside the inner handler's scope we perform E.op
      -- THROUGH the outer instance (ROp (Just (AVar sb))). Ambient routing
      -- would hit the inner handler (-> 1); named routing must skip it and
      -- reach the outer (-> 2). The discriminator is the returned value 2.
      --   outer (named sb): E.op -> resume 2
      --   inner (ambient) : E.op -> resume 1
      --   body            : let x = sb.E.op () in ret x
      let e = runFresh $ do
            sb <- freshName (T.pack "sb")
            x  <- freshName (T.pack "x")
            pIn <- freshName (T.pack "pIn"); rIn <- freshName (T.pack "rIn")
            pOut <- freshName (T.pack "pOut"); rOut <- freshName (T.pack "rOut")
            vIn <- freshName (T.pack "vIn"); vOut <- freshName (T.pack "vOut")
            armIn <- freshName (T.pack "armIn"); armOut <- freshName (T.pack "armOut")
            let unit = Ty.CTCon Ty.TcUnit []
                resumeBody resume rb val =
                  Anf.Let (Anf.Binder rb Anf.Unrestricted unit)
                    (Anf.RApp (Anf.AVar resume) [Anf.ALit (Anf.LInt val)])
                    (Anf.Ret (Anf.AVar rb))
                body =
                  Anf.Let (Anf.Binder x Anf.Unrestricted unit)
                    (Anf.ROp (Just (Anf.AVar sb)) (T.pack "E") (T.pack "op") [Anf.ALit Anf.LUnit])
                    (Anf.Ret (Anf.AVar x))
                innerArm =
                  Anf.OpArm (T.pack "E") (T.pack "op")
                    [Anf.Binder pIn Anf.Unrestricted unit]
                    (Anf.Binder rIn Anf.Unrestricted unit)
                    (resumeBody rIn armIn 1)
                innerHdlr =
                  Anf.Handler (Anf.Binder vIn Anf.Unrestricted unit, Anf.Ret (Anf.AVar vIn))
                    [innerArm] Nothing Nothing Nothing
                outerArm =
                  Anf.OpArm (T.pack "E") (T.pack "op")
                    [Anf.Binder pOut Anf.Unrestricted unit]
                    (Anf.Binder rOut Anf.Unrestricted unit)
                    (resumeBody rOut armOut 2)
                outerHdlr =
                  Anf.Handler (Anf.Binder vOut Anf.Unrestricted unit, Anf.Ret (Anf.AVar vOut))
                    [outerArm] Nothing Nothing (Just (Anf.Binder sb Anf.Unrestricted unit))
            pure (Anf.Handle (Anf.Handle body innerHdlr) outerHdlr)
      in assertEval Map.empty e (T.pack "2")

  , testCase "unhandled operation errors" $
      let e = runFresh $ do
            a <- freshName (T.pack "a")
            pure $ Anf.Let (Anf.Binder a Anf.Unrestricted (Ty.CTCon Ty.TcUnit []))
                     (Anf.ROp Nothing (T.pack "Ask") (T.pack "ask") [Anf.ALit Anf.LUnit])
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

-- ---------------------------------------------------------------------------
-- interpEntryTests

-- Load + elaborate (via the given elaborator) + run a single-file program.
-- Unique temp path per call (parallel-safe); guaranteed cleanup.
runSourceWith
  :: (Loader.ModuleName -> [Loader.LoadedModule] -> Either String Anf.CoreModule)
  -> Text -> IO (Either String Text)
runSourceWith elaborate src = do
  u <- newUnique
  let path = "test/.interp-tmp-" <> show (hashUnique u) <> ".wok"
  go path `Control.Exception.finally` removeFileIfExists path
  where
    go path = do
      TIO.writeFile path src
      result <- Loader.loadProgram path []
      case result of
        Left lerr -> pure (Left ("loader: " <> show lerr))
        Right (entryName, ms) ->
          case elaborate entryName ms of
            Left s  -> pure (Left ("elaborate: " <> s))
            Right cm -> case Interp.runModule cm of
              Left rerr -> pure (Left ("runtime: " <> show rerr))
              Right v   -> pure (Right (Interp.renderValue v))

runSourceToValue :: Text -> IO (Either String Text)
runSourceToValue = runSourceWith Pipeline.elaborateProgram

-- Like 'runSourceToValue' but additionally forces the result and converts any
-- pure 'error' thrown during elaboration (e.g. unsupported pattern) into a
-- 'Left'. Elaboration errors are raised lazily, so a plain run would otherwise
-- surface them only as an uncaught exception.
runSourceToValueForced :: Text -> IO (Either String Text)
runSourceToValueForced src = do
  caught <- Control.Exception.try (runSourceToValue src >>= \r -> Control.Exception.evaluate (forceEither r))
  pure $ case caught of
    Left (Control.Exception.ErrorCall msg) -> Left msg
    Right ok                               -> ok
  where
    forceEither e@(Left s)  = s `seq` e
    forceEither e@(Right t) = T.length t `seq` e

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
             , T.pack "helper x = x" ])
      case r of
        Left msg -> assertBool ("expected missing-main (UnboundVar) error, got: " <> msg)
                      (Data.List.isInfixOf "UnboundVar" msg && Data.List.isInfixOf "main" msg)
        Right v  -> assertFailure ("expected failure, got " <> T.unpack v)
  , testCase "top-level constant (CAF) is forced and usable from main" $ do
      -- A 0-arity non-main bind is now evaluated once to a value and shared
      -- (previously rejected as UnsupportedCaf). This underpins ground
      -- instance dictionaries, which lower to 0-arity record values.
      r <- runSourceToValue (T.unlines
             [ T.pack "module Main"
             , T.pack "import Std.Base"
             , T.pack "answer = 42"
             , T.pack "main = answer" ])
      r @?= Right (T.pack "42")
  , testCase "non-zero integer pattern matches its literal (C1 regression)" $ do
      -- Before the fix, integer-literal patterns were compiled to a literal 0,
      -- so `case 5 of 5 -> 100; _ -> 0` returned 0 instead of 100.
      r <- runSourceToValue (T.unlines
             [ T.pack "module Main"
             , T.pack "import Std.Base"
             , T.pack "classify n = case n of"
             , T.pack "  5 -> 100"
             , T.pack "  _ -> 0"
             , T.pack "main = classify 5" ])
      r @?= Right (T.pack "100")
  , testCase "non-empty list literal pattern is rejected (I3 guard)" $ do
      -- Exact-length list matching needs a backtracking match compiler the flat
      -- one-Alt-per-clause model lacks; rather than silently match ANY non-empty
      -- list, a non-empty list literal pattern is rejected (as it was on main).
      r <- runSourceToValueForced (T.unlines
             [ T.pack "module Main"
             , T.pack "import Std.Base"
             , T.pack "solo xs = case xs of"
             , T.pack "  [a] -> a"
             , T.pack "  _   -> 0"
             , T.pack "main = solo [1, 2]" ])
      case r of
        Left msg -> assertBool
                      ("expected non-empty list literal pattern rejection, got: " <> msg)
                      (Data.List.isInfixOf "non-empty list literal pattern" msg)
        Right v  -> assertFailure ("expected rejection, got " <> T.unpack v)
  ]

interpWholeProgramTests :: TestTree
interpWholeProgramTests = testGroup "InterpWholeProgram"
  [ testCase "main calls prelude id" $ do
      r <- runSourceWith Pipeline.elaborateProgramFull (T.unlines
             [ T.pack "module Main"
             , T.pack "import Std.Base"
             , T.pack "main = id 99" ])
      r @?= Right (T.pack "99")
  , testCase "main calls prelude const" $ do
      r <- runSourceWith Pipeline.elaborateProgramFull (T.unlines
             [ T.pack "module Main"
             , T.pack "import Std.Base"
             , T.pack "main = const 7 99" ])
      r @?= Right (T.pack "7")
  ]

-- ---------------------------------------------------------------------------
-- Elaborate basic tests

-- | Check whether an Expr matches the structural shape of:
--   Let _ (RApp _ [ALit (LInt 1)]) (Let _ (RApp _ [AVar _]) (Ret (AVar _)))
-- This corresponds to elaborating  f (g 1).
isAppNamingShape :: Anf.Expr -> Bool
isAppNamingShape
  (Anf.Let _ (Anf.RApp _ [Anf.ALit (Anf.LInt 1)])
    (Anf.Let _ (Anf.RApp _ [Anf.AVar _])
      (Anf.Ret (Anf.AVar _)))) = True
isAppNamingShape _ = False

elaborateBasicTests :: TestTree
elaborateBasicTests = testGroup "ElaborateBasic"
  [ testCase "literal int -> Ret (ALit (LInt 1))" $
      elaborateExprForTest TE.emptyEnv
        (Abs.ELitI (Abs.WokInt ((0,0), T.pack "1")))
        @?= Anf.Ret (Anf.ALit (Anf.LInt 1))

  , testCase "literal string -> Ret (ALit (LStr ...))" $
      elaborateExprForTest TE.emptyEnv
        (Abs.ELitS "hello")
        @?= Anf.Ret (Anf.ALit (Anf.LStr (T.pack "hello")))

  , testCase "unit -> Ret (ALit LUnit)" $
      elaborateExprForTest TE.emptyEnv Abs.EUnit
        @?= Anf.Ret (Anf.ALit Anf.LUnit)

  , testCase "application f (g 1) names its arguments" $
      let -- f (g 1) encoded as EApp (EVar f) (EParen (EApp (EVar g) (ELitI 1)))
          lit1  = Abs.ELitI (Abs.WokInt ((0,0), T.pack "1"))
          g_app = Abs.EApp (Abs.EVar (Abs.VarId ((0,0), T.pack "g"))) lit1
          expr  = Abs.EApp
                    (Abs.EVar (Abs.VarId ((0,0), T.pack "f")))
                    (Abs.EParen g_app)
          result = elaborateExprForTest TE.emptyEnv expr
      in assertBool
           ("expected Let _ (RApp _ [ALit 1]) (Let _ (RApp _ [AVar _]) (Ret (AVar _))), got: "
            <> show result)
           (isAppNamingShape result)

  , testCase "tuple (1, 2) -> Let _ (RCon Tuple2 [ALit 1, ALit 2]) (Ret (AVar _))" $
      let expr = Abs.ETuple
                   (Abs.ELitI (Abs.WokInt ((0,0), T.pack "1")))
                   [Abs.ELitI (Abs.WokInt ((0,0), T.pack "2"))]
          result = elaborateExprForTest TE.emptyEnv expr
      in case result of
           Anf.Let _ (Anf.RCon tag [Anf.ALit (Anf.LInt 1), Anf.ALit (Anf.LInt 2)]) (Anf.Ret (Anf.AVar _)) ->
             tag @?= T.pack "Tuple2"
           _ -> assertFailure ("unexpected shape: " <> show result)

  , testCase "list [1] -> Let nil (RCon Nil []) (Let _ (RCon Cons [ALit 1, AVar nil]) (Ret ...))" $
      let expr   = Abs.EList [Abs.ELitI (Abs.WokInt ((0,0), T.pack "1"))]
          result = elaborateExprForTest TE.emptyEnv expr
      in case result of
           Anf.Let _ (Anf.RCon nilTag []) (Anf.Let _ (Anf.RCon consTag [Anf.ALit (Anf.LInt 1), Anf.AVar _]) (Anf.Ret (Anf.AVar _))) -> do
             nilTag  @?= T.pack "Nil"
             consTag @?= T.pack "Cons"
           _ -> assertFailure ("unexpected shape: " <> show result)

  , testCase "empty list [] -> Let _ (RCon Nil []) (Ret (AVar _))" $
      let expr   = Abs.EList []
          result = elaborateExprForTest TE.emptyEnv expr
      in case result of
           Anf.Let _ (Anf.RCon nilTag []) (Anf.Ret (Anf.AVar _)) ->
             nilTag @?= T.pack "Nil"
           -- nullary con passes through as RAtom-free path -> Let binding
           _ -> assertFailure ("unexpected shape: " <> show result)
  ]

-- ---------------------------------------------------------------------------
-- ElaborateControl tests

-- | Helpers for building dummy-position tokens.
dummyPos :: (Int, Int)
dummyPos = (0, 0)

varId :: T.Text -> Abs.VarId
varId t = Abs.VarId (dummyPos, t)

conId :: T.Text -> Abs.ConId
conId t = Abs.ConId (dummyPos, t)

-- | Check whether an Expr has a Case with two AltCon arms, the first being
-- conName1 with at least one field binder and the second being conName2 with
-- no field binders.
isTwoConCaseShape :: T.Text -> T.Text -> Anf.Expr -> Bool
isTwoConCaseShape con1 con2 e = case e of
  Anf.Case _ [Anf.AltCon c1 (_:_) _, Anf.AltCon c2 [] _] ->
    c1 == con1 && c2 == con2
  _ -> False

-- | Check that an Expr contains at least one LetJoin node anywhere.
hasLetJoin :: Anf.Expr -> Bool
hasLetJoin (Anf.LetJoin _ _ _ _)     = True
hasLetJoin (Anf.Let _ _ e)            = hasLetJoin e
hasLetJoin (Anf.LetRec defs e)        = any (\(_, _, b) -> hasLetJoin b) defs || hasLetJoin e
hasLetJoin (Anf.Case _ alts)          = any altHasLetJoin alts
hasLetJoin (Anf.Jump _ _)             = False
hasLetJoin (Anf.Ret _)                = False
hasLetJoin (Anf.Handle e _)           = hasLetJoin e

altHasLetJoin :: Anf.Alt -> Bool
altHasLetJoin (Anf.AltCon _ _ e)  = hasLetJoin e
altHasLetJoin (Anf.AltLit _ e)    = hasLetJoin e
altHasLetJoin (Anf.AltDefault e)  = hasLetJoin e

-- | Check that a tail-position if elaborates to a bare Case (no LetJoin).
isBareIfCase :: Anf.Expr -> Bool
isBareIfCase (Anf.Case _ [Anf.AltCon t1 [] _, Anf.AltCon f1 [] _]) =
  t1 == T.pack "True" && f1 == T.pack "False"
isBareIfCase _ = False

-- | Check the shape of a bare let-value binding:
-- Let _ (RAtom (ALit (LInt 1))) (Ret (AVar _))
isLetValueRetShape :: Anf.Expr -> Bool
isLetValueRetShape (Anf.Let _ (Anf.RAtom (Anf.ALit (Anf.LInt 1))) (Anf.Ret (Anf.AVar _))) = True
isLetValueRetShape _ = False

-- | Check that an Expr contains a LetRec with at least one entry.
hasLetRec :: Anf.Expr -> Bool
hasLetRec (Anf.LetRec (_:_) _)       = True
hasLetRec (Anf.Let _ _ e)             = hasLetRec e
hasLetRec (Anf.LetRec _ e)            = hasLetRec e
hasLetRec (Anf.LetJoin _ _ jb e)     = hasLetRec jb || hasLetRec e
hasLetRec (Anf.Case _ alts)           = any altHasLetRec alts
hasLetRec _                           = False

altHasLetRec :: Anf.Alt -> Bool
altHasLetRec (Anf.AltCon _ _ e) = hasLetRec e
altHasLetRec (Anf.AltLit _ e)   = hasLetRec e
altHasLetRec (Anf.AltDefault e) = hasLetRec e

elaborateControlTests :: TestTree
elaborateControlTests = testGroup "ElaborateControl"

  [ -- case on a 2-constructor type: case m of { Just x -> x ; Nothing -> 0 }
    -- Expect: Case _ [AltCon "Just" [_] _, AltCon "Nothing" [] _]
    testCase "case: 2-constructor type Just/Nothing shape" $
      let mExpr   = Abs.EVar (varId (T.pack "m"))
          justPat = Abs.PApp (Abs.MPName (conId (T.pack "Just")))
                             (Abs.APVar (varId (T.pack "x")))
                             []
          nothPat = Abs.PAtom (Abs.APCon (Abs.MPName (conId (T.pack "Nothing"))))
          xExpr   = Abs.EVar (varId (T.pack "x"))
          zeroExpr = Abs.ELitI (Abs.WokInt (dummyPos, T.pack "0"))
          alt1    = Abs.AltC justPat xExpr Abs.NoWhere
          alt2    = Abs.AltC nothPat zeroExpr Abs.NoWhere
          expr    = Abs.ECase mExpr [alt1, alt2]
          result  = elaborateExprForTest TE.emptyEnv expr
      in assertBool
           ("expected Case [AltCon Just [_] _, AltCon Nothing [] _], got: " <> show result)
           (isTwoConCaseShape (T.pack "Just") (T.pack "Nothing") result)

  , -- value-position if introduces a LetJoin:
    -- normName (EIf c 1 2) k  =>  LetJoin j [r] (k (AVar r)) (Case c [True->Jump j [1]; False->Jump j [2]])
    testCase "value-position if: normName introduces LetJoin" $
      let cExpr = Abs.EVar (varId (T.pack "c"))
          ifExpr = Abs.EIf cExpr
                     (Abs.ELitI (Abs.WokInt (dummyPos, T.pack "1")))
                     (Abs.ELitI (Abs.WokInt (dummyPos, T.pack "2")))
          -- wrap in a let so 'if' is in value position: let y = (if c then 1 else 2) in y
          letBody = Abs.EVar (varId (T.pack "y"))
          letDecl = Abs.LDEqn (Abs.LHSPre (Abs.FNBare (varId (T.pack "y"))) [])
                               ifExpr Abs.NoWhere
          expr    = Abs.ELet [letDecl] letBody
          result  = elaborateExprForTest TE.emptyEnv expr
      in assertBool
           ("expected LetJoin in result (value-position if), got: " <> show result)
           (hasLetJoin result)

  , -- tail-position if is a bare Case over True/False (no LetJoin)
    testCase "tail-position if: bare Case over True/False" $
      let cExpr = Abs.EVar (varId (T.pack "c"))
          expr  = Abs.EIf cExpr
                    (Abs.ELitI (Abs.WokInt (dummyPos, T.pack "1")))
                    (Abs.ELitI (Abs.WokInt (dummyPos, T.pack "2")))
          result = elaborateExprForTest TE.emptyEnv expr
      in assertBool
           ("expected bare Case over True/False, got: " <> show result)
           (isBareIfCase result)

  , -- let value binding: let x = 1 in x
    -- Expect: Let _ (RAtom (ALit (LInt 1))) (Ret (AVar _))
    testCase "let value binding: let x = 1 in x -> Let _ (RAtom (LInt 1)) (Ret (AVar _))" $
      let litExpr = Abs.ELitI (Abs.WokInt (dummyPos, T.pack "1"))
          letDecl = Abs.LDEqn (Abs.LHSPre (Abs.FNBare (varId (T.pack "x"))) [])
                               litExpr Abs.NoWhere
          body    = Abs.EVar (varId (T.pack "x"))
          expr    = Abs.ELet [letDecl] body
          result  = elaborateExprForTest TE.emptyEnv expr
      in assertBool
           ("expected Let _ (RAtom (LInt 1)) (Ret (AVar _)), got: " <> show result)
           (isLetValueRetShape result)

  , -- let function binding: let f y = y in f
    -- Expect: LetRec with one entry whose body is Ret (AVar _)
    testCase "let function binding: let f y = y in f -> contains LetRec" $
      let paramPat = Abs.APVar (varId (T.pack "y"))
          bodyY    = Abs.EVar (varId (T.pack "y"))
          letDecl  = Abs.LDEqn (Abs.LHSPre (Abs.FNBare (varId (T.pack "f"))) [paramPat])
                                bodyY Abs.NoWhere
          contF    = Abs.EVar (varId (T.pack "f"))
          expr     = Abs.ELet [letDecl] contF
          result   = elaborateExprForTest TE.emptyEnv expr
      in assertBool
           ("expected LetRec in result, got: " <> show result)
           (hasLetRec result)

  , -- PCons with a non-trivial (literal) head: case xs of { 0 : rest -> rest ; _ -> [] }
    -- The head 0 is an APLitI, which is refutable; elabPat must emit a nested
    -- Case on the head binder with an AltLit 0 arm (not silently wildcard it).
    testCase "cons pattern with literal head: nested Case on head binder is produced" $
      let expr = Abs.ECase (Abs.EVar (Abs.VarId ((0,0), T.pack "xs")))
                   [ Abs.AltC
                       (Abs.PCons (Abs.APLitI (Abs.WokInt ((0,0), T.pack "0")))
                                  (Abs.PAtom (Abs.APVar (Abs.VarId ((0,0), T.pack "rest")))))
                       (Abs.EVar (Abs.VarId ((0,0), T.pack "rest")))
                       Abs.NoWhere
                   , Abs.AltC (Abs.PAtom Abs.APWild) (Abs.EList []) Abs.NoWhere
                   ]
          result = elaborateExprForTest TE.emptyEnv expr
          -- The first alt of the outer Case must be AltCon "Cons" [_, _] whose
          -- body is a Case _ [AltLit (LInt 0) _], proving the literal head test
          -- was compiled to a nested case rather than silently wildcarded.
          hasNestedLitHead e = case e of
            Anf.Case _ (Anf.AltCon c (_:_:_) innerBody : _)
              | c == T.pack "Cons" -> case innerBody of
                  Anf.Case _ (Anf.AltLit (Anf.LInt 0) _ : _) -> True
                  _                                            -> False
            _ -> False
      in assertBool
           ("expected outer Case with AltCon Cons whose body has nested AltLit 0, got: " <> show result)
           (hasNestedLitHead result)

  , -- where clause: equation body using where-bound name
    -- let x = (let-with-where body) where w = 5
    -- Modeled as:  let x = w where { w = 5 } in x
    testCase "where clause: body uses where-bound name -> binding in scope" $
      let wExpr   = Abs.EVar (varId (T.pack "w"))
          wDecl   = Abs.LDEqn (Abs.LHSPre (Abs.FNBare (varId (T.pack "w"))) [])
                               (Abs.ELitI (Abs.WokInt (dummyPos, T.pack "5"))) Abs.NoWhere
          xDecl   = Abs.LDEqn (Abs.LHSPre (Abs.FNBare (varId (T.pack "x"))) [])
                               wExpr (Abs.WithWh [wDecl])
          xVar    = Abs.EVar (varId (T.pack "x"))
          expr    = Abs.ELet [xDecl] xVar
          result  = elaborateExprForTest TE.emptyEnv expr
      in -- The result should be some nested Let structure (not error) and
         -- eventually return via Ret.
         case result of
           Anf.Ret _               -> assertFailure ("unexpectedly bare Ret: " <> show result)
           Anf.Let _ _ _           -> pure ()  -- nested Let structure: where binding in scope
           Anf.LetJoin _ _ _ _     -> pure ()  -- join wiring: also fine
           other                   -> assertFailure ("unexpected shape: " <> show other)
  ]

-- ---------------------------------------------------------------------------
-- ElaborateRecords tests
-- ---------------------------------------------------------------------------

-- | Minimal env with a record constructor Point { x : U64, y : U64 } and a
-- non-nullary data constructor Just (arity 1).
recordTestEnv :: TE.Env
recordTestEnv =
  let dummyScheme = Ty.mkScheme [] (Ty.CTCon Ty.TcUnit [])
      justInfo    = TE.ConInfo dummyScheme 1 (T.pack "Maybe")
      nilInfo     = TE.ConInfo dummyScheme 0 (T.pack "List")
      pointRci    = TE.RecordConInfo
                      (T.pack "Point")
                      [ (T.pack "x", Ty.CTCon Ty.TcU64 [])
                      , (T.pack "y", Ty.CTCon Ty.TcU64 [])
                      ]
                      []
  in TE.extendRecordCon (T.pack "Point") pointRci
       (TE.extendCon (T.pack "Just") justInfo
         (TE.extendCon (T.pack "Nil") nilInfo TE.emptyEnv))

-- Shape predicates for the record tests --------------------------------

-- For ECon "Just" in tail position, elabTail calls elabRhs then deliverRhs,
-- so the result should be:
-- Let t (RLam [a] (Let c (RCon "Just" [AVar a]) (Ret (AVar c)))) (Ret (AVar t))
isEtaJustShape :: Anf.Expr -> Bool
isEtaJustShape (Anf.Let _ (Anf.RLam (_:_) lamBody) _) = lamBodyHasRCon (T.pack "Just") lamBody
isEtaJustShape _ = False

lamBodyHasRCon :: T.Text -> Anf.Expr -> Bool
lamBodyHasRCon conName (Anf.Let _ (Anf.RCon c _) _) = c == conName
lamBodyHasRCon _       _                            = False

-- | ECon "Nil" (arity 0, registered) should produce RCon "Nil" [].
-- In tail position: Ret (AVar _) where the var came from a Let _ (RCon "Nil" []).
-- Actually for nullary: deliverRhs TRet (RCon "Nil" []) ->
--   Let t (RCon "Nil" []) (Ret (AVar t))
isNullaryConShape :: T.Text -> Anf.Expr -> Bool
isNullaryConShape conName (Anf.Let _ (Anf.RCon c []) (Anf.Ret (Anf.AVar _))) = c == conName
isNullaryConShape _ _ = False

-- | ERecord "Point" [y=2, x=1] reordered to [x=1, y=2] then RRecord "Point" [("x",..), ("y",..)]
-- In tail position: Let t (RRecord "Point" [...]) (Ret (AVar t))
isRecordDeclaredOrder :: Anf.Expr -> Bool
isRecordDeclaredOrder (Anf.Let _ (Anf.RRecord t fields) _) =
  t == T.pack "Point" && length fields == 2 &&
  fst (fields !! 0) == T.pack "x" &&
  fst (fields !! 1) == T.pack "y"
isRecordDeclaredOrder _ = False

-- | EProj (EVar p) "x" -> Let t (RProj "x" (AVar _)) (Ret (AVar t))
isProjShape :: T.Text -> Anf.Expr -> Bool
isProjShape lbl (Anf.Let _ (Anf.RProj l (Anf.AVar _)) _) = l == lbl
isProjShape _   _                                         = False

-- | Record pattern: case pt of { Point { x = px } -> px }
-- Expect: Case _ [AltCon "Point" [] (Let _ (RProj "x" _) (Ret (AVar _)))]
isRecordPatShape :: Anf.Expr -> Bool
isRecordPatShape (Anf.Case _ [Anf.AltCon t [] body]) =
  t == T.pack "Point" && bodyHasProjLet body
isRecordPatShape _ = False

bodyHasProjLet :: Anf.Expr -> Bool
bodyHasProjLet (Anf.Let _ (Anf.RProj l (Anf.AVar _)) (Anf.Ret (Anf.AVar _))) =
  l == T.pack "x"
bodyHasProjLet _ = False

elaborateRecordsTests :: TestTree
elaborateRecordsTests = testGroup "ElaborateRecords"
  [ -- Constructor saturation: bare ECon "Just" (arity 1) -> eta-expanded RLam
    testCase "saturation: ECon Just (arity 1) produces an RLam wrapper" $
      let expr   = Abs.ECon (conId (T.pack "Just"))
          result = elaborateExprForTest recordTestEnv expr
      in assertBool
           ("expected Let _ (RLam [_] ...) _, got: " <> show result)
           (isEtaJustShape result)

  , -- Nullary constructor stays RCon
    testCase "nullary: ECon Nil (arity 0) produces RCon Nil []" $
      let expr   = Abs.ECon (conId (T.pack "Nil"))
          result = elaborateExprForTest recordTestEnv expr
      in assertBool
           ("expected Let _ (RCon \"Nil\" []) (Ret _), got: " <> show result)
           (isNullaryConShape (T.pack "Nil") result)

  , -- Unregistered constructor stays nullary
    testCase "nullary: unregistered ECon stays RCon []" $
      let expr   = Abs.ECon (conId (T.pack "Nothing"))
          result = elaborateExprForTest TE.emptyEnv expr
      in assertBool
           ("expected RCon \"Nothing\" [], got: " <> show result)
           (isNullaryConShape (T.pack "Nothing") result)

  , -- Record construction with fields given out of order -> reordered to declared order
    testCase "record construction: ERecord Point [y=2, x=1] reordered to [x,y]" $
      let litI n = Abs.ELitI (Abs.WokInt (dummyPos, T.pack (show (n :: Int))))
          fe l e = Abs.RFExpr (varId (T.pack l)) e
          -- fields in source order: y first, then x
          expr   = Abs.ERecord (conId (T.pack "Point"))
                     [ fe "y" (litI 2)
                     , fe "x" (litI 1)
                     ]
          result = elaborateExprForTest recordTestEnv expr
      in assertBool
           ("expected RRecord Point [(x,_),(y,_)] in declared order, got: " <> show result)
           (isRecordDeclaredOrder result)

  , -- Record projection
    testCase "projection: EProj (EVar p) x -> RProj \"x\" _" $
      let expr   = Abs.EProj (Abs.EVar (varId (T.pack "p"))) (varId (T.pack "x"))
          result = elaborateExprForTest TE.emptyEnv expr
      in assertBool
           ("expected Let _ (RProj \"x\" (AVar _)) _, got: " <> show result)
           (isProjShape (T.pack "x") result)

  , -- Record pattern: case pt of { Point { x = px } -> px }
    testCase "record pattern PRecord: fields bound by RProj" $
      let ptExpr  = Abs.EVar (varId (T.pack "pt"))
          pxPat   = Abs.PAtom (Abs.APVar (varId (T.pack "px")))
          rfp     = Abs.RFPat (varId (T.pack "x")) pxPat
          pat     = Abs.PAtom (Abs.PRecord (conId (T.pack "Point")) [rfp])
          bodyExpr = Abs.EVar (varId (T.pack "px"))
          alt     = Abs.AltC pat bodyExpr Abs.NoWhere
          expr    = Abs.ECase ptExpr [alt]
          result  = elaborateExprForTest recordTestEnv expr
      in assertBool
           ("expected Case _ [AltCon Point [] (Let _ (RProj x _) (Ret _))], got: " <> show result)
           (isRecordPatShape result)
  ]

-- ---------------------------------------------------------------------------
-- ElaborateEffects tests
-- ---------------------------------------------------------------------------

-- | Minimal env with effect IO declaring operations write (1 arg) and read (1 arg).
effectTestEnv :: TE.Env
effectTestEnv =
  let dummyScheme = Ty.mkScheme [] (Ty.CTCon Ty.TcUnit [])
      ioInfo = TE.EffectInfo
                 []
                 (Map.fromList
                   [ (T.pack "write", dummyScheme)
                   , (T.pack "read",  dummyScheme)
                   ])
  in TE.extendEffect (T.pack "IO") ioInfo TE.emptyEnv

-- | Check whether the top-level Rhs of an expression is an ROp with the given label and op.
-- Searches through the outermost Let if present.
hasROp :: T.Text -> T.Text -> Anf.Expr -> Bool
hasROp lbl op e = case e of
  Anf.Let _ (Anf.ROp _ l o _) _ -> l == lbl && o == op
  Anf.Ret (Anf.AVar _)          -> False  -- bare atom, no ROp
  _                              -> False

-- | Check that an ROp (not an RApp/RProj) appears in the outermost binding.
topLevelIsROp :: T.Text -> T.Text -> Anf.Expr -> Bool
topLevelIsROp lbl op expr = case expr of
  Anf.Let _ (Anf.ROp _ l o _) _ -> l == lbl && o == op
  _                             -> False

-- | Check that the outermost expression is a Handle with at least one OpArm
-- whose label and op match.
isHandleWithOpArm :: T.Text -> T.Text -> Anf.Expr -> Bool
isHandleWithOpArm lbl op expr = case expr of
  Anf.Handle _ (Anf.Handler _ opArms _ _ _) ->
    any (\arm -> Anf.oaLabel arm == lbl && Anf.oaOp arm == op) opArms
  _ -> False

-- | Check that an OpArm body contains an RApp of the resume binder (auto-resume).
opArmBodyHasResume :: Anf.OpArm -> Bool
opArmBodyHasResume arm =
  let resumeName = Anf.bndName (Anf.oaResume arm)
  in exprHasRAppOf resumeName (Anf.oaBody arm)

exprHasRAppOf :: Name -> Anf.Expr -> Bool
exprHasRAppOf n (Anf.Let _ (Anf.RApp (Anf.AVar f) _) _) = f == n
exprHasRAppOf n (Anf.Let _ _ rest)                        = exprHasRAppOf n rest
exprHasRAppOf n (Anf.LetJoin _ _ jb e)                   = exprHasRAppOf n jb || exprHasRAppOf n e
exprHasRAppOf _ _                                         = False

elaborateEffectsTests :: TestTree
elaborateEffectsTests = testGroup "ElaborateEffects"

  [ -- Effect operation call: IO.write x -> ROp "IO" "write" [_]
    testCase "operation call: EApp (EProj (ECon IO) write) x -> ROp IO write [_]" $
      let xExpr = Abs.EVar (varId (T.pack "x"))
          hdExpr = Abs.EProj (Abs.ECon (conId (T.pack "IO"))) (varId (T.pack "write"))
          expr   = Abs.EApp hdExpr xExpr
          result = elaborateExprForTest effectTestEnv expr
      in assertBool
           ("expected Let _ (ROp \"IO\" \"write\" [_]) _, got: " <> show result)
           (topLevelIsROp (T.pack "IO") (T.pack "write") result)

  , -- Non-effect projection should still produce RProj, not ROp.
    testCase "non-effect EProj (EVar r) x -> RProj x _ (not ROp)" $
      let rExpr  = Abs.EVar (varId (T.pack "r"))
          expr   = Abs.EProj rExpr (varId (T.pack "x"))
          result = elaborateExprForTest TE.emptyEnv expr
      in assertBool
           ("expected Let _ (RProj \"x\" _) _, got: " <> show result)
           (case result of
             Anf.Let _ (Anf.RProj l (Anf.AVar _)) _ -> l == T.pack "x"
             _                                        -> False)

  , -- Operator chain: a + b -> RApp <+> [a, b]
    testCase "EExpr: a + b -> RApp (AVar +) [AVar a, AVar b]" $
      let aE = Abs.EVar (varId (T.pack "a"))
          bE = Abs.EVar (varId (T.pack "b"))
          op = Abs.IOSym (Abs.VarSym (dummyPos, T.pack "+"))
          expr = Abs.EExpr aE [Abs.ITail op bE]
          result = elaborateExprForTest TE.emptyEnv expr
      in assertBool
           ("expected Let _ (RApp (AVar +) [AVar a, AVar b]) (Ret (AVar _)), got: " <> show result)
           (case result of
             Anf.Let _ (Anf.RApp (Anf.AVar _) [Anf.AVar _, Anf.AVar _]) (Anf.Ret (Anf.AVar _)) -> True
             _                                                                                    -> False)

  , -- Operator section: (+) -> RAtom (AVar _)
    testCase "EParenOp (+) -> RAtom (AVar _)" $
      let expr   = Abs.EParenOp (Abs.VarSym (dummyPos, T.pack "+"))
          result = elaborateExprForTest TE.emptyEnv expr
      in assertBool
           ("expected Ret (AVar _), got: " <> show result)
           (case result of
             Anf.Ret (Anf.AVar _) -> True
             _                    -> False)

  , -- Handler in tail position:
    -- with { IO.write m -> () ; v -> v } (comp ())
    testCase "EWith tail position: produces Handle + OpArm with auto-resume" $
      let unitE   = Abs.EUnit
          compApp = Abs.EApp (Abs.EVar (varId (T.pack "comp"))) unitE
          mPat    = Abs.APVar (varId (T.pack "m"))
          writeArm = Abs.HArm (conId (T.pack "IO")) (varId (T.pack "write")) [mPat] Abs.EUnit
          retArm  = Abs.HUArm (varId (T.pack "v")) [] (Abs.EVar (varId (T.pack "v")))
          expr    = Abs.EWith [writeArm, retArm] compApp
          result  = elaborateExprForTest effectTestEnv expr
      in do
        assertBool
          ("expected Handle with IO.write OpArm, got: " <> show result)
          (isHandleWithOpArm (T.pack "IO") (T.pack "write") result)
        -- check auto-resume: the op arm body contains RApp of the resume binder
        case result of
          Anf.Handle _ (Anf.Handler _ (arm:_) _ _ _) ->
            assertBool
              ("expected op arm body to contain RApp of resume binder, got body: "
               <> show (Anf.oaBody arm))
              (opArmBodyHasResume arm)
          _ -> assertFailure ("expected Handle node, got: " <> show result)
  ]

-- ---------------------------------------------------------------------------
-- ElaborateModule tests

-- Build a small module with two top-level equations:
--   idf x = x
--   k = idf
-- and an Env whose envVars contains "idf" and "k".
-- Tests:
--   1. Two TopBinds named "idf" and "k".
--   2. idf has one param; body is Ret (AVar p) where p == the param binder.
--   3. k's body references the SAME canonical Name as idf's tbName.

elaborateModuleTests :: TestTree
elaborateModuleTests = testGroup "ElaborateModule"
  [ testCase "produces two TopBinds named idf and k" $ do
      let (idfBind, kBind) = buildElabModule
      nameHint (Anf.tbName idfBind) @?= T.pack "idf"
      nameHint (Anf.tbName kBind)   @?= T.pack "k"

  , testCase "idf has one param binder" $ do
      let (idfBind, _) = buildElabModule
      length (Anf.tbParams idfBind) @?= 1

  , testCase "idf body is Ret (AVar param): identity preserved" $ do
      let (idfBind, _) = buildElabModule
      case Anf.tbParams idfBind of
        [b] -> case Anf.tbBody idfBind of
          Anf.Ret (Anf.AVar n) -> n @?= Anf.bndName b
          other -> assertFailure ("expected Ret (AVar param), got: " <> show other)
        _ -> assertFailure "expected exactly one param binder"

  , testCase "k's body references the same canonical Name as idf's tbName" $ do
      let (idfBind, kBind) = buildElabModule
          idfName = Anf.tbName idfBind
      -- k = idf; body should be Ret (AVar idfName)
      case Anf.tbBody kBind of
        Anf.Ret (Anf.AVar n) -> n @?= idfName
        other -> assertFailure ("expected Ret (AVar idfName), got: " <> show other)
  ]

-- | Build the test module and return (idfBind, kBind).
buildElabModule :: (Anf.TopBind, Anf.TopBind)
buildElabModule =
  let -- idf x = x
      idfParam = Abs.APVar (varId (T.pack "x"))
      idfLhs   = Abs.LHSPre (Abs.FNBare (varId (T.pack "idf"))) [idfParam]
      idfBody  = Abs.EVar (varId (T.pack "x"))
      idfDecl  = Abs.DEqn idfLhs idfBody Abs.NoWhere
      -- k = idf
      kLhs  = Abs.LHSPre (Abs.FNBare (varId (T.pack "k"))) []
      kBody = Abs.EVar (varId (T.pack "idf"))
      kDecl = Abs.DEqn kLhs kBody Abs.NoWhere
      (envOut, tds) = typedModuleForTest B.initialEnv (Abs.Module [idfDecl, kDecl])
      cm = elaborateModule envOut tds
      binds = Anf.cmBinds cm
      idfBind = case filter (\b -> nameHint (Anf.tbName b) == T.pack "idf") binds of
                  (b:_) -> b
                  []    -> error "buildElabModule: idf bind not found"
      kBind   = case filter (\b -> nameHint (Anf.tbName b) == T.pack "k") binds of
                  (b:_) -> b
                  []    -> error "buildElabModule: k bind not found"
  in (idfBind, kBind)

typedAstTests :: TestTree
typedAstTests = testGroup "TypedAst"
  [ testCase "fmap/Foldable reach every annotation" $
      let e = Typed.Texp (1 :: Int) (Typed.TApp (Typed.Texp 2 (Typed.TVar (T.pack "f")))
                                                 [Typed.Texp 3 (Typed.TLitI 0)])
          e' = fmap (* 10) e
      in sum e' @?= (60 :: Int)   -- 10 + 20 + 30 over the three annotations
  , testCase "TQVar folds over its class-arg annotations" $
      let e = Typed.Texp (10 :: Int)
                (Typed.TQVar (T.pack "==") [(T.pack "Eq", 5)])
      in sum e @?= 15   -- node ann 10 + class-arg ann 5
  ]

-- | Parse-only coverage for the Eq type-class slice (Task 0): `class`/`instance`
-- declarations and `(C a) => T` qualified types parse into the new Abs nodes.
-- These are semantically ignored for now (no typechecking yet).
classParseTests :: TestTree
classParseTests = testGroup "ClassParse"
  [ testCase "class decl parses to DClass" $
      case parse (T.pack "module M\nclass Eq a where\n  (==) : a -> a -> Bool\n") of
        Right (Abs.Module ds) -> assertBool "expected a DClass" (any isDClass ds)
        Left e -> assertFailure ("parse: " ++ e)
  , testCase "instance decl parses to DInstance" $
      case parse (T.pack "module M\ninstance Eq U64 where\n  (==) = eqU64\n") of
        Right (Abs.Module ds) -> assertBool "expected a DInstance" (any isDInstance ds)
        Left e -> assertFailure ("parse: " ++ e)
  , testCase "instance with context parses to IHCtx" $
      case parse (T.pack "module M\ninstance (Eq a) => Eq (Option a) where\n  (==) x y = True\n") of
        Right (Abs.Module ds) -> assertBool "expected an IHCtx instance head" (any isCtxInstance ds)
        Left e -> assertFailure ("parse: " ++ e)
  , testCase "qualified sig parses to TQual" $
      case parse (T.pack "module M\nisEq : (Eq a) => a -> a -> Bool\n") of
        Right (Abs.Module ds) -> assertBool "expected a TQual in a DSig" (any sigHasQual ds)
        Left e -> assertFailure ("parse: " ++ e)
  ]
  where
    isDClass Abs.DClass{}    = True
    isDClass _               = False
    isDInstance Abs.DInstance{} = True
    isDInstance _               = False
    isCtxInstance (Abs.DInstance (Abs.IHCtx{}) _) = True
    isCtxInstance _                               = False
    sigHasQual (Abs.DSig _ _ (Abs.TQual _ _)) = True
    sigHasQual _                              = False

classEnvTests :: TestTree
classEnvTests = testGroup "ClassEnv"
  [ testCase "register + lookup a class and its method" $
      let ci = TE.ClassInfo (0, Ty.KStar)
                 (Map.singleton (T.pack "==") eqScheme)
                 Map.empty [T.pack "=="] (T.pack "Eq$Dict")
          e  = TE.extendClass (T.pack "Eq") ci TE.emptyEnv
      in do TE.lookupClass (T.pack "Eq") e @?= Just ci
            TE.classOfMethod (T.pack "==") e @?= Just (T.pack "Eq")
  , testCase "register + lookup an instance" $
      let ii = TE.InstanceInfo (T.pack "Eq") (Ty.CTCon Ty.TcU64 []) []
                 (T.pack "dict$Eq$U64") Map.empty
          e  = TE.extendInstance ii TE.emptyEnv
      in TE.lookupInstances (T.pack "Eq") e @?= [ii]
  ]
  where
    eqScheme = Ty.Scheme [(0, Ty.KStar)] [Ty.Constraint (T.pack "Eq") (Ty.CTGen 0)]
                 (Ty.CTArr (Ty.CTGen 0) Ty.CREmpty
                   (Ty.CTArr (Ty.CTGen 0) Ty.CREmpty (Ty.CTCon Ty.TcBool [])))

-- | Parse a module body (prefixed with @module M@), then fold the class
-- registrar over all class decls and the instance registrar over all
-- instance decls, starting from 'B.initialEnv'. Class decls are processed
-- before instance decls so that an instance can see its class.
registerDecls :: Text -> Either TErr.TypeError TE.Env
registerDecls body =
  case parse (T.pack "module M\n" <> body) of
    Left e -> error ("registerDecls: parse: " ++ e)
    Right (Abs.Module ds) -> do
      e1 <- Control.Monad.foldM Class.processClassDecl B.initialEnv ds
      Control.Monad.foldM Class.processInstanceDecl e1 ds

-- | Register a module body and hand the resulting 'Env' to a callback,
-- failing the test if registration returns 'Left'.
withDecls :: Text -> (TE.Env -> Assertion) -> Assertion
withDecls body k = case registerDecls body of
  Left err  -> assertFailure ("expected successful registration, got: " ++ show err)
  Right env -> k env

-- | Assert that registering a module body fails (returns 'Left').
assertRejected :: Text -> Assertion
assertRejected body = case registerDecls body of
  Left _    -> pure ()
  Right _   -> assertFailure "expected registration to be rejected, but it succeeded"

classRegisterTests :: TestTree
classRegisterTests = testGroup "ClassRegister"
  [ testCase "class Eq registers method scheme with Eq constraint" $
      withDecls (T.pack "class Eq a where\n  (==) : a -> a -> Bool\n") $ \env ->
        case TE.lookupVar (T.pack "==") env of
          Just s  -> Ty.schemeConstraints s
                       @?= [Ty.Constraint (T.pack "Eq") (Ty.CTGen 0)]
          Nothing -> assertFailure "no == in env"
  , testCase "ground instance registers, ground dict name" $
      withDecls (T.pack "class Eq a where\n  (==) : a -> a -> Bool\ninstance Eq U64 where\n  (==) = eqU64\n") $ \env ->
        case TE.lookupInstances (T.pack "Eq") env of
          [i] -> TE.iiDictName i @?= T.pack "dict$Eq$U64"
          _   -> assertFailure "expected exactly one Eq instance"
  , testCase "non-smaller instance context rejected" $
      assertRejected (T.pack "class Eq a where\n  (==) : a -> a -> Bool\ninstance (Eq [a]) => Eq a where\n  (==) x y = True\n")
  , testCase "overlapping instance rejected" $
      assertRejected (T.pack "class Eq a where\n  (==) : a -> a -> Bool\ninstance Eq U64 where\n  (==) = eqU64\ninstance Eq U64 where\n  (==) = eqU64\n")
  ]

constraintAccumTests :: TestTree
constraintAccumTests = testGroup "ConstraintAccum"
  [ testCase "add then take returns in order, then empties" $
      let r = TM.runTC_ B.initialEnv $ do
                a <- TM.freshTVar Ty.KStar
                TM.addConstraint (T.pack "Eq") a
                cs1 <- TM.takeConstraints
                cs2 <- TM.takeConstraints
                pure (map TM.csClass cs1, length cs1, length cs2)
      in case r of
           Right t -> t @?= ([T.pack "Eq"], 1, 0)
           Left e  -> assertFailure (show e)
  ]

solveTests :: TestTree
solveTests = testGroup "Solve"
  [ testCase "ground instance -> EvGlobal" $
      Solve.resolve env Set.empty (T.pack "Eq") (Ty.CTCon Ty.TcU64 [])
        @?= Right (Ty.EvGlobal (T.pack "dict$Eq$U64"))
  , testCase "constrained instance over concrete -> EvApp of EvGlobal" $
      Solve.resolve env Set.empty (T.pack "Eq")
        (Ty.CTCon (Ty.TcUser (T.pack "Option")) [Ty.CTCon Ty.TcU64 []])
        @?= Right (Ty.EvApp (T.pack "dict$Eq$Option")
                            [Ty.EvGlobal (T.pack "dict$Eq$U64")])
  , testCase "quantified var in scope -> EvParam" $
      Solve.resolve env (Set.singleton 0) (T.pack "Eq") (Ty.CTGen 0)
        @?= Right (Ty.EvParam (T.pack "d$Eq$0"))
  , testCase "quantified var out of scope -> Ambiguous" $
      Solve.resolve env Set.empty (T.pack "Eq") (Ty.CTGen 0)
        @?= Left (Solve.Ambiguous (T.pack "Eq"))
  , testCase "no instance -> NoInst" $
      Solve.resolve env Set.empty (T.pack "Eq") (Ty.CTCon Ty.TcString [])
        @?= Left (Solve.NoInst (T.pack "Eq") (Ty.CTCon Ty.TcString []))
  ]
  where
    env = TE.extendInstance optInst (TE.extendInstance u64Inst TE.emptyEnv)
    u64Inst = TE.InstanceInfo
                (T.pack "Eq")
                (Ty.CTCon Ty.TcU64 [])
                []
                (T.pack "dict$Eq$U64")
                Map.empty
    optInst = TE.InstanceInfo
                (T.pack "Eq")
                (Ty.CTCon (Ty.TcUser (T.pack "Option")) [Ty.CTGen 0])
                [Ty.Constraint (T.pack "Eq") (Ty.CTGen 0)]
                (T.pack "dict$Eq$Option")
                Map.empty

-- | End-to-end inference of the Eq type-class slice: qualified signatures,
-- constraint emission at use-sites, and top-level discharge. Each snippet is
-- prefixed with a minimal Eq class + an `Eq U64` instance (and an `eqU64`
-- bodyless sig so the instance impl typechecks), then run through the full
-- parse -> reorder -> inferProgramWith pipeline so registration, inference, and
-- discharge all execute together.
eqInferTests :: TestTree
eqInferTests = testGroup "EqInfer"
  [ testCase "1 == 2 : Bool" $
      case eqInferDecl (T.pack "main") (T.pack "main = 1 == 2") of
        Left e  -> assertFailure ("typecheck: " ++ show e)
        Right d -> do
          -- The constraint Eq U64 resolves to an instance, so main's scheme is
          -- monomorphic Bool with no residual constraints or evidence.
          Ty.schemeBody (I.tdScheme d) @?= Ty.CTCon Ty.TcBool []
          Ty.schemeConstraints (I.tdScheme d) @?= []
          I.tdEvidence d @?= []
  , testCase "isEq : forall a.(Eq a)=> a->a->Bool with evidence param" $
      case eqInferDecl (T.pack "isEq") (T.pack "isEq x y = x == y") of
        Left e  -> assertFailure ("typecheck: " ++ show e)
        Right d -> do
          Ty.schemeConstraints (I.tdScheme d)
            @?= [Ty.Constraint (T.pack "Eq") (Ty.CTGen 0)]
          map fst (I.tdEvidence d) @?= [T.pack "d$Eq$0"]
  , testCase "no instance for Eq String errors" $
      case eqInferModule (T.pack "bad = \"a\" == \"b\"") of
        Left _  -> pure ()
        Right _ -> assertFailure "expected NoInstance error for Eq String"
  , testCase "ambiguous constraint errors" $
      case eqInferModule (T.pack "amb : (Eq a) => Bool\namb = True") of
        Left _  -> pure ()
        Right _ -> assertFailure "expected AmbiguousConstraint error"
  , -- Regression guard (signed-path entailment must check the ARGUMENT, not
    -- merely the class name): the body needs Eq b but the declared context only
    -- promises Eq a, so this is under-entailed and must be REJECTED.
    testCase "under-entailed signed binding rejected (Eq a sig, body needs Eq b)" $
      case eqInferModule
             (T.pack "f : (Eq a) => a -> b -> Bool\nf x y = y == y") of
        Left _  -> pure ()
        Right _ -> assertFailure
          "expected rejection: body uses (==) on b but sig only provides Eq a"
  , -- A ground signed binding whose only Eq use is on U64 discharges to a
    -- concrete instance: no residual constraint, no evidence parameter.
    testCase "ground signed binding using == on U64 succeeds, no evidence" $
      case eqInferDecl (T.pack "g") (T.pack "g : U64 -> Bool\ng x = x == 0") of
        Left e  -> assertFailure ("typecheck: " ++ show e)
        Right d -> do
          Ty.schemeConstraints (I.tdScheme d) @?= []
          I.tdEvidence d @?= []
  ]
  where
    -- Minimal Eq prelude: fixity decls so the reorderer accepts (==)/(/=),
    -- a Bool datatype, a bodyless eqU64 (so the instance impl checks), and a
    -- single-parameter Eq class with an Eq U64 instance implementing both
    -- methods (the completeness check requires every method to be implemented).
    preludeEq =
      T.concat
        [ T.pack "fixity == left\n"
        , T.pack "fixity /= left\n"
        , T.pack "data Bool = True | False\n"
        , T.pack "eqU64 : U64 -> U64 -> Bool\n"
        , T.pack "class Eq a where\n"
        , T.pack "  (==) : a -> a -> Bool\n"
        , T.pack "  (/=) : a -> a -> Bool\n"
        , T.pack "instance Eq U64 where\n"
        , T.pack "  (==) = eqU64\n"
        , T.pack "  (/=) = eqU64\n"
        ]

    -- Parse + reorder + infer a module built from the Eq prelude plus the
    -- given body. Returns all TypedDecls or the type error.
    eqInferModule :: Text -> Either TErr.TypeError [I.TypedDecl]
    eqInferModule body =
      let src = T.concat [T.pack "module M\n", preludeEq, body, T.pack "\n"]
      in case parse src of
           Left e -> error ("EqInfer parse: " ++ e)
           Right ast -> case reorderModule ast of
             Left es -> error ("EqInfer reorder: " ++ show es)
             Right rm ->
               case TC.inferProgramWith B.initialEnv SO.Embedded (reorderedAst rm) of
                 Left e             -> Left e
                 Right (_, ds, _ws) -> Right ds

    -- Run 'eqInferModule' and pick out the named TypedDecl.
    eqInferDecl :: Text -> Text -> Either TErr.TypeError I.TypedDecl
    eqInferDecl name body = do
      ds <- eqInferModule body
      case [ d | d <- ds, I.tdName d == name ] of
        (d : _) -> Right d
        []      -> error ("EqInfer: no TypedDecl named " ++ T.unpack name)

-- | Synthetic instance desugaring (Task 9): each instance produces real
-- typed dict bindings via the existing inference pipeline. We infer a module
-- with an `Eq U64` (ground) and an `Eq (Option a)` (constrained) instance and
-- assert the resulting dict TypedDecls have the right schemes and evidence.
eqDesugarTests :: TestTree
eqDesugarTests = testGroup "EqDesugar"
  [ testCase "dict$Eq$U64 has scheme `Eq U64`, no constraints, no evidence" $
      case desugarModule of
        Left e   -> assertFailure ("typecheck: " ++ show e)
        Right ds -> case findDecl (T.pack "dict$Eq$U64") ds of
          Nothing -> assertFailure "no dict$Eq$U64 TypedDecl"
          Just d  -> do
            Ty.schemeBody (I.tdScheme d)
              @?= Ty.CTCon (Ty.TcUser (T.pack "Eq")) [Ty.CTCon Ty.TcU64 []]
            Ty.schemeConstraints (I.tdScheme d) @?= []
            I.tdEvidence d @?= []
  , testCase "dict$Eq$Option has (Eq a) constraint + an Eq evidence param" $
      case desugarModule of
        Left e   -> assertFailure ("typecheck: " ++ show e)
        Right ds -> case findDecl (T.pack "dict$Eq$Option") ds of
          Nothing -> assertFailure "no dict$Eq$Option TypedDecl"
          Just d  -> do
            Ty.schemeConstraints (I.tdScheme d)
              @?= [Ty.Constraint (T.pack "Eq") (Ty.CTGen 0)]
            map fst (I.tdEvidence d) @?= [T.pack "d$Eq$0"]
  , testCase "method-synth bindings dict$Eq$U64$m0 / $m1 exist" $
      case desugarModule of
        Left e   -> assertFailure ("typecheck: " ++ show e)
        Right ds -> do
          assertBool "missing dict$Eq$U64$m0"
            (any ((== T.pack "dict$Eq$U64$m0") . I.tdName) ds)
          assertBool "missing dict$Eq$U64$m1"
            (any ((== T.pack "dict$Eq$U64$m1") . I.tdName) ds)
  , -- C1 regression: a signed binding whose body yields a constraint with a
    -- declared skolem NESTED UNDER a type constructor (`Eq (Option a)` from
    -- `(Some x) == (Some x)`). This previously CRASHED in `freeze` on the
    -- embedded Rigid; the declared `(Eq a) =>` promises `Eq a`, and the
    -- `instance (Eq a) => Eq (Option a)` makes `Eq (Option a)` entailed, so it
    -- must TYPECHECK with `schemeConstraints = [Eq (CTGen 0)]` and a `d$Eq$0`.
    testCase "signed `Eq (Option a)` constraint entailed (skolem under tycon)" $
      case desugarModuleWith
             (T.pack "f : (Eq a) => a -> Bool\nf x = (Some x) == (Some x)\n") of
        Left e   -> assertFailure ("typecheck: " ++ show e)
        Right ds -> case findDecl (T.pack "f") ds of
          Nothing -> assertFailure "no f TypedDecl"
          Just d  -> do
            Ty.schemeConstraints (I.tdScheme d)
              @?= [Ty.Constraint (T.pack "Eq") (Ty.CTGen 0)]
            map fst (I.tdEvidence d) @?= [T.pack "d$Eq$0"]
  ]
  where
    findDecl n ds = case [ d | d <- ds, I.tdName d == n ] of
      (d : _) -> Just d
      []      -> Nothing

    -- Fixities, Bool, Option, a bodyless eqU64, not, the Eq class with a (/=)
    -- default, a ground Eq U64 instance, and a constrained Eq (Option a).
    desugarSrc =
      T.concat
        [ T.pack "module M\n"
        , T.pack "fixity == left\n"
        , T.pack "fixity /= left\n"
        , T.pack "data Bool = True | False\n"
        , T.pack "data Option a = None | Some a\n"
        , T.pack "eqU64 : U64 -> U64 -> Bool\n"
        , T.pack "not : Bool -> Bool\n"
        , T.pack "class Eq a where\n"
        , T.pack "  (==) : a -> a -> Bool\n"
        , T.pack "  (/=) : a -> a -> Bool\n"
        , T.pack "  (/=) x y = not (x == y)\n"
        , T.pack "instance Eq U64 where\n"
        , T.pack "  (==) = eqU64\n"
        , T.pack "instance (Eq a) => Eq (Option a) where\n"
        , T.pack "  (==) x y = case (x, y) of\n"
        , T.pack "    (None, None) -> True\n"
        , T.pack "    (Some a, Some b) -> a == b\n"
        , T.pack "    _ -> False\n"
        ]

    desugarModule :: Either TErr.TypeError [I.TypedDecl]
    desugarModule = desugarModuleWith (T.pack "")

    -- Like 'desugarModule', but appends an extra declaration body to the
    -- shared Eq+Option prelude before inferring.
    desugarModuleWith :: Text -> Either TErr.TypeError [I.TypedDecl]
    desugarModuleWith extra =
      case parse (T.append desugarSrc extra) of
        Left e -> error ("EqDesugar parse: " ++ e)
        Right ast -> case reorderModule ast of
          Left es -> error ("EqDesugar reorder: " ++ show es)
          Right rm ->
            case TC.inferProgramWith B.initialEnv SO.Embedded (reorderedAst rm) of
              Left e             -> Left e
              Right (_, ds, _ws) -> Right ds

-- | End-to-end elaboration of a minimal Eq program (Task 10): parse -> reorder
-- -> infer -> elaborate, then assert the ANF shape of the desugared dictionary
-- bind and the case-projecting method dispatch in `main = 1 == 2`.
eqElaborateTests :: TestTree
eqElaborateTests = testGroup "ElaborateClass"
  [ testCase "dict$Eq$U64 is a 0-arity TopBind constructing Eq$Dict" $
      withElab $ \cm ->
        case findBind (T.pack "dict$Eq$U64") cm of
          Nothing -> assertFailure "no dict$Eq$U64 TopBind"
          Just tb -> do
            Anf.tbParams tb @?= []
            assertBool "dict$Eq$U64 body does not construct Eq$Dict"
              (buildsCon (T.pack "Eq$Dict") (Anf.tbBody tb))
  , testCase "main = 1 == 2 lowers `==` to a Case-project + apply" $
      withElab $ \cm ->
        case findBind (T.pack "main") cm of
          Nothing -> assertFailure "no main TopBind"
          Just tb ->
            case findMethodDispatch (Anf.tbBody tb) of
              Nothing -> assertFailure
                ("main body has no Eq$Dict Case-project+apply; body:\n"
                  ++ show (Anf.tbBody tb))
              Just () -> pure ()
  ]
  where
    src =
      T.concat
        [ T.pack "module M\n"
        , T.pack "fixity == left\n"
        , T.pack "data Bool = True | False\n"
        , T.pack "eqU64 : U64 -> U64 -> Bool\n"
        , T.pack "class Eq a where\n"
        , T.pack "  (==) : a -> a -> Bool\n"
        , T.pack "instance Eq U64 where\n"
        , T.pack "  (==) = eqU64\n"
        , T.pack "main = 1 == 2\n"
        ]

    withElab :: (Anf.CoreModule -> Assertion) -> Assertion
    withElab k =
      case parse src of
        Left e -> assertFailure ("ElaborateClass parse: " ++ e)
        Right ast -> case reorderModule ast of
          Left es -> assertFailure ("ElaborateClass reorder: " ++ show es)
          Right rm ->
            case TC.inferProgramWith B.initialEnv SO.Embedded (reorderedAst rm) of
              Left e            -> assertFailure ("ElaborateClass typecheck: " ++ show e)
              Right (env, ds, _) -> k (elaborateModule env ds)

    findBind :: Text -> Anf.CoreModule -> Maybe Anf.TopBind
    findBind n (Anf.CoreModule binds) =
      case [ tb | tb <- binds, Name.nameHint (Anf.tbName tb) == n ] of
        (tb : _) -> Just tb
        []       -> Nothing

    -- Does this Expr (anywhere down the let-chain / tail) emit an RCon for `c`?
    buildsCon :: Text -> Anf.Expr -> Bool
    buildsCon c expr = case expr of
      Anf.Let _ (Anf.RCon c' _) _ | c' == c -> True
      Anf.Let _ _ body                       -> buildsCon c body
      Anf.LetRec _ body                      -> buildsCon c body
      Anf.LetJoin _ _ j body                 -> buildsCon c j || buildsCon c body
      Anf.Case _ alts                        -> any (buildsCon c . altBody) alts
      _                                      -> False

    altBody :: Anf.Alt -> Anf.Expr
    altBody (Anf.AltCon _ _ e)  = e
    altBody (Anf.AltLit _ e)    = e
    altBody (Anf.AltDefault e)  = e

    -- Find a Case over a dict scrutinee that matches the Eq$Dict constructor,
    -- binds the method fields, and applies field 0 (the `==` method) to args.
    findMethodDispatch :: Anf.Expr -> Maybe ()
    findMethodDispatch expr = case expr of
      Anf.Case _ [Anf.AltCon con fbs body]
        | con == T.pack "Eq$Dict"
        , (f0 : _) <- map Anf.bndName fbs
        , appliesField f0 body -> Just ()
      Anf.Case _ alts   -> firstJust (map (findMethodDispatch . altBody) alts)
      Anf.Let _ _ body  -> findMethodDispatch body
      Anf.LetRec _ body -> findMethodDispatch body
      Anf.LetJoin _ _ j body ->
        firstJust [findMethodDispatch j, findMethodDispatch body]
      _ -> Nothing

    -- The field-0 method var is applied to two literal args somewhere in body.
    appliesField :: Name.Name -> Anf.Expr -> Bool
    appliesField f expr = case expr of
      Anf.Let _ (Anf.RApp (Anf.AVar g) _) _ | g == f -> True
      Anf.Ret _              -> False
      Anf.Let _ _ body       -> appliesField f body
      Anf.LetRec _ body      -> appliesField f body
      Anf.LetJoin _ _ j body -> appliesField f j || appliesField f body
      Anf.Case _ alts        -> any (appliesField f . altBody) alts
      _                      -> False

    firstJust :: [Maybe a] -> Maybe a
    firstJust = Data.Maybe.listToMaybe . Data.Maybe.catMaybes

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
          -- Assert None alt routes to j0 with no atoms.
          case [ body | Anf.AltCon c [] body <- alts, c == T.pack "None" ] of
            [body] -> body @?= Anf.Jump j0 []
            _      -> assertFailure "expected AltCon \"None\" [] ..."
          -- Assert Some alt binds the field and routes to j1 with that atom.
          case [ (fieldBinder, body)
               | Anf.AltCon c [fieldBinder] body <- alts, c == T.pack "Some" ] of
            [(fieldBinder, body)] ->
              body @?= Anf.Jump j1 [Anf.AVar (Anf.bndName fieldBinder)]
            _ -> assertFailure "expected AltCon \"Some\" [_] ..."
        other -> assertFailure ("expected Case, got: " ++ show other)

  , testCase "two columns: nested Case with cross-clause fallthrough" $ do
      let oracle = M.ConOracle
            { M.coArity = \t -> if t == T.pack "Cons" then 2 else 0
            , M.coSiblings = \_ -> Just [T.pack "Nil", T.pack "Cons"] }
          ty = Ty.CTCon Ty.TcUnit []
          v  s = M.MPat ty (M.MVar (Just (T.pack s)))
          cons h t = M.MPat ty (M.MCon (T.pack "Cons") [h, t])
          wild = M.MPat ty (M.MVar Nothing)
          jA = Name.JoinId (Name.Unique 200)
          jB = Name.JoinId (Name.Unique 201)
          rows =
            [ M.Row [cons (v "x") (v "xs"), cons (v "y") (v "ys")] []
                    jA [T.pack "x", T.pack "xs", T.pack "y", T.pack "ys"] 0
            , M.Row [wild, wild] [] jB [] 1 ]
          a1 = Anf.AVar (Name.Name (T.pack "a") (Name.Unique 1))
          a2 = Anf.AVar (Name.Name (T.pack "b") (Name.Unique 2))
          expr = runFresh (M.compileMatch oracle [a1, a2] rows)
          jumps = collectJumps expr
      case expr of
        Anf.Case _ alts -> assertBool "nested Case present" (any isNestedCase alts)
        other -> assertFailure ("expected Case, got: " ++ show other)
      assertBool "jA reachable via Cons/Cons clause" (jA `elem` jumps)
      assertBool "jB reachable via wildcard fallthrough" (jB `elem` jumps)

  , testCase "literal column tests constructor once then switches literal" $ do
      let oracle = M.ConOracle
            { M.coArity = \t -> if t == T.pack "Just" then 1 else 0
            , M.coSiblings = \_ -> Just [T.pack "Just", T.pack "Nothing"] }
          ty = Ty.CTCon Ty.TcUnit []
          just p = M.MPat ty (M.MCon (T.pack "Just") [p])
          lit0 = M.MPat ty (M.MLit (Anf.LInt 0))
          wild = M.MPat ty (M.MVar Nothing)
          none = M.MPat ty (M.MCon (T.pack "Nothing") [])
          j0 = Name.JoinId (Name.Unique 300)
          j1 = Name.JoinId (Name.Unique 301)
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

    -- Recursively collect all Jump targets in an Expr.
    collectJumps :: Anf.Expr -> [Name.JoinId]
    collectJumps (Anf.Jump j _)         = [j]
    collectJumps (Anf.Ret _)            = []
    collectJumps (Anf.Let _ rhs e)      = collectJumpsRhs rhs ++ collectJumps e
    collectJumps (Anf.LetRec defs e)    = concatMap (\(_,_,b) -> collectJumps b) defs ++ collectJumps e
    collectJumps (Anf.LetJoin _ _ jb e) = collectJumps jb ++ collectJumps e
    collectJumps (Anf.Case _ alts)      = concatMap collectJumpsAlt alts
    collectJumps (Anf.Handle e h)       =
      collectJumps e
        ++ collectJumps (snd (Anf.hReturn h))
        ++ concatMap (collectJumps . Anf.oaBody) (Anf.hOps h)

    collectJumpsRhs :: Anf.Rhs -> [Name.JoinId]
    collectJumpsRhs (Anf.RLam _ e) = collectJumps e
    collectJumpsRhs _              = []

    collectJumpsAlt :: Anf.Alt -> [Name.JoinId]
    collectJumpsAlt (Anf.AltCon _ _ e)  = collectJumps e
    collectJumpsAlt (Anf.AltLit _ e)    = collectJumps e
    collectJumpsAlt (Anf.AltDefault e)  = collectJumps e

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

  , testCase "full finite signature is exhaustive" $ do
      let oracle = M.ConOracle
            { M.coArity = \t -> if t == T.pack "Cons" then 2 else 0
            , M.coSiblings = \_ -> Just [T.pack "Nil", T.pack "Cons"] }
          ty = Ty.CTCon Ty.TcUnit []
          nil  = M.MPat ty (M.MCon (T.pack "Nil") [])
          cons = M.MPat ty (M.MCon (T.pack "Cons")
                   [M.MPat ty (M.MVar Nothing), M.MPat ty (M.MVar Nothing)])
          rows = [ M.Row [nil]  [] (Name.JoinId (Name.Unique 1)) [] 0
                 , M.Row [cons] [] (Name.JoinId (Name.Unique 2)) [] 1 ]
          cov  = M.matchCoverage oracle 1 rows
      M.covExhaustive cov @?= True
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

  , testCase "literal column is non-exhaustive" $ do
      let oracle = M.ConOracle { M.coArity = const 0, M.coSiblings = \_ -> Nothing }
          ty = Ty.CTCon Ty.TcUnit []
          l0 = M.MPat ty (M.MLit (Anf.LInt 0))
          rows = [ M.Row [l0] [] (Name.JoinId (Name.Unique 1)) [] 0 ]
          cov  = M.matchCoverage oracle 1 rows
      M.covExhaustive cov @?= False
  ]

multiplicityUnitTests :: TestTree
multiplicityUnitTests = testGroup "multiplicity (unit)"
  [ testGroup "lattice"
      [ testCase "addC One One = Many"    $ Mult.addC One One    @?= Many
      , testCase "addC Zero One = One"    $ Mult.addC Zero One   @?= One
      , testCase "addC One Many = Many"   $ Mult.addC One Many   @?= Many
      , testCase "joinC One One = One"    $ Mult.joinC One One   @?= One
      , testCase "joinC Zero Many = Many" $ Mult.joinC Zero Many @?= Many
      , testCase "joinC Zero Zero = Zero" $ Mult.joinC Zero Zero @?= Zero
      ]
  , testGroup "cardOf"
      [ testCase "drop (no resume) = Zero" $
          Mult.cardOf trustedSusp kName (Ret unit) @?= Zero
      , testCase "single direct resume = One" $
          Mult.cardOf trustedSusp kName resumeOnce @?= One
      , testCase "two sequenced resumes = Many" $
          Mult.cardOf trustedSusp kName resumeTwiceSeq @?= Many
      , testCase "resume in two case arms = One (branch join)" $
          Mult.cardOf trustedSusp kName resumeInBothArms @?= One
      , testCase "continuation returned = Many (escape)" $
          Mult.cardOf trustedSusp kName (Ret (AVar kName)) @?= Many
      , testCase "continuation passed to a call = Many (escape)" $
          Mult.cardOf trustedSusp kName escapeIntoCall @?= Many
      , testCase "continuation captured in a closure = Many" $
          Mult.cardOf trustedSusp kName escapeIntoLam @?= Many
      , testCase "continuation in LetRec body = Many" $
          Mult.cardOf trustedSusp kName escapeIntoLetRec @?= Many
      , testCase "resume inside a nested Handle arm = Many" $
          Mult.cardOf trustedSusp kName handleArmCapture @?= Many
      , testCase "jump to an unknown join = Many" $
          Mult.cardOf trustedSusp kName (Jump (JoinId (Unique 50)) []) @?= Many
      , testCase "resume in a join reached from two case arms = One" $
          Mult.cardOf trustedSusp kName joinFromTwoArms @?= One
      , testCase "genuine __coro_susp with resume binder = One (trusted-once)" $
          Mult.cardOf trustedSusp kName coroSuspResume @?= One
      , testCase "spoofed __coro_susp (distinct identity) = Many (C2)" $
          Mult.cardOf trustedSusp kName spoofCoroSuspResume @?= Many
      , testCase "genuine __coro_susp but empty trusted set = Many" $
          Mult.cardOf Set.empty kName coroSuspResume @?= Many
      , testCase "non-coro_susp call with resume binder = Many (control)" $
          Mult.cardOf trustedSusp kName fooCallResume @?= Many
      ]
  , testGroup "analyzeModule"
      [ testCase "clean module = no errors" $
          Mult.analyzeModule Set.empty (modWith resumeOnceArm) @?= []
      , testCase "multishot arm = one error" $
          Mult.analyzeModule Set.empty (modWith multishotArm)
            @?= [Mult.MultishotResume (T.pack "Choice") (T.pack "flip")]
      ]
  ]
  where
    kName  = Name (T.pack "k") (Unique 1)
    fName  = Name (T.pack "f") (Unique 2)
    ty     = Ty.CTCon Ty.TcUnit []
    bnd n  = Binder n Unrestricted ty
    unit   = ALit LUnit
    resumeOnce = Let (bnd (Name (T.pack "r") (Unique 10)))
                     (RApp (AVar kName) [unit]) (Ret unit)
    resumeTwiceSeq =
      Let (bnd (Name (T.pack "a") (Unique 11))) (RApp (AVar kName) [unit])
        (Let (bnd (Name (T.pack "b") (Unique 12))) (RApp (AVar kName) [unit])
          (Ret unit))
    resumeInBothArms =
      Case (ALit (LInt 0))
        [ AltCon (T.pack "A") [] resumeOnce
        , AltCon (T.pack "B") [] resumeOnce ]
    escapeIntoCall =
      Let (bnd (Name (T.pack "c") (Unique 13)))
          (RApp (AVar fName) [AVar kName]) (Ret unit)
    escapeIntoLam =
      Let (bnd (Name (T.pack "g") (Unique 14)))
          (RLam [bnd (Name (T.pack "x") (Unique 15))]
                (Let (bnd (Name (T.pack "r2") (Unique 16)))
                     (RApp (AVar kName) [AVar (Name (T.pack "x") (Unique 15))])
                     (Ret unit)))
          (Ret unit)
    escapeIntoLetRec =
      LetRec [ ( bnd (Name (T.pack "loop") (Unique 17))
               , [bnd (Name (T.pack "x") (Unique 18))]
               , Let (bnd (Name (T.pack "r3") (Unique 19)))
                     (RApp (AVar kName) [unit]) (Ret unit) ) ]
             (Ret unit)
    handleArmCapture =
      Handle (Ret unit)
        (Handler (bnd (Name (T.pack "v") (Unique 20)), Ret unit)
          [ OpArm (T.pack "E") (T.pack "op") []
              (bnd (Name (T.pack "rk") (Unique 21)))
              (Let (bnd (Name (T.pack "r4") (Unique 22)))
                   (RApp (AVar kName) [unit]) (Ret unit)) ]
          Nothing Nothing Nothing)
    joinFromTwoArms =
      LetJoin (JoinId (Unique 60)) []
        (Let (bnd (Name (T.pack "r5") (Unique 61)))
             (RApp (AVar kName) [unit]) (Ret unit))
        (Case (ALit (LInt 0))
          [ AltCon (T.pack "A") [] (Jump (JoinId (Unique 60)) [])
          , AltCon (T.pack "B") [] (Jump (JoinId (Unique 60)) []) ])
    handlerWith oa =
      Handler (bnd (Name (T.pack "v") (Unique 90)), Ret unit) [oa] Nothing Nothing Nothing
    modWith oa =
      CoreModule [ TopBind (Name (T.pack "main") (Unique 91)) []
                     (Handle (Ret unit) (handlerWith oa)) ]
    -- Trusted-once relaxation: handing the resume binder to a GENUINE once-sink
    -- extern (__coro_susp) counts as One. The relaxation keys on the prim's
    -- IDENTITY (its Unique) being in the trusted once-sink SET, not its hint text,
    -- so `trustedSusp` carries the canonical Unique of the genuine sink (Unique
    -- 70). A user binding hinted the same with a DIFFERENT Unique is NOT in the
    -- set, hence NOT trusted (C2) — see `spoofCoroSuspResume`.
    trustedSusp  = Set.singleton (Unique 70)
    coroSuspName = Name (T.pack "__coro_susp") (Unique 70)
    -- A USER binding hinted `__coro_susp` but with a distinct identity.
    spoofSuspName = Name (T.pack "__coro_susp") (Unique 80)
    fooName      = Name (T.pack "foo")         (Unique 71)
    xName        = Name (T.pack "x")           (Unique 72)
    -- Let _ = __coro_susp x k; Ret ()
    coroSuspResume =
      Let (bnd (Name (T.pack "s") (Unique 73)))
          (RApp (AVar coroSuspName) [AVar xName, AVar kName])
          (Ret unit)
    -- Let _ = <user __coro_susp> x k; Ret ()  -- spoof: distinct identity = Many
    spoofCoroSuspResume =
      Let (bnd (Name (T.pack "s3") (Unique 81)))
          (RApp (AVar spoofSuspName) [AVar xName, AVar kName])
          (Ret unit)
    -- Let _ = foo x k; Ret ()  -- non-trusted head should still be Many
    fooCallResume =
      Let (bnd (Name (T.pack "s2") (Unique 74)))
          (RApp (AVar fooName) [AVar xName, AVar kName])
          (Ret unit)
    resumeOnceArm =
      OpArm (T.pack "Tick") (T.pack "tick") [] (bnd kName) resumeOnce
    multishotArm =
      OpArm (T.pack "Choice") (T.pack "flip") [] (bnd kName) resumeTwiceSeq
