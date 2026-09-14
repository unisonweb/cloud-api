#!/bin/bash

# The main thing that this wrapper script does is watch for changes in
# NIMBUS_CONFIG_DIR and hit the endpoint to make nimbus reload its config when
# they change. This is mostly done because Unison doesn't currently have
# builtins for handling interrupts or watching files.
#
# This script also provides support for polling EC2 IAM credentials and updating
# the nimbus config to include them. To enable this, set
# NIMBUS_POLL_IAM_CREDENTIALS=1
set -euo pipefail

: "${NIMBUS_CONFIG_DIR:=}"

: "${NIMBUS_CONFIG_FILE:=/run/nimbus/config-merged.json}"
export NIMBUS_CONFIG_FILE

mkdir -p "$(dirname "$NIMBUS_CONFIG_FILE")"

: "${NIMBUS_AWS_CREDENTIALS_PATH:=${NIMBUS_CONFIG_DIR}/aws-credentials.json}"

: "${NIMBUS_POLL_IAM_CREDENTIALS:=}"

: "${NIMBUS_VAULT_TOKEN_FILE:=${NIMBUS_CONFIG_DIR}/vault_token}"

children=()

local_base_uri() {
  /usr/local/bin/nimbus-local-uri
}

trigger_shutdown() {
    echo "Triggering shutdown..."
    curl --fail-with-body --silent --show-error -X POST "$(local_base_uri)/internal/shutdown" || echo "WARNING: failed call to shutdown endpoint"
}

cleanup() {
    echo "Cleaning up..."
    if [ ${#children[@]} -gt 0 ]; then
      kill "${children[@]}"
    fi
}

config_reload() {
  curl --fail-with-body --silent --show-error -X POST "$(local_base_uri)/internal/reload-config" || echo "WARNING: failed call to reload-config endpoint"
}

trap config_reload SIGHUP

trap "echo 'received SIGINT'; trigger_shutdown" SIGINT

trap "echo 'received SIGTERM'; trigger_shutdown" SIGTERM

poll_aws_credentials() {
  local -r jqFilter=$(cat <<'END_HEREDOC'
{
  blobFetcher : {
    awsConfig : {
      credentials : .|{accessKey : .AccessKeyId, secretKey : .SecretAccessKey, token : .Token }
    }
  },
  userBlobFetcher : {
    awsConfig : {
      credentials : .|{accessKey : .AccessKeyId, secretKey : .SecretAccessKey, token : .Token }
    }
  },
  dynamo : {
    credentials : .|{accessKey : .AccessKeyId, secretKey : .SecretAccessKey, token : .Token }
  }
}
END_HEREDOC
)
  while true; do
    {
      local token
      local role_name
      local tmpfile
      token=$(curl --fail-with-body -sS -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
      role_name=$(curl -f -s -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/iam/security-credentials/)
      tmpfile=$(mktemp)
      curl --fail-with-body -sS -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/iam/security-credentials/$role_name" | jq "$jqFilter" > "$tmpfile" && mv -f "$tmpfile" "$NIMBUS_AWS_CREDENTIALS_PATH"
    } || echo "WARNING: Failed to fetch AWS credentials"
    sleep 15m
  done
}

write_vault_json() {
  local tmpfile
  tmpfile=$(mktemp)
  jq -R '{vault: {token : .}}' < "$NIMBUS_VAULT_TOKEN_FILE" > "$tmpfile" && mv -f "$tmpfile" "$NIMBUS_CONFIG_DIR/vault.json" || echo "WARNING: failed to update vault configuration"
}

write_meta_json() {
  local tmpfile
  tmpfile=$(mktemp)
  local -r jqFilter=$(cat <<'END_HEREDOC'
{
  meta : {
    nimbusVersion: $nimbusVersion,
    ucmVersion: $ucmVersion
  }
}
END_HEREDOC
)
  jq --null-input \
    --rawfile nimbusVersion /usr/share/nimbus/version.txt \
    --arg ucmVersion "$(ucm --version)" \
    "$jqFilter" \
    > "$tmpfile" && \
    mv -f "$tmpfile" "$NIMBUS_CONFIG_DIR/nimbus-meta.json" ||
      echo "WARNING: failed to update nimbus metadata configuration"
}

update_config() {
  local tmpfile
  tmpfile=$(mktemp)
  local defaultHost
  defaultHost="\"$(hostname -i)\"" || defaultHost='null'
  # TODO should this use `find` instead of a glob?
  # Does that make it easier to ignore the main config file?
  jq -s --argjson defaultHost "$defaultHost" 'reduce .[] as $cfg ({host: $defaultHost}; . * $cfg)' "$NIMBUS_CONFIG_DIR"/*.json > "$tmpfile"
  mv -f "$tmpfile" "$NIMBUS_CONFIG_FILE" || echo "WARNING: failed to update configuration"
}

listen_for_updates() {
  # We have to watch the whole directory as opposed to individual files because
  # some tools replace the files instead of modifying them in place, and
  # inotifywait dies when a file that it is watching gets goes away or gets
  # replaced.
  inotifywait -q -m -e close_write,moved_to "$NIMBUS_CONFIG_DIR" | while read -r path action file; do
    local filepath
    filepath="${path}${file}"
    if [[ $filepath == "$NIMBUS_CONFIG_FILE" ]]; then
      config_reload
    elif [[ $filepath == "$NIMBUS_VAULT_TOKEN_FILE" ]]; then
      write_vault_json
    elif [[ $file == *.json && $file != .* ]]; then
      echo "Detected '$action' for '$filepath'. Regenerating $NIMBUS_CONFIG_FILE"
      update_config && { config_reload || echo "WARNING: failed to reload config"; } || echo "WARNING: failed to update config"
    fi

  done
}

update-ca-certificates

if [ -f "$NIMBUS_VAULT_TOKEN_FILE" ]; then
  write_vault_json
fi

if [ -n "$NIMBUS_POLL_IAM_CREDENTIALS" ]; then
  poll_aws_credentials &
  children+=($!)

  echo "Waiting for credentials to be available at $NIMBUS_AWS_CREDENTIALS_PATH"

  until [ -f "$NIMBUS_AWS_CREDENTIALS_PATH" ]; do
    sleep 1
  done
  echo "Credentials available at $NIMBUS_AWS_CREDENTIALS_PATH"
fi

if [ -n "$NIMBUS_CONFIG_DIR" ]; then
  write_meta_json
  update_config || echo "WARNING: failed to update config on startup"
  listen_for_updates &
  children+=($!)
fi

/usr/bin/ucm run.compiled /usr/share/nimbus/nodeMain.uc &
ucmPid=$!
while true; do
  code=0
  wait $ucmPid || code=$?
  if [[ $code -le 128 ]]; then
    cleanup || echo "encountered an error while cleaning up"
    exit $code
  fi
done
