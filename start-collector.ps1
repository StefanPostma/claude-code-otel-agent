<#  Start the Claude Code observability agent collector (Windows), with the
    stable host.id fallback derived and exported first. #>
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Load DT_ENDPOINT / DT_API_TOKEN from the local (gitignored) env file if present.
$EnvFile = Join-Path $ScriptDir 'auto-monitoring\collector.env'
if (Test-Path $EnvFile) {
  Get-Content $EnvFile | Where-Object { $_ -match '^\s*([^#=]+)=(.*)$' } | ForEach-Object {
    [Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim(), 'Process')
  }
}

# Derive + export stable host identity (sets $env:STABLE_HOST_ID / STABLE_HOST_NAME).
& "$ScriptDir\host-identity\Compute-HostId.ps1" | Out-Null
Write-Host "host.id=$($env:STABLE_HOST_ID)  host.name=$($env:STABLE_HOST_NAME)"

if (-not $env:DT_ENDPOINT)  { throw 'set DT_ENDPOINT, e.g. https://<env>.live.dynatrace.com' }
if (-not $env:DT_API_TOKEN) { throw 'set DT_API_TOKEN' }

$Collector = if ($env:COLLECTOR_BIN) { $env:COLLECTOR_BIN } else { 'otelcol-contrib' }
& $Collector --config "$ScriptDir\processor\claude-code-agent.yaml"
