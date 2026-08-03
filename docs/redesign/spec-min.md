# wok v2 handler surface — minimal spec (parser edition)

Normative extract of spec.md (through D28) for implementing the front end.
Where this file and spec.md disagree, spec.md wins; report the disagreement.
Everything here is decidable at parse time or with only the effect
declarations in hand — no type inference required.

## 1. Keywords

```
ML skeleton : module import as type alias class instance let in case of
              if then else where \
law words   : effect handler handle use abort return var := with
              foreign extern own lend copy
migration   : once        -- NOT a keyword; reserved at clause-head position
                          -- only, to emit "v1 clause keyword; drop it"
```

Reserved as op names (E-RESERVED): `once`, `abort`, `return`, `var`.

## 2. Declarations

```
effectdecl  ::= "effect" ConId tyvar*            -- ops in a layout block
                  (varid ":" type)+

handlerlit  ::= "handler" ConId clause+          -- a first-class VALUE
                                                 -- ConId must name an effect
clause      ::= "var" varid "=" expr             -- baton (frame state)
              | "return" pattern "->" body       -- value clause (optional;
                                                 --   defaults to identity)
              | "abort" varid pattern* "->" body -- never-resumes clause
              | varid pattern* "," varid "->" body   -- CONTROL clause
              | varid pattern* "->" body             -- PLAIN clause

install     ::= "handle" label "=" expr          -- statement: label REQUIRED
              | "handle" (label "=")? expr "in" expr  -- inline: label elidable
rebind      ::= "use" varid "as" label ("," varid "as" label)* ("in" expr)?
assign      ::= varid ":=" expr                  -- legal only in clause bodies
                                                 -- of the declaring handler
```

A single clause may share the `handler` head's line
(`reader e = handler Reader ask -> e`). Blocks are column-delimited, no `;`
(D22). A signature must PRECEDE its equation (D23). Labels: lowercase =
free role name; Capitalized = the effect's designation slot, and must name
a declared effect.

Let scoping (D26): a binding WITHOUT parameters is NON-RECURSIVE — its RHS
reads the enclosing scope, so `let off = off + 4` rebinds (new value,
shadows the old). A binding WITH parameters is a function equation:
recursive, and adjacent function equations group for mutual recursion. A
value binding whose RHS references its own binder name is an error with
the eta hint ("recursive binding? write `let f x = ...`").

## 3. Clause classification (pure syntax, in order)

1. Head keyword `var` / `return` / `abort` -> that kind.
2. Head keyword `once` -> migration diagnostic: "v1 clause keyword; drop it".
3. Otherwise it is an op clause. A `,` at clause-head depth before `->`
   makes it a CONTROL clause; no comma makes it a PLAIN clause. Full stop —
   classification never consults names, types, or counts (D25).
4. In a control head, exactly one bare lowercase varid follows the comma:
   the continuation binder. It is never a pattern (D14).

## 4. Checks, in pipeline order

Parse time (no tables needed):
- comma followed by non-varid, or more than one name after the comma -> E-ARITY
- `once` at clause head -> migration diagnostic

Resolution time (effect declarations in hand):
- value binding's RHS references its own binder -> error, eta hint (D26)
- `:=` checks (D27, three E-VARSCOPE voices): no handler frame in lexical
  scope; target resolves to a value, not a `var` (including a var SHADOWED
  by a later let — name the shadow site); or the write's nearest enclosing
  function-forming construct is not the declaring handler's clause body —
  lambdas, local function equations, and handler literals are boundaries;
  blocks, `case` arms, and `if` branches are not
- clause-body name resolution: args -> batons -> enclosing scope (a `var`
  shadows an outer binding of the same name)
- `handler E` where E is not a declared effect -> error at E
- clause op not declared by E -> error at the op token
- argument-pattern count != op arity, for EVERY kind (plain, control,
  abort) -> E-ARITY. Left of a comma, binder count always equals op arity.
- multiple clauses per op: allowed with refutable patterns; must agree on
  plain vs {control, abort}; together they must cover the argument type
  -> E-COVER

Later analyses (for completeness of the E-vocabulary):
- control arm consumes its continuation on NO path -> E-ABORT ("write abort")
- continuation name rebound within its USABILITY REGION (the arm body up
  to any function-forming boundary; live or dead) -> E-SHADOW; a
  same-named binder beyond a boundary (lambda, local function, handler
  literal) is a fresh declaration and legal (D28). Precedence: a
  same-region shadow that explains a zero- or double-consumption is
  blamed as E-SHADOW, preempting E-ABORT / E-AFFINE
- continuation consumed twice on a path -> E-AFFINE
- continuation escapes the arm (returned, stored, captured) -> E-ESCAPE

## 5. Semantics in five lines (for error-message wording)

- PLAIN: body has the OP's result type; auto-resumes; compiles to a call.
- CONTROL: `k : T -> R` (op result -> handler answer-out). Calling `k` runs
  the rest of the computation to completion under this handler and returns
  the final `R`. At most one call per path (inferred, not declared).
- ABORT: body has the answer-out type `R` and IS the answer; the `return`
  clause does not run; no continuation is ever materialized.
- RETURN: runs on the body's normal completion value; `Handler E a b` with
  `a /= b` forces its presence.
- VAR: per-activation state; reads see the latest write; reads crossing a
  function boundary take a SNAPSHOT (the slot never travels); `:=` outside
  the declaring handler's clause bodies -> E-VARSCOPE. The pyramid for
  error wording: `=` names a value, forever; `:=` updates a slot; slots
  live only in handler frames; everything else mutates through an effect
  you can see in the type (State).

## 6. Canonical examples (conformance seeds)

```
state : s -> Handler (State s) a (a, s)
state init = handler State
  var cur = init
  get      -> cur
  set x    -> cur := x
  return v -> (v, cur)

collect : Handler (Yield a) r [a]
collect = handler Yield
  yield x, k -> x :: k ()
  return u   -> []

except : Handler (Except e) a (Result a e)
except = handler Except
  abort throw e -> Err e
  return v      -> Ok v

race : Handler Ask a (Result a String)
race = handler Ask
  var budget = 3
  ask q, k -> case budget == 0 of
    True  -> Err "out of budget"
    False -> budget := budget - 1
             k (lookup q)
  return v -> Ok v

main =
  handle Except = except
  handle State  = state 0
  (handle collect in count 1 7)
```

## 7. Provenance map (when a rule needs its why)

comma classification + totality: D25. comma placement: C8 (two
amendments). abort kind: C13/D24. patterns per op + coverage: D14. baton
copy point: C12. labels/slots: P1/P2, D13, D17. no `;`: D22. sig-first:
D23. value-clause keyword: conservation argument in C8's record and the
`gett` typo probe (2026-08-04 session).
