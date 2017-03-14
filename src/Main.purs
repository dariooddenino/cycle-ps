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
  :: forall e s
   . Sources (timer :: TIMER | e) Int s
  -> Sinks (timer :: TIMER | e) Int s
main' _ =
  StrMap.fromFoldable [(Tuple "TIMER" (XS.periodic 2000))]

logDriver
  :: forall e s
   . Driver (console :: CONSOLE | e) Int s
logDriver sink k = do
  s <- sink
  XS.addListener { next: \i -> log $ show i
                 , error: \_ -> pure unit
                 , complete: \_ -> pure unit
                 }
                 s
  XS.create'

main :: forall e s. XS.EffS (st :: ST s, timer :: TIMER, console :: CONSOLE | e) Unit
main = do
  log "Starting"
  let
    lis :: XS.Listener (timer :: TIMER, console :: CONSOLE, st :: ST s | e) Int
    lis = { next: \i -> log $ show i, error: \_ -> pure unit, complete: \_ -> pure unit }
  du <- XS.create'
  XS.subscribe lis du
  XS.shamefullySendNext 3 du
  void $ run main' (StrMap.fromFoldable [(Tuple "TIMER" logDriver)])
