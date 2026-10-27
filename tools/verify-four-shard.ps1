[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Push-Location $workspace
try {
    function Invoke-ZigChecked([string[]]$ZigArguments) {
        $previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & zig @ZigArguments
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
        }
        if ($code -ne 0) { throw "Failed: zig $($ZigArguments -join ' ') (exit $code)" }
    }

    if ((& zig version).Trim() -ne '0.17.0-dev.315+5b647b792') { throw 'Pinned Zig version required' }
    $filters = @(
        'four_shard_acceptance',
        'multi_portfolio_netting_acceptance',
        'risk_lease_delivery_acceptance',
        'shared_venue_delivery_acceptance',
        'coordinator_safety_acceptance',
        'shared_gateway_venue_acceptance',
        'account_isolation_acceptance',
        'shared_forced_execution_acceptance',
        'shared_fee_history_acceptance',
        'portfolio.account_coordinator'
    )
    $filterArguments = @($filters | ForEach-Object { '--test-filter'; $_ })
    foreach ($mode in @('Debug', 'ReleaseSafe')) {
        $testStack = if ($mode -eq 'Debug') { '268435456' } else { '67108864' }
        Invoke-ZigChecked -ZigArguments (@('test', 'src/main.zig', '-O', $mode, '--stack', $testStack) + $filterArguments)
    }

    $artifact = '.scratch/build/four-shard-acceptance/ringwin.exe'
    New-Item -ItemType Directory -Force (Split-Path $artifact) | Out-Null
    Invoke-ZigChecked -ZigArguments @('build-exe', 'src/main.zig', '-O', 'ReleaseSafe', '--stack', '67108864', "-femit-bin=$artifact")
    & $artifact --four-shard-acceptance
    if ($LASTEXITCODE -ne 0) { throw 'Four-shard frozen acceptance failed' }
    Write-Output 'four_shard_wave=passed debug_test_stack_bytes=268435456 release_safe_stack_bytes=67108864 application_stack_bytes=67108864 venue_qualification=not_run production_qualification=false'
} finally {
    Pop-Location
}
