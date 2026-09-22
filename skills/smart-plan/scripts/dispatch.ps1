# smart-plan dispatch: run ONE worker headlessly. Windows-native twin of dispatch.sh.
# Works on Windows PowerShell 5.1 (stock) and PowerShell 7+. Keep this file ASCII-only.
#
# Usage: dispatch.ps1 <harness> <model> <write|read> <repo> <brief> <result> [timeoutSec] [session]
#   harness : claude | codex | gemini | agy | opencode
#   brief   : file piped to the worker on stdin (with [session]: the follow-up message)
#   result  : file that will hold the worker's final message
# Optional env: SP_CODEGRAPH=<binary>  code-graph tool read-only claude workers may run (default codebase-memory-mcp)
# Optional env: SP_ALLOW='Bash(npm test *)'  extra tool rule for claude workers (verify command)
# Optional env: SP_TASK='P2.T1 backend'  label shown on the status board (default: result file name)
# Optional env: SP_DETACH=1  start the worker detached, print started=<status file> and return at once;
#                            collect it with: status.ps1 wait <maxSec> <result>...
# Live state: <result>.status (key=value lines, read by status.sh / status.ps1); raw events: <result>.events
# Prints 3 lines: exit=<code>  session=<id>  result=<worker|captured|missing>. Exit 124 = timeout.
# Never adds permission-bypass or sandbox-bypass flags.
param(
  [Parameter(Mandatory=$true, Position=0)][ValidateSet('claude','codex','gemini','agy','opencode')][string]$Harness,
  [Parameter(Mandatory=$true, Position=1)][string]$Model,
  [Parameter(Mandatory=$true, Position=2)][ValidateSet('write','read')][string]$Mode,
  [Parameter(Mandatory=$true, Position=3)][string]$Repo,
  [Parameter(Mandatory=$true, Position=4)][string]$Brief,
  [Parameter(Mandatory=$true, Position=5)][string]$Result,
  [Parameter(Position=6)][int]$TimeoutSec = 1800,
  [Parameter(Position=7)][string]$Session = ''
)
$ErrorActionPreference = 'Stop'

function Fail($m) { [Console]::Error.WriteLine("dispatch: $m"); exit 2 }
function Abs($p) { [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).Path, $p)) }
# Quote one argument for a cmd.exe command line. cmd.exe does not honour \" : a double quote inside an
# argument would end the quoting and expose & | < > to cmd, so such an argument is refused.
function Q($a) {
  if ("$a".Contains('"')) { Fail "argument contains a double quote, refused: $a" }
  if ($a -match '[\s()&|<>^*]') { '"' + $a + '"' } else { $a }
}

# Refuse a double quote before anything is started or written (a detached child would fail silently).
foreach ($v in @($Model, $Repo, $Brief, $Result, $Session, $env:SP_ALLOW, $env:SP_CODEGRAPH)) {
  if ($v -and "$v".Contains('"')) { Fail "argument contains a double quote, refused: $v" }
}
$Brief = Abs $Brief; $Result = Abs $Result; $Repo = Abs $Repo
if ($Repo.Length -gt 3) { $Repo = $Repo.TrimEnd('\') }   # a trailing backslash would escape the closing quote
if (-not (Test-Path -LiteralPath $Brief -PathType Leaf)) { Fail "brief not found: $Brief" }
if (-not (Test-Path -LiteralPath $Repo -PathType Container)) { Fail "repo not found: $Repo" }
if (-not (Get-Command $Harness -ErrorAction SilentlyContinue)) { Fail "harness not installed: $Harness" }
$dir = Split-Path -Parent $Result
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$events = "$Result.events"; $errf = "$Result.stderr"; $status = "$Result.status"
$started = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

function Write-Status($state, $rc, $sid, $res) {
  $task = $env:SP_TASK; if (-not $task) { $task = Split-Path -Leaf $Result }
  $l = @("task=$task", "harness=$Harness", "model=$Model", "mode=$Mode", "started=$started", "timeout=$TimeoutSec", "state=$state")
  if ($state -ne 'running') { $l += @("ended=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())", "exit=$rc", "session=$sid", "result=$res") }
  $text = ($l -join "`n") + "`n"
  # A board may be reading the file: retry instead of failing the dispatch.
  for ($i = 0; $i -lt 5; $i++) {
    try { [IO.File]::WriteAllText($status, $text, (New-Object Text.UTF8Encoding($false))); break } catch { Start-Sleep -Milliseconds 200 }
  }
}

# Detached start: the parent marks the task running (so a wait never reads an older round) and returns.
if ($env:SP_DETACH) {
  Write-Status 'running'
  $env:SP_DETACH = ''
  $shell = (Get-Process -Id $PID).Path
  $al = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, $Harness, $Model, $Mode, $Repo, $Brief, $Result, "$TimeoutSec")
  if ($Session) { $al += $Session }
  Start-Process -FilePath $shell -ArgumentList (($al | ForEach-Object { Q $_ }) -join ' ') -WindowStyle Hidden | Out-Null
  Write-Output "started=$status"; exit 0
}
$before = ''
if (Test-Path -LiteralPath $Result) { $before = (Get-FileHash -LiteralPath $Result).Hash }

$a = @()
switch ($Harness) {
  'claude' {
    $a = @('claude', '-p', '--model', $Model, '--output-format', 'stream-json', '--verbose')
    if ($Session) { $a += @('--resume', $Session) }
    if ($Mode -eq 'write') {
      $a += @('--permission-mode', 'acceptEdits')
      if ($env:SP_ALLOW) { $a += @('--allowedTools', $env:SP_ALLOW) }
    } else {
      $cg = $env:SP_CODEGRAPH; if (-not $cg) { $cg = 'codebase-memory-mcp' }
      $a += @('--permission-mode', 'dontAsk', '--allowedTools', 'Read', 'Grep', 'Glob', 'Bash(git diff *)', 'Bash(git status *)', ('Bash(' + $cg + ' *)'))
      if ($env:SP_ALLOW) { $a += $env:SP_ALLOW }
    }
  }
  'codex' {
    $sb = 'read-only'; if ($Mode -eq 'write') { $sb = 'workspace-write' }
    # "codex exec resume" has no -s flag: without the config override a resumed session runs under the
    # config.toml default sandbox. The value is not valid TOML, so codex takes it as a literal string.
    if ($Session) { $a = @('codex', 'exec', 'resume', $Session, '-m', $Model, '-c', "sandbox_mode=$sb") }
    else { $a = @('codex', 'exec', '-m', $Model, '-C', $Repo, '-s', $sb) }
    $inGit = $false
    if (Get-Command git -ErrorAction SilentlyContinue) {
      try { & git -C $Repo rev-parse --is-inside-work-tree 2>$null | Out-Null; $inGit = ($LASTEXITCODE -eq 0) } catch { $inGit = $false }
    }
    if (-not $inGit) { $a += '--skip-git-repo-check' }
    $a += @('--json', '-o', $Result, '-')
  }
  'gemini' {
    $am = 'default'; if ($Mode -eq 'write') { $am = 'auto_edit' }
    $a = @('gemini', '-m', $Model, '--approval-mode', $am, '-o', 'json')
    if ($Session) { $a += @('-r', $Session) }
    $a += @('-p', 'Execute the task brief provided on stdin.')
  }
  'agy' {
    # agy does not read the prompt from stdin: pass the brief by path.
    # It also resolves relative paths next to the brief unless told where the repository is.
    # In print mode it loads the repository's AGENTS.md / GEMINI.md only when the repository is passed with --add-dir.
    $am = 'plan'; if ($Mode -eq 'write') { $am = 'accept-edits' }
    $a = @('agy', '-p', "Read the task brief at this path and execute it exactly: $Brief - relative paths in the brief start at the repository root: $Repo", '--mode', $am, '--add-dir', $Repo, '--output-format', 'stream-json', '--print-timeout', "$($TimeoutSec)s")
    if ($Model -ne 'auto') { $a += @('--model', $Model) }
    if ($Session) { $a += @('--conversation', $Session) }
  }
  'opencode' {
    $a = @('opencode', 'run', '-m', $Model, '--dir', $Repo, '--format', 'json')
    if ($Mode -eq 'write') { $a += '--auto' }
    if ($Session) { $a += @('-s', $Session) }
  }
}

# cmd.exe does the redirection so the brief reaches the worker byte-exact (no PowerShell re-encoding).
Write-Status 'running'
$line = (($a | ForEach-Object { Q $_ }) -join ' ') + ' < ' + (Q $Brief) + ' > ' + (Q $events) + ' 2> ' + (Q $errf)
$p = Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /s /c "' + $line + '"') -WorkingDirectory $Repo -NoNewWindow -PassThru
$null = $p.Handle   # keeps ExitCode readable after exit
if ($p.WaitForExit($TimeoutSec * 1000)) { $rc = $p.ExitCode }
else { & taskkill.exe /PID $p.Id /T /F 2>$null | Out-Null; $rc = 124 }

# Last string value of a JSON key, from a JSON document or JSON-lines file.
function Find-Last($node, $key) {
  $found = $null
  if ($node -is [System.Collections.IEnumerable] -and $node -isnot [string]) {
    foreach ($i in $node) { $r = Find-Last $i $key; if ($r) { $found = $r } }
  } elseif ($node -is [psobject] -and $node.PSObject.Properties) {
    foreach ($prop in $node.PSObject.Properties) {
      if ($prop.Name -eq $key -and $prop.Value -is [string]) { if ($prop.Value) { $found = $prop.Value } }
      elseif ($null -ne $prop.Value -and $prop.Value -isnot [string] -and $prop.Value -isnot [ValueType]) {
        $r = Find-Last $prop.Value $key; if ($r) { $found = $r }
      }
    }
  }
  return $found
}
function Json-Last($key, $file) {
  if (-not (Test-Path -LiteralPath $file)) { return '' }
  $raw = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
  $docs = @()
  try { $docs = @($raw | ConvertFrom-Json) } catch {
    foreach ($l in ($raw -split "`r?`n")) { if ($l.Trim()) { try { $docs += ($l | ConvertFrom-Json) } catch { } } }
  }
  $out = ''
  foreach ($d in $docs) { $r = Find-Last $d $key; if ($r) { $out = $r } }
  return $out
}

$final = 'text'; $sid = ''
switch ($Harness) {
  'claude'   { $sid = Json-Last 'session_id' $events;      $final = 'result' }
  'codex'    { $sid = Json-Last 'thread_id' $events;       $final = 'text' }
  'gemini'   { $sid = Json-Last 'session_id' $events; if (-not $sid) { $sid = Json-Last 'sessionId' $events }; $final = 'response' }   # best effort
  'agy'      { $sid = Json-Last 'conversation_id' $events; $final = 'response' }
  'opencode' { $sid = Json-Last 'sessionID' $events;       $final = 'text' }
}
if (-not $sid) { $sid = $Session }

# Result: prefer what the worker wrote; otherwise capture its final message.
$state = 'missing'
$after = ''
if ((Test-Path -LiteralPath $Result) -and ((Get-Item -LiteralPath $Result).Length -gt 0)) { $after = (Get-FileHash -LiteralPath $Result).Hash }
if ($after -and ($after -ne $before)) { $state = 'worker' }
else {
  $msg = Json-Last $final $events
  if ($msg) { [IO.File]::WriteAllText($Result, $msg + "`n", (New-Object Text.UTF8Encoding($false))); $state = 'captured' }
}

$fin = 'done'; if ($rc -ne 0) { $fin = 'failed' }; if ($rc -eq 124) { $fin = 'timeout' }
Write-Status $fin $rc $sid $state
Write-Output "exit=$rc"; Write-Output "session=$sid"; Write-Output "result=$state"
exit $rc
