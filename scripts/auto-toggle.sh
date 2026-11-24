#!/usr/bin/env bash
# Toggle automatic approval and the optional triple-gate System One mode.

set -euo pipefail

STATE_DIR="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/herdr-yes-only}"
mkdir -p "$STATE_DIR"

case "${1:-}" in
  on) touch "$STATE_DIR/auto-enabled" ;;
  off) rm -f "$STATE_DIR/auto-enabled" ;;
  system-one-on) touch "$STATE_DIR/system-one-enabled" ;;
  system-one-off) rm -f "$STATE_DIR/system-one-enabled" ;;
  *)
    printf 'usage: %s {on|off|system-one-on|system-one-off}\n' "$0" >&2
    exit 2
    ;;
esac
