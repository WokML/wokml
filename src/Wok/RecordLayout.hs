-- | Pre-pass: insert virtual commas inside record @{ ... }@ blocks when
-- fields are newline-separated instead of comma-separated.
--
-- This pre-pass runs BEFORE BNFC's @resolveLayout@ so that BNFC's layout
-- filter never sees the record-specific indentation rules.
--
-- Strategy: walk the token stream tracking a brace-context stack.  Each
-- record-context @{@ (i.e., one that follows a @ConId@, @=@, or @+@)
-- checks whether the first non-comment token after it is on a different
-- line.  If so, the brace is "block mode" and subsequent tokens that start
-- a new line get a virtual @,@ inserted before them (unless one is already
-- present).  Non-record braces and inline record braces pass through
-- unchanged.
module Wok.RecordLayout
  ( insertRecordVirtualCommas
  ) where

import qualified Data.Text as T

import GeneratedParser.Wok.Lex
  ( Posn(..), Tok(..), Token(..), TokSymbol(..)
  , tokenPosn
  )
import GeneratedParser.Wok.Layout (nextPos)

-- ---------------------------------------------------------------------------
-- Token helpers
-- ---------------------------------------------------------------------------

tokenLine :: Token -> Int
tokenLine t = case tokenPosn t of Pn _ l _ -> l

-- | Make a synthetic comma token at a given position.
virtualComma :: Posn -> Token
virtualComma p = PT p (TK (TokSymbol (T.pack ",") 3))

-- | Make a synthetic comma token positioned just after a given token.
commaAfter :: Token -> Token
commaAfter t = virtualComma (nextPos t)

-- | Is this token a @{@?
isLBrace :: Token -> Bool
isLBrace (PT _ (TK (TokSymbol _ 44))) = True
isLBrace _                            = False

-- | Is this token a @}@?
isRBrace :: Token -> Bool
isRBrace (PT _ (TK (TokSymbol _ 46))) = True
isRBrace _                            = False

-- | Is this token a @,@?
isComma :: Token -> Bool
isComma (PT _ (TK (TokSymbol _ 3))) = True
isComma _                           = False

-- | Is this token a @ConId@?
isConId :: Token -> Bool
isConId (PT _ (T_ConId _)) = True
isConId _                  = False

-- | Is this token @=@?
isEquals :: Token -> Bool
isEquals (PT _ (TK (TokSymbol _ 10))) = True
isEquals _                            = False

-- | Is this token the VarSym @+@?
isPlusSym :: Token -> Bool
isPlusSym (PT _ (T_VarSym t)) = t == T.pack "+"
isPlusSym _                   = False

-- | Does this token qualify as a lookbehind trigger for a record brace?
-- Record braces follow: ConId, =, or the VarSym +.
isRecordBraceTrigger :: Token -> Bool
isRecordBraceTrigger t = isConId t || isEquals t || isPlusSym t

-- ---------------------------------------------------------------------------
-- Brace context stack
-- ---------------------------------------------------------------------------

-- | Context pushed onto the stack for every @{@ we encounter.
data BraceCtx
  = -- | Block-mode record brace: the first token after @{@ was on a new line.
    -- We track the line of @{@ so we can insert commas at newlines.
    BlockBrace
      { bcOpenLine :: !Int
        -- ^ Line of the @{@ token itself.
      , bcLastLine :: !Int
        -- ^ Line of the last token we emitted inside this brace.
      }
  | -- | Inline record brace or non-record brace: pass through unchanged.
    OtherBrace
  deriving (Show)

-- ---------------------------------------------------------------------------
-- Main function
-- ---------------------------------------------------------------------------

-- | Insert virtual @,@ tokens in block-form record literals.
insertRecordVirtualCommas :: [Token] -> [Token]
insertRecordVirtualCommas toks = go Nothing [] toks
  where
  -- go prevToken stack remaining
  go :: Maybe Token -> [BraceCtx] -> [Token] -> [Token]
  go _ _ [] = []

  go prev stack (t : ts)
    -- Closing brace: pop the stack.
    | isRBrace t =
        case stack of
          []        -> t : go (Just t) []    ts
          _ : rest  -> t : go (Just t) rest  ts

    -- Opening brace.
    | isLBrace t =
        let isRecord = case prev of
              Just p  -> isRecordBraceTrigger p
              Nothing -> False
        in if isRecord
           then
             -- Peek at the next token to decide block vs inline.
             case ts of
               [] ->
                 -- Empty brace body: inline.
                 t : go (Just t) (OtherBrace : stack) ts
               (next : _) ->
                 if tokenLine next > tokenLine t
                 then
                   -- Block mode: first field is on next line.
                   let ctx = BlockBrace (tokenLine t) (tokenLine t)
                   in t : go (Just t) (ctx : stack) ts
                 else
                   -- Inline mode.
                   t : go (Just t) (OtherBrace : stack) ts
           else
             -- Non-record brace: push OtherBrace, no special handling.
             t : go (Just t) (OtherBrace : stack) ts

    -- Any other token: maybe insert a virtual comma.
    | otherwise =
        case stack of
          BlockBrace openLine lastLine : rest ->
            let curLine = tokenLine t
            in if curLine > lastLine && lastLine > openLine && not (isComma t)
               then
                 -- New line inside a block record, and we have already seen at
                 -- least one field (lastLine > openLine).  Insert a virtual
                 -- comma before this token (positioned just after the prev
                 -- token).
                 let comma = case prev of
                               Just p  -> commaAfter p
                               Nothing -> virtualComma (Pn 0 curLine 1)
                     newCtx = BlockBrace openLine curLine
                 in comma : t : go (Just t) (newCtx : rest) ts
               else
                 -- Either same line, first field (lastLine == openLine), or
                 -- already a comma: just update lastLine.
                 let newCtx = BlockBrace openLine curLine
                 in t : go (Just t) (newCtx : rest) ts
          _ ->
            t : go (Just t) stack ts
