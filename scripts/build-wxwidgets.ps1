param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("x64", "arm64")]
    [string]$Arch
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$version = $env:WXWIDGETS_VERSION
$sourceSha256 = $env:WXWIDGETS_SOURCE_SHA256
$runtimeLibrary = $env:MSVC_RUNTIME_LIBRARY
if (-not $version) { throw "WXWIDGETS_VERSION is required" }
if (-not $sourceSha256) { throw "WXWIDGETS_SOURCE_SHA256 is required" }
if (-not $runtimeLibrary) { throw "MSVC_RUNTIME_LIBRARY is required" }

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = (Resolve-Path (Join-Path $scriptDir "..")).Path
$workDir = Join-Path $root ".build\wxwidgets-$Arch"
$sourceZip = Join-Path $workDir "wxWidgets-$version.zip"
$sourceExtractDir = Join-Path $workDir "source"
$installDir = Join-Path $workDir "package"
$artifactsDir = Join-Path $root "artifacts"
$packageName = "wxwidgets-windows-$Arch.zip"
$packagePath = Join-Path $artifactsDir $packageName

switch ($Arch) {
    "x64" {
        $targetCpu = "X64"
        $vcVarsArch = "amd64"
    }
    "arm64" {
        $targetCpu = "ARM64"
        $vcVarsArch = "amd64_arm64"
    }
}
$runtimeLibs = if ($runtimeLibrary.EndsWith("DLL")) { "dynamic" } else { "static" }

Remove-Item -Recurse -Force $workDir, $artifactsDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $workDir, $artifactsDir | Out-Null

$url = "https://github.com/wxWidgets/wxWidgets/releases/download/v$version/wxWidgets-$version.zip"
Invoke-WebRequest -Uri $url -OutFile $sourceZip
$actualSha256 = (Get-FileHash -Algorithm SHA256 $sourceZip).Hash.ToLowerInvariant()
if ($actualSha256 -ne $sourceSha256.ToLowerInvariant()) {
    throw "Expected wxWidgets SHA256 $sourceSha256, got $actualSha256"
}

New-Item -ItemType Directory -Force $sourceExtractDir | Out-Null
Expand-Archive -Path $sourceZip -DestinationPath $sourceExtractDir
$sourceDir = Get-ChildItem -Path $sourceExtractDir -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName "build\msw\makefile.vc") } |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $sourceDir -and (Test-Path (Join-Path $sourceExtractDir "build\msw\makefile.vc"))) {
    $sourceDir = $sourceExtractDir
}
if (-not $sourceDir) { throw "Unable to locate extracted wxWidgets source root" }

$setupHeader = Join-Path $sourceDir "include\wx\msw\setup.h"
if (Test-Path $setupHeader) {
    (Get-Content $setupHeader) `
        -replace '^#define wxUSE_LIBWEBP\s+\d+', '#define wxUSE_LIBWEBP 0' |
        Set-Content -Encoding UTF8 $setupHeader
}

$programFilesX86 = [Environment]::GetFolderPath("ProgramFilesX86")
$vswhere = Join-Path $programFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "Unable to locate vswhere.exe" }
$visualStudioPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
if (-not $visualStudioPath) { throw "Unable to locate Visual Studio with MSVC tools" }
$vcVarsAll = Join-Path $visualStudioPath "VC\Auxiliary\Build\vcvarsall.bat"
if (-not (Test-Path $vcVarsAll)) { throw "Unable to locate vcvarsall.bat" }

$mswBuildDir = Join-Path $sourceDir "build\msw"
$nmakeArgs = @(
    "/NOLOGO", "/f", "makefile.vc",
    "BUILD=release", "SHARED=0", "RUNTIME_LIBS=$runtimeLibs",
    "TARGET_CPU=$targetCpu", "USE_WEBVIEW=0", "USE_PRECOMP=0"
) -join " "
$cmdLine = "call `"$vcVarsAll`" $vcVarsArch && cd /d `"$mswBuildDir`" && nmake $nmakeArgs"
& cmd.exe /d /s /c $cmdLine
if ($LASTEXITCODE -ne 0) { throw "wxWidgets nmake failed with exit code $LASTEXITCODE" }

$wxSourceLibDir = Join-Path $sourceDir "lib\vc_${Arch}_lib"
$wxInstallIncludeDir = Join-Path $installDir "include\wx-3.3"
$wxInstallLibDir = Join-Path $installDir "lib\vc_${Arch}_lib"
New-Item -ItemType Directory -Force $wxInstallIncludeDir, $wxInstallLibDir | Out-Null
Copy-Item (Join-Path $sourceDir "include\*") $wxInstallIncludeDir -Recurse -Force
Copy-Item (Join-Path $wxSourceLibDir "*") $wxInstallLibDir -Recurse -Force

$expectedLibs = @("wxmsw33u_core.lib", "wxbase33u_net.lib", "wxbase33u.lib")
foreach ($lib in $expectedLibs) {
    $path = Join-Path $wxInstallLibDir $lib
    if (-not (Test-Path $path)) { throw "Missing expected wxWidgets library: $path" }
}

$vcToolsVersionFile = Join-Path $visualStudioPath "VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt"
$vcToolsVersion = if (Test-Path $vcToolsVersionFile) { (Get-Content -Raw $vcToolsVersionFile).Trim() } else { "" }
$manifest = [ordered]@{
    schemaVersion = 1
    target = "windows-$Arch"
    os = "windows"
    arch = $Arch
    libraries = [ordered]@{
        wxwidgets = [ordered]@{
            version = $version
            sourceUrl = $url
            sourceSha256 = $sourceSha256
            linkage = "static"
            shared = $false
            buildType = "Release"
            msvcRuntimeLibrary = $runtimeLibrary
            buildSystem = "makefile.vc"
            targetCpu = $targetCpu
            vcArch = $Arch
            disabledFeatures = @("webview", "libwebp")
        }
    }
    toolchains = [ordered]@{
        visualStudio = $visualStudioPath
        vcTools = $vcToolsVersion
        nmake = "MSVC"
    }
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $installDir "manifest.json")

Compress-Archive -Path (Join-Path $installDir "*") -DestinationPath $packagePath
