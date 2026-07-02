-- | Pre-pass: insert virtual separators inside brace @{ ... }@ blocks when
-- entries are newline-separated instead of explicitly separated. Two kinds of
-- brace get this treatment, with DIFFERENT separators:
--
--   * record literals (@Point { x = 1, y = 2 }@) -- virtual @,@; and
--   * effect-handler blocks (@with H { op -> e ; v -> e }@) -- virtual @;@,
--     matching the @separator HandlerArm ";"@ in the grammar.
--
-- This pre-pass runs BEFORE BNFC's @resolveLayout@ so that BNFC's layout
-- filter never sees the brace-specific indentation rules.
--
-- Strategy: walk the token stream tracking a brace-context stack. Each
-- record-context @{@ (one that follows a @ConId@, @=@, or @+@) checks whether
-- the first token after it is on a different line. If so, the brace is "block
-- mode" and subsequent tokens that start a new line get a virtual separator
-- inserted before them (unless one is already present). The separator is @;@
-- when the brace is a HANDLER brace -- a @{@ governed by a @with@ keyword, which
-- a short backward walk from the @{@ over its prefix detects (the three handler
-- forms are @with {@, @with ConId... {@, and @with VarId = ConId {@) -- and @,@
-- otherwise. A type-level @with@ (in @T -> R with E@) never governs a nearby
-- @{@, so it is not misclassified: the decision is made from the brace's own
-- immediate prefix, not a global flag. Non-record braces and inline (single-
-- line) braces pass through unchanged.
module Wok.RecordLayout
  ( insertRecordVirtualCommas
  ) where

import qualified Data.Text as T

import GeneratedParser.Wok.Lex
  ( Posn(..), Tok(..), Token(..), TokSymbol(..)
  , tokenPosn, eitherResIdent
  )
import GeneratedParser.Wok.Layout (nextPos)

-- ---------------------------------------------------------------------------
-- Token helpers
-- ---------------------------------------------------------------------------

tokenLine :: Token -> Int
tokenLine t = case tokenPosn t of Pn _ l _ -> l

tokenCol :: Token -> Int
tokenCol t = case tokenPosn t of Pn _ _ c -> c

-- | The reserved-symbol token for @,@.
--
-- The Happy parser matches symbol tokens by their numeric @tsID@ (its @TokSymbol@
-- @Eq@/@Ord@ compare on @tsID@ alone, ignoring the text), so a synthetic comma
-- MUST carry the same id the lexer assigns @,@. We look that id up in the
-- lexer's own reserved-word table via @eitherResIdent@ rather than hardcoding
-- it, so it tracks any BNFC renumbering on regen. (@,@ is always a reserved
-- symbol, so the identifier fallback below is never taken.)
commaTok :: Tok
commaTok = eitherResIdent
  (\_ -> error "RecordLayout: ',' missing from the lexer's reserved-symbol table")
  (T.pack ",")

-- | The reserved-symbol token for @;@ (handler-arm separator). Looked up the
-- same regen-proof way as 'commaTok'.
semiTok :: Tok
semiTok = eitherResIdent
  (\_ -> error "RecordLayout: ';' missing from the lexer's reserved-symbol table")
  (T.pack ";")

-- | Make a synthetic separator token of a given 'Tok' just after a token.
sepAfter :: Tok -> Token -> Token
sepAfter sep t = PT (nextPos t) sep

-- Symbol tokens are matched by their TEXT, not by their BNFC-assigned
-- numeric @tsID@. The IDs are alphabetical positions in the reserved-word
-- table and shift whenever the grammar adds a token (e.g. the v1 effect
-- grammar inserted @..@, renumbering @=@ 9->10, @{@ 43->52, @}@ 45->54).
-- Matching on text is regen-proof.

-- | Is this token a @{@?
isLBrace :: Token -> Bool
isLBrace (PT _ (TK (TokSymbol t _))) = t == T.pack "{"
isLBrace _               = False

-- | Is this token a @}@?
isRBrace :: Token -> Bool
isRBrace (PT _ (TK (TokSymbol t _))) = t == T.pack "}"
isRBrace _               = False

-- | Is this token a @,@?
isComma :: Token -> Bool
isComma (PT _ (TK (TokSymbol t _))) = t == T.pack ","
isComma _               = False

-- | Is this token a @;@?
isSemi :: Token -> Bool
isSemi (PT _ (TK (TokSymbol t _))) = t == T.pack ";"
isSemi _               = False

-- | Is this token a @ConId@?
isConId :: Token -> Bool
isConId (PT _ (T_ConId _)) = True
isConId _                  = False

-- | Is this token a @VarId@?
isVarId :: Token -> Bool
isVarId (PT _ (T_VarId _)) = True
isVarId _                  = False

-- | Is this token @=@?
isEquals :: Token -> Bool
isEquals (PT _ (TK (TokSymbol t _))) = t == T.pack "="
isEquals _               = False

-- | Is this token the @with@ keyword? (A reserved word, so it lexes to a
-- 'TokSymbol' like the punctuation does.)
isWithKw :: Token -> Bool
isWithKw (PT _ (TK (TokSymbol t _))) = t == T.pack "with"
isWithKw _               = False

-- | Is this token the VarSym @+@?
isPlusSym :: Token -> Bool
isPlusSym (PT _ (T_VarSym t)) = t == T.pack "+"
isPlusSym _                   = False

-- | Does this token qualify as a lookbehind trigger for a record brace?
-- Record braces follow: ConId, =, or the VarSym +.
isRecordBraceTrigger :: Token -> Bool
isRecordBraceTrigger t = isConId t || isEquals t || isPlusSym t

-- | Is the @{@ whose immediate token prefix is given (most-recent token FIRST)
-- an effect-HANDLER brace rather than a record literal? A handler brace is one
-- governed by a @with@ keyword, in one of the grammar's three inline-handler
-- forms (Wok.cf EWith / EWithH / EWithNamedH):
--
--   * @with {@                  -- @with@ sits immediately before the @{@;
--   * @with ConId [ConId] {@    -- a @with@ precedes a run of effect ConIds;
--   * @with VarId = ConId {@    -- a named instance binds a ConId handler block.
--
-- The walk drops the leading ConId run (the effect header / the named ConId)
-- and then checks for the @with@ keyword directly, or for the @= VarId with@
-- tail of the named form. Because only the brace's own prefix is inspected, a
-- type-level @with@ in a signature (@T -> R with E@) -- whose effect row is not
-- followed by a @{@ -- never reaches this test for an unrelated later brace.
isHandlerBrace :: [Token] -> Bool
isHandlerBrace revPrefix = case revPrefix of
  (p : _) | isWithKw p -> True                    -- with {
  _ -> case dropWhile isConId revPrefix of
         (w : _)          | isWithKw w -> True     -- with ConId... {
         (eq : v : w : _)                          -- with VarId = ConId {
           | isEquals eq && isVarId v && isWithKw w -> True
         _ -> False

-- ---------------------------------------------------------------------------
-- Brace context stack
-- ---------------------------------------------------------------------------

-- | Context pushed onto the stack for every @{@ we encounter.
data BraceCtx
  = -- | Block-mode brace: the first token after @{@ was on a new line. We track
    -- the line of @{@ so we can insert separators at newlines, and whether this
    -- is a handler brace (separator @;@) or a record brace (separator @,@).
    BlockBrace
      { bcOpenLine :: Int
        -- ^ Line of the @{@ token itself.
      , bcLastLine :: Int
        -- ^ Line of the last token we emitted inside this brace.
      , bcRefCol :: Int
        -- ^ Column of the first arm token (the arm-start reference column). For
        -- a handler brace, a new line whose leading token is at-or-left-of this
        -- column starts a new arm (insert a separator); a strictly deeper line
        -- continues the current arm's body (no separator). Record braces ignore
        -- this and keep the line-only behaviour.
      , bcIsHandler :: Bool
        -- ^ True => handler brace (insert @;@); False => record brace (@,@).
      }
  | -- | Inline brace or non-brace-layout brace: pass through unchanged.
    OtherBrace
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Main function
-- ---------------------------------------------------------------------------

-- | Insert virtual separators (@,@ for records, @;@ for handler blocks) in
-- block-form braces.
insertRecordVirtualCommas :: [Token] -> [Token]
insertRecordVirtualCommas toks = go [] [] toks
  where
  -- go revPrefix stack remaining
  --   revPrefix: the REAL tokens already consumed, most-recent FIRST (synthetic
  --   separators are never recorded here, so brace classification sees only the
  --   source token stream).
  go :: [Token] -> [BraceCtx] -> [Token] -> [Token]
  go _ _ [] = []

  go prefix stack (t : ts)
    -- Closing brace: pop the stack.
    | isRBrace t =
        case stack of
          []        -> t : go (t : prefix) []    ts
          _ : rest  -> t : go (t : prefix) rest  ts

    -- Opening brace.
    | isLBrace t =
        let isHandler = isHandlerBrace prefix
            isRecord  = case prefix of
              (p : _) -> isRecordBraceTrigger p
              []      -> False
        in if isHandler || isRecord
           then
             -- Peek at the next token to decide block vs inline.
             case ts of
               [] ->
                 -- Empty brace body: inline.
                 t : go (t : prefix) (OtherBrace : stack) ts
               (next : _) ->
                 if tokenLine next > tokenLine t
                 then
                   -- Block mode: first entry is on the next line. The first
                   -- entry token's column is the arm-start reference column.
                   let ctx = BlockBrace (tokenLine t) (tokenLine t) (tokenCol next) isHandler
                   in t : go (t : prefix) (ctx : stack) ts
                 else
                   -- Inline mode.
                   t : go (t : prefix) (OtherBrace : stack) ts
           else
             -- Non-layout brace: push OtherBrace, no special handling.
             t : go (t : prefix) (OtherBrace : stack) ts

    -- Any other token: maybe insert a virtual separator.
    | otherwise =
        case stack of
          BlockBrace openLine lastLine refCol isHandler : rest ->
            let curLine = tokenLine t
                isSepTok  = if isHandler then isSemi  else isComma
                sepTokFor = if isHandler then semiTok else commaTok
                prevIsSep = case prefix of
                  (p : _) -> isSepTok p
                  []      -> False
                -- Handler braces are indentation-sensitive: a new line whose
                -- leading token is strictly deeper than the arm reference column
                -- is a continuation of the current arm's body, NOT a new arm, so
                -- it gets no separator. Record braces keep the line-only rule.
                startsNewEntry = not isHandler || tokenCol t <= refCol
                -- Advancing @lastLine@ to the current token's line; identical in
                -- both branches, so bound once here.
                newCtx = BlockBrace openLine curLine refCol isHandler
            in if curLine > lastLine && lastLine > openLine
                  && not (isSepTok t) && not prevIsSep
                  && startsNewEntry
               then
                 -- New line inside a block brace, and we have already seen at
                 -- least one entry (lastLine > openLine), with no literal
                 -- separator already terminating the previous line. Insert a
                 -- virtual separator before this token (positioned just after
                 -- the previous real token): @,@ for records, @;@ for handlers.
                 let sep = case prefix of
                               (p : _) -> sepAfter sepTokFor p
                               []      -> PT (Pn 0 curLine 1) sepTokFor
                 in sep : t : go (t : prefix) (newCtx : rest) ts
               else
                 -- Either same line, first entry (lastLine == openLine), the
                 -- current token is a separator, a body continuation (deeper than
                 -- the arm column), or the previous token already was a separator:
                 -- just advance lastLine.
                 t : go (t : prefix) (newCtx : rest) ts
          _ ->
            t : go (t : prefix) stack ts
