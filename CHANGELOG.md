# Revision history for wok

## 0.2.0.0

### Added

- ConId/VarId lexical split — constructors and type constructors are now
  lexically distinct from variables.
- Module syntax: `module` header, `import`, `use`, and the `local` private
  marker, with hierarchical dotted module paths.
- The `x.y` projection expression (module access or record field).
- A reserved-word bucket for future-feature keywords.

### Changed

- `.` is no longer a `VarSym` operator character; it is the projection /
  module-path separator.
- Token payloads in the AST are now `Text` (generated with BNFC `--text-token`).

## 0.1.0.0 -- Unreleased

v1 grammar frontend. Lex + parse + pretty-print round-trip. No typechecker, no runtime.

### Features

* BNFC grammar (`grammar/Wok.cf`) generating `Wok.{Abs, Lex, Par, Print, Layout, ErrM}`.
* Top-level declarations: function equations, type signatures (single `:`), data declarations, fixity declarations.
* Identifier classes: `VarId` (alphabetic; allows `_`, `-`, digits, primes) and `VarSym` (pure symbols).
* Expression layer: atoms (var, lit, paren, list, tuple, paren-op), juxtaposition application, flat infix-operator tails (precedence deferred to a future resolver pass), lambda, `let..in`, `case..of`, `if/then/else`.
* Pattern layer: variable, wildcard, literals, constructor application (`PApp`), right-assoc cons (`::`), list, tuple, paren.
* Type layer: type vars/ctors, function arrow (right-assoc), juxtaposition application, list, tuple.
* Fixity declarations: relational (`tighter than` / `looser than`), left/right associativity, no numeric levels.
* Four equivalent operator-definition forms: prefix bare, prefix paren `(+)`, infix symbolic, infix backtick.
* Layout pragma: indentation-based blocks for `let`, `where`, `case..of`, top-level decls; explicit braces still work.
* Negative integer lexer rule: `-5` lexes as one token (`WokInt`).
* CLI executable (`cabal run wok -- file.wok`) prints the parsed AST.
* Test suite: 11 example programs round-tripped via tasty-golden.

### Documented warts

* `1-2` and `foo-5` lex greedily; subtraction needs spaces.
* `if c then a else b + 1` parses as `(if-then-else) + 1` (tight-scope).
* `(sym) x = ...` after another decl needs explicit `;` (layout-filter quirk).
* Multiple list-pattern case alternatives need explicit braces (same quirk).
* `::` is a pattern-only cons in v1; not yet an expression-level infix operator.
* 24 happy shift/reduce conflicts in the eager-juxtaposition expression rule; resolved by default-shift, no functional impact.

### Deferred to v2+

See `docs/superpowers/specs/2026-05-20-bnfc-wok-grammar-design.md`.
