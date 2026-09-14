{{ $logicalLocationCount := env "NIMBUS_LOCATION_COUNT" | parseUint }}
{{ $cloudApiHost := or (env "NIMBUS_CLOUD_API_HOST") "cloud-api" }}
{
  "environment" : "local",
  "bindPorts": {
    "publicHttp" : {{ env "NIMBUS_PORT_PUBLIC" | parseUint }},
    "tcp" : {{ env "NIMBUS_PORT_GOSSIP_TCP" | parseUint }},
    "client" : {{ env "NIMBUS_PORT_CLIENT_MSGS" | parseUint }}
  },
  "clusterMap": {
  },
  "blobFetcher": {
    "bucket": "unison-cloud-services",
    "awsConfig": {
      "credentials": {
        "accessKey": "unison-test",
        "secretKey": "sekret-for-tests"
      },
      "hostName": "unison-test-s3",
      "port": 9000,
      "region": "us-west-2"
    }
  },
  "userBlobFetcher": {
    "bucket": "unison-cloud-user-blobs",
    "awsConfig": {
      "credentials": {
        "accessKey": "unison-test",
        "secretKey": "sekret-for-tests"
      },
      "hostName": "unison-test-s3",
      "port": 9000,
      "region": "us-west-2"
    }
  },
  "vault": {
    "host": "vault",
    "port": 8200,
    "scheme": "http",
    "token": "vault-plaintext-root-token"
  },
  "dynamo": {
    "credentials": {
      "accessKey": "myAccessKey",
      "secretKey": "mySecretKey"
    },
    "host": "unison-test-dynamo",
    "port": 8000,
    "type": "local"
  },
  "shards": {
    "allocationIndex" : {{ env "NIMBUS_ALLOC_INDEX" | parseUint }},
    "logicalLocationCount" : {{ $logicalLocationCount }},
    "shardCount" : {{ env "NIMBUS_SHARD_COUNT" | parseUint }}
  },
  "blockedUsers" : {{ keyOrDefault "nimbus/blockedUsers" "[]" }},
  "cloudApiToken" : "705da529-68b8-4a0d-a499-b1e3f94a4f3e",
  "cloudApiInstances" : [
    {
      "uri" : "http://{{ $cloudApiHost }}:5424"
    }
  ],
  "tcpConfig" : {
    "type": "userIds",
    "userIds": [ "1f13c72eb55446229d8efc5a603700a2" ]
  }

}
