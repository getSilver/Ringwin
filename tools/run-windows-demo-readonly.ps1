[CmdletBinding()]
param([string]$EnvFile = '', [switch]$DemoLive, [switch]$SystemOwnerAuthorized,
      [Parameter(Mandatory=$true)][string]$RestBaseUrl,
      [Parameter(Mandatory=$true)][string]$Entity,
      [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{64}$')][string]$UidSha256)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'protected-demo-launch.ps1')
Assert-ProtectedDemoInput $EnvFile
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$zig = (Get-Command zig -ErrorAction Stop).Source

if ($DemoLive -and -not $SystemOwnerAuthorized) { throw 'Demo live requires explicit SystemOwner authorization' }
Invoke-EmptyInputNative $zig @('build','windows-demo-bin','-Doptimize=ReleaseSafe')
$names = @('RINGWIN_OKX_REST_BASE_URL','RINGWIN_OKX_ENTITY','RINGWIN_OKX_UID_SHA256','RINGWIN_DEMO_LIVE_AUTHORIZED','RINGWIN_DEMO_LIVE_DEADLINE_UNIX')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $env:RINGWIN_OKX_REST_BASE_URL = $RestBaseUrl
    $env:RINGWIN_OKX_ENTITY = $Entity
    $env:RINGWIN_OKX_UID_SHA256 = $UidSha256
    $env:RINGWIN_DEMO_LIVE_AUTHORIZED = if ($DemoLive) { '1' } else { $null }
    $env:RINGWIN_DEMO_LIVE_DEADLINE_UNIX = if ($DemoLive) { [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1800) } else { $null }
    Invoke-ProtectedDemoExecutable (Join-Path $workspace 'zig-out\bin\ringwin-windows-demo.exe') @($(if ($DemoLive) { '--windows-demo-live' } else { '--windows-demo-readonly' }))
} finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') } }
