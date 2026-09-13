<#
.SYNOPSIS
  Simulates one or more EVE Online clients for testing EVE-Zig Preview's
  window detection and chatlog/gamelog parsing, without running the real game.

.DESCRIPTION
  Detection in src/scout.zig requires BOTH:
    - a top-level visible window with class name exactly "trinityWindow"
    - owned by a process whose exe path ends in "exefile.exe"
  This script satisfies both by copying the local powershell.exe to
  "exefile.exe" in an isolated scratch folder and launching one copy per
  simulated character. Each copy drives a real Win32 window registered under
  the literal class name "trinityWindow" (raw RegisterClassEx/CreateWindowEx,
  not WinForms, which cannot produce that exact class name) whose title flips
  between "EVE" (logged out / loading) and "EVE - <CharacterName>" (logged
  in) under your control.

  It also writes real-format chatlog/gamelog fixture files (UTF-16LE
  chatlogs, UTF-8-BOM gamelogs) that you can append simulated events to
  (bounty payouts, mining, combat, jumps) while the app is watching them.

  Everything is confined to -WorkDir. Nothing under the real
  Documents\EVE\logs folders is touched unless you explicitly point
  -ChatlogDir/-GamelogDir there.

.PARAMETER CharacterNames
  Characters to start logged in immediately.

.PARAMETER WorkDir
  Scratch root for the copied exe, control files, and (by default) logs.

.PARAMETER ChatlogDir / GamelogDir
  Where fixture log files are written. Point the app's settings at these
  paths (Chatlog/Gamelog directory fields) to have it watch the simulated
  files instead of your real EVE logs.

.PARAMETER WindowStyle
  Console window style for the spawned exefile.exe copies. Kept visible by
  default (Minimized) rather than Hidden, since a hidden process running
  under a renamed system binary is the kind of pattern AV/EDR flags.

.EXAMPLE
  .\test-eve-clients.ps1 -CharacterNames 'Aria Kestrel','Dax Solano'
#>
[CmdletBinding()]
param(
    [string[]]$CharacterNames = @('Test Client 1', 'Test Client 2', 'Test Client 3', 'Test Client 4', 'Test Client 5', 'Test Client 6', 'Test Client 7', 'Test Client 8', 'Test Client 9', 'Test Client 10'),
    [string]$WorkDir = (Join-Path $env:TEMP 'EveMajSim'),
    # Matches config.zig's own default, so the app picks these fixtures up with no settings change.
    [string]$ChatlogDir = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'EVE\logs\Chatlogs'),
    [string]$GamelogDir = (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'EVE\logs\Gamelogs'),
    [ValidateSet('Normal', 'Minimized', 'Maximized')]
    [string]$WindowStyle = 'Minimized',
    # Stretched to fill each simulated window so it looks like the game, not a blank box.
    [string]$BackgroundImageUrl = 'http://i.mjst.cc/wZvLshTidi.png',
    [switch]$NoBackgroundImage
)

$ErrorActionPreference = 'Stop'

$exeDir = Join-Path $WorkDir 'exe'
$controlDir = Join-Path $WorkDir 'control'
$stateDir = Join-Path $WorkDir 'state'
foreach ($dir in @($WorkDir, $exeDir, $controlDir, $stateDir, $ChatlogDir, $GamelogDir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

$fakeExePath = Join-Path $exeDir 'exefile.exe'
# Always Windows PowerShell 5.1, regardless of which shell is running this orchestrator.
$sourcePs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path $sourcePs)) {
    throw "Windows PowerShell not found at $sourcePs"
}
if (-not (Test-Path $fakeExePath)) {
    Copy-Item -Path $sourcePs -Destination $fakeExePath -Force
}

$bgImagePath = ''
if (-not $NoBackgroundImage -and $BackgroundImageUrl) {
    $assetsDir = Join-Path $WorkDir 'assets'
    New-Item -ItemType Directory -Force -Path $assetsDir | Out-Null
    $candidatePath = Join-Path $assetsDir 'client_background.png'
    if (-not (Test-Path $candidatePath)) {
        try {
            Invoke-WebRequest -Uri $BackgroundImageUrl -OutFile $candidatePath -UseBasicParsing
        } catch {
            Write-Warning "Could not download background image ($_) - simulated windows will use a plain background."
        }
    }
    if (Test-Path $candidatePath) { $bgImagePath = $candidatePath }
}

# Agent: a real top-level window registered under class name "trinityWindow", the only thing scout.zig's filter matches on.
$agentTemplate = @'
Add-Type -TypeDefinition @"
using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;

// WinForms can't register an exact custom class name (it wraps it), so this uses raw CreateWindowEx/RegisterClassEx instead.
public class TrinityWindow {
    [StructLayout(LayoutKind.Sequential)]
    private struct WNDCLASSEX {
        public uint cbSize;
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int ptX;
        public int ptY;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT {
        public int left;
        public int top;
        public int right;
        public int bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PAINTSTRUCT {
        public IntPtr hdc;
        public bool fErase;
        public RECT rcPaint;
        public bool fRestore;
        public bool fIncUpdate;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] rgbReserved;
    }

    private delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern ushort RegisterClassEx(ref WNDCLASSEX lpwcx);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateWindowEx(uint dwExStyle, string lpClassName, string lpWindowName, uint dwStyle, int x, int y, int w, int h, IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);
    // CharSet.Unicode required or this binds to DefWindowProcA, which mangles the Unicode window title.
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DefWindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    private static extern bool UpdateWindow(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool SetWindowText(IntPtr hWnd, string text);
    [DllImport("user32.dll")]
    private static extern bool GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref MSG lpMsg);
    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessage(ref MSG lpMsg);
    [DllImport("user32.dll")]
    private static extern IntPtr SetTimer(IntPtr hWnd, IntPtr nIDEvent, uint uElapse, IntPtr lpTimerFunc);
    [DllImport("user32.dll")]
    private static extern void PostQuitMessage(int nExitCode);
    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(IntPtr hWnd);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);
    [DllImport("user32.dll")]
    private static extern IntPtr BeginPaint(IntPtr hWnd, out PAINTSTRUCT lpPaint);
    [DllImport("user32.dll")]
    private static extern bool EndPaint(IntPtr hWnd, ref PAINTSTRUCT lpPaint);
    [DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    private const uint WM_DESTROY = 0x0002;
    private const uint WM_PAINT = 0x000F;
    private const uint WM_ERASEBKGND = 0x0014;
    private const uint WM_TIMER = 0x0113;
    private const uint WS_OVERLAPPEDWINDOW = 0x00CF0000;
    private const uint WS_VISIBLE = 0x10000000;
    private const int CW_USEDEFAULT = unchecked((int)0x80000000);

    private static string charName;
    private static string ctrlFile;
    private static string lastCmd = "";
    // Rooted so it isn't GC'd; native code holds only a raw function pointer to it.
    private static readonly WndProcDelegate WndProcHandler = WndProc;
    // Stretched to fill the client area on WM_PAINT; null if no image was supplied/loadable.
    private static Bitmap backgroundImage;

    private static IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam) {
        if (msg == WM_TIMER) {
            string cmd;
            try { cmd = File.ReadAllText(ctrlFile).Trim(); } catch { return IntPtr.Zero; }
            if (cmd != lastCmd) {
                lastCmd = cmd;
                if (cmd == "login") SetWindowText(hWnd, "EVE - " + charName);
                else if (cmd == "logout") SetWindowText(hWnd, "EVE");
                else if (cmd == "exit") DestroyWindow(hWnd);
            }
            return IntPtr.Zero;
        }
        if (msg == WM_ERASEBKGND && backgroundImage != null) {
            return (IntPtr)1;
        }
        if (msg == WM_PAINT) {
            PAINTSTRUCT ps;
            IntPtr hdc = BeginPaint(hWnd, out ps);
            if (backgroundImage != null) {
                RECT rect;
                GetClientRect(hWnd, out rect);
                using (Graphics g = Graphics.FromHdc(hdc)) {
                    g.DrawImage(backgroundImage, 0, 0, rect.right - rect.left, rect.bottom - rect.top);
                }
            }
            EndPaint(hWnd, ref ps);
            return IntPtr.Zero;
        }
        if (msg == WM_DESTROY) {
            PostQuitMessage(0);
            return IntPtr.Zero;
        }
        return DefWindowProc(hWnd, msg, wParam, lParam);
    }

    public static void Run(string name, string ctrl, string bgImagePath) {
        charName = name;
        ctrlFile = ctrl;
        if (!string.IsNullOrEmpty(bgImagePath)) {
            try { backgroundImage = new Bitmap(bgImagePath); } catch { backgroundImage = null; }
        }

        IntPtr hInstance = GetModuleHandle(null);
        WNDCLASSEX wc = new WNDCLASSEX();
        wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
        wc.style = 0x0003;
        wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(WndProcHandler);
        wc.hInstance = hInstance;
        wc.lpszClassName = "trinityWindow";
        RegisterClassEx(ref wc);

        // 16:9 to match the background screenshot's aspect ratio instead of stretching it into a 4:3 box.
        IntPtr hwnd = CreateWindowEx(0, "trinityWindow", "EVE", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            CW_USEDEFAULT, CW_USEDEFAULT, 1024, 576, IntPtr.Zero, IntPtr.Zero, hInstance, IntPtr.Zero);
        if (hwnd == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());

        ShowWindow(hwnd, 1);
        UpdateWindow(hwnd);
        SetTimer(hwnd, (IntPtr)1, 400, IntPtr.Zero);

        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0)) {
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
    }
}
"@ -ReferencedAssemblies System.Drawing
[TrinityWindow]::Run(__CHARNAME__, __CTRLFILE__, __BGIMAGE__)
'@

# Deterministic (hashed, not random) so re-running the script resolves to the same filename.
function Get-StableCharId {
    param([string]$CharName)
    $hash = [System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($CharName))
    $num = [BitConverter]::ToUInt32($hash, 0)
    return 1000000000 + ($num % 1147483647)
}

$StableSessionStart = [datetime]'2024-01-01 00:00:00'

function Get-CharacterStateFile {
    param([string]$CharName)
    $safeName = ($CharName -replace '[^A-Za-z0-9]', '_')
    Join-Path $stateDir "$safeName.json"
}

# Persists each character's current Chatlog/Gamelog paths across separate script runs.
function Save-CharacterState {
    param([string]$CharName, [string]$ChatlogPath, [string]$GamelogPath, [string]$System)
    $state = @{ Chatlog = $ChatlogPath; Gamelog = $GamelogPath; System = $System }
    $state | ConvertTo-Json -Compress | Set-Content -Path (Get-CharacterStateFile -CharName $CharName)
}

function Get-CharacterState {
    param([string]$CharName)
    $path = Get-CharacterStateFile -CharName $CharName
    if (-not (Test-Path $path)) { return $null }
    try {
        $state = Get-Content -Path $path -Raw | ConvertFrom-Json
        if ((Test-Path $state.Chatlog) -and (Test-Path $state.Gamelog)) { return $state }
    } catch {}
    return $null
}

# Matches a real captured chatlog's exact structure: LF header, CRLF+leading-BOM log lines.
function New-ChatlogFile {
    param([string]$CharName, [string]$CharId, [string]$Dir, [datetime]$Started, [string]$System)

    $stamp = $Started.ToString('yyyyMMdd_HHmmss')
    $path = Join-Path $Dir "Local_${stamp}_${CharId}.txt"
    if (Test-Path $path) { return $path }

    $sessionTs = $Started.ToString('yyyy.MM.dd HH:mm:ss')
    $dashLine = (' ' * 8) + ('-' * 63)
    $header = "`r`n`r`n`n`n" +
        "$dashLine`n`n" +
        "          Channel ID:      local`n" +
        "          Channel Name:    Local`n" +
        "          Listener:        $CharName`n" +
        "          Session started: $sessionTs`n" +
        "$dashLine`n`n"
    $firstLine = Format-ChatlogLine -Ts $sessionTs -Text "EVE System > Channel changed to Local : $System"

    $text = $header + $firstLine
    $bytes = [System.Text.Encoding]::Unicode.GetPreamble() + [System.Text.Encoding]::Unicode.GetBytes($text)
    [System.IO.File]::WriteAllBytes($path, $bytes)
    return $path
}

function Format-ChatlogLine {
    param([string]$Ts, [string]$Text)
    $bomChar = [char]0xFEFF
    return "$bomChar[ $Ts ] $Text`r`n"
}

function New-GamelogFile {
    param([string]$CharName, [string]$CharId, [string]$Dir, [datetime]$Started)

    $stamp = $Started.ToString('yyyyMMdd_HHmmss')
    $path = Join-Path $Dir "${stamp}_${CharId}.txt"
    if (Test-Path $path) { return $path }

    $sessionTs = $Started.ToString('yyyy.MM.dd HH:mm:ss')
    $lines = @(
        ('-' * 60)
        '  Gamelog'
        "  Listener: $CharName"
        "  Session Started: $sessionTs"
        ('-' * 60)
        "[ $sessionTs ] (hint) Attempting to join a channel"
    )
    $text = ($lines -join "`r`n") + "`r`n"
    Set-Content -Path $path -Value $text -Encoding UTF8 -NoNewline
    return $path
}

function Add-GamelogEvent {
    param([string]$Path, [string]$Kind, [string]$Destination = 'Jita')

    $ts = (Get-Date).ToString('yyyy.MM.dd HH:mm:ss')
    $line = switch ($Kind) {
        'bounty' {
            $amount = Get-Random -Minimum 1000 -Maximum 500000
            $formatted = '{0:N0}' -f $amount
            "[ $ts ] (bounty) <font size=12><b><color=0xff00aa00>$formatted ISK</b><color=0x77ffffff> added to next bounty payout (payment adjusted)"
        }
        'mining' {
            $units = Get-Random -Minimum 1 -Maximum 200
            $ore = Get-Random -InputObject @('Veldspar', 'Scordite', 'Pyroxeres', 'Coesite', 'Zeolites')
            "[ $ts ] (mining) You mined $units units of $ore."
        }
        'combatIn' {
            $dmg = Get-Random -Minimum 10 -Maximum 500
            "[ $ts ] (combat) <color=0xffcc0000><b>$dmg</b> <color=0x77ffffff><font size=10>from</font> <b><color=0xffffffff>Gist Seraphim</b><font size=10><color=0x77ffffff> - Heavy Missile - Hits"
        }
        'combatOut' {
            $dmg = Get-Random -Minimum 10 -Maximum 500
            "[ $ts ] (combat) <color=0xff00ffff><b>$dmg</b> <color=0x77ffffff><font size=10>to</font> <b><color=0xffffffff>Gistatis Tribunus</b><font size=10><color=0x77ffffff> - Nova Cruise Missile - Hits"
        }
        'miss' {
            "[ $ts ] (combat) Gist Seraphim misses you completely"
        }
        'undock' {
            "[ $ts ] Undocking from Jita IV - Moon 4 - Caldari Navy Assembly Plant in Jita"
        }
        # Everything below fires one specific src/types.zig NotificationType, matching the exact substrings
        # src/chatlog.zig's parseQuestionEvent/parseNotifyEvent/parseCombatEvent/parseNoneEvent look for - see
        # the config dialog's Event Alerts table (NOTIFICATION_TYPES in config_dialog.js) for the full type list.
        'FleetInvite' {
            "[ $ts ] (question) Someone wants you to join their fleet, do you accept?"
        }
        'FleetFollow' {
            "[ $ts ] (notify) Following Fleet Commander in warp"
        }
        'FleetRegroup' {
            "[ $ts ] (notify) Regrouping to Fleet Commander"
        }
        'FleetDisband' {
            "[ $ts ] (notify) Your fleet is disbanding"
        }
        'JumpCloning' {
            "[ $ts ] (notify) Starting clone jumping"
        }
        'MiningCompression' {
            "[ $ts ] (notify) Successfully compressed Veldspar into 10 Compressed Veldspar"
        }
        'AsteroidDepleted' {
            "[ $ts ] (notify) Your Miner II deactivates as it finds the resource it was harvesting a pale shadow of its former glory."
        }
        'CargoFull' {
            "[ $ts ] (notify) Your Miner II has completed operations. Ship's cargo hold is full."
        }
        'CrystalBroke' {
            "[ $ts ] (notify) Mining Laser Upgrade II deactivates due to the destruction of the Mining Crystal II."
        }
        'WarpScrambled' {
            "[ $ts ] (combat) Warp scramble attempt from Hostile Pilot to you!"
        }
        'WarpDisrupted' {
            "[ $ts ] (combat) Warp disruption attempt from Hostile Pilot to you!"
        }
        'Decloak' {
            "[ $ts ] (notify) Your cloak deactivates due to proximity to Guristas Pith Ship."
        }
        'ObservatoryDecloak' {
            "[ $ts ] (notify) Your cloak deactivates due to a pulse from a Mobile Observatory in the area."
        }
        'CloakFailed' {
            "[ $ts ] (notify) Your cloaking systems are unable to activate due to your ship being within 2000m of a hostile."
        }
        'BombLauncherEmpty' {
            "[ $ts ] (notify) Bomb Launcher II has run out of charges"
        }
        'SelfDestruct' {
            "[ $ts ] (notify) Your Capsule will self-destruct in 5 seconds."
        }
        'WarpBubble' {
            "[ $ts ] (notify) You are within a warp disruption zone. Get 20000.0 meters from Warp Disrupt Probe to warp."
        }
        'Docking' {
            "[ $ts ] (notify) You cannot do that while docking."
        }
        'AutopilotReached' {
            "[ $ts ] (notify) Autopilot disabled - Waypoint reached"
        }
        'AutopilotApproaching' {
            "[ $ts ] (notify) Autopilot approaching target"
        }
        'JumpRange' {
            "[ $ts ] (notify) Please get within 2500 meters of the stargate to jump."
        }
        'AggressionCantJump' {
            "[ $ts ] (notify) The stargate denies you permission to jump for the moment due to your recent acts of aggression."
        }
        'ConduitJump' {
            "[ $ts ] (notify) A Conduit Field jumps you to $Destination."
        }
        'ConversationInvite' {
            "[ $ts ] (None) Some Pilot is inviting you to a conversation"
        }
    }
    if ($line) {
        [System.IO.File]::AppendAllText($Path, $line + "`r`n", [System.Text.Encoding]::UTF8)
    }
    return $line
}

# One-shot NotificationType kinds fireable via Add-GamelogEvent - excludes TakingDamage/MiningIdle/MiningStopped
# (tracker-driven, use the b/m/c bursts or 'x' instead) and SystemChange (fired by the j/r jump commands instead).
# ConduitJump is included here but, like a real conduit, also moves the character - see the 'e' menu handler.
$script:NotificationTypeKinds = @(
    'FleetInvite', 'FleetFollow', 'FleetRegroup', 'FleetDisband',
    'MiningCompression', 'AsteroidDepleted', 'CargoFull', 'CrystalBroke',
    'WarpScrambled', 'WarpDisrupted', 'Decloak', 'ObservatoryDecloak', 'CloakFailed', 'BombLauncherEmpty', 'SelfDestruct', 'WarpBubble',
    'Docking', 'AutopilotReached', 'AutopilotApproaching', 'JumpRange', 'AggressionCantJump', 'ConduitJump', 'JumpCloning',
    'ConversationInvite'
)

function Select-NotificationTypeKind {
    Write-Host ''
    for ($idx = 0; $idx -lt $script:NotificationTypeKinds.Count; $idx++) {
        Write-Host ("{0,2}) {1}" -f ($idx + 1), $script:NotificationTypeKinds[$idx])
    }
    $sel = Read-Host 'Event type number (or name)'
    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $script:NotificationTypeKinds.Count) {
        return $script:NotificationTypeKinds[[int]$sel - 1]
    }
    if ($script:NotificationTypeKinds -contains $sel) { return $sel }
    Write-Warning 'No such event type.'
    return $null
}

# Runs in its own child process via Start-Job, so line-building is duplicated from Add-GamelogEvent rather than shared.
$script:BurstScriptBlock = {
    param($Path, $Kind, $DurationSeconds, $IntervalSeconds)
    $end = (Get-Date).AddSeconds($DurationSeconds)
    while ((Get-Date) -lt $end) {
        $ts = (Get-Date).ToString('yyyy.MM.dd HH:mm:ss')
        $tickKind = if ($Kind -eq 'combatMixed') {
            Get-Random -InputObject @('combatIn', 'combatOut', 'miss')
        } else {
            $Kind
        }
        $line = switch ($tickKind) {
            'bounty' {
                $amount = Get-Random -Minimum 1000 -Maximum 500000
                $formatted = '{0:N0}' -f $amount
                "[ $ts ] (bounty) <font size=12><b><color=0xff00aa00>$formatted ISK</b><color=0x77ffffff> added to next bounty payout (payment adjusted)"
            }
            'mining' {
                $units = Get-Random -Minimum 1 -Maximum 200
                $ore = Get-Random -InputObject @('Veldspar', 'Scordite', 'Pyroxeres', 'Coesite', 'Zeolites')
                "[ $ts ] (mining) You mined $units units of $ore."
            }
            'combatIn' {
                $dmg = Get-Random -Minimum 10 -Maximum 500
                "[ $ts ] (combat) <color=0xffcc0000><b>$dmg</b> <color=0x77ffffff><font size=10>from</font> <b><color=0xffffffff>Gist Seraphim</b><font size=10><color=0x77ffffff> - Heavy Missile - Hits"
            }
            'combatOut' {
                $dmg = Get-Random -Minimum 10 -Maximum 500
                "[ $ts ] (combat) <color=0xff00ffff><b>$dmg</b> <color=0x77ffffff><font size=10>to</font> <b><color=0xffffffff>Gistatis Tribunus</b><font size=10><color=0x77ffffff> - Nova Cruise Missile - Hits"
            }
            'miss' {
                "[ $ts ] (combat) Gist Seraphim misses you completely"
            }
        }
        if ($line) {
            [System.IO.File]::AppendAllText($Path, $line + "`r`n", [System.Text.Encoding]::UTF8)
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}

$script:BurstIntervals = @{
    'bounty'      = 3
    'mining'      = 5
    'combatIn'    = 2
    'combatOut'   = 2
    'miss'        = 2
    'combatMixed' = 2
}

function Start-EventBurst {
    param([string]$Path, [string]$Kind, [int]$DurationSeconds = 60)

    $interval = $script:BurstIntervals[$Kind]
    $job = Start-Job -ScriptBlock $script:BurstScriptBlock -ArgumentList $Path, $Kind, $DurationSeconds, $interval
    return $job
}

$script:EveSystemNames = @(
    'Jita', 'Amarr', 'Dodixie', 'Rens', 'Hek', 'Perimeter', 'Sobaseki', 'Tama',
    'Uedama', 'Old Man Star', 'Ashab', 'Alentene', 'Nourvukaiken', 'Amamake',
    'Rancer', 'Aunia', 'Iyen-Oursta', 'Villore', 'Enaluri', 'Stacmon',
    'Osmon', 'Nagamanen', 'Balle', 'Aset', 'Onnamon'
)

# Same duplication as BurstScriptBlock - runs in its own child process, no access to this script's functions.
$script:JumpScriptBlock = {
    param($GamelogPath, $ChatlogPath, $FromSystem, $Systems, $IntervalSeconds)
    $bomChar = [char]0xFEFF
    $current = $FromSystem
    for ($i = 0; $i -lt $Systems.Count; $i++) {
        $dest = $Systems[$i]
        $ts = (Get-Date).ToString('yyyy.MM.dd HH:mm:ss')
        $gameLine = "[ $ts ] Jumping from $current to $dest`r`n"
        [System.IO.File]::AppendAllText($GamelogPath, $gameLine, [System.Text.Encoding]::UTF8)
        $chatLine = "$bomChar[ $ts ] EVE System > Channel changed to Local : $dest`r`n"
        [System.IO.File]::AppendAllText($ChatlogPath, $chatLine, [System.Text.Encoding]::Unicode)
        $current = $dest
        if ($i -lt $Systems.Count - 1) { Start-Sleep -Seconds $IntervalSeconds }
    }
}

function Start-JumpSequence {
    param([string]$GamelogPath, [string]$ChatlogPath, [string]$FromSystem, [string[]]$Systems, [int]$IntervalSeconds = 10)

    $job = Start-Job -ScriptBlock $script:JumpScriptBlock -ArgumentList $GamelogPath, $ChatlogPath, $FromSystem, $Systems, $IntervalSeconds
    return $job
}

function Add-ChatlogJump {
    param([string]$Path, [string]$System)

    $ts = (Get-Date).ToString('yyyy.MM.dd HH:mm:ss')
    $line = Format-ChatlogLine -Ts $ts -Text "EVE System > Channel changed to Local : $System"
    [System.IO.File]::AppendAllText($Path, $line, [System.Text.Encoding]::Unicode)
    return $line
}

function Add-GamelogJump {
    param([string]$Path, [string]$From, [string]$To)

    $ts = (Get-Date).ToString('yyyy.MM.dd HH:mm:ss')
    $line = "[ $ts ] Jumping from $From to $To`r`n"
    [System.IO.File]::AppendAllText($Path, $line, [System.Text.Encoding]::UTF8)
    return $line
}

$clients = [ordered]@{}

function Start-SimClient {
    param([string]$CharName)

    if ($clients.Contains($CharName)) {
        Write-Warning "$CharName is already running."
        return
    }

    $safeName = ($CharName -replace '[^A-Za-z0-9]', '_')
    $ctrlFile = Join-Path $controlDir "$safeName.ctl"
    Set-Content -Path $ctrlFile -Value 'login' -NoNewline

    $charId = Get-StableCharId -CharName $CharName

    # Resume the character's most recent session if we have one, rather than reverting to the stable file.
    $existingState = Get-CharacterState -CharName $CharName
    if ($existingState) {
        $chatlogPath = $existingState.Chatlog
        $gamelogPath = $existingState.Gamelog
        $startSystem = $existingState.System
    } else {
        $chatlogPath = New-ChatlogFile -CharName $CharName -CharId $charId -Dir $ChatlogDir -Started $StableSessionStart -System 'Jita'
        $gamelogPath = New-GamelogFile -CharName $CharName -CharId $charId -Dir $GamelogDir -Started $StableSessionStart
        $startSystem = 'Jita'
        Save-CharacterState -CharName $CharName -ChatlogPath $chatlogPath -GamelogPath $gamelogPath -System $startSystem
    }

    $script = $agentTemplate.Replace('__CHARNAME__', "'$($CharName.Replace("'", "''"))'").Replace('__CTRLFILE__', "'$($ctrlFile.Replace("'", "''"))'").Replace('__BGIMAGE__', "'$($bgImagePath.Replace("'", "''"))'")
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))

    $proc = Start-Process -FilePath $fakeExePath `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-WindowStyle', $WindowStyle, '-EncodedCommand', $encoded) `
        -WindowStyle $WindowStyle -PassThru

    $clients[$CharName] = [ordered]@{
        Process     = $proc
        ControlFile = $ctrlFile
        CharId      = $charId
        Chatlog     = $chatlogPath
        Gamelog     = $gamelogPath
        System      = $startSystem
        LoggedIn    = $true
        Jobs        = @{}
    }
    Write-Host "Started $CharName (PID $($proc.Id), char id $charId)" -ForegroundColor Green
}

function Stop-CharacterBursts {
    param($Client)
    foreach ($job in $Client.Jobs.Values) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    $Client.Jobs.Clear()
}

function Stop-SimClient {
    param([string]$CharName, [switch]$Kill)

    $c = $clients[$CharName]
    if (-not $c) { Write-Warning "Unknown character: $CharName"; return }

    Stop-CharacterBursts -Client $c

    if ($Kill) {
        Stop-Process -Id $c.Process.Id -Force -ErrorAction SilentlyContinue
    } else {
        Set-Content -Path $c.ControlFile -Value 'exit' -NoNewline
        Start-Sleep -Milliseconds 800
        if (-not $c.Process.HasExited) {
            Stop-Process -Id $c.Process.Id -Force -ErrorAction SilentlyContinue
        }
    }
    $clients.Remove($CharName)
    Write-Host "Stopped $CharName" -ForegroundColor Yellow
}

function Show-Status {
    if ($clients.Count -eq 0) {
        Write-Host '(no simulated clients running)'
        return
    }
    $i = 1
    foreach ($name in $clients.Keys) {
        $c = $clients[$name]
        $alive = -not $c.Process.HasExited
        $state = if (-not $alive) { 'CRASHED/EXITED' } elseif ($c.LoggedIn) { 'logged in' } else { 'logged out' }
        $runningKinds = @($c.Jobs.Keys | Where-Object { ($c.Jobs[$_]).State -eq 'Running' })
        $burstNote = if ($runningKinds.Count -gt 0) { " bursting=$($runningKinds -join ',')" } else { '' }
        Write-Host ("{0}) {1,-20} PID {2,-7} [{3}] system={4}{5}" -f $i, $name, $c.Process.Id, $state, $c.System, $burstNote)
        $i++
    }
}

function Select-Character {
    Show-Status
    if ($clients.Count -eq 0) { return $null }
    $names = @($clients.Keys)
    $sel = Read-Host 'Character number (or name)'
    if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $names.Count) {
        return $names[[int]$sel - 1]
    }
    if ($clients.Contains($sel)) { return $sel }
    Write-Warning 'No such character.'
    return $null
}

# For Travel Mode testing: comma-separated indices/names from Show-Status, or "all".
function Select-MultipleCharacters {
    Show-Status
    if ($clients.Count -eq 0) { return @() }
    $names = @($clients.Keys)
    $sel = Read-Host 'Character numbers or names, comma-separated (or "all")'
    if (-not $sel) { return @() }
    if ($sel.Trim().ToLower() -eq 'all') { return $names }

    $result = @()
    foreach ($token in ($sel -split ',')) {
        $t = $token.Trim()
        if ($t -match '^\d+$' -and [int]$t -ge 1 -and [int]$t -le $names.Count) {
            $result += $names[[int]$t - 1]
        } elseif ($clients.Contains($t)) {
            $result += $t
        } else {
            Write-Warning "No such character: $t"
        }
    }
    return $result
}

function Start-CharacterBurst {
    param([string]$CharName, [string]$Kind, [int]$DurationSeconds = 60)

    $c = $clients[$CharName]
    $existing = $c.Jobs[$Kind]
    if ($existing -and $existing.State -eq 'Running') {
        Write-Warning "$CharName is already bursting '$Kind' - let it finish or wait it out before starting another."
        return
    }
    if ($existing) {
        Remove-Job -Job $existing -Force -ErrorAction SilentlyContinue
    }
    $c.Jobs[$Kind] = Start-EventBurst -Path $c.Gamelog -Kind $Kind -DurationSeconds $DurationSeconds
    Write-Host "$CharName started a ${DurationSeconds}s '$Kind' burst (events every $($script:BurstIntervals[$Kind])s)." -ForegroundColor Green
}

# Fires several distinct NotificationTypes on one character ~1.5s apart (one from each Event Alerts category:
# fleet, mining, combat, navigation, general) so they land inside each other's default 10s display window and
# visibly stack - exercises both the stack itself and the oldest-entry eviction once more than MAX_STACKED_NOTIFICATIONS
# (3, see painter.zig) are active at once. Blocks the menu loop for a few seconds while it runs.
function Start-NotificationStorm {
    param([string]$CharName, [string[]]$Kinds = @('FleetInvite', 'CargoFull', 'Decloak', 'Docking', 'ConversationInvite'))

    $c = $clients[$CharName]
    Write-Host "${CharName}: firing $($Kinds -join ' -> ') 1.5s apart ..." -ForegroundColor Green
    foreach ($kind in $Kinds) {
        Write-Host (Add-GamelogEvent -Path $c.Gamelog -Kind $kind)
        Start-Sleep -Milliseconds 1500
    }
    Write-Host "${CharName}: storm complete." -ForegroundColor Green
}

function Start-CharacterJumpSequence {
    param([string]$CharName)

    $c = $clients[$CharName]
    $existing = $c.Jobs['jump']
    if ($existing -and $existing.State -eq 'Running') {
        Write-Warning "$CharName is already mid jump-sequence - wait for it to finish."
        return
    }
    if ($existing) {
        Remove-Job -Job $existing -Force -ErrorAction SilentlyContinue
    }
    $systems = Get-Random -InputObject $script:EveSystemNames -Count 3
    $c.Jobs['jump'] = Start-JumpSequence -GamelogPath $c.Gamelog -ChatlogPath $c.Chatlog -FromSystem $c.System -Systems $systems
    # Updated immediately since the background job can't reach back into this script's state.
    $c.System = $systems[-1]
    Save-CharacterState -CharName $CharName -ChatlogPath $c.Chatlog -GamelogPath $c.Gamelog -System $c.System
    Write-Host "$CharName jump route: $($systems -join ' -> ') (10s apart)." -ForegroundColor Green
}

# Jumps everyone but $StragglerName to one new system, for testing Travel Mode's left-behind alert.
function Start-TravelModeTest {
    param([string[]]$CharNames, [string]$StragglerName)

    $straggler = $clients[$StragglerName]
    $dest = Get-Random -InputObject ($script:EveSystemNames | Where-Object { $_ -ne $straggler.System })

    $movers = @()
    foreach ($name in $CharNames) {
        if ($name -eq $StragglerName) { continue }
        $c = $clients[$name]
        Add-GamelogJump -Path $c.Gamelog -From $c.System -To $dest | Out-Null
        Add-ChatlogJump -Path $c.Chatlog -System $dest | Out-Null
        $c.System = $dest
        Save-CharacterState -CharName $name -ChatlogPath $c.Chatlog -GamelogPath $c.Gamelog -System $c.System
        $movers += $name
    }

    Write-Host "Jumped $($movers -join ', ') to $dest." -ForegroundColor Green
    Write-Host "$StragglerName stayed behind in $($straggler.System)." -ForegroundColor Yellow
    Write-Host "Wait for Travel Mode's Catch-Up Window to elapse, then check $StragglerName's thumbnail for the Left Behind notification." -ForegroundColor DarkYellow
    Write-Host "Then use 'j' to jump $StragglerName to $dest and confirm the alert clears." -ForegroundColor DarkYellow
}

Write-Host ''
Write-Host '=== EVE-Zig Preview client simulator ===' -ForegroundColor Cyan
Write-Host "Chatlog dir: $ChatlogDir"
Write-Host "Gamelog dir: $GamelogDir"
if ($ChatlogDir -like "*\Documents\EVE\logs\Chatlogs" -or $GamelogDir -like "*\Documents\EVE\logs\Gamelogs") {
    Write-Host 'These are the app''s default log directories, so no settings change is needed - fixtures land alongside your real EVE logs.' -ForegroundColor DarkYellow
    Write-Host 'Fixture files are named after their (fake) character, e.g. Local_*_1234567890.txt - safe to delete anytime; nothing here overwrites real EVE files.' -ForegroundColor DarkYellow
} else {
    Write-Host 'Point the app''s Settings > Chatlog/Gamelog directory fields at the paths above to watch these fixtures.'
}
Write-Host ''

$menu = @'

  [s] status                 [n] start new character   [o] log OUT (title -> "EVE")
  [i] log back IN            [k] kill (crash) client    [b] bounty burst (60s)
  [m] mining burst (60s)     [c] combat burst (60s)     [j] jump to system
  [r] random 3-system route  [e] fire event type...     [x] notification storm (multi-alert test)
  [t] travel mode test (group jump, leave one behind)
  [q] quit (stops everyone)
'@

# try/finally makes cleanup Ctrl+C-safe: Ctrl+C raises a pipeline-stop that unwinds through finally.
try {
    foreach ($name in $CharacterNames) { Start-SimClient -CharName $name }

:mainLoop while ($true) {
    Write-Host $menu -ForegroundColor DarkGray
    $cmd = Read-Host 'Command'
    switch ($cmd) {
        's' { Show-Status }
        'n' {
            $name = Read-Host 'New character name'
            if ($name) { Start-SimClient -CharName $name }
        }
        'o' {
            $name = Select-Character
            if ($name) {
                Set-Content -Path $clients[$name].ControlFile -Value 'logout' -NoNewline
                $clients[$name].LoggedIn = $false
                Write-Host "$name is now logged out (title -> `"EVE`")"
            }
        }
        'i' {
            $name = Select-Character
            if ($name) {
                $c = $clients[$name]
                Set-Content -Path $c.ControlFile -Value 'login' -NoNewline
                $c.LoggedIn = $true
                # Real EVE starts a fresh Chatlog/Gamelog file per login session; mirror that here.
                $now = Get-Date
                $c.Chatlog = New-ChatlogFile -CharName $name -CharId $c.CharId -Dir $ChatlogDir -Started $now -System $c.System
                $c.Gamelog = New-GamelogFile -CharName $name -CharId $c.CharId -Dir $GamelogDir -Started $now
                Save-CharacterState -CharName $name -ChatlogPath $c.Chatlog -GamelogPath $c.Gamelog -System $c.System
                Write-Host "$name is now logged in (new session log files created)"
            }
        }
        'k' {
            $name = Select-Character
            if ($name) { Stop-SimClient -CharName $name -Kill }
        }
        'b' {
            $name = Select-Character
            if ($name) { Start-CharacterBurst -CharName $name -Kind 'bounty' }
        }
        'm' {
            $name = Select-Character
            if ($name) { Start-CharacterBurst -CharName $name -Kind 'mining' }
        }
        'c' {
            $name = Select-Character
            if ($name) {
                $dir = Read-Host 'Direction: (i)ncoming, (o)utgoing, (m)iss, (x) mixed fight'
                $kind = switch ($dir) { 'i' { 'combatIn' } 'o' { 'combatOut' } 'm' { 'miss' } default { 'combatMixed' } }
                Start-CharacterBurst -CharName $name -Kind $kind
            }
        }
        'j' {
            $name = Select-Character
            if ($name) {
                $newSystem = Read-Host 'Jump to system'
                if ($newSystem) {
                    $c = $clients[$name]
                    Add-GamelogJump -Path $c.Gamelog -From $c.System -To $newSystem | Write-Host
                    Add-ChatlogJump -Path $c.Chatlog -System $newSystem | Out-Null
                    $c.System = $newSystem
                    Save-CharacterState -CharName $name -ChatlogPath $c.Chatlog -GamelogPath $c.Gamelog -System $c.System
                }
            }
        }
        'r' {
            $name = Select-Character
            if ($name) { Start-CharacterJumpSequence -CharName $name }
        }
        'e' {
            $name = Select-Character
            if ($name) {
                $kind = Select-NotificationTypeKind
                if ($kind -eq 'ConduitJump') {
                    $c = $clients[$name]
                    $dest = Get-Random -InputObject ($script:EveSystemNames | Where-Object { $_ -ne $c.System })
                    Write-Host (Add-GamelogEvent -Path $c.Gamelog -Kind $kind -Destination $dest)
                    Add-ChatlogJump -Path $c.Chatlog -System $dest | Out-Null
                    $c.System = $dest
                    Save-CharacterState -CharName $name -ChatlogPath $c.Chatlog -GamelogPath $c.Gamelog -System $c.System
                    Write-Host "$name conduit-jumped to $dest." -ForegroundColor Green
                } elseif ($kind) {
                    Write-Host (Add-GamelogEvent -Path $clients[$name].Gamelog -Kind $kind)
                }
            }
        }
        'x' {
            $name = Select-Character
            if ($name) { Start-NotificationStorm -CharName $name }
        }
        't' {
            $group = Select-MultipleCharacters
            if ($group.Count -lt 2) {
                Write-Warning 'Travel Mode test needs at least 2 characters.'
            } else {
                Write-Host ''
                for ($idx = 0; $idx -lt $group.Count; $idx++) {
                    Write-Host ("{0,2}) {1}" -f ($idx + 1), $group[$idx])
                }
                $stragglerSel = Read-Host 'Which one gets left behind? (number or name)'
                $straggler = $null
                if ($stragglerSel -match '^\d+$' -and [int]$stragglerSel -ge 1 -and [int]$stragglerSel -le $group.Count) {
                    $straggler = $group[[int]$stragglerSel - 1]
                } elseif ($group -contains $stragglerSel) {
                    $straggler = $stragglerSel
                }
                if (-not $straggler) {
                    Write-Warning 'No such character in the group.'
                } else {
                    Start-TravelModeTest -CharNames $group -StragglerName $straggler
                }
            }
        }
        'q' {
            break mainLoop
        }
        default { Write-Warning 'Unknown command.' }
    }
}
} finally {
    foreach ($name in @($clients.Keys)) { Stop-SimClient -CharName $name }
    # Safety net for any stray job Stop-SimClient didn't catch.
    Get-Job -ErrorAction SilentlyContinue | Stop-Job -ErrorAction SilentlyContinue
    Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
    Write-Host 'All simulated clients stopped.' -ForegroundColor Cyan
}
