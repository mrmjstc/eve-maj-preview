# The release steps build-release.ps1, build-release-dev.ps1 and tools\release\publish.ps1 share.
# Each throws on failure; the scripts catch it, print it and exit 1.

Set-StrictMode -Version Latest

$script:Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$script:VersionFile = Join-Path $script:Root "VERSION"
$script:DistDir = Join-Path $script:Root "dist"

# What the portable zip holds; installer\eve-maj-preview.iss lists the same files for the installer.
$script:PackageItems = @(
    @{ Name = "eve-maj-preview.exe"; Source = "zig-out\bin" },
    @{ Name = "CascadiaCode-LICENSE.txt"; Source = "licenses"; Dest = "licenses" },
    @{ Name = "Geist-LICENSE.txt"; Source = "licenses"; Dest = "licenses" },
    @{ Name = "knots-LICENSE.txt"; Source = "licenses"; Dest = "licenses" },
    @{ Name = "eve-maj-preview-LICENSE.txt"; Source = "licenses"; Dest = "licenses" },
    @{ Name = "sounds"; Source = "." },
    @{ Name = "README.md"; Source = "." }
)

function Get-RepoRoot { return $script:Root }

# Runs a native command and throws when it exits non-zero.
function Invoke-Checked([string]$What, [scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE" }
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

function Assert-Gh {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found. Install it to publish releases: https://cli.github.com"
    }
}

function Get-BaseVersion {
    if (-not (Test-Path $script:VersionFile)) { throw "VERSION file not found at $($script:VersionFile)" }
    return (Get-Content $script:VersionFile -Raw).Trim()
}

function Invoke-UnitTests {
    Write-Host "Running unit tests (zig build test)..." -ForegroundColor Cyan
    Push-Location $script:Root
    try { Invoke-Checked "zig build test" { zig build test } } finally { Pop-Location }
}

# VERSION is embedded at compile time, so it reads $Version for the build and is restored after.
function Invoke-ReleaseBuild([string]$Version) {
    $original = Get-Content $script:VersionFile -Raw
    $isRewritten = $original.Trim() -ne $Version
    if ($isRewritten) { Set-Content -Path $script:VersionFile -Value $Version -NoNewline }
    Push-Location $script:Root
    try {
        Write-Host "Building v$Version (zig build --release=safe)..." -ForegroundColor Cyan
        Invoke-Checked "zig build" { zig build --release=safe }
    } finally {
        Pop-Location
        if ($isRewritten) { Set-Content -Path $script:VersionFile -Value $original -NoNewline }
    }
}

# The zip's path.
function New-PortableZip([string]$Version) {
    $packageName = "eve-maj-preview-v$Version"
    $stagingDir = Join-Path $script:DistDir $packageName
    $zipPath = Join-Path $script:DistDir "$packageName-portable.zip"
    Write-Host "Packaging EVE-Maj Preview v$Version..." -ForegroundColor Green

    # Start clean so stale files never end up in the archive.
    if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
    New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
    foreach ($item in $script:PackageItems) {
        $source = Join-Path (Join-Path $script:Root $item.Source) $item.Name
        if (-not (Test-Path $source)) { throw "$($item.Name) not found in $($item.Source)" }
        $destination = if ($item.ContainsKey("Dest")) { Join-Path $stagingDir $item.Dest } else { $stagingDir }
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Write-Host "  Copying $($item.Name)" -ForegroundColor Cyan
        Copy-Item $source -Destination $destination -Recurse
    }

    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Write-Host "Creating archive: $zipPath" -ForegroundColor Cyan
    Compress-Archive -Path (Join-Path $stagingDir "*") -DestinationPath $zipPath -CompressionLevel Optimal
    # The staging folder only controls the archive's internal layout.
    Remove-Item $stagingDir -Recurse -Force
    return $zipPath
}

# The installer's path, or $null without Inno Setup unless -Required, which throws instead.
function New-Installer([string]$Version, [switch]$Required) {
    $compiler = Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    if (-not $compiler) {
        $compiler = Get-ChildItem -Path "${env:ProgramFiles(x86)}", "$env:ProgramFiles" -Filter "Inno Setup*" -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "ISCC.exe" } |
            Where-Object { Test-Path $_ } |
            Select-Object -First 1
    }
    if (-not $compiler) {
        if ($Required) { throw "Inno Setup (ISCC.exe) not found" }
        Write-Host "Inno Setup (ISCC.exe) not found - skipping installer build. Install it from https://jrsoftware.org/isinfo.php to include one in releases." -ForegroundColor Yellow
        return $null
    }
    Write-Host "Building installer with Inno Setup..." -ForegroundColor Cyan
    Invoke-Checked "Inno Setup" { & $compiler "/Q" "/DMyAppVersion=$Version" (Join-Path $script:Root "installer\eve-maj-preview.iss") }
    return Join-Path $script:DistDir "eve-maj-preview-v$Version-setup.exe"
}

# SHA256SUMS.txt beside the assets, in sha256sum's format; its path.
function New-Checksums([string[]]$Paths) {
    $sumsPath = Join-Path $script:DistDir "SHA256SUMS.txt"
    $lines = foreach ($path in $Paths) { "$((Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant())  $(Split-Path $path -Leaf)" }
    Set-Content -Path $sumsPath -Value $lines -Encoding ascii
    return $sumsPath
}

# The text under CHANGELOG's `## [<Heading>]`, or $null if there's no such section.
function Get-ChangelogSection([string]$Heading) {
    $changelogFile = Join-Path $script:Root "docs\CHANGELOG.md"
    if (-not (Test-Path $changelogFile)) { return $null }
    $text = Get-Content $changelogFile -Raw
    if ($text -match "(?ms)^## \[$([regex]::Escape($Heading))\][^\r\n]*\r?\n(.*?)(?=^## \[|\z)") {
        $section = $matches[1].Trim()
        if ($section) { return $section }
    }
    return $null
}

# The next free vX.Y.Z-dev.N for VERSION, counting tags on origin too.
function Get-NextDevTag([string]$BaseVersion) {
    Write-Host "Fetching existing dev tags..." -ForegroundColor Cyan
    Invoke-Checked "git fetch" { git fetch origin --tags --quiet }
    $highest = 0
    foreach ($tag in (git tag --list "v$BaseVersion-dev.*")) {
        if ($tag -match '-dev\.(\d+)$' -and [int]$matches[1] -gt $highest) { $highest = [int]$matches[1] }
    }
    return "v$BaseVersion-dev.$($highest + 1)"
}

# Pushes the current branch, then tags its head and pushes the tag, which starts .github\workflows\release.yml.
function Publish-Tag([string]$Tag) {
    git rev-parse -q --verify "refs/tags/$Tag" | Out-Null
    if ($LASTEXITCODE -eq 0) { throw "tag $Tag already exists locally. Delete it (git tag -d $Tag) if you want to retry." }
    Write-Host "  Pushing the branch" -ForegroundColor Cyan
    Invoke-Checked "git push" { git push origin HEAD }
    Write-Host "  Tagging $Tag" -ForegroundColor Cyan
    Invoke-Checked "git tag" { git tag -a $Tag -m $Tag }
    Write-Host "  Pushing the tag" -ForegroundColor Cyan
    Invoke-Checked "git push (tag)" { git push origin $Tag }
}

function Test-GitHubRelease([string]$Tag) {
    Invoke-GhCapture @("release", "view", $Tag, "--json", "tagName") | Out-Null
    return $LASTEXITCODE -eq 0
}

# A draft, or a prerelease that never becomes Latest; its URL.
function Publish-GitHubRelease([string]$Tag, [string]$Title, [string[]]$Assets, [string]$Notes, [switch]$Prerelease) {
    $kind = if ($Prerelease) { "--prerelease" } else { "--draft" }
    $arguments = @("release", "create", $Tag) + $Assets + @($kind, "--verify-tag", "--title", $Title)
    $notesFile = $null
    if ($Notes) {
        # Notes go through a file: inline they can exceed the 32K command-line limit.
        $notesFile = Join-Path ([IO.Path]::GetTempPath()) "release-notes-$Tag.md"
        Set-Content -Path $notesFile -Value $Notes -Encoding utf8
        $arguments += @("--notes-file", $notesFile)
    } else {
        Write-Host "  No CHANGELOG entries found - falling back to --generate-notes" -ForegroundColor Yellow
        $arguments += "--generate-notes"
    }
    try {
        $output = Invoke-GhCapture $arguments
    } finally {
        if ($notesFile) { Remove-Item $notesFile -ErrorAction SilentlyContinue }
    }
    if ($LASTEXITCODE -ne 0) { throw "gh release create failed: $($output -join ' ')" }
    return ($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^https://' } | Select-Object -Last 1)
}

# The changelog section as a Discord embed's text: bold headings and bullet glyphs, cut to fit.
function Format-DiscordNotes([string]$Notes, [string]$EmptyText) {
    $body = $null
    if ($Notes) {
        $sections = [regex]::Matches($Notes, '(?ms)^### (\S.*?)\r?\n(.*?)(?=^### |\z)')
        $parts = foreach ($section in $sections) {
            $heading = $section.Groups[1].Value.Trim()
            $bullets = ($section.Groups[2].Value.Trim() -split '\r?\n' | Where-Object { $_ -match '^- ' } | ForEach-Object { "• " + $_.Substring(2) }) -join "`n"
            "**$heading**`n$bullets"
        }
        $body = $parts -join "`n`n"
    }
    if (-not $body) { $body = $EmptyText }
    if ($body.Length -gt 3800) { $body = $body.Substring(0, 3800) + "`n..." }
    return $body
}

function New-DiscordPayload([string]$Title, [string]$Url, [int]$Color, [string]$Username, [string]$Description) {
    return @{
        username = $Username
        embeds   = @(@{ title = $Title; url = $Url; color = $Color; description = $Description })
    }
}

# Warns rather than throws: the release is already out.
function Send-DiscordNotice([string]$WebhookUrl, [hashtable]$Payload) {
    try {
        $body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Payload -Depth 6))
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType "application/json; charset=utf-8" -Body $body | Out-Null
        Write-Host "  Posted the announcement to Discord" -ForegroundColor Cyan
    } catch {
        Write-Host "WARNING: Failed to post the Discord announcement: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Export-ModuleMember -Function Get-RepoRoot, Assert-Gh, Get-BaseVersion, Invoke-UnitTests, Invoke-ReleaseBuild,
    New-PortableZip, New-Installer, New-Checksums, Get-ChangelogSection, Get-NextDevTag, Publish-Tag,
    Test-GitHubRelease, Publish-GitHubRelease, Format-DiscordNotes, New-DiscordPayload, Send-DiscordNotice
