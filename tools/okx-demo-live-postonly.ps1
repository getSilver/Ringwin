[CmdletBinding()]
param(
    [Parameter(Mandatory)] [switch]$DemoLive,
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env.local')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $DemoLive) { throw 'Explicit -DemoLive is required' }
& (Join-Path $PSScriptRoot 'okx-demo-preflight.ps1') -EnvFile $EnvFile | Out-Null
& (Join-Path $PSScriptRoot 'okx-demo-private-readonly.ps1') -EnvFile $EnvFile `
    -WebSocketUrl 'wss://wspap.okx.com/ws/v5/private' | Out-Null

$values = @{}
foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $EnvFile))) {
    if ($line -notmatch '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { continue }
    $value = $matches[2]
    if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    $values[$matches[1]] = $value
}
foreach ($name in @('OKX_DEMO_API_KEY','OKX_DEMO_SECRET_KEY','OKX_DEMO_PASSPHRASE','OKX_DEMO_REST_BASE_URL')) {
    if (-not $values.ContainsKey($name) -or [string]::IsNullOrWhiteSpace($values[$name])) { throw "Missing $name" }
}
$base = ([string]$values.OKX_DEMO_REST_BASE_URL).TrimEnd('/')
if ([Uri]$base -notmatch '^https://([a-z0-9-]+\.)*okx\.com/$') { throw 'Invalid Demo REST origin' }

function Invoke-Private([string]$Method, [string]$Path, [string]$Body = '') {
    $timestamp = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
    $payload = $timestamp + $Method + $Path + $Body
    $hmac = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes([string]$values.OKX_DEMO_SECRET_KEY))
    try { $signature = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))) } finally { $hmac.Dispose() }
    $headers = @{
        'OK-ACCESS-KEY'=[string]$values.OKX_DEMO_API_KEY; 'OK-ACCESS-SIGN'=$signature
        'OK-ACCESS-TIMESTAMP'=$timestamp; 'OK-ACCESS-PASSPHRASE'=[string]$values.OKX_DEMO_PASSPHRASE
        'x-simulated-trading'='1'; 'Content-Type'='application/json'
    }
    try {
        $response = Invoke-RestMethod -Method $Method -Uri ($base + $Path) -Headers $headers -Body $Body
    } finally { $headers.Clear(); $signature=$null; $payload=$null }
    if ([string]$response.code -ne '0') { throw "OKX request rejected: $Path code=$($response.code)" }
    return $response
}

$ticker = (Invoke-RestMethod -Uri "$base/api/v5/market/ticker?instId=BTC-USDT").data[0]
$instrument = (Invoke-Private 'GET' '/api/v5/account/instruments?instType=SPOT&instId=BTC-USDT').data[0]
$culture = [Globalization.CultureInfo]::InvariantCulture
$bid = [decimal]::Parse([string]$ticker.bidPx, $culture)
$tick = [decimal]::Parse([string]$instrument.tickSz, $culture)
$lot = [decimal]::Parse([string]$instrument.lotSz, $culture)
$minimum = [decimal]::Parse([string]$instrument.minSz, $culture)
$price = [Math]::Floor(($bid * [decimal]0.90) / $tick) * $tick
$size = [Math]::Ceiling(([decimal]5 / $price) / $lot) * $lot
if ($size -lt $minimum) { $size = $minimum }
$notional = $price * $size
if ($notional -le 0 -or $notional -gt 25) { throw 'Computed order violates 25 USDT limit' }
$clientId = 'RWNA' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmssfff', $culture)
$body = [ordered]@{ instId='BTC-USDT'; tdMode='cash'; clOrdId=$clientId; side='buy'; ordType='post_only'; sz=$size.ToString($culture); px=$price.ToString($culture); pxAmendType='0' } | ConvertTo-Json -Compress
$placed = $false
try {
    $place = Invoke-Private 'POST' '/api/v5/trade/order' $body
    $item = @($place.data)[0]
    if ([string]$item.sCode -ne '0' -or [string]::IsNullOrWhiteSpace([string]$item.ordId)) { throw "Place failed sCode=$($item.sCode)" }
    $placed = $true
    $cancelBody = [ordered]@{ instId='BTC-USDT'; ordId=[string]$item.ordId; clOrdId=$clientId } | ConvertTo-Json -Compress
    $cancel = Invoke-Private 'POST' '/api/v5/trade/cancel-order' $cancelBody
    if ([string]@($cancel.data)[0].sCode -ne '0') { throw "Cancel failed sCode=$(@($cancel.data)[0].sCode)" }
    $placed = $false
} finally {
    if ($placed) {
        try { Invoke-Private 'POST' '/api/v5/trade/cancel-order' ([ordered]@{ instId='BTC-USDT'; clOrdId=$clientId } | ConvertTo-Json -Compress) | Out-Null } catch {}
    }
    $body=$null; $values.Clear()
}
Start-Sleep -Milliseconds 500
& (Join-Path $PSScriptRoot 'okx-demo-preflight.ps1') -EnvFile $EnvFile | Out-Null
[ordered]@{ qualified=$true; environment='demo'; operation='post_only_place_cancel'; instrument='BTC-USDT'; max_notional_usdt=25; cleanup='verified'; filled=$false } | ConvertTo-Json
