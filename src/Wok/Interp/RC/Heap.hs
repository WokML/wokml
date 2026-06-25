{-# LANGUAGE ForeignFunctionInterface #-}
module Wok.Interp.RC.Heap
  ( WokObj, WokHeap
  , wokHeapNew, wokHeapFree
  , wokAlloc, wokAllocAt, wokDup, wokDec, wokFree
  , wokSlotSet, wokSlotGet, wokTag, wokArity, wokRc
  , wokStatAllocs, wokStatFrees, wokStatLive, wokStatPeak
  , wokStatPeakBytes, wokStatPeakPhysicalBytes
  , wokArrayAlloc, wokArrayLen, wokArrayElemKind, wokArraySlotGet, wokArraySlotSet
  , wokStringAlloc, wokStringLen, wokStringData, wokStringByteGet
  , wokArenaOpen, wokArenaAlloc, wokArenaClose, wokStatArenaBytes, wokStatArenaPeak
  ) where

import Foreign.Ptr (Ptr)
import Data.Word (Word8, Word32, Word64)
import Data.Int (Int64)

data WokObj   -- phantom: pointer to a C cell
data WokHeap  -- phantom: pointer to a per-run heap context

foreign import ccall unsafe "wok_heap_new"  wokHeapNew  :: IO (Ptr WokHeap)
foreign import ccall unsafe "wok_heap_free" wokHeapFree :: Ptr WokHeap -> IO ()
foreign import ccall unsafe "wok_alloc"     wokAlloc    :: Ptr WokHeap -> Word32 -> Word32 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_alloc_at"  wokAllocAt  :: Ptr WokHeap -> Word32 -> Word32 -> Ptr WokObj -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_dup"       wokDup      :: Ptr WokObj -> IO ()
foreign import ccall unsafe "wok_dec"       wokDec      :: Ptr WokObj -> IO Word64
foreign import ccall unsafe "wok_rc"        wokRc       :: Ptr WokObj -> IO Word32
foreign import ccall unsafe "wok_free"      wokFree     :: Ptr WokHeap -> Ptr WokObj -> IO ()
foreign import ccall unsafe "wok_slot_set"  wokSlotSet  :: Ptr WokObj -> Word32 -> Word64 -> IO ()
foreign import ccall unsafe "wok_slot_get"  wokSlotGet  :: Ptr WokObj -> Word32 -> IO Word64
foreign import ccall unsafe "wok_tag"       wokTag      :: Ptr WokObj -> IO Word32
foreign import ccall unsafe "wok_arity"     wokArity    :: Ptr WokObj -> IO Word32
foreign import ccall unsafe "wok_stat_allocs"      wokStatAllocs      :: Ptr WokHeap -> IO Word64
foreign import ccall unsafe "wok_stat_frees"       wokStatFrees       :: Ptr WokHeap -> IO Word64
foreign import ccall unsafe "wok_stat_live"        wokStatLive        :: Ptr WokHeap -> IO Int64
foreign import ccall unsafe "wok_stat_peak"        wokStatPeak        :: Ptr WokHeap -> IO Int64
foreign import ccall unsafe "wok_stat_peak_bytes"  wokStatPeakBytes   :: Ptr WokHeap -> IO Word64
foreign import ccall unsafe "wok_stat_peak_physical_bytes" wokStatPeakPhysicalBytes :: Ptr WokHeap -> IO Word64
foreign import ccall unsafe "wok_array_alloc"     wokArrayAlloc    :: Ptr WokHeap -> Word64 -> Word8 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_array_len"        wokArrayLen      :: Ptr WokObj -> IO Word64
foreign import ccall unsafe "wok_array_elemkind"   wokArrayElemKind :: Ptr WokObj -> IO Word32
foreign import ccall unsafe "wok_array_slot_get"   wokArraySlotGet  :: Ptr WokObj -> Word64 -> IO Word64
foreign import ccall unsafe "wok_array_slot_set"   wokArraySlotSet  :: Ptr WokObj -> Word64 -> Word64 -> IO ()
foreign import ccall unsafe "wok_string_alloc"     wokStringAlloc   :: Ptr WokHeap -> Word64 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_string_len"       wokStringLen     :: Ptr WokObj -> IO Word64
foreign import ccall unsafe "wok_string_data"      wokStringData    :: Ptr WokObj -> IO (Ptr Word8)
foreign import ccall unsafe "wok_string_byte_get"  wokStringByteGet :: Ptr WokObj -> Word64 -> IO Word64
foreign import ccall unsafe "wok_arena_open"       wokArenaOpen     :: Ptr WokHeap -> IO Word32
foreign import ccall unsafe "wok_arena_alloc"      wokArenaAlloc    :: Ptr WokHeap -> Word32 -> Word32 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_arena_close"      wokArenaClose    :: Ptr WokHeap -> Word32 -> IO ()
foreign import ccall unsafe "wok_stat_arena_bytes" wokStatArenaBytes :: Ptr WokHeap -> IO Word64
foreign import ccall unsafe "wok_stat_arena_peak"  wokStatArenaPeak  :: Ptr WokHeap -> IO Word64
