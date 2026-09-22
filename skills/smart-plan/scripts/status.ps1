# smart-plan status: who is working on what, read from the <result>.status and <result>.events files
# that dispatch writes. Costs no model tokens. Windows-native twin of status.sh.
# Works on Windows PowerShell 5.1 (stock) and PowerShell 7+. Keep this file ASCII-only.
#
# Usage: status.ps1 [dir] [watchSec]            board of every worker under dir (default .to-do);
#                                               with watchSec: redraw every watchSec seconds until Ctrl-C
#        status.ps1 wait <maxSec> <result>...   block until none of these workers is running, at most maxSec
#                                               seconds; prints one line per worker. Exit 0 = all finished,
#                                               3 = some still running (call again).
# States: running | done | failed | timeout | stale (running past its timeout: the dispatch was killed).
# The model is shown without its channel prefix (openrouter/deepseek/x -> x); the journal has the channel.
# Finished workers leave the board after 30 minutes; the journal keeps the history.
$ErrorActionPreference = 'Stop'

function Now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# Read a file another process may be writing; at most the last $max bytes.
function Read-Tail($file, $max) {
  try {
    $fs = New-Object IO.FileStream($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
      if ($fs.Length -gt $max) { $null = $fs.Seek(-$max, [IO.SeekOrigin]::End) }
      $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
      return $sr.ReadToEnd()
    } finally { $fs.Dispose() }
  } catch { return '' }
}

# Load one status file into a hashtable; $null when absent or incomplete.
function Load($file) {
  if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
  $s = @{ task = ''; harness = ''; model = ''; started = 0; timeout = 1800; state = ''; ended = 0; exit = ''; session = ''; result = '' }
  foreach ($l in ((Read-Tail $file 65536) -split "`r?`n")) {
    $i = $l.IndexOf('=')
    if ($i -gt 0) { $s[$l.Substring(0, $i)] = $l.Substring($i + 1) }
  }
  if (-not $s.state) { return $null }
  if ($s.state -eq 'running' -and ((Now) - [long]$s.started) -gt ([long]$s.timeout + 120)) { $s.state = 'stale' }
  return $s
}

# First string value of a JSON key in a line, unescaped for display.
function JVal($line, $key) {
  $m = [regex]::Match($line, '"' + [regex]::Escape($key) + '":"((?:\\.|[^"\\])*)"')
  if (-not $m.Success) { return '' }
  $v = $m.Groups[1].Value -replace '\\\\', [string][char]1 -replace '\\[nrt]', ' ' -replace '\\"', '"'
  return $v -replace [string][char]1, '\'
}

# Last thing the worker did, from the tail of its event stream. Empty when the harness does not stream.
function Activity($harness, $file) {
  $pat = $null
  switch ($harness) {
    'claude'   { $pat = '^."type":"assistant".*"type":"(tool_use|text)"' }
    'codex'    { $pat = '"type":"(command_execution|agent_message|file_change)"' }
    'opencode' { $pat = '^."type":"(tool_use|text)"' }
    'agy'      { $pat = '"step_type":"tool"' }
  }
  if (-not $pat -or -not (Test-Path -LiteralPath $file)) { return '' }
  $line = ''
  foreach ($l in ((Read-Tail $file 262144) -split "`r?`n")) { if ($l -cmatch $pat) { $line = $l } }
  if (-not $line) { return '' }
  $label = JVal $line 'tool_name'; if (-not $label) { $label = JVal $line 'tool' }
  if (-not $label) {
    if ($line.Contains('"type":"tool_use"')) { $label = JVal $line 'name' }
    elseif ($line.Contains('"type":"command_execution"')) { $label = 'shell' }
    elseif ($line.Contains('"type":"file_change"')) { $label = 'edit' }
    else { $label = 'says' }
  }
  $detail = ''
  foreach ($k in 'command', 'CommandLine') {
    if (-not $detail) { $detail = (JVal $line $k) -replace '^.*(pwsh|powershell|bash|sh)(\.exe)?"? +(-NoProfile +)?(-Command|-lc|-c) +', '' }
  }
  foreach ($k in 'file_path', 'filePath', 'AbsolutePath', 'TargetFile', 'path') {
    if (-not $detail) { $detail = (JVal $line $k) -replace '.*[\\/]', '' }
  }
  foreach ($k in 'pattern', 'query', 'text') { if (-not $detail) { $detail = JVal $line $k } }
  $out = $label; if ($detail) { $out = "${label}: $detail" }
  if ($out.Length -gt 60) { $out = $out.Substring(0, 60) }
  return $out
}

function Clock($sec) { '{0}:{1:00}' -f [int][math]::Floor($sec / 60), [int]($sec % 60) }
function Fit($t, $n) { if ($t.Length -gt $n) { $t = $t.Substring(0, $n) }; $t.PadRight($n) }

function Board($dir) {
  $run = 0; $fin = 0; $old = 0; $rows = @()
  foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.status' -ErrorAction SilentlyContinue)) {
    $s = Load $f.FullName; if (-not $s) { continue }
    $t = Now
    if ($s.state -eq 'running') { $run++; $el = $t - [long]$s.started; $act = Activity $s.harness ($f.FullName -replace '\.status$', '.events') }
    elseif ($s.state -eq 'stale') { $fin++; $el = $t - [long]$s.started; $act = 'no sign of life past its timeout: dispatch again' }
    else {
      if (($t - [long]$s.ended) -gt 1800) { $old++; continue }
      $fin++; $el = [long]$s.ended - [long]$s.started; $act = "exit=$($s.exit) result=$($s.result)"
    }
    $model = ($s.model -replace '^.*/', '') + " ($($s.harness))"
    $rows += New-Object psobject -Property @{ Key = [long]$s.started; Text = ('{0} {1} {2} {3}  {4}' -f (Fit $s.task 18), (Fit $model 34), (Fit $s.state 8), (Clock $el).PadLeft(6), $act) }
  }
  ('{0} {1} {2} {3}  {4}' -f (Fit 'TASK' 18), (Fit 'MODEL (HARNESS)' 34), (Fit 'STATE' 8), 'TIME'.PadLeft(6), 'LAST ACTIVITY')
  $rows | Sort-Object Key | ForEach-Object { $_.Text }
  "-- $run running, $fin finished, $old older than 30 min hidden -- $(Get-Date -Format 'HH:mm:ss')"
}

if ($args.Count -gt 0 -and $args[0] -eq 'wait') {
  if ($args.Count -lt 3) { [Console]::Error.WriteLine('usage: status.ps1 wait <maxSec> <result>...'); exit 2 }
  $max = [int]$args[1]; $results = @($args[2..($args.Count - 1)]); $t0 = Now
  while ($true) {
    $busy = $false
    foreach ($r in $results) { $s = Load "$r.status"; if ($s -and $s.state -eq 'running') { $busy = $true } }
    if (-not $busy -or ((Now) - $t0) -ge $max) { break }
    Start-Sleep -Seconds 2
  }
  foreach ($r in $results) {
    $s = Load "$r.status"
    if ($s) { "$($s.task) | $($s.model) ($($s.harness)) | state=$($s.state) exit=$($s.exit) session=$($s.session) result=$($s.result)" }
    else { "$r | no status file" }
  }
  if ($busy) { exit 3 }
  exit 0
}

$dir = '.to-do'; if ($args.Count -gt 0) { $dir = $args[0] }
if (-not (Test-Path -LiteralPath $dir -PathType Container)) { [Console]::Error.WriteLine("status: folder not found: $dir"); exit 2 }
if ($args.Count -lt 2) { Board $dir; exit 0 }
while ($true) { $out = Board $dir; Clear-Host; $out; Start-Sleep -Seconds ([int]$args[1]) }
