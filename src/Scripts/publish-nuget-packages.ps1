# Pack (and optionally push) the SoftSense.DeltaLake.Net NuGet package.
#
# Adapted from the softsense-publish-packages skill template. Differences from the template:
#   - one packable project (src/DeltaLake/DeltaLake.csproj)
#   - -RustLibraryRoot / -KernelLibraryRoot: folders holding the prebuilt native libraries for
#     every RID (<root>/<rid>-bridge/... and <root>/<rid>-kernel/...). CI passes the downloaded
#     build artifacts here. When omitted, the csproj builds the natives for THIS machine only,
#     so a local pack yields a single-platform package for local testing.
#
# Usage:
#   ./publish-nuget-packages.ps1                                          # local build, {version.txt}-local.{timestamp}
#   ./publish-nuget-packages.ps1 -Version "0.33.0-preview.42"
#   ./publish-nuget-packages.ps1 -Version "0.33.0" -RustLibraryRoot <dir> -KernelLibraryRoot <dir>
#   ./publish-nuget-packages.ps1 -Version "0.33.0" -Push -NuGetSource <url> -ApiKey <key>
#
# Version resolution: explicit -Version, else src/version.txt + "-local.{yyyyMMddHHmmss}".

param(
    [string]$OutputPath = "",
    [string]$Version = "",
    [string]$RustLibraryRoot = "",
    [string]$KernelLibraryRoot = "",
    [switch]$Push,
    [string]$NuGetSource = "",
    [string]$ApiKey = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrEmpty($OutputPath)) {
    $isWin = ($IsWindows) -or ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    $OutputPath = if ($isWin) { "D:\source\.local-nuget-builds" } else { Join-Path $HOME ".local-nuget-builds" }
}

# src/version.txt is the single source of truth (Scripts/ sits directly under src/).
$versionFile = Join-Path (Split-Path $PSScriptRoot -Parent) "version.txt"
$baseVersion = (Get-Content $versionFile -Raw).Trim()

if ([string]::IsNullOrEmpty($Version)) {
    # Single 14-digit segment: SemVer rejects leading zeros in numeric prerelease identifiers.
    $Version = "$baseVersion-local.$(Get-Date -Format 'yyyyMMddHHmmss')"
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    Write-Host "Created output directory: $OutputPath" -ForegroundColor Green
}

# Repository root: two levels up from src/Scripts.
$repoRoot = (Get-Item $PSScriptRoot).Parent.Parent.FullName

$projects = @(
    "src/DeltaLake/DeltaLake.csproj"
)

Write-Host ""
Write-Host "Packing SoftSense.DeltaLake.Net to: $OutputPath" -ForegroundColor Cyan
Write-Host "Version: $Version" -ForegroundColor Cyan
if ($RustLibraryRoot)   { Write-Host "Bridge natives: $RustLibraryRoot" -ForegroundColor Cyan }
if ($KernelLibraryRoot) { Write-Host "Kernel natives: $KernelLibraryRoot" -ForegroundColor Cyan }
Write-Host ""

$failed = @()
$succeeded = @()

foreach ($projectRelPath in $projects) {
    $project = Join-Path $repoRoot $projectRelPath
    $projectName = [System.IO.Path]::GetFileNameWithoutExtension($project)

    if (-not (Test-Path $project)) {
        Write-Host "  Project not found: $project" -ForegroundColor Red
        $failed += $projectName
        continue
    }

    Write-Host "Packing $projectName..." -ForegroundColor Yellow

    $packArgs = @(
        "pack", $project,
        "--configuration", "Release",
        "--output", $OutputPath,
        "/p:Version=$Version",
        "/p:PackageVersion=$Version",
        "/p:SymbolPackageFormat=snupkg"
    )
    if ($RustLibraryRoot)   { $packArgs += "/p:RustLibraryRoot=$RustLibraryRoot" }
    if ($KernelLibraryRoot) { $packArgs += "/p:KernelLibraryRoot=$KernelLibraryRoot" }

    $packResult = & dotnet @packArgs 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Packed: $projectName $Version" -ForegroundColor Green
        $succeeded += $projectName
    } else {
        Write-Host "  Failed to pack $projectName" -ForegroundColor Red
        Write-Host $packResult -ForegroundColor Red
        $failed += $projectName
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if ($succeeded.Count -gt 0) { Write-Host "Succeeded ($($succeeded.Count)): $($succeeded -join ', ')" -ForegroundColor Green }
if ($failed.Count -gt 0)    { Write-Host "Failed ($($failed.Count)): $($failed -join ', ')" -ForegroundColor Red }
Write-Host ""

$packages = Get-ChildItem -Path $OutputPath -Filter "*$Version*nupkg" | Sort-Object Name
if ($packages.Count -gt 0) {
    Write-Host "Packages:" -ForegroundColor Green
    foreach ($pkg in $packages) {
        $color = if ($pkg.Extension -eq ".snupkg") { "DarkGray" } else { "White" }
        Write-Host "  $($pkg.Name)" -ForegroundColor $color
    }
}
Write-Host ""

if ($Push -and $failed.Count -eq 0) {
    if ([string]::IsNullOrEmpty($NuGetSource)) {
        Write-Host "ERROR: -NuGetSource is required when using -Push" -ForegroundColor Red
        exit 1
    }

    Write-Host "Pushing packages to: $NuGetSource" -ForegroundColor Cyan
    $nupkgs = Get-ChildItem -Path $OutputPath -Filter "*$Version.nupkg" | Where-Object { $_.Extension -eq ".nupkg" }
    $pushFailed = @()

    foreach ($pkg in $nupkgs) {
        Write-Host "  Pushing $($pkg.Name)..." -ForegroundColor Yellow
        $pushArgs = @("nuget", "push", $pkg.FullName, "--source", $NuGetSource, "--skip-duplicate")
        if (-not [string]::IsNullOrEmpty($ApiKey)) { $pushArgs += @("--api-key", $ApiKey) }

        $pushResult = & dotnet @pushArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Pushed: $($pkg.Name)" -ForegroundColor Green
        } else {
            Write-Host "  Failed to push $($pkg.Name)" -ForegroundColor Red
            Write-Host $pushResult -ForegroundColor Red
            $pushFailed += $pkg.Name
        }
    }

    if ($pushFailed.Count -gt 0) {
        Write-Host ""
        Write-Host "Failed to push $($pushFailed.Count) package(s)" -ForegroundColor Red
        exit 1
    }
    Write-Host ""
    Write-Host "All packages pushed successfully" -ForegroundColor Green
}

if ($failed.Count -gt 0) { exit 1 }
