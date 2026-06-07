# wok examples

Five runnable programs, smallest to largest. Each is a complete module with a
`main`; run any of them with the `--run` flag:

```sh
cabal run -v0 wok -- examples/<file>.wok --run
```

(Drop `-v0` to see cabal's build chatter; add `--dump-anf` instead of `--run`
to see the lowered intermediate representation.)

| File | Shows | `--run` output |
|------|-------|----------------|
| `collatz.wok` | pure recursion (no effects) | `111` |
| `state-accumulate.wok` | `State` + recursion + tuple destructuring `let` | `31` |
| `expr-eval.wok` | recursion over a tree + `Writer` + `Except` | `Ok((11, [20, 23, 11]))` |
| `mtl-machine.wok` | the full mtl stack: `Reader` + `Writer` + `State` + `Except` | `Ok(((4, 30), [10, 30]))` |
| `as-patterns.wok` | `as`-patterns (`pat as name`) in a case arm, a single-clause head, and a multi-clause function | `[8, 5, 6, 7]` |

Run them all:

```sh
for f in collatz state-accumulate expr-eval mtl-machine as-patterns; do
  printf '%-18s ' "$f"
  cabal run -v0 wok -- "examples/$f.wok" --run
done
```

## What to look at

- **`collatz.wok`** — `case n == 1 of …` recursion. The language has equality
  (`==`/`/=`) but no ordering, so branching is done on equality and `mod`.
- **`state-accumulate.wok`** — `state 0 comp` runs a `State` computation and
  returns a `(value, finalState)` pair; `let (_, total) = … in total` projects
  the part you want without a `fst`.
- **`expr-eval.wok`** — an `Expr` tree evaluated recursively; `Writer` logs each
  intermediate result and `Except` aborts on divide-by-zero (try changing the
  divisor to `Lit 0` to see `Err(...)`).
- **`mtl-machine.wok`** — four handlers stacked flatly with `with … in`
  (top-to-bottom = outer-to-inner). `Reader` supplies a multiplier, `State`
  holds a running total, `Writer` records snapshots, `Except` would abort the
  whole run (swap in a `Boom` command to see `Err(...)`). The result nests as
  `Result ((count, finalState), log) String` — the shape mtl transformer stacks
  give you, minus the transformers.
- **`as-patterns.wok`** — `pat as name` (name last) matches a structure AND binds
  the whole value. `keepNonEmpty` returns the matched list via `whole` without
  rebuilding it; `doubleUp n as m` is an irreducible `var as var` head; `dedupHead`
  is a multi-clause function that collapses leading duplicates. `::` is pattern-only
  in wok, so the expressions build lists with `[...]` and `++`.
