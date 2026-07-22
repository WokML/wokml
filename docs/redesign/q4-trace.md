# Q4 prototype trace — stored control vs label environments

Resolves former open question Q4 of `spec.md`: when a stored continuation (or
suspension) is resumed, which label environment do its residual performs — and
its handler's arm-residual performs — resolve against? Method: empirical
probes against the CURRENT compiler (2026-07-21, branch
feat/tco-and-recursive-joins), then the v2 rule derived from what the machine
already guarantees.

## The candidates

- (a) LEXICAL CAPTURE: residual labels bind at capture time; resuming after a
  captured activation died is a use-after-free in naming clothes unless a
  lifetime-entanglement analysis forbids it.
- (b) LATE-BOUND: residual labels re-resolve at the resume site; sound via the
  row obligation, but makes labels late-bound for stored control,
  contradicting the lexical resolution rule of spec 1.3.
- (c) CONFINEMENT: stored control cannot leave the extent of the handlers it
  was captured under, so capture-site and resume-site environments are the
  SAME live activations — (a) versus (b) is unobservable.

## Empirical probes

| Probe | Program shape | Result |
|-------|---------------|--------|
| baseline | `test/rc-m3/01-store-resume.wok`: store/take/resume within the arm's own extent | prints 2 (works) |
| p4 within-extent | suspend, resume under the SAME enclosing `with reader 10`; producer performs Reader AFTER resume | prints 15 (works; sees the live provider) |
| p2 cross-env | `(with reader 10 in start producer)` then `with reader 99 in run g 5` — pending Reader obligation crosses the reader boundary | REJECTED: `CarrierEscape (12,1) "main"` |
| p5 unrelated | producer with EMPTY residual row crosses out of a reader boundary it does not use | REJECTED: `RowMismatch (13,14)` (row-variable plumbing) |
| p3 no provider | resume with no Reader in scope at all | REJECTED: `UndischargedEffect "Reader"` |

Probe sources (final surface of the current compiler):

```
-- p4 (accepted, 15): resume inside the provider's extent
producer u = let a = Coro.suspend 0 in a + Reader.ask
main = with reader 10 in
  (case start producer of
     Completed r   -> r
     Suspended x g -> run g 5)

-- p2 (CarrierEscape): the same, but the Step crosses the reader boundary
main = case (with reader 10 in start producer) of
    Completed r   -> r
    Suspended x g -> (with reader 99 in run g 5)
```

## Finding

The current machine implements (c), CONFINEMENT, via two independent fences:
a suspension whose residual row mentions a handler's effect cannot cross that
handler's boundary (`CarrierEscape`, p2), and in practice even an
empty-residual carrier is stopped by row-variable plumbing (`RowMismatch`,
p5). Within the extent, resumption is fully supported and residual performs
find the same, still-live activations (p4, baseline). Resuming without a
provider is a static row error (p3). Consequently:

- The Q4 "renamed environment" and "dead activation" cases are STATICALLY
  UNWRITABLE today. There is no dynamic question to answer; the type system
  answers it before runtime.
- Lexical-versus-late-bound is vacuous under confinement — both would produce
  identical behavior in every expressible program.

## The v2 rule (adopted as D15)

Stated in label vocabulary:

1. A second-class consuming carrier (Suspension, ContCell) MAY NOT escape the
   extent of any `handle` whose label appears in its residual row. Violations
   render as E-ESCAPE: "suspension `g` still needs label `Reader` bound by
   the handle at <pos>; it cannot escape that handle's extent" (replacing
   today's `CarrierEscape` voice). Sibling shapes route separately: resuming
   with NO provider anywhere in scope (p3, today `UndischargedEffect`) is
   E-AMBIENT per the spec registry — nothing escaped, a label is missing;
   the p5 shape (empty residual row crossing an unrelated boundary, today
   `RowMismatch`) may lawfully be ACCEPTED per the precision note below — an
   implementation that keeps the rejection renders it as E-ESCAPE.
2. Within the extent, resume-site and capture-site label environments are
   therefore identical and live; residual performs (the continuation's own
   AND those of re-installed handler arms) resolve to those activations.
3. A Handler value's own arm row (`Handler E a b with (log : Writer [...])`) is
   discharged at its `handle` site; the activation is confined within those
   providers, and any stored continuation containing the activation inherits
   that confinement. The arm-residual UAF scenario of Q4 is unconstructible.
4. RC consequence: because dead-activation resume is unwritable, the M2b
   owned-set discipline needs no extension for labels.

Precision note: today's p5 rejection (empty residual crossing an unrelated
boundary) looks like row-plumbing coarseness rather than intent; rule 1 only
REQUIRES confinement for labels actually in the residual row. v2 may lawfully
accept the p5 shape if its kinded rows keep the variable clean — an allowed
refinement, not an obligation.

## Addendum: owner-review probes for D15/D16 (2026-07-22)

Four fresh probes against the current compiler, closing the owner review of
the confinement/wrapper core:

| Probe | Program shape | Result |
|-------|---------------|--------|
| d16-p1 | Step returned through ONE user function (`relay c = start c`) | REJECTED: `CarrierEscape "relay"` |
| d16-p2 | Step stored in a tuple | REJECTED: `CarrierEscape "main"` |
| d15-p3 | a handler whose ARM performs Writer sits inside the coroutine; suspension crosses it; resume under `with writer` | ACCEPTED: prints (42, [42]) — the arm's tell fired post-resume |
| d15-p4 | the same Step crossing the writer boundary to resume under a different writer | REJECTED: row mismatch (the q4-p5 voice) |

Conclusions adopted into the spec:

1. ROW COMPOSITION is the load-bearing equation behind rule 1's coverage of
   arm-origin obligations, now certified empirically:
   handle-expression row = (body row \ E) + the handler's arm row.
   An arm-origin entry (d15-p3's Writer) therefore flows into any carrier
   captured across the handle, and rule 1's residual-row keying confines it
   (d15-p4). The delta review's V6/UAF attack is closed by observation, not
   only by text.
2. STEP'S TRAVEL RULE, pinned: Step is STATICALLY second-class regardless
   of which constructor it dynamically holds; it is born only from the
   language-defined producers (`start`/`step`, extern trust anchors) and is
   eliminated by `case` in the scope that received it. Even a one-layer
   user relay returning it is rejected (d16-p1) — section 2's
   cannot-be-returned rule holds with NO user-facing exception; the only
   returner of a Step is the trusted primitive itself.

## The named ceiling

Confinement is also the known expressiveness ceiling: cross-environment
resumption — a scheduler moving parked continuations between contexts — is
exactly what the M3 notes call "cross-arm scheduler not HM-expressible;
answer-decoupling next". Lifting confinement would make the Q4 cases REAL and
require the late-bound design (candidate (b): carrier rows re-discharged by
label at the resume site, `use ... as` bridging renames, E-AMBIENT on missing
labels). That sketch is retained here for that day; it is out of v2 scope,
which freezes the CURRENT feature set — and confinement is the current
feature set, empirically certified above.
