#!/bin/bash

set -euo pipefail

mkdir -p /consul/config
envsubst < /tmp/services.hcl.tpl > /consul/config/services.hcl

consul agent -config-dir /consul/config &

echo "Waiting for Consul to be ready"
curl --silent --show-error --fail --retry 6 --retry-all-errors -o /dev/null \
  -X PUT -d '["00000000-0000-0000-0000-000000000000"]' 'http://localhost:8500/v1/kv/nimbus/blockedUsers' || {
  echo "Couldn't put blocked users key in Consul" 1>&2
  exit 1
}
echo "Consul is ready!"

exec consul-template \
  -template='/etc/nimbus/cfg/config.tpl:/etc/nimbus/cfg/config.json' \
  -exec-reload-signal='SIGHUP' \
  -exec-splay=1s \
  -exec-kill-timeout=300s \
  -exec-kill-signal='SIGTERM' \
  -exec='/usr/local/bin/nimbus'
