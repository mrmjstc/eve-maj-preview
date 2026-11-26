# Keeps the release scripts' Discord webhook URLs out of the repo: each is saved
# encrypted to the current Windows account (DPAPI, via Export-Clixml) under
# %LOCALAPPDATA%, and only that account on this PC can read it back.
#
# Save or replace one (prompts for the URL, which isn't echoed):
#   .\tools\discord-webhook.ps1 -Channel release
#   .\tools\discord-webhook.ps1 -Channel dev
# Remove one:
#   .\tools\discord-webhook.ps1 -Channel dev -Remove
# Copy a saved one into the repository secret the Release workflow reads
# (DISCORD_WEBHOOK_RELEASE or DISCORD_WEBHOOK_DEV), through gh:
#   .\tools\discord-webhook.ps1 -Channel release -UploadToGitHub
#
# tools\release\publish.ps1 dot-sources this file for Get-DiscordWebhook when run
# locally; dot-sourced without -Channel it only defines the functions.

param(
    [ValidateSet("release", "dev")]
    [string]$Channel,
    [switch]$Remove,
    [switch]$UploadToGitHub
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
if ($UploadToGitHub) {
    $url = Get-DiscordWebhook $Channel
    if (-not $url) {
        Write-Host "ERROR: no $Channel Discord webhook is saved; save one first with -Channel $Channel" -ForegroundColor Red
        exit 1
    }
    $secretName = "DISCORD_WEBHOOK_$($Channel.ToUpperInvariant())"
    # gh won't guess between origin and the backup remote, so name origin's repo.
    if ((git remote get-url origin) -notmatch 'github\.com[:/]([^/]+/[^/]+?)(\.git)?$') {
        Write-Host "ERROR: origin isn't a GitHub repository" -ForegroundColor Red
        exit 1
    }
    $repo = $matches[1]
    # Piped in, so the URL never appears on a command line.
    $url | gh secret set $secretName --repo $repo
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: gh secret set failed" -ForegroundColor Red
        exit 1
    }
    Write-Host "Saved the $Channel Discord webhook as $repo's repository secret $secretName" -ForegroundColor Green
    return
}
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
