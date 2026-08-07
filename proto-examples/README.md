# proto/handler-values — worked examples

Run each from the worktree root with:

    cabal run -v0 exe:wok -- proto-examples/<file> --run

These prove first-class handler VALUES end to end: a handler built with
`handler E { arms }`, held as a value, and installed separately with
`handle h in body`. None of the three can be expressed by the fused `with`
forms, because in each the handler crosses a boundary the fused form has no way
to cross.

| File | What it proves | Output |
|---|---|---|
| `01-value-across-boundary.wok` | A handler value passed as a function ARGUMENT (`run f = handle f in E.ask`) and installed inside the callee. The fused form cannot pass a handler to a function. | `41` |
| `02-runtime-selected.wok` | A handler CHOSEN at runtime (`pick b` returns one of two handler values by a `case`), then installed. Inlining is impossible: the identity is a runtime value. | `200` |
| `03-once-abort.wok` | A `once` control-arm handler value that drops its continuation (zero-shot abort). Confirms the arm machinery works for control clauses, not just auto-resume. | `7` |

## Scope of the prototype

Supported: ambient (unnamed) handler values, installed in TAIL position, over a
body performing exactly one effect. No handler-local `var` parameter, no
named/self handler value, no value-position install. These limits are the
demands the prototype surfaced, written up in
`../docs/retrofit-item4-callback-runner-migration.md`.
