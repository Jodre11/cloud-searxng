#!/usr/bin/env bash
# Rotate a single gluetun proxy container's Mullvad exit by restarting it.
#
# Unlike the old single-tunnel setup, searxng no longer shares a gluetun netns
# (it reaches the pool over the internal Docker network via outgoing.proxies),
# so rotating one proxy does NOT require a searxng restart. httpx sees
# connection-refused on that one proxy for ~10s and keeps using the others.
#
# Usage: rotate-exit.sh <gluetun-a|gluetun-b|gluetun-c>
#
# Install via staggered cron on the VM (each exit refreshes once/24h, 8h apart):
#   0  2 * * *  /opt/searxng/scripts/rotate-exit.sh gluetun-a >> /var/log/searxng-rotate.log 2>&1
#   0 10 * * *  /opt/searxng/scripts/rotate-exit.sh gluetun-b >> /var/log/searxng-rotate.log 2>&1
#   0 18 * * *  /opt/searxng/scripts/rotate-exit.sh gluetun-c >> /var/log/searxng-rotate.log 2>&1
set -euo pipefail

CONTAINER="${1:?Usage: rotate-exit.sh <gluetun-a|gluetun-b|gluetun-c>}"

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
