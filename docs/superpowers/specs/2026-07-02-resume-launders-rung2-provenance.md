# Resume-launders-effects — rung 2 (residual provenance / escape analysis)

> **SUPERSEDED (2026-07-03).** Rung 2 is IMPLEMENTED. The chosen mechanism (caller-root
> residual provenance) and its final design live in
> `2026-07-03-resume-launders-rung2-caller-root-provenance-design.md`; the plan is
> `docs/superpowers/plans/2026-07-03-resume-launders-rung2-caller-root-provenance.md`.
> This doc is kept for its problem statement and the CLOSED/OPEN table, but its
> "candidate mechanisms" section and OPEN status are historical. The remaining gap
> is the inner-abstraction family (`docs/superpowers/2026-07-02-lambda-effect-laundering-note.md`).

Status: **OPEN — needs its own brainstorm** (2026-07-02). This is the second rung of
the "resume launders effects" epic. Rung 1 (the load-bearing residual row for the
DIRECT + arm-hosted positions) is implemented and merged-pending on
`feat/resume-launders-loadbearing`; see
`2026-07-02-resume-launders-effect-row-loadbearing-spec.md`. Do NOT start coding
rung 2 from this doc — it records the problem, the evidence, and the candidate
mechanisms so a future brainstorm can converge. Precursor decision (still binding):
`2026-07-02-resume-launders-effect-row-explicitness-decision.md` (explicit, not
inferred). Memory: `[[explicit-resume-effect-laundering]]`.

## 1. Why rung 2 exists (the rung-1 finding)

The rung-1 spec assumed a single emitter-site change closes the "resume launders
effects" hole. That assumption was **empirically disproved during review**: a
reviewer patched the compiler to record (instead of exempt) the residual at the
handler-discharge site, and it **broke three legitimate programs**
(`coro-residual-handled`, `coro-residual-multi`, `11-effect-collect`). So the
discharge-site exemption is load-bearing for soundness, and "record everywhere" is
not a cheap fix.

Root cause: **effect-row metavariables carry no provenance.** After
`dischargeEffects` strips the handled labels, a handler's own benign leftover
sub-ambient tail and a genuinely-unhandled residual (e.g. `run g 0`'s `e`) are
BOTH a bare `Unbound KEffect` `TVar` that closes to empty at the binding boundary.
Nothing local distinguishes "this bare tail is dischargeable plumbing" from "this
bare tail is a laundered obligation." Rung 1 handles only the positions where the
residual reaches the enclosing declared ambient **directly** (top-level driver
bodies + resume calls in arm bodies, exempted by resume-row identity). Where the
residual passes through a handler's sub-ambient discharge, it still launders.

## 2. What rung 1 closed vs. what rung 2 must close

CLOSED by rung 1 (death tests exist —
`test/typecheck-fail-examples/resume-launders-{undeclared,in-arm,in-named-arm}.wok`):
- Top-level resume driver: `drive g = run g 0` under a closed sig → rejected.
- Handler-arm-hosted: `with { Ask.ask -> run g 0 } Ask.ask` → rejected.
- Named-handler-arm-hosted → rejected.

OPEN — rung 2's targets (characterization tests pin them as currently-ACCEPTED,
`test/typecheck-examples/launder-leak-*.wok`; rung 2 flips them to
`UndischargedEffect`, a conscious golden flip):

| Leak | Program (closed sig) | Mechanism |
|------|----------------------|-----------|
| Handled-expression | `driveHandledExpr g = with { Ask.ask -> 0 } (run g 0)` | discharge-site terminal exemption |
| Nested handlers | `driveNested g = with H1 (with H2 (run g 0))` | same, compounded |
| Runner-sugar | `driveSugar f = with s = state 0 in f ()` (`f : () -> U64 with eff e`) | `EWithNamed` `appRow` terminal exemption |

## 3. Candidate mechanisms (for the brainstorm to weigh)

- **(A) Unify-based propagation.** Thread the handled-expression's residual into
  the enclosing ambient tail (the mechanism `Std.Control.state` already relies on
  via `bodyRow`/`appRow` sharing). REJECTED at rung 1 as a blanket move: generalizing
  it regressed `state` (aliases a shared row var the named-handler machinery still
  needs to grow). A rung-2 version would need to apply it ONLY where the tail is a
  genuine obligation — which requires the same discrimination that is the hard part.
- **(B) Provenance / escape post-pass.** Give effect-row variables provenance, or
  run a post-hoc check: "does this row variable's representative appear in the
  declared type of something still live in the environment (a parameter's
  `(row e)`, an outer sig)?" — analogous to an occurs/escape check. A row var that
  traces back to a **caller-supplied** residual (a parameter's row) is an
  obligation; a **freshly-minted handler-internal** var that closes to empty is
  benign. This is the more principled route and generalizes, but it is a real
  analysis (design + soundness proof + review), not a tweak. This is the likely
  rung-2 direction; the brainstorm should pressure-test it against the `state` /
  `54-reentrant-routing` / `coro-residual-*` corpus that route (A) broke.

## 4. Separate, NOT part of this epic — the lambda gap

Review Gate 3 also surfaced a DIFFERENT, pre-existing hole with its own root cause:
`ELam` inference installs a plain ambient and unconditionally closes it with **no
obligation check at all**, so an effectful lambda applied under a closed sig can
launder (e.g. `(\x -> f()) 0` with `f : () -> U64 with eff e`). This is general
effect-laundering-through-lambda, orthogonal to resume/handlers, and would NOT be
fixed by rung 2's provenance analysis. It is tracked separately in
`docs/superpowers/2026-07-02-lambda-effect-laundering-note.md`. (Note: carrier-typed
variants are incidentally blocked by the existing affine carrier discipline, so the
specific `\x -> run g x` shape is safe for an unrelated reason; non-carrier
residuals leak.)

## 5. Success criteria for rung 2 (when it is eventually built)

- The 3 `launder-leak-*.wok` characterization examples flip from accepted to
  `UndischargedEffect` (conscious golden flips; move to `typecheck-fail-examples/`).
- ZERO regression on the corpus route (A) broke: `coro-residual-handled`,
  `coro-residual-multi`, `11-effect-collect`, `54-reentrant-routing`,
  `44-named-instance`, and the full prelude handler set.
- Full suite green; type-only (no runtime change), consistent with rung 1.
