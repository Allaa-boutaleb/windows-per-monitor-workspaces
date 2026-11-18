#Requires -Version 5.1
[CmdletBinding()]
param([string]$AutoHotkeyPath = "$env:LOCALAPPDATA\IndependentMonitorWorkspaces\runtime\AutoHotkey.exe")
$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'IndependentMonitorWorkspaces.ahk') -Raw
$globals = $source.Substring(0, $source.IndexOf('DetectHiddenWindows true'))
$functions = $source.Substring($source.IndexOf("`nInitializeMonitors() {"))
# Run actual discovery, cleanup, matching, and activation against deterministic
# windows. No user windows, input, or persistent state are touched.
$harness = $globals + "`nRunRestartTests()`nExitApp(0)`n" + $functions
foreach ($name in @('IsManageableWindow', 'IsWorkspaceWindowKind', 'IsVisible', 'GetWindowMonitor', 'HideWindowFast',
    'DebugLog', 'DebugDescribeWindow', 'InvalidateWorkspaceFrame', 'PromoteWorkspaceWindow',
    'RemoveWindowFromWorkspaceOrders', 'DeleteWindowSnapshot')) {
    $harness = [regex]::Replace($harness, '(?m)^' + $name + '\(', 'Native_' + $name + '(')
}
foreach ($name in @('WinExist', 'WinGetList', 'WinGetPID', 'WinGetProcessPath', 'WinGetClass', 'SetTimer')) {
    $harness = [regex]::Replace($harness, '\b' + $name + '\(', 'Test_' + $name + '(')
}
$harness += @'

RunRestartTests() {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript, WindowRestartIdentity
    global RecentAppWorkspaces, RestartActivationUntil, TestWindows, APP_RESTART_MEMORY_MS
    global WorkspaceStatePersistenceEnabled, TaskbarActivationShields, PendingExternalActivations
    global Switching, WorkspaceOverview
    WorkspaceStatePersistenceEnabled := false
    ; The engine records the monitor layout at startup.
    SetMonitorTopology(ReadMonitorTopology())
    ResetFixture()
    AddWindow(101, 10)
    LearnVisibleWindows()
    AssertRestart(WindowWorkspace[101].workspace = 3, "initial app learned on D3")
    CurrentWorkspace[1] := 2
    HiddenByScript[101] := true
    TestWindows.Delete(101)
    AddWindow(202, 20, "C:\Apps\Editor\app-2.0.0\Editor.exe")
    CheckRestartedWorkspaceWindows()
    AssertRestart(!WindowWorkspace.Has(101) && WindowWorkspace[202].workspace = 3,
        "new HWND/PID and updater version inherit D3 even in one scan")
    AssertRestart(CurrentWorkspace[1] = 2 && !TestWindows[202].visible && HiddenByScript.Has(202),
        "restored app hidden without switching away from D2")
    TestWindows[202].visible := true
    AssertRestart(QueueExternalWorkspaceActivation(202, "test") && !TestWindows[202].visible
        && PendingExternalActivations.Count = 0, "startup focus does not navigate to D3")
    TaskbarActivationShields[1] := {workspace: 2, claimed: false}
    AssertRestart(QueueExternalWorkspaceActivation(202, "test")
        && PendingExternalActivations.Has(202), "explicit taskbar selection still navigates")
    TaskbarActivationShields.Clear()
    PendingExternalActivations.Clear()
    AddWindow(203, 20, "C:\Apps\Editor\app-2.0.0\Editor.exe")
    LearnVisibleWindows()
    AssertRestart(WindowWorkspace[203].workspace = 2, "consumed memory does not pin extra windows")

    ResetFixture()
    AddWindow(101, 10)
    LearnVisibleWindows()
    CurrentWorkspace[1] := 2
    TestWindows[101].pid := 99
    LearnVisibleWindows()
    AssertRestart(WindowWorkspace[101].workspace = 3 && WindowRestartIdentity[101].pid = 99,
        "recycled handle with new PID is treated as a replacement")

    ResetFixture()
    AddWindow(101, 10)
    AddWindow(102, 10)
    LearnVisibleWindows()
    WindowWorkspace[102].workspace := 1
    TestWindows.Clear()
    CurrentWorkspace[1] := 2
    AddWindow(201, 20)
    LearnVisibleWindows()
    AssertRestart(WindowWorkspace[201].workspace = 2, "conflicting closed workspaces are not guessed")

    ResetFixture()
    AddWindow(101, 10)
    AddWindow(102, 10)
    LearnVisibleWindows()
    WindowWorkspace[102].workspace := 1
    TestWindows.Delete(101)
    CurrentWorkspace[1] := 2
    AddWindow(201, 20)
    LearnVisibleWindows()
    AssertRestart(WindowWorkspace[201].workspace = 2, "conflicting surviving window prevents guessing")

    ResetFixture()
    AddWindow(101, 10)
    AddWindow(102, 10)
    LearnVisibleWindows()
    TestWindows.Clear()
    CurrentWorkspace[1] := 2
    AddWindow(201, 20)
    AddWindow(202, 20)
    LearnVisibleWindows()
    AssertRestart(WindowWorkspace[201].workspace = 3 && WindowWorkspace[202].workspace = 3,
        "multiple replacements inherit a common workspace")

    ResetFixture()
    AddWindow(101, 10)
    LearnVisibleWindows()
    TestWindows.Clear()
    LearnVisibleWindows()
    for key, record in RecentAppWorkspaces
        record.closedAt := A_TickCount - APP_RESTART_MEMORY_MS - 1
    CurrentWorkspace[1] := 2
    AddWindow(201, 20)
    LearnVisibleWindows()
    AssertRestart(WindowWorkspace[201].workspace = 2, "expired restart memory is ignored")

    ResetFixture()
    AddWindow(101, 10)
    LearnVisibleWindows()
    TestWindows.Clear()
    CurrentWorkspace[1] := 2
    AddWindow(201, 20, "C:\Other\Editor\app-2.0.0\Editor.exe")
    AddWindow(202, 21,, "OtherClass")
    AddWindow(203, 22,,, 2)
    LearnVisibleWindows()
    AssertRestart(WindowWorkspace[201].workspace = 2 && WindowWorkspace[202].workspace = 2,
        "different installation paths and window classes do not match")
    AssertRestart(WindowWorkspace[203].monitor = 2 && WindowWorkspace[203].workspace = 1,
        "another monitor uses that monitor's current workspace")

    ResetFixture()
    AddWindow(101, 10, "C:\Program Files\WindowsApps\Vendor.Editor_1.2.3.4_x64__publisher\Editor.exe")
    LearnVisibleWindows()
    TestWindows.Clear()
    CurrentWorkspace[1] := 2
    AddWindow(201, 20, "C:\Program Files\WindowsApps\Vendor.Editor_2.3.4.5_x64__publisher\Editor.exe")
    LearnVisibleWindows()
    AssertRestart(WindowWorkspace[201].workspace = 3, "packaged app version change matches")
    RestartActivationUntil[201] := A_TickCount - 1
    AssertRestart(!SuppressRestartActivation(201, WindowWorkspace[201]), "focus grace period expires")

    ResetFixture()
    AddWindow(101, 10)
    Switching := true
    CheckRestartedWorkspaceWindows()
    AssertRestart(WindowWorkspace.Count = 0, "scan defers during a transition")
    Switching := false
    WorkspaceOverview := true
    CheckRestartedWorkspaceWindows()
    AssertRestart(WindowWorkspace.Count = 0, "scan defers during overview")
    WorkspaceOverview := false
    CheckRestartedWorkspaceWindows()
    AssertRestart(WindowWorkspace.Count = 1, "background scan resumes")
    FileAppend("App restart workspace tests passed.`n", "*")
}
ResetFixture() {
    global CurrentWorkspace, WindowWorkspace, WindowRestartIdentity, RecentAppWorkspaces
    global HiddenByScript, RestartActivationUntil, TestWindows
    CurrentWorkspace := Map(1, 3, 2, 1)
    WindowWorkspace.Clear(), WindowRestartIdentity.Clear(), RecentAppWorkspaces.Clear()
    HiddenByScript.Clear(), RestartActivationUntil.Clear()
    TestWindows := Map()
}
AddWindow(hwnd, pid, path := "C:\Apps\Editor\app-1.0.0\Editor.exe", className := "EditorWindow", monitor := 1) {
    global TestWindows
    TestWindows[hwnd] := {pid: pid, path: path, className: className, monitor: monitor, visible: true}
}
AssertRestart(condition, message) {
    if !condition {
        FileAppend("FAIL: " message "`n", "*")
        ExitApp(1)
    }
}
TestHwnd(selector) => Integer(SubStr(selector, 8))
Test_WinExist(selector) => TestWindows.Has(TestHwnd(selector)) ? TestHwnd(selector) : 0
Test_WinGetPID(selector) => TestWindows[TestHwnd(selector)].pid
Test_WinGetProcessPath(selector) => TestWindows[TestHwnd(selector)].path
Test_WinGetClass(selector) => TestWindows[TestHwnd(selector)].className
Test_WinGetList(*) {
    result := []
    for hwnd in TestWindows
        result.Push(hwnd)
    return result
}
IsManageableWindow(hwnd) => TestWindows.Has(hwnd)
IsWorkspaceWindowKind(hwnd) => TestWindows.Has(hwnd)
IsVisible(hwnd) => TestWindows[hwnd].visible
GetWindowMonitor(hwnd) => TestWindows[hwnd].monitor
HideWindowFast(hwnd) {
    TestWindows[hwnd].visible := false
}
DebugDescribeWindow(*) => "fixture"
DebugLog(*) {
}
InvalidateWorkspaceFrame(*) {
}
PromoteWorkspaceWindow(*) {
}
RemoveWindowFromWorkspaceOrders(*) {
}
DeleteWindowSnapshot(*) {
}
Test_SetTimer(*) {
}
'@
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('IMW-restart-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $testScript = Join-Path $testRoot 'restart-tests.ahk'
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
        throw 'App restart tests timed out.'
    }
    Get-Content -LiteralPath (Join-Path $testRoot 'stdout.txt'), (Join-Path $testRoot 'stderr.txt')
    if ($result.ExitCode -ne 0) { throw "App restart tests failed: $($result.ExitCode)" }
} finally {
    Get-ChildItem -LiteralPath $testRoot -File | Remove-Item -Force
    Remove-Item -LiteralPath $testRoot
}
