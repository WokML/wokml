# Carrier containment: closing the user-constructor laundering hole

**Status: IMPLEMENTED — owner-approved 2026-08-10; pending `/code-review high`**
**Date: 2026-08-10**

## Implementation note (2026-08-10)

Implemented as specified, with **one scope expansion the spec did not
anticipate and R2 predicted**: the declaration-site closure alone did NOT
close the RECORD form of the hole. A record's type is `CTRecord tag row` —
the tag is the CONSTRUCTOR name and the field types live structurally in the
row — so there is no tycon name for `isHandleType`/`isAffineCarrierType` to
look up, and both fell through to `False`. `data R = R Borrow` was correctly
rejected while `data R = R { b : Borrow }` was accepted, letting a
second-class foreign borrow escape its lending activation (the Slice-3
use-after-free).

Closed by answering record containment **structurally** in the two predicates
(`recordRowCarries` in `Carrier.hs`), which needs no tag-to-tycon mapping.
This contradicts D4's "the two soundness passes are NOT modified" — D4's
premise (that closing the name set is the whole fix) held for positional
constructors and not for records. Pinned by
`test/typecheck-fail-examples/carrier-field-record.wok`.

T6 (provenance diagnostics) was NOT implemented — it was marked droppable and
owner's-call, and the approval did not single it out. A derived carrier still
fails with a bare `CarrierEscape`.

## Review round (`/code-review high`, 2026-08-10)

Three findings, all in the record work above, all fixed and pinned by
`test/typecheck-examples/carrier-record-read-ok.wok`:

1. **HIGH — the record fix over-rejected.** Making a carrier-holding record a
   carrier binder meant the record could no longer be READ: `readN r = r.n`
   on an ordinary `U64` field failed with `CarrierEscape`, because `recurse`
   put the projection base in a non-allowed position. Reading a sibling field
   leaks nothing, and this rejected exactly the shape the rule exists to keep
   usable. Fixed by making the projection and record-extension BASE an allowed
   position: what leaves is the field (or the new record), judged at the
   parent. Storing or returning the record whole is still caught.
2. **MEDIUM — affinity leaked through the wrong predicate.**
   `recordRowCarries` was hard-wired to `isHandleType`, whose first arm reports
   every effect-instance handle as a carrier while ignoring the name set. So a
   record containing a handle came back affine from `isAffineCarrierType`,
   contradicting that function's own contract, and two uses of such a record
   were a spurious `FutureConsumedTwice`. Fixed by parameterising
   `recordRowCarries` over the element predicate so each caller recurses under
   its own question.
3. **LOW — unreachable code with a false comment.** `conFields`'s
   `envRecordCons` fallback cannot fire: `registerCons` builds `tcCons` from
   positional `ConDef`s only. Removed, and the comment now states plainly that
   record containment is answered structurally at the predicates and NOT by
   this closure.

## Full-branch review round (`/code-review medium`, base..HEAD, 2026-08-10)

The first review only saw `HEAD~1`, which is how its own fix commit went
unreviewed. The full-branch pass found three more, and I verified each against
the BASE build to separate regression from pre-existing:

1. **HIGH — the record fix was bypassable four ways.** Making the
   projection/extension base allowed (the previous round's fix) left the
   carrier one keystroke from the rejected `leak r = [r]`: `[r.b]`,
   `[R { ..r, n = 1 }]`, `[R { b = r.b, n = 1 }]`, and `[p.h]` for an effect
   handle. **Not a regression** — all were accepted at base too, since records
   were not carriers at all there. But the branch claimed to close record
   laundering and did not. Fixed by judging the node's own RESULT type
   (`isCarrierRecordNode`), which is what separates them from `r.n : U64`.
2. **HIGH — a genuine regression, introduced by this branch.** The structural
   `CTRecord` arm of `isHandleType` flowed into `isHandleContinuation`, so a
   parameter of type `R -> U64` became a "runner continuation" slot and its
   deliberately-permissive allowance admitted a Borrow-capturing closure:
   `keep (\r -> … bo …)` was ACCEPTED where the identical program over a
   carrier-free record was rejected. Verified rejected at base, accepted at
   HEAD. Fixed by splitting out `isNominalHandleType` and having the
   continuation-domain test use it, so containment-derived cases cannot widen
   that allowance.
3. **MEDIUM — the accept fixture pinned an unsound case.** `bump : R -> R`
   returned a record still holding the `Borrow`, contradicting the sibling
   `leak r = [r]` reject one keystroke away. Moved to
   `test/typecheck-fail-examples/carrier-record-rebuild.wok`; the accept
   fixture keeps the legitimate read (`r.n`) and now uses the extension only as
   an intermediate.

The §"Known residual" recorded in the previous round is therefore **closed**,
not deferred: projection and extension results are judged.

Verified after this round: 2428 tests green; oracle 82 compared / 0 failed /
`coverage change: none` with the golden tree untouched; hlint at its
pre-existing baseline of 6 (no new hints).
**Predecessor: docs/superpowers/2026-08-09-coro-step-suspension-brainstorm.md (§2, §4b)**
**Branch target: new branch off `feat/prelude-v2-phase3`**

## Goal

Close a soundness hole in the one-shot law: a marked carrier (`Suspension`,
`Step`, `ContCell`) can be smuggled out of its activation inside an ordinary
user data type, after which it is first-class, duplicable, and resumable
twice.

This spec implements **A2 (contagion)** from the brainstorm: a type that
structurally contains a carrier *is* a carrier, derived rather than
declared. §"Decisions" records why, and D5 records the A1 fallback.

## The bug

`checkCarriers` and `checkFutureAffine` both track *binder names of carrier
type*, using a set of carrier tycon names built in `Infer.hs:4330-4340` by
filtering `envTyCons` on `tcCarrier`. The moment a carrier sits inside a
value whose own tycon is not in that set, both passes go blind.

Probed at HEAD of `feat/prelude-v2-phase3`:

| smuggling vehicle | declared slot type | verdict |
|---|---|---|
| list literal `[g]` | `[a]` — polymorphic | rejected, `CarrierEscape` |
| builtin tuple `(g, 1)` | polymorphic | rejected, `CarrierEscape` |
| user con, polymorphic field — `Pair g 1` | `CTGen a` | rejected, `CarrierEscape` |
| `erase g` (`a -> Transport`) | polymorphic | rejected, `CarrierEscape` |
| **user con, carrier-typed field — `Box g`** | `Suspension a b r (row e)` | **ACCEPTED** |
| **same for `ContCell` — `CellBox c`** | `ContCell r (row e)` | **ACCEPTED** |

Mechanism: `headParamTypes` (`Carrier.hs:393`) resolves a data
constructor's parameter types through the same `ctxResolve` path as a
function's, so a field declared at carrier type satisfies `isHandleSlot` and
the position is marked *allowed*. That allowance exists so `step`/`run`/
`cancel` can legitimately receive a `Suspension`; a constructor with a
precisely-typed field is indistinguishable from them. Note the inversion:
**the more precisely the field is typed, the more it launders.**

The exploit runs. `main = useTwice (escape (start prod))` with
`data Box (row e) = Box (Suspension U64 U64 U64 (row e))` prints `211`
(= `105 + 106`) — one one-shot continuation resumed twice. Under
`WOK_DEBUG_ONESHOT=1` the runtime oracle reports `OneShotViolation`, so the
static law and the dynamic oracle disagree on this program.

Severity: a type-level soundness hole today (the CEK machine runs it; the RC
machine declines for an unrelated M3-coverage reason), and a latent
use-after-free once RC coverage reaches coroutines, because Perceus drops a
continuation at its single consuming use precisely because the law promises
there is only one.

## Design

### The invariant

> A carrier's identity must never become reachable from a value of
> non-carrier type.

There are exactly two ways a carrier gets inside another value, and they are
guarded by different mechanisms that must meet in the middle:

| route | example | guard |
|---|---|---|
| a **polymorphic** slot, known only at the call | `[g]`, `(g,1)`, `Pair g 1`, `erase g` | the existing **use-site** escape check — already correct, untouched by this spec |
| a **declared carrier-typed** slot | `Box g` | the new **declaration-site** closure, below |

### The closure

Replace the two set constructions at `Infer.hs:4330-4340` with a
containment closure over the type graph. Both soundness passes consume a
`Set Text` and are **unchanged** — the entire fix is that the set they
receive is now closed under containment.

Seeds (today's behaviour):

```
S0 = { n | tcCarrier (envTyCons ! n) }                    -- all carriers
A0 = { n | tcCarrier (envTyCons ! n), tcAffine (…) }      -- affine subset
```

Iterate to a fixpoint: a tycon `T` joins `S` when any field type of any
constructor of `T` mentions a member of `S`; `T` joins `A` when a field type
mentions a member of `A`. Monotone over a finite tycon set, so it converges;
recursive and mutually recursive declarations are handled by construction.
`A ⊆ S` is preserved automatically, since `A ⊆ S` implies
`mentions A ⊆ mentions S`.

Affinity propagates by *kind of containment*: a type containing an affine
carrier becomes affine (consume-once **and** second-class); a type
containing only a non-affine carrier such as FFI `Borrow` becomes
second-class only, matching `Borrow`'s deliberate read-many semantics.

### `mentions` — the traversal

```
mentions s (CTCon (TcUser n) args) = Set.member n s || any (mentions s) args
mentions s (CTCon _          args) = any (mentions s) args
mentions s (CTRecord _ row)        = any (mentions s) (rowFieldTypes row)
mentions _ (CTArr _ _ _)           = False      -- see D2
mentions _ (CTGen _)               = False      -- see D3
```

Two subtleties worth stating explicitly, because both are easy to get
backwards:

- **Traversing `args` does not poison the container tycon.** `data L = L [Suspension …]`
  makes `L` a carrier because a carrier occurs in `L`'s *field type*.
  `List` itself stays clean, because the rule is applied to the field types
  written in each declaration, and `List`'s own field type is `CTGen 0`.
- **The arrow rule is a stop, not an omission.** A field of function type
  does not *contain* a carrier; it produces or consumes one.

## Decisions

<decision id="D1">Implement A2 (contagion), not A1 (reject carrier-typed
fields in user declarations). Two independent arguments. (a) A2 makes the
v2 blocker dissolve for free: with carrier-ness derived, `Step` can become
an ordinary `type` whose affinity comes from its `Suspension` field, so
`prelude/v2/Control.wok` needs no `extern type X = Con …` grammar growth
(brainstorm B2) — though that change is a SEPARATE slice, not this one.
(b) When answer-decoupling makes cross-arm parking expressible, the
continuation's empty slot returns as `Option (Suspension …)` in a handler
baton — ordinary data containing a carrier, which A2 handles structurally
and A1 admits only through a prelude exemption.</decision>

<decision id="D2">A field of arrow type stops contagion. `data F = F (() -> Step …)`
is the prelude's producer-thunk shape (`runConc`, `spawn`, `async` all build
`\() -> start (asConc …)`) and must stay legal. SOUNDNESS DEPENDENCY, to be
stated in the code comment: this exemption is safe ONLY because a closure
that captures a carrier is independently rejected by the existing capture
rule (pinned by `grammar/go/testdata/golden/reject-05-closure-smuggle`). A
thunk can therefore return a FRESH carrier but cannot smuggle an existing
one. If the capture rule is ever weakened, this exemption becomes a
hole.</decision>

<decision id="D3">`CTGen` (a quantified slot) does not trigger contagion.
A type variable cannot be known to be a carrier at declaration time;
containment through a polymorphic slot is guarded at the USE site by the
existing escape check, which already rejects `Pair g 1`, `[g]`, `(g,1)` and
`erase g`. The two mechanisms partition the problem; neither is
redundant.</decision>

<decision id="D4">The two soundness passes (`checkCarriers`,
`checkFutureAffine`) are NOT modified. They already consume a `Set Text` of
carrier tycon names; closing that set is the whole fix, so every existing
carrier fixture keeps testing exactly what it tested before.

BUT the closure must not be delivered as a local substitution at
`Infer.hs:4330`, because `tcCarrier` has **three** consumers, not one, and
the other two read the raw flag:

- `Infer.hs:462` — `isCarrier`, feeding `effectRelevantRowVars`: decides
  whether a row var is rigidified. Its own comment cites "a non-carrier data
  row param (`Box (row e)`) stays flexible" as the example, which is
  precisely the type this spec reclassifies.
- `Infer.hs:1056-1061` — `checkConcPayload`, rejecting a carrier anywhere in
  a `Promise`/`Chan` payload.

So the closure is **written back into `env`'s `TyConInfo` records**: after
the fixpoint, set `tcCarrier`/`tcAffine` on each derived tycon, so the flag
*is* the closure and every present and future consumer is automatically
consistent. This is the same declaration-site-over-use-site argument this
spec makes about the language, applied to its own implementation: patching
the readers we happen to have found would leave the next reader
wrong.</decision>

<decision id="D6">The closure is computed once, as soon as the tycon and
constructor environment is complete and **before body inference**, not from
the post-inference `env2`. Forced by D4's first consumer: `isCarrier` at
`Infer.hs:462` is consulted DURING inference (row-var rigidification), so a
closure computed at 4330 would arrive too late to be seen by it. Data and
constructor declarations are fully processed in an earlier pass, so the
inputs are available at that point.

Consequence to state plainly: because rigidification consumes this flag, the
closure can change INFERENCE for a program that declares a carrier-holding
type, not merely reject it later. That is the intended reading (such a
type's row parameter genuinely is a carrier's residual row), but it means
"this is a pure analysis change" would be false, and it is why the
golden expectation in the definition of done is a check rather than an
assumption.</decision>

<decision id="D5">A1 fallback, if the owner prefers rejection at review:
reject a non-prelude data/record declaration whose field type mentions a
carrier, with the same `mentions` traversal and the same D2/D3 rules. Same
traversal, different consumer — an error at the declaration instead of a
derived set. It closes the same hole; it forecloses D1(a) (Step must then
stay `extern data`, so the v2 twin needs grammar growth) and D1(b) (the
`Option (Suspension …)` baton becomes prelude-only).</decision>

## Non-goals

- **Making `Step` an ordinary `type`** (brainstorm B2). Enabled by this
  spec, specified separately, and gated on the owner accepting D1.
- **The `ContCell`/`Suspension` merge** (brainstorm §5c). Sequenced after
  this; carrier surgery with an open escape hole means verifying twice.
- **Linear/explicit-disposal** (brainstorm §5). Independent; both laws
  already forbid the double use this spec's hole permits.
- **The `headParamTypes` stopgap** (brainstorm A3). Subsumed: once `Box` is
  a derived carrier, `[Box g]` is a carrier in a list and the existing
  escape check fires. Do not implement both.
- `concCarrierTys` (`Infer.hs:1024`) — a hardcoded `["Promise", "Chan"]`
  name list gating Conc payload checks. It is a name-string check in a
  codebase that otherwise trusts markers, and it is unrelated to this hole.
  Noted, not touched.

## Tasks

Tiers per the subagent routing convention (spec completeness, not felt
difficulty).

**T1 — the closure (standard).** Add `carrierClosure` to
`Wok.TypeChecking.Env` (it owns `TyConInfo`/`ConInfo`/`RecordConInfo` and
already imports `CType`), exported explicitly. Signature shape:

```
carrierClosure :: Env -> Env      -- returns env with derived tcCarrier/tcAffine set (D4)
```

**Reuse the existing traversal.** `checkConcPayload`'s `goConFields`
(`Infer.hs:1076-1090`) is prior art that already does exactly this walk, for
its own purpose, and it answers the field-access question outright:

```
goConFields seen n = case lookupTyCon n env of
  Just info -> forM_ (tcCons info) $ \cn ->
    case lookupCon cn env of
      Just ci -> mapM_ (go seen) (conFieldTys (conArity ci) (schemeBody (conScheme ci)))
      Nothing -> case lookupRecordCon cn env of
        Just rc -> mapM_ (go seen . snd) (rcFields rc)
```

So: record constructors **are** listed in `tcCons` and are found by falling
back from `envCons` to `envRecordCons`; `conFieldTys` already peels the
arrow spine. Factor this field-enumeration out and share it rather than
writing a second copy — the two walks differ only in what they do at a
carrier, and a drifting duplicate is exactly how R2 happens.

`mentions` must be **total over `CType`**. The sketch above covers the
constructors at `Types.hs:110-116`; any constructor not listed there must be
handled deliberately, with a comment, rather than falling into a catch-all
`False`.

**T2 — wire it in (mechanical).** Call `carrierClosure` where the tycon and
constructor environment is complete and before body inference (D6), and drop
the two `Set.fromList` comprehensions at `Infer.hs:4330-4340` to plain
`tcCarrier` / `tcCarrier && tcAffine` filters over the now-derived flags.
Keep the existing comment explaining why the affine subset is narrower, and
extend it to record that the flags are closed under containment. The other
two `tcCarrier` readers (`Infer.hs:462`, `Infer.hs:1056-1061`) need no edit
**because** of the write-back — say so in the comment, so a future reader
does not "helpfully" re-derive a local set.

**T3 — reject fixtures (mechanical).** Under `test/typecheck-fail-examples/`,
from the session's probes (in the scratchpad, reproduced in the brainstorm):
`carrier-field-user-data.wok` (`Box`), `carrier-field-contcell.wok`
(`CellBox`), `carrier-field-nested.wok` (`data L = L [Suspension …]`, the
`args` traversal), and `carrier-field-exploit.wok` (the full `211`
double-resume program, which must now fail to TYPECHECK rather than run).

**T4 — accept fixtures, i.e. the anti-regressions (standard).** These are
the ones that catch an over-broad closure:
`test/typecheck-examples/user-data-step-not-carrier.wok` must still ACCEPT
(its `Step` is `Completed r | Suspended a r` — same names, no real carrier
field, so name-reuse must stay legal); a new fixture for D2
(`data F = F (() -> Step …)` accepts); a new fixture for D3 confirming
`Pair g 1` still fails with `CarrierEscape` from the use-site check rather
than from the closure.

**T5 — the prelude-invariance assertion (standard).** A test asserting that
for the prelude, the DERIVED carrier set equals the MARKED carrier set.
Verified by inspection while writing this spec: no prelude `data` has a
field mentioning `Suspension`/`Step`/`ContCell`/`Borrow` (`Request` carries
`Transport`, which wraps `U64`; `Fiber`/`Promise`/`Chan` wrap `U64`). This
test makes accidental future contagion in the prelude visible immediately
rather than as a mysterious `CarrierEscape` in user code.

**T6 — provenance diagnostics (frontier; OWNER'S CALL at review, droppable).**
A2's one real cost is user confusion: a `Box` is now second-class and
affine, and the user never wrote a marker. Today the failure is a bare
`CarrierEscape` naming only the binding. Mitigation: have `carrierClosure`
also return `Map Text (Text, Text)` — derived tycon to (constructor, field
type) that made it one — and thread it into the error rendering so the
message can say *"`Box` is a carrier because constructor `Box` holds a
`Suspension`"*. This needs either a new error constructor or env access at
render time, so it is the only task here that touches the error surface.
Drop it and the fix is still complete; keep it and A2 is teachable.

## Definition of done

1. All four T3 fixtures reject; all three T4 fixtures accept.
2. `WOK_WOKPARSE=$PWD/grammar/c/wokparse cabal run wok-tests` fully green.
3. `./scripts/typecheck-oracle.sh` green with **zero golden movement**, and
   no corpus file newly rejected. Verified while writing this spec: the only
   corpus declaration matching a carrier-typed field is
   `test/typecheck-examples/user-data-step-not-carrier.wok`, whose `Step` is
   `Completed r | Suspended a r` — same names, no `Suspension` field, does
   not import `Control` — so it stays clean. With no prelude or corpus type
   holding a carrier, nothing should move. Two distinct failure modes to
   watch, since D6 means this is a check and not a tautology: a golden whose
   *scheme text* changes (rigidification reached a row it did not before),
   and a previously-green file that now *errors* (the closure is
   over-broad). Either is a bug in the fix; neither is a contract update.
   Do not run `--update`.
4. T5's prelude-invariance assertion green.
5. The `211` exploit fails to typecheck; re-run it under
   `WOK_DEBUG_ONESHOT=1` to confirm the static law and the runtime oracle
   now agree (the oracle should never get the chance to fire).
6. `/code-review high` on the branch, findings fixed; full-branch review
   before any merge to main (house rule).

## Risks

<risk id="R1">**Over-broad closure silently narrows the language.** A type
that becomes a carrier by accident stops being returnable or storable, and
the diagnostic today does not say why. Guards: T5 pins the prelude, item 3
of the definition of done pins the goldens, and T6 (if kept) makes the
message explain itself.</risk>

<risk id="R2">**A field-type source the closure does not read is this same
hole through a different door.** Positional and record constructors are both
covered by reusing `goConFields` (T1). If any other declaration form carries
field types — future `D_Alias` in particular, where `type S = Suspension …`
would launder trivially — it must be routed through `mentions` too. The
implementer should enumerate the declaration forms that introduce field
types rather than pattern-match the two they happen to find.

**Effect-instance handles: verified closed, no work needed.** `isHandleType`
treats `CTCon (TcEffect _) _` as second-class, and `mentions` deliberately
has no `TcEffect` clause. Probed: `data HBox = HBox St` for an effect `St`
fails with `UnknownTyCon "St"` — an effect name does not live in the type
namespace, so a handle cannot be written as a field type at all and
containment through this family is structurally unreachable. Recorded here
so a future reader does not mistake the omission for an oversight.</risk>

<risk id="R3">**The arrow exemption (D2) is load-bearing and its soundness
lives in another pass.** If the closure exempts arrows but the capture rule
regresses, carriers escape through `data G = G (() -> Suspension …)` with a
captured `g`. The code comment must name the dependency, and the D2 accept
fixture should sit next to a reject fixture that captures rather than
produces.</risk>
