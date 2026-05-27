# Records — design

Status: draft (rev 2 — refined row polymorphism semantics)
Owner: zy
Date: 2026-05-27 (rev 2: 2026-05-27)

## Motivation

Wok needs a record type — a labeled-field aggregate distinct from tuples. The internal type system has been pre-wired with row-polymorphic machinery (`Row`, `RVar`, `unifyRow` stub, `KEffect` kind) since the HM core spec, anticipating both records and effects as later applications. This spec defines the surface syntax and inference rules for records, claiming the simpler of the two row-using features.

Records here are **nominal by default** (declared via `data`), with **explicit row-extension via `+`** at the type level. Anonymous structural records are intentionally NOT a first-class concept — they appear only as the right-hand side of `+`. The design favors strict, explicit annotation over implicit row polymorphism; users opt into row polymorphism via named row variables.

This spec supersedes `2026-05-26-row-polymorphic-records-design.md`, which proposed a structural-with-anonymous-types design that was rejected after discussion converged on the nominal-by-default approach.

## Goals

- **Single declaration mechanism** — extend the existing `data` keyword with a record-style constructor:
  ```wok
  data Point = Point { x : U64, y : U64 }
  ```
- **Explicit row extension** at the type level — `Point + { score : U64 }` for concrete extensions, `Point + row r` for row variables (`row` is a keyword marking row variables distinct from ordinary type variables).
- **Strict nominal identity** — `data UserId = UserId { value : U64 }` and `data OrderId = OrderId { value : U64 }` are distinct types; values cannot cross.
- **Strict construction** — `Point { x = 1, y = 2 }` is strict (extras error). Extensions exist only by spread from an existing value.
- **Field access** uses existing `EProj` syntax — `p.x`.
- **Pattern matching** with explicit row-tail wildcard — `Point { x = a, y = b }` is strict; `Point { x = a, y = b, .. }` is open.
- **Leijen 2005 scoped-label unification** wired up internally; surface syntax is nominal-anchored to keep the row machinery legible to users.
- **Soundness inherited from Leijen 2005**: Progress + Preservation hold under Wok's design constraints (no subtyping, immutable records, rank-1 HM).

## Non-goals

Deferred to future specs:

- **Polymorphic variants** — the dual application of rows on sum-type constructors. Same row machinery; different surface syntax.
- **Multi-spread in a single record literal** — `{ ..p, ..q, x = 1 }`. v1 allows at most one `..` per literal.
- **Mid-position `..`** — `{ x = 1, ..p, y = 2 }`. v1 requires `..` to appear last in field-list position.
- **Punning shorthand** — `{ x }` for `{ x = x }`. Sugar pass.
- **Nominal-wrapper (newtype-style) records** — `UserId` and `OrderId` are already distinct under data-keyword nominality; no separate `newtype` keyword.
- **Field mutability** — records are immutable; spread is the update mechanism.
- **Subtyping** — no structural subtyping; row polymorphism is the only "this function accepts any record with at least these fields" mechanism.
- **Anonymous structural record types** — `{ x : T, y : U }` is NOT a valid type expression except as the RHS of `+`.
- **Named row-tail capture in patterns** (`Point { x = a, ..rest }`) — the `rest` binder would need an anonymous-record type, which the design forbids. v1 supports only anonymous wildcard `..` (discard extras). Named capture deferred to v2.
- **Same-field-name across multi-constructor records** — `data X = A { x : U64 } | B { x : String }` is rejected in v1. Each field name across all constructors of a single `data` decl must be unique. Disambiguation machinery can come later.
- **Record constructors as first-class functions** — Unlike Haskell, the name of a record-form constructor (e.g., `Point` in `data Point = Point { x : U64, y : U64 }`) is not a callable value. Construction requires `T { ... }` literal syntax; `let f = Point` and `map Point xs` are errors. Wrapper functions are a one-line workaround. Positional constructors (`Just a`, `Ok a`) remain first-class curried functions; the asymmetry mirrors the asymmetry of the surface forms.
- **`Lacks`-style row constraints** — constraints like `forall r. Lacks "tag" r => Point + row r -> Point + row r + { tag : T }` that statically rule out row-variable instantiations introducing label collisions. v1 emits a warning at shadow-inducing call sites instead. **Planned for v2** — the warning is an interim accommodation, not the long-term answer.
- **Row-tail removal operator** — a `-` or `\` operator that pops the outermost scoped label, exposing inner shadowed labels. v1 has no syntax to access inner shadowed labels. **Planned for v2** — pairs with `Lacks` constraints to give the full Leijen-style row toolkit.

## The row-polymorphism model

This is the conceptual model the rest of the spec elaborates. Reading this first makes the surface rules below feel inevitable.

**Every record value has a nominal type tag and a row of fields.** The tag comes from the `data` constructor used to make it. The row contains the labeled fields. Internally: `TRecord Text (Row s)` — the `Text` is the tag (e.g. `"Point"`), the `Row` is the field labels with their types.

**Construction tags + populates row.** `Point { x = 1, y = 2 }` produces a value whose internal type is `TRecord "Point" (RowExtend "x" U64 (RowExtend "y" U64 RowEmpty))`.

**Extension `+` adds to the row, never changes the tag.** `Point + { score : U64 }` is `TRecord "Point" (row with Point's declared fields + score)`. `Point + row r` is `TRecord "Point" (row with Point's declared fields + open row variable r)`. The tag stays `"Point"` throughout — extension never changes nominal identity.

**Unification checks tag first, then row.** Two record types unify iff (a) their tags match, AND (b) their rows unify per Leijen 2005 scoped-label algorithm. `UserId + row r` and `OrderId + row r` never unify, regardless of row contents.

**Row polymorphism = preserving the row tail.** A function `Point + row r -> Point + row r` accepts any extension and returns a value with the same extension. Internally, the row variable `r` is forall-bound. Callers passing `Point + { score : U64 }` instantiate `r := { score : U64 }`; the function preserves it through. The `row` keyword distinguishes row variables from ordinary type variables at the surface syntax level.

**Record constructors are not values.** Unlike positional constructors (which are curried functions like `Just : a -> Maybe a`), record-form constructors exist only as syntactic markers inside `T { ... }` literals and patterns. The name is never callable — there is no `let f = Point` form, no `map Point xs`. Users who need a first-class construction function write a one-line wrapper.

**Bare nominal is strict.** `Point` (without `+ row r`) means EXACTLY `Point` — no extras allowed. A caller with `Point + { score : U64 }` cannot pass to a function expecting `Point` without explicitly stripping the extension. The strict default is deliberate: users opt into row tolerance via `+ row r`.

**Field access is statically known.** `p.x` works iff `x` is known in `p`'s type — either in the base declaration (`Point`'s `x : U64`) or in a concrete extension (`Point + { score : U64 }` exposes `score`). For row-polymorphic types `Point + row r`, only the base-declared fields are accessible; `r`'s contents are opaque to the function body. The function cannot read through `r`, cannot inspect what's in `r`, and cannot pattern-branch on `r`. This is parametricity: the body must work uniformly for every possible instantiation of `r`.

**Pattern matching is strict by default; explicit `..` opens.** A pattern `Point { x = a, y = b }` matches ONLY closed `Point` values. To match values with extensions, add `..` at the end: `Point { x = a, y = b, .. }`. The `..` discards extras (named capture is deferred).

**Construction is bidirectional.** If a constructor literal is checked against an expected type:
- Expected `Point` → accept only `Point`'s declared fields; extras error.
- Expected `Point + { ext fields }` → accept `Point`'s fields PLUS any from the extension; anything else errors.
- No expected type (pure inference) → strict (only declared fields).

This last rule lets users write `Point { x = 0, y = 0, score = 99 }` when a sig says `Point + { score : U64 }`, but the same construction errors when no sig context is available.

## Surface syntax

### Declarations

`data` decls support both positional (existing) and record-field (new) constructor argument shapes:

```wok
-- Existing positional form (unchanged):
data Maybe a = Nothing | Just a
data Either a b = Left a | Right b

-- New record form:
data Point = Point { x : U64, y : U64 }
data User  = User  { name : String, age : U64 }

-- With type parameters:
data Container a = Container { value : a }
data Pair a b    = Pair      { fst : a, snd : b }

-- Multi-constructor records (each constructor has its own field list):
data Shape 
  = Circle { radius : U64 }
  | Square { side : U64 }
  | Rect   { width : U64, height : U64 }

-- Mixed positional + record across constructors:
data Result a e
  = Ok a
  | Err { message : String, code : U64 }
```

**Constraint:** A single constructor's field list is closed at the declaration. To express "Point with extras," use `+` at use site.

#### Block layout for record fields

Record-field lists may be written either inline (comma-separated, on one line) or as an indent-delimited block. Newlines inside `{ ... }` act as virtual separators, equivalent to commas. The rule applies uniformly across all four record-syntactic contexts — declarations, type extensions, value construction, and patterns.

```wok
-- Inline:
data Point = Point { x : U64, y : U64 }

-- Block (newlines separate fields):
data Point = Point {
  x : U64
  y : U64
}

-- Mixed (newline OR comma terminates a field):
data Big = Big {
  name : String, age : U64
  address : String
  score : U64
}
```

Nested record literals each open their own layout context; the brace-context stack handles this naturally.

#### Constructor name elision (sugar)

In a single-constructor record decl where the constructor would share the data-type's name, the constructor name may be omitted. The desugared form is identical:

```wok
-- These two are equivalent:
data Point = Point { x : U64, y : U64 }
data Point = { x : U64, y : U64 }

-- With block layout:
data Point = {
  x : U64
  y : U64
}
```

Constraints on elision:

1. **Single-constructor decls only.** `data Shape = { x : U64 } | Square { side : U64 }` is rejected (no implicit name for the first alternative).
2. **Record form only.** Positional constructors must always name themselves explicitly.
3. **Use sites are unaffected.** Construction is still `Point { x = 1, y = 2 }`; patterns are still `Point { x = a, y = b }`. The internal tag is still `"Point"`. The sugar is purely at the decl site.

### Type-position syntax (sigs)

```wok
-- Strict nominal (default):
moveBy : U64 -> U64 -> Point -> Point

-- Extension with concrete fields:
withScore : U64 -> Point -> Point + { score : U64 }

-- Extension with row variable (row polymorphism):
preserveExtras : Point + row r -> U64 -> Point + row r

-- Multiple extension layers:
addBoth : Request + row r -> Request + row r + { user : User } + { trace : String }
```

**Row variables are marked with `row`.** Writing `Point + r` (without `row`) parses as `Point + r` where `r` is a regular type variable — which is not a valid type-extension shape (the RHS of `+` must be either a concrete record `{ ... }` or a row variable `row r`). The elaborator rejects bare `Point + r` with a targeted error suggesting `Point + row r`.

**Anonymous record types are valid ONLY as the RHS of `+`.** A bare `{ x : U64, y : U64 }` is NOT a legal type expression elsewhere. The grammar restricts anonymous record syntax to the `RowContrib` non-terminal, which only appears as the right operand of `+`.

**Field collisions in extension** (`Point + { x : String }` where `Point` already has `x`) are compile errors. No scoped-label layering at the type-decl level.

### Value construction

Construction is **bidirectional**: the typechecker uses the expected type (from sig or surrounding context) to determine what's allowed in the literal.

```wok
-- No expected type (inferred-only context): STRICT — extras error
origin = Point { x = 0, y = 0 }                        -- type: Point  (strict construction)
unit   = Point { x = 0, y = 0, z = 5 }                 -- COMPILE ERROR: z not declared (no sig context allows it)

-- Expected type from sig: extras allowed if they match the extension
named : Point + { score : U64 }
named = Point { x = 0, y = 0, score = 99 }             -- OK: sig says Point + { score : U64 }; score is in the extension

scored : Point + { score : U64, color : String }
scored = Point { x = 0, y = 0, score = 99, color = "red" }   -- OK: both extras match the sig

bad : Point + { score : U64 }
bad = Point { x = 0, y = 0, score = 99, color = "red" }    -- COMPILE ERROR: color not in the expected extension

-- Spread extends the row from an existing value:
moved : Point
moved = Point { ..origin, x = 99 }                     -- type: Point  (x is in Point's declared fields)

labeled : Point + { score : U64, color : String }       -- sig REQUIRED: extras need an expected type
labeled = Point { ..named, color = "red" }              -- OK: sig accommodates color
```

**Strict inference.** Without an expected type, construction is strict — `labeled = Point { ..named, color = "red" }` with no sig is a compile error because `color` is neither declared in `Point` nor present in any expected extension. Row growth from a literal's extras requires the sig to advertise the extra fields. This matches the strict-by-default ethos throughout the spec.

**Construction rule (precise):** given a constructor literal `T { fields... }` and an expected type `T'`:
1. `T` must equal `T'` (or be the nominal tag of `T'` — for extended types `T' = T + ext`). Tag mismatch errors.
2. Every field declared in `T`'s constructor must appear in `fields...`. Missing fields error.
3. Every field in `fields...` must be EITHER:
   - declared in `T`'s constructor, OR
   - declared in `ext` (if the expected type is `T + ext`).
   - Otherwise: compile error.
4. The resulting value has type `T'` (whatever the expected type was; this may be `T` itself, or `T + ext`).

**For spread `Point { ..p, fields... }`:** the spread source `p`'s type determines the starting row. The trailing field list adds (or scoped-overrides) fields. Type-checking follows the same bidirectional rule, with `p`'s contributing fields counted as "already present."

### Field access

```wok
p.x                                 -- type: U64 (if p : Point — base field declared in Point)
p.score                             -- type: U64 (if p : Point + { score : U64 } — known extension)
p.x.y                               -- chained (if p has a record-valued field)
```

**Access rule:** `p.field` typechecks iff `field` is a label statically known to be in `p`'s row.

Field access and caller-side compatibility are two distinct axes. The table below separates them:

| Type of `p` | Fields you can read inside | Values callers may pass |
|---|---|---|
| `Point` (closed) | `x`, `y` | only closed `Point` — extensions rejected |
| `Point + { score : U64 }` (concrete extension) | `x`, `y`, `score` | exactly `Point + { score : U64 }` |
| `Point + row r` (row-polymorphic) | `x`, `y` | `Point` OR `Point + anything` — `r` is bound by the caller |
| `Point + { score : U64 } + row r` | `x`, `y`, `score` | any value with at least `x`, `y`, `score` |

Closed `Point` and row-polymorphic `Point + row r` are identical in the middle column — that's the point of the second column. The `r` doesn't grant the function any new access; it changes what the function accepts at its boundary.

#### Row parametricity

When a signature introduces a row variable `r`, the body cannot:

- **read through `r`** — `.somefield` errors with `UnknownField` unless `somefield` is in a statically known part of the row;
- **inspect or pattern-branch on `r`'s contents** — `r` is opaque, not enumerable;
- **remove a field from `r`** — the function does not know what is in `r`.

The body CAN add a field by widening the result row, as long as the signature advertises the addition. The function then constructs a value with the new field laid on top of whatever `r` contains; if a caller's instantiation of `r` happens to introduce a label that collides with the added field, scoped labels resolve the overlap at the type level (see §"Scoped labels at the type level" below).

Because `r` is bound by the caller and the body must behave uniformly for every possible `r`, the caller's extras flow through untouched. Any operation that would depend on `r`'s shape is rejected at the type level.

To work with a field that might be present, commit to it in the signature:

```wok
g1 : Point + row r -> Point + row r + { tag : String }   -- promises to add `tag`; r threads through
g1 p = Point { ..p, tag = "ok" }

g2 : Point + { score : U64 } + row r -> U64              -- promises the caller supplies `score`
g2 p = p.score
```

Reuses existing `EProj` grammar. The typechecker performs the row-lookup at unification time, applying `rewriteRow` from the Leijen algorithm.

### Pattern matching

```wok
case point of
  Point { x = 0, y = 0 } -> "origin"                    -- closed pattern: matches only base Point (no extensions)
  Point { x = a, y = b } -> show a ++ "," ++ show b     -- closed: bind both fields
  _                      -> "unknown"

case event of
  Event { kind = "click", .. } -> handleClick           -- open: bind kind, discard any extension fields
  Event { kind = "key",   .. } -> handleKey
```

**Pattern rules:**

1. **Strict by default.** A constructor pattern `T { fields... }` (no trailing `..`) matches ONLY values whose type is exactly `T` (no extension row). A value of type `Point + { score : U64 }` does NOT match `Point { x = a, y = b }`; the pattern arm is skipped.

2. **Open with `..` (anonymous wildcard).** `T { fields..., .. }` matches values of type `T` OR `T + extension` (any extension). The `..` discards the extension fields — they're not bound to anything.

3. **Named row-tail capture `..rest` is NOT supported in v1.** Capturing the extension row as a binder would require giving `rest` an anonymous-record type, which the design forbids. Deferred to v2 when an explicit "extension view" type is designed.

4. **Coverage check.** The pattern-coverage analyzer treats `Point { ... }` (strict) and `Point + { score : U64 }` as distinct types for exhaustiveness. A function `f : Point + row r -> ()` whose match has only strict `Point { ... }` arms is reported as **non-exhaustive** — when a caller instantiates `r` to a non-empty row, the strict arms fail to match. The strict arms themselves are NOT marked unreachable, because when a caller passes a closed `Point` (`r := RowEmpty`), the strict arms do match. Only the "non-exhaustive" diagnostic fires.

**To preserve extras through a transformation, use spread on the value (not pattern destructuring):**

```wok
addOne : Point + row r -> Point + row r
addOne p = Point { ..p, x = p.x + 1 }       -- spread p preserves the row tail; field access works on declared fields
```

This is the row-polymorphism use case — and it works in v1 without named row-tail capture in patterns.

### Update semantics — scoped labels canonicalized at construction

A spread + same-label override like `Point { ..p, x = 99 }` semantically pushes a new layer per Leijen scoped-label theory, but Wok canonicalizes at construction time so types never show duplicates.

**Canonicalization rule:** during type-checking of a constructor literal `T { ..p, fields... }`, if a `field = value` overrides an existing label in the row (whether from `p` or from earlier fields in the literal) AND the new value's type unifies with the existing label's type, the resulting type contains a SINGLE entry for that label (the new value's contribution replaces the old at the type level). If types DON'T unify, it's a compile error.

```wok
p = Point { x = 1, y = 2 }                              -- type: Point  (closed)
moved = Point { ..p, x = 99 }                           -- type: Point  (canonicalized; x's type didn't change)
broken = Point { ..p, x = "hi" }                        -- COMPILE ERROR: x's existing type is U64; new value is String
```

**Why this is sound:** records are immutable, and projection is the only observation on a record value. Therefore the layered form `{ ..p, x = v }` and the flattened form `{ x = v, ..other_fields }` are observationally indistinguishable — every projection returns the same value in both. Canonicalizing at construction preserves the soundness theorems of Leijen 2005, which are stated over an observational equivalence Wok's stricter (no-mutation, no-subtyping) language inherits.

**Internal representation:** the typechecker stores the canonical (deduplicated) form. There is no internal "scoped label stack" hidden underneath when construction is fully concrete — the layering exists only in the Leijen theory and is canonicalized away. This is a refinement of Leijen 2005 enabled by the immutability constraint.

If the user actively WANTS multiple layers (e.g., for some advanced overriding pattern), they cannot get it from concrete `+` extension or spread+override — both canonicalize. They'd need an explicit "stack of values" data structure, which is out of scope.

#### Scoped labels at the type level (via row-variable instantiation)

Canonicalization fires at concrete construction — when the row is fully known to the typechecker. When a construction involves a spread from a row-polymorphic value (`Point { ..p, tag = "ok" }` where `p : Point + row r`), the typechecker has no way to know whether `r` already contains `tag`. It treats the added field as fresh; the result type is `Point + row r + { tag : String }`.

At a call site, when `r` is instantiated to a concrete row, **substitution may introduce duplicate labels** in the resulting type. Duplicate labels at the type level are NOT canonicalized — they persist as scoped labels per Leijen 2005. Projection on a row with multiple same-name entries selects the **outermost** entry.

**Worked example:**

```wok
g1 : Point + row r -> Point + row r + { tag : String }
g1 p = Point { ..p, tag = "ok" }

-- Call site 1 — no collision:
clean   : Point + { color : String }
result1 = g1 clean   -- result1 : Point + { color : String } + { tag : String }
                     -- result1.color : String, result1.tag : String. Fine.

-- Call site 2 — collision:
weird   : Point + { tag : Int }
result2 = g1 weird   -- result2 : Point + { tag : Int } + { tag : String }
                     -- two `tag` entries in the row; outer is String, inner is Int.
                     -- result2.tag : String (outermost wins).
                     -- The inner `tag : Int` is shadowed; v1 has no syntax to access it.
```

This is sound because of row parametricity: `g1`'s body cannot read `p.tag` (only fields explicitly in the signature are accessible), and its `tag = "ok"` is a write of the new outer layer. The function's behavior is uniform across every instantiation of `r`. Callers who want to avoid the shadow should not call `g1` on a record that already contains `tag` — the type makes the shadow visible.

**Compiler warning on shadow.** When row-variable instantiation introduces a label collision, the compiler emits a warning at the call site:

```
warning: row-variable instantiation introduced a shadow
  caller's type: Point + { tag : Int }
  function adds: + { tag : String }
  result type:   Point + { tag : Int } + { tag : String }

  the inner `tag : Int` is shadowed; `.tag` on the result returns the String.
```

The warning is informational; the program compiles. There is no escape-hatch syntax to silence it in v1. (If shadow-introducing call sites become a common idiom that the warning over-fires on, v2 can add `Lacks`-style constraints or a directive — see §"Non-goals".)

### Multi-constructor records

```wok
data Shape 
  = Circle { radius : U64 }
  | Square { side : U64 }
  | Rect   { width : U64, height : U64 }
```

Each constructor has its own field list. Construction and patterns are scoped to the specific constructor:

```wok
unitCircle = Circle { radius = 1 }
unitSquare = Square { side = 1 }

area : Shape -> U64
area s = case s of
  Circle { radius = r } -> 3 * r * r          -- approx
  Square { side = s }   -> s * s
  Rect { width = w, height = h } -> w * h
```

**Constraint:** every field name declared across the constructors of a single `data` decl must be unique. `data X = A { x : U64 } | B { x : String }` is rejected in v1 because `.x` would be ambiguous on a bare `X` value.

(Future enhancement: allow same-name fields with type-directed disambiguation similar to OCaml records. v2 work.)

## Grammar additions

```bnfc
-- Extend ConDef to support record-style constructor fields:
ConDef.         ConDef ::= ConId [Type2] ;                          -- existing positional
ConDefRec.      ConDef ::= ConId "{" [RecordFieldType] "}" ;        -- record form, explicit name
ConDefRecElide. ConDef ::= "{" [RecordFieldType] "}" ;              -- record form, name elided
                                                                    -- (elaborator: valid only in single-con decls;
                                                                    --  constructor tag defaults to data-type name)

RFType.        RecordFieldType ::= VarId ":" Type ;
separator      RecordFieldType "," ;

-- Type-level `+` extension (left-assoc, tighter than `->`).
-- Lexer keeps `+` as a generic VarSym; this production consumes any VarSym at
-- the type level and the elaborator restricts to literal "+".
TExtend.       Type1 ::= Type1 VarSym RowContrib ;

-- RowContrib is the right operand of `+`. Either a concrete row literal OR a
-- row variable marked by the `row` keyword. Anonymous record types appear
-- ONLY here (NOT in `Type2`), so a bare `{ ... }` is rejected at parse time
-- in any other type position.
RCAnon.        RowContrib ::= "{" [RecordFieldType] "}" ;           -- concrete extension
RCVar.         RowContrib ::= "row" VarId ;                         -- row variable

-- Value-level record construction:
ERecord.       Exp2 ::= ConId "{" [RecordFieldExpr] "}" ;
ERecordExt.    Exp2 ::= ConId "{" ".." Exp [TrailingFields] "}" ;   -- G3 fix: trailing fields optional

TFEmpty.       TrailingFields ::= ;
TFList.        TrailingFields ::= "," [RecordFieldExpr] ;

RFExpr.        RecordFieldExpr ::= VarId "=" Exp ;
separator      RecordFieldExpr "," ;

-- Pattern matching:
PRecord.       AtomPat ::= ConId "{" [RecordFieldPat] "}" ;
PRecordOpen.   AtomPat ::= ConId "{" [RecordFieldPat] "," PatRowTail "}" ;
PRecordWild.   AtomPat ::= ConId "{" PatRowTail "}" ;               -- e.g. T { .. } or T { ..rest }

RFPat.         RecordFieldPat ::= VarId "=" Pat ;
separator      RecordFieldPat "," ;

-- PRTNamed parses, but the elaborator rejects it in v1 with a targeted error
-- ("named row-tail capture deferred to v2; use `..` to discard"). Keeping it
-- in the grammar gives a better error message than a raw parse failure.
PRTNamed.      PatRowTail ::= ".." VarId ;
PRTAnon.       PatRowTail ::= ".." ;
```

LALR(1) safety: the `{` after a `ConId` is unambiguous lookahead. The existing tuple/list/sum-constructor productions don't start with `ConId "{"`, so the new productions slot in cleanly. The name-elided `ConDefRecElide` (which starts with `{` directly after `=`) is also unambiguous because no other `ConDef` alternative begins with `{`.

`row` becomes a new keyword token. It is reserved globally to keep the lexer simple, even though it only appears in type positions; the cost is users cannot name variables `row`.

`..` becomes a new keyword token. (See "Lexer additions" below.)

### Layout for record-field lists

Record-field lists may be written inline (comma-separated) or as an indent-delimited block. The BNFC grammar above uses `separator RecordFieldType "," ;` (and analogous for `RecordFieldExpr` and `RecordFieldPat`). The block form is handled by the **layout filter pre-pass** rather than at the parser level:

- When `{` is followed by a newline, the filter opens a brace-layout context.
- Lines indented past the `{` are field items; newlines act as virtual commas.
- `}` (dedented) closes the context.
- Nested record literals push and pop their own contexts, so a brace-context stack is required.
- An inline form (everything on one line, comma-separated) bypasses the filter entirely — the parser sees the explicit commas.

The rule applies uniformly across all four record-syntactic contexts (decl, type-extension RHS, value construction, pattern). The existing layout filter (with its recent paren-leading top-level decl fix at commits `0556ee3` and `351b38b`) needs the brace-context-stack extension; this is new layout-filter work for v1.

## Type-system additions

### New constructors in `Wok.TypeChecking.Types`

Add a NOMINAL-TAGGED record carrier to both the mutable inference type and the closed CType:

```haskell
data Type s
  = TCon TyCon [Type s]
  | TArr (Type s) (Row s) (Type s)
  | TRecord Text (Row s)        -- NEW: tag + row.  Text is the nominal name (e.g. "Point")
  | TVar (STRef s (TVar s))

data CType
  = CTCon TyCon [CType]
  | CTArr CType CRow CType
  | CTRecord Text CRow          -- NEW: tag + row, closed form
  | CTGen Int
```

The `Row`/`RVar` representations are unchanged. The `Text` tag is the nominal identity.

**Key property:** unification of records is `TRecord tag1 row1 ~ TRecord tag2 row2` iff `tag1 == tag2` AND `row1 ~ row2`. Different tags → unification fails, regardless of row shape. This gives nominal identity even when two record types share the same field-shape.

### `+` is sugar over row extension

There is no separate "extension type." `Point + { score : U64 }` translates to `TRecord "Point" (row with Point's declared fields ++ score field)`. The tag stays `"Point"` (extension never changes nominal identity); the row grows.

For a row variable: `Point + row r` translates to `TRecord "Point" (row with Point's declared fields ++ RowVar r)`. The row variable lives in the tail.

Multiple extensions: `Point + { score : U64 } + { color : String }` accumulates into one row: `TRecord "Point" (row with x, y, score, color)`.

Multiple extensions with a row variable: `Point + row r + { tag : String }` produces `TRecord "Point" (row with x, y, RowVar r, tag : String)`. After instantiation of `r`, scoped labels may arise if `r` overlaps with existing labels (see §"Scoped labels at the type level").

### Anonymous record types on RHS of `+`

The grammar restricts anonymous record syntax to the `RowContrib` non-terminal, which only appears as the right operand of `TExtend`. A bare `{ x : U64, y : U64 }` is therefore a **parse error** in any other type position (function-arg, return, let-binding, etc.) — the parser never reaches a production that would accept it.

At the AST level, an anonymous-record `RowContrib` produces a `RowExtend ... RowEmpty` chain (a closed row of the listed labels). A `row r` `RowContrib` produces a `RowVar r`. The typechecker merges either form with the LHS's row — neither becomes a standalone `TRecord` value.

### TyCon registration

A `data Foo = Foo { fields... }` decl registers:
- A `TyConInfo` for `"Foo"` with arity matching its type parameters and the field list as metadata.
- A **record-only constructor descriptor** for `"Foo"` storing the declared field types and the result type `CTRecord "Foo" (CRow of declared fields)`. **No curried-function `conScheme` is generated.** The constructor name is NOT a value; lookup of `"Foo"` in the value namespace returns `RecordConstructorNotAValue` (a domain-specific error).
- When `Foo` is referenced in a type position, the resolver produces `CTRecord "Foo" (row of declared fields)` (closed). `Foo + ext` produces `CTRecord "Foo" (row with declared fields ++ ext's row)`.

Positional constructors (e.g., `Just a` in `data Maybe a = Nothing | Just a`) continue to register a curried `conScheme` and behave as first-class functions — the asymmetry is intentional and reflects the surface-form distinction.

For multi-constructor decls with both positional and record alternatives (e.g., `data Result a e = Ok a | Err { message : String, code : U64 }`), each constructor is registered according to its form: `Ok` gets a curried scheme, `Err` gets a record-only descriptor.

For nominal identity: `data UserId = UserId { value : U64 }` and `data OrderId = OrderId { value : U64 }` produce `CTRecord "UserId" ...` and `CTRecord "OrderId" ...` respectively. These never unify (different tags) regardless of row shape.

This is a clean refinement of Leijen 2005: rows carry shapes, the nominal tag is separate and load-bearing for identity.

### `unifyRow` — replace stub with Leijen 2005 algorithm

The current `unifyRow` handles only `RowEmpty ~ RowEmpty`. Replace with the full scoped-label algorithm (see "Implementation: unifyRow algorithm" below).

The `unify` function for records itself adds a tag-check:

```haskell
unify pos (TRecord tag1 row1) (TRecord tag2 row2) = do
  unless (tag1 == tag2) $
    throwError (NominalMismatch pos tag1 tag2)
  unifyRow pos row1 row2
```

This is the entry point for record unification. The row-level unification proceeds per Leijen.

### Construction is bidirectional-checked

The typechecker uses the expected type when checking constructor literals (per "Construction rule" in the model section above).

**In inference mode (no expected type):**
- Literal `T { fields... }` produces `CTRecord "T" (closed row of declared fields)`.
- Extras error.

**In checking mode (expected type `CTRecord "T" row`):**
- Literal `T { fields... }` is checked against the expected row.
- Each declared field of `T` must appear.
- Each non-base field in the literal must appear in the expected row's extension portion.
- The resulting value has the expected type.

Implementation: extend `inferExprW`'s `ERecord` and `ERecordExt` cases to take an optional expected type, threading it from let-bindings, lambda bodies, and function-argument positions.

## Strict vs row-polymorphic — guidance

The strict-by-default rule (`Point` accepts only closed `Point`) has a real consequence: every function that should be tolerant of extensions needs `+ row r` in its sig.

**Rule of thumb:**

- **If your function CONSUMES the record fully** (e.g., serializes, hashes, sends over a wire), use bare `Point`. The function doesn't need extras — it discards them or has no use for them. A caller passing an extended `Point + { score : U64 }` is forced to strip the extension first (e.g., via re-construction), which is the right behavior because the function won't preserve those fields.

- **If your function TRANSFORMS or PASSES THROUGH the record** (e.g., updates a field, decorates, threads it through a pipeline), use `Point + row r`. The row variable carries extras through.

- **If your function adds a SPECIFIC field**, use `Point + row r -> Point + row r + { newField : T }`. The result type explicitly adds the new field while preserving incoming extras. Callers whose row already contains `newField` get a shadow warning at the call site (see §"Scoped labels at the type level").

Examples:

```wok
-- CONSUMES — bare sig, no row tolerance:
serialize : Point -> String                            -- extensions would be discarded; reject them upfront

-- TRANSFORMS — preserves the row:
flipXY : Point + row r -> Point + row r
flipXY p = Point { ..p, x = p.y, y = p.x }

-- ADDS — explicit growth in the output row:
withScore : Point + row r -> U64 -> Point + row r + { score : U64 }
withScore p s = Point { ..p, score = s }
```

This is more verbose than a permissive design where bare types were row-polymorphic by default, but it makes the choice explicit at every function boundary. Tradeoff already accepted in earlier design discussion.

## Implementation: unifyRow algorithm

Leijen 2005 scoped-label unification. Replace the stub in `Wok.TypeChecking.Unify`:

```haskell
unifyRow :: BNFC'Position -> Row s -> Row s -> TC s ()
unifyRow pos r1 r2 = do
  r1' <- forceRow r1
  r2' <- forceRow r2
  case (r1', r2') of
    (RowEmpty, RowEmpty) -> pure ()

    (RowVar v1, RowVar v2)
      | v1 == v2  -> pure ()
      | otherwise -> bindRowVar pos v1 r2'

    (RowVar v, row) -> bindRowVar pos v row
    (row, RowVar v) -> bindRowVar pos v row

    (RowExtend l1 t1 rest1, row2) -> do
      (t2, rest2') <- rewriteRow pos l1 row2
      unify pos t1 t2
      unifyRow pos rest1 rest2'

    _ -> throwError (RowMismatch (toSpan pos) (freezeRowFast r1') (freezeRowFast r2'))

-- Bubble label `l` up to the head of `row`. May extend a row variable.
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
      tFresh    <- freshTVar KStar
      restFresh <- freshRowVar
      bindRowVar pos v (RowExtend l tFresh restFresh)
      pure (tFresh, restFresh)
    RowEmpty -> throwError (RowMismatch (toSpan pos) ...)
```

Plus an occurs-check for row variables (in `bindRowVar`) — prevents `r := { x : r }`-style infinite types.

`forceRow` and `freezeRow` already exist; verify they handle `RowExtend` cases (they do per the pre-wired HM core).

## Inference rules

### Record-decl processing

In `processDataDecls`:
```haskell
processDataDecl env (Abs.DData typeName params constructors) = do
  -- For ConDefRecElide (name-elided form): valid only when constructors is a
  -- single-element list; the elided constructor's tag is set to typeName.
  -- Multi-constructor decls with any elided form are rejected here.
  let normalizedConstructors = normalizeElision typeName constructors

  for each con in normalizedConstructors:
    case con of
      Abs.ConDef conName positionalArgs ->
        -- Existing positional path: build curried arrow scheme (first-class function).
        let conScheme = Scheme params (buildArrows positionalArgs (CTCon typeName paramTypes))
        registerCon conName (PositionalCon { conScheme, ... })

      Abs.ConDefRec conName fields ->
        -- Record-form constructor:
        let crow = buildCRow fields paramMap
            retT = CTRecord typeName crow            -- nominal-tagged record type
        -- NO curried arrow scheme. Register as a record-only descriptor.
        -- Variable-position lookup of conName returns RecordConstructorNotAValue.
        registerCon conName (RecordCon { fields, retT, params })

  -- Register the TyCon `typeName` with arity len(params); store all field metadata.
  registerTyCon typeName (TyConInfo { arity = length params, ... })
```

Reject if multiple constructors of the same data decl share a field name (per the multi-constructor uniqueness rule).

Reject `ConDefRecElide` in any decl with more than one constructor — name elision is valid only for single-constructor record decls.

### Construction inference (`ERecord`, `ERecordExt`)

`ERecord` and `ERecordExt` dispatch directly on the AST shape (the `ConId` is a syntactic tag, not a value lookup):

```haskell
inferExprWChecked :: Map Text (Type s) -> Maybe (Type s) -> Abs.Exp -> TC s (Type s)
inferExprWChecked mono expected (Abs.ERecord (Abs.ConId (pos, conName)) fields) = do
  -- Look up the record-constructor descriptor (NOT a value-namespace lookup).
  conInfo <- lookupRecordCon pos conName   -- errors if conName isn't a record constructor
  -- Determine the row of allowed fields: declared fields, plus extension fields if `expected` is T+ext.
  let declared = declaredFieldsOf conInfo
      allowedExtras = case expected of
        Just (TRecord t row) | t == conInfo.tag -> extractExtensionFields row
        _                                       -> []
      allowedSet = Set.fromList (declared ++ allowedExtras)

  -- Check each provided field is in the allowed set; error otherwise.
  -- Check each declared field is provided.
  -- Type-check each field's value against its expected field type.

  -- Build the result row, using the expected type's row if provided (preserves layout & row var):
  let resultRow = case expected of
        Just (TRecord _ row) -> row
        _                    -> closedRowOfDeclared declared
  pure (TRecord conInfo.tag resultRow)
```

Similar logic for `ERecordExt` (spread + extra fields). The spread expression `..p` is inferred normally; its type must be `TRecord conInfo.tag _` (same nominal tag). The spread's row contributes to the "already-present" field set; trailing fields are checked against the allowed set.

**Variable-position lookup of a record constructor name fails:**

```haskell
inferExprW mono (Abs.EVar (Abs.VarId (pos, name))) = do
  case lookupValue name of
    Just scheme -> ...                                       -- ordinary value
    Nothing -> case lookupRecordCon' name of
      Just _  -> throwError (RecordConstructorNotAValue pos name)
      Nothing -> throwError (NameNotInScope pos name)
```

This implements the "record constructors are not first-class functions" rule with a targeted error message.

### Field access (`EProj`)

```haskell
inferExprW mono (Abs.EProj e (Abs.VarId (pos, label))) = do
  eT <- inferExprW mono e
  eT' <- force eT
  case eT' of
    TRecord _ row -> do
      -- Bubble `label` up to the head of row using rewriteRow.
      -- If row is bare RowEmpty or a RowVar without label, error.
      (fieldT, _rest) <- rewriteRow pos label row
      pure fieldT
    _ -> throwError (NotARecord pos eT')
```

`rewriteRow` on a `RowVar` would normally allocate a fresh row tail and extend the variable — but for field access, this would silently succeed when the row variable doesn't actually contain the label. **For field access specifically**, we want a stricter behavior: refuse to extend row variables.

Implementation: provide `rewriteRowStrict` that fails on `RowVar` (rather than extending it). Used by `EProj`. Regular `rewriteRow` (extending) is used by `unifyRow` (where extension is appropriate).

### Pattern matching (`PRecord`, `PRecordWild`)

```haskell
inferAtomPat (Abs.PRecord (Abs.ConId (pos, conName)) fields) = do
  conInfo <- lookupRecordCon pos conName
  -- Strict pattern: result type is closed TRecord (no row variable in the tail)
  let row = buildClosedRow fields (declaredFieldsOf conInfo)
      patT = TRecord conInfo.tag row
  -- For each pattern field, recursively check
  binds <- forEachField ...
  pure (patT, binds)

inferAtomPat (Abs.PRecordWild (Abs.ConId (pos, conName)) Abs.PRTAnon) = do
  conInfo <- lookupRecordCon pos conName
  -- Open pattern: result type has a fresh row variable in the tail
  freshRow <- freshRowVar
  let row = buildOpenRow fields (declaredFieldsOf conInfo) freshRow
      patT = TRecord conInfo.tag row
  binds <- forEachField ...
  pure (patT, binds)

inferAtomPat (Abs.PRecordWild (Abs.ConId (pos, _)) (Abs.PRTNamed _ binder)) =
  -- PRTNamed parses successfully, but the elaborator rejects it for v1.
  throwError (NamedRowTailCaptureDeferred pos binder)
```

The strict form produces a CLOSED row; the open form produces a row with a fresh row variable at the tail (which the value's type can unify with anything).

Named row-tail capture (`..rest`) is parsed but rejected by the elaborator in v1 with a `NamedRowTailCaptureDeferred` error — the production stays in the grammar so the error message can target the user's intent precisely instead of surfacing as a generic parse failure.

### Bidirectional context propagation

The typechecker threads expected types through:
- Sigs: `name : T` gives `T` as the expected type when checking the body.
- Function arguments: when calling `f : A -> B`, the argument expression is checked against `A`.
- Let bindings with sigs: `let x : T = ...` checks the RHS against `T`.
- Lambda bodies: `\(x : T) -> body` doesn't propagate to the body's return; that's pure inference unless wrapped in a sig.

This is a modest extension of the HM core's existing inference; the records spec just uses it more actively.

## Test plan

Unit tests (in `test/Spec.hs`):

| Test | Asserts |
| --- | --- |
| `parseRecordDataDecl` | `data Point = Point { x : U64, y : U64 }` parses and round-trips |
| `parseRecordValue` | `Point { x = 1, y = 2 }` parses; spread form `Point { ..p, x = 1 }` parses; spread-only `Point { ..p }` parses (G3) |
| `parseRecordPattern` | Closed `Point { x = a, y = b }` and open `Point { x = a, .. }` parse |
| `parseRecordTypeExtension` | `Point + { score : U64 }` and `Point + row r` parse |
| `parseBlockLayoutDecl` | Multi-line `data Point = Point {\n  x : U64\n  y : U64\n}` parses identically to inline form |
| `parseBlockLayoutValue` | Multi-line `Point {\n  x = 1\n  y = 2\n}` parses identically to inline form |
| `parseBlockLayoutPattern` | Multi-line pattern `Point {\n  x = a\n  y = b\n}` parses identically |
| `parseBlockLayoutMixed` | Mixed comma + newline (`{ x : U64, y : U64\n  z : U64 }`) parses |
| `parseBlockLayoutNested` | Nested record literal in block layout parses correctly (brace-context stack) |
| `parseElidedConstructorName` | `data Point = { x : U64, y : U64 }` parses; AST-equivalent to explicit form |
| `parseRejectsElisionMultiCon` | `data Shape = { x : U64 } \| Square { side : U64 }` rejected (elision invalid in multi-con) |
| `parseRejectsElisionPositional` | Elided form rejected for positional-style constructors |
| `parseRejectsBareRowVar` | `Point + r` (without `row` keyword) is rejected by the elaborator with a "did you mean `+ row r`?" hint |
| `parseAcceptsNamedTail` | Pattern `Point { x = a, ..rest }` parses (PRTNamed in grammar) |
| `elabRejectsNamedTail` | Elaborator rejects parsed `..rest` pattern with v1-deferral error |
| `parseRejectsAnonRecordType` | Type expression `{ x : U64, y : U64 }` standalone (not as RHS of `+`) rejected at parse (RowContrib restriction) |
| `parseTypeLevelPlus` | `Point + ...` parses; type-level `+` consumes a `VarSym`; elaborator restricts to `"+"` |
| `parseRejectsNonPlusTypeOp` | `Point - r` errors during elaboration with "only `+` is valid at type level" |
| `typecheckClosedRecord` | `p = Point { x = 1, y = 2 }` infers as `Point` |
| `typecheckRecordExtension` | `named : Point + { score : U64 }; named = Point { x = 0, y = 0, score = 99 }` checks |
| `typecheckRowPolymorphism` | `f : Point + row r -> Point + row r; f p = p` is inferred as polymorphic in r |
| `typecheckStrictConstruction` | `Point { x = 1, y = 2, z = 3 }` (without sig context) errors |
| `typecheckStrictInferenceOnSpreadExtras` | `labeled = Point { ..named, color = "red" }` (no sig) errors (S1) |
| `typecheckExtensionRejectsStrict` | A `Point + { score : U64 }` value cannot be passed to `f : Point -> ...` |
| `typecheckFieldAccess` | `p.x` on a `Point` value typechecks as `U64` |
| `typecheckFieldAccessOnExtension` | `p.score` on a `Point + { score : U64 }` value typechecks |
| `typecheckFieldAccessOnRowVar` | `p.score` on `Point + row r` errors with `UnknownField` |
| `typecheckNominalDistinct` | `UserId` value cannot be passed where `OrderId` is expected, even with same shape |
| `typecheckPatternStrict` | Pattern `Point { x = a }` does NOT match a `Point + { z : U64 }` value (pattern arm skipped) |
| `typecheckPatternOpen` | Pattern `Point { x = a, .. }` matches both `Point` and `Point + { z : U64 }` values |
| `typecheckPatternCoverage` | `f : Point + row r -> ...` with only strict pattern arms reports non-exhaustive (S4) |
| `typecheckPatternStrictNotUnreachable` | `f : Point + row r -> ...` with a strict arm: arm is reachable when `r := RowEmpty`; no unreachable diagnostic |
| `typecheckCanonicalization` | `Point { ..p, x = 99 }` (where p : Point) produces type Point (no duplicate x) |
| `typecheckCallSiteRowCollision` | `g1 : Point + row r -> Point + row r + { tag : String }` called on `Point + { tag : Int }`: result has scoped `tag`; `.tag` returns String (S2-a) |
| `typecheckCallSiteRowCollisionDifferentTypes` | Verify scoped labels can have different types; projection takes outermost |
| `warnRowCollisionShadow` | The above call site emits a row-shadow warning naming both types |
| `typecheckRecordConstructorNotValue` | `let f = Point in f` errors with `RecordConstructorNotAValue` |
| `typecheckRecordPositionalApplication` | `Point 1 2` errors with `RecordConstructorNeedsBraces` |
| `typecheckPositionalConstructorStillValue` | `map Just [1,2,3]` works — positional constructors remain first-class |
| `typecheckMixedConDecl` | `data Result a e = Ok a \| Err { message : String, code : U64 }`: `Ok` is a value, `Err` is not |
| `typecheckSpreadOnly` | `Point { ..p }` (no trailing fields) typechecks; result has p's type exactly |
| `typecheckPhantomTypeParam` | `data Phantom a = Phantom { x : U64 }`: construction without sig leaves `a` underdetermined (fresh tvar) |
| `typecheckEmptyFieldsCon` | `data Unit = Unit { }`: `Unit { }` constructs; type checks |
| `typecheckMultiConSameName` | `data X = A { x : U64 } | B { x : String }` rejected at decl time |
| `typecheckPolymorphicRecord` | `Container a = Container { value : a }`; `Container { value = 42 } : Container U64` |

Golden tests (in `test/typecheck-examples/`):
- `13-records.wok` — basic record types and construction
- `14-record-extension.wok` — `+` extension with concrete fields and row variables
- `15-record-patterns.wok` — pattern matching with strict and open forms
- `16-multi-constructor-records.wok` — `data Shape = Circle { ... } | Square { ... }`
- `17-polymorphic-records.wok` — `data Container a = Container { value : a }`
- `18-nominal-distinction.wok` — `UserId` and `OrderId` are distinct types

Fail tests (in `test/typecheck-fail-examples/`):
- `10-construction-extras.wok` — `Point { x = 1, y = 2, z = 3 }` errors
- `11-cross-nominal-pass.wok` — passing `UserId` where `OrderId` expected
- `12-pattern-strict-fail.wok` — strict pattern on extended record fails to match

## File / module changes summary

| File | Action |
| --- | --- |
| `grammar/Wok.cf` | Add `ConDefRec`, `ConDefRecElide`, `TExtend`, `RowContrib` (with `RCAnon` and `RCVar`), `ERecord`, `ERecordExt` (with optional trailing fields), pattern productions; reserve `..` and `row` as keyword tokens |
| `src/Wok/Layout.hs` | Extend the layout filter with a brace-context stack: opening `{` followed by newline opens an indent block; newlines inside emit virtual commas; matching `}` closes the context |
| `src-generated/GeneratedParser/Wok/*` | Regenerate via BNFC |
| `src/Wok/TypeChecking/Types.hs` | Add `TRecord` + `CTRecord` constructors; add `RecordCon` descriptor (no curried scheme); add `RecordConstructorNotAValue` error |
| `src/Wok/TypeChecking/Unify.hs` | Replace `unifyRow` stub with full Leijen algorithm; add `rewriteRow` (extending) and `rewriteRowStrict` (non-extending, for field access); update `force`/`freeze` walkers for the new constructors |
| `src/Wok/TypeChecking/Elaborate.hs` | Elaborator restrictions: reject non-`+` VarSym at type level; reject `RCVar` outside row positions; reject `PRTNamed` patterns (v1 deferral); reject `ConDefRecElide` in multi-con decls; reject bare row-var-shaped names without `row` prefix |
| `src/Wok/TypeChecking/Infer.hs` | Add cases in `inferExprW` (ERecord, ERecordExt — both record-only-lookup), `inferAtomPat` (PRecord, PRecordOpen, PRecordWild), `processDataDecls` (ConDefRec, ConDefRecElide normalization); extend `translateSig`'s walkers; bidirectional check support; emit row-shadow warning on collision at substitution time |
| `prelude/Std/Base.wok` | No required changes; records are user-facing |
| `test/typecheck-examples/` | New fixtures per test plan |
| `test/typecheck-fail-examples/` | New fail fixtures |
| `test/Spec.hs` | Add record unit tests and unify-row unit tests |
| `examples/records-tour.wok` | New example file demonstrating the syntax |

## Lexer additions

`..` becomes a literal token, distinct from `.` (used for module paths and field projection). Define in `Wok.cf` as a literal; BNFC's longest-match handles it.

`row` becomes a reserved keyword. It is only meaningful at the type level (as the marker before a row-variable name in `RowContrib`), but is reserved globally to keep the lexer simple. Users cannot name variables `row`.

`+` is currently part of the `VarSym` token category and is used as a generic infix operator in expressions (`x + y` is `EExpr` with `IOSym ::= VarSym`). The new type-level extension production `TExtend. Type1 ::= Type1 VarSym RowContrib` consumes a `VarSym` at the type level rather than promoting `+` to a structural literal — this avoids breaking any existing `VarSym`-routed expression syntax. The elaborator inspects the consumed `VarSym` and rejects any value other than `"+"` with a targeted error message.

Layout filter changes for the brace-context stack are described in §"Layout for record-field lists" above. The same filter handles record literals in value, type-extension, decl, and pattern positions uniformly.

## Migration

This is purely additive — no existing valid Wok program changes meaning.

- Current Wok grammar has no `{ ... }` productions at the value/type/pattern level.
- The `data` decl currently uses positional constructors only; the new `ConDefRec` and `ConDefRecElide` forms are additive.
- `data` keyword is reused; no syntactic conflict.
- `+` continues to be parsed via `VarSym` at both expression and type levels; no global lexer change.
- `..` and `row` are new tokens; neither exists in current Wok code.
- Layout-filter extension to handle brace-context is additive — code that doesn't use record `{ ... }` syntax is unaffected.

No fixture migration needed for backwards compatibility.

## Inheritance from Leijen 2005

Soundness (Progress + Preservation) inherits from Leijen 2005 because:
- Wok has no subtyping (no covariance/contravariance interactions with rows).
- Records are immutable (no aliasing-plus-mutation soundness loss).
- HM is rank-1 (no quantifier-position issues).
- Scoped labels prevent Wand-style ambiguity at the type level — when row-variable instantiation introduces label collisions, the resulting scoped labels are sound and projection is deterministic (outermost wins).
- Construction-time canonicalization (Wok's refinement) is observationally equivalent to the layered form because records are immutable and projection-only.

See `docs/koka.md` Paper 1 review for the detailed soundness argument.

## Open hooks for future specs

This spec preserves several named extension points. The v2 row-completion items are explicitly committed (not speculative); the others are exploratory.

**Committed for v2 (records-side row completion):**

1. **`Lacks` row constraints** — `forall r. Lacks "tag" r => Point + row r -> Point + row r + { tag : T }`. Replaces the v1 runtime warning with a compile-time guarantee that no shadow can occur. Adds constraint-solving to the inference pipeline. The v1 warning is a deliberate interim measure; this is the intended endgame.
2. **Row-tail removal operator** — a syntax for popping the outermost scoped label so the inner shadowed label becomes accessible. Pairs with `Lacks`: `Lacks` prevents shadows preemptively; remove handles them after the fact. Together they give Wok the full Leijen-style row toolkit on the records side.
3. **Named row-tail pattern capture** — `Point { x = a, ..rest }` binding `rest` to an extension-row type. Requires designing the "extension view" type that lets `rest` be addressable as a value with row-typed shape.

**Other open hooks (separate specs):**

4. **Polymorphic variants** — `[ Red | Green | ..vs ]` syntax, dual to records. Same row machinery on the sum-type side.
5. **Algebraic effects** (`2026-05-27-effects-spec.md`) — effects use the same `Row` representation on the function-arrow effect-row slot. The `with` keyword is reserved for the effect surface syntax.
6. **Type classes with associated types** (`2026-05-27-typeclasses-spec.md`) — orthogonal to records but composes naturally; e.g., `class Container c = { type Element c, ... }`.
