# Typed Core — design

Status: draft (rev 1)
Owner: zy
Date: 2026-06-04

> **Decomposition note.** This is sub-project 1 of two. It builds the typed-IR
> foundation only — behavior-preserving, no new surface syntax. Sub-project 2
> (a minimal `Eq` type-class slice) rides on this foundation and is a partial
> implementation of the surface design in `2026-05-27-typeclasses-spec.md`. The
> two are sequenced so the large `Infer.hs` change lands green-to-green before
> any semantics depend on it.

## Motivation

Wok is heading toward a self-hosting compiler, so the intermediate
representation must *carry* types rather than trust a side-channel. Today it
does not:

- Inference computes a `Type s` for every subexpression (`inferExprW :: Map
  Text (Type s) -> Abs.Exp -> TC s (Type s)`), uses it for unification, and
  **discards it**. The only thing emitted per declaration is `TypedDecl { tdName,
  tdScheme }` — one scheme per top-level binding, nothing per-node or per-binder.
- Elaboration (`Wok.IR.Elaborate`) consumes the raw `Abs.Module` plus the
  `Env` and produces a deliberately **type-erased** ANF (`Wok.IR.Anf`).

The frozen/closed type representation (`CType`) and the zonk machinery
(`freeze`, `generalize`/`freezeQuantify` in `Unify`/`Infer`) already exist —
what is missing is a path that carries inferred types from inference into the
IR.

**Goal:** inference emits a *typed AST* (each node decorated with its zonked
`CType`); elaboration consumes that typed AST instead of raw `Abs`; the ANF it
produces has type-annotated binders. The program runs identically — this is a
foundation, not a feature.

**First consumer:** sub-project 2 attaches type-class *evidence* as additional
decoration on the same typed tree. Future analyses (representation, unboxing,
specialization) also require typed IR. No-dup/occurrence analysis does not need
types and is unaffected.

## Scope

**In scope**
- A typed AST datatype mirroring the elaboration-reachable `Abs.Exp`/pattern
  forms, each node carrying a `CType`.
- Inference building that tree and freezing it to `CType` per declaration.
- `Wok.IR.Anf.Binder` carrying a type (`bndType :: CType`).
- Elaboration rewritten to walk the typed AST and to annotate every binder it
  mints (params, lets, case fields, fresh ANF temporaries) with a type.
- A typed pretty-print path for golden inspection.

**Out of scope**
- Type classes, constraints, evidence, dictionary passing (sub-project 2).
- Numeric-literal polymorphism and new integer types (their own later spec).
- Any change to surface syntax or runtime behavior.
- An IR re-checker / Core Lint. Per decision, the IR is *annotated* and trusted,
  not independently re-typechecked — the ANF is machine-generated, never
  hand-written, so there is no second author to guard against.
- **Type interning / hash-consing.** Each node/binder stores its `CType` by
  value; identical types (`U64`, `Bool`, ...) are not shared. Deferred as a
  memory/equality optimization — adding it later is a drop-in because the typed
  AST is parameterized over the annotation (`Texp a`, deriving `Traversable`):
  an intern pass is `traverse intern :: Texp CType -> Intern (Texp TypeId)`,
  and a pure hash-cons can ride the existing `freezeQuantify` step. Must stay
  deterministic (no `unsafePerformIO` global table — the repo bans it).

## Architecture

The pipeline gains a typed hand-off between the two existing passes:

```
Abs.Module
   │  inference (Wok.TypeChecking.Infer)
   ▼
[ TypedDecl' { scheme, typed body : TExpr (CType-annotated) } ]
   │  elaboration (Wok.IR.Elaborate) — now walks TExpr
   ▼
CoreModule (ANF) with typed Binders   (Wok.IR.Anf)
   │  interpreter (Wok.Interp) — ignores types at runtime
   ▼
Value
```

Types exist for analysis and dumps; the interpreter erases them. All existing
ANF and `run` goldens must stay green — that is the regression guarantee that
makes the large inference change verifiable.

## Components

### 1. The typed AST (`Wok.TypeChecking.Typed`, new module)

A datatype mirroring the `Abs.Exp` constructors that elaboration handles
(literals, `var`, `con`, app, lambda, `if`, tuple, list, paren, paren-op,
proj/proj-con, record/record-ext, let/where, case, handle, operator-chain),
plus the pattern forms that bind names.

Each node is uniformly annotated with its type via a wrapper, so "the type of
any subexpression" is a single field access and freezing happens at one place
per node:

```haskell
data TExpr = TExpr { teType :: CType, teNode :: TExprF }
data TExprF
  = TLit  Lit
  | TVar  ...            -- carries the resolved name/scheme reference
  | TApp  TExpr [TExpr]
  | TLam  [TPat] TExpr
  | TCase TExpr [TAlt]
  | ...                  -- one per elaboration-reachable Abs.Exp form
data TPat  = TPat { tpType :: CType, tpNode :: TPatF }
```

It lives in `Wok.TypeChecking` (inference builds it; elaboration imports it),
and it reuses `CType` directly — see Key Decisions.

### 2. Inference emits the typed AST

The central implementation challenge is **zonk timing**. During inference,
node types are `Type s` with unresolved mutable cells; they cannot be frozen to
`CType` until the declaration's inference and generalization are complete. So
inference proceeds in two phases per declaration:

1. **Build** a `Type s`-annotated tree (`TExprS s`) as it infers — every
   `inferExprW` case returns its `(Type s, TExprS s)` node instead of just the
   type.
2. **Freeze** the whole tree to a `CType`-annotated `TExpr` *after*
   generalization, reusing the **same** quantification mapping that
   `generalize`/`freezeQuantify` used for the scheme.

The shared mapping is the correctness crux: a node typed by a variable that the
declaration generalizes must freeze to the *same* `CTGen n` the scheme uses, or
the node types and the scheme disagree. `freezeQuantify` already threads its
mapping through explicit `nextRef`/`seenRef`/`kindsRef` refs (`Infer.hs:64`);
the tree-freeze applies `freezeQuantify` with those same refs. Generalization is
refactored to expose them.

Capture point: `typeEquationWith` (`Infer.hs:1828`) is where each equation's
body is inferred and `generalize` is called; the typed body is built there and
frozen alongside the scheme.

### 3. `Binder` carries a type (`Wok.IR.Anf`)

`Binder` gains `bndType :: CType`. Every binder elaboration creates — top-level
params, lambda params, `let` bindings, `case` constructor fields, and the fresh
`t` temporaries ANF normalization introduces for intermediate computations —
takes its type from the corresponding `TExpr`/`TPat` node. The pretty-printer
gains an optional typed rendering (`x : U64`) for a typed golden dump; the
existing erased dump stays available.

### 4. Elaboration consumes the typed AST (`Wok.IR.Elaborate`)

`elabRhs`/`elabK`/`elabTail`/`elaborateModule`/`elabTopBind`/
`elaborateModulesShared` and the `elaborateExprForTest` seam are retargeted from
`Abs.Exp` to `TExpr`. Name resolution (global `Env` + local scope) is unchanged
in spirit; the only addition is that each minted `Binder` reads its type from the
node it is lowering. Because every `TExpr` carries `teType`, fresh intermediates
get a precise type with no re-derivation.

### 5. Pipeline wiring (`Wok.Pipeline`)

`runPipelineFold`'s per-module result carries the typed decls alongside the
existing AST and env. `elaborateProgram`/`elaborateProgramFull` consume the typed
decls. `--dump-anf` renders the typed ANF; an optional `--dump-typed-ast` may
dump `TExpr` for debugging.

## Data flow (per declaration)

```
Abs equation body
  └ inferExprW ─→ (Type s, TExprS s)          -- phase 1: build, types still mutable
        └ generalize ─→ Scheme  (mints var→CTGen map via freezeQuantify refs)
              └ zonkTExpr (same refs) ─→ TExpr -- phase 2: freeze every node
                    └ bundle: TypedDecl' { name, scheme, typedParams, typedBody }
                          └ elaborate ─→ TopBind with typed Binders
```

## Error handling

- Inference errors are unchanged — the same programs typecheck and fail as
  before.
- Elaboration continues to treat impossible cases as panics (the program is
  already well-typed) and now additionally trusts node types.
- **Zonk totality:** every node's `Type s` must resolve at freeze time. Under
  the current monomorphic-where-needed HM (no classes yet), top-level
  generalization resolves or quantifies all relevant variables, so there should
  be no leftover ambiguous metavar. This must be verified; if a leftover cell can
  occur (e.g. an unconstrained local), the freeze must default it deterministically
  or surface a clear internal error rather than silently emitting a bogus type.

## Testing

- **Regression (primary):** all existing ANF goldens and `run` goldens stay
  green. Behavior is preserved by construction; the goldens prove the inference
  rewrite is faithful.
- **Typed golden dump:** a new typed-ANF golden over the existing success corpus
  pins the binder types (e.g. `id`'s param and result render as the same
  generalized variable; arithmetic binders are `U64`; list/`Option` binders carry
  their constructed types).
- **Unit tests:** `TExpr` construction for representative expressions; a
  zonk-consistency test that a polymorphic function's node types use the same
  generalized variables as its scheme; a monomorphic function's binders carry
  concrete types.
- **Erasure cross-check (optional, transitional):** assert that erasing types
  from the new typed ANF yields the same structure the old type-erased path
  produced, while both paths still exist.

## Key decisions

- **Reuse `CType` in the IR.** The IR imports `Wok.TypeChecking.Types (CType,
  CRow)` rather than defining a parallel type mirror. `CType` is the canonical
  zonked type; duplicating it invites drift. The coupling is acceptable and means
  future type-system additions (e.g. the `CTAssoc` the typeclasses spec
  anticipates) flow through automatically.
- **Annotation only, no Lint.** The IR is trusted, not re-checked (machine-
  generated, single author).
- **Typed hand-off, not a fused pass.** Inference emits `TExpr`; elaboration
  stays a separate, independently-testable pass that is retargeted to `TExpr`.
  Considered and rejected: fusing elaboration into the type checker (emit ANF
  directly during inference) — it would discard the working, tested standalone
  elaborator and entangle two complex passes.
- **Behavior-preserving.** Types never reach the runtime; the typed dumps are
  additive.

## Risks

- **Magnitude.** Every `inferExprW` case must build a `TExprS` node, and
  elaboration must be retargeted — a sizeable mechanical change to a ~100 KB
  file. Mitigation: the change is behavior-preserving and golden-guarded, so the
  risk is effort, not correctness uncertainty.
- **Zonk/quantification consistency.** Node types must freeze with the same
  variable mapping as the scheme. This is the one genuinely subtle correctness
  point; the shared-`freezeQuantify`-refs approach addresses it and the
  zonk-consistency unit test guards it.
- **Zonk totality** (see Error handling) must be confirmed before relying on it.

## Relationship to existing specs

- `2026-05-27-typeclasses-spec.md` — the ambitious type-class *surface* design.
  Sub-project 2 implements a minimal slice of it (single-parameter `Eq`, one
  constrained instance) on top of this typed core; type-class *evidence* becomes
  additional decoration on `TExpr`.
- `2026-05-25-hm-core-design.md` — the HM core this builds on (`CType`,
  `Scheme`, `freeze`, `generalize`).
- `2026-06-03-anf-elaboration.md` / `2026-06-03-anf-cek-interpreter.md` — the
  type-erased ANF and interpreter this upgrades; their goldens are the
  regression guard.
