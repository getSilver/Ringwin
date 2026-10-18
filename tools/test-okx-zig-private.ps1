[CmdletBinding()]
param([string]$EnvFile = '')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'protected-demo-launch.ps1')
Assert-ProtectedDemoInput $EnvFile
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$zig = (Get-Command zig -ErrorAction Stop).Source

$include = Join-Path $workspace '.scratch\build\bootstrap\curl-source\curl-8.21.0\include'
$lib = Join-Path $workspace '.scratch\build\libcurl-8.21.0-windows-x86_64-schannel\lib'
$output = Join-Path $workspace '.scratch\build\okx-curl-private-smoke.exe'
Invoke-EmptyInputNative $zig @('build-exe',(Join-Path $workspace 'src\okx_curl_private_smoke.zig'),(Join-Path $workspace 'src\okx_curl_shim.c'),"-I$include","-L$lib",'-lc','-lcurl','-lws2_32','-lcrypt32','-lsecur32','-ladvapi32','-lbcrypt','-lwldap32','-lnormaliz','-liphlpapi','-OReleaseSafe','--stack','67108864',"-femit-bin=$output")
$oldTimestamp = $env:RINGWIN_OKX_TIMESTAMP
$oldSeconds = $env:RINGWIN_OKX_TIMESTAMP_SECONDS
try {
    $env:RINGWIN_OKX_TIMESTAMP = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ',[Globalization.CultureInfo]::InvariantCulture)
    $env:RINGWIN_OKX_TIMESTAMP_SECONDS = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString([Globalization.CultureInfo]::InvariantCulture)
    Invoke-ProtectedDemoExecutable $output @()
} finally { $env:RINGWIN_OKX_TIMESTAMP = $oldTimestamp; $env:RINGWIN_OKX_TIMESTAMP_SECONDS = $oldSeconds }
