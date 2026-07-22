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
is ordinary scoping. A live continuation binder may never be shadowed,
delimited or not — its consumption obligation does not end at a scope
boundary, and `(let k = f in k (k 1))` is the S2 silence with parentheses.
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
  - `once op p1 p2 k -> e` — control clause. Pattern count = op arity + 1;
    the LAST binder is the continuation — an affine second-class function,
    always a bare lowercase variable, never a pattern.
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
continuations bound by `once`, `Suspension`, `Borrow`, `ContCell`, and any
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

Multiplicity remains analysis, not annotation. `once` declares a binder's ROLE
(this name is the continuation); how many times it is used stays inferred and
checked exactly as today (see C10).

## 3. Diagnostics registry (one renderer)

All violations of section 2 render through one template naming the value, its
class, its binding site, and the violation route. Registry:

| Code | Meaning |
|------|---------|
| E-ARITY | clause pattern count wrong: a plain clause needs one pattern per op argument, a `once` clause needs op arity + 1 (patterns counted per position, before destructuring) |
| E-COVER | the pattern clauses for an op do not cover its argument type (no fallthrough exists under labels) |
| E-SHADOW | a live continuation binder shadowed (an error ANYWHERE, delimited or not — P1), or a live label re-bound in the same block (delimited inline re-binding of labels is allowed) |
| E-ESCAPE | second-class value returned, stored, or captured by an escaping closure |
| E-AFFINE | affine value consumed twice; reports BOTH sites |
| E-KIND | Effect-kinded type used in a Type-kinded position |
| E-AMBIENT | no row label in scope for a perform or call; same-typed labels are listed as hints, and with exactly ONE type-compatible label in scope the hint is DEFINITIVE (mechanically applicable) — uniqueness powers diagnostics, never meaning (A11) |
| E-LABEL | ROLE-label violations (duplicate label in one row, collision at a composition boundary, a label used as an expression, a term in a label position, a qualifier/label dot collision, a CAPITAL written as the label of a parenthesized row entry — slots have no labeled spelling) and SLOT violations (a capitalized name naming no declared effect = unknown slot; a slot assigned a handler of a different effect = slot type error — P2/D17) |
| E-VARSCOPE | `:=` target is not a `var` of the lexically enclosing handler |
| E-RESERVED | effect declares an op named `once`, `return`, or `var` |
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
declaration (E-RESERVED).
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
Accepted residual risk. Alternatives rejected: a separator token between args
and continuation (new syntax carrying no new information beyond position); a
magic binder name (reverses the settled no-magic-resume decision). The arity
check plus E-SHADOW plus convention (last binder named k) is judged
sufficient; a naming lint may be added later if evidence demands.
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
  get -> init ; set x -> init := x ; return v -> (v, init)
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
immutable captures need no var (`reader e = handler Reader { ask -> e }`).
Conformance twin: examples/accept/09-activation-independence.wok pins
(1, 0).
</response>

## 5. Decisions

<decision id="D1">Keyword budget, one meaning each: `with` appears ONLY in
type rows; `handler` builds a value; `handle` installs; `use` bridges named to
ambient; `once`/`return`/`var` are clause heads; `:=` updates batons. Rationale:
the current `with` carries four meanings; greppability and agent-legibility
demand one-keyword-one-concept.</decision>
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
match failure has no fallthrough; (3) the continuation binder of a `once`
clause remains a bare lowercase variable — argument positions destructure,
the continuation position never does. The `return` clause may also bind a
pattern. Multiplicity is unchanged: after desugaring, per-branch k uses
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
`effect Search = { choose : [a] -> a, require : Bool -> () }` and the
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
- 04-generator.wok — once and return clauses, one-shot push generator
- 05-coroutine-pull.wok — primitive Step/Suspension pull surface (differs from current wok only in the unit-pattern head)
- 06-use-bridge.wok — per-call cell designation with inline `use ... as`
- 07-handler-values.wok — handler values selected at runtime AND passed to a function (runTick)
- 08-proto-patterns.wok — pattern clauses per op (D14), protocol-style dispatch
- 09-activation-independence.wok — one handler value, two installs, two independent cells (C12)

reject/
- 01-capability-escape.wok — E-LABEL: capability label used as an expression
- 02-once-arity.wok — E-ARITY: the S1 collapse, now loud both ways
- 03-shadowed-continuation.wok — E-SHADOW: the S2 collapse, now loud
- 04-capability-in-data.wok — E-KIND: effect type stored in a constructor
- 05-closure-smuggle.wok — E-ESCAPE: closure over a Suspension stored in data (C2)
- 06-ambiguous-ambient.wok — E-AMBIENT: no default label; named labels hinted
- 07-assign-outside.wok — E-VARSCOPE: baton update outside its handler
- 08-double-resume.wok — E-AFFINE: sequential double resume, unified voice
- 09-silent-discard.wok — E-DISCARD: non-unit value dropped without `_ =`
- 10-uncovered-op.wok — E-COVER: op clauses miss a constructor, no fallthrough
- 11-effect-label-mismatch.wok — E-LABEL: effect-head label bound to a wrong-effect handler (D17)

Rejected-design counterfactuals (NOT v2 syntax; documentation, never
conformance) live in rejected.md (D19).

## Appendix: retrofit order for the current wok (guidance, not plan)

Cheapest first, each independently shippable and each closing a probed trap:
1. `once`/`return` clause keywords + E-ARITY/E-SHADOW (closes S1/S2; mechanical
   codemod, op arity known per arm).
2. Unified E-ESCAPE/E-AFFINE renderer over the existing checkers (kills the
   five-voice problem; no semantic change).
3. Explicit `Handler` answer types (closes the answer-type disagreement class).
4. `handle`/`use` keyword split (frees `with` for rows only).
5. Capabilities-as-primitive (genuinely from-scratch; do not retrofit — the
   named-instances design already covers the practical need on the current
   compiler).
