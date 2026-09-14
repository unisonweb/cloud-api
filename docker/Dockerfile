#syntax=docker/dockerfile:1
ARG UCM_RELEASE=1.1.0
ARG UCM_INSTALLATION=release

FROM debian:trixie-slim AS base
ENV LANG=en_US.UTF-8
USER root
WORKDIR /root
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get -y install locales         && \
  echo "en_US.UTF-8 UTF-8" > /etc/locale.gen           && \
  dpkg-reconfigure --frontend=noninteractive locales   && \
  update-locale LANG=en_US.UTF-8

################################################################################
# build-ucm
################################################################################
# a container for building a local version of ucm
FROM base AS install-ucm-build-from-source
ENV LANG=C.UTF-8
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get install -y \
    build-essential \
    git \
    gnupg \
    libffi-dev \
    libgmp-dev \
    libncurses6 \
    libpq-dev \
    libtinfo-dev \
    make \
    netbase \
    openssh-client \
    rsync \
    unzip \
    wget \
    xz-utils \
    zlib1g-dev
# download public key for github.com
RUN mkdir -p -m 0600 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts
ARG TARGETARCH
COPY docker/download-stack.sh /usr/local/bin/download-stack
RUN TARGETARCH=${TARGETARCH} download-stack
# This is awkward. We cache the `.stack-work` dirs, but we have to stash them in
# a separate directory so they don't get wiped out by the mount of the source
# code (since Stack mixes .stack-work directories in with the source).
RUN --mount=type=bind,readwrite,from=unison-source,target=/tmp/unison \
  --mount=type=cache,target=/root/.stack \
  --mount=type=cache,target=/tmp/unison-stack-work \
  cd /tmp/unison-stack-work && \
  find . -type d -name '.stack-work' -exec sh -c \
    'rsync -rt --mkpath "$1/" "/tmp/unison/${1#./}/"' _ {} \; && \
  cd /tmp/unison && \
  stack build --only-dependencies && \
  stack --local-bin-path /opt/unisonlanguage/unison build --copy-bins unison-cli-main:unison && \
  ln -s /opt/unisonlanguage/unison/unison /usr/bin/ucm && \
  find . -type d -name '.stack-work' -exec sh -c \
    'rsync -rt --mkpath "$1/" "/tmp/unison-stack-work/${1#./}/"' _ {} \;

################################################################################
# nimbus-test-s3
################################################################################

FROM quay.io/minio/minio@sha256:d249d1fb6966de4d8ad26c04754b545205ff15a62e4fd19ebd0f26fa5baacbc0 AS nimbus-test-s3

COPY testing-certs/minio.key /root/.minio/certs/private.key
COPY testing-certs/minio.crt /root/.minio/certs/public.crt
RUN mkdir /usr/local/share/ca-certificates
COPY testing-certs/minio.crt /usr/local/share/ca-certificates/minio-test-ca.crt

CMD ["server", "--console-address", ":443", "/data"]

################################################################################
# install-ucm-release
################################################################################
FROM unisonlang/unison:${UCM_RELEASE} AS ucm-release
USER root
COPY docker/unison-nightly.list /etc/apt/sources.list.d/unison-nightly.list
RUN apt-get update && apt-get install -y unisonweb=1.1.0
USER unison

FROM base AS install-ucm-release
COPY --from=ucm-release /usr/lib/unisonweb /usr/lib/unisonweb
COPY --from=ucm-release /usr/bin/ucm /usr/bin/ucm

################################################################################
# install-ucm
################################################################################
FROM install-ucm-${UCM_INSTALLATION} AS install-ucm

################################################################################
# pull-nimbus
################################################################################
FROM install-ucm AS pull-nimbus
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get -y install ca-certificates gettext-base
ARG NIMBUS_BRANCH
ARG NIMBUS_SHARE_PATH
ARG CACHE_BUST
COPY docker/nimbus/pull-nimbus.md.tpl /tmp/pull-nimbus.md.tpl
RUN NIMBUS_BRANCH="${NIMBUS_BRANCH}" NIMBUS_SHARE_PATH="${NIMBUS_SHARE_PATH}" envsubst < /tmp/pull-nimbus.md.tpl > /tmp/pull-nimbus.md
RUN --mount=type=secret,required=true,id=share-credentials,target=/root/.local/share/unisonlanguage/credentials.json \
    --mount=type=cache,target=/tmp/nimbus-codebase,sharing=locked \
    UNISON_MIGRATION="auto" \
    CACHE_BUST="${CACHE_BUST}" \
    UNISON_DEBUG=timing \
    /usr/bin/ucm transcript.in-place --codebase-create /tmp/nimbus-codebase /tmp/pull-nimbus.md && \
    cp -r /tmp/nimbus-codebase/.unison /root/

FROM scratch AS unison-codebase
COPY --from=pull-nimbus /root/.unison/ /

################################################################################
# compile-nimbus
################################################################################
FROM install-ucm AS compile-nimbus
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get -y install ca-certificates curl jq gettext-base
ARG NIMBUS_BRANCH
ARG NIMBUS_VERSION
COPY docker/nimbus/compile-nimbus.md.tpl /tmp/compile-nimbus.md.tpl
RUN NIMBUS_BRANCH="${NIMBUS_BRANCH}" envsubst < /tmp/compile-nimbus.md.tpl > /tmp/compile-nimbus.md
RUN --mount=type=bind,rw,from=unison-codebase,target=/root/nimbus/.unison/ \
  mkdir -p /usr/share/nimbus && \
  UNISON_DEBUG=timing \
  /usr/bin/ucm --codebase /root/nimbus transcript.fork /tmp/compile-nimbus.md && \
  echo -n "${NIMBUS_VERSION}" > /usr/share/nimbus/version.txt

################################################################################
# nimbus-public
################################################################################
FROM install-ucm AS nimbus-public
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get -y install curl inotify-tools jq
COPY docker/nimbus/nimbus-health-check.sh /usr/local/bin/nimbus-health-check
COPY docker/nimbus/nimbus-local-uri.sh /usr/local/bin/nimbus-local-uri
COPY docker/nimbus/nimbus.sh /usr/local/bin/nimbus
COPY --from=compile-nimbus /usr/share/nimbus /usr/share/nimbus

ENV GHCRTS="-N -C0.003 -qb -qn1"

HEALTHCHECK --timeout=5s --start-period=30s \
  CMD /usr/local/bin/nimbus-health-check

ENTRYPOINT ["/usr/local/bin/nimbus"]

################################################################################
# nimbus
################################################################################
FROM nimbus-public AS nimbus
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get -y install ca-certificates
COPY docker/unison-us-west-2-ca.pem /usr/local/share/ca-certificates/unison-us-west-2-ca.crt
RUN update-ca-certificates

################################################################################
# nimbus-with-test-configs
################################################################################
# Similar to nimbus image but has test config files baked in. There is surely a
# better way to do this, but I keep hitting issues. One is that mounting a
# volume via docker compose doesn't work properly inside a Drone docker
# pipeline.

FROM nimbus-public AS nimbus-with-test-configs
COPY docker/hashicorp-archive-keyring.gpg /usr/share/keyrings/hashicorp-archive-keyring.gpg
RUN echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com trixie main" > /etc/apt/sources.list.d/hashicorp.list
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get -y install gettext-base consul consul-template
COPY docker/nimbus/consul/ /consul/config/
COPY docker/nimbus/services.hcl.tpl /tmp/services.hcl.tpl
COPY docker/nimbus/config.tpl /etc/nimbus/cfg/config.tpl
COPY --from=nimbus-test-s3 /usr/local/share/ca-certificates/minio-test-ca.crt /usr/local/share/ca-certificates/minio-test-ca.crt
RUN update-ca-certificates
COPY docker/nimbus/nimbus-test.sh /usr/local/bin/nimbus-test

ENTRYPOINT ["/usr/local/bin/nimbus-test"]

################################################################################
# nimbus-with-byoc-configs
################################################################################
# Similar to nimbus image but has test config files baked in. There is surely a
# better way to do this, but I keep hitting issues. One is that mounting a
# volume via docker compose doesn't work properly inside a Drone docker
# pipeline.

FROM nimbus-with-test-configs AS nimbus-with-byoc-configs
COPY docker/nimbus/config.byoc.tpl /etc/nimbus/cfg/config.tpl

################################################################################
# compile-cloud-api
################################################################################

FROM base AS compile-cloud-api
ENV LANG=C.UTF-8
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get install -y \
    build-essential \
    binutils \
    git \
    gnupg \
    libffi-dev \
    libgmp-dev \
    libncurses6 \
    libpq-dev \
    libtinfo-dev \
    make \
    netbase \
    openssh-client \
    haskell-stack \
    unzip \
    wget \
    xz-utils \
    zlib1g-dev \
    ghc
# download public key for github.com
RUN mkdir -p -m 0600 ~/.ssh && ssh-keyscan github.com >> ~/.ssh/known_hosts
ARG TARGETARCH
COPY stack.yaml stack.yaml.lock package.yaml cloud.cabal /tmp/cloud-api/
COPY src /tmp/cloud-api/src
COPY app /tmp/cloud-api/app
# This is awkward. We cache the `.stack-work` dirs, but we have to stash them in
# a separate directory so they don't get wiped out by the mount of the source
# code (since Stack mixes .stack-work directories in with the source).
RUN --mount=type=cache,target=/tmp/cloud-api-stack-work,id=cloud-api-stack-work-cache \
  --mount=type=cache,target=/root/.stack,id=cloud-api-stack-cache \
  cd /tmp/cloud-api-stack-work && \
  find . -type d -name '.stack-work' -exec sh -c \
    'rsync -rt --mkpath "$1/" "/tmp/cloud-api/${1#./}/"' _ {} \; && \
  cd /tmp/cloud-api && \
  stack -v install cloud:cloud-exe && \
  find . -type d -name '.stack-work' -exec sh -c \
    'rsync -rt --mkpath "$1/" "/tmp/cloud-api-stack-work/${1#./}/"' _ {} \;


################################################################################
# nimbus-outbound-proxy
################################################################################
# a containerized squid proxy that restricts requests

# Some inspiration from https://github.com/jpetazzo/squid-in-a-can/blob/master/squid/Dockerfile

FROM base AS nimbus-outbound-proxy
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get -y install curl squid
COPY docker/unison-us-west-2-ca.pem /usr/local/share/ca-certificates/unison-us-west-2-ca.crt
RUN update-ca-certificates
# The overrides directory can be mounted as a volume to dynamically pick up changes.
COPY outbound-proxy/domain-deny-list.txt /etc/squid/overrides/domain-deny-list.txt
COPY outbound-proxy/squid.conf /etc/squid/squid.conf
COPY outbound-proxy/delay.conf /etc/squid/overrides/delay.conf
COPY outbound-proxy/start-squid /usr/local/bin/start-squid
COPY outbound-proxy/connect-unison.conf /etc/squid/overrides/connect-unison.conf

ENTRYPOINT ["/usr/local/bin/start-squid"]

HEALTHCHECK --timeout=10s --start-period=60s \
  CMD curl --fail-with-body --proxy localhost:3128 'https://www.unison-lang.org'

################################################################################
# download-vault
################################################################################
# a container for fetching hashicorp vault
FROM base AS download-vault
ARG VAULT_VERSION
ARG TARGETARCH
ADD https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${TARGETARCH}.zip /tmp/vault.zip
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get -y install unzip && unzip /tmp/vault.zip -d /usr/local/bin

################################################################################
# nimbus-integration-tests
################################################################################
FROM install-ucm AS nimbus-integration-tests
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get -y install ca-certificates awscli curl gettext-base

COPY --from=nimbus-test-s3 /usr/bin/mc /usr/bin/mc
COPY --from=nimbus-test-s3 /usr/local/share/ca-certificates/minio-test-ca.crt /usr/local/share/ca-certificates/minio-test-ca.crt
RUN update-ca-certificates

COPY --from=download-vault /usr/local/bin/vault /usr/local/bin/vault
COPY --from=unison-codebase / /root/nimbus/.unison

ARG NIMBUS_BRANCH
RUN --mount=type=bind,source=integration-tests/transcript.md.tpl,target=/tmp/integration-tests/transcript.md.tpl \
  mkdir -p /usr/share/nimbus/integration-tests && NIMBUS_BRANCH="${NIMBUS_BRANCH}" envsubst < /tmp/integration-tests/transcript.md.tpl > /usr/share/nimbus/integration-tests/transcript.md
COPY integration-tests/generated/large/client-config.json /usr/share/nimbus/integration-tests/large/client-config.json
COPY integration-tests/generated/small/client-config.json /usr/share/nimbus/integration-tests/small/client-config.json
COPY integration-tests/generated/byoc/client-config.json /usr/share/nimbus/integration-tests/byoc/client-config.json
COPY integration-tests/integration-tests.sh /usr/local/bin/integration-tests

ENV CREATE_TEST_BUCKETS=true

ENTRYPOINT ["/usr/local/bin/integration-tests"]

################################################################################
# nimbus-integration-tests-cloud-client
################################################################################
FROM install-ucm AS nimbus-integration-tests-cloud-client
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get update && apt-get -y install ca-certificates gettext-base curl

COPY docker/unison-us-west-2-ca.pem /usr/local/share/ca-certificates/unison-us-west-2-ca.crt
RUN update-ca-certificates

COPY --from=unison-codebase / /root/nimbus/.unison
ARG NIMBUS_BRANCH
RUN --mount=type=bind,source=integration-tests/integration-tests-cloud-client.md.tpl,target=/tmp/integration-tests-cloud-client.md.tpl \
  mkdir -p /usr/share/nimbus/integration-tests && NIMBUS_BRANCH="${NIMBUS_BRANCH}" envsubst < /tmp/integration-tests-cloud-client.md.tpl > /usr/share/nimbus/integration-tests/transcript.md
COPY integration-tests/integration-tests.sh /usr/local/bin/integration-tests

ENTRYPOINT ["/usr/local/bin/integration-tests"]

################################################################################
# consul-test
################################################################################
FROM hashicorp/consul@sha256:842ee8b5d0ea228b6c36230a442bcf13b7f92bbe35091676f4482eaa933a6ad7 AS consul-test
COPY docker/consul-server.json /consul/config/consul-server.json
HEALTHCHECK --timeout=5s --start-period=30s \
  CMD curl --fail-with-body http://localhost:8500/v1/status/leader


################################################################################
# cloud
################################################################################
FROM base AS cloud
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt,sharing=locked \
  apt-get  update && apt-get install -y ssl-cert libpq5 ca-certificates curl locales redis-tools
RUN openssl genrsa -out /etc/ssl/private/cloud.key && \
    echo "C.UTF-8 UTF-8" > /etc/locale.gen && \
    dpkg-reconfigure --frontend=noninteractive locales && \
    update-locale LANG=C.UTF-8
ENV LANG=C.UTF-8

COPY --from=nimbus-test-s3 /usr/local/share/ca-certificates/minio-test-ca.crt /usr/local/share/ca-certificates/minio-test-ca.crt
RUN update-ca-certificates

COPY docker/cloud-entrypoint.sh /usr/local/bin/cloud-entrypoint
RUN chmod 555 /usr/local/bin/cloud-entrypoint

COPY docker/aws-config /root/.aws/config

COPY --from=compile-cloud-api /root/.local/bin/cloud-exe /usr/local/bin/cloud
ENTRYPOINT ["/usr/local/bin/cloud-entrypoint"]

HEALTHCHECK --timeout=5s --start-period=30s \
  CMD curl --fail-with-body "http://localhost:${NOMAD_ALLOC_PORT_cloud_http}/metrics"

ARG CLOUD_COMMIT
ENV CLOUD_COMMIT=$CLOUD_COMMIT
