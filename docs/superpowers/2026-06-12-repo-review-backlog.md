# Repo-wide review backlog (2026-06-12)

Findings from the four-subsystem adversarial review run on `feat/slice-3-conc`
(post-fix, 786 green). Everything listed here is **pre-existing on `main`** — none
of it was introduced by the Conc branch. Each item was verified by the finder agent
with an actual repro (program + observed output) unless marked otherwise. Ordered
by severity within each section. Each is its own fix slice; none blocks the Conc
merge.

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
