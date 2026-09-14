☁ fluffly little clouds ☁

The back end for Unison Cloud

This repository contains the source for cloud-api, but the source for nimbus lives [on Share](https://share.unison-lang.org/@cloud/p/code/latest/namespaces/private/nimbus/main).

# How cache invalidation works (cloud-api → nimbus)

When something changes that nimbus has cached — an environment losing access to a
database, a service being (re)deployed or undeployed, an env var changing — cloud-api
tells the nimbus nodes to invalidate the relevant cache. This is **synchronous**: the
triggering request does not return until every node has acknowledged it applied the
change (or a deadline trips), and each node's latency is measured so slow nodes are
visible. (This replaced an older best-effort Consul Serf-event mechanism, which could
silently drop or lag invalidations.)

## The mechanism

Each nimbus node holds one persistent websocket to a single cloud-api instance (the
BYOC cluster protocol — see `joinCluster`). Nodes are sharded across cloud-api
instances, so no single instance can reach them all directly.

A change handler calls one of the `fire*InvalidationEvent` functions
(`src/Cloud/Events.hs`), which call `invalidateSync`
(`src/Cloud/Web/Cluster/Impl.hs`). `invalidateSync`:

1. **Local delivery** (`invalidateClusterLocal`): for every node connected to *this*
   instance, it stamps a correlation id (`seq`) on the event, pushes it over the
   websocket, and blocks until the node replies `InvalidationAck {seq, applyNanos}` (or
   the ~30s deadline elapses). It records the cloud-api-measured round-trip and the
   node-reported apply time.
2. **Peer fan-out**: it discovers the other cloud-api instances from Consul (service
   `cloud-api-http`, or `cloud-api-staging-http` in staging — overridable with the
   `CLOUD_API_CONSUL_SERVICE` env var) and calls each instance's
   `POST /internal/invalidate`, which runs the same local delivery there and returns
   its per-node results.
3. **Aggregate**: local + all peer results, deduped by node id (the discovered peer
   list includes this instance, reached over loopback). Per-node latency is logged
   (`rtt=… apply=…`) — this is how you spot a slow node.

If no peers are discovered (e.g. local integration tests, where cloud-api isn't
registered in Consul) it degrades to local-only delivery — correct for a
single-instance deployment, where every node is attached to that instance.

> Note: peer discovery returning an empty list is silent and looks identical to
> "single instance," so a wrong service name only manifests once more than one
> cloud-api instance is running. Watch the `cloud-api peer discovery … found N peer(s)`
> log line.

## Node side (nimbus / Unison)

The node's websocket receive loop applies the invalidation (clears the relevant
`SemispaceCache` — e.g. `EnvironmentInvalidation` drops the cached
environment→database mapping) and then replies with `InvalidationAck` carrying the
`seq` and the measured apply duration. The apply happens first; an ack failure is
logged, never fatal. The node source lives in the `@cloud/nimbus` project on Share.



## Protocol versioning

A node advertises `protocolVersion=2` when it joins. cloud-api stamps `seq` and blocks
on acks only for V2 nodes; older (V1) nodes get the legacy fire-and-forget push (no
ack). The `seq` field is optional on the wire, so it is backward compatible in both
directions and the two repos can deploy independently.

## The invalidation events

`EnvironmentInvalidation`, `UserServiceInvalidation`, `ServiceIdInvalidation`, and
`ServiceHashInvalidation` — all constructors of the `Event` type in
`src/Cloud/Byoc/Env.hs`, all flowing through the same `invalidateSync` path.

## Key files

| Concern | File |
| --- | --- |
| `fire*InvalidationEvent` entry points | `src/Cloud/Events.hs` |
| `invalidateSync`, local delivery, peer discovery, ack waiters | `src/Cloud/Web/Cluster/Impl.hs` |
| Internal peer RPC route (`/internal/invalidate`) | `src/Cloud/Web/Internal/API.hs`, `src/Cloud/Web/Internal/Impl.hs` |
| `Event`, `NodeDelivery`/`PeerNodeResult`, websocket `Connection` | `src/Cloud/Byoc/Env.hs` |

# Running services locally

See [running-locally.md](running-locally.md).

# Running integration tests locally

This will run integration tests against a local `docker compose` cluster:

```sh
make integration-tests-small
```

