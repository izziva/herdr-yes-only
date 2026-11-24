#!/usr/bin/env bash
# Shared helpers for herdr-yes-only.

set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

YES_ONLY_MODE="${HERDR_YES_ONLY_MODE:-strict}"
D1_MODEL="${HERDR_YES_ONLY_D1_MODEL:-LiquidAI/d1-2B}"
D1_MIN_CONTEXT="${HERDR_YES_ONLY_D1_MIN_CONTEXT_CONFIDENCE:-0.80}"
D1_MIN_SAFETY="${HERDR_YES_ONLY_D1_MIN_SAFETY_CONFIDENCE:-0.90}"
D1_MIN_RESPONSE="${HERDR_YES_ONLY_D1_MIN_RESPONSE_CONFIDENCE:-0.90}"
D1_TIMEOUT_SEC="${HERDR_YES_ONLY_D1_TIMEOUT_SEC:-5}"
BLOCK_RISKY="${HERDR_YES_ONLY_BLOCK_RISKY:-1}"
DEBUG="${HERDR_YES_ONLY_DEBUG:-0}"

APPROVE_MAX_SENDS="${APPROVE_MAX_SENDS:-5}"
APPROVE_LEAVE_TIMEOUT_MS="${APPROVE_LEAVE_TIMEOUT_MS:-1200}"
APPROVE_SETTLE_SEC="${APPROVE_SETTLE_SEC:-0.15}"

file_mtime() {
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || date +%s
}

json_eval() {
  if command -v jq >/dev/null 2>&1; then
    jq -r "$1"
  else
    python3 -c "
import sys, json
d = json.load(sys.stdin)
$2"
  fi
}

take_lock() {
  local dir="$1" max_age="$2" now mt
  if mkdir "$dir" 2>/dev/null; then
    return 0
  fi
  now=$(date +%s)
  mt=$(file_mtime "$dir")
  if [ $((now - mt)) -lt "$max_age" ]; then
    return 1
  fi
  rmdir "$dir" 2>/dev/null || true
  mkdir "$dir" 2>/dev/null
}

pane_lock_path() {
  printf '%s/herdr-yes-only.pane.%s' "${TMPDIR:-/tmp}" \
    "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9_-' '_')"
}

agent_status() {
  "$HERDR" agent get "$1" 2>/dev/null | json_eval \
    '.result.agent.agent_status // empty' \
    'print(d.get("result", {}).get("agent", {}).get("agent_status", ""))'
}

read_screen() {
  "$HERDR" agent read "$1" --source visible --lines 50 2>/dev/null || true
}

normalize_screen() {
  printf '%s\n' "$1" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\r$//'
}

risky_command_present() {
  local screen="$1"
  [ "$BLOCK_RISKY" = "1" ] || return 1

  printf '%s\n' "$screen" | grep -qiE \
    '(rm[[:space:]]+-[a-z]*r[a-z]*f|sudo[[:space:]]|curl[^|]*\|[[:space:]]*(ba)?sh|wget[^|]*\|[[:space:]]*(ba)?sh|git[[:space:]]+push[^&]*--force|dd[[:space:]]+if=|chmod[[:space:]]+-R[[:space:]]+777|mkfs\.|shutdown[[:space:]]|reboot[[:space:]])' \
    && return 0
  return 1
}

# Strict mode: exact Yes and No only.
strict_yes_no_prompt() {
  local screen="$1" normalized
  local yes_count no_count cursor_yes default_yes numbered_options

  normalized=$(normalize_screen "$screen")
  risky_command_present "$normalized" && return 1

  numbered_options=$(printf '%s\n' "$normalized" | grep -cE '^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]' || true)
  [ "$numbered_options" -le 2 ] || return 1

  yes_count=$(printf '%s\n' "$normalized" | grep -icE '^[[:space:]]*(❯[[:space:]]*)?yes[[:space:]]*$' || true)
  no_count=$(printf '%s\n' "$normalized" | grep -icE '^[[:space:]]*(❯[[:space:]]*)?no[[:space:]]*$' || true)

  [ "$yes_count" -eq 1 ] || return 1
  [ "$no_count" -eq 1 ] || return 1

  cursor_yes=$(printf '%s\n' "$normalized" | grep -icE '^[[:space:]]*❯[[:space:]]*yes[[:space:]]*$' || true)
  default_yes=$(printf '%s\n' "$normalized" | grep -icE '(\(Y/n\)|\[Y/n\]|press enter to confirm yes|enter to confirm yes|default: yes)' || true)

  [ "$cursor_yes" -eq 1 ] || [ "$default_yes" -ge 1 ] || return 1
  return 0
}

# System One candidate: exactly one affirmative and one negative binary option.
# This does not authorize an action by itself; d1-2B must pass all three gates.
system_one_binary_candidate() {
  local screen="$1" normalized
  local affirmative_count negative_count cursor_affirmative default_affirmative numbered_options

  normalized=$(normalize_screen "$screen")
  risky_command_present "$normalized" && return 1

  numbered_options=$(printf '%s\n' "$normalized" | grep -cE '^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]' || true)
  [ "$numbered_options" -le 2 ] || return 1

  affirmative_count=$(printf '%s\n' "$normalized" | grep -icE \
    '^[[:space:]]*(❯[[:space:]]*)?(yes([[:space:]]*,[[:space:]]*(always|allow|continue|proceed))?|approve|allow|confirm|proceed|continue|accept|install|run|execute|trust|enable)[[:space:]]*$' || true)

  negative_count=$(printf '%s\n' "$normalized" | grep -icE \
    '^[[:space:]]*(❯[[:space:]]*)?(no|deny|reject|cancel|abort|skip|decline|disable|don.t[[:space:]]+run|do[[:space:]]+not[[:space:]]+run)[[:space:]]*$' || true)

  [ "$affirmative_count" -eq 1 ] || return 1
  [ "$negative_count" -eq 1 ] || return 1

  cursor_affirmative=$(printf '%s\n' "$normalized" | grep -icE \
    '^[[:space:]]*❯[[:space:]]*(yes([[:space:]]*,[[:space:]]*(always|allow|continue|proceed))?|approve|allow|confirm|proceed|continue|accept|install|run|execute|trust|enable)[[:space:]]*$' || true)

  default_affirmative=$(printf '%s\n' "$normalized" | grep -icE \
    '(\(Y/n\)|\[Y/n\]|press enter to confirm yes|enter to confirm yes|default: yes|default: approve|default: allow|default: confirm|default: proceed)' || true)

  [ "$cursor_affirmative" -eq 1 ] || [ "$default_affirmative" -ge 1 ] || return 1
  return 0
}

system_one_gate() {
  local screen="$1" result

  result=$(printf '%s' "$screen" | python3 "$SCRIPT_DIR/system_one.py" \
    --model "$D1_MODEL" \
    --min-context "$D1_MIN_CONTEXT" \
    --min-safety "$D1_MIN_SAFETY" \
    --min-response "$D1_MIN_RESPONSE" \
    --timeout "$D1_TIMEOUT_SEC" 2>/dev/null) || return 1

  if [ "$DEBUG" = "1" ]; then
    printf '%s\n' "$result" >&2
  fi

  printf '%s' "$result" | json_eval \
    '.approved == true' \
    'import sys, json
print(str(json.load(sys.stdin).get("approved", False)).lower())' | grep -qx true
}

prompt_allowed() {
  local pane="$1" screen
  screen=$(read_screen "$pane")

  case "$YES_ONLY_MODE" in
    strict)
      strict_yes_no_prompt "$screen"
      ;;
    system-one)
      system_one_binary_candidate "$screen" && system_one_gate "$screen"
      ;;
    *)
      return 1
      ;;
  esac
}

approve_pane() {
  local pane="$1" sent=0

  while [ "$sent" -lt "$APPROVE_MAX_SENDS" ]; do
    [ "$(agent_status "$pane")" = "blocked" ] || break
    prompt_allowed "$pane" || break

    "$HERDR" agent send-keys "$pane" enter >/dev/null 2>&1 || break
    sent=$((sent + 1))

    "$HERDR" agent wait "$pane" --until idle --until working --until done \
      --timeout "$APPROVE_LEAVE_TIMEOUT_MS" >/dev/null 2>&1 || true
    sleep "$APPROVE_SETTLE_SEC"
  done

  if [ "$sent" -eq 0 ]; then
    printf -- '-'
  elif [ "$(agent_status "$pane")" = "blocked" ]; then
    printf 0
  else
    printf 1
  fi
}
