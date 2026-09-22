# smart-plan preflight: collect access facts. Windows-native twin of preflight.sh. Never prints a secret.
# Works on Windows PowerShell 5.1 (stock) and PowerShell 7+. Keep this file ASCII-only.
#
#   preflight.ps1 check <provider,provider,...>   providers: anthropic openai google deepseek zai qwen typesafe openrouter
#   preflight.ps1 smoke <harness> <model> [timeoutSec]   one tiny real request through dispatch.ps1 (read-only)
#   preflight.ps1 smoke-all <timeoutSec> <harness>=<model> [<harness>=<model> ...]   the same, every pair in parallel;
#                                          one smoke row per pair, in the order given; exit 0 only if every row is OK, else 1
#   preflight.ps1 models <harness> [regex] model IDs only, one per line, filtered by a case-insensitive extended regex
#                                          (default: all). Exit 0 = at least one ID, 1 = none, 2 = unknown / not installed harness
#   preflight.ps1 agents [dir]             read-only: is the repository readable by every harness? (dir default .)
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
param(
  [Parameter(Mandatory=$true, Position=0)][ValidateSet('check','smoke','smoke-all','models','agents')][string]$Action,
  [Parameter(Position=1)][string]$Arg1 = '',
  [Parameter(Position=2)][string]$Arg2 = '',
  [Parameter(Position=3)][string]$Arg3 = '',
  [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest
)
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Row($s, $i, $d, $f) { Write-Output ("{0}`t{1}`t{2}`t{3}" -f $s, $i, $d, $f) }
function Has($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }
# A variable set in User/Machine scope after the terminal opened is invisible to the process: check all scopes.
function EnvSet($n) {
  foreach ($scope in 'Process','User','Machine') { if ([Environment]::GetEnvironmentVariable($n, $scope)) { return $true } }
  return $false
}
function EnvVal($n) {
  foreach ($scope in 'Process','User','Machine') { $v = [Environment]::GetEnvironmentVariable($n, $scope); if ($v) { return $v } }
  return ''
}
function Ver($c) { try { (& $c --version 2>$null | Select-Object -First 1) } catch { '' } }
function Strip($t) { ($t | Out-String) -replace "$([char]27)\[[0-9;]*m", '' }

$script:ocAuth = $null
function OcHas($rx) {
  if (-not (Has opencode)) { return $false }
  if ($null -eq $script:ocAuth) { try { $script:ocAuth = Strip (& opencode auth list 2>$null) } catch { $script:ocAuth = '' } }
  return ($script:ocAuth -match $rx)
}

$script:openrouterOk = $false
function Check-Env {
  Row INFO shell ("PowerShell {0} on {1}" -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString) ''
  Row OK timeout 'built into dispatch.ps1' ''
  if (Has git) {
    $top = ''
    try { $top = (& git rev-parse --show-toplevel 2>$null) } catch { }
    if ($LASTEXITCODE -eq 0 -and $top) { Row OK git "repository: $top" '' } else { Row MISSING git 'current directory is not a git repository' 'git init' }
  } else { Row MISSING git 'not installed' 'install git' }
  if (Has curl.exe) { Row OK curl 'curl.exe available' '' } else { Row INFO curl 'curl.exe absent (needed only for Jev)' 'install curl' }
  $cg = EnvVal 'SP_CODEGRAPH'; if (-not $cg) { $cg = 'codebase-memory-mcp' }   # code-graph binary named in routing.md
  if (Has $cg) { Row OK codegraph (Ver $cg) '' }
  else { Row INFO codegraph "$cg not installed (fatal only if REQUIRE_CODEGRAPH is on)" 'install it (routing.md, Code graph), or set SP_CODEGRAPH to the routed binary' }
}

function Check-OpenRouter {
  if (EnvSet 'OPENROUTER_API_KEY') {
    $code = 0
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      $r = Invoke-WebRequest -Uri 'https://openrouter.ai/api/v1/key' -Headers @{ Authorization = 'Bearer ' + (EnvVal 'OPENROUTER_API_KEY') } -UseBasicParsing -TimeoutSec 20
      $code = [int]$r.StatusCode
    } catch { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } }
    if ($code -eq 200) { Row OK openrouter.key 'env var present, validated (HTTP 200)' ''; $script:openrouterOk = $true }
    elseif ($code -eq 401) { Row MISSING openrouter.key 'env var present but rejected (HTTP 401)' 'create a new key at openrouter.ai/keys' }
    else { Row INFO openrouter.key "env var present, validation inconclusive (HTTP $code)" ''; $script:openrouterOk = $true }
  }
  elseif (OcHas 'openrouter') { Row OK openrouter.key 'credential stored in opencode (validated by the smoke test)' ''; $script:openrouterOk = $true }
  else { Row MISSING openrouter.key 'no OPENROUTER_API_KEY and no opencode credential' 'opencode auth login  (or set OPENROUTER_API_KEY)' }
  if (Has opencode) { Row OK openrouter.bridge ("opencode " + (Ver opencode)) '' } else { Row MISSING openrouter.bridge 'opencode not installed' 'npm i -g opencode-ai'; $script:openrouterOk = $false }
}

function Channel($p, $sub, $key, $viaOr) {
  $c = 'none'
  if ($sub) { $c = 'subscription' } elseif ($key) { $c = 'api-key' } elseif ($viaOr -and $script:openrouterOk) { $c = 'openrouter' }
  Write-Output ("CHANNEL`t{0}`t{1}" -f $p, $c)
}

function Check-Provider($p) {
  $sub = $false; $key = $false
  switch ($p) {
    'anthropic' {
      if (Has claude) {
        $st = ''
        try { $st = ((& claude auth status 2>$null) | Out-String) -replace '\s', '' } catch { }
        if ($st -match '"loggedIn":true' -and $st -match '"subscriptionType":"') { $sub = $true; Row OK anthropic.subscription ("claude " + (Ver claude) + ", subscription login") '' }
        elseif ($st -match '"loggedIn":true') { Row INFO anthropic.subscription 'logged in, no subscription type reported' '' }
        else { Row MISSING anthropic.subscription 'claude installed, not logged in' 'claude auth login' }
      } else { Row MISSING anthropic.subscription 'claude CLI not installed' 'https://code.claude.com/docs' }
      if (EnvSet 'ANTHROPIC_API_KEY') { $key = $true; Row OK anthropic.api-key present '' } else { Row INFO anthropic.api-key 'ANTHROPIC_API_KEY not set' '' }
      Channel anthropic $sub $key $true
    }
    'openai' {
      if (Has codex) {
        $ls = ''
        try { $ls = (& codex login status 2>&1 | Out-String) } catch { }
        if ($LASTEXITCODE -eq 0 -and $ls -match 'ChatGPT') { $sub = $true; Row OK openai.subscription ((Ver codex) + ", ChatGPT login") '' }
        elseif ($LASTEXITCODE -eq 0) { $key = $true; Row OK openai.api-key 'codex logged in with an API key' '' }
        else { Row MISSING openai.subscription 'codex installed, not logged in' 'codex login' }
      } else { Row MISSING openai.subscription 'codex CLI not installed' 'npm i -g @openai/codex' }
      if ((EnvSet 'CODEX_API_KEY') -or (EnvSet 'OPENAI_API_KEY')) { $key = $true; Row OK openai.api-key present '' }
      Channel openai $sub $key $true
    }
    'google' {
      $g = @(); if (Has agy) { $g += 'agy' }; if (Has gemini) { $g += 'gemini' }
      if ($g.Count) { Row INFO google.harness ("installed: " + ($g -join ' ') + " (no auth-status command exists: run the smoke test)") '' }
      else { Row MISSING google.harness 'neither agy nor gemini installed' 'install Antigravity CLI, or: npm i -g @google/gemini-cli' }
      if ((EnvSet 'GEMINI_API_KEY') -or (EnvSet 'GOOGLE_API_KEY') -or (EnvSet 'GOOGLE_CLOUD_PROJECT')) { $key = $true; Row OK google.api-key present '' } else { Row INFO google.api-key 'no GEMINI_API_KEY / Vertex env' '' }
      if ($g.Count -and -not $key) { Write-Output "CHANNEL`tgoogle`tunverified-login (smoke test decides)" } else { Channel google $false $key $true }
    }
    'deepseek' {
      Row INFO deepseek.subscription 'DeepSeek offers no subscription' ''
      if ((EnvSet 'DEEPSEEK_API_KEY') -or (OcHas 'deepseek')) { $key = $true; Row OK deepseek.api-key present '' } else { Row INFO deepseek.api-key 'no DEEPSEEK_API_KEY (OpenRouter will be used)' '' }
      Channel deepseek $false $key $true
    }
    'zai' {
      if (OcHas 'coding plan') { $sub = $true; Row OK zai.subscription 'GLM Coding Plan credential in opencode' '' } else { Row INFO zai.subscription 'no GLM Coding Plan credential in opencode' '' }
      if ((EnvSet 'ZHIPU_API_KEY') -or (OcHas 'z\.ai|zhipu')) { $key = $true; Row OK zai.api-key present '' } else { Row INFO zai.api-key 'no ZHIPU_API_KEY' '' }
      Channel zai $sub $key $true
    }
    'qwen' {
      if ((EnvSet 'ALIBABA_TOKEN_PLAN_API_KEY') -or (OcHas 'token plan')) { $sub = $true; Row OK qwen.subscription 'Alibaba Token Plan credential present' '' } else { Row INFO qwen.subscription 'no Alibaba Token Plan credential' '' }
      $null = OcHas '.'   # fills ocAuth; a "... Plan" line is a subscription, not the pay-as-you-go key
      $payg = @(("$($script:ocAuth)" -split "`n") | Where-Object { $_ -match 'alibaba|dashscope' -and $_ -notmatch 'plan' })
      if ((EnvSet 'DASHSCOPE_API_KEY') -or $payg.Count) { $key = $true; Row OK qwen.api-key present '' } else { Row INFO qwen.api-key 'no DASHSCOPE_API_KEY (OpenRouter will be used)' '' }
      Channel qwen $sub $key $true
    }
    'typesafe' {
      if (EnvSet 'TYPESAFE_API_KEY') {
        $key = $true; $code = 0   # GET /v1/models validates the key without spending a token
        $base = EnvVal 'SP_JEV_URL'; if (-not $base) { $base = 'https://api.typesafe.ai/v1/systemone' }
        $models = ($base -replace '/[^/]*$', '') + '/models'
        try {
          [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
          $r = Invoke-WebRequest -Uri $models -Headers @{ Authorization = 'Bearer ' + (EnvVal 'TYPESAFE_API_KEY') } -UseBasicParsing -TimeoutSec 20
          $code = [int]$r.StatusCode
        } catch { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } }
        if ($code -eq 200) { Row OK typesafe.api-key 'present, validated (HTTP 200)' '' }
        elseif ($code -eq 401) { $key = $false; Row MISSING typesafe.api-key 'present but rejected (HTTP 401)' 'create a new key in the TypeSafe console, or set the review gate to off in routing.md' }
        else { Row INFO typesafe.api-key "present, validation inconclusive (HTTP $code)" '' }
      }
      else { Row MISSING typesafe.api-key 'TYPESAFE_API_KEY not set (Jev has no other channel)' 'set TYPESAFE_API_KEY, or set the review gate to off in routing.md' }
      $sk = $false   # official skill: optional question-design guidance for the orchestrator, never needed to call Jev
      if (Has claude) { try { if ((& claude plugin list 2>$null | Out-String) -match 'typesafe@') { $sk = $true } } catch { } }
      $userHome = [Environment]::GetFolderPath('UserProfile')
      foreach ($d in '.claude/skills', '.agents/skills', "$userHome/.claude/skills", "$userHome/.agents/skills", "$userHome/.codex/skills", "$userHome/.config/opencode/skills") {
        if (Test-Path -LiteralPath "$d/typesafe-ai/SKILL.md") { $sk = $true }
      }
      if ($sk) { Row OK typesafe.skill 'official TypeSafe skill installed' '' }
      else { Row INFO typesafe.skill 'official TypeSafe skill not installed (optional)' 'Claude Code: claude plugin marketplace add typesafe-ai/skills, then claude plugin install typesafe@typesafe-ai - other agents: npx skills add typesafe-ai/skills --skill typesafe-ai' }
      Channel typesafe $false $key $false
    }
    'openrouter' { }
    default { Row INFO $p 'unknown provider: reachable only through opencode / OpenRouter' ''; Channel $p $false $false $true }
  }
}

function Usage {
  [Console]::Error.WriteLine('usage: preflight.ps1 check <providers> | smoke <harness> <model> [timeoutSec] | smoke-all <timeoutSec> <harness>=<model> ... | models <harness> [regex] | agents [dir]')
  exit 2
}
function Epoch { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# --- smoke: one tiny real request, with a cache of OK results (same file as preflight.sh) ---
function Cache-File {
  $h = $env:USERPROFILE; if (-not $h) { $h = $env:HOME }; if (-not $h) { $h = [Environment]::GetFolderPath('UserProfile') }
  if (-not $h) { return '' }
  try { return [IO.Path]::Combine($h, '.cache', 'smart-plan', 'smoke.tsv') } catch { return '' }   # Join-Path fails on an unknown drive
}
function Cache-Hit($h, $m) {   # age in hours of the youngest fresh OK, else -1
  $ch = 24; if ("$($env:SP_SMOKE_CACHE_H)" -match '^\d{1,6}$') { $ch = [int]$env:SP_SMOKE_CACHE_H }
  $f = Cache-File
  if ($ch -le 0 -or -not $f -or -not (Test-Path -LiteralPath $f -PathType Leaf)) { return -1 }
  $now = Epoch; $best = -1
  try {
    foreach ($l in [IO.File]::ReadAllLines($f)) {
      $p = $l -split "`t"
      if ($p.Count -lt 3 -or $p[0] -notmatch '^\d{1,15}$' -or $p[1] -cne $h -or $p[2] -cne $m) { continue }
      $age = $now - [long]$p[0]
      if ($age -ge 0 -and $age -lt ($ch * 3600) -and ($best -lt 0 -or $age -lt $best)) { $best = $age }
    }
  } catch { return -1 }
  if ($best -lt 0) { return -1 }
  return [int][Math]::Floor($best / 3600)
}
function Cache-Put($h, $m) {   # never fails (an unwritable home is ignored)
  try {
    $f = Cache-File; if (-not $f) { return }
    $d = Split-Path -Parent $f
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null }
    $line = "{0}`t{1}`t{2}`n" -f (Epoch), $h, $m
    for ($i = 0; $i -lt 5; $i++) {
      try { [IO.File]::AppendAllText($f, $line, (New-Object Text.UTF8Encoding($false))); break } catch { Start-Sleep -Milliseconds 100 }
    }
  } catch { }
}
$script:smokeRc = 0
function Smoke-One($h, $m, $t) {   # prints one row, sets $script:smokeRc to the dispatch exit code
  $age = Cache-Hit $h $m
  if ($age -ge 0) { Row OK "smoke.$h" "$m replied (cached $($age)h ago)" ''; $script:smokeRc = 0; return }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("sp-smoke-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  [IO.File]::WriteAllText((Join-Path $tmp 'brief.md'), "Reply with exactly: OK`nDo nothing else. Do not use any tool.`n", (New-Object Text.UTF8Encoding($false)))
  $shell = (Get-Process -Id $PID).Path
  & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'dispatch.ps1') $h $m read $tmp (Join-Path $tmp 'brief.md') (Join-Path $tmp 'result.md') $t | Out-Null
  $rc = $LASTEXITCODE
  $res = Join-Path $tmp 'result.md'
  if ($rc -eq 0 -and (Test-Path $res) -and ((Get-Content -Raw $res) -match 'OK')) { Row OK "smoke.$h" "$m replied" ''; Cache-Put $h $m }
  else {
    $why = ''
    foreach ($f in "$res.stderr", "$res.events") {
      if (-not $why.Trim() -and (Test-Path $f)) { $x = Strip (Get-Content -Raw $f); if ($x) { $x = ($x -replace '\s+', ' ').Trim(); $why = $x.Substring([Math]::Max(0, $x.Length - 300)) } }
    }
    if ($rc -eq 124) { $why = 'timeout' }
    if (-not $why) { $why = 'no output' }
    Row MISSING "smoke.$h" "$m failed (exit $rc): $why" 'check login, model access, quota / credit'
  }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  $script:smokeRc = $rc
}

# --- agents: is the repository readable by every harness? Read-only, no model call, no network. ---
function Exists($p) { Test-Path -LiteralPath $p }
function Is-Link($p) { $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue; return [bool]($i -and $i.LinkType -eq 'SymbolicLink') }
function NonEmpty-Dir($p) { (Test-Path -LiteralPath $p -PathType Container) -and (@(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue).Count -gt 0) }
function Present($p) { (Test-Path -LiteralPath $p -PathType Leaf) -or (NonEmpty-Dir $p) }
function Contains-Text($text, $p) {
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $false }
  try { return [IO.File]::ReadAllText($p).Contains($text) } catch { return $false }
}
function First-Line($p) {   # first non-empty line; ReadAllLines is CR and BOM tolerant
  try { foreach ($l in [IO.File]::ReadAllLines($p)) { if ($l.Trim()) { return $l } } } catch { }
  return ''
}
function Has-AtLine($p) {
  try { foreach ($l in [IO.File]::ReadAllLines($p)) { if ($l.StartsWith('@')) { return $true } } } catch { }
  return $false
}
function Layout-State($dir) {
  $fa = Join-Path $dir 'AGENTS.md'; $fc = Join-Path $dir 'CLAUDE.md'; $fg = Join-Path $dir 'GEMINI.md'
  $ha = Exists $fa; $hc = Exists $fc; $hg = Exists $fg
  if (-not $ha) {
    if ($hc -and $hg) { return 'vendor-only' } elseif ($hc) { return 'claude-only' } elseif ($hg) { return 'gemini-only' } else { return 'none' }
  }
  if ((Is-Link $fa) -or (Is-Link $fc) -or (Is-Link $fg)) { return 'symlink' }
  if (-not $hc -and -not $hg) { return 'agents-only' }
  # a missing bridge counts as a bridge that does not import
  if (-not $hc -or -not $hg -or (First-Line $fc) -cne '@AGENTS.md' -or (First-Line $fg) -cne '@./AGENTS.md') { return 'no-import' }
  if ((Get-Item -LiteralPath $fa -Force).Length -eq 0 -or (Has-AtLine $fa)) { return 'agents-invalid' }
  return 'compatible'
}
$script:instr = @('AGENTS.md', 'CLAUDE.md', 'GEMINI.md')
function Walk($abs, $rel, $acc) {   # plain search: skips .git and node_modules, does not follow links
  foreach ($e in @(Get-ChildItem -LiteralPath $abs -Force -ErrorAction SilentlyContinue)) {
    if ($e.PSIsContainer) {
      if ($e.Name -eq '.git' -or $e.Name -eq 'node_modules' -or $e.LinkType) { continue }
      Walk $e.FullName ($rel + $e.Name + '/') $acc
    } elseif ($script:instr -ccontains $e.Name) { [void]$acc.Add($rel + $e.Name) }
  }
}
function Agents-Cmd($dir) {
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { [Console]::Error.WriteLine("preflight: folder not found: $dir"); exit 2 }
  $root = (Resolve-Path -LiteralPath $dir).ProviderPath
  $found = New-Object System.Collections.ArrayList
  $inGit = $false
  if (Has git) { try { & git -C $root rev-parse --is-inside-work-tree 2>$null | Out-Null; $inGit = ($LASTEXITCODE -eq 0) } catch { $inGit = $false } }
  if ($inGit) {
    try {
      foreach ($l in @(& git -C $root -c core.quotePath=false ls-files 2>$null) + @(& git -C $root -c core.quotePath=false ls-files --others --exclude-standard 2>$null)) { [void]$found.Add("$l") }
    } catch { }
  } else { Walk $root '' $found }
  $set = New-Object 'System.Collections.Generic.List[string]'
  foreach ($f in $found) {
    if ($f -cnotmatch '/(AGENTS|CLAUDE|GEMINI)\.md$' -or $f -match '(^|/)(\.git|node_modules)/') { continue }
    if (-not (Exists (Join-Path $root $f))) { continue }
    $d = $f.Substring(0, $f.LastIndexOf('/'))
    if (-not $set.Contains($d)) { $set.Add($d) }
  }
  $folders = $set.ToArray(); [Array]::Sort($folders, [StringComparer]::Ordinal)
  $script:allOk = $true; $total = 0
  foreach ($d in (@('.') + $folders)) {
    $abs = $root; if ($d -ne '.') { $abs = Join-Path $root $d }
    $st = Layout-State $abs
    Write-Output ("LAYOUT`t{0}`t{1}" -f $d, $st)
    if ($st -ne 'compatible') { $script:allOk = $false }
    $fa = Join-Path $abs 'AGENTS.md'
    if (Test-Path -LiteralPath $fa -PathType Leaf) { $total += (Get-Item -LiteralPath $fa -Force).Length }
  }
  function Gap($kind, $path) { Write-Output ("GAP`t{0}`t{1}" -f $kind, $path); $script:allOk = $false }
  function P($rel) { Join-Path $root $rel }
  $s1 = NonEmpty-Dir (P '.claude/skills'); $s2 = NonEmpty-Dir (P '.agents/skills')
  if ($s1 -and -not $s2) { Gap skills '.claude/skills' }
  if ($s2 -and -not $s1) { Gap skills '.agents/skills' }
  foreach ($p in '.claude/commands', '.gemini/commands', '.codex/prompts') { if (NonEmpty-Dir (P $p)) { Gap commands $p } }
  foreach ($p in '.claude/agents', '.codex/agents', '.gemini/agents', '.agents/agents') { if (NonEmpty-Dir (P $p)) { Gap subagents $p } }
  if (Test-Path -LiteralPath (P '.mcp.json') -PathType Leaf) { Gap mcp '.mcp.json' }
  if (Contains-Text 'mcpServers' (P '.gemini/settings.json')) { Gap mcp '.gemini/settings.json' }
  if (Contains-Text '"mcp"' (P 'opencode.json')) { Gap mcp 'opencode.json' }
  foreach ($p in '.cursorrules', '.cursor/rules', '.github/copilot-instructions.md', '.windsurfrules', '.clinerules') { if (Present (P $p)) { Gap rules $p } }
  if (Test-Path -LiteralPath (P '.claude/settings.json') -PathType Leaf) { Gap permissions '.claude/settings.json' }
  if (Contains-Text '"permission"' (P 'opencode.json')) { Gap permissions 'opencode.json' }
  $ra = P 'AGENTS.md'
  if (Test-Path -LiteralPath $ra -PathType Leaf) {   # characters = bytes that are not UTF-8 continuation bytes
    $chars = 0
    try { foreach ($b in [IO.File]::ReadAllBytes($ra)) { if (($b -band 0xC0) -ne 0x80) { $chars++ } } } catch { }
    if ($chars -gt 12000) { Gap size "AGENTS.md: $chars characters (limit 12000)" }
  }
  if ($total -gt 32768) { Gap size "all AGENTS.md: $total bytes (limit 32768)" }
  if ($script:allOk) { Write-Output "RESULT`tcompatible" } else { Write-Output "RESULT`twork-needed" }
}

# Quote one argument for a Start-Process argument line.
function QA($a) {
  if ("$a".Contains('"')) { [Console]::Error.WriteLine("preflight: argument contains a double quote, refused: $a"); exit 2 }
  if ($a -match '\s') { '"' + $a + '"' } else { $a }
}

if ($Action -eq 'check') {
  if (-not $Arg1) { Usage }
  Check-Env; Check-OpenRouter
  foreach ($p in ($Arg1 -split '[,\s]+' | Where-Object { $_ })) { Check-Provider $p }
  exit 0
}

if ($Action -eq 'agents') {
  $dir = $Arg1; if (-not $dir) { $dir = '.' }
  Agents-Cmd $dir
  exit 0
}

if ($Action -eq 'models') {
  if (-not $Arg1) { Usage }
  if (@('claude', 'codex', 'gemini', 'agy', 'opencode') -notcontains $Arg1) { [Console]::Error.WriteLine("preflight: unknown harness: $Arg1"); exit 2 }
  if (-not (Has $Arg1)) { [Console]::Error.WriteLine("preflight: harness not installed: $Arg1"); exit 2 }
  $rx = $Arg2; if (-not $rx) { $rx = '.' }
  try { $null = [regex]$rx } catch { [Console]::Error.WriteLine("preflight: invalid regex: $rx"); exit 2 }
  $ids = @()
  switch ($Arg1) {
    'claude'   { $ids = @('fable', 'opus', 'sonnet', 'haiku') }   # aliases: no list command exists
    'gemini'   { $ids = @('pro', 'flash', 'auto') }               # aliases: no list command exists
    'opencode' { try { $ids = @((Strip (& opencode models 2>$null)) -split "`r?`n") } catch { } }
    'codex'    {
      try {
        $j = ((& codex debug models 2>$null) | Out-String) | ConvertFrom-Json
        $list = $j; if ($j.models) { $list = $j.models } elseif ($j.data) { $list = $j.data }
        $ids = @($list | ForEach-Object { if ($_.slug -is [string]) { $_.slug } elseif ($_.id -is [string]) { $_.id } })
      } catch { }
    }
    'agy'      {   # "id <tab> display name" lines; any other format: the lines as they are
      try {
        $lines = @((Strip (& agy models 2>$null)) -split "`r?`n")
        $tabbed = @($lines | Where-Object { $_ -match "`t" })
        if ($tabbed.Count) { $ids = @($tabbed | ForEach-Object { ($_ -split "`t")[0] }) } else { $ids = $lines }
      } catch { }
    }
  }
  $n = 0
  foreach ($id in $ids) { $id = "$id".Trim(); if ($id -and $id -match $rx) { Write-Output $id; $n++ } }
  if ($n -gt 0) { exit 0 } else { exit 1 }
}

if ($Action -eq 'smoke-all') {
  if ($Arg1 -notmatch '^\d{1,9}$') { Usage }
  $pairs = @(@($Arg2, $Arg3) + @($Rest) | Where-Object { $_ })
  if (-not $pairs.Count) { Usage }
  foreach ($pair in $pairs) { if ($pair -notmatch '^[^=]+=.+$') { Usage } }
  $sdir = Join-Path ([IO.Path]::GetTempPath()) ("sp-smoke-all-" + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $sdir | Out-Null
  $shell = (Get-Process -Id $PID).Path
  $procs = @(); $n = 0
  foreach ($pair in $pairs) {
    $n++; $i = $pair.IndexOf('=')
    $al = '-NoProfile -ExecutionPolicy Bypass -File ' + (QA $PSCommandPath) + ' smoke ' + (QA $pair.Substring(0, $i)) + ' ' + (QA $pair.Substring($i + 1)) + ' ' + $Arg1
    $p = Start-Process -FilePath $shell -ArgumentList $al -NoNewWindow -PassThru -RedirectStandardOutput (Join-Path $sdir "$n.row") -RedirectStandardError (Join-Path $sdir "$n.err")
    $null = $p.Handle
    $procs += $p
  }
  $deadline = [DateTime]::UtcNow.AddSeconds([int]$Arg1 + 90)
  foreach ($p in $procs) {
    $left = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
    if (-not $p.WaitForExit($left)) { & taskkill.exe /PID $p.Id /T /F 2>$null | Out-Null }
  }
  $n = 0; $bad = 0
  foreach ($pair in $pairs) {
    $n++; $i = $pair.IndexOf('='); $line = ''
    $f = Join-Path $sdir "$n.row"
    if (Test-Path -LiteralPath $f) { $line = @(Get-Content -LiteralPath $f | Where-Object { $_ -match "^(OK|MISSING)`t" }) | Select-Object -First 1 }
    if (-not $line) { $line = "MISSING`tsmoke.$($pair.Substring(0, $i))`t$($pair.Substring($i + 1)) failed: no output`tcheck login, model access, quota / credit" }
    Write-Output $line
    if ($line -notmatch "^OK`t") { $bad = 1 }
  }
  Remove-Item -Recurse -Force $sdir -ErrorAction SilentlyContinue
  exit $bad
}

# smoke
if (-not $Arg1 -or -not $Arg2) { Usage }
$t = 120
if ($Arg3) { if ($Arg3 -notmatch '^\d{1,9}$') { Usage }; $t = [int]$Arg3 }
Smoke-One $Arg1 $Arg2 $t
exit $script:smokeRc
