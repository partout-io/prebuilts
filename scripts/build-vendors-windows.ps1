param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("windows-x64", "windows-arm64")]
    [string]$Target,

    [Parameter(Mandatory = $true)]
    [ValidateSet("openssl", "mbedtls", "wg-go")]
    [string]$Vendor
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = (Resolve-Path (Join-Path $scriptDir "..")).Path
$workDir = Join-Path $root ".build\$Target\$Vendor"
$installDir = Join-Path $workDir "install"
$vendorRoot = Join-Path $installDir $Vendor
$artifactsDir = Join-Path $root "artifacts"
$llvmMingwVersion = $env:LLVM_MINGW_VERSION
$llvmMingwRoot = $env:LLVM_MINGW_ROOT
$runtimeLibrary = $env:MSVC_RUNTIME_LIBRARY

switch ($Target) {
    "windows-x64" {
        $arch = "x64"
        $vcVarsArch = "amd64"
        $opensslTarget = "VC-WIN64A"
        $opensslArch = "x64"
        $goArch = "amd64"
        $mingwTriple = "x86_64-w64-mingw32"
        $dlltoolMachine = "i386:x86-64"
    }
    "windows-arm64" {
        $arch = "arm64"
        $vcVarsArch = "amd64_arm64"
        $opensslTarget = "VC-WIN64-ARM"
        $opensslArch = "arm64"
        $goArch = "arm64"
        $mingwTriple = "aarch64-w64-mingw32"
        $dlltoolMachine = "arm64"
    }
}

if ($Vendor -in @("mbedtls", "wg-go")) {
    if (-not $llvmMingwVersion) { throw "LLVM_MINGW_VERSION is required for $Vendor" }
    if (-not $llvmMingwRoot) { throw "LLVM_MINGW_ROOT is required for $Vendor" }
}

function Get-GitOutput {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $output = & git @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
    (($output | Select-Object -First 1) -as [string]).Trim()
}

function Assert-PathExists {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Missing expected path: $Path" }
}

function ConvertTo-CmdArgument {
    param([Parameter(Mandatory = $true)][string]$Argument)
    '"' + ($Argument -replace '"', '\"') + '"'
}

function Join-CmdArguments {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    ($Arguments | ForEach-Object { ConvertTo-CmdArgument $_ }) -join " "
}

$visualStudioPath = ""
$vcToolsVersion = ""
$script:vcVarsAll = ""
if ($Vendor -eq "openssl") {
    $programFilesX86 = [Environment]::GetFolderPath("ProgramFilesX86")
    $vswhere = Join-Path $programFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
    Assert-PathExists $vswhere
    $visualStudioPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
    if (-not $visualStudioPath) { throw "Unable to locate Visual Studio with MSVC tools" }
    $script:vcVarsAll = Join-Path $visualStudioPath "VC\Auxiliary\Build\vcvarsall.bat"
    Assert-PathExists $script:vcVarsAll
    $vcToolsVersionFile = Join-Path $visualStudioPath "VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt"
    if (Test-Path $vcToolsVersionFile) {
        $vcToolsVersion = (Get-Content -Raw $vcToolsVersionFile).Trim()
    }
}

function Invoke-VcVarsCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Architecture,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$Command
    )
    $cmdLine = "call `"$script:vcVarsAll`" $Architecture && cd /d `"$WorkingDirectory`" && $Command"
    & cmd.exe /d /s /c $cmdLine
    if ($LASTEXITCODE -ne 0) { throw "Command failed with exit code ${LASTEXITCODE}: $Command" }
}

function Copy-SourceTree {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    New-Item -ItemType Directory -Force $Destination | Out-Null
    Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $vendorRoot, $artifactsDir | Out-Null

$opensslDir = Join-Path $root "vendors\openssl"
$mbedtlsDir = Join-Path $root "vendors\mbedtls"
$wgGoDir = Join-Path $root "vendors\wg-go"

switch ($Vendor) {
    "openssl" {
        if (-not $runtimeLibrary) { throw "MSVC_RUNTIME_LIBRARY is required for OpenSSL" }
        Assert-PathExists (Join-Path $opensslDir "Configure")
        $buildSource = Join-Path $workDir "openssl-source"
        Copy-SourceTree $opensslDir $buildSource
        $configureArgs = @(
            "Configure", $opensslTarget,
            "--prefix=$vendorRoot", "--openssldir=$vendorRoot", "--libdir=lib",
            "no-apps", "no-docs", "no-dsa", "no-engine", "no-gost", "no-legacy",
            "no-ssl", "no-tests", "no-zlib", "shared"
        )
        $configureCommand = "perl " + (Join-CmdArguments $configureArgs)
        Invoke-VcVarsCommand -Architecture $vcVarsArch -WorkingDirectory $buildSource `
            -Command "$configureCommand && nmake /NOLOGO && nmake /NOLOGO install_sw"
    }
    "mbedtls" {
        Assert-PathExists (Join-Path $mbedtlsDir "tf-psa-crypto\scripts\basic.requirements.txt")
        $buildSource = Join-Path $workDir "mbedtls-source"
        $cmakeBuild = Join-Path $workDir "mbedtls-cmake-build"
        Copy-SourceTree $mbedtlsDir $buildSource

        $venv = Join-Path $workDir "mbedtls-python"
        & python -m venv $venv
        $python = Join-Path $venv "Scripts\python.exe"
        & $python -m pip install --disable-pip-version-check `
            -r (Join-Path $mbedtlsDir "scripts\basic.requirements.txt") `
            -r (Join-Path $mbedtlsDir "tf-psa-crypto\scripts\basic.requirements.txt")

        $cc = Join-Path $llvmMingwRoot "bin\$mingwTriple-clang.exe"
        $ar = Join-Path $llvmMingwRoot "bin\llvm-ar.exe"
        $ranlib = Join-Path $llvmMingwRoot "bin\llvm-ranlib.exe"
        Assert-PathExists $cc
        Assert-PathExists $ar
        Assert-PathExists $ranlib
        if (-not (Get-Command cmake.exe -ErrorAction SilentlyContinue)) { throw "CMake is required for Mbed TLS" }
        if (-not (Get-Command ninja.exe -ErrorAction SilentlyContinue)) { throw "Ninja is required for Mbed TLS" }
        $cmakeArgs = @(
            "-S", $buildSource,
            "-B", $cmakeBuild,
            "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_INSTALL_PREFIX=$vendorRoot",
            "-DCMAKE_INSTALL_LIBDIR=lib",
            "-DCMAKE_SYSTEM_NAME=Windows",
            "-DCMAKE_SYSTEM_PROCESSOR=$arch",
            "-DCMAKE_C_COMPILER=$cc",
            "-DCMAKE_AR=$ar",
            "-DCMAKE_RANLIB=$ranlib",
            "-DCMAKE_C_FLAGS=-O2",
            "-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY",
            "-DPython3_EXECUTABLE=$python",
            "-DGEN_FILES=ON",
            "-DENABLE_PROGRAMS=OFF",
            "-DENABLE_TESTING=OFF",
            "-DUSE_SHARED_MBEDTLS_LIBRARY=OFF",
            "-DUSE_STATIC_MBEDTLS_LIBRARY=ON"
        )
        & cmake @cmakeArgs
        if ($LASTEXITCODE -ne 0) { throw "Mbed TLS CMake configure failed with exit code $LASTEXITCODE" }
        & cmake --build $cmakeBuild --parallel $([Environment]::ProcessorCount)
        if ($LASTEXITCODE -ne 0) { throw "Mbed TLS CMake build failed with exit code $LASTEXITCODE" }
        & cmake --install $cmakeBuild
        if ($LASTEXITCODE -ne 0) { throw "Mbed TLS CMake install failed with exit code $LASTEXITCODE" }

        Copy-Item (Join-Path $vendorRoot "lib\libmbedtls.a") (Join-Path $vendorRoot "lib\mbedtls.lib")
        Copy-Item (Join-Path $vendorRoot "lib\libmbedx509.a") (Join-Path $vendorRoot "lib\mbedx509.lib")
        Copy-Item (Join-Path $vendorRoot "lib\libmbedcrypto.a") (Join-Path $vendorRoot "lib\mbedcrypto.lib")
    }
    "wg-go" {
        $cc = Join-Path $llvmMingwRoot "bin\$mingwTriple-clang.exe"
        $cxx = Join-Path $llvmMingwRoot "bin\$mingwTriple-clang++.exe"
        $dlltool = Join-Path $llvmMingwRoot "bin\llvm-dlltool.exe"
        Assert-PathExists $cc
        Assert-PathExists $cxx
        Assert-PathExists $dlltool
        New-Item -ItemType Directory -Force (Join-Path $vendorRoot "include"), (Join-Path $vendorRoot "lib") | Out-Null
        Copy-Item (Join-Path $wgGoDir "include\*") (Join-Path $vendorRoot "include") -Recurse -Force
        New-Item -ItemType Directory -Force (Join-Path $vendorRoot "lib\cmake\WgGo") | Out-Null
        Copy-Item (Join-Path $wgGoDir "cmake\*") (Join-Path $vendorRoot "lib\cmake\WgGo") -Force

        $previousEnvironment = @{
            CGO_ENABLED = $env:CGO_ENABLED; GOOS = $env:GOOS; GOARCH = $env:GOARCH;
            CC = $env:CC; CXX = $env:CXX; CGO_CFLAGS = $env:CGO_CFLAGS;
            CGO_CXXFLAGS = $env:CGO_CXXFLAGS
        }
        try {
            $env:CGO_ENABLED = "1"
            $env:GOOS = "windows"
            $env:GOARCH = $goArch
            $env:CC = $cc
            $env:CXX = $cxx
            $env:CGO_CFLAGS = "--target=$mingwTriple"
            $env:CGO_CXXFLAGS = "--target=$mingwTriple"
            & go build -C (Join-Path $wgGoDir "src") -ldflags=-w -trimpath -v `
                -o (Join-Path $vendorRoot "lib\wg-go.dll") -buildmode=c-shared
            if ($LASTEXITCODE -ne 0) { throw "wg-go build failed with exit code $LASTEXITCODE" }
        } finally {
            foreach ($entry in $previousEnvironment.GetEnumerator()) {
                if ($null -eq $entry.Value) {
                    Remove-Item -Path "env:$($entry.Key)" -ErrorAction SilentlyContinue
                } else {
                    Set-Item -Path "env:$($entry.Key)" -Value $entry.Value
                }
            }
        }
        & $dlltool -m $dlltoolMachine -d (Join-Path $wgGoDir "exports.def") -l (Join-Path $vendorRoot "lib\wg-go.lib")
        if ($LASTEXITCODE -ne 0) { throw "llvm-dlltool failed with exit code $LASTEXITCODE" }
    }
}

switch ($Vendor) {
    "openssl" {
        Assert-PathExists (Join-Path $vendorRoot "include")
        Assert-PathExists (Join-Path $vendorRoot "lib\libssl.lib")
        Assert-PathExists (Join-Path $vendorRoot "lib\libcrypto.lib")
        Assert-PathExists (Join-Path $vendorRoot "bin\libssl-3-$opensslArch.dll")
        Assert-PathExists (Join-Path $vendorRoot "bin\libcrypto-3-$opensslArch.dll")
    }
    "mbedtls" {
        Assert-PathExists (Join-Path $vendorRoot "include")
        Assert-PathExists (Join-Path $vendorRoot "lib\cmake\MbedTLS\MbedTLSConfig.cmake")
        Assert-PathExists (Join-Path $vendorRoot "lib\libtfpsacrypto.a")
        Assert-PathExists (Join-Path $vendorRoot "lib\mbedtls.lib")
        Assert-PathExists (Join-Path $vendorRoot "lib\mbedx509.lib")
        Assert-PathExists (Join-Path $vendorRoot "lib\mbedcrypto.lib")
    }
    "wg-go" {
        Assert-PathExists (Join-Path $vendorRoot "include")
        Assert-PathExists (Join-Path $vendorRoot "lib\cmake\WgGo\WgGoConfig.cmake")
        Assert-PathExists (Join-Path $vendorRoot "lib\wg-go.dll")
        Assert-PathExists (Join-Path $vendorRoot "lib\wg-go.lib")
    }
}

if ($Vendor -in @("mbedtls", "wg-go")) {
    $smokeBuild = Join-Path $workDir "cmake-package-smoke"
    $smokeOption = if ($Vendor -eq "mbedtls") { "-DTEST_MBEDTLS=ON" } else { "-DTEST_WGGO=ON" }
    & cmake -S (Join-Path $root "tests\cmake-packages") -B $smokeBuild `
        "-DCMAKE_PREFIX_PATH=$vendorRoot" $smokeOption
    if ($LASTEXITCODE -ne 0) { throw "$Vendor CMake package smoke test failed with exit code $LASTEXITCODE" }
}

$prebuiltsRemote = ((& git -C $root remote) | Select-Object -First 1) -as [string]
$prebuiltsRepository = if ($prebuiltsRemote) {
    Get-GitOutput -Arguments @("-C", $root, "remote", "get-url", $prebuiltsRemote.Trim())
} else { "" }
$prebuiltsRef = Get-GitOutput -Arguments @("-C", $root, "rev-parse", "HEAD")
$libraries = [ordered]@{}
$goVersion = ""
switch ($Vendor) {
    "openssl" {
        $libraries["openssl"] = [ordered]@{
            version = Get-GitOutput -Arguments @("-C", $opensslDir, "describe", "--tags", "--always", "--dirty")
            ref = Get-GitOutput -Arguments @("-C", $opensslDir, "rev-parse", "HEAD")
            linkage = "shared"
        }
    }
    "mbedtls" {
        $libraries["mbedtls"] = [ordered]@{
            version = Get-GitOutput -Arguments @("-C", $mbedtlsDir, "describe", "--tags", "--always", "--dirty")
            ref = Get-GitOutput -Arguments @("-C", $mbedtlsDir, "rev-parse", "HEAD")
            linkage = "static"
        }
    }
    "wg-go" {
        $wireGuardGoVersion = ""
        foreach ($line in Get-Content (Join-Path $wgGoDir "go.sum")) {
            if ($line -match "^\s*golang\.zx2c4\.com/wireguard\s+(\S+)\s+" -and $Matches[1] -notlike "*/go.mod") {
                $wireGuardGoVersion = $Matches[1]
                break
            }
        }
        if (-not $wireGuardGoVersion) { throw "Unable to resolve wireguard-go version" }
        $goVersion = ((& go env GOVERSION) | Select-Object -First 1).Trim()
        $libraries["wg-go"] = [ordered]@{
            sourceRef = $prebuiltsRef
            wireguardGoVersion = $wireGuardGoVersion
            linkage = "shared"
        }
    }
}

$makeVersion = ""
$makeCommand = Get-Command make.exe -ErrorAction SilentlyContinue
if ($makeCommand) { $makeVersion = ((& $makeCommand.Source --version) | Select-Object -First 1).Trim() }
$clangVersion = ""
if ($Vendor -in @("mbedtls", "wg-go")) {
    $clang = Join-Path $llvmMingwRoot "bin\$mingwTriple-clang.exe"
    $clangVersion = ((& $clang --version) | Select-Object -First 1).Trim()
}
$cmakeVersion = ""
$ninjaVersion = ""
if ($Vendor -in @("mbedtls", "wg-go")) {
    $cmakeVersion = ((& cmake --version) | Select-Object -First 1) -replace "^cmake version ", ""
}
if ($Vendor -eq "mbedtls") {
    $ninjaVersion = ((& ninja --version) | Select-Object -First 1).Trim()
}
$manifest = [ordered]@{
    schemaVersion = 1
    target = $Target
    vendor = $Vendor
    os = "windows"
    arch = $arch
    prebuilts = [ordered]@{ repository = $prebuiltsRepository; ref = $prebuiltsRef }
    libraries = $libraries
    toolchains = [ordered]@{
        go = $goVersion
        cmake = $cmakeVersion
        ninja = $ninjaVersion
        make = $makeVersion
        llvmMingw = $llvmMingwVersion
        clang = $clangVersion
        visualStudio = $visualStudioPath
        vcTools = $vcToolsVersion
        msvcRuntimeLibrary = $runtimeLibrary
    }
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $vendorRoot "manifest.json")

$packageName = "$Vendor-$Target.zip"
$packagePath = Join-Path $artifactsDir $packageName
Compress-Archive -Path (Join-Path $vendorRoot "*") -DestinationPath $packagePath -Force
