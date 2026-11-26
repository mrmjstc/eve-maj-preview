# Cuts a dev build from the 'dev' branch: runs the unit tests, then tags the current commit as
# v<VERSION>-dev.<N> (N counting up per base version) and pushes it. The tag starts
# .github\workflows\release.yml, which builds, packages, publishes a GitHub prerelease with notes
# from the CHANGELOG's [Unreleased] section and announces it on the dev Discord channel
# (tools\release\publish.ps1).
#
# Never changes VERSION or CHANGELOG.md. -SkipTests skips the unit tests. -DryRun tags and pushes
# nothing: it builds and packages the next dev build locally and prints what it would hold.

param(
    [switch]$SkipTests,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "tools\release\release.psm1") -Force

try {
    $currentBranch = (git rev-parse --abbrev-ref HEAD).Trim()
    if ($currentBranch -ne "dev") { throw "build-release-dev.ps1 must be run from the 'dev' branch (currently on '$currentBranch')" }

    # Before anything is tagged, so a failing test leaves nothing behind.
    if (-not $SkipTests) { Invoke-UnitTests }

    $tag = Get-NextDevTag (Get-BaseVersion)
    Write-Host "Dev build: $tag" -ForegroundColor Green

    if ($DryRun) {
        & (Join-Path (Get-RepoRoot) "tools\release\publish.ps1") -Tag $tag -DryRun
        exit $LASTEXITCODE
    }

    Publish-Tag $tag
    Write-Host "`nPushed $tag. The Release workflow now builds it and publishes the prerelease; follow it with 'gh run watch' or on the Actions tab." -ForegroundColor Green
    Write-Host "If the workflow fails, re-run it there, or run .\tools\release\publish.ps1 -Tag $tag here." -ForegroundColor Yellow
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
