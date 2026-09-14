{-# LANGUAGE OverloadedStrings #-}

-- | Golden tests for the cloud-api <-> nimbus websocket wire protocol.
--
-- The JSON files in protocol-fixtures/ are the canonical wire format, shared
-- with the nimbus (Unison) test suite: both sides decode/encode the same
-- fixtures, so protocol drift fails a unit test instead of an integration run.
-- If a test here fails because the protocol changed INTENTIONALLY, update the
-- fixture AND the corresponding nimbus-side test together.
module Cloud.ProtocolFixturesSpec (spec) where

import Cloud.Byoc.Env
import Cloud.Consul.API (CheckStatus (..))
import Cloud.Deployment.DeploymentHash (DeploymentHash (..))
import Cloud.Web.Cluster.Impl
import Cloud.Web.Types (EnvironmentId (..), ServiceId (..), serviceNameFromText)
import Cloud.User.UserHandle (UserHandle (..))
import Data.Aeson (Result (..), Value, eitherDecode, fromJSON, toJSON)
import Data.ByteString.Lazy qualified as BL
import Data.UUID qualified as UUID
import System.Clock (fromNanoSecs)
import Test.Hspec

fixture :: FilePath -> IO BL.ByteString
fixture name = BL.readFile ("protocol-fixtures/" <> name)

fixtureValue :: FilePath -> IO Value
fixtureValue name = do
  bytes <- fixture name
  either (error . ("unparseable fixture: " <>)) pure (eitherDecode bytes)

fixClusterId :: ClusterId
fixClusterId = ClusterId (maybe (error "bad uuid") id (UUID.fromString "ae35ed12-93f9-4915-92d5-4144e804b013"))

fixEnvId :: EnvironmentId
fixEnvId = EnvironmentId (maybe (error "bad uuid") id (UUID.fromString "38ded0c1-3bc1-42b2-ada8-d0cde3ff4226"))

fixServiceId :: ServiceId
fixServiceId = ServiceId (maybe (error "bad uuid") id (UUID.fromString "ca95967d-dbc6-469c-a674-e01cb3d71856"))

spec :: Spec
spec = describe "wire-protocol golden fixtures" $ do
  describe "cloud-api -> node encodes" $ do
    it "HealthRequest" $ do
      expected <- fixtureValue "health-request.json"
      toJSON (HealthRequestMessage (MonoTime (fromNanoSecs 123456789))) `shouldBe` expected

    it "LocationRegistered" $ do
      expected <- fixtureValue "location-registered.json"
      toJSON (LocationRegisteredMessage fixClusterId) `shouldBe` expected

    it "Error" $ do
      expected <- fixtureValue "error.json"
      toJSON (ErrorMsg "Unauthenticated") `shouldBe` expected

    it "EnvironmentInvalidation (legacy, no seq)" $ do
      expected <- fixtureValue "environment-invalidation.json"
      toJSON (EnvironmentInvalidation fixClusterId fixEnvId) `shouldBe` expected

    it "EnvironmentInvalidation stamped with seq" $ do
      expected <- fixtureValue "environment-invalidation-seq.json"
      stampSeq 42 (EnvironmentInvalidation fixClusterId fixEnvId) `shouldBe` expected

    it "UserServiceInvalidation" $ do
      expected <- fixtureValue "user-service-invalidation.json"
      serviceName <- either (error . show) pure (serviceNameFromText "my-service")
      toJSON (UserServiceInvalidation fixClusterId (UserHandle "alice") serviceName) `shouldBe` expected

    it "ServiceIdInvalidation" $ do
      expected <- fixtureValue "service-id-invalidation.json"
      toJSON (ServiceIdInvalidation fixClusterId fixServiceId) `shouldBe` expected

    it "ServiceHashInvalidation" $ do
      expected <- fixtureValue "service-hash-invalidation.json"
      toJSON (ServiceHashInvalidation fixClusterId (DeploymentHash "dowlpdw3tqbh34nsrfzlxot4jcqsx7ccl76mgyvkh7qum65zohja")) `shouldBe` expected

  describe "node -> cloud-api decodes" $ do
    it "HealthResponse" $ do
      bytes <- fixture "health-response.json"
      case eitherDecode bytes of
        Right (HealthResponse n status message) -> do
          monoTimeToNanos n `shouldBe` 123456789
          (status == Passing) `shouldBe` True
          message `shouldBe` Nothing
        Right _ -> expectationFailure "decoded to the wrong IncomingMessage constructor"
        Left err -> expectationFailure ("failed to decode HealthResponse fixture: " <> err)

    it "InvalidationAck" $ do
      bytes <- fixture "invalidation-ack.json"
      case eitherDecode bytes of
        Right (InvalidationAckMsg s applyNanos) -> do
          s `shouldBe` 7
          applyNanos `shouldBe` 51234
        Right _ -> expectationFailure "decoded to the wrong IncomingMessage constructor"
        Left err -> expectationFailure ("failed to decode InvalidationAck fixture: " <> err)

  describe "peer-RPC Event decodes (FromJSON Event mirrors the wire encoding)" $ do
    it "round-trips every invalidation fixture" $ do
      let cases =
            [ "environment-invalidation.json",
              "user-service-invalidation.json",
              "service-id-invalidation.json",
              "service-hash-invalidation.json"
            ]
      mapM_
        ( \name -> do
            v <- fixtureValue name
            case fromJSON v :: Result Event of
              Success ev -> toJSON ev `shouldBe` v
              Error err -> expectationFailure ("FromJSON Event failed on " <> name <> ": " <> err)
        )
        cases
