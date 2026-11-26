#!/usr/bin/env bash
# Shared helpers for herdr-yes-only.

set -euo pipefail

HERDR="${HERDR_BIN_PATH:-herdr}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

YES_ONLY_MODE="${HERDR_YES_ONLY_MODE:-strict}"
D1_MODEL="${HERDR_YES_ONLY_D1_MODEL:-LiquidAI/d1-2B-MLX-4bit}"
D1_MIN_CONTEXT="${HERDR_YES_ONLY_D1_MIN_CONTEXT_CONFIDENCE:-0.80}"
D1_MIN_SAFETY="${HERDR_YES_ONLY_D1_MIN_SAFETY_CONFIDENCE:-0.90}"
D1_MIN_RESPONSE="${HERDR_YES_ONLY_D1_MIN_RESPONSE_CONFIDENCE:-0.90}"
D1_TIMEOUT_SEC="${HERDR_YES_ONLY_D1_TIMEOUT_SEC:-5}"
BLOCK_RISKY="${HERDR_YES_ONLY_BLOCK_RISKY:-1}"
DEBUG="${HERDR_YES_ONLY_DEBUG:-0}"

APPROVE_MAX_SENDS="${APPROVE_MAX_SENDS:-5}"
APPROVE_DELAY_SEC="${APPROVE_DELAY_SEC:-2}"
APPROVE_LEAVE_TIMEOUT_MS="${APPROVE_LEAVE_TIMEOUT_MS:-1200}"
APPROVE_SETTLE_SEC="${APPROVE_SETTLE_SEC:-0.15}"
APPROVE_RECHECK_TRIES="${APPROVE_RECHECK_TRIES:-5}"
APPROVE_RECHECK_SEC="${APPROVE_RECHECK_SEC:-0.3}"

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

# The menu being answered: the run of non-blank lines around the last cursor
# line (or the last run, without a cursor), so numbered lists in the agent's
# output above the prompt are not counted as options. Numbered options that
# wrap are joined back onto one line.
menu_block() {
  printf '%s\n' "$1" | awk '
    { line[NR] = $0 }
    /^[[:space:]]*❯/ { cur = NR }
    END {
      if (!cur) { cur = NR; while (cur > 0 && line[cur] ~ /^[[:space:]]*$/) cur-- }
      if (!cur) exit
      s = cur; while (s > 1 && line[s - 1] !~ /^[[:space:]]*$/) s--
      e = cur; while (e < NR && line[e + 1] !~ /^[[:space:]]*$/) e++
      for (i = s; i <= e; i++) {
        if (line[i] ~ /^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]/) {
          if (buf != "") print buf
          buf = line[i]
        } else if (buf != "" && line[i] ~ /^    +[^[:space:]]/) {
          t = line[i]; sub(/^[[:space:]]+/, "", t); buf = buf " " t
        } else {
          if (buf != "") print buf
          buf = ""
          print line[i]
        }
      }
      if (buf != "") print buf
    }'
}

risky_command_present() {
  local screen="$1"
  [ "$BLOCK_RISKY" = "1" ] || return 1

  printf '%s\n' "$screen" | grep -qiE \
    '(rm[[:space:]]+-[a-z]*r[a-z]*f|sudo[[:space:]]|curl[^|]*\|[[:space:]]*(ba)?sh|wget[^|]*\|[[:space:]]*(ba)?sh|git[[:space:]]+push[^&]*--force|dd[[:space:]]+if=|chmod[[:space:]]+-R[[:space:]]+777|mkfs\.|shutdown[[:space:]]|reboot[[:space:]])' \
    && return 0
  return 1
}

# Strict mode: exact Yes and No. A third "Yes, and don't ask again / for this
# session" option is tolerated, but Enter must select the one-time Yes.
strict_yes_no_prompt() {
  local screen="$1" normalized menu
  local yes_count yes_persistent_count no_count cursor_yes default_yes numbered_options

  normalized=$(normalize_screen "$screen")
  risky_command_present "$normalized" && return 1
  menu=$(menu_block "$normalized")

  yes_count=$(printf '%s\n' "$menu" | grep -icE '^[[:space:]]*(❯[[:space:]]*)?([0-9]+\.[[:space:]]*)?yes[[:space:]]*$' || true)
  yes_persistent_count=$(printf '%s\n' "$menu" | grep -icE \
    '^[[:space:]]*(❯[[:space:]]*)?([0-9]+\.[[:space:]]*)?yes,[[:space:]].*(don.t ask again|this session|always)' || true)
  no_count=$(printf '%s\n' "$menu" | grep -icE '^[[:space:]]*(❯[[:space:]]*)?([0-9]+\.[[:space:]]*)?no(,[[:space:]].*)?[[:space:]]*$' || true)

  [ "$yes_count" -eq 1 ] || return 1
  [ "$yes_persistent_count" -le 1 ] || return 1
  [ "$no_count" -eq 1 ] || return 1

  numbered_options=$(printf '%s\n' "$menu" | grep -cE '^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]' || true)
  [ "$numbered_options" -le $((2 + yes_persistent_count)) ] || return 1

  cursor_yes=$(printf '%s\n' "$menu" | grep -icE '^[[:space:]]*❯[[:space:]]*([0-9]+\.[[:space:]]*)?yes[[:space:]]*$' || true)
  [ "$yes_persistent_count" -eq 0 ] || [ "$cursor_yes" -eq 1 ] || return 1

  default_yes=$(printf '%s\n' "$menu" | grep -icE '(\(Y/n\)|\[Y/n\]|press enter to confirm yes|enter to confirm yes|default: yes)' || true)

  [ "$cursor_yes" -eq 1 ] || [ "$default_yes" -ge 1 ] || return 1
  return 0
}

# System One candidate: exactly one affirmative and one negative binary option.
# This does not authorize an action by itself; d1-2B must pass all three gates.
system_one_binary_candidate() {
  local screen="$1" normalized menu
  local affirmative_count negative_count cursor_affirmative default_affirmative numbered_options

  normalized=$(normalize_screen "$screen")
  risky_command_present "$normalized" && return 1
  menu=$(menu_block "$normalized")

  numbered_options=$(printf '%s\n' "$menu" | grep -cE '^[[:space:]]*(❯[[:space:]]*)?[0-9]+\.[[:space:]]' || true)
  [ "$numbered_options" -le 2 ] || return 1

  affirmative_count=$(printf '%s\n' "$menu" | grep -icE \
    '^[[:space:]]*(❯[[:space:]]*)?([0-9]+\.[[:space:]]*)?(yes([[:space:]]*,[[:space:]]*(always|allow|continue|proceed))?|approve|allow|confirm|proceed|continue|accept|install|run|execute|trust|enable)[[:space:]]*$' || true)

  negative_count=$(printf '%s\n' "$menu" | grep -icE \
    '^[[:space:]]*(❯[[:space:]]*)?([0-9]+\.[[:space:]]*)?(no|deny|reject|cancel|abort|skip|decline|disable|don.t[[:space:]]+run|do[[:space:]]+not[[:space:]]+run)[[:space:]]*$' || true)

  [ "$affirmative_count" -eq 1 ] || return 1
  [ "$negative_count" -eq 1 ] || return 1

  cursor_affirmative=$(printf '%s\n' "$menu" | grep -icE \
    '^[[:space:]]*❯[[:space:]]*([0-9]+\.[[:space:]]*)?(yes([[:space:]]*,[[:space:]]*(always|allow|continue|proceed))?|approve|allow|confirm|proceed|continue|accept|install|run|execute|trust|enable)[[:space:]]*$' || true)

  default_affirmative=$(printf '%s\n' "$menu" | grep -icE \
    '(\(Y/n\)|\[Y/n\]|press enter to confirm yes|enter to confirm yes|default: yes|default: approve|default: allow|default: confirm|default: proceed)' || true)

  [ "$cursor_affirmative" -eq 1 ] || [ "$default_affirmative" -ge 1 ] || return 1
  return 0
}

system_one_gate() {
  local screen="$1" result

  result=$(printf '%s' "$screen" | uv run --quiet --script "$SCRIPT_DIR/system_one.py" \
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

# After an Enter, chained requests can reach Herdr as one: the pane goes back to
# blocked without a new status event. Watch the pane for a short window.
still_needs_attention() {
  local pane="$1" i=0

  while [ "$i" -lt "$APPROVE_RECHECK_TRIES" ]; do
    [ "$(agent_status "$pane")" = "blocked" ] && return 0
    sleep "$APPROVE_RECHECK_SEC"
    i=$((i + 1))
  done
  return 1
}

approve_pane() {
  local pane="$1" sent=0

  while [ "$sent" -lt "$APPROVE_MAX_SENDS" ]; do
    [ "$(agent_status "$pane")" = "blocked" ] || break
    sleep "$APPROVE_DELAY_SEC"
    [ "$(agent_status "$pane")" = "blocked" ] || break
    prompt_allowed "$pane" || break

    "$HERDR" agent send-keys "$pane" enter >/dev/null 2>&1 || break
    sent=$((sent + 1))

    "$HERDR" agent wait "$pane" --until idle --until working --until done \
      --timeout "$APPROVE_LEAVE_TIMEOUT_MS" >/dev/null 2>&1 || true
    sleep "$APPROVE_SETTLE_SEC"

    still_needs_attention "$pane" || break
  done

  if [ "$sent" -eq 0 ]; then
    printf -- '-'
  elif [ "$(agent_status "$pane")" = "blocked" ]; then
    printf 0
  else
    printf 1
  fi
}