# running a local Unison Cloud cluster

## dependencies

In order to run Unison Cloud locally via docker, you'll need to have the following installed:

- [Docker](https://docs.docker.com/engine/install/)

It will make things easier if you also have `make` installed.

## process

**If you need to modify nimbus**:

- From within ucm, pull the latest nimbus if necessary (ex: `clone @cloud/nimbus /nimbus`).
- Create a branch for your work (ex: `branch my-feature`).
- Modify Nimbus via standard ucm commands such as `edit`, `update`, etc.

**If you need to modify cloud-api**:

**After modifications**:

Run integration tests against a local cluster (see below).

## Running tests locally

You can use Docker to run a local Unison Cloud cluster. This is what our CI integration tests do, and they even run the client side of the integration tests within a docker container that is part of the `docker compose` cluster.

To run tests with a Nimbus branch from your own codebase run the following (from the top-level directory of this git repo):

```sh
NIMBUS_LOCAL_BRANCH=my-feature make integration-tests
```

Substitute `my-feature` for `main` or whatever your branch name is.

### Running Nimbus from Share

If you don't specify `NIMBUS_LOCAL_BRANCH`, the Docker builds pull from a private repo on Share, so they need credentials.

Currently the [Makefile](Makefile) expects credentials in `~/.local/share/unisonlanguage/credentials.json`. If you have run `auth.login` from ucm, then generally this file should be populated.

**NOTE:** this assumes that you have access to the [@cloud](https://share.unison-lang.org/@cloud) user on Share. If you are looking at this repo, you probably do.

```sh
make integration-tests
```

This will run the integration tests against the version of Nimbus specified at the top of the [Makefile](Makefile).

### commands

**Regenerate the configuration required for integration tests**

```
make integration-tests/lint # optional
make integration-tests/gen-configs
```

You should only need to do this if you change [integration-tests/config.dhall](/integration-tests/config.dhall).

**Build the relevant docker images**

```sh
make build
```

**Run the integration tests and then shut down the cluster**

```sh
make build integration-tests
```

**Run the integration tests against production**

``sh
make build integration-tests-cloud-client
``

**Run the cluster until interrupt**

```sh
make serve
```
