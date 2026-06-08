# Expressing the multi-shot notion under one-shot-as-law

wok makes effect handlers **one-shot**: an arm may resume its continuation *at most
once*, and a handler that resumes twice is a compile error (see
`superpowers/specs/2026-06-09-one-shot-multiplicity-analysis-design.md`). The obvious
worry is expressiveness — multi-shot handlers are how you write backtracking,
nondeterminism, and probabilistic inference. This note is about the *thinking* that
shows none of that power is actually lost; only the *idiom* changes.

The three runnable companions: `examples/generators.wok`, `examples/nondeterminism.wok`,
`examples/probabilistic.wok`.

## The puzzle

A multi-shot resume means "run the rest of the computation **more than once**, with
different inputs, and combine the results." The canonical illegal handler:

```
-- COMPILE ERROR under one-shot-as-law: resumes k twice.
with { Choice.flip k -> k True ++ k False }
```

`k` is *the rest of the computation after `flip`*. Resuming it with `True` and again
with `False` runs that remainder twice and concatenates. If you can only resume once,
how do you get both runs?

## The key idea: control/data duality

Multi-shot resumption is **branching expressed as control** — the handler reaches back
into the future and forks it. Its dual is **branching expressed as data** — you carry
*all the branches at once* in a value. The two are interchangeable, and the value form
is just a list:

> A multi-shot continuation, made explicit, **is** a list-returning function.
> Resuming it N times **is** mapping it over N inputs and concatenating.

Read the illegal handler again with that lens. `k` is "the rest of the computation,"
i.e. a function `rest : Bool -> [Answer]`. Then:

| Multi-shot handler (control) | Explicit list (data) |
|---|---|
| `k a` (resume once) | `rest a` |
| `k a ++ k b` (resume twice) | `concatMap rest [a, b]` |
| abort: bind `k`, never call it | `[]` |
| `flip k -> k True ++ k False` | `flip choices = concatMap rest choices`, `choices = [True, False]` |

The multi-shot handler was *implicitly* building a list of all outcomes by forking
control. Writing that list explicitly is the whole translation. This is why "the list
monad is reified multi-shot" is literally true, not a slogan — the runtime of a
multi-shot handler would build the very same list internally.

`examples/nondeterminism.wok` is exactly this. The illegal

```
do { a <- choice [1..n]; b <- choice [1..n]; guard (a + b == target); pure (a, b) }
```

becomes a nest of `concatMapL` over explicit ranges, with `[]` for "guard failed" and
`[(a, b)]` for "succeeded":

```
concatMapL (\a ->
  concatMapL (\b ->
    case a + b == target of
      True  -> [(a, b)]      -- a successful branch
      False -> [])           -- a pruned branch (the 0-shot case)
    (range 1 (n + 1)))
  (range 1 (n + 1))
```

`solutions 6 7` → `[(1, 6), (2, 5), (3, 4), (4, 3), (5, 2), (6, 1)]`. Every branch the
multi-shot handler would have explored by re-resuming is now an element the list
carries. `concatMapL`'s `\a -> ...` lambda **is** the continuation `k` made first-class.

## Probabilistic programming: multi-shot *with a measure*

Probabilistic inference is multi-shot where each branch additionally carries a *weight*
(a probability mass). The data form is a list of `(value, weight)` pairs — a
distribution — and the probability monad's `bind` is `concatMap` that **multiplies
weights** (independent draws compound):

```
bindD d f =
  concatMapL (\p -> let (x, w) = p in
    concatMapL (\q -> let (y, w2) = q in [(y, w * w2)])   -- weights multiply
      (f x))
    d
```

`examples/probabilistic.wok` builds the distribution of the sum of two fair dice and
reads off `P(sum == 7)`:

```
twoDiceSum = bindD die (\a -> bindD die (\b -> [(a + b, 1)]))
main = (weightOf 7 twoDiceSum, totalWeight twoDiceSum)   -- (6, 36)  ==  6/36 = 1/6
```

This is genuine inference — the joint distribution is enumerated and the event measured
— with no multi-shot handler anywhere. A multi-shot `sample` effect would have produced
the identical weighted enumeration by forking control; the weighted list just *names*
it. The same shape gives you parser combinators over ambiguous grammars (a list of all
successful parses) — same `concatMap`, different payload.

## The false multi-shot: generators are one-shot

A frequent confusion is that generators/streams "produce many values," so they must be
multi-shot. They are not. Each `yield` resumes its continuation **exactly once**; the
"many" comes from the producer's *own recursion*, not from re-resuming one continuation.
So generators remain ordinary effect handlers under the law. `examples/generators.wok`:

```
effect Yield = { yield : U64 -> () }

count lo hi = case lo == hi of                 -- the producer's loop drives "many"
  True  -> ()
  False -> let u = Yield.yield lo in count (lo + 1) hi

with { Yield.yield x k -> [x] ++ k () ; v -> [] }    -- one resume per yield -> 1-shot
count 1 7                                            -- => [1, 2, 3, 4, 5, 6]
```

`wok examples/generators.wok --dump-multiplicity` reports `Yield.yield : 1` — a legal
one-shot handler, not a workaround. Async/await and concurrency are the same story: a
parked continuation is resumed once, later (escaping-one-shot), so they stay one-shot
too; the OS's push/many-events is absorbed by a runtime queue *below* the effect
boundary and re-exposed as a one-shot pull.

## Why give up the multi-shot handler at all?

Two payoffs, and they are the reason the law is worth the idiom change:

1. **Soundness for free.** A re-resumed continuation can re-run a computation that
   captured mutable state and re-observe it at a different type — the classic
   polymorphic-reference unsoundness, which normally forces a *value restriction*. The
   explicit-list form is pure data: it cannot re-observe anything. No multi-shot → no
   hazard → **no value restriction needed**.
2. **A simpler, faster backend.** One-shot continuations compile to direct-style jumps
   (contification); the copyable/persistent multi-shot representation is never built.

## When to reach for which

- **Effect handler (one-shot):** sequential effects — state, reader, writer, exceptions,
  generators, async, concurrency. The control idiom is terser and composes through the
  effect row.
- **Explicit `List` / weighted `List`:** branching search, nondeterminism, probabilistic
  inference, ambiguous parsing. The data idiom is slightly more verbose, but it is
  ordinary pure values — and it is exactly the structure a multi-shot handler would have
  built for you anyway.

The slogan: **one-shot-as-law doesn't remove multi-shot expressiveness; it asks you to
name the branching structure as data instead of conjuring it from control.** Everything a
multi-shot handler computed, an explicit list computes — soundly, and without a value
restriction.
