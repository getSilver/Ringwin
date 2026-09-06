[CmdletBinding()]
param(
    [ValidateSet('PrepareOnly', 'DemoLive')]
    [string]$Mode = 'PrepareOnly',
    [switch]$SystemOwnerAuthorized,
    [string]$Distro = 'Ubuntu',
    [string]$EnvFile = (Join-Path $PSScriptRoot '..\.env.local'),
    [string]$CurlBuildRoot = (Join-Path $PSScriptRoot '..\.scratch\build\curl-linux-openssl-3'),
    [string]$OpenSSLRoot = (Join-Path $PSScriptRoot '..\.scratch\build\linux-deps\openssl3\root\usr'),
    [string]$Output = (Join-Path $PSScriptRoot '..\.scratch\build\okx-demo-live-acceptance-linux'),
    [string]$Proxy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Mode -eq 'DemoLive' -and -not $SystemOwnerAuthorized) {
    throw 'DemoLive requires the current SystemOwner authorization switch'
}

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$envPath = [IO.Path]::GetFullPath($EnvFile)
$curlRoot = [IO.Path]::GetFullPath($CurlBuildRoot)
$opensslRoot = [IO.Path]::GetFullPath($OpenSSLRoot)
$outputPath = [IO.Path]::GetFullPath($Output)
foreach ($path in @($envPath, $curlRoot, $opensslRoot, $outputPath)) {
    if (-not $path.StartsWith($workspace, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path must remain inside the workspace: $path"
    }
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
$opensslLibPosix = ConvertTo-WslPath (Join-Path $opensslRoot 'lib\x86_64-linux-gnu')
$invocation = if ($Mode -eq 'DemoLive') { "$outputPosix --demo-live" } else { "$outputPosix --prepare-only" }
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
export LD_LIBRARY_PATH=$opensslLibPosix
$invocation
"@ -replace "`r`n", "`n"

$linuxScriptPath = Join-Path $workspace '.scratch\build\okx-linux-acceptance.sh'
[IO.File]::WriteAllText($linuxScriptPath, $linuxScript, [Text.UTF8Encoding]::new($false))
wsl.exe -d $Distro -- /bin/sh (ConvertTo-WslPath $linuxScriptPath)
if ($LASTEXITCODE -ne 0) { throw "Linux OKX acceptance failed in WSL distro $Distro" }

$qualification = if ($Mode -eq 'DemoLive') { 'demo_qualified' } else { 'observation_only' }
Write-Output "okx_linux_acceptance=passed mode=$($Mode.ToLowerInvariant()) writes=$([int]($Mode -eq 'DemoLive')) qualification=$qualification production_qualification=false"
