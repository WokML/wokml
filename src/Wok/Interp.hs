-- | Public facade for the ANF CEK interpreter. The interpreter runs an
-- elaborated CoreModule (Scope B output) to a runtime Value. v1 is pure:
-- main must be 0-arity and any effects must be discharged by handlers.
--
-- v1 limitation: top-level value constants (0-arity bindings other than
-- @main@, e.g. @answer = 42@) are NOT supported and are rejected with an
-- 'UnsupportedCaf' error rather than evaluated. Only function bindings
-- (arity >= 1) and @main@ are run. (Forcing CAFs in a strict machine with
-- mutual function/constant references is deferred to a later iteration.)
module Wok.Interp
  ( runModule
  , renderValue
  , RuntimeError (..)
  ) where

import Wok.Interp.Machine (runModule)
import Wok.Interp.Value (RuntimeError (..), renderValue)
