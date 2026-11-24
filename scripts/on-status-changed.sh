#!/usr/bin/env bash
# React to a blocked agent only when automatic approval is enabled.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

STATE_DIR="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/herdr-yes-only}"

[ -f "$STATE_DIR/auto-enabled" ] || exit 0

if [ -f "$STATE_DIR/system-one-enabled" ]; then
  export HERDR_YES_ONLY_MODE=system-one
fi

pane=$(printf '%s' "${HERDR_EVENT_JSON:-}" | json_eval \
  '.pane_id // .result.pane_id // empty' \
  'import sys, json
d = json.load(sys.stdin)
print(d.get("pane_id") or d.get("result", {}).get("pane_id", ""))') || true

[ -n "$pane" ] || exit 0
[ "$(agent_status "$pane")" = "blocked" ] || exit 0

approve_pane "$pane" >/dev/null
