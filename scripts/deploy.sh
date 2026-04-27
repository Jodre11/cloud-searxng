#!/usr/bin/env bash
# Deploy or update the SearXNG stack on the Oracle Cloud VM.
# Usage: deploy.sh <host> [--first-run]
set -euo pipefail

HOST="${1:?Usage: deploy.sh <host> [--first-run]}"
FIRST_RUN="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_DIR="$(cd "$SCRIPT_DIR/../compose" && pwd)"
REMOTE_DIR="/opt/searxng"

echo "Syncing compose files to ${HOST}:${REMOTE_DIR}..."
rsync -avz --exclude='.env.example' \
    "${COMPOSE_DIR}/" \
    "ubuntu@${HOST}:${REMOTE_DIR}/"

echo "Syncing scripts to ${HOST}:${REMOTE_DIR}/scripts/..."
rsync -avz \
    "${SCRIPT_DIR}/health-check.sh" \
    "ubuntu@${HOST}:${REMOTE_DIR}/scripts/"

if [[ "$FIRST_RUN" == "--first-run" ]]; then
    echo "First run: setting up Tailscale..."
    # shellcheck disable=SC2029
    ssh "ubuntu@${HOST}" "sudo tailscale up --authkey=\$(grep TAILSCALE_AUTHKEY ${REMOTE_DIR}/.env | cut -d= -f2) --ssh"
fi

echo "Starting stack..."
# shellcheck disable=SC2029
ssh "ubuntu@${HOST}" "cd ${REMOTE_DIR} && docker compose up -d"

echo "Waiting for health checks..."
sleep 15

# shellcheck disable=SC2029
ssh "ubuntu@${HOST}" "docker compose -f ${REMOTE_DIR}/docker-compose.yml ps"

echo "Deploy complete."
