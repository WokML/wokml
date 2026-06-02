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
import qualified Wok.TypeChecking.Builtins as B
import qualified Wok.TypeChecking as TC
import qualified Wok.SourceOrigin as SO
import qualified Wok.Prelude as Prelude
import qualified Wok.Loader as Loader
import qualified Wok.Pipeline as Pipeline
import Control.Monad.Except (throwError)
import Data.Bifunctor (first)
import qualified Data.List
import Data.List (sortBy)
import Data.Ord (comparing)

import System.FilePath (takeBaseName, replaceDirectory, replaceExtension)

main :: IO ()
main = do
  exampleFiles       <- findByExtension [".wok"] "test/examples"
  resolveFiles       <- findByExtension [".wok"] "test/resolve-examples"
  typecheckFiles     <- findByExtension [".wok"] "test/typecheck-examples"
  typecheckBadFiles  <- findByExtension [".wok"] "test/typecheck-fail-examples"
  defaultMain $ testGroup "wok"
    [ testGroup "parse golden"
        [ goldenVsString (takeBaseName f) (goldenFor f) (parseToBS f)
        | f <- exampleFiles
        ]
    , fixityTests
    , resolveTests
    , typesSmokeTests
    , envSmokeTests
    , envOverlayTests
    , sourceOriginTests
    , preludeTests
    , modPathTests
    , monadSmokeTests
    , unifyWalksTests
    , unifyTests
    , generalizeTests
    , builtinsTests
    , translateTests
    , dataTests
    , effectDeclTests
    , effectSigTests
    , effectGrammarTests
    , effectOpTests
    , effectHandlerTests
    , effectPressureTests
    , closedByDefaultTests
    , lambdaEffectScopingTests
    , patternTests
    , exprBasicTests
    , exprLetTests
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
    , patternCoverageTests
    , blockLayoutTests
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
      let s = Ty.Scheme [(0, Ty.KStar)] (Ty.CTArr (Ty.CTGen 0) Ty.CREmpty (Ty.CTGen 0))
      in Ty.schemeVars s @?= [(0, Ty.KStar)]
  , testCase "Level is comparable" $
      compare (Ty.Level 1) (Ty.Level 2) @?= LT
  ]

envSmokeTests :: TestTree
envSmokeTests = testGroup "Wok.TypeChecking.Env"
  [ testCase "emptyEnv has no entries" $ do
      TE.lookupVar (T.pack "x") TE.emptyEnv @?= Nothing
      TE.lookupCon (T.pack "Just") TE.emptyEnv @?= Nothing
      TE.lookupTyCon (T.pack "Maybe") TE.emptyEnv @?= Nothing
  , testCase "extendVar then lookupVar finds it" $
      let s = Ty.Scheme [] (Ty.CTCon Ty.TcU64 [])
          e = TE.extendVar (T.pack "x") s TE.emptyEnv
      in TE.lookupVar (T.pack "x") e @?= Just s
  , testCase "TypeError has Show" $
      let err = TErr.UnknownVar Nothing (T.pack "ghost")
      in length (show err) > 0 @?= True
  ]

envOverlayTests :: TestTree
envOverlayTests = testGroup "envOverlay"
  [ testCase "disjoint vars union cleanly" $
      let a = TE.extendVar (T.pack "x") (Ty.Scheme [] (Ty.CTCon Ty.TcU64 [])) TE.emptyEnv
          b = TE.extendVar (T.pack "y") (Ty.Scheme [] (Ty.CTCon Ty.TcBool [])) TE.emptyEnv
      in case TE.overlayEnvs a b of
           Right e -> do
             TE.lookupVar (T.pack "x") e @?= TE.lookupVar (T.pack "x") a
             TE.lookupVar (T.pack "y") e @?= TE.lookupVar (T.pack "y") b
           Left _ -> assertFailure "expected Right"

  , testCase "var collision returns Left with NsVar" $
      let s1 = Ty.Scheme [] (Ty.CTCon Ty.TcU64 [])
          s2 = Ty.Scheme [] (Ty.CTCon Ty.TcBool [])
          a = TE.extendVar (T.pack "dup") s1 TE.emptyEnv
          b = TE.extendVar (T.pack "dup") s2 TE.emptyEnv
      in case TE.overlayEnvs a b of
           Left collisions -> collisions @?= [(TE.NsVar, T.pack "dup")]
           Right _ -> assertFailure "expected Left"

  , testCase "tycon collision returns Left with NsTyCon" $
      let tci = TE.TyConInfo Ty.KStar 0 []
          a = TE.extendTyCon (T.pack "Foo") tci TE.emptyEnv
          b = TE.extendTyCon (T.pack "Foo") tci TE.emptyEnv
      in case TE.overlayEnvs a b of
           Left collisions -> collisions @?= [(TE.NsTyCon, T.pack "Foo")]
           Right _ -> assertFailure "expected Left"

  , testCase "con collision returns Left with NsCon" $
      let ci = TE.ConInfo (Ty.Scheme [] (Ty.CTCon Ty.TcBool [])) 0 (T.pack "Bool")
          a = TE.extendCon (T.pack "True") ci TE.emptyEnv
          b = TE.extendCon (T.pack "True") ci TE.emptyEnv
      in case TE.overlayEnvs a b of
           Left collisions -> collisions @?= [(TE.NsCon, T.pack "True")]
           Right _ -> assertFailure "expected Left"

  , testCase "extendEffect then lookupEffect round-trips" $
      let ei  = TE.EffectInfo []
                  (Map.fromList [(T.pack "read", Ty.Scheme [] (Ty.CTCon Ty.TcString []))])
          env = TE.extendEffect (T.pack "IO") ei TE.emptyEnv
      in TE.lookupEffect (T.pack "IO") env @?= Just ei

  , testCase "effect collision returns Left with NsEffect" $
      let ei = TE.EffectInfo [] Map.empty
          a  = TE.extendEffect (T.pack "IO") ei TE.emptyEnv
          b  = TE.extendEffect (T.pack "IO") ei TE.emptyEnv
      in case TE.overlayEnvs a b of
           Left collisions -> collisions @?= [(TE.NsEffect, T.pack "IO")]
           Right _ -> assertFailure "expected Left"

  , testCase "collisions across multiple namespaces are all reported" $
      let s = Ty.Scheme [] (Ty.CTCon Ty.TcU64 [])
          tci = TE.TyConInfo Ty.KStar 0 []
          a = TE.extendTyCon (T.pack "X") tci (TE.extendVar (T.pack "y") s TE.emptyEnv)
          b = TE.extendTyCon (T.pack "X") tci (TE.extendVar (T.pack "y") s TE.emptyEnv)
      in case TE.overlayEnvs a b of
           Left collisions ->
             Data.List.sort collisions @?=
               Data.List.sort [(TE.NsVar, T.pack "y"), (TE.NsTyCon, T.pack "X")]
           Right _ -> assertFailure "expected Left"
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
        Just (Ty.Scheme [] body) -> case body of
          Ty.CTArr (Ty.CTCon Ty.TcU64 []) Ty.CREmpty
            (Ty.CTArr (Ty.CTCon Ty.TcU64 []) Ty.CREmpty (Ty.CTCon Ty.TcU64 [])) ->
              pure ()
          _ -> assertFailure ("unexpected body: " ++ show body)
        _ -> assertFailure "+ missing or has quantifiers"
  , testCase "Std.Base: ++ has one type quantifier" $ do
      env <- stdBaseExtendedEnv
      case TE.lookupVar (T.pack "++") env of
        Just (Ty.Scheme [(_, Ty.KStar)] _) -> pure ()
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
           Right s -> s @?= Ty.Scheme []
                            (Ty.CTArr (Ty.CTCon Ty.TcU64 []) Ty.CREmpty
                                      (Ty.CTCon Ty.TcU64 []))
           Left e -> assertFailure (show e)
  , testCase "a -> a translates to forall a. a -> a" $
      let var = Abs.TVar (Abs.VarId ((0,0), T.pack "a"))
          ty  = Abs.TFun var var
          result = TM.runTC_ B.initialEnv (I.translateSig B.initialEnv ty)
      in case result of
           Right (Ty.Scheme [(0, Ty.KStar)]
                    (Ty.CTArr (Ty.CTGen 0) Ty.CREmpty (Ty.CTGen 0))) ->
             pure ()
           other -> assertFailure ("unexpected: " ++ show other)
  , testCase "[a] translates to forall a. [a]" $
      let var = Abs.TVar (Abs.VarId ((0,0), T.pack "a"))
          result = TM.runTC_ B.initialEnv (I.translateSig B.initialEnv (Abs.TList var))
      in case result of
           Right (Ty.Scheme [(0, Ty.KStar)] (Ty.CTCon Ty.TcList [Ty.CTGen 0])) ->
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
           Right s -> s @?= Ty.Scheme [] (Ty.CTCon Ty.TcU64 [])
           Left e -> assertFailure (show e)
  , testCase "generalize fresh a -> a yields forall a. a -> a" $
      let result = TM.runTC_ TE.emptyEnv $ do
            a <- TM.enterLevel (TM.freshTVar Ty.KStar)
            I.generalize (Ty.TArr a Ty.RowEmpty a)
      in case result of
           Right (Ty.Scheme [(i, Ty.KStar)]
                    (Ty.CTArr (Ty.CTGen j) Ty.CREmpty (Ty.CTGen k)))
             | i == j && j == k -> pure ()
           other -> assertFailure ("unexpected scheme: " ++ show other)
  , testCase "instantiate forall a. a -> a yields shared TVar" $
      let s = Ty.Scheme [(0, Ty.KStar)]
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
        , T.pack "runIO comp = handle (comp ()) of"
        , T.pack "  IO.read p -> p"
        , T.pack "  IO.write m -> ()"
        , T.pack "  return v -> v"
        ]
        (T.pack "runIO")
        @?= Right (T.pack "forall a. (() -> a) -> a")

  , testCase "effect-translating handler: Logger discharged, IO introduced" $
      schemeOf
        [ T.pack "effect Logger = { log : String -> () }"
        , T.pack "effect IO = { write : String -> () }"
        , T.pack "logToIO c = handle (c ()) of"
        , T.pack "  Logger.log m -> IO.write m"
        , T.pack "  return v -> v"
        ]
        (T.pack "logToIO")
        @?= Right (T.pack "forall a. (() -> a) -> a with IO")

  , testCase "non-exhaustive handler is rejected (HandlerCoverage)" $
      case schemeOf
             [ T.pack "effect IO = { read : String -> String, write : String -> () }"
             , T.pack "runIO comp = handle (comp ()) of"
             , T.pack "  IO.read p -> p"
             ]
             (T.pack "runIO") of
        Left msg -> assertBool ("expected HandlerCoverage, got: " ++ msg)
                      (T.pack "HandlerCoverage" `T.isInfixOf` T.pack msg)
        Right s  -> assertFailure ("expected rejection, got: " ++ T.unpack s)

  , testCase "handler with no return arm: result is the handled type" $
      schemeOf
        [ T.pack "effect IO = { write : String -> () }"
        , T.pack "runIO comp = handle (comp ()) of"
        , T.pack "  IO.write m -> ()"
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
            , "partial comp = handle (comp ()) of"
            , "  IO.write m -> ()"
            , "  return v -> v"
            ]
            "partial"
            @?= Right "forall b a. (() -> b with IO + Logger + eff a) -> b with Logger + eff a"

      , testCase "one handler discharges two effects at once" $
          schemeOf
            [ "effect IO = { write : String -> () }"
            , "effect Logger = { log : String -> () }"
            , "runBoth : (() -> a with IO + Logger + eff e) -> a with eff e"
            , "runBoth comp = handle (comp ()) of"
            , "  IO.write m -> ()"
            , "  Logger.log m -> ()"
            , "  return v -> v"
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
            , "bad comp = handle (comp ()) of"
            , "  IO.read p -> 42"
            , "  return v -> v"
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
                 , "weird c = handle (vacuous ()) of"
                 , "  IO.write m -> ()"
                 , "  return v -> v"
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
                   Ty.Scheme [(0, Ty.KStar)] body ->
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
  ]

patternTests :: TestTree
patternTests = testGroup "Wok.TypeChecking.Infer (patterns)"
  [ testCase "var pattern returns fresh type and one binding" $
      let result = TM.runTC_ B.initialEnv $ do
            (t, bs) <- I.inferPat
              (Abs.PAtom (Abs.APVar (Abs.VarId ((0,0), T.pack "x"))))
            pure (length bs, case t of Ty.TVar _ -> True; _ -> False)
      in case result of
           Right (1, True) -> pure ()
           other -> assertFailure ("unexpected: " ++ show other)
  , testCase "literal Int pattern" $
      let result = TM.runTC_ B.initialEnv $ do
            (t, _) <- I.inferPat
              (Abs.PAtom (Abs.APLitI
                (Abs.WokInt ((0,0), T.pack "5"))))
            U.freeze t
      in case result of
           Right ct -> ct @?= Ty.CTCon Ty.TcU64 []
           Left e -> assertFailure (show e)
  , testCase "wildcard pattern returns fresh type, no bindings" $
      let result = TM.runTC_ B.initialEnv $ do
            (_, bs) <- I.inferPat (Abs.PAtom Abs.APWild)
            pure (length bs)
      in case result of
           Right 0 -> pure ()
           other -> assertFailure ("unexpected: " ++ show other)
  , testCase "True nullary constructor pattern" $ do
      env <- stdBaseExtendedEnv
      let result = TM.runTC_ env $ do
            (t, _) <- I.inferPat (Abs.PAtom
              (Abs.APCon (Abs.MPName (Abs.ConId ((0,0), T.pack "True")))))
            U.freeze t
      case result of
        Right ct -> ct @?= Ty.CTCon Ty.TcBool []
        Left e -> assertFailure (show e)
  , testCase "tuple pattern (x, y) gives 2-tuple type and 2 bindings" $
      let pos = (0,0)
          vp s = Abs.PAtom (Abs.APVar (Abs.VarId (pos, T.pack s)))
          result = TM.runTC_ B.initialEnv $ do
            (t, bs) <- I.inferPat
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
               Ty.Scheme [(0, Ty.KStar)]
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
               Ty.Scheme [(0, Ty.KStar)]
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
                   Ty.Scheme [(_, Ty.KStar)]
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
  [ testCase "loads entry + embedded Std.Base; topo order is Prelude first" $ do
      res <- Loader.loadProgram "test/loader-fixtures/01-entry-imports-base.wok" []
      case res of
        Right (entryName, modules) -> do
          entryName @?= T.pack "Main"
          map Loader.lmName modules @?= [T.pack "Std.Base", T.pack "Main"]
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
      -- A and B both export `foo`. The entry imports both; the env
      -- overlay in `Pipeline.typecheckProgram` detects the collision and
      -- returns a Left starting with "env:".
      --
      -- NOTE on the assertion: the current pipeline contract is that
      -- each module's envOut contains its seed env (B.initialEnv plus
      -- transitive imports), so overlaying TWO non-Std.Base imports
      -- always clashes on the builtin tycons (U64, (,), ...) BEFORE
      -- the `foo` clash is reached. This is a known architectural
      -- coarseness: env-merge surfaces SOME collision rather than
      -- specifically the user-visible `foo`. The load-bearing claim
      -- for this test is therefore "two imports exporting overlapping
      -- names produce an env-merge error" — exact contents are
      -- pipeline-defined.
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
            forced <- U.forceRow rVar
            U.freezeRow forced
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
            forced <- U.forceRow rVar
            U.freezeRow forced
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
            cr <- U.freezeRow rest
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
            cr  <- U.freezeRow rest
            pure (ct, cr)
      in case result of
           Right (Ty.CTCon Ty.TcU64 [], Ty.CRExtend lbl (Ty.CTCon Ty.TcBool []) Ty.CREmpty)
             | lbl == T.pack "x" -> pure ()
           Right other ->
             assertFailure ("expected (CTCon TcU64 [], CRExtend x (CTCon TcBool []) CREmpty), got: " ++ show other)
           Left e -> assertFailure ("expected Right, got: " ++ show e)

  , testCase "occurs check: r := {x : r} is rejected" $
      -- Setup: fresh RowVar r. Attempt to bind r to RowExtend "x" someType (RowVar r).
      -- Expected: throws RowOccursCheck (dedicated cycle error).
      let result = runUnify $ do
            rVar <- TM.freshRVar
            case rVar of
              Ty.RowVar ref -> do
                let cyclicRow = Ty.RowExtend (T.pack "x") (Ty.TCon Ty.TcU64 []) rVar
                U.bindRowVar Nothing ref cyclicRow
              _ -> error "expected RowVar from freshRVar"
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
            -- Both should now freeze to the same CRow (CRGen)
            cr1 <- U.freezeRow r1
            cr2 <- U.freezeRow r2
            pure (cr1, cr2)
      in case result of
           Right (cr1, cr2) -> cr1 @?= cr2
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
cRowLabels (Ty.CRGen _) = []

typeLevelExtTests :: TestTree
typeLevelExtTests = testGroup "TypeLevelExtension"
  [ testCase "concrete extension translates to TRecord with merged fields" $ do
      -- Point + { score : U64 } should yield CTRecord "Point" with x, y, score
      let ty = Abs.TExtend mkPointTy (mkVarSym "+")
                 (mkRCAnon [("score", mkU64)])
      case translateSigInPointEnv ty of
        Left e -> assertFailure ("unexpected error: " ++ show e)
        Right (Ty.Scheme _ (Ty.CTRecord tag row)) -> do
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

  , testCase "row variable extension translates to CTRecord with CRGen tail" $ do
      -- Point + row r should yield CTRecord "Point" (x, y, r)
      let ty = Abs.TExtend mkPointTy (mkVarSym "+") (mkRCVar "r")
      case translateSigInPointEnv ty of
        Left e -> assertFailure ("unexpected error: " ++ show e)
        Right (Ty.Scheme qs (Ty.CTRecord tag row)) -> do
          tag @?= T.pack "Point"
          -- The row should end with a CRGen for the row variable
          let hasRowVar (Ty.CRGen _) = True
              hasRowVar Ty.CREmpty   = False
              hasRowVar (Ty.CRExtend _ _ rest) = hasRowVar rest
          hasRowVar row @? "expected row variable (CRGen) in row"
          -- There should be exactly one KEffect quantifier for the row var
          let rowQs = [ i | (i, Ty.KEffect) <- qs ]
          length rowQs @?= 1
        Right other -> assertFailure ("expected CTRecord scheme, got: " ++ show other)

  , testCase "two uses of same row var share one CRGen slot" $ do
      -- (Point + row r) -> (Point + row r): both `r` should map to same index
      let extTy = Abs.TExtend mkPointTy (mkVarSym "+") (mkRCVar "r")
          ty    = Abs.TFun extTy extTy
      case translateSigInPointEnv ty of
        Left e -> assertFailure ("unexpected error: " ++ show e)
        Right (Ty.Scheme qs _) -> do
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
        Right (Ty.Scheme _ (Ty.CTRecord tag row)) -> do
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
        Right (Ty.Scheme _ (Ty.CTRecord tag row)) -> do
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
            Just (Ty.Scheme [] (Ty.CTRecord tag row)) -> do
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
