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


#shellcheck disable=SC2086
exec "$@" ${EXTRAS}
