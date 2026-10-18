# Shared by the current framed-stdin launchers. This file never reads stdin.
function Assert-ProtectedDemoInput([string]$EnvFile) {
    if ($EnvFile) { throw 'EnvFile is retired. Supply a Demo credential frame through an inherited restricted pipe; see docs/okx-demo-credential-input.md.' }
    foreach ($name in @('RINGWIN_OKX_KEY','RINGWIN_OKX_SECRET','RINGWIN_OKX_PASSPHRASE')) {
        if (Test-Path "Env:$name") { throw 'Legacy raw credential environment is rejected; remove it before launching.' }
    }
}
function Invoke-EmptyInputNative([string]$Executable, [string[]]$NativeArguments) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    # Standard Windows argv quoting, including trailing backslashes. Arguments are nonsecret.
    $info.Arguments = (($NativeArguments | ForEach-Object { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }) -join ' ')
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Build process did not start' }
        $process.StandardInput.Close()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "Build process failed with exit $($process.ExitCode)" }
    } finally { $process.Dispose() }
}
function Invoke-ProtectedDemoExecutable([string]$Executable, [string[]]$NativeArguments) {
    # Native invocation inherits the original OS handle without reading/re-encoding its bytes.
    & $Executable @NativeArguments
    if ($LASTEXITCODE -ne 0) { throw "Native Demo process failed with exit $LASTEXITCODE" }
}
