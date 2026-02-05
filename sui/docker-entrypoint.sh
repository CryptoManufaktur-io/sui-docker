#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f /opt/sui/.initialized ]]; then
  wget "https://github.com/MystenLabs/sui-genesis/raw/main/${NETWORK}/genesis.blob" -O /opt/sui/config/genesis.blob
  wget https://raw.githubusercontent.com/MystenLabs/sui/main/crates/sui-config/data/fullnode-template.yaml -O /opt/sui/config/node.yml

  # Set snapshot.
  dasel put -f /opt/sui/config/node.yml -v "mysten-${NETWORK}-archives" "state-archive-read-config.[0].object-store-config.bucket"

  # Set seed peers.
  yq eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' /opt/sui/config/node.yml "/build/peers.${NETWORK}.yml" > /opt/sui/config/tmp.yml && mv /opt/sui/config/tmp.yml /opt/sui/config/node.yml

  # Download snapshot.
  sui-tool download-formal-snapshot --latest --genesis /opt/sui/config/genesis.blob \
    --network "${NETWORK}" \
    --path /opt/sui/db --num-parallel-downloads 50 --no-sign-request

  touch /opt/sui/.initialized
else
  echo "Already initialized!"
fi

# Update ports
dasel put -f /opt/sui/config/node.yml -v "0.0.0.0:${RPC_PORT}" json-rpc-address
dasel put -f /opt/sui/config/node.yml -v "0.0.0.0:${P2P_PORT}" p2p-config.listen-address

# Update pruning + archive read settings
dasel put -f /opt/sui/config/node.yml -t int -v 3 authority-store-pruning-config.num-latest-epoch-dbs-to-retain
dasel put -f /opt/sui/config/node.yml -t int -v 3600 authority-store-pruning-config.epoch-db-pruning-period-secs
dasel put -f /opt/sui/config/node.yml -t int -v 1 authority-store-pruning-config.num-epochs-to-retain
dasel put -f /opt/sui/config/node.yml -t int -v 10 authority-store-pruning-config.max-checkpoints-in-batch
dasel put -f /opt/sui/config/node.yml -t int -v 1000 authority-store-pruning-config.max-transactions-in-batch
dasel put -f /opt/sui/config/node.yml -t int -v 60 authority-store-pruning-config.pruning-run-delay-seconds

dasel put -f /opt/sui/config/node.yml -t int -v 20 state-archive-read-config.[0].object-store-config.object-store-connection-limit
dasel put -f /opt/sui/config/node.yml -t int -v 5 state-archive-read-config.[0].concurrency
dasel put -f /opt/sui/config/node.yml -t bool -v false state-archive-read-config.[0].use-for-pruning-watermark


#shellcheck disable=SC2086
exec "$@" ${EXTRAS}
