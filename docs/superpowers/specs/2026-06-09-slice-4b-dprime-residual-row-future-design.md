# Slice 4b″ — residual-row-carrying Future (capability reconstruction by type)

Date: 2026-06-09
Status: Design sketch for a DEFERRED follow-on to slice 4b (merged: `2026-06-09-one-shot-escape-design.md`).
Closes the soundness gap 4b documented (re-suspension / bounded-handler-escaped resume crashes a
well-typed program). The load-bearing PREREQUISITE/RISK is a kind-system extension (row-kinded
type parameters) — front-loaded in §2. Planning artifact: the implementing session MUST start with
brainstorming (Kickoff prompt at the end), then writing-plans, then subagent-driven-development.

Reads with: `2026-06-09-one-shot-escape-design.md` (slice 4b — esp. §5.2 the "capability
reconstruction by TYPE" crux this slice delivers, the Task 0 decision note, and §9's deferred 4b″
entry), memory `effects-slice-4b-one-shot-escape` (the "no handler anywhere" vs "bounded handler
escaped" distinction; the KNOWN LIMITATION section), `higher-ir-direction` + `one-shot-as-law`
(the decidable-HM / row-typed stance), `docs/koka.md` (row theory).

## 1. Summary

Slice 4b's `Future a b r` does **not** record the effect ROW of the parked continuation. So when
you `resume`, the tail re-performs effects that must be handled at the resume site — but the type
system doesn't track them. 4b catches the "**no handler anywhere**" case (the producer's effect
propagates to `start`'s call site → type error). It MISSES the "**bounded handler escaped**" case:
a handler present when the future was created but gone by resume time. At runtime the tail performs
that effect with no handler → **a crash on a program that type-checked** (a soundness gap, bounded
today only by the synchronous resumer resuming in-scope).

```wok
let s = (with logHandler in start producer) in   -- logHandler discharges Log around start, then RETURNS
resume s v                                        -- producer's tail re-performs Log -> NO handler -> CRASH (4b)
```

4b″ **row-indexes the future** — `Future a b r e`, where `e` is the residual effect row the parked
continuation performs on resume — and makes `resume`/`step` carry `e` in their own row, so the
**resume site must handle `e`**. The example above becomes a **type error**, not a crash. This is
the "capability reconstruction by TYPE" the 4b spec named as the EFFECT bound (§5.2) and deferred.

## 2. THE PREREQUISITE / RISK — row-kinded type parameters

`Future a b r e` needs `e` to be an **effect row in a (non-arrow) type-parameter position**. wok
already has effect rows, but only on **arrows** (`T -[row]-> T`) and effect applications. A row as
a **type-constructor parameter** likely requires a **kind-system extension**: a `Row` kind, and
`Future`'s last parameter is `Row`-kinded (`Future : * -> * -> * -> Row -> *`).

This is the load-bearing question for the whole slice — settle it FIRST in brainstorming:
- Does wok's kind system already admit a `Row` kind / row-kinded tycon params, or must it be added?
- If added: it should stay **decidable and HM-principal** — row *unification* already exists and is
  principal, so allowing rows as tycon params is a *kind* extension, not new *inference* complexity.
  Confirm against `src/Wok/TypeChecking/{Types,Class,Infer}.hs` (the `Kind` type, `resolveTyCon`,
  kind-checking of tycon applications) and the row representation. NO rank-2; row-poly only.
- If this proves to need more than a contained kind extension, STOP and surface it — it reshapes
  the slice (and may argue for an alternative encoding; see §Open Questions).

## 3. The design

### 3.1 The type

`Future a b r e` — `e` is the **residual effect row** the parked continuation performs when resumed.

- `start : (() -> r with Coro a b + e) -> Future a b r e with e`
  (`Coro` is discharged by `start`'s handler; `e` = the producer's NON-`Coro` effects, captured
  into the future AND emitted at the `start` site — the before-suspend effects happen during
  `start`.)
- `resume : Future a b r e -> b -> r with e`
  (resuming runs the tail, which performs `e` → the **resume site must handle `e`**.)
- `value : Future a b r e -> a` (pure read; no row).
- `cancel : Future a b r e -> () with ?` (cancellation drops the continuation; its row obligation
  is part of the deferred cancellation-runtime — likely `with e` or empty; settle in brainstorming).
- (If 4b′ has landed: `step : Future a b r e -> b -> Step … with e`, and the yield arm's tail
  future `s'` carries the same `e`. 4b′ and 4b″ compose; either may land first.)

### 3.2 Why this closes the gap

`e` ties the resume site to the parked tail's effects. In the bounded-escaped example, `logHandler`
discharges `e = Log` around `start`, but `resume s v : r with Log` requires `Log` handled at the
**resume** site — where `logHandler` has returned — so it is a **type error**. The "re-performed
effect with no re-establishable handler at the resume site = type error" goal (4b spec §5.2 crux)
is delivered. The "no handler anywhere" case (already caught by 4b) remains caught — now uniformly,
through the row.

### 3.3 Conservatism (intended, documented)

You cannot statically split "effects before the suspend" from "effects after it" (the suspend point
is dynamic), so `e` = the producer's **full** non-`Coro` residual row. This **over-approximates**:
an effect that only ever happens *before* the suspend is still required at the resume site. Sound,
occasionally over-requiring. A precise before/after split would need control-flow analysis of the
suspend point — out of scope; document the conservatism.

## 4. Scope

**IN:** the row-kinded `Future a b r e` (gated on the §2 kind extension); threading `e` through
`start`/`resume`/`value`(none)/`step`(if present); the resume-site row obligation that turns the
bounded-handler-escaped case into a type error; the negative test (bounded handler escaped →
type error) + positives (resume in-scope with the handler live still type-checks + runs).

**OUT (deferred):** precise before/after-suspend row splitting (use the conservative full residual);
the cancellation RUNTIME (only `cancel`'s row TYPE is in scope, if any); first-class futures / `box`;
the scheduler (layer 3). 4b′ (chaining) is INDEPENDENT — compose if present, don't require it.

## 5. Type correctness

Row-kinded `Future a b r e`; `start`/`resume`/`step` thread `e`; the resume obligation is the
ordinary effect-row discipline applied to `resume`'s declared row. Row unification (existing) is
principal; the only new piece is the kind extension (§2), which is a kinding rule, not an inference
change. No rank-2; row-poly only. Decidable + HM-principal IF §2 lands cleanly.

## 6. Open questions (settle in brainstorming — §2 FIRST)

- **§2 kind extension feasibility** — does wok admit a `Row` kind / row-kinded tycon params today,
  or must it be added, and how contained is that? THE gating question.
- **Alternative encodings if §2 is heavy:** e.g. encode the residual via an *existing* arrow-row
  rather than a new tycon param (does some `Future`-as-a-function-ish encoding carry the row on an
  arrow?), or a phantom/witness encoding. Compare for principality + ergonomics. (Likely the direct
  row-kinded param is cleanest IF the kind extension is contained.)
- **Conservatism** — accept the full-residual over-approximation (recommended) or invest in a
  before/after-suspend split (probably not worth it).
- **`cancel`'s row** — does cancelling owe `e` (it drops the tail, so arguably empty), tied to the
  deferred cancellation runtime?
- **Interaction with 4b′** — confirm `e` threads through `step`/the yield-arm tail future when both
  are present; neither slice should require the other.
- **Migration** — `Future a b r` (4b) → `Future a b r e`: existing 4b examples/tests gain an `e`
  (often empty for pure-tailed producers). Plan the golden churn.

## 7. Testing

- Negative (the headline): bounded handler escaped — `let s = (with H in start producer) in resume
  s v` where the tail performs `H`'s effect → a TYPE error (unhandled `e` at the resume site), NOT
  a runtime crash. (This is the 4b KNOWN-LIMITATION case, now caught.)
- Positive: resume in-scope with the handler still live → type-checks + runs (the 4b examples,
  now with an explicit/empty `e`).
- Positive: `coro-escape`/`coro-multi-driver` still run (their producers have empty residual `e`).
- The "no handler anywhere" case stays a (now row-uniform) type error.
- Kind tests: `Future U64 U64 U64 {Log}` (or whatever the row syntax is) kind-checks; a malformed
  application is a kind error.

## 8. Build / verify

`cabal build`; `cabal test` (expect golden churn from the new `e` parameter — read diffs before
accepting). If a grammar change is needed for the row-in-type-position syntax → BNFC regen + the 3
manual patches + no new shift/reduce conflicts. Full-branch review before merge to `main`.

---

## Kickoff prompt (paste into a fresh session)

```
Work on slice 4b″ for the wok language (repo /Users/zy/wokml): the RESIDUAL-ROW-CARRYING FUTURE
(capability reconstruction by TYPE), closing the soundness gap that merged slice 4b documented.
Branch from main first (feat/slice-4b-dprime). Standing rules: FULL-BRANCH review before any merge
to main; I prefer clarifying questions in prose (not multiple-choice).

START with brainstorming — and the FIRST thing to settle is the kind-system prerequisite (below),
because the whole slice rests on it. THEN writing-plans, THEN subagent-driven-development. TDD.

WHAT: slice 4b's `Future a b r` does NOT record the parked continuation's effect row. So `resume`
runs the tail, which re-performs effects, but the type system doesn't track them. 4b catches the
"no handler ANYWHERE" case (effect propagates to start's site). It MISSES the "bounded handler
ESCAPED" case: `let s = (with H in start producer) in resume s v` where the tail performs H's
effect — H has RETURNED by resume time, so at runtime it CRASHES on a program that type-checked
(a soundness gap, bounded today only by the synchronous resumer resuming in-scope). 4b″ row-indexes
the future — `Future a b r e`, e = the residual row — and makes resume carry e in its row, so the
RESUME SITE must handle e. The bounded-escaped case becomes a TYPE error, not a crash. This is the
"capability reconstruction by TYPE" the 4b spec §5.2 named and deferred.

THE PREREQUISITE / RISK (settle FIRST): `Future a b r e` needs an effect ROW in a non-arrow
type-PARAMETER position. wok has rows only on arrows today. This likely needs a KIND-SYSTEM
extension: a `Row` kind and `Future : * -> * -> * -> Row -> *`. It SHOULD stay decidable + HM-
principal (row UNIFICATION already exists and is principal; this is a KIND extension, not new
inference). Probe src/Wok/TypeChecking/{Types,Class,Infer}.hs (the Kind type, resolveTyCon, kind
checking, the row representation). NO rank-2; row-poly only. If this needs more than a contained
kind extension, STOP and surface it — consider alternative encodings (carry the row on an arrow
rather than a tycon param; phantom/witness). The direct row-kinded param is preferred IF contained.

DESIGN (converged direction; confirm in brainstorming):
- start : (() -> r with Coro a b + e) -> Future a b r e with e
- resume : Future a b r e -> b -> r with e   (resume site must handle e)
- value : Future a b r e -> a                (pure read, no row)
- e = the producer's FULL non-Coro residual row (CONSERVATIVE — you can't statically split
  before/after the suspend; document the over-approximation).
- Closes the bounded-escaped gap; keeps the no-handler-anywhere case caught (now row-uniform).
- Composes with 4b′ (chaining) if present (step/the yield tail future carry e); neither requires
  the other.

OUT OF SCOPE: precise before/after-suspend row splitting; the cancellation RUNTIME (only cancel's
row TYPE, if any); first-class futures / box; the scheduler (layer 3).

OPEN QUESTIONS: §2 kind-extension feasibility (THE gate); alternative encodings if heavy; the
conservatism; cancel's row; 4b′ interaction; migration golden churn (every 4b Future gains an e).

READ FIRST: docs/superpowers/specs/2026-06-09-slice-4b-dprime-residual-row-future-design.md (this
design), 2026-06-09-one-shot-escape-design.md (slice 4b — esp §5.2 the capability-reconstruction
crux + the Task 0 note + §9), memory effects-slice-4b-one-shot-escape (the "no handler anywhere"
vs "bounded handler escaped" distinction + the KNOWN LIMITATION section), docs/koka.md (row theory),
src/Wok/TypeChecking/{Types,Class,Infer}.hs (kinds, rows, resolveTyCon), prelude/Std/Control.wok
(start/resume/value), src/Wok/TypeChecking/Carrier.hs (the carrier/affine machinery to thread e
through).

BUILD/TEST: cabal build; cabal test (expect golden churn from the new e param — read diffs before
accepting). Grammar change (if row-in-type syntax needs one) → BNFC regen + 3 manual patches + no
new shift/reduce conflicts. Full-branch review before merge.
```
