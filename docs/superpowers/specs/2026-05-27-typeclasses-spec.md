# Type classes with associated types and HKT — surface design

Status: draft (rev 2 — surface-language focus; implementation deferred until records ship)
Owner: zy
Date: 2026-05-27 (rev 2: 2026-05-27)

> **Scope note (rev 2):** this spec is currently the SURFACE LANGUAGE design only. Implementation details (constraint solver, instance resolution, kind inference algorithm) are sketched but deferred. Records ship first (`2026-05-27-records-spec.md`); typeclasses spec gets its implementation pass after row polymorphism for records is correct and validated.

## Motivation

Wok needs a mechanism for **ad-hoc polymorphism** — functions that work on different types via per-type implementations. The natural choice for an ML-family language with the HM core already built is Haskell-style type classes, which Wok's HM design doc anticipated by reserving `class` and `instance` in `ReservedKw`.

This spec defines:
- **Type class declarations** with operations, default methods, and optional associated types.
- **Instances** providing per-type implementations.
- **Multi-parameter classes** and **superclasses**.
- **Higher-kinded types (HKT)** via implicit kind inference, with explicit kind annotations as an opt-in.
- **Constraints in function sigs** with mandatory parentheses (even for single constraints, for at-first-glance unambiguity).

Type classes interoperate cleanly with the records spec (associated types like `Element c` describe properties of nominal record types) and the effects spec (associated effect rows like `with SaveEffects p` let classes abstract over effect sets).

## Goals

- **Class declarations** with operations and optional default methods:
  ```wok
  class Eq a = 
    { eq : a -> a -> Bool
    , ne : a -> a -> Bool
    , ne x y = not (eq x y)              -- default method
    }
  ```
- **Associated types** as type-level functions of the class parameter:
  ```wok
  class Container c = 
    { type Element c
    , type Index c
    , empty  : c
    , insert : Index c -> Element c -> c -> c
    , lookup : Index c -> c -> Option (Element c)
    }
  ```
- **Instances** that provide both operation implementations and associated-type bindings:
  ```wok
  instance Container (Map k v) = 
    { type Element (Map k v) = v
    , type Index   (Map k v) = k
    , empty  = ...
    , insert = ...
    , lookup = ...
    }
  ```
- **Constraints in sigs** with mandatory parens:
  ```wok
  example : (Eq a, Show a) => a -> a -> () with IO
  ```
- **Superclasses** via constraint on the class declaration:
  ```wok
  class (Eq a) => Ord a = { ... }
  ```
- **Multi-parameter classes**:
  ```wok
  class Conversion a b = { convert : a -> b }
  ```
- **HKT** with implicit kind inference:
  ```wok
  class Functor f = { fmap : (a -> b) -> f a -> f b }
  ```
- **Associated effect rows** for interoperation with the effects spec:
  ```wok
  class Persistent p = 
    { type SaveEffects p
    , save : p -> () with SaveEffects p
    }
  ```

## Non-goals (deferred)

- **Constraint kinds** (`Constraint` as a first-class kind) — Haskell's `ConstraintKinds` extension. Defer.
- **Existential types** / GADTs — orthogonal feature; not in scope.
- **Type families** beyond associated types (closed type families, type-level functions outside class bodies) — defer.
- **Functional dependencies** — associated types subsume the common use cases; defer fundeps.
- **Coherence flexibility** — overlapping instances, incoherent instances. v1 requires single canonical instance per (class, type-tuple) pair.
- **Orphan instances** — require instance declarations in the same module as either the class or the type. Standard discipline.
- **Implicit parameters** — Wok will not have Haskell's `ImplicitParams`. Use class constraints or explicit arguments.
- **Higher-rank polymorphism** — HM design doc commits to rank-1; classes' operations are rank-1.
- **Subtyping** — no class-based subtyping; constraints are unification-based.

## Surface syntax

### Class declarations

```wok
-- Single-parameter class:
class Eq a = 
  { eq : a -> a -> Bool
  , ne : a -> a -> Bool
  
  -- Default method (recommended when one operation can be defined in terms of others)
  , ne x y = not (eq x y)
  }

-- Class with associated types:
class Container c = 
  { type Element c
  , type Index   c
  , empty  : c
  , insert : Index c -> Element c -> c -> c
  , lookup : Index c -> c -> Option (Element c)
  , size   : c -> U64
  }

-- Multi-parameter class:
class Conversion a b = 
  { convert : a -> b
  }

-- HKT class (kind of `f` inferred to be `* -> *`):
class Functor f = 
  { fmap : (a -> b) -> f a -> f b
  }

-- Class with associated effect row:
class Persistent p = 
  { type SaveEffects p
  , save : p -> () with SaveEffects p
  , load : String -> Option p with SaveEffects p
  }

-- Superclass:
class (Eq a) => Ord a = 
  { compare : a -> a -> Ordering
  , lt : a -> a -> Bool
  , gt : a -> a -> Bool
  
  , lt x y = case compare x y of LT -> True ; _ -> False
  , gt x y = case compare x y of GT -> True ; _ -> False
  }
```

**Body syntax:** brace-delimited, comma-separated, mirroring `data` and `effect` declarations. Three kinds of entries:
1. **Associated type declarations** — `type Element c`. May appear in any order; conventionally first.
2. **Operation type signatures** — `op : T`.
3. **Default method definitions** — `op args = body`. Optional; provide default impls in terms of other class operations.

### Instances

```wok
instance Eq U64 = 
  { eq = primEqU64
  -- ne uses class-default
  }

instance Eq String = 
  { eq = stringEq
  , ne = \a b -> stringNe a b              -- override default for performance
  }

instance Container (Map k v) = 
  { type Element (Map k v) = v
  , type Index   (Map k v) = k
  , empty  = Map { entries = [] }
  , insert = \k v m -> ...
  , lookup = \k m   -> ...
  , size   = \m     -> List.length m.entries
  }

instance Functor Option = 
  { fmap = \fn opt -> case opt of
      None   -> None
      Some x -> Some (fn x)
  }

instance Functor [] = 
  { fmap = \fn xs -> case xs of
      []      -> []
      x :: tl -> fn x :: fmap fn tl
  }

instance (Eq a) => Eq (Option a) = 
  { eq = \a b -> case (a, b) of
      (None, None)     -> True
      (Some x, Some y) -> eq x y
      _                -> False
  }

instance Persistent User = 
  { type SaveEffects User = IO + Audit
  , save = \u -> IO.write (User.name u)
                  Audit.record u
  , load = \path -> let raw = IO.read path
                    in parseUser raw
  }
```

**Body syntax:** same shape as class declarations:
- Associated type bindings — `type Element (Map k v) = v`.
- Operation implementations — `op = ...` or `op args = ...`.

### Constraints in function sigs

```wok
-- Single constraint (parens required):
showLine : (Show a) => a -> () with IO

-- Multiple constraints:
sortAndShow : (Ord a, Show a) => [a] -> () with IO

-- Multi-line for clarity:
processItem 
  : ( Container c
    , Eq (Element c)
    , Persistent (Element c)
    )
  => Index c 
  -> c 
  -> Bool 
  with SaveEffects (Element c) + IO + Logger + e
```

**Constraints always use parens** (even for single constraint) to avoid the at-first-glance ambiguity between "constraint list" and "tuple type." See "Why mandatory parens" below.

### Associated type access at use sites

Function-application form (NOT dot-access):

```wok
example : (Container c) => Index c -> c -> Option (Element c)
example idx container = Container.lookup idx container
```

`Element c` reads as "the Element of c" — a type-level function application. Same syntactic shape as any other type-constructor application.

### HKT with explicit kinds (optional)

By default, kinds are inferred. For documentation or to constrain ambiguous cases, explicit kind annotations:

```wok
class Functor (f : * -> *) = 
  { fmap : (a -> b) -> f a -> f b
  }

class Bifunctor (f : * -> * -> *) = 
  { bimap : (a -> c) -> (b -> d) -> f a b -> f c d
  }
```

The `(name : kind)` form annotates the kind. Kinds are `*` (concrete) or `K1 -> K2` (kind arrow). Effect kind `Effect` is added by the effects spec.

## Grammar additions

```bnfc
-- Top-level declarations:
DClass.       Decl ::= "class" ClassHead "=" "{" [ClassEntry] "}" ;
DInstance.    Decl ::= "instance" InstHead "=" "{" [InstEntry] "}" ;

-- Class head: optional superclass constraint + class name + parameters
ClassHead.    ClassHead ::= ClassParams ;
ClassHeadSup. ClassHead ::= "(" [Constraint] ")" "=>" ClassParams ;

ClassParams.  ClassParams ::= ConId [ClassParam] ;
ClassParam.   ClassParam ::= VarId ;                                    -- implicit kind
ClassParamK.  ClassParam ::= "(" VarId ":" Kind ")" ;                   -- explicit kind

-- Instance head: optional constraint + class name + type arguments
InstHead.     InstHead ::= InstParams ;
InstHeadSup.  InstHead ::= "(" [Constraint] ")" "=>" InstParams ;

InstParams.   InstParams ::= ConId [Type2] ;

-- Class entries: associated types, operation sigs, default methods
CETy.         ClassEntry ::= "type" ConId [VarId] ;                     -- associated type decl
CESig.        ClassEntry ::= VarId ":" Type ;                            -- operation sig
CEDefault.    ClassEntry ::= VarId [AtomPat] "=" Exp ;                  -- default method
separator     ClassEntry "," ;

-- Instance entries: associated type bindings + operation impls
IETy.         InstEntry ::= "type" ConId [Type2] "=" Type ;             -- type binding
IEImpl.       InstEntry ::= VarId [AtomPat] "=" Exp ;                   -- operation impl
separator     InstEntry "," ;

-- Constraint in a sig context: always parens
TConstrFun.   Type ::= "(" [Constraint] ")" "=>" Type ;

Constraint.   Constraint ::= ConId [Type2] ;
separator     Constraint "," ;

-- Kinds (existing; the explicit-kind form is new but the kind AST is already there):
KStar.        Kind ::= "*" ;
KEffect.      Kind ::= "Effect" ;
KArrow.       Kind ::= Kind "->" Kind ;
```

**Token additions:** `class` and `instance` are already reserved (`ReservedKw`). `=>` is a new compound token for the constraint arrow.

LALR(1) check: 
- `class` / `instance` keywords disambiguate top-level decl flavor.
- `=>` after `(...)` is unambiguous (no other production has parens followed by `=>` at type level).
- Class/instance bodies use the same `{ ... }` shape as `data` and `effect` decls; the parent decl keyword distinguishes.

## Type system additions

### Class environment

Add a new map to `Env`:

```haskell
data Env = Env
  { envVars   :: Map Text Scheme
  , envCons   :: Map Text ConInfo
  , envTyCons :: Map Text TyConInfo
  , envClasses :: Map Text ClassInfo          -- NEW
  , envInstances :: [InstanceInfo]            -- NEW (linear scan; small N)
  }

data ClassInfo = ClassInfo
  { ciParams      :: [(Text, Kind)]            -- e.g. [("a", KStar)] for class Eq a
  , ciSuperclasses :: [Constraint]             -- e.g. [Eq a] for class (Eq a) => Ord a
  , ciAssocTypes :: [(Text, [Text])]           -- (name, param-list) for associated types
  , ciOps        :: Map Text Scheme            -- operation name -> scheme
  , ciDefaults   :: Map Text Expr              -- default method bodies (raw AST)
  }

data InstanceInfo = InstanceInfo
  { iiClass     :: Text
  , iiTypes     :: [CType]                     -- instance type args, e.g. [Map k v] for instance ... Eq (Map k v)
  , iiContext   :: [Constraint]                -- instance-level constraints, e.g. (Eq a) for instance (Eq a) => Eq (Option a)
  , iiAssocBinds :: [(Text, [CType], CType)]   -- associated type bindings
  , iiOpImpls   :: Map Text Expr               -- operation implementations
  }
```

### Constraint solving

Type inference is extended to track constraints:

```haskell
data Constraint = Constraint
  { conClass :: Text
  , conArgs  :: [CType]
  }

-- Inference produces a (Scheme, [Constraint]) pair
-- Generalization adds constraints to the scheme's prefix:
--   forall a b. (Eq a, Show b) => a -> b -> String
```

Constraint resolution:
1. **At call site:** the typechecker collects constraints arising from operations and instance usage.
2. **At generalization:** unresolved constraints become part of the scheme's qualified type.
3. **At specific instantiation:** the typechecker discharges constraints by finding matching instances.

The constraint-solver is a worklist algorithm:
- Match constraint against `envInstances` to find applicable `InstanceInfo`.
- If found, replace the constraint with the instance's context (recursively).
- If none found, the constraint propagates up to be discharged later (or to be part of the binding's scheme).

**No backtracking** — coherence requires single-instance-per-(class, type-tuple); first match is the only match.

### Associated type resolution

When the typechecker encounters `Element c` in a type position:
1. Look up the class that has `Element` as an associated type → `Container`.
2. If `c` is a concrete type (e.g., `Map k v`), find the `Container (Map k v)` instance and look up its `type Element (Map k v) = v` binding → return `v`.
3. If `c` is a type variable still being constrained, defer: `Element c` becomes a *type-level skolem* parameterized by `c`. Constraint solving may later refine `c`.

Implementation: extend `CType` with a `CTAssoc Text [CType]` constructor (representing "associated type `name` applied to args"):

```haskell
data CType
  = CTCon TyCon [CType]
  | CTArr CType CRow CType
  | CTRecord CRow
  | CTAssoc Text [CType]                  -- NEW: associated type, resolved on demand
  | CTGen Int
```

`unify` handles `CTAssoc` by attempting resolution; if both sides are `CTAssoc` of the same name with same args (after `unify` of args), they unify trivially. Otherwise, attempt instance lookup.

### Default methods

When an instance is checked and a class operation is NOT provided in the instance body:
- The class's default method definition is used (if present).
- If neither the instance nor the class provides a definition, the constructor is rejected ("missing operation `eq` in instance Eq U64").

Default methods can reference other class operations:
```wok
class Eq a = 
  { eq : a -> a -> Bool
  , ne : a -> a -> Bool
  , ne x y = not (eq x y)                    -- references `eq`, which the instance must provide
  }
```

Implementation: at instance elaboration, walk the class's `ciOps`; for each operation not in the instance's `iiOpImpls`, copy the default from `ciDefaults`. If neither has it, raise an error.

### Operation invocation

`Container.lookup idx container` is parsed as `EProj (ECon "Container") (VarId "lookup")`. The typechecker:
1. Sees `Container` is a class name (in `envClasses`).
2. Resolves `Container.lookup` to a class operation.
3. Generates a constraint `Container c` where `c` is the type of `container`.
4. If the constraint can be discharged immediately (a matching instance exists), inlines/resolves the call. Otherwise, propagates the constraint up.

This reuses the existing `EProj` grammar; the class context is determined at typecheck time, not parse time. Same mechanism as the effects spec's `IO.read` operation invocations.

## Inference rules — sketch

### Constraint-collecting inference

The TC monad gains a constraints accumulator:

```haskell
data TCCtx s = TCCtx
  { tcEnv        :: Env
  , tcLevel      :: Level
  , tcUniqCounter :: STRef s Int
  , tcConstraints :: STRef s [Constraint]   -- NEW
  }
```

`inferExprW` extends:
- Class operation calls add constraints.
- Generalization promotes accumulated constraints into the scheme's prefix.

### Class-decl processing

In `inferProgramTC` (or a new `processClassDecls`):
```haskell
processClassDecl env (Abs.DClass head body) = do
  -- Translate class params and their kinds
  -- Translate operations (each is a Scheme parameterized by class params)
  -- Translate associated types (each is a name + parameter list)
  -- Translate default methods (store raw AST; check at instance time)
  let classInfo = ClassInfo { ... }
  pure (extendClass name classInfo env)
```

### Instance-decl processing

```haskell
processInstanceDecl env (Abs.DInstance head body) = do
  -- Translate instance head: (constraints) => ClassName type-args
  -- Check that ClassName exists in envClasses
  -- For each operation in the class, verify the instance provides an impl OR a default exists
  -- For each associated type in the class, verify the instance provides a binding
  -- Generate the InstanceInfo and add to envInstances
  pure (extendInstance instanceInfo env)
```

### Constraint solving at generalization

When `generalize` is called at let-binding finalization:
- Collect constraints accumulated during the binding's body.
- Discharge constraints if possible (find matching instances).
- Promote remaining constraints into the scheme's qualified prefix.
- The result: `forall ... . (...constraints...) => bodyType`.

## Test plan

| Test | Asserts |
| --- | --- |
| `parseClassDecl` | `class Eq a = { eq : a -> a -> Bool }` parses and round-trips |
| `parseInstanceDecl` | `instance Eq U64 = { eq = primEq }` parses |
| `parseMultiConstraint` | `(Eq a, Show a) => ...` parses; single `(Eq a) =>` also parses |
| `parseAssociatedType` | `type Element c` in class body parses |
| `parseHKT` | `class Functor f = { ... }` parses with implicit kind |
| `parseExplicitKind` | `class Functor (f : * -> *) = { ... }` parses |
| `typecheckSimpleClass` | `Eq U64` instance allows `eq 1 2` typecheck as `Bool` |
| `typecheckPolyClassMethod` | Using class operation in a generic context produces correct constraint |
| `typecheckAssociatedType` | `Container.lookup` returns `Option (Element c)`; resolves on concrete instance |
| `typecheckSuperclass` | `Ord a` use site requires `Eq a` to be discharged |
| `typecheckMissingInstance` | Calling `eq` on a type with no `Eq` instance produces a typed error |
| `typecheckDefaultMethod` | Class default method is used when instance omits the operation |
| `typecheckHKT` | `fmap` works on `Option a` and `[a]` for the inferred functor kind |
| `typecheckInstanceConstraint` | `instance (Eq a) => Eq (Option a) = ...` works; calling `eq` on `Option a` requires `Eq a` |

Golden tests:
- `19-typeclasses.wok` — basic Eq, Ord, Show classes
- `20-associated-types.wok` — Container with Element and Index
- `21-hkt-functor.wok` — Functor for Option and List
- `22-superclasses.wok` — Ord with Eq superclass

## File / module changes summary

| File | Action |
| --- | --- |
| `grammar/Wok.cf` | Add `DClass`, `DInstance`, class/instance heads, entries, constraint syntax in types |
| `src-generated/GeneratedParser/Wok/*` | Regenerate via BNFC |
| `src/Wok/TypeChecking/Types.hs` | Add `CTAssoc` constructor for associated types |
| `src/Wok/TypeChecking/Env.hs` | Add `envClasses` and `envInstances` to `Env`; add `ClassInfo`, `InstanceInfo` types |
| `src/Wok/TypeChecking/Infer.hs` | Class-decl processing, instance-decl processing, constraint collection, instance resolution, default-method elaboration |
| `src/Wok/TypeChecking/Unify.hs` | Handle `CTAssoc` in unification |
| `src/Wok/TypeChecking/Monad.hs` | Add constraint accumulator to TCCtx |
| `prelude/Std/Base.wok` | Add common classes: `Show`, `Eq`, `Ord` (basic), maybe `Functor` |
| `test/typecheck-examples/` | New golden tests per plan |
| `test/Spec.hs` | Class/instance unit tests |
| `examples/typeclasses-tour.wok` | New example file |

## Open hooks for future specs

1. **Algebraic effects** (`2026-05-27-effects-spec.md`) — classes can declare associated effect rows (`type SaveEffects p`), enabling effect-polymorphic interfaces.
2. **Constraint kinds** — first-class `Constraint` kind would let users define constraint synonyms.
3. **GADTs / existentials** — would need separate machinery but classes can be a discriminator.
4. **Newtype-style records** — orthogonal feature; classes work on any record type without special accommodation.

## Why mandatory parens for constraints

Why require `(Eq a) =>` instead of allowing `Eq a =>`?

**At-first-glance unambiguity.** Without parens, a sig like:

```wok
example : Container c, Eq (Element c) => Index c -> c -> Bool
```

reads ambiguously to a left-to-right scanner: the eye sees `Container c`, then `,`, then `Eq (Element c)` — could be a tuple type (`(Container c, Eq (Element c))` as a 2-element tuple type) UNTIL it hits `=>`. Then the brain must backtrack.

With mandatory parens:

```wok
example : (Container c, Eq (Element c)) => Index c -> c -> Bool
```

The opening `(` immediately signals: "this is a constraint context." No backtrack.

The cost is one extra pair of characters per constrained sig. For consistency, single-constraint sigs use parens too:

```wok
showLine : (Show a) => a -> () with IO
```

Uniform rule: constraints are always parenthesized.

## Composition with records and effects

The complete picture, combining typeclasses, records, and effects in one sig:

```wok
processItem 
  : ( Container c
    , Eq (Element c)
    , Persistent (Element c)
    )
  => Index c 
  -> c 
  -> Bool 
  with SaveEffects (Element c) + IO + Logger + e
```

- **Constraints** in parens before `=>`.
- **Associated types** (`Element c`, `SaveEffects (Element c)`) as function-application style.
- **Record types** (`c`, `Index c`) as nominal references.
- **Effects** after `with`, with `+` for composition and `e` as the row variable.

All four positions have distinct syntactic roles. No overload.

## Pedagogical placement

For Wok's documentation:
- **Pre-class users** can write everyday code without classes. Plain functions work for monomorphic code.
- **Light class use** (`(Show a) =>`) is the common case; one constraint, one operation.
- **Multi-class + associated-type** code is for library authors and advanced patterns. Common in standard-library design.
- **HKT (Functor, Applicative)** is opt-in expressiveness for those who want it. Wok doesn't force monad-style programming on anyone.

The pedagogical rule: classes are a tool for library design, not a daily-use feature for application code. Most user code reads cleanly without them.
