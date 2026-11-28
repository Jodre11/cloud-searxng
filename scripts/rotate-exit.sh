#!/usr/bin/env bash
# Rotate a single gluetun proxy container's Mullvad exit by restarting it.
#
# Unlike the old single-tunnel setup, searxng no longer shares a gluetun netns
# (it reaches the pool over the internal Docker network via outgoing.proxies),
# so rotating one proxy does NOT require a searxng restart. Requests routed to
# that proxy fail for ~10s (retried on the next proxy where the engine sets
# `retries`); the others keep serving.
#
# Usage: rotate-exit.sh <gluetun-a|gluetun-b|gluetun-c>
#
# Install via staggered cron in the ubuntu user's crontab (each exit refreshes once/24h, 8h apart):
#   0  2 * * *  /opt/searxng/scripts/rotate-exit.sh gluetun-a
#   0 10 * * *  /opt/searxng/scripts/rotate-exit.sh gluetun-b
#   0 18 * * *  /opt/searxng/scripts/rotate-exit.sh gluetun-c
#
# The script appends to its own log (ROTATE_LOG, default /opt/searxng/logs/rotate-exit.log). Do not redirect
# to /var/log in the cron line: it is root:syslog 775, so for the ubuntu user the shell fails to open the file
# and cron never starts the script. That is how rotation silently never ran (found 2026-11-28).
set -euo pipefail

CONTAINER="${1:?Usage: rotate-exit.sh <gluetun-a|gluetun-b|gluetun-c>}"
ROTATE_LOG="${ROTATE_LOG:-/opt/searxng/logs/rotate-exit.log}"

mkdir -p "$(dirname "$ROTATE_LOG")"
exec >>"$ROTATE_LOG" 2>&1

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

if [[ ! "$CONTAINER" =~ ^gluetun-[abc]$ ]]; then
    log "ERROR: unknown container '${CONTAINER}' (expected gluetun-a|gluetun-b|gluetun-c)"
    exit 1
fi

wait_for_container_healthy() {
    local name="$1" tries="${2:-24}" i status
    for ((i = 1; i <= tries; i++)); do
        status="$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo missing)"
        [[ "$status" == "healthy" ]] && return 0
        sleep 5
    done
    log "ERROR: $name did not become healthy after $((tries * 5))s (last: ${status:-unknown})"
    return 1
}

log "Rotating ${CONTAINER}: restarting container for a fresh Mullvad exit..."
docker restart "$CONTAINER" >/dev/null
wait_for_container_healthy "$CONTAINER"

new_exit="$(docker exec "$CONTAINER" wget -qO- https://am.i.mullvad.net/json 2>/dev/null \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["ip"], d["mullvad_exit_ip_hostname"], d["country"])' \
    2>/dev/null || echo 'unknown')"
log "${CONTAINER} new exit: ${new_exit}"

log "Rotation of ${CONTAINER} complete."
