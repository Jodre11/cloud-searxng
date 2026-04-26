#!/usr/bin/env bash
# SearXNG health check — pings Better Stack heartbeat on success.
# Install via cron: */3 * * * * /opt/searxng/scripts/health-check.sh
set -euo pipefail

BETTERSTACK_HEARTBEAT_URL="${BETTERSTACK_HEARTBEAT_URL:?Set BETTERSTACK_HEARTBEAT_URL}"
SEARXNG_URL="http://127.0.0.1:8888/search?q=test&format=json"

response=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$SEARXNG_URL")

if [[ "$response" == "200" ]]; then
    curl -s -o /dev/null --max-time 5 "$BETTERSTACK_HEARTBEAT_URL"
fi
