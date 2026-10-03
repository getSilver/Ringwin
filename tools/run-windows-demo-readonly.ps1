[CmdletBinding()]
param(
    [string]$EnvFile = '',
    [switch]$DemoLive,
    [switch]$SystemOwnerAuthorized
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$EnvFile = if ($EnvFile) { $EnvFile } else { Join-Path $PSScriptRoot '..\.env.local' }
if ($DemoLive -and -not $SystemOwnerAuthorized) { throw 'Demo live requires explicit SystemOwner authorization' }
$preflight = & (Join-Path $PSScriptRoot 'okx-demo-preflight.ps1') -EnvFile $EnvFile | ConvertFrom-Json
if (-not $preflight.qualified -or $preflight.environment -ne 'demo' -or
    $preflight.pending_orders -ne 0 -or $preflight.pending_algo_orders -ne 0 -or
    $preflight.open_positions -ne 0 -or $preflight.liabilities -ne 0 -or
    @($preflight.funded_currencies | Where-Object { $_ -ne 'USDT' }).Count -ne 0) {
    throw 'OKX Demo read-only preflight failed'
}

$values = @{}
foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $EnvFile))) {
    if ($line -notmatch '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { continue }
    $value = $matches[2]
    if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    $values[$matches[1]] = $value
}

& zig build windows-demo-bin
if ($LASTEXITCODE -ne 0) { throw 'Windows Demo binary build failed' }

$names = @('RINGWIN_OKX_KEY','RINGWIN_OKX_SECRET','RINGWIN_OKX_PASSPHRASE','RINGWIN_OKX_REST_BASE_URL','RINGWIN_OKX_ENTITY','RINGWIN_OKX_UID_SHA256','RINGWIN_DEMO_LIVE_AUTHORIZED','RINGWIN_DEMO_LIVE_DEADLINE_UNIX')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$previousProxy = $env:HTTPS_PROXY
$chainFailure = $null
try {
    $env:RINGWIN_OKX_KEY = [string]$values.OKX_DEMO_API_KEY
    $env:RINGWIN_OKX_SECRET = [string]$values.OKX_DEMO_SECRET_KEY
    $env:RINGWIN_OKX_PASSPHRASE = [string]$values.OKX_DEMO_PASSPHRASE
    $env:RINGWIN_OKX_REST_BASE_URL = [string]$values.OKX_DEMO_REST_BASE_URL
    $env:RINGWIN_OKX_ENTITY = [string]$values.OKX_ENTITY
    $env:RINGWIN_OKX_UID_SHA256 = [string]$preflight.account_uid_sha256
    $env:RINGWIN_DEMO_LIVE_AUTHORIZED = if ($DemoLive) { '1' } else { $null }
    $env:RINGWIN_DEMO_LIVE_DEADLINE_UNIX = if ($DemoLive) { [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1800) } else { $null }
    $uri = [Uri]'https://openapi.okx.com'
    if (-not [Net.WebRequest]::DefaultWebProxy.IsBypassed($uri)) {
        $env:HTTPS_PROXY = [Net.WebRequest]::DefaultWebProxy.GetProxy($uri).AbsoluteUri
    }
    $mode = if ($DemoLive) { '--windows-demo-live' } else { '--windows-demo-readonly' }
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $chainLines = @(& (Join-Path $PSScriptRoot '..\zig-out\bin\ringwin-windows-demo.exe') $mode 2>&1 | ForEach-Object { "$_" })
    } finally { $ErrorActionPreference = $previousErrorActionPreference }
    $chainExit = $LASTEXITCODE
    $chainLines | Write-Output
    if ($chainExit -ne 0) {
        $reason = @($chainLines | Where-Object { $_ -match '^error: [A-Za-z][A-Za-z0-9_]*$|^windows_demo_\w+_failed=|^okx_transport_failure ' }) -join '; '
        throw "Windows Demo chain failed in $mode`: $reason"
    }
} catch {
    $chainFailure = $_
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    $env:HTTPS_PROXY = $previousProxy
    $values.Clear()
}
if ($DemoLive) {
    $after = & (Join-Path $PSScriptRoot 'okx-demo-preflight.ps1') -EnvFile $EnvFile | ConvertFrom-Json
    Write-Output ("windows_demo_postflight: pending_orders={0} pending_algo_orders={1} open_positions={2} liabilities={3} funded_currencies={4}" -f
        $after.pending_orders, $after.pending_algo_orders, $after.open_positions, $after.liabilities, (@($after.funded_currencies) -join ','))
    if ($chainFailure) { throw $chainFailure }
    if (-not $after.qualified -or $after.account_uid_sha256 -ne $preflight.account_uid_sha256 -or
        $after.pending_orders -ne 0 -or $after.pending_algo_orders -ne 0 -or
        $after.open_positions -ne 0 -or $after.liabilities -ne 0 -or
        @($after.funded_currencies | Where-Object { $_ -ne 'USDT' }).Count -ne 0) {
        throw 'Post-trade authoritative OKX Demo preflight did not confirm zero exposure'
    }
}
if ($chainFailure) { throw $chainFailure }
