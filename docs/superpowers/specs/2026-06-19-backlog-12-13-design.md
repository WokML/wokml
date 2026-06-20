# Design: backlog residuals #12 (APrim atom) and #13 (positioned generic-expression unifies)

- Date: 2026-06-19
- Branch: `fix/backlog-residuals-12-13`
- Status: design approved (brainstorm), pending spec review then plan
- Gate: full-branch `/code-review` before any merge to `main`
- Lands as: two independent commits (one per slice) on top of the existing
  `chore(test): remove dead coro-resume-obligation golden` commit.

## 1. Why these two, together

These are the last two open items from the 2026-06-12 repo-review backlog
(`docs/superpowers/2026-06-12-repo-review-backlog.md`, "DEFERRED FULL FIXES").
Both are *diagnostics* residuals — neither produces a wrong value or a crash on
valid input today — but #12 has a latent silent-wrong-value angle worth closing.
They touch independent subsystems (interpreter/`Atom` vs typechecker spans), so
they share one brainstorm/spec but land as separate commits.

### Loci re-verified against current code (the doc's line numbers had drifted)

- #12: `data Atom` is `src/Wok/IR/Anf.hs:48`; `resolveAtom` is
  `src/Wok/Interp/Value.hs:180`; the elaborator's name resolver `resolveVar` is
  `src/Wok/IR/Elaborate.hs:80`.
- #13: the positionless `unify` sites are `src/Wok/TypeChecking/Infer.hs` (see
  §3); the leaf-walking helper `expPos` **already exists** at `Infer.hs:2591`
  (the 2026-06-12 doc proposed building it from scratch — it doesn't need to be).
  `ETuple` performs **no** unify (tuples are heterogeneous), so it is a non-issue.

## 2. Slice 1 — #12: distinguish prim references from missing binders

### 2.1 Problem

`resolveAtom` resolves an `AVar n` by `nameUniq` in the runtime environment, then
**falls back** to the prim table by `nameHint` (text):

```haskell
resolveAtom prims sc (AVar n) =
  case Map.lookup (nameUniq n) (scEnv sc) of
    Just v  -> Right v
    Nothing -> case Map.lookup (nameHint n) prims of   -- the load-bearing fallback
      Just p  -> Right (VPrim p)
      Nothing -> Left (UnboundVar (nameHint n))
```

That fallback **is** how builtins resolve: `+`, `mod`, `div`, `++`, `eqU64`,
`__coro_resume`, … are not bound in the runtime env, only looked up by name. So
it cannot simply be removed. But it also means: if a binder goes **missing** due
to a compiler bug and its hint happens to collide with a prim name, it silently
resolves to the builtin (a wrong value) instead of erroring `UnboundVar`. Latent
today (needs another bug to trigger; the Jump arity check closed the one known
path), but it is the kind of latent fault that turns a small bug into a baffling
one.

### 2.2 Design (approved shape)

Mark prim references **structurally distinct** from ordinary binders at
elaboration, so the by-name fallback becomes unreachable for ordinary binders and
can be deleted.

1. **New atom form `APrim Text`.** `data Atom = AVar Name | ALit Lit | APrim Text`
   (`Anf.hs:48`). `APrim` is a *different kind of atom*, so a builtin reference
   and a variable reference can never be confused. (Per the repo's
   Strict+StrictData rule, the field is written `APrim Text` with **no** bang;
   StrictData makes it strict.)

2. **Route by prelude-`extern` identity, not by name string.** The set of
   builtins is data-driven from the prelude `extern` declarations
   (`prelude/Std/Base.wok`, `prelude/Std/Control.wok`) — never a hardcoded list
   in the elaborator. The elaborator carries the canonical `Name`s of the
   value-level prelude externs and, in `resolveVar`, emits `APrim (nameHint n)`
   when a resolved **global** `Name` is one of them, else `AVar n`. Routing keys
   on identity (`Name`/`Unique`); the `APrim` payload is the text key the prim
   table already uses. Identity where it matters (the decision), text where it is
   harmless (the lookup).

3. **`resolveAtom` split, fallback deleted.**

   ```haskell
   resolveAtom prims _  (APrim name) =
     case Map.lookup name prims of
       Just p  -> Right (VPrim p)
       Nothing -> Left (UnboundPrim name)     -- prelude<->runtime contract breach
   resolveAtom _     sc (AVar n) =
     case Map.lookup (nameUniq n) (scEnv sc) of
       Just v  -> Right v
       Nothing -> Left (UnboundVar (nameHint n))   -- NO prim fallback
   resolveAtom _     _  (ALit l) = Right (VLit l)
   ```

   A new `RuntimeError` constructor `UnboundPrim Text` (in `Value.hs`, with a
   renderer) signals "a builtin has no backing implementation" — an internal
   prelude↔runtime contract breach, distinct from a user-facing `UnboundVar`.

4. **`Prim.hs` is demoted to a checked implementation registry.** It stops being
   the authority on *what is a prim* (the prelude externs are) and remains only
   the Haskell *implementations* behind each extern — which genuinely cannot move
   into the language. The `APrim`→`UnboundPrim` hard error turns the
   extern↔implementation relationship into a checked contract: a declared extern
   with no implementation fails loudly the first time it is used, instead of
   today's silent guessing. (An *eager* "every prelude extern has an impl" check
   at load time is possible but out of scope — the lazy resolve-time check is
   sufficient and YAGNI.)

### 2.3 Forward-compatibility with future `(+)` overloading

This is already how `(==)` works in `Std.Base`: `class Eq`, `instance Eq U64
where (==) = eqU64`, `instance Eq U32 where (==) = eqU32`. A `==` use is resolved
by type to a dictionary whose field is one of those externs. When `Num`/`(+)`
overloading lands, `(+)` migrates from today's monomorphic `extern (+)` to a
class method backed by per-type externs (`addU32`, `addU64`, `addF32`, …) — each
of which is just another `APrim`. Routing-by-identity routes *whatever extern
dictionary resolution lands on*, so the design does not get in overloading's way.
The only thing to avoid is hardcoding "`+` is one prim spelled `+`" anywhere —
and identity-routing inherently doesn't. No extra work now.

### 2.4 Completeness obligation, and why it is compiler-enforced

"Route *every* builtin or builtins break" is the load-bearing risk. It is bounded
and GHC-checked:

- The only path that relies on the fallback is **value-level extern references**,
  all of which flow through the globals branch of `resolveVar`. **Constructors**
  (`Cons`, `Nil`, `True`, `Suspended`, …) take a separate `RCon` path and are
  **not** prim-table keys — removing the fallback cannot touch them. **Literals**
  are `ALit`. So the obligation reduces to "every value-level extern reference
  becomes `APrim`," handled at one choke point.
- Adding a constructor to `Atom` makes every exhaustive match on `Atom`
  incomplete, so GHC's pattern-completeness warnings **enumerate every consumer**
  that must learn about `APrim`. The implementer follows the compiler.

Consumers to update (the semantically-correct treatment of "a prim is a global
constant"):

- `src/Wok/IR/Anf.hs`: `atomVars (APrim _) = Set.empty` (no free variable — this
  one central function is reused wherever free variables are computed, e.g.
  `Escape`, so those are covered transitively); `collectAtom (APrim _) t = t`
  (not a binder, no hint); `renderAtom _ (APrim p) = p` (renders the prim name).
- `src/Wok/IR/Escape.hs`: the direct `AVar n -> … member tracked` sites
  (`389`, `420`) get `APrim _ -> False` (a prim is never a tracked/escaping
  local).
- `src/Wok/IR/Perceus.hs`: a prim atom is not refcounted — **no** dup/drop.
- `src/Wok/IR/Multiplicity.hs`: a prim atom is a constant — never a continuation
  binder; contributes nothing to cardinality.
- `src/Wok/IR/Match.hs`, `src/Wok/IR/Reachable.hs`: pass-through constant cases.
- `src/Wok/Interp/Machine.hs`, `src/Wok/Interp/RC/Machine.hs`,
  `src/Wok/Interp/RC/Value.hs`: resolve `APrim` via the prim table (mirror
  `resolveAtom`); no RC accounting for a prim.

### 2.5 The seam that surfaces extern identity to the elaborator

`resolveVar` needs the set of canonical extern `Name`s (call it
`ecPrims :: Set Name`, added to `ElabCtx`). The set is the value-level prelude
externs, mapped to their canonical `Name`s via the existing
`(definingModule, name) -> Name` identity already produced by
`elaborateModulesSharedWithGlobals` (and used by the multiplicity once-sink
machinery). The authoritative source of "this name is an extern" is the
typechecker (it already computes a per-module `externs` set and gates `extern`
prelude-only). Recommended plumbing (to be pinned in the plan): surface the
typechecker's extern set — mirroring the existing `extern data`/`extern type`
marker in `Env` — and have both elaboration entry points (`elaborateModule` and
`elaborateModulesSharedWithGlobals`) build `ecPrims` from it. Non-extern prelude
functions with bodies (`id`, `const`, `not`) are **not** in `ecPrims`; they
remain `AVar` bound in the runtime env, exactly as today.

### 2.6 Behavioral change (the point of the slice)

A missing binder whose hint collides with a prim used to silently resolve to the
builtin (wrong value, no error); it now errors `UnboundVar`. Every *correct*
program is unchanged. This is the one intentional behavioral change in either
slice: a latent silent-wrong-value becomes an honest failure.

### 2.7 Refinement (post-brainstorm, pressure-tested): `(Module, Name)` single identity

§2.2 chose `APrim Text` and left the once-sink trust mechanism alone. Brainstorming
then surfaced that the codebase already carries **two** ways to recognize the genuine
prelude continuation sinks: Multiplicity trusts `__coro_susp` by canonical **`Unique`**
(`isCoroSusp f = Set.member (nameUniq f) onceSinks`), while Escape/Reachable recognize
`__cont_store` by **hint text** (the "TRUST ANCHOR / code-review #6" comment in
`Escape.hs`). `Unique` is a compilation-internal disambiguation tag, not a semantic
identity; the honest identity of a top-level definition is `(Module, Name)`. So we
unify both onto one layer.

**Decision (supersedes §2.2 payload):** `APrim` carries the qualified identity
`(Module, Name)` — i.e. `APrim (Text, Text)`, the same key shape `globalByKey`/
`onceSinkKeys` already use.

- **Elaborator.** `ecPrims :: Map Name (Text, Text)` (each value-level prelude
  extern's canonical `Name` → its `(definingModule, name)` key, built from the extern
  `TypedDecl`s through `globalByKey`). `resolveVar` does one lookup on a resolved
  global: `Just qkey -> APrim qkey`, else `AVar n`. Locals are never routed.
- **One recognizer predicate.** A static `onceSinkNames :: Set (Text, Text)` =
  `{(Std.Control,"__coro_susp"), (Std.Control,"__cont_store")}` (co-located with the
  other prim-name constants in `PrimNames.hs`). Multiplicity matches
  `RApp (APrim qkey) … | Set.member qkey onceSinkNames`; Escape/Reachable's
  `__cont_store` move-in matches `APrim (Std.Control,"__cont_store")`.
- **Retire the `Unique` layer.** `resolveTrusted`, `onceSinkKeys`-as-`Unique`, and the
  `Set Unique` returned by `elaborateProgramFullTrusted` are removed;
  `elaborateProgramFullTrusted` collapses to plain `elaborateProgramFull`
  (`CoreModule`). The two consumers that took the `Set Unique` —
  `elaborateCheckedFull` and the `--dump-multiplicity` CLI in `app/Main.hs` — pass the
  static `onceSinkNames` instead. `Unique` returns to binder-freshness only.
- **`analyzeModule`/`computeTrustMap`** keep a parameter, but of type
  `Set (Text, Text)` (defaulting to `onceSinkNames` in production), so the **M3-a
  red-check stays injectable**: it passes `onceSinkNames ∖ {(Std.Control,"__cont_store")}`
  and witnesses `park` flipping `1 → ω`.

**Why sound (pressure-tested by reading the code):**
- `resolveVar` (via `elabRhsF (TVar t)`) is the single choke point for every builtin
  reference — direct uses, operators, evidence/dict lowering, AND instance-method
  bodies (`instance Eq U64 where (==) = eqU64` desugars to a synthetic decl whose body
  `eqU64` is a `TVar` → `resolveVar` → `APrim`). Class-method *use* sites project a
  synthetic dict-field binder (`AVar`, env-resolved) — correctly NOT a builtin.
- `APrim` is unforgeable: emitted only for genuine prelude externs (users can't declare
  `extern` — the Part-1 gate). A forged user `__coro_susp` resolves to `AVar` and stays
  untrusted — same forgery-resistance as the `Unique` check, now structural, and
  `(Module, Name)` additionally disambiguates same-named externs across modules.

**Caveat A — "one layer" is for surface externs/sinks, not every `__`-name.**
`__rc_dup`/`__rc_drop` are **Perceus-synthesized post-elaboration**, not prelude
externs, so they never become `APrim` and stay recognized by hint-on-`AVar`. That is a
*different category* (compiler-internal RC ops, where the compiler controls the name so
hint is reliable) and is left untouched. End state: `(Module, Name)`/`APrim` for
trusted-sink identity; hint-on-`AVar` for compiler-synthesized RC bookkeeping.

**Caveat A′ (Task 2 implementation finding) — ALL surface continuation externs
move, not only the two named sinks.** Routing *every* value-level prelude `extern`
to `APrim` (the §2.4 completeness obligation, required for Task 3 to delete the
by-hint fallback) necessarily affects EVERY genuine `Std.Control` continuation
extern — not just `__coro_susp`/`__cont_store`. `__cont_cell_new` (Escape's
`freshCellBinder` fresh-cell recognizer) and `__cont_take` (Perceus's
`isContTakeRhs` + the three `moveOperandUniques`/`ownedOccs`/lint borrow exemptions)
were *also* hint-on-`AVar` and were silently broken by routing; they are migrated to
`APrim (module, name)` identity in lock-step with `__cont_store`. The line stays
exactly where Caveat A drew it: every genuine surface continuation extern →
`APrim`-identity recognition; only Perceus-synthesized `__rc_dup`/`__rc_drop` stay
hint-on-`AVar`. (The plan's Step 4 enumerated only the two trusted sinks; this is the
complete recognizer set the design's §2.4 obligation entails.)

**Caveat B — runtime implementation lookup stays name-keyed.** `APrim` carries
`(Module, Name)` for *identity*, but `Prim.hs`'s implementations have no module, so both
interpreters look the impl up by the *name* part. Harmless today (Base/Control share no
extern names); re-keying the prim table by `(Module, Name)` is deferred (churn for no
behavioral gain).

**Deferred — interning.** Interning `(Module, Name)` to an integer id is NOT done: the
only per-operation comparison is the interpreter's prim-table lookup, and the
interpreter is not the performance target (the compiled backend lowers `APrim` to a
native op by matching `(Module, Name)` at compile time, with no runtime lookup). A
static enum would be fastest but would re-hardcode the prim list (against the
data-driven principle). If a future profile shows it matters, the design-preserving move
is a post-elaboration pass assigning each `APrim` a prelude-derived table index.

## 3. Slice 2 — #13: position generic-expression / case / pattern unifies

### 3.1 Problem

A type mismatch at several spots surfaces as `Mismatch Nothing …` — no source
location — because the BNFC `Exp`/`Pat` AST carries no per-node position;
positions live only on leaf tokens (`VarId`, `ConId`, `WokInt`). `EApp` and the
infix path already recover a position via `expPos`/`infixOpPos`; the remaining
generic sites still pass `Nothing`.

### 3.2 Design (full "B": expressions + case + patterns)

Two best-effort leaf-walking helpers; at each mismatch site, pass a recovered
position instead of `Nothing`.

- **Extend `expPos :: Abs.Exp -> Abs.BNFC'Position`** (`Infer.hs:2591`) to recurse
  into more shapes: `ECon` (its `ConId` token), `EIf c _ _ -> expPos c`,
  `EList (x:_) -> expPos x`, `ETuple a _ -> expPos a`. (Already handles `EVar`,
  `EApp`, `EProj`, `EProjC`, `ELitI`, `EParen`.)
- **Add `patPos :: Abs.Pat -> Abs.BNFC'Position`** (mirror), walking to the
  leftmost leaf: `APVar`→`VarId` pos, `APCon`/`PApp`→`modPathPos`,
  `PRecord*`→`ConId` pos, `APLitI`→`WokInt` pos, `PCons h _`→`patPos h`,
  `APTuple p _`→`patPos p`, `APList (p:_)`→`patPos p`, `APParen`/`APAs`→recurse.

**Best-effort rule (honest limitation).** `ELitS String`, `ELitC Char`, `EUnit`,
and pattern `APLitS`/`APLitC`/`APWild`/`PUnit` carry **no** position token in the
AST, so the helpers return `Nothing` for a bare string/char/wildcard. To maximize
useful locations, multi-operand sites point at the offending operand but fall
back to a sibling via `Maybe`'s `<|>`, and ultimately to `Nothing` (today's
behavior). So the result is strictly an improvement or a no-op, never a
regression, and it never points at the *wrong* place — at worst it points coarser
(at the start of the enclosing construct) or omits the location.

### 3.3 The seven sites (with chosen anchor)

Expression side (`expPos`):

1. `Infer.hs:1711` `if` condition not `Bool` → `expPos c`.
2. `Infer.hs:1712` `if` branches disagree → `expPos b <|> expPos a <|> expPos c`
   (prefer the else branch).
3. `Infer.hs:1726` list-literal element disagrees with first →
   `expPos e <|> expPos x` (prefer the offending element).
4. `Infer.hs:2616` `case` arm body disagrees with result →
   `expPos body <|> patPos pat`.

Pattern side (`patPos`):

5. `Infer.hs:2608` `case` arm pattern cannot match scrutinee → `patPos pat`.
6. `Infer.hs:1243` cons-pattern tail is not a list → `patPos tailPat`.
7. `Infer.hs:1289` list-pattern element disagrees with first → `patPos p`
   (requires restructuring the `mapM_` to keep each element pattern in scope:
   `mapM_ (\(p, t) -> unify (patPos p) firstT t) (zip ps restTs)`).

### 3.4 No behavioral change

The position argument is consulted **only** when a unify *fails*, to attach a
`line:col` to the error. On success it is ignored. Same programs accepted, same
rejected — only the wording of rejections changes.

## 4. Testing plan

### 4.1 #12 (correctness-adjacent — touches the `Atom` type + interpreter)

- **Core (new behavior):** a unit test that a **missing binder** whose hint
  collides with a prim name now resolves to `Left (UnboundVar …)` rather than
  silently returning the builtin's value. Construct an ANF expression with an
  `AVar` whose `Unique` is absent from the env and whose `nameHint` is a prim key
  (e.g. `"+"`); assert `UnboundVar`.
- **No-regression (every builtin still resolves):** the full suite stays green —
  every program using `+`, `mod`, `++`, `eqU64`, the `Eq` instances, the
  `__coro_*`/`__cont_*` family, etc. still runs. The `run-golden` outputs are
  unchanged (same runtime results).
- **Red-check:** revert just the fallback removal (restore the `AVar`→prim
  branch) ⇒ the missing-binder test flips back to silently returning the prim's
  value. This proves the test bites.
- **Possible golden churn:** goldens that *dump the IR/atom rendering*
  (`anf-golden`, `typed-anf-golden`, and any `rc`/`perceus` dump that renders
  atoms) *may* shift for programs that reference builtins, if the `APrim`
  rendering differs from the previous `AVar`-hint rendering. Mechanical; each
  regenerated golden is eyeballed to confirm the rendering is the prim name.

### 4.2 #13 (diagnostics-only)

- **Positive goldens** (`typecheck-fail-golden`) for the seven cases, asserting
  the message now carries a `line:col`: `if`-condition, `if`-branches,
  list-literal element, `case`-arm bodies, `case` pattern-vs-scrutinee,
  cons-pattern tail, list-pattern element.
- **Documented no-position case:** one golden where the offending term is a bare
  string literal, showing the helper falls back (coarser anchor or no location) —
  pinning the honest limitation so it is not mistaken for a regression later.
- **Expected golden churn:** a handful of *existing* error goldens gain a
  `line:col` they lacked, because extending `expPos` also sharpens its existing
  `EApp` caller. Strictly better; reviewed in the same pass.

### 4.3 Test discipline

No temporary fixes or loopholes; goldens are regenerated via the normal accept
path and each diff is reviewed for sensibility (right location, right wording),
coherent with the spec's goal, before the slice is considered done.

## 5. Rejected alternatives

- **#12 flag on `Name` instead of `APrim`.** `Name`'s `Eq`/`Ord` are by `Unique`
  only, so a flag would not participate in identity and could drift; it also keeps
  one `AVar` path that forks internally — the same "one path, two meanings" shape
  that let the bug hide. `APrim` makes the distinction structural.
- **#12 route by prim-name-string membership.** Reintroduces the very
  hint-collision fragility we are removing, and contradicts the established
  "trust the marker, not the name string" principle. Rejected in favor of
  extern-identity routing.
- **#12 key the runtime prim table by `Unique`.** More invasive (re-key the
  table, thread `Unique`s to the runtime) for zero safety gain — identity-routing
  already prevents the collision, so the payload can stay text. Rejected (YAGNI).
- **#13 option 1 (regenerate parser with a position functor on `Exp`).** Correct
  and complete, but a repo-wide change touching `src-generated` and every
  `inferExprW` arm — wildly disproportionate to positioning seven `unify` calls,
  especially since the leaf-walk helper already exists.
- **#13 scope "A" (expressions only) or "A + case-arms".** A leaves the *most
  common* instance of the same bug (`case` arms returning different types) without
  a location — an arbitrary line. Building `patPos` for the high-value
  pattern-vs-scrutinee site makes the list/cons-pattern sites nearly free, so full
  B is the coherent stopping point. Chosen: full B.

## 6. Out of scope / deferred

- Eager "every prelude extern has a backing implementation" check at load time
  (the lazy `APrim`→`UnboundPrim` check suffices).
- Positions for record-pattern and constructor-argument mismatches (already
  positioned via the constructor token) and for handler/`with` and declaration
  unifies (separate constructs with their own error stories).
