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

## Customization

`custom.yml` is not tracked by git and can be used to override anything in the provided yml files. If you use it,
add it to `COMPOSE_FILE` in `.env`

## Auto-upgrade (optional)

An optional containerized auto-upgrade job is provided in `auto-upgrade.yml`. It mounts the repo and Docker socket,
polls GitHub releases, updates `DOCKER_TAG` in `.env`, rebuilds, and restarts the stack.

To enable it, add `auto-upgrade.yml` to `COMPOSE_FILE` in `.env`, e.g.:

`COMPOSE_FILE=sui.yml:auto-upgrade.yml`

You can tune behavior via `.env`: `WATCH_INTERVAL`, `RUN_ONCE`, `SERVICE_NAME`, `SLACK_WEBHOOK_URL`, `SLACK_NO_UPDATE`.

## Version

Sui Docker uses a semver scheme.

This is Sui Docker v1.0.0
