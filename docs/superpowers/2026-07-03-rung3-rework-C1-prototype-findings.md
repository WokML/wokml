# Rung-3 rework — C1 prototype gate findings (2026-07-03)

Branch `feat/resume-launders-loadbearing`. Prototype behind switch
`rigidKEffectSkolems` (`src/Wok/TypeChecking/Infer.hs`), currently **False**
(inert; tree green). `Unify.hs` fully reverted after the probe.

## Verdict: the naive thesis (§2/§3 "one honest change at freezeSigSkolems") is FALSIFIED.

Making KEffect signature vars rigid does NOT drop in. Three coupled obstacles,
all reproduced against the built binary.

### Reproducer baseline (confirms §1 "Today" column exactly)
A-1 REJECT, FP-1 REJECT (the two false positives), FN-1/2/3/4 + A-2 ACCEPT (the
five false negatives), PROBE-1 REJECT, PROBE-2 ACCEPT. My 9 `.wok` reproducers in
`scratchpad/repro/` reproduce the documented behavior; death-test corpus (14) all
REJECT, accept corpus (10) all ACCEPT. Ground truth established.

### Finding 1 — site-2 (freezeSigSkolems) rigid ALONE breaks the PRELUDE.
With `rigidKEffectSkolems = True` and the old apparatus left on, results were
byte-identical to baseline — the apparatus masks everything. Turning the apparatus
off (gate `emitResidualTail`) and rebuilding: **every** program fails at
`typecheck in Std.Control: RigidEscape 701` — no test even reaches `Main`. The
rigid reconciliation rejects the prelude runners.

### Finding 2 — the clash is `E ~ {Reader | ...}`, NOT `E ~ RowEmpty`.
Instrumented `rigidUnify`: `skolem u=701 rk=KEffect vs t=RowExtend Reader`. The
offender is `reader : r -> (Reader r -> a with Reader r + eff e) -> a with eff e`
(and by extension `state`/`writer`/`except`, all open-sig runners). At the
`finalizeGroupTyped` reconciliation the declared open tail `e` (now rigid `E`)
meets an inferred effect row that STILL carries the concrete handled label
`{Reader | ...}`. Rigid unification (correctly, by its own rules) refuses to GROW a
rigid tail to absorb a concrete label. The flexible path silently absorbed it —
that absorption is load-bearing for how handler discharge currently types.
I also PERMITTED `rigid-KEffect ~ RowEmpty` (an open tail may be empty) as a probe;
it did NOT fix the prelude, confirming the problem is concrete-label absorption,
not emptiness. This is the C1(ii) COMPLETENESS failure the spec flagged, but deeper
than "harden the row arms": an effect tail participates in row rewriting/growth
that rigidity structurally forbids, and the reconciliation `unify declT tv` is the
wrong meeting point for effect rows (unlike KStar, where `a ~ u64` is a correct
reject).

### Finding 3 — even if reconciliation worked, the residual never reaches a wall.
`finishApp` (`Infer.hs:2475`) does `closeRow effRow` at EVERY application, and
`closeRow` (`:3858`) writes `Link RowEmpty` over a `TVar` cell WITHOUT going through
`rigidUnify`. So (a) residual tails are destroyed at each application before any
wall sees them (this is the actual laundering site — a bare tail is dropped, not
unified against the ambient), and (b) a rigid skolem tail would be silently
overwritten by `closeRow`, defeating rigidity at perform sites. The current
architecture deliberately DROPS residual tails and catches laundering via a
side-channel (`emitResidualTail` → pending obligations). Routing the residual
through unification instead requires re-plumbing `emitRow` (unify the tail into the
ambient), `closeRow` (rigid-aware), and the body-check instantiation site (rigid) —
plus a scoped closed-only skolemization so open runners survive Finding 2.

### "Which instantiation site(s)?" — MOOT.
The spec's AS3/D1 fork (site-2 only vs also site-1 body-check instantiation) can't
be evaluated: site-2 breaks the prelude at reconciliation before the site-1
question is even reachable. The obstacle is upstream of the site choice.

### Scoped form (D3) does NOT rescue it cleanly.
"Skolemize `e` only when it occurs in a closed declared arrow" cannot distinguish
`run : Suspension (row e) -> b -> r with eff e` (legit — `e` dischargeable via the
innermost open `with eff e`) from `drive : Suspension (row e) -> U64` (leak — `e`
only in a closed context): BOTH have `e` in a closed OUTER arrow's domain (curried
effect sits on the innermost arrow). Distinguishing them needs "e appears AND is
not covered by an open declared tail" — i.e. the same structural sig walk
`callerRootRefs` already does. The "principled replacement" collapses back into
structural analysis.

## C2 (blast radius) — BLOCKED.
C2 measurement requires a prototype whose prelude compiles. Finding 1 shows it does
not. No blast-radius number can be produced until the completeness obstacle
(Finding 2) is resolved. C2 is therefore not resolvable at this gate.

## Recommendation (spec-sanctioned outcomes, user to steer)
Per the C1 response clause ("if, after a bounded effort, rigid KEffect row
unification cannot be made complete, fall back to NG2"):

1. **NG2 — post-hoc escape pass over elaborated Core** (spec's stated fallback):
   re-derive the residual obligation structurally AFTER elaboration, decoupled from
   the unifier, so it never fights handler-discharge absorption. Cleaner than
   re-plumbing the unifier; principled; but is a fresh pass to design.
2. **Re-plumb the rigid path** (site-1 rigid + rigid-aware `closeRow` + emit-tail
   unification + scoped closed-only skolemization threaded as ONE skolemization
   through body-check and reconciliation). Fights the discharge reconciliation
   (Finding 2); cost/risk assessed HIGH; comparable in size to the apparatus it
   deletes.
3. **Keep the rung-1/2/3 apparatus, fix its 2 false positives directly.** The spec
   rejected this as "a heuristic that needs principled replacement," but now that
   A-1/FP-1 are diagnosed, a targeted fix may be cheaper than either above. (The
   original diagnosis said A-1 is "not locally fixable" without weakening the death
   tests — worth re-litigating only if 1 and 2 are unattractive.)

My lean: **NG2 (option 1)** — it is the only path that stops fighting the unifier's
handler-discharge absorption, and the spec already names it the fallback.

## UPDATE — SCOPED rigid works (sound + complete on the whole corpus)

Going deeper on Option A revealed it cannot reconnect the erased inner residual to
the outer declared root for the point-free/let-bound FN cases (closeRow severs the
link before reconciliation) — it only covers the direct rungs-1/2 shapes. That
prompted re-testing the rigid approach C1 had dismissed, but SCOPED.

C1 tested the UN-scoped flip (rigidify EVERY effect-row sig var) → broke the prelude.
The missing piece: rigidify a sig's effect-row var ONLY when it is TRAPPED — it never
appears as an arrow effect-row tail in a POSITIVE (result-spine) position, i.e. the
function has no declared `with eff e` channel to perform it. Polarity matters: a
`with eff e` on a PARAMETER arrow is the caller's promise, not this function's channel.

Mechanism (~30 lines, apparatus OFF): a polarity-aware `dischargeableRowVars`
classifier over the declared CType + one conditional in `freezeSigSkolems`. The rigid
skolem is minted only at reconciliation (site 2), AFTER body inference, so closeRow
never touches it. The laundering that defeats Option A becomes the DETECTOR: the body
launders the trapped residual to `{}`, the declared rigid `E ≠ {}`, clash at
reconciliation = RigidEscape = the leak.

RESULTS (scoped-rigid ON, apparatus OFF):
- 9 reproducers: ALL correct (A-1/FP-1/PROBE-2 accept; FN-1/2/3/4/A-2/PROBE-1 reject).
- 14 launder death tests: ALL reject.
- typecheck-examples: 51/51 accept (0 false positives).
- typecheck-fail-examples: 105/105 reject (0 leaks).
- run-examples: 104/104 typecheck (the 1 flagged is `*-rejected.wok`, an intentional
  CarrierEscape reject, unrelated).
- Prelude compiles (open-sig runners spared by polarity).

This ACHIEVES the spec's original goal (delete the apparatus) which Option A could
NOT (Option A must keep the eager-recording half). C5 soundness holds: a trapped var
is polymorphic and un-handleable, so performing it under a closed wall is always a
leak; a phantom trapped var (e.g. `cancel`) is accepted because it is never performed.

Open items before shipping: (1) diagnostic mapping RigidEscape -> a laundering error
(C3/Q1); (2) full 2135-test suite + golden regen (goldens pin `UndischargedEffect`
text, will churn to the new error — expected); (3) Q3 two-named-effect fixture;
(4) actually delete the apparatus + confirm no dangling refs (AS3 grep).

REVISED RECOMMENDATION: scoped rigid skolemization (this), NOT the NG2 record-then-judge
pass. It is smaller, deletes the apparatus, and is sound+complete on the whole corpus.

## HARDER VERIFICATION (full suite + adversarial hunt)

Scoped-rigid ON, apparatus OFF.

### Full suite: 2135 tests, 27 "failures" — ALL golden-text churn, ZERO verdict regressions.
- 21 `typecheck-fail-golden/*`: death tests still REJECT; error text changed
  (UndischargedEffect/etc -> RigidEscape). Handled by diagnostic mapping (C3) + golden
  regen (task 6).
- 5 `typed-anf-golden/*`: cosmetic effect-row var RENUMBERING in the typed dump
  (e.g. `Suspension U64 U64 U64 a4` -> `... a0`); identical structure; still accept.
  Regen.
- 1 was the future/conc bucket subset (see below).

### SUBSUMPTION finding (real interaction, not a bug): 6 death tests now reject via
RigidEscape, MASKING their original FutureConsumedTwice (one-shot) / CarrierEscape
(second-class) errors: future-recursive-consume, future-await-twice,
future-helper-double-consume, future-resume-then-cancel (one-shot);
future-reperform-unhandled, conc-producer-capture (carrier). I read all 6: each is a
GENUINE DUAL-ERROR — the program really does perform/return a trapped polymorphic
effect (e.g. `run f 1` under closed `-> U64`; `main : Step (row e) = start producer`
over-promises like `f : a; f = 5`), so RigidEscape is a CORRECT rejection that merely
fires first. NOT a false positive. But it means these files no longer isolate the
one-shot/carrier checks (lost regression guards). FIX (task 6): give each a `with eff e`
channel so it does NOT leak, isolating the original bug. VERIFIED: adding `with eff e`
to future-await-twice restores `FutureConsumedTwice (Just (7,1)) "g"` (not RigidEscape).

### Adversarial battery (hand-built, 16 cases): ZERO false positives, ZERO missed leaks.
- 8 valid cases (phantom-hold via cancel, ignore-arg, declares-e-unused, two-trapped
  none-performed, HOF passthrough, declared `with eff e` performer, where-local open):
  all ACCEPT correctly.
- 8 leak cases (step under closed, HOF-indirect `(\f->f s)(\x->run x 0)`, sig-local
  generalized, two-params-perform-one, fn-param let-bound, under-other-handler,
  branch-perform): all REJECT correctly.
- NON-issues: `passthrough : Suspension (row e) -> Suspension (row e)` rejects via
  pre-existing CarrierEscape (can't RETURN a second-class Suspension) — unrelated to
  the change; `pair-extract` used undefined `fst` (malformed test).

Independent adversarial subagent sweep (named/two-effects, polarity/data-type boundary,
higher-rank, mutual recursion, unusual performers): PENDING.

### Independent adversarial subagent (32 cases): ZERO false positives, ZERO missed leaks.
Covered: named-effect coexistence (two DIFFERENT named effects), data-wrapper/tuple/list
threading, all six performers (run/step/drainOne/parBoth/race/runRace), HOF callbacks,
helper routing, mutual recursion, where-locals, curried returned-closures.
- Two-distinct-row-var conflation (the flagged category-A gap): NOT conflated.
  `leak-two-rows-masked` (trapped `e` performed, only a different var `f` declared as a
  channel) is correctly REJECTED. Per-variable rigidity keeps distinct channels distinct.
- POLARITY boundary is effectively UNREACHABLE and SOUND-by-default: user data cons
  cannot hold `with eff e` arrows in fields; effect vars ride only as bare `(row e)` args
  on Suspension/Step, which are collected in NEITHER polarity -> conservatively TRAPPED
  (the sound direction). So the covariant-CTCon approximation cannot be exploited. This
  DOWNGRADES documented limitation #1 to a non-issue for the current language.
- CarrierEscape cases (returning/escaping a live second-class Suspension/Step) are the
  pre-existing carrier discipline, not this check.

## FINAL VERIFICATION VERDICT: scoped-rigid is SOUND + COMPLETE on the whole corpus +
## adversarial hunt (48 crafted cases + 2135-test suite + full prelude), ZERO verdict
## regressions. Remaining work is mechanical: diagnostic mapping (C3), delete apparatus
## (§4), reclassify 6 subsumed death tests (add `with eff e`) + regen goldens, add Q3
## fixtures. Only surviving boundary: higher-rank effect polymorphism (not a current
## feature; revisit if the language grows). RECOMMENDATION: adopt scoped-rigid.
