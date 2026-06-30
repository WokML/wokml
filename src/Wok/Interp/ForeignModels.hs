-- | Representation-independent pure models of the blessed foreign symbols.
--
-- Both interpreters (the reference 'Wok.Interp.Machine' and the RC
-- 'Wok.Interp.RC.Machine') share these byte-level functions; only the
-- value-representation plumbing (how a @Bytes@ argument is extracted and how a
-- result is wrapped) lives in each interpreter's own dispatch surface.
--
-- These are faithful, deterministic models of the libc functions that Task 6
-- will replace with real C calls. Keeping the logic in one place means the two
-- interpreters cannot drift in their not-found / truncation semantics.
module Wok.Interp.ForeignModels
  ( foreignMemchr
  , foreignStrndup
  ) where

import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import Data.Word (Word64)

-- | Pure model for C @memchr(buf, byte, n)@.
--
-- Searches @buf[0 .. min n len)@ (we clamp the scan length to the buffer's
-- length to avoid an overread) and returns the offset of the first byte equal
-- to @(byte .&. 0xFF)@. When the byte is ABSENT, returns @min n len@ -- the
-- CLAMPED length, NOT the original @n@.
--
-- This is the well-defined wok contract: real C @memchr@ returns NULL when the
-- byte is absent, so Task 6's marshalling must translate NULL into this same
-- @min n len@ sentinel for the two backends to agree.
foreignMemchr :: BS.ByteString -> Word64 -> Word64 -> Word64
foreignMemchr bs byte n =
  -- Clamp in the Word64 domain to avoid Int wrap-around when n > 2^63.
  let n'  = fromIntegral (min n (fromIntegral (BS.length bs) :: Word64))
      tgt = fromIntegral (byte .&. 0xFF :: Word64)
  in maybe (fromIntegral n') fromIntegral (BS.elemIndex tgt (BS.take n' bs))

-- | Pure model for C @strndup(buf, n)@.
-- Returns the bytes of @buf@ up to the first NUL or @n@ bytes, whichever
-- comes first. Does NOT include the NUL terminator (mirrors C semantics).
--
-- We clamp in the Word64 domain (same as 'foreignMemchr') so that a huge
-- @n >= 2^63@ does not wrap negative when converted to 'Int', which would
-- cause 'BS.take' to return an empty result instead of the real prefix.
foreignStrndup :: BS.ByteString -> Word64 -> BS.ByteString
foreignStrndup bs n =
  BS.takeWhile (/= 0) (BS.take (fromIntegral (min n (fromIntegral (BS.length bs) :: Word64))) bs)
