module Main where

import Prelude
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Timer (TIMER)
import Control.Monad.ST (ST, STRef, newSTRef, readSTRef, modifySTRef, writeSTRef)
import Control.Monad.Eff.Console (CONSOLE, log)
import Run
import Data.StrMap as StrMap
import Data.StrMap.ST as StrMap.ST
import Control.XStream as XS
import Data.Tuple
import Data.Array (range)
import Snabbdom
import Data.Maybe
import Data.Newtype
import Debug.Trace

h_ tag = h tag { attrs: StrMap.empty, on: toVNodeEventObject StrMap.empty,
                 hook: toVNodeHookObjectProxy { insert: Nothing, update: Nothing, destroy: Nothing }}

type Node s e = VNodeProxy (st :: ST s, stream :: XS.STREAM | e)

main'
  :: forall s e
   . Sources Int
  -> CycleEff s (timer :: TIMER, vdom :: VDOM | e) (Sinks (Node s (timer :: TIMER | e)))
main' i = do
   let input = StrMap.lookup "DOM" i
   case input of
     (Just stream) -> do
       let
         toDom j = h_ "div" $ (\j' -> h_ "p" [text $ "Hello World:" <> show j']) <$> (range 0 j)
         sink = toDom <$> stream
       pure $ StrMap.singleton "DOM" sink
     _ -> do
       e <- emptyProducer
       pure $ StrMap.singleton "DOM" e

mOrpatch
  :: forall s e
   . STRef s (Maybe (Node s e))
  -> Node s e
  -> CycleEff s (vdom :: VDOM | e) Unit
mOrpatch currentDom newDom = do
  cdom <- readSTRef currentDom
  case cdom of
    Nothing -> do
      _ <- writeSTRef currentDom $ Just newDom
      patchInitialSelector "#app" newDom
    Just dom -> do
      void $ writeSTRef currentDom $ Just newDom
      patch dom newDom

domDriver
  :: forall s e
   . Driver s (vdom :: VDOM, timer :: TIMER | e) (Node s (timer :: TIMER | e)) Int
domDriver sink k = do
  vdom <- newSTRef Nothing
  XS.addListener { next: \n -> mOrpatch vdom n, error: const $ pure unit, complete: const $pure unit } sink
  e <- XS.periodic 1000
  pure e

main :: forall s e. CycleEff s (vdom :: VDOM, timer :: TIMER | e) Unit
main = do
  void $ run main' (StrMap.fromFoldable [(Tuple "DOM" domDriver)])
