#!/usr/bin/env bash
# SearXNG health check — pings Better Stack heartbeat on success.
# Install via root cron: */3 * * * * BETTERSTACK_HEARTBEAT_URL="<url>" /opt/searxng/scripts/health-check.sh
#
# Health is judged from REAL searches, not by searching: the exit_health plugin (compose/searxng/plugins/)
# records which engines answered each search. "Healthy" means at least half of the newest SAMPLE_SIZE
# category searches were answered by MIN_ENGINES or more distinct web engines. Probing with a synthetic search
# every 3 minutes used to be about half of all traffic the engines saw from this instance, and HTTP 200 alone
# said nothing, because SearXNG returns 200 with no results when every engine is blocked.
#
# A synthetic search is sent only when there is no fresh evidence: nobody has searched for IDLE_PROBE_AFTER
# seconds, or the verdict is unhealthy and RECHECK_AFTER seconds old (so recovery is noticed while idle).
set -euo pipefail

BETTERSTACK_HEARTBEAT_URL="${BETTERSTACK_HEARTBEAT_URL:?Set BETTERSTACK_HEARTBEAT_URL}"
export MIN_ENGINES="${MIN_ENGINES:-2}"
export SAMPLE_SIZE="${SAMPLE_SIZE:-6}"
IDLE_PROBE_AFTER="${IDLE_PROBE_AFTER:-$((6 * 60 * 60))}"
RECHECK_AFTER="${RECHECK_AFTER:-$((30 * 60))}"
PROBE_URL="http://127.0.0.1:8888/search?q=test&categories=general&format=json"
RECORD_PATH="/var/cache/searxng/exit-health.jsonl"
# Touched by apt on every successful package-list refresh; if it goes stale, OS security updates have stopped.
APT_STAMP="/var/lib/apt/periodic/update-success-stamp"
APT_MAX_AGE_SECONDS=$((2 * 24 * 60 * 60))

# Prints "<healthy 0|1> <newest record timestamp>" for the plugin's records on stdin.
evaluate() {
    python3 -c '
import json, os, sys

# General-category engines that are not web indexes must not satisfy the quorum on their own.
NOT_WEB = {"wikibooks", "currency", "dictzone", "mymemory translated"}
min_engines = int(os.environ["MIN_ENGINES"])
sample_size = int(os.environ["SAMPLE_SIZE"])

searches = []
for line in sys.stdin:
    if not line.strip():
        continue
    record = json.loads(line)
    # Bang searches query one engine; only category searches say anything about the pool.
    if len(set(record["queried"]) - NOT_WEB) >= 3:
        searches.append(record)

sample = searches[-sample_size:]
good = sum(len(set(record["answered"]) - NOT_WEB) >= min_engines for record in sample)
healthy = bool(sample) and 2 * good >= len(sample)
print(int(healthy), max((record["ts"] for record in searches), default=0))
'
}

read_records() {
    docker exec searxng tail -n 200 "$RECORD_PATH" 2>/dev/null || true
}

apt_age=$(($(date +%s) - $(stat -c %Y "$APT_STAMP" 2>/dev/null || echo 0)))
if (( apt_age > APT_MAX_AGE_SECONDS )); then
    exit 0
fi

read -r healthy newest_ts < <(read_records | evaluate) || exit 0
age=$(($(date +%s) - newest_ts))

if (( age > IDLE_PROBE_AFTER )) || { (( ! healthy )) && (( age > RECHECK_AFTER )); }; then
    # The plugin records the probe like any search, so it is judged the same way.
    curl -sf -o /dev/null --max-time 20 "$PROBE_URL" || exit 0
    read -r healthy newest_ts < <(read_records | evaluate) || exit 0
fi

if (( healthy )); then
    curl -s -o /dev/null --max-time 5 "$BETTERSTACK_HEARTBEAT_URL"
fi
