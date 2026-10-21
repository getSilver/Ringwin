[CmdletBinding()]
param(
    [switch]$DemoLive,
    [string]$EnvFile = '',
    [int]$Parallel = 4
)

# Single fail-fast acceptance entry for the trading core wave (map 12).
# Composes: offline success/fault/restart trajectories, SimulatedVenue,
# four-shard coordination, Python StrategyHost seam, and - only when
# explicitly enabled via -DemoLive - existing OKX Demo facts.
# Any failing step stops the wave immediately; nothing continues past a
# broken assertion.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'zig-entry.ps1')

function Invoke-Zig {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $invocation = Get-ZigSourceInvocation $args
        $nativeArguments = $invocation.Arguments
        & $invocation.Executable @nativeArguments
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Invoke-Captured {
    param([string[]]$ZigArguments)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $invocation = Get-ZigSourceInvocation $ZigArguments
        $nativeArguments = $invocation.Arguments
        $captured = @(& $invocation.Executable @nativeArguments 2>&1)
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    $text = @($captured | ForEach-Object { "$_" })
    $text | ForEach-Object { $_ | Out-Host }
    if ($LASTEXITCODE -ne 0) { throw "Command failed: zig $($ZigArguments -join ' ')" }
    return $text
}

if (-not $EnvFile) { $EnvFile = Join-Path $PSScriptRoot '..\.env.local' }
$ExpectedZig = '0.17.0-dev.315+5b647b792'
$AcceptanceSchema = $null
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildRoot = Join-Path $workspace '.scratch\build'
$curlBuild = Join-Path $buildRoot 'libcurl-8.21.0-windows-x86_64-schannel'
$curlSource = Join-Path $buildRoot 'bootstrap\curl-source'
$sourceRevision = (& git -C $workspace rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or -not $sourceRevision) { throw 'Source revision is unavailable' }

function Get-SourceSnapshot {
    # Hash tracked and untracked code, tests, build inputs, and this verifier.
    # Docs and tracker reports are excluded so recording the digest cannot
    # change the source identity it records.
    $paths = @(& git -C $workspace ls-files --cached --others --exclude-standard -- src python tools build.zig build.zig.zon)
    if ($LASTEXITCODE -ne 0 -or $paths.Count -eq 0) { throw 'Source file list is unavailable' }
    $manifest = foreach ($path in ($paths | Sort-Object -CaseSensitive -Unique)) {
        $file = Join-Path $workspace $path
        $digest = if (Test-Path -LiteralPath $file -PathType Leaf) {
            (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        } else { 'missing' }
        "$path`t$digest"
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($manifest -join "`n"))
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

$sourceTreeSha256 = Get-SourceSnapshot
$sourceDirty = @(& git -C $workspace status --porcelain --untracked-files=all).Count -ne 0
if ($LASTEXITCODE -ne 0) { throw 'Source worktree status is unavailable' }

function Assert-SourceAbsent {
    param([string]$Path, [string]$Pattern, [string]$Label)
    $sourcePath = Join-Path $workspace $Path
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw "Source file is missing: $Path" }
    $matches = @(Select-String -LiteralPath $sourcePath -Pattern $Pattern -ErrorAction Stop)
    if ($matches.Count -ne 0) {
        throw "Forbidden source remains ($Label): $($matches.Line -join '; ')"
    }
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Core wave acceptance must run on Windows'
}
$zigVersion = (& zig version).Trim()
if ($LASTEXITCODE -ne 0 -or $zigVersion -ne $ExpectedZig) {
    throw "Expected Zig $ExpectedZig, got $zigVersion"
}

Write-Output '== phase=format'
$zigSources = @(Get-ChildItem (Join-Path $workspace 'src') -Recurse -File -Filter '*.zig' | ForEach-Object FullName)
Invoke-Zig fmt --check $zigSources
if ($LASTEXITCODE -ne 0) { throw 'Zig format check failed' }

Write-Output '== phase=source_contract'
if (Test-Path -LiteralPath (Join-Path $workspace 'src\okx_spot_projection.zig')) {
    throw 'Competing OKX economic projection still exists'
}
Assert-SourceAbsent 'src\trading\trading_shard.zig' '^\s*(order_state|filled_quantity|order_quantity|open_order_reservation_micros|risk_lease_remaining_micros|layered_risk_reserved_micros|last_canonical_report|last_canonical_fill)\s*:' 'legacy TradingShard authority'
Assert-SourceAbsent 'src\trading\trading_shard.zig' 'intent_sequence\s*=\s*1\b|RWN-00000001-01-000000000001' 'fixed timer identity'
Assert-SourceAbsent 'src\execution\execution_gateway.zig' '^\s*pub fn send\s*\(' 'raw public Gateway send'
Assert-SourceAbsent 'src\testing\acceptance\venues\okx_demo_live_acceptance.zig' 'adapter\.trySend.*order_(command|batch)' 'Demo order send bypass'
Assert-SourceAbsent 'python\strategy_host.py' 'ctypes|input-mapping|output-mapping|qsh_' 'Python mapping or cursor capability'
Assert-SourceAbsent 'src\strategy\strategy_host_lifecycle.zig' 'OwnedMapping|input_mapping|output_mapping' 'Host mapping capability transfer'

Write-Output '== phase=core_tests mode=Debug'
$debugTests = Invoke-Captured @('test', (Join-Path $workspace 'src\main.zig'), '-ODebug', '--stack', '67108864')

Write-Output '== phase=core_tests mode=ReleaseSafe'
$releaseTests = Invoke-Captured @('test', (Join-Path $workspace 'src\main.zig'), '-OReleaseSafe', '--stack', '67108864')

Write-Output '== phase=single_shard_wave'
# Deterministic fixture: happy path plus market-gap / risk-rejection /
# unknown-reconciliation / duplicate-report fault trajectories through the
# SimulatedVenue adapter seam, with frozen digests and live/replay/recovery
# equivalence checks.
$singleShardEvidence = Invoke-Captured @('run', (Join-Path $workspace 'src\main.zig'), '-OReleaseSafe', '--', '--offline-fixture')

Write-Output '== phase=four_shard_wave'
# Four shards + shared gateway + account coordination: success path, local
# faults, margin break latching, and three recovery paths that must converge
# to one shared summary digest. Historical replay never resends side effects.
$fourShardEvidence = Invoke-Captured @('run', (Join-Path $workspace 'src\main.zig'), '-OReleaseSafe', '--', '--four-shard-acceptance')

Write-Output '== phase=python_seam'
# StrategyHost product acceptance: same core risk/OMS seam for Python
# intents, crash rebuild, hang kill, stale-session fencing, checkpoint
# catch-up recovery. Fails fast on the first broken check.
$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = 'Continue'
    $pythonEvidence = @(& python (Join-Path $workspace 'python\verify_strategy_host.py') 2>&1)
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
$pythonEvidence | ForEach-Object { $_ | Out-Host }
if ($LASTEXITCODE -ne 0) { throw 'Python StrategyHost acceptance failed' }

Write-Output '== phase=linux_cross_compile'
Invoke-Zig build-exe (Join-Path $workspace 'src\main.zig') -target x86_64-linux-gnu -OReleaseSafe -fno-emit-bin
if ($LASTEXITCODE -ne 0) { throw 'Linux core cross-build failed' }

$mode = 'offline'
if ($DemoLive) {
    $mode = 'demo_live'
    Write-Output '== phase=okx_demo_facts mode=demo_live (explicitly enabled)'
    $curlLibrary = Get-ChildItem -LiteralPath $curlBuild -Recurse -File -Filter 'libcurl.a' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $curlLibrary) {
        & (Join-Path $PSScriptRoot 'bootstrap-libcurl.ps1') -BuildRoot $buildRoot -Parallel $Parallel | Out-Host
    }
    & (Join-Path $PSScriptRoot 'test-libcurl.ps1') -BuildRoot $curlBuild

    $include = (Get-ChildItem -LiteralPath $curlSource -Recurse -Directory -Filter include | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'curl\curl.h')
    } | Select-Object -First 1).FullName
    if (-not $include) { throw 'Pinned libcurl headers are missing after bootstrap' }
    Invoke-Zig build-obj (Join-Path $workspace 'src\testing\acceptance\venues\okx_demo_live_acceptance.zig') `
        (Join-Path $workspace 'src\adapters\okx\okx_curl_shim.c') -target x86_64-linux-gnu -lc "-I$include" `
        "-femit-bin=$(Join-Path $buildRoot 'okx-demo-live-acceptance-linux.o')"
    if ($LASTEXITCODE -ne 0) { throw 'Linux OKX Adapter compile check failed' }

    $liveArgs = @{
        EnvFile = $EnvFile
        BuildRoot = $curlBuild
        Optimize = 'ReleaseSafe'
        DemoLive = $true
    }
    & (Join-Path $PSScriptRoot 'run-okx-demo-live-acceptance.ps1') @liveArgs
    if ($LASTEXITCODE -ne 0) { throw 'OKX Demo live facts failed' }
}
else {
    Write-Output '== phase=okx_demo_facts mode=offline (skipped; enable explicitly with -DemoLive)'
}

$debugText = $debugTests -join "`n"
$releaseText = $releaseTests -join "`n"
$fourText = $fourShardEvidence -join "`n"
$singleText = $singleShardEvidence -join "`n"
$schemaMatch = [regex]::Match($fourText, 'four_shard_acceptance: schema=(\d+)')
if (-not $schemaMatch.Success) { throw 'Four-shard machine-readable schema evidence is missing' }
$AcceptanceSchema = [int]$schemaMatch.Groups[1].Value
$stableSchemaMatch = [regex]::Match($fourText, 'journal_schema=(\d+), state_schema=(\d+)')
if (-not $stableSchemaMatch.Success) { throw 'Stable journal/state schema evidence is missing' }
$JournalSchema = [int]$stableSchemaMatch.Groups[1].Value
$StateSchema = [int]$stableSchemaMatch.Groups[2].Value
if ($AcceptanceSchema -ne 13 -or $JournalSchema -ne 22 -or $StateSchema -ne 25) {
    throw "Unexpected acceptance/journal/state schema: $AcceptanceSchema/$JournalSchema/$StateSchema"
}
$debugMatch = [regex]::Match($debugText, 'All (\d+) tests passed')
$releaseMatch = [regex]::Match($releaseText, 'All (\d+) tests passed')
$barrierMatch = [regex]::Match($fourText, 'coordinator_barrier=(\d+), coordinator_digest=([0-9a-f]+)')
$sharedMatch = [regex]::Match($fourText, 'shared_summary=([0-9a-f]{64})')
$gatewayMatch = [regex]::Match($debugText, 'execution_gateway_acceptance: adapter_submissions=(\d+)')
$ownershipMatch = [regex]::Match($fourText, 'owned_command_count=(\d+), replay_send_capability=(\w+)')
$shardMatches = [regex]::Matches($fourText, 'shard_(\d+): barrier=(\d+), digest=([0-9a-f]{64})')
if ($shardMatches.Count -ne 4) { throw 'Four-shard barrier/digest evidence is incomplete' }
$shardBarriers = @()
$shardDigests = @()
foreach ($match in $shardMatches) {
    $index = [int]$match.Groups[1].Value
    if ($index -ne $shardBarriers.Count) { throw 'Four-shard evidence indexes are not contiguous' }
    $shardBarriers += [int64]$match.Groups[2].Value
    $shardDigests += $match.Groups[3].Value
}
$singleDigestMatches = [regex]::Matches($singleText, 'digest=([0-9a-f]{64})')
if ($singleDigestMatches.Count -ne 5) { throw 'Single-shard trajectory digest evidence is incomplete' }
$singleDigests = @($singleDigestMatches | ForEach-Object { $_.Groups[1].Value })
$pythonText = $pythonEvidence -join "`n"
$pythonScenarioMatches = [regex]::Matches($pythonText, 'scenario=(\w+) samples=(\d+)')
if ($pythonScenarioMatches.Count -ne 5) { throw 'Python capacity scenario evidence is incomplete' }
$pythonHostile = [regex]::Match($pythonText, 'hostile_capability=(absent), hostile_authority=(unchanged)')
if (-not $pythonHostile.Success) { throw 'Python hostile-child capability evidence is missing' }
$requiredVenueMarkers = [ordered]@{
    SimulatedVenue = 'simulated_venue\.'
    OKX = 'okx_venue_adapter\.'
    Binance = 'binance_venue_adapter\.'
    Bybit = 'bybit_venue_adapter\.'
}
$offlineVenueContracts = @()
foreach ($venue in $requiredVenueMarkers.Keys) {
    $marker = $requiredVenueMarkers[$venue]
    if (-not [regex]::IsMatch($debugText, $marker)) { throw "Offline venue evidence is missing: $marker" }
    $offlineVenueContracts += $venue
}
if (-not $debugMatch.Success -or -not $releaseMatch.Success -or -not $barrierMatch.Success -or
    -not $sharedMatch.Success -or -not $gatewayMatch.Success -or -not $ownershipMatch.Success) {
    throw 'Acceptance child output did not contain complete machine-readable evidence'
}
if ($debugMatch.Groups[1].Value -ne $releaseMatch.Groups[1].Value) {
    throw 'Debug and ReleaseSafe did not run the same test matrix'
}
$debugNames = @([regex]::Matches($debugText, '(?m)^\d+/\d+ (.+?)\.\.\.') | ForEach-Object { $_.Groups[1].Value })
$releaseNames = @([regex]::Matches($releaseText, '(?m)^\d+/\d+ (.+?)\.\.\.') | ForEach-Object { $_.Groups[1].Value })
if ($debugNames.Count -ne [int]$debugMatch.Groups[1].Value -or
    $releaseNames.Count -ne [int]$releaseMatch.Groups[1].Value -or
    ($debugNames -join "`n") -cne ($releaseNames -join "`n")) {
    throw 'Debug and ReleaseSafe test names differ'
}
$pythonPassed = [regex]::IsMatch($pythonText, 'strategy_host_product_acceptance=passed')
if (-not $pythonPassed) { throw 'Python machine-readable acceptance evidence is missing' }
$debugSafety = $debugText
if ($singleText -notmatch 'unknown-reconciliation-v1:.*replay=equivalent') { throw 'Canonical reconciliation live/replay evidence is missing' }
if ($singleText -notmatch 'duplicate-report-v1:.*replay=equivalent') { throw 'Partial fill live/replay evidence is missing' }
if ($singleText -notmatch 'happy_path:') { throw 'Happy-path evidence is missing' }
if ($debugSafety -notmatch 'core_safety_invariants:.*ccc=pass') { throw 'CCC live/replay evidence is missing' }
if ($debugSafety -notmatch 'core_safety_invariants:.*intent_conflict=pass') { throw 'Intent conflict live/replay evidence is missing' }
if ($debugSafety -notmatch 'core_safety_invariants:.*suspense=pass') { throw 'Suspense live/replay evidence is missing' }
if ($debugSafety -notmatch 'core_safety_invariants:.*tombstone_archive=pass') { throw 'Tombstone archive restore evidence is missing' }
if ($debugSafety -notmatch 'core_safety_invariants:.*host_activated=pass') { throw 'HostActivated live evidence is missing' }
if ($debugSafety -notmatch 'core_safety_invariants:.*dispatch_persist=pass') { throw 'Durable dispatch persist evidence is missing' }
if ($debugSafety -notmatch 'core_safety_invariants:.*replay_no_send=pass') { throw 'Replay no-send evidence is missing' }
if ($debugSafety -notmatch 'core_safety_invariants:.*reduce_only_fencing=pass') { throw 'Reduce-only and fencing send evidence is missing' }
if ($releaseText -notmatch 'core_safety_invariants:.*tombstone_archive=pass') { throw 'ReleaseSafe tombstone archive evidence is missing' }
if ($releaseText -notmatch 'core_safety_invariants:.*dispatch_persist=pass') { throw 'ReleaseSafe durable dispatch evidence is missing' }
if ($releaseText -notmatch 'core_safety_invariants:.*replay_no_send=pass.*reduce_only_fencing=pass') { throw 'ReleaseSafe Gateway safety evidence is missing' }

$reviewChecks = [ordered]@{
    H1 = 'bounded rings and frozen bridge fail closed'
    H2 = 'extreme risk arithmetic fails closed'
    M1 = 'host fault revokes the old activation before a replacement can trade'
    M3 = 'fencing tokens are strictly increasing and stale sends fail'
    M5 = 'Gateway reads current authority facts instead of caller proof fields'
    B01 = 'ConfirmedAbsent cannot become a fill and releases reservation'
    B02 = 'canonical terminal reconciliation confirms a CCC replacement'
    B03 = 'DispatchProof rechecks authority reservation lease fencing and true reduce-only'
    B04 = 'pending amend keeps old and new remaining exposure through fills and rejection'
    B05 = 'layered risk retains unknown reservations until authoritative terminal evidence'
    B06 = 'margin safety gate takes the strictest amount bps and liquidation distance'
    B07 = 'unowned economics stay in suspense until an immutable allocation'
    B08 = 'configurable Genesis fails closed until authority is complete'
    B09 = 'shared canonical adapter facts enter the TradingShard state seam'
    B10 = 'shared canonical adapter facts enter the TradingShard state seam'
    B11 = 'risk lease limit rejects a native intent with a replayable reason'
    B12 = 'partial fill keeps another PendingCancel blocking CCC'
    B13 = 'native and Python intents cross the same authority and risk seam'
    B14 = 'OMS group identity is checked before new risk and conflict survives replay'
    B15 = 'full lifecycle trajectories authorize only prescribed risk cancel and reduce behavior'
    R07 = 'recovered dispatch needs an order reconciliation newer than its send'
    R07Schema = 'dispatch namespace survives recovery and changes for a new stream'
    OldSchema = 'stable CanonicalEvent decoder rejects malformed envelopes without state change'
    R11 = 'compacted second group member keeps its own intent identity'
}
foreach ($check in $reviewChecks.GetEnumerator()) {
    $marker = [regex]::Escape($check.Value)
    if (-not [regex]::IsMatch($debugText, $marker) -or -not [regex]::IsMatch($releaseText, $marker)) {
        throw "Review check $($check.Key) is missing from Debug or ReleaseSafe: $($check.Value)"
    }
}
$rejectionMarkers = @(
    'core_input_rejection: product_model=IncompatibleProductReservationModel',
    'core_input_rejection: l2=IncompleteL2Book fill_fee=MissingFillFee'
)
foreach ($marker in $rejectionMarkers) {
    if (-not $debugText.Contains($marker) -or -not $releaseText.Contains($marker)) {
        throw "Core rejection evidence is missing from Debug or ReleaseSafe: $marker"
    }
}
if ((Get-SourceSnapshot) -ne $sourceTreeSha256) { throw 'Source changed during acceptance' }
$evidence = [ordered]@{
    acceptance = 'passed'
    report_schema = 4
    source_revision = $sourceRevision
    source_tree_sha256 = $sourceTreeSha256
    source_scope = @('src', 'python', 'tools', 'build.zig', 'build.zig.zon')
    source_dirty = $sourceDirty
    zig = $zigVersion
    schema = $AcceptanceSchema
    journal_schema = $JournalSchema
    state_schema = $StateSchema
    mode = $mode
    debug_tests = [int]$debugMatch.Groups[1].Value
    release_safe_tests = [int]$releaseMatch.Groups[1].Value
    coordinator_barrier = [int64]$barrierMatch.Groups[1].Value
    coordinator_digest = $barrierMatch.Groups[2].Value
    shard_barriers = $shardBarriers
    shard_digests = $shardDigests
    shared_summary = $sharedMatch.Groups[1].Value
    gateway_adapter_submissions = [int]$gatewayMatch.Groups[1].Value
    safety_assertions = @(
        'checked_arithmetic_no_commit'
        'canonical_reconciliation_live_replay'
        'intent_conflict_and_ccc'
        'authoritative_reduce_only_and_fencing'
        'host_activation_before_intent'
        'hostile_child_has_no_backing_capability'
        'suspense_allocation_recovery'
        'tombstone_capacity_recovery_only'
        'legacy_authority_absent'
    )
    review_checks = @($reviewChecks.Keys)
    rejection_facts = $rejectionMarkers
    owned_command_count = [int]$ownershipMatch.Groups[1].Value
    replay_send_capability = $ownershipMatch.Groups[2].Value
    single_shard_output = @($singleText | Where-Object { $_ -match '(happy_path:|market-gap-v1:|risk-rejection-v1:|unknown-reconciliation-v1:|duplicate-report-v1:)' })
    single_shard_digests = $singleDigests
    offline_venue_contracts = $offlineVenueContracts
    python_scenarios = @($pythonScenarioMatches | ForEach-Object { $_.Groups[1].Value })
    python_hostile_capability = $pythonHostile.Groups[1].Value
    python_hostile_authority = $pythonHostile.Groups[2].Value
    python = 'passed'
    linux = 'compile_only'
    okx_demo_qualification = if ($DemoLive) { 'demo_qualified' } else { 'not_run' }
    binance_testnet_qualification = 'not_run'
    bybit_testnet_qualification = 'not_run'
    production_qualification = $false
}
Write-Output ("core_wave_evidence=" + ($evidence | ConvertTo-Json -Compress))
