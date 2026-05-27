# Row-polymorphic records — design

Status: **SUPERSEDED** (2026-05-27)
Owner: zy
Date: 2026-05-26

> **This spec is superseded by `2026-05-27-records-spec.md`.**
>
> After drafting this spec, design discussion converged on a different shape:
> - **Nominal records via `data ... = T { ... }`** — no new keyword (`record`); reuse `data` with extended constructor syntax.
> - **No anonymous structural record types** in sigs — they exist only on the RHS of `+`.
> - **Explicit extension via `+`** — `Point + { score : U64 }` for concrete extension, `Point + r` for row variables. No implicit row tails.
> - **Bare nominal = strict** by default; row polymorphism is explicit opt-in via `+ r`.
> - **Construction is strict** — extras only via spread of an existing extended value.
> - **`with` clause for effect annotations on arrows** (separate concern from records, but designed in parallel).
>
> The original `record` keyword + `..r` row-tail syntax described below was rejected in favor of `data` + `+`-extension. The Leijen scoped-label theory and the internal row machinery are still in scope (now shared between records and effects), but the surface syntax differs substantially.
>
> See `2026-05-27-records-spec.md` for the current design, `2026-05-27-typeclasses-spec.md` for typeclasses + associated types + HKT, and `2026-05-27-effects-spec.md` for the algebraic-effects implementation.

## Motivation

Wok's HM core (commit `f8f0b6c` and ancestors) ships with row-poly *plumbing*: `Type s = TArr (Type s) (Row s) (Type s)`, `Row s = RowEmpty | RowExtend Text (Type s) (Row s) | RowVar (STRef s (RVar s))`, `KEffect` kind, a stub `unifyRow` that handles only the trivial empty-row case. None of it has user-visible surface syntax.

This spec adds row-polymorphic **records** — the first feature that actually exercises that plumbing. Algebraic effects (the dual application of the same row machinery) are a separate later spec; both reuse the same `Row`/`unifyRow` core.

The design philosophy follows Leijen's 2005 scoped-label theory, already committed to by `docs/superpowers/specs/2026-05-25-hm-core-design.md` (line 9: "scoped-label rows, semantic value restriction, no subtyping") and `docs/koka.md` (Paper 1).

## Goals

- Surface syntax for **record types**: closed `{ x : T, y : U }` and open `{ x : T, ..r }` (with `..r` a named row variable, or `..` for anonymous).
- Surface syntax for **record values**: closed `{ x = 1, y = 2 }` and spread `{ ..p, x = 1 }`.
- **Field access**: `p.x` (already in the grammar as `EProj`; semantics now extended to row-polymorphic records).
- Surface syntax for **record patterns**: closed `{ x = a, y = b }` and open `{ x = a, ..rest }` (with `..rest` named or `..` anonymous).
- **Named record declarations**: `record Foo a b = { x : a, ys : [b] }` introducing a named structural record type with optional type parameters. Semantics: eager type-alias expansion (`Foo a b` is shorthand for its structural expansion, fully interchangeable with the anonymous form). Record decls are **closed only** — `record OpenFoo = { x : U64, ..r }` is rejected at parse time.
- **Type inference** for row-polymorphic records: replace the stub `unifyRow` with Leijen 2005's full scoped-label algorithm.
- **Soundness preserved**: Progress + Preservation hold (inherited from Leijen 2005).

## Non-goals (deferred to later specs)

- **Polymorphic variants** (the dual of records: open sums). Row-poly variants share the row machinery on the constructor side; design space is large enough to warrant a separate spec.
- **Algebraic effects.** Effect rows on `->` arrows reuse this spec's row machinery; separate spec when records ship.
- **Multi-spread** in a single record literal/type/pattern (`{ ..p, ..q, x = 1 }`). Allowed at most one `..` per record expression in v1; defer multi-spread to a v2 sugar pass.
- **Mid-position `..`** (`{ x : T, ..r, y : U }`). Tail-only in v1; mid-position is semantically equivalent under scoped labels but adds parser complexity.
- **Punning shorthand** `{ x, y }` for `{ x = x, y = y }`. Defer to a future sugar pass.
- **Nominal-style construction syntax** `Point { x = 1, y = 2 }`. v1 uses structural construction `{ x = 1, y = 2 }` exclusively; the `record Foo = { ... }` decl introduces a type alias-ish nominal type whose values are still constructed structurally.
- **Field mutability.** Records are immutable values; field "update" via `{ ..p, x = v }` always allocates a fresh record value.
- **Subtyping.** No structural subtyping; row polymorphism is the entire mechanism for "this function accepts any record with at least these fields."

## Theory

### Leijen 2005 scoped labels in one paragraph

Records are sequences of labeled fields. Two records are equal iff they have the same labels in the same multiset (order doesn't matter) and equal types per label. **Duplicate labels are allowed and form a stack** — `{ x = 1, x = 2 }` is a valid record value whose `x.x` returns `1` (outermost wins). Record extension `{ x = v, ..r }` *always* adds a new layer on top of `r`, never overwrites. This duplicate-allowing design dodges the principal-type ambiguity that plagues Wand-style row systems (see `docs/koka.md` Paper 1 review).

### What changes in the type system

The existing `Row` and `RVar` constructors in `Wok.TypeChecking.Types` are already correct for this theory. No new constructors needed. What changes:

- `unifyRow` in `Wok.TypeChecking.Unify` gets the full Leijen scoped-label algorithm (currently a stub handling only `RowEmpty ~ RowEmpty`).
- `Wok.TypeChecking.Infer` gains inference rules for record literals, field access, record patterns, record extension, and record declarations.
- The closed CType form gets a `CTRecord CRow` variant (parallel to `CTArr` for functions). Wait — actually records can be represented as `CTCon (TcRecord) [implicit row arg]`. See "Type representation" below for the design choice.
- A new `TyCon` constructor `TcRecord` represents the record type constructor; its single argument is a Row carrying the labeled fields.

### Type representation

A record type `{ x : U64, y : Bool }` is represented internally as:

```haskell
CTCon TcRecord [CTRow (CRExtend "x" (CTCon TcU64 []) (CRExtend "y" (CTCon TcBool []) CREmpty))]
```

…but wait, `[CType]` arguments can't hold a `CRow` directly. The cleanest fix: introduce a `CTRow CRow` constructor as a CType so rows can appear in tycon argument positions, OR special-case `TcRecord` as `CTRecord CRow`. The spec proposes the latter:

```haskell
-- in Wok.TypeChecking.Types:
data CType
  = CTCon TyCon [CType]
  | CTArr CType CRow CType
  | CTRecord CRow         -- new
  | CTGen Int
```

…and parallel for the mutable `Type s`:

```haskell
data Type s
  = TCon TyCon [Type s]
  | TArr (Type s) (Row s) (Type s)
  | TRecord (Row s)       -- new
  | TVar (STRef s (TVar s))
```

This matches the structure of `TArr` (which carries a row in the middle): both function arrows and records are constructors with row payload. The unifier can recurse into `TRecord` rows uniformly with `TArr`'s row slot.

(Alternative considered: a `TcRecord` tycon name with a row-shaped argument representation hack. Rejected as less clean than a dedicated constructor.)

### Surface ↔ internal mapping

| Surface                    | Internal                                                            |
| -------------------------- | ------------------------------------------------------------------- |
| `{ x : T, y : U }`         | `CTRecord (CRExtend "x" T (CRExtend "y" U CREmpty))`                |
| `{ x : T, ..r }`           | `CTRecord (CRExtend "x" T (CRGen r))` (with `r` a generalised slot) |
| `{ ..r }`                  | `CTRecord (CRGen r)`                                                |
| `{}` (empty record type)   | `CTRecord CREmpty`                                                  |
| `record Foo = { x : T }`   | A `TyConInfo` named `"Foo"` whose internal expansion is a record CType (see "Named record types"). |

## Surface syntax

### Type positions

```wok
{}                                  -- empty closed record type
{ x : U64 }                         -- closed record with one field
{ x : U64, y : Bool }               -- closed record with two fields
{ x : U64, ..r }                    -- open record: must have x : U64; r is the rest (named)
{ x : U64, .. }                     -- open record with anonymous rest
{ ..r }                             -- pure row variable (named); matches any record
{ .. }                              -- pure row variable (anonymous)
```

**Closed vs open** is a load-bearing distinction. `{ x : U64 }` only unifies with another `{ x : U64 }`. `{ x : U64, ..r }` (or `..`) unifies with `{ x : U64 }`, `{ x : U64, y : Bool }`, etc.

**Anonymous `..` semantics:** treated as a fresh `Unbound` row variable (NOT rigid). Multiple anonymous occurrences in the same sig may be unified by the body (Case 1 below) or independently inferred to closed (Case 2). Same relationship as `_` in pattern positions or in `PartialTypeSignatures`.

**Named `..r` semantics:** forall-bound at the sig boundary, frozen as `Rigid` by `freezeSig` before unifying against the body. Multiple `..r` (same name) MUST unify; this is the contract-enforcement mechanism for "preserves rest."

Worked example of the anonymous/named distinction:

```wok
-- Case 1: anonymous, body forces sharing
setX : { x : U64, .. } -> U64 -> { x : U64, .. }
setX p n = { ..p, x = n }
-- Inferred sig: forall r. { x : U64, ..r } -> U64 -> { x : U64, ..r }
-- (Both anonymous .. unify through the body.)

-- Case 2: anonymous, body doesn't preserve rest
keepOnlyX : { x : U64, .. } -> { x : U64, .. }
keepOnlyX p = { x = p.x }
-- Inferred sig: forall r. { x : U64, ..r } -> { x : U64 }
-- (Output `..` clamps to RowEmpty because the body returns a closed record.)

-- Case 3: named, body must preserve rest
keepOnlyX' : { x : U64, ..r } -> { x : U64, ..r }
keepOnlyX' p = { x = p.x }
-- Type error: rigid row escape. Sig promised row polymorphism; body broke it.
```

### Value construction

```wok
empty = {}                          -- empty record value
p = { x = 1, y = 2 }                -- closed literal
q = { ..p, z = 3 }                  -- spread p, add z (scoped: z is on top)
shifted = { ..p, x = 99 }           -- spread p, override x (scoped: outer x = 99 wins)
```

**Spread source** (`..e` in expression position) requires a real expression — there's no anonymous form here (anonymous would have nothing to spread). At most one spread per record literal in v1.

**Scoped labels in values**: `{ ..p, x = 99 }` where `p` already has `x` does NOT overwrite — it pushes a new `x = 99` layer on top. Field access reads outermost, so `(.x) { ..p, x = 99 }` is `99` regardless of what `p.x` was.

### Field access

Already in the grammar as `EProj`:

```wok
p.x                                 -- field access; type is the type of x in p's row
p.x.y                               -- chained: nested record access
```

Semantics: `p.x` reads the **outermost** `x` layer in `p`'s row. Type: if `p : { x : T, ..r }`, then `p.x : T`.

### Pattern matching

```wok
case point of
  { x = 0, y = 0 } -> "origin"                  -- closed pattern (matches only 2-field records)
  { x = a, y = b } -> ...                       -- closed pattern, bind both
  _ -> ...

case event of
  { kind = "click", ..rest } -> handleClick rest -- match kind, bind the rest
  { kind = "key",   ..rest } -> handleKey rest
  { kind = _,       .. }     -> ignore           -- match any record with kind, discard rest
```

Pattern row-tail `..rest` binds the leftover fields as a record. `..` (anonymous) discards them. The bound name has type `{ ..rfresh }` where `rfresh` is a fresh row variable representing exactly the fields not matched.

### Record declarations

```wok
record Point = { x : U64, y : U64 }                     -- monomorphic, closed
record User  = { name : String, age : U64 }
record Container a = { value : a }                       -- polymorphic
record Pair a b = { fst : a, snd : b }
```

`record` introduces a **named structural record type** (eager-alias semantics). Values are constructed and pattern-matched as ordinary anonymous records of the matching shape; the `record` keyword gives the type a name and may declare type parameters. The keyword is already reserved in `grammar/Wok.cf` (`ReservedKw ::= "contract" | "type" | ... | "record"`).

**Semantics (committed):**

1. **Eager type-alias expansion.** `Point` IS `{ x : U64, y : U64 }`. The typechecker's `resolveTyCon "Point"` expands to the underlying `CTRecord` form immediately; downstream inference and unification see the expanded structural type. `p : Point` and `p : { x : U64, y : U64 }` are fully interchangeable: a `Point`-typed binding can be passed to a function expecting `{ x : U64, y : U64 }`, and vice versa.

2. **Closed-only.** Record declarations declare a CONCRETE record type. Open declarations (`record OpenFoo = { x : U64, ..r }`) are rejected at parse time — there's no `RowTail` production for `DRecord`. If a caller wants a polymorphic record family, they write the polymorphic sig inline (e.g. `mkContainer : a -> { value : a, ..r }`).

3. **Polymorphic via type parameters.** `record Container a = { value : a }` parameterises the record by `a`; `Container U64` is `{ value : U64 }`, `Container String` is `{ value : String }`. The type-parameter mechanism mirrors existing `data Maybe a = ...` syntax.

4. **No nominal wrapper.** v1 does NOT introduce a fresh tycon distinct from its expansion. If "newtype-style" nominal records are wanted later (to catch accidental cross-record-type confusion), that's a separate spec — but the alias-default keeps the mechanism count low for v1.

## Grammar changes

Additions to `grammar/Wok.cf`. New token `..` (two dots, distinct from `.`).

```bnfc
-- Token level: two-dot is its own keyword (longest-match)
-- (existing single `.` continues to work for module paths and EProj)

-- Type positions (Type2 — atomic types)
TRecord.       Type2 ::= "{" [RecordFieldType] "}" ;
TRecordOpen.   Type2 ::= "{" [RecordFieldType] "," RowTail "}" ;
TRowOnly.      Type2 ::= "{" RowTail "}" ;

RFType.        RecordFieldType ::= VarId ":" Type ;
separator      RecordFieldType "," ;

-- Row-tail forms (named / anonymous), shared between Type and Pat
RTNamed.       RowTail ::= ".." VarId ;
RTAnon.        RowTail ::= ".." ;

-- Expression positions (Exp2 — atomic exprs)
ERecord.       Exp2 ::= "{" [RecordFieldExpr] "}" ;
ERecordExt.    Exp2 ::= "{" ".." Exp "," [RecordFieldExpr] "}" ;

RFExpr.        RecordFieldExpr ::= VarId "=" Exp ;
separator      RecordFieldExpr "," ;

-- Pattern positions (AtomPat)
PRecord.       AtomPat ::= "{" [RecordFieldPat] "}" ;
PRecordOpen.   AtomPat ::= "{" [RecordFieldPat] "," PatRowTail "}" ;

RFPat.         RecordFieldPat ::= VarId "=" Pat ;
separator      RecordFieldPat "," ;

PRTNamed.      PatRowTail ::= ".." VarId ;
PRTAnon.       PatRowTail ::= ".." ;

-- Top-level decl: named record type (closed only; supports type parameters)
DRecord.       Decl ::= "record" ConId [VarId] "=" "{" [RecordFieldType] "}" ;
```

**LALR(1) check.** The lookahead `{` opens a record in all three syntactic positions (type, expression, pattern). The token after `{` disambiguates:
- `}` → empty (already valid).
- `VarId ":"` → a record-field-type → `TRecord` (or `TRecordOpen` if `..` follows).
- `VarId "="` → a record-field-expr or record-field-pat (context-dependent).
- `".."` → `TRowOnly` / `ERecordExt` / `PRTNamed`/`PRTAnon`.

The grammar is LALR(1) clean because `{` only opens records (no block/let/where competition — those use `let { ... }` with the layout filter inserting the explicit braces).

**Lexer addition.** The `..` token is a new fixed string the lexer recognizes via BNFC's standard longest-match. Existing single `.` (used in `EProj` and `MPDot`) is unaffected — `..` is a longer match and wins.

**Layout-filter consideration.** Like the operator-name sig fix (commit `0556ee3` + `351b38b`), top-level decls starting with `{` (e.g. `record Foo = { ... }` is fine; but if any user-facing decl ever starts with `{` literally) would need the same `maybeInsertSeparator`-on-`isParenOpen` patch. Since `record` starts with the `record` keyword (not `{`), this is not exercised by record decls. But the layout filter is already patched, so no further changes needed.

After editing the grammar, regenerate:

```sh
bnfc --haskell -d --text-token -p GeneratedParser -o src-generated grammar/Wok.cf
```

## Type-system implementation

### `Wok.TypeChecking.Types` — additions

Add a `TRecord` constructor to the mutable `Type s` and a `CTRecord` constructor to the closed `CType`:

```haskell
data Type s
  = TCon TyCon [Type s]
  | TArr (Type s) (Row s) (Type s)
  | TRecord (Row s)             -- NEW
  | TVar (STRef s (TVar s))

data CType
  = CTCon TyCon [CType]
  | CTArr CType CRow CType
  | CTRecord CRow               -- NEW
  | CTGen Int
```

`Row s` and `CRow` representations are unchanged (already correct from the HM core spec).

### `Wok.TypeChecking.Unify` — replace the stub

Replace the current `unifyRow` (which handles only `RowEmpty ~ RowEmpty`) with the full Leijen 2005 algorithm:

```haskell
-- in Wok.TypeChecking.Unify

unifyRow :: BNFC'Position -> Row s -> Row s -> TC s ()
unifyRow pos r1 r2 = do
  r1' <- forceRow r1
  r2' <- forceRow r2
  case (r1', r2') of
    (RowEmpty, RowEmpty) -> pure ()

    (RowVar v1, RowVar v2)
      | v1 == v2 -> pure ()
      | otherwise -> bindRowVar pos v1 r2'

    (RowVar v, row) -> bindRowVar pos v row
    (row, RowVar v) -> bindRowVar pos v row

    (RowExtend l1 t1 rest1, row2) -> do
      -- Rewrite row2 so its head label is l1
      (t2, rest2') <- rewriteRow pos l1 row2
      unify pos t1 t2
      unifyRow pos rest1 rest2'

    -- Catch-all: mismatched shapes (e.g. RowExtend vs RowEmpty)
    _ -> throwError (RowMismatch (toSpan pos) (freezeRowFast r1') (freezeRowFast r2'))

-- Rewrite a row so that label `l` is at its head, returning the corresponding
-- type at that position and the remaining row after stripping it.
rewriteRow :: BNFC'Position -> Text -> Row s -> TC s (Type s, Row s)
rewriteRow pos l row = do
  row' <- forceRow row
  case row' of
    RowExtend l' t rest
      | l == l'   -> pure (t, rest)
      | otherwise -> do
          (t', rest') <- rewriteRow pos l rest
          pure (t', RowExtend l' t rest')
    RowVar v -> do
      -- Allocate fresh t and rest', extend v to RowExtend l t rest'
      tFresh    <- freshTVar KStar
      restFresh <- freshRowVar
      bindRowVar pos v (RowExtend l tFresh restFresh)
      pure (tFresh, restFresh)
    RowEmpty -> throwError (RowMismatch ...)  -- label l not found and no row tail
```

**Occurs check on row variables**: `bindRowVar` must call `occursAdjustRow` before binding, to prevent infinite rows (the row variable being bound to a row containing itself).

### `Wok.TypeChecking.Infer` — new inference rules

Five new cases plus type-translation extensions:

**Translate `Abs.TRecord` / `Abs.TRecordOpen` / `Abs.TRowOnly`:**
- `Abs.TRecord fields` → translate each field to `(label, CType)`, build a closed CRow, wrap with `CTRecord`.
- `Abs.TRecordOpen fields tail` → like above, then attach `tail`'s row variable (named or fresh anonymous) as the row tail.
- `Abs.TRowOnly tail` → `CTRecord` wrapping just the row tail.

Mirror this in `goT` and `walkArg` (the two type-translation walkers in `Infer.hs`).

**Infer record literal `Abs.ERecord fields`:**
```haskell
inferExprW mono (Abs.ERecord fields) = do
  -- Each field's RHS is inferred independently.
  pairs <- forM fields $ \(Abs.RFExpr (Abs.VarId (_, label)) e) -> do
    t <- inferExprW mono e
    pure (label, t)
  -- Build a closed Row from the inferred fields.
  let row = foldr (\(l, t) rest -> RowExtend l t rest) RowEmpty pairs
  pure (TRecord row)
```

**Infer record extension `Abs.ERecordExt base fields`:**
```haskell
inferExprW mono (Abs.ERecordExt base fields) = do
  baseT <- inferExprW mono base
  baseRow <- expectRecord baseT  -- unify baseT with TRecord (fresh row var) and extract
  -- Append new fields as layers on top of baseRow.
  pairs <- forM fields $ \(Abs.RFExpr (Abs.VarId (_, label)) e) -> do
    t <- inferExprW mono e
    pure (label, t)
  let row = foldr (\(l, t) rest -> RowExtend l t rest) baseRow pairs
  pure (TRecord row)
```

**Infer field access `Abs.EProj e (Abs.VarId (_, label))`** — this case already exists for module-path projection but currently doesn't handle records. Extend it:

```haskell
inferExprW mono (Abs.EProj e (Abs.VarId (_, label))) = do
  eT <- inferExprW mono e
  row <- expectRecord eT
  -- Use rewriteRow to extract the field's type from the row.
  (fieldT, _rest) <- rewriteRow (Just (...)) label row
  pure fieldT
```

**Infer record pattern `Abs.PRecord fields` / `Abs.PRecordOpen fields tail`:**
```haskell
inferAtomPat (Abs.PRecord fields) = do
  pairResults <- forM fields $ \(Abs.RFPat (Abs.VarId (_, label)) pat) -> do
    (patT, binds) <- inferAtomPat pat
    pure ((label, patT), binds)
  let row = foldr (\((l, t), _) rest -> RowExtend l t rest) RowEmpty pairResults
      binds = concatMap snd pairResults
  pure (TRecord row, binds)

inferAtomPat (Abs.PRecordOpen fields tail) = do
  -- Like above, but the tail is a fresh row variable (named or anonymous).
  -- Named tail binds a record-typed name into the pattern's environment.
  ...
```

**Process record decl `Abs.DRecord name params fields`** — register an alias-expanding TyCon for the named record type:

```haskell
-- Inside processDataDecls' fold over decls:
case decl of
  Abs.DRecord (Abs.ConId (pos, name)) params fields -> do
    -- 1. Translate field types in an env where `params` are bound to fresh CTGen slots.
    -- 2. Build a CRow from the translated fields (closed; no row tail).
    -- 3. Register a TyConInfo for `name` with arity `length params`, whose underlying
    --    "expansion" is the CTRecord crow.
    -- 4. resolveTyCon "Point" then returns a CTRecord (not a CTCon (TcUser "Point")),
    --    so all downstream typechecking sees the expanded structural form.
```

The expansion happens at `resolveTyCon` time (eager). Error messages show the expanded form for v1 — option to preserve the original name `Point` in error messages is a future ergonomics polish.

## Soundness

Inherited from Leijen 2005's proof of Progress + Preservation for scoped-label rows. Wok's design constraints align with that proof's preconditions:

- **No subtyping** (HM design doc, line 9, 48): no covariance / contravariance hazards.
- **Immutable records** (this spec, non-goals): no aliasing-plus-mutation unsoundness.
- **Rank-1 HM** (HM design doc, non-goals line 44): no higher-rank trickery.
- **Scoped labels** (this spec, theory): no Wand-style principal-type ambiguity.

See the `docs/koka.md` review of Paper 1 for the full soundness argument summary.

## Performance

Leijen's `unifyRow` is O((n+m)²) worst case where n, m are the field counts of the two rows being unified. For realistic record sizes (5-30 fields) this is sub-millisecond per call. Per the production Koka implementation: row unification is never the typechecker bottleneck.

If profiling ever surfaces row unification as hot, the standard optimization is to maintain a canonical sorted-by-label representation internally; this turns the algorithm into a merge of sorted sequences (O(n+m)). Defer until measured to need it.

## Examples

### A. Basic record usage

```wok
record Point = { x : U64, y : U64 }

origin : Point
origin = { x = 0, y = 0 }

move : U64 -> U64 -> Point -> Point
move dx dy p = { ..p, x = p.x + dx, y = p.y + dy }
```

### B. Generic field accessor

```wok
getName : { name : String, ..r } -> String
getName p = p.name

-- Works on any record with a `name` field:
greeting1 = getName { name = "Alice", age = 30 }
greeting2 = getName { name = "tax-form", id = 42 }
```

### C. Pipeline accumulation

```wok
parseRequest : RawBytes -> { url : String, method : String }
parseRequest bytes = ...

authenticate : { url : String, ..r } -> { url : String, user : User, ..r }
authenticate req = { ..req, user = lookupUser req.url }

addTimestamp : { ..r } -> { timestamp : U64, ..r }
addTimestamp r = { ..r, timestamp = now () }

handle : RawBytes -> { url : String, method : String, user : User, timestamp : U64 }
handle bytes = bytes
  |> parseRequest
  |> authenticate
  |> addTimestamp
```

### D. Pattern peel-off

```wok
processEvent : { kind : String, payload : Payload, ..rest } -> Result
processEvent { kind = k, payload = p, ..rest } =
  case k of
    "click" -> handleClick p rest
    "key"   -> handleKey p rest
    _       -> ignore
```

### E. Anonymous row tail when no sharing needed

```wok
log : { name : String, .. } -> ()
log p = print ("processing " ++ p.name)
```

## Test plan

Add to the existing `tasty` suite:

| Test                            | Asserts                                                                                       |
| ------------------------------- | --------------------------------------------------------------------------------------------- |
| `parseRecordTypes`              | Parsing all three record-type forms (closed, open named, open anonymous, pure-row) round-trips. |
| `parseRecordValues`             | Closed literal + spread + spread-with-override all parse + round-trip.                         |
| `parseRecordPatterns`           | All pattern forms parse + round-trip.                                                          |
| `parseRecordDecl`               | `record Foo = { ... }` parses + round-trips.                                                   |
| `typecheckClosedRecord`         | `p = { x = 1, y = 2 }` infers as `{ x : U64, y : U64 }`.                                       |
| `typecheckGenericAccessor`      | `getName p = p.name` infers `forall a r. { name : a, ..r } -> a`.                              |
| `typecheckRecordExt`            | `{ ..p, x = 1 }` correctly extends p's type.                                                   |
| `typecheckRowPolymorphism`      | Worked example C (pipeline accumulation) typechecks end-to-end.                                |
| `typecheckScopedLabelDuplicate` | `{ ..p, x = 99 }` where `p.x` exists results in a 2-deep row; access returns outermost.        |
| `typecheckPatternPeelOff`       | Pattern `{ x = a, ..rest }` binds `a` and `rest`; `rest`'s type excludes `x`.                  |
| `typecheckNamedRowMustShare`    | `f : { x : U64, ..r } -> { x : U64, ..r }; f p = { x = p.x }` is rejected (rigid row escape). |
| `typecheckAnonymousRowDoesNot`  | Same but with `..` anonymous: inference clamps output to closed, no error.                     |
| `typecheckRecordDecl`           | `record Point = { x : U64, y : U64 }; origin : Point; origin = { x = 0, y = 0 }` typechecks.   |
| `unifyRowSameLabels`            | Unifying two rows with identical labels and types succeeds, doesn't allocate fresh vars.       |
| `unifyRowDifferentOrder`        | `{ x : U64, y : Bool }` unifies with `{ y : Bool, x : U64 }`.                                  |
| `unifyRowVarRewriting`          | `{ x : U64, ..r }` unifies with `{ x : U64, y : Bool }` binding `r := { y : Bool, ..r' }`.    |
| `unifyRowOccursCheck`           | Trying to unify `r` with `{ x : r }` produces an OccursCheck error.                            |

Plus golden tests for representative programs under `test/typecheck-examples/` (e.g., `13-records.wok`, `14-row-polymorphism.wok`, `15-record-decl.wok`, `16-pattern-peel.wok`) and corresponding fail fixtures.

## File / module changes summary

| File                                    | Action                                                                                |
| --------------------------------------- | ------------------------------------------------------------------------------------- |
| `grammar/Wok.cf`                        | Add record productions (type, expression, pattern, decl), plus the `..` token.        |
| `src-generated/GeneratedParser/Wok/*`   | Regenerate via BNFC.                                                                  |
| `src/Wok/TypeChecking/Types.hs`         | Add `TRecord (Row s)` and `CTRecord CRow` constructors.                                |
| `src/Wok/TypeChecking/Unify.hs`         | Replace stub `unifyRow` with Leijen 2005 algorithm; add `rewriteRow`; update `force`/`freeze` walkers for new TRecord/CTRecord constructors. |
| `src/Wok/TypeChecking/Infer.hs`         | Add `inferExprW` cases for `ERecord`, `ERecordExt`, `EProj` (extended for records); add `inferAtomPat` cases for `PRecord`, `PRecordOpen`; add record-decl handling in `processDataDecls`; extend `translateSig`'s `goT` and `processDataDecls`'s `walkArg` for new type AST nodes. |
| `src/Wok/TypeChecking/Error.hs`         | Add row-related error variants if not already adequate (currently has `RowMismatch`).  |
| `src/Wok/Reordering.hs`                 | Add identity-passthrough cases for new expression / pattern constructors (catchall should already cover, but verify).  |
| `prelude/Std/Base.wok`                  | No required changes; records are user-facing.                                          |
| `examples/`                             | Add a `records-tour.wok` example file demonstrating the new syntax.                    |
| `test/typecheck-examples/`              | Add 4-5 new fixtures covering the test plan.                                           |
| `test/typecheck-fail-examples/`         | Add 2-3 fixtures exercising soundness boundaries (rigid row escape, duplicate-decl, etc). |
| `test/Spec.hs`                          | Add row-unification unit tests (parallel to existing `unifyTests` / `unifyWalksTests`). |

## Migration / impact

This is purely **additive**: no existing valid Wok program changes meaning. Specifically:

- The current grammar has no `{ ... }` productions at the value/type/pattern level (`{ ... }` was only a layout-filter artifact for `let { ... }`). New record productions fill that gap without affecting any existing code.
- The `record` keyword is already reserved; existing code can't use `record` as an identifier.
- The `..` token is new; no existing Wok code can contain it.
- Field access syntax `p.x` already parses (as `EProj`); its semantics extends to records without changing existing behavior on module paths (`Std.Base.foo`).

No test fixtures or examples need migration for backwards-compatibility reasons.

## Open hooks for future specs

This spec preserves three named extension points for follow-up work:

1. **Polymorphic variants** — the dual application of the same row machinery on constructor (sum) types. Same `Row`/`unifyRow` core; syntax like `[ Red | Green | ..vs ]`. Reuses `RowExtend`/`RowVar`/scoped labels.
2. **Algebraic effects** — effect rows on `->` arrows. The existing `TArr (Type s) (Row s) (Type s)` already has the row slot; this spec doesn't introduce non-empty rows there. Effects spec wires the surface syntax (`A -> B !{ io, ..e }`) and inference rules.
3. **Field-access on first-class rows** — once row types are first-class, optics-style abstractions become directly expressible. Probably never need a separate language feature, but library combinators emerge naturally.

The records spec doesn't block any of these; it just makes the unification infrastructure battle-tested by virtue of being used by a complete feature.
