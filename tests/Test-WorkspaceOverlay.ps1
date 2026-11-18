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
# Delay the real GUI Show call and queue a competing update at that exact point.
# All windows belong to this harness; no user input, windows or saved state change.
$functions = $functions.Replace('overlay.Show(', 'TestOverlayShow(overlay, ')
$harness = $globals + @'

WorkspaceStatePersistenceEnabled := false
DEBUG_LOG_PATH := A_ScriptDir "\overlay.log"
DEBUG_PREVIOUS_LOG_PATH := A_ScriptDir "\previous.log"
DetectHiddenWindows true
Thread("Interrupt", 0)
global InjectOverlayUpdate := false
SetTimer((*) => ExitApp(2), -10000)
try {
    RunOverlayTests()
    FileAppend("Overlay tests passed: overlapping updates, stale timers, expiry, workspace mismatch, reset cleanup.`n", "*")
    ExitApp(0)
} catch as caughtError {
    FileAppend("FAIL: " caughtError.Message " at line " caughtError.Line "`n", "*")
    ExitApp(1)
}

TestOverlayShow(overlay, options) {
    global InjectOverlayUpdate
    overlay.Show(options)
    if InjectOverlayUpdate {
        InjectOverlayUpdate := false
        SetTimer((*) => ShowWorkspaceOverlay(MonitorGetPrimary(), 2), -1)
        Sleep(250)
    }
}

RunOverlayTests() {
    global CurrentWorkspace, WorkspaceOverlays, InjectOverlayUpdate, INDICATOR_MS
    monitor := MonitorGetPrimary()
    CurrentWorkspace[monitor] := 2
    InjectOverlayUpdate := true
    ShowWorkspaceOverlay(monitor, 3)
    Sleep(120)
    visible := 0
    for hwnd in WinGetList("ahk_class AutoHotkeyGUI ahk_pid " DllCall("GetCurrentProcessId"))
        visible += IsVisible(hwnd) ? 1 : 0
    AssertOverlay(visible = 1, "overlapping updates left " visible " visible indicators")
    AssertOverlay(WorkspaceOverlays[monitor].workspace = 2, "latest label wins")
    old := WorkspaceOverlays[monitor]
    oldDismiss := old.dismissTimer
    ShowWorkspaceOverlay(monitor, 1)
    replacement := WorkspaceOverlays[monitor]
    oldDismiss.Call()
    AssertOverlay(WorkspaceOverlays.Has(monitor) && IsVisible(replacement.hwnd),
        "stale dismissal must not remove the replacement")
    CancelWorkspaceOverlay(monitor)
    ShowWorkspaceOverlay(monitor, 2)
    expired := WorkspaceOverlays[monitor]
    Sleep(INDICATOR_MS + 100)
    AssertOverlay(!WorkspaceOverlays.Has(monitor) && !DllCall("IsWindow", "ptr", expired.hwnd),
        "timer destroys the native indicator")
    ShowWorkspaceOverlay(monitor, 2)
    expired := WorkspaceOverlays[monitor]
    SetTimer(expired.dismissTimer, 0)
    expired.expiresAt := A_TickCount - 1
    CheckWorkspaceEngineHealth()
    AssertOverlay(!WorkspaceOverlays.Has(monitor) && !IsVisible(expired.hwnd),
        "watchdog removes indicator if dismissal is missed")
    ShowWorkspaceOverlay(monitor, 3)
    CheckWorkspaceEngineHealth()
    AssertOverlay(!WorkspaceOverlays.Has(monitor), "watchdog removes wrong-workspace label")
    ShowWorkspaceOverlay(monitor, 2)
    if MonitorGetCount() > 1
        ShowWorkspaceOverlay(monitor = 1 ? 2 : 1, 1)
    ClearWorkspaceOverlays()
    AssertOverlay(WorkspaceOverlays.Count = 0, "reset removes all monitor indicators")
    for hwnd in WinGetList("ahk_class AutoHotkeyGUI ahk_pid " DllCall("GetCurrentProcessId"))
        AssertOverlay(!IsVisible(hwnd), "no orphan indicators survive cleanup")
    AssertOverlay(!A_IsCritical, "critical setting restored")
}
AssertOverlay(condition, message) {
    if !condition
        throw Error(message)
}
'@ + $functions
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('IMW-overlay-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $testScript = Join-Path $testRoot 'overlay-tests.ahk'
    [IO.File]::WriteAllText($testScript, $harness, [Text.UTF8Encoding]::new($true))
    $process = Start-Process -FilePath $AutoHotkeyPath -WindowStyle Hidden -PassThru `
        -ArgumentList @('/ErrorStdOut', ('"' + $testScript + '"')) `
        -RedirectStandardOutput (Join-Path $testRoot 'stdout.txt') `
        -RedirectStandardError (Join-Path $testRoot 'stderr.txt')
    # Windows PowerShell 5.1 reports no exit code unless the handle is opened
    # while the process is still running.
    $null = $process.Handle
    if (-not $process.WaitForExit(15000)) {
        $process.Kill()
        throw 'Overlay tests timed out.'
    }
    Get-Content -LiteralPath (Join-Path $testRoot 'stdout.txt'), (Join-Path $testRoot 'stderr.txt')
    if ($process.ExitCode -ne 0) { throw "Overlay tests failed: $($process.ExitCode)" }
} finally {
    Get-ChildItem -LiteralPath $testRoot -File | Remove-Item -Force
    Remove-Item -LiteralPath $testRoot
}
