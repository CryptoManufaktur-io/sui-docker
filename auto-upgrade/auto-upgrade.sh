#!/usr/bin/env bash
set -Eeuo pipefail

REPO_DIR=${REPO_DIR:-/workspace}
ENV_FILE=${ENV_FILE:-${REPO_DIR}/.env}
WATCH_INTERVAL=${WATCH_INTERVAL:-3600}
RUN_ONCE=${RUN_ONCE:-0}
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL:-}
SLACK_NO_UPDATE=${SLACK_NO_UPDATE:-0}
GITHUB_API=${GITHUB_API:-https://api.github.com}
SERVICE_NAME=${SERVICE_NAME:-sui-node}
COMPOSE_ARGS=()
PROJECT_NAME=

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
}

slack() {
  local message="$1"
  if [ -n "${SLACK_WEBHOOK_URL}" ]; then
    curl -fsSL -X POST -H 'Content-type: application/json' \
      --data "{\"text\": \"${message}\"}" \
      "${SLACK_WEBHOOK_URL}" >/dev/null || true
  fi
}

env_get() {
  local key="$1"
  awk -F= -v k="${key}" '$1==k {sub(/^[^=]*=/, ""); print; found=1; exit} END{if(!found) exit 1}' "${ENV_FILE}"
}

env_set() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "${ENV_FILE}"; then
    sed -i "s/^${key}=.*/${key}=${value}/" "${ENV_FILE}"
  else
    echo "${key}=${value}" >> "${ENV_FILE}"
  fi
}

resolve_compose_files() {
  if [ "${#COMPOSE_ARGS[@]}" -gt 0 ]; then
    return
  fi

  PROJECT_NAME=$(basename "${REPO_DIR}")

  local raw
  raw=$(env_get COMPOSE_FILE || true)
  if [ -z "${raw}" ]; then
    raw="sui.yml"
  fi

  local IFS=:
  local part
  read -r -a parts <<< "${raw}"
  for part in "${parts[@]}"; do
    if [ -z "${part}" ]; then
      continue
    fi
    if [[ "${part}" = /* ]]; then
      COMPOSE_ARGS+=(-f "${part}")
    else
      COMPOSE_ARGS+=(-f "${REPO_DIR}/${part}")
    fi
  done
}

compose() {
  resolve_compose_files
  docker compose --project-directory "${REPO_DIR}" --env-file "${ENV_FILE}" --project-name "${PROJECT_NAME}" "${COMPOSE_ARGS[@]}" "$@"
}

fetch_latest_tag() {
  local network="$1"
  local releases
  releases=$(curl -fsSL "${GITHUB_API}/repos/MystenLabs/sui/releases?per_page=100")
  echo "${releases}" \
    | jq -r '.[].tag_name' \
    | grep -E "^${network}-" \
    | sort -V \
    | tail -n1
}

upgrade_once() {
  if [ ! -f "${ENV_FILE}" ]; then
    log "Missing ${ENV_FILE}. Aborting."
    exit 1
  fi

  COMPOSE_ARGS=()
  local current_tag network latest_tag backup container_id status
  current_tag=$(env_get DOCKER_TAG || true)
  network=$(env_get NETWORK || true)

  if [ -z "${network}" ] && [ -n "${current_tag}" ]; then
    network="${current_tag%%-*}"
  fi

  if [ -z "${network}" ]; then
    log "Unable to determine NETWORK from ${ENV_FILE}."
    exit 1
  fi

  if [ -z "${current_tag}" ]; then
    log "DOCKER_TAG not set in ${ENV_FILE}."
    exit 1
  fi

  latest_tag=$(fetch_latest_tag "${network}")
  if [ -z "${latest_tag}" ] || [ "${latest_tag}" = "null" ]; then
    log "Unable to resolve latest tag for ${network}."
    exit 1
  fi

  if [ "${current_tag}" = "${latest_tag}" ]; then
    log "No update needed (${current_tag})."
    if [ "${SLACK_NO_UPDATE}" = "1" ]; then
      slack "✅ No upgrade needed. Sui ${network} is already ${current_tag}."
    fi
    return 0
  fi

  log "Updating ${current_tag} -> ${latest_tag}."
  backup="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp "${ENV_FILE}" "${backup}"
  env_set DOCKER_TAG "${latest_tag}"

  if ! compose build --pull; then
    log "Build failed. Rolling back."
    cp "${backup}" "${ENV_FILE}"
    compose build --pull || true
    compose up -d || true
    slack "❌ Upgrade failed for Sui ${network}. Build error. Rolled back to ${current_tag}."
    exit 1
  fi

  if ! compose up -d; then
    log "Startup failed. Rolling back."
    cp "${backup}" "${ENV_FILE}"
    compose build --pull || true
    compose up -d || true
    slack "❌ Upgrade failed for Sui ${network}. Startup error. Rolled back to ${current_tag}."
    exit 1
  fi

  container_id=$(compose ps -q "${SERVICE_NAME}" || true)
  if [ -z "${container_id}" ]; then
    log "Unable to find container for ${SERVICE_NAME}."
    slack "⚠️ Upgrade completed to ${latest_tag} but ${SERVICE_NAME} container ID not found."
    return 0
  fi

  status=$(docker inspect -f '{{.State.Status}}' "${container_id}" 2>/dev/null || true)
  if [ "${status}" != "running" ]; then
    log "Container not running (status=${status}). Rolling back."
    cp "${backup}" "${ENV_FILE}"
    compose build --pull || true
    compose up -d || true
    slack "❌ Upgrade failed for Sui ${network}. Container status=${status}. Rolled back to ${current_tag}."
    exit 1
  fi

  slack "🎉 Upgraded Sui ${network} to ${latest_tag}."
}

main() {
  local lock_file=/tmp/sui-watchdog.lock
  exec 9>"${lock_file}"
  if ! flock -n 9; then
    log "Another upgrade run is in progress."
    exit 0
  fi

  if [ "${RUN_ONCE}" = "1" ]; then
    upgrade_once
    exit 0
  fi

  while true; do
    upgrade_once || true
    sleep "${WATCH_INTERVAL}"
  done
}

main "$@"
