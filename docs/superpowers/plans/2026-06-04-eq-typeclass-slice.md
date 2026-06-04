# Eq Type-Class Slice (Dictionary Passing) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A minimal, decidable single-parameter `Eq` type class with full dictionary passing — `class`/`instance` surface syntax (layout `where`-blocks, operators as methods), constrained instances (`(Eq a) => Eq (Option a)`), polymorphic constrained user functions, and the interpreter CAF fix — with zero behavior change for code that does not use classes.

**Architecture:** Constraints are collected during inference, generalized into qualified schemes, and discharged against registered instances. The typechecker decorates use-sites of constrained identifiers with a `TQVar` node that carries the class-argument *type*; a single shared resolver (`Wok.TypeChecking.Solve`) turns a frozen class-argument type into an `Evidence` term, used both by the typechecker (to validate dischargeability) and by elaboration (to build the concrete dictionary term). Dictionaries are records (`VRecord`); a method call is a field projection + application; instances are top-level binds (ground = 0-arity dict value needing the CAF fix; constrained = a dict-builder lambda). The heavy logic lives in two new modules (`Class`, `Solve`); `Infer.hs` gains only hook points.

**Tech Stack:** Haskell (GHC 9.10, `Strict`/`StrictData`), `mtl`, `ST` for inference cells, BNFC (`--haskell -d --text-token`) + Alex + Happy with two hand-maintained post-regen patches, `tasty`/`tasty-golden`/`tasty-hunit`. Reuses `Wok.TypeChecking.Types.CType` in the IR; reuses the typed core (`Wok.TypeChecking.Typed`).

**Spec:** `docs/superpowers/specs/2026-06-04-eq-typeclass-slice-design.md`

---

## Design refinements vs. the spec (read once)

Two refinements discovered while planning against the actual code; both keep the spec's intent and reduce churn:

1. **No `=>` grammar exists today.** The spec assumed qualified types could be written; they cannot. Task 0 therefore adds BOTH `class`/`instance` decls AND a qualified-type form `(C a) => T` to `Type`, and `translateSig` (Task 7) learns to read it.

   **UPDATE (Task 0 done):** `TQual [Constraint] Type` is unparseable under LALR(1) — a leading `ConId` inside `(` cannot be disambiguated between a constraint and a tuple-type element until after `)`. The implemented grammar is `TQual. Type ::= Type1 "=>" Type`, producing **`Abs.TQual Type Type`** where the LHS is the constraint context encoded AS a type: a single constraint `(Eq a)` arrives as `TParen (TApp (TCon Eq) (TVar a))`; multiple `(Eq a, Show a)` arrive as `TTuple`. Downstream (Task 7 `translateSig`, and any constraint reader) MUST reinterpret that LHS `Type` into `[Constraint]` via a helper `constraintsOfType :: Abs.Type -> Either TypeError [Constraint]` (unwrap `TParen`/`TTuple`, then each element `TApp (TCon C) arg` -> `Constraint C arg`). Instance heads are unaffected: `Abs.InstHead = IHPlain ConId [Type] | IHCtx [Constraint] ConId [Type]` still carry real `[Constraint]` (unambiguous after the `instance` keyword). Confirmed `Abs` shapes: `DClass ConId [VarId] [ClassEntry]`, `DInstance InstHead [InstEntry]`, `ClassEntry = CESig MethodName Type | CEDefault FunLHS Exp`, `InstEntry = IEImpl FunLHS Exp`, `MethodName = MNBare VarId | MNParen VarSym`, `Constraint ConId [Type]`. Also: `Infer.hs` already gained two forced arms for the new `TQual` constructor (`checkAnonTailPolarity` descends; `translateSig` currently REJECTS `TQual` with `UnsupportedFeature` — Task 7 replaces that rejection with real handling). The BNFC regen command requires the namespace prefix: `bnfc --haskell -d --text-token -p GeneratedParser -o src-generated grammar/Wok.cf`.

2. **Evidence is computed by a shared resolver from a frozen class-argument type, not stored as a pre-resolved `Evidence` inside the typed tree.** A use-site of a *constrained* identifier becomes one new typed node `TQVar Text [(Text, a)]` — the name plus, per constraint, `(className, classArgType)` where `classArgType` rides as an annotation-typed field (so it freezes with the tree via the existing `traverse`). `Wok.TypeChecking.Solve.resolve` maps a frozen `CType` class-argument + the in-scope evidence-parameter set to an `Evidence` term. The typechecker calls `resolve` at discharge to *validate* (concrete constraints must resolve, else error) and to detect ambiguity; elaboration calls the same `resolve` to *build* the dictionary term. This makes `Solve` the single resolution engine and keeps `Typed.hs` to one new constructor. Non-constrained identifiers keep emitting the existing `TVar`/`TParenOp` nodes, so all existing goldens are byte-identical.

Lowering of `TQVar name cs`:
- If `name` is a class method (its class is in `envClasses`): `(ev."name") args...` — project the method off its single dict.
- Otherwise (`name` is an ordinary constrained function): `name ev... args...` — pass dicts as leading curried arguments.

---

## File structure

**New files:**
- `src/Wok/TypeChecking/Class.hs` — class/instance registration (`processClassDecl`, `processInstanceDecl`), method-scheme construction, termination + coherence checks. Depends on `Env`, `Types`, `Monad`, the sig translator.
- `src/Wok/TypeChecking/Solve.hs` — the constraint resolver: `resolve :: Env -> Set Int -> Text -> CType -> Either SolveError Evidence`, plus `dictName`. Pure (no `TC`/`ST`); callable from both inference and elaboration.

**Modified files:**
- `grammar/Wok.cf` — remove `class`/`instance` from `ReservedKw`; add `DClass`/`DInstance`, qualified-type `TQual`, `Constraint`, `MethodName`, class/instance entry productions.
- `src-generated/GeneratedParser/Wok/*` — regenerated by BNFC; two manual patches re-applied.
- `src/Wok/Reordering.hs` — pass `DClass`/`DInstance` through (currently catch-all already does, but add explicit constraint validation).
- `src/Wok/TypeChecking/Types.hs` — `Constraint`, `Evidence`; `Scheme` gains `schemeConstraints`.
- `src/Wok/TypeChecking/Env.hs` — `ClassInfo`, `InstanceInfo`; `envClasses`, `envInstances`; helpers; `emptyEnv`/`overlayEnvs`.
- `src/Wok/TypeChecking/Monad.hs` — `ctxConstraints` accumulator + `addConstraint`/`takeConstraints`.
- `src/Wok/TypeChecking/Typed.hs` — `TQVar Text [(Text, a)]` node; (no other node changes).
- `src/Wok/TypeChecking/Infer.hs` — `translateSig` qualified types; constraint emission + `TQVar` build at constrained-scheme instantiation; discharge + `tdEvidence` at `finalizeGroupTyped`; class/instance pre-pass in `inferProgramTC`; `TypedDecl` gains `tdEvidence`.
- `src/Wok/IR/Elaborate.hs` — lower `TQVar` (Solve-driven); prepend evidence-param binders from `tdEvidence`; lower instance decls to dict `TopBind`s; specialize default methods.
- `src/Wok/IR/Anf.hs` — no type changes; instance dicts use existing `RRecord`/`RProj`.
- `src/Wok/Interp/Prim.hs` — rename `==` prim to `eqU64`; drop `/=`.
- `src/Wok/Interp/Machine.hs` — `runModule` CAF fix (knot-tied global env).
- `prelude/Std/Base.wok` — `class Eq`, `instance Eq U64`, `not`, `eqU64` sig; remove old `(==)`/`(/=)` sigs.
- `wok.cabal` — register `Wok.TypeChecking.Class`, `Wok.TypeChecking.Solve`.
- `test/Spec.hs` + golden dirs — new unit groups and goldens.

---

## Task 0: Grammar — class/instance decls + qualified types

**Goal:** `class`/`instance` `where`-blocks and `(C a) => T` qualified types parse into new `Abs` constructors; they are semantically ignored for now (no typechecking yet). All existing goldens stay green.

**Files:**
- Modify: `grammar/Wok.cf` (ReservedKw lines 87-88; Decl block lines 63-90; Type block lines 195-226)
- Regenerate: `src-generated/GeneratedParser/Wok/{Abs,Par.y,Lex,Layout,Print,ErrM}.hs`
- Modify: `src/Wok/Reordering.hs:226` (DReserved passthrough; add DClass/DInstance)
- Modify: `src/Wok/TypeChecking/Infer.hs:2264` (`toLocalDecl` — keep ignoring class/instance for now)
- Test: `test/Spec.hs` (new group `ClassParse`) + `test/examples/26-typeclass.wok` (parse golden)

**Acceptance Criteria:**
- [ ] `grammar/Wok.cf` no longer lists `class`/`instance` in `ReservedKw`.
- [ ] BNFC regenerates; both manual patches re-applied; `cabal build` succeeds.
- [ ] `class Eq a where (==) : a -> a -> Bool` and `instance Eq U64 where (==) = eqU64` parse to `Abs.DClass`/`Abs.DInstance`.
- [ ] `isEq : (Eq a) => a -> a -> Bool` parses to a `Type` using the new `TQual` constructor.
- [ ] All existing `parse golden`, `anf golden`, `typed-anf golden`, `run golden` groups stay byte-identical.

**Verify:** `cabal build && cabal test --test-options='-p ClassParse'` → pass; `cabal test --test-options='-p golden'` → all pass.

**Steps:**

- [ ] **Step 1: Edit `grammar/Wok.cf`.** Remove `class`/`instance` from the `ReservedKw` rule (lines 87-90), leaving the others:

```bnfc
rules     ReservedKw ::= "contract" | "type" | "deriving" | "forall"
                       | "do" | "record" | "row" | "fun" | "ctl" | "resume" ;
```

  Add to the `Decl` block (after `DEffect`, around line 66). The `where "{" ... "}"` are layout-virtual braces (the `where` keyword is already a layout keyword at line 58):

```bnfc
DClass.    Decl ::= "class" ConId [VarId] "where" "{" [ClassEntry] "}" ;
DInstance. Decl ::= "instance" InstHead "where" "{" [InstEntry] "}" ;

-- Instance head: class name + type args, with optional constraint context.
IHPlain.   InstHead ::= ConId [Type2] ;
IHCtx.     InstHead ::= "(" [Constraint] ")" "=>" ConId [Type2] ;

-- A method name: a plain identifier or a parenthesized operator.
MNBare.    MethodName ::= VarId ;
MNParen.   MethodName ::= "(" VarSym ")" ;

-- Class entries: a method signature or a default-method equation.
CESig.     ClassEntry ::= MethodName ":" Type ;
CEDefault. ClassEntry ::= FunLHS "=" Exp ;
separator  ClassEntry ";" ;

-- Instance entries: a method implementation.
IEImpl.    InstEntry ::= FunLHS "=" Exp ;
separator  InstEntry ";" ;

-- A single constraint, e.g. `Eq a`.
Constraint. Constraint ::= ConId [Type2] ;
separator   Constraint "," ;
```

  Add to the `Type` block (a qualified type is the loosest type form, so it sits at top-level `Type`, like `TFun`; insert near line 195 before `TFun`):

```bnfc
TQual.    Type  ::= "(" [Constraint] ")" "=>" Type ;
```

  Note: `Constraint ::= ConId [Type2]` and `EffectAtom ::= ConId [Type2]` share a prefix, but constraints only appear inside `"(" ... ")" "=>"`, which no effect form uses, so there is no LALR conflict at the constraint position. The `(` lookahead for `TQual` vs `TParen`/`TTuple`/`TUnit` is resolved by Happy because only `TQual` is followed by `... ")" "=>"`.

- [ ] **Step 2: Regenerate the parser.** From repo root:

```bash
bnfc --haskell -d --text-token -o src-generated grammar/Wok.cf
```

  This rewrites `src-generated/GeneratedParser/Wok/{Abs,Lex,Par.y,Layout,Print,Skel,Test,ErrM}.hs` and `Doc.txt`. (cabal auto-runs `alex`/`happy` on `Lex.x`/`Par.y`; it does NOT run `bnfc`.)

- [ ] **Step 3: Re-apply the two manual post-regen patches.** These are documented in `grammar/Wok.cf` comments (lines 13-56) and were lost by regeneration.

  **Patch 1 — `src-generated/GeneratedParser/Wok/Layout.hs`** (the separator-before-paren fix). Find the `res pt st (t0 : ts)` clause that combines `isLayoutOpen t0 || isParenOpen t0` and split it into two clauses; only the paren branch inserts a separator, and the binder MUST be `pt` not `_`:

```haskell
res pt st (t0 : ts)
  | isLayoutOpen t0
    = t0 : res (Just t0) (Explicit : st) ts
  | isParenOpen t0
    = maybeInsertSeparator pt t0 st $
      t0 : res (Just t0) (Explicit : st) ts
```

  **Patch 2 — `src-generated/GeneratedParser/Wok/Par.y`** (record-pattern left-recursion). Replace the auto-generated right-recursive `ListRecordFieldPat` with a left-recursive `NEListRecordFieldPat` and reverse at the use sites (verbatim from `grammar/Wok.cf` comment lines 44-54):

```happy
NEListRecordFieldPat
  : RecordFieldPat { [$1] }
  | NEListRecordFieldPat ',' RecordFieldPat { $3 : $1 }

AtomPat
  : ConId '{' '}' { GeneratedParser.Wok.Abs.PRecord $1 [] }
  | ConId '{' NEListRecordFieldPat '}' { GeneratedParser.Wok.Abs.PRecord $1 (reverse $3) }
  | ConId '{' NEListRecordFieldPat ',' PatRowTail '}' { GeneratedParser.Wok.Abs.PRecordOpen $1 (reverse $3) $5 }
  | ConId '{' PatRowTail '}' { GeneratedParser.Wok.Abs.PRecordWild $1 $3 }
```

- [ ] **Step 4: Build and resolve any new grammar conflicts.**

```bash
cabal build 2>&1 | tee /tmp/wok-build.log
```

  Expected new `Abs` constructors (BNFC derives names from the rule labels): `DClass ConId [VarId] [ClassEntry]`, `DInstance InstHead [InstEntry]`, `InstHead = IHPlain ConId [Type2] | IHCtx [Constraint] ConId [Type2]`, `MethodName = MNBare VarId | MNParen VarSym`, `ClassEntry = CESig MethodName Type | CEDefault FunLHS Exp MaybeWhere` (note: BNFC may attach `MaybeWhere` from the `Exp` context — confirm the exact shape in the regenerated `Abs.hs` and use whatever it emits), `InstEntry = IEImpl FunLHS Exp MaybeWhere`, `Constraint ConId [Type2]`, `Type` gains `TQual [Constraint] Type`. If Happy reports a shift/reduce conflict involving `TQual`, confirm Patch 1/2 are applied; conflicts in the generated `.info` that pre-existed are acceptable (the build still produces a working parser).

- [ ] **Step 5: Pass class/instance decls through reordering.** `src/Wok/Reordering.hs:226` currently has `reorderDecl _ d@(DReserved{}) = Right d`. Add explicit passthrough arms for the new decls so they survive to typechecking (they are reordered like any non-equation decl — keep them in place):

```haskell
reorderDecl _ d@(Abs.DClass{})    = Right d
reorderDecl _ d@(Abs.DInstance{}) = Right d
```

  (Place these alongside the existing `DData`/`DEffect` passthrough arms; match the exact signature `reorderDecl` uses there.)

- [ ] **Step 6: Keep `toLocalDecl` ignoring class/instance (for now).** `Infer.hs:2264` `toLocalDecl` already returns `[]` for non-`DEqn`/`DSig`. No change needed this task — class/instance are typechecked in Task 7, not as local decls.

- [ ] **Step 7: Write the parse fixture + golden.** Create `test/examples/26-typeclass.wok`:

```wok
module Test.TypeClass

class Eq a where
  (==) : a -> a -> Bool
  (/=) : a -> a -> Bool
  (/=) x y = not (x == y)

instance Eq U64 where
  (==) = eqU64

instance (Eq a) => Eq (Option a) where
  (==) x y =
    case (x, y) of
      (None, None)     -> True
      (Some a, Some b) -> a == b
      _                -> False

isEq : (Eq a) => a -> a -> Bool
isEq x y = x == y
```

  The `parse golden` group auto-discovers `test/examples/*.wok`; generate its golden:

```bash
cabal test --test-options="-p 'parse golden' --accept"
```

  Inspect `test/golden/26-typeclass.expected` by hand: it should be the BNFC `Print` round-trip showing `DClass`/`DInstance`/`TQual` reconstructed. Re-run without `--accept` to confirm clean.

- [ ] **Step 8: Write a `ClassParse` unit test** in `test/Spec.hs` asserting the constructors. Add `classParseTests` to the test tree (near the other parse tests) and to the `defaultMain` list:

```haskell
classParseTests :: TestTree
classParseTests = testGroup "ClassParse"
  [ testCase "class decl parses to DClass" $
      case parse (T.pack "module M\nclass Eq a where\n  (==) : a -> a -> Bool\n") of
        Right (Abs.Module ds) ->
          assertBool "expected a DClass" (any isDClass ds)
        Left e -> assertFailure ("parse: " ++ e)
  , testCase "qualified sig parses to TQual" $
      case parse (T.pack "module M\nisEq : (Eq a) => a -> a -> Bool\n") of
        Right (Abs.Module ds) ->
          assertBool "expected a TQual in a DSig" (any sigHasQual ds)
        Left e -> assertFailure ("parse: " ++ e)
  ]
  where
    isDClass Abs.DClass{} = True
    isDClass _            = False
    sigHasQual (Abs.DSig _ _ (Abs.TQual _ _)) = True
    sigHasQual _                              = False
```

- [ ] **Step 9: Run + commit.**

```bash
cabal test --test-options='-p ClassParse' && cabal test --test-options='-p golden'
git add grammar/Wok.cf src-generated/ src/Wok/Reordering.hs test/examples/26-typeclass.wok test/golden/26-typeclass.expected test/Spec.hs
git commit -m "feat(grammar): class/instance decls and qualified types parse (semantically ignored)"
```

---

## Task 1: Types — `Constraint`, `Evidence`, qualified `Scheme`

**Goal:** Add the constraint and evidence vocabulary, and let a `Scheme` carry constraints.

**Files:**
- Modify: `src/Wok/TypeChecking/Types.hs` (after `Scheme`, lines 91-95)
- Test: `test/Spec.hs` (group `ConstraintTypes`)

**Acceptance Criteria:**
- [ ] `data Constraint = Constraint { conClass :: Text, conArg :: CType } deriving (Eq, Show)`.
- [ ] `data Evidence = EvGlobal Text | EvParam Text | EvApp Text [Evidence] deriving (Eq, Show)`.
- [ ] `Scheme` gains `schemeConstraints :: [Constraint]`; all existing constructions compile (helper `mkScheme` provided so non-class call sites stay terse).
- [ ] `cabal build` succeeds; `ConstraintTypes` test passes.

**Verify:** `cabal test --test-options='-p ConstraintTypes'` → pass.

**Steps:**

- [ ] **Step 1: Add the types** to `Types.hs`. `Text` is already imported. Insert after the `Scheme` definition:

```haskell
-- | A single class constraint, e.g. @Eq a@ (single-parameter classes only).
data Constraint = Constraint
  { conClass :: Text   -- ^ class name, e.g. "Eq"
  , conArg   :: CType  -- ^ the (closed) argument type
  }
  deriving (Eq, Show)

-- | A dictionary-passing witness for a discharged constraint.
data Evidence
  = EvGlobal Text         -- ^ a ground instance dict, e.g. "dict$Eq$U64"
  | EvParam  Text         -- ^ an in-scope dictionary parameter, e.g. "d$Eq$0"
  | EvApp    Text [Evidence]  -- ^ a dict-builder applied to sub-evidence
  deriving (Eq, Show)
```

- [ ] **Step 2: Extend `Scheme`.** Change (lines 91-95):

```haskell
data Scheme = Scheme
  { schemeVars        :: [(Int, Kind)]
  , schemeConstraints :: [Constraint]   -- NEW: qualified prefix, e.g. [Eq (CTGen 0)]
  , schemeBody        :: CType
  }
  deriving (Eq, Show)
```

  Add a back-compat smart constructor so unconstrained call sites do not all need a `[]`:

```haskell
-- | A scheme with no class constraints (the overwhelmingly common case).
mkScheme :: [(Int, Kind)] -> CType -> Scheme
mkScheme vs body = Scheme vs [] body
```

  Export `Constraint(..)`, `Evidence(..)`, `mkScheme` from the module's export list.

- [ ] **Step 3: Repair existing `Scheme` constructions.** The compiler will flag every `Scheme vs body` literal (it now needs 3 fields). Mechanically replace each `Scheme vs body` with `mkScheme vs body` across `src/` (do NOT touch the ones that intentionally set constraints — there are none yet). Use the build errors as the worklist:

```bash
cabal build 2>&1 | grep -n "Scheme" | head
```

  Likely sites: `Infer.hs` (`generalize`, `generalizeTyped`, `translateSig`, bodyless-sig), `Builtins.hs` (none — it builds tycons only), `Env.hs` (record/effect schemes if any). Each becomes `mkScheme ...` or an explicit `Scheme vs [] body`.

- [ ] **Step 4: Write `ConstraintTypes` test.**

```haskell
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
```

- [ ] **Step 5: Run + commit.**

```bash
cabal test --test-options='-p ConstraintTypes'
git commit -am "feat(types): Constraint, Evidence; Scheme carries a qualified prefix"
```

---

## Task 2: Env — `ClassInfo`, `InstanceInfo`, class/instance namespaces

**Goal:** The typing environment can register and look up classes and instances.

**Files:**
- Modify: `src/Wok/TypeChecking/Env.hs` (Env record lines 66-72; helpers lines 110-138; `emptyEnv` lines 75-76; `overlayEnvs`)
- Test: `test/Spec.hs` (group `ClassEnv`)

**Acceptance Criteria:**
- [ ] `ClassInfo` records the single param, the methods (name -> scheme), the defaults (raw `Abs.Exp` per method), and the method-name set.
- [ ] `InstanceInfo` records class, head type, context constraints, dict name, and per-method impls (raw `Abs.Exp`).
- [ ] `Env` gains `envClasses :: Map Text ClassInfo` and `envInstances :: [InstanceInfo]`; `emptyEnv` initializes them; `overlayEnvs` merges them (instances concatenated, classes unioned with collision error on duplicate class names).
- [ ] Helpers: `lookupClass`, `lookupInstances`, `classOfMethod`, `extendClass`, `extendInstance`.
- [ ] `cabal build` succeeds; `ClassEnv` test passes; existing `envSmoke`/`envOverlay` tests stay green.

**Verify:** `cabal test --test-options='-p ClassEnv' && cabal test --test-options='-p Env'` → pass.

**Steps:**

- [ ] **Step 1: Add the info records** to `Env.hs`. Import `Abs` (`import qualified GeneratedParser.Wok.Abs as Abs`) and `Constraint`, `Scheme` from `Types`:

```haskell
data ClassInfo = ClassInfo
  { ciParam    :: (Int, Kind)              -- ^ the single class parameter (CTGen idx, kind)
  , ciMethods  :: Map Text Scheme          -- ^ method name -> its full scheme (with Eq constraint)
  , ciDefaults :: Map Text Abs.Exp         -- ^ default-method bodies, keyed by method name
  , ciMethodNames :: [Text]                -- ^ declared methods, in source order
  }
  deriving (Eq, Show)

data InstanceInfo = InstanceInfo
  { iiClass    :: Text                      -- ^ "Eq"
  , iiHead     :: CType                      -- ^ instance type, e.g. CTCon TcU64 [] or CTCon (TcUser "Option") [CTGen 0]
  , iiContext  :: [Constraint]               -- ^ e.g. [Eq (CTGen 0)] for Eq (Option a)
  , iiDictName :: Text                       -- ^ "dict$Eq$U64" / "dict$Eq$Option"
  , iiImpls    :: Map Text Abs.Exp           -- ^ method name -> impl body
  }
  deriving (Eq, Show)
```

  (`Abs.Exp` derives `Eq`/`Show`, so these derive cleanly.)

- [ ] **Step 2: Extend `Env`** (lines 66-72):

```haskell
data Env = Env
  { envVars       :: Map Text Scheme
  , envCons       :: Map Text ConInfo
  , envTyCons     :: Map Text TyConInfo
  , envRecordCons :: Map Text RecordConInfo
  , envEffects    :: Map Text EffectInfo
  , envClasses    :: Map Text ClassInfo     -- NEW
  , envInstances  :: [InstanceInfo]         -- NEW
  }
  deriving (Eq, Show)
```

  Update `emptyEnv` (line 75) to `Env Map.empty Map.empty Map.empty Map.empty Map.empty Map.empty []`.

- [ ] **Step 3: Add helpers** (next to the existing `lookup*`/`extend*`):

```haskell
lookupClass :: Text -> Env -> Maybe ClassInfo
lookupClass k = Map.lookup k . envClasses

lookupInstances :: Text -> Env -> [InstanceInfo]
lookupInstances cls e = [ i | i <- envInstances e, iiClass i == cls ]

-- | If a name is a method of some class, return that class name.
classOfMethod :: Text -> Env -> Maybe Text
classOfMethod m e =
  case [ cn | (cn, ci) <- Map.toList (envClasses e), m `elem` ciMethodNames ci ] of
    (cn : _) -> Just cn
    []       -> Nothing

extendClass :: Text -> ClassInfo -> Env -> Env
extendClass k v e = e { envClasses = Map.insert k v (envClasses e) }

extendInstance :: InstanceInfo -> Env -> Env
extendInstance i e = e { envInstances = i : envInstances e }
```

  Export all five plus `ClassInfo(..)`, `InstanceInfo(..)`.

- [ ] **Step 4: Update `overlayEnvs`.** Find the existing `overlayEnvs` (it merges the five maps; the agent confirmed it exists and is used by `Pipeline`). Add:
  - `envInstances` of the result = `envInstances a ++ envInstances b`.
  - `envClasses` = `Map.unionWithKey` that errors on a duplicate class name across modules (mirror however `overlayEnvs` reports existing collisions; if it returns `Either`, reuse that error channel; if it errors via `Left ... CollisionError`, add a `ClassCollision Text` variant).

  If `overlayEnvs` currently destructures all fields positionally, update the pattern to include the two new fields.

- [ ] **Step 5: Write `ClassEnv` test.**

```haskell
classEnvTests :: TestTree
classEnvTests = testGroup "ClassEnv"
  [ testCase "register + lookup a class and its method" $
      let ci = TE.ClassInfo (0, Ty.KStar)
                 (Map.singleton (T.pack "==") eqScheme)
                 Map.empty [T.pack "=="]
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
```

- [ ] **Step 6: Run + commit.**

```bash
cabal test --test-options='-p ClassEnv' && cabal test --test-options='-p Env'
git commit -am "feat(env): ClassInfo/InstanceInfo namespaces + lookups + overlay"
```

---

## Task 3: Monad — constraint accumulator

**Goal:** Inference can emit constraints into a per-run accumulator and read/clear them at discharge points.

**Files:**
- Modify: `src/Wok/TypeChecking/Monad.hs` (TCCtx lines 37-49; `runTC` lines 64-79; helpers)
- Test: `test/Spec.hs` (group `ConstraintAccum`)

**Acceptance Criteria:**
- [ ] `TCCtx` gains `ctxConstraints :: STRef s [(Int, Constraint s)]` — wait: constraints carry `Type s` args during inference, not `CType`. Use an inference-time constraint alias (see Step 1).
- [ ] `addConstraint :: ConstraintS s -> TC s ()` appends; `takeConstraints :: TC s [ConstraintS s]` reads and clears.
- [ ] `runTC` initializes the accumulator.
- [ ] `cabal build`; `ConstraintAccum` test passes.

**Verify:** `cabal test --test-options='-p ConstraintAccum'` → pass.

**Steps:**

- [ ] **Step 1: Define an inference-time constraint** (a constraint whose argument is a mutable `Type s`, frozen later). Put it in `Monad.hs` (it needs `Type s`):

```haskell
-- | A constraint collected during inference; its argument is still a mutable
-- 'Type s' and is frozen to 'CType' at the binding's generalization.
data ConstraintS s = ConstraintS
  { csClass :: Text
  , csArg   :: Type s
  }
```

- [ ] **Step 2: Add the accumulator to `TCCtx`** (lines 37-49):

```haskell
  , ctxConstraints :: STRef s [ConstraintS s]   -- NEW
```

- [ ] **Step 3: Initialize in `runTC`** (lines 64-79). Add alongside `freshRef`/`warnsRef`:

```haskell
  consRef  <- newSTRef []
  let ctx = TCCtx freshRef (Level 0) env warnsRef Nothing consRef
```

  (Match the `TCCtx` field order from Step 2.)

- [ ] **Step 4: Add helpers** (next to `addWarning`):

```haskell
addConstraint :: Text -> Type s -> TC s ()
addConstraint cls arg = do
  ref <- asks ctxConstraints
  liftST $ modifySTRef' ref (ConstraintS cls arg :)

-- | Read and clear all currently-accumulated constraints.
takeConstraints :: TC s [ConstraintS s]
takeConstraints = do
  ref <- asks ctxConstraints
  liftST $ do
    cs <- readSTRef ref
    writeSTRef ref []
    pure (reverse cs)
```

  Export `ConstraintS(..)`, `addConstraint`, `takeConstraints`.

- [ ] **Step 5: Write `ConstraintAccum` test.**

```haskell
constraintAccumTests :: TestTree
constraintAccumTests = testGroup "ConstraintAccum"
  [ testCase "add then take returns in order, then empties" $
      let r = TM.runTC_ B.initialEnv $ do
                a <- TM.freshTVar Ty.KStar
                TM.addConstraint (T.pack "Eq") a
                cs1 <- TM.takeConstraints
                cs2 <- TM.takeConstraints
                pure (map TM.csClass cs1, length cs1, length cs2)
      in r @?= Right ([T.pack "Eq"], 1, 0)
  ]
```

- [ ] **Step 6: Run + commit.**

```bash
cabal test --test-options='-p ConstraintAccum'
git commit -am "feat(types): constraint accumulator in the TC monad"
```

---

## Task 4: Typed AST — `TQVar` node + `TypedDecl` evidence params

**Goal:** A use-site of a constrained identifier has a dedicated typed node carrying per-constraint class-argument types; `TypedDecl` records its evidence parameters.

**Files:**
- Modify: `src/Wok/TypeChecking/Typed.hs` (`TexpF`, lines 18-38)
- Modify: `src/Wok/TypeChecking/Infer.hs` (`TypedDecl`, lines 2213-2219)
- Test: `test/Spec.hs` (group `TypedAst` — extend)

**Acceptance Criteria:**
- [ ] `TexpF a` gains `TQVar Text [(Text, a)]` — name + per-constraint `(className, classArgType)`; the `a` payloads participate in `Functor`/`Foldable`/`Traversable` (so they freeze with the tree).
- [ ] `TypedDecl` gains `tdEvidence :: [(Text, Constraint)]` — ordered evidence parameters (param name, the constraint it satisfies).
- [ ] Deriving still works; `cabal build`; existing `TypedAst`/`typed-anf golden` groups stay green (no `TQVar` is emitted until Task 7, so output is unchanged).

**Verify:** `cabal test --test-options='-p TypedAst' && cabal test --test-options="-p 'typed-anf golden'"` → pass.

**Steps:**

- [ ] **Step 1: Add the node** to `TexpF` in `Typed.hs` (after `TParenOp`, line 30):

```haskell
  | TQVar Text [(Text, Texp a -> a)]  -- WRONG: see below
```

  Use the correct shape — the class-argument type is a bare annotation `a`, not a function:

```haskell
  | TQVar Text [(Text, a)]   -- constrained-identifier use: name + [(class, classArgType)]
```

  `deriving (Show, Functor, Foldable, Traversable)` already covers the new field because `(Text, a)` lists fold over `a`.

- [ ] **Step 2: Extend `TypedDecl`** (`Infer.hs:2213-2219`):

```haskell
data TypedDecl = TypedDecl
  { tdName     :: Text
  , tdScheme   :: Scheme
  , tdParams   :: [TPat]
  , tdBody     :: TExpr
  , tdEvidence :: [(Text, Constraint)]   -- NEW: evidence params (name, constraint)
  }
  deriving (Show)
```

  Update the three `TypedDecl { ... }` constructions (`Infer.hs:2023`, `2032`, `2292`) to add `tdEvidence = []` for now (Task 7 fills it).

- [ ] **Step 3: Extend the `TypedAst` test** to construct and fold a `TQVar`:

```haskell
  , testCase "TQVar folds over its class-arg annotations" $
      let e = Typed.Texp (10 :: Int)
                (Typed.TQVar (T.pack "==") [(T.pack "Eq", 5)])
      in sum e @?= 15   -- node ann 10 + class-arg ann 5
```

  (Add this case inside the existing `typedAstTests` group.)

- [ ] **Step 4: Run + commit.**

```bash
cabal test --test-options='-p TypedAst' && cabal test --test-options="-p 'typed-anf golden'"
git commit -am "feat(types): TQVar typed node + TypedDecl evidence params"
```

---

## Task 5: `Wok.TypeChecking.Class` — class/instance registration

**Goal:** Translate `Abs.DClass`/`Abs.DInstance` into `ClassInfo`/`InstanceInfo`, registering methods as constrained schemes, with termination + coherence checks.

**Files:**
- Create: `src/Wok/TypeChecking/Class.hs`
- Modify: `wok.cabal` (add module)
- Modify: `src/Wok/TypeChecking/Error.hs` (new error variants)
- Test: `test/Spec.hs` (group `ClassRegister`)

**Acceptance Criteria:**
- [ ] `processClassDecl :: Env -> Abs.Decl -> Either TypeError Env` registers a `ClassInfo`, adds each method's full scheme (`forall a. (C a) => <sig>`) into `envVars`, and stores defaults.
- [ ] `processInstanceDecl :: Env -> Abs.Decl -> Either TypeError Env` validates the class exists, every method is provided or has a default, runs the termination + coherence checks, mints the dict name, and registers an `InstanceInfo`.
- [ ] Termination: each context constraint's argument is structurally smaller than the head; else `InstanceNotSmaller`.
- [ ] Coherence: a second instance for the same `(class, head-tycon)` is `OverlappingInstance`.
- [ ] `ClassRegister` test passes.

**Verify:** `cabal test --test-options='-p ClassRegister'` → pass.

**Steps:**

- [ ] **Step 1: Add error variants** to `Error.hs` (`TypeError` sum type):

```haskell
  | UnknownClass Text
  | DuplicateClass Text
  | OverlappingInstance Text Text     -- class, head tycon
  | InstanceNotSmaller Text Text      -- class, head (context not structurally smaller)
  | MissingMethod Text Text           -- instance head, method
  | AmbiguousConstraint Text          -- class (constrained var absent from type)
  | NoInstance Text Text              -- class, type rendering
```

  Add `Show`/render arms matching the file's existing style.

- [ ] **Step 2: Write `Class.hs`.** This module reuses the sig translator, which lives in `Infer.hs`. To avoid an import cycle, the sig translator that `Class` needs is the *pure* `Abs.Type -> Scheme` one. If `translateSig` in `Infer.hs` is pure (it returns a `Scheme` without `TC s`), import it; if it is in `TC s`, move the pure core into a small helper `Wok.TypeChecking.Sig` (new tiny module) and import that from both `Infer` and `Class`. Check `Infer.hs:373` (`translateSig`): per the exploration it produces a `Scheme` allocating `CTGen` slots — if it is `Abs.Type -> Scheme` (pure or `Either`), reuse directly; otherwise extract its body.

  Module skeleton (assuming a reusable `schemeOfType :: Map Text Int -> Abs.Type -> Either TypeError ([(Int,Kind)], CType)` exists or is extracted — it maps free `VarId`s to `CTGen` slots and translates the body):

```haskell
module Wok.TypeChecking.Class
  ( processClassDecl
  , processInstanceDecl
  ) where

import qualified Data.Map.Strict as Map
import           Data.Text (Text)
import qualified Data.Text as Tx
import qualified GeneratedParser.Wok.Abs as Abs
import           Wok.TypeChecking.Env
import           Wok.TypeChecking.Error (TypeError (..))
import           Wok.TypeChecking.Types
import           Wok.TypeChecking.Sig (schemeOfType, typeArgToCType)  -- extracted helper(s)

-- Register a class: build ClassInfo, inject method schemes into envVars.
processClassDecl :: Env -> Abs.Decl -> Either TypeError Env
processClassDecl env (Abs.DClass (Abs.ConId (_, cname)) params entries) = do
  -- single parameter only
  pvar <- case params of
            [Abs.VarId (_, p)] -> Right p
            _ -> Left (DuplicateClass cname)   -- reuse/replace with a clearer "needs exactly one param"
  -- The class parameter is CTGen 0 throughout the class body.
  let paramMap = Map.singleton pvar 0
  methodSigs <- sequence
    [ do (vs, body) <- schemeOfType paramMap ty
         -- prepend the class constraint Eq (CTGen 0); ensure CTGen 0 is quantified
         let sch = Scheme (ensureParam vs) [Constraint cname (CTGen 0)] body
         Right (methodName mn, sch)
    | Abs.CESig mn ty <- entries ]
  let defaults = Map.fromList [ (funLhsName lhs, body)
                              | Abs.CEDefault lhs body _ <- entries ]
      ci = ClassInfo (0, KStar) (Map.fromList methodSigs) defaults
                     (map fst methodSigs)
      env1 = extendClass cname ci env
      -- inject each method into envVars so use-sites resolve + instantiate it
      env2 = foldr (\(m, s) e -> extendVar m s e) env1 methodSigs
  Right env2
processClassDecl env _ = Right env

ensureParam :: [(Int, Kind)] -> [(Int, Kind)]
ensureParam vs | any ((== 0) . fst) vs = vs
               | otherwise             = (0, KStar) : vs

methodName :: Abs.MethodName -> Text
methodName (Abs.MNBare (Abs.VarId (_, n)))  = n
methodName (Abs.MNParen (Abs.VarSym (_, n))) = n

-- funLhsName: reuse the same name-extraction Infer uses (export it or duplicate).
```

  Continue with the instance processor:

```haskell
processInstanceDecl :: Env -> Abs.Decl -> Either TypeError Env
processInstanceDecl env (Abs.DInstance ihead entries) = do
  let (ctxC, cname, targs) = splitHead ihead
  ci <- maybe (Left (UnknownClass cname)) Right (lookupClass cname env)
  headTy   <- instHeadType cname targs              -- CType for the instance head
  context  <- mapM (constraintToC) ctxC             -- [Constraint] in CTGen terms
  -- termination: each context arg structurally smaller than headTy
  mapM_ (\c -> if smaller (conArg c) headTy then Right ()
               else Left (InstanceNotSmaller cname (renderCType headTy))) context
  -- coherence: no existing instance for (cname, head tycon)
  let hc = headCon headTy
  if any (\i -> iiClass i == cname && headCon (iiHead i) == hc) (envInstances env)
    then Left (OverlappingInstance cname (Tx.pack (show hc)))
    else Right ()
  -- completeness: every method provided or defaulted
  let impls = Map.fromList [ (funLhsName lhs, body) | Abs.IEImpl lhs body _ <- entries ]
  mapM_ (\m -> if Map.member m impls || Map.member m (ciDefaults ci) then Right ()
               else Left (MissingMethod (renderCType headTy) m)) (ciMethodNames ci)
  let ii = InstanceInfo cname headTy context (dictName cname headTy) impls
  Right (extendInstance ii env)
processInstanceDecl env _ = Right env

-- A type is "smaller" than the head if it is a proper structural subterm.
smaller :: CType -> CType -> Bool
smaller x parent = x /= parent && x `elemSub` parent
  where
    elemSub t (CTCon _ ts) = any (\u -> t == u || elemSub t u) ts
    elemSub t (CTArr a _ b) = t == a || t == b || elemSub t a || elemSub t b
    elemSub _ _ = False

headCon :: CType -> TyCon
headCon (CTCon c _) = c
headCon _           = error "instance head must be a type constructor application"

dictName :: Text -> CType -> Text
dictName cls h = Tx.pack "dict$" <> cls <> Tx.pack "$" <> tyConKey (headCon h)
```

  Implement the small helpers `splitHead` (destructure `IHPlain`/`IHCtx`), `instHeadType` (translate `ConId [Type2]` to a `CType` with the class param at `CTGen 0`), `constraintToC` (translate an `Abs.Constraint` to a `Constraint` over `CTGen`), `tyConKey :: TyCon -> Text` (e.g. `TcU64 -> "U64"`, `TcUser "Option" -> "Option"`), and `renderCType` (reuse `prettyCType` from `Infer` or a local renderer). These are mechanical; show the full code in the module.

- [ ] **Step 3: Extract the reusable sig translator if needed.** If `Infer.translateSig` is not directly reusable as `Abs.Type -> Either TypeError ([(Int,Kind)], CType)`, create `src/Wok/TypeChecking/Sig.hs` containing the pure VarId->CTGen translation (move the core of `translateSig`'s `Abs.Type` walk there), and have `Infer.hs` import it. Register `Wok.TypeChecking.Sig` in `wok.cabal`. Keep `Infer.translateSig` as a thin wrapper so existing call sites and tests are unaffected.

- [ ] **Step 4: Register modules in `wok.cabal`** under `library`/`exposed-modules` (alphabetical with the other `Wok.TypeChecking.*`): `Wok.TypeChecking.Class`, and `Wok.TypeChecking.Sig` if created.

- [ ] **Step 5: Write `ClassRegister` tests** (parse a snippet, run the processors, assert env contents):

```haskell
classRegisterTests :: TestTree
classRegisterTests = testGroup "ClassRegister"
  [ testCase "class Eq registers method scheme with Eq constraint" $
      withDecls "class Eq a where\n  (==) : a -> a -> Bool\n" $ \env ->
        case TE.lookupVar (T.pack "==") env of
          Just s  -> TE.... -- assert schemeConstraints == [Eq (CTGen 0)]
          Nothing -> assertFailure "no == in env"
  , testCase "ground instance registers, ground dict name" $
      withDecls "class Eq a where\n  (==) : a -> a -> Bool\ninstance Eq U64 where\n  (==) = eqU64\n" $ \env ->
        case TE.lookupInstances (T.pack "Eq") env of
          [i] -> TE.iiDictName i @?= T.pack "dict$Eq$U64"
          _   -> assertFailure "expected one Eq instance"
  , testCase "non-smaller instance context rejected" $
      assertRejected "class Eq a where\n  (==) : a -> a -> Bool\ninstance (Eq [a]) => Eq a where\n  (==) x y = True\n"
  , testCase "overlapping instance rejected" $
      assertRejected "class Eq a where\n  (==) : a -> a -> Bool\ninstance Eq U64 where\n  (==) = eqU64\ninstance Eq U64 where\n  (==) = eqU64\n"
  ]
```

  Provide `withDecls`/`assertRejected` helpers in `Spec.hs` that parse a module (prefixing `module M\n`), reorder, fold `processClassDecl`/`processInstanceDecl` over the decls starting from `B.initialEnv`, and either hand the resulting `Env` to the callback or assert a `Left`.

- [ ] **Step 6: Run + commit.**

```bash
cabal test --test-options='-p ClassRegister'
git commit -am "feat(types): Class module - class/instance registration + decidability checks"
```

---

## Task 6: `Wok.TypeChecking.Solve` — the constraint resolver

**Goal:** A pure resolver mapping a class name + frozen class-argument type (plus the in-scope evidence-param set) to an `Evidence` term, or a precise failure. Used by both the typechecker (validate) and elaboration (build).

**Files:**
- Create: `src/Wok/TypeChecking/Solve.hs`
- Modify: `wok.cabal`
- Test: `test/Spec.hs` (group `Solve`)

**Acceptance Criteria:**
- [ ] `resolve :: Env -> Set Int -> Text -> CType -> Either SolveError Evidence`:
  - class-arg is `CTGen i` and `i` is in the param set -> `Right (EvParam (paramName cls i))`.
  - class-arg is a concrete `CTCon c args`: find the instance for `(cls, c)`; recurse on its context (each context constraint instantiated by matching the head's `CTGen`s to `args`) -> `Right (EvGlobal d)` if context empty, else `Right (EvApp d subEv)`.
  - class-arg is `CTGen i` not in the param set -> `Left (Ambiguous cls)`.
  - no matching instance -> `Left (NoInst cls (render arg))`.
- [ ] `paramName :: Text -> Int -> Text` is the canonical evidence-param name (`d$<cls>$<i>`), shared with `tdEvidence` minting in Task 7.
- [ ] `Solve` test passes.

**Verify:** `cabal test --test-options='-p Solve'` → pass.

**Steps:**

- [ ] **Step 1: Write `Solve.hs`.**

```haskell
module Wok.TypeChecking.Solve
  ( SolveError (..)
  , resolve
  , paramName
  ) where

import qualified Data.Map.Strict as Map
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text)
import qualified Data.Text as Tx
import           Wok.TypeChecking.Env
import           Wok.TypeChecking.Types

data SolveError
  = NoInst Text CType
  | Ambiguous Text
  deriving (Eq, Show)

paramName :: Text -> Int -> Text
paramName cls i = Tx.pack "d$" <> cls <> Tx.pack "$" <> Tx.pack (show i)

resolve :: Env -> Set Int -> Text -> CType -> Either SolveError Evidence
resolve env params cls arg = case arg of
  CTGen i
    | i `Set.member` params -> Right (EvParam (paramName cls i))
    | otherwise             -> Left (Ambiguous cls)
  CTCon c cargs ->
    case [ i | i <- lookupInstances cls env, headConEq (iiHead i) c ] of
      (inst : _) -> do
        sub <- instMatch (iiHead inst) arg          -- CTGen idx -> concrete arg
        evs <- mapM (\ctx -> resolve env params (conClass ctx)
                              (applySub sub (conArg ctx)))
                    (iiContext inst)
        Right $ if null evs then EvGlobal (iiDictName inst)
                            else EvApp (iiDictName inst) evs
      [] -> Left (NoInst cls arg)
  _ -> Left (NoInst cls arg)
  where
    headConEq (CTCon hc _) c = hc == c
    headConEq _            _ = False
```

  Implement `instMatch :: CType -> CType -> Either SolveError (Map Int CType)` (align the instance head's `CTGen`s with the concrete argument's children; for `Eq (Option a)` vs `Eq (Option U64)` it yields `{0 -> U64}`) and `applySub :: Map Int CType -> CType -> CType` (substitute `CTGen`s). Both are small structural recursions; include full code.

- [ ] **Step 2: Register `Wok.TypeChecking.Solve` in `wok.cabal`.**

- [ ] **Step 3: Write `Solve` tests** against a hand-built env (an `Eq U64` ground instance and an `Eq (Option a)` constrained instance):

```haskell
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
    u64Inst = TE.InstanceInfo (T.pack "Eq") (Ty.CTCon Ty.TcU64 []) []
                (T.pack "dict$Eq$U64") Map.empty
    optInst = TE.InstanceInfo (T.pack "Eq")
                (Ty.CTCon (Ty.TcUser (T.pack "Option")) [Ty.CTGen 0])
                [Ty.Constraint (T.pack "Eq") (Ty.CTGen 0)]
                (T.pack "dict$Eq$Option") Map.empty
```

- [ ] **Step 4: Run + commit.**

```bash
cabal test --test-options='-p Solve'
git commit -am "feat(types): Solve - shared constraint resolver (evidence construction)"
```

---

## Task 7: Infer integration — qualified sigs, constraint emission, discharge, dispatch

**Goal:** Class methods and constrained functions typecheck end to end: qualified signatures translate, use-sites emit constraints and build `TQVar` nodes, generalization produces qualified schemes with `tdEvidence`, concrete constraints are validated, and `class`/`instance` decls are registered in `inferProgramTC`.

**Files:**
- Modify: `src/Wok/TypeChecking/Infer.hs` (`translateSig` ~373; `inferExprW` EVar 1265, EParenOp 1285; `inferInfixOpW`/`lookupOpNameW` 1699-1715; `instantiate` ~220; `finalizeGroupTyped` 1997-2040; `inferProgramTC` 2243-2260)
- Test: `test/Spec.hs` (group `EqInfer`)

**Acceptance Criteria:**
- [ ] `translateSig` accepts `Abs.TQual ctx ty`: the constraints become the scheme's `schemeConstraints` (over the same `CTGen` mapping as the body).
- [ ] Instantiating a scheme with `schemeConstraints` emits one `addConstraint` per constraint (with the instantiated `Type s` arg), and the use-site builds a `TQVar name [(class, argTy)]` node instead of `TVar`/`TParenOp`.
- [ ] `inferProgramTC` registers `class`/`instance` decls (via `Class`) BEFORE inferring equations, so method names resolve.
- [ ] At `finalizeGroupTyped`: constraints whose frozen arg is a quantified `CTGen` of this binding become `tdEvidence` (and `schemeConstraints`); constraints whose frozen arg is concrete are validated with `Solve.resolve env Set.empty` (error on `NoInst`); a constrained var absent from the scheme body is `AmbiguousConstraint`.
- [ ] `1 == 2` infers `Bool`; `isEq x y = x == y` gets scheme `forall a. (Eq a) => a -> a -> Bool` and `tdEvidence = [("d$Eq$0", Eq (CTGen 0))]`; `eq` on a type with no instance errors; an ambiguous use errors.
- [ ] All existing typecheck goldens stay green (non-constrained schemes emit no constraints, no `TQVar`).

**Verify:** `cabal test --test-options='-p EqInfer'` → pass; `cabal test --test-options="-p 'typecheck success golden'"` → unchanged.

**Steps:**

- [ ] **Step 1: Qualified signatures in `translateSig`.** At the top of the `Abs.Type` walk (`Infer.hs:373+`), handle `TQual` first: translate the inner type to `(vars, body)`, translate each `Abs.Constraint (ConId (_,c)) [Type2]` to a `Constraint c argC` using the SAME `VarId -> CTGen` map the body used, and return a `Scheme vars constraints body`. For non-`TQual` types, return `Scheme vars [] body` (i.e. `mkScheme`). Show the exact case:

```haskell
-- inside translateSig's worker, before the TFun/TWith/... cases:
goTop (Abs.TQual cs inner) = do
  (vars, body) <- goBody inner          -- existing translation, returns vars+CType
  constraints  <- mapM (goConstraint) cs
  pure (Scheme vars constraints body)
goTop other = do
  (vars, body) <- goBody other
  pure (Scheme vars [] body)

goConstraint (Abs.Constraint (Abs.ConId (_, c)) targs) = do
  argC <- goConArg targs                -- translate the single type arg to CType (CTGen-keyed)
  pure (Constraint c argC)
```

  (Adapt names to the real `translateSig` structure; the key point is constraints share the body's variable->`CTGen` map.)

- [ ] **Step 2: Emit constraints at instantiation + build `TQVar`.** The cleanest single choke point is `instantiate` (`Infer.hs:~220`), which turns a `Scheme` into a `Type s` by freshening quantifiers. Change it to ALSO return the instantiated constraint args, so callers can emit them and build the node. Add a sibling that returns them:

```haskell
-- returns (instantiated body type, [(class, instantiated arg Type s)])
instantiateQ :: Scheme -> TC s (Type s, [(Text, Type s)])
instantiateQ (Scheme vars constraints body) = do
  subst <- freshSubstFor vars            -- existing logic inside instantiate
  let t  = applySubstC subst body        -- existing: CType+subst -> Type s
      cs = [ (conClass c, applySubstC subst (conArg c)) | c <- constraints ]
  pure (t, cs)

instantiate :: Scheme -> TC s (Type s)   -- keep for non-constrained callers
instantiate s = fst <$> instantiateQ s
```

  Then in the EVar case (`Infer.hs:1265-1274`), use `instantiateQ` and branch on whether constraints came back:

```haskell
inferExprW mono (Abs.EVar (Abs.VarId (pos, name))) =
  case Map.lookup name mono of
    Just t -> pure (t, Ty.Texp t (Ty.TVar name))
    Nothing -> do
      env <- currentEnv
      case lookupVar name env of
        Just s -> do
          (t, cs) <- instantiateQ s
          mapM_ (\(cls, arg) -> addConstraint cls arg) cs
          let node | null cs   = Ty.TVar name
                   | otherwise = Ty.TQVar name cs   -- cs :: [(Text, Type s)] = [(class, argTy)]
          pure (t, Ty.Texp t node)
        Nothing -> throwError (UnknownVar (Just pos) name)
```

  Apply the identical change to `EParenOp` (1285-1294) building `TQVar name cs`, and to `lookupOpNameW` (1699-1715): when the op's scheme has constraints, the operator-chain node builder (`applyTails`, 1373-1380) must use `TQVar opName cs` as the applied head instead of `TVar opName`. Thread `cs` out of `lookupOpNameW` (change its return to `(Type s, Text, [(Text, Type s)])`) and have `applyTails` build `Ty.Texp opTy (if null cs then Ty.TVar opName else Ty.TQVar opName cs)`.

- [ ] **Step 3: Register class/instance decls in `inferProgramTC`** (`Infer.hs:2243-2260`). After `processEffectDecls` (line 2250) and before building `localDecls`, fold the pure registrars over the decls. Because they are `Either TypeError Env`, lift with `liftEither`/`either throwError pure`:

```haskell
  env1e <- processEffectDecls env1 decls
  env1c <- either throwError pure (foldM Class.processClassDecl    env1e [ d | d@Abs.DClass{}    <- decls ])
  env1i <- either throwError pure (foldM Class.processInstanceDecl env1c [ d | d@Abs.DInstance{} <- decls ])
  withEnv (const env1i) $ do
    ...
```

  Import `qualified Wok.TypeChecking.Class as Class` and `Control.Monad (foldM)`.

- [ ] **Step 4: Discharge + `tdEvidence` at `finalizeGroupTyped`** (`Infer.hs:1997-2040`). After computing the frozen scheme + tree (both signed and unsigned paths), process this binding's constraints:
  1. `cs <- takeConstraints` (the constraints accumulated while inferring this binding's body).
  2. Freeze each constraint's `Type s` arg with the SAME mapping used for the scheme. Simplest: include the constraint args in the synthetic tree that `generalizeTyped` freezes, so they get consistent `CTGen` numbering. Concretely, before generalizing, build a synthetic node that references each constraint arg (e.g. extend the synthetic `TLam` wrapper to also carry the constraint args as extra `TQVar` children), generalize, then read back the frozen args. Alternatively, freeze each arg via the same `freezeQuantify` refs `generalizeTyped` uses by inlining the constraint freeze into `generalizeTyped` (add a `[Constraint s] -> ([Constraint], ...)` parameter). Pick the inlined-into-`generalizeTyped` approach: give `generalizeTyped` an extra `[ConstraintS s]` argument and have it freeze those args alongside the body, returning `(Scheme, TExpr, [Constraint])`.
  3. Partition the frozen constraints:
     - arg is `CTGen i` AND `i` is a quantifier of this scheme -> a residual constraint; collect `(paramName cls i, Constraint cls (CTGen i))` for `tdEvidence` and add `Constraint cls (CTGen i)` to `schemeConstraints`.
     - arg is `CTGen i` but `i` is NOT a quantifier (a monomorphic local) -> defer by re-emitting via `addConstraint` (it belongs to an outer binding). For the top-level slice this should not occur; if it does at the very top, raise `AmbiguousConstraint cls`.
     - arg is concrete -> validate with `Solve.resolve env Set.empty cls arg`; `Left (NoInst ..)` -> `throwError (NoInstance cls (render arg))`; `Left (Ambiguous ..)` -> `throwError (AmbiguousConstraint cls)`; `Right _` -> discharged (no residual).
  4. Dedup residual constraints by `(cls, i)` so `tdEvidence` has one param per distinct quantified constraint, ordered by `i`.
  5. Build `TypedDecl { ..., tdScheme = scheme { schemeConstraints = residual }, tdEvidence = evParams }`.

  Show the discharge helper in full:

```haskell
dischargeBinding
  :: Env -> Scheme -> [Constraint]            -- frozen constraints for this binding
  -> TC s (Scheme, [(Text, Constraint)])
dischargeBinding env sch frozen = do
  let qs = Set.fromList (map fst (schemeVars sch))
  residual <- fmap concat $ forM (nubByClassArg frozen) $ \c ->
    case conArg c of
      CTGen i | i `Set.member` qs -> pure [c]
              | otherwise         -> throwError (AmbiguousConstraint (conClass c))
      arg -> case Solve.resolve env Set.empty (conClass c) arg of
        Right _              -> pure []
        Left (Solve.NoInst cls a)  -> throwError (NoInstance cls (renderCType a))
        Left (Solve.Ambiguous cls) -> throwError (AmbiguousConstraint cls)
  let evParams = [ (Solve.paramName (conClass c) i, c)
                 | c <- residual, CTGen i <- [conArg c] ]
  pure (sch { schemeConstraints = residual }, evParams)
```

  Wire `dischargeBinding` into both `finalizeGroupTyped` paths, using the env from `currentEnv`. For the SIGNED path, the declared scheme already has `schemeConstraints`; validate that the accumulated constraints are entailed by the declared ones (each accumulated concrete constraint resolves; each accumulated `CTGen` constraint is among the declared constraints) and set `tdEvidence` from the DECLARED `schemeConstraints` (so `isEq`'s declared `(Eq a) =>` yields `tdEvidence = [("d$Eq$0", Eq (CTGen 0))]`).

- [ ] **Step 5: Inner let-groups.** `finalizeGroup` (non-typed, `Infer.hs:1961`) is used for nested lets; for the minimal slice, nested constrained lets are out of scope. Guard: if `takeConstraints` is non-empty at a non-top `finalizeGroup` whose binding does not generalize them, re-emit them so they reach the enclosing top-level binding (do not drop). This preserves correctness for the common case (constraints flow to the top-level binding that owns the use).

- [ ] **Step 6: Write `EqInfer` tests.** Use the `withDecls`-style harness but run the FULL `inferProgramWith` so registration + inference + discharge all execute. Build modules as strings prefixed with the `Eq` class + `Eq U64` instance.

```haskell
eqInferTests :: TestTree
eqInferTests = testGroup "EqInfer"
  [ testCase "1 == 2 : Bool" $
      typeOfMain (preludeEq <> "main = 1 == 2\n") $ \scheme ->
        Ty.schemeBody scheme @?= Ty.CTCon Ty.TcBool []
  , testCase "isEq gets forall a. (Eq a) => a -> a -> Bool + evidence param" $
      declScheme (preludeEq <> "isEq x y = x == y\n") (T.pack "isEq") $ \d -> do
        TC.schemeConstraintsOf d @?= [Ty.Constraint (T.pack "Eq") (Ty.CTGen 0)]   -- adapt accessor
        map fst (TC.tdEvidence d) @?= [T.pack "d$Eq$0"]
  , testCase "no instance for Eq String errors" $
      assertTypeError (preludeEq <> "bad = \"a\" == \"b\"\n")
  , testCase "ambiguous constraint errors" $
      assertTypeError (preludeEq <> "amb : (Eq a) => Bool\namb = True\n")
  ]
  where
    preludeEq = "class Eq a where\n  (==) : a -> a -> Bool\n  (/=) : a -> a -> Bool\ninstance Eq U64 where\n  (==) = eqU64\n"
```

  Provide `typeOfMain`/`declScheme`/`assertTypeError` helpers (parse with `module M\n` prefix, `reorderModule`, `TC.inferProgramWith B.initialEnv SO.Embedded`, find the named decl or assert `Left`). Note: `eqU64` must be in scope; add a bodyless sig `eqU64 : U64 -> U64 -> Bool` to the test snippet so inference of the instance impl resolves it (the real prelude adds this in Task 10).

- [ ] **Step 7: Run + commit.**

```bash
cabal test --test-options='-p EqInfer' && cabal test --test-options="-p 'typecheck success golden'"
git commit -am "feat(types): qualified sigs, constraint emission/discharge, class dispatch"
```

---

## Task 8: Prim rename + interpreter CAF fix

**Goal:** The raw U64 equality prim is `eqU64` (not `==`), and the interpreter evaluates 0-arity top-level binds to values once instead of rejecting them.

**Files:**
- Modify: `src/Wok/Interp/Prim.hs:23-24`
- Modify: `src/Wok/Interp/Machine.hs:189-199` (`runModule`)
- Test: `test/Spec.hs` (groups `InterpPrim` — update; `InterpCaf` — new)

**Acceptance Criteria:**
- [ ] `primTable` has `eqU64` (arity 2, integer equality) and no `==`/`/=`.
- [ ] `runModule` evaluates every 0-arity top-level bind (including `main`'s siblings) to a `Value` once, in a knot-tied global env, and binds the value (not an unforced `VClosure`); function binds (arity > 0) remain `VClosure`s.
- [ ] A module with a 0-arity non-`main` constant runs (no `UnsupportedCaf`).
- [ ] Existing `run golden` outputs stay byte-identical.

**Verify:** `cabal test --test-options='-p InterpPrim' && cabal test --test-options='-p InterpCaf' && cabal test --test-options="-p 'run golden'"` → pass.

**Steps:**

- [ ] **Step 1: Rename the prim.** In `Prim.hs` `prims` list (lines 23-24), replace:

```haskell
  , cmp (Tx.pack "==") (==)
  , cmp (Tx.pack "/=") (/=)
```

  with:

```haskell
  , cmp (Tx.pack "eqU64") (==)
```

  (`/=` is dropped; the class default `(/=) x y = not (x == y)` covers inequality.)

- [ ] **Step 2: CAF fix in `runModule`.** Replace the body (lines 189-199) with a knot-tied env where 0-arity binds are forced to values and function binds stay closures. Forcing must run on the SAME `gEnv` so dict bodies can reference other globals:

```haskell
runModule :: CoreModule -> Either RuntimeError Value
runModule (CoreModule binds) =
  let -- Knot: gEnv refers to itself; lazy Map values are forced on demand.
      gEnv = Map.fromList (map entry binds)
      entry (TopBind n ps body)
        | null ps   = (nameUniq n, forceTop body)   -- 0-arity CAF: evaluate once
        | otherwise = (nameUniq n, VClosure gEnv ps body)
      forceTop body = case run primTable (Eval body (Scope gEnv Map.empty) KDone) of
        Right v  -> v
        Left err -> errorValue err     -- see note
  in case [ tb | tb@(TopBind n _ _) <- binds, nameHint n == Tx.pack "main" ] of
       (TopBind _ [] body : _) -> run primTable (Eval body (Scope gEnv Map.empty) KDone)
       (TopBind{}         : _) -> Left (ArityError (Tx.pack "main must take no arguments"))
       []                      -> Left (UnboundVar (Tx.pack "main"))
```

  Two correctness notes to resolve in code:
  - **Error in a CAF body:** `forceTop` cannot return `Either` lazily inside the `Map` without complicating the knot. Prefer making the global env hold `Value` via `Data.Map`'s laziness in values: build `gEnv` with lazy values (`Map.fromList` values are lazy by default in `Data.Map.Strict`? No — `Data.Map.Strict` is strict in values). Use `Data.Map.Lazy` for `gEnv` specifically, or precompute non-`main` CAFs in dependency-agnostic order by relying on closure laziness: since a dict body only *projects/forces* other globals when its methods are *called*, and method closures capture `gEnv` lazily, forcing a dict to `VRecord` only evaluates the record spine (field closures are `VClosure gEnv ...`), which does not recurse into other CAFs at force time. Therefore force-time cycles do not arise for dictionaries. Implement `gEnv` with `Data.Map.Lazy.fromList` so the self-reference is well-founded, and have `forceTop` return a `Value` by `either (\e -> ...) id`. For a clean failure, thread errors by making 0-arity values `VThunk (Either RuntimeError Value)` — but that enlarges `Value`. SIMPLEST acceptable approach for the slice: assume CAF bodies do not fail (dictionaries never do); on a `Left`, `error (show err)` is acceptable since it indicates a compiler bug, mirroring elaboration's panic-on-impossible policy. Document this in a comment.
  - Switch the `runModule` import to `import qualified Data.Map.Lazy as Map` ONLY for building `gEnv`, or build the knot with `Data.Map.Strict` but wrap CAF values in a lazy thunk via `let`-bound laziness. Choose `Data.Map.Lazy` for `gEnv`.

- [ ] **Step 3: Update `InterpPrim` tests** that referenced `==`/`/=` to use `eqU64` (grep the test file for `"=="`/`"/="` prim usages and update). The arithmetic/bool prim tests are unaffected.

- [ ] **Step 4: Write `InterpCaf` test** — a hand-built `CoreModule` with a 0-arity constant the `main` body uses:

```haskell
interpCafTests :: TestTree
interpCafTests = testGroup "InterpCaf"
  [ testCase "0-arity top-level constant is forced and shared" $
      -- module: answer = 42 ; main = answer
      let answer = Anf.TopBind (mkName "answer" 0) []
                     (Anf.Ret (Anf.ALit (Anf.LInt 42)))
          mainB  = Anf.TopBind (mkName "main" 1) []
                     (Anf.Ret (Anf.AVar (mkName "answer" 0)))
          cm = Anf.CoreModule [answer, mainB]
      in Interp.runModule cm @?= Right (Interp.VLit (Anf.LInt 42))
  ]
```

  Provide `mkName hint uniq = Name (T.pack hint) (Unique uniq)` (import `Wok.IR.Name`).

- [ ] **Step 5: Run + commit.**

```bash
cabal test --test-options='-p InterpPrim' && cabal test --test-options='-p InterpCaf' && cabal test --test-options="-p 'run golden'"
git commit -am "feat(interp): eqU64 prim; force 0-arity CAFs to values (knot-tied gEnv)"
```

---

> **SUPERSEDED (2026-06-04, after Task 8).** Tasks 9–11 below were re-scoped during
> execution — see the **"RE-SCOPE: Tasks 9–12"** section near the end of this file.
> The original approach (lowering instances in elaboration) was unworkable: instance
> method bodies are stored as raw `Abs.Exp` (never typechecked, so elaboration has no
> `TExpr` for them), and operator method names cannot be record field labels. The
> re-scope desugars instances into synthetic typed top-level bindings via the normal
> inference path, and represents dictionaries as a data constructor. Read the RE-SCOPE
> section; the three sections immediately below are kept only for history.

## Task 9 (SUPERSEDED): Elaboration — lower `TQVar`, evidence params, instance dicts

**Goal:** Elaboration turns constrained use-sites into dictionary projections/applications, prepends evidence-parameter binders, and lowers `class`/`instance` decls into dictionary `TopBind`s with default methods specialized.

**Files:**
- Modify: `src/Wok/IR/Elaborate.hs` (`elabRhsF`/`elabKF` for the new node ~225-352; `elabTopBind` 605-612; `elaborateModule` 617-625; `elaborateModulesShared` 631-642)
- Test: `test/Spec.hs` (groups `ElaborateClass` — new)

**Acceptance Criteria:**
- [ ] A `TQVar name cs` node lowers via `Solve.resolve env params <class> <argTy>` per constraint:
  - if `name` is a class method (its class in `envClasses`): `(<ev>.name) args` — `RProj name <evAtom>` then apply.
  - else: `name <ev>... args` — `RApp name (evAtoms ++ args)`.
- [ ] Evidence terms become atoms: `EvGlobal d` -> global `AVar` for `d`; `EvParam p` -> the in-scope evidence binder; `EvApp d evs` -> a `Let`-bound `RApp d evs` producing the dict atom.
- [ ] A binding with `tdEvidence` gets one leading `Binder` per evidence param (typed as the dict record type) added before its value params; those names populate the in-scope param set passed to `Solve`.
- [ ] Each `InstanceInfo` lowers to a `TopBind`: ground -> 0-arity `RRecord <Class> [(method, impl-atom)]`; constrained -> a lambda over its context dicts producing the record. Default methods are specialized by substituting the instance's own method impls for class-method references.
- [ ] `elaborateModule`/`elaborateModulesShared` emit instance dict `TopBind`s and mint global names for dict names + evidence consumers.
- [ ] `ElaborateClass` tests pass; existing `Elaborate*` groups stay green.

**Verify:** `cabal test --test-options='-p Elaborate'` → all pass.

**Steps:**

- [ ] **Step 1: Carry the evidence-param scope in `ElabCtx`.** Add `ecEvidence :: Map.Map Int Name` (quantified-constraint index -> the dict binder name) and `ecClasses :: Map Text ... ` is already reachable via `ecEnv`. Update the `ElabCtx` record and its constructions.

- [ ] **Step 2: Lower `TQVar`.** Add a case to `elabRhsF` (the worker behind `elabRhs`, `Elaborate.hs:227`). For a constrained var used as the head of an application, the existing app path collects the spine; handle `TQVar` both as a bare value and as an app head. Representative code:

```haskell
elabRhsF ty (TQVar name cs) k = do
  env <- asks ecEnv
  evScope <- asks ecEvidence
  -- Build an evidence atom per constraint.
  evAtoms <- mapM (evidenceAtom env evScope) cs   -- cs :: [(Text, CType)]
  case classOfMethod name env of
    Just _cls ->
      -- class method: project off its (single) evidence dict, then it's a function value
      case evAtoms of
        [d] -> k (RProj name d)
        _   -> error "Eq slice: class methods have exactly one constraint"
    Nothing ->
      -- ordinary constrained function: pass dicts as leading args (partial application)
      resolveVar name >>= \fnAtom -> case fnAtom of
        AVar fn -> k (RApp (AVar fn) evAtoms)   -- remaining value args applied by the spine
        _       -> error "constrained function name did not resolve"
```

  `evidenceAtom :: Env -> Map Int Name -> (Text, CType) -> Elab Atom` calls `Solve.resolve env (Map.keysSet scope) cls argTy` and lowers the `Evidence`:

```haskell
evidenceAtom env scope (cls, argTy) =
  case Solve.resolve env (Map.keysSet scope) cls argTy of
    Right ev -> lowerEv ev
    Left e   -> error ("Eq slice: unresolved evidence at elaboration: " ++ show e)
  where
    lowerEv (EvGlobal d) = resolveVar d            -- global dict name
    lowerEv (EvParam p)  = pure (AVar (paramBinderFor p scope))  -- map name back to binder
    lowerEv (EvApp d es) = do
      args <- mapM lowerEv es
      dAtom <- resolveVar d
      n <- bindFresh (Tx.pack "dict")
      -- emit: let n = d args in <n>
      -- (return n as the atom; the surrounding k builds the Let)
      ... -- bind via a Let in the current continuation
```

  Note: the spine collection in elaboration normally wraps non-atomic RHS in `Let`s via `normName`; reuse that machinery so the `EvApp` dict and the projected method compose with the existing app normalization. The exact integration mirrors how `TApp`/`TProj` are already normalized (`Elaborate.hs:282`). Because `(==) x y` parses as an operator chain -> `TApp (TQVar "==" cs) [x, y]`, ensure the `TApp` case, when its head is a `TQVar` that is a class method, lowers to `RApp (projected-method-atom) [x, y]`. Implement by special-casing `TApp (Texp _ (TQVar name cs)) args` in `elabRhsF`/the app path: build the method/function atom from the `TQVar` (projection or partial-app), then apply `args`.

- [ ] **Step 3: Prepend evidence-param binders in `elabTopBind`** (`Elaborate.hs:605-612`). Before elaborating params, create one `Binder` per `tdEvidence` entry (named `paramName cls i`, typed as the dict record type for that class — use a `CTRecord <Class> CREmpty` placeholder type, since binder types are erased at runtime) and extend `ecEvidence` mapping each constrained `CTGen i` to that binder's `Name`:

```haskell
elabTopBind globals td = do
  let fname = tdName td
      name  = Map.findWithDefault (errName fname) fname globals
  (evBinders, evMap) <- mkEvidenceParams (tdEvidence td)
  (paramBinders, extender) <- elabParams (tdParams td)
  bodyExpr <- local (\c -> c { ecEvidence = evMap })
                    (extender (elabTail (tdBody td)))
  pure (TopBind name (evBinders ++ paramBinders) bodyExpr)
```

  `mkEvidenceParams :: [(Text, Constraint)] -> Elab ([Binder], Map Int Name)` mints a `Name` per entry and pairs the `CTGen i` (from `conArg`) to it.

- [ ] **Step 4: Lower instances to dict `TopBind`s.** Add `instanceTopBinds :: Map Text Name -> Env -> Elab [TopBind]` that, for each `InstanceInfo` in `envInstances env`, builds:
  - the method bodies: for each class method, use `iiImpls` if present, else specialize the class default (`ciDefaults`) by substituting the instance's own method impls for class-method references (a syntactic `Abs.Exp` rewrite: replace occurrences of method name `m` with the instance's impl/closure). Elaborate each body to an `Atom`-producing expression bound to the record field.
  - ground instance (empty `iiContext`): `TopBind dictName [] (RRecord <Class> [(m, methodAtom)] -> Ret)`. The record fields are themselves functions; bind each as a `Let` of an `RLam`, then `Ret (record)`. 
  - constrained instance: `TopBind dictName [evParamBinders] body` where `evParamBinders` is one dict binder per `iiContext` constraint, in scope for the field bodies.

  Default-method specialization helper:

```haskell
-- Replace class-method references in a default body with the instance's impls.
specializeDefault :: Map Text Abs.Exp -> Abs.Exp -> Abs.Exp
specializeDefault impls = rewrite
  where rewrite e = ...substitute (EVar/EParenOp m) with impls!m where present...
```

  For `Eq U64`, the `(/=)` default `not (x == y)` becomes `not (eqU64 x y)` because the instance's `(==)` impl is `eqU64`.

- [ ] **Step 5: Emit instance binds in module elaboration.** In `elaborateModule` (617-625) and `elaborateModulesShared` (631-642): mint global names for every instance `dictName` AND every value global (the existing `Map.keys (envVars env)`), then produce `binds = instanceTopBinds globals env ++ map (elabTopBind globals) tds`. Filter bodyless sigs as today. Ensure `dictName`s are in `globals` so `resolveVar` finds them.

- [ ] **Step 6: Write `ElaborateClass` tests.** Use the full pipeline on a small typed program (parse -> infer -> elaborate) and assert ANF shape:

```haskell
elaborateClassTests :: TestTree
elaborateClassTests = testGroup "ElaborateClass"
  [ testCase "instance Eq U64 lowers to a 0-arity dict TopBind" $
      elaborateSrc (preludeEq <> "main = 1 == 2\n") $ \cm ->
        assertBool "dict$Eq$U64 present as 0-arity bind"
          (any (\b -> nameHint (Anf.tbName b) == T.pack "dict$Eq$U64" && null (Anf.tbParams b))
               (Anf.cmBinds cm))
  , testCase "x == y lowers to projection + apply" $
      elaborateSrc (preludeEq <> "main = 1 == 2\n") $ \cm ->
        assertBool "main projects == off a dict" (mainProjectsEq cm)
  ]
```

  Provide `elaborateSrc` (load prelude-less module string through `Pipeline.elaborateProgram` using a test loader, or assemble `LoadedModule`s directly) and the shape predicates.

- [ ] **Step 7: Run + commit.**

```bash
cabal test --test-options='-p Elaborate'
git commit -am "feat(ir): lower TQVar to dict proj/apply; instances to dict binds"
```

---

## Task 10: Prelude `Eq` + end-to-end run goldens

**Goal:** `Eq`, `instance Eq U64`, `not`, and the `eqU64` builtin sig live in the prelude; full programs using `Eq` run correctly.

**Files:**
- Modify: `prelude/Std/Base.wok`
- Create: `test/run-examples/10-eq-u64.wok`, `11-eq-option.wok`, `12-eq-poly.wok`, `13-ne-default.wok`
- Test: `test/Spec.hs` (`run golden` auto-discovers; goldens generated)

**Acceptance Criteria:**
- [ ] `prelude/Std/Base.wok` declares `class Eq a` (with `(==)`, `(/=)`, and the `(/=)` default), `instance Eq U64 where (==) = eqU64`, `not : Bool -> Bool` (with body), and `eqU64 : U64 -> U64 -> Bool` (bodyless builtin sig). The old monomorphic `(==)`/`(/=)` sigs are removed.
- [ ] Four run examples produce correct values: `eq` on `U64`, `eq` on `Option U64` (constrained instance), a polymorphic `(Eq a) =>` function at two types, and `/=` via the default.
- [ ] All existing `run golden`, `typecheck success golden`, `anf golden`, `typed-anf golden` stay green (the prelude change affects only the removed `==`/`/=` sigs — confirm no existing example relied on the OLD monomorphic `==`; if one does, it now goes through the class and must still produce the same value).

**Verify:** `cabal test --test-options="-p 'run golden'"` → all pass (incl. the four new ones).

**Steps:**

- [ ] **Step 1: Edit `prelude/Std/Base.wok`.** Remove the `(==)`/`(/=)` sig lines (24-25). Keep the fixity lines (they still apply to the operators). Add:

```wok
eqU64 : U64 -> U64 -> Bool

not : Bool -> Bool
not x = case x of
  True  -> False
  False -> True

class Eq a where
  (==) : a -> a -> Bool
  (/=) : a -> a -> Bool
  (/=) x y = not (x == y)

instance Eq U64 where
  (==) = eqU64
```

  (Keep `instance (Eq a) => Eq (Option a)` OUT of the prelude unless a run example needs it from the prelude; the `11-eq-option.wok` example can declare it locally, exercising user-defined constrained instances. Decide: declaring it in the prelude is fine too — choose the prelude to make all four examples terse. If in the prelude, `Option` is already defined there at line 15.)

  Add to the prelude:

```wok
instance (Eq a) => Eq (Option a) where
  (==) x y =
    case (x, y) of
      (None, None)     -> True
      (Some a, Some b) -> a == b
      _                -> False
```

- [ ] **Step 2: Confirm `eqU64` resolves at runtime.** `eqU64` has a bodyless sig (so it typechecks) and is NOT a top-level bind, so at runtime `resolveAtom` falls through to the prim table where `eqU64` now lives (Task 8). Verify this path: a reference to `eqU64` mints a global Name with hint `eqU64`; `resolveAtom` misses scope, hits `Map.lookup "eqU64" primTable` -> the prim. Good (this is exactly how `+`/`-` work today).

- [ ] **Step 3: Write run examples.**

  `test/run-examples/10-eq-u64.wok`:

```wok
module Run.EqU64
main = if 3 == 3 then 1 else 0
```

  `test/run-examples/11-eq-option.wok`:

```wok
module Run.EqOption
main = if (Some 4) == (Some 4) then 1 else 0
```

  `test/run-examples/12-eq-poly.wok`:

```wok
module Run.EqPoly
allEq : (Eq a) => a -> a -> a -> Bool
allEq x y z = (x == y) && (y == z)
main = if allEq 7 7 7 then 1 else 0
```

  `test/run-examples/13-ne-default.wok`:

```wok
module Run.NeDefault
main = if 2 /= 3 then 1 else 0
```

- [ ] **Step 4: Generate + inspect run goldens.**

```bash
cabal test --test-options="-p 'run golden' --accept"
```

  Inspect `test/run-golden/{10-eq-u64,11-eq-option,12-eq-poly,13-ne-default}.expected` — each must be `1`. Re-run without `--accept` to confirm clean. Also confirm the pre-existing run goldens (`01`..`09`) are unchanged.

- [ ] **Step 5: Run full suite + commit.**

```bash
cabal test
git add prelude/Std/Base.wok test/run-examples/10-eq-u64.wok test/run-examples/11-eq-option.wok test/run-examples/12-eq-poly.wok test/run-examples/13-ne-default.wok test/run-golden/
git commit -m "feat(prelude): Eq class, Eq U64/Option instances, not; end-to-end run goldens"
```

---

## Task 11: Negative goldens + regression sweep

**Goal:** Pin the error behavior (no-instance, ambiguity, non-terminating instance) and prove the whole feature is behavior-preserving for non-class code.

**Files:**
- Create: `test/typecheck-fail-examples/{27-eq-no-instance,28-eq-ambiguous,29-eq-bad-instance}.wok`
- Test: `test/Spec.hs` (`typecheck fail golden` auto-discovers)

**Acceptance Criteria:**
- [ ] `27-eq-no-instance.wok` (`"a" == "b"` with no `Eq String`) fails typechecking with a `NoInstance Eq String`-style message.
- [ ] `28-eq-ambiguous.wok` (`amb : (Eq a) => Bool`) fails with `AmbiguousConstraint`.
- [ ] `29-eq-bad-instance.wok` (`instance (Eq [a]) => Eq a`) fails with `InstanceNotSmaller`.
- [ ] The erased `anf golden` and `run golden` for ALL pre-existing examples (`01`..`09` run; `01`..`25` anf) are byte-identical to before this branch.
- [ ] `cabal test` is fully green.

**Verify:** `cabal test` → all pass; `git diff --stat <branch-base> -- test/anf-golden test/run-golden` shows only ADDED files, none modified.

**Steps:**

- [ ] **Step 1: Write the failing fixtures.**

  `test/typecheck-fail-examples/27-eq-no-instance.wok`:

```wok
module Fail.NoInstance
bad = "a" == "b"
```

  `test/typecheck-fail-examples/28-eq-ambiguous.wok`:

```wok
module Fail.Ambiguous
amb : (Eq a) => Bool
amb = True
```

  `test/typecheck-fail-examples/29-eq-bad-instance.wok`:

```wok
module Fail.BadInstance
class C a where
  f : a -> Bool
instance (C [a]) => C a where
  f x = True
```

- [ ] **Step 2: Generate + inspect fail goldens.**

```bash
cabal test --test-options="-p 'typecheck fail golden' --accept"
```

  Inspect each `.expected` — confirm the message names the right error (`NoInstance`/`AmbiguousConstraint`/`InstanceNotSmaller`). Re-run clean.

- [ ] **Step 3: Behavior-preservation check.** Confirm no pre-existing golden changed:

```bash
git status --porcelain test/anf-golden test/run-golden test/typed-anf-golden
# Expect ONLY new files (10-13 run goldens). If any 01..09 / 01..25 file is Modified, STOP and investigate.
```

- [ ] **Step 4: Full suite.**

```bash
cabal test
```

  Expect every group green, including `parse golden`, all four typecheck/anf/typed-anf/run golden groups, and the new `ClassParse`/`ConstraintTypes`/`ClassEnv`/`ConstraintAccum`/`TypedAst`/`ClassRegister`/`Solve`/`EqInfer`/`InterpCaf`/`ElaborateClass` units.

- [ ] **Step 5: Commit.**

```bash
git add test/typecheck-fail-examples/ test/typecheck-fail-golden/
git commit -m "test(types): Eq negative goldens; behavior-preservation regression sweep"
```

---

## RE-SCOPE: Tasks 9–12 (2026-06-04, the live plan for the remainder)

**Architecture decision.** Dictionaries are represented as a **data constructor**, and
instances are **desugared into synthetic typed top-level bindings** that flow through the
normal inference → elaboration pipeline. This reuses 100% of the existing data/constructor
machinery and avoids both problems that sank the original Task 9 (untyped instance bodies;
operator-named record fields).

Concretely, for `class Eq a where (==) : a -> a -> Bool ; (/=) : a -> a -> Bool ; (/=) x y = not (x == y)`:

- The class registers a **dict data type**: `data Eq a = Eq$Dict (a -> a -> Bool) (a -> a -> Bool)`
  — tycon `Eq` (kind from the class param), one constructor `Eq$Dict` whose positional fields
  are the method types (constraint stripped), in `ciMethodNames` order.
- `instance Eq U64 where (==) = eqU64` desugars to synthetic decls:
  - `dict$Eq$U64$eq = eqU64`  (method impl, as a named function)
  - `dict$Eq$U64$ne x y = not (dict$Eq$U64$eq x y)`  (default `/=`, with the class-method
    reference `==` rewritten to the SIBLING synthetic name to avoid dict self-reference)
  - `dict$Eq$U64 = Eq$Dict dict$Eq$U64$eq dict$Eq$U64$ne`  (the dict, a 0-arity CAF value —
    works thanks to Task 8's CAF fix)
- `instance (Eq a) => Eq (Option a) where (==) x y = case (x,y) of …a == b…` desugars to:
  - `dict$Eq$Option$eq x y = case (x,y) of …a == b…`  (here `a == b` is a genuine class-method
    use at the ELEMENT type → inferred `(Eq a) =>`, evidence param threaded automatically)
  - `dict$Eq$Option$ne x y = not (dict$Eq$Option$eq x y)`  (default, sibling-rewritten →
    also `(Eq a) =>`)
  - `dict$Eq$Option = Eq$Dict dict$Eq$Option$eq dict$Eq$Option$ne`  (uses the constrained
    method synths as values → inferred `(Eq a) => Eq (Option a)`; elaboration threads the
    element dict via the normal constrained-function path)
- A **class-method use** `x == y` is a `TQVar "==" [(Eq, argTy)]`. Elaboration resolves the
  evidence dict atom `d` (via `Solve`), then projects method index `k` (= position of `==` in
  `ciMethodNames`) by `case`-destructuring the dict con and applies: `case d of Eq$Dict f0 f1 -> f0 x y`.
- An **ordinary constrained-function use** (e.g. `isEq`, or a method synth used as a value)
  lowers by passing evidence dict atoms as **leading arguments**.

Synthetic names use `$` (e.g. `dict$Eq$U64$eq`) — illegal in surface identifiers, so they
cannot collide with user names; they are constructed directly in `Abs` (bypassing the lexer).
The dict con name `<Class>$Dict` (e.g. `Eq$Dict`) likewise uses `$` and is constructed directly.

**Key consequence:** elaboration needs NO instance-specific logic — instances are ordinary
`TypedDecl`s (constructor applications / functions) by the time elaboration runs. Elaboration
only learns to lower the `TQVar` node and to prepend `tdEvidence` binders.

`Abs` shapes confirmed: `ConDef ConId [Type]` (function-typed fields OK, no parens needed);
`DEqn FunLHS Exp MaybeWhere`; `FunLHS = LHSPre FunName [AtomPat]`; `EApp Exp Exp` (curried);
`ECon ConId`, `EVar VarId`, `EParenOp VarSym`. `inferProgramTC` (Infer.hs ~2460) runs
`processDataDecls` → `processEffectDecls` → class/instance registration → `localDecls = concatMap toLocalDecl decls` → `inferTopLetGroup`.

---

### Task 9 (RE-SCOPED): Dict data type + synthetic instance desugaring (typechecker)

**Goal:** Each class registers a dict data constructor; each instance is desugared into
synthetic typed top-level bindings (method impls/defaults + the dict assembly) that flow
through the existing inference pipeline and become `TypedDecl`s. After this task, `instance`
decls produce real typed dict bindings; nothing is lowered in elaboration yet.

**Files:**
- Modify: `src/Wok/TypeChecking/Env.hs` — `ClassInfo` gains `ciDictCon :: Text`.
- Modify: `src/Wok/TypeChecking/Class.hs` — generate the dict `Abs.DData` from a `DClass`;
  generate `[Abs.Decl]` instance bindings from a `DInstance` + `ClassInfo`; set `ciDictCon`.
- Modify: `src/Wok/TypeChecking/Infer.hs` — `inferProgramTC` weaves synthetic dict-data decls
  into the `processDataDecls` input and synthetic instance bindings into `localDecls`.
- Modify: `test/Spec.hs` — `EqDesugar` group (infer a module with a class + instances; assert
  the dict `TypedDecl`s exist with the expected schemes/evidence).

**Acceptance Criteria:**
- [ ] `processClassDecl` registers a dict data type `data <Class> <params> = <Class>$Dict <methodType…>`
  (via the existing data-registration path) and stores `ciDictCon = "<Class>$Dict"`.
- [ ] For each instance, synthetic bindings are generated and typechecked: one per method
  (impl verbatim, or default with class-method refs rewritten to sibling synth names), plus the
  dict-assembly binding `<dictName> = <Class>$Dict <methodSynth…>`.
- [ ] `inferProgramTC` produces `TypedDecl`s for all synthetic bindings; `dict$Eq$U64` has scheme
  `Eq U64` (0-arity), `dict$Eq$Option` has scheme `forall a.(Eq a)=> Eq (Option a)` with
  `tdEvidence=[("d$Eq$0", Eq (CTGen 0))]`.
- [ ] Non-class modules are unaffected; full suite green; existing goldens byte-identical
  (no class/instance in them → no synthetic decls generated).

**Verify:** `cabal test --test-options='-p EqDesugar' && cabal test`

**Steps:**

- [ ] **Step 1 — `ClassInfo.ciDictCon`.** Add `ciDictCon :: Text` to `ClassInfo` (Env.hs); update
  its one construction in `Class.processClassDecl` and the `ClassEnv`/`ClassRegister` tests that
  build a `ClassInfo` literal.

- [ ] **Step 2 — Dict data type generation** (`Class.hs`). Write `dictDataDecl :: Abs.Decl -> Abs.Decl`
  mapping a `DClass cid params entries` to
  `DData cid params [ConDef (mkConId (cidText <> "$Dict")) [ ty | CESig _ ty <- entries ]]`.
  The field types are the method `Abs.Type`s verbatim (they are `a -> a -> Bool`, already over the
  class param). Construct the `ConId`/`VarId` wrappers directly with a dummy position. `processClassDecl`
  sets `ciDictCon = cidText <> "$Dict"`.

- [ ] **Step 3 — Instance binding generation** (`Class.hs`). Write
  `instanceBindings :: Env -> Abs.Decl -> Either TypeError [Abs.Decl]` for a `DInstance`:
  look up the `ClassInfo`; compute the head key (reuse Task 5's `tyConKey . headCon` on the
  translated head, or re-derive from the instance head args) for naming; for each method `m` in
  `ciMethodNames` produce a `DEqn` named `dict$<Cls>$<HeadKey>$<mMangled>`:
  - if `m` is in the instance's `iiImpls`/`InstEntry`s: take that `FunLHS`+`Exp`, rebuild the LHS as
    `LHSPre (FNBare (mkVarId synthName)) <the impl's AtomPats>` (extract the pats from the original
    `FunLHS`, whether `LHSInfSym`/`LHSPre`/`LHSInfBT`), keep the body verbatim.
  - else use the class default (`ciDefaults`/`CEDefault`): rebuild LHS with the synth name and
    **rewrite class-method references in the body** to the SIBLING synth names (a pure `Abs.Exp`
    rewrite replacing `EVar`/`EParenOp`/operator-`EExpr` heads whose name is a class method of THIS
    class with an `EVar (mkVarId siblingSynthName)`). Leave non-method names untouched.
  Then the dict-assembly `DEqn`: `dict$<Cls>$<HeadKey> = <Cls>$Dict <each method synth as EVar>`
  built as a curried `EApp` spine over `ECon (<Cls>$Dict)`.
  Return all these decls. (Method-name mangling: map operator method names to identifier-safe
  suffixes, e.g. `==` → `eq`, `/=` → `ne`; a small fixed table is fine for the Eq slice, but prefer
  a general mangle like `opMangle :: Text -> Text` so future methods work.)

- [ ] **Step 4 — Weave into `inferProgramTC`** (`Infer.hs`). After computing the class/instance
  registration env (`env1i`), generate synthetic decls and run them through the EXISTING pipeline:
  - dict data decls: `let dictData = map Class.dictDataDecl [ d | d@Abs.DClass{} <- decls ]`; include
    them in the `processDataDecls` input — i.e. call `processDataDecls seedEnv (decls ++ dictData)`
    (move the dict-data generation BEFORE `processDataDecls`, since the cons must be registered before
    instance bindings infer). Note `dictDataDecl` only needs the `DClass` syntax, not the env.
  - instance bindings: `instB <- either throwError pure (concat <$> mapM (Class.instanceBindings env1i) [ d | d@Abs.DInstance{} <- decls ])`; then `let localDecls = concatMap toLocalDecl (decls ++ instB)`.
  Keep the class/instance registration (`processClassDecl`/`processInstanceDecl`) as-is — it still
  populates `envClasses`/`envInstances`/method schemes that `Solve` and method-use sites need.
  Ensure `ciDictCon` registration and the dict-data registration are consistent (same `<Cls>$Dict`).

- [ ] **Step 5 — `EqDesugar` tests.** Infer a module with `class Eq` + `instance Eq U64` +
  `instance (Eq a) => Eq (Option a)` (+ `eqU64`, `not`, `Bool`, `Option`, fixities) via
  `inferProgramWith`. Assert: a `TypedDecl` named `dict$Eq$U64` exists with scheme body `Eq U64`
  (i.e. `CTCon (TcUser "Eq") [CTCon TcU64 []]`); `dict$Eq$Option` exists with
  `schemeConstraints=[Eq (CTGen 0)]` and `tdEvidence` param `d$Eq$0`. (Reuse the parse+infer harness.)

- [ ] **Step 6 — Verify + commit.**
```bash
cabal test --test-options='-p EqDesugar' && cabal test
git commit -am "feat(types): dict data type + synthetic instance desugaring"
```

---

### Task 10 (RE-SCOPED): Elaboration — lower `TQVar` + evidence params

**Goal:** Elaboration lowers the `TQVar` node and prepends `tdEvidence` binders. Instances are
already ordinary `TypedDecl`s (from Task 9), so there is NO instance-specific elaboration.

**Files:**
- Modify: `src/Wok/IR/Elaborate.hs` — replace the Task-4 `TQVar` stub; add evidence handling.
- Modify: `test/Spec.hs` — `ElaborateClass` group.

**Acceptance Criteria:**
- [ ] `ElabCtx` carries `ecEvidence :: Map Int Name` (quantified-constraint index → dict binder).
- [ ] A binding with `tdEvidence` gets one leading `Binder` per evidence param (named
  `Solve.paramName cls i`, typed with the dict type), prepended before value params; `ecEvidence`
  maps each `CTGen i` to that binder.
- [ ] A `TQVar name cs` whose `name` is a class method (via `classOfMethod`): resolve the (single)
  evidence dict atom via `Solve.resolve env (Map.keysSet ecEvidence) cls argTy`, then
  `case dictAtom of <Cls>$Dict f0..fn -> f_k …` where `k` = method index in `ciMethodNames`,
  applying `f_k` to the call's args. (Handle both `TApp (TQVar …) args` and a bare `TQVar` value.)
- [ ] A `TQVar name cs` whose `name` is NOT a class method (ordinary constrained function): lower to
  `name` applied with the evidence atoms as LEADING args.
- [ ] Evidence atoms: `EvGlobal d` → the global dict `Name`; `EvParam p` → the in-scope evidence
  binder; `EvApp d evs` → `let t = d evs in t` (apply the builder to sub-evidence atoms).
- [ ] `ElaborateClass` tests pass; existing `Elaborate*` groups byte-identical; full suite green.

**Verify:** `cabal test --test-options='-p Elaborate' && cabal test`

**Steps:**

- [ ] **Step 1 — `ecEvidence` in `ElabCtx`.** Add the field; thread it (default `Map.empty`) through
  all `ElabCtx` constructions and the test seam.

- [ ] **Step 2 — Evidence-param binders in `elabTopBind`.** For each `(paramName, Constraint cls (CTGen i))`
  in `tdEvidence td`, mint a `Binder` named `paramName` (type = the dict type for `cls` at `CTGen i`,
  e.g. `CTCon (TcUser cls) [CTGen i]`; binder types are erased at runtime so a reasonable type suffices),
  prepend them before the value-param binders, and build `ecEvidence = Map.fromList [(i, binderName)]`.
  Elaborate the body under that `ecEvidence`.

- [ ] **Step 3 — Lower `TQVar`.** Replace the stub. Implement an evidence-atom builder
  `evidenceAtom :: (Text, CType) -> Elab Atom` that calls `Solve.resolve env (Map.keysSet ecEvidence) cls argTy`
  and lowers the `Evidence`: `EvGlobal d`→`resolveVar d`; `EvParam p`→ look up the binder in `ecEvidence`
  (by the index whose `paramName` equals `p`, or store `ecEvidence` keyed so this is direct);
  `EvApp d evs`→ recursively build atoms, `bindFresh`, emit `Let t (RApp dAtom evAtoms)`, return `AVar t`.
  Then for `TQVar name cs`:
  - class method (`classOfMethod name env = Just cls`): `[d] <- mapM evidenceAtom cs`; look up
    `ciDictCon` + method index `k`; produce the projection-and-apply. As an app head
    (`TApp (Texp _ (TQVar …)) args`): elaborate args to atoms, then
    `Case dAtom [AltCon dictCon fieldBinders (RApp (AVar (fieldBinders!!k)) argAtoms-as-tail)]`.
    As a bare value: `Case dAtom [AltCon dictCon fieldBinders (Ret (AVar (fieldBinders!!k)))]`.
  - ordinary (`classOfMethod = Nothing`): `evs <- mapM evidenceAtom cs`; as an app head →
    `RApp (resolved name) (evs ++ argAtoms)`; bare → `RApp (resolved name) evs` (partial application).
  Integrate with the existing app-spine normalization (mirror how `TApp`/`TProj` are handled): the
  cleanest is to special-case `TApp (Texp _ (TQVar n cs)) args` in the app path, and handle a bare
  `TQVar` in `elabRhsF`.

- [ ] **Step 4 — `ElaborateClass` tests.** Elaborate a small program (`main = 1 == 2` etc.) end to end
  and assert: a `dict$Eq$U64` `TopBind` exists (0-arity, body constructs `Eq$Dict`); `main`'s `==`
  lowers to a `Case` over the dict extracting field 0 and applying. Provide an `elaborateSrc` helper
  (load via the loader or assemble `LoadedModule`s; or reuse the run-pipeline harness).

- [ ] **Step 5 — Verify + commit.**
```bash
cabal test --test-options='-p Elaborate' && cabal test
git commit -am "feat(ir): lower TQVar (method case-project / constrained leading-args) + evidence params"
```

---

### Task 11 (RE-SCOPED): Prelude `Eq` + end-to-end run goldens

Same as the original Task 10 (now unblocked by Tasks 9–10). Add `class Eq`, `instance Eq U64`,
`instance (Eq a) => Eq (Option a)`, `not`, and the `eqU64` bodyless sig to `prelude/Std/Base.wok`
(remove the old monomorphic `(==)`/`(/=)` sigs); add the four run examples
(`10-eq-u64`, `11-eq-option`, `12-eq-poly`, `13-ne-default`), each evaluating to `1`; generate and
inspect their run goldens; confirm `01`–`09` run goldens unchanged. **Verify:**
`cabal test --test-options="-p 'run golden'" && cabal test`. Commit
`feat(prelude): Eq class + instances + not; end-to-end run goldens`.

(See the SUPERSEDED "Task 10" section above for the exact prelude text and example files — that
content is still correct; only its task number changed.)

---

### Task 12 (RE-SCOPED): Negative goldens + regression sweep

Same as the original Task 11. Add the three failing fixtures
(`27-eq-no-instance`, `28-eq-ambiguous`, `29-eq-bad-instance`) under
`test/typecheck-fail-examples/`; generate+inspect their fail goldens; confirm all pre-existing
`anf`/`run`/`typed-anf` goldens are byte-identical (only ADDED files); full suite green. **Verify:**
`cabal test`. Commit `test(types): Eq negative goldens; behavior-preservation regression sweep`.

(See the SUPERSEDED "Task 11" section above for the exact fixture contents.)

---

## Known limitations (future scope, recorded during Task 9)

Sound for the single-parameter, operator-method `Eq` slice; must be revisited before
multi-method / multi-parameter / named-method classes:

- **`substTyVar` (Class.hs) is capture-unaware.** A method whose type has a free variable
  beyond the class parameter (e.g. `foo : a -> b -> a`), instantiated by an instance head that
  reuses that name, would name-capture. Verified NOT unsound today (it surfaces as an
  `UnknownTyCon`/rejection, not a mis-typecheck), but the error is opaque. Fix with proper
  capture-avoiding substitution when methods gain extra type variables.
- **`rewriteMethodRefs` (Class.hs) is scope-unaware.** It rewrites any default-body reference
  whose name is a class method to the sibling synth. A *non-operator* method name shadowed by a
  local binder inside a default body would be wrongly rewritten. Harmless for operator-only `Eq`;
  add scope tracking before named methods.
- **No top-level SCC staging.** All top-level binds infer as one mutually-monomorphic group;
  the synthetic method-synth signatures (Task 9) are what make constrained instances propagate
  evidence. If SCC staging is added later, those synthetic sigs become optional (but stay
  harmless).
- **Minor hlint:** `Infer.hs` ~2487 has a `Redundant <$>` hint introduced by Task 9
  (`either throwError pure (concat <$> mapM …)` → `either throwError (pure . concat) (mapM …)`).
  Fold into the Task 12 cleanup.

## Self-review checklist (run after implementation)

1. **Decidability:** termination check rejects non-smaller instance contexts (Task 5/11); coherence rejects overlap (Task 5); ambiguity rejected at discharge (Task 7) and surfaced as a golden (Task 11).
2. **Behavior preservation:** non-constrained schemes emit no constraints and build `TVar`/`TParenOp` (Task 7), so erased `anf golden` + `run golden` for `01`..existing are byte-identical (Task 11 guard).
3. **Evidence consistency:** the single `Solve.resolve` engine is used by both the typechecker (validate, Task 7) and elaboration (build, Task 9); `paramName` is the one source of evidence-param names (Task 6) used by both `tdEvidence` minting (Task 7) and elaboration binder lookup (Task 9).
4. **CAF fix:** ground dicts (0-arity) force to `VRecord` once via a knot-tied lazy `gEnv` (Task 8); constrained dicts are builder lambdas (Task 9) needing no force fix.
5. **Default methods:** specialized per instance by impl substitution (Task 9) — no recursive dict value.
6. **Name consistency across tasks:** `Constraint`/`Evidence`/`schemeConstraints` (Task 1), `ClassInfo`/`InstanceInfo`/`envClasses`/`envInstances`/`classOfMethod` (Task 2), `ConstraintS`/`addConstraint`/`takeConstraints` (Task 3), `TQVar`/`tdEvidence` (Task 4), `processClassDecl`/`processInstanceDecl`/`dictName` (Task 5), `Solve.resolve`/`paramName`/`EvGlobal`/`EvParam`/`EvApp` (Task 6), `eqU64` (Task 8/10) are spelled identically everywhere.
7. **Grammar regen discipline:** both manual patches re-applied after `bnfc` (Task 0); `DClass`/`DInstance`/`TQual` constructor names confirmed against the regenerated `Abs.hs`.
