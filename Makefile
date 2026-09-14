# To use a local branch instead of downloading a nimbus release, set NIMBUS_LOCAL_BRANCH like so:
# NIMBUS_LOCAL_BRANCH=my-branch make integration-tests
#
# NOTE: currently we assume that your branch is within @cloud/nimbus, so this would resolve to your local
# @cloud/nimbus/my-branch branch.
#
# Otherwise the Share path below will be used.
# NOTE: if you set this to a branch instead of a release then you might need to
# jump through some docker cache hoops to pick up updates to the branch. The
# easiest thing to do would be to push a new branch with updates and point to
# it.
NIMBUS_SHARE_PATH:=@cloud/nimbus/releases/44.4.9
#NIMBUS_SHARE_PATH:=@cloud/nimbus/@ceedubs/nodetype

# You can either build ucm from source or use a release. Set `unison_source` to build from source.
#unison_source := https://github.com/unisonweb/unison.git\#6da22c82434d6541b8a196a99475541920ec97f6
#unison_source := https://github.com/unisonweb/unison.git\#topic/reflect-errs
#unison_source := https://github.com/unisonweb/unison.git\#trunk
#unison_source := /home/alice/code/unison
# ^
# You can specify a hash, branch, or tag after the `#` (which needs to be escaped for Make).
# You can also change this to a local file path, but it will copy the entire repo with history.
arch:=$(shell uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
VAULT_VERSION=1.15.4
UNAME := $(shell uname)
docker_registry=324181518966.dkr.ecr.us-west-2.amazonaws.com
cloud_commit := $(shell git diff-index --quiet HEAD -- && git rev-parse --short=10 HEAD || echo 'wip')

# This doesn't need to include all intermediate stages; just those that we use in integration tests and/or publish.
docker_build_targets := $(addprefix docker_build_,cloud consul-test nimbus-public nimbus nimbus-test-s3 nimbus-outbound-proxy nimbus-with-test-configs nimbus-with-byoc-configs nimbus-integration-tests nimbus-integration-tests-cloud-client)

docker_push_targets := $(addprefix docker_push_,cloud nimbus nimbus-integration-tests-cloud-client nimbus-outbound-proxy)

docker_stitch_private_targets := $(addprefix docker_stitch_private_,cloud nimbus nimbus-integration-tests-cloud-client nimbus-outbound-proxy)

.SHELLFLAGS := -eu -o pipefail -c
.PHONY: all clean format install docker_build docker_push docker_public_push stitch stitch_public integration-tests integration-tests-multi serve

INTEGRATION_TEST_DIR := integration-tests
INTEGRATION_TEST_GENERATED_SMALL_DIR := $(INTEGRATION_TEST_DIR)/generated/small
INTEGRATION_TEST_GENERATED_BYOC_DIR := $(INTEGRATION_TEST_DIR)/generated/byoc
INTEGRATION_TEST_GENERATED_LARGE_DIR := $(INTEGRATION_TEST_DIR)/generated/large

ifdef NIMBUS_LOCAL_BRANCH
nimbus_branch:=$(NIMBUS_LOCAL_BRANCH)
local_unison_codebase:=$(HOME)/.unison
pull_nimbus_docker_args:=--build-context unison-codebase="$(local_unison_codebase)" \
	--build-arg NIMBUS_VERSION=DEV-$(NIMBUS_LOCAL_BRANCH)
else
nimbus_branch:=main
share_credentials_file:=$(HOME)/.local/share/unisonlanguage/credentials.json
# If the Share path is mutable (a branch instead of a release), then Docker won't
# check for updates unless we pull cache-busting tricks, hence CACHE_BUST.
pull_nimbus_docker_args:=--secret id=share-credentials,src="$(share_credentials_file)" \
	--build-arg NIMBUS_SHARE_PATH=$(NIMBUS_SHARE_PATH) \
	--build-arg NIMBUS_VERSION=$(NIMBUS_SHARE_PATH) \
	--build-arg CACHE_BUST="$(shell date '+%s')"
endif

# If we are building ucm from source then we can use the native platform,
# otherwise we need to target x86, because linux arm builds of ucm aren't
# published as of December 2024.
ifdef unison_source
build_ucm_docker_args:=--build-context unison-source="$(unison_source)" \
											 --build-arg UCM_INSTALLATION=build-from-source
else
build_ucm_docker_args:=--build-arg UCM_INSTALLATION=release
endif

ifdef USE_STABLE_BUILD_TAGS
# this abomination is turning something like @cloud/nimbus/@ceedubs/byoc3 into cloud_nimbus_ceedubs_byoc3_2025
build_tag:=$(shell echo $(NIMBUS_SHARE_PATH) | sed -E 's/[^a-zA-Z0-9_\-]/_/g; s/^_+//; s/_+$$//; s/_+/_/g')_$(DRONE_BUILD_NUMBER)
else
build_tag := latest
endif

public_docker_username := unisoncomputing
public_docker_image := $(public_docker_username)/unison-cloud
public_docker_tag := $(public_docker_image):$(build_tag)
public_docker_latest := $(public_docker_image):latest

OPEN_BROWSER ?= "true"

export DOCKER_BUILDKIT := 1
export DOCKER_CONTEXT DOCKER_HOST

ifeq ($(UNAME),Linux)
  OPEN := xdg-open
endif

ifeq ($(UNAME),Darwin)
  OPEN := open
endif

docker_build_cloud: image_name:=cloud
docker_build_cloud:
	docker build   \
		-f docker/Dockerfile \
		--target $(image_name) \
		$(build_ucm_docker_args) \
		--build-arg CLOUD_COMMIT=$(cloud_commit) \
		--tag $(docker_registry)/$(image_name):$(build_tag) \
		.

docker_build_consul-test: image_name:=consul-test
docker_build_consul-test:
	docker build  \
		-f docker/Dockerfile \
		--target consul-test \
		$(build_ucm_docker_args) \
		--tag $(docker_registry)/$(image_name):$(build_tag) \
		.

docker_build_ucm: image_name:=build-ucm
docker_build_ucm:
	docker build  \
		-f docker/Dockerfile \
		--target $(image_name) \
		$(build_ucm_docker_args) \
		.

docker_build_nimbus: image_name:=nimbus
docker_build_nimbus:
	docker build  \
		-f docker/Dockerfile \
		--target $(image_name) \
		--build-arg NIMBUS_BRANCH=$(nimbus_branch) \
		$(build_ucm_docker_args) \
		$(pull_nimbus_docker_args) \
		--tag $(docker_registry)/$(image_name):$(build_tag) \
		.

docker_build_nimbus-public: image_name:=nimbus-public
docker_build_nimbus-public:
	docker build  \
		-f docker/Dockerfile \
		--target $(image_name) \
		--build-arg NIMBUS_BRANCH=$(nimbus_branch) \
		$(build_ucm_docker_args) \
		$(pull_nimbus_docker_args) \
		--tag $(public_docker_tag) \
		.

docker_build_nimbus-with-test-configs: image_name:=nimbus-with-test-configs
docker_build_nimbus-with-test-configs:
	docker build  \
		-f docker/Dockerfile \
		--target $(image_name) \
		--build-arg NIMBUS_BRANCH=$(nimbus_branch) \
		$(build_ucm_docker_args) \
		$(pull_nimbus_docker_args) \
		--tag $(docker_registry)/$(image_name):$(build_tag) \
		.
docker_build_nimbus-with-byoc-configs: image_name:=nimbus-with-byoc-configs
docker_build_nimbus-with-byoc-configs:
	docker build  \
		-f docker/Dockerfile \
		--target $(image_name) \
		--build-arg NIMBUS_BRANCH=$(nimbus_branch) \
		$(build_ucm_docker_args) \
		$(pull_nimbus_docker_args) \
		--tag $(docker_registry)/$(image_name):$(build_tag) \
		.

docker_build_nimbus-integration-tests-cloud-client: image_name:=nimbus-integration-tests-cloud-client
docker_build_nimbus-integration-tests-cloud-client:
	docker build  \
		-f docker/Dockerfile \
		--target $(image_name) \
		--build-arg NIMBUS_BRANCH=$(nimbus_branch) \
		--build-arg VAULT_VERSION=$(VAULT_VERSION) \
		$(build_ucm_docker_args) \
		$(pull_nimbus_docker_args) \
		--tag $(docker_registry)/$(image_name):$(build_tag) \
		.

docker_build_nimbus-integration-tests: image_name:=nimbus-integration-tests
docker_build_nimbus-integration-tests:
	docker build  \
		-f docker/Dockerfile \
		--target $(image_name) \
		--build-arg NIMBUS_BRANCH=$(nimbus_branch) \
		--build-arg VAULT_VERSION=$(VAULT_VERSION) \
		$(build_ucm_docker_args) \
		$(pull_nimbus_docker_args) \
		--tag $(docker_registry)/$(image_name):$(build_tag) \
		.

docker_build_nimbus-test-s3: image_name:=nimbus-test-s3
docker_build_nimbus-test-s3:
	docker build  \
		-f docker/Dockerfile \
		$(build_ucm_docker_args) \
		--target nimbus-test-s3 \
		--tag $(docker_registry)/$(image_name):$(build_tag) \
		.

docker_build_nimbus-outbound-proxy: image_name:=nimbus-outbound-proxy
docker_build_nimbus-outbound-proxy:
	docker build  \
		-f docker/Dockerfile \
		--target $(image_name) \
		$(build_ucm_docker_args) \
		--tag $(docker_registry)/$(image_name):$(build_tag) \
		.

docker_push_%: image_name=$(@:docker_push_%=%)
docker_push_%:
	docker tag "$(docker_registry)/$(image_name):$(build_tag)" "$(docker_registry)/$(image_name):$(build_tag)-$(arch)"
	docker tag "$(docker_registry)/$(image_name):$(build_tag)" "$(docker_registry)/$(image_name):latest-$(arch)"
	docker push "$(docker_registry)/$(image_name):$(build_tag)-$(arch)"
	docker push "$(docker_registry)/$(image_name):latest-$(arch)"

docker_push: $(docker_push_targets)
	@echo "Pushed images with tags 'latest-$(arch)' and '$(build_tag)-$(arch)'"

docker_public_push: docker_push
	docker tag "$(public_docker_tag)" "$(public_docker_tag)-$(arch)"
	docker tag "$(public_docker_tag)" "$(public_docker_latest)-$(arch)"
	@docker login -u $(public_docker_username) -p $(docker_password)
	docker push "$(public_docker_tag)-$(arch)"
	docker push "$(public_docker_latest)-$(arch)"

docker_build: $(docker_build_targets)

docker_staging_release:
	docker build -f docker/Dockerfile --target cloud -t $(docker_registry)/cloud-staging:$(build_tag) docker

docker_staging_push: $(docker_build_cloud)
	docker push $(docker_registry)/cloud-staging:$(build_tag)


docker_stitch_private_%: image_name=$(@:docker_stitch_private_%=%)
docker_stitch_private_%: AMD_TAG=${docker_registry}/$(image_name):$(build_tag)-amd64
docker_stitch_private_%: ARM_TAG=${docker_registry}/$(image_name):$(build_tag)-arm64
docker_stitch_private_%: STITCH_TAG=${docker_registry}/$(image_name):$(build_tag)
docker_stitch_private_%: STITCH_TAG_LATEST=${docker_registry}/$(image_name):latest
docker_stitch_private_%: arm_digest=$(shell docker buildx imagetools inspect ${ARM_TAG} --format '{{json .Manifest}}' | jq -r .digest)
docker_stitch_private_%: amd_digest=$(shell docker buildx imagetools inspect ${AMD_TAG} --format '{{json .Manifest}}' | jq -r .digest)
docker_stitch_private_%:
	docker buildx imagetools create -t ${STITCH_TAG} ${AMD_TAG}@${amd_digest} ${ARM_TAG}@${arm_digest}
	docker buildx imagetools create -t ${STITCH_TAG_LATEST} ${AMD_TAG}@${amd_digest} ${ARM_TAG}@${arm_digest}

stitch_public:
stitch_public: AMD_TAG=${public_docker_image}:${build_tag}-amd64
stitch_public: ARM_TAG=${public_docker_image}:${build_tag}-arm64
stitch_public: STITCH_TAG=${public_docker_image}:${build_tag}
stitch_public: STITCH_TAG_LATEST=${public_docker_image}:latest
stitch_public: arm_digest=$(shell docker buildx imagetools inspect ${ARM_TAG} --format '{{json .Manifest}}' | jq -r .digest)
stitch_public: amd_digest=$(shell docker buildx imagetools inspect ${AMD_TAG} --format '{{json .Manifest}}' | jq -r .digest)
stitch_public:
	docker buildx imagetools create -t ${STITCH_TAG} ${AMD_TAG}@${amd_digest} ${ARM_TAG}@${arm_digest}
	docker buildx imagetools create -t ${STITCH_TAG_LATEST} ${AMD_TAG}@${amd_digest} ${ARM_TAG}@${arm_digest}

stitch: $(docker_stitch_private_targets)

stop:
	DOCKER_REGISTRY=$(docker_registry) BUILD_TAG=$(build_tag) docker compose -f docker/docker-compose-infra.yaml -f $(INTEGRATION_TEST_GENERATED_SMALL_DIR)/docker-compose-nimbus.yml -f $(INTEGRATION_TEST_GENERATED_BYOC_DIR)/docker-compose-byoc.yml-f docker/docker-compose-serve.yaml down

serve-without-teardown: docker_build
	DOCKER_REGISTRY=$(docker_registry) \
	BUILD_TAG=$(build_tag) \
  NIMBUS_CLIENT_CONFIG_FILE='/usr/share/nimbus/integration-tests/small/client-config.json' \
  NIMBUS_BYOC_CLIENT_CONFIG_FILE='/usr/share/nimbus/integration-tests/byoc/client-config.json' \
  UNISON_CLOUD_SUBMIT_DISABLE_LOG_STREAMING=true \
	docker compose -f docker/docker-compose-infra.yaml -f $(INTEGRATION_TEST_GENERATED_SMALL_DIR)/docker-compose-nimbus.yml -f $(INTEGRATION_TEST_GENERATED_BYOC_DIR)/docker-compose-byoc.yml -f docker/docker-compose-cloud-api.yaml -f docker/docker-compose-serve.yaml -f docker/docker-compose-test.yaml up \
		--build \
		--remove-orphans \
		--renew-anon-volumes
		# --detach
	# stack build --fast cloud:cloud-exe
	# while  ! (  pg_isready --host localhost -U postgres -p 5432 && redis-cli -p 6379 ping)  do \
		# echo "Waiting for postgres and redis..."; \
		# sleep 1; \
	# done;
	# echo "Running Cloud at http://localhost:5424"
	# (. ./cloud.env && stack exec cloud-exe 2>&1)

serve: # docker_build
	bash -c "trap 'trap - SIGINT SIGTERM ERR; $(MAKE) stop; exit 1' SIGINT SIGTERM ERR; $(MAKE) serve-without-teardown"

integration-tests: docker_build
	DOCKER_REGISTRY=$(docker_registry) \
	BUILD_TAG=$(build_tag) \
  NIMBUS_CLIENT_CONFIG_FILE='/usr/share/nimbus/integration-tests/large/client-config.json' \
  NIMBUS_BYOC_CLIENT_CONFIG_FILE='/usr/share/nimbus/integration-tests/byoc/client-config.json' \
  UNISON_CLOUD_SUBMIT_DISABLE_LOG_STREAMING=true \
	docker compose -f docker/docker-compose-infra.yaml -f $(INTEGRATION_TEST_GENERATED_LARGE_DIR)/docker-compose-nimbus.yml -f $(INTEGRATION_TEST_GENERATED_BYOC_DIR)/docker-compose-byoc.yml -f docker/docker-compose-cloud-api.yaml -f docker/docker-compose-test.yaml up \
		--build \
		--renew-anon-volumes \
		--timeout 60 \
		--exit-code-from integration-tests \
		--remove-orphans

integration-tests-small-retest:
	DOCKER_REGISTRY=$(docker_registry) \
	BUILD_TAG=$(build_tag) \
  NIMBUS_CLIENT_CONFIG_FILE='/usr/share/nimbus/integration-tests/small/client-config.json' \
  NIMBUS_BYOC_CLIENT_CONFIG_FILE='/usr/share/nimbus/integration-tests/byoc/client-config.json' \
  UNISON_CLOUD_SUBMIT_DISABLE_LOG_STREAMING=true \
	docker compose -f docker/docker-compose-infra.yaml -f $(INTEGRATION_TEST_GENERATED_SMALL_DIR)/docker-compose-nimbus.yml -f $(INTEGRATION_TEST_GENERATED_BYOC_DIR)/docker-compose-byoc.yml -f docker/docker-compose-cloud-api.yaml -f docker/docker-compose-test.yaml up \
		--build \
		--renew-anon-volumes \
		--timeout 60 \
		--exit-code-from integration-tests \
		--remove-orphans

integration-tests-small: docker_build
	DOCKER_REGISTRY=$(docker_registry) \
	BUILD_TAG=$(build_tag) \
  NIMBUS_CLIENT_CONFIG_FILE='/usr/share/nimbus/integration-tests/small/client-config.json' \
  NIMBUS_BYOC_CLIENT_CONFIG_FILE='/usr/share/nimbus/integration-tests/byoc/client-config.json' \
  UNISON_CLOUD_SUBMIT_DISABLE_LOG_STREAMING=true \
	docker compose -f docker/docker-compose-infra.yaml -f $(INTEGRATION_TEST_GENERATED_SMALL_DIR)/docker-compose-nimbus.yml -f $(INTEGRATION_TEST_GENERATED_BYOC_DIR)/docker-compose-byoc.yml -f docker/docker-compose-cloud-api.yaml -f docker/docker-compose-test.yaml up \
		--build \
		--renew-anon-volumes \
		--timeout 60 \
		--exit-code-from integration-tests \
		--remove-orphans

# Same suite and small topology as integration-tests-small, but with TWO
# cloud-api instances registered in Consul and the nimbus nodes sharded across
# them — exercising cross-instance invalidation via the /internal/invalidate
# peer RPC, which single-instance runs cannot cover.
integration-tests-multi: docker_build
	DOCKER_REGISTRY=$(docker_registry) \
	BUILD_TAG=$(build_tag) \
  NIMBUS_CLIENT_CONFIG_FILE='/usr/share/nimbus/integration-tests/small/client-config.json' \
  NIMBUS_BYOC_CLIENT_CONFIG_FILE='/usr/share/nimbus/integration-tests/byoc/client-config.json' \
  UNISON_CLOUD_SUBMIT_DISABLE_LOG_STREAMING=true \
	docker compose -f docker/docker-compose-infra.yaml -f $(INTEGRATION_TEST_GENERATED_SMALL_DIR)/docker-compose-nimbus.yml -f $(INTEGRATION_TEST_GENERATED_BYOC_DIR)/docker-compose-byoc.yml -f docker/docker-compose-cloud-api.yaml -f docker/docker-compose-multi-cloud-api.yaml -f docker/docker-compose-test.yaml up \
		--build \
		--renew-anon-volumes \
		--timeout 60 \
		--exit-code-from integration-tests \
		--remove-orphans

local-integration-tests:
	trap 'docker compose -f docker/docker-compose-base.yaml -f $(INTEGRATION_TEST_GENERATED_SMALL_DIR)/docker-compose-nimbus.yml -f $(INTEGRATION_TEST_GENERATED_BYOC_DIR)/docker-compose-byoc.yml down' EXIT INT TERM; \
	docker compose -f docker/docker-compose-base.yaml -f $(INTEGRATION_TEST_GENERATED_SMALL_DIR)/docker-compose-nimbus.yml -f $(INTEGRATION_TEST_GENERATED_BYOC_DIR)/docker-compose-byoc.yml -f docker/docker-compose.yaml -f docker/docker-compose-test.yaml up --build --exit-code-from integration-tests --remove-orphans --force-recreate

integration-tests/gen-configs: integration-tests/config.dhall
	mkdir -p $(INTEGRATION_TEST_GENERATED_LARGE_DIR)
	mkdir -p $(INTEGRATION_TEST_GENERATED_SMALL_DIR)
	echo '(./$(INTEGRATION_TEST_DIR)/config.dhall).large.dockerComposeContents' | \
		dhall-to-yaml --output $(INTEGRATION_TEST_GENERATED_LARGE_DIR)/docker-compose-nimbus.yml
	echo '(./$(INTEGRATION_TEST_DIR)/config.dhall).large.clientConfig' | \
		dhall-to-json --output $(INTEGRATION_TEST_GENERATED_LARGE_DIR)/client-config.json
	echo '(./$(INTEGRATION_TEST_DIR)/config.dhall).small.dockerComposeContents' | \
		dhall-to-yaml --output $(INTEGRATION_TEST_GENERATED_SMALL_DIR)/docker-compose-nimbus.yml
	echo '(./$(INTEGRATION_TEST_DIR)/config.dhall).small.clientConfig' | \
		dhall-to-json --output $(INTEGRATION_TEST_GENERATED_SMALL_DIR)/client-config.json
	echo '(./$(INTEGRATION_TEST_DIR)/config.dhall).byoc.dockerComposeContents' | \
		dhall-to-yaml --output $(INTEGRATION_TEST_GENERATED_BYOC_DIR)/docker-compose-byoc.yml
	echo '(./$(INTEGRATION_TEST_DIR)/config.dhall).byoc.clientConfig' | \
		dhall-to-json --output $(INTEGRATION_TEST_GENERATED_BYOC_DIR)/client-config.json

integration-tests/lint: $(INTEGRATION_TEST_DIR)/config.dhall
	dhall freeze --transitive $(INTEGRATION_TEST_DIR)/config.dhall
	dhall --ascii lint --transitive $(INTEGRATION_TEST_DIR)/config.dhall

testing-certs/minio.crt: testing-certs/minio.key
	openssl req -x509 -new -nodes \
		-days 3650 \
		-key testing-certs/minio.key \
		-subj "/O=Unison Computing/CN=*.s3.unison-test-s3" \
		-addext "subjectAltName=DNS:*.unison-test-s3,DNS:*.s3.unison-test-s3,DNS:unison-test-s3,DNS:localhost,DNS:unison-cloud-services.localhost,DNS:*.s3.localhost" \
		-out $@

format:
	ormolu --mode inplace $$(git ls-files '*.hs')

print_cloud_commit:
	@echo $(cloud_commit)

print-tag:
	@echo $(build_tag)

all: docker_build
	echo $(unison)

clean:
	stack clean
	(test -n "$(INTEGRATION_TEST_GENERATED_DIR)" && rm -r "$(INTEGRATION_TEST_GENERATED_DIR)") || true
