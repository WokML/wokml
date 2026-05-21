# wok

A Miranda-flavored functional language frontend, built with BNFC.

**v1 is grammar only** -- lex + parse + pretty-print round-trip. No typechecker, no runtime, no semantics.

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

The test suite runs every `test/examples/*.wok` file through a parse -> pretty-print -> re-parse round-trip and compares against golden files in `test/golden/`.

## Run the CLI

```bash
cabal run wok -- test/examples/01-literals.wok
```

## Regenerate after editing `grammar/Wok.cf`

```bash
bnfc --haskell -d -p GeneratedParser --text-token -o src grammar/Wok.cf
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
- **Identifier classes:** `VarId` (alphabetic; may contain `_`, `-`, digits, primes; cannot start `-`), `VarSym` (pure-symbol operators).
- **Block delimiters:** indentation (layout rule) OR explicit `{` `;` `}`. Both work; mixing is fine.
- **Conditional:** built-in `if c then a else b`.
- **Pattern matching:** `case e of { p1 -> e1; p2 -> e2 }`.
- **Operator definitions** (all four equivalent):
  - `add x y = ...` -- prefix, alphabetic name
  - `(+) x y = ...` -- prefix, symbolic name in parens
  - `x + y = ...` -- infix, symbolic
  - `` x `add` y = ... `` -- infix, backtick-wrapped alphabetic
- **Fixity:** relational, not numeric. `fixity * left tighter than +`.
- **Cons:** `::` (Miranda/F#-style) in patterns only (`h :: t -> ...`). Not currently an expression-level infix operator.
- **Negative literals:** `-5` lexes as one token. `1-2` lexes as `[1, -2]`; subtraction needs spaces (`1 - 2`).

## Known layout warts

- `(sym)` prefix operator definitions (e.g., `(+) x y = x`) must be the first top-level declaration OR must be preceded by an explicit `;`. The BNFC layout filter treats `(` as an "explicit block opener" and does not insert a separator before it.
- List patterns (`[x]`, `[]`) at the start of a case alternative following another case alternative with a list pattern also need explicit `;` separators. Use explicit braces for case blocks with multiple list patterns.

## Known AST-shape warts

These do not affect parsing but matter for downstream consumers (semantic pass, resolver):

- **`PApp` is "constructor with 1+ args"; bare names parse as `PAtom (APVar x)`.** The grammar can't distinguish a nullary constructor (`Nothing`) from a variable binding (`x`) at parse time, so both reach the AST as `PAtom (APVar ...)`. The semantic pass distinguishes by uppercase-vs-lowercase against the data environment. (Spec uses `PCon`; grammar uses `PApp` due to a LALR reduce/reduce conflict at zero args.)
- **`Pat ::= AtomPat` is an explicit wrapper `PAtom`, not a transparent coercion.** BNFC's `_.` coercion only works between same-base-category precedence levels (e.g., `Exp/Exp1/Exp2`), not between distinct categories like `Pat` and `AtomPat`. Downstream `case` over `Pat` must handle the `PAtom` wrapper.
- **Integer literals are `WokInt` (a position-tagged string), not native Haskell `Integer`.** Needed for the `-5`-as-one-token lexer rule; BNFC doesn't allow overriding the built-in `Integer` token. Downstream code reads the integer value via `read :: String -> Integer`.

## Happy shift/reduce conflicts

`cabal build` reports `shift/reduce conflicts: 24`, all in the expression layer (`Exp1 -> Exp1 . Exp2` — eager-juxtaposition application meets infix tail). Happy resolves by default-shift, which gives the desired left-associative parse for `f x y` and clean separation for `f x + g y`. No tests have failed because of these. Documented and accepted for v1; revisit if a v2 grammar change risks worsening them.

## Deferred to v2+

See `docs/superpowers/specs/2026-05-20-bnfc-wok-grammar-design.md` for the full deferred-features list. Highlights: floats, modules, type classes, records, do-notation, mixfix-with-holes, `::` as expression-level cons, layout-filter improvements.
