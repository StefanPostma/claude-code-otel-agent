#!/usr/bin/env bash
# ============================================================================
#  macOS security log sidecar — unified log → NDJSON files for the collector
#
#  Polls the macOS unified log (`/usr/bin/log show`) with the security predicate
#  built from macos-security/predicates.json and appends the matching records as
#  NDJSON to $MACOS_SECURITY_LOG_DIR/unified-YYYYMMDD.ndjson. The collector's
#  filelog/macos_security receiver tails those files (see processor/claude-code-agent.yaml).
#
#  Why polling, not `log stream`: `log stream` output cannot be rotated, and `log show`
#  with a persisted cursor survives restarts without gaps or duplicates.
#
#  No root needed: an admin user reads the unified log. Private payloads stay
#  redacted as <private> unless the machine has the private-data profile.
#
#  Usage
#    macos-security-log.sh                 # run forever (started by start-collector.sh)
#    macos-security-log.sh --once          # one poll
#    macos-security-log.sh --profile 60m   # record counts per subsystem/category for the last 60m
#    macos-security-log.sh --print-predicate
#  Env
#    MACOS_SECURITY_LOG_DIR   output dir (default ~/.dynatrace-otel/macos-security)
#    MACOS_SECURITY_INTERVAL  poll interval seconds (default 30)
#    MACOS_SECURITY_RETENTION_DAYS  days of ndjson to keep (default 2)
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRED_FILE="$HERE/predicates.json"
DIR="${MACOS_SECURITY_LOG_DIR:-$HOME/.dynatrace-otel/macos-security}"
INTERVAL="${MACOS_SECURITY_INTERVAL:-30}"
RETENTION="${MACOS_SECURITY_RETENTION_DAYS:-2}"
LOG=/usr/bin/log            # NOT bare `log`: zsh has a builtin of that name
CURSOR="$DIR/.cursor"

[ "$(uname -s)" = "Darwin" ] || { echo "macos-security-log: not macOS, nothing to do"; exit 0; }
[ -x "$LOG" ] || { echo "macos-security-log: $LOG missing"; exit 1; }
mkdir -p "$DIR"

predicate() {
  python3 -I - "$PRED_FILE" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
parts = [c["predicate"] for c in cfg["categories"].values() if c.get("enabled")]
print(f'{cfg["always"]} AND ({" OR ".join(parts)})')
PY
}

poll() {
  local now start
  now="$(date '+%Y-%m-%d %H:%M:%S')"
  if [ -s "$CURSOR" ]; then start="$(cat "$CURSOR")"; else start="$(date -v-5M '+%Y-%m-%d %H:%M:%S')"; fi
  local out="$DIR/unified-$(date '+%Y%m%d').ndjson"
  # eventType != logEvent rows (activity/trace events) and the trailing summary object
  # have no eventMessage — drop them so the receiver sees only log records.
  "$LOG" show --style ndjson --start "$start" --end "$now" --predicate "$PRED" 2>/dev/null \
    | grep -F '"eventMessage"' >> "$out" || true
  echo "$now" > "$CURSOR"
  find "$DIR" -name 'unified-*.ndjson' -mtime +"$RETENTION" -delete 2>/dev/null || true
}

PRED="$(predicate)"
case "${1:-}" in
  --print-predicate) echo "$PRED"; exit 0 ;;
  --profile)
    span="${2:-60m}"
    "$LOG" show --last "$span" --style ndjson --predicate "$PRED" 2>/dev/null | python3 -I -c '
import sys, json, collections
c = collections.Counter(); ex = {}; n = 0
for line in sys.stdin:
    try: r = json.loads(line)
    except ValueError: continue
    if "eventMessage" not in r: continue
    n += 1
    k = (r.get("subsystem") or "-", r.get("category") or "-", (r.get("processImagePath") or "").rsplit("/", 1)[-1], r.get("messageType"))
    c[k] += 1; ex.setdefault(k, r["eventMessage"][:100])
print(f"records in window: {n}")
for k, v in c.most_common(40): print(f"{v:6d}  {k[0]:38s} {k[1]:16s} {k[2]:22s} {(k[3] or "-"):8s} | {ex[k]}")'
    exit 0 ;;
  --once) poll; exit 0 ;;
esac

echo "macos-security-log: dir=$DIR interval=${INTERVAL}s categories=$(python3 -I -c 'import json,sys;c=json.load(open(sys.argv[1]))["categories"];print(",".join(k for k,v in c.items() if v.get("enabled")))' "$PRED_FILE")"
trap 'exit 0' TERM INT
while :; do poll; sleep "$INTERVAL"; done
