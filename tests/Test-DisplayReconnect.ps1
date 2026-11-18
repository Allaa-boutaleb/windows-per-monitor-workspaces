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
# A monitor that disconnects, as one switched to a console's input does, and
# comes back. The layouts are synthetic and placed far off screen, so the
# harness windows never appear on the user's displays. No user windows,
# input, or saved user state are touched.
$harness = $globals + @'

WORKSPACE_STATE_PATH := A_ScriptDir "\workspace-state.tsv"
DEBUG_LOG_PATH := A_ScriptDir "\display-reconnect.log"
DEBUG_PREVIOUS_LOG_PATH := A_ScriptDir "\previous.log"
DetectHiddenWindows true
SetWinDelay -1
try {
    TestDisplayReconnect()
    FileAppend("Display reconnect tests passed (disconnect, restart while away, return, renumbering, moved monitor, closed window, scan freeze).`n", "*")
    ExitApp(0)
} catch as caughtError {
    FileAppend("FAIL: " caughtError.Message " at line " caughtError.Line "`n", "*")
    ExitApp(1)
}

TestDisplayReconnect() {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript, WorkspaceWindowOrders
    global MonitorTopology, WindowPlacements, DisplacedWindows, DisplacedMonitors
    global DisplacedWindowOrders, DisplayTopologyPending, WORKSPACE_STATE_PATH
    left := TestMonitor("\\.\IMWTEST1", 20000, 0, 21000, 800)
    right := TestMonitor("\\.\IMWTEST2", 21000, 0, 22600, 900)
    ; Ordinary app windows: the engine leaves tool windows to their app.
    shown := Gui("+Resize -DPIScale")
    parked := Gui("+Resize -DPIScale")
    stay := Gui("+Resize -DPIScale")
    closer := Gui("+Resize -DPIScale")
    try {
        shown.Show("NA x21100 y100 w400 h300")
        parked.Show("Hide x21200 y150 w400 h300")
        stay.Show("NA x20100 y100 w300 h200")
        closer.Show("Hide x21300 y200 w300 h200")
        shownHome := GetWindowRectObject(shown.Hwnd)
        parkedHome := GetWindowRectObject(parked.Hwnd)
        stayHome := GetWindowRectObject(stay.Hwnd)
        AssertDisplay(shownHome.left = 21100 && stayHome.left = 20100,
            "fixtures open where they were placed")

        SetMonitorTopology([left, right])
        CurrentWorkspace.Clear()
        CurrentWorkspace[1] := 1
        CurrentWorkspace[2] := 2
        WindowWorkspace[shown.Hwnd] := {monitor: 2, workspace: 2}
        WindowWorkspace[parked.Hwnd] := {monitor: 2, workspace: 1}
        WindowWorkspace[closer.Hwnd] := {monitor: 2, workspace: 3}
        WindowWorkspace[stay.Hwnd] := {monitor: 1, workspace: 1}
        HiddenByScript[parked.Hwnd] := true
        HiddenByScript[closer.Hwnd] := true
        WorkspaceWindowOrders["2:2"] := [shown.Hwnd]
        WorkspaceWindowOrders["2:1"] := [parked.Hwnd]
        WorkspaceWindowOrders["1:1"] := [stay.Hwnd]
        WindowPlacements := RecordWindowPlacements()
        AssertDisplay(WindowPlacements[shown.Hwnd].device = "\\.\imwtest2"
            && WindowPlacements[parked.Hwnd].device = "\\.\imwtest2"
            && WindowPlacements[stay.Hwnd].device = "\\.\imwtest1",
            "placements record each window's monitor")

        ; The right monitor switches to a console. Windows moves its visible
        ; window onto the left monitor; hidden ones stay where they were.
        MoveTestWindow(shown, 20150, 150)
        ReconcileDisplayTopology([left], "test-disconnect")
        AssertDisplay(!DisplayTopologyPending && MonitorTopology.Length = 1,
            "the reconcile commits the new layout")
        AssertDisplay(CurrentWorkspace.Count = 1 && CurrentWorkspace[1] = 1,
            "the remaining monitor keeps its workspace")
        AssertSlot(shown, 1, 1, "a moved window joins the workspace shown where it landed")
        AssertSlot(stay, 1, 1, "a window on the remaining monitor keeps its slot")
        AssertDisplay(!WindowWorkspace.Has(parked.Hwnd) && HiddenByScript.Has(parked.Hwnd)
            && !IsVisible(parked.Hwnd), "a hidden window waits, still hidden")
        AssertDisplay(DisplacedWindows.Has(shown.Hwnd)
            && DisplacedWindows[shown.Hwnd].workspace = 2
            && DisplacedWindows[parked.Hwnd].workspace = 1
            && DisplacedWindows[parked.Hwnd].device = "\\.\imwtest2",
            "both windows remember their monitor and workspace")
        AssertDisplay(DisplacedMonitors.Has("\\.\imwtest2")
            && DisplacedMonitors["\\.\imwtest2"].workspace = 2,
            "the disconnected monitor's workspace is remembered")
        AssertDisplay(DisplacedWindowOrders.Has("\\.\imwtest2|2")
            && WorkspaceWindowOrders.Has("1:1") && !WorkspaceWindowOrders.Has("2:2"),
            "workspace stacks follow their monitor")

        ; A waiting window that closes is forgotten.
        closerHwnd := closer.Hwnd
        closer.Destroy()
        RefreshClosedAppWorkspaces()
        AssertDisplay(!DisplacedWindows.Has(closerHwnd) && !HiddenByScript.Has(closerHwnd),
            "a closed waiting window is dropped")

        ; The engine restarts while the monitor is away. The old engine
        ; revealed every hidden window as it stopped.
        SaveWorkspaceState()
        saved := FileRead(WORKSPACE_STATE_PATH, "UTF-8")
        AssertDisplay(InStr(saved, "H`t" parked.Hwnd "`t") && InStr(saved, "H`t" shown.Hwnd "`t")
            && RegExMatch(saved, "m)^M\t\\\\\.\\IMWTEST2\t2(\t-?\d+){8}\r?$"),
            "waiting windows and the away monitor are saved")
        CurrentWorkspace.Clear()
        WindowWorkspace.Clear()
        HiddenByScript.Clear()
        WorkspaceWindowOrders.Clear()
        DisplacedWindows.Clear()
        DisplacedMonitors.Clear()
        SetMonitorTopology([left])
        CurrentWorkspace[1] := 1
        parked.Show("NA")
        LoadWorkspaceState()
        Sleep(100)
        AssertDisplay(DisplacedWindows.Has(parked.Hwnd) && DisplacedWindows.Has(shown.Hwnd)
            && DisplacedWindows[parked.Hwnd].placement
            && DisplacedWindows[parked.Hwnd].placement.left = parkedHome.left,
            "a restart keeps waiting windows and their places")
        AssertDisplay(!IsVisible(parked.Hwnd) && HiddenByScript.Has(parked.Hwnd)
            && !WindowWorkspace.Has(parked.Hwnd), "a restart hides waiting windows again")
        AssertSlot(shown, 1, 1, "a restart keeps a moved window on its new monitor")
        AssertDisplay(DisplacedMonitors["\\.\imwtest2"].workspace = 2
            && DisplacedMonitors["\\.\imwtest2"].monitor.right = 22600,
            "a restart keeps the away monitor's workspace and geometry")

        ; While it is away, the user moves the left monitor to D3, which hides
        ; the window that joined D1.
        CurrentWorkspace[1] := 3
        HideTestWindow(shown)

        ; The monitor returns.
        ReconcileDisplayTopology([left, right], "test-return")
        Sleep(100)
        AssertDisplay(CurrentWorkspace[1] = 3 && CurrentWorkspace[2] = 2,
            "both monitors show the workspaces they showed before")
        AssertSlot(shown, 2, 2, "a moved window returns to its monitor and workspace")
        AssertDisplay(IsVisible(shown.Hwnd) && !HiddenByScript.Has(shown.Hwnd)
            && SameTestRect(GetWindowRectObject(shown.Hwnd), shownHome),
            "a returning window is shown where it was")
        AssertSlot(parked, 2, 1, "a waiting window returns to its workspace")
        AssertDisplay(!IsVisible(parked.Hwnd) && HiddenByScript.Has(parked.Hwnd)
            && SameTestRect(GetWindowRectObject(parked.Hwnd), parkedHome),
            "a window for another workspace stays hidden in place")
        AssertDisplay(!DisplacedWindows.Count && !DisplacedMonitors.Count
            && WorkspaceWindowOrders.Has("2:2") && !DisplacedWindowOrders.Count,
            "nothing is left waiting")

        ; A monitor blinks off and on and comes back numbered first. Windows
        ; left a window on the other monitor.
        WindowPlacements := RecordWindowPlacements()
        MoveTestWindow(stay, 21300, 200)
        ReconcileDisplayTopology([right, left], "test-renumber")
        AssertSlot(stay, 2, 1, "a window keeps its slot when monitors renumber")
        AssertDisplay(SameTestRect(GetWindowRectObject(stay.Hwnd), stayHome),
            "a window Windows moved during a blink is put back")
        AssertSlot(shown, 1, 2, "slots follow their monitor's new number")
        AssertDisplay(CurrentWorkspace[1] = 2 && CurrentWorkspace[2] = 3
            && WorkspaceWindowOrders.Has("1:2") && WorkspaceWindowOrders.Has("2:1"),
            "active workspaces and stacks follow their monitor's new number")

        ; The monitor leaves again, a hidden window is moved too, and the
        ; monitor returns 200 pixels further right.
        WindowPlacements := RecordWindowPlacements()
        MoveTestWindow(shown, 20150, 150)
        MoveTestWindow(parked, 20200, 200)
        ReconcileDisplayTopology([left], "test-disconnect-again")
        moved := TestMonitor("\\.\IMWTEST2", 21200, 0, 22800, 900)
        ReconcileDisplayTopology([left, moved], "test-return-moved")
        Sleep(100)
        AssertSlot(shown, 2, 2, "a window returns to a monitor that moved")
        AssertDisplay(SameTestRect(GetWindowRectObject(shown.Hwnd), OffsetTestRect(shownHome, 200)),
            "a returning window keeps its place on a monitor that moved")
        AssertDisplay(!IsVisible(parked.Hwnd)
            && SameTestRect(GetWindowRectObject(parked.Hwnd), OffsetTestRect(parkedHome, 200)),
            "a hidden window Windows moved is put back without showing it")

        ; Mid-change, the scan learns nothing and switches and saves wait.
        unmanaged := Gui("+Resize -DPIScale")
        try {
            unmanaged.Show("NA x20300 y300 w200 h150")
            before := FileGetTime(WORKSPACE_STATE_PATH, "M") FileRead(WORKSPACE_STATE_PATH, "UTF-8")
            ; The real monitors differ from the synthetic layout.
            AssertDisplay(DisplayTopologyChanging() && DisplayTopologyPending,
                "a monitor list that differs starts a display change")
            LearnVisibleWindows()
            AssertDisplay(!WindowWorkspace.Has(unmanaged.Hwnd), "the scan waits during a change")
            AssertDisplay(!SwitchToWorkspaceOnMonitor(1, 1, 0), "switches wait during a change")
            SaveWorkspaceState()
            AssertDisplay(FileGetTime(WORKSPACE_STATE_PATH, "M")
                FileRead(WORKSPACE_STATE_PATH, "UTF-8") = before, "saves wait during a change")
        } finally {
            SetTimer(SettleDisplayTopologyChange, 0)
            DisplayTopologyPending := false
            unmanaged.Destroy()
        }
    } finally {
        for fixture in [shown, parked, stay, closer]
            try fixture.Destroy()
    }
}
TestMonitor(name, left, top, right, bottom) {
    return {name: name, device: StrLower(name), left: left, top: top,
        right: right, bottom: bottom, workLeft: left, workTop: top,
        workRight: right, workBottom: bottom - 40}
}
MoveTestWindow(fixture, x, y) {
    rect := GetWindowRectObject(fixture.Hwnd)
    DllCall("SetWindowPos", "ptr", fixture.Hwnd, "ptr", 0, "int", x, "int", y,
        "int", rect.right - rect.left, "int", rect.bottom - rect.top, "uint", 0x0214)
}
HideTestWindow(fixture) {
    global HiddenByScript
    DllCall("ShowWindow", "ptr", fixture.Hwnd, "int", 0)
    HiddenByScript[fixture.Hwnd] := true
}
OffsetTestRect(rect, dx) {
    return {left: rect.left + dx, top: rect.top, right: rect.right + dx, bottom: rect.bottom}
}
SameTestRect(a, b) {
    return a && b && a.left = b.left && a.top = b.top && a.right = b.right && a.bottom = b.bottom
}
AssertSlot(fixture, monitor, workspace, message) {
    global WindowWorkspace
    AssertDisplay(WindowWorkspace.Has(fixture.Hwnd)
        && WindowWorkspace[fixture.Hwnd].monitor = monitor
        && WindowWorkspace[fixture.Hwnd].workspace = workspace, message)
}
AssertDisplay(condition, message) {
    if !condition
        throw Error(message)
}
'@ + $functions
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('IMW-display-reconnect-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $testScript = Join-Path $testRoot 'display-reconnect-tests.ahk'
    [IO.File]::WriteAllText($testScript, $harness, [Text.UTF8Encoding]::new($true))
    $process = Start-Process -FilePath $AutoHotkeyPath -WindowStyle Hidden -PassThru `
        -ArgumentList @('/ErrorStdOut', ('"' + $testScript + '"')) `
        -RedirectStandardOutput (Join-Path $testRoot 'stdout.txt') `
        -RedirectStandardError (Join-Path $testRoot 'stderr.txt')
    # Windows PowerShell 5.1 reports no exit code unless the handle is opened
    # while the process is still running.
    $null = $process.Handle
    if (-not $process.WaitForExit(20000)) {
        $process.Kill()
        throw 'Display reconnect tests timed out.'
    }
    Get-Content -LiteralPath (Join-Path $testRoot 'stdout.txt'), (Join-Path $testRoot 'stderr.txt')
    if ($process.ExitCode -ne 0) {
        Get-Content -LiteralPath (Join-Path $testRoot 'display-reconnect.log') -Tail 20 -ErrorAction SilentlyContinue
        throw "Display reconnect tests failed: $($process.ExitCode)"
    }
} finally {
    Get-ChildItem -LiteralPath $testRoot -File | Remove-Item -Force
    Remove-Item -LiteralPath $testRoot
}
