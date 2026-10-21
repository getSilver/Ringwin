[CmdletBinding()]
param([switch]$DemoLive, [switch]$SystemOwnerAuthorized, [switch]$PrepareOnly, [switch]$CleanupOnly,
      [ValidateSet('Debug','ReleaseSafe')][string]$Optimize = 'ReleaseSafe',
      [string]$EnvFile = '', [string]$BuildRoot,
      [Parameter(Mandatory=$true)][string]$RestBaseUrl,
      [Parameter(Mandatory=$true)][string]$Entity,
      [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{64}$')][string]$UidSha256)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'protected-demo-launch.ps1')
Assert-ProtectedDemoInput $EnvFile
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$zig = (Get-Command zig -ErrorAction Stop).Source

if (@($DemoLive,$PrepareOnly,$CleanupOnly).Where({ $_ }).Count -ne 1) { throw 'Choose exactly one Demo mode' }
if (($DemoLive -or $CleanupOnly) -and -not $SystemOwnerAuthorized) { throw 'Demo writes require -SystemOwnerAuthorized' }
if (($DemoLive -or $CleanupOnly) -and $Optimize -ne 'ReleaseSafe') { throw 'Demo writes require ReleaseSafe' }
if ($DemoLive -or $CleanupOnly) { throw 'Authoritative writes require the Linux acceptance wrapper and its versioned policy; no Windows fallback.' }
if (-not $BuildRoot) { $BuildRoot = Join-Path $workspace '.scratch\build\libcurl-8.21.0-windows-x86_64-schannel' }
$include = Join-Path $workspace '.scratch\build\bootstrap\curl-source\curl-8.21.0\include'
$output = Join-Path $workspace '.scratch\build\okx-demo-live-acceptance.exe'
Invoke-EmptyInputNative (Get-Command python).Source @((Join-Path $PSScriptRoot 'zig-entry.py'),'--zig',$zig,'build-exe',(Join-Path $workspace 'src\testing\acceptance\venues\okx_demo_live_acceptance.zig'),(Join-Path $workspace 'src\adapters\okx\okx_curl_shim.c'),"-I$include","-L$(Join-Path $BuildRoot 'lib')",'-lc','-lcurl','-lws2_32','-lcrypt32','-lsecur32','-ladvapi32','-lbcrypt','-lwldap32','-lnormaliz','-liphlpapi',"-O$Optimize",'--stack','67108864',"-femit-bin=$output")
$oldBase = $env:RINGWIN_OKX_REST_BASE_URL
$oldEntity = $env:RINGWIN_OKX_ENTITY
$oldUid = $env:RINGWIN_OKX_UID_SHA256
try {
    $env:RINGWIN_OKX_REST_BASE_URL = $RestBaseUrl
    $env:RINGWIN_OKX_ENTITY = $Entity
    $env:RINGWIN_OKX_UID_SHA256 = $UidSha256
    Invoke-ProtectedDemoExecutable $output @('--prepare-only')
} finally { $env:RINGWIN_OKX_REST_BASE_URL = $oldBase; $env:RINGWIN_OKX_ENTITY = $oldEntity; $env:RINGWIN_OKX_UID_SHA256 = $oldUid }
