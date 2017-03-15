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

-- foreign import _fixReplicator :: forall e a s. XS.Listener (st :: ST s | e) a -> XS.EffS (st :: ST s | e) Unit

-- type MemoryStream e a = XS.EffS e (XS.Stream a)
-- type Sources e a s = SM.StrMap (MemoryStream (st :: ST s | e) a)
-- type Sinks e a s = SM.StrMap (MemoryStream (st :: ST s | e) a)
-- type SinkProxies e a s = SM.StrMap (MemoryStream (st :: ST s | e) a)
-- type SinkProxies s e a = SM.StrMap (MemoryStream s e a)
-- type Driver e a s = MemoryStream (st :: ST s | e) a -> String -> MemoryStream (st :: ST s | e) a
-- type Driver s e a = MemoryStream s e a -> String -> MemoryStream s e a
-- type Drivers e a s = SM.StrMap (Driver e a s)
-- type DisposeFunction e s = Unit -> XS.EffS (st :: ST s | e) Unit
-- type ReplicationBuffer a = { _n :: Array a, _e :: Array Error }
-- type ReplicationBuffers a s = SMT.STStrMap s (ReplicationBuffer a)
-- type SinkReplicators e a s = SMT.STStrMap s (XS.Listener (st :: ST s | e) a)

type CycleEff s e a = XS.EffS (st :: ST s | e) a
type Listener s e a = XS.Listener (st :: ST s | e) a
type MemoryStream s e a = CycleEff s e (XS.Stream a)

newtype Source s e a = Source (MemoryStream s e a)
derive instance newtypeSource :: Newtype (Source s e a) _

newtype Sink s e a = Sink (MemoryStream s e a)
derive instance newtypeSink :: Newtype (Sink s e a) _

newtype SinkProxy s e a =  SinkProxy (MemoryStream s e a)
derive instance newtypeSinkProxy :: Newtype (SinkProxy s e a) _

type Driver s e a = CycleEff s e (Sink s e a -> String -> Source s e a)

newtype DisposeFunction s e = DisposeFunction (Unit -> CycleEff s e Unit)

newtype ReplicationBuffer a = ReplicationBuffer { _n :: Array a, _e :: Array Error }
derive instance newtypeReplicationBuffer :: Newtype (ReplicationBuffer a) _

newtype SinkReplicator s e a = SinkReplicator (Listener s e a)
derive instance newtypeSinkReplicator :: Newtype (SinkReplicator s e a) _

type Sources s e a = SM.StrMap (Source s e a)
type Sinks s e a = SM.StrMap (Sink s e a)
type SinkProxies s e a = SM.StrMap (Sink s e a)
type Drivers s e a = SM.StrMap (Driver s e a)
type ReplicationBuffers s a = SMT.STStrMap s (ReplicationBuffer a)
type SinkReplicators s e a = SMT.STStrMap s (SinkReplicator s e a)

foreign import _fixReplicator
  :: forall s e a
   . Listener s e a
  -> CycleEff s e Unit

fixReplicator :: forall s e a. SinkReplicator s e a -> CycleEff s e Unit
fixReplicator r = _fixReplicator $ unwrap r

emptyProducer :: forall s e a. MemoryStream s e a
emptyProducer = XS.createWithMemory { start: \_ -> pure unit, stop: \_ -> pure unit }

makeSinkProxies :: forall s e a. Drivers s e a -> SinkProxies s e a
makeSinkProxies drivers =
  SM.fromFoldable $ (\k -> (Tuple k (Sink emptyProducer))) <$> SM.keys drivers

_createSource
  :: forall s e a
   . SinkProxies s e a
  -> String
  -> Driver s e a
  -> CycleEff s e (Maybe (Source s e a))
_createSource sinkProxies k driver = do
  d <- driver
  pure $ (\s -> d s k) <$> (SM.lookup k sinkProxies)

_filterStrMap
  :: forall s e a
   . SM.StrMap (Maybe (Source s e a))
  -> SM.StrMap (Source s e a)
_filterStrMap m = SM.fromFoldable $ catMaybes $ sequenceDefault <$> SM.toList m

callDrivers
  :: forall s e a
   . Drivers s e a
  -> SinkProxies s e a
  -> CycleEff s e (Sources s e a)
callDrivers drivers sinkProxies = do
  sources <- SMT.new
  foreachE (SM.keys drivers) \k ->
    for_ (SM.lookup k drivers) \driver -> do
      d <- driver
      for_ (SM.lookup k sinkProxies) \s ->
        SMT.poke sources k (d s k)
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
      SMT.poke r n (SinkReplicator { next: updateBufferNext b n
                                   , error: updateBufferError b n
                                   , complete: \_ -> pure unit
                                   })
      pure unit

createSubscriptions
  :: forall s e a
   . Array String
  -> SinkReplicators s e a
  -> Sinks s e a
  -> CycleEff s e (Array (Maybe XS.Subscription))
createSubscriptions names replicators streams =
  traverseDefault
    (\n ->
      case (SM.lookup n streams) of
        Just (Sink s') -> do
          s <- s'
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
  -> SinkProxies s e a
  -> ReplicationBuffers s a
  -> SinkReplicators s e a
  -> CycleEff s e Unit
updatePBR names sinkProxies buffers replicators =
  foreachE names \n ->
   case SM.lookup n sinkProxies of
     (Just (Sink listener)) -> do
       l <- listener
       let
         next = \a -> XS.shamefullySendNext a l
         error = \e -> XS.shamefullySendError e l
       callBuffer n buffers next error
       SMT.poke replicators n (SinkReplicator { next: next, error: error, complete: \_ -> pure unit })
       r <- SMT.peek replicators n
       for_ r fixReplicator
       pure unit
     _ -> pure unit


dispose
  :: forall s e a
   . Array (Maybe XS.Subscription)
  -> SinkProxies s e a
  -> Array String
  -> DisposeFunction s e
dispose subscriptions proxies names = DisposeFunction \_ -> do
  traverse_ (traverse_ XS.cancelSubscription) subscriptions

  foreachE names \n ->
    case SM.lookup n proxies of
      (Just (Sink proxy)) -> proxy >>= \p ->
                      XS.shamefullySendComplete unit p
      _ -> pure unit

replicateMany
  :: forall s e a
   . Sinks s e a
  -> SinkProxies s e a
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
  :: forall s e a
   . (Sources s e a -> Sinks s e a)
  -> Drivers s e a
  -> CycleEff s e (DisposeFunction s e)
run main drivers = do
  let sinkProxies = makeSinkProxies drivers
  sources <- callDrivers drivers sinkProxies
  let sinks = main sources
  replicateMany sinks sinkProxies

addListener
  :: forall s e a
   . Listener s e a
  -> Sink s e a
  -> CycleEff s e Unit
addListener listener stream =
  unwrap stream >>= \s ->
    XS.addListener listener s
