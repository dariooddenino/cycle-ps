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
import Data.Newtype

main'
  :: forall s e
   . Sources s (timer :: TIMER | e) Int
  -> Sinks s (timer :: TIMER | e) Int
main' _ =
  StrMap.fromFoldable [(Tuple "TIMER" (Sink (XS.periodic 2000)))]

logDriver
  :: forall s e
   . Driver s (console :: CONSOLE | e) Int
logDriver sink k = do
  -- addListener { next: log <<< show, error: const $ pure unit, complete: const $ pure unit } sink
  Source emptyProducer
--logDriver = pure $ \sink k -> do
--  let s = unwrap sink
--  s <- sink
  -- XS.addListener { next: \i -> log $ show i
  --             , error: \_ -> pure unit
  --             , complete: \_ -> pure unit
  --             } s
--  addListener { next: log <<< show, error: const $ pure unit, complete: const $ pure unit } sink
--  Source emptyProducer

main :: forall e s. XS.EffS (st :: ST s, timer :: TIMER, console :: CONSOLE | e) Unit
main = do
  log "Starting"
  -- let
  --   lis :: XS.Listener (timer :: TIMER, console :: CONSOLE, st :: ST s | e) Int
  --   lis = { next: \i -> log $ show i, error: \_ -> pure unit, complete: \_ -> pure unit }
  -- du <- XS.create'
  -- XS.subscribe lis du
  -- XS.shamefullySendNext 3 du
--  void $ run main' (StrMap.fromFoldable [(Tuple "TIMER" logDriver)])
