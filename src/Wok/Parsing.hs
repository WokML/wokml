-- | Front-end facade: lex, apply the layout filter, and parse Wok source.
module Wok.Parsing
  ( parse
  ) where

import Data.Text (Text)
import GeneratedParser.Wok.Abs (Module)
import qualified GeneratedParser.Wok.Layout as Layout
import qualified GeneratedParser.Wok.Lex as L
import qualified GeneratedParser.Wok.Par as P
import Wok.RecordLayout (insertRecordVirtualCommas)

-- | Parse Wok source text into a 'Module'.
--
-- This is the whole front-end pipeline in one step: lexing, the
-- indentation/layout filter, then the parser. A 'Left' carries the
-- parser's error message.
--
-- The pipeline has three stages:
--
-- 1. 'L.tokens': lex the source into a raw token stream.
-- 2. 'insertRecordVirtualCommas': pre-pass that inserts virtual @,@ tokens
--    in block-form record literals (multiline @{ ... }@ after a ConId, @=@,
--    or @+@), before BNFC's layout filter sees the stream.
-- 3. 'Layout.resolveLayout': BNFC's indentation filter for @let@/@where@/@of@.
-- 4. 'P.pModule': the generated LALR parser.
parse :: Text -> Either String Module
parse = P.pModule . Layout.resolveLayout True . insertRecordVirtualCommas . L.tokens
