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
  , prettyModuleTyped
  , prettyExpr
    -- * Free-variable analysis
  , freeVarsExpr
  , freeVarsHandler
  , freeVarsRhs
  , freeVarsAlt
  , atomVars
  , binderUnique
    -- * Handler helpers
  , hParamBinders
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx
import Wok.IR.Name (Name, JoinId (..), Unique (..), nameHint, nameUniq)
import Wok.TypeChecking.Types (CType (..), TyCon (..))

-- | Multiplicity. v1 always Unrestricted; Affine is the future no-dup hook.
data Mult = Unrestricted | Affine
  deriving (Eq, Show)

data Binder = Binder { bndName :: Name, bndMult :: Mult, bndType :: CType }
  deriving (Eq, Show)

data Lit = LInt Integer | LStr Text | LChar Char | LUnit
  deriving (Eq, Show)

-- | Trivial, pure, effect-free values: the ONLY things allowed as call args,
-- constructor fields, scrutinees, jump args.
--
-- 'APrim' carries the QUALIFIED identity @(Module, Name)@ of a prelude
-- @extern@ (e.g. @("Std.Base", "+")@). The module disambiguates same-named
-- externs across modules; runtime implementation lookup keys on the name part
-- (Caveat B), and the trusted-sink recognizers key on the whole pair.
data Atom = AVar Name | ALit Lit | APrim (Text, Text)
  deriving (Eq, Show)

-- | Value-producing computations: the RHS of a strict Let. Never nested.
data Rhs
  = RAtom Atom                   -- x = y
  | RApp Atom [Atom]             -- f a b   (n-ary; saturated by elaboration)
  | RCon Text [Atom]             -- Cons x xs
  | RLam [Binder] Expr           -- \x y -> e
  | ROp (Maybe Atom) Text Text [Atom]
    -- ^ inst.E.op a  (instance handle, effect label, op name, args).
    -- The leading 'Maybe Atom' is the named-instance handle through which the
    -- operation is performed; 'Nothing' = ambient (route to nearest handler).
  | RRecord Text [(Text, Atom)]  -- T { l = a }
  | RProj Text Atom              -- a.l
  | RReuseCon Atom Text [Atom]   -- alloc_at(tok) Con field...  (FBIP reuse)
    -- ^ An 'RCon' that consumes a reuse token (the leading 'Atom', an 'AVar'
    -- naming a token binder produced by @__rc_drop_reuse@). Produced ONLY by the
    -- FBIP reuse-pairing post-pass that runs AFTER 'Wok.IR.Perceus.insertRC';
    -- the elaborator and every analysis that runs before that post-pass never
    -- emit or observe it (spec 2026-06-23-fbip-reuse-design §5.1).
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
  , hAnswerJoin :: Maybe JoinId
    -- ^ The join point this handler's arms deliver their answer to, when the
    -- handler is in value (non-tail) position; Nothing in tail position. Used
    -- by the interpreter to redirect a resumed sub-run's answer to the resume
    -- call site instead of the static post-handler continuation.
  , hParam :: Maybe Binder          -- ^ handler-local parameter (slice 4a); Nothing = ordinary
  , hSelf :: Maybe Binder           -- ^ self-instance binder (named handler); Nothing = ordinary
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
collectAtom (APrim _) t = t

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
collectRhs (ROp minst _ _ xs) t = foldr collectAtom t (maybe xs (: xs) minst)
collectRhs (RRecord _ flds) t = foldr (\(_, a) acc -> collectAtom a acc) t flds
collectRhs (RProj _ a)     t = collectAtom a t
collectRhs (RReuseCon tok _ xs) t = foldr collectAtom t (tok : xs)

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
collectHandler (Handler ret ops _ mparam mself) t =
  let (rb, re) = ret
      t0 = maybe t (`insertBinder` t) mparam
      ts = maybe t0 (`insertBinder` t0) mself
      t1 = collectExpr re (insertBinder rb ts)
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
renderAtom _   (APrim (_, n)) = n

-- | Format a binder using a caller-supplied binder-renderer.
-- The erased renderer ignores the type; the typed renderer appends \" : type\".
type BndFmt = HintTable -> Binder -> Text

erasedBndFmt :: BndFmt
erasedBndFmt tbl b = rn tbl (bndName b)

typedBndFmt :: BndFmt
typedBndFmt tbl b = rn tbl (bndName b) <> Tx.pack " : " <> prettyCTypeLocal (bndType b)

renderBinder :: BndFmt -> HintTable -> Binder -> Text
renderBinder fmt = fmt

renderBinders :: BndFmt -> HintTable -> [Binder] -> Text
renderBinders fmt tbl bs = Tx.intercalate (Tx.pack " ") (map (renderBinder fmt tbl) bs)

-- Indent every line of a block by n spaces
indent :: Int -> Text -> Text
indent n t =
  let pad = Tx.replicate n (Tx.pack " ")
      ls  = Tx.lines t
  in Tx.intercalate (Tx.pack "\n") (map (pad <>) ls)

-- ---------------------------------------------------------------------------
-- Rendering Rhs

renderRhs :: BndFmt -> HintTable -> Rhs -> Text
renderRhs _   tbl (RAtom a) =
  renderAtom tbl a
renderRhs _   tbl (RApp f xs) =
  renderAtom tbl f
    <> Tx.pack "("
    <> Tx.intercalate (Tx.pack ", ") (map (renderAtom tbl) xs)
    <> Tx.pack ")"
renderRhs _   _   (RCon c []) = c
renderRhs _   tbl (RCon c xs) =
  c
    <> Tx.pack "("
    <> Tx.intercalate (Tx.pack ", ") (map (renderAtom tbl) xs)
    <> Tx.pack ")"
renderRhs fmt tbl (RLam ps e) =
  Tx.pack "\\"
    <> (if null ps then Tx.pack "" else renderBinders fmt tbl ps <> Tx.pack " ")
    <> Tx.pack "-> "
    <> renderExpr fmt tbl e
renderRhs _   tbl (ROp minst lbl op xs) =
  maybe (Tx.pack "") (\a -> renderAtom tbl a <> Tx.pack ".") minst
    <> lbl <> Tx.pack "." <> op
    <> Tx.pack "("
    <> Tx.intercalate (Tx.pack ", ") (map (renderAtom tbl) xs)
    <> Tx.pack ")"
renderRhs _   tbl (RRecord tyName flds) =
  tyName
    <> Tx.pack " { "
    <> Tx.intercalate (Tx.pack ", ")
         (map (\(l, a) -> l <> Tx.pack " = " <> renderAtom tbl a) flds)
    <> Tx.pack " }"
renderRhs _   tbl (RProj lbl a) =
  renderAtom tbl a <> Tx.pack "." <> lbl
renderRhs _   tbl (RReuseCon tok c xs) =
  c
    <> Tx.pack "@"
    <> renderAtom tbl tok
    <> Tx.pack "("
    <> Tx.intercalate (Tx.pack ", ") (map (renderAtom tbl) xs)
    <> Tx.pack ")"

-- ---------------------------------------------------------------------------
-- Rendering Expr (flat layout, no extra depth per let)

renderExpr :: BndFmt -> HintTable -> Expr -> Text
renderExpr _   tbl (Ret a) =
  renderAtom tbl a
renderExpr fmt tbl (Let b r e) =
  Tx.pack "let " <> renderBinder fmt tbl b <> Tx.pack " = " <> renderRhs fmt tbl r
    <> Tx.pack "\n"
    <> renderExpr fmt tbl e
renderExpr fmt tbl (LetRec defs e) =
  Tx.pack "letrec\n"
    <> Tx.intercalate (Tx.pack "\n")
         (map (\(b, ps, body) ->
                indent 2 (
                  renderBinder fmt tbl b
                    <> (if null ps then Tx.pack "" else Tx.pack " " <> renderBinders fmt tbl ps)
                    <> Tx.pack " =\n"
                    <> indent 2 (renderExpr fmt tbl body)
                )) defs)
    <> Tx.pack "\n"
    <> renderExpr fmt tbl e
renderExpr fmt tbl (Case a alts) =
  Tx.pack "case " <> renderAtom tbl a <> Tx.pack " of\n"
    <> Tx.intercalate (Tx.pack "\n")
         (map (indent 2 . renderAlt fmt tbl) alts)
renderExpr fmt tbl (LetJoin jid ps jbody e) =
  Tx.pack "join " <> renderJoinId jid
    <> Tx.pack "("
    <> Tx.intercalate (Tx.pack ", ") (map (renderBinder fmt tbl) ps)
    <> Tx.pack ") =\n"
    <> indent 2 (renderExpr fmt tbl jbody)
    <> Tx.pack "\n"
    <> renderExpr fmt tbl e
renderExpr _   tbl (Jump jid xs) =
  Tx.pack "jump " <> renderJoinId jid
    <> Tx.pack "("
    <> Tx.intercalate (Tx.pack ", ") (map (renderAtom tbl) xs)
    <> Tx.pack ")"
renderExpr fmt tbl (Handle e h) =
  renderExpr fmt tbl e
    <> Tx.pack "\n"
    <> renderHandler fmt tbl h

-- ---------------------------------------------------------------------------
-- Rendering Alt

-- | Join a clause header (ending in "->") with its body: inline when the body
-- is a single line, otherwise place the body on its own indented block.
arrowBody :: Text -> Text -> Text
arrowBody header body =
  case Tx.lines body of
    [_] -> header <> Tx.pack " " <> body
    _   -> header <> Tx.pack "\n" <> indent 2 body

renderAlt :: BndFmt -> HintTable -> Alt -> Text
renderAlt fmt tbl (AltCon c bs e) =
  arrowBody
    (c <> (if null bs then Tx.pack "" else Tx.pack " " <> renderBinders fmt tbl bs)
       <> Tx.pack " ->")
    (renderExpr fmt tbl e)
renderAlt fmt tbl (AltLit l e) =
  arrowBody (renderLit l <> Tx.pack " ->") (renderExpr fmt tbl e)
renderAlt fmt tbl (AltDefault e) =
  arrowBody (Tx.pack "_ ->") (renderExpr fmt tbl e)

-- ---------------------------------------------------------------------------
-- Rendering Handler

renderHandler :: BndFmt -> HintTable -> Handler -> Text
renderHandler fmt tbl (Handler (rb, re) ops _ _ mself) =
  Tx.pack "with"
    <> maybe (Tx.pack "") (\sb -> Tx.pack " " <> renderBinder fmt tbl sb <> Tx.pack " =") mself
    <> Tx.pack " {"
    <> Tx.pack "\n"
    <> indent 2
         (arrowBody (Tx.pack "return " <> renderBinder fmt tbl rb <> Tx.pack " ->")
                    (renderExpr fmt tbl re))
    <> (if null ops
          then Tx.pack ""
          else Tx.pack "\n" <> Tx.intercalate (Tx.pack "\n") (map (indent 2 . renderOpArm fmt tbl) ops))
    <> Tx.pack "\n}"

renderOpArm :: BndFmt -> HintTable -> OpArm -> Text
renderOpArm fmt tbl (OpArm lbl op args resume body) =
  arrowBody
    (lbl <> Tx.pack "." <> op
       <> Tx.pack "("
       <> Tx.intercalate (Tx.pack ", ")
            (map (renderBinder fmt tbl) args ++ [renderBinder fmt tbl resume])
       <> Tx.pack ") ->")
    (renderExpr fmt tbl body)

-- ---------------------------------------------------------------------------
-- Top-level rendering

renderTop :: BndFmt -> HintTable -> TopBind -> Text
renderTop fmt tbl (TopBind n ps e) =
  rn tbl n
    <> (if null ps then Tx.pack "" else Tx.pack " " <> renderBinders fmt tbl ps)
    <> Tx.pack " =\n"
    <> indent 2 (renderExpr fmt tbl e)

-- ---------------------------------------------------------------------------
-- Local CType renderer (avoids import cycle if Infer ever imports Anf)

prettyCTypeLocal :: CType -> Text
prettyCTypeLocal (CTGen i)            = Tx.pack "a" <> Tx.pack (show i)
prettyCTypeLocal (CTCon TcU64    [])  = Tx.pack "U64"
prettyCTypeLocal (CTCon TcU32    [])  = Tx.pack "U32"
prettyCTypeLocal (CTCon TcChar   [])  = Tx.pack "Char"
prettyCTypeLocal (CTCon TcString [])  = Tx.pack "String"
prettyCTypeLocal (CTCon TcNever  [])  = Tx.pack "Never"
prettyCTypeLocal (CTCon TcBool   [])  = Tx.pack "Bool"
prettyCTypeLocal (CTCon TcUnit   [])  = Tx.pack "()"
prettyCTypeLocal (CTCon TcList [x])   =
  Tx.pack "[" <> prettyCTypeLocal x <> Tx.pack "]"
prettyCTypeLocal (CTCon TcArray [x])  =
  Tx.pack "Array " <> prettyCTypeLocal x
prettyCTypeLocal (CTCon (TcTuple _) xs) =
  Tx.pack "("
    <> Tx.intercalate (Tx.pack ", ") (map prettyCTypeLocal xs)
    <> Tx.pack ")"
prettyCTypeLocal (CTCon (TcUser n) []) = n
prettyCTypeLocal (CTCon (TcUser n) xs0) =
  case filter (/= CREmpty) xs0 of
    []  -> n
    xs  -> n <> Tx.pack " " <> Tx.intercalate (Tx.pack " ") (map prettyCTypeLocal xs)
prettyCTypeLocal (CTCon tc xs) =
  Tx.pack (show tc)
    <> (if null xs then Tx.pack "" else Tx.pack " " <> Tx.intercalate (Tx.pack " ") (map prettyCTypeLocal xs))
prettyCTypeLocal (CTArr a _ b) =
  prettyCTypeLocal a <> Tx.pack " -> " <> prettyCTypeLocal b
prettyCTypeLocal (CTRecord t _) = t
-- Row nodes (kind KEffect) reach here when a row appears as a type argument,
-- e.g. the residual (row e) of Step/Suspension. Enumerate ALL labels (the
-- earlier head-only form silently dropped every label past the first).
prettyCTypeLocal CREmpty            = Tx.pack "{}"
prettyCTypeLocal r@CRExtend{}       = prettyRowLocal r

-- | Render a row as a flat brace list: @{Log, Tick}@ for a closed row, or
-- @{Log, Tick | e}@ when it ends in a row variable.
prettyRowLocal :: CType -> Text
prettyRowLocal row =
  Tx.pack "{" <> Tx.intercalate (Tx.pack ", ") labels <> tailTx <> Tx.pack "}"
  where
    (labels, restTail) = collect row
    collect (CRExtend l _ rest) = let (ls, t) = collect rest in (l : ls, t)
    collect other               = ([], other)
    tailTx = case restTail of
      CREmpty -> Tx.empty
      t       -> Tx.pack " | " <> prettyCTypeLocal t

-- ---------------------------------------------------------------------------
-- Public API

prettyModule :: CoreModule -> Text
prettyModule (CoreModule binds) =
  Tx.intercalate (Tx.pack "\n\n")
    (map (\b -> renderTop erasedBndFmt (collectTopBind b Map.empty) b) binds)

-- | Like 'prettyModule' but renders each binder as @name : type@.
prettyModuleTyped :: CoreModule -> Text
prettyModuleTyped (CoreModule binds) =
  Tx.intercalate (Tx.pack "\n\n")
    (map (\b -> renderTop typedBndFmt (collectTopBind b Map.empty) b) binds)

prettyExpr :: Expr -> Text
prettyExpr e =
  let tbl = buildHintTableExpr e
  in renderExpr erasedBndFmt tbl e

-- ---------------------------------------------------------------------------
-- Free-variable analysis
--
-- The standard ANF free-var walk: a binder removes its own Unique from the
-- free set of its scope. Only term variables ('AVar') contribute; literals,
-- constructor tags, effect labels, and join ids do not.

-- | The free term variables (as 'Unique's) of an ANF expression: every 'AVar'
-- reference not bound by an enclosing binder. The single source of truth shared
-- by the Perceus pass and the RC interpreter for computing closure captures.
freeVarsExpr :: Expr -> Set Unique
freeVarsExpr (Ret a)            = atomVars a
freeVarsExpr (Let b r e)        =
  freeVarsRhs r `Set.union` Set.delete (binderUnique b) (freeVarsExpr e)
freeVarsExpr (LetRec defs body) =
  let groupU = Set.fromList (map (\(b, _, _) -> binderUnique b) defs)
      bodyFv = freeVarsExpr body
      defFv  = Set.unions
                 [ freeVarsExpr d `Set.difference` Set.fromList (map binderUnique ps)
                 | (_, ps, d) <- defs ]
  in (bodyFv `Set.union` defFv) `Set.difference` groupU
freeVarsExpr (Case a alts)      = atomVars a `Set.union` Set.unions (map freeVarsAlt alts)
freeVarsExpr (LetJoin _ ps jb e) =
  let psU = Set.fromList (map binderUnique ps)
  in (freeVarsExpr jb `Set.difference` psU) `Set.union` freeVarsExpr e
freeVarsExpr (Jump _ as)        = Set.unions (map atomVars as)
freeVarsExpr (Handle e h)       =
  freeVarsExpr e `Set.union` freeVarsHandler h
    -- The handler CONSUMES its parameter from the enclosing scope (baton model,
    -- M2b-2 Task 2), so hParam is an external free variable of the Handle even
    -- though freeVarsHandler excludes it from the arm free vars (it is "locally
    -- bound" inside the arms). Including it here ensures the outer 'Let' rule
    -- keeps the param live rather than dropping it before the Handle fires.
    `Set.union` maybe Set.empty (Set.singleton . binderUnique) (hParam h)

-- | Free vars of a handler's arms: the return-arm body minus its binder, plus each
-- op-arm body minus that arm's args + resume binder; finally minus hParam/hSelf.
--
-- DELIBERATE ASYMMETRY vs 'freeVarsExpr (Handle ...)': 'freeVarsHandler' EXCLUDES
-- hParam and hSelf (they are "locally bound" from the arms' perspective -- each arm
-- sees the param as an in-scope binding). By contrast, 'freeVarsExpr' INCLUDES hParam
-- in the outer-scope free-variable set (the Handle CONSUMES its param from the
-- enclosing scope -- baton model, M2b-2 Task 2 -- so the outer Let must keep it live
-- until the Handle fires). Collapsing the two would either drop the param before the
-- Handle (UAF on the abort path) or spuriously reject all parameterized handlers
-- (param appears free in the handler arms, so the enclosing context's drop-insertion
-- would see it as double-consumed). Both failure modes were verified by a red-check.
freeVarsHandler :: Handler -> Set Unique
freeVarsHandler (Handler (rb, rbody) ops _ mparam mself) =
  let retFv = Set.delete (binderUnique rb) (freeVarsExpr rbody)
      opFv  = Set.unions
                [ freeVarsExpr body
                    `Set.difference` Set.fromList (binderUnique resume : map binderUnique args)
                | OpArm _ _ args resume body <- ops ]
      bound = Set.fromList (map binderUnique (maybe [] pure mparam ++ maybe [] pure mself))
  in (retFv `Set.union` opFv) `Set.difference` bound

freeVarsAlt :: Alt -> Set Unique
freeVarsAlt (AltCon _ bs e) = freeVarsExpr e `Set.difference` Set.fromList (map binderUnique bs)
freeVarsAlt (AltLit _ e)    = freeVarsExpr e
freeVarsAlt (AltDefault e)  = freeVarsExpr e

freeVarsRhs :: Rhs -> Set Unique
freeVarsRhs (RAtom a)        = atomVars a
freeVarsRhs (RApp f as)      = Set.unions (map atomVars (f : as))
freeVarsRhs (RCon _ as)      = Set.unions (map atomVars as)
freeVarsRhs (RLam ps e)      = freeVarsExpr e `Set.difference` Set.fromList (map binderUnique ps)
freeVarsRhs (ROp m _ _ as)   = Set.unions (map atomVars (maybe as (: as) m))
freeVarsRhs (RRecord _ flds) = Set.unions (map (atomVars . snd) flds)
freeVarsRhs (RProj _ a)      = atomVars a
freeVarsRhs (RReuseCon tok _ as) = Set.unions (atomVars tok : map atomVars as)

atomVars :: Atom -> Set Unique
atomVars (AVar n) = Set.singleton (nameUniq n)
atomVars (ALit _) = Set.empty
atomVars (APrim _) = Set.empty

binderUnique :: Binder -> Unique
binderUnique = nameUniq . bndName

-- | Return the handler's parameter binder as a singleton list, or empty if
-- the handler has no parameter.  Convenience alias for 'maybe [] pure . hParam'.
hParamBinders :: Handler -> [Binder]
hParamBinders = maybe [] pure . hParam
