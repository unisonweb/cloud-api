#!/bin/bash


: "${UNISON_CLOUD_LOCAL_TESTS:=false}"
: "${CREATE_TEST_BUCKETS:=$UNISON_CLOUD_LOCAL_TESTS}"
: "${CREATE_VAULT_MOUNT:=$UNISON_CLOUD_LOCAL_TESTS}"
: "${CREATE_DYNAMO_TABLE:=$UNISON_CLOUD_LOCAL_TESTS}"

set -euo pipefail

echo "credentials file info:"
ls -l "$HOME/.local/share/unisonlanguage/credentials.json" || (echo "not found")

# this is a hack to give the nimbus instances some time to initialize before we try to hit them
sleep 10

if [ "$CREATE_TEST_BUCKETS" = true ] ; then
  echo "Creating the test s3 bucket"
  mc alias set test-s3 https://unison-test-s3:9000 unison-test sekret-for-tests
  mc mb --ignore-existing test-s3/unison-cloud-services
  mc mb --ignore-existing test-s3/unison-cloud-user-blobs
fi

if [ "$CREATE_VAULT_MOUNT" = true ] ; then
  if vault secrets list | grep -q environments ; then
     echo "vault mount already exists"
  else
     echo "Creating vault mount"
     vault secrets enable -path=environments kv-v2
  fi
fi

if [ "$CREATE_DYNAMO_TABLE" = true ] ; then
  echo "Creating the test dynamo table"
  aws dynamodb --endpoint=http://unison-test-dynamo:8000 describe-table --table-name test || aws dynamodb --endpoint=http://unison-test-dynamo:8000 create-table --table-name test --attribute-definitions AttributeName=K,AttributeType=B AttributeName=NS,AttributeType=S --key-schema AttributeName=K,KeyType=HASH AttributeName=NS,KeyType=RANGE --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5
fi

exit_status=0

fetchAccessToken() {
  user=$1; shift
  curl --fail-with-body -s -c - "http://${UNISON_CLOUD_HOST}:${UNISON_CLOUD_HTTP_PORT}/local/user/${user}/login" | grep 'cloud-session' | sed -r 's/.*\s+cloud-session\s+(.*)/\1/'
}

if [[ "true" = "${UNISON_CLOUD_LOCAL_TESTS:-}" ]] && [[ -z "${UNISON_CLOUD_ACCESS_TOKEN:-}" ]]; then
  echo "Fetching access token for test user from local cloud-api instance"
  UNISON_CLOUD_ACCESS_TOKEN=$(fetchAccessToken "test")
  export UNISON_CLOUD_ACCESS_TOKEN
fi

if [[ "true" = "${UNISON_CLOUD_LOCAL_TESTS:-}" ]] && [[ -z "${UNISON_CLOUD_TEST_ORGUSER_ACCESS_TOKEN:-}" ]]; then
  echo "Fetching access token for test org user from local cloud-api instance"
  UNISON_CLOUD_TEST_ORGUSER_ACCESS_TOKEN=$(fetchAccessToken "transcripts")
  export UNISON_CLOUD_TEST_ORGUSER_ACCESS_TOKEN
  UNISON_CLOUD_TEST_ORG_ID="U-e5e7635c-8db2-4b7f-9fee-86ee8d120ef9"
  export UNISON_CLOUD_TEST_ORG_ID
fi

if [[ "true" = "${UNISON_CLOUD_LOCAL_TESTS:-}" ]] && [[ -z "${UNISON_CLOUD_TEST_BADUSER_ACCESS_TOKEN:-}" ]]; then
  echo "Fetching access token for test bad user from local cloud-api instance"
  UNISON_CLOUD_TEST_BADUSER_ACCESS_TOKEN=$(fetchAccessToken "badscripts")
  export UNISON_CLOUD_TEST_BADUSER_ACCESS_TOKEN
fi

/usr/bin/ucm --codebase /root/nimbus transcript.fork /usr/share/nimbus/integration-tests/transcript.md || exit_status=$?

# this is a hack to give the nimbus instances some time to log failures before we shut them down.
sleep 5

cat /usr/share/nimbus/integration-tests/transcript.output.md

exit "$exit_status"
