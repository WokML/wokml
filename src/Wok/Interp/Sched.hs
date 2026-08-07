module Wok.Interp.Sched (driveConc) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Sequence (Seq, (|>), ViewL (..))
import qualified Data.Sequence as Seq
import qualified Data.Text as Tx

import Wok.IR.Anf (Lit (..))
import Wok.Interp.Value
  ( Config, IdSupply, idRegionBound, Kont (..), PrimTable, RuntimeError (..), Value (..), renderValue )

-- | Re-enter a coro carrier (a VCont) or apply a starter thunk, producing the
-- next machine 'Config'. Supplied by "Wok.Interp.Machine" to avoid an
-- import cycle (Machine already imports this module). The 'IdSupply' rides
-- alongside: a nested 'driveConc' reachable through 'enter' advances it and
-- returns the advanced supply so callers always see the post-drive supply.
type Enter = PrimTable -> IdSupply -> Value -> [Value] -> Kont -> Either RuntimeError (Config, IdSupply)

-- | Run a 'Config' to its final 'Value' (i.e. to a `Done`). Supplied by
-- "Wok.Interp.Machine". The 'IdSupply' threads through so that handle ids
-- minted by any nested 'driveConc' reached during the run are globally unique.
type Run = PrimTable -> IdSupply -> Config -> Either RuntimeError (Value, IdSupply)

-- | Drive a Conc root to its result with a deterministic, single-threaded,
-- FIFO cooperative scheduler. The last argument is a `start`-wrapped STARTER
-- THUNK (`() -> Step Request Transport a (row e)`): applying it to unit installs
-- the child's Coro handler and runs it to its first `Step`.
--
-- 'enterF'/'runF' are the machine's own 'enter'/'run', threaded in by the caller
-- (Machine.hs) to avoid a module import cycle.
--
-- SCOPE: children and root are pure up to `Conc` (they perform only
-- yield/spawn/async/await). This lets every carrier be resumed under a fresh
-- `KDone`. Threading a child's non-Conc residual effect through resume is OUT OF
-- SCOPE here.
--
-- Protocol (see Prim.hs `__coro_*` + Control.wok `Conc`/`Coro`):
--   * A started/resumed coro returns a `Step` Value:
--       VCon "Completed"  [r]                 -- done, result r
--       VCon "Suspended"  [reqValue, carrier] -- parked; carrier is a VCont
--   * reqValue is the `Request` VCon: VCon "ReqYield" [], VCon "ReqSpawn" [Transport st],
--     VCon "ReqAsync" [Transport st], VCon "ReqAwait" [LInt pid], ...
--     Transport-wrapped fields are VCon "Transport" [inner].
--   * To resume a carrier, deliver a Transport-wrapped value (the wok `recall`s it):
--       resume value = VCon "Transport" [v]
--     yield ignores it -> Transport unit; spawn does recallId -> Transport (LInt fid);
--     async does recallId -> Transport (LInt pid); await does recall -> Transport v.
--
-- Id supply contract: 'driveConc' seeds 'schNextId' from the incoming supply
-- and returns the result paired with the next-free supply (the post-consumption
-- counter), so nested drives (reached through child starts as well as resumes)
-- mint globally disjoint ids.
driveConc :: Enter -> Run -> PrimTable -> IdSupply -> Value -> Either RuntimeError (Value, IdSupply)
driveConc enterF runF prims sup0 rootStarter = do
  (rootStep, sup1) <- startCoro sup0 rootStarter
  st0 <- processStep Root rootStep (Sched sup1 Seq.empty Map.empty Map.empty Nothing)
  loop st0
  where
    -- Start a coro from a starter thunk: apply it to unit under a fresh KDone,
    -- run to Done; the result is the first `Step` Value.
    startCoro :: IdSupply -> Value -> Either RuntimeError (Value, IdSupply)
    startCoro sup starter = do
      (cfg, sup1) <- enterF prims sup starter [VLit LUnit] KDone
      runF prims sup1 cfg

    -- Resume a parked carrier with a resume value under a fresh KDone; run to
    -- Done; the result is the next `Step` Value. The carrier (a VCont) re-installs
    -- its Coro handler on re-entry, so the produced value is again a `Step`.
    resumeCoro :: IdSupply -> Value -> Value -> Either RuntimeError (Value, IdSupply)
    resumeCoro sup carrier resumeVal = do
      (cfg, sup1) <- enterF prims sup carrier [resumeVal] KDone
      runF prims sup1 cfg

    -- | Mint a fresh handle id. Refuses to wrap into the next entry's region
    -- (2^48 - 1 ids mintable per interpreter entry — the region's last id is
    -- sacrificed as the wrap sentinel; unreachable in practice, loud if reached).
    mint :: Sched -> Either RuntimeError (Integer, Sched)
    mint st =
      let i    = schNextId st
          next = i + 1
      in if next `mod` idRegionBound == 0
           then Left (PrimError (Tx.pack "conc: handle id space exhausted for this interpreter entry"))
           else Right (i, st { schNextId = next })

    -- Fold a single Step into scheduler state.
    --
    --   Completed r            : Root records the result; Detached is discarded;
    --                            Fulfils pid fulfils the promise cell and wakes
    --                            every parked waiter with the (cached) value.
    --   Suspended ReqYield   c : enqueue (Transport unit, c) at the BACK (round-robin).
    --   Suspended (ReqSpawn st) c: mint a fresh fiber id, start the Detached child
    --                              and fold its first Step, then enqueue the spawner
    --                              resumed with Transport (LInt fid).
    --   Suspended (ReqAsync st) c: mint a fresh promise id, install a Pending cell,
    --                              start the child tagged Fulfils pid and fold its
    --                              first Step (which may already fulfil), then resume
    --                              the caller with Transport (LInt pid).
    --   Suspended (ReqAwait pid) c: Full v -> resume c now with Transport v (cached);
    --                               Pending ws -> park c on the cell (no resume now).
    processStep :: Owner -> Value -> Sched -> Either RuntimeError Sched
    processStep owner step st = case step of
      VCon t [r] | t == completedTag ->
        case owner of
          Root         -> Right (st { schResult = Just r })
          Detached     -> Right st
          Fulfils pid  -> fulfil pid r st
      VCon t [reqVal, carrier] | t == suspendedTag ->
        case reqVal of
          VCon rt [] | rt == reqYieldTag ->
            -- Park; resume later with unit (yield ignores its resume value).
            Right (enqueue owner (transport (VLit LUnit)) carrier st)
          VCon rt [starterT] | rt == reqSpawnTag -> do
            (fid, st1) <- mint st
            childStarter <- unTransport starterT
            (childStep, supAfterChild) <- startCoro (schNextId st1) childStarter
            -- Fire-and-forget: the child is Detached (its Completed is dropped).
            -- Write supAfterChild back before folding: the child's first segment may nest a runConc.
            st2 <- processStep Detached childStep st1 { schNextId = supAfterChild }
            -- Resume the spawner with its new fiber id (recallId reads the LInt).
            Right (enqueue owner (transport (VLit (LInt fid))) carrier st2)
          VCon rt [starterT] | rt == reqAsyncTag -> do
            (pid, st1) <- mint st
            let st1' = st1 { schCells = Map.insert pid (Pending Seq.empty) (schCells st1) }
            childStarter <- unTransport starterT
            (childStep, supAfterChild) <- startCoro (schNextId st1') childStarter
            -- The child fulfils promise `pid` when it Completes.
            -- Write supAfterChild back before folding: the child's first segment may nest a runConc.
            st2 <- processStep (Fulfils pid) childStep st1' { schNextId = supAfterChild }
            -- Resume the caller with the promise id (recallId reads the LInt).
            Right (enqueue owner (transport (VLit (LInt pid))) carrier st2)
          VCon rt [VLit (LInt pid)] | rt == reqAwaitTag ->
            case Map.lookup pid (schCells st) of
              Just (Full v) ->
                -- Fulfil-once cache: deliver the stored value immediately.
                Right (enqueue owner (transport v) carrier st)
              Just (Pending ws) ->
                -- Park the awaiter on the cell; it is woken when `pid` is fulfilled.
                Right (st { schCells = Map.insert pid (Pending (ws |> (owner, carrier))) (schCells st) })
              Nothing ->
                Left (notOwned (Tx.pack "promise") pid)
          VCon rt [] | rt == reqNewChanTag -> do
            -- Allocate an empty channel and hand the caller its id (recallId).
            (cid, st1) <- mint st
            let st2 = st1 { schChans = Map.insert cid (ChanState Seq.empty Seq.empty) (schChans st1) }
            Right (enqueue owner (transport (VLit (LInt cid))) carrier st2)
          VCon rt [VLit (LInt cid), msg] | rt == reqSendTag -> do
            -- `msg` is the Transport-wrapped payload (wok side did `erase v`);
            -- strip the envelope to get the bare value to buffer / deliver.
            v <- unTransport msg
            -- One-shot transport guard: a captured continuation (a coro carrier,
            -- affine) must not be buffered/delivered -- a receiver could resume
            -- it in addition to (or instead of) its rightful single use.
            checkNoCont chanBoundary v
            case Map.lookup cid (schChans st) of
              Just (ChanState buf waiters) ->
                case Seq.viewl waiters of
                  -- A receiver is parked: hand it the OLDEST-first value directly,
                  -- waking it on the ready queue; the buffer stays empty.
                  (rOwner, rCarrier) :< restW ->
                    let st1 = st { schChans = Map.insert cid (ChanState buf restW) (schChans st) }
                        st2 = enqueue rOwner (transport v) rCarrier st1
                    in Right (enqueue owner (transport (VLit LUnit)) carrier st2)
                  -- No receiver: append to the FIFO buffer; ack the sender with unit.
                  EmptyL ->
                    let st1 = st { schChans = Map.insert cid (ChanState (buf |> v) waiters) (schChans st) }
                    in Right (enqueue owner (transport (VLit LUnit)) carrier st1)
              Nothing ->
                Left (notOwned (Tx.pack "channel") cid)
          VCon rt [VLit (LInt cid)] | rt == reqRecvTag ->
            case Map.lookup cid (schChans st) of
              Just (ChanState buf waiters) ->
                case Seq.viewl buf of
                  -- Buffered value waiting: deliver the OLDEST (recall reads it).
                  v :< restB ->
                    let st1 = st { schChans = Map.insert cid (ChanState restB waiters) (schChans st) }
                    in Right (enqueue owner (transport v) carrier st1)
                  -- Empty buffer: park the receiver on the channel (no resume now).
                  EmptyL ->
                    Right (st { schChans = Map.insert cid (ChanState buf (waiters |> (owner, carrier))) (schChans st) })
              Nothing ->
                Left (notOwned (Tx.pack "channel") cid)
          other ->
            Left (PrimError (Tx.pack "driveConc: unsupported request: " <> renderValue other))
      other ->
        Left (PrimError (Tx.pack "driveConc: expected a Step, got " <> renderValue other))

    -- Fulfil promise `pid` with the child's Completed value, cache it, and move
    -- every parked waiter to the ready queue resumed with the (bare) value.
    --
    -- The async child producer is `\ () -> erase (f ())`, so its Completed value
    -- is already Transport-wrapped (VCon "Transport" [inner]). Strip that one
    -- envelope so the cell caches the BARE value; awaiters are then resumed with a
    -- single Transport envelope (which the wok `await` `recall`s back to `inner`).
    fulfil :: Integer -> Value -> Sched -> Either RuntimeError Sched
    fulfil pid raw st = do
      v <- unTransport raw
      -- One-shot transport guard: the cell CACHES v and hands it to EVERY
      -- awaiter, so a captured continuation (a coro carrier, affine) smuggled
      -- inside would be resumable many times. Reject it at the boundary.
      checkNoCont promiseBoundary v
      case Map.lookup pid (schCells st) of
        Just (Pending ws) ->
          let woken = fmap (\(o, c) -> (o, transport v, c)) ws
              ready' = foldl (|>) (schReady st) woken
          in Right st { schCells = Map.insert pid (Full v) (schCells st)
                      , schReady = ready' }
        Just (Full _) ->
          Left (PrimError (Tx.pack "driveConc: promise fulfilled twice: " <> Tx.pack (show pid)))
        Nothing ->
          Left (PrimError (Tx.pack "driveConc: fulfil on unknown promise " <> Tx.pack (show pid)))

    -- Pop the FIFO ready queue, resume each carrier, fold the resulting Step --
    -- until the ROOT completes. Root completion ends the program: as soon as
    -- `schResult` is set we return it, regardless of the queue's contents.
    -- Still-parked or still-ready fibers (race losers, fire-and-forget orphans)
    -- are simply dropped, never resumed again (daemonic, forkIO-style), so a
    -- diverging loser cannot hang the program. If the queue empties BEFORE the
    -- root completed (awaiters still parked on unfulfilled cells / channels),
    -- that is a deadlock.
    loop :: Sched -> Either RuntimeError (Value, IdSupply)
    loop st = case schResult st of
      Just r  -> Right (r, schNextId st)
      Nothing -> case Seq.viewl (schReady st) of
        EmptyL
          | any pending (Map.elems (schCells st)) || any blocked (Map.elems (schChans st)) ->
              Left (PrimError (Tx.pack "conc: deadlock"))
          | otherwise ->
              Left (PrimError (Tx.pack "driveConc: ready queue drained before root completed"))
        (owner, resumeVal, carrier) :< rest -> do
          let st' = st { schReady = rest }
          (nextStep, supAfterResume) <- resumeCoro (schNextId st') carrier resumeVal
          st'' <- processStep owner nextStep st' { schNextId = supAfterResume }
          loop st''

    pending :: Cell -> Bool
    pending (Pending _) = True
    pending (Full _)    = False

    -- A channel is blocked iff a receiver is parked on it with nothing buffered
    -- (the buffer is necessarily empty whenever the waiter queue is non-empty,
    -- since `send` never queues a waiter alongside a buffered value).
    blocked :: ChanState -> Bool
    blocked (ChanState _ waiters) = not (Seq.null waiters)

-- | Which queued coro is the root (whose Completed sets the result), an `async`
-- child fulfilling a promise cell, or a fire-and-forget `spawn` child (Detached,
-- whose Completed is dropped).
data Owner = Root | Fulfils !Integer | Detached

-- | A promise cell: either a queue of parked awaiters (each a @(Owner, carrier)@)
-- or the fulfilled value (cached for fulfil-once await-many semantics).
data Cell = Pending !(Seq (Owner, Value)) | Full !Value

-- | A channel: a FIFO buffer of sent-but-not-yet-received values and a FIFO of
-- parked receivers (each an @(Owner, carrier)@, so a woken receiver that is
-- itself an async child still fulfils its own promise on completion). At most
-- one of the two queues is non-empty at any time.
data ChanState = ChanState !(Seq Value) !(Seq (Owner, Value))

-- | Scheduler state: a fresh-id counter (shared by fibers, promises, channels),
-- a FIFO ready-queue of parked coros, the promise-cell map, the channel map, and
-- the root's eventual result (Nothing until the root completes).
data Sched = Sched
  { schNextId :: !Integer
  , schReady  :: !(Seq (Owner, Value, Value))  -- (owner, resumeValue, carrier)
  , schCells  :: !(Map Integer Cell)
  , schChans  :: !(Map Integer ChanState)
  , schResult :: !(Maybe Value)
  }

enqueue :: Owner -> Value -> Value -> Sched -> Sched
enqueue owner resumeVal carrier st =
  st { schReady = schReady st |> (owner, resumeVal, carrier) }

-- | One-shot transport guard (runtime backstop for the static payload
-- restriction, which is signature-locus only and so misses inference-only
-- payloads). True iff the value IS a captured continuation, or is a data
-- constructor / record whose spine contains one. Deliberately does NOT walk
-- into 'VClosure' environments: they can be huge, and a lambda capturing a
-- carrier VARIABLE is already rejected statically by the directlyEscapes
-- second-class check. 'VLit' / 'VPrim' / 'VInst' carry no continuation.
containsCont :: Value -> Bool
containsCont VCont{}        = True
containsCont VContP{}       = True
containsCont (VCon _ fs)    = any containsCont fs
containsCont (VRecord _ fm) = any containsCont (Map.elems fm)
containsCont VLit{}         = False
containsCont VPrim{}        = False
containsCont VClosure{}     = False
-- proto/handler-values: a handler value's arms are static code; like a closure
-- capturing a carrier it is rejected statically, so it carries no live cont.
containsCont VHandler{}     = False
containsCont VInst{}        = False
containsCont VBytes{}       = False

-- | Reject a value crossing the transport (a promise cell or a channel) if it
-- carries a captured continuation; @where@ names the boundary for the error.
checkNoCont :: Tx.Text -> Value -> Either RuntimeError ()
checkNoCont boundary v
  | containsCont v =
      Left (PrimError (Tx.pack "conc: a continuation cannot cross the transport (carrier in " <> boundary <> Tx.pack ")"))
  | otherwise = Right ()

promiseBoundary, chanBoundary :: Tx.Text
promiseBoundary = Tx.pack "Promise"
chanBoundary    = Tx.pack "Chan"

-- | Ownership error for a handle that misses this scheduler's maps: minted by
-- another runConc (foreign/stale) or forged. The text is golden-locked.
notOwned :: Tx.Text -> Integer -> RuntimeError
notOwned kind i = PrimError (Tx.pack "conc: " <> kind <> Tx.pack " not owned by this scheduler (created by another runConc, or forged): " <> Tx.pack (show i))

-- | Wrap a value in the Transport envelope the wok side `recall`s.
transport :: Value -> Value
transport v = VCon transportTag [v]

-- | Unwrap a Transport envelope, yielding the inner value.
unTransport :: Value -> Either RuntimeError Value
unTransport (VCon t [v]) | t == transportTag = Right v
unTransport other =
  Left (PrimError (Tx.pack "driveConc: expected a Transport, got " <> renderValue other))

completedTag, suspendedTag, transportTag :: Tx.Text
completedTag = Tx.pack "Completed"
suspendedTag = Tx.pack "Suspended"
transportTag = Tx.pack "Transport"

reqYieldTag, reqSpawnTag, reqAsyncTag, reqAwaitTag :: Tx.Text
reqYieldTag  = Tx.pack "ReqYield"
reqSpawnTag  = Tx.pack "ReqSpawn"
reqAsyncTag  = Tx.pack "ReqAsync"
reqAwaitTag  = Tx.pack "ReqAwait"

reqNewChanTag, reqSendTag, reqRecvTag :: Tx.Text
reqNewChanTag = Tx.pack "ReqNewChan"
reqSendTag    = Tx.pack "ReqSend"
reqRecvTag    = Tx.pack "ReqRecv"
