{-# LANGUAGE DataKinds #-}

module Cloud.Byoc.Types
  ( ByocUserClaims (..),
    DeploymentClaims (..),
    DeploymentLogsClaims (..),
    EnvironmentClaims (..),
    DaemonHashClaims (..),
    JobSubmitClaims (..),
    UserLogsClaims (..),
  )
where

import Cloud.Byoc.Env (ClusterId (..))
import Cloud.Client.Messages (JobId)
import Cloud.Prelude
import Cloud.Web.Types (EnvironmentId)
import Share.JWT
import Share.JWT qualified as ShareJWT
import Share.OAuth.Types (UserId)
import Cloud.Deployment.DeploymentHash (DeploymentHash)

data ByocUserClaims = ByocUserClaims
  { clusterId :: ClusterId,
    userId :: UserId,
    standardClaims :: ShareJWT.StandardClaims
  }
  deriving (Show, Eq)

instance ShareJWT.AsJWTClaims ByocUserClaims where
  toClaims :: ByocUserClaims -> ShareJWT.JWTClaimsMap
  toClaims (ByocUserClaims {..}) =
    ShareJWT.toClaims standardClaims
      & ShareJWT.addClaim "clusterId" clusterId
      & ShareJWT.addClaim "userId" userId
  fromClaims claims = do
    standardClaims <- ShareJWT.fromClaims claims
    userId <- ShareJWT.getClaim "sub" claims
    clusterId <- ShareJWT.getClaim "clusterId" claims
    pure $ ByocUserClaims {..}

claimKeyEnvironmentId :: Text
claimKeyEnvironmentId = "environmentId"

claimKeyTokenType :: Text
claimKeyTokenType = "t"

claimKeyJobId :: Text
claimKeyJobId = "jobId"

claimDeploymentHash :: Text
claimDeploymentHash = "deployHash"

claimDaemonHash :: Text
claimDaemonHash = "daemonHash"

data EnvironmentClaims = EnvironmentClaims
  { environmentId :: EnvironmentId,
    userClaims :: ByocUserClaims
  }
  deriving (Show, Eq)

instance ShareJWT.AsJWTClaims EnvironmentClaims where
  toClaims :: EnvironmentClaims -> ShareJWT.JWTClaimsMap
  toClaims (EnvironmentClaims {..}) =
    ShareJWT.toClaims userClaims
      & ShareJWT.addClaim claimKeyEnvironmentId environmentId
      & ShareJWT.addClaim claimKeyTokenType ("env" :: String)
  fromClaims claims = do
    userClaims <- ShareJWT.fromClaims claims
    environmentId <- ShareJWT.getClaim claimKeyEnvironmentId claims
    typ <- ShareJWT.getClaim claimKeyTokenType claims
    if typ /= "env"
      then Left ("Invalid JWT type:" <> typ)
      else Right ()
    pure $ EnvironmentClaims {..}

data JobSubmitClaims = JobSubmitClaims
  { environmentId :: EnvironmentId,
    jobId :: JobId,
    userClaims :: ByocUserClaims
  }

instance ShareJWT.AsJWTClaims JobSubmitClaims where
  toClaims :: JobSubmitClaims -> ShareJWT.JWTClaimsMap
  toClaims (JobSubmitClaims {..}) =
    ShareJWT.toClaims userClaims
      & ShareJWT.addClaim claimKeyEnvironmentId environmentId
      & ShareJWT.addClaim claimKeyTokenType ("jobSubmit" :: String)
      & ShareJWT.addClaim claimKeyJobId jobId
  fromClaims claims = do
    typ <- ShareJWT.getClaim claimKeyTokenType claims
    if typ /= "jobSubmit"
      then Left ("Invalid JWT type:" <> typ)
      else Right ()
    userClaims <- ShareJWT.fromClaims claims
    environmentId <- ShareJWT.getClaim claimKeyEnvironmentId claims
    jobId <- ShareJWT.getClaim claimKeyJobId claims
    pure $ JobSubmitClaims {..}

newtype UserLogsClaims = UserLogsClaims
  {
    userClaims :: ByocUserClaims
  }

instance ShareJWT.AsJWTClaims UserLogsClaims where
  toClaims (UserLogsClaims {..}) =
    ShareJWT.toClaims userClaims
      & ShareJWT.addClaim claimKeyTokenType ("userLogs" :: String)
  fromClaims claims = do
    typ <- ShareJWT.getClaim claimKeyTokenType claims
    if typ /= "userLogs"
      then Left ("Invalid JWT type:" <> typ)
      else Right ()
    userClaims <- ShareJWT.fromClaims claims
    pure $ UserLogsClaims {..}

data DeploymentLogsClaims = DeploymentLogsClaims
  { deploymentHash :: DeploymentHash,
    start :: Maybe Text,
    userClaims :: ByocUserClaims
  }

instance ShareJWT.AsJWTClaims DeploymentLogsClaims where
  toClaims (DeploymentLogsClaims {..}) =
    ShareJWT.toClaims userClaims
      & ShareJWT.addClaim claimDeploymentHash deploymentHash
      & ShareJWT.addClaim claimKeyTokenType ("deploymentLogs" :: String)
      & ShareJWT.addClaim "start" start
  fromClaims claims = do
    typ <- ShareJWT.getClaim claimKeyTokenType claims
    if typ /= "deploymentLogs"
      then Left ("Invalid JWT type:" <> typ)
      else Right ()
    userClaims <- ShareJWT.fromClaims claims
    deploymentHash <- ShareJWT.getClaim claimDeploymentHash claims
    start <- ShareJWT.getClaim "start" claims
    pure $ DeploymentLogsClaims {..}

data DeploymentClaims = DeploymentClaims
  { deploymentHash :: DeploymentHash,
    userClaims :: ByocUserClaims
  }

instance ShareJWT.AsJWTClaims DeploymentClaims where
  toClaims (DeploymentClaims {..}) =
    ShareJWT.toClaims userClaims
      & ShareJWT.addClaim claimDeploymentHash deploymentHash
      & ShareJWT.addClaim claimKeyTokenType ("deployment" :: String)
  fromClaims claims = do
    typ <- ShareJWT.getClaim claimKeyTokenType claims
    if typ /= "deployment"
      then Left ("Invalid JWT type:" <> typ)
      else Right ()
    userClaims <- ShareJWT.fromClaims claims
    deploymentHash <- ShareJWT.getClaim claimDeploymentHash claims
    pure $ DeploymentClaims {..}

data DaemonHashClaims = DaemonHashClaims
  { daemonHash :: DeploymentHash,
    userClaims :: ByocUserClaims
  }

instance ShareJWT.AsJWTClaims DaemonHashClaims where
  toClaims :: DaemonHashClaims -> ShareJWT.JWTClaimsMap
  toClaims (DaemonHashClaims {..}) =
    ShareJWT.toClaims userClaims
      & ShareJWT.addClaim claimDaemonHash daemonHash
      & ShareJWT.addClaim claimKeyTokenType ("daemonHash" :: String)
  fromClaims claims = do
    typ <- ShareJWT.getClaim claimKeyTokenType claims
    if typ /= "daemonHash"
      then Left ("Invalid JWT type:" <> typ)
      else Right ()
    userClaims <- ShareJWT.fromClaims claims
    daemonHash <- ShareJWT.getClaim claimDaemonHash claims
    pure $ DaemonHashClaims {..}
