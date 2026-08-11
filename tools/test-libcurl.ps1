[CmdletBinding()]
param(
    [string]$BuildRoot = (Join-Path $PSScriptRoot '..\.scratch\build\libcurl-8.21.0-windows-x86_64-schannel')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = Join-Path $PSScriptRoot '..\.scratch\build\bootstrap\curl-source'
if (-not (Test-Path -LiteralPath $sourceRoot)) {
    $sourceRoot = Join-Path $PSScriptRoot '..\.scratch\build\bootstrap\curl'
}
$include = (Get-ChildItem -LiteralPath $sourceRoot -Recurse -Directory -Filter include | Where-Object {
    Test-Path -LiteralPath (Join-Path $_.FullName 'curl\curl.h')
} | Select-Object -First 1).FullName
$library = (Get-ChildItem -LiteralPath $BuildRoot -Recurse -File -Filter 'libcurl.a' | Select-Object -First 1)
if (-not $include -or -not $library) { throw 'Run tools/bootstrap-libcurl.ps1 first' }

& zig test (Join-Path $PSScriptRoot '..\src\okx_curl_transport.zig') `
    (Join-Path $PSScriptRoot '..\src\okx_curl_shim.c') `
    "-I$include" "-L$($library.DirectoryName)" -lc -lcurl `
    -lws2_32 -lcrypt32 -lsecur32 -ladvapi32 -lbcrypt -lwldap32 -lnormaliz -liphlpapi
if ($LASTEXITCODE -ne 0) { throw 'libcurl qualification test failed' }

$previousHttpsProxy = $env:HTTPS_PROXY
try {
    $destination = [Uri]'https://openapi.okx.com'
    $systemProxy = [Net.WebRequest]::DefaultWebProxy
    if ($systemProxy -and -not $systemProxy.IsBypassed($destination)) {
        $env:HTTPS_PROXY = $systemProxy.GetProxy($destination).AbsoluteUri
    }
    & zig run (Join-Path $PSScriptRoot '..\src\okx_curl_public_smoke.zig') `
        (Join-Path $PSScriptRoot '..\src\okx_curl_shim.c') `
        "-I$include" "-L$($library.DirectoryName)" -lc -lcurl `
        -lws2_32 -lcrypt32 -lsecur32 -ladvapi32 -lbcrypt -lwldap32 -lnormaliz -liphlpapi
    if ($LASTEXITCODE -ne 0) { throw 'libcurl public HTTPS smoke failed' }
} finally {
    $env:HTTPS_PROXY = $previousHttpsProxy
}
