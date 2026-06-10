# Kinded `Ty` Representation — Slice A (the merge) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the two parallel type sorts — `CType`/`CRow` (closed) and `Type`/`Row` with `TVar`/`RVar` (inference-time) — into ONE kinded type-expression datatype, as a strictly behaviour-preserving refactor (all ~695 goldens byte-identical), so that a later slice can place an effect row in a type-constructor argument.

**Architecture:** Keep the existing names `CType`/`Type`/`TVar`/`CTGen` and FOLD rows into them as new constructors (rows become ordinary type nodes of kind `KEffect`); delete `CRow`/`Row`/`RVar`. Unification gains a kind check in `unifyVar` and the Leijen row algorithm moves inline into `unify`. Every conversion/traversal that today has a Type-half and a Row-half (`force`/`forceRow`, `freeze`/`freezeRow`, `occursAdjust*`, `instantiate`, `freezeSig`, the pretty-printers) collapses to one. The spec's "decidability contract" is held: variable kinds stay `{KStar, KEffect}` only; no behaviour changes, so `KindMismatch` cannot fire on existing programs.

**Tech Stack:** Haskell, GHC 9.10, `-Wall -Werror` with exhaustiveness checks, `tasty-golden`.

---

## Background the engineer needs

This is Slice A of the design `docs/superpowers/specs/2026-06-10-kinded-type-representation-design.md` (read §6 staging and §7 decidability contract). Slice A is the merge ONLY — no new surface syntax, no row-kinded tycon parameters, no new feature. Its entire correctness argument is **"every existing test stays byte-identical."**

### Naming decision (refines the spec's `Ty`/`CTy`)

Two independent axes; both chosen to minimise diff AND keep clarity:

**Type name — keep `CType`/`Type`/`TVar`/`CTGen`** (don't rename to `CTy`/`Ty`). Most consumers already match `CTCon`/`CTArr`/`CTGen`/`TCon`/`TArr`/`TVar`, so keeping the names confines the diff to genuinely row-specific code. The mild misnomer (a `Type s` can now be kind-`KEffect`, i.e. a row) is mitigated by: (a) the `Row`/`CRow` aliases below used in row positions; (b) the `Row`/`CR` constructor prefixes that mark row nodes; (c) a datatype doc-comment stating the kinded nature. (GHC precedent: its `Type` spans kinds.)

**Constructor names — KEEP `CREmpty`/`CRExtend` (closed) and `RowEmpty`/`RowExtend` (inference).** This is the load-bearing choice for the zero-churn guarantee: the typecheck-fail goldens render types via **derived `Show`** (e.g. `future-reperform-unhandled.expected` = `RowMismatch Nothing CREmpty (CRExtend "Log" (CTCon TcUnit []) CREmpty)`; `13-polymorphic-records.expected` embeds `CRExtend`/`CREmpty`). Renaming these constructors would churn those goldens. Keeping the exact names → byte-identical `Show` → **true** zero golden churn. The `CR`/`Row` prefix doubly serves as row-ness documentation inside the unified type. (`CRGen` is the exception — it merges into `CTGen`; verified it appears in NO golden, only in `test/Spec.hs`, so its merge is golden-safe but requires porting `Spec.hs`.)

**Aliases (clarity + smaller diff):** add `type CRow = CType` and `type Row s = Type s`, used wherever a value is a row (arrow middle slot, record child, `CTArr`/`CTRecord` field types, row-walking signatures). Type signatures like `CTArr CType CRow CType` then still read with the row documented, and type-level references to `CRow`/`Row` keep compiling. (Aliases are non-enforcing — a `CRow` could syntactically hold a non-row — but that is inherent to the fold and the prefix/comment make intent clear. Pattern matches over a `CRow` value now see all `CType` constructors, so exhaustive row-matches gain the structural arms; those functions are being merged anyway.)

The kind `KEffect` is kept as the row-kind name (the rename to `KRow` is cosmetic churn — skip it).

### The current two-sort representation (grounded, `src/Wok/TypeChecking/Types.hs`)

```haskell
data Kind = KStar | KEffect | KArrow Kind Kind          -- KEffect IS the row kind

data Type s = TCon TyCon [Type s] | TArr (Type s) (Row s) (Type s)
            | TRecord Text (Row s) | TVar (STRef s (TVar s))
data TVar s = Unbound { uniq, level, kind :: Kind } | Rigid { uniq, kind :: Kind } | Link (Type s)
data Row s  = RowEmpty | RowExtend Text (Type s) (Row s) | RowVar (STRef s (RVar s))
data RVar s = RUnbound { rUniq, rLevel } | RLink (Row s)     -- NB: NO kind field

data CType = CTCon TyCon [CType] | CTArr CType CRow CType | CTRecord Text CRow | CTGen Int
data CRow  = CREmpty | CRExtend Text CType CRow | CRGen Int
```

### Two facts already verified (the load-bearing correctness guards)

1. **Gen indices never collide.** `freshTVar` and `freshRVar` both draw from ONE shared `freshUniq` counter (`src/Wok/TypeChecking/Monad.hs:110-129`), so every type-var and row-var `uniq` is globally unique. `freeze` maps `Unbound u → CTGen u` and `freezeRow` maps `RUnbound u → CRGen u` by that `uniq`; `instantiate`/`freezeSig` filter ONE `schemeVars :: [(Int,Kind)]` list by `k == KEffect`. So merging `CTGen`/`CRGen` into one `CTGen Int` is faithful — no two distinct vars share an index.
2. **Rows are never skolemized.** `freezeSigSkolems` (`Infer.hs:339-353`) makes kind-`KStar` signature vars `Rigid` (skolems) but kind-`KEffect` (row) vars **fresh `Unbound` RowVars** — never rigid. The merged code MUST keep this: a row variable in a signature becomes a fresh unbound meta var of kind `KEffect`, NOT a `Rigid`. Getting this wrong silently changes inference and breaks the no-op.

### The full unifier today (`src/Wok/TypeChecking/Unify.hs`)

`unify`/`unifyVar`/`rigidUnify` handle types; `unifyRow`/`bindRowVar`/`rewriteRow`/`rewriteRowStrict` handle rows (Leijen 2005 scoped-label). `force`/`forceRow` chase `Link`/`RLink`. `freeze`/`freezeRow`/`freezeTolerant` convert to closed form. `occursAdjust`/`occursAdjustRow`/`occursAdjustRowVar`/`adjustLevels`/`adjustLevelsRow` do occurs-check + level adjustment. The `unifyVar` body carries the `TODO(v2-rows)` that this slice closes.

### Files this slice touches

- `src/Wok/TypeChecking/Types.hs` — the datatype merge (the source of all downstream churn).
- `src/Wok/TypeChecking/Unify.hs` — collapse force/freeze/occurs/unify halves; add the `unifyVar` kind check.
- `src/Wok/TypeChecking/Monad.hs` — `freshRVar` now mints a `TVar` cell of kind `KEffect`.
- `src/Wok/TypeChecking/Infer.hs` — collapse `instantiate`/`freezeSig`/`substCTypeWith`/generalisation halves; merge `prettyCType`/`prettyCRow`; translation of parsed types builds the new constructors.
- `src/Wok/TypeChecking/Error.hs` — add `KindMismatch`.
- `src/Wok/TypeChecking/Carrier.hs`, `src/Wok/IR/Anf.hs`, `src/Wok/IR/Elaborate.hs`, `src/Wok/TypeChecking/Typed.hs`, `src/Wok/TypeChecking/Class.hs`, `src/Wok/TypeChecking/Builtins.hs`, `src/Wok/TypeChecking/Env.hs` — port `CRow`/`Row` matches and the arrow middle-slot; one printer in `Anf.hs`.
- `test/Spec.hs` — prep guard test (Task 1) + post-merge unit tests (Task 3).

### Method for a whole-subsystem refactor

The exact per-line edits across ~10 files cannot all be pre-written; instead this plan gives **complete code for the datatypes, the unifier core, `freeze`, and the row-skolemization guard**, plus a **precise transformation rule-table** and the **`-Werror` worklist procedure** for the mechanical remainder, with the **unchanged golden suite as the equivalence oracle**. That is the correct artifact for a refactor of this size — the compiler enumerates every site, and the goldens prove behaviour is identical.

---

## Task 0: Branch and capture the preservation baseline

**Goal:** Branch from `main`; record the green baseline and the exact behaviours the merge must preserve.

**Files:** none (git + measurement).

**Acceptance Criteria:**
- [ ] On branch `feat/kinded-ty-representation` forked from `main`.
- [ ] `cabal build` clean; test count recorded (expect 695).
- [ ] Coroutine run-example values recorded (regression anchors).

**Verify:** `git branch --show-current` → `feat/kinded-ty-representation`

**Steps:**

- [ ] **Step 1: Branch**
```bash
cd /Users/zy/wokml
git checkout main
git checkout -b feat/kinded-ty-representation
```

- [ ] **Step 2: Baseline suite**
```bash
cabal build 2>&1 | tail -3
cabal test 2>&1 | grep -iE "All [0-9]+ tests"
```
Record the count (expect `All 695 tests passed`). Every later task must keep this number AND keep every golden byte-identical (Slice A adds only non-golden unit tests).

- [ ] **Step 3: Record regression anchors**
```bash
for f in coro-escape coro-step-range coro-step-zip coro-multi-driver; do
  printf "%s=" "$f"; cabal run -v0 wok -- test/run-examples/$f.wok --run
done
```
Expected `421 / 10 / 52 / 64`. These must be identical after the merge.

---

## Task 1: Prep — `KindMismatch` error + the row-skolemization guard test

**Goal:** Add the `KindMismatch` error constructor (used by Task 2's `unifyVar` kind check) and a regression test pinning the "rows are not skolemized" behaviour, both green now and unchanged by the merge.

**Files:**
- Modify: `src/Wok/TypeChecking/Error.hs` (add `KindMismatch`)
- Create: `test/typecheck-examples/effect-poly-roundtrip.wok`
- Create (via `--accept`): the three goldens for it
- Modify: `test/Spec.hs` (no new code needed if the corpus file covers it; see Step 3)

**Acceptance Criteria:**
- [ ] `KindMismatch` exists in `TypeError` and renders via the existing `Show`/error pipeline.
- [ ] An effect-polymorphic round-trip program (row var used in two positions of a signature) type-checks and is golden-pinned.
- [ ] Full suite green; build clean.

**Verify:** `cabal test 2>&1 | grep -iE "effect-poly-roundtrip|All [0-9]+ tests"`

**Steps:**

- [ ] **Step 1: Add the `KindMismatch` constructor**

In `src/Wok/TypeChecking/Error.hs`, find the `TypeError` data type and add a constructor mirroring the shape of the existing `Mismatch`/`RowMismatch` (they carry a `SourceSpan` and the offending closed types). Add:
```haskell
  | KindMismatch SourceSpan CType CType
    -- ^ Two types of different KINDS were unified (e.g. a row where a `*`-kinded
    -- type was expected). Cannot arise from surface programs in Slice A (every
    -- type is well-kinded); guards the kinded representation for later slices.
```
Match whatever `import`/derivation `Mismatch` uses (it already references `CType`). Build:
```bash
cabal build 2>&1 | tail -3
```
Expected: clean (the constructor is unused for now; if `-Wall` flags an incomplete `case` over `TypeError` anywhere, add the new arm there following the neighbouring `Mismatch`/`RowMismatch` arm's rendering).

- [ ] **Step 2: Write the row-skolemization regression program**

This pins that an effect-polymorphic signature (a row variable threaded through two positions) type-checks — the behaviour `freezeSigSkolems` provides by making row vars fresh-unbound, NOT rigid. Create `test/typecheck-examples/effect-poly-roundtrip.wok`:
```wok
module Main
import Std.Base

-- `id`-like, but effect-polymorphic: the same row variable `e` appears on the
-- argument's arrow and the result's arrow. This only type-checks if the signature
-- row var is a shared, non-skolemized variable (freezeSigSkolems behaviour).
applyThunk : (() -> a with eff e) -> a with eff e
applyThunk f = f ()

main : U64
main = applyThunk (\_ -> 7)
```

- [ ] **Step 3: Generate goldens and confirm it type-checks + runs**
```bash
cabal run -v0 wok -- test/typecheck-examples/effect-poly-roundtrip.wok --run
cabal test --test-options=--accept 2>&1 | grep -i "effect-poly-roundtrip"
git status --short test/ | grep -v effect-poly-roundtrip || echo "(only the new fixture's goldens added)"
```
Expected: `--run` prints `7`; three new goldens (`typecheck-golden`, `anf-golden`, `typed-anf-golden`) added; no pre-existing golden changed. (If `applyThunk` does not type-check on current `main`, the row-poly signature form differs — inspect an existing effect-poly prelude runner like `reader`/`state` in `prelude/Std/Control.wok` and mirror its exact signature syntax instead. The point is a row var in two signature positions.)

- [ ] **Step 4: Full suite**
```bash
cabal test 2>&1 | grep -iE "All [0-9]+ tests"
```
Expected: baseline + 3 (the new fixture across three golden groups), all green.

- [ ] **Step 5: Commit**
```bash
git add src/Wok/TypeChecking/Error.hs test/typecheck-examples/effect-poly-roundtrip.wok test/typecheck-golden/effect-poly-roundtrip.expected test/anf-golden/effect-poly-roundtrip.expected test/typed-anf-golden/effect-poly-roundtrip.expected
git commit -m "prep(tc): add KindMismatch error + effect-poly row-var regression (slice A)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: The atomic merge (one large task; ends green; zero golden churn)

**Goal:** Fold `CRow`/`Row`/`RVar` into `CType`/`Type`/`TVar`; collapse every two-half traversal into one; add the `unifyVar` kind check. End state: builds clean and **every one of the ~698 goldens is byte-identical**.

**Files:** `src/Wok/TypeChecking/{Types,Unify,Monad,Infer,Carrier,Class,Builtins,Env}.hs`, `src/Wok/IR/{Anf,Elaborate}.hs`, `src/Wok/TypeChecking/Typed.hs`, `test/Spec.hs` (port `CRGen` in existing unit tests).

**Acceptance Criteria:**
- [ ] The DELETED names are gone from `src/`: the `data RVar`, `data CRow`, `data Row` declarations and the constructors/functions `CRGen`, `RowVar`, `RUnbound`, `RLink`, `forceRow`, `freezeRow`. (`CRow`/`Row` survive as `type` aliases; `CREmpty`/`CRExtend`/`RowEmpty`/`RowExtend` survive as constructors — these are KEPT by design.)
- [ ] `unifyVar` rejects a kind-mismatched link with `KindMismatch`.
- [ ] `freezeSig` still makes kind-`KStar` sig vars `Rigid` and kind-`KEffect` sig vars fresh-`Unbound`.
- [ ] `cabal build` clean under `-Wall -Werror`.
- [ ] `cabal test` green AND **zero golden churn** (`git diff` over `test/*-golden/` is empty — including the two row-rendering goldens `future-reperform-unhandled` and `13-polymorphic-records`); coro values `421/10/52/64`.

**Verify:** `grep -rnE 'CRGen|RowVar|RUnbound|RLink|forceRow|freezeRow|data CRow|data Row |data RVar' src/` → nothing; `cabal test 2>&1 | grep -iE "All [0-9]+ tests"`; `git diff --stat -- test/ | grep golden` → empty.

**Steps:**

- [ ] **Step 1: Merge the datatypes in `Types.hs`**

Replace the `Type`/`TVar`/`Row`/`RVar`/`CType`/`CRow` declarations with the folded versions. `Kind` is unchanged (`KEffect` stays the row kind). **Keep the row constructor names** (`RowEmpty`/`RowExtend`, `CREmpty`/`CRExtend`) — that is what preserves derived-`Show` output (zero golden churn) and marks row-ness. Add the `Row`/`CRow` aliases:

```haskell
-- | A type EXPRESSION. After the slice-A merge this spans kinds: a node of kind
-- KStar is an ordinary type; a node of kind KEffect is an effect/record ROW
-- (built with RowEmpty/RowExtend). The `Row s` alias marks row positions.
data Type s
  = TCon TyCon [Type s]
  | TArr (Type s) (Row s) (Type s)    -- domain -[row]-> codomain ; MIDDLE is a row (kind KEffect)
  | TRecord Text (Row s)              -- nominal record ; child is a row (kind KEffect)
  | RowEmpty                          -- {} : KEffect
  | RowExtend Text (Type s) (Row s)   -- label, payload (KStar), rest (a row)
  | TVar (STRef s (TVar s))

-- | A row is just a Type of kind KEffect. Alias used to document row positions.
type Row s = Type s

data TVar s
  = Unbound { uniq :: Int, level :: Level, kind :: Kind }
  | Rigid   { uniq :: Int, kind :: Kind }
  | Link (Type s)
-- RVar is DELETED. A row variable is a TVar whose cell has kind = KEffect.

-- closed (post-freeze): same kinded-expression story, closed form.
data CType
  = CTCon TyCon [CType]
  | CTArr CType CRow CType             -- MIDDLE is a row (kind KEffect)
  | CTRecord Text CRow
  | CREmpty                           -- {} : KEffect (closed)
  | CRExtend Text CType CRow          -- label, payload, rest (a row)
  | CTGen Int                         -- quantified var; kind from the Scheme quantifier list
  deriving (Eq, Show)

-- | Closed row = closed Type of kind KEffect. Alias documents row positions.
type CRow = CType
-- CRGen is DELETED (subsumed by CTGen — same shared uniq index space).
```
Note `TArr`/`CTArr`/`TRecord`/`CTRecord` field types use the `Row s`/`CRow` aliases, so their signatures read exactly as before (the alias = `Type s`/`CType`). Update the module export list: drop `RVar (..)`; keep `CType (..)`, `Type (..)`, `TVar (..)`; **export the aliases** `Row`, `CRow` (as `type` synonyms, not `(..)`). From here the build is RED — use `-Werror` as the worklist for the remaining steps.

- [ ] **Step 2: `Monad.hs` — `freshRVar` mints a kind-`KEffect` TVar**

`freshRVar` currently builds an `RUnbound`. It now builds a `TVar` cell of kind `KEffect` (so row vars are ordinary meta vars):
```haskell
freshRVar :: TC s (Type s)
freshRVar = do
  lvl <- currentLevel        -- (use whatever the surrounding code uses for the level)
  u   <- freshUniq
  ref <- liftST $ newSTRef (Unbound u lvl KEffect)
  pure (TVar ref)
```
Keep the name `freshRVar` (callers are unchanged) — it now returns a `Type s` of kind `KEffect`. `freshTVar k` is unchanged.

- [ ] **Step 3: `Unify.hs` — collapse `force`/`freeze`/`occurs`/`unify` halves**

`force` already chases `TVar` links; it now also covers row nodes (they are `Type`s). **Delete `forceRow`** (callers use `force`). `RowEmpty`/`RowExtend` are non-`TVar`, so `force` returns them as-is — covered by `force`'s catch-all (already `force t = pure t`).

Merge `freeze`/`freezeRow`/`freezeTolerant` into single functions over `Type → CType` (row arms included). `freeze`:
```haskell
freeze :: Type s -> TC s CType
freeze t = do
  t' <- force t
  case t' of
    TCon c ts        -> CTCon c <$> mapM freeze ts
    TArr a r b       -> CTArr <$> freeze a <*> freeze r <*> freeze b
    TRecord tag row  -> CTRecord tag <$> freeze row
    RowEmpty         -> pure CREmpty
    RowExtend l p r  -> CRExtend l <$> freeze p <*> freeze r
    TVar ref -> do
      tv <- liftST $ readSTRef ref
      case tv of
        Unbound u _ _ -> pure (CTGen u)
        Link _        -> error "freeze: TVar was Link after force"
        Rigid u _     -> error ("freeze: unexpected Rigid (uniq " ++ show u ++ ")")
```
`freezeTolerant` is identical except `Rigid u _ -> pure (CTGen u)` (as today). **Delete `freezeRow`** (its `RUnbound u → CRGen u` becomes the `TVar`/`Unbound u → CTGen u` arm above — same `uniq`, faithful per the Task 0 guard #1).

Collapse `occursAdjust`/`occursAdjustRow`/`occursAdjustRowVar`/`adjustLevels`/`adjustLevelsRow` into `occursAdjust` (occurs-check + level-lower, with target ref) and `adjustLevels` (level-lower, no target) over the unified `Type` — add `RowEmpty`/`RowExtend` arms (recurse into payload + rest) to each, exactly mirroring the old Row arms. The old `occursAdjustRowVar`'s `RowOccursCheck` path merges into `occursAdjust`'s existing same-ref check.

`unify` absorbs the Leijen row algorithm (the row formers become cases in `unify`; **delete `unifyRow`** or keep it as a thin alias `unifyRow = unify`):
```haskell
unify :: SourceSpan -> Type s -> Type s -> TC s ()
unify sp a b = do
  a' <- force a
  b' <- force b
  case (a', b') of
    (TVar r1, TVar r2) | r1 == r2 -> pure ()
    (TVar r, t) -> unifyVar sp r t >> warnIfRecordShadow sp t
    (t, TVar r) -> unifyVar sp r t >> warnIfRecordShadow sp t
    (TCon c1 ts1, TCon c2 ts2)
      | c1 == c2, length ts1 == length ts2 -> zipWithM_ (unify sp) ts1 ts2
    (TArr a1 e1 b1, TArr a2 e2 b2) -> unify sp a1 a2 >> unify sp e1 e2 >> unify sp b1 b2
    (TRecord t1 r1, TRecord t2 r2) -> do
      when (t1 /= t2) $ throwError (NominalMismatch sp t1 t2)
      unify sp r1 r2
      warnOnShadow sp r1
    -- ROW formers (Leijen 2005 scoped-label), now inline:
    (RowEmpty, RowEmpty) -> pure ()
    (RowExtend l1 p1 rest1, row2) -> do
      (p2, rest2') <- rewriteRow sp l1 row2
      unify sp p1 p2
      unify sp rest1 rest2'
    (RowEmpty, RowExtend{}) -> do
      ca <- freeze a'; cb <- freeze b'; throwError (RowMismatch sp ca cb)
    _ -> do
      ca <- freeze a'; cb <- freeze b'; throwError (Mismatch sp ca cb)
```
Note `(TArr .. e1 ..) ~ (TArr .. e2 ..)` now calls `unify sp e1 e2` on the row operands — which routes to the row-former cases above. `rewriteRow`/`rewriteRowStrict` keep their logic but over `Type` (return `(Type s, Row s)`); their `RowVar` case becomes a `TVar` case (a kind-`KEffect` var) that binds the var to `RowExtend l tFresh restFresh` where `tFresh <- freshTVar KStar` and `restFresh <- freshRVar`. **Fold `bindRowVar` into `unifyVar`** (binding a kind-`KEffect` var is the same code path as binding any var — occurs-adjust then `Link`).

- [ ] **Step 4: `Unify.hs` — the kind check in `unifyVar` (closes the TODO)**

```haskell
unifyVar :: SourceSpan -> STRef s (TVar s) -> Type s -> TC s ()
unifyVar sp ref t = do
  tv <- liftST $ readSTRef ref
  case tv of
    Link _ -> error "unifyVar: caller must have forced first"
    Rigid u _ -> rigidUnify sp ref u t
    Unbound _ lvl k -> do
      tk <- kindOf t
      when (k /= tk) $ do
        ca <- freeze (TVar ref); cb <- freeze t
        throwError (KindMismatch sp ca cb)
      occursAdjust sp ref lvl t
      liftST $ writeSTRef ref (Link t)
```
Add a small `kindOf :: Type s -> TC s Kind` that forces and reads the kind: `RowEmpty`/`RowExtend` → `KEffect`; `TCon`/`TArr`/`TRecord` → `KStar`; `TVar` → the cell's `kind` (Unbound/Rigid) or recurse through `Link`. (In Slice A every unify is well-kinded, so the `when` never fires on existing programs — Task 3 unit-tests that it CAN fire when constructed directly.)

- [ ] **Step 5: `Infer.hs` — collapse `instantiate`/`freezeSig`/`substCTypeWith`/generalisation**

In `instantiateQ`, `freezeSigSkolems`, `substCTypeWith`: the `substInCType` helpers split a CType walk (`goT`) and a CRow walk (`goR`). Merge into ONE walk over the folded `CType` — fold `goR`'s arms into `goT` (`CREmpty`/`CRExtend` join the cases; `CTGen i` looks up the single substitution map). Keep the kind-aware split when BUILDING the fresh substitution:
- `instantiateQ`: still partition `vars` by `k == KEffect` to choose `freshRVar` vs `freshTVar k`; but the body substitution is one map `Int → Type s` covering both (a row gen maps to a `freshRVar` result, a type gen to a `freshTVar` result). One `goT` walk; the old `goR`'s arms fold in: `CREmpty → RowEmpty`, `CRExtend l p r → RowExtend l (goT p) (goT r)`, `CRGen i → subst!i` becomes `CTGen i → subst!i` (CRGen is gone).
- `freezeSigSkolems`: **preserve the guard** — kind-`KStar` vars → `Rigid` skolem; kind-`KEffect` vars → `freshRVar` (fresh `Unbound`, NOT rigid). One body walk afterward.
- `substCTypeWith`: the existing `goR (CRGen _) = RowEmpty -- row params not supported in v1` line — a row-kinded gen in this record-field context dropped to `RowEmpty`. After the merge that case is `CTGen i` where the param's kind is `KEffect`; **keep the exact behaviour** (map it to `RowEmpty`) so record-constructor instantiation is byte-identical. Distinguish it from a normal type-gen by the param kind. (Slice-A no-op; a later slice revisits it.)

For generalisation (`freezeQuantifyG`, ~`Infer.hs:241` and its helpers): it freezes unbound vars to `CTGen` and records `(Int, Kind)` in the quantifier list. Merge its type-half and row-half into one walk over `Type` producing the folded `CType`, recording `(uniq, KStar)` for kind-`*` unbound vars and `(uniq, KEffect)` for kind-`KEffect` unbound vars — exactly as today, just one traversal. The renumbering/seen-set logic is unchanged (it already keys on `uniq`, which is shared).

- [ ] **Step 6: `Infer.hs` — translation of parsed types + one pretty-printer**

The parsed-type translator (`translateConArg`, `freezeSig`'s source, the `Abs.Type → Scheme` builder ~`Infer.hs:370+`) builds `CTArr`/`CTRecord` with a `CRow` middle and `CREmpty`/`CRExtend`/`CRGen` for rows. With the constructor names AND the `CRow` alias kept, these builders are **unchanged** except `CRGen i → CTGen i` (CRGen is gone). Builders like `foldr (\(l,t) acc -> CRExtend l t acc) CREmpty …` stay verbatim.

Merge `prettyCType`/`prettyCRow` into ONE `prettyCType` that handles row nodes too. **The output bytes MUST be identical** — a row in arrow position must render exactly as `prettyCRow` did (e.g. the `with l1,l2` formatting), a `CTGen` for a row var must render with the same variable-naming as before. Cross-check against `prettyCRow` (`Infer.hs:3547+`) and the arrow case of `prettyCType` (`Infer.hs:3520+`). Do the same for `Anf.hs:prettyCTypeLocal` (merge its `prettyCRow`-equivalent in; preserve `[]`, tuple, `TcUser` rendering exactly).

- [ ] **Step 7: Port the remaining consumers via the `-Werror` worklist**

Run `cabal build 2>&1 | grep -iE "error:|not in scope|incomplete|constructor"` repeatedly; each error names a file/line. Because the constructor names and the `CRow`/`Row` aliases are KEPT, most references compile unchanged — the churn is narrow. Apply the **transformation rule-table**:

| Old | New | Why |
|---|---|---|
| `CRGen i` | `CTGen i` | CRGen deleted (merged into CTGen) |
| `RowVar ref` | `TVar ref` (cell kind `KEffect`) | RVar deleted; row var is a TVar |
| `RUnbound u l` | `Unbound u l KEffect` | merged var cell |
| `RLink r` | `Link r` | merged var cell |
| `forceRow` | `force` | merged |
| `freezeRow` | `freeze` | merged |
| `freezeRowTolerant`/`freezeRow`-variants | the merged `freeze`/`freezeTolerant` | merged |
| `CREmpty` / `CRExtend` / `RowEmpty` / `RowExtend` | **unchanged** (kept) | zero-churn + row-ness marker |
| `CRow` / `Row s` (as a type) | **unchanged** (alias) | documents row positions |
| an exhaustive `case` over a `CRow`/`Row` value | now sees ALL `CType`/`Type` ctors — add the structural arms (usually an `error "expected a row"` for the impossible non-row ctors, OR fold into the merged walk) | exhaustiveness under `-Werror` |

Specific consumers:
- `Carrier.hs` — `isHandleType`/`isAffineCarrierType` match `CTCon …` (unchanged); they never inspect rows. Only compile-fixes if a `case` over `CType` became non-exhaustive (add `CREmpty`/`CRExtend` arms returning `False`).
- `Anf.hs` / `Elaborate.hs` / `Typed.hs` — type annotations re-thread; `prettyCTypeLocal` merges its row half (per Step 6, byte-identical). Add `CREmpty`/`CRExtend` arms to any exhaustive `CType` `case`.
- `Class.hs` — `tyConKey`/dict logic over `CType` heads (kind-`*`); add row arms where a `case` over `CType` is exhaustive (a row can't be a class head → `error`/unreachable). Class/instance heads stay kind-`*`.
- `Builtins.hs` — `initialEnv`; compile-fixes only.
- `Env.hs` — `Constraint`/`InstanceInfo` carry `CType`; no logic change.
- `test/Spec.hs` — existing unit tests construct/match `CRGen` (and possibly `CREmpty`/`CRExtend`); port `CRGen → CTGen`. (`CREmpty`/`CRExtend` references stay.)

Keep applying until `cabal build` is clean.

- [ ] **Step 8: Build clean + prove zero golden churn**
```bash
cabal build 2>&1 | tail -5
grep -rnE 'CRGen|RowVar|RUnbound|RLink|forceRow|freezeRow|data CRow|data Row |data RVar' src/ || echo "clean: deleted row-sort names gone"
cabal test 2>&1 | grep -iE "All [0-9]+ tests"
git diff --stat -- test/ | grep -i golden && echo "!!! GOLDEN CHURN — investigate" || echo "ZERO golden churn"
git diff -- test/typecheck-fail-golden/future-reperform-unhandled.expected test/typecheck-fail-golden/13-polymorphic-records.expected   # must be empty
for f in coro-escape coro-step-range coro-step-zip coro-multi-driver; do
  printf "%s=" "$f"; cabal run -v0 wok -- test/run-examples/$f.wok --run
done
```
Expected: build clean; grep clean; `All 698 tests passed`; **no golden under `test/*-golden/` changed** (especially the two row-rendering goldens — kept constructor names make their derived-`Show` byte-identical); coro values `421/10/52/64`. If ANY golden changed, the merge altered behaviour — diff it, find the divergence (a renamed constructor leaking into `Show`, a pretty-printer byte difference in Step 6, or a dropped row in Step 5), fix, re-run. Do NOT `--accept`.

- [ ] **Step 9: Commit**
```bash
git add src/
git commit -m "refactor(tc): merge CType/CRow (Type/Row, TVar/RVar) into one kinded representation (slice A)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Post-merge unit tests for the kinded representation

**Goal:** Lock the new invariants with direct unit tests (the surface can't exercise them yet): kind-dispatched unify, `KindMismatch` firing, the row-skolemization guard still holds.

**Files:** Modify `test/Spec.hs`.

**Acceptance Criteria:**
- [ ] A unit test unifies two kind-`KEffect` rows directly and gets the Leijen result.
- [ ] A unit test unifies a kind-`KStar` var against a row and gets `KindMismatch`.
- [ ] A `freeze` round-trip over a row-bearing type is asserted.
- [ ] Full suite green; still zero golden churn.

**Verify:** `cabal test 2>&1 | grep -iE "kinded representation|All [0-9]+ tests"`

**Steps:**

- [ ] **Step 1: Add a unit-test group**

In `test/Spec.hs`, near the existing `unifyTests`/`rowUnifyTests` groups (find them by name), add tests that build `Type s` values via the monad and assert. Mirror the existing `rowUnifyTests` harness exactly (it already runs `unify`/`unifyRow` in `runTC`). Concretely:
```haskell
    , testCase "kinded representation: row unify still scoped-label" $ do
        -- {x:U64 | r1} ~ {y:U64 | r2} succeeds, threading tails (existing behaviour,
        -- now via the merged `unify`). Reuse whatever the rowUnifyTests group uses to
        -- build rows and assert success.
        <reuse rowUnifyTests harness; assert the two rows unify without error>
    , testCase "kinded representation: KStar vs KEffect is KindMismatch" $ do
        -- Build a fresh KStar var and a RowEmpty; unifying them must fail KindMismatch.
        <runTC: a <- freshTVar KStar; unify sp a RowEmpty>  -- expect Left (KindMismatch ...)
    , testCase "kinded representation: freeze round-trips a row-bearing arrow" $ do
        -- An arrow with a non-empty effect row freezes to CTArr _ (CRExtend ...) _.
        <runTC: build TArr unit (RowExtend "Log" unit RowEmpty) unit; freeze; assert shape = CTArr _ (CRExtend "Log" _ CREmpty) _>
```
Fill the `<...>` using the existing `unifyTests`/`rowUnifyTests` construction helpers in `Spec.hs` (the same `runTC`/`freshTVar`/assertion combinators those groups already use — do not invent new infrastructure). If `freshTVar`/`unify` are not already imported in `Spec.hs`'s test section, add them to the qualified imports used by `unifyTests`.

- [ ] **Step 2: Run + confirm no golden churn**
```bash
cabal test 2>&1 | grep -iE "kinded representation|All [0-9]+ tests"
git diff --stat -- test/ | grep -i golden || echo "ZERO golden churn"
```
Expected: the three new tests pass; total `All 701 tests passed`; no golden changed.

- [ ] **Step 3: Commit**
```bash
git add test/Spec.hs
git commit -m "test(tc): unit tests for kinded representation (kind-dispatch, KindMismatch, freeze) (slice A)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Full-branch review and finish

**Goal:** The standing-rule full-branch review before merge to `main`.

**Files:** none.

**Acceptance Criteria:**
- [ ] Full-branch review `main..HEAD` completed and triaged.
- [ ] Build + test green; zero golden churn vs `main`.
- [ ] Deleted row-sort names gone from `src/` (`CRGen`, `RowVar`, `data RVar`/`CRow`/`Row`, `forceRow`, `freezeRow`); `CRow`/`Row` aliases and `CREmpty`/`CRExtend`/`RowEmpty`/`RowExtend` constructors intentionally remain.
- [ ] Integration decision made with the user (merge confirmed in prose).

**Verify:** review report produced; `cabal test` green.

**Steps:**

- [ ] **Step 1: Verification snapshot**
```bash
cabal build 2>&1 | tail -3
cabal test 2>&1 | grep -iE "All [0-9]+ tests"
git diff --stat main -- test/ | grep -i golden || echo "ZERO golden churn vs main"
grep -rnE 'CRGen|RowVar|RUnbound|RLink|forceRow|freezeRow|data CRow|data Row |data RVar' src/ || echo "clean"
git log --oneline main..HEAD | cat
```

- [ ] **Step 2: Request full-branch review**

Invoke `superpowers-extended-cc:requesting-code-review` scoped to `main..HEAD`. The review must check: the merge is genuinely behaviour-preserving (zero golden churn is the oracle); `unifyVar`'s kind check is correct and the row-skolemization guard (`freezeSig`: kind-`KStar`→`Rigid`, kind-`KEffect`→fresh-`Unbound`) is intact; the merged pretty-printer is byte-identical; no `CRow`/`RVar` remnants; the decidability contract invariants (variable kinds `{KStar, KEffect}` only; no `KArrow`-kinded variable) hold.

- [ ] **Step 3: Triage**

Use `superpowers-extended-cc:receiving-code-review`; apply fixes as small commits; re-run `cabal test` (and the zero-churn check) after each.

- [ ] **Step 4: Finish**

Invoke `superpowers-extended-cc:finishing-a-development-branch`; confirm with the user in prose before merging to `main`.

---

## Self-review (author's pass against the spec, Slice A scope)

- **Spec §6 Slice A (the merge as a no-op):** Tasks 2 (merge) + the zero-golden-churn bar (Tasks 2/3). ✔
- **Spec §7 decidability contract:** held — variable kinds stay `{KStar, KEffect}`; `unifyVar` kind check added (invariant guard); no `KArrow`-kinded variables introduced; `KindMismatch` added but cannot fire on existing programs. ✔
- **Spec §10 correctness-preservation checks:** gen index space (Task 0 fact #1, faithful `CTGen` merge); row non-skolemization (Task 0 fact #2 + Task 1 regression test + Task 2 Step 5 preservation + Task 4 review check). ✔
- **Spec §10 migration shape:** in-place, one large task (Task 2), `-Werror` worklist. ✔ (per the user's decision)
- **Spec §11 testing:** suite-unchanged equivalence proof (Task 2/3) + the named unit tests (Task 3). ✔
- **OUT of Slice A:** no row-kinded params, no surface syntax, no consumers — none added. ✔
- **Naming refinement** (keep `CType`/`Type` names vs the spec's `CTy`/`Ty`) is documented in Background with rationale (minimise churn → achievable zero-golden-churn). ✔
