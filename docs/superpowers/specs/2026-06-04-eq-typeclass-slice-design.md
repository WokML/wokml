# Eq type-class slice (dictionary passing) — design

Status: draft (rev 1)
Owner: zy
Date: 2026-06-04

> **Decomposition note.** This is sub-project 2 of the typeclasses foundation. It
> rides on the typed core (`docs/superpowers/specs/2026-06-04-typed-core-design.md`,
> merged to `main` 2026-06-04) and is a *minimal, decidable* implementation of a
> single slice of the ambitious surface design in
> `docs/superpowers/specs/2026-05-27-typeclasses-spec.md`. It deliberately departs
> from that spec's syntax (layout `where`-blocks instead of `= { , , }`) and scope
> (single-parameter `Eq` only).

## Motivation

Wok has ad-hoc polymorphism reserved (`class`/`instance` are `ReservedKw`) but not
implemented. Today `(==)` is a *monomorphic builtin*: `(==) : U64 -> U64 -> Bool`
declared in `prelude/Std/Base.wok`, backed by a runtime prim resolved by name
(`resolveAtom` falls back to `primTable` when a var is not in local scope). This
slice turns `Eq` into a real single-parameter type class and **repurposes `(==)`
into its method**, so equality becomes per-type and user-extensible.

The immediate user goal: an `Eq` class for integers. The strategic payoff: once
`Eq` is a class, adding equality for a new type (notably the planned `U32`) is
*just a new instance + a prim* — no new dispatch machinery. That follow-up is out
of scope here (see §9) because its hard part is numeric-literal typing, not classes.

**Why dictionary passing (not monomorphization):** wok runs on a CEK interpreter,
so monomorphization's performance win is moot, and dictionaries map directly onto
the existing record IR — `VRecord` + closures + currying already work. A class
dictionary is a record; a method call is a field projection + application.

**First consumer of the typed core's extensibility:** the typed AST is parameterized
over its annotation and was built to carry exactly this kind of decoration. This
slice attaches type-class *evidence* to the typed tree, as the typed-core design
anticipated.

## Goals

- A single-parameter `Eq` class with operator methods and a default method.
- `instance Eq U64` (ground) and `instance (Eq a) => Eq (Option a)` (constrained).
- Polymorphic user functions carrying `(Eq a) => ...` constraints, solved by
  dictionary passing.
- Decidable inference and instance resolution, *enforced* by registration-time
  checks (termination, coherence, ambiguity).
- Zero behavior change for code that does not use classes (all existing goldens
  stay green).

## Non-goals (deferred)

- **Associated types**, **superclasses**, **multi-parameter classes**, **HKT**,
  **explicit kind annotations** — the ambitious parts of the typeclasses spec.
- **Functional dependencies**, **type families**, **overlapping/orphan instance
  flexibility** — the features that threaten decidability.
- **U32 and numeric-literal polymorphism** — their own later spec (§9). U32 then
  becomes a ground `Eq` instance + a prim; this slice provides everything else.
- **An IR re-checker / Core Lint** — consistent with the typed-core decision: the
  IR is annotated and trusted, not re-typechecked.

## Surface syntax

Layout `where`-blocks, reusing the existing BNFC layout filter
(`grammar/Wok.cf:58`, `layout "let", "where", "of"`). The `where` keyword already
opens an indentation block with virtual `{ ; }`; class/instance bodies reuse it
verbatim — no new layout work.

```wok
class Eq a where
  (==) : a -> a -> Bool
  (/=) : a -> a -> Bool
  (/=) x y = not (x == y)        -- default method

instance Eq U64 where
  (==) = eqU64                    -- /= uses the class default

instance (Eq a) => Eq (Option a) where
  (==) x y =
    case (x, y) of
      (None,   None)   -> True
      (Some a, Some b) -> a == b
      _                -> False
```

- **Operators are the methods** (Haskell-style). Writing `x == y` directly invokes
  the class method; there is no separate `eq`/`ne` name. This is the literal
  meaning of "repurpose `(==)`".
- **Method names accept parenthesized operators** `(==)`; the sig grammar already
  allows `(VarSym)` names, so class/instance entries extend that.
- **Constraints in function sigs are always parenthesized**, even singletons, for
  left-to-right unambiguity (consistency rule from the typeclasses spec):
  ```wok
  isEq : (Eq a) => a -> a -> Bool
  ```
- **Placement**: `class Eq`, `instance Eq U64`, and a new `not : Bool -> Bool`
  live in `prelude/Std/Base.wok`. The old monomorphic `(==)` / `(/=)` sigs there
  are removed; `eqU64` (the raw prim) gets a builtin sig in their place.

### Grammar additions (`grammar/Wok.cf`)

```bnfc
-- Top-level declarations (where-block bodies use layout-virtual braces):
DClass.    Decl ::= "class" ConId [VarId] "where" "{" [ClassEntry] "}" ;
DInstance. Decl ::= "instance" InstHead "where" "{" [InstEntry] "}" ;

-- Instance head: optional constraint context + class name + type args:
InstHead.    InstHead ::= ConId [Type2] ;
InstHeadSup. InstHead ::= "(" [Constraint] ")" "=>" ConId [Type2] ;

-- Class entries: operation sigs + default-method equations.
-- MethodName admits a plain VarId or a parenthesized operator (VarSym).
CESig.     ClassEntry ::= MethodName ":" Type ;
CEDefault. ClassEntry ::= FunLHS "=" Exp ;
separator  ClassEntry ";" ;             -- virtual ; from layout

-- Instance entries: operation impls.
IEImpl.    InstEntry ::= FunLHS "=" Exp ;
separator  InstEntry ";" ;

-- Constraint context in a sig: always parens.
TConstrFun. Type ::= "(" [Constraint] ")" "=>" Type ;
Constraint. Constraint ::= ConId [Type2] ;
separator   Constraint "," ;
```

`class`/`instance` are already `ReservedKw`; `=>` is the one new compound token.
LALR(1): the `class`/`instance` keyword fixes the decl flavor; `(...) "=>"` is
unambiguous at type level. The `MethodName` production (VarId | `(VarSym)`) mirrors
the existing `SigName` shape.

## Architecture

The pipeline is unchanged in shape; class machinery is bolted onto the existing
passes, with the heavy logic in two NEW modules so `Infer.hs` (already 2431 lines)
gains only thin hook points.

```
Abs.Module
   │  inference (Wok.TypeChecking.Infer)
   │    + Class registration  (Wok.TypeChecking.Class)   -- NEW
   │    + constraint solving   (Wok.TypeChecking.Solve)  -- NEW
   ▼
[ TypedDecl { scheme (qualified), evidence params, typed body w/ evidence } ]
   │  elaboration (Wok.IR.Elaborate) — lowers evidence to records/args
   ▼
CoreModule (ANF): instances → dict binds; methods → proj+apply
   │  interpreter (Wok.Interp) — CAF fix forces 0-arity dict values
   ▼
Value
```

### Module split (keeps `Infer.hs` to glue)

**New modules** (where the weight goes):

- `Wok.TypeChecking.Class` — `processClassDecl` / `processInstanceDecl`:
  build `ClassInfo` / `InstanceInfo`, register into `Env`, run the **termination
  check** (§7) and **coherence check** (§7). ~150-200 lines.
- `Wok.TypeChecking.Solve` — the constraint solver and evidence construction:
  match a `Constraint` against `envInstances`, build the `Evidence` term, recurse
  into instance contexts, **detect ambiguity** (§7). The genuinely new algorithm,
  isolated from inference. ~200 lines.

**Small, localized edits to existing files:**

- `Env.hs` — add `envClasses :: Map Text ClassInfo` and
  `envInstances :: [InstanceInfo]`, plus the `ClassInfo` / `InstanceInfo` records.
- `Types.hs` — add `Constraint` and `Evidence` types.
- `Typed.hs` — a class-method node carrying its resolved `Evidence`, and an
  evidence-param list on `TypedDecl` / `TLocalDecl`. Localized; the rest of the
  tree is untouched.
- `Monad.hs` — one constraint-accumulator ref in `TCCtx`.

**`Infer.hs` footprint — three hook points only (~40-60 lines):**

1. On class-method name lookup, emit a `Constraint` into the accumulator.
2. At `generalize` / `finalizeGroup`, call `Solve.discharge` to resolve what it
   can and quantify the rest into the scheme's qualified prefix.
3. In `inferProgramTC`, dispatch the new `DClass` / `DInstance` arms to `Class`.

If a hook turns out to need more than glue, that is the signal to extract it into
`Class` / `Solve`, not to let it accrete in `Infer.hs`. This mirrors the existing
codebase pattern where `Unify.hs` is its own module that `Infer.hs` calls into.

## Components

### 1. Class & instance registration (`Wok.TypeChecking.Class`)

```haskell
data ClassInfo = ClassInfo
  { ciParam    :: (Text, Kind)        -- single parameter, e.g. ("a", KStar)
  , ciMethods  :: Map Text Scheme     -- method -> forall a. (Eq a) => <sig>
  , ciDefaults :: Map Text Abs.Exp    -- default-method bodies (raw AST)
  }

data InstanceInfo = InstanceInfo
  { iiClass   :: Text                 -- "Eq"
  , iiHead    :: CType                -- the instance type, e.g. U64 or Option a
  , iiContext :: [Constraint]         -- e.g. [Eq a] for Eq (Option a)
  , iiDictName :: Text                -- "dict$Eq$U64" / "dict$Eq$Option"
  , iiImpls   :: Map Text Abs.Exp     -- method impls provided by the instance
  }
```

- `processClassDecl`: each method sig becomes a `Scheme` quantified over the class
  param with the class constraint in its qualified prefix
  (`forall a. (Eq a) => a -> a -> Bool`). Methods are added to `envVars` so use
  sites resolve them as ordinary names whose scheme happens to carry a constraint.
  Defaults are stored as raw AST, specialized per instance at elaboration.
- `processInstanceDecl`: validates the class exists; verifies every method is
  provided OR has a class default; checks coherence and termination (§7); mints
  `iiDictName`; records the instance.

### 2. Constraint type and evidence (`Types.hs`)

```haskell
data Constraint = Constraint { conClass :: Text, conArg :: CType }

data Evidence
  = EvGlobal Text            -- a ground instance dict, e.g. dict$Eq$U64
  | EvParam  Text            -- a dictionary parameter in scope (e.g. dEqa)
  | EvApp    Text [Evidence] -- a dict-builder applied to sub-evidence
```

### 3. Constraint collection, solving, evidence (`Infer.hs` hooks + `Solve`)

Mirrors the typed core's **build-then-freeze two-phase** pattern: during inference,
node types are mutable `Type s` and evidence is an unresolved placeholder; both are
resolved at the per-binding freeze.

- **Collect**: using a class method instantiates its scheme — `a` becomes a fresh
  TVar — and emits `Eq <var>` into the accumulator. The method node is built with
  an evidence placeholder keyed to that constraint.
- **Solve at generalization** (`Solve.discharge`), per accumulated `Eq t`:
  - `t` concrete with a matching instance → **discharge**. Evidence is `EvGlobal`
    (ground instance) or `EvApp dictName subEv` (constrained instance, recursing
    into its context).
  - `t` a variable being generalized → **quantify**: `Eq a` joins the scheme's
    qualified prefix; the binding gains an evidence parameter `dEqa`; method nodes
    at type `a` resolve to `EvParam "dEqa"`.
  - `t` concrete with no instance → "no instance for `Eq T`" error.
  - `t` a constrained variable absent from the binding's type → **ambiguity**
    error (§7).
- **Freeze**: the same pass that freezes node `CType`s resolves each evidence
  placeholder to a concrete `Evidence`, using the var→quantifier mapping already
  shared with the scheme. `TypedDecl`/`TLocalDecl` gain `[(Text, Constraint)]`
  evidence params; the typed tree's method nodes carry resolved `Evidence`.

### 4. Dictionaries in the IR / runtime

- A dictionary is a `VRecord "Eq" { "==" : <fn>, "/=" : <fn> }`. Operator strings
  are valid IR record labels (labels are `Text`).
- **Ground instance** lowers to a 0-arity top-level dict value:
  `dict$Eq$U64 = Eq { "==" = eqU64, "/=" = \x y -> not (eqU64 x y) }`.
- **Constrained instance** lowers to a dict-*builder* function taking the element
  dict: `dict$Eq$Option = \dEqA -> Eq { ... }`. Has a param; runs unchanged today.
- **Default methods carry no dict self-reference.** At instance elaboration,
  default-method bodies are *specialized* by substituting the instance's own method
  impls for class-method references. `Eq U64`'s `/=` becomes
  `\x y -> not (eqU64 x y)` directly — no self-referential record needed.
- **The raw prim**: the existing `==` prim is renamed `eqU64` in `primTable` and
  given a builtin sig in `Base.wok`; the `/=` prim is dropped (the class default
  covers it). `eqU64` is what `instance Eq U64` plugs into `(==)`.

### 5. Interpreter CAF fix (`Wok.Interp` / `Machine.hs`)

Today `runModule` rejects any 0-arity top-level bind other than `main`
(`UnsupportedCaf`, `Machine.hs:191`) and otherwise wraps every top-level bind as an
*unforced* `VClosure` (so projecting a field off a dict would fail).

Fix: build the global environment so that **0-arity top-level binds are evaluated
to `Value`s once and bound as those values**, while function binds (arity > 0) stay
`VClosure`s as today. The global env must be recursive/lazy so a dict bind can
reference other globals regardless of declaration order (the `VClosure` env field
is already lazy; extend the same laziness to forced 0-arity binds, e.g. via a
knot-tied `Map` of thunks forced on demand). `main` keeps its existing 0-arity
entry-point handling.

This is the one true prerequisite; constrained instances (which have a param) would
run without it, but ground dicts would not.

### 6. Elaboration (`Wok.IR.Elaborate`) — mechanical lowering, no resolution

- Evidence params on a binding → ordinary `Binder` params prepended to the
  function (typed from the constraint).
- A class-method use with evidence `ev` → project the method field off the dict
  and apply: `(==) @ev x y`  ⇒  `(ev."==") x y`.
- Evidence terms: `EvGlobal n` → reference global dict `n`; `EvParam n` → the dict
  binder in scope; `EvApp f es` → apply builder `f` to lowered sub-evidence.
- Instances → top-level binds: ground → 0-arity dict record; constrained →
  dict-builder lambda. Default methods specialized as in §4.

### 7. Decidability guards (enforced at registration, not assumed)

The slice is decidable by construction; we *enforce* the conditions rather than
trusting them, so it stays decidable as instances are added later.

- **Termination (Paterson-style structural condition).** `processInstanceDecl`
  rejects any instance whose context constraint is not on a type *structurally
  smaller* than the head. Every legal instance has shape
  `(Eq t1, ..., Eq tn) => Eq (T t1 ... tn)` with each `ti` an immediate argument
  of `T`, so resolution is a terminating structural fold
  (`Eq (Option U64) -> Eq U64 -> done`). The disallowed shapes (context not
  smaller than head, e.g. `Eq [a] => Eq a`) are exactly the ones that loop.
- **Coherence.** One instance per `(class, type-head)`; duplicate registration is
  an error. Resolution is a deterministic lookup keyed by the head's outermost
  type constructor — no backtracking, no overlap.
- **Ambiguity.** A constrained variable that does not appear in the type it
  qualifies (e.g. `forall a. (Eq a) => Bool`) is rejected with a clear message.
  This is incompleteness of inference, not undecidability, but it must be reported
  rather than left as a dangling constraint.

These three, plus the single-parameter / no-fundeps / no-type-families scope, keep
both inference (HM + qualified types, decidable per Jones's "Qualified Types") and
resolution decidable.

## Data flow (per constrained binding)

```
isEq x y = x == y
  └ infer body: (==) instantiated -> Eq α emitted; node carries placeholder ev
        └ generalize: α generalized -> scheme forall a. (Eq a) => a -> a -> Bool
              └ Solve: ev placeholder -> EvParam "dEqa"; binding gains param dEqa
                    └ freeze: node CTypes + evidence resolved with shared mapping
                          └ TypedDecl { scheme, evParams=[(dEqa, Eq a)], body }
                                └ elaborate: \dEqa x y -> (dEqa."==") x y
```

## Error handling

- **No instance**: `Eq T` with no registered instance → typed error naming class +
  type.
- **Ambiguity**: constrained var absent from the qualified type → clear error.
- **Non-terminating / overlapping instance**: rejected at registration.
- **Missing method in instance** with no class default → error naming the method.
- Existing inference errors are unchanged; non-class programs typecheck and fail
  exactly as before.
- Elaboration continues to treat impossible cases as panics (the program is
  already well-typed).

## Testing

- **Regression (primary):** all existing erased-ANF, typed-ANF, and `run` goldens
  stay byte-identical — the behavior-preservation proof for non-class code.
- **Parse:** class/instance `where`-blocks; operator methods `(==)`; constrained
  instance head `(Eq a) => Eq (Option a)`; parenthesized constraint in a sig.
- **Typecheck:**
  - `1 == 2` infers `Bool`.
  - a `(Eq a) => ...` user function collects and quantifies the constraint.
  - `Eq (Option a)` use requires `Eq a` to be dischargeable.
  - missing-instance error (`Eq` on a type with no instance).
  - ambiguity error (constrained var absent from the type).
  - non-terminating-instance registration rejected.
  - duplicate-instance (coherence) registration rejected.
- **Run goldens:**
  - `eq` on `U64`.
  - `eq` on `Option U64` (constrained instance + element-dict passing exercised).
  - a polymorphic `(Eq a) =>` user function applied at two distinct types.
  - `/=` via the class default.
- **CAF fix:** a ground dict value evaluates once and projects correctly; a module
  with a non-dict 0-arity constant also now runs (the fix generalizes).

Golden test files (proposed): `test/run-examples/` additions for the four run
cases; `test/typecheck-examples/` additions for the typecheck cases; typed-ANF
goldens for an instance dict and a constrained function so the lowering is pinned.

## Key decisions

- **Operators are the methods** (not `eq`/`ne` named methods + a bridge). Least
  machinery; the literal meaning of "repurpose `(==)`".
- **Layout `where`-blocks** over the spec's `= { , , }` form. Leaner, and reuses
  the existing layout filter with zero new layout work.
- **Dictionary passing** over monomorphization. CEK runtime makes mono's win moot;
  dicts map onto the existing record IR.
- **Evidence-decorated typed AST** (Approach 1) over a post-elaboration insertion
  pass or inline resolution during elaboration. Keeps instance resolution inside
  the type checker where type + constraint info live; elaboration stays a dumb,
  golden-testable lowering. This is what the typed core was built to enable.
- **Heavy logic in new modules** (`Class`, `Solve`); `Infer.hs` gains only hooks.
- **Default methods specialized per instance** (substitution) rather than via dict
  self-reference. Avoids recursive dict values for ground instances.
- **Decidability conditions enforced at registration**, not assumed.

## Risks

- **`Infer.hs` clutter.** Mitigated by the module split and the three-hook
  discipline; if a hook exceeds glue, extract it.
- **CAF fix correctness.** Recursive/lazy global env must force 0-arity binds
  exactly once and tolerate forward references without looping on genuine cycles.
  Guard with the CAF run test plus the unchanged `run` goldens.
- **Evidence/quantifier consistency.** Evidence must freeze with the same var
  mapping as the scheme (same subtlety the typed core already solved); reuse that
  shared `freezeQuantify` mapping.
- **Scope creep toward the full typeclasses spec.** Held off by the explicit
  non-goals; anything beyond single-parameter `Eq` is a later spec.

## Relationship to existing specs

- `2026-05-27-typeclasses-spec.md` — the ambitious surface design. This slice
  implements a single decidable corner of it and intentionally departs on syntax
  and scope; that spec remains the north star for associated types / superclasses /
  HKT.
- `2026-06-04-typed-core-design.md` — the typed-IR foundation this rides on;
  evidence is the first decoration added to its parameterized typed AST.
- `2026-05-25-hm-core-design.md` — the HM core (`CType`, `Scheme`, `freeze`,
  `generalize`) the constraint/qualified-type extension builds on.
- `2026-06-03-anf-cek-interpreter.md` — the CEK interpreter whose CAF handling this
  extends and whose `run` goldens are the regression guard.

## U32 follow-up (out of scope; the payoff)

Once this lands, U32 is a separate small spec:

- Add the `U32` tycon (`Builtins.hs`) and prims (`eqU32`, arithmetic).
- `instance Eq U32 where (==) = eqU32` — a *ground* instance, trivially passing
  the termination check, requiring no new class machinery.

The genuinely hard part of U32 is **numeric-literal typing** (how `1` chooses
between `U64`/`U32` — defaulting and/or annotation), which is why it is its own
spec and not bundled here. This slice deliberately provides the class mechanism so
that the U32 work is "a new instance + a prim + literal typing," nothing more.
