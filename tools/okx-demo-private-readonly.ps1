[CmdletBinding()]
param(
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env.local'),
    [int]$TimeoutSeconds = 20,
    [string]$WebSocketUrl = 'wss://wspap.okx.com:8443/ws/v5/private'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-EnvFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing env file: $Path" }
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

function Send-Json([Net.WebSockets.ClientWebSocket]$Socket, [object]$Value, [Threading.CancellationToken]$Token) {
    $json = $Value | ConvertTo-Json -Compress -Depth 8
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $segment = [ArraySegment[byte]]::new($bytes)
    $Socket.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true, $Token).GetAwaiter().GetResult() | Out-Null
}

function Receive-Json([Net.WebSockets.ClientWebSocket]$Socket, [Threading.CancellationToken]$Token) {
    $buffer = [byte[]]::new(65536)
    $stream = [IO.MemoryStream]::new()
    try {
        do {
            $segment = [ArraySegment[byte]]::new($buffer)
            $result = $Socket.ReceiveAsync($segment, $Token).GetAwaiter().GetResult()
            if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) {
                throw 'OKX closed the private WebSocket before qualification completed'
            }
            $stream.Write($buffer, 0, $result.Count)
            if ($stream.Length -gt 1048576) { throw 'Private WebSocket message exceeded 1 MiB' }
        } while (-not $result.EndOfMessage)
        return [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
    } finally {
        $stream.Dispose()
    }
}

$values = Read-EnvFile $EnvFile
$apiKey = Require-Value $values 'OKX_DEMO_API_KEY'
$secretKey = Require-Value $values 'OKX_DEMO_SECRET_KEY'
$passphrase = Require-Value $values 'OKX_DEMO_PASSPHRASE'
$entity = Require-Value $values 'OKX_ENTITY'
if ($entity -ne 'global') { throw 'This qualified probe currently supports OKX_ENTITY=global only' }
if ($TimeoutSeconds -lt 5 -or $TimeoutSeconds -gt 120) { throw 'TimeoutSeconds must be between 5 and 120' }
$wsUri = [Uri]$WebSocketUrl
if ($wsUri.Scheme -ne 'wss' -or $wsUri.Host -ne 'wspap.okx.com' -or
    $wsUri.AbsolutePath -ne '/ws/v5/private' -or $wsUri.Port -notin @(443, 8443) -or
    $wsUri.Query -or $wsUri.Fragment) {
    throw 'WebSocketUrl must be the fixed OKX Demo private WSS endpoint on port 443 or 8443'
}

$timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString([Globalization.CultureInfo]::InvariantCulture)
$hmac = [Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($secretKey))
try {
    $signature = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($timestamp + 'GET/users/self/verify')))
} finally {
    $hmac.Dispose()
}

$socket = [Net.WebSockets.ClientWebSocket]::new()
$socket.Options.Proxy = [Net.WebRequest]::DefaultWebProxy
$timeout = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
try {
    $socket.ConnectAsync($wsUri, $timeout.Token).GetAwaiter().GetResult() | Out-Null
    Send-Json $socket ([ordered]@{ op = 'login'; args = @([ordered]@{
        apiKey = $apiKey; passphrase = $passphrase; timestamp = $timestamp; sign = $signature
    }) }) $timeout.Token
    $login = Receive-Json $socket $timeout.Token
    $loginCode = if ('code' -in $login.PSObject.Properties.Name) { [string]$login.code } else { '0' }
    if ([string]$login.event -ne 'login' -or $loginCode -ne '0') {
        throw "OKX private WebSocket login rejected with code $loginCode"
    }

    Send-Json $socket ([ordered]@{ op = 'subscribe'; args = @(
        [ordered]@{ channel = 'orders'; instType = 'ANY' },
        [ordered]@{ channel = 'account' },
        [ordered]@{ channel = 'positions'; instType = 'ANY' }
    ) }) $timeout.Token

    $acks = @{}
    $snapshots = @{}
    while ($acks.Count -lt 3 -or -not $snapshots.ContainsKey('account') -or -not $snapshots.ContainsKey('positions')) {
        $message = Receive-Json $socket $timeout.Token
        $event = if ('event' -in $message.PSObject.Properties.Name) { [string]$message.event } else { '' }
        if ($event -eq 'error') {
            $errorCode = if ('code' -in $message.PSObject.Properties.Name) { [string]$message.code } else { 'missing' }
            throw "OKX private WebSocket error code $errorCode"
        }
        if ($event -eq 'subscribe') {
            $subscribeCode = if ('code' -in $message.PSObject.Properties.Name) { [string]$message.code } else { '0' }
            if ($subscribeCode -ne '0') { throw "OKX subscription rejected with code $subscribeCode" }
            $acks[[string]$message.arg.channel] = $true
            continue
        }
        if ('arg' -notin $message.PSObject.Properties.Name -or $null -eq $message.arg -or
            'channel' -notin $message.arg.PSObject.Properties.Name -or
            [string]::IsNullOrWhiteSpace([string]$message.arg.channel)) { continue }
        $channel = [string]$message.arg.channel
        $eventType = if ('eventType' -in $message.PSObject.Properties.Name) { [string]$message.eventType } else { '' }
        if ($channel -in @('account', 'positions') -and $eventType -eq 'snapshot') {
            $snapshots[$channel] = @($message.data).Count
        }
    }

    [ordered]@{
        qualified = $true
        environment = 'demo'
        entity = 'global'
        private_ws_host = 'wspap.okx.com'
        private_ws_port = $wsUri.Port
        login = 'acknowledged'
        subscribed_channels = @($acks.Keys | Sort-Object)
        orders_initial_snapshot_expected = $false
        account_snapshot_rows = [int]$snapshots.account
        position_snapshot_rows = [int]$snapshots.positions
        writes_sent = 0
    } | ConvertTo-Json -Depth 4
} finally {
    if ($socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
        try { $socket.CloseAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'qualification complete', [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null } catch {}
    }
    $timeout.Dispose()
    $socket.Dispose()
    $signature = $null
    $apiKey = $null
    $secretKey = $null
    $passphrase = $null
}
