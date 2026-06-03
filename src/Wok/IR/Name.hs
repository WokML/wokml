module Wok.IR.Name
  ( Unique (..)
  , Name (..)
  , JoinId (..)
  , Fresh
  , runFresh
  , freshUnique
  , freshName
  , freshJoin
  , nameText
  ) where

import Control.Monad.State.Strict (State, evalState, state)
import Data.Text (Text)

-- | Opaque identity token. Ord exists ONLY to key Map/IntMap; ordering and
-- contiguity carry no meaning and no pass may rely on them.
newtype Unique = Unique Int
  deriving (Eq, Ord, Show)

-- | A term-level name: a human hint for dumps/errors plus an identity.
-- Eq/Ord are on the unique ALONE.
data Name = Name { nameHint :: Text, nameUniq :: Unique }
  deriving (Show)

instance Eq Name where
  a == b = nameUniq a == nameUniq b
instance Ord Name where
  compare a b = compare (nameUniq a) (nameUniq b)

-- | Join-point label. Its own type so a Jump cannot target a value binder.
newtype JoinId = JoinId Unique
  deriving (Eq, Ord, Show)

-- | Deterministic pure supply (no IO).
type Fresh = State Int

runFresh :: Fresh a -> a
runFresh m = evalState m 0

freshUnique :: Fresh Unique
freshUnique = state (\n -> (Unique n, n + 1))

freshName :: Text -> Fresh Name
freshName hint = Name hint <$> freshUnique

freshJoin :: Fresh JoinId
freshJoin = JoinId <$> freshUnique

-- | The display text for a name (hint only; callers disambiguate on collision).
nameText :: Name -> Text
nameText = nameHint
