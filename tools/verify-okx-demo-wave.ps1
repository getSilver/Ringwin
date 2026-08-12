[CmdletBinding()]
param(
    [switch]$DemoLive,
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env.local'),
    [int]$Parallel = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ExpectedZig = '0.17.0-dev.315+5b647b792'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildRoot = Join-Path $workspace '.scratch\build'
$curlBuild = Join-Path $buildRoot 'libcurl-8.21.0-windows-x86_64-schannel'
$curlSource = Join-Path $buildRoot 'bootstrap\curl-source'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'OKX Demo wave acceptance must run on Windows'
}
$zigVersion = (& zig version).Trim()
if ($LASTEXITCODE -ne 0 -or $zigVersion -ne $ExpectedZig) {
    throw "Expected Zig $ExpectedZig, got $zigVersion"
}

$zigSources = @(Get-ChildItem (Join-Path $workspace 'src') -File -Filter '*.zig' | ForEach-Object FullName)
& zig fmt --check $zigSources
if ($LASTEXITCODE -ne 0) { throw 'Zig format check failed' }
foreach ($optimize in @('Debug', 'ReleaseSafe', 'ReleaseFast')) {
    & zig test (Join-Path $workspace 'src\main.zig') "-O$optimize"
    if ($LASTEXITCODE -ne 0) { throw "Core $optimize tests failed" }
}
& zig run (Join-Path $workspace 'src\main.zig') -OReleaseSafe
if ($LASTEXITCODE -ne 0) { throw 'Deterministic core acceptance failed' }

$curlLibrary = Get-ChildItem -LiteralPath $curlBuild -Recurse -File -Filter 'libcurl.a' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $curlLibrary) {
    & (Join-Path $PSScriptRoot 'bootstrap-libcurl.ps1') -BuildRoot $buildRoot -Parallel $Parallel | Out-Host
}
& (Join-Path $PSScriptRoot 'test-libcurl.ps1') -BuildRoot $curlBuild

$include = (Get-ChildItem -LiteralPath $curlSource -Recurse -Directory -Filter include | Where-Object {
    Test-Path -LiteralPath (Join-Path $_.FullName 'curl\curl.h')
} | Select-Object -First 1).FullName
if (-not $include) { throw 'Pinned libcurl headers are missing after bootstrap' }
& zig build-exe (Join-Path $workspace 'src\main.zig') -target x86_64-linux-gnu -OReleaseSafe -fno-emit-bin
if ($LASTEXITCODE -ne 0) { throw 'Linux core cross-build failed' }
& zig build-obj (Join-Path $workspace 'src\okx_demo_live_acceptance.zig') `
    (Join-Path $workspace 'src\okx_curl_shim.c') -target x86_64-linux-gnu -lc "-I$include" `
    "-femit-bin=$(Join-Path $buildRoot 'okx-demo-live-acceptance-linux.o')"
if ($LASTEXITCODE -ne 0) { throw 'Linux OKX Adapter compile check failed' }

$liveArgs = @{
    EnvFile = $EnvFile
    BuildRoot = $curlBuild
    Optimize = 'ReleaseSafe'
}
if ($DemoLive) { $liveArgs.DemoLive = $true } else { $liveArgs.PrepareOnly = $true }
& (Join-Path $PSScriptRoot 'run-okx-demo-live-acceptance.ps1') @liveArgs

$mode = if ($DemoLive) { 'demo_live' } else { 'read_only' }
Write-Output "okx_demo_wave_acceptance=passed mode=$mode linux=compile_only production_qualification=false"
