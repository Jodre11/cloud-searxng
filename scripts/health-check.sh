#!/usr/bin/env bash
# SearXNG health check — pings Better Stack heartbeat on success.
# Install via cron: */3 * * * * /opt/searxng/scripts/health-check.sh
set -euo pipefail

BETTERSTACK_HEARTBEAT_URL="${BETTERSTACK_HEARTBEAT_URL:?Set BETTERSTACK_HEARTBEAT_URL}"
SEARXNG_URL="http://127.0.0.1:8888/search?q=test&format=json"
# Touched by apt on every successful package-list refresh; if it goes stale, OS security updates have stopped.
APT_STAMP="/var/lib/apt/periodic/update-success-stamp"
APT_MAX_AGE_SECONDS=$((2 * 24 * 60 * 60))

response=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$SEARXNG_URL")
if [[ "$response" != "200" ]]; then
    exit 0
fi

apt_age=$(($(date +%s) - $(stat -c %Y "$APT_STAMP" 2>/dev/null || echo 0)))
if (( apt_age > APT_MAX_AGE_SECONDS )); then
    exit 0
fi

curl -s -o /dev/null --max-time 5 "$BETTERSTACK_HEARTBEAT_URL"
