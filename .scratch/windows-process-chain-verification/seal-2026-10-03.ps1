[CmdletBinding()]
param([string]$RunDirectory = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not $RunDirectory) { $RunDirectory = Join-Path $PSScriptRoot 'run-2026-10-03-9600' }
$run = (Resolve-Path -LiteralPath $RunDirectory).Path
function Get-CollectorSourceIdentity {
    $paths = @(& git -C $root ls-files --cached --others --exclude-standard -- src python tools build.zig build.zig.zon)
    if ($LASTEXITCODE -ne 0) { throw 'Collector source manifest unavailable' }
    $manifest = foreach ($path in ($paths | Sort-Object -CaseSensitive -Unique)) {
        $file = Join-Path $root $path
        $hash = if (Test-Path -LiteralPath $file -PathType Leaf) { (Get-FileHash $file).Hash.ToLowerInvariant() } else { 'missing' }
        "$path`t$hash"
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($manifest -join "`n"))))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
$collectorSource = Get-CollectorSourceIdentity
$originalPath = Join-Path $PSScriptRoot 'report-demolive-2026-10-03-parser-failed.json'
if ((Get-FileHash $originalPath).Hash.ToLowerInvariant() -ne '1c5257e3074291eb702204aa8e7daebbf427ed20e7d706d3040844bf1615ad42') { throw 'Original report changed' }
$report = Get-Content $originalPath -Raw | ConvertFrom-Json
if ($report.failure -ne 'Live economic evidence missing') { throw 'Different failure requires separate investigation' }
foreach ($mode in @('offline','readonly')) {
    $prior = Get-Content (Join-Path $PSScriptRoot "report-$mode-2026-10-03-9939110d.json") -Raw | ConvertFrom-Json
    foreach ($field in @('revision','source_tree_sha256','acceptance_schema','journal_schema','state_schema','schema_registry','venue','environment')) {
        if ($prior.$field -ne $report.$field) { throw "Execution evidence mismatch: $mode/$field" }
    }
    if ($mode -eq 'offline' -and $prior.offline -ne 'passed') { throw 'Offline evidence missing' }
    if ($mode -eq 'readonly' -and ($prior.read_only -ne 'passed' -or $prior.account_uid_sha256 -ne $report.account_uid_sha256)) { throw 'Read-only evidence missing' }
}
$catalog = Get-Content (Join-Path $PSScriptRoot 'durable-files-2026-10-03.json') -Raw | ConvertFrom-Json
function Assert-DurableFiles {
    $actual = @(Get-ChildItem -LiteralPath (Join-Path $run 'engine'),(Join-Path $run 'execution') -File -Recurse | ForEach-Object { $_.FullName.Substring($run.Length+1).Replace('\','/') } | Sort-Object -CaseSensitive)
    $expected = @($catalog.path | Sort-Object -CaseSensitive)
    if (($actual -join "`n") -cne ($expected -join "`n")) { throw 'Durable evidence file set changed' }
    foreach ($file in $catalog) {
        if ((Get-FileHash -LiteralPath (Join-Path $run $file.path)).Hash.ToLowerInvariant() -ne $file.sha256) { throw "Durable evidence changed: $($file.path)" }
    }
}
Assert-DurableFiles
Push-Location $root
try { & zig build windows-demo-bin; if ($LASTEXITCODE -ne 0) { throw 'Collector build failed' } }
finally { Pop-Location }
$binary = Join-Path $root 'zig-out/bin/ringwin-windows-demo.exe'
$lines = @(& $binary --windows-demo-evidence (Join-Path $run 'engine') (Join-Path $run 'execution'))
if ($LASTEXITCODE -ne 0) { throw 'Recovery failed' }
$recovered = @($lines | Where-Object { $_ -match '^windows_demo_recovered=passed replay_send_capability=false durable_dispatches=2$' })
if ($recovered.Count -ne 1) { throw 'Complete durable dispatch set missing' }
Assert-DurableFiles
$sealedOrders = @()
$fills = @()
$economics = $null
foreach ($line in $lines) {
    if ($line -match '^windows_demo_order local_id=(\d+) client_id=(RWN1[A-F0-9]{28}) state=filled quantity=(\d+)$') {
        $sealedOrders += [ordered]@{ local_id=$matches[1]; client_id=$matches[2]; state='filled'; quantity=$matches[3] }
    } elseif ($line -match '^windows_demo_fill identity=(\d+) local_order_id=(\d+) quantity=(\d+)$') {
        $fills += [ordered]@{ identity=$matches[1]; local_order_id=$matches[2]; quantity=$matches[3] }
    } elseif ($line -match '^windows_demo_economics fee_micros=(-?\d+) replay_digest=([0-9a-f]{64}) strategy_identity=(\d+) config_version=(\d+)$') {
        if ($economics) { throw 'Duplicate economic summary' }
        $economics = @($matches[1],$matches[2],$matches[3],$matches[4])
    }
}
if ($sealedOrders.Count -ne 2 -or $fills.Count -ne $report.live_fills.Count -or -not $economics) { throw 'Incomplete recovery' }
if (@($sealedOrders.client_id | Sort-Object -Unique).Count -ne 2 -or @($sealedOrders.local_id | Sort-Object -Unique).Count -ne 2 -or @($fills.identity | Sort-Object -Unique).Count -ne $fills.Count) { throw 'Duplicate identities' }
if ($economics[0] -ne $report.live_fees[0].fee_micros -or $economics[1] -ne $report.live_replay_digest -or [int]$economics[2] -ne $report.observed_strategy_identity -or [int]$economics[3] -ne $report.observed_config_version) { throw 'Recovered economics differ from original run' }
foreach ($fill in $fills) {
    $prior = @($report.live_fills | Where-Object { $_.identity -eq $fill.identity -and $_.local_order_id -eq $fill.local_order_id -and $_.quantity -eq $fill.quantity })
    if ($prior.Count -ne 1 -or [long]$fill.quantity -le 0 -or $fill.local_order_id -notin $sealedOrders.local_id) { throw 'Recovered Fill mismatch' }
}
# Existing read-only API helper; no trading endpoints are called.
$baseline = (. (Join-Path $root 'tools/okx-demo-preflight.ps1')) | ConvertFrom-Json
if (-not $baseline.qualified -or $baseline.account_uid_sha256 -ne $report.account_uid_sha256 -or $baseline.pending_orders -ne 0 -or $baseline.pending_algo_orders -ne 0 -or $baseline.open_positions -ne 0 -or $baseline.liabilities -ne 0 -or @($baseline.funded_currencies | Where-Object { $_ -ne 'USDT' }).Count -ne 0) { throw 'Account is not reconciled to zero exposure' }
$venueOrders = @()
foreach ($order in $sealedOrders) {
    $applied = [long]0
    foreach ($fill in $fills) { if ($fill.local_order_id -eq $order.local_id) { $applied += [long]$fill.quantity } }
    if ([long]$applied -ne [long]$order.quantity) { throw 'Applied Fill total differs from terminal order' }
    $rows = @((Invoke-OkxGet "/api/v5/trade/order?instId=BTC-USDT&clOrdId=$($order.client_id)").data)
    if ($rows.Count -ne 1) { throw 'Missing authoritative order' }
    $row = $rows[0]
    $side = if ($order.local_id -eq '1') { 'buy' } else { 'sell' }
    if ($row.clOrdId -ne $order.client_id -or $row.instId -ne 'BTC-USDT' -or $row.state -ne 'filled' -or $row.side -ne $side -or [decimal]$row.accFillSz * 100000000 -ne [decimal]$order.quantity -or [decimal]$row.avgPx * [decimal]$row.accFillSz -gt 25) { throw 'Authoritative terminal order mismatch' }
    $venueOrders += [ordered]@{ local_id=$order.local_id; client_id=$row.clOrdId; order_id=$row.ordId; side=$row.side; state=$row.state; filled_btc=$row.accFillSz; average_price_usdt=$row.avgPx; fee=$row.fee; fee_currency=$row.feeCcy; created_at_unix_ms=$row.cTime; updated_at_unix_ms=$row.uTime }
}
if (@($venueOrders.order_id | Sort-Object -Unique).Count -ne 2) { throw 'Duplicate venue orders' }
$buy = $venueOrders[0]
$sell = $venueOrders[1]
if ($buy.fee_currency -ne 'BTC' -or $sell.fee_currency -ne 'USDT' -or [decimal]$buy.filled_btc + [decimal]$buy.fee -ne [decimal]$sell.filled_btc -or [Math]::Ceiling(-[decimal]$sell.fee * 1000000) -ne [decimal]$economics[0]) { throw 'Net quantity or fee conservation mismatch' }
foreach ($order in $venueOrders) {
    if ([long]$order.created_at_unix_ms -lt 1790993663000 -or [long]$order.updated_at_unix_ms -ge 1790995463000) { throw 'Order outside authorized 30-minute window' }
}
if ((Get-CollectorSourceIdentity) -ne $collectorSource) { throw 'Collector source changed during collection' }
$unresolved = @($venueOrders | Where-Object { $_.state -ne 'filled' }).Count
# Recovery requires exactly two dispatch proofs, each fully matched to one engine
# command; the two exact wire-ID GETs above authoritatively resolve that entire set.
$report.live_order_ids = $sealedOrders
$report.order_writes = $sealedOrders.Count
$report.observed_roles = $report.requested_roles
$report.demo_live = 'passed'
$report.final_reconciliation = 'passed'
$report.windows_process_chain_verified = 'passed'
$report.proof_gap = $null
$report.PSObject.Properties.Remove('failure')
$report | Add-Member -NotePropertyName collection -NotePropertyValue ([ordered]@{
    method='retrospective_durable_recovery_and_authoritative_get'; observed_at_utc=[DateTime]::UtcNow.ToString('o'); revision=(& git -C $root rev-parse HEAD).Trim(); source_tree_sha256=$collectorSource; seal_script_sha256=(Get-FileHash $PSCommandPath).Hash.ToLowerInvariant(); build_command='zig build windows-demo-bin'; binary_sha256=(Get-FileHash $binary).Hash.ToLowerInvariant(); original_failed_report='report-demolive-2026-10-03-parser-failed.json'; original_failed_report_sha256=(Get-FileHash $originalPath).Hash.ToLowerInvariant(); durable_file_catalog='durable-files-2026-10-03.json'; durable_file_catalog_sha256=(Get-FileHash (Join-Path $PSScriptRoot 'durable-files-2026-10-03.json')).Hash.ToLowerInvariant(); replay_send_capability=$false; order_writes=0; unresolved_dispatches=$unresolved; qualification_scope='Original execution revision/source_tree_sha256 only; collector changes are not online-qualified'; terminal_run_evidence='Original collector reached Live economic evidence missing only after successful five-role live and zero-exposure postflight checks'; authorized_start_utc='2026-10-03T02:14:23Z'; authorized_deadline_utc='2026-10-03T02:44:23Z'; authoritative_orders=$venueOrders; account_postflight=$baseline
})
$json = ($report | ConvertTo-Json -Depth 10) -replace "`r`n", "`n"
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'report-demolive-2026-10-03-recovered.json'), $json + "`n", [Text.UTF8Encoding]::new($false))
Write-Output "windows_process_chain_verified=$($report.windows_process_chain_verified) execution_revision=$($report.revision) production_qualification=false"
