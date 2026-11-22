# Keeps the release scripts' Discord webhook URLs out of the repo: each is saved
# encrypted to the current Windows account (DPAPI, via Export-Clixml) under
# %LOCALAPPDATA%, and only that account on this PC can read it back.
#
# Save or replace one (prompts for the URL, which isn't echoed):
#   .\tools\discord-webhook.ps1 -Channel release
#   .\tools\discord-webhook.ps1 -Channel dev
# Remove one:
#   .\tools\discord-webhook.ps1 -Channel dev -Remove
#
# build-release.ps1 and build-release-dev.ps1 dot-source this file for
# Get-DiscordWebhook; dot-sourced without -Channel it only defines the functions.

param(
    [ValidateSet("release", "dev")]
    [string]$Channel,
    [switch]$Remove
)

function Get-DiscordWebhookPath([string]$Channel) {
    return Join-Path $env:LOCALAPPDATA "eve-maj-preview\release\discord-webhook-$Channel.xml"
}

# The saved URL, or $null when none is saved or it can't be decrypted (another account or PC).
function Get-DiscordWebhook([string]$Channel) {
    $path = Get-DiscordWebhookPath $Channel
    if (-not (Test-Path $path)) { return $null }
    try {
        $secure = Import-Clixml -Path $path
        return [System.Net.NetworkCredential]::new("", $secure).Password
    } catch {
        Write-Host "WARNING: Failed to read the saved $Channel Discord webhook: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

if (-not $Channel) { return }

$path = Get-DiscordWebhookPath $Channel
if ($Remove) {
    if (Test-Path $path) { Remove-Item $path -Force }
    Write-Host "Removed the $Channel Discord webhook" -ForegroundColor Green
    return
}

$secure = Read-Host -AsSecureString "Discord webhook URL for $Channel"
$url = [System.Net.NetworkCredential]::new("", $secure).Password
if ($url -notmatch '^https://(discord\.com|discordapp\.com)/api/webhooks/') {
    Write-Host "ERROR: that isn't a Discord webhook URL; nothing was saved" -ForegroundColor Red
    exit 1
}
New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
$secure | Export-Clixml -Path $path
Write-Host "Saved the $Channel Discord webhook to $path (encrypted to this Windows account)" -ForegroundColor Green
