module Cloud.Web.Util
  (validDNSName
  )
where

import Cloud.Prelude
import Cloud.Web.App (WebApp)
import Cloud.Utils (isValidDNSName)
import Cloud.Errors (respondError)
import Cloud.Web.Errors (CloudWebError(InvalidName))

validDNSName :: Text -> WebApp Text
validDNSName name | isValidDNSName name = pure name
validDNSName name = respondError $ InvalidName name
