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

$partoutRepository = $env:PARTOUT_REPOSITORY
$partoutRef = $env:PARTOUT_REF
$opensslVersion = $env:OPENSSL_VERSION
$mbedtlsVersion = $env:MBEDTLS_VERSION
$generator = $env:CMAKE_GENERATOR
$runtimeLibrary = $env:MSVC_RUNTIME_LIBRARY

if (-not $partoutRepository) { throw "PARTOUT_REPOSITORY is required" }
if (-not $partoutRef) { throw "PARTOUT_REF is required" }
if (-not $opensslVersion) { throw "OPENSSL_VERSION is required" }
if (-not $mbedtlsVersion) { throw "MBEDTLS_VERSION is required" }
if (-not $generator) { throw "CMAKE_GENERATOR is required" }
if (-not $runtimeLibrary) { throw "MSVC_RUNTIME_LIBRARY is required" }

$root = (Get-Location).Path
$partoutDir = Join-Path $root ".build\partout"
$workDir = Join-Path $root ".build\$Target-$Vendor"
$packageRoot = Join-Path $workDir "package"
$artifactsDir = Join-Path $root "artifacts"

switch ($Target) {
    "windows-x64" {
        $arch = "x64"
        $cmakeArch = "x64"
        $vcVarsArch = "amd64"
        $opensslTarget = "VC-WIN64A"
    }
    "windows-arm64" {
        $arch = "arm64"
        $cmakeArch = "ARM64"
        $vcVarsArch = "amd64_arm64"
        $opensslTarget = "VC-WIN64-ARM"
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
$nasmVersion = ""
if (Get-Command nasm -ErrorAction SilentlyContinue) {
    $nasmVersion = ((& nasm -v) | Select-Object -First 1).Trim()
}

Remove-Item -Recurse -Force $workDir, $artifactsDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $packageRoot | Out-Null
New-Item -ItemType Directory -Force $artifactsDir | Out-Null

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

function Copy-SourceTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDir,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDir
    )

    Remove-Item -Recurse -Force $DestinationDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $DestinationDir | Out-Null
    Copy-Item -Recurse -Force (Join-Path $SourceDir "*") $DestinationDir
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

function Build-OpenSSL {
    $sourceDir = Join-Path $partoutDir "vendors\openssl"
    $buildDir = Join-Path $workDir "openssl-src"
    $installDir = Join-Path $packageRoot "openssl"
    $flags = @(
        "no-apps",
        "no-docs",
        "no-dsa",
        "no-engine",
        "no-gost",
        "no-legacy",
        "shared",
        "no-ssl",
        "no-tests",
        "no-zlib"
    )

    Copy-SourceTree -SourceDir $sourceDir -DestinationDir $buildDir

    $configureArgs = @(
        "perl",
        "Configure",
        $opensslTarget,
        "--prefix=""$installDir""",
        "--openssldir=""$installDir""",
        "--libdir=lib"
    ) + $flags

    $command = ($configureArgs -join " ") + " && nmake /NOLOGO && nmake /NOLOGO install_sw"
    Invoke-VcVarsCommand -Architecture $vcVarsArch -WorkingDirectory $buildDir -Command $command

    Assert-PathExists (Join-Path $installDir "lib\libssl.lib")
    Assert-PathExists (Join-Path $installDir "lib\libcrypto.lib")

    $binDir = Join-Path $installDir "bin"
    $sslDlls = Get-ChildItem -Path $binDir -Filter "libssl*.dll" -ErrorAction SilentlyContinue
    $cryptoDlls = Get-ChildItem -Path $binDir -Filter "libcrypto*.dll" -ErrorAction SilentlyContinue
    if (-not $sslDlls) { throw "Missing expected OpenSSL SSL DLL in $binDir" }
    if (-not $cryptoDlls) { throw "Missing expected OpenSSL Crypto DLL in $binDir" }
}

function Build-MbedTLS {
    $sourceDir = Join-Path $partoutDir "vendors\mbedtls"
    $buildDir = Join-Path $workDir "mbedtls-build"
    $installDir = Join-Path $packageRoot "mbedtls"

    python -m pip install --user --disable-pip-version-check -r (Join-Path $sourceDir "scripts\basic.requirements.txt")
    Push-Location (Join-Path $sourceDir "tf-psa-crypto")
    try {
        python "framework\scripts\make_generated_files.py"
    } finally {
        Pop-Location
    }

    Push-Location $sourceDir
    try {
        python "scripts\make_generated_files.py"
    } finally {
        Pop-Location
    }

    cmake `
        -S $sourceDir `
        -B $buildDir `
        -G $generator `
        -A $cmakeArch `
        -DCMAKE_POLICY_DEFAULT_CMP0091=NEW `
        -DCMAKE_INSTALL_PREFIX="$installDir" `
        -DCMAKE_MSVC_RUNTIME_LIBRARY="$runtimeLibrary" `
        -DENABLE_TESTING=OFF `
        -DENABLE_PROGRAMS=OFF `
        -DUSE_SHARED_MBEDTLS_LIBRARY=OFF `
        -DUSE_STATIC_MBEDTLS_LIBRARY=ON

    cmake --build $buildDir --target install --config Release --parallel

    Assert-PathExists (Join-Path $installDir "lib\mbedtls.lib")
    Assert-PathExists (Join-Path $installDir "lib\mbedx509.lib")
    Assert-PathExists (Join-Path $installDir "lib\mbedcrypto.lib")
}

function Write-Manifest {
    $libraries = [ordered]@{}

    switch ($Vendor) {
        "openssl" {
            $libraries["openssl"] = [ordered]@{
                version = $opensslVersion
                linkage = "shared"
            }
        }
        "mbedtls" {
            $libraries["mbedtls"] = [ordered]@{
                version = $mbedtlsVersion
                linkage = "static"
            }
        }
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        target = $Target
        vendor = $Vendor
        os = "windows"
        arch = $arch
        partout = [ordered]@{
            repository = $partoutRepository
            ref = $partoutRef
        }
        libraries = $libraries
        toolchains = [ordered]@{
            go = ""
            cmake = $cmakeVersion
            ninja = ""
            androidApi = ""
            androidNdk = ""
            llvmMingw = ""
            visualStudio = $visualStudioPath
            vcTools = $vcToolsVersion
            msbuild = $msbuildVersion
            nasm = $nasmVersion
            msvcRuntimeLibrary = $runtimeLibrary
            cmakeGenerator = $generator
            cmakeArch = $cmakeArch
        }
    }

    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $packageRoot "manifest.json")
}

function New-Package {
    $packageName = "partout-vendors-$Vendor-$Target.tar.gz"
    $packagePath = Join-Path $artifactsDir $packageName

    tar -czf $packagePath -C $packageRoot .

    $sha256 = (Get-FileHash -Algorithm SHA256 $packagePath).Hash.ToLowerInvariant()
    "$sha256  $packageName" | Set-Content -Encoding ASCII "$packagePath.sha256"
}

switch ($Vendor) {
    "openssl" { Build-OpenSSL }
    "mbedtls" { Build-MbedTLS }
}

Write-Manifest
New-Package
