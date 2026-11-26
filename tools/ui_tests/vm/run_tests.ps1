<#
.SYNOPSIS
Builds the app, runs tools/ui_tests inside a Hyper-V VM ("Dev" by default), and streams the output back.

.DESCRIPTION
Needs: membership of Hyper-V Administrators, the guest login saved once with
    Get-Credential -UserName ".\tester" | Export-Clixml "$env:LOCALAPPDATA\eve-maj-vm\tester.xml"
and `tester` signed in on the VM's console (auto-logon does this after a guest restart).
The config dialog also needs install_lavapipe.ps1 run once. Only tools\ui_tests and the two exes are
copied in; the tests make their own sandboxed profiles.

.EXAMPLE
tools\ui_tests\vm\run_tests.ps1                    # build, then run every test
tools\ui_tests\vm\run_tests.ps1 -NoBuild hotkey     # run tests whose name contains "hotkey"
tools\ui_tests\vm\run_tests.ps1 -NoBuild --failed   # rerun what the last VM run failed
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$NoBuild,
    [string]$VMName = "Dev",
    [Parameter(ValueFromRemainingArguments)][string[]]$RunArguments = @()
)

$ErrorActionPreference = "Stop"

$Repo = Resolve-Path (Join-Path $PSScriptRoot "..\..\..")
$StateDir = Join-Path $env:LOCALAPPDATA "eve-maj-vm"
$CredentialFile = Join-Path $StateDir "tester.xml"
$TaskName = "eve-maj-ui-tests"
$GuestRoot = "C:\vmtests"
$GuestPython = "C:\Program Files\Python313\pythonw.exe"
$PollSeconds = 3
$Exes = "eve-maj-preview.exe", "eve-maj-sim.exe"

if (-not (Test-Path $CredentialFile)) { throw "Missing $CredentialFile; save the guest login first (see Get-Help $PSCommandPath)" }
$credential = Import-Clixml $CredentialFile

if (-not $NoBuild) {
    Push-Location $Repo
    try {
        zig build
        if ($LASTEXITCODE -ne 0) { throw "zig build failed" }
    } finally { Pop-Location }
}
foreach ($exe in $Exes) {
    if (-not (Test-Path (Join-Path $Repo "zig-out\bin\$exe"))) { throw "Missing zig-out\bin\$exe; build first" }
}

$session = New-PSSession -VMName $VMName -Credential $credential
try {
    $guestState = Invoke-Command -Session $session -ArgumentList $TaskName {
        param($TaskName)
        $isSignedIn = [bool](query user 2>$null | Select-String -Pattern '^\s*>?tester\s+.*\sActive\s')
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        @{ is_signed_in = $isSignedIn; is_running = ($task -and $task.State -eq "Running") }
    }
    if (-not $guestState.is_signed_in) { throw "tester isn't signed in on the VM's console; restart the guest so auto-logon signs it in" }
    if ($guestState.is_running) { throw "A test run is already going in the VM" }

    Invoke-Command -Session $session -ArgumentList $GuestRoot {
        param($GuestRoot)
        # A status strip left by a run that was cut short.
        Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" | Where-Object CommandLine -like "*\vm\status.py*" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
        Remove-Item "$GuestRoot\repo", "$GuestRoot\out" -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force "$GuestRoot\repo\tools", "$GuestRoot\repo\zig-out\bin", "$GuestRoot\out" | Out-Null
    }
    Copy-Item (Join-Path $Repo "tools\ui_tests") -Destination "$GuestRoot\repo\tools\" -Recurse -ToSession $session -Exclude "__pycache__"
    foreach ($exe in $Exes) {
        Copy-Item (Join-Path $Repo "zig-out\bin\$exe") -Destination "$GuestRoot\repo\zig-out\bin\" -ToSession $session
    }

    $quoted = ($RunArguments | ForEach-Object { '"' + ($_ -replace '"', '') + '"' }) -join " "
    Invoke-Command -Session $session -ArgumentList $TaskName, $GuestRoot, $GuestPython, $quoted {
        param($TaskName, $GuestRoot, $GuestPython, $quoted)
        $runner = "$GuestRoot\repo\tools\ui_tests\vm\runner.py"
        $action = New-ScheduledTaskAction -Execute $GuestPython -Argument "`"$runner`" `"$GuestRoot\out`" `"$GuestRoot\vulkan`" $quoted" -WorkingDirectory "$GuestRoot\repo\tools\ui_tests"
        # Interactive: the run needs tester's desktop for windows, focus and input.
        $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\tester" -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Start-ScheduledTask -TaskName $TaskName
    }

    $shown = 0
    $exitCode = $null
    while ($null -eq $exitCode) {
        Start-Sleep -Seconds $PollSeconds
        $poll = Invoke-Command -Session $session -ArgumentList $GuestRoot, $TaskName {
            param($GuestRoot, $TaskName)
            $lines = @(if (Test-Path "$GuestRoot\out\output.txt") { Get-Content "$GuestRoot\out\output.txt" -Encoding utf8 })
            $code = if (Test-Path "$GuestRoot\out\exitcode.txt") { [int](Get-Content "$GuestRoot\out\exitcode.txt" -Raw) } else { $null }
            @{ lines = $lines; code = $code; state = (Get-ScheduledTask -TaskName $TaskName).State.ToString() }
        }
        if ($poll.lines.Count -gt $shown) {
            $poll.lines[$shown..($poll.lines.Count - 1)] | ForEach-Object { Write-Host $_ }
            $shown = $poll.lines.Count
        }
        $exitCode = $poll.code
        if ($null -eq $exitCode -and $poll.state -ne "Running") { throw "The VM's test task stopped without writing an exit code" }
    }

    $savedOutput = Join-Path $StateDir "last-output.txt"
    Copy-Item "$GuestRoot\out\output.txt" -Destination $savedOutput -FromSession $session
    Write-Host "`nVM run finished with exit code $exitCode; output saved to $savedOutput"
    exit $exitCode
} finally {
    Remove-PSSession $session
}
