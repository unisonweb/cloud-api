module Cloud.Utils.TextUtil
  ( stripPrefix
  )

where

import Data.Text qualified as Text
import Cloud.Prelude

stripPrefix :: Text -> Text -> Text
stripPrefix prefix content =
  fromMaybe content (Text.stripPrefix prefix content)
