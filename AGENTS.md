# Repository Guidelines

## Project Structure & Module Organization
- Root compose files: `sui.yml` (base stack), `rpc-shared.yml` (expose RPC locally), `ext-network.yml` (integration with central-proxy-docker), `auto-upgrade.yml` (optional auto-upgrade container).
- `default.env` is the template; create `.env` locally for overrides. `custom.yml` is an optional, untracked override file referenced via `COMPOSE_FILE`.
- `sui/` holds image assets and runtime bits: `Dockerfile.binary`, `docker-entrypoint.sh`, and peer lists such as `peers.mainnet.yml` and `peers.testnet.yml`.
- `auto-upgrade/` contains the auto-upgrade container image and script.
- Lifecycle helpers: `suid` (primary CLI) and `ethd` (same interface) wrap Docker Compose operations.

## Build, Test, and Development Commands
- `./suid install` installs Docker/Docker Compose if missing.
- `cp default.env .env` then edit `.env` (notably `NETWORK`, `DOCKER_TAG`, and `COMPOSE_FILE`).
- `./suid up` starts or updates services; `./suid down` stops them.
- `./suid update` refreshes client versions and this repo, then run `./suid up`.
- `./suid logs -f --tail 50 sui-node` tails service logs (example).
- `./suid check-sync --public-rpc <url>` compares local checkpoint height with a public RPC (defaults to https://fullnode.<network>.sui.io:443); output uses emoji status markers.
- `./suid -h` or `./ethd -h` shows top-level help; `check-sync -h` still reaches the subcommand help.
- `./suid cmd ps` runs an arbitrary `docker compose` subcommand.
- Optional auto-upgrade: include `auto-upgrade.yml` in `COMPOSE_FILE` and tune `WATCH_INTERVAL` or `SLACK_WEBHOOK_URL` in `.env`. The auto-upgrade container uses the repo directory name as the compose project name. Compose files are resolved relative to the repo.

## Coding Style & Naming Conventions
- Shell scripts use `bash` with `set -Eeuo pipefail`; keep changes consistent with existing 2-space indentation.
- Environment variables are uppercase with underscores (e.g., `DOCKER_TAG`).
- Compose service names are kebab-case (e.g., `sui-node`), and compose files use `*.yml`.

## Testing Guidelines
- No unit/integration test suite is defined.
- Run linting via `pre-commit run --all-files` (install with `pre-commit install`).
- For smoke checks, run `./suid up` and `./suid version`.

## Commit & Pull Request Guidelines
- Git history is minimal (only “initial commit”), so no established commit convention; use short, imperative messages.
- Follow the squash-and-merge workflow from `CONTRIBUTING.md`: create a branch, open a PR from it, and avoid merge commits.
- In PRs, describe config changes (e.g., compose or `.env` defaults) and include basic validation steps (e.g., `./suid up`).

## Security & Configuration Tips
- Keep secrets and host-specific settings in `.env` and do not commit them.
- If exposing RPC locally, confirm `COMPOSE_FILE` includes `rpc-shared.yml` only where intended.
