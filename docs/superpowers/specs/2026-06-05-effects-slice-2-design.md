# Effect handlers — slice 2: effect header, forgotten-resume lint, `Never`

Date: 2026-06-05
Status: Design converged (brainstorm 2026-06-05). Ready for slice planning.
Roadmap: `docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md` (slice 2).
Surface spec: `docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md` (§4.3, §8, §1).
Slice-1 plan (template): `docs/superpowers/plans/2026-06-05-effects-slice-1-with-resume.md`.
Memories: `effect-surface-syntax-final`, `effect-compilation-strategy`, `higher-ir-direction`.

## 1. Scope

Slice 2 delivers the ergonomics-and-safety layer on top of the slice-1 `with`-prefix
handler:

- **(A) Optional effect header** (§4.3): `with E1 E2 { … }` names the handled effects so
  arms can drop the `Effect.` qualifier. Unqualified ops resolve against the header;
  ambiguity is an error; the header is a strict coverage contract.
- **(B) Forgotten-resume lint** (§8): warn when an operation arm binds a *named* continuation
  that is never referenced in the body, on a *returning* operation. Binding the continuation
  to `_` (the wildcard) suppresses an intentional abort.
- **(C) Supporting pieces:**
  - **`Never`** — a new uninhabited type that marks an operation as *non-returning*; this
    is what the lint keys on (resolves roadmap follow-up #4).
  - **`MalformedHandlerArm`** — a dedicated error for too-many-patterns / non-variable
    continuation binders, replacing today's misleading `UnknownOperation`
    (roadmap follow-up #2).

Branch `feat/effects-slice-2-header-lint` off `main`. Full-branch review before any merge
(standing rule). TDD throughout; regenerate goldens reading every diff.

Out of scope (deferred — see §7): abort-policy config, a `Sys`/`Exit` runtime effect,
bounded `(with H ; e)` (slice 3), parameterized handlers and the concurrency runtime
(slice 4), one-shot multiplicity / value restriction (slice X).

## 2. `Never`: non-returning as a type, not a param

### 2.1 The problem (roadmap follow-up #4)

The surface spec's original definition of a *non-returning* operation was Koka-style: an
operation whose result is a type variable bound by the *operation* and occurring only in
result position (`throw : String -> a`, where each *call* may pick a different `a`, so the
result is bottom and the op can never actually return).

wok rejects a free operation-level result variable: every type variable an operation
mentions must be an **effect parameter** declared on the header. The working form was
therefore `effect Exn a = { throw : String -> a }`. But an effect parameter is fixed
*once per handler instance*, not per call — so the per-call universal polymorphism that
made `throw` bottom cannot be expressed. Worse, this collapses two semantically different
operations into the *same* type structure:

```
effect Exn    a = { throw : String -> a }   -- abort: never resumes
effect Reader r = { ask   : r }             -- returns a pure value; handler resumes
```

Both have a result that is an output-only effect param. The type system cannot tell them
apart, so no analysis over `eiParams`/`eiOps` can soundly classify "non-returning." (An
earlier candidate — "result is an effect param that never appears in argument position
across the effect" — produces a false positive on `Reader.ask`.)

### 2.2 The resolution

Stop encoding non-returning as a *parameter* and encode it as an **uninhabited type**:

```
effect Exn = { throw : String -> Never }    -- no phantom param needed
```

`Never` has no constructors, so it has no values. Consequences, all desirable:

- A handler arm for `throw` receives `k : Never -> R`, which can never be called — the
  type *proves* the operation cannot resume.
- An auto-resume (binder-less) arm `Exn.throw msg -> <body>` would require `<body> : Never`,
  which is unconstructable — so an abort op *must* bind the continuation and abort, enforced
  by the type checker.
- `Exn` loses its phantom parameter; the declaration is simpler than the param workaround.

This is the same split as Rust's bare `!` (the type is uninhabited; what to *do* on
divergence — unwind, abort, exit 0 — is a separate runtime/handler concern, never a field
of the type; see §7).

### 2.2.1 Bottom elimination at the perform site (load-bearing)

`Never` is wok's **bottom type**, and a bottom type is only useful if a value of it can be
consumed at *any* type. Consider:

```
risky : Bool -> U64 with Exn
risky b = if b then Exn.throw "boom" else 7    -- then: Never, else: U64
```

wok is HM with **no subtyping**, so a concrete `Never` will not unify with `U64`, and this
would wrongly fail to type-check. The HM-compatible fix is to recover the original
`throw : ∀a. String -> a` behaviour at the *use* site:

> When typing a reference to a **non-returning operation** (an operation whose declared
> result type is `Never`), instantiate its result as a **fresh type variable** rather than
> the literal `Never`. Each perform of `Exn.throw …` therefore yields a fresh result type
> that unifies with whatever the context demands (`U64` above).

This is ex-falso / bottom-elimination, localized to the effect-operation reference path
(`Infer.hs` `EProj` effect-op case, ~1516–1534): after computing the op's type, if its
ultimate result is `Never`, rebuild it with a fresh result variable. The *handler* side is
unchanged — an arm's `k : Never -> R` is correctly uncallable, since resumption never
happens. (A general `absurd : Never -> a` for `Never` values in arbitrary position is not
needed by these cases and is deferred; perform-site freshening covers exceptions.)

### 2.3 The lint discriminator

> An operation is **non-returning** iff its declared result type, after peeling its leading
> arrows, is `Never`.

A one-line, sound, declaration-level check. `Reader.ask : r` is correctly *not* exempt
(its result is `r`, not `Never`); `print : String -> ()` is correctly *returning* (result
`()`).

### 2.4 Representation

`Never` is an uninhabited type. **Resolved representation: a built-in tycon `TcNever`**,
mirrored on every site that handles `TcString` (the `TyCon` enum in
`Wok.TypeChecking.Types`, `tyConKey` + the name→tycon resolver in `Class.hs`, `resolveTyCon`
+ `prettyCType` in `Infer.hs`, `prettyCTypeLocal` in `Anf.hs`, and the `Builtins.hs`
tycon registry). It is uninhabited because no constructor or literal ever produces it.

Rationale for built-in over a prelude `data Never`: every primitive in wok (`U64`, `String`,
`Char`, `Bool`, `Unit`, `List`) is a built-in tycon, not a prelude `data` decl; and the
grammar requires `data ConId = [ConDef]`, so a constructor-less type would need the awkward
`data Never =` (trailing `=`, empty list) and depends on `processDataDecls` accepting zero
constructors. The built-in avoids both. The discriminator checks "the result type's head
constructor is `TcNever`."

## 3. Effect header (§4.3)

### 3.1 Surface

```
with State { get   -> 0           -- unqualified: header names State
             set s -> () }
prog ()
```

A `with` may carry an optional, space-separated list of effect names (one or more `ConId`)
between `with` and the `{`. The header is sugar: headerless dot-qualified arms remain valid
and are the form to use for multi-effect blocks with name collisions.

### 3.2 Resolution rules

> Within `with E1 E2 … { … }`:
> - An **unqualified** operation name resolves to the *unique* listed effect that declares
>   it. **Zero** matches → error (the op is not declared by any header effect). **Two or
>   more** matches → ambiguity error (re-qualify to fix).
> - **Qualified** arms (`E.op …`) are still allowed inside a headed block, but qualifying an
>   effect **not** in the header is an error. The header is a strict "exactly these effects"
>   coverage contract: the handled set *is* the header, and every operation of every header
>   effect must have an arm (the existing `HandlerCoverage` check, run against the header
>   set rather than the union of arm heads).

A headerless block behaves exactly as in slice 1: the handled set is the union of the arms'
(qualified) effect names.

Conflict resolution is qualification. If two header effects declare the same op name, a bare
arm is ambiguous and you disambiguate by writing the qualified form — qualification is
*optional sugar the header removes*, not forbidden inside a headed block:

```
effect Reader = { ask : U64 }
effect Config = { ask : U64 }     -- both declare `ask`

with Reader Config {
  Reader.ask -> 41                -- qualified: resolves the `ask` collision
  Config.ask -> 0                 -- qualified: the other `ask`
}
prog ()
```

Every arm resolves internally to a fully-qualified `(effect, op)` pair regardless of how it
was written; the header only lets you *omit* the qualifier where it is unambiguous. A block
with so many collisions that qualifying each is noisier than helpful should just drop the
header (the headerless form is always valid).

**Empty handler is an error.** A `with { }` (or `with E { }`) with zero arms handles nothing
and is almost certainly a mistake; reject it ("a handler must have at least one arm"),
consistent with the existing rule that a `with` which is the last element of a block is an
error.

### 3.3 The value-arm / unqualified-nullary-op ambiguity

A bare nullary arm `get -> 0` is syntactically identical to a value arm `v -> 0` (both are
`VarId "->" Exp`). Disambiguation is **semantic**, resolved in the type checker, not the
grammar:

> In a headed block, a leading bare name that matches an operation of a header effect is an
> **operation arm**; otherwise it is the **value arm**.

Consequence (accepted, documented): to write a value arm in a headed block, choose a binder
name that is not an operation of any header effect. In a headerless block, a bare
`name -> …` is always the value arm (slice-1 behaviour), since there is no header to resolve
an unqualified op against.

### 3.4 Grammar

Today (slice 1):

```
EWith.  Exp2       ::= "with" "{" [HandlerArm] "}" Exp ;
HArm.   HandlerArm ::= ConId "." VarId [AtomPat] "->" Exp ;
HVArm.  HandlerArm ::= VarId "->" Exp ;
separator HandlerArm ";" ;
```

Slice 2 adds the header and an unqualified operation-arm form. Two grammar facts constrain
the shape:

1. The header is a non-empty run of `ConId` with no separator (`with State IO {`). BNFC
   needs an explicit non-empty list rule for this (a `terminator`/`separator ""` run, or a
   dedicated `EffHeader` production); the plan picks the form that regenerates without new
   conflicts.
2. `HVArm` (`VarId "->" Exp`) and an unqualified op-with-args form (`VarId [AtomPat] "->" Exp`)
   collide at zero atoms. Resolve by having **one** production `VarId [AtomPat] "->" Exp`
   cover both the value arm and any unqualified operation arm (qualified `HArm` is unchanged);
   the type checker then classifies each occurrence per §3.3 (op if the head name resolves
   against the header, else the value arm — which must have zero extra patterns).

The headed and headerless `with` are distinct productions (e.g. `EWith` and `EWithH`) so the
absence of a header is unambiguous. Reapply the two documented manual parser patches after
regenerating (`Layout.hs` separator patch, `Par.y` `NEListRecordFieldPat` patch).

### 3.5 Type-checker integration

`inferHandler` (`src/Wok/TypeChecking/Infer.hs:1655`) gains the header as an extra argument
(the routing at `EWith`/`EWithH` supplies it; `[]` for a headerless block). Changes:

- **Arm classification.** Before the existing per-arm loop, classify each unqualified arm:
  resolve its head name against the header effects (0 → error, 1 → op arm with that effect,
  ≥2 → ambiguity error), or treat it as the value arm. Qualified arms are unchanged except
  for the "qualified effect must be in the header (when a header is present)" check.
- **Handled set.** When a header is present, `handledEffects` is the header list (strict
  contract); coverage runs against it. When absent, unchanged (union of arm heads).
- The body-type modes (auto-resume vs binder-control), resume typing, value-arm handling,
  and effect discharge are all unchanged from slice 1.

## 4. Forgotten-resume lint (§8)

### 4.1 Rule

> If an operation arm binds a **named** continuation `k`, `k` is **not referenced anywhere in
> the arm body**, and the operation is a **returning** operation (its result type is not
> `Never`, §2.3), emit a warning: the continuation is discarded — did you mean to resume, or
> to abort? Suppress an intentional abort by binding the continuation to `_` (the wildcard)
> instead of a name.

The trigger is binder-**unreferenced**, not binder-never-called: an escaping continuation
(`Async.await fut k -> Blocked fut k`) references `k` and never warns. A non-returning
operation (`throw : … -> Never`) is exempt, so genuine exceptions do not warn.

### 4.2 `_` (wildcard) as the suppressor (not a keyword)

The suppressor is the existing **wildcard pattern** `_`: an arm that intentionally aborts a
*returning* operation binds its continuation to `_` instead of a name, and the lint stays
quiet.

```
State.get k -> initialState     -- named but unreferenced (returning op) -> WARN
State.get _ -> initialState     -- wildcard: intentional abort           -> silent
```

This satisfies the spec's "the suppressor is not a semantic keyword": `_` is the wildcard
pattern wok already has, so it needs no new name, no reserved word, and no grammar change.
It is also stronger than a magic name — a wildcard binds nothing, so the continuation is
*structurally unreferenceable*, making "forgot to resume" impossible by construction rather
than checked after the fact. The lint therefore only ever concerns a **named** binder
(`APVar`); a wildcard binder (`APWild`) is the explicit discard and is never warned. (A
non-returning op needs no suppressor at all; it is exempt by §2.3.)

> Supersedes `discard`: the surface spec §8 and the `effect-surface-syntax-final` memory name
> `discard` as the suppressor. This slice re-litigates that on the merits (a wildcard is
> lower-machinery and structurally honest) and replaces it with `_`. Surface-spec §8 and the
> memory are updated to match as part of this slice's migration.

### 4.3 Mechanism

The binder-control branch of `inferHandler` (`Infer.hs:1731`) accepts both a named binder and
a wildcard:

1. **Named binder** `[Abs.APVar (Abs.VarId (_, kname))]`: bind `kname : T -> R` as today.
   Then compute whether `kname` occurs free in the arm body — a surface-level free-variable
   scan over the `Abs.Exp` body is sufficient and simplest (respecting ordinary lambda/let
   binders; the typed body node is also available if a typed-AST walk is preferred). If
   `kname` is unreferenced **and** the op's result type is not `Never`:
   `addWarning (ForgottenResume pos effect op)`.
2. **Wildcard binder** `[Abs.APWild]`: the continuation is discarded; bind nothing, type the
   body at the answer type `R`, and never warn. (Elaboration mirrors the named-binder control
   arm but with no surface name to bind — the resume `Name` is still generated for the
   runtime; it simply has no surface alias.)

Add one constructor to `Warning` (`src/Wok/TypeChecking/Error.hs:129`):

```haskell
| ForgottenResume SourceSpan Text Text
  -- ^ An operation arm binds a continuation that is never referenced in its body,
  --   on a returning operation. Args: position, effect name, operation name.
```

The lint is a **warning** (non-fatal): it never rejects a valid program. It rides the
existing `addWarning`/`runTC` channel (`Monad.hs:148`) and is reported alongside a successful
compile, exactly like `RowShadow`/`NonExhaustiveMatch`.

## 5. `MalformedHandlerArm` error (roadmap follow-up #2)

The slice-1 per-arm branch throws `UnknownOperation` when an arm has more than `arity + 1`
patterns or a non-variable continuation binder (`Infer.hs:1743`). This is misleading — the
operation *is* known; the *arm* is malformed. Replace it with a dedicated error.

Add to `TypeError` (`src/Wok/TypeChecking/Error.hs`):

```haskell
| MalformedHandlerArm SourceSpan Text Text
  -- ^ A handler arm for a known operation has an invalid pattern shape:
  --   more than (op arity + 1) patterns, or a non-variable continuation binder.
  --   Args: position, effect name, operation name.
```

Throw it at the `_ ->` fallthrough of the binder-shape `case`. The error message should
state the expected shape (the op's argument patterns, plus an optional variable continuation
binder).

## 6. Migration and testing

- **Fixtures use `String` for the throw argument** (`throw : String -> Never`). `String` is
  implemented end-to-end as a carried value (literal → `LStr` → `VLit (LStr …)`, with
  matching and rendering); it lacks string *operations*, which these fixtures do not need.
- **Migrate `Exn` examples** from `effect Exn a = { throw : String -> a }` (phantom param) to
  `effect Exn = { throw : String -> Never }`, including `test/run-examples/16-exn-abort.wok`,
  and regenerate affected goldens (read each diff).
- **New fixtures:**
  - Header: a `with State { get -> …; set s -> … }` run/typecheck example; an ambiguity
    typecheck-fail (two header effects declaring the same op); a coverage-contract
    typecheck-fail (header effect with a missing op); a qualified-effect-not-in-header
    typecheck-fail.
  - Lint: a returning op with an unreferenced *named* binder (warning fires); the same
    suppressed by a `_` (wildcard) binder (no warning); an escaping continuation
    `await fut k -> Blocked fut k` (no warning); a non-returning `throw : … -> Never` aborting
    (no warning).
  - Malformed arm: too many patterns / non-variable binder (the new error).
- **Reconcile the design corpus:** update surface-spec §8 (`docs/.../2026-06-05-effect-handler-
  surface-syntax.md`) and the `effect-surface-syntax-final` memory to name `_` (not `discard`)
  as the suppressor, and to state non-returning ops use a `Never` result (not an output-only
  effect param). Keeps the authoritative corpus consistent with this slice.
- **Verify commands:** `cabal build`; `cabal test`; `cabal run wok -- <file> --run|--dump-anf`;
  regenerate goldens with `cabal run wok-tests -- --accept` (read diffs before accepting).
- Warnings appear in golden output; confirm the lint fixtures assert the warning text and the
  suppressed/exempt fixtures assert its absence.

## 7. Deferred (captured, not built here)

- **Abort-policy config** (print backtrace / hard abort / `exit 0`). This is a *handler*
  decision, not a property of `Never`: different handlers over an abort effect give different
  policies (`throw msg k -> Sys.exit 0` vs `-> printStackTrace msg`). Making `Never` carry
  config would make it inhabited and destroy its guarantee. A `Sys`/`Exit` runtime effect is
  the home for this, deferred with the runtime.
- **Locks / STM / Mutex / lock elision.** A lock is an effect handled by the concurrency
  runtime (slice 4); STM vs Mutex is a handler choice behind the same surface op, not a
  global decision; eliding a lock when control flow proves single-consumer access is the
  escape/multiplicity analysis from the higher-IR direction (slice X). All depend on
  machinery not yet built; out of scope here.
- Bounded `(with H ; e)` (slice 3); parameterized handlers, scheduler, `Future`,
  `Control.Wok` (slice 4); one-shot multiplicity check, value restriction, cancellation
  (slice X).
- **Region / lifetime scoping on a handler.** The `with` scope is the natural home for
  regions (a handler installs a capability bounded by its extent, as Koka's `runST` does),
  and the *capability* is already region-scoped today: a `with` discharges its effect from the
  handled row, so a closure escaping the scope that still performs the effect fails the
  undischarged-effect check. What is *not* yet enforced is preventing a *resource value*
  (mutable ref, buffer) allocated under the handler from escaping — that needs a region
  witness introduced by a **parameterized handler** (slice 4) plus a **value-restriction /
  skolem-escape check** (slice X; the substrate partially exists — see `EscapedTyVar` /
  `RigidEscape`). Region semantics ride the handler's effect *parameter*, never the §3.3
  effect *header* (which binds no variables); keep the two orthogonal.

## 8. Self-review

- **Placeholders:** none. The one open decision (`data Never` vs `TcNever`) is explicit, has
  a default, and is resolvable in the plan's first task without changing the rest of the
  design.
- **Consistency:** the lint discriminator (§2.3 "result is `Never`") matches the `Never`
  representation (§2.4) and the exemption in §4.1. The header coverage contract (§3.2) reuses
  the existing `HandlerCoverage` mechanism against a header-derived handled set (§3.5).
- **Scope:** focused on header + lint + the two supporting pieces (`Never`, malformed-arm).
  Everything runtime-flavoured (abort policy, locks, scheduler) is explicitly deferred (§7).
- **Ambiguity:** the value-arm/unqualified-op collision is resolved by an explicit semantic
  rule (§3.3) and a single grammar production (§3.4); the lint suppressor is pinned to `_`,
  the existing wildcard pattern (§4.2), not a new keyword.
- **Goal alignment:** unchanged — handlers stay second-class (decidable), nondeterminism stays
  row-tracked (deterministic), effect handlers remain the one control mechanism. `Never` is a
  type, not a new control feature.
