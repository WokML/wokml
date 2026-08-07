---
You are implementing the wok v2 handler surface in the C front end (grammar/c), on branch docs/redesign-v2-surface in /Users/zy/wokml. Both the C front end and the design bundle live on THIS branch — do not switch branches (the bundle exists only here; the tree also carries other branches' uncommitted WIP — never sweep it; commit via pathspec).

Read first, in this order:
1. docs/redesign/spec-min.md — the one-page NORMATIVE reference for this work: keywords, grammar, the four-step pure-syntax clause classification, checks in pipeline order, five-line semantics for error wording, canonical examples. Where spec-min.md and spec.md disagree, spec.md wins — REPORT the disagreement, never silently pick.
2. docs/redesign/spec.md sections 1.0–1.2 and decisions D22–D28 — the authority and the whys (spec-min §7 maps each rule to its decision).
3. The recent grammar/c commit log — the front end was built BEFORE 2026-08-04, so it predates every decision you are implementing.

The task: sync grammar/c (scanner, layout filter, parser, formatter, linter) to the 2026-08-04 surface. The delta, newest spec first: D25 — the once keyword is CUT, control clauses are classified by the COMMA ALONE (op args, k -> body); once at clause-head emits the migration diagnostic "v1 clause keyword; drop it". D24 — new abort clause kind, op-arity patterns, NO continuation binder. C8 — exactly one bare lowercase varid after the comma; left of a comma, binder count = op arity for every kind. D26 — value bindings non-recursive (let off = off + 4 rebinds), function equations recursive; value self-reference errors with the eta hint. D27 — := write-locality, the E-VARSCOPE voices, the boundary list. D28 — diagnostics vocabulary only.

Scope discipline: the front end owns spec-min §4's parse-time checks and the resolution-time checks (effect declarations in hand). The "later analyses" list (E-ABORT, E-SHADOW, E-AFFINE, E-ESCAPE) is NOT parser work — do not implement it, do reserve the vocabulary.

Method: start with a DIFF, not code — read grammar/c's implemented clause grammar, produce the delta list against spec-min §1–3, brainstorm, write the slice spec, review, then implement. Conformance is the corpus: docs/redesign/examples/ (12 accept + 14 reject, EXPECT lines pin codes and positions — verify columns against the files, not memory). Existing grammar/c disciplines hold: C23, generated files under build/, roster/schema tests green, formatter round-trips, shrink before reporting, JSON Lines diagnostics. Probe empirically; killer programs over prose; if two docs disagree, stop and report. No emojis; clean up temp files; small commits via pathspec.

Facts that save an hour: clause classification is pure syntax (keyword → once-migration → comma-or-not; never names, types, or counts). A single clause may share the handler head's line. handle is two-tier (statement requires its label; inline elides). Signatures precede equations (D23) — use them as resync anchors. The v1 retrofit branch keeps once deliberately; you are building v2 only.

---