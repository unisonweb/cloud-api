module Cloud.Prelude
  ( ByteString,
    coerce,
    eitherToMaybe,
    Exception (..),
    fromMaybe,
    Generic,
    HasCallStack,
    Map,
    maybeToEither,
    module X,
    readMaybe,
    Text,
    tshow,

    -- * Monad Utils
    when,
    forever,
    guard,
  )
where

import Cloud.Prelude.Orphans ()
import Control.Monad (forever, guard, when)
import Data.Bifunctor as X
import Data.ByteString (ByteString)
import Data.Coerce (coerce)
import Data.Foldable as X
import Data.Function as X
import Data.Functor as X
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import GHC.Stack (HasCallStack)
import Text.Read (readMaybe)
import UnliftIO as X (Exception (..), MonadIO (..), MonadUnliftIO, bracket, bracket_, throwIO, try)

eitherToMaybe :: Either x a -> Maybe a
eitherToMaybe = either (const Nothing) Just

maybeToEither :: a -> Maybe b -> Either a b
maybeToEither a = maybe (Left a) Right

tshow :: (Show t) => t -> Text
tshow = Text.pack . show
{-# INLINE tshow #-}
