#!/bin/bash

set -euo pipefail

os='linux'

case $TARGETARCH in
  amd64)
    arch='x86_64'
    ;;
  arm64)
    arch='aarch64'
    ;;
esac


mkdir -p /opt/stack
wget "https://github.com/commercialhaskell/stack/releases/download/v2.15.7/stack-2.15.7-${os}-${arch}.tar.gz" -O- \
  | tar -x -z --strip-components 1 -C /opt/stack \
  && ln -s /opt/stack/stack /usr/local/bin/stack
