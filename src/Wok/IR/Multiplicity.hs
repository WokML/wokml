module Wok.IR.Multiplicity
  ( Card (..)
  , joinC
  , addC
  , cardOf
  , MultiplicityError (..)
  , analyzeModule
  , renderMultiplicityError
  , prettyMultiplicity
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Name (Name, JoinId)
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

mentionsAny :: Name -> [Atom] -> Bool
mentionsAny r = any (mentionsAtom r)

-- | The affine analysis: an upper bound on how many times `r` is invoked in `e`.
-- Type-free; the single soundness rule is that any occurrence of `r` that is NOT
-- the head of a saturated application is an escape and yields Many.
cardOf :: Name -> Expr -> Card
cardOf r = go Map.empty
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
      RApp _ as        -> if mentionsAny r as then Many else Zero
      RAtom a          -> if mentionsAtom r a then Many else Zero
      RCon _ as        -> if mentionsAny r as then Many else Zero
      RLam _ b         -> if occursExpr r b then Many else Zero
      ROp minst _ _ as -> if maybe False (mentionsAtom r) minst || mentionsAny r as
                            then Many else Zero
      RRecord _ flds   -> if any (mentionsAtom r . snd) flds then Many else Zero
      RProj _ a        -> if mentionsAtom r a then Many else Zero

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
opArmsInModule :: CoreModule -> [OpArm]
opArmsInModule cm = concatMap (opArmsInExpr . tbBody) (cmBinds cm)

opArmsInExpr :: Expr -> [OpArm]
opArmsInExpr e = case e of
  Ret _            -> []
  Let _ rhs b      -> opArmsInRhs rhs ++ opArmsInExpr b
  LetRec defs b    -> concatMap (\(_, _, db) -> opArmsInExpr db) defs ++ opArmsInExpr b
  Case _ alts      -> concatMap opArmsInAlt alts
  LetJoin _ _ jb b -> opArmsInExpr jb ++ opArmsInExpr b
  Jump _ _         -> []
  Handle e' h      -> opArmsInExpr e' ++ opArmsInHandler h

opArmsInRhs :: Rhs -> [OpArm]
opArmsInRhs (RLam _ b) = opArmsInExpr b
opArmsInRhs _          = []

opArmsInAlt :: Alt -> [OpArm]
opArmsInAlt (AltCon _ _ b) = opArmsInExpr b
opArmsInAlt (AltLit _ b)   = opArmsInExpr b
opArmsInAlt (AltDefault b) = opArmsInExpr b

opArmsInHandler :: Handler -> [OpArm]
opArmsInHandler (Handler (_, re) ops _ _ _) =
  opArmsInExpr re ++ concatMap (\oa -> oa : opArmsInExpr (oaBody oa)) ops

-- | The card of an arm's continuation: walk the body, keyed on the resume binder.
armCard :: OpArm -> Card
armCard oa = cardOf (bndName (oaResume oa)) (oaBody oa)

-- | The consumer: every multi-shot arm is an error.
analyzeModule :: CoreModule -> [MultiplicityError]
analyzeModule cm =
  [ MultishotResume (oaLabel oa) (oaOp oa)
  | oa <- opArmsInModule cm
  , armCard oa == Many ]

renderMultiplicityError :: MultiplicityError -> Text
renderMultiplicityError (MultishotResume lbl op) =
  Tx.concat
    [ Tx.pack "multishot resume: the `", lbl, Tx.pack ".", op
    , Tx.pack "` arm resumes its continuation more than once; handlers are one-shot."
    , Tx.pack "\n  resume at most once, or express the multi-shot logic explicitly (e.g. with a list)."
    ]

-- | The proof artifact: one `label.op : 0|1|ω` line per arm, module order.
prettyMultiplicity :: CoreModule -> Text
prettyMultiplicity cm =
  Tx.intercalate (Tx.pack "\n")
    [ Tx.concat [ oaLabel oa, Tx.pack ".", oaOp oa, Tx.pack " : ", renderCard (armCard oa) ]
    | oa <- opArmsInModule cm ]

renderCard :: Card -> Text
renderCard Zero = Tx.pack "0"
renderCard One  = Tx.pack "1"
renderCard Many = Tx.pack "\969"   -- ω
