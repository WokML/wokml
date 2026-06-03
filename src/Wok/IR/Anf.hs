module Wok.IR.Anf
  ( Mult (..)
  , Binder (..)
  , Lit (..)
  , Atom (..)
  , Rhs (..)
  , Expr (..)
  , Alt (..)
  , Handler (..)
  , OpArm (..)
  , TopBind (..)
  , CoreModule (..)
  , prettyModule
  , prettyExpr
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Name (Name, JoinId (..), Unique (..), nameHint, nameUniq)

-- | Multiplicity. v1 always Unrestricted; Affine is the future no-dup hook.
data Mult = Unrestricted | Affine
  deriving (Eq, Show)

data Binder = Binder { bndName :: Name, bndMult :: Mult }
  deriving (Eq, Show)

data Lit = LInt Integer | LStr Text | LChar Char | LUnit
  deriving (Eq, Show)

-- | Trivial, pure, effect-free values: the ONLY things allowed as call args,
-- constructor fields, scrutinees, jump args.
data Atom = AVar Name | ALit Lit
  deriving (Eq, Show)

-- | Value-producing computations: the RHS of a strict Let. Never nested.
data Rhs
  = RAtom Atom                   -- x = y
  | RApp Atom [Atom]             -- f a b   (n-ary; saturated by elaboration)
  | RCon Text [Atom]             -- Cons x xs
  | RLam [Binder] Expr           -- \x y -> e
  | ROp Text Text [Atom]         -- E.op a  (effect label, op name, args)
  | RRecord Text [(Text, Atom)]  -- T { l = a }
  | RProj Text Atom              -- a.l
  deriving (Eq, Show)

-- | Block / control structure. Strict: Let = evaluate-now sequencing.
data Expr
  = Ret Atom
  | Let Binder Rhs Expr
  | LetRec [(Binder, [Binder], Expr)] Expr   -- mutually-rec FUNCTIONS only
  | Case Atom [Alt]
  | LetJoin JoinId [Binder] Expr Expr        -- join j(ps)=jbody ; body
  | Jump JoinId [Atom]
  | Handle Expr Handler
  deriving (Eq, Show)

data Alt
  = AltCon Text [Binder] Expr
  | AltLit Lit Expr
  | AltDefault Expr
  deriving (Eq, Show)

data Handler = Handler
  { hReturn :: (Binder, Expr)
  , hOps :: [OpArm]
  } deriving (Eq, Show)

data OpArm = OpArm
  { oaLabel :: Text
  , oaOp :: Text
  , oaArgs :: [Binder]
  , oaResume :: Binder
  , oaBody :: Expr
  } deriving (Eq, Show)

data TopBind = TopBind { tbName :: Name, tbParams :: [Binder], tbBody :: Expr }
  deriving (Eq, Show)

newtype CoreModule = CoreModule { cmBinds :: [TopBind] }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Pretty-printing
-- ---------------------------------------------------------------------------

-- | Hint collision table: maps each hint text to the set of distinct Uniques
-- that share it. Hints that appear exactly once render as bare hint; those
-- that appear more than once render as "hint.N" where N is the Unique Int.
type HintTable = Map Text (Set Unique)

-- ---------------------------------------------------------------------------
-- Walking helpers: collect every Name that appears in a term

collectAtom :: Atom -> HintTable -> HintTable
collectAtom (AVar n) t = insertName n t
collectAtom (ALit _) t = t

insertName :: Name -> HintTable -> HintTable
insertName n = Map.insertWith Set.union (nameHint n) (Set.singleton (nameUniq n))

insertBinder :: Binder -> HintTable -> HintTable
insertBinder b = insertName (bndName b)

insertBinders :: [Binder] -> HintTable -> HintTable
insertBinders bs t = foldr insertBinder t bs

collectRhs :: Rhs -> HintTable -> HintTable
collectRhs (RAtom a)       t = collectAtom a t
collectRhs (RApp f xs)     t = foldr collectAtom t (f : xs)
collectRhs (RCon _ xs)     t = foldr collectAtom t xs
collectRhs (RLam ps e)     t = collectExpr e (insertBinders ps t)
collectRhs (ROp _ _ xs)    t = foldr collectAtom t xs
collectRhs (RRecord _ flds) t = foldr (\(_, a) acc -> collectAtom a acc) t flds
collectRhs (RProj _ a)     t = collectAtom a t

collectExpr :: Expr -> HintTable -> HintTable
collectExpr (Ret a)              t = collectAtom a t
collectExpr (Let b r e)          t = collectExpr e (collectRhs r (insertBinder b t))
collectExpr (LetRec defs e)      t =
  let t1 = foldr (\(b, ps, _) acc -> insertBinders ps (insertBinder b acc)) t defs
      t2 = foldr (\(_, _, body) acc -> collectExpr body acc) t1 defs
  in collectExpr e t2
collectExpr (Case a alts)        t = foldr collectAlt (collectAtom a t) alts
collectExpr (LetJoin _ ps jb e)  t = collectExpr e (collectExpr jb (insertBinders ps t))
collectExpr (Jump _ xs)          t = foldr collectAtom t xs
collectExpr (Handle e h)         t = collectHandler h (collectExpr e t)

collectAlt :: Alt -> HintTable -> HintTable
collectAlt (AltCon _ bs e) t = collectExpr e (insertBinders bs t)
collectAlt (AltLit _ e)    t = collectExpr e t
collectAlt (AltDefault e)  t = collectExpr e t

collectHandler :: Handler -> HintTable -> HintTable
collectHandler (Handler ret ops) t =
  let (rb, re) = ret
      t1 = collectExpr re (insertBinder rb t)
  in foldr collectOpArm t1 ops

collectOpArm :: OpArm -> HintTable -> HintTable
collectOpArm (OpArm _ _ args resume body) t =
  collectExpr body (insertBinder resume (insertBinders args t))

collectTopBind :: TopBind -> HintTable -> HintTable
collectTopBind (TopBind n ps e) t =
  collectExpr e (insertBinders ps (insertName n t))

buildHintTableExpr :: Expr -> HintTable
buildHintTableExpr e = collectExpr e Map.empty

-- ---------------------------------------------------------------------------
-- Rendering helpers

rn :: HintTable -> Name -> Text
rn tbl n =
  let hint = nameHint n
  in case Map.lookup hint tbl of
       Just s | Set.size s > 1 ->
         hint <> Tx.pack "." <> Tx.pack (show (Set.findIndex (nameUniq n) s + 1))
       _ -> hint

renderJoinId :: JoinId -> Text
renderJoinId (JoinId (Unique i)) = Tx.pack "j" <> Tx.pack (show i)

renderLit :: Lit -> Text
renderLit (LInt n) = Tx.pack (show n)
renderLit (LStr s) = Tx.pack (show s)
renderLit (LChar c) = Tx.pack (show c)
renderLit LUnit = Tx.pack "()"

renderAtom :: HintTable -> Atom -> Text
renderAtom tbl (AVar n) = rn tbl n
renderAtom _   (ALit l) = renderLit l

renderBinder :: HintTable -> Binder -> Text
renderBinder tbl b = rn tbl (bndName b)

renderBinders :: HintTable -> [Binder] -> Text
renderBinders tbl bs = Tx.intercalate (Tx.pack " ") (map (renderBinder tbl) bs)

-- Indent every line of a block by n spaces
indent :: Int -> Text -> Text
indent n t =
  let pad = Tx.replicate n (Tx.pack " ")
      ls  = Tx.lines t
  in Tx.intercalate (Tx.pack "\n") (map (pad <>) ls)

-- ---------------------------------------------------------------------------
-- Rendering Rhs

renderRhs :: HintTable -> Rhs -> Text
renderRhs tbl (RAtom a) =
  renderAtom tbl a
renderRhs tbl (RApp f xs) =
  renderAtom tbl f
    <> Tx.pack "("
    <> Tx.intercalate (Tx.pack ", ") (map (renderAtom tbl) xs)
    <> Tx.pack ")"
renderRhs _   (RCon c []) = c
renderRhs tbl (RCon c xs) =
  c
    <> Tx.pack "("
    <> Tx.intercalate (Tx.pack ", ") (map (renderAtom tbl) xs)
    <> Tx.pack ")"
renderRhs tbl (RLam ps e) =
  Tx.pack "\\"
    <> (if null ps then Tx.pack "" else renderBinders tbl ps <> Tx.pack " ")
    <> Tx.pack "-> "
    <> renderExpr tbl e
renderRhs tbl (ROp lbl op xs) =
  lbl <> Tx.pack "." <> op
    <> Tx.pack "("
    <> Tx.intercalate (Tx.pack ", ") (map (renderAtom tbl) xs)
    <> Tx.pack ")"
renderRhs tbl (RRecord tyName flds) =
  tyName
    <> Tx.pack " { "
    <> Tx.intercalate (Tx.pack ", ")
         (map (\(l, a) -> l <> Tx.pack " = " <> renderAtom tbl a) flds)
    <> Tx.pack " }"
renderRhs tbl (RProj lbl a) =
  renderAtom tbl a <> Tx.pack "." <> lbl

-- ---------------------------------------------------------------------------
-- Rendering Expr (flat layout, no extra depth per let)

renderExpr :: HintTable -> Expr -> Text
renderExpr tbl (Ret a) =
  renderAtom tbl a
renderExpr tbl (Let b r e) =
  Tx.pack "let " <> renderBinder tbl b <> Tx.pack " = " <> renderRhs tbl r
    <> Tx.pack "\n"
    <> renderExpr tbl e
renderExpr tbl (LetRec defs e) =
  Tx.pack "letrec\n"
    <> Tx.intercalate (Tx.pack "\n")
         (map (\(b, ps, body) ->
                indent 2 (
                  renderBinder tbl b
                    <> (if null ps then Tx.pack "" else Tx.pack " " <> renderBinders tbl ps)
                    <> Tx.pack " =\n"
                    <> indent 2 (renderExpr tbl body)
                )) defs)
    <> Tx.pack "\n"
    <> renderExpr tbl e
renderExpr tbl (Case a alts) =
  Tx.pack "case " <> renderAtom tbl a <> Tx.pack " of\n"
    <> Tx.intercalate (Tx.pack "\n")
         (map (indent 2 . renderAlt tbl) alts)
renderExpr tbl (LetJoin jid ps jbody e) =
  Tx.pack "join " <> renderJoinId jid
    <> Tx.pack "("
    <> Tx.intercalate (Tx.pack ", ") (map (renderBinder tbl) ps)
    <> Tx.pack ") =\n"
    <> indent 2 (renderExpr tbl jbody)
    <> Tx.pack "\n"
    <> renderExpr tbl e
renderExpr tbl (Jump jid xs) =
  Tx.pack "jump " <> renderJoinId jid
    <> Tx.pack "("
    <> Tx.intercalate (Tx.pack ", ") (map (renderAtom tbl) xs)
    <> Tx.pack ")"
renderExpr tbl (Handle e h) =
  renderExpr tbl e
    <> Tx.pack "\n"
    <> renderHandler tbl h

-- ---------------------------------------------------------------------------
-- Rendering Alt

-- | Join a clause header (ending in "->") with its body: inline when the body
-- is a single line, otherwise place the body on its own indented block.
arrowBody :: Text -> Text -> Text
arrowBody header body =
  case Tx.lines body of
    [_] -> header <> Tx.pack " " <> body
    _   -> header <> Tx.pack "\n" <> indent 2 body

renderAlt :: HintTable -> Alt -> Text
renderAlt tbl (AltCon c bs e) =
  arrowBody
    (c <> (if null bs then Tx.pack "" else Tx.pack " " <> renderBinders tbl bs)
       <> Tx.pack " ->")
    (renderExpr tbl e)
renderAlt tbl (AltLit l e) =
  arrowBody (renderLit l <> Tx.pack " ->") (renderExpr tbl e)
renderAlt tbl (AltDefault e) =
  arrowBody (Tx.pack "_ ->") (renderExpr tbl e)

-- ---------------------------------------------------------------------------
-- Rendering Handler

renderHandler :: HintTable -> Handler -> Text
renderHandler tbl (Handler (rb, re) ops) =
  Tx.pack "with {"
    <> Tx.pack "\n"
    <> indent 2
         (arrowBody (Tx.pack "return " <> renderBinder tbl rb <> Tx.pack " ->")
                    (renderExpr tbl re))
    <> (if null ops
          then Tx.pack ""
          else Tx.pack "\n" <> Tx.intercalate (Tx.pack "\n") (map (indent 2 . renderOpArm tbl) ops))
    <> Tx.pack "\n}"

renderOpArm :: HintTable -> OpArm -> Text
renderOpArm tbl (OpArm lbl op args resume body) =
  arrowBody
    (lbl <> Tx.pack "." <> op
       <> Tx.pack "("
       <> Tx.intercalate (Tx.pack ", ")
            (map (renderBinder tbl) args ++ [renderBinder tbl resume])
       <> Tx.pack ") ->")
    (renderExpr tbl body)

-- ---------------------------------------------------------------------------
-- Top-level rendering

renderTop :: HintTable -> TopBind -> Text
renderTop tbl (TopBind n ps e) =
  rn tbl n
    <> (if null ps then Tx.pack "" else Tx.pack " " <> renderBinders tbl ps)
    <> Tx.pack " =\n"
    <> indent 2 (renderExpr tbl e)

-- ---------------------------------------------------------------------------
-- Public API

prettyModule :: CoreModule -> Text
prettyModule (CoreModule binds) =
  Tx.intercalate (Tx.pack "\n\n")
    (map (\b -> renderTop (collectTopBind b Map.empty) b) binds)

prettyExpr :: Expr -> Text
prettyExpr e =
  let tbl = buildHintTableExpr e
  in renderExpr tbl e

