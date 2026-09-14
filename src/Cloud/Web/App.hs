module Cloud.Web.App
  ( addRequestTag,
    -- cloudPath,
    -- cloudPathQ,
    isCloudUILink,
    freshRequestCtx,
    getTags,
    localRequestCtx,
    RequestCtx (..),
    RequestId (..),
    shouldUseCaching,
    WebApp,
    withLocalTag,
  )
where

import Cloud.App
import Cloud.Env
import Cloud.Prelude
-- import Cloud.Web.Types (RequestId)
import Cloud.Utils.Logging
  ( LogMsg (severity, tags),
    MonadLogger (..),
    logFmtFormatter,
  )
import Control.Monad.Reader (MonadReader (ask, local), asks)
import Data.Aeson (FromJSON, ToJSON)
import Data.Map qualified as Map
import Network.URI (URI)
import Network.URI qualified as URI
import Servant (FromHttpApiData, ToHttpApiData)
import Share.OAuth.Types (UserId)
import Share.Utils.Show (tShow)
import UnliftIO.STM
  ( TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVarIO,
  )

type WebApp = AppM RequestCtx

newtype RequestId = RequestId Text
  deriving stock (Eq, Ord)
  deriving (Show, FromHttpApiData, ToHttpApiData, ToJSON, FromJSON) via Text

-- | Context which is local to a single request.
data RequestCtx = RequestCtx
  { useCaching :: Bool,
    requestId :: Maybe RequestId,
    authenticatedUser :: Maybe UserId,
    -- Tags which apply to the entire request
    reqTagsVar :: TVar (Map Text Text),
    -- Context specific tags which will be appended to log messages.
    -- Often useful when performing an operation in a loop over a set of things and you want
    -- to know which thing you were working with when a given log or error occurred.
    localTags :: Map Text Text,
    pathInfo :: [Text],
    -- | The full URI of the request, useful for debugging, don't use this for logic.
    rawURI :: Maybe URI
  }

instance MonadLogger WebApp where
  logMsg msg = do
    log <- asks envLogger
    currentTags <- getTags
    msg <- pure $ msg {tags = tags msg `Map.union` currentTags}
    minSeverity <- asks envMinLogSeverity
    when (severity msg >= minSeverity) $ do
      timestamp <- asks envTimeCache >>= liftIO
      liftIO . log . logFmtFormatter timestamp $ msg

-- | Generate an empty request context
freshRequestCtx :: (MonadIO m) => m RequestCtx
freshRequestCtx = do
  reqTagsVar <- liftIO $ newTVarIO mempty
  pure
    ( RequestCtx
        { useCaching = True,
          requestId = Nothing,
          authenticatedUser = Nothing,
          reqTagsVar,
          localTags = mempty,
          pathInfo = [],
          rawURI = Nothing
        }
    )

-- | Get the tags associated with the current request.
getTags :: (MonadReader (Env RequestCtx) m, MonadIO m) => m (Map Text Text)
getTags = do
  Env {envCommitHash} <- ask
  RequestCtx {useCaching, requestId, authenticatedUser, reqTagsVar, localTags} <- asks envRequestCtx
  reqTags <- liftIO $ readTVarIO reqTagsVar
  pure $
    Map.unions
      [ Map.fromList
          [ ("caching-disabled", showBool $ not useCaching),
            ("request-id", maybe "<none>" tShow requestId),
            ("authenticated-user-id", maybe "<unauthenticated>" tShow authenticatedUser),
            ("commit", tShow envCommitHash)
          ],
        localTags, -- local tags take precedence over request tags
        reqTags
      ]
  where
    showBool :: Bool -> Text
    showBool True = "true"
    showBool False = "false"

-- | Add a tag to the current request. This tag will be used in logging and error reports
addRequestTag :: (MonadReader (Env RequestCtx) m, MonadIO m) => Text -> Text -> m ()
addRequestTag k v = do
  RequestCtx {reqTagsVar} <- asks envRequestCtx
  atomically $ modifyTVar' reqTagsVar (Map.insert k v)

-- | Set a tag within given block. This tag will be used in logging and error reports within
-- that block.
--
-- E.g. If performing an action over many users, we'll want to know which user we were working
-- on when logs or errors occur:
--
-- for users \user -> withLocalTag "user" (userId user) do
--   ...
withLocalTag :: (MonadReader (Env RequestCtx) m, MonadIO m) => Text -> Text -> m a -> m a
withLocalTag k v action = do
  localRequestCtx (\ctx -> ctx {localTags = Map.insert k v $ localTags ctx}) action

localRequestCtx :: (MonadReader (Env RequestCtx) m) => (RequestCtx -> RequestCtx) -> m a -> m a
localRequestCtx f = local \env -> env {envRequestCtx = f (envRequestCtx env)}

shouldUseCaching :: (MonadReader (Env RequestCtx) m) => m Bool
shouldUseCaching =
  asks (useCaching . envRequestCtx)

-- -- | Construct a full URI to a path within Cloud, with provided query params.
-- cloudPathQ :: [Text] -> Map Text Text -> AppM reqCtx URI
-- cloudPathQ pathSegments queryParams = do
--   uri <- asks envApiOrigin
--   pure . setPathAndQueryParams pathSegments queryParams $ uri

-- -- | Construct a full URI to a path within Cloud.
-- cloudPath :: [Text] -> AppM reqCtx URI
-- cloudPath path = cloudPathQ path mempty

-- | Check if a URI is a link to the cloud UI.
-- This is useful for preventing attackers from generating arbitrary redirections in
-- things like login redirects.
isCloudUILink :: URI -> AppM reqCtx Bool
isCloudUILink uri = do
  cloudUI <- asks envCloudUiOrigin
  cloudWebsite <- asks envCloudHomepageOrigin
  let uriAuth = URI.uriAuthority uri
  pure $ URI.uriAuthority cloudUI == uriAuth || URI.uriAuthority cloudWebsite == uriAuth
