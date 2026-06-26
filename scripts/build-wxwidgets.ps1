param(
    [Parameter(Mandatory = $true)]
    [string]$Arch,

    [Parameter(Mandatory = $true)]
    [string]$CMakeArch,

    [Parameter(Mandatory = $true)]
    [string]$VcArch
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

$version = $env:WXWIDGETS_VERSION
$sourceSha256 = $env:WXWIDGETS_SOURCE_SHA256
$generator = $env:CMAKE_GENERATOR
$runtimeLibrary = $env:MSVC_RUNTIME_LIBRARY

if (-not $version) { throw "WXWIDGETS_VERSION is required" }
if (-not $sourceSha256) { throw "WXWIDGETS_SOURCE_SHA256 is required" }
if (-not $generator) { throw "CMAKE_GENERATOR is required" }
if (-not $runtimeLibrary) { throw "MSVC_RUNTIME_LIBRARY is required" }

$root = (Get-Location).Path
$workDir = Join-Path $root ".build\wxwidgets-$Arch"
$sourceZip = Join-Path $workDir "wxWidgets-$version.zip"
$sourceExtractDir = Join-Path $workDir "source"
$buildDir = Join-Path $workDir "build"
$installDir = Join-Path $workDir "package"
$artifactsDir = Join-Path $root "artifacts"
$packageName = "wxwidgets-windows-$Arch.zip"
$packagePath = Join-Path $artifactsDir $packageName

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

$rootCMakeLists = Join-Path $sourceExtractDir "CMakeLists.txt"
if (Test-Path $rootCMakeLists) {
    $sourceDir = $sourceExtractDir
} else {
    $sourceDir = Get-ChildItem -Path $sourceExtractDir -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName "CMakeLists.txt") } |
        Select-Object -First 1 -ExpandProperty FullName
}

if (-not $sourceDir) {
    $entries = Get-ChildItem -Path $sourceExtractDir | Select-Object -First 20 -ExpandProperty Name
    throw "Unable to locate extracted wxWidgets source root in $sourceExtractDir. Top-level entries: $($entries -join ', ')"
}

cmake `
    -S $sourceDir `
    -B $buildDir `
    -G $generator `
    -A $CMakeArch `
    -DCMAKE_POLICY_DEFAULT_CMP0091=NEW `
    -DCMAKE_INSTALL_PREFIX="$installDir" `
    -DCMAKE_MSVC_RUNTIME_LIBRARY="$runtimeLibrary" `
    -DwxBUILD_SHARED=OFF `
    -DwxBUILD_USE_STATIC_RUNTIME=OFF `
    -DwxBUILD_TESTS=OFF `
    -DwxBUILD_SAMPLES=OFF `
    -DwxBUILD_DEMOS=OFF `
    -DwxBUILD_PRECOMP=OFF `
    -DwxUSE_LIBWEBP=OFF `
    -DwxUSE_WEBVIEW=OFF

cmake --build $buildDir --target install --config Release --parallel

$wxLibDir = Join-Path $installDir "lib\vc_${VcArch}_lib"
$expectedLibs = @(
    "wxmsw33u_core.lib",
    "wxbase33u_net.lib",
    "wxbase33u.lib"
)

foreach ($lib in $expectedLibs) {
    $path = Join-Path $wxLibDir $lib
    if (-not (Test-Path $path)) {
        throw "Missing expected wxWidgets library: $path"
    }
}

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
            cmakeGenerator = $generator
            cmakeArch = $CMakeArch
            vcArch = $VcArch
            disabledFeatures = @("webview", "libwebp")
        }
    }
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path $installDir "manifest.json")

Compress-Archive -Path (Join-Path $installDir "*") -DestinationPath $packagePath
$sha256 = (Get-FileHash -Algorithm SHA256 $packagePath).Hash.ToLowerInvariant()
"$sha256  $packageName" | Set-Content -Encoding ASCII "$packagePath.sha256"
