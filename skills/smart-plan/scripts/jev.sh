#!/usr/bin/env bash
# smart-plan Jev call: builds the System One request from files, so no model ever has to re-type a diff as JSON.
# POSIX shells: Linux, macOS (bash 3.2+), Git Bash, WSL. Windows without bash: use jev.ps1. Needs curl. No jq, no Node.
#
#   jev.sh <questions.json> <response.json> <name=file> [<name=file> ...]
#
#   questions.json  the "questions" object only (small, written by the caller)
#   name=file       one state entry per pair: state.<name> = text content of <file>   e.g. goal=goal.txt diff=task.diff
#
# Env: TYPESAFE_API_KEY (required, never printed) - SP_JEV_MODEL (default jev-latest) - SP_JEV_URL - SP_JEV_MAX_BYTES (default 80000)
# Prints: http=<code>  and  response=<path>.   Exit: 0 ok - 1 call failed - 2 usage - 3 state too large (slice it) - 4 no key
set -u
[ $# -ge 3 ] || { echo "usage: jev.sh <questions.json> <response.json> <name=file> [<name=file> ...]" >&2; exit 2; }
questions=$1; out=$2; shift 2
[ -f "$questions" ] || { echo "questions file not found: $questions" >&2; exit 2; }
[ -n "${TYPESAFE_API_KEY:-}" ] || { echo "TYPESAFE_API_KEY not set" >&2; exit 4; }
command -v curl >/dev/null 2>&1 || { echo "curl not installed" >&2; exit 1; }
url=${SP_JEV_URL:-https://api.typesafe.ai/v1/systemone}
model=${SP_JEV_MODEL:-jev-latest}
max=${SP_JEV_MAX_BYTES:-80000}
tab=$(printf '\t')
body="$out.request"

json_string() { # <file> : file content as the inside of a JSON string
  tr -d '\000-\010\013-\037' < "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$tab/\\\\t/g" | awk '{ printf "%s\\n", $0 }'
}

total=0
for pair in "$@"; do
  f=${pair#*=}
  [ "$f" != "$pair" ] && [ -f "$f" ] || { echo "bad state entry (want name=file, file must exist): $pair" >&2; exit 2; }
  total=$((total + $(wc -c < "$f")))
done
if [ "$total" -gt "$max" ]; then echo "state is $total bytes, limit $max: slice the diff by file group and call once per slice" >&2; exit 3; fi

{
  printf '{"model":"%s","state":{' "$model"
  first=1
  for pair in "$@"; do
    [ $first -eq 1 ] || printf ','
    first=0
    printf '"%s":"' "${pair%%=*}"; json_string "${pair#*=}"; printf '"'
  done
  printf '},"questions":'
  cat "$questions"
  printf '}'
} > "$body"

try=1; code=000
while [ $try -le 3 ]; do
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$TYPESAFE_API_KEY" | curl -s -o "$out" -w '%{http_code}' --max-time 60 --config - -H 'Content-Type: application/json' --data-binary "@$body" "$url" 2>/dev/null)
  case "$code" in 429|529) sleep $((try * 5)); try=$((try + 1)) ;; *) break ;; esac
done
echo "http=${code:-000}"
echo "response=$out"
[ "$code" = 200 ]
