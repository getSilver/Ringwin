[CmdletBinding()]
param(
    [Parameter(Mandatory)] [switch]$SystemOwnerAuthorized,
    [switch]$InspectOnly,
    [switch]$MarketCleanup,
    [decimal]$ObservedExchangeFloor = 0,
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env.local'),
    [string]$ExpectedUidSha256 = 'e52bb9f5cda58fc03db5ba5b93de42450d7d69030d618c8dd8aae4adc5b70952'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $SystemOwnerAuthorized) { throw 'Demo cleanup requires SystemOwner authorization' }
if ($MarketCleanup -and $ObservedExchangeFloor -gt 0) { throw 'Market cleanup cannot use a limit price floor' }
$preflight = & (Join-Path $PSScriptRoot 'okx-demo-preflight.ps1') -EnvFile $EnvFile | ConvertFrom-Json
if (-not $preflight.qualified -or $preflight.account_uid_sha256 -ne $ExpectedUidSha256 -or $preflight.pending_orders -ne 0 -or $preflight.open_positions -ne 0 -or $preflight.liabilities -ne 0) { throw 'Demo cleanup preflight rejected' }

$values = @{}
foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $EnvFile))) {
    if ($line -notmatch '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { continue }
    $value = $matches[2]
    if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) { $value = $value.Substring(1, $value.Length - 2) }
    $values[$matches[1]] = $value
}
$base = ([string]$values.OKX_DEMO_REST_BASE_URL).TrimEnd('/')
$culture = [Globalization.CultureInfo]::InvariantCulture
function Invoke-Private([string]$Method, [string]$Path, [string]$Body = '') {
    $timestamp = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $culture)
    $payload = $timestamp + $Method + $Path + $Body
    $hmac = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes([string]$values.OKX_DEMO_SECRET_KEY))
    try { $signature = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))) } finally { $hmac.Dispose() }
    $headers = @{ 'OK-ACCESS-KEY'=[string]$values.OKX_DEMO_API_KEY; 'OK-ACCESS-SIGN'=$signature; 'OK-ACCESS-TIMESTAMP'=$timestamp; 'OK-ACCESS-PASSPHRASE'=[string]$values.OKX_DEMO_PASSPHRASE; 'x-simulated-trading'='1'; 'Content-Type'='application/json' }
    try { $response = Invoke-RestMethod -Method $Method -Uri ($base + $Path) -Headers $headers -Body $(if ($Body) { $Body } else { $null }) } finally { $headers.Clear() }
    if ([string]$response.code -ne '0') {
        $row = @($response.data)[0]
        throw "OKX request rejected: $Path code=$($response.code) sCode=$($row.sCode) sMsg=$($row.sMsg)"
    }
    return $response
}

try {
    $balance = @((Invoke-Private 'GET' '/api/v5/account/balance?ccy=BTC,USDT').data | ForEach-Object { @($_.details) } | Where-Object { $_.ccy -eq 'BTC' })[0]
    if ($null -eq $balance) { throw 'BTC balance row missing' }
    $available = [decimal]::Parse([string]$balance.availBal, $culture)
    $cash = [decimal]::Parse([string]$balance.cashBal, $culture)
    if ($available -le 0 -or $available -ne $cash) { throw 'BTC balance unavailable or held' }
    $rules = @((Invoke-Private 'GET' '/api/v5/account/instruments?instType=SPOT&instId=BTC-USDT').data)[0]
    $lot = [decimal]::Parse([string]$rules.lotSz, $culture)
    $minimum = [decimal]::Parse([string]$rules.minSz, $culture)
    $size = [Math]::Floor($available / $lot) * $lot
    if ($size -lt $minimum -or $size -ne $available) { throw 'Residual BTC is not exactly tradable' }
    $ticker = @((Invoke-RestMethod -Method Get -Uri "$base/api/v5/market/ticker?instId=BTC-USDT").data)[0]
    $limits = @((Invoke-RestMethod -Method Get -Uri "$base/api/v5/public/price-limit?instId=BTC-USDT").data)[0]
    $bid = [decimal]::Parse([string]$ticker.bidPx, $culture)
    $tick = [decimal]::Parse([string]$rules.tickSz, $culture)
    $lower = [decimal]::Parse([string]$limits.sellLmt, $culture)
    $price = [Math]::Floor(($bid * [decimal]0.999) / $tick) * $tick
    if ($ObservedExchangeFloor -gt 0) {
        $floor = [Math]::Ceiling($ObservedExchangeFloor / $tick) * $tick
        if ($floor -gt $bid) { throw "Exchange sell floor exceeds current bid: floor=$floor bid=$bid" }
        if ($price -lt $floor) { $price = $floor }
    }
    if ($InspectOnly) {
        [ordered]@{ size=$size.ToString($culture); bid=$bid.ToString($culture); lower=$lower.ToString($culture); price=$price.ToString($culture); notional=($price * $size).ToString($culture) } | ConvertTo-Json -Compress
        return
    }
    if ($bid -le 0 -or $bid * $size -gt 25 -or (-not $MarketCleanup -and ($price -lt $lower -or $price -le 0 -or $price * $size -gt 25))) { throw "Protected sell violates price or notional boundary: bid=$bid lower=$lower price=$price notional=$($price * $size)" }
    $clientId = 'RWRC' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmssfff', $culture)
    $body = if ($MarketCleanup) {
        [ordered]@{ instId='BTC-USDT'; tdMode='cash'; clOrdId=$clientId; side='sell'; ordType='market'; tgtCcy='base_ccy'; banAmend='true'; sz=$size.ToString($culture) } | ConvertTo-Json -Compress
    } else {
        [ordered]@{ instId='BTC-USDT'; tdMode='cash'; clOrdId=$clientId; side='sell'; ordType='ioc'; sz=$size.ToString($culture); px=$price.ToString($culture); pxAmendType='0' } | ConvertTo-Json -Compress
    }
    try { $result = Invoke-Private 'POST' '/api/v5/trade/order' $body }
    catch { throw "Demo cleanup dispatch uncertain: client_id=$clientId; $($_.Exception.Message)" }
    $row = @($result.data)[0]
    if ([string]$row.sCode -ne '0' -or [string]::IsNullOrWhiteSpace([string]$row.ordId)) { throw "Demo cleanup rejected sCode=$($row.sCode) client_id=$clientId" }
    $filled = $false
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $order = @((Invoke-Private 'GET' "/api/v5/trade/order?instId=BTC-USDT&ordId=$($row.ordId)").data)[0]
        if ([string]$order.state -eq 'filled' -and [decimal]::Parse([string]$order.accFillSz, $culture) -eq $size) { $filled = $true; break }
        if ([string]$order.state -in @('canceled', 'rejected')) { throw "Demo cleanup terminal without full fill: order_id=$($row.ordId) state=$($order.state)" }
        Start-Sleep -Milliseconds 500
    }
    if (-not $filled) { throw "Demo cleanup terminal unconfirmed: order_id=$($row.ordId)" }
    $after = & (Join-Path $PSScriptRoot 'okx-demo-preflight.ps1') -EnvFile $EnvFile | ConvertFrom-Json
    if ($after.account_uid_sha256 -ne $ExpectedUidSha256 -or $after.pending_orders -ne 0 -or $after.open_positions -ne 0 -or $after.liabilities -ne 0 -or
        @($after.funded_currencies | Where-Object { $_ -ne 'USDT' }).Count -ne 0) { throw "Demo cleanup zero exposure unconfirmed: order_id=$($row.ordId)" }
    [ordered]@{ completed=$true; client_id=$clientId; order_id=[string]$row.ordId; size=$size.ToString($culture); price=$(if ($MarketCleanup) { [string]$order.avgPx } else { $price.ToString($culture) }); terminal='filled'; zero_exposure=$true } | ConvertTo-Json -Compress
} finally { $values.Clear(); $body=$null }
