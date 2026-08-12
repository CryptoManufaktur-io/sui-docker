#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f /opt/sui/.initialized ]]; then
  wget "https://github.com/MystenLabs/sui-genesis/raw/main/${NETWORK}/genesis.blob" -O /opt/sui/config/genesis.blob
  wget https://raw.githubusercontent.com/MystenLabs/sui/main/crates/sui-config/data/fullnode-template.yaml -O /opt/sui/config/node.yml

  # Set snapshot.
  dasel put -f /opt/sui/config/node.yml -v "mysten-${NETWORK}-archives" "state-archive-read-config.[0].object-store-config.bucket"

  # Set seed peers.
  yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' /opt/sui/config/node.yml "/build/peers.${NETWORK}.yml" > /opt/sui/config/tmp.yml && mv /opt/sui/config/tmp.yml /opt/sui/config/node.yml

  # Download snapshot. SNAPSHOT_EPOCH pins a specific epoch, which is needed when the
  # node has to retain history reaching further back than the latest snapshot covers.
  # Note a snapshot for epoch N restores the object set as of the *end* of N, so the
  # node starts at the first checkpoint of N+1.
  if [[ -n "${SNAPSHOT_EPOCH:-}" ]]; then
    snapshot_selector=(--epoch "${SNAPSHOT_EPOCH}")
  else
    snapshot_selector=(--latest)
  fi
  # Restore fetches checkpoints from checkpoints.mainnet.sui.io to verify the snapshot.
  # At high concurrency those requests time out and the whole restore aborts, which
  # restarts it from scratch since .initialized is only written on success. Lower
  # SNAPSHOT_PARALLEL_DOWNLOADS if the restore fails with "operation timed out".
  sui-tool download-formal-snapshot "${snapshot_selector[@]}" --genesis /opt/sui/config/genesis.blob \
    --network "${NETWORK}" \
    --path /opt/sui/db \
    --num-parallel-downloads "${SNAPSHOT_PARALLEL_DOWNLOADS:-50}" \
    --max-retries "${SNAPSHOT_MAX_RETRIES:-3}" \
    --no-sign-request

  touch /opt/sui/.initialized
else
  echo "Already initialized!"
fi

# Update ports
dasel put -f /opt/sui/config/node.yml -v "0.0.0.0:${RPC_PORT}" json-rpc-address
dasel put -f /opt/sui/config/node.yml -v "0.0.0.0:${P2P_PORT}" p2p-config.listen-address

# Pruning. Sui prunes all historical data, not just state, so this window is how far
# back the node can still serve transactions and events. Defaults preserve the previous
# hardcoded behaviour.
dasel put -f /opt/sui/config/node.yml -t int -v "${NUM_EPOCHS_TO_RETAIN:-0}" authority-store-pruning-config.num-epochs-to-retain
dasel put -f /opt/sui/config/node.yml -t int -v "${NUM_EPOCHS_TO_RETAIN_FOR_CHECKPOINTS:-2}" authority-store-pruning-config.num-epochs-to-retain-for-checkpoints
dasel put -f /opt/sui/config/node.yml -t int -v 1 authority-store-pruning-config.periodic-compaction-threshold-days
dasel put -f /opt/sui/config/node.yml -t bool -v true authority-store-pruning-config.use-range-deletion

# RPC surface. enable-indexing serves the gRPC v2 API on the JSON-RPC port and
# enable-index-processing keeps JSON-RPC working alongside it. Both default off so
# existing deployments are unaffected.
#
# Note the gRPC index is only ever built forward from the checkpoint the node is at
# when indexing is first enabled - it does not backfill. To serve historical
# checkpoints over gRPC the node must be restored from a snapshot predating them with
# this already set, which is why these are applied before first start.
dasel put -f /opt/sui/config/node.yml -t bool -v "${RPC_ENABLE_INDEXING:-false}" rpc.enable-indexing
dasel put -f /opt/sui/config/node.yml -t bool -v "${RPC_ENABLE_INDEX_PROCESSING:-false}" rpc.enable-index-processing

# Archival fallback. State sync reads this only when the node is behind what its peers
# still retain, which is exactly the situation after restoring an older snapshot.
# Only ingestion-url is consulted; the object-store-config form in the upstream
# template is ignored. Leave ARCHIVE_INGESTION_URL empty to keep the template default.
#
# The upstream fullnode-template ships a literal placeholder here:
#   ingestion-url: https://checkpoints.<mainnet|testnet>.sui.io
# which is not a parseable URL, so sui-node panics on startup with
# "archival ingestion url must be valid: IdnaError". Leaving it in place is not an
# option - either replace it with a real URL, or drop the section entirely.
if [[ -n "${ARCHIVE_INGESTION_URL:-}" ]]; then
  # Credentials are passed as *paths*, not values: sui-node reads the file content for
  # AWS keys. This keeps them out of .env, out of `docker inspect`, out of the process
  # environment and out of node.yml. Place the files yourself with 0400 and owned by
  # the container user - nothing here creates them.
  for f in "${ARCHIVE_AWS_KEY_FILE:-}" "${ARCHIVE_AWS_SECRET_FILE:-}"; do
    if [[ -z "$f" || ! -r "$f" ]]; then
      echo "ERROR: ARCHIVE_INGESTION_URL is set but credential file '$f' is missing or unreadable." >&2
      echo "       Archival fallback would fail at runtime. Refusing to start." >&2
      exit 1
    fi
  done
  yq -i '
    .state-archive-read-config = [
      {
        "ingestion-url": strenv(ARCHIVE_INGESTION_URL),
        "concurrency": (strenv(ARCHIVE_CONCURRENCY) | tonumber),
        "remote-store-options": [
          ["aws_access_key_id", strenv(ARCHIVE_AWS_KEY_FILE)],
          ["aws_secret_access_key", strenv(ARCHIVE_AWS_SECRET_FILE)],
          ["aws_request_payer", strenv(AWS_REQUEST_PAYER)]
        ]
      }
    ]' /opt/sui/config/node.yml
else
  yq -i 'del(.state-archive-read-config)' /opt/sui/config/node.yml
fi


#shellcheck disable=SC2086
exec "$@" ${EXTRAS}
