# Bumps the version, builds the app, and packages it for release: copies
# the exe from zig-out\bin into a versioned folder and zips it up,
# then also builds an installer via Inno Setup if ISCC.exe is available.
#
# By default bumps the minor version by 1 (patch resets to 0), e.g.
# 1.0.0 -> 1.1.0. Use -MinorBump to change the amount, -PatchBump for a
# hotfix release (e.g. 1.0.0 -> 1.0.1, minor untouched), or -SkipBump to
# package the current VERSION as-is. Use -SkipBuild to skip 'zig build'
# and package whatever is already in zig-out\bin. Use -SkipWinget to
# suppress the post-publish reminder to run update-winget.ps1. The unit
# tests run first, before anything is bumped; -SkipTests skips them.

param(
    [int]$MinorBump = 1,
    [switch]$PatchBump,
    [switch]$SkipBump,
    [switch]$SkipBuild,
    [switch]$SkipTests,
    [switch]$SkipWinget,
    [string]$DiscordWebhookUrl
)

$ErrorActionPreference = "Stop"

# Saved encrypted outside the repo by tools\discord-webhook.ps1; -DiscordWebhookUrl overrides it.
if (-not $DiscordWebhookUrl) {
    . (Join-Path $PSScriptRoot "tools\discord-webhook.ps1")
    $DiscordWebhookUrl = Get-DiscordWebhook "release"
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
$zonFile = Join-Path $root "build.zig.zon"
$changelogFile = Join-Path $root ".claude\CHANGELOG.md"

if (-not (Test-Path $versionFile)) {
    Write-Host "ERROR: VERSION file not found at $versionFile" -ForegroundColor Red
    exit 1
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: GitHub CLI (gh) not found. Install it to publish releases: https://cli.github.com" -ForegroundColor Red
    exit 1
}

# Before the bump, so a failing test leaves VERSION, build.zig.zon and the CHANGELOG untouched.
if (-not $SkipTests) {
    Write-Host "Running unit tests (zig build test)..." -ForegroundColor Cyan
    & zig build test
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: unit tests failed with exit code $LASTEXITCODE; nothing was bumped or built" -ForegroundColor Red
        exit 1
    }
}

$currentVersion = (Get-Content $versionFile -Raw).Trim()

if ($SkipBump) {
    $version = $currentVersion
} else {
    $parts = $currentVersion.Split(".")
    if ($parts.Count -ne 3) {
        Write-Host "ERROR: VERSION '$currentVersion' is not in major.minor.patch form" -ForegroundColor Red
        exit 1
    }
    $major = [int]$parts[0]
    if ($PatchBump) {
        $minor = [int]$parts[1]
        $patch = [int]$parts[2] + 1
        $version = "$major.$minor.$patch"
    } else {
        $minor = [int]$parts[1] + $MinorBump
        $version = "$major.$minor.0"
    }

    Write-Host "Bumping version: $currentVersion -> $version" -ForegroundColor Green
    Set-Content -Path $versionFile -Value $version -NoNewline

    # Kept in step with VERSION, which is what the build actually reads.
    $zonText = Get-Content $zonFile -Raw
    $versionLine = '(?m)^(\s*\.version\s*=\s*")[^"]*(")'
    if ($zonText -notmatch $versionLine) {
        Write-Host "ERROR: no .version line found in $zonFile" -ForegroundColor Red
        exit 1
    }
    Set-Content -Path $zonFile -Value ($zonText -replace $versionLine, "`${1}$version`${2}") -NoNewline
    Write-Host "  Updated build.zig.zon version to $version" -ForegroundColor Cyan

    if (Test-Path $changelogFile) {
        $changelogText = Get-Content $changelogFile -Raw
        if ($changelogText -match '(?m)^## \[Unreleased\]') {
            $today = Get-Date -Format "yyyy-MM-dd"
            $changelogText = $changelogText -replace '(?m)^## \[Unreleased\]', "## [$version] - $today"
            Set-Content -Path $changelogFile -Value $changelogText -NoNewline
            Write-Host "  Promoted CHANGELOG Unreleased section to $version" -ForegroundColor Cyan
        }
    }
}

if (-not $SkipBuild) {
    Write-Host "Building (zig build --release=safe)..." -ForegroundColor Cyan
    & zig build --release=safe
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: zig build failed with exit code $LASTEXITCODE" -ForegroundColor Red
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
    Write-Host "`nInno Setup (ISCC.exe) not found - skipping installer build. Install it from https://jrsoftware.org/isinfo.php to include one in releases." -ForegroundColor Yellow
}

# --- Publish to GitHub ---------------------------------------------------
# Commits the version bump (if any), tags it, pushes, and creates a draft
# GitHub release with the zip attached. Left as a draft so it can be
# reviewed before going live.

Write-Host "`nPublishing GitHub release..." -ForegroundColor Cyan

git diff --quiet -- $versionFile $zonFile $changelogFile
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Committing version bump" -ForegroundColor Cyan
    git add $versionFile $zonFile $changelogFile
    git commit -m "bump(version): $version"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: git commit failed" -ForegroundColor Red
        exit 1
    }
}

$tagName = "v$version"

git rev-parse -q --verify "refs/tags/$tagName" | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "ERROR: tag $tagName already exists locally. Delete it (git tag -d $tagName) if you want to retry." -ForegroundColor Red
    exit 1
}

Write-Host "  Tagging $tagName" -ForegroundColor Cyan
git tag -a $tagName -m "v$version"
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: git tag failed" -ForegroundColor Red
    exit 1
}

Write-Host "  Pushing commit and tag" -ForegroundColor Cyan
git push origin HEAD
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: git push failed" -ForegroundColor Red
    exit 1
}
git push origin $tagName
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: git push (tag) failed" -ForegroundColor Red
    exit 1
}

# The version's CHANGELOG section (promoted from Unreleased above, or already
# present) becomes both the GitHub release notes and the Discord announcement,
# so the two always agree.
$changelogSection = $null
if (Test-Path $changelogFile) {
    $changelogText = Get-Content $changelogFile -Raw
    if ($changelogText -match "(?ms)^## \[$([regex]::Escape($version))\][^\r\n]*\r?\n(.*?)(?=^## \[|\z)") {
        $changelogSection = $matches[1].Trim()
    }
}

Write-Host "  Creating draft GitHub release" -ForegroundColor Cyan
$releaseAssets = @($zipPath)
if ($installerPath) {
    $releaseAssets += $installerPath
}
if ($changelogSection) {
    # Notes go through a file: inline they can exceed the 32K command-line limit.
    $notesFile = Join-Path ([IO.Path]::GetTempPath()) "release-notes-$tagName.md"
    Set-Content -Path $notesFile -Value $changelogSection -Encoding utf8
    $releaseUrl = Invoke-GhCapture (@("release", "create", $tagName) + $releaseAssets + @("--draft", "--title", "v$version", "--notes-file", $notesFile))
    Remove-Item $notesFile -ErrorAction SilentlyContinue
} else {
    Write-Host "  No CHANGELOG entry found for v$version - falling back to --generate-notes" -ForegroundColor Yellow
    $releaseUrl = Invoke-GhCapture (@("release", "create", $tagName) + $releaseAssets + @("--draft", "--title", "v$version", "--generate-notes"))
}
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: gh release create failed" -ForegroundColor Red
    $releaseUrl | ForEach-Object { Write-Host "  $_" }
    exit 1
}
$releaseUrl = ($releaseUrl | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^https://' } | Select-Object -Last 1)

Write-Host "`nDraft release created for $tagName - review and publish on GitHub when ready." -ForegroundColor Green
if (-not $SkipWinget -and $installerPath) {
    Write-Host "After publishing, run .\update-winget.ps1 to submit the winget-pkgs manifest update." -ForegroundColor Yellow
}

# --- Notify Discord --------------------------------------------------------
# Reformats the same changelog section (bold headers, bullet glyphs) into a
# rich embed so the team sees what's in the draft release without opening
# GitHub.

if (-not $DiscordWebhookUrl) {
    Write-Host "No release Discord webhook saved, so no announcement was posted. Save one with .\tools\discord-webhook.ps1 -Channel release" -ForegroundColor Yellow
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
        $changelogBody = "_No changelog entry found for v$version._"
    }
    if ($changelogBody.Length -gt 3800) {
        $changelogBody = $changelogBody.Substring(0, 3800) + "`n..."
    }

    $embed = @{
        title       = "EVE-Maj Preview v$version"
        url         = $releaseUrl
        color       = 10181046
        description = $changelogBody
    }
    $payload = @{
        username = "EVE-Maj Preview"
        embeds   = @($embed)
    }

    try {
        Invoke-RestMethod -Uri $DiscordWebhookUrl -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $payload -Depth 6))) | Out-Null
        Write-Host "  Posted release notification to Discord" -ForegroundColor Cyan
    } catch {
        Write-Host "WARNING: Failed to post Discord notification: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}
