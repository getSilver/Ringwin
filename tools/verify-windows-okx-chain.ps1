[CmdletBinding()]
param(
    [ValidateSet('Offline', 'ReadOnly', 'DemoLive')][string]$Mode = 'Offline',
    [switch]$SystemOwnerAuthorized,
    [string]$EnvFile = '', [string]$RestBaseUrl, [string]$Entity, [string]$UidSha256
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$reportDir = Join-Path $root '.scratch\windows-process-chain-verification'
$reportPath = Join-Path $reportDir ("report-{0}.json" -f $Mode.ToLowerInvariant())

function Get-SourceIdentity {
    $paths = @(& git -C $root ls-files --cached --others --exclude-standard -- src python tools build.zig build.zig.zon)
    if ($LASTEXITCODE -ne 0 -or $paths.Count -eq 0) { throw 'Source manifest unavailable' }
    $manifest = foreach ($path in ($paths | Sort-Object -CaseSensitive -Unique)) {
        $file = Join-Path $root $path
        $hash = 'missing'
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $fileSha = [Security.Cryptography.SHA256]::Create()
            $stream = [IO.File]::OpenRead($file)
            try { $hash = ([BitConverter]::ToString($fileSha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
            finally { $stream.Dispose(); $fileSha.Dispose() }
        }
        "$path`t$hash"
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($manifest -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Read-Schema([string]$name) {
    $source = Get-Content -LiteralPath (Join-Path $root 'src\production_contract.zig') -Raw
    $match = [regex]::Match($source, "pub const $name\s*:\s*u\d+\s*=\s*(\d+);")
    if (-not $match.Success) { throw "Schema value unavailable: $name" }
    return [int]$match.Groups[1].Value
}

function Invoke-Checked([string]$command, [string[]]$arguments) {
    if ($command -eq 'zig') {
        . (Join-Path $PSScriptRoot 'protected-demo-launch.ps1')
        return ((Invoke-EmptyInputNative (Get-Command zig -ErrorAction Stop).Source $arguments -CaptureOutput) -split "`r?`n")
    }
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $command @arguments 2>&1 | ForEach-Object { "$_" })
    } finally { $ErrorActionPreference = $previous }
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "$command $($arguments -join ' ') failed (exit $code)" }
    return $lines
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows required' }
if ($Mode -eq 'DemoLive' -and -not $SystemOwnerAuthorized) { throw 'Fresh bounded SystemOwner authorization required' }
$revision = (& git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or -not $revision) { throw 'Git revision unavailable' }
$source = Get-SourceIdentity
$report = [ordered]@{
    schema = 1
    observed_at_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    revision = $revision
    source_tree_sha256 = $source
    acceptance_schema = Read-Schema 'acceptance_schema_version'
    journal_schema = Read-Schema 'journal_schema_version'
    state_schema = Read-Schema 'state_schema_version'
    schema_registry = Read-Schema 'schema_registry_identity'
    environment = 'demo'
    venue = 'okx'
    requested_product = 'BTC-USDT spot'
    observed_product = $null
    requested_strategy = 'windows_verification_python_host'
    requested_strategy_identity = 40
    observed_strategy_identity = $null
    configuration_source = 'src/windows_verification_runtime.zig and demo_authority.Policy'
    requested_config_version = 1
    observed_config_version = $null
    account_uid_sha256 = $null
    requested_roles = 5
    observed_roles = $null
    requested_ipc = 'windows_named_pipe'
    mode = $Mode.ToLowerInvariant()
    windows_durable_adapter = 'not_run'
    windows_credential_adapter = 'not_run'
    offline = 'not_run'
    offline_adapter_tests = 'not_run'
    replay_digest = $null
    market_raw_frames = $null
    private_raw_barrier = $null
    read_only = 'not_run'
    demo_live = 'not_run'
    role_ownership = 'not_run'
    durable_recovery = 'not_run'
    final_reconciliation = 'not_run'
    order_writes = 0
    live_order_ids = @()
    live_fills = @()
    live_fees = @()
    live_replay_digest = $null
    historical_demo_evidence = 'evidence-2026-09-29-demo-round-trip.json'
    proof_gap = 'Current-source offline, read-only, or authorized live economic evidence is incomplete.'
    windows_process_chain_verified = 'blocked'
    production_qualification = $false
}

try {
    if ($Mode -eq 'Offline') {
        $null = Invoke-Checked 'zig' @('build', 'windows-durable')
        $report.windows_durable_adapter = 'passed'
        $null = Invoke-Checked 'zig' @('build', 'windows-credential')
        $report.windows_credential_adapter = 'passed'
        $null = Invoke-Checked 'zig' @('test', (Join-Path $root 'src\okx_live_chain.zig'), '--stack', '67108864')
        $null = Invoke-Checked 'zig' @('test', (Join-Path $root 'src\main.zig'), '--stack', '67108864')
        $lines = Invoke-Checked 'zig' @('build', 'windows-chain')
        $okx = @($lines | Where-Object { $_ -match '^windows_okx_offline=passed ' })
        if ($okx.Count -ne 1 -or $okx[0] -notmatch 'product=BTC-USDT-spot strategy_identity=(\d+) config_version=(\d+) roles=5 ipc=named_pipe market_raw_frames=(\d+) private_raw_barrier=(\d+) spot_atoms=20000 replay_digest=([0-9a-f]{64}) replay_send_capability=false role_ownership=passed durable_recovery=passed') {
            throw 'Complete OKX offline process-chain evidence missing'
        }
        $report.offline_adapter_tests = 'passed'
        $report.observed_product = 'BTC-USDT spot'
        $report.observed_strategy_identity = [int]$matches[1]
        $report.observed_config_version = [int]$matches[2]
        $report.observed_roles = 5
        $report.market_raw_frames = [int]$matches[3]
        $report.private_raw_barrier = [int]$matches[4]
        $report.replay_digest = $matches[5]
        $report.offline = 'passed'
        $report.role_ownership = 'passed'
        $report.durable_recovery = 'passed'
    } else {
        . (Join-Path $PSScriptRoot 'protected-demo-launch.ps1')
        Assert-ProtectedDemoInput $EnvFile
        if ($UidSha256 -notmatch '^[0-9a-f]{64}$' -or -not $RestBaseUrl -or -not $Entity) { throw 'Explicit nonsecret endpoint/entity/account UID hash required' }
        $report.account_uid_sha256 = $UidSha256
        $offlinePath = Join-Path $reportDir 'report-offline.json'
        if (Test-Path -LiteralPath $offlinePath) {
            $prior = Get-Content -LiteralPath $offlinePath -Raw | ConvertFrom-Json
            if ($prior.source_tree_sha256 -eq $source -and $prior.revision -eq $revision -and
                $prior.mode -eq 'offline' -and $prior.venue -eq 'okx' -and
                $prior.acceptance_schema -eq $report.acceptance_schema -and
                $prior.journal_schema -eq $report.journal_schema -and $prior.state_schema -eq $report.state_schema -and
                $prior.schema_registry -eq $report.schema_registry) {
                $report.offline = $prior.offline
                $report.offline_adapter_tests = $prior.offline_adapter_tests
                $report.observed_product = $prior.observed_product
                $report.observed_strategy_identity = $prior.observed_strategy_identity
                $report.observed_config_version = $prior.observed_config_version
                $report.replay_digest = $prior.replay_digest
                $report.market_raw_frames = $prior.market_raw_frames
                $report.private_raw_barrier = $prior.private_raw_barrier
                $report.windows_durable_adapter = $prior.windows_durable_adapter
                $report.windows_credential_adapter = $prior.windows_credential_adapter
                $report.role_ownership = $prior.role_ownership
                $report.durable_recovery = $prior.durable_recovery
            }
        }
        if ($Mode -eq 'DemoLive') {
            if ($report.offline -ne 'passed' -or $report.role_ownership -ne 'passed' -or
                $report.durable_recovery -ne 'passed') { throw 'Current-source OKX process-chain evidence missing' }
            $readonly = Get-Content -LiteralPath (Join-Path $reportDir 'report-readonly.json') -Raw | ConvertFrom-Json
            if ($readonly.source_tree_sha256 -ne $source -or $readonly.revision -ne $revision -or
                $readonly.mode -ne 'readonly' -or $readonly.venue -ne 'okx' -or
                $readonly.read_only -ne 'passed' -or $readonly.account_uid_sha256 -ne $report.account_uid_sha256 -or
                $readonly.acceptance_schema -ne $report.acceptance_schema -or
                $readonly.journal_schema -ne $report.journal_schema -or
                $readonly.state_schema -ne $report.state_schema -or
                $readonly.schema_registry -ne $report.schema_registry) { throw 'Current-source read-only evidence missing' }
            $report.read_only = 'passed'
            $report.order_writes = $null
            $previous = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $lines = @(& (Join-Path $PSScriptRoot 'run-windows-demo-readonly.ps1') -DemoLive -SystemOwnerAuthorized -RestBaseUrl $RestBaseUrl -Entity $Entity -UidSha256 $UidSha256 2>&1 | ForEach-Object { "$_" })
            } finally { $ErrorActionPreference = $previous }
            if ($LASTEXITCODE -ne 0) { throw 'Authorized Windows Demo chain failed' }
            if (-not ($lines -match 'windows_demo_live=passed rest=ok private_ws=ok public_ws=ok roles=5 terminal=ok zero_exposure=ok production_qualification=false') -or -not ($lines -match 'native_demo_preflight=passed account_identity=matched pending_orders=0 pending_algo_orders=0 open_positions=0 liabilities=0 funded_currencies_only_usdt=true') -or -not ($lines -match 'windows_demo_postflight: pending_orders=0 pending_algo_orders=0 open_positions=0 liabilities=0 funded_currencies_only_usdt=true account_identity=matched')) { throw 'Demo terminal or zero-exposure evidence missing' }
            foreach ($line in $lines) {
                if ($line -match '^windows_demo_order local_id=(\d+) client_id=([A-Z0-9]+) state=filled quantity=(\d+)$') {
                    $report.live_order_ids += [ordered]@{ local_id = $matches[1]; client_id = $matches[2]; state = 'filled'; quantity = $matches[3] }
                } elseif ($line -match '^windows_demo_fill identity=(\d+) local_order_id=(\d+) quantity=(\d+)$') {
                    $report.live_fills += [ordered]@{ identity = $matches[1]; local_order_id = $matches[2]; quantity = $matches[3] }
                } elseif ($line -match '^windows_demo_economics fee_micros=(-?\d+) replay_digest=([0-9a-f]{64}) strategy_identity=(\d+) config_version=(\d+)$') {
                    $report.live_fees += [ordered]@{ scope = 'portfolio_total'; fee_micros = $matches[1] }
                    $report.live_replay_digest = $matches[2]
                    if ([int]$matches[3] -ne $report.requested_strategy_identity -or
                        [int]$matches[4] -ne $report.requested_config_version) { throw 'Live strategy configuration mismatch' }
                }
            }
            if ($report.live_order_ids.Count -ne 2 -or $report.live_fills.Count -lt 2 -or
                $report.live_fees.Count -ne 1 -or -not $report.live_replay_digest) { throw 'Live economic evidence missing' }
            $localIds = @($report.live_order_ids | ForEach-Object { $_.local_id })
            $clientIds = @($report.live_order_ids | ForEach-Object { $_.client_id })
            $fillIds = @($report.live_fills | ForEach-Object { $_.identity })
            if (@($localIds | Sort-Object -Unique).Count -ne 2 -or
                @($clientIds | Sort-Object -Unique).Count -ne 2 -or
                @($fillIds | Sort-Object -Unique).Count -ne $fillIds.Count -or
                [long]$report.live_fees[0].fee_micros -le 0) { throw 'Live economic identity or fee mismatch' }
            foreach ($order in $report.live_order_ids) {
                $applied = [long]0
                foreach ($fill in $report.live_fills) {
                    if ($fill.local_order_id -notin $localIds -or [long]$fill.quantity -le 0) { throw 'Fill does not belong to a reported order' }
                    if ($fill.local_order_id -eq $order.local_id) { $applied += [long]$fill.quantity }
                }
                if ($applied -ne [long]$order.quantity) { throw 'Canonical Fill quantity differs from terminal order' }
            }
            $report.order_writes = $report.live_order_ids.Count
            $report.demo_live = 'passed'
            $report.final_reconciliation = 'passed'
            $report.observed_roles = 5
        } else {
            $lines = Invoke-Checked (Join-Path $PSScriptRoot 'run-windows-demo-readonly.ps1') @('-RestBaseUrl',$RestBaseUrl,'-Entity',$Entity,'-UidSha256',$UidSha256)
            if (-not ($lines -match 'windows_demo_readonly=passed.*roles=5 order_writes=0') -or -not ($lines -match 'native_demo_preflight=passed account_identity=matched') -or -not ($lines -match 'windows_demo_postflight: pending_orders=0 pending_algo_orders=0 open_positions=0 liabilities=0 funded_currencies_only_usdt=true account_identity=matched')) { throw 'Read-only role evidence missing' }
            $report.read_only = 'passed'
            $report.observed_roles = 5
        }
    }
    if ((Get-SourceIdentity) -ne $source) { throw 'Source changed during acceptance' }
    if ($report.offline -eq 'passed' -and $report.read_only -eq 'passed' -and
        $report.demo_live -eq 'passed' -and $report.role_ownership -eq 'passed' -and
        $report.durable_recovery -eq 'passed' -and $report.final_reconciliation -eq 'passed' -and
        $report.observed_product -eq $report.requested_product -and
        $report.observed_strategy_identity -eq $report.requested_strategy_identity -and
        $report.observed_config_version -eq $report.requested_config_version -and
        $report.observed_roles -eq 5 -and
        $report.live_order_ids.Count -eq 2 -and $report.live_fills.Count -ge 2 -and $report.live_fees.Count -eq 1 -and
        $report.live_replay_digest) {
        $report.windows_process_chain_verified = 'passed'
        $report.proof_gap = $null
    }
} catch {
    $field = @{ Offline = 'offline'; ReadOnly = 'read_only'; DemoLive = 'demo_live' }[$Mode]
    $report[$field] = 'failed'
    $report.windows_process_chain_verified = 'failed'
    $report.failure = $_.Exception.Message
} finally {
    $json = ($report | ConvertTo-Json -Depth 6) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($reportPath, $json + "`n", [Text.UTF8Encoding]::new($false))
    Write-Output "windows_okx_report=$reportPath windows_process_chain_verified=$($report.windows_process_chain_verified) production_qualification=false"
}
if ($report.windows_process_chain_verified -eq 'failed') { throw $report.failure }
if ($Mode -eq 'Offline' -and $report.offline -ne 'passed') { throw 'Complete Windows OKX offline process-chain evidence is blocked' }
if ($Mode -eq 'DemoLive' -and $report.windows_process_chain_verified -ne 'passed') { throw $report.proof_gap }
