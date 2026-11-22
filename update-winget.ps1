# Updates the winget-pkgs manifest for a published GitHub release and
# submits the PR via wingetcreate. Run this AFTER publishing the draft
# release that build-release.ps1 creates - winget needs the installer to be
# publicly downloadable so it can hash it, and drafts aren't public.
#
# Requires wingetcreate (winget install Microsoft.WingetCreate) and a
# GitHub login for the PR (wingetcreate prompts for device-code login, or
# pass -Token with a PAT that has public_repo scope).
#
# One-time bootstrap: the very first submission for a new package must be
# done with 'wingetcreate new' (interactive) instead of this script, since
# there's no existing manifest yet for 'update' to modify.

param(
    [string]$WingetPackageId = "mrmjstc.EVE-MajPreview",
    [string]$Version,
    [string]$Token
)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$versionFile = Join-Path $root "VERSION"

if (-not $Version) {
    if (-not (Test-Path $versionFile)) {
        Write-Host "ERROR: VERSION file not found at $versionFile" -ForegroundColor Red
        exit 1
    }
    $Version = (Get-Content $versionFile -Raw).Trim()
}

if (-not (Get-Command wingetcreate -ErrorAction SilentlyContinue) -and -not (Get-Command wingetcreate.exe -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: wingetcreate not found. Install it: winget install Microsoft.WingetCreate" -ForegroundColor Red
    exit 1
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: GitHub CLI (gh) not found." -ForegroundColor Red
    exit 1
}

$tagName = "v$Version"

Write-Host "Looking up release $tagName..." -ForegroundColor Cyan
$releaseJson = gh release view $tagName --json isDraft,assets 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: release $tagName not found. Run build-release.ps1 first." -ForegroundColor Red
    exit 1
}
$release = $releaseJson | ConvertFrom-Json
if ($release.isDraft) {
    Write-Host "ERROR: release $tagName is still a draft. Publish it on GitHub first - winget needs a public installer URL to hash it." -ForegroundColor Red
    exit 1
}

$installerAsset = $release.assets | Where-Object { $_.name -like "*-setup.exe" } | Select-Object -First 1
if (-not $installerAsset) {
    Write-Host "ERROR: no *-setup.exe asset found on release $tagName." -ForegroundColor Red
    exit 1
}
$installerUrl = $installerAsset.url

Write-Host "Updating winget manifest $WingetPackageId to $Version" -ForegroundColor Green
Write-Host "  Installer: $installerUrl" -ForegroundColor Cyan

$wingetArgs = @("update", $WingetPackageId, "--version", $Version, "--urls", $installerUrl, "--submit")
if ($Token) {
    $wingetArgs += @("--token", $Token)
}

& wingetcreate @wingetArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: wingetcreate update failed" -ForegroundColor Red
    exit 1
}

Write-Host "`nDone: winget manifest PR submitted for $WingetPackageId v$Version" -ForegroundColor Green
