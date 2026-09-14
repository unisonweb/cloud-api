{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module Cloud.Email.Client
where

import Servant
import Servant.Client
import Cloud.Prelude
import Data.Aeson hiding (Result)
import Cloud.Web.App
import Control.Monad.Reader (ask)
import Cloud.Env (Env(..))
import Cloud.Utils.Logging
import qualified Data.Text as Text


-- nead to provider a bearer token to EmailServiceAPI calls

data Email = Email Text (Maybe Bool)
    deriving (Generic, Show, Eq)

type EmailAPI = "cloud" :> "onboarding"
    :> Header "Authorization" Text
    :> ReqBody '[JSON] Email
    :> Put '[JSON] NoContent

instance ToJSON Email where
    toJSON :: Email -> Value
    toJSON (Email email Nothing) = object
        [ "email" .= email
        ]
    toJSON (Email email (Just receiveNewsletter)) = object
        [ "email" .= email,
          "receive_newsletter" .= receiveNewsletter
        ]

emailApi :: Proxy EmailAPI
emailApi = Proxy

emailClient :: Maybe Text -> Email -> ClientM NoContent
emailClient = client emailApi

registerEmail :: Email -> WebApp ()
registerEmail email = do
    Env {envEmailServiceToken, envEmailClientEnv} <- ask
    case envEmailClientEnv of
        Nothing -> do
            logErrorText "Email client environment not initialized"
            return ()
        Just env -> do
            res <- liftIO $ runClientM (emailClient envEmailServiceToken email) env
            case res of
                Left err ->
                    logErrorText $ Text.pack $ "Failed to register email: " ++ show err
                Right _ -> return ()