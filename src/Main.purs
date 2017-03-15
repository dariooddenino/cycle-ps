module Main where

import Prelude
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Timer (TIMER)
import Control.Monad.ST (ST)
import Control.Monad.Eff.Console (CONSOLE, log)
import Run
import Data.StrMap as StrMap
import Control.XStream as XS
import Data.Tuple
import Debug.Trace

main'
  :: forall s e
   . Sources s (timer :: TIMER | e) Int
  -> Sinks s (timer :: TIMER | e) Int
main' _ =
  StrMap.fromFoldable [(Tuple "TIMER" (Sink (XS.periodic 500)))]

logDriver
  :: forall s e
   . Driver s (timer :: TIMER, console :: CONSOLE | e) Int
logDriver sink k = do
  addListener { next: \i -> log $ show i, error: const $ pure unit, complete: const $ pure unit } sink
  pure $ Source emptyProducer

main :: forall s e. CycleEff s (timer :: TIMER, console :: CONSOLE | e) Unit
main = do
  log "Starting"
  void $ run main' (StrMap.fromFoldable [(Tuple "TIMER" logDriver)])
