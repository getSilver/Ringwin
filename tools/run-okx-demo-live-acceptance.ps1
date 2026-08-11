[CmdletBinding()]
param(
    [switch]$DemoLive,
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env.local')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $DemoLive) { throw 'Explicit -DemoLive authorization is required' }

$preflight = & (Join-Path $PSScriptRoot 'okx-demo-preflight.ps1') -EnvFile $EnvFile | ConvertFrom-Json
if (-not $preflight.qualified -or $preflight.environment -ne 'demo' -or $preflight.pending_orders -ne 0 -or
    $preflight.pending_algo_orders -ne 0 -or $preflight.open_positions -ne 0 -or $preflight.liabilities -ne 0) {
    throw 'OKX Demo preflight did not qualify a clean account'
}
if (@($preflight.funded_currencies | Where-Object { $_ -ne 'USDT' }).Count -ne 0) {
    throw 'Demo acceptance requires a zero BTC baseline and USDT-only funding'
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

$build = Join-Path $PSScriptRoot '..\.scratch\build\curl-win64-schannel-3'
$source = Join-Path $PSScriptRoot '..\.scratch\build\bootstrap\curl\curl-8.21.0\include'
$previousProxy = $env:HTTPS_PROXY
try {
    $env:RINGWIN_OKX_KEY = [string]$values.OKX_DEMO_API_KEY
    $env:RINGWIN_OKX_SECRET = [string]$values.OKX_DEMO_SECRET_KEY
    $env:RINGWIN_OKX_PASSPHRASE = [string]$values.OKX_DEMO_PASSPHRASE
    $uri = [Uri]'https://openapi.okx.com'
    if (-not [Net.WebRequest]::DefaultWebProxy.IsBypassed($uri)) {
        $env:HTTPS_PROXY = [Net.WebRequest]::DefaultWebProxy.GetProxy($uri).AbsoluteUri
    }
    & zig run (Join-Path $PSScriptRoot '..\src\okx_demo_live_acceptance.zig') `
        (Join-Path $PSScriptRoot '..\src\okx_curl_shim.c') "-I$source" "-L$(Join-Path $build 'lib')" `
        -lc -lcurl -lws2_32 -lcrypt32 -lsecur32 -ladvapi32 -lbcrypt -lwldap32 -lnormaliz -liphlpapi `
        -OReleaseSafe -- --demo-live
    if ($LASTEXITCODE -ne 0) { throw 'OKX Demo live acceptance failed' }
} finally {
    $env:RINGWIN_OKX_KEY = $null
    $env:RINGWIN_OKX_SECRET = $null
    $env:RINGWIN_OKX_PASSPHRASE = $null
    $env:HTTPS_PROXY = $previousProxy
    $values.Clear()
    $final = & (Join-Path $PSScriptRoot 'okx-demo-preflight.ps1') -EnvFile $EnvFile | ConvertFrom-Json
    if ($final.pending_orders -ne 0 -or $final.pending_algo_orders -ne 0 -or $final.open_positions -ne 0 -or $final.liabilities -ne 0 -or
        @($final.funded_currencies | Where-Object { $_ -ne 'USDT' }).Count -ne 0) {
        Write-Error 'Final Demo preflight found residual orders, positions, liabilities, or BTC funding'
    }
}
