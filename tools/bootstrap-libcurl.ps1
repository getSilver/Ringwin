[CmdletBinding()]
param(
    [string]$BuildRoot = (Join-Path $PSScriptRoot '..\.scratch\build'),
    [int]$Parallel = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$downloads = @(
    @{ Name = 'curl'; File = 'curl.zip'; Url = 'https://curl.se/download/curl-8.21.0.zip'; Sha256 = 'A99651D2B9EE0BF858C590078B1B0F989C187B07009E88BF94C0EC614BE1BC7D' },
    @{ Name = 'cmake'; File = 'cmake.zip'; Url = 'https://github.com/Kitware/CMake/releases/download/v4.3.3/cmake-4.3.3-windows-x86_64.zip'; Sha256 = '935ADE9E5E8723583C07F44C5592CEA2A1C8F65C56CA7E07B34C025C880E0BD6' },
    @{ Name = 'ninja'; File = 'ninja.zip'; Url = 'https://github.com/ninja-build/ninja/releases/download/v1.13.2/ninja-win.zip'; Sha256 = '07FC8261B42B20E71D1720B39068C2E14FFCEE6396B76FB7A795FB460B78DC65' }
)

$buildRootPath = [IO.Path]::GetFullPath($BuildRoot)
$workspacePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $buildRootPath.StartsWith($workspacePath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'BuildRoot must remain inside this workspace'
}
if ($Parallel -lt 1 -or $Parallel -gt 32) { throw 'Parallel must be between 1 and 32' }

$bootstrap = Join-Path $buildRootPath 'bootstrap'
New-Item -ItemType Directory -Path $bootstrap -Force | Out-Null
foreach ($download in $downloads) {
    $archive = Join-Path $bootstrap $download.File
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        Invoke-WebRequest -Uri $download.Url -OutFile $archive
    }
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ($actual -ne $download.Sha256) { throw "SHA256 mismatch for $($download.Name)" }
}

$sourceArchive = Join-Path $bootstrap 'curl.zip'
$sourceRoot = Join-Path $bootstrap 'curl-source'
$cmakeRoot = Join-Path $bootstrap 'cmake-tool'
$ninjaRoot = Join-Path $bootstrap 'ninja-tool'
foreach ($path in @($sourceRoot, $cmakeRoot, $ninjaRoot)) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        New-Item -ItemType Directory -Path $path | Out-Null
    }
}
if (-not (Get-ChildItem -LiteralPath $sourceRoot -Force)) { tar.exe -xf $sourceArchive -C $sourceRoot }
if (-not (Get-ChildItem -LiteralPath $cmakeRoot -Force)) { tar.exe -xf (Join-Path $bootstrap 'cmake.zip') -C $cmakeRoot }
if (-not (Get-ChildItem -LiteralPath $ninjaRoot -Force)) { tar.exe -xf (Join-Path $bootstrap 'ninja.zip') -C $ninjaRoot }

$curlSource = (Get-ChildItem -LiteralPath $sourceRoot -Directory -Filter 'curl-*' | Select-Object -First 1).FullName
$cmake = (Get-ChildItem -LiteralPath $cmakeRoot -Recurse -File -Filter 'cmake.exe' | Select-Object -First 1).FullName
$ninja = (Get-ChildItem -LiteralPath $ninjaRoot -Recurse -File -Filter 'ninja.exe' | Select-Object -First 1).FullName
$zig = (Get-Command zig -ErrorAction Stop).Source
$zigAr = (Resolve-Path (Join-Path $PSScriptRoot 'zig-ar.cmd')).Path
$zigRanlib = (Resolve-Path (Join-Path $PSScriptRoot 'zig-ranlib.cmd')).Path
$output = Join-Path $buildRootPath 'libcurl-8.21.0-windows-x86_64-schannel'

& $cmake -S $curlSource -B $output -G Ninja `
    "-DCMAKE_MAKE_PROGRAM=$ninja" "-DCMAKE_C_COMPILER=$zig" `
    -DCMAKE_C_COMPILER_ARG1=cc "-DCMAKE_AR=$zigAr" "-DCMAKE_RANLIB=$zigRanlib" `
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DCMAKE_BUILD_TYPE=Release `
    -DBUILD_SHARED_LIBS=OFF -DBUILD_CURL_EXE=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF `
    -DCURL_USE_SCHANNEL=ON -DCURL_USE_LIBPSL=OFF -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF `
    -DCURL_ZSTD=OFF -DUSE_NGHTTP2=OFF -DUSE_NGHTTP3=OFF -DUSE_QUICHE=OFF `
    -DCURL_DISABLE_LDAP=ON -DCURL_DISABLE_LDAPS=ON -DCURL_DISABLE_FTP=ON `
    -DCURL_DISABLE_FILE=ON -DCURL_DISABLE_TELNET=ON -DCURL_DISABLE_TFTP=ON `
    -DCURL_DISABLE_DICT=ON -DCURL_DISABLE_POP3=ON -DCURL_DISABLE_IMAP=ON `
    -DCURL_DISABLE_SMTP=ON -DCURL_DISABLE_GOPHER=ON -DCURL_DISABLE_MQTT=ON `
    -DCURL_DISABLE_RTSP=ON -DCURL_DISABLE_WEBSOCKETS=OFF
if ($LASTEXITCODE -ne 0) { throw 'libcurl configure failed' }
& $cmake --build $output --config Release --parallel $Parallel
if ($LASTEXITCODE -ne 0) { throw 'libcurl build failed' }

[ordered]@{
    version = '8.21.0'
    tls_backend = 'Schannel'
    protocols = @('http', 'https', 'ws', 'wss')
    build_root = $output
} | ConvertTo-Json
