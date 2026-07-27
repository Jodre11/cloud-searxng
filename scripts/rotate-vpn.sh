#!/usr/bin/env bash
# Rotate the Mullvad exit by restarting gluetun, then restart searxng so it
# re-attaches to gluetun's network namespace.
#
# Why searxng must restart: it runs with network_mode "service:gluetun", so it
# shares gluetun's netns. Restarting gluetun tears that netns down and searxng
# loses all networking (search endpoint returns connection-refused) until it is
# itself restarted.
#
# Install via cron on the VM (rotate twice a day):
#   0 */12 * * * /opt/searxng/scripts/rotate-vpn.sh >> /var/log/searxng-rotate.log 2>&1
set -euo pipefail

COMPOSE_DIR="/opt/searxng"
HEALTH_URL="http://localhost:8080/search?q=test&format=json"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

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

wait_for_search() {
    local tries="${1:-15}" i code
    for ((i = 1; i <= tries; i++)); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$HEALTH_URL" 2>/dev/null || echo 000)"
        [[ "$code" == "200" ]] && return 0
        sleep 4
    done
    log "ERROR: search endpoint not healthy after rotation (last HTTP: ${code:-000})"
    return 1
}

cd "$COMPOSE_DIR"

log "Rotating Mullvad exit: restarting gluetun..."
docker restart gluetun >/dev/null
wait_for_container_healthy gluetun

new_exit="$(docker exec gluetun wget -qO- https://am.i.mullvad.net/json 2>/dev/null \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["ip"], d["mullvad_exit_ip_hostname"], d["country"])' \
    2>/dev/null || echo 'unknown')"
log "New exit: ${new_exit}"

log "Restarting searxng to re-attach netns..."
docker restart searxng >/dev/null
wait_for_search

log "Rotation complete."
