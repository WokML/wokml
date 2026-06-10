# Kinded type-expression representation — unify `CType`/`CRow` into one kinded `Ty`

Date: 2026-06-10
Status: **Design sketch** for a foundational refactor that PRECEDES layer-3 concurrency. Captures a
converged direction (the user has committed to reaching layer-3 concurrency + first-class/boxed
resources, which makes row-indexed effectful types a recurring need, not a one-off). The implementing
session MUST start with brainstorming (kickoff at the end) — there are real open questions (kind
taxonomy, surface syntax, staging) to settle before any code. Then writing-plans, then
subagent-driven-development. TDD. Full-branch review before merge to `main`.

Reads with: `2026-06-09-slice-4b-dprime-residual-row-future-design.md` (4b″ — the first concrete
consumer: a row-indexed `Suspension a b r e`), `2026-06-10-coroutine-types-extern-decl-design.md`
(slice 4d — `extern type`/`extern data`, where row-kinded parameter declarations attach), memory
`higher-ir-direction` (the typed-Core/ANF direction this foundation serves), `one-shot-as-law`
(affine→linear for resources), `effect-naming-design-2` + `named-effect-instances-design` (effect-row
semantics), `docs/koka.md` (row theory — the model this follows). Grounding code:
`src/Wok/TypeChecking/{Types,Unify,Infer,Env,Class}.hs`.

## 1. Summary

wok's type representation has **two parallel sorts**: types (`CType` / inference-time `Type`) and rows
(`CRow` / inference-time `Row`), each with its own variable kind, its own unifier path, and its own
copy of every traversal (zonk, freeze, generalize, instantiate, pretty, ftv, occurs). A row can only
appear in two hard-wired places — an arrow's middle slot (`CTArr CType CRow CType`) and a nominal
record (`CTRecord Text CRow`). It **cannot** appear as an argument to a type constructor, because a
tycon's arguments are `[CType]` and a row is a `CRow`, a different sort.

That is precisely the wall every row-indexed effectful type hits: `Suspension a b r e` (4b″),
`Task a e` (the scheduler), `Stream a e`, a boxed `Resource r e` — all want an effect **row** in a
type-constructor **parameter** position.

This spec proposes collapsing the two sorts into **one kinded type-expression datatype** (`Ty` at the
inference layer, `CTy` closed), where a `Kind` (`*`, `Row`, `* -> *`, …) sorts every node. A row
becomes a `Ty` of kind `Row`; arrows/records carry a kind-`Row` child; **and a tycon may declare a
kind-`Row` parameter.** Unification dispatches on kind (kind-`*` → first-order syntactic; kind-`Row` →
the existing Leijen scoped-label row unifier). Inference stays **HM + row unification, row-poly only,
no rank-2, no higher-kinded inference** — F-omega-shaped *representation*, HM-shaped *inference*. The
result: row-kinded type parameters become available *uniformly*, and the long-standing two-sort
maintenance tax (paid again in slice 4d's carrier-set threading, and would be paid again by a
one-off 4b″ injection) is retired.

## 2. Motivation — why general, not a one-off

A `CTRow CRow` injection that wraps a row as a type *just for `Suspension`* pays the full cost of a
representation change (every `CType` traversal gains a case under `-Werror`) **and** weakens the
"well-kinded by construction" invariant (a `CType` could now hold a non-`*` node, caught only by a
checker), all to serve one type. Rejected (§13).

The user is committing to the roadmap's deferred **layer 3** (scheduler / `spawn` / `par` / `select`)
and **first-class / boxed resources + cancellation**. That cluster is *pervasively* row-indexed:

| Future type | Shape | The row records |
|---|---|---|
| `Suspension a b r e` (4b″) | parked coroutine | effects the resumed tail performs |
| `Task a e` (scheduler) | spawned computation | effects it performs when awaited |
| `Stream a e` / `Sink a e` | pull-stream | effects each step performs |
| `Channel a` send/recv | typed channel op | the op's effects |
| `Resource r e` (boxed) | escaped handle/resource | effects owed on use/release |

Every one needs the same capability. Build it once as a kinded representation and each is "a tycon
with a `Row` slot." Build it as per-type encodings and you re-derive the wall N times. Since the
decision is "we WILL reach layer 3," general is the YAGNI-correct call.

## 3. The current representation (grounded)

`src/Wok/TypeChecking/Types.hs`:

```haskell
data Kind = KStar | KEffect | KArrow Kind Kind          -- a kind for rows already exists (KEffect)

-- inference-time (mutable cells)
data Type s = TCon TyCon [Type s] | TArr (Type s) (Row s) (Type s)
            | TRecord Text (Row s) | TVar (STRef s (TVar s))
data TVar s = Unbound { uniq, level, kind :: Kind } | Rigid { uniq, kind :: Kind } | Link (Type s)
data Row s  = RowEmpty | RowExtend Text (Type s) (Row s) | RowVar (STRef s (RVar s))
data RVar s = RUnbound { rUniq, rLevel } | RLink (Row s)   -- NB: RVar carries NO kind (implicitly Row)

-- closed (post-freeze)
data CType = CTCon TyCon [CType] | CTArr CType CRow CType | CTRecord Text CRow | CTGen Int
data CRow  = CREmpty | CRExtend Text CType CRow | CRGen Int

data Scheme = Scheme { schemeVars :: [(Int, Kind)], schemeConstraints :: [Constraint], schemeBody :: CType }
```

**The foundation is already half-built — four facts make this cheaper than it looks:**

1. **A row kind already exists** (`KEffect`) and is load-bearing: generalisation/instantiation already
   split quantifiers by kind (`Infer.hs:262-265, 345-349`), row variables are `KEffect`-kinded, and
   schemes quantify rows as `CRGen` slots. wok already does **row-polymorphism** and **principal row
   unification** (`Unify.hs`, the Leijen 2005 scoped-label unifier). The hard theory is done.
2. **`Scheme.schemeVars :: [(Int, Kind)]`** and **`TyConInfo.tcKind :: Kind`** (a *full* `Kind`) are
   already kind-aware. A tycon kind like `* -> * -> * -> Row -> *` is already *representable*; the
   arity-based construction just hard-codes all-`KStar` params (`Infer.hs:854`).
3. **Record rows and effect rows already share one datatype** (`CRow` is used by both `CTArr` and
   `CTRecord`). There is one row sort, not two.
4. The unifier **already has a TODO for exactly this** (`Unify.hs:312-315`):
   > *"check kinds before linking. The TVar's kind field is ignored in v1 because every type is KStar;
   > once KEffect / KArrow row variables ship, we need to verify the target's kind matches … and emit
   > a KindMismatch error."*

So the gap is not the kind *system* — it is the **value-level two-sort split** (`CType` vs `CRow`,
`Type` vs `Row`, `TVar` vs `RVar`) and the inability to put a row in a tycon argument.

## 4. The design

### 4.1 Kinds

```haskell
data Kind = KStar | KRow | KArrow Kind Kind   -- rename KEffect -> KRow (rows are the general kind)
```

(The `KEffect`→`KRow` rename is cosmetic — the kind's *identity* matters, not its name; it may be
kept as `KEffect` to shrink Slice A's diff.) `KRow` classifies effect rows AND record rows (they already share `CRow`; see §14 open Q on whether
duplicate-label/multiset semantics force two row kinds). `KArrow` already exists today as a tycon
*arity descriptor* (`[] : * -> *`, tuples) and is used ONLY to kind-check applications — by the
decidability contract (§7) **no unification variable is ever `KArrow`-kinded**, so this does not admit
higher-kinded inference. Kinds remain first-order and finite.

### 4.2 One closed type-expression datatype

```haskell
data CTy
  = CtCon  TyCon [CTy]      -- tycon applied; each arg's kind dictated by the tycon's declared kind
  | CtArr  CTy CTy CTy      -- domain -[row]-> codomain ; the MIDDLE child has kind KRow
  | CtRecord Text CTy       -- nominal record ; the child has kind KRow
  | CtRowEmpty             -- {} : KRow
  | CtRowExt Text CTy CTy   -- label : payload(KStar) , rest(KRow)   (preserve current per-label payload encoding)
  | CtGen  Int            -- bound var; its kind is read from the enclosing Scheme's quantifier list
```

A row is now an ordinary `CTy` of kind `KRow`, so it can sit anywhere a `CTy` can — including a
`CtCon` argument. `Scheme` is unchanged in shape (`schemeVars :: [(Int, Kind)]`, `schemeBody :: CTy`);
`CtGen i`'s kind is the `i`-th quantifier's kind. The label payload in `CtRowExt` preserves the
current `RowExtend`/`CRExtend` encoding faithfully (it is how effect/field arguments are stored — do
NOT redesign it here).

### 4.3 One inference-time datatype + one meta-variable

```haskell
data Ty s = TyCon TyCon [Ty s] | TyArr (Ty s) (Ty s) (Ty s)
          | TyRecord Text (Ty s) | TyRowEmpty | TyRowExt Text (Ty s) (Ty s)
          | TyVar (STRef s (Meta s))
data Meta s = Unbound { uniq, level, kind :: Kind }   -- kind now meaningful for ALL vars (incl. rows)
            | Rigid   { uniq, kind :: Kind }
            | Link (Ty s)
```

`RVar` merges into `Meta` — a row variable is a `TyVar` whose cell has `kind = KRow`. This is what
the `Unify.hs:312` TODO asks for: every meta var carries a real kind.

### 4.4 Unification dispatches on kind

`unify` first forces both sides, then **dispatches by kind**:

- both `KStar` → the existing first-order structural unify (`TyCon`/`TyArr`/`TyRecord`), occurs-checked.
- both `KRow` → the existing Leijen scoped-label row unifier (`unifyRow`), unchanged algorithm.
- `KStar` vs `KRow` (or any mismatch) → a new `KindMismatch` type error (the TODO's promise).
- `unifyVar` checks the target's kind against the cell's kind before `Link` (closing the `Unify.hs:312`
  TODO).

No new unification *algorithm* — both already exist. The merge is: one datatype, a kind dispatch at
the top, and `unifyVar` honouring kinds. Principality is preserved because each branch is the existing
principal procedure.

### 4.5 Kind checking (declared kinds; row-kinded params)

Tycon kinds are **declared, not inferred** (kept simple/decidable):

- `extern type`/`extern data` (slice 4d) and ordinary `data` decls gain optional **per-parameter kind
  annotations**; an un-annotated param defaults to `KStar` (full back-compat — every existing decl is
  all-`KStar`). Syntax is an open question (§14) — e.g. `extern type Suspension a b r (e : Row)`.
- A tycon application `T t1 … tn` is **kind-checked**: each `ti` must have the kind `T`'s declared
  kind demands at that position (today `translateConArg` only checks *arity*; it gains a kind check).
  A row argument in a `KStar` slot, or a `*` argument in a `KRow` slot, is a `KindMismatch`.
- Kind *synthesis* over a type expression is syntax-directed (vars from the quantifier list, tycons
  from `TyConInfo.tcKind`, arrows/records/rows have fixed kinds). No kind *inference* fixpoint.

### 4.6 Generalisation / instantiation

Essentially unchanged — they are *already* kind-aware (`Infer.hs:262-265, 345-349` split `KEffect`
vs `KStar`). After the merge there is one code path that quantifies/instantiates a var at whatever
kind its cell carries, replacing the current "types here, rows there" duplication. `freeze`
(Type→CType, Row→CRow) collapses into one `Ty s → CTy`.

## 5. What it unlocks (the payoff catalogue)

1. **Row-indexed effectful types — the whole layer-3 cluster** (§2 table). `Suspension a b r e`
   (4b″), `Task a e`, `Stream/Sink a e`, `Channel`. Each is "a tycon with a `Row` slot"; `step`/`run`/
   `await`/`pull` thread the row into their own effect row, so the **consumer site must handle it**
   (turning 4b's documented re-perform crash into a type error, uniformly, for every such type).
2. **First-class / boxed resources + cancellation.** A boxed handle/continuation that escapes its
   handler carries its effect obligations in its type (`Box e` / `Resource r e`); use-after-escape is
   a type error, not a crash. Dovetails with `one-shot-as-law`: a resource needing exactly-once
   release upgrades affine→linear, and the release effects live in the row.
3. **Effect aliases / effect-generic libraries.** Rows as type expressions can be *named* and *passed*
   (`type App = {State S, Except E, Log}`; library types parameterised over an arbitrary effect row),
   the way koka libraries stay effect-generic.
4. **Unified record-rows ⊕ effect-rows.** Both already share `CRow`; one `KRow` kind makes that
   official and enables **row-polymorphic records as parameters** / extensible records in more
   positions — and deletes the duplicated row machinery.
5. **Cheaper future type-system work + typed-Core foundation.** One representation means new features
   extend *one* datatype with *one* kind rule instead of threading both worlds (the tax slice 4d paid
   for carrier-set, and 4b″ would pay again). It also gives the memory's `higher-ir-direction`
   (elaborate to typed Core) a sound kinded type language at the boundary.
6. **(Door, caveated) higher-kinded parameters.** The merge makes `* -> *` *slots* representable
   (Functor/Traversable-style abstraction, multi-param classes beyond today's single-param `Eq`).
   **Caveat:** wok's thesis is "effects replace monads," so HKT-for-`Monad` is likely *not* wanted,
   and higher-kinded *inference* would break decidable HM. Treat as "no longer forbidden by the
   representation," not a goal.

## 6. Staging strategy (how to land a core-representation change safely)

Merging two core datatypes is inherently a big change, but it splits cleanly into a **behaviour-
preserving refactor** then **additive features**:

- **Slice A — the merge, as a semantic no-op.** Collapse `Type/Row` → `Ty s` and `CType/CRow` → `CTy`,
  merge `TVar/RVar` → `Meta`, kind-dispatch in `unify`, honour kinds in `unifyVar`. **No new surface
  syntax, no row-kinded params yet.** Every existing program type-checks identically; **all ~695
  goldens are unchanged** (pretty-printer output identical). The golden suite is the proof of
  equivalence — this is what makes the dangerous refactor reviewable. Front-load this slice.
- **Slice B — row-kinded tycon parameters.** Additive on the merged rep: per-parameter kind
  annotations on `extern type`/`extern data`/`data`, kind-checking of applications, surface syntax for
  a row in a type-argument position (`Suspension a b r {Log}` or `… (eff e)` — grammar change → BNFC
  regen + the 3 manual patches). Small, because the representation already permits it.
- **Slice C+ — the consumers.** 4b″ (`Suspension a b r e`) is the first; then `Task`/scheduler,
  `Stream`, boxed `Resource`. Each is now a small typing increment, no core change.

This ordering means the high-risk work (A) ships as a behaviour-identical refactor, separately
reviewed, before any feature rides on it.

## 7. Decidability contract (the invariant that keeps inference HM-principal)

The value of this change is **representational generality, NOT inference power.** After the merge,
*every* unification reduces to one of two existing, already-principal, mutually-recursive procedures —
structural type unification and the Leijen scoped-label row unifier — selected by a **statically known
kind**. Inference therefore stays decidable and principal **exactly as today**, *iff* all five of the
following hold. These are invariants, not aspirations: they should be guarded by tests, and no future
slice may cross one without redoing this analysis.

1. **Kinds are declared and checked, never inferred.** No kind variables, no kind polymorphism;
   un-annotated tycon params default to `KStar`. Kind synthesis is syntax-directed and decidable.
2. **Meta-variables are instantiated only at `KStar` or `KRow` — never `KArrow`.** Tycons may *have*
   `KArrow` kinds (e.g. `[] : * -> *`), used solely to kind-check applications; but no unification
   *variable* is ever `KArrow`-kinded. This is the single guard against higher-order unification
   (undecidable).
3. **Type-constructor application is always saturated, with a concrete tycon at the head.** No
   type-level lambdas; no partially-applied tycon as a unifiable value. (Already enforced by exact
   arity checking; must remain so.)
4. **Rows stay scoped-label (Leijen), with no lacks/presence constraints.** This is what makes row
   unification unitary and decidable without qualified types — and therefore free of qualified-type
   ambiguity.
5. **Every tycon argument slot has a fixed, declared kind.** Unification decomposes a tycon
   application argument-wise at known kinds; it never has to *guess* whether a position is a type or a
   row.

**Why these suffice.** By (1)+(5) unification never mixes sorts: each pair it meets has a known, equal
kind, or it is an immediate `KindMismatch`. By (2)+(3) no variable is ever applied to arguments, so
higher-order unification — the undecidable case — is structurally absent. By (4) the row sub-procedure
is unitary and constraint-free. The two procedures are mutually recursive (a `*` unification of an
arrow delegates to row unification for its effect slot, exactly as today) but terminate on finite
terms with occurs-checks on both sorts. Composition of principal steps is principal ⇒ HM principal
types still exist and are computed; let-generalisation is unchanged.

**What WOULD break it (all deferred; each needs its own metatheory pass):**
- Higher-kinded *inference* — a `* -> *` *variable* that gets unified ⇒ higher-order unification,
  undecidable in general (decidable only under a generative/injective-application restriction à la
  GHC, which is subtler and out of scope). Violates (2).
- Kind *inference* with kind variables ⇒ still decidable but new machinery; violates (1).
- Lacks/presence-constrained (set-semantics) records ⇒ qualified types + potential ambiguity;
  violates (4).

The danger to manage is *future scope creep across this contract*, not this change itself.

**Runtime unchanged.** This is a type-representation refactor; interpreter/ANF *values* are untouched
(ANF *type annotations* re-thread through `CTy`; lowering and evaluation do not change).

## 8. Blast radius (files)

Essentially the type-checking subsystem; bounded and mostly mechanical, with the ~695-test golden
suite as the net:

- `src/Wok/TypeChecking/Types.hs` — the datatypes (the merge itself).
- `src/Wok/TypeChecking/Unify.hs` — kind-dispatch `unify`; `unifyVar` kind check; `unifyRow` reused.
- `src/Wok/TypeChecking/Infer.hs` — `freeze`/zonk/instantiate/generalise collapse to one path;
  `resolveTyCon`; kind-check in `translateConArg`/tycon application; `prettyCType`/`prettyCRow` →
  one printer; `schemeParamTypes`; data-decl kind construction (`Infer.hs:854`).
- `src/Wok/TypeChecking/Env.hs` — `TyConInfo` (per-param kinds; `tcKind` already a full `Kind`).
- `src/Wok/TypeChecking/Class.hs` — `tyConKey`; class-param kinds.
- `src/Wok/TypeChecking/Carrier.hs`, `src/Wok/IR/{Anf,Elaborate}.hs`, `Typed.hs` — consume the frozen
  type (`CType`→`CTy`): pattern matches and the `prettyCTypeLocal` printer re-target.
- `src/Wok/TypeChecking/Builtins.hs` — `initialEnv` tycon kinds.
- `grammar/Wok.cf` — ONLY in Slice B (kind-annotation + row-in-type-arg syntax) → BNFC regen + 3 patches.

## 9. Scope

**IN (Slice A):** merge `Type/Row`→`Ty`, `CType/CRow`→`CTy`, `TVar/RVar`→`Meta`; kind-dispatched
`unify`; `unifyVar` kind enforcement + `KindMismatch`; one freeze/zonk/generalise/instantiate/pretty;
behaviour-identical (goldens unchanged). **IN (Slice B):** per-param kind annotations; kind-checked
applications; row-in-type-argument surface syntax; `Suspension`/`Step` (or the next consumer) gaining
a `Row` param as the proof.

**OUT (deferred):** higher-kinded *inference*; rank-2 / first-class polymorphism; any `Monad`/HKT
class hierarchy; kind *inference* for data decls (annotate instead); **row-kinded class parameters**
(class params stay `KStar` — no `Eq`-over-a-row) and instances over carrier/row-indexed types
(carriers are second-class, never stored, so never need an instance); the layer-3 consumers themselves
(separate slices); a typed-Core IR (separate track — this only makes it cheaper later).

## 10. Migration & golden strategy

- Slice A is a **pure refactor**: the acceptance bar is "every one of the ~695 goldens is byte-identical."
  If a golden changes, the merge altered observable behaviour — investigate, do not accept. The
  zero-churn bar explicitly includes **error-message rendering** (existing `RowMismatch` etc. text —
  `KindMismatch` cannot fire in Slice A since every existing type is `KStar`) and **type
  pretty-printing**: the merged single printer must emit byte-identical output to the two printers
  (`prettyCType`/`prettyCRow` and `prettyCTypeLocal`) it replaces.
- Do the merge bottom-up: datatypes → unify → freeze/zonk → inference → frozen-AST consumers → printers.
  Keep `cabal build` honest at each layer (the `-Werror` exhaustiveness checks turn every unported match
  into a compile error — use that as the worklist).
- **Migration shape — decide in planning:** either (a) mutate `Types.hs` in place and ride the
  `-Werror` worklist (one big-bang, but the compiler lists every site), or (b) introduce `CTy`/`Ty`
  ALONGSIDE the old types and port module-by-module behind conversions, deleting `CType`/`CRow` last —
  (b) trades a temporary conversion layer for incremental compilability instead of a whole-subsystem
  big-bang. Transitional `type CType = CTy` / pattern synonyms can shrink either diff.
- **Correctness-preservation checks (Slice A is only a no-op if these hold):**
  - **Shared gen index space.** `CTGen`/`CRGen` already index into ONE `schemeVars` list (instantiation
    filters it by kind, `Infer.hs:262-265`), so the unified `CtGen i` reads its kind from
    `schemeVars[i]`. Confirm this before collapsing the two gen constructors — if they had ever been
    separate index spaces, the merge would conflate a type-gen and a row-gen at the same index.
  - **Do not newly skolemize rows.** Today `RVar` has NO `Rigid` form — row variables in signatures
    are not skolemized the way type variables are (`freezeSig`). Giving the unified `Meta` a `Rigid`
    constructor must NOT start treating signature row vars as rigid; replicate the current
    row-var-in-signature handling exactly, or Slice A silently changes inference behaviour (and is no
    longer a no-op).

## 11. Testing

- **Slice A:** the entire existing suite green AND unchanged (the equivalence proof). Add unit tests:
  `unify` of two `KRow` `Ty`s behaves as the old `unifyRow`; a `KStar` vs `KRow` unify yields
  `KindMismatch`; `unifyVar` rejects a kind-mismatched link; round-trip `freeze` of a row-bearing type.
- **Slice B:** a tycon declared with a `Row` param kind-checks when applied to a row and `KindMismatch`es
  when applied to a `*` (and vice-versa); the row-in-type-arg syntax parses + elaborates; a row-kinded
  param prints back correctly.
- **Regression:** the coro run-examples (421/10/52/64) and negatives stay identical across both slices.

## 12. Build / verify

`cabal build` (lean on `-Werror` exhaustiveness as the port worklist); `cabal test` (Slice A: expect
ZERO golden churn — read any diff as a bug; Slice B: expected new goldens only). Grammar change in
Slice B → BNFC regen + the 3 manual patches + no new shift/reduce conflicts. Full-branch review
before each merge to `main`.

## 13. Rejected alternatives

- **One-off `CTRow CRow` injection** (a single new `CType` constructor wrapping a row, for `Suspension`
  only). Pays a representation cost (every `CType` traversal under `-Werror`) AND weakens
  well-kinded-by-construction (a `CType` can hold a non-`*` node), to serve one type. The awkward
  middle: neither minimal nor general. Rejected once layer 3 is committed.
- **Arrow / phantom encoding** (carry the residual row on an arrow inside `Suspension`'s representation;
  no new sort). Sound and minimal, and the right call IF only `Suspension` ever needed it — but it
  fights the nominal-opaque API (recovering `e` from an internal arrow) and does NOT generalise to
  `Task`/`Stream`/`Resource`. Rejected because the roadmap needs the capability broadly. (Remains the
  fallback if Slice A's blast radius proves larger than estimated and layer 3 slips.)
- **Full F-omega with higher-kinded INFERENCE.** Overshoots: breaks decidable HM, which is a wok
  invariant. We take F-omega *representation* only, with HM inference (§7).

## 14. Open questions (settle in brainstorming — before any code)

1. **Kind taxonomy.** One `KRow` for both effect-rows and record-rows, or two kinds? They already
   share `CRow`, favouring one — but confirm effect-row semantics (named instances / any duplicate-
   label or multiset behaviour from `named-effect-instances-design`) don't diverge from record-row
   set semantics in a way that wants distinct kinds.
2. **Surface syntax — decl site:** how to annotate a row-kinded parameter (`(e : Row)` vs a sigil vs
   bracket). And **use site:** how to write a row in a type-argument slot (`Suspension a b r {Log}`,
   `Suspension a b r (eff e)`, `… ..e` for the open tail). Reuse the existing `EffectRow`/`with`
   grammar where possible; estimate the grammar/BNFC change.
3. **Staging confirmation.** Is the behaviour-preserving Slice A genuinely landable as a zero-golden-
   churn no-op, or do pretty-printer details force churn? (Probe early — it determines reviewability.)
4. **Transitional aliases / pattern synonyms** to shrink the Slice A diff — worth it or churn?
5. **Kind inference for `data` decls** — mandatory annotation (simplest) vs inferring a param's kind
   from constructor-field usage (more ergonomic, more machinery). Recommend mandatory/annotation first.
6. **RESOLVED (decidability contract §7):** Slice B exposes `KRow` parameters only. `* -> *` param
   slots and any `KArrow`-kinded variable are OUT — they would violate contract invariant (2) and
   open higher-order unification. A future HKT slice, if ever wanted, must redo the §7 metatheory.
7. **Interaction with the typed AST / ANF type annotations** — confirm `Typed.hs` + `Anf.hs` re-thread
   `CTy` mechanically with no behavioural change.

## 15. Relationship to other slices

- **4b″** is the first consumer; it can be re-specced to *depend on* Slice A+B rather than carry its own
  kind extension. (The 4b″ design's §2 "kind-system prerequisite" IS this spec.)
- **4d** (`extern type`/`extern data`) is where row-kinded parameter *declarations* attach — the
  marker-carrying tycons are the natural first row-kinded tycons.
- **Layer 3** (scheduler) and **boxed resources** are the broad payoff (§5) and the reason to do this
  generally now.

---

## Kickoff prompt (paste into a fresh session)

```
Work on the KINDED TYPE-EXPRESSION REPRESENTATION for the wok language (repo /Users/zy/wokml): unify
the two type sorts (CType/CRow, inference-time Type/Row, TVar/RVar) into ONE kinded type-expression
datatype, so a row can appear as a type-constructor parameter. This is the foundation for layer-3
concurrency (Task/Future/Stream/Channel) and first-class/boxed resources — all row-indexed. Spec:
docs/superpowers/specs/2026-06-10-kinded-type-representation-design.md. Branch from main first
(feat/kinded-ty-representation). Standing rules: FULL-BRANCH review before any merge to main; I prefer
clarifying questions in prose (not multiple-choice).

START with brainstorming, and settle the §14 open questions FIRST — especially: (1) one KRow kind vs
distinct effect/record row kinds (they already share CRow); (2) surface syntax for a row-kinded param
(decl site) and a row in a type-argument slot (use site); (3) whether Slice A (the merge) can land as
a ZERO-golden-churn behaviour-preserving no-op. THEN writing-plans, THEN subagent-driven-development.
TDD.

KEY GROUNDING (the foundation is half-built):
- A row kind already exists (Kind = KStar | KEffect | KArrow) and is load-bearing: generalisation/
  instantiation already split vars by kind (Infer.hs:262-265, 345-349); row unification is already
  principal (Unify.hs, Leijen 2005).
- Scheme.schemeVars is already [(Int, Kind)]; TyConInfo.tcKind is already a full Kind. A kind like
  * -> * -> * -> Row -> * is already REPRESENTABLE; the data-decl construction just hard-codes all
  KStar params (Infer.hs:854).
- Record rows and effect rows already share the SAME CRow datatype (CTArr and CTRecord both use CRow).
- Unify.hs:312-315 has an EXPLICIT TODO for this: "check kinds before linking … once KEffect/KArrow
  row variables ship, verify the target's kind matches and emit a KindMismatch."

THE GAP is the value-level two-sort split + the inability to put a row in a tycon argument. THE PLAN:
Slice A = merge the datatypes as a behaviour-preserving no-op (all ~695 goldens UNCHANGED — that is the
equivalence proof; use -Werror exhaustiveness as the port worklist; unify dispatches on kind, reusing
the existing structural and row unifiers; unifyVar enforces kinds → KindMismatch). Slice B = row-kinded
tycon parameters (per-param kind annotations on extern type/data + data; kind-checked applications;
surface syntax for a row in a type-arg slot → grammar change + BNFC regen + 3 manual patches). Then the
consumers (4b″ Suspension a b r e, then Task/scheduler, Stream, boxed Resource) become small increments.

HOLD THE LINE (wok invariant): decidable + HM-principal, row-poly only, NO rank-2, NO higher-kinded
INFERENCE. F-omega-shaped representation, HM-shaped inference. Runtime/interpreter unchanged.

OUT OF SCOPE: higher-kinded inference; Monad/HKT class hierarchy; rank-2; kind inference for data decls
(annotate instead); the layer-3 consumers themselves (separate slices); a typed-Core IR.
```
