# Rejected designs, as programs (D19)

Each entry is a COUNTERFACTUAL: the rejected design written in the syntax it
would have had, exhibiting the failure that rejected it. None of this is v2
syntax — these files' programs must never be ported into examples/ as
conformance. The bar this ledger enforces (D19): no new passing or
resolution mechanism lands without a program the existing set cannot
express; no form is removed without a nameable trap it enables.

## Bucket A — rejected additions (ways to pass or resolve)

### A1. Positional capability arguments (rejected in C1)

```
sumProd : State U64 -> State U64 -> [U64] -> ()
main = handle a = state 0 in handle b = state 1 in
       sumProd b a [1, 2, 3, 4]        -- arguments SWAPPED
```
Type-checks perfectly (both are `State U64`); sums land in the product cell.
No diagnostic is possible, ever: positions are invisible to types.

### A2. Type-keyed resolution (rejected in C1)

```
sumProd : [U64] -> () with {State U64, State U64}
```
A set keyed by type collapses the two entries into one; the language's own
clincher example is inexpressible. Plus instantiation-order coherence
hazards in polymorphic code (the C1-d ghost).

### A3. Call-site row binding

```
bumpAmbient () with State = to        -- term-level `with` (breaks D1)
use to as State in bumpAmbient ()     -- identical meaning, already exists
```
A second spelling of the rename; zero new programs expressible.

### A4. `as`-postfix install

```
handle makeInstrumentedState cfg (retryPolicy 3) as State
handle State = makeInstrumentedState cfg (retryPolicy 3)
```
The first buries the greppable name behind an arbitrarily long expression
and destroys the mtl stack's aligned label column; `grep "handle State"`
finds the second at column one.

### A5. Label polymorphism (the generic `run`)

```
run : Handler e a b -> (() -> a with e) -> b
run h c = handle ?? = h in c ()        -- what NAME gets bound?
```
The thunk's row must match SOME label; abstracting over the name is
resolution-by-type through the back door (A2 again).

### A6. Parameter-mutation batons (the double-install exploit — see C12)

```
state init = handler State
  get      -> init
  set x    -> init := x                -- mutate the captured parameter
  return v -> (v, init)

main =
  let h = state 0                      -- ONE handler value
  let (x, s1) = (handle h in State.set 1)
  let (y, s2) = (handle h in State.get)
  (s1, s2)
```
Shared `init` binding: (1, 1) — state leaks across activations of one
first-class value. With `var cur = init`: (1, 0). The var line is the
visible per-activation copy point. Conformance twin:
examples/accept/09-activation-independence.wok.

### A7. Var-elision sugar

Same surface as A6, with the compiler silently inserting the per-activation
copy. The program READS as shared mutation and RUNS as per-activation copy:
apparent semantics diverges from actual semantics — an E.3-class silence
installed on purpose.

### A8. `become` (self-replacing handlers)

```
state s = handler State
  get   -> s
  set x -> become (state x)     -- replace the activation's handler
```
Elegant (state = the handler's own parameter), but: a new keyword; the
activation's identity changes under a possibly-stored continuation (the
D15/M2b seam, where the UAFs have historically lived); and rc==1 reuse
compiles it back into the frame slot anyway. Bigger than the problem.

### A9. Singleton auto-designation (rejected by P1/P2 instantiation)

```
-- version 1: compiles; auto-resolves to the only State in scope
main =
  handle acct = state 100
  bumpAmbient ()

-- version 2: a colleague adds unrelated state
main =
  handle acct  = state 100
  handle debug = state 0
  bumpAmbient ()                -- error at a distance, or a silent tiebreak
```
The count cliff: meaning depends on a CENSUS of the scope, so a distant
edit breaks or silently reroutes working calls. P1 rejects it (an unwritten
binder with undelimited extent; census-derivable is not derivable); P2
names it (implicit slot assignment). Payoff audit: saves exactly one
written `use acct as State` line, in the one situation where that line is
the only text saying which cell serves the default vocabulary. Precedent
for the failure mode: Scala implicits' by-type-with-uniqueness resolution.

### A10. Brace-record rows (`with { from : State U64, to : State U64 }`)

```
with { State U64, log : Writer [String] }
--     ^^^^^^^^^ "why does one field have no name?"
```
Braces import record intuition — every member is named — which the DEFAULT
tier deliberately breaks: bare entries are slot obligations, nameless at
the surface. The intuition arrives and then misleads at exactly the seam a
newcomer must learn. Also: whole-row braces change every effectful
signature in existence (D20's parens touch ~15%), kill the current-wok
convergence claim, and require a new row-polymorphism tail syntax. D20's
parenthesized labeled entries deliver the targeted readability without the
false friend. (Braces are also this bundle's notation for the REJECTED
type-keyed set — A2.)

### A11. Callee-local names + uniqueness auto-resolution (implicit capability arguments)

The steelmanned hybrid of A9 and D13's rejected variant: every row entry
named, names CALLEE-LOCAL (alpha-convertible), callers auto-supply by type
when both sides are singletons, explicit naming only on multiplicity. It
genuinely repairs two recorded objections — the Schelling-point problem
(names no longer cross boundaries) and sumProd (explicit fallback). Four
killers survive:

```
-- caller count cliff (A9, unrepaired): an unrelated handle breaks
-- distant auto-supplied calls
handle acct  = state 100
handle debug = state 0        -- new, unrelated feature
report ()                     -- ERROR at a distance

-- NEW: callee interface cliff — a second same-typed entry makes the first
-- entry's name retroactively PUBLIC API
log : Msg -> () with (s : State Buf)                        -- s is local
log : Msg -> () with (s : State Buf) + (cache : State Buf)  -- s is now
--   interface (rule: multiplicity forces naming); every auto-caller breaks
--   and the author is stuck with a name chosen under local-name assumptions
```

Plus: greppability inverts — provider wiring becomes a type-checker
computation instead of text, the census-derivability P1 forbids — and the
C1-d coherence ghost returns at non-ground types. Migration: mandatory
naming changes 100% of effectful signatures. Salvage adopted instead: the
incumbent design already CONTAINS the fully-named style as an option (a
row label is a binder — spec 1.3), and uniqueness powers DIAGNOSTICS,
never meaning: with exactly one type-compatible label in scope,
E-AMBIENT's hint is definitive and mechanically applicable.

### A12. Abortness inferred from the op's return type (rejected in C13)

```
effect Except e
  throw : e -> Never       -- Never return: handler "obviously" cannot resume

except = handler Except
  throw e  -> Err e        -- INFERRED abort: no keyword, kind read off the type
  return v -> Ok v

-- the counterfactual that kills it: aborting a RESUMABLE op
effect Tick
  tick : U64 -> U64        -- resumable type; THIS handler chooses to abort

timeout = handler Tick
  tick n -> Err "deadline" -- is this a plain clause (auto-resume with the
                           -- body's value) or an inferred abort? The type
                           -- says resumable; the handler means abort. No
                           -- inference can see a CHOICE.
```

The clause kind is a per-handler choice, not a per-op property; inference
from the op type covers only the `Never` corner and silently mis-reads every
abortive handler of a resumable op as a plain clause — the S1 collapse
rebuilt one floor up. It also splits the register: kind-by-inference for
some clauses, kind-by-keyword for others, re-opening the
reconstructed-by-analysis reading this design exists to close. The type
fact survives as a lint: a `once` clause for a `Never`-returning op binds a
continuation typing already killed — suggest `abort`, never an error (D2).

### A13. Function-local `var` (Koka-style; rejected in C14)

```
-- (a) straight-line: var's only winning case -- D26 covers it with no mutation
readHeader b =
  var off = 0
  let magic = u32At b off
  off := off + 4
  ...
-- vs D26:  let off = off + 4      (a new VALUE; nothing mutates)

-- (b) loops: wok iterates via HOFs; the first real loop crosses a lambda
sumTo n =
  var acc = 0
  var i   = 1
  while (\_ -> i <= n) (\_ ->
    acc := acc + i        -- E-VARSCOPE: the write crosses a lambda boundary
    i   := i + 1)
  acc
-- allowing it means tracking the captured slot in the closure's type,
-- which IS the State effect: Koka's own var is sugar over a local state
-- row entry, so "function-local var done soundly" duplicates State with
-- the row hidden

-- (c) escape: untracked capture is unsound
counter : () -> (() -> U64)     -- the type claims PURE
counter u =
  var n = 0
  \_ -> n := n + 1              -- hidden state behind a pure type; the slot
                                -- secretly migrates to the heap
```

The design space has no fourth point: forbid capture and (a) is all that
remains (already covered by D26); track capture and the feature is State
with the row hidden — the D20-refused second spelling. One mutation home
(the handler frame, D27) keeps the pyramid teachable: values shadow,
effects mutate visibly, frames mutate privately.

### A14. `return` as the abort spelling (rejected in the C13 naming probes)

```
-- the unification that almost works: both clauses produce the final answer
except = handler Except
  return throw e -> Err e     -- on this op: the answer, now (C-style early exit)
  return v       -> Ok v      -- on completion: the answer (Koka-style transformer)

-- the killer: a NULLARY op makes classification name-dependent
effect Cfg
  get : U64

h = handler Cfg
  return get -> 41     -- abortive handling of get? or a value clause whose
                       -- binder happens to be named `get`? one token either way

-- and the typo that exploits it, verified on the current compiler
-- (2026-08-03, old surface): `gett` for declared `get` silently became the
-- VALUE arm; the error surfaced positionless, far from the typo
  return gett -> 41    -- typo: silently a value clause binding `gett`
```

The strongest of the naming probes, because the imported prior is CORRECT
— C's `return` does mean "stop here, hand back a value," which is what an
abort does. It dies anyway, on the rule every clause-head candidate must
pass: THE HEAD MUST CLASSIFY THE CLAUSE WITH NO HELP — not from types
(`yield`'s collision with its own flagship op name), not from ecosystem
priors (`continue`'s loop reading), not from name resolution (this
entry). For any nullary op, `return name ->` is one token in both
readings, so classification falls back to asking whether `name` is a
declared op — resolution-dependent clause kinds, the exact S-collapse
family the clause-kind redesign exists to close, rebuilt at the one
arity where the collision is guaranteed. Secondary wounds: one word
carries two different priors (Koka's completion-transformer vs C's
early-exit — half the clauses obey each), and abort deliberately
BYPASSES the value clause (`Err e`, never `Ok (Err e)`), so spelling
both `return` invites exactly the wrong uniformity guess. `abort` and
`return` remain distinct words because they are distinct promises.

## Bucket B — rejected removals (uniformity by deletion)

### B1. Forbid `handle State = state 0` (roles + `use` only)

```
handle e = except                     handle Except = except
use e as Except                       handle Reader = reader 10
handle r = reader 10          vs      handle Writer = writer
use r as Reader                       handle State  = state 0
...8 lines, 4 throwaway names
```
The left column's extra tokens state nothing the right doesn't. Fails the
trap bar: closes nothing D17/E-SHADOW don't already close. Recorded as the
1.2 idiom bullet.

### B2. Forbid `use ... as`

```
transfer    : () -> () with (from : State U64) + (to : State U64)
bumpAmbient : () -> () with State U64
handle to    = state 5      -- bumpAmbient unservable
handle State = state 5      -- transfer's `to` unbound
```
One cell must satisfy two vocabularies; every workaround (`handle State =
to`, A3) IS the rename respelled. The pick-two triangle: {no-swap,
no-rename-operator, cells-passable} — choose two.

### B3. Inline-only `use` (forbid the statement form)

```
use to as State              -- both names written; nothing elided or hidden
bumpAmbient ()
bumpAmbient ()
```
The statement form hides no information (contrast STATEMENT-form anonymous
handles, which hid the label — the delimited elided form is legal under
D13 two-tier); forbidding it would make `use` the one binder statement of
three (`let`, `handle`, `use`) without a statement form, for zero
informational gain.

## Bucket C — rejected dissolutions of essential couplings (see D18)

### C-flatten. Order-free answer types

```
handle Except = except            handle State  = state 0
handle State  = state 0     vs    handle Except = except
prog ()                           prog ()
: Result (a, U64) String          : (Result a String, U64)
```
Abort DISCARDS state on the left, PRESERVES it on the right — different
programs, so the types must differ. Flattening requires handlers to
commute; only special pairs do, and a commuting-subset rule is a worse
coupling than the one removed.

### C-converter. Remove `handle` (unify the value and activation tiers)

No program to show — only absences: without the unique converter, either
`runTick (pick True)` (runtime-selected handler values) or `transfer` over
two named cells stops being expressible. Two orthogonal tiers must meet at
exactly one operator; that meeting point is what orthogonality looks like
at a boundary.
