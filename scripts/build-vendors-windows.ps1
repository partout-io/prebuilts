param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("windows-x64", "windows-arm64")]
    [string]$Target,

    [Parameter(Mandatory = $true)]
    [ValidateSet("openssl", "mbedtls")]
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
$runtimeLibrary = $env:MSVC_RUNTIME_LIBRARY

switch ($Target) {
    "windows-x64" {
        $arch = "x64"
        $vcVarsArch = "amd64"
        $opensslTarget = "VC-WIN64A"
        $opensslArch = "x64"
    }
    "windows-arm64" {
        $arch = "arm64"
        $vcVarsArch = "amd64_arm64"
        $opensslTarget = "VC-WIN64-ARM"
        $opensslArch = "arm64"
    }
}

if (-not $runtimeLibrary) { throw "MSVC_RUNTIME_LIBRARY is required for $Vendor" }
if ($runtimeLibrary -notin @("MultiThreaded", "MultiThreadedDLL", "MultiThreadedDebug", "MultiThreadedDebugDLL")) {
    throw "Unsupported MSVC_RUNTIME_LIBRARY: $runtimeLibrary"
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

switch ($Vendor) {
    "openssl" {
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

        if (-not (Get-Command cmake.exe -ErrorAction SilentlyContinue)) { throw "CMake is required for Mbed TLS" }
        if (-not (Get-Command ninja.exe -ErrorAction SilentlyContinue)) { throw "Ninja is required for Mbed TLS" }
        $cmakeArgs = @(
            "-S", $buildSource,
            "-B", $cmakeBuild,
            "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_INSTALL_PREFIX=$vendorRoot",
            "-DCMAKE_INSTALL_LIBDIR=lib",
            "-DCMAKE_C_COMPILER=cl.exe",
            "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
            "-DCMAKE_MSVC_RUNTIME_LIBRARY=$runtimeLibrary",
            "-DPython3_EXECUTABLE=$python",
            "-DGEN_FILES=ON",
            "-DENABLE_PROGRAMS=OFF",
            "-DENABLE_TESTING=OFF",
            "-DUSE_SHARED_MBEDTLS_LIBRARY=OFF",
            "-DUSE_STATIC_MBEDTLS_LIBRARY=ON"
        )
        $configureCommand = "cmake " + (Join-CmdArguments $cmakeArgs)
        Invoke-VcVarsCommand -Architecture $vcVarsArch -WorkingDirectory $workDir -Command $configureCommand
        Invoke-VcVarsCommand -Architecture $vcVarsArch -WorkingDirectory $workDir `
            -Command "cmake --build `"$cmakeBuild`" --parallel $([Environment]::ProcessorCount)"
        Invoke-VcVarsCommand -Architecture $vcVarsArch -WorkingDirectory $workDir `
            -Command "cmake --install `"$cmakeBuild`""

        # Mbed TLS 4 retains the historical mbedcrypto name as a GNU-style alias.
        # Give MSVC consumers the same compatibility library with its native suffix.
        Copy-Item (Join-Path $vendorRoot "lib\tfpsacrypto.lib") (Join-Path $vendorRoot "lib\mbedcrypto.lib")
        Remove-Item (Join-Path $vendorRoot "lib\libmbedcrypto.a") -Force -ErrorAction SilentlyContinue
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
        Assert-PathExists (Join-Path $vendorRoot "lib\tfpsacrypto.lib")
        Assert-PathExists (Join-Path $vendorRoot "lib\mbedtls.lib")
        Assert-PathExists (Join-Path $vendorRoot "lib\mbedx509.lib")
        Assert-PathExists (Join-Path $vendorRoot "lib\mbedcrypto.lib")
        $gnuArchives = @(Get-ChildItem (Join-Path $vendorRoot "lib") -Filter "*.a")
        if ($gnuArchives.Count -ne 0) {
            throw "Mbed TLS MSVC package unexpectedly contains GNU archives: $($gnuArchives.Name -join ', ')"
        }
    }
}

if ($Vendor -eq "mbedtls") {
    $smokeBuild = Join-Path $workDir "cmake-package-smoke"
    $smokeOption = "-DTEST_MBEDTLS=ON"
    $smokeArgs = @(
        "-S", (Join-Path $root "tests\cmake-packages"),
        "-B", $smokeBuild,
        "-DCMAKE_PREFIX_PATH=$vendorRoot",
        $smokeOption
    )
    $smokeArgs += @(
        "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_C_COMPILER=cl.exe",
        "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=$runtimeLibrary"
    )
    $smokeCommand = "cmake " + (Join-CmdArguments $smokeArgs)
    Invoke-VcVarsCommand -Architecture $vcVarsArch -WorkingDirectory $workDir -Command $smokeCommand
    Invoke-VcVarsCommand -Architecture $vcVarsArch -WorkingDirectory $workDir `
        -Command "cmake --build `"$smokeBuild`" --parallel $([Environment]::ProcessorCount)"
}

$prebuiltsRemote = ((& git -C $root remote) | Select-Object -First 1) -as [string]
$prebuiltsRepository = if ($prebuiltsRemote) {
    Get-GitOutput -Arguments @("-C", $root, "remote", "get-url", $prebuiltsRemote.Trim())
} else { "" }
$prebuiltsRef = Get-GitOutput -Arguments @("-C", $root, "rev-parse", "HEAD")
$libraries = [ordered]@{}
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
}

$makeVersion = ""
$makeCommand = Get-Command make.exe -ErrorAction SilentlyContinue
if ($makeCommand) { $makeVersion = ((& $makeCommand.Source --version) | Select-Object -First 1).Trim() }
$compiler = "MSVC"
$manifestRuntimeLibrary = $runtimeLibrary
$cmakeVersion = ""
$ninjaVersion = ""
if ($Vendor -eq "mbedtls") {
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
        cmake = $cmakeVersion
        ninja = $ninjaVersion
        make = $makeVersion
        compiler = $compiler
        visualStudio = $visualStudioPath
        vcTools = $vcToolsVersion
        msvcRuntimeLibrary = $manifestRuntimeLibrary
    }
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $vendorRoot "manifest.json")

$packageName = "$Vendor-$Target.zip"
$packagePath = Join-Path $artifactsDir $packageName
Compress-Archive -Path (Join-Path $vendorRoot "*") -DestinationPath $packagePath -Force
