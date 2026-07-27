# VPN Exit Pool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Distribute SearXNG search egress across a pool of 3 Mullvad exit IPs so concurrent research bursts spread across exits instead of hammering one, with staggered per-exit rotation for freshness.

**Architecture:** Replace the single gluetun container (which searxng shares a netns with) with 3 gluetun HTTP-proxy containers, each pinned to a different Mullvad exit. searxng becomes a normal container on a private Docker network and uses SearXNG's native `outgoing.proxies` list, whose httpx client round-robins requests across the 3 proxies. A generalised `rotate-exit.sh <container>` restarts one proxy at a time on a staggered cron.

**Tech Stack:** Docker Compose, gluetun (WireGuard + built-in HTTP proxy), SearXNG (httpx-based outgoing proxy support), Caddy, bash, cron.

## Global Constraints

- **Pool size = 3 exits.** Mullvad allows 5 simultaneous connections per account; 3 leaves 2 for other devices. Do not exceed 3 without a second account.
- **Each of the 3 tunnels needs its OWN Mullvad WireGuard key/config.** Reusing one key across 3 concurrent tunnels breaks Mullvad-side routing. Three distinct `WIREGUARD_PRIVATE_KEY` + `WIREGUARD_ADDRESSES` pairs are required.
- **searxng must have NO direct WAN route** — its only egress is via the proxies (fail-closed, no IP leak).
- Instance is private (Tailscale-only, no public ingress), single-user. Incoming limiter stays `false`.
- All bash scripts: `#!/usr/bin/env bash`, `set -euo pipefail`, 4-space indent, ≤120 cols.
- Verification is against the real Docker stack (local `docker compose` or the OCI VM via `ssh ubuntu@searxng`), not a unit-test framework. Each task ends with a concrete runnable check.
- Deploy target paths on VM: compose at `/opt/searxng`, scripts at `/opt/searxng/scripts`.

---

## File Structure

- `compose/docker-compose.yml` (modify) — replace single `gluetun` with `gluetun-a/b/c`; detach searxng from gluetun netns onto a private network; repoint caddy.
- `compose/.env.example` (modify) — 3 WireGuard key/address pairs + shared country pool.
- `compose/searxng/settings.yml` (modify) — add `outgoing.proxies` list.
- `scripts/rotate-exit.sh` (create) — rotate a single named gluetun container, no searxng restart.
- `scripts/rotate-vpn.sh` (delete) — superseded.
- `scripts/deploy.sh` (modify) — sync `rotate-exit.sh` instead of `rotate-vpn.sh`.
- `README.md` (modify) — document pool architecture, 3-key requirement, staggered rotation cron.

---

## Task 1: Compose — 3 gluetun proxy containers + detached searxng

**Files:**
- Modify: `compose/docker-compose.yml`
- Modify: `compose/.env.example`

**Interfaces:**
- Produces: three proxy endpoints reachable on the `internal` Docker network as `http://gluetun-a:8888`, `http://gluetun-b:8888`, `http://gluetun-c:8888`; searxng reachable to caddy as `searxng:8080`.
- Consumes: env vars `WIREGUARD_PRIVATE_KEY_A/B/C`, `WIREGUARD_ADDRESSES_A/B/C`, `VPN_PROVIDER`, `VPN_SERVER_COUNTRIES`, `SEARXNG_SECRET_KEY`.

**Network topology (enforces fail-closed):** Two Docker networks. `internal` (`internal: true`, no WAN gateway) carries searxng ⇄ proxies ⇄ caddy. `wan` (normal bridge) carries only the 3 gluetun containers' outbound tunnel traffic. searxng and caddy are on `internal` ONLY, so they have no direct WAN route — searxng's sole egress is the proxies. Each gluetun sits on BOTH networks: it receives proxy requests on `internal` and egresses via `wan`. The `internal` subnet is pinned (`172.28.0.0/16`) so gluetun's killswitch can be told to allow return traffic to it via `FIREWALL_OUTBOUND_SUBNETS`.

- [ ] **Step 1: Update `.env.example` with 3 key pairs**

Replace the single VPN block in `compose/.env.example` with:

```bash
# VPN (Mullvad) — THREE separate WireGuard configs, one per exit.
# Generate 3 configs at https://mullvad.net/en/account/wireguard-config
# (each "Generate key" gives a distinct private key + address). Reusing one
# key across all three tunnels breaks Mullvad routing.
VPN_PROVIDER=mullvad
VPN_SERVER_COUNTRIES=Sweden,Switzerland,Netherlands

WIREGUARD_PRIVATE_KEY_A=PASTE_VALUE_HERE
WIREGUARD_ADDRESSES_A=10.x.x.x/32
WIREGUARD_PRIVATE_KEY_B=PASTE_VALUE_HERE
WIREGUARD_ADDRESSES_B=10.x.x.x/32
WIREGUARD_PRIVATE_KEY_C=PASTE_VALUE_HERE
WIREGUARD_ADDRESSES_C=10.x.x.x/32

# SearXNG
SEARXNG_SECRET_KEY=PASTE_VALUE_HERE

# Tailscale (used by deploy script, not compose)
TAILSCALE_AUTHKEY=tskey-auth-PASTE_VALUE_HERE

# Better Stack (used by health-check cron)
BETTERSTACK_HEARTBEAT_URL=https://uptime.betterstack.com/api/v1/heartbeat/PASTE_VALUE_HERE
```

- [ ] **Step 2: Rewrite `docker-compose.yml`**

Replace the whole file with:

```yaml
services:
  gluetun-a:
    image: qmcgaw/gluetun:latest
    container_name: gluetun-a
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=${VPN_PROVIDER}
      - VPN_TYPE=wireguard
      - WIREGUARD_PRIVATE_KEY=${WIREGUARD_PRIVATE_KEY_A}
      - WIREGUARD_ADDRESSES=${WIREGUARD_ADDRESSES_A}
      - SERVER_COUNTRIES=${VPN_SERVER_COUNTRIES}
      - HTTPPROXY=on
      - HTTPPROXY_LISTENING_ADDRESS=:8888
      # Allow the killswitch to return proxy responses to the internal subnet.
      - FIREWALL_OUTBOUND_SUBNETS=172.28.0.0/16
      - TZ=Europe/London
      - UPDATER_PERIOD=24h
    networks:
      - internal
      - wan
    volumes:
      - gluetun-a-data:/gluetun
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null https://am.i.mullvad.net/connected || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  gluetun-b:
    image: qmcgaw/gluetun:latest
    container_name: gluetun-b
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=${VPN_PROVIDER}
      - VPN_TYPE=wireguard
      - WIREGUARD_PRIVATE_KEY=${WIREGUARD_PRIVATE_KEY_B}
      - WIREGUARD_ADDRESSES=${WIREGUARD_ADDRESSES_B}
      - SERVER_COUNTRIES=${VPN_SERVER_COUNTRIES}
      - HTTPPROXY=on
      - HTTPPROXY_LISTENING_ADDRESS=:8888
      - FIREWALL_OUTBOUND_SUBNETS=172.28.0.0/16
      - TZ=Europe/London
      - UPDATER_PERIOD=24h
    networks:
      - internal
      - wan
    volumes:
      - gluetun-b-data:/gluetun
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null https://am.i.mullvad.net/connected || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  gluetun-c:
    image: qmcgaw/gluetun:latest
    container_name: gluetun-c
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=${VPN_PROVIDER}
      - VPN_TYPE=wireguard
      - WIREGUARD_PRIVATE_KEY=${WIREGUARD_PRIVATE_KEY_C}
      - WIREGUARD_ADDRESSES=${WIREGUARD_ADDRESSES_C}
      - SERVER_COUNTRIES=${VPN_SERVER_COUNTRIES}
      - HTTPPROXY=on
      - HTTPPROXY_LISTENING_ADDRESS=:8888
      - FIREWALL_OUTBOUND_SUBNETS=172.28.0.0/16
      - TZ=Europe/London
      - UPDATER_PERIOD=24h
    networks:
      - internal
      - wan
    volumes:
      - gluetun-c-data:/gluetun
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null https://am.i.mullvad.net/connected || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  searxng:
    image: searxng/searxng:latest
    container_name: searxng
    restart: unless-stopped
    networks:
      - internal
    depends_on:
      gluetun-a:
        condition: service_healthy
      gluetun-b:
        condition: service_healthy
      gluetun-c:
        condition: service_healthy
    volumes:
      - ./searxng/settings.yml:/etc/searxng/settings.yml:ro
    environment:
      - SEARXNG_SECRET_KEY=${SEARXNG_SECRET_KEY}
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETGID
      - SETUID
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://localhost:8080/healthz || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s

  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    networks:
      - internal
    ports:
      - "8888:8888"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    depends_on:
      searxng:
        condition: service_healthy

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    environment:
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
      - WATCHTOWER_INCLUDE_STOPPED=true
      - WATCHTOWER_REVIVE_STOPPED=true
      - DOCKER_API_VERSION=1.40
      - TZ=Europe/London
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro

networks:
  # No WAN gateway — searxng/caddy sit here and cannot reach the internet
  # except via the gluetun proxies (fail-closed, no IP leak). Subnet pinned so
  # gluetun's killswitch can allow return traffic via FIREWALL_OUTBOUND_SUBNETS.
  internal:
    driver: bridge
    internal: true
    ipam:
      config:
        - subnet: 172.28.0.0/16
  # Normal bridge; only the gluetun containers attach here for tunnel egress.
  wan:
    driver: bridge

volumes:
  gluetun-a-data:
  gluetun-b-data:
  gluetun-c-data:
  caddy-data:
  caddy-config:
```

Notes:
- The host port mapping stays `8888:8888` on caddy (caddy's own listener, unrelated to gluetun's internal `:8888` proxy port — different network namespaces, no clash).
- `watchtower` needs no network (it only talks to the Docker socket).
- If a gluetun container fails to answer proxy requests after this change, confirm `FIREWALL_OUTBOUND_SUBNETS` matches the actual `internal` subnet Docker assigned (`docker network inspect searxng_internal`); adjust the pinned subnet if it differs.

- [ ] **Step 3: Validate compose syntax**

Run: `docker compose -f compose/docker-compose.yml config >/dev/null`
Expected: no error, exits 0 (warns about unset env vars is fine if `.env` absent locally; validate structure only).

- [ ] **Step 4: Commit**

```bash
git add compose/docker-compose.yml compose/.env.example
git commit -m "Replace single gluetun with 3-exit proxy pool"
```

---

## Task 2: SearXNG outgoing proxy distribution

**Files:**
- Modify: `compose/searxng/settings.yml`

**Interfaces:**
- Consumes: proxy endpoints `http://gluetun-a:8888`, `http://gluetun-b:8888`, `http://gluetun-c:8888` from Task 1.
- Produces: searxng configured to round-robin outgoing engine requests across the 3 proxies.

- [ ] **Step 1: Add `outgoing.proxies` to the existing `outgoing` block**

In `compose/searxng/settings.yml`, extend the `outgoing:` section (currently ends after `pool_maxsize: 20`) so it reads:

```yaml
outgoing:
  request_timeout: 6.0
  max_request_timeout: 10.0
  pool_connections: 100
  pool_maxsize: 20
  # Distribute outgoing engine requests across the gluetun proxy pool. httpx
  # round-robins the list per request, so a concurrent research burst spreads
  # across 3 Mullvad exit IPs instead of hammering one.
  proxies:
    all://:
      - http://gluetun-a:8888
      - http://gluetun-b:8888
      - http://gluetun-c:8888
```

- [ ] **Step 2: Validate YAML parses**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('compose/searxng/settings.yml')); print('OK')"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add compose/searxng/settings.yml
git commit -m "Route SearXNG egress through the gluetun proxy pool"
```

---

## Task 3: `rotate-exit.sh` — single-exit staggered rotation

**Files:**
- Create: `scripts/rotate-exit.sh`
- Delete: `scripts/rotate-vpn.sh`
- Modify: `scripts/deploy.sh:18-21`

**Interfaces:**
- Consumes: a gluetun container name argument (`gluetun-a` | `gluetun-b` | `gluetun-c`).
- Produces: rotates that one container's Mullvad exit, waits for healthy, logs the new exit IP. Does NOT restart searxng.

- [ ] **Step 1: Create `scripts/rotate-exit.sh`**

```bash
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
```

- [ ] **Step 2: Make executable and delete the superseded script**

```bash
chmod +x scripts/rotate-exit.sh
git rm scripts/rotate-vpn.sh
```

- [ ] **Step 3: Update `deploy.sh` to sync the new script**

In `scripts/deploy.sh`, change the scripts rsync block from:

```bash
rsync -avz \
    "${SCRIPT_DIR}/health-check.sh" \
    "${SCRIPT_DIR}/rotate-vpn.sh" \
    "ubuntu@${HOST}:${REMOTE_DIR}/scripts/"
```

to:

```bash
rsync -avz \
    "${SCRIPT_DIR}/health-check.sh" \
    "${SCRIPT_DIR}/rotate-exit.sh" \
    "ubuntu@${HOST}:${REMOTE_DIR}/scripts/"
```

- [ ] **Step 4: Lint the new script**

Run: `bash -n scripts/rotate-exit.sh`
Expected: no output, exit 0. (If `shellcheck` is available: `shellcheck scripts/rotate-exit.sh` — expect no errors.)

- [ ] **Step 5: Commit**

```bash
git add scripts/rotate-exit.sh scripts/deploy.sh
git commit -m "Add per-exit rotation script, retire single-tunnel rotate-vpn.sh"
```

---

## Task 4: Documentation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: architecture and cron from Tasks 1–3.
- Produces: README reflecting the pool architecture, 3-key requirement, and staggered rotation cron.

- [ ] **Step 1: Update the VPN egress description**

In `README.md`, update the architecture/feature text so the egress diagram and prose describe 3 gluetun proxy containers feeding searxng via `outgoing.proxies`, replacing the single-tunnel `network_mode: service:gluetun` description. Use this diagram:

```
   searxng ──▶ outgoing.proxies (httpx round-robin, per request)
                 ├─▶ gluetun-a  HTTP proxy  ─▶ Mullvad exit 1
                 ├─▶ gluetun-b  HTTP proxy  ─▶ Mullvad exit 2
                 └─▶ gluetun-c  HTTP proxy  ─▶ Mullvad exit 3
```

- [ ] **Step 2: Update the env-var table**

Replace the single `WIREGUARD_PRIVATE_KEY` / `WIREGUARD_ADDRESSES` rows with the three lettered pairs, and add a note: "Three separate Mullvad WireGuard configs are required — one per exit. Generate each at the Mullvad account WireGuard-config page; do not reuse one key across tunnels."

- [ ] **Step 3: Replace the rotation cron section**

Replace the "VPN Exit Rotation Cron" section's single-line cron with the staggered trio:

```bash
crontab -l 2>/dev/null | { cat; \
  echo '0  2 * * * /opt/searxng/scripts/rotate-exit.sh gluetun-a >> /var/log/searxng-rotate.log 2>&1'; \
  echo '0 10 * * * /opt/searxng/scripts/rotate-exit.sh gluetun-b >> /var/log/searxng-rotate.log 2>&1'; \
  echo '0 18 * * * /opt/searxng/scripts/rotate-exit.sh gluetun-c >> /var/log/searxng-rotate.log 2>&1'; \
} | crontab -
```

And explain: exits refresh once per 24h, 8h apart, so at most one is mid-rotation at any instant and the pool is never more than 1/3 degraded.

- [ ] **Step 4: Update the Project Structure tree**

Change the `scripts/` listing: replace `rotate-vpn.sh` with `rotate-exit.sh # Rotate one gluetun exit (staggered pool rotation)`.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Document VPN exit pool architecture and staggered rotation"
```

---

## Task 5: Live deploy & verification

**Files:** none (operational).

**Interfaces:**
- Consumes: everything from Tasks 1–4, plus a real `.env` on the VM with 3 valid Mullvad key pairs.

- [ ] **Step 1: Prerequisite — 3 Mullvad configs in the VM `.env`**

Confirm `/opt/searxng/.env` on the VM has `WIREGUARD_PRIVATE_KEY_A/B/C` and `WIREGUARD_ADDRESSES_A/B/C` filled with 3 distinct Mullvad WireGuard configs. If not, generate them at the Mullvad account page and populate. (This is a manual/human step — the keys are secrets, not in the repo.)

- [ ] **Step 2: Deploy**

Run: `bash scripts/deploy.sh <vm-ip-or-searxng>`
Expected: rsync completes; `docker compose up -d` recreates the stack; `docker compose ps` shows `gluetun-a/b/c` healthy, `searxng` healthy, `caddy` and `watchtower` up.

- [ ] **Step 3: Verify 3 distinct exit IPs**

Run (on VM):
```bash
for c in gluetun-a gluetun-b gluetun-c; do \
  ssh ubuntu@searxng "docker exec $c wget -qO- https://am.i.mullvad.net/json" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["mullvad_exit_ip_hostname"],d["ip"])'; done
```
Expected: 3 different hostnames/IPs. (Note: run each ssh as a separate call per the repo's bash rules; the loop is illustrative.)

- [ ] **Step 4: Verify search works through the pool**

Run: `ssh ubuntu@searxng "curl -s 'http://localhost:8080/search?q=test&format=json' -o /dev/null -w '%{http_code}'"`
Expected: `200`.

- [ ] **Step 5: Verify burst spreads across exits**

Fire ~15 concurrent searches, then inspect each gluetun's logs for outbound activity:
```bash
ssh ubuntu@searxng "for i in \$(seq 1 15); do curl -s 'http://localhost:8080/search?q=test'\$i -o /dev/null & done; wait"
ssh ubuntu@searxng "docker logs gluetun-a --since 1m 2>&1 | grep -c GET"
ssh ubuntu@searxng "docker logs gluetun-b --since 1m 2>&1 | grep -c GET"
ssh ubuntu@searxng "docker logs gluetun-c --since 1m 2>&1 | grep -c GET"
```
Expected: all three counters > 0 (traffic distributed). Note: gluetun HTTP-proxy request logging requires `HTTPPROXY_LOG=on`; if counts read 0, temporarily enable it to confirm distribution, then set back to `off`.

- [ ] **Step 6: Verify rotation keeps search alive**

Run: `ssh ubuntu@searxng "/opt/searxng/scripts/rotate-exit.sh gluetun-b"` and, concurrently or immediately after, `ssh ubuntu@searxng "curl -s 'http://localhost:8080/search?q=test&format=json' -o /dev/null -w '%{http_code}'"`
Expected: rotation logs a new exit for gluetun-b; search still returns `200` (served by gluetun-a/c during the restart).

- [ ] **Step 7: Install the staggered cron**

Install the three-line staggered cron from Task 4 Step 3 on the VM (preserving the existing `health-check.sh` line), then verify with `ssh ubuntu@searxng "crontab -l"`.
Expected: health-check line plus 3 `rotate-exit.sh` lines present.
