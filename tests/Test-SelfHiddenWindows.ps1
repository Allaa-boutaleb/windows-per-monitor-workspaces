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
# Save and reload real state for windows this harness owns, the way an engine
# restart does. Tray apps and popups hide their own windows; a restart must not
# pop those up or treat them as hidden by the engine. No user windows, input,
# or saved user state are touched.
$harness = $globals + @'

WORKSPACE_STATE_PATH := A_ScriptDir "\workspace-state.tsv"
DEBUG_LOG_PATH := A_ScriptDir "\self-hidden.log"
DEBUG_PREVIOUS_LOG_PATH := A_ScriptDir "\previous.log"
DetectHiddenWindows true
SetWinDelay -1
try {
    TestSelfHiddenWindows()
    FileAppend("Self-hidden window tests passed (save flags, restart, legacy state, release after visit, reopen in place).`n", "*")
    ExitApp(0)
} catch as caughtError {
    FileAppend("FAIL: " caughtError.Message " at line " caughtError.Line "`n", "*")
    ExitApp(1)
}

TestSelfHiddenWindows() {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript, WorkspaceWindowOrders
    global WORKSPACE_STATE_PATH
    InitializeMonitors()
    monitor := MonitorGetPrimary()
    ; Ordinary app windows: the engine leaves tool windows to their app.
    shown := Gui("-Caption -DPIScale")
    trayApp := Gui("-Caption -DPIScale")
    parked := Gui("-Caption -DPIScale")
    popup := Gui("-Caption -DPIScale")
    legacy := Gui("-Caption -DPIScale")
    try {
        shown.Show("NA x40 y40 w160 h120")
        CurrentWorkspace[monitor] := 1
        WindowWorkspace[shown.Hwnd] := {monitor: monitor, workspace: 1}
        WindowWorkspace[trayApp.Hwnd] := {monitor: monitor, workspace: 1}
        WindowWorkspace[parked.Hwnd] := {monitor: monitor, workspace: 2}
        WindowWorkspace[popup.Hwnd] := {monitor: monitor, workspace: 2}
        HiddenByScript[parked.Hwnd] := true
        SaveWorkspaceState()
        flags := SavedShownFlags()
        ; Older versions wrote no flag, so their state keeps showing the window.
        FileAppend("W`t" legacy.Hwnd "`t" DllCall("GetCurrentProcessId") "`t"
            MonitorGetName(monitor) "`t1`n", WORKSPACE_STATE_PATH, "UTF-8")

        WindowWorkspace.Clear()
        HiddenByScript.Clear()
        WorkspaceWindowOrders.Clear()
        InitializeMonitors()
        LoadWorkspaceState()
        ApplyRestoredWorkspaceVisibility()
        Sleep(100)
        AssertSelfHidden(!IsVisible(trayApp.Hwnd), "restart popped up a window its app had hidden")
        AssertSelfHidden(!HiddenByScript.Has(popup.Hwnd),
            "restart claimed an app-hidden window on another workspace")
        AssertSelfHidden(WindowWorkspace.Has(trayApp.Hwnd) && WindowWorkspace.Has(popup.Hwnd),
            "app-hidden windows keep their workspace")
        AssertSelfHidden(HiddenByScript.Has(parked.Hwnd) && !IsVisible(parked.Hwnd),
            "a script-hidden window stays hidden for its workspace")
        AssertSelfHidden(IsVisible(shown.Hwnd) && IsVisible(legacy.Hwnd),
            "visible and legacy-state windows are shown")
        AssertSelfHidden(flags.Has(shown.Hwnd) && flags[shown.Hwnd] = "1"
            && flags[parked.Hwnd] = "1", "visible and script-hidden windows are saved as shown")
        AssertSelfHidden(flags[trayApp.Hwnd] = "0" && flags[popup.Hwnd] = "0",
            "app-hidden windows are saved as self-hidden")

        ; Visit D2 after the handoff: parked appeared, but popup's app kept it
        ; hidden. Older state marked it script-hidden, so it was re-shown and
        ; waited on during every visit.
        CurrentWorkspace[monitor] := 2
        parked.Show("NA x220 y40 w160 h120")
        HiddenByScript.Delete(parked.Hwnd)
        HiddenByScript[popup.Hwnd] := true
        VerifyWorkspaceTransition(monitor, 2, 2)
        AssertSelfHidden(HiddenByScript.Has(popup.Hwnd), "release waits for the final check")
        VerifyWorkspaceTransition(monitor, 2, 3)
        AssertSelfHidden(!HiddenByScript.Has(popup.Hwnd) && !IsVisible(popup.Hwnd),
            "an app-hidden window is released after a visit")
        AssertSelfHidden(IsVisible(parked.Hwnd), "shown windows are unaffected")

        ; Back on D1, popup's app opens it again, as Telegram reuses one hidden
        ; media viewer. It opens on D1 instead of switching the monitor to D2.
        CurrentWorkspace[monitor] := 1
        popup.Show("x400 y40 w160 h120")
        AssertSelfHidden(QueueExternalWorkspaceActivation(popup.Hwnd, "test"),
            "the reopened window's activation is handled")
        ProcessPendingExternalActivations()
        AssertSelfHidden(CurrentWorkspace[monitor] = 1,
            "an app reopening its own hidden window switched the monitor")
        AssertSelfHidden(WindowWorkspace[popup.Hwnd].workspace = 1 && IsVisible(popup.Hwnd),
            "a reopened window joins the current workspace")
    } finally {
        for fixture in [shown, trayApp, parked, popup, legacy]
            fixture.Destroy()
    }
}
SavedShownFlags() {
    global WORKSPACE_STATE_PATH
    flags := Map()
    for line in StrSplit(FileRead(WORKSPACE_STATE_PATH, "UTF-8"), "`n", "`r") {
        fields := StrSplit(line, "`t")
        if fields.Length >= 5 && fields[1] = "W"
            flags[Integer(fields[2])] := fields.Length >= 6 ? fields[6] : ""
    }
    return flags
}
AssertSelfHidden(condition, message) {
    if !condition
        throw Error(message)
}
'@ + $functions
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('IMW-self-hidden-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $testScript = Join-Path $testRoot 'self-hidden-tests.ahk'
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
        throw 'Self-hidden window tests timed out.'
    }
    Get-Content -LiteralPath (Join-Path $testRoot 'stdout.txt'), (Join-Path $testRoot 'stderr.txt')
    if ($process.ExitCode -ne 0) {
        Get-Content -LiteralPath (Join-Path $testRoot 'self-hidden.log') -Tail 12 -ErrorAction SilentlyContinue
        throw "Self-hidden window tests failed: $($process.ExitCode)"
    }
} finally {
    Get-ChildItem -LiteralPath $testRoot -File | Remove-Item -Force
    Remove-Item -LiteralPath $testRoot
}
