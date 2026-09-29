[CmdletBinding()]
param(
    [ValidateSet('Offline', 'ReadOnly', 'DemoLive')][string]$Mode = 'Offline',
    [switch]$SystemOwnerAuthorized
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
    observed_strategy = $null
    configuration_source = 'src/windows_verification_runtime.zig and demo_authority.Policy'
    observed_configuration = $null
    account_uid_sha256 = $null
    requested_roles = 5
    observed_roles = $null
    requested_ipc = 'windows_named_pipe'
    mode = $Mode.ToLowerInvariant()
    windows_durable_adapter = 'not_run'
    windows_credential_adapter = 'not_run'
    offline = 'not_run'
    offline_adapter_tests = 'not_run'
    read_only = 'not_run'
    demo_live = 'not_run'
    role_ownership = 'not_run'
    durable_recovery = 'not_run'
    final_reconciliation = 'not_run'
    order_writes = 0
    live_order_ids = @()
    live_fills = @()
    live_fees = @()
    historical_demo_evidence = 'evidence-2026-09-29-demo-round-trip.json'
    proof_gap = 'Current live chain prints aggregate success only; machine report cannot bind current order IDs, fills, and fees.'
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
        if (-not ($lines -match 'okx_host_gateway_private=offline_passed')) { throw 'OKX offline role evidence missing' }
        $report.offline_adapter_tests = 'passed'
        # The same binary explicitly reports offline=blocked for the complete OKX chain.
        $report.offline = 'blocked'
        $report.role_ownership = 'blocked'
        $report.durable_recovery = 'blocked'
    } else {
        $preflight = & (Join-Path $PSScriptRoot 'okx-demo-preflight.ps1') | ConvertFrom-Json
        if (-not $preflight.qualified -or $preflight.environment -ne 'demo' -or -not $preflight.account_uid_sha256) { throw 'Demo preflight failed' }
        $report.account_uid_sha256 = $preflight.account_uid_sha256
        $offlinePath = Join-Path $reportDir 'report-offline.json'
        if (Test-Path -LiteralPath $offlinePath) {
            $prior = Get-Content -LiteralPath $offlinePath -Raw | ConvertFrom-Json
            if ($prior.source_tree_sha256 -eq $source -and $prior.revision -eq $revision -and
                $prior.mode -eq 'offline' -and $prior.venue -eq 'okx' -and
                $prior.acceptance_schema -eq $report.acceptance_schema -and
                $prior.journal_schema -eq $report.journal_schema -and $prior.state_schema -eq $report.state_schema) {
                $report.offline = $prior.offline
                $report.offline_adapter_tests = $prior.offline_adapter_tests
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
                $readonly.state_schema -ne $report.state_schema) { throw 'Current-source read-only evidence missing' }
            $report.read_only = 'passed'
            $lines = Invoke-Checked (Join-Path $PSScriptRoot 'run-windows-demo-readonly.ps1') @('-DemoLive', '-SystemOwnerAuthorized')
            if (-not ($lines -match 'windows_demo_live=passed.*terminal=ok zero_exposure=ok') -or
                -not ($lines -match 'windows_demo_postflight: pending_orders=0 pending_algo_orders=0 open_positions=0 liabilities=0 funded_currencies=USDT')) { throw 'Demo terminal or zero-exposure evidence missing' }
            $report.demo_live = 'passed'
            $report.final_reconciliation = 'passed'
            $report.order_writes = 'bounded_live_round_trip'
            $report.observed_roles = 5
        } else {
            $lines = Invoke-Checked (Join-Path $PSScriptRoot 'run-windows-demo-readonly.ps1') @()
            if (-not ($lines -match 'windows_demo_readonly=passed.*roles=5 order_writes=0')) { throw 'Read-only role evidence missing' }
            $report.read_only = 'passed'
            $report.observed_roles = 5
        }
    }
    if ((Get-SourceIdentity) -ne $source) { throw 'Source changed during acceptance' }
    if ($report.offline -eq 'passed' -and $report.read_only -eq 'passed' -and
        $report.demo_live -eq 'passed' -and $report.role_ownership -eq 'passed' -and
        $report.durable_recovery -eq 'passed' -and $report.final_reconciliation -eq 'passed' -and
        $report.observed_product -eq $report.requested_product -and
        $report.observed_strategy -eq $report.requested_strategy -and
        $report.observed_configuration -and $report.observed_roles -eq 5 -and
        $report.live_order_ids.Count -ge 2 -and $report.live_fills.Count -ge 2 -and $report.live_fees.Count -ge 2) {
        $report.windows_process_chain_verified = 'passed'
        $report.proof_gap = $null
    }
} catch {
    $field = @{ Offline = 'offline'; ReadOnly = 'read_only'; DemoLive = 'demo_live' }[$Mode]
    $report[$field] = 'failed'
    $report.windows_process_chain_verified = 'failed'
    $report.failure = $_.Exception.Message
} finally {
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding utf8
    Write-Output "windows_okx_report=$reportPath windows_process_chain_verified=$($report.windows_process_chain_verified) production_qualification=false"
}
if ($report.windows_process_chain_verified -eq 'failed') { throw $report.failure }
if ($Mode -eq 'Offline' -and $report.offline -ne 'passed') { throw 'Complete Windows OKX offline process-chain evidence is blocked' }
if ($Mode -eq 'DemoLive' -and $report.windows_process_chain_verified -ne 'passed') { throw $report.proof_gap }
