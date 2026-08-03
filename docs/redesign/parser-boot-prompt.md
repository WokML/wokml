# Boot prompt — sync the C front end to the v2 handler surface

Paste everything below the line into a fresh session.

---

You are implementing the wok v2 handler surface in the C front end
(`grammar/c`), on branch `docs/redesign-v2-surface` in `/Users/zy/wokml`.
Both the C front end and the design bundle live on THIS branch — do not
switch branches (the bundle exists only here; the tree also carries other
branches' uncommitted WIP — never sweep it; commit via pathspec).

## Read first, in this order

1. `docs/redesign/spec-min.md` — the one-page NORMATIVE reference for this
   work: keywords, grammar, the four-step pure-syntax clause
   classification, checks in pipeline order, five-line semantics for error
   wording, canonical examples. Where spec-min.md and spec.md disagree,
   spec.md wins — REPORT the disagreement, never silently pick.
2. `docs/redesign/spec.md` sections 1.0-1.2 and decisions D22-D28 — the
   authority and the whys (spec-min §7 maps each rule to its decision).
3. The recent `grammar/c` commit log — the front end was built BEFORE
   2026-08-04, so it predates every decision you are implementing.

## The task

Sync `grammar/c` (scanner, layout filter, parser, formatter, linter) to
the 2026-08-04 surface. What changed, newest spec first:

- D25: the `once` keyword is CUT. Control clauses are classified by the
  COMMA ALONE: `op args, k -> body`. `once` at clause-head position emits
  the migration diagnostic "v1 clause keyword; drop it" — it is reserved
  there and ONLY there.
- D24: new `abort` clause kind — `abort op args -> body`, op-arity
  patterns, NO continuation binder.
- C8 (two amendments): in a control head, exactly one bare lowercase
  varid follows the comma; left of a comma, binder count = op arity for
  every clause kind.
- D26: value bindings (no parameters) are NON-recursive — `let off = off
  + 4` rebinds; function equations (with parameters) stay recursive and
  group. A value RHS referencing its own binder is an error with the eta
  hint.
- D27: `:=` write-locality — the E-VARSCOPE voices and the boundary list
  (lambdas, local function equations, handler literals; NOT blocks/case
  arms/if branches). Clause-body resolution: args -> batons -> enclosing.
- D28: E-SHADOW = the usability region (only relevant to the front end
  as diagnostics vocabulary; the check itself is a later analysis).

Scope discipline: the front end owns spec-min §4's parse-time checks and
the resolution-time checks (effect declarations in hand). The "later
analyses" list (E-ABORT, E-SHADOW, E-AFFINE, E-ESCAPE) is NOT parser
work — do not implement it, do reserve the diagnostic vocabulary.

## Method (the workflow that built everything here)

1. START WITH A DIFF, NOT CODE: read grammar/c's implemented clause
   grammar and produce the delta list against spec-min §1-3. Brainstorm,
   write the slice spec, get it reviewed, then implement.
2. CONFORMANCE IS THE CORPUS: `docs/redesign/examples/` — 12 accept + 14
   reject, each reject carrying an `-- EXPECT:` line with code, message
   shape, and positions. The parser slices should end with these parsing
   (accepts) and diagnosing (rejects whose fault is front-end-visible:
   reject/02 E-ARITY, reject/12 E-ARITY, the `once` migration form).
   spec-min §6's canonical examples are the smoke set.
3. The existing grammar/c disciplines hold: C23, every generated file
   under `build/`, the roster/schema tests stay green, the formatter
   round-trips (parse -> print -> parse = identity), shrink before
   reporting, resync at item boundaries, JSON Lines diagnostics.
4. Positions are load-bearing: reject EXPECT lines pin line:col. The
   comma moved binder columns once already (reject/03: k at 14:11) —
   verify against the files, not memory.
5. Probe empirically before deciding; killer programs over prose; if a
   rule seems wrong or two docs disagree, STOP and report — the bundle
   has a challenge/response process for exactly that.
6. No emojis in code. Clean up temp files. Small commits, one concern
   each, `git commit -- <paths>`.

## Facts that will save you an hour

- Clause classification is PURE SYNTAX (spec-min §3): keyword, else
  `once`-migration check, else comma-or-not. Never names, types, or
  counts. Arity checks come later, with the effect table.
- A comma head takes exactly ONE bare varid after the comma — a pattern
  there is E-ARITY at parse time.
- A single clause may share the `handler` head's line
  (`reader e = handler Reader ask -> e`).
- `handle` is two-tier: statement form REQUIRES its label; inline
  (`handle [l =] h in e`) may elide it.
- Signatures precede equations (D23) — single-pass declaration
  processing is guaranteed; use signatures as resync anchors.
- The v1 retrofit branch (`feat/retrofit-once-return`) keeps `once` —
  that surface has no comma; the divergence is deliberate. You are
  building v2 only.
