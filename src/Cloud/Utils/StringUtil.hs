module Cloud.Utils.StringUtil
  ( stripPrefix
  )

where

import qualified Data.Text as Text

stripPrefix :: String -> String -> String
stripPrefix prefix content =
  maybe content Text.unpack (Text.stripPrefix (Text.pack prefix) (Text.pack content))
