{-# LANGUAGE ForeignFunctionInterface #-}

-- | Pure Haskell wrappers over the StringZilla C entry points (`runtime/wok_str_ops.c`).
-- The C functions are pure byte->value computations that never touch the wok_rc heap,
-- so 'unsafeDupablePerformIO' over 'BSU.unsafeUseAsCStringLen' is sound and copy-free.
module Wok.Runtime.StringZilla
  ( szFind
  , szHash
  , szEditDistance
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Data.Word (Word64)
import Foreign.C.Types (CChar, CSize (..))
import Foreign.Ptr (Ptr)
import System.IO.Unsafe (unsafeDupablePerformIO)

foreign import ccall unsafe "wok_sz_find"
  c_wok_sz_find :: Ptr CChar -> CSize -> Ptr CChar -> CSize -> CSize -> IO Word64

foreign import ccall unsafe "wok_sz_hash"
  c_wok_sz_hash :: Ptr CChar -> CSize -> IO Word64

foreign import ccall unsafe "wok_sz_edit_distance"
  c_wok_sz_edit_distance :: Ptr CChar -> CSize -> Ptr CChar -> CSize -> IO Word64

-- | First occurrence of @needle@ in @hay@ at/after byte offset @from@;
--   absolute byte position, or 'maxBound' (== @WOK_SZ_NOT_FOUND@) if absent.
szFind :: BS.ByteString -> BS.ByteString -> Int -> Word64
szFind hay needle from = unsafeDupablePerformIO $
  BSU.unsafeUseAsCStringLen hay $ \(hp, hl) ->
    BSU.unsafeUseAsCStringLen needle $ \(np, nl) ->
      c_wok_sz_find hp (fromIntegral hl) np (fromIntegral nl) (fromIntegral from)

szHash :: BS.ByteString -> Word64
szHash s = unsafeDupablePerformIO $
  BSU.unsafeUseAsCStringLen s $ \(p, l) ->
    c_wok_sz_hash p (fromIntegral l)

szEditDistance :: BS.ByteString -> BS.ByteString -> Word64
szEditDistance a b = unsafeDupablePerformIO $
  BSU.unsafeUseAsCStringLen a $ \(ap, al) ->
    BSU.unsafeUseAsCStringLen b $ \(bp, bl) ->
      c_wok_sz_edit_distance ap (fromIntegral al) bp (fromIntegral bl)
