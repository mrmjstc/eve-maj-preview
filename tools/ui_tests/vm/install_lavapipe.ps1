<#
.SYNOPSIS
Installs Mesa's lavapipe, a CPU Vulkan driver, in the test VM so the knots config dialog can open there.

.DESCRIPTION
Hyper-V gives the guest no GPU, so the dialog fails with VulkanUnavailable. This puts lavapipe and the host's
Vulkan loader (vulkan-1.dll) in C:\vmtests\vulkan, outside the folder each run replaces. runner.py then
puts that folder on PATH and points VK_DRIVER_FILES at lavapipe, so nothing in the guest needs admin rights.
Run once, and again only to change the Mesa version. Needs the gh CLI and the same guest login as run_tests.ps1.

.EXAMPLE
tools\ui_tests\vm\install_lavapipe.ps1
tools\ui_tests\vm\install_lavapipe.ps1 -Version 26.2.7
#>
[CmdletBinding()]
param(
    [string]$Version = "26.2.6",
    [string]$VMName = "Dev"
)

$ErrorActionPreference = "Stop"

$StateDir = Join-Path $env:LOCALAPPDATA "eve-maj-vm"
$CredentialFile = Join-Path $StateDir "tester.xml"
$CacheDir = Join-Path $StateDir "mesa-$Version"
$Archive = "mesa3d-$Version-release-msvc.7z"
$GuestDir = "C:\vmtests\vulkan"
$Loader = Join-Path $env:SystemRoot "System32\vulkan-1.dll"
$Files = "x64/vulkan_lvp.dll", "x64/lvp_icd.x86_64.json"

if (-not (Test-Path $CredentialFile)) { throw "Missing $CredentialFile; see Get-Help $(Join-Path $PSScriptRoot 'run_tests.ps1')" }
if (-not (Test-Path $Loader)) { throw "Missing $Loader; the host needs a Vulkan driver installed to lend its loader" }

if (-not (Test-Path (Join-Path $CacheDir "x64\vulkan_lvp.dll"))) {
    New-Item -ItemType Directory -Force $CacheDir | Out-Null
    gh release download $Version --repo pal1000/mesa-dist-win --pattern $Archive --dir $CacheDir --clobber
    if ($LASTEXITCODE -ne 0) { throw "Failed to download $Archive" }
    # Windows' own tar (libarchive) reads 7z; Git Bash's GNU tar doesn't.
    Push-Location $CacheDir
    try {
        & (Join-Path $env:SystemRoot "System32\tar.exe") -xf $Archive @Files
        if ($LASTEXITCODE -ne 0) { throw "Failed to extract lavapipe from $Archive" }
    } finally { Pop-Location }
    Remove-Item (Join-Path $CacheDir $Archive)
}

$session = New-PSSession -VMName $VMName -Credential (Import-Clixml $CredentialFile)
try {
    Invoke-Command -Session $session -ArgumentList $GuestDir {
        param($GuestDir)
        Remove-Item $GuestDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force $GuestDir | Out-Null
    }
    foreach ($file in $Files) {
        Copy-Item (Join-Path $CacheDir $file) -Destination "$GuestDir\" -ToSession $session
    }
    Copy-Item $Loader -Destination "$GuestDir\" -ToSession $session
    $installed = Invoke-Command -Session $session -ArgumentList $GuestDir { param($GuestDir) (Get-ChildItem $GuestDir).Name }
    Write-Host "Installed lavapipe $Version in the VM's ${GuestDir}: $($installed -join ', ')"
} finally {
    Remove-PSSession $session
}
