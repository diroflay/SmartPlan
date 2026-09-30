# smart-plan Jev call: builds the System One request from files, so no model ever has to re-type a diff as JSON.
# Windows-native twin of jev.sh. Works on Windows PowerShell 5.1 (stock) and PowerShell 7+. Keep this file ASCII-only.
#
#   jev.ps1 <questions.json> <response.json> <name=file> [<name=file> ...]
#
#   questions.json  the "questions" object only (small, written by the caller)
#   name=file       one state entry per pair: state.<name> = text content of <file>   e.g. goal=goal.txt diff=task.diff
#
# Env: TYPESAFE_API_KEY (required, never printed) - SP_JEV_MODEL (default jev-latest) - SP_JEV_URL - SP_JEV_MAX_BYTES (default 80000)
# Prints: http=<code>  and  response=<path>.   Exit: 0 ok - 1 call failed - 2 usage - 3 state too large (slice it) - 4 no key
# Names: SP_JEV_MODEL = letters, digits . _ : - only; state names = letters, digits and _ only (exit 2 otherwise).
# Retries 429, 529, 502, 503 and no answer (http=000), 3 tries in all. A non-200 body is kept in <response.json>.
$ErrorActionPreference = 'Stop'
function EnvVal($n) {
  foreach ($scope in 'Process','User','Machine') { $v = [Environment]::GetEnvironmentVariable($n, $scope); if ($v) { return $v } }
  return ''
}
function Full($p) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p) }
function JsonString($text) {
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $text.ToCharArray()) {
    $c = [int]$ch
    if ($ch -eq '\') { [void]$sb.Append('\\') }
    elseif ($ch -eq '"') { [void]$sb.Append('\"') }
    elseif ($c -eq 10) { [void]$sb.Append('\n') }
    elseif ($c -eq 9) { [void]$sb.Append('\t') }
    elseif ($c -lt 32) { }
    else { [void]$sb.Append($ch) }
  }
  return $sb.ToString()
}

if ($args.Count -lt 3) { [Console]::Error.WriteLine('usage: jev.ps1 <questions.json> <response.json> <name=file> [<name=file> ...]'); exit 2 }
$Questions = [string]$args[0]; $Out = [string]$args[1]; $State = @($args[2..($args.Count - 1)] | ForEach-Object { [string]$_ })
if (-not (Test-Path -LiteralPath $Questions)) { [Console]::Error.WriteLine("questions file not found: $Questions"); exit 2 }
$url = EnvVal 'SP_JEV_URL'; if (-not $url) { $url = 'https://api.typesafe.ai/v1/systemone' }
$model = EnvVal 'SP_JEV_MODEL'; if (-not $model) { $model = 'jev-latest' }
if ($model -cnotmatch '^[A-Za-z0-9._:-]+$') { [Console]::Error.WriteLine("bad SP_JEV_MODEL (letters, digits . _ : - only): $model"); exit 2 }
$max = 80000; $m = EnvVal 'SP_JEV_MAX_BYTES'
if ($m) { if ($m -notmatch '^[0-9]{1,9}$') { [Console]::Error.WriteLine("SP_JEV_MAX_BYTES must be a whole number: $m"); exit 2 }; $max = [int]$m }
$key = EnvVal 'TYPESAFE_API_KEY'
if (-not $key) { [Console]::Error.WriteLine('TYPESAFE_API_KEY not set'); exit 4 }

$total = 0; $parts = @()
foreach ($pair in $State) {
  $i = $pair.IndexOf('=')
  if ($i -lt 1 -or -not (Test-Path -LiteralPath $pair.Substring($i + 1) -PathType Leaf)) { [Console]::Error.WriteLine("bad state entry (want name=file, file must exist): $pair"); exit 2 }
  $name = $pair.Substring(0, $i)
  if ($name -cnotmatch '^[A-Za-z0-9_]+$') { [Console]::Error.WriteLine("bad state name (letters, digits and _ only): $name"); exit 2 }
  $file = Full $pair.Substring($i + 1)
  $total += (Get-Item -LiteralPath $file).Length
  $parts += ('"{0}":"{1}"' -f (JsonString $name), (JsonString ([IO.File]::ReadAllText($file))))
}
if ($total -gt $max) { [Console]::Error.WriteLine("state is $total bytes, limit ${max}: slice the diff by file group and call once per slice"); exit 3 }

$body = '{"model":"' + (JsonString $model) + '","state":{' + ($parts -join ',') + '},"questions":' + [IO.File]::ReadAllText((Full $Questions)) + '}'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Full "$Out.request"), $body, $utf8)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$code = 0; $resp = ''
for ($try = 1; $try -le 3; $try++) {
  try {
    $r = Invoke-WebRequest -Uri $url -Method Post -Headers @{ Authorization = 'Bearer ' + $key } -ContentType 'application/json' -Body $utf8.GetBytes($body) -UseBasicParsing -TimeoutSec 60
    $code = [int]$r.StatusCode; $resp = $r.Content
  } catch {
    $err = $_; $code = 0; $resp = ''
    if ($err.Exception.Response) { $code = [int]$err.Exception.Response.StatusCode }
    # Keep the error body: it says why. PowerShell 7 puts it in ErrorDetails; 5.1 may leave it in the response stream.
    if ($err.ErrorDetails -and $err.ErrorDetails.Message) { $resp = $err.ErrorDetails.Message }
    elseif ($err.Exception.Response -and $err.Exception.Response.PSObject.Methods['GetResponseStream']) {
      try { $resp = (New-Object IO.StreamReader($err.Exception.Response.GetResponseStream(), [Text.Encoding]::UTF8)).ReadToEnd() } catch { $resp = '' }
    }
  }
  if (@(0, 429, 502, 503, 529) -notcontains $code) { break }
  if ($try -lt 3) { Start-Sleep -Seconds ($try * 5) }
}
[IO.File]::WriteAllText((Full $Out), [string]$resp, $utf8)
if ($code -eq 0) { Write-Output 'http=000' } else { Write-Output "http=$code" }
Write-Output "response=$Out"
if ($code -eq 200) { exit 0 } else { exit 1 }
