# History

wok is a research language with algebraic effects, a Perceus reference-counting runtime,
and no garbage collector. This file is the narrative of how it was built, from the first
grammar to the current front end.

The history below is a rebuild. The original development ran to 1046 commits; each entry
here is one epic, squashed from the commits that made it up, and every epic commit reuses
the exact tree the repository had when that epic finished. The individual commit subjects
are preserved in each commit message, so nothing is lost -- run `git log` for the detail.

Entries marked **breaking** changed the language surface, the prelude, or the CLI in a way
that required existing `.wok` code to change; the commit message states the migration.



## May 2026

### bootstrap the toolchain and the v1 BNFC grammar

`chore` &middot; 2026-05-20 to 2026-05-21 &middot; 27 commits &middot; `02edf8f14`

Stands the project up: a BNFC grammar for the surface language, a happy/alex
toolchain, the `wok` executable, and a golden-AST test corpus. The grammar covers
literals, declarations, application, operator chains, lambda/let/case/if, patterns,
type expressions, where clauses, and layout-sensitive blocks.

Spec: [`2026-05-20-bnfc-wok-grammar-design.md`](docs/superpowers/specs/2026-05-20-bnfc-wok-grammar-design.md)

### v2 module syntax and the ConId/VarId split

`feat(grammar)` &middot; 2026-05-21 &middot; 10 commits &middot; `47532f6fd`  **breaking**

Splits the single identifier token into ConId and VarId, which lets the grammar tell
constructors from variables without semantic feedback, and adds the module header,
imports, and qualified projection.

> Breaking: Identifiers are now lexed as ConId or VarId by leading case. Sources that used a lowercase constructor name or an uppercase variable name no longer parse.

Spec: [`2026-05-21-module-syntax-conid-split-design.md`](docs/superpowers/specs/2026-05-21-module-syntax-conid-split-design.md)

### Hindley-Milner core typechecker

`feat(typecheck)` &middot; 2026-05-25 &middot; 30 commits &middot; `65936baa7`

A complete Hindley-Milner core: unification with row support, generalize/instantiate,
data declarations, pattern and expression inference, and a three-pass top-level walk.
User signatures are skolemized so a declaration cannot over-promise.

Spec: [`2026-05-25-hm-core-design.md`](docs/superpowers/specs/2026-05-25-hm-core-design.md)

### Std.Base prelude, the module loader, and U64

`feat(prelude)` &middot; 2026-05-26 &middot; 29 commits &middot; `128283472`  **breaking**

Moves the built-ins out of the compiler and into a real prelude module. Adds the module
loader (dependency graph, topological sort, whole-program view), the `Std.Base` embedded
prelude, environment overlay, and the unit literal.

> Breaking: The compiler no longer supplies built-ins implicitly; programs must import `Std.Base`. The integer type is renamed to `U64` at the surface.

Spec: [`2026-05-26-include-path-and-stdbase-design.md`](docs/superpowers/specs/2026-05-26-include-path-and-stdbase-design.md), [`2026-05-26-unit-literal-design.md`](docs/superpowers/specs/2026-05-26-unit-literal-design.md)

### row-polymorphic records

`feat(records)` &middot; 2026-05-26 to 2026-05-27 &middot; 19 commits &middot; `801365eb3`

Row-polymorphic records on Leijen's 2005 unifier: record construction with spread,
field access, strict/open/wild patterns, row-shadow warnings, and a brace-context layout
stack for block-form literals.

Spec: [`2026-05-26-row-polymorphic-records-design.md`](docs/superpowers/specs/2026-05-26-row-polymorphic-records-design.md), [`2026-05-27-effects-spec.md`](docs/superpowers/specs/2026-05-27-effects-spec.md), [`2026-05-27-records-spec.md`](docs/superpowers/specs/2026-05-27-records-spec.md), [`2026-05-27-typeclasses-spec.md`](docs/superpowers/specs/2026-05-27-typeclasses-spec.md)

### algebraic effects v1 -- declarations, rows, handlers

`feat(effects)` &middot; 2026-05-31 to 2026-06-03 &middot; 21 commits &middot; `f84c50a3d`

The first algebraic effects: `effect` declarations, effect rows on arrows, operation
calls that thread their row, and handlers. An operation used outside its declared row is
reported as an undischarged effect.

Spec: [`2026-05-31-algebraic-effects-v1-surface-design.md`](docs/superpowers/specs/2026-05-31-algebraic-effects-v1-surface-design.md)


## June 2026

### ANF intermediate representation and elaboration

`feat(ir)` &middot; 2026-06-03 &middot; 14 commits &middot; `20db8cc84`

A-normal form with join points, plus the elaborator that lowers the surface AST into it:
pattern compilation, record forms, constructor saturation, effect operations and handlers,
and a deterministic pretty-printer behind `wok --dump-anf`.

### the ANF CEK interpreter

`feat(interp)` &middot; 2026-06-03 &middot; 13 commits &middot; `14ab098a9`

A CEK machine over the ANF: runtime values, an environment, a primitive table, currying,
join points, and deep multi-shot effect dispatch. Whole-program elaboration lets calls
cross module boundaries.

### typed core -- elaboration from a typed AST

`feat(types)` &middot; 2026-06-04 &middot; 14 commits &middot; `84c10d07e`

Reworks inference to build a typed tree as it goes, so elaboration reads types off the
nodes instead of re-deriving them. Binders carry a real type from here on, which is what
later dictionary passing and the RC analyses depend on.

Spec: [`2026-06-04-typed-core-design.md`](docs/superpowers/specs/2026-06-04-typed-core-design.md)

### Eq type class by dictionary passing

`feat(types)` &middot; 2026-06-04 &middot; 22 commits &middot; `c4bac2e5a`

Single-parameter type classes by dictionary passing, with dictionaries as ordinary data
constructors. Adds constraint accumulation, a pure constraint solver, evidence parameters,
and `Eq` instances in the prelude.

Spec: [`2026-06-04-eq-typeclass-slice-design.md`](docs/superpowers/specs/2026-06-04-eq-typeclass-slice-design.md)

### multi-clause functions via a decision-tree match compiler

`feat(ir)` &middot; 2026-06-05 &middot; 13 commits &middot; `3fcbd30a6`

Top-level multi-clause definitions compile to decision trees, with exhaustiveness and
redundancy analysis over the clause matrix. The column heuristic is deliberately the
leftmost constructor rather than Maranget scoring -- simple, and good enough here.

Spec: [`2026-06-05-multi-clause-match-compiler-design.md`](docs/superpowers/specs/2026-06-05-multi-clause-match-compiler-design.md)

### slice 1 -- with-prefix handlers and free resume

`feat(effects)` &middot; 2026-06-05 &middot; 9 commits &middot; `fc7201880`  **breaking**

Reshapes handler syntax around a `with` prefix and makes `resume` a free variable in the
arm body rather than a keyword, with a value arm for the return case.

> Breaking: Handlers are written with a `with` prefix; the `handle` and `return` keywords are gone, and `resume` is an ordinary variable bound by the arm rather than a keyword.

Spec: [`2026-06-05-effect-handler-surface-syntax.md`](docs/superpowers/specs/2026-06-05-effect-handler-surface-syntax.md), [`2026-06-05-effect-handlers-ROADMAP.md`](docs/superpowers/specs/2026-06-05-effect-handlers-ROADMAP.md), [`2026-06-05-effect-handlers-unified-case-design.md`](docs/superpowers/specs/2026-06-05-effect-handlers-unified-case-design.md)

### slice 2 -- effect headers, Never, and the forgotten-resume lint

`feat(effects)` &middot; 2026-06-05 &middot; 10 commits &middot; `c7dedf62b`  **breaking**

Adds an optional effect header that states the coverage contract, the `Never` bottom type
with perform-site bottom elimination, and a lint for arms that forget to resume.

> Breaking: `Exn` is replaced by `Never`. Handler arms that neither resume nor diverge are now reported by the forgotten-resume lint.

Spec: [`2026-06-05-effects-slice-2-design.md`](docs/superpowers/specs/2026-06-05-effects-slice-2-design.md)

### slice 3 -- bounded handlers and the delimiter fix

`feat(effects)` &middot; 2026-06-06 &middot; 12 commits &middot; `464d0ea14`

Bounded handlers -- `(with H e)` delimits the handler to one expression. The substance is
the delimiter fix underneath: a non-tail resume now rebinds the answer join, so the
continuation is genuinely delimited.

Spec: [`2026-06-06-effects-slice-3-bounded-handlers-design.md`](docs/superpowers/specs/2026-06-06-effects-slice-3-bounded-handlers-design.md)

### slice 4a -- parameterized handlers and Std.Control

`feat(effects)` &middot; 2026-06-07 &middot; 20 commits &middot; `142475fef`  **breaking**

Handlers carry state as a baton threaded through a two-argument resume, with `with ... in`
sugar for the runner form. Ships the mtl quartet as a second embedded prelude, plus tuple
destructuring in let.

> Breaking: The mtl prelude moves from `Control.Wok` to `Std.Control`, and the eval/exec variants are dropped.

Spec: [`2026-06-07-effects-slice-4a-parameterized-handlers-design.md`](docs/superpowers/specs/2026-06-07-effects-slice-4a-parameterized-handlers-design.md)

### as-patterns via the `as` keyword

`feat(patterns)` &middot; 2026-06-07 to 2026-06-08 &middot; 13 commits &middot; `7f3bb5377`

As-patterns spelled `pat as name`, deliberately not `pat@name` -- `@` is reserved for
future visible type application. Works in both single-alt and multi-clause heads.

Spec: [`2026-06-07-tagged-effects-as-patterns-num.md`](docs/superpowers/specs/2026-06-07-tagged-effects-as-patterns-num.md), [`2026-06-07-as-patterns-design.md`](docs/superpowers/specs/2026-06-07-as-patterns-design.md)

### named effect instances

`feat(effects)` &middot; 2026-06-08 &middot; 18 commits &middot; `22d7c7bb6`

Multiple instances of the same effect in one scope, distinguished by name rather than by
a type-level tag: `with count = state 0 in`, then `count.get`. The handle type is the
effect, and the dot is resolved by type.

Spec: [`2026-06-08-named-capabilities-design.md`](docs/superpowers/specs/2026-06-08-named-capabilities-design.md), [`2026-06-08-named-effect-instances-design.md`](docs/superpowers/specs/2026-06-08-named-effect-instances-design.md)

### one-shot multiplicity -- affine no-dup on continuations

`feat(effects)` &middot; 2026-06-09 &middot; 11 commits &middot; `6ef479df6`  **breaking**

Continuation binders become affine -- a continuation cannot be duplicated, so a genuinely
multi-shot handler is a compile error rather than a runtime surprise. One-shot is the law
the rest of the runtime work is built on.

> Breaking: A continuation binder is affine. A handler that resumes more than once, previously a runtime behaviour, is now a compile error.

Spec: [`2026-06-09-one-shot-multiplicity-analysis-design.md`](docs/superpowers/specs/2026-06-09-one-shot-multiplicity-analysis-design.md)

### slice 4b -- one-shot escaping continuations and extern

`feat(effects)` &middot; 2026-06-09 &middot; 16 commits &middot; `cbca34222`

A continuation may escape its handler, as an opaque second-class affine value, with
`start`/`value`/`resume`/`cancel`. Adds `extern` declarations so the prelude can name
types the compiler provides.

Spec: [`2026-06-09-one-shot-escape-design.md`](docs/superpowers/specs/2026-06-09-one-shot-escape-design.md)

### slice 4b' -- the step pull-generator combinator

`feat(effects)` &middot; 2026-06-09 to 2026-06-10 &middot; 10 commits &middot; `b53924ab3`  **breaking**

`step` as an ordinary library function rather than syntax -- pull one value from a
suspended computation and get the rest back.

Spec: [`2026-06-09-slice-4b-dprime-residual-row-future-design.md`](docs/superpowers/specs/2026-06-09-slice-4b-dprime-residual-row-future-design.md), [`2026-06-09-slice-4b-prime-chaining-generators-design.md`](docs/superpowers/specs/2026-06-09-slice-4b-prime-chaining-generators-design.md)

### slice 4c -- the closed Step ADT and suspend-family naming

`feat(effects)` &middot; 2026-06-10 &middot; 10 commits &middot; `ddf988307`  **breaking**

Replaces the ad-hoc suspension protocol with a closed ADT that ordinary `case` can scrutinise,
which is what makes zipping two generators type-check.

> Breaking: `Future` is renamed to `Suspension` and `resume` to `run`. Suspension results are scrutinised through the closed `Step` ADT instead of the previous accessors.

Spec: [`2026-06-10-slice-4c-step-adt-suspend-naming-design.md`](docs/superpowers/specs/2026-06-10-slice-4c-step-adt-suspend-naming-design.md)

### slice 4d -- coroutine types as extern declarations

`feat(effects)` &middot; 2026-06-10 &middot; 9 commits &middot; `822462e0d`

The coroutine types move out of the compiler and into prelude `extern` declarations, with
the carrier marker threaded through the analyses so they trust the declaration rather than
a name string.

Spec: [`2026-06-10-coroutine-types-extern-decl-design.md`](docs/superpowers/specs/2026-06-10-coroutine-types-extern-decl-design.md)

### one kinded type representation, merging CType and CRow

`refactor(types)` &middot; 2026-06-10 &middot; 5 commits &middot; `eac9c2ced`

Collapses the separate type and row representations into one kinded type. Types and rows
stop being two parallel worlds, which is the prerequisite for row-kinded parameters.

Spec: [`2026-06-10-kinded-type-representation-design.md`](docs/superpowers/specs/2026-06-10-kinded-type-representation-design.md)

### row-kinded type-constructor parameters

`feat(types)` &middot; 2026-06-10 &middot; 6 commits &middot; `cf44ae853`

Type constructors can take a row-kinded parameter, written `(row e)`, with kind checking on
tycon applications.

Spec: [`2026-06-10-slice-b-row-kinded-params-design.md`](docs/superpowers/specs/2026-06-10-slice-b-row-kinded-params-design.md)

### slice 4b" -- the residual effect row on Suspension and Step

`feat(effects)` &middot; 2026-06-10 to 2026-06-11 &middot; 9 commits &middot; `1b440807d`  **breaking**

Suspension and Step gain a residual effect row, so resuming a suspended computation has to
account for the effects of its tail instead of laundering them away.

> Breaking: Suspension and Step take a residual effect row parameter. Code that resumes a suspension must now account for the effects of its tail.

Spec: [`2026-06-10-slice-4b-dprime-residual-row-on-kinded-ty-design.md`](docs/superpowers/specs/2026-06-10-slice-4b-dprime-residual-row-on-kinded-ty-design.md)

### the Async effect and deterministic par

`feat(async)` &middot; 2026-06-11 &middot; 10 commits &middot; `b731dbaa7`

An Async effect and a deterministic `par`, built as a pure library over the coroutine CPS
rather than as runtime threads. Structured concurrency: children cannot outlive their scope.

Spec: [`2026-06-11-async-effect-surface-and-cps-design.md`](docs/superpowers/specs/2026-06-11-async-effect-surface-and-cps-design.md), [`2026-06-11-resume-site-control-and-heap-continuations-design.md`](docs/superpowers/specs/2026-06-11-resume-site-control-and-heap-continuations-design.md)

### report row-unification mismatch as RowMismatch

`fix(diag)` &middot; 2026-06-11 &middot; 2 commits &middot; `e6dcf9bad`

Row unification failures were surfacing as an UnknownField placeholder; they now report as
what they are.

### race and cooperative cancellation

`feat(async)` &middot; 2026-06-11 &middot; 5 commits &middot; `92e075e1c`

`race` with cooperative cancellation, where cancelling is just dropping the loser.

### race becomes a neutral combinator

`refactor(async)` &middot; 2026-06-11 &middot; 4 commits &middot; `f85e0d80c`  **breaking**

Drops Nondet/Choice/runDet in favour of `race` as a first-wins, left-biased-on-ties
combinator. Determinism is not tracked in the type system, because it is not enforceable
there.

> Breaking: `Nondet`, `Choice`, and `runDet` are removed. Use `race`, which takes the first result and is left-biased on ties.

### position row-mismatch errors and dedup RowShadow

`fix(diag)` &middot; 2026-06-11 &middot; 2 commits &middot; `5ad45925f`

Row-mismatch errors get source positions, and RowShadow warnings dedup by content.

### inter-procedural one-shot inference

`feat(effects)` &middot; 2026-06-11 &middot; 3 commits &middot; `6312ed589`

One-shot inference crosses function boundaries instead of stopping at them, without
losing soundness.

### the Conc surface and a deterministic scheduler

`feat(conc)` &middot; 2026-06-12 &middot; 19 commits &middot; `c278f971d`

A concurrency surface (Conc, Fiber, Transport) over a deterministic interpreter scheduler,
so concurrent programs have reproducible interleavings under test.

Spec: [`2026-06-12-slice-3-runtime-provided-concurrency-design.md`](docs/superpowers/specs/2026-06-12-slice-3-runtime-provided-concurrency-design.md)

### the repo-review backlog -- fourteen findings closed

`fix` &middot; 2026-06-12 &middot; 9 commits &middot; `6de001759`

Closes all fourteen findings from a full-repo review: an elaboration scope leak, a carrier
escape, a row-unification hang, and a rigidUnify panic among them.

### cross-scheduler handle identity

`fix(conc)` &middot; 2026-06-13 &middot; 16 commits &middot; `19cc941ef`

Handle identities were per-scheduler and could collide across schedulers. They become flat
global ids from a machine-threaded supply, with per-entry CAF regions.

Spec: [`2026-06-13-conc-handle-identity-design.md`](docs/superpowers/specs/2026-06-13-conc-handle-identity-design.md)

### Perceus M1 -- the RC store interpreter and dup/drop pass

`feat(rc)` &middot; 2026-06-14 &middot; 38 commits &middot; `ca0529d18`

Perceus reference counting: an explicit RC store, a static dup/drop insertion pass, and a
differential oracle that checks the counted interpreter against the reference one. No
collector -- reclamation is precise and immediate.

Spec: [`2026-06-14-perceus-interpreter-static-analysis-design.md`](docs/superpowers/specs/2026-06-14-perceus-interpreter-static-analysis-design.md), [`2026-06-14-rc-join-property-generator-design.md`](docs/superpowers/specs/2026-06-14-rc-join-property-generator-design.md)

### M1.5 -- closures and LetRec enclosing capture

`feat(rc)` &middot; 2026-06-14 to 2026-06-15 &middot; 15 commits &middot; `da44f9ac4`

Extends RC to closures and to LetRec groups that capture from an enclosing scope.

Spec: [`2026-06-14-m1.5-closures-perceus-design.md`](docs/superpowers/specs/2026-06-14-m1.5-closures-perceus-design.md)

### M2a -- shared-env recursive closures and one escape source

`feat(rc)` &middot; 2026-06-15 to 2026-06-16 &middot; 47 commits &middot; `a68c5eaa8`

Escaping recursive closures use a shared environment plus a code pointer, following Koka.
Also consolidates escape analysis into a single source of truth, which the review round
showed was where the double-free was hiding.

Spec: [`2026-06-15-m2-continuation-aware-drop-design.md`](docs/superpowers/specs/2026-06-15-m2-continuation-aware-drop-design.md), [`2026-06-15-m2a-2-shared-env-recursive-closures-design.md`](docs/superpowers/specs/2026-06-15-m2a-2-shared-env-recursive-closures-design.md), [`2026-06-15-m2a-2-shared-env-recursive-closures-reasoning.md`](docs/superpowers/specs/2026-06-15-m2a-2-shared-env-recursive-closures-reasoning.md)

### M2b-1 -- counted handler frames and the continuation owned set

`feat(rc)` &middot; 2026-06-17 &middot; 18 commits &middot; `ce3eef3ac`

Reference counting reaches handler frames: frames are counted, and a continuation owns a
set of values that is freed exactly once on abort and moved out on tail resume.

Spec: [`2026-06-17-m2b-continuations-effects-rc-design.md`](docs/superpowers/specs/2026-06-17-m2b-continuations-effects-rc-design.md)

### M2b-2 -- parameterized handlers and value position

`feat(rc)` &middot; 2026-06-17 to 2026-06-18 &middot; 16 commits &middot; `37436af7c`

Extends the RC handler fragment to parameterized handlers -- the baton is owned by Perceus
and re-installed on a two-argument resume -- and to handlers in value position.

Spec: [`2026-06-17-m2b-2-parameterized-handlers-design.md`](docs/superpowers/specs/2026-06-17-m2b-2-parameterized-handlers-design.md)

### M3 -- stored and escaping continuations on the RC store

`feat(rc)` &middot; 2026-06-18 to 2026-06-19 &middot; 19 commits &middot; `eacf04964`

Continuations can be stored, taken, and resumed on the RC store. Cycles are prevented
rather than collected: a carrier wall rejects the programs that could build one.

Spec: [`2026-06-18-m3-stored-continuations-design.md`](docs/superpowers/specs/2026-06-18-m3-stored-continuations-design.md)

### the resume-binder-type RC leak

`fix(rc)` &middot; 2026-06-19 &middot; 9 commits &middot; `906062f83`

The resume binder was typed as the answer, not as the continuation, which leaked whenever
the answer type was unboxed. It is now `T -> R`.

Spec: [`2026-06-19-m2b-resume-binder-type-leak-fix-design.md`](docs/superpowers/specs/2026-06-19-m2b-resume-binder-type-leak-fix-design.md)

### value-position handlers are no longer flagged multishot

`fix(multiplicity)` &middot; 2026-06-19 &middot; 3 commits &middot; `742d8be3e`

One-shot analysis was marking every value-position arm as multi-shot. Seeding the join
environment with the answer join fixes it without weakening the genuine multi-shot error.

Spec: [`2026-06-19-value-position-multishot-false-positive-design.md`](docs/superpowers/specs/2026-06-19-value-position-multishot-false-positive-design.md)

### APrim (Module,Name) identity and positioned diagnostics

`feat(ir)` &middot; 2026-06-19 to 2026-06-21 &middot; 14 commits &middot; `f25c98de3`

Primitives get a single `(Module, Name)` identity instead of a separate Unique layer, and
type mismatches in if/list/case positions get real source spans.

Spec: [`2026-06-19-backlog-12-13-design.md`](docs/superpowers/specs/2026-06-19-backlog-12-13-design.md)

### a real C heap for constructor cells

`feat(rt)` &middot; 2026-06-21 &middot; 14 commits &middot; `7004a9136`

Constructor cells move onto a C heap over FFI, with Haskell still driving the drop cascade.
Both backends run under a differential oracle that compares output and allocation stats.

Spec: [`2026-06-21-c-runtime-allocator-ncon-design.md`](docs/superpowers/specs/2026-06-21-c-runtime-allocator-ncon-design.md)

### the slab arena allocator

`perf(rt)` &middot; 2026-06-21 &middot; 7 commits &middot; `74bd32a1c`

Replaces plain malloc with a bump allocator plus arity-exact LIFO free lists and O(slabs)
teardown, behind an unchanged ABI. About four times faster; malloc stays available behind
a flag.

Spec: [`2026-06-21-c-runtime-arena-allocator-design.md`](docs/superpowers/specs/2026-06-21-c-runtime-arena-allocator-design.md)

### layout compaction -- an 8-byte header and descriptor-driven slots

`perf(rt)` &middot; 2026-06-22 &middot; 8 commits &middot; `5f33acb2a`

Shrinks the cell to an 8-byte header plus descriptor-driven slots -- roughly half the
previous size -- with a first-kind-wins per-tag descriptor and a fallback on mismatch.

Spec: [`2026-06-22-layout-compaction-design.md`](docs/superpowers/specs/2026-06-22-layout-compaction-design.md)

### nullary constructors as inline immediates

`perf(rt)` &middot; 2026-06-22 to 2026-06-23 &middot; 11 commits &middot; `a0b6a99af`

Nullary constructors stop allocating: they become an interned tag inline in the address,
intercepted at alloc and deref. Halves allocation on tree-shaped workloads.

Spec: [`2026-06-22-layout-compaction-slice2-design.md`](docs/superpowers/specs/2026-06-22-layout-compaction-slice2-design.md)

### FBIP -- in-place reuse for map and reverse

`feat(rc)` &middot; 2026-06-23 &middot; 11 commits &middot; `653d17f14`

Functional but in-place -- when a cell is uniquely owned, map and reverse reuse it instead
of allocating. Restricted to same-constructor reuse, since cross-constructor reuse is
unsound here.

Spec: [`2026-06-23-fbip-reuse-design.md`](docs/superpowers/specs/2026-06-23-fbip-reuse-design.md)

### FBIP effect safety -- reservations reclaimed on abort

`fix(rc)` &middot; 2026-06-23 &middot; 8 commits &middot; `bdc4f0f4d`

An in-flight reservation set, reclaimed when a continuation aborts, so reuse stays sound in
the presence of effects.

Spec: [`2026-06-23-fbip-effect-safety-design.md`](docs/superpowers/specs/2026-06-23-fbip-effect-safety-design.md)

### Array Slice A -- the boxed array type

`feat(array)` &middot; 2026-06-24 &middot; 1 commits &middot; `22bc1e12d`

A boxed `Array a` -- Koka's vector -- with seven primitives, a `Std.Array` module, and
oracle coverage. `set` copies for now.

### Array Slice B -- Array on a real C cell

`feat(array)` &middot; 2026-06-24 &middot; 17 commits &middot; `a152f4064`

Array moves onto a real C cell with a unified byte-size class, and peak bytes is elevated
to a shared oracle invariant.

Spec: [`2026-06-24-array-slice-b-c-cell-design.md`](docs/superpowers/specs/2026-06-24-array-slice-b-c-cell-design.md)

### Array Slice C -- in-place set under rc==1

`perf(array)` &middot; 2026-06-24 &middot; 10 commits &middot; `74d488749`

`Array.set` mutates in place when the array is uniquely owned, reusing the FBIP rc==1 gate,
for zero allocation on the common accumulate loop.

Spec: [`2026-06-24-array-slice-c-inplace-set-design.md`](docs/superpowers/specs/2026-06-24-array-slice-c-inplace-set-design.md)

### Region Slice R1 -- inferred function-local arenas

`feat(region)` &middot; 2026-06-25 &middot; 23 commits &middot; `737327636`

Function-local values that provably do not escape are allocated in an uncounted
per-activation arena, inferred rather than declared. The routing is an IR annotation, so it
is backend-agnostic.

Spec: [`2026-06-25-region-slice-r1-design.md`](docs/superpowers/specs/2026-06-25-region-slice-r1-design.md), [`2026-06-25-region-slice-r1-gist.md`](docs/superpowers/specs/2026-06-25-region-slice-r1-gist.md)

### String Slice E1 -- String as flat UTF-8 bytes on a C cell

`feat(string)` &middot; 2026-06-25 to 2026-06-26 &middot; 12 commits &middot; `4d68bb284`  **breaking**

String becomes flat UTF-8 bytes on a C cell -- Unicode-first, valid-only, counted and boxed
-- rather than a list of characters.

> Breaking: String is a counted, boxed, heap-only value of flat UTF-8 bytes. It is no longer a list of characters, and list operations no longer apply to it.

Spec: [`2026-06-25-string-slice-e1-design.md`](docs/superpowers/specs/2026-06-25-string-slice-e1-design.md)

### String Slice E2 -- StringZilla search and hashing

`feat(string)` &middot; 2026-06-26 &middot; 8 commits &middot; `5a5a0ddaa`

Vendors StringZilla for search and hashing, and dogfoods indexOf/contains/count in the
prelude on top of the new primitives.

Spec: [`2026-06-26-string-slice-e2-design.md`](docs/superpowers/specs/2026-06-26-string-slice-e2-design.md)

### String Slice E3 -- small-string optimisation

`perf(string)` &middot; 2026-06-26 &middot; 9 commits &middot; `c9330318f`

Strings of seven bytes or fewer live inline in the address with no cell at all, packed into
an eleven-class slot sub-tag.

Spec: [`2026-06-26-string-slice-e3-design.md`](docs/superpowers/specs/2026-06-26-string-slice-e3-design.md)

### String Slice E4 -- zero-copy views and borrow passing

`feat(string)` &middot; 2026-06-26 to 2026-06-27 &middot; 15 commits &middot; `0dff60a7c`

Slicing returns a zero-copy view over the original bytes, with the escape and region
analyses routing views so a view cannot outlive what it points at.

Spec: [`2026-06-26-string-slice-e4-design.md`](docs/superpowers/specs/2026-06-26-string-slice-e4-design.md)

### String Slice E5 -- codepoint iteration

`feat(string)` &middot; 2026-06-27 to 2026-06-28 &middot; 10 commits &middot; `090c41b7b`

Codepoint-level iteration over the flat bytes: decode, width, singleton, and foldChars,
with a death test pinning the interaction with one-shot resume.

Spec: [`2026-06-27-string-slice-e5-design.md`](docs/superpowers/specs/2026-06-27-string-slice-e5-design.md)

### Slice E6 -- Bytes and validated String construction

`feat(bytes)` &middot; 2026-06-28 &middot; 12 commits &middot; `2b5118817`

A `Bytes` type for unvalidated input and a validated construction path into String, using a
Hoehrmann DFA validator in C with a Haskell reference to agree against.

Spec: [`2026-06-28-string-slice-e6-bytes-design.md`](docs/superpowers/specs/2026-06-28-string-slice-e6-bytes-design.md)

### FFI Slice 1 -- the C-to-RC bytes handoff

`feat(ffi)` &middot; 2026-06-29 &middot; 9 commits &middot; `14ac85a23`

Bytes produced in C can enter the RC world either by copy or by adoption, where adoption
takes ownership and frees through libc at rc zero. Copy versus adopt is a declared contract,
not a guess.

Spec: [`2026-06-28-ffi-bytes-in-design.md`](docs/superpowers/specs/2026-06-28-ffi-bytes-in-design.md)

### FFI Slice 2 -- the foreign-module surface

`feat(ffi)` &middot; 2026-06-29 to 2026-06-30 &middot; 22 commits &middot; `1ec2f7265`

`foreign module Libc "c" ... where ...` as a real declaration form, with a new IO ground
effect and a GObject-style transfer model for ownership.

Spec: [`2026-06-29-ffi-slice2-foreign-module-design.md`](docs/superpowers/specs/2026-06-29-ffi-slice2-foreign-module-design.md)


## July 2026

### FFI Slice 3 -- the foreign borrow tier

`feat(ffi)` &middot; 2026-07-01 &middot; 19 commits &middot; `43b72b654`

Transfer-none reads become a second-class, non-affine `Borrow` that cannot be laundered
into a first-class value, closed at end of activation, with `Bytes.copy` as the escape
hatch.

Spec: [`2026-07-01-ffi-slice3-borrow-in-design.md`](docs/superpowers/specs/2026-07-01-ffi-slice3-borrow-in-design.md)

### FFI Slice 4 -- owned-into-C move-out

`feat(ffi)` &middot; 2026-07-01 to 2026-07-02 &middot; 23 commits &middot; `7d53cf2e0`

A parameter marked `owned` transfers ownership into C, routed by an rc==1 move-or-copy
decision, with the dispatch site as the sole dropper. Verified by QuickCheck properties and
an ASan death matrix.

Spec: [`2026-07-01-ffi-slice4-owned-into-c-design.md`](docs/superpowers/specs/2026-07-01-ffi-slice4-owned-into-c-design.md)

### `var` handler state and block-scope arm bodies

`feat(handler)` &middot; 2026-07-02 &middot; 9 commits &middot; `fb1256153`  **breaking**

Handler state must now be introduced with `var`, which makes the baton visible at the
binding site, and arm bodies may span lines under a column-aware block scope.

> Breaking: Handler state must be written `var name = init`. The bare `name = init` form is rejected.

Spec: [`2026-07-02-handler-block-var-and-block-scope-design.md`](docs/superpowers/specs/2026-07-02-handler-block-var-and-block-scope-design.md)

### runConc drops its phantom residual row

`fix(conc)` &middot; 2026-07-02 &middot; 5 commits &middot; `9d35c360f`  **breaking**

runConc carried a phantom residual row that silently absorbed outer effects. Tightening its
type turns that into a compile-time row mismatch.

> Breaking: runConc is typed `(() -> a with Conc) -> a`. A body carrying effects other than Conc, which the phantom row previously absorbed, is now a row mismatch.

Spec: [`2026-07-02-resume-launders-effect-row-explicitness-decision.md`](docs/superpowers/specs/2026-07-02-resume-launders-effect-row-explicitness-decision.md)

### the load-bearing residual effect row

`feat(effects)` &middot; 2026-07-02 &middot; 8 commits &middot; `b1f9d5099`  **breaking**

The residual effect row becomes load-bearing rather than decorative: a driver that consumes
a residual must declare it, and the exemption narrows to row identity so an arm body cannot
launder effects away.

> Breaking: A function that consumes a residual effect row must declare it with `with eff e`. The previous implicit exemption no longer applies.

Spec: [`2026-07-02-resume-launders-effect-row-loadbearing-GIST.md`](docs/superpowers/specs/2026-07-02-resume-launders-effect-row-loadbearing-GIST.md), [`2026-07-02-resume-launders-effect-row-loadbearing-spec.md`](docs/superpowers/specs/2026-07-02-resume-launders-effect-row-loadbearing-spec.md), [`2026-07-02-resume-launders-rung2-provenance.md`](docs/superpowers/specs/2026-07-02-resume-launders-rung2-provenance.md)

### rung 2 -- caller-root residual provenance

`feat(effects)` &middot; 2026-07-03 &middot; 8 commits &middot; `31cb1fce4`  **breaking**

Residual provenance is tracked to the caller root, which retires the previous
exempt-by-identity rule and closes the handler-position leaks.

Spec: [`2026-07-03-resume-launders-rung2-caller-root-provenance-design.md`](docs/superpowers/specs/2026-07-03-resume-launders-rung2-caller-root-provenance-design.md)

### scoped rigid skolemization of trapped effect vars

`feat(effects)` &middot; 2026-07-03 to 2026-07-05 &middot; 10 commits &middot; `1e4829301`  **breaking**

Replaces the whole three-rung provenance apparatus with scoped rigid skolemization of
trapped effect variables -- a smaller mechanism that is both sound and complete for the
cases the rungs handled piecemeal.

> Breaking: Trapped effect variables are skolemized within their scope. Programs that laundered an effect through a rigid variable now report an undischarged effect.

Spec: [`2026-07-03-inner-abstraction-effect-laundering-design.md`](docs/superpowers/specs/2026-07-03-inner-abstraction-effect-laundering-design.md), [`2026-07-03-rung3-rework-scoped-rigid-trapped-effect-skolemization-spec.md`](docs/superpowers/specs/2026-07-03-rung3-rework-scoped-rigid-trapped-effect-skolemization-spec.md)

### the IO entry ambient and the one-shot runtime oracle

`feat(effects)` &middot; 2026-07-06 &middot; 6 commits &middot; `7a48b6e5d`  **breaking**

Top-level zero-argument bindings obligate an `{IO}` ambient, which closes the CAF effect
bypass, and a runtime oracle flags a continuation used twice.

> Breaking: Top-level zero-argument bindings carry an `{IO}` ambient effect. A user-declared `effect IO` no longer overrides the ground effect.

### qualified imports

`feat(imports)` &middot; 2026-07-06 to 2026-07-07 &middot; 3 commits &middot; `fed8544e9`

`import M`, `import M (x, y)`, and `import M as A`, resolved through a per-module,
non-transitive qualifier table.

### tail-call contraction and self-visible join points

`perf(interp)` &middot; 2026-07-21 &middot; 4 commits &middot; `d0dbb9011`

Tail calls are contracted so tail recursion runs at constant continuation depth, with join
points made self-visible so a back edge resolves.

Spec: [`2026-07-20-trmc-design.md`](docs/superpowers/specs/2026-07-20-trmc-design.md), [`2026-07-21-ir-tail-representation.md`](docs/superpowers/specs/2026-07-21-ir-tail-representation.md), [`2026-07-21-parameterized-resume-frame-leak.md`](docs/superpowers/specs/2026-07-21-parameterized-resume-frame-leak.md), [`2026-07-21-tco-tail-call-contraction.md`](docs/superpowers/specs/2026-07-21-tco-tail-call-contraction.md)

### the v2 surface spec and its design ledgers

`docs(redesign)` &middot; 2026-07-22 &middot; 6 commits &middot; `53e21c613`

The design work for the v2 surface: a full spec, conformance examples, and decision ledgers
recording what was chosen and what was rejected.


## August 2026

### a hand-written v2 tokeniser, and s-expressions that round-trip

`feat(grammar)` &middot; 2026-08-02 to 2026-08-03 &middot; 6 commits &middot; `98c4946ec`

A hand-written tokeniser and parser for the v2 surface, replacing generated parsing, with an
s-expression dump that rebuilds the source exactly -- which makes the same code a formatter
and a linter.

### the C23 front end -- scanner, layout filter, parser, formatter

`feat(grammar/c)` &middot; 2026-08-03 &middot; 11 commits &middot; `f770daf77`

The front end reimplemented in C23: scanner, a pure layout filter, parser, formatter, line
filling, and JSON Lines diagnostics, over one validated-on-read UTF-8 decoder.

Spec: [`2026-08-03-c23-frontend-design.md`](docs/superpowers/specs/2026-08-03-c23-frontend-design.md), [`2026-08-03-wokcheck-design.md`](docs/superpowers/specs/2026-08-03-wokcheck-design.md), [`2026-08-03-line-filling-design.md`](docs/superpowers/specs/2026-08-03-line-filling-design.md), [`2026-08-03-local-repair-design.md`](docs/superpowers/specs/2026-08-03-local-repair-design.md), [`2026-08-03-generative-testing-design.md`](docs/superpowers/specs/2026-08-03-generative-testing-design.md)

### generative testing over a generated schema, and the Std.* rename

`feat(grammar/c)` &middot; 2026-08-03 &middot; 16 commits &middot; `497899ef1`  **breaking**

Tests generate syntax trees from the schema rather than generating source text, then shrink
before reporting. The schema records families and the reader enforces them, so the guards
survive the edits they guard. The prelude's `Std.*` rename lands in the same run.

> Breaking: Prelude modules are renamed from `Std.*` to their bare names.

### the v2 clause-kind surface, decided

`docs(redesign)` &middot; 2026-08-04 &middot; 10 commits &middot; `434f8a5b6`

The clause-kind round: `abort` becomes a clause head, `once` is cut in favour of the comma
classifying alone, and local mutability gets one home for `:=`.

### the v2 clause surface, fixity, and the shield rule

`feat(grammar/c)` &middot; 2026-08-05 to 2026-08-06 &middot; 16 commits &middot; `99219b1a2`  **breaking**

The C front end takes on the decided v2 clause surface, plus the `fixity` declaration it
never had and a shield rule for operator resolution -- where the denotation, not the
Haskell implementation, is the oracle.

> Breaking: In handler arms the comma classifies the clause and `abort` is a clause head; `once` is removed as a clause keyword.

Spec: [`2026-08-05-v2-clause-surface-frontend-sync.md`](docs/superpowers/specs/2026-08-05-v2-clause-surface-frontend-sync.md), [`2026-08-06-fixity-front-end.md`](docs/superpowers/specs/2026-08-06-fixity-front-end.md), [`2026-08-06-fixity-shield-rule.md`](docs/superpowers/specs/2026-08-06-fixity-shield-rule.md)

### s-expression ingestion and the Haskell oracle

`feat(sexp)` &middot; 2026-08-06 to 2026-08-07 &middot; 13 commits &middot; `8d9a50cc4`

The C front end's s-expression dump becomes an input the Haskell typechecker can ingest,
with scheme-text goldens standing as the contract a future C typechecker must meet.

Spec: [`2026-08-06-sexp-ingestion-oracle.md`](docs/superpowers/specs/2026-08-06-sexp-ingestion-oracle.md), [`2026-08-07-sexp-reorder-pass.md`](docs/superpowers/specs/2026-08-07-sexp-reorder-pass.md)

### declared clause kinds and first-class handler values

`feat(handlers)` &middot; 2026-08-08 &middot; 2 commits &middot; `bfd699f9b`  **breaking**

Handler clause kinds become declared rather than counted, with a parser-backed codemod
migrating the corpus, and handlers become first-class values that can be bound, passed, and
installed by name.

> Breaking: Handler clause kinds are declared, not inferred from arity. Existing arms must name their kind; the codemod under tools/ performs the rewrite.

Spec: [`2026-08-08-prelude-v2-rework.md`](docs/superpowers/specs/2026-08-08-prelude-v2-rework.md)

### prelude v2 phases 0-2 -- runner migration and the handle-family mapper

`feat(prelude)` &middot; 2026-08-08 &middot; 9 commits &middot; `e079c3a3a`  **breaking**

The four Control runners migrate onto handler values, and the s-expression mapper learns
the handle-install family.

### prelude v2 phase 3 -- drift-gated v2 twins

`feat(prelude)` &middot; 2026-08-08 to 2026-08-09 &middot; 3 commits &middot; `66c7eb4b1`

Five of the six preludes gain a v2 twin, kept honest by a drift gate that fails when the
twins diverge.

### close the containment laundering hole

`fix(carrier)` &middot; 2026-08-10 &middot; 3 commits &middot; `e58235a8c`

A one-shot continuation carrier could still be laundered out of its activation inside an
ordinary record or data field, after which it was duplicable and resumable twice. The
containment check now follows fields and record reads, with fixtures for the thunk, cell,
nested, and user-data shapes.

Spec: [`2026-08-10-carrier-containment-fix.md`](docs/superpowers/specs/2026-08-10-carrier-containment-fix.md)


---

82 epics (21 of them breaking), rebuilt from 1046 original commits spanning 2026-05-20 to 2026-08-10.
