{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module Cloud.Web.Errors
  ( BadRequest (..),
    CloudWebError (..),
    EntityMissing (..),
    ErrorID (..),
    UnauthenticatedError (..),
    internalServerError,
    or403,
    or404,
    reportError,
    ToServerError (..),
  )
where

import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Domain.Types (DomainName)
import Cloud.Errors
import Cloud.Prelude
import Cloud.Service.Types (ServiceId, ServiceName)
import Cloud.User.UserHandle (UserHandle)
import Cloud.Utils.Logging
import Cloud.Utils.Logging qualified as Logging
import Cloud.Web.App
import Crypto.Hash (SHA256)
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Int (Int32)
import Data.Text (pack)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Text.Encoding qualified as Text
import Servant
import Share.OAuth.Types (UserId)
import Share.Utils.IDs qualified as IDs
import Share.Utils.Show (tShow)
import Cloud.Byoc.Env (ClusterId)
import Cloud.Consul.API (ServiceInstanceId, serviceInstanceIdToText)
import Cloud.Web.Types (serviceNameToText)

data EntityMissing = EntityMissing {entityMissingErrorID :: ErrorID, errorMsg :: Text}

instance Show EntityMissing where
  show EntityMissing {errorMsg} = "Entity Missing: " <> show errorMsg

instance Loggable EntityMissing where
  toLog EntityMissing {errorMsg} = withSeverity UserFault $ textLog errorMsg

instance ToServerError EntityMissing where
  toServerError (EntityMissing {entityMissingErrorID}) = (entityMissingErrorID, err404 {errBody = "Not Found"})

data HashMismatch = HashMismatch {expected :: SHA256, actual :: SHA256}
  deriving stock (Show)

instance Loggable HashMismatch where
  toLog HashMismatch {expected, actual} =
    withSeverity UserFault $
      textLog $
        pack $
          "Hash mismatch: expected " <> show expected <> " but got " <> show actual

instance ToServerError HashMismatch where
  toServerError _ = (ErrorID "Hash Mismatch", err400 {errBody = "Hash Mismatch"})

data UnauthenticatedError = UnauthenticatedError
  deriving stock (Show)

instance Logging.Loggable UnauthenticatedError where
  toLog = Logging.withSeverity Logging.UserFault . Logging.showLog

instance ToServerError UnauthenticatedError where
  toServerError _ = (ErrorID "unauthenticated", err401 {errBody = "Unauthenticated"})

data NotAuthorized = NotAuthorized deriving (Show)

instance Loggable NotAuthorized where
  toLog _ = withSeverity UserFault $ textLog "Not Authorized"

instance ToServerError NotAuthorized where
  toServerError _ = (ErrorID "Not Authorized", err403)

data ErrorRedirect = ErrorRedirect Text URI
  deriving stock (Show)

instance Loggable ErrorRedirect where
  toLog (ErrorRedirect msg _) = withSeverity Error $ textLog msg

instance ToServerError ErrorRedirect where
  toServerError (ErrorRedirect errorID redirectURI) =
    ( ErrorID errorID,
      err302
        { errHeaders = [("Location", BS.pack $ show redirectURI)]
        }
    )

or403 :: WebApp Bool -> WebApp ()
or403 m =
  m >>= (\b -> if b then pure () else respondError NotAuthorized)

or404 :: WebApp (Maybe a) -> EntityMissing -> WebApp a
or404 m err =
  m >>= \case
    Nothing -> respondError err
    Just b -> pure b

-- | Various Error types that the Share UI knows how to interpret
data ShareUIError
  = UnspecifiedError
  | AccountCreationGitHubPermissionsRejected
  | AccountCreationHandleAlreadyTaken
  | AccountCreationInvalidHandle
  deriving (Show)

data Unimplemented = Unimplemented

instance ToServerError Unimplemented where
  toServerError Unimplemented = (ErrorID "unimplemented", err501 {errBody = "Not Implemented"})

instance Loggable Unimplemented where
  toLog Unimplemented = withSeverity Error . textLog $ "Unimplemented"

newtype BadRequest = BadRequest Text

instance ToServerError BadRequest where
  toServerError (BadRequest msg) = (ErrorID "bad-request", err400 {errBody = BL.fromStrict . Text.encodeUtf8 $ msg})

instance Loggable BadRequest where
  toLog (BadRequest msg) = withSeverity UserFault . textLog $ msg

data InvalidParam = InvalidParam {paramName :: Text, param :: Text, parseError :: Text}

instance ToServerError InvalidParam where
  toServerError (InvalidParam {paramName, parseError}) =
    ( ErrorID $ "invalid-param:" <> paramName,
      err400
        { errReasonPhrase = "Invalid Parameter",
          errBody = BL.fromStrict . Text.encodeUtf8 $ "Unable to parse parameter " <> paramName <> ", " <> parseError
        }
    )

instance Loggable InvalidParam where
  toLog (InvalidParam {paramName, param, parseError}) =
    withSeverity UserFault . textLog $
      "Invalid Parameter: " <> paramName <> ". value: " <> tShow param <> ", error: " <> parseError

-- | Box up server errors of any type into the same type.
-- This is handy when "throwing" into ExceptT in things like PG transactions
-- where there are many possible errors, but we're just going to throw them in the App
-- monad outside of the transaction anyways.
data SomeServerError where
  SomeServerError :: (ToServerError e, Loggable e) => e -> SomeServerError

instance ToServerError SomeServerError where
  toServerError (SomeServerError e) = toServerError e

instance Loggable SomeServerError where
  toLog (SomeServerError e) = toLog e

data CloudWebError
  = InternalError Text
  | UserNotFoundForHandle UserHandle
  | UserNotFoundForId UserId
  | DomainNotFound DomainName
  | DomainInUse DomainName
  | CloudRequiresSubscription UserId
  | CloudNotAuthorized
  | CloudNotCloudAccount
  | CloudNotAuthenticated
  | ServiceTooLarge
  | InvalidServicesVersion Int32
  | ServiceIdNotFound ServiceId
  | NoCurrentDeploymentForService ServiceId
  | ServiceNameNotFound ServiceName
  | InvalidSearchString Text
  | InvalidDomainName DomainName
  | InvalidURI Text
  | InvalidDeployment DeploymentHash
  | InvalidName Text
  | MissingParameter Text
  | UnknownServiceInstance ClusterId ServiceInstanceId

instance Loggable CloudWebError where
  toLog (InternalError txt)= withSeverity Error $ textLog $ "Internal Server Error: " <> tshow txt
  toLog (UserNotFoundForId uid) = withSeverity UserFault $ textLog $ "User not found for id: " <> IDs.toText uid
  toLog (DomainNotFound domain) = withSeverity UserFault $ textLog $ "Domain not found: " <> tshow domain
  toLog (DomainInUse domain) = withSeverity UserFault $ textLog $ "Domain already in use: " <> tshow domain
  toLog (UserNotFoundForHandle userHandle) = withSeverity UserFault $ textLog $ "User not found for handle: " <> tShow userHandle
  toLog CloudNotAuthorized = withSeverity UserFault $ textLog "Not authorized"
  toLog CloudNotCloudAccount = withSeverity UserFault $ textLog "Not a unison cloud account"
  toLog (CloudRequiresSubscription uid) = withSeverity UserFault $ textLog $ "User " <> IDs.toText uid <> " requires a subscription"
  toLog CloudNotAuthenticated = withSeverity UserFault $ textLog "Must be logged in"
  toLog ServiceTooLarge = withSeverity UserFault $ textLog "Service is too Large"
  toLog (InvalidServicesVersion v) = withSeverity UserFault $ textLog $ Text.pack $ "Invalid services version: " <> show v
  toLog (InvalidDomainName n) = withSeverity UserFault $ textLog $ Text.pack $ "Invalid DomainName: " <> show n
  toLog (ServiceIdNotFound v) = withSeverity UserFault $ textLog $ Text.pack $ "ServiceId not found for id: " <> show v
  toLog (NoCurrentDeploymentForService s) = withSeverity UserFault $ textLog $ Text.pack $ "There is not a currently assigned deployment for ServiceId: " <> show s
  toLog (ServiceNameNotFound n) = withSeverity UserFault $ textLog $ "ServiceName not found: " <> serviceNameToText n
  toLog (InvalidDeployment h) = withSeverity UserFault $ textLog $ Text.pack $ "Invalid Deployment: " <> show h
  toLog (InvalidSearchString s) = withSeverity UserFault $ textLog $ Text.pack $ "Invalid Search Text: " <> show s
  toLog (InvalidName v) = withSeverity UserFault $ textLog $ Text.pack $ "Invalid Name: " <> show v
  toLog (InvalidURI uri) = withSeverity UserFault $ textLog $ Text.pack $ "Invalid URI: " <> show uri
  toLog (MissingParameter v) = withSeverity UserFault $ textLog $ Text.pack $ "Missing parameter: " <> show v
  toLog (UnknownServiceInstance cluster instanceId) = withSeverity UserFault $ textLog $ "Unknown cluster/instance: " <> tshow cluster <> "/" <> serviceInstanceIdToText instanceId

instance ToServerError CloudWebError where
  toServerError (InternalError _) = (ErrorID "Internal Server Error", err500)
  toServerError (UserNotFoundForId uid) = (ErrorID "user-not-found-for-id", err404 {errBody = BL.fromStrict (encodeUtf8 $ "User not found for id: " <> IDs.toText uid)})
  toServerError (UserNotFoundForHandle userHandle) = (ErrorID "user-not-found-for-handle", err404 {errBody = BL.fromStrict (encodeUtf8 $ "User not found for handle: " <> tShow userHandle)})
  toServerError (DomainNotFound domain) = (ErrorID "domain-not-found", err404 {errBody = BL.fromStrict (encodeUtf8 $ "Domain not found: " <> tshow domain)})
  toServerError (DomainInUse domain) = (ErrorID "domain-in-use", err409 {errBody = BL.fromStrict (encodeUtf8 $ "Domain " <> tshow domain <> " already in use, please contact us if you think this is an error!")})
  toServerError CloudNotAuthorized = (ErrorID "Not authorized", err401 {errBody = BL.fromStrict (encodeUtf8 " Not authorized to access this resource")})
  toServerError CloudNotCloudAccount = (ErrorID "Not authorized", err401 {errBody = BL.fromStrict (encodeUtf8 "Not a unison cloud account. Please sign up for a free account at https://www.unison.cloud/signup/?plan=Free")})
  toServerError CloudNotAuthenticated = (ErrorID "Must be logged in", err401 {errBody = BL.fromStrict (encodeUtf8 "Must be logged in: https://api.unison.cloud/login")})
  toServerError (CloudRequiresSubscription _) = (ErrorID "Requires subscription", err402 {errBody = BL.fromStrict (encodeUtf8 "This feature requires a paid Cloud subscription. see https://www.unison.cloud/pricing/")})
  toServerError ServiceTooLarge = (ErrorID "Service is too Large", err400)
  toServerError (InvalidServicesVersion v) = (ErrorID "Invalid services version", err400 {errBody = BL.fromStrict (encodeUtf8 $ pack $ "Invalid services version: " <> show v)})
  toServerError (InvalidDomainName n) = (ErrorID "Invalid DomainName", err400 {errBody = BL.fromStrict (encodeUtf8 $ pack $ "Invalid domain name: " <> show n)})
  toServerError (ServiceIdNotFound v) = (ErrorID "service-id-not-found", err404 {errBody = BL.fromStrict (encodeUtf8 $ pack $ "ServiceId not found: " <> show v)})
  toServerError (NoCurrentDeploymentForService s) = (ErrorID "service-id-no-current-deployment", err404 {errBody = BL.fromStrict (encodeUtf8 $ pack $ "No current deployment for ServiceId: " <> show s)})
  toServerError (ServiceNameNotFound n) = (ErrorID "Invalid ServiceName", err404 {errBody = BL.fromStrict (encodeUtf8 $ "ServiceName not found: " <> serviceNameToText n)})
  toServerError (InvalidDeployment h) = (ErrorID "Invalid Deployment", err400 {errBody = BL.fromStrict (encodeUtf8 $ pack $ "Invalid Deployment: " <> show h)})
  toServerError (InvalidSearchString s) = (ErrorID "Invalid Search Text", err400 {errBody = BL.fromStrict (encodeUtf8 $ pack $ "Invalid Search Text: " <> show s)})
  toServerError (InvalidName v) = (ErrorID "Invalid Name", err400 {errBody = BL.fromStrict (encodeUtf8 $ pack $ "Invalid Name: " <> show v <> "Names must be less than 64 characters, start with a letter, and may only contain: a-z, A-Z, 0-9, or -.")})
  toServerError (InvalidURI uri) = (ErrorID "Invalid URI", err400 {errBody = BL.fromStrict (encodeUtf8 $ pack $ "Invalid URI: " <> show uri)})
  toServerError (MissingParameter v) = (ErrorID "Missing parameter", err400 {errBody = BL.fromStrict (encodeUtf8 $ pack $ "Missing parameter: " <> show v)})
  toServerError (UnknownServiceInstance cluster instanceId) = (ErrorID "unknown-service-instance", err404 {errBody = BL.fromStrict (encodeUtf8 $ "Unknown cluster/service instance: " <> tshow cluster <> "/" <> serviceInstanceIdToText instanceId)})
