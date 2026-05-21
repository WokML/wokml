# Wok v1 Grammar — Design Spec

**Date:** 2026-05-20
**Status:** Approved, ready for implementation planning
**Project:** `wok` (the Haskell-cabal project at `/Users/zy/wokml`)

## Purpose

Design a BNFC grammar for `wok`, a Miranda-flavored functional language with Agda-influenced precedence handling. v1 covers lex + parse + AST round-trip; typechecking, semantics, and the precedence resolver are out of scope.

The grammar must produce **zero conflicts** when fed through `bnfc --haskell -d`, and must support a downstream mixfix-style precedence resolver that runs as a separate pass.

## High-level shape of the language

A wok source file is a layout-blocked list of top-level declarations. Each declaration is one of: function equation, type signature, data declaration, fixity declaration. Expressions are parsed with deferred precedence — operators are kept flat in a head-and-infix-tail shape that the post-parse resolver consumes.

The language is *not* Haskell. Key surface-syntax differences:

- `:` (single colon) for type annotation. `::` is list cons.
- `--` for line comments. `{- -}` for nested block comments.
- No mixfix-with-holes (`if_then_else_`, `_+_`). Operator-shape information lives in fixity declarations, not in operator names.
- Two ident lex classes — `VarId` (alphabetic) and `VarSym` (symbolic) — to disambiguate infix function definitions.
- No numeric precedence levels. Precedence is declared relationally via `tighter than` / `looser than`, forming a partial order. Operators with no declared relation are incomparable; mixing them in one expression without parens is a resolver error.
- `if/then/else` is built-in syntax; conditional via boolean.

## Project layout

```
/Users/zy/wokml/
├── wok.cabal                  # add build-tool-depends: BNFC, alex, happy
├── app/
│   └── Main.hs                # CLI: read file → lex → parse → pretty-print AST
├── grammar/
│   └── Wok.cf                 # the single BNFC source-of-truth file
├── src/                       # BNFC-generated modules land here
│   └── Wok/
│       ├── Abs.hs             # generated abstract syntax tree
│       ├── Lex.hs             # generated Alex lexer
│       ├── Par.hs             # generated Happy parser
│       ├── Print.hs           # generated pretty-printer
│       ├── Layout.hs          # generated layout resolver
│       └── ErrM.hs            # generated error monad
├── test/
│   ├── examples/              # *.wok sample programs that should parse
│   └── golden/                # AST golden files (printed back via Print.hs)
└── docs/superpowers/specs/    # this file lives here
```

- **One grammar file** `grammar/Wok.cf`. BNFC handles modular grammars poorly; one file is the norm.
- **Build wiring:** add a `library` stanza with `src` as its `hs-source-dirs`. Add `build-tool-depends: BNFC:bnfc, alex:alex, happy:happy`. Generated files are checked in (so `cabal build` works without BNFC installed) but regenerable.
- The future hand-written **mixfix/precedence resolver** module (e.g., `src/Wok/Resolve.hs`) consumes `Wok.Abs` types. It is *not* part of v1; a stub interface is sketched in "Future work" below.

## Lexical layer

### Identifier classes

```
varidStart  = letter | "_"                          -- "-" forbidden at start
varidCont   = letter | digit | "_" | "'" | "-"      -- only "-" from symbols allowed mid/end
varid       = varidStart varidCont*
            EXCLUDING bare "_" (which is the wildcard token)

varsym      = symbolChar+                           -- pure-symbol run
            EXCLUDING reserved-token table matches (longest-match rule)

  symbolChar = ! # $ % & * + . / < = > ? @ \ ^ | - ~
```

Two ident classes — `VarId` and `VarSym` — disjoint by start character. No third "mixfix" class; mixfix-with-holes is not in scope for v1.

Constructor-vs-variable disambiguation is a **semantic** decision (made after the data env is built), not a lexical one. `Just` lexes as `VarId`, the same as `foo`.

### Wildcard

Bare `_` (length exactly 1) lexes as the wildcard token, not as a `VarId`. Any longer ident containing `_` is `VarId` (e.g., `_unused`, `x_y`, `_x_y_z_`). The `_unused` Haskell convention for intentionally-unused binders is preserved.

### Integer literals

```
intLit      = digit+
            | "-" digit+              (when "-" is at token-start position)
```

The `-`-followed-by-digit rule is greedy at the lexer level: `-5` is one token `IntLit -5`. Consequences:

| Input | Tokens |
|---|---|
| `-5` | `IntLit -5` |
| `- 5` | `VarSym "-"`, `IntLit 5` |
| `f -5` | `VarId "f"`, `IntLit -5` (== f applied to -5) |
| `f - 5` | `VarId "f"`, `VarSym "-"`, `IntLit 5` (== f minus 5) |
| `1-2` | `IntLit 1`, `IntLit -2` (greedy: subtraction needs spaces) |
| `foo-5` | `VarId "foo-5"` (greedy: subtraction needs spaces) |

The `1-2` / `foo-5` warts are documented in the style guide. Subtraction always requires spaces around `-`.

### String and char literals

Standard. Escapes: `\n \t \r \\ \" \' \0 \xHH \uHHHH`. No interpolation in v1.

### Comments

```
lineComment  = "--" .* '\n'                         -- per syntax.md
blockComment = "{-" (any, including nested {- -}) "-}"
```

### Reserved tokens

**Reserved keywords (length-13 list):**

```
let  in  case  of  data  where
fixity  left  right  tighter  looser  than
if  then  else
```

**Reserved operator-tokens:**

```
=  ->  \  |  :  ::
```

**Reserved punctuation:**

```
(  )  [  ]  {  }  ,  ;  `
```

Lexer uses **longest-match, then keyword-table check**: read a maximal ident-or-symbol run, then if the whole run matches a reserved token, emit the reserved token instead. So `lett` is `VarId "lett"`, not `let` + `t`. Same with `::=` would be three tokens `::` + `=` (longest-match takes the 2-char `::`).

### Float literals — deferred

`.` is a symbol char and could appear in operator names. Float lexing requires careful disambiguation (e.g., between `3.14` and `3 . 14`). Defer to v2.

## Layout pragma

```
layout toplevel ;                   -- the file itself is a layout block of decls
layout "let", "where", "of" ;       -- after each of these, open an indented block
layout stop "in" ;                  -- "in" closes the matching "let" block early
```

Mechanics: BNFC's layout filter operates between the lexer and the parser, inserting virtual `{`, `;`, `}` tokens based on indentation. The grammar is written with explicit braces; source files use indentation.

Examples:

```
-- Layout-free (explicit braces):
f x = let { y = x + 1; z = y * 2 } in z + y

-- Layout (idiomatic):
f x =
  let y = x + 1
      z = y * 2
  in z + y

-- Top-level decls, one per line, no indentation:
f x = x + 1
g y = y * 2
data Maybe a = Nothing | Just a
```

`if/then/else` does *not* open a layout block. Multi-line conditionals require the continuation lines (`then`, `else`) to be indented more than the enclosing block's reference column:

```
let x = if foo
        then bar
        else baz
in x
```

## Top-level structure

```
Module.   Module ::= [Decl] ;
separator Decl ";" ;

DEqn.     Decl ::= FunLHS "=" Exp MaybeWhere ;
DSig.     Decl ::= VarId [VarId] ":" Type ;             -- multi-name: `f, g : T`
DData.    Decl ::= "data" VarId [VarId] "=" [ConDef] ;
DFixity.  Decl ::= "fixity" FixName FixAssoc [FixRel] ;

separator VarId "," ;
separator ConDef "|" ;

ConDef.   ConDef ::= VarId [AtomType] ;                 -- e.g. `Just a`, `Cons a (List a)`
```

- One file = one module. No `module Foo where` header in v1.
- Top-level decls separated by `;` (or layout-inserted equivalents).

### Function-equation LHS

Three forms via the lex split — symbolic infix works directly; alphabetic infix needs backticks.

```
DEqn.     Decl ::= FunLHS "=" Exp MaybeWhere ;

LHSPre.   FunLHS ::= FunName [AtomPat] ;                -- prefix:  f x y
LHSInfSym. FunLHS ::= AtomPat VarSym AtomPat ;          -- infix symbolic:  x + y
LHSInfBT.  FunLHS ::= AtomPat "`" VarId "`" AtomPat ;   -- infix alphabetic: x `add` y

FNBare.   FunName ::= VarId | VarSym ;
FNParen.  FunName ::= "(" VarSym ")" ;                  -- (+) x y = ...
```

Equivalent definition forms for `+`:

```
(+) x y    = ...              -- prefix paren form
x + y      = ...              -- infix form (works because + is VarSym)
x `+` y    = ...              -- backticks always permitted
```

For an alphabetic name `add`:

```
add x y    = ...              -- prefix form
x `add` y  = ...              -- infix form (backticks required)
```

Multiple equations with the same name parse as separate `DEqn`s. A later semantic pass groups them.

### `where` clauses

```
NoWhere.  MaybeWhere ::= ;
WithWh.   MaybeWhere ::= "where" "{" [LocalDecl] "}" ;
separator LocalDecl ";" ;

LDEqn.    LocalDecl ::= FunLHS "=" Exp MaybeWhere ;
LDSig.    LocalDecl ::= VarId [VarId] ":" Type ;
```

Local decls allow only function equations and type signatures. No nested `data` or `fixity` in `where` blocks (fixity is top-level only by design).

### Type signatures

Single colon `:` per `syntax.md`. Multiple names allowed: `f, g, h : Int -> Int`.

### Data declarations

```
data Maybe a = Nothing | Just a
data List a = Nil | Cons a (List a)
data Pair a b = MkPair a b
```

No `deriving`, no GADTs, no record syntax, no constraints in v1.

### Fixity declarations

```
DFixity.  Decl     ::= "fixity" FixName FixAssoc [FixRel] ;
FNSym.    FixName  ::= VarSym ;
FNAlpha.  FixName  ::= VarId ;
FALeft.   FixAssoc ::= "left" ;
FARight.  FixAssoc ::= "right" ;
FRTight.  FixRel   ::= "tighter" "than" FixName ;
FRLoose.  FixRel   ::= "looser"  "than" FixName ;
separator FixRel "" ;
```

Examples:

```
fixity +   left
fixity -   left
fixity *   left   tighter than +
fixity /   left   tighter than +
fixity ::  right
fixity ==  left   looser  than +
fixity add left                            -- used as `x `add` y`
```

**Design notes:**

- **Binary infix only.** No prefix/postfix user-declared operators in v1.
- **Relational precedence**, not numeric. `tighter than X` and `looser than X` form a partial order via the resolver's DAG. No `equal to` (no equivalence; strict partial order).
- **Operators with no declared relation are incomparable.** An expression that mixes incomparable operators without parens is a resolver error: *"ambiguous: declare a relation between `+` and `<>`."*
- **No source-level `prefix`/`postfix` keywords.** Unary minus is hardcoded in the resolver (overloaded prefix-when-no-left-operand and infix). `not x` works as plain juxtaposition application — no fixity needed.

## Patterns

```
PVar.    Pat ::= VarId ;
PWild.   Pat ::= "_" ;
PLitI.   Pat ::= Integer ;
PLitS.   Pat ::= String ;
PLitC.   Pat ::= Char ;
PCon.    Pat ::= VarId [AtomPat] ;                    -- constructor with args
PTuple.  Pat ::= "(" Pat "," [Pat] ")" ;              -- 2-or-more
PList.   Pat ::= "[" [Pat] "]" ;
PCons.   Pat ::= AtomPat "::" Pat ;                   -- right-assoc cons
PParen.  Pat ::= "(" Pat ")" ;

separator Pat "," ;

-- AtomPat excludes applied/cons forms (used as constructor args, infix-LHS operands, etc.)
APVar.   AtomPat ::= VarId ;
APWild.  AtomPat ::= "_" ;
APLitI.  AtomPat ::= Integer ;
APLitS.  AtomPat ::= String ;
APLitC.  AtomPat ::= Char ;
APTuple. AtomPat ::= "(" Pat "," [Pat] ")" ;
APList.  AtomPat ::= "[" [Pat] "]" ;
APParen. AtomPat ::= "(" Pat ")" ;
```

**Notes:**

- **Variable vs constructor pattern** is a semantic decision. Both lex as `VarId` and grammar produces `PVar`/`PCon` based on arity. The semantic pass uses the data env to reclassify: a 0-arg `PVar` whose name matches a known constructor is a constructor match, not a variable binding.
- **`f Just = ...` ambiguity:** without a case convention, this could mean "match constructor `Just` (taking 0 args)" or "bind variable named `Just`." The semantic pass resolves via the data env. Documented wart.
- **Cons `::`** is right-associative: `1 :: 2 :: xs` → `1 :: (2 :: xs)`.
- **Tuples** require ≥ 2 elements. `(x)` is `PParen`.
- **Deferred:** as-patterns (`x@p`), view patterns, bang patterns, record patterns, irrefutable `~p`. All v2+.

## Expressions

The expression layer uses **Approach B with eager juxtaposition**: a head application-run followed by a flat list of (infix-op, application-run) tails. Operator precedence/associativity is deferred to the resolver pass; juxtaposition application is eager in the grammar.

```
EExpr.    Exp ::= AppExp [InfixTail] ;
ITail.    InfixTail ::= InfixOp AppExp ;
IOSym.    InfixOp ::= VarSym ;
IOBT.     InfixOp ::= "`" VarId "`" ;
separator InfixTail "" ;

EApp.     AppExp ::= AppExp AtomExp ;                 -- left-assoc juxtaposition
_.        AppExp ::= AtomExp ;

EVar.     AtomExp ::= VarId ;
ELitI.    AtomExp ::= Integer ;
ELitS.    AtomExp ::= String ;
ELitC.    AtomExp ::= Char ;
EParen.   AtomExp ::= "(" Exp ")" ;
EParenOp. AtomExp ::= "(" VarSym ")" ;                -- use a VarSym as a value
EList.    AtomExp ::= "[" [Exp] "]" ;
ETuple.   AtomExp ::= "(" Exp "," [Exp] ")" ;
ELam.     AtomExp ::= "\\" [Pat] "->" Exp ;
ELet.     AtomExp ::= "let" "{" [LocalDecl] "}" "in" Exp ;
ECase.    AtomExp ::= "case" Exp "of" "{" [Alt] "}" ;
EIf.      AtomExp ::= "if" Exp "then" Exp "else" Exp ;

separator Exp "," ;

Alt.      Alt ::= Pat "->" Exp MaybeWhere ;
separator Alt ";" ;
```

### How each test input parses

| Input | Parses as (AST sketch) | Resolver step |
|---|---|---|
| `1 + 2 * 3` | head `1`, tail `[(+, 2), (*, 3)]` | precedence reorder per DAG |
| `f x y` | head `App (App f x) y`, tail `[]` | (nothing; already a tree) |
| `map f xs ++ ys` | head `App (App map f) xs`, tail `[(++, ys)]` | precedence reorder if `++` mixed with others |
| `1 :: 2 :: []` | head `1`, tail `[(::, 2), (::, [])]` | right-assoc per `fixity :: right` |
| `` x `div` y + z `` | head `x`, tail `` [(`div`, y), (+, z)] `` | precedence reorder |
| `(+) 1 2` | head `App (App (paren-wrap +) 1) 2`, tail `[]` | (already a tree) |
| `if b then a else c` | `EIf b a c` as an atom | (no resolver work; built-in) |

### Notes

- **Operator chains are flat in the AST.** The grammar emits `head + [(op, operand), ...]`; the resolver consumes the flat list and builds a tree using the fixity table.
- **Juxtaposition is eager.** Because we have no mixfix-with-holes, the grammar applies left-to-right `App` directly. This is a simplification over the originally-considered "fully flat token list" approach.
- **`if/then/else` is built-in.** No mixfix needed. Three reserved words: `if`, `then`, `else`. Conditional sub-expressions are normal `Exp` slots; greedy parsing handles nested `if`s cleanly.
- **No operator sections** (`(+ 1)`, `(1 +)`) in v1. Use `\x -> x + 1` instead.

## Types

```
TFun.     Type     ::= AppType "->" Type ;            -- right-assoc
_.        Type     ::= AppType ;

TApp.     AppType  ::= AppType AtomType ;             -- left-assoc type application
_.        AppType  ::= AtomType ;

TVar.     AtomType ::= VarId ;                        -- both type-var and type-ctor
TList.    AtomType ::= "[" Type "]" ;
TTuple.   AtomType ::= "(" Type "," [Type] ")" ;
TParen.   AtomType ::= "(" Type ")" ;

separator Type "," ;
```

- Single `VarId` class covers both type variables and type constructors. Distinction is semantic.
- `->` right-assoc: `Int -> Int -> Int` = `Int -> (Int -> Int)`.
- Type application is juxtaposition, left-assoc: `Maybe a b` = `(Maybe a) b`.
- Tuple types require ≥ 2 components. Lists are `[T]`.
- **Deferred:** type-level operators, `forall`, kind annotations, constraints (`Eq a =>`), type aliases.

## Reserved-word and reserved-symbol summary

For implementer reference:

**Keywords (15):**
```
let  in  case  of  data  where
fixity  left  right  tighter  looser  than
if  then  else
```

**Operator-symbol tokens (6):**
```
=  ->  \  |  :  ::
```

**Punctuation (9):**
```
(  )  [  ]  {  }  ,  ;  `
```

## Documented warts (accepted during design)

| Wart | Where | Workaround |
|---|---|---|
| `1-2` lexes as `[1, IntLit(-2)]` | lexer | Write `1 - 2` |
| `foo-5` lexes as one VarId | lexer | Style: spaces around binary `-` |
| `f Just = ...` ambiguity (ctor vs binder) | parser → semantic | Resolve via data env |
| Symbolic operator def must be `(+) x y = ...` or `x + y = ...`, never bare | grammar | Use one of the supported forms |
| `-x` (variable negation) not declarable at source | resolver | Hardcoded `-` as overloaded prefix/infix |
| `if c then a else b + 1` parses as `(if c then a else b) + 1`, NOT Haskell's `if c then a else (b + 1)` | grammar | `if/then/else` is an `AtomExp` (tight scope). Add parens to extend an `else` branch over operators. |

## Deferred to v2+

- Float literals
- Module system (`module Foo where`, imports, exports)
- Type classes / constraints / `forall` / kind annotations
- Type aliases (`type T = ...`)
- Type-level operators
- Records (declaration + update syntax)
- Deriving clauses
- As-patterns, view patterns, bang patterns, irrefutable patterns
- `do`-notation
- Prefix / postfix user-declared operators
- Mixfix-with-holes (`if_then_else_` style)
- ConId/VarId lex split (uppercase-vs-lowercase distinction)
- Operator sections (`(+ 1)`, `(1 +)`)
- User-defined fixity for `if`/`then`/`else` (they are now built-in keywords)

## Out of scope (non-goals)

- Typechecker
- Codegen / interpreter / runtime
- Standard library
- REPL

## v1 deliverable

1. `grammar/Wok.cf` — BNFC grammar producing zero conflicts on `bnfc --haskell -d -o src grammar/Wok.cf`.
2. `src/Wok/{Abs,Lex,Par,Print,Layout,ErrM}.hs` — generated and committed.
3. `app/Main.hs` — reads file, lexes + parses + layout-resolves + pretty-prints AST.
4. `test/examples/*.wok` — corpus exercising every grammar production.
5. `test/golden/*.expected` — golden ASTs (text from `Wok.Print`) verified by a test runner.

### Definition of done

- All examples parse without conflict warnings from BNFC/Happy.
- Parse → print → parse round-trip is stable (same AST).
- README documents the lexer rules, the fixity scheme, and the deferred-list above.

## Future work — Mixfix resolver (sketch only)

This module is **not** part of v1. It is described here so the v1 grammar's AST shape is justified.

**Interface:**

```haskell
module Wok.Resolve where

import qualified Wok.Abs as A

-- The resolver consumes the loose AST (head + flat infix tail) and produces
-- a fully-parenthesized expression tree using the fixity environment.
resolve :: FixEnv -> A.Exp -> Either ResolveError ResolvedExp

data Fixity = Fixity
  { fixAssoc :: Assoc        -- Left | Right
  , fixRels  :: [Relation]   -- Tighter ident | Looser ident
  } deriving Show

data Assoc = AssocLeft | AssocRight
data Relation = TighterThan A.FixName | LooserThan A.FixName

type FixEnv = Map A.FixName Fixity
```

**Behavior:**

1. Build a precedence DAG from `tighter/looser` declarations.
2. For each flat operator chain `[op1, op2, ...]`, use the DAG to determine parenthesization. Reject if the chain mixes incomparable operators ("ambiguous: declare a relation between X and Y").
3. Apply associativity within each precedence level.
4. Hardcode `-` as overloaded prefix-when-no-left-operand / infix-otherwise.

A separate "Wok precedence & mixfix resolver" brainstorm should be opened **after** the v1 grammar can parse files. That session designs the default precedence table (what `+`, `*`, `::`, `==`, `++`, etc. ship with), the error-reporting strategy, and any extension points.

## Decisions log (key iterations during brainstorm)

For traceability — the choices that took multiple rounds:

1. **Expression-layer shape:** considered right-recursive operator chain (A), application-chain + tail (B), and fully-flat token list (C). Initially picked C for Agda-faithfulness. Switched to B after adopting the lex split (which made C unnecessary) and dropping mixfix-with-holes.
2. **Operator lex class:** initially single uniform `Ident`; switched to **two-class lex split** (`VarId` / `VarSym`) when user accepted Haskell's approach for infix-LHS support.
3. **Mixfix-with-holes:** considered, then iterated through several shapes (`_+_`, `_!`, `if_then_else_`, etc.), then dropped entirely. v1 has binary infix only. `if/then/else` added back as a built-in keyword form.
4. **Fixity precedence:** numeric Haskell-style first, switched to **relational `tighter than` / `looser than`** (Agda-influenced). Dropped `infix` (non-associative) and `equal to` for further simplicity.
5. **Unary minus:** went through several iterations. Final: lexer-level rule for `-` + digit = `IntLit`; resolver-hardcoded prefix for `-x` (variable).
6. **`_unused` convention:** preserved by allowing `_`-prefixed names as `VarId` after dropping mixfix-with-holes (which had collided).
