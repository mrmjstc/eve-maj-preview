# Samples a running EVE-Maj Preview's memory and handle counts, to spot leaks:
# a metric that climbs with each repeat of an action and never comes back down.
#
#   .\tools\memory_soak.ps1                          # until Ctrl+C, every 5 s
#   .\tools\memory_soak.ps1 -DurationMinutes 60 -IntervalSeconds 10
#   .\tools\memory_soak.ps1 -DurationSeconds 30 -IntervalSeconds 2
#   .\tools\memory_soak.ps1 -ProcessName eve-maj-sim
#
# The two durations add up; with neither it runs until Ctrl+C or the process exits.
# Ctrl+C still writes the CSV and summary.
#
# Writes a CSV (default under %TEMP%) and prints start/end/min/max and a
# least-squares slope per hour for each metric when it stops.

param(
    [string]$ProcessName = "eve-maj-preview",
    [ValidateRange(1, 3600)]
    [int]$IntervalSeconds = 5,
    [ValidateRange(0, 100000)]
    [int]$DurationMinutes = 0,
    [ValidateRange(0, 6000000)]
    [int]$DurationSeconds = 0,
    [string]$OutFile = (Join-Path $env:TEMP ("memory_soak_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date)))
)

$ErrorActionPreference = "Stop"

Add-Type -Namespace MemorySoak -Name User32 -MemberDefinition @"
[DllImport("user32.dll")]
public static extern uint GetGuiResources(System.IntPtr hProcess, uint uiFlags);
"@
$GR_GDIOBJECTS = 0
$GR_USEROBJECTS = 1

$found = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
if ($found.Count -eq 0) {
    Write-Error "No running process named '$ProcessName'"
}
if ($found.Count -gt 1) {
    Write-Error "More than one '$ProcessName' is running; close the others"
}
$process = $found[0]

$metrics = "PrivateKB", "WorkingSetKB", "GdiObjects", "UserObjects", "Handles", "Threads"
$samples = [System.Collections.Generic.List[object]]::new()
$started = Get-Date
$duration_seconds = $DurationMinutes * 60 + $DurationSeconds
$deadline = if ($duration_seconds -gt 0) { $started.AddSeconds($duration_seconds) } else { [datetime]::MaxValue }
$stops = if ($duration_seconds -gt 0) { "stops after $duration_seconds s, on Ctrl+C or when the process exits" } else { "runs until Ctrl+C or the process exits" }

function Get-Sample {
    $process.Refresh()
    [pscustomobject]@{
        Time         = (Get-Date).ToString("o")
        Seconds      = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        PrivateKB    = [math]::Round($process.PrivateMemorySize64 / 1KB)
        WorkingSetKB = [math]::Round($process.WorkingSet64 / 1KB)
        GdiObjects   = [MemorySoak.User32]::GetGuiResources($process.Handle, $GR_GDIOBJECTS)
        UserObjects  = [MemorySoak.User32]::GetGuiResources($process.Handle, $GR_USEROBJECTS)
        Handles      = $process.HandleCount
        Threads      = $process.Threads.Count
    }
}

# Units per hour; 0 with fewer than two samples.
function Get-Slope([object[]]$rows, [string]$metric) {
    $count = $rows.Count
    if ($count -lt 2) { return 0 }
    $mean_x = ($rows | Measure-Object Seconds -Average).Average
    $mean_y = ($rows | Measure-Object $metric -Average).Average
    $numerator = 0.0
    $denominator = 0.0
    foreach ($row in $rows) {
        $delta_x = $row.Seconds - $mean_x
        $numerator += $delta_x * ($row.$metric - $mean_y)
        $denominator += $delta_x * $delta_x
    }
    if ($denominator -eq 0) { return 0 }
    return $numerator / $denominator * 3600
}

function Write-Summary {
    if ($samples.Count -eq 0) { return }
    $rows = $samples.ToArray()
    $rows | Export-Csv -Path $OutFile -NoTypeInformation -Encoding utf8
    $minutes = [math]::Round($rows[-1].Seconds / 60, 1)
    Write-Host ""
    Write-Host "$($rows.Count) samples over $minutes min -> $OutFile"
    $metrics | ForEach-Object {
        $stats = $rows | Measure-Object $_ -Minimum -Maximum
        [pscustomobject]@{
            Metric    = $_
            Start     = $rows[0].$_
            End       = $rows[-1].$_
            Min       = $stats.Minimum
            Max       = $stats.Maximum
            PerHour   = [math]::Round((Get-Slope $rows $_), 1)
        }
    } | Format-Table -AutoSize | Out-Host
}

Write-Host "Sampling '$ProcessName' (pid $($process.Id)) every $IntervalSeconds s; $stops"
try {
    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        $sample = Get-Sample
        $samples.Add($sample)
        Write-Host ("{0,8:N1}s  private {1,7:N0} KB  ws {2,7:N0} KB  gdi {3,4}  user {4,4}  handles {5,5}  threads {6,3}" -f `
            $sample.Seconds, $sample.PrivateKB, $sample.WorkingSetKB, $sample.GdiObjects, $sample.UserObjects, $sample.Handles, $sample.Threads)
        Start-Sleep -Seconds $IntervalSeconds
    }
    if ($process.HasExited) { Write-Host "Process exited" }
}
finally {
    Write-Summary
}
