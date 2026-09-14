{-# LANGUAGE OverloadedStrings #-}

module Cloud.Domain.Impl where

import Cloud.Consul.API
  ( GetResponse (..),
    ListResponse (..),
    ConsulIndex,
    deleteKey',
    listKeys,
    readKey,
    updateKey',
  )
import Cloud.Domain.API (DomainAPI)
import Cloud.Domain.Types
  ( DomainDetails (DomainDetails),
    DomainName (..),
  )
import Cloud.Errors (respondError)
import Cloud.Postgres.Ops qualified as PGO
import Cloud.Prelude
import Cloud.Service.Types (ServiceName)
import Cloud.User.Types (CloudTier (..), User (..))
import Cloud.User.UserHandle (UserHandle (..))
import Cloud.Web.App (WebApp)
import Cloud.Web.Errors (CloudWebError (..))
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Types (status404)
import Servant
  ( HasServer (ServerT),
    NoContent (..),
    type (:<|>) ((:<|>)),
  )
import Servant.Client (ClientError (..), ResponseF (responseStatusCode))
import Servant.Client qualified as S
import Share.OAuth.Types (UserId)
import Text.Regex.TDFA ((=~))
import Data.Maybe (catMaybes)
import Control.Monad (unless)
import Cloud.Web.Types (serviceNameFromTextMaybe, serviceNameToText)
import Cloud.Web.Environment (Env(..))
import Control.Monad.Reader (ask)

server :: ServerT DomainAPI WebApp
server =
  listDomainsEndpoint
    :<|> createDomainEndpoint
    :<|> getDomainEndpoint
    :<|> deleteDomainEndpoint

listDomainsEndpoint :: UserId -> WebApp [DomainDetails]
listDomainsEndpoint userId = do
  Env { consulClientEnv } <- ask
  User {handle} <- PGO.expectUserById userId
  let (UserHandle handleTxt) = handle
  let key = "userdomains/" <> handleTxt
  res <- liftIO $ S.runClientM (listKeys key Nothing) consulClientEnv
  case res of
    Left err -> do
      if is404Error err
        then pure []
        else do
          respondError $ InternalError $ Text.pack $ "Consul error: " <> show err
    Right (_, ListResponse r) ->
      catMaybes
        <$> traverse (fmap (fmap fst) . getDomain handle)
          ( foldr
              ( \x acc ->
                  let suffix = Text.drop (Text.length key + 1) x
                   in if Text.null suffix
                        then acc
                        else DomainName suffix : acc
              )
              []
              r
          )
      --pure $
      --    foldr
      --      ( \x acc ->
      --          let suffix = Text.drop (Text.length key + 1) x
      --           in if Text.null suffix
      --                then acc
      --                else suffix : acc
      --      )
      --      []
      --      r

createDomainEndpoint :: UserId -> DomainName -> ServiceName -> WebApp DomainDetails
createDomainEndpoint userId domain serviceName = do
  Env { consulClientEnv } <- ask
  User {handle} <- PGO.expectUserById userId
  let (DomainName domainTxt) = domain
  let (UserHandle handleTxt) = handle
  tier <- PGO.userCloudTier userId
  case tier of
    Free ->
      respondError $ CloudRequiresSubscription userId
    _ -> do
      unless (isValidDomain domainTxt) $ respondError $ InvalidDomainName domain
      old <- getDomain handle domain
      case old of
        Just (dd@(DomainDetails _ oldServiceName), cas) ->
          if oldServiceName == serviceName
            then return dd
            else update handleTxt domainTxt consulClientEnv (Just cas)
        _ -> do
          checkDomainUniqueness domain
          update handleTxt domainTxt consulClientEnv Nothing
  where
    update handleTxt domainTxt consulEnv cas = do
      let key = "userdomains/" <> handleTxt <> "/" <> domainTxt
      res <- liftIO $ S.runClientM (updateKey' key (Text.encodeUtf8 $ serviceNameToText serviceName) Nothing cas Nothing Nothing) consulEnv
      case res of
        Left err -> do
          respondError $ InternalError $ Text.pack $ "Consul error: " <> show err
        Right _ ->
          return $ DomainDetails domain serviceName

domainRegex :: String
domainRegex = "^[a-zA-Z0-9-]+(\\.[a-zA-Z0-9-]+)*\\.[a-zA-Z]{2,}$"

isValidDomain :: Text -> Bool
isValidDomain domain = Text.unpack domain =~ domainRegex

getDomain :: UserHandle -> DomainName -> WebApp (Maybe (DomainDetails, ConsulIndex))
getDomain user domainName = do
  Env { consulClientEnv } <- ask
  let (DomainName domainTxt) = domainName
  let (UserHandle handleTxt) = user
  res <- liftIO $ S.runClientM (readKey False ("userdomains/" <> handleTxt <> "/" <> domainTxt)) consulClientEnv
  case res of
    Left err -> do
      if is404Error err
        then pure Nothing
        else do
          respondError $ InternalError $ Text.pack $ "Consul error: " <> show err
    Right Nothing -> pure Nothing
    Right (Just r) -> do
      let serviceNameText = responseValue r
      serviceName <- case serviceNameFromTextMaybe serviceNameText of
        Nothing -> respondError $ InvalidName serviceNameText
        Just sn -> pure sn
      pure $ Just (DomainDetails domainName serviceName, updateIndex r)

is404Error :: ClientError -> Bool
is404Error (FailureResponse _ response) = responseStatusCode response == status404
is404Error _ = False

checkDomainUniqueness :: DomainName -> WebApp ()
checkDomainUniqueness dn@(DomainName name) = do
  Env { consulClientEnv } <- ask
  res <- liftIO $ S.runClientM (listKeys "userdomains/" Nothing) consulClientEnv
  case res of
    Left err -> do
      liftIO $ print err
      if is404Error err
        then return ()
        else do
          respondError $ InternalError $ Text.pack $ "Consul error: " <> show err
    Right (_, ListResponse domains) ->
      when (any (Text.isInfixOf ("/" <> name)) domains) $ respondError $ DomainInUse dn

getDomainEndpoint :: UserId  -> DomainName -> WebApp DomainDetails
getDomainEndpoint userId domain = do
  User {handle} <- PGO.expectUserById userId
  tier <- PGO.userCloudTier userId
  case tier of
    Free ->
      respondError $ CloudRequiresSubscription userId
    _ ->
      getDomain handle domain >>= \case
        Nothing -> respondError $ DomainNotFound domain
        Just (d, _) -> return d

deleteDomainEndpoint :: UserId -> DomainName -> WebApp NoContent
deleteDomainEndpoint userId domain = do
  Env { consulClientEnv } <- ask
  User {handle} <- PGO.expectUserById userId
  let DomainName domainName = domain
  let (UserHandle handleTxt) = handle
  res <- liftIO $ S.runClientM (deleteKey' ("userdomains/" <> handleTxt <> "/" <> domainName) Nothing Nothing) consulClientEnv
  case res of
    Left err -> do
      respondError $ InternalError $ Text.pack $ "Consul error: " <> show err
    Right _ ->
      return NoContent
