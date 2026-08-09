# Brainstorm: `Step` / `Suspension` under the one-shot law

**Date: 2026-08-09**
**Status: BRAINSTORM — no implementation. Agenda item #1 of the coroutine
planning conversation; input to the `prelude/v2/Control.wok` twin (spec
`2026-08-08-prelude-v2-rework.md`, phase-3 residue).**

## 0. The question asked

"Should `Step` and `suspend` work like this, if what we want is one-shot
delimited continuations?"

Short answer, up front: **the shape is right, the marker story is wrong.**
A reified two-case outcome plus an opaque parked continuation is the correct
surface for one-shot. But the way the compiler currently decides that a
`Step` is consume-once is an assertion by convention, not a derivation from
structure — and while probing that, this session found a live soundness hole
that lets a user resume a one-shot continuation twice.

## 1. What the design says today

```
effect Coro a b = { suspend : a -> b }

extern type Suspension a b r (row e)
extern data Step a b r (row e) = Completed r | Suspended a (Suspension a b r (row e))
```

Three separate disciplines ride on those two declarations:

| discipline | what it forbids | how it is enforced |
|---|---|---|
| second-class (escape) | a carrier leaving its activation (stored, returned, captured) | `tcCarrier`, set by `extern data`/`extern type` |
| affine (consume-once) | resuming the same parked continuation twice | `tcAffine`, defaults on for every carrier |
| one-shot at the IR level | `dup` on a continuation binder | `Wok.IR.Multiplicity`, independent of the above |

`Suspension` genuinely needs both markers: it *is* the continuation.
`Step` needs them only because it *contains* a `Suspension` — `Completed r`
holds nothing affine at all. `Step` is morally `Either r (a, Suspension)`,
and its consume-once obligation is entirely inherited from the field. The
existing reject fixture `step-scrutinized-twice.wok` is the proof that the
obligation is real: casing one `Step` twice hands you two live `g` binders
for one continuation.

So the true rule the compiler is trying to express is **contagion by
containment**. The implementation instead writes the conclusion by hand onto
one specific type, and relies on `extern` being prelude-only so that no one
else can build such a container.

That reliance does not hold.

## 2. The probe: containment can be laundered

Four attempts to smuggle a `Suspension` out of the `Suspended x g` arm, run
against the current compiler (`wok` at HEAD of `feat/prelude-v2-phase3`):

| smuggling vehicle | declared slot type | verdict |
|---|---|---|
| list literal `[g]` (existing fixture `suspension-escapes.wok`) | `[a]`, element slot polymorphic | rejected — `CarrierEscape` |
| builtin tuple `(g, 1)` | polymorphic | rejected — `CarrierEscape` |
| user data con with a polymorphic field, `Pair g 1` | `CTGen a` | rejected — `CarrierEscape` |
| user data con with a **carrier-typed field**, `Box g` | `Suspension a b r (row e)` | **ACCEPTED** |

where

```
data Box (row e) = Box (Suspension U64 U64 U64 (row e))
```

The mechanism is in `src/Wok/TypeChecking/Carrier.hs:393` —
`headParamTypes` resolves a data constructor's parameter types through
exactly the same `ctxResolve` path as a function's, so a field declared at
carrier type satisfies `isHandleSlot` and the position is marked *allowed*.
That allowance exists for a good reason: it is what lets `step`/`run`/
`cancel` legitimately receive a `Suspension`. A data constructor with a
precisely-typed field is indistinguishable from those consumers.

Note the inversion, which is what makes this more than a missing case: **the
more precisely you type the field, the more it launders.** Declare the field
polymorphically and the check fires; declare it honestly as a `Suspension`
and the check stands down.

### The exploit runs

```
prod : () -> U64 with Coro U64 U64
prod u = let x = Coro.suspend 1 in x + 100

escape : Step U64 U64 U64 (row e) -> [Box (row e)]
escape s = case s of
  Completed _   -> []
  Suspended x g -> [Box g]        -- carrier escapes its activation, in a list

unbox : Box (row e) -> U64 -> U64 with eff e
unbox bx v = case bx of
  Box g -> run g v

useTwice : [Box (row e)] -> U64 with eff e
useTwice bs = case bs of
  []     -> 0
  b :: _ -> let r1 = unbox b 5 in let r2 = unbox b 6 in r1 + r2

main : U64
main = useTwice (escape (start prod))
```

`wok --run` prints `211` — that is `105 + 106`, the same one-shot
continuation resumed twice with two different values. Both disciplines are
laundered at once: the carrier escaped its activation, and the `Box` is
ordinary first-class data so it duplicates freely.

### How bad, stated precisely

- **Today: a type-level soundness hole.** The one-shot law admits a program
  it is supposed to reject. The CEK interpreter executes it without
  complaint, because there a continuation is an immutable value and
  resuming it twice is merely wrong, not unsafe.
- **Not today a memory-safety bug.** The RC machine refuses this program for
  an unrelated reason (`start`'s arm escapes its resume into a non-
  `__cont_store` position — the M3 coverage limit), so Perceus never sees
  it.
- **Latent use-after-free.** The RC machine drops a continuation at its
  single consuming use precisely because the law promises there is only one.
  The day RC coverage reaches coroutines, this shape becomes a genuine UAF.

The probes live in the session scratchpad (`probe_box2.wok`,
`probe_pair.wok`, `probe_tuple.wok`, `probe_exploit.wok`); they become
reject fixtures as part of whichever fix is chosen, not before.

### The runtime oracle disagrees with the static law

The one-shot runtime oracle already exists (`Wok.Interp.Value`, gated on
`WOK_DEBUG_ONESHOT=1`: a per-capture used-flag, `OneShotViolation` on a
second apply). Run the exploit under it:

```
WOK_DEBUG_ONESHOT=1 wok probe_exploit.wok --run
  runtime error: OneShotViolation
```

So this is a **differential witness**: a program the static law accepts and
the dynamic oracle rejects. That is exactly the disagreement the oracle was
built to expose, and nothing has ever pointed it at this shape — there is no
fixture in the corpus that smuggles a carrier through a user constructor, so
the oracle never had the chance. That gap is as much the finding as the
missing check is.

### Other routes, probed

| route | verdict |
|---|---|
| `erase g` (`erase : a -> Transport`, the type-erasing gate into `Conc`) | rejected — polymorphic slot, `CarrierEscape` |
| record literal `Rec { susp = g, tag = 1 }` | blocked, but **for an unrelated reason** — parameterized records are broken today (`freeze: unexpected Rigid`, and even a carrier-free `Rec4 a` fails to unify with its own tycon). Pre-existing, adjacent to the known backlog, not a carrier issue. |

The record row deserves emphasis, because it is the argument for where to
put the fix: the record laundering route is closed *by accident*. The moment
parameterized records are repaired, `Rec { susp = g }` becomes a second
instance of exactly this hole — unless the rule lives at the declaration
rather than at the construction site.

`ContCell` launders identically — probed, same shape:

```
data CellBox r (row e) = CellBox (ContCell r (row e))
stash : ContCell U64 (row e) -> [CellBox U64 (row e)]
stash c = [CellBox c]                     -- accepted
```

so stored continuations (M3) are exposed by the same mechanism, and whatever
fix is chosen must cover every marked carrier, not just `Suspension`.

## 3. Two decisions, not one

The v2 blocker and the soundness hole read like one problem because both
touch the `extern` marker on `Step`. They are independent, and the order
matters: **the hole must be closed whatever v2 does.** Even if the owner
grows the v2 grammar and keeps `extern data Step ...` exactly as it is, `Box`
still launders it.

### Decision A (forced): what happens when a user type contains a carrier

**A1 — Reject.** A user (non-prelude) data declaration may not have a field
whose type is a marked carrier. Prelude declarations are exempt, so `Step`
keeps working. Blunt, small, obviously sound, and it closes the hole at the
declaration site rather than at every use site.
Cost: a legitimate wrapper (`data Task = Task Fiber (Suspension ...)`)
becomes inexpressible, and `Step` stays a hand-blessed special case — the
thing that caused this in the first place.

**A2 — Contagion.** A tycon whose constructors transitively mention an
affine carrier *is* an affine carrier; one that mentions a non-affine
second-class carrier (e.g. FFI `Borrow`) inherits second-class-ness only.
Computed as a fixpoint over the type graph so recursive and mutually
recursive declarations converge.
Cost: user wrapper types silently become second-class and consume-once —
a real semantic change the owner must sign off on, and a diagnostic
challenge ("why can't I return my own `Task`?" needs an error that names the
offending field). Also a genuinely new analysis, where A1 is a check.

**A3 — Narrow patch.** In `headParamTypes`, a `TCon` head does not get the
allowed-slot treatment unless the *constructed* type is itself a carrier.
This is A1 stated operationally at the use site, and it is what I would
write first regardless, because it is a two-line change that turns the
exploit into a `CarrierEscape` immediately. It is a stopgap, not an answer:
it stops the smuggling but leaves "what does it mean for a user type to hold
a carrier" undefined.

### Decision B: the v2 spelling for `Step`

**B1 — Grow v2.** Add an `extern type X ... = Con ... | ...` production:
C parser, sexp schema constructor field, `Wok.Sexp.Surface` mapping to v1's
`DExternData`. Faithful, keeps everything as-is, and moves the golden
contract by exactly zero. Cost: new grammar surface whose only user is one
prelude declaration.

**B2 — `Step` becomes an ordinary `type`.** Its constructors are public
anyway; only `Suspension` stays `extern type` (opaque), which v2 already
spells. The carrier and affine properties are *derived* from the
`Suspension` field. Zero grammar work, and the marker ends up on exactly the
one type that intrinsically deserves it.
This is only available if Decision A resolves to A2 — without contagion, an
ordinary `Step` is an ordinary type and the whole discipline evaporates.

**B3 — Eliminator / CPS encoding.** Delete the container: `start` takes two
answer continuations instead of returning a sum.
```
start : (() -> r with Coro a b + eff e)
     -> (r -> z)
     -> (a -> Suspension a b r (row e) -> z)
     -> z with eff e
```
The `Suspension` is then bound by a *lambda parameter*, which the existing
param-binder machinery already handles correctly — no container exists to
launder, and `extern type` (opaque-only) suffices, so v2 unblocks too.
Type-theoretically the most honest reading of affine: a value you may
deconstruct exactly once, by handing it to an eliminator.
Cost: the drivers get materially worse. `parBoth` and `runRace` do nested
two-way case analysis today; in CPS that is four nested lambdas per round,
and the residual-row plumbing threads through every answer type. Users lose
`case`. This is a real ergonomic tax for a property the data encoding can
have anyway.

**B4 — Dynamic ownership.** Drop the static carrier entirely: `Suspended a
Token` where the token is plain data (a `U64`), the real continuation lives
in a side table, and double-resume is a runtime error. This is not
hypothetical — it is exactly what `Conc` already does with `Fiber`/`Promise`/
`Chan` and the "not owned by this scheduler" check.
Cost: it converts a compile-time law into a runtime trap, and the whole
point of "one-shot is the law" was the former. Worth naming as the honest
fallback if static containment turns out unworkable, not as a target.

### The convergence

A2 + B2 is the combination worth leading with: state the containment rule
once, and the v2 blocker dissolves as a side effect with no grammar work,
no golden movement, and the `extern` marker left on `Suspension` alone —
where it is a statement about the runtime object rather than about a wrapper
around it. That is a smaller total surface than today's, which is unusual
for a fix.

If the owner prefers A1 (reject), B2 is off the table and the choice
collapses to B1 (grow the grammar) or B3 (eliminator).

## 4. Affine or linear? (and why it does not decide this bug)

"One-shot" is ambiguous in the literature and the ambiguity matters here:

- **affine** — at most once. Forbids two uses. Permits zero.
- **linear** — exactly once. Forbids two uses *and* zero.

They agree on everything except dropping. **Both forbid the exploit**, which
uses the continuation twice. So switching to linear would not have caught
it: the bug is not in which law is stated, it is in how far the checker can
*see*. Once the carrier sits inside a `Box`, neither pass is tracking it, and
a law nobody is enforcing is not stronger for being stricter.

Today's surface is affine **by construction**, and it is not close to
linear — three places in `Control.wok` drop a live carrier with no consumer:

- `cancel` exists for no other purpose than to discard a `Suspension`;
- `runRace`'s left-bias arm, `Suspended _ ga -> case sb of Completed rb -> rb`,
  drops `ga` without even calling `cancel`;
- `raceAny` drops every loser un-resumed, and the comment calls that
  "cooperative cancellation, pure control-flow, no keyword".

Under a linear law all three are compile errors as written.

### The real argument for linear — and it is not about duplication

Linearity buys **unwinding**, not safety from double-use. Today, dropping a
`Suspension` means the producer's tail never runs. In heap terms nothing
leaks: RC reclaims the continuation. But if the producer was holding a
resource *across* the suspend — an FFI `Borrow`, an owned pointer, an open
handle, a region — then nothing runs its cleanup, and nothing ever will.
Exactly-once forces every parked continuation to reach `resume` or `cancel`,
which gives the compiler a *place* to hang finalizers. That is precisely the
cancellation-plus-finalizers gap the Conc slice deferred ("it needs fiber-id
tracking plus finalizers, neither of which exists yet").

There is also a neat convergence with the v2 surface: `abort` is already the
clause kind that means "this arm discards its continuation". Under a linear
law, `abort` stops being cosmetic and becomes the *declared* drop site — the
one place unwinding is allowed to happen. If linear is ever wanted, the hook
is already in the grammar.

Costs, which are why this is not the fix on offer here: every branch must
consume or explicitly cancel (`runRace`, `raceAny`, `except` all rewrite);
a story is needed for what a trap does to outstanding continuations; and the
value is entirely in resource cleanup, a question wok has not yet asked.

**Recommendation against the duplication bug: stay affine.** Linear does not
fix it; both laws already forbid two uses, and adopting linear to close a
duplication hole would be paying for the wrong thing.

**But that only settles the duplication question.** The owner has since
stated a second, independent requirement — *no resource may be silently
forgotten; a discard must be written down, especially in control flow* —
and linear is a reasonable answer to THAT. §5 assesses that pivot on its
own terms. The two conclusions are not in tension: affine-vs-linear is
irrelevant to the `Box` exploit, and decisive for explicit disposal.

### So: is the shape right?

Yes. A one-shot continuation is affine, and affine values are perfectly good
*data* — they can sit in a constructor, be scrutinised by `case`, be passed
as arguments, so long as nothing duplicates them. That is why `Step` as a
reified sum is sound in principle, and why B3's eliminator, though more
rigorous-looking, buys nothing the data encoding cannot have.

What the shape demands, and what is missing, is that the *container* inherit
the obligation structurally rather than by decree. The `Box` exploit is the
receipt.

## 4b. How to actually get the one-shot guarantee

### State the invariant first

> A carrier's identity must never become reachable from a value of
> non-carrier type.

Everything below is a way of making that inductive. Today it is approximated
by a local walk over *names of carrier type* (`envCarriers` in
`checkCarriers`, the binder set in `checkFutureAffine`). The approximation is
sound only while carriers cannot hide inside non-carriers — which is the
assumption `Box` breaks.

### There are two ways in, and only one is guarded

| how the carrier gets inside | example | guarded? |
|---|---|---|
| a **polymorphic** slot | `[g]`, `(g, 1)`, `Pair g 1`, `erase g` | yes — at the construction site |
| a **declared carrier-typed** slot | `Box g` | **no** |

The two guards have to meet in the middle. The polymorphic route is already
covered at the use site and should stay there (the slot type is only known
at the call). The declared route should be closed at the **declaration**.

### Fix at the declaration site, not the use site

This is the load-bearing recommendation. A use-site patch must enumerate
every introduction form — positional constructor application, record
literal, record update, and whatever the v2 surface grows next. A
declaration-site rule does not care how many ways there are to build the
value, because the field cannot be declared at all.

The record probe above is the argument in miniature: record literals are
*currently* not a laundering route only because parameterized records are
broken. Fix that bug and the hole reopens through a form the use-site patch
never heard of. With the v2 surface actively growing, robustness beats the
smaller diff.

Concretely, one of:

- **F-reject** — a non-prelude data/record declaration whose field type
  contains a marked carrier is an error at the declaration. Prelude exempt,
  so `Step` keeps working. Smallest sound rule; kills user wrappers.
- **F-contagion** — such a type *becomes* a carrier (affine if the contained
  carrier is affine, second-class-only if not, so `Borrow` wrappers stay
  readable). A fixpoint over the type graph; monotone over a finite set, so
  recursive and mutually recursive declarations converge. Both existing
  passes then work unchanged, because both consult a set of carrier tycon
  names — the fix is to close that set under containment rather than to
  write a new analysis.

Whichever is chosen, two details must be nailed down:

1. **Arrow-typed fields are not containment.** `data F = F (() -> Step …)`
   is a producer *thunk* — the prelude's `runConc`/`spawn` shape — and must
   stay legal. A closure that captures a carrier is already handled by the
   capture rule (`reject-05-closure-smuggle`). So contagion applies to
   non-arrow occurrences only; under an arrow's domain or codomain it stops.
2. **Resolve through aliases.** If `D_Alias` ever maps, `type S = Suspension …`
   must not become a laundering route.

### Stopgap, available today

In `headParamTypes` (`Carrier.hs:393`), a `TCon` head does not get the
allowed-slot treatment unless the *constructed* type is itself a carrier.
Two lines; turns the exploit into a `CarrierEscape` immediately. It is a
stopgap precisely because it is a use-site patch: it stops the positional
constructor and leaves the question undefined.

### Backstop, worth doing regardless

The static rule should not be the only thing standing. The runtime one-shot
oracle already exists and already catches this shape (§2). Add a CI leg that
runs the carrier corpus under `WOK_DEBUG_ONESHOT=1`, and fixture-ify the
four probes. That converts "we believe the static law is total" into
something continuously checked, and it is the mechanism that would have
surfaced this hole without anyone going looking for it.

### Then audit the remaining routes

The routes by which a carrier could reach two consuming uses, and their
current status — the ones marked *reasoned* still want a probe before the
spec closes:

| route | status |
|---|---|
| direct double use | rejected (`step-scrutinized-twice`, `future-await-twice`) |
| let-alias | rejected (`consumeCard` over-approximates aliases to `Many`) |
| helper that consumes twice | rejected (`future-helper-double-consume`) |
| recursion | rejected (`future-recursive-consume`) |
| closure capture | rejected (`reject-05-closure-smuggle`) |
| polymorphic container / `erase` / `__coerce` | rejected — probed |
| declared carrier-typed field | **ACCEPTED — the hole** |
| record literal with a carrier field | blocked only by a pre-existing parameterized-record bug |
| `Array.set` of a carrier | reasoned (polymorphic slot), not probed |
| identity-function round-trip `id g` | reasoned (alias over-approximation), not probed |

Two smaller notes on the surface itself, neither blocking:

- `__coro_unwrap` is documented-partial (it traps if the producer
  re-suspends), which means `run` is partial. That is the deferred
  failure-model slice and it is orthogonal to everything above, but it is
  the one place the coroutine surface is not total.
- Slice 4b″ recorded that the resume obligation carried by `Step`'s
  `(row e)` is redundant. If that holds, `Step a b r` may not need the row
  at all (with `Suspension` keeping it) — a simplification worth deciding
  *while* the declaration is being respelled rather than after, since it
  changes the same signatures.

## 5. Pivoting to linear, for explicit disposal

Requirement, as stated by the owner: a token holding a resource must not be
silently forgotten; if it is dropped, the source must say so. This is
"explicit disposal", and it is a better-posed goal than "linear" — linear is
one mechanism for it.

### Scope, stated before anything else: wok does NOT become a linear language

"Linear" below is scoped to a sublanguage that is already restricted. It
means exactly two things:

1. the **affine carriers** — `Suspension`, `Step`, `ContCell` — tighten from
   at-most-once to exactly-once. These types are already second-class,
   already affine, already unable to escape an activation. Note this is not
   even all carriers: FFI `Borrow` is deliberately non-affine (read-many),
   and stays that way;
2. the **handler continuation binder `k`** must be used or explicitly
   discarded via `abort`.

Everything else is untouched. Ordinary values — numbers, strings, lists,
records, user data types — stay fully unrestricted: droppable, duplicable,
ignorable. There is no linearity polymorphism, no usage-annotated arrows, no
second function space, no `!` in any signature a user writes. A program that
never defines a handler and never touches coroutines is bit-for-bit
unaffected.

The accurate phrasing is **"carriers become linear; the language stays
unrestricted"**. That places wok where Koka and OCaml sit — an unrestricted
language with a small linear sublanguage for one specific resource — not
where Linear Haskell or Rust sit.

This also keeps the standing architectural commitment intact: the recorded
higher-IR direction is "multiplicity as an ANALYSIS, no linear types". The
pivot does not overturn that. It changes a threshold inside an existing
analysis (reject `Zero` as well as `Many`) and adds the must-direction to
compute it. Still an analysis; still no linear type system.

What a user would actually SEE, all of it in control-flow code:

- `abort` becomes mandatory where a continuation is currently dropped in
  silence (~12 corpus arms);
- `cancel g` becomes mandatory where a carrier is currently abandoned
  (2 arms, both in `runRace`);
- a branch disagreement — one arm resumes, the other does not — becomes an
  error.

### Why this concern is already real in the repo

There is a documented leak class, accepted as a deferral in **three**
separate slices, always the same shape: **a suspended-then-abandoned
activation never runs its close.**

- M2b: the raw-abort leak.
- FFI Slice 3: "the abort-path buffer leak (a suspended-then-abandoned
  activation never runs its close → leak, memory-safe)".
- FFI Slice 4: "if execution aborts between ownership-release and the
  consumer free the buffer leaks … the same class as the M2b raw-abort leak
  and the Slice-3 abort leak."

That is precisely "a token holding a resource got forgotten". The concern is
not speculative; it has been signed off three times.

### Why the pivot is unusually cheap here

Linear type systems are normally invasive — linearity polymorphism, usage
annotations on arrows, a second function space. None of that is needed here,
for one structural reason: **carriers are already second-class.** They
cannot escape their activation, cannot be captured by a closure, cannot sit
in a polymorphic slot. So "exactly once" stays a *local, per-binder* check
over one activation — no type-system surgery.

That is also why the containment hole is a hard prerequisite rather than a
parallel task: second-class-ness is the load-bearing property the cheapness
rests on, and `Box` is a breach of it. Exactly-once is exactly as
unenforceable as at-most-once while a carrier can hide inside ordinary data.

### What it costs, concretely

Cheap, and mostly already built:

- **The v2 grammar already has the spelling.** `WOK_CLAUSE_ABORT = 4`:
  `abort op pats -> body`, and it does **not bind `k`**. The three clause
  kinds — plain (auto-resume), control (`op ps, k ->`), abort — are already
  a three-way explicit classification of the continuation's fate.
- **The diagnostic is already reserved.** `E-ABORT` is minted in the v2
  diagnostic roster under "Not in scope, vocabulary reserved… later
  analyses. They stay out of the code." The slot was cut for this check.
- **It is not enforced anywhere today.** Probed: wokparse accepts
  `throw e, k -> Err e` with `k` unused, exit 0, no diagnostic. (This also
  answers the original handoff's queued question: v2 does *not* force the
  `abort` spelling, so the faithful `Control` translation needs no
  abort-clause mapper work.)
- **`Control.wok` needs two edits.** `runRace` has exactly two arms that
  abandon a live carrier (`Suspended _ gb -> ra` and `Suspended _ ga -> …
  rb`); both become `cancel`. `cancel` already exists and already means
  this. `parBoth`/`drainOne` consume everything already.
- **The corpus is roughly a dozen arms** — `Exn`/`Choose` handlers of the
  `throw n k -> None` shape (grep estimate, heuristic filter). They are
  already migrating to v2 clause kinds, and the once/return retrofit set the
  codemod precedent.
- **The `Card` lattice already computes `Zero`.**

The real engineering cost is one thing, and it is shared by both halves:

- **The analysis is a *may* analysis and linear needs a *must* analysis.**
  `cardOf` is documented as "an upper bound on how many times `r` is
  invoked", and `joinC` is `max`. That is sound for at-most-once and wrong
  for at-least-once. The fix is to carry a `(lower, upper)` pair — meet =
  `min` on the lower side — and reject `lower == Zero`. Both passes need it:
  `Wok.IR.Multiplicity` over ANF for the handler binder `k`, and
  `checkFutureAffine` over the typed AST for carrier values. Two small
  passes, not one, and the trust-map relaxation needs a mirrored must-side
  entry.
- Branch disagreement becomes an error (one arm resumes, the other does
  not), which is where any false positives will come from.

### Precision: what each increment actually buys

A cheap first increment is `card(k) == Zero` in a control clause → error,
"use `abort` if you mean to discard". That uses the existing upper-bound
analysis and catches every whole-arm drop, which is all of the ~12 corpus
arms. It does **not** catch a branch-level drop:

```
op x, k -> case x of
  A -> k 1
  B -> 42        -- k silently dropped on this path; joinC = max reports One
```

Branch-level explicitness needs the must-direction. So: the syntactic check
is a real first increment, the `(lower, upper)` pair is the property.

### The honest limit: explicit discard still does not run cleanup

This is the part that matters most for the stated goal. Writing `cancel g`
today does **not** run the abandoned activation's closes — that is exactly
the documented abort-path leak, and it survives an *explicit* discard. So:

- **linear / mandatory `abort` supplies the discard SITES** — every place a
  continuation dies becomes named, statically known, and visible in the
  control flow;
- **unwinding attached to those sites supplies the BEHAVIOUR** — running the
  drops and closes the abandoned frames owe.

Linear is the enabler, not the fix. It is, however, the right first half:
without explicit discard sites, unwinding would have to be attached to
arbitrary implicit drops, which is the harder problem.

Static linearity also says nothing about traps. It gives "every path in the
*source* names its disposal", not "disposal always runs".

### The tier that linear does not touch at all

| tier | today | does linear-on-carriers help? |
|---|---|---|
| continuations — `Suspension`, `Step`, `ContCell` | affine, second-class, marked | yes — the cheap pivot above |
| FFI resources — `owned`, `Borrow` | `owned` is already move-out (linear-ish); `Borrow` is deliberately non-affine | partly — the abort-path leak is an unwinding gap, not a law gap |
| scheduler tokens — `Fiber`, `Promise`, `Chan` | **plain `U64` data. No discipline at all.** | **no — completely untouched** |

The third row deserves the owner's attention, because it is the most literal
reading of "a token holding a resource got forgotten": a `Promise` that is
never `await`ed, a `Chan` never drained, a `Fiber` never joined are all
silently fine today, and nothing in this brainstorm changes that. They are
plain data *by design* (the real carriers live in the Haskell scheduler,
keyed by id, with a dynamic "not owned by this scheduler" check). Making
them explicit is a separate and larger design question than the coroutine
one, precisely because they were made first-class on purpose.

### Suggested sequencing

0. **Close the containment hole.** Prerequisite for any law; without it,
   neither affine nor linear is enforceable.
1. **Implement E-ABORT: a control clause must use its `k`.** Cheap, uses
   syntax and a diagnostic code that already exist, and delivers most of
   "show me the drop" at the handler level on its own.
2. **Linear on carrier values.** Two `cancel`s in `Control.wok`, plus the
   `(lower, upper)` pair in both passes.
3. **Unwinding on discard.** The actual fix for the abort-path leak class.
   The big one, and the deferred failure-model slice.
4. **Tokens (`Promise`/`Chan`/`Fiber`).** Own design question.

Steps 1 and 2 are the pivot and are genuinely small. Step 3 is where the
owner's requirement is actually met, and it should not be undersold as
falling out of the pivot — it does not.

## 5b. `ContCell`, and what its name is hiding

Raised by the owner: the name is unintuitive. It is, and the reason turns out
to be substantive rather than cosmetic.

**What it is.** A one-shot parking slot for a handler continuation. You mint
one (`__cont_cell_new`), move a continuation *in* (`__cont_store` — consumes
`k`, no incref), and move it back *out* (`__cont_take` — empties the cell).
Its purpose is M3 stored/escaping continuations: it lets a scheduler handler
park `k` in its baton and resume it *later*, outside the arm that captured
it. Without it a continuation can only be resumed within its own arm body.

**Why "cell" misleads.** Everywhere else the word means a mutable box you can
read repeatedly — an ML `ref`, a Rust `Cell`, a Lisp cons. This one has
*take* semantics, not *get* semantics: reading it empties it, and it holds
at most one value once. It is a one-shot mailbox (closer to an `MVar`) or a
park slot. `Cont` is also abbreviated where its sibling is spelled out in
full as `Suspension` — two registers for two halves of one idea.

**And "cell" implies it remembers what it holds. It does not.** Compare the
two sibling types:

```
Suspension a b r (row e)     -- tracks the resume-argument type b
ContCell      r (row e)      -- does NOT
```

`__cont_store` and `__cont_take` both quantify `b` freshly, so nothing forces
the take to agree with the store. Probed — store a continuation expecting a
`U64`, take it back at `String`, apply it to a string:

```
let filled = __cont_store cell k in
let k2     = __cont_take filled in
k2 "not a number"                      -- type-checks
```

Result: accepted statically; at run time `PrimError "expected U64, got
\"not a number\""`. That is a type confusion the type system let through to
a dynamic trap. It is memory-safe only because the interpreter tag-checks
primitives; on a compiled backend with unboxed representations this is the
classic type-confusion fault. (The RC run also reports `heap freed with 1
live cells (leak)` on that error path — the abort-path leak class from §5
again, on a different route.)

The prelude comment says the decoupling was deliberate:

> `__cont_store` is the trusted ONCE-SINK … the continuation slot is a plain
> function `(b -> r with eff e)` decoupled from the cell, so the op-arm
> `op x k -> __cont_store cell k` unifies without an occurs-check

So `b` was dropped from the cell's type to dodge an occurs-check during
op-arm unification, and the resulting loss of the store/take agreement looks
unnoticed rather than accepted — the comment argues only for the decoupling,
never for the untypedness. `Suspension` solves the same op-arm problem
(`__coro_susp` decouples its slot identically) while *keeping* `b` in the
carrier type, which suggests the fix is available in the design already.

**The naming question is downstream of a design question.** `ContCell` and
`Suspension` are both reified one-shot continuations, both second-class,
both affine. They differ only in provenance (one you mint, one you receive
inside a `Step`) and in how the continuation comes back out. If they merge,
the name problem disappears with them. If they stay separate, the prelude's
own vocabulary already supplies a better word — it calls a `Suspension` "the
opaque, second-class, affine **parked** producer", so `ParkSlot` (or
`Parked`) names this one in the register that is already in use.

Recommendation: treat "does `ContCell` track `b`" as a correctness item to
schedule, and the rename as a follow-on to whether the two types merge — not
the other way round.

## 5c. DECIDED — merge `ContCell` into `Suspension`

Owner decision, 2026-08-09: merge, so there is one reified-continuation
concept rather than two. Spec below; implementation pending review.

### Scope note, stated honestly up front

The stated motive was "so the user doesn't need to care about `ContCell`".
Two facts about that:

- **Users already cannot reach it through any API.** No prelude function
  wraps `ContCell`; it appears only in compiler test fixtures
  (`test/rc-m3`, `test/rc-m3-reject`, `test/multiplicity-examples`).
- **But they can name it.** `import Control` brings the type into scope, and
  a user can write `data CellBox r (row e) = CellBox (ContCell r (row e))` —
  probed, accepted (which is §2's laundering hole, on this type too).

So the merge's payoff is *compiler concept count*, one fewer nameable
carrier, and the §5b `b`-tracking bug fixed for free. It is not a
user-facing surface change. The decision stands on those grounds; it just
should not be sold as removing something users see.

### The real justification: the two-phase lifecycle serves no constructible program

`ContCell` exists to park a continuation *now* and resume it *later*,
outside the arm that captured it. That use is **not constructible today**.
The route requires the cell to live in the handler's baton, and
`test/rc-m3-reject/01-cycle-cont-reaches-cell.wok` documents that this is
rejected by an `OccursCheck` — storing `resume` into the baton unifies the
cell's answer type `r` with the continuation's own result type, so `r`
occurs in itself. Every *accept* fixture therefore mints and drains the cell
inside a single arm:

```
once tick k ->
  let cell   = __cont_cell_new () in
  let filled = __cont_store cell k in
  let k2     = __cont_take filled in
  k2 1
```

That is a round trip. The empty state is never observable: `__cont_store`
returns the filled handle (Design A) and the program uses the *returned*
handle, so the empty cell is threaded in and immediately superseded. A
two-phase lifecycle with no reachable second phase is exactly the thing to
collapse.

### The merged surface

```
extern type Suspension a b r (row e)                            -- unchanged, opaque
extern __cont_park : (b -> r with eff e) -> Suspension Never b r (row e)
```

- `__cont_cell_new` — **deleted**; the empty state becomes unrepresentable.
- `__cont_store` — becomes `__cont_park`, a one-argument *constructor*.
- `__cont_take` — **deleted**; subsumed by `run` (see the shim item below).
- `cancel` already applies, and now means "discard a parked handler
  continuation" as well as "abandon a producer" — one word for one idea.

`a = Never` reads as "this continuation cannot yield again". **Today that is
documentation only**: exhaustiveness is not enforced, probed with a control —
omitting the live `Suspended` arm of an ordinary `Step U64 () U64` is
accepted just as readily as omitting the uninhabited one. It becomes a real
totality argument for `run` if exhaustiveness checking ever lands; until
then it is a type-level comment, and the spec should not claim more.

### Required: the host shim must wrap to Step shape

This is the one place the merge is not a pure deletion, and it must be in
the spec or the implementation will hit a confusing trap.

A *coroutine* continuation yields a `Step` when applied, because it resumes
under the `Coro` handler whose value arm is `return v -> __coro_done v` —
that is why `__coro_unwrap` can expect `VCon "Completed"`
(`Prim.hs:117-126`). A *raw handler* continuation has no such wrapper:
`runTick` in `test/rc-m3/01-store-resume.wok` has no `return` arm, so
applying its `k` yields a raw `r`. But `__coro_resume` is just
`PRApply k [v]` (`Prim.hs:137`).

Trace the merged path and the two consumers disagree:

- `run (park k) v` → apply → raw `r` → `__coro_unwrap`'s **catch-all**
  (`Prim.hs:125`, `[v] -> PRDone v`) passes it through. It *appears* to
  work — and is shape-ambiguous: if `r` is itself `Completed`-shaped (a
  nested coroutine returning a `Step`), unwrap peels a layer it must not.
- `step (park k) v` declares `Step Never b r` but a raw `r` comes back, so
  any `case` on the result fails at runtime.

**Fix: `__cont_park`'s host shim wraps the stored continuation as
`\v -> Completed (k v)`**, making its application Step-shaped like every
other `Suspension`. Exact precedent exists — `__coro_susp`'s shim "exists
only to ERASE the continuation's wok type" (`Prim.hs:101-107`); park's
shim wraps for the same class of reason. With the wrap, `run` and `step`
both behave uniformly and the catch-all is no longer load-bearing.

### What gets deleted, and what covers the residual risk

Three defense layers disappear because the states they guard become
unrepresentable:

| deleted | why it is safe |
|---|---|
| the `ContCellEmpty` sentinel | there is no empty phase |
| `__cont_store`: "cell already holds a continuation (one-shot violation)" | a cell cannot be filled twice if it is only ever constructed full |
| `__cont_take` on an empty cell "errors loudly" | ditto |

Residual risk moves to machinery that already exists: double-consume of the
parked `Suspension` collapses into the ordinary `FutureConsumedTwice` path
(plus the linear/must analysis if §5 lands), and double-*apply* is caught by
the `WOK_DEBUG_ONESHOT` oracle.

### Blast radius

Compiler:

- `prelude/Control.wok` — remove `extern type ContCell` + three prims, add one.
- `src/Wok/IR/PrimNames.hs` — three qualified identities collapse to one.
- `src/Wok/IR/Multiplicity.hs` — once-sink trust set (`__coro_susp` + park).
- `src/Wok/IR/Escape.hs` — the blessed move-in position changes from
  `__cont_store` to the park constructor. Note `rc-m3-reject/02` pins that
  the blessing recognises **only the literal atom**, not an alias.
- `src/Wok/IR/Reachable.hs`, `src/Wok/Interp/Prim.hs` (three prims to one),
  the RC runtime `NContCell` representation and its `cascadeChildren`.
- `Wok.TypeChecking.Env` — one fewer carrier tycon, automatically.

Tests — the risky part, because these fixtures' *subject* is the two-phase
discipline being deleted, and their comments encode the M3 rationale:

- `test/rc-m3/{01,02,03}`, `test/rc-m3-reject/{01,02,03}`,
  `test/multiplicity-examples/m3-store-{once,branch}`.
- Haskell-side unit tests keyed on these prims, which the `.wok` sweep does
  not cover: the "m3 cycle red-check" test over a hand-constructed owned set,
  and the `NContCell` cascade test.
- Any rc-stats / ANF / multiplicity goldens over the above.

`rc-m3-reject/01`'s subject needs particular thought: its point is that the
baton route is unconstructible *via an OccursCheck*. After the merge the
same program is written with `__cont_park`, and the spec must confirm the
OccursCheck still fires (it should — the occurrence is in the answer type,
not in the cell's two-phase-ness) rather than assume it.

### Forward compatibility

The merge does **not** foreclose cross-arm parking, and does not fix it
either — that is answer-decoupling's job, and it is orthogonal. But when
answer-decoupling lands and cross-arm parking becomes expressible, the empty
slot **returns**, spelled as ordinary data in the handler baton:
`Option (Suspension …)`. That is ordinary data containing a carrier, i.e.
squarely Decision A's territory: contagion (A2) handles it structurally,
while rejection (A1) admits it only through the prelude exemption. So the
merge is another argument for A2, and the empty state's eventual spelling is
determined by that decision rather than by this one.

### Sequencing and fallback

Sequence after the containment fix (§4b): carrier surgery with an open
escape hole means verifying everything twice. If this slice slips, the
`b`-tracking bug from §5b should be fixed standalone — add `b` to
`ContCell`'s signature — because that is a correctness item and the merge is
a simplification.

## 6. What I need from the owner

0. **Explicit disposal (§5).** Recommendation: pivot, in the order 0-1-2-3
   above — but adopt it as the *explicit-disposal* decision, not as a fix
   for the `Box` bug, which it does not touch. Confirm that step 3
   (unwinding) is understood as the step that actually meets the
   requirement, and say whether the token tier (`Promise`/`Chan`/`Fiber`)
   is in scope or a separate epic.
1. ~~**Decision A**: A1 or A2?~~ **DECIDED A2 (contagion) and IMPLEMENTED**,
   2026-08-10 — see `specs/2026-08-10-carrier-containment-fix.md`. A3 was
   subsumed rather than shipped (a derived carrier trips the existing escape
   check, so the `headParamTypes` stopgap was unnecessary). Implementation
   found one further instance of the hole the spec did not anticipate: the
   RECORD form, which needed a structural fix in the carrier predicates on
   top of the closure.
2. **Decision B**, which A constrains: B1 grow the v2 grammar, B2 `Step` as
   an ordinary type (needs A2), or B3 eliminator?
2b. **`ContCell` merge (§5c) — DECIDED, spec pending review.** Note it
   argues for A2 (contagion), since the empty slot returns as
   `Option (Suspension …)` once answer-decoupling makes cross-arm parking
   expressible.
3. Is `Box g` passing *intended* — data constructors as blessed carrier
   consumers? The fixture record says no (`suspension-escapes` rejects
   containment in a list; `user-data-step-not-carrier` blesses only name
   reuse with no real carrier in sight), but that is inference from
   fixtures, not from a stated rule, so it is the owner's call to confirm.
4. Does the residual row come off `Step` in the same slice, or stay?

After those four, this becomes a short implementation spec: the fix slice
(with the four probes fixture-ified as rejects), then the
`prelude/v2/Control.wok` twin per the existing handoff.

### Consequence for the C typechecker epic's sequencing

The `ContCell` merge (§5c) changes declared prelude signatures, therefore
schemes, therefore the 82-golden contract. The prelude-v2 spec's D2 budgeted
**two** contract moves (phase 1 and phase 3) and said the C typechecker
sequences strictly after them. This is a **third**. It does not change the
conclusion — it reinforces it: the contract is still in motion, so starting
the C typechecker now would target a contract known to change, which is
exactly what D2 warned against. Goldens move here by design and must be
audited on regeneration, not blind-accepted.
