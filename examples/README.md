# wok examples

Thirteen runnable programs, smallest to largest. Each is a complete module with a
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
| `named-instances.wok` | named effect instances — two independent `State U64` cells, handle-typed helper params | `(((), 105), 0)` |
| `generators.wok` | a generator/stream as a **one-shot** handler (`once yield x k -> [x] ++ k ()`) | `[1, 2, 3, 4, 5, 6]` |
| `coroutine.wok` | one-shot escaping continuation: `start` returns a `Step`, `case` on `Completed`/`Suspended`, `run`/`step`/`cancel` an opaque second-class affine `Suspension` | `421` |
| `generators-pull.wok` | **pull**-model generator: the consumer drives, `step`ping a `Suspension` and `case`ing each `Step` (contrast the push `generators.wok`) | `15` |
| `pull-take.wok` | consumer-driven early termination: take the first `n` values then `cancel` the parked remainder | `3` |
| `pull-zip.wok` | zip two live producers in lockstep — holding two `Suspension`s at once, which the closed `Step` ADT (arm-bound tail, no closure capture) makes type-check | `52` |
| `nondeterminism.wok` | backtracking search via explicit `List` (the list monad = reified multi-shot) | `[(1, 6), (2, 5), (3, 4), (4, 3), (5, 2), (6, 1)]` |
| `probabilistic.wok` | probabilistic programming via a weighted-`List` distribution monad; `P(sum == 7)` for two dice | `(6, 36)` |

The last three show how the **multi-shot** use cases (backtracking, probabilistic
inference, generators) are expressed under wok's one-shot-handler law. The thinking
behind that — the control/data duality, "the list monad is reified multi-shot" — is
written up in [`../docs/expressing-multishot-under-one-shot.md`](../docs/expressing-multishot-under-one-shot.md).

Run them all:

```sh
for f in collatz state-accumulate expr-eval mtl-machine as-patterns named-instances generators coroutine generators-pull pull-take pull-zip nondeterminism probabilistic; do
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
- **`named-instances.wok`** — multiple reachable instances of one effect. `with
  count = state 0 in …` introduces a named instance; you perform through the name
  (`count.get`). The instance's type IS the effect (`State U64`); the dot resolves
  by type (handle → perform, record → project). `sumProd` is the clincher — two
  `State U64` cells told apart by name alone. Handles are second-class (scoped,
  can't escape their `with`).
- **`generators.wok`** — a generator is **one-shot**, not multi-shot: each
  `once Yield.yield x k -> [x] ++ k ()` resumes once, and the producer's recursion
  (`count`) drives the "many." `--dump-multiplicity` reports `Yield.yield : 1`, so it
  is a legal handler under the one-shot law.
- **`generators-pull.wok` / `pull-take.wok` / `pull-zip.wok`** — the **pull** model,
  where the *consumer* drives instead of a handler reacting. `start` runs the producer
  to its first suspension and returns the first `Step`; the consumer `case`s
  `Suspended x g` / `Completed r` and calls `step g ()` to pull the next. `pull-take`
  shows consumer-driven early termination (`cancel` the unused remainder); `pull-zip`
  shows the payoff over a single push handler — driving two producers at once, holding
  two `Suspension`s, which works because the tail binds in a `case` arm rather than a
  closure.
- **`nondeterminism.wok`** — the multi-shot handler `once flip k -> k True ++ k False` is a
  compile error, so backtracking is written explicitly with `List`. `concatMapL`'s
  lambda is the continuation `k` made first-class; `[]` is the pruned (0-shot) branch,
  `[(a, b)]` a successful one. The list monad *is* reified multi-shot.
- **`probabilistic.wok`** — probabilistic inference as weighted nondeterminism: a
  distribution is `[(value, weight)]`, and `bindD` is `concatMap` that multiplies
  weights across independent draws. Computes `P(sum == 7)` for two fair dice as
  `(6, 36)`. No multi-shot handler — the weighted list *names* the branching a
  multi-shot `sample` would have forked.

See [`../docs/expressing-multishot-under-one-shot.md`](../docs/expressing-multishot-under-one-shot.md)
for the conceptual walkthrough of why these encodings recover full multi-shot
expressiveness under the one-shot-handler law.
