# Handoff: Control.wok v2 twin (last module of the prelude-v2 epic)

Paste-ready prompt for a fresh session. Everything referenced is committed.

---

Start the Control v2 rework. Read
`docs/superpowers/specs/2026-08-08-prelude-v2-rework.md` (the Execution
status section) first, then this file. Work on a fresh branch off
`feat/prelude-v2-phase3` (or off main if that branch has merged).

## State you inherit

- main (590fec0): handler values (item 4), the four Control runners as
  handler-value producers, the sexp mapper's handle family closed, oracle at
  82 goldens.
- `feat/prelude-v2-phase3` (148dd38, pushed): v2 twins + checked-in wokparse
  dumps for five of six preludes under `prelude/v2/`, gated by two test
  groups in `test/Spec.hs`:
  - `Prelude.V2Twins` (ungated): each checked-in `prelude/v2/M.sexp`, mapped
    through `Wok.Sexp.Surface`, must be normalized-tree-EQUAL to the v1
    parse of `prelude/M.wok` (tree equality implies environment equality).
  - `Prelude.V2Freshness` (WOK_WOKPARSE-gated): dump byte-equals a fresh
    `wokparse -sexp` run.
  - Both groups DISCOVER `prelude/v2/*.wok` — dropping `Control.wok` +
    `Control.sexp` in gates them automatically; no Spec.hs edit needed.
- `prelude/Control.wok` (309 lines) is the only module without a twin.

## Step 1 — the design decision (brainstorm + spec BEFORE any code)

The blocker: `extern data Step a b r (row e) = Completed r | Suspended a
(Suspension a b r (row e))` is a TRANSPARENT extern ADT and v2 has no
spelling for it. Verified: v2 `extern type` is opaque-only (probe
`extern type Step ... = ...` → parse error at the `=`; the C schema's
`D_ExternType` carries no constructor field). Options to brainstorm, not
prejudged:

1. Grow v2: an `extern type X ... = Con ... | ...` production
   (grammar/c parser + sexp schema constructor field + `Wok.Sexp.Surface`
   mapping to v1's `DExternData`).
2. Restructure: make `Step` an ORDINARY `type` (its constructors are public
   anyway) and keep only `Suspension`/`ContCell` extern-opaque. Before
   choosing this, check what actually keys on Step being extern: the
   carrier/consume-once discipline "rides the extern marker" — grep the
   trust anchors in `Wok.TypeChecking.Carrier`, `Wok.IR.Multiplicity`,
   `Wok.IR.Escape` for how Step is classified.
3. Something better from the coroutine redesign itself.

This is agenda item #1 of the coroutine + String-method planning
conversation the owner asked for — so produce a short spec and get the
owner's review before implementing. Constraints that stand: one-shot is the
law; carriers are second-class; `extern` is the prelude-only trust anchor
and analyses trust the MARKER, not names; the C typechecker consumes the
result, so surface changes move the 82-golden contract (regenerate + audit
if so, otherwise expect ZERO golden movement).

One more probe to run during the spec (untested this session): the `except`
runner's arm drops its continuation (`once throw e k -> Err e`). Check
whether v2 accepts a control clause with an unused k (`throw e, k -> Err e`)
or whether E-ABORT totality forces the `abort` clause spelling. If `abort`
is forced anywhere, the mapper's `abort-clause` gap must close — the
faithful mapping is `abort op ps -> body` → v1 `HOnceUArm op (ps ++
[APWild])` (v1 already types a wildcard continuation binder; verify
semantics with a twin-pair fixture before relying on it).

## Step 2 — translate (faithful 1:1, verified spellings)

Everything else in Control translates on spellings probed green this
session: `extern type Suspension a b r (row e)`; extern sigs (operators
included); `with eff e` rows; effect decls in block form (`effect Coro a b`
+ indented `op : type` lines); `data` → `type ... = A | B`; `let ... in` →
block lets; no `;` (columns only); no `once` (comma classifies: plain
`op ps ->`, control `op ps, k ->`, `return v ->`); `handler E` /
`handle [n =] h in` for the four runners (already handler-value producers
in v1). Do NOT redesign any surface beyond the spec'd Step decision.

## Definition of done

1. Owner-reviewed spec for the Step spelling; implementation per that spec.
2. `prelude/v2/Control.wok` + checked-in dump; wokparse accepts; both
   discovery gates green.
3. Mapper extensions only on demand (a gap firing on the Control dump).
4. `WOK_WOKPARSE=$PWD/grammar/c/wokparse cabal run wok-tests` all green;
   `./scripts/typecheck-oracle.sh` green; golden movement only if the spec
   changed surface, audited not blind-accepted.
5. `/code-review high` on the branch, findings fixed; full-branch review
   before any merge to main (house rule).
6. Update the epic spec's status section + memory: Control twin done, R3
   fully retired, the C typechecker epic unblocks.
