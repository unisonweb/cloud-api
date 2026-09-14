module Cloud.Utils.ServantClientUtils
  ( clientEnvWithTimeout
  )
where

import Servant.Client
import Network.HTTP.Client (ResponseTimeout, responseTimeout)
import Cloud.Prelude

clientEnvWithTimeout :: ResponseTimeout -> ClientEnv -> ClientEnv
clientEnvWithTimeout desiredTimeout defaultEnv =
  defaultEnv
    {
      makeClientRequest = \url req ->
        makeClientRequest defaultEnv url req <&> \r ->
          r { responseTimeout = desiredTimeout }
    }
