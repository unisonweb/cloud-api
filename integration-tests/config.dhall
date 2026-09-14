let Prelude =
      https://raw.githubusercontent.com/dhall-lang/dhall-lang/v22.0.0/Prelude/package.dhall
        sha256:1c7622fdc868fe3a23462df3e6f533e50fdc12ecf3b42c0bb45c328ec8c4293e

let Compose =
      https://raw.githubusercontent.com/sbdchd/dhall-docker-compose/191bd80809ec2b68429d7f29c37233fef135483f/compose/v3/package.dhall
        sha256:baaa593a2b573bed109daf58662067cd5d1667f8cf186d2ed95b532269a850dc

let nimbusImage = "\${DOCKER_REGISTRY}/nimbus-with-test-configs:\${BUILD_TAG}"

let byocImage = "\${DOCKER_REGISTRY}/nimbus-with-byoc-configs:\${BUILD_TAG}"

let consul = { host = "consul", port = 8500 }

let consulUri =
      "http://" ++ consul.host ++ ":" ++ Prelude.Natural.show consul.port

let dynamo =
      { type = "local"
      , host = "unison-test-dynamo"
      , port = 8000
      , credentials = { accessKey = "myAccessKey", secretKey = "mySecretKey" }
      }

let nimbusBindPorts = { client = 17010, http = 17011, tcp = 17012 }

let Ports = { client : Natural, http : Natural, tcp : Natural }

let NimbusInstance =
      { host : Text
      , bindPorts : Ports
      , allocIndex : Natural
      , nodeType : Optional Text
      }

let leftPadTo2Digits =
      \(n : Natural) ->
        let text = Prelude.Natural.show n

        in  if Prelude.Natural.greaterThan n 9 then text else "0" ++ text

let testNodeId =
      \(shardIndex : Natural) ->
      \(locationIndex : Natural) ->
        leftPadTo2Digits shardIndex ++ leftPadTo2Digits locationIndex

let testInstance
    : Natural ->
      Natural ->
      Natural ->
      Natural ->
      Text ->
      Optional Text ->
        NimbusInstance
    = \(shardCount : Natural) ->
      \(locationCount : Natural) ->
      \(shardIndex : Natural) ->
      \(locationIndex : Natural) ->
      \(hostPrefix : Text) ->
      \(nodeType : Optional Text) ->
        let allocIndex = shardIndex * locationCount + locationIndex

        let nodeId = testNodeId shardIndex locationIndex

        in  { host = hostPrefix ++ nodeId
            , bindPorts = nimbusBindPorts
            , allocIndex
            , nodeType
            }

let instances =
      \(shardCount : Natural) ->
      \(locationCount : Natural) ->
      \(hostPrefix : Text) ->
      \(nodeType : Optional Text) ->
        let lol =
              Prelude.List.generate
                shardCount
                (List NimbusInstance)
                ( \(shardIndex : Natural) ->
                    Prelude.List.generate
                      locationCount
                      NimbusInstance
                      ( \(locationIndex : Natural) ->
                          testInstance
                            shardCount
                            locationCount
                            shardIndex
                            locationIndex
                            hostPrefix
                            nodeType
                      )
                )

        in  Prelude.List.concat NimbusInstance lol

let clientConfig =
      \(instances : List NimbusInstance) ->
        let nodes =
              Prelude.List.map
                NimbusInstance
                { host : Text, port : Natural, httpPort : Natural }
                ( \(instance : NimbusInstance) ->
                    { host = instance.host
                    , port = instance.bindPorts.client
                    , httpPort = instance.bindPorts.http
                    }
                )
                instances

        let clusterMap = {
          unison = [ "141c4ddf-2423-4f10-a4de-465939951354" ]
        }

        in  { consulUri, dynamo, nodes, clusterMap }

let nimbusInstanceToDockerService =
      \(nimbusImage : Text) ->
      \(shardCount : Natural) ->
      \(locationCount : Natural) ->
      \(instance : NimbusInstance) ->
        let envForSure =
              { NIMBUS_CONFIG_DIR = "/etc/nimbus/cfg"
              , NIMBUS_ALLOC_INDEX = Prelude.Natural.show instance.allocIndex
              , NIMBUS_SHARD_COUNT = Prelude.Natural.show shardCount
              , NIMBUS_LOCATION_COUNT = Prelude.Natural.show locationCount
              , NIMBUS_PORT_CLIENT_MSGS =
                  Prelude.Natural.show nimbusBindPorts.client
              , NIMBUS_PORT_PUBLIC = Prelude.Natural.show nimbusBindPorts.http
              , NIMBUS_PORT_GOSSIP_TCP =
                  Prelude.Natural.show nimbusBindPorts.tcp
              , NIMBUS_MINIO_412_WORKAROUND = "true"
              }

        let envMaybe = { NIMBUS_NODE_TYPE = instance.nodeType }

        let env =
                toMap envForSure
              # Prelude.Map.unpackOptionals Text Text (toMap envMaybe)

        in  { mapKey = instance.host
            , mapValue = Compose.Service::{
              , image = Some nimbusImage
              , environment = Some (Compose.ListOrDict.Dict env)
              , depends_on = Some
                [ "cloud-api"
                , "consul"
                , "vault"
                , "unison-test-dynamo"
                , "outbound-http-proxy"
                ]
              , stop_grace_period = Some "1m"
              }
            }

let dockerComposeServices =
      \(shardCount : Natural) ->
      \(locationCount : Natural) ->
      \(instances : List NimbusInstance) ->
      \(dockerImage : Text) ->
        Prelude.List.map
          NimbusInstance
          (Prelude.Map.Entry Text Compose.Service.Type)
          (nimbusInstanceToDockerService dockerImage shardCount locationCount)
          instances

in  { large =
        let dockerImage = nimbusImage

        let daemonShardCount = 1

        let publicShardCount = 1

        let daemonLocationCount = 1

        let publicLocationCount = 2

        let interactiveShardCount = 1

        let interactiveLocationCount = 3

        let daemonHostPrefix = "nimbus-unison-daemon-"

        let publicHostPrefix = "nimbus-public-daemon-"

        let interactiveHostPrefix = "nimbus-"

        let daemonInstances =
              instances
                daemonShardCount
                daemonLocationCount
                daemonHostPrefix
                (Some "unison-daemon")

        let publicInstances =
              instances
                publicShardCount
                publicLocationCount
                publicHostPrefix
                (Some "public-daemon")

        let interactiveInstances =
              instances
                interactiveShardCount
                interactiveLocationCount
                interactiveHostPrefix
                (Some "interactive")

        let dockerComposeServices =
                dockerComposeServices
                  daemonShardCount
                  daemonLocationCount
                  daemonInstances
                  dockerImage
              # dockerComposeServices
                  interactiveShardCount
                  interactiveLocationCount
                  interactiveInstances
                  dockerImage
              # dockerComposeServices
                  publicShardCount
                  publicLocationCount
                  publicInstances
                  dockerImage

        in  { clientConfig = clientConfig interactiveInstances
            , dockerComposeContents = Compose.Config::{
              , services = Some dockerComposeServices
              }
            }
    , small =
        let dockerImage = nimbusImage

        let daemonShardCount = 1

        let publicShardCount = 1

        let daemonLocationCount = 1

        let publicLocationCount = 1

        let interactiveShardCount = 1

        let interactiveLocationCount = 2

        let daemonHostPrefix = "nimbus-unison-daemon-"

        let publicHostPrefix = "nimbus-public-daemon-"

        let interactiveHostPrefix = "nimbus-"

        let daemonInstances =
              instances
                daemonShardCount
                daemonLocationCount
                daemonHostPrefix
                (Some "unison-daemon")

        let publicInstances =
              instances
                publicShardCount
                publicLocationCount
                publicHostPrefix
                (Some "public-daemon")

        let interactiveInstances =
              instances
                interactiveShardCount
                interactiveLocationCount
                interactiveHostPrefix
                (Some "interactive")

        let dockerComposeServices =
                dockerComposeServices
                  daemonShardCount
                  daemonLocationCount
                  daemonInstances
                  dockerImage
              # dockerComposeServices
                  interactiveShardCount
                  interactiveLocationCount
                  interactiveInstances
                  dockerImage
              # dockerComposeServices
                  publicShardCount
                  publicLocationCount
                  publicInstances
                  dockerImage

        in  { clientConfig = clientConfig interactiveInstances
            , dockerComposeContents = Compose.Config::{
              , services = Some dockerComposeServices
              }
            }
    , byoc =
        let shardCount = 1

        let locationCount = 1

        let hostPrefix = "byoc-"

        let clusteredInstances =
              instances shardCount locationCount hostPrefix (None Text)

        let dockerImage = byocImage

        in  { clientConfig = clientConfig clusteredInstances
            , dockerComposeContents = Compose.Config::{
              , services = Some
                  ( dockerComposeServices
                      shardCount
                      locationCount
                      clusteredInstances
                      dockerImage
                  )
              }
            }
    }
