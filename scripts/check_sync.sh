#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage: check_sync.sh [options]

Options:
  --container NAME         Docker container name or ID to run curl/jq within
  --compose-service NAME   Docker Compose service name to resolve to a container
  --local-rpc URL          Local Sui JSON-RPC URL (default: http://127.0.0.1:${RPC_PORT:-9000})
  --public-rpc URL         Public/reference Sui JSON-RPC URL (default: https://fullnode.<network>.sui.io:443)
  --block-lag N            Acceptable lag in checkpoints (default: 2)
  --no-install             Do not install curl/jq inside the container
  --env-file PATH          Path to env file to load
  -h, --help               Show this help

Examples:
  ./scripts/check_sync.sh --public-rpc https://public-rpc.example
  ./scripts/check_sync.sh --compose-service sui-node --public-rpc https://public-rpc.example
  CONTAINER=sui-node-1 PUBLIC_RPC=https://public-rpc.example ./scripts/check_sync.sh
USAGE
}

ENV_FILE="${ENV_FILE:-}"
CONTAINER="${CONTAINER:-}"
DOCKER_SERVICE="${DOCKER_SERVICE:-}"
LOCAL_RPC="${LOCAL_RPC:-}"
PUBLIC_RPC="${PUBLIC_RPC:-}"
BLOCK_LAG_THRESHOLD="${BLOCK_LAG_THRESHOLD:-2}"
INSTALL_TOOLS="${INSTALL_TOOLS:-1}"

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      local key="${line%%=*}"
      local val="${line#*=}"
      val="${val#"${val%%[![:space:]]*}"}"
      if [[ "$val" =~ ^\".*\"$ ]]; then
        val="${val:1:-1}"
      elif [[ "$val" =~ ^\'.*\'$ ]]; then
        val="${val:1:-1}"
      fi
      export "${key}=${val}"
    fi
  done < "$file"
}

args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--env-file" ]]; then
    ENV_FILE="${args[$((i+1))]:-}"
  fi
done

if [[ -n "${ENV_FILE:-}" ]]; then
  load_env_file "$ENV_FILE"
elif [[ -f ".env" ]]; then
  ENV_FILE=".env"
  load_env_file "$ENV_FILE"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --container) CONTAINER="$2"; shift 2 ;;
    --compose-service) DOCKER_SERVICE="$2"; shift 2 ;;
    --local-rpc) LOCAL_RPC="$2"; shift 2 ;;
    --public-rpc) PUBLIC_RPC="$2"; shift 2 ;;
    --block-lag) BLOCK_LAG_THRESHOLD="$2"; shift 2 ;;
    --no-install) INSTALL_TOOLS="0"; shift ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 2 ;;
  esac
done

LOCAL_RPC="${LOCAL_RPC:-http://127.0.0.1:${RPC_PORT:-9000}}"

if [[ -n "$CONTAINER" && -n "$DOCKER_SERVICE" ]]; then
  echo "❌ Error: --container and --compose-service are mutually exclusive"
  exit 2
fi

default_public_rpc() {
  case "${NETWORK:-mainnet}" in
    mainnet) echo "https://fullnode.mainnet.sui.io:443" ;;
    testnet) echo "https://fullnode.testnet.sui.io:443" ;;
    devnet) echo "https://fullnode.devnet.sui.io:443" ;;
    *) echo "https://fullnode.mainnet.sui.io:443" ;;
  esac
}

if [[ -z "$PUBLIC_RPC" ]]; then
  PUBLIC_RPC="$(default_public_rpc)"
fi

if [[ ! "$BLOCK_LAG_THRESHOLD" =~ ^[0-9]+$ ]]; then
  echo "❌ Error: --block-lag must be an integer"
  exit 2
fi

resolve_container() {
  if [[ -n "$CONTAINER" || -z "$DOCKER_SERVICE" ]]; then
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Error: docker not found; cannot resolve --compose-service $DOCKER_SERVICE"
    exit 2
  fi
  if docker compose version >/dev/null 2>&1; then
    CONTAINER="$(docker compose ps -q "$DOCKER_SERVICE" | head -n 1)"
  elif command -v docker-compose >/dev/null 2>&1; then
    CONTAINER="$(docker-compose ps -q "$DOCKER_SERVICE" | head -n 1)"
  else
    echo "❌ Error: docker compose not available; cannot resolve --compose-service $DOCKER_SERVICE"
    exit 2
  fi
  if [[ -z "$CONTAINER" ]]; then
    echo "❌ Error: no running container found for service $DOCKER_SERVICE"
    exit 2
  fi
}

run_cmd() {
  if [[ -n "$CONTAINER" ]]; then
    docker exec -i "$CONTAINER" "$@"
  else
    "$@"
  fi
}

ensure_tools() {
  echo "⏳ Checking tools inside container"
  if [[ -n "$CONTAINER" ]]; then
    if [[ "$INSTALL_TOOLS" == "1" ]]; then
      docker exec -u root "$CONTAINER" sh -c '
        set -e
        if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
          exit 0
        fi
        if command -v apt-get >/dev/null 2>&1; then
          apt-get update -y
          apt-get install -y curl jq ca-certificates
        elif command -v apk >/dev/null 2>&1; then
          apk add --no-cache curl jq ca-certificates
        else
          echo "Unsupported base image. No apt-get or apk found."
          exit 1
        fi
      '
    else
      if ! run_cmd command -v curl >/dev/null 2>&1 || ! run_cmd command -v jq >/dev/null 2>&1; then
        echo "❌ error: curl and jq are required in the container. Re-run without --no-install."
        echo
        echo "❌ Final status: error"
        exit 2
      fi
    fi
    echo "✅ Tools available in container"
  else
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
      echo "❌ error: curl and jq are required on the host when no --container is set."
      echo
      echo "❌ Final status: error"
      exit 2
    fi
    echo "✅ Tools available in container"
  fi
}

rpc_call() {
  local url="$1"
  local method="$2"
  local params="${3:-[]}"
  local payload
  payload=$(printf '{"jsonrpc":"2.0","method":"%s","params":%s,"id":1}' "$method" "$params")
  run_cmd curl -sS -X POST "$url" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null
}

rpc_call_checked() {
  local url="$1"
  local method="$2"
  local params="${3:-[]}"
  local response
  response="$(rpc_call "$url" "$method" "$params")" || return 10
  if [[ -z "$response" ]]; then
    return 10
  fi
  if ! echo "$response" | run_cmd jq -e . >/dev/null 2>&1; then
    return 11
  fi
  printf '%s' "$response"
}

extract_height() {
  run_cmd jq -r '
    if (.result|type) == "string" or (.result|type) == "number" then .result
    elif .result.sequenceNumber then .result.sequenceNumber
    elif .sequenceNumber then .sequenceNumber
    elif .checkpoint.sequenceNumber then .checkpoint.sequenceNumber
    elif .result.checkpoint.sequenceNumber then .result.checkpoint.sequenceNumber
    else empty end
  '
}

extract_digest() {
  run_cmd jq -r '
    .result.digest
    // .digest
    // .checkpoint.digest
    // .result.checkpoint.digest
    // empty
  '
}

get_latest_checkpoint() {
  local url="$1"
  local response
  response="$(rpc_call_checked "$url" "sui_getLatestCheckpointSequenceNumber" "[]")" || return $?
  local height
  height=$(echo "$response" | extract_height 2>/dev/null)
  if [[ -z "$height" || "$height" == "null" ]]; then
    return 12
  fi
  printf '%s' "$height"
}

get_checkpoint_digest() {
  local url="$1"
  local checkpoint="$2"
  local response
  response="$(rpc_call_checked "$url" "sui_getCheckpoint" "[\"$checkpoint\"]")" || return $?
  local digest
  digest=$(echo "$response" | extract_digest 2>/dev/null)
  if [[ -z "$digest" || "$digest" == "null" ]]; then
    return 12
  fi
  printf '%s' "$digest"
}

emit_error_and_exit() {
  local message="$1"
  echo "$message"
  echo
  echo "❌ Final status: error"
  exit 2
}

handle_checkpoint_error() {
  local rc="$1"
  local url="$2"
  local kind="$3"
  case "$rc" in
    10) emit_error_and_exit "❌ error: RPC unreachable ($url)" ;;
    11) emit_error_and_exit "❌ error: JSON parse failure ($url)" ;;
    12)
      if [[ "$kind" == "height" ]]; then
        emit_error_and_exit "❌ error: checkpoint sequence number missing in RPC response ($url)"
      else
        emit_error_and_exit "❌ error: checkpoint digest missing in RPC response ($url)"
      fi
      ;;
    *) emit_error_and_exit "❌ error: unexpected RPC error ($url)" ;;
  esac
}

resolve_container

if [[ -n "$CONTAINER" ]]; then
  if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "❌ Error: container '$CONTAINER' not found"
    exit 2
  fi
  if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]]; then
    echo "❌ Error: container '$CONTAINER' is not running"
    exit 2
  fi
fi

ensure_tools

echo
echo "⏳ Latest block comparison"

if local_height="$(get_latest_checkpoint "$LOCAL_RPC")"; then
  :
else
  handle_checkpoint_error "$?" "$LOCAL_RPC" "height"
fi
if public_height="$(get_latest_checkpoint "$PUBLIC_RPC")"; then
  :
else
  handle_checkpoint_error "$?" "$PUBLIC_RPC" "height"
fi

if [[ ! "$local_height" =~ ^[0-9]+$ || ! "$public_height" =~ ^[0-9]+$ ]]; then
  echo "❌ error: non-numeric checkpoint sequence number detected"
  echo
  echo "❌ Final status: error"
  exit 2
fi

if local_digest="$(get_checkpoint_digest "$LOCAL_RPC" "$local_height")"; then
  :
else
  handle_checkpoint_error "$?" "$LOCAL_RPC" "digest"
fi
if public_digest="$(get_checkpoint_digest "$PUBLIC_RPC" "$public_height")"; then
  :
else
  handle_checkpoint_error "$?" "$PUBLIC_RPC" "digest"
fi

lag=$((public_height - local_height))

# Determine lag direction
if (( lag < 0 )); then
  lag_direction="local ahead"
  lag_abs=$(( -lag ))
elif (( lag > 0 )); then
  lag_direction="local behind"
  lag_abs=$lag
else
  lag_direction="in sync"
  lag_abs=0
fi

echo "Local latest:  $local_height $local_digest"
echo "Public latest: $public_height $public_digest"
echo "Lag:         $lag_abs blocks (threshold: $BLOCK_LAG_THRESHOLD) ($lag_direction)"

# Check for divergence at same height
if [[ "$local_height" == "$public_height" && "$local_digest" != "$public_digest" ]]; then
  echo "❌ error: checkpoint digests differ at same height"
  echo
  echo "❌ Final status: error"
  exit 2
fi

# Determine final status
if (( lag < 0 )); then
  # Local is ahead of public
  echo
  echo "✅ Final status: in sync"
  exit 0
elif (( lag_abs > BLOCK_LAG_THRESHOLD )); then
  echo
  echo "⏳ Final status: syncing"
  exit 1
else
  echo
  echo "✅ Final status: in sync"
  exit 0
fi
