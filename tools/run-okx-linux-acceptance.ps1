[CmdletBinding()]
param(
    [ValidateSet('PrepareOnly', 'DemoLive', 'CleanupOnly')]
    [string]$Mode = 'PrepareOnly',
    [switch]$SystemOwnerAuthorized,
    [string]$Distro = 'Ubuntu',
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env.local'),
    [string]$CurlBuildRoot = (Join-Path $PSScriptRoot '..\.scratch\build\curl-linux-openssl-3'),
    [string]$OpenSSLRoot = (Join-Path $PSScriptRoot '..\.scratch\build\linux-deps\openssl3\root\usr'),
    [string]$Output = (Join-Path $PSScriptRoot '..\.scratch\build\okx-demo-live-acceptance-linux'),
    [string]$PolicyFile = (Join-Path $PSScriptRoot '..\.scratch\okx-demo-policy.json'),
    [string]$StateDirectory = (Join-Path $PSScriptRoot '..\.scratch\okx-demo-authority'),
    [string]$Proxy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Mode -ne 'PrepareOnly' -and -not $SystemOwnerAuthorized) {
    throw "$Mode requires the current SystemOwner authorization switch"
}

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$envPath = [IO.Path]::GetFullPath($EnvFile)
$curlRoot = [IO.Path]::GetFullPath($CurlBuildRoot)
$opensslRoot = [IO.Path]::GetFullPath($OpenSSLRoot)
$outputPath = [IO.Path]::GetFullPath($Output)
$policyPath = [IO.Path]::GetFullPath($PolicyFile)
$statePath = [IO.Path]::GetFullPath($StateDirectory)
foreach ($path in @($envPath, $curlRoot, $opensslRoot, $outputPath, $policyPath, $statePath)) {
    if (-not $path.StartsWith($workspace, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path must remain inside the workspace: $path"
    }
}
if ($Mode -ne 'PrepareOnly' -and -not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
    throw "Versioned Demo policy is missing: $policyPath"
}

$zig = (Get-Command zig -ErrorAction Stop).Source
$sourceRoot = Join-Path $workspace '.scratch\build\bootstrap\curl-source\curl-8.21.0'
$include = Join-Path $sourceRoot 'include'
$curlLibrary = Join-Path $curlRoot 'lib\libcurl.a'
$sslLibrary = Join-Path $opensslRoot 'lib\x86_64-linux-gnu\libssl.a'
$cryptoLibrary = Join-Path $opensslRoot 'lib\x86_64-linux-gnu\libcrypto.a'
$zLibrary = Join-Path $workspace '.scratch\build\linux-deps\root\usr\lib\x86_64-linux-gnu\libz.a'
foreach ($path in @($include, $curlLibrary, $sslLibrary, $cryptoLibrary, $zLibrary)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -and $path -ne $include) {
        throw "Linux libcurl dependency is missing: $path"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $include 'curl\curl.h') -PathType Leaf)) {
    throw "Pinned libcurl headers are missing: $include"
}

& $zig build-exe (Join-Path $workspace 'src\okx_demo_live_acceptance.zig') `
    (Join-Path $workspace 'src\okx_curl_shim.c') -target x86_64-linux-gnu -OReleaseSafe `
    "-I$include" $curlLibrary $sslLibrary $cryptoLibrary $zLibrary -lpthread -ldl `
    "-femit-bin=$outputPath"
if ($LASTEXITCODE -ne 0) { throw 'Linux OKX acceptance build failed' }

function ConvertTo-ShellLiteral([string]$value) {
    return "'$(($value -replace "'", "'\\''"))'"
}
function ConvertTo-WslPath([string]$path) {
    return '/mnt/' + $path.Substring(0, 1).ToLowerInvariant() + $path.Substring(2).Replace('\', '/')
}

$envPathPosix = ConvertTo-WslPath $envPath
$outputPosix = ConvertTo-WslPath $outputPath
$policyPosix = ConvertTo-WslPath $policyPath
$statePosix = ConvertTo-WslPath $statePath
$opensslLibPosix = ConvertTo-WslPath (Join-Path $opensslRoot 'lib\x86_64-linux-gnu')
$invocation = switch ($Mode) {
    'DemoLive' { "$outputPosix --demo-live" }
    'CleanupOnly' { "$outputPosix --cleanup-only" }
    default { "$outputPosix --prepare-only" }
}
$proxyLine = if ([string]::IsNullOrWhiteSpace($Proxy)) { '' } else {
    "export HTTPS_PROXY=$(ConvertTo-ShellLiteral $Proxy)`nexport HTTP_PROXY=$(ConvertTo-ShellLiteral $Proxy)"
}
$linuxScript = @"
set -eu
ENV_FILE=$envPathPosix
$proxyLine
export RINGWIN_OKX_KEY=`$(grep ^OKX_DEMO_API_KEY= `$ENV_FILE | cut -d= -f2-)
export RINGWIN_OKX_SECRET=`$(grep ^OKX_DEMO_SECRET_KEY= `$ENV_FILE | cut -d= -f2-)
export RINGWIN_OKX_PASSPHRASE=`$(grep ^OKX_DEMO_PASSPHRASE= `$ENV_FILE | cut -d= -f2-)
export RINGWIN_OKX_REST_BASE_URL=`$(grep ^OKX_DEMO_REST_BASE_URL= `$ENV_FILE | cut -d= -f2-)
export RINGWIN_OKX_ENTITY=`$(grep ^OKX_ENTITY= `$ENV_FILE | cut -d= -f2-)
export RINGWIN_DEMO_POLICY_PATH=$policyPosix
export RINGWIN_DEMO_STATE_DIR=$statePosix
export LD_LIBRARY_PATH=$opensslLibPosix
$invocation
"@ -replace "`r`n", "`n"

$linuxScriptPath = Join-Path $workspace '.scratch\build\okx-linux-acceptance.sh'
[IO.File]::WriteAllText($linuxScriptPath, $linuxScript, [Text.UTF8Encoding]::new($false))
wsl.exe -d $Distro -- /bin/sh (ConvertTo-WslPath $linuxScriptPath)
if ($LASTEXITCODE -ne 0) { throw "Linux OKX acceptance failed in WSL distro $Distro" }

$qualification = if ($Mode -eq 'PrepareOnly') { 'observation_only' } else { 'demo_qualified' }
Write-Output "okx_linux_acceptance=passed mode=$($Mode.ToLowerInvariant()) writes=$([int]($Mode -ne 'PrepareOnly')) qualification=$qualification production_qualification=false"
