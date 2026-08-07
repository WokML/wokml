# wok

A Miranda-flavored functional language, built with BNFC for the front end.

The pipeline runs end to end: lex + parse + layout, name resolution, Hindley-Milner type inference with effect-row unification, elaboration to an ANF intermediate representation, and a stackless CEK interpreter that evaluates programs (`--run` runs `main`).

## What's implemented

- **Front end:** layout-aware parser, pretty-print round-trip, hierarchical modules (`module` / `import` / `use`, `local` visibility).
- **Type system:** Hindley-Milner inference with **effect-row** unification, records (construction, projection, patterns, row extension), and single-parameter **`Eq` type classes** via dictionary passing.
- **Pattern matching:** top-level multi-clause functions compile to decision trees (`Wok.IR.Match`); constructor / cons / record / literal / wildcard patterns.
- **Algebraic effect handlers:** `with { ... }` prefix handlers; auto-resume by default, bind a continuation to take control (abort / once / multishot); optional effect header `with E { ... }`; the `Never` bottom type and the forgotten-resume lint; and the bounded `(with H e)` form (handler scoped to one expression). Deep, multishot resume. See `docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md` for the slice roadmap.
- **Runtime:** ANF elaboration (`Wok.IR.Elaborate`) feeding a CEK interpreter (`Wok.Interp.Machine`). `--run` evaluates `main`; `--dump-anf` prints the elaborated IR.

## Build

Requires GHC 9.10+, Cabal 3.14+, and BNFC + Alex + Happy installed:

```bash
cabal install --overwrite-policy=always BNFC alex happy
cabal build
```

## Test

```bash
cabal test
```

The suite is golden-file based (`tasty-golden`) and covers the whole pipeline: parse round-trip (`test/examples/` vs `test/golden/`), name resolution (`test/resolve-examples/`), type checking (success in `test/typecheck-examples/`, expected failures in `test/typecheck-fail-examples/`), ANF elaboration (`test/anf-golden/`, `test/typed-anf-golden/`), and end-to-end evaluation (`test/run-examples/` vs `test/run-golden/`).

## Run the CLI

```bash
cabal run wok -- test/examples/01-literals.wok          # parse + pretty-print
cabal run wok -- test/run-examples/07-effect-ask.wok --run       # evaluate main
cabal run wok -- test/run-examples/07-effect-ask.wok --dump-anf  # dump elaborated ANF
```

## Regenerate after editing `grammar/Wok.cf`

```bash
bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf
cabal build
```

BNFC produces `Test.hs`, `Skel.hs`, `Doc.txt` and `.bak` files that are gitignored.

## Regenerate golden files

After adding or changing example files:

```bash
cabal test --test-options=--accept
```

## Language summary

- **Top-level decls:** function equations (`f x = ...`), type signatures (`f : T`), data declarations (`data T = ...`), fixity declarations (`fixity + left tighter than ...`).
- **Identifier classes:** `ConId` (uppercase-initial; data constructors, type
  constructors, module-name segments), `VarId` (lowercase- or `_`-initial;
  variables, type variables, function names, projection selectors), `VarSym`
  (pure-symbol operators; `.` is no longer a symbol character).
- **Block delimiters:** indentation (layout rule) OR explicit `{` `;` `}`. Both work; mixing is fine.
- **Conditional:** built-in `if c then a else b`.
- **Pattern matching:** `case e of { p1 -> e1; p2 -> e2 }`; top-level functions may have multiple clauses, compiled to decision trees.
- **Records:** construction `Point { x = 1, y = 2 }`, projection `p.x`, patterns `Point { x = a, .. }`, row extension `Point { ..p, x = 9 }`.
- **Type classes:** `class Eq a where { (==) : a -> a -> Bool }` and `instance Eq U64 where { ... }` (single-parameter; dictionary-passing).
- **Effect handlers:** `with { once Exn.throw m k -> None ; return v -> Some v } e` — prefix handlers over the rest of the block; an operation arm auto-resumes unless it is declared `once`, which binds a continuation as its last binder; optional header `with State { get -> 0 ; set s -> () }`; bounded form `(with H e)` scopes the handler to one expression. The `Never` bottom type marks non-returning operations.
- **Operator definitions** (all four equivalent):
  - `add x y = ...` -- prefix, alphabetic name
  - `(+) x y = ...` -- prefix, symbolic name in parens
  - `x + y = ...` -- infix, symbolic
  - `` x `add` y = ... `` -- infix, backtick-wrapped alphabetic
- **Fixity:** relational, not numeric. `fixity * left tighter than +`.
- **Cons:** `::` (Miranda/F#-style) in patterns only (`h :: t -> ...`). Not currently an expression-level infix operator.
- **Negative literals:** `-5` lexes as one token. `1-2` lexes as `[1, -2]`; subtraction needs spaces (`1 - 2`).

## Modules (v2)

- **Header:** `module Data.Example` — explicit, hierarchical, no `where`.
- **Imports:** `import Data.List` (by dotted name); `use Data.List` brings a
  module's names into scope unqualified.
- **Visibility:** declarations are public by default; prefix `local` to make
  one private (`local helper x = x`).
- **Qualified access / projection:** `x.y` is one syntactic form — either a
  module member or a record field — disambiguated by a later semantic pass.

## Known layout warts

- `(sym)` prefix operator definitions (e.g., `(+) x y = x`) must be the first top-level declaration OR must be preceded by an explicit `;`. The BNFC layout filter treats `(` as an "explicit block opener" and does not insert a separator before it.
- List patterns (`[x]`, `[]`) at the start of a case alternative following another case alternative with a list pattern also need explicit `;` separators. Use explicit braces for case blocks with multiple list patterns.

## Known AST-shape warts

These do not affect parsing but matter for downstream consumers (semantic pass, resolver):

- **`PApp` still takes 1+ args even after the ConId/VarId split.** The split
  removes the *variable vs constructor* semantic guesswork, but a 0-arg `PApp`
  would still clash with the bare-constructor atom form, so bare constructors
  remain `PAtom (APCon ...)`. This matches Haskell's `gcon`/`apat` shaping.
- **`Pat ::= AtomPat` is an explicit wrapper `PAtom`, not a transparent coercion.** BNFC's `_.` coercion only works between same-base-category precedence levels (e.g., `Exp/Exp1/Exp2`), not between distinct categories like `Pat` and `AtomPat`. Downstream `case` over `Pat` must handle the `PAtom` wrapper.
- **Integer literals are `WokInt` (a position-tagged text), not native Haskell `Integer`.** Needed for the `-5`-as-one-token lexer rule; BNFC doesn't allow overriding the built-in `Integer` token. Downstream code reads the integer value via `read :: String -> Integer`.
- **`EProj` (`x.y`) is semantically overloaded** — the parser cannot tell
  module access from record-field access. The renamer resolves module access;
  genuine field projections reach the type checker.
- **Reserved-for-future keywords:** `contract type class instance deriving
  forall do record` cannot be used as identifiers, though their features do
  not exist yet.

## Happy shift/reduce conflicts

`cabal build` reports **31** shift/reduce conflicts (summed across 6 LALR states; the bulk are in the expression layer `Exp1 -> Exp1 . Exp2` — eager-juxtaposition application meeting an infix tail; the count grew from 24 → 28 → 31 as the v2 pattern/projection rules and the effect-handler productions landed). Happy resolves by default-shift, which gives the desired left-associative parse for `f x y` and clean separation for `f x + g y`. No tests have failed because of these. Documented and accepted; revisit if a future grammar change risks worsening them.

## Deferred to v2+

See `docs/superpowers/specs/2026-05-20-bnfc-wok-grammar-design.md` for the full deferred-features list. Still deferred: floats, multi-parameter type classes, do-notation, mixfix-with-holes, `::` as an expression-level cons operator, layout-filter improvements. (Single-parameter type classes, records, and algebraic effect handlers have since landed — see "What's implemented" above.)
