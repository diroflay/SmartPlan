#!/usr/bin/env bash
# smart-plan status: who is working on what, read from the <result>.status and <result>.events files
# that dispatch writes. Costs no model tokens. POSIX shells (bash 3.2+); Windows without bash: status.ps1.
#
# Usage: status.sh [dir] [watch_s]            board of every worker under dir (default .to-do);
#                                             with watch_s: redraw every watch_s seconds until Ctrl-C
#        status.sh wait <max_s> <result>...   block until none of these workers is running, at most max_s
#                                             seconds; prints one line per worker. Exit 0 = all finished,
#                                             3 = some still running (call again).
# States: running | done | failed | timeout | stale (running past its timeout: the dispatch was killed).
# The model is shown without its channel prefix (openrouter/deepseek/x -> x); the journal has the channel.
# Finished workers leave the board after 30 minutes; the journal keeps the history.
set -u

SOH=$(printf '\001')
now() { date +%s; }

# Load one status file into st_* variables.
load() {
  st_task=""; st_harness=""; st_model=""; st_mode=""; st_started=0; st_timeout=1800; st_state=""
  st_ended=0; st_exit=""; st_session=""; st_result=""
  [ -f "$1" ] || return 1
  while IFS='=' read -r k v; do
    v=${v%$'\r'}
    case "$k" in
      task) st_task=$v ;; harness) st_harness=$v ;; model) st_model=$v ;; mode) st_mode=$v ;;
      started) st_started=$v ;; timeout) st_timeout=$v ;; state) st_state=$v ;; ended) st_ended=$v ;;
      exit) st_exit=$v ;; session) st_session=$v ;; result) st_result=$v ;;
    esac
  done < "$1"
  [ -n "$st_state" ] || return 1
  if [ "$st_state" = running ] && [ $(( $(now) - st_started )) -gt $(( st_timeout + 120 )) ]; then st_state=stale; fi
  return 0
}

# First string value of a JSON key in $line, unescaped for display.
jval() {
  printf '%s' "$line" | grep -oE "\"$1\":\"(\\\\.|[^\"\\\\])*\"" | head -1 |
    sed -e "s/^\"$1\":\"//" -e 's/"$//' -e "s/\\\\\\\\/$SOH/g" -e 's/\\[nrt]/ /g' -e 's/\\"/"/g' -e "s/$SOH/\\\\/g"
}

# Last thing the worker did, from the tail of its event stream. Empty when the harness does not stream.
activity() { # <harness> <events file>
  [ -s "$2" ] || return 0
  case "$1" in
    claude)   pat='^."type":"assistant".*"type":"(tool_use|text)"' ;;
    codex)    pat='"type":"(command_execution|agent_message|file_change)"' ;;
    opencode) pat='^."type":"(tool_use|text)"' ;;
    agy)      pat='"step_type":"tool"' ;;
    *) return 0 ;;
  esac
  line=$(tail -c 262144 "$2" | grep -E "$pat" | tail -1)
  [ -n "$line" ] || return 0
  label=$(jval tool_name); [ -n "$label" ] || label=$(jval tool)
  if [ -z "$label" ]; then
    case "$line" in
      *'"type":"tool_use"'*) label=$(jval name) ;;
      *'"type":"command_execution"'*) label=shell ;;
      *'"type":"file_change"'*) label=edit ;;
      *) label=says ;;
    esac
  fi
  detail=""
  for k in command CommandLine; do
    [ -n "$detail" ] || detail=$(jval "$k" | sed -E 's/^.*(pwsh|powershell|bash|sh)(\.exe)?"? +(-NoProfile +)?(-Command|-lc|-c) +//')
  done
  for k in file_path filePath AbsolutePath TargetFile path; do
    [ -n "$detail" ] || detail=$(jval "$k" | sed -e 's|.*[\\/]||')
  done
  for k in pattern query text; do
    [ -n "$detail" ] || detail=$(jval "$k")
  done
  printf '%s' "$label${detail:+: $detail}" | cut -c1-60
}

clock() { printf '%d:%02d' $(( $1 / 60 )) $(( $1 % 60 )); }

board() { # <dir>
  n_run=0; n_fin=0; n_old=0; rows=""
  while IFS= read -r f; do
    load "$f" || continue
    t=$(now)
    case "$st_state" in
      running) n_run=$((n_run + 1)); el=$(( t - st_started )) ;;
      stale)   n_fin=$((n_fin + 1)); el=$(( t - st_started )) ;;
      *) if [ $(( t - st_ended )) -gt 1800 ]; then n_old=$((n_old + 1)); continue; fi
         n_fin=$((n_fin + 1)); el=$(( st_ended - st_started )) ;;
    esac
    act=""
    [ "$st_state" = running ] && act=$(activity "$st_harness" "${f%.status}.events")
    [ "$st_state" = stale ] && act="no sign of life past its timeout: dispatch again"
    case "$st_state" in running|stale) ;; *) act="exit=$st_exit result=$st_result" ;; esac
    rows="$rows$st_started|$(printf '%-18.18s %-34.34s %-8s %6s  %s' "$st_task" "${st_model##*/} ($st_harness)" "$st_state" "$(clock "$el")" "$act")
"
  done <<EOF
$(find "$1" -type f -name '*.status' 2>/dev/null)
EOF
  printf '%-18s %-34s %-8s %6s  %s\n' TASK "MODEL (HARNESS)" STATE TIME "LAST ACTIVITY"
  printf '%s' "$rows" | sort -n | cut -d'|' -f2-
  echo "-- $n_run running, $n_fin finished, $n_old older than 30 min hidden -- $(date '+%H:%M:%S')"
}

if [ "${1:-}" = wait ]; then
  [ $# -ge 3 ] || { echo "usage: status.sh wait <max_s> <result>..." >&2; exit 2; }
  max=$2; shift 2; t0=$(now)
  while :; do
    busy=0
    for r in "$@"; do load "$r.status" && [ "$st_state" = running ] && busy=1; done
    [ "$busy" -eq 0 ] && break
    [ $(( $(now) - t0 )) -ge "$max" ] && break
    sleep 2
  done
  for r in "$@"; do
    if load "$r.status"; then echo "$st_task | $st_model ($st_harness) | state=$st_state exit=$st_exit session=$st_session result=$st_result"
    else echo "$r | no status file"; fi
  done
  [ "$busy" -eq 0 ] && exit 0
  exit 3
fi

dir=${1:-.to-do}; every=${2:-}
[ -d "$dir" ] || { echo "status: folder not found: $dir" >&2; exit 2; }
if [ -z "$every" ]; then board "$dir"; exit 0; fi
while :; do out=$(board "$dir"); printf '\033[2J\033[H%s\n' "$out"; sleep "$every"; done
