#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$AutoHotkeyPath = "$env:LOCALAPPDATA\IndependentMonitorWorkspaces\runtime\AutoHotkey.exe",
    [string]$SourceScriptPath
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 has no $PSScriptRoot while binding parameter defaults.
if (-not $SourceScriptPath) {
    $SourceScriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'IndependentMonitorWorkspaces.ahk'
}
$source = Get-Content -LiteralPath $SourceScriptPath -Raw
$globals = $source.Substring(0, $source.IndexOf('DetectHiddenWindows true'))
$functions = $source.Substring($source.IndexOf("`nInitializeMonitors() {"))
# A separate fixture process owns one visible and one hidden window, then stops
# pumping messages like a hung app. Real switches run across them. Only owned
# fixture windows are touched; no user windows, input, or saved state change.
$fixture = @'
#Requires AutoHotkey v2.0
#NoTrayIcon
shown := Gui("-Caption +ToolWindow", "IMW hung fixture")
shown.BackColor := "CC2222"
hidden := Gui("-Caption +ToolWindow", "IMW hidden hung fixture")
shown.Show("NA x120 y120 w360 h240")
FileAppend(shown.Hwnd "`t" hidden.Hwnd, A_Args[1], "UTF-8")
DllCall("Sleep", "uint", 60000)
ExitApp
'@
$harness = $globals + @'

WorkspaceStatePersistenceEnabled := false
OverviewPreviewMode := true
DEBUG_LOG_PATH := A_ScriptDir "\hung.log"
DEBUG_PREVIOUS_LOG_PATH := A_ScriptDir "\previous.log"
DetectHiddenWindows true
SetWinDelay -1
OnMessage(0x000F, PaintWorkspaceOverview)
OnMessage(0x0014, HandleWorkspaceSlideEraseBackground)
; The engine records the monitor layout at startup.
SetMonitorTopology(ReadMonitorTopology())
try {
    TestHungWindowSwitch()
    FileAppend("Hung window tests passed (switch away and back, snapshots, stack restore, raise, verify).`n", "*")
    ExitApp(0)
} catch as caughtError {
    FileAppend("FAIL: " caughtError.Message " at line " caughtError.Line "`n", "*")
    ExitApp(1)
}

TestHungWindowSwitch() {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript, WindowSnapshots
    fields := StrSplit(FileRead(A_Args[1], "UTF-8"), "`t")
    hungShown := Integer(fields[1])
    hungHidden := Integer(fields[2])
    monitor := MonitorGetPrimary()
    MonitorGetWorkArea(monitor, &left, &top)
    incoming := Gui("-Caption +ToolWindow -DPIScale")
    incoming.BackColor := "22CC44"
    try {
        AssertHung(IsVisible(hungShown) && !IsVisible(hungHidden), "fixture visibility")
        AssertHung(!IsWindowResponsive(hungShown) && !IsWindowResponsive(hungHidden),
            "fixture app is detected as unresponsive")
        AssertHung(IsWindowResponsive(incoming.Hwnd), "this thread's windows are responsive")
        incoming.Show("NA x" (left + 200) " y" (top + 160) " w360 h240")
        DllCall("UpdateWindow", "ptr", incoming.Hwnd)
        DllCall("dwmapi\DwmFlush")
        AssertHung(CaptureWindowSnapshot(incoming.Hwnd), "responsive window snapshot")
        incoming.Hide()

        CurrentWorkspace[monitor] := 1
        WindowWorkspace[hungShown] := {monitor: monitor, workspace: 1}
        WindowWorkspace[hungHidden] := {monitor: monitor, workspace: 1}
        WindowWorkspace[incoming.Hwnd] := {monitor: monitor, workspace: 2}
        HiddenByScript[incoming.Hwnd] := true

        started := A_TickCount
        AssertHung(SwitchToWorkspaceOnMonitor(2, monitor, 1), "switch away from a hung app")
        AssertHung(CurrentWorkspace[monitor] = 2 && IsVisible(incoming.Hwnd), "D2 is shown")
        AssertHung(WindowSnapshots.Has(hungShown), "hung window is captured from the screen")
        AssertHung(!WindowSnapshots.Has(hungHidden), "hidden hung window is not captured")
        AssertHung(SwitchToWorkspaceOnMonitor(1, monitor, -1), "switch back to a hung app")
        AssertHung(CurrentWorkspace[monitor] = 1 && !IsVisible(incoming.Hwnd), "D1 is shown")
        AssertHung(!CaptureWindowSnapshot(hungHidden), "no snapshot for a hidden hung window")
        RaiseWorkspacePriorityWindow(hungShown)
        HiddenByScript[hungHidden] := true
        VerifyWorkspaceTransition(monitor, 1, 3)
        AssertHung(HiddenByScript.Has(hungHidden),
            "a hung app's pending show is not mistaken for a self-hidden window")
        elapsed := A_TickCount - started
        AssertHung(elapsed < 5000, "hung app delayed the engine by " elapsed " ms")
    } finally {
        incoming.Destroy()
        CancelWorkspaceOverlay(monitor)
        ClearWindowSnapshots()
        ClearWorkspaceFrames()
    }
}
AssertHung(condition, message) {
    if !condition
        throw Error(message)
}
'@ + $functions
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('IMW-hung-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$fixtureProcess = $null
try {
    $fixtureScript = Join-Path $testRoot 'hung-fixture.ahk'
    $handles = Join-Path $testRoot 'handles.txt'
    [IO.File]::WriteAllText($fixtureScript, $fixture, [Text.UTF8Encoding]::new($true))
    $fixtureProcess = Start-Process -FilePath $AutoHotkeyPath -PassThru `
        -ArgumentList @('/ErrorStdOut', ('"' + $fixtureScript + '"'), ('"' + $handles + '"'))
    $deadline = (Get-Date).AddSeconds(10)
    while (-not (Test-Path -LiteralPath $handles) -or -not (Get-Content -LiteralPath $handles -Raw)) {
        if ((Get-Date) -gt $deadline) { throw 'Hung fixture did not start.' }
        Start-Sleep -Milliseconds 50
    }

    $testScript = Join-Path $testRoot 'hung-tests.ahk'
    [IO.File]::WriteAllText($testScript, $harness, [Text.UTF8Encoding]::new($true))
    $process = Start-Process -FilePath $AutoHotkeyPath -WindowStyle Hidden -PassThru `
        -ArgumentList @('/ErrorStdOut', ('"' + $testScript + '"'), ('"' + $handles + '"')) `
        -RedirectStandardOutput (Join-Path $testRoot 'stdout.txt') `
        -RedirectStandardError (Join-Path $testRoot 'stderr.txt')
    # Windows PowerShell 5.1 reports no exit code unless the handle is opened
    # while the process is still running.
    $null = $process.Handle
    if (-not $process.WaitForExit(20000)) {
        $process.Kill()
        Get-Content -LiteralPath (Join-Path $testRoot 'hung.log') -Tail 6 -ErrorAction SilentlyContinue
        throw 'Hung window tests timed out: a hung app froze the workspace engine.'
    }
    Get-Content -LiteralPath (Join-Path $testRoot 'stdout.txt'), (Join-Path $testRoot 'stderr.txt')
    if ($process.ExitCode -ne 0) {
        Get-Content -LiteralPath (Join-Path $testRoot 'hung.log') -Tail 12 -ErrorAction SilentlyContinue
        throw "Hung window tests failed: $($process.ExitCode)"
    }
} finally {
    if ($fixtureProcess -and -not $fixtureProcess.HasExited) { $fixtureProcess.Kill() }
    if ($fixtureProcess) { $fixtureProcess.WaitForExit(5000) | Out-Null }
    Get-ChildItem -LiteralPath $testRoot -File | Remove-Item -Force
    Remove-Item -LiteralPath $testRoot
}
