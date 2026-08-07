---
spec: retrofit-item4-callback-runner-migration
status: draft
---

# Item 4: migrating the prelude callback-runners to handler values

## Context

Retrofit item 4 in `docs/redesign/spec.md`'s appendix is "the `handle`/`use`
keyword split (frees `with` for rows only)." This spec scopes the part of item 4
that touches the four prelude runners in `prelude/Std/Control.wok`:

```
reader e c = with self = Reader { ask -> e } in c self
state  i c = with self = State  { var s = i ; get -> s ; once set x k -> k x () ; return v -> (v, s) } in c self
writer   c = with self = Writer { var log = [] ; once tell w k -> k (log ++ w) () ; return v -> (v, log) } in c self
except   c = with self = Except { once throw e k -> Err e ; return v -> Ok v } in c self
```

Each fuses THREE jobs into one expression: build a handler (the arms), name it
(`self`), and install it while handing the handle to a body callback (`c self`).
The v2 endpoint (`docs/redesign/examples/accept/01-state-cell.wok`) splits them:

```
state : s -> Handler (State s) a (a, s)
state init = handler State
  var cur = init
  get      -> cur
  set x    -> cur := x
  return v -> (v, cur)
```

`handler` BUILDS a value; the caller writes `handle st = state 0 in body` to
INSTALL it; the callback is gone.

The redesign bundle never analyzes this migration. It shows the endpoint but
never quotes the `EWithNamedH` construct, never states that the four runners
lose their callback, and gives no reject example for the argument-position case
this closes. This spec fills that gap.

### The load-bearing fact

Current wok has **no first-class handler values**. Verified empirically:

- `Handler E a b` as a type is `UnknownTyCon "Handler"`.
- Every handler-block grammar production requires a trailing computation:
  `EWith … Exp`, `EWithH … Exp`, `EWithNamedH … "in" Exp`. A handler block
  cannot stand alone as a value.

So `with self = E { ... } in c self` fuses build and install PRECISELY BECAUSE
a handler cannot exist on its own to be passed around. The core of this
migration is therefore not a surface respin — it is the D3 "handlers are data"
capability: a `Handler` type, standalone handler values, and a `handle`
installer that consumes one. The keyword split rides on top of that.

## What "migrated" means concretely

For each of the four runners:

1. Type changes from a callback-taker to a `Handler`-returner. `state`'s
   `s -> (State s -> a with State s + eff e) -> (a, s) with eff e` becomes
   `s -> Handler (State s) a (a, s)`. The callback parameter and its residual
   row plumbing vanish from the interface.
2. Body changes from `with self = E { ARMS } in c self` to `handler E { ARMS }`.
3. Every call site changes from a callback application to a `handle`
   installation (see D4 for the two forms).

## Non-goals

<non_goal id="NG1">Capabilities-as-primitive (retrofit item 5). The spec appendix says do NOT retrofit it; these runners are ordinary library functions returning handler values, not a new primitive.</non_goal>

<non_goal id="NG2">Statement-form `handle` and block sequencing (D11). This spec uses only the delimited inline form `handle [l =] h in body`, which has an explicit `in` and needs no layout change. Statement-form handles (`handle State = state 0` as a bare block statement, accept/03) are a separate item.</non_goal>

<non_goal id="NG3">The full v2 label/role/slot system (D9/D13/D17/P2) beyond the minimum a runner call site needs. Two-vocabulary `use ... as` bridging (accept/06) is out of scope here.</non_goal>

<non_goal id="NG4">Rewriting the ~127 handler-block sites elsewhere in the corpus that are NOT runner call sites. This spec is the four runners plus the sites that invoke them.</non_goal>

## Decisions

<decision id="D1">Runners return `Handler E a b` values (D3, C9). The four runners become functions whose result type is a `Handler`. This requires a `Handler` type constructor with three arguments — effect, input answer type, output answer type — and first-class handler values that a `handler E { ... }` block produces. This is the real work of the item; the keyword is the easy part.</decision>

<decision id="D2">`handler E { ARMS }` is a standalone expression producing a handler value. It is `EWith`/`EWithH` with the trailing body removed and `with` respelled `handler`. The arms are unchanged from what item 1 already produced (`once`/`return` clause kinds).</decision>

<decision id="D3">The `in c self` callback is DELETED, not respelled. Under D9 a capability is never a first-class term, so `c self` — passing the handle `self` as an argument to `c` — is grammatically inexpressible in v2. The callback has no v2 form to migrate to; it disappears because `handle h in body` writes the body directly where the callback used to be applied.</decision>

<decision id="D4">Call sites use the delimited inline `handle` form, in two spellings that mirror the two current sugars:
- Ambient (`EWithRun`): `with state 0 in body` becomes `handle State = state 0 in body` (default label = effect head, D13 tier 2 allows eliding it to `handle state 0 in body`).
- Named (`EWithNamed`): `with count = state 0 in count.get` becomes `handle count = state 0 in count.get`.
No call site needs statement-form `handle` (NG2).</decision>

<decision id="D5">The named-instances feature is preserved, not removed. `handle count = state 0` binds the role label `count`; `count.get` performs through it; two `handle`s of the same effect are two independent activations (accept/02, accept/09). This is the same guarantee `with count = state 0 in` gives today.</decision>

## Challenges

<challenge id="C1" summary="Does introducing handler values duplicate or conflict with the existing fused with-forms during the transition?">
Item 1 shipped `once`/`return` on the EXISTING fused `with { ... } body` forms. Adding standalone `handler E { ... }` values plus `handle` means two coexisting ways to install a handler for the whole transition. Do they conflict, and does the corpus have to convert atomically?
</challenge>

<response to="C1" status="open">
Likely resolvable by keeping both surfaces live until the corpus is converted, exactly as item 1 kept old and new clause spellings live until the codemod ran. But whether `handle` and `with { ... } body` can coexist without grammar ambiguity (both start with a handler-ish head) needs a prototype: `handler`/`handle` are new keywords, so the lexer separates them, but the parser interaction with the four surviving `with` productions is unverified. Prototype the grammar before committing to a coexistence window.
</response>

<challenge id="C2" summary="Does the baton mechanism migrate to := + auto-resume, or keep once set x k -> k x ()?">
The current `state` threads its baton through a two-arg resume: `once set x k -> k x ()`, where `k`'s first argument becomes the new baton. The v2 endpoint uses `set x -> cur := x` — an AUTO-RESUME arm with the `:=` baton-assignment operator. `:=` is a separate surface + elaboration feature (D1 of the redesign lists it as a baton updater). Does this migration require adopting `:=`, or can the runners keep the two-arg-resume baton and change only the wrapper?
</challenge>

<response to="C2" status="resolved">
Keep the two-arg-resume baton for this item; defer `:=`. The build/install split is orthogonal to how the baton is threaded: `handler State { var s = i ; get -> s ; once set x k -> k x () ; return v -> (v, s) }` captures the baton at install time exactly as the fused form does today. Bundling `:=` would fold a second, independently-shippable surface change into item 4. Consequence, stated honestly: the migrated runners will NOT be byte-identical to accept/01 until a later `:=` item lands; their `set` arm stays a `once` control arm rather than an auto-resume `:=` arm. That is a smaller, verifiable step, and `:=` becomes its own retrofit item with its own S-probe evidence.
</response>

<challenge id="C3" summary="Is item 4 blocked on item 3 (explicit Handler answer types)?">
`state : s -> Handler (State s) a (a, s)` names the input answer type `a` and the output answer type `(a, s)` explicitly. Current wok has no `Handler` type and INFERS answer types. Can the runners' types even be written before item 3 (explicit `Handler` answer types) lands?
</challenge>

<response to="C3" status="resolved">
Item 4 depends on item 3; sequence 3 before 4. The `Handler E a b` type constructor and the ability to write its three arguments in a signature ARE item 3. A handler value has no useful type without them — `handler State { ... }` inferred to an anonymous handler type could not be returned from `state` with a checkable signature. So the dependency is real and one-directional: build the `Handler` type and explicit answer types first, then the runners can be typed as `Handler`-returners. This also means item 3 must deliver first-class handler VALUES, not merely answer-type annotations on the existing fused forms — a point item 3's own spec should absorb.
</response>

<challenge id="C4" summary="The ambient sugar discards the handle (\_ ->); how does handle State = ... bind the default label without it?">
`with state 0 in body` desugars to `state 0 (\_ -> body)` — the callback IGNORES the handle, and ambient performs (`State.get`) resolve through the installed activation via the effect row, not the passed handle. In v2 there is no callback to ignore. How does `handle State = state 0 in body` route an ambient `State.get` to this activation?
</challenge>

<response to="C4" status="open">
The intended answer is D9/P2: `handle State = state 0` assigns the State DESIGNATION SLOT, and an ambient `State.get` resolves to the slot. But current wok's ambient resolution routes through the effect row and the nearest installed handler, not a named slot. Whether the existing ambient-perform resolution can be pointed at a `handle`-installed activation WITHOUT the full P2 slot machinery is unverified. Prototype: install one handler value via `handle` (no label) and confirm an ambient `State.get` in the body resolves to it, matching today's `with state 0 in`. If it needs the slot layer, that pulls D9 into item 4's scope and this spec must widen.
</response>

<challenge id="C5" summary="What is the reject example for the argument-position capability escape this closes?">
D3 deletes the callback because D9 makes `c self` inexpressible. The redesign's `reject/01-capability-escape.wok` only covers RETURN position (`handle c = h in c`). There is no reject twin for argument position (`handle c = h in f c`) — which is exactly the shape the current runners use. Without it, the migration removes a construct with no fixture pinning WHY it is illegal in v2.
</challenge>

<response to="C5" status="resolved">
Add the missing reject twin as part of this item: a fixture that installs a capability and passes it as an argument to a function (`handle c = state 0 in useIt c`), expecting E-LABEL / "capabilities are not values" at the argument position. This both documents the deletion and closes the conformance gap the redesign left open. The current runners' `c self` is the canonical instance of this shape, so the fixture is a direct mutation of a runner. File it alongside the item-4 acceptance corpus.
</response>

<challenge id="C6" summary="Do all four runners' answer types actually express as Handler E a b?">
`state` and `writer` return a pair `(a, s)` / `(a, [w])`; `except` returns `Result a e`; `reader` returns `a` unchanged. The `Handler E a b` triple must express each: input answer `a`, output answer the transformed result. Does every runner's transformation fit the three-argument `Handler` shape, or does one of them need something the triple cannot say?
</challenge>

<response to="C6" status="open">
By inspection each fits — `Handler (State s) a (a, s)`, `Handler (Writer [w]) a (a, [w])`, `Handler (Except e) a (Result a e)`, `Handler (Reader r) a a`. But this is inspection, not a checked type: the `Handler` type does not exist yet to validate against. Confirm once item 3's `Handler` type is prototyped, by giving each runner its signature and typechecking the `handler E { ... }` body against it. `except`'s `Never`-result `throw` arm (zero-shot) and `reader`'s pure `ask` (no baton) are the two most likely to surface an edge in the answer-type checker.
</response>

## Assumptions

<assumption id="A1">The arms inside each runner are already at their item-1 form (`once`/`return` clause kinds). Verified: `prelude/Std/Control.wok` is converted and green.</assumption>

<assumption id="A2">`handler`/`handle`/`use` can be added as lexer keywords without colliding with existing identifiers in the corpus, as `once`/`return` were. Needs the same comment-stripped scan item 1 used; `use` in particular may already appear (there is a `DUse` import form — check `use` is not overloaded).</assumption>

<assumption id="A3">The elaboration seam that currently lowers `EWithNamedH`/`EWith` into the typed core can be split into a build step (handler value) and an install step (handle), reusing the existing handler-frame lowering. Unverified against `src/Wok/IR/Elaborate.hs`.</assumption>

## Open questions

<open_question id="Q1">Migration order for the corpus: convert the four runners and ALL their call sites atomically, or run a coexistence window like item 1 (both surfaces live, then a codemod)? Depends on C1's prototype. If `handle` and `with { ... } body` coexist cleanly, a codemod over call sites is the item-1-proven path.</open_question>

<open_question id="Q2">Does `use` come in with this item or later? The four runners do not need `use ... as` (no two-vocabulary bridging). `use` could be deferred to a fifth sub-item, keeping this one to `handler`/`handle`. Deferring narrows the surface added here to two keywords.</open_question>

<open_question id="Q3">Is a codemod feasible for the call sites the way it was for the arms? Call-site rewriting needs to know each runner's identity (is this `with foo in` a runner application or an unrelated `EWithRun`?) — derivable from the parse plus the runner set, like the arity table. Worth prototyping the same parser-backed tool shape (`tools/Codemod.hs`) rather than regex.</open_question>

## Contract status

Not buildable. Three responses are open (C1, C4, C6), each a prototype handoff:
grammar coexistence, ambient resolution through `handle`, and the `Handler`
answer-type check. All three depend on item 3 delivering the `Handler` type and
first-class handler values first — which is this spec's sharpest finding: item 4
is not a surface split over existing machinery, it is the consumer of a handler-
values capability that does not exist yet.

## Findings from the State-slice implementation (feat/handler-values-state, 2026-08-08)

Recorded here so the migration slice inherits them; none are fixed on that
branch beyond what its commits state.

1. **Fused ambient handlers share the payload-tying hole.** The branch closed
   install-site payload tying for handler VALUES (a `State U64` handler over a
   body performing `State.set "oops"` now rejects), but the FUSED ambient form
   still discharges without unifying the row payload: `with State { get -> 0 ;
   once set x k -> k () ; return v -> v } (let u = State.set "oops" in 1)`
   typechecks and runs to 1 today. Pre-existing (per-arm fresh substitutions +
   payload-blind dischargeEffects); belongs to the repo backlog, not the
   handler-values branch.

2. **Named-frame ambient dispatch divergence (mirrored, not introduced).**
   Typing treats an ambient perform inside a named install's body as flowing
   OUT (named performs never touch the ambient row), but runtime findHandler
   with no target matches ANY covering frame -- including the named one. The
   handler-value named install deliberately mirrors the fused EWithNamedH
   discipline, so the divergence is unchanged; handler values make the shape
   more common, so the migration should keep it in view.

3. **Handler-value arm bodies charge their effects at the CONSTRUCTION site.**
   `inferOpArmNode` types a value's arm bodies under the construction ambient,
   but arms RUN at dispatch. Irrelevant for the four prelude runners (arm
   bodies are pure), but an effect-translating runner (logToIO-style) built as
   a handler value charges its arm effects to where the value was built, not
   where it is installed. Known limit for the migration slice.
