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
# On-screen displays (a Caps Lock indicator), meeting and screen-sharing
# overlays, and other popups must never join a workspace: hiding one and
# re-showing it on the next visit left it stuck on screen, and focusing one
# switched the monitor's workspace. Uses only windows this harness owns and
# its own state and log files.
$harness = $globals + @'

WORKSPACE_STATE_PATH := A_ScriptDir "\workspace-state.tsv"
DEBUG_LOG_PATH := A_ScriptDir "\transient.log"
DEBUG_PREVIOUS_LOG_PATH := A_ScriptDir "\previous.log"
DetectHiddenWindows true
SetWinDelay -1
try {
    TestTransientWindows()
    FileAppend("Transient window tests passed (overlays, palettes, saved-state release, restart memory, log speed).`n", "*")
    ExitApp(0)
} catch as caughtError {
    FileAppend("FAIL: " caughtError.Message " at line " caughtError.Line "`n", "*")
    ExitApp(1)
}

TestTransientWindows() {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript, WorkspaceWindowOrders
    global WindowRestartIdentity, WORKSPACE_STATE_PATH
    InitializeMonitors()
    monitor := MonitorGetPrimary()
    app := Gui("-Caption -DPIScale")
    osd := Gui("-Caption +ToolWindow +AlwaysOnTop -DPIScale")
    noActivate := Gui("-Caption +E0x08000000 -DPIScale")
    clickThrough := Gui("-Caption +E0x80020 -DPIScale")
    listedTool := Gui("-Caption +ToolWindow +E0x40000 -DPIScale")
    palette := Gui("-Caption +ToolWindow +Owner" app.Hwnd " -DPIScale")
    floatingBar := Gui("-Caption +ToolWindow +AlwaysOnTop +Owner" app.Hwnd " -DPIScale")
    dialog := Gui("+Owner" app.Hwnd " -DPIScale", "IMW owned dialog")
    ; Zoom's screen-sharing toolbar asks for a taskbar button. While sharing
    ; it is owned by a click-through annotation overlay; before and after, by
    ; a hidden toolbar holder that the meeting window owns.
    shareOverlay := Gui("-Caption +ToolWindow +AlwaysOnTop +E0x80020 -DPIScale")
    shareToolbar := Gui("-Caption +AlwaysOnTop +E0x40000 +Owner" shareOverlay.Hwnd " -DPIScale")
    toolbarHolder := Gui("-Caption +ToolWindow +E0x08000000 +Owner" app.Hwnd " -DPIScale")
    heldToolbar := Gui("-Caption +E0x40000 +Owner" toolbarHolder.Hwnd " -DPIScale")
    reowned := Gui("-Caption +E0x40000 -DPIScale")
    try {
        AssertTransient(IsWorkspaceWindowKind(app.Hwnd), "an ordinary app window is managed")
        AssertTransient(IsWorkspaceWindowKind(dialog.Hwnd), "an app's dialog is managed")
        AssertTransient(IsWorkspaceWindowKind(listedTool.Hwnd),
            "a tool window shown on the taskbar is managed")
        AssertTransient(!IsWorkspaceWindowKind(osd.Hwnd), "an on-screen display is not managed")
        AssertTransient(!IsWorkspaceWindowKind(noActivate.Hwnd),
            "a window that never takes focus is not managed")
        AssertTransient(!IsWorkspaceWindowKind(clickThrough.Hwnd),
            "a click-through overlay is not managed")
        AssertTransient(!IsWorkspaceWindowKind(shareToolbar.Hwnd)
            && !ResolveTrackedWorkspaceWindow(shareToolbar.Hwnd),
            "a taskbar-listed toolbar owned by an overlay is not managed")
        AssertTransient(!IsWorkspaceWindowKind(heldToolbar.Hwnd),
            "a toolbar owned by an overlay that an app window owns is not managed")
        AssertTransient(!IsWorkspaceWindowKind(palette.Hwnd),
            "a palette is not managed while its app is not")
        WindowWorkspace[app.Hwnd] := {monitor: monitor, workspace: 1}
        AssertTransient(IsWorkspaceWindowKind(palette.Hwnd), "a palette follows its tracked app")
        AssertTransient(!IsWorkspaceWindowKind(floatingBar.Hwnd),
            "an always-on-top toolbar stays out even when its app is tracked")
        AssertTransient(ResolveTrackedWorkspaceWindow(dialog.Hwnd) = app.Hwnd,
            "focusing a new dialog still leads to its app's workspace")
        AssertTransient(!ResolveTrackedWorkspaceWindow(floatingBar.Hwnd),
            "focusing an app's floating toolbar does not switch workspaces")

        ; Older versions saved popups and overlays with the apps. The OSD was
        ; hidden mid-display on D3; a restart must neither keep it nor show it.
        WindowWorkspace.Clear()
        HiddenByScript.Clear()
        WorkspaceWindowOrders.Clear()
        app.Show("NA x40 y40 w160 h120")
        palette.Show("NA x40 y180 w60 h40")
        CurrentWorkspace[monitor] := 1
        pid := DllCall("GetCurrentProcessId")
        monitorName := MonitorGetName(monitor)
        contents := "IMW_STATE_V2`nM`t" monitorName "`t1`n"
        for entry in [[app, 1], [palette, 1], [osd, 3], [noActivate, 3], [clickThrough, 1]]
            contents .= "W`t" entry[1].Hwnd "`t" pid "`t" monitorName "`t" entry[2] "`t1`n"
        contents .= "O`t" osd.Hwnd "`t" pid "`t" monitorName "`t3`t1`n"
        if FileExist(WORKSPACE_STATE_PATH)
            FileDelete(WORKSPACE_STATE_PATH)
        FileAppend(contents, WORKSPACE_STATE_PATH, "UTF-8")
        InitializeMonitors()
        LoadWorkspaceState()
        ApplyRestoredWorkspaceVisibility()
        Sleep(100)
        AssertTransient(WindowWorkspace.Has(app.Hwnd) && WindowWorkspace.Has(palette.Hwnd),
            "saved apps and their palettes are kept")
        for overlay in [osd, noActivate, clickThrough]
            AssertTransient(!WindowWorkspace.Has(overlay.Hwnd) && !HiddenByScript.Has(overlay.Hwnd),
                "a saved overlay is released")
        AssertTransient(!WorkspaceWindowOrders.Has(WorkspaceWindowOrderKey(monitor, 3)),
            "a released overlay leaves no saved stack")
        RestoreAllWindows()
        Sleep(100)
        AssertTransient(!IsVisible(osd.Hwnd) && !IsVisible(noActivate.Hwnd),
            "released overlays are not popped up, even when revealing everything")

        ; A new popup of the same app must not inherit a closed one's workspace.
        dialog.Show("NA x220 y40 w160 h120")
        RememberWindowRestartIdentity(app.Hwnd)
        RememberWindowRestartIdentity(dialog.Hwnd)
        AssertTransient(WindowRestartIdentity.Has(app.Hwnd), "app windows are remembered for restarts")
        AssertTransient(!WindowRestartIdentity.Has(dialog.Hwnd),
            "owned dialogs and popups are not remembered for restarts")

        ; Zoom shows its share toolbar first and attaches it to the sharing
        ; overlay afterwards, so the background scan could adopt it in between.
        WindowWorkspace[reowned.Hwnd] := {monitor: monitor, workspace: 3}
        DllCall("SetWindowLongPtr", "ptr", reowned.Hwnd, "int", -8, "ptr", shareOverlay.Hwnd) ; GWLP_HWNDPARENT
        AssertTransient(!QueueExternalWorkspaceActivation(reowned.Hwnd, "test"),
            "focusing a window that became an overlay does not switch workspaces")
        RefreshClosedAppWorkspaces()
        AssertTransient(!WindowWorkspace.Has(reowned.Hwnd) && WindowWorkspace.Has(app.Hwnd)
            && WindowWorkspace.Has(palette.Hwnd), "a window that became an overlay is released")

        ; Every line used to reopen the log, about 8 ms each; a switch logs
        ; dozens. Lines must still be on disk at once for crash diagnosis.
        startedAt := A_TickCount
        Loop 400
            DebugLog("TRANSIENT_TEST", "line=" A_Index)
        elapsed := A_TickCount - startedAt
        AssertTransient(elapsed < 400, "400 log lines took " elapsed " ms")
        AssertTransient(InStr(FileRead(DEBUG_LOG_PATH, "UTF-8"), "[TRANSIENT_TEST] line=400"),
            "log lines are flushed immediately")
    } finally {
        for fixture in [reowned, shareToolbar, shareOverlay, heldToolbar, toolbarHolder,
            floatingBar, palette, dialog, osd, noActivate, clickThrough, listedTool, app]
            fixture.Destroy()
    }
}
AssertTransient(condition, message) {
    if !condition
        throw Error(message)
}
'@ + $functions
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('IMW-transient-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $testScript = Join-Path $testRoot 'transient-tests.ahk'
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
        throw 'Transient window tests timed out.'
    }
    Get-Content -LiteralPath (Join-Path $testRoot 'stdout.txt'), (Join-Path $testRoot 'stderr.txt')
    if ($process.ExitCode -ne 0) {
        Get-Content -LiteralPath (Join-Path $testRoot 'transient.log') -Tail 12 -ErrorAction SilentlyContinue
        throw "Transient window tests failed: $($process.ExitCode)"
    }
} finally {
    Get-ChildItem -LiteralPath $testRoot -File | Remove-Item -Force
    Remove-Item -LiteralPath $testRoot
}
