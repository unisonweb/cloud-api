{-# LANGUAGE DeriveAnyClass #-}
module Cloud.Log.Types 
(
  LogQueryResult (..),
)

where
import Cloud.Prelude
import Data.Aeson

data LogQueryResult = LogQueryResult
  { nun :: Int,
    logs :: [Text]
  }
  deriving (Eq, Show, Generic, ToJSON)

{-

NOTES:

This command will produce a JSON response from loki that we are trying to parse:

    curl -v 'http://loki.us-west-2.unison-lang.org:3100/loki/api/v1/query_range?query=%7Bjob=%22nomad_allocs%22,%20task_name=%22nimbus%22%7D'

you can see what the query is:

    ❯ echo '%7Bjob=%22nomad_allocs%22,%20task_name=%22nimbus%22%7D' | sed 's/%/\\x/g' | xargs -0 printf '%b'

    {job="nomad_allocs", task_name="nimbus"}


  ❯ python3
Python 3.11.2 (main, Mar 13 2023, 12:18:29) [GCC 12.2.0] on linux
Type "help", "copyright", "credits" or "license" for more information.
>>> import urllib.parse
>>> print(urllib.parse.quote_plus('{job="nomad_allocs", task_name="nimbus"}'))
%7Bjob%3D%22nomad_allocs%22%2C+task_name%3D%22nimbus%22%7D



This is perhpas how we could graft the Text of the log lines in as raw JSON.

data LogQueryResult = LogQueryResult
  { nun :: Int
  , logs :: [Text]
  } deriving (Eq, Show, Generic)

instance ToJSON LogQueryResult where
  toJSON (LogQueryResult n l) = object
    [ "nun" .= n
    , "logs" .= map toJSONRawJson l
    ]
  toEncoding (LogQueryResult n l) = pairs
    ( "nun" .= n <> "logs" .= map toJSONRawJson l
    )

-- Helper function to treat Text as raw JSON
toJSONRawJson :: Text -> Value
toJSONRawJson logText = 
  case eitherDecode (fromStrict $ TE.encodeUtf8 logText) of
    Right val -> val
    Left _ -> error "Invalid JSON in logs" -- Or handle this case as you see fit

-- Directly inject raw text as JSON using unsafeToEncoding
-- This skips the overhead of parsing and directly outputs the text as JSON
instance ToJSON Text where
  toJSON = String
  toEncoding text = unsafeToEncoding . fromStrict $ TE.encodeUtf8 text

-}  
