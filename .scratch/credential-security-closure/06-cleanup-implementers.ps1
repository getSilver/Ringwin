[CmdletBinding()]
param([switch]$Remove)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$integration = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$archive = 'D:\github\Ringwin-credential-worktrees-archive-20261019'
$expectedArchiveSha = '18952886223a59425017345ff5f417870933d69a2a941f032f68eb765f682439'
$allowed = @('lifecycle-fix','protected-memory','store-protection','auth-protection','aead-protection','gateway-injection','native-account-guard','review-fixes') | ForEach-Object { 'D:\github\Ringwin-credential-' + $_ }
$manifestPath = Join-Path $archive 'manifest.json'
if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $expectedArchiveSha) { throw 'Archive manifest identity mismatch' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if (@($manifest.trees).Count -ne 8) { throw 'Expected eight preserved trees' }
if ($Remove) {
    $state = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runs\credential-final-v3\state.json') -Raw | ConvertFrom-Json
    if ($state.status -ne 'passed') { throw 'Final acceptance has not passed' }
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'credential-final-v3-validation.json'))) { throw 'Final evidence has not been sealed' }
}
$journalPath = Join-Path $PSScriptRoot '06-cleanup-state.json'
if (Test-Path -LiteralPath $journalPath) { throw 'Cleanup journal already exists; inspect it before resuming' }
$journal = [ordered]@{ archive=$archive; manifest_sha256=$expectedArchiveSha; remove_requested=[bool]$Remove; status='verifying'; verified=@(); removed=@() }
function Save-Journal {
    [IO.File]::WriteAllText($journalPath, ($journal | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}
Save-Journal
foreach ($tree in $manifest.trees) {
    $absolute = [IO.Path]::GetFullPath($tree.path)
    if ($allowed -notcontains $absolute -or [IO.Path]::GetDirectoryName($absolute) -ne 'D:\github') { throw 'Unexpected cleanup target' }
    $entry = Get-Item -LiteralPath $absolute -Force
    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Worktree root must not be a reparse point' }
    $head = (& git -C $absolute rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -ne $tree.head) { throw 'Preserved worktree HEAD changed' }
    & git -C $integration merge-base --is-ancestor $head HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Implementation is not integrated' }
    $changes = & git -C $absolute status --porcelain --untracked-files=no
    if ($LASTEXITCODE -ne 0 -or $changes) { throw 'Tracked changes require preservation' }
    foreach ($file in $tree.files) {
        $source = [IO.Path]::GetFullPath((Join-Path $absolute $file.path))
        $copyRoot = Join-Path $archive ([IO.Path]::GetFileName($absolute))
        $copy = [IO.Path]::GetFullPath((Join-Path $copyRoot $file.path))
        if (-not $source.StartsWith($absolute + '\', [StringComparison]::OrdinalIgnoreCase) -or -not $copy.StartsWith($copyRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest file escapes its named tree' }
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $file.sha256 -or (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -ne $file.sha256) { throw 'Preservation bytes changed' }
    }
    $journal.verified += [ordered]@{ path=$absolute; head=$head; files=@($tree.files).Count; bytes=$tree.bytes }
    Save-Journal
    Write-Output "preservation_verified=$absolute files=$(@($tree.files).Count)"
}
$journal.status = 'verified'
Save-Journal
if (-not $Remove) { return }
foreach ($tree in $journal.verified) {
    # Every absolute target and its preservation hashes were checked above.
    & git -C $integration worktree remove --force -- $tree.path
    if ($LASTEXITCODE -ne 0) { throw "Worktree removal failed: $($tree.path)" }
    $journal.removed += $tree.path
    Save-Journal
    Write-Output "worktree_removed=$($tree.path)"
}
$journal.status = 'complete'
Save-Journal
