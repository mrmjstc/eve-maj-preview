# Builds, packages and publishes the GitHub release for a pushed tag, then announces it on Discord.
# .github\workflows\release.yml runs it for every v* tag; run it locally to finish a release CI couldn't.
#
# A vX.Y.Z tag makes a draft release from CHANGELOG's [X.Y.Z] section, announced on the release channel.
# A vX.Y.Z-dev.N tag makes a prerelease from [Unreleased], announced on the dev channel.
# A tag that already has a release is left alone, so re-running is safe.
#
# The webhooks come from DISCORD_WEBHOOK_RELEASE and DISCORD_WEBHOOK_DEV, or locally from
# tools\discord-webhook.ps1's saved ones; without one the announcement is skipped.
# -DryRun builds and packages, then prints the release and announcement instead of publishing;
# a stable tag whose section isn't promoted yet previews [Unreleased].
# -RequireInstaller fails without Inno Setup rather than releasing the zip alone.

param(
    [Parameter(Mandatory)][string]$Tag,
    [switch]$DryRun,
    [switch]$RequireInstaller
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "release.psm1") -Force

try {
    if ($Tag -notmatch '^v(\d+\.\d+\.\d+)(-dev\.\d+)?$') { throw "tag '$Tag' isn't vX.Y.Z or vX.Y.Z-dev.N" }
    $version = $Tag.Substring(1)
    $isDev = $Tag.Contains("-dev.")

    if (-not $DryRun) {
        Assert-Gh
        if (-not $isDev -and (Get-BaseVersion) -ne $version) { throw "tag $Tag doesn't match VERSION '$(Get-BaseVersion)'" }
        if (Test-GitHubRelease $Tag) {
            Write-Host "$Tag already has a release; nothing to do" -ForegroundColor Green
            exit 0
        }
    }

    Invoke-ReleaseBuild $version
    $assets = @(New-PortableZip $version)
    $installer = New-Installer $version -Required:$RequireInstaller
    if ($installer) { $assets += $installer }
    $assets += New-Checksums $assets

    $notes = Get-ChangelogSection $(if ($isDev) { "Unreleased" } else { $version })
    if (-not $notes -and -not $isDev -and $DryRun) { $notes = Get-ChangelogSection "Unreleased" }

    if ($isDev) {
        $title = "v$version (dev build)"
        $discordChannel = "dev"
        $webhook = $env:DISCORD_WEBHOOK_DEV
        $announcement = @{ Title = "[DEV BUILD] EVE-Maj Preview v$version"; Color = 15105570; Username = "EVE-Maj Preview (dev)"; Empty = "_No [Unreleased] changelog entries found._" }
    } else {
        $title = "v$version"
        $discordChannel = "release"
        $webhook = $env:DISCORD_WEBHOOK_RELEASE
        $announcement = @{ Title = "EVE-Maj Preview v$version"; Color = 10181046; Username = "EVE-Maj Preview"; Empty = "_No changelog entry found for v$version._" }
    }
    if (-not $webhook -and -not $env:CI) {
        . (Join-Path (Get-RepoRoot) "tools\discord-webhook.ps1")
        $webhook = Get-DiscordWebhook $discordChannel
    }
    $description = Format-DiscordNotes $notes $announcement.Empty

    if ($DryRun) {
        Write-Host "`nDry run: nothing was published." -ForegroundColor Green
        Write-Host "Would create a $(if ($isDev) { 'prerelease' } else { 'draft release' }) '$title' for $Tag with:" -ForegroundColor Cyan
        $assets | ForEach-Object { Write-Host "  $_" }
        Write-Host "Release notes:" -ForegroundColor Cyan
        Write-Host $(if ($notes) { $notes } else { "(none; --generate-notes)" })
        Write-Host "Discord ($discordChannel channel$(if (-not $webhook) { ', no webhook saved so it would be skipped' })):" -ForegroundColor Cyan
        Write-Host (ConvertTo-Json -InputObject (New-DiscordPayload $announcement.Title "<release url>" $announcement.Color $announcement.Username $description) -Depth 6)
        exit 0
    }

    Write-Host "`nPublishing $title..." -ForegroundColor Cyan
    $releaseUrl = Publish-GitHubRelease $Tag $title $assets $notes -Prerelease:$isDev
    Write-Host "Published: $releaseUrl" -ForegroundColor Green
    if (-not $isDev) { Write-Host "It's a draft: review and publish it on GitHub, then run .\update-winget.ps1." -ForegroundColor Yellow }

    if ($webhook) {
        Send-DiscordNotice $webhook (New-DiscordPayload $announcement.Title $releaseUrl $announcement.Color $announcement.Username $description)
    } else {
        Write-Host "No $discordChannel Discord webhook, so no announcement was posted." -ForegroundColor Yellow
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
