module Cloud.Env
  ( Env (..),
  )
where

import Amazonka qualified as S3
import Amazonka.S3 qualified as S3
import Cloud.Byoc.Env (ClusterEnv)
import Cloud.Client.Types (Client, ClientId, NimbusConfig)
import Cloud.Postgres.Env (PostgresEnv)
import Cloud.Prelude
import Cloud.Stripe.API (StripeConfig)
import Cloud.User.Env (AuthEnv)
import Cloud.Utils.Logging.Types qualified as Logging
import Database.Redis qualified as R
import Network.Socket (HostName, ServiceName)
import Network.URI (URI)
import Servant qualified as S
import Servant.Client qualified as S
import System.Log.FastLogger (FormattedTime, LogStr)
import System.Log.Raven.Types (SentryService)
import UnliftIO

data Env reqCtx = Env
  { envServerHostname :: HostName,
    envClientPort :: ServiceName,
    envClients :: TVar (Map ClientId Client),
    envCloudUiOrigin :: URI, -- E.g. "https://app.unison.cloud"
    envCloudHomepageOrigin :: URI, -- E.g. "https://www.unison.cloud"
    envCommitHash :: Text,
    envEmailClientEnv :: Maybe S.ClientEnv,
    envEmailServiceToken :: Maybe Text,
    envApiOrigin :: URI, -- E.g. "https://api.unison-lang.org"
    consulClientEnv :: S.ClientEnv,
    envLogger :: LogStr -> IO (),
    envMinLogSeverity :: Logging.Severity,
    envTimeCache :: IO FormattedTime,
    postgresEnv :: PostgresEnv,
    clusterEnv :: ClusterEnv,
    authEnv :: AuthEnv,
    envNimbusConfig :: NimbusConfig,
    envEnvironmentsMount :: Text,
    envVaultToken :: Text,
    envVaultClientEnv :: S.ClientEnv,
    cloudServicesBucket :: S3.BucketName,
    s3Env :: S3.Env,
    envRedisConnection :: R.Connection,
    envRequestCtx :: reqCtx,
    envSentryService :: SentryService,
    envServerPort :: Int,
    envZendeskAuth :: S.BasicAuthData,
    envStripeConfig :: StripeConfig
  }
