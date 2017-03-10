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
import Data.Maybe (Maybe, Maybe(..))
import Data.List (catMaybes)
import Data.Array (intersect, foldM, snoc)
import Data.Traversable (sequenceDefault)

-- it's a  XS.Listener...
-- type FantasyObserver x r c = { next :: x -> Void
 -- , error :: r -> Void
 --                            , complete :: c -> Void
 --                            }

-- Questo che roba e'?
type FantasySubscription = { unsubscribe :: Unit -> Void }

type FantasyObservable e a = { subscribe :: XS.Listener e a -> FantasySubscription}

type MemoryStream e a = XS.EffS e (XS.Stream a)

type Sources a = SM.StrMap a
type Sinks e a = SM.StrMap (FantasyObservable e a)
type SinkProxies e a = SM.StrMap (MemoryStream e a)
type Driver e a = MemoryStream e a -> String -> a
type Drivers e a = SM.StrMap (Driver e a)
type DisposeFunction eff = Unit -> Eff eff Unit

type ReplicationBuffer a = { _n :: Array a, _e :: Array Error }
type ReplicationBuffers a s = SMT.STStrMap s (ReplicationBuffer a)

type SinkReplicators e a s = SMT.STStrMap s (XS.Listener (st :: ST s | e) a)

-- Questa e' una dispose function.
-- deve poter chiamare unsubsribe e sta funzione c() dei sinkProxies
-- disposeReplication() {
--   subscriptions.forEach(s => s.unsubscribe())
--   sinkNames.forEach((name) => sinkProxies[name]._c())
--                      }

emptyProducer :: forall e a. XS.EffS e (XS.Stream a)
emptyProducer = XS.createWithMemory { start: \_ -> pure unit, stop: \_ -> pure unit }

-- for const name in drivers
-- sinkProxies[name] = xs.createWithMemory()

-- type EffS e a = Eff (stream :: STREAM | e) a
-- createWithMemory :: forall e a. Producer e a -> EffS e (Stream a)
-- type Listener e a = { next :: a -> EffS e Unit, error :: Error -> EffS e Unit, complete :: Unit -> EffS e Unit }
-- type Producer e a = { start: Listener e a -> EffS e Unit, stop :: Unit -> EffS e Unit }


makeSinkProxies :: forall e a. Drivers e a -> SinkProxies e a
makeSinkProxies drivers =
  SM.fromFoldable $ (\k -> (Tuple k emptyProducer)) <$> SM.keys drivers

_createSource :: forall e a. SinkProxies e a -> String -> Driver e a -> Maybe a
_createSource sinkProxies k d = (\s -> d s k) <$> (SM.lookup k sinkProxies)

_filterStrMap :: forall a. SM.StrMap (Maybe a) -> SM.StrMap a
_filterStrMap m = SM.fromFoldable $ catMaybes $ sequenceDefault <$> SM.toList m

callDrivers :: forall e a. Drivers e a -> SinkProxies e a -> Sources a
callDrivers drivers sinkProxies =
  _filterStrMap $
    SM.mapWithKey (_createSource sinkProxies) drivers

-- update :: (a -> Maybe a) -> String -> StrMap a -> StrMap a

--_updateBufferNext :: forall a b. String -> a -> b -> ReplicationBuffers a b
-- _updateBuffers key a b = update (f a b) key where
--  f a b k = Nothing

updateBufferNext :: forall e a s. (ReplicationBuffers a s) -> String -> a -> XS.EffS (st :: ST s | e) Unit
updateBufferNext buffer name value = do
  currValue <- SMT.peek buffer name
  case currValue of
    Just c -> void $ SMT.poke buffer name { _n: (snoc c._n value), _e: c._e }
    _ -> pure unit

updateBufferError :: forall e a s. (ReplicationBuffers a s) -> String -> Error -> XS.EffS (st :: ST s | e) Unit
updateBufferError buffer name value = do
  currValue <-SMT.peek buffer name
  case currValue of
    Just c -> void $ SMT.poke buffer name { _n: c._n, _e: (snoc c._e value) }
    _ -> pure unit

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

replicateMany :: forall e a s. Sinks e a -> SinkProxies e a -> XS.EffS (st :: ST s | e) Unit
replicateMany sinks sinkProxies = do
  let names = intersect (SM.keys sinks) (SM.keys sinkProxies)
  buffers <- (SMT.new :: (XS.EffS (st :: ST s | e) (ReplicationBuffers a s)))
  replicators <- (SMT.new :: (XS.EffS (st :: ST s | e) (SinkReplicators e a s)))
  void $ updateBuffersAndReplicators names buffers replicators
  pure unit
  -- crea subscriptions con xs fromObservable .subscribe replicator
  -- itera i names di nuovo e fa operazioni varie su buffer

-- function replicateMany<So extends Sources, Si extends Sinks>(
--                       sinks: Si,
--                       sinkProxies: SinkProxies<Si>): DisposeFunction {
--   const sinkNames: Array<keyof Si> = Object.keys(sinks).filter(name => !!sinkProxies[name]);

--   let buffers: ReplicationBuffers<Si> = {} as ReplicationBuffers<Si>;
--   const replicators: SinkReplicators<Si> = {} as SinkReplicators<Si>;
--   sinkNames.forEach((name) => {
--     buffers[name] = {_n: [], _e: []};
--     replicators[name] = {
--       next: (x: any) => buffers[name]._n.push(x),
--       error: (err: any) => buffers[name]._e.push(err),
--       complete: () => {},
--     };
--   });

--   const subscriptions = sinkNames
--     .map(name => xs.fromObservable(sinks[name] as any).subscribe(replicators[name]));

--   sinkNames.forEach((name) => {
--     const listener = sinkProxies[name];
--     const next = (x: any) => { listener._n(x); };
--     const error = (err: any) => { logToConsoleError(err); listener._e(err); };
--     buffers[name]._n.forEach(next);
--     buffers[name]._e.forEach(error);
--     replicators[name].next = next;
--     replicators[name].error = error;
--     // because sink.subscribe(replicator) had mutated replicator to add
--     // _n, _e, _c, we must also update these:
--     replicators[name]._n = next;
--     replicators[name]._e = error;
--   });
--   buffers = null as any; // free up for GC

--   return function disposeReplication() {
--     subscriptions.forEach(s => s.unsubscribe());
--     sinkNames.forEach((name) => sinkProxies[name]._c());
--   };
-- }


run :: forall e a. (Sources a -> Sinks e a) -> Drivers e a -> Unit
run main drivers = do
  let
    sinkProxies = makeSinkProxies drivers
    sources = callDrivers drivers sinkProxies
    -- adaptedSources = adaptSources sources ?? boh e poi la passerebbe al main sotto
    sinks = main sources
--     disposeReplication = replicateMany sinks sinkProxies -- questo e' un eff, andrebbe col <-
  -- return function dispose () {
   -- disposeSources sources
  -- disposeReplication
  -- }
  unit


-- -- -- --

-- The important thing to know while using iti s that `pureST :: (forall s. Eff (st :: ST s) a) -> a` is used like

-- ```add2Items strMap k1 a1 k2 a2 = pureST do
--   mutableStrMap <- StrMap.thawST strMap
--   StrMap.ST.poke mutableStrMap k1 a1
--   StrMap.ST.poke mutableStrMap k2 a2
--   copiedNewMap <- StrMap.freezeST mutableStrMap
--   pure copiedNewMap
-- ```

-- parsonsmatt [7:28 PM]
-- so I think your `filter` function could be implemented like

-- ```_filterStrMap :: forall a. SM.STrMap (Maybe a) -> SM.StrMap a
-- _filterStrMap oldMap = pureST do
--   newMap <- ST.new
--   foldM oldMap \acc key maybeA ->
--     for maybeA \a -> ST.poke newMap key a
--   freezeST newMap
-- ```

-- or `foldM oldMap \_ key -> traverse (ST.poke newMap key)`, if you want it a little more concise
