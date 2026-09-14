module Cloud.Utils
  ( isValidDNSName,
  )
where

import Cloud.Prelude
import Data.Char qualified as Char
import Data.Text qualified as Text

isValidDNSName :: Text -> Bool
isValidDNSName name =
  case Text.uncons name of
    Just (c, rest)
      | Char.isAlpha c && (Text.length rest < 63) ->
          Text.all (\c -> Char.isAlphaNum c || c == '-') rest
    _ -> False
