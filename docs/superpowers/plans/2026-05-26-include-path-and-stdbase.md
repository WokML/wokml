# Include Path and Std.Base Prelude Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace hand-coded `Wok.TypeChecking.Builtins` with an embedded pure-Wok `Std.Base` Prelude, stand up a minimal module loader (`wok <entry.wok> [-I file.wok]...`), thread fixity tables + envs across module boundaries, and add a warning channel for bodyless signatures in user files.

**Architecture:** Three phases. **Phase 1 (additive foundations)** lands eight isolated changes that don't break existing tests: a leaf `Wok.SourceOrigin` module, env/fixity overlay combinators, the `skolemize → freezeSig` rename, a `modPathText` helper, the warning channel + bodyless-sig fix + new `inferProgramWith`, the embedded `Wok.Prelude` (with placeholder content), and the new `Wok.Loader`. **Phase 2** is a mechanical `TcInt → TcU64` rename across code + test fixtures. **Phase 3** is the cutover: populate `Std.Base`, shrink `Builtins.initialEnv`, rewrite `Main`, migrate the typecheck harness and existing fixtures to import `Std.Base`. **Phase 4** adds the new Loader-tier test suite and migrates the user-facing examples.

**Tech Stack:** Haskell (GHC2024, Strict + StrictData on hand-written modules), cabal, BNFC + alex + happy, file-embed (new dep), tasty + tasty-golden + tasty-hunit. ast-grep is preferred for code search.

**Spec:** `docs/superpowers/specs/2026-05-26-include-path-and-stdbase-design.md`

**Project conventions:**
- No emojis anywhere in code, comments, commit messages, or test fixtures.
- Hand-written `wok` library modules are `Strict + StrictData` by default (see `wok.cabal` `default-extensions`).
- Generated parser modules under `src-generated/` are NOT to be hand-edited; regenerate with `bnfc --haskell -d --text-token -o src-generated grammar/Wok.cf`.

---

## Phase 1: Additive foundations

### Task 1: Create `Wok.SourceOrigin` leaf module

**Goal:** A tiny leaf module hosting the `Origin` ADT so both `Wok.Loader` and `Wok.TypeChecking.Infer` can depend on it without a cyclic import.

**Files:**
- Create: `src/Wok/SourceOrigin.hs`
- Modify: `wok.cabal` (add `Wok.SourceOrigin` to `exposed-modules`)
- Test: add a tiny smoke test to `test/Spec.hs`

**Acceptance Criteria:**
- [ ] `data Origin = Embedded | UserFile FilePath` exported.
- [ ] `originPath :: Origin -> String` exported, returns `"<embedded Std.Base>"` for `Embedded` and the path for `UserFile`.
- [ ] No imports beyond `Prelude` (true leaf).
- [ ] `cabal build` succeeds.
- [ ] Smoke test in `test/Spec.hs` verifying `originPath` round-trips passes.

**Verify:** `cabal test --test-options="-p sourceOrigin"` passes.

**Steps:**

- [ ] **Step 1: Write the module**

Create `src/Wok/SourceOrigin.hs`:

```haskell
-- | Where a module's source came from. Used to tag every LoadedModule
-- and to gate origin-sensitive typechecker behavior (e.g. bodyless-sig
-- warnings are silent for Embedded but emitted for UserFile).
--
-- Lives in its own leaf module so both Wok.Loader and
-- Wok.TypeChecking.Infer can depend on it without a cyclic import.
module Wok.SourceOrigin
  ( Origin (..)
  , originPath
  ) where

data Origin = Embedded | UserFile FilePath
  deriving (Eq, Show)

originPath :: Origin -> String
originPath Embedded        = "<embedded Std.Base>"
originPath (UserFile path) = path
```

- [ ] **Step 2: Register in cabal**

Open `wok.cabal`, find the `library` section's `exposed-modules` block (around line 49-59). Add `Wok.SourceOrigin` between `Wok.Reordering` and `Wok.TypeChecking`:

```cabal
    exposed-modules:
        Wok.Parsing
        Wok.Reordering
        Wok.SourceOrigin
        Wok.TypeChecking
        Wok.TypeChecking.Types
        ...
```

- [ ] **Step 3: Add the smoke test**

Open `test/Spec.hs`. Add an import at the top (near the other `qualified Wok.* as ...` imports):

```haskell
import qualified Wok.SourceOrigin as SO
```

Add a new test group adjacent to `envSmokeTests`:

```haskell
sourceOriginTests :: TestTree
sourceOriginTests = testGroup "Wok.SourceOrigin"
  [ testCase "originPath Embedded is the placeholder tag" $
      SO.originPath SO.Embedded @?= "<embedded Std.Base>"
  , testCase "originPath UserFile returns the path verbatim" $
      SO.originPath (SO.UserFile "foo/bar.wok") @?= "foo/bar.wok"
  ]
```

Add `sourceOriginTests` to the test list in `main` (the `defaultMain $ testGroup "wok"` block, around line 38).

- [ ] **Step 4: Build and test**

```bash
cabal build 2>&1 | tail -5
cabal test --test-options="-p sourceOrigin" 2>&1 | tail -10
```

Expected: build succeeds; tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/Wok/SourceOrigin.hs wok.cabal test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(loader): add Wok.SourceOrigin leaf module

Hosts the Origin ADT so that both Wok.Loader (to come) and
Wok.TypeChecking.Infer can depend on it without forming an
import cycle. Embedded vs UserFile distinction will gate
bodyless-sig warning emission.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Add `overlayEnvs` + `EnvNs` to `Wok.TypeChecking.Env`

**Goal:** A left-biased `Env` merge combinator that surfaces collisions across all three namespaces (vars, cons, tycons), used later by the loader when composing imports.

**Files:**
- Modify: `src/Wok/TypeChecking/Env.hs`
- Test: `test/Spec.hs` — extend `envSmokeTests` or add `envOverlayTests`

**Acceptance Criteria:**
- [ ] `data EnvNs = NsVar | NsCon | NsTyCon` exported.
- [ ] `overlayEnvs :: Env -> Env -> Either [(EnvNs, Text)] Env` exported.
- [ ] On disjoint inputs, returns the union (left-biased on values).
- [ ] On any name collision in any of the three maps, returns `Left` with one `(ns, name)` pair per offender.
- [ ] Smoke test covers: disjoint union, collision in `envVars`, collision in `envCons`, collision in `envTyCons`, collision across multiple namespaces simultaneously.

**Verify:** `cabal test --test-options="-p envOverlay"` passes.

**Steps:**

- [ ] **Step 1: Write the failing tests first**

Open `test/Spec.hs`. Add to imports if not present:

```haskell
import qualified Data.Map.Strict as Map
```

Add a new group:

```haskell
envOverlayTests :: TestTree
envOverlayTests = testGroup "Wok.TypeChecking.Env (overlay)"
  [ testCase "disjoint vars union cleanly" $
      let a = TE.extendVar (T.pack "x") (Ty.Scheme [] (Ty.CTCon Ty.TcInt [])) TE.emptyEnv
          b = TE.extendVar (T.pack "y") (Ty.Scheme [] (Ty.CTCon Ty.TcBool [])) TE.emptyEnv
      in case TE.overlayEnvs a b of
           Right e -> do
             TE.lookupVar (T.pack "x") e @?= TE.lookupVar (T.pack "x") a
             TE.lookupVar (T.pack "y") e @?= TE.lookupVar (T.pack "y") b
           Left _ -> assertFailure "expected Right"

  , testCase "var collision returns Left with NsVar" $
      let s1 = Ty.Scheme [] (Ty.CTCon Ty.TcInt [])
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

  , testCase "collisions across multiple namespaces are all reported" $
      let s = Ty.Scheme [] (Ty.CTCon Ty.TcInt [])
          tci = TE.TyConInfo Ty.KStar 0 []
          a = TE.extendTyCon (T.pack "X") tci (TE.extendVar (T.pack "y") s TE.emptyEnv)
          b = TE.extendTyCon (T.pack "X") tci (TE.extendVar (T.pack "y") s TE.emptyEnv)
      in case TE.overlayEnvs a b of
           Left collisions ->
             -- Sorted on the namespace tag to make assertion stable
             Data.List.sort collisions @?=
               Data.List.sort [(TE.NsVar, T.pack "y"), (TE.NsTyCon, T.pack "X")]
           Right _ -> assertFailure "expected Left"
  ]
```

Add `envOverlayTests` to the `defaultMain` list.

Add `import qualified Data.List` to the imports if not present.

- [ ] **Step 2: Run the failing tests**

```bash
cabal test --test-options="-p envOverlay" 2>&1 | tail -20
```

Expected: compile error — `EnvNs` and `overlayEnvs` not defined.

- [ ] **Step 3: Implement `overlayEnvs` and `EnvNs`**

Open `src/Wok/TypeChecking/Env.hs`. Add to the export list (alphabetised next to `emptyEnv`):

```haskell
module Wok.TypeChecking.Env
  ( Env (..)
  , ConInfo (..)
  , TyConInfo (..)
  , EnvNs (..)
  , emptyEnv
  , overlayEnvs
  , lookupVar
  , lookupCon
  , lookupTyCon
  , extendVar
  , extendCon
  , extendTyCon
  ) where
```

After the `emptyEnv` definition, add:

```haskell
-- | Tag for which of the three Env namespaces a name lives in.
-- Used by 'overlayEnvs' to attribute collisions.
data EnvNs = NsVar | NsCon | NsTyCon
  deriving (Eq, Ord, Show)

-- | Left-biased union of two 'Env's. On any name collision in any of
-- the three namespaces, returns 'Left' with one (namespace, name) pair
-- per offending name. The order of pairs in the result is:
-- envVars collisions first (in Map order), then envCons, then envTyCons.
--
-- "Left-biased" means that on disjoint inputs the result is the
-- straightforward union; the bias only matters at the API contract level
-- since we reject any actual overlap rather than silently picking a side.
overlayEnvs :: Env -> Env -> Either [(EnvNs, Text)] Env
overlayEnvs (Env v1 c1 tc1) (Env v2 c2 tc2) =
  let varClash = Map.keys (Map.intersection v1 v2)
      conClash = Map.keys (Map.intersection c1 c2)
      tcClash  = Map.keys (Map.intersection tc1 tc2)
      clashes  =  [ (NsVar,   k) | k <- varClash ]
               ++ [ (NsCon,   k) | k <- conClash ]
               ++ [ (NsTyCon, k) | k <- tcClash  ]
  in case clashes of
       [] -> Right (Env (Map.union v1 v2) (Map.union c1 c2) (Map.union tc1 tc2))
       _  -> Left clashes
```

- [ ] **Step 4: Run the tests; expect green**

```bash
cabal test --test-options="-p envOverlay" 2>&1 | tail -20
```

Expected: all five tests pass. Run the full suite to confirm no regression:

```bash
cabal test 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add src/Wok/TypeChecking/Env.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(typecheck): add overlayEnvs + EnvNs to Wok.TypeChecking.Env

Left-biased Env union combinator that returns Left with per-namespace
(NsVar/NsCon/NsTyCon) name pairs on any collision. Used later by the
module loader to compose imports' exported envs while attributing
collisions to specific names rather than producing silent overwrites.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Add `overlayFixities` + `reorderModuleWith` to `Wok.Reordering`

**Goal:** Split `reorderModule` so that an external `FixityTable` (from imports) can seed expression reordering, and add a fixity-table overlay combinator that reports cross-module operator conflicts.

**Files:**
- Modify: `src/Wok/Reordering.hs`
- Test: extend `fixityTests` in `test/Spec.hs`

**Acceptance Criteria:**
- [ ] `reorderModuleWith :: FixityTable -> Module -> Either [ReorderError] Module` exported (returns the reordered AST only, not a wrapping `ReorderedModule`).
- [ ] Existing `reorderModule :: Module -> Either [ReorderError] ReorderedModule` retained and works unchanged (calls `reorderModuleWith` internally with the module's own fixities — no externally injected table).
- [ ] `overlayFixities :: FixityTable -> FixityTable -> Either [FixityError] FixityTable` exported.
- [ ] `overlayFixities` returns `RedeclaredOp` for any operator that appears in both tables (using each side's recorded `BNFC'Position` for `posA`/`posB`).
- [ ] `emptyFixityTable :: FixityTable` exported (handy for tests + for the loader's accumulator initial value).
- [ ] Three new tests: `reorderModuleWith` accepts an empty external table and behaves like the old `reorderModule`; `reorderModuleWith` honors an external `fixity * left tighter than +` to reassociate `a + b * c`; `overlayFixities` reports `RedeclaredOp` on conflict.

**Verify:** `cabal test --test-options="-p fixity OR reordering"` passes; existing fixity / reorder tests untouched.

**Steps:**

- [ ] **Step 1: Add `emptyFixityTable`, `overlayFixities`, and `reorderModuleWith`**

Open `src/Wok/Reordering.hs`. Update the export list:

```haskell
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
```

After the `FixityTable` newtype definition (line ~44), add:

```haskell
-- | An empty fixity table, useful as an identity for overlays and
-- as the starting point for the module loader's accumulator.
emptyFixityTable :: FixityTable
emptyFixityTable = FixityTable Map.empty
```

After `buildFixityTable` (line ~68), add:

```haskell
-- | Left-biased union of two fixity tables. On any operator name that
-- appears in both, returns 'RedeclaredOp name posA posB' (one entry per
-- offending operator) so the caller can attribute conflicts.
overlayFixities
  :: FixityTable -> FixityTable -> Either [FixityError] FixityTable
overlayFixities (FixityTable a) (FixityTable b) =
  let clashes = Map.intersectionWithKey
                  (\k ai bi -> RedeclaredOp k (opPos ai) (opPos bi))
                  a b
  in case Map.elems clashes of
       [] -> Right (FixityTable (Map.union a b))
       es -> Left es
```

After `reorderModule` (line ~164), add:

```haskell
-- | Reorder a module's expressions against an *externally supplied*
-- fixity table. The supplied table is overlaid (left-biased; conflicts
-- reported as 'RedeclaredOp' lifted via 'FixityErr') with the module's
-- own DFixity decls. Use this from the module loader to thread
-- imported modules' fixities into the importer's reordering pass.
--
-- The single-module 'reorderModule' is now a thin wrapper that passes
-- 'emptyFixityTable' as the external table.
reorderModuleWith
  :: FixityTable -> Module -> Either [ReorderError] Module
reorderModuleWith externalTable m = do
  ownTable <- mapLeft (map FixityErr) (buildFixityTable m)
  merged   <- mapLeft (map FixityErr) (overlayFixities externalTable ownTable)
  reorderAst merged m
```

Refactor `reorderModule` to use the new combinator. Replace the existing definition (line ~164) with:

```haskell
reorderModule :: Module -> Either [ReorderError] ReorderedModule
reorderModule m = do
  table <- mapLeft (map FixityErr) (buildFixityTable m)
  ast   <- reorderModuleWith emptyFixityTable m
  Right (ReorderedModule ast table)
```

(The `ReorderedModule` wrapper is retained because existing test code and `app/Main.hs` reach into it. The new internal pipeline uses `reorderModuleWith` directly.)

- [ ] **Step 2: Add the new tests**

Open `test/Spec.hs`. In the `fixityTests` group, add to the `"errors"` subgroup at the end (just before the closing `]`):

```haskell
      , testCase "overlayFixities: disjoint tables merge cleanly" $
          let a = case buildFixityTable (parseSrc "fixity + left\n") of
                    Right t -> t
                    Left es -> error ("setup: " ++ show es)
              b = case buildFixityTable (parseSrc "fixity * left tighter than +\n") of
                    Right t -> t
                    Left es -> error ("setup: " ++ show es)
          in case overlayFixities a b of
               Right merged -> do
                 assocOf merged "+" @?= Just FALeft
                 assocOf merged "*" @?= Just FALeft
               Left es -> assertFailure ("expected Right, got: " ++ show es)

      , testCase "overlayFixities: conflict yields RedeclaredOp" $
          let a = case buildFixityTable (parseSrc "fixity + left\n") of
                    Right t -> t
                    Left es -> error ("setup: " ++ show es)
              b = case buildFixityTable (parseSrc "fixity + right\n") of
                    Right t -> t
                    Left es -> error ("setup: " ++ show es)
          in case overlayFixities a b of
               Left [RedeclaredOp "+" _ _] -> pure ()
               other -> assertFailure ("expected single RedeclaredOp, got " ++ show other)
```

In the `resolveTests` group, add new cases inside the `"chains"` subgroup at the end:

```haskell
      , testCase "reorderModuleWith: empty external table behaves like reorderModule" $
          let src = "fixity + left\nfixity * left tighter than +\nx = a * b + c\n"
              expected = case reorderModule (parseSrc src) of
                           Right rm  -> Pr.printTree (reorderedAst rm)
                           Left  es  -> error ("setup: " ++ show es)
          in case reorderModuleWith emptyFixityTable (parseSrc src) of
               Right ast -> Pr.printTree ast @?= expected
               Left es   -> assertFailure ("expected Right, got: " ++ show es)

      , testCase "reorderModuleWith: external table influences reassociation" $
          let extSrc = "fixity + left\nfixity * left tighter than +\n"
              ext   = case buildFixityTable (parseSrc extSrc) of
                        Right t -> t
                        Left es -> error ("setup: " ++ show es)
              userSrc = "x = a + b * c\n"
          in case reorderModuleWith ext (parseSrc userSrc) of
               Right ast ->
                 -- The reassociation should put * inside +'s right operand.
                 Pr.printTree ast @?= "x = a + (b * c)"
               Left es -> assertFailure ("expected Right, got: " ++ show es)
```

- [ ] **Step 3: Build and test**

```bash
cabal build 2>&1 | tail -5
cabal test --test-options="-p Wok.Reordering" 2>&1 | tail -30
```

Expected: all existing reorder/fixity tests still pass, plus the new ones.

- [ ] **Step 4: Commit**

```bash
git add src/Wok/Reordering.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(reordering): add overlayFixities + reorderModuleWith

Splits expression reordering from fixity-table construction so the
module loader can seed reordering with an externally supplied
FixityTable (the union of imports' tables). Existing reorderModule
becomes a thin wrapper. New overlayFixities surfaces cross-module
RedeclaredOp on conflict.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Rename `skolemize` → `freezeSig`

**Goal:** Drop the "skolemize" jargon. Function gets a plain-English name; the `Rigid` constructor stays (already plain). The over-promising note in `syntax.md` is reworded.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs` (definition, call site, error message)
- Modify: `src/Wok/TypeChecking/Types.hs` (comment on `Rigid`)
- Modify: `syntax.md` (rewording)

**Acceptance Criteria:**
- [ ] No occurrences of `skolemize` or `Skolem` remain in `src/` or `syntax.md` or `app/`.
- [ ] `freezeSig` has a docstring matching the spec's wording (uses the `double n = n + n` example, NOT `f = (+)`).
- [ ] `cabal build` succeeds.
- [ ] `cabal test` passes (rename does not change behavior).

**Verify:** `grep -RIn "skolem\|Skolem" src app syntax.md` returns no matches; `cabal test 2>&1 | tail -5` shows no failures.

**Steps:**

- [ ] **Step 1: Find every reference**

```bash
grep -RIn "skolemize\|Skolem" src app syntax.md docs/superpowers/plans 2>/dev/null
```

Expected matches (4 in `src/`, 1 in `syntax.md` — the plan files themselves are reference material and don't need updating):
- `src/Wok/TypeChecking/Types.hs:58` (comment on `Rigid`)
- `src/Wok/TypeChecking/Infer.hs:150` (definition)
- `src/Wok/TypeChecking/Infer.hs:167` (error message inside `skolemize`)
- `src/Wok/TypeChecking/Infer.hs:704` (call site)
- `syntax.md` (the over-promising note)

- [ ] **Step 2: Rename the function in `Infer.hs`**

Open `src/Wok/TypeChecking/Infer.hs`. Find `skolemize :: Scheme -> TC s (Type s)` (line ~150). Replace the function with:

```haskell
-- | Replace each forall-bound type variable in a user's signature with
-- a fresh Rigid type — one the unifier treats as an opaque constant.
-- Catches signatures that over-promise: in
--
--   double : a -> a
--   double n = n + n
--
-- the body forces a = u64 (because (+) is u64 -> u64 -> u64), so the
-- body's inferred type is u64 -> u64. Without freezing, unifying
-- (a -> a) with (u64 -> u64) silently weakens the sig to (u64 -> u64).
-- With freezing, the sig becomes (rigid_1 -> rigid_1); unification
-- with (u64 -> u64) fails, and the over-promise surfaces as a type
-- error rather than disappearing.
freezeSig :: Scheme -> TC s (Type s)
freezeSig (Scheme vars body) = do
  -- existing body of skolemize, with the internal error message updated:
  --   ("freezeSig: dangling CTGen " ++ show i)
  -- ... (keep the existing implementation verbatim, only the function
  --      name and the internal error string change)
```

When making the edit, preserve the original function body exactly — only change:
- function name `skolemize` → `freezeSig` (definition line)
- the error string `"skolemize: dangling CTGen "` → `"freezeSig: dangling CTGen "` (~line 167)

Update the call site (~line 704) from `declT <- skolemize declared` to `declT <- freezeSig declared`.

- [ ] **Step 3: Update the comment in `Types.hs`**

Open `src/Wok/TypeChecking/Types.hs`. Find the `Rigid` constructor (line ~58) and update its docstring:

```haskell
    -- ^ Rigid (frozen) type introduced by freezeSig. Represents a rigid
    -- type — an opaque constant the unifier can only equate with itself.
    -- See freezeSig for the over-promising motivation.
```

(Replace any mention of "skolem" / "skolemize" with the new terminology.)

- [ ] **Step 4: Reword `syntax.md`**

Open `syntax.md`. Replace the "overpromising generalised type" note with the new wording:

```markdown
Remember there are over-promising signatures like

    f : a -> a
    f = (+)

doesn't work because `(+)` is `u64 -> u64 -> u64`, not `a -> a`. The
typechecker catches this by *freezing* the user's signature (`freezeSig`):
the `a`s become rigid constants that the unifier won't equate with `u64`,
so the over-promise surfaces as a type error.
```

(Note: this still uses the original `f = (+)` example because that's what the user originally wrote in syntax.md. The `freezeSig` docstring uses the cleaner `double n = n + n` example for technical clarity.)

- [ ] **Step 5: Build and test**

```bash
cabal build 2>&1 | tail -5
cabal test 2>&1 | tail -10
```

Expected: build succeeds; all tests pass (this is purely a rename + comment change).

- [ ] **Step 6: Verify no remaining references**

```bash
grep -RIn "skolemize\|Skolem" src app syntax.md 2>/dev/null
```

Expected: no matches.

- [ ] **Step 7: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs src/Wok/TypeChecking/Types.hs syntax.md
git commit -m "$(cat <<'EOF'
refactor(typecheck): rename skolemize -> freezeSig

Plain-English name for the function that freezes a user's signature
type variables into Rigid constants before unifying against the body's
inferred type. Behavior unchanged; the Rigid constructor (already a
plain word) keeps its name. syntax.md note rewritten in the new terms.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Add `modPathText` helper; refactor `modPathHead` callers

**Goal:** A new helper that flattens a dotted `ModPath` (e.g. `Std.Base`) into a single `Text`, replacing the current `modPathHead` that errors on `MPDot`. Used by the loader for module-name keys and by the typechecker for tycon/constructor lookup.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs`
- Test: `test/Spec.hs` (extend appropriate group with `modPathText` cases)

**Acceptance Criteria:**
- [ ] `modPathText :: Abs.ModPath -> Text` exported from `Wok.TypeChecking.Infer` (or a new tiny helper module if more natural).
- [ ] `modPathText (Abs.MPName (Abs.ConId (_, n))) = n`.
- [ ] `modPathText (Abs.MPDot p (Abs.ConId (_, n))) = modPathText p <> "." <> n`.
- [ ] A second helper `modPathPos :: Abs.ModPath -> (Int, Int)` returns the position of the *first* `ConId` in the path (used for error reporting).
- [ ] Existing `modPathHead` removed; every caller updated to use `(modPathText, modPathPos)` or `modPathText` alone.
- [ ] Existing tycon/constructor lookup at the `MPDot` call sites no longer errors — qualified names are accepted as their flattened text key (e.g. `Std.Base.True` → lookup key `"Std.Base.True"`).

  Note: actual qualified-name lookup semantics are deferred to a later spec. For now, a `MPDot` path that doesn't resolve to a known tycon/constructor surfaces as a normal `UnknownTyCon` / `UnknownCon` error. Bare `MPName` lookups (the only thing user code can write today) continue to work.

- [ ] `cabal test` passes (the change is mechanical for `MPName`; previously-erroring `MPDot` is now an `UnknownTyCon` error in user code, which is no worse).

**Verify:** `cabal test 2>&1 | tail -10` shows no regressions; new helper tests pass.

**Steps:**

- [ ] **Step 1: Write helper + helper tests first**

Open `test/Spec.hs`. Add a new test group:

```haskell
modPathTests :: TestTree
modPathTests = testGroup "Wok.TypeChecking.Infer (modPath helpers)"
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

  , testCase "modPathPos returns first ConId position" $
      let mp = Abs.MPDot (Abs.MPName (Abs.ConId ((42, 7), T.pack "Std")))
                         (Abs.ConId ((42, 11), T.pack "Base"))
      in I.modPathPos mp @?= (42, 7)
  ]
```

Add `modPathTests` to the test list in `defaultMain`.

- [ ] **Step 2: Run failing tests**

```bash
cabal test --test-options="-p modPath" 2>&1 | tail -10
```

Expected: compile error — `modPathText` / `modPathPos` not exported.

- [ ] **Step 3: Implement the helpers**

Open `src/Wok/TypeChecking/Infer.hs`. Add `modPathText` and `modPathPos` to the module's export list (next to `inferProgram`).

Replace the existing `modPathHead` (line ~245) with:

```haskell
-- | Flatten a dotted ModPath into its text key, e.g. Std.Base -> "Std.Base".
modPathText :: Abs.ModPath -> Text
modPathText (Abs.MPName (Abs.ConId (_, n))) = n
modPathText (Abs.MPDot p (Abs.ConId (_, n))) =
  modPathText p <> Tx.pack "." <> n

-- | Position of the first (leftmost) ConId in a ModPath, used for
-- error reporting.
modPathPos :: Abs.ModPath -> (Int, Int)
modPathPos (Abs.MPName (Abs.ConId (pos, _))) = pos
modPathPos (Abs.MPDot p _)                   = modPathPos p
```

- [ ] **Step 4: Update existing callers of `modPathHead`**

Every call site of `modPathHead` returned `(name, pos)`. Each call site lives near a `case` that does `let (name, pos) = modPathHead modPath in ...`. Replace each such block:

```haskell
let name = modPathText modPath
    pos  = modPathPos modPath
```

Call sites (from earlier grep): `Infer.hs` lines 207, 218, 328, 338, 365, 397. Each is a near-identical `let (name, pos) = modPathHead modPath` line — translate each mechanically.

- [ ] **Step 5: Run tests**

```bash
cabal test 2>&1 | tail -10
```

Expected: helper tests pass; all existing tests pass (the rename is mechanical; semantics for bare `MPName` are unchanged; `MPDot` user code now surfaces as `UnknownTyCon` instead of an internal error, which is strictly better).

- [ ] **Step 6: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
refactor(typecheck): replace modPathHead with modPathText + modPathPos

Drops the 'qualified names not supported' error in favour of a clean
flatten-to-Text helper. Dotted ModPaths like Std.Base are now flattened
to the text key 'Std.Base'; lookups against environments will surface
as UnknownTyCon/UnknownCon rather than internal errors. Loader work
to come will use these keys directly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Warning channel + bodyless-sig support + `inferProgramWith`

**Goal:** Three coupled changes in `Wok.TypeChecking.Infer`: add a `Warning` ADT, fix bodyless sigs so they enter the env as ordinary bindings, and add a new `inferProgramWith :: Env -> Origin -> Module -> Either TypeError (Env, [TypedDecl], [Warning])`. Existing `inferProgram` becomes a back-compat wrapper.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs`
- Modify: `src/Wok/TypeChecking.hs` (re-export `Warning`, `inferProgramWith`, `Origin`)
- Test: `test/Spec.hs` — new `bodylessSigTests` group

**Acceptance Criteria:**
- [ ] `data Warning = BodylessBinding Text BNFC'Position` exported from `Wok.TypeChecking.Infer` and re-exported from `Wok.TypeChecking`.
- [ ] `inferProgramWith :: Env -> Origin -> Abs.Module -> Either TypeError (Env, [TypedDecl], [Warning])` implemented and exported.
- [ ] Existing `inferProgram :: Abs.Module -> Either TypeError (Env, [TypedDecl])` retained, implemented as `inferProgramWith Builtins.initialEnv (UserFile "<unknown>") m` and discarding the warnings list. Existing callers + tests unchanged.
- [ ] Bodyless `LDSig` / `DSig` (a sig whose name has no matching `LDEqn`/`DEqn`) enters the env with its declared scheme verbatim (no `freezeSig`).
- [ ] When `Origin = UserFile _`, each bodyless sig emits a `BodylessBinding name pos` warning.
- [ ] When `Origin = Embedded`, bodyless sigs are silent.
- [ ] Multi-name sigs (`a, b, c : Int`) get one warning per bodyless name when in `UserFile`.
- [ ] New tests cover: bodyless sig becomes a visible binding (regression for the current silent drop); user-file bodyless sig produces exactly one warning per binding; embedded bodyless sig produces zero warnings; bodyless sig with `a -> a` scheme stays `forall a. a -> a` (no freezing applied).

**Verify:** `cabal test --test-options="-p bodyless"` passes; whole suite passes.

**Steps:**

- [ ] **Step 1: Add the Warning ADT**

Open `src/Wok/TypeChecking/Infer.hs`. Near the existing data declarations (next to `TypedDecl`), add:

```haskell
-- | Non-fatal diagnostics surfaced by the typechecker. The set is
-- intentionally small in v1 — one variant per surface phenomenon
-- we want to flag without aborting.
data Warning
  = BodylessBinding Text BNFC'Position
    -- ^ A signature (LDSig/DSig) had no matching equation. The binding
    -- still enters the env (with its declared scheme verbatim) so
    -- importers see it; this warning only fires for user-file modules.
  deriving (Eq, Show)
```

Add `BNFC'Position` and `Warning(..)` to the export list.

- [ ] **Step 2: Refactor `inferProgram` → `inferProgramWith` (top-level)**

Find `inferProgram` (line ~755). The new shape:

```haskell
-- | Pipeline entry parameterised by the seed env and module origin.
-- The seed env is the irreducible pre-env (from Builtins) overlaid
-- with every imported module's exported env, as composed by the
-- module loader. Origin gates bodyless-sig warnings: silent for
-- Embedded (Std.Base), emitted for UserFile.
inferProgramWith
  :: Env -> Origin -> Abs.Module
  -> Either TypeError (Env, [TypedDecl], [Warning])
inferProgramWith seedEnv origin (Abs.Module decls) =
  runTC seedEnv (inferProgramTC origin decls)

-- | Back-compat: keep the v1 signature so existing direct callers
-- (test harness, smoke tests) continue to work. Uses the hand-coded
-- initialEnv as the seed; discards warnings; tags the file as UserFile
-- with a placeholder path.
inferProgram :: Abs.Module -> Either TypeError (Env, [TypedDecl])
inferProgram m =
  case inferProgramWith Builtins.initialEnv (UserFile "<unknown>") m of
    Left err -> Left err
    Right (env, decls, _warnings) -> Right (env, decls)
```

(Add `import Wok.SourceOrigin (Origin (..))` at the top of the module.)

- [ ] **Step 3: Plumb `origin` through `inferProgramTC` and the let-group machinery**

Change the signature of `inferProgramTC` to take an `Origin` and to return warnings:

```haskell
inferProgramTC :: Origin -> [Abs.Decl] -> TC s (Env, [TypedDecl], [Warning])
inferProgramTC origin decls = do
  env1 <- processDataDecls Builtins.initialEnv decls
  -- ^ NOTE: still uses Builtins.initialEnv here, NOT the seed env from
  -- inferProgramWith. After Task 10 the cutover will switch this to
  -- the seed env. We touch only what's needed for the warnings/bodyless
  -- changes in this task.
  let localDecls = concatMap toLocalDecl decls
  withEnv (const env1) $ do
    (schemes, warnings) <- inferTopLetGroup origin localDecls
    env2 <- currentEnv
    let finalEnv = foldr (\(n, s) e -> extendVar n s e) env2 schemes
    pure (finalEnv, [TypedDecl n s | (n, s) <- schemes], warnings)
```

Wait — `inferProgramTC` must take the `seedEnv` too, otherwise the loader can't pass it in. Update further:

```haskell
inferProgramTC
  :: Env -> Origin -> [Abs.Decl] -> TC s (Env, [TypedDecl], [Warning])
inferProgramTC seedEnv origin decls = do
  env1 <- processDataDecls seedEnv decls
  let localDecls = concatMap toLocalDecl decls
  withEnv (const env1) $ do
    (schemes, warnings) <- inferTopLetGroup origin localDecls
    env2 <- currentEnv
    let finalEnv = foldr (\(n, s) e -> extendVar n s e) env2 schemes
    pure (finalEnv, [TypedDecl n s | (n, s) <- schemes], warnings)
```

Update `inferProgramWith` to pass `seedEnv` through:

```haskell
inferProgramWith seedEnv origin (Abs.Module decls) =
  runTC seedEnv (inferProgramTC seedEnv origin decls)
```

- [ ] **Step 4: Update `inferTopLetGroup` to emit bodyless bindings + warnings**

Find `inferTopLetGroup` (line ~781). New shape:

```haskell
inferTopLetGroup
  :: Origin -> [Abs.LocalDecl] -> TC s ([(Text, Scheme)], [Warning])
inferTopLetGroup origin localDecls = do
  let (sigs, eqns) = partitionLocalDecls localDecls
  sigMap <- buildSigMap sigs
  let groups = groupEquations eqns
  unified <- enterLevel $ do
    placeholders <- mapM (allocatePlaceholderTVar sigMap) groups
    let monoRec = foldr (\(n, tv, _) m -> Map.insert n tv m) Map.empty placeholders
    mapM (unifyGroupWith monoRec) placeholders
  results <- mapM (finalizeGroup sigMap) unified
  let coveredEqn   = Set.fromList (map fst groups)
      sigOnlyNames = [ n | (n, _) <- Map.toList sigMap, not (Set.member n coveredEqn) ]
      sigOnlyBindings = [ (n, s) | n <- sigOnlyNames, Just s <- [Map.lookup n sigMap] ]
      warnings = case origin of
        Embedded -> []
        UserFile _ ->
          [ BodylessBinding n (sigPos sigs n) | n <- sigOnlyNames ]
  topResults <- forM results $ \case
    Right (n, s) -> pure (n, s)
    Left (n, _) -> error
      ("inferTopLetGroup: unexpected escape for top-level binding "
      ++ Tx.unpack n)
  pure (topResults ++ sigOnlyBindings, warnings)
```

And a helper to pull the position out of the original sig list (the sig's position is whatever the `LDSig`'s `VarId` carries):

```haskell
-- | Find the BNFC'Position of the LDSig that declared `name`. Returns
-- the position of the first matching LDSig. Defensive `Nothing` only
-- happens when called with a name not in `sigs`, which is a caller bug.
sigPos :: [Abs.LocalDecl] -> Text -> BNFC'Position
sigPos sigs name = go sigs
  where
    go [] = Nothing  -- should be unreachable; the caller filtered for known names
    go (Abs.LDSig (Abs.VarId (p, n)) extras _ : rest)
      | n == name = Just p
      | any (\(Abs.VICons (Abs.VarId (_, x))) -> x == name) extras = Just p
      | otherwise = go rest
    go (_ : rest) = go rest
```

(Add `import qualified Data.Set as Set` if not present.)

- [ ] **Step 5: Apply the same bodyless fix to `inferLetGroup` (for let blocks)**

Find `inferLetGroup` (line ~566). The same logic applies: after computing `results`, walk `sigMap` for the complement of equation groups and add bodyless bindings to the env. For let blocks we do NOT emit warnings (let-block bodyless sigs are a separate future warning). The change:

```haskell
inferLetGroup mono decls k = do
  let (sigs, eqns) = partitionLocalDecls decls
  sigMap <- buildSigMap sigs
  let groups = groupEquations eqns
  unified <- enterLevel $ do
    placeholders <- mapM (allocatePlaceholderTVar sigMap) groups
    let monoRec = foldr (\(n, tv, _) m -> Map.insert n tv m) mono placeholders
    mapM (unifyGroupWith monoRec) placeholders
  results <- mapM (finalizeGroup sigMap) unified
  let monoBindings = [ (n, tv) | Left  (n, tv) <- results ]
      polyBindings = [ (n, s)  | Right (n, s)  <- results ]
      coveredEqn   = Set.fromList (map fst groups)
      sigOnlyBindings = [ (n, s) | (n, s) <- Map.toList sigMap
                                 , not (Set.member n coveredEqn) ]
      mono'   = foldr (\(n, tv) m -> Map.insert n tv m) mono monoBindings
      extend2 = foldr (.) id [ extendVarTC n s | (n, s) <- polyBindings ++ sigOnlyBindings ]
  extend2 (k mono')
```

(No warning emission here — let-block bodyless warnings are a future concern.)

- [ ] **Step 6: Re-export from `Wok.TypeChecking.hs`**

Open `src/Wok/TypeChecking.hs`. Update the export list:

```haskell
module Wok.TypeChecking
  ( inferProgram
  , inferProgramWith
  , prettyScheme
  , TypedDecl (..)
  , TypeError (..)
  , Warning (..)
  , Env (..)
  , ConInfo (..)
  , TyConInfo (..)
  , Scheme (..)
  , CType (..)
  , CRow (..)
  , Kind (..)
  , TyCon (..)
  , Origin (..)
  , originPath
  ) where

import Wok.SourceOrigin (Origin (..), originPath)
import Wok.TypeChecking.Env (Env (..), ConInfo (..), TyConInfo (..))
import Wok.TypeChecking.Error (TypeError (..))
import Wok.TypeChecking.Infer
  ( TypedDecl (..)
  , Warning (..)
  , inferProgram
  , inferProgramWith
  , prettyScheme
  )
import Wok.TypeChecking.Types
  ( CRow (..), CType (..), Kind (..), Scheme (..), TyCon (..) )
```

- [ ] **Step 7: Add new tests**

Open `test/Spec.hs`. Add:

```haskell
bodylessSigTests :: TestTree
bodylessSigTests = testGroup "Wok.TypeChecking.Infer (bodyless sigs)"
  [ testCase "bodyless sig becomes a visible binding (top-level)" $
      let src = "myConst : a -> a\n"
          result = case parse (T.pack src) of
            Right ast ->
              case reorderModule ast of
                Right rm  -> TC.inferProgram (reorderedAst rm)
                Left  es  -> Left (TErr.UnknownVar Nothing
                                     (T.pack ("setup: " ++ show es)))
            Left err -> Left (TErr.UnknownVar Nothing (T.pack ("setup: " ++ err)))
      in case result of
           Right (env, _) ->
             case TE.lookupVar (T.pack "myConst") env of
               Just s ->
                 -- Scheme should be forall a. a -> a, NOT frozen.
                 case s of
                   Ty.Scheme [(_, Ty.KStar)]
                     (Ty.CTArr (Ty.CTGen i) Ty.CREmpty (Ty.CTGen j))
                     | i == j -> pure ()
                   other -> assertFailure ("unexpected scheme: " ++ show other)
               Nothing -> assertFailure "myConst missing from env"
           Left e -> assertFailure ("unexpected error: " ++ show e)

  , testCase "UserFile bodyless sig emits exactly one warning" $
      let src = "myConst : a -> a\n"
          result = case parse (T.pack src) of
            Right ast -> case reorderModule ast of
              Right rm -> TC.inferProgramWith B.initialEnv
                            (TC.UserFile "<test>") (reorderedAst rm)
              Left  es -> error ("setup: " ++ show es)
            Left err -> error ("setup: " ++ err)
      in case result of
           Right (_env, _decls, warnings) ->
             case warnings of
               [TC.BodylessBinding n _] -> n @?= T.pack "myConst"
               other -> assertFailure ("expected one BodylessBinding, got: " ++ show other)
           Left e -> assertFailure ("unexpected error: " ++ show e)

  , testCase "Embedded bodyless sig emits zero warnings" $
      let src = "myConst : a -> a\n"
          result = case parse (T.pack src) of
            Right ast -> case reorderModule ast of
              Right rm -> TC.inferProgramWith B.initialEnv
                            TC.Embedded (reorderedAst rm)
              Left  es -> error ("setup: " ++ show es)
            Left err -> error ("setup: " ++ err)
      in case result of
           Right (_, _, []) -> pure ()
           Right (_, _, ws) -> assertFailure ("expected no warnings, got: " ++ show ws)
           Left e -> assertFailure ("unexpected error: " ++ show e)

  , testCase "multi-name bodyless sig emits one warning per name" $
      let src = "a, b, c : Int\n"
          result = case parse (T.pack src) of
            Right ast -> case reorderModule ast of
              Right rm -> TC.inferProgramWith B.initialEnv
                            (TC.UserFile "<test>") (reorderedAst rm)
              Left  es -> error ("setup: " ++ show es)
            Left err -> error ("setup: " ++ err)
      in case result of
           Right (_, _, warnings) ->
             length warnings @?= 3
           Left e -> assertFailure ("unexpected error: " ++ show e)
  ]
```

Add `bodylessSigTests` to the `defaultMain` test list.

- [ ] **Step 8: Build and test**

```bash
cabal build 2>&1 | tail -5
cabal test --test-options="-p bodyless" 2>&1 | tail -30
cabal test 2>&1 | tail -10
```

Expected: bodyless tests pass; entire suite passes (back-compat preserved).

- [ ] **Step 9: Commit**

```bash
git add src/Wok/TypeChecking/Infer.hs src/Wok/TypeChecking.hs test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(typecheck): warning channel + bodyless sig support + inferProgramWith

* Adds Warning ADT (single variant BodylessBinding for v1).
* Adds inferProgramWith :: Env -> Origin -> Module -> Either TypeError
  (Env, [TypedDecl], [Warning]) so the loader can seed an env and gate
  warnings on origin.
* Fixes a latent bug: bodyless LDSig/DSig were silently dropped
  (registered into sigMap but never made it into envVars). Now they
  enter the env with the declared scheme verbatim (no freezeSig).
* Warnings: bodyless top-level sigs in UserFile origin emit one
  BodylessBinding per name; Embedded origin is silent.
* Existing inferProgram retained as a thin wrapper (back-compat for
  tests and direct callers).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Create `Wok.Prelude` with placeholder embedded source

**Goal:** A new module that exposes the embedded `Std.Base` source as `Text`, using `file-embed`. The actual content lands in Task 10; this task ships with a placeholder so the module compiles and embedding plumbing is verified.

**Files:**
- Create: `prelude/Std/Base.wok` (placeholder content)
- Create: `src/Wok/Prelude.hs`
- Modify: `wok.cabal` (add `Wok.Prelude` to exposed-modules; add `file-embed` to build-depends; add `prelude/Std/Base.wok` to extra-source-files)

**Acceptance Criteria:**
- [ ] `prelude/Std/Base.wok` exists with at least `module Std.Base\n`.
- [ ] `src/Wok/Prelude.hs` exports `preludeName :: Text` (`"Std.Base"`) and `preludeSource :: Text`.
- [ ] `preludeSource` is the runtime-decoded content of `prelude/Std/Base.wok`, sourced via `Data.FileEmbed.embedStringFile` (TH).
- [ ] `wok.cabal` lists `Wok.Prelude` under `exposed-modules`, `file-embed` under `build-depends`, and `prelude/Std/Base.wok` under `extra-source-files`.
- [ ] `cabal build` succeeds.
- [ ] A smoke test asserts `Wok.Prelude.preludeName == "Std.Base"` and `Tx.length preludeSource > 0`.

**Verify:** `cabal test --test-options="-p prelude"` passes.

**Steps:**

- [ ] **Step 1: Create the placeholder Prelude file**

Create `prelude/Std/Base.wok`:

```wok
module Std.Base

-- Placeholder. Real content lands with the cutover (plan Task 10):
--   * data Bool = True | False
--   * data Option a = Some a | None
--   * data Result t e = Ok t | Err e
--   * fixity decls + operator signatures (bodyless)
--   * id, const
```

- [ ] **Step 2: Add `file-embed` to cabal**

Open `wok.cabal`. In the hand-written `library` section's `build-depends` (around line 60-67), add `file-embed`:

```cabal
    build-depends:
        base         ^>=4.20,
        array        ^>=0.5,
        containers,
        file-embed,
        mtl,
        text,
        transformers,
        wok:wok-generated,
```

Add `prelude/Std/Base.wok` to the top-level extra-source-files. If there isn't one yet, add:

```cabal
extra-source-files:
    CHANGELOG.md
    prelude/Std/Base.wok
```

(Note: `extra-doc-files` already exists for CHANGELOG.md. Use a new `extra-source-files` field for the Prelude so it's tracked as source.)

Add `Wok.Prelude` to the library's `exposed-modules` block:

```cabal
    exposed-modules:
        Wok.Parsing
        Wok.Prelude
        Wok.Reordering
        Wok.SourceOrigin
        Wok.TypeChecking
        ...
```

- [ ] **Step 3: Write `Wok.Prelude`**

Create `src/Wok/Prelude.hs`:

```haskell
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The embedded Std.Base Prelude source.
--
-- The text of prelude/Std/Base.wok is baked into the wok binary at
-- build time via Data.FileEmbed.embedStringFile. The compiler's loader
-- unconditionally inserts a LoadedModule keyed "Std.Base" into the
-- module map before processing any user files, using this Text as the
-- module's source. Rebuild the binary to ship new Prelude content;
-- there is no runtime disk lookup.
module Wok.Prelude
  ( preludeName
  , preludeSource
  ) where

import Data.FileEmbed (embedStringFile)
import Data.Text (Text)
import qualified Data.Text as Tx

preludeName :: Text
preludeName = Tx.pack "Std.Base"

-- File path is relative to the cabal project root (where wok.cabal lives).
preludeSource :: Text
preludeSource = Tx.pack $(embedStringFile "prelude/Std/Base.wok")
```

- [ ] **Step 4: Add a smoke test**

Open `test/Spec.hs`. Add an import:

```haskell
import qualified Wok.Prelude as Prelude
```

Add a test group:

```haskell
preludeTests :: TestTree
preludeTests = testGroup "Wok.Prelude"
  [ testCase "preludeName is Std.Base" $
      Prelude.preludeName @?= T.pack "Std.Base"
  , testCase "preludeSource is non-empty" $
      assertBool "expected non-empty preludeSource"
                 (T.length Prelude.preludeSource > 0)
  , testCase "preludeSource contains a module header" $
      assertBool "expected `module Std.Base` in source"
                 (T.isInfixOf (T.pack "module Std.Base") Prelude.preludeSource)
  ]
```

Add `preludeTests` to `defaultMain`.

- [ ] **Step 5: Build and test**

```bash
cabal build 2>&1 | tail -10
cabal test --test-options="-p prelude" 2>&1 | tail -10
```

Expected: build succeeds (TH-embed of the placeholder content), three smoke tests pass.

- [ ] **Step 6: Commit**

```bash
git add prelude/Std/Base.wok src/Wok/Prelude.hs wok.cabal test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(prelude): add embedded Std.Base scaffolding via file-embed

* New prelude/Std/Base.wok placeholder (real content lands at cutover).
* New Wok.Prelude module: preludeName + preludeSource (TH-embedded).
* cabal: Wok.Prelude exposed; file-embed dep; Prelude file tracked
  via extra-source-files.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Create `Wok.Loader`

**Goal:** A new module that loads + parses + builds-fixity-tables for every input file (entry + each `-I` + the embedded Prelude), builds a `Map ModuleName LoadedModule`, validates the import dep graph, and topo-sorts. Not yet wired into `Main` — that happens at the cutover.

**Files:**
- Create: `src/Wok/Loader.hs`
- Modify: `wok.cabal` (add `Wok.Loader` to exposed-modules)
- Test: `test/Spec.hs` — new `loaderTests` group; create `test/loader-fixtures/` for tiny `.wok` files used as inputs

**Acceptance Criteria:**
- [ ] `Wok.Loader` exports: `ModuleName` (type alias), `LoadedModule (..)`, `ModuleMap` (type alias), `LoaderError (..)`, `loadProgram :: FilePath -> [FilePath] -> IO (Either LoaderError [LoadedModule])`.
- [ ] `loadProgram` always returns Std.Base as the first element of the resulting list (topo order — it has no imports so it's a graph root).
- [ ] Returns `LoadFileMissing` if any path doesn't exist; `LoadParseError` on parse failure; `LoadFixityError` on per-module fixity-build failure; `LoadNoModuleHeader` if a file's first decl isn't `DModule`; `LoadDuplicateModule` if two files claim the same module name; `LoadImportUnknown` if a module imports a name not in the map; `LoadImportCycle` if the dep graph has a cycle (including self-import).
- [ ] Returned `LoadedModule`s are sorted topologically (an importer always appears after every module it transitively imports).
- [ ] Unit tests cover all error variants AND the happy path (`Std.Base` + a single user file that imports it).

**Verify:** `cabal test --test-options="-p loader"` passes.

**Steps:**

- [ ] **Step 1: Sketch the module**

Create `src/Wok/Loader.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | Multi-module loader: parse + build fixity tables for the embedded
-- Std.Base + every -I file + the entry, build a module map, validate
-- the import dep graph, and return modules in topo order. Expression
-- reordering and typechecking happen downstream (in the caller, per
-- the design spec) using the per-module fixity tables this loader
-- produces.
module Wok.Loader
  ( ModuleName
  , LoadedModule (..)
  , ModuleMap
  , LoaderError (..)
  , loadProgram
  ) where

import Control.Exception (IOException, try)
import qualified Data.Graph as G
import qualified Data.List
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx
import qualified Data.Text.IO as TIO

import GeneratedParser.Wok.Abs
import Wok.Parsing (parse)
import qualified Wok.Prelude as Prelude
import Wok.Reordering
  ( FixityError, FixityTable, ReorderError, buildFixityTable )
import Wok.SourceOrigin (Origin (..))
import qualified Wok.TypeChecking.Infer as I

type ModuleName = Text
type ModuleMap = Map ModuleName LoadedModule

data LoadedModule = LoadedModule
  { lmName     :: ModuleName
  , lmOrigin   :: Origin
  , lmAst      :: Module       -- post-parse, PRE-reorder
  , lmImports  :: [ModuleName] -- from DImport decls; deduped, source order
  , lmFixities :: FixityTable  -- this module's own DFixity decls only
  }

data LoaderError
  = LoadFileMissing               FilePath
  | LoadParseError                FilePath String
  | LoadFixityError               FilePath [FixityError]
  | LoadReorderError              ModuleName [ReorderError]
  | LoadCrossModuleFixityConflict Text ModuleName ModuleName
  | LoadCrossModuleNameConflict   Text ModuleName ModuleName
  | LoadNoModuleHeader            FilePath
  | LoadDuplicateModule           ModuleName FilePath FilePath
  | LoadImportUnknown             ModuleName ModuleName
  | LoadImportCycle               [ModuleName]
  deriving (Eq, Show)

loadProgram
  :: FilePath        -- entry file
  -> [FilePath]      -- additional -I files (order preserved)
  -> IO (Either LoaderError [LoadedModule])
loadProgram entry extras = do
  preludeRes <- pure (parseAndPrep "<embedded Std.Base>" Embedded Prelude.preludeSource)
  case preludeRes of
    Left err -> pure (Left err)
    Right preludeLM -> do
      extraResults <- mapM loadOne extras
      entryResult  <- loadOne entry
      case sequence (extraResults ++ [entryResult]) of
        Left err  -> pure (Left err)
        Right userLMs ->
          case buildMap (preludeLM : userLMs) of
            Left err  -> pure (Left err)
            Right mm  -> case topoSort mm of
              Left err   -> pure (Left err)
              Right list -> pure (Right list)

-- ---------------------------------------------------------------
-- Reading + parsing one file
-- ---------------------------------------------------------------

loadOne :: FilePath -> IO (Either LoaderError LoadedModule)
loadOne path = do
  bytes <- try (TIO.readFile path) :: IO (Either IOException Text)
  case bytes of
    Left _   -> pure (Left (LoadFileMissing path))
    Right tx -> pure (parseAndPrep path (UserFile path) tx)

parseAndPrep :: FilePath -> Origin -> Text -> Either LoaderError LoadedModule
parseAndPrep path origin src = do
  ast <- case parse src of
    Left err -> Left (LoadParseError path err)
    Right m  -> Right m
  name <- case extractModuleName ast of
    Nothing -> Left (LoadNoModuleHeader path)
    Just n  -> Right n
  fixities <- case buildFixityTable ast of
    Left es -> Left (LoadFixityError path es)
    Right t -> Right t
  let imports = extractImports ast
  Right $ LoadedModule
    { lmName     = name
    , lmOrigin   = origin
    , lmAst      = ast
    , lmImports  = imports
    , lmFixities = fixities
    }

-- The grammar's DModule lives at any position but conventionally first;
-- v1 accepts it as the first decl only.
extractModuleName :: Module -> Maybe ModuleName
extractModuleName (Module (DModule mp : _)) = Just (I.modPathText mp)
extractModuleName _                          = Nothing

extractImports :: Module -> [ModuleName]
extractImports (Module decls) =
  let names = [ I.modPathText mp | DImport mp <- decls ]
  in dedupe names
  where
    dedupe = go Set.empty
    go _ [] = []
    go seen (x : xs)
      | Set.member x seen = go seen xs
      | otherwise         = x : go (Set.insert x seen) xs

-- ---------------------------------------------------------------
-- Map + topo sort
-- ---------------------------------------------------------------

buildMap :: [LoadedModule] -> Either LoaderError ModuleMap
buildMap = foldr step (Right Map.empty)
  where
    step lm acc = do
      m <- acc
      case Map.lookup (lmName lm) m of
        Just prev -> Left $ LoadDuplicateModule
                       (lmName lm)
                       (originAsPath (lmOrigin prev))
                       (originAsPath (lmOrigin lm))
        Nothing -> Right (Map.insert (lmName lm) lm m)
    originAsPath Embedded        = "<embedded Std.Base>"
    originAsPath (UserFile path) = path

-- Topo-sort with cycle and unknown-import detection.
-- Returns modules in dependency order (a module appears after every
-- module it depends on).
topoSort :: ModuleMap -> Either LoaderError [LoadedModule]
topoSort mm = do
  -- Check every import target exists.
  let missing =
        [ (lmName lm, target)
        | lm <- Map.elems mm
        , target <- lmImports lm
        , not (Map.member target mm)
        ]
  case missing of
    ((importer, target) : _) -> Left (LoadImportUnknown importer target)
    [] -> do
      let nodes = [ (lm, lmName lm, lmImports lm) | lm <- Map.elems mm ]
          sccs  = G.stronglyConnComp nodes
      case [cs | G.CyclicSCC cs <- sccs] of
        (cycleMods : _) -> Left (LoadImportCycle (map lmName cycleMods))
        [] -> Right (reverse [lm | G.AcyclicSCC lm <- sccs])
        -- stronglyConnComp returns sinks first; reverse to get sources first.
```

- [ ] **Step 2: Register in cabal**

Open `wok.cabal`. Add `Wok.Loader` to the library's `exposed-modules`. Also add `directory` to `build-depends` if not already there (already in the test deps; check whether needed in library — the loader uses `Control.Exception.try` for missing-file detection, so `directory` isn't strictly required).

```cabal
    exposed-modules:
        Wok.Loader
        Wok.Parsing
        Wok.Prelude
        ...
```

- [ ] **Step 3: Create loader test fixtures**

Create the directory `test/loader-fixtures/`. Add files:

`test/loader-fixtures/01-entry-imports-base.wok`:
```wok
module Main
import Std.Base

f x = x
```

`test/loader-fixtures/02-no-header.wok`:
```wok
f x = x
```

`test/loader-fixtures/03-unknown-import.wok`:
```wok
module Main
import Foo.Bar
```

`test/loader-fixtures/04-cycle-a.wok`:
```wok
module A
import B
```

`test/loader-fixtures/04-cycle-b.wok`:
```wok
module B
import A
```

`test/loader-fixtures/05-self-import.wok`:
```wok
module Main
import Main
```

`test/loader-fixtures/06-dup-a.wok`:
```wok
module Dup
f = 1
```

`test/loader-fixtures/06-dup-b.wok`:
```wok
module Dup
g = 2
```

- [ ] **Step 4: Write loader tests**

Open `test/Spec.hs`. Add imports:

```haskell
import qualified Wok.Loader as Loader
```

Add a test group:

```haskell
loaderTests :: TestTree
loaderTests = testGroup "Wok.Loader"
  [ testCase "loads entry + embedded Std.Base; topo order is Prelude first" $ do
      res <- Loader.loadProgram "test/loader-fixtures/01-entry-imports-base.wok" []
      case res of
        Right modules -> do
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
  ]
```

Add `loaderTests` to the `defaultMain` test list.

- [ ] **Step 5: Build and test**

```bash
cabal build 2>&1 | tail -10
cabal test --test-options="-p loader" 2>&1 | tail -30
```

Expected: all loader tests pass.

- [ ] **Step 6: Run full suite to confirm no regression**

```bash
cabal test 2>&1 | tail -10
```

Expected: zero failures.

- [ ] **Step 7: Commit**

```bash
git add src/Wok/Loader.hs wok.cabal test/loader-fixtures/ test/Spec.hs
git commit -m "$(cat <<'EOF'
feat(loader): add Wok.Loader (module map + dep graph + topo sort)

* loadProgram :: FilePath -> [FilePath] -> IO (Either LoaderError [LoadedModule])
* Always seeds the embedded Std.Base into the module map first.
* Header validation, duplicate detection, import resolution, cycle
  detection (including self-import), topological sort.
* Per-module FixityTable built at load time; expression reordering
  is deferred to typecheck time (when cross-module fixities can be
  merged).
* Not yet wired into Main — cutover happens with the bigger
  Std.Base population change.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2: Mechanical `TcInt → TcU64` rename

### Task 9: Rename `TcInt` to `TcU64` across code and test fixtures

**Goal:** Mechanical rename of the integer tycon constructor (`TcInt → TcU64`), the env key string (`"Int" → "u64"`), and every test fixture / golden referencing either. Pure-rename; no behavioural change.

**Files:**
- Modify: `src/Wok/TypeChecking/Types.hs` (constructor)
- Modify: `src/Wok/TypeChecking/Builtins.hs` (env entry key + scheme constructors)
- Modify: `src/Wok/TypeChecking/Infer.hs` (`resolveTyCon`, `prettyCType`, integer-literal type)
- Modify: every `test/typecheck-examples/*.wok` (`Int → u64`)
- Modify: every `test/typecheck-golden/*.expected` (`Int → u64`)
- Modify: every `test/typecheck-fail-examples/*.wok` (`Int → u64`)
- Modify: every `test/typecheck-fail-golden/*.expected` (`TcInt → TcU64`, `Int → u64`)
- Modify: `test/Spec.hs` (`Ty.TcInt → Ty.TcU64`)

**Acceptance Criteria:**
- [ ] `grep -RIn "TcInt\b" src test app` returns no matches.
- [ ] `grep -wn "Int" test/typecheck-examples test/typecheck-fail-examples` returns no matches (every fixture uses `u64`).
- [ ] `Builtins.initialEnv`'s tycon entry uses `"u64"` as the key with `TcU64`-resolvable type ctor.
- [ ] All tests pass (mechanical rename → no behaviour change).

**Verify:** `cabal test 2>&1 | tail -10` shows no failures; greps above return empty.

**Steps:**

- [ ] **Step 1: Rename the constructor**

Open `src/Wok/TypeChecking/Types.hs`. Find the `TyCon` data definition (line ~39):

```haskell
data TyCon
  = TcU64       -- was TcInt
  | TcChar
  | TcString
  | TcBool
  | TcUnit
  | TcTuple Int
  | TcList
  | TcUser Text
  deriving (Eq, Show)
```

- [ ] **Step 2: Update `Builtins.hs`**

Open `src/Wok/TypeChecking/Builtins.hs`. Update the tycon entry list (~line 28-36):

```haskell
    tyConEntries =
      [ ("u64",    TyConInfo KStar 0 [])    -- was "Int"
      , ("Char",   TyConInfo KStar 0 [])
      , ("String", TyConInfo KStar 0 [])
      , ("Bool",   TyConInfo KStar 0 ["True", "False"])
      , ("()",     TyConInfo KStar 0 [])
      , ("[]",     TyConInfo listKind 1 [])
      ] ++ [ (tupleName n, TyConInfo (tupleKind n) n []) | n <- [2 .. 16] ]
```

Update all `CTCon TcInt []` to `CTCon TcU64 []` in the operator schemes (intBinop, intToBool, listConcat, etc. — lines ~65-85):

```haskell
    intBinop = Scheme []
      (CTArr (CTCon TcU64 []) CREmpty
        (CTArr (CTCon TcU64 []) CREmpty (CTCon TcU64 [])))

    intToBool = Scheme []
      (CTArr (CTCon TcU64 []) CREmpty
        (CTArr (CTCon TcU64 []) CREmpty (CTCon TcBool [])))
```

(Leave the helper names `intBinop` and `intToBool` for now — Task 10 deletes these entries entirely.)

- [ ] **Step 3: Update `Infer.hs`**

Open `src/Wok/TypeChecking/Infer.hs`. Update `resolveTyCon` (line ~250):

```haskell
resolveTyCon :: Text -> TyCon
resolveTyCon name
  | name == Tx.pack "u64"    = TcU64
  | name == Tx.pack "Char"   = TcChar
  | name == Tx.pack "String" = TcString
  | name == Tx.pack "Bool"   = TcBool
  | name == Tx.pack "()"     = TcUnit
  | name == Tx.pack "[]"     = TcList
  | otherwise                = TcUser name
```

Update `prettyCType` (line ~824):

```haskell
prettyCType (CTCon TcU64    []) = Tx.pack "u64"
```

Update integer-literal inference (lines ~393, ~448):

```haskell
inferAtomPat (Abs.APLitI _) = pure (TCon TcU64 [], [])
...
inferExprW _ (Abs.ELitI _) = pure (TCon TcU64 [])
```

- [ ] **Step 4: Bulk-rename in test fixtures**

For each `.wok` file in `test/typecheck-examples/` and `test/typecheck-fail-examples/`, replace surface-syntax `Int` with `u64`. Use a Haskell-aware editor or careful sed (DO NOT use a naive `sed -i 's/Int/u64/g'` because tycon `Int` appears as a substring inside the constructor `TcInt` elsewhere — but these directories should only have `.wok` files, not `.hs`, so it's safer here):

```bash
for f in test/typecheck-examples/*.wok test/typecheck-fail-examples/*.wok; do
  sed -i.bak 's/\bInt\b/u64/g' "$f" && rm "$f.bak"
done
```

Similarly, update the goldens:

```bash
for f in test/typecheck-golden/*.expected test/typecheck-fail-golden/*.expected; do
  sed -i.bak -e 's/\bInt\b/u64/g' -e 's/\bTcInt\b/TcU64/g' "$f" && rm "$f.bak"
done
```

(The `\b` word-boundary anchors are crucial — without them, `Integer` or `Interval` would be corrupted, but neither appears in these fixtures.)

Verify the result by skimming a couple:

```bash
cat test/typecheck-examples/02-arithmetic.wok
cat test/typecheck-golden/02-arithmetic.expected
cat test/typecheck-fail-golden/01-mismatch.expected
```

- [ ] **Step 5: Update `test/Spec.hs`**

Replace every `Ty.TcInt` with `Ty.TcU64`. There are ~20 occurrences (per the earlier grep).

```bash
sed -i.bak 's/Ty\.TcInt/Ty.TcU64/g' test/Spec.hs && rm test/Spec.hs.bak
```

- [ ] **Step 6: Build and test**

```bash
cabal build 2>&1 | tail -10
cabal test 2>&1 | tail -20
```

Expected: build succeeds; all tests pass (the rename is purely mechanical).

- [ ] **Step 7: Verify nothing leaked**

```bash
grep -RIn "TcInt\b" src test app
grep -wn "Int" test/typecheck-examples test/typecheck-fail-examples test/typecheck-golden test/typecheck-fail-golden
```

Both expected: empty.

- [ ] **Step 8: Commit**

```bash
git add src/Wok/TypeChecking/Types.hs src/Wok/TypeChecking/Builtins.hs src/Wok/TypeChecking/Infer.hs test/
git commit -m "$(cat <<'EOF'
refactor(types): rename TcInt -> TcU64; integer surface name is now `u64`

Mechanical rename: TyCon constructor TcInt -> TcU64, env key "Int" ->
"u64", surface tycon `Int` -> `u64` in every test fixture and golden.
Integer literals now infer as u64. Pure refactor; no behaviour change.

This is the precursor to the Std.Base cutover (next commit), which
removes the operator schemes from Builtins.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 3: The cutover

### Task 10: Populate `Std.Base` + shrink Builtins + rewrite Main + migrate test harness + fixtures

**Goal:** The atomic switch. Populate `prelude/Std/Base.wok` with the real Prelude content; shrink `Builtins.initialEnv` to just the unspellable irreducible tycons; rewrite `app/Main.hs` to use `Wok.Loader` + the new typecheck pipeline; update the test harness to route through the Loader; migrate every existing typecheck fixture to use `module Main; import Std.Base` plus the new spellings (`Maybe → Option`, `Either → Result`, `data List` → built-in `[]`, etc.).

**Files:**
- Modify: `prelude/Std/Base.wok` — write the real content
- Modify: `src/Wok/TypeChecking/Builtins.hs` — shrink to irreducible pre-env
- Modify: `src/Wok/TypeChecking/Infer.hs` — `inferProgramTC` now uses the seed env from `inferProgramWith` (drop the hard-coded `Builtins.initialEnv` reference inside)
- Modify: `app/Main.hs` — full rewrite (CLI parsing, Loader integration, per-module typecheck fold, pretty-printers, warning emission)
- Modify: `test/Spec.hs` — change `typecheckSuccessHarness` and `typecheckFailHarness` to route through the Loader
- Modify: every `test/typecheck-examples/*.wok` (add `module Main; import Std.Base`; replace data decls / type names per Std.Base)
- Modify: every `test/typecheck-fail-examples/*.wok` (add header + import)

**Acceptance Criteria:**
- [ ] `prelude/Std/Base.wok` contains: fixity decls, `data Bool / Option / Result`, bodyless operator sigs (+, -, *, /, div, mod, ==, /=, &&, ||, ++, $), `id`, `const`.
- [ ] `Builtins.initialEnv` exports only u64, (), [], and the 15-tuple family in `envTyCons`. `envCons` and `envVars` are `Map.empty`.
- [ ] `app/Main.hs` accepts `wok <entry> [-I file]…`; errors with usage line on bad CLI; runs the new pipeline; prints warnings to stderr and the entry module's typed decls to stdout.
- [ ] Test harness uses Loader + new pipeline; existing typecheck-success and typecheck-fail goldens still pass (after fixture migration).
- [ ] Every `test/typecheck-examples/*.wok` starts with `module Main\nimport Std.Base\n`.
- [ ] Fixtures previously declaring `data Maybe` / `data Either` / `data List` are rewritten to use Std.Base's `Option` / `Result` / built-in `[]`.
- [ ] `cabal build` succeeds.
- [ ] `cabal test 2>&1` shows zero failures.

**Verify:** `cabal test 2>&1 | tail -20` shows the entire suite green; `wok test/typecheck-examples/02-arithmetic.wok` prints the expected typed decls.

**Steps:**

- [ ] **Step 1: Populate `prelude/Std/Base.wok`**

Replace the placeholder with the real content:

```wok
module Std.Base

fixity + left
fixity - left
fixity * left tighter than +
fixity / left tighter than +
fixity == left looser than +
fixity /= left looser than +
fixity && left looser than ==
fixity || left looser than &&
fixity ++ right
fixity $  right looser than ||

data Bool = True | False
data Option a = Some a | None
data Result t e = Ok t | Err e

(+)  : u64 -> u64 -> u64
(-)  : u64 -> u64 -> u64
(*)  : u64 -> u64 -> u64
(/)  : u64 -> u64 -> u64
div  : u64 -> u64 -> u64
mod  : u64 -> u64 -> u64
(==) : u64 -> u64 -> Bool
(/=) : u64 -> u64 -> Bool
(&&) : Bool -> Bool -> Bool
(||) : Bool -> Bool -> Bool
(++) : [a] -> [a] -> [a]
($)  : (a -> b) -> a -> b

id : a -> a
id x = x

const : a -> b -> a
const x y = x
```

(No `data Char`, `data String` — those tycons are dropped per spec.)

- [ ] **Step 2: Shrink `Builtins.initialEnv`**

Open `src/Wok/TypeChecking/Builtins.hs`. Replace the entire body:

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | The irreducible pre-environment. Everything spellable in Wok lives
-- in Std.Base (loaded by Wok.Loader before user code). Only the tycons
-- that cannot be expressed in surface Wok stay here:
--
--   * u64                  -- opaque machine integer
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
import Wok.TypeChecking.Env (Env (..), TyConInfo (..), emptyEnv)
import Wok.TypeChecking.Types (Kind (..))

initialEnv :: Env
initialEnv = emptyEnv
  { envTyCons = Map.fromList tyConEntries
  }
  where
    listKind :: Kind
    listKind = KArrow KStar KStar

    tyConEntries :: [(Text, TyConInfo)]
    tyConEntries =
      [ ("u64", TyConInfo KStar 0 [])
      , ("()",  TyConInfo KStar 0 [])
      , ("[]",  TyConInfo listKind 1 [])
      ] ++ [ (tupleName n, TyConInfo (tupleKind n) n []) | n <- [2 .. 16] ]

    tupleName :: Int -> Text
    tupleName n = "(" <> Data.Text.replicate (n - 1) "," <> ")"

    tupleKind :: Int -> Kind
    tupleKind n = foldr KArrow KStar (replicate n KStar)
```

- [ ] **Step 3: Update `Infer.inferProgramTC` to consume the seed env**

Open `src/Wok/TypeChecking/Infer.hs`. `inferProgramTC` currently calls `processDataDecls Builtins.initialEnv decls`. Change it to use the `seedEnv` parameter:

```haskell
inferProgramTC
  :: Env -> Origin -> [Abs.Decl] -> TC s (Env, [TypedDecl], [Warning])
inferProgramTC seedEnv origin decls = do
  env1 <- processDataDecls seedEnv decls
  let localDecls = concatMap toLocalDecl decls
  withEnv (const env1) $ do
    (schemes, warnings) <- inferTopLetGroup origin localDecls
    env2 <- currentEnv
    let finalEnv = foldr (\(n, s) e -> extendVar n s e) env2 schemes
    pure (finalEnv, [TypedDecl n s | (n, s) <- schemes], warnings)
```

The back-compat `inferProgram` (which calls `inferProgramWith Builtins.initialEnv ...`) automatically gets the new shrunken `initialEnv`. After this step it will produce TypeErrors when called against fixtures that reference `Bool`/`+`/etc — but those fixtures will be updated in Step 7 to go through the new harness instead.

- [ ] **Step 4: Rewrite `app/Main.hs`**

Replace the entire file:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.List (sortBy)
import qualified Data.Map.Strict as Map
import Data.Ord (comparing)
import qualified Data.Text as Tx
import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Wok.Loader
  ( LoadedModule (..)
  , LoaderError (..)
  , ModuleName
  , loadProgram
  )
import Wok.Reordering
  ( FixityTable
  , emptyFixityTable
  , overlayFixities
  , reorderModuleWith
  )
import Wok.SourceOrigin (Origin (..), originPath)
import qualified Wok.TypeChecking as TC
import qualified Wok.TypeChecking.Builtins as B
import Wok.TypeChecking.Env (Env, overlayEnvs, EnvNs (..))

-- ----------------------------------------------------------------
-- CLI
-- ----------------------------------------------------------------

usage :: String
usage = "usage: wok <entry.wok> [-I <file.wok>]..."

main :: IO ()
main = do
  args <- getArgs
  case parseCli args of
    Left msg          -> hPutStrLn stderr msg >> exitFailure
    Right (e, extras) -> runApp e extras

parseCli :: [String] -> Either String (FilePath, [FilePath])
parseCli = go Nothing []
  where
    go (Just e) xs []                  = Right (e, reverse xs)
    go Nothing  _  []                  = Left usage
    go _        _  ("-I" : [])         = Left ("-I requires an argument\n" ++ usage)
    go e        xs ("-I" : f : rest)   = go e (f : xs) rest
    go Nothing  xs (a : rest)          = go (Just a) xs rest
    go (Just _) _  (a : _)             =
      Left ("unexpected extra positional: " ++ a ++ "\n" ++ usage)

-- ----------------------------------------------------------------
-- App
-- ----------------------------------------------------------------

data PipelineError
  = PErrLoader  LoaderError
  | PErrReorder ModuleName String
  | PErrEnv     ModuleName [(EnvNs, Tx.Text)]
  | PErrType    ModuleName TC.TypeError

runApp :: FilePath -> [FilePath] -> IO ()
runApp entry extras = do
  loaded <- loadProgram entry extras
  case loaded of
    Left lerr -> hPutStrLn stderr (prettyLoaderError lerr) >> exitFailure
    Right ms  -> case typecheckAll ms of
      Left perr -> hPutStrLn stderr (prettyPipelineError perr) >> exitFailure
      Right (typedMap, warnings) -> do
        mapM_ (hPutStrLn stderr . prettyWarning) warnings
        let entryName = lmName (last ms)
        case Map.lookup entryName typedMap of
          Nothing ->
            hPutStrLn stderr ("internal: entry module " ++ Tx.unpack entryName
                              ++ " missing from typed map") >> exitFailure
          Just decls ->
            mapM_ printDecl (sortBy (comparing TC.tdName) decls)
  where
    printDecl (TC.TypedDecl n s) =
      TIO.putStrLn (n <> Tx.pack " : " <> TC.prettyScheme s)

-- ----------------------------------------------------------------
-- Per-module typecheck fold
-- ----------------------------------------------------------------

-- | Fold the typechecker over modules in topo order. Each module sees
-- the irreducible pre-env merged with every imported module's exports,
-- and its expression reordering is seeded with the merged fixity table
-- of its imports.
typecheckAll
  :: [LoadedModule]
  -> Either PipelineError (Map.Map ModuleName [TC.TypedDecl], [TC.Warning])
typecheckAll modules = go modules Map.empty Map.empty Map.empty []
  where
    -- typedDeclsMap tracks decls per module for final printing.
    -- envsByMod / fixByMod track per-module exports for downstream importers.
    go [] typedDecls _envs _fix warnings =
      Right (typedDecls, reverse warnings)
    go (m : rest) typedDecls envsByMod fixByMod warnings = do
      let importNames = lmImports m
          importedEnvs =
            [ envsByMod Map.! n | n <- importNames, Map.member n envsByMod ]
          importedFixs =
            [ fixByMod Map.! n | n <- importNames, Map.member n fixByMod ]

      -- Merge fixities: foldM overlayFixities with the module's own table.
      mergedFix <- foldMEither overlayFixities emptyFixityTable importedFixs
        |> wrapFixErr m
      mergedFix' <- overlayFixities mergedFix (lmFixities m)
        |> wrapFixErr m

      -- Merge envs: start from irreducible pre-env, overlay imports.
      mergedEnv <- foldMEither overlayEnvs B.initialEnv importedEnvs
        |> wrapEnvErr m

      -- Reorder this module's expressions with merged fixities.
      reordered <- case reorderModuleWith mergedFix' (lmAst m) of
        Left errs -> Left (PErrReorder (lmName m) (show errs))
        Right ast -> Right ast

      -- Typecheck.
      case TC.inferProgramWith mergedEnv (lmOrigin m) reordered of
        Left tcerr -> Left (PErrType (lmName m) tcerr)
        Right (envOut, decls, ws) ->
          go rest
             (Map.insert (lmName m) decls typedDecls)
             (Map.insert (lmName m) envOut envsByMod)
             (Map.insert (lmName m) (lmFixities m) fixByMod)
             (reverse ws ++ warnings)

    foldMEither
      :: (b -> a -> Either e b) -> b -> [a] -> Either e b
    foldMEither _ acc [] = Right acc
    foldMEither f acc (x : xs) = case f acc x of
      Left e   -> Left e
      Right acc' -> foldMEither f acc' xs

    wrapFixErr m (Left fes) =
      -- Attribute the conflict to (m, m) for v1; we lose the "other module"
      -- side here. Future improvement: track which prior module each fixity
      -- came from.
      Left (PErrReorder (lmName m) (show fes))
    wrapFixErr _ (Right t)  = Right t

    wrapEnvErr m (Left clashes) = Left (PErrEnv (lmName m) clashes)
    wrapEnvErr _ (Right e)      = Right e

    (|>) :: a -> (a -> b) -> b
    x |> f = f x
    infixl 1 |>

-- ----------------------------------------------------------------
-- Pretty-printers
-- ----------------------------------------------------------------

prettyLoaderError :: LoaderError -> String
prettyLoaderError = \case
  LoadFileMissing p ->
    "error: file not found: " <> p
  LoadParseError p msg ->
    "parse error in " <> p <> ": " <> msg
  LoadFixityError p errs ->
    "fixity error in " <> p <> ":\n" <> unlines (map (("  " <>) . show) errs)
  LoadReorderError n errs ->
    "reorder error in module " <> Tx.unpack n <> ":\n"
      <> unlines (map (("  " <>) . show) errs)
  LoadCrossModuleFixityConflict op a b ->
    "error: fixity for `" <> Tx.unpack op <> "` declared in both "
      <> Tx.unpack a <> " and " <> Tx.unpack b
  LoadCrossModuleNameConflict name a b ->
    "error: name `" <> Tx.unpack name <> "` exported by both "
      <> Tx.unpack a <> " and " <> Tx.unpack b
  LoadNoModuleHeader p ->
    "error: " <> p <> " is missing a `module X.Y` header (must be the first declaration)"
  LoadDuplicateModule n p1 p2 ->
    "error: module " <> Tx.unpack n <> " is declared in both " <> p1 <> " and " <> p2
  LoadImportUnknown m target ->
    "error: module " <> Tx.unpack m
      <> " imports unknown module " <> Tx.unpack target
  LoadImportCycle ms ->
    "error: import cycle: " <> intercalate " -> " (map Tx.unpack ms)
  where
    intercalate sep = foldr1 (\x acc -> x <> sep <> acc)

prettyPipelineError :: PipelineError -> String
prettyPipelineError = \case
  PErrLoader le    -> prettyLoaderError le
  PErrReorder n s  -> "reorder error in module " <> Tx.unpack n <> ": " <> s
  PErrEnv n cs ->
    "env merge conflict in module " <> Tx.unpack n <> ":\n"
      <> unlines [ "  " <> show ns <> " " <> Tx.unpack name | (ns, name) <- cs ]
  PErrType n te ->
    "typecheck error in module " <> Tx.unpack n <> ": " <> show te

prettyWarning :: TC.Warning -> String
prettyWarning (TC.BodylessBinding name pos) =
  "warning: bodyless binding `" <> Tx.unpack name <> "`" <> showPos pos
    <> "\n  add an equation, or move the declaration into Std.Base if intentional."
  where
    showPos (Just (l, c)) = " at line " <> show l <> ", col " <> show c
    showPos Nothing       = ""
```

- [ ] **Step 5: Update the test harness in `test/Spec.hs`**

Replace `typecheckSuccessHarness` and `typecheckFailHarness` so they route through the Loader. For a single-file test, wrap as if the file were the entry with no `-I`:

```haskell
typecheckSuccessHarness :: FilePath -> IO BL.ByteString
typecheckSuccessHarness path = do
  result <- Loader.loadProgram path []
  case result of
    Left lerr -> pure (BL.pack ("loader: " <> show lerr <> "\n"))
    Right ms  ->
      case typecheckAllForTest ms of
        Left s    -> pure (BL.pack ("pipeline: " <> s <> "\n"))
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
    Right ms  ->
      case typecheckAllForTest ms of
        Left s -> pure (BL.pack ("typecheck: " <> s <> "\n"))
        Right _ -> pure (BL.pack "UNEXPECTED SUCCESS\n")

-- | Test-side implementation of the pipeline fold, returning only the
-- *entry* module's decls + accumulated warnings, or a stringified error
-- on the first failure.
typecheckAllForTest
  :: [Loader.LoadedModule]
  -> Either String ([TC.TypedDecl], [TC.Warning])
typecheckAllForTest modules = go modules Map.empty Map.empty Map.empty []
  where
    entryName = Loader.lmName (last modules)
    go [] tdMap _envs _fix warns =
      Right (Map.findWithDefault [] entryName tdMap, reverse warns)
    go (m : rest) tdMap envsByMod fixByMod warns =
      let importedFixs = [ fixByMod Map.! n
                         | n <- Loader.lmImports m, Map.member n fixByMod ]
          importedEnvs = [ envsByMod Map.! n
                         | n <- Loader.lmImports m, Map.member n envsByMod ]
      in case foldMEither overlayFixities emptyFixityTable importedFixs of
           Left fes -> Left (show fes)
           Right f0 -> case overlayFixities f0 (Loader.lmFixities m) of
             Left fes -> Left (show fes)
             Right mergedFix ->
               case foldMEither overlayEnvs B.initialEnv importedEnvs of
                 Left cs   -> Left ("env clashes: " ++ show cs)
                 Right env -> case reorderModuleWith mergedFix (Loader.lmAst m) of
                   Left es -> Left ("reorder: " ++ show es)
                   Right ast ->
                     case TC.inferProgramWith env (Loader.lmOrigin m) ast of
                       Left e -> Left (show e)
                       Right (envOut, decls, ws) ->
                         go rest
                            (Map.insert (Loader.lmName m) decls tdMap)
                            (Map.insert (Loader.lmName m) envOut envsByMod)
                            (Map.insert (Loader.lmName m) (Loader.lmFixities m) fixByMod)
                            (reverse ws ++ warns)

    foldMEither f acc [] = Right acc
    foldMEither f acc (x : xs) = case f acc x of
      Left e   -> Left e
      Right a' -> foldMEither f a' xs
```

Add the necessary imports at the top of `test/Spec.hs` if not already present:

```haskell
import qualified Data.Map.Strict as Map
import qualified Wok.Loader as Loader
import Wok.SourceOrigin (Origin (..))
```

- [ ] **Step 6: Migrate `test/typecheck-examples/*.wok` fixtures**

Each fixture needs the new header. Some need rewrites because they declared `data Maybe`/`Either`/`List` that now exist in Std.Base.

`test/typecheck-examples/01-identity.wok`:
```wok
module Main
import Std.Base

id : a -> a
id x = x

const : a -> b -> a
const x y = x

flip : (a -> b -> c) -> b -> a -> c
flip f x y = f y x
```

Note: this conflicts with Std.Base's `id` and `const`! Either:
- (preferred) Rename the fixture's bindings (e.g. `myId`, `myConst`)
- (alternative) Delete the conflicting bindings

Use the rename approach for minimal disruption:

```wok
module Main
import Std.Base

myId : a -> a
myId x = x

myConst : a -> b -> a
myConst x y = x

myFlip : (a -> b -> c) -> b -> a -> c
myFlip f x y = f y x
```

Update `test/typecheck-golden/01-identity.expected` accordingly (sorted alphabetically):
```
myConst : forall a b. a -> b -> a
myFlip : forall a b c. (a -> b -> c) -> b -> a -> c
myId : forall a. a -> a
```

`test/typecheck-examples/02-arithmetic.wok` (drop the now-redundant fixity decls since Std.Base provides them):
```wok
module Main
import Std.Base

add : u64 -> u64 -> u64
add x y = x + y

double : u64 -> u64
double n = n * 2

quad : u64 -> u64
quad n = double (double n)
```

`test/typecheck-examples/03-lists.wok` (rewrite to use `[]` instead of `data List`):
```wok
module Main
import Std.Base

myLength : [a] -> u64
myLength xs = case xs of
  []      -> 0
  _ :: ys -> 1 + myLength ys

myMap : (a -> b) -> [a] -> [b]
myMap f xs = case xs of
  []      -> []
  y :: ys -> f y :: myMap f ys
```

Update its golden:
```
myLength : forall a. [a] -> u64
myMap : forall a b. (a -> b) -> [a] -> [b]
```

`test/typecheck-examples/04-maybe.wok` (rewrite Maybe → Option, Just → Some, Nothing → None):
```wok
module Main
import Std.Base

fromOption : a -> Option a -> a
fromOption d m = case m of
  None   -> d
  Some x -> x

mapOption : (a -> b) -> Option a -> Option b
mapOption f m = case m of
  None   -> None
  Some x -> Some (f x)
```

Golden:
```
fromOption : forall a. a -> Option a -> a
mapOption : forall a b. (a -> b) -> Option a -> Option b
```

`test/typecheck-examples/05-either.wok` (rewrite Either → Result, Left → Ok, Right → Err):
```wok
module Main
import Std.Base

mapResult : (a -> c) -> (b -> c) -> Result a b -> c
mapResult f g e = case e of
  Ok a  -> f a
  Err b -> g b
```

Golden:
```
mapResult : forall a b c. (a -> c) -> (b -> c) -> Result a b -> c
```

`test/typecheck-examples/06-mutual-rec.wok`:
```wok
module Main
import Std.Base

even : u64 -> Bool
even n = case n of
  0 -> True
  _ -> odd (n - 1)

odd : u64 -> Bool
odd n = case n of
  0 -> False
  _ -> even (n - 1)
```

(Golden unchanged from Phase 2 update.)

`test/typecheck-examples/07-where.wok`:
```wok
module Main
import Std.Base

hyp : u64 -> u64 -> u64
hyp x y = root (sq x + sq y)
  where
    sq n = n * n
    root n = n
```

`test/typecheck-examples/08-patterns.wok` (rewrite Maybe → Option):
```wok
module Main
import Std.Base

first : (a, b) -> a
first p = case p of
  (x, _) -> x

isNone : Option a -> Bool
isNone m = case m of
  None   -> True
  Some _ -> False

headOr : a -> [a] -> a
headOr d xs = case xs of
  []     -> d
  x :: _ -> x
```

Golden:
```
first : forall a b. (a, b) -> a
headOr : forall a. a -> [a] -> a
isNone : forall a. Option a -> Bool
```

`test/typecheck-examples/09-higher-order.wok`:
```wok
module Main
import Std.Base

twice : (a -> a) -> a -> a
twice f x = f (f x)

compose : (b -> c) -> (a -> b) -> a -> c
compose f g x = f (g x)

apply : (a -> b) -> a -> b
apply f x = f x
```

`test/typecheck-examples/10-multi-sig.wok`:
```wok
module Main
import Std.Base

zero, one, two : u64
zero = 0
one = 1
two = 2

allZeros : Bool
allZeros = case zero of
  0 -> True
  _ -> False
```

- [ ] **Step 7: Migrate `test/typecheck-fail-examples/*.wok` fixtures**

Add `module Main; import Std.Base` to each. Goldens may need updating if the error text changed due to harness output prefix differences (the new harness emits `"typecheck: " <> show err` — same prefix as before).

Example for `01-mismatch.wok`:
```wok
module Main
import Std.Base

bad : u64
bad = "not an int"
```

Golden unchanged from the Phase 2 update:
```
typecheck: Mismatch Nothing (CTCon TcU64 []) (CTCon TcString []) -- wait, TcString is GONE per spec!
```

Wait — the spec drops Char and String. But test fixtures reference them. Need to think. The fixture `01-mismatch.wok` currently uses `String`. After Std.Base, `String` is no longer in scope (it's dropped from Builtins). So this fixture would fail with `UnknownTyCon`, not `Mismatch`. Need to rewrite the test to a still-valid mismatch:

```wok
module Main
import Std.Base

bad : u64
bad = True
```

Golden:
```
typecheck: Mismatch Nothing (CTCon TcU64 []) (CTCon TcBool []) -- but TcBool is now TcUser "Bool"!
```

Hmm wait again — after the cutover, `Bool` is no longer a primitive `TcBool` because it's defined in Std.Base via `data Bool = True | False`. The typechecker handles user-defined data via `TcUser "Bool"`. So the mismatch text becomes `(CTCon (TcUser "Bool") [])`.

But `prettyCType` for `TcUser n []` prints as `n`, so user-facing text still says `Bool`. The `Show TypeError` instance prints raw constructor form (`CTCon (TcUser "Bool") []`), so the golden needs to use that exact text.

Update golden:
```
typecheck: Mismatch Nothing (CTCon TcU64 []) (CTCon (TcUser "Bool") [])
```

This applies to every fail-golden that used `TcBool` / `TcChar` / `TcString` — those become `TcUser "Bool"` etc., except `TcChar` / `TcString` are *gone* entirely, so any fail fixture using them must be rewritten to use `Bool` / `u64` / `Option` / etc.

Concretely, audit each `test/typecheck-fail-examples/*.wok`:
- `01-mismatch.wok`: rewrite "not an int" → True, golden uses `TcUser "Bool"`
- `02-occurs.wok`: probably unaffected (occurs check)
- `03-unknown-var.wok`: unaffected
- `04-unknown-con.wok`: unaffected
- `05-arity.wok`: unaffected
- `06-sig-mismatch.wok`: similar to 01 — rewrite if it used String/Char
- `07-duplicate-tycon.wok`: needs review — if it defines `data Bool` and that conflicts with Std.Base's `Bool`, it becomes a different error
- `08-sig-too-general.wok`: needs review

Walk each file:

```bash
for f in test/typecheck-fail-examples/*.wok; do
  echo "=== $f ==="; cat "$f"
done
```

For each, add `module Main; import Std.Base` and adjust types as needed. Update the matching golden under `test/typecheck-fail-golden/`.

- [ ] **Step 8: Build and run**

```bash
cabal build 2>&1 | tail -10
cabal test 2>&1 | tail -30
```

This is the make-or-break step. Expected: build succeeds; every golden test passes after fixture + golden migration. If a test fails, inspect the diff against the golden:

```bash
cabal test --test-options="-p typecheck.*02-arithmetic" 2>&1 | tail -50
```

Adjust each golden until the suite is green.

- [ ] **Step 9: Manual smoke test of the CLI**

```bash
cabal run wok -- test/typecheck-examples/02-arithmetic.wok 2>&1
```

Expected output:
```
add : u64 -> u64 -> u64
double : u64 -> u64
quad : u64 -> u64
```

(And the loader silently includes Std.Base, so the entry-only output filter works.)

```bash
cabal run wok -- 2>&1
```

Expected: usage line printed to stderr; exit code non-zero.

```bash
cabal run wok -- test/typecheck-examples/does-not-exist.wok 2>&1
```

Expected: `error: file not found: ...` on stderr; exit code non-zero.

- [ ] **Step 10: Commit**

```bash
git add prelude/Std/Base.wok src/Wok/TypeChecking/Builtins.hs src/Wok/TypeChecking/Infer.hs app/Main.hs test/Spec.hs test/typecheck-examples/ test/typecheck-fail-examples/ test/typecheck-golden/ test/typecheck-fail-golden/
git commit -m "$(cat <<'EOF'
feat(cutover): populate Std.Base, shrink Builtins, rewrite Main

The atomic switch from hand-coded Wok.TypeChecking.Builtins to the
embedded Std.Base Prelude:

* prelude/Std/Base.wok: data Bool/Option/Result, fixity decls, bodyless
  operator sigs (+, -, *, /, div, mod, ==, /=, &&, ||, ++, $), id, const.
* Builtins.initialEnv: shrunk to u64, (), [], the 15-tuple family. No
  constructors, no operators, no helpers.
* inferProgramTC now consumes the seed env from inferProgramWith
  (rather than hard-coding Builtins.initialEnv).
* app/Main.hs: new CLI (wok <entry> [-I file]...), Wok.Loader
  integration, per-module typecheck fold with cross-module fixity and
  env merging, warning emission to stderr.
* test/Spec.hs harness: routes through Wok.Loader; per-module fold
  mirrors Main's.
* All test/typecheck-(fail-)examples migrated: module header +
  `import Std.Base`; Maybe/Either/List/Char/String references rewritten
  to Option/Result/[]/u64/Bool as appropriate. Goldens regenerated.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 4: New tests + example migration

### Task 11: Add Loader-tier integration tests

**Goal:** Add the tests called out in the spec's "Test plan" section that exercise multi-module flows: cross-module fixity, bodyless warnings, name conflicts.

**Files:**
- Create: `test/loader-fixtures/07-cross-fixity-entry.wok`, `07-cross-fixity-extra.wok`
- Create: `test/loader-fixtures/08-cross-fixity-redecl.wok`
- Create: `test/loader-fixtures/09-name-conflict-a.wok`, `09-name-conflict-b.wok`, `09-name-conflict-entry.wok`
- Create: `test/loader-fixtures/10-bodyless-user.wok`
- Modify: `test/Spec.hs` — add `crossModuleFixityTests`, `crossModuleNameConflictTests`, `bodylessUserWarningTests`

**Acceptance Criteria:**
- [ ] `crossModuleFixity`: An `-I` file declares `fixity ## left tighter than +`; the entry uses `a + b ## c` and the loader reorders it as `a + (b ## c)`.
- [ ] `crossModuleFixityRedecl`: Entry tries to redeclare `fixity + left` (already in Std.Base) — surfaces as `LoadCrossModuleFixityConflict` or the pipeline-error equivalent.
- [ ] `crossModuleNameConflict`: Two `-I` files both export `foo`; entry imports both — surfaces as env merge conflict on `foo`.
- [ ] `bodylessUserWarning`: A user-file `foo : u64` with no equation produces a `BodylessBinding "foo" _` warning.
- [ ] `silentBodylessInPrelude`: The full pipeline run against `test/typecheck-examples/02-arithmetic.wok` produces zero warnings (Std.Base's bodyless sigs are silent).

**Verify:** `cabal test --test-options="-p crossModule OR bodylessUser OR silentBodyless"` passes.

**Steps:**

(The steps follow the same fixture-then-test pattern as Task 8; see the spec test plan for assertions. Each test reuses the `typecheckAllForTest` harness from Task 10's Step 5. Concrete fixture contents and test code go here. — Plan reader: this task is mechanical given Task 8/10's patterns; spend ~30 min writing the fixture files and test bodies. If any expected error path needs a new `LoaderError` variant or `PipelineError` shape, extend per the spec.)

- [ ] **Step 1: Write fixtures + tests; run; commit.** Follow Task 8 Steps 3-7 as templates.

---

### Task 12: Migrate `examples/hehe.wok` and `examples/types-tour.wok`

**Goal:** Add `module Main; import Std.Base` headers; delete redundant fixity decls and `data Bool` (now in Std.Base); rewrite `Maybe` / `List` to `Option` / `[]`.

**Files:**
- Modify: `examples/hehe.wok`
- Modify: `examples/types-tour.wok`

**Acceptance Criteria:**
- [ ] Both files start with `module Main\nimport Std.Base\n`.
- [ ] `examples/hehe.wok`: fixity block removed; `data Bool = True | False` removed.
- [ ] `examples/types-tour.wok`: `data Maybe` and `data List` removed; functions rewritten to use `Option` and built-in `[]`.
- [ ] `wok examples/hehe.wok` runs to completion (no parse / load / typecheck errors).
- [ ] `wok examples/types-tour.wok` runs to completion.
- [ ] The parse-golden tests for these files (if any in `test/examples/` mirror them) still pass — but check; the parse-golden fixtures may be separate copies that aren't user-facing examples.

**Verify:** `cabal run wok -- examples/hehe.wok 2>&1 | head -10` shows typed-decl output; similar for `types-tour.wok`.

**Steps:**

- [ ] **Step 1: Migrate `examples/hehe.wok`** — apply the diff described in the spec's Migration section. Run `cabal run wok -- examples/hehe.wok` to verify.
- [ ] **Step 2: Migrate `examples/types-tour.wok`** — replace `data Maybe` / `data List` with `Option` / `[]` usages. Run `cabal run wok -- examples/types-tour.wok` to verify.
- [ ] **Step 3: Run full test suite to confirm no regression** — `cabal test 2>&1 | tail -10`.
- [ ] **Step 4: Commit**:

```bash
git add examples/hehe.wok examples/types-tour.wok
git commit -m "$(cat <<'EOF'
chore(examples): migrate examples to Std.Base Prelude

Adds `module Main; import Std.Base` headers, deletes fixity decls and
data Bool / Maybe / List declarations now provided by Std.Base, and
rewrites Maybe/Just/Nothing to Option/Some/None and List a / Nil / Cons
to built-in [] / [] / ::.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review

After all tasks done, re-run the spec self-review against the plan:

1. **Spec coverage**: every requirement maps to a task. ✓ (Tasks 1-8 = additive foundations; Task 9 = TcInt rename; Task 10 = cutover; Task 11 = integration tests; Task 12 = example migration.)
2. **No placeholders**: every step has concrete code or commands. ✓ (Tasks 11 Step 1 is described as "mechanical given Task 8/10's patterns" — verify before execution that the engineer can produce fixtures and tests from those templates without re-asking.)
3. **Type consistency**: `Origin` is defined in `Wok.SourceOrigin` (Task 1) and used everywhere it appears. `Warning` is in `Wok.TypeChecking.Infer` and re-exported from `Wok.TypeChecking` (Task 6). `LoadedModule` fields (`lmName`, `lmOrigin`, `lmAst`, `lmImports`, `lmFixities`) used consistently in Loader (Task 8), Main rewrite (Task 10), and test harness rewrite (Task 10). ✓.

---

## Notes for the executor

- This is a single execution thread. Tasks 1-8 can be done in order without re-testing the whole suite between them (each task has its own test gate). Task 9 is mechanical. Task 10 is the big-bang cutover and MUST land in one commit. Tasks 11-12 are additive.
- When a task says "regenerate parser via BNFC," that's the only step at which the contents of `src-generated/` should change. Hand-editing generated files breaks the cabal `BNFC:bnfc` toolchain hint.
- The `prelude/Std/Base.wok` file is embedded at build time. After editing it, `cabal build` will recompile the binary; no other action needed.
