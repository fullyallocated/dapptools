{-# Language GADTs #-}
{-# Language DataKinds #-}

module EVM.Stepper
  ( Action (..)
  , Stepper
  , exec
  , execFully
  , wait
  , ask
  , evm
  , entering
  , enter
  , interpret
  )
where

-- This module is an abstract definition of EVM steppers.
-- Steppers can be run as TTY debuggers or as CLI test runners.
--
-- The implementation uses the operational monad pattern
-- as the framework for monadic interpretation.
--
-- Note: this is a sketch of a work in progress!

import Prelude hiding (fail)

import Control.Monad.Operational (Program, singleton, view, ProgramViewT(..), ProgramView)
import Control.Monad.State.Strict (runState, liftIO, StateT)
import qualified Control.Monad.State.Class as State
import qualified EVM.Exec
import Data.Text (Text)
import EVM.Types (Buffer)

import EVM (EVM, VM, VMResult (VMFailure, VMSuccess), Error (Query, Choose), Query, Choose)
import qualified EVM

import qualified EVM.Fetch as Fetch

-- | The instruction type of the operational monad
data Action a where

  -- | Keep executing until an intermediate result is reached
  Exec ::           Action VMResult

  -- | Wait for a query to be resolved
  Wait :: Query   -> Action ()

  -- | Multiple things can happen
  Ask :: Choose -> Action ()

  -- | Embed a VM state transformation
  EVM  :: EVM a   -> Action a

-- | Type alias for an operational monad of @Action@
type Stepper a = Program Action a

-- Singleton actions

exec :: Stepper VMResult
exec = singleton Exec

wait :: Query -> Stepper ()
wait = singleton . Wait

ask :: Choose -> Stepper ()
ask = singleton . Ask

evm :: EVM a -> Stepper a
evm = singleton . EVM

-- | Run the VM until final result, resolving all queries
execFully :: Stepper (Either Error Buffer)
execFully =
  exec >>= \case
    VMFailure (Query q) ->
      wait q >> execFully
    VMFailure (Choose q) ->
      ask q >> execFully
    VMFailure x ->
      pure (Left x)
    VMSuccess x ->
      pure (Right x)

entering :: Text -> Stepper a -> Stepper a
entering t stepper = do
  evm (EVM.pushTrace (EVM.EntryTrace t))
  x <- stepper
  evm EVM.popTrace
  pure x

enter :: Text -> Stepper ()
enter t = evm (EVM.pushTrace (EVM.EntryTrace t))

interpret :: Fetch.Fetcher -> Stepper a -> StateT VM IO a
interpret fetcher =
  eval . view

  where
    eval
      :: ProgramView Action a
      -> StateT VM IO a

    eval (Return x) =
      pure x

    eval (action :>>= k) =
      case action of
        Exec ->
          EVM.Exec.exec >>= interpret fetcher . k
        Wait q ->
          do m <- liftIO (fetcher q)
             State.state (runState m) >> interpret fetcher (k ())
        Ask _ ->
          error "cannot make choices with this interpreter"
        EVM m -> do
          r <- State.state (runState m)
          interpret fetcher (k r)
