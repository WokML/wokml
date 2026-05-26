
1. Type annotation is `:`.
2. Use `--` as line comment


Remember that we can do a Coverage pass that will check the exhaustive and the overlapping patterns

Remember there are over-promising signatures like

    f : a -> a
    f = (+)

doesn't work because `(+)` is `u64 -> u64 -> u64`, not `a -> a`. The
typechecker catches this by *freezing* the user's signature (`freezeSig`):
the `a`s become rigid constants that the unifier won't equate with `u64`,
so the over-promise surfaces as a type error.