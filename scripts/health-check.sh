#!/usr/bin/env bash
# SearXNG health check — pings Better Stack heartbeat on success.
# Install via cron: */10 * * * * /opt/searxng/scripts/health-check.sh
#
# "Success" means a general search was answered by at least MIN_ENGINES distinct engines, not merely HTTP 200:
# SearXNG returns 200 with an empty result list when every engine is blocked or suspended, which kept this
# check green while the exit pool was degraded. Each run is a real search through the engines, so keep the
# cadence low; at */3 it was about half of all traffic the engines saw from this instance.
set -euo pipefail

BETTERSTACK_HEARTBEAT_URL="${BETTERSTACK_HEARTBEAT_URL:?Set BETTERSTACK_HEARTBEAT_URL}"
MIN_ENGINES="${MIN_ENGINES:-2}"
SEARXNG_URL="http://127.0.0.1:8888/search?q=test&categories=general&format=json"
# Touched by apt on every successful package-list refresh; if it goes stale, OS security updates have stopped.
APT_STAMP="/var/lib/apt/periodic/update-success-stamp"
APT_MAX_AGE_SECONDS=$((2 * 24 * 60 * 60))

body=$(curl -sf --max-time 20 "$SEARXNG_URL") || exit 0

# Engines in the general category that are not web indexes (wikibooks answers "test" from its own wiki) must
# not satisfy the quorum on their own.
answering=$(python3 -c '
import json, sys
not_web = {"wikibooks", "currency", "dictzone", "mymemory translated"}
results = json.load(sys.stdin).get("results", [])
print(len({engine for result in results for engine in result.get("engines", [])} - not_web))
' <<<"$body" 2>/dev/null) || exit 0
if (( answering < MIN_ENGINES )); then
    exit 0
fi

apt_age=$(($(date +%s) - $(stat -c %Y "$APT_STAMP" 2>/dev/null || echo 0)))
if (( apt_age > APT_MAX_AGE_SECONDS )); then
    exit 0
fi

curl -s -o /dev/null --max-time 5 "$BETTERSTACK_HEARTBEAT_URL"
