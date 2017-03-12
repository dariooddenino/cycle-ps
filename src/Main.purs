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

-- main'
--   :: forall e a s
--    . Sources e a s
--   -> Sinks (timer :: TIMER | e) Int s
main' _ = StrMap.fromFoldable [(Tuple "TIMER" (XS.periodic 100))]

logDriver
  :: forall e a s
   . Show a
  => Driver (console :: CONSOLE | e) a s
logDriver sink _ = do
  s <- sink
  XS.addListener { next: \i -> log $ show i
                 , error: \_ -> pure unit
                 , complete: \_ -> pure unit
                 }
                 s
  XS.create'

-- main :: forall e s. XS.EffS (st :: ST s, timer :: TIMER, console :: CONSOLE | e) Unit
main = do
  log "Starting"
  void $ run main' $ StrMap.fromFoldable [(Tuple "TIMER" logDriver)]
  log "Hello sailor!"
