#!/usr/bin/env bash
# smart-plan dispatch: run ONE worker headlessly, the same way on every machine.
# POSIX shells: Linux, macOS (bash 3.2+), Git Bash, WSL. Windows without bash: use dispatch.ps1.
#
# Usage: dispatch.sh <harness> <model> <write|read> <repo> <brief> <result> [timeout_s] [session]
#   harness : claude | codex | gemini | agy | opencode
#   brief   : file piped to the worker on stdin (with [session]: the follow-up message)
#   result  : file that will hold the worker's final message
# Optional env: SP_CODEGRAPH=<binary>  code-graph tool read-only claude workers may run (default codebase-memory-mcp)
# Optional env: SP_ALLOW='Bash(npm test *)'  extra tool rule for claude workers (verify command)
# Optional env: SP_TASK='P2.T1 backend'  label shown on the status board (default: result file name)
# Optional env: SP_DETACH=1  start the worker detached, print started=<status file> and return at once;
#                            collect it with: status.sh wait <max_s> <result>...
# Live state: <result>.status (key=value lines, read by status.sh / status.ps1); raw events: <result>.events
# Prints 3 lines: exit=<code>  session=<id>  result=<worker|captured|missing>. Exit 124 = timeout.
# Never adds permission-bypass or sandbox-bypass flags.
set -u

die() { echo "dispatch: $*" >&2; exit 2; }
[ $# -ge 6 ] || die "usage: dispatch.sh <harness> <model> <write|read> <repo> <brief> <result> [timeout_s] [session]"
harness=$1; model=$2; mode=$3; repo=$4; brief=$5; result=$6; tmo=${7:-1800}; sess=${8:-}

abspath() { case "$1" in /*|[A-Za-z]:*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
brief=$(abspath "$brief"); result=$(abspath "$result")
[ -f "$brief" ] || die "brief not found: $brief"
[ -d "$repo" ] || die "repo not found: $repo"
case "$mode" in write|read) ;; *) die "mode must be write or read" ;; esac
command -v "$harness" >/dev/null 2>&1 || die "harness not installed: $harness"
mkdir -p "$(dirname "$result")"
events="$result.events"; errf="$result.stderr"; status="$result.status"
started=$(date +%s)

write_status() { # <state> [exit session result]
  {
    echo "task=${SP_TASK:-$(basename "$result")}"; echo "harness=$harness"; echo "model=$model"; echo "mode=$mode"
    echo "started=$started"; echo "timeout=$tmo"; echo "state=$1"
    if [ $# -gt 1 ]; then echo "ended=$(date +%s)"; echo "exit=$2"; echo "session=$3"; echo "result=$4"; fi
  } > "$status.tmp"
  mv -f "$status.tmp" "$status" 2>/dev/null || { cat "$status.tmp" > "$status"; rm -f "$status.tmp"; }
}

# Detached start: the parent marks the task running (so a wait never reads an older round) and returns.
if [ -n "${SP_DETACH:-}" ]; then
  write_status running
  if command -v nohup >/dev/null 2>&1; then SP_DETACH= nohup bash "$0" "$@" >/dev/null 2>&1 &
  else SP_DETACH= bash "$0" "$@" >/dev/null 2>&1 & fi
  echo "started=$status"; exit 0
fi

cd "$repo" || die "cannot enter repo"
before=""; [ -f "$result" ] && before=$(cksum < "$result")

cmd=()
case "$harness" in
  claude)
    cmd=(claude -p --model "$model" --output-format stream-json --verbose)
    [ -n "$sess" ] && cmd+=(--resume "$sess")
    if [ "$mode" = write ]; then
      cmd+=(--permission-mode acceptEdits)
      [ -n "${SP_ALLOW:-}" ] && cmd+=(--allowedTools "$SP_ALLOW")
    else
      cmd+=(--permission-mode dontAsk --allowedTools Read Grep Glob "Bash(git diff *)" "Bash(git status *)" "Bash(${SP_CODEGRAPH:-codebase-memory-mcp} *)")
      [ -n "${SP_ALLOW:-}" ] && cmd+=("$SP_ALLOW")
    fi ;;
  codex)
    sb=read-only; [ "$mode" = write ] && sb=workspace-write
    # "codex exec resume" has no -s flag: without the config override a resumed session runs under the
    # config.toml default sandbox. The value is not valid TOML, so codex takes it as a literal string.
    if [ -n "$sess" ]; then cmd=(codex exec resume "$sess" -m "$model" -c "sandbox_mode=$sb")
    else cmd=(codex exec -m "$model" -C "$PWD" -s "$sb"); fi
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || cmd+=(--skip-git-repo-check)
    cmd+=(--json -o "$result" -) ;;
  gemini)
    am=default; [ "$mode" = write ] && am=auto_edit
    cmd=(gemini -m "$model" --approval-mode "$am" -o json)
    [ -n "$sess" ] && cmd+=(-r "$sess")
    cmd+=(-p "Execute the task brief provided on stdin.") ;;
  agy)
    # agy does not read the prompt from stdin: pass the brief by path (native form on Git Bash).
    # It also resolves relative paths next to the brief unless told where the repository is.
    bp=$brief; rp=$PWD; command -v cygpath >/dev/null 2>&1 && { bp=$(cygpath -w "$brief"); rp=$(cygpath -w "$PWD"); }
    # In print mode it loads the repository's AGENTS.md / GEMINI.md only when the repository is passed with --add-dir.
    am=plan; [ "$mode" = write ] && am=accept-edits
    cmd=(agy -p "Read the task brief at this path and execute it exactly: $bp - relative paths in the brief start at the repository root: $rp" --mode "$am" --add-dir "$rp" --output-format stream-json --print-timeout "${tmo}s")
    [ "$model" != auto ] && cmd+=(--model "$model")
    [ -n "$sess" ] && cmd+=(--conversation "$sess") ;;
  opencode)
    cmd=(opencode run -m "$model" --dir "$PWD" --format json)
    [ "$mode" = write ] && cmd+=(--auto)
    [ -n "$sess" ] && cmd+=(-s "$sess") ;;
  *) die "unknown harness: $harness" ;;
esac

# Portable timeout: timeout (GNU), gtimeout (macOS coreutils), else a watchdog.
rc=0
run_worker() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$tmo" "${cmd[@]}" < "$brief" > "$events" 2> "$errf"; rc=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$tmo" "${cmd[@]}" < "$brief" > "$events" 2> "$errf"; rc=$?
  else
    "${cmd[@]}" < "$brief" > "$events" 2> "$errf" & pid=$!
    ( sleep "$tmo"; kill "$pid" 2>/dev/null && : > "$events.timeout" ) & wd=$!
    wait "$pid"; rc=$?
    kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
    [ -f "$events.timeout" ] && { rm -f "$events.timeout"; rc=124; }
  fi
}
write_status running
run_worker 2>/dev/null   # hides the shell's own "Terminated" notice (bash 3.2); worker stderr still goes to $errf
# Normalise timeout exit codes: GNU timeout = 124, BusyBox timeout = 143, SIGKILL = 137.
if [ $(( $(date +%s) - started )) -ge "$tmo" ]; then case "$rc" in 137|143) rc=124 ;; esac; fi

# Last string value of a JSON key, without jq. node gives exact parsing; grep -oE + sed is the fallback
# (compact or pretty-printed JSON: optional whitespace around the colon; BSD and GNU safe).
json_last() { # <key> <file>
  if command -v node >/dev/null 2>&1; then
    node -e 'const fs=require("fs");const k=process.argv[1];let out="";const walk=o=>{if(o&&typeof o==="object"){for(const [a,b] of Object.entries(o)){if(a===k&&typeof b==="string")out=b;else walk(b)}}};for(const l of fs.readFileSync(process.argv[2],"utf8").split(/\r?\n/)){try{walk(JSON.parse(l))}catch(e){}}if(!out){try{walk(JSON.parse(fs.readFileSync(process.argv[2],"utf8")))}catch(e){}}process.stdout.write(out)' "$1" "$2"
  else
    grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"(\\\\.|[^\"\\\\])*\"" "$2" | tail -1 | sed -e "s/^\"$1\"[[:space:]]*:[[:space:]]*\"//" -e 's/"$//' -e 's/\\n/\
/g' -e 's/\\"/"/g' -e 's/\\\\/\\/g'
  fi
}

case "$harness" in
  claude)   session=$(json_last session_id "$events"); final=result ;;
  codex)    session=$(json_last thread_id "$events");  final=text ;;
  gemini)   session=$(json_last session_id "$events"); [ -n "$session" ] || session=$(json_last sessionId "$events")
            final=response ;;   # best effort: only gemini versions that report a session id allow a resume
  agy)      session=$(json_last conversation_id "$events"); final=response ;;
  opencode) session=$(json_last sessionID "$events");  final=text ;;
esac
[ -z "$session" ] && session=$sess

# Result: prefer what the worker wrote; otherwise capture its final message.
after=""; [ -s "$result" ] && after=$(cksum < "$result")
if [ -n "$after" ] && [ "$after" != "$before" ]; then state=worker
else
  msg=$(json_last "$final" "$events")
  if [ -n "$msg" ]; then printf '%s\n' "$msg" > "$result"; state=captured; else state=missing; fi
fi

fin=done; [ "$rc" -ne 0 ] && fin=failed; [ "$rc" -eq 124 ] && fin=timeout
write_status "$fin" "$rc" "$session" "$state"
echo "exit=$rc"; echo "session=$session"; echo "result=$state"
exit "$rc"
