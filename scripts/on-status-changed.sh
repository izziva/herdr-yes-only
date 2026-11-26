#!/usr/bin/env bash
# React to a blocked agent only when automatic approval is enabled.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

STATE_DIR="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/herdr-yes-only}"

[ -f "$STATE_DIR/auto-enabled" ] || exit 0

if [ -f "$STATE_DIR/system-one-enabled" ]; then
  export HERDR_YES_ONLY_MODE=system-one
fi

pane=$(printf '%s' "${HERDR_PLUGIN_EVENT_JSON:-}" | json_eval \
  '.data.pane_id // empty' \
  'print(d.get("data", {}).get("pane_id", ""))') || true

[ -n "$pane" ] || exit 0
[ "$(agent_status "$pane")" = "blocked" ] || exit 0

lock=$(pane_lock_path "$pane")
take_lock "$lock" 60 || exit 0
trap 'rmdir "$lock" 2>/dev/null || true' EXIT HUP INT TERM

approve_pane "$pane" >/dev/null