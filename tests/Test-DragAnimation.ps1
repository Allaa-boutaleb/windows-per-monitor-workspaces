#Requires -Version 5.1
[CmdletBinding()]
param([string]$AutoHotkeyPath = "$env:LOCALAPPDATA\IndependentMonitorWorkspaces\runtime\AutoHotkey.exe")
$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'IndependentMonitorWorkspaces.ahk') -Raw
$globals = $source.Substring(0, $source.IndexOf('DetectHiddenWindows true'))
$functions = $source.Substring($source.IndexOf("`nInitializeMonitors() {"))
# Exercise native GDI composition and HWND layering with three owned fixtures.
# Never send mouse/keyboard input or change user-window assignments or focus.
$harness = $globals + @'

WorkspaceStatePersistenceEnabled := false
OverviewPreviewMode := true
DEBUG_LOG_PATH := A_ScriptDir "\render.log"
DEBUG_PREVIOUS_LOG_PATH := A_ScriptDir "\previous.log"
DetectHiddenWindows true
SetWinDelay -1
OnMessage(0x000F, PaintWorkspaceOverview)
OnMessage(0x0014, HandleWorkspaceSlideEraseBackground)
SetTimer((*) => ExitApp(2), -10000)
try {
    TestNativeDragAnimation()
    FileAppend("Native drag animation tests passed (both directions, frame pixels, Z-order).`n", "*")
    ExitApp(0)
} catch as caughtError {
    FileAppend("FAIL: " caughtError.Message " at line " caughtError.Line "`n", "*")
    ExitApp(1)
}

TestNativeDragAnimation() {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript, Switching
    monitor := MonitorGetPrimary()
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    CurrentWorkspace[monitor] := 1
    outgoing := Gui("-Caption +ToolWindow -DPIScale")
    incoming := Gui("-Caption +ToolWindow -DPIScale")
    held := Gui("-Caption +ToolWindow -DPIScale")
    outgoing.BackColor := "2244CC"
    incoming.BackColor := "22CC44"
    held.BackColor := "FF00FF"
    options := "NA x" (left + 80) " y" (top + 80) " w400 h280"
    state := false
    try {
        incoming.Show(options)
        DllCall("UpdateWindow", "ptr", incoming.Hwnd)
        DllCall("dwmapi\DwmFlush")
        WindowWorkspace[incoming.Hwnd] := {monitor: monitor, workspace: 2}
        CaptureWindowSnapshot(incoming.Hwnd)
        incoming.Hide()
        HiddenByScript[incoming.Hwnd] := true
        outgoing.Show(options)
        held.Show("NA x" (left + 120) " y" (top + 120) " w200 h140")
        WindowWorkspace[outgoing.Hwnd] := {monitor: monitor, workspace: 1}
        WindowWorkspace[held.Hwnd] := {monitor: monitor, workspace: 1}
        AssertNative(CaptureWindowSnapshot(outgoing.Hwnd), "outgoing fixture snapshot")
        AssertNative(CaptureWindowSnapshot(held.Hwnd), "held fixture snapshot")
        Switching := true
        for direction in [1, -1] {
            destination := direction = 1 ? 2 : 1
            origin := direction = 1 ? 1 : 2
            AssignCarriedWorkspaceWindow(held.Hwnd, monitor, destination)
            state := BeginWorkspaceSlideAnimation(monitor, origin, destination, direction, 340, held.Hwnd)
            AssertNative(state, "animation exists while holding a window")
            AssertNative(DllCall("GetWindow", "ptr", state.hwnd, "uint", 3, "ptr") = held.Hwnd,
                "animation is immediately behind the live held window")
            AssertNative(!(WinGetExStyle("ahk_id " state.hwnd) & 0x8), "drag layer is not topmost")
            AssertNative(IsVisible(held.Hwnd), "held window remains visible")
            oldColor := direction = 1 ? 0xCC4422 : 0x44CC22
            newColor := direction = 1 ? 0x44CC22 : 0xCC4422
            AssertNative(FramePixel(state.outgoingFrame, 180, 180) = oldColor,
                "outgoing frame contains underlying app, without held-window ghost")
            ; Same order as a switch: hide the outgoing app, reveal the
            ; incoming one under the cover, then capture it.
            leaving := direction = 1 ? outgoing : incoming
            leaving.Hide()
            HiddenByScript[leaving.Hwnd] := true
            AssertNative(state.incomingPending, "uncached incoming workspace waits for its reveal")
            RevealWorkspaceForHandoff(monitor, destination, 260, held.Hwnd, state.hwnd)
            AssertNative(DllCall("GetWindow", "ptr", state.hwnd, "uint", 3, "ptr") = held.Hwnd,
                "revealed windows stay beneath the cover")
            CompleteIncomingWorkspaceFrame(state, [leaving.Hwnd])
            actualColor := FramePixel(state.incomingFrame, 180, 180)
            AssertNative(actualColor = newColor,
                "incoming frame omits held-window ghost: actual=" actualColor " expected=" newColor)
            AssertNative(!state.incomingExact, "a patched frame fades out at the end")
            AssertNative(state.incomingOffset = direction * state.width, "correct initial side")
            RunWorkspaceSlideAnimation(state)
            AssertNative(state.outgoingOffset = -direction * state.width && state.incomingOffset = 0,
                "slide reaches correct destination")
            AssertNative(IsVisible(held.Hwnd), "held window survives complete animation")
            EndWorkspaceSlideAnimation(state)
            state := false
        }
    } finally {
        EndWorkspaceSlideAnimation(state)
        outgoing.Destroy()
        incoming.Destroy()
        held.Destroy()
        ClearWindowSnapshots()
        ClearWorkspaceFrames()
    }
}
FramePixel(frame, x, y) {
    dc := DllCall("CreateCompatibleDC", "ptr", 0, "ptr")
    old := DllCall("SelectObject", "ptr", dc, "ptr", frame.bitmap, "ptr")
    pixel := DllCall("GetPixel", "ptr", dc, "int", x, "int", y, "uint")
    DllCall("SelectObject", "ptr", dc, "ptr", old)
    DllCall("DeleteDC", "ptr", dc)
    return pixel
}
AssertNative(condition, message) {
    if !condition
        throw Error(message)
}
'@ + $functions
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('IMW-drag-render-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $testScript = Join-Path $testRoot 'render-tests.ahk'
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
        throw 'Native drag animation tests timed out.'
    }
    Get-Content -LiteralPath (Join-Path $testRoot 'stdout.txt'), (Join-Path $testRoot 'stderr.txt')
    if ($process.ExitCode -ne 0) {
        Get-Content -LiteralPath (Join-Path $testRoot 'render.log') -Tail 12 -ErrorAction SilentlyContinue
        throw "Native drag animation tests failed: $($process.ExitCode)"
    }
} finally {
    Get-ChildItem -LiteralPath $testRoot -File | Remove-Item -Force
    Remove-Item -LiteralPath $testRoot
}
