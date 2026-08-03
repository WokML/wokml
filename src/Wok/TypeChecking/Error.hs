-- | Type errors and warnings emitted by the HM core checker.
module Wok.TypeChecking.Error
  ( SourceSpan
  , TypeError (..)
  , Warning (..)
  ) where

import Data.Text (Text)
import GeneratedParser.Wok.Abs (BNFC'Position)
import Wok.TypeChecking.Types (CRow, CType, Kind)

-- | A source location. Currently the start position of the offending
-- token (BNFC only records token starts, not full spans).
type SourceSpan = BNFC'Position

data TypeError
  = Mismatch SourceSpan CType CType
  | KindMismatch SourceSpan CType CType
    -- ^ Two types of different KINDS were unified (e.g. a row where a `*`-kinded
    -- type was expected). Cannot arise from surface programs in Slice A (every
    -- type is well-kinded); guards the kinded representation for later slices.
  | TyConArgKind SourceSpan Text Int Kind Kind
    -- ^ Tycon application kind error: <tycon> parameter #<i> (0-based) expects
    -- kind <expected>, but the argument has kind <actual>. The application-site
    -- analogue of the unification-level KindMismatch (slice B).
  | FieldKindError SourceSpan Kind
    -- ^ A constructor field's type must have kind `*`, but it has kind <actual>
    -- (a row-typed field, e.g. `Box e` with `e:KEffect`). Caught at field
    -- translation, preempting a cryptic downstream KindMismatch (slice B).
  | OccursCheck SourceSpan Int CType
  | UnknownVar SourceSpan Text
  | UnknownCon SourceSpan Text
  | UnknownTyCon SourceSpan Text
  | ArityMismatch SourceSpan Text Int Int
    -- ^ name, expected, got
  | ClauseArityMismatch SourceSpan Text Int Int
    -- ^ Two equations for the same name disagree on argument count.
    -- Args: offending equation position, function name, first equation's
    -- arity, this equation's arity.
  | RowMismatch SourceSpan CRow CRow
  | RowOccursCheck SourceSpan Int CRow
    -- ^ A row variable occurs inside the row being assigned to it.
    -- Args: pos, the row var's uniq, the cyclic row (for diagnostics).
  | SigMismatch SourceSpan Text CType CType
    -- ^ binding name, declared, inferred
  | EscapedTyVar SourceSpan Int
  | RigidEscape SourceSpan Int
    -- ^ A skolem (rigid) type variable from a user-supplied signature was
    -- unified with something other than itself. The Int is the skolem's uniq.
    -- This means the declared signature is more general than what the body
    -- actually delivers.
  | DuplicateTyCon SourceSpan Text
  | DuplicateCon SourceSpan Text
  | DuplicateBinding SourceSpan Text
  | UnsupportedFeature SourceSpan Text
    -- ^ for module access (EProj/EProjC) in v1
  | RecordConstructorNotAValue SourceSpan Text
    -- ^ A record constructor was used in a value position.
    -- E.g. "Point is a record constructor; use Point { ... } syntax."
  | RecordConstructorNeedsBraces SourceSpan Text
    -- ^ A record constructor was applied positionally rather than with braces.
    -- E.g. "Point requires { ... } syntax; positional application not supported."
  | UnknownField SourceSpan Text Text
    -- ^ A field name is not present in the record's row.
    -- Args: position, record tag, field name.
  | NominalMismatch SourceSpan Text Text
    -- ^ Two record types with identical rows but different nominal tags were unified.
    -- E.g. "expected UserId but found OrderId".
  | NamedRowTailCaptureDeferred SourceSpan Text
    -- ^ Named row-tail capture is deferred to v2.
    -- E.g. "named row-tail capture deferred to v2; use .. to discard".
  | BareRowVar SourceSpan Text
    -- ^ A bare row variable was used where a row contribution was expected.
    -- E.g. "did you mean + row r instead of + r?".
  | NonPlusTypeOp SourceSpan Text
    -- ^ An operator other than + was used at the type level.
    -- E.g. "only + is valid as a type-level operator; found -".
  | AnonRecordNotInRowContrib SourceSpan
    -- ^ An anonymous record literal was used outside of a row contribution context.
    -- E.g. "anonymous record { ... } only allowed as the RHS of +".
  | AnonRowTailInParam SourceSpan
    -- ^ An anonymous @..@ row tail (effect or record) appears in a
    -- contravariant (parameter) position, where it cannot thread and could
    -- only drop effects/fields. Use a named tail (@eff e@ / @row r@) to carry
    -- it through. E.g. @(a -> b with ..) -> ...@ is rejected; use @eff e@.
  | AmbiguousAccessor SourceSpan Text
    -- ^ A dot accessor @x.op@ whose receiver's type could not be resolved to a
    -- record or an effect-instance handle (an unsolved metavar after forcing).
    -- The dispatch is type-directed, so an unannotated receiver is ambiguous:
    -- annotate the receiver (e.g. @(c : State U64).get@). Args: position, label.
  | NotARecord SourceSpan CType
    -- ^ Field access was attempted on a value whose type is not a record.
    -- Algebraic-effects (v1) errors.
  | MissingEffectDecl SourceSpan Text
    -- ^ @with FooBar@ where @FooBar@ is not a declared effect.
  | UndischargedEffect SourceSpan Text
    -- ^ An operation of effect @E@ is used but @E@ is absent from a closed
    -- effect row (the enclosing function's @with@ clause lacks it).
  | UnknownOperation SourceSpan Text Text
    -- ^ @E.op@ where @op@ is not an operation of effect @E@ (effect, op).
  | MalformedHandlerArm SourceSpan Text Text
    -- ^ A handler arm for a KNOWN operation has an invalid pattern shape:
    --   more than (op arity + 1) patterns, or a non-variable continuation
    --   binder. Args: position, effect name, operation name.
  | HandlerOpAmbiguous SourceSpan Text [Text]
    -- ^ An unqualified handler-arm op name is declared by more than one header
    --   effect. Args: position, op name, candidate effect names. Re-qualify.
  | UnknownUnqualifiedOp SourceSpan Text
    -- ^ An unqualified handler arm with arguments names no operation of any
    --   header effect. Args: position, op name.
  | HandlerEffectNotInHeader SourceSpan Text
    -- ^ A qualified handler arm names an effect absent from the (non-empty)
    --   header (a strict "exactly these effects" contract). Args: position, effect.
  | EmptyHandler SourceSpan
    -- ^ A `with { }` / `with E { }` with zero arms handles nothing. Args: position.
  | DuplicateOperation SourceSpan Text Text
    -- ^ Two operations with the same name in one effect decl (effect, op).
  | HandlerCoverage SourceSpan Text [Text]
    -- ^ A handler omits operations of the handled effect (effect, missing ops).
  | DuplicateReturnArm SourceSpan
    -- ^ A handler has more than one @return@ arm; only one is allowed.
  | DuplicateHandlerParam SourceSpan
    -- ^ A parameterized handler block declares more than one @name = init@
    --   entry; a handler block may declare at most one such parameter.
  | BareHandlerParam SourceSpan Text
    -- ^ A handler-local state entry was written in the bare @name = init@ form;
    --   it must be declared with @var@ (@var name = init@). Carries the offending
    --   binder name so the message points at it.
  | UnknownClass Text
    -- ^ An instance references a class that has not been declared.
  | DuplicateClass Text
    -- ^ A class name is registered more than once. Arg: class name.
  | MalformedClassDecl Text
    -- ^ A class declaration is malformed (e.g. not exactly one class
    -- parameter). Arg: human-readable detail.
  | MalformedInstance Text
    -- ^ An instance declaration is malformed (e.g. not exactly one head
    -- argument, a head that is not a type-constructor application, an
    -- unbound type variable, a type-level extension, or a multi-argument
    -- context constraint). Arg: human-readable detail.
  | OverlappingInstance Text Text
    -- ^ A second instance for the same (class, head tycon) pair.
    -- Args: class name, head tycon rendering.
  | InstanceNotSmaller Text Text
    -- ^ An instance context constraint's argument is not structurally
    -- smaller than the instance head (termination check).
    -- Args: class name, head rendering.
  | MissingMethod Text Text
    -- ^ An instance does not provide a class method and the class has no
    -- default for it. Args: instance head rendering, method name.
  | AmbiguousConstraint Text
    -- ^ A constraint's variable does not appear in the type being
    -- constrained, so no instance can ever be selected. Arg: class name.
  | NoInstance Text Text
    -- ^ No instance exists to discharge a constraint.
    -- Args: class name, type rendering.
  | UnsupportedHeadPattern SourceSpan Text Text
    -- ^ A function-head clause group routed through the match compiler contains a
    -- pattern shape the compiler cannot lower. Args: position, function name,
    -- a human description of the unsupported pattern.
  | CarrierEscape SourceSpan Text
    -- ^ A second-class effect-instance handle (or a closure capturing one)
    -- escapes its scope. The carrier rule (named effect instances, §4.3) permits
    -- a handle to appear ONLY as the receiver of a named perform (@x.op@) or as
    -- an argument passed into a handle-typed parameter slot. Anywhere else
    -- (returned, stored in a constructor/record/tuple, put in a list, or captured
    -- by an escaping closure) is rejected: "instance handle cannot escape its
    -- scope". Args: position (the enclosing binding, since the typed AST carries
    -- no per-node span), the offending binding's name.
  | FutureConsumedTwice SourceSpan Text
    -- ^ A coroutine 'Future' binding is consumed more than once along a single
    -- control-flow path. A future is consumed by @resume@ XOR @cancel@, at most
    -- once total; @value@ reads are non-consuming. This affine bound is a LOCAL
    -- analysis (futures are second-class via the carrier rule) run after
    -- inference, beside 'CarrierEscape': it counts consuming uses (sequence =
    -- sum, branch = max) of each Future-typed binding within a function body and
    -- rejects any count > 1. Conservative: aliasing or unanalyzable flow that
    -- could consume twice is rejected (sound over-approximation). Args: position
    -- (the enclosing binding, since the typed AST carries no per-node span), the
    -- offending future binding's name.
  | IOEffectNotHandleable SourceSpan
    -- ^ A @with@-handler block targets @IO@, which is the ground effect.
    -- @IO@ has no operations and is discharged by running the program, never
    -- by a handler. Args: position (the handler site).
    -- Message: "IO is a ground effect and cannot be handled; it is discharged
    -- by running the program."
  | ExternNotAllowed SourceSpan Text
    -- ^ A UserFile module contains an @extern@ declaration. @extern@ marks a
    -- compiler-hole primitive bound to a host prim by name, and it is the trust
    -- anchor for the soundness analyses (the one-shot relaxation's escape sink and
    -- the affine check's non-consuming reader are recognised by EXTERN IDENTITY,
    -- not by name). Allowing a user to mint an @extern@ would let them forge that
    -- identity, so @extern@ is permitted ONLY in the standard prelude (Embedded
    -- origin). Args: position (the enclosing binding; the typed AST carries no
    -- per-node span) and the offending extern name.
  | ConcPayloadEffectful SourceSpan Text
    -- ^ A @Promise a@ or @Chan a@ type-application was resolved with a payload
    -- @a@ that contains a function arrow anywhere (a function-typed or
    -- effect-carrying value). Such a payload could smuggle a closure/thunk
    -- across a channel or promise, defeating the spec's load-bearing-row
    -- avoidance (spec §3.3): the concurrency carriers must transport only
    -- effect-free, first-order data. First-order data and bare polymorphic
    -- payloads (an unresolved type variable / quantified slot) are allowed; the
    -- check fires only on a concretely function-typed payload, walking into
    -- data-type arguments to catch nested arrows. Args: position (the carrier
    -- tycon's source span) and the offending payload type, rendered.
  | ForeignSymbolNotBlessed SourceSpan Text Text
    -- ^ A @foreign module@ member's (lib, C-symbol) pair is not in the
    -- blessed allow-list. Only statically-known deterministic symbols are
    -- accepted in the interpreter era; everything else is a clean error.
    -- Args: position (the @foreign module@ header), library tag, C symbol name.
    -- Message: "foreign symbol (lib, sym) is not in the blessed allow-list."
  | ForeignModuleMemberUnknown SourceSpan Text Text
    -- ^ A dotted access @M.op@ where @M@ is a declared foreign module but
    -- @op@ is not one of its declared members. Args: position, module name,
    -- member name.
    -- Message: "foreign module M has no member op."
  | AmbiguousProjectionHead SourceSpan Text
    -- ^ A ConId is registered both as an algebraic effect AND as a foreign
    -- module, making @ConId.op@ ambiguous. Args: position, the ConId.
    -- Message: "ConId is both an effect and a foreign module; rename one."
  | ForeignOwnedNeedsFree SourceSpan Text Text
    -- ^ A @foreign module@ member is declared @owned@ but the module header
    -- carries no @free@ clause. Without a free function the runtime cannot
    -- reclaim the adopted pointer. Args: position, module name, member name.
    -- Message: "owned member mem in foreign module M requires a free clause."
  | ForeignDispositionMismatch SourceSpan Text Text
    -- ^ A @foreign module@ member's declared signature disagrees with the
    -- blessed symbol's return disposition -- either the @owned@ keyword, or
    -- (for @DispBorrow@, FFI Slice 3 Task 4) the declared return TYPE, which
    -- is not @Borrow@. The blessed table is the ground truth for how the
    -- callee's return value must be handled; any mismatch would produce
    -- backend divergence (one backend errors, another silently leaks,
    -- double-frees, or disagrees with its checked type). Args: position,
    -- member name, guidance message.
    --
    -- For @DispAdopt@: "foreign member 'mem' returns an owned buffer; declare
    -- it @owned@ and give the module a @free@ clause."
    -- For @DispScalar@ or @DispCopy@: "foreign member 'mem' returns a scalar;
    -- remove @owned@."
    -- For @DispBorrow@: "foreign member 'mem' returns a borrowed view; remove
    -- @owned@" (if @owned@ was wrongly declared), or "... its declared return
    -- type must be @Borrow@" (if the return type disagrees with the blessed
    -- disposition).
  | DuplicateForeignModule SourceSpan Text
    -- ^ A @foreign module@ declaration uses a name that is already registered
    -- as a foreign module in the same file (or via an import). The second
    -- declaration would silently overwrite the first's member set, losing
    -- members with no error. Args: position (the duplicate header), module name.
    -- Message: "foreign module M is already declared; rename one."
  | ForeignMemberPartialApp SourceSpan Text Text
    -- ^ A foreign-module member was used as a first-class value (partial
    -- application or bare reference) rather than being fully applied at the
    -- call site. Foreign members are not closures and cannot be passed around;
    -- they must be used as the direct head of a saturated call. Args: position,
    -- module name, member name.
    -- Message: "foreign member M.f must be fully applied; it cannot be used as
    -- a first-class value."
  | ForeignOwnedArgNotBytes SourceSpan Text Text
    -- ^ A @foreign module@ member declares a parameter as @owned T@ (FFI
    -- Slice 4) where @T@ (after stripping @owned@) is not @Bytes@. The
    -- transfer-full argument tier is scoped to @Bytes@ only in this slice --
    -- there is no blessed sink for any other owned-INTO-C payload shape.
    -- Args: position (the member's declared type), member name, guidance
    -- message.
    -- Message: "foreign member 'mem' declares an `owned` parameter of type
    -- <T>; `owned` is only supported on `Bytes` parameters."
  | ForeignOwnedArgNotBlessed SourceSpan Text Text
    -- ^ A @foreign module@ member declares an @owned@ parameter, but the
    -- blessed table's entry for its (lib, C-symbol) pair does not carry a
    -- matching 'Wok.FFI.Blessed.MoveOut' at that argument position. The
    -- blessed table is authoritative for what the runtime actually does with
    -- an argument; a mismatch here would mean the checked signature promises
    -- a transfer-full handoff the runtime never performs (or vice versa).
    -- Args: position, member name, guidance message.
    -- Message: "foreign member 'mem' declares an `owned` parameter but is not
    -- blessed as a transfer-full argument sink at that position."
  | ForeignBlessedMoveOutNeedsOwned SourceSpan Text Text
    -- ^ The dual of 'ForeignOwnedArgNotBlessed': the blessed table marks an
    -- argument position 'Wok.FFI.Blessed.MoveOut' (transfer-full), but the
    -- member's surface signature did NOT declare that parameter @owned@. This
    -- is a latent use-after-move: the runtime router (FFI Slice 4 Task 4) acts
    -- on the BLESSED transfer list, so it would move/consume the argument
    -- while the checker treated it as a plain (borrowed) value the caller may
    -- still use. Rejecting here keeps the surface @owned@ and the blessed
    -- 'MoveOut' in agreement at every position. Args: position, member name,
    -- guidance message.
    -- Message: "foreign member 'mem' is blessed to take ownership of parameter
    -- N; declare it as `owned <T>`."
  | OwnedModifierMisplaced SourceSpan Text
    -- ^ A surface `owned` type modifier (FFI Slice 4) appeared somewhere other
    -- than a `Bytes` parameter head of a `foreign module` member: in ordinary
    -- (non-foreign) code, on a foreign member's return type, or nested inside
    -- a compound parameter type (e.g. `Array (owned Bytes)`). `owned` is
    -- boundary metadata scoped to that one position; 'Wok.TypeChecking.Infer.
    -- registerMember's `classifyOwnedParams' strips it there before the type
    -- ever reaches this check, so any `TOwned` this error fires on is by
    -- construction misplaced. Args: position, guidance message.
    -- Message: "`owned` is only allowed on a `Bytes` parameter of a
    -- foreign-module member."
  deriving (Show)
  -- Note: the @eff@/@row@ domain split (an @eff@ var in a record tail, or a
  -- @row@ var in a @with@ clause) needs no type error -- the two are disjoint
  -- grammar productions (EffectRow vs RowContrib), so a domain mix is a parse
  -- error.

-- | Non-fatal diagnostics emitted by the typechecker.
data Warning
  = BodylessBinding Text SourceSpan
    -- ^ A signature had no matching equation. Still enters the env verbatim;
    -- only emitted for UserFile-origin modules (not Embedded / Base).
  | RowShadow SourceSpan Text CType CType
    -- ^ A row-variable instantiation introduced a label collision: the concrete
    -- part of the row already had the given label, and the substituted-in row
    -- also carries it. Args: call-site position, the colliding label, the outer
    -- (existing) type, the inner (newly introduced) type.
    -- The program still typechecks; this is informational only (v1 has no
    -- escape hatch; v2 will add Lacks-style constraints).
  | NonExhaustiveRecordPattern SourceSpan Text
    -- ^ A case expression scrutinises a record type whose row is open (has a
    -- row-variable tail), but ALL arms are strict (no open '..' arm and no
    -- wildcard). The strict arms are still reachable (they match when the row
    -- variable is instantiated to RowEmpty), but the open-extension case is
    -- not covered. Args: position, the record constructor tag.
  | NonExhaustiveMatch SourceSpan Text
    -- ^ A function's clause group does not cover all inputs. Args: position, name.
  | RedundantClause SourceSpan Text Int
    -- ^ A clause can never match (shadowed). Args: position, name, 0-based clause index.
  | ForgottenResume SourceSpan Text Text
    -- ^ An operation arm binds a NAMED continuation never referenced in its
    --   body, on a RETURNING operation (result /= Never). Args: position,
    --   effect, operation. Suppress with a `_` (wildcard) binder.
  | QualifierShadowsExisting Text Text Text
    -- ^ An import qualifier name collides with an existing in-scope name
    -- (effect, foreign module, or record constructor). The qualifier wins
    -- (takes precedence in the typecheck arm); this warns the user. Args:
    -- qualifier name, source module name, shadowed-namespace description.
  deriving (Eq, Show)
