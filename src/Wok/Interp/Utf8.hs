module Wok.Interp.Utf8
  ( utf8Width
  , decodeCharAt
  , validateUtf8
  ) where

import Data.Bits ((.&.), (.|.), shiftL)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Char (chr)
import qualified Data.Text as Tx
import qualified Data.Text.Encoding as TxEnc
import Data.Word (Word8)
import Wok.Interp.Value (RuntimeError (PrimError))

-- | Byte width (1..4) implied by a UTF-8 lead byte. 'Left' on a continuation
-- byte (0x80..0xBF) -- i.e. not a codepoint boundary -- or an invalid lead.
utf8Width :: Word8 -> Either RuntimeError Int
utf8Width b
  | b < 0x80  = Right 1
  | b < 0xC0  = Left (PrimError (Tx.pack "utf8: byte offset is not a codepoint boundary"))
  | b < 0xE0  = Right 2
  | b < 0xF0  = Right 3
  | b < 0xF8  = Right 4
  | otherwise = Left (PrimError (Tx.pack "utf8: invalid lead byte"))

-- | Decode the single codepoint whose UTF-8 encoding begins at byte index @i@.
-- Returns @(codepoint, byteWidth)@. O(1). 'Left' if the byte at @i@ is itself a
-- continuation byte (not a boundary). The caller guarantees @0 <= i < length@;
-- the String invariant (valid UTF-8) guarantees the continuation bytes at
-- @i+1..@ exist. Single lead-byte dispatch lives in 'utf8Width' (DRY).
decodeCharAt :: ByteString -> Int -> Either RuntimeError (Char, Int)
decodeCharAt bs i = do
  let b0 = BS.index bs i
  w <- utf8Width b0
  let cont k = fromIntegral (BS.index bs (i + k) .&. 0x3F) :: Int
      cp = case w of
        1 -> fromIntegral b0
        2 -> (fromIntegral (b0 .&. 0x1F) `shiftL` 6)  .|. cont 1
        3 -> (fromIntegral (b0 .&. 0x0F) `shiftL` 12) .|. (cont 1 `shiftL` 6) .|. cont 2
        _ -> (fromIntegral (b0 .&. 0x07) `shiftL` 18) .|. (cont 1 `shiftL` 12)
                                                      .|. (cont 2 `shiftL` 6)  .|. cont 3
  Right (chr cp, w)

-- | True iff the bytes are well-formed UTF-8 (rejects overlong, lone
-- continuation, > U+10FFFF, lone surrogate). The reference/abstract-heap gate
-- for Std.Bytes.fromBytes, and the oracle anchor the C DFA must match.
validateUtf8 :: ByteString -> Bool
validateUtf8 bs = case TxEnc.decodeUtf8' bs of
  Right _ -> True
  Left  _ -> False
