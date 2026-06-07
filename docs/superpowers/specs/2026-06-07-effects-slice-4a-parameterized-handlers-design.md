# Effects Slice 4a: parameterized handlers + `with … in` runner sugar + `Std.Control`

Date: 2026-06-07
Status: Design converged (extended brainstorming + empirical pressure-testing on the
live compiler). Implements **slice 4a** of
`docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md`.
Reads with: `2026-06-05-effect-handler-surface-syntax.md` (§1 State ops, §5 auto-resume /
bind-to-control, §6 value arms), `2026-06-06-effects-slice-3-bounded-handlers-design.md`
(§2/§3 the CEK runtime, the deep `VCont` re-install + answer-join rebind this slice
extends), `docs/koka.md` (§"Parameterized handlers", §"Handler typing rule", value
restriction).

## 1. Summary

Slice 4a makes `State` (and any "carry a value the handler reads/updates") a clean,
composable effect, by adding **parameterized handlers**: a handler carries a local
parameter threaded through `resume`. It ships three things:

1. **The mechanism** — a handler may declare a local parameter with an initial value, as a
   `name = init` entry inside the handler block (`with State { s = 0 ; … }`); operation arms
   read the current parameter, and a resuming arm supplies the next parameter via a
   **two-argument resume** `resume(newParam, result)`.
   Auto-resume threads the parameter unchanged; only a parameter *change* takes control.
2. **The terse surface** — a `with <runner> in <body>` sugar that scopes a runner function
   over the rest of the block, desugaring to `<runner> (\_ -> <body>)`. It removes the
   thunk at the use site and is coherent with `let … in`. Stacking is per-line, mirroring
   nested `let … in`.
3. **`Std.Control`** — a second embedded prelude shipping the mtl workhorse stack as four
   flat handlers (`Reader`, `Writer`, `State`, `Except`) plus their runners. `State`/`Writer`
   exercise the parameterized mechanism; `Reader`/`Except` are non-parameterized completers.

The concurrency half of `Std.Control` (`spawn`/`par`/`Future`/scheduler) stays deferred to
slice 4b.

## 2. Motivation — grounded, and corrected

Three pains, reproduced on the live compiler:

- **Arity wall.** The natural answer-type encoding `get k -> \s -> k s s` is illegal — `k s s`
  saturates to a two-argument call and `VCont` is strictly one-argument (`Machine.hs:116`
  → `ArityError`).
- **Verbose + unsafe.** The split workaround `get k -> \s -> let g = k s in g s` forces hand
  threading of `\s -> …` in every arm; dropping `s` silently loses state, with no lint.
- **Answer-type pollution.** The encoding makes the answer type `s -> a`, so the caller must
  write `(with …) s0` and `State` stops composing like `Ask`/`Choice`/`Exn`.

**Correction to the brief's stated motivation.** The brief claimed the split encoding
"returns 0 not 99." After the slice-3 delimiter fix it now returns the *correct* values
(99; and 205 on an increment case). So the motivation is not "wrong answers in isolation."

**The decisive evidence is composition.** With each runner implemented via the library
encoding (answer type `s -> …`, no new mechanism), stacking two parameterized handlers with
interleaved operations **silently loses the outer one's parameter** — proven both directions
on the live compiler:

| nesting (interleaved get/set/tell) | result | expected | verdict |
|---|---|---|---|
| `writer` outside, `state` inside | `((205, 105), [])` | `((205,105),[100,105])` | log lost |
| `state` outside, `writer` inside | `((205, [100,105]), 100)` | `((205,[100,105]),105)` | state lost |
| either handler alone | correct | correct | ok |

The encoding threads the parameter through a closure-valued *answer type*, and that closure
cannot reach across an intervening handler's continuation. A *real* parameterized handler
keeps the parameter in the **live `KHandle` frame**; when an outer handler resumes,
`findHandler`'s `above` re-prepends the *current* inner frame with its updated parameter, so
both thread correctly. **Parameter-in-the-frame composes; parameter-in-the-answer-type does
not.** This rules out the encoding as a foundation and is the core reason the mechanism must
be real.

## 3. Surface syntax

### 3.1 Parameterized handler (the definition primitive — NOT user-facing)

This is the form a *library author* writes once to define a parameterized handler (e.g. the
`state` runner in `Std.Control`). **Application code never writes it** — users only write the
`with … in` runner sugar (§3.2). It is the existing handler block (slices 1–3) with one new
kind of entry: a **handler-local parameter** declared as a `name = init` binding alongside
the arms.

```
effect State s = { get : s, set : s -> () }     -- unchanged (surface spec §1)

with State { s = 0              -- handler-local param `s`, seeded to 0 (a block entry)
           ; get     -> s       -- auto-resume: read param, thread it UNCHANGED
           ; set x k -> k x ()  -- control: resume(newParam = x, result = ())
           ; v       -> (v, s)  -- value arm: final value + final param
           }
body                            -- handled computation (rest of the block)
```

Rule:

> The local parameter is in scope in every operation arm (its **current** value) and in the
> value arm (its **final** value). **Auto-resume threads the parameter unchanged; to change
> it, take control and call `resume(newParam, result)`.** Reads (`get`) stay auto-resume;
> writes (`set`) take control.

The parameter name is **declared in the handler block** and freely chosen (`balance = 0`),
distinct from the effect's *type* parameter (`s` in `effect State s`, a type variable in a
different namespace). The seed is "the initial value provided to the handler," read like a
record field — not a mutable variable. A handler block may declare more than one parameter;
position within the block is irrelevant (it is a declaration, not an arm).

The two-argument resume order is `(newParam, result)`, matching Koka (koka.md:330-331,
`get → resume(s,s)`, `put(s') → resume(s',())`).

Grammar — one new handler-block entry, no new `with` production (works headerless or headed):

```
HParam. HandlerArm ::= VarId "=" Exp ;   -- seed entry; `=` distinguishes it from `->` arms
```

After a leading `VarId`, lookahead `=` selects `HParam`; `->` or an `AtomPat` selects the
existing unqualified arm `HUArm`; a `.` is the qualified arm `HArm` (which is `ConId`-led, so
no collision). The elaborator classifies each block entry as param / op arm / value arm.

### 3.2 `with … in` runner sugar (the terse use)

```
with state 0 in              state 0 (\_ ->
let a = State.get in    ≡        let a = State.get in
State.set (a + 1)                State.set (a + 1))
```

> `with <runner> in <body>` ≡ `<runner> (\_ -> <body>)`. The runner is any function whose
> last parameter is a `() -> a with …` computation; `with` captures the rest of the block,
> wraps it in the thunk, and supplies it as that final argument.

It is coherent with `let x = e in body` (introduce, then `in body`). The `in` delimiter is
load-bearing: it marks where the runner ends and the body begins, so the runner can be plain
juxtaposition (`state 0`) without fake-call parens. Stacking mirrors **nested** `let … in`:

```
with reader cfg in              reader cfg (\_ ->
with state 0 in           ≡       state 0 (\_ ->
with writer in                     writer (\_ ->
body                                 body)))
```

Top-to-bottom = outermost-to-innermost, matching the slice-1–3 stacking rule. Bounded scope
is `(with state 0 in e)`, parallel to slice-3's `(with { … } e)`.

Grammar:

```
EWithRun. Exp2 ::= "with" Exp1 "in" Exp ;   -- runner is Exp1 (an application); body is Exp
```

The runner is restricted to `Exp1` (application) so a runner can never itself contain a
top-level `let … in`/`with … in` whose `in` would race the sugar's `in`.

**Not available: a `let`-style indentation block for `with`.** `let`'s multi-binding block
relies on `let` being a *layout keyword*; `with` cannot be one without breaking the
type-level `with E` in signatures (grammar `Wok.cf:363-366`), and explicit `with { … }`
braces already mean handler arms. So multiple handlers stack as multiple `with … in` lines
(coherent with nested `let … in`); there is no single-`in` block form. A `;`-separated block
was considered and rejected (introduces `;` into expression position for marginal gain).

The brace forms (`with { arms } e`, `with E { arms } e` — now with the optional `name = init`
param entry inside the block) keep their `}`-delimited bodies and stay `in`-free; only the
brace-less runner form takes `in`.

### 3.3 The mtl quartet, terse (`Std.Control`)

```
module Std.Control
import Std.Base

-- Reader: read-only env (non-parameterized; capture)
effect Reader r = { ask : r }
reader : r -> (() -> a with Reader r + eff e) -> a with eff e
reader e c = with Reader { ask -> e } c ()

-- State: threaded cell (PARAMETERIZED)
effect State s = { get : s, set : s -> () }
state : s -> (() -> a with State s + eff e) -> (a, s) with eff e
state i c = with State { s = i ; get -> s ; set x k -> k x () ; v -> (v, s) } c ()

-- Writer: append-only log (PARAMETERIZED; list-specialized — see §7)
effect Writer w = { tell : w -> () }
writer : (() -> a with Writer [w] + eff e) -> (a, [w]) with eff e
writer c = with Writer { log = [] ; tell w k -> k (log ++ w) () ; v -> (v, log) } c ()

-- Except: abort with an error (non-parameterized; reshape to Result)
effect Except e = { throw : e -> Never }
except : (() -> a with Except e + eff r) -> Result a e with eff r
except c = with Except { throw e k -> Err e ; v -> Ok v } c ()
```

Application code never writes handler arms:

```
import Std.Control
main =
  with reader cfg in
  with state 0 in
  let a = State.get in
  State.set (a + 1)             -- main : ((), U64)   (the (value, finalState) pair)
```

One runner per effect: there is no `eval`/`exec` pair. `state` returns the full
`(value, finalState)` pair, and projecting out just the value or just the state is done at
the call site with a destructuring `let` — e.g. `let (a, _) = state init c in …` for the
value, `let (_, s) = state init c in …` for the state. That destructuring `let` is a small
separate addition (not `fst`/`snd` on `Std.Base`), keeping the prelude to one runner per
effect.

### 3.4 Tuple destructuring-`let` (shipped as a small additive feature)

Because each effect has exactly one runner returning a `(value, finalState)` pair (no
`eval`/`exec` split), projecting out just the value (or just the state) needs a destructuring
`let` so the prelude does not have to also ship `fst`/`snd`: `let (result, _) = state 100 prog in result`.
This shipped as a tuple-only destructuring-`let`, grammar form
`LDPat. LocalDecl ::= "(" Pat "," [Pat] ")" "=" Exp` (zero added parser conflicts; bare-var and
top-level defs are unchanged). Refutable/constructor patterns and `where`-block pattern binds
are out of scope — use `case` for those.

## 4. Typing — stays in HM

- Param entry `s = init`: `init : σ`, binder `s : σ`, with `σ` unified against the effect's
  state parameter (`State σ`).
- `get : s` (= σ): auto-resume body type = σ. ✓
- `set : s -> ()`: control arm, **`resume : σ -> () -> R`** — one extra *leading* arrow over
  slice-1's `resume : T -> R`. The implementation allocates a *fresh open effect row* on the
  leading `σ ->` arrow (like the second arrow), not a closed/pure one — benign and strictly
  more permissive, since a partial application `resume x` emits nothing into it; the second
  arrow likewise carries a fresh open `resumeRow` (as in slice 1, so applying `k` flows its
  effects to the outer ambient). `k x ()` : R. ✓
- Auto-resume desugars to `resume(s, body)`, so it too is typed at `σ -> T -> R`.
- Value arm: `s : σ` in scope, `v : A`; `(v, s) : (A, σ)` ⇒ answer `R = (A, σ)`.

The parameter is a monomorphic threaded value; `resume` gains one arrow. Nothing higher-rank,
no first-class handler — handlers stay second-class, inference stays HM + row unification.

## 5. Lowering + runtime

The parameter lives in the handler's captured scope `hsc` (the slice-3 lever).

1. **`Wok.IR.Anf` — `Handler`:** add `hParam :: Maybe Binder` (`Nothing` = ordinary handler).
   Update `collectHandler` (free-var/hint collection) and `renderHandler` (metadata; no
   behavioural change).
2. **`Wok.IR.Elaborate` — `THandle`:** classify the `HParam` block entry as the handler's
   parameter; lower `with State { s = init ; … } comp` to
   `let s = init in Handle comp (Handler ret ops answerJoin (Just s_binder))`, so the
   `KHandle h sc k` pushed at `Machine.hs:71` captures `sc` with `s := init`. Auto-resume arm
   lowering passes the current parameter: `op … -> body` becomes
   `let res = resume(<paramBinder>, body) in deliver res` (two-argument application). The
   control branch is unchanged (the arm already calls `k` explicitly).
3. **`Wok.Interp.Value` — resume value:** add `VContP (Value -> Kont -> Kont)`, a
   parameter-aware continuation. `enter (VContP f) [param, result] k = Return result (f param
   k)`; any other arity errors.
4. **`Wok.Interp.Machine` — `dispatchOp`:** for a parameterized handler build

   ```haskell
   resumeVal = VContP (\newParam after ->
     let hsc' = hsc { scEnv  = bindBinder pb newParam (scEnv hsc)        -- NEW: param rebind
                    , scJoins = <slice-3 answer-join rebind to `after`> }
     in above (KHandle h hsc' after))
   ```

   The parameter rebind (in `scEnv`) and the slice-3 answer-join rebind (in `scJoins`) are
   independent edits to `hsc'` and compose. Non-parameterized handlers (`hParam = Nothing`)
   keep the slice-3 one-argument `VCont` and are byte-for-byte unchanged. The value arm runs
   via `returnTo (KHandle h hsc k)` under the last-installed `hsc`, so it sees the final
   parameter.

Why nesting composes (traced — `state` outside, `writer` inside, the case the encoding got
wrong):

```
State.get        resume(s=100,100)   kont: Writer[log=[]]   :: State[s=100] :: after   a=100
Writer.tell[100] resume(log=[100],()) kont: Writer[log=[100]] :: State[s=100] :: after
State.set 105    resume(s=105,())    kont: Writer[log=[100]] :: State[s=105] :: after   <- Writer frame preserved
State.get        105                                                                    b=105
Writer.tell[105] log -> [100,105]
return 205    -> Writer arm (205,[100,105]) -> State arm ((205,[100,105]),105)   CORRECT
```

Each resume creates a fresh `KHandle` frame with the updated parameter in the live kont;
subsequent `findHandler`/`above` capture the live frame, so an outer resume re-installs the
inner handler with its current parameter.

The `with … in` sugar is a pure elaboration desugar (`<runner> (\_ -> <body>)`); no runtime
change.

## 6. `Std.Control` as a second embedded prelude

`Std.Base` is embedded today (`prelude/Std/Base.wok` shipped as a cabal data-file, read by
`Wok.Prelude.preludeSource`, inserted into the module map before user files in
`Loader.hs:74-78`). `Std.Control` mirrors that:

- add `prelude/Std/Control.wok`,
- add a `controlWokSource` accessor in `Prelude.hs` (a second `getDataFileName`),
- insert it in `Loader.hs` (`preludeLM : controlWokLM : extraLMs ++ [entryLM]`),
- list it in `wokml.cabal` data-files.

The loader already topo-sorts imports, so `Std.Control` importing `Std.Base` (for `+`, `++`,
`Option`, `Result`) works without new module-system machinery.

## 7. Scope

In scope (slice 4a):

- Parameterized handler mechanism: grammar `HParam` (the `name = init` block entry), `hParam`,
  two-argument `VContP` resume, param rebind on the slice-3 re-install, auto-resume
  parameter-pass desugar, typing `resume : σ → T → R`.
- `with … in` runner sugar: grammar `EWithRun`, the `<runner> (\_ -> <body>)` desugar, the
  bounded `(with … in e)` form.
- `Std.Control` prelude with the mtl quartet (above) + loader/cabal embedding.
- Goldens: the nested-composition matrix (§5), single State/Writer, the migrated surface-spec
  §1 `State` example as a real runner, the combined mtl demo, the single `state` runner
  returning the `(value, finalState)` pair (projection via a destructuring `let`, not
  eval/exec runners), bounded form, `--dump-anf` for the parameter lowering. Negatives: swapped-arg type error,
  the forgotten-resume lint catching a dropped `k` in `set`.

Out of scope (deferred, each forward-compatible):

- **Concurrency half of `Std.Control`** (`spawn`/`par`/`Future`/scheduler) — slice 4b.
- **Named handler declarations** (`with state(0)` referencing a *predefined* handler with no
  thunk and no arms). The `with … in` sugar already gives no-thunk reuse; a true handler-alias
  decl is a separate ergonomic layer. Forward-compatible: composes with the in-block param.
- **Tagged / multiple instances** of one effect (`State@balance`, `State@cursor`) — the
  `inject`/duplicate-label family, a standing non-goal. Multiple states today = one `State`
  over a record with field access as the lens. Eventual full spelling
  `with State@tag { s = i ; … }` composes with the in-block param form.
- **General-`Monoid` `Writer`** — needs a `Monoid` class (only `Eq` exists). 4a ships the
  list-specialized `Writer` (a concrete monoid, and a clean second parameterized-handler
  test).
- **Positional / unnamed seed** (e.g. `with State { 0 ; … }`, name defaulted from the type
  parameter) — deferred; the named `name = init` entry is primary because the arms must refer
  to the parameter by name and a defaulted name collides on effects like `Writer`
  (`k (w ++ x)` vs `k (log ++ w)`).
- **Multiple params per handler block** — the `HParam` grammar allows several `name = init`
  entries; 4a tests and uses a single param (State/Writer). More than one is permitted by the
  grammar but not a 4a deliverable to exercise.

Rejected (with reasons, so they are not relitigated by accident):

- **Library-encoding runners** (answer type `s -> …`, no new mechanism) — empirically does not
  compose across stacked handlers (§2 table). Dead.
- **`let`-style indentation block for `with`** — `with` can't be a layout keyword (§3.2).
- **`with f(args)` parenthesized sugar** — reads as a function call; superseded by `with … in`.

## 8. Goal alignment (cross-cutting invariants)

- **Decidable** — parameter is a threaded value; `resume` gains one arrow; handlers stay
  second-class. HM + row unification, no new type-system feature.
- **Deterministic** — immutable functional threading, never a mutable cell → no `ndet`. This
  is why the value restriction stays deferred to slice X (koka.md:235/454: functional
  parameter-threading is sound without it).
- **Effect handlers are the one mechanism** — `State`, `Writer`, `Reader`, `Except` are four
  handlers, no transformer plumbing, no `lift`. The mtl stack collapses to flat handlers and
  the stack order (reorder the `with … in` lines) reproduces transformer-order semantics
  (e.g. keep-vs-lose the log on a `throw`).
- **Analysis over annotation / keyword-light** — new surface is the `name = init` block entry
  and the `with … in` delimiter. Reads stay auto-resume; the write-takes-control cue is the
  existing binder rule. Justified, minimal.

## 9. Risks (front-load these in the plan)

1. **Nested different-effect composition (highest).** The `state`-outside-`writer`-inside case
   (and the swap) must thread *both* parameters correctly under the real mechanism — this is
   exactly where the encoding failed. It is the TDD anchor: write it first, prove the
   mechanism against it before any sugar or prelude work. (Distinct from the deferred §12
   same-effect deep-re-entrant-multishot limitation; this is single-resume, different effects,
   and must work.)
2. **Dangling-`in` layout behaviour.** `with … in` introduces an `in` where no `let` block is
   open; BNFC's `layout stop "in"` must pass it through to the `EWithRun` production rather
   than mis-closing or erroring. Verify against the layout filter and re-verify after the
   grammar regen. Fallback if it bites: the parenthesized `with f(args)` form (layout-safe).
3. **Grammar regen + conflicts.** `HParam` (a new handler-block entry) and `EWithRun` (the
   `with … in` runner form) are the two grammar changes; after `bnfc … && reapply the two
   manual patches`, confirm the shift/reduce conflict count is unchanged, that the `HParam`
   `VarId "=" …` vs `HUArm` `VarId … "->" …` choice is a clean shift, and that the runner form
   disambiguates from the brace handler forms after `with` (`{`/`ConId{` handler vs `Exp1 in`
   runner).
4. **`hParam` consistency.** Free-var/hint collection (`collectHandler`) and the printer must
   track the new field or the round-trip/`--dump-anf` goldens drift.

## 10. Workflow

TDD; front-load risk 1 (nested composition) and risk 2 (layout). Build order: mechanism
(runtime + typing + the `HParam` block entry) proven against the nested matrix → `with … in`
sugar → `Std.Control` + loader embedding → goldens + docs. Full-branch review before any merge to
main. `cabal build`; `cabal test`; `cabal run -v0 wok -- <file> --run | --dump-anf`;
`cabal run wok-tests -- --accept` (read diffs first). After any grammar change:
`bnfc --haskell -d -p GeneratedParser --text-token -o src-generated grammar/Wok.cf`, reapply
the two manual patches (`grammar/Wok.cf:13-56`), confirm the conflict count.
