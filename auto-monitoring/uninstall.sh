#!/usr/bin/env bash
# Reverse install.sh: stop/remove the collector service and restore settings.json
# (telemetry goes back to flowing directly to Dynatrace, exactly as before).
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$HOME/.claude/settings.json"

case "$(uname -s)" in
  Darwin)
    PLIST="$HOME/Library/LaunchAgents/com.dynatrace.claudecode-collector.plist"
    launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "▶ LaunchAgent removed" ;;
  Linux)
    systemctl --user disable --now claudecode-collector.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/claudecode-collector.service"
    systemctl --user daemon-reload
    echo "▶ systemd user service removed" ;;
esac

if [ -f "$SETTINGS.pre-automon.bak" ]; then
  cp "$SETTINGS.pre-automon.bak" "$SETTINGS"
  echo "▶ settings.json restored from backup (direct-to-Dynatrace telemetry, incl. its token)"
else
  echo "⚠ No settings backup found — settings.json left unchanged"
fi
echo "ℹ $REPO_DIR/auto-monitoring/collector.env kept (holds the token). Delete it manually if you no longer need it."
