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
  , wokStringViewAlloc, wokStringViewParent, wokStringViewOffset, wokStringViewLen
  , wokBytesAlloc, wokBytesLen, wokBytesData, wokBytesByteGet
  , wokForeignBytesAlloc, wokForeignBytesPtr, wokForeignBytesLen
  , wokBorrowViewAlloc, wokBorrowViewPtr, wokBorrowViewLen
  , wokBorrowDemoLend, wokBorrowDemoClose
  , wokValidateUtf8
  , wokArenaOpen, wokArenaAlloc, wokArenaClose, wokStatArenaBytes, wokStatArenaPeak
  -- libc calls used by rcForeignDispatch (Task 6 FFI Slice 2)
  , c_memchr, c_strndup, c_strlen
  ) where

import Foreign.Ptr (Ptr)
import Foreign.C.Types (CInt (..), CSize (..))
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
foreign import ccall unsafe "wok_string_alloc"       wokStringAlloc      :: Ptr WokHeap -> Word64 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_string_len"         wokStringLen        :: Ptr WokObj -> IO Word64
foreign import ccall unsafe "wok_string_data"        wokStringData       :: Ptr WokObj -> IO (Ptr Word8)
foreign import ccall unsafe "wok_string_byte_get"    wokStringByteGet    :: Ptr WokObj -> Word64 -> IO Word64
foreign import ccall unsafe "wok_string_view_alloc"  wokStringViewAlloc  :: Ptr WokHeap -> Ptr WokObj -> Word64 -> Word64 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_string_view_parent" wokStringViewParent :: Ptr WokObj -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_string_view_offset" wokStringViewOffset :: Ptr WokObj -> IO Word64
foreign import ccall unsafe "wok_string_view_len"    wokStringViewLen    :: Ptr WokObj -> IO Word64
foreign import ccall unsafe "wok_bytes_alloc"    wokBytesAlloc    :: Ptr WokHeap -> Word64 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_bytes_len"      wokBytesLen      :: Ptr WokObj -> IO Word64
foreign import ccall unsafe "wok_bytes_data"     wokBytesData     :: Ptr WokObj -> IO (Ptr Word8)
foreign import ccall unsafe "wok_bytes_byte_get" wokBytesByteGet  :: Ptr WokObj -> Word64 -> IO Word64
foreign import ccall unsafe "wok_foreign_bytes_alloc" wokForeignBytesAlloc :: Ptr WokHeap -> Ptr Word8 -> Word64 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_foreign_bytes_ptr"   wokForeignBytesPtr   :: Ptr WokObj -> IO (Ptr Word8)
foreign import ccall unsafe "wok_foreign_bytes_len"   wokForeignBytesLen   :: Ptr WokObj -> IO Word64
foreign import ccall unsafe "wok_borrow_view_alloc" wokBorrowViewAlloc :: Ptr WokHeap -> Ptr Word8 -> Word64 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_borrow_view_ptr"   wokBorrowViewPtr   :: Ptr WokObj -> IO (Ptr Word8)
foreign import ccall unsafe "wok_borrow_view_len"   wokBorrowViewLen   :: Ptr WokObj -> IO Word64
-- The malloc'd lend-THEN-free Demo producer (FFI Slice 3 Task 5). Heap-context-free:
-- the lent buffer is a FOREIGN buffer the borrow view points into, off the WokHeap, so
-- these take no 'Ptr WokHeap'. 'wokBorrowDemoLend n' mallocs min(n,cap) bytes (buf[i]=i&0xFF)
-- and returns the base pointer; 'wokBorrowDemoClose ptr' frees it. The interpreter registers
-- the base ptr at the producing call and frees it once at the borrowing activation's exit.
foreign import ccall unsafe "wok_borrow_demo_lend"  wokBorrowDemoLend  :: Word64 -> IO (Ptr Word8)
foreign import ccall unsafe "wok_borrow_demo_close" wokBorrowDemoClose :: Ptr Word8 -> IO ()
foreign import ccall unsafe "wok_validate_utf8"  wokValidateUtf8  :: Ptr Word8 -> Word64 -> IO Int
foreign import ccall unsafe "wok_arena_open"         wokArenaOpen        :: Ptr WokHeap -> IO Word32
foreign import ccall unsafe "wok_arena_alloc"      wokArenaAlloc    :: Ptr WokHeap -> Word32 -> Word32 -> IO (Ptr WokObj)
foreign import ccall unsafe "wok_arena_close"      wokArenaClose    :: Ptr WokHeap -> Word32 -> IO ()
foreign import ccall unsafe "wok_stat_arena_bytes" wokStatArenaBytes :: Ptr WokHeap -> IO Word64
foreign import ccall unsafe "wok_stat_arena_peak"  wokStatArenaPeak  :: Ptr WokHeap -> IO Word64

-- libc blessed calls (Task 6 FFI Slice 2: borrow-out dispatch)
-- memchr(buf, byte, n): returns pointer to first matching byte, or NULL.
foreign import ccall unsafe "string.h memchr"  c_memchr  :: Ptr Word8 -> CInt -> CSize -> IO (Ptr Word8)
-- strndup(buf, n): malloc's a NUL-terminated copy of up to n bytes of buf.
foreign import ccall unsafe "string.h strndup" c_strndup :: Ptr Word8 -> CSize -> IO (Ptr Word8)
-- strlen(s): byte length of NUL-terminated C string.
foreign import ccall unsafe "string.h strlen"  c_strlen  :: Ptr Word8 -> IO CSize
