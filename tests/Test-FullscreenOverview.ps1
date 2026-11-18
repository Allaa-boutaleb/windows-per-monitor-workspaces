#Requires -Version 5.1
[CmdletBinding()]
param([string]$AutoHotkeyPath = "$env:LOCALAPPDATA\IndependentMonitorWorkspaces\runtime\AutoHotkey.exe")
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$source = Get-Content -LiteralPath (Join-Path $repoRoot 'IndependentMonitorWorkspaces.ahk') -Raw
$start = $source.IndexOf('CheckWorkspaceOverviewHotCorner() {')
$end = $source.IndexOf('GetMonitorDpi(monitor) {', $start)
$functions = $source.Substring($start, $end - $start)
$start = $source.IndexOf('ToggleWorkspaceOverview(*) {')
$end = $source.IndexOf('ShowWorkspaceOverview(monitor :=', $start)
$functions += $source.Substring($start, $end - $start)
foreach ($name in @('WinExist', 'WinGetClass', 'WinGetMinMax', 'WinGetStyle', 'WinGetPos', 'MonitorGet', 'DllCall')) {
    $functions = [regex]::Replace($functions, '\b' + $name + '\(', 'Test_' + $name + '(')
}
# Exercise real detection and entry points with deterministic OS responses.
# No user windows, focus, cursor, or running engine are changed.
$harness = @'
#Requires AutoHotkey v2.0
global WorkspaceOverview := false, OverviewHotCornerMonitor := 0
global OverviewHotCornerEnteredAt := 0, OverviewHotCornerCooldownUntil := 0
global TestClass := "Game", TestStyle := 0x80000000, TestMinMax := 0
global TestRect := [-1920, 0, 1920, 1080], TestHwnd := 1, TestGone := false
global TestOpens := 0
Assert(IsForegroundFullscreen(), "borderless fullscreen on negative-coordinate monitor")
TestRect := [-1920, 0, 1280, 720]
Assert(!IsForegroundFullscreen(), "windowed game allows corner")
TestRect := [-1928, -8, 1936, 1096]
TestStyle := 0x00C00000
TestMinMax := 1
Assert(!IsForegroundFullscreen(), "normal maximized app allows corner")
TestStyle := 0x80000000
TestMinMax := 0
TestRect := [-1920, 0, 1920, 1080]
for shellClass in ["Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd"] {
    TestClass := shellClass
    Assert(!IsForegroundFullscreen(), "desktop/taskbar allows corner")
}
TestClass := "Game"
TestMinMax := -1
Assert(!IsForegroundFullscreen(), "minimized window allows corner")
TestMinMax := 0
TestHwnd := 0
Assert(!IsForegroundFullscreen(), "no active window allows corner")
TestHwnd := 1
TestGone := true
Assert(!IsForegroundFullscreen(), "closing window is harmless")
TestGone := false
OverviewHotCornerMonitor := 2
OverviewHotCornerEnteredAt := A_TickCount - 600
CheckWorkspaceOverviewHotCorner()
Assert(TestOpens = 0 && OverviewHotCornerMonitor = 0 && OverviewHotCornerEnteredAt = 0,
    "fullscreen suppresses corner on another monitor and resets dwell")
ToggleWorkspaceOverview()
Assert(TestOpens = 1, "explicit keyboard overview still opens during fullscreen")
TestRect := [-1920, 0, 1280, 720]
CheckWorkspaceOverviewHotCorner()
Assert(TestOpens = 1 && OverviewHotCornerMonitor = 2, "leaving fullscreen starts fresh dwell")
OverviewHotCornerEnteredAt := A_TickCount - 600
CheckWorkspaceOverviewHotCorner()
Assert(TestOpens = 2, "corner opens after fresh dwell outside fullscreen")
FileAppend("Fullscreen overview tests passed.`n", "*")
ExitApp(0)
Assert(condition, message) {
    if !condition {
        FileAppend("FAIL: " message "`n", "*")
        ExitApp(1)
    }
}
Test_WinExist(*) => TestHwnd
Test_WinGetClass(*) {
    if TestGone
        throw Error("Window closed")
    return TestClass
}
Test_WinGetStyle(*) => TestStyle
Test_WinGetMinMax(*) => TestMinMax
Test_WinGetPos(&x, &y, &w, &h, *) {
    x := TestRect[1], y := TestRect[2], w := TestRect[3], h := TestRect[4]
}
Test_MonitorGet(monitor, &left, &top, &right, &bottom) {
    left := monitor = 1 ? -1920 : 0
    top := 0, right := left + 1920, bottom := 1080
}
Test_DllCall(name, args*) {
    if name = "GetAsyncKeyState"
        return 0
    if name = "GetCursorPos" {
        NumPut("int", 0, "int", 0, args[2])
        return 1
    }
    throw Error("Unexpected native call: " name)
}
GetWindowMonitor(*) => 1
GetMonitorUnderMouse() => 2
GetMonitorDpi(*) => 96
ShowWorkspaceOverview(*) {
    global TestOpens
    TestOpens += 1
}
CloseWorkspaceOverview(*) {
}
DebugLog(*) {
}
'@
$harness += "`n" + $functions
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('IMW-fullscreen-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $testScript = Join-Path $testRoot 'fullscreen-tests.ahk'
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
        throw 'Fullscreen overview tests timed out.'
    }
    Get-Content -LiteralPath (Join-Path $testRoot 'stdout.txt'), (Join-Path $testRoot 'stderr.txt')
    if ($result.ExitCode -ne 0) { throw "Fullscreen overview tests failed: $($result.ExitCode)" }
} finally {
    Get-ChildItem -LiteralPath $testRoot -File | Remove-Item -Force
    Remove-Item -LiteralPath $testRoot
}
