{-# LANGUAGE OverloadedStrings #-}
module Main where

import Test.Tasty
import Test.Tasty.Golden (goldenVsString, findByExtension)
import Test.Tasty.HUnit

import qualified Data.ByteString.Lazy.Char8 as BL
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
import Control.Monad.Except (throwError)
import Data.Bifunctor (first)
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
    , monadSmokeTests
    , unifyWalksTests
    , unifyTests
    , generalizeTests
    , builtinsTests
    , translateTests
    , dataTests
    , patternTests
    , exprBasicTests
    , exprLetTests
    , programTests
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
  src <- TIO.readFile path
  case pipeline src of
    Left err -> pure (BL.pack err)
    Right (_, decls) -> do
      let sorted = sortBy (comparing TC.tdName) decls
          ls = [ T.unpack (TC.tdName d <> T.pack " : " <> TC.prettyScheme (TC.tdScheme d))
               | d <- sorted ]
      pure (BL.pack (unlines ls))
  where
    pipeline src = do
      p <- first ("parse: " ++) (parse src)
      r <- first (("reorder: " ++) . show) (reorderModule p)
      first (("typecheck: " ++) . show) (TC.inferProgram (reorderedAst r))

typecheckFailHarness :: FilePath -> IO BL.ByteString
typecheckFailHarness path = do
  src <- TIO.readFile path
  case pipeline src of
    Left err -> pure (BL.pack (err ++ "\n"))
    Right _  -> pure (BL.pack "UNEXPECTED SUCCESS\n")
  where
    pipeline src = do
      p <- first ("parse: " ++) (parse src)
      r <- first (("reorder: " ++) . show) (reorderModule p)
      first (("typecheck: " ++) . show) (TC.inferProgram (reorderedAst r))

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
      Ty.TcInt @?= Ty.TcInt
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
      let s = Ty.Scheme [] (Ty.CTCon Ty.TcInt [])
          e = TE.extendVar (T.pack "x") s TE.emptyEnv
      in TE.lookupVar (T.pack "x") e @?= Just s
  , testCase "TypeError has Show" $
      let err = TErr.UnknownVar Nothing (T.pack "ghost")
      in length (show err) > 0 @?= True
  ]

monadSmokeTests :: TestTree
monadSmokeTests = testGroup "Wok.TypeChecking.Monad"
  [ testCase "freshUniq returns increasing values" $
      let result = TM.runTC TE.emptyEnv $ do
            a <- TM.freshUniq
            b <- TM.freshUniq
            c <- TM.freshUniq
            pure (a, b, c)
      in case result of
           Right t -> t @?= (0, 1, 2)
           Left e  -> assertFailure (show e)
  , testCase "enterLevel bumps then restores" $
      let result = TM.runTC TE.emptyEnv $ do
            l0 <- TM.currentLevel
            l1 <- TM.enterLevel TM.currentLevel
            l2 <- TM.currentLevel
            pure (l0, l1, l2)
      in case result of
           Right t -> t @?= (Ty.Level 0, Ty.Level 1, Ty.Level 0)
           Left e  -> assertFailure (show e)
  , testCase "freshTVar runs without error" $
      let result = TM.runTC TE.emptyEnv $ do
            _ <- TM.enterLevel (TM.freshTVar Ty.KStar)
            pure ()
      in case result of
           Right () -> pure ()
           Left e -> assertFailure (show e)
  , testCase "throwError caught as Left" $
      let result :: Either TErr.TypeError ()
          result = TM.runTC TE.emptyEnv $
            throwError (TErr.UnknownVar Nothing (T.pack "x"))
      in case result of
           Left (TErr.UnknownVar _ _) -> pure ()
           _ -> assertFailure "expected UnknownVar"
  ]

unifyWalksTests :: TestTree
unifyWalksTests = testGroup "Wok.TypeChecking.Unify (walks)"
  [ testCase "freeze TCon Int" $
      let result = TM.runTC TE.emptyEnv $
            U.freeze (Ty.TCon Ty.TcInt [])
      in case result of
           Right ct -> ct @?= Ty.CTCon Ty.TcInt []
           Left e   -> assertFailure ("expected Right, got: " ++ show e)
  , testCase "freeze fresh TVar produces CTGen" $
      let result = TM.runTC TE.emptyEnv $ do
            t <- TM.freshTVar Ty.KStar
            U.freeze t
      in case result of
           Right (Ty.CTGen _) -> pure ()
           _ -> assertFailure ("expected CTGen, got " ++ show result)
  , testCase "occursAdjust fires when target appears" $
      let result = TM.runTC TE.emptyEnv $ do
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
      let result = TM.runTC TE.emptyEnv $
            U.unify Nothing (Ty.TCon Ty.TcInt []) (Ty.TCon Ty.TcInt [])
      in case result of
           Right () -> pure ()
           Left e -> assertFailure (show e)
  , testCase "mismatched TCons fail" $
      let result = TM.runTC TE.emptyEnv $
            U.unify Nothing (Ty.TCon Ty.TcInt []) (Ty.TCon Ty.TcBool [])
      in case result of
           Left (TErr.Mismatch _ _ _) -> pure ()
           _ -> assertFailure
                  ("expected Mismatch, got "
                  ++ either show (const "Right ()") result)
  , testCase "fresh TVar unifies with concrete type" $
      let result = TM.runTC TE.emptyEnv $ do
            a <- TM.freshTVar Ty.KStar
            U.unify Nothing a (Ty.TCon Ty.TcInt [])
            U.freeze a
      in case result of
           Right ct -> ct @?= Ty.CTCon Ty.TcInt []
           Left e -> assertFailure (show e)
  , testCase "TArr unifies (with empty effect row)" $
      let result = TM.runTC TE.emptyEnv $ do
            a <- TM.freshTVar Ty.KStar
            U.unify Nothing
              (Ty.TArr a Ty.RowEmpty (Ty.TCon Ty.TcBool []))
              (Ty.TArr (Ty.TCon Ty.TcInt []) Ty.RowEmpty (Ty.TCon Ty.TcBool []))
            U.freeze a
      in case result of
           Right ct -> ct @?= Ty.CTCon Ty.TcInt []
           Left e -> assertFailure (show e)
  , testCase "occurs check fires (a ~ List a)" $
      let result = TM.runTC TE.emptyEnv $ do
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
builtinsTests = testGroup "Wok.TypeChecking.Builtins"
  [ testCase "Bool, Int, list registered" $ do
      case TE.lookupTyCon (T.pack "Bool") B.initialEnv of
        Just info -> do
          TE.tcArity info @?= 0
          TE.tcCons info @?= [T.pack "True", T.pack "False"]
        Nothing -> assertFailure "Bool missing"
      case TE.lookupTyCon (T.pack "Int") B.initialEnv of
        Just info -> TE.tcKind info @?= Ty.KStar
        Nothing -> assertFailure "Int missing"
      case TE.lookupTyCon (T.pack "[]") B.initialEnv of
        Just info -> TE.tcArity info @?= 1
        Nothing -> assertFailure "list missing"
  , testCase "True and False are constructors of Bool" $
      case TE.lookupCon (T.pack "True") B.initialEnv of
        Just info -> TE.conTyCon info @?= T.pack "Bool"
        Nothing -> assertFailure "True missing"
  , testCase "+ has scheme Int -> Int -> Int" $
      case TE.lookupVar (T.pack "+") B.initialEnv of
        Just (Ty.Scheme [] body) -> case body of
          Ty.CTArr (Ty.CTCon Ty.TcInt []) Ty.CREmpty
            (Ty.CTArr (Ty.CTCon Ty.TcInt []) Ty.CREmpty (Ty.CTCon Ty.TcInt [])) ->
              pure ()
          _ -> assertFailure ("unexpected body: " ++ show body)
        _ -> assertFailure "+ missing or has quantifiers"
  , testCase "++ has scheme forall a. [a] -> [a] -> [a]" $
      case TE.lookupVar (T.pack "++") B.initialEnv of
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
  [ testCase "Int -> Int translates to monotype" $
      let int = Abs.TCon (Abs.MPName (Abs.ConId ((0,0), T.pack "Int")))
          ty  = Abs.TFun int int
          result = TM.runTC B.initialEnv (I.translateSig B.initialEnv ty)
      in case result of
           Right s -> s @?= Ty.Scheme []
                            (Ty.CTArr (Ty.CTCon Ty.TcInt []) Ty.CREmpty
                                      (Ty.CTCon Ty.TcInt []))
           Left e -> assertFailure (show e)
  , testCase "a -> a translates to forall a. a -> a" $
      let var = Abs.TVar (Abs.VarId ((0,0), T.pack "a"))
          ty  = Abs.TFun var var
          result = TM.runTC B.initialEnv (I.translateSig B.initialEnv ty)
      in case result of
           Right (Ty.Scheme [(0, Ty.KStar)]
                    (Ty.CTArr (Ty.CTGen 0) Ty.CREmpty (Ty.CTGen 0))) ->
             pure ()
           other -> assertFailure ("unexpected: " ++ show other)
  , testCase "[a] translates to forall a. [a]" $
      let var = Abs.TVar (Abs.VarId ((0,0), T.pack "a"))
          result = TM.runTC B.initialEnv (I.translateSig B.initialEnv (Abs.TList var))
      in case result of
           Right (Ty.Scheme [(0, Ty.KStar)] (Ty.CTCon Ty.TcList [Ty.CTGen 0])) ->
             pure ()
           other -> assertFailure ("unexpected: " ++ show other)
  , testCase "unknown tycon errors" $
      let unk = Abs.TCon (Abs.MPName (Abs.ConId ((0,0), T.pack "Frob")))
          result = TM.runTC B.initialEnv (I.translateSig B.initialEnv unk)
      in case result of
           Left (TErr.UnknownTyCon _ _) -> pure ()
           _ -> assertFailure ("expected UnknownTyCon, got "
                              ++ either show (const "Right") result)
  ]

generalizeTests :: TestTree
generalizeTests = testGroup "Wok.TypeChecking.Infer (generalize/instantiate)"
  [ testCase "generalize Int yields no quantifiers" $
      let result = TM.runTC TE.emptyEnv $
            I.generalize (Ty.TCon Ty.TcInt [])
      in case result of
           Right s -> s @?= Ty.Scheme [] (Ty.CTCon Ty.TcInt [])
           Left e -> assertFailure (show e)
  , testCase "generalize fresh a -> a yields forall a. a -> a" $
      let result = TM.runTC TE.emptyEnv $ do
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
          result = TM.runTC TE.emptyEnv $ do
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
          result = TM.runTC B.initialEnv $
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
  , testCase "duplicate tycon (vs builtin Bool) errors" $
      let pos = (0,0)
          vc s = Abs.ConId (pos, T.pack s)
          decl = Abs.DData (vc "Bool") [] []
          result = TM.runTC B.initialEnv $
                     I.processDataDecls B.initialEnv [decl]
      in case result of
           Left (TErr.DuplicateTyCon _ _) -> pure ()
           _ -> assertFailure
                  ("expected DuplicateTyCon, got "
                  ++ either show (const "Right") result)
  ]

patternTests :: TestTree
patternTests = testGroup "Wok.TypeChecking.Infer (patterns)"
  [ testCase "var pattern returns fresh type and one binding" $
      let result = TM.runTC B.initialEnv $ do
            (t, bs) <- I.inferPat
              (Abs.PAtom (Abs.APVar (Abs.VarId ((0,0), T.pack "x"))))
            pure (length bs, case t of Ty.TVar _ -> True; _ -> False)
      in case result of
           Right (1, True) -> pure ()
           other -> assertFailure ("unexpected: " ++ show other)
  , testCase "literal Int pattern" $
      let result = TM.runTC B.initialEnv $ do
            (t, _) <- I.inferPat
              (Abs.PAtom (Abs.APLitI
                (Abs.WokInt ((0,0), T.pack "5"))))
            U.freeze t
      in case result of
           Right ct -> ct @?= Ty.CTCon Ty.TcInt []
           Left e -> assertFailure (show e)
  , testCase "wildcard pattern returns fresh type, no bindings" $
      let result = TM.runTC B.initialEnv $ do
            (_, bs) <- I.inferPat (Abs.PAtom Abs.APWild)
            pure (length bs)
      in case result of
           Right 0 -> pure ()
           other -> assertFailure ("unexpected: " ++ show other)
  , testCase "True nullary constructor pattern" $
      let result = TM.runTC B.initialEnv $ do
            (t, _) <- I.inferPat (Abs.PAtom
              (Abs.APCon (Abs.MPName (Abs.ConId ((0,0), T.pack "True")))))
            U.freeze t
      in case result of
           Right ct -> ct @?= Ty.CTCon Ty.TcBool []
           Left e -> assertFailure (show e)
  , testCase "tuple pattern (x, y) gives 2-tuple type and 2 bindings" $
      let pos = (0,0)
          vp s = Abs.PAtom (Abs.APVar (Abs.VarId (pos, T.pack s)))
          result = TM.runTC B.initialEnv $ do
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
      let result = TM.runTC B.initialEnv $ do
            t <- I.inferExpr (Abs.ELitI (Abs.WokInt ((0,0), T.pack "42")))
            U.freeze t
      in case result of
           Right ct -> ct @?= Ty.CTCon Ty.TcInt []
           Left e -> assertFailure (show e)
  , testCase "if True then 1 else 2 : Int" $
      let true = Abs.ECon (Abs.ConId ((0,0), T.pack "True"))
          mkI s = Abs.ELitI (Abs.WokInt ((0,0), T.pack s))
          result = TM.runTC B.initialEnv $ do
            t <- I.inferExpr (Abs.EIf true (mkI "1") (mkI "2"))
            U.freeze t
      in case result of
           Right ct -> ct @?= Ty.CTCon Ty.TcInt []
           Left e -> assertFailure (show e)
  , testCase "(+) 1 2 : Int" $
      let plus = Abs.EParenOp (Abs.VarSym ((0,0), T.pack "+"))
          mkI s = Abs.ELitI (Abs.WokInt ((0,0), T.pack s))
          result = TM.runTC B.initialEnv $ do
            t <- I.inferExpr (Abs.EApp (Abs.EApp plus (mkI "1")) (mkI "2"))
            U.freeze t
      in case result of
           Right ct -> ct @?= Ty.CTCon Ty.TcInt []
           Left e -> assertFailure (show e)
  , testCase "\\x -> x : a -> a" $
      let lam = Abs.ELam [Abs.APVar (Abs.VarId ((0,0), T.pack "x"))]
                  (Abs.EVar (Abs.VarId ((0,0), T.pack "x")))
          result = TM.runTC B.initialEnv $ do
            t <- I.inferExpr lam
            U.freeze t
      in case result of
           Right (Ty.CTArr (Ty.CTGen i) Ty.CREmpty (Ty.CTGen j)) | i == j -> pure ()
           other -> assertFailure ("unexpected: " ++ show other)
  , testCase "EProj fails as unsupported" $
      let proj = Abs.EProj (Abs.EVar (Abs.VarId ((0,0), T.pack "x")))
                   (Abs.VarId ((0,0), T.pack "y"))
          result = TM.runTC B.initialEnv
                     (I.inferExpr proj >>= \t -> U.freeze t)
      in case result of
           Left (TErr.UnsupportedFeature _ _) -> pure ()
           _ -> assertFailure
                  ("expected UnsupportedFeature, got "
                  ++ either show (const "Right") result)
  ]

exprLetTests :: TestTree
exprLetTests = testGroup "ExprLet"
  [ testCase "let id = \\x -> x in (id 1, id True) : (Int, Bool)" $
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
          result = TM.runTC B.initialEnv $ do
            t <- I.inferExpr (Abs.ELet [ldId] body)
            U.freeze t
      in case result of
           Right ct -> ct @?= Ty.CTCon (Ty.TcTuple 2)
                              [Ty.CTCon Ty.TcInt [], Ty.CTCon Ty.TcBool []]
           Left e -> assertFailure (show e)
  , testCase "case True of True -> 1; False -> 0 : Int" $
      let pos = (0,0)
          c s  = Abs.ConId (pos, T.pack s)
          mkI s = Abs.ELitI (Abs.WokInt (pos, T.pack s))
          true = Abs.ECon (c "True")
          altT = Abs.AltC (Abs.PAtom (Abs.APCon (Abs.MPName (c "True"))))
                          (mkI "1") Abs.NoWhere
          altF = Abs.AltC (Abs.PAtom (Abs.APCon (Abs.MPName (c "False"))))
                          (mkI "0") Abs.NoWhere
          result = TM.runTC B.initialEnv $ do
            t <- I.inferExpr (Abs.ECase true [altT, altF])
            U.freeze t
      in case result of
           Right ct -> ct @?= Ty.CTCon Ty.TcInt []
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
