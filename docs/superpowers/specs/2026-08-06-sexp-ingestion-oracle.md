# Sexp ingestion: the Haskell typechecker as a differential oracle

**Status: DRAFT — awaiting review**
**Branch target: new feature branch off main**
**Date: 2026-08-06**

## Goal

Make the Haskell compiler accept the `grammar/c` s-expression AST dump as its
input, so that:

1. the Haskell parser (`Wok.Parsing` / BNFC) leaves the trust path — both the
   future C typechecker and the Haskell typechecker consume the *identical*
   tree, so any divergence is a semantics bug, never a parse difference;
2. a future C typechecker (flat arr32 union-find engine, benchmarked
   2026-08-06: ~4-6 ns/op vs ~140-380 ns/op for the STRef design) can be
   developed against the Haskell implementation as its oracle, reusing the
   differential-harness discipline that already guards the RC runtime
   (`rcDifferentialHarness`, test/Spec.hs:13681).

## Non-goals (this epic)

- Deleting `Wok.Parsing`. test/Spec.hs holds 1,039 assertions plus ~40
  auto-discovered corpora that feed v1 source text through `parse`. Removal is
  a separate migration (S5, deferred) once the corpus itself is sexp-first.
- Supporting the `grammar/go` dialect. It is stale (pre-D25 surface: still has
  `once`, no `fixity`, no `abort`) and structurally different (surface-named
  heads, variadic fields). The C dialect is current, schema-derived, and
  strict. Go is not touched.
- Comments and positions in the dump. The C dump deliberately carries neither
  (wok_sexpr.h:16-18). See D4 for how positions degrade.
- Writing the C typechecker itself. This epic builds the oracle-side plumbing
  and proves it on the parser level; the C typechecker is the next epic.

## Architecture

```
                      grammar/c wokparse -sexp
   file.wok  ──────────────────────────────────────►  file.sexp
                                                          │
              Haskell today                               │  NEW
   file.wok ──► Wok.Parsing.parse ──► Abs.Module          ▼
                     (BNFC v1)            ▲       Wok.Sexp.Read   (dialect)
                                          │              │
                                          │              ▼
                                          └──── Wok.Sexp.Surface  (v2→v1 map)
                                                          │
                              Loader / Reordering / TypeChecking (UNCHANGED)
```

Two new modules, both with explicit export lists:

- `Wok.Sexp.Read` — text → `SExp` datum tree. Implements the C dialect's
  lexical rules exactly (wok_sexpr.h:7-15): delimiters are `(`, `)`, `"`,
  whitespace; escapes are `\\ \" \n \t \r \xHH` and *nothing else*; `#t`/`#f`
  words; `(none)`/`(some X)`; `(seq ...)` always tagged. Strict: unknown
  escape, unterminated list/string, depth > 256 are errors.
- `Wok.Sexp.Surface` — `SExp` → `GeneratedParser.Wok.Abs.Module`. A
  hand-written, context-directed decoder over the 84 `W_/D_/T_/P_/E_/S_/H_/N_`
  tags (wok_ast.h:203-243), enforcing field count and family exactly as the C
  reader does (wrong family = error, not coercion), then mapping each v2 node
  to its v1 equivalent.

No existing module changes semantics. The typechecker, reordering, and loader
pipelines are untouched downstream of `Abs.Module`.

## Decisions

**D1 — Dialect = the grammar/c schema dump, verbatim.** The format spec is the
header comment of `grammar/c/wok_sexpr.h` plus the `wok_ast.h` schema. The
Haskell reader must be exactly as strict as `wok_sexpr_read`: unknown head
tag, wrong field count, wrong field shape, wrong family → error with the tag
name and the datum's line/col in the .sexp file. `(!null)`/`(!depth)` damage
markers are rejected (as in C). `D_Error`/`E_Error` map to a hard error in the
oracle path — the oracle only accepts clean parses.

**D2 — Injection at the Loader, keyed by file extension.** `parseAndPrep`
(Loader.hs:117) gains one branch: a file ending in `.sexp` goes through
`Wok.Sexp.Read` + `Wok.Sexp.Surface`; everything else goes through `parse` as
today. This keeps `loadProgram`'s module-graph logic (topo sort, prelude
loading, fixity extraction, import extraction) working unchanged for sexp
inputs, because after mapping we have an ordinary `Abs.Module` with `DModule`
first and `DImport`/`DFixity` decls in place. The CLI needs zero new flags:
`wok file.sexp` and `-I dep.sexp` just work. Preludes remain .wok/BNFC-parsed
for now (they are v1 source; the C front end does not parse them — see R3).

**D3 — The mapping is semantic, not syntactic.** The C tree is v2 surface; the
Haskell tree is v1. The mapper translates each v2 form to the v1 form with the
same *meaning*, not the same spelling. Known direct correspondences:

| v2 (C dump) | v1 (Abs) | note |
|---|---|---|
| `W_File (seq d...)` | `Module [Decl]` | root |
| `D_Module (N_ModPath ...)` | `DModule ModPath` | must stay first decl |
| `D_Import` | `DImport ModPath ImportMod` | plain / list / as |
| `D_Equation (L_Prefix ...)` | `DEqn` prefix form | |
| `D_Equation (L_Infix ...)` | `DEqn` infix-defn form | |
| `D_Sig / H_SigName` | `DSig` | multi-name sigs |
| `D_Type` | `DData` | constructors + record cons |
| `D_Effect / H_OpSig` | `DEffect` | |
| `D_Class / D_Instance` | `DClass / DInstance` | |
| `D_Foreign / H_ForeignMember` | `DForeign` | owned/lend transfer modes |
| `D_Fixity / H_FixRel` | `DFixity` | v1 reordering is already partial-order |
| `E_Chain head (seq (H_ChainOp op bt rhs)...)` | `EExpr head [ITail...]` | UNRESOLVED chain; Wok.Reordering resolves it, so fixity resolution is differentially tested for free |
| `E_App` (binary, curried) | `EApp` (spine) | re-spine |
| `E_Handler / H_Clause kind` | v1 handler forms | clause kinds: PLAIN/CONTROL/RETURN/VAR/ABORT — see D5 |
| `E_HandleIn label h body` | `EWith* / EWithNamed*` family | label: elided/slot/role |
| `E_Block / S_Let / S_Handle / S_Use / S_Discard` | v1 block-scope forms | handler-block var + block-scope shipped in v1 (64d32ea) |
| `T_Fun / T_With / H_RowEntry` | v1 `Type` + `EffectRow` | row entries: eff/role/slot |
| `P_*` | `Pat / AtomPat` | records incl. `..`/`..rest` |
| `N_Name upper-flag / N_ModPath` | `ConId / VarId / ModPath` | case re-derived from flag, not spelling |

**D4 — Positions: point into the .sexp file.** The dump carries no source
positions, but the reader knows each datum's line/col *in the dump text* (the
C reader does the same for its own diagnostics). The four positioned token
newtypes (`WokInt/ConId/VarId/VarSym`, all non-Maybe `((Int,Int),Text)`) get
the datum's position in the .sexp file. Consequence: type errors on sexp
inputs point into the dump, which is debuggable (dumps are pretty-printed one
field per line), and the oracle harness compares error *identity* (constructor
/ code), never spans.

**D5 — Literal decoding happens in the mapper, once, and is testable.**
`WFC_TEXT` fields carry the raw source lexeme (`(E_Str "\"a line\\n\"")`
including quotes). v1 `ELitS`/`ELitC` want decoded values. `Wok.Sexp.Surface`
implements wok literal decoding (string/char escapes per spec-min.md) as pure
functions with their own unit tests. Divergence between this decoder and the
BNFC lexer's decoding is caught by the S3 differential (D7).

**D6 — Gap inventory is a deliverable, not a footnote.** S1 starts by
classifying all 84 tags: (a) direct map, (b) compositional map, (c) no v1
equivalent. Category (c) nodes make the mapper fail with a dedicated error
(`SexpGap <tag>` listing the construct), and the inventory table is committed
to this spec. Known candidates for (c) from the rosters: v2 clause-kind
details where v1 still expects `once` (the once/return retrofit is on an
unmerged branch), `D_Alias` (v1 has no type alias decl), `D_ExternType`
parameter kinds. Each (c) entry is a concrete, actionable statement of v1/v2
drift — the same class of finding as the EWithNamedH gap already logged.

**D7 — The first differential is parser-vs-parser, and it gates everything.**
Before any C typechecker exists, the reader is validated end-to-end:

```
for each corpus file F both front ends accept:
    A  = reorderModule (Wok.Parsing.parse F)            -- Haskell path
    B  = reorderModule (Sexp.Surface (wokparse -sexp F)) -- C path
    assert printTree A == printTree B                    -- Print-normalized
```

This runs over `docs/redesign/examples/accept` plus every `test/` corpus file
the C front end parses cleanly. It is a new tasty group, gated on an env var
(`WOK_WOKPARSE=path/to/wokparse`); unset ⇒ the group is skipped, so CI without
a C toolchain stays green.

**Amendment (S1-S4 execution):** the original text here claimed comparing
the *reordered* trees checks "the C fixity resolver and Wok.Reordering
against each other". That is NOT what happens: `wokparse -sexp` dumps
operator chains **UNRESOLVED** (`E_Chain head (H_ChainOp ...)*` maps to v1's
deferred-precedence `EExpr head [ITail]`), so BOTH paths are resolved by the
same `Wok.Reordering` and the C shield-rule resolver is never differentially
exercised by this harness. Comparing post-reorder trees still matters (it
exercises reordering over sexp-derived trees, and catches mapper bugs that
only surface after resolution), but a real resolver-vs-resolver differential
needs a **wokparse resolved-dump mode** (dump the chain AFTER the C
resolver has shaped it) — recorded as future work, not this epic. The
comparator is normalized structural equality, not printTree — see Findings.

**D8 — The oracle contract for the future C typechecker is scheme text.** The
existing default CLI mode already prints `name : scheme` per entry-module
decl. That output (plus a canonical error-code line on failure) is the oracle
answer. The C typechecker must reproduce it byte-for-byte on the shared
corpus; scheme variable naming is canonicalized by the existing printer
(CTGen indices are deterministic). No new output machinery needed this epic —
only a note that S4 adds an `--errors-canonical` mode if error-side
comparison needs more than the code.

## Corpus audit (measured 2026-08-06)

Empirical acceptance, current main + grammar/c HEAD:

| corpus | files | C front end parses | Haskell parses |
|---|---|---|---|
| test/typecheck-examples | 56 | 27 | 56 (by construction) |
| test/run-examples | 104 | 49 | 104 |
| test/examples | 26 | 5 | 26 |
| docs/redesign/examples/accept | 12 | 12 | **1** (05-coroutine-pull) |
| docs/redesign/examples/reject | 14 | 12 (syntax-clean) | — |

- **The S3 differential corpus is the 81-file intersection** (44% of the v1
  corpora), of which 36 exercise the with/handler/effect surface — real
  coverage of the highest-drift area.
- **The v2 accept corpus cannot enter S3** (the Haskell parser rejects 11/12)
  — it enters through the sexp path only, gated on mapper (gap-inventory)
  coverage, and becomes S4 oracle corpus.
- **Existing .expected goldens are reusable as cross-path goldens**: for each
  intersection file, the sexp-ingested program must reproduce the SAME
  golden (schemes / run output) the .wok path already locks in. S3 therefore
  asserts both tree equality (post-reorder printTree) and golden equality —
  the goldens are suitable for v2 work precisely because they are keyed to
  program meaning, not to the ingestion path.
- **The redesign reject corpus has no machine-readable expectation** (prose
  comments only; the `-- EXPECT:` protocol exists only in grammar/c/testdata).
  S4 adds `-- EXPECT:` headers to docs/redesign/examples/reject plus a
  C-code → Haskell TypeError-constructor mapping table; until then the reject
  side is not oracle-comparable.
- Anomaly noted during the audit: batch loops over wokparse intermittently
  stalled for minutes in the sandboxed shell while every individual
  invocation ran in <5 ms with identical output across runs. Not reproducible
  deterministically; retest outside the sandbox before treating it as a
  parser bug (if it reproduces, fuzz the layout filter first).

## Slices

**S1 — `Wok.Sexp.Read` + `Wok.Sexp.Surface` + gap inventory.**
Datum reader with strict lexical rules; decoder for all 84 tags; literal
decoders; the (a)/(b)/(c) inventory table appended to this spec. Unit tests:
lexical edge cases (escape strictness, depth, `(none)`/`(some)`), family
strictness (the five hand-written dumps from grammar/c/test/test_sexpr.c:122
ported as accept/reject cases), literal decoding, and per-family mapping
goldens. Acceptance: every accept-corpus dump the C front end produces today
maps or fails with a named `SexpGap`.

**S2 — Loader wiring.** The `.sexp` branch in `parseAndPrep`; a
`loader-fixtures` style test with a .sexp entry importing a .wok prelude.
Acceptance: `wok file.sexp` prints schemes; `--run` works on a sexp-ingested
program whose .wok twin runs.

**S3 — Parser differential over the corpus (D7).** The env-gated tasty group
over the 81-file intersection (see Corpus audit). Two assertions per file:
post-reorder `printTree` equality, AND the sexp-ingested program reproduces
the file's existing `.expected` golden (schemes / run output) — the goldens
double as cross-path oracles. Acceptance: zero mismatches, and every
exclusion is either a recorded `SexpGap` or a recorded C-parse rejection —
no silent skips (log the excluded list in the test output).

**S4 — Oracle harness skeleton.** A `scripts/typecheck-oracle.sh` in the
mold of `oneshot-oracle.sh`: run `wokparse -sexp` + `wok` over the corpus,
store scheme-text goldens under `test/oracle-golden/`. These goldens are the
contract the C typechecker implements against. Acceptance: goldens exist and
regenerate deterministically.

**S5 (deferred, separate epic) — parser removal.** Migrate Spec.hs inline
sources and corpora to sexp-first, then delete `Wok.Parsing`,
`Wok.RecordLayout`, and the BNFC sublibrary. Not scheduled; blocked on the C
front end parsing everything the test suite needs (including preludes, R3).

## Risks / open questions

**R1 — v1/v2 surface drift is live.** The once/return retrofit (v1 corpus
codemod) sits on an unmerged branch; v2 cut `once` for comma clauses +
`abort`. Until that lands, clause-kind mapping targets what main's Abs
actually has. The gap inventory (D6) makes each drift point explicit rather
than letting the mapper paper over it. Decision needed at S1 review: map v2
CONTROL clauses onto v1 `once` (semantics match: affine k) or hold as
`SexpGap` until the retrofit merges.

**R2 — Two reorderings must agree.** v2's fixity resolver (shield rule, three
hardening passes) and v1's `Wok.Reordering` were built independently. D7
deliberately compares post-reorder trees so disagreement surfaces as a
mismatch, not silently. Expect findings here; they are wanted.

**Amendment (S1-S4 execution):** this risk is currently NOT covered — see
the D7 amendment: chains are dumped unresolved, so both paths flow through
`Wok.Reordering` and the shield-rule resolver never runs on the differential
path. Coverage requires the future wokparse resolved-dump mode.

**R3 — Preludes stay v1.** The six embedded preludes are v1 source the C
front end cannot parse, so sexp-ingested programs still typecheck against
BNFC-parsed preludes. For the oracle this is fine (both the Haskell and the
future C typechecker will consume the same prelude *environment* — the C
typechecker gets it from the same goldens), but full parser removal (S5)
needs the preludes on the v2 surface first.

**R4 — `Read`-derived escape hatch rejected.** `Abs` derives `Read`, so
`show`/`read` of the Haskell AST would be a zero-code interchange format. It
is rejected as the oracle format: it encodes the v1 tree (nothing forces the
C side to construct it), is Haskell-locked, and would silently drift with the
grammar. The C dialect is the schema of record.

## Gap inventory (S1, measured)

Measured against `Wok.Sexp.Surface` as implemented (S1b), on main's ACTUAL
v1 surface (`GeneratedParser.Wok.Abs` / `grammar/Wok.cf`). One row per tag
in the `WOK_NODES` roster. Note: the roster holds **84** tags, not the 82
this spec's prose originally said — the prose undercounted (all 84 are
classified below and decoded by the mapper; the prose spots have since
been corrected to 84).

Categories: **(a)** direct — one v2 node, one v1 form; **(b)**
compositional — mapped by reshaping, or mapped only on a subset with named
gaps for the rest; **(c)** SexpGap / excluded — no v1 equivalent (the
mapper fails loudly with the tag and a one-line description).

Totals: **52 (a) / 22 (b) / 10 (c)**.

| tag | cat | note |
|---|---|---|
| N_Name | a | token; ConId/VarId chosen by the `upper` FLAG, never by spelling |
| N_ModPath | a | `MPName`/`MPDot` fold; every part's flag must say upper |
| D_Module | a | `DModule` |
| D_Import | b | names/alias split -> `IMPlain`/`IMList`/`IMAs`; list+alias together, or an upper name in the list, gaps (v1 `ImportMod` is structurally one-of, vars-only) |
| D_Type | b | `DData`; see H_ConDef |
| D_Alias | c | **v1 has no type-alias declaration** |
| D_Effect | b | `DEffect`; a `(row e)` parameter gaps (v1 effect params are bare VarIds) |
| D_Class | b | `DClass`; multi-name sigs expand to one `CESig` each; extern sigs, defaults-with-where, and any other decl kind in the body gap |
| D_Instance | b | `DInstance`; the OPT ctx TYPE is reshaped into `[Constraint]` (tuple = list); a non-`Class Type*` ctx gaps |
| D_Foreign | b | `DForeign` with `FFNone` always (v2 schema has no `free <sym>` field — v1-side surface v2 has not adopted) |
| D_ExternType | a | `DExternType` |
| D_Sig | a | `DSig`, or `DExtern` when `is_extern` |
| D_Fixity | a | `FNAlpha`/`FNSym` by the `alpha` FLAG; assoc 0/1 -> `FALeft`/`FARight` |
| D_Equation | a | `DEqn` |
| D_Error | c | damage marker; D1: the oracle path hard-errors (`MalformedDump`), deliberately NOT a SexpGap |
| H_TyParam | a | `TPPlain`/`TPRow` by the `is_row` FLAG (context caveats under D_Effect/D_Class) |
| H_ConDef | b | `ConDef` / `ConDefRec` / `ConDefRecElide` by `is_record` + empty-name; mixed args+fields is malformed |
| H_FieldType | a | `RFType` |
| H_OpSig | a | `RFType` (v1 spells effect ops as record field types) |
| H_ForeignMember | b | `FMPlain` always: v1's `owned` MEMBER marker (`FMOwned`, transfer-full result) has no v2 field — v2 puts transfer on the TYPE (T_Transfer) |
| H_SigName | a | `SNBare`/`SNParen` by the `paren` FLAG |
| H_FixRel | a | sense 0/1 -> `FRTight`/`FRLoose` |
| L_Prefix | b | `LHSPre`; the FNBare/FNBareSym split reads the spelling — the ONE place the schema carries no alpha flag |
| L_Infix | a | `LHSInfSym`/`LHSInfBT` by the `backtick` FLAG |
| T_Var | a | `TVar` |
| T_Con | a | `TCon` (qualified paths fine) |
| T_App | a | `TApp` (both sides left-nested binary) |
| T_Fun | a | `TFun` |
| T_Qual | b | `TQual`; v1 parses always wrap the ctx in `TParen`, the map does not — printTree differs on qualified types (S3 will surface it; no fixture uses them yet) |
| T_With | b | maps only when the body is `T_Fun` (v1 `TWith` is arrow-shaped by grammar); a non-arrow `T with row` gaps |
| T_List | a | `TList` |
| T_Tuple | a | `TTuple` (arity >= 2 enforced) |
| T_Unit | a | `TUnit` |
| T_RowArg | a | `TRowArg` |
| T_Transfer | b | mode own -> `TOwned`; **lend gaps** (v1 has no borrow-tier type spelling); **copy gaps** (v1 spells copy by omission; dropping the marker silently was rejected) |
| H_RowEntry | b | slot -> `ERAtom` chain via `ERPlus "+"`, trailing row var -> `ERVarOnly`; **role entries `(name : Eff)` gap** (v1 rows have no roles — the known D9/EWithNamedH drift); a non-tail row var gaps; qualified effect atoms gap |
| P_Var | a | `PAtom APVar` |
| P_Wild | a | `PAtom APWild` |
| P_Int | a | `APLitI`; the `negative` FLAG re-prefixes `-` onto the decimal text |
| P_Str | a | `APLitS` via decodeStringLexeme |
| P_Char | a | `APLitC` via decodeCharLexeme |
| P_Con | a | nullary -> `APCon`, applied -> `PApp`; non-atomic args wrapped `APParen` |
| P_Cons | a | `PCons` |
| P_Tuple | a | `APTuple` (arity >= 2 enforced) |
| P_List | a | `APList` |
| P_Unit | a | `PUnit` |
| P_As | a | `APAs` |
| P_Record | b | `PRecord`/`PRecordOpen`/`PRecordWild` by `is_open` + fields + rest; a QUALIFIED constructor head gaps (v1 record patterns take a bare ConId) |
| H_FieldPat | a | `RFPat` |
| E_Var | a | `EVar` |
| E_Con | a | `ECon` |
| E_Int | a | `ELitI`; decimal text kept verbatim |
| E_Str | a | `ELitS` via decodeStringLexeme |
| E_Char | a | `ELitC` via decodeCharLexeme |
| E_Unit | a | `EUnit` |
| E_OpRef | a | `EParenOp` |
| E_App | a | `EApp`; BOTH surfaces are left-nested binary — no re-spining needed (the spec's "re-spine" row was moot) |
| E_Chain | a | `EExpr head [ITail]`, UNRESOLVED; `backtick` FLAG -> `IOBT`/`IOSym`; Wok.Reordering resolves downstream (verified by the 02-arithmetic end-to-end fixture) |
| E_Dot | a | `EProj`/`EProjC` by the `upper` FLAG |
| E_Neg | b | `E_Neg (E_Int n)` -> negative `ELitI`; any other operand gaps (v1 has no negation operator) |
| E_List | a | `EList` |
| E_Tuple | a | `ETuple` (arity >= 2 enforced) |
| E_Lambda | a | `ELam`; non-atomic binders wrapped `APParen` |
| E_LetIn | b | `ELet [d]`; bind lhs L_Prefix/L_Infix/P_Var -> `LDEqn`, P_Tuple -> `LDPat`; any OTHER pattern lhs (e.g. `_`) gaps — v1 has no wildcard/refutable let |
| E_HandleIn | b | handler literal + elided label -> `EWithH E []`; + lowercase label -> `EWithNamedH`; + Capitalized label equal to the effect -> `EWithH`; a DIFFERENT slot label gaps; a **non-literal handler expression gaps** (v1 has no first-class handler installation) |
| E_UseIn | c | **v1 has no `use x as label` rebind form** |
| E_If | a | `EIf` |
| E_Case | a | `ECase` |
| E_Handler | c | **v1 has no first-class handler values** (proto/handler-values only); consumed structurally when it sits directly under E_HandleIn/the mapped install forms, gaps everywhere else |
| E_Assign | c | **v1 has no `:=` frame-slot assignment surface** (v1 batons update through resume machinery, not user-visible assignment) |
| E_Record | b | `ERecord`/`ERecordExt` by the spread OPT; a non-`E_Con` head gaps (v1 requires a bare constructor; v2's head is a full EXPR) |
| E_Block | b | S_Let chains around a final expression -> nested `ELet` (adjacent FUNCTION-equation lets grouped into one `ELet` so D26 mutual recursion survives; value lets nest singly so sequential rebinding survives); all other statement shapes gap |
| E_Error | c | damage marker; as D_Error |
| S_Let | b | via E_Block (see above) |
| S_Handle | c | **v1 has no statement-form handler install** (`handle label = e` without `in`); every v1 with-form is a delimited expression |
| S_Use | c | **v1 has no use-rebind statement** |
| S_Discard | c | **v1 cannot sequence a discarded expression** (no `;`-like form) |
| H_ChainOp | a | `ITail` |
| H_Bind | b | see E_LetIn / E_Block |
| H_UseBind | c | carrier of the rebind pairs; falls with S_Use/E_UseIn |
| H_Alt | a | `AltC` (wheres map recursively) |
| H_Clause | b | kind mapping below (R1); ABORT gaps |
| H_Field | a | `RFExpr` |
| W_File | a | `Module [Decl]` |

### R1 resolved (clause kinds, against main's actual surface)

main never had `once` (the once/return retrofit is still on its unmerged
branch), so the R1 alternative "map CONTROL onto v1 `once`" does not
exist; the empirical v1 arm inventory is `HUArm VarId [AtomPat] Exp` (op
arm with an OPTIONAL (arity+1)-th continuation binder, split off by the
typechecker), `HArm` (dot-qualified variant), `HParam`/`HParamV` (seed /
`var` baton). The mapping, exercised by the "handler clause mapping (R1)"
tests:

| v2 kind | v1 form | rationale |
|---|---|---|
| PLAIN | `HUArm op <arity pats>` | v1 arity-many arm is auto-resume, tail-resumptive: same semantics |
| CONTROL | `HUArm op <arity pats + k>` | v1's explicit-k arm; both sides are affine one-shot ("one-shot is the law"), so `op p, k -> e` == `op p k -> e` |
| RETURN | `HUArm v []` when the clause binds a BARE VARIABLE | v1's value arm (classified by the typechecker against the header); a PATTERN return clause gaps — v1 cannot spell it. Caveat: a return binder that collides with an op name would classify as an op arm downstream; undetectable without effect decls, documented here |
| VAR | `HParamV name init` | exact v1 equivalent (`var name = init`, 64d32ea) |
| ABORT | **SexpGap** | v1 spells never-resume as an explicit-k arm that drops k; mapping would require inventing a fresh binder name (capture analysis) — a loud gap was chosen over a synthesized binder |

### Spec corrections found while implementing S1

- The roster is 84 tags, not 82 (prose in "Architecture" and D6/S1).
- D3's `E_App` row says "re-spine": unnecessary — v1 `EApp` is also
  binary/left-nested (the BNFC `Exp1 ::= Exp1 Exp2` production), and the
  end-to-end fixtures confirm printTree equality without reshaping.
- D3's `E_Block / S_*` row points at "v1 block-scope forms" — v1's 64d32ea
  block-scope work was LAYOUT (multi-line arm bodies), not Abs
  constructors; v1 has no block node, hence the S_Handle/S_Use/S_Discard
  gaps above and the nested-ELet encoding for S_Let.

## Oracle goldens (S4)

`scripts/typecheck-oracle.sh` runs the full sexp path — `wokparse -sexp`
piped into `wok` (default mode, which prints `name : scheme` per
entry-module decl) — over the corpus and locks the output down as goldens
under `test/oracle-golden/<corpus-dir-basename>/<file-basename>.schemes`.
This tree is the oracle contract D8 promises: **a future C typechecker
must reproduce this scheme text byte-for-byte on the same corpus** to be
considered conformant. There is no error-side golden yet (D8's deferred
`--errors-canonical` note); a file whose sexp ingestion fails is skipped,
not recorded as a negative fixture.

Regenerate with `scripts/typecheck-oracle.sh --update` (rewrites the
tree; refuses to write a golden — and exits nonzero — if two back-to-back
runs on the same file disagree, which would mean the oracle itself is
nondeterministic). Check the tree is still reproduced with a plain
`scripts/typecheck-oracle.sh` (no flag): PASS/FAIL per file, nonzero exit
on any FAIL or on any golden present on disk that the run failed to
reproduce (a silent coverage regression).

The corpus is the same four flat directories as the `Sexp.Differential`
tasty group (test/typecheck-examples, test/examples, test/run-examples,
docs/redesign/examples/accept), minus the files test/Spec.hs's
`sexpKnownDivergences` excludes from that intersection. The script
carries its own copy of that exclusion list (`KNOWN_DIVERGENCES`) since
the two live in different languages; keep them in sync by hand.

Coverage re-measured 2026-08-07 after the fix round (grammar/c HEAD, this
branch). The fix round grew the golden tree from 66 to **77**: the five
T_With-mapper-bug files and the six redundant-paren run-examples files
re-entered (see Findings); the known-divergence exclusion shrank to the
single span-only file:

| corpus | .wok files | C-reject | ingestion gap | known-divergence | **golden** |
|---|---|---|---|---|---|
| test/typecheck-examples | 56 | 29 | 0 | 0 | **27** |
| test/examples | 26 | 21 | 5 | 0 | **0** |
| test/run-examples | 104 | 55 | 0 | 1 | **48** |
| docs/redesign/examples/accept | 12 | 0 | 10 | 0 | **2** |
| **total** | 198 | 105 | 15 | 1 | **77** |

(The two test/examples files previously carried as known divergences —
03-expressions and 13-data-lowercase-error — now land in the ordinary
ingestion-gap bucket for THIS script: both are module-header-less
fragments, so `wok` rejects them before any scheme text exists. Their
test-suite treatment is separate: 03-expressions runs the normalized tree
assertion, 13-data-lowercase-error pins its no-v1-twin status.)

Notes on the zero-coverage row: `test/examples` holds standalone snippets
with no `module` header (the `SexpParseOnly` kind — tested only by
parse/print round-trip, never loaded as a program). The 5 files whose
dump the C front end accepts still fail at the `wok` ingestion step with
`LoadNoModuleHeader`, so none reach a scheme-text golden; this is
expected, not a regression, and is folded into the "ingestion gap" count
above (the script does not distinguish a `SexpGap`-tagged mapper failure
from a structural Loader failure — both mean "no byte-for-byte oracle
content this file", which is D8's line in the sand for this slice).

Determinism: every one of the 77 golden files was generated twice per
`--update` run and compared byte-for-byte before being written; no
divergence was observed. The full tree was also regenerated a second time
end-to-end and diffed against the first — identical, confirming the
goldens are stable across regenerations, not just within one run.

## Findings (S1-S4 execution)

Recorded so the lessons outlive the diffs that fixed them.

1. **The T_With row-attachment mapper bug (the root cause behind five
   "divergences").** `Wok.Sexp.Surface` originally mapped
   `T_With (T_Fun a rest) row` by attaching the row to the OUTERMOST
   arrow (`TWith a rest row`). v1 and the typechecker attach an
   unparenthesized trailing `with` to the INNERMOST arrow —
   `A -> B -> C with E` is `TFun A (TWith B C E)` (Infer.hs's
   `goT (Abs.TWith ...)` note is the authority; grammar/Wok.cf's TWith
   comment claiming whole-chain scope is misleading). Symptom: five
   corpus files (conc-await-multi, conc-chan-order, conc-parall,
   coro-step-range, coro-step-zip) typechecked to `UndischargedEffect`
   on the sexp path only, because the effect row rode the wrong arrow.
   Fix: `mapWithArrow` descends the dumped arrow spine while the
   codomain is a bare `T_Fun` and bottoms out in `TWith` on the last
   arrow; a nested `T_With` codomain (a distinct dump node, i.e. source
   parens) stops the descent.

2. **The "position-sensitive typecheck divergence" theory is
   OVERTURNED.** The five files above were previously excluded under
   the theory that Infer.hs read something position-derived (spec D4's
   dump-vs-source positions differing). Positions were irrelevant: the
   trees genuinely differed structurally, and the comparator could not
   see it (finding 3). No latent position-sensitivity in
   Wok.TypeChecking.Infer is implied by anything observed in this epic.

3. **printTree is blind as a differential comparator.** The BNFC
   printer renders `TFun A (TWith B C E)` and `TWith A (TFun B C) E` as
   the SAME text, and cannot render paren nodes it does not have — so
   "post-reorder printTree equality" certified structurally different
   trees as identical (hiding finding 1) while simultaneously failing
   on semantically-inert redundant parens (excluding seven harmless
   files). The differential now compares `show` of NORMALIZED trees
   (strip EParen / zero-tail EExpr / PAtom-APParen / APParen-PAtom /
   TParen; zero the (line,col) in the four positioned token newtypes)
   via one shared helper used by both the fixture end-to-end tests and
   the corpus group; printTree appears only as failure-message context.

4. **The chain/dot greedy-operand wrapping bug.** `E_Chain`'s head, each
   `H_ChainOp` rhs, and the `E_Dot` receiver were mapped without
   `wrapExpArg`, so `x + (if c then 1 else 2) + 3` mapped to a tree
   that PRINTS as `x + if c then 1 else 2 + 3` — a reparse swallows
   `+ 3` into the else branch (semantics-changing, invisible to the
   normalized comparator by design, caught by review). All three slots
   now wrap greedy-bodied operands, with unit tests for each shape.

5. **Read.hs depth guard tightened to match C exactly.** The generic
   reader counted every list — including the `(seq ...)`/`(some X)`/
   `(none)` wrappers — against `WOK_SEXPR_MAX_DEPTH`, while C's
   schema-driven reader depth-checks only NODES (`parse_opt`/`parse_seq`
   run at the parent node's depth). The Haskell reader now treats
   wrapper-headed lists as depth-transparent, so both readers accept
   exactly the same nesting envelope.
