# smart-plan review: every deterministic step of a task review, so no model hand-writes the Jev questions,
# reads raw probabilities or applies thresholds. Costs no model tokens; only `gate` calls Jev (through jev.ps1).
# Windows-native twin of review.sh. Works on Windows PowerShell 5.1 (stock) and PowerShell 7+. Keep this file ASCII-only.
# Run from the repository root. <P> = task file prefix, e.g. .to-do/<plan>/tasks/P2.T1 (files are <P>.<suffix>).
#
#   review.ps1 prep    <P> <verify-command|-|none> [path ...]
#       Runs the verify command (one string, through cmd.exe /d /s /c), last 60 output lines -> P.verify. "-" or "none" =
#       no verify command (Windows PowerShell 5.1 rejects a bare "-" after -File: use "none" there).
#       Verify fails: prints verify=fail, exit=<code>, tail=P.verify; exit 1; no diff is built.
#       Else P.diff = git diff -- <paths> plus every untracked new file in the paths (no paths = whole
#       repository without .to-do). Env SP_DIFF_BASE=<ref>: git diff <ref>...HEAD -- <paths> instead.
#       Prints verify=pass|none and diff=<bytes>; exit 5 when the diff is empty. Starts a new round: removes
#       P.diff P.gate P.gate.txt P.jev.json P.review.md first.
#   review.ps1 gate    <P> <rubric>          rubric = comma list of backend, frontend, critical, none
#       Reads P.criteria (one "<id>: <full text>" per line; blank lines and # lines ignored), P.goal, P.diff,
#       P.verify and the optional P.questions.extra.json (one JSON object of extra questions: every id must
#       start with "x." and is a noul expected to be true). Writes P.questions.json, calls Jev (P.jev.json),
#       writes P.gate (id <tab> kind <tab> probability <tab> label; kind = done | gap | true | false) and
#       P.gate.txt. Prints gate=pass|fail|uncertain, then finding=<id>: <gap label> per failing id, then
#       disputed=<ids in the dead band> (fail and uncertain). Exit 0 for the three verdicts.
#       gate=too-large exit 3 (slice: one prefix per slice, then merge) - gate=no-key exit 4 -
#       gate=error http=<code> exit 1.
#   review.ps1 merge   <P> <sliceP> [<sliceP> ...]
#       Combines the slices' .gate files into P.gate by the meaning of the question, never by average:
#       done = best slice, true = worst slice, false = highest slice, gap = the slice with the best done.
#       Same verdict, printing and P.gate.txt as gate.
#   review.ps1 verdict <P> <reader-result-file>
#       Combines the reader's verdict with P.gate.txt (absent = gate off: the reader decides alone), writes
#       P.review.md (at most 12 lines), prints review=PASS|FAIL|ESCALATE (plus reason=... when the reader
#       gave no verdict).
#
# Env: SP_GATE_PASS (default 0.80) - SP_GATE_FAIL (default 0.35) - SP_DIFF_BASE - and those of jev.ps1:
#      TYPESAFE_API_KEY (never printed), SP_JEV_MODEL, SP_JEV_URL, SP_JEV_MAX_BYTES.
# Exit: 0 ok - 1 verify failed / call failed - 2 usage - 3 state too large - 4 no key - 5 empty diff.
# Git is only read (rev-parse, diff, ls-files). The verify command must not contain an unquoted ")".
$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$inv = [Globalization.CultureInfo]::InvariantCulture
$tab = [string][char]9
$ws = [char[]]@(32, 9, 10, 11, 12, 13)

function Die($m) { [Console]::Error.WriteLine("review: $m"); exit 2 }
function Usage {
  [Console]::Error.WriteLine('usage: review.ps1 prep    <P> <verify-command|-|none> [path ...]')
  [Console]::Error.WriteLine('       review.ps1 gate    <P> <rubric: backend,frontend,critical|none>')
  [Console]::Error.WriteLine('       review.ps1 merge   <P> <sliceP> [<sliceP> ...]')
  [Console]::Error.WriteLine('       review.ps1 verdict <P> <reader-result-file>')
  exit 2
}
function Full($p) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p) }
function IsFile($p) { Test-Path -LiteralPath $p -PathType Leaf }
function HasBytes($p) { if (IsFile $p) { return ((Get-Item -LiteralPath $p -Force).Length -gt 0) } return $false }
function WriteText($p, $t) { [IO.File]::WriteAllText((Full $p), $t, $utf8) }
function ReadLines($p) { return ,@(([IO.File]::ReadAllText((Full $p)) -replace "`r", '') -split "`n") }
function Drop($p) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } }
function MakeDirOf($p) {
  $d = Split-Path -Parent $p
  if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}
function ToNum($s) { $d = 0.0; if ([double]::TryParse([string]$s, [Globalization.NumberStyles]::Float, $inv, [ref]$d)) { return $d } return 0.0 }
function IsNum($v) { return ($v -is [double] -or $v -is [single] -or $v -is [decimal] -or $v -is [int] -or $v -is [long]) }
function IsProb($s) { return ($s -match '^(0|1|0?\.[0-9]+|1\.0+)$') }

$passT = $env:SP_GATE_PASS; if (-not $passT) { $passT = '0.80' }
$failT = $env:SP_GATE_FAIL; if (-not $failT) { $failT = '0.35' }

# Verdict lines from P.gate -> output and the first lines of P.gate.txt. gap lines never decide.
function Judge($pre) {
  if (-not (IsProb $passT)) { Die "SP_GATE_PASS must be a number between 0 and 1: $passT" }
  if (-not (IsProb $failT)) { Die "SP_GATE_FAIL must be a number between 0 and 1: $failT" }
  $PASS = ToNum $passT; $FAIL = ToNum $failT; $e = 0.000000001
  $gap = New-Object System.Collections.Hashtable
  $rows = New-Object System.Collections.ArrayList
  $gateLines = ReadLines "$pre.gate"
  foreach ($line in $gateLines) {
    $f = $line.Split([char]9)
    if ($f.Length -lt 3) { continue }
    if ($f[1] -ceq 'gap') { $lab = ''; if ($f.Length -gt 3) { $lab = $f[3] }; $gap[$f[0]] = $lab; continue }
    [void]$rows.Add($f)
  }
  $v = 'pass'; $find = @(); $dis = @()
  if ($rows.Count -eq 0) { $v = 'uncertain' }
  foreach ($f in $rows) {
    $p = ToNum $f[2]
    if ($f[1] -ceq 'false') { $ok = ($p -le 1 - $PASS + $e); $bad = ($p -gt 1 - $FAIL + $e) }
    else { $ok = ($p -ge $PASS - $e); $bad = ($p -lt $FAIL - $e) }
    if ($bad) {
      $v = 'fail'
      if ($f[1] -ceq 'done') {
        $c = $f[0] -creplace '\.done$', ''
        $g = [string]$gap["$c.gap"]
        if ($g -eq '' -or $g -ceq 'none' -or $g -eq '-') { $g = 'unspecified' }
        $find += ($c + ': ' + $g)
      } else { $find += ($f[0] + ': rubric') }
    } elseif (-not $ok) {
      if ($v -ceq 'pass') { $v = 'uncertain' }
      $dis += $f[0]
    }
  }
  $lines = @("gate=$v")
  if ($v -ceq 'fail') { foreach ($x in $find) { $lines += "finding=$x" } }
  if ($v -cne 'pass') { $lines += ('disputed=' + ($dis -join ',')) }
  $body = @($gateLines | Where-Object { $_ -ne '' })
  $all = $lines + @("thresholds=pass:$passT fail:$failT", ('id' + $tab + 'kind' + $tab + 'probability' + $tab + 'label')) + $body
  WriteText "$pre.gate.txt" (($all -join "`n") + "`n")
  foreach ($l in $lines) { Write-Output $l }
}

# ---------------------------------------------------------------- prep
function RunShell($cmd, $outFile) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.UseShellExecute = $false; $psi.RedirectStandardInput = $true
  $psi.WorkingDirectory = (Get-Location).ProviderPath
  if ($env:OS -eq 'Windows_NT') {
    $exe = $env:ComSpec; if (-not $exe) { $exe = 'cmd.exe' }
    $psi.FileName = $exe
    $psi.Arguments = '/d /s /c "( ' + $cmd + ' ) > "' + $outFile + '" 2>&1"'
  } else {
    $psi.FileName = '/bin/sh'
    $psi.ArgumentList.Add('-c')
    $psi.ArgumentList.Add('( ' + $cmd + " ) > '" + ($outFile -replace "'", "'\''") + "' 2>&1")
  }
  $proc = [Diagnostics.Process]::Start($psi)
  $proc.StandardInput.Close()
  $proc.WaitForExit()
  return $proc.ExitCode
}
function TailBytes($src, $dst, $n) {
  $b = [IO.File]::ReadAllBytes($src); $start = 0; $cnt = 0
  $i = $b.Length - 1
  if ($i -ge 0 -and $b[$i] -eq 10) { $i-- }
  for (; $i -ge 0; $i--) { if ($b[$i] -eq 10) { $cnt++; if ($cnt -eq $n) { $start = $i + 1; break } } }
  $fs = [IO.File]::Create($dst)
  try { $fs.Write($b, $start, $b.Length - $start) } finally { $fs.Close() }
}
function AppendFile($src, $dst) {
  $b = [IO.File]::ReadAllBytes($src)
  $fs = New-Object System.IO.FileStream($dst, [IO.FileMode]::Append)
  try { $fs.Write($b, 0, $b.Length) } finally { $fs.Close() }
}

function CmdPrep($a) {
  if ($a.Count -lt 2) { Usage }
  $pre = $a[0]; $vcmd = $a[1]
  $paths = @(); if ($a.Count -gt 2) { $paths = @($a[2..($a.Count - 1)]) }
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die 'git not installed' }
  & git rev-parse --is-inside-work-tree 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { Die 'not inside a git work tree (run from the repository root)' }
  MakeDirOf $pre
  foreach ($s in 'diff', 'gate', 'gate.txt', 'jev.json', 'review.md') { Drop "$pre.$s" }
  $vstate = 'none'
  if ($vcmd -ceq '-' -or $vcmd -ceq 'none') {
    WriteText "$pre.verify" "no verify command`n"
  } else {
    $tmp = Full "$pre.verify.tmp"
    $rc = RunShell $vcmd $tmp
    if (-not (IsFile $tmp)) { WriteText $tmp '' }
    TailBytes $tmp (Full "$pre.verify") 60
    Drop $tmp
    if ($rc -ne 0) { Write-Output 'verify=fail'; Write-Output "exit=$rc"; Write-Output "tail=$pre.verify"; exit 1 }
    $vstate = 'pass'
  }
  if ($paths.Count -gt 0) { $spec = $paths } else { $spec = @('.', ':(exclude).to-do') }
  $diff = Full "$pre.diff"; $tmp = Full "$pre.diff.tmp"
  $base = $env:SP_DIFF_BASE
  if ($base) {
    & git diff --no-color --no-ext-diff "--output=$diff" "$base...HEAD" -- @spec 2>$null
    if ($LASTEXITCODE -ne 0) { Drop $diff; Die "git diff failed: check SP_DIFF_BASE ($base) and the paths" }
  } else {
    & git diff --no-color --no-ext-diff "--output=$diff" -- @spec 2>$null
    if ($LASTEXITCODE -ne 0) { Drop $diff; Die 'git diff failed: check the paths' }
    # Workers never git add: a plain git diff misses new files. --no-index exits 1 when there is a difference.
    $pn = ($pre -replace '\\', '/') -creplace '^\./', ''
    $pdir = '.'; $k = $pn.LastIndexOf('/'); if ($k -gt 0) { $pdir = $pn.Substring(0, $k) }
    $old = $null
    try { $old = [Console]::OutputEncoding; [Console]::OutputEncoding = $utf8 } catch { }
    $list = @(& git -c core.quotepath=off ls-files --others --exclude-standard -- @spec 2>$null)
    try { if ($old) { [Console]::OutputEncoding = $old } } catch { }
    foreach ($f in $list) {
      $f = ([string]$f).TrimEnd("`r")
      if ($f -eq '' -or $f.StartsWith('"') -or $f.EndsWith('/')) { continue }
      if ($f.StartsWith('.to-do/', [StringComparison]::Ordinal) -or $f.StartsWith("$pdir/", [StringComparison]::Ordinal) -or $f.StartsWith("$pn.", [StringComparison]::Ordinal)) { continue }
      Drop $tmp
      & git diff --no-color --no-ext-diff --no-index "--output=$tmp" -- /dev/null $f 2>$null
      if (IsFile $tmp) { AppendFile $tmp $diff }
    }
    Drop $tmp
  }
  if (-not (IsFile $diff)) { WriteText $diff '' }
  $bytes = (Get-Item -LiteralPath $diff -Force).Length
  Write-Output "verify=$vstate"; Write-Output "diff=$bytes"
  if ($bytes -gt 0) { exit 0 }
  exit 5
}

# ---------------------------------------------------------------- gate
function JsonEsc($text) { # the inside of a JSON string
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $text.ToCharArray()) {
    $c = [int]$ch
    if ($ch -eq '\') { [void]$sb.Append('\\') }
    elseif ($ch -eq '"') { [void]$sb.Append('\"') }
    elseif ($c -eq 9) { [void]$sb.Append('\t') }
    elseif ($c -lt 32) { }
    else { [void]$sb.Append($ch) }
  }
  return $sb.ToString()
}
function RubricQ($id, $line) { return ('"' + $id + '": {"type": "noul", "instructions": "' + $line + '", "criteria": {"true": "yes", "false": "no"}}') }

function CmdGate($a) {
  if ($a.Count -ne 2) { Usage }
  $pre = $a[0]; $rubric = $a[1]
  $wantB = $false; $wantF = $false; $wantC = $false
  foreach ($r in ($rubric -split '[,\s]+')) {
    if ($r -eq '') { continue }
    if ($r -ceq 'backend') { $wantB = $true } elseif ($r -ceq 'frontend') { $wantF = $true } elseif ($r -ceq 'critical') { $wantC = $true }
    elseif ($r -cne 'none') { Die "unknown rubric: $r (backend, frontend, critical, none)" }
  }
  if (-not (HasBytes "$pre.criteria")) { Die "criteria file missing or empty: $pre.criteria" }
  foreach ($s in 'goal', 'diff', 'verify') { if (-not (IsFile "$pre.$s")) { Die "file not found: $pre.$s (run prep first; the orchestrator writes .goal)" } }
  if (-not (HasBytes "$pre.goal")) { Die "goal file is empty: $pre.goal" }
  $jev = Join-Path $PSScriptRoot 'jev.ps1'
  if (-not (IsFile $jev)) { Die 'jev.ps1 not found next to review.ps1' }
  foreach ($s in 'gate', 'gate.txt', 'jev.json') { Drop "$pre.$s" }
  $qf = "$pre.questions.json"

  $entries = @(); $ids = New-Object System.Collections.ArrayList
  $seen = New-Object System.Collections.Hashtable
  $ln = 0
  foreach ($raw in (ReadLines "$pre.criteria")) {
    $ln++
    $line = $raw.TrimStart($ws)
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    $k = $line.IndexOf(':')
    if ($k -lt 0) { Die "bad criteria line $ln (want '<id>: <full text>'): $line" }
    $id = $line.Substring(0, $k); $text = $line.Substring($k + 1).Trim($ws)
    if ($id -cnotmatch '^[A-Za-z0-9_-]+$') { Die "bad criterion id on line $ln (letters, digits, _ and - only): $id" }
    if ($text -eq '') { Die "criterion $id has no text (line $ln)" }
    $lc = $id.ToLowerInvariant()
    if ($seen.ContainsKey($lc)) { Die "criterion id used twice: $id" }
    $seen[$lc] = 1
    $esc = JsonEsc $text
    $entries += ('"' + $id + '.done": {"type": "noul", "instructions": {"criterion": "' + $esc + '", "question": ' +
      '"Does the executable code added or changed in `diff` fully implement `criterion`?"}, "criteria": {"true": "implemented by executable code and reachable", "false": "missing, partial, stubbed, unreachable, or only claimed in a comment, name or docstring"}}')
    $entries += ('"' + $id + '.gap": {"type": "choice", "instructions": {"criterion": "' + $esc + '", "question": ' +
      '"What is the main gap between the executable code in `diff` and `criterion`?"}, "criteria": {"none": "no gap", "missing": "not implemented", "partial": "some cases not handled", "stubbed": "placeholder, hardcoded or mocked logic", "not_wired": "code exists but is unreachable from the UI, route or entry point", "wrong_behaviour": "does something else than specified", "error_unhandled": "failure case not handled"}}')
    [void]$ids.Add(@("$id.done", 'done')); [void]$ids.Add(@("$id.gap", 'gap'))
  }
  if ($entries.Count -eq 0) { Die "no criterion found in $pre.criteria" }

  if ($wantB) {
    $entries += (RubricQ 'r.validation' 'every new input is validated before use')
    $entries += (RubricQ 'r.errors' 'every new failure path returns the project''s error shape')
    [void]$ids.Add(@('r.validation', 'true')); [void]$ids.Add(@('r.errors', 'true'))
  }
  if ($wantF) {
    $entries += (RubricQ 'r.real_api' 'the UI calls the real API, not mock data')
    $entries += (RubricQ 'r.states' 'loading, error and empty states are rendered')
    $entries += (RubricQ 'r.wired' 'the new UI is reachable from the existing navigation')
    [void]$ids.Add(@('r.real_api', 'true')); [void]$ids.Add(@('r.states', 'true')); [void]$ids.Add(@('r.wired', 'true'))
  }
  if ($wantC) {
    $entries += (RubricQ 'r.authz' 'every new endpoint or action checks authorization')
    $entries += (RubricQ 'r.secrets' 'the diff contains a secret, key or credential')
    [void]$ids.Add(@('r.authz', 'true')); [void]$ids.Add(@('r.secrets', 'false'))
  }
  $entries += (RubricQ 'r.regression' 'the diff changes existing behaviour outside the task''s criteria')
  [void]$ids.Add(@('r.regression', 'false'))

  # Extra questions of the orchestrator: a {...} object whose members are spliced in. Ids start with "x.".
  $xf = "$pre.questions.extra.json"
  if (IsFile $xf) {
    $xt = [IO.File]::ReadAllText((Full $xf)); $xo = $null; $bad = $false; $xids = @()
    try { $xo = ConvertFrom-Json -InputObject $xt -ErrorAction Stop } catch { $bad = $true }
    if (-not $bad -and -not ($xo -is [System.Management.Automation.PSCustomObject])) { $bad = $true }
    if (-not $bad) {
      foreach ($pr in $xo.PSObject.Properties) { if ($pr.Name -cnotmatch '^x\.[A-Za-z0-9_.-]+$') { $bad = $true } else { $xids += $pr.Name } }
    }
    if ($bad) { Die "$xf must be one JSON object whose ids all match x.[A-Za-z0-9_.-]+" }
    $i1 = $xt.IndexOf('{'); $i2 = $xt.LastIndexOf('}')
    if ($i1 -ge 0 -and $i2 -gt $i1 -and $xids.Count -gt 0) {
      $inner = ($xt.Substring($i1 + 1, $i2 - $i1 - 1) -replace "`r", '').Trim([char[]]@(32, 9, 10))
      if ($inner -ne '') { $entries += $inner; foreach ($x in $xids) { [void]$ids.Add(@($x, 'true')) } }
    }
  }
  WriteText $qf ('{' + "`n" + ($entries -join ",`n") + "`n}`n")

  $hostExe = (Get-Process -Id $PID).Path
  $out = @(& $hostExe -NoProfile -ExecutionPolicy Bypass -File $jev $qf "$pre.jev.json" "goal=$pre.goal" "diff=$pre.diff" "verify=$pre.verify")
  $rc = $LASTEXITCODE
  $code = '000'
  foreach ($l in $out) { if ([string]$l -match '^http=([0-9]+)') { $code = $Matches[1]; break } }
  if ($code -match '^0+$') { $code = '000' }
  if ($rc -eq 3) { Write-Output 'gate=too-large'; exit 3 }
  if ($rc -eq 4) { Write-Output 'gate=no-key'; exit 4 }
  if ($rc -ne 0) { Write-Output "gate=error http=$code"; exit 1 }

  $answers = $null
  try { $resp = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Full "$pre.jev.json"))) -ErrorAction Stop; $answers = $resp.answers } catch { $answers = $null }
  $gate = @(); $missing = @()
  foreach ($q in $ids) {
    $id = $q[0]; $kind = $q[1]; $p = $null; $lab = '-'; $x = $null
    if ($answers -is [System.Management.Automation.PSCustomObject]) { $pr = $answers.PSObject.Properties[$id]; if ($pr) { $x = $pr.Value } }
    if ($x -is [System.Management.Automation.PSCustomObject]) {
      if ($kind -ceq 'gap') {
        if (($x.choice -is [string]) -and (IsNum $x.confidence)) { $p = [double]$x.confidence; $lab = ($x.choice -replace '\s+', ' ') }
      } elseif (IsNum $x.noul) { $p = [double]$x.noul }
    }
    if ($null -eq $p) { $missing += $id; continue }
    $gate += ($id + $tab + $kind + $tab + $p.ToString('0.0000', $inv) + $tab + $lab)
  }
  if ($missing.Count -gt 0) {
    [Console]::Error.WriteLine("review: no usable answer in $pre.jev.json for: " + ($missing -join ' '))
    Write-Output "gate=error http=$code"; exit 1
  }
  WriteText "$pre.gate" (($gate -join "`n") + "`n")
  Judge $pre
  exit 0
}

# ---------------------------------------------------------------- merge
function CmdMerge($a) {
  if ($a.Count -lt 2) { Usage }
  $pre = $a[0]
  $slices = @($a[1..($a.Count - 1)])
  foreach ($s in $slices) { if (-not (HasBytes "$s.gate")) { Die "slice gate file missing or empty: $s.gate" } }
  MakeDirOf $pre
  $kind = New-Object System.Collections.Hashtable; $prob = New-Object System.Collections.Hashtable
  $rawv = New-Object System.Collections.Hashtable; $best = New-Object System.Collections.Hashtable
  $gp = New-Object System.Collections.Hashtable; $gl = New-Object System.Collections.Hashtable; $g1 = New-Object System.Collections.Hashtable
  $order = New-Object System.Collections.ArrayList
  $si = 0
  foreach ($s in $slices) {
    $si++
    foreach ($line in (ReadLines "$s.gate")) {
      $f = $line.Split([char]9)
      if ($f.Length -lt 3) { continue }
      $id = $f[0]; $p = ToNum $f[2]
      if (-not $kind.ContainsKey($id)) { [void]$order.Add($id); $kind[$id] = $f[1] }
      $k = $kind[$id]
      if ($k -ceq 'gap') {
        $lab = ''; if ($f.Length -gt 3) { $lab = $f[3] }
        $gp["$id$tab$si"] = $f[2]; $gl["$id$tab$si"] = $lab
        if (-not $g1.ContainsKey($id)) { $g1[$id] = $si }
        continue
      }
      if (-not $prob.ContainsKey($id)) { $prob[$id] = $p; $rawv[$id] = $f[2]; $best[$id] = $si }
      elseif ($k -ceq 'true') { if ($p -lt $prob[$id]) { $prob[$id] = $p; $rawv[$id] = $f[2]; $best[$id] = $si } }
      elseif ($p -gt $prob[$id]) { $prob[$id] = $p; $rawv[$id] = $f[2]; $best[$id] = $si }
    }
  }
  $res = @()
  foreach ($id in $order) {
    if ($kind[$id] -ceq 'gap') {
      $d = ($id -creplace '\.gap$', '') + '.done'
      if ($best.ContainsKey($d)) { $s0 = $best[$d] } else { $s0 = $g1[$id] }
      if (-not $gp.ContainsKey("$id$tab$s0")) { $s0 = $g1[$id] }
      $res += ($id + $tab + 'gap' + $tab + $gp["$id$tab$s0"] + $tab + $gl["$id$tab$s0"])
    } else { $res += ($id + $tab + $kind[$id] + $tab + $rawv[$id] + $tab + '-') }
  }
  WriteText "$pre.gate" (($res -join "`n") + "`n")
  Judge $pre
  exit 0
}

# ---------------------------------------------------------------- verdict
function CmdVerdict($a) {
  if ($a.Count -ne 2) { Usage }
  $pre = $a[0]; $rf = $a[1]
  if ($rf -ceq '-') { Die "every review has a reader: give the reader's result file" }
  if (-not (IsFile $rf)) { Die "reader result file not found: $rf" }
  $rl = ReadLines $rf
  $reader = 'none'; $unmet = @(); $defects = @(); $on = $false
  foreach ($l in $rl) {
    if ($reader -ceq 'none' -and $l -cmatch '^.*VERDICT:[ *_`]*(PASS|FAIL|ESCALATE)') { $reader = $Matches[1] }
    if ($l -cmatch '^[\s*-]*[A-Za-z][A-Za-z0-9_.-]*:\s*unmet') { $unmet += $l }
    if ($on) { if ($l -match '[^ \t]') { $defects += $l } }
    elseif ($l -cmatch '^[ \t*-]*DEFECTS:') { $on = $true; $defects += $l }
  }
  $concrete = $false
  if ($defects.Count -gt 0) {
    $first = (($defects[0] -creplace '^.*DEFECTS:[ *_`]*', '') -creplace '[ *_`.]*$', '').ToLowerInvariant()
    if ($first -ceq 'none') { $defects = @() }
    else { foreach ($l in $defects) { if (($l -creplace '^.*DEFECTS:', '') -match '\S+:[0-9]+') { $concrete = $true } } }
  }
  $gate = 'off'; $findings = @(); $disputed = ''
  if (IsFile "$pre.gate.txt") {
    $gate = ''
    foreach ($l in (ReadLines "$pre.gate.txt")) {
      if ($gate -eq '' -and $l -cmatch '^gate=(pass|fail|uncertain)$') { $gate = $Matches[1] }
      if ($l.StartsWith('finding=', [StringComparison]::Ordinal)) { $findings += $l }
      if ($disputed -eq '' -and $l.StartsWith('disputed=', [StringComparison]::Ordinal)) { $disputed = $l }
    }
    if ($gate -eq '') { $gate = 'uncertain' }
  }
  $reason = ''
  if ($reader -ceq 'none') { $result = 'ESCALATE'; $reason = 'reader gave no verdict' }
  elseif ($gate -ceq 'off') { $result = $reader }
  elseif ($reader -ceq 'PASS' -and $gate -ceq 'pass') { $result = 'PASS' }
  elseif ($reader -ceq 'FAIL' -and $gate -ceq 'fail') { $result = 'FAIL' }
  elseif ($reader -ceq 'FAIL' -and $concrete) { $result = 'FAIL' }
  else { $result = 'ESCALATE' }
  $md = @("RESULT: $result  (reader=$reader gate=$gate)")
  if ($reason) { $md += "reason: $reason" }
  $md += $unmet; $md += $defects; $md += $findings
  if ($result -ceq 'ESCALATE' -and $disputed -ne '') { $md += $disputed }
  if ($md.Count -gt 12) { $md = $md[0..11] }
  WriteText "$pre.review.md" (($md -join "`n") + "`n")
  Write-Output "review=$result"
  if ($reason) { Write-Output "reason=$reason" }
  exit 0
}

if ($args.Count -lt 1) { Usage }
$sub = [string]$args[0]
$rest = @(); if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)]) }
if ($sub -ceq 'prep') { CmdPrep $rest }
elseif ($sub -ceq 'gate') { CmdGate $rest }
elseif ($sub -ceq 'merge') { CmdMerge $rest }
elseif ($sub -ceq 'verdict') { CmdVerdict $rest }
else { Usage }
