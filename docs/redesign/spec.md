---
spec: wok-surface-redesign
status: buildable
---

# wok surface redesign (v2 sketch): capabilities, declared clause kinds, one second-class mode

This spec records a from-scratch redesign of wok's surface for the EXISTING feature
set (one-shot effects, affine continuations, Perceus RC + regions, second-class
carriers, HM + rows). Semantics are unchanged; what changes is which facts are
written in source versus reconstructed by analysis. Every change traces to a bug
class or silent-legality trap found empirically (the Section E probe battery,
2026-07-21) or to a merged-slice discovery in the repo history.

Method note: the design below was itself pressure-tested Section-E-style before
writing this spec. The pressure-test record IS the challenge/response section;
one original sketch (direct-style Search) failed the test and was retracted.

<non_goal id="NG1">An implementation plan for the current repo. The retrofit
appendix orders what could be cherry-picked, but this spec describes a
hypothetical v2 surface, not a migration.</non_goal>
<non_goal id="NG2">Any change to the memory model (Perceus, regions, FBIP,
layout) or to the one-shot law. Both are kept verbatim.</non_goal>
<non_goal id="NG3">Multi-shot continuations in any form. The law stands;
multi-shot remains data.</non_goal>
<non_goal id="NG4">First-class continuations or first-class capabilities. Both
stay second-class; this spec only unifies how second-class-ness is checked and
reported.</non_goal>
<non_goal id="NG5">Concrete lexer/parser productions. Grammar sketches here fix
FORM and disambiguation rules, not the BNFC encoding.</non_goal>

## 1. The five surface forms

(Concrete keyword palette, declaration forms, and block-sequencing rules are
fixed in the companion `surface.md` — D10 through D12. This section states
the effect-system forms; examples below use the final surface.)

### 1.0 Principles (P1, P2)

Two principles GENERATE the binding rules below; the named decisions D13 and
D17 are worked instances of them, not independent axioms (D18).

P1 — VISIBILITY: explicitness scales with scope visibility. A binder whose
scope is not syntactically delimited must be written in full; a binder whose
scope is delimited may be elided when derivable. Re-binding a live
obligation-carrying name (a label, a continuation) in the same undelimited
scope is an error; for LABELS ONLY, re-binding inside a delimited sub-scope
is ordinary scoping. A continuation binder's name is frozen throughout its
USABILITY REGION — its arm body up to any function-forming boundary
(lambda, local function equation, handler literal: the D27 list) — before
AND after consumption (a dead-name shadow would absorb a double-resume
attempt that must surface as E-AFFINE); `(let k = f in k (k 1))` is the S2
silence with parentheses. Beyond a function-forming boundary the
continuation is unusable anyway (capture is conservatively rejected, C10),
so a same-named binder there declares a fresh thing and is ordinary
scoping (C15/D28) — which is what lets the k convention compose across
nested handlers.
Derived: statement handles write their labels; inline handles may
elide them (derivable from the handler's type); `use` targets are never
elidable (a rename is information, not derivable); E-SHADOW's same-block
rule and its delimited allowance; the inline-`use` adjacency idiom.

P2 — ROLES AND SLOTS: two binding forms, not two label regimes. ROLE LABELS
(lowercase) are free names in their own namespace (1.6): they bind any
effect and are never checked against anything. DESIGNATION SLOTS exist one
per declared effect, are named BY the effect (`State`), and have an
ordinary type — an activation of that effect. `handle State = h` and
`use x as State` ASSIGN the State slot, so the former "capitalized label"
rules are ordinary name resolution (an unknown slot is an undefined name)
and ordinary typing (the State slot holds State activations). Default-label
row entries (`with State U64`) are obligations on the SLOT; role entries
(`with (st : State U64)`) are obligations on a role name.

### 1.1 Handler values

```
state : s -> Handler (State s) a (a, s)
state init = handler State
  var cur = init
  get      -> cur
  set x    -> cur := x
  return v -> (v, cur)
```

- `handler E` introduces a handler VALUE (first-class data). The effect name `E`
  is mandatory (see C3). Clauses follow in a layout block (current column-aware
  arm-body rules carry over unchanged).
- `Handler E a b` is the handler's full contract: handles `E`, turns an
  `a`-computation into a `b` result. Answer-in/answer-out are explicit in the
  type (see D7).
- A handler whose ARM BODIES themselves perform carries its own row:
  `Handler E a b with (log : Writer [String])`. That row is discharged at each
  `handle` site, exactly as a function's row is discharged at each call
  site; the activation is then confined within those providers (D15).
  Row composition: a handle-expression's row = (body row \ E) + the arm
  row — this is what carries arm-origin obligations into any carrier
  captured across the handle (certified empirically: q4-trace addendum).
- Clause kinds are keyword-distinguished:
  - `op p1 p2 -> e` — auto-resume (tail-resumptive). One PATTERN per
    argument position (D14); pattern count = op arity.
  - `op p1 p2, k -> e` — control clause, classified by the comma ALONE
    (D25: the `once` keyword is cut). Argument patterns = op arity, then
    the `,` separator, then the continuation binder — an affine
    second-class function, always a bare lowercase variable, never a
    pattern. The comma marks where the op's application ends: left of it,
    binder count = op arity for every clause kind (C8, amended).
    ABORT-TOTALITY: the arm must consume its continuation on at least one
    path; an arm that never does is E-ABORT — write `abort`.
  - `abort op p1 p2 -> e` — aborting control clause. Pattern count = op
    arity; NO continuation is bound. The clause promises it never resumes,
    and the promise is enforced by construction — no continuation name
    exists in the clause to call. The body is typed at answer-out `b` and
    IS the handle-expression's answer on that path; the `return` clause
    does not run (see C13/D24).
  - `return p -> e` — the value clause (pattern allowed). Optional;
    defaults to identity (then `b` = `a`).
  - `var cur = e` — a frame baton (parameterized handler state).
- An op may have MULTIPLE clauses with refutable patterns; they desugar to
  one clause plus `case` on the argument (decision trees), and together they
  must COVER the argument type (E-COVER) — under labels a perform routes to
  exactly one activation, so a match failure has no fallthrough (D14).
- `cur := e` updates a baton. Legal only in clause bodies of the handler
  that declares `var cur`; frame-state semantics (see C4). (Schematic name
  `cur`, not `s`: the type variable `s` in the example's signature is a
  separate namespace — see accept/01.)

### 1.2 Installing: `handle` binds a label (two-tier)

```
handle State = state 0            -- statement form: label REQUIRED
handle from  = state 100          -- statement form, role label
(handle collect in count 1 7)     -- delimited inline form: label elidable,
                                  --   defaults to the effect head (Yield)
```

- STATEMENT form (scopes over the rest of the block, D11): the label is
  REQUIRED — the extent is invisible, so the provider of every
  statement-scoped perform must be greppable text (`grep "handle State"`
  finds the binding site).
- DELIMITED INLINE form (`handle [l =] h in body`): the label may be ELIDED,
  defaulting to the effect head of `h`'s Handler type. The extent is
  visibly bounded and the provider sits next to its body, so the label earns
  nothing there — this is the runner idiom
  (`handle collect in count 1 7`, accept/04; or over a handler-valued
  parameter, `handle h in useTick ()`, accept/07). Write the label when it is a ROLE a
  row needs (`handle st = state 0 in sumList ...`).
- Binding the effect head name (`State`) is how ambient/default-label code
  is served; any other name creates a role label reached via `x.op` or
  bridged with `use ... as` (1.4).
- The whole inline expression has the handler's answer-out type (`(a, s)`
  for `state`).
- Answer shapes NEST in install order because handler order is OBSERVABLE
  (abort semantics differ by nesting — except-outside-state discards state,
  inside preserves it); this coupling is semantic and deliberate (D18).
- Shadowing is ONE rule for all labels: re-binding a live label in the same
  block is E-SHADOW; re-binding inside a delimited inline sub-expression is
  allowed — its scope is visibly bounded. Elision changes nothing here: an
  elided inline label IS the effect head and may shadow an outer one exactly
  as a written one may.
- Idiom (style, not grammar): bind the effect head directly
  (`handle State = state 0`) for the common single-instance ambient case;
  bind ROLES and designate via `use ... as` when a block juggles multiple
  same-effect instances (the accept/06 pattern). Both forms are legal
  everywhere; forbidding either was considered and rejected — neither
  closes a nameable trap the other enables.
- Regimes (P2): a CAPITALIZED name in binder position assigns that effect's
  DESIGNATION SLOT — an unknown slot is a name-resolution error and a
  wrong-effect handler is an ordinary type error (both render as E-LABEL;
  D17 is the worked example; aliases resolving to effect instances count).
  Lowercase labels are ROLES: free names, any effect. The elided inline form
  conforms by construction (its slot is derived from the handler's type).

### 1.3 Capability rows: set-based, keyed by NAME (labels)

Capabilities are never positional term-level parameters and never resolved by
type. A function's capability requirements form a LABELED ROW — unordered,
keyed by label (see C1 for the trade study that forced this):

```
transfer : () -> () with (from : State U64) + (to : State U64)
transfer () =
  let amt = from.get
  from.set 0
  to.set (to.get + amt)
```

- Labeled entries are PARENTHESIZED, mandatorily (D20): `(label : Instance)`
  is a self-delimiting unit — no colon-extent precedence rule for readers or
  the parser. Default entries are bare instance types.
- A bare row entry `with State U64` is an obligation on the State
  DESIGNATION SLOT (P2) — it needs no written label because slots are named
  by their effect, and it HAS no labeled spelling: the label inside a
  parenthesized entry must be LOWERCASE (a role; a capital there is
  E-LABEL). Today's rows, and today's `State.get` surface, are exactly the
  slot-obligation special case.
- A row label IS A BINDER: it is in scope in the body directly (`from.get`)
  — no further binding, `use`, or ceremony is ever needed on the callee
  side. The fully-named signature style is therefore already available as
  an option within this design (see rejected.md A11's salvage).
- Labels are NOT expressions (D9): a label may appear only as a dot receiver
  or in `use ... as`. Capabilities therefore never exist as terms, and the
  capability-escape class is grammatically inexpressible.
- Resolution at every call site is BY LABEL against the caller's lexical
  scope; a missing label is E-AMBIENT (same-typed labels offered as hints);
  a duplicate label in one row is E-LABEL.
- Two same-typed capabilities are two labels (`from`/`to`); swapping them
  requires visibly re-binding labels, never a positional accident.
- Row polymorphism (`with eff e`) forwards matching labels through
  intermediate functions untouched, as today. Labeled rows sit on arrow
  types exactly like current rows and defer resolution to application sites,
  preserving today's dynamic-handling behavior for closures passed downward.

### 1.4 Re-binding labels: `use ... as`

- `use x as l, y as m in body` re-binds labels within `body` — the bridge at
  boundaries where names differ (calling a `with State U64` helper with a
  cell labeled `c`: `use c as State in helper ()`).
- In a block, `use x as l` scopes over the rest of the block (D11).
- The same-block shadowing rule of 1.2 applies to `use` bindings equally.
- `use x as L` with `L` capitalized ASSIGNS the L designation slot (P2);
  ordinary slot typing requires `x`'s instance to have effect head `L`
  (D17's worked example) — `use` cannot tell the lie `handle` cannot tell.

### 1.5 Dot resolution order

For `X.y`: if `X` is BOTH an import qualifier and a row label in scope, the
dot is E-LABEL (ambiguous receiver) — disambiguate by renaming the import
(`import Foo as F`) or bridging the label (`use ... as`). Otherwise:
(1) import qualifier (qualified name); (2) row label in scope (including
default labels like `State`); (3) record projection by receiver type.
Collisions between the qualifier and label namespaces are ERRORS, not silent
precedence — a like-named import must never silently capture ambient
performs (hardened after review; see C6).

### 1.6 Namespaces

Labels form their OWN namespace, disjoint from terms. A name is resolved as
a label only in the four LABEL POSITIONS: a `handle` binder, a dot-receiver
head, the subject of `use`, and the target of `as`. Everywhere else a name
is a term (D9: labels are not expressions). Under P2 this namespace holds
ROLE labels (lowercase); a CAPITALIZED name in a label position refers to
that effect's DESIGNATION SLOT, which lives in the effect namespace (one
per declared effect). The governing invariant: A CAPITALIZED NAME IS NEVER
A FRESH BINDER — it always references something declared elsewhere (a
constructor, a module, an effect, or that effect's slot); every fresh
binder in the language is lowercase. Consequences:

- `let from = 5` and `handle from = state 100` may coexist; bare `from` is
  the term, `from.get` resolves per 1.5 (label beats projection).
- A term in a label position is E-LABEL: `use h as State` where `h` is a
  first-class Handler VALUE does not install — the diagnostic hints
  `handle State = h in ...` instead.

## 2. One second-class mode

Every binder is classified first-class or second-class. Second-class things:
continuations bound in control clauses, `Suspension`, `Borrow`, `ContCell`, and any
function value that CAPTURES a second-class value (class propagation — see
C2). Capability labels are not terms at all (D9), so capability escape is a
grammar impossibility rather than a mode-check result; the mode guards only
the consuming carriers listed above. One checker enforces one rule:

> A second-class value cannot be returned from the scope that introduced it,
> stored in a constructor, or captured by a closure that outlives that scope.
> Consuming kinds (continuations, Suspensions, ContCells) are additionally
> affine: at most one consumption per path; branches join at max, sequences add.

Escape hatches are explicit, typed operations (`__cont_store` moves a
continuation into a cell; `Bytes.copy` promotes a borrow to owned data).
Consuming carriers are additionally CONFINED (D15): they may not escape the
extent of any `handle` whose label is in their residual row, which is what
makes resume-time label environments always identical to capture-time ones.
A second-class value may be stored only in a LANGUAGE-DEFINED carrier
wrapper (`Step`), which propagates second-classness rather than laundering
it — see D16. User constructors cannot store second-class values (E-KIND).

Defense in depth: effect-instance types have kind `Effect`, not `Type`, so
`[State U64]` or `type H = H (State U64)` is a KIND error before mode checking
runs (see C5).

Multiplicity remains analysis, not annotation. The comma declares a binder's
ROLE (the name after it is the continuation — D25); how many times it is used
stays inferred and checked exactly as today (see C10).

## 3. Diagnostics registry (one renderer)

All violations of section 2 render through one template naming the value, its
class, its binding site, and the violation route. Registry:

| Code | Meaning |
|------|---------|
| E-ARITY | clause pattern count wrong: every clause kind binds one pattern per op argument (counted per position, before destructuring); a control clause (comma head) additionally binds exactly one bare continuation name after the `,`. The count is always checked against the op type — a head with no comma is a plain clause, full stop (D25) |
| E-ABORT | a comma-headed control arm consumes its continuation on no path — the arm is an abort in disguise; write `abort` (D25's totality rule; loses no programs) |
| E-COVER | the pattern clauses for an op do not cover its argument type (no fallthrough exists under labels) |
| E-SHADOW | a continuation's name rebound within its USABILITY REGION — its arm body up to any function-forming boundary, live or dead (D28; beyond a boundary a same-named binder is fresh and legal, which lets the k convention compose across nested handlers) — or a live label re-bound in the same block (delimited inline re-binding of labels is allowed). When a same-region shadow explains a zero- or double-consumption, E-SHADOW preempts E-ABORT/E-AFFINE: the shadow is the enabling edit |
| E-ESCAPE | second-class value returned, stored, or captured by an escaping closure |
| E-AFFINE | affine value consumed twice; reports BOTH sites |
| E-KIND | Effect-kinded type used in a Type-kinded position |
| E-AMBIENT | no row label in scope for a perform or call; same-typed labels are listed as hints, and with exactly ONE type-compatible label in scope the hint is DEFINITIVE (mechanically applicable) — uniqueness powers diagnostics, never meaning (A11) |
| E-LABEL | ROLE-label violations (duplicate label in one row, collision at a composition boundary, a label used as an expression, a term in a label position, a qualifier/label dot collision, a CAPITAL written as the label of a parenthesized row entry — slots have no labeled spelling) and SLOT violations (a capitalized name naming no declared effect = unknown slot; a slot assigned a handler of a different effect = slot type error — P2/D17) |
| E-VARSCOPE | `:=` outside its slot's home; three voices, each naming its repair (D27): no handler frame in scope (mutation in ordinary code goes through an effect: `handle s = state 0` ... `s.set x`), target is a value not a slot (declare `var` — or the var is SHADOWED, shadow site named), or the write crosses a function-forming boundary (lambda, local function equation, handler literal — snapshot the value, or route the write through an op) |
| E-RESERVED | effect declares an op named `once`, `abort`, `return`, or `var` (`once` stays reserved solely to power the v1-migration diagnostic, D25) |
| E-DISCARD | non-final, non-unit line in a block without an explicit `_ =` discard |

Every code has a machine-readable form and a `--explain E-XXXX` entry; every
analysis keeps a dump mode with golden tests (current `--dump-multiplicity`
practice, made a design rule).

## 4. Pressure-test record

<challenge id="C1" summary="Rows are unordered; parameters are ordered — the row-to-params desugaring is incoherent as sketched">
If `with Reader U64 + State U64` desugars to positional implicit parameters,
row reordering (rows are sets) silently changes call compatibility, and
explicit application of a row-sugar function is order-sensitive nonsense.
Also: with capability params, what does today's nearest-handler-wins mean when
two same-typed capabilities are in scope (the sumProd case)?
</challenge>
<response to="C1" status="resolved">
RESOLVED by a three-way trade study (2026-07-21) on what capability
parameters should be. Candidates and killer programs:
(1) POSITIONAL (capabilities as ordinary curried params) — REJECTED.
Killer: `sumProd prod sum xs` type-checks with the arguments swapped and is
silently the wrong program; position carries the meaning and positions are
invisible to types — a silent collapse built into the calculus. Secondary
wounds: partial application smuggles capabilities into closures, and fixing
that pushes the first/second-class split into arrow types (two arrow kinds).
(2) TYPE-KEYED SET (implicit resolution by effect-instance type) — REJECTED.
Killer: a set keyed by type cannot hold two `State U64`; sumProd, the
language's own clincher, becomes inexpressible without per-role newtypes.
Plus the C1-d coherence hazard is intrinsic to type-keyed resolution.
(3) LABELED ROW (set-based, keyed by NAME) — ADOPTED (section 1.3, D9).
Insight: the current effect row is ALREADY a name-keyed set whose key is
forced to the effect head name — which is exactly why two same-typed
instances never fit and named instances arrived as a bolt-on. Generalizing
the key from effect-name to arbitrary label is the minimal change that makes
sumProd a row citizen.
Sub-issue dispositions under the labeled design:
(C1-b) the semantic break shrinks to handles-bound-under-a-non-default-label;
the empirical probe program (`with c = state 7 in amb ()` printing (7, 7))
keeps working by binding the default label explicitly
(`handle State = state 7`, D13), and the role-labeled case fails loudly with
a one-line `use c as State in` hint.
(C1-c) dissolves: labeled rows sit on arrows exactly like today's rows and
defer resolution to application sites — no creation-site capture, no new
lambda semantics, today's dynamic-handling behavior preserved.
(C1-d) dissolves: resolution is by label, and labels are ground even under
type polymorphism.
Residual (accepted): intentional mis-binding (`use b as from, a as to in`)
remains expressible but is visible at the rebind site; no design can check
intent. Same-block label re-binding is an error under D13; delimited inline
nesting is allowed.
</response>

<challenge id="C2" summary="Partial application smuggles capabilities (V4 in disguise)">
`transfer a` is a closure capturing the second-class capability `a`. If that
closure is first-class, storing it in a list exports the capability and every
fence in the design is decorative.
</challenge>
<response to="C2" status="resolved">
Class propagation is a core rule: a function value that captures a
second-class value is itself second-class (may be locally applied and passed
DOWN, may not be returned, stored, or captured by an escaping closure). This
single rule guards continuations, capabilities, Suspensions, and Borrows
through closures, partial application, and handler literals uniformly.
Prior art: Osvald et al. second-class values; Effekt blocks. The current
compiler already behaves this way piecemeal (closure capture of k promotes to
many-use; carriers have a capture wall) — the rule unifies it.
(Labeled-row amendment, D9: with capabilities out of term space, this rule's
remaining subjects are the consuming carriers — continuations, Suspension,
Borrow, ContCell — and closures over them. See reject/05.)
</response>

<challenge id="C3" summary="Bare op names in handler literals are ambiguous, and clause keywords collide with op names">
Two effects can declare the same op name, so `handler` with bare `get -> ...`
clauses cannot resolve its effect without a signature; and an op named `once`,
`return`, or `var` breaks clause parsing.
</challenge>
<response to="C3" status="resolved">
`handler E` names its effect mandatorily; clauses resolve against E's
declaration and E is checked against any `Handler E a b` signature (helpful
redundancy). `once`, `return`, `var` are rejected as op names at effect
declaration (E-RESERVED). (C13 adds `abort` to the reserved set.)
</response>

<challenge id="C4" summary="What baton value does a stored or late resume see?">
With `:=` replacing two-arg resume, a `once` clause may update a baton and
also store or hold its continuation; the order of writes versus resumption
must be defined or parameterized handlers are unsound under M3 storage.
</challenge>
<response to="C4" status="resolved">
Frame-state semantics: the baton is mutable state of the handler ACTIVATION.
Reads in clause bodies see writes in evaluation order; a resumption (immediate
or via a stored continuation) re-enters the activation and sees the latest
write. This is the param-in-frame variant, which the 4a slice already
established as the one that composes (the baton-threading encoding does not).
`:=` outside the declaring handler's clause bodies is E-VARSCOPE.
</response>

<challenge id="C5" summary="(c : State U64) collides with lowercase type variables in parenthesized types">
`(a -> b)` has lowercase TYPE variables in parens; `(c : State U64)` has a
lowercase TERM binder. Same opening context.
</challenge>
<response to="C5" status="resolved">
Superseded by D9: capability parameters no longer appear in arrow chains, so
the `(c : EffType)` named-parameter production is removed and the collision
vanishes entirely. Labels live in the `with` row, whose grammar has no
overlap with parenthesized types. The Effect kind and its E-KIND fence
remain (effect-instance types cannot appear in Type-kinded positions such as
constructor fields); the kinded Ty representation already merged in the
current compiler supports the new base kind cheaply.
</response>

<challenge id="C6" summary="The dot is three-ways overloaded and this collision class already produced a shipped bug">
`State.set` could be module-qualified name, ambient perform, or (for a record
receiver) projection; the current compiler needed a review fix
(qualifier-wins-in-application-position) for exactly this family.
</challenge>
<response to="C6" status="resolved">
Resolved in 1.5, HARDENED after review: when a dot receiver is both an
import qualifier and a label in scope, the collision is E-LABEL (an error,
not silent precedence) — a like-named import must never silently capture
ambient performs, which would be a compile-succeeds silent collapse in a
design whose goal is eliminating that class. With no collision the order is
qualifier > label > projection.
</response>

<challenge id="C7" summary="If capabilities replace rows, why do rows still appear in the spec?">
Capability capture makes most higher-order code row-free, but stored control
(Suspension, ContCell, thunks passed to start) crosses scope boundaries where
capture-based reasoning dies.
</challenge>
<response to="C7" status="resolved">
Two mechanisms with a stated boundary: capabilities answer WHO PROVIDES an
effect for code that runs inside the provider's scope (all ordinary calls and
HOFs — no rows needed); rows answer WHAT IS STILL PENDING on control that is
stored and resumed elsewhere (`Suspension a b r (row e)`, `ContCell r (row e)`,
`start`'s argument). This is the 4b-prime-prime discovery (residual rows on
Step/Suspension) kept as a first-class design principle rather than a patch.
(Labeled-row amendment, D9: rows are now the universal mechanism —
capability rows on arrows state WHO PROVIDES, discharged per call; residual
rows on stored control state WHAT IS PENDING, discharged at resume under
confinement (D15). The "no rows needed" phrasing above described the pre-D9
term-level-capability design and no longer holds.)
</response>

<challenge id="C8" summary="once binders are positional; naming the argument k and the continuation f is a legal different program">
The S1 collapse is closed by declared arity, but binder MEANING is still
positional; adversarial naming can mislead a reader.
</challenge>
<response to="C8" status="resolved">
AMENDED 2026-08-04 (original resolution below, kept for the record). The
original response rejected a separator as "no new information beyond
position" — that was wrong about what the information is. The clause head
borrows APPLICATION syntax (`once ask q k` reads as `ask` applied to two
things), and application syntax carries a contract every ML reader has
internalized: binder count = type arity. The head breaks that contract in
exactly one slot, marked only by the leading keyword. Evidence (all run
against the retrofit build, 2026-08-04): a user who follows the op type
(`ask : U64 -> U64`, so one binder) is stopped by E-ARITY but the count
riddle "expected 2, got 1" cannot explain itself; `once Ask.ask k q ->
q (k + 1)` — argument named k, continuation named q — compiles and runs;
sharpest, `once Get.get k` binds a name to an op whose type has NO arrows
and runs. The separator carries exactly the missing boundary: WHERE THE
OP'S APPLICATION ENDS. Prior art agrees — the two mainstream designs that
also refuse a magic resume both split the slot visibly: OCaml (the 5.3
deep-handler syntax; grammar `effect pattern , value-name` — the
continuation slot is a value-name, never a pattern, the same asymmetry as
D14's rule, and the manual's own `| effect Yield, k ->` is the nullary
shape verbatim) and Unison (`{ ask q -> k } -> ...`).

Separator spellings, enumerated:
(1) COMMA — ADOPTED: `once ask q, k -> e`; nullary `once get, k -> e`.
OCaml's choice. Unambiguous in head position (a bare top-level comma cannot
begin a tuple pattern — tuples are parenthesized). Keeps the head shape
UNIFORM across clause kinds: the op application is spelled identically in
plain (`ask q`), `abort` (`abort ask q`), and `once` (`once ask q, k`)
heads — the separator appears exactly where, and only where, a
non-argument binder exists. Left of the comma, binder count = op arity
again, for every clause kind without exception.
(2) BAR (`once ask q | k -> e`) — REJECTED: `|` imports two wrong ML
priors at precisely this position — or-patterns (`q | k` reads "pattern q
or pattern k") and guards (`| k` reads "when k") — the D10 finding
(familiarity as liability) applied to punctuation; it also collides
visually with sum-type declarations.
(3) PARENS (`once (ask q) k -> e`) — REJECTED: closing the application
visibly is honest (OCaml parenthesizes too), but it breaks head-shape
uniformity across kinds (plain arms are unparenthesized), adds ceremony on
nullary ops (`once (get) k`), and OCaml still needed the comma anyway —
parens alone leave `k` adjacent to the group, one token from the illusion
returning.
(4) DOT (`once ask q . k -> e`) — REJECTED on four grounds. Register: every
existing dot means access-into-a-namespace, the token this design has spent
the most hardening on (1.5 exists to arbitrate its three readings; C6
records the shipped bug) — a fourth reading for dot against a first
separator job for comma. Prior: the ML tradition's binder-separator dots
(`λx. e`, `forall a. t`) both mean "binders end here, the BODY follows" —
but what follows this dot is another binder; the dot would import a native
prior and betray it. Lexical: the dot is whitespace-sensitive — `q.k`
without spaces lexes as a dotted name and lands in exactly the 1.5
ambiguity (Haskell's composition-vs-module-access wart, imported on
purpose); `q,k` and `q , k` are the same token stream. Visibility: the
separator's job is to be seen; the dot is the smallest glyph in the font.

E-ARITY consequently renders as two crisp messages instead of one riddle:
argument-count-wrong (left of the comma, checked against the op type) and
missing-continuation (a `once` head with no `,`). One code, two voices.

RESIDUAL, still accepted: the separator fixes the STRUCTURAL illusion, not
the names — `ask k, q -> ...` remains legal with misleading names,
though the comma now marks q as the continuation regardless of what it is
called. The naming lint remains the recorded mitigation; E-SHADOW was
unchanged by this amendment (later refined to the usability region —
C15/D28). Original resolution (superseded on the separator, standing on
the rest): magic binder name rejected (reverses the settled
no-magic-resume decision); arity check plus E-SHADOW plus convention (last
binder named k) judged sufficient.

SECOND AMENDMENT (D25, owner decision, 2026-08-04): with the comma
adopted, `once` paid the classification bit twice — a comma head cannot be
a plain arm, so the keyword was redundant for classification. The
edit-distance defense of the redundancy is closed instead by
ABORT-TOTALITY (E-ABORT): a comma arm must consume its continuation on at
least one path, which guarantees every comma arm's body references `k`, so
deleting `, k` always leaves an unbound name. The keyword is CUT; the
comma is the sole classifier. See D25 for the full case analysis and the
priced costs.
</response>

<challenge id="C9" summary="Are handler values first-class or second-class? The sketch used both">
`state : s -> Handler ...` RETURNS a handler (first-class use); but handlers
relate to capabilities, which are second-class.
</challenge>
<response to="C9" status="resolved">
Split cleanly: a Handler is a first-class VALUE (a recipe: clause table +
baton initializers) — storable, returnable, selectable at runtime. A
capability is the second-class HANDLE to an activation, created only by
`handle`. A handler literal that captures a second-class value becomes
second-class by C2's propagation rule, so the split introduces no hole.
</response>

<challenge id="C10" summary="Does the once keyword violate the RULES (no surface annotation, inference alone)?">
The one-shot law is enforced with no surface annotation today; `once` looks
like an annotation.
</challenge>
<response to="C10" status="resolved">
`once` declares binder ROLE (which name is the continuation), not multiplicity.
The affine discipline — at most one use per path, branches max, sequences add,
capture and aliasing conservatively rejected — remains fully inferred and
checked by the same analysis. No clause gains a multiplicity annotation;
auto-resume clauses are unchanged. What `once` buys is that the checker's
findings can be reported against a declared fact with a position, closing the
S1/S2 silent-collapse class that pure convention allowed.
</response>

<challenge id="C11" summary="The direct-style Search sketch violates the one-shot law">
`s.choose : [a] -> a` as an effect op is multi-shot if its handler resumes per
element — the original sketch was illegal under the RULES it claimed to serve.
</challenge>
<response to="C11" status="resolved">
Retracted. v1 ships Search as a combinator library (the list-monad encoding,
packaged and documented as the paved road). Direct-style choose is possible
only via replay semantics (re-run the computation once per path with a
decision log; each run resumes nothing twice, so the law holds at re-execution
cost). Replay is recorded as Q1, not promised. (Since resolved: D21 ships it as a
fenced library.)
</response>

<challenge id="C12" summary="Eliminate the `var` baton line by mutating the captured parameter">
The parameterized-handler boilerplate (`var cur = init` then `cur := x`)
looks removable: mutate `init` directly in the arms and drop the var line.
Raised during the var pressure test (2026-07-22).
</challenge>
<response to="C12" status="resolved">
Rejected: the `var` line is the visible PER-ACTIVATION COPY POINT, and the
double-install exploit shows what removing it breaks. Handler values are
first-class (C9), so one value installs many times:

```
state init = handler State
  get      -> init
  set x    -> init := x
  return v -> (v, init)
main =
  let h = state 0
  let (x, s1) = (handle h in State.set 1)
  let (y, s2) = (handle h in State.get)
  (s1, s2)
```

Shared `init` binding yields (1, 1) — state leaks across activations of one
value; with `var cur = init` each activation copies: (1, 0). Repairing
parameter-mutation requires an implicit per-activation copy — `var` made
invisible, an apparent-vs-actual semantics divergence (the E.3 class).
Related rejections: var-elision sugar and `become`-style self-replacing
handlers (rejected.md A7/A8). Frame-state semantics (C4) plus the visible
var stand; one-shot makes the slot uniquely owned (rc==1), so the backend
compiles it to in-place update, and contified tail-resumptive handlers to a
stack slot or register. Mutability ceremony is proportional to use:
immutable captures need no var (`reader e = handler Reader ask -> e`).
Conformance twin: examples/accept/09-activation-independence.wok pins
(1, 0).
</response>

<challenge id="C13" summary="once quietly covers two promises; the never-resuming clause wears a mandatory dead binder">
The clause-kind family (C3/C8/C10) declares WHO takes the continuation, but
not the sharpest fact a handler can know about it: that it is never called.
The canonical citizen is `except`'s clause, `once throw e k -> Err e` — `k`
is bound, dead, and MANDATORY, because E-ARITY forces a binder the body must
then never use. "Trust me, I do not resume" is a convention the surface
cannot state and the checker cannot hold anyone to — the S1-family shape
this redesign exists to kill, sitting in its own flagship prelude. Worse:
for a `Never`-returning op the binder is dead BY TYPING (`k`'s argument type
is uninhabited, so `k` cannot be applied), making the mandatory spelling
actively misleading. Raised by the retrofit review (2026-08-03), which
shipped once/return and immediately re-created the dead binder in every
migrated aborting arm.
</challenge>
<response to="C13" status="resolved">
ADOPTED as a third clause kind (D24): `abort op p1 p2 -> e`. Trade study:

(1) STATUS QUO (`once` covers 0-and-1) — REJECTED. The dead binder is a
lie-shaped obligation: the surface REQUIRES writing a capability the clause
must not exercise. Every argument that justified `once` over binder-counting
(a declared fact the checker can hold the program to, C10) applies verbatim
to never-resumes over trust-me.
(2) INFER abortness from the op's return type (`throw : e -> Never` implies
no resumption) — REJECTED, ledger entry A12. Killer: abortive handling of a
RESUMABLE op is a per-handler choice inference cannot see (a timeout handler
aborting `tick : U64 -> U64`); and kind-by-inference for some clauses,
kind-by-keyword for others re-opens the reconstructed-by-analysis register
this spec exists to close. The type-level fact is not wasted: a `once`
clause for a `Never`-returning op binds a continuation typing has already
killed — a candidate for the C8 naming lint, never an error (D2).
(3) `abort` KEYWORD — ADOPTED. What it buys: the dead binder disappears;
the promise is enforced BY CONSTRUCTION (no continuation name is in scope,
so no new E-code, no new analysis — cheaper enforcement than E-SHADOW's
traversal); the runtime gains a static fact — an all-abort op needs no
materialized continuation, so dispatch may unwind directly (capture elision;
the M2b abort-free owned-set path becomes statically selectable instead of
dynamically discovered); and intent gets a diff line — a clause that starts
resuming must change its declared kind visibly. Prior art wanting exactly
this fact: Koka's `final ctl`; OCaml's requirement that a dropped
continuation be explicitly discontinued.

Costs, accepted: one more law word in D1's budget; a third kind to teach;
and the promise is CLAUSE-level, not path-level — a conditional abort
(`op x, k -> if p then k x else fail`) stays a control clause, and a
zero-use path inside a control clause remains legal and inferred (D2
unchanged; D25's E-ABORT fires only when NO path consumes).

Closure against the clause-kind-zoo objection: under the one-shot law a
continuation's declarable disciplines are exactly {exactly-zero, at-most-
one, tail-exactly-one} = {`abort`, `once`, plain}. "Exactly once"
(must-resume) is not statically checkable without totality reasoning and is
deliberately absent; more-than-once is against the law (NG3). The kind set
is CLOSED — there is no fourth keyword to slide toward. Koka's larger zoo
(`raw ctl` etc.) exists to serve multi-shot, which wok forbids.

D14 interaction: the clauses of one op must agree on plain vs control;
control and `abort` clauses mix per op (pattern-refuted aborts are
legitimate: abort on `Fatal m`, resume otherwise). A mixed group desugars
to a single control clause; the abort-originated branches cannot touch the
merged continuation because hygiene never binds it in their bodies — the
promise survives desugaring by construction. An all-abort group desugars
to an `abort` clause and keeps capture elision.

Semantics: identical to today's non-resuming control arm — the clause
body's value is the handle-expression's answer directly; `return` does not
run on that path (`except` yields `Err e`, never `Ok (Err e)`); baton reads
see the latest write (C4) and the activation then tears down. Nesting
observability (1.2, D18b) is unchanged — `abort` is the keyword for the
semantics the spec already calls "abort".

NAMING: `abort` over `final` (Koka's word imports finalizer semantics wok
does not have), over `never` (states a negation, not an act), over `stop`
(states neither), over reusing `return` (the nullary-op collision makes
classification name-dependent — the strongest rejected spelling; A14). Fourth application of the D10 finding: the spec's own
prose already uses "abort semantics" as the observable that orders handler
nesting — the keyword adopts the document's vocabulary.

Conformance twins: accept/10-abort-except.wok (the runner, dead-binder-free)
and reject/12-abort-binds-continuation.wok (the mechanical mis-migration —
keyword swapped, dead binder kept — dies E-ARITY).
</response>

<challenge id="C14" summary="`:=` is unexplained: why can a clause body mutate when a bare function body cannot?">
Raised in the parser-prep review (2026-08-04). E-VARSCOPE states WHERE
`:=` is illegal but the spec never derives WHY; "lexically enclosing
handler" is also imprecise — it does not decide a write under a lambda
inside a clause body, nor a write from an inner handler literal targeting
an outer baton (first-class handler values, C9, make the latter an
escaping mutable reference). And the obvious repair — allow `var` in any
function body, Koka-style — was never trade-studied.
</challenge>
<response to="C14" status="resolved">
Resolved by the MUTATION PYRAMID plus write-locality (D27), with a
scoping repair for the non-mutating case (D26). The explanation has three
layers, one per fence. TYPES: `:=` appears in no effect row, and may be
invisible ONLY because a write can never leave its activation — widen the
scope one inch and it owes a row entry, and the construct that owes a row
entry already exists (State). SEMANTICS: a write needs an owner whose
lifetime brackets it; bare function bodies own values, not slots; only
activations own frames. MACHINE: one-shot makes the frame rc==1, so `:=`
is one in-place store; any wider scope needs a heap cell, which is what
State visibly provides. Slogan (the --explain text): `=` names a value,
forever; `:=` updates a slot; slots live only in handler frames;
everything else mutates through an effect you can see in the type.

Function-local `var` (Koka-style) — REJECTED, ledger A13. The three-case
analysis: (a) straight-line rebinding is the only case where it wins, and
D26 covers it with no mutation at all; (b) loops need lambda capture, and
a soundly tracked mutable capture IS the State effect (Koka's own `var`
is sugar over a local state row entry); (c) untracked capture is unsound
— A13's `counter` mutates behind a pure type. Empirical push: the rebind
idiom is BROKEN on the current compiler — `let x = 1 in let x = x + 1 in
x` dies with a RUNTIME `UnboundVar "x"` (recursive local let groups; the
baton-named variant dies identically), recorded on the v1 backlog — so
the gap D26 repairs is real, and today's only working spelling is
hand-written SSA (`off0`/`off1`/`off2`).

Probed on the current compiler (2026-08-04): fresh-name lets read batons
fine; a baton SHADOWS an enclosing `let` of the same name — the frame
slot is the innermost binding in clause bodies, now normative (D27); the
self-named shadow falls into the recursive-let hole above.
</response>

<challenge id="C15" summary="Strict E-SHADOW punishes the k convention it depends on: nested handlers cannot both name their continuation k">
The strict rule (any rebinding of a continuation's name anywhere in its
arm, delimited or not) and C8's convention (name the last binder k) are
in tension: handlers compose by NESTING, and both composition shapes were
probed rejected on the retrofit build (2026-08-03) — a nested handler's
own continuation named k dies ContinuationShadowed, and so does an
unrelated lambda binder `\k -> k + 1` whose k is a U64 with no
continuation anywhere near it. Following the convention at two nesting
levels is a compile error; the fence and the convention cannot both stand
as written. The bundle was also internally misaligned: P1 said
strict-everywhere while reject/03's own EXPECT prose said "shadowed WHILE
UNCONSUMED" — a liveness rule the spec never adopted.
</challenge>
<response to="C15" status="resolved">
Resolved by scoping the fence to USABILITY (D28), in D27's boundary
vocabulary. The insight: beyond a function-forming boundary (lambda,
local function equation, handler literal), the outer continuation is
UNUSABLE anyway — capture is conservatively rejected (C10), so a
same-named binder there can mask nothing legal; it is a fresh
declaration, ordinary scoping. Within the region, the name stays frozen
for the WHOLE arm, live or dead. Pure liveness ("frozen only until
consumed") was considered and rejected on a killer: consume-then-shadow
(`let a = k 1 in let k = f in k 2`) silently absorbs a double-resume
attempt that must surface as E-AFFINE — the shadow converts a law
violation into a legal different program, S2's own trick replayed after
consumption. So the region rule keeps both S2 directions loud while both
probe shapes become legal, and the k convention composes at every
nesting depth (accept/12). Diagnostic precedence: when a same-region
shadow explains a zero-consumption (E-ABORT) or double-consumption
(E-AFFINE), blame the shadow — it is the enabling edit, and "write
abort" would be the wrong repair. COUPLING INVARIANT: the exemption is
sound exactly because capture is rejected; if closure capture of
continuations is ever relaxed, the shadow fence must extend to wherever
the usability fence moves. The v1 retrofit keeps its strict traversal
(shipped, corpus-clean — the strictness costs nothing until nested-k
code exists); adopting D28 there is an optional follow-up, not a defect.
Twins: accept/12-nested-handlers-k.wok (both continuations named k, plus
the U64 lambda binder) and reject/14-shadow-after-consume.wok (the
consume-then-shadow killer); reject/03 re-voiced to the region rule.
</response>

## 5. Decisions

<decision id="D1">Keyword budget, one meaning each: `with` appears ONLY in
type rows; `handler` builds a value; `handle` installs; `use` bridges named to
ambient; `abort`/`return`/`var` are clause heads (C13 added `abort`; D25 cut
`once` — the control clause is comma-classified); `:=` updates batons.
Rationale: the current `with` carries four meanings; greppability and
agent-legibility demand one-keyword-one-concept.</decision>
<decision id="D2">The one-shot law and multiplicity-as-analysis are kept
verbatim. This spec changes reporting and declaration, never enforcement
strength.</decision>
<decision id="D3">Handlers are data; capabilities are activations (C9).</decision>
<decision id="D4">Effects have their own kind. Kind errors are the first fence,
mode checking the second, affinity analysis the third (C5).</decision>
<decision id="D5">All second-class/affine violations render through one
template with binding site, class, and route; every code has --explain and
every analysis a golden-tested dump mode (section 3).</decision>
<decision id="D6">The examples directory doubles as the future conformance
suite: accept/ files state expected output, reject/ files state expected
diagnostic code and blamed binder, mirroring test/multiplicity-examples/
practice.</decision>
<decision id="D7">Answer types are explicit in Handler types. Rationale: the
resume-binder-type leak and the value-position multiplicity false positive
were both disagreements about an implicit answer type; a spelled type leaves
that disagreement nowhere to live.</decision>
<decision id="D8">Coroutine surface (Step, Suspension, start/step/run/cancel)
is primitive, with residual rows in its kinds per C7 — the endpoint of slices
4b through 4c adopted as an axiom. `Step` is the sole carrier wrapper
(D16).</decision>
<decision id="D9">Capability parameters are SET-BASED KEYED BY NAME (labeled
rows), not positional and not type-keyed — see C1 for the trade study.
Corollary: labels are not expressions; a label appears only as a dot
receiver (`from.get`) or in `use ... as`. Capabilities therefore never exist
as first-class terms, making capability escape grammatically inexpressible
rather than mode-checked, and shrinking the second-class mode's duties to
consuming carriers and closures over them.</decision>
<decision id="D10">Surface tone principle (full design: surface.md). Two
keyword registers: ML SKELETON (conventional words on familiar ground —
module, type, class, let, case) and LAW WORDS (wherever wok's discipline
departs from ML, the keyword states the promise — once, handle, use, var,
own, lend). Metaphor register rejected: unsearchable, agent-unpredictable,
states no law. Surface allegiance stays Haskell-flavored layout ML; the
current examples are demoted from syntax law to semantic oracle (expected
outputs are the regression anchor).</decision>
<decision id="D11">Block sequencing with an explicit-discard law. An indented
block is a sequence: `let`/`handle`/`use` become statements scoping over the
rest of the block; unit-typed lines sequence freely; the final line is the
value; discarding a non-unit value requires `_ = e`, else E-DISCARD (an
error). Kills the `let u = ... in` dummy-binder wart in every effectful
file; nothing is dropped silently, mirroring the runtime's counting of every
value. Inline `let/handle/use ... in` forms remain.</decision>
<decision id="D12">Lexical repairs enabled by surface freedom: `::` is an
expression as well as a pattern; `type`/`alias` replace `data`/synonym
forms; effect and class declarations are layout-uniform (no brace-record
form); `Ord` with comparison operators ships via the existing dictionary
machinery. Everything not listed in surface.md's wart ledger is deliberately
unchanged — repeated pressure tests converged back to the current surface.</decision>
<decision id="D13">(P1 instance — see 1.0; retained for its motivating
record.) Anonymous handles are FORBIDDEN: every `handle` writes its
label (resolves former Q2). Default labels survive in ROW TYPES as the
canonical Schelling point (`with State U64`, a slot obligation needing no
written label);
serving ambient code means binding the effect head name explicitly
(`handle State = state 0`). Shadowing collapses to one uniform rule (1.2):
re-binding a live label in the same block is E-SHADOW; delimited inline
re-binding is allowed. Rejected variant: also dropping default labels from
rows (full label-explicit style) — label names would enter every public
interface with no canonical choice, turning cross-library composition into
rename negotiation; the default label is the coordination point. Costs
accepted: install-site ceremony (the label restates what the handler type
implies — greppable redundancy) and a weaker "current surface is the special
case" convergence (ports gain a mechanically derivable label). REFINED after
the runner-idiom review (accept/07): the mandate is TWO-TIER — statement-form
handles (invisible extent) must write their label; delimited inline handles
(`handle h in body`) may elide it, defaulting to the effect head, because
the extent is visible and the provider is adjacent to its body. The
shadowing rule is unchanged, and the greppability guarantee narrows to
statement-scoped providers — which is what it was about.</decision>
<decision id="D14">Patterns are allowed in op-ARGUMENT positions of handler
clauses (resolves former Q3), defined by desugaring: multiple pattern
clauses for one op elaborate to a single variable-binder clause whose body
is a `case` on the argument (the existing decision-tree machinery;
case-in-arm is proven ground — m3-store-branch). Three rules keep it sound:
(1) E-ARITY counts PATTERNS, one per argument position, before
destructuring; (2) the clauses for each op must COVER its argument type
(E-COVER) — under labels a perform routes to exactly one activation, so a
match failure has no fallthrough; (3) the continuation binder of a control
clause remains a bare lowercase variable, standing after the `,` separator
(C8, amended; D25 made the comma the sole classifier) — argument positions
destructure, the continuation position never does. The `return` clause may
also bind a pattern. Multiplicity is unchanged: after desugaring, per-branch k uses
join at max, as verified empirically (V2).</decision>
<decision id="D15">CONFINEMENT resolves former Q4 (full trace + empirical
certificate: q4-trace.md). A consuming carrier (Suspension, ContCell) may
not escape the extent of any `handle` whose label appears in its residual
row; within the extent, capture-site and resume-site label environments are
the same live activations, so residual performs — the continuation's own and
those of deep-re-installed handler arms — always find their providers
(arm-origin obligations are covered because arm rows COMPOSE into the
carrier's residual row; certified empirically, q4-trace addendum). The
"renamed environment" and "dead activation" cases are statically unwritable
(verified: CarrierEscape / RowMismatch / UndischargedEffect on the current
compiler). v2 routing: a carrier crossing a needed handle's extent is
E-ESCAPE; resuming with no provider in scope (the p3 shape) is E-AMBIENT per
the registry; the p5 shape (empty residual row crossing an unrelated
boundary) may lawfully be ACCEPTED — an implementation that keeps the
rejection renders it as E-ESCAPE. Lexical-vs-late-bound label binding is
unobservable — confinement makes the question vacuous. The M2b owned-set RC
discipline needs no extension. Named ceiling, out of v2 scope:
cross-environment resumption (schedulers) is the answer-decoupling epic; the
late-bound design sketch for that day is retained in q4-trace.md.</decision>
<decision id="D16">CARRIER WRAPPERS (closes the Step exemption gap found in
review). A second-class value may be stored only in the fields of a
LANGUAGE-DEFINED carrier wrapper — today exactly one, `Step`, whose
`Suspended` constructor carries a Suspension (D8). A wrapper does not
launder: Step is STATICALLY second-class regardless of which constructor it
dynamically holds (class cannot depend on runtime shape), confined exactly
as its payload (D15). Its travel rule is pinned empirically (q4-trace
addendum): born only from the language-defined producers (`start`/`step`,
extern trust anchors), eliminated by `case` in the scope that received it —
even a one-layer user relay returning it is rejected, as is storage in a
tuple. Eliminating it by `case` re-binds the payload
into the arm (the arm-bound-tail design). User constructors cannot store
second-class values: fields are Type-kinded (E-KIND) and closures over them
stay second-class by propagation (C2). This is why accept/05 is legal and
reject/05 is not.</decision>
<decision id="D17">(P2 instance — see 1.0; the rule below is now DERIVED by
slot name-resolution and slot typing, retained for its motivating record.)
LABEL REGIMES ENFORCED (guardrail on effect-head labels).
A capitalized label must name a declared effect in scope (aliases resolving
to effect instances count), and binding it — `handle State = h` or
`use g as State` — requires the bound activation's effect head to match,
E-LABEL at the binding site otherwise. Motivating counterexample:
`handle State = double` with `double : Handler Tick a a` was previously
legal and failed only at a distant resolution site — or never, if nothing
performed through it: a deceptive binding wearing the most trusted name in
the file. The rule moves blame to the declaration, catches label typos
(`handle Stat = state 0` dies at the binding instead of surfacing as a
faraway E-AMBIENT), and turns effect-head labels into CHECKED type
annotations: in `f h = handle State = h in ...` the label constrains h's
inferred type to Handler (State t) a b. Lowercase role labels remain free
(any effect); the elided inline form conforms by construction. Zero
breakage across the conformance examples.</decision>
<decision id="D18">RULES-LAYER REFACTOR (axioms to principles), zero surface
change: the binding rules are generated by P1 (visibility) and P2 (roles
and slots) in section 1.0; D13 and D17 are retained as worked instances
with their motivating counterexamples intact. Two couplings were examined
and deliberately NOT dissolved, being essential rather than incidental:
(a) `handle` is the unique converter between the value tier and the
activation tier — two orthogonal spaces must meet at exactly one operator;
(b) answer shapes nest in install order because handler order is observable
in abort semantics — flattening would require handlers to commute, which
only special pairs do, and a commuting-subset rule would be a worse
coupling than the one removed. Litmus for the refactor: every former "why"
about a binding rule is answered by instantiating a principle rather than
citing a decree — including questions the old rules never addressed (why
`use` targets are never elidable: a rename is information, not
derivable).</decision>
<decision id="D20">Labeled row entries are PARENTHESIZED, mandatorily:
`with (from : State U64) + (to : State U64)`; default entries stay bare
(`with State U64 + Except String`). Rationale: the bare labeled form has a
colon-extent readability problem — `State U64 + to` momentarily parses as a
type expression before the reader backtracks; parens make each entry
self-delimiting for reader and parser alike, and `(name : Type)` is
established ML-family binder punctuation. Mandatory rather than optional:
two legal spellings of one row is the redundancy this design refuses. Note:
this re-scopes former C5's lowvar-colon disambiguation to row-entry
position only — far narrower than the retired arrow-chain production.
Surface punctuation only, zero semantic change; requested in owner
review.</decision>
<decision id="D21">REPLAY SEARCH SHIPS AS A FENCED LIBRARY (resolves former
Q1, option b). `Search.replay : (() -> a with Search) -> [a]` where
`effect Search` declares `choose : [a] -> a` and `require : Bool -> ()`, and the
thunk's row is CLOSED over exactly Search — no polymorphic tail. The
closed row is the static purity fence that makes replay sound by
construction: re-running the thunk re-performs nothing but Search ops.
Mechanism: a decision-log driver re-runs the thunk once per path; `choose`
auto-resumes with the logged element (tail-resumptive), `require`-failure
drops the continuation (zero-shot) — every run obeys the one-shot law, so
this is a PURE LIBRARY over legal handlers, no new primitives. The cost
model is documented, not hidden: shared prefixes are re-executed per path
(worst-case exponential redundancy versus shared-prefix multi-shot); the
combinator road (nondeterminism.wok's list monad) remains the paved path
for cost-sensitive search. NAMING: `Search`/`choose`/`require` over
`Amb`/`NonDet`/`guard` — the traditional names import the true-multi-shot
shared-prefix prior, which is exactly the wrong cost and resume model for
replay; an unfamiliar-but-plain use-case word prevents the false prior.
Third application of the D10 finding (after `once` over `ctl`):
familiarity is a liability precisely where it teaches the wrong
law.</decision>
<decision id="D23">FORWARD-ONLY DECLARATIONS: a signature must PRECEDE the
equation it describes. `f = 1` followed by `f : U64` is an error; the reverse
is the only legal order. The rule is per declaration BLOCK, so a `where`
binding carries its own signature independently of the top level.

Rationale, in three registers. For a READER: the type is met before the code
it constrains, always, with no scanning back. For the FRONT END: declaration
processing is single-pass — nothing needs a pre-scan to discover a signature
that might appear later. For DIAGNOSTICS: a signature becomes the strongest
resynchronisation anchor available, because `name : Type` at a block column
is unambiguously a fresh declaration and can never be the tail of a damaged
one. That last property is what lets error recovery collapse a misindented
region into ONE fault instead of one per line.

Empirical basis (2026-08-02): across all 642 `.wok` files in the repo, zero
put a signature after its equation. The rule codifies universal existing
practice and breaks nothing; the ordering freedom it removes was never used.

Not adopted: requiring ADJACENCY (a signature immediately followed by its
equation). Ordering carries the reading and single-pass benefits on its own,
while adjacency would additionally forbid grouping a block of related
signatures ahead of a block of definitions, which is a legitimate style with
no trap attached. It remains available if evidence ever demands it.</decision>
<decision id="D22">NO `;`: BLOCK ITEMS ARE DELIMITED BY COLUMNS ALONE.
The item separator is removed from the surface. A layout block's items are
now bounded by indentation and nothing else, so there is one layout rule
instead of a rule plus an escape hatch. A single handler clause may still
share its head's line (`handler Reader ask -> e`); more than one needs the
block. The only `;` in this bundle was one C12 prose line, which was already
non-conforming for a second reason (it used the brace handler form D12
forbids); it is now written as a layout block. `;` is retained in the
diagnostic table of removed lexemes, since it is legal v1 wok that a port
will hit.

RECORDS WERE MEASURED FOR REMOVAL AND KEPT. The question was whether braces
earn their place, since records are their only job (a record type, a record
literal or update, a record pattern) and `{- -}` is a comment the grammar
never sees. Measured over the repo (2026-08-02): of 642 `.wok` files, 164 use
braces, but 143 of those are v1's `effect E = { op : T }` form that D12 had
already replaced with a layout block. Genuine record use is 12 files, ALL of
them tests of the record feature itself — `prelude/`, `examples/` and
`bench/` contain none, and neither do the 20 v2 conformance examples.

Removal was implemented and reverted by owner decision. Recording what it
would have bought and cost, since the measurement is the expensive part:
removal would have deleted the third arm of 1.5's dot resolution, reducing
C6's three-way overload (qualifier / ambient perform / projection) to two
readings, and `..` would have become dead — its only uses are record spread
and open record patterns. It would have cost named-field construction,
row-polymorphic record extension, and a feature already implemented and
tested in the v1 compiler. The half-measure — layout-based record TYPES with
brace literals — is specifically rejected: a record LITERAL cannot be
layout-based (`f Point x = 1` is unparseable) and parens and brackets are
taken by tuples/grouping/row entries and lists, so that path ends at two
spellings of one concept, the redundancy D20 refuses.

Braces therefore stay, confined to records exactly as surface.md section 3
already states.</decision>
<decision id="D19">REJECTED-ALTERNATIVES LEDGER: rejected.md holds the
counterfactual programs — each rejected design written in the syntax it
would have had, exhibiting its failure. Bucket A: added ways to pass or
resolve (positional capabilities, type-keyed resolution, call-site row
binding, as-postfix installs, label polymorphism, parameter-mutation
batons, var-elision sugar, become, singleton auto-designation, brace-record
rows, implicit capability arguments); Bucket B:
removals for uniformity (forbid head-binding, forbid `use ... as`,
inline-only `use`); Bucket C: dissolutions of essential couplings (order-
free answers, tier unification). The bar the ledger enforces: no new
passing or resolution mechanism lands without a program the existing set
cannot express, and no form is removed without a nameable trap it enables.
Newest entry, singleton auto-designation, was rejected by direct P1/P2
instantiation (census-derivable is not derivable; implicit slot
assignment) — the first proposal decided entirely by the principles, D18's
litmus in action.</decision>
<decision id="D24">ABORT CLAUSE KIND (C13's trade study).
`abort op p1 p2 -> e` declares a control clause that never resumes: pattern
count = op arity, NO continuation binder, body typed at answer-out `b`,
`return` clause skipped on that path. The promise is held by construction —
no continuation name exists in the clause — so no new E-code and no new
analysis; enforcement strength is unchanged (D2). The clause-kind set
{plain, control, `abort`, `return`, `var`} is CLOSED under the one-shot law:
exactly-zero / at-most-one / tail-exactly-one are the only declarable
resumption disciplines (must-resume needs totality; multi-shot is NG3).
control/`abort` clauses mix per op under D14's desugaring, hygiene
preserving the abort promise through the merge; an all-abort op licenses
capture elision (dispatch may unwind without materializing a continuation).
Registry amendments: E-ARITY counts `abort` at op arity; `abort` joins
E-RESERVED. A control clause whose op returns `Never` is a lint candidate,
never an error. (D25 later cut the `once` keyword — the kinds and this
decision's content are unchanged; "once clause" reads "control clause",
comma-classified, with never-consuming arms promoted from lint to E-ABORT
by totality.)</decision>
<decision id="D25">THE CONTROL CLAUSE IS COMMA-CLASSIFIED; `once` IS CUT
(second C8 amendment; owner decision 2026-08-04). After the comma
amendment, the keyword paid the classification bit twice — a comma head
cannot be a plain arm. The residual edit-distance defense is replaced by
ABORT-TOTALITY: a comma-headed arm must consume its continuation on at
least one path, else E-ABORT — write `abort`. Totality loses no programs
(a never-resuming control arm IS an abort, one word shorter) and deletes
dead binders from real code. Case analysis, every single-token edit from a
legal arm loud: comma deleted -> plain arm, count vs op type, E-ARITY;
`, k` deleted -> unbound `k` in the body, guaranteed by totality;
`k`-ignoring comma arm -> E-ABORT. The unmarked-kind budget is unchanged:
a comma-less head is a plain arm, full stop — `call k -> k 41` is the
LEGAL argument reading under any design with unmarked plain arms, exactly
as it was with the keyword; declared kinds make the two readings distinct
SPELLINGS (`call f, k` is control), never a guess. Organizing principle
gained: keywords now mark exactly the clauses that hold NO continuation
(`abort`, `return`, `var`); the one clause that holds the future shows it
structurally. C10 survives verbatim — the comma carries the role
declaration; multiplicity stays inferred. Costs, priced and accepted: the
one-shot law loses its surface word (enforced everywhere, written
nowhere); `grep once` loses its meaning; the spoken cue is gone. `once`
remains reserved AT CLAUSE-HEAD POSITION only, to power the v1-migration
diagnostic ("v1 clause keyword; drop it"); the v1 retrofit keeps its
`once`, since without the comma that surface's keyword is its sole
classifier. Closed as moot by this cut: the never-vs-abort family
question (no frequency-word sibling remains).</decision>
<decision id="D26">NON-RECURSIVE VALUE BINDINGS; RECURSIVE FUNCTION
EQUATIONS (C14's repair for the straight-line case). In a block or `let`,
a binding WITHOUT parameters is non-recursive: its RHS reads the
enclosing scope, so `let off = off + 4` is the rebind idiom — a NEW
immutable value shadowing the old (hand-written SSA handed back to the
compiler; the conformance twin pins `(7, (47, 87))`). A binding WITH
parameters is a function equation: recursive, self-visible, grouping with
adjacent equations for mutual recursion (the existing local-group
semantics; "does it have parameters?" is answerable by looking at the
line). Rationale, three independent grounds: strictness makes value
self-reference bottom by construction (knot-tying is a lazy-language
harvest); the one strict-language use — OCaml's static cyclic
constructors, `let rec ones = 1 :: ones` — builds exactly the heap shape
a cycle-collector-free RC runtime must never construct, so the rule
closes a grammar route to cycles (same family as the one-shot law); and
recursive computation already has a home with parameters in it — even a
recursive lambda has the eta spelling (`let f x = ...`). The rule's one
sharp edge is made loud: a VALUE binding whose RHS references its own
binder name is an ERROR with the eta hint ("recursive binding? write
`let f x = ...`"), never a silent capture of an outer same-named
binding.</decision>
<decision id="D27">MUTATION HAS ONE HOME: WRITE-LOCALITY FOR `:=` (C14).
The pyramid: user code mutates through effects (visible in the row);
handler clauses implement effects via frame state (`var`/`:=`); the
machine implements frame state as an rc==1 slot (one store). `:=` is not
an assignment operator — it is the handler's private write to its own
activation frame, and the scope rule is what licenses its absence from
effect rows. WRITE-LOCALITY: the target of `:=` must be a `var` of the
handler whose clause body is the write's nearest enclosing
function-forming construct; lambdas, local function equations, and
handler literals all form boundaries (a handler literal capturing an
outer baton write would be an escaping mutable reference — handler
values are first-class, C9); blocks, `case` arms, and `if` branches do
not. READS crossing a boundary take a snapshot of the current value —
the slot itself never travels, so closures stay first-class and no new
second-class subjects exist. Clause-body name resolution is args ->
batons -> enclosing scope (the baton shadows an outer binding of the
same name; probed, now normative). Composed with D26: `let cur = cur +
1` in a clause body reads the SLOT's current value and shadows it with
an arm-local VALUE for the rest of the body; a later `cur := e` then
targets a value and is E-VARSCOPE with the shadow site named
(reject/13). E-VARSCOPE renders in three voices, each naming its repair:
no-frame-here (mutation in ordinary code goes through an effect —
`handle s = state 0`), target-is-a-value (declare `var`, or the var is
shadowed — site named), write-crosses-a-boundary (snapshot the value, or
route the write through an op of the outer handler). Style lint, not
error: self-named shadowing of a live baton.</decision>
<decision id="D28">CONTINUATION SHADOW FENCE = THE USABILITY REGION
(C15). A continuation binder's name is frozen throughout its usability
region: the arm body up to any function-forming boundary — lambdas,
local function equations, handler literals, exactly D27's list — and the
freeze holds BEFORE AND AFTER consumption. Pre-consumption shadowing is
the S2 zero-use silence; post-consumption shadowing would absorb a
double-resume attempt that must surface as E-AFFINE (the liveness-only
variant was rejected on this killer). Beyond a boundary, a same-named
binder is a fresh declaration and legal: the outer continuation is
unusable there (capture conservatively rejected, C10), so nothing legal
is maskable — this is what lets C8's "name it k" convention compose
across nested handlers, and what legalizes the innocent `\k -> k + 1`.
Precedence: a same-region shadow that explains a zero- or
double-consumption is blamed as E-SHADOW, preempting E-ABORT/E-AFFINE —
the shadow is the enabling edit and its hint (rename) is the true
repair. Coupling invariant: this exemption stands exactly as long as
continuation capture is rejected; relax capture and the shadow fence
must extend with the usability fence. One principle now serves three
rules: D27's write-locality, C10's capture wall, and this fence all draw
the same boundary line — what cannot cross a function-forming construct
cannot be endangered beyond one.</decision>

## 6. Assumptions and open questions

<assumption id="A1">The kinded core type representation extends to a new base
kind Effect without disturbing row kinds (the CType/CRow merge suggests
yes).</assumption>
<assumption id="A2">The unified second-class mode checker can subsume the
duties of today's separate fences (multiplicity capture promotion,
CarrierEscape, the occurs-check and Mismatch accidents) with no loss of
soundness — plausible because every current fence is a special case of the
section 2 rule, but unproven until prototyped.</assumption>

## 7. Examples index (docs/redesign/examples/)

These files use the v2 surface and are NOT compilable by the current wok; each
reject file carries an `-- EXPECT:` line stating code and blamed binder.

accept/
- 01-state-cell.wok — handler value, named handle introducing a row label
- 02-two-cells.wok — two same-typed cells as two row labels (from/to)
- 03-ambient-mtl.wok — default-label rows, labels bound explicitly (the mtl stack)
- 04-generator.wok — control and return clauses, one-shot push generator
- 05-coroutine-pull.wok — primitive Step/Suspension pull surface (differs from current wok only in the unit-pattern head)
- 06-use-bridge.wok — per-call cell designation with inline `use ... as`
- 07-handler-values.wok — handler values selected at runtime AND passed to a function (runTick)
- 08-proto-patterns.wok — pattern clauses per op (D14), protocol-style dispatch
- 09-activation-independence.wok — one handler value, two installs, two independent cells (C12)
- 10-abort-except.wok — abort clause, the Except runner without the dead binder (C13/D24)
- 11-let-rebind-cursor.wok — D26 rebind idiom: non-recursive value lets as compiler-side SSA
- 12-nested-handlers-k.wok — D28: the k convention composes — nested handlers both bind k; a U64 lambda binder k is innocent

reject/
- 01-capability-escape.wok — E-LABEL: capability label used as an expression
- 02-once-arity.wok — E-ARITY: comma-less head is plain, count checked against the op type (D25)
- 03-shadowed-continuation.wok — E-SHADOW: the S2 collapse, now loud
- 04-capability-in-data.wok — E-KIND: effect type stored in a constructor
- 05-closure-smuggle.wok — E-ESCAPE: closure over a Suspension stored in data (C2)
- 06-ambiguous-ambient.wok — E-AMBIENT: no default label; named labels hinted
- 07-assign-outside.wok — E-VARSCOPE: baton update outside its handler
- 08-double-resume.wok — E-AFFINE: sequential double resume, unified voice
- 09-silent-discard.wok — E-DISCARD: non-unit value dropped without `_ =`
- 10-uncovered-op.wok — E-COVER: op clauses miss a constructor, no fallthrough
- 11-effect-label-mismatch.wok — E-LABEL: effect-head label bound to a wrong-effect handler (D17)
- 12-abort-binds-continuation.wok — E-ARITY: abort clause keeps the dead continuation binder (C13)
- 13-write-to-shadowed-var.wok — E-VARSCOPE: shadow-then-write, the shadow site named (D26+D27)
- 14-shadow-after-consume.wok — E-SHADOW: consume-then-shadow would absorb a double resume (D28's dead-name half)

Rejected-design counterfactuals (NOT v2 syntax; documentation, never
conformance) live in rejected.md (D19).

## Appendix: retrofit order for the current wok (guidance, not plan)

Cheapest first, each independently shippable and each closing a probed trap:
1. `once`/`return` clause keywords + E-ARITY/E-SHADOW (closes S1/S2; mechanical
   codemod, op arity known per arm). Shipped 2026-07 without `abort` (C13
   postdates it); `abort` can ride any later slice — mechanical again: every
   migrated `once op ... k ->` arm whose `k` is dead is a candidate.
2. Unified E-ESCAPE/E-AFFINE renderer over the existing checkers (kills the
   five-voice problem; no semantic change).
3. Explicit `Handler` answer types (closes the answer-type disagreement class).
4. `handle`/`use` keyword split (frees `with` for rows only).
5. Capabilities-as-primitive (genuinely from-scratch; do not retrofit — the
   named-instances design already covers the practical need on the current
   compiler).
