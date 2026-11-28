#!/usr/bin/env bash
# Per-engine health check — reports an engine that has stopped answering to a second Better Stack heartbeat.
# Install via the ubuntu crontab (see README §6):
#   7 * * * * set -a; . /opt/searxng/.env; set +a; /opt/searxng/scripts/engine-health.sh
#
# health-check.sh alerts only when search as a whole collapses. With many engines, they can die one by one for
# weeks before that happens, so this check looks at each engine separately, using the same exit_health plugin
# records. An engine is DEAD when it answered none of the last WINDOW searches it was queried in. Engines that
# only answer when a query suits them (RARE) are counted dead only when they also errored in at least half of
# them, so "no relevant results" is not mistaken for failure. An engine is judged only while it is still being
# queried: one that has been disabled drops out on its own.
#
# On success it pings BETTERSTACK_ENGINES_HEARTBEAT_URL; with dead engines it posts the per-engine table to
# <url>/fail, which opens an incident with that table attached. The table is also written to REPORT_PATH on
# every run. If the URL is unset, the report is still written and nothing is sent.
set -euo pipefail

export WINDOW="${WINDOW:-20}"
export RECENT="${RECENT:-5}"
REPORT_PATH="${REPORT_PATH:-/opt/searxng/logs/engine-health.txt}"
RECORD_DIR="/run/exit-health"

records() {
    docker exec searxng cat "$RECORD_DIR/records.jsonl.1" 2>/dev/null || true
    docker exec searxng cat "$RECORD_DIR/records.jsonl" 2>/dev/null || true
}

# Prints the report; the first line is "dead=<n>".
evaluate() {
    python3 -c '
import collections, json, os, sys, time

# Engines that legitimately return no web results for most queries: infobox-only, conversion, translation and
# narrow wikis. They are reported, but only judged on errors.
RARE = {
    "wikipedia", "wikidata", "wikibooks", "wiktionary", "currency", "dictzone", "mymemory translated",
    "gentoo", "free software directory",
}
window = int(os.environ["WINDOW"])
recent = int(os.environ["RECENT"])

searches = []
for line in sys.stdin:
    line = line.strip()
    if line:
        try:
            searches.append(json.loads(line))
        except json.JSONDecodeError:
            continue
searches.sort(key=lambda record: record["ts"])

# Engines queried by any of the newest RECENT category searches are the ones currently enabled.
category = [record for record in searches if len(record["queried"]) >= 3]
current = {name for record in category[-recent:] for name in record["queried"]}

seen = collections.defaultdict(list)
for record in searches:
    for name in record["queried"]:
        seen[name].append(record)

rows, dead = [], []
for name in sorted(current):
    sample = seen[name][-window:]
    answered = sum(name in record["answered"] for record in sample)
    errored = sum(name in record["unresponsive"] for record in sample)
    if len(sample) < window:
        verdict = "too few searches"
    elif answered:
        verdict = "ok"
    elif name in RARE and 2 * errored < len(sample):
        verdict = "quiet (expected)"
    else:
        verdict = "DEAD"
        dead.append(name)
    rows.append(f"{name:24} answered {answered:>3}/{len(sample):<3} errored {errored:>3}  {verdict}")

print(f"dead={len(dead)}")
stamp = time.strftime("%Y-%m-%d %H:%M %Z")
print(f"Engine health at {stamp}: {len(searches)} searches on record, window {window}.")
if dead:
    print("Not answering: " + ", ".join(dead) + ". Re-test with !<shortcut>; disable if blocked for good.")
print("\n".join(rows) if rows else "No category searches on record yet.")
'
}

report=$(records | evaluate)
dead="${report%%$'\n'*}"
dead="${dead#dead=}"
body="${report#*$'\n'}"

mkdir -p "$(dirname "$REPORT_PATH")"
printf '%s\n' "$body" >"$REPORT_PATH"

if [[ -z "${BETTERSTACK_ENGINES_HEARTBEAT_URL:-}" ]]; then
    exit 0
fi
if (( dead > 0 )); then
    curl -s -o /dev/null --max-time 10 --data-binary "$body" "$BETTERSTACK_ENGINES_HEARTBEAT_URL/fail"
else
    curl -s -o /dev/null --max-time 10 "$BETTERSTACK_ENGINES_HEARTBEAT_URL"
fi
