{-# LANGUAGE ForeignFunctionInterface #-}
module Wok.Interp.RC.Heap
  ( WokObj, WokHeap
  , wokHeapNew, wokHeapFree
  , wokAlloc, wokDup, wokDec, wokFree
  , wokSlotSet, wokSlotGet, wokTag, wokArity
  , wokStatAllocs, wokStatFrees, wokStatLive, wokStatPeak
  ) where

import Foreign.Ptr (Ptr)
import Data.Word (Word32, Word64)
import Data.Int (Int64)

data WokObj   -- phantom: pointer to a C cell
data WokHeap  -- phantom: pointer to a per-run heap context

foreign import ccall unsafe "wok_heap_new"  wokHeapNew  :: IO (Ptr WokHeap)
foreign import ccall unsafe "wok_heap_free" wokHeapFree :: Ptr WokHeap -> IO ()
foreign import ccall unsafe "wok_alloc"     wokAlloc    :: Ptr WokHeap -> Word32 -> Word32 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_dup"       wokDup      :: Ptr WokObj -> IO ()
foreign import ccall unsafe "wok_dec"       wokDec      :: Ptr WokObj -> IO Word64
foreign import ccall unsafe "wok_free"      wokFree     :: Ptr WokHeap -> Ptr WokObj -> IO ()
foreign import ccall unsafe "wok_slot_set"  wokSlotSet  :: Ptr WokObj -> Word32 -> Word64 -> IO ()
foreign import ccall unsafe "wok_slot_get"  wokSlotGet  :: Ptr WokObj -> Word32 -> IO Word64
foreign import ccall unsafe "wok_tag"       wokTag      :: Ptr WokObj -> IO Word32
foreign import ccall unsafe "wok_arity"     wokArity    :: Ptr WokObj -> IO Word32
foreign import ccall unsafe "wok_stat_allocs" wokStatAllocs :: Ptr WokHeap -> IO Word64
foreign import ccall unsafe "wok_stat_frees"  wokStatFrees  :: Ptr WokHeap -> IO Word64
foreign import ccall unsafe "wok_stat_live"   wokStatLive   :: Ptr WokHeap -> IO Int64
foreign import ccall unsafe "wok_stat_peak"   wokStatPeak   :: Ptr WokHeap -> IO Int64
