param([string]$Helper, [string]$Compiler, [string]$Verify, [string]$Seed, [string]$Case)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Windows PowerShell 5.1 required' }
Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
if ($Seed -eq 'stale') { $global:LASTEXITCODE = 19 }
if ($Case -eq 'verify') {
    try { & $Verify; throw 'Expected controlled fmt stop' }
    catch {
        if ($_.Exception.Message -ne 'Build process failed with exit 73') { throw }
        if ($LASTEXITCODE -ne 73) { throw 'fmt exit status was not published' }
    }
} else {
    . $Helper
    if ($Case -eq 'failure') {
        try { Invoke-EmptyInputNative $Compiler @('fail') -CaptureOutput; throw 'Expected child failure' }
        catch {
            if ($_.Exception.Message -ne 'Build process failed with exit 41') { throw }
            if ($LASTEXITCODE -ne 41) { throw 'child exit status was not published before throw' }
        }
    } else {
        $version = (Invoke-EmptyInputNative $Compiler @('version') -CaptureOutput).Trim()
        if ($version -ne '0.17.0-dev.315+5b647b792' -or $LASTEXITCODE -ne 0) { throw 'Successful compiler status was not published' }
    }
}
# The helper must leave the original inherited binary pipe byte-for-byte untouched.
$inputStream = [Console]::OpenStandardInput()
$bytes = New-Object IO.MemoryStream
$inputStream.CopyTo($bytes)
$expected = [Convert]::FromBase64String($env:RINGWIN_SYNTHETIC_FRAME_BASE64)
if ([Convert]::ToBase64String($bytes.ToArray()) -ne [Convert]::ToBase64String($expected)) { throw 'Original framed stdin changed' }
Write-Output "case=$Case seed=$Seed exit_state=true original_frame_preserved=true powershell=$($PSVersionTable.PSVersion)"
