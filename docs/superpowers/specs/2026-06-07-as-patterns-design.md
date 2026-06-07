# Design: `as` as-patterns (slice A)

Date: 2026-06-07
Status: **Implemented on `feat/as-patterns`** (Tasks 1-4 + 2b). As-patterns
(`pat as name`, name last) work in case arms, lambdas, single-clause heads,
multi-clause/decision-tree heads, nested under constructors, and `var as var`.
Full suite green. Demo: `examples/as-patterns.wok`.
Branch: `feat/as-patterns`.

Derives from `docs/superpowers/specs/2026-06-07-tagged-effects-as-patterns-num.md`
(§2 as-patterns). This slice implements **only** as-patterns; tagged effect instances
(§1) and `Num` (§4) are out of scope.

**Surface-token change from the source spec.** The source spec proposed `@` as a
shared postfix naming operator for as-patterns AND tagged effects. That coupling was
dropped in brainstorming: tagged effects will use a **named-capability binder**
(`with count = state 0 in … count.get`, Design 2 — see the effect-naming memory), not
`@`. With nothing else needing `@`, as-patterns use the conventional **`as` keyword**
(OCaml/F# style, `pat as name`), and `@` is **left free / unreserved** — earmarked for
future **visible type application** (`e @Type`), which serves the deferred `Num`/`Monoid`
return-type-dispatch work and has no clean keyword alternative. This also removes the
riskiest grammar work (no `VarSym` surgery, no `@@`-operator fixture migration).

## 1. Goal

Add **as-patterns**: match a structure and simultaneously bind a name to the whole
matched value, name LAST via the `as` keyword (`pat as name`) — exactly OCaml/F#
as-patterns.

```
dedupHead : [U64] -> [U64]
dedupHead (x :: y :: rest) as whole = case x == y of
  True  -> dedupHead (y :: rest)   -- drop the dup, keep going
  False -> whole                   -- reuse the whole list, no rebuild
dedupHead other = other
```

Read as "`(x :: y :: rest)`, named `whole`." The name binds the exact value the inner
pattern matched, so the body can reuse it without rebuilding or re-matching.

## 2. Decisions (settled in brainstorming)

- **Surface:** `pat as name`, name LAST. Grammar: `APAs. AtomPat ::= AtomPat "as" VarId`
  (left-recursive, BNFC-friendly). Richer left patterns use parens: `(Just x) as whole`,
  `(x :: xs) as whole`.
- **`as` keyword:** `"as"` becomes a reserved literal token via the production. This is
  safe: `as` is not currently a keyword, the import syntax is `import ModPath` (no
  aliasing), and no `.wok` file uses `as` as an identifier. `@` is **untouched** — it
  stays in the `VarSym` class (still a valid operator char), so the `@@` cross-fixity
  fixture is unaffected; no fixture migration. `@` is reserved only in the roadmap, for
  future visible type application.
- **Scope — full support:** as-patterns are allowed everywhere `AtomPat` appears —
  case arms, function-LHS args (single- and multi-clause), lambda binders, let/where
  binders, and nested inside other patterns.
- **Edge cases:**
  - `var as var` (e.g. `x as y`): allowed (both names bind the whole value; harmless).
  - Nested / chained as-patterns (`(Just x) as a` inside another pattern; `foo as a as b`
    parses left-recursively as `(foo as a) as b`, both names to the same scrutinee):
    allowed, handled by recursive elaboration with no special cases.
  - As-patterns inside destructuring-`let` components (`let (a, (Just x) as w) = e`):
    **not** added here. `checkComponentPat` already restricts those components to a
    bare variable or `_`; an as-pattern hits that existing "use `case`" rejection. That
    pre-existing limitation is left untouched (out of scope for this slice).
- **Elaboration mechanism:** a native typed node `TPAs Text (Tpat a)` (NOT a surface
  desugar — the surface can't name a nested sub-scrutinee). Threaded through both
  elaboration paths and the decision-tree compiler.

## 3. The pattern pipeline (what changes, in order)

Patterns flow: grammar/`Abs` → `inferPat`/`inferAtomPat` (`Infer.hs`, produces typed
`Tpat`) → two consumers in `Elaborate.hs`: the old `elabPatF`/`elabParam` path **and**
`toMPat`, which feeds the `Wok.IR.Match` decision-tree compiler (multi-clause functions
go through Match — this is why the headline example needs Match support).

1. **Grammar (`grammar/Wok.cf`):**
   - Add `APAs. AtomPat ::= AtomPat "as" VarId ;` alongside the other `AtomPat` rules.
     (`"as"` auto-becomes a reserved token; `VarSym` is untouched, so `@` stays an
     operator char and the `@@` fixture is unaffected.)
   - Regenerate (`bnfc --haskell -d -p GeneratedParser --text-token -o src-generated
     grammar/Wok.cf`), then **reapply the THREE manual patches** documented at
     `grammar/Wok.cf:13-69` (Layout.hs separator split; Par.y left-recursive
     `NEListRecordFieldPat`; Par.y empty-record `ConId '{' '}'`).
   - **Confirm the shift/reduce conflict count is UNCHANGED.** If it rises
     unexplainably, STOP and report (do not ship unexplained conflicts).

2. **Typed AST (`src/Wok/TypeChecking/Typed.hs`):** add `TPAs Text (Tpat a)` to
   `TpatF` (name + inner pattern). The `deriving (Functor, Foldable, Traversable)` must
   continue to cover it.

3. **Inference (`src/Wok/TypeChecking/Infer.hs`):** in `inferAtomPat`, handle
   `Abs.APAs inner (Abs.VarId (_, name))`:
   - infer `inner`, yielding `(ty, innerBinds, innerNode)`;
   - the as-name has the inner pattern's type: return binds `(name, ty) : innerBinds`;
   - return node `Ty.Tpat ty (Ty.TPAs name innerNode)`.
   No new unification — the as-name is just another binding at the inner type.

4. **Elaboration — old case path (`src/Wok/IR/Elaborate.hs`):**
   - `elabPatF` gets a `TPAs name inner` case: bind `name` to the current scrutinee
     atom (a let, as `TPVar` does at line ~639), then elaborate `inner` against the
     **same** scrutinee for the continuation. The as-binding is irrefutable; refutability
     is entirely the inner pattern's.
   - `elabParam` (function/lambda binders): a top-level `TPAs name inner` binds `name`
     to the parameter atom, then continues binding `inner`.

5. **Elaboration — decision-tree path:**
   - `toMPat` (`Elaborate.hs`): translate `TPAs name inner`. `Match.MPat` has no
     as-node today, so add one — see step 6.
   - `Match` (`src/Wok/IR/Match.hs`): add `MAs Text MPat` to `MPatF`. In the matrix
     operations, an `MAs v p` in a column records the binding `v -> <occurrence atom for
     that column>` and then behaves as `p` for matching (column selection, specialize,
     default, and the per-row binding collection at line ~85). Concretely: when a row's
     column is `MAs v p`, add `(v, scrut_i)` to that row's bindings and replace the
     column entry with `p` before the usual dispatch. This keeps the heuristic and
     specialize/default logic unchanged for the inner pattern; the as-node only adds a
     binding. `isWildP`/`mpatType`/`nubHeads` must see through `MAs` to its inner.

## 4. Testing (TDD; front-load the grammar risk)

Order mirrors the risk:

1. **Grammar/`as`-token first.** After the grammar change + patch reapply + conflict-count
   check, add parse-level tests (or smallest runnable `.wok` files) that confirm:
   `(Just x) as whole`, `(x :: xs) as whole`, `x as y`, `foo as a as b` parse; bare-var
   binds, function-LHS (`f x = …`, `(+) x y = …`, infix `x + y = …`), destructuring-let,
   and existing operators (`++`, `||`, `$`, the `@@` cross-fixity fixture) still
   parse/run.
2. **Headline example.** `dedupHead` (multi-clause, Match path) compiles and runs;
   `--run` produces the expected list and `--dump-anf` shows the as-name reused, not a
   rebuilt value.
3. **Each position.** case arm, single-clause function arg, lambda binder, nested
   as-pattern, `var as var`.
4. **Rejection.** as-pattern in a destructuring-let component still reports the existing
   "use `case`" message (unchanged behaviour).
5. **Full suite.** `cabal test` (587 green today) plus any new goldens
   (`cabal run wok-tests -- --accept`, read diffs before accepting).

Build/run: `cabal build`; `cabal test`; `cabal run -v0 wok -- <file.wok> --run` /
`--dump-anf`.

## 5. Risks

- **Grammar conflicts (primary).** The left-recursive `AtomPat "as" VarId` could change
  the LALR conflict count or interact with `LHSInfSym. FunLHS ::= AtomPat VarSym AtomPat`
  (infix function-def LHS). Mitigation: build the grammar change first, in isolation;
  confirm the conflict count is unchanged and the infix-def / function-LHS /
  destructuring-let forms still parse before writing any elaboration code. Stop and
  report if conflicts rise unexplainably. (Lower risk than the dropped `@`-reservation
  route: no `VarSym` lexer-class change, no fixture migration.)
- **Match matrix correctness.** The as-binding must be collected on every path the
  column can take (specialize hit, default, and the variable-row case). Mitigation: the
  `MAs`-strips-to-inner-plus-binding rule is applied uniformly at the point each matrix
  op reads a column; covered by the headline + nested tests.

## 6. Out of scope (do not build here)

- Tagged effect instances — the next slice (row-system change). Surface will be the
  named-capability binder `with count = state 0 in … count.get` (Design 2), not `@`.
- `Num` class / polymorphic literals — deferred pending the number-system design. `@` is
  earmarked for the visible type application (`e @Type`) that disambiguates its
  return-type-dispatched methods.
- Widening destructuring-`let` components to accept rich patterns (incl. as-patterns).
