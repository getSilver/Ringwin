[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env.local')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$MaxNotionalUsdt = 25
$AllowedInstruments = @('BTC-USDT', 'BTC-USDT-SWAP')

function Read-EnvFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing env file: $Path"
    }

    $values = @{}
    foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $Path))) {
        if ($line -notmatch '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$') { continue }
        $value = $matches[2]
        if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$matches[1]] = $value
    }
    return $values
}

function Require-Value([hashtable]$Values, [string]$Name) {
    if (-not $Values.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace($Values[$Name])) {
        throw "Missing or empty $Name"
    }
    return [string]$Values[$Name]
}

function Test-Zero([object]$Value) {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $true }
    $number = [decimal]0
    return [decimal]::TryParse([string]$Value, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -and $number -eq 0
}

$envValues = Read-EnvFile $EnvFile
$apiKey = Require-Value $envValues 'OKX_DEMO_API_KEY'
$secretKey = Require-Value $envValues 'OKX_DEMO_SECRET_KEY'
$passphrase = Require-Value $envValues 'OKX_DEMO_PASSPHRASE'
$baseUrl = (Require-Value $envValues 'OKX_DEMO_REST_BASE_URL').TrimEnd('/')
$entity = Require-Value $envValues 'OKX_ENTITY'

$baseUri = [Uri]$baseUrl
if ($baseUri.Scheme -ne 'https' -or ($baseUri.Host -ne 'okx.com' -and -not $baseUri.Host.EndsWith('.okx.com', [StringComparison]::OrdinalIgnoreCase))) {
    throw 'OKX_DEMO_REST_BASE_URL must be an HTTPS okx.com origin'
}
if ($baseUri.AbsolutePath -ne '/' -or $baseUri.Query -or $baseUri.Fragment) {
    throw 'OKX_DEMO_REST_BASE_URL must not contain a path, query, or fragment'
}

$publicTime = Invoke-RestMethod -Method Get -Uri "$baseUrl/api/v5/public/time"
if ($publicTime.code -ne '0' -or @($publicTime.data).Count -ne 1) { throw 'OKX public time check failed' }
$serverMs = [int64]$publicTime.data[0].ts
$localMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$clockOffsetMs = $serverMs - $localMs
if ([Math]::Abs($clockOffsetMs) -gt 5000) { throw "Local clock offset exceeds 5000 ms: $clockOffsetMs" }

function Invoke-OkxGet([string]$RequestPath) {
    $timestamp = [DateTimeOffset]::UtcNow.AddMilliseconds($clockOffsetMs).ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
    $payload = $timestamp + 'GET' + $RequestPath
    $hmac = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($secretKey))
    try {
        $signature = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload)))
    } finally {
        $hmac.Dispose()
    }

    $headers = @{
        'OK-ACCESS-KEY' = $apiKey
        'OK-ACCESS-SIGN' = $signature
        'OK-ACCESS-TIMESTAMP' = $timestamp
        'OK-ACCESS-PASSPHRASE' = $passphrase
        'x-simulated-trading' = '1'
    }
    try {
        $response = Invoke-RestMethod -Method Get -Uri ($baseUrl + $RequestPath) -Headers $headers
    } catch {
        $status = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $code = 'unknown'
        $message = 'no response body'
        if (-not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
            try {
                $errorBody = $_.ErrorDetails.Message | ConvertFrom-Json
                $code = [string]$errorBody.code
                $message = [string]$errorBody.msg
            } catch {
                $message = 'non-JSON response body'
            }
        }
        throw "OKX read-only request failed: $RequestPath; HTTP $status; code=$code; msg=$message"
    } finally {
        $headers.Clear()
        $signature = $null
        $payload = $null
    }
    if ($response.code -ne '0') { throw "OKX rejected read-only request $RequestPath with code $($response.code)" }
    return $response
}

$configResponse = Invoke-OkxGet '/api/v5/account/config'
if (@($configResponse.data).Count -ne 1) { throw 'Expected one account/config row' }
$config = $configResponse.data[0]
$permissions = @([string]$config.perm -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() })
if ('trade' -notin $permissions -or ('read_only' -notin $permissions -and 'read' -notin $permissions)) {
    throw 'Demo API key must have Read and Trade permissions'
}
if ('withdraw' -in $permissions) { throw 'Demo API key must not have Withdraw permission' }
if ([string]$config.acctLv -ne '2') { throw "Account mode must be Futures mode (acctLv=2), got acctLv=$($config.acctLv)" }
if ([string]$config.posMode -ne 'net_mode') { throw "Position mode must be net_mode, got posMode=$($config.posMode)" }
if ([bool]$config.autoLoan -or [bool]$config.enableSpotBorrow) { throw 'Borrowing must be disabled' }

$spot = @( (Invoke-OkxGet '/api/v5/account/instruments?instType=SPOT&instId=BTC-USDT').data )
$swap = @( (Invoke-OkxGet '/api/v5/account/instruments?instType=SWAP&instId=BTC-USDT-SWAP').data )
if ($spot.Count -ne 1 -or [string]$spot[0].instId -ne 'BTC-USDT' -or [string]$spot[0].state -ne 'live') {
    throw 'BTC-USDT is not uniquely available and live for this account'
}
if ($swap.Count -ne 1 -or [string]$swap[0].instId -ne 'BTC-USDT-SWAP' -or [string]$swap[0].state -notin @('live', 'post_only')) {
    throw 'BTC-USDT-SWAP is not uniquely available for this account'
}

$leverage = @( (Invoke-OkxGet '/api/v5/account/leverage-info?instId=BTC-USDT-SWAP&mgnMode=isolated').data )
if ($leverage.Count -lt 1 -or @($leverage | Where-Object { $_.instId -eq 'BTC-USDT-SWAP' -and $_.mgnMode -eq 'isolated' -and $_.posSide -eq 'net' }).Count -lt 1) {
    throw 'Missing isolated/net leverage configuration for BTC-USDT-SWAP'
}

$positions = @( (Invoke-OkxGet '/api/v5/account/positions').data | Where-Object { -not (Test-Zero $_.pos) })
if ($positions.Count -ne 0) { throw "Preflight requires zero open positions; found $($positions.Count)" }
$orders = @( (Invoke-OkxGet '/api/v5/trade/orders-pending').data )
if ($orders.Count -ne 0) { throw "Preflight requires zero pending orders; found $($orders.Count)" }
$algoOrders = @(@('conditional', 'oco', 'trigger', 'move_order_stop', 'iceberg', 'twap', 'chase') | ForEach-Object {
    @((Invoke-OkxGet "/api/v5/trade/orders-algo-pending?ordType=$_").data)
})
if ($algoOrders.Count -ne 0) { throw "Preflight requires zero pending algo orders; found $($algoOrders.Count)" }

$balanceRows = @( (Invoke-OkxGet '/api/v5/account/balance').data )
$liabilities = @($balanceRows | ForEach-Object { @($_.details) } | Where-Object {
    -not (Test-Zero $_.liab) -or -not (Test-Zero $_.isoLiab) -or -not (Test-Zero $_.crossLiab)
})
if ($liabilities.Count -ne 0) { throw "Preflight requires zero liabilities; found $($liabilities.Count)" }

$nonZeroCurrencies = @($balanceRows | ForEach-Object { @($_.details) } | Where-Object { -not (Test-Zero $_.eq) } | ForEach-Object { [string]$_.ccy } | Sort-Object -Unique)
[ordered]@{
    qualified = $true
    environment = 'demo'
    entity = $entity
    rest_host = $baseUri.Host
    simulated_header = 1
    clock_offset_ms = $clockOffsetMs
    permissions = $permissions
    account_mode = [string]$config.acctLv
    position_mode = [string]$config.posMode
    contract_isolated_mode = [string]$config.ctIsoMode
    allowed_instruments = $AllowedInstruments
    max_order_notional_usdt = $MaxNotionalUsdt
    open_positions = 0
    pending_orders = 0
    pending_algo_orders = 0
    liabilities = 0
    funded_currencies = $nonZeroCurrencies
} | ConvertTo-Json -Depth 4
