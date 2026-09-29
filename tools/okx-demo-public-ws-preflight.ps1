[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$socket = [Net.WebSockets.ClientWebSocket]::new()
$timeout = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(20))
try {
    $socket.Options.Proxy = [Net.WebRequest]::DefaultWebProxy
    $null = $socket.ConnectAsync([Uri]'wss://wspap.okx.com/ws/v5/public', $timeout.Token).GetAwaiter().GetResult()
    $request = [Text.Encoding]::UTF8.GetBytes('{"op":"subscribe","args":[{"channel":"tickers","instId":"BTC-USDT"}]}')
    $null = $socket.SendAsync([ArraySegment[byte]]::new($request), [Net.WebSockets.WebSocketMessageType]::Text, $true, $timeout.Token).GetAwaiter().GetResult()
    $buffer = [byte[]]::new(32768)
    $subscribed = $false
    $tick = $false
    for ($attempt = 0; $attempt -lt 8 -and -not $tick; $attempt++) {
        $message = [IO.MemoryStream]::new()
        do {
            $received = $socket.ReceiveAsync([ArraySegment[byte]]::new($buffer), $timeout.Token).GetAwaiter().GetResult()
            if ($received.MessageType -ne [Net.WebSockets.WebSocketMessageType]::Text) { throw 'Unexpected public WS frame type' }
            $message.Write($buffer, 0, $received.Count)
            if ($message.Length -gt 32768) { throw 'Public WS frame too large' }
        } until ($received.EndOfMessage)
        $frame = [Text.Encoding]::UTF8.GetString($message.ToArray()) | ConvertFrom-Json
        if ($frame.PSObject.Properties['event'] -and $frame.event -eq 'error') { throw 'Public WS subscription rejected' }
        if (-not $frame.PSObject.Properties['arg']) { continue }
        if ($frame.PSObject.Properties['event'] -and $frame.event -eq 'subscribe' -and $frame.arg.channel -eq 'tickers' -and $frame.arg.instId -eq 'BTC-USDT') { $subscribed = $true }
        if ($frame.arg.channel -eq 'tickers' -and $frame.arg.instId -eq 'BTC-USDT' -and $frame.PSObject.Properties['data'] -and @($frame.data).Count -gt 0) { $tick = $true }
    }
    if (-not $subscribed -or -not $tick) { throw 'Public WS subscription or tick missing' }
    'public_ws=passed environment=demo channel=tickers instrument=BTC-USDT order_writes=0'
} finally {
    $socket.Dispose()
    $timeout.Dispose()
}
