#!/bin/sh

set -ex

echo CLOUD_REDIS: "$CLOUD_REDIS"

redis_ping() {
    redis-cli -u "$CLOUD_REDIS" ping
}

for a in $(seq 0 5) ; do
  if redis_ping ; then
    break;
  fi; 
	echo "Waiting for redis...$((10 - a)) more times"; \
  sleep 2; \
done;

if ! (redis_ping)  then \
    echo "Redis not available"; \
  exit 1; \
fi;

echo "Running Cloud at http://localhost:5424"


exec 2>&1
exec /usr/local/bin/cloud
