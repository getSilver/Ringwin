# Shared by the current framed-stdin launchers. This file never reads stdin.
function Assert-ProtectedDemoInput([string]$EnvFile) {
    if ($EnvFile) { throw 'EnvFile is retired. Supply a Demo credential frame through an inherited restricted pipe; see docs/okx-demo-credential-input.md.' }
    foreach ($name in @('RINGWIN_OKX_KEY','RINGWIN_OKX_SECRET','RINGWIN_OKX_PASSPHRASE')) {
        if (Test-Path "Env:$name") { throw 'Legacy raw credential environment is rejected; remove it before launching.' }
    }
}
function Invoke-EmptyInputNative([string]$Executable, [string[]]$NativeArguments, [switch]$CaptureOutput) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = [bool]$CaptureOutput
    # Standard Windows argv quoting, including trailing backslashes. Arguments are nonsecret.
    $info.Arguments = (($NativeArguments | ForEach-Object { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }) -join ' ')
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $previousInputEncoding = [Console]::InputEncoding
    try {
        # .NET Framework otherwise writes a UTF8 BOM into a fresh redirected pipe.
        [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
        if (-not $process.Start()) { throw 'Build process did not start' }
        $process.StandardInput.BaseStream.Close()
        $captured = if ($CaptureOutput) { $process.StandardOutput.ReadToEnd() } else { $null }
        $process.WaitForExit()
        # Diagnostics.Process does not update PowerShell's native exit state.
        # Publish it before either returning captured output or throwing.
        $global:LASTEXITCODE = $process.ExitCode
        if ($process.ExitCode -ne 0) { throw "Build process failed with exit $($process.ExitCode)" }
        if ($CaptureOutput) { return $captured }
    } finally { [Console]::InputEncoding = $previousInputEncoding; $process.Dispose() }
}
function Invoke-ProtectedDemoExecutable([string]$Executable, [string[]]$NativeArguments) {
    # Native invocation inherits the original OS handle without reading/re-encoding its bytes.
    & $Executable @NativeArguments
    if ($LASTEXITCODE -ne 0) { throw "Native Demo process failed with exit $LASTEXITCODE" }
}
