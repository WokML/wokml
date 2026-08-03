module Wok.IR.Multiplicity
  ( Card (..)
  , joinC
  , addC
  , cardOf
  , cardOfWithTrust
  , computeTrustMap
  , MultiplicityError (..)
  , analyzeModule
  , renderMultiplicityError
  , prettyMultiplicity
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Name (Name, JoinId, Unique, nameUniq)
import Wok.IR.Anf

-- | The {0,1,omega} cardinality lattice on continuation use. Zero <= One <= Many.
data Card = Zero | One | Many
  deriving (Eq, Show)

-- | Branch combinator (join): only one path runs, so take the max on the chain.
joinC :: Card -> Card -> Card
joinC a b = case (a, b) of
  (Many, _) -> Many
  (_, Many) -> Many
  (One, _)  -> One
  (_, One)  -> One
  _         -> Zero

-- | Sequence combinator (+): both run; saturating, so two resumes = Many.
addC :: Card -> Card -> Card
addC Zero x = x
addC x Zero = x
addC _ _    = Many

-- | Does the resume binder `r` occur in this atom? (Identity is the Unique.)
mentionsAtom :: Name -> Atom -> Bool
mentionsAtom r (AVar n) = n == r
mentionsAtom _ (ALit _) = False
mentionsAtom _ (APrim _) = False

mentionsAny :: Name -> [Atom] -> Bool
mentionsAny r = any (mentionsAtom r)

-- | The affine analysis: an upper bound on how many times `r` is invoked in `e`.
-- Type-free; the single soundness rule is that any occurrence of `r` that is NOT
-- the head of a saturated application is an escape and yields Many.
--
-- @onceSinks@ is the set of qualified @(module, name)@ identities of the
-- prelude's trusted once-sink @extern@ prims (the escape sinks that resume their
-- continuation argument at most once; e.g. @(Control, "__coro_susp")@), the
-- static 'Wok.IR.PrimNames.onceSinkNames' in production. The trusted-once
-- relaxation fires ONLY for an 'APrim' application head whose @(module, name)@ is
-- in this set; a USER binding merely HINTED @__coro_susp@ resolves to an 'AVar'
-- (never 'APrim') and is NOT trusted. An empty set means the relaxation never
-- fires.
--
-- Back-compat shim: 'cardOf' is 'cardOfWithTrust' with an EMPTY trust map, i.e.
-- the inter-procedural relaxation (clause B below) never fires. This preserves
-- the original conservative, purely-intra-procedural behaviour for every caller
-- (and unit test) that does not supply a trust map.
cardOf :: Set (Text, Text) -> Name -> Expr -> Card
cardOf onceSinks = cardOfWithTrust onceSinks Map.empty Map.empty

-- | The same affine analysis as 'cardOf', closed over a @trustMap@ that records,
-- for each top-level function (keyed by its 'Unique'), the per-parameter
-- cardinality of that parameter in the function body. This enables ONE extra
-- relaxation (clause B in 'cardRhs'): when the resume binder @r@ is passed
-- DIRECTLY (as a bare @AVar r@ argument) to a known function @f@, we may charge
-- only @f@'s trusted card for that slot instead of the blanket @Many@.
--
-- SOUNDNESS. The relaxation lowers a card below @Many@ ONLY when (a) @f@ has a
-- trust-map entry whose slot for that argument position is provably @<= 1@, AND
-- (b) the continuation is handed over directly. A continuation buried in a
-- lambda/constructor/record still hits the unchanged 'RLam'/'RCon'/'RRecord'
-- rules and yields @Many@. The trust map itself is computed by a fixpoint that
-- STARTS FROM EMPTY (see 'computeTrustMap'), so a callee absent from the map is
-- treated as @Many@ for that slot; trust only ever grows monotonically as cards
-- DECREASE, hence the relaxation can never wrongly trust a multishot callee.
-- @seedEnv@ pre-populates the join-cardinality env used by the 'Jump' rule. The
-- handler's ANSWER-JOIN is seeded to 'Zero' there (see 'armCard'), because it is
-- an EXIT whose body runs after the handler returns and structurally cannot
-- invoke this arm's resume binder @r@. A join NOT in @seedEnv@ (and not
-- 'LetJoin'-bound in scope) still defaults to 'Many' (the recursive-join case),
-- so the relaxation is confined to the known exit join and can never lower a
-- genuine multi-shot below 'Many'.
cardOfWithTrust :: Set (Text, Text) -> Map Unique [Card] -> Map JoinId Card -> Name -> Expr -> Card
cardOfWithTrust onceSinks trustMap seedEnv r = go seedEnv
  where
    go :: Map JoinId Card -> Expr -> Card
    go env e = case e of
      Ret a
        | mentionsAtom r a -> Many          -- continuation returned as a value
        | otherwise        -> Zero
      Let _ rhs b -> addC (cardRhs rhs) (go env b)
      Case a alts
        | mentionsAtom r a -> Many          -- scrutinizing the continuation
        | otherwise        -> foldr (joinC . goAlt env) Zero alts
      LetJoin j _ jb b ->
        -- cj = resumes per jump to j. A recursive jump inside jb sees j NOT yet
        -- in env -> Many (sound; no fixpoint needed).
        let cj = go env jb
        in go (Map.insert j cj env) b
      Jump j as ->
        addC (Map.findWithDefault Many j env)
             (if mentionsAny r as then Many else Zero)
      LetRec defs b ->
        addC (if any (\(_, _, db) -> occursExpr r db) defs then Many else Zero)
             (go env b)
      Handle e' h ->
        addC (go env e')
             (if occursHandlerArms r h then Many else Zero)

    goAlt env (AltCon _ _ b) = go env b
    goAlt env (AltLit _ b)   = go env b
    goAlt env (AltDefault b) = go env b

    cardRhs rhs = case rhs of
      RApp (AVar f) as
        | f == r ->
            addC One (if mentionsAny r as then Many else Zero)
      -- Trusted-once axiom: handing the resume binder to a genuine prelude once-sink
      -- @extern@ (e.g. @__coro_susp@) is One. The runtime guarantees the future
      -- created from the continuation is resumed at most once. The prelude @start@
      -- desugars to a suspend arm that hands @k@ to @__coro_susp@, so this clause is
      -- LIVE whenever Control's coro surface is used. The match is on the call
      -- head being an 'APrim' whose qualified @(module, name)@ identity is in the
      -- trusted once-sink set, NOT the hint text: a user-defined top-level
      -- @__coro_susp@ resolves to an 'AVar' (never 'APrim') and is correctly NOT
      -- trusted. Do NOT broaden this relaxation beyond the genuine escape-sink
      -- identities.
      RApp (APrim qkey) as
        | Set.member qkey onceSinks && mentionsAny r as -> One
      -- B. Inter-procedural relaxation. If @f@ is a known top-level function and
      -- the resume binder @r@ is among its arguments, charge, for each argument
      -- position that is EXACTLY @AVar r@ (the continuation passed directly), the
      -- callee's trusted card for that parameter; sum (addC) over those positions
      -- (so passing @k@ to two One-slots is One + One = Many). A position that is
      -- out of range, or whose trusted card is @Many@, contributes @Many@. Args
      -- are atoms, so @mentionsAtom r a@ is exactly "@a@ is @AVar r@"; there is no
      -- continuation buried inside an arg at this level (those hit RLam/RCon).
      -- SOUNDNESS: @cs@ comes from the fixpoint-from-empty trust map, an UPPER
      -- bound on the callee's uses; a recursive/mutual callee never gets proven
      -- (stays absent => looked up as Nothing => this clause does not fire =>
      -- catch-all Many), so cycles stay conservative.
      --
      -- SATURATION GUARD: @cs@ has exactly one entry per parameter, so
      -- @length cs@ IS the callee's arity. The trusted per-param card is only a
      -- valid charge for a SATURATED application that actually CONSUMES the
      -- parameters. An under-saturated (partial) application does not invoke the
      -- callee at all: it CAPTURES the continuation into a returned closure (an
      -- escape), and the later calls of that closure re-invoke @r@ an unbounded
      -- number of times. Requiring @length as == length cs@ confines this clause
      -- to saturated calls; partial (and over-applied) calls fall through to the
      -- catch-all @RApp _ as -> Many@, which is correct (the continuation escapes).
      RApp (AVar f) as
        | Just cs <- Map.lookup (nameUniq f) trustMap
        , length as == length cs        -- saturated call only (see SATURATION GUARD)
        , mentionsAny r as ->
            foldr addC Zero
              [ cs !! i
              | (i, a) <- zip [0 :: Int ..] as, mentionsAtom r a ]
      RApp _ as        -> if mentionsAny r as then Many else Zero
      RAtom a          -> if mentionsAtom r a then Many else Zero
      RCon _ as        -> if mentionsAny r as then Many else Zero
      RLam _ b         -> if occursExpr r b then Many else Zero
      ROp minst _ _ as -> if maybe False (mentionsAtom r) minst || mentionsAny r as
                            then Many else Zero
      RRecord _ flds   -> if any (mentionsAtom r . snd) flds then Many else Zero
      RProj _ a        -> if mentionsAtom r a then Many else Zero
      -- The FBIP reuse form is introduced by a post-pass that runs AFTER
      -- multiplicity analysis; it never reaches this pass.
      RReuseCon{}      -> error "RReuseCon: produced only by reusePairing post-pass (after multiplicity analysis)"
      -- Foreign call: args are plain values, never the resume continuation.
      RForeignCall _ _ _ _ _ as -> if mentionsAny r as then Many else Zero

-- | Conservative "does `r` occur free anywhere in `e`" (shadowing ignored: resume
-- binders are fresh, and a false positive only over-approximates to Many).
occursExpr :: Name -> Expr -> Bool
occursExpr r e = case e of
  Ret a            -> mentionsAtom r a
  Let _ rhs b      -> occursRhs r rhs || occursExpr r b
  LetRec defs b    -> any (\(_, _, db) -> occursExpr r db) defs || occursExpr r b
  Case a alts      -> mentionsAtom r a || any (occursAlt r) alts
  LetJoin _ _ jb b -> occursExpr r jb || occursExpr r b
  Jump _ as        -> mentionsAny r as
  Handle e' h      -> occursExpr r e' || occursHandlerArms r h

occursRhs :: Name -> Rhs -> Bool
occursRhs r rhs = case rhs of
  RAtom a          -> mentionsAtom r a
  RApp f as        -> mentionsAtom r f || mentionsAny r as
  RCon _ as        -> mentionsAny r as
  RLam _ b         -> occursExpr r b
  ROp minst _ _ as -> maybe False (mentionsAtom r) minst || mentionsAny r as
  RRecord _ flds   -> any (mentionsAtom r . snd) flds
  RProj _ a        -> mentionsAtom r a
  RReuseCon{}              -> error "RReuseCon: produced only by reusePairing post-pass (after multiplicity analysis)"
  RForeignCall _ _ _ _ _ as -> mentionsAny r as

occursAlt :: Name -> Alt -> Bool
occursAlt r (AltCon _ _ b) = occursExpr r b
occursAlt r (AltLit _ b)   = occursExpr r b
occursAlt r (AltDefault b) = occursExpr r b

occursHandlerArms :: Name -> Handler -> Bool
occursHandlerArms r (Handler (_, re) ops _ _ _) =
  occursExpr r re || any (occursExpr r . oaBody) ops

-- ---------------------------------------------------------------------------
-- Module-level analysis
-- ---------------------------------------------------------------------------

-- | A handler arm whose continuation is provably multi-shot. Carries the effect
-- label and op name for the diagnostic.
data MultiplicityError = MultishotResume Text Text
  deriving (Eq, Show)

-- | Every operation arm reachable in a module (handlers may nest anywhere).
opArmsInModule :: CoreModule -> [(Maybe JoinId, OpArm)]
opArmsInModule cm = concatMap (opArmsInExpr . tbBody) (cmBinds cm)

opArmsInExpr :: Expr -> [(Maybe JoinId, OpArm)]
opArmsInExpr e = case e of
  Ret _            -> []
  Let _ rhs b      -> opArmsInRhs rhs ++ opArmsInExpr b
  LetRec defs b    -> concatMap (\(_, _, db) -> opArmsInExpr db) defs ++ opArmsInExpr b
  Case _ alts      -> concatMap opArmsInAlt alts
  LetJoin _ _ jb b -> opArmsInExpr jb ++ opArmsInExpr b
  Jump _ _         -> []
  Handle e' h      -> opArmsInExpr e' ++ opArmsInHandler h

opArmsInRhs :: Rhs -> [(Maybe JoinId, OpArm)]
opArmsInRhs (RLam _ b) = opArmsInExpr b
opArmsInRhs _          = []

opArmsInAlt :: Alt -> [(Maybe JoinId, OpArm)]
opArmsInAlt (AltCon _ _ b) = opArmsInExpr b
opArmsInAlt (AltLit _ b)   = opArmsInExpr b
opArmsInAlt (AltDefault b) = opArmsInExpr b

-- | Each op arm is paired with its handler's 'hAnswerJoin' (the value-position
-- answer-join, or 'Nothing' in tail position) so 'armCard' can seed that join as
-- a zero-cost exit. Nested handlers reached via @opArmsInExpr (oaBody oa)@ carry
-- their own answer-join.
opArmsInHandler :: Handler -> [(Maybe JoinId, OpArm)]
opArmsInHandler (Handler (_, re) ops aj _ _) =
  opArmsInExpr re ++ concatMap (\oa -> (aj, oa) : opArmsInExpr (oaBody oa)) ops

-- | The card of an arm's continuation under a trust map: walk the body, keyed on
-- the resume binder.
-- @mAnswerJoin@ is the enclosing handler's 'hAnswerJoin' (value-position) or
-- 'Nothing' (tail position). It is seeded to 'Zero' so the arm's exit jump to the
-- answer-join is not charged 'Many' (the answer-join's body cannot invoke this
-- arm's resume binder). Without it EVERY value-position arm is falsely 'Many'.
armCard :: Set (Text, Text) -> Map Unique [Card] -> Maybe JoinId -> OpArm -> Card
armCard onceSinks tm mAnswerJoin oa =
  cardOfWithTrust onceSinks tm seed (bndName (oaResume oa)) (oaBody oa)
  where seed = maybe Map.empty (\j -> Map.singleton j Zero) mAnswerJoin

-- | The per-function, per-parameter trust map: for each top-level binding, the
-- cardinality of each of its parameters in its own body, computed under the
-- trust map itself by a fixpoint.
--
-- SOUNDNESS (the fixpoint MUST start from EMPTY). With the empty map, a callee
-- looked up by clause B of 'cardRhs' is absent, so the relaxation does not fire
-- and the catch-all charges @Many@: every param's card in the first iterate is a
-- sound UPPER BOUND on its uses. Each subsequent iterate can only LOWER a card
-- (Many -> One/Zero) as more callees become trusted, never raise one, so the
-- sequence is monotonically decreasing in the @Many >= One >= Zero@ order and
-- converges. Because trust only grows from a sound start, the map can NEVER
-- wrongly trust a multishot function. A recursive (or mutually-recursive)
-- function that passes its parameter to a self/mutual call: on every iterate the
-- callee's relevant slot is still @Many@ (it never gets proven @<= 1@ because the
-- proof would require itself), so the param stays @Many@ — conservative and
-- correct. Do NOT seed this from an optimistic (Zero/One) map; that would assume
-- the very property under proof and could trust a genuine multishot.
computeTrustMap :: Set (Text, Text) -> CoreModule -> Map Unique [Card]
computeTrustMap onceSinks cm = fixpoint Map.empty
  where
    step tm = Map.fromList
      [ ( nameUniq (tbName tb)
        , [ cardOfWithTrust onceSinks tm Map.empty (bndName p) (tbBody tb)
          | p <- tbParams tb ] )
      | tb <- cmBinds cm ]
    fixpoint tm =
      let tm' = step tm
      in if tm' == tm then tm else fixpoint tm'

-- | The consumer: every multi-shot arm is an error. @onceSinks@ is the set of
-- qualified @(module, name)@ identities of the genuine once-sink @extern@ prims
-- (see 'cardOf').
-- The inter-procedural trust map is computed INTERNALLY (fixpoint from empty),
-- so the external signature is unchanged.
analyzeModule :: Set (Text, Text) -> CoreModule -> [MultiplicityError]
analyzeModule onceSinks cm =
  let tm = computeTrustMap onceSinks cm
  in [ MultishotResume (oaLabel oa) (oaOp oa)
     | (aj, oa) <- opArmsInModule cm
     , armCard onceSinks tm aj oa == Many ]

renderMultiplicityError :: MultiplicityError -> Text
renderMultiplicityError (MultishotResume lbl op) =
  Tx.concat
    [ Tx.pack "multishot resume: the `", lbl, Tx.pack ".", op
    , Tx.pack "` arm resumes its continuation more than once; handlers are one-shot."
    , Tx.pack "\n  resume at most once, or express the multi-shot logic explicitly (e.g. with a list)."
    ]

-- | The proof artifact: one `label.op : 0|1|ω` line per arm, module order.
-- @onceSinks@ is the same trusted escape-sink identity set 'analyzeModule' uses
-- (resolved in the pipeline), so the dump agrees with what the law accepts.
prettyMultiplicity :: Set (Text, Text) -> CoreModule -> Text
prettyMultiplicity onceSinks cm =
  let tm = computeTrustMap onceSinks cm
  in Tx.intercalate (Tx.pack "\n")
       [ Tx.concat [ oaLabel oa, Tx.pack ".", oaOp oa, Tx.pack " : ", renderCard (armCard onceSinks tm aj oa) ]
       | (aj, oa) <- opArmsInModule cm ]

renderCard :: Card -> Text
renderCard Zero = Tx.pack "0"
renderCard One  = Tx.pack "1"
renderCard Many = Tx.pack "\969"   -- ω
