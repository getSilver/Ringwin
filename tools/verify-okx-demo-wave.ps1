[CmdletBinding()]
param(
    [switch]$DemoLive,
    [string]$EnvFile = '',
    [string]$RestBaseUrl, [string]$Entity, [string]$UidSha256, [switch]$SystemOwnerAuthorized,
    [int]$Parallel = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'zig-entry.ps1')
. (Join-Path $PSScriptRoot 'protected-demo-launch.ps1')
Assert-ProtectedDemoInput $EnvFile
if ($DemoLive) { throw 'Use the Linux authoritative wrapper with fresh explicit authorization for Demo writes' }

function Invoke-Zig {
    $invocation = Get-ZigSourceInvocation $args
    Invoke-EmptyInputNative $invocation.Executable $invocation.Arguments
    $global:LASTEXITCODE = 0
}

$ExpectedZig = '0.17.0-dev.315+5b647b792'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildRoot = Join-Path $workspace '.scratch\build'
$curlBuild = Join-Path $buildRoot 'libcurl-8.21.0-windows-x86_64-schannel'
$curlSource = Join-Path $buildRoot 'bootstrap\curl-source'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'OKX Demo wave acceptance must run on Windows'
}
$zigVersion = (Invoke-EmptyInputNative (Get-Command zig -ErrorAction Stop).Source @('version') -CaptureOutput).Trim()
if ($LASTEXITCODE -ne 0 -or $zigVersion -ne $ExpectedZig) {
    throw "Expected Zig $ExpectedZig, got $zigVersion"
}

$zigSources = @(Get-ChildItem (Join-Path $workspace 'src') -Recurse -File -Filter '*.zig' | ForEach-Object FullName)
Invoke-Zig fmt --check $zigSources
if ($LASTEXITCODE -ne 0) { throw 'Zig format check failed' }
foreach ($optimize in @('Debug', 'ReleaseSafe', 'ReleaseFast')) {
    Invoke-Zig test (Join-Path $workspace 'src\main.zig') "-O$optimize"
    if ($LASTEXITCODE -ne 0) { throw "Core $optimize tests failed" }
}
Invoke-Zig build-exe (Join-Path $workspace 'src\main.zig') -OReleaseSafe '--stack' '67108864' "-femit-bin=$(Join-Path $buildRoot 'wave-offline.exe')"
Invoke-EmptyInputNative (Join-Path $buildRoot 'wave-offline.exe') @()
if ($LASTEXITCODE -ne 0) { throw 'Deterministic core acceptance failed' }

$curlLibrary = Get-ChildItem -LiteralPath $curlBuild -Recurse -File -Filter 'libcurl.a' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $curlLibrary) {
    throw 'Provision pinned libcurl dependencies before a framed-input verification; no automatic bootstrap receives this stdin.'
}
Invoke-EmptyInputNative (Get-Process -Id $PID).Path @('-NoProfile','-File',(Join-Path $PSScriptRoot 'test-libcurl.ps1'),'-BuildRoot',$curlBuild)

$include = (Get-ChildItem -LiteralPath $curlSource -Recurse -Directory -Filter include | Where-Object {
    Test-Path -LiteralPath (Join-Path $_.FullName 'curl\curl.h')
} | Select-Object -First 1).FullName
if (-not $include) { throw 'Pinned libcurl headers are missing after bootstrap' }
Invoke-Zig build-exe (Join-Path $workspace 'src\main.zig') -target x86_64-linux-gnu -OReleaseSafe -fno-emit-bin
if ($LASTEXITCODE -ne 0) { throw 'Linux core cross-build failed' }
Invoke-Zig build-obj (Join-Path $workspace 'src\testing\acceptance\venues\okx_demo_live_acceptance.zig') `
    (Join-Path $workspace 'src\adapters\okx\okx_curl_shim.c') -target x86_64-linux-gnu -lc "-I$include" `
    "-femit-bin=$(Join-Path $buildRoot 'okx-demo-live-acceptance-linux.o')"
if ($LASTEXITCODE -ne 0) { throw 'Linux OKX Adapter compile check failed' }

$liveArgs = @{
    EnvFile = $EnvFile
    RestBaseUrl = $RestBaseUrl
    Entity = $Entity
    UidSha256 = $UidSha256
    SystemOwnerAuthorized = $SystemOwnerAuthorized
    BuildRoot = $curlBuild
    Optimize = 'ReleaseSafe'
}
if ($DemoLive) { $liveArgs.DemoLive = $true } else { $liveArgs.PrepareOnly = $true }
& (Join-Path $PSScriptRoot 'run-okx-demo-live-acceptance.ps1') @liveArgs

$mode = if ($DemoLive) { 'demo_live' } else { 'read_only' }
$qualification = if ($DemoLive) { 'demo_qualified' } else { 'not_run' }
Write-Output "okx_demo_wave_acceptance=passed mode=$mode qualification=$qualification linux=compile_only production_qualification=false"
