# Prelude v2 rework: retiring the R3 carve-out

**Status: IN PROGRESS — phases 0–2 landed on `feat/prelude-v2-rework`; phase 3
blocked on the coroutine/String-method planning discussion (owner constraint:
no extern-surface work before that plan exists)**
**Date: 2026-08-08 (status updated same day)**

## Execution status (2026-08-08)

- **D4 resolved**: the three lineages merged into `feat/prelude-v2-rework`
  (`feat/retrofit-once-return` ⊂ `feat/handler-values-state`; one conflict-free
  merge onto the sexp-oracle lineage). Merge-to-main still awaits the owner's
  full-branch review.
- **Phase 0 — DONE** (arrived via the merge): `handler E { ARMS }` values,
  `handle [name =] h in body`, var seeding, named labels, carrier-escape gate.
  O3 answered favorably: ambient dispatch reaches a `handle` install without
  the P2 slot machinery.
- **Phase 1 — DONE** (24a0815, 8826f09, 61d2c7c): `Handler` became writable in
  signatures (item-4 C3); the four runners are handler-value producers; 23
  corpus/example files migrated to `handle` spelling. Two fixtures keep LOCAL
  callback-runner copies because the old shape is their subject
  (57-named-answers-ambient, launder-leak-runner-sugar). O2 resolved: by hand
  (3 mechanical shapes across ~23 files did not warrant a codemod).
- **Phase 2 — DONE for the handle family** (f5beb00): `E_Handler` maps to
  `EHandlerV` in all positions; `E_HandleIn` maps non-literal installs to
  `EHandleV`/`EHandleN`. Differential intersection +10 files, oracle 74→82
  goldens, all agreeing; accept/01's gap frontier is now its `:=` arm
  (E_Assign, an explicit non-goal). Statement-form `S_Handle`/`S_Use` stays
  unmapped — the v2 runners are expression-RHS `handler` values and never
  need it (revisit only if the phase-3 text does).
- **Known limit (review finding, 2026-08-08)**: the phase-1 migration moved
  the four runners onto `RMakeHandler`/`InstallHandler`, which Perceus
  declares not-RC-coverable, so binds using the prelude runners are no longer
  instrumented by the RC balance/differential oracle. The rc-m2b/rc-perceus
  corpora define LOCAL fused runners and lost nothing, but the oracle's reach
  over the real prelude narrowed; restoring it is an RC-coverage slice of its
  own (likely alongside the coroutine plan).
- **Phase 3 — FIVE OF SIX DONE (owner-approved 2026-08-08, faithful 1:1
  re-spelling only)**: `prelude/v2/{Array,Base,Borrow,Bytes,String}.wok` are
  v2 twins, each with a CHECKED-IN wokparse dump beside it. O1 RESOLVED as
  its leaning: v1 twins stay the corpus default until S5; the Prelude.V2Twins
  group (ungated -- dumps are checked in) requires each dump, mapped through
  Wok.Sexp.Surface, to be normalized-structurally EQUAL to the v1 parse of
  the v1 twin (tree equality implies environment equality -- schemes,
  fixities, instances -- so this is stronger than a scheme drift test);
  Prelude.V2Freshness (WOK_WOKPARSE-gated) byte-compares each dump against a
  fresh wokparse run (D1). The mapper needed ZERO extensions -- the phase-2
  expectations (D_Alias/E_Assign/S_Discard not needed) held. Translation
  deltas were purely mechanical: `data`->`type`, `class`/`instance`/`foreign
  module` drop `where`, one `let ... in` becomes a block let. Under twins,
  "R3 retired" means precisely: the v2 closure exists for these five modules
  and is drift-verified; BNFC remains the corpus default until S5.
- **Phase 3 residue — Control is OWNER-BLOCKED**: `extern data Step a b r
  (row e) = Completed r | Suspended ...` is a TRANSPARENT extern ADT, and v2
  has no spelling for it (`extern type` is opaque-only; probed, and the C
  schema's D_ExternType carries no constructor field). Choosing the v2
  spelling -- or restructuring Step -- is agenda item #1 of the coroutine
  planning conversation; Control.wok gets its v2 twin after that.
- **Phase 3 — BLOCKED before that plan** (context kept for the record):
  every prelude module carries `extern` compiler holes
  (Control: the whole coroutine/ContCell block; String: the method prims).
  Rewriting the text in v2 means re-spelling those surfaces, which the owner
  has frozen pending a coroutine + String-method plan. Planning input, from
  running `wokparse -check-only` over the CURRENT preludes:

  | module | v2 parse today | first blocker |
  |---|---|---|
  | Array | parses | — |
  | Bytes | parses | — |
  | Base | rejects | `data X = A \| B` sum spelling; `class … where` |
  | String | rejects | multi-line `let … in` body layout |
  | Borrow | rejects | `foreign module … where` spelling |
  | Control | rejects | `;` in handler blocks; `once`/`return` clause kinds (v2: comma-classified, `once` cut) |

  So the v2 rewrite is dominated by mechanical re-spelling (data/class/layout/
  foreign forms) — the extern coroutine/String surfaces translate 1:1 UNLESS
  the planning discussion changes their shape, which is exactly why it comes
  first.

**Date: 2026-08-08**
**Predecessor: 2026-08-06-sexp-ingestion-oracle.md (R3), docs/retrofit-item4-callback-runner-migration.md (item 4, worktree /Users/zy/wokml-retrofit)**

## Goal

Rewrite the six prelude modules (`prelude/*.wok`, 557 lines) in the v2
surface so that:

1. `grammar/c` wokparse parses them — the C typechecker epic gets prelude
   sources in its own dialect instead of a serialized environment blob;
2. the Haskell compiler consumes them through the same sexp path as user
   code, retiring the R3 carve-out ("preludes remain BNFC-parsed");
3. the 77-golden oracle contract (`scripts/typecheck-oracle.sh`) covers a
   corpus whose *entire* transitive closure is v2, so the future C
   typechecker never needs a v1 parser.

This epic was chosen over the freeze/thaw prelude blob (2026-08-08, owner
decision): more work now, but it removes the last v1 dependency and grows
the differential corpus instead of trusting a Haskell-produced artifact
forever.

## The load-bearing scope fact

The four `Control` runners are the exact idiom v2 deletes:

```
reader e c = with self = Reader { ask -> e } in c self
```

Under redesign D9 a capability is never a first-class term, so `c self` is
grammatically inexpressible in v2 (see redesign gap audit, 2026-07-22).
The sanctioned migration is item 4: runners return `handler E { ARMS }`
values, call sites install with `handle [label =] h in body`, and the
callback disappears. Item 4 is therefore a HARD PREREQUISITE of this epic,
not an optional cleanup. The prototype (`proto/handler-values`, e997370)
proves the mechanism end to end but has two limits the preludes hit:

- **var seeding**: `state`/`writer` carry `var s = i` / `var log = []`
  handler-block batons. The item-4 spec (D-baton decision) says
  `handler State { var s = i ; ... }` captures the baton at install time;
  the prototype does not implement `var` params yet.
- **named handler values**: the corpus uses named instances
  (`with count = state 0 in ... count.get`). Item-4 D5 preserves this as
  `handle count = state 0` binding the role label; the prototype has no
  named/self value.

Both are enumerated as item-4 challenges; "land item 4" below means the
full spec including these, not the prototype as-is.

## Non-goals

- The `:=` frame-slot assignment surface. Item-4 C2 defers it; the migrated
  runners keep the two-arg-resume `once set x k -> k x ()` baton style and
  are NOT byte-identical to redesign accept/01 until `:=` lands as its own
  item.
- Deleting `Wok.Parsing`/BNFC (S5 of the oracle spec, still deferred — the
  Haskell test corpus is still v1-first).
- The C typechecker itself. This epic is its prerequisite; the goldens only
  stabilize when this epic lands (see D2).
- `grammar/go` and `grammar/Wok.cf` stay untouched.

## Phases

### Phase 0 — land item 4 in v1

Promote `proto/handler-values` to a real feature per
`docs/retrofit-item4-callback-runner-migration.md`: `handler E { ARMS }`
values, `handle [label =] h in body` install, `var` seeding, named-label
binding, plus the missing reject fixture for argument-position capability
escape (`handle c = state 0 in useIt c` — the runners' own shape, pinned
as illegal). Item-4 challenge C-ambient (does ambient `State.get` resolve
to a `handle`-installed activation without the P2 slot machinery?) is the
first thing to prototype-verify; if it needs the slot layer, the item-4
spec widens and this epic re-sequences.

### Phase 1 — migrate the runners and their call sites (still v1)

Rewrite the four `Control` runners as handler-value producers; migrate
every corpus call site from callback style to `handle ... in` style.
Blast radius (grep estimates, include comments): 66 corpus files import
Control, ~30 mention a runner. Full suite green; **regenerate the 77
goldens** — reader/state/writer/except schemes change, so the C-typechecker
contract moves (D2).

### Phase 2 — close the mapper gaps the v2 preludes need

Audit the rewritten preludes against the v2 tag map. Known state:
`D_ExternType` (class a) and `D_Foreign` (class b) are already mapped, so
`Borrow`/`Bytes`/`String`/`Control` extern and foreign-module surfaces
pass. The gap list that matters is the handler family: `E_Handler` maps
only structurally under `E_HandleIn` today; after phase 0 it maps to the
new v1 handler-value node in all positions. `S_Handle`/`S_Use`/`H_UseBind`
close the same way if the prelude text uses statement-form installs.
`D_Alias`, `E_Assign`, `S_Discard` are expected NOT to be needed — confirm
during the audit, extend only on demand.

### Phase 3 — rewrite the prelude text in v2

Translate `prelude/*.wok` to v2 surface (v2 twins live next to or replace
the v1 files — see O1). wokparse must accept all six; the Haskell Loader
consumes them per D1. Regenerate goldens once more. R3 is retired; the
oracle corpus closure is v2-only; the C typechecker epic can start.

## Decisions

<decision id="D1">Haskell consumes v2 preludes as CHECKED-IN
`prelude/*.sexp` dumps plus a freshness gate: a test (env-gated on
WOK_WOKPARSE, like the Sexp.Differential group) regenerates each dump with
wokparse and fails on drift. Rejected alternative: Loader shells out to
wokparse at load time — makes the Haskell toolchain depend on the C binary
at runtime and in CI environments that do not build grammar/c.</decision>

<decision id="D2">The golden contract MOVES twice (phase 1 and phase 3)
and only stabilizes when this epic lands. Consequence, stated plainly:
the C typechecker epic sequences strictly AFTER this one; starting it
against the current goldens would target a contract known to change.</decision>

<decision id="D3">The A5 thunk-runner shape (`c : () -> a with e`,
capability via the row) is NOT revived as a migration target. It was
rejected in the redesign bundle, and named-instance dot-dispatch
(`count.get`) needs the handle bound to a label, which the thunk shape
cannot provide.</decision>

<decision id="D4">Branch topology is an owner decision at spec review,
not solved here. The pieces live on three unmerged lineages:
`feat/sexp-ingestion-oracle` (sexp bridge + oracle, this branch, based on
docs/redesign-v2-surface), `proto/handler-values` (item-4 prototype, off
main), `feat/retrofit-once-return` (tools/ codemod). Item 4 must be
implemented on a lineage that eventually reaches the sexp bridge; the
merge order (and whether the grammar/c -> src/c rename happens before or
after) is decided by the owner per the review-before-merge rule.</decision>

## Open questions

<open id="O1">Do v1 prelude files survive phase 3 as twins (BNFC path
keeps working for the v1-first test corpus, dual maintenance risk), or are
they replaced (S5 partially forced: every v1 corpus test that loads a
prelude must go through the sexp path)? Leaning: keep v1 twins until S5,
with a drift test comparing the two environments' schemes.</open>

<open id="O2">Does phase 1 land the corpus migration as a parser-backed
codemod (tools/ exists only on feat/retrofit-once-return) or by hand
(~30 files)? The once/return retrofit precedent says codemod.</open>

<open id="O3">Item-4 C-ambient: if ambient resolution needs the D9/P2
designation-slot machinery, phase 0 grows substantially. Verify first,
before any other phase-0 work.</open>
