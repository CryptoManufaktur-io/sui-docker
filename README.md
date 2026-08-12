# Overview

Docker Compose for Sui

Meant to be used with [central-proxy-docker](https://github.com/CryptoManufaktur-io/central-proxy-docker) for traefik
and Prometheus remote write; use `:ext-network.yml` in `COMPOSE_FILE` inside `.env` in that case.

If you want the RPC ports exposed locally, use `rpc-shared.yml` in `COMPOSE_FILE` inside `.env`.

## Quick Start

The `./suid` script can be used as a quick-start:

`./suid install` brings in docker-ce, if you don't have Docker installed already.

`cp default.env .env`

`nano .env` and adjust variables as needed, particularly NETWORK and DOCKER_TAG.

`./suid up`

## Software update

To update the software, run `./suid update` and then `./suid up`

## Sync check

Compare your local node against a public RPC:

`./suid check-sync`

Override the public endpoint if needed:
`./suid check-sync --public-rpc https://public-rpc.example`

The command reads `.env` if present and uses `RPC_PORT` for the local endpoint. By default it uses the `sui-node` compose service and https://fullnode.<network>.sui.io:443 based on `NETWORK`.

## Pruning

Sui prunes transactions, events and checkpoints, not just state.

- `NUM_EPOCHS_TO_RETAIN` — epochs of historical object versions (default `0`)
- `NUM_EPOCHS_TO_RETAIN_FOR_CHECKPOINTS` — epochs of transactions and checkpoints (default `2`)

An epoch is ~24h. Raising these increases disk usage substantially.

## gRPC API

gRPC v2 is served on `RPC_PORT`, but only when indexing is enabled:

```
RPC_ENABLE_INDEXING=true          # serves gRPC
RPC_ENABLE_INDEX_PROCESSING=true  # keeps JSON-RPC working alongside it
```

The gRPC index builds forward from wherever the node is when indexing is first enabled;
it does not backfill. To serve historical checkpoints over gRPC, restore from a snapshot
predating them with indexing already on. JSON-RPC and gRPC read from different stores, so
JSON-RPC answering for an old checkpoint does not mean gRPC can.

Enabling indexing on an existing node triggers a full rebuild, during which RPC is offline.

### Exposing gRPC through Traefik

`grpc.yml` publishes gRPC on its own hostname over h2c, gated on a token header. Add it to
`COMPOSE_FILE` and set `GRPC_HOST` and `GRPC_TOKEN`. It is a separate overlay so that an
unset host does not trigger certificate requests, and an empty token does not leave an
ungated route.

Requests without a valid token get a 404, not a 401. Use an auth sidecar if you need 401
or multiple header names.

## Restoring from a specific epoch

`SNAPSHOT_EPOCH` pins the formal snapshot to an epoch instead of the latest. Applies only
on first initialisation.

A snapshot for epoch N restores state as of the **end** of N, so the node starts at the
first checkpoint of N+1. To keep history from within epoch N, restore from N-1.

`SNAPSHOT_PARALLEL_DOWNLOADS` and `SNAPSHOT_MAX_RETRIES` tune the restore. Restore verifies
against `checkpoints.mainnet.sui.io`; at high concurrency those requests time out and abort
the restore, which then starts over. Lower `SNAPSHOT_PARALLEL_DOWNLOADS` if you see
`operation timed out`.

## Archival fallback

State sync reads the archive only when the node is behind what peers retain (~1-2 epochs),
i.e. after restoring an older snapshot or extended downtime. Without it, sync stops and
logs `Failed to find an archive reader to complete the state sync request`.

```
ARCHIVE_INGESTION_URL=https://s3.us-west-2.amazonaws.com/mysten-mainnet-checkpoints
ARCHIVE_CONCURRENCY=20
ARCHIVE_AWS_KEY_FILE=/opt/sui/creds/access_key_id
ARCHIVE_AWS_SECRET_FILE=/opt/sui/creds/secret_access_key
AWS_REQUEST_PAYER=true
```

The mainnet bucket is requester-pays: credentials are required and egress is billed to your
account. It is idle in normal operation, so leaving it configured costs nothing.

Credentials are **paths to files**, not values — `sui-node` reads the file content, keeping
them out of `.env` and `docker inspect`. Create them under the data volume, owned by uid
10001, mode 0400, with no trailing newline (`printf '%s'`, not `echo`). The node refuses to
start if the files are missing.

An empty `ARCHIVE_INGESTION_URL` removes the section entirely. The upstream fullnode
template ships an unparseable placeholder (`https://checkpoints.<mainnet|testnet>.sui.io`)
which otherwise panics the node with `archival ingestion url must be valid`.

## Customization

`custom.yml` is not tracked by git and can be used to override anything in the provided yml files. If you use it,
add it to `COMPOSE_FILE` in `.env`

## Auto-upgrade (optional)

An optional containerized auto-upgrade job is provided in `auto-upgrade.yml`. It mounts the repo and Docker socket,
polls GitHub releases, updates `DOCKER_TAG` in `.env`, rebuilds, and restarts the stack.

To enable it, add `auto-upgrade.yml` to `COMPOSE_FILE` in `.env`, e.g.:

`COMPOSE_FILE=sui.yml:auto-upgrade.yml`

You can tune behavior via `.env`: `WATCH_INTERVAL`, `RUN_ONCE`, `SERVICE_NAME`, `SLACK_WEBHOOK_URL`, `SLACK_NO_UPDATE`.
The auto-upgrade container uses the repo directory name as the compose project name.

### Slack notifications

Slack notifications are only sent if `SLACK_WEBHOOK_URL` is set.

- **No upgrade needed**: sends a ✅ notification only when `SLACK_NO_UPDATE=1`.
- **Upgrade success**: sends a 🎉 notification after the new container is running.
- **Upgrade failure**: sends a ❌ notification and rolls back `DOCKER_TAG` when build or startup fails.

### Upgrade flow (summary)

1. Resolve the latest GitHub release tag for the configured network.
2. If the latest tag matches `DOCKER_TAG`, exit (optionally Slack-notify if `SLACK_NO_UPDATE=1`).
3. If a newer tag is found, update `DOCKER_TAG`, rebuild, and restart the service.
4. On failure (build/startup/container not running), restore the previous `.env` and attempt to restart it.

## Version

Sui Docker uses a semver scheme.

This is Sui Docker v1.0.0
