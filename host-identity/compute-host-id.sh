#!/usr/bin/env bash
# ============================================================================
#  Stable host.id derivation (Linux / macOS) — fallback when OneAgent is absent.
#
#  Mirrors OneAgent's `oneagentctl --set-host-id-source` (machine-id | mac | fqdn
#  | ip, + optional namespace), hashes the source to a stable 16-hex-uppercase id
#  (OneAgent HOST-xxxx style), and CACHES it so the same host keeps the same id
#  across restarts. Prints, for the collector launcher to `eval`:
#      STABLE_HOST_ID=<16 hex>
#      STABLE_HOST_NAME=<fqdn>
#
#  Env knobs: HOST_ID_SOURCE (default machine-id) · HOST_ID_NAMESPACE
#             HOST_ID_CACHE_DIR (default ~/.dynatrace-otel) · HOST_ID_REFRESH=1
# ============================================================================
set -euo pipefail
SOURCE="${HOST_ID_SOURCE:-machine-id}"
NAMESPACE="${HOST_ID_NAMESPACE:-}"
CACHE_DIR="${HOST_ID_CACHE_DIR:-$HOME/.dynatrace-otel}"
CACHE_FILE="$CACHE_DIR/host-id"

hash16() {
  local h
  if command -v sha256sum >/dev/null 2>&1; then h=$(printf '%s' "$1" | sha256sum)
  else h=$(printf '%s' "$1" | shasum -a 256); fi
  printf '%s' "${h%% *}" | cut -c1-16 | tr 'a-f' 'A-F'
}

raw_source() {
  case "$SOURCE" in
    machine-id)
      if   [ -r /etc/machine-id ];            then cat /etc/machine-id
      elif [ -r /var/lib/dbus/machine-id ];   then cat /var/lib/dbus/machine-id
      # macOS: ioreg lives in /usr/sbin, which launchd's minimal PATH omits — use the
      # absolute path so a service-started run derives the SAME id as an interactive one.
      elif [ -x /usr/sbin/ioreg ];            then /usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}'
      elif command -v ioreg >/dev/null 2>&1;  then ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $4}'
      else echo "no stable machine-id source found; falling back to hostname (weaker)" >&2; hostname; fi ;;
    mac)
      if command -v ip >/dev/null 2>&1; then ip -o link 2>/dev/null | awk '/link\/ether/{print $(NF-1); exit}'
      else ifconfig 2>/dev/null | awk '/ether/{print $2; exit}'; fi ;;
    fqdn) hostname -f 2>/dev/null || hostname ;;
    ip)
      if command -v ip >/dev/null 2>&1; then ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
      else ipconfig getifaddr en0 2>/dev/null || hostname; fi ;;
    *) echo "unknown HOST_ID_SOURCE: $SOURCE (use machine-id|mac|fqdn|ip)" >&2; exit 2 ;;
  esac
}

mkdir -p "$CACHE_DIR"
if [ -s "$CACHE_FILE" ] && [ "${HOST_ID_REFRESH:-0}" != "1" ]; then
  HOST_ID=$(tr -d '[:space:]' < "$CACHE_FILE")
else
  SRC="$(raw_source | tr -d '[:space:]')"
  [ -n "$SRC" ] || { echo "could not resolve host-id source '$SOURCE'" >&2; exit 1; }
  HOST_ID=$(hash16 "${NAMESPACE}:${SRC}")
  printf '%s' "$HOST_ID" > "$CACHE_FILE"
fi
HOST_NAME=$(hostname -f 2>/dev/null || hostname)
echo "STABLE_HOST_ID=$HOST_ID"
echo "STABLE_HOST_NAME=$HOST_NAME"
