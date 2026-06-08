# One-shot Multiplicity Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an affine (no-dup) analysis on continuation binders over `Wok.IR.Anf` that infers a `{0,1,ω}` resume-count per handler arm and rejects multi-shot (`ω`) handlers as a compile error.

**Architecture:** One new pure module `Wok.IR.Multiplicity` holds the `{0,1,ω}` cardinality lattice and a type-free structural walk `cardOf` over `Expr`, keyed on the resume binder's `Name`. A module-level traversal flags any arm whose continuation card is `Many`. The error is wired into the `--run` pipeline (multi-shot programs no longer run) and surfaced via a dedicated golden group; a `--dump-multiplicity` mode prints the inferred number per arm as the proof artifact. No grammar, type-system, or interpreter change.

**Tech Stack:** Haskell (GHC, cabal), `containers`, `text`; tasty + tasty-hunit (unit) + tasty-golden (golden) for tests.

**Design source:** `docs/superpowers/specs/2026-06-09-one-shot-multiplicity-analysis-design.md`.

**Deferred (NOT in this plan, per spec §4):** the value restriction (dropped as unnecessary), `opMultiplicity`/`once` surface (slice 4b), cancellation, interprocedural summaries, and the optional debug-only single-use `VCont` runtime oracle (spec §9 — documented there, intentionally omitted here to keep the slice to analysis + consumer).

---

### Task 1: The `Card` lattice + `cardOf` per-arm analysis

**Goal:** A pure module computing, for a resume binder `r` and an arm body `Expr`, an upper bound in `{Zero,One,Many}` on how many times `r` is invoked — the substance of the slice. Front-loaded (riskiest), TDD.

**Files:**
- Create: `src/Wok/IR/Multiplicity.hs`
- Modify: `wok.cabal:97` (add `Wok.IR.Multiplicity` to library `exposed-modules`, after `Wok.IR.Match`)
- Modify: `test/Spec.hs` (add unit-test group; wire into `defaultMain`)

**Acceptance Criteria:**
- [ ] `cardOf` returns `One` for a single direct resume, `Many` for two sequenced resumes or `+`-combined resumes, `One` for resumes in distinct `Case` arms, `Zero` for a dropped continuation.
- [ ] Every escape (continuation returned, passed to a call, captured in a closure/`RCon`/`ROp`, used as a scrutinee) yields `Many`.
- [ ] `LetRec`/`Handle`-arm capture and unknown/recursive `Jump` targets yield `Many`.
- [ ] Lattice laws hold: `addC One One == Many`, `addC Zero x == x`, `joinC One One == One`, `joinC Zero Many == Many`.

**Verify:** `cabal test 2>&1 | grep -i multiplicity` → the `multiplicity (unit)` group passes; `cabal test` stays green (629 + new).

**Steps:**

- [ ] **Step 1: Write the module with the lattice and walk (this is the failing target — tests come next)**

Create `src/Wok/IR/Multiplicity.hs`:

```haskell
module Wok.IR.Multiplicity
  ( Card (..)
  , joinC
  , addC
  , cardOf
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Wok.IR.Name (Name, JoinId, nameUniq)
import Wok.IR.Anf

-- | The {0,1,ω} cardinality lattice on continuation use. Zero <= One <= Many.
data Card = Zero | One | Many
  deriving (Eq, Show)

-- | Branch combinator (⊔): only one path runs, so take the max on the chain.
joinC :: Card -> Card -> Card
joinC a b = case (a, b) of
  (Many, _) -> Many
  (_, Many) -> Many
  (One, _)  -> One
  (_, One)  -> One
  _         -> Zero

-- | Sequence combinator (+): both run; saturating, so two resumes = Many.
addC :: Card -> Card -> Card
addC Zero x = x
addC x Zero = x
addC _ _    = Many

-- | Does the resume binder `r` occur in this atom? (Identity is the Unique.)
mentionsAtom :: Name -> Atom -> Bool
mentionsAtom r (AVar n) = nameUniq n == nameUniq r
mentionsAtom _ (ALit _) = False

mentionsAny :: Name -> [Atom] -> Bool
mentionsAny r = any (mentionsAtom r)

-- | The affine analysis: an upper bound on how many times `r` is invoked in `e`.
-- Type-free; the single soundness rule is that any occurrence of `r` that is NOT
-- the head of a saturated application is an escape and yields Many.
cardOf :: Name -> Expr -> Card
cardOf r = go Map.empty
  where
    go :: Map JoinId Card -> Expr -> Card
    go env e = case e of
      Ret a
        | mentionsAtom r a -> Many          -- continuation returned as a value
        | otherwise        -> Zero
      Let _ rhs b -> addC (cardRhs rhs) (go env b)
      Case a alts
        | mentionsAtom r a -> Many          -- scrutinizing the continuation
        | otherwise        -> foldr (joinC . goAlt env) Zero alts
      LetJoin j _ jb b ->
        -- cj = resumes per jump to j. A recursive jump inside jb sees j NOT yet
        -- in env -> Many (sound; no fixpoint needed).
        let cj = go env jb
        in go (Map.insert j cj env) b
      Jump j as ->
        addC (Map.findWithDefault Many j env)
             (if mentionsAny r as then Many else Zero)
      LetRec defs b ->
        addC (if any (\(_, _, db) -> occursExpr r db) defs then Many else Zero)
             (go env b)
      Handle e' h ->
        addC (go env e')
             (if occursHandlerArms r h then Many else Zero)

    goAlt env (AltCon _ _ b) = go env b
    goAlt env (AltLit _ b)   = go env b
    goAlt env (AltDefault b) = go env b

    cardRhs rhs = case rhs of
      RApp (AVar f) as
        | nameUniq f == nameUniq r ->
            addC One (if mentionsAny r as then Many else Zero)
      RApp _ as        -> if mentionsAny r as then Many else Zero
      RAtom a          -> if mentionsAtom r a then Many else Zero
      RCon _ as        -> if mentionsAny r as then Many else Zero
      RLam _ b         -> if occursExpr r b then Many else Zero
      ROp minst _ _ as -> if maybe False (mentionsAtom r) minst || mentionsAny r as
                            then Many else Zero
      RRecord _ flds   -> if any (mentionsAtom r . snd) flds then Many else Zero
      RProj _ a        -> if mentionsAtom r a then Many else Zero

-- | Conservative "does `r` occur free anywhere in `e`" (shadowing ignored: resume
-- binders are fresh, and a false positive only over-approximates to Many).
occursExpr :: Name -> Expr -> Bool
occursExpr r e = case e of
  Ret a            -> mentionsAtom r a
  Let _ rhs b      -> occursRhs r rhs || occursExpr r b
  LetRec defs b    -> any (\(_, _, db) -> occursExpr r db) defs || occursExpr r b
  Case a alts      -> mentionsAtom r a || any (occursAlt r) alts
  LetJoin _ _ jb b -> occursExpr r jb || occursExpr r b
  Jump _ as        -> mentionsAny r as
  Handle e' h      -> occursExpr r e' || occursHandlerArms r h

occursRhs :: Name -> Rhs -> Bool
occursRhs r rhs = case rhs of
  RAtom a          -> mentionsAtom r a
  RApp f as        -> mentionsAtom r f || mentionsAny r as
  RCon _ as        -> mentionsAny r as
  RLam _ b         -> occursExpr r b
  ROp minst _ _ as -> maybe False (mentionsAtom r) minst || mentionsAny r as
  RRecord _ flds   -> any (mentionsAtom r . snd) flds
  RProj _ a        -> mentionsAtom r a

occursAlt :: Name -> Alt -> Bool
occursAlt r (AltCon _ _ b) = occursExpr r b
occursAlt r (AltLit _ b)   = occursExpr r b
occursAlt r (AltDefault b) = occursExpr r b

occursHandlerArms :: Name -> Handler -> Bool
occursHandlerArms r (Handler (_, re) ops _ _ _) =
  occursExpr r re || any (occursExpr r . oaBody) ops
```

- [ ] **Step 2: Add the cabal exposed-module**

Modify `wok.cabal` — insert after line 97 (`Wok.IR.Match`):

```
        Wok.IR.Multiplicity
```

- [ ] **Step 3: Write failing unit tests**

In `test/Spec.hs`, add imports near the existing IR imports (top of file):

```haskell
import qualified Wok.IR.Multiplicity as Mult
import Wok.IR.Multiplicity (Card (..))
import Wok.IR.Anf
import Wok.IR.Name (Name (..), Unique (..))
import qualified Wok.TypeChecking.Types as Ty
```

Add this test group (place near `fixityTests`):

```haskell
multiplicityUnitTests :: TestTree
multiplicityUnitTests = testGroup "multiplicity (unit)"
  [ testGroup "lattice"
      [ testCase "addC One One = Many"   $ Mult.addC One One   @?= Many
      , testCase "addC Zero One = One"   $ Mult.addC Zero One  @?= One
      , testCase "addC One Many = Many"  $ Mult.addC One Many  @?= Many
      , testCase "joinC One One = One"   $ Mult.joinC One One  @?= One
      , testCase "joinC Zero Many = Many"$ Mult.joinC Zero Many@?= Many
      , testCase "joinC Zero Zero = Zero"$ Mult.joinC Zero Zero@?= Zero
      ]
  , testGroup "cardOf"
      [ testCase "drop (no resume) = Zero" $
          Mult.cardOf kName (Ret unit) @?= Zero
      , testCase "single direct resume = One" $
          Mult.cardOf kName resumeOnce @?= One
      , testCase "two sequenced resumes = Many" $
          Mult.cardOf kName resumeTwiceSeq @?= Many
      , testCase "resume in two case arms = One (branch join)" $
          Mult.cardOf kName resumeInBothArms @?= One
      , testCase "continuation returned = Many (escape)" $
          Mult.cardOf kName (Ret (AVar kName)) @?= Many
      , testCase "continuation passed to a call = Many (escape)" $
          Mult.cardOf kName escapeIntoCall @?= Many
      , testCase "continuation captured in a closure = Many" $
          Mult.cardOf kName escapeIntoLam @?= Many
      , testCase "continuation in LetRec body = Many" $
          Mult.cardOf kName escapeIntoLetRec @?= Many
      ]
  ]
  where
    kName  = Name (T.pack "k") (Unique 1)
    fName  = Name (T.pack "f") (Unique 2)
    ty     = Ty.CTCon Ty.TcUnit []
    bnd n  = Binder n Unrestricted ty
    unit   = ALit LUnit
    -- k ()
    resumeOnce = Let (bnd (Name (T.pack "r") (Unique 10)))
                     (RApp (AVar kName) [unit]) (Ret unit)
    -- let _ = k () in k ()
    resumeTwiceSeq =
      Let (bnd (Name (T.pack "a") (Unique 11))) (RApp (AVar kName) [unit])
        (Let (bnd (Name (T.pack "b") (Unique 12))) (RApp (AVar kName) [unit])
          (Ret unit))
    -- case 0 of A -> k () ; B -> k ()
    resumeInBothArms =
      Case (ALit (LInt 0))
        [ AltCon (T.pack "A") [] resumeOnce
        , AltCon (T.pack "B") [] resumeOnce ]
    -- let _ = f k in ()
    escapeIntoCall =
      Let (bnd (Name (T.pack "c") (Unique 13)))
          (RApp (AVar fName) [AVar kName]) (Ret unit)
    -- let g = (\x -> k x) in ()
    escapeIntoLam =
      Let (bnd (Name (T.pack "g") (Unique 14)))
          (RLam [bnd (Name (T.pack "x") (Unique 15))]
                (Let (bnd (Name (T.pack "r2") (Unique 16)))
                     (RApp (AVar kName) [AVar (Name (T.pack "x") (Unique 15))])
                     (Ret unit)))
          (Ret unit)
    -- letrec loop x = k () in ()
    escapeIntoLetRec =
      LetRec [ ( bnd (Name (T.pack "loop") (Unique 17))
               , [bnd (Name (T.pack "x") (Unique 18))]
               , Let (bnd (Name (T.pack "r3") (Unique 19)))
                     (RApp (AVar kName) [unit]) (Ret unit) ) ]
             (Ret unit)
```

Wire it into `defaultMain`'s top-level `testGroup "wok" [ ... ]` list (alongside `fixityTests`):

```haskell
    , multiplicityUnitTests
```

Ensure `import qualified Data.Text as T` exists in `test/Spec.hs` (it imports `Data.Text` already as `T` per existing usage; if the alias differs, match the file's existing alias).

- [ ] **Step 4: Run tests — verify they fail, then pass**

Run: `cabal test 2>&1 | tail -30`
Expected first run: compile succeeds, `multiplicity (unit)` group runs; if any assertion is wrong, fix `Multiplicity.hs` until green. All other groups stay green.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/IR/Multiplicity.hs wok.cabal test/Spec.hs
git commit -m "feat(multiplicity): Card lattice + cardOf affine analysis on continuation binders

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Module-level analysis, error type, and renderers

**Goal:** Traverse a `CoreModule`, apply `cardOf` to every handler arm, and expose (a) the list of `MultishotResume` errors, (b) an error renderer, and (c) a per-arm `prettyMultiplicity` dump. These are the consumer-facing surfaces Tasks 3–4 wire up.

**Files:**
- Modify: `src/Wok/IR/Multiplicity.hs` (add `MultiplicityError`, `analyzeModule`, `renderMultiplicityError`, `prettyMultiplicity`, and the op-arm collector; extend the module export list)
- Modify: `test/Spec.hs` (extend `multiplicityUnitTests` with module-level cases)

**Acceptance Criteria:**
- [ ] `analyzeModule` returns one `MultishotResume label op` per arm whose continuation card is `Many`, and `[]` for an all-`{0,1}` module.
- [ ] `analyzeModule` finds handlers nested anywhere (inside `Let`/`Case`/`Handle`/`RLam`), not only at the top of a `TopBind`.
- [ ] `prettyMultiplicity` renders one `label.op : 0|1|ω` line per arm, in module order.

**Verify:** `cabal test 2>&1 | grep -i "multiplicity (unit)"` → passes (now includes module-level cases).

**Steps:**

- [ ] **Step 1: Extend the module exports**

In `src/Wok/IR/Multiplicity.hs`, replace the export list with:

```haskell
module Wok.IR.Multiplicity
  ( Card (..)
  , joinC
  , addC
  , cardOf
  , MultiplicityError (..)
  , analyzeModule
  , renderMultiplicityError
  , prettyMultiplicity
  ) where
```

Add imports at the top (alongside existing):

```haskell
import Data.Text (Text)
import qualified Data.Text as Tx
```

- [ ] **Step 2: Add the op-arm collector, error type, analyzer, and renderers**

Append to `src/Wok/IR/Multiplicity.hs`:

```haskell
-- | A handler arm whose continuation is provably multi-shot. Carries the effect
-- label and op name for the diagnostic.
data MultiplicityError = MultishotResume Text Text
  deriving (Eq, Show)

-- | Every operation arm reachable in a module (handlers may nest anywhere).
opArmsInModule :: CoreModule -> [OpArm]
opArmsInModule (CoreModule binds) = concatMap (opArmsInExpr . tbBody) binds

opArmsInExpr :: Expr -> [OpArm]
opArmsInExpr e = case e of
  Ret _            -> []
  Let _ rhs b      -> opArmsInRhs rhs ++ opArmsInExpr b
  LetRec defs b    -> concatMap (\(_, _, db) -> opArmsInExpr db) defs ++ opArmsInExpr b
  Case _ alts      -> concatMap opArmsInAlt alts
  LetJoin _ _ jb b -> opArmsInExpr jb ++ opArmsInExpr b
  Jump _ _         -> []
  Handle e' h      -> opArmsInExpr e' ++ opArmsInHandler h

opArmsInRhs :: Rhs -> [OpArm]
opArmsInRhs (RLam _ b) = opArmsInExpr b
opArmsInRhs _          = []

opArmsInAlt :: Alt -> [OpArm]
opArmsInAlt (AltCon _ _ b) = opArmsInExpr b
opArmsInAlt (AltLit _ b)   = opArmsInExpr b
opArmsInAlt (AltDefault b) = opArmsInExpr b

opArmsInHandler :: Handler -> [OpArm]
opArmsInHandler (Handler (_, re) ops _ _ _) =
  opArmsInExpr re ++ concatMap (\oa -> oa : opArmsInExpr (oaBody oa)) ops

-- | The card of an arm's continuation: walk the body, keyed on the resume binder.
armCard :: OpArm -> Card
armCard oa = cardOf (bndName (oaResume oa)) (oaBody oa)

-- | The consumer: every multi-shot arm is an error.
analyzeModule :: CoreModule -> [MultiplicityError]
analyzeModule cm =
  [ MultishotResume (oaLabel oa) (oaOp oa)
  | oa <- opArmsInModule cm
  , armCard oa == Many ]

renderMultiplicityError :: MultiplicityError -> Text
renderMultiplicityError (MultishotResume lbl op) =
  Tx.concat
    [ Tx.pack "multishot resume: the `", lbl, Tx.pack ".", op
    , Tx.pack "` arm resumes its continuation more than once; handlers are one-shot."
    , Tx.pack "\n  resume at most once, or express the multi-shot logic explicitly (e.g. with a list)."
    ]

-- | The proof artifact: one `label.op : 0|1|ω` line per arm, module order.
prettyMultiplicity :: CoreModule -> Text
prettyMultiplicity cm =
  Tx.intercalate (Tx.pack "\n")
    [ Tx.concat [ oaLabel oa, Tx.pack ".", oaOp oa, Tx.pack " : ", renderCard (armCard oa) ]
    | oa <- opArmsInModule cm ]

renderCard :: Card -> Text
renderCard Zero = Tx.pack "0"
renderCard One  = Tx.pack "1"
renderCard Many = Tx.pack "\969"   -- ω
```

- [ ] **Step 3: Add module-level unit tests**

In `test/Spec.hs`, extend `multiplicityUnitTests` with a third `testGroup` (add to the list):

```haskell
  , testGroup "analyzeModule"
      [ testCase "clean module = no errors" $
          Mult.analyzeModule (modWith resumeOnceArm) @?= []
      , testCase "multishot arm = one error" $
          Mult.analyzeModule (modWith multishotArm)
            @?= [Mult.MultishotResume (T.pack "Choice") (T.pack "flip")]
      ]
  ]
  where
    -- (extend the existing `where` block of multiplicityUnitTests)
    kName  = Name (T.pack "k") (Unique 1)
    -- ... (keep the existing bindings) ...
    handlerWith oa =
      Handler (bnd (Name (T.pack "v") (Unique 90)), Ret unit) [oa] Nothing Nothing Nothing
    modWith oa =
      CoreModule [ TopBind (Name (T.pack "main") (Unique 91)) []
                     (Handle (Ret unit) (handlerWith oa)) ]
    resumeOnceArm =
      OpArm (T.pack "Tick") (T.pack "tick") [] (bnd kName) resumeOnce
    multishotArm =
      OpArm (T.pack "Choice") (T.pack "flip") [] (bnd kName) resumeTwiceSeq
```

(Merge these `where` bindings into Task 1's existing `where` block — do not duplicate `kName`/`bnd`/`unit`/`resumeOnce`/`resumeTwiceSeq`.)

- [ ] **Step 4: Run tests**

Run: `cabal test 2>&1 | grep -iA2 "multiplicity (unit)"`
Expected: PASS (lattice + cardOf + analyzeModule).

- [ ] **Step 5: Commit**

```bash
git add src/Wok/IR/Multiplicity.hs test/Spec.hs
git commit -m "feat(multiplicity): module analysis, MultishotResume error, dump renderer

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `--dump-multiplicity` CLI mode + passing-corpus golden

**Goal:** Expose the inferred per-arm number via `wok <file> --dump-multiplicity`, and pin it with golden dumps over self-contained one-shot/zero-shot handler programs.

**Files:**
- Modify: `app/Main.hs` (add `ModeDumpMultiplicity`, parse `--dump-multiplicity`, dispatch)
- Create: `test/multiplicity-examples/one-shot.wok`
- Create: `test/multiplicity-examples/zero-shot.wok`
- Create: `test/multiplicity-golden/one-shot.expected`
- Create: `test/multiplicity-golden/zero-shot.expected`
- Modify: `test/Spec.hs` (add `multiplicity-golden` group + harness + `findByExtension`)

**Acceptance Criteria:**
- [ ] `wok test/multiplicity-examples/one-shot.wok --dump-multiplicity` prints `Tick.tick : 1`.
- [ ] `wok test/multiplicity-examples/zero-shot.wok --dump-multiplicity` prints `Bail.bail : 0`.
- [ ] The `multiplicity golden` test group passes.

**Verify:** `cabal run -v0 wok -- test/multiplicity-examples/one-shot.wok --dump-multiplicity` → `Tick.tick : 1`

**Steps:**

- [ ] **Step 1: Write the passing example programs**

Create `test/multiplicity-examples/one-shot.wok`:

```
module Main
import Std.Base

effect Tick = { tick : U64 -> U64 }

useTick : () -> U64 with Tick
useTick u = Tick.tick 41

main : U64
main =
  with { Tick.tick x k -> k (x + 1) }
  useTick ()
```

Create `test/multiplicity-examples/zero-shot.wok`:

```
module Main
import Std.Base

effect Bail = { bail : U64 -> Never }

useBail : () -> U64 with Bail
useBail u = Bail.bail 7

main : U64
main =
  with { Bail.bail e k -> 0 }
  useBail ()
```

- [ ] **Step 2: Add the CLI mode**

In `app/Main.hs`:

Add the import (with the existing `Wok.IR.Anf` import):

```haskell
import Wok.IR.Multiplicity (prettyMultiplicity)
```

Extend `CliMode`:

```haskell
data CliMode = ModePrintSchemes | ModeDumpAnf | ModeDumpMultiplicity | ModeRun
```

Update `usage`:

```haskell
usage = "usage: wok <entry.wok> [-I <file.wok>]... [--dump-anf | --dump-multiplicity | --run]"
```

Add the flag in `parseCli`'s `go` (next to `--dump-anf`):

```haskell
    go e xs _  ("--dump-multiplicity" : rest) = go e xs ModeDumpMultiplicity rest
```

Add the dispatch in `runApp`'s `case mode of` (next to `ModeDumpAnf`):

```haskell
      ModeDumpMultiplicity -> case Pipeline.elaborateProgram entryName ms of
        Left msg  -> hPutStrLn stderr msg >> exitFailure
        Right cm  -> TIO.putStrLn (prettyMultiplicity cm)
```

- [ ] **Step 3: Generate the golden files (run the tool, capture output)**

Run and inspect:

```bash
cabal run -v0 wok -- test/multiplicity-examples/one-shot.wok --dump-multiplicity
cabal run -v0 wok -- test/multiplicity-examples/zero-shot.wok --dump-multiplicity
```

Expected first: `Tick.tick : 1`. Expected second: `Bail.bail : 0`.

Create `test/multiplicity-golden/one-shot.expected` with exactly:

```
Tick.tick : 1
```

Create `test/multiplicity-golden/zero-shot.expected` with exactly:

```
Bail.bail : 0
```

(Each file ends with a single trailing newline — the harness appends `"\n"`, matching `anfElaborateHarness`.)

- [ ] **Step 4: Wire the golden group into the test suite**

In `test/Spec.hs`:

Add the file discovery (next to `anfFiles`, around line 62):

```haskell
  multFiles          <- findByExtension [".wok"] "test/multiplicity-examples"
```

Add the test group (next to the `anf golden` group):

```haskell
    , testGroup "multiplicity golden"
        [ goldenVsString (takeBaseName f) (multGoldenFor f) (multDumpHarness f)
        | f <- multFiles ]
```

Add the helpers (next to `anfGoldenFor` / `anfElaborateHarness`):

```haskell
multGoldenFor :: FilePath -> FilePath
multGoldenFor f =
  replaceDirectory (replaceExtension f ".expected") "test/multiplicity-golden"

multDumpHarness :: FilePath -> IO BL.ByteString
multDumpHarness path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> pure (BL.pack ("loader: " <> show lerr <> "\n"))
    Right (entryName, ms) ->
      case Pipeline.elaborateProgram entryName ms of
        Left s  -> pure (BL.pack ("elaborateProgram: " <> s <> "\n"))
        Right cm -> pure (BL.pack (T.unpack (Mult.prettyMultiplicity cm) <> "\n"))
```

- [ ] **Step 5: Run tests, accept goldens if needed**

Run: `cabal test 2>&1 | tail -20`
If the golden group reports a mismatch you have verified is correct, run `cabal run wok-tests -- --accept` and READ the diff before accepting.
Expected: `multiplicity golden` passes; suite green.

- [ ] **Step 6: Commit**

```bash
git add app/Main.hs test/multiplicity-examples test/multiplicity-golden test/Spec.hs
git commit -m "feat(multiplicity): --dump-multiplicity mode + passing-corpus goldens

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Enforce the law — pipeline rejection + multi-shot fail corpus

**Goal:** Make a multi-shot handler an actual compile error: `--run` refuses to run it, and a dedicated golden group pins the `MultishotResume` diagnostic over synthetic multi-shot programs.

**Files:**
- Modify: `src/Wok/Pipeline.hs` (add `elaborateCheckedFull`; export it; import `Multiplicity`)
- Modify: `app/Main.hs` (`ModeRun` uses `elaborateCheckedFull`)
- Create: `test/multiplicity-fail-examples/multishot-plus.wok`
- Create: `test/multiplicity-fail-examples/multishot-seq.wok`
- Create: `test/multiplicity-fail-golden/multishot-plus.expected`
- Create: `test/multiplicity-fail-golden/multishot-seq.expected`
- Modify: `test/Spec.hs` (add `multiplicity fail golden` group + harness)

**Acceptance Criteria:**
- [ ] `wok test/multiplicity-fail-examples/multishot-plus.wok --run` exits non-zero with the `multishot resume` diagnostic on stderr.
- [ ] The existing passing examples still `--run` unchanged (629 run-goldens stay green — the corpus has no multi-shot handlers).
- [ ] The `multiplicity fail golden` group passes.

**Verify:** `cabal run -v0 wok -- test/multiplicity-fail-examples/multishot-plus.wok --run; echo "exit=$?"` → diagnostic on stderr, `exit=1`.

**Steps:**

- [ ] **Step 1: Add the checked-elaboration pipeline entry**

In `src/Wok/Pipeline.hs`:

Extend the export list:

```haskell
  ( typecheckProgram
  , elaborateProgram
  , elaborateProgramFull
  , elaborateCheckedFull
  ) where
```

Add the import:

```haskell
import Wok.IR.Multiplicity (analyzeModule, renderMultiplicityError)
```

Append the function after `elaborateProgramFull`:

```haskell
-- | Whole-program elaboration plus the one-shot multiplicity law: a multi-shot
-- handler is rejected here as a compile error (stringified, like other v1
-- pipeline errors).
elaborateCheckedFull
  :: ModuleName
  -> [LoadedModule]
  -> Either String CoreModule
elaborateCheckedFull entryName ms = do
  cm <- elaborateProgramFull entryName ms
  case analyzeModule cm of
    []   -> Right cm
    errs -> Left (Tx.unpack
                    (Tx.intercalate (Tx.pack "\n")
                       (map renderMultiplicityError errs)))
```

- [ ] **Step 2: Make `--run` enforce the law**

In `app/Main.hs`, change the `ModeRun` branch from `elaborateProgramFull` to `elaborateCheckedFull`:

```haskell
      ModeRun -> case Pipeline.elaborateCheckedFull entryName ms of
        Left msg -> hPutStrLn stderr msg >> exitFailure
        Right cm -> case Interp.runModule cm of
          Left rerr -> hPutStrLn stderr ("runtime error: " <> show rerr) >> exitFailure
          Right v   -> TIO.putStrLn (Interp.renderValue v)
```

- [ ] **Step 3: Write the multi-shot fail programs**

Create `test/multiplicity-fail-examples/multishot-plus.wok`:

```
module Main
import Std.Base

effect Choice = { flip : Bool }

useChoice : () -> U64 with Choice
useChoice u = case Choice.flip of
  True  -> 1
  False -> 0

main : U64
main =
  with { Choice.flip k -> k True + k False }
  useChoice ()
```

Create `test/multiplicity-fail-examples/multishot-seq.wok`:

```
module Main
import Std.Base

effect Choice = { flip : Bool }

useChoice : () -> U64 with Choice
useChoice u = case Choice.flip of
  True  -> 1
  False -> 0

main : U64
main =
  with { Choice.flip k -> let a = k True in k False }
  useChoice ()
```

- [ ] **Step 4: Add the fail-golden group + harness**

In `test/Spec.hs`:

Add discovery (next to `multFiles`):

```haskell
  multFailFiles      <- findByExtension [".wok"] "test/multiplicity-fail-examples"
```

Add the group (next to `multiplicity golden`):

```haskell
    , testGroup "multiplicity fail golden"
        [ goldenVsString (takeBaseName f) (multFailGoldenFor f) (multFailHarness f)
        | f <- multFailFiles ]
```

Add the helpers:

```haskell
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
```

- [ ] **Step 5: Generate fail-goldens (run, capture, verify)**

```bash
cabal run -v0 wok -- test/multiplicity-fail-examples/multishot-plus.wok --run; echo "exit=$?"
```

Expected: stderr shows the `multishot resume: the \`Choice.flip\` arm ...` diagnostic, `exit=1`.

Create `test/multiplicity-fail-golden/multishot-plus.expected` and `multishot-seq.expected` by running the suite once and accepting (Step 6) — or write them by hand to match `renderMultiplicityError (MultishotResume "Choice" "flip")`:

```
multishot resume: the `Choice.flip` arm resumes its continuation more than once; handlers are one-shot.
  resume at most once, or express the multi-shot logic explicitly (e.g. with a list).
```

(Both files have identical content — same effect/op — plus a trailing newline.)

- [ ] **Step 6: Run tests, accept goldens after reading the diff**

Run: `cabal test 2>&1 | tail -25`
If `multiplicity fail golden` mismatches because the `.expected` was not yet written, run `cabal run wok-tests -- --accept`, READ the diff, confirm it is exactly the multishot diagnostic, then re-run `cabal test`.
Expected: full suite green (629 + new unit/golden tests).

- [ ] **Step 7: Commit**

```bash
git add src/Wok/Pipeline.hs app/Main.hs test/multiplicity-fail-examples test/multiplicity-fail-golden test/Spec.hs
git commit -m "feat(multiplicity): enforce one-shot law in --run + multishot fail goldens

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Post-implementation (after all tasks pass review)

These are NOT implementation tasks — they are the merge-time obligations the spec (§11) records. Do them as part of finishing the branch, before the full-branch review:

- [ ] Update the slice-X row in `docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md` to reflect the re-anchor (one-shot law; value restriction dropped; analysis-only consumer this slice).
- [ ] Add/append a memory recording: one-shot is the law, value restriction dropped, multi-shot → `List`, `ndet`-for-concurrency unaffected, interpreter capability retained, affine-analysis (no-dup) is the no-dup half of an eventual linear system. Cross-link from `effect-surface-syntax-final` and `effect-compilation-strategy`.
- [ ] Full-branch review before any merge to `main` (per-task reviews do not substitute).

## Self-review notes (spec coverage)

- Spec §5 (lattice + walk) → Task 1. Spec §6 (consumer: error + dump; `0`-lint left in `Infer`) → Tasks 2–4 (the `0`-lint is untouched; this plan adds no `0` handling, matching the spec). Spec §10 corpus (no multi-shot, no resume-through-helper) → validated by all 629 run-goldens staying green and conservative-local needing no summaries. Spec §12 (golden dump + synthetic fail corpus + unit tests) → Tasks 1–4. Spec §4 OUT items → none implemented; §8 (`bndMult` revive), §9 (oracle) intentionally deferred and noted above.
- No grammar change → no BNFC regen; shift/reduce count untouched (stays 32).
