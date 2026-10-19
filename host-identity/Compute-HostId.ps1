<#
  Stable host.id derivation (Windows) — fallback when OneAgent is absent.

  Mirrors OneAgent's --set-host-id-source (machine-id | mac | fqdn | ip, + optional
  namespace), hashes the source to a stable 16-hex-uppercase id, and CACHES it so the
  host keeps the same id across restarts. Sets process env vars STABLE_HOST_ID /
  STABLE_HOST_NAME (consumed by the collector) and also prints them.

  Env knobs: HOST_ID_SOURCE (default machine-id) · HOST_ID_NAMESPACE
             HOST_ID_CACHE_DIR (default %ProgramData%\dynatrace-otel) · HOST_ID_REFRESH=1
#>
param(
  [string]$Source    = $env:HOST_ID_SOURCE,
  [string]$Namespace = $env:HOST_ID_NAMESPACE,
  [string]$CacheDir  = $env:HOST_ID_CACHE_DIR
)
if (-not $Source)   { $Source = 'machine-id' }
if (-not $CacheDir) { $CacheDir = Join-Path $env:ProgramData 'dynatrace-otel' }
$CacheFile = Join-Path $CacheDir 'host-id'

function Hash16([string]$s) {
  $sha   = [System.Security.Cryptography.SHA256]::Create()
  $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
  $hex   = -join ($bytes | ForEach-Object { $_.ToString('x2') })
  return $hex.Substring(0, 16).ToUpper()
}

function Get-RawSource {
  switch ($Source) {
    'machine-id' { (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid }
    'mac'  { (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object ifIndex | Select-Object -First 1).MacAddress }
    'fqdn' { [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName }
    'ip'   { (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1).IPAddress }
    default { throw "unknown HOST_ID_SOURCE: $Source (use machine-id|mac|fqdn|ip)" }
  }
}

New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
if ((Test-Path $CacheFile) -and $env:HOST_ID_REFRESH -ne '1') {
  $HostId = (Get-Content $CacheFile -Raw).Trim()
} else {
  $src = "$(Get-RawSource)".Trim()
  if (-not $src) { throw "could not resolve host-id source '$Source'" }
  $HostId = Hash16 "${Namespace}:${src}"
  Set-Content -Path $CacheFile -Value $HostId -NoNewline
}
$HostName = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName

$env:STABLE_HOST_ID   = $HostId
$env:STABLE_HOST_NAME = $HostName
Write-Output "STABLE_HOST_ID=$HostId"
Write-Output "STABLE_HOST_NAME=$HostName"
