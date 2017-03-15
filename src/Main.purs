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

main'
  :: forall s e
   . Sources Int
  -> CycleEff s (timer :: TIMER | e) (Sinks Int)
main' _ = do
  s <- XS.periodic 500
  pure $ StrMap.fromFoldable [(Tuple "TIMER" (Sink s))]

logDriver
  :: forall s e
   . Driver s (timer :: TIMER, console :: CONSOLE | e) Int
logDriver sink k = do
  addListener { next: \i -> log $ show i, error: const $ pure unit, complete: const $ pure unit } sink
  e <- emptyProducer
  pure $ Source e

main :: forall s e. CycleEff s (timer :: TIMER, console :: CONSOLE | e) Unit
main = do
  log "Starting"
  void $ run main' (StrMap.fromFoldable [(Tuple "TIMER" logDriver)])
