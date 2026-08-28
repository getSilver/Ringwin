[CmdletBinding()]
param(
    [switch]$DemoLive,
    [string]$EnvFile = '',
    [int]$Parallel = 4
)

# Single fail-fast acceptance entry for the trading core wave (map 09).
# Composes: offline success/fault/restart trajectories, SimulatedVenue,
# four-shard coordination, Python StrategyHost seam, and - only when
# explicitly enabled via -DemoLive - existing OKX Demo facts.
# Any failing step stops the wave immediately; nothing continues past a
# broken assertion.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Zig {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & zig @args
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

if (-not $EnvFile) { $EnvFile = Join-Path $PSScriptRoot '..\.env.local' }
$ExpectedZig = '0.17.0-dev.315+5b647b792'
$AcceptanceSchema = 1
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildRoot = Join-Path $workspace '.scratch\build'
$curlBuild = Join-Path $buildRoot 'libcurl-8.21.0-windows-x86_64-schannel'
$curlSource = Join-Path $buildRoot 'bootstrap\curl-source'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Core wave acceptance must run on Windows'
}
$zigVersion = (& zig version).Trim()
if ($LASTEXITCODE -ne 0 -or $zigVersion -ne $ExpectedZig) {
    throw "Expected Zig $ExpectedZig, got $zigVersion"
}

Write-Output '== phase=format'
$zigSources = @(Get-ChildItem (Join-Path $workspace 'src') -File -Filter '*.zig' | ForEach-Object FullName)
Invoke-Zig fmt --check $zigSources
if ($LASTEXITCODE -ne 0) { throw 'Zig format check failed' }

Write-Output '== phase=core_tests mode=Debug'
Invoke-Zig test (Join-Path $workspace 'src\main.zig') '-ODebug'
if ($LASTEXITCODE -ne 0) { throw 'Core Debug tests failed' }

Write-Output '== phase=core_tests mode=ReleaseSafe'
Invoke-Zig test (Join-Path $workspace 'src\main.zig') '-OReleaseSafe'
if ($LASTEXITCODE -ne 0) { throw 'Core ReleaseSafe tests failed' }

Write-Output '== phase=single_shard_wave'
# Deterministic fixture: happy path plus market-gap / risk-rejection /
# unknown-reconciliation / duplicate-report fault trajectories through the
# SimulatedVenue adapter seam, with frozen digests and live/replay/recovery
# equivalence checks.
Invoke-Zig run (Join-Path $workspace 'src\main.zig') '-OReleaseSafe'
if ($LASTEXITCODE -ne 0) { throw 'Single-shard deterministic acceptance failed' }

Write-Output '== phase=four_shard_wave'
# Four shards + shared gateway + account coordination: success path, local
# faults, margin break latching, and three recovery paths that must converge
# to one shared summary digest. Historical replay never resends side effects.
Invoke-Zig run (Join-Path $workspace 'src\main.zig') '-OReleaseSafe' '--' '--four-shard-acceptance'
if ($LASTEXITCODE -ne 0) { throw 'Four-shard acceptance failed' }

Write-Output '== phase=python_seam'
# StrategyHost product acceptance: same core risk/OMS seam for Python
# intents, crash rebuild, hang kill, stale-session fencing, checkpoint
# catch-up recovery. Fails fast on the first broken check.
& python (Join-Path $workspace 'python\verify_strategy_host.py')
if ($LASTEXITCODE -ne 0) { throw 'Python StrategyHost acceptance failed' }

Write-Output '== phase=linux_cross_compile'
Invoke-Zig build-exe (Join-Path $workspace 'src\main.zig') -target x86_64-linux-gnu -OReleaseSafe -fno-emit-bin
if ($LASTEXITCODE -ne 0) { throw 'Linux core cross-build failed' }

$mode = 'offline'
if ($DemoLive) {
    $mode = 'demo_live'
    Write-Output '== phase=okx_demo_facts mode=demo_live (explicitly enabled)'
    $curlLibrary = Get-ChildItem -LiteralPath $curlBuild -Recurse -File -Filter 'libcurl.a' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $curlLibrary) {
        & (Join-Path $PSScriptRoot 'bootstrap-libcurl.ps1') -BuildRoot $buildRoot -Parallel $Parallel | Out-Host
    }
    & (Join-Path $PSScriptRoot 'test-libcurl.ps1') -BuildRoot $curlBuild

    $include = (Get-ChildItem -LiteralPath $curlSource -Recurse -Directory -Filter include | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'curl\curl.h')
    } | Select-Object -First 1).FullName
    if (-not $include) { throw 'Pinned libcurl headers are missing after bootstrap' }
    Invoke-Zig build-obj (Join-Path $workspace 'src\okx_demo_live_acceptance.zig') `
        (Join-Path $workspace 'src\okx_curl_shim.c') -target x86_64-linux-gnu -lc "-I$include" `
        "-femit-bin=$(Join-Path $buildRoot 'okx-demo-live-acceptance-linux.o')"
    if ($LASTEXITCODE -ne 0) { throw 'Linux OKX Adapter compile check failed' }

    $liveArgs = @{
        EnvFile = $EnvFile
        BuildRoot = $curlBuild
        Optimize = 'ReleaseSafe'
        DemoLive = $true
    }
    & (Join-Path $PSScriptRoot 'run-okx-demo-live-acceptance.ps1') @liveArgs
    if ($LASTEXITCODE -ne 0) { throw 'OKX Demo live facts failed' }
}
else {
    Write-Output '== phase=okx_demo_facts mode=offline (skipped; enable explicitly with -DemoLive)'
}

Write-Output "core_wave_acceptance=passed schema=$AcceptanceSchema mode=$mode demo_facts=$(if ($DemoLive) { 'explicit_okx_demo' } else { 'disabled' }) linux=compile_only production_qualification=false"
