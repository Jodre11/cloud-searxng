# cloud-searxng

Private [SearXNG](https://docs.searxng.org/) instance running on Oracle Cloud Free Tier, accessible
exclusively over [Tailscale](https://tailscale.com/).

## Why

A private, no-logging search frontend on infrastructure I control. Constraints:

- **Free** — Oracle Cloud Free Tier (ARM A1.Flex, 4 OCPU / 24 GB) covers the compute indefinitely.
- **No public exposure** — Tailscale Serve handles ingress; no public ports except temporary SSH
  during bootstrap, removed once Tailscale SSH is confirmed working.
- **VPN egress** — all search traffic exits through Mullvad WireGuard via Gluetun, so my IP isn't
  the one querying upstream engines.
- **Reproducible** — Terraform for OCI, Docker Compose for the runtime, cloud-init for bootstrap.
  One `terraform apply` + one `deploy.sh` rebuilds the whole stack.

This repo is the recipe. Forking and running it on your own OCI tenancy should take about an hour
the first time.

## Architecture

```
Tailscale (HTTPS)                  OCI VM.Standard.A1.Flex (ARM, 4 OCPU, 24 GB)
─────────────────────────────────────────────────────────────────────────────────
  Client device
       │
       ▼
  Tailscale Serve (:443)  ──►  Caddy (:8888)  ──►  SearXNG (:8080)
                                                         │
                                   searxng ──▶ outgoing.proxies (httpx round-robin, per request)
                                                 ├─▶ gluetun-a  HTTP proxy  ─▶ Mullvad exit 1
                                                 ├─▶ gluetun-b  HTTP proxy  ─▶ Mullvad exit 2
                                                 └─▶ gluetun-c  HTTP proxy  ─▶ Mullvad exit 3
```

Search traffic exits through a pool of three Gluetun HTTP-proxy containers, each pinned to a
different Mullvad WireGuard exit. SearXNG's `outgoing.proxies` list round-robins across them via
httpx, one exit per request. Tailscale Serve provides auto-managed TLS certificates. Caddy
reverse-proxies and strips identifying headers. Watchtower auto-updates container images daily
at 04:00. On the host, unattended-upgrades installs Ubuntu and Docker updates and reboots at 03:00 when a kernel
update needs it; Tailscale updates itself.

No ports are exposed to the public internet except SSH (port 22), which is intended to be removed
once Tailscale SSH is confirmed working.

## Prerequisites

- [Terraform](https://www.terraform.io/) >= 1.5
- [Bitwarden CLI](https://bitwarden.com/help/cli/) (for OCI credentials via `scripts/env.sh`)
- OCI API key stored in Bitwarden (item: "OCI - cloud-searxng")
- SSH key pair (default `~/.ssh/id_ed25519`)
- [Mullvad VPN](https://mullvad.net/) account with three WireGuard configurations (one per exit)
- [Tailscale](https://tailscale.com/) account with Serve enabled
- [Better Stack](https://betterstack.com/) account (optional, for heartbeat monitoring)

## Setup

### 1. Load OCI Credentials

```bash
source scripts/env.sh
```

Unlocks Bitwarden, fetches the OCI API key fields, and exports `TF_VAR_*` variables for Terraform.

### 2. Provision Infrastructure

```bash
terraform -chdir=terraform init
terraform -chdir=terraform apply
```

Creates a VCN, subnet, security list, internet gateway, and an ARM compute instance. Cloud-init
installs Docker, Tailscale, and prepares `/opt/searxng`.

### 3. Create the `.env` File

SSH to the instance and create `/opt/searxng/.env` from the example:

```bash
scp compose/.env.example ubuntu@<public-ip>:/opt/searxng/.env
ssh ubuntu@<public-ip> "TERM=xterm-256color nano /opt/searxng/.env"
```

Fill in:

| Variable                    | Source                                               |
|-----------------------------|------------------------------------------------------|
| `WIREGUARD_PRIVATE_KEY_A`   | Mullvad WireGuard config A (`[Interface]` section)   |
| `WIREGUARD_ADDRESSES_A`     | Mullvad WireGuard config A (IPv4 address)             |
| `WIREGUARD_PRIVATE_KEY_B`   | Mullvad WireGuard config B (`[Interface]` section)   |
| `WIREGUARD_ADDRESSES_B`     | Mullvad WireGuard config B (IPv4 address)             |
| `WIREGUARD_PRIVATE_KEY_C`   | Mullvad WireGuard config C (`[Interface]` section)   |
| `WIREGUARD_ADDRESSES_C`     | Mullvad WireGuard config C (IPv4 address)             |
| `VPN_SERVER_COUNTRIES`      | Comma-separated list (e.g. `Sweden,Switzerland,Netherlands`) |
| `SEARXNG_SECRET_KEY`        | Generate on-instance: `openssl rand -hex 32`          |
| `TAILSCALE_AUTHKEY`         | Tailscale admin console > Settings > Keys; attach `tag:server` (tagged nodes never key-expire) |
| `BETTERSTACK_HEARTBEAT_URL` | Better Stack > Heartbeats > create heartbeat          |

Three separate Mullvad WireGuard configs are required — one per exit. Generate each at the
Mullvad account WireGuard-config page; do not reuse one key across tunnels.

The `.env` file should be `chmod 600` and never leaves the instance.

### 4. Deploy

First run (syncs compose files, joins Tailscale, starts the stack):

```bash
bash scripts/deploy.sh <public-ip> --first-run
```

Subsequent deploys (e.g. after changing compose files or settings):

```bash
bash scripts/deploy.sh <public-ip>
```

### 5. Enable Tailscale Serve

On the instance:

```bash
sudo tailscale serve --bg 8888
```

If prompted, enable Serve for the node via the link provided. Once active, the instance is
available at:

```
https://searxng.<tailnet>.ts.net/
```

### 6. Health Check Cron (Optional)

The heartbeat is sent only when SearXNG answers *and* apt has refreshed its package lists within the last two
days, so a stalled OS-update pipeline alerts the same way an outage does.

Install the heartbeat cron job on the instance:

```bash
sudo crontab -l 2>/dev/null | { cat; echo '*/3 * * * * BETTERSTACK_HEARTBEAT_URL="<url>" /opt/searxng/scripts/health-check.sh'; } | sudo crontab -
```

### 7. VPN Exit Rotation Cron (Recommended)

Each Gluetun container picks one Mullvad server at start and stays pinned to it. The commercial
search engines (Brave, DuckDuckGo, Startpage) intermittently return `403` / `429` / CAPTCHA from
shared Mullvad exit IPs; when tripped, SearXNG locally suspends that engine for a cooldown
(`suspended_time`), so a stale exit progressively degrades results. `rotate-exit.sh` forces a
fresh exit by restarting a named Gluetun container. Exits refresh once per 24h, 8h apart, so at
most one is mid-rotation at any instant and the pool is never more than 1/3 degraded.

```bash
crontab -l 2>/dev/null | { cat; \
  echo '0  2 * * * /opt/searxng/scripts/rotate-exit.sh gluetun-a >> /var/log/searxng-rotate.log 2>&1'; \
  echo '0 10 * * * /opt/searxng/scripts/rotate-exit.sh gluetun-b >> /var/log/searxng-rotate.log 2>&1'; \
  echo '0 18 * * * /opt/searxng/scripts/rotate-exit.sh gluetun-c >> /var/log/searxng-rotate.log 2>&1'; \
} | crontab -
```

## Access

| Method          | URL                                      |
|-----------------|------------------------------------------|
| Tailscale HTTPS | `https://searxng.<tailnet>.ts.net/`      |
| SSH (Tailscale) | `ssh ubuntu@searxng`                     |
| SSH (public)    | `ssh ubuntu@<public-ip>` (temporary)     |

## Project Structure

```
cloud-searxng/
├── compose/
│   ├── .env.example              # Template for instance .env
│   ├── docker-compose.yml        # Gluetun + SearXNG + Caddy + Watchtower
│   ├── caddy/Caddyfile           # Reverse proxy config
│   └── searxng/settings.yml      # SearXNG engine and UI settings
├── scripts/
│   ├── deploy.sh                 # Rsync + docker compose up
│   ├── env.sh                    # Load OCI creds from Bitwarden
│   ├── health-check.sh           # Heartbeat health check
│   └── rotate-exit.sh            # Rotate one gluetun exit (staggered pool rotation)
└── terraform/
    ├── main.tf                   # VCN, subnet, security list, instance
    ├── variables.tf              # Input variables
    ├── outputs.tf                # Instance ID and public IP
    ├── cloud-init.yml            # Docker + Tailscale bootstrap
    └── terraform.tfvars.example  # Example variable values
```

## Post-Deploy Hardening

Once Tailscale SSH is confirmed working:

1. Remove the SSH ingress rule from `terraform/main.tf` (port 22 in the security list)
2. Run `terraform apply` to close the public SSH port
3. Access the instance exclusively via `ssh ubuntu@searxng` over Tailscale
