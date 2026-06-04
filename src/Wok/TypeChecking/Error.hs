-- | Type errors and warnings emitted by the HM core checker.
module Wok.TypeChecking.Error
  ( SourceSpan
  , TypeError (..)
  , Warning (..)
  ) where

import Data.Text (Text)
import GeneratedParser.Wok.Abs (BNFC'Position)
import Wok.TypeChecking.Types (CRow, CType)

-- | A source location. Currently the start position of the offending
-- token (BNFC only records token starts, not full spans).
type SourceSpan = BNFC'Position

data TypeError
  = Mismatch SourceSpan CType CType
  | OccursCheck SourceSpan Int CType
  | UnknownVar SourceSpan Text
  | UnknownCon SourceSpan Text
  | UnknownTyCon SourceSpan Text
  | ArityMismatch SourceSpan Text Int Int
    -- ^ name, expected, got
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
  | DuplicateOperation SourceSpan Text Text
    -- ^ Two operations with the same name in one effect decl (effect, op).
  | HandlerCoverage SourceSpan Text [Text]
    -- ^ A handler omits operations of the handled effect (effect, missing ops).
  | DuplicateReturnArm SourceSpan
    -- ^ A handler has more than one @return@ arm; only one is allowed.
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
  deriving (Show)
  -- Note: the @eff@/@row@ domain split (an @eff@ var in a record tail, or a
  -- @row@ var in a @with@ clause) needs no type error -- the two are disjoint
  -- grammar productions (EffectRow vs RowContrib), so a domain mix is a parse
  -- error.

-- | Non-fatal diagnostics emitted by the typechecker.
data Warning
  = BodylessBinding Text SourceSpan
    -- ^ A signature had no matching equation. Still enters the env verbatim;
    -- only emitted for UserFile-origin modules (not Embedded / Std.Base).
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
  deriving (Eq, Show)
