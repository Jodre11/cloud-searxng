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
                                                    network_mode: service:gluetun
                                                         │
                                                    Gluetun (WireGuard)
                                                         │
                                                    Mullvad VPN exit
```

All search traffic exits through Mullvad VPN (via Gluetun). Tailscale Serve provides auto-managed
TLS certificates. Caddy reverse-proxies and strips identifying headers. Watchtower auto-updates
container images daily at 04:00.

No ports are exposed to the public internet except SSH (port 22), which is intended to be removed
once Tailscale SSH is confirmed working.

## Prerequisites

- [Terraform](https://www.terraform.io/) >= 1.5
- [Bitwarden CLI](https://bitwarden.com/help/cli/) (for OCI credentials via `scripts/env.sh`)
- OCI API key stored in Bitwarden (item: "OCI - cloud-searxng")
- SSH key pair (default `~/.ssh/id_ed25519`)
- [Mullvad VPN](https://mullvad.net/) account with a WireGuard configuration
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

| Variable                  | Source                                               |
|---------------------------|------------------------------------------------------|
| `WIREGUARD_PRIVATE_KEY`   | Mullvad WireGuard config file (`[Interface]` section) |
| `WIREGUARD_ADDRESSES`     | Mullvad WireGuard config file (IPv4 address)          |
| `VPN_SERVER_COUNTRIES`    | Comma-separated list (e.g. `Sweden,Switzerland,Netherlands`) |
| `SEARXNG_SECRET_KEY`      | Generate on-instance: `openssl rand -hex 32`          |
| `TAILSCALE_AUTHKEY`       | Tailscale admin console > Settings > Keys             |
| `BETTERSTACK_HEARTBEAT_URL` | Better Stack > Heartbeats > create heartbeat        |

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

Install the heartbeat cron job on the instance:

```bash
sudo crontab -l 2>/dev/null | { cat; echo '*/3 * * * * BETTERSTACK_HEARTBEAT_URL="<url>" /opt/searxng/scripts/health-check.sh'; } | sudo crontab -
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
│   └── health-check.sh           # Heartbeat health check
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
