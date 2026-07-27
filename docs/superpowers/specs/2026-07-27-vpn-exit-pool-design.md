# VPN Exit Pool — Design

**Date:** 2026-07-27
**Status:** Approved (pending spec review)

## Problem

SearXNG's search traffic egresses through a single Mullvad exit IP (one gluetun
container, `network_mode: "service:gluetun"`). When the AI co-agent tool issues a burst
of concurrent web-search requests (research mode), they all hit the same exit IP at once,
tripping engine rate limits (`429` / `403` / CAPTCHA). SearXNG then locally suspends the
affected engines on a cooldown, degrading results.

The prior fix (periodic single-exit rotation, `rotate-vpn.sh` + 12h cron) resets IP
reputation over time but does nothing for a *simultaneous* burst — every request in the
burst still shares one IP.

## Goal

Distribute outgoing search requests across a **pool of exit IPs** so a concurrent burst
spreads across multiple Mullvad exits instead of hammering one. Retain periodic freshness
(each exit rotates to a new Mullvad server over time).

## Constraints

- **Mullvad allows 5 simultaneous connections per account.** Each pinned exit = one
  connection. Pool sized at **3 exits**, leaving 2 for other devices.
- OCI VM is 4 OCPU / 24 GB — comfortably handles 3 WireGuard tunnels.
- Instance is private (Tailscale-only, no public ingress), single-user.

## Approach (chosen)

**3 gluetun proxy containers + SearXNG native proxy distribution.**

SearXNG's `outgoing.proxies` accepts a *list* and its httpx client distributes requests
across the list round-robin, per request. No custom distribution code needed. The pool is
produced by running 3 gluetun containers, each pinned to a different Mullvad exit, each
exposing its built-in HTTP proxy.

Approaches considered and rejected:
- **Mullvad SOCKS5 per-server proxies through one tunnel** — leaner (1 container, dozens
  of exits, no cap) but unverified from the box (gluetun's busybox wget lacks SOCKS5, and
  reachability of Mullvad SOCKS from inside a WireGuard tunnel + httpx SOCKS support were
  not confirmed). Deferred as a possible fast-follow spike.
- **Static 3-exit pool, no rotation** — drops the periodic-freshness requirement.

## Architecture

```
                      ┌──────────────────────────────────────┐
   Tailscale/Caddy ──▶│ searxng  (own network, no direct WAN) │
                      └───────────────┬──────────────────────┘
                        outgoing.proxies (httpx round-robin, per request)
                ┌──────────────┬──────┴───────┬──────────────┐
                ▼              ▼               ▼
          gluetun-a       gluetun-b       gluetun-c
          HTTP proxy      HTTP proxy      HTTP proxy
          :8888           :8888           :8888
                │              │               │
          Mullvad exit 1  Mullvad exit 2  Mullvad exit 3
```

### Network model

- searxng drops `network_mode: "service:gluetun"` and joins a private Docker network with
  the 3 gluetun containers. searxng has **no direct WAN route** — its only path out is via
  the proxies. If all proxies are down, searches **fail closed** (no IP leak), the correct
  behaviour for a privacy instance.
- caddy reverse-proxies to `searxng:8080` directly (was `gluetun:8080`).
- watchtower unchanged.

### Components

- **gluetun-a / gluetun-b / gluetun-c**: each with `HTTPPROXY=on` (built-in HTTP proxy,
  default listen `:8888`), own killswitch, own healthcheck
  (`am.i.mullvad.net/connected`). `SERVER_COUNTRIES` may be shared (all land on different
  servers within the pool) or differ per container for geographic spread.
- **searxng** `settings.yml` addition:
  ```yaml
  outgoing:
    proxies:
      all://:
        - http://gluetun-a:8888
        - http://gluetun-b:8888
        - http://gluetun-c:8888
  ```
  A ~20-request burst fans out to ~7 per exit instead of 20 on one.

## Rotation (staggered)

Generalise `rotate-vpn.sh` → `rotate-exit.sh <container>`:
- Takes one gluetun container name, restarts only that container, waits for `healthy`,
  logs its new Mullvad exit IP.
- **No searxng restart** — searxng no longer shares any gluetun netns, so rotating one
  proxy does not touch searxng. httpx sees connection-refused on that one proxy for ~10s
  and continues using the other two.

Staggered cron so the pool is never more than 1/3 degraded:
```
0  2 * * *   rotate-exit.sh gluetun-a
0 10 * * *   rotate-exit.sh gluetun-b
0 18 * * *   rotate-exit.sh gluetun-c
```
Each exit refreshes once per 24h, 8h apart; at most one mid-rotation at any instant.

The current single `rotate-vpn.sh` + 12h cron is retired (superseded).

## Failure handling & health

- **Proxy down (rotation/crash):** httpx does not auto-failover a single in-flight request
  to another proxy (the list is for distribution, not retry). During the ~10s restart
  window, the fraction of requests that picked that proxy fail; SearXNG tolerates per-engine
  failures gracefully. Staggered rotation keeps this window tiny and rare.
- **Fail-closed:** each gluetun killswitch refuses to proxy if its tunnel drops (no real-IP
  leak); searxng has no WAN route, so the system fails closed overall.
- **Health surfacing:** each gluetun keeps its healthcheck; `rotate-exit.sh` waits for
  `healthy` and logs the new exit IP to `/var/log/searxng-rotate.log`. The existing Better
  Stack `health-check.sh` still covers end-to-end liveness (searxng 200 + heartbeat).
- **Startup ordering:** searxng `depends_on` all 3 gluetun containers `healthy`; caddy
  `depends_on` searxng `healthy`.

## Testing

1. Confirm 3 distinct exit IPs via the 3 proxies.
2. Fire ~15 concurrent searches; confirm results spread across exits (distinct source IPs
   in gluetun logs).
3. Rotate one exit mid-burst; confirm searches keep returning.

## Out of scope

- SOCKS5-per-server approach (possible future spike to shrink to one container).
- Scaling beyond 5 exits (would require a second Mullvad account).
