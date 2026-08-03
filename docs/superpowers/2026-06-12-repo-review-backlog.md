# Repo-wide review backlog (2026-06-12)

Findings from the four-subsystem adversarial review run on `feat/slice-3-conc`
(post-fix, 786 green). Everything listed here is **pre-existing on `main`** — none
of it was introduced by the Conc branch. Each item was verified by the finder agent
with an actual repro (program + observed output) unless marked otherwise. Ordered
by severity within each section. Each is its own fix slice; none blocks the Conc
merge.

## RESOLUTION (branch `fix/repo-review-backlog`, 801 green)

All 14 findings are now fixed on `fix/repo-review-backlog`. A three-reviewer
full-branch adversarial pass confirmed #1,#2,#3,#5,#6,#7,#8,#12,#14 sound and
caught two defects in the first cut (#11's CafFailure catch never fired due to a
strictness hoist; #4's panic survived on the multi-line layout) — both repaired
and locked with run-the-exploit fixtures. Commit map:
- `e223398` batches 1-5: #1 (scope-leak join), #2 (functionCapturesHandle),
  #3 (row shared-tail guard), #4 (rigidUnify level guard — signed case),
  #6 (LetRec ordering), #8 (buildOracle env-first), #9 (handler `;` layout),
  #10 (transitive fixities + diamond-merge), #11 (first cut), #12 (Jump arity),
  #14 (producer-thunk origin gate).
- `941cdfe` #5 dangling CTGen (intern generalizable row vars; cross-module fixture).
- `fad9709` #7 body-case via Match (duplicate-head trigger; byte-identical flat path else).
- `767bd80` #13 carrier/future + infix-operand positions (EIf/list generic-expr
  positions DEFERRED — needs a BNFC `Exp` position functor).
- `d96982e` review fixes: #11 (thunk + deep-force, now actually catches),
  #4 (EscapedTyVar backstop for the unsigned-enclosing layout).

Notes on residual scope, all documented in-commit:
- #9: the newline-as-separator works per ARM; a single arm whose BODY spans lines
  still needs explicit grouping (same constraint records have).
- #10: same-name + same-fixity + same-(line,col) in two modules merges silently
  (legitimate diamond; harmful redeclarations differ in OpInfo or are caught by
  the value-namespace overlayEnvs).
- #12: resolveAtom's prim-name fallback is load-bearing (builtin resolution); the
  Jump arity check fixes the concrete missed-binder repro at its source.
- #13: infix-operand and carrier/future decl errors are now positioned; generic
  EIf/condition/list-element unifies still pass `Nothing` (Exp AST has no
  per-node position — only embedded tokens do).

## DEFERRED FULL FIXES (the residuals above, proper form)

These are the COMPLETE fixes for the two diagnostics residuals (#12, #13), kept
out of this branch because each is a cross-cutting structural change
disproportionate to a diagnostics-only payoff (neither produces a wrong value or
a crash on valid input). Recorded here so a future slice can pick them up.

### #12 — distinguish prim references from missing binders

Problem. `resolveAtom` (`src/Wok/Interp/Value.hs:160`) resolves an `AVar n` by
unique id in the env, then FALLS BACK to the prim table by `nameHint`. That
fallback IS how builtins (`+`, `mod`, `div`, …) resolve — they are not bound in
the env, only looked up by name. So it cannot be removed. But it also means a
binder that goes MISSING due to a compiler bug, whose hint collides with a prim
name, silently resolves to the builtin (wrong value) instead of erroring
`UnboundVar`. The Jump arity check (Machine.hs) closed the one known path to a
missing binder; the masking itself is latent (needs another bug to bite).

Full fix. Mark prim references distinctly at elaboration so the by-name fallback
is unreachable for ordinary binders:
  1. Add an atom form for builtins, e.g. `APrim Text` to `data Atom`
     (`src/Wok/IR/Anf.hs:39`), OR a sentinel/global flag on the `Name`.
  2. In the elaborator, emit `APrim name` (not `AVar`) for a resolved builtin —
     `resolveVar`/the globals path in `src/Wok/IR/Elaborate.hs` is where a name
     resolves to a builtin; route builtins to the new form there.
  3. In `resolveAtom`: `APrim name -> Map.lookup name prims` (hard error if
     absent); `AVar n -> Map.lookup (nameUniq n) env` and on a miss return
     `Left (UnboundVar …)` with NO prim fallback.
  4. Update the other `Atom` consumers in `Anf.hs` (collectAtom ~112,
     renderAtom ~190) and any pattern matches on `Atom`.
Cost: small but cross-cutting (Atom type + elaborator + machine + a couple of
walkers). Effect: a missing binder is always a loud `UnboundVar`, never a
silently-substituted builtin.

### #13 — position EIf / list / tuple (and any generic-expression) unifies

Problem. A mismatch at an `if`/list/tuple surfaces as `Mismatch Nothing …`
(`src/Wok/TypeChecking/Infer.hs`: EIf ~1711-1712, list ~1726, and similar). Root
cause is structural: the BNFC `Exp` AST carries NO per-node position
(`data Exp = … | EIf Exp Exp Exp | …` in `src-generated/GeneratedParser/Wok/Abs.hs`);
positions live only on leaf TOKENS (VarId / WokInt / operator symbols). That is
why the infix-operand and decl-name cases COULD be fixed (a token to hang the
span on) and these cannot.

Full fix (option 1, complete). Regenerate the parser with a POSITION FUNCTOR on
`Exp` (BNFC `--functor`, or the project's regen path), so every `Exp` node carries
`BNFC'Position`. Then thread that position into the `unify` calls in
`inferExprW` (EIf condition/branches, EList/ETuple element unifies, EApp, …).
Correct and complete, but touches the generated parser, the `Exp` type, and every
`inferExprW` arm — a large, mechanical, repo-wide change.

Full fix (option 2, cheap heuristic — RECOMMENDED first step). Add
`exprPos :: Abs.Exp -> SourceSpan` that walks to the LEFTMOST leaf token of a
subexpression (`EVar`→its VarId pos, `ELitI`→its pos, `EApp f _`→`exprPos f`,
`EIf c _ _`→`exprPos c`, `EList (x:_)`→`exprPos x`, …) and use it at the
positionless `unify` sites. Imprecise (points at the start of the offending
branch, not the exact clash) but strictly better than `Nothing`; ~30 lines, NO
parser regen. Mirrors how `infixOpPos` already recovers the operator token's
position for the infix case.

---

## Original findings (as filed)

## A. Soundness / wrong-values (highest priority)

1. **Elaboration scope leak — silent wrong values.** `src/Wok/IR/Elaborate.hs:124`
   (and `elabRhsF` TLet ~464): a `let ... in` in value position wraps the ENTIRE
   continuation in `withLocals`, so let-bound names shadow outer/global names in
   sibling arguments textually outside the let. Repro: with top-level `x = 10`,
   `second a b = b`, `main = second (let x = 1 in x) x` evaluates to **1** (should
   be 10). Typechecking resolves correctly; only elaboration mis-scopes — silent
   miscompilation.

2. **Carrier escape via equation-form local function.** `src/Wok/TypeChecking/Carrier.hs:386`:
   `bindDecls` marks a let binding as a carrier only on direct-escape RHS forms or
   carrier result type. An equation-form helper `let helper x = c.set x in helper`
   (params on the LHS, body not a TLam) is never added to `envCarriers`, so a
   closure over a second-class handle escapes its `with` scope. Repro accepted:
   `leak u = with c = state 0 in let helper x = c.set x in helper` (exit 0); the
   semantically identical lambda form is correctly rejected. Pre-existing soundness
   hole in the handle discipline.

3. **Row unification hang.** `src/Wok/TypeChecking/Unify.hs:204`: no shared-tail
   (same row variable) check; unifying `{A|e0} ~ {B|e0}` rewrites the common tail
   with a fresh tail and recurses forever. Repro: a two-arg function whose params
   share `eff e`, called with the same argument twice whose rows force distinct
   heads — compiler spins (killed at 8s). Should be RowMismatch/RowOccursCheck.

4. **rigidUnify panic (no level/kind check).** `src/Wok/TypeChecking/Unify.hs:278`:
   any Unbound metavar is pinned to a Rigid skolem with no scope-escape or kind
   check. Repro: `outer u = let helper : a -> a; helper y = if True then y else u
   in helper 1` → compiler panic `finalizeGroupTyped: unexpected escape` instead of
   a positioned type error. Also allows KStar-metavar := KEffect-skolem.

5. **Dangling CTGen on row-parameterised data across modules.**
   `src/Wok/TypeChecking/Infer.hs:181`: `freezeQuantifyG` freezes generalizable
   KEffect vars as `CTGen <raw global uniq>` without interning/recording in the
   quantifier list. Cross-module use panics `instantiate: dangling CTGen 3`
   (repro'd); worse, the raw uniq can collide with a KStar quantifier index →
   silent kind confusion.

## B. Miscompilation / crashes on reasonable programs

6. **Local group LetRec ordering.** `src/Wok/IR/Elaborate.hs:613`: local FUNCTION
   bindings are emitted in a LetRec BEFORE sibling local VALUE bindings, so a local
   function referencing a sibling value crashes `UnboundVar` at runtime. Repro:
   `main = let a = 5; f y = y + a in f 1` → `UnboundVar "a"`.

7. **Body-position `case` lacks clause backtracking.** `src/Wok/IR/Elaborate.hs:660`:
   body cases still use the old one-alt-per-clause path (not `Wok.IR.Match`);
   overlapping heads with literal/nested sub-patterns mis-dispatch. Repro:
   `case m of Some 1 -> 100; Some n -> n; None -> 0` on `Some 2` →
   `NonExhaustiveCase` (top-level multi-clause form works). KNOWN limitation
   (memory: multi-clause-not-implemented), now with a concrete crash repro.

8. **buildOracle hijacks user constructors named Cons/Nil/TupleN.**
   `src/Wok/IR/Elaborate.hs:807`: built-in structural tags are answered before the
   env, so `data Tri2 = Cons U64 U64 U64 | Empty2` gets list arity/siblings →
   wrong decision tree → runtime `NonExhaustiveCase`. Repro'd.

9. **Multi-line effect-handler blocks cannot be written.**
   `src/Wok/RecordLayout.hs:92`: any `{` after a ConId is classified as a record
   brace; handler blocks get virtual commas at newlines and fail to parse. This is
   why every prelude handler is one line. Repro'd.

10. **Operator fixities don't flow transitively.** `src/Wok/Pipeline.hs:63`:
    imported envs are transitive but `importedFixs` are direct-imports-only.
    A module importing only Std.Control can call Std.Base functions but
    `1 + 2` fails `UndeclaredOperator "+"`. Repro'd.

## C. Diagnostics / robustness (lower priority)

11. **CAF runtime errors crash as internal panic.** `src/Wok/Interp/Machine.hs:281`:
    `forceTop` converts any Left from a user 0-arity binding (e.g. `bad = div 1 0`)
    into `error "runModule: CAF evaluation failed"` — a user error mislabeled as a
    compiler invariant violation.

12. **resolveAtom prim-name fallback masks UnboundVar.** `src/Wok/Interp/Value.hs:148`
    + silent `bindBinders` zip truncation + no Jump arity check (`Machine.hs:66`):
    an IR bug whose missed binder's hint collides with a prim name (`mod`, `+`, …)
    silently resolves to the builtin instead of erroring.

13. **Span losses.** `src/Wok/TypeChecking/Infer.hs:3312/3325` pass hardcoded
    `Nothing` spans to checkCarriers/checkFutureAffine (positionless
    CarrierEscape/FutureConsumedTwice); infix-op/EIf/list unifies (~1728, 1681,
    1696) drop available positions — `1 + "a"` reports `Mismatch Nothing ...`.

14. **Producer-thunk exemption not origin-gated** (`Carrier.hs:157` vs the
    Embedded-only clause-tail exemption, Infer.hs:3270). Verified inconsistency,
    NOT unsound (only fresh-carrier factories pass; capturing/non-flat variants
    still rejected). Fix = add the origin gate for consistency; fixture exists for
    the capturing path (`conc-producer-capture.wok`), add one for the non-capturing
    user-file form when gating.

## D. Conc-branch limitations already documented (spec §11) — not bugs to fix here

- Residual non-Conc effects (children AND the root's own tail) trap at runtime.
- Payload restriction: static check is best-effort (con-field/record-con/
  inference-only bypasses); the runtime transport guard is the backstop for
  continuations specifically.
- Nested `runConc` id-space collision (handles carry no scheduler identity).
- `raceAny []` deadlocks at runtime (`conc: deadlock`).
- `__coerce`/`erase`/`recall` user-reachable pending module privacy.
- Scheduler maps never shrink (cells/chans retained for the run's lifetime);
  spawn fiber ids are write-only until a fiber table exists.

## 2026-08-04 addition (probed during the v2 local-mutability design round)

- **#15 — self-referential local VALUE let dies at RUNTIME as `UnboundVar`
  instead of a compile-time error.** `let x = 1 in let x = x + 1 in x` →
  `runtime error: UnboundVar "x"`. Local let groups are recursive, so the
  RHS `x` resolves to the binder being defined; for a non-function value
  the self-reference survives typechecking AND elaboration and only dies
  in the machine (elaboration-scope family, cf. #1). Identical hole
  through a handler baton: `with Acc { var t = 0 ; add x k ->
  let t = t + x in k t () ; v -> (v, t) }` → `UnboundVar "t"`. Fresh-name
  lets and plain shadowing (`let x = 1 in let x = 2 in x` → 2) are fine;
  only the self-referencing rebind is a hole. Fix direction: reject value
  self-reference at resolution time with an eta hint ("recursive binding?
  write `let f x = ...`") — the v2 spec pins the full rule as D26
  (non-recursive value bindings); v1 wants the positioned diagnostic
  regardless of the fork.
