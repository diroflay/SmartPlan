#!/usr/bin/env bash
# smart-plan preflight: collect access facts the same way on every machine. Never prints a secret.
# POSIX shells: Linux, macOS (bash 3.2+), Git Bash, WSL. Windows without bash: use preflight.ps1.
#
#   preflight.sh check <provider,provider,...>   providers: anthropic openai google deepseek zai qwen typesafe openrouter
#   preflight.sh smoke <harness> <model> [timeout_s]   one tiny real request through dispatch.sh (read-only)
#   preflight.sh smoke-all <timeout_s> <harness>=<model> [<harness>=<model> ...]   the same, every pair in parallel;
#                                          one smoke row per pair, in the order given; exit 0 only if every row is OK, else 1
#   preflight.sh models <harness> [regex]  model IDs only, one per line, filtered by a case-insensitive extended regex
#                                          (default: all). Exit 0 = at least one ID, 1 = none, 2 = unknown / not installed harness
#   preflight.sh agents [dir]              read-only: is the repository readable by every harness? (dir default .)
#
# Optional env: SP_CODEGRAPH=<binary>  code-graph tool to look for (default codebase-memory-mcp)
# Optional env: SP_SMOKE_CACHE_H=<hours>  an OK smoke younger than this is reused instead of a new call (default 24,
#               0 = never read the cache). Cache: <home>/.cache/smart-plan/smoke.tsv, lines epoch <tab> harness <tab> model;
#               only OK results are recorded.
# check prints tab-separated lines:  STATUS <tab> item <tab> detail <tab> fix      STATUS = OK | MISSING | INFO
# and one line per provider:         CHANNEL <tab> provider <tab> subscription|api-key|openrouter|none
# smoke / smoke-all print:           OK|MISSING <tab> smoke.<harness> <tab> detail <tab> fix
# agents prints:  LAYOUT <tab> folder <tab> none|claude-only|gemini-only|vendor-only|agents-only|no-import|agents-invalid|symlink|compatible
#                 GAP <tab> skills|commands|subagents|mcp|rules|permissions|size <tab> path
#                 RESULT <tab> compatible|work-needed      (last line; exit 0)
set -u
here=$(cd "$(dirname "$0")" && pwd)
esc=$(printf '\033')
strip_ansi() { sed "s/${esc}\[[0-9;]*m//g"; }   # POSIX-safe (BSD sed has no \x1b)
row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}"; }
has() { command -v "$1" >/dev/null 2>&1; }
envset() { eval "[ -n \"\${$1:-}\" ]"; }
ver() { "$1" --version 2>/dev/null | head -1 | tr -d '\r'; }

oc_auth=""
oc_has() { # <regex> : credential stored in opencode?
  has opencode || return 1
  [ -n "$oc_auth" ] || oc_auth=$(opencode auth list 2>/dev/null | strip_ansi)
  printf '%s' "$oc_auth" | grep -Eiq "$1"
}

check_env() {
  row INFO shell "bash ${BASH_VERSION:-?} on $(uname -s 2>/dev/null)"
  if has timeout; then row OK timeout "timeout"; elif has gtimeout; then row OK timeout "gtimeout"
  else row INFO timeout "none: dispatch.sh uses its built-in watchdog" "optional: brew install coreutils"; fi
  if has git; then
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then row OK git "repository: $(git rev-parse --show-toplevel 2>/dev/null)"
    else row MISSING git "current directory is not a git repository" "git init"; fi
  else row MISSING git "not installed" "install git"; fi
  if has curl; then row OK curl "$(ver curl)"; else row INFO curl "not installed (needed only for Jev and OpenRouter key validation)" "install curl"; fi
  cg=${SP_CODEGRAPH:-codebase-memory-mcp}   # code-graph binary named in routing.md
  if has "$cg"; then row OK codegraph "$(ver "$cg")"
  else row INFO codegraph "$cg not installed (fatal only if REQUIRE_CODEGRAPH is on)" "install it (routing.md, Code graph), or set SP_CODEGRAPH to the routed binary"; fi
  if has node; then row INFO node "$(ver node)"; else row INFO node "absent: dispatch.sh falls back to sed parsing"; fi
}

openrouter_ok=1
check_openrouter() {
  if envset OPENROUTER_API_KEY; then
    if has curl; then
      code=$(printf 'header = "Authorization: Bearer %s"\n' "$OPENROUTER_API_KEY" | curl -s -o /dev/null -w '%{http_code}' --max-time 20 --config - https://openrouter.ai/api/v1/key 2>/dev/null)
      case "$code" in
        200) row OK openrouter.key "env var present, validated (HTTP 200)"; openrouter_ok=0 ;;
        401) row MISSING openrouter.key "env var present but rejected (HTTP 401)" "create a new key at openrouter.ai/keys" ;;
        *)   row INFO openrouter.key "env var present, validation inconclusive (HTTP ${code:-none})"; openrouter_ok=0 ;;
      esac
    else row OK openrouter.key "env var present (not validated: no curl)"; openrouter_ok=0; fi
  elif oc_has 'openrouter'; then row OK openrouter.key "credential stored in opencode (validated by the smoke test)"; openrouter_ok=0
  else row MISSING openrouter.key "no OPENROUTER_API_KEY and no opencode credential" "opencode auth login  (or set OPENROUTER_API_KEY)"; fi
  if has opencode; then row OK openrouter.bridge "opencode $(ver opencode)"; else row MISSING openrouter.bridge "opencode not installed" "npm i -g opencode-ai"; openrouter_ok=1; fi
}

channel() { # <provider> <sub 0/1> <key 0/1> <via-openrouter yes/no>
  if [ "$2" = 0 ]; then c=subscription; elif [ "$3" = 0 ]; then c=api-key
  elif [ "$4" = yes ] && [ "$openrouter_ok" = 0 ]; then c=openrouter; else c=none; fi
  printf 'CHANNEL\t%s\t%s\n' "$1" "$c"
}

check_provider() {
  sub=1; key=1
  case "$1" in
    anthropic)
      if has claude; then
        st=$(claude auth status 2>/dev/null | tr -d ' \r\n')
        case "$st" in
          *'"loggedIn":true'*'"subscriptionType":"'*) sub=0; row OK anthropic.subscription "claude $(ver claude), subscription login" ;;
          *'"loggedIn":true'*) row INFO anthropic.subscription "logged in, no subscription type reported" ;;
          *) row MISSING anthropic.subscription "claude installed, not logged in" "claude auth login" ;;
        esac
      else row MISSING anthropic.subscription "claude CLI not installed" "https://code.claude.com/docs"; fi
      if envset ANTHROPIC_API_KEY; then key=0; row OK anthropic.api-key present; else row INFO anthropic.api-key "ANTHROPIC_API_KEY not set"; fi
      channel anthropic $sub $key yes ;;
    openai)
      if has codex; then
        ls=$(codex login status 2>&1); rc=$?
        if [ $rc -eq 0 ] && printf '%s' "$ls" | grep -qi chatgpt; then sub=0; row OK openai.subscription "codex $(ver codex), ChatGPT login"
        elif [ $rc -eq 0 ]; then key=0; row OK openai.api-key "codex logged in with an API key"
        else row MISSING openai.subscription "codex installed, not logged in" "codex login"; fi
      else row MISSING openai.subscription "codex CLI not installed" "npm i -g @openai/codex"; fi
      if envset CODEX_API_KEY || envset OPENAI_API_KEY; then key=0; row OK openai.api-key present; fi
      channel openai $sub $key yes ;;
    google)
      g=""; has agy && g="agy"; has gemini && g="$g gemini"
      if [ -n "$g" ]; then row INFO google.harness "installed:$g (no auth-status command exists: run the smoke test)"
      else row MISSING google.harness "neither agy nor gemini installed" "install Antigravity CLI, or: npm i -g @google/gemini-cli"; fi
      if envset GEMINI_API_KEY || envset GOOGLE_API_KEY || envset GOOGLE_CLOUD_PROJECT; then key=0; row OK google.api-key present; else row INFO google.api-key "no GEMINI_API_KEY / Vertex env"; fi
      if [ -n "$g" ] && [ $key -ne 0 ]; then printf 'CHANNEL\tgoogle\tunverified-login (smoke test decides)\n'; else channel google 1 $key yes; fi ;;
    deepseek)
      row INFO deepseek.subscription "DeepSeek offers no subscription"
      if envset DEEPSEEK_API_KEY || oc_has 'deepseek'; then key=0; row OK deepseek.api-key present; else row INFO deepseek.api-key "no DEEPSEEK_API_KEY (OpenRouter will be used)"; fi
      channel deepseek 1 $key yes ;;
    zai)
      if oc_has 'coding plan'; then sub=0; row OK zai.subscription "GLM Coding Plan credential in opencode"; else row INFO zai.subscription "no GLM Coding Plan credential in opencode"; fi
      if envset ZHIPU_API_KEY || oc_has 'z\.ai|zhipu'; then key=0; row OK zai.api-key present; else row INFO zai.api-key "no ZHIPU_API_KEY"; fi
      channel zai $sub $key yes ;;
    qwen)
      if envset ALIBABA_TOKEN_PLAN_API_KEY || oc_has 'token plan'; then sub=0; row OK qwen.subscription "Alibaba Token Plan credential present"; else row INFO qwen.subscription "no Alibaba Token Plan credential"; fi
      oc_has . # fills oc_auth; a "... Plan" line is a subscription, not the pay-as-you-go key
      if envset DASHSCOPE_API_KEY || printf '%s\n' "$oc_auth" | grep -Ei 'alibaba|dashscope' | grep -viq 'plan'; then key=0; row OK qwen.api-key present; else row INFO qwen.api-key "no DASHSCOPE_API_KEY (OpenRouter will be used)"; fi
      channel qwen $sub $key yes ;;
    typesafe)
      if envset TYPESAFE_API_KEY; then key=0
        if has curl; then # GET /v1/models validates the key without spending a token
          base=${SP_JEV_URL:-https://api.typesafe.ai/v1/systemone}
          code=$(printf 'header = "Authorization: Bearer %s"\n' "$TYPESAFE_API_KEY" | curl -s -o /dev/null -w '%{http_code}' --max-time 20 --config - "${base%/*}/models" 2>/dev/null)
          case "$code" in
            200) row OK typesafe.api-key "present, validated (HTTP 200)" ;;
            401) key=1; row MISSING typesafe.api-key "present but rejected (HTTP 401)" "create a new key in the TypeSafe console, or set the review gate to off in routing.md" ;;
            *)   row INFO typesafe.api-key "present, validation inconclusive (HTTP ${code:-none})" ;;
          esac
        else row OK typesafe.api-key present; fi
      else row MISSING typesafe.api-key "TYPESAFE_API_KEY not set (Jev has no other channel)" "set TYPESAFE_API_KEY, or set the review gate to off in routing.md"; fi
      has curl || row MISSING typesafe.curl "curl is required to call Jev" "install curl"
      sk=1 # official skill: optional question-design guidance for the orchestrator, never needed to call Jev
      if has claude && claude plugin list 2>/dev/null | grep -qi 'typesafe@'; then sk=0; fi
      for d in .claude/skills .agents/skills "$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.codex/skills" "$HOME/.config/opencode/skills"; do
        [ -f "$d/typesafe-ai/SKILL.md" ] && sk=0
      done
      if [ $sk -eq 0 ]; then row OK typesafe.skill "official TypeSafe skill installed"
      else row INFO typesafe.skill "official TypeSafe skill not installed (optional)" "Claude Code: claude plugin marketplace add typesafe-ai/skills, then claude plugin install typesafe@typesafe-ai - other agents: npx skills add typesafe-ai/skills --skill typesafe-ai"; fi
      channel typesafe 1 $key no ;;
    openrouter) : ;;
    *) row INFO "$1" "unknown provider: reachable only through opencode / OpenRouter"; channel "$1" 1 1 yes ;;
  esac
}

# --- smoke: one tiny real request, with a cache of OK results ---
tab=$(printf '\t'); cr=$(printf '\r'); bom=$(printf '\357\273\277')
cache="${HOME:-}/.cache/smart-plan/smoke.tsv"
cache_hit() { # <harness> <model> : prints the age in hours of the youngest fresh OK, else returns 1
  ch=${SP_SMOKE_CACHE_H:-24}; case "$ch" in ''|*[!0-9]*) ch=24 ;; esac
  [ "$ch" -gt 0 ] || return 1
  [ -n "${HOME:-}" ] && [ -f "$cache" ] || return 1
  now=$(date +%s); best=""
  while IFS="$tab" read -r ce charness cmodel || [ -n "$ce" ]; do
    cmodel=${cmodel%"$cr"}
    case "$ce" in ''|*[!0-9]*) continue ;; esac
    [ "$charness" = "$1" ] && [ "$cmodel" = "$2" ] || continue
    age=$(( now - ce ))
    [ "$age" -ge 0 ] && [ "$age" -lt $(( ch * 3600 )) ] || continue
    if [ -z "$best" ] || [ "$age" -lt "$best" ]; then best=$age; fi
  done < "$cache"
  [ -n "$best" ] || return 1
  echo $(( best / 3600 ))
}
cache_put() { # <harness> <model> : never fails (an unwritable home is ignored)
  [ -n "${HOME:-}" ] || return 0
  { mkdir -p "${cache%/*}" && printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" >> "$cache"; } 2>/dev/null
  return 0
}
smoke_one() { # <harness> <model> <timeout_s> : prints one row, returns the dispatch exit code
  if hrs=$(cache_hit "$1" "$2"); then row OK "smoke.$1" "$2 replied (cached ${hrs}h ago)"; return 0; fi
  tmp=$(mktemp -d 2>/dev/null || { d="${TMPDIR:-/tmp}/sp-smoke-$$-$1"; mkdir -p "$d"; echo "$d"; })
  printf 'Reply with exactly: OK\nDo nothing else. Do not use any tool.\n' > "$tmp/brief.md"
  out=$(bash "$here/dispatch.sh" "$1" "$2" read "$tmp" "$tmp/brief.md" "$tmp/result.md" "$3" 2>&1); rc=$?
  if [ $rc -eq 0 ] && grep -q 'OK' "$tmp/result.md" 2>/dev/null; then row OK "smoke.$1" "$2 replied"; cache_put "$1" "$2"
  else
    why=$(tail -c 300 "$tmp/result.md.stderr" 2>/dev/null | strip_ansi | tr '\r\n\t' '   ')
    [ -n "$(printf '%s' "$why" | tr -d ' ')" ] || why=$(tail -c 300 "$tmp/result.md.events" 2>/dev/null | strip_ansi | tr '\r\n\t' '   ')
    [ $rc -eq 124 ] && why="timeout"
    row MISSING "smoke.$1" "$2 failed (exit $rc): ${why:-no output}" "check login, model access, quota / credit"
  fi
  rm -rf "$tmp"; return $rc
}

# --- models: IDs only (the raw listings are far too large for an orchestrator to read) ---
list_models() { # <harness>
  case "$1" in
    claude)   printf '%s\n' fable opus sonnet haiku ;;   # aliases: no list command exists
    gemini)   printf '%s\n' pro flash auto ;;            # aliases: no list command exists
    opencode) opencode models 2>/dev/null < /dev/null | strip_ansi ;;
    codex)
      if has node; then
        codex debug models 2>/dev/null < /dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);for(const m of (j.models||j.data||j)){const id=m&&(m.slug||m.id);if(typeof id==="string")console.log(id)}}catch(e){}})'
      else
        codex debug models 2>/dev/null < /dev/null | grep -oE '"slug"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -e 's/"$//' -e 's/.*"//'
      fi ;;
    agy)      # "id <tab> display name" lines; any other format: the lines as they are
      ml=$(agy models 2>/dev/null < /dev/null | strip_ansi | tr -d '\r')
      if printf '%s\n' "$ml" | grep -q "$tab"; then printf '%s\n' "$ml" | grep "$tab" | cut -f1
      else printf '%s\n' "$ml"; fi ;;
  esac
}

# --- agents: is the repository readable by every harness? Read-only, no model call, no network. ---
lines() { tr -d '\r' < "$1" 2>/dev/null | sed "1s/^$bom//"; }   # CR and BOM tolerant
first_line() { lines "$1" | grep -v '^[[:space:]]*$' | head -1; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
nonempty_dir() { [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]; }
present() { [ -f "$1" ] || nonempty_dir "$1"; }
contains() { [ -f "$2" ] && grep -qF -- "$1" "$2" 2>/dev/null; }
gap() { printf 'GAP\t%s\t%s\n' "$1" "$2"; allok=0; }
layout_state() { # <folder>
  fa="$1/AGENTS.md"; fc="$1/CLAUDE.md"; fg="$1/GEMINI.md"; ha=0; hc=0; hg=0
  exists "$fa" && ha=1; exists "$fc" && hc=1; exists "$fg" && hg=1
  if [ $ha = 0 ]; then
    if [ $hc = 1 ] && [ $hg = 1 ]; then echo vendor-only; elif [ $hc = 1 ]; then echo claude-only
    elif [ $hg = 1 ]; then echo gemini-only; else echo none; fi
    return
  fi
  if [ -L "$fa" ] || [ -L "$fc" ] || [ -L "$fg" ]; then echo symlink; return; fi
  if [ $hc = 0 ] && [ $hg = 0 ]; then echo agents-only; return; fi
  # a missing bridge counts as a bridge that does not import
  if [ $hc = 0 ] || [ $hg = 0 ] || [ "$(first_line "$fc")" != "@AGENTS.md" ] || [ "$(first_line "$fg")" != "@./AGENTS.md" ]; then echo no-import; return; fi
  if [ ! -s "$fa" ] || lines "$fa" | grep -q '^@'; then echo agents-invalid; return; fi
  echo compatible
}
agents_cmd() { # <dir>
  cd "$1" 2>/dev/null || { echo "preflight: folder not found: $1" >&2; exit 2; }
  if has git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    found=$( { git -c core.quotePath=false ls-files; git -c core.quotePath=false ls-files --others --exclude-standard; } 2>/dev/null )
  else
    found=$(find . \( -name .git -o -name node_modules \) -prune -o \( -type f -o -type l \) \( -name AGENTS.md -o -name CLAUDE.md -o -name GEMINI.md \) -print 2>/dev/null | sed 's|^\./||')
  fi
  folders=$(printf '%s\n' "$found" | tr -d '\r' | grep -E '/(AGENTS|CLAUDE|GEMINI)\.md$' | grep -Ev '(^|/)(\.git|node_modules)/' |
    while IFS= read -r f; do exists "$f" && printf '%s\n' "${f%/*}"; done | LC_ALL=C sort -u)
  allok=1; total=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    st=$(layout_state "$d"); printf 'LAYOUT\t%s\t%s\n' "$d" "$st"
    [ "$st" = compatible ] || allok=0
    [ -f "$d/AGENTS.md" ] && total=$(( total + $(wc -c < "$d/AGENTS.md" | tr -d ' ') ))
  done <<LIST
.
$folders
LIST
  s1=0; s2=0; nonempty_dir .claude/skills && s1=1; nonempty_dir .agents/skills && s2=1
  [ $s1 = 1 ] && [ $s2 = 0 ] && gap skills .claude/skills
  [ $s1 = 0 ] && [ $s2 = 1 ] && gap skills .agents/skills
  for p in .claude/commands .gemini/commands .codex/prompts; do nonempty_dir "$p" && gap commands "$p"; done
  for p in .claude/agents .codex/agents .gemini/agents .agents/agents; do nonempty_dir "$p" && gap subagents "$p"; done
  [ -f .mcp.json ] && gap mcp .mcp.json
  contains mcpServers .gemini/settings.json && gap mcp .gemini/settings.json
  contains '"mcp"' opencode.json && gap mcp opencode.json
  for p in .cursorrules .cursor/rules .github/copilot-instructions.md .windsurfrules .clinerules; do present "$p" && gap rules "$p"; done
  [ -f .claude/settings.json ] && gap permissions .claude/settings.json
  contains '"permission"' opencode.json && gap permissions opencode.json
  if [ -f AGENTS.md ]; then   # characters = bytes that are not UTF-8 continuation bytes (locale independent)
    chars=$(LC_ALL=C tr -d '\200-\277' < AGENTS.md | wc -c | tr -d ' ')
    [ "$chars" -gt 12000 ] && gap size "AGENTS.md: $chars characters (limit 12000)"
  fi
  [ "$total" -gt 32768 ] && gap size "all AGENTS.md: $total bytes (limit 32768)"
  if [ $allok = 1 ]; then printf 'RESULT\tcompatible\n'; else printf 'RESULT\twork-needed\n'; fi
}

usage() { echo "usage: preflight.sh check <providers> | smoke <harness> <model> [timeout_s] | smoke-all <timeout_s> <harness>=<model> ... | models <harness> [regex] | agents [dir]" >&2; exit 2; }
case "${1:-}" in
  check)
    [ $# -ge 2 ] || usage
    check_env; check_openrouter
    for p in $(printf '%s' "$2" | tr ',' ' '); do check_provider "$p"; done ;;
  smoke)
    [ $# -ge 3 ] || usage
    smoke_one "$2" "$3" "${4:-120}"; exit $? ;;
  smoke-all)
    [ $# -ge 3 ] || usage
    case "$2" in ''|*[!0-9]*) usage ;; esac
    tmo=$2; shift 2
    for pair in "$@"; do case "$pair" in ?*=?*) ;; *) usage ;; esac; done
    sdir=$(mktemp -d 2>/dev/null || { d="${TMPDIR:-/tmp}/sp-smoke-all-$$"; mkdir -p "$d"; echo "$d"; })
    n=0
    for pair in "$@"; do
      n=$(( n + 1 ))
      ( smoke_one "${pair%%=*}" "${pair#*=}" "$tmo" > "$sdir/$n.row" 2>/dev/null ) &
    done
    wait
    n=0; bad=0
    for pair in "$@"; do
      n=$(( n + 1 ))
      if [ -s "$sdir/$n.row" ]; then cat "$sdir/$n.row"; else row MISSING "smoke.${pair%%=*}" "${pair#*=} failed: no output" "check login, model access, quota / credit"; fi
      grep -q "^OK$tab" "$sdir/$n.row" 2>/dev/null || bad=1
    done
    rm -rf "$sdir"; exit $bad ;;
  models)
    [ $# -ge 2 ] || usage
    case "$2" in claude|codex|gemini|agy|opencode) ;; *) echo "preflight: unknown harness: $2" >&2; exit 2 ;; esac
    has "$2" || { echo "preflight: harness not installed: $2" >&2; exit 2; }
    list_models "$2" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' | grep -Ei -- "${3:-.}"
    exit $? ;;
  agents)
    agents_cmd "${2:-.}"; exit 0 ;;
  *) usage ;;
esac
