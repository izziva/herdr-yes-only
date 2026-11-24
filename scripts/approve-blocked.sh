#!/usr/bin/env bash
# Approve only binary prompts that pass the configured decision pipeline.

set -euo pipefail
. "$(dirname "$0")/lib.sh"

LOCK="${TMPDIR:-/tmp}/herdr-yes-only.lock"
RESULTS="$(mktemp -d "${TMPDIR:-/tmp}/herdr-yes-only.XXXXXX")"

trap 'rm -rf "$RESULTS" "$LOCK"' EXIT HUP INT TERM

take_lock "$LOCK" 70 || exit 0

approved=0
skipped=0
stuck=0
n=0

while read -r pane agent; do
  [ -n "$pane" ] || continue
  n=$((n + 1))
  (
    lock=$(pane_lock_path "$pane")
    take_lock "$lock" 60 || exit 0
    trap 'rmdir "$lock" 2>/dev/null || true' EXIT HUP INT TERM
    approve_pane "$pane" > "$RESULTS/$n"
  ) &
done <<EOF
$("$HERDR" agent list | json_eval \
  '.result.agents[] | "\(.pane_id) \(.agent // "unknown")"' \
  'for a in d.get("result", {}).get("agents", []):
    print(a["pane_id"], a.get("agent", "unknown"))')
EOF
wait

for file in "$RESULTS"/*; do
  [ -e "$file" ] || continue
  case "$(cat "$file")" in
    1) approved=$((approved + 1)) ;;
    0) stuck=$((stuck + 1)) ;;
    *) skipped=$((skipped + 1)) ;;
  esac
done

message="Yes-only: approved $approved, skipped $skipped"
[ "$stuck" -gt 0 ] && message="$message, still blocked $stuck"
"$HERDR" notification show "$message" --sound none >/dev/null 2>&1 || true
