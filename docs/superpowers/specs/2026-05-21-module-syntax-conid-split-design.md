# Wok v2 — Module Syntax & ConId/VarId Split — Design Spec

**Date:** 2026-05-21
**Status:** Drafted, awaiting review
**Project:** `wok` (the Haskell-cabal project at `/Users/zy/wokml`)
**Supersedes (partially):** the v2-deferred items in `2026-05-20-bnfc-wok-grammar-design.md:426-441`

## Purpose

The v1 grammar deferred two things this spec now designs (see the v1 spec's
"Deferred to v2+" list):

- the **ConId/VarId lexical split** (uppercase-vs-lowercase distinction), and
- the **module system** (`module`, imports, exports).

This is a **surface-syntax** increment: it adds grammar, tokens, and AST nodes.
It deliberately does **not** implement the semantic passes those nodes feed
(name resolution, visibility enforcement, type-directed field resolution).
Those remain future work, but the AST shape here is justified against them.

## Scope

**In scope**

- ConId/VarId lexer split; `.` removed from the operator alphabet.
- Module header (`module XXX.YYY`), `import`, `use`, and the `local` private marker.
- The `x.y` projection expression (uniform: module-access OR record-field).
- Qualified type constructors and qualified constructor patterns.
- A reserved-word bucket for future-feature keywords.

**Out of scope (deferred, separate work)**

- **Record declaration / literal / update syntax.** The `x.y` *projection* is
  designed here; how records are *declared* is a separate later pass.
- Name resolution, `import`/`use` semantics, `local` visibility *enforcement* —
  all renamer work.
- Module-access vs record-field *disambiguation* — renamer + type checker.
- `as` / `hiding` / `qualified` import refinements; submodules; parametric
  modules / module types (ML/Futhark style).
- The Tier-C reserved features themselves (type aliases, classes, etc.).
- Float literals (still deferred, see v1 spec).

## Background — the two warts this addresses

The v1 grammar uses one identifier class `VarId` for variables, type variables,
type constructors, data constructors, and (eventually) module names. Two
documented warts follow from that (`README.md:70-78`):

1. A nullary constructor (`Nothing`) and a variable binder (`x`) both reach the
   AST as `PAtom (APVar ...)`; a semantic pass must reclassify by first-letter
   case against the data environment.
2. `TVar VarId` conflates type variables and type constructors.

Splitting the identifier token by case fixes **both of those specific
disambiguation problems** — they become lexical facts, no semantic
reclassification needed. It does **not** remove the `PApp`-takes-1+-args
shaping or the `PAtom` wrapper; those are standard LALR pattern-grammar
structure (see Section A, Patterns).

---

## Section A — ConId/VarId lexical split

### Token definitions

`grammar/Wok.cf:195-202` currently has one `VarId` and a `VarSym` that includes
`.`. The new definitions:

```bnfc
position token WokInt  ('-')? digit+ ;
position token ConId   upper          (letter | digit | '_' | '\'' | '-')* ;
position token VarId   (lower | '_')  (letter | digit | '_' | '\'' | '-')* ;
position token VarSym  ('!' | '#' | '$' | '%' | '&' | '*' | '+' | '/' |
                        '<' | '=' | '>' | '?' | '@' | '\\' | '^' | '|' |
                        '-' | '~')+ ;
```

- `ConId` — uppercase-initial: data constructors, type constructors, module-name
  segments.
- `VarId` — lowercase- or `_`-initial: variables, type variables, function
  names, projection selectors.
- `VarSym` — **`.` removed** from the alphabet. `.` becomes a reserved
  punctuation token (it appears as the `"."` literal in productions below, so
  BNFC reserves it automatically). Consequence: `.` can no longer be a
  user-declared operator; function composition must be spelled otherwise
  (`>>`, `<<`, or an alphabetic name).
- First characters of `ConId` and `VarId` are disjoint, so the lexer has zero
  ambiguity between them.
- **Wildcard unchanged.** Bare `_` (length 1) is already in the lexer's
  reserved set (`Lex.x:184`), so it lexes as the `_` token, not `VarId`.
  `_x` and longer remain `VarId`. No change needed.

### Why the lexer, not a later pass

In Wok, case is *mandatory syntax* (uppercase = constructor), not a convention.
That makes "is this a constructor?" a purely lexical fact, exactly as in
Haskell and OCaml — those compilers decide it in the lexer (`conid`/`varid`,
`UIDENT`/`LIDENT`). Languages that defer identifier-kind to name resolution
(Rust) do so because case is *not* syntax there. Wok matches the Haskell case.

### Per-rule VarId reclassification

Every current `VarId` occurrence is reclassified:

| Current rule | Occurrence | Becomes |
|---|---|---|
| `DSig` | signature names (`f, g : T`) | `VarId` |
| `DData` | type name (`data T ...`) | `ConId` |
| `DData` / `separator` | type params (`a b c`) | `VarId` |
| `VICons` | extra sig names | `VarId` |
| `FNBare` | prefix function name | `VarId` |
| `FNAlpha` | fixity name (alphabetic op) | `VarId` |
| `LHSInfBT` / `IOBT` | backtick infix name | `VarId` |
| `PApp` | constructor head | `ConId` (via `ModPath`, see Patterns) |
| `APVar` | variable pattern | `VarId` |
| `ConDef` | constructor name | `ConId` |
| `TVar` | type var / ctor (was both) | split: `TVar VarId` + `TCon` |
| `EVar` | variable / ctor (was both) | split: `EVar VarId` + `ECon` |

### Patterns

```bnfc
PApp.  Pat ::= ModPath AtomPat [AtomPat] ;  -- constructor (poss. qualified), 1+ args
PCons. Pat ::= AtomPat "::" Pat ;
PAtom. Pat ::= AtomPat ;

APVar.   AtomPat ::= VarId ;     -- variable binder
APCon.   AtomPat ::= ModPath ;   -- nullary constructor (poss. qualified)
APWild.  AtomPat ::= "_" ;
APLitI.  AtomPat ::= WokInt ;
APLitS.  AtomPat ::= String ;
APLitC.  AtomPat ::= Char ;
APTuple. AtomPat ::= "(" Pat "," [Pat] ")" ;
APList.  AtomPat ::= "[" [Pat] "]" ;
APParen. AtomPat ::= "(" Pat ")" ;
```

**Important honesty note.** `PApp` still requires **1+ args**. The split fixes
the *variable-vs-constructor* problem (a bare lowercase name is unambiguously
`APVar`, a bare uppercase name is unambiguously `APCon`), but a 0-arg `PApp`
would still reduce/reduce against `PAtom (APCon ...)` for a bare constructor.
This is the same `gcon` / `apat` shaping Haskell's own grammar uses, and it is
correct. So bare constructors (qualified or not) reach the AST as
`PAtom (APCon ...)`, and `PApp` is "constructor applied to at least one arg."
`PAtom` likewise remains an explicit wrapper. Downstream `case`-over-`Pat` code
is unaffected by the split here.

### Types

```bnfc
TFun.  Type  ::= Type1 "->" Type ;
_.     Type  ::= Type1 ;
TApp.  Type1 ::= Type1 Type2 ;
_.     Type1 ::= Type2 ;
TVar.  Type2 ::= VarId ;     -- type variable
TCon.  Type2 ::= ModPath ;   -- type constructor, possibly qualified (Data.Maybe.Maybe)
TList. Type2 ::= "[" Type "]" ;
TTuple. Type2 ::= "(" Type "," [Type] ")" ;
TParen. Type2 ::= "(" Type ")" ;
```

Types use `ModPath` directly for (possibly qualified) type constructors —
there is no field projection in types, so `Data.Maybe.Maybe` is just a dotted
constructor name, not a projection node. This is the deliberate asymmetry with
expressions (next section): `.` in a type is *only* module qualification; `.`
in an expression is overloaded.

### Expressions

```bnfc
EVar.   Exp2 ::= VarId ;            -- variable
ECon.   Exp2 ::= ConId ;            -- bare data constructor
-- (EProj / EProjC added in Section C; ELitI/ELitS/ELitC/EParen/EParenOp/
--  EList/ETuple/ELam/ELet/ECase/EIf unchanged)
```

---

## Section B — Module syntax

```bnfc
-- Hierarchical dotted module paths
MPName.  ModPath ::= ConId ;
MPDot.   ModPath ::= ModPath "." ConId ;     -- Data.List

DModule. Decl ::= "module" ModPath ;         -- this file's module header
DImport. Decl ::= "import" ModPath ;         -- import a module by dotted name
DUse.    Decl ::= "use" ModPath ;            -- bring a module's names in unqualified
DLocal.  Decl ::= "local" Decl ;             -- private: not visible outside this module
```

### Header

`module XXX.YYY` is an explicit, hierarchical header (Haskell-flavored) — but
**without `where`**. `where` is a layout keyword (`layout "let","where","of"`);
`module Foo where` would open a nested layout block that fights `layout
toplevel`. So the header is just `module ModPath`.

The header is modeled as a `Decl` (`DModule`), conventionally the first one,
rather than a separate `Module ::= ModHeader [Decl]` rule — this keeps
`Module ::= [Decl]` intact and avoids fighting the toplevel layout filter. The
semantic pass enforces "present, first, and unique." This is the same
grammar-permits / semantic-restricts pattern v1 already uses (empty `case`,
equation grouping).

### Imports

`import` takes a dotted `ModPath`, not a string file path. (Futhark imports by
string path because its files are anonymous; Wok files are named by their
header, so import-by-name is the consistent choice.) `import Data.List` makes
the module reachable under its full path; members are accessed `Data.List.foo`.

`use` brings a module's names into scope unqualified — pure naming sugar, the
analogue of OCaml's `open` / Futhark's `open`. It is included now so the
keyword is reserved and the surface form parses; its scoping semantics are
renamer work.

### Visibility — `local`, not export lists

Default visibility is **public**. A declaration is made private by prefixing
`local` (Futhark's model: *"any names bound by `dec` will not be visible
outside the module"*). Chosen over a Haskell-style `module Foo (exports)`
list because there is no export list to keep in sync with the code, which
matches the "everything else public" direction already set.

`DLocal` is recursively `Decl`-wrapping-`Decl`. The grammar permits oddities
(`local local f`, `local module X`, `local import Y`); the semantic pass
restricts `local` to value / type / data / fixity declarations.

---

## Section C — The `x.y` projection

`x.y` is **one** syntactic form — a projection — parsed identically whether it
will turn out to be module-member access or record-field access. The parser
does not disambiguate; it emits a uniform node.

```bnfc
EProj.  Exp2 ::= Exp2 "." VarId ;   -- projection: module member OR record field
EProjC. Exp2 ::= Exp2 "." ConId ;   -- qualified constructor: List.Cons, Data.Maybe.Just
```

Two rules (VarId vs ConId selector) instead of a `Sel` wrapper category — this
avoids a needless wrapper AST node of the kind v1 already regrets (`PAtom`,
`VarIdComma`).

- **Left-associative**, at the `Exp2` (atom) level, so projection binds tighter
  than juxtaposition application: `f x.y` parses as `f (x.y)`.
- `Data.List.foldr` → `EProj (EProjC (ECon Data) List) foldr`.
- `(mkUser n).name` → `EProj (EParen ...) name`.
- The left operand is any `Exp2`, so the grammar accepts nonsense like
  `1.field`; the semantic pass rejects it. (Standard Wok grammar-permits /
  semantic-restricts.)

Patterns need qualified *constructors* but not projection (you do not match on
a field access), so qualified constructor patterns are handled by `ModPath` in
`PApp` / `APCon` (Section A), not by a projection node.

### Disambiguation is a two-phase semantic job

This is the key consequence for the future renamer and type checker. `EProj`
resolves in different phases depending on the kind of its head:

- **Head resolves to a module** → known at **name-resolution time**. The
  renamer knows every binding's kind, resolves the longest module-path prefix
  (standard qualified-name lookup), and rewrites the node into a direct
  reference.
- **Head resolves to a value** → `.y` is a **record-field projection**, which
  is **type-directed** — it cannot be validated until the head's type is
  known. That node survives into the type checker.

Recommended division of labor: the renamer rewrites all module-access `EProj`s
into resolved references, so the type checker only ever sees genuine field
projections.

---

## Section D — Reserved-word bucket

"Names that cannot be a `VarId`" is BNFC's reserved-word set. As confirmed from
the generated lexer (`Lex.x:176-197`), that set (`resWords`) is built **only**
from string literals appearing in productions — BNFC has no standalone
`reserved`/`keyword` pragma. To reserve words for features that do not exist
yet, the words must live in *a* production. They are collected into one bucket:

```bnfc
rules      ReservedKw ::= "contract" | "type" | "class" | "instance"
                        | "deriving" | "forall" | "do" | "record" ;
DReserved. Decl ::= ReservedKw ;
```

- `rules` is BNFC shorthand: it auto-generates one label per word, so the
  bucket is two lines and a small flat `ReservedKw` AST type.
- `DReserved` makes the bucket reachable from `Module`, which guarantees every
  word lands in `resWords` and is therefore excluded from `VarId`.
- Bonus: a reserved word written where a declaration is expected parses as
  `DReserved`, letting the semantic pass emit a precise *"`contract` is
  reserved for a future feature"* instead of a cryptic parse error.
- **Migration:** when a Tier-C feature ships, move its word out of `ReservedKw`
  into that feature's real production.

### Full reserved-word inventory

| Tier | Words | Source |
|---|---|---|
| A — current grammar | `case data else fixity if in left let looser of right than then tighter where` | v1 |
| B — this design | `module import use local` | Section B |
| C — future-reserved | `contract type class instance deriving forall do record` | Section D |

Each reserved word is an identifier users permanently lose. Tier C is curated
from the v1 spec's deferred-features list; `as` / `hiding` / `qualified` were
considered and **not** reserved (common identifier names; Haskell keeps them
contextual, which LALR/BNFC cannot easily do).

---

## AST shape summary

New / changed `Wok.Abs` types (BNFC-generated from the grammar above):

- New newtype: `ConId` (position-tagged, like `VarId`).
- New types: `ModPath`, `ReservedKw`.
- `Decl`: add `DModule`, `DImport`, `DUse`, `DLocal`, `DReserved`.
- `Exp`: add `ECon`, `EProj`, `EProjC`.
- `Type`: `TVar` now VarId-only; add `TCon` (over `ModPath`).
- `Pat` / `AtomPat`: `PApp` head and `APCon` now over `ModPath`.

### Which pass consumes what

- **Lexer:** `ConId` / `VarId` / `VarSym` (no `.`), the `.` token, reserved words.
- **Parser:** produces `Module` with the new nodes; layout filter unchanged
  (none of `module`/`import`/`use`/`local` opens a block).
- **Renamer (future):** resolves `import`s; rewrites module-access `EProj`;
  enforces `local` visibility; rejects `DReserved`; checks `DModule` placement.
- **Type checker (future):** record-field `EProj` only, type-directed, once
  record declarations exist.

## Conflicts expectation

v1 builds with 24 expression-layer shift/reduce conflicts (documented,
accepted). The new rules use distinct tokens (`.`, `module`, `import`, `use`,
`local`, Tier-C keywords), so they are expected to add no new conflicts; the
ConId/VarId split may slightly *reduce* them. The implementation plan must run
`bnfc --haskell -d` + `cabal build` and confirm the conflict count does not
regress meaningfully.

## Documented warts (accepted)

| Wart | Where | Note |
|---|---|---|
| `PApp` still requires 1+ args; bare constructors are `PAtom (APCon ...)` | grammar | Standard LALR shaping (Haskell `gcon`/`apat`). The split fixes var-vs-ctor *semantics*, not this structure. |
| `PAtom` remains an explicit wrapper | grammar | Unchanged from v1. |
| `EProj` is semantically overloaded (module vs field) | by design | Resolved in two phases (Section C). |
| `local local`, `local module`, `local import` parse | grammar | Semantic pass rejects. |
| `DModule` may appear anywhere / repeated | grammar | Semantic pass enforces first + unique. |
| `3.14` lexes as `WokInt . WokInt` → clean parse error | lexer | Floats still deferred; `.` reservation only changes the failure mode. |
| 8 Tier-C words unavailable as identifiers | lexer | Deliberate forward-compatibility cost. |

## Regeneration / migration steps (for the plan)

1. Edit `grammar/Wok.cf` per Sections A-D.
2. `bnfc --haskell -d -o src grammar/Wok.cf`; `cabal build`; check conflict count.
3. Update `Wok.Resolve` — `resolveExp` must gain cases for `ECon`, `EProj`,
   `EProjC` (recurse into the projection head).
4. Add example `.wok` files exercising modules, imports, `local`, projection,
   the split, and reserved-word errors; regenerate golden ASTs.
5. Update `README.md` (lexer rules, module syntax, reserved list, warts).

## Decisions log

1. **ConId/VarId split at the lexer**, not a later pass — case is mandatory
   syntax in Wok, as in Haskell/OCaml.
2. **`x.y` is a uniform `EProj`**, disambiguated semantically by whether the
   head is a module or a value (user decision). This *superseded* an earlier
   idea of lexing `List.map` as a single `QVarId` token.
3. **`.` removed from the `VarSym` alphabet** so qualified/projection syntax is
   lexically unambiguous; composition loses the `.` spelling.
4. **Module header is explicit and hierarchical (`module XXX.YYY`), no
   `where`** (layout conflict), modeled as the first `Decl`.
5. **Visibility via Futhark-style `local`**, default-public; rejected
   Haskell-style export lists.
6. **Future keywords reserved via a `ReservedKw`/`DReserved` bucket** — BNFC
   has no keyword pragma, so reservation requires a production.
7. **`PApp` keeps 1+ args** — correction to an earlier suggestion in design
   discussion that the split would allow 0-arg `PApp`; it would still
   reduce/reduce against the bare-constructor atom form.
