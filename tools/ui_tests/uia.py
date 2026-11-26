"""UI Automation for the config dialog, through one PowerShell process, since the guest's Python has no COM bindings.

The dialog publishes its controls through knots' AccessKit tree: each named for its row's label (see
src/dialog/knots/widgets.zig's nameControl), switches as CheckBoxes, buttons with Invoke.
"""

import json
import subprocess

# Reads one JSON command a line and answers with one JSON line; commands find their elements afresh, as frames rebuild them.
BRIDGE_SCRIPT = r"""
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$A = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]::Descendants
$root = $null

function Controls($type) {
    $condition = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::$type)
    return @($root.FindAll($Scope, $condition))
}

function Describe($element, $position) {
    $current = $element.Current
    $info = @{ position = $position; name = $current.Name; type = $current.ControlType.ProgrammaticName.Replace('ControlType.', ''); enabled = $current.IsEnabled }
    $pattern = $null
    if ($element.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) { $info.toggled = $pattern.Current.ToggleState.ToString() -eq 'On' }
    if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) { $info.value = $pattern.Current.Value }
    return $info
}

function Answer($result) {
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $result -Compress -Depth 4))
    [Console]::Out.Flush()
}

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    try {
        $command = ConvertFrom-Json $line
        switch ($command.op) {
            'attach' { $root = $A::FromHandle([IntPtr][long]$command.hwnd); Answer @{ ok = $true } }
            'list' {
                $items = @()
                $controls = Controls $command.type
                for ($i = 0; $i -lt $controls.Count; $i++) { $items += Describe $controls[$i] $i }
                Answer @{ ok = $true; items = @($items) }
            }
            'toggle' {
                $controls = Controls 'CheckBox'
                if ($command.position -ge $controls.Count) { throw "no checkbox at $($command.position) of $($controls.Count)" }
                $controls[$command.position].GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
                Answer @{ ok = $true }
            }
            'invoke' {
                $button = @(Controls 'Button' | Where-Object { $_.Current.Name -eq $command.name })
                if ($button.Count -eq 0) { throw "no button named '$($command.name)'" }
                $button[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                Answer @{ ok = $true }
            }
            default { throw "unknown op '$($command.op)'" }
        }
    } catch {
        Answer @{ ok = $false; error = $_.Exception.Message }
    }
}
"""


class UiaError(RuntimeError):
    pass


class Dialog:
    """The config dialog window `hwnd`, driven by name; close() ends the PowerShell process."""

    def __init__(self, hwnd: int):
        self.process = subprocess.Popen(["powershell", "-NoProfile", "-NonInteractive", "-Command", BRIDGE_SCRIPT],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, encoding="utf-8")
        self._send({"op": "attach", "hwnd": hwnd})

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            self.process.wait(timeout=10)

    def controls(self, control_type: str) -> list[dict]:
        """Each control of a UI Automation type (e.g. "CheckBox"), in tree order: position, name, type, enabled, and toggled or value."""
        return self._send({"op": "list", "type": control_type})["items"]

    def toggle(self, position: int):
        """The checkbox at `position` in controls("CheckBox")."""
        self._send({"op": "toggle", "position": position})

    def invoke(self, name: str):
        """The first button named `name`, e.g. a tab in the sidebar, or Save."""
        self._send({"op": "invoke", "name": name})

    def _send(self, command: dict) -> dict:
        self.process.stdin.write(json.dumps(command) + "\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise UiaError(f"The UI Automation bridge ended during {command['op']}")
        answer = json.loads(line)
        if not answer.get("ok"):
            raise UiaError(f"{command['op']} failed: {answer.get('error')}")
        return answer
