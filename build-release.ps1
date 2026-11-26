# Cuts a stable release: runs the unit tests, bumps the version, commits the bump, tags it and
# pushes. The tag starts .github\workflows\release.yml, which builds, packages, creates the draft
# GitHub release and announces it on Discord (tools\release\publish.ps1).
#
# By default bumps the minor version by 1 (patch resets to 0), e.g. 1.0.0 -> 1.1.0. Use
# -MinorBump to change the amount, -PatchBump for a hotfix release (e.g. 1.0.0 -> 1.0.1, minor
# untouched), or -SkipBump to release the current VERSION as-is. -SkipTests skips the unit tests.
# -DryRun changes and pushes nothing: it builds and packages the next version locally and prints
# what the release would hold.

param(
    [int]$MinorBump = 1,
    [switch]$PatchBump,
    [switch]$SkipBump,
    [switch]$SkipTests,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "tools\release\release.psm1") -Force

$root = Get-RepoRoot
$versionFile = Join-Path $root "VERSION"
$zonFile = Join-Path $root "build.zig.zon"
$changelogFile = Join-Path $root "docs\CHANGELOG.md"

try {
    $currentVersion = Get-BaseVersion
    # Before the bump, so a failing test leaves VERSION, build.zig.zon and the CHANGELOG untouched.
    if (-not $SkipTests) { Invoke-UnitTests }

    if ($SkipBump) {
        $version = $currentVersion
    } else {
        $parts = $currentVersion.Split(".")
        if ($parts.Count -ne 3) { throw "VERSION '$currentVersion' is not in major.minor.patch form" }
        $major = [int]$parts[0]
        $version = if ($PatchBump) { "$major.$($parts[1]).$([int]$parts[2] + 1)" } else { "$major.$([int]$parts[1] + $MinorBump).0" }
    }
    $tag = "v$version"

    if ($DryRun) {
        & (Join-Path $root "tools\release\publish.ps1") -Tag $tag -DryRun
        exit $LASTEXITCODE
    }

    if (-not $SkipBump) {
        Write-Host "Bumping version: $currentVersion -> $version" -ForegroundColor Green
        Set-Content -Path $versionFile -Value $version -NoNewline

        # Kept in step with VERSION, which is what the build actually reads.
        $zonText = Get-Content $zonFile -Raw
        $versionLine = '(?m)^(\s*\.version\s*=\s*")[^"]*(")'
        if ($zonText -notmatch $versionLine) { throw "no .version line found in $zonFile" }
        Set-Content -Path $zonFile -Value ($zonText -replace $versionLine, "`${1}$version`${2}") -NoNewline
        Write-Host "  Updated build.zig.zon version to $version" -ForegroundColor Cyan

        # The promoted section becomes the release notes and the Discord announcement.
        $changelogText = Get-Content $changelogFile -Raw
        if ($changelogText -match '(?m)^## \[Unreleased\]') {
            $today = Get-Date -Format "yyyy-MM-dd"
            Set-Content -Path $changelogFile -Value ($changelogText -replace '(?m)^## \[Unreleased\]', "## [$version] - $today") -NoNewline
            Write-Host "  Promoted CHANGELOG Unreleased section to $version" -ForegroundColor Cyan
        }
    }

    git diff --quiet -- $versionFile $zonFile $changelogFile
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Committing version bump" -ForegroundColor Cyan
        git add $versionFile $zonFile $changelogFile
        git commit -m "bump(version): $version"
        if ($LASTEXITCODE -ne 0) { throw "git commit failed" }
    }

    Publish-Tag $tag
    Write-Host "`nPushed $tag. The Release workflow now builds it and creates the draft release; follow it with 'gh run watch' or on the Actions tab." -ForegroundColor Green
    Write-Host "If the workflow fails, re-run it there, or run .\tools\release\publish.ps1 -Tag $tag here." -ForegroundColor Yellow
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
