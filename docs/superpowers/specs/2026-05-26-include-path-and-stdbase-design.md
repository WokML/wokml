# Include path and `Std.Base` Prelude — design

Status: draft (awaiting user review)
Owner: zy
Date: 2026-05-26

## Motivation

`Wok.TypeChecking.Builtins.initialEnv` currently hand-codes the entire initial
typing environment in Haskell: `Int`/`Char`/`String`/`Bool` tycons, `True`/`False`
constructors, arithmetic / comparison / list / dollar operator schemes, plus
the unit, list, and tuple-family tycons. This makes the "default Prelude" a
Haskell file rather than a Wok file, and gives the compiler no way to consume
*other* Wok files as compilation units — today the executable takes exactly
one file path and processes it in isolation.

This spec replaces hand-coded Builtins with a pure-Wok `Std.Base` module that
the compiler embeds at build time, and stands up a minimal multi-module
loader so that the entry file and any additional `-I`-listed files are
typechecked together with `Std.Base` automatically in scope.

## Goals

- Replace as much of `Builtins.initialEnv` as can be expressed in surface Wok
  with a pure-Wok `Std.Base` module.
- Embed `Std.Base` in the compiler binary at build time; no runtime disk
  lookup or `$WOK_PATH` indirection.
- Resolve `import X.Y` declarations against an in-memory map of module name
  to parsed module, populated from CLI-provided files plus the embedded
  Prelude.
- Run the parse + reorder + typecheck pipeline over multiple modules in
  topological order, threading both fixity tables and typing environments
  across module boundaries.
- Introduce a warning channel so that bodyless signatures (a legitimate
  pattern for `Std.Base`'s primitive operators) can be flagged when they
  appear in user code.

## Non-goals (deferred / out of scope)

- Directory-search module resolution (no `-I <dir>` filesystem walk). Module
  names map only to user-provided files plus the embedded Prelude; deriving
  `Std/Base.wok` from `Std.Base` is explicitly not done.
- Multiple sized integer types. `u64` is the sole machine integer in v1.
- `Char` and `String` tycons.
- `Array n T`, `Vector T`, type-level naturals, kind `Nat`.
- Type classes, numeric defaulting, ad-hoc polymorphism for `(+)`.
- Qualified imports (`import X.Y as Z`), export lists, the `DUse` and
  `DLocal` declarations (grammar reserves them; loader treats `DUse` /
  `DLocal` as no-ops for v1).
- Warning severity, suppression flags, source-snippet rendering.
- Separate-compilation caching. Every `wok` invocation re-parses,
  re-reorders, and re-typechecks every module from source.

## High-level design

### CLI

```
wok <entry.wok> [-I <file.wok>]...
```

- The single positional argument is the entry module's file.
- Each `-I <file.wok>` adds one additional file to the in-memory module
  pool. The module's name comes from that file's `module X.Y` header.
- `Std.Base` is unconditionally inserted into the pool at startup from the
  embedded Prelude source.

### Pipeline

```
parseCli
  -> loadProgram                            (Wok.Loader)
       embed Std.Base, read user files,
       parse + buildFixityTable each,
       extract module headers + imports,
       build dep graph, topo-sort
  -> typecheckAll                           (per-module fold in topo order)
       for each LoadedModule m:
         mergedFixities = unionFixities (lmFixities <$> imports m)
                            `overlay` lmFixities m
         mergedEnv      = unionEnvs    (tmExports  <$> imports m)
                            `overlay` irreduciblePreEnv
         reordered      = reorderModuleWith mergedFixities (lmAst m)
         (envOut, decls, warnings) =
           inferProgramWith mergedEnv (lmOrigin m) reordered
         record (lmName m, TypedModule envOut decls)
  -> print warnings (stderr)
  -> print entry module's typed decls       (stdout, sorted by name)
```

The crucial split: `Wok.Reordering` previously bundled fixity-table
construction and expression reassociation in one call (`reorderModule`). To
let an importer reorder its expressions against `Std.Base`'s fixities, the
two halves are separated. The loader does the fixity-table build (cheap, no
expression walk). Expression reordering is deferred until typecheck time,
when the merged table is in hand.

## Components

### `Wok.Prelude` (new)

Single-responsibility module that exposes the embedded `Std.Base` source as
a `Text` value. Implementation uses `Data.FileEmbed.embedStringFile` against
`prelude/Std/Base.wok` relative to the project root.

```haskell
module Wok.Prelude (preludeName, preludeSource) where

preludeName   :: Text       -- "Std.Base"
preludeSource :: Text       -- contents of prelude/Std/Base.wok
```

cabal: `Wok.Prelude` added to the `wok` library's `exposed-modules`;
`file-embed` added to `build-depends`; `prelude/Std/Base.wok` added to
`extra-source-files`.

### `Wok.SourceOrigin` (new, leaf module)

Tiny module whose sole purpose is to host `Origin` upstream of both
`Wok.Loader` and `Wok.TypeChecking.Infer`, avoiding a layering reversal.

```haskell
module Wok.SourceOrigin (Origin (..), originPath) where

import Data.Text (Text)

data Origin = Embedded | UserFile FilePath
  deriving (Eq, Show)

originPath :: Origin -> String
originPath Embedded        = "<embedded Std.Base>"
originPath (UserFile path) = path
```

Imported by `Wok.Loader` (which tags every `LoadedModule` with an `Origin`)
and by `Wok.TypeChecking.Infer` (which uses it to decide whether to emit
bodyless-sig warnings).

### `Wok.Loader` (new)

```haskell
module Wok.Loader where

type ModuleName = Text

-- `Origin` itself is defined in the new leaf module `Wok.SourceOrigin`
-- (see below) so that `Wok.TypeChecking.Infer` can take it as a
-- parameter without depending on `Wok.Loader`.
import Wok.SourceOrigin (Origin (..))

data LoadedModule = LoadedModule
  { lmName     :: ModuleName
  , lmOrigin   :: Origin
  , lmAst      :: Module           -- post-parse, PRE-reorder
  , lmImports  :: [ModuleName]     -- deduped, source order
  , lmFixities :: FixityTable      -- this module's own DFixity decls only
  }

data LoaderError
  = LoadFileMissing               FilePath
  | LoadParseError                FilePath String
  | LoadFixityError               FilePath [FixityError]              -- per-module, at load
  | LoadReorderError              ModuleName [ReorderError]           -- per-module, at typecheck
  | LoadCrossModuleFixityConflict Text ModuleName ModuleName          -- op name, two modules
  | LoadCrossModuleNameConflict   Text ModuleName ModuleName          -- value/con/tycon name, two modules
  | LoadNoModuleHeader            FilePath
  | LoadDuplicateModule           ModuleName FilePath FilePath
  | LoadImportUnknown             ModuleName ModuleName               -- importer, missing target
  | LoadImportCycle               [ModuleName]

loadProgram :: FilePath -> [FilePath] -> IO (Either LoaderError [LoadedModule])
-- Returns modules in topo order: Std.Base first, entry last.
```

Loader algorithm:

1. Parse the embedded `Std.Base` source. Build its `FixityTable`. Record
   `lmOrigin = Embedded`.
2. For each `-I` file and the entry file (in that order): `readFile`,
   `parse`, `buildFixityTable`. Record `lmOrigin = UserFile path`.
3. For each parsed `Module`: locate the first decl. It must be `DModule
   modPath`; flatten the `ModPath` into a dotted `Text` (e.g. `"Std.Base"`).
   Missing header is rejected with `LoadNoModuleHeader`.
4. Build `Map ModuleName LoadedModule`. Duplicate names across files are
   rejected with `LoadDuplicateModule`.
5. For each module, collect `DImport` decls into `lmImports`. Verify each
   target name exists in the map (`LoadImportUnknown`).
6. Build dep graph; topo-sort via `Data.Graph.stronglyConnComp` (same
   library `Wok.Reordering` already uses for fixity cycle detection at
   `src/Wok/Reordering.hs:101`). Any cyclic SCC is rejected with
   `LoadImportCycle`. Self-imports count as cycles.
7. Return modules in topo order.

### `Wok.Reordering` (modified)

New exported entry point:

```haskell
reorderModuleWith :: FixityTable -> Module -> Either [ReorderError] Module
```

The existing `reorderModule` becomes `reorderModuleWith
emptyFixityTable` for back-compat with direct callers / tests. Implementation:
`reorderModuleWith table m = mapLeft (map FixityErr) ... <whatever>`. The
internal `reorderAst` walker is unchanged; only the table-source changes.

Cross-module fixity merging happens in the loader's per-module typecheck
step, not inside `Wok.Reordering`. The new combinator:

```haskell
overlayFixities :: FixityTable -> FixityTable -> Either [FixityError] FixityTable
```

is left-biased on success and returns `RedeclaredOp` entries for any name
that appears in both tables. The loader catches these and wraps them as
`LoadCrossModuleFixityConflict opName moduleA moduleB`.

### `Wok.TypeChecking.Builtins` (shrunk)

```haskell
initialEnv :: Env
initialEnv = emptyEnv
  { envTyCons = Map.fromList tyConEntries
  }
  where
    tyConEntries =
      [ ("u64", TyConInfo KStar 0 [])
      , ("()",  TyConInfo KStar 0 [])
      , ("[]",  TyConInfo (KArrow KStar KStar) 1 [])
      ] ++ [ (tupleName n, TyConInfo (tupleKind n) n []) | n <- [2 .. 16] ]
```

`envCons` and `envVars` are empty. `Bool`/`True`/`False`, `Option`,
`Result`, `id`, `const`, and every operator come from `Std.Base`.

The `TyCon` data type in `Wok.TypeChecking.Types` renames `TcInt` to
`TcU64`. Consumers updated: `Builtins.hs`, `Infer.hs` (`resolveTyCon`,
`prettyCType`'s special-case for the integer tycon). Integer-literal
inference, which today produces `Int`, now produces `u64`.

### `Wok.TypeChecking` / `Infer` (modified)

New signature:

```haskell
inferProgramWith
  :: Env -> Origin -> Module
  -> Either TypeError (Env, [TypedDecl], [Warning])
```

The old `inferProgram :: Module -> Either TypeError (Env, [TypedDecl])`
becomes a thin convenience over `inferProgramWith Builtins.initialEnv
(UserFile "<unknown>") <module>` for test back-compat (returning `(env,
decls)` by discarding warnings).

Two changes inside `inferLetGroup` and `inferTopLetGroup`:

1. **Bodyless signatures become bindings.** After
   `results <- mapM finalizeGroup unified`, compute the set of names
   covered by equation groups, then walk `sigMap` for the complement:

   ```haskell
   let coveredNames = Set.fromList (map fst groups)
       bodylessSigs = [ (n, s) | (n, s) <- Map.toList sigMap
                               , not (Set.member n coveredNames) ]
   ```

   Merge `bodylessSigs` into the env extension alongside `polyBindings`.
   Bodyless sigs do not invoke `freezeSig` — there is no body to over-promise
   against, so the user's scheme is taken verbatim.

2. **Bodyless warnings for user files.** For each bodyless sig, when
   `origin = UserFile _`, emit a `BodylessBinding name pos` warning. The
   binding still enters the env (so importers see it); the warning is purely
   advisory.

### Warning channel (new)

```haskell
data Warning = BodylessBinding Text BNFC'Position
```

Single variant for v1. The `Origin` is not stored on the warning; the
loader assembles the full pretty-printed warning at print time, using
`originPath` for the file path.

### `freezeSig` rename

Function `skolemize :: Scheme -> TC s (Type s)` is renamed to `freezeSig`.
The `Rigid` constructor in `Wok.TypeChecking.Types` is unchanged (already a
plain-English name). All call sites and comments updated. The reference to
"over-promising" in `syntax.md` is reworded to drop the word "skolemize"
and use the new name.

Function docstring (new):

> Replace each `forall`-bound type variable in a user's signature with a
> fresh **rigid** type — one the unifier treats as an opaque constant.
> Catches signatures that over-promise: in `double : a -> a; double n = n + n`,
> the body forces `a = u64` (because `(+)` is `u64 -> u64 -> u64`), so the
> body's inferred type is `u64 -> u64`. Without freezing, unifying `a -> a`
> with `u64 -> u64` silently weakens the sig to `u64 -> u64`. With freezing,
> the sig becomes `rigid_1 -> rigid_1`, unification with `u64 -> u64` fails,
> and the over-promise surfaces as a type error.

### Main (rewritten)

```haskell
main :: IO ()
main = do
  args <- getArgs
  case parseCli args of
    Left u            -> hPutStrLn stderr u >> exitFailure
    Right (e, extras) -> runApp e extras

parseCli :: [String] -> Either String (FilePath, [FilePath])
-- hand-rolled; accepts <entry> with zero or more -I <file> pairs.

runApp :: FilePath -> [FilePath] -> IO ()
runApp entry extras = do
  loaded <- loadProgram entry extras
  case loaded of
    Left lerr -> hPutStrLn stderr (prettyLoaderError lerr) >> exitFailure
    Right ms  -> case typecheckAll ms of
      Left terr -> hPutStrLn stderr (prettyTypeError terr) >> exitFailure
      Right (typedMap, warnings) -> do
        mapM_ (hPutStrLn stderr . prettyWarning) warnings
        let entryName = lmName (last ms)
            entryMod  = typedMap Map.! entryName
        mapM_ printDecl (sortBy (comparing tdName) (tmDecls entryMod))
```

`typecheckAll :: [LoadedModule] -> Either TypeError (Map ModuleName
TypedModule, [Warning])` is the per-module fold described under "Pipeline".

`TypedModule` is the per-module typecheck result:

```haskell
data TypedModule = TypedModule
  { tmName    :: ModuleName
  , tmExports :: Env             -- everything the module brings into scope
  , tmDecls   :: [TypedDecl]     -- for pretty-printing the entry module
  }
```

## `Std.Base` contents

Repo location: `prelude/Std/Base.wok`. Editable like any other file; binary
must be rebuilt for changes to take effect at runtime (this is fine — the
embed mechanism intentionally has zero runtime disk lookup).

```wok
module Std.Base

fixity + left
fixity - left
fixity * left tighter than +
fixity / left tighter than +
fixity == left looser than +
fixity /= left looser than +
fixity && left looser than ==
fixity || left looser than &&
fixity ++ right
fixity $  right looser than ||

data Bool     = True | False
data Option a = Some a | None
data Result t e = Ok t | Err e

(+)  : u64 -> u64 -> u64
(-)  : u64 -> u64 -> u64
(*)  : u64 -> u64 -> u64
(/)  : u64 -> u64 -> u64
div  : u64 -> u64 -> u64
mod  : u64 -> u64 -> u64
(==) : u64 -> u64 -> Bool
(/=) : u64 -> u64 -> Bool
(&&) : Bool -> Bool -> Bool
(||) : Bool -> Bool -> Bool
(++) : [a] -> [a] -> [a]
($)  : (a -> b) -> a -> b

id : a -> a
id x = x

const : a -> b -> a
const x y = x
```

Notes:

- No `data List` — the `[]` tycon (from the irreducible pre-env) is the
  only cons-list type. Shipping both `List a` and `[]` would be the same
  redundancy the spec rejects for `Either` vs `Result`.
- `(/)`, `div`, `mod` are all kept for parity with current `Builtins.hs`.
- Operators are declared via bodyless sigs; their *runtime* meaning is the
  compiler's responsibility once codegen lands (not in this spec).

## Module resolution rules

- A module's name is whatever its `module X.Y` header declares. The file
  path on disk is irrelevant for resolution. `wok myEntry.wok` works
  regardless of what header it declares; `import` lines target module names,
  not paths.
- Header is mandatory. A file with no `DModule` decl is rejected at load
  time.
- Module names must be unique across the entire load set (entry +
  every `-I` file + embedded Std.Base). Duplicates are rejected.
- `import X.Y` looks up `X.Y` in the module map. Misses are
  `LoadImportUnknown`.
- The `MPDot` form is now supported. `Std.Base` is flattened to the dotted
  text `"Std.Base"` at the loader boundary; `modPathHead` in
  `Wok.TypeChecking.Infer` (which today errors on `MPDot`) is replaced /
  augmented with a `modPathText :: ModPath -> Text` helper used by both the
  loader and the typechecker for tycon/constructor lookup.

## Cross-module fixity merging

For each module `m` in topo order:

```
mergedFixities = foldM overlayFixities emptyFixityTable
                   (lmFixities <$> importsOf m ++ [m])
```

`overlayFixities :: FixityTable -> FixityTable -> Either [FixityError]
FixityTable` is left-biased on disjoint inputs and returns `[RedeclaredOp
op posA posB]` for any operator that appears in both tables. The loader
catches these and emits `LoadCrossModuleFixityConflict op moduleA moduleB`,
attributing the conflict to the two contributing modules (which is the
information a user actually wants — positions inside `RedeclaredOp` may
point to unhelpful generated-file locations for the embedded `Std.Base`).

`overlayFixities` is new; placed in `Wok.Reordering` next to
`buildFixityTable` to keep fixity-table operations co-located.

## Cross-module env merging

For each module `m`:

```
mergedEnv = foldM overlayEnvs irreduciblePreEnv
              (tmExports <$> importsOf m)
```

`overlayEnvs :: Env -> Env -> Either [(EnvNs, Text)] Env` unions the three
maps (`envVars`, `envCons`, `envTyCons`). On any name collision (across any
of the three namespaces) it returns the offending namespace + name pairs.
The loader catches these and emits
`LoadCrossModuleNameConflict name moduleA moduleB` per offending name.

```haskell
data EnvNs = NsVar | NsCon | NsTyCon
```

`overlayEnvs` and `EnvNs` are new; placed in `Wok.TypeChecking.Env` next
to `emptyEnv`.

## Bodyless signature semantics

- A `LDSig`/`DSig` whose name has no matching `LDEqn`/`DEqn` is registered
  as an env binding with the declared scheme. The user's scheme is taken
  verbatim — no `freezeSig`, no body inference.
- Multi-name sigs (`a, b, c : Int`) already fan out to one `sigMap` entry
  per name in `buildSigMap`. The bodyless rule applies per name.
- Allowed in `let` blocks as well as top level, for symmetry. A future
  warning pass may flag "bodyless inside a let block" as suspicious; that
  is not in this spec.
- In `UserFile` modules every bodyless sig emits a `BodylessBinding`
  warning. In `Embedded` modules they are silent (that is the whole point
  of the feature for `Std.Base`).

## Error model

Loader errors (`LoaderError`) surface before typechecking and abort the
run. The pretty-printer in `Main` produces a single human-readable line per
error, plus a usage-hint footer for `LoadNoModuleHeader`.

Typechecker errors (`TypeError`, existing) abort the run with the existing
`Show TypeError` text for v1; a polished `prettyTypeError` is out of scope.

Reordering errors (`ReorderError`) inside `reorderModuleWith` surface as a
new `LoadReorderError ModuleName [ReorderError]` loader error variant
(reordering is now driven by the loader, so its errors flow through the
loader's error channel).

## Warning model

- `data Warning = BodylessBinding Text BNFC'Position`
- Threaded out of `inferProgramWith` and accumulated by `typecheckAll`.
- Printed to `stderr` from `Main` before the typed-decl output, so warnings
  appear above the typed-decl wall when both streams are combined.
- No severity, no suppression. Warnings never abort the run.

## Test plan

Add to the existing `tasty` suite:

| Test                          | Asserts                                              |
| ----------------------------- | ---------------------------------------------------- |
| `loadsTinyProgram`            | Entry with `import Std.Base` + `f x = x + 1` typechecks; `f : u64 -> u64` in env. |
| `rejectsMissingHeader`        | Entry without `module X.Y` -> `LoadNoModuleHeader`.  |
| `rejectsUnknownImport`        | Entry `import Foo.Bar` -> `LoadImportUnknown`.       |
| `rejectsDuplicateModule`      | Two `-I` files both `module A` -> `LoadDuplicateModule`. |
| `rejectsImportCycle`          | A imports B, B imports A -> `LoadImportCycle`.        |
| `rejectsSelfImport`           | A imports A -> `LoadImportCycle`.                     |
| `warnsOnBodylessUserSig`      | `-I` file with `foo : u64` and no equation -> warning emitted; `foo` still in env. |
| `silentBodylessInPrelude`     | Embedded `Std.Base`'s `(+)` produces no warning.     |
| `crossModuleFixity`           | Entry uses `a + b * c`, picks up `Std.Base`'s `* tighter than +`. |
| `crossModuleFixityRedecl`     | Entry redeclares `fixity + left` -> `RedeclaredOp` via `LoadCrossModuleFixityConflict` or analogous. |
| `crossModuleNameConflict`     | Two `-I` modules export same name, entry imports both -> env-merge conflict surfaced as `TypeError` (or new variant). |
| `bodylessSigsAreVerbatim`     | Test that `f : a -> a` as a bodyless sig stays `forall a. a -> a`, not subjected to `freezeSig`. |
| `examplesPort`                | `examples/hehe.wok` and `examples/types-tour.wok`, both prepended with `module Main` + `import Std.Base`, typecheck unchanged. |

Golden test files: `test/golden/<name>.wok` plus a `.expected` file
listing the sorted typed-decl output.

## Migration

The two existing example files need one-time edits:

- `examples/hehe.wok`: prepend `module Main`. Delete the entire fixity
  block (now in `Std.Base`). Prepend `import Std.Base`. The `data Bool =
  True | False` decl in section 2 must be deleted (now in `Std.Base`;
  redeclaration is a conflict).
- `examples/types-tour.wok`: prepend `module Main` and `import Std.Base`.
  Delete its `data Maybe` and `data List` decls (replaced by `Std.Base`'s
  `Option` and the built-in `[]`). Rewrite `mapMaybe`, `fromMaybe`,
  `headList` to use `Option` / `Some` / `None` and `[]` instead of `Maybe`
  / `Just` / `Nothing` and `List`.

These edits are tracked as a single migration task in the plan.

## File / module changes summary

| File                                       | Action                                                                 |
| ------------------------------------------ | ---------------------------------------------------------------------- |
| `prelude/Std/Base.wok`                     | New. Embedded Prelude source.                                          |
| `src/Wok/Prelude.hs`                       | New. Exposes `preludeName`, `preludeSource` via `Data.FileEmbed`.      |
| `src/Wok/SourceOrigin.hs`                  | New leaf module. `Origin (..)`, `originPath`.                          |
| `src/Wok/Loader.hs`                        | New. Module map, dep graph, topo sort, `LoaderError`, `loadProgram`.   |
| `src/Wok/Reordering.hs`                    | Add `reorderModuleWith`, `overlayFixities`. Existing `reorderModule` becomes thin wrapper. |
| `src/Wok/TypeChecking/Builtins.hs`         | Shrink `initialEnv` to irreducible pre-env (u64, (), [], tuples 2..16). |
| `src/Wok/TypeChecking/Types.hs`            | `TcInt` -> `TcU64`.                                                    |
| `src/Wok/TypeChecking/Env.hs`              | Add `overlayEnvs`, `EnvNs`.                                            |
| `src/Wok/TypeChecking/Infer.hs`            | Bodyless-sig fix in `inferLetGroup` + `inferTopLetGroup`. New `inferProgramWith` returning warnings. `freezeSig` rename. `modPathHead` -> `modPathText`. `resolveTyCon`/`prettyCType` updated for `TcU64`. |
| `src/Wok/TypeChecking.hs`                  | Re-export `Warning`, `inferProgramWith`, `Origin`.                     |
| `app/Main.hs`                              | Rewrite for new CLI + pipeline. `parseCli`, `runApp`, `typecheckAll`, pretty-printers. |
| `examples/hehe.wok`                        | Migration: add header + import, delete redundant decls.                |
| `examples/types-tour.wok`                  | Migration: add header + import, rewrite to `Option` / `[]`.            |
| `wok.cabal`                                | New `exposed-modules`: `Wok.Prelude`, `Wok.SourceOrigin`, `Wok.Loader`. Add `file-embed` dep. `extra-source-files: prelude/Std/Base.wok`. |
| `syntax.md`                                | Reword the over-promising note to drop "skolemize".                    |
| `test/` (tests)                            | Add unit + golden tests per "Test plan".                               |
