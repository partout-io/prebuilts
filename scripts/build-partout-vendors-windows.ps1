param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("windows-x64", "windows-arm64")]
    [string]$Target
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$partoutRepository = $env:PARTOUT_REPOSITORY
$partoutRef = $env:PARTOUT_REF
$opensslVersion = $env:OPENSSL_VERSION
$mbedtlsVersion = $env:MBEDTLS_VERSION
$wireGuardGoVersion = $env:WIREGUARD_GO_VERSION
$llvmMingwVersion = $env:LLVM_MINGW_VERSION
$llvmMingwRoot = $env:LLVM_MINGW_ROOT
$runtimeLibrary = $env:MSVC_RUNTIME_LIBRARY

if (-not $partoutRepository) { throw "PARTOUT_REPOSITORY is required" }
if (-not $partoutRef) { throw "PARTOUT_REF is required" }
if (-not $opensslVersion) { throw "OPENSSL_VERSION is required" }
if (-not $mbedtlsVersion) { throw "MBEDTLS_VERSION is required" }
if (-not $wireGuardGoVersion) { throw "WIREGUARD_GO_VERSION is required" }
if (-not $llvmMingwVersion) { throw "LLVM_MINGW_VERSION is required" }
if (-not $llvmMingwRoot) { throw "LLVM_MINGW_ROOT is required" }
if (-not $runtimeLibrary) { throw "MSVC_RUNTIME_LIBRARY is required" }

$root = (Get-Location).Path
$partoutDir = Join-Path $root ".build\partout"
$workDir = Join-Path $root ".build\$Target"
$buildDir = Join-Path $workDir "cmake-build"
$vendorOutputDir = Join-Path $workDir "vendor-output"
$installDir = Join-Path $workDir "install"
$artifactsDir = Join-Path $root "artifacts"
$vendors = @("openssl", "mbedtls", "wg-go")

switch ($Target) {
    "windows-x64" {
        $arch = "x64"
        $cmakeProcessor = "AMD64"
        $vcVarsArch = "amd64"
        $opensslArch = "x64"
    }
    "windows-arm64" {
        $arch = "arm64"
        $cmakeProcessor = "ARM64"
        $vcVarsArch = "amd64_arm64"
        $opensslArch = "arm64"
    }
}

if (-not (Test-Path $partoutDir)) {
    throw "Partout checkout not found: $partoutDir"
}

$programFilesX86 = [Environment]::GetFolderPath("ProgramFilesX86")
$vswhere = Join-Path $programFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    throw "Unable to locate vswhere.exe at $vswhere"
}

$visualStudioPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if (-not $visualStudioPath) {
    throw "Unable to locate a Visual Studio installation with MSVC tools"
}

$script:vcVarsAll = Join-Path $visualStudioPath "VC\Auxiliary\Build\vcvarsall.bat"
if (-not (Test-Path $script:vcVarsAll)) {
    throw "Unable to locate vcvarsall.bat at $script:vcVarsAll"
}

$vcToolsVersionFile = Join-Path $visualStudioPath "VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt"
$vcToolsVersion = ""
if (Test-Path $vcToolsVersionFile) {
    $vcToolsVersion = (Get-Content -Raw $vcToolsVersionFile).Trim()
}

$msbuild = Join-Path $visualStudioPath "MSBuild\Current\Bin\MSBuild.exe"
$msbuildVersion = ""
if (Test-Path $msbuild) {
    $msbuildVersion = ((& $msbuild -version -nologo) | Select-Object -Last 1).Trim()
}

$cmakeVersion = ((& cmake --version) | Select-Object -First 1) -replace "^cmake version ", ""
$ninjaVersion = ""
if (Get-Command ninja -ErrorAction SilentlyContinue) {
    $ninjaVersion = ((& ninja --version) | Select-Object -First 1).Trim()
}
$goVersion = ""
if (Get-Command go -ErrorAction SilentlyContinue) {
    $goVersion = ((& go env GOVERSION) | Select-Object -First 1).Trim()
}
$nasmVersion = ""
if (Get-Command nasm -ErrorAction SilentlyContinue) {
    $nasmVersion = ((& nasm -v) | Select-Object -First 1).Trim()
}

Remove-Item -Recurse -Force $workDir, $artifactsDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $buildDir, $vendorOutputDir, $installDir, $artifactsDir | Out-Null

function ConvertTo-CmdArgument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Argument
    )

    '"' + ($Argument -replace '"', '\"') + '"'
}

function Join-CmdArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    ($Arguments | ForEach-Object { ConvertTo-CmdArgument $_ }) -join " "
}

function Invoke-VcVarsCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    $cmdLine = "call ""$script:vcVarsAll"" $Architecture && cd /d ""$WorkingDirectory"" && $Command"
    & cmd.exe /d /s /c $cmdLine
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $Command"
    }
}

function Assert-PathExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Missing expected path: $Path"
    }
}

$cmakeArgs = @(
    "-S", $partoutDir,
    "-B", $buildDir,
    "-G", "Ninja",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_INSTALL_PREFIX=$installDir",
    "-DCMAKE_POLICY_DEFAULT_CMP0091=NEW",
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=$runtimeLibrary",
    "-DCMAKE_SYSTEM_PROCESSOR=$cmakeProcessor",
    "-DPP_BUILD_OUTPUT=$vendorOutputDir",
    "-DPP_BUILD_LIBRARY=OFF",
    "-DPP_BUILD_VENDOR_SOURCE=bundled",
    "-DPP_BUILD_USE_OPENSSL=ON",
    "-DPP_BUILD_USE_MBEDTLS=ON",
    "-DPP_BUILD_USE_WIREGUARD=ON"
)

$configureCommand = "cmake " + (Join-CmdArguments $cmakeArgs)
$buildCommand = "cmake --build " + (Join-CmdArguments @($buildDir, "--parallel"))
$installCommand = "cmake --install " + (Join-CmdArguments @($buildDir))
Invoke-VcVarsCommand -Architecture $vcVarsArch -WorkingDirectory $root -Command "$configureCommand && $buildCommand && $installCommand"

function Assert-VendorPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Vendor
    )

    $vendorRoot = Join-Path $installDir $Vendor
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
            Assert-PathExists (Join-Path $vendorRoot "lib\mbedtls.lib")
            Assert-PathExists (Join-Path $vendorRoot "lib\mbedx509.lib")
            Assert-PathExists (Join-Path $vendorRoot "lib\mbedcrypto.lib")
        }
        "wg-go" {
            Assert-PathExists (Join-Path $vendorRoot "include")
            Assert-PathExists (Join-Path $vendorRoot "lib\wg-go.dll")
            Assert-PathExists (Join-Path $vendorRoot "lib\wg-go.lib")
        }
        default {
            throw "Unknown vendor: $Vendor"
        }
    }
}

function New-Manifest {
    $libraries = [ordered]@{}
    $libraries["openssl"] = [ordered]@{
        version = $opensslVersion
        linkage = "shared"
    }
    $libraries["mbedtls"] = [ordered]@{
        version = $mbedtlsVersion
        linkage = "static"
    }
    $libraries["wg-go"] = [ordered]@{
        partoutRef = $partoutRef
        wireguardGoVersion = $wireGuardGoVersion
        linkage = "shared"
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        target = $Target
        os = "windows"
        arch = $arch
        partout = [ordered]@{
            repository = $partoutRepository
            ref = $partoutRef
        }
        libraries = $libraries
        toolchains = [ordered]@{
            go = $goVersion
            cmake = $cmakeVersion
            ninja = $ninjaVersion
            llvmMingw = $llvmMingwVersion
            llvmMingwRoot = $llvmMingwRoot
            visualStudio = $visualStudioPath
            vcTools = $vcToolsVersion
            msbuild = $msbuildVersion
            nasm = $nasmVersion
            msvcRuntimeLibrary = $runtimeLibrary
            cmakeGenerator = "Ninja"
            cmakeProcessor = $cmakeProcessor
        }
    }

    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $installDir "manifest.json")
}

foreach ($vendor in $vendors) {
    Assert-VendorPackage -Vendor $vendor
}

New-Manifest

$packageName = "partout-vendors-$Target.zip"
$packagePath = Join-Path $artifactsDir $packageName
Compress-Archive -Path (Join-Path $installDir "*") -DestinationPath $packagePath -Force

$sha256 = (Get-FileHash -Algorithm SHA256 $packagePath).Hash.ToLowerInvariant()
"$sha256  $packageName" | Set-Content -Encoding ASCII "$packagePath.sha256"
