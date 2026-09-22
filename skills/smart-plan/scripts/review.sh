#!/usr/bin/env bash
# smart-plan review: every deterministic step of a task review, so no model hand-writes the Jev questions,
# reads raw probabilities or applies thresholds. Costs no model tokens; only `gate` calls Jev (through jev.sh).
# POSIX shells: Linux, macOS (bash 3.2+), Git Bash, WSL. Windows without bash: use review.ps1. No jq; Node optional.
# Run from the repository root. <P> = task file prefix, e.g. .to-do/<plan>/tasks/P2.T1 (files are <P>.<suffix>).
#
#   review.sh prep    <P> <verify-command|-|none> [path ...]
#       Runs the verify command (one string, through bash -c), last 60 output lines -> P.verify. "-" or "none" = no
#       verify command (Windows PowerShell 5.1 rejects a bare "-" after -File: use "none" there).
#       Verify fails: prints verify=fail, exit=<code>, tail=P.verify; exit 1; no diff is built.
#       Else P.diff = git diff -- <paths> plus every untracked new file in the paths (no paths = whole
#       repository without .to-do). Env SP_DIFF_BASE=<ref>: git diff <ref>...HEAD -- <paths> instead.
#       Prints verify=pass|none and diff=<bytes>; exit 5 when the diff is empty. Starts a new round: removes
#       P.diff P.gate P.gate.txt P.jev.json P.review.md first.
#   review.sh gate    <P> <rubric>          rubric = comma list of backend, frontend, critical, none
#       Reads P.criteria (one "<id>: <full text>" per line; blank lines and # lines ignored), P.goal, P.diff,
#       P.verify and the optional P.questions.extra.json (one JSON object of extra questions: every id must
#       start with "x." and is a noul expected to be true). Writes P.questions.json, calls Jev (P.jev.json),
#       writes P.gate (id <tab> kind <tab> probability <tab> label; kind = done | gap | true | false) and
#       P.gate.txt. Prints gate=pass|fail|uncertain, then finding=<id>: <gap label> per failing id, then
#       disputed=<ids in the dead band> (fail and uncertain). Exit 0 for the three verdicts.
#       gate=too-large exit 3 (slice: one prefix per slice, then merge) - gate=no-key exit 4 -
#       gate=error http=<code> exit 1.
#   review.sh merge   <P> <sliceP> [<sliceP> ...]
#       Combines the slices' .gate files into P.gate by the meaning of the question, never by average:
#       done = best slice, true = worst slice, false = highest slice, gap = the slice with the best done.
#       Same verdict, printing and P.gate.txt as gate.
#   review.sh verdict <P> <reader-result-file>
#       Combines the reader's verdict with P.gate.txt (absent = gate off: the reader decides alone), writes
#       P.review.md (at most 12 lines), prints review=PASS|FAIL|ESCALATE (plus reason=... when the reader
#       gave no verdict).
#
# Env: SP_GATE_PASS (default 0.80) - SP_GATE_FAIL (default 0.35) - SP_DIFF_BASE - and those of jev.sh:
#      TYPESAFE_API_KEY (never printed), SP_JEV_MODEL, SP_JEV_URL, SP_JEV_MAX_BYTES.
# Exit: 0 ok - 1 verify failed / call failed - 2 usage - 3 state too large - 4 no key - 5 empty diff.
# Git is only read (rev-parse, diff, ls-files).
set -u

here=$(cd "$(dirname "$0")" && pwd)
tab=$(printf '\t')
die() { echo "review: $*" >&2; exit 2; }
usage() {
  cat >&2 <<'EOF'
usage: review.sh prep    <P> <verify-command|-|none> [path ...]
       review.sh gate    <P> <rubric: backend,frontend,critical|none>
       review.sh merge   <P> <sliceP> [<sliceP> ...]
       review.sh verdict <P> <reader-result-file>
EOF
  exit 2
}

pass_t=${SP_GATE_PASS:-0.80}; fail_t=${SP_GATE_FAIL:-0.35}
is_prob() { printf '%s' "$1" | grep -Eq '^(0|1|0?\.[0-9]+|1\.0+)$'; }

# Verdict lines from P.gate -> stdout and the first lines of P.gate.txt. gap lines never decide.
judge() { # <P>
  is_prob "$pass_t" || die "SP_GATE_PASS must be a number between 0 and 1: $pass_t"
  is_prob "$fail_t" || die "SP_GATE_FAIL must be a number between 0 and 1: $fail_t"
  lines=$(LC_ALL=C awk -F "$tab" -v PASS="$pass_t" -v FAIL="$fail_t" '
    { sub(/\r$/, "") }
    NF < 3 { next }
    $2 == "gap" { gap[$1] = $4; next }
    { n++; id[n] = $1; kd[n] = $2; pr[n] = $3 + 0 }
    END {
      e = 0.000000001; v = "pass"; nf = 0; dis = ""
      if (n == 0) v = "uncertain"
      for (i = 1; i <= n; i++) {
        if (kd[i] == "false") { ok = (pr[i] <= 1 - PASS + e); bad = (pr[i] > 1 - FAIL + e) }
        else { ok = (pr[i] >= PASS - e); bad = (pr[i] < FAIL - e) }
        if (bad) {
          v = "fail"
          if (kd[i] == "done") {
            c = id[i]; sub(/\.done$/, "", c); g = gap[c ".gap"]
            if (g == "" || g == "none" || g == "-") g = "unspecified"
            find[++nf] = c ": " g
          } else find[++nf] = id[i] ": rubric"
        } else if (!ok) {
          if (v == "pass") v = "uncertain"
          dis = dis (dis == "" ? "" : ",") id[i]
        }
      }
      print "gate=" v
      if (v == "fail") for (i = 1; i <= nf; i++) print "finding=" find[i]
      if (v != "pass") print "disputed=" dis
    }' "$1.gate")
  { printf '%s\n' "$lines"; echo "thresholds=pass:$pass_t fail:$fail_t"; echo "id${tab}kind${tab}probability${tab}label"; tr -d '\r' < "$1.gate"; } > "$1.gate.txt"
  printf '%s\n' "$lines"
}

# ---------------------------------------------------------------- prep
cmd_prep() {
  [ $# -ge 2 ] || usage
  P=$1; vcmd=$2; shift 2
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree (run from the repository root)"
  mkdir -p "$(dirname "$P")"
  rm -f "$P.diff" "$P.gate" "$P.gate.txt" "$P.jev.json" "$P.review.md"
  vstate=none
  if [ "$vcmd" = "-" ] || [ "$vcmd" = none ]; then
    echo "no verify command" > "$P.verify"
  else
    bash -c "$vcmd" > "$P.verify.tmp" 2>&1 < /dev/null; rc=$?
    tail -n 60 "$P.verify.tmp" > "$P.verify"; rm -f "$P.verify.tmp"
    if [ "$rc" -ne 0 ]; then echo "verify=fail"; echo "exit=$rc"; echo "tail=$P.verify"; exit 1; fi
    vstate=pass
  fi
  if [ $# -gt 0 ]; then spec=("$@"); else spec=(. ':(exclude).to-do'); fi
  base=${SP_DIFF_BASE:-}
  if [ -n "$base" ]; then
    git diff --no-color --no-ext-diff "$base...HEAD" -- "${spec[@]}" > "$P.diff" 2>/dev/null || { rm -f "$P.diff"; die "git diff failed: check SP_DIFF_BASE ($base) and the paths"; }
  else
    git diff --no-color --no-ext-diff -- "${spec[@]}" > "$P.diff" 2>/dev/null || { rm -f "$P.diff"; die "git diff failed: check the paths"; }
    # Workers never git add: a plain git diff misses new files. --no-index exits 1 when there is a difference.
    pdir=$(dirname "$P"); pdir=${pdir#./}; pown=${P#./}
    git -c core.quotepath=off ls-files --others --exclude-standard -- "${spec[@]}" > "$P.diff.tmp" 2>/dev/null
    while IFS= read -r f || [ -n "$f" ]; do
      f=${f%$'\r'}
      case "$f" in ''|'"'*|*/|.to-do/*|"$pdir"/*|"$pown".*) continue ;; esac
      git diff --no-color --no-ext-diff --no-index -- /dev/null "$f" >> "$P.diff" 2>/dev/null
    done < "$P.diff.tmp"
    rm -f "$P.diff.tmp"
  fi
  bytes=$(wc -c < "$P.diff" | tr -d ' ')
  echo "verify=$vstate"; echo "diff=$bytes"
  [ "$bytes" -gt 0 ] || exit 5
  exit 0
}

# ---------------------------------------------------------------- gate
json_esc() { # <text> : the inside of a JSON string
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\012-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$tab/\\\\t/g"
}
rubric_q() { # <id> <line>
  printf ',\n"%s": {"type": "noul", "instructions": "%s", "criteria": {"true": "yes", "false": "no"}}' "$1" "$2" >> "$qf"
}

# One line per expected id: id <tab> kind <tab> raw probability | MISSING <tab> label
parse_answers() { # <ids file> <response file>
  if command -v node >/dev/null 2>&1; then
    node -e 'const fs=require("fs");const a1=process.argv[1],a2=process.argv[2];let a={};try{const o=JSON.parse(fs.readFileSync(a2,"utf8").replace(/^\s+/,""));if(o&&o.answers&&typeof o.answers==="object")a=o.answers}catch(e){}for(const l of fs.readFileSync(a1,"utf8").split("\n")){if(!l)continue;const t=l.split("\t");const x=a[t[0]];let p="MISSING",lab="-";if(x&&typeof x==="object"){if(t[1]==="gap"){if(typeof x.choice==="string"&&typeof x.confidence==="number"){p=x.confidence;lab=x.choice.replace(/\s+/g," ")}}else if(typeof x.noul==="number")p=x.noul}console.log([t[0],t[1],p,lab].join("\t"))}' "$1" "$2"
  else
    flat=$(tr -d '\r\n' < "$2")
    num='-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?'
    while IFS="$tab" read -r id kind; do
      [ -n "$id" ] || continue
      rx=$(printf '%s' "$id" | sed 's/\./\\./g')
      blk=$(printf '%s' "$flat" | grep -oE "\"$rx\"[[:space:]]*:[[:space:]]*\{[^{}]*(\{[^{}]*\}[^{}]*)*\}" | head -1)
      p=MISSING; lab=-
      if [ "$kind" = gap ]; then
        c=$(printf '%s' "$blk" | grep -oE '"choice"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -e 's/^"choice"[[:space:]]*:[[:space:]]*"//' -e 's/"$//')
        v=$(printf '%s' "$blk" | grep -oE "\"confidence\"[[:space:]]*:[[:space:]]*$num" | head -1 | sed 's/^.*:[[:space:]]*//')
        if [ -n "$c" ] && [ -n "$v" ]; then p=$v; lab=$c; fi
      else
        v=$(printf '%s' "$blk" | grep -oE "\"noul\"[[:space:]]*:[[:space:]]*$num" | head -1 | sed 's/^.*:[[:space:]]*//')
        [ -n "$v" ] && p=$v
      fi
      printf '%s\t%s\t%s\t%s\n' "$id" "$kind" "$p" "$lab"
    done < "$1"
  fi
}

cmd_gate() {
  [ $# -eq 2 ] || usage
  P=$1; rubric=$2
  want_b=0; want_f=0; want_c=0
  for r in $(printf '%s' "$rubric" | tr ',' ' '); do
    case "$r" in backend) want_b=1 ;; frontend) want_f=1 ;; critical) want_c=1 ;; none) ;; *) die "unknown rubric: $r (backend, frontend, critical, none)" ;; esac
  done
  [ -s "$P.criteria" ] || die "criteria file missing or empty: $P.criteria"
  for s in goal diff verify; do [ -f "$P.$s" ] || die "file not found: $P.$s (run prep first; the orchestrator writes .goal)"; done
  [ -s "$P.goal" ] || die "goal file is empty: $P.goal"
  [ -f "$here/jev.sh" ] || die "jev.sh not found next to review.sh"
  rm -f "$P.gate" "$P.gate.txt" "$P.jev.json"
  qf="$P.questions.json"; idf="$P.gate.ids"
  : > "$idf"; printf '{' > "$qf"

  bom=$(printf '\357\273\277'); seen=" "; nc=0; ln=0
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1)); line=${line%$'\r'}
    [ "$ln" -eq 1 ] && line=${line#"$bom"}
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *:*) ;; *) die "bad criteria line $ln (want '<id>: <full text>'): $line" ;; esac
    id=${line%%:*}; text=${line#*:}
    text="${text#"${text%%[![:space:]]*}"}"; text="${text%"${text##*[![:space:]]}"}"
    case "$id" in ''|*[!A-Za-z0-9_-]*) die "bad criterion id on line $ln (letters, digits, _ and - only): $id" ;; esac
    [ -n "$text" ] || die "criterion $id has no text (line $ln)"
    lc=$(printf '%s' "$id" | tr 'A-Z' 'a-z')
    case "$seen" in *" $lc "*) die "criterion id used twice: $id" ;; esac
    seen="$seen$lc "
    esc=$(json_esc "$text")
    [ "$nc" -eq 0 ] || printf ',' >> "$qf"
    nc=$((nc + 1))
    {
      printf '\n"%s.done": {"type": "noul", "instructions": {"criterion": "%s", "question": ' "$id" "$esc"
      printf '%s' '"Does the executable code added or changed in `diff` fully implement `criterion`?"}, "criteria": {"true": "implemented by executable code and reachable", "false": "missing, partial, stubbed, unreachable, or only claimed in a comment, name or docstring"}},'
      printf '\n"%s.gap": {"type": "choice", "instructions": {"criterion": "%s", "question": ' "$id" "$esc"
      printf '%s' '"What is the main gap between the executable code in `diff` and `criterion`?"}, "criteria": {"none": "no gap", "missing": "not implemented", "partial": "some cases not handled", "stubbed": "placeholder, hardcoded or mocked logic", "not_wired": "code exists but is unreachable from the UI, route or entry point", "wrong_behaviour": "does something else than specified", "error_unhandled": "failure case not handled"}}'
    } >> "$qf"
    printf '%s.done\tdone\n%s.gap\tgap\n' "$id" "$id" >> "$idf"
  done < "$P.criteria"
  [ "$nc" -gt 0 ] || { rm -f "$idf" "$qf"; die "no criterion found in $P.criteria"; }

  if [ "$want_b" -eq 1 ]; then
    rubric_q r.validation "every new input is validated before use"
    rubric_q r.errors "every new failure path returns the project's error shape"
    printf 'r.validation\ttrue\nr.errors\ttrue\n' >> "$idf"
  fi
  if [ "$want_f" -eq 1 ]; then
    rubric_q r.real_api "the UI calls the real API, not mock data"
    rubric_q r.states "loading, error and empty states are rendered"
    rubric_q r.wired "the new UI is reachable from the existing navigation"
    printf 'r.real_api\ttrue\nr.states\ttrue\nr.wired\ttrue\n' >> "$idf"
  fi
  if [ "$want_c" -eq 1 ]; then
    rubric_q r.authz "every new endpoint or action checks authorization"
    rubric_q r.secrets "the diff contains a secret, key or credential"
    printf 'r.authz\ttrue\nr.secrets\tfalse\n' >> "$idf"
  fi
  rubric_q r.regression "the diff changes existing behaviour outside the task's criteria"
  printf 'r.regression\tfalse\n' >> "$idf"

  # Extra questions of the orchestrator: a {...} object whose members are spliced in. Ids start with "x.".
  xf="$P.questions.extra.json"
  if [ -f "$xf" ]; then
    if command -v node >/dev/null 2>&1; then
      xids=$(node -e 'const fs=require("fs");try{const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8").replace(/^\s+/,""));if(!o||typeof o!=="object"||Array.isArray(o))throw 0;for(const k of Object.keys(o)){if(!/^x\.[A-Za-z0-9_.-]+$/.test(k))throw 0;console.log(k)}}catch(e){process.exit(1)}' "$xf") ||
        { rm -f "$idf"; die "$xf must be one JSON object whose ids all match x.[A-Za-z0-9_.-]+"; }
    else
      xids=$(tr -d '\r\n' < "$xf" | grep -oE '"x\.[A-Za-z0-9_.-]+"[[:space:]]*:[[:space:]]*\{' | sed -e 's/^"//' -e 's/".*$//')
    fi
    inner=$(LC_ALL=C awk '{ sub(/\r$/, ""); s = s $0 "\n" } END { a = index(s, "{"); b = 0; for (i = length(s); i > 0; i--) if (substr(s, i, 1) == "}") { b = i; break }
      if (a && b > a) { t = substr(s, a + 1, b - a - 1); gsub(/^[ \t\n]+|[ \t\n]+$/, "", t); printf "%s", t } }' "$xf")
    if [ -n "$inner" ] && [ -n "$xids" ]; then
      printf ',\n%s' "$inner" >> "$qf"
      for x in $xids; do printf '%s\ttrue\n' "$x" >> "$idf"; done
    fi
  fi
  printf '\n}\n' >> "$qf"

  out=$(bash "$here/jev.sh" "$qf" "$P.jev.json" "goal=$P.goal" "diff=$P.diff" "verify=$P.verify"); rc=$?
  code=$(printf '%s\n' "$out" | sed -n 's/^http=\([0-9][0-9]*\).*$/\1/p' | head -1)
  case "${code:-0}" in 0|00|000) code=000 ;; esac
  case "$rc" in
    0) ;;
    3) rm -f "$idf"; echo "gate=too-large"; exit 3 ;;
    4) rm -f "$idf"; echo "gate=no-key"; exit 4 ;;
    *) rm -f "$idf"; echo "gate=error http=$code"; exit 1 ;;
  esac

  parse_answers "$idf" "$P.jev.json" > "$P.gate.raw"
  rm -f "$idf"
  missing=$(LC_ALL=C awk -F "$tab" '$3 == "MISSING" { printf "%s ", $1 }' "$P.gate.raw")
  if [ -n "$missing" ]; then
    rm -f "$P.gate.raw"
    echo "review: no usable answer in $P.jev.json for: $missing" >&2
    echo "gate=error http=$code"; exit 1
  fi
  LC_ALL=C awk -F "$tab" '{ printf "%s\t%s\t%.4f\t%s\n", $1, $2, $3, $4 }' "$P.gate.raw" > "$P.gate"
  rm -f "$P.gate.raw"
  judge "$P"
  exit 0
}

# ---------------------------------------------------------------- merge
cmd_merge() {
  [ $# -ge 2 ] || usage
  P=$1; shift
  files=()
  for s in "$@"; do [ -s "$s.gate" ] || die "slice gate file missing or empty: $s.gate"; files+=("$s.gate"); done
  mkdir -p "$(dirname "$P")"
  LC_ALL=C awk -F "$tab" '
    FNR == 1 { s++ }
    { sub(/\r$/, "") }
    NF < 3 { next }
    { id = $1; k = $2; p = $3 + 0
      if (!(id in kind)) { order[++n] = id; kind[id] = k }
      k = kind[id]
      if (k == "gap") { gp[id, s] = $3; gl[id, s] = $4; if (!(id in g1)) g1[id] = s; next }
      if (!(id in prob)) { prob[id] = p; raw[id] = $3; best[id] = s }
      else if (k == "true") { if (p < prob[id]) { prob[id] = p; raw[id] = $3; best[id] = s } }
      else if (p > prob[id]) { prob[id] = p; raw[id] = $3; best[id] = s }
    }
    END {
      for (i = 1; i <= n; i++) {
        id = order[i]
        if (kind[id] == "gap") {
          d = id; sub(/\.gap$/, "", d); d = d ".done"
          s0 = (d in best) ? best[d] : g1[id]
          if (!((id, s0) in gp)) s0 = g1[id]
          printf "%s\tgap\t%s\t%s\n", id, gp[id, s0], gl[id, s0]
        } else printf "%s\t%s\t%s\t-\n", id, kind[id], raw[id]
      }
    }' "${files[@]}" > "$P.gate.tmp"
  mv -f "$P.gate.tmp" "$P.gate"
  judge "$P"
  exit 0
}

# ---------------------------------------------------------------- verdict
cmd_verdict() {
  [ $# -eq 2 ] || usage
  P=$1; rf=$2
  [ "$rf" != "-" ] || die "every review has a reader: give the reader's result file"
  [ -f "$rf" ] || die "reader result file not found: $rf"
  reader=$(tr -d '\r' < "$rf" | grep -E 'VERDICT:[ *_`]*(PASS|FAIL|ESCALATE)' | head -1 | sed -E 's/^.*VERDICT:[ *_`]*(PASS|FAIL|ESCALATE).*$/\1/')
  [ -n "$reader" ] || reader=none
  unmet=$(tr -d '\r' < "$rf" | grep -E '^[[:space:]*-]*[A-Za-z][A-Za-z0-9_.-]*:[[:space:]]*unmet')
  defects=$(tr -d '\r' < "$rf" | LC_ALL=C awk 'on && /[^ \t]/ { print } !on && /^[ \t*-]*DEFECTS:/ { on = 1; print }')
  concrete=0
  if [ -n "$defects" ]; then
    first=$(printf '%s\n' "$defects" | head -1 | sed -e 's/^.*DEFECTS:[ *_`]*//' -e 's/[ *_`.]*$//' | tr 'A-Z' 'a-z')
    if [ "$first" = none ]; then defects=""
    elif printf '%s\n' "$defects" | sed 's/^.*DEFECTS://' | grep -Eq '[^[:space:]]+:[0-9]+'; then concrete=1; fi
  fi
  gate=off; findings=""; disputed=""
  if [ -f "$P.gate.txt" ]; then
    gate=$(tr -d '\r' < "$P.gate.txt" | grep -E '^gate=(pass|fail|uncertain)$' | head -1 | sed 's/^gate=//')
    [ -n "$gate" ] || gate=uncertain
    findings=$(tr -d '\r' < "$P.gate.txt" | grep '^finding=')
    disputed=$(tr -d '\r' < "$P.gate.txt" | grep '^disputed=' | head -1)
  fi
  reason=""
  if [ "$reader" = none ]; then result=ESCALATE; reason="reader gave no verdict"
  elif [ "$gate" = off ]; then result=$reader
  elif [ "$reader" = PASS ] && [ "$gate" = pass ]; then result=PASS
  elif [ "$reader" = FAIL ] && [ "$gate" = fail ]; then result=FAIL
  elif [ "$reader" = FAIL ] && [ "$concrete" -eq 1 ]; then result=FAIL
  else result=ESCALATE; fi
  {
    echo "RESULT: $result  (reader=$reader gate=$gate)"
    [ -z "$reason" ] || echo "reason: $reason"
    [ -z "$unmet" ] || printf '%s\n' "$unmet"
    [ -z "$defects" ] || printf '%s\n' "$defects"
    [ -z "$findings" ] || printf '%s\n' "$findings"
    if [ "$result" = ESCALATE ] && [ -n "$disputed" ]; then echo "$disputed"; fi
  } | head -12 > "$P.review.md"
  echo "review=$result"
  [ -z "$reason" ] || echo "reason=$reason"
  exit 0
}

sub=${1:-}; [ $# -gt 0 ] && shift
case "$sub" in
  prep) cmd_prep "$@" ;;
  gate) cmd_gate "$@" ;;
  merge) cmd_merge "$@" ;;
  verdict) cmd_verdict "$@" ;;
  *) usage ;;
esac
