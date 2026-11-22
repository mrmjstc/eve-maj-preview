# Builds and packages a dev build from the 'dev' branch: tags the current
# commit as v<VERSION>-dev.<N> (N auto-incrementing per base version), builds,
# packages, publishes a GitHub prerelease, and posts to the dev Discord webhook.
#
# Unlike build-release.ps1, this never touches VERSION or CHANGELOG.md - it
# only reads them. The base version comes from whatever VERSION currently
# holds, and the release notes are pulled from the CHANGELOG's [Unreleased]
# section as-is, since dev builds are previews of what that section will
# become. Use -SkipBuild to package whatever is already in zig-out\bin.
# The unit tests run first, before anything is tagged; -SkipTests skips them.

param(
    [switch]$SkipBuild,
    [switch]$SkipTests,
    [string]$DiscordWebhookUrl
)

$ErrorActionPreference = "Stop"

# Saved encrypted outside the repo by tools\discord-webhook.ps1; -DiscordWebhookUrl overrides it.
if (-not $DiscordWebhookUrl) {
    . (Join-Path $PSScriptRoot "tools\discord-webhook.ps1")
    $DiscordWebhookUrl = Get-DiscordWebhook "dev"
}

# pwsh 7.5 can fail to start gh.exe when capturing its output ("StandardOutputEncoding is only
# supported when standard output is redirected"), so run it through Process directly.
function Invoke-GhCapture([string[]]$GhArgs) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new((Get-Command gh).Source)
    foreach ($a in $GhArgs) { $psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    $global:LASTEXITCODE = $proc.ExitCode
    return $out -split "`r?`n"
}

$root = $PSScriptRoot
$binDir = Join-Path $root "zig-out\bin"
$versionFile = Join-Path $root "VERSION"
$changelogFile = Join-Path $root ".claude\CHANGELOG.md"

$currentBranch = (git rev-parse --abbrev-ref HEAD).Trim()
if ($currentBranch -ne "dev") {
    Write-Host "ERROR: build-release-dev.ps1 must be run from the 'dev' branch (currently on '$currentBranch')" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $versionFile)) {
    Write-Host "ERROR: VERSION file not found at $versionFile" -ForegroundColor Red
    exit 1
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: GitHub CLI (gh) not found. Install it to publish releases: https://cli.github.com" -ForegroundColor Red
    exit 1
}

# Before VERSION is rewritten for the build, so a failing test leaves the tree untouched.
if (-not $SkipTests) {
    Write-Host "Running unit tests (zig build test)..." -ForegroundColor Cyan
    & zig build test
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: unit tests failed with exit code $LASTEXITCODE; nothing was tagged or built" -ForegroundColor Red
        exit 1
    }
}

$baseVersion = (Get-Content $versionFile -Raw).Trim()

Write-Host "Fetching existing dev tags..." -ForegroundColor Cyan
git fetch origin --tags --quiet

$existingTags = git tag --list "v$baseVersion-dev.*"
$maxN = 0
foreach ($t in $existingTags) {
    if ($t -match '-dev\.(\d+)$') {
        $n = [int]$matches[1]
        if ($n -gt $maxN) { $maxN = $n }
    }
}
$devN = $maxN + 1
$version = "$baseVersion-dev.$devN"
$tagName = "v$version"

Write-Host "Dev build: $tagName" -ForegroundColor Green

if (-not $SkipBuild) {
    # VERSION is embedded at compile time (config dialog, tray tooltip, startup log), so it has
    # to say "-dev.N" during the build itself - restored right after so the working tree stays clean.
    Write-Host "Writing dev version to VERSION ($version)..." -ForegroundColor Cyan
    Set-Content -Path $versionFile -Value $version -NoNewline
    try {
        Write-Host "Building (zig build --release=safe)..." -ForegroundColor Cyan
        & zig build --release=safe
        $buildExitCode = $LASTEXITCODE
    } finally {
        Set-Content -Path $versionFile -Value $baseVersion -NoNewline
    }
    if ($buildExitCode -ne 0) {
        Write-Host "ERROR: zig build failed with exit code $buildExitCode" -ForegroundColor Red
        exit 1
    }
}

if (-not (Test-Path $binDir)) {
    Write-Host "ERROR: $binDir not found. Build the project first." -ForegroundColor Red
    exit 1
}

$packageName = "eve-maj-preview-v$version"

$distDir = Join-Path $root "dist"
$stagingDir = Join-Path $distDir $packageName
$zipPath = Join-Path $distDir "$packageName-portable.zip"

Write-Host "Packaging EVE-Maj Preview v$version..." -ForegroundColor Green

# Start clean so stale files never end up in the archive
if (Test-Path $stagingDir) {
    Remove-Item $stagingDir -Recurse -Force
}
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

$itemsToCopy = @(
    @{ Name = "eve-maj-preview.exe"; Source = $binDir },
    @{ Name = "CascadiaCode-LICENSE.txt"; Source = (Join-Path $root "licenses"); Dest = "licenses" },
    @{ Name = "Geist-LICENSE.txt"; Source = (Join-Path $root "licenses"); Dest = "licenses" },
    @{ Name = "knots-LICENSE.txt"; Source = (Join-Path $root "licenses"); Dest = "licenses" },
    @{ Name = "eve-maj-preview-LICENSE.txt"; Source = (Join-Path $root "licenses"); Dest = "licenses" },
    @{ Name = "sounds"; Source = $root },
    @{ Name = "README.md"; Source = $root }
)

foreach ($item in $itemsToCopy) {
    $source = Join-Path $item.Source $item.Name
    if (-not (Test-Path $source)) {
        Write-Host "ERROR: $($item.Name) not found in $($item.Source)" -ForegroundColor Red
        exit 1
    }
    $destination = if ($item.Dest) { Join-Path $stagingDir $item.Dest } else { $stagingDir }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Write-Host "  Copying $($item.Name)" -ForegroundColor Cyan
    Copy-Item $source -Destination $destination -Recurse
}

if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}

Write-Host "Creating archive: $zipPath" -ForegroundColor Cyan
Compress-Archive -Path (Join-Path $stagingDir "*") -DestinationPath $zipPath -CompressionLevel Optimal

# The staging folder was only needed to control the archive's internal layout
Remove-Item $stagingDir -Recurse -Force

Write-Host "`nDone: $zipPath" -ForegroundColor Green

# --- Build installer (optional, needs Inno Setup) -------------------------

$innoCompiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $innoCompiler) {
    $innoCompiler = Get-ChildItem -Path "${env:ProgramFiles(x86)}", "$env:ProgramFiles" -Filter "Inno Setup*" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName "ISCC.exe" } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
}

$installerPath = $null
if ($innoCompiler) {
    Write-Host "`nBuilding installer with Inno Setup..." -ForegroundColor Cyan
    $installerScript = Join-Path $root "installer\eve-maj-preview.iss"
    & $innoCompiler "/DMyAppVersion=$version" $installerScript
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Inno Setup compilation failed" -ForegroundColor Red
        exit 1
    }
    $installerPath = Join-Path $distDir "eve-maj-preview-v$version-setup.exe"
    Write-Host "Done: $installerPath" -ForegroundColor Green
} else {
    Write-Host "`nInno Setup (ISCC.exe) not found - skipping installer build." -ForegroundColor Yellow
}

# --- Publish to GitHub ---------------------------------------------------
# Tags the current commit and creates a GitHub prerelease with the zip
# attached, so it's clearly marked as non-stable and never becomes "Latest".

Write-Host "`nPublishing GitHub prerelease..." -ForegroundColor Cyan

git rev-parse -q --verify "refs/tags/$tagName" | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "ERROR: tag $tagName already exists locally. Delete it (git tag -d $tagName) if you want to retry." -ForegroundColor Red
    exit 1
}

Write-Host "  Pushing dev branch" -ForegroundColor Cyan
git push origin HEAD
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: git push failed" -ForegroundColor Red
    exit 1
}

Write-Host "  Tagging $tagName" -ForegroundColor Cyan
git tag -a $tagName -m "v$version"
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: git tag failed" -ForegroundColor Red
    exit 1
}

Write-Host "  Pushing tag" -ForegroundColor Cyan
git push origin $tagName
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: git push (tag) failed" -ForegroundColor Red
    exit 1
}

# Dev builds preview whatever is queued up for the next real release, so the
# release notes and Discord post pull straight from [Unreleased] as-is - it's
# never promoted or modified here.
$changelogSection = $null
if (Test-Path $changelogFile) {
    $changelogText = Get-Content $changelogFile -Raw
    if ($changelogText -match '(?ms)^## \[Unreleased\][^\r\n]*\r?\n(.*?)(?=^## \[|\z)') {
        $changelogSection = $matches[1].Trim()
    }
}

Write-Host "  Creating GitHub prerelease" -ForegroundColor Cyan
$releaseAssets = @($zipPath)
if ($installerPath) {
    $releaseAssets += $installerPath
}
if ($changelogSection) {
    # Notes go through a file: inline they can exceed the 32K command-line limit.
    $notesFile = Join-Path ([IO.Path]::GetTempPath()) "release-notes-$tagName.md"
    Set-Content -Path $notesFile -Value $changelogSection -Encoding utf8
    $releaseUrl = Invoke-GhCapture (@("release", "create", $tagName) + $releaseAssets + @("--prerelease", "--title", "v$version (dev build)", "--notes-file", $notesFile))
    Remove-Item $notesFile -ErrorAction SilentlyContinue
} else {
    Write-Host "  No [Unreleased] CHANGELOG entries found - falling back to --generate-notes" -ForegroundColor Yellow
    $releaseUrl = Invoke-GhCapture (@("release", "create", $tagName) + $releaseAssets + @("--prerelease", "--title", "v$version (dev build)", "--generate-notes"))
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: gh release create failed" -ForegroundColor Red
    $releaseUrl | ForEach-Object { Write-Host "  $_" }
    exit 1
}
$releaseUrl = ($releaseUrl | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^https://' } | Select-Object -Last 1)

Write-Host "`nPrerelease published: $releaseUrl" -ForegroundColor Green

# --- Notify Discord --------------------------------------------------------

if (-not $DiscordWebhookUrl) {
    Write-Host "No dev Discord webhook saved, so no announcement was posted. Save one with .\tools\discord-webhook.ps1 -Channel dev" -ForegroundColor Yellow
} else {
    $changelogBody = $null
    if ($changelogSection) {
        $sections = [regex]::Matches($changelogSection, '(?ms)^### (\S.*?)\r?\n(.*?)(?=^### |\z)')
        $parts = foreach ($section in $sections) {
            $heading = $section.Groups[1].Value.Trim()
            $bullets = ($section.Groups[2].Value.Trim() -split '\r?\n' | Where-Object { $_ -match '^- ' } | ForEach-Object { "• " + $_.Substring(2) }) -join "`n"
            "**$heading**`n$bullets"
        }
        $changelogBody = $parts -join "`n`n"
    }
    if (-not $changelogBody) {
        $changelogBody = "_No [Unreleased] changelog entries found._"
    }
    if ($changelogBody.Length -gt 3800) {
        $changelogBody = $changelogBody.Substring(0, 3800) + "`n..."
    }

    $embed = @{
        title       = "[DEV BUILD] EVE-Maj Preview v$version"
        url         = $releaseUrl
        color       = 15105570
        description = $changelogBody
    }
    $payload = @{
        username = "EVE-Maj Preview (dev)"
        embeds   = @($embed)
    }

    try {
        Invoke-RestMethod -Uri $DiscordWebhookUrl -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $payload -Depth 6))) | Out-Null
        Write-Host "  Posted dev build notification to Discord" -ForegroundColor Cyan
    } catch {
        Write-Host "WARNING: Failed to post Discord notification: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
