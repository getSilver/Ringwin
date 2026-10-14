param([string]$ManifestPath = '.scratch/core-continuous-capacity/06-final-v2-source-manifest.json')
$ErrorActionPreference = 'Stop'
$taskWorkspace = 'D:\github\Ringwin-core-continuous-capacity'
Set-Location -LiteralPath $taskWorkspace
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$artifactDir = Join-Path $taskWorkspace '.scratch/core-continuous-capacity'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$zigVersion = & 'D:\Program Files\zig\zig.exe' version
if ($LASTEXITCODE -ne 0 -or $zigVersion -ne '0.17.0-dev.315+5b647b792') { throw 'Unexpected Zig compiler identity' }
function Assert-FrozenSource {
    $mismatches = @($manifest.files | Where-Object {
        (Get-FileHash -LiteralPath $_.path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $_.sha256
    })
    if ($mismatches.Count -ne 0) { throw "Frozen source mismatch: $($mismatches.path -join ', ')" }
}
function Invoke-Captured([string]$Name, [string]$Invocation, [string]$Artifact = '') {
    Assert-FrozenSource
    $log = Join-Path $artifactDir "$Name.log"
    $stdout = Join-Path $artifactDir "$Name.stdout.log"
    $command = '"' + $Invocation + ' 1>"' + $stdout + '" 2>"' + $log + '""'
    $started = [DateTime]::UtcNow.ToString('o')
    $process = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/s', '/c', $command) -WorkingDirectory $taskWorkspace -WindowStyle Hidden -PassThru
    $state = [ordered]@{ stage = $Name; state = 'running'; source_tree_sha256 = $manifest.source_tree_sha256; started_utc = $started; parent_pid = $process.Id; command = $Invocation }
    [System.IO.File]::WriteAllText((Join-Path $artifactDir '06-final-v2-run-state.json'), ($state | ConvertTo-Json -Depth 6) + "`n", $utf8)
    $process.WaitForExit()
    $mismatches = @($manifest.files | Where-Object {
        (Get-FileHash -LiteralPath $_.path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $_.sha256
    })
    $result = [ordered]@{
        source_tree_sha256 = $manifest.source_tree_sha256
        zig = $zigVersion
        started_utc = $started
        finished_utc = [DateTime]::UtcNow.ToString('o')
        exit_code = $process.ExitCode
        command = $Invocation
        capture = 'native direct file handles'
        workload = 'functional; <=100 live and <=100 retained terminal across shards; no capacity pressure'
        source_mismatches_after = $mismatches.Count
        log_bytes = (Get-Item -LiteralPath $log).Length
        log_sha256 = (Get-FileHash -LiteralPath $log -Algorithm SHA256).Hash.ToLowerInvariant()
        stdout_sha256 = (Get-FileHash -LiteralPath $stdout -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    if ($Artifact -ne '' -and (Test-Path -LiteralPath $Artifact)) {
        $result.artifact_sha256 = (Get-FileHash -LiteralPath $Artifact -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    [System.IO.File]::WriteAllText((Join-Path $artifactDir "$Name.result.json"), ($result | ConvertTo-Json -Depth 8) + "`n", $utf8)
    $state.state = if ($process.ExitCode -eq 0 -and $mismatches.Count -eq 0) { 'completed-stage' } else { 'failed' }
    $state.exit_code = $process.ExitCode
    [System.IO.File]::WriteAllText((Join-Path $artifactDir '06-final-v2-run-state.json'), ($state | ConvertTo-Json -Depth 6) + "`n", $utf8)
    Write-Output "$Name exit=$($process.ExitCode) source_mismatches=$($mismatches.Count)"
    if ($process.ExitCode -ne 0 -or $mismatches.Count -ne 0) { throw "$Name failed; retained logs and result" }
}
$zig = '"D:\Program Files\zig\zig.exe"'
$target = Join-Path $artifactDir '06-final-v2-four-shard-rs.exe'
Invoke-Captured '06-final-v2-four-shard-rs-build' ($zig + ' test src/main.zig -O ReleaseSafe --stack 268435456 --test-no-exec --test-filter "four-shard acceptance entry" "-femit-bin=' + $target + '"') $target
Invoke-Captured '06-final-v2-four-shard-rs' ('"' + $target + '"') $target
foreach ($mode in @('ReleaseSafe', 'Debug')) {
    $label = $mode.ToLowerInvariant()
    $exe = Join-Path $artifactDir "06-final-v2-full-$label.exe"
    Invoke-Captured "06-final-v2-full-$label-build" ($zig + ' test src/main.zig -O ' + $mode + ' --stack 268435456 --test-no-exec "-femit-bin=' + $exe + '"') $exe
    Invoke-Captured "06-final-v2-full-$label" ('"' + $exe + '"') $exe
}
$app = Join-Path $taskWorkspace 'zig-out/bin/ringwin.exe'
Invoke-Captured '06-final-v2-app-build' ($zig + ' build -Doptimize=ReleaseSafe') $app
$cli = Join-Path $artifactDir '06-final-v2-cli.exe'
Invoke-Captured '06-final-v2-cli-build' ($zig + ' build-exe src/main.zig -O ReleaseSafe --stack 268435456 "-femit-bin=' + $cli + '"') $cli
foreach ($artifact in @(@{ label = 'app'; path = $app }, @{ label = 'cli'; path = $cli })) {
    Invoke-Captured ('06-final-v2-' + $artifact.label + '-offline-fixture') ('"' + $artifact.path + '" --offline-fixture') $artifact.path
    Invoke-Captured ('06-final-v2-' + $artifact.label + '-windows-chain-test') ('"' + $artifact.path + '" --windows-chain-test') $artifact.path
}
Assert-FrozenSource
function Get-PeStackReserve([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        $stream.Position = 0x3c
        $peOffset = $reader.ReadUInt32()
        $stream.Position = $peOffset + 24
        $magic = $reader.ReadUInt16()
        $stream.Position = $peOffset + 24 + 72
        if ($magic -eq 0x20b) { return $reader.ReadUInt64() }
        if ($magic -eq 0x10b) { return $reader.ReadUInt32() }
        throw 'Unknown PE optional header'
    } finally { $reader.Dispose() }
}
$artifacts = foreach ($path in @((Join-Path $artifactDir '06-final-v2-full-releasesafe.exe'), (Join-Path $artifactDir '06-final-v2-full-debug.exe'), $app, $cli)) {
    [ordered]@{ path = $path.Substring($taskWorkspace.Length + 1).Replace('\', '/'); bytes = (Get-Item -LiteralPath $path).Length; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(); pe_stack_reserve_bytes = Get-PeStackReserve $path }
}
$identity = [ordered]@{ recorded_utc = [DateTime]::UtcNow.ToString('o'); source_tree_sha256 = $manifest.source_tree_sha256; zig = $zigVersion; artifacts = @($artifacts); scope = 'functional artifacts only; no capacity pressure or production qualification' }
[System.IO.File]::WriteAllText((Join-Path $artifactDir '06-final-v2-artifacts.json'), ($identity | ConvertTo-Json -Depth 8) + "`n", $utf8)
Write-Output '06 final acceptance commands completed; inspect results and reviews before closing ticket'
