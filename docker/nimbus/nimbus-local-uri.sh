#!/bin/bash

set -euo pipefail

: "${NIMBUS_CONFIG_FILE:=/run/nimbus/config-merged.json}"

local_gossip_port() {
  local -r fallbackPort="${NIMBUS_PORT_GOSSIP:-8081}"
  if [ -f "$NIMBUS_CONFIG_FILE" ]; then
    jq -r --arg fallbackPort "$fallbackPort" '.bindPorts.gossipHttp // $fallbackPort' < "$NIMBUS_CONFIG_FILE"
  else echo "$fallbackPort"
  fi
}

echo "http://localhost:$(local_gossip_port)"
