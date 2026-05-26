# Unit literal `()` — design

Status: draft (awaiting user review)
Owner: zy
Date: 2026-05-26

## Motivation

Wok's grammar today has no surface syntax for the unit value, type, or
pattern. The `("()", TyConInfo KStar 0 [])` entry in
`Wok.TypeChecking.Builtins.initialEnv` is registered but unreachable from
source: `EParen` requires `"(" Exp ")"` (one or more expressions inside),
`ETuple` requires two or more, `TParen` requires a `Type`, `APParen`
requires a `Pat`. There is no production matching `(` followed immediately
by `)`.

This spec adds the three missing productions so users can write `()` as a
value, type, and pattern. Whitespace between the parens is permitted,
matching ML-family convention (OCaml, F#, Standard ML, and Rust all accept
`( )` as unit; Haskell and Elm are the strict outliers).

This change is **orthogonal to the include-path / `Std.Base` spec** and can
ship in either order; neither depends on the other.

## Goals

- Add `EUnit`, `TUnit`, `PUnit` BNFC productions for the unit value, type,
  and pattern respectively.
- Allow arbitrary whitespace between `(` and `)` (`()`, `( )`, `(   )` all
  accepted).
- Hook the new productions into the typechecker so the existing `()` tycon
  entry becomes reachable as `CTCon TcUnit []`.

## Non-goals

- No new constructor name for unit (no `Unit`, no `MkUnit`). Following the
  same pattern as `[]` and the tuple family, the only inhabitant of unit
  is the unit literal itself, spelled identically as `()`.
- No alias type name. The type and value share the spelling `()`.

## Grammar changes (`grammar/Wok.cf`)

Add three productions:

```bnfc
EUnit.  Exp2    ::= "(" ")" ;
TUnit.  Type2   ::= "(" ")" ;
PUnit.  AtomPat ::= "(" ")" ;
```

Two-token form (separate `(` and `)`) rather than a single `"()"` lexer
token. BNFC's default whitespace-as-token-separator behavior then accepts
`( )` and `(   )` automatically — no lexer special-case.

**LALR(1) check.** The existing
`EParen "(" Exp ")"`, `ETuple "(" Exp "," [Exp] ")"`,
`TParen "(" Type ")"`, `TTuple "(" Type "," [Type] ")"`,
`APParen "(" Pat ")"`, `APTuple "(" Pat "," [Pat] ")"`
all require non-empty content after the opening `(`. Adding `EUnit "("
")"` etc. introduces no shift-reduce or reduce-reduce conflicts because
the lookahead token `)` immediately after `(` distinguishes the unit form
from every other paren production (which all require an Exp / Type / Pat
non-terminal next).

After editing the grammar, regenerate:

```sh
bnfc --haskell -d --text-token -o src-generated grammar/Wok.cf
```

(Same command already documented in `wok.cabal` under the
`wok-generated` library notes.)

## Typechecker changes (`src/Wok/TypeChecking/Infer.hs`)

Three new case branches, all returning the existing `TcUnit` tycon:

- `inferExpr (Abs.EUnit _)`: type is `CTCon TcUnit []`.
- `translateType ... (Abs.TUnit _)`: type is `CTCon TcUnit []`.
- `inferAtomPat (Abs.PUnit _)`: type `CTCon TcUnit []`, no bindings.

The `()` tycon entry in `Builtins.initialEnv` is unchanged; it just
becomes reachable. The `prettyCType` case `CTCon TcUnit [] -> "()"`
already exists (`Infer.hs:828`) — no change needed.

## Test plan

Add to the existing `tasty` suite:

| Test                       | Asserts                                                          |
| -------------------------- | ---------------------------------------------------------------- |
| `unitValueParsesAndTypes`  | `u = ()` typechecks; `u : ()` in env.                            |
| `unitValueWithWhitespace`  | `u = ( )` typechecks identically to `u = ()`.                    |
| `unitValueExtraWhitespace` | `u = (   )` accepted.                                            |
| `unitTypeAnnotation`       | `u : ()` followed by `u = ()` typechecks; sig is honored.        |
| `unitFunctionArg`          | `f () = 0` typechecks as `() -> u64` (or `() -> Int` pre-Std.Base spec); pattern matches the unit value. |
| `unitInTuple`              | `pair = ((), 42)` infers `((), <integer-literal-type>)`.         |
| `unitParseErrors`          | `()` followed by junk inside still fails as expected (sanity check that other paren productions are not broken). |

The "integer-literal type" in `unitFunctionArg` and `unitInTuple` is `u64`
if the include-path spec has landed, `Int` if not. Tests should match
whichever has landed at the time this change is implemented.

## Files changed

| File                                       | Action                                  |
| ------------------------------------------ | --------------------------------------- |
| `grammar/Wok.cf`                           | Add `EUnit`, `TUnit`, `PUnit`.          |
| `src-generated/GeneratedParser/Wok/*.hs`   | Regenerated via BNFC.                   |
| `src/Wok/TypeChecking/Infer.hs`            | Add three case branches (`EUnit`, `TUnit`, `PUnit`). |
| `test/Spec.hs` (or wherever TC tests live) | Add tests per plan.                     |
