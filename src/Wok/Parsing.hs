-- | Front-end facade: lex, apply the layout filter, and parse Wok source.
module Wok.Parsing
  ( parse
  ) where

import Data.Text (Text)
import GeneratedParser.Wok.Abs (Module)
import qualified GeneratedParser.Wok.Layout as Layout
import qualified GeneratedParser.Wok.Lex as L
import qualified GeneratedParser.Wok.Par as P

-- | Parse Wok source text into a 'Module'.
--
-- This is the whole front-end pipeline in one step: lexing, the
-- indentation/layout filter, then the parser. A 'Left' carries the
-- parser's error message.
parse :: Text -> Either String Module
parse = P.pModule . Layout.resolveLayout True . L.tokens
