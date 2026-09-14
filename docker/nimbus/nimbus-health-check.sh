#!/bin/sh

set -eu

curl --silent --show-error --fail-with-body "$(/usr/local/bin/nimbus-local-uri)/health"
