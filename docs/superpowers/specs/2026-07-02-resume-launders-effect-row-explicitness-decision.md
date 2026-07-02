# Resume-launders slice — effect-row explicitness decision

Status: **DECIDED** (2026-07-02). A design decision for the queued "resume launders
effects" slice (Option B: make the residual effect row load-bearing). Seeds the
eventual full spec; records the write-vs-infer question as resolved so it is not
re-litigated. Related: `docs/superpowers/specs/2026-06-11-resume-site-control-and-heap-continuations-design.md`,
`docs/effect-handlers-explainer.html` item 1.

## Decision

Effect rows stay **EXPLICIT**. A missing `with` clause means **pure** (empty row),
NOT "infer the row" — performing an effect you did not declare stays a compile
error (`UndischargedEffect`). Option B simply extends this existing discipline to
its one loophole: performing a bare row variable `e` (the coroutine residual)
must obligate the enclosing row, so a resume/await driver must write `with eff e`
exactly as it must already write `with State`. No silent effect inference.

Uniform law after the slice: **every effect you perform — concrete or polymorphic
— must appear in your signature.** One rule, no exceptions, no "is this the
inferred case or the pure case?" ambiguity.

## Why not inference (the rejected alternative)

Full effect-row inference (missing `with` = infer, Koka-style) is **sound** —
Koka is the existence proof (HM + row unification + a generalization discipline +
a boundary discharge gate). It is nonetheless wrong for wok, for two reasons:

1. **Structural — wok has no boundary gate.** wok's *sole* effect safety net is
   the declaration-site check: performing an undeclared effect is rejected on the
   spot (verified: `f : () -> U64` performing `State.get` → `UndischargedEffect
   "State"`), and the effect propagates up to `main` (typed pure), which is the
   de-facto boundary. There is **no** separate entry/`main` effect-discharge pass
   (confirmed by the FFI IO-effect work: "no entry-effect gate exists"). Inference-
   by-omission *deletes* this net — forgetting `with State` would be silently
   inferred, not caught — so recovering soundness would require **building** the
   entry-discharge gate wok deliberately lacks, plus re-auditing the second-class-
   handler / one-shot-multiplicity / named-instance interactions under inference.
   Cross-cutting, far larger than Option B itself.

2. **Philosophical — authored contract vs inferred metadata.** Inference converts
   a function's effects from an *authored contract* (the signature tells you what
   it does without reading the body) into *inferred metadata* (you must ask the
   compiler). That undercuts the project thesis of explicit, controllable effects
   and makes signatures non-self-documenting. The tension is fundamental: you
   cannot have both terseness (infer) AND the "you performed an undeclared effect"
   error — they are the same coin. Koka chose terse + boundary-gate; wok chose
   explicit + declaration-site. Both sound; wok's keeps signatures honest-by-
   authoring.

Ergonomic footnote: the explicit burden is small and *consistent with what wok
already requires* (you cannot omit `with State` today either). It falls only on
effect-polymorphic higher-order combinators (resume drivers, schedulers, map/fold-
likes), threads like a type variable, and is structurally far lighter than Rust
lifetimes — additive not constraining, no aliasing/variance/outlives dimension,
errors are local.

## Opt-in inference syntax (designed; DEFERRED — not in the first slice)

If verbosity ever proves painful, the sanctioned escape hatch is a **visible
opt-in placeholder**, NOT silent inference:

- **Token:** `_` in the effect-row tail — `with eff _` (or `with State s + eff _`).
  Meaning: "infer this row from the body / context."

- **Why it preserves the thesis.** It is opt-in and visible: a signature with no
  `with` still means pure (forgetting an effect is still caught); you get inference
  ONLY where you wrote `_`; and the `_` on the page still *declares* that effects
  flow here — the type is not lying, it says "effects present, ask for specifics."
  It is a middle point between spelling out the whole row and Koka's silent
  inference, and it does not touch wok's declaration-site safety net for any
  signature that does not opt in.

  ```
  -- explicit (default, the law):
  replay : Suspension U64 U64 U64 (row e) -> U64 with eff e

  -- opt-in inferred tail (same meaning; `_` solved to `e` from the body):
  replay : Suspension U64 U64 U64 (row e) -> U64 with eff _
  ```

- **Linkage caveat.** A row that must be *shared* between an INPUT (a callback's
  row — part of the contract) and an OUTPUT (the result) must stay a **named**
  variable, because `_` positions infer independently. Use `_` only in OUTPUT /
  determined positions; keep INPUT / contract positions (and the decision to have
  a row at all) explicit:

  ```
  -- callback row `e` is the CONTRACT (named); result row is inferred to equal it:
  map : (a -> b with eff e) -> [a] -> [b] with eff _
  ```

- **Why deferred.** For the resume-launders drivers the result row is usually the
  named residual `e` (linked to the `Suspension`'s row parameter), so `_` saves
  little *there*; its value is general convenience elsewhere. Ship the slice
  explicit-only first; add `_` as a fast-follow ONLY if the `with eff e` audit
  shows real verbosity pain. Adding it later is non-breaking (it is purely
  additive surface).

## Summary

Explicit is the default and the law. Inference is sound but self-defeating for
wok (deletes the sole safety net; converts contract into metadata). The `_` opt-in
placeholder is the visible, thesis-preserving escape hatch, designed here but
deferred until proven necessary.
