<#
  Auto-monitoring installer (Windows)

  Makes EVERY Claude Code session on this machine monitored, OneAgent-style:
    1. runs the collector as a logon Scheduled Task (auto-restart on failure)
    2. routes Claude Code's OTel telemetry through it (settings.json env)

  SAFE ORDER: the collector is verified reachable BEFORE settings.json is redirected,
  so working telemetry is never broken. Idempotent. Reverse with uninstall.ps1 steps
  at the bottom of this file.
#>
$ErrorActionPreference = 'Stop'
$RepoDir      = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Kit          = Join-Path $RepoDir 'auto-monitoring'
$Settings     = Join-Path $env:USERPROFILE '.claude\settings.json'
$CollectorUrl = 'http://localhost:4318'
$TaskName     = 'ClaudeCodeCollector'

# ---- 1. prerequisites -------------------------------------------------------
if (-not (Get-Command otelcol-contrib -ErrorAction SilentlyContinue)) {
  throw 'otelcol-contrib not found on PATH. Install it (https://opentelemetry.io/docs/collector/installation/) and re-run.'
}
if (-not (Test-Path $Settings)) { throw "$Settings not found." }

# ---- 2. credentials → collector.env (seeded from current settings) ----------
$EnvFile = Join-Path $Kit 'collector.env'
if (-not (Test-Path $EnvFile)) {
  $cfg = Get-Content $Settings -Raw | ConvertFrom-Json
  $ep  = if ($env:DT_ENDPOINT)  { $env:DT_ENDPOINT }  else { "$($cfg.env.OTEL_EXPORTER_OTLP_ENDPOINT)" -replace '/api/v2/otlp$','' }
  $tok = if ($env:DT_API_TOKEN) { $env:DT_API_TOKEN } else { "$($cfg.env.OTEL_EXPORTER_OTLP_HEADERS)" -replace '^Authorization=Api-Token ','' }
  if (-not $ep -or -not $tok -or $ep -eq $CollectorUrl) { throw 'Could not derive Dynatrace endpoint/token. Set DT_ENDPOINT and DT_API_TOKEN and re-run.' }
  "DT_ENDPOINT=$ep`nDT_API_TOKEN=$tok" | Set-Content -Path $EnvFile -NoNewline
  # restrict to current user
  $acl = Get-Acl $EnvFile; $acl.SetAccessRuleProtection($true,$false)
  $acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME,'FullControl','Allow')))
  Set-Acl $EnvFile $acl
  Write-Host "Wrote collector.env (user-only ACL). Rotate this token when convenient."
}

# ---- 3. logon Scheduled Task, restarts on failure ---------------------------
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$RepoDir\start-collector.ps1`"" `
             -WorkingDirectory $RepoDir
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$set     = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
             -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $set -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host "Scheduled task '$TaskName' registered and started."

# ---- 4. verify the collector BEFORE touching settings -----------------------
$ok = $false
for ($i = 0; $i -lt 20 -and -not $ok; $i++) {
  try {
    Invoke-RestMethod -Method Post -Uri "$CollectorUrl/v1/traces" -ContentType 'application/json' -Body '{"resourceSpans":[]}' | Out-Null
    $ok = $true
  } catch { Start-Sleep -Seconds 1 }
}
if (-not $ok) { throw "Collector not reachable after 20s. settings.json left UNCHANGED — telemetry still flows directly. Check the task (Get-ScheduledTaskInfo $TaskName)." }
Write-Host 'Collector is up.'

# ---- 5. route Claude Code telemetry through the collector (backup first) ----
Copy-Item $Settings "$Settings.pre-automon.bak" -Force
$cfg = Get-Content $Settings -Raw | ConvertFrom-Json
if (-not $cfg.env) { $cfg | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) }
foreach ($kv in @{
  CLAUDE_CODE_ENABLE_TELEMETRY = '1'
  OTEL_METRICS_EXPORTER        = 'otlp'
  OTEL_LOGS_EXPORTER           = 'otlp'
  OTEL_TRACES_EXPORTER         = 'otlp'
  OTEL_EXPORTER_OTLP_PROTOCOL  = 'http/protobuf'
  OTEL_EXPORTER_OTLP_ENDPOINT  = $CollectorUrl
}.GetEnumerator()) { $cfg.env | Add-Member -Force -NotePropertyName $kv.Key -NotePropertyValue $kv.Value }
$cfg.env.PSObject.Properties.Remove('OTEL_EXPORTER_OTLP_HEADERS')   # token now only in collector.env
$cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $Settings
Write-Host "settings.json redirected to $CollectorUrl (backup: $Settings.pre-automon.bak)"
Write-Host "`nAuto-monitoring active for every NEW 'claude' session on this machine."

<#  ---- UNINSTALL (run manually) ----
  Unregister-ScheduledTask -TaskName ClaudeCodeCollector -Confirm:$false
  Copy-Item "$env:USERPROFILE\.claude\settings.json.pre-automon.bak" "$env:USERPROFILE\.claude\settings.json" -Force
#>
