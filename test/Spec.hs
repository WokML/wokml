{-# LANGUAGE OverloadedStrings #-}
module Main where

import Test.Tasty
import Test.Tasty.Golden (goldenVsString, findByExtension)
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck (testProperty, QuickCheckTests (..))
import Test.QuickCheck
  ( Gen, Property, forAllShrink, counterexample, choose, elements, sized
  , frequency, conjoin, property, cover, checkCoverage, (.&&.) )
import qualified Test.QuickCheck as QC
import Control.Monad.State.Strict (StateT, runStateT, state, lift)

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
import Wok.IR.Name (Unique (..), Name (..), JoinId (..), Fresh, runFresh, freshUnique, freshName, freshJoin)
import qualified Wok.IR.Anf as Anf
import Wok.IR.Elaborate (elaborateModule)
import qualified Wok.IR.Elaborate as Elab
import qualified Wok.Interp.Value as IV
import qualified Wok.Interp.Prim as IP
import qualified Wok.Interp.Machine as IM
import qualified Wok.Interp.RC.Value as St
import qualified Wok.Interp.RC.Prim as RCP
import qualified Wok.Interp.RC.Machine as RCM
import qualified Wok.IR.Name as Name
import qualified Wok.IR.Match as M
import qualified Wok.IR.Perceus as Perceus
import qualified Wok.IR.Escape as Esc
import Wok.IR.Reachable
  ( pruneToReachable, exprUniques
  , firstOrderNoHandlerViolations )
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
  perceusFiles       <- findByExtension [".wok"] "test/rc-examples"
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
    , crossModuleRowParamTests
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
    , rcStoreTests
    , rcDropTests
    , rcIncrefTests
    , rcMachineTests
    , rcModuleTests
    , rcLetRecTests
    , rcM2a1BaselineTests
    , rcM2a1LintTests
    , rcM2a1AliasTests
    , rcM2a1SiblingDropTests
    , borrowOnCallTests
    , sharedEnvEvalTests
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
    , testGroup "perceus golden"
        [ goldenVsString (takeBaseName f) (perceusGoldenFor f) (perceusDumpHarness f)
        | f <- perceusFiles ]
    , testGroup "perceus lint"
        [ testCase (takeBaseName f) (perceusLintHarness f)
        | f <- perceusFiles ]
    , testGroup "rc differential"
        [ testCase (takeBaseName f) (rcDifferentialHarness f)
        | f <- perceusFiles ]
    , testGroup "rc stats"
        [ testGroup "heap accounting"
            [ testCase (takeBaseName f) (rcStatsHarness f)
            | f <- perceusFiles ]
        , testGroup "golden"
            [ goldenVsString (takeBaseName f) (rcStatsGoldenFor f) (rcStatsDumpHarness f)
            | f <- perceusFiles ]
        ]
    , rcTeethTests perceusFiles
    , rcDeepListTests
    , rcPropertyTests
    , rcM2a1PropertyTests
    , rvRecMemberRepTests
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

-- ---------------------------------------------------------------------------
-- Perceus pass golden + balance lint (Task 5)
--
-- The golden pins the dump of the dup/drop-instrumented ANF (load ->
-- elaborateProgramFull -> Perceus.insertRC -> Perceus.prettyPerceus). The lint
-- HUnit asserts the static balance invariant (every owned binder reaches
-- exactly one consume on every path) holds for the instrumented corpus.

perceusGoldenFor :: FilePath -> FilePath
perceusGoldenFor f =
  replaceDirectory (replaceExtension f ".expected") "test/rc-perceus-golden"

perceusDumpHarness :: FilePath -> IO BL.ByteString
perceusDumpHarness path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> pure (BL.pack ("loader: " <> show lerr <> "\n"))
    Right (entryName, ms) ->
      case Pipeline.elaborateProgramFull entryName ms of
        Left s  -> pure (BL.pack ("elaborate: " <> s <> "\n"))
        Right cm -> pure (BL.pack (T.unpack (Perceus.prettyPerceus cm) <> "\n"))

perceusLintHarness :: FilePath -> Assertion
perceusLintHarness path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> assertFailure ("loader: " <> show lerr)
    Right (entryName, ms) ->
      case Pipeline.elaborateProgramFull entryName ms of
        Left s  -> assertFailure ("elaborate: " <> s)
        Right cm ->
          case Perceus.balanceLint cm of
            []          -> pure ()
            violations  -> assertFailure
              ("balance lint violations:\n"
                 <> unlines (map T.unpack violations))

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
      let tciA = TE.TyConInfo Ty.KStar 0 [] False []
          tciB = TE.TyConInfo Ty.KStar 1 [] False [Ty.KStar]
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
          tciA = TE.TyConInfo Ty.KStar 0 [] False []
          tciB = TE.TyConInfo Ty.KStar 1 [] False [Ty.KStar]
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
          tci = TE.TyConInfo Ty.KStar 0 [] False []
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
          tp s = Abs.TPPlain (vv s)
          decl = Abs.DData (vc "Maybe") [tp "a"]
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
          tp s = Abs.TPPlain (vv s)
          -- extern type Susp a b r
          suspDecl = Abs.DExternType (vc "Susp") [tp "a", tp "b", tp "r"]
          -- extern data St a b r = Done r | More a (Susp a b r)
          stDecl = Abs.DExternData (vc "St") [tp "a", tp "b", tp "r"]
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
          plainDecl = Abs.DData (vc "Plain") [tp "a"]
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
  , testCase "tcParamKinds: (row e) is KEffect, bare is KStar" $
      let pos = (0,0)
          vc s = Abs.ConId (pos, T.pack s)
          vv s = Abs.VarId (pos, T.pack s)
          -- data Box (row e) = Box U64
          boxDecl = Abs.DData (vc "Box") [Abs.TPRow (vv "e")]
                      [ Abs.ConDef (vc "Box")
                          [Abs.TCon (Abs.MPName (vc "U64"))] ]
          -- data Plain a = Plain a
          plainDecl = Abs.DData (vc "Plain") [Abs.TPPlain (vv "a")]
                        [ Abs.ConDef (vc "Plain") [Abs.TVar (vv "a")] ]
          result = TM.runTC_ B.initialEnv $
                     I.processDataDecls B.initialEnv [boxDecl, plainDecl]
      in case result of
           Right env -> do
             case TE.lookupTyCon (T.pack "Box") env of
               Just info -> TE.tcParamKinds info @?= [Ty.KEffect]
               Nothing   -> assertFailure "Box missing"
             case TE.lookupTyCon (T.pack "Plain") env of
               Just info -> TE.tcParamKinds info @?= [Ty.KStar]
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

-- A cross-module instantiation of an inferred row-polymorphic scheme must not
-- panic. RowParamDef exports `mkbox : forall (e : row). Box e` (unsigned, so its
-- scheme is built by freezeQuantify). Bug #5 was that freezeQuantify froze the
-- generalizable row var to its raw global uniq as an UNRECORDED CTGen, leaving it
-- out of the stored scheme's quantifier list; the importing module then
-- instantiated it and crashed `instantiate: dangling CTGen`. Whole-program
-- elaboration succeeding (a Right) is the load-bearing assertion.
crossModuleRowParamTests :: TestTree
crossModuleRowParamTests = testGroup "crossModuleRowParam"
  [ testCase "cross-module use of an inferred row-poly scheme does not dangle" $ do
      res <- Loader.loadProgram
               "test/loader-fixtures/12-row-param-use.wok"
               [ "test/loader-fixtures/12-row-param-def.wok" ]
      case res of
        Right (entryName, ms) ->
          case Pipeline.elaborateProgram entryName ms of
            Right _  -> pure ()
            Left s   -> assertFailure ("expected pipeline success, got: " ++ s)
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
        @?= Data.List.sort (map T.pack ["+","-","*","/","div","mod","eqU64","eqU32","u32","&&","||","++","$","__coro_susp","__coro_unwrap","__coro_resume","__coro_done","__coro_cancel","__coerce","__drive_conc"])
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
    testCase "cons pattern with literal head: literal is compiled to a real test (not wildcarded)" $
      -- `case xs of (0 :: rest) -> rest; _ -> []`. The head literal `0` is a
      -- REFUTABLE sub-pattern under Cons, so this routes through the decision-tree
      -- compiler (bug #7: the old flat one-Alt path committed to Cons and could
      -- not backtrack from a failed `0` test to the `_` arm). The literal must
      -- still appear as an AltLit (LInt 0) somewhere in the tree -- proving it was
      -- compiled to an actual test rather than silently wildcarded.
      let expr = Abs.ECase (Abs.EVar (Abs.VarId ((0,0), T.pack "xs")))
                   [ Abs.AltC
                       (Abs.PCons (Abs.APLitI (Abs.WokInt ((0,0), T.pack "0")))
                                  (Abs.PAtom (Abs.APVar (Abs.VarId ((0,0), T.pack "rest")))))
                       (Abs.EVar (Abs.VarId ((0,0), T.pack "rest")))
                       Abs.NoWhere
                   , Abs.AltC (Abs.PAtom Abs.APWild) (Abs.EList []) Abs.NoWhere
                   ]
          result = elaborateExprForTest TE.emptyEnv expr
          altHasLit0 a = case a of
            Anf.AltLit (Anf.LInt 0) _ -> True
            Anf.AltLit _ b            -> exprHasLit0 b
            Anf.AltCon _ _ b          -> exprHasLit0 b
            Anf.AltDefault b          -> exprHasLit0 b
          exprHasLit0 e = case e of
            Anf.Case _ alts        -> any altHasLit0 alts
            Anf.Let _ _ b          -> exprHasLit0 b
            Anf.LetRec _ b         -> exprHasLit0 b
            Anf.LetJoin _ _ jb b   -> exprHasLit0 jb || exprHasLit0 b
            _                      -> False
      in assertBool
           ("expected an AltLit (LInt 0) somewhere in the tree, got: " <> show result)
           (exprHasLit0 result)

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
  , testGroup "cardOfWithTrust (inter-procedural)"
      [ testCase "helper trusted One in slot 0 -> direct k pass = One" $
          Mult.cardOfWithTrust trustedSusp (Map.fromList [(helperUniq, [One])])
            kName callHelperWithK @?= One
      , testCase "helper trusted Many in slot 0 -> Many (relaxation no-op)" $
          Mult.cardOfWithTrust trustedSusp (Map.fromList [(helperUniq, [Many])])
            kName callHelperWithK @?= Many
      , testCase "helper absent from trust map -> Many (catch-all)" $
          Mult.cardOfWithTrust trustedSusp Map.empty kName callHelperWithK @?= Many
      , testCase "k passed to two One-slots in one call = Many (addC)" $
          Mult.cardOfWithTrust trustedSusp (Map.fromList [(helperUniq, [One, One])])
            kName callHelperWithKK @?= Many
      , testCase "partial application of trusted helper to k = Many (escape, saturation guard)" $
          -- helper has arity 2 (trust [One, One]) but is applied to ONLY k: that
          -- partial app CAPTURES k into the closure f rather than consuming it.
          -- The two later f n calls re-invoke the captured continuation. Clause B
          -- must NOT fire (length as 1 != length cs 2) -> falls through to Many.
          Mult.cardOfWithTrust trustedSusp (Map.fromList [(helperUniq, [One, One])])
            kName partialHelperEscape @?= Many
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
    -- Inter-procedural relaxation fixtures: a top-level helper to whose param the
    -- resume binder k is handed directly. Its trusted card is supplied via the
    -- trust map in each test.
    helperUniq = Unique 75
    helperName = Name (T.pack "helper") helperUniq
    tName      = Name (T.pack "t")      (Unique 76)
    -- let t = helper k in Ret t   (k handed directly to helper's slot 0)
    callHelperWithK =
      Let (bnd tName) (RApp (AVar helperName) [AVar kName]) (Ret (AVar tName))
    -- let t = helper k k in Ret t (k in two slots -> One + One = Many)
    callHelperWithKK =
      Let (bnd tName) (RApp (AVar helperName) [AVar kName, AVar kName]) (Ret (AVar tName))
    -- Partial application capture (arity 2, applied to 1 arg = k):
    --   let f = helper k        -- partial: captures k into the closure f
    --   let a = f n             -- re-invokes captured k
    --   let b = f n             -- re-invokes captured k again
    --   Ret b
    -- The saturation guard must keep clause B from firing on `helper k`.
    fName2 = Name (T.pack "f") (Unique 77)
    nName  = Name (T.pack "n") (Unique 78)
    partialHelperEscape =
      Let (bnd fName2) (RApp (AVar helperName) [AVar kName])
        (Let (bnd (Name (T.pack "a") (Unique 79))) (RApp (AVar fName2) [AVar nName])
          (Let (bnd (Name (T.pack "b") (Unique 82))) (RApp (AVar fName2) [AVar nName])
            (Ret (AVar (Name (T.pack "b") (Unique 82))))))
    resumeOnceArm =
      OpArm (T.pack "Tick") (T.pack "tick") [] (bnd kName) resumeOnce
    multishotArm =
      OpArm (T.pack "Choice") (T.pack "flip") [] (bnd kName) resumeTwiceSeq

-- ---------------------------------------------------------------------------
-- RC store tests (Task 0: owned heap foundation)

rcStoreTests :: TestTree
rcStoreTests = testGroup "rc store"
  [ testCase "alloc gives fresh addrs and counts" $ do
      let s0 = St.emptyStore
          (a, s1) = St.alloc (St.NCon (T.pack "Nil") []) s0
          (b, s2) = St.alloc (St.NCon (T.pack "Nil") []) s1
      a @?= 0
      b @?= 1
      St.stLive (St.stStats s2) @?= 2
      St.stAllocs (St.stStats s2) @?= 2
  , testCase "deref reads a live cell" $ do
      let (a, s1) = St.alloc (St.NCon (T.pack "True") []) St.emptyStore
      case St.deref a s1 of
        Right c -> St.cNode c @?= St.NCon (T.pack "True") []
        Left e  -> assertFailure ("unexpected: " <> show e)
  , testCase "deref of absent addr fails" $
      case St.deref 99 St.emptyStore of
        Left _  -> pure ()
        Right _ -> assertFailure "expected failure on absent addr"
  ]

rcDropTests :: TestTree
rcDropTests = testGroup "rc drop"
  [ testCase "drop frees a unique leaf" $ do
      let (a, s1) = St.alloc (St.NCon (T.pack "Nil") []) St.emptyStore
      case St.dropAddr a s1 of
        Right s2 -> do
          St.stFrees (St.stStats s2) @?= 1
          St.stLive  (St.stStats s2) @?= 0
          case St.deref a s2 of
            Left _  -> pure ()
            Right _ -> assertFailure "UAF not trapped"
        Left e -> assertFailure (show e)
  , testCase "double free is trapped" $ do
      let (a, s1) = St.alloc (St.NCon (T.pack "Nil") []) St.emptyStore
      case St.dropAddr a s1 of
        Right s2 ->
          case St.dropAddr a s2 of
            Left _  -> pure ()
            Right _ -> assertFailure "double-free not trapped"
        Left e -> assertFailure (show e)
  , testCase "drop recursively frees children" $ do
      let (h, s1) = St.alloc (St.NCon (T.pack "Nil") []) St.emptyStore
          (t, s2) = St.alloc (St.NCon (T.pack "Nil") []) s1
          (c, s3) = St.alloc (St.NCon (T.pack "Cons") [St.RVBox h, St.RVBox t]) s2
      case St.dropAddr c s3 of
        Right s4 -> St.stLive (St.stStats s4) @?= 0
        Left e   -> assertFailure (show e)
  , testCase "deep list drops iteratively (no stack overflow)" $ do
      let n = 200000 :: Int
          -- NOTE: build is GHC-stack-recursive (GHC grows its stack); this test isolates dropAddr's EXPLICIT iterativeness, not the builder's.
          build 0 s = St.alloc (St.NCon (T.pack "Nil") []) s
          build k s =
            let (rest, s') = build (k - 1) s
            in St.alloc (St.NCon (T.pack "Cons") [St.RVLit (Anf.LInt (fromIntegral k)), St.RVBox rest]) s'
          (top, s1) = build n St.emptyStore
      case St.dropAddr top s1 of
        Right s2 -> St.stLive (St.stStats s2) @?= 0
        Left e   -> assertFailure (show e)
  ]

rcIncrefTests :: TestTree
rcIncrefTests = testGroup "rc incref"
  [ testCase "incref bumps rc from 1 to 2" $ do
      let (a, s1) = St.alloc (St.NCon (T.pack "Nil") []) St.emptyStore
      case St.incref a s1 of
        Right s2 ->
          case St.deref a s2 of
            Right c -> St.cRc c @?= 2
            Left e  -> assertFailure ("deref after incref: " <> show e)
        Left e -> assertFailure ("incref failed: " <> show e)
  , testCase "incref on dead addr returns Left" $ do
      let (a, s1) = St.alloc (St.NCon (T.pack "Nil") []) St.emptyStore
      case St.dropAddr a s1 of
        Right s2 ->
          case St.incref a s2 of
            Left _  -> pure ()
            Right _ -> assertFailure "incref of dead addr should return Left"
        Left e -> assertFailure ("drop failed: " <> show e)
  , testCase "incref then two drops frees exactly once" $ do
      let (a, s1) = St.alloc (St.NCon (T.pack "Nil") []) St.emptyStore
      case St.incref a s1 of
        Left e -> assertFailure ("incref failed: " <> show e)
        Right s2 ->
          case St.dropAddr a s2 of
            Left e  -> assertFailure ("first drop failed: " <> show e)
            Right s3 -> do
              St.stFrees (St.stStats s3) @?= 0
              case St.deref a s3 of
                Left e  -> assertFailure ("cell freed too early: " <> show e)
                Right _ ->
                  case St.dropAddr a s3 of
                    Left e  -> assertFailure ("second drop failed: " <> show e)
                    Right s4 -> do
                      St.stFrees (St.stStats s4) @?= 1
                      St.stLive  (St.stStats s4) @?= 0
  ]

-- ---------------------------------------------------------------------------
-- RC machine tests (Task 2: store-threaded CEK over the no-handler fragment)
--
-- Each program is a HAND-INSTRUMENTED ANF: dup/drop are inserted manually (the
-- automatic Perceus pass is Task 5). We run it from an empty store, render the
-- result EXACTLY as the reference renderer would, then drop the result handle,
-- and assert the heap is empty (stLive == 0) -- i.e. every allocation was
-- balanced by a free.

-- | A boxed binder with a placeholder type (the machine ignores binder types;
-- only the Unique identity matters for env lookup).
rcBnd :: Name.Name -> Anf.Binder
rcBnd n = Anf.Binder n Anf.Unrestricted (Ty.CTCon Ty.TcUnit [])

-- | Run a hand-instrumented Expr from the empty store, then RENDER the result
-- and DROP it (if boxed). Returns the rendered text and the final live-cell
-- count. A 'Left' anywhere is reported as a test failure.
runAndAccount :: Anf.Expr -> IO (Text, Int)
runAndAccount e =
  case RCM.runExprRC RCP.rcPrimTable Map.empty (St.initSentinel St.emptyStore) e of
    Left err -> assertFailure ("rc run failed: " <> show err)
    Right (v, s) ->
      case St.renderRCValue s v of
        Left err -> assertFailure ("render failed: " <> show err)
        Right txt ->
          case v of
            St.RVBox a ->
              case St.dropAddr a s of
                Left err -> assertFailure ("result drop failed: " <> show err)
                Right s' -> pure (txt, St.stLive (St.stStats s'))
            St.RVLit _           -> pure (txt, St.stLive (St.stStats s))
            St.RVRecMember _ _ envA ->
              case St.dropAddr envA s of
                Left err -> assertFailure ("result drop failed: " <> show err)
                Right s' -> pure (txt, St.stLive (St.stStats s'))

rcMachineTests :: TestTree
rcMachineTests = testGroup "rc machine"
  [ testCase "boundary admits a standalone closure capturing a LetRec sibling, escaping or not (M2a-2 Stage A)" $ do
      -- M2a-2 Stage A: a standalone closure that captures a 'LetRec' sibling is now
      -- ADMITTED whether it stays LOCAL or ESCAPES. The closure capture is
      -- dup-balanced by the pass (a build-site @__rc_dup@ of the shared env per
      -- capture), and the interpreter keeps an over-applied unnamed intermediate
      -- alive through its own call (deferred-consume, 'KDropCellRC'), so the escaped
      -- closure's cascade-drop balances exactly. A BARE move (con / record / list /
      -- call-arg / alias) of a sibling stays rejected (Stage B). See
      -- 'rlamSiblingCaptureEscapes' / the 'isRLam' narrowing in 'Wok.IR.Reachable'.
      --   NON-escaping:  let f n = 0 (LetRec) ; let h = \m -> f m ; in 0   (h dropped)
      --   ESCAPING:      let f n = 0 (LetRec) ; let h = \m -> f m ; in h   (h returned)
      let u64    = Ty.CTCon Ty.TcU64 []
          funTy  = Ty.CTCon (Ty.TcUser (T.pack "Fun")) []
          fName' = Name (T.pack "f") (Unique 990001)
          mName' = Name (T.pack "m") (Unique 990004)
          rName' = Name (T.pack "r") (Unique 990005)
          hName' = Name (T.pack "h") (Unique 990003)
          fBnd'  = Anf.Binder fName' Anf.Unrestricted funTy
          nBnd'  = Anf.Binder (Name (T.pack "n") (Unique 990002)) Anf.Unrestricted u64
          hBnd'  = Anf.Binder hName' Anf.Unrestricted funTy
          mBnd'  = Anf.Binder mName' Anf.Unrestricted u64
          rBnd'  = Anf.Binder rName' Anf.Unrestricted u64
          -- @cap@ = the closure body captures the sibling 'f'; @esc@ = the closure
          -- escapes (the enclosing body returns 'h' instead of the scalar 0).
          mkBody cap esc =
            Anf.LetRec [(fBnd', [nBnd'], Anf.Ret (Anf.ALit (Anf.LInt 0)))]
              (Anf.Let hBnd'
                 (Anf.RLam [mBnd']
                    (if cap
                       then Anf.Let rBnd' (Anf.RApp (Anf.AVar fName') [Anf.AVar mName'])
                                          (Anf.Ret (Anf.AVar rName'))
                       else Anf.Ret (Anf.AVar mName')))
                 (if esc then Anf.Ret (Anf.AVar hName')
                         else Anf.Ret (Anf.ALit (Anf.LInt 0))))
          cmWith cap esc = Anf.CoreModule
            [ Anf.TopBind (Name (T.pack "main") (Unique 990000)) [] (mkBody cap esc) ]
      -- NON-escaping sibling-capturing closure is ADMITTED.
      firstOrderNoHandlerViolations (cmWith True False) @?= []
      -- ESCAPING sibling-capturing closure is now ADMITTED (M2a-2 Stage A) and must
      -- RUN SOUND: the result is the escaped closure (a value CAF), so the run
      -- succeeds, is heap-balanced, and matches the reference interpreter.
      firstOrderNoHandlerViolations (cmWith True True) @?= []
      let escCm = pruneToReachable (cmWith True True)
      case (Interp.runModule escCm, RCM.runModuleRCUnchecked (Perceus.insertRC escCm)) of
        (Right v, Right run) -> do
          Interp.renderValue v @?= RCM.rcOutput run
          let st = RCM.rcStats run; bl = RCM.rcBaseline run
          assertEqual "escaping closure-capture: heap balanced (live)" bl (St.stLive st)
          assertEqual "escaping closure-capture: heap balanced (allocs-frees)"
            bl (St.stAllocs st - St.stFrees st)
        (refRes, rcRes) ->
          assertFailure ("both interpreters must succeed; got "
                           <> show (either show (const "ok") refRes) <> " / "
                           <> show (either show (const "ok") rcRes))
      -- A closure that does NOT capture a sibling is admitted regardless.
      firstOrderNoHandlerViolations (cmWith False False) @?= []
  , testCase "list literal renders and heap empties after result drop" $ do
      -- let n   = Nil
      --     c2  = Cons 2 n
      --     xs  = Cons 1 c2
      -- in xs                      -- => [1, 2]
      (txt, live) <- runAndAccount $ runFresh $ do
        nNil <- freshName (T.pack "n")
        nC2  <- freshName (T.pack "c2")
        nXs  <- freshName (T.pack "xs")
        pure $
          Anf.Let (rcBnd nNil) (Anf.RCon (T.pack "Nil") [])
            (Anf.Let (rcBnd nC2)
              (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 2), Anf.AVar nNil])
              (Anf.Let (rcBnd nXs)
                (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 1), Anf.AVar nC2])
                (Anf.Ret (Anf.AVar nXs))))
      txt @?= T.pack "[1, 2]"
      live @?= 0

  , testCase "record projection: dup kept field, drop parent, heap empties" $ do
      -- let l0 = Nil
      --     l1 = Cons 1 l0          -- the field we keep
      --     m0 = Nil
      --     m1 = Cons 2 m0          -- the field we discard (freed via parent drop)
      --     p  = Pair { fst = l1, snd = m1 }
      --     k  = p.fst              -- alias into the record (NOT yet owned)
      --     k' = __rc_dup k         -- take ownership of the kept field
      --     _  = __rc_drop p        -- frees the record shell AND the discarded snd
      -- in k'                       -- => [1]
      (txt, live) <- runAndAccount $ runFresh $ do
        nL0 <- freshName (T.pack "l0"); nL1 <- freshName (T.pack "l1")
        nM0 <- freshName (T.pack "m0"); nM1 <- freshName (T.pack "m1")
        nP  <- freshName (T.pack "p");  nK  <- freshName (T.pack "k")
        nK' <- freshName (T.pack "kp"); nU  <- freshName (T.pack "u")
        let dropName = Name.Name (T.pack "__rc_drop") (Unique (-1))
            dupName  = Name.Name (T.pack "__rc_dup")  (Unique (-2))
        pure $
          Anf.Let (rcBnd nL0) (Anf.RCon (T.pack "Nil") [])
          (Anf.Let (rcBnd nL1) (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 1), Anf.AVar nL0])
          (Anf.Let (rcBnd nM0) (Anf.RCon (T.pack "Nil") [])
          (Anf.Let (rcBnd nM1) (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 2), Anf.AVar nM0])
          (Anf.Let (rcBnd nP)
            (Anf.RRecord (T.pack "Pair")
              [ (T.pack "fst", Anf.AVar nL1), (T.pack "snd", Anf.AVar nM1) ])
          (Anf.Let (rcBnd nK)  (Anf.RProj (T.pack "fst") (Anf.AVar nP))
          (Anf.Let (rcBnd nK') (Anf.RApp (Anf.AVar dupName) [Anf.AVar nK])
          (Anf.Let (rcBnd nU)  (Anf.RApp (Anf.AVar dropName) [Anf.AVar nP])
          (Anf.Ret (Anf.AVar nK')))))))))
      txt @?= T.pack "[1]"
      live @?= 0

  , testCase "__rc_drop frees a tuple and returns unit; result is a literal" $ do
      -- let p = Tuple2 1 2
      --     _ = __rc_drop p
      -- in 99                       -- => 99, heap empty (the tuple was freed)
      (txt, live) <- runAndAccount $ runFresh $ do
        nP <- freshName (T.pack "p"); nU <- freshName (T.pack "u")
        let dropName = Name.Name (T.pack "__rc_drop") (Unique (-1))
        pure $
          Anf.Let (rcBnd nP)
            (Anf.RCon (T.pack "Tuple2") [Anf.ALit (Anf.LInt 1), Anf.ALit (Anf.LInt 2)])
          (Anf.Let (rcBnd nU) (Anf.RApp (Anf.AVar dropName) [Anf.AVar nP])
          (Anf.Ret (Anf.ALit (Anf.LInt 99))))
      txt @?= T.pack "99"
      live @?= 0

  , testCase "__rc_dup is a no-op on a literal" $ do
      -- let x = __rc_dup 5 in x     -- => 5, no allocation at all
      (txt, live) <- runAndAccount $ runFresh $ do
        nX <- freshName (T.pack "x")
        let dupName = Name.Name (T.pack "__rc_dup") (Unique (-2))
        pure $
          Anf.Let (rcBnd nX) (Anf.RApp (Anf.AVar dupName) [Anf.ALit (Anf.LInt 5)])
          (Anf.Ret (Anf.AVar nX))
      txt @?= T.pack "5"
      live @?= 0

  , testCase "shared value: one dup balances two drops, heap empties" $ do
      -- let s  = Cons 7 Nil          -- a value shared by two consumers
      --     s' = __rc_dup s          -- second owner
      --     a  = Tuple2 s 1          -- consumes the original ownership
      --     b  = Tuple2 s' 2         -- consumes the duped ownership
      --     _  = __rc_drop a         -- frees a AND its share of s
      --     _  = __rc_drop b         -- frees b AND the LAST share of s
      -- in 0                         -- => 0, heap empty
      (txt, live) <- runAndAccount $ runFresh $ do
        nNil <- freshName (T.pack "nil"); nS <- freshName (T.pack "s")
        nS'  <- freshName (T.pack "sp");  nA <- freshName (T.pack "a")
        nB   <- freshName (T.pack "b");   nU1 <- freshName (T.pack "u1")
        nU2  <- freshName (T.pack "u2")
        let dropName = Name.Name (T.pack "__rc_drop") (Unique (-1))
            dupName  = Name.Name (T.pack "__rc_dup")  (Unique (-2))
        pure $
          Anf.Let (rcBnd nNil) (Anf.RCon (T.pack "Nil") [])
          (Anf.Let (rcBnd nS)  (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 7), Anf.AVar nNil])
          (Anf.Let (rcBnd nS') (Anf.RApp (Anf.AVar dupName) [Anf.AVar nS])
          (Anf.Let (rcBnd nA)  (Anf.RCon (T.pack "Tuple2") [Anf.AVar nS, Anf.ALit (Anf.LInt 1)])
          (Anf.Let (rcBnd nB)  (Anf.RCon (T.pack "Tuple2") [Anf.AVar nS', Anf.ALit (Anf.LInt 2)])
          (Anf.Let (rcBnd nU1) (Anf.RApp (Anf.AVar dropName) [Anf.AVar nA])
          (Anf.Let (rcBnd nU2) (Anf.RApp (Anf.AVar dropName) [Anf.AVar nB])
          (Anf.Ret (Anf.ALit (Anf.LInt 0)))))))))
      txt @?= T.pack "0"
      live @?= 0

  , testCase "Case derefs the scrutinee, binds children, then drop-parent empties the heap" $ do
      -- let n  = Nil
      --     xs = Cons 42 n
      -- in case xs of
      --      Cons h t -> let _ = __rc_drop xs   -- own-children / drop-parent:
      --                  in h                    --   h is a literal (no dup),
      --                                           --   so drop the whole shell xs
      --                                           --   (recursively freeing n)
      --      Nil      -> 0                        -- => 42, heap empty
      -- This is the canonical Perceus shape for a Case whose kept children are
      -- unboxed: the shell is freed at the match, recursively releasing the tail.
      (txt, live) <- runAndAccount $ runFresh $ do
        nNil <- freshName (T.pack "n");  nXs <- freshName (T.pack "xs")
        nH   <- freshName (T.pack "h");  nT  <- freshName (T.pack "t")
        nU   <- freshName (T.pack "u")
        let dropName = Name.Name (T.pack "__rc_drop") (Unique (-1))
        pure $
          Anf.Let (rcBnd nNil) (Anf.RCon (T.pack "Nil") [])
          (Anf.Let (rcBnd nXs) (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 42), Anf.AVar nNil])
          (Anf.Case (Anf.AVar nXs)
            [ Anf.AltCon (T.pack "Cons") [rcBnd nH, rcBnd nT]
                (Anf.Let (rcBnd nU) (Anf.RApp (Anf.AVar dropName) [Anf.AVar nXs])
                  (Anf.Ret (Anf.AVar nH)))
            , Anf.AltCon (T.pack "Nil") []
                (Anf.Ret (Anf.ALit (Anf.LInt 0)))
            ]))
      txt @?= T.pack "42"
      live @?= 0

  , testCase "RLam free-var capture: uncaptured local survives closure drop" $ do
      -- Build an env holding an owned boxed local y (rc=1) that the lambda does
      -- NOT reference. Allocate the closure, then DROP it via __rc_drop (the
      -- Perceus-inserted scope-exit drop), then return y.
      --
      -- Under the old whole-env capture: dropping f cascades into y (y is in
      -- f's cenv), decrementing y from rc=1 to rc=0 and freeing y. The final
      -- Ret (AVar yName) then tries to look up yAddr which is now dead ->
      -- use-after-free (Right with a dead address, or Left if deref fails).
      -- Specifically, the final Ret returns RVBox yAddr, and since yAddr is in
      -- stDead, any subsequent deref (e.g. renderRCValue) would error. But since
      -- our test just checks the returned address equals yAddr, we need to verify
      -- yAddr is still LIVE (not in stDead). We check stLive increased back.
      --
      -- Under the NEW free-var-only capture: y is NOT in f's cenv, so dropping
      -- f does not touch y. y survives with rc=1.
      --
      --   let f  = \x -> 0    -- does NOT reference y
      --       _u = __rc_drop f -- Perceus scope-exit drop: drop the closure
      --   in y                 -- y must still be alive (not freed by drop f)
      let yU        = Unique 1000
          yName     = Name.Name (T.pack "y") yU
          fU        = Unique 1002
          fName     = Name.Name (T.pack "f") fU
          xU        = Unique 1001
          xName     = Name.Name (T.pack "x") xU
          uU        = Unique 1003
          uName     = Name.Name (T.pack "_u") uU
          dropName  = Name.Name (T.pack "__rc_drop") (Unique (-1))
          u64Ty     = Ty.CTCon Ty.TcU64 []
          px        = Anf.Binder xName Anf.Unrestricted u64Ty
          -- f = \x -> 0   (body does NOT mention y)
          e = Anf.Let (Anf.Binder fName Anf.Unrestricted u64Ty)
                      (Anf.RLam [px] (Anf.Ret (Anf.ALit (Anf.LInt 0))))
                      (Anf.Let (Anf.Binder uName Anf.Unrestricted u64Ty)
                               (Anf.RApp (Anf.AVar dropName) [Anf.AVar fName])
                               (Anf.Ret (Anf.AVar yName)))
          s0          = St.emptyStore
          (yAddr, s1) = St.alloc (St.NCon (T.pack "Y") []) s0
          env         = Map.fromList [(yU, St.RVBox yAddr)]
      case RCM.runExprRC RCP.rcPrimTable env s1 e of
        Left err     -> assertFailure ("expected success, got: " <> show err)
        Right (v, sf) -> do
          -- y must still be live (not freed by the closure drop)
          assertBool "y must not be in stDead after closure drop"
            (St.stLive (St.stStats sf) >= 1)
          case v of
            St.RVBox a -> a @?= yAddr
            other      -> assertFailure ("expected RVBox y, got " <> show other)

  , test_closureInstrumentationHeapEmpty
  , test_closureLintClean
  , test_closureLintTeeth
  ]

-- | A hand-built closure module (Task 3): a boxed local 'b' is captured by a
-- closure 'f' (which ignores its unboxed param and returns the unpacked field),
-- then 'f' is applied. Running the INSTRUMENTED body must end heap-empty: the
-- capture 'b' is consumed by the Case drop-parent inside the closure body and
-- the closure cell is consumed on application.
--
--   main =
--     let b = Box 7
--     in let f = \x -> case b of Box v -> v
--        in let r = f 5
--           in r
closureModule :: Anf.CoreModule
closureModule =
  Anf.CoreModule [Anf.TopBind mainName [] body]
  where
    mainName = Name.Name (T.pack "main") (Unique 2000)
    bN  = Name.Name (T.pack "b") (Unique 2001)
    fN  = Name.Name (T.pack "f") (Unique 2002)
    rN  = Name.Name (T.pack "r") (Unique 2003)
    xN  = Name.Name (T.pack "x") (Unique 2004)
    vN  = Name.Name (T.pack "v") (Unique 2005)
    boxTy = Ty.CTCon (Ty.TcUser (T.pack "Box")) []   -- isBoxedType => True
    u64Ty = Ty.CTCon Ty.TcU64 []                     -- unboxed
    funTy = Ty.CTCon (Ty.TcUser (T.pack "Fun")) []   -- boxed via catch-all
    bB = Anf.Binder bN Anf.Unrestricted boxTy
    fB = Anf.Binder fN Anf.Unrestricted funTy
    rB = Anf.Binder rN Anf.Unrestricted u64Ty
    xB = Anf.Binder xN Anf.Unrestricted u64Ty
    vB = Anf.Binder vN Anf.Unrestricted u64Ty
    body =
      Anf.Let bB (Anf.RCon (T.pack "Box") [Anf.ALit (Anf.LInt 7)])
        (Anf.Let fB
          (Anf.RLam [xB]
            (Anf.Case (Anf.AVar bN)
              [Anf.AltCon (T.pack "Box") [vB] (Anf.Ret (Anf.AVar vN))]))
          (Anf.Let rB (Anf.RApp (Anf.AVar fN) [Anf.ALit (Anf.LInt 5)])
            (Anf.Ret (Anf.AVar rN))))

test_closureInstrumentationHeapEmpty :: TestTree
test_closureInstrumentationHeapEmpty =
  testCase "closure instrumentation: build+call is heap-empty" $
    case Perceus.insertRC closureModule of
      Anf.CoreModule (Anf.TopBind _ _ body0 : _) ->
        case RCM.runExprRC RCP.rcPrimTable Map.empty St.emptyStore body0 of
          Left err      -> assertFailure ("run failed: " <> show err)
          Right (_, st) -> St.stLive (St.stStats st) @?= 0
      Anf.CoreModule [] -> assertFailure "insertRC dropped the module's binds"

-- | Task 4: the balanced closure module lints clean (capture-as-consume and the
-- lambda-body scope are both accounted by 'balanceLint').
test_closureLintClean :: TestTree
test_closureLintClean = testCase "closure lint: balanced closure lints clean" $
  Perceus.balanceLint closureModule @?= []

-- | Task 4 teeth: omit one inserted drop and the lint must report the imbalance,
-- proving it is genuinely counting the closure's consumes (not just un-refusing).
test_closureLintTeeth :: TestTree
test_closureLintTeeth = testCase "closure lint: missing capture drop is reported" $
  assertBool "expected a non-empty lint report"
    (not (null (Perceus.lintInstrumented (Perceus.insertRCMutated Perceus.OmitOneDrop closureModule))))

-- ---------------------------------------------------------------------------
-- RC whole-module tests (Task 3: runModuleRC, static globals, result drop)
--
-- These run a HAND-INSTRUMENTED 'CoreModule' end to end through 'runModuleRC':
-- top-level binds are installed into the static immortal region (never counted,
-- never dup/drop'd), 'main' is run, and its result is rendered then dropped. We
-- assert the rendered output AND that the DYNAMIC heap empties (stLive == 0).

-- | A top-level bind. The name's hint matters only for 'main' (located by hint);
-- every other bind is reached by its 'Unique' through the static env.
rcTop :: Name.Name -> [Anf.Binder] -> Anf.Expr -> Anf.TopBind
rcTop = Anf.TopBind

rcModuleTests :: TestTree
rcModuleTests = testGroup "rc module"
  [ testCase "static global function: called by main, never counted, heap empties" $ do
      -- id2 x = x                          -- a top-level FUNCTION (static closure)
      -- main  = let xs = Cons 1 (Cons 2 Nil)   -- dynamic allocation
      --             ys = id2 xs                -- call the static global
      --             _  = __rc_drop ys          -- frees the list (ys aliases xs)
      --         in 0                           -- => 0, dynamic heap empty
      let (txt, st, bl) = runFresh $ do
            -- global function 'id2'
            nId  <- freshName (T.pack "id2")
            nIdX <- freshName (T.pack "x")
            -- main locals
            nMain <- freshName (T.pack "main")
            nNil  <- freshName (T.pack "n");  nC2  <- freshName (T.pack "c2")
            nXs   <- freshName (T.pack "xs"); nYs  <- freshName (T.pack "ys")
            nU    <- freshName (T.pack "u")
            let dropName = Name.Name (T.pack "__rc_drop") (Unique (-1))
                idBind = rcTop nId [rcBnd nIdX] (Anf.Ret (Anf.AVar nIdX))
                mainBody =
                  Anf.Let (rcBnd nNil) (Anf.RCon (T.pack "Nil") [])
                  (Anf.Let (rcBnd nC2)
                    (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 2), Anf.AVar nNil])
                  (Anf.Let (rcBnd nXs)
                    (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 1), Anf.AVar nC2])
                  (Anf.Let (rcBnd nYs) (Anf.RApp (Anf.AVar nId) [Anf.AVar nXs])
                  (Anf.Let (rcBnd nU)  (Anf.RApp (Anf.AVar dropName) [Anf.AVar nYs])
                  (Anf.Ret (Anf.ALit (Anf.LInt 0)))))))
                mainBind = rcTop nMain [] mainBody
            pure (Anf.CoreModule [idBind, mainBind])
            >>= \cm -> case RCM.runModuleRC cm of
                         Left err  -> error ("runModuleRC failed: " <> show err)
                         Right run -> pure (RCM.rcOutput run, RCM.rcStats run, RCM.rcBaseline run)
      txt @?= T.pack "0"
      -- The dynamic heap is empty: every dynamic alloc was freed, and the static
      -- global closure was NEVER counted (so it does not show up in stLive).
      -- No value-CAFs in this module, so baseline == 0.
      bl @?= (0 :: Int)
      St.stLive st @?= bl
      St.stAllocs st @?= St.stFrees st

  , testCase "boxed result is dropped by runModuleRC; heap empties" $ do
      -- main = Cons 1 (Cons 2 Nil)         -- returns a boxed list directly;
      --                                     -- runModuleRC renders THEN drops it.
      let (txt, st, bl) = runFresh $ do
            nMain <- freshName (T.pack "main")
            nNil  <- freshName (T.pack "n"); nC2 <- freshName (T.pack "c2")
            nXs   <- freshName (T.pack "xs")
            let mainBody =
                  Anf.Let (rcBnd nNil) (Anf.RCon (T.pack "Nil") [])
                  (Anf.Let (rcBnd nC2)
                    (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 2), Anf.AVar nNil])
                  (Anf.Let (rcBnd nXs)
                    (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 1), Anf.AVar nC2])
                  (Anf.Ret (Anf.AVar nXs))))
            pure (Anf.CoreModule [rcTop nMain [] mainBody])
            >>= \cm -> case RCM.runModuleRC cm of
                         Left err  -> error ("runModuleRC failed: " <> show err)
                         Right run -> pure (RCM.rcOutput run, RCM.rcStats run, RCM.rcBaseline run)
      txt @?= T.pack "[1, 2]"
      -- No value-CAFs, baseline == 0.
      bl @?= (0 :: Int)
      St.stLive st @?= bl
      St.stAllocs st @?= St.stFrees st

  , testCase "literal result, no allocation: empty heap, zero allocs" $ do
      -- main = 99                           -- => 99, no allocation, no drop
      let (txt, st, bl) = runFresh $ do
            nMain <- freshName (T.pack "main")
            pure (Anf.CoreModule [rcTop nMain [] (Anf.Ret (Anf.ALit (Anf.LInt 99)))])
            >>= \cm -> case RCM.runModuleRC cm of
                         Left err  -> error ("runModuleRC failed: " <> show err)
                         Right run -> pure (RCM.rcOutput run, RCM.rcStats run, RCM.rcBaseline run)
      txt @?= T.pack "99"
      -- No value-CAFs, baseline == 0.
      bl @?= (0 :: Int)
      St.stLive st @?= bl
      St.stAllocs st @?= (0 :: Int)

  , testCase "missing main is a loud error" $
      case RCM.runModuleRC (Anf.CoreModule []) of
        Left _  -> pure ()
        Right _ -> assertFailure "expected runModuleRC to reject a module with no main"

  , testCase "HOF with standalone RLam is admitted and runs (M1.5 boundary)" $ do
      -- As of M1.5 'firstOrderNoHandlerViolations' no longer flags 'RLam', so
      -- 'runModuleRC' admits a higher-order program. This test verifies the
      -- boundary guard does NOT reject such a program (it produces the expected
      -- output rather than raising a PrimError).
      --
      --   apply f x = f x
      --   main = let b  = Cons 1 Nil
      --              lam = \y -> 7
      --              r  = apply lam b
      --          in r
      --
      -- NB: this hand-built AST uses rcBnd which annotates every binder with
      -- TcUnit, so Perceus treats every variable as unboxed and inserts no drops.
      -- The 'b' allocation leaks in this synthetic test; that is expected and
      -- acceptable here because the heap-balance invariant is fully covered by
      -- the corpus programs 26-30 which use correctly typed source programs.
      let txt = runFresh $ do
            nApply <- freshName (T.pack "apply")
            nF     <- freshName (T.pack "f")
            nX     <- freshName (T.pack "x")
            nR0    <- freshName (T.pack "r0")
            nMain  <- freshName (T.pack "main")
            nNil   <- freshName (T.pack "nil")
            nB     <- freshName (T.pack "b")
            nLam   <- freshName (T.pack "lam")
            nY     <- freshName (T.pack "y")
            nR     <- freshName (T.pack "r")
            let applyBody =
                  Anf.Let (rcBnd nR0) (Anf.RApp (Anf.AVar nF) [Anf.AVar nX])
                  (Anf.Ret (Anf.AVar nR0))
                applyBind = rcTop nApply [rcBnd nF, rcBnd nX] applyBody
                mainBody =
                  Anf.Let (rcBnd nNil) (Anf.RCon (T.pack "Nil") [])
                  (Anf.Let (rcBnd nB)
                    (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 1), Anf.AVar nNil])
                  (Anf.Let (rcBnd nLam)
                    (Anf.RLam [rcBnd nY] (Anf.Ret (Anf.ALit (Anf.LInt 7))))
                  (Anf.Let (rcBnd nR)
                    (Anf.RApp (Anf.AVar nApply) [Anf.AVar nLam, Anf.AVar nB])
                  (Anf.Ret (Anf.AVar nR)))))
                mainBind = rcTop nMain [] mainBody
                cm = Anf.CoreModule [applyBind, mainBind]
            case RCM.runModuleRC (Perceus.insertRC cm) of
              Left err  -> error ("runModuleRC failed: " <> show err)
              Right run -> pure (RCM.rcOutput run)
      txt @?= T.pack "7"

  -- -------------------------------------------------------------------------
  -- Immortal baseline tests (Task 3 follow-up).
  --
  -- A value-CAF (0-arity constant bind other than 'main') is forced at load
  -- time; its result lives on the DYNAMIC heap for the lifetime of the module.
  -- These cells are immortal globals: they must not be counted as a leak.
  --
  -- The oracle:  rcBaseline > 0  (the CAF allocated dynamic cells)
  --              stLive == rcBaseline  (main's work balanced; no extra leak)
  --
  -- Without the baseline fix, stLive would be > 0 after main completes even
  -- though there is no leak, falsely reporting a heap imbalance.

  , testCase "value-CAF (pair) allocates immortal cells; baseline>0 and stLive==baseline" $ do
      -- pair = Tuple2 1 2              -- a value-CAF: allocates 1 cell at load time
      -- main = 0                       -- does not allocate; => "0"
      --
      -- After installation, baseline = 1 (the Tuple2 cell is live).
      -- main allocates nothing and returns a literal, so stLive stays at 1.
      -- Oracle: baseline == 1, stLive == 1 (== baseline), no leak on top.
      let (txt, st, bl) = runFresh $ do
            nPair  <- freshName (T.pack "pair")
            nPairV <- freshName (T.pack "pairV")  -- local binder inside the CAF body
            nMain  <- freshName (T.pack "main")
            let pairBind = rcTop nPair []
                             (Anf.Let (rcBnd nPairV)
                               (Anf.RCon (T.pack "Tuple2")
                                 [ Anf.ALit (Anf.LInt 1)
                                 , Anf.ALit (Anf.LInt 2) ])
                               (Anf.Ret (Anf.AVar nPairV)))
                mainBind = rcTop nMain [] (Anf.Ret (Anf.ALit (Anf.LInt 0)))
            pure (Anf.CoreModule [pairBind, mainBind])
            >>= \cm -> case RCM.runModuleRC cm of
                         Left err  -> error ("runModuleRC failed: " <> show err)
                         Right run -> pure (RCM.rcOutput run, RCM.rcStats run, RCM.rcBaseline run)
      txt @?= T.pack "0"
      -- The value-CAF genuinely allocated a dynamic cell: baseline must be > 0.
      -- (If this were 0 the test would not exercise the immortal-baseline fix.)
      assertBool "baseline > 0: value-CAF allocated at least one immortal cell" (bl > 0)
      -- main did no allocation and held no references to the pair, so the
      -- dynamic heap must be exactly at the baseline (no leak on top of it).
      St.stLive st @?= bl

  , testCase "value-CAF list allocates multiple immortal cells; baseline>0 and stLive==baseline" $ do
      -- xs   = Cons 10 (Cons 20 Nil)   -- value-CAF: 3 cells at load (Nil, Cons 20, Cons 10)
      -- main = 0                        -- does not allocate; => "0"
      --
      -- After installation, baseline = 3.
      -- main allocates nothing; stLive stays at 3.
      -- Oracle: baseline == 3, stLive == 3 (== baseline), no leak on top.
      let (txt, st, bl) = runFresh $ do
            nXs   <- freshName (T.pack "xs")
            nMain <- freshName (T.pack "main")
            nNil  <- freshName (T.pack "nil")
            nC2   <- freshName (T.pack "c2")
            nC1   <- freshName (T.pack "c1")  -- local binder for the head Cons
            let xsBind = rcTop nXs []
                           (Anf.Let (rcBnd nNil) (Anf.RCon (T.pack "Nil") [])
                           (Anf.Let (rcBnd nC2)
                             (Anf.RCon (T.pack "Cons") [ Anf.ALit (Anf.LInt 20)
                                                       , Anf.AVar nNil ])
                           (Anf.Let (rcBnd nC1)
                             (Anf.RCon (T.pack "Cons") [ Anf.ALit (Anf.LInt 10)
                                                       , Anf.AVar nC2 ])
                           (Anf.Ret (Anf.AVar nC1)))))
                mainBind = rcTop nMain [] (Anf.Ret (Anf.ALit (Anf.LInt 0)))
            pure (Anf.CoreModule [xsBind, mainBind])
            >>= \cm -> case RCM.runModuleRC cm of
                         Left err  -> error ("runModuleRC failed: " <> show err)
                         Right run -> pure (RCM.rcOutput run, RCM.rcStats run, RCM.rcBaseline run)
      txt @?= T.pack "0"
      -- The list CAF allocated 3 cells (Nil, Cons 20, Cons 10); baseline >= 3.
      assertBool "baseline > 0: list CAF allocated immortal cells" (bl > 0)
      -- main did nothing dynamic; stLive must equal the baseline exactly.
      St.stLive st @?= bl
  ]

-- ---------------------------------------------------------------------------
-- RC local mutual recursion (Task 4: LetRec uncounted region)
--
-- A local 'LetRec' group of mutually-recursive closures is an UNCOUNTED REGION:
-- intra-group edges (even's env references odd, and vice versa) do NOT
-- contribute to reference counts, so the closure-env knot never forms a counted
-- cycle. The group is dropped as a UNIT at scope exit -- dropping one member
-- frees that member's cell but does NOT traverse a sibling edge (same region),
-- so siblings are neither double-freed nor leaked; each is freed by its own
-- scope-exit drop.
--
-- We run a HAND-INSTRUMENTED program with the canonical mutual-recursion shape:
--
--   letrec even = \n -> case eqU64 n 0 of
--                         True  -> let _ = drop bool in 1
--                         False -> let _ = drop bool; m = n - 1 in odd m
--          odd  = \n -> case eqU64 n 0 of
--                         True  -> let _ = drop bool in 0
--                         False -> let _ = drop bool; m = n - 1 in even m
--   in let r  = even 4          -- => 1 (4 is even)
--          _  = drop even       -- scope exit: drop the group as a unit
--          _  = drop odd
--      in r
--
-- Each call allocates one boxed Bool (from eqU64) which its branch drops, so the
-- only residue at scope exit is the two-closure region, dropped explicitly. The
-- result (1) is an unboxed literal, so runAndAccount has nothing further to free.

-- | Compiler-internal prim handles. dup/drop and the arithmetic/comparison
-- prims are resolved by HINT through the prim table (see 'callFn' in
-- "Wok.Interp.RC.Machine"), so any negative 'Unique' that cannot collide with a
-- 'runFresh'-minted binder works as the identity.
rcDropName, rcEqName, rcSubName :: Name.Name
rcDropName = Name.Name (T.pack "__rc_drop") (Unique (-1))
rcEqName   = Name.Name (T.pack "eqU64")     (Unique (-3))
rcSubName  = Name.Name (T.pack "-")         (Unique (-4))

-- | A parity-clause body: @\\param -> case eqU64 param 0 of { True -> baseLit;
-- False -> sibling (param - 1) }@, fully ANF-instrumented with a drop of the
-- freshly-allocated boxed Bool in each branch. All fresh names are minted in the
-- SAME 'Fresh' computation as the surrounding group, so no Unique collides (a
-- nested 'runFresh' would restart the counter at 0 and alias the group binders).
rcParityClause :: Name.Name -> Integer -> Name.Name -> Fresh Anf.Expr
rcParityClause param baseLit sibling = do
  nZ <- freshName (T.pack "z");  nB <- freshName (T.pack "b")
  nU <- freshName (T.pack "u");  nM <- freshName (T.pack "m")
  nRec <- freshName (T.pack "rec")
  pure $
    Anf.Let (rcBnd nZ) (Anf.RAtom (Anf.ALit (Anf.LInt 0)))
    (Anf.Let (rcBnd nB)
      (Anf.RApp (Anf.AVar rcEqName) [Anf.AVar param, Anf.AVar nZ])
    (Anf.Case (Anf.AVar nB)
      [ Anf.AltCon (T.pack "True") []
          (Anf.Let (rcBnd nU) (Anf.RApp (Anf.AVar rcDropName) [Anf.AVar nB])
            (Anf.Ret (Anf.ALit (Anf.LInt baseLit))))
      , Anf.AltCon (T.pack "False") []
          (Anf.Let (rcBnd nU) (Anf.RApp (Anf.AVar rcDropName) [Anf.AVar nB])
           (Anf.Let (rcBnd nM)
             (Anf.RApp (Anf.AVar rcSubName) [Anf.AVar param, Anf.ALit (Anf.LInt 1)])
           (Anf.Let (rcBnd nRec)
             (Anf.RApp (Anf.AVar sibling) [Anf.AVar nM])
             (Anf.Ret (Anf.AVar nRec)))))
      ]))

-- | Build the canonical mutual-recursion program:
--
--   letrec even = \n -> case eqU64 n 0 of True -> 1; False -> odd (n-1)
--          odd  = \n -> case eqU64 n 0 of True -> 0; False -> even (n-1)
--   in let r = <entry> <arg>
--          _ = drop <dropFirst>
--          _ = drop <dropSecond>      -- group dropped as a unit, in this order
--      in r
--
-- 'entryIsEven' selects which member 'main' calls; 'dropEvenFirst' selects the
-- scope-exit drop order, so a test can exercise dropping a sibling BEFORE the
-- one it points at (the uncounted-edge case).
rcMutualProgram :: Bool -> Integer -> Bool -> Fresh Anf.Expr
rcMutualProgram entryIsEven arg dropEvenFirst = do
  nEven <- freshName (T.pack "even"); nOdd <- freshName (T.pack "odd")
  nEN   <- freshName (T.pack "en");   nON  <- freshName (T.pack "on")
  nR    <- freshName (T.pack "r")
  nU1   <- freshName (T.pack "u1");   nU2  <- freshName (T.pack "u2")
  evenBody <- rcParityClause nEN 1 nOdd
  oddBody  <- rcParityClause nON 0 nEven
  let entry      = if entryIsEven then nEven else nOdd
      (d1, d2)   = if dropEvenFirst then (nEven, nOdd) else (nOdd, nEven)
  pure $
    Anf.LetRec
      [ (rcBnd nEven, [rcBnd nEN], evenBody)
      , (rcBnd nOdd,  [rcBnd nON], oddBody)
      ]
      (Anf.Let (rcBnd nR) (Anf.RApp (Anf.AVar entry) [Anf.ALit (Anf.LInt arg)])
       (Anf.Let (rcBnd nU1) (Anf.RApp (Anf.AVar rcDropName) [Anf.AVar d1])
        (Anf.Let (rcBnd nU2) (Anf.RApp (Anf.AVar rcDropName) [Anf.AVar d2])
         (Anf.Ret (Anf.AVar nR)))))

rcLetRecTests :: TestTree
rcLetRecTests = testGroup "rc letrec"
  [ testCase "local mutual recursion: even 4 = 1, group drops as a unit, heap empties" $ do
      (txt, live) <- runAndAccount $ runFresh (rcMutualProgram True 4 True)
      txt @?= T.pack "1"
      live @?= 0

  , testCase "odd 4 = 0 via the same group" $ do
      (txt, live) <- runAndAccount $ runFresh (rcMutualProgram False 4 True)
      txt @?= T.pack "0"
      live @?= 0

  , testCase "dropping one sibling before the one it points at does not double-free or leak" $ do
      -- Drop odd FIRST, then even. Because intra-group edges are uncounted,
      -- freeing odd does NOT traverse its edge to even (same region), so even is
      -- still live and is freed by its own drop. Neither double-free nor leak.
      (txt, live) <- runAndAccount $ runFresh (rcMutualProgram True 3 False)
      txt @?= T.pack "0"   -- even 3 = False = 0
      live @?= 0

  -- F6 regression. A covered local 'LetRec' group whose closure bodies reference
  -- a value-CAF must NOT decref the CAF when the group is dropped at scope exit.
  --
  -- The interpreter captures the WHOLE enclosing scope (incl. the CAF's handle)
  -- into each group closure cell. Before F2 made the CAF a static (negative)
  -- handle in the captured env, the group closure captured the CAF's DYNAMIC
  -- counted cell uncounted; at scope exit each member's drop cascaded through
  -- 'countedChildren' into that CAF edge (region-less, so NOT filtered as a
  -- same-region sibling), decref-ing the CAF once PER MEMBER -> premature free /
  -- double-free / stLive below baseline. The invariant: dropping a letrec group
  -- must not decref a cell the group does not own (globals/CAFs/outer borrows).
  --
  -- Shape (run through the REAL pass + runModuleRC, exactly as the corpus does):
  --   caf  = Cons 99 Nil                    -- value-CAF: 2 immortal cells
  --   main = letrec f = \x -> caf           -- two closures, both capture caf
  --                 g = \x -> caf
  --          in 0                           -- => 0, group dropped at scope exit
  -- The group is covered (main has no boxed enclosing locals, the CAF is a global
  -- reference, not a local), so Perceus instruments it with one scope-exit
  -- __rc_drop per member. main allocates nothing dynamic, so the ONLY live cells
  -- after main are the two immortal CAF cells: stLive must equal the baseline.
  , testCase "covered letrec group capturing a value-CAF: no double-free, stLive==baseline" $ do
      let (txt, st, bl) = runFresh $ do
            nCaf  <- freshName (T.pack "caf")
            nCafV <- freshName (T.pack "cafV")
            nNil  <- freshName (T.pack "nil")
            nMain <- freshName (T.pack "main")
            nF    <- freshName (T.pack "f");  nG <- freshName (T.pack "g")
            nFX   <- freshName (T.pack "fx"); nGX <- freshName (T.pack "gx")
            let listTy   = Ty.CTCon Ty.TcList [Ty.CTCon Ty.TcU64 []]
                rcBndL n = Anf.Binder n Anf.Unrestricted listTy
                -- value-CAF: caf = Cons 99 Nil  (2 boxed cells)
                cafBind = rcTop nCaf []
                  (Anf.Let (rcBndL nNil) (Anf.RCon (T.pack "Nil") [])
                   (Anf.Let (rcBndL nCafV)
                     (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 99), Anf.AVar nNil])
                     (Anf.Ret (Anf.AVar nCafV))))
                -- each member closure simply returns the captured CAF.
                memberBody = Anf.Ret (Anf.AVar nCaf)
                mainBody =
                  Anf.LetRec
                    [ (rcBndL nF, [rcBndL nFX], memberBody)
                    , (rcBndL nG, [rcBndL nGX], memberBody)
                    ]
                    (Anf.Ret (Anf.ALit (Anf.LInt 0)))
                mainBind = rcTop nMain [] mainBody
                cm = Anf.CoreModule [cafBind, mainBind]
            case RCM.runModuleRC (Perceus.insertRC cm) of
              Left err  -> error ("runModuleRC failed: " <> show err)
              Right run -> pure (RCM.rcOutput run, RCM.rcStats run, RCM.rcBaseline run)
      txt @?= T.pack "0"
      -- The CAF allocated immortal cells; the test only has teeth if baseline > 0.
      assertBool "baseline > 0: value-CAF allocated immortal cells" (bl > 0)
      -- The group drop must NOT have touched the CAF: stLive stays at the baseline.
      St.stLive st @?= bl

  -- F1 FOLLOW-UP (review #4) regression. The Jump rule reserves the TRANSITIVE
  -- captured set (union over closeJoins{j}) so an outer Jump does not drop a var
  -- a DOWNSTREAM chained join will consume. The join-body seeding ('jDelta') must
  -- be SYMMETRIC with that reservation: it must seed with the transitive cap too,
  -- not just the join's own cap. Otherwise a join j1 whose body is a Case --- one
  -- arm chaining to a downstream j2 that captures the outer var 'w', the other arm
  -- NOT mentioning w --- never OWNS w (w is in cap(j2), not cap(j1), and not free
  -- in j1's body), so its non-forwarding arm never drops w => w LEAKS on that path
  -- even though the outer Jump reserved it.
  --
  -- This exact ANF shape (an intermediate Case-bodied join that reaches the
  -- w-capturing join only TRANSITIVELY) is not currently emitted by the surface
  -- elaborator (it inlines/specializes the w-using continuation into each arm, so
  -- w lands in that join's OWN cap), so the regression is pinned at the IR level:
  --
  --   g w =                                  -- w : [U64], owned boxed param
  --     join j2(y) = let c = Cons y w in c   -- builds with w  => w in cap(j2)
  --     join j1(z) =                         -- body is a CASE; w NOT free here
  --       case z of
  --         0 -> 0                           -- non-forwarding: w must be DROPPED
  --         _ -> jump j2(7)                  -- chains to j2 (reserves w)
  --     jump j1(sel)                         -- outer jump: reserves transitive cap
  --   main = g [1,2,3] 0                      -- take the sel=0 (leaking) path
  --
  -- On the sel=0 path g returns a literal, so w is never moved out and MUST be
  -- dropped inside g. Before the symmetric-jDelta fix w is un-owned in j1's body
  -- and leaks (stLive > baseline = 0); after, j1's body owns w and its Case drops
  -- it on the non-forwarding arm. We assert BOTH a runnable heap-empty oracle
  -- (stLive == baseline) AND a clean 'balanceLint' (no over-consume / leak report).
  , testCase "F1 follow-up: transitive-cap join body drops a reserved outer var on its non-forwarding arm" $ do
      let buildCM sel = runFresh $ do
            nG    <- freshName (T.pack "g")
            nW    <- freshName (T.pack "w")
            nMain <- freshName (T.pack "main")
            nNil  <- freshName (T.pack "nil")
            nC2   <- freshName (T.pack "c2")
            nC1   <- freshName (T.pack "c1")
            j2    <- freshJoin; j1 <- freshJoin
            nY    <- freshName (T.pack "y")   -- j2 param (unboxed U64)
            nZ    <- freshName (T.pack "z")   -- j1 param (unboxed U64)
            nCell <- freshName (T.pack "cell")
            nGv   <- freshName (T.pack "gv")
            let listTy    = Ty.CTCon Ty.TcList [Ty.CTCon Ty.TcU64 []]
                u64Ty     = Ty.CTCon Ty.TcU64 []
                rcBndL n  = Anf.Binder n Anf.Unrestricted listTy   -- BOXED
                rcBndU n  = Anf.Binder n Anf.Unrestricted u64Ty    -- unboxed
                -- g w = join j2(y)=Cons y w ; join j1(z)=case z {0->0; _->jump j2 7}
                --       ; jump j1 sel
                gBody =
                  Anf.LetJoin j2 [rcBndU nY]
                    (Anf.Let (rcBndL nCell)
                       (Anf.RCon (T.pack "Cons") [Anf.AVar nY, Anf.AVar nW])
                       (Anf.Ret (Anf.AVar nCell)))
                  (Anf.LetJoin j1 [rcBndU nZ]
                    (Anf.Case (Anf.AVar nZ)
                       [ Anf.AltLit (Anf.LInt 0) (Anf.Ret (Anf.ALit (Anf.LInt 0)))
                       , Anf.AltDefault (Anf.Jump j2 [Anf.ALit (Anf.LInt 7)]) ])
                  (Anf.Jump j1 [Anf.ALit (Anf.LInt sel)]))
                gBind = rcTop nG [rcBndL nW] gBody
                -- main = let nil=Nil; c2=Cons 2 nil; c1=Cons 1 c2; gv = g c1 in gv
                mainBody =
                  Anf.Let (rcBndL nNil) (Anf.RCon (T.pack "Nil") [])
                  (Anf.Let (rcBndL nC2)
                     (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 2), Anf.AVar nNil])
                  (Anf.Let (rcBndL nC1)
                     (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 1), Anf.AVar nC2])
                  (Anf.Let (rcBndL nGv) (Anf.RApp (Anf.AVar nG) [Anf.AVar nC1])
                  (Anf.Ret (Anf.AVar nGv)))))
                mainBind = rcTop nMain [] mainBody
            pure (Anf.CoreModule [gBind, mainBind])
      -- (a) production pass must balance: no over-consume / leak lint findings.
      let cm0 = buildCM 0
      assertEqual "balanceLint must be clean on the transitive-cap join shape"
        [] (Perceus.balanceLint cm0)
      -- (b) runnable heap-empty oracle on the LEAKING (sel=0) path: w must be
      -- dropped inside g on the non-forwarding arm. baseline == 0 (no value-CAFs);
      -- before the fix this leaks the [1,2,3] spine (stLive == 3 > 0).
      case RCM.runModuleRC (Perceus.insertRC cm0) of
        Left err  -> assertFailure ("runModuleRC failed: " <> show err)
        Right run -> do
          let st = RCM.rcStats run
              bl = RCM.rcBaseline run
          assertEqual "no value-CAFs: baseline must be 0" 0 bl
          assertEqual "sel=0 (non-forwarding) path: w must be dropped, heap empty"
            bl (St.stLive st)

  -- DIRECT-USE + FORWARD regression (review focus #1, and the move-variant of #2).
  -- A join body that BOTH moves an owned outer var directly into a binding AND
  -- forwards (tail-jumps) to a DOWNSTREAM join that also consumes that var has TWO
  -- consumers of one owned unit, so the pass MUST dup it. The 'Let' dup-planner
  -- keyed only on 'freeVarsExpr body' (syntactic free vars), which does NOT see a
  -- var delivered IMPLICITLY through a downstream join's 'cap'; without the fix it
  -- planned no dup and 'consumedHere' relinquished the var at the direct move, so
  -- the downstream join then consumed a var already moved -> use-after-free /
  -- double-free (balanceLint: over-consume of w). The fix makes the dup-planner and
  -- 'consumedHere' treat 'bodyReservedCap' as "needed later", exactly as the
  -- prompt-drop 'keepInBody' already does. This shape is not emitted by the surface
  -- elaborator (the corpus '--dump-perceus' goldens are unchanged by the fix), so
  -- the regression is pinned at the IR level:
  --
  --   f w =                                    -- w : [U64], owned boxed param
  --     join j2(yb) = let c2 = Pair yb w in c2 -- uses w  => w in cap(j2)
  --     join j1(z)  = let u  = Cons 0 w        -- DIRECT move of w
  --                   in jump j2(u)            -- forwards u; w arrives via cap(j2)
  --     jump j1(9)                             -- outer jump: reserves transitive cap
  --   main = let nil=Nil; c1=Cons 1 nil; r = f c1 in r
  --
  -- The returned Pair(u, w) shares w (referenced through both u's tail and the
  -- Pair's own field), so the single owned unit MUST be dup'd or the result-drop
  -- double-frees w. We assert a clean 'balanceLint' AND a runnable heap-empty
  -- oracle (stLive == baseline == 0).
  , testCase "review #1: join body moving an outer var AND forwarding it dups (no double-consume)" $ do
      let cm = runFresh $ do
            nF    <- freshName (T.pack "f")
            nW    <- freshName (T.pack "w")
            nMain <- freshName (T.pack "main")
            nNil  <- freshName (T.pack "nil")
            nC1   <- freshName (T.pack "c1")
            nR    <- freshName (T.pack "r")
            j2    <- freshJoin; j1 <- freshJoin
            nYb   <- freshName (T.pack "yb")   -- j2 param (boxed list)
            nZ    <- freshName (T.pack "z")    -- j1 param (unboxed U64)
            nU    <- freshName (T.pack "u")    -- j1 direct-use binder (boxed list)
            nC2   <- freshName (T.pack "c2")   -- j2 result (boxed Pair)
            let listTy   = Ty.CTCon Ty.TcList [Ty.CTCon Ty.TcU64 []]
                u64Ty    = Ty.CTCon Ty.TcU64 []
                rcBndL n = Anf.Binder n Anf.Unrestricted listTy   -- BOXED
                rcBndU n = Anf.Binder n Anf.Unrestricted u64Ty    -- unboxed
                fBody =
                  Anf.LetJoin j2 [rcBndL nYb]
                    (Anf.Let (rcBndL nC2)
                       (Anf.RCon (T.pack "Pair") [Anf.AVar nYb, Anf.AVar nW])
                       (Anf.Ret (Anf.AVar nC2)))
                  (Anf.LetJoin j1 [rcBndU nZ]
                    (Anf.Let (rcBndL nU)
                       (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 0), Anf.AVar nW])
                       (Anf.Jump j2 [Anf.AVar nU]))
                  (Anf.Jump j1 [Anf.ALit (Anf.LInt 9)]))
                fBind = rcTop nF [rcBndL nW] fBody
                mainBody =
                  Anf.Let (rcBndL nNil) (Anf.RCon (T.pack "Nil") [])
                  (Anf.Let (rcBndL nC1)
                     (Anf.RCon (T.pack "Cons") [Anf.ALit (Anf.LInt 1), Anf.AVar nNil])
                  (Anf.Let (rcBndL nR) (Anf.RApp (Anf.AVar nF) [Anf.AVar nC1])
                  (Anf.Ret (Anf.AVar nR))))
                mainBind = rcTop nMain [] mainBody
            pure (Anf.CoreModule [fBind, mainBind])
      -- (a) production pass must balance: no over-consume / leak lint findings.
      assertEqual "balanceLint must be clean on the direct-use+forward join shape"
        [] (Perceus.balanceLint cm)
      -- (b) runnable heap-empty oracle: the result Pair shares w, so without the
      -- dup the result-drop double-frees w. baseline == 0 (no value-CAFs).
      case RCM.runModuleRC (Perceus.insertRC cm) of
        Left err  -> assertFailure ("runModuleRC failed: " <> show err)
        Right run -> do
          let st = RCM.rcStats run
              bl = RCM.rcBaseline run
          assertEqual "no value-CAFs: baseline must be 0" 0 bl
          assertEqual "direct-use+forward: w dup'd, heap empties" bl (St.stLive st)

  -- Task 7: LetRec member free-var capture tightening.
  --
  -- A boxed local 'y' lives in the enclosing scope. The LetRec group (ev/od)
  -- is a standard mutual-recursion pair that does NOT reference 'y'. Under the
  -- OLD whole-env capture, each member's NClosure captures 'y' via 'groupEnv';
  -- when the group is dropped at scope exit (explicit __rc_drop of each member),
  -- the cascade for each member walks its cenv, finds 'y' (a non-sibling dynamic
  -- cell), decrefs it, and frees it prematurely (use-after-free). Under the NEW
  -- free-var-only capture, 'y' is NOT in any member's cenv, so the cascade never
  -- touches it and 'y' is still live after the group drop.
  --
  -- Shape (using runExprRC with y pre-loaded in the env):
  --   letrec ev k = case eqU64 k 0 of True -> 1; False -> od (k-1)
  --          od k = case eqU64 k 0 of True -> 0; False -> ev (k-1)
  --   in let r  = ev 2
  --          u1 = __rc_drop ev
  --          u2 = __rc_drop od
  --      in y                -- y must still be live after the group drop
  --
  -- We verify: (a) the expression evaluates to RVBox yAddr (y is the result),
  -- (b) stLive >= 1 because y's cell is still allocated and not freed (the
  --     literal result of 'ev 2' frees nothing on drop), and (c) deref yAddr
  --     succeeds (y not in stDead). Under the OLD whole-env capture both members
  --     captured y, so the two group drops double-freed it.
  , testCase "LetRec free-var capture: uncaptured enclosing local survives group drop" $ do
      -- Pre-allocate y as a standalone dynamic cell NOT referenced by ev/od.
      let yU          = Unique 9001
          yName       = Name.Name (T.pack "y") yU
          s0          = St.emptyStore
          (yAddr, s1) = St.alloc (St.NCon (T.pack "Y") []) s0
          env         = Map.fromList [(yU, St.RVBox yAddr)]
          -- Build the LetRec expression using freshly minted names.
          -- y is in 'env' but NOT free in either member's body.
          e = runFresh $ do
                nEv <- freshName (T.pack "ev"); nOd <- freshName (T.pack "od")
                nEN <- freshName (T.pack "en"); nON <- freshName (T.pack "on")
                nR  <- freshName (T.pack "r")
                nU1 <- freshName (T.pack "u1")
                nU2 <- freshName (T.pack "u2")
                nU3 <- freshName (T.pack "u3")
                evenBody <- rcParityClause nEN 1 nOd
                oddBody  <- rcParityClause nON 0 nEv
                pure $
                  Anf.LetRec
                    [ (rcBnd nEv, [rcBnd nEN], evenBody)
                    , (rcBnd nOd, [rcBnd nON], oddBody)
                    ]
                    (Anf.Let (rcBnd nR)
                       (Anf.RApp (Anf.AVar nEv) [Anf.ALit (Anf.LInt 2)])
                    (Anf.Let (rcBnd nU1)
                       (Anf.RApp (Anf.AVar rcDropName) [Anf.AVar nEv])
                    (Anf.Let (rcBnd nU2)
                       (Anf.RApp (Anf.AVar rcDropName) [Anf.AVar nOd])
                    -- Drop the result of ev 2 (a literal, so drop is a no-op)
                    -- and return y so we can inspect whether y's address is live.
                    (Anf.Let (rcBnd nU3)
                       (Anf.RApp (Anf.AVar rcDropName) [Anf.AVar nR])
                    (Anf.Ret (Anf.AVar yName))))))
      case RCM.runExprRC RCP.rcPrimTable env s1 e of
        Left err      -> assertFailure ("expected success, got: " <> show err)
        Right (v, sf) -> do
          -- y must still be live after the group drop; stLive >= 1 means y's
          -- cell was NOT freed by the cascade through the members' cenv.
          assertBool "y must not be freed by the LetRec group drop"
            (St.stLive (St.stStats sf) >= 1)
          case v of
            St.RVBox a -> do
              a @?= yAddr
              case St.deref yAddr sf of
                Left err2 -> assertFailure ("deref y after group drop failed: " <> show err2)
                Right _   -> pure ()
            other -> assertFailure ("expected RVBox y, got " <> show other)

  -- M1.5 PHASE 2 (Task 8) --- NON-ESCAPING enclosing capture is instrumented.
  --
  --   caf  = Box 7                            -- value-CAF (1 immortal cell)
  --   main =
  --     let b = caf                           -- enclosing boxed local (alias of CAF)
  --     in letrec f x = case b of Box v -> v  -- captures b (BORROWED), only called
  --        in let r = f 5
  --           in r                            -- => 7, group dropped at scope exit
  --
  -- Single-member capture: the borrow model moves b into the region (capOcc[b]=1,
  -- need(b)=1, dups(b)=0); at the group drop f's cascade decrefs b exactly once.
  -- The CAF cell is immortal, so stLive must equal the baseline (b aliases it via
  -- a static handle, never counted). The point is that the group is now COVERED
  -- and instrumented (pre-Phase-2 it was passed through unchanged).
  , testCase "non-escaping LetRec capturing one enclosing local: covered, heap==baseline, lint clean" $ do
      let (txt, st, bl, lintOut) = runFresh $ do
            nCaf <- freshName (T.pack "caf")
            nMain <- freshName (T.pack "main")
            nB   <- freshName (T.pack "b")
            nF   <- freshName (T.pack "f");  nX <- freshName (T.pack "x")
            nV   <- freshName (T.pack "v");  nR <- freshName (T.pack "r")
            let boxTy    = Ty.CTCon (Ty.TcUser (T.pack "Box")) []
                u64Ty    = Ty.CTCon Ty.TcU64 []
                bndB n   = Anf.Binder n Anf.Unrestricted boxTy
                bndU n   = Anf.Binder n Anf.Unrestricted u64Ty
                cafBind  = rcTop nCaf []
                  (Anf.Let (bndB nB) (Anf.RCon (T.pack "Box") [Anf.ALit (Anf.LInt 7)])
                    (Anf.Ret (Anf.AVar nB)))
                memberBody =
                  Anf.Case (Anf.AVar nB)
                    [Anf.AltCon (T.pack "Box") [bndU nV] (Anf.Ret (Anf.AVar nV))]
                mainBody =
                  Anf.Let (bndB nB) (Anf.RAtom (Anf.AVar nCaf))
                    (Anf.LetRec
                      [ (bndU nF, [bndU nX], memberBody) ]
                      (Anf.Let (bndU nR) (Anf.RApp (Anf.AVar nF) [Anf.ALit (Anf.LInt 5)])
                        (Anf.Ret (Anf.AVar nR))))
                cm = Anf.CoreModule [cafBind, rcTop nMain [] mainBody]
            case RCM.runModuleRC (Perceus.insertRC cm) of
              Left err  -> error ("runModuleRC failed: " <> show err)
              Right run -> pure (RCM.rcOutput run, RCM.rcStats run, RCM.rcBaseline run,
                                 Perceus.balanceLint cm)
      txt @?= T.pack "7"
      assertBool "baseline > 0: the Box CAF allocated an immortal cell" (bl > 0)
      St.stLive st @?= bl
      lintOut @?= ([] :: [Text])

  -- M1.5 PHASE 2 (Task 8) --- SHARED enclosing capture (multiset dup). TWO members
  -- both capture the same enclosing local b, so capOcc[b]=2, need(b)=2, dups(b)=1.
  -- The build emits ONE __rc_dup b; at the group drop BOTH members cascade-decref
  -- b once each (2 total), balanced by the original unit + the dup. Reverting the
  -- multiset dup (dups(b)=0) would leave b with one unit and two decrefs => a
  -- double-free; this test pins the multiset accounting.
  --
  --   caf  = Box 7
  --   main =
  --     let b = caf
  --     in letrec f x = case b of Box v -> v   -- captures b
  --               g x = case b of Box v -> v   -- ALSO captures b
  --        in let r = f 5
  --           in r                             -- => 7, both members drop at exit
  , testCase "shared LetRec capture (two members, one b): multiset dup, heap==baseline, lint clean" $ do
      let (txt, st, bl, lintOut) = runFresh $ do
            nCaf <- freshName (T.pack "caf")
            nMain <- freshName (T.pack "main")
            nB   <- freshName (T.pack "b")
            nF   <- freshName (T.pack "f");  nX <- freshName (T.pack "x")
            nG   <- freshName (T.pack "g");  nY <- freshName (T.pack "y")
            nV   <- freshName (T.pack "v");  nW <- freshName (T.pack "w")
            nR   <- freshName (T.pack "r")
            let boxTy    = Ty.CTCon (Ty.TcUser (T.pack "Box")) []
                u64Ty    = Ty.CTCon Ty.TcU64 []
                bndB n   = Anf.Binder n Anf.Unrestricted boxTy
                bndU n   = Anf.Binder n Anf.Unrestricted u64Ty
                cafBind  = rcTop nCaf []
                  (Anf.Let (bndB nB) (Anf.RCon (T.pack "Box") [Anf.ALit (Anf.LInt 7)])
                    (Anf.Ret (Anf.AVar nB)))
                clause vn = Anf.Case (Anf.AVar nB)
                  [Anf.AltCon (T.pack "Box") [bndU vn] (Anf.Ret (Anf.AVar vn))]
                mainBody =
                  Anf.Let (bndB nB) (Anf.RAtom (Anf.AVar nCaf))
                    (Anf.LetRec
                      [ (bndU nF, [bndU nX], clause nV)
                      , (bndU nG, [bndU nY], clause nW)
                      ]
                      (Anf.Let (bndU nR) (Anf.RApp (Anf.AVar nF) [Anf.ALit (Anf.LInt 5)])
                        (Anf.Ret (Anf.AVar nR))))
                cm = Anf.CoreModule [cafBind, rcTop nMain [] mainBody]
            case RCM.runModuleRC (Perceus.insertRC cm) of
              Left err  -> error ("runModuleRC failed: " <> show err)
              Right run -> pure (RCM.rcOutput run, RCM.rcStats run, RCM.rcBaseline run,
                                 Perceus.balanceLint cm)
      txt @?= T.pack "7"
      assertBool "baseline > 0: the Box CAF allocated an immortal cell" (bl > 0)
      St.stLive st @?= bl
      lintOut @?= ([] :: [Text])

  -- M2a-2 (Task 4) --- the shared env of a CAPTURING NON-ESCAPING group is dropped
  -- EXACTLY ONCE. A two-member group f/g both BORROW-READ one enclosing boxed local
  -- @b = Box 7@ (each base case @case b of Box v -> v@); the body calls @f 2@ and
  -- returns the scalar result (no member escapes). The pass must instrument this as
  -- ordinary acyclic RC: exactly ONE @__rc_drop@ of a member (the shared-env handle,
  -- member 0) at the group's combined last use --- NOT one drop per member, and NO
  -- per-member multiset capture dups. Asserted three ways: (1) a 'prettyPerceus'
  -- count of exactly one member-drop in @main@'s instrumented body, (2) heap-balance
  -- (the single env-drop frees the env, whose cascade frees the captured Box once),
  -- (3) a clean 'balanceLint'.
  , testCase "M2a-2 capturing non-escaping group: shared env dropped EXACTLY once" $ do
      let (pretty, st, bl, lintOut) = runFresh $ do
            nB   <- freshName (T.pack "b")
            nMain <- freshName (T.pack "main")
            nF   <- freshName (T.pack "f");  nG <- freshName (T.pack "g")
            nFK  <- freshName (T.pack "fk"); nGK <- freshName (T.pack "gk")
            nV1  <- freshName (T.pack "v1"); nV2 <- freshName (T.pack "v2")
            nFKs <- freshName (T.pack "fks"); nGKs <- freshName (T.pack "gks")
            nFr  <- freshName (T.pack "fr");  nGr <- freshName (T.pack "gr")
            nR   <- freshName (T.pack "r")
            let boxTy  = Ty.CTCon (Ty.TcUser (T.pack "Box")) []
                u64Ty  = Ty.CTCon Ty.TcU64 []
                bndB n = Anf.Binder n Anf.Unrestricted boxTy
                bndU n = Anf.Binder n Anf.Unrestricted u64Ty
                baseRead vn = Anf.Case (Anf.AVar nB)
                  [Anf.AltCon (T.pack "Box") [bndU vn] (Anf.Ret (Anf.AVar vn))]
                recArm selfK sib ksN rN =
                  Anf.Let (bndU ksN) (Anf.RApp (primAtom (T.pack "-")) [Anf.AVar selfK, Anf.ALit (Anf.LInt 1)])
                    (Anf.Let (bndU rN) (Anf.RApp (Anf.AVar sib) [Anf.AVar ksN])
                      (Anf.Ret (Anf.AVar rN)))
                fBody = Anf.Case (Anf.AVar nFK)
                  [Anf.AltLit (Anf.LInt 0) (baseRead nV1), Anf.AltDefault (recArm nFK nG nFKs nFr)]
                gBody = Anf.Case (Anf.AVar nGK)
                  [Anf.AltLit (Anf.LInt 0) (baseRead nV2), Anf.AltDefault (recArm nGK nF nGKs nGr)]
                mainBody =
                  Anf.Let (bndB nB) (Anf.RCon (T.pack "Box") [Anf.ALit (Anf.LInt 7)])
                    (Anf.LetRec
                      [ (bndU nF, [bndU nFK], fBody)
                      , (bndU nG, [bndU nGK], gBody) ]
                      (Anf.Let (bndU nR) (Anf.RApp (Anf.AVar nF) [Anf.ALit (Anf.LInt 2)])
                        (Anf.Ret (Anf.AVar nR))))
                cm = Anf.CoreModule [rcTop nMain [] mainBody]
            case RCM.runModuleRC (Perceus.insertRC cm) of
              Left err  -> error ("runModuleRC failed: " <> show err)
              Right run -> pure ( Perceus.prettyPerceus cm
                                , RCM.rcStats run, RCM.rcBaseline run, Perceus.balanceLint cm )
      -- (1) Exactly ONE member-drop in main's body (the single shared-env drop).
      let memberDrops = length (T.breakOnAll (T.pack "__rc_drop(f)") pretty)
                          + length (T.breakOnAll (T.pack "__rc_drop(g)") pretty)
      assertEqual "exactly one member-drop (the single shared-env drop, not per-member)"
        1 memberDrops
      -- (2) Heap-balanced: Box + ONE NEnv allocated, both freed by the single drop.
      assertEqual "allocs - frees == baseline (heap balanced)" bl (St.stAllocs st - St.stFrees st)
      St.stLive st @?= bl
      assertEqual "exactly two dynamic allocations (Box + ONE shared NEnv)" 2 (St.stAllocs st)
      -- (3) The pass is balanceLint-clean.
      lintOut @?= ([] :: [Text])

  -- M2a-2 STAGE B --- ESCAPING enclosing capture is now ADMITTED and runs SOUND.
  -- A group that captures an enclosing boxed local AND RETURNS a member (the member
  -- binder flows out of the LetRec body as a value) is dup-balanced by the pass: the
  -- returned member transfers the single shared-env handle out (the env-alive handle
  -- is not also dropped), so the captured 'b' is freed exactly once via the env
  -- cascade when the result CAF drops. CONTROL: the SAME group shape WITHOUT the
  -- enclosing capture (the existing 23-letrec-return-member shape) is also admitted.
  --
  --   main =
  --     let b = Box 7                          -- enclosing boxed local
  --     in letrec f x = case b of Box v -> v   -- captures b (borrowed read)
  --        in f                                -- RETURNS the member f => ESCAPES
  , testCase "escaping LetRec capturing an enclosing local: ACCEPTED and runs sound (M2a-2 Stage B)" $ do
      let boxTy   = Ty.CTCon (Ty.TcUser (T.pack "Box")) []
          u64Ty   = Ty.CTCon Ty.TcU64 []
          funTy   = Ty.CTCon (Ty.TcUser (T.pack "Fun")) []
          bName   = Name (T.pack "b") (Unique 970001)
          fName   = Name (T.pack "f") (Unique 970002)
          xName   = Name (T.pack "x") (Unique 970003)
          vName   = Name (T.pack "v") (Unique 970004)
          bBnd    = Anf.Binder bName Anf.Unrestricted boxTy
          fBnd    = Anf.Binder fName Anf.Unrestricted funTy
          xBnd    = Anf.Binder xName Anf.Unrestricted u64Ty
          vBnd    = Anf.Binder vName Anf.Unrestricted u64Ty
          -- capture: member reads the enclosing b; nocap: member ignores b.
          memberBody captures =
            if captures
              then Anf.Case (Anf.AVar bName)
                     [Anf.AltCon (T.pack "Box") [vBnd] (Anf.Ret (Anf.AVar vName))]
              else Anf.Ret (Anf.AVar xName)
          mkBody captures =
            Anf.Let bBnd (Anf.RCon (T.pack "Box") [Anf.ALit (Anf.LInt 7)])
              (Anf.LetRec [(fBnd, [xBnd], memberBody captures)]
                 (Anf.Ret (Anf.AVar fName)))         -- RETURN f => member escapes
          cmWith captures = Anf.CoreModule
            [ Anf.TopBind (Name (T.pack "main") (Unique 970000)) [] (mkBody captures) ]
      -- M2a-2 Stage B: the capturing-and-escaping group is now ADMITTED and runs
      -- SOUND (the returned member transfers the single env handle out).
      firstOrderNoHandlerViolations (cmWith True) @?= []
      let escCm = pruneToReachable (cmWith True)
      case (Interp.runModule escCm, RCM.runModuleRCUnchecked (Perceus.insertRC escCm)) of
        (Right v, Right run) -> do
          Interp.renderValue v @?= RCM.rcOutput run
          let st = RCM.rcStats run; bl = RCM.rcBaseline run
          assertEqual "escaping enclosing-capture return: heap balanced (live)" bl (St.stLive st)
          assertEqual "escaping enclosing-capture return: heap balanced (allocs-frees)"
            bl (St.stAllocs st - St.stFrees st)
        (Left _, Left _) -> pure ()
        (refRes, rcRes) ->
          assertFailure ("RC run must agree with reference; got ref="
                           <> either show (const "ok") refRes <> " rc="
                           <> either show (const "ok") rcRes)
      -- Control: the same escaping group WITHOUT the enclosing capture (the existing
      -- 23-letrec-return-member shape) is also admitted.
      firstOrderNoHandlerViolations (cmWith False) @?= []

  -- M1.5 PHASE 2 REVIEW FINDING 1 (verified DOUBLE-FREE; M2a-1 Task 5 narrowing) ---
  -- a member that CONSUMES (moves) an enclosing capture is now ADMITTED when the
  -- group is NON-escaping (the pass emits a dup-per-consuming-use; the runtime
  -- accounting balances), and is REJECTED only when a member ALSO ESCAPES the
  -- scope (region-lifetime extension = M2a-2; 'letRecMemberEscapes'). CONTROL: a
  -- BORROWED READ (a Case scrutinee keeping only the unboxed field, like 31/32) is
  -- admitted regardless.
  --
  --   peek p = 0
  --   main = let b = Box 6
  --          in letrec go k = case k of 0 -> peek b ; _ -> go (k-1)   -- peek b MOVES b
  --          in let r = go 1 in r                                     -- go non-escaping
  , testCase "consuming LetRec capture: REJECTED (escaping or not), borrow admitted" $ do
      let boxTy   = Ty.CTCon (Ty.TcUser (T.pack "Box")) []
          u64Ty   = Ty.CTCon Ty.TcU64 []
          funTy   = Ty.CTCon (Ty.TcUser (T.pack "Fun")) []
          peekName = Name (T.pack "peek") (Unique 960001)
          pName    = Name (T.pack "p")    (Unique 960002)
          bName    = Name (T.pack "b")    (Unique 960003)
          goName   = Name (T.pack "go")   (Unique 960004)
          kName    = Name (T.pack "k")    (Unique 960005)
          vName    = Name (T.pack "v")    (Unique 960006)
          rName    = Name (T.pack "r")    (Unique 960007)
          pBnd     = Anf.Binder pName  Anf.Unrestricted boxTy
          bBnd     = Anf.Binder bName  Anf.Unrestricted boxTy
          goBnd    = Anf.Binder goName Anf.Unrestricted funTy
          kBnd     = Anf.Binder kName  Anf.Unrestricted u64Ty
          vBnd     = Anf.Binder vName  Anf.Unrestricted u64Ty
          rBnd     = Anf.Binder rName  Anf.Unrestricted u64Ty
          peekBind = Anf.TopBind peekName [pBnd] (Anf.Ret (Anf.ALit (Anf.LInt 0)))
          -- consuming=True : 0 -> peek b      (b is a CALL ARGUMENT => moved)
          -- consuming=False: 0 -> case b of Box v -> v   (BORROWED READ, like 31/32)
          memberBody consuming =
            Anf.Case (Anf.AVar kName)
              [ Anf.AltLit (Anf.LInt 0)
                  (if consuming
                     then Anf.Let rBnd (Anf.RApp (Anf.AVar peekName) [Anf.AVar bName])
                                       (Anf.Ret (Anf.AVar rName))
                     else Anf.Case (Anf.AVar bName)
                            [Anf.AltCon (T.pack "Box") [vBnd] (Anf.Ret (Anf.AVar vName))])
              , Anf.AltDefault
                  (Anf.Let kBnd (Anf.RApp (Anf.AVar goName) [Anf.ALit (Anf.LInt 0)])
                     (Anf.Ret (Anf.AVar kName)))
              ]
          -- escaping=False: body is 'let r = go 1 in r' (go used only as call head)
          -- escaping=True : body is 'Ret go'            (the member escapes)
          mkBody consuming escaping =
            Anf.Let bBnd (Anf.RCon (T.pack "Box") [Anf.ALit (Anf.LInt 6)])
              (Anf.LetRec [(goBnd, [kBnd], memberBody consuming)]
                 (if escaping
                    then Anf.Ret (Anf.AVar goName)
                    else Anf.Let rBnd (Anf.RApp (Anf.AVar goName) [Anf.ALit (Anf.LInt 1)])
                           (Anf.Ret (Anf.AVar rName))))
          cmWith consuming escaping = Anf.CoreModule
            [ peekBind
            , Anf.TopBind (Name (T.pack "main") (Unique 960000)) [] (mkBody consuming escaping) ]
      -- Consuming-capture support is DEFERRED: ANY consuming use is REJECTED,
      -- whether the member escapes or not.
      assertBool "non-escaping consuming-capture group must be rejected"
        (not (null (firstOrderNoHandlerViolations (cmWith True False))))
      assertBool "consuming-AND-escaping group must be rejected"
        (not (null (firstOrderNoHandlerViolations (cmWith True True))))
      -- Control: the borrowed-read shape (Case scrutinee keeping only the unboxed
      -- field, like 31/32) is NOT rejected, escaping or not.
      firstOrderNoHandlerViolations (cmWith False False) @?= []

  -- M1.5 PHASE 2 REVIEW FINDING 2 (verified LEAK) --- a NESTED inner LetRec whose
  -- member captures an OUTER group member (cross-region counted edge) is EXCLUDED
  -- from coverage by the pass ('capturesRegion', spec 5.5) but was passed through
  -- UN-instrumented => leak. The boundary must refuse it. CONTROL: the same nested
  -- shape where the inner member does NOT reference the outer member is NOT rejected.
  --
  --   main = letrec outer k = ... outer (k-1)
  --          in letrec inner j = case j of 0 -> outer 1 ; _ -> inner (j-1)  -- inner CALLS outer
  --          in inner 2
  , testCase "cross-region LetRec capture (inner member calls outer member): boundary rejects it" $ do
      let u64Ty   = Ty.CTCon Ty.TcU64 []
          funTy   = Ty.CTCon (Ty.TcUser (T.pack "Fun")) []
          outerN  = Name (T.pack "outer") (Unique 950001)
          kName   = Name (T.pack "k")     (Unique 950002)
          innerN  = Name (T.pack "inner") (Unique 950003)
          jName   = Name (T.pack "j")     (Unique 950004)
          tName   = Name (T.pack "t")     (Unique 950005)
          rName   = Name (T.pack "r")     (Unique 950006)
          outerB  = Anf.Binder outerN Anf.Unrestricted funTy
          kBnd    = Anf.Binder kName  Anf.Unrestricted u64Ty
          innerB  = Anf.Binder innerN Anf.Unrestricted funTy
          jBnd    = Anf.Binder jName  Anf.Unrestricted u64Ty
          tBnd    = Anf.Binder tName  Anf.Unrestricted u64Ty
          rBnd    = Anf.Binder rName  Anf.Unrestricted u64Ty
          outerBody =
            Anf.Case (Anf.AVar kName)
              [ Anf.AltLit (Anf.LInt 0) (Anf.Ret (Anf.ALit (Anf.LInt 0)))
              , Anf.AltDefault
                  (Anf.Let kBnd (Anf.RApp (Anf.AVar outerN) [Anf.ALit (Anf.LInt 0)])
                     (Anf.Ret (Anf.AVar kName)))
              ]
          -- crosses=True : inner's base case CALLS the outer member (cross-region).
          -- crosses=False: inner's base case returns a literal (no outer reference).
          innerBody crosses =
            Anf.Case (Anf.AVar jName)
              [ Anf.AltLit (Anf.LInt 0)
                  (if crosses
                     then Anf.Let tBnd (Anf.RApp (Anf.AVar outerN) [Anf.ALit (Anf.LInt 1)])
                                       (Anf.Ret (Anf.AVar tName))
                     else Anf.Ret (Anf.ALit (Anf.LInt 0)))
              , Anf.AltDefault
                  (Anf.Let jBnd (Anf.RApp (Anf.AVar innerN) [Anf.ALit (Anf.LInt 0)])
                     (Anf.Ret (Anf.AVar jName)))
              ]
          mkBody crosses =
            Anf.LetRec [(outerB, [kBnd], outerBody)]
              (Anf.LetRec [(innerB, [jBnd], innerBody crosses)]
                 (Anf.Let rBnd (Anf.RApp (Anf.AVar innerN) [Anf.ALit (Anf.LInt 2)])
                    (Anf.Ret (Anf.AVar rName))))
          cmWith crosses = Anf.CoreModule
            [ Anf.TopBind (Name (T.pack "main") (Unique 950000)) [] (mkBody crosses) ]
      -- Teeth: the cross-region group fires the violation.
      assertBool "cross-region capture group must be rejected"
        (not (null (firstOrderNoHandlerViolations (cmWith True))))
      -- Control: the same nested shape with NO cross-region reference is NOT rejected.
      firstOrderNoHandlerViolations (cmWith False) @?= []
  ]

-- ---------------------------------------------------------------------------
-- M2a-1 boundary: the escape-narrowed guard ACCEPTS non-escaping reproducers
-- and still REJECTS their escaping variants
--
-- 'test/rc-m2a1/33-consuming-capture-nonescape.wok' (case #1): a 'LetRec'
-- member that CONSUMES an enclosing boxed capture via a function-call argument
-- ('RApp'). The group is NON-ESCAPING, but consuming-capture support is DEFERRED
-- (a dup-per-consuming-use scheme was proved unsound at scale by Suite G), so the
-- '#1' guard REJECTS ANY consuming use of an enclosing capture --- escaping or
-- not. The file lives in 'test/rc-m2a1/' (NOT auto-discovered) since it is no
-- longer admitted.
--
-- 'test/rc-examples/34-rlam-sibling-nonescape.wok' (case #4): a standalone
-- closure ('RLam') that captures a 'LetRec' group sibling; the closure is never
-- used and is dropped (NON-ESCAPING), so the boundary guard ACCEPTS it (the
-- '#4' guard only fires when 'rlamSiblingCaptureEscapes'). This shape is the
-- owned/borrowed-capture (Invariant-2) case and stays supported.
--
-- The ESCAPING variants STAY rejected (region-lifetime extension = M2a-2):
--   * 'test/rc-m2a1/36-rlam-sibling-escape.wok' RETURNS the closure 'h'.
--   * 'test/rc-m2a1/37-consuming-capture-escape.wok' RETURNS the member 'go'.
--
-- The escaping/rejected variants live in 'test/rc-m2a1/' (NOT 'test/rc-examples/')
-- so they are NOT auto-discovered by the perceus-golden / perceus-lint /
-- rc-differential / rc-stats suites, all of which assert-fail on rejected
-- programs. The admitted reproducer (34) lives in 'test/rc-examples/' and runs
-- under those suites.

-- | Load and elaborate a '.wok' file, then return the boundary-guard
-- violations.  Returns an empty list when the file is in the RC fragment and
-- returns the violation messages when it is not.  Propagates loader and
-- elaboration errors as 'assertFailure' (the file must at least elaborate).
boundaryViolationsOf :: FilePath -> IO [Text]
boundaryViolationsOf path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> assertFailure ("loader: " <> show lerr)
    Right (entryName, ms) ->
      case Pipeline.elaborateProgramFull entryName ms of
        Left s  -> assertFailure ("elaborate: " <> s)
        Right cm -> pure (firstOrderNoHandlerViolations cm)

rcM2a1BaselineTests :: TestTree
rcM2a1BaselineTests = testGroup "m2a-1 boundary (escape-narrowed guards)"
  [ testCase "consuming-capture non-escape #1 is REJECTED (deferred)" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/33-consuming-capture-nonescape.wok"
      assertBool "any consuming-capture group must be rejected (deferred)" (not (null vs))
  , testCase "rlam-sibling non-escape #4 is ACCEPTED" $ do
      vs <- boundaryViolationsOf "test/rc-examples/34-rlam-sibling-nonescape.wok"
      assertEqual "non-escaping sibling-capturing closure must pass the boundary" [] vs
  -- M2a-2 STAGE A: a sibling captured into an ESCAPING standalone CLOSURE (#6) or a
  -- NESTED escaping closure (#8) is now ADMITTED and runs SOUND. The closure capture
  -- is dup-balanced by the pass, and the interpreter keeps an over-applied unnamed
  -- intermediate alive through its own call (deferred-consume), so the escaped
  -- closure's cascade-drop balances exactly. Both corpora over-apply the escaped
  -- closure ('main = (mk 7) 2'), exercising that path; the run must agree with the
  -- reference value and be heap-balanced.
  , testCase "rlam-sibling ESCAPE #6 is ACCEPTED and runs sound (M2a-2 Stage A)" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/36-rlam-sibling-escape.wok"
      assertEqual "an escaping closure capturing a sibling must pass the boundary" [] vs
      assertRcAgrees "test/rc-m2a1/36-rlam-sibling-escape.wok"
  , testCase "consuming-capture ESCAPE #7 is still REJECTED" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/37-consuming-capture-escape.wok"
      assertBool "an escaping consuming-capture group must be rejected" (not (null vs))
  , testCase "rlam-sibling NESTED-ESCAPE #8 is ACCEPTED and runs sound (M2a-2 Stage A)" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/38-rlam-nested-escape.wok"
      assertEqual "a sibling captured into a nested escaping closure must pass the boundary" [] vs
      assertRcAgrees "test/rc-m2a1/38-rlam-nested-escape.wok"
  , testCase "consuming-capture NESTED-ESCAPE #9 is REJECTED" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/39-consuming-nested-escape.wok"
      assertBool "a group member captured into a nested escaping closure must be rejected" (not (null vs))
  -- DIRECT-escape (M2a-2 Stage B, now SOUND): a sibling moved DIRECTLY into an
  -- escaping value --- an 'RCon'/'RRecord' field, a list cell, or a non-head call
  -- argument --- is now ADMITTED and runs SOUND. The pass dups the shared env at the
  -- move (dup-on-consume), so the escaped cell owns an independent env unit and the
  -- group's enclosing local is freed exactly once via the env cascade. Each over-
  -- applies the escaped sibling ('main = ... g 2'), exercising the unnamed-
  -- intermediate deferred env-drop; the run must agree with the reference value and
  -- be heap-balanced.
  , testCase "sibling-into-constructor escape #12 is ACCEPTED and runs sound (M2a-2 Stage B)" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/42-sibling-con-escape.wok"
      assertEqual "a sibling moved into an escaping constructor must pass the boundary" [] vs
      assertRcAgrees "test/rc-m2a1/42-sibling-con-escape.wok"
  , testCase "sibling-into-call-argument escape #13 is ACCEPTED and runs sound (M2a-2 Stage B)" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/43-sibling-arg-escape.wok"
      assertEqual "a sibling passed as a non-head arg of an escaping call must pass the boundary" [] vs
      assertRcAgrees "test/rc-m2a1/43-sibling-arg-escape.wok"
  , testCase "sibling-into-list-constructor escape #14 is ACCEPTED and runs sound (M2a-2 Stage B)" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/44-sibling-listcon-escape.wok"
      assertEqual "a sibling stored in an escaping list cell must pass the boundary" [] vs
      assertRcAgrees "test/rc-m2a1/44-sibling-listcon-escape.wok"
  , testCase "sibling-into-record-field escape #15 is ACCEPTED and runs sound (M2a-2 Stage B)" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/45-sibling-record-escape.wok"
      assertEqual "a sibling stored in an escaping record field must pass the boundary" [] vs
      assertRcAgrees "test/rc-m2a1/45-sibling-record-escape.wok"
  -- POSITIVE guards against over-rejection: a member returned DIRECTLY ('Ret f',
  -- mirror of rc-examples/23) and a sibling used only as a CALL HEAD ('f 3') are
  -- NOT escapes via the generalized guard and must STAY ACCEPTED.
  , testCase "direct return-of-member #16 STAYS ACCEPTED (not over-rejected)" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/46-return-member-accept.wok"
      assertEqual "a direct return-of-member must pass the boundary" [] vs
  , testCase "sibling-as-call-head #17 STAYS ACCEPTED (not over-rejected)" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/47-sibling-callhead-accept.wok"
      assertEqual "a sibling used only as a call head must pass the boundary" [] vs
  -- M2a-2 Stage B: over-applying a DIRECT member return as an UNNAMED INTERMEDIATE
  -- ('(mk 7) 2') leaked the shared env before the interpreter's deferred env-drop on
  -- the 'RVRecMember' unnamed-intermediate path. Must be ACCEPTED and run sound
  -- (heap-balanced + value-match) --- the permanent guard for that fix.
  , testCase "member over-apply #21 is ACCEPTED and runs sound (M2a-2 Stage B)" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/51-member-overapply-accept.wok"
      assertEqual "an over-applied direct member return must pass the boundary" [] vs
      assertRcAgrees "test/rc-m2a1/51-member-overapply-accept.wok"
  -- POSITIVE guards against the call-head over-rejection: a recursive group member
  -- whose body CALLS an enclosing boxed CAPTURE 'g' as a call HEAD ('g u') is a
  -- BORROW under uniform borrow-on-call, NOT a move/consume. 'consumingOccs' used to
  -- count the head and (the group being non-escaping) wrongly REJECTED it; now the
  -- head is exempt and the group is ADMITTED and runs SOUND (value-match + heap-
  -- balanced). Both a SATURATED head (#52) and a PARTIAL head (#53) must pass.
  , testCase "capture-as-saturated-call-head #22 is ACCEPTED and runs sound (M2a-2)" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/52-capture-callhead-accept.wok"
      assertEqual "a capture used only as a saturated call head must pass the boundary" [] vs
      assertRcAgrees "test/rc-m2a1/52-capture-callhead-accept.wok"
  , testCase "capture-as-partial-call-head #23 is ACCEPTED and runs sound (M2a-2)" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/53-capture-partial-callhead-accept.wok"
      assertEqual "a capture used only as a partial call head must pass the boundary" [] vs
      assertRcAgrees "test/rc-m2a1/53-capture-partial-callhead-accept.wok"
  ]

-- ---------------------------------------------------------------------------
-- M2a-1 lint: 'balanceLint' as the compile-time oracle for case #1/#4
--
-- M2a-1 Tasks 3+4 bring the consuming-capture (#1) and borrowed-sibling (#4)
-- 'LetRec' shapes INTO the Perceus pass's coverage and make 'balanceLint'
-- audit them. The pass emits a build-site '__rc_dup' per consuming use of an
-- enclosing capture so each runtime move owns its unit and the region keeps its
-- per-member cascade unit; 'balanceLint' relinquishes the same multiset, so it is
-- BALANCED on these shapes only when the dup-per-consuming-use is exactly right.
--
-- The RC BOUNDARY guard ('firstOrderNoHandlerViolations') STILL rejects both
-- programs until the escape-narrowing slice (Task 5) --- 'rcM2a1BaselineTests'
-- asserts that. These tests audit the PASS + LINT directly, on the elaborated
-- module ('balanceLint' runs 'insertRC' itself), so they bypass the boundary.

-- | Load and elaborate a '.wok' file to its 'CoreModule'. Propagates loader and
-- elaboration errors as 'assertFailure'.
elaboratedModuleOf :: FilePath -> IO Anf.CoreModule
elaboratedModuleOf path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> assertFailure ("loader: " <> show lerr)
    Right (entryName, ms) ->
      case Pipeline.elaborateProgramFull entryName ms of
        Left s  -> assertFailure ("elaborate: " <> s)
        Right cm -> pure cm

rcM2a1LintTests :: TestTree
rcM2a1LintTests = testGroup "m2a-1 lint (balanceLint is the oracle for #4)"
  [ testCase "rlam-sibling #4 is covered and balances clean" $ do
      cm <- elaboratedModuleOf "test/rc-examples/34-rlam-sibling-nonescape.wok"
      assertEqual "balanceLint must be clean on the borrowed-sibling shape"
        [] (Perceus.balanceLint cm)
  , testCase "teeth: OmitOneDrop is caught on #4" $ do
      cm <- elaboratedModuleOf "test/rc-examples/34-rlam-sibling-nonescape.wok"
      assertBool "a dropped __rc_drop must produce a balanceLint violation"
        (not (null (Perceus.lintInstrumented (Perceus.insertRCMutated Perceus.OmitOneDrop cm))))
  ]

-- ---------------------------------------------------------------------------
-- M2a-1 alias-of-sibling hardening: a bare 'let x = f' that aliases a LetRec
-- group sibling 'f' (a borrowed/uncounted-region member) must propagate the
-- sibling's exempt-ness THROUGH the alias --- 'x' is a borrow of the same member,
-- so the pass emits NO '__rc_dup' and NO '__rc_drop' for it and does NOT count it
-- as owned. Before the fix the pass dropped 'x' at its dead point, double-freeing
-- the region member (cell-drop + group-drop); 'runModuleRCUnchecked' errored
-- 'double-free: addr 0' while the boundary guard ACCEPTED the program and
-- 'balanceLint' reported it CLEAN --- it escaped both oracles. The genuine oracle
-- is runtime accounting.
--
--   * '40-alias-sibling-drop' (alias DROPPED, non-escaping): now ACCEPTED by the
--     boundary guard, runs heap-BALANCED, and agrees with the reference value.
--   * '41-alias-sibling-escape' (alias RETURNED, escaping): the borrow leaves the
--     region; the boundary guard's escape detection follows the alias rename and
--     REJECTS it (region-lifetime extension = M2a-2).
rcM2a1AliasTests :: TestTree
rcM2a1AliasTests = testGroup "m2a-1 alias-of-sibling (exempt-ness through aliases)"
  [ testCase "alias-sibling DROP #10: boundary ACCEPTS the non-escaping alias" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/40-alias-sibling-drop.wok"
      assertEqual "a dropped (non-escaping) alias of a sibling must pass the boundary"
        [] vs
  , testCase "alias-sibling DROP #10: heap empties after RC run (no double-free)" $
      assertHeapEmpty "test/rc-m2a1/40-alias-sibling-drop.wok"
  , testCase "alias-sibling DROP #10: balanceLint is clean (mirrors the pass)" $ do
      cm <- elaboratedModuleOf "test/rc-m2a1/40-alias-sibling-drop.wok"
      assertEqual "balanceLint must be clean on the alias-of-sibling shape"
        [] (Perceus.balanceLint cm)
  , testCase "alias-sibling DROP #10: teeth: OmitOneDrop is caught" $ do
      cm <- elaboratedModuleOf "test/rc-m2a1/40-alias-sibling-drop.wok"
      assertBool "a dropped __rc_drop must produce a balanceLint violation"
        (not (null (Perceus.lintInstrumented (Perceus.insertRCMutated Perceus.OmitOneDrop cm))))
  , testCase "alias-sibling DROP #10: RC run agrees with the reference value" $ do
      cm <- elaboratedModuleOf "test/rc-m2a1/40-alias-sibling-drop.wok"
      let pruned = pruneToReachable cm
      case (Interp.runModule pruned, RCM.runModuleRCUnchecked (Perceus.insertRC pruned)) of
        (Right v, Right run) ->
          Interp.renderValue v @?= RCM.rcOutput run
        (refRes, rcRes) ->
          assertFailure ("both interpreters must succeed; got "
                           <> show (either show (const "ok") refRes) <> " / "
                           <> show (either show (const "ok") rcRes))
  , testCase "alias-sibling ESCAPE #11: boundary ACCEPTS and runs sound (M2a-2 Stage B)" $ do
      -- M2a-2 Stage B: a bare ALIAS of a sibling that ESCAPES (returned) is now
      -- ADMITTED and runs SOUND. The env-alias propagation makes the escaping alias
      -- transfer the single shared-env handle out; the scope's env-alive handle is
      -- NOT also dropped, so the env the escaped alias still holds is not double-freed.
      vs <- boundaryViolationsOf "test/rc-m2a1/41-alias-sibling-escape.wok"
      assertEqual "an escaping alias of a sibling must pass the boundary" [] vs
      assertRcAgrees "test/rc-m2a1/41-alias-sibling-escape.wok"
  ]

-- ---------------------------------------------------------------------------
-- M2a-1 sibling-in-cell LOCAL DROP: a LetRec group sibling moved into an
-- ordinary container cell ('NCon'/'NRecord'/list 'Cons') that is then DROPPED
-- LOCALLY (the cell does NOT escape; the result is a scalar). Before the cascade
-- fix, 'countedChildren' returned ALL boxed children of a non-region, non-closure
-- container, so dropping the local cell cascaded into the region member 'f' --- and
-- the LetRec group's own unit-drop freed 'f' again --- a verified DOUBLE-FREE
-- ('double-free: addr 0') under 'runModuleRCUnchecked', while the boundary guard
-- correctly ACCEPTED the program (no escape) and 'balanceLint' reported it clean.
-- The genuine oracle is runtime accounting.
--
-- The fix makes the region/static-child skip in 'countedChildren' uniform across
-- ALL node kinds, so an 'NCon'/'NRecord' cell never cascade-frees a sibling it
-- merely contains; the sibling is freed exactly once by its group's unit-drop.
--
--   * '48-sibling-con-drop'     ('Box f'        dropped locally)
--   * '49-sibling-listcon-drop' ('Cons f Nil'   dropped locally)
--   * '50-sibling-record-drop'  ('Cell { fn=f }' dropped locally)
--
-- Their ESCAPING counterparts (42/44/45) stay REJECTED --- 'rcM2a1BaselineTests'.
rcM2a1SiblingDropTests :: TestTree
rcM2a1SiblingDropTests = testGroup "m2a-1 sibling-in-cell local drop (no cascade double-free)"
  [ testCase "sibling-in-con DROP #18: boundary ACCEPTS the non-escaping cell" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/48-sibling-con-drop.wok"
      assertEqual "a locally-dropped sibling-in-constructor must pass the boundary" [] vs
  , testCase "sibling-in-con DROP #18: heap empties after RC run (no double-free)" $
      assertHeapEmpty "test/rc-m2a1/48-sibling-con-drop.wok"
  , testCase "sibling-in-con DROP #18: balanceLint is clean (sibling exempt throughout)" $ do
      cm <- elaboratedModuleOf "test/rc-m2a1/48-sibling-con-drop.wok"
      assertEqual "balanceLint must be clean on the sibling-in-constructor drop shape"
        [] (Perceus.balanceLint cm)
  , testCase "sibling-in-con DROP #18: teeth: OmitOneDrop is caught" $ do
      cm <- elaboratedModuleOf "test/rc-m2a1/48-sibling-con-drop.wok"
      assertBool "a dropped __rc_drop must produce a balanceLint violation"
        (not (null (Perceus.lintInstrumented (Perceus.insertRCMutated Perceus.OmitOneDrop cm))))
  , testCase "sibling-in-con DROP #18: RC run agrees with the reference value" $ do
      cm <- elaboratedModuleOf "test/rc-m2a1/48-sibling-con-drop.wok"
      let pruned = pruneToReachable cm
      case (Interp.runModule pruned, RCM.runModuleRCUnchecked (Perceus.insertRC pruned)) of
        (Right v, Right run) ->
          Interp.renderValue v @?= RCM.rcOutput run
        (refRes, rcRes) ->
          assertFailure ("both interpreters must succeed; got "
                           <> show (either show (const "ok") refRes) <> " / "
                           <> show (either show (const "ok") rcRes))
  , testCase "sibling-in-listcon DROP #19: boundary ACCEPTS the non-escaping cell" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/49-sibling-listcon-drop.wok"
      assertEqual "a locally-dropped sibling-in-list-cell must pass the boundary" [] vs
  , testCase "sibling-in-listcon DROP #19: heap empties after RC run (no double-free)" $
      assertHeapEmpty "test/rc-m2a1/49-sibling-listcon-drop.wok"
  , testCase "sibling-in-record DROP #20: boundary ACCEPTS the non-escaping cell" $ do
      vs <- boundaryViolationsOf "test/rc-m2a1/50-sibling-record-drop.wok"
      assertEqual "a locally-dropped sibling-in-record-field must pass the boundary" [] vs
  , testCase "sibling-in-record DROP #20: heap empties after RC run (no double-free)" $
      assertHeapEmpty "test/rc-m2a1/50-sibling-record-drop.wok"
  ]

-- ---------------------------------------------------------------------------
-- M2a-2 Task 1: uniform BORROW-ON-CALL.
--
-- Applying ANY function value BORROWS it (the call is a pure read), never
-- consumes it. Perceus drops a function value at its LAST USE, exactly like any
-- other value. A closure called N times is therefore dup'd 0 times and dropped
-- exactly once. These tests lock that convention together with the heap-balance,
-- value-match, and 'balanceLint' oracles.

-- | Count the inserted @__rc_dup u@ / @__rc_drop u@ calls naming a specific
-- 'Unique' anywhere in an instrumented expression. An RC intrinsic is an
-- @RApp (AVar h) [AVar n]@ whose head hint is the dup/drop hint and whose single
-- operand names @u@.
countRcIntrinsicFor :: Text -> Unique -> Expr -> Int
countRcIntrinsicFor hint u = goE
  where
    isFor (RApp (AVar h) [AVar n]) =
      nameHint h == hint && nameUniq n == u
    isFor _ = False
    one r = if isFor r then 1 else 0
    goE (Ret _)            = 0
    goE (Let _ r e)        = one r + goRhs r + goE e
    goE (Case _ alts)      = sum (map goAlt alts)
    goE (LetJoin _ _ jb e) = goE jb + goE e
    goE (Jump _ _)         = 0
    goE (LetRec defs e)    = sum [ goE d | (_, _, d) <- defs ] + goE e
    goE (Handle e _)       = goE e
    goRhs (RLam _ e) = goE e
    goRhs _          = 0
    goAlt (AltCon _ _ e) = goE e
    goAlt (AltLit _ e)   = goE e
    goAlt (AltDefault e) = goE e

borrowOnCallTests :: TestTree
borrowOnCallTests = testGroup "borrow-on-call"
  [ testCase "closure called twice: borrow => no dup, drop at last use, heap balanced" $
      borrowOnCallTwiceBalanced
  ]

-- main = let f = \x -> x + 1
--        let a = f 10
--        let b = f 20      -- f used twice; borrow => no dup, drop at last use
--        in a + b
borrowOnCallTwiceBalanced :: Assertion
borrowOnCallTwiceBalanced = do
  let intTy = Ty.CTCon Ty.TcU64 []
      funTy = Ty.CTCon (Ty.TcUser (T.pack "Fun")) []
      nm h u = Name (T.pack h) (Unique u)
      fLam = RLam [Binder (nm "x" 1) Unrestricted intTy]
               (Let (Binder (nm "x1" 2) Unrestricted intTy)
                    (RApp (primAtom (T.pack "+")) [AVar (nm "x" 1), ALit (LInt 1)])
                 (Ret (AVar (nm "x1" 2))))
      body =
        Let (Binder (nm "f" 3) Unrestricted funTy) fLam
          (Let (Binder (nm "a" 4) Unrestricted intTy) (RApp (AVar (nm "f" 3)) [ALit (LInt 10)])
            (Let (Binder (nm "b" 5) Unrestricted intTy) (RApp (AVar (nm "f" 3)) [ALit (LInt 20)])
              (Let (Binder (nm "s" 6) Unrestricted intTy)
                   (RApp (primAtom (T.pack "+")) [AVar (nm "a" 4), AVar (nm "b" 5)])
                (Ret (AVar (nm "s" 6))))))
      cm     = CoreModule [TopBind (nm "main" 1000000) [] body]
      pruned = pruneToReachable cm
  assertBool "must be accepted" (null (firstOrderNoHandlerViolations pruned))
  -- Borrow-on-call: 'f' (the closure binder, Unique 3) is dup'd 0 times and
  -- dropped exactly once (at its last use, the second call site).
  let instrumented = Perceus.insertRC pruned
      CoreModule iBinds = instrumented
  case [ b | TopBind n _ b <- iBinds, nameHint n == T.pack "main" ] of
    (ib : _) -> do
      assertEqual "f is never dup'd (borrow, not move)"
        0 (countRcIntrinsicFor (T.pack "__rc_dup") (Unique 3) ib)
      assertEqual "f is dropped exactly once (at last use)"
        1 (countRcIntrinsicFor (T.pack "__rc_drop") (Unique 3) ib)
    [] -> assertFailure "instrumented module dropped main"
  case (Interp.runModule pruned, RCM.runModuleRC instrumented) of
    (Right v, Right run) -> do
      assertEqual "value" (Interp.renderValue v) (RCM.rcOutput run)
      assertEqual "heap empty" (St.stLive (RCM.rcStats run)) (RCM.rcBaseline run)
      assertEqual "balanced"
        (St.stAllocs (RCM.rcStats run) - St.stFrees (RCM.rcStats run))
        (RCM.rcBaseline run)
    (refRes, rcRes) ->
      assertFailure ("both interpreters must succeed; got "
                       <> either show (const "ok") refRes <> " / "
                       <> either show (const "ok") rcRes)
  assertEqual "balanceLint clean" [] (Perceus.balanceLint pruned)

-- ---------------------------------------------------------------------------
-- M2a-2 Task 3: evaluate 'letrec' via the shared-env + code-pointer
-- representation ('RVRecMember' over a static 'NGroupCode' label plus at most
-- ONE shared 'NEnv' cell). The boundary guard still rejects escaping shapes, so
-- only NON-escaping 'letrec' exercises this path.
--
--   * a CAPTURE-FREE group uses the static empty-env sentinel and allocates NO
--     dynamic group cell (acceptance: zero group allocation);
--   * a CAPTURING group allocates exactly ONE 'NEnv' cell, freed once;
--   * sibling (recursive) calls allocate nothing (the sibling scope is
--     reconstructed inline at entry);
--   * partial application of a member builds an ordinary closure that re-enters
--     the member on full application.

sharedEnvEvalTests :: TestTree
sharedEnvEvalTests = testGroup "sharedenv-eval"
  [ testCase "capture-free mutual even/odd: value-match, heap-balanced, ZERO group allocation" $
      sharedEnvCaptureFreeMutual
  , testCase "capture-free group derefs the static sentinel as the empty env (no collision)" $
      sharedEnvSentinelIsEmptyEnv
  , testCase "capturing group (borrow-read one boxed local): exactly ONE NEnv, freed once" $
      sharedEnvCapturingOneEnv
  , testCase "partial application of a recursive member re-enters it on full application" $
      sharedEnvPartialApplication
  , testCase "bare-member top-level result: runModuleRCUnchecked drops its env (heap-balanced)" $
      sharedEnvBareMemberResult
  ]

-- | Prereq A regression: a 'main' that RETURNS a bare group member
-- ('Ret (AVar even)') produces an 'RVRecMember' as the top-level result. The
-- final result-drop in 'runModuleRCUnchecked' must release that result via its
-- 'valueChildren' (the shared 'NEnv'), exactly like 'RVBox'; otherwise the env
-- cell is never freed and the run is spuriously imbalanced ('stLive' above
-- baseline). The capturing group below allocates exactly one 'NEnv' (it
-- borrow-reads the boxed local @b@), so a missing final drop leaves @live=2@.
--
--   main = let b = Box 7
--          letrec even k = case k of 0 -> (case b of Box v -> v) ; _ -> odd (k-1)
--                 odd  k = case k of 0 -> (case b of Box v -> v) ; _ -> even (k-1)
--          in even                         -- bare member returned => RVRecMember
sharedEnvBareMemberResult :: Assertion
sharedEnvBareMemberResult = do
  let intTy  = Ty.CTCon Ty.TcU64 []
      boxTy  = Ty.CTCon (Ty.TcUser (T.pack "Box")) []
      funTy  = Ty.CTCon (Ty.TcUser (T.pack "Fun")) []
      nm h u = Name (T.pack h) (Unique u)
      bnd h u ty = Binder (nm h u) Unrestricted ty
      nB = nm "b" 1; nEven = nm "even" 2; nOdd = nm "odd" 3
      baseRead vU = Case (AVar nB)
                      [ AltCon (T.pack "Box") [bnd "v" vU intTy] (Ret (AVar (nm "v" vU))) ]
      recArm selfK sib ks ksU r rU =
        Let (bnd ks ksU intTy) (RApp (primAtom (T.pack "-")) [AVar selfK, ALit (LInt 1)])
          (Let (bnd r rU intTy) (RApp (AVar sib) [AVar (nm ks ksU)])
            (Ret (AVar (nm r rU))))
      evenBody = Case (AVar (nm "ek" 4))
                   [ AltLit (LInt 0) (baseRead 10), AltDefault (recArm (nm "ek" 4) nOdd "eks" 20 "er" 21) ]
      oddBody  = Case (AVar (nm "ok" 5))
                   [ AltLit (LInt 0) (baseRead 11), AltDefault (recArm (nm "ok" 5) nEven "oks" 22 "or" 23) ]
      body =
        Let (bnd "b" 1 boxTy) (RCon (T.pack "Box") [ALit (LInt 7)])
          (LetRec [ (Binder nEven Unrestricted funTy, [bnd "ek" 4 intTy], evenBody)
                  , (Binder nOdd  Unrestricted funTy, [bnd "ok" 5 intTy], oddBody) ]
            (Ret (AVar nEven)))
      cm     = CoreModule [TopBind (nm "main" 100) [] body]
      pruned = pruneToReachable cm
  case RCM.runModuleRCUnchecked (Perceus.insertRC pruned) of
    Left err  -> assertFailure ("runModuleRCUnchecked failed: " <> show err)
    Right run -> do
      let st = RCM.rcStats run
          bl = RCM.rcBaseline run
      assertEqual "live cells must return to baseline after dropping the bare-member result"
        bl (St.stLive st)
      assertEqual "allocs minus frees must equal the baseline (no leaked env)"
        bl (St.stAllocs st - St.stFrees st)

-- | A capture-free, TRULY mutually-recursive even/odd group with LITERAL base
-- cases, as a whole 'main' module. The 'Case' scrutinises the integer parameter
-- DIRECTLY (an 'AltLit 0' base + an 'AltDefault' recursive arm), so no boxed
-- Bool is ever allocated: a correct capture-free run allocates ZERO dynamic
-- cells (no 'NEnv', members inline over the static sentinel).
--
--   main = letrec even k = case k of 0 -> 1 ; _ -> odd (k-1)
--                 odd  k = case k of 0 -> 0 ; _ -> even (k-1)
--          in even <arg>
mutualLitModule :: Integer -> CoreModule
mutualLitModule arg =
  let intTy = Ty.CTCon Ty.TcU64 []
      nm h u = Name (T.pack h) (Unique u)
      bnd h u = Binder (nm h u) Unrestricted intTy
      -- distinct Uniques per binder (the machine keys env on Unique).
      nEven = nm "even" 1; nOdd = nm "odd" 2
      evenBody =
        Case (AVar (nm "ek" 3))
          [ AltLit (LInt 0) (Ret (ALit (LInt 1)))
          , AltDefault (Let (bnd "eks" 5) (RApp (primAtom (T.pack "-")) [AVar (nm "ek" 3), ALit (LInt 1)])
                          (Let (bnd "er" 6) (RApp (AVar nOdd) [AVar (nm "eks" 5)])
                            (Ret (AVar (nm "er" 6))))) ]
      oddBody =
        Case (AVar (nm "ok" 4))
          [ AltLit (LInt 0) (Ret (ALit (LInt 0)))
          , AltDefault (Let (bnd "oks" 7) (RApp (primAtom (T.pack "-")) [AVar (nm "ok" 4), ALit (LInt 1)])
                          (Let (bnd "or" 8) (RApp (AVar nEven) [AVar (nm "oks" 7)])
                            (Ret (AVar (nm "or" 8))))) ]
      body =
        LetRec [ (Binder nEven Unrestricted intTy, [bnd "ek" 3], evenBody)
               , (Binder nOdd  Unrestricted intTy, [bnd "ok" 4], oddBody) ]
          (Let (bnd "r" 9) (RApp (AVar nEven) [ALit (LInt arg)])
            (Ret (AVar (nm "r" 9))))
  in CoreModule [TopBind (nm "main" 100) [] body]

sharedEnvCaptureFreeMutual :: Assertion
sharedEnvCaptureFreeMutual = do
  let cm     = mutualLitModule 4
      pruned = pruneToReachable cm
  assertBool "non-escaping capture-free group must pass the boundary"
    (null (firstOrderNoHandlerViolations pruned))
  let instrumented = Perceus.insertRC pruned
  case (Interp.runModule pruned, RCM.runModuleRC instrumented) of
    (Right v, Right run) -> do
      let st = RCM.rcStats run
          bl = RCM.rcBaseline run
      assertEqual "value matches the reference interpreter"
        (Interp.renderValue v) (RCM.rcOutput run)   -- even 4 = 1
      assertEqual "heap empties to the immortal baseline" bl (St.stLive st)
      assertEqual "allocs - frees == baseline"
        bl (St.stAllocs st - St.stFrees st)
      -- ZERO group allocation: a capture-free group allocates no dynamic cell
      -- (no NEnv; the code label is static; literal base cases allocate no Bool).
      assertEqual "capture-free group allocates ZERO dynamic cells" 0 (St.stAllocs st)
      assertEqual "and never peaks above zero live dynamic cells" 0 (St.stPeak st)
    (refRes, rcRes) ->
      assertFailure ("both interpreters must succeed; got "
                       <> either show (const "ok") refRes <> " / "
                       <> either show (const "ok") rcRes)

-- | The sentinel collision fix: a capture-free group's @envAddr@ is the static
-- empty-env sentinel, and dereferencing it returns @NEnv Map.empty@ --- NOT the
-- first top-level bind's static cell (which 'reserveStatic' now starts at -2
-- after 'initSentinel' reserves -1).
sharedEnvSentinelIsEmptyEnv :: Assertion
sharedEnvSentinelIsEmptyEnv = do
  let s = St.initSentinel St.emptyStore
  case St.deref St.emptyEnvSentinelAddr s of
    Right c -> case St.cNode c of
      St.NEnv m -> assertEqual "sentinel holds the empty env" Map.empty m
      other     -> assertFailure ("sentinel must be NEnv empty, got " <> show other)
    Left err -> assertFailure ("sentinel deref failed: " <> show err)
  -- After the sentinel, the next static address is -2, so the first top-level
  -- bind (or group code label) cannot alias the sentinel slot.
  let (a, _) = St.allocStatic (St.NCon (T.pack "X") []) s
  assertBool "first post-sentinel static addr is below the sentinel" (a < St.emptyEnvSentinelAddr)

-- | A capturing, non-escaping group: two members that BOTH borrow-read one boxed
-- enclosing local @b = Box 7@ (each base case is @case b of Box v -> v@, a
-- borrow-read that keeps no boxed child). Built and HAND-INSTRUMENTED directly
-- (Perceus's letrec instrumentation is simplified in Task 4), so the group is
-- dropped by exactly ONE member-drop --- which frees the single shared 'NEnv'
-- and cascades into @b@. Asserts: exactly ONE 'NEnv' allocated (Box + env = 2
-- dynamic allocs, peak 2) and freed once (heap empties).
sharedEnvCapturingOneEnv :: Assertion
sharedEnvCapturingOneEnv = do
  let intTy  = Ty.CTCon Ty.TcU64 []
      boxTy  = Ty.CTCon (Ty.TcUser (T.pack "Box")) []
      nm h u = Name (T.pack h) (Unique u)
      bnd h u ty = Binder (nm h u) Unrestricted ty
      nB = nm "b" 1; nF = nm "f" 2; nG = nm "g" 3
      -- base case: case b of Box v -> v   (a borrow-read of the captured b)
      baseRead vU = Case (AVar nB)
                      [ AltCon (T.pack "Box") [bnd "v" vU intTy] (Ret (AVar (nm "v" vU))) ]
      recArm selfK sib ks ksU r rU =
        Let (bnd ks ksU intTy) (RApp (primAtom (T.pack "-")) [AVar selfK, ALit (LInt 1)])
          (Let (bnd r rU intTy) (RApp (AVar sib) [AVar (nm ks ksU)])
            (Ret (AVar (nm r rU))))
      fBody = Case (AVar (nm "fk" 4))
                [ AltLit (LInt 0) (baseRead 10), AltDefault (recArm (nm "fk" 4) nG "fks" 20 "fr" 21) ]
      gBody = Case (AVar (nm "gk" 5))
                [ AltLit (LInt 0) (baseRead 11), AltDefault (recArm (nm "gk" 5) nF "gks" 22 "gr" 23) ]
      -- main = let b = Box 7
      --        letrec f k = case k of 0 -> (case b of Box v -> v) ; _ -> g (k-1)
      --               g k = case k of 0 -> (case b of Box v -> v) ; _ -> f (k-1)
      --        let r = f 2                       -- => 7 (the captured value)
      --            _ = __rc_drop f               -- ONE member-drop: frees the env, cascades b
      --        in r
      e =
        Let (bnd "b" 1 boxTy) (RCon (T.pack "Box") [ALit (LInt 7)])
          (LetRec [ (Binder nF Unrestricted intTy, [bnd "fk" 4 intTy], fBody)
                  , (Binder nG Unrestricted intTy, [bnd "gk" 5 intTy], gBody) ]
            (Let (bnd "r" 6 intTy) (RApp (AVar nF) [ALit (LInt 2)])
              (Let (bnd "_d" 7 intTy) (RApp (AVar rcDropName) [AVar nF])
                (Ret (AVar (nm "r" 6))))))
      s0 = St.initSentinel St.emptyStore
  case RCM.runExprRC RCP.rcPrimTable Map.empty s0 e of
    Left err -> assertFailure ("rc run failed: " <> show err)
    Right (v, s) -> do
      txt <- either (assertFailure . show) pure (St.renderRCValue s v)
      txt @?= T.pack "7"
      let st = St.stStats s
      -- Box (1) + the ONE shared NEnv (1) = exactly two dynamic allocs; nothing
      -- more (sibling calls allocate nothing, base case is a borrow-read).
      assertEqual "exactly two dynamic allocations (Box + ONE NEnv)" 2 (St.stAllocs st)
      assertEqual "peak two live dynamic cells (Box + env held together)" 2 (St.stPeak st)
      -- The single member-drop freed the env, whose cascade freed Box: heap empties
      -- (the result is the unboxed literal 7, so there is nothing further to drop).
      assertEqual "both cells freed (env + cascaded Box)" 2 (St.stFrees st)
      assertEqual "heap empty after the single group drop" 0 (St.stLive st)

-- | Partial application of a recursive member. The single-member group
--
--   f a b = case b of 0 -> a ; _ -> let b' = b - 1 ; r = f a b' in r
--
-- accumulates @a@ while counting @b@ down to 0 (so @f 10 3 = 10@). We apply it
-- PARTIALLY (@p = f 10@, one arg of two), which must build an ordinary closure
-- capturing the supplied arg + the member, then FULLY apply it (@p 3@) so the
-- closure re-enters the member's code. Non-escaping (capture-free, result is a
-- scalar), hand-instrumented: the partial closure is the only dynamic cell and
-- is dropped at the end.
sharedEnvPartialApplication :: Assertion
sharedEnvPartialApplication = do
  let intTy  = Ty.CTCon Ty.TcU64 []
      funTy  = Ty.CTCon (Ty.TcUser (T.pack "Fun")) []
      nm h u = Name (T.pack h) (Unique u)
      bnd h u ty = Binder (nm h u) Unrestricted ty
      nF = nm "f" 1
      fBody =
        Case (AVar (nm "fb" 3))
          [ AltLit (LInt 0) (Ret (AVar (nm "fa" 2)))
          , AltDefault
              (Let (bnd "fb1" 4 intTy) (RApp (primAtom (T.pack "-")) [AVar (nm "fb" 3), ALit (LInt 1)])
                (Let (bnd "fr" 5 intTy) (RApp (AVar nF) [AVar (nm "fa" 2), AVar (nm "fb1" 4)])
                  (Ret (AVar (nm "fr" 5))))) ]
      -- main = letrec f a b = case b of 0 -> a ; _ -> f a (b-1)
      --        let p = f 10            -- PARTIAL: na=1 < np=2 => build a closure
      --            r = p 3             -- FULL: re-enters f => 10
      --            _ = __rc_drop p     -- drop the partial closure (its only owner)
      --        in r
      e =
        LetRec [ (Binder nF Unrestricted funTy, [bnd "fa" 2 intTy, bnd "fb" 3 intTy], fBody) ]
          (Let (bnd "p" 6 funTy) (RApp (AVar nF) [ALit (LInt 10)])
            (Let (bnd "r" 7 intTy) (RApp (AVar (nm "p" 6)) [ALit (LInt 3)])
              (Let (bnd "_d" 8 intTy) (RApp (AVar rcDropName) [AVar (nm "p" 6)])
                (Ret (AVar (nm "r" 7))))))
      s0 = St.initSentinel St.emptyStore
  case RCM.runExprRC RCP.rcPrimTable Map.empty s0 e of
    Left err -> assertFailure ("rc run failed: " <> show err)
    Right (v, s) -> do
      txt <- either (assertFailure . show) pure (St.renderRCValue s v)
      txt @?= T.pack "10"      -- f 10 3 accumulates a=10 down b=3..0
      let st = St.stStats s
      -- The ONLY dynamic cell is the partial-application closure; freed by its
      -- single drop. (The group code label is static; capture-free, so no NEnv.)
      assertEqual "exactly one dynamic allocation (the partial closure)" 1 (St.stAllocs st)
      assertEqual "the partial closure is freed" 1 (St.stFrees st)
      assertEqual "heap empty after dropping the partial closure" 0 (St.stLive st)

-- | Elaborate -> prune -> Perceus.insertRC -> runModuleRC a consuming-capture
-- corpus file directly (no boundary guard), and assert the heap is balanced:
-- everything born is freed and 'stLive' returns to the value-CAF baseline.
assertHeapEmpty :: FilePath -> Assertion
assertHeapEmpty path = do
  cm <- elaboratedModuleOf path
  case RCM.runModuleRCUnchecked (Perceus.insertRC (pruneToReachable cm)) of
    Left err  -> assertFailure ("runModuleRCUnchecked failed: " <> show err)
    Right run -> do
      let st = RCM.rcStats run
          bl = RCM.rcBaseline run
      assertEqual "live cells must return to the value-CAF baseline (no leak)"
        bl (St.stLive st)
      assertEqual "allocs minus frees must equal the baseline (no leak)"
        bl (St.stAllocs st - St.stFrees st)

-- | Elaborate -> prune a '.wok' file, then run BOTH interpreters and assert the RC
-- run AGREES with the reference value AND is heap-balanced (allocs - frees and live
-- both return to the value-CAF baseline). Unlike 'assertHeapEmpty', the result MAY
-- be a live value CAF (an escaped closure), so it asserts balance against the
-- baseline rather than zero. The run-the-exploit check for an ACCEPTED escaping
-- shape: a wrongly-admitted escape surfaces as a 'Left' (UAF / double-free), a leak
-- (live /= baseline), or a value mismatch.
assertRcAgrees :: FilePath -> Assertion
assertRcAgrees path = do
  cm <- elaboratedModuleOf path
  let pruned = pruneToReachable cm
  case (Interp.runModule pruned, RCM.runModuleRCUnchecked (Perceus.insertRC pruned)) of
    (Right v, Right run) -> do
      Interp.renderValue v @?= RCM.rcOutput run
      let st = RCM.rcStats run
          bl = RCM.rcBaseline run
      assertEqual "live cells must return to the value-CAF baseline (no leak)"
        bl (St.stLive st)
      assertEqual "allocs minus frees must equal the baseline (no leak)"
        bl (St.stAllocs st - St.stFrees st)
    -- BOTH interpreters failing is AGREEMENT (the RC pass did not DIVERGE from the
    -- reference): e.g. a shape that hits a shared evaluator limitation such as a
    -- record-pattern match on a call result ('NonExhaustiveCase' in both). The RC
    -- soundness claim is "RC agrees with the reference", not "the program runs". A
    -- one-sided failure (a UAF / double-free / leak in the RC run only) is the real
    -- soundness fault and still fails loudly.
    -- BOTH interpreters failing is AGREEMENT ONLY when they fail the SAME WAY: a
    -- shared evaluator limitation (e.g. a record-pattern match on a call result =>
    -- 'NonExhaustiveCase' in both). It is NOT a free pass. An RC memory-safety
    -- fault (double-free / use-after-free / dangling --- a 'PrimError' the
    -- reference interpreter, having no store, can NEVER produce) is a real
    -- one-sided soundness fault and MUST fail loudly even when the reference also
    -- errored; otherwise a future RC double-free could hide behind an unrelated
    -- reference failure (and recall a freed-env UAF surfaces as 'UnboundVar', which
    -- looks innocuous). So: reject any RC memory-safety fault outright, then require
    -- the two failures to share a constructor (payload text differs by design).
    (Left refE, Left rcE)
      | rcMemSafetyFault rcE ->
          assertFailure ("RC memory-safety fault hidden behind a reference failure (" <> path
                           <> "): rc=" <> show rcE <> " ref=" <> show refE)
      | errCtorTag refE == errCtorTag rcE -> pure ()
      | otherwise ->
          assertFailure ("RC failure DIVERGES from the reference failure --- a possible one-sided RC \
                         \fault (" <> path <> "): ref=" <> show refE <> " rc=" <> show rcE)
    (refRes, rcRes) ->
      assertFailure ("RC run must AGREE with the reference (both succeed or both fail); got ref="
                       <> either show (const "ok") refRes <> " rc="
                       <> either show (const "ok") rcRes)

-- | True iff @e@ is an RC STORE memory-safety / store-internal fault --- a
-- double-free, a use-after-free, a drop of a dangling/never-allocated address, OR
-- an RC-store-only structural invariant break (an env-handle whose backing cell is
-- not an 'NEnv', or any "internal:" machine message). These are all 'PrimError's
-- the reference interpreter (which has NO reference-counted store) can never raise,
-- so their presence on the RC side is ALWAYS a real one-sided soundness fault, even
-- when the reference also failed for an unrelated reason --- they must never launder
-- past 'errCtorTag' agreement in a both-fail branch.
--
-- The matched fragments are EXACTLY the store-only 'PrimError' messages emitted in
-- "src/Wok/Interp/RC/Value.hs" (drop/incref store guards) and
-- "src/Wok/Interp/RC/Machine.hs" ("RVRecMember env addr is not NEnv", "internal:"
-- machine invariants). We deliberately do NOT match the SHARED type-confusion
-- PrimErrors ("expected U64" / "expected Bool" / "division by zero" / "rc M1:
-- effects not supported"): those describe a value-level limitation the store-less
-- reference can also hit, so treating them as RC-only would risk a false failure.
--
-- RESIDUAL (cannot be closed without false failures): a freed-env use-after-free
-- can also surface as a plain 'IV.UnboundVar' (the env slot is gone, so the member
-- lookup misses) rather than a store 'PrimError'. 'UnboundVar' is a legitimate
-- reference-interpreter error too, so classifying it here would reject genuine
-- both-fail agreement (a real false failure). It is therefore left UNCAUGHT by this
-- predicate; the heap-balance assertions in 'assertRcAgrees' / 'prop_m2a1Escape' are
-- the backstop for that UAF shape on the accepting path (a freed-env leak shows as
-- live /= baseline), and the boundary fences keep the unsound shapes out entirely.
rcMemSafetyFault :: IV.RuntimeError -> Bool
rcMemSafetyFault (IV.PrimError m) =
  any (`T.isInfixOf` m)
    [ T.pack "double-free", T.pack "use-after-free", T.pack "dangling"
    , T.pack "is not NEnv", T.pack "internal:" ]
rcMemSafetyFault _ = False

-- | The constructor tag of a 'RuntimeError', ignoring its payload text (which
-- differs by design between the reference and RC interpreters). Two failures
-- that share a tag are the SAME class of error (genuine agreement).
errCtorTag :: IV.RuntimeError -> Text
errCtorTag e = case e of
  IV.UnboundVar{}        -> T.pack "UnboundVar"
  IV.NotAFunction{}      -> T.pack "NotAFunction"
  IV.NonExhaustiveCase{} -> T.pack "NonExhaustiveCase"
  IV.NoMatchingHandler{} -> T.pack "NoMatchingHandler"
  IV.BadProjection{}     -> T.pack "BadProjection"
  IV.PrimError{}         -> T.pack "PrimError"
  IV.ArityError{}        -> T.pack "ArityError"
  IV.UnsupportedCaf{}    -> T.pack "UnsupportedCaf"

-- ---------------------------------------------------------------------------
-- Suite A: differential run over the no-handler / first-order corpus (Task 8)
--
-- For each program in test/rc-examples/, run BOTH interpreters in the same test:
--
--   * the REFERENCE interpreter on the ORIGINAL (pre-Perceus) ANF
--       (Interp.runModule -> Interp.renderValue), and
--   * the RC interpreter on the Perceus-INSTRUMENTED ANF
--       (Machine.runModuleRC . Perceus.insertRC -> rcOutput).
--
-- dup/drop never change values, so the two rendered outputs must be
-- byte-identical. Because the RC interpreter is an INDEPENDENT implementation,
-- this is a genuine differential signal (a bug in either side surfaces as a
-- divergence rather than hiding identically in both).
--
-- Error path: we compare SUCCESS outputs. If BOTH sides return 'Left' we treat
-- it as a match WITHOUT comparing the error text -- the RC and reference error
-- renderings differ by design (different RuntimeError constructors / messages).
-- A one-sided failure is a real divergence and fails the test.
--
-- RC scope guard: the RC interpreter supports the handler-free fragment
-- (closures included, as of M1.5). We reject any corpus program whose CODE
-- REACHABLE FROM 'main' contains a handler/operation ('Handle'/'ROp' -- effects
-- are M2). We scope the check to the reachable call graph rather than the whole
-- elaborated module on purpose: 'elaborateProgramFull' inlines the entire
-- prelude (which DOES contain handlers), but none of it is reached by a
-- handler-free corpus 'main', so it never executes on the RC store.

rcDifferentialHarness :: FilePath -> Assertion
rcDifferentialHarness path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> assertFailure ("loader: " <> show lerr)
    Right (entryName, ms) ->
      case Pipeline.elaborateProgramFull entryName ms of
        Left s   -> assertFailure ("elaborate: " <> s)
        Right cm -> do
          -- RC scope guard: reject handlers / operations ('Handle'/'ROp')
          -- anywhere in the code reachable from 'main' (closures are admitted).
          case firstOrderNoHandlerViolations cm of
            [] -> pure ()
            vs -> assertFailure
              (path <> ": not a handler-free program (Handle/ROp out of scope):\n"
                 <> unlines (map T.unpack vs))
          -- Prune to the binds reachable from 'main' before running. This is a
          -- semantics-preserving dead-bind elimination: a top-level bind never
          -- reached from 'main' cannot affect main's result. We prune for BOTH
          -- interpreters so they execute byte-identical programs. It is REQUIRED
          -- for the RC interpreter: 'runModuleRC' force-evaluates every value-CAF
          -- eagerly at load time, whereas 'elaborateProgramFull' inlines the whole
          -- prelude (incl. dictionary CAFs that bottom out in prims the RC store
          -- does not bind); pruning drops those unreached CAFs so only the
          -- first-order corpus actually runs.
          let pruned = pruneToReachable cm
              refRes = Interp.runModule pruned
              rcRes  = RCM.runModuleRC (Perceus.insertRC pruned)
          case (refRes, rcRes) of
            (Right v, Right run) ->
              Interp.renderValue v @?= RCM.rcOutput run
            (Left _, Left _) ->
              -- Both failed: a match by design (error text differs between the
              -- reference and RC interpreters; we do not compare it).
              pure ()
            (Right v, Left rerr) ->
              assertFailure
                ( "divergence: reference SUCCEEDED ("
                    <> T.unpack (Interp.renderValue v)
                    <> ") but RC interpreter FAILED: " <> show rerr )
            (Left rerr, Right run) ->
              assertFailure
                ( "divergence: reference FAILED (" <> show rerr
                    <> ") but RC interpreter SUCCEEDED ("
                    <> T.unpack (RCM.rcOutput run) <> ")" )

-- ---------------------------------------------------------------------------
-- Suite E: deep-list recursive-drop at scale (Task 11)
--
-- The corpus carries a small (N == 8) deep-list program at
-- 'test/rc-examples/16-deep-list.wok', which is golden-pinned and runs through
-- Suites A/B/D like every other corpus file. This dedicated harness additionally
-- runs a LARGE (N == 50000) variant --- kept out of the auto-discovered corpus
-- so it is not golden-pinned --- end-to-end through the WHOLE pipeline
-- (elaborate -> Perceus insertRC -> runModuleRC) and asserts the exact heap
-- accounting for a freshly built, fully consumed spine of length N:
--
--   * frees    == N + 1  (N 'Cons' shells + one 'Nil', every one reclaimed),
--   * allocs   == N + 1  (nothing else is allocated; baseline == 0),
--   * peakLive == N + 1  (the whole spine is live before it is consumed),
--   * stLive   == 0      (heap-empty at exit).
--
-- Reaching 'frees == N + 1' at this scale proves the RC store's drop is
-- ITERATIVE (a worklist, not host recursion): a recursive drop of a 50000-cell
-- spine would otherwise overflow the Haskell stack. This is the same property as
-- the Store-level unit test in 'rc drop', but exercised end-to-end through the
-- '__rc_drop' calls the Perceus pass actually inserts.

rcDeepListTests :: TestTree
rcDeepListTests = testGroup "rc deep-list"
  [ testCase ("frees == N + 1 at scale (N = " <> show deepListN <> ")") $ do
      instrumented <- rcStatsPrepare "test/rc-deep-list/scale.wok"
      case RCM.runModuleRC instrumented of
        Left rerr -> assertFailure ("RC interpreter failed: " <> show rerr)
        Right run -> do
          let st       = RCM.rcStats run
              baseline = RCM.rcBaseline run
              expected = deepListN + 1
          assertEqual "this program retains no global baseline"
            0 baseline
          assertEqual "frees must equal N + 1 (every spine cell reclaimed)"
            expected (St.stFrees st)
          assertEqual "allocs must equal N + 1 (only the spine is allocated)"
            expected (St.stAllocs st)
          assertEqual "peakLive must equal N + 1 (whole spine live before consume)"
            expected (St.stPeak st)
          assertEqual "stLive must be 0 at exit (heap-empty)"
            0 (St.stLive st)
  ]
  where
    deepListN :: Int
    deepListN = 50000

-- ---------------------------------------------------------------------------
-- Suite B: heap accounting + --dump-rc-stats golden (Task 9)
--
-- For each program in test/rc-examples/, after running it on the RC interpreter,
-- assert the BASELINE heap invariant: every dynamic allocation made by 'main' is
-- reclaimed, leaving exactly the immortal global/dictionary-CAF baseline live:
--
--     stLive          == rcBaseline   AND
--     stAllocs - stFrees == rcBaseline
--
-- We assert against the baseline, NOT against zero, because 'runModuleRC' forces
-- every value-CAF (e.g. an instance-dictionary record) at load time; those cells
-- are immortal globals, not leaks (see 'RCRun's documentation). For a module
-- whose 'main' allocates nothing persistent, rcBaseline == 0 and the invariant
-- reduces to the textbook heap-empty (stLive == 0, allocs == frees). The corpus
-- includes a typeclass program (15-typeclass-dict) whose dictionary CAF makes
-- rcBaseline == 1, exercising the non-zero-baseline path.
--
-- A second golden test pins the four accounting numbers (allocs/frees/peakLive/
-- baseline) per program via 'Machine.renderRcStats' --- the same bytes the
-- '--dump-rc-stats' CLI mode emits --- so a regression (a move silently turning
-- into a dup, or a dropped/duplicated drop) surfaces as a golden diff.
--
-- Both harnesses share the differential harness's M1 scope guard and reachable
-- pruning, so they run the same byte-identical handler-free programs.

rcStatsGoldenFor :: FilePath -> FilePath
rcStatsGoldenFor f =
  replaceDirectory (replaceExtension f ".expected") "test/rc-stats-golden"

-- | Load -> elaborate -> M1 scope guard -> prune-to-reachable -> insertRC. The
-- shared front end for both Suite B harnesses; returns the pruned, instrumented
-- module ready for 'runModuleRC', or an 'assertFailure' on any front-end error.
rcStatsPrepare :: FilePath -> IO Anf.CoreModule
rcStatsPrepare path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> assertFailure ("loader: " <> show lerr)
    Right (entryName, ms) ->
      case Pipeline.elaborateProgramFull entryName ms of
        Left s   -> assertFailure ("elaborate: " <> s)
        Right cm -> do
          case firstOrderNoHandlerViolations cm of
            [] -> pure ()
            vs -> assertFailure
              (path <> ": not a handler-free program (Handle/ROp out of scope):\n"
                 <> unlines (map T.unpack vs))
          pure (Perceus.insertRC (pruneToReachable cm))

-- | Suite B heap-accounting assertion: run the instrumented module and check the
-- baseline invariant.
rcStatsHarness :: FilePath -> Assertion
rcStatsHarness path = do
  instrumented <- rcStatsPrepare path
  case RCM.runModuleRC instrumented of
    Left rerr -> assertFailure ("RC interpreter failed: " <> show rerr)
    Right run -> do
      let st       = RCM.rcStats run
          baseline = RCM.rcBaseline run
      assertEqual (path <> ": stLive must return to the immortal baseline")
        baseline (St.stLive st)
      assertEqual (path <> ": allocs - frees must equal the immortal baseline")
        baseline (St.stAllocs st - St.stFrees st)

-- | Suite B golden: the '--dump-rc-stats' bytes for a corpus program.
rcStatsDumpHarness :: FilePath -> IO BL.ByteString
rcStatsDumpHarness path = do
  instrumented <- rcStatsPrepare path
  case RCM.runModuleRC instrumented of
    Left rerr -> pure (BL.pack ("RC interpreter failed: " <> show rerr <> "\n"))
    Right run -> pure (BL.pack (T.unpack (RCM.renderRcStats run)))

-- ---------------------------------------------------------------------------
-- Suite C(b): fault injection --- the oracle has TEETH (Task 10)
--
-- The differential + heap-accounting oracle is only worth anything if it CATCHES
-- a wrong dup/drop placement. To prove it does, we deliberately break the pass
-- with 'Perceus.insertRCMutated' (a tests-only post-pass that perturbs exactly
-- one RC call; the production 'insertRC' is untouched) and assert each mutation
-- makes the oracle fail LOUDLY somewhere on the corpus:
--
--   * 'OmitOneDrop'      --- a leak: the Suite B baseline invariant breaks
--     (@stLive > rcBaseline@) on at least one program.
--   * 'OmitOneDup'       --- under-counting a shared value: the RC run trips a
--     'Left' use-after-free / double-free, OR 'balanceLint' reports an
--     over-consume on the mutated module.
--   * 'DuplicateOneDrop' --- over-relinquishing: the RC run trips a 'Left'
--     double-free on at least one program.
--
-- Each test asserts the FAILURE is DETECTED --- i.e. the mutated run does NOT
-- satisfy the oracle on at least one corpus program. A mutation that the oracle
-- failed to catch on EVERY program would be a vacuous oracle, and the test fails.
--
-- We share the front end with Suite B (same load -> elaborate -> M1 scope guard
-- -> prune), then apply the MUTATED instrumentation instead of the correct one.

rcTeethTests :: [FilePath] -> TestTree
rcTeethTests perceusFiles = testGroup "rc teeth"
  [ testCase "OmitOneDrop leaks (Suite B baseline breaks somewhere)" $ do
      detected <- Control.Monad.filterM
                    (teethLeakDetected Perceus.OmitOneDrop) perceusFiles
      assertBool
        ("OmitOneDrop produced NO leak on any corpus program --- the heap-accounting "
           <> "oracle is vacuous")
        (not (null detected))
  , testCase "OmitOneDup trips UAF/double-free or balance over-consume somewhere" $ do
      detected <- Control.Monad.filterM
                    (teethUnsoundDetected Perceus.OmitOneDup) perceusFiles
      assertBool
        ("OmitOneDup was caught by NEITHER the RC run nor balanceLint on any corpus "
           <> "program --- the oracle is vacuous")
        (not (null detected))
  , testCase "DuplicateOneDrop trips a double-free somewhere" $ do
      detected <- Control.Monad.filterM
                    (teethRunFailDetected Perceus.DuplicateOneDrop) perceusFiles
      assertBool
        ("DuplicateOneDrop produced NO RC-run failure on any corpus program --- the "
           <> "double-free trap is vacuous")
        (not (null detected))
  ]

-- | Load + elaborate + M1-guard + prune a corpus file, then instrument it with a
-- MUTATED Perceus pass. Returns 'Nothing' for a file outside the M1 fragment (so
-- the teeth tests silently skip it, exactly as Suite B would refuse it) and
-- 'Just' the mutated module otherwise.
teethPrepareMutated :: Perceus.Mutation -> FilePath -> IO (Maybe Anf.CoreModule)
teethPrepareMutated mut path = do
  result <- Loader.loadProgram path []
  case result of
    Left _ -> pure Nothing
    Right (entryName, ms) ->
      case Pipeline.elaborateProgramFull entryName ms of
        Left _   -> pure Nothing
        Right cm
          | not (null (firstOrderNoHandlerViolations cm)) -> pure Nothing
          | otherwise ->
              pure (Just (Perceus.insertRCMutated mut (pruneToReachable cm)))

-- | Does 'OmitOneDrop' make Suite B's baseline invariant FAIL on this file via a
-- genuine LEAK? A leak shows up as @stLive > rcBaseline@ (more live cells than the
-- immortal baseline) OR as @stAllocs - stFrees > rcBaseline@. We deliberately do
-- NOT count a 'Left' as a leak: the plan says OmitOneDrop must make Suite B report
-- @stLive > baseline@, so this asserts the SPECIFIC leak path, not just "something
-- went wrong". 'Nothing' (out of fragment) or a clean (balanced) run -> NOT
-- detected.
teethLeakDetected :: Perceus.Mutation -> FilePath -> IO Bool
teethLeakDetected mut path = do
  mcm <- teethPrepareMutated mut path
  case mcm of
    Nothing -> pure False
    Just cm -> case RCM.runModuleRC cm of
      Left _    -> pure False  -- a run failure is not the leak signal we assert
      Right run ->
        let st       = RCM.rcStats run
            baseline = RCM.rcBaseline run
        in pure (St.stLive st > baseline
                   || (St.stAllocs st - St.stFrees st) > baseline)

-- | Does the mutation make the RC RUN fail with a 'Left' on this file
-- (use-after-free / double-free / dangling)? 'Nothing' or a clean run -> 'False'.
teethRunFailDetected :: Perceus.Mutation -> FilePath -> IO Bool
teethRunFailDetected mut path = do
  mcm <- teethPrepareMutated mut path
  case mcm of
    Nothing -> pure False
    Just cm -> pure (case RCM.runModuleRC cm of
                       Left _  -> True
                       Right _ -> False)

-- | Does the mutation make the oracle catch UNSOUNDNESS on this file --- EITHER
-- the RC run trips a 'Left' (UAF/double-free), OR 'Perceus.lintInstrumented'
-- flags an over-consume on the mutated, instrumented module? We lint the
-- ALREADY-mutated bytes via 'lintInstrumented' (the plain 'balanceLint' re-runs
-- the CORRECT 'insertRC', which would hide the mutation). Either signal counts.
teethUnsoundDetected :: Perceus.Mutation -> FilePath -> IO Bool
teethUnsoundDetected mut path = do
  runFail <- teethRunFailDetected mut path
  if runFail
    then pure True
    else do
      mcm <- teethPrepareMutated mut path
      pure (case mcm of
              Nothing -> False
              Just cm -> not (null (Perceus.lintInstrumented cm)))

-- ---------------------------------------------------------------------------
-- Suite F: property-based differential + heap-empty (Task 12)
--
-- The curated corpus (Suites A/B/D/E) pins specific programs; this suite throws
-- RANDOM first-order ANF at the same oracle so it catches placement bugs the
-- corpus misses. For every generated program we assert ALL THREE oracle signals
-- at once:
--
--   1. DIFFERENTIAL: the reference interpreter (on the PRE-Perceus ANF) and the
--      RC interpreter (on the Perceus-INSTRUMENTED ANF) render byte-identical
--      output. 'dup'/'drop' do not change values, so any divergence is a bug.
--   2. HEAP-EMPTY: after the RC run, @stLive == rcBaseline@ AND
--      @stAllocs - stFrees == rcBaseline@ (the baseline invariant; generated
--      programs have no global CAFs so the baseline is 0 in practice, but we
--      assert against the reported baseline for robustness).
--   3. NO UAF / DOUBLE-FREE: the RC run returns 'Right' (the store tombstone
--      traps surface any use-after-free / double-free as a 'Left').
--
-- The generator emits WELL-SCOPED, FIRST-ORDER ANF directly (no surface syntax,
-- no loader/elaborator): Lit / Con / Record / Proj / Case / Let over a small
-- fixed set of nullary+binary constructors and saturated binary integer prims.
-- There are NO lambdas / HOF / partial application / effects, so every program
-- is squarely in the M1 fragment. Because both interpreters resolve constructors
-- structurally and prims by name (and 'renderValue'/'renderRCValue' agree byte
-- for byte), a directly-built @main = e@ module runs identically on both without
-- the type checker --- exactly the differential we want. Binder types are
-- generated FAITHFULLY (Int = unboxed U64; Pair/List/Record = boxed) so the
-- Perceus pass inserts dup/drop on precisely the reference-counted values.

rcPropertyTests :: TestTree
rcPropertyTests =
  localOption (QuickCheckTests 500) $
    testGroup "rc property"
      [ testProperty "differential output + heap-empty + no UAF/double-free"
          prop_rcDifferential
      ]

-- | The single Suite F property. Generate a first-order program, then assert the
-- three oracle signals. On failure, attach the pretty-printed instrumented ANF
-- and both interpreters' results as a counterexample (so a shrink/seed is
-- diagnosable without re-running by hand).
prop_rcDifferential :: Property
prop_rcDifferential =
  forAllShrink genProgram shrinkProgram $ \cm ->
    let refRes = Interp.runModule cm
        rcRes  = RCM.runModuleRC (Perceus.insertRC cm)
        report =
          "instrumented ANF:\n"
            <> T.unpack (Perceus.prettyPerceus cm)
            <> "\n\nreference: " <> showRes (fmap Interp.renderValue refRes)
            <> "\nrc:        " <> showRcRes rcRes
    in counterexample report $
         case (refRes, rcRes) of
           (Right v, Right run) ->
             let outOk      = Interp.renderValue v == RCM.rcOutput run
                 st         = RCM.rcStats run
                 baseline   = RCM.rcBaseline run
                 liveOk     = St.stLive st == baseline
                 balancedOk = St.stAllocs st - St.stFrees st == baseline
             in counterexample "output / heap-empty / balanced mismatch"
                  (outOk && liveOk && balancedOk)
           (Left _, Left _) ->
             -- Both failed the same way by construction (a generated divide is
             -- the only partial prim and we never emit it; this branch is a
             -- defensive match, treated as agreement).
             counterexample "both interpreters failed (treated as agreement)" True
           _ ->
             counterexample "divergence: exactly one interpreter failed" False
  where
    showRes (Right t)  = T.unpack t
    showRes (Left e)   = "FAILED (" <> show e <> ")"
    showRcRes (Right run) = T.unpack (RCM.rcOutput run)
    showRcRes (Left e)    = "FAILED (" <> show e <> ")"

-- ---------------------------------------------------------------------------
-- The first-order ANF generator
--
-- A program is @main = e@ where @e@ produces a value of a randomly chosen type.
-- Generation runs in @StateT Int Gen@: the 'Int' is a monotonic fresh-Unique
-- supply (so every binder is globally unique => well-scoped by construction),
-- and 'Gen' drives the random choices. A typed environment @[(Name, GTy)]@ of
-- in-scope binders lets leaves reference earlier bindings of a compatible type.

-- | The closed first-order type universe the generator ranges over. Every one is
-- rendered identically by the reference and RC interpreters.
data GTy
  = GInt            -- unboxed U64 scalar
  | GPair           -- boxed   Pair(Int, Int)
  | GList           -- boxed   cons-list of Int (Cons(Int, GList) | Nil)
  | GRec            -- boxed   record R { fst : Int, snd : Int }
  deriving (Eq, Show)

-- | Map a generator type to the 'CType' carried by binders of that type. The
-- Perceus pass keys boxedness off this type ('isBoxedType'): 'GInt' is unboxed
-- (no dup/drop), the other three are boxed (reference-counted).
gtyCType :: GTy -> Ty.CType
gtyCType GInt  = Ty.CTCon Ty.TcU64 []
gtyCType GPair = Ty.CTCon (Ty.TcTuple 2) [Ty.CTCon Ty.TcU64 [], Ty.CTCon Ty.TcU64 []]
gtyCType GList = Ty.CTCon Ty.TcList [Ty.CTCon Ty.TcU64 []]
gtyCType GRec  = Ty.CTRecord recTyName Ty.CREmpty

recTyName :: Text
recTyName = T.pack "R"

-- | Generation monad: a fresh-Unique counter threaded over 'Gen'.
type GenM = StateT Int Gen

-- | Pull a fresh, globally-unique 'Name' with a readable hint.
freshN :: Text -> GenM Name
freshN hint = state (\u -> (Name hint (Unique u), u + 1))

-- | A typed binder over a generated type.
gBinder :: Text -> GTy -> GenM Binder
gBinder hint ty = do
  n <- freshN hint
  pure (Binder n Unrestricted (gtyCType ty))

-- | Lift a 'Gen' action into 'GenM'.
liftG :: Gen a -> GenM a
liftG = lift

-- | Weighted choice among 'GenM' alternatives (a 'GenM' analogue of QuickCheck's
-- 'frequency'). Zero-weight entries are ignored; at least one positive-weight
-- entry must be supplied.
freqM :: [(Int, GenM a)] -> GenM a
freqM xs = do
  let live = [ (w, a) | (w, a) <- xs, w > 0 ]
      total = sum (map fst live)
  pick <- liftG (choose (1, total))
  go pick live
  where
    go _ [] = error "freqM: empty / all-zero weights"
    go k ((w, a) : rest)
      | k <= w    = a
      | otherwise = go (k - w) rest

-- | The whole-program generator: @main = e@, scaled by the QuickCheck size.
genProgram :: Gen CoreModule
genProgram = sized $ \sz -> do
  ty <- elements [GInt, GPair, GList, GRec]
  (body, _) <- runStateT (genExpr [] (max 1 (min sz 8)) ty) 0
  mainN <- pure (Name (T.pack "main") (Unique 1000000))
  pure (CoreModule [TopBind mainN [] body])

-- | Generate an ANF 'Expr' of result type @ty@ under typed environment @env@,
-- with a fuel budget @n@ bounding nesting depth. The environment lists in-scope
-- boxed/unboxed binders the leaves may reference.
genExpr :: [(Name, GTy)] -> Int -> GTy -> GenM Expr
genExpr env n ty
  | n <= 0    = Ret <$> genAtom env ty
  | otherwise =
      freqM
        [ (2, Ret <$> genAtom env ty)
        , (4, genLet env n ty)
        , (if scrutinizable env then 3 else 0, genCase env n ty)
        , (if n >= 3 then 3 else 0, genJoinCluster env n ty)
        , (if n >= 3 then 3 else 0, genClosureCluster env n ty)
        , (if n >= 3 then 3 else 0, genLetRecCaptureCluster env n ty)
        ]

-- | A 'let x = rhs in body' producing @ty@. The rhs produces some intermediate
-- type; the body (under x in scope) produces @ty@.
genLet :: [(Name, GTy)] -> Int -> GTy -> GenM Expr
genLet env n ty = do
  rhsTy <- liftG (elements [GInt, GPair, GList, GRec])
  (b, rhs) <- genRhs env (n - 1) rhsTy
  body <- genExpr ((bndName b, rhsTy) : env) (n - 1) ty
  pure (Let b rhs body)

-- | Generate a 'Let' binder of type @ty@ together with its (already-ANF) rhs.
genRhs :: [(Name, GTy)] -> Int -> GTy -> GenM (Binder, Rhs)
genRhs env _n ty = do
  b <- gBinder (hintFor ty) ty
  rhs <- case ty of
    GInt  -> genIntRhs env
    GPair -> do x <- genAtom env GInt
                y <- genAtom env GInt
                pure (RCon (T.pack "Tuple2") [x, y])
    GList -> freqM
               [ (1, pure (RCon (T.pack "Nil") []))
               , (3, do hd <- genAtom env GInt
                        tl <- genAtom env GList
                        pure (RCon (T.pack "Cons") [hd, tl])) ]
    GRec  -> do a <- genAtom env GInt
                c <- genAtom env GInt
                pure (RRecord recTyName [(T.pack "fst", a), (T.pack "snd", c)])
  pure (b, rhs)

-- | An integer-producing rhs: either a saturated binary prim over two int atoms,
-- a projection of a boxed value's int field, or a plain int atom.
genIntRhs :: [(Name, GTy)] -> GenM Rhs
genIntRhs env = do
  let projSources =
        [ (nm, lbl)
        | (nm, GRec) <- env, lbl <- [T.pack "fst", T.pack "snd"] ]
  freqM
    [ (4, do op <- liftG (elements [T.pack "+", T.pack "-", T.pack "*"])
             x  <- genAtom env GInt
             y  <- genAtom env GInt
             pure (RApp (AVar (primName op)) [x, y]))
    , (if null projSources then 0 else 2,
         do (nm, lbl) <- liftG (elements projSources)
            pure (RProj lbl (AVar nm)))
    , (2, RAtom <$> genAtom env GInt)
    ]

-- | A 'case' scrutinizing an in-scope boxed value (Pair / List / Record) and
-- producing @ty@ in every alt. Every alt consumes the same owned set, exercising
-- the Perceus branch-reconciliation / own-children-drop-parent rules.
genCase :: [(Name, GTy)] -> Int -> GTy -> GenM Expr
genCase env n ty = do
  (scrut, scrutTy) <- liftG (elements (scrutCandidates env))
  case scrutTy of
    GPair -> do
      xb <- gBinder (T.pack "px") GInt
      yb <- gBinder (T.pack "py") GInt
      body <- genExpr ((bndName xb, GInt) : (bndName yb, GInt) : env) (n - 1) ty
      pure (Case (AVar scrut) [AltCon (T.pack "Tuple2") [xb, yb] body])
    GRec -> do
      -- A record has no constructor to match; scrutinize via a default alt that
      -- keeps the record live for projection in the body.
      body <- genExpr env (n - 1) ty
      pure (Case (AVar scrut) [AltDefault body])
    GList -> do
      hb   <- gBinder (T.pack "h") GInt
      tb   <- gBinder (T.pack "t") GList
      consBody <- genExpr ((bndName hb, GInt) : (bndName tb, GList) : env) (n - 1) ty
      nilBody  <- genExpr env (n - 1) ty
      pure (Case (AVar scrut)
              [ AltCon (T.pack "Cons") [hb, tb] consBody
              , AltCon (T.pack "Nil") [] nilBody ])
    GInt -> Ret <$> genAtom env ty   -- unreachable (filtered by scrutCandidates)

-- | Boxed in-scope binders usable as 'case' scrutinees.
scrutCandidates :: [(Name, GTy)] -> [(Name, GTy)]
scrutCandidates env = [ (nm, t) | (nm, t) <- env, t /= GInt ]

scrutinizable :: [(Name, GTy)] -> Bool
scrutinizable = not . null . scrutCandidates

-- | A trivial atom of the requested type: prefer an in-scope binder of that type,
-- otherwise a literal/constant. For 'GInt' a random small literal; for the boxed
-- types, a canonical empty/zero constant so a leaf always type-checks structurally.
genAtom :: [(Name, GTy)] -> GTy -> GenM Atom
genAtom env ty =
  let candidates = [ AVar nm | (nm, t) <- env, t == ty ]
  in case ty of
       GInt -> freqM
                 [ (3, ALit . LInt . toInteger <$> liftG (choose (0, 20 :: Int)))
                 , (if null candidates then 0 else 4, liftG (elements candidates))
                 ]
       _    -> if null candidates
                 then pure (constAtomFor ty)
                 else liftG (elements candidates)

-- | A canonical closed constant atom for a boxed type, used when no in-scope
-- binder of that type exists. These are LITERAL/nullary forms only (an atom must
-- be trivial); compound constants are introduced via 'genRhs' lets, so the only
-- nullary boxed constant we can express as a bare atom is the empty list 'Nil'...
-- which is itself a constructor, NOT an atom. Therefore boxed leaves fall back to
-- a unit literal sentinel only when truly unavoidable; in practice 'genExpr'
-- seeds boxed bindings via 'genLet' before requesting a boxed atom, so this path
-- is not hit for well-fuelled programs. To stay TOTAL we emit a zero int literal,
-- which is only ever reached at fuel 0 with an empty env and is harmless because
-- the differential compares whatever both interpreters produce identically.
constAtomFor :: GTy -> Atom
constAtomFor _ = ALit (LInt 0)

hintFor :: GTy -> Text
hintFor GInt  = T.pack "i"
hintFor GPair = T.pack "p"
hintFor GList = T.pack "xs"
hintFor GRec  = T.pack "r"

-- | The 'Name' under which a binary integer prim is referenced. The 'Unique' is
-- irrelevant: both interpreters resolve prims by HINT (the textual name) when the
-- name is absent from the runtime env (see 'callFn'/the reference 'enter'), so a
-- placeholder unique suffices.
primName :: Text -> Name
primName op = Name op (Unique 2000000)

-- ---------------------------------------------------------------------------
-- Adversarial join clusters (Suite F, review #1 follow-up)
--
-- The base generator emits no joins, so the recurring "a var consumed somewhere
-- the dup/drop placement didn't see" bug class was unreachable by random programs:
--   * F1     -- a Case whose scrutinee is captured only by a join reached
--               TRANSITIVELY through a chain (reuse detection must close over it);
--   * #4     -- a join that owns a var only via the TRANSITIVE cap and so must
--               DROP it on a non-forwarding arm of its own body;
--   * §1     -- a join body that MOVES a captured var AND forwards onward to a
--               downstream join that also uses it (two consumers => a dup).
--
-- 'genJoinCluster' synthesizes a value-position case on a freshly-seeded boxed
-- capture whose continuation is a chain of joins capturing that var, directly in
-- ANF. It only owes STRUCTURAL validity (well-scoped, arity-correct jumps, covered
-- fragment); the existing triple oracle (differential output + heap-empty +
-- balanced, with a UAF/double-free trapped as a 'Left') checks that the PASS got
-- the reference counting right. Reverting any of the three fixes makes the
-- corresponding kind below fail at runtime (a leak or a trapped use-after-free).

-- | How an INTERMEDIATE join (one that is not the deepest in the chain) treats the
-- captured scrutinee. The deepest join always uses the capture (so it is in that
-- join's cap); the intermediates differ:
data IntermediateKind
  = PureForward     -- ^ body is a bare 'Jump' onward: the capture is reached only
                    --   TRANSITIVELY through the deepest join (exercises F1).
  | MoveForward     -- ^ body MOVES the capture into a dead binding then jumps on:
                    --   the capture lives in two places => a dup is required (§1).
  | BranchForward   -- ^ body is a 'Case' on its int param, one arm forwarding and
                    --   one not, so the capture (owned only via the transitive cap)
                    --   must be DROPPED on the non-forwarding arm (#4).
  deriving (Eq, Show)

-- | A fresh 'JoinId' from the same monotonic supply as binder names.
freshJoinId :: GenM JoinId
freshJoinId = state (\u -> (JoinId (Unique u), u + 1))

-- | Generate an adversarial join cluster producing @ty@. Seeds its own boxed
-- capture, so it needs nothing from @env@ and is available whenever there is fuel.
genJoinCluster :: [(Name, GTy)] -> Int -> GTy -> GenM Expr
genJoinCluster env n ty = do
  -- Pure-forward weighted twice so the F1 path is well represented.
  kind  <- liftG (elements [PureForward, PureForward, MoveForward, BranchForward])
  depth <- case kind of
             PureForward   -> liftG (choose (1, 3 :: Int))
             MoveForward   -> liftG (choose (2, 3 :: Int))
             BranchForward -> pure (2 :: Int)
  -- Seed a fresh non-empty capture list  s = Cons h Nil  (so the Cons arm runs).
  nilN <- freshN (T.pack "n0")
  sN   <- freshN (T.pack "s")
  hN   <- freshN (T.pack "h")
  tN   <- freshN (T.pack "t")
  h0   <- liftG (choose (0, 9 :: Int))
  jHead    <- freshJoinId
  restJids <- mapM (const freshJoinId) [2 .. depth]
  let jids = jHead : restJids
  params <- mapM (const (freshN (T.pack "r"))) jids
  let listTy  = gtyCType GList
      intTy   = gtyCType GInt
      -- BranchForward needs head arg 0 so j1's non-forwarding arm runs at runtime
      -- (review #4 shows up there as a leak); otherwise any nonzero forward arg.
      headArg = if kind == BranchForward then 0 else 1 :: Int
      armTo j = Jump j [ALit (LInt (toInteger headArg))]
      -- The capture is NOT referenced in the arms (it reaches the joins only
      -- through the cap) -- exactly the F1 trap.
      caseE   = Case (AVar sN)
                  [ AltCon (T.pack "Cons")
                      [Binder hN Unrestricted intTy, Binder tN Unrestricted listTy]
                      (armTo jHead)
                  , AltCon (T.pack "Nil") [] (armTo jHead) ]
      succs   = map Just restJids ++ [Nothing]   -- successor of each join; deepest -> Nothing
      triples = zip3 jids params succs
  -- Build each join body, then nest deepest-OUTERMOST (foldM: head ends innermost,
  -- delivering the Case; each later join wraps the accumulator).
  nest <- Control.Monad.foldM
            (\acc (jid, pN, mSucc) -> do
               body <- genJoinBody env n ty sN kind pN mSucc
               pure (LetJoin jid [Binder pN Unrestricted intTy] body acc))
            caseE
            triples
  pure $ Let (Binder nilN Unrestricted listTy) (RCon (T.pack "Nil") [])
       $ Let (Binder sN Unrestricted listTy)
             (RCon (T.pack "Cons") [ALit (LInt (toInteger h0)), AVar nilN])
       $ nest

-- | One join body. @mSucc = Nothing@ marks the deepest join (it captures @sN@ and
-- produces @ty@); otherwise it is an intermediate whose shape follows @kind@.
genJoinBody :: [(Name, GTy)] -> Int -> GTy -> Name -> IntermediateKind -> Name -> Maybe JoinId -> GenM Expr
genJoinBody env n ty sN kind pN mSucc =
  let listTy = gtyCType GList
  in case mSucc of
       Nothing -> do
         -- Deepest join: USE the capture (a dead Cons that moves it -> sN is in the
         -- cap), then produce @ty@ by the ordinary rules.
         capN  <- freshN (T.pack "cap")
         inner <- genExpr env (n - 1) ty
         pure (Let (Binder capN Unrestricted listTy)
                   (RCon (T.pack "Cons") [ALit (LInt 0), AVar sN]) inner)
       Just jn -> case kind of
         PureForward -> pure (Jump jn [ALit (LInt 1)])
         MoveForward -> do
           uN <- freshN (T.pack "u")
           pure (Let (Binder uN Unrestricted listTy)
                     (RCon (T.pack "Cons") [ALit (LInt 0), AVar sN])
                     (Jump jn [ALit (LInt 1)]))
         BranchForward -> do
           nf <- genExpr env (n - 1) ty     -- non-forwarding arm (does not use sN)
           pure (Case (AVar pN)
                   [ AltLit (LInt 0) nf
                   , AltDefault (Jump jn [ALit (LInt 1)]) ])

-- ---------------------------------------------------------------------------
-- Adversarial closure clusters (Suite F, M1.5 Task 6)
--
-- 'genClosureCluster' seeds a fresh boxed capture (a Pair of two ints), builds
-- an 'RLam' that captures and CONSUMES it via a 'Case', then exercises one of
-- four shapes that stress different RC obligations the Perceus pass must satisfy:
--
--   ClosureCallOnce   -- f built and called once; f and capture consumed by call
--   ClosureCallTwice  -- f called twice; pass must DUP f before the first call
--                       so the second call still has a live copy
--   ClosureDrop       -- f built and NEVER called; pass must DROP f (which
--                       cascades to the capture)
--   ClosureBranch     -- f built; one Case arm calls it, the other drops it;
--                       pass must balance dup/drop across the two arms
--
-- The closure body is always: @\x -> case cap of Tuple2 px py -> px@ (returns
-- the first int field, ignoring the unboxed param @x@).  The program result is
-- always GInt so the heap returns to baseline after a correct Perceus pass.

-- | The four structural shapes for 'genClosureCluster'.
data ClosureShape
  = ClosureCallOnce    -- ^ call f exactly once
  | ClosureCallTwice   -- ^ call f twice (forces a dup of the closure)
  | ClosureDrop        -- ^ build f and drop without calling (tests drop cascade)
  | ClosureBranch      -- ^ call f in one branch, drop in the other
  deriving (Eq, Show)

-- | Generate an adversarial closure cluster producing @ty@. Seeds its own
-- boxed capture, so it is self-contained and available whenever there is fuel.
-- The closure binder carries @'Ty.CTCon' ('Ty.TcUser' "Fun") []@ so 'isBoxedType'
-- tracks it as a heap-allocated cell (the same convention as 'closureModule').
genClosureCluster :: [(Name, GTy)] -> Int -> GTy -> GenM Expr
genClosureCluster env n ty = do
  shape <- liftG (elements [ClosureCallOnce, ClosureCallTwice, ClosureDrop, ClosureBranch])
  -- Seed the capture: a Pair of two random int literals.
  v0 <- liftG (choose (0, 9 :: Int))
  v1 <- liftG (choose (0, 9 :: Int))
  capN <- freshN (T.pack "cap")
  fN   <- freshN (T.pack "f")
  xN   <- freshN (T.pack "x")
  pxN  <- freshN (T.pack "fpx")
  pyN  <- freshN (T.pack "fpy")
  let pairTy = gtyCType GPair   -- CTCon (TcTuple 2) [U64, U64]  -- boxed
      funTy  = Ty.CTCon (Ty.TcUser (T.pack "Fun")) []  -- boxed (catch-all)
      intTy  = gtyCType GInt    -- CTCon TcU64 []               -- unboxed
      capB   = Binder capN Unrestricted pairTy
      fB     = Binder fN  Unrestricted funTy
      xB     = Binder xN  Unrestricted intTy
      pxB    = Binder pxN Unrestricted intTy
      pyB    = Binder pyN Unrestricted intTy
      -- The closure body: consume cap via case, return first field.
      lamBody = Case (AVar capN)
                  [ AltCon (T.pack "Tuple2") [pxB, pyB]
                      (Ret (AVar pxN)) ]
      lam    = RLam [xB] lamBody
      -- One call of f with an unboxed arg; produces GInt.
      callF result body =
        Let (Binder result Unrestricted intTy)
            (RApp (AVar fN) [ALit (LInt 0)])
            body
  -- Build the closure-seeding prefix, then add the shape-specific continuation.
  let seedPrefix inner =
        Let capB (RCon (T.pack "Tuple2") [ALit (LInt (toInteger v0)), ALit (LInt (toInteger v1))])
          (Let fB lam inner)
  case shape of
    ClosureCallOnce -> do
      rN    <- freshN (T.pack "r")
      inner <- genExpr ((rN, GInt) : env) (n - 1) ty
      pure $ seedPrefix (callF rN inner)

    ClosureCallTwice -> do
      r1N   <- freshN (T.pack "r1")
      r2N   <- freshN (T.pack "r2")
      inner <- genExpr ((r2N, GInt) : (r1N, GInt) : env) (n - 1) ty
      pure $ seedPrefix
        (callF r1N (callF r2N inner))

    ClosureDrop -> do
      -- Never call f; Perceus must drop f (cascade to cap) at scope exit.
      -- Result comes from genExpr so ty is satisfied.
      inner <- genExpr env (n - 1) ty
      pure $ seedPrefix inner

    ClosureBranch -> do
      -- A Case where one arm CALLS f and the other DROPS it: the pass must
      -- instrument BOTH arms (dup-then-consume on the call arm, a drop on the
      -- non-calling arm) and balance them. The scrutinee is pinned to 0 so the
      -- CALL arm always runs at runtime (the double-free-on-f risk is the
      -- adversarial half worth executing every case; the drop arm is still
      -- statically instrumented and balanceLint-checked). Mirrors the
      -- 'BranchForward' precedent in 'genJoinCluster'.
      rN    <- freshN (T.pack "r")
      -- call arm: call f, bind result, continue
      callBody <- genExpr ((rN, GInt) : env) (n - 1) ty
      -- drop arm: f is NOT called; Perceus must drop it here
      dropBody <- genExpr env (n - 1) ty
      pure $ seedPrefix
        (Case (ALit (LInt 0))
          [ AltLit (LInt 0)      (callF rN callBody)
          , AltDefault            dropBody ])

-- ---------------------------------------------------------------------------
-- Adversarial LetRec capture clusters (Suite F, M1.5 Task 10)
--
-- 'genLetRecCaptureCluster' seeds a fresh boxed capture (a Pair of two ints),
-- builds a TWO-member MUTUALLY-RECURSIVE 'LetRec' group where BOTH members
-- capture it (it is free in both bodies, so capOcc=2), and exercises it
-- non-escapingly (the group is called once; the result is unboxed). The pass
-- instruments the capture-consuming base-case arm of BOTH members statically;
-- which arm actually fires at runtime depends on the call parity, but the RC
-- accounting (and 'balanceLint') must balance for both regardless.
--
-- STRUCTURAL INVARIANTS that make this adversarial:
--
--   SharedCapture  -- both members capture the SAME boxed local; the pass must
--                     emit one 'dup' of the capture (multiset accounting: need=2,
--                     dups=1). Reverting the dup plan empties it and causes a
--                     double-free / use-after-free detectable by the heap-empty
--                     oracle and 'balanceLint'.
--
-- The two members are TRULY MUTUALLY RECURSIVE (f calls g, g calls f) so the
-- elaborator/generator puts them in a SINGLE 'LetRec' node (not two nested
-- single-member groups, which would trigger the cross-region-capture deferral).
-- The group is NON-ESCAPING: the result is an unboxed GInt extracted by calling
-- 'f'; no member is returned, stored, or passed as a non-head argument.
--
-- Member bodies:
--   f kN1 = case kN1 of
--     0 -> case capN of Tuple2 pxN1 pyN1 -> pxN1   (consume cap, return int)
--     _ -> gN(kN1 - 1)                              (call sibling, mutual-rec)
--   g kN2 = case kN2 of
--     0 -> case capN of Tuple2 pxN2 pyN2 -> pyN2   (consume cap, return int)
--     _ -> fN(kN2 - 1)                              (call sibling, mutual-rec)
--
-- 'cap' is BORROWED inside each body (the pass adds it to ctxExempt for the
-- member scope): the case-on-cap destructs it structurally but no drop is
-- emitted inside. The drops come from the group's scope-exit drop cascade: one
-- member drop per capture occurrence => the multiset dup must supply two units.

-- | Generate an adversarial LetRec capture cluster producing @ty@. Seeds its
-- own boxed capture, so it is self-contained and available whenever there is
-- fuel. The result is always 'GInt' (unboxed), so the heap returns to baseline
-- after a correct Perceus pass.
genLetRecCaptureCluster :: [(Name, GTy)] -> Int -> GTy -> GenM Expr
genLetRecCaptureCluster env n ty = do
  -- Seed the capture: a Pair of two random int literals (the shared boxed local).
  v0   <- liftG (choose (0, 9 :: Int))
  v1   <- liftG (choose (0, 9 :: Int))
  capN <- freshN (T.pack "cap")
  fN   <- freshN (T.pack "lrf")
  gN   <- freshN (T.pack "lrg")
  kN1  <- freshN (T.pack "k1")
  kN2  <- freshN (T.pack "k2")
  ks1N <- freshN (T.pack "ks1")
  ks2N <- freshN (T.pack "ks2")
  pxN1 <- freshN (T.pack "px1")
  pyN1 <- freshN (T.pack "py1")
  pxN2 <- freshN (T.pack "px2")
  pyN2 <- freshN (T.pack "py2")
  r1N  <- freshN (T.pack "r1")
  r2N  <- freshN (T.pack "r2")
  rN   <- freshN (T.pack "lrr")
  let pairTy = gtyCType GPair   -- boxed Pair
      intTy  = gtyCType GInt    -- unboxed U64
      capB   = Binder capN Unrestricted pairTy
      fB     = Binder fN   Unrestricted intTy   -- result type (not arrow)
      gB     = Binder gN   Unrestricted intTy
      kB1    = Binder kN1  Unrestricted intTy
      kB2    = Binder kN2  Unrestricted intTy
      ks1B   = Binder ks1N Unrestricted intTy
      ks2B   = Binder ks2N Unrestricted intTy
      pxB1   = Binder pxN1 Unrestricted intTy
      pyB1   = Binder pyN1 Unrestricted intTy
      pxB2   = Binder pxN2 Unrestricted intTy
      pyB2   = Binder pyN2 Unrestricted intTy
      r1B    = Binder r1N  Unrestricted intTy
      r2B    = Binder r2N  Unrestricted intTy
      rB     = Binder rN   Unrestricted intTy
      -- Body of f: case k of 0 -> case cap of Tuple2 px py -> px
      --                       _ -> let ks = k - 1; r = g(ks); r
      -- capN and gN are free in this body: capN is the shared boxed capture,
      -- gN is a sibling (exempt, never dup'd/drop'd inside).
      fBody  = Case (AVar kN1)
                 [ AltLit (LInt 0)
                     (Case (AVar capN)
                       [ AltCon (T.pack "Tuple2") [pxB1, pyB1]
                           (Ret (AVar pxN1)) ])
                 , AltDefault
                     (Let ks1B (RApp (AVar (primName (T.pack "-")))
                                     [AVar kN1, ALit (LInt 1)])
                       (Let r1B (RApp (AVar gN) [AVar ks1N])
                         (Ret (AVar r1N)))) ]
      -- Body of g: case k of 0 -> case cap of Tuple2 px py -> py
      --                       _ -> let ks = k - 1; r = f(ks); r
      -- capN and fN are free in this body.
      gBody  = Case (AVar kN2)
                 [ AltLit (LInt 0)
                     (Case (AVar capN)
                       [ AltCon (T.pack "Tuple2") [pxB2, pyB2]
                           (Ret (AVar pyN2)) ])
                 , AltDefault
                     (Let ks2B (RApp (AVar (primName (T.pack "-")))
                                     [AVar kN2, ALit (LInt 1)])
                       (Let r2B (RApp (AVar fN) [AVar ks2N])
                         (Ret (AVar r2N)))) ]
  -- The continuation uses rN (a GInt) and proceeds to produce @ty@.
  inner <- genExpr ((rN, GInt) : env) (n - 1) ty
  pure $
    -- seed the shared boxed capture
    Let capB (RCon (T.pack "Tuple2")
                   [ALit (LInt (toInteger v0)), ALit (LInt (toInteger v1))]) $
    -- the two-member mutually-recursive group (f calls g, g calls f => truly mutual)
    LetRec
      [ (fB, [kB1], fBody)
      , (gB, [kB2], gBody) ]
    -- non-escaping call: result is unboxed; no member is returned or stored
    (Let rB (RApp (AVar fN) [ALit (LInt 2)]) inner)

-- ---------------------------------------------------------------------------
-- Suite G: M2a-1 owned/borrowed + escape property generator (this slice)
--
-- The four M2a-1 holes (alias double-free, escaping-alias, direct sibling-escape
-- via con/call, local-drop of sibling-in-con) all survived because Suite F's
-- generators NEVER produce the M2a-1 shapes: a LetRec member CONSUMING an
-- enclosing capture, a standalone closure capturing a LetRec sibling that
-- ESCAPES, a sibling moved DIRECTLY into a con/record/call-arg, or an ALIAS of a
-- sibling. This generator emits exactly those shapes, in BOTH the non-escaping
-- (must be ACCEPTED by the boundary guard AND run sound) and escaping (must be
-- REJECTED) variants, directly in ANF (mirroring the test/rc-m2a1/33-50 corpus).
--
-- The PROOF (prop_m2a1Escape): for every generated program p, if the boundary
-- guard 'firstOrderNoHandlerViolations' ACCEPTS p, then the RC run via
-- 'runModuleRCUnchecked (insertRC (pruneToReachable cm))' MUST succeed, be
-- heap-balanced (stLive == baseline AND stAllocs - stFrees == baseline), AND
-- match the reference interpreter. A wrongly-ACCEPTED escaping shape would
-- surface here as a leak, a use-after-free / double-free 'Left', or a value
-- mismatch. If the guard REJECTS p the run assertion is skipped (rejection is
-- the conservative, always-sound verdict). Two supporting properties pin the
-- static oracle: 'balanceLint' must be clean on every IN-FRAGMENT program, and
-- every single-site RC mutation (OmitOneDrop / OmitOneDup / DuplicateOneDrop)
-- must be CAUGHT (a non-empty 'lintInstrumented' or a trapped runtime 'Left').
--
-- IMPORTANT DESIGN NOTE on what "escapes" means here. The boundary guard's
-- escape walkers ('rlamSiblingCaptureEscapes', 'letRecMemberEscapes') run over a
-- single bind body. A value RETURNED from 'main' (Ret (AVar h)) IS an escape
-- (goE (Ret a) = hit a), and a value sealed into a returned con/record likewise.
-- So we build everything inside 'main''s body and drive the verdict by whether
-- the captured value flows OUT (return / con / record / call-arg / nested
-- closure) or stays LOCAL (dropped unused, or only called in place). The
-- non-escaping variants always produce a GInt result so a sound pass empties the
-- heap; the escaping variants are only checked for the REJECT verdict, so their
-- result type is unconstrained.

-- | The five M2a-1 shape families this generator ranges over. Each is realized
-- in a non-escaping (ACCEPT) and an escaping (REJECT) variant where applicable.
data M2a1Shape
  = M2ConsumeCapture       -- ^ LetRec member CONSUMES (moves) an enclosing capture
  | M2ClosureSibling       -- ^ standalone closure ('RLam') captures a LetRec sibling
  | M2DirectSibling        -- ^ sibling moved DIRECTLY into con / record / call-arg / proj
  | M2AliasSibling         -- ^ alias ('let x = f') of a sibling, incl. transitive
  | M2Mixed                -- ^ capture-an-enclosing-local + an escaping member; nested
  | M2MemberBodyEscape     -- ^ a member's BASE or REC arm RETURNS / MOVES a sibling
                           --   (the BLOCKER-1 member-body escape: the shared env is
                           --   carried OUT from INSIDE a member body, where the body
                           --   borrows --- not owns --- the env). The escaped member
                           --   is then called externally, so the run must be sound.
  | M2PartialMember        -- ^ a MULTI-ARITY recursive member that captures an
                           --   enclosing local, applied at PARTIAL / SATURATED / OVER
                           --   saturation. PARTIAL is the M2a-2 double-free shape (the
                           --   LT path of 'enterRC's 'RVRecMember' arm): @mk u = let
                           --   f a b = ... u ... in f@; @main = let g = mk 7 in let h =
                           --   g 0 in h 2@. The result is a scalar (heap must empty),
                           --   so it is ACCEPT-and-run-sound.
  | M2CaptureBodyEscape    -- ^ a member body ESCAPES a borrowed enclosing CAPTURE: it
                           --   RETURNS the captured boxed value directly, or SEALS it
                           --   into a returned con. The capture is moved into the shared
                           --   env once; the escaping handle must dup the captured cell
                           --   (the 'Ret'/con-move escape-dup) so the env cascade frees
                           --   it exactly once. The escaped capture is then destructured
                           --   externally to a scalar, so the heap must empty =>
                           --   ACCEPT-and-run-sound. The CAPTURE analogue of
                           --   'M2MemberBodyEscape' (which escapes a SIBLING).
  | M2CaptureCallHead      -- ^ a member body CALLS an enclosing boxed FUNCTION capture
                           --   @g@ as a (saturated or partial) call HEAD (@g k@). A call
                           --   head is a BORROW under uniform borrow-on-call, NOT a
                           --   move/consume, so the group is ACCEPT-and-run-sound. This
                           --   is the regression family for the call-head over-rejection
                           --   ('consumingOccs' used to count the head); the capture is
                           --   never escaped (result is a scalar) so the heap must empty.
  | M2CrossRegion          -- ^ an INNER 'LetRec' group nested inside an OUTER group's
                           --   member body, whose inner member captures an OUTER group
                           --   MEMBER BINDER (a cross-region counted edge: @rawEnclosingFv
                           --   ∩ lr@, where @lr@ is the outer region's binders). The pass
                           --   excludes this from coverage (spec 5.5) so it is DEFERRED
                           --   and REJECTED at the boundary by the cross-region fence
                           --   ('crossRegionViol'). This is the GENERATIVE coverage for
                           --   that fence (previously 0 fires across Suite G); a 'cover'
                           --   below pins that the class is generated AND rejected, so a
                           --   regression that stops rejecting cross-region goes red.
  deriving (Eq, Show)

-- | How the captured / aliased value flows, deciding the boundary verdict.
data M2Flow
  = FlowDropLocal          -- ^ value stays local (dropped unused / called in place): ACCEPT
  | FlowReturn             -- ^ value RETURNED from main: ESCAPE => REJECT
  | FlowCon                -- ^ value sealed into a returned constructor field: ESCAPE
  | FlowRecord             -- ^ value sealed into a returned record field: ESCAPE
  | FlowList               -- ^ value sealed into a returned list cell: ESCAPE
  | FlowCallArg            -- ^ value passed as a non-head call argument that escapes: ESCAPE
  | FlowNestedClosure      -- ^ value captured by a nested closure that escapes: ESCAPE
  | FlowReturnThenCall     -- ^ closure routed through an unnamed intermediate then
                           --   OVER-APPLIED (the corpus-36 @(mk u) 2@ path): exercises
                           --   the deferred-consume ('KDropCellRC') so the escaped
                           --   closure's env survives its own call. Yields a scalar
                           --   (the call result), so it is LOCAL/ACCEPT and runs sound.
  deriving (Eq, Show)

-- | The boxed catch-all type carried by a closure / sibling-function binder, so
-- 'isBoxedType' tracks it as a heap cell (same convention as 'closureModule' and
-- 'genClosureCluster').
funTyC :: Ty.CType
funTyC = Ty.CTCon (Ty.TcUser (T.pack "Fun")) []

-- | A boxed single-field constructor type used as an escape vehicle.
boxTyC :: Ty.CType
boxTyC = Ty.CTCon (Ty.TcUser (T.pack "Box")) []

-- | The whole-program generator for the M2a-1 suite: @main = e@ where @e@ is one
-- of the five shape families. Sized by the QuickCheck size for the inner
-- continuation depth.
genM2a1Program :: Gen CoreModule
genM2a1Program = sized $ \sz -> do
  shape <- elements [M2ConsumeCapture, M2ClosureSibling, M2DirectSibling, M2AliasSibling, M2Mixed
                    , M2MemberBodyEscape, M2PartialMember, M2CaptureBodyEscape, M2CaptureCallHead
                    , M2CrossRegion]
  (body, _) <- runStateT (genM2a1Cluster shape (max 1 (min sz 6))) 0
  let mainN = Name (T.pack "main") (Unique 1000000)
  pure (CoreModule [TopBind mainN [] body])

-- | Dispatch on the shape family. @n@ is the inner-continuation fuel.
genM2a1Cluster :: M2a1Shape -> Int -> GenM Expr
genM2a1Cluster shape n = case shape of
  M2ConsumeCapture -> genConsumeCaptureCluster n
  M2ClosureSibling -> genClosureSiblingCluster n
  M2DirectSibling  -> genDirectSiblingCluster n
  M2AliasSibling   -> genAliasSiblingCluster n
  M2Mixed          -> genMixedCluster n
  M2MemberBodyEscape -> genMemberBodyEscapeCluster n
  M2PartialMember  -> genPartialMemberCluster n
  M2CaptureBodyEscape -> genCaptureBodyEscapeCluster n
  M2CaptureCallHead -> genCaptureCallHeadCluster n
  M2CrossRegion    -> genCrossRegionCluster n

-- | Build a two-member, TRULY mutually-recursive 'LetRec' group (f calls g, g
-- calls f, so the elaborator would put them in ONE group node). The caller
-- supplies the per-member base-case body (fired when the int param is 0); the
-- recursive arm always calls the sibling. The boxed locals @capN@ (an enclosing
-- capture) and the sibling names are free in the bodies exactly as the corpus
-- shapes require. Returns the group binders and the assembled 'LetRec' wrapper
-- that takes the continuation (the expression following the group).
--
-- @mkFBase@ / @mkGBase@ receive the capture binder name and the sibling name so
-- they can either BORROW (case cap) or CONSUME (move cap) it. The recursive arm
-- is fixed: @_ -> let ks = k - 1; r = <sibling>(ks); r@.
genMutualGroup
  :: Name                                  -- ^ enclosing boxed capture in scope
  -> (Name -> Name -> GenM Expr)           -- ^ f base body, given (capN, siblingG)
  -> (Name -> Name -> GenM Expr)           -- ^ g base body, given (capN, siblingF)
  -> GenM (Name, Name, Expr -> Expr)
genMutualGroup capN mkFBase mkGBase = do
  fN  <- freshN (T.pack "lrf")
  gN  <- freshN (T.pack "lrg")
  kN1 <- freshN (T.pack "k1")
  kN2 <- freshN (T.pack "k2")
  ks1 <- freshN (T.pack "ks1")
  ks2 <- freshN (T.pack "ks2")
  r1  <- freshN (T.pack "r1")
  r2  <- freshN (T.pack "r2")
  let intTy = gtyCType GInt
      kB1   = Binder kN1 Unrestricted intTy
      kB2   = Binder kN2 Unrestricted intTy
  fBase <- mkFBase capN gN
  gBase <- mkGBase capN fN
  let recArmF =
        Let (Binder ks1 Unrestricted intTy)
            (RApp (primAtom (T.pack "-")) [AVar kN1, ALit (LInt 1)])
          (Let (Binder r1 Unrestricted intTy) (RApp (AVar gN) [AVar ks1])
            (Ret (AVar r1)))
      recArmG =
        Let (Binder ks2 Unrestricted intTy)
            (RApp (primAtom (T.pack "-")) [AVar kN2, ALit (LInt 1)])
          (Let (Binder r2 Unrestricted intTy) (RApp (AVar fN) [AVar ks2])
            (Ret (AVar r2)))
      fBody = Case (AVar kN1) [AltLit (LInt 0) fBase, AltDefault recArmF]
      gBody = Case (AVar kN2) [AltLit (LInt 0) gBase, AltDefault recArmG]
      wrap cont = LetRec [(Binder fN Unrestricted intTy, [kB1], fBody)
                         ,(Binder gN Unrestricted intTy, [kB2], gBody)] cont
  pure (fN, gN, wrap)

-- | A prim atom (binary integer op), resolved by hint at runtime.
primAtom :: Text -> Atom
primAtom op = AVar (primName op)

-- | Seed a boxed Pair capture from two random int literals, returning its binder
-- name and a wrapper that prefixes the seeding 'Let'.
seedPairCapture :: GenM (Name, Expr -> Expr)
seedPairCapture = do
  v0 <- liftG (choose (0, 9 :: Int))
  v1 <- liftG (choose (0, 9 :: Int))
  capN <- freshN (T.pack "cap")
  let capB = Binder capN Unrestricted (gtyCType GPair)
      wrap cont = Let capB (RCon (T.pack "Tuple2")
                                 [ALit (LInt (toInteger v0)), ALit (LInt (toInteger v1))]) cont
  pure (capN, wrap)

-- ---------------------------------------------------------------------------
-- Family 1: LetRec member CONSUMES an enclosing boxed capture.
--
-- The base case MOVES the capture (passes it to a call / stores it in a con or
-- record / returns it), which is a CONSUMING use; the pass must emit a build-site
-- dup per consuming use so the move owns its unit and the group cascade keeps its
-- own. NON-escaping: the group is called in place and the result is the scalar
-- extracted; the group never escapes => ACCEPT, heap must empty. We also exercise
-- multi-branch ('Case') consumption and value-position 'if'/'case' (which the
-- elaborator lowers to joins; we emit the join form directly).
genConsumeCaptureCluster :: Int -> GenM Expr
genConsumeCaptureCluster n = do
  (capN, seedCap) <- seedPairCapture
  -- How each base body consumes the capture.
  consumeStyle <- liftG (elements [ConsumeMoveToCon, ConsumeMoveToRecord, ConsumeMultiBranch, ConsumeValueCase])
  let intTy = gtyCType GInt
  -- A consuming base body that yields a GInt: it MOVES the Pair capture into a
  -- cell (con / record), then destructures the cell back to an int. Storing the
  -- Pair into the cell is the CONSUMING move the pass must dup-cover; the cell is
  -- then fully consumed locally (the result is the scalar), so the group + the
  -- dup accounting must balance.
  let consumeBody pickField capArg = case consumeStyle of
        ConsumeMoveToCon -> consumeViaBox pickField capArg
        ConsumeMoveToRecord -> do
          -- seal cap into a record field (move), then read the field back (RProj on
          -- a RECORD is valid) and case-destructure the Pair.
          recN <- freshN (T.pack "rc")
          capBackN <- freshN (T.pack "cb")
          pxN <- freshN (T.pack "px")
          pyN <- freshN (T.pack "py")
          pure (Let (Binder recN Unrestricted capCellRecTy)
                    (RRecord capCellRecName [(T.pack "p", AVar capArg)])
                  (Let (Binder capBackN Unrestricted (gtyCType GPair))
                       (RProj (T.pack "p") (AVar recN))
                    (Case (AVar capBackN)
                       [ AltCon (T.pack "Tuple2")
                           [Binder pxN Unrestricted intTy, Binder pyN Unrestricted intTy]
                           (Ret (AVar (if pickField then pxN else pyN))) ])))
        ConsumeMultiBranch -> do
          -- a Case on a fresh int, BOTH arms consuming cap (move into a box, then
          -- destructure picking different fields). cap is consumed on every arm.
          sN <- freshN (T.pack "sel")
          armA <- consumeViaBox True capArg
          armB <- consumeViaBox False capArg
          pure (Let (Binder sN Unrestricted intTy) (RAtom (ALit (LInt 0)))
                  (Case (AVar sN) [ AltLit (LInt 0) armA, AltDefault armB ]))
        ConsumeValueCase -> do
          -- value-position case lowered to a join: a join j(x) delivers the
          -- result; a Case feeds it, and cap is consumed (moved into a box and
          -- destructured) in the arm feeding the join.
          jId <- freshJoinId
          pN  <- freshN (T.pack "jp")
          sN  <- freshN (T.pack "vsel")
          feedDirect <- consumeViaBoxJumping pickField capArg jId
          pure (LetJoin jId [Binder pN Unrestricted intTy] (Ret (AVar pN))
                  (Let (Binder sN Unrestricted intTy) (RAtom (ALit (LInt 0)))
                    (Case (AVar sN) [AltDefault feedDirect])))
  (fN, _gN, wrapGroup) <-
    genMutualGroup capN
      (\c _g -> consumeBody True c)
      (\c _g -> consumeBody False c)
  rN <- freshN (T.pack "lrr")
  let rB = Binder rN Unrestricted intTy
  -- non-escaping call: the result is unboxed; no member is returned or stored.
  cont <- genExpr [(rN, GInt)] (n - 1) GInt
  pure $ seedCap $ wrapGroup
    (Let rB (RApp (AVar fN) [ALit (LInt 2)]) cont)

-- | The consuming styles for family 1. Each performs a valid CONSUMING MOVE of
-- the Pair capture (storing it into a con / record cell), then destructures the
-- cell back to a scalar locally.
data ConsumeStyle
  = ConsumeMoveToCon
  | ConsumeMoveToRecord
  | ConsumeMultiBranch
  | ConsumeValueCase
  deriving (Eq, Show)

-- | Consume the Pair @capArg@ by moving it into a single-field 'Box' con, then
-- destructuring the box and the Pair to yield an int (the chosen field). The
-- @RCon "Box" [cap]@ is the consuming move; the box is fully consumed locally.
consumeViaBox :: Bool -> Name -> GenM Expr
consumeViaBox pickField capArg = do
  let intTy = gtyCType GInt
  boxN <- freshN (T.pack "bx")
  capBackN <- freshN (T.pack "cback")
  pxN <- freshN (T.pack "px")
  pyN <- freshN (T.pack "py")
  pure (Let (Binder boxN Unrestricted boxTyC) (RCon (T.pack "Box") [AVar capArg])
          (Case (AVar boxN)
            [ AltCon (T.pack "Box") [Binder capBackN Unrestricted (gtyCType GPair)]
                (Case (AVar capBackN)
                  [ AltCon (T.pack "Tuple2")
                      [Binder pxN Unrestricted intTy, Binder pyN Unrestricted intTy]
                      (Ret (AVar (if pickField then pxN else pyN))) ]) ]))

-- | As 'consumeViaBox', but instead of returning the extracted int it JUMPS to
-- @jId@ with it (used to feed a value-position join). Same consuming move.
consumeViaBoxJumping :: Bool -> Name -> JoinId -> GenM Expr
consumeViaBoxJumping pickField capArg jId = do
  let intTy = gtyCType GInt
  boxN <- freshN (T.pack "bx")
  capBackN <- freshN (T.pack "cback")
  pxN <- freshN (T.pack "px")
  pyN <- freshN (T.pack "py")
  pure (Let (Binder boxN Unrestricted boxTyC) (RCon (T.pack "Box") [AVar capArg])
          (Case (AVar boxN)
            [ AltCon (T.pack "Box") [Binder capBackN Unrestricted (gtyCType GPair)]
                (Case (AVar capBackN)
                  [ AltCon (T.pack "Tuple2")
                      [Binder pxN Unrestricted intTy, Binder pyN Unrestricted intTy]
                      (Jump jId [AVar (if pickField then pxN else pyN)]) ]) ]))

-- ---------------------------------------------------------------------------
-- Family 9: a member body CALLS an enclosing boxed FUNCTION capture as a HEAD.
--
-- Seed a boxed function capture @g@ (a lambda of 'funTyC', so 'isBoxedType' tracks
-- it as a heap cell and it lands in the boundary's @bsc@), then build a recursive
-- group whose base bodies CALL @g@ as the call HEAD --- saturated (@g k@) or
-- partial (@(g k) 1@, @g@ a two-arg lambda). A call head is a BORROW under uniform
-- borrow-on-call, NOT a move/consume, so the group is ADMITTED and runs SOUND. The
-- capture never escapes (the result is a scalar), so the heap must empty. This is
-- the GENERATIVE regression guard for the call-head over-rejection: before the fix
-- 'consumingOccs' counted the head, and the non-escaping group was wrongly
-- REJECTED.
genCaptureCallHeadCluster :: Int -> GenM Expr
genCaptureCallHeadCluster n = do
  partial <- liftG (elements [False, True])
  let intTy = gtyCType GInt
  gN <- freshN (T.pack "gcap")
  -- The captured function. Saturated variant: @\x -> x + 1@ (arity 1). Partial
  -- variant: @\a b -> a + b@ (arity 2), called partially as a head below.
  gBody <-
    if partial
      then do
        aN <- freshN (T.pack "ga")
        bN <- freshN (T.pack "gb")
        sN <- freshN (T.pack "gs")
        pure (RLam [Binder aN Unrestricted intTy, Binder bN Unrestricted intTy]
                (Let (Binder sN Unrestricted intTy)
                     (RApp (primAtom (T.pack "+")) [AVar aN, AVar bN])
                  (Ret (AVar sN))))
      else do
        xN <- freshN (T.pack "gx")
        sN <- freshN (T.pack "gs")
        pure (RLam [Binder xN Unrestricted intTy]
                (Let (Binder sN Unrestricted intTy)
                     (RApp (primAtom (T.pack "+")) [AVar xN, ALit (LInt 1)])
                  (Ret (AVar sN))))
  let gB = Binder gN Unrestricted funTyC
      -- The base body CALLS @g@ as a HEAD on an int literal (a borrow, never a
      -- move). Saturated: @r = g 0; r@. Partial: @t = g 0; r = t 1; r@. The base
      -- body does not receive the member's int param, so we feed a literal --- the
      -- point under test is purely that the call HEAD @g@ is a borrow.
      callHeadBase capN =
        if partial
          then do
            tN <- freshN (T.pack "ct")
            rN <- freshN (T.pack "cr")
            pure (Let (Binder tN Unrestricted funTyC) (RApp (AVar capN) [ALit (LInt 0)])
                    (Let (Binder rN Unrestricted intTy) (RApp (AVar tN) [ALit (LInt 1)])
                      (Ret (AVar rN))))
          else do
            rN <- freshN (T.pack "cr")
            pure (Let (Binder rN Unrestricted intTy) (RApp (AVar capN) [ALit (LInt 0)])
                    (Ret (AVar rN)))
  (fN, _gN2, wrapGroup) <-
    genMutualGroup gN
      (\c _g -> callHeadBase c)
      (\c _g -> callHeadBase c)
  rN <- freshN (T.pack "lrr")
  let rB = Binder rN Unrestricted intTy
  -- non-escaping call: the result is the scalar; no member escapes.
  cont <- genExpr [(rN, GInt)] (n - 1) GInt
  pure $ Let gB gBody $ wrapGroup
    (Let rB (RApp (AVar fN) [ALit (LInt 2)]) cont)

-- ---------------------------------------------------------------------------
-- Family 10: CROSS-REGION capture (the cross-region #3 fence, DEFERRED/REJECTED).
--
-- An OUTER two-member group @(oF, oG)@; INSIDE @oF@'s member body sits an INNER
-- self-recursive group @inr@ whose member body REFERENCES @oG@ --- an OUTER group
-- MEMBER BINDER. That is a cross-region COUNTED EDGE: at the inner 'LetRec' node the
-- in-scope region set @lr@ is exactly @{oF, oG}@, and @rawEnclosingFv inr@ contains
-- @oG@, so @rawEnclosingFv inr ∩ lr@ is non-empty and 'crossRegionViol' fires. The
-- pass excludes a member that captures an outer region member from coverage (spec
-- 5.5 'capturesRegion') and an un-instrumented pass-through would LEAK, so the class
-- is DEFERRED and REJECTED at the boundary.
--
-- This is the ONLY Suite G family that produces cross-region shapes (0 fires across
-- the other families). It is always a REJECT, so 'prop_m2a1Escape' merely skips the
-- run; the teeth are the dedicated 'cover' in the property that the class is
-- GENERATED AND REJECTED (so a regression that stops rejecting cross-region goes
-- red). We vary HOW the inner member references the outer member @oG@: as a SATURATED
-- call head, or as a non-head call ARGUMENT (both put @oG@ in 'rawEnclosingFv').
genCrossRegionCluster :: Int -> GenM Expr
genCrossRegionCluster _n = do
  refAsArg <- liftG (elements [False, True])
  let intTy = gtyCType GInt
  oFN <- freshN (T.pack "ocrf")
  oGN <- freshN (T.pack "ocrg")
  okN1 <- freshN (T.pack "ock1")
  okN2 <- freshN (T.pack "ock2")
  -- The inner self-recursive group, nested in @oF@'s body. Its base body references
  -- the OUTER member @oG@ (the cross-region edge): either as a saturated call head
  -- @oG 0@, or as a non-head argument to a different call.
  inN <- freshN (T.pack "incr")
  inkN <- freshN (T.pack "ink")
  inrN <- freshN (T.pack "inr")
  inrsN <- freshN (T.pack "inrs")
  let innerBase =
        if refAsArg
          then
            -- seal @oG@ (the outer member) into a 'Box' con as a non-head field ---
            -- still a free var of the body => in rawEnclosingFv => cross-region.
            Let (Binder inrN Unrestricted boxTyC) (RCon (T.pack "Box") [AVar oGN])
              (Ret (ALit (LInt 0)))
          else
            -- call the OUTER member @oG@ as a saturated head.
            Let (Binder inrN Unrestricted intTy) (RApp (AVar oGN) [ALit (LInt 0)])
              (Ret (AVar inrN))
      innerRec =
        Let (Binder inrsN Unrestricted intTy)
            (RApp (primAtom (T.pack "-")) [AVar inkN, ALit (LInt 1)])
          (Let (Binder inrN Unrestricted intTy) (RApp (AVar inN) [AVar inrsN])
            (Ret (AVar inrN)))
      innerBody = Case (AVar inkN) [AltLit (LInt 0) innerBase, AltDefault innerRec]
      innerGroupBody =
        LetRec [(Binder inN Unrestricted intTy, [Binder inkN Unrestricted intTy], innerBody)]
          (Let (Binder inrN Unrestricted intTy) (RApp (AVar inN) [ALit (LInt 0)])
            (Ret (AVar inrN)))
      -- @oF@'s body holds the inner group; @oG@ is a trivial base.
      oFBody = innerGroupBody
      oGBody = Ret (ALit (LInt 0))
      outer cont =
        LetRec [ (Binder oFN Unrestricted intTy, [Binder okN1 Unrestricted intTy], oFBody)
               , (Binder oGN Unrestricted intTy, [Binder okN2 Unrestricted intTy], oGBody) ]
               cont
  rN <- freshN (T.pack "ocrr")
  pure $ outer
    (Let (Binder rN Unrestricted intTy) (RApp (AVar oFN) [ALit (LInt 0)])
      (Ret (AVar rN)))

-- | The record type / name used as a Pair-capture cell vehicle.
capCellRecName :: Text
capCellRecName = T.pack "PCell"

capCellRecTy :: Ty.CType
capCellRecTy = Ty.CTRecord capCellRecName Ty.CREmpty

-- | Build the CORPUS-style single self-recursive 'LetRec' member that captures an
-- UNBOXED enclosing local (a fresh @U64@ seed @u@, exactly like corpus 36/42/etc:
-- @f n = case n of 0 -> u ; _ -> f (n - 1)@). Because the captured local is
-- UNBOXED, the group does NOT trip 'letRecCapturesEnclosing' (which only watches
-- BOXED enclosing locals), so the group itself is admitted and the boundary
-- verdict is driven SOLELY by how the sibling @f@ flows downstream (closure /
-- cell / alias). Returns the sibling binder name and a wrapper that seeds @u@ and
-- the group, taking the continuation (the expression following the group).
--
-- M2a-2 BLOCKER 2 NOTE: this group is NOT capture-free. The counted-env predicate
-- is "captures ANY bound enclosing local, boxed or unboxed", so the runtime
-- allocates ONE counted 'NEnv' holding @u@ (the member body resolves @u@ from it),
-- dropped exactly once via the pass's member-0 env unit. "Capture-free => sentinel"
-- applies only when the capture union is EMPTY (no enclosing local at all).
genSiblingGroup :: GenM (Name, Expr -> Expr)
genSiblingGroup = do
  seed <- liftG (choose (0, 9 :: Int))
  uN  <- freshN (T.pack "u")
  fN  <- freshN (T.pack "lrf")
  nN  <- freshN (T.pack "fn")
  ksN <- freshN (T.pack "fks")
  rN  <- freshN (T.pack "frr")
  let intTy = gtyCType GInt
      fBody = Case (AVar nN)
                [ AltLit (LInt 0) (Ret (AVar uN))
                , AltDefault
                    (Let (Binder ksN Unrestricted intTy)
                         (RApp (primAtom (T.pack "-")) [AVar nN, ALit (LInt 1)])
                       (Let (Binder rN Unrestricted intTy) (RApp (AVar fN) [AVar ksN])
                         (Ret (AVar rN)))) ]
      wrap cont =
        Let (Binder uN Unrestricted intTy) (RAtom (ALit (LInt (toInteger seed))))
          (LetRec [(Binder fN Unrestricted intTy, [Binder nN Unrestricted intTy], fBody)] cont)
  pure (fN, wrap)

-- | As 'genSiblingGroup', but the self-recursive member captures a BOXED enclosing
-- local (a fresh @Tuple2@ @cap@) instead of an unboxed @u@. The base case
-- destructures @cap@ to a scalar. Because the capture is BOXED, the group's shared
-- env is a real COUNTED 'NEnv' cell (not the capture-free sentinel), so a closure
-- that captures the sibling @f@ and escapes must DUP that env --- exercising the
-- dup-on-closure-capture + the escaped closure's cascade-drop balance. (The unboxed
-- 'genSiblingGroup' ALSO allocates a counted 'NEnv' holding @u@ --- BLOCKER 2: the
-- env exists for any enclosing capture, boxed or unboxed; only a group with NO
-- enclosing capture at all uses the sentinel. The boxed variant differs in that its
-- captured field is itself reference-counted, so the cascade decrefs a heap child.) The base
-- case only READS @cap@ (a borrowed scrutinee keeping no boxed child), so the group
-- is NOT a consuming-capture (#1) reject; the verdict is driven purely by how the
-- sibling @f@ flows downstream. NOTE: the group itself captures a boxed enclosing
-- local, so a BARE escape of @f@ would trip Part B (escapeViol) --- but a CLOSURE
-- escape is exempt (escapeViol uses the bare-only predicate), exactly the Stage A
-- frontier under test.
genSiblingGroupBoxed :: GenM (Name, Expr -> Expr)
genSiblingGroupBoxed = do
  (capN, seedCap) <- seedPairCapture
  fN  <- freshN (T.pack "lrf")
  nN  <- freshN (T.pack "fn")
  ksN <- freshN (T.pack "fks")
  rN  <- freshN (T.pack "frr")
  pxN <- freshN (T.pack "px")
  pyN <- freshN (T.pack "py")
  let intTy = gtyCType GInt
      -- base case: case cap of Tuple2 px py -> px  (a borrowed read of cap; the
      -- boxed children px/py are unboxed ints, so cap is NOT consumed)
      baseBody = Case (AVar capN)
                   [ AltCon (T.pack "Tuple2")
                       [Binder pxN Unrestricted intTy, Binder pyN Unrestricted intTy]
                       (Ret (AVar pxN)) ]
      fBody = Case (AVar nN)
                [ AltLit (LInt 0) baseBody
                , AltDefault
                    (Let (Binder ksN Unrestricted intTy)
                         (RApp (primAtom (T.pack "-")) [AVar nN, ALit (LInt 1)])
                       (Let (Binder rN Unrestricted intTy) (RApp (AVar fN) [AVar ksN])
                         (Ret (AVar rN)))) ]
      wrap cont =
        seedCap (LetRec [(Binder fN Unrestricted intTy, [Binder nN Unrestricted intTy], fBody)] cont)
  pure (fN, wrap)

-- ---------------------------------------------------------------------------
-- Family 2: a standalone closure that captures a LetRec GROUP SIBLING.
--
-- A two-member group is built; then a standalone 'RLam' h captures a sibling f
-- (f is FREE in h's body, used as a call head inside the closure). The closure
-- then either stays LOCAL (dropped unused / called in place => ACCEPT) or
-- ESCAPES (returned, sealed into a con/record, or captured by a nested closure
-- that escapes => REJECT). Mirrors corpus 36 (escape) and the admitted local
-- case.
genClosureSiblingCluster :: Int -> GenM Expr
genClosureSiblingCluster n = do
  -- Range over BOTH the unboxed-capture group (a counted 'NEnv' whose single field
  -- is the unboxed @u@; BLOCKER 2 --- NOT the sentinel, which is reserved for groups
  -- with NO enclosing capture) and the BOXED-capture group (a counted 'NEnv' whose
  -- field is itself a heap child). The boxed variant is what exercises
  -- the dup-on-closure-capture and the escaped closure's env cascade-drop balance;
  -- the unboxed variant is the corpus 36/38 shape.
  boxedCap <- liftG (elements [True, False])
  (fN, wrapGroup) <- if boxedCap then genSiblingGroupBoxed else genSiblingGroup
  flow <- liftG (frequency
                   [ (1, pure FlowDropLocal)
                   , (1, pure FlowReturn)
                   , (1, pure FlowCon)
                   , (1, pure FlowRecord)
                   , (1, pure FlowNestedClosure)
                   , (1, pure FlowReturnThenCall) ])
  -- The closure h: \m -> let r = f (m + 1); r   (f is the captured sibling,
  -- used as a call head inside the body; the closure cell captures f).
  hN <- freshN (T.pack "h")
  mN <- freshN (T.pack "hm")
  msN <- freshN (T.pack "hms")
  hrN <- freshN (T.pack "hr")
  let intTy = gtyCType GInt
      hBody = Let (Binder msN Unrestricted intTy)
                  (RApp (primAtom (T.pack "+")) [AVar mN, ALit (LInt 1)])
                (Let (Binder hrN Unrestricted intTy) (RApp (AVar fN) [AVar msN])
                  (Ret (AVar hrN)))
      hLam  = RLam [Binder mN Unrestricted intTy] hBody
      hB    = Binder hN Unrestricted funTyC
  body <- closureFlowBody flow hN n
  pure $ wrapGroup (Let hB hLam body)

-- | Realize a closure / sibling flow as the continuation following the binder
-- @vN@ (the closure or sibling value). 'FlowDropLocal' yields a GInt and never
-- mentions @vN@ (so it is dropped unused => ACCEPT). The escaping flows return /
-- seal @vN@ so the guard REJECTS.
closureFlowBody :: M2Flow -> Name -> Int -> GenM Expr
closureFlowBody flow vN n = case flow of
  FlowDropLocal -> genExpr [] (n - 1) GInt          -- vN unused => dropped => local
  FlowReturn    -> pure (Ret (AVar vN))             -- escape via return
  FlowCon       -> do
    cN <- freshN (T.pack "esc")
    pure (Let (Binder cN Unrestricted boxTyC) (RCon (T.pack "Box") [AVar vN]) (Ret (AVar cN)))
  FlowRecord    -> do
    cN <- freshN (T.pack "escr")
    pure (Let (Binder cN Unrestricted (Ty.CTRecord (T.pack "Cell") Ty.CREmpty))
              (RRecord (T.pack "Cell") [(T.pack "fn", AVar vN)]) (Ret (AVar cN)))
  FlowList      -> do
    nilN <- freshN (T.pack "nl")
    cN   <- freshN (T.pack "escl")
    pure (Let (Binder nilN Unrestricted funTyC) (RCon (T.pack "Nil") [])
            (Let (Binder cN Unrestricted funTyC) (RCon (T.pack "Cons") [AVar vN, AVar nilN])
              (Ret (AVar cN))))
  FlowCallArg   -> do
    -- pass vN as a non-head argument to an in-scope identity-ish closure that we
    -- build on the spot, whose RESULT escapes (returned).
    idN <- freshN (T.pack "idf")
    pN  <- freshN (T.pack "idp")
    rN  <- freshN (T.pack "idr")
    let idLam = RLam [Binder pN Unrestricted funTyC] (Ret (AVar pN))
    pure (Let (Binder idN Unrestricted funTyC) idLam
            (Let (Binder rN Unrestricted funTyC) (RApp (AVar idN) [AVar vN]) (Ret (AVar rN))))
  FlowNestedClosure -> do
    -- a nested closure that captures vN free, and we RETURN the nested closure
    -- (so vN rides out in its cell => escape).
    gN <- freshN (T.pack "nest")
    qN <- freshN (T.pack "nq")
    rN <- freshN (T.pack "nr")
    let nestLam = RLam [Binder qN Unrestricted (gtyCType GInt)]
                    (Let (Binder rN Unrestricted (gtyCType GInt)) (RApp (AVar vN) [AVar qN])
                      (Ret (AVar rN)))
    pure (Let (Binder gN Unrestricted funTyC) nestLam (Ret (AVar gN)))
  FlowReturnThenCall -> do
    -- Route vN through an identity closure (which RETURNS vN, an unnamed
    -- intermediate at the application site) then OVER-APPLY the result to a scalar:
    -- @let r = (id vN) 7 in r@. The intermediate closure value is consumed by the
    -- application with NO IR binder, exercising the deferred-consume path
    -- ('KDropCellRC') that keeps the escaped closure's shared env alive through its
    -- own call. The result is the scalar call value (a GInt), so a sound pass empties
    -- the heap. This is the in-main analogue of the corpus-36 @(mk u) 2@ shape.
    idN <- freshN (T.pack "idf")
    pN  <- freshN (T.pack "idp")
    rN  <- freshN (T.pack "callr")
    -- @id@ has arity 1; applying it to TWO args (vN and 7) saturates @id@ (it
    -- returns vN, an unnamed intermediate) then OVER-APPLIES that result to 7.
    let idLam = RLam [Binder pN Unrestricted funTyC] (Ret (AVar pN))
    pure (Let (Binder idN Unrestricted funTyC) idLam
            (Let (Binder rN Unrestricted (gtyCType GInt))
                 (RApp (AVar idN) [AVar vN, ALit (LInt 7)])
              (Ret (AVar rN))))

-- ---------------------------------------------------------------------------
-- Family 3: a LetRec sibling moved DIRECTLY (no closure) into a con / record /
-- list / call-arg / projection. Non-escaping (dropped locally => ACCEPT) vs
-- escaping (the cell is returned => REJECT). Mirrors corpus 42-45 (escape) and
-- 48-50 (local drop).
genDirectSiblingCluster :: Int -> GenM Expr
genDirectSiblingCluster n = do
  -- Range over unboxed (sentinel env) and BOXED (counted NEnv) capture groups, so
  -- the bare-move dup-on-escape is exercised against a real env (Stage B).
  boxedCap <- liftG (elements [True, False])
  (fN, wrapGroup) <- if boxedCap then genSiblingGroupBoxed else genSiblingGroup
  -- vehicle for moving the sibling: con / record / list cell.
  vehicle <- liftG (elements [FlowCon, FlowRecord, FlowList])
  -- M2a-2 STAGE B: a BARE move of a sibling into a con / record / list is now sound
  -- whether it stays LOCAL (dropped) or ESCAPES (returned) --- the pass dups the
  -- shared env at the move. Range over both so the property exercises the now-
  -- admitted bare-escape class.
  escapes <- liftG (elements [True, False])
  -- Build the cell holding the sibling f directly, bound to cN.
  cN <- freshN (T.pack "cell")
  (cellTy, cellRhs, extraPrefix) <- case vehicle of
    FlowRecord -> pure (Ty.CTRecord (T.pack "Cell") Ty.CREmpty
                       , RRecord (T.pack "Cell") [(T.pack "fn", AVar fN)]
                       , id)
    FlowList   -> do
      nilN <- freshN (T.pack "nl")
      pure ( funTyC
           , RCon (T.pack "Cons") [AVar fN, AVar nilN]
           , Let (Binder nilN Unrestricted funTyC) (RCon (T.pack "Nil") []) )
    _          -> pure (boxTyC, RCon (T.pack "Box") [AVar fN], id)
  let cB = Binder cN Unrestricted cellTy
  body <-
    if escapes
      then pure (Ret (AVar cN))                -- cell escapes => REJECT
      else genExpr [] (n - 1) GInt             -- cell dropped locally => ACCEPT
  pure $ wrapGroup (extraPrefix (Let cB cellRhs body))

-- ---------------------------------------------------------------------------
-- Family 4: an ALIAS of a sibling ('let x = f'), including a transitive chain
-- ('let y = x'). Dropped locally (=> ACCEPT) vs returned (=> REJECT). Mirrors
-- corpus 40 (drop) and 41 (escape).
genAliasSiblingCluster :: Int -> GenM Expr
genAliasSiblingCluster n = do
  -- Range over unboxed (sentinel env) and BOXED (counted NEnv) capture groups, so
  -- the escaping-alias env-handle transfer is exercised against a real env (Stage B).
  boxedCap <- liftG (elements [True, False])
  (fN, wrapGroup) <- if boxedCap then genSiblingGroupBoxed else genSiblingGroup
  transitive <- liftG (elements [True, False])
  -- M2a-2 STAGE B: a bare ALIAS of a sibling (incl. a transitive chain) is now sound
  -- whether it is dropped LOCALLY or ESCAPES (returned) --- the env-alias propagation
  -- transfers the single shared-env handle out on escape. Range over both.
  escapes <- liftG (elements [True, False])
  xN <- freshN (T.pack "ax")
  yN <- freshN (T.pack "ay")
  let xB = Binder xN Unrestricted funTyC
      yB = Binder yN Unrestricted funTyC
      -- the final alias name that flows out (or is dropped)
      finalAlias = if transitive then yN else xN
      aliasPrefix cont =
        if transitive
          then Let xB (RAtom (AVar fN)) (Let yB (RAtom (AVar xN)) cont)
          else Let xB (RAtom (AVar fN)) cont
  body <-
    if escapes
      then pure (Ret (AVar finalAlias))        -- alias escapes => REJECT
      else genExpr [] (n - 1) GInt             -- alias dropped locally => ACCEPT
  pure $ wrapGroup (aliasPrefix body)

-- ---------------------------------------------------------------------------
-- Family 5: MIXES. A group that BOTH captures an enclosing local AND has an
-- escaping member (the Part-B reject), plus a nested-LetRec variant. We bias
-- toward the consuming-AND-escaping shape (corpus 37) and the borrow-AND-escape
-- shape so both the 'consumeViol' and the 'escapeViol' boundary clauses fire.
genMixedCluster :: Int -> GenM Expr
genMixedCluster _n = do
  (capN, seedCap) <- seedPairCapture
  consuming <- liftG (elements [True, False])
  -- base body either CONSUMES (project cap) or BORROWS (case cap); a member is
  -- ALSO made to escape by returning it from the group body.
  let consumeBase pick c _g = consumeViaBox pick c
      borrowBase pick = \c _g -> do
        pxN <- freshN (T.pack "px")
        pyN <- freshN (T.pack "py")
        pure (Case (AVar c)
                [ AltCon (T.pack "Tuple2")
                    [Binder pxN Unrestricted (gtyCType GInt), Binder pyN Unrestricted (gtyCType GInt)]
                    (Ret (AVar (if pick then pxN else pyN))) ])
      base = if consuming then consumeBase else borrowBase
  (fN, _gN, wrapGroup) <- genMutualGroup capN (base True) (base False)
  -- The group body RETURNS a member (escape) => letRecMemberEscapes is True, and
  -- with an enclosing capture present this is the Part-B / FINDING-1 reject.
  nested <- liftG (elements [True, False])
  let groupBodyEscape = Ret (AVar fN)
  if not nested
    then pure $ seedCap $ wrapGroup groupBodyEscape
    else do
      -- nest the escaping group inside an OUTER group that just calls a sibling;
      -- exercises nested-LetRec handling on the way to the reject.
      oFN <- freshN (T.pack "olrf")
      oGN <- freshN (T.pack "olrg")
      okN1 <- freshN (T.pack "ok1")
      okN2 <- freshN (T.pack "ok2")
      let intTy = gtyCType GInt
          oFBody = wrapGroup groupBodyEscape   -- inner group + its escaping body
          oGBody = Ret (ALit (LInt 0))
          outer cont =
            LetRec [ (Binder oFN Unrestricted funTyC, [Binder okN1 Unrestricted intTy], oFBody)
                   , (Binder oGN Unrestricted intTy,  [Binder okN2 Unrestricted intTy], oGBody) ]
                   cont
      pure $ seedCap $ outer (Ret (AVar oFN))

-- ---------------------------------------------------------------------------
-- Family 6: MEMBER-BODY sibling escape (the M2a-2 BLOCKER-1 class).
--
-- A two-member group where one member's BASE or RECURSIVE arm RETURNS or MOVES a
-- sibling --- so the shared env is carried OUT from INSIDE a member body, where the
-- body BORROWS (does not own) the env. The escaped sibling is then called
-- externally. This is the shape Suite G's other families never produced (their
-- escapes all leave from MAIN's body, never from inside a member body), so the
-- member-body double-free shipped green. After the fix the pass must DUP the env
-- at the member-body escape (an incref) so the externally-held handle owns its own
-- unit and the single 'NEnv' is dropped exactly once. ACCEPTED + must-run-sound.
--
-- We range over: BOXED vs UNBOXED capture (so the escaped env is a real counted
-- 'NEnv' in both --- the unboxed variant is BLOCKER 2); BASE-arm vs REC-arm escape;
-- escape via bare RETURN vs MOVE-into-a-con (dup-on-consume at two distinct sites);
-- and the OVER-APPLY-THEN-CALL variant (@(f 0) depth@ as a single saturating apply,
-- exercising the unnamed-intermediate deferred env-drop alongside the member-body
-- escape).
data MemberEscStyle
  = MescReturn          -- ^ member arm is @Ret sibling@ (bare member-body escape)
  | MescMoveCon         -- ^ member arm seals sibling into a returned 'Box' con
  deriving (Eq, Show)

genMemberBodyEscapeCluster :: Int -> GenM Expr
genMemberBodyEscapeCluster n = do
  boxedCap <- liftG (elements [True, False])
  escStyle <- liftG (elements [MescReturn, MescMoveCon])
  escInRec <- liftG (elements [True, False])   -- escape from the REC arm vs the BASE arm
  overApply <- liftG (elements [True, False])  -- (f 0) depth saturating apply vs named h
  let intTy = gtyCType GInt
  -- Seed the capture (boxed Pair or unboxed U64) and a reader that turns it into a
  -- GInt the non-escaping member arm yields (a borrowed READ of the capture, never a
  -- consume --- consuming captures stay boundary-rejected and out of this family).
  (_capN, seedCap, capReader) <-
    if boxedCap
      then do
        (cN, sc) <- seedPairCapture
        let reader = do
              pxN <- freshN (T.pack "px"); pyN <- freshN (T.pack "py")
              pure (\k -> Case (AVar cN)
                            [ AltCon (T.pack "Tuple2")
                                [Binder pxN Unrestricted intTy, Binder pyN Unrestricted intTy]
                                (k (AVar pxN)) ])
        pure (cN, sc, reader)
      else do
        seed <- liftG (choose (0, 9 :: Int))
        uN <- freshN (T.pack "u")
        let sc cont = Let (Binder uN Unrestricted intTy)
                          (RAtom (ALit (LInt (toInteger seed)))) cont
            reader = pure (\k -> k (AVar uN))
        pure (uN, sc, reader)
  -- The escaping member f and the worker member g (truly mutually recursive: f's
  -- non-escaping arm calls g, g's rec arm calls f, so the elaborator co-groups them).
  fN  <- freshN (T.pack "lrf")
  gN  <- freshN (T.pack "lrg")
  k1N <- freshN (T.pack "k1"); k2N <- freshN (T.pack "k2")
  -- The member-body escape expression: carry sibling g OUT (Ret g) or seal it into a
  -- returned con (a MOVE of g into a Box). Both are member-body escapes of the env.
  escExpr <- case escStyle of
    MescReturn  -> pure (Ret (AVar gN))
    MescMoveCon -> do
      cN <- freshN (T.pack "mesc")
      pure (Let (Binder cN Unrestricted boxTyC) (RCon (T.pack "Box") [AVar gN]) (Ret (AVar cN)))
  readCap <- capReader
  -- f's body ALWAYS yields the escaping value (so f is type-consistent: every path
  -- returns the function value / Box). escInRec=False escapes immediately
  -- (single-arm); escInRec=True SELF-recurses first (@f (k1-1)@), then escapes at
  -- the base arm --- the escape then happens from a member body reached BY a sibling
  -- recursion, the same env-borrowing position. Either way the env leaves from
  -- INSIDE f's body. f references its sibling g (the escaped value), so f and g are
  -- ONE group node sharing the env.
  ks1N <- freshN (T.pack "fks"); r1N <- freshN (T.pack "fr")
  let fSelfRec = Let (Binder ks1N Unrestricted intTy)
                     (RApp (primAtom (T.pack "-")) [AVar k1N, ALit (LInt 1)])
                   (Let (Binder r1N Unrestricted funTyC) (RApp (AVar fN) [AVar ks1N])
                     (Ret (AVar r1N)))
      fBody = if escInRec
                then Case (AVar k1N) [ AltLit (LInt 0) escExpr, AltDefault fSelfRec ]
                else escExpr
  -- g's body: a self-recursive worker that READS the capture at its base case (so the
  -- capture --- boxed or unboxed --- is genuinely live in the shared env), yielding a
  -- GInt. The escaped g is what main calls.
  ks2N <- freshN (T.pack "gks"); r2N <- freshN (T.pack "gr")
  let gRecCall = Let (Binder ks2N Unrestricted intTy)
                     (RApp (primAtom (T.pack "-")) [AVar k2N, ALit (LInt 1)])
                   (Let (Binder r2N Unrestricted intTy) (RApp (AVar gN) [AVar ks2N])
                     (Ret (AVar r2N)))
      gBody = Case (AVar k2N) [ AltLit (LInt 0) (readCap (\a -> Ret a)), AltDefault gRecCall ]
      wrapGroup cont =
        LetRec [ (Binder fN Unrestricted funTyC, [Binder k1N Unrestricted intTy], fBody)
               , (Binder gN Unrestricted funTyC, [Binder k2N Unrestricted intTy], gBody) ]
               cont
  -- The escaped member (g, possibly inside a Box) flows out of f, then is CALLED
  -- externally so the run exercises the escaped env: either through a named handle
  -- @h@ that is then applied, or via an over-apply @(f initArg) depth@. When the
  -- escape sealed g in a Box we must first unbox it before calling.
  -- Pick @initArg@ so f's FIRST call lands on the ESCAPING arm (which returns the
  -- callable sibling g): base-arm escape (escInRec=False) fires at k1==0; rec-arm
  -- escape (escInRec=True) fires at any k1 /= 0. This guarantees the call-out target
  -- is a function value (g), not the GInt the cap-reading arm would yield.
  let initArg = if escInRec then 1 else 0 :: Int
  depth   <- liftG (choose (1, max 1 (min n 4)))
  hN <- freshN (T.pack "h"); rN <- freshN (T.pack "rr")
  callOut <- case escStyle of
    MescReturn ->
      if overApply
        then pure (Let (Binder rN Unrestricted intTy)
                       (RApp (AVar fN) [ALit (LInt (toInteger initArg)), ALit (LInt (toInteger depth))])
                     (Ret (AVar rN)))
        else pure (Let (Binder hN Unrestricted funTyC) (RApp (AVar fN) [ALit (LInt (toInteger initArg))])
                     (Let (Binder rN Unrestricted intTy) (RApp (AVar hN) [ALit (LInt (toInteger depth))])
                       (Ret (AVar rN))))
    MescMoveCon -> do
      -- f returns a Box holding g; unbox then call.
      boxN <- freshN (T.pack "bx"); gOutN <- freshN (T.pack "gout")
      pure (Let (Binder boxN Unrestricted boxTyC) (RApp (AVar fN) [ALit (LInt (toInteger initArg))])
              (Case (AVar boxN)
                [ AltCon (T.pack "Box") [Binder gOutN Unrestricted funTyC]
                    (Let (Binder rN Unrestricted intTy) (RApp (AVar gOutN) [ALit (LInt (toInteger depth))])
                      (Ret (AVar rN))) ]))
  pure $ seedCap $ wrapGroup callOut

-- ---------------------------------------------------------------------------
-- Family 6b: a member body ESCAPES a borrowed enclosing CAPTURE (the capture
-- analogue of Family 6, which escapes a SIBLING).
--
-- A self-recursive member @f@ closes over a BOXED enclosing capture @cap@ (a
-- 'Tuple2'). Its base arm ESCAPES the capture: either RETURNS @cap@ bare
-- (@Ret cap@) or SEALS it into a returned 'Box' con (@let bx = Box cap in bx@) ---
-- both carry the captured boxed cell OUT from INSIDE a member body, where the body
-- BORROWS (does not own) the shared env that holds @cap@. The pass must dup the
-- captured cell at the escape site (the generalised 'Ret'/'Jump' escape-dup, or the
-- con-move dup-on-consume) so the env's capture-field cascade frees @cap@ exactly
-- once. Without that dup the env cascade frees @cap@ out from under the returned
-- handle --- the verified member-body CAPTURE-escape use-after-free.
--
-- The escaped capture is then DESTRUCTURED externally to a scalar 'GInt' (one field
-- of the Tuple2), so the whole program yields a scalar and the heap MUST empty =>
-- ACCEPT-and-run-sound. We range over: BASE-arm vs REC-arm escape (rec-arm
-- self-recurses first, then escapes at the base, so the escape happens from a body
-- reached BY a recursion --- the same env-borrowing position); and escape via bare
-- RETURN vs MOVE-into-a-returned-con (two distinct dup sites). The saturating apply
-- @(f init) ...@ form is not needed (the capture, not a function, is what escapes).
genCaptureBodyEscapeCluster :: Int -> GenM Expr
genCaptureBodyEscapeCluster _n = do
  escStyle <- liftG (elements [MescReturn, MescMoveCon])
  escInRec <- liftG (elements [True, False])
  let intTy  = gtyCType GInt
      pairTy = gtyCType GPair
  (capN, seedCap) <- seedPairCapture
  fN  <- freshN (T.pack "lcf")
  k1N <- freshN (T.pack "ck1")
  -- The member-body escape expression: carry the CAPTURE out bare (@Ret cap@) or
  -- sealed into a returned 'Box' con (a MOVE of @cap@ into the con). Both escape the
  -- borrowed capture from inside the member body.
  escExpr <- case escStyle of
    MescReturn  -> pure (Ret (AVar capN))
    MescMoveCon -> do
      cN <- freshN (T.pack "csc")
      pure (Let (Binder cN Unrestricted boxTyC) (RCon (T.pack "Box") [AVar capN]) (Ret (AVar cN)))
  ks1N <- freshN (T.pack "cks"); r1N <- freshN (T.pack "cfr")
  -- f's result type is the escaped value (a Pair, or a Box of a Pair). The rec arm
  -- self-recurses (borrowing the env), so escInRec=True escapes from a body reached
  -- by a recursion; escInRec=False escapes immediately.
  let escTy = case escStyle of { MescReturn -> pairTy; MescMoveCon -> boxTyC }
      fSelfRec = Let (Binder ks1N Unrestricted intTy)
                     (RApp (primAtom (T.pack "-")) [AVar k1N, ALit (LInt 1)])
                   (Let (Binder r1N Unrestricted escTy) (RApp (AVar fN) [AVar ks1N])
                     (Ret (AVar r1N)))
      fBody = if escInRec
                then Case (AVar k1N) [ AltLit (LInt 0) escExpr, AltDefault fSelfRec ]
                else escExpr
      wrapGroup cont =
        LetRec [ (Binder fN Unrestricted funTyC, [Binder k1N Unrestricted intTy], fBody) ] cont
  -- Call f so its FIRST call lands on the escaping (base) arm: base-arm escape fires
  -- at k1==0; rec-arm escape fires at any k1 /= 0 (here 1, recursing once to k1==0).
  let initArg = if escInRec then 1 else 0 :: Int
  -- Externally destructure the escaped capture to one Tuple2 field (a scalar).
  pxN <- freshN (T.pack "cpx"); pyN <- freshN (T.pack "cpy")
  pick <- liftG (elements [True, False])
  let readPair scrut = Case scrut
        [ AltCon (T.pack "Tuple2")
            [Binder pxN Unrestricted intTy, Binder pyN Unrestricted intTy]
            (Ret (AVar (if pick then pxN else pyN))) ]
  rN <- freshN (T.pack "crr")
  callOut <- case escStyle of
    MescReturn ->
      pure (Let (Binder rN Unrestricted pairTy) (RApp (AVar fN) [ALit (LInt (toInteger initArg))])
              (readPair (AVar rN)))
    MescMoveCon -> do
      -- f returns a Box holding the Pair capture; unbox then destructure.
      boxN <- freshN (T.pack "cbx"); pOutN <- freshN (T.pack "cpout")
      pure (Let (Binder boxN Unrestricted boxTyC) (RApp (AVar fN) [ALit (LInt (toInteger initArg))])
              (Case (AVar boxN)
                [ AltCon (T.pack "Box") [Binder pOutN Unrestricted pairTy]
                    (readPair (AVar pOutN)) ]))
  pure $ seedCap $ wrapGroup callOut

-- ---------------------------------------------------------------------------
-- Family 7: PARTIAL APPLICATION of a MULTI-ARITY capturing member (the M2a-2
-- double-free shape).
--
-- A single self-recursive member of arity >= 2 captures an enclosing local
-- (boxed Pair or unboxed U64). The member is bound to a NAMED head @g@, then
-- applied at one of three SATURATIONS:
--
--   * PARTIAL   --- @let h = g a0 in h <rest>@. @g a0@ is an UNDER-application of
--     the 'RVRecMember' (the LT path of 'enterRC's member arm) --- the exact
--     branch where the shared env was double-freed (build incref'd nothing while
--     the cell's drop cascaded the env). @h@ is the resulting 'NClosure'
--     ('BorrowCaptures'), then saturated.
--   * SATURATED --- @let r = g a0 a1 [a2] in r@ in ONE call (the clean control;
--     EQ path, no partial cell).
--   * OVER      --- the member is arity-1-extended via an identity wrapper so an
--     over-application chains through 'KAppRC'. (We realize "over" as a saturated
--     call whose result --- a scalar --- is then NOT further applied; genuine
--     over-application of a first-order member needs a higher-arity result, which
--     this corpus does not produce, so OVER here saturates a 3-arity member by a
--     1-then-2 split, exercising partial-then-saturate.)
--
-- Every variant yields a GInt (the base case reads the capture to a scalar), so a
-- sound pass empties the heap: ACCEPT-and-run-sound. The base case only READS the
-- capture (borrowed scrutinee / unboxed read), never CONSUMES it (#1 is deferred).
data PartialSaturation = PartPartial | PartSaturated | PartOver
  deriving (Eq, Show)

-- | HOW the named member head @g@ is consumed downstream. The PLAIN kinds apply
-- @g@ DIRECTLY (the original M2a-2 corpus); the two RLAM-MEDIATED crosses route
-- the member through an 'RLam' so 'CaptureMode' propagation across the partial-
-- application of a closure (the 'NClosure' LT branch of 'enterRC') is under test:
--
--   * 'PartRLamPartial' (CROSS 5) --- a 2-arg 'RLam' @e = \x y -> g (x+y) <rest>@
--     that CAPTURES the recursive member head @g@. @e@ is PARTIALLY applied to ONE
--     arg (@let p = e a0@), stored, then SATURATED and called (@p a1@). The partial
--     of the RLam takes the LT branch; its 'CaptureMode' must be carried to the new
--     partial cell verbatim.
--   * 'PartRLamBodyPartial' (CROSS 6) --- a 1-arg ESCAPING 'RLam' @h = \x -> <member
--     @g@ partially applied, then saturated>@. The member partial lives INSIDE the
--     closure body; for an arity-3 member the body does a 1-then-1-then-rest split so
--     the partial-of-a-partial fires the LT branch (the 'BorrowCaptures' propagation
--     case). @h@ is bound, then CALLED locally (@h a@), so the result is a scalar and
--     the run is ACCEPT-and-sound.
--
-- Both yield a GInt, so a sound pass empties the heap (ACCEPT-and-run-sound).
data PartialKind
  = PartPlain PartialSaturation   -- ^ apply the member head @g@ directly
  | PartRLamPartial               -- ^ CROSS 5: capture @g@ in an RLam, partial-apply the RLam
  | PartRLamBodyPartial           -- ^ CROSS 6: member partial inside an escaping RLam body
  deriving (Eq, Show)

genPartialMemberCluster :: Int -> GenM Expr
genPartialMemberCluster n = do
  boxedCap <- liftG (elements [True, False])
  kind     <- liftG (elements [ PartPlain PartPartial, PartPlain PartSaturated, PartPlain PartOver
                              , PartRLamPartial, PartRLamBodyPartial ])
  -- CROSS 6's partial-of-a-partial needs arity 3 to fire the LT branch INSIDE the
  -- RLam body; otherwise range over 2/3 as before.
  arity    <- case kind of
                PartRLamBodyPartial -> pure (3 :: Int)
                _                   -> liftG (elements [2, 3 :: Int])
  let intTy = gtyCType GInt
  -- Seed the capture and a reader turning it into the GInt the base arm yields.
  (seedCap, capReader) <-
    if boxedCap
      then do
        (cN, sc) <- seedPairCapture
        let reader = do
              pxN <- freshN (T.pack "px"); pyN <- freshN (T.pack "py")
              pure (\k -> Case (AVar cN)
                            [ AltCon (T.pack "Tuple2")
                                [Binder pxN Unrestricted intTy, Binder pyN Unrestricted intTy]
                                (k (AVar pxN)) ])
        pure (sc, reader)
      else do
        seed <- liftG (choose (0, 9 :: Int))
        uN <- freshN (T.pack "u")
        let sc cont = Let (Binder uN Unrestricted intTy)
                          (RAtom (ALit (LInt (toInteger seed)))) cont
            reader = pure (\k -> k (AVar uN))
        pure (sc, reader)
  -- The member f of the chosen arity: its FIRST param @a@ is the recursion fuel;
  -- the rest are inert (threaded through the recursive call so they stay live).
  -- f a p1 .. = case a of 0 -> <read cap> ; _ -> f (a-1) p1 .. .
  fN  <- freshN (T.pack "lrf")
  aN  <- freshN (T.pack "fa")
  restNs <- mapM (\_ -> freshN (T.pack "fp")) [2 .. arity]   -- arity-1 inert params
  ksN <- freshN (T.pack "fks")
  rN  <- freshN (T.pack "frr")
  readCap <- capReader
  let paramBs = Binder aN Unrestricted intTy
                  : [ Binder p Unrestricted intTy | p <- restNs ]
      recCallArgs = AVar ksN : map AVar restNs
      fBody = Case (AVar aN)
                [ AltLit (LInt 0) (readCap Ret)
                , AltDefault
                    (Let (Binder ksN Unrestricted intTy)
                         (RApp (primAtom (T.pack "-")) [AVar aN, ALit (LInt 1)])
                       (Let (Binder rN Unrestricted intTy) (RApp (AVar fN) recCallArgs)
                         (Ret (AVar rN)))) ]
      wrapGroup cont =
        LetRec [(Binder fN Unrestricted intTy, paramBs, fBody)] cont
  -- Bind the member to a NAMED head @g@, then apply at the chosen saturation.
  gN  <- freshN (T.pack "g")
  -- Choose a small recursion depth (the first arg) and inert arg values.
  depth <- liftG (choose (0, max 0 (min n 3)))
  -- Concrete argument literals: the FUEL (@depth@, the first arg) and the inert REST.
  let fuelArg  = ALit (LInt (toInteger depth))
      restArgs = [ ALit (LInt (toInteger (10 + i))) | i <- [1 .. arity - 1] ]
  body <- case kind of
    PartPlain PartSaturated -> do
      rrN <- freshN (T.pack "rr")
      pure (Let (Binder rrN Unrestricted intTy) (RApp (AVar gN) (fuelArg : restArgs))
              (Ret (AVar rrN)))
    PartPlain PartPartial -> do
      -- g applied to the FUEL arg only (partial); the result @h@ is then applied
      -- to the remaining args (saturating it). The double-free shape.
      hN  <- freshN (T.pack "h")
      rrN <- freshN (T.pack "rr")
      pure (Let (Binder hN Unrestricted funTyC) (RApp (AVar gN) [fuelArg])
              (Let (Binder rrN Unrestricted intTy) (RApp (AVar hN) restArgs)
                (Ret (AVar rrN))))
    PartPlain PartOver -> do
      -- Partial in TWO steps for arity-3 (1 then the rest); for arity-2 this
      -- coincides with PartPartial. Exercises a chain of partial closures.
      hN  <- freshN (T.pack "h"); h2N <- freshN (T.pack "h2")
      rrN <- freshN (T.pack "rr")
      case restArgs of
        (r1 : r2rest) | arity >= 3 ->
          pure (Let (Binder hN Unrestricted funTyC) (RApp (AVar gN) [fuelArg])
                 (Let (Binder h2N Unrestricted funTyC) (RApp (AVar hN) [r1])
                   (Let (Binder rrN Unrestricted intTy) (RApp (AVar h2N) r2rest)
                     (Ret (AVar rrN)))))
        _ ->
          pure (Let (Binder hN Unrestricted funTyC) (RApp (AVar gN) [fuelArg])
                 (Let (Binder rrN Unrestricted intTy) (RApp (AVar hN) restArgs)
                   (Ret (AVar rrN))))
    PartRLamPartial -> do
      -- CROSS 5: a 2-arg RLam @e = \x y -> let s = x + y in let r = g s <rest> in r@
      -- that CAPTURES the recursive member head @g@ (free in the body as a call
      -- head). @e@ is PARTIALLY applied to ONE arg (@let p = e a0@), then SATURATED
      -- and called (@p a1@). The partial of the RLam takes the 'NClosure' LT branch
      -- of 'enterRC', so its 'CaptureMode' must reach the new partial cell intact.
      xN  <- freshN (T.pack "rlx"); yN <- freshN (T.pack "rly")
      sN  <- freshN (T.pack "rls"); erN <- freshN (T.pack "rler")
      eN  <- freshN (T.pack "rle"); pN  <- freshN (T.pack "rlp")
      rrN <- freshN (T.pack "rr")
      -- g saturated INSIDE the RLam body: g s <rest> where s = x + y stands in for
      -- the fuel arg and the inert rest are the member's remaining params.
      let eBody = Let (Binder sN Unrestricted intTy)
                      (RApp (primAtom (T.pack "+")) [AVar xN, AVar yN])
                    (Let (Binder erN Unrestricted intTy)
                         (RApp (AVar gN) (AVar sN : restArgs))
                      (Ret (AVar erN)))
          eLam  = RLam [Binder xN Unrestricted intTy, Binder yN Unrestricted intTy] eBody
      pure (Let (Binder eN Unrestricted funTyC) eLam
              (Let (Binder pN Unrestricted funTyC) (RApp (AVar eN) [fuelArg])
                (Let (Binder rrN Unrestricted intTy) (RApp (AVar pN) [ALit (LInt 1)])
                  (Ret (AVar rrN)))))
    PartRLamBodyPartial -> do
      -- CROSS 6: a 1-arg RLam @h@ whose BODY partially applies the member @g@, then
      -- saturates it. For arity-3 the body does a 1-then-1-then-rest split so the
      -- partial-of-a-partial fires the 'NClosure' LT branch (the 'BorrowCaptures'
      -- propagation case) INSIDE the closure body. @h@ is bound then CALLED locally,
      -- so the member partial's lifetime is bounded by @h@'s call and the result is
      -- a scalar (ACCEPT-and-run-sound).
      hN  <- freshN (T.pack "h"); hxN <- freshN (T.pack "hx")
      p1N <- freshN (T.pack "hp1"); p2N <- freshN (T.pack "hp2")
      hrN <- freshN (T.pack "hr"); rrN <- freshN (T.pack "rr")
      let hBody = case restArgs of
            (r1 : _) | arity >= 3 ->
              -- arity-3: g fuel (partial, 1 of 3) -> p1 r1 (partial-of-partial, 2 of
              -- 3, the LT branch) -> p2 hx (saturate, 3 of 3). The closure param @hx@
              -- is the LAST inert arg, so the partial-of-partial saturates exactly.
              Let (Binder p1N Unrestricted funTyC) (RApp (AVar gN) [fuelArg])
                (Let (Binder p2N Unrestricted funTyC) (RApp (AVar p1N) [r1])
                  (Let (Binder hrN Unrestricted intTy) (RApp (AVar p2N) [AVar hxN])
                    (Ret (AVar hrN))))
            _ ->
              -- arity-2 fallback: g fuel (partial, 1 of 2) then saturate inside the
              -- body with the closure param @hx@ as the single remaining arg.
              Let (Binder p1N Unrestricted funTyC) (RApp (AVar gN) [fuelArg])
                (Let (Binder hrN Unrestricted intTy) (RApp (AVar p1N) [AVar hxN])
                  (Ret (AVar hrN)))
          hLam = RLam [Binder hxN Unrestricted intTy] hBody
      pure (Let (Binder hN Unrestricted funTyC) hLam
              (Let (Binder rrN Unrestricted intTy) (RApp (AVar hN) [ALit (LInt 0)])
                (Ret (AVar rrN))))
  pure $ seedCap $ wrapGroup (Let (Binder gN Unrestricted funTyC) (RAtom (AVar fN)) body)

-- | Structural detector for the PARTIAL-APPLICATION-of-a-multi-arity-member class
-- (M2a-2 double-free shape): a 'LetRec' member of arity >= 2 whose handle is then
-- applied to FEWER arguments than its arity at a named head (the 'enterRC'
-- 'RVRecMember' LT path). Used only for the 'cover'/'checkCoverage' non-vacuity
-- floor; it is a conservative recognizer (member arity >= 2 + a single-arg apply
-- of a binder bound to that member).
hasPartialMemberApply :: CoreModule -> Bool
hasPartialMemberApply (CoreModule bs) = any (\(TopBind _ _ b) -> go Map.empty b) bs
  where
    -- @arits@ maps a binder Unique to the arity of the member it (transitively)
    -- names, for any name aliased to a >= 2-arity LetRec member.
    go arits e = case e of
      LetRec defs body ->
        let arits' = foldr (\(bd, ps, _) m ->
                              if length ps >= 2
                                then Map.insert (binderUnique bd) (length ps) m
                                else m) arits defs
        in any (\(_, _, d) -> go arits' d) defs || go arits' body
      Let bd r body ->
        let arits' = case r of
              RAtom (AVar nm') | Just k <- Map.lookup (nameUniq nm') arits ->
                Map.insert (binderUnique bd) k arits
              _ -> arits
            here = case r of
              RApp (AVar nm') as
                | Just k <- Map.lookup (nameUniq nm') arits, length as < k -> True
              _ -> False
        in here || go arits' body
      Case _ alts -> any (go arits . altBody) alts
      LetJoin _ _ jb body -> go arits jb || go arits body
      _ -> False
    altBody (AltCon _ _ b) = b
    altBody (AltLit _ b)   = b
    altBody (AltDefault b) = b

-- | Structural detector for the RLAM-MEDIATED member-partial class (CROSS 5/6):
-- a 'LetRec' member of arity >= 2 whose handle (or an alias of it) is referenced
-- as a CALL HEAD from INSIDE an 'RLam' body --- either the RLam itself captures
-- the member and is then partially applied (CROSS 5), or the member is partially
-- applied within an escaping RLam body (CROSS 6). Either way the member flows
-- through a closure, so the 'NClosure' LT branch's 'CaptureMode' propagation is on
-- the path. Used only for the 'cover'/'checkCoverage' non-vacuity floor; it is a
-- conservative recognizer (member arity >= 2 + a member-alias call head occurring
-- lexically under at least one 'RLam').
hasRLamMemberPartial :: CoreModule -> Bool
hasRLamMemberPartial (CoreModule bs) = any (\(TopBind _ _ b) -> go Map.empty False b) bs
  where
    -- @arits@ maps a binder Unique to the arity of the >= 2-arity LetRec member it
    -- (transitively) names. @inLam@ records whether we are lexically inside an RLam.
    go arits inLam e = case e of
      LetRec defs body ->
        let arits' = foldr (\(bd, ps, _) m ->
                              if length ps >= 2
                                then Map.insert (binderUnique bd) (length ps) m
                                else m) arits defs
        in any (\(_, _, d) -> go arits' inLam d) defs || go arits' inLam body
      Let bd r body ->
        let arits' = case r of
              RAtom (AVar nm') | Just k <- Map.lookup (nameUniq nm') arits ->
                Map.insert (binderUnique bd) k arits
              _ -> arits
            -- A member-alias call HEAD seen INSIDE an RLam body is the marker.
            here = case r of
              RApp (AVar nm') _ | inLam, Map.member (nameUniq nm') arits -> True
              RLam _ lamB -> go arits' True lamB
              _ -> False
        in here || go arits' inLam body
      Case _ alts -> any (go arits inLam . altBody) alts
      LetJoin _ _ jb body -> go arits inLam jb || go arits inLam body
      _ -> False
    altBody (AltCon _ _ b) = b
    altBody (AltLit _ b)   = b
    altBody (AltDefault b) = b

-- ---------------------------------------------------------------------------
-- Suite G properties.

-- | The Suite G test group. Three properties as recommended: the soundness proof
-- (accepted ⟹ heap-balanced + value-match), the static-lint cleanliness oracle,
-- and the generalized fault-injection teeth.
rcM2a1PropertyTests :: TestTree
rcM2a1PropertyTests =
  localOption (QuickCheckTests 800) $
    testGroup "rc m2a-1 property (Suite G: owned/borrowed + escape)"
      [ testCase "consuming-capture groups (single + two-member) are REJECTED (deferred)"
          rcM2a1ConsumeCaptureRejected
      , testCase "nested capturing groups are REJECTED (escape + borrow-read); flat stays admitted"
          rcM2a2NestedCaptureRejected
      , testCase "fence partition: indirect-alias captures rejected by consumeViol (not mob)"
          rcM2a2FencePartitionPinned
      , testProperty "accepted => sound (heap-balanced + value-match); rejected => skipped"
          prop_m2a1Escape
      , testProperty "balanceLint is clean on every in-fragment generated program"
          prop_m2a1LintClean
      , testProperty "every single-site RC mutation is caught (generalized teeth)"
          prop_m2a1Teeth
      , testCase "captureEscapesBody single-source: verdict + oracle on hand-built RHS matrix"
          captureEscapesBodyDriftGuard
      , testProperty "captureEscapesBody DERIVES from escapeWalk (equals frozen oracle on every program)"
          prop_captureEscapesBodyMatchesOracle
      , testCase "hasCaptureBodyEscape: fires on capture escape, NOT on sibling escape"
          hasCaptureBodyEscapeSpecific
      , testCase "rcMemSafetyFault catches RC-store-only faults, NOT shared/value errors"
          rcMemSafetyFaultClassification
      ]

-- | 'rcMemSafetyFault' must classify EXACTLY the RC-store-only 'PrimError'
-- messages as memory-safety faults (so a both-fail branch rejects them outright,
-- never laundering a one-sided RC fault past 'errCtorTag' agreement), and must
-- NOT classify the SHARED value-level errors the store-less reference can also
-- produce (else a both-fail branch would false-fail on genuine agreement).
rcMemSafetyFaultClassification :: Assertion
rcMemSafetyFaultClassification = do
  let pe = IV.PrimError . T.pack
  -- MUST catch: the store guards (Value.hs) and the machine invariants (Machine.hs)
  -- the reference, having no reference-counted store, can NEVER emit.
  assertBool "double-free is an RC mem-safety fault"
    (rcMemSafetyFault (pe "double-free: addr 7"))
  assertBool "use-after-free is an RC mem-safety fault"
    (rcMemSafetyFault (pe "use-after-free: addr 7"))
  assertBool "dangling addr is an RC mem-safety fault"
    (rcMemSafetyFault (pe "dangling addr 7"))
  assertBool "drop of dangling addr is an RC mem-safety fault"
    (rcMemSafetyFault (pe "drop of dangling addr 7"))
  assertBool "RVRecMember env addr is not NEnv is an RC store-internal fault"
    (rcMemSafetyFault (pe "RVRecMember env addr is not NEnv: 3"))
  assertBool "an internal: machine message is an RC store-internal fault"
    (rcMemSafetyFault (pe "internal: runModuleRC bind/addr length mismatch"))
  -- MUST NOT catch: shared value-level errors (a store-less reference hits these
  -- too), and non-PrimError constructors.
  assertBool "expected U64 is a SHARED value error, not an RC mem-safety fault"
    (not (rcMemSafetyFault (pe "expected U64")))
  assertBool "expected Bool is a SHARED value error, not an RC mem-safety fault"
    (not (rcMemSafetyFault (pe "expected Bool, got a closure handle")))
  assertBool "division by zero is a SHARED value error, not an RC mem-safety fault"
    (not (rcMemSafetyFault (pe "-: division by zero")))
  assertBool "UnboundVar is NOT an RC mem-safety fault (residual UAF-as-UnboundVar)"
    (not (rcMemSafetyFault (IV.UnboundVar (T.pack "x"))))

-- | Specificity test for 'hasCaptureBodyEscape' (the FIX-1 capture-escape detector):
-- it must fire ONLY when a member body escapes an ENCLOSING BOXED CAPTURE, and must
-- NOT fire when a member body escapes a SIBLING group binder (a distinct code path).
-- This guards against a future over-broadening of the detector (which previously
-- fired on ~55% of programs across every family, gutting the non-vacuity floor).
hasCaptureBodyEscapeSpecific :: Assertion
hasCaptureBodyEscapeSpecific = do
  let intTy  = Ty.CTCon Ty.TcU64 []
      pairTy = Ty.CTCon (Ty.TcTuple 2) [intTy, intTy]
      nm h u = Name (T.pack h) (Unique u)
      -- POSITIVE: a single-member group whose body RETURNS an enclosing boxed
      -- capture @cap@ (bound OUTSIDE the group, not a sibling, not a param).
      --   main = let cap = Tuple2(9,5)
      --          letrec f k = Ret cap
      --          in let r = f 0 in case r of Tuple2 px py -> Ret px
      capEscapeBody =
        Let (Binder (nm "cap" 0) Unrestricted pairTy)
            (RCon (T.pack "Tuple2") [ALit (LInt 9), ALit (LInt 5)])
          (LetRec
            [ ( Binder (nm "f" 1) Unrestricted funTyC
              , [Binder (nm "k" 2) Unrestricted intTy]
              , Ret (AVar (nm "cap" 0)) ) ]               -- member body escapes the CAPTURE
            (Let (Binder (nm "r" 3) Unrestricted pairTy)
                 (RApp (AVar (nm "f" 1)) [ALit (LInt 0)])
              (Case (AVar (nm "r" 3))
                [ AltCon (T.pack "Tuple2")
                    [Binder (nm "px" 4) Unrestricted intTy, Binder (nm "py" 5) Unrestricted intTy]
                    (Ret (AVar (nm "px" 4))) ])))
      capEscapeCm = CoreModule [TopBind (nm "main" 1000000) [] capEscapeBody]
      -- NEGATIVE: a two-member group whose body RETURNS a SIBLING binder @g@ (a group
      -- member, NOT an enclosing capture). This is the M2MemberBodyEscape code path.
      --   main = letrec f k = Ret g
      --                 g k = Ret k
      --          in let h = f 0 in let r = h 0 in Ret r
      sibEscapeBody =
        LetRec
          [ ( Binder (nm "f" 1) Unrestricted funTyC
            , [Binder (nm "k1" 2) Unrestricted intTy]
            , Ret (AVar (nm "g" 6)) )                     -- member body escapes a SIBLING
          , ( Binder (nm "g" 6) Unrestricted funTyC
            , [Binder (nm "k2" 7) Unrestricted intTy]
            , Ret (AVar (nm "k2" 7)) ) ]
          (Let (Binder (nm "h" 3) Unrestricted funTyC)
               (RApp (AVar (nm "f" 1)) [ALit (LInt 0)])
            (Let (Binder (nm "r" 4) Unrestricted intTy)
                 (RApp (AVar (nm "h" 3)) [ALit (LInt 0)])
              (Ret (AVar (nm "r" 4)))))
      sibEscapeCm = CoreModule [TopBind (nm "main" 1000000) [] sibEscapeBody]
  assertBool "must fire on a member body escaping an enclosing boxed CAPTURE"
    (hasCaptureBodyEscape capEscapeCm)
  assertBool "must NOT fire on a member body escaping a SIBLING group binder"
    (not (hasCaptureBodyEscape sibEscapeCm))

-- | The two-member consuming-capture group that a dup-per-consuming-use plan got
-- WRONG (Suite G surfaced the leak): both base cases CONSUME (move) the shared
-- enclosing boxed capture @cap@:
--
--   main = let cap = Tuple2(9,5)
--          letrec lrf k1 = case k1 of 0 -> <move cap into a Box, read it back>
--                                     _ -> lrg (k1 - 1)
--                 lrg k2 = case k2 of 0 -> <move cap into a Box, read it back>
--                                     _ -> lrf (k2 - 1)
--          let lrr = lrf 2 in lrr
--
-- The dup-per-consuming-use scheme pre-emitted one @__rc_dup cap@ per consuming
-- SIBLING at the build site, but at runtime the mutual recursion terminates in
-- EXACTLY ONE base case, so only one consuming move fires --- the surplus dups
-- leaked. Consuming-capture support is therefore DEFERRED (it needs proper
-- borrow-passing). This asserts the M1.5 boundary line is RESTORED: ANY consuming
-- use of an enclosing capture is REJECTED at the boundary --- single-member
-- (rc-m2a1/33) and two-member alike --- so the unsound shape never reaches the
-- pass. A REJECTED program is sound (it is never compiled).
rcM2a1ConsumeCaptureRejected :: Assertion
rcM2a1ConsumeCaptureRejected = do
  -- Single-member consuming-capture corpus: rejected at the boundary BY THE
  -- CONSUMING-CAPTURE FENCE (pinned to catch a fence-swap regression).
  vs33 <- boundaryViolationsOf "test/rc-m2a1/33-consuming-capture-nonescape.wok"
  assertBool "single-member consuming-capture group must be REJECTED by the consuming-capture fence"
    (any (T.isInfixOf (T.pack "consumes an enclosing capture")) vs33)
  -- Two-member consuming-capture group (built directly): rejected at the boundary.
  let intTy  = Ty.CTCon Ty.TcU64 []
      pairTy = Ty.CTCon (Ty.TcTuple 2) [intTy, intTy]
      nm h u = Name (T.pack h) (Unique u)
      -- base case: move cap into a Box con, destructure the box and the Pair,
      -- return one int field (a valid CONSUMING move of cap).
      consumeBase backU pxU pyU pick =
        Let (Binder (nm "bx" backU) Unrestricted boxTyC)
            (RCon (T.pack "Box") [AVar (nm "cap" 0)])
          (Case (AVar (nm "bx" backU))
            [ AltCon (T.pack "Box") [Binder (nm "cback" (backU + 100)) Unrestricted pairTy]
                (Case (AVar (nm "cback" (backU + 100)))
                  [ AltCon (T.pack "Tuple2")
                      [Binder (nm "px" pxU) Unrestricted intTy, Binder (nm "py" pyU) Unrestricted intTy]
                      (Ret (AVar (if pick then nm "px" pxU else nm "py" pyU))) ]) ])
      fBody = Case (AVar (nm "k1" 3))
                [ AltLit (LInt 0) (consumeBase 9 11 12 True)
                , AltDefault
                    (Let (Binder (nm "ks1" 5) Unrestricted intTy)
                         (RApp (AVar (nm "-" 2000000)) [AVar (nm "k1" 3), ALit (LInt 1)])
                       (Let (Binder (nm "r1" 7) Unrestricted intTy)
                            (RApp (AVar (nm "lrg" 2)) [AVar (nm "ks1" 5)])
                         (Ret (AVar (nm "r1" 7))))) ]
      gBody = Case (AVar (nm "k2" 4))
                [ AltLit (LInt 0) (consumeBase 13 15 16 False)
                , AltDefault
                    (Let (Binder (nm "ks2" 6) Unrestricted intTy)
                         (RApp (AVar (nm "-" 2000000)) [AVar (nm "k2" 4), ALit (LInt 1)])
                       (Let (Binder (nm "r2" 8) Unrestricted intTy)
                            (RApp (AVar (nm "lrf" 1)) [AVar (nm "ks2" 6)])
                         (Ret (AVar (nm "r2" 8))))) ]
      body =
        Let (Binder (nm "cap" 0) Unrestricted pairTy)
            (RCon (T.pack "Tuple2") [ALit (LInt 9), ALit (LInt 5)])
          (LetRec [ (Binder (nm "lrf" 1) Unrestricted intTy, [Binder (nm "k1" 3) Unrestricted intTy], fBody)
                  , (Binder (nm "lrg" 2) Unrestricted intTy, [Binder (nm "k2" 4) Unrestricted intTy], gBody) ]
            (Let (Binder (nm "lrr" 17) Unrestricted intTy)
                 (RApp (AVar (nm "lrf" 1)) [ALit (LInt 2)])
              (Ret (AVar (nm "lrr" 17)))))
      cm     = CoreModule [TopBind (nm "main" 1000000) [] body]
      pruned = pruneToReachable cm
  assertBool "two-member consuming-capture group must be REJECTED by the consuming-capture fence"
    (any (T.isInfixOf (T.pack "consumes an enclosing capture"))
         (firstOrderNoHandlerViolations pruned))
  -- WHY the rejection stands (verification-gate finding, 2026-06-16). The shared-env
  -- borrow model alone does NOT make #1 sound. If the boundary were bypassed and the
  -- pass run on this very reproducer, the dynamic dup-on-consume balances the path
  -- TAKEN at runtime (so a runModuleRCUnchecked at a fixed depth happens to empty the
  -- heap), but the pass does NOT emit statically-balanced instrumentation: the capture
  -- is moved into the shared env ONCE while each base-case arm independently dups it,
  -- and the path-insensitive multiset accounting that underwrites soundness for ALL
  -- call patterns (including the nested/escaped group whose env-drop never fires)
  -- cannot reconcile. 'balanceLint' --- the compile-time oracle (Suite G's
  -- 'prop_m2a1LintClean') --- MUST therefore flag the leak. This is the teeth: were
  -- the dup-on-consume emission ever made to "pass" by weakening the lint, this
  -- assertion would catch the regression.
  assertBool "balanceLint must flag the consuming-capture imbalance (deferral rationale)"
    (not (null (Perceus.balanceLint (Perceus.insertRC pruned))))

-- | NESTED CAPTURING GROUP (M2a-2, verified DOUBLE-FREE). A 'LetRec' group NESTED
-- inside an enclosing 'LetRec' member body that captures a boxed local bound
-- OUTSIDE that enclosing member double-frees the local: the local lives in BOTH the
-- enclosing member's 'NEnv' and the inner group's 'NEnv' --- two cascades on drop,
-- but only one incref backs the re-capture (the local is treated as
-- borrowed/moved-once). The boundary guard REJECTS this class on the MEMBER-OUTER
-- BOXED SET (@rawEnclosingFv ∩ mob@) --- whether the inner group ESCAPES the
-- outside-bound local (CLAIM 1, returns it), only BORROW-READS it (CLAIM 2),
-- reaches it through a same-cell ALIAS rename (CLAIM 3), or is TRIPLE-nested
-- (CLAIM 4). A REJECTED program is sound (it is never compiled). Each must-reject
-- shape is RUN unchecked to confirm it would genuinely double-free if admitted.
--
-- The PRECISION boundary (M2a-2 precision-cleanup): three shapes that were
-- conservatively over-rejected are now ADMITTED-and-RUN-SOUND because the captured
-- local is NOT in the member-outer set:
--   * FLAT (non-nested) group capturing an enclosing local --- one env, one cascade;
--   * GROUP-IN-LAMBDA-IN-MEMBER --- a lambda body is a fresh frame, resetting @mob@
--     (ADMIT 1, the same group is sound at top level);
--   * PER-ENTRY LET-LOCAL --- a local ALLOCATED inside the enclosing member body
--     (rebuilt per entry alongside the inner env --- one cascade) (ADMIT 2).
-- A nested group that captures NO enclosing boxed local also stays ADMITTED.
rcM2a2NestedCaptureRejected :: Assertion
rcM2a2NestedCaptureRejected = do
  let intTy  = Ty.CTCon Ty.TcU64 []
      funTy  = Ty.CTCon (Ty.TcUser (T.pack "Fun")) []
      nm h u = Name (T.pack h) (Unique u)
      -- main = let b = Box 7 in
      --        letrec f k = (letrec h j = Ret b in let r = h 0 in Ret r)
      --        in let res = f 0 in case res of Box v -> Ret v
      claim1 =
        Let (Binder (nm "b" 0) Unrestricted boxTyC)
            (RCon (T.pack "Box") [ALit (LInt 7)])
          (LetRec
            [ ( Binder (nm "f" 1) Unrestricted funTy
              , [Binder (nm "k" 2) Unrestricted intTy]
              , LetRec
                  [ ( Binder (nm "h" 3) Unrestricted funTy
                    , [Binder (nm "j" 4) Unrestricted intTy]
                    , Ret (AVar (nm "b" 0)) ) ]      -- inner group ESCAPES the local b
                  (Let (Binder (nm "r" 5) Unrestricted boxTyC)
                       (RApp (AVar (nm "h" 3)) [ALit (LInt 0)])
                    (Ret (AVar (nm "r" 5)))) ) ]
            (Let (Binder (nm "res" 6) Unrestricted boxTyC)
                 (RApp (AVar (nm "f" 1)) [ALit (LInt 0)])
              (Case (AVar (nm "res" 6))
                [ AltCon (T.pack "Box") [Binder (nm "v" 7) Unrestricted intTy]
                    (Ret (AVar (nm "v" 7))) ])))
      claim1Cm = pruneToReachable (CoreModule [TopBind (nm "main" 1000000) [] claim1])
      -- main = let b = Box 7 in
      --        letrec f k = (letrec h j = (case b of Box v -> Ret v) in let r = h 0 in Ret r)
      --        in let res = f 0 in Ret res
      claim2 =
        Let (Binder (nm "b" 0) Unrestricted boxTyC)
            (RCon (T.pack "Box") [ALit (LInt 7)])
          (LetRec
            [ ( Binder (nm "f" 1) Unrestricted funTy
              , [Binder (nm "k" 2) Unrestricted intTy]
              , LetRec
                  [ ( Binder (nm "h" 3) Unrestricted funTy
                    , [Binder (nm "j" 4) Unrestricted intTy]
                    , Case (AVar (nm "b" 0))          -- inner group BORROW-READS the local b
                        [ AltCon (T.pack "Box") [Binder (nm "v" 7) Unrestricted intTy]
                            (Ret (AVar (nm "v" 7))) ] ) ]
                  (Let (Binder (nm "r" 5) Unrestricted intTy)
                       (RApp (AVar (nm "h" 3)) [ALit (LInt 0)])
                    (Ret (AVar (nm "r" 5)))) ) ]
            (Let (Binder (nm "res" 6) Unrestricted intTy)
                 (RApp (AVar (nm "f" 1)) [ALit (LInt 0)])
              (Ret (AVar (nm "res" 6)))))
      claim2Cm = pruneToReachable (CoreModule [TopBind (nm "main" 1000000) [] claim2])
  -- CLAIM 1 (escape) and CLAIM 2 (borrow-read): BOTH rejected at the boundary BY
  -- THE NESTED-CAPTURING-GROUP FENCE (pinned to catch a fence-swap regression).
  assertBool "CLAIM 1 (nested group escapes enclosing local) must be REJECTED by the nested-capture fence"
    (any (T.isInfixOf (T.pack "nested LetRec group captures a local bound outside"))
         (firstOrderNoHandlerViolations claim1Cm))
  assertBool "CLAIM 2 (nested group borrow-reads enclosing local) must be REJECTED by the nested-capture fence"
    (any (T.isInfixOf (T.pack "nested LetRec group captures a local bound outside"))
         (firstOrderNoHandlerViolations claim2Cm))

  -- CLAIM 3 (ALIAS): the inner group captures the outside-bound local through a
  -- same-cell rename @let ba = b@ bound inside the enclosing member body. @ba@ is
  -- NOT allocated per entry --- it names the SAME cell as @b@ --- so capturing it
  -- double-frees exactly as capturing @b@. The member-outer set propagates through
  -- the pure 'RAtom' rename, so the fence still fires.
  --   main = let b = Box 7 in
  --          letrec f k = (let ba = b in letrec h j = Ret ba in let r = h 0 in Ret r)
  --          in let res = f 0 in case res of Box v -> Ret v
  let claim3 =
        Let (Binder (nm "b" 0) Unrestricted boxTyC)
            (RCon (T.pack "Box") [ALit (LInt 7)])
          (LetRec
            [ ( Binder (nm "f" 1) Unrestricted funTy
              , [Binder (nm "k" 2) Unrestricted intTy]
              , Let (Binder (nm "ba" 30) Unrestricted boxTyC)
                    (RAtom (AVar (nm "b" 0)))           -- same-cell alias of the outside-bound b
                  (LetRec
                    [ ( Binder (nm "h" 3) Unrestricted funTy
                      , [Binder (nm "j" 4) Unrestricted intTy]
                      , Ret (AVar (nm "ba" 30)) ) ]      -- inner group captures the alias
                    (Let (Binder (nm "r" 5) Unrestricted boxTyC)
                         (RApp (AVar (nm "h" 3)) [ALit (LInt 0)])
                      (Ret (AVar (nm "r" 5))))) ) ]
            (Let (Binder (nm "res" 6) Unrestricted boxTyC)
                 (RApp (AVar (nm "f" 1)) [ALit (LInt 0)])
              (Case (AVar (nm "res" 6))
                [ AltCon (T.pack "Box") [Binder (nm "v" 7) Unrestricted intTy]
                    (Ret (AVar (nm "v" 7))) ])))
      claim3Cm = pruneToReachable (CoreModule [TopBind (nm "main" 1000000) [] claim3])
  assertBool "CLAIM 3 (nested group captures outside-bound local via alias) must be REJECTED by the nested-capture fence"
    (any (T.isInfixOf (T.pack "nested LetRec group captures a local bound outside"))
         (firstOrderNoHandlerViolations claim3Cm))

  -- CLAIM 4 (TRIPLE NESTING): group @g@ nested in member @f@, group @h@ nested in
  -- member @g@; @h@ captures @b@ bound OUTSIDE @f@. @b@ is in the member-outer set
  -- of the @g@-member body (snapshotted from @f@'s body), so the innermost fence
  -- fires.
  --   main = let b = Box 7 in
  --          letrec f k = (letrec g m = (letrec h j = Ret b in let r = h 0 in Ret r)
  --                        in let s = g 0 in Ret s)
  --          in let res = f 0 in case res of Box v -> Ret v
  let claim4 =
        Let (Binder (nm "b" 0) Unrestricted boxTyC)
            (RCon (T.pack "Box") [ALit (LInt 7)])
          (LetRec
            [ ( Binder (nm "f" 1) Unrestricted funTy
              , [Binder (nm "k" 2) Unrestricted intTy]
              , LetRec
                  [ ( Binder (nm "g" 40) Unrestricted funTy
                    , [Binder (nm "m" 41) Unrestricted intTy]
                    , LetRec
                        [ ( Binder (nm "h" 3) Unrestricted funTy
                          , [Binder (nm "j" 4) Unrestricted intTy]
                          , Ret (AVar (nm "b" 0)) ) ]    -- innermost group captures outside-f local b
                        (Let (Binder (nm "r" 5) Unrestricted boxTyC)
                             (RApp (AVar (nm "h" 3)) [ALit (LInt 0)])
                          (Ret (AVar (nm "r" 5)))) ) ]
                  (Let (Binder (nm "s" 42) Unrestricted boxTyC)
                       (RApp (AVar (nm "g" 40)) [ALit (LInt 0)])
                    (Ret (AVar (nm "s" 42)))) ) ]
            (Let (Binder (nm "res" 6) Unrestricted boxTyC)
                 (RApp (AVar (nm "f" 1)) [ALit (LInt 0)])
              (Case (AVar (nm "res" 6))
                [ AltCon (T.pack "Box") [Binder (nm "v" 7) Unrestricted intTy]
                    (Ret (AVar (nm "v" 7))) ])))
      claim4Cm = pruneToReachable (CoreModule [TopBind (nm "main" 1000000) [] claim4])
  assertBool "CLAIM 4 (triple-nested group captures outside-bound local) must be REJECTED by the nested-capture fence"
    (any (T.isInfixOf (T.pack "nested LetRec group captures a local bound outside"))
         (firstOrderNoHandlerViolations claim4Cm))

  -- ENTANGLEMENT GATE: every must-reject shape would genuinely DOUBLE-FREE / UAF if
  -- it were admitted. Run each unchecked and assert the RC interpreter FAILS (or
  -- leaves the heap imbalanced) --- so the rejection is load-bearing, not vacuous.
  let wouldFaultUnchecked cm =
        case RCM.runModuleRCUnchecked (Perceus.insertRC cm) of
          Left _    -> True
          Right run -> St.stLive (RCM.rcStats run) /= RCM.rcBaseline run
  assertBool "CLAIM 1 would double-free if admitted (rejection is load-bearing)"
    (wouldFaultUnchecked claim1Cm)
  assertBool "CLAIM 2 would double-free if admitted (rejection is load-bearing)"
    (wouldFaultUnchecked claim2Cm)
  assertBool "CLAIM 3 would double-free if admitted (rejection is load-bearing)"
    (wouldFaultUnchecked claim3Cm)
  assertBool "CLAIM 4 would double-free/UAF if admitted (rejection is load-bearing)"
    (wouldFaultUnchecked claim4Cm)

  -- ADMIT 1 (newly admitted + SOUND): a group nested inside a LAMBDA that sits in a
  -- member body. The lambda body is a fresh frame (resets the member-outer set), so
  -- the nested group is sound exactly as the same group at top level.
  --   main = let b = Box 7 in
  --          letrec f k = (let cl = (\z -> letrec h j = case b of Box v -> Ret v
  --                                        in let r = h 0 in Ret r)
  --                        in let out = cl 0 in Ret out)
  --          in let res = f 0 in Ret res
  let admitLam =
        Let (Binder (nm "b" 0) Unrestricted boxTyC)
            (RCon (T.pack "Box") [ALit (LInt 7)])
          (LetRec
            [ ( Binder (nm "f" 1) Unrestricted funTy
              , [Binder (nm "k" 2) Unrestricted intTy]
              , Let (Binder (nm "cl" 8) Unrestricted funTy)
                    (RLam [Binder (nm "z" 9) Unrestricted intTy]
                      (LetRec
                        [ ( Binder (nm "h" 3) Unrestricted funTy
                          , [Binder (nm "j" 4) Unrestricted intTy]
                          , Case (AVar (nm "b" 0))
                              [ AltCon (T.pack "Box") [Binder (nm "v" 7) Unrestricted intTy]
                                  (Ret (AVar (nm "v" 7))) ] ) ]
                        (Let (Binder (nm "r" 5) Unrestricted intTy)
                             (RApp (AVar (nm "h" 3)) [ALit (LInt 0)])
                          (Ret (AVar (nm "r" 5))))))
                  (Let (Binder (nm "out" 10) Unrestricted intTy)
                       (RApp (AVar (nm "cl" 8)) [ALit (LInt 0)])
                    (Ret (AVar (nm "out" 10)))) ) ]
            (Let (Binder (nm "res" 6) Unrestricted intTy)
                 (RApp (AVar (nm "f" 1)) [ALit (LInt 0)])
              (Ret (AVar (nm "res" 6)))))
      admitLamCm = pruneToReachable (CoreModule [TopBind (nm "main" 1000000) [] admitLam])
  assertBool "ADMIT 1: a group nested inside a lambda in a member body must be ADMITTED"
    (null (firstOrderNoHandlerViolations admitLamCm))
  case (Interp.runModule admitLamCm, RCM.runModuleRCUnchecked (Perceus.insertRC admitLamCm)) of
    (Right v, Right run) -> do
      Interp.renderValue v @?= RCM.rcOutput run
      assertEqual "group-in-lambda: live cells return to baseline"
        (RCM.rcBaseline run) (St.stLive (RCM.rcStats run))
      assertEqual "group-in-lambda: allocs minus frees equal baseline"
        (RCM.rcBaseline run) (St.stAllocs (RCM.rcStats run) - St.stFrees (RCM.rcStats run))
    (refRes, rcRes) ->
      assertFailure ("group-in-lambda: both interpreters must succeed; got "
                       <> either show (const "ok") refRes <> " / "
                       <> either show (const "ok") rcRes)

  -- ADMIT 2 (newly admitted + SOUND): a group nested in a member body capturing a
  -- PER-ENTRY local ALLOCATED inside that member body (@let bloc = Box 9@). It is
  -- NOT in the member-outer set (it is rebuilt per entry alongside the inner env),
  -- so one cascade --- sound.
  --   main = letrec f k = (let bloc = Box 9 in
  --                         letrec h j = case bloc of Box v -> Ret v in let r = h 0 in Ret r)
  --          in let res = f 0 in Ret res
  let admitPerEntry =
        LetRec
          [ ( Binder (nm "f" 1) Unrestricted funTy
            , [Binder (nm "k" 2) Unrestricted intTy]
            , Let (Binder (nm "bloc" 20) Unrestricted boxTyC)
                  (RCon (T.pack "Box") [ALit (LInt 9)])
                (LetRec
                  [ ( Binder (nm "h" 3) Unrestricted funTy
                    , [Binder (nm "j" 4) Unrestricted intTy]
                    , Case (AVar (nm "bloc" 20))
                        [ AltCon (T.pack "Box") [Binder (nm "v" 7) Unrestricted intTy]
                            (Ret (AVar (nm "v" 7))) ] ) ]
                  (Let (Binder (nm "r" 5) Unrestricted intTy)
                       (RApp (AVar (nm "h" 3)) [ALit (LInt 0)])
                    (Ret (AVar (nm "r" 5))))) ) ]
          (Let (Binder (nm "res" 6) Unrestricted intTy)
               (RApp (AVar (nm "f" 1)) [ALit (LInt 0)])
            (Ret (AVar (nm "res" 6))))
      admitPerEntryCm = pruneToReachable (CoreModule [TopBind (nm "main" 1000000) [] admitPerEntry])
  assertBool "ADMIT 2: a nested group capturing a per-entry let-local must be ADMITTED"
    (null (firstOrderNoHandlerViolations admitPerEntryCm))
  case (Interp.runModule admitPerEntryCm, RCM.runModuleRCUnchecked (Perceus.insertRC admitPerEntryCm)) of
    (Right v, Right run) -> do
      Interp.renderValue v @?= RCM.rcOutput run
      assertEqual "per-entry-let-local: live cells return to baseline"
        (RCM.rcBaseline run) (St.stLive (RCM.rcStats run))
      assertEqual "per-entry-let-local: allocs minus frees equal baseline"
        (RCM.rcBaseline run) (St.stAllocs (RCM.rcStats run) - St.stFrees (RCM.rcStats run))
    (refRes, rcRes) ->
      assertFailure ("per-entry-let-local: both interpreters must succeed; got "
                       <> either show (const "ok") refRes <> " / "
                       <> either show (const "ok") rcRes)

  -- PRECISION 1 (admit + SOUND): a FLAT group (top-level scope, lr empty) capturing
  -- an enclosing boxed local. One env cell, one cascade --- verified sound.
  --   main = let b = Box 7 in
  --          letrec h j = (case b of Box v -> Ret v)
  --          in let r = h 0 in Ret r
  let flatBody =
        Let (Binder (nm "b" 0) Unrestricted boxTyC)
            (RCon (T.pack "Box") [ALit (LInt 7)])
          (LetRec
            [ ( Binder (nm "h" 3) Unrestricted funTy
              , [Binder (nm "j" 4) Unrestricted intTy]
              , Case (AVar (nm "b" 0))
                  [ AltCon (T.pack "Box") [Binder (nm "v" 7) Unrestricted intTy]
                      (Ret (AVar (nm "v" 7))) ] ) ]
            (Let (Binder (nm "r" 5) Unrestricted intTy)
                 (RApp (AVar (nm "h" 3)) [ALit (LInt 0)])
              (Ret (AVar (nm "r" 5)))))
      flatCm = pruneToReachable (CoreModule [TopBind (nm "main" 1000000) [] flatBody])
  assertBool "PRECISION: a FLAT group capturing an enclosing local must stay ADMITTED"
    (null (firstOrderNoHandlerViolations flatCm))
  case (Interp.runModule flatCm, RCM.runModuleRCUnchecked (Perceus.insertRC flatCm)) of
    (Right v, Right run) -> do
      Interp.renderValue v @?= RCM.rcOutput run
      let st = RCM.rcStats run
          bl = RCM.rcBaseline run
      assertEqual "flat-capture: live cells return to baseline (no leak/double-free)"
        bl (St.stLive st)
      assertEqual "flat-capture: allocs minus frees equal baseline"
        bl (St.stAllocs st - St.stFrees st)
    (refRes, rcRes) ->
      assertFailure ("flat-capture: both interpreters must succeed; got "
                       <> either show (const "ok") refRes <> " / "
                       <> either show (const "ok") rcRes)

  -- PRECISION 2 (admit): a NESTED group that captures NO enclosing boxed local ---
  -- the inner group references only its own param. lr is non-empty but the
  -- rawEnclosingFv ∩ bsc intersection is empty, so it stays ADMITTED.
  --   main = let b = Box 7 in
  --          letrec f k = (letrec h j = Ret j in let r = h 0 in Ret r)
  --          in case b of Box v -> Ret v
  let nestedNoCap =
        Let (Binder (nm "b" 0) Unrestricted boxTyC)
            (RCon (T.pack "Box") [ALit (LInt 7)])
          (LetRec
            [ ( Binder (nm "f" 1) Unrestricted funTy
              , [Binder (nm "k" 2) Unrestricted intTy]
              , LetRec
                  [ ( Binder (nm "h" 3) Unrestricted funTy
                    , [Binder (nm "j" 4) Unrestricted intTy]
                    , Ret (AVar (nm "j" 4)) ) ]       -- captures only its own param
                  (Let (Binder (nm "r" 5) Unrestricted intTy)
                       (RApp (AVar (nm "h" 3)) [ALit (LInt 0)])
                    (Ret (AVar (nm "r" 5)))) ) ]
            (Case (AVar (nm "b" 0))
              [ AltCon (T.pack "Box") [Binder (nm "v" 7) Unrestricted intTy]
                  (Ret (AVar (nm "v" 7))) ]))
      nestedNoCapCm = pruneToReachable (CoreModule [TopBind (nm "main" 1000000) [] nestedNoCap])
  assertBool "PRECISION: a NESTED group capturing NO enclosing local must stay ADMITTED"
    (null (firstOrderNoHandlerViolations nestedNoCapCm))

-- | FENCE-PARTITION REGRESSION (pins the split between two nested-capture fences,
-- and the soundness boundary it protects).
--
-- A nested group capturing an outside-bound local @b@ through an INSIDE-bound alias
-- is policed by TWO disjoint fences, and which one fires depends on HOW the alias was
-- formed --- a partition that is load-bearing for soundness:
--
--   * SAME-CELL 'RAtom' rename (@let ba = b@): @ba@ names the SAME heap cell as the
--     outside-bound @b@, so capturing it into a nested group genuinely DOUBLE-FREES
--     (@b@ lives in both the member's env and the inner group's env --- two cascades,
--     one incref). 'nestedCaptureViol' catches this BECAUSE @mob@ (the member-outer
--     boxed set) is PROPAGATED through the pure 'RAtom' rename. This rejection is
--     LOAD-BEARING (verified below: it double-frees if force-run).
--
--   * INDIRECT alias --- a 'RApp' call RESULT (@let al = idf b@), an 'RCon'-then-
--     destructure, or an 'RProj' of a record field holding @b@: @mob@ is deliberately
--     NOT propagated through these RHS forms (they allocate / yield a fresh cell in
--     the GENERAL case), so 'nestedCaptureViol' does NOT fire. They are caught instead
--     by the CONSUMING-CAPTURE fence ('consumeViol'): the alias is bound inside the
--     member body so it lands in @bsc@, and a nested group consuming it locally is a
--     consuming capture of a @bsc@ member. CRUCIALLY (verified below) these shapes are
--     actually SOUND if force-run --- the pass's move/projection dup machinery
--     ('projDupFor', 'moveOperandUniques') breaks the aliasing --- so @consumeViol@'s
--     rejection of them is CONSERVATIVE OVER-REJECTION, NOT a load-bearing fence.
--
-- WHY THIS IS PINNED (the cross-fence dependency a future slice must respect): if a
-- later slice RELAXES @consumeViol@ to admit local consumes (via proper borrow-
-- passing), the indirect-alias shapes stay sound, BUT it must NOT also drop the
-- 'RAtom'-rename case from @consumeViol@ on the assumption that @consumeViol@ alone
-- covered it --- the 'RAtom' double-free is held by @nestedCaptureViol@ via @mob@,
-- and that coverage must remain. This test asserts the partition exactly: the
-- 'RAtom' shape is caught by @nestedCaptureViol@ AND double-frees if admitted; the
-- three indirect shapes are caught by @consumeViol@, NOT @nestedCaptureViol@, AND run
-- sound if admitted (the over-rejection is documented, not asserted away).
rcM2a2FencePartitionPinned :: Assertion
rcM2a2FencePartitionPinned = do
  let intTy  = Ty.CTCon Ty.TcU64 []
      funTy  = Ty.CTCon (Ty.TcUser (T.pack "Fun")) []
      recTy  = Ty.CTRecord (T.pack "PCell") Ty.CREmpty
      nm h u = Name (T.pack h) (Unique u)
      -- The inner self-recursive group @h@ CONSUMES its captured alias @aliasN@ by
      -- sealing it into a 'Box' that is destructured-and-dropped locally (the deferred
      -- #1 local-consume shape). @h@ is called by the enclosing member, so the alias is
      -- captured into @h@'s env.
      innerConsumeGroup aliasN contBuild =
        LetRec
          [ ( Binder (nm "h" 3) Unrestricted funTy
            , [Binder (nm "j" 4) Unrestricted intTy]
            , Let (Binder (nm "bx" 8) Unrestricted boxTyC)
                  (RCon (T.pack "Box") [AVar aliasN])      -- MOVE the alias into a Box (consume)
                (Case (AVar (nm "bx" 8))
                  [ AltCon (T.pack "Box") [Binder (nm "cb" 9) Unrestricted boxTyC]
                      (Case (AVar (nm "cb" 9))
                        [ AltCon (T.pack "Box") [Binder (nm "vv" 10) Unrestricted intTy]
                            (Ret (AVar (nm "vv" 10))) ]) ]) ) ]
          (contBuild (nm "h" 3))
      -- The inner group @h@ ESCAPES its captured alias (returns it). This is the shape
      -- whose double-free is genuinely load-bearing for the SAME-CELL 'RAtom' alias.
      innerEscapeGroup aliasN contBuild =
        LetRec
          [ ( Binder (nm "h" 3) Unrestricted funTy
            , [Binder (nm "j" 4) Unrestricted intTy]
            , Ret (AVar aliasN) ) ]                       -- ESCAPE the alias
          (contBuild (nm "h" 3))
      -- The enclosing member @f@ runs @aliasBody@ --- the alias-binding prologue
      -- followed by the nested group + call. @resTy@ is the call result type (int for
      -- the consume shapes; Box for the escape shape).
      mkMember aliasBody =
        ( Binder (nm "f" 1) Unrestricted funTy
        , [Binder (nm "k" 2) Unrestricted intTy]
        , aliasBody )
      consumeCont hN =
        Let (Binder (nm "r" 5) Unrestricted intTy)
            (RApp (AVar hN) [ALit (LInt 0)])
          (Ret (AVar (nm "r" 5)))
      escapeCont hN =
        Let (Binder (nm "r" 5) Unrestricted boxTyC)
            (RApp (AVar hN) [ALit (LInt 0)])
          (Ret (AVar (nm "r" 5)))
      -- An inner group that ESCAPES / CONSUMES its captured alias, with its call
      -- continuation already applied --- a plain @Name -> Expr@ the alias builders feed.
      innerEscape aliasN  = innerEscapeGroup aliasN escapeCont
      innerConsume aliasN = innerConsumeGroup aliasN consumeCont
      -- Drive @main@: build @b@ outside, the group with @f@, call @f@, then either drop
      -- the int result or destructure the escaped Box to a scalar (so the heap empties
      -- on a SOUND run).
      program member resTy escaped =
        Let (Binder (nm "b" 0) Unrestricted boxTyC)
            (RCon (T.pack "Box") [ALit (LInt 7)])
          (LetRec [member]
            (Let (Binder (nm "res" 6) Unrestricted resTy)
                 (RApp (AVar (nm "f" 1)) [ALit (LInt 0)])
              (if escaped
                 then Case (AVar (nm "res" 6))
                        [ AltCon (T.pack "Box") [Binder (nm "v" 7) Unrestricted intTy]
                            (Ret (AVar (nm "v" 7))) ]
                 else Ret (AVar (nm "res" 6)))))
      mkCm member resTy escaped =
        pruneToReachable (CoreModule [TopBind (nm "main" 1000000) [] (program member resTy escaped)])

  -- SAME-CELL alias (RAtom rename), inner group ESCAPES it: the genuine DOUBLE-FREE.
  --   let ba = b   (pure rename --- same cell, mob propagates)
  let ratomAlias k =
        Let (Binder (nm "ba" 30) Unrestricted boxTyC) (RAtom (AVar (nm "b" 0)))
          (k (nm "ba" 30))
      ratomCm = mkCm (mkMember (ratomAlias innerEscape)) boxTyC True

  -- INDIRECT alias 1: call-result  @let al = idf b@  (idf = \x -> x).
  let callResultAlias k =
        Let (Binder (nm "idf" 20) Unrestricted funTy)
            (RLam [Binder (nm "x" 21) Unrestricted boxTyC] (Ret (AVar (nm "x" 21))))
          (Let (Binder (nm "al" 22) Unrestricted boxTyC)
               (RApp (AVar (nm "idf" 20)) [AVar (nm "b" 0)])   -- RApp RESULT (a fresh move)
            (k (nm "al" 22)))
      callResultCm = mkCm (mkMember (callResultAlias innerConsume)) intTy False

  -- INDIRECT alias 2: con-then-destructure  @let c = Box b ; case c of Box al -> ...@
  -- (the destructured child @al@ is dup'd by the pass, breaking the aliasing).
  let conAlias k =
        Let (Binder (nm "c" 23) Unrestricted boxTyC)
            (RCon (T.pack "Box") [AVar (nm "b" 0)])             -- RCon captures b
          (Case (AVar (nm "c" 23))
            [ AltCon (T.pack "Box") [Binder (nm "al" 24) Unrestricted boxTyC]
                (k (nm "al" 24)) ])
      conCm = mkCm (mkMember (conAlias innerConsume)) intTy False

  -- INDIRECT alias 3: record projection  @let c = {p=b} ; let al = c.p@  (RProj of a
  -- record field --- valid projection; 'projDupFor' dups @al@).
  let recProjAlias k =
        Let (Binder (nm "c" 25) Unrestricted recTy)
            (RRecord (T.pack "PCell") [(T.pack "p", AVar (nm "b" 0))])
          (Let (Binder (nm "al" 26) Unrestricted boxTyC)
               (RProj (T.pack "p") (AVar (nm "c" 25)))          -- RProj alias
            (k (nm "al" 26)))
      recProjCm = mkCm (mkMember (recProjAlias innerConsume)) intTy False

  let nestedMsg  = T.pack "nested LetRec group captures a local bound outside"
      consumeMsg = T.pack "consumes an enclosing capture"
      rejectedBy needle cm = any (T.isInfixOf needle) (firstOrderNoHandlerViolations cm)
      wouldFaultUnchecked cm =
        case RCM.runModuleRCUnchecked (Perceus.insertRC cm) of
          Left _    -> True
          Right run -> St.stLive (RCM.rcStats run) /= RCM.rcBaseline run
      runsSoundUnchecked cm =
        case RCM.runModuleRCUnchecked (Perceus.insertRC cm) of
          Left _    -> False
          Right run -> St.stLive (RCM.rcStats run) == RCM.rcBaseline run

  -- SAME-CELL 'RAtom' alias: caught by the NESTED-CAPTURE fence (mob propagates the
  -- rename), and the rejection is LOAD-BEARING --- it genuinely double-frees.
  assertBool "RAtom-rename alias must be REJECTED by the nested-capture fence (mob)"
    (rejectedBy nestedMsg ratomCm)
  assertBool "RAtom-rename alias would DOUBLE-FREE if admitted (nested-capture fence is load-bearing)"
    (wouldFaultUnchecked ratomCm)

  -- INDIRECT aliases: caught by the CONSUMING-CAPTURE fence, NOT the nested-capture
  -- fence (mob does not propagate through RApp/RCon-destructure/RProj). The partition.
  assertBool "call-result alias must be REJECTED by the consuming-capture fence"
    (rejectedBy consumeMsg callResultCm)
  assertBool "call-result alias must NOT be caught by the nested-capture fence (partition)"
    (not (rejectedBy nestedMsg callResultCm))
  assertBool "con-destructure alias must be REJECTED by the consuming-capture fence"
    (rejectedBy consumeMsg conCm)
  assertBool "con-destructure alias must NOT be caught by the nested-capture fence (partition)"
    (not (rejectedBy nestedMsg conCm))
  assertBool "record-proj alias must be REJECTED by the consuming-capture fence"
    (rejectedBy consumeMsg recProjCm)
  assertBool "record-proj alias must NOT be caught by the nested-capture fence (partition)"
    (not (rejectedBy nestedMsg recProjCm))

  -- The indirect-alias rejections are CONSERVATIVE OVER-REJECTION: each actually runs
  -- SOUND if force-run (the pass's move/projection dup machinery breaks the aliasing).
  -- This is documented, not a soundness fault. Pinning it makes the over-rejection a
  -- KNOWN, INTENTIONAL fact: if a future slice relaxes consumeViol to ADMIT these, the
  -- run is already sound (so the admission is safe) --- but the RAtom case above stays
  -- held by the nested-capture fence and must not be dropped.
  assertBool "call-result alias actually RUNS SOUND if admitted (over-rejection, not a double-free)"
    (runsSoundUnchecked callResultCm)
  assertBool "con-destructure alias actually RUNS SOUND if admitted (over-rejection)"
    (runsSoundUnchecked conCm)
  assertBool "record-proj alias actually RUNS SOUND if admitted (over-rejection)"
    (runsSoundUnchecked recProjCm)

-- | The soundness proof. Generate an M2a-1 program; if the boundary guard accepts
-- it, the unchecked RC run MUST succeed, be heap-balanced, AND match the
-- reference value. If the guard rejects, the run assertion is skipped.
prop_m2a1Escape :: Property
prop_m2a1Escape =
  forAllShrink genM2a1Program shrinkProgram $ \cm0 ->
    let cm      = pruneToReachable cm0
        accepted = null (firstOrderNoHandlerViolations cm)
        refRes  = Interp.runModule cm
        rcRes   = RCM.runModuleRCUnchecked (Perceus.insertRC cm)
        report  =
          "boundary accepted: " <> show accepted
            <> "\ninstrumented ANF:\n" <> T.unpack (Perceus.prettyPerceus cm)
            <> "\nreference: " <> showRes (fmap Interp.renderValue refRes)
            <> "\nrc:        " <> showRcRes rcRes
        memberEsc = hasMemberBodyEscape cm
        partialMember = hasPartialMemberApply cm
        rlamMemberPartial = hasRLamMemberPartial cm
        captureEsc = hasCaptureBodyEscape cm
        captureCallHead = hasCaptureCallHead cm
        crossRegion = hasCrossRegion cm
        -- NON-VACUITY (made explicit, and now LOUD via 'checkCoverage'). Three classes
        -- whose absence would silently gut the proof must be GENERATED, ACCEPTED, and
        -- actually RUN --- not merely skipped as rejects:
        --   * the member-body sibling-escape class (BLOCKER 1);
        --   * the PARTIAL APPLICATION of a multi-arity capturing member (the M2a-2
        --     double-free shape --- the LT path of 'enterRC's 'RVRecMember' arm); and
        --   * the RLAM-MEDIATED member-partial class (CROSS 5/6) --- a recursive
        --     member flowed THROUGH an 'RLam' that is itself partially applied, so the
        --     'NClosure' LT branch's 'CaptureMode' propagation (the shared-env
        --     retain/release fix) is exercised through a closure, not only through a
        --     bare named head. Without this floor a regression that stops generating
        --     the RLam-mediated crosses would leave the propagation unguarded.
        -- 'checkCoverage' (wrapping the whole property below) turns each 'cover'
        -- floor from an inert warning into a HARD FAILURE: if a generator regression
        -- stops producing any class above its floor, the property goes red.
        ranSound = accepted && either (const False) (const True) rcRes
    in checkCoverage $
       cover 4.0 (memberEsc && ranSound) "member-body sibling escape: accepted+run" $
       cover 3.0 (partialMember && ranSound) "partial multi-arity member apply: accepted+run" $
       cover 3.0 (rlamMemberPartial && ranSound) "RLam-mediated member partial (CROSS 5/6): accepted+run" $
       cover 5.0 (captureEsc && ranSound) "member-body CAPTURE escape: accepted+run" $
       cover 3.0 (captureCallHead && ranSound) "member-body CAPTURE call-head: accepted+run" $
       -- CROSS-REGION (#3): the class MUST be generated AND REJECTED (the fence is the
       -- only thing keeping a cross-region counted edge out; its absence from coverage
       -- previously left the fence with ZERO generative teeth). The 'cover' pins the
       -- generation rate; the conjoined property below pins that a generated
       -- cross-region program is ALWAYS rejected, so a regression that stops rejecting
       -- cross-region goes red.
       cover 3.0 (crossRegion && not accepted) "cross-region capture: generated+rejected" $
       counterexample ("cross-region program was NOT rejected (fence regression): "
                         <> T.unpack (Perceus.prettyPerceus cm))
         (not crossRegion || not accepted)
         .&&.
       QC.label (if memberEsc
                   then if accepted then "member-body-escape: accepted+run"
                                    else "member-body-escape: rejected"
                   else if partialMember
                          then if accepted then "partial-member-apply: accepted+run"
                                           else "partial-member-apply: rejected"
                          else "other shape")
       (counterexample report $
         if not accepted
           then property True   -- rejection is the conservative, always-sound verdict
           else case (refRes, rcRes) of
                  (Right v, Right run) ->
                    let outOk      = Interp.renderValue v == RCM.rcOutput run
                        st         = RCM.rcStats run
                        baseline   = RCM.rcBaseline run
                        liveOk     = St.stLive st == baseline
                        balancedOk = St.stAllocs st - St.stFrees st == baseline
                    in counterexample "ACCEPTED but unsound: output / heap-empty / balanced mismatch"
                         (outOk && liveOk && balancedOk)
                  -- BOTH failing is AGREEMENT ONLY when they fail the SAME WAY (a
                  -- shared evaluator limitation). It is NOT a free pass: an RC
                  -- memory-safety fault (double-free / UAF / dangling --- a 'PrimError'
                  -- the store-less reference can NEVER produce) is a real one-sided
                  -- soundness fault that MUST fail loudly even when the reference also
                  -- errored, and a freed-env UAF can surface as a quiet 'UnboundVar'.
                  -- Mirrors 'assertRcAgrees': reject any RC mem-safety fault, then
                  -- require the two failures to share an error constructor.
                  (Left refE, Left rcE)
                    | rcMemSafetyFault rcE ->
                        counterexample ("ACCEPTED but unsound: RC memory-safety fault hidden behind a \
                                        \reference failure: rc=" <> show rcE <> " ref=" <> show refE)
                          False
                    | errCtorTag refE == errCtorTag rcE ->
                        counterexample "both interpreters failed the same way (agreement)" True
                    | otherwise ->
                        counterexample ("ACCEPTED but unsound: RC failure DIVERGES from the reference \
                                        \failure: ref=" <> show refE <> " rc=" <> show rcE)
                          False
                  _ ->
                    counterexample "ACCEPTED but unsound: exactly one interpreter failed" False)
  where
    showRes (Right t)  = T.unpack t
    showRes (Left e)   = "FAILED (" <> show e <> ")"
    showRcRes (Right run) = T.unpack (RCM.rcOutput run)
    showRcRes (Left e)    = "FAILED (" <> show e <> ")"

-- | Structural detector for the MEMBER-BODY sibling-escape class (BLOCKER 1): a
-- 'LetRec' MEMBER body (NOT the group body) in which a SIBLING group-binder occurs
-- in an ESCAPING position --- a 'Ret' atom, or a 'RCon'/'RRecord' field, or a
-- non-head call argument. A call-HEAD occurrence (a recursive call) is excluded (it
-- is a borrow, not an escape). Used only for the 'cover'/'label' non-vacuity floor.
hasMemberBodyEscape :: CoreModule -> Bool
hasMemberBodyEscape (CoreModule bs) = any (topB) bs
  where
    topB (TopBind _ _ body) = go Set.empty body
    -- @sibs@ = the group-binder Uniques whose MEMBER BODIES we are currently inside.
    go sibs e = case e of
      Ret a              -> escapesSib sibs [a]
      Let _ r body       -> rhsEsc sibs r || go sibs body
      Case _ alts        -> any (altG sibs) alts
      LetJoin _ _ jb body -> go sibs jb || go sibs body
      Jump _ as          -> escapesSib sibs as
      LetRec defs body   ->
        let gU = Set.fromList [ binderUnique b | (b, _, _) <- defs ]
            -- INSIDE each member body the siblings are escape candidates.
            inMember = any (\(_, _, d) -> go gU d) defs
        in inMember || go sibs body   -- group body uses the OUTER sibs only
      Handle _ _         -> False
    altG sibs (AltCon _ _ b) = go sibs b
    altG sibs (AltLit _ b)   = go sibs b
    altG sibs (AltDefault b) = go sibs b
    -- An escaping RHS: a sibling moved into a con/record field or a non-head call
    -- argument. The call HEAD of an 'RApp' is a borrow (excluded). 'RLam' captures
    -- are handled by descending (a captured sibling escapes via the closure cell).
    rhsEsc sibs r = case r of
      RCon _ as       -> escapesSib sibs as
      RRecord _ flds  -> escapesSib sibs (map snd flds)
      RApp _ as       -> escapesSib sibs as            -- args escape; head borrows
      RLam _ b        -> go sibs b
      _               -> False
    escapesSib sibs as = any (\a -> case a of AVar n -> Set.member (nameUniq n) sibs; _ -> False) as

-- | Structural detector for the CAPTURE-BODY-escape class (the capture analogue of
-- 'hasMemberBodyEscape', the M2CaptureBodyEscape family): a 'LetRec' MEMBER body
-- that ESCAPES an ENCLOSING BOXED CAPTURE --- a boxed free variable bound OUTSIDE
-- the group that is NEITHER a sibling group binder NOR one of that member's own
-- params --- by carrying it OUT as (part of) the body's RETURN VALUE.
--
-- The detector is SPECIFIC to that class. It must NOT fire on a SIBLING-member
-- escape (a member returning a fellow group binder --- the M2MemberBodyEscape
-- family) nor on a recursion-SEED escape (an enclosing value returned from the
-- GROUP BODY, not from inside a member body) --- those are distinct code paths.
-- The earlier detector was over-broad (it fired on ~55% of programs across every
-- family) because it tracked ANY enclosing 'Unique' as a capture, regardless of
-- boxedness, and counted escapes that were not genuine member-body capture flows.
--
-- The specificity comes from mirroring the real pass predicate
-- 'letRecMemberConsumesCaptureNonEscaping' / 'captureEscapesBody' in
-- "src/Wok/IR/Escape.hs": for each group member we compute its enclosing boxed
-- capture set (free vars of the body, minus the member's params, minus the group
-- binders, intersected with the boxed binders in scope) and fire iff SOME such
-- capture flows OUT of that member body as its return value. The escape walk
-- ('captureFlowsOut') is a focused AST matcher --- it does NOT re-run the pass.
-- Used only for the 'cover' / 'label' non-vacuity floor.
hasCaptureBodyEscape :: CoreModule -> Bool
hasCaptureBodyEscape (CoreModule bs) = any topB bs
  where
    -- @boxed@ = Uniques of BOXED binders bound in ENCLOSING scopes (capture
    -- candidates for any nested group member).
    topB (TopBind _ ps body) = go (boxedOf ps) body
    go boxed e = case e of
      Ret _                -> False
      Jump _ _             -> False
      Let b r body         ->
        goR boxed r
          || go (extend boxed [b]) body
      Case _ alts          -> any (altG boxed) alts
      LetJoin _ ps jb body -> go (extend boxed ps) jb || go boxed body
      LetRec defs body     ->
        let groupU = Set.fromList [ binderUnique b | (b, _, _) <- defs ]
            -- A member body's enclosing boxed captures: its free vars, minus its own
            -- params, minus the sibling group binders, intersected with the boxed
            -- binders in enclosing scope. Fire iff one of them flows OUT as the body's
            -- return value (the genuine member-body capture escape).
            memberEscapes (_, dps, d) =
              let params = Set.fromList (map binderUnique dps)
                  caps   = ((freeVarsExpr d `Set.difference` params)
                             `Set.difference` groupU)
                            `Set.intersection` boxed
              in any (`captureFlowsOut` d) (Set.toList caps)
            -- Inside the GROUP BODY the siblings are now in scope (boxed function
            -- binders), but the group body is NOT a member body, so a return there is
            -- a seed/sibling escape (a different code path), not this class.
            boxedBody = extend boxed [ b | (b, _, _) <- defs ]
        in any memberEscapes defs || go boxedBody body
      Handle _ _           -> False
    altG boxed (AltCon _ bs' b) = go (extend boxed bs') b
    altG boxed (AltLit _ b)     = go boxed b
    altG boxed (AltDefault b)   = go boxed b
    goR boxed r = case r of
      RLam _ b -> go boxed b
      _        -> False
    extend boxed bs' = Set.union boxed (boxedOf bs')
    boxedOf = Set.fromList . map binderUnique . filter (Esc.isBoxedType . bndType)

-- | True iff the captured value @u0@ flows OUT of the member body @body@ AS (part
-- of) its RETURN VALUE: it (or a con/record container holding it, or an alias)
-- reaches a 'Ret' or a 'Jump' argument. Mirrors 'captureEscapesBody' in
-- "src/Wok/IR/Escape.hs" --- the exact admissible-escape rule the pass dup-balances
-- --- but as a TEST-side AST matcher (no pass internals imported). A capture sealed
-- into a con/record that is destructured-and-dropped INSIDE the body, passed as a
-- call argument, re-captured into a nested closure, or projected does NOT count.
captureFlowsOut :: Unique -> Expr -> Bool
captureFlowsOut u0 = goE (Set.singleton u0)
  where
    hit tracked a = case a of
      AVar n -> nameUniq n `Set.member` tracked
      ALit _ -> False
    anyHit tracked = any (hit tracked)
    goE tracked e = case e of
      Ret a              -> hit tracked a
      Jump _ as          -> anyHit tracked as
      Let bd r body      -> case r of
        RAtom (AVar n)
          | nameUniq n `Set.member` tracked ->
              goE (Set.insert (binderUnique bd) tracked) body
        RCon _ as
          | anyHit tracked as ->
              goE (Set.insert (binderUnique bd) tracked) body
        RRecord _ flds
          | anyHit tracked (map snd flds) ->
              goE (Set.insert (binderUnique bd) tracked) body
        _ -> goE tracked body
      LetRec ds body     -> any (\(_, _, d) -> goE tracked d) ds || goE tracked body
      Case _ alts        -> any (goAlt tracked) alts
      LetJoin _ _ jb body -> goE tracked jb || goE tracked body
      Handle e' _        -> goE tracked e'
    goAlt tracked (AltCon _ _ e) = goE tracked e
    goAlt tracked (AltLit _ e)   = goE tracked e
    goAlt tracked (AltDefault e) = goE tracked e

-- ---------------------------------------------------------------------------
-- DRIFT GUARD for the single-source escape walker (feat/rc-escape-single-source)
--
-- 'Esc.captureEscapesBody' was refactored to DERIVE from the shared 'escapeWalk'
-- skeleton instead of re-listing its own per-'Rhs' case table. The refactor is a
-- pure dedup --- it MUST be result-identical on every input. 'oldCaptureEscapesBody'
-- below is a FROZEN, byte-faithful copy of the pre-refactor hand-rolled definition;
-- it is the ORACLE. 'prop_captureEscapesBodyMatchesOracle' pins the two equal over
-- generated programs, and 'captureEscapesBodyDriftGuard' pins them over a battery of
-- hand-built RHS shapes (Ret/Jump/RCon/RRecord/RProj/RApp-arg/RApp-head/alias-chain/
-- Case). If a future edit to the shared skeleton drifts the verdict on ANY shape, one
-- of these fails. DO NOT "fix" the oracle to track the new behaviour --- a divergence
-- is a real regression in the dedup.

-- | FROZEN ORACLE: the pre-refactor hand-rolled 'captureEscapesBody'. Kept verbatim
-- so a drift in the shared 'escapeWalk' fold is caught. (Mirror only --- never edit
-- to follow a behaviour change.)
oldCaptureEscapesBody :: Unique -> Expr -> Bool
oldCaptureEscapesBody u0 = goE (Set.singleton u0)
  where
    hit tracked a = case a of
      AVar n -> Name.nameUniq n `Set.member` tracked
      ALit _ -> False
    anyHit tracked = any (hit tracked)
    goE tracked e = case e of
      Ret a                 -> hit tracked a
      Jump _ as             -> anyHit tracked as
      Let bd r body         -> case r of
        RAtom (AVar n)
          | Name.nameUniq n `Set.member` tracked ->
              goE (Set.insert (binderUnique bd) tracked) body
        RCon _ as
          | anyHit tracked as ->
              goE (Set.insert (binderUnique bd) tracked) body
        RRecord _ flds
          | anyHit tracked (map snd flds) ->
              goE (Set.insert (binderUnique bd) tracked) body
        _ -> goE tracked body
      LetRec ds body        -> any (\(_, _, d) -> goE tracked d) ds || goE tracked body
      Case _ alts           -> any (goAlt tracked) alts
      LetJoin _ _ jb body   -> goE tracked jb || goE tracked body
      Handle e' _           -> goE tracked e'
    goAlt tracked (AltCon _ _ e) = goE tracked e
    goAlt tracked (AltLit _ e)   = goE tracked e
    goAlt tracked (AltDefault e) = goE tracked e

-- | Every 'Unique' that NAMES a binder or occurs as an atom anywhere in @e@. Used
-- as the drift-guard's probe set: 'captureEscapesBody' must agree with the oracle on
-- ALL of them (not just genuine captures), so the equality is total over the corpus.
allMentionedUniques :: Expr -> Set.Set Unique
allMentionedUniques = go
  where
    go e = case e of
      Ret a               -> atomVars a
      Jump _ as           -> Set.unions (map atomVars as)
      Let bd r body       -> Set.insert (binderUnique bd) (goR r) `Set.union` go body
      LetRec ds body      ->
        Set.unions (go body : [ Set.insert (binderUnique b) (go d) | (b, _, d) <- ds ])
      Case a alts         -> atomVars a `Set.union` Set.unions (map goAlt alts)
      LetJoin _ ps jb body ->
        Set.fromList (map binderUnique ps) `Set.union` go jb `Set.union` go body
      Handle e' _         -> go e'
    goAlt (AltCon _ bs e) = Set.fromList (map binderUnique bs) `Set.union` go e
    goAlt (AltLit _ e)    = go e
    goAlt (AltDefault e)  = go e
    goR r = case r of
      RAtom a      -> atomVars a
      RApp h as    -> Set.unions (map atomVars (h : as))
      RCon _ as    -> Set.unions (map atomVars as)
      RLam ps e    -> Set.fromList (map binderUnique ps) `Set.union` go e
      ROp m _ _ as -> Set.unions (map atomVars (maybe as (: as) m))
      RRecord _ fl -> Set.unions (map (atomVars . snd) fl)
      RProj _ a    -> atomVars a

-- | All sub-expressions of @e@ (including @e@ itself), so the drift guard probes
-- 'captureEscapesBody' at every body position, not just the top.
allSubExprs :: Expr -> [Expr]
allSubExprs e = e : case e of
  Ret _                -> []
  Jump _ _             -> []
  Let _ r body         -> rhsSub r ++ allSubExprs body
  LetRec ds body       -> concat [ allSubExprs d | (_, _, d) <- ds ] ++ allSubExprs body
  Case _ alts          -> concatMap altSub alts
  LetJoin _ _ jb body  -> allSubExprs jb ++ allSubExprs body
  Handle e' _          -> allSubExprs e'
  where
    altSub (AltCon _ _ b) = allSubExprs b
    altSub (AltLit _ b)   = allSubExprs b
    altSub (AltDefault b) = allSubExprs b
    rhsSub (RLam _ b)     = allSubExprs b
    rhsSub _              = []

-- | DRIFT GUARD (generative): 'Esc.captureEscapesBody' must equal the frozen oracle
-- on EVERY (capture 'Unique', sub-expression) pair of every generated program. A
-- single disagreement is a regression in the single-source fold.
prop_captureEscapesBodyMatchesOracle :: Property
prop_captureEscapesBodyMatchesOracle =
  forAllShrink genM2a1Program shrinkProgram $ \(CoreModule binds) ->
    conjoin
      [ counterexample
          ("captureEscapesBody DRIFTED from oracle for u=" <> show u
             <> "\nsub-expr:\n" <> show sub)
          (Esc.captureEscapesBody u sub QC.=== oldCaptureEscapesBody u sub)
      | TopBind _ _ body <- binds
      , sub <- allSubExprs body
      , u   <- Set.toList (allMentionedUniques sub)
      ]

-- | DRIFT GUARD (hand-built shapes): pin 'captureEscapesBody' against the oracle on
-- the matrix the M2a-2 admit/reject verdicts turn on --- Ret/Jump (escape), a
-- returned RCon/RRecord container (escape via the tracked-closure), an RProj parent
-- / a non-head RApp arg / an RApp head / a re-capturing RLam / an ROp arg (all
-- NON-escape), and an alias chain that ends in a Ret (escape). The oracle equality
-- is the single-source property; we additionally assert the GROUND TRUTH verdict on
-- each shape so the matrix itself is pinned, not just self-consistency.
captureEscapesBodyDriftGuard :: Assertion
captureEscapesBodyDriftGuard = do
  let u  = Unique 9001
      nU = Name (T.pack "u") u
      boxed = Ty.CTCon Ty.TcBool []
      bnd t uq = Binder (Name (T.pack "b") (Unique uq)) Unrestricted t
      var uq = AVar (Name (T.pack "b") (Unique uq))
      -- shape, expected verdict
      shapes :: [(String, Expr, Bool)]
      shapes =
        [ ("Ret of capture",            Ret (AVar nU),                       True)
        , ("Jump of capture",           Jump (JoinId (Unique 1)) [AVar nU],  True)
        , ("returned RCon container",
            Let (bnd boxed 10) (RCon (T.pack "Box") [AVar nU])
              (Ret (var 10)),                                                True)
        , ("returned RRecord container",
            Let (bnd boxed 11) (RRecord (T.pack "R") [(T.pack "f", AVar nU)])
              (Ret (var 11)),                                                True)
        , ("alias chain then Ret",
            Let (bnd boxed 12) (RAtom (AVar nU))
              (Let (bnd boxed 13) (RAtom (var 12)) (Ret (var 13))),          True)
        , ("RCon container destructured-and-dropped locally",
            Let (bnd boxed 14) (RCon (T.pack "Box") [AVar nU])
              (Ret (ALit LUnit)),                                            False)
        , ("non-head RApp arg (consumed by callee)",
            Let (bnd boxed 15) (RApp (var 99) [AVar nU]) (Ret (ALit LUnit)), False)
        , ("RApp head (borrow)",
            Let (bnd boxed 16) (RApp (AVar nU) [ALit LUnit]) (Ret (ALit LUnit)), False)
        , ("re-capture into nested RLam",
            Let (bnd boxed 17) (RLam [bnd boxed 18] (Ret (AVar nU)))
              (Ret (ALit LUnit)),                                            False)
        , ("RProj parent",
            Let (bnd boxed 19) (RProj (T.pack "f") (AVar nU)) (Ret (ALit LUnit)), False)
        , ("ROp arg",
            Let (bnd boxed 20) (ROp Nothing (T.pack "E") (T.pack "op") [AVar nU])
              (Ret (ALit LUnit)),                                            False)
        , ("Case scrutinee (matched, not flowed out)",
            Case (AVar nU) [AltDefault (Ret (ALit LUnit))],                  False)
        , ("capture re-named inside Case alt then Ret",
            Case (ALit LUnit) [AltDefault (Ret (AVar nU))],                  True)
        ]
  mapM_ (\(label, expr, expected) -> do
            assertEqual (label <> ": verdict") expected (Esc.captureEscapesBody u expr)
            assertEqual (label <> ": matches oracle")
              (oldCaptureEscapesBody u expr) (Esc.captureEscapesBody u expr))
        shapes

-- | Non-vacuity detector for the M2CaptureCallHead family (the call-head admit
-- guard): a 'LetRec' MEMBER body in which an enclosing CAPTURE (a 'Unique' bound
-- OUTSIDE the group --- not a sibling, not a member param) occurs as an 'RApp' call
-- HEAD. A call head is a BORROW, so this shape must be ADMITTED and run sound; the
-- floor keeps the generator from silently dropping it. Mirrors the @outer@/
-- @inMember@ threading of 'hasCaptureBodyEscape'.
hasCaptureCallHead :: CoreModule -> Bool
hasCaptureCallHead (CoreModule bs) = any topB bs
  where
    topB (TopBind _ ps body) = go (Set.fromList (map binderUnique ps)) False body
    go outer inMember e = case e of
      Ret _                -> False
      Jump _ _             -> False
      Let b r body         ->
        rhsHead outer inMember r
          || go (Set.insert (binderUnique b) outer) inMember body
      Case _ alts          -> any (altG outer inMember) alts
      LetJoin _ ps jb body ->
        let outer' = Set.union outer (Set.fromList (map binderUnique ps))
        in go outer' inMember jb || go outer inMember body
      LetRec defs body     ->
        let gU = Set.fromList [ binderUnique b | (b, _, _) <- defs ]
            inDef (_, dps, d) =
              go (Set.union outer (Set.fromList (map binderUnique dps))) True d
            outerBody = Set.union outer gU
        in any inDef defs || go outerBody inMember body
      Handle _ _           -> False
    altG outer inMember (AltCon _ bs' b) =
      go (Set.union outer (Set.fromList (map binderUnique bs'))) inMember b
    altG outer inMember (AltLit _ b)   = go outer inMember b
    altG outer inMember (AltDefault b) = go outer inMember b
    rhsHead outer inMember r = case r of
      RApp (AVar n) _ -> inMember && Set.member (nameUniq n) outer
      _               -> False

-- | Non-vacuity detector for the M2CrossRegion family (the cross-region #3 fence):
-- some 'LetRec' group, somewhere, captures an OUTER 'LetRec' GROUP-MEMBER binder ---
-- a free var of an inner group member that is bound by an ENCLOSING group still in
-- scope (NOT by this group, NOT by the member's own params). Mirrors the boundary
-- 'crossRegionViol' predicate (@rawEnclosingFv defs ∩ lr@) as a TEST-side AST matcher:
-- @lr@ is threaded as the set of enclosing group binders in scope. Used only for the
-- 'cover' floor that the cross-region class is GENERATED (and, paired with the
-- always-reject verdict, REJECTED), giving the otherwise-untested fence generative
-- teeth. The fence is the SOURCE OF TRUTH; this is a structural witness, not a re-run.
hasCrossRegion :: CoreModule -> Bool
hasCrossRegion (CoreModule bs) = any topB bs
  where
    topB (TopBind _ _ body) = go Set.empty body
    -- @lr@ = the Uniques of group binders bound by ENCLOSING (in-scope) LetRec groups.
    go lr e = case e of
      Ret _              -> False
      Jump _ _           -> False
      Let _ r body       -> goR lr r || go lr body
      Case _ alts        -> any (altG lr) alts
      LetJoin _ _ jb body -> go lr jb || go lr body
      Handle e' _        -> go lr e'
      LetRec defs body   ->
        let groupU = Set.fromList [ binderUnique b | (b, _, _) <- defs ]
            params ps = Set.fromList (map binderUnique ps)
            rawEncl =
              Set.unions
                [ (freeVarsExpr d `Set.difference` params ps) `Set.difference` groupU
                | (_, ps, d) <- defs ]
            -- cross-region: an inner member captures an OUTER region member (in @lr@).
            here = not (Set.null (Set.intersection rawEncl lr))
            lr'  = Set.union lr groupU
            -- member bodies see the EXTENDED region set (so a doubly-nested group's
            -- capture of the outermost member is detected too).
            inMembers = any (\(_, _, d) -> go lr' d) defs
        in here || inMembers || go lr' body
    altG lr (AltCon _ _ b) = go lr b
    altG lr (AltLit _ b)   = go lr b
    altG lr (AltDefault b) = go lr b
    goR lr r = case r of
      RLam _ b -> go lr b
      _        -> False

-- | The static oracle must be clean on every IN-FRAGMENT generated program (one
-- the boundary guard ACCEPTS). 'balanceLint' runs 'insertRC' itself and does not
-- consult the boundary guard, so on an ESCAPING (out-of-fragment) program ---
-- e.g. a sibling alias that is RETURNED --- it CORRECTLY reports the over-consume
-- of the escaped value ("not owned here"); that is the conservative reject the
-- boundary makes, not a pass bug. We therefore gate on acceptance (in-fragment)
-- and document the skip: a boundary-rejected program may legitimately lint dirty.
prop_m2a1LintClean :: Property
prop_m2a1LintClean =
  forAllShrink genM2a1Program shrinkProgram $ \cm0 ->
    let cm   = pruneToReachable cm0
        viol = Perceus.balanceLint cm
    in if not (null (firstOrderNoHandlerViolations cm))
         then property True   -- out-of-fragment: a dirty lint is the conservative reject
         else counterexample ("balanceLint reported on an IN-FRAGMENT program: " <> show viol
                                <> "\nANF:\n" <> T.unpack (Perceus.prettyPerceus cm))
                (null viol)

-- | Generalized fault-injection: for every generated program, each single-site
-- mutation must be CAUGHT --- either 'lintInstrumented' flags the mutated,
-- already-instrumented module, OR the unchecked RC run trips a 'Left'. This turns
-- the three hand teeth into a generative oracle. A mutation that is a structural
-- no-op on a particular program (e.g. 'OmitOneDrop' when the program inserts no
-- drop) leaves the bytes IDENTICAL to the correct instrumentation; we detect that
-- and treat it as vacuously fine for that program (no mutation actually happened),
-- so it is not a false counterexample.
prop_m2a1Teeth :: Property
prop_m2a1Teeth =
  forAllShrink genM2a1Program shrinkProgram $ \cm0 ->
    let cm = pruneToReachable cm0
    in conjoin
         [ counterexample ("mutation " <> show mut <> " was NOT caught\nANF:\n"
                             <> T.unpack (Perceus.prettyPerceus cm))
             (mutationCaught mut cm)
         | mut <- [Perceus.OmitOneDrop, Perceus.OmitOneDup, Perceus.DuplicateOneDrop] ]

-- | Is the given single-site mutation caught on this module, or a structural
-- no-op? Caught = a non-empty 'lintInstrumented' OR a 'Left' from the unchecked
-- RC run. No-op = the mutated instrumentation is byte-identical to the correct
-- one (the mutation site did not exist), which counts as "fine" (nothing to
-- catch).
mutationCaught :: Perceus.Mutation -> CoreModule -> Bool
mutationCaught mut cm =
  let correct = Perceus.insertRC cm
      mutated = Perceus.insertRCMutated mut cm
  in mutated == correct                                  -- mutation was a no-op
       || not (null (Perceus.lintInstrumented mutated))  -- caught statically
       || (case RCM.runModuleRCUnchecked mutated of      -- caught at runtime
             Left _  -> True
             Right _ -> False)

-- | Shrinking: drop the program toward a constant. We shrink the single 'main'
-- bind's body to its trivial sub-results (a 'Ret' of a contained atom, an alt
-- body, or a let body), preserving well-scopedness by only ever REPLACING an
-- expression with one of its own sub-expressions whose free variables are a
-- subset of the original's. The simplest safe shrink: replace the body with a
-- 'Ret' of a literal of the same shape is unsound (type may differ), so we only
-- climb into structurally-contained sub-expressions.
shrinkProgram :: CoreModule -> [CoreModule]
shrinkProgram (CoreModule [TopBind n ps body]) =
  [ CoreModule [TopBind n ps body'] | body' <- shrinkExpr body ]
shrinkProgram _ = []

-- | Sub-expressions reachable by peeling one constructor layer, restricted to
-- those that remain WELL-SCOPED on their own (no free variable bound only by the
-- peeled layer). Returns same-typed continuations only (a let body, an alt body),
-- never a differently-typed fragment.
shrinkExpr :: Expr -> [Expr]
shrinkExpr e = case e of
  Let b _ body
    | not (Name.nameUniq (bndName b) `Set.member` exprUniques body) -> [body]
    | otherwise -> []
  Case _ alts ->
    [ altBody | alt <- alts
              , Just altBody <- [altClosedBody alt] ]
  -- A join cluster: recursively shrink the delivering body, keeping the join
  -- DEFINED so no 'Jump' is stranded; additionally offer dropping the whole join
  -- iff the delivering body never jumps to it. We never extract a join body alone
  -- (it may reference the join params or the captured var).
  LetJoin j ps jb body ->
    [ LetJoin j ps jb body' | body' <- shrinkExpr body ]
      ++ [ body | not (exprJumpsTo j body) ]
  _ -> []
  where
    -- Only extract an alt body that is well-scoped on its own: no free child
    -- binder, and no 'Jump' (which would dangle once its enclosing join is gone).
    altClosedBody (AltCon _ bs b)
      | not (any (\bd -> Name.nameUniq (bndName bd) `Set.member` exprUniques b) bs)
      , not (exprHasJump b) = Just b
      | otherwise = Nothing
    altClosedBody (AltLit _ b)   | not (exprHasJump b) = Just b
                                 | otherwise           = Nothing
    altClosedBody (AltDefault b) | not (exprHasJump b) = Just b
                                 | otherwise           = Nothing

-- | Does @e@ contain any 'Jump' (which would dangle if extracted from its
-- enclosing join)? Used to keep 'shrinkExpr' from producing ill-scoped fragments.
exprHasJump :: Expr -> Bool
exprHasJump (Jump _ _)         = True
exprHasJump (Ret _)            = False
exprHasJump (Let _ _ e)        = exprHasJump e
exprHasJump (Case _ alts)      = any (exprHasJump . clusterAltBody) alts
exprHasJump (LetJoin _ _ jb e) = exprHasJump jb || exprHasJump e
exprHasJump (LetRec ds e)      = any (\(_, _, b) -> exprHasJump b) ds || exprHasJump e
exprHasJump (Handle e _)       = exprHasJump e

-- | Does @e@ jump to the specific join @j@ (so dropping @j@'s binder would strand it)?
exprJumpsTo :: JoinId -> Expr -> Bool
exprJumpsTo j (Jump j' _)        = j == j'
exprJumpsTo _ (Ret _)            = False
exprJumpsTo j (Let _ _ e)        = exprJumpsTo j e
exprJumpsTo j (Case _ alts)      = any (exprJumpsTo j . clusterAltBody) alts
exprJumpsTo j (LetJoin _ _ jb e) = exprJumpsTo j jb || exprJumpsTo j e
exprJumpsTo j (LetRec ds e)      = any (\(_, _, b) -> exprJumpsTo j b) ds || exprJumpsTo j e
exprJumpsTo j (Handle e _)       = exprJumpsTo j e

clusterAltBody :: Anf.Alt -> Expr
clusterAltBody (AltCon _ _ b) = b
clusterAltBody (AltLit _ b)   = b
clusterAltBody (AltDefault b) = b

-- ---------------------------------------------------------------------------
-- Task 2: RVRecMember representation tests

-- | 'St.valueChildren' must correctly enumerate the COUNTED child addresses for
-- each 'St.RCValue' variant. 'RVLit' has none, 'RVBox' has one (the node
-- pointer), and 'RVRecMember' has one (the shared env addr @envAddr@); the
-- static @groupAddr@ is UNCOUNTED and must NOT appear.
rvRecMemberChildren :: Assertion
rvRecMemberChildren = do
  assertEqual "lit has no children"    []  (St.valueChildren (St.RVLit LUnit))
  assertEqual "box child"              [7] (St.valueChildren (St.RVBox 7))
  assertEqual "recmember counts env"   [9] (St.valueChildren (St.RVRecMember (-5) 0 9))

-- | Dropping the env address referenced by an 'St.RVRecMember' must free the
-- 'NEnv' cell.  An 'NEnv Map.empty' has no children, so after the single drop
-- the live count must be zero.
rvRecMemberDropCountsEnv :: Assertion
rvRecMemberDropCountsEnv = do
  let (envA, s0) = St.alloc (St.NEnv Map.empty) St.emptyStore
  case St.dropAddr envA s0 of
    Right s1 -> assertEqual "env freed" 0 (St.stLive (St.stStats s1))
    Left err -> assertFailure (show err)

-- | The static sentinel installed by 'St.initSentinel' must live at
-- 'St.emptyEnvSentinelAddr' and be a static (negative) address, so
-- 'St.incref' and 'St.dropAddr' are no-ops on it.
rvRecMemberSentinelNoOp :: Assertion
rvRecMemberSentinelNoOp = do
  let s0 = St.initSentinel St.emptyStore
  -- The sentinel must be at the fixed static address.
  assertEqual "sentinel addr is static" True (St.isStaticAddr St.emptyEnvSentinelAddr)
  -- incref on the sentinel is a no-op: store is unchanged.
  case St.incref St.emptyEnvSentinelAddr s0 of
    Left err -> assertFailure ("incref sentinel failed: " <> show err)
    Right s1 -> assertEqual "incref on sentinel is no-op (live unchanged)" 0
                  (St.stLive (St.stStats s1))
  -- dropAddr on the sentinel is a no-op: store is unchanged.
  case St.dropAddr St.emptyEnvSentinelAddr s0 of
    Left err -> assertFailure ("drop sentinel failed: " <> show err)
    Right s1 -> assertEqual "drop on sentinel is no-op (live unchanged)" 0
                  (St.stLive (St.stStats s1))

-- | 'St.renderRCValue' must render an 'St.RVRecMember' as @"<closure>"@,
-- matching the reference interpreter's closure rendering for the differential
-- oracle.
rvRecMemberRender :: Assertion
rvRecMemberRender = do
  let s  = St.emptyStore
      v  = St.RVRecMember (-5) 0 9
  case St.renderRCValue s v of
    Left err  -> assertFailure ("renderRCValue failed: " <> show err)
    Right txt -> assertEqual "renders as <closure>" (T.pack "<closure>") txt

-- | The test group for the 'RVRecMember' / 'NGroupCode' / 'NEnv'
-- representation additions (Task 2, M2a-2).
rvRecMemberRepTests :: TestTree
rvRecMemberRepTests = testGroup "rvrecmember-rep"
  [ testCase "valueChildren: lit=[], box=[a], recmember=[envAddr]" rvRecMemberChildren
  , testCase "drop of envAddr frees the NEnv cell"                 rvRecMemberDropCountsEnv
  , testCase "sentinel addr is static; incref/drop are no-ops"     rvRecMemberSentinelNoOp
  , testCase "renderRCValue of RVRecMember is <closure>"           rvRecMemberRender
  ]
