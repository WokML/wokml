-- | The v2-to-v1 surface mapper: a grammar/c s-expression dump, read by
-- "Wok.Sexp.Read", becomes a v1 'Abs.Module' ready for the unchanged
-- Loader / Reordering / TypeChecking pipeline.
--
-- The mapper is two passes over the datum tree:
--
--   1. /Validation/ ('checkNode'): a generic walk against the wok_ast.h
--      schema, exactly as strict as the C reference reader
--      (@wok_sexpr_read@): unknown head tag, wrong field count, a field of
--      the wrong shape, or a child of the wrong FAMILY are all
--      'MalformedDump' errors. The family lattice mirrors
--      @wok_family_accepts@: a STMT slot accepts a bare expression, a
--      BINDLHS slot accepts a prefix head or a pattern, the two error
--      nodes stand anywhere; nothing else subsumes.
--
--   2. /Mapping/: each validated v2 node becomes the v1 form with the same
--      MEANING (spec D3). A well-formed v2 construct v1 cannot express is
--      a 'SexpGap' carrying the tag and a one-line statement of what v1
--      lacks -- a deliverable finding (spec D6), never a coercion. The two
--      damage nodes (@D_Error@ / @E_Error@) are 'MalformedDump' hard
--      errors: the oracle path accepts only clean parses (spec D1).
--
-- Design notes:
--
--   * The dump carries no source positions, so every positioned v1 token
--     gets the line\/column of the datum it was decoded from IN THE .SEXP
--     FILE (spec D4). Never a @(0,0)@ sentinel.
--
--   * @WFC_TEXT@ fields hold the RAW SOURCE LEXEME (an @E_Str@ field is
--     @"hello\\n"@ INCLUDING the wok quotes). 'decodeStringLexeme' and
--     'decodeCharLexeme' process the wok escape set (the one
--     grammar\/c\/wok_token.c @scan_literal@ accepts:
--     @\\\\ \\\" \\' \\n \\t \\r \\0 \\xHH@) exactly once, here (spec D5).
--
--   * The signature takes no file name: errors carry a 'Pos' into the
--     dump text, and the caller (the S2 loader branch) knows which file it
--     read. Keeping the function pure of presentation concerns was chosen
--     over the spec sketch's @Text@ first argument.
--
--   * @N_Name@ case is decided by the dumped @upper@ FLAG, never by
--     first-character inspection (spec D3, last row). Where a v1 position
--     structurally requires one case (a module-path part, an import
--     alias), a contradicting flag is a 'MalformedDump' -- the v2 parser
--     cannot emit such a dump. The two places with NO flag in the schema
--     (an @L_Prefix@ head naming an operator, an @E_HandleIn@ label) are
--     classified by their spelling, and say so in a comment.
module Wok.Sexp.Surface
  ( SurfaceError (..)
  , surfaceModule
  , decodeStringLexeme
  , decodeCharLexeme
  ) where

import Control.Monad (zipWithM)
import Data.Char (chr, isDigit, isUpper)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

import qualified GeneratedParser.Wok.Abs as Abs
import Wok.Sexp.Read (Pos (..), SExp (..), hexVal)

-- ---------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------

-- | The two failure modes the spec requires be distinguished.
data SurfaceError
  = -- | The dump does not conform to the wok_ast.h schema (unknown tag,
    -- wrong arity, wrong field shape, wrong family), or it carries a
    -- damage node, which the oracle path rejects (spec D1).
    MalformedDump Pos Text
  | -- | A WELL-FORMED v2 construct with no v1 equivalent: the position,
    -- the INNERMOST tag the gap fired on, a STABLE construct label
    -- naming the spec-inventory construct (one label per distinct gap
    -- rule, so a NEW gap under an already-allowlisted broad tag cannot
    -- launder itself past the differential's gap allowlist), and a
    -- one-line statement of what v1 lacks (spec D6).
    SexpGap Pos Text Text Text
  deriving (Eq, Show)

mal :: Pos -> String -> Either SurfaceError a
mal p msg = Left (MalformedDump p (T.pack msg))

gapAt :: Pos -> Text -> Text -> String -> Either SurfaceError a
gapAt p tag label msg = Left (SexpGap p tag label (T.pack msg))

gap :: GNode -> Text -> String -> Either SurfaceError a
gap n = gapAt (gPos n) (gTag n)

-- | The damage nodes: the parser plants them where a production gave up.
-- The reader accepts them anywhere (their family is a wildcard, matching
-- the C reader), but the ORACLE path maps them to a hard error (spec D1).
damaged :: GNode -> Either SurfaceError a
damaged n = mal (gPos n) msg
  where
    msg =
      "the dump contains a damage node (" ++ T.unpack (gTag n)
        ++ "); the oracle path accepts only clean parses"

notDamaged :: GNode -> Either SurfaceError ()
notDamaged n
  | gFamily n == FamError = damaged n
  | otherwise = Right ()

-- | A node of an accepted family that still cannot stand in this mapping
-- position. After 'checkNode' this fires only for damage nodes (the
-- family wildcard) -- anything else would be a walker bug, and says so.
unmappable :: GNode -> String -> Either SurfaceError a
unmappable n what = do
  notDamaged n
  mal (gPos n) (T.unpack (gTag n) ++ " cannot stand where " ++ what ++ " is required")

-- ---------------------------------------------------------------------
-- The schema: families, field classes, per-tag field lists (wok_ast.h)
-- ---------------------------------------------------------------------

-- | Node families, mirroring @WOK_FAMILIES@ (wok_ast.h). @NONE@ is not
-- represented: it exists only for scalar fields, which 'FieldClass'
-- encodes without a family.
data Family
  = FamError
  | FamFile
  | FamDecl
  | FamType
  | FamPat
  | FamExpr
  | FamStmt
  | FamName
  | FamPath
  | FamLhs
  | FamBindLhs
  | FamSigName
  | FamTyParam
  | FamConDef
  | FamFieldType
  | FamOpSig
  | FamForeignMem
  | FamRowEntry
  | FamFieldPat
  | FamChainOp
  | FamBind
  | FamUseBind
  | FamAlt
  | FamClause
  | FamField
  | FamFixRel
  deriving (Eq, Show)

familyName :: Family -> String
familyName f = case f of
  FamError -> "ERROR"
  FamFile -> "FILE"
  FamDecl -> "DECL"
  FamType -> "TYPE"
  FamPat -> "PAT"
  FamExpr -> "EXPR"
  FamStmt -> "STMT"
  FamName -> "NAME"
  FamPath -> "PATH"
  FamLhs -> "LHS"
  FamBindLhs -> "BINDLHS"
  FamSigName -> "SIGNAME"
  FamTyParam -> "TYPARAM"
  FamConDef -> "CONDEF"
  FamFieldType -> "FIELDTYPE"
  FamOpSig -> "OPSIG"
  FamForeignMem -> "FOREIGNMEM"
  FamRowEntry -> "ROWENTRY"
  FamFieldPat -> "FIELDPAT"
  FamChainOp -> "CHAINOP"
  FamBind -> "BIND"
  FamUseBind -> "USEBIND"
  FamAlt -> "ALT"
  FamClause -> "CLAUSE"
  FamField -> "FIELD"
  FamFixRel -> "FIXREL"

-- | @wok_family_accepts@, verbatim: the three subsumptions and the
-- damage wildcard, nothing else.
familyAccepts :: Family -> Family -> Bool
familyAccepts want got =
  want == got
    || got == FamError
    || (want == FamStmt && got == FamExpr)
    || (want == FamBindLhs && (got == FamLhs || got == FamPat))

-- | A field's class, with the family a child-holding class demands.
data FieldClass
  = CNode Family
  | COpt Family
  | CSeq Family
  | CName
  | CText
  | CInt
  | CFlag

-- | Per-tag lookup into 'tagSpecMap'.
tagSpec :: Text -> Maybe (Family, [FieldClass])
tagSpec = flip Map.lookup tagSpecMap

-- | The @WOK_NODES@ roster with each tag's @*_FIELDS@ list, transcribed
-- from wok_ast.h. Every tag consumes EXACTLY these fields, in this order.
-- A 'Map' CAF (built once, shared) rather than a ~70-way sequential
-- 'Text' case, which forced a linear scan per lookup.
tagSpecMap :: Map Text (Family, [FieldClass])
tagSpecMap = Map.fromList
  -- names and paths
  [ ("N_Name", (FamName, [CName, CFlag]))
  , ("N_ModPath", (FamPath, [CSeq FamName]))
  -- declarations
  , ("D_Module", (FamDecl, [CNode FamPath]))
  , ("D_Import", (FamDecl, [CNode FamPath, CSeq FamName, COpt FamName]))
  , ("D_Type", (FamDecl, [CName, CSeq FamTyParam, CSeq FamConDef]))
  , ("D_Alias", (FamDecl, [CName, CSeq FamTyParam, CNode FamType]))
  , ("D_Effect", (FamDecl, [CName, CSeq FamTyParam, CSeq FamOpSig]))
  , ("D_Class", (FamDecl, [CName, CSeq FamTyParam, CSeq FamDecl]))
  , ("D_Instance", (FamDecl, [COpt FamType, CName, CSeq FamType, CSeq FamDecl]))
  , ("D_Foreign", (FamDecl, [CName, CText, CSeq FamForeignMem]))
  , ("D_ExternType", (FamDecl, [CName, CSeq FamTyParam]))
  , ("D_Sig", (FamDecl, [CSeq FamSigName, CNode FamType, CFlag]))
  , ("D_Fixity", (FamDecl, [CName, CFlag, CInt, CSeq FamFixRel]))
  , ("D_Equation", (FamDecl, [CNode FamLhs, CNode FamExpr, CSeq FamDecl]))
  , ("D_Error", (FamError, [CText]))
  -- declaration helpers
  , ("H_TyParam", (FamTyParam, [CName, CFlag]))
  , ("H_ConDef", (FamConDef, [CName, CSeq FamType, CSeq FamFieldType, CFlag]))
  , ("H_FieldType", (FamFieldType, [CName, CNode FamType]))
  , ("H_OpSig", (FamOpSig, [CName, CNode FamType]))
  , ("H_FixRel", (FamFixRel, [CInt, CName, CFlag]))
  , ("H_ForeignMember", (FamForeignMem, [CName, CText, CNode FamType]))
  , ("H_SigName", (FamSigName, [CName, CFlag]))
  , ("L_Prefix", (FamLhs, [CName, CFlag, CSeq FamPat]))
  , ("L_Infix", (FamLhs, [CNode FamPat, CName, CFlag, CNode FamPat]))
  -- types
  , ("T_Var", (FamType, [CName]))
  , ("T_Con", (FamType, [CNode FamPath]))
  , ("T_App", (FamType, [CNode FamType, CNode FamType]))
  , ("T_Fun", (FamType, [CNode FamType, CNode FamType]))
  , ("T_Qual", (FamType, [CNode FamType, CNode FamType]))
  , ("T_With", (FamType, [CNode FamType, CSeq FamRowEntry]))
  , ("T_List", (FamType, [CNode FamType]))
  , ("T_Tuple", (FamType, [CSeq FamType]))
  , ("T_Unit", (FamType, []))
  , ("T_RowArg", (FamType, [CName]))
  , ("T_Transfer", (FamType, [CInt, CNode FamType]))
  , ("H_RowEntry", (FamRowEntry, [CInt, CName, COpt FamType]))
  -- patterns
  , ("P_Var", (FamPat, [CName]))
  , ("P_Wild", (FamPat, []))
  , ("P_Int", (FamPat, [CInt, CFlag]))
  , ("P_Str", (FamPat, [CText]))
  , ("P_Char", (FamPat, [CText]))
  , ("P_Con", (FamPat, [CNode FamPath, CSeq FamPat]))
  , ("P_Cons", (FamPat, [CNode FamPat, CNode FamPat]))
  , ("P_Tuple", (FamPat, [CSeq FamPat]))
  , ("P_List", (FamPat, [CSeq FamPat]))
  , ("P_Unit", (FamPat, []))
  , ("P_As", (FamPat, [CNode FamPat, CName]))
  , ("P_Record", (FamPat, [CNode FamPath, CSeq FamFieldPat, CFlag, CName]))
  , ("H_FieldPat", (FamFieldPat, [CName, CNode FamPat]))
  -- expressions
  , ("E_Var", (FamExpr, [CName]))
  , ("E_Con", (FamExpr, [CName]))
  , ("E_Int", (FamExpr, [CInt]))
  , ("E_Str", (FamExpr, [CText]))
  , ("E_Char", (FamExpr, [CText]))
  , ("E_Unit", (FamExpr, []))
  , ("E_OpRef", (FamExpr, [CName]))
  , ("E_App", (FamExpr, [CNode FamExpr, CNode FamExpr]))
  , ("E_Chain", (FamExpr, [CNode FamExpr, CSeq FamChainOp]))
  , ("E_Dot", (FamExpr, [CNode FamExpr, CName, CFlag]))
  , ("E_Neg", (FamExpr, [CNode FamExpr]))
  , ("E_List", (FamExpr, [CSeq FamExpr]))
  , ("E_Tuple", (FamExpr, [CSeq FamExpr]))
  , ("E_Lambda", (FamExpr, [CSeq FamPat, CNode FamExpr]))
  , ("E_LetIn", (FamExpr, [CNode FamBind, CNode FamExpr]))
  , ("E_HandleIn", (FamExpr, [CName, CNode FamExpr, CNode FamExpr]))
  , ("E_UseIn", (FamExpr, [CSeq FamUseBind, CNode FamExpr]))
  , ("E_If", (FamExpr, [CNode FamExpr, CNode FamExpr, CNode FamExpr]))
  , ("E_Case", (FamExpr, [CNode FamExpr, CSeq FamAlt]))
  , ("E_Handler", (FamExpr, [CName, CSeq FamClause]))
  , ("E_Assign", (FamExpr, [CNode FamExpr, CNode FamExpr]))
  , ("E_Record", (FamExpr, [CNode FamExpr, COpt FamExpr, CSeq FamField]))
  , ("E_Block", (FamExpr, [CSeq FamStmt]))
  , ("E_Error", (FamError, [CText]))
  -- statements
  , ("S_Let", (FamStmt, [CNode FamBind]))
  , ("S_Handle", (FamStmt, [CName, CNode FamExpr]))
  , ("S_Use", (FamStmt, [CSeq FamUseBind]))
  , ("S_Discard", (FamStmt, [CNode FamExpr]))
  -- expression helpers
  , ("H_ChainOp", (FamChainOp, [CName, CFlag, CNode FamExpr]))
  , ("H_Bind", (FamBind, [CNode FamBindLhs, CNode FamExpr]))
  , ("H_UseBind", (FamUseBind, [CName, CName]))
  , ("H_Alt", (FamAlt, [CNode FamPat, CNode FamExpr, CSeq FamDecl]))
  , ("H_Clause", (FamClause, [CInt, CName, CSeq FamPat, CName, CNode FamExpr]))
  , ("H_Field", (FamField, [CName, CNode FamExpr]))
  -- the file
  , ("W_File", (FamFile, [CSeq FamDecl]))
  ]

-- H_Clause kind constants (wok_ast.h WOK_CLAUSE_*).
clausePlain, clauseControl, clauseReturn, clauseVar, clauseAbort :: Integer
clausePlain = 0
clauseControl = 1
clauseReturn = 2
clauseVar = 3
clauseAbort = 4

-- H_RowEntry kind constants (WOK_ROW_*).
rowSlot, rowRole, rowVar :: Integer
rowSlot = 0
rowRole = 1
rowVar = 2

-- ---------------------------------------------------------------------
-- Pass 1: schema validation into a typed generic tree
-- ---------------------------------------------------------------------

-- | A schema-validated node: its tag, the family the tag belongs to, the
-- position of its opening parenthesis in the dump, and its fields.
data GNode = GNode
  { gTag :: Text
  , gFamily :: Family
  , gPos :: Pos
  , gFields :: [GField]
  }

-- | A validated field. Integers keep the original decimal spelling so a
-- literal survives verbatim into a v1 token.
data GField
  = FldNode GNode
  | FldOpt (Maybe GNode)
  | FldSeq [GNode]
  | FldName Text Pos
  | FldText Text Pos
  | FldInt Integer Text Pos
  | FldFlag Bool Pos

sexpPos :: SExp -> Pos
sexpPos s = case s of
  SWord _ p -> p
  SString _ p -> p
  SList _ p -> p

checkNode :: SExp -> Either SurfaceError GNode
checkNode s = case s of
  SList (SWord tag _ : rawFields) listPos -> case tagSpec tag of
    Nothing ->
      mal listPos ("unknown node tag `" ++ T.unpack tag ++ "`")
    Just (fam, spec)
      | length rawFields /= length spec ->
          mal listPos
            (T.unpack tag ++ " expects " ++ show (length spec)
               ++ " fields, found " ++ show (length rawFields))
      | otherwise ->
          GNode tag fam listPos <$> zipWithM (checkField tag) spec rawFields
  SList _ p -> mal p "a node must be a list headed by a tag word"
  SWord w p -> mal p ("expected a node, found the word `" ++ T.unpack w ++ "`")
  SString _ p -> mal p "expected a node, found a string"

checkField :: Text -> FieldClass -> SExp -> Either SurfaceError GField
checkField tag cls s = case cls of
  CName -> case s of
    SString t p -> Right (FldName t p)
    _ -> shapeErr "a quoted name"
  CText -> case s of
    SString t p -> Right (FldText t p)
    _ -> shapeErr "a quoted text lexeme"
  CInt -> case s of
    SWord w p
      | not (T.null w) && T.all isDigit w ->
          Right (FldInt (decimalValue w) w p)
    _ -> shapeErr "a decimal integer"
  CFlag -> case s of
    SWord w p
      | w == T.pack "#t" -> Right (FldFlag True p)
      | w == T.pack "#f" -> Right (FldFlag False p)
    _ -> shapeErr "#t or #f"
  CNode want -> FldNode <$> checkChild want s
  COpt want -> case s of
    SList [SWord kw _] _
      | kw == T.pack "none" -> Right (FldOpt Nothing)
    SList [SWord kw _, x] _
      | kw == T.pack "some" -> FldOpt . Just <$> checkChild want x
    _ -> shapeErr "(none) or (some X)"
  CSeq want -> case s of
    SList (SWord kw _ : items) _
      | kw == T.pack "seq" -> FldSeq <$> mapM (checkChild want) items
    _ -> shapeErr "a (seq ...) form"
  where
    shapeErr what =
      mal (sexpPos s)
        ("a field of " ++ T.unpack tag ++ " expects " ++ what)

checkChild :: Family -> SExp -> Either SurfaceError GNode
checkChild want s = do
  n <- checkNode s
  if familyAccepts want (gFamily n)
    then Right n
    else
      mal (gPos n)
        ("a " ++ familyName want ++ " field cannot hold " ++ T.unpack (gTag n)
           ++ " (family " ++ familyName (gFamily n) ++ ")")

-- The word was validated to be all decimal digits.
decimalValue :: Text -> Integer
decimalValue = T.foldl' step 0
  where
    step acc c = acc * 10 + toInteger (fromEnum c - fromEnum '0')

-- ---------------------------------------------------------------------
-- Pass 2: mapping to the v1 surface
-- ---------------------------------------------------------------------

-- | Map a dump (one @W_File@ datum, as 'Wok.Sexp.Read.readSExp' returns
-- it) to a v1 module.
surfaceModule :: SExp -> Either SurfaceError Abs.Module
surfaceModule s = do
  root <- checkNode s
  case (gTag root, gFields root) of
    ("W_File", [FldSeq decls]) -> Abs.Module <$> mapM mapDecl decls
    _ -> mal (gPos root) "the root of a dump must be W_File"

-- Token builders: D4 positions, straight from the dump datum.

tokPos :: Pos -> (Int, Int)
tokPos (Pos l c) = (l, c)

mkVarId :: Pos -> Text -> Abs.VarId
mkVarId p t = Abs.VarId (tokPos p, t)

mkConId :: Pos -> Text -> Abs.ConId
mkConId p t = Abs.ConId (tokPos p, t)

mkVarSym :: Pos -> Text -> Abs.VarSym
mkVarSym p t = Abs.VarSym (tokPos p, t)

mkWokInt :: Pos -> Text -> Abs.WokInt
mkWokInt p t = Abs.WokInt (tokPos p, t)

-- The VarSym character set of grammar/Wok.cf, for the one v1 split the
-- schema carries no flag for: an L_Prefix head is FNBareSym exactly when
-- its spelling is a symbol run.
startsSymbolic :: Text -> Bool
startsSymbolic t = case T.uncons t of
  Just (c, _) -> c `elem` ("!#$%&*+/<=>?@\\^|-~" :: String)
  Nothing -> False

startsUpper :: Text -> Bool
startsUpper t = case T.uncons t of
  Just (c, _) -> isUpper c
  Nothing -> False

-- Names -----------------------------------------------------------------

nameParts :: GNode -> Either SurfaceError (Text, Bool, Pos)
nameParts n = case (gTag n, gFields n) of
  ("N_Name", [FldName t p, FldFlag up _]) -> Right (t, up, p)
  _ -> unmappable n "a name"

pathParts :: GNode -> Either SurfaceError [(Text, Bool, Pos)]
pathParts n = case (gTag n, gFields n) of
  ("N_ModPath", [FldSeq parts]) -> mapM nameParts parts
  _ -> unmappable n "a module path"

-- Module-path parts are structurally ConIds in v1; the upper flag is the
-- authority, and a contradicting flag is a dump the v2 parser cannot
-- have produced.
mapModPath :: GNode -> Either SurfaceError Abs.ModPath
mapModPath n = do
  parts <- pathParts n
  cids <- mapM upperPart parts
  case cids of
    [] -> mal (gPos n) "a module path needs at least one part"
    (c : cs) -> Right (foldl Abs.MPDot (Abs.MPName c) cs)
  where
    upperPart (t, up, p)
      | up = Right (mkConId p t)
      | otherwise = mal p "a module path part must be an upper name (N_Name upper flag)"

-- Declarations ------------------------------------------------------------

mapDecl :: GNode -> Either SurfaceError Abs.Decl
mapDecl n = case (gTag n, gFields n) of
  ("D_Module", [FldNode path]) ->
    Abs.DModule <$> mapModPath path
  ("D_Import", [FldNode path, FldSeq names, FldOpt malias]) -> do
    mp <- mapModPath path
    case (names, malias) of
      ([], Nothing) -> Right (Abs.DImport mp Abs.IMPlain)
      (ns@(_ : _), Nothing) ->
        Abs.DImport mp . Abs.IMList <$> mapM importName ns
      ([], Just alias) -> do
        (t, up, p) <- nameParts alias
        if up
          then Right (Abs.DImport mp (Abs.IMAs (mkConId p t)))
          else mal p "an import alias must be an upper name (N_Name upper flag)"
      (_ : _, Just _) ->
        gap n "import-list-plus-alias" "v1 imports cannot carry both a name list and an alias"
  ("D_Type", [FldName nm np, FldSeq params, FldSeq cons]) -> do
    tps <- mapM tyParam params
    cds <- mapM conDef cons
    Right (Abs.DData (mkConId np nm) tps cds)
  ("D_Alias", [FldName _ _, FldSeq _, FldNode _]) ->
    gap n "type-alias-decl" "v1 has no type-alias declaration"
  ("D_Effect", [FldName nm np, FldSeq params, FldSeq ops]) -> do
    vs <- mapM (plainParamVar "effect") params
    fts <- mapM opSig ops
    Right (Abs.DEffect (mkConId np nm) vs fts)
  ("D_Class", [FldName nm np, FldSeq params, FldSeq body]) -> do
    vs <- mapM (plainParamVar "class") params
    entries <- concat <$> mapM classEntry body
    Right (Abs.DClass (mkConId np nm) vs entries)
  ("D_Instance", [FldOpt mctx, FldName nm np, FldSeq args, FldSeq body]) -> do
    tys <- mapM mapType args
    hd <- case mctx of
      Nothing -> Right (Abs.IHPlain (mkConId np nm) tys)
      Just ctx -> do
        cs <- constraintsOf ctx
        Right (Abs.IHCtx cs (mkConId np nm) tys)
    entries <- mapM instEntry body
    Right (Abs.DInstance hd entries)
  ("D_Foreign", [FldName nm np, FldText lib lp, FldSeq members]) -> do
    libStr <- strLexemeAt lp lib
    ms <- mapM foreignMember members
    -- v2 has no `free <sym>` field on a foreign module, so the mapped
    -- decl always carries FFNone (see the gap inventory).
    Right (Abs.DForeign (mkConId np nm) libStr Abs.FFNone ms)
  ("D_ExternType", [FldName nm np, FldSeq params]) ->
    Abs.DExternType (mkConId np nm) <$> mapM tyParam params
  ("D_Sig", [FldSeq names, FldNode ty, FldFlag isExtern _]) ->
    sigFields n names ty $ \s0 rest t ->
      Right ((if isExtern then Abs.DExtern else Abs.DSig) s0 (map Abs.SNCons rest) t)
  ("D_Fixity", [FldName nm np, FldFlag alpha _, FldInt assoc _ ap, FldSeq rels]) -> do
    fa <- case assoc of
      0 -> Right Abs.FALeft
      1 -> Right Abs.FARight
      _ -> mal ap "D_Fixity assoc must be 0 (left) or 1 (right)"
    rs <- mapM fixRel rels
    Right (Abs.DFixity (fixName alpha np nm) fa rs)
  ("D_Equation", [FldNode lhs, FldNode body, FldSeq wheres]) ->
    Abs.DEqn <$> mapFunLHS lhs <*> mapExpr body <*> whereBlock wheres
  _ -> unmappable n "a declaration"

-- | Shared skeleton of the @D_Sig@ clauses in 'mapDecl' and 'localDecl':
-- both parse the same @[FldSeq names, FldNode ty, FldFlag isExtern _]@
-- shape into a type and a non-empty name list, then differ only in what
-- they build from ('isExtern', the first name, the rest, and the type).
-- 'classEntry''s @D_Sig@ clause is genuinely different (extern is always
-- rejected there, with no per-arm branching to share, and it fans out to
-- one 'Abs.ClassEntry' per name rather than one decl for the group) and
-- is intentionally NOT routed through this helper.
sigFields
  :: GNode
  -> [GNode]
  -> GNode
  -> (Abs.SigName -> [Abs.SigName] -> Abs.Type -> Either SurfaceError a)
  -> Either SurfaceError a
sigFields n names ty k = do
  t <- mapType ty
  sns <- mapM sigName names
  case sns of
    [] -> mal (gPos n) "a signature needs at least one name"
    (s0 : rest) -> k s0 rest t

importName :: GNode -> Either SurfaceError Abs.ImportName
importName n = do
  (t, up, p) <- nameParts n
  if up
    then gap n "import-list-upper-name" "v1 import lists are vars-only; an upper name cannot be filtered in"
    else Right (Abs.INVar (mkVarId p t))

tyParam :: GNode -> Either SurfaceError Abs.TyParam
tyParam n = case (gTag n, gFields n) of
  ("H_TyParam", [FldName t p, FldFlag isRow _]) ->
    Right (if isRow then Abs.TPRow (mkVarId p t) else Abs.TPPlain (mkVarId p t))
  _ -> unmappable n "a type parameter"

-- For the v1 decls whose parameter lists are bare VarIds (effect, class).
plainParamVar :: String -> GNode -> Either SurfaceError Abs.VarId
plainParamVar what n = case (gTag n, gFields n) of
  ("H_TyParam", [FldName t p, FldFlag isRow _])
    | isRow -> gap n "row-kinded-decl-param" ("v1 " ++ what ++ " parameters are plain type variables; no (row e) form")
    | otherwise -> Right (mkVarId p t)
  _ -> unmappable n "a type parameter"

conDef :: GNode -> Either SurfaceError Abs.ConDef
conDef n = case (gTag n, gFields n) of
  ("H_ConDef", [FldName nm np, FldSeq args, FldSeq fields, FldFlag isRecord _])
    | isRecord -> case args of
        (_ : _) -> mal (gPos n) "a record constructor cannot carry positional arguments"
        [] -> do
          fts <- mapM fieldType fields
          Right $
            if T.null nm
              then Abs.ConDefRecElide fts
              else Abs.ConDefRec (mkConId np nm) fts
    | otherwise -> case fields of
        (_ : _) -> mal (gPos n) "a positional constructor cannot carry record fields"
        []
          | T.null nm -> mal (gPos n) "a positional constructor needs a name"
          | otherwise -> Abs.ConDef (mkConId np nm) <$> mapM mapType args
  _ -> unmappable n "a constructor definition"

-- | Shared body of 'fieldType' and 'opSig': both destructure a
-- @[FldName, FldNode]@ pair into an 'Abs.RFType' and differ only in which
-- tag they require and what the "unmappable" error calls the node.
namedTypedField :: Text -> String -> GNode -> Either SurfaceError Abs.RecordFieldType
namedTypedField wantTag what n = case (gTag n, gFields n) of
  (tag, [FldName t p, FldNode ty]) | tag == wantTag ->
    Abs.RFType (mkVarId p t) <$> mapType ty
  _ -> unmappable n what

fieldType :: GNode -> Either SurfaceError Abs.RecordFieldType
fieldType = namedTypedField "H_FieldType" "a record field type"

opSig :: GNode -> Either SurfaceError Abs.RecordFieldType
opSig = namedTypedField "H_OpSig" "an operation signature"

sigName :: GNode -> Either SurfaceError Abs.SigName
sigName n = case (gTag n, gFields n) of
  ("H_SigName", [FldName t p, FldFlag paren _]) ->
    Right (if paren then Abs.SNParen (mkVarSym p t) else Abs.SNBare (mkVarId p t))
  _ -> unmappable n "a signature name"

fixName :: Bool -> Pos -> Text -> Abs.FixName
fixName alpha p t
  | alpha = Abs.FNAlpha (mkVarId p t)
  | otherwise = Abs.FNSym (mkVarSym p t)

fixRel :: GNode -> Either SurfaceError Abs.FixRel
fixRel n = case (gTag n, gFields n) of
  ("H_FixRel", [FldInt sense _ sp, FldName t p, FldFlag alpha _]) ->
    case sense of
      0 -> Right (Abs.FRTight (fixName alpha p t))
      1 -> Right (Abs.FRLoose (fixName alpha p t))
      _ -> mal sp "H_FixRel sense must be 0 (tighter) or 1 (looser)"
  _ -> unmappable n "a fixity relation"

classEntry :: GNode -> Either SurfaceError [Abs.ClassEntry]
classEntry n = case (gTag n, gFields n) of
  ("D_Sig", [FldSeq names, FldNode ty, FldFlag isExtern _])
    | isExtern -> gap n "class-extern-sig" "v1 class bodies cannot hold extern signatures"
    | otherwise -> do
        t <- mapType ty
        mapM (methodSig t) names
  ("D_Equation", [FldNode lhs, FldNode body, FldSeq wheres]) ->
    case wheres of
      [] -> do
        l <- mapFunLHS lhs
        e <- mapExpr body
        Right [Abs.CEDefault l e]
      (_ : _) -> gap n "class-default-where" "v1 class default equations carry no where-block"
  _ -> do
    notDamaged n
    gap n "class-body-decl-kind" "v1 class bodies allow only method signatures and default equations"

methodSig :: Abs.Type -> GNode -> Either SurfaceError Abs.ClassEntry
methodSig t n = case (gTag n, gFields n) of
  ("H_SigName", [FldName nm p, FldFlag paren _]) ->
    Right (Abs.CESig (if paren then Abs.MNParen (mkVarSym p nm) else Abs.MNBare (mkVarId p nm)) t)
  _ -> unmappable n "a method name"

instEntry :: GNode -> Either SurfaceError Abs.InstEntry
instEntry n = case (gTag n, gFields n) of
  ("D_Equation", [FldNode lhs, FldNode body, FldSeq wheres]) ->
    case wheres of
      [] -> Abs.IEImpl <$> mapFunLHS lhs <*> mapExpr body
      (_ : _) -> gap n "instance-method-where" "v1 instance equations carry no where-block"
  _ -> do
    notDamaged n
    gap n "instance-body-decl-kind" "v1 instance bodies are method equations only"

-- Instance context: the v2 dump carries the LHS as a plain type; v1 wants
-- a [Constraint]. A tuple contributes one constraint per component.
constraintsOf :: GNode -> Either SurfaceError [Abs.Constraint]
constraintsOf n = case (gTag n, gFields n) of
  ("T_Tuple", [FldSeq items]) -> mapM constraint1 items
  _ -> (: []) <$> constraint1 n

constraint1 :: GNode -> Either SurfaceError Abs.Constraint
constraint1 n = do
  let (hd, args) = typeSpine n
  case (gTag hd, gFields hd) of
    ("T_Con", [FldNode pathN]) -> do
      parts <- pathParts pathN
      case parts of
        [(t, True, p)] -> Abs.Constraint (mkConId p t) <$> mapM mapType args
        _ -> gap n "qualified-constraint-head" "v1 instance contexts are `Class Type*` constraints with an unqualified class head"
    _ -> do
      notDamaged hd
      gap n "non-constraint-context" "v1 instance contexts are lists of `Class Type*` constraints"

foreignMember :: GNode -> Either SurfaceError Abs.ForeignMember
foreignMember n = case (gTag n, gFields n) of
  ("H_ForeignMember", [FldName nm np, FldText sym sp, FldNode ty]) -> do
    fs <-
      if T.null sym
        then Right Abs.FSNone
        else Abs.FSName <$> strLexemeAt sp sym
    -- v1's `owned` MEMBER marker (FMOwned, transfer-full result) has no
    -- field in the v2 schema; transfer travels on the member's TYPE as
    -- T_Transfer instead. Members therefore always map to FMPlain.
    Abs.FMPlain (mkVarId np nm) fs <$> mapType ty
  _ -> unmappable n "a foreign member"

whereBlock :: [GNode] -> Either SurfaceError Abs.MaybeWhere
whereBlock ds = case ds of
  [] -> Right Abs.NoWhere
  _ -> Abs.WithWh <$> mapM localDecl ds

localDecl :: GNode -> Either SurfaceError Abs.LocalDecl
localDecl n = case (gTag n, gFields n) of
  ("D_Equation", [FldNode lhs, FldNode body, FldSeq wheres]) ->
    Abs.LDEqn <$> mapFunLHS lhs <*> mapExpr body <*> whereBlock wheres
  ("D_Sig", [FldSeq names, FldNode ty, FldFlag isExtern _])
    | isExtern -> gap n "where-extern-sig" "v1 local blocks cannot hold extern signatures"
    | otherwise ->
        sigFields n names ty $ \s0 rest t ->
          Right (Abs.LDSig s0 (map Abs.SNCons rest) t)
  _ -> do
    notDamaged n
    gap n "where-decl-kind" "v1 where-blocks allow only equations and signatures"

-- Left-hand sides -----------------------------------------------------------

mapFunLHS :: GNode -> Either SurfaceError Abs.FunLHS
mapFunLHS n = case (gTag n, gFields n) of
  ("L_Prefix", [FldName t p, FldFlag paren _, FldSeq args]) -> do
    aps <- mapM patAtom args
    Right (Abs.LHSPre (funName paren p t) aps)
  ("L_Infix", [FldNode l, FldName op opP, FldFlag backtick _, FldNode r]) -> do
    la <- patAtom l
    ra <- patAtom r
    Right $
      if backtick
        then Abs.LHSInfBT la (mkVarId opP op) ra
        else Abs.LHSInfSym la (mkVarSym opP op) ra
  _ -> unmappable n "a function left-hand side"

-- L_Prefix carries no symbol-vs-identifier flag (unlike D_Fixity's
-- `alpha`), so the FNBareSym/FNBare split must read the spelling: a v1
-- VarSym is a run of symbol characters, and cannot overlap a VarId.
funName :: Bool -> Pos -> Text -> Abs.FunName
funName paren p t
  | paren = Abs.FNParen (mkVarSym p t)
  | startsSymbolic t = Abs.FNBareSym (mkVarSym p t)
  | otherwise = Abs.FNBare (mkVarId p t)

-- Types ----------------------------------------------------------------

-- Peel a left-nested T_App spine into its head and argument list.
typeSpine :: GNode -> (GNode, [GNode])
typeSpine = go []
  where
    go acc n = case (gTag n, gFields n) of
      ("T_App", [FldNode f, FldNode a]) -> go (a : acc) f
      _ -> (n, acc)

-- | Wrap a mapped domain 'Abs.Type' in 'Abs.TParen' when it is NOT valid
-- where the v1 grammar requires a `Type1` (a 'TFun'/'TWith''s domain
-- slot, grammar\/Wok.cf ~line 316): 'Abs.TQual'\/'Abs.TWith'\/'Abs.TFun'
-- are `Type`-only productions there, never `Type1` -- wrapping is the
-- ONLY way v1's tree can represent "a function type as another
-- function's domain" at all, so this is a structural requirement, not a
-- style choice.
wrapTypeDomain :: Abs.Type -> Abs.Type
wrapTypeDomain t = case t of
  Abs.TQual {} -> Abs.TParen t
  Abs.TWith {} -> Abs.TParen t
  Abs.TFun  {} -> Abs.TParen t
  _            -> t

-- | Wrap a mapped codomain 'Abs.Type' in 'Abs.TParen' when it is itself a
-- 'Abs.TWith'. In v1 an UNPARENTHESIZED trailing `with E` attaches to the
-- INNERMOST arrow (`A -> B -> C with E` parses as `TFun A (TWith B C E)`;
-- Infer.hs's @goT (Abs.TWith ...)@ note is the authority -- the
-- grammar\/Wok.cf comment claiming whole-chain scope is misleading), so a
-- 'TWith' standing as another arrow's codomain can only have come from
-- explicit source parens (`a -> (b -> c with E)`) -- which is exactly how
-- the v2 dump presents it: a distinct nested @T_With@ node. A plain
-- nested 'TFun' codomain needs no wrap -- the grammar's right-recursive
-- `Type ::= Type1 "->" Type` already chains it correctly on its own.
wrapWithScope :: Abs.Type -> Abs.Type
wrapWithScope t@(Abs.TWith {}) = Abs.TParen t
wrapWithScope t                = t

mapType :: GNode -> Either SurfaceError Abs.Type
mapType n = case (gTag n, gFields n) of
  ("T_Var", [FldName t p]) -> Right (Abs.TVar (mkVarId p t))
  ("T_Con", [FldNode path]) -> Abs.TCon <$> mapModPath path
  ("T_App", [FldNode f, FldNode a]) -> Abs.TApp <$> mapType f <*> mapType a
  ("T_Fun", [FldNode from, FldNode to]) ->
    (Abs.TFun . wrapTypeDomain <$> mapType from) <*> (wrapWithScope <$> mapType to)
  ("T_Qual", [FldNode ctx, FldNode body]) ->
    -- v1's own parser ALWAYS wraps a constraint context in TParen (the
    -- surface convention is `(Eq a) => T`, never a bare `Eq a => T`;
    -- grammar/Wok.cf's TQual DESIGN NOTE: "The surface form `(Eq a)`
    -- arrives as a TParen of a TApp"). Unconditional, not just
    -- 'wrapTypeDomain''s level check.
    (Abs.TQual . Abs.TParen <$> mapType ctx) <*> mapType body
  ("T_With", [FldNode body, FldSeq row]) ->
    case (gTag body, gFields body) of
      ("T_Fun", [FldNode from, FldNode to]) -> do
        r <- effectRow (gPos n) row
        mapWithArrow from to r
      _ -> do
        notDamaged body
        gap n "non-arrow-with" "v1 attaches `with` only to an arrow type (Type1 -> Type with Row)"
  ("T_List", [FldNode el]) -> Abs.TList <$> mapType el
  ("T_Tuple", [FldSeq items]) -> case items of
    (i1 : i2 : rest) -> do
      t1 <- mapType i1
      ts <- mapM mapType (i2 : rest)
      Right (Abs.TTuple t1 ts)
    _ -> mal (gPos n) "a tuple type needs at least two components"
  ("T_Unit", []) -> Right Abs.TUnit
  ("T_RowArg", [FldName t p]) -> Right (Abs.TRowArg (mkVarId p t))
  ("T_Transfer", [FldInt mode _ mp, FldNode body])
    | mode == 0 -> Abs.TOwned <$> mapType body
    | mode == 1 -> gap n "lend-transfer" "v1 has no `lend` (borrow-tier) type-transfer spelling"
    | mode == 2 -> gap n "copy-transfer" "v1 spells copy transfer by omission; there is no explicit `copy` modifier"
    | otherwise -> mal mp "T_Transfer mode out of range"
  _ -> unmappable n "a type"

-- | The F1 root-cause fix: a @T_With@ over an arrow chain attaches its
-- row to the INNERMOST arrow, matching the v1 BNFC parse and the
-- typechecker's reading (Infer.hs @goT (Abs.TWith ...)@: `A -> B -> C
-- with E` IS `TFun A (TWith B C E)` -- E rides the arrow a
-- fully-applied curried function performs its effects behind). So the
-- mapper descends the dumped arrow spine while the codomain is a BARE
-- @T_Fun@, rebuilding 'Abs.TFun' per level, and bottoms out in
-- 'Abs.TWith' on the last arrow. A codomain that is anything else -- in
-- particular a nested @T_With@, which the dump carries as a distinct
-- node exactly when the source parenthesized it -- stops the descent
-- and maps through the ordinary 'mapType' (+ 'wrapWithScope') path.
mapWithArrow :: GNode -> GNode -> Abs.EffectRow -> Either SurfaceError Abs.Type
mapWithArrow from to r = do
  from' <- wrapTypeDomain <$> mapType from
  case (gTag to, gFields to) of
    ("T_Fun", [FldNode from2, FldNode to2]) ->
      Abs.TFun from' <$> mapWithArrow from2 to2 r
    _ -> do
      to' <- wrapWithScope <$> mapType to
      Right (Abs.TWith from' to' r)

-- Effect rows -----------------------------------------------------------

data RowItem
  = RIAtom Abs.EffectAtom Pos
  | RIVar Abs.VarId Pos

effectRow :: Pos -> [GNode] -> Either SurfaceError Abs.EffectRow
effectRow herePos entries = do
  items <- mapM rowItem entries
  buildRow items
  where
    buildRow items = case items of
      [] -> mal herePos "an effect row cannot be empty"
      [RIAtom a _] -> Right (Abs.EROne a)
      [RIVar v _] -> Right (Abs.ERVarOnly v)
      (RIAtom a p : rest) ->
        Abs.ERPlus a (mkVarSym p (T.pack "+")) <$> buildRow rest
      (RIVar _ p : _ : _) ->
        gapAt p "H_RowEntry" "row-var-not-tail" "v1 effect rows allow a row variable only as the final tail"

rowItem :: GNode -> Either SurfaceError RowItem
rowItem n = case (gTag n, gFields n) of
  ("H_RowEntry", [FldInt kind _ kp, FldName label lp, FldOpt mty])
    | kind == rowSlot -> case (T.null label, mty) of
        (True, Just ty) -> RIAtom <$> effectAtom ty <*> pure (gPos n)
        (False, _) -> mal lp "a slot row entry carries no label"
        (True, Nothing) -> mal (gPos n) "a slot row entry needs its effect type"
    | kind == rowRole ->
        gap n "role-row-entry" "v1 effect rows have no role obligations `(name : Effect)`"
    | kind == rowVar -> case (T.null label, mty) of
        (False, Nothing) -> Right (RIVar (mkVarId lp label) (gPos n))
        (True, _) -> mal lp "a row-variable entry needs a name"
        (False, Just _) -> mal (gPos n) "a row-variable entry carries no type"
    | otherwise -> mal kp "H_RowEntry kind out of range"
  _ -> unmappable n "a row entry"

effectAtom :: GNode -> Either SurfaceError Abs.EffectAtom
effectAtom n = do
  let (hd, args) = typeSpine n
  case (gTag hd, gFields hd) of
    ("T_Con", [FldNode pathN]) -> do
      parts <- pathParts pathN
      case parts of
        [(t, True, p)] -> Abs.ERAtom (mkConId p t) <$> mapM mapType args
        _ -> gap n "qualified-effect-atom" "v1 effect atoms are unqualified (`ConId Type*`)"
    _ -> do
      notDamaged hd
      gap n "non-constructor-effect-atom" "v1 effect atoms are `ConId Type*` applications"

-- Patterns ----------------------------------------------------------------

-- v1 wants an AtomPat in binder positions (LHS args, lambda params, the
-- continuation slot). The dump carries no parens, so any non-atomic
-- pattern is wrapped in APParen, which prints back as the parens the v2
-- source must have had.
patAtom :: GNode -> Either SurfaceError Abs.AtomPat
patAtom n = do
  p <- mapPat n
  Right $ case p of
    Abs.PAtom a -> a
    other -> Abs.APParen other

mapPat :: GNode -> Either SurfaceError Abs.Pat
mapPat n = case (gTag n, gFields n) of
  ("P_Var", [FldName t p]) -> Right (Abs.PAtom (Abs.APVar (mkVarId p t)))
  ("P_Wild", []) -> Right (Abs.PAtom Abs.APWild)
  ("P_Int", [FldInt _ raw ip, FldFlag negative _]) ->
    let txt = if negative then T.cons '-' raw else raw
    in Right (Abs.PAtom (Abs.APLitI (mkWokInt ip txt)))
  ("P_Str", [FldText raw p]) ->
    Abs.PAtom . Abs.APLitS <$> strLexemeAt p raw
  ("P_Char", [FldText raw p]) ->
    Abs.PAtom . Abs.APLitC <$> charLexemeAt p raw
  ("P_Con", [FldNode path, FldSeq args]) -> do
    mp <- mapModPath path
    case args of
      [] -> Right (Abs.PAtom (Abs.APCon mp))
      (a1 : rest) -> do
        h <- patAtom a1
        hs <- mapM patAtom rest
        Right (Abs.PApp mp h hs)
  ("P_Cons", [FldNode hd, FldNode tl]) ->
    Abs.PCons <$> patAtom hd <*> mapPat tl
  ("P_Tuple", [FldSeq items]) -> case items of
    (i1 : i2 : rest) -> do
      p1 <- mapPat i1
      ps <- mapM mapPat (i2 : rest)
      Right (Abs.PAtom (Abs.APTuple p1 ps))
    _ -> mal (gPos n) "a tuple pattern needs at least two components"
  ("P_List", [FldSeq items]) ->
    Abs.PAtom . Abs.APList <$> mapM mapPat items
  ("P_Unit", []) -> Right (Abs.PAtom Abs.PUnit)
  ("P_As", [FldNode pat, FldName t p]) -> do
    a <- patAtom pat
    Right (Abs.PAtom (Abs.APAs a (mkVarId p t)))
  ("P_Record", [FldNode path, FldSeq fields, FldFlag isOpen _, FldName rest rp]) -> do
    parts <- pathParts path
    cid <- case parts of
      [(t, True, p)] -> Right (mkConId p t)
      _ -> gap n "qualified-record-pattern-head" "v1 record patterns take an unqualified constructor head"
    fps <- mapM fieldPat fields
    if isOpen
      then
        let tl = if T.null rest then Abs.PRTAnon else Abs.PRTNamed (mkVarId rp rest)
        in Right $ case fps of
             [] -> Abs.PAtom (Abs.PRecordWild cid tl)
             (_ : _) -> Abs.PAtom (Abs.PRecordOpen cid fps tl)
      else
        if T.null rest
          then Right (Abs.PAtom (Abs.PRecord cid fps))
          else mal rp "a closed record pattern carries no ..rest name"
  _ -> unmappable n "a pattern"

fieldPat :: GNode -> Either SurfaceError Abs.RecordFieldPat
fieldPat n = case (gTag n, gFields n) of
  ("H_FieldPat", [FldName t p, FldNode pat]) ->
    Abs.RFPat (mkVarId p t) <$> mapPat pat
  _ -> unmappable n "a record field pattern"

-- Expressions ---------------------------------------------------------------

-- | Wrap a mapped 'Abs.Exp' in 'Abs.EParen' when it is a "greedy-bodied"
-- Exp2 form (grammar\/Wok.cf: 'ELam'\/'ELet'\/'EIf'\/'EWith'\/'EWithH'\/
-- 'EWithRun'\/'EWithNamed'\/'EWithNamedH' -- each ends in a bare,
-- right-recursive `Exp` with no closing token). Grammatically these ARE
-- valid 'Exp2' forms unwrapped, but only when they are the LAST token of
-- the whole expression: as an 'E_App' operand (or head) followed by
-- anything else, an unwrapped one would silently swallow that "anything
-- else" into its own body on reparse -- exactly the hazard v1's own
-- parser avoids by requiring the source to write explicit parens there.
-- v2 does not carry "the user wrote redundant parens" (the same category
-- of loss as positions and comments, spec's Non-goals), so the mapper
-- reconstructs the wrapping a real v1 parse would need in this position.
wrapExpArg :: Abs.Exp -> Abs.Exp
wrapExpArg e = case e of
  Abs.ELam {}        -> Abs.EParen e
  Abs.ELet {}        -> Abs.EParen e
  Abs.EIf {}         -> Abs.EParen e
  Abs.EWith {}       -> Abs.EParen e
  Abs.EWithH {}      -> Abs.EParen e
  Abs.EWithRun {}    -> Abs.EParen e
  Abs.EWithNamed {}  -> Abs.EParen e
  Abs.EWithNamedH {} -> Abs.EParen e
  _                  -> e

mapExpr :: GNode -> Either SurfaceError Abs.Exp
mapExpr n = case (gTag n, gFields n) of
  ("E_Var", [FldName t p]) -> Right (Abs.EVar (mkVarId p t))
  ("E_Con", [FldName t p]) -> Right (Abs.ECon (mkConId p t))
  ("E_Int", [FldInt _ raw p]) -> Right (Abs.ELitI (mkWokInt p raw))
  ("E_Str", [FldText raw p]) -> Abs.ELitS <$> strLexemeAt p raw
  ("E_Char", [FldText raw p]) -> Abs.ELitC <$> charLexemeAt p raw
  ("E_Unit", []) -> Right Abs.EUnit
  ("E_OpRef", [FldName t p]) -> Right (Abs.EParenOp (mkVarSym p t))
  ("E_App", [FldNode f, FldNode a]) ->
    -- Both surfaces apply left-nested binary; no re-spining is needed.
    -- Either side still needs 'wrapExpArg': see its haddock.
    (Abs.EApp . wrapExpArg <$> mapExpr f) <*> (wrapExpArg <$> mapExpr a)
  ("E_Chain", [FldNode hd, FldSeq ops]) ->
    -- UNRESOLVED, deliberately: Wok.Reordering owns fixity (spec D3).
    -- The head is an `Exp1` slot in v1 (EExpr. Exp ::= Exp1 [InfixTail]),
    -- so a greedy-bodied head needs 'wrapExpArg' exactly like an E_App
    -- operand: unwrapped, `(if c then 1 else 2) + 3` would print as
    -- `if c then 1 else 2 + 3` and reparse with `+ 3` swallowed into the
    -- else branch.
    (Abs.EExpr . wrapExpArg <$> mapExpr hd) <*> mapM chainOp ops
  ("E_Dot", [FldNode recv, FldName t p, FldFlag upper _]) -> do
    -- The receiver is an `Exp2` slot (EProj. Exp2 ::= Exp2 "." VarId), so
    -- the same greedy-body hazard applies: `(\ x -> r) . f` unwrapped
    -- would print as `\ x -> r . f` and reparse with `.f` swallowed into
    -- the lambda body.
    r <- wrapExpArg <$> mapExpr recv
    Right $
      if upper
        then Abs.EProjC r (mkConId p t)
        else Abs.EProj r (mkVarId p t)
  ("E_Neg", [FldNode body]) -> case (gTag body, gFields body) of
    ("E_Int", [FldInt _ raw ip]) ->
      Right (Abs.ELitI (mkWokInt ip (T.cons '-' raw)))
    _ -> do
      notDamaged body
      gap n "general-negation" "v1 has no negation operator; only a negative integer literal"
  ("E_List", [FldSeq items]) -> Abs.EList <$> mapM mapExpr items
  ("E_Tuple", [FldSeq items]) -> case items of
    (i1 : i2 : rest) -> do
      e1 <- mapExpr i1
      es <- mapM mapExpr (i2 : rest)
      Right (Abs.ETuple e1 es)
    _ -> mal (gPos n) "a tuple expression needs at least two components"
  ("E_Lambda", [FldSeq params, FldNode body]) -> do
    aps <- mapM patAtom params
    Abs.ELam aps <$> mapExpr body
  ("E_LetIn", [FldNode bind, FldNode body]) -> do
    ld <- bindLocalDecl bind
    Abs.ELet [ld] <$> mapExpr body
  ("E_HandleIn", [FldName label lp, FldNode handler, FldNode body]) ->
    mapHandleIn n label lp handler body
  ("E_UseIn", [FldSeq _, FldNode _]) ->
    gap n "use-rebind" "v1 has no `use x as label` rebind form"
  ("E_If", [FldNode c, FldNode t, FldNode e]) ->
    Abs.EIf <$> mapExpr c <*> mapExpr t <*> mapExpr e
  ("E_Case", [FldNode scrut, FldSeq alts]) ->
    Abs.ECase <$> mapExpr scrut <*> mapM mapAlt alts
  ("E_Handler", [FldName _ _, FldSeq _]) ->
    gap n "handler-value" "v1 has no first-class handler values; a `handler E` literal is mappable only directly under handle"
  ("E_Assign", [FldNode _, FldNode _]) ->
    gap n "frame-slot-assign" "v1 has no `:=` frame-slot assignment surface"
  ("E_Record", [FldNode path, FldOpt spread, FldSeq fields]) ->
    case (gTag path, gFields path) of
      ("E_Con", [FldName t p]) -> do
        fs <- mapM recField fields
        case spread of
          Nothing -> Right (Abs.ERecord (mkConId p t) fs)
          Just sp -> do
            e <- mapExpr sp
            Right $
              Abs.ERecordExt (mkConId p t) e $
                case fs of
                  [] -> Abs.TFNone
                  (_ : _) -> Abs.TFSome fs
      ("E_Dot", [FldNode _, FldName _ _, FldFlag True _]) -> do
        notDamaged path
        gap n "qualified-record-head" "v1 record construction requires an unqualified constructor head"
      _ -> do
        notDamaged path
        gap n "computed-record-head" "v1 record construction requires a bare constructor head"
  ("E_Block", [FldSeq stmts]) -> mapBlock (gPos n) stmts
  _ -> unmappable n "an expression"

chainOp :: GNode -> Either SurfaceError Abs.InfixTail
chainOp n = case (gTag n, gFields n) of
  ("H_ChainOp", [FldName op p, FldFlag backtick _, FldNode rhs]) -> do
    -- The rhs is an `Exp1` slot (ITail. InfixTail ::= InfixOp Exp1): a
    -- greedy-bodied operand needs 'wrapExpArg', or `x + (if c then 1
    -- else 2) + 3` would print with the `+ 3` inside the else branch on
    -- reparse.
    r <- wrapExpArg <$> mapExpr rhs
    Right $
      Abs.ITail
        (if backtick then Abs.IOBT (mkVarId p op) else Abs.IOSym (mkVarSym p op))
        r
  _ -> unmappable n "a chain operator"

mapAlt :: GNode -> Either SurfaceError Abs.Alt
mapAlt n = case (gTag n, gFields n) of
  ("H_Alt", [FldNode pat, FldNode body, FldSeq wheres]) ->
    Abs.AltC <$> mapPat pat <*> mapExpr body <*> whereBlock wheres
  _ -> unmappable n "a case alternative"

recField :: GNode -> Either SurfaceError Abs.RecordFieldExpr
recField n = case (gTag n, gFields n) of
  ("H_Field", [FldName t p, FldNode value]) ->
    Abs.RFExpr (mkVarId p t) <$> mapExpr value
  _ -> unmappable n "a record field"

-- Handler installation --------------------------------------------------------

-- v1 installs only handler LITERALS, through its with-family. A label is
-- a raw NAME span with no case flag in the schema, so the role-vs-slot
-- split (spec-min: lowercase = free role, Capitalized = designation
-- slot) is necessarily read from the spelling.
mapHandleIn
  :: GNode -> Text -> Pos -> GNode -> GNode -> Either SurfaceError Abs.Exp
mapHandleIn n label lp handler body = case (gTag handler, gFields handler) of
  ("E_Handler", [FldName eff ep, FldSeq clauses]) -> do
    arms <- mapM handlerArm clauses
    b <- mapExpr body
    if T.null label
      then Right (Abs.EWithH (mkConId ep eff) [] arms b)
      else
        if startsUpper label
          then
            if label == eff
              then Right (Abs.EWithH (mkConId ep eff) [] arms b)
              else gap n "foreign-slot-label" "v1 cannot install under a designation-slot label other than the handler's own effect"
          else Right (Abs.EWithNamedH (mkVarId lp label) (mkConId ep eff) arms b)
  _ -> do
    notDamaged handler
    gap n "first-class-handler-install" "v1 has no first-class handler values; only a `handler E` literal can be installed"

-- Clause kinds (resolves spec question R1 against main's ACTUAL surface):
--   PLAIN   -> HUArm op <arity pats>           (v1 auto-resume arm)
--   CONTROL -> HUArm op <arity pats + k-var>   (v1 explicit-k arm; both
--              sides are affine one-shot, so the semantics coincide;
--              main never had `once`, so there is nothing to map it to)
--   RETURN  -> HUArm v []  when the clause binds a bare variable (v1's
--              value arm); a PATTERN return clause has no v1 form
--   VAR     -> HParamV
--   ABORT   -> SexpGap: v1 spells never-resume by an explicit-k arm that
--              drops k; mapping would have to invent a binder name
handlerArm :: GNode -> Either SurfaceError Abs.HandlerArm
handlerArm n = case (gTag n, gFields n) of
  ("H_Clause", [FldInt kind _ kp, FldName nm np, FldSeq pats, FldName k kkp, FldNode body])
    | kind == clausePlain ->
        if T.null k
          then do
            requireName
            aps <- mapM patAtom pats
            Abs.HUArm (mkVarId np nm) aps <$> mapExpr body
          else mal kkp "a plain clause binds no continuation"
    | kind == clauseControl ->
        if T.null k
          then mal kkp "a control clause names its continuation"
          else do
            requireName
            aps <- mapM patAtom pats
            Abs.HUArm (mkVarId np nm) (aps ++ [Abs.APVar (mkVarId kkp k)])
              <$> mapExpr body
    | kind == clauseReturn ->
        case (T.null nm, T.null k, pats) of
          (True, True, [p]) -> case (gTag p, gFields p) of
            ("P_Var", [FldName v vp]) ->
              Abs.HUArm (mkVarId vp v) [] <$> mapExpr body
            _ -> do
              notDamaged p
              gap n "pattern-return-clause" "v1's value arm binds a bare variable; a pattern return clause has no v1 form"
          (True, True, _) -> mal (gPos n) "a return clause carries exactly one pattern"
          _ -> mal (gPos n) "a return clause names no operation and no continuation"
    | kind == clauseVar ->
        case (pats, T.null k) of
          ([], True) -> do
            requireName
            Abs.HParamV (mkVarId np nm) <$> mapExpr body
          _ -> mal (gPos n) "a var clause carries no patterns and no continuation"
    | kind == clauseAbort ->
        gap n "abort-clause" "v1 has no `abort` clause; never-resume is spelled by an explicit continuation binder that is dropped"
    | otherwise -> mal kp "H_Clause kind out of range"
    where
      requireName =
        if T.null nm
          then mal np "this clause kind names its operation"
          else Right ()
  _ -> unmappable n "a handler clause"

-- Blocks ---------------------------------------------------------------------

-- D11: a block is a statement sequence whose value is its final
-- expression. v1 has no block node; what maps is a chain of `let`
-- statements around that final expression, as nested ELet scopes.
-- Following D26, adjacent FUNCTION-equation lets are grouped into one
-- ELet so their mutual recursion survives; value lets nest one by one so
-- their sequential (rebinding) scope survives. Everything else a block
-- can hold -- handle/use statements, discarded expressions -- has no v1
-- spelling and gaps.
mapBlock :: Pos -> [GNode] -> Either SurfaceError Abs.Exp
mapBlock herePos stmts = case splitLast stmts of
  Nothing -> mal herePos "an empty block has no value"
  Just (initial, lastStmt) -> do
    final <-
      if gFamily lastStmt == FamExpr
        then mapExpr lastStmt
        else do
          notDamaged lastStmt
          gap lastStmt "block-without-final-expr" "v1 can only mean a block that ends in an expression"
    buildBlock initial final

splitLast :: [a] -> Maybe ([a], a)
splitLast xs = case xs of
  [] -> Nothing
  (y : ys) -> case splitLast ys of
    Nothing -> Just ([], y)
    Just (front, lst) -> Just (y : front, lst)

buildBlock :: [GNode] -> Abs.Exp -> Either SurfaceError Abs.Exp
buildBlock stmts final = case stmts of
  [] -> Right final
  (s : rest) -> case stmtLetBind s of
    Just bind
      | isFunEqBind bind ->
          let (run, remainder) = span isFunEqLet (s : rest)
          in do
               binds <- mapM letBindOf run
               lds <- mapM bindLocalDecl binds
               Abs.ELet lds <$> buildBlock remainder final
      | otherwise -> do
          ld <- bindLocalDecl bind
          Abs.ELet [ld] <$> buildBlock rest final
    Nothing -> do
      notDamaged s
      case gTag s of
        "S_Handle" -> gap s "statement-handle" "v1 has no statement-form handler install; every v1 with-form is a delimited expression"
        "S_Use" -> gap s "statement-use" "v1 has no `use x as label` rebind form"
        "S_Discard" -> gap s "statement-discard" "v1 cannot sequence a discarded expression"
        _ -> gapAt (gPos s) "E_Block" "mid-block-expression" "v1 cannot sequence an expression statement inside a block"
  where
    isFunEqLet x = maybe False isFunEqBind (stmtLetBind x)
    letBindOf x = case stmtLetBind x of
      Just b -> Right b
      Nothing -> mal (gPos x) "expected a let statement"

stmtLetBind :: GNode -> Maybe GNode
stmtLetBind n = case (gTag n, gFields n) of
  ("S_Let", [FldNode b]) -> Just b
  _ -> Nothing

-- A binding with parameters is a (recursive) function equation (D26).
isFunEqBind :: GNode -> Bool
isFunEqBind n = case (gTag n, gFields n) of
  ("H_Bind", [FldNode lhs, FldNode _]) -> case (gTag lhs, gFields lhs) of
    ("L_Prefix", [FldName _ _, FldFlag _ _, FldSeq args]) -> not (null args)
    ("L_Infix", _) -> True
    _ -> False
  _ -> False

bindLocalDecl :: GNode -> Either SurfaceError Abs.LocalDecl
bindLocalDecl n = case (gTag n, gFields n) of
  ("H_Bind", [FldNode lhs, FldNode rhs]) -> do
    e <- mapExpr rhs
    case (gTag lhs, gFields lhs) of
      ("L_Prefix", _) -> do
        l <- mapFunLHS lhs
        Right (Abs.LDEqn l e Abs.NoWhere)
      ("L_Infix", _) -> do
        l <- mapFunLHS lhs
        Right (Abs.LDEqn l e Abs.NoWhere)
      ("P_Var", [FldName t p]) ->
        Right (Abs.LDEqn (Abs.LHSPre (Abs.FNBare (mkVarId p t)) []) e Abs.NoWhere)
      ("P_Tuple", [FldSeq items]) -> case items of
        (i1 : i2 : rest) -> do
          p1 <- mapPat i1
          ps <- mapM mapPat (i2 : rest)
          Right (Abs.LDPat p1 ps e)
        _ -> mal (gPos lhs) "a tuple pattern needs at least two components"
      _ -> do
        notDamaged lhs
        gap n "refutable-let-binding" "v1 binds only equations, plain variables, and tuple destructuring"
  _ -> unmappable n "a binding"

-- ---------------------------------------------------------------------
-- Literal lexeme decoding (spec D5)
-- ---------------------------------------------------------------------

strLexemeAt :: Pos -> Text -> Either SurfaceError String
strLexemeAt p raw = case decodeStringLexeme raw of
  Right s -> Right s
  Left msg -> Left (MalformedDump p msg)

charLexemeAt :: Pos -> Text -> Either SurfaceError Char
charLexemeAt p raw = case decodeCharLexeme raw of
  Right c -> Right c
  Left msg -> Left (MalformedDump p msg)

-- | Decode a raw wok string lexeme -- the SOURCE spelling, quotes
-- included -- into its value. The escape set is exactly the one the C
-- lexer accepts (grammar\/c\/wok_token.c, @scan_literal@):
-- @\\\\ \\\" \\' \\n \\t \\r \\0@ and @\\xHH@ with exactly two hex digits.
decodeStringLexeme :: Text -> Either Text String
decodeStringLexeme raw = do
  body <- stripDelims '"' "string" raw
  decodeEscapes '"' body

-- | Decode a raw wok character lexeme (e.g. @'a'@, @'\\n'@) into its
-- single character.
decodeCharLexeme :: Text -> Either Text Char
decodeCharLexeme raw = do
  body <- stripDelims '\'' "character" raw
  s <- decodeEscapes '\'' body
  case s of
    [c] -> Right c
    _ -> Left (T.pack "a character literal must hold exactly one character")

stripDelims :: Char -> String -> Text -> Either Text String
stripDelims q what raw = case T.uncons raw of
  Just (c0, rest) | c0 == q -> case T.unsnoc rest of
    Just (mid, cN) | cN == q -> Right (T.unpack mid)
    _ -> badDelims
  _ -> badDelims
  where
    badDelims =
      Left (T.pack ("a " ++ what ++ " lexeme must be delimited by " ++ [q]))

decodeEscapes :: Char -> String -> Either Text String
decodeEscapes q = go
  where
    go s = case s of
      [] -> Right []
      ('\\' : rest) -> case rest of
        [] -> Left (T.pack "dangling backslash at the end of a literal")
        ('x' : more) -> case more of
          (h1 : h2 : after) -> case (hexVal h1, hexVal h2) of
            (Just a, Just b) -> (chr (a * 16 + b) :) <$> go after
            _ -> hexErr
          _ -> hexErr
        (e : after) -> case lookup e escapeTable of
          Just decoded -> (decoded :) <$> go after
          Nothing -> Left (T.pack ("unknown escape `\\" ++ [e] ++ "` in a literal"))
      (c : rest)
        | c == q -> Left (T.pack "unescaped delimiter inside a literal")
        | c == '\n' -> Left (T.pack "a literal cannot span lines")
        | otherwise -> (c :) <$> go rest
    hexErr = Left (T.pack "`\\x` needs exactly two hex digits")

escapeTable :: [(Char, Char)]
escapeTable =
  [ ('\\', '\\')
  , ('"', '"')
  , ('\'', '\'')
  , ('n', '\n')
  , ('t', '\t')
  , ('r', '\r')
  , ('0', '\NUL')
  ]
