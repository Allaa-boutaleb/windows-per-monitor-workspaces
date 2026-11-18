#Requires -Version 5.1
[CmdletBinding()]
param([string]$AutoHotkeyPath = "$env:LOCALAPPDATA\IndependentMonitorWorkspaces\runtime\AutoHotkey.exe")

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $repoRoot 'IndependentMonitorWorkspaces.ahk') -Raw
# Run the real switch/assignment/queue logic against a deterministic desktop.
# No user windows, input, saved state, or running engine are touched.
$globals = $source.Substring(0, $source.IndexOf('DetectHiddenWindows true'))
$functions = $source.Substring($source.IndexOf("`nInitializeMonitors() {"))
$harness = $globals + "`nRunDragTests()`nExitApp(0)`n" + $functions
$stubs = @(
    'GetDraggedWorkspaceWindow', 'EnsureMonitorState', 'GetWindowMonitor',
    'LearnVisibleWindows', 'RememberWorkspaceWindowOrder', 'IsVisible',
    'IsManageableWindow', 'HideWindowFast', 'ShowWindowFast',
    'CaptureWindowSnapshot', 'BeginWorkspaceSlideAnimation',
    'RestoreWorkspaceWindowOrder', 'ShowWorkspaceOverlay', 'DebugLog'
)
foreach ($name in $stubs) {
    $harness = [regex]::Replace($harness, '(?m)^' + $name + '\(', 'Native_' + $name + '(')
}
foreach ($name in @('WinExist', 'WinGetList', 'SetTimer')) {
    $harness = [regex]::Replace($harness, '\b' + $name + '\(', 'Test_' + $name + '(')
}
$harness += @'

RunDragTests() {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript, OverviewPreviewMode
    global WorkspaceStatePersistenceEnabled, CarriedWorkspaceWindow
    global PendingWorkspaceSwitches, Switching, SwitchingMonitor
    global TestWindows, TestDragged, TestAnimations, TestMonitor, TestRestored
    WorkspaceStatePersistenceEnabled := false
    OverviewPreviewMode := true
    ; The engine records the monitor layout at startup.
    SetMonitorTopology(ReadMonitorTopology())
    TestWindows := Map(101, true, 102, true, 201, false, 301, false)
    TestDragged := 101
    TestMonitor := 1
    TestAnimations := 0
    TestRestored := []
    CurrentWorkspace := Map(1, 1, 2, 2)
    WindowWorkspace := Map(101, {monitor: 1, workspace: 1},
        102, {monitor: 1, workspace: 1}, 201, {monitor: 1, workspace: 2},
        301, {monitor: 1, workspace: 3})
    HiddenByScript := Map(201, true, 301, true)

    AssertDrag(SwitchToWorkspaceOnMonitor(2, 1), "first switch succeeds")
    AssertDrag(TestWindows[101] && !HiddenByScript.Has(101), "held window stays visible")
    AssertDrag(!TestWindows[102] && TestWindows[201], "other windows switch normally")
    AssertDrag(WindowWorkspace[101].workspace = 2, "held window joins D2")
    AssertDrag(TestRestored[1] = 101, "held window stays first in destination stack")
    AssertDrag(!QueueExternalWorkspaceActivation(101, "test"), "carry ignores external activation")

    AssertDrag(SwitchToWorkspaceOnMonitor(3, 1), "repeated held switch succeeds")
    AssertDrag(WindowWorkspace[101].workspace = 3 && TestWindows[101], "carry continues into D3")
    AssertDrag(TestAnimations = 2, "each held switch animates behind the carried window")
    TestDragged := 0
    FinishWorkspaceWindowDrag()
    AssertDrag(!CarriedWorkspaceWindow && WindowWorkspace[101].workspace = 3, "drop stays on D3")
    SwitchToWorkspaceOnMonitor(2, 1)
    AssertDrag(!TestWindows[101] && WindowWorkspace[101].workspace = 3, "released window stays behind")
    AssertDrag(TestAnimations = 3, "normal switching still uses animation")

    TestWindows[101] := true
    HiddenByScript.Delete(101)
    TestDragged := 101
    CarryWindowToWorkspace(101, 1, 2)
    TestMonitor := 2
    TestDragged := 0
    FinishWorkspaceWindowDrag()
    AssertDrag(WindowWorkspace[101].monitor = 2 && WindowWorkspace[101].workspace = 2,
        "cross-monitor drop joins destination active workspace")

    ; A request queued while held must recheck the drag when it executes.
    TestMonitor := 1
    CarryWindowToWorkspace(101, 1, 2)
    TestDragged := 101
    Switching := true
    SwitchingMonitor := 1
    SwitchToWorkspaceOnMonitor(3, 1)
    TestDragged := 0
    Switching := false
    SwitchingMonitor := 0
    ProcessPendingWorkspaceSwitches()
    AssertDrag(WindowWorkspace[101].workspace = 2 && !TestWindows[101],
        "queued switch after release does not carry the dropped window")
    AssertDrag(PendingWorkspaceSwitches.Count = 0, "queue drains")
    AssertDrag(GetAdjacentWorkspace(3, 1) = 3 && GetAdjacentWorkspace(1, -1) = 1,
        "navigation boundaries remain intact")
    FileAppend("Window drag switch tests passed.`n", "*")
}
AssertDrag(condition, message) {
    if !condition {
        FileAppend("FAIL: " message "`n", "*")
        ExitApp(1)
    }
}
GetDraggedWorkspaceWindow() {
    global TestDragged
    return TestDragged
}
GetWindowMonitor(hwnd) {
    global TestMonitor
    return TestMonitor
}
Test_WinExist(selector) {
    global TestWindows
    return TestWindows.Has(Integer(SubStr(selector, 8)))
}
Test_WinGetList(*) {
    global TestWindows
    return [101, 102, 201, 301]
}
IsVisible(hwnd) {
    global TestWindows
    return TestWindows.Has(hwnd) && TestWindows[hwnd]
}
IsManageableWindow(hwnd) {
    return true
}
HideWindowFast(hwnd) {
    global TestWindows, TestDragged
    AssertDrag(hwnd != TestDragged, "never hide a held window")
    TestWindows[hwnd] := false
}
ShowWindowFast(hwnd) {
    global TestWindows
    TestWindows[hwnd] := true
}
BeginWorkspaceSlideAnimation(monitor, oldWorkspace, newWorkspace, direction, duration,
    draggedHwnd := 0) {
    global TestAnimations, TestDragged
    AssertDrag(draggedHwnd = TestDragged, "animation receives the current held window")
    AssertDrag(direction = (newWorkspace > oldWorkspace ? 1 : -1), "slide direction follows destination")
    TestAnimations += 1
    return false
}
RestoreWorkspaceWindowOrder(monitor, workspace, draggedHwnd := 0, coverHwnd := 0) {
    global TestRestored
    TestRestored := GetWorkspaceWindowOrder(monitor, workspace)
}
EnsureMonitorState(*) {
}
LearnVisibleWindows(*) {
}
RememberWorkspaceWindowOrder(*) {
}
CaptureWindowSnapshot(*) {
}
ShowWorkspaceOverlay(*) {
}
DebugLog(*) {
}
Test_SetTimer(*) {
}
'@
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('IMW-drag-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $testScript = Join-Path $testRoot 'drag-tests.ahk'
    [IO.File]::WriteAllText($testScript, $harness, [Text.UTF8Encoding]::new($true))
    $result = Start-Process -FilePath $AutoHotkeyPath -WindowStyle Hidden -PassThru `
        -ArgumentList @('/ErrorStdOut', ('"' + $testScript + '"')) `
        -RedirectStandardOutput (Join-Path $testRoot 'stdout.txt') `
        -RedirectStandardError (Join-Path $testRoot 'stderr.txt')
    # Windows PowerShell 5.1 reports no exit code unless the handle is opened
    # while the process is still running.
    $null = $result.Handle
    if (-not $result.WaitForExit(15000)) {
        $result.Kill()
        throw 'Window drag tests timed out.'
    }
    Get-Content -LiteralPath (Join-Path $testRoot 'stdout.txt'), (Join-Path $testRoot 'stderr.txt')
    if ($result.ExitCode -ne 0) { throw "Window drag tests failed: $($result.ExitCode)" }
} finally {
    # Delete only this run's known files; no recursive computed-path cleanup.
    Get-ChildItem -LiteralPath $testRoot -File | Remove-Item -Force
    Remove-Item -LiteralPath $testRoot
}
