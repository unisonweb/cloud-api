{{ $logicalLocationCount := env "NIMBUS_LOCATION_COUNT" | parseUint }}
{{ $cloudApiHost := or (env "NIMBUS_CLOUD_API_HOST") "cloud-api" }}
{
  "environment" : "local",
  {{ if (env "NIMBUS_NODE_TYPE") }}"nodeType": "{{ env "NIMBUS_NODE_TYPE" }}", {{ end }}
  "bindPorts": {
    "publicHttp" : {{ env "NIMBUS_PORT_PUBLIC" | parseUint }},
    "client" : {{ env "NIMBUS_PORT_CLIENT_MSGS" | parseUint }},
    "tcp" : {{ env "NIMBUS_PORT_GOSSIP_TCP" | parseUint }}
  },
  "outboundProxy" : {
    "host" : "outbound-http-proxy",
    "port" : 3128
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
  "clusterMap": {
    "unison": [
      "141c4ddf-2423-4f10-a4de-465939951354"
    ]
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
  "logs": {
    "provider": {
      "type": "loki",
      "uri": "http://unison-test-loki:3100",
      "labels": {
        "job": "nimbus-local"
      }
    }
  },
  "shards": {
    "allocationIndex" : {{ env "NIMBUS_ALLOC_INDEX" | parseUint }},
    "logicalLocationCount" : {{ $logicalLocationCount }},
    "shardCount" : {{ env "NIMBUS_SHARD_COUNT" | parseUint }}
  },
  "blockedUsers" : {{ keyOrDefault "nimbus/blockedUsers" "[]" }},
  "cloudApiToken" : "nruObCVk0VrIzJyTH72HxXAdTf8hsU+cOZKiJ/Y99ARcdXLdzzqK9zB9EDUvrlyKJ9LckJ5uvUY=",
  "cloudApiInstances" : [
    {
      "uri" : "http://{{ $cloudApiHost }}:5424"
    }{{ if env "NIMBUS_CLOUD_API_HOST_2" }},
    {
      "uri" : "http://{{ env "NIMBUS_CLOUD_API_HOST_2" }}:5424"
    }{{ end }}
  ],
  "tcpConfig" : {
    "type": "everybody"
  }
}
