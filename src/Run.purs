module Run where

import Prelude

import Control.Monad.Eff (Eff, foreachE)
import Control.Monad.Eff.Exception (Error)
import Control.Monad.Eff.Console (log, logShow)
import Control.Monad.Eff.Class (liftEff)
import Control.XStream as XS
import Data.StrMap as SM
import Control.Monad.ST (ST)
import Data.StrMap.ST as SMT
import Data.Tuple (Tuple(..))
import Data.Maybe (isJust, Maybe(..))
import Data.List (catMaybes)
import Data.Array (intersect, foldM, snoc, filter)
import Data.Traversable (sequenceDefault, traverseDefault, traverse_, for_)
import Debug.Trace

foreign import _fixReplicator :: forall e a s. XS.Listener (st :: ST s | e) a -> XS.EffS (st :: ST s | e) Unit

type MemoryStream e a = XS.EffS e (XS.Stream a)
type Sources e a s = SM.StrMap (MemoryStream (st :: ST s | e) a)
type Sinks e a s = SM.StrMap (MemoryStream (st :: ST s | e) a)
type SinkProxies e a s = SM.StrMap (MemoryStream (st :: ST s | e) a)
type Driver e a s = MemoryStream (st :: ST s | e) a -> String -> MemoryStream (st :: ST s | e) a
type Drivers e a s = SM.StrMap (Driver e a s)
type DisposeFunction e s = Unit -> XS.EffS (st :: ST s | e) Unit
type ReplicationBuffer a = { _n :: Array a, _e :: Array Error }
type ReplicationBuffers a s = SMT.STStrMap s (ReplicationBuffer a)
type SinkReplicators e a s = SMT.STStrMap s (XS.Listener (st :: ST s | e) a)

emptyProducer :: forall e a. XS.EffS e (XS.Stream a)
emptyProducer = XS.createWithMemory { start: \_ -> pure unit, stop: \_ -> pure unit }

makeSinkProxies :: forall e a s. Drivers e a s -> SinkProxies e a s
makeSinkProxies drivers =
  SM.fromFoldable $ (\k -> (Tuple k emptyProducer)) <$> SM.keys drivers

_createSource :: forall e a s. SinkProxies e a s -> String -> Driver e a s -> Maybe (MemoryStream (st :: ST s | e) a)
_createSource sinkProxies k d =
  (\s -> d s k) <$> (SM.lookup k sinkProxies)

_filterStrMap :: forall e a s. SM.StrMap (Maybe (MemoryStream (st :: ST s | e) a)) -> SM.StrMap (MemoryStream (st :: ST s | e) a)
_filterStrMap m = SM.fromFoldable $ catMaybes $ sequenceDefault <$> SM.toList m

callDrivers :: forall e a s. Drivers e a s -> SinkProxies e a s -> Sources e a s
callDrivers drivers sinkProxies =
  _filterStrMap $
    SM.mapWithKey (_createSource sinkProxies) drivers

updateBufferNext :: forall e a s. (ReplicationBuffers a s) -> String -> a -> XS.EffS (st :: ST s | e) Unit
updateBufferNext buffer name value = do
  currValue <- SMT.peek buffer name
  for_ currValue \c -> void $ SMT.poke buffer name { _n: (snoc c._n value), _e: c._e }

updateBufferError :: forall e a s. (ReplicationBuffers a s) -> String -> Error -> XS.EffS (st :: ST s | e) Unit
updateBufferError buffer name value = do
  currValue <- SMT.peek buffer name
  for_ currValue \c -> void $ SMT.poke buffer name { _n: c._n, _e: ( snoc c._e value )}

updateBuffersAndReplicators
  :: forall e a s
   . Array String
  -> ReplicationBuffers a s
  -> SinkReplicators e a s
  -> XS.EffS (st :: ST s | e) Unit
updateBuffersAndReplicators names buffers replicators =
  foreachE names (f buffers replicators) where
    f b r n = do
      SMT.poke b n { _n: [], _e: [] }
      SMT.poke r n { next: updateBufferNext b n
                   , error: updateBufferError b n
                   , complete: \_ -> pure unit
                   }
      pure unit

createSubscriptions
  :: forall e a s
   . Array String
  -> SinkReplicators e a s
  -> Sinks e a s
  -> XS.EffS (st :: ST s | e) (Array (Maybe XS.Subscription))
createSubscriptions names replicators streams =
  traverseDefault
    (\n ->
      case (SM.lookup n streams) of
        Just s' -> do
          s <- s'
          rs' <- SM.freezeST replicators
          case (SM.lookup n rs') of
            (Just r) -> do
              Just <$> XS.subscribe r s
            _ -> pure Nothing
        _ -> pure Nothing
      ) names

callBuffer
  :: forall e a s
   . String
  -> ReplicationBuffers a s
  -> (a -> XS.EffS (st :: ST s | e) Unit)
  -> (Error -> XS.EffS (st :: ST s | e) Unit)
  -> XS.EffS (st :: ST s | e) Unit
callBuffer name buffers next error = do
  buffer <- SMT.peek buffers name
  for_ buffer \b -> do
      traverse_ next b._n
      traverse_ error b._e

updatePBR
  :: forall e a s
   . Array String
  -> SinkProxies e a s
  -> ReplicationBuffers a s
  -> SinkReplicators e a s
  -> XS.EffS (st :: ST s | e) Unit
updatePBR names sinkProxies buffers replicators =
  foreachE names \n ->
   case SM.lookup n sinkProxies of
     (Just listener) -> do
       l <- listener
       let
         next = \a -> XS.shamefullySendNext a l
         error = \e -> XS.shamefullySendError e l
       callBuffer n buffers next error
       SMT.poke replicators n { next: next, error: error, complete: \_ -> pure unit }
       r <- SMT.peek replicators n
       for_ r _fixReplicator
       pure unit
     _ -> pure unit


dispose
  :: forall e a s
   . Array (Maybe XS.Subscription)
  -> SinkProxies e a s
  -> Array String
  -> DisposeFunction e s
dispose subscriptions proxies names = \_ -> do
  traverse_ (traverse_ XS.cancelSubscription) subscriptions

  foreachE names \n ->
    case SM.lookup n proxies of
      (Just proxy) -> proxy >>= \p ->
                      XS.shamefullySendComplete unit p
      _ -> pure unit

replicateMany
  :: forall e a s
   . Sinks e a s
  -> SinkProxies e a s
  -> XS.EffS (st :: ST s | e) (DisposeFunction e s)
replicateMany sinks sinkProxies = do
  let names = intersect (SM.keys sinks) (SM.keys sinkProxies)
  buffers <- (SMT.new :: (XS.EffS (st :: ST s | e) (ReplicationBuffers a s)))
  replicators <- (SMT.new :: (XS.EffS (st :: ST s | e) (SinkReplicators e a s)))
  void $ updateBuffersAndReplicators names buffers replicators
  updatePBR names sinkProxies buffers replicators
  subscriptions <- createSubscriptions names replicators sinks
  -- delete map buffers?
  pure $ dispose subscriptions sinkProxies names

run
  :: forall e a s
   . (Sources e a s -> Sinks e a s)
  -> Drivers e a s
  -> XS.EffS (st :: ST s | e) (DisposeFunction e s)
run main drivers = do
  let
    sinkProxies = makeSinkProxies drivers
    sources = callDrivers drivers sinkProxies
    sinks = main sources
  replicateMany sinks sinkProxies
