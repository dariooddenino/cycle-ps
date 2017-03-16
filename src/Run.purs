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
import Data.Newtype

type CycleEff s e a = XS.EffS (st :: ST s | e) a
type Listener s e a = XS.Listener (st :: ST s | e) a
type MemoryStream a = XS.Stream a

type Source a = MemoryStream a
type Sink a = MemoryStream a

type Driver s e a b = Sink a -> String -> CycleEff s e (Source b)

newtype DisposeFunction s e = DisposeFunction (Unit -> CycleEff s e Unit)

newtype ReplicationBuffer a = ReplicationBuffer { _n :: Array a, _e :: Array Error }
derive instance newtypeReplicationBuffer :: Newtype (ReplicationBuffer a) _

newtype SinkReplicator s e a = SinkReplicator (Listener s e a)
derive instance newtypeSinkReplicator :: Newtype (SinkReplicator s e a) _

type Sources a = SM.StrMap (Source a)
type Sinks a = SM.StrMap (Sink a)
type SinkProxies a = SM.StrMap (Sink a)
type Drivers s e a b = SM.StrMap (Driver s e a b)
type ReplicationBuffers s a = SMT.STStrMap s (ReplicationBuffer a)
type SinkReplicators s e a = SMT.STStrMap s (SinkReplicator s e a)

foreign import _fixReplicator
  :: forall s e a
   . Listener s e a
  -> CycleEff s e Unit

emptyProducer :: forall s e a. CycleEff s e (MemoryStream a)
emptyProducer = XS.createWithMemory { start: \_ -> pure unit, stop: \_ -> pure unit }

makeSinkProxies :: forall s e a b. Drivers s e a b -> CycleEff s e (SinkProxies a)
makeSinkProxies drivers = do
  m <- SMT.new
  foreachE (SM.keys drivers) \k -> do
    s <- emptyProducer
    SMT.poke m k s
    pure unit
  SM.freezeST m

callDrivers
  :: forall s e a b
   . Drivers s e a b
  -> SinkProxies a
  -> CycleEff s e (Sources b)
callDrivers drivers sinkProxies = do
  sources <- SMT.new
  foreachE (SM.keys drivers) \k ->
    for_ (SM.lookup k drivers) \driver -> do
--      d <- driver
      for_ (SM.lookup k sinkProxies) \s -> do
        source <- driver s k
        SMT.poke sources k source
  SM.freezeST sources

updateBufferNext
  :: forall s e a
   . ReplicationBuffers s a
  -> String
  -> a
  -> CycleEff s e Unit
updateBufferNext buffers name value = do
  mBuffer <- SMT.peek buffers name
  for_ mBuffer \buffer -> do
    let nb = over ReplicationBuffer (\b -> { _n: (snoc b._n value), _e: b._e }) buffer
    void $ SMT.poke buffers name nb

updateBufferError
  :: forall s e a
   . ReplicationBuffers s a
  -> String
  -> Error
  -> CycleEff s e Unit
updateBufferError buffers name value = do
  mBuffer <- SMT.peek buffers name
  for_ mBuffer \buffer -> do
    let nb = over ReplicationBuffer (\b -> { _n: b._n, _e: (snoc b._e value) }) buffer
    void $ SMT.poke buffers name nb

updateBuffersAndReplicators
  :: forall s e a
   . Array String
  -> ReplicationBuffers s a
  -> SinkReplicators s e a
  -> CycleEff s e Unit
updateBuffersAndReplicators names buffers replicators =
  foreachE names (f buffers replicators) where
    f b r n = do
      SMT.poke b n (ReplicationBuffer { _n: [], _e: [] })
      SMT.poke r n (SinkReplicator { next: \i -> updateBufferNext b n i
                                   , error: \e -> updateBufferError b n e
                                   , complete: \_ -> pure unit
                                   })
      pure unit

createSubscriptions
  :: forall s e a
   . Array String
  -> SinkReplicators s e a
  -> Sinks a
  -> CycleEff s e (Array (Maybe XS.Subscription))
createSubscriptions names replicators streams =
  traverseDefault
    (\n ->
      case (SM.lookup n streams) of
        Just s -> do
          rs' <- SM.freezeST replicators
          case (SM.lookup n rs') of
            (Just (SinkReplicator r)) -> do
              Just <$> XS.subscribe r s
            _ -> pure Nothing
        _ -> pure Nothing
      ) names

callBuffer
  :: forall s e a
   . String
  -> ReplicationBuffers s a
  -> (a -> CycleEff s e Unit)
  -> (Error -> CycleEff s e Unit)
  -> CycleEff s e Unit
callBuffer name buffers next error = do
  buffer <- SMT.peek buffers name
  for_ buffer \(ReplicationBuffer b) -> do
      traverse_ next b._n
      traverse_ error b._e

updatePBR
  :: forall s e a
   . Array String
  -> SinkProxies a
  -> ReplicationBuffers s a
  -> SinkReplicators s e a
  -> CycleEff s e Unit
updatePBR names sinkProxies buffers replicators =
  foreachE names \n ->
   case SM.lookup n sinkProxies of
     Just listener -> do
       let
         next = \a -> XS.shamefullySendNext a listener
         error = \e -> XS.shamefullySendError e listener
       callBuffer n buffers next error
       SMT.poke replicators n (SinkReplicator { next: next, error: error, complete: \_ -> pure unit })
       r <- SMT.peek replicators n
       for_ r (_fixReplicator <<< unwrap)
       pure unit
     _ -> pure unit


dispose
  :: forall s e a
   . Array (Maybe XS.Subscription)
  -> SinkProxies a
  -> Array String
  -> DisposeFunction s e
dispose subscriptions proxies names = DisposeFunction \_ -> do
  traverse_ (traverse_ XS.cancelSubscription) subscriptions

  foreachE names \n ->
    case SM.lookup n proxies of
      (Just proxy) ->
                      XS.shamefullySendComplete unit proxy
      _ -> pure unit

replicateMany
  :: forall s e a
   . Sinks a
  -> SinkProxies a
  -> CycleEff s e (DisposeFunction s e)
replicateMany sinks sinkProxies = do
  let names = intersect (SM.keys sinks) (SM.keys sinkProxies)
  buffers <- (SMT.new :: (CycleEff s e (ReplicationBuffers s a)))
  replicators <- (SMT.new :: (CycleEff s e (SinkReplicators s e a)))
  void $ updateBuffersAndReplicators names buffers replicators
  updatePBR names sinkProxies buffers replicators
  subscriptions <- createSubscriptions names replicators sinks
  -- delete map buffers?
  pure $ dispose subscriptions sinkProxies names

run
  :: forall s e a b
   . (Sources b -> CycleEff s e (Sinks a))
  -> Drivers s e a b
  -> CycleEff s e (DisposeFunction s e)
run main drivers = do
  sinkProxies <- makeSinkProxies drivers
  sources <- callDrivers drivers sinkProxies
  sinks <- main sources
  replicateMany sinks sinkProxies
