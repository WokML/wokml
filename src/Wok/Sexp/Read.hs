-- | Strict datum reader for the grammar/c s-expression dump dialect.
--
-- This module knows nothing about the wok AST schema (that is
-- "Wok.Sexp.Surface"'s job). It produces a generic, schema-agnostic datum
-- tree -- a WORD, a STRING, or a LIST of datums -- with exactly the lexical
-- strictness of the reference reader (grammar/c/wok_sexpr.c, from
-- @wok_sexpr_read@ down):
--
--   * delimiters are @(@ @)@ @"@ and ASCII whitespace (space, tab, CR,
--     LF); everything else accumulates into a WORD verbatim, so @#t@,
--     @#f@, @seq@, @some@, @none@, decimal integers, and every tag name
--     are all just words at this layer -- interpreting them is Surface's
--     job;
--   * strings are opened and closed by @"@; the escape set is EXACTLY
--     @\\\\ \\\" \\n \\t \\r@ and @\\xHH@ (two hex digits) -- any other
--     escape is a hard error, matching @read_string_lit@;
--   * lists are @(@ datum* @)@; an unterminated list or a stray @)@ with
--     no open list is an error;
--   * NODE nesting deeper than 256 levels is an error, matching
--     @WOK_SEXPR_MAX_DEPTH@ exactly: as in the C reader, the structural
--     wrapper lists @(seq ...)@\/@(some X)@\/@(none)@ are
--     depth-transparent (C's @parse_opt@\/@parse_seq@ run at the parent
--     node's depth and hand @depth + 1@ straight to their child nodes),
--     and words\/strings are leaves that never consume a level;
--   * bytes >= 0x80 (multi-byte UTF-8 content) pass through raw, both in
--     words and inside strings, since 'Text' already carries decoded
--     Unicode code points.
--
-- The dump carries no source positions of its own (wok_sexpr.h:16-18), so
-- 'Pos' points into the .sexp dump text itself, not into any original .wok
-- source -- this is what D4 of the sexp-ingestion-oracle spec calls for.
module Wok.Sexp.Read
  ( SExp (..)
  , Pos (..)
  , SexpError (..)
  , readSExp
  , hexVal
  ) where

import Data.Char (chr, isDigit)
import Data.Text (Text)
import qualified Data.Text as T

-- | A 1-based line/column position in the input text.
data Pos = Pos
  { posLine :: Int
  , posCol  :: Int
  } deriving (Eq, Show)

-- | A generic s-expression datum. Each constructor carries the position of
-- its first character: the first character of a word, the opening quote of
-- a string, or the opening parenthesis of a list. String content is the
-- already-decoded value (escapes processed); a word is stored verbatim.
data SExp
  = SWord Text Pos
  | SString Text Pos
  | SList [SExp] Pos
  deriving (Eq, Show)

-- | A reader error: the position it was found at, and a description.
data SexpError = SexpError
  { sexpErrorPos     :: Pos
  , sexpErrorMessage :: Text
  } deriving (Eq, Show)

-- | The reader's cursor: the text not yet consumed, and the position of
-- its first character (if any).
data RState = RState Text Pos

rsPos :: RState -> Pos
rsPos (RState _ p) = p

-- | Matches @WOK_SEXPR_MAX_DEPTH@ in wok_sexpr.c: a chain of this many
-- nested lists is accepted, one more is rejected.
maxDepth :: Int
maxDepth = 256

-- | Parse exactly one datum from 'Text', then require only whitespace to
-- the end of input (the dump is a single @W_File@ root datum).
readSExp :: Text -> Either SexpError SExp
readSExp input =
  case parseDatum 1 (RState input (Pos 1 1)) of
    Left err -> Left err
    Right (datum, afterDatum) ->
      let afterWs = skipWs afterDatum
      in case peekChar afterWs of
           Nothing -> Right datum
           Just _  -> Left (SexpError (rsPos afterWs) trailingMsg)
  where
    trailingMsg = T.pack "trailing content after the top-level form"

-- | Advance the cursor past one character, tracking line/col: a newline
-- starts a new line at column 1, anything else advances the column.
uncons1 :: RState -> Maybe (Char, RState)
uncons1 (RState t p) = case T.uncons t of
  Nothing      -> Nothing
  Just (c, t') -> Just (c, RState t' (advancePos c p))

advancePos :: Char -> Pos -> Pos
advancePos '\n' (Pos l _) = Pos (l + 1) 1
advancePos _    (Pos l c) = Pos l (c + 1)

peekChar :: RState -> Maybe Char
peekChar (RState t _) = fmap fst (T.uncons t)

isWs :: Char -> Bool
isWs c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

isDelim :: Char -> Bool
isDelim c = c == '(' || c == ')' || c == '"' || isWs c

skipWs :: RState -> RState
skipWs st = case peekChar st of
  Just c | isWs c -> case uncons1 st of
    Just (_, st') -> skipWs st'
    Nothing       -> st
  _ -> st

-- | Parse one datum at the given NODE-nesting depth. Words and strings
-- are leaves and never grow the depth; a list grows it (and is checked
-- against 'maxDepth') only when it is a real node list, not one of the
-- three depth-transparent wrappers -- see 'parseList'.
parseDatum :: Int -> RState -> Either SexpError (SExp, RState)
parseDatum depth st0 =
  let st1 = skipWs st0
  in case peekChar st1 of
       Nothing  -> Left (SexpError (rsPos st1) noDatumMsg)
       Just '(' -> parseList depth st1
       Just '"' -> parseStringLit st1
       Just ')' -> Left (SexpError (rsPos st1) strayCloseMsg)
       Just _   -> Right (parseWord st1)
  where
    noDatumMsg    = T.pack "unexpected end of input, expected a datum"
    strayCloseMsg = T.pack "unexpected `)` with no matching `(`"

-- | A maximal run of non-delimiter characters. The caller only invokes
-- this when the next character is known to be present and not a
-- delimiter, so the resulting word is always non-empty.
parseWord :: RState -> (SExp, RState)
parseWord st = (SWord wordText startPos, st')
  where
    startPos = rsPos st
    (wordText, st') = takeWord st []

    takeWord s acc = case peekChar s of
      Just c | not (isDelim c) -> case uncons1 s of
        Just (c', s') -> takeWord s' (c' : acc)
        Nothing       -> (T.pack (reverse acc), s)
      _ -> (T.pack (reverse acc), s)

-- | Parse a list. The depth accounting mirrors the C reader EXACTLY: a
-- list headed by one of the dialect's three structural wrapper words
-- (@seq@\/@some@\/@none@) is depth-TRANSPARENT -- in C those wrappers are
-- schema plumbing, not nodes (@parse_opt@\/@parse_seq@ are entered at the
-- parent node's depth and call @parse_node(depth + 1)@ for their
-- children), so the wrapper itself is never depth-checked and its
-- children parse at the depth the wrapper was reached at. Every other
-- list is a node list: checked against 'maxDepth' BEFORE recursing into
-- any child (so a pathological deep nest cannot recurse unboundedly),
-- children one level deeper, matching @parse_node@'s entry guard.
parseList :: Int -> RState -> Either SexpError (SExp, RState)
parseList depth st = case uncons1 st of
  Nothing       -> Left (SexpError openPos unterminatedMsg)
  Just (_, st1) ->
    let s1 = skipWs st1
    in case peekChar s1 of
         Just c | not (isDelim c) ->
           case parseWord s1 of
             (headDatum@(SWord w _), s2)
               | isWrapperHead w -> loop depth s2 [headDatum]
               | otherwise       -> nodeLoop s2 [headDatum]
             (headDatum, s2)     -> nodeLoop s2 [headDatum]
         _ -> nodeLoop s1 []
  where
    openPos = rsPos st
    depthMsg =
      T.pack ("s-expression nesting exceeds " ++ show maxDepth ++ " levels")
    unterminatedMsg = T.pack "unterminated list: missing `)`"

    isWrapperHead w = w == T.pack "seq" || w == T.pack "some" || w == T.pack "none"

    nodeLoop s acc
      | depth > maxDepth = Left (SexpError openPos depthMsg)
      | otherwise        = loop (depth + 1) s acc

    loop childDepth s acc =
      let s1 = skipWs s
      in case peekChar s1 of
           Nothing  -> Left (SexpError openPos unterminatedMsg)
           Just ')' -> case uncons1 s1 of
             Just (_, s2) -> Right (SList (reverse acc) openPos, s2)
             Nothing      -> Left (SexpError openPos unterminatedMsg)
           Just _   -> case parseDatum childDepth s1 of
             Left err      -> Left err
             Right (d, s2) -> loop childDepth s2 (d : acc)

parseStringLit :: RState -> Either SexpError (SExp, RState)
parseStringLit st = case uncons1 st of
  Nothing       -> Left (SexpError openPos unterminatedMsg)
  Just (_, st1) -> loop st1 []
  where
    openPos = rsPos st
    unterminatedMsg = T.pack "unterminated string literal"
    unterminatedXMsg = T.pack "unterminated \\x escape in string literal"
    invalidXMsg = T.pack "invalid \\x escape in string literal"

    loop s acc = case peekChar s of
      Nothing  -> Left (SexpError openPos unterminatedMsg)
      Just '"' -> case uncons1 s of
        Just (_, s') -> Right (SString (T.pack (reverse acc)) openPos, s')
        Nothing      -> Left (SexpError openPos unterminatedMsg)
      Just '\\' -> case uncons1 s of
        Nothing      -> Left (SexpError openPos unterminatedMsg)
        Just (_, s1) -> readEscape s1 acc
      Just c -> case uncons1 s of
        Just (_, s') -> loop s' (c : acc)
        Nothing      -> Left (SexpError openPos unterminatedMsg)

    -- 's1' is positioned at the escape character itself (not yet
    -- consumed), matching where the C reader reports an unknown escape.
    readEscape s1 acc = case peekChar s1 of
      Nothing -> Left (SexpError openPos unterminatedMsg)
      Just e -> case e of
        '\\'  -> consumeEscape s1 '\\' acc
        '"'   -> consumeEscape s1 '"' acc
        'n'   -> consumeEscape s1 '\n' acc
        't'   -> consumeEscape s1 '\t' acc
        'r'   -> consumeEscape s1 '\r' acc
        'x'   -> readHexEscape s1 acc
        other -> Left (SexpError (rsPos s1) (unknownEscapeMsg other))

    unknownEscapeMsg c =
      T.pack ("unknown escape `\\" ++ [c] ++ "` in string literal")

    consumeEscape s1 decoded acc = case uncons1 s1 of
      Just (_, s2) -> loop s2 (decoded : acc)
      Nothing      -> Left (SexpError openPos unterminatedMsg)

    -- 's1' is positioned at 'x' (not yet consumed).
    readHexEscape s1 acc = case uncons1 s1 of
      Nothing -> Left (SexpError openPos unterminatedMsg)
      Just (_, sAfterX) -> case uncons1 sAfterX of
        Nothing -> Left (SexpError openPos unterminatedXMsg)
        Just (hi, sAfterHi) -> case uncons1 sAfterHi of
          Nothing -> Left (SexpError openPos unterminatedXMsg)
          Just (lo, sAfterLo) ->
            case (hexVal hi, hexVal lo) of
              (Just hiV, Just loV) ->
                loop sAfterLo (chr (hiV * 16 + loV) : acc)
              _ -> Left (SexpError (rsPos sAfterX) invalidXMsg)

-- | Decode a single hex digit. Shared with "Wok.Sexp.Surface", which
-- decodes the same @\\xHH@ escape inside string\/char literal lexemes and
-- would otherwise duplicate this exact case analysis.
hexVal :: Char -> Maybe Int
hexVal c
  | isDigit c            = Just (fromEnum c - fromEnum '0')
  | c >= 'a' && c <= 'f' = Just (fromEnum c - fromEnum 'a' + 10)
  | c >= 'A' && c <= 'F' = Just (fromEnum c - fromEnum 'A' + 10)
  | otherwise            = Nothing
