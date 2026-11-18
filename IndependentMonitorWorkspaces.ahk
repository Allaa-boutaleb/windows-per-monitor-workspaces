#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; Independent per-monitor workspaces for Windows 11.
; This intentionally stays on one native Windows virtual desktop and emulates
; independent desktops by showing/hiding only the windows on the selected monitor.

APP_VERSION := "1.2.24"
WORKSPACE_COUNT := 3
SHOW_FEEDBACK := true
WORKSPACE_SLIDE_MS := 340
RAPID_WORKSPACE_SLIDE_MS := 190
WORKSPACE_FADE_MS := 120
INDICATOR_MS := 850
WORKSPACE_WATCHDOG_SOFT_MS := 1400
WORKSPACE_WATCHDOG_RESTART_MS := 4500

global CurrentWorkspace := Map()
global WindowWorkspace := Map()
global WindowRestartIdentity := Map()
global RecentAppWorkspaces := Map()
global RestartActivationUntil := Map()
APP_RESTART_MEMORY_MS := 10 * 60 * 1000
global HiddenByScript := Map()
global RestoredSelfHiddenWindows := Map()
global WindowSnapshots := Map()
global WorkspaceFrames := Map()
global WorkspaceWindowOrders := Map()
global DeferredWorkspaceFrameDeletes := []
global DesktopBackgrounds := Map()
global DesktopBackgroundsCapturedAt := 0
global DesktopBackgroundsAttemptedAt := 0
DESKTOP_BACKGROUND_REFRESH_MS := 5 * 60 * 1000
global WorkspaceSlideAnimations := Map()
global WorkspaceOverlays := Map()
global WorkspaceOverview := false
global OverviewHotCornerMonitor := 0
global OverviewHotCornerEnteredAt := 0
global OverviewHotCornerCooldownUntil := 0
global OverviewPreviewWindows := []
global OverviewPreviewMode := false
global Switching := false
global SwitchingMonitor := 0
global SwitchingStartedAt := 0
global SwitchingLastProgressAt := 0
global SwitchingTargetWorkspace := 0
global SwitchingDirection := 0
global SwitchingSoftRecoveryRequested := false
global WorkspaceRestartScheduled := false
global WorkspaceRestartPreviewMode := false
global RequestedWorkspace := Map()
global PendingWorkspaceSwitches := Map()
global WorkspaceSlideSkipRequests := Map()
global ExternalActivationHandling := false
global PendingExternalActivations := Map()
global ForegroundWinEventCallback := 0
global ForegroundWinEventHook := 0
global TaskbarActivationShields := Map()
global CarriedWorkspaceWindow := 0
; Monitors are numbered by Windows' enumeration order, which changes when a
; display disconnects or reconnects. The layout the slots were numbered in is
; kept here, with each monitor's \\.\DISPLAYn device name and geometry.
global MonitorTopology := []
global MonitorTopologyKey := ""
global DisplayTopologyPending := false
global DisplayTopologyLastSeen := ""
DISPLAY_SETTLE_MS := 1500
; Where each window sat moments ago, refreshed while the layout is stable, so
; windows Windows moves off a disconnecting monitor can be put back.
global WindowPlacements := Map()
global PlacementRestores := Map()
; Windows, workspace stacks and active workspaces of monitors that are gone,
; kept until the monitor returns.
global DisplacedWindows := Map()
global DisplacedMonitors := Map()
global DisplacedWindowOrders := Map()
global DEBUG_LOG_PATH := GetWorkspaceStoragePath("debug.log")
global DEBUG_PREVIOUS_LOG_PATH := GetWorkspaceStoragePath("debug.previous.log")
global DEBUG_MAX_BYTES := 4 * 1024 * 1024
global DebugLogFile := false
global DEBUG_SESSION_ID := FormatTime(, "yyyyMMdd-HHmmss") "-" DllCall("GetCurrentProcessId", "uint")
global WORKSPACE_STATE_PATH := GetWorkspaceStoragePath("workspace-state.tsv", true)
global WORKSPACE_RECOVERY_PATH := GetWorkspaceStoragePath("pending-recovery.tsv", true)
global WorkspaceStatePersistenceEnabled := true

; AutoHotkey starts system-DPI-aware, which virtualizes screen coordinates on
; monitors whose scaling differs from the primary display. Keep the script's
; single native UI thread per-monitor-v2-aware so monitor bounds, screen
; captures, GDI buffers, and presentation windows all use physical pixels.
global StartupPreviousDpiContext := EnablePerMonitorDpiAwareness()

DetectHiddenWindows true
SetTitleMatchMode 2
SetWinDelay -1
OnMessage(0x000F, PaintWorkspaceOverview) ; WM_PAINT
OnMessage(0x0014, HandleWorkspaceSlideEraseBackground) ; WM_ERASEBKGND
OnMessage(0x0202, HandleOverviewClick) ; WM_LBUTTONUP

if A_Args.Length && A_Args[1] = "--navigation-self-test" {
    RunNavigationBoundarySelfTest()
    return
}

InitializeDebugLogging()
DebugLog("STARTUP", "version=" APP_VERSION " script=" A_ScriptFullPath
    " args=" FormatDebugArguments())
DebugLog("DPI_AWARENESS", DebugDpiAwareness())

if A_Args.Length && A_Args[1] = "--preview" {
    previewMonitor := A_Args.Length >= 2 ? Integer(A_Args[2]) : MonitorGetPrimary()
    previewWorkspace := A_Args.Length >= 3 ? Integer(A_Args[3]) : 2
    previewDirection := A_Args.Length >= 4 ? Integer(A_Args[4]) : 1
    ShowWorkspaceOverlay(previewMonitor, previewWorkspace, previewDirection)
    SetTimer((*) => ExitApp(), -3000)
    return
}

if A_Args.Length && A_Args[1] = "--overview-preview" {
    WorkspaceStatePersistenceEnabled := false
    InitializeMonitors()
    previewMonitor := A_Args.Length >= 2 ? Integer(A_Args[2]) : MonitorGetPrimary()
    SetupWorkspaceOverviewPreview(previewMonitor)
    return
}

if A_Args.Length && A_Args[1] = "--slide-preview" {
    WorkspaceStatePersistenceEnabled := false
    InitializeMonitors()
    previewMonitor := A_Args.Length >= 2 ? Integer(A_Args[2]) : MonitorGetPrimary()
    SetupWorkspaceSlidePreview(previewMonitor)
    return
}

if A_Args.Length && A_Args[1] = "--rapid-slide-preview" {
    WorkspaceStatePersistenceEnabled := false
    InitializeMonitors()
    previewMonitor := A_Args.Length >= 2 ? Integer(A_Args[2]) : MonitorGetPrimary()
    SetupWorkspaceSlidePreview(previewMonitor, true)
    return
}

if A_Args.Length && A_Args[1] = "--handoff-loop-preview" {
    WorkspaceStatePersistenceEnabled := false
    InitializeMonitors()
    previewMonitor := A_Args.Length >= 2 ? Integer(A_Args[2]) : MonitorGetPrimary()
    SetupWorkspaceSlidePreview(previewMonitor, false, true)
    return
}

if A_Args.Length && A_Args[1] = "--taskbar-activation-preview" {
    WorkspaceStatePersistenceEnabled := false
    InitializeMonitors()
    previewMonitor := A_Args.Length >= 2 ? Integer(A_Args[2]) : MonitorGetPrimary()
    SetupTaskbarActivationPreview(previewMonitor)
    return
}

if A_Args.Length && A_Args[1] = "--watchdog-preview" {
    WorkspaceStatePersistenceEnabled := false
    WorkspaceRestartPreviewMode := true
    InitializeMonitors()
    Switching := true
    SwitchingMonitor := MonitorGetPrimary()
    SwitchingTargetWorkspace := 2
    SwitchingDirection := 1
    SwitchingStartedAt := A_TickCount - WORKSPACE_WATCHDOG_RESTART_MS - 100
    SwitchingLastProgressAt := SwitchingStartedAt
    CheckWorkspaceEngineHealth()
    SetTimer((*) => ExitApp(), -400)
    return
}

InitializeMonitors()
OnExit(HandleAppExit)
OnMessage(0x007E, HandleDisplayChange) ; WM_DISPLAYCHANGE
OnMessage(0x001A, HandleSettingChange) ; WM_SETTINGCHANGE
LoadWorkspaceState()
SyncRequestedWorkspaces()
LearnVisibleWindows()
ApplyRestoredWorkspaceVisibility()
SaveWorkspaceState()

Loop 9 {
    workspace := A_Index
    Hotkey("#^" workspace, SwitchToWorkspace.Bind(workspace))
    Hotkey("#^+" workspace, MoveActiveWindowToWorkspace.Bind(workspace))
}

Hotkey("#^Left", PreviousWorkspace)
Hotkey("#^Right", NextWorkspace)
Hotkey("^!Left", PreviousWorkspace)
Hotkey("^!Right", NextWorkspace)
Hotkey("#^+Esc", ResetAndRevealAll)
Hotkey("#^+r", RestartWorkspaceEngine)
Hotkey("#^Space", ToggleWorkspaceOverview)
RegisterTaskbarClickHotkeys()
SetTimer(CheckWorkspaceOverviewHotCorner, 100)
InstallForegroundWinEventHook()
SetTimer(CheckExternalWorkspaceActivation, 15)
SetTimer(CheckRestartedWorkspaceWindows, 250)
SetTimer(CheckWorkspaceEngineHealth, 250)
SetTimer(RefreshDesktopBackgrounds, -1500)
SetTimer(RefreshDesktopBackgroundsWhenIdle, 30000)

A_TrayMenu.Delete()
A_TrayMenu.Add("Workspace overview", ToggleWorkspaceOverview)
A_TrayMenu.Add("Show shortcuts", ShowHelp)
A_TrayMenu.Add("Open debug log", OpenDebugLog)
A_TrayMenu.Add("Restart workspace engine", RestartWorkspaceEngine)
A_TrayMenu.Add("Reveal all windows and reset", ResetAndRevealAll)
A_TrayMenu.Add()
A_TrayMenu.Add("Exit (reveals hidden windows)", (*) => ExitApp())
A_TrayMenu.Default := "Show shortcuts"
A_IconTip := "Independent Monitor Workspaces"

ResumePendingWorkspaceRecovery()
readyMonitor := GetMonitorUnderMouse()
ShowFeedbackForMonitor(readyMonitor,
    CurrentWorkspace.Has(readyMonitor) ? CurrentWorkspace[readyMonitor] : 1, "Ready")

InitializeMonitors() {
    global CurrentWorkspace
    topology := ReadMonitorTopology()
    SetMonitorTopology(topology)
    DebugLog("MONITORS_INIT", "count=" topology.Length " primary=" MonitorGetPrimary())
    for index, entry in topology {
        CurrentWorkspace[index] := 1
        DebugLog("MONITOR", "index=" index " name=" entry.name
            " bounds=" entry.left "," entry.top "," entry.right "," entry.bottom
            " dpi=" GetMonitorDpi(index) " current=D1")
    }
}

ReadMonitorEntry(index) {
    try {
        name := MonitorGetName(index)
        MonitorGet(index, &left, &top, &right, &bottom)
        MonitorGetWorkArea(index, &workLeft, &workTop, &workRight, &workBottom)
    } catch
        return false
    return {name: name, device: StrLower(name),
        left: left, top: top, right: right, bottom: bottom,
        workLeft: workLeft, workTop: workTop, workRight: workRight, workBottom: workBottom}
}

ReadMonitorTopology() {
    topology := []
    Loop MonitorGetCount() {
        entry := ReadMonitorEntry(A_Index)
        ; Keep the numbering intact even if a monitor vanished mid-read; its
        ; empty name keeps the layout from being taken as settled.
        topology.Push(entry ? entry : {name: "", device: "",
            left: 0, top: 0, right: 0, bottom: 0,
            workLeft: 0, workTop: 0, workRight: 0, workBottom: 0})
    }
    return topology
}

SetMonitorTopology(topology) {
    global MonitorTopology, MonitorTopologyKey, DisplayTopologyLastSeen
    MonitorTopology := topology
    MonitorTopologyKey := MonitorTopologySignature(topology)
    DisplayTopologyLastSeen := MonitorTopologyKey
}

MonitorTopologySignature(topology) {
    signature := ""
    for index, entry in topology
        signature .= (index > 1 ? "|" : "") entry.device ":" entry.left "," entry.top
            . "," entry.right "," entry.bottom
    return signature
}

CurrentMonitorSignature() {
    ; Names and bounds only: this runs with every 250 ms window scan.
    signature := ""
    try {
        Loop MonitorGetCount() {
            MonitorGet(A_Index, &left, &top, &right, &bottom)
            signature .= (A_Index > 1 ? "|" : "") StrLower(MonitorGetName(A_Index))
                . ":" left "," top "," right "," bottom
        }
    } catch
        signature .= "|unreadable"
    return signature
}

SameMonitorGeometry(a, b) {
    return a.left = b.left && a.top = b.top && a.right = b.right && a.bottom = b.bottom
        && a.workLeft = b.workLeft && a.workTop = b.workTop
        && a.workRight = b.workRight && a.workBottom = b.workBottom
}

GetWorkspaceStoragePath(fileName, stateStore := false) {
    ; Codex is a packaged app, so files installed under LOCALAPPDATA can be
    ; physically redirected into the package's LocalCache. Once installed,
    ; anchor logs and state to the script's resolved on-disk directory so an
    ; Explorer-launched recovery process sees the same data as the installer.
    if FileExist(A_ScriptDir "\install.json") {
        if !stateStore
            return A_ScriptDir "\" fileName
        SplitPath(A_ScriptDir, &directoryName, &parentDirectory)
        return parentDirectory "\IndependentMonitorWorkspacesState\" fileName
    }
    directory := stateStore
        ? "IndependentMonitorWorkspacesState"
        : "IndependentMonitorWorkspaces"
    return EnvGet("LOCALAPPDATA") "\" directory "\" fileName
}

SwitchToWorkspace(workspace, direction := 0, *) {
    if Type(direction) != "Integer"
        direction := 0
    EnsureMonitorState()
    monitor := GetMonitorUnderMouse()
    DebugLog("SWITCH_HOTKEY", "target=D" workspace " monitor=" monitor
        " direction=" direction)
    SwitchToWorkspaceOnMonitor(workspace, monitor, direction)
}

SwitchToWorkspaceOnMonitor(workspace, monitor, direction := 0, rapid := false,
    externalActivatedHwnd := 0) {
    global WORKSPACE_COUNT, CurrentWorkspace, WindowWorkspace
    global WORKSPACE_SLIDE_MS, RAPID_WORKSPACE_SLIDE_MS
    global HiddenByScript, Switching, SwitchingMonitor, WorkspaceOverview, OverviewPreviewMode
    global RequestedWorkspace, PendingWorkspaceSwitches, WorkspaceSlideSkipRequests
    global SwitchingStartedAt, SwitchingLastProgressAt, SwitchingTargetWorkspace
    global SwitchingDirection, SwitchingSoftRecoveryRequested

    if Type(direction) != "Integer"
        direction := 0

    DebugLog("SWITCH_REQUEST", "target=D" workspace " monitor=" monitor
        " direction=" direction " rapid=" rapid " switching=" Switching)
    if workspace < 1 || workspace > WORKSPACE_COUNT {
        DebugLog("SWITCH_REJECT", "reason=invalid-workspace target=" workspace)
        return false
    }
    ; Monitor numbers are stale until a display change settles.
    if DisplayTopologyChanging() {
        DebugLog("SWITCH_REJECT", "reason=display-change target=D" workspace
            " monitor=" monitor)
        return false
    }
    RequestedWorkspace[monitor] := workspace
    if Switching {
        PendingWorkspaceSwitches[monitor] := {
            workspace: workspace, direction: direction, rapid: true
        }
        if SwitchingMonitor = monitor
            WorkspaceSlideSkipRequests[monitor] := true
        DebugLog("SWITCH_QUEUE", "target=D" workspace " monitor=" monitor
            " direction=" direction " activeMonitor=" SwitchingMonitor
            " accelerateActive=" (SwitchingMonitor = monitor)
            " pendingMonitors=" PendingWorkspaceSwitches.Count)
        return false
    }

    if WorkspaceOverview
        CloseWorkspaceOverview(false)

    FinishWorkspaceWindowDrag()
    Switching := true
    SwitchingMonitor := monitor
    SwitchingStartedAt := A_TickCount
    SwitchingLastProgressAt := SwitchingStartedAt
    SwitchingTargetWorkspace := workspace
    SwitchingDirection := direction
    SwitchingSoftRecoveryRequested := false
    animation := false
    switchSucceeded := false
    try {
        EnsureMonitorState()
        oldWorkspace := CurrentWorkspace[monitor]
        DebugLog("SWITCH_BEGIN", "monitor=" monitor " from=D" oldWorkspace
            " to=D" workspace " map=" DebugWorkspaceSummary(monitor))
        MarkWorkspaceSwitchProgress("begin")

        if externalActivatedHwnd
            PrepareShieldedExternalActivation(
                externalActivatedHwnd, monitor, workspace)

        ; Discover newly opened windows before changing what is visible.
        LearnVisibleWindows()

        if workspace = oldWorkspace {
            DebugLog("SWITCH_SAME", "monitor=" monitor " workspace=D" workspace)
            ShowWorkspaceOverlay(monitor, workspace, 0)
            SetTimer(VerifyWorkspaceTransition.Bind(monitor, workspace, 0), -200)
            return true
        }

        if direction = 0
            direction := workspace > oldWorkspace ? 1 : -1

        ; Preserve the complete top-to-bottom stack before any outgoing app is
        ; hidden. This prevents the order of asynchronous show acknowledgements
        ; from deciding which maximized app appears on top when we return.
        RememberWorkspaceWindowOrder(monitor, oldWorkspace)

        ; A native title-bar drag must never be hidden or covered by the slide.
        ; Resolve at execution time so queued requests cannot carry a window
        ; after the user has already released it.
        draggedHwnd := GetDraggedWorkspaceWindow()
        if draggedHwnd {
            CarryWindowToWorkspace(draggedHwnd, monitor, workspace)
            CancelTaskbarActivationShield(monitor, 0, "window-drag")
        }

        ; The animation layer owns captured window surfaces while the real
        ; outgoing windows are hidden underneath it.
        animationDuration := rapid ? RAPID_WORKSPACE_SLIDE_MS : WORKSPACE_SLIDE_MS
        animation := BeginWorkspaceSlideAnimation(
            monitor, oldWorkspace, workspace, direction, animationDuration, draggedHwnd)
        MarkWorkspaceSwitchProgress("animation-ready")
        if externalActivatedHwnd && animation
            CancelTaskbarActivationShield(monitor, 0, "animation-handoff")

        ; First hide every non-target window. Incoming windows remain hidden
        ; until their captured surfaces finish sliding into place.
        hiddenWindows := []
        for hwnd, slot in WindowWorkspace.Clone() {
            if !WinExist("ahk_id " hwnd) {
                ForgetWindow(hwnd)
                continue
            }
            if slot.monitor != monitor
                continue

            if slot.workspace = workspace
                continue

            if IsVisible(hwnd) && (OverviewPreviewMode || IsManageableWindow(hwnd)) {
                DebugLog("SWITCH_HIDE", "target=D" workspace " assigned=D" slot.workspace
                    " " DebugDescribeWindow(hwnd))
                if !animation
                    CaptureWindowSnapshot(hwnd)
                HideWindowFast(hwnd)
                HiddenByScript[hwnd] := true
                hiddenWindows.Push(hwnd)
            } else {
                DebugLog("SWITCH_SKIP", "target=D" workspace " assigned=D" slot.workspace
                    " visible=" IsVisible(hwnd) " manageable=" IsManageableWindow(hwnd)
                    " scriptHidden=" HiddenByScript.Has(hwnd) " " DebugDescribeWindow(hwnd))
            }
        }

        MarkWorkspaceSwitchProgress("windows-hidden")

        ; Keep an opaque animation frame in place until every app that this
        ; script hid has acknowledged its show request. A fixed delay races
        ; slower application UI threads and exposes only the first app to
        ; respond. Restore the saved window stack while it is still covered.
        ; An uncached workspace is revealed under the outgoing frame before the
        ; slide, so it slides in exactly as it will look, shadows included,
        ; even for windows hidden since before the engine started.
        revealed := false
        if animation && animation.incomingPending {
            RevealWorkspaceForHandoff(monitor, workspace, 260, draggedHwnd, animation.hwnd)
            revealed := true
            MarkWorkspaceSwitchProgress("incoming-revealed")
            CompleteIncomingWorkspaceFrame(animation, hiddenWindows)
            MarkWorkspaceSwitchProgress("incoming-captured")
        }
        RunWorkspaceSlideAnimation(animation)
        MarkWorkspaceSwitchProgress("animation-complete")
        ; A drag holds topmost windows back from an early reveal; show them
        ; while the cover is still up.
        if !revealed || draggedHwnd && HasScriptHiddenWorkspaceWindows(monitor, workspace)
            RevealWorkspaceForHandoff(monitor, workspace, 260, draggedHwnd)
        MarkWorkspaceSwitchProgress("handoff-complete")
        FadeOutWorkspaceSlide(animation)
        EndWorkspaceSlideAnimation(animation)
        animation := false

        CurrentWorkspace[monitor] := workspace
        DebugLog("SWITCH_COMMIT", "monitor=" monitor " current=D" workspace
            " map=" DebugWorkspaceSummary(monitor))
        ShowWorkspaceOverlay(monitor, workspace, direction)
        ScheduleWorkspaceStateSave()
        SetTimer(VerifyWorkspaceTransition.Bind(monitor, workspace, 0), -200)
        switchSucceeded := true
    } catch as error {
        DebugLog("SWITCH_ERROR", "monitor=" monitor " target=D" workspace
            " message=" DebugClean(error.Message) " what=" DebugClean(error.What)
            " line=" error.Line)
        ScheduleWorkspaceEngineRestart(
            "switch-exception", monitor, workspace, direction)
    } finally {
        try EndWorkspaceSlideAnimation(animation)
        if externalActivatedHwnd
            CancelTaskbarActivationShield(monitor, 0, "switch-finalize")
        if WorkspaceSlideSkipRequests.Has(monitor)
            WorkspaceSlideSkipRequests.Delete(monitor)
        Switching := false
        SwitchingMonitor := 0
        SwitchingStartedAt := 0
        SwitchingLastProgressAt := 0
        SwitchingTargetWorkspace := 0
        SwitchingDirection := 0
        SwitchingSoftRecoveryRequested := false
        DebugLog("SWITCH_END", "monitor=" monitor " target=D" workspace
            " current=" (CurrentWorkspace.Has(monitor) ? "D" CurrentWorkspace[monitor] : "missing"))
        if PendingWorkspaceSwitches.Count
            SetTimer(ProcessPendingWorkspaceSwitches, -1)
    }
    return switchSucceeded
}

GetDraggedWorkspaceWindow() {
    ; GUITHREADINFO identifies the actual native move/size loop, avoiding
    ; false carries when selecting text, dragging a file, or holding a click.
    if !(DllCall("GetAsyncKeyState", "int", 0x01, "short") & 0x8000)
        return 0
    info := Buffer(24 + 6 * A_PtrSize, 0)
    NumPut("uint", info.Size, info, 0)
    if !DllCall("GetGUIThreadInfo", "uint", 0, "ptr", info, "int")
        return 0
    if !(NumGet(info, 4, "uint") & 0x02) ; GUI_INMOVESIZE
        return 0
    hwnd := NumGet(info, 8 + 4 * A_PtrSize, "ptr")
    return hwnd && IsVisible(hwnd) && IsManageableWindow(hwnd) ? hwnd : 0
}

AssignCarriedWorkspaceWindow(hwnd, monitor, workspace) {
    global WindowWorkspace
    if WindowWorkspace.Has(hwnd) {
        previous := WindowWorkspace[hwnd]
        InvalidateWorkspaceFrame(previous.monitor, previous.workspace)
    }
    InvalidateWorkspaceFrame(monitor, workspace)
    DeleteWindowSnapshot(hwnd)
    WindowWorkspace[hwnd] := {monitor: monitor, workspace: workspace}
    RememberWindowRestartIdentity(hwnd)
    PromoteWorkspaceWindow(monitor, workspace, hwnd)
    ScheduleWorkspaceStateSave()
}

CarryWindowToWorkspace(hwnd, monitor, workspace) {
    global CarriedWorkspaceWindow, PendingExternalActivations
    CarriedWorkspaceWindow := hwnd
    if PendingExternalActivations.Has(hwnd)
        PendingExternalActivations.Delete(hwnd)
    AssignCarriedWorkspaceWindow(hwnd, monitor, workspace)
    SetTimer(FinishWorkspaceWindowDrag, 30)
    DebugLog("DRAG_CARRY", "hwnd=" hwnd " monitor=" monitor " target=D" workspace)
}

FinishWorkspaceWindowDrag(*) {
    global CarriedWorkspaceWindow, CurrentWorkspace, Switching
    if Switching
        return
    hwnd := CarriedWorkspaceWindow
    if hwnd && GetDraggedWorkspaceWindow() = hwnd
        return
    SetTimer(FinishWorkspaceWindowDrag, 0)
    CarriedWorkspaceWindow := 0
    if !hwnd || !WinExist("ahk_id " hwnd)
        return
    ; A window can cross another display after the last shortcut. Commit to
    ; the display where it was dropped, using the usual window-monitor rule.
    monitor := GetWindowMonitor(hwnd)
    if CurrentWorkspace.Has(monitor) {
        AssignCarriedWorkspaceWindow(hwnd, monitor, CurrentWorkspace[monitor])
        DebugLog("DRAG_DROP", "hwnd=" hwnd " monitor=" monitor
            " workspace=D" CurrentWorkspace[monitor])
    }
}

PreviousWorkspace(*) {
    global CurrentWorkspace, RequestedWorkspace
    EnsureMonitorState()
    monitor := GetMonitorUnderMouse()
    baseWorkspace := RequestedWorkspace.Has(monitor)
        ? RequestedWorkspace[monitor] : CurrentWorkspace[monitor]
    nextWorkspace := GetAdjacentWorkspace(baseWorkspace, -1)
    if nextWorkspace = baseWorkspace {
        DebugLog("SWITCH_BOUNDARY", "monitor=" monitor
            " direction=-1 requested=D" baseWorkspace " boundary=D1")
        return
    }
    SwitchToWorkspace(nextWorkspace, -1)
}

NextWorkspace(*) {
    global WORKSPACE_COUNT, CurrentWorkspace, RequestedWorkspace
    EnsureMonitorState()
    monitor := GetMonitorUnderMouse()
    baseWorkspace := RequestedWorkspace.Has(monitor)
        ? RequestedWorkspace[monitor] : CurrentWorkspace[monitor]
    nextWorkspace := GetAdjacentWorkspace(baseWorkspace, 1)
    if nextWorkspace = baseWorkspace {
        DebugLog("SWITCH_BOUNDARY", "monitor=" monitor
            " direction=1 requested=D" baseWorkspace
            " boundary=D" WORKSPACE_COUNT)
        return
    }
    SwitchToWorkspace(nextWorkspace, 1)
}

GetAdjacentWorkspace(baseWorkspace, direction) {
    global WORKSPACE_COUNT
    return Max(1, Min(WORKSPACE_COUNT, baseWorkspace + direction))
}

RunNavigationBoundarySelfTest() {
    cases := [
        [1, -1, 1],
        [1, 1, 2],
        [2, -1, 1],
        [2, 1, 3],
        [3, -1, 2],
        [3, 1, 3]
    ]
    for testCase in cases {
        actual := GetAdjacentWorkspace(testCase[1], testCase[2])
        if actual != testCase[3] {
            FileAppend("Navigation boundary self-test failed: base=D"
                testCase[1] " direction=" testCase[2] " expected=D"
                testCase[3] " actual=D" actual "`n", "*")
            ExitApp(1)
        }
    }

    ; Repeated input is calculated from the latest requested D-number. Verify
    ; that extra presses remain pinned to each edge instead of wrapping.
    workspace := 1
    Loop 5
        workspace := GetAdjacentWorkspace(workspace, 1)
    if workspace != 3 {
        FileAppend("Navigation boundary self-test failed: repeated right ended at D"
            workspace "`n", "*")
        ExitApp(1)
    }
    Loop 5
        workspace := GetAdjacentWorkspace(workspace, -1)
    if workspace != 1 {
        FileAppend("Navigation boundary self-test failed: repeated left ended at D"
            workspace "`n", "*")
        ExitApp(1)
    }

    FileAppend("Navigation boundary self-test passed.`n", "*")
    ExitApp(0)
}

MoveActiveWindowToWorkspace(workspace, *) {
    global WORKSPACE_COUNT, CurrentWorkspace, WindowWorkspace, HiddenByScript

    if workspace < 1 || workspace > WORKSPACE_COUNT
        return

    hwnd := WinExist("A")
    if !hwnd || !IsManageableWindow(hwnd) {
        DebugLog("MOVE_REJECT", "target=D" workspace " hwnd=" hwnd
            " manageable=" (hwnd ? IsManageableWindow(hwnd) : false))
        return
    }
    if DisplayTopologyChanging() {
        DebugLog("MOVE_REJECT", "target=D" workspace " reason=display-change")
        return
    }

    EnsureMonitorState()
    monitor := GetWindowMonitor(hwnd)
    DebugLog("MOVE_ASSIGN", "target=D" workspace " monitor=" monitor " " DebugDescribeWindow(hwnd))
    if WindowWorkspace.Has(hwnd) {
        previousSlot := WindowWorkspace[hwnd]
        InvalidateWorkspaceFrame(previousSlot.monitor, previousSlot.workspace)
    }
    InvalidateWorkspaceFrame(monitor, workspace)
    WindowWorkspace[hwnd] := {monitor: monitor, workspace: workspace}
    RememberWindowRestartIdentity(hwnd)
    PromoteWorkspaceWindow(monitor, workspace, hwnd)
    ScheduleWorkspaceStateSave()

    if workspace != CurrentWorkspace[monitor] {
        CaptureWindowSnapshot(hwnd)
        HideWindowFast(hwnd)
        HiddenByScript[hwnd] := true
    }

    ShowFeedbackForMonitor(monitor, workspace, "Moved to")
}

ToggleWorkspaceOverview(*) {
    global WorkspaceOverview
    if WorkspaceOverview {
        DebugLog("OVERVIEW_TOGGLE", "action=close monitor=" WorkspaceOverview.monitor)
        CloseWorkspaceOverview()
        return
    }
    monitor := GetMonitorUnderMouse()
    DebugLog("OVERVIEW_TOGGLE", "action=open monitor=" monitor)
    ShowWorkspaceOverview(monitor)
}

ShowWorkspaceOverview(monitor := 0, *) {
    global WORKSPACE_COUNT, CurrentWorkspace, WorkspaceOverview, OverviewPreviewMode

    if WorkspaceOverview
        CloseWorkspaceOverview(false)
    if !OverviewPreviewMode && DisplayTopologyChanging() {
        DebugLog("OVERVIEW_REJECT", "reason=display-change")
        return
    }
    if !monitor
        monitor := GetMonitorUnderMouse()

    EnsureMonitorState()
    DebugLog("OVERVIEW_OPEN", "monitor=" monitor " current=D" CurrentWorkspace[monitor]
        " previousActive=" DebugDescribeWindow(WinExist("A")))
    if !OverviewPreviewMode
        LearnVisibleWindows()
    CancelWorkspaceOverlay(monitor)

    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    width := right - left
    height := bottom - top
    dpi := GetMonitorDpi(monitor)
    scaleRatio := dpi / A_ScreenDPI
    density := dpi / 96
    previousActive := WinExist("A")

    overview := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale")
    overview.BackColor := "070B14"
    overview.MarginX := 0
    overview.MarginY := 0
    overview.OnEvent("Escape", HandleOverviewEscape)
    overview.OnEvent("Close", HandleOverviewEscape)

    state := {
        gui: overview, hwnd: 0, monitor: monitor,
        left: left, top: top, width: width, height: height,
        dpi: dpi, density: density, scaleRatio: scaleRatio,
        previousActive: previousActive,
        paintRects: [], workspaceRects: [], windowRects: [],
        pendingThumbnails: [], thumbnails: [], snapshotDraws: []
    }
    WorkspaceOverview := state
    BuildWorkspaceOverview(state)

    showWidth := Max(1, Round(width / scaleRatio))
    showHeight := Max(1, Round(height / scaleRatio))
    overview.Show("x" left " y" top " w" showWidth " h" showHeight)
    state.hwnd := overview.Hwnd

    ; Lock the final destination to the monitor's exact physical work area.
    try DllCall("SetWindowPos", "ptr", state.hwnd, "ptr", -1,
        "int", left, "int", top, "int", width, "int", height,
        "uint", 0x0040)
    try DllCall("InvalidateRect", "ptr", state.hwnd, "ptr", 0, "int", true)

    for pending in state.pendingThumbnails
        RegisterOverviewThumbnail(state, pending)

    try WinActivate("ahk_id " state.hwnd)
    DebugLog("OVERVIEW_READY", "monitor=" monitor " hwnd=" state.hwnd
        " workspaceRects=" state.workspaceRects.Length
        " windowRects=" state.windowRects.Length)
}

BuildWorkspaceOverview(state) {
    global WORKSPACE_COUNT, CurrentWorkspace

    density := state.density
    outerPadding := Round(28 * density)
    panelGap := Round(18 * density)
    panelWidth := Floor((state.width - (outerPadding * 2) - (panelGap * (WORKSPACE_COUNT - 1))) / WORKSPACE_COUNT)
    panelHeight := state.height - (outerPadding * 2)
    headerHeight := Round(64 * density)
    innerPadding := Round(16 * density)
    tileGap := Round(12 * density)
    activeWorkspace := CurrentWorkspace.Has(state.monitor) ? CurrentWorkspace[state.monitor] : 1

    ; COLORREF values are BGR rather than RGB.
    state.paintRects.Push({x: 0, y: 0, w: state.width, h: state.height, color: 0x140B07})

    Loop WORKSPACE_COUNT {
        workspace := A_Index
        panelX := outerPadding + ((workspace - 1) * (panelWidth + panelGap))
        panelY := outerPadding
        border := Max(1, Round((workspace = activeWorkspace ? 3 : 1) * density))
        borderColor := workspace = activeWorkspace ? 0xEB6325 : 0x493729

        state.paintRects.Push({x: panelX, y: panelY, w: panelWidth, h: panelHeight, color: borderColor})
        state.paintRects.Push({
            x: panelX + border, y: panelY + border,
            w: panelWidth - (border * 2), h: panelHeight - (border * 2),
            color: 0x271811
        })
        state.workspaceRects.Push({x: panelX, y: panelY, w: panelWidth, h: panelHeight, workspace: workspace})

        windows := GetOverviewWindows(state.monitor, workspace)
        windowCount := windows.Length
        DebugLog("OVERVIEW_PANEL", "monitor=" state.monitor " workspace=D" workspace
            " windows=" windowCount " active=" (workspace = activeWorkspace))
        countLabel := windowCount = 1 ? "1 window" : windowCount " windows"
        AddOverviewText(state,
            panelX + innerPadding, panelY + Round(12 * density),
            panelWidth - (innerPadding * 2), Round(34 * density),
            "D" workspace, "s20 cFFFFFF w600", "Center +0x200 BackgroundTrans")
        AddOverviewText(state,
            panelX + innerPadding, panelY + Round(42 * density),
            panelWidth - (innerPadding * 2), Round(18 * density),
            countLabel, "s9 c94A3B8 w500", "Center +0x200 BackgroundTrans")

        contentX := panelX + innerPadding
        contentY := panelY + headerHeight
        contentWidth := panelWidth - (innerPadding * 2)
        contentHeight := panelHeight - headerHeight - innerPadding

        if !windowCount {
            AddOverviewText(state, contentX, contentY, contentWidth, contentHeight,
                "Empty", "s13 c64748B w500", "Center +0x200 BackgroundTrans")
            continue
        }

        visibleCount := Min(windowCount, 9)
        columns := visibleCount <= 2 ? 1 : visibleCount <= 6 ? 2 : 3
        rows := Ceil(visibleCount / columns)
        tileWidth := Floor((contentWidth - (tileGap * (columns - 1))) / columns)
        tileHeight := Floor((contentHeight - (tileGap * (rows - 1))) / rows)
        titleHeight := Round(30 * density)

        Loop visibleCount {
            itemIndex := A_Index
            hwnd := windows[itemIndex]
            DebugLog("OVERVIEW_ITEM", "monitor=" state.monitor " workspace=D" workspace
                " item=" itemIndex " " DebugDescribeWindow(hwnd))
            column := Mod(itemIndex - 1, columns)
            row := Floor((itemIndex - 1) / columns)
            tileX := contentX + (column * (tileWidth + tileGap))
            tileY := contentY + (row * (tileHeight + tileGap))
            previewInset := Round(7 * density)
            previewRect := {
                x: tileX + previewInset,
                y: tileY + previewInset,
                w: tileWidth - (previewInset * 2),
                h: Max(1, tileHeight - titleHeight - (previewInset * 2))
            }

            state.paintRects.Push({x: tileX, y: tileY, w: tileWidth, h: tileHeight, color: 0x20120B})
            state.windowRects.Push({
                x: tileX, y: tileY, w: tileWidth, h: tileHeight,
                workspace: workspace, hwnd: hwnd
            })

            title := GetOverviewWindowTitle(hwnd)
            AddOverviewText(state,
                tileX + previewInset, tileY + tileHeight - titleHeight,
                tileWidth - (previewInset * 2), titleHeight,
                title, "s9 cE2E8F0 w500", "Center +0x200 +0x4000 BackgroundTrans")
            state.pendingThumbnails.Push({hwnd: hwnd, rect: previewRect})
        }
    }
}

GetOverviewWindows(monitor, workspace) {
    global WindowWorkspace
    result := []
    seen := Map()

    for hwnd in WinGetList() {
        if !WindowWorkspace.Has(hwnd)
            continue
        slot := WindowWorkspace[hwnd]
        if slot.monitor != monitor || slot.workspace != workspace
            continue
        if !WinExist("ahk_id " hwnd)
            continue
        result.Push(hwnd)
        seen[hwnd] := true
    }

    for hwnd, slot in WindowWorkspace {
        if seen.Has(hwnd) || slot.monitor != monitor || slot.workspace != workspace
            continue
        if WinExist("ahk_id " hwnd)
            result.Push(hwnd)
    }
    return result
}

GetOverviewWindowTitle(hwnd) {
    try title := Trim(WinGetTitle("ahk_id " hwnd))
    catch
        title := ""
    if title
        return title
    try return WinGetProcessName("ahk_id " hwnd)
    catch
        return "Window"
}

AddOverviewText(state, x, y, width, height, text, fontOptions, controlOptions := "") {
    options := OverviewRectOptions(x, y, width, height, state.scaleRatio)
    if controlOptions
        options .= " " controlOptions
    control := state.gui.AddText(options, text)
    control.SetFont(fontOptions, "Segoe UI")
    return control
}

OverviewRectOptions(x, y, width, height, scaleRatio) {
    return "x" Round(x / scaleRatio)
        . " y" Round(y / scaleRatio)
        . " w" Max(1, Round(width / scaleRatio))
        . " h" Max(1, Round(height / scaleRatio))
}

RegisterOverviewThumbnail(state, pending) {
    global HiddenByScript, WindowSnapshots

    if HiddenByScript.Has(pending.hwnd) && WindowSnapshots.Has(pending.hwnd) {
        snapshot := WindowSnapshots[pending.hwnd]
        destination := FitOverviewRect(snapshot.width, snapshot.height, pending.rect)
        state.snapshotDraws.Push({snapshot: snapshot, rect: destination})
        try DllCall("InvalidateRect", "ptr", state.hwnd, "ptr", 0, "int", true)
        return true
    }

    ; A live thumbnail of a hidden window is empty. One hidden since before the
    ; engine started has no snapshot until its workspace is next shown.
    thumbnail := 0
    result := -1
    if !HiddenByScript.Has(pending.hwnd)
        try result := DllCall("dwmapi\DwmRegisterThumbnail",
            "ptr", state.hwnd, "ptr", pending.hwnd, "ptr*", &thumbnail, "int")

    if result != 0 || !thumbnail {
        AddOverviewText(state,
            pending.rect.x, pending.rect.y, pending.rect.w, pending.rect.h,
            "Preview unavailable", "s10 c64748B w500", "Center +0x200 BackgroundTrans")
        return false
    }

    sourceWidth := 0
    sourceHeight := 0
    clientRect := Buffer(16, 0)
    if DllCall("GetClientRect", "ptr", pending.hwnd, "ptr", clientRect.Ptr) {
        sourceWidth := NumGet(clientRect, 8, "int")
        sourceHeight := NumGet(clientRect, 12, "int")
    }
    if sourceWidth <= 0 || sourceHeight <= 0 {
        sourceSize := Buffer(8, 0)
        if DllCall("dwmapi\DwmQueryThumbnailSourceSize", "ptr", thumbnail, "ptr", sourceSize.Ptr, "int") = 0 {
            sourceWidth := NumGet(sourceSize, 0, "int")
            sourceHeight := NumGet(sourceSize, 4, "int")
        }
    }

    if sourceWidth <= 0 || sourceHeight <= 0 {
        DllCall("dwmapi\DwmUnregisterThumbnail", "ptr", thumbnail)
        return false
    }

    destination := FitOverviewRect(sourceWidth, sourceHeight, pending.rect)
    drawX := destination.x
    drawY := destination.y
    drawWidth := destination.w
    drawHeight := destination.h

    ; DWM_THUMBNAIL_PROPERTIES: flags, destination/source RECTs, opacity, visibility.
    properties := Buffer(48, 0)
    NumPut("uint", 0x1D, properties, 0)
    NumPut("int", drawX, "int", drawY,
        "int", drawX + drawWidth, "int", drawY + drawHeight, properties, 4)
    NumPut("uchar", 255, properties, 36)
    NumPut("int", 1, properties, 40)
    NumPut("int", 1, properties, 44)

    result := DllCall("dwmapi\DwmUpdateThumbnailProperties",
        "ptr", thumbnail, "ptr", properties.Ptr, "int")
    if result != 0 {
        DllCall("dwmapi\DwmUnregisterThumbnail", "ptr", thumbnail)
        return false
    }

    state.thumbnails.Push(thumbnail)
    return true
}

FitOverviewRect(sourceWidth, sourceHeight, bounds) {
    fit := Min(bounds.w / sourceWidth, bounds.h / sourceHeight)
    width := Max(1, Round(sourceWidth * fit))
    height := Max(1, Round(sourceHeight * fit))
    return {
        x: bounds.x + Floor((bounds.w - width) / 2),
        y: bounds.y + Floor((bounds.h - height) / 2),
        w: width, h: height
    }
}

PaintWorkspaceOverview(wParam, lParam, msg, hwnd) {
    global WorkspaceOverview, WorkspaceSlideAnimations
    if WorkspaceSlideAnimations.Has(hwnd) {
        PaintWorkspaceSlide(hwnd)
        return 0
    }
    if PaintTaskbarActivationShield(hwnd)
        return 0
    if !WorkspaceOverview || !WorkspaceOverview.hwnd || hwnd != WorkspaceOverview.hwnd
        return

    state := WorkspaceOverview
    paint := Buffer(72, 0)
    hdc := DllCall("BeginPaint", "ptr", hwnd, "ptr", paint.Ptr, "ptr")
    if !hdc
        return

    for item in state.paintRects {
        rect := Buffer(16, 0)
        NumPut("int", item.x, "int", item.y,
            "int", item.x + item.w, "int", item.y + item.h, rect, 0)
        brush := DllCall("CreateSolidBrush", "uint", item.color, "ptr")
        DllCall("FillRect", "ptr", hdc, "ptr", rect.Ptr, "ptr", brush)
        DllCall("DeleteObject", "ptr", brush)
    }

    for item in state.snapshotDraws
        DrawOverviewSnapshot(hdc, item.snapshot, item.rect)
    DllCall("EndPaint", "ptr", hwnd, "ptr", paint.Ptr)
    return 0
}

HandleWorkspaceSlideEraseBackground(wParam, lParam, msg, hwnd) {
    global WorkspaceSlideAnimations, TaskbarActivationShields
    if WorkspaceSlideAnimations.Has(hwnd)
        return 1
    for monitor, state in TaskbarActivationShields {
        if state.hwnd = hwnd
            return 1
    }
}

DrawOverviewSnapshot(destinationDc, snapshot, rect, source := false) {
    if !source
        source := {x: 0, y: 0, w: snapshot.width, h: snapshot.height}
    sourceDc := DllCall("CreateCompatibleDC", "ptr", destinationDc, "ptr")
    if !sourceDc
        return
    oldBitmap := DllCall("SelectObject", "ptr", sourceDc, "ptr", snapshot.bitmap, "ptr")
    DllCall("SetStretchBltMode", "ptr", destinationDc, "int", 4)
    DllCall("StretchBlt",
        "ptr", destinationDc, "int", rect.x, "int", rect.y, "int", rect.w, "int", rect.h,
        "ptr", sourceDc, "int", source.x, "int", source.y, "int", source.w, "int", source.h,
        "uint", 0x00CC0020)
    DllCall("SelectObject", "ptr", sourceDc, "ptr", oldBitmap)
    DllCall("DeleteDC", "ptr", sourceDc)
}

HandleOverviewClick(wParam, lParam, msg, hwnd) {
    global WorkspaceOverview
    if !WorkspaceOverview || !WorkspaceOverview.hwnd
        return

    state := WorkspaceOverview
    if hwnd != state.hwnd && !DllCall("IsChild", "ptr", state.hwnd, "ptr", hwnd)
        return

    point := Buffer(8, 0)
    if !DllCall("GetCursorPos", "ptr", point.Ptr)
        return
    if !DllCall("ScreenToClient", "ptr", state.hwnd, "ptr", point.Ptr)
        return
    x := NumGet(point, 0, "int")
    y := NumGet(point, 4, "int")
    DebugLog("OVERVIEW_CLICK", "messageHwnd=" hwnd " overviewHwnd=" state.hwnd
        " monitor=" state.monitor " client=" x "," y)

    for item in state.windowRects {
        if PointInsideOverviewRect(x, y, item) {
            targetHwnd := item.hwnd
            targetWorkspace := item.workspace
            targetMonitor := state.monitor
            DebugLog("OVERVIEW_WINDOW_HIT", "workspace=D" targetWorkspace
                " monitor=" targetMonitor " rect=" item.x "," item.y "," item.w "," item.h
                " " DebugDescribeWindow(targetHwnd))
            CloseWorkspaceOverview(false)
            ; Finish the workspace transition outside WM_LBUTTONUP. The selected
            ; window is revealed only after that transition is confirmed.
            SetTimer(CompleteOverviewWindowSelection.Bind(
                targetHwnd, targetWorkspace, targetMonitor, 0), -1)
            return 0
        }
    }

    for item in state.workspaceRects {
        if PointInsideOverviewRect(x, y, item) {
            targetWorkspace := item.workspace
            targetMonitor := state.monitor
            DebugLog("OVERVIEW_PANEL_HIT", "workspace=D" targetWorkspace
                " monitor=" targetMonitor " rect=" item.x "," item.y "," item.w "," item.h)
            CloseWorkspaceOverview(false)
            SwitchToWorkspaceOnMonitor(targetWorkspace, targetMonitor)
            return 0
        }
    }

    DebugLog("OVERVIEW_CLICK_MISS", "monitor=" state.monitor " client=" x "," y)
    CloseWorkspaceOverview()
    return 0
}

PointInsideOverviewRect(x, y, rect) {
    return x >= rect.x && x < rect.x + rect.w
        && y >= rect.y && y < rect.y + rect.h
}

CompleteOverviewWindowSelection(hwnd, workspace, monitor, attempt := 0) {
    global CurrentWorkspace, Switching
    DebugLog("SELECTION_STEP", "attempt=" attempt " workspace=D" workspace
        " monitor=" monitor " switching=" Switching " current="
        (CurrentWorkspace.Has(monitor) ? "D" CurrentWorkspace[monitor] : "missing")
        " " DebugDescribeWindow(hwnd))
    if !WinExist("ahk_id " hwnd) {
        DebugLog("SELECTION_ABORT", "reason=window-gone hwnd=" hwnd)
        return
    }

    ; A hotkey or another monitor may already be switching. Wait for it to
    ; finish instead of revealing one window on the currently displayed D-slot.
    if Switching {
        DebugLog("SELECTION_WAIT", "reason=switch-in-progress attempt=" attempt)
        if attempt < 10
            SetTimer(CompleteOverviewWindowSelection.Bind(
                hwnd, workspace, monitor, attempt + 1), -50)
        return
    }

    switched := SwitchToWorkspaceOnMonitor(workspace, monitor)
    if !switched || !CurrentWorkspace.Has(monitor)
        || CurrentWorkspace[monitor] != workspace {
        DebugLog("SELECTION_WAIT", "reason=switch-not-committed switched=" switched
            " expected=D" workspace " actual="
            (CurrentWorkspace.Has(monitor) ? "D" CurrentWorkspace[monitor] : "missing")
            " attempt=" attempt)
        if attempt < 10
            SetTimer(CompleteOverviewWindowSelection.Bind(
                hwnd, workspace, monitor, attempt + 1), -50)
        return
    }

    DebugLog("SELECTION_COMMITTED", "workspace=D" workspace " monitor=" monitor
        " activationDelayMs=80 " DebugDescribeWindow(hwnd))
    SetTimer(ActivateOverviewWindow.Bind(hwnd, monitor, workspace, 0), -80)
}

ActivateOverviewWindow(hwnd, monitor, workspace, attempt := 0) {
    global CurrentWorkspace, HiddenByScript
    DebugLog("ACTIVATE_ATTEMPT", "attempt=" attempt " workspace=D" workspace
        " monitor=" monitor " current="
        (CurrentWorkspace.Has(monitor) ? "D" CurrentWorkspace[monitor] : "missing")
        " activeHwnd=" WinExist("A") " " DebugDescribeWindow(hwnd))
    if !WinExist("ahk_id " hwnd) {
        DebugLog("ACTIVATE_ABORT", "reason=window-gone hwnd=" hwnd)
        return
    }

    ; Do not leak the selected window into another workspace if the user starts
    ; a new switch during the short activation delay or focus retry period.
    if !CurrentWorkspace.Has(monitor) || CurrentWorkspace[monitor] != workspace {
        DebugLog("ACTIVATE_ABORT", "reason=workspace-mismatch expected=D" workspace
            " actual=" (CurrentWorkspace.Has(monitor) ? "D" CurrentWorkspace[monitor] : "missing"))
        return
    }

    if HiddenByScript.Has(hwnd)
        HiddenByScript.Delete(hwnd)

    try minimized := WinGetMinMax("ahk_id " hwnd) = -1
    catch
        minimized := false
    ; A direct restore/show is intentional here: clicking a preview means the
    ; user explicitly wants that exact window in the foreground. A hung app
    ; gets the same request posted, so it cannot freeze the engine.
    if IsWindowResponsive(hwnd) {
        try DllCall("ShowWindow", "ptr", hwnd, "int", minimized ? 9 : 5)
        if minimized
            try WinRestore("ahk_id " hwnd)
        try WinActivate("ahk_id " hwnd)
    } else
        try DllCall("ShowWindowAsync", "ptr", hwnd, "int", minimized ? 9 : 5)
    try DllCall("SetForegroundWindow", "ptr", hwnd)

    ; Focusing some applications can briefly cover a newly created overlay.
    ; Refresh it after focus so app-preview clicks visibly confirm D1/D2/D3,
    ; exactly like the numbered and previous/next hotkeys.
    if attempt = 0
        ShowWorkspaceOverlay(monitor, workspace, 0)

    activated := WinActive("ahk_id " hwnd) != 0
    if activated {
        PromoteWorkspaceWindow(monitor, workspace, hwnd)
        ScheduleWorkspaceStateSave()
    }
    DebugLog("ACTIVATE_RESULT", "attempt=" attempt " activated=" activated
        " activeHwnd=" WinExist("A") " visible=" IsVisible(hwnd)
        " scriptHidden=" HiddenByScript.Has(hwnd) " " DebugDescribeWindow(hwnd))
    if !activated && attempt < 5
        SetTimer(ActivateOverviewWindow.Bind(
            hwnd, monitor, workspace, attempt + 1), -120)
}

IsPointerOverTaskbarAppList(*) {
    MouseGetPos(&x, &y)
    for hwnd in WinGetList("ahk_class MSTaskListWClass") {
        if !IsVisible(hwnd)
            continue
        rect := Buffer(16, 0)
        if !DllCall("GetWindowRect", "ptr", hwnd, "ptr", rect.Ptr)
            continue
        if x >= NumGet(rect, 0, "int") && x < NumGet(rect, 8, "int")
            && y >= NumGet(rect, 4, "int") && y < NumGet(rect, 12, "int")
            return true
    }
    return false
}

RegisterTaskbarClickHotkeys() {
    HotIf(IsPointerOverTaskbarAppList)
    Hotkey("$LButton", HandleTaskbarAppMouseDown)
    Hotkey("$LButton Up", HandleTaskbarAppMouseUp)
    HotIf()
}

HandleTaskbarAppMouseDown(*) {
    BeginTaskbarActivationShield(GetMonitorUnderMouse())
    SendEvent("{LButton Down}")
}

HandleTaskbarAppMouseUp(*) {
    SendEvent("{LButton Up}")
    SetTimer(CancelUnclaimedTaskbarActivationShields, -180)
}

BeginTaskbarActivationShield(monitor) {
    global CurrentWorkspace, Switching, WorkspaceOverview
    global ExternalActivationHandling, TaskbarActivationShields
    if Switching || WorkspaceOverview || ExternalActivationHandling
        return false
    EnsureMonitorState()
    CancelTaskbarActivationShield(monitor, 0, "replace")

    workspace := CurrentWorkspace[monitor]
    captureStarted := A_TickCount
    frame := CaptureMonitorWorkspaceFrame(monitor, workspace)
    if !frame
        return false
    bitmap := DuplicateWorkspaceBitmap(frame.bitmap, frame.width, frame.height)
    if !bitmap
        return false

    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    layer := CreatePhysicalPixelLayer()
    state := {
        gui: layer, hwnd: layer.Hwnd, monitor: monitor, workspace: workspace,
        left: left, top: top, width: right - left, height: bottom - top,
        bitmap: bitmap, claimed: false, startedAt: A_TickCount
    }
    TaskbarActivationShields[monitor] := state
    ; Position the hidden HWND in physical pixels first. Gui.Show() interprets
    ; dimensions through the GUI DPI and can expose one scaled frame before a
    ; corrective SetWindowPos on mixed-scaling displays.
    try DllCall("SetWindowPos", "ptr", state.hwnd, "ptr", -1,
        "int", left, "int", top, "int", state.width, "int", state.height,
        "uint", 0x0010)
    try DllCall("SetWindowPos", "ptr", state.hwnd, "ptr", -1,
        "int", left, "int", top, "int", state.width, "int", state.height,
        "uint", 0x0050)
    PresentTaskbarActivationShield(state)
    try DllCall("dwmapi\DwmFlush")
    DebugLog("TASKBAR_SHIELD_BEGIN", "monitor=" monitor
        " workspace=D" workspace " hwnd=" state.hwnd
        " resolution=" state.width "x" state.height
        " geometry=" DebugWindowRenderGeometry(state.hwnd)
        " preparationMs=" (A_TickCount - captureStarted))
    SetTimer(CancelTaskbarActivationShield.Bind(
        monitor, state.hwnd, "timeout"), -900)
    return true
}

DuplicateWorkspaceBitmap(sourceBitmap, width, height) {
    screenDc := DllCall("GetDC", "ptr", 0, "ptr")
    sourceDc := screenDc ? DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr") : 0
    destinationDc := screenDc ? DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr") : 0
    bitmap := screenDc ? DllCall("CreateCompatibleBitmap", "ptr", screenDc,
        "int", width, "int", height, "ptr") : 0
    if !screenDc || !sourceDc || !destinationDc || !bitmap {
        if bitmap
            DllCall("DeleteObject", "ptr", bitmap)
        if sourceDc
            DllCall("DeleteDC", "ptr", sourceDc)
        if destinationDc
            DllCall("DeleteDC", "ptr", destinationDc)
        if screenDc
            DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
        return 0
    }
    oldSource := DllCall("SelectObject", "ptr", sourceDc, "ptr", sourceBitmap, "ptr")
    oldDestination := DllCall("SelectObject", "ptr", destinationDc, "ptr", bitmap, "ptr")
    copied := DllCall("BitBlt", "ptr", destinationDc,
        "int", 0, "int", 0, "int", width, "int", height,
        "ptr", sourceDc, "int", 0, "int", 0, "uint", 0x00CC0020, "int")
    DllCall("SelectObject", "ptr", sourceDc, "ptr", oldSource)
    DllCall("SelectObject", "ptr", destinationDc, "ptr", oldDestination)
    DllCall("DeleteDC", "ptr", sourceDc)
    DllCall("DeleteDC", "ptr", destinationDc)
    DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
    if !copied {
        DllCall("DeleteObject", "ptr", bitmap)
        return 0
    }
    return bitmap
}

PresentTaskbarActivationShield(state, destinationDc := 0) {
    sourceDc := DllCall("CreateCompatibleDC", "ptr", destinationDc ? destinationDc : 0, "ptr")
    if !sourceDc
        return false
    oldBitmap := DllCall("SelectObject", "ptr", sourceDc, "ptr", state.bitmap, "ptr")
    releaseDestination := false
    if !destinationDc {
        destinationDc := DllCall("GetDC", "ptr", state.hwnd, "ptr")
        releaseDestination := true
    }
    copied := destinationDc ? DllCall("BitBlt", "ptr", destinationDc,
        "int", 0, "int", 0, "int", state.width, "int", state.height,
        "ptr", sourceDc, "int", 0, "int", 0, "uint", 0x00CC0020, "int") : 0
    DllCall("SelectObject", "ptr", sourceDc, "ptr", oldBitmap)
    DllCall("DeleteDC", "ptr", sourceDc)
    if releaseDestination && destinationDc
        DllCall("ReleaseDC", "ptr", state.hwnd, "ptr", destinationDc)
    return copied != 0
}

PaintTaskbarActivationShield(hwnd) {
    global TaskbarActivationShields
    for monitor, state in TaskbarActivationShields {
        if state.hwnd != hwnd
            continue
        paint := Buffer(72, 0)
        hdc := DllCall("BeginPaint", "ptr", hwnd, "ptr", paint.Ptr, "ptr")
        if hdc {
            PresentTaskbarActivationShield(state, hdc)
            DllCall("EndPaint", "ptr", hwnd, "ptr", paint.Ptr)
        }
        return true
    }
    return false
}

CancelUnclaimedTaskbarActivationShields(*) {
    global TaskbarActivationShields
    for monitor, state in TaskbarActivationShields.Clone() {
        if !state.claimed
            CancelTaskbarActivationShield(monitor, state.hwnd, "unclaimed")
    }
}

CancelTaskbarActivationShield(monitor, expectedHwnd := 0, reason := "cancel", *) {
    global TaskbarActivationShields
    if !TaskbarActivationShields.Has(monitor)
        return
    state := TaskbarActivationShields[monitor]
    if expectedHwnd && state.hwnd != expectedHwnd
        return
    TaskbarActivationShields.Delete(monitor)
    try state.gui.Destroy()
    if state.bitmap
        try DllCall("DeleteObject", "ptr", state.bitmap)
    DebugLog("TASKBAR_SHIELD_END", "monitor=" monitor
        " workspace=D" state.workspace " reason=" reason
        " elapsedMs=" (A_TickCount - state.startedAt))
}

ClearTaskbarActivationShields(reason := "clear") {
    global TaskbarActivationShields
    for monitor in TaskbarActivationShields.Clone()
        CancelTaskbarActivationShield(monitor, 0, reason)
}

PrepareShieldedExternalActivation(hwnd, monitor, workspace) {
    global WindowWorkspace, HiddenByScript, TaskbarActivationShields
    if !TaskbarActivationShields.Has(monitor)
        return false
    if !WinExist("ahk_id " hwnd) || !WindowWorkspace.Has(hwnd)
        return false
    slot := WindowWorkspace[hwnd]
    if slot.monitor != monitor || slot.workspace != workspace
        return false

    startedAt := A_TickCount
    HiddenByScript[hwnd] := true
    if IsVisible(hwnd)
        HideWindowFast(hwnd)
    while IsVisible(hwnd) && A_TickCount - startedAt < 120
        Sleep(4)
    hidden := !IsVisible(hwnd)
    DebugLog("TASKBAR_SHIELD_PREPARE", "monitor=" monitor
        " workspace=D" workspace " hidden=" hidden
        " elapsedMs=" (A_TickCount - startedAt) " hwnd=" hwnd)
    return hidden
}

CheckExternalWorkspaceActivation(*) {
    global Switching, ExternalActivationHandling, WorkspaceOverview
    if Switching || ExternalActivationHandling || WorkspaceOverview
        return
    foregroundHwnd := WinExist("A")
    hwnd := ResolveTrackedWorkspaceWindow(foregroundHwnd)
    if !hwnd || !IsVisible(hwnd)
        return
    QueueExternalWorkspaceActivation(hwnd, "poll", 0)
}

InstallForegroundWinEventHook() {
    global ForegroundWinEventCallback, ForegroundWinEventHook
    if ForegroundWinEventHook
        return true
    try {
        ForegroundWinEventCallback := CallbackCreate(HandleForegroundWinEvent,, 7)
        ; EVENT_SYSTEM_FOREGROUND = 3. Out-of-context delivery keeps this hook
        ; isolated from application UI threads while arriving before polling or
        ; the next ordinary AutoHotkey timer tick.
        ForegroundWinEventHook := DllCall("SetWinEventHook",
            "uint", 3, "uint", 3, "ptr", 0,
            "ptr", ForegroundWinEventCallback,
            "uint", 0, "uint", 0, "uint", 0, "ptr")
        if !ForegroundWinEventHook
            throw Error("SetWinEventHook returned null")
        DebugLog("FOREGROUND_HOOK_INSTALL", "result=ok hook=" ForegroundWinEventHook)
        return true
    } catch as error {
        DebugLog("FOREGROUND_HOOK_ERROR", "message=" DebugClean(error.Message))
        if ForegroundWinEventCallback {
            try CallbackFree(ForegroundWinEventCallback)
            ForegroundWinEventCallback := 0
        }
        ForegroundWinEventHook := 0
        return false
    }
}

RemoveForegroundWinEventHook() {
    global ForegroundWinEventCallback, ForegroundWinEventHook
    if ForegroundWinEventHook {
        try DllCall("UnhookWinEvent", "ptr", ForegroundWinEventHook)
        ForegroundWinEventHook := 0
    }
    if ForegroundWinEventCallback {
        try CallbackFree(ForegroundWinEventCallback)
        ForegroundWinEventCallback := 0
    }
}

HandleForegroundWinEvent(hook, event, foregroundHwnd, objectId,
    childId, eventThread, eventTime) {
    if event != 3 || !foregroundHwnd
        return
    hwnd := ResolveTrackedWorkspaceWindow(foregroundHwnd)
    if hwnd
        QueueExternalWorkspaceActivation(hwnd, "win-event", eventTime)
}

QueueExternalWorkspaceActivation(hwnd, source, eventTime := 0) {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    global PendingExternalActivations, TaskbarActivationShields
    global ExternalActivationHandling
    global CarriedWorkspaceWindow
    if hwnd && hwnd = CarriedWorkspaceWindow
        return false
    if ExternalActivationHandling
        return true
    if !hwnd || !WindowWorkspace.Has(hwnd)
        return false

    slot := WindowWorkspace[hwnd]
    if !CurrentWorkspace.Has(slot.monitor)
        return false
    current := CurrentWorkspace[slot.monitor]
    if slot.workspace = current
        return false
    ; Focus on an overlay never moves the monitor, including in the moment
    ; before the background scan releases a window that has become one.
    if !IsWorkspaceWindowKind(hwnd)
        return false
    ; Windows activates windows it moves off a disconnecting monitor, and
    ; monitor numbers are stale until the change settles.
    if DisplayTopologyChanging()
        return false
    if SuppressRestartActivation(hwnd, slot)
        return true
    if PendingExternalActivations.Has(hwnd)
        return true
    if TaskbarActivationShields.Has(slot.monitor) {
        shield := TaskbarActivationShields[slot.monitor]
        if shield.workspace = current
            shield.claimed := true
    }

    ; Windows has already made this app visible before it sends either the
    ; foreground event or the polling fallback. Keep that frame in place and
    ; adopt its assigned workspace atomically; hiding it here would cause a
    ; visible reopen followed by a second slide.
    detectedAt := A_TickCount
    wasVisible := IsVisible(hwnd)
    PendingExternalActivations[hwnd] := {
        source: source, eventTime: eventTime, queuedAt: detectedAt
    }
    shielded := TaskbarActivationShields.Has(slot.monitor)
        && TaskbarActivationShields[slot.monitor].claimed
    DebugLog("EXTERNAL_ACTIVATION_INTERCEPT", "source=" source
        " eventTime=" eventTime " detectedAt=" detectedAt
        " wasVisible=" wasVisible " action="
        (shielded ? "shielded-slide" : "adopt-without-slide")
        " monitor=" slot.monitor " current=D" current
        " assigned=D" slot.workspace " hwnd=" hwnd)
    SetTimer(ProcessPendingExternalActivations, -1)
    return true
}

ProcessPendingExternalActivations(*) {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    global Switching, WorkspaceOverview, ExternalActivationHandling
    global PendingExternalActivations, TaskbarActivationShields, DisplayTopologyPending
    if !PendingExternalActivations.Count
        return
    if DisplayTopologyPending {
        PendingExternalActivations.Clear()
        return
    }
    if ExternalActivationHandling || Switching || WorkspaceOverview {
        SetTimer(ProcessPendingExternalActivations, -15)
        return
    }

    for hwnd, request in PendingExternalActivations.Clone() {
        PendingExternalActivations.Delete(hwnd)
        if !WinExist("ahk_id " hwnd) || !WindowWorkspace.Has(hwnd)
            continue
        slot := WindowWorkspace[hwnd]
        if !CurrentWorkspace.Has(slot.monitor)
            continue
        current := CurrentWorkspace[slot.monitor]

        ; A concurrently finishing hotkey may already have reached the app's
        ; workspace after the event was queued. Reveal/focus it without starting
        ; a redundant transition.
        if slot.workspace = current {
            if HiddenByScript.Has(hwnd) {
                ShowWindowFast(hwnd)
                HiddenByScript.Delete(hwnd)
            }
            SetTimer(ActivateOverviewWindow.Bind(
                hwnd, slot.monitor, slot.workspace, 0), -20)
            continue
        }

        ; The engine hides every window it parks on another workspace. One it
        ; never hid was hidden by its own app, like Telegram's reused media
        ; viewer or a tray app, and the app is opening it again now. It opens
        ; where the user is, as a new window would.
        if !HiddenByScript.Has(hwnd) {
            monitor := GetWindowMonitor(hwnd)
            if !CurrentWorkspace.Has(monitor)
                monitor := slot.monitor
            workspace := CurrentWorkspace[monitor]
            WindowWorkspace[hwnd] := {monitor: monitor, workspace: workspace}
            PromoteWorkspaceWindow(monitor, workspace, hwnd)
            InvalidateWorkspaceFrame(slot.monitor, slot.workspace)
            InvalidateWorkspaceFrame(monitor, workspace)
            ScheduleWorkspaceStateSave()
            DebugLog("EXTERNAL_ACTIVATION_REOPEN", "source=" request.source
                " fromMonitor=" slot.monitor " fromWorkspace=D" slot.workspace
                " toMonitor=" monitor " toWorkspace=D" workspace
                " " DebugDescribeWindow(hwnd))
            continue
        }

        ExternalActivationHandling := true
        try {
            DebugLog("EXTERNAL_ACTIVATION_DETECT", "source=" request.source
                " queuedMs=" (A_TickCount - request.queuedAt)
                " trackedHwnd=" hwnd " monitor=" slot.monitor
                " current=D" current " assigned=D" slot.workspace
                " scriptHidden=" HiddenByScript.Has(hwnd) " " DebugDescribeWindow(hwnd))

            shielded := TaskbarActivationShields.Has(slot.monitor)
                && TaskbarActivationShields[slot.monitor].claimed
            if shielded {
                PromoteWorkspaceWindow(slot.monitor, slot.workspace, hwnd)
                InvalidateWorkspaceFrame(slot.monitor, slot.workspace)
                direction := slot.workspace > current ? 1 : -1
                switched := SwitchToWorkspaceOnMonitor(
                    slot.workspace, slot.monitor, direction, false, hwnd)
                committed := switched && CurrentWorkspace.Has(slot.monitor)
                    && CurrentWorkspace[slot.monitor] = slot.workspace
            } else {
                committed := AdoptExternallyActivatedWorkspace(
                    hwnd, slot.monitor, slot.workspace)
            }
            DebugLog("EXTERNAL_ACTIVATION_SWITCH", "mode="
                (shielded ? "shielded-slide" : "instant-adopt")
                " committed=" committed " monitor=" slot.monitor
                " from=D" current " to=D" slot.workspace
                " source=" request.source " " DebugDescribeWindow(hwnd))
            if committed
                SetTimer(ActivateOverviewWindow.Bind(
                    hwnd, slot.monitor, slot.workspace, 0), -20)
        } catch as error {
            DebugLog("EXTERNAL_ACTIVATION_ERROR", "message=" DebugClean(error.Message)
                " trackedHwnd=" hwnd " source=" request.source)
        } finally {
            ExternalActivationHandling := false
        }
        break
    }
    if PendingExternalActivations.Count
        SetTimer(ProcessPendingExternalActivations, -1)
}

AdoptExternallyActivatedWorkspace(hwnd, monitor, workspace) {
    global CurrentWorkspace, RequestedWorkspace, WindowWorkspace, HiddenByScript
    global Switching, SwitchingMonitor, PendingWorkspaceSwitches, WorkspaceOverview

    if Switching || !CurrentWorkspace.Has(monitor)
        return false
    oldWorkspace := CurrentWorkspace[monitor]
    if oldWorkspace = workspace
        return true

    startedAt := A_TickCount
    Switching := true
    SwitchingMonitor := monitor
    try {
        if WorkspaceOverview
            CloseWorkspaceOverview(false)
        RememberWorkspaceWindowOrder(monitor, oldWorkspace)
        PromoteWorkspaceWindow(monitor, workspace, hwnd)
        InvalidateWorkspaceFrame(monitor, oldWorkspace)
        InvalidateWorkspaceFrame(monitor, workspace)

        hiddenOutgoing := 0
        requestedIncoming := 0
        for candidate, slot in WindowWorkspace.Clone() {
            if slot.monitor != monitor
                continue
            if !WinExist("ahk_id " candidate) {
                ForgetWindow(candidate)
                continue
            }
            if slot.workspace != workspace {
                if IsVisible(candidate) {
                    HideWindowFast(candidate)
                    HiddenByScript[candidate] := true
                    hiddenOutgoing += 1
                }
                continue
            }

            ; The taskbar-selected window is already the frame the user sees.
            ; Leave it completely untouched. Reveal workspace siblings behind
            ; it without waiting or replaying a slide.
            if candidate = hwnd && IsVisible(candidate) {
                if HiddenByScript.Has(candidate)
                    HiddenByScript.Delete(candidate)
                continue
            }
            if HiddenByScript.Has(candidate) {
                ShowWindowFast(candidate)
                requestedIncoming += 1
            }
        }

        CurrentWorkspace[monitor] := workspace
        RequestedWorkspace[monitor] := workspace
        RaiseWorkspacePriorityWindow(hwnd)
        ShowWorkspaceOverlay(monitor, workspace,
            workspace > oldWorkspace ? 1 : -1)
        ScheduleWorkspaceStateSave()
        SetTimer(FinalizeAdoptedWorkspace.Bind(
            hwnd, monitor, workspace, 0), -35)
        SetTimer(VerifyWorkspaceTransition.Bind(monitor, workspace, 0), -200)
        DebugLog("EXTERNAL_ADOPT_COMMIT", "monitor=" monitor
            " from=D" oldWorkspace " to=D" workspace
            " elapsedMs=" (A_TickCount - startedAt)
            " hiddenOutgoing=" hiddenOutgoing
            " requestedIncoming=" requestedIncoming
            " selected=" DebugDescribeWindow(hwnd))
        return true
    } finally {
        Switching := false
        SwitchingMonitor := 0
        if PendingWorkspaceSwitches.Count
            SetTimer(ProcessPendingWorkspaceSwitches, -1)
    }
}

FinalizeAdoptedWorkspace(hwnd, monitor, workspace, attempt := 0) {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    if !CurrentWorkspace.Has(monitor) || CurrentWorkspace[monitor] != workspace
        return

    pending := 0
    for candidate, slot in WindowWorkspace.Clone() {
        if slot.monitor != monitor || slot.workspace != workspace
            continue
        if !WinExist("ahk_id " candidate) {
            ForgetWindow(candidate)
            continue
        }
        if IsVisible(candidate) {
            if HiddenByScript.Has(candidate)
                HiddenByScript.Delete(candidate)
        } else if HiddenByScript.Has(candidate) {
            ShowWindowFast(candidate)
            pending += 1
        }
    }
    RestoreWorkspaceWindowOrder(monitor, workspace)
    RaiseWorkspacePriorityWindow(hwnd)
    DebugLog("EXTERNAL_ADOPT_FINALIZE", "attempt=" attempt
        " monitor=" monitor " workspace=D" workspace
        " pending=" pending " selectedVisible=" IsVisible(hwnd))
    if pending && attempt < 5
        SetTimer(FinalizeAdoptedWorkspace.Bind(
            hwnd, monitor, workspace, attempt + 1), -50)
}

RaiseWorkspacePriorityWindow(hwnd) {
    if !hwnd || !WinExist("ahk_id " hwnd) || !IsVisible(hwnd)
        return false
    try return DllCall("SetWindowPos", "ptr", hwnd, "ptr", 0,
        "int", 0, "int", 0, "int", 0, "int", 0,
        "uint", IsWindowResponsive(hwnd) ? 0x0013 : 0x4013, "int") != 0 ; NOMOVE|NOSIZE|NOACTIVATE; ASYNCWINDOWPOS if hung
    catch
        return false
}

ResolveTrackedWorkspaceWindow(hwnd) {
    global WindowWorkspace
    if !hwnd
        return 0
    if WindowWorkspace.Has(hwnd)
        return hwnd
    ; A focused toolbar or overlay stays where it is on screen. Following it
    ; to its app's workspace made clicking a share toolbar switch the monitor.
    if !IsWorkspaceWindowKind(hwnd)
        return 0
    for ancestorMode in [2, 3] { ; GA_ROOT, GA_ROOTOWNER
        try ancestor := DllCall("GetAncestor", "ptr", hwnd, "uint", ancestorMode, "ptr")
        catch
            ancestor := 0
        if ancestor && WindowWorkspace.Has(ancestor)
            return ancestor
    }
    return 0
}

HandleOverviewEscape(*) {
    CloseWorkspaceOverview()
}

CloseWorkspaceOverview(restoreFocus := true, *) {
    global WorkspaceOverview, OverviewHotCornerCooldownUntil
    if !WorkspaceOverview
        return

    state := WorkspaceOverview
    DebugLog("OVERVIEW_CLOSE", "monitor=" state.monitor " restoreFocus=" restoreFocus
        " previousActive=" state.previousActive)
    WorkspaceOverview := false
    for thumbnail in state.thumbnails
        try DllCall("dwmapi\DwmUnregisterThumbnail", "ptr", thumbnail)
    try state.gui.Destroy()

    OverviewHotCornerCooldownUntil := A_TickCount + 900
    if restoreFocus && state.previousActive && WinExist("ahk_id " state.previousActive)
        try WinActivate("ahk_id " state.previousActive)
}

CheckWorkspaceOverviewHotCorner() {
    global WorkspaceOverview, OverviewHotCornerMonitor, OverviewHotCornerEnteredAt
    global OverviewHotCornerCooldownUntil

    if WorkspaceOverview || (DllCall("GetAsyncKeyState", "int", 0x01, "short") & 0x8000)
        || IsForegroundFullscreen() {
        OverviewHotCornerMonitor := 0
        OverviewHotCornerEnteredAt := 0
        return
    }
    if A_TickCount < OverviewHotCornerCooldownUntil
        return

    point := Buffer(8, 0)
    if !DllCall("GetCursorPos", "ptr", point.Ptr)
        return
    x := NumGet(point, 0, "int")
    y := NumGet(point, 4, "int")
    monitor := GetMonitorUnderMouse()
    MonitorGet(monitor, &left, &top, &right, &bottom)
    threshold := Max(3, Round(4 * (GetMonitorDpi(monitor) / 96)))
    inCorner := x >= left && x <= left + threshold && y >= top && y <= top + threshold

    if !inCorner {
        OverviewHotCornerMonitor := 0
        OverviewHotCornerEnteredAt := 0
        return
    }

    if OverviewHotCornerMonitor != monitor {
        OverviewHotCornerMonitor := monitor
        OverviewHotCornerEnteredAt := A_TickCount
        return
    }

    if A_TickCount - OverviewHotCornerEnteredAt >= 500 {
        OverviewHotCornerMonitor := 0
        OverviewHotCornerEnteredAt := 0
        OverviewHotCornerCooldownUntil := A_TickCount + 1500
        ShowWorkspaceOverview(monitor)
    }
}

IsForegroundFullscreen() {
    ; Check the focused app's monitor, even if the pointer escapes to another
    ; display. Only the automatic hot corner is blocked; the hotkey still works.
    hwnd := WinExist("A")
    if !hwnd
        return false
    try {
        class := WinGetClass("ahk_id " hwnd)
        if class = "Progman" || class = "WorkerW"
            || class = "Shell_TrayWnd" || class = "Shell_SecondaryTrayWnd"
            return false
        if WinGetMinMax("ahk_id " hwnd) = -1
            return false
        ; Captioned maximized apps can extend past the monitor with an auto-hide
        ; taskbar. Fullscreen and borderless games do not have a normal caption.
        if (WinGetStyle("ahk_id " hwnd) & 0x00C00000) = 0x00C00000
            return false
        WinGetPos(&x, &y, &width, &height, "ahk_id " hwnd)
        MonitorGet(GetWindowMonitor(hwnd), &left, &top, &right, &bottom)
        return x <= left && y <= top && x + width >= right && y + height >= bottom
    } catch {
        ; The foreground window may disappear between queries.
        return false
    }
}

GetMonitorDpi(monitor) {
    MonitorGet(monitor, &left, &top, &right, &bottom)
    point := Buffer(8, 0)
    NumPut("int", left + 1, "int", top + 1, point, 0)
    hMonitor := DllCall("MonitorFromPoint", "int64", NumGet(point, 0, "int64"),
        "uint", 2, "ptr")
    dpiX := A_ScreenDPI
    dpiY := A_ScreenDPI
    try {
        if DllCall("Shcore\GetDpiForMonitor", "ptr", hMonitor, "int", 0,
            "uint*", &dpiX, "uint*", &dpiY, "int") != 0
            dpiX := A_ScreenDPI
    }
    return dpiX > 0 ? dpiX : A_ScreenDPI
}

EnablePerMonitorDpiAwareness() {
    previousContext := 0
    try previousContext := DllCall(
        "SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
    return previousContext
}

DebugDpiAwareness() {
    context := 0
    awareness := -1
    try context := DllCall("GetThreadDpiAwarenessContext", "ptr")
    if context
        try awareness := DllCall(
            "GetAwarenessFromDpiAwarenessContext", "ptr", context, "int")
    return "threadContext=" context " awareness=" awareness
        . " screenDpi=" A_ScreenDPI
}

CreatePhysicalPixelLayer() {
    ; AHK's process DPI mode can still let a newly-created GUI pass through a
    ; scaled intermediate size. Create the native HWND under per-monitor-v2 so
    ; every subsequent SetWindowPos value is interpreted as a physical pixel.
    previousContext := 0
    try previousContext := DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
    try {
        layer := Gui("+AlwaysOnTop -Caption -Border +ToolWindow +E0x20 -DPIScale")
        ; Force HWND creation before restoring the caller's DPI context.
        layerHwnd := layer.Hwnd
    } finally {
        if previousContext
            try DllCall("SetThreadDpiAwarenessContext", "ptr", previousContext, "ptr")
    }
    layer.BackColor := "111827"
    layer.MarginX := 0
    layer.MarginY := 0
    return layer
}

DebugWindowRenderGeometry(hwnd) {
    clientRect := Buffer(16, 0)
    windowRect := Buffer(16, 0)
    if !DllCall("GetClientRect", "ptr", hwnd, "ptr", clientRect.Ptr)
        return "unavailable"
    clientWidth := NumGet(clientRect, 8, "int") - NumGet(clientRect, 0, "int")
    clientHeight := NumGet(clientRect, 12, "int") - NumGet(clientRect, 4, "int")
    windowDetails := "window=unavailable"
    if DllCall("GetWindowRect", "ptr", hwnd, "ptr", windowRect.Ptr) {
        windowDetails := "window=" NumGet(windowRect, 0, "int")
            . "," NumGet(windowRect, 4, "int")
            . "," NumGet(windowRect, 8, "int")
            . "," NumGet(windowRect, 12, "int")
    }
    try windowDpi := DllCall("GetDpiForWindow", "ptr", hwnd, "uint")
    catch
        windowDpi := 0
    return "client=" clientWidth "x" clientHeight " " windowDetails
        . " windowDpi=" windowDpi
}

SetupWorkspaceOverviewPreview(monitor) {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    global OverviewPreviewWindows, OverviewPreviewMode

    OverviewPreviewMode := true
    CurrentWorkspace[monitor] := 1
    colors := ["173B66", "4C1D95", "14532D", "7C2D12", "164E63", "713F12"]
    labels := ["Browser", "Notes", "Editor", "Terminal", "Calendar", "Files"]

    Loop 3 {
        workspace := A_Index
        Loop 2 {
            item := A_Index
            colorIndex := ((workspace - 1) * 2) + item
            source := Gui("+ToolWindow -DPIScale", "D" workspace " - " labels[colorIndex])
            source.BackColor := colors[colorIndex]
            source.MarginX := 0
            source.MarginY := 0
            source.SetFont("s24 cFFFFFF w600", "Segoe UI")
            source.AddText("x0 y0 w520 h300 Center +0x200 BackgroundTrans",
                "D" workspace "`n" labels[colorIndex])
            source.Show("x80 y80 w520 h300")
            WindowWorkspace[source.Hwnd] := {monitor: monitor, workspace: workspace}
            OverviewPreviewWindows.Push({gui: source, workspace: workspace, hwnd: source.Hwnd})
        }
    }

    SetTimer(LaunchWorkspaceOverviewPreview.Bind(monitor), -350)
    SetTimer((*) => ExitApp(), -8000)
}

LaunchWorkspaceOverviewPreview(monitor) {
    global OverviewPreviewWindows, HiddenByScript
    for item in OverviewPreviewWindows {
        if item.workspace = 1
            continue
        CaptureWindowSnapshot(item.hwnd)
        item.gui.Hide()
        HiddenByScript[item.hwnd] := true
    }
    ShowWorkspaceOverview(monitor)
}

SetupWorkspaceSlidePreview(monitor, rapidTest := false, handoffLoopTest := false) {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    global OverviewPreviewWindows, OverviewPreviewMode

    OverviewPreviewMode := true
    CurrentWorkspace[monitor] := 1
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    colors := ["173B66", "4C1D95", "14532D", "7C2D12"]
    labels := ["D1 Browser", "D1 Notes", "D2 Editor", "D2 Terminal"]

    Loop 4 {
        item := A_Index
        workspace := item <= 2 ? 1 : 2
        column := Mod(item - 1, 2)
        source := Gui("+ToolWindow -DPIScale", labels[item])
        source.BackColor := colors[item]
        source.MarginX := 0
        source.MarginY := 0
        source.SetFont("s24 cFFFFFF w600", "Segoe UI")
        source.AddText("x0 y0 w520 h300 Center +0x200 BackgroundTrans", labels[item])
        source.Show("x" (left + 120 + column * 600) " y" (top + 180)
            " w520 h300")
        WindowWorkspace[source.Hwnd] := {monitor: monitor, workspace: workspace}
        OverviewPreviewWindows.Push({gui: source, workspace: workspace, hwnd: source.Hwnd})
        if workspace = 2 {
            CaptureWindowSnapshot(source.Hwnd)
            source.Hide()
            HiddenByScript[source.Hwnd] := true
        }
    }

    if handoffLoopTest
        SetTimer(RunWorkspaceHandoffLoopPreview.Bind(monitor, 1), -300)
    else if rapidTest
        SetTimer(RunRapidWorkspaceSlidePreview.Bind(monitor), -450)
    else
        SetTimer(RunWorkspaceSlidePreview.Bind(monitor, 1), -450)
    SetTimer((*) => ExitApp(), handoffLoopTest ? -5200 : -2600)
}

RunWorkspaceSlidePreview(monitor, step) {
    if step = 1 {
        SwitchToWorkspaceOnMonitor(2, monitor, 1)
        SetTimer(RunWorkspaceSlidePreview.Bind(monitor, 2), -650)
    } else {
        SwitchToWorkspaceOnMonitor(1, monitor, -1)
    }
}

RunRapidWorkspaceSlidePreview(monitor) {
    ; These timers interrupt the active animation just like repeated hotkeys.
    SetTimer(SwitchToWorkspaceOnMonitor.Bind(3, monitor, 1), -80)
    SetTimer(SwitchToWorkspaceOnMonitor.Bind(1, monitor, 1), -140)
    SwitchToWorkspaceOnMonitor(2, monitor, 1)
}

RunWorkspaceHandoffLoopPreview(monitor, step) {
    if step > 8
        return
    targetWorkspace := Mod(step, 2) ? 2 : 1
    direction := targetWorkspace = 2 ? 1 : -1
    SwitchToWorkspaceOnMonitor(targetWorkspace, monitor, direction)
    SetTimer(RunWorkspaceHandoffLoopPreview.Bind(monitor, step + 1), -90)
}

SetupTaskbarActivationPreview(monitor) {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    global OverviewPreviewWindows, OverviewPreviewMode

    OverviewPreviewMode := true
    CurrentWorkspace[monitor] := 1
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    labels := ["D1 Codex", "D1 Browser", "D3 Editor"]
    colors := ["173B66", "4C1D95", "14532D"]
    workspaces := [1, 1, 3]

    Loop labels.Length {
        item := A_Index
        source := Gui("+ToolWindow -DPIScale", labels[item])
        source.BackColor := colors[item]
        source.MarginX := 0
        source.MarginY := 0
        source.SetFont("s24 cFFFFFF w600", "Segoe UI")
        source.AddText("x0 y0 w560 h330 Center +0x200 BackgroundTrans", labels[item])
        source.Show("x" (left + 180 + (item - 1) * 55)
            " y" (top + 200 + (item - 1) * 45) " w560 h330")
        workspace := workspaces[item]
        WindowWorkspace[source.Hwnd] := {monitor: monitor, workspace: workspace}
        OverviewPreviewWindows.Push({
            gui: source, workspace: workspace, hwnd: source.Hwnd, label: labels[item]
        })
        if workspace = 3 {
            CaptureWindowSnapshot(source.Hwnd)
            source.Hide()
            HiddenByScript[source.Hwnd] := true
        }
    }

    RegisterTaskbarClickHotkeys()
    InstallForegroundWinEventHook()
    SetTimer(CheckExternalWorkspaceActivation, 15)
    SetTimer(SwitchToWorkspaceOnMonitor.Bind(3, monitor, 1), -250)
    SetTimer(SimulateTaskbarWorkspaceActivation.Bind(monitor), -950)
    SetTimer((*) => ExitApp(), -2800)
}

SimulateTaskbarWorkspaceActivation(monitor) {
    global OverviewPreviewWindows
    BeginTaskbarActivationShield(monitor)
    for item in OverviewPreviewWindows {
        if item.label != "D1 Codex"
            continue
        DebugLog("TASKBAR_PREVIEW_CLICK", "monitor=" monitor
            " target=D1 " DebugDescribeWindow(item.hwnd))
        item.gui.Show()
        try WinActivate("ahk_id " item.hwnd)
        return
    }
}

CheckRestartedWorkspaceWindows(*) {
    global Switching, ExternalActivationHandling, WorkspaceOverview
    if Switching || ExternalActivationHandling || WorkspaceOverview
        return
    LearnVisibleWindows()
    RememberWindowPlacements()
}

GetWindowRestartIdentity(hwnd) {
    try {
        path := StrLower(WinGetProcessPath("ahk_id " hwnd))
        className := StrLower(WinGetClass("ahk_id " hwnd))
        if !path || !className
            return false
        ; Keep the installation directory and executable name. Only known
        ; updater version components are interchangeable, never bare exe names.
        path := RegExReplace(path, "i)\\app-\d+(?:\.\d+)+(?:-[\w.-]+)?\\", "\app-{version}\")
        path := RegExReplace(path,
            "i)(\\windowsapps\\[^\\]+_)\d+\.\d+\.\d+\.\d+(_[^\\]+\\)", "$1{version}$2")
        return {key: path "|" className, pid: WinGetPID("ahk_id " hwnd)}
    } catch
        return false
}

RememberWindowRestartIdentity(hwnd) {
    global WindowRestartIdentity, OverviewPreviewMode
    if OverviewPreviewMode || WindowRestartIdentity.Has(hwnd)
        return
    ; Only an app's top-level windows come back after a restart. Its dialogs
    ; and popups share its executable and often its class, so a new one opened
    ; on this workspace was hidden as the "restart" of one closed on another.
    if DllCall("GetWindow", "ptr", hwnd, "uint", 4, "ptr") ; GW_OWNER
        return
    identity := GetWindowRestartIdentity(hwnd)
    if identity
        WindowRestartIdentity[hwnd] := identity
}

RememberClosedAppWorkspace(hwnd) {
    global WindowRestartIdentity, WindowWorkspace, RecentAppWorkspaces
    if !WindowRestartIdentity.Has(hwnd) || !WindowWorkspace.Has(hwnd)
        return
    key := WindowRestartIdentity[hwnd].key
    slot := WindowWorkspace[hwnd]
    ambiguous := false
    remaining := 1
    if RecentAppWorkspaces.Has(key) {
        previous := RecentAppWorkspaces[key]
        ambiguous := previous.ambiguous || previous.monitor != slot.monitor
            || previous.workspace != slot.workspace
        remaining += previous.remaining
    }
    RecentAppWorkspaces[key] := {monitor: slot.monitor, workspace: slot.workspace,
        closedAt: A_TickCount, ambiguous: ambiguous, remaining: remaining}
}

RefreshClosedAppWorkspaces() {
    global WindowWorkspace, WindowRestartIdentity, RecentAppWorkspaces
    global RestartActivationUntil, APP_RESTART_MEMORY_MS, HiddenByScript
    for key, record in RecentAppWorkspaces.Clone() {
        if A_TickCount - record.closedAt > APP_RESTART_MEMORY_MS
            RecentAppWorkspaces.Delete(key)
    }
    for hwnd, deadline in RestartActivationUntil.Clone() {
        if A_TickCount >= deadline
            RestartActivationUntil.Delete(hwnd)
    }
    for hwnd in WindowWorkspace.Clone() {
        alive := false
        try alive := WinExist("ahk_id " hwnd)
            && (!WindowRestartIdentity.Has(hwnd)
                || WinGetPID("ahk_id " hwnd) = WindowRestartIdentity[hwnd].pid)
        if !alive
            ForgetWindow(hwnd)
        ; Apps restyle and re-own windows after showing them; Zoom attaches
        ; its share toolbar to the sharing overlay only after it appears. A
        ; window this script hid waits until a visit shows it again.
        else if !HiddenByScript.Has(hwnd) && !IsWorkspaceWindowKind(hwnd)
            ReleaseWorkspaceWindow(hwnd)
        else
            RememberWindowRestartIdentity(hwnd)
    }
    ; Windows waiting for a disconnected monitor are not in a workspace.
    global DisplacedWindows
    for hwnd, home in DisplacedWindows.Clone() {
        alive := false
        try alive := WinExist("ahk_id " hwnd) && WinGetPID("ahk_id " hwnd) = home.pid
        if alive
            continue
        DisplacedWindows.Delete(hwnd)
        if !WindowWorkspace.Has(hwnd) && HiddenByScript.Has(hwnd)
            HiddenByScript.Delete(hwnd)
    }
}

ReleaseWorkspaceWindow(hwnd) {
    global WindowRestartIdentity
    DebugLog("WINDOW_RELEASE", "reason=not-a-workspace-window " DebugDescribeWindow(hwnd))
    ; Released rather than closed, so a relaunch must not inherit its slot.
    if WindowRestartIdentity.Has(hwnd)
        WindowRestartIdentity.Delete(hwnd)
    ForgetWindow(hwnd)
}

TryRestoreRestartedWindow(hwnd, monitor) {
    global WindowRestartIdentity, RecentAppWorkspaces, WindowWorkspace
    global CurrentWorkspace, HiddenByScript, RestartActivationUntil, WORKSPACE_COUNT
    if !WindowRestartIdentity.Has(hwnd)
        return false
    key := WindowRestartIdentity[hwnd].key
    if !RecentAppWorkspaces.Has(key)
        return false
    record := RecentAppWorkspaces[key]
    ; An app spread across desktops has no single safe destination. Also leave
    ; placement on another physical monitor to the normal monitor-move rule.
    if record.ambiguous || record.monitor != monitor
        || !CurrentWorkspace.Has(monitor) || record.workspace < 1
        || record.workspace > WORKSPACE_COUNT
        return false
    for otherHwnd, slot in WindowWorkspace {
        if WindowRestartIdentity.Has(otherHwnd)
            && WindowRestartIdentity[otherHwnd].key = key
            && (slot.monitor != record.monitor || slot.workspace != record.workspace) {
            record.ambiguous := true
            return false
        }
    }
    WindowWorkspace[hwnd] := {monitor: monitor, workspace: record.workspace}
    ; One replacement per closed window; additional newly opened windows still
    ; belong to the current workspace rather than pinning the entire app.
    record.remaining -= 1
    if !record.remaining
        RecentAppWorkspaces.Delete(key)
    InvalidateWorkspaceFrame(monitor, record.workspace)
    PromoteWorkspaceWindow(monitor, record.workspace, hwnd)
    if record.workspace != CurrentWorkspace[monitor] {
        RestartActivationUntil[hwnd] := A_TickCount + 2000
        HiddenByScript[hwnd] := true
        HideWindowFast(hwnd)
    }
    DebugLog("APP_RESTART_RESTORE", "hwnd=" hwnd " monitor=" monitor
        " workspace=D" record.workspace " key=" key)
    return true
}

SuppressRestartActivation(hwnd, slot) {
    global RestartActivationUntil, HiddenByScript, TaskbarActivationShields
    if !RestartActivationUntil.Has(hwnd)
        return false
    ; A deliberate taskbar click takes precedence over startup focus requests.
    if A_TickCount >= RestartActivationUntil[hwnd]
        || TaskbarActivationShields.Has(slot.monitor) {
        RestartActivationUntil.Delete(hwnd)
        return false
    }
    HiddenByScript[hwnd] := true
    HideWindowFast(hwnd)
    return true
}

LearnVisibleWindows() {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript
    global OverviewPreviewMode
    global CarriedWorkspaceWindow

    ; Regression previews own an isolated set of synthetic windows. Never pull
    ; the user's real applications into those temporary workspace assignments.
    if OverviewPreviewMode {
        DebugLog("WINDOW_SCAN_SKIP", "reason=preview-mode tracked=" WindowWorkspace.Count)
        return
    }
    ; While displays change, Windows moves windows between monitors and the
    ; monitor numbers shift. Learning from that would scatter every window's
    ; workspace; the change is reconciled once it settles.
    if DisplayTopologyChanging()
        return

    RefreshClosedAppWorkspaces()
    AdoptReshownDisplacedWindows()

    learned := 0
    moved := 0
    for hwnd in WinGetList() {
        if hwnd = CarriedWorkspaceWindow
            continue
        if HiddenByScript.Has(hwnd)
            continue
        ; Most of the system's windows are hidden. Rule those out before the
        ; process and style lookups, since this scan repeats every 250 ms.
        if !IsVisible(hwnd) || !IsManageableWindow(hwnd)
            continue

        monitor := GetWindowMonitor(hwnd)
        if !WindowWorkspace.Has(hwnd) {
            RememberWindowRestartIdentity(hwnd)
            if TryRestoreRestartedWindow(hwnd, monitor) {
                learned += 1
                continue
            }
            WindowWorkspace[hwnd] := {
                monitor: monitor,
                workspace: CurrentWorkspace[monitor]
            }
            learned += 1
            DebugLog("WINDOW_LEARN", "monitor=" monitor " workspace=D" CurrentWorkspace[monitor]
                " " DebugDescribeWindow(hwnd))
            continue
        }

        ; A visible window dragged to another monitor joins the workspace that is
        ; currently displayed there.
        slot := WindowWorkspace[hwnd]
        ; A window being put back after a display change is still on its way.
        if slot.monitor != monitor && !PlacementRestores.Has(hwnd) {
            oldMonitor := slot.monitor
            oldWorkspace := slot.workspace
            WindowWorkspace[hwnd] := {
                monitor: monitor,
                workspace: CurrentWorkspace[monitor]
            }
            PromoteWorkspaceWindow(monitor, CurrentWorkspace[monitor], hwnd)
            moved += 1
            DebugLog("WINDOW_MONITOR_MOVE", "fromMonitor=" oldMonitor
                " fromWorkspace=D" oldWorkspace " toMonitor=" monitor
                " toWorkspace=D" CurrentWorkspace[monitor] " " DebugDescribeWindow(hwnd))
        }
    }
    if learned || moved {
        DebugLog("WINDOW_SCAN_END", "learned=" learned " moved=" moved
            " tracked=" WindowWorkspace.Count " scriptHidden=" HiddenByScript.Count)
        ScheduleWorkspaceStateSave()
    }
}

IsManageableWindow(hwnd) {
    global HiddenByScript

    if hwnd = A_ScriptHwnd
        return false

    try style := WinGetStyle("ahk_id " hwnd)
    catch
        return false

    if style & 0x40000000 ; WS_CHILD
        return false

    try class := WinGetClass("ahk_id " hwnd)
    catch
        return false
    if class = "AutoHotkeyGUI"
        return false
    if !IsWorkspaceWindowKind(hwnd)
        return false

    ; Do not adopt windows hidden by their own application. Windows already
    ; managed by this script are the exception.
    if !HiddenByScript.Has(hwnd) && !(style & 0x10000000) ; WS_VISIBLE
        return false

    try {
        cloaked := 0
        if DllCall("dwmapi\\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14,
            "int*", &cloaked, "uint", 4) = 0 && cloaked
            return false
    }

    return true
}

IsWorkspaceWindowKind(hwnd) {
    global WindowWorkspace
    try class := WinGetClass("ahk_id " hwnd)
    catch
        return false
    static ignoredClasses := Map(
        "Shell_TrayWnd", true,
        "Shell_SecondaryTrayWnd", true,
        "Progman", true,
        "WorkerW", true,
        "DV2ControlHost", true,
        "MsgrIMEWindowClass", true,
        "SysShadow", true,
        "Windows.UI.Core.CoreWindow", true,
        "EdgeUiInputTopWndClass", true,
        "XamlExplorerHostIslandWindow", true,
        "XamlExplorerHostIslandWindow_WASDK", true,
        "Xaml_WindowedPopupClass", true,
        "tooltips_class32", true,
        "#32768", true, ; menus
        "SysDragImage", true,
        "RaycastUIAccessHelper", true,
        "RaycastNodeGracefulShutdownClass", true
    )
    if ignoredClasses.Has(class)
        return false

    ; Windows Widgets exposes a browser-class helper window, but it is a shell
    ; surface rather than a workspace app. Zoom draws its screen-sharing
    ; borders and indicators from CptHost.exe.
    try processName := StrLower(WinGetProcessName("ahk_id " hwnd))
    catch
        processName := ""
    if processName = "raycast.exe" || processName = "cpthost.exe"
        return false
    if processName = "msedgewebview2.exe" {
        try title := WinGetTitle("ahk_id " hwnd)
        catch
            title := ""
        if title = "Widgets"
            return false
    }

    ; Workspaces hold the windows Windows lists on the taskbar and in Alt+Tab,
    ; plus their dialogs. On-screen displays, tray flyouts, notifications and
    ; meeting or screen-sharing overlays come and go on their app's schedule:
    ; hiding one during a switch and re-showing it on the next visit left it
    ; stuck on screen, and focusing one jumped the monitor to the workspace
    ; that happened to be showing when it first appeared.
    try exStyle := WinGetExStyle("ahk_id " hwnd)
    catch
        return false
    if exStyle & 0x20 ; WS_EX_TRANSPARENT
        return false
    ; A window owned by an overlay belongs to that overlay, even one asking for
    ; a taskbar button. Zoom's screen-sharing toolbar does, and is owned by a
    ; hidden toolbar holder that the meeting window owns, so check every owner
    ; up the chain rather than only the top one.
    try owner := DllCall("GetWindow", "ptr", hwnd, "uint", 4, "ptr") ; GW_OWNER
    catch
        owner := 0
    if owner && !IsWorkspaceWindowKind(owner)
        return false
    if exStyle & 0x40000 ; WS_EX_APPWINDOW
        return true
    if exStyle & 0x08000000 ; WS_EX_NOACTIVATE
        return false
    if !(exStyle & 0x80) ; WS_EX_TOOLWINDOW
        return true
    ; An app's own palettes and drawn frame shadows still follow it, because
    ; hiding the app does not hide the windows it owns. Always-on-top ones
    ; float above every workspace.
    if !owner || exStyle & 0x8 ; WS_EX_TOPMOST
        return false
    try rootOwner := DllCall("GetAncestor", "ptr", hwnd, "uint", 3, "ptr") ; GA_ROOTOWNER
    catch
        return false
    return WindowWorkspace.Has(rootOwner)
}

IsVisible(hwnd) {
    try return DllCall("IsWindowVisible", "ptr", hwnd, "int") != 0
    catch
        return false
}

HideWindowFast(hwnd) {
    ; SW_HIDE = 0. Post to the owning UI thread without waiting for each app.
    try {
        result := DllCall("ShowWindowAsync", "ptr", hwnd, "int", 0)
        DebugLog("WINDOW_HIDE_ASYNC", "result=" result " " DebugDescribeWindow(hwnd))
        return result
    } catch as error {
        DebugLog("WINDOW_HIDE_ERROR", "message=" DebugClean(error.Message) " " DebugDescribeWindow(hwnd))
        return false
    }
}

ShowWindowFast(hwnd) {
    ; SW_SHOWNA = 8: show without activation or restoring minimized windows.
    try {
        result := DllCall("ShowWindowAsync", "ptr", hwnd, "int", 8)
        DebugLog("WINDOW_SHOW_ASYNC", "result=" result " " DebugDescribeWindow(hwnd))
        return result
    } catch as error {
        DebugLog("WINDOW_SHOW_ERROR", "message=" DebugClean(error.Message) " " DebugDescribeWindow(hwnd))
        return false
    }
}

IsWindowResponsive(hwnd, timeoutMs := 100) {
    ; PrintWindow, ShowWindow and synchronous SetWindowPos wait for the owning
    ; UI thread with no timeout. One hung app would otherwise block this
    ; script's only thread, including the watchdog meant to recover it.
    ownerThread := DllCall("GetWindowThreadProcessId", "ptr", hwnd, "ptr", 0, "uint")
    if !ownerThread
        return false
    if ownerThread = DllCall("GetCurrentThreadId", "uint")
        return true
    result := 0
    ; WM_NULL with SMTO_ABORTIFHUNG returns at once for a window Windows
    ; already reports as hung, and after timeoutMs for one that just stalled.
    try return DllCall("SendMessageTimeout", "ptr", hwnd, "uint", 0,
        "ptr", 0, "ptr", 0, "uint", 0x0002, "uint", timeoutMs,
        "uptr*", &result, "ptr") != 0
    catch
        return false
}

WorkspaceWindowOrderKey(monitor, workspace) {
    return monitor ":" workspace
}

RememberWorkspaceWindowOrder(monitor, workspace) {
    global WindowWorkspace, HiddenByScript, WorkspaceWindowOrders
    key := WorkspaceWindowOrderKey(monitor, workspace)
    visibleOrder := []
    allInWindowsOrder := []
    total := 0
    for hwnd in WinGetList() {
        if !WindowWorkspace.Has(hwnd)
            continue
        slot := WindowWorkspace[hwnd]
        if slot.monitor != monitor || slot.workspace != workspace
            continue
        total += 1
        allInWindowsOrder.Push(hwnd)
        if IsVisible(hwnd) && !HiddenByScript.Has(hwnd)
            visibleOrder.Push(hwnd)
    }

    ; An incomplete handoff must not overwrite a complete saved stack with only
    ; the first application that happened to respond. Keep the prior order and
    ; append genuinely new handles until every assigned window is visible.
    order := []
    included := Map()
    if visibleOrder.Length < total && WorkspaceWindowOrders.Has(key) {
        for hwnd in WorkspaceWindowOrders[key] {
            if !WindowWorkspace.Has(hwnd)
                continue
            slot := WindowWorkspace[hwnd]
            if slot.monitor = monitor && slot.workspace = workspace {
                order.Push(hwnd)
                included[hwnd] := true
            }
        }
    } else {
        for hwnd in visibleOrder {
            order.Push(hwnd)
            included[hwnd] := true
        }
    }
    for hwnd in allInWindowsOrder {
        if !included.Has(hwnd)
            order.Push(hwnd)
    }

    if order.Length
        WorkspaceWindowOrders[key] := order
    else if WorkspaceWindowOrders.Has(key)
        WorkspaceWindowOrders.Delete(key)
    DebugLog("STACK_REMEMBER", "monitor=" monitor " workspace=D" workspace
        " visible=" visibleOrder.Length " total=" total
        " order=" DebugWindowOrder(order))
    return order
}

GetWorkspaceWindowOrder(monitor, workspace) {
    global WindowWorkspace, WorkspaceWindowOrders
    key := WorkspaceWindowOrderKey(monitor, workspace)
    saved := WorkspaceWindowOrders.Has(key) ? WorkspaceWindowOrders[key] : []
    order := []
    included := Map()

    ; First retain the remembered top-to-bottom stack, discarding stale or
    ; reassigned handles. Then append newly discovered windows in their current
    ; Windows Z-order so they are never omitted from the restored group.
    for hwnd in saved {
        if !WinExist("ahk_id " hwnd) || !WindowWorkspace.Has(hwnd)
            continue
        slot := WindowWorkspace[hwnd]
        if slot.monitor != monitor || slot.workspace != workspace
            continue
        order.Push(hwnd)
        included[hwnd] := true
    }
    for hwnd in WinGetList() {
        if included.Has(hwnd) || !WindowWorkspace.Has(hwnd)
            continue
        slot := WindowWorkspace[hwnd]
        if slot.monitor = monitor && slot.workspace = workspace {
            order.Push(hwnd)
            included[hwnd] := true
        }
    }
    WorkspaceWindowOrders[key] := order
    return order
}

RestoreWorkspaceWindowOrder(monitor, workspace, draggedHwnd := 0, coverHwnd := 0) {
    order := GetWorkspaceWindowOrder(monitor, workspace)
    restored := 0

    ; The saved array is top-to-bottom. Raising it in reverse reconstructs that
    ; ordering without activating or moving any application window.
    Loop order.Length {
        hwnd := order[order.Length - A_Index + 1]
        if hwnd = draggedHwnd
            continue
        if !WinExist("ahk_id " hwnd) || !IsVisible(hwnd)
            continue
        insertAfter := draggedHwnd
        ; Revealed before the slide, a window must stay beneath its cover. In a
        ; drag the cover sits just below the held window; otherwise the cover
        ; is topmost, and only a topmost window could rise above it. Placing a
        ; topmost window under a normal one would strip its topmost state.
        if coverHwnd {
            try topmost := (WinGetExStyle("ahk_id " hwnd) & 0x8) != 0
            catch
                topmost := false
            if draggedHwnd ? !topmost : topmost
                insertAfter := coverHwnd
        }
        ; Post the reorder during a drag or to a hung app instead of waiting.
        postReorder := draggedHwnd || !IsWindowResponsive(hwnd)
        try {
            result := DllCall("SetWindowPos", "ptr", hwnd, "ptr", insertAfter,
                "int", 0, "int", 0, "int", 0, "int", 0,
                "uint", postReorder ? 0x4013 : 0x0013, "int") ; NOMOVE|NOSIZE|NOACTIVATE; optional ASYNCWINDOWPOS
            restored += result ? 1 : 0
        }
    }
    DebugLog("STACK_RESTORE", "monitor=" monitor " workspace=D" workspace
        " requested=" order.Length " restored=" restored
        " order=" DebugWindowOrder(order))
    return restored
}

HasScriptHiddenWorkspaceWindows(monitor, workspace) {
    global WindowWorkspace, HiddenByScript
    for hwnd, slot in WindowWorkspace {
        if slot.monitor = monitor && slot.workspace = workspace && HiddenByScript.Has(hwnd)
            return true
    }
    return false
}

RevealWorkspaceForHandoff(monitor, workspace, timeoutMs := 260, draggedHwnd := 0,
    coverHwnd := 0) {
    global WindowWorkspace, HiddenByScript
    expected := []
    showStartedAt := A_TickCount

    for hwnd, slot in WindowWorkspace.Clone() {
        if slot.monitor != monitor || slot.workspace != workspace
            continue
        if !WinExist("ahk_id " hwnd) {
            ForgetWindow(hwnd)
            continue
        }
        ; A drag's cover is not topmost, so a topmost window revealed before
        ; the slide would show above it. It waits for the slide to finish.
        if coverHwnd && draggedHwnd && HiddenByScript.Has(hwnd) {
            try topmost := (WinGetExStyle("ahk_id " hwnd) & 0x8) != 0
            catch
                topmost := false
            if topmost {
                DebugLog("SWITCH_DEFER", "target=D" workspace " reason=topmost-during-drag "
                    DebugDescribeWindow(hwnd))
                continue
            }
        }
        if HiddenByScript.Has(hwnd) {
            expected.Push(hwnd)
            DebugLog("SWITCH_SHOW", "target=D" workspace " " DebugDescribeWindow(hwnd))
            ShowWindowFast(hwnd)
        } else {
            DebugLog("SWITCH_KEEP", "target=D" workspace " already-not-script-hidden "
                DebugDescribeWindow(hwnd))
        }
    }

    DebugLog("HANDOFF_BEGIN", "monitor=" monitor " workspace=D" workspace
        " expected=" expected.Length " timeoutMs=" timeoutMs)
    pending := []
    retryAt := 48
    loop {
        pending := []
        for hwnd in expected {
            if !WinExist("ahk_id " hwnd)
                continue
            if IsVisible(hwnd) {
                if HiddenByScript.Has(hwnd)
                    HiddenByScript.Delete(hwnd)
            } else
                pending.Push(hwnd)
        }
        elapsed := A_TickCount - showStartedAt
        if !pending.Length || elapsed >= timeoutMs
            break
        if elapsed >= retryAt {
            DebugLog("HANDOFF_RETRY", "monitor=" monitor " workspace=D" workspace
                " elapsedMs=" elapsed " pending=" pending.Length
                " windows=" DebugWindowOrder(pending))
            for hwnd in pending
                ShowWindowFast(hwnd)
            retryAt += 64
        }
        Sleep(8)
    }

    RestoreWorkspaceWindowOrder(monitor, workspace, draggedHwnd, coverHwnd)
    ; IsWindowVisible changes before every compositor surface is necessarily on
    ; screen. Two DWM presentation boundaries make the cover removal atomic to
    ; the user's eye while adding only one or two refresh intervals.
    try DllCall("dwmapi\DwmFlush")
    try DllCall("dwmapi\DwmFlush")
    elapsed := A_TickCount - showStartedAt
    DebugLog("HANDOFF_COMPLETE", "monitor=" monitor " workspace=D" workspace
        " elapsedMs=" elapsed " expected=" expected.Length
        " visible=" (expected.Length - pending.Length)
        " pending=" pending.Length " windows=" DebugWindowOrder(pending))
    return pending.Length = 0
}

RemoveWindowFromWorkspaceOrders(hwnd) {
    global WorkspaceWindowOrders
    for key, order in WorkspaceWindowOrders.Clone() {
        filtered := []
        for savedHwnd in order {
            if savedHwnd != hwnd
                filtered.Push(savedHwnd)
        }
        if filtered.Length
            WorkspaceWindowOrders[key] := filtered
        else
            WorkspaceWindowOrders.Delete(key)
    }
}

PromoteWorkspaceWindow(monitor, workspace, hwnd) {
    global WorkspaceWindowOrders
    RemoveWindowFromWorkspaceOrders(hwnd)
    key := WorkspaceWindowOrderKey(monitor, workspace)
    order := WorkspaceWindowOrders.Has(key) ? WorkspaceWindowOrders[key] : []
    order.InsertAt(1, hwnd)
    WorkspaceWindowOrders[key] := order
    DebugLog("STACK_PROMOTE", "monitor=" monitor " workspace=D" workspace
        " hwnd=" hwnd " order=" DebugWindowOrder(order))
}

DebugWindowOrder(order) {
    value := ""
    for hwnd in order
        value .= (value ? "," : "") hwnd
    return value ? value : "none"
}

CaptureWindowSnapshot(hwnd, allowScreenCapture := true) {
    global WindowSnapshots
    if !WinExist("ahk_id " hwnd)
        return false
    ; A hidden window prints as solid black even though PrintWindow reports
    ; success. Keep its last snapshot, or none, instead of a black one.
    if !IsVisible(hwnd)
        return false

    windowRect := Buffer(16, 0)
    if !DllCall("GetWindowRect", "ptr", hwnd, "ptr", windowRect.Ptr)
        return false
    left := NumGet(windowRect, 0, "int")
    top := NumGet(windowRect, 4, "int")
    width := NumGet(windowRect, 8, "int") - left
    height := NumGet(windowRect, 12, "int") - top
    if width <= 0 || height <= 0
        return false

    screenDc := DllCall("GetDC", "ptr", 0, "ptr")
    memoryDc := DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr")
    bitmap := DllCall("CreateCompatibleBitmap", "ptr", screenDc,
        "int", width, "int", height, "ptr")
    if !screenDc || !memoryDc || !bitmap {
        if bitmap
            DllCall("DeleteObject", "ptr", bitmap)
        if memoryDc
            DllCall("DeleteDC", "ptr", memoryDc)
        if screenDc
            DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
        return false
    }

    oldBitmap := DllCall("SelectObject", "ptr", memoryDc, "ptr", bitmap, "ptr")
    captured := false
    if IsWindowResponsive(hwnd) {
        printStarted := A_TickCount
        try captured := DllCall("PrintWindow", "ptr", hwnd, "ptr", memoryDc, "uint", 2, "int") != 0
        ; A responsive app can still take seconds here when the compositor is
        ; busy, as during a screen share. Record which window it was.
        if A_TickCount - printStarted > 150
            DebugLog("SNAPSHOT_PRINT_SLOW", "elapsedMs=" (A_TickCount - printStarted)
                " " DebugDescribeWindow(hwnd))
    } else
        DebugLog("SNAPSHOT_PRINT_SKIP", "reason=unresponsive " DebugDescribeWindow(hwnd))
    ; The screen only holds this window's pixels while it is shown.
    if !captured && allowScreenCapture && IsVisible(hwnd) {
        captured := DllCall("BitBlt", "ptr", memoryDc,
            "int", 0, "int", 0, "int", width, "int", height,
            "ptr", screenDc, "int", left, "int", top, "uint", 0x00CC0020, "int") != 0
    }

    sourceRestored := false
    if captured && Max(width, height) > 1280 {
        resizeScale := 1280 / Max(width, height)
        resizedWidth := Max(1, Round(width * resizeScale))
        resizedHeight := Max(1, Round(height * resizeScale))
        resizedDc := DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr")
        resizedBitmap := DllCall("CreateCompatibleBitmap", "ptr", screenDc,
            "int", resizedWidth, "int", resizedHeight, "ptr")
        if resizedDc && resizedBitmap {
            oldResizedBitmap := DllCall("SelectObject", "ptr", resizedDc, "ptr", resizedBitmap, "ptr")
            DllCall("SetStretchBltMode", "ptr", resizedDc, "int", 4)
            resized := DllCall("StretchBlt",
                "ptr", resizedDc, "int", 0, "int", 0, "int", resizedWidth, "int", resizedHeight,
                "ptr", memoryDc, "int", 0, "int", 0, "int", width, "int", height,
                "uint", 0x00CC0020, "int") != 0
            DllCall("SelectObject", "ptr", resizedDc, "ptr", oldResizedBitmap)
            if resized {
                DllCall("SelectObject", "ptr", memoryDc, "ptr", oldBitmap)
                sourceRestored := true
                DllCall("DeleteObject", "ptr", bitmap)
                bitmap := resizedBitmap
                width := resizedWidth
                height := resizedHeight
            } else {
                DllCall("DeleteObject", "ptr", resizedBitmap)
            }
        }
        if resizedDc
            DllCall("DeleteDC", "ptr", resizedDc)
    }

    if !sourceRestored
        DllCall("SelectObject", "ptr", memoryDc, "ptr", oldBitmap)
    DllCall("DeleteDC", "ptr", memoryDc)
    DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)

    if !captured {
        DllCall("DeleteObject", "ptr", bitmap)
        return false
    }

    DeleteWindowSnapshot(hwnd)
    WindowSnapshots[hwnd] := {bitmap: bitmap, width: width, height: height}
    return true
}

DeleteWindowSnapshot(hwnd) {
    global WindowSnapshots
    if !WindowSnapshots.Has(hwnd)
        return
    snapshot := WindowSnapshots[hwnd]
    if snapshot.bitmap
        try DllCall("DeleteObject", "ptr", snapshot.bitmap)
    WindowSnapshots.Delete(hwnd)
}

ClearWindowSnapshots() {
    global WindowSnapshots
    for hwnd in WindowSnapshots.Clone()
        DeleteWindowSnapshot(hwnd)
}

GetMonitorUnderMouse() {
    point := Buffer(8, 0)
    if !DllCall("GetCursorPos", "ptr", point.Ptr)
        return MonitorGetPrimary()

    ; Pass the native POINT by value, preserving physical coordinates on mixed-DPI displays.
    hMonitor := DllCall("MonitorFromPoint", "int64", NumGet(point, 0, "int64"),
        "uint", 2, "ptr")
    return GetMonitorIndexFromHandle(hMonitor)
}

GetWindowMonitor(hwnd) {
    hMonitor := DllCall("MonitorFromWindow", "ptr", hwnd, "uint", 2, "ptr")
    return GetMonitorIndexFromHandle(hMonitor)
}

GetMonitorIndexFromHandle(hMonitor) {
    if !hMonitor
        return MonitorGetPrimary()

    ; MONITORINFOEXW provides the stable \\.\DISPLAYn device name.
    info := Buffer(104, 0)
    NumPut("uint", 104, info, 0)
    if !DllCall("GetMonitorInfoW", "ptr", hMonitor, "ptr", info.Ptr)
        return MonitorGetPrimary()

    deviceName := StrGet(info.Ptr + 40, 32, "UTF-16")
    Loop MonitorGetCount() {
        if StrLower(MonitorGetName(A_Index)) = StrLower(deviceName)
            return A_Index
    }
    return MonitorGetPrimary()
}

EnsureMonitorState() {
    global CurrentWorkspace, RequestedWorkspace
    Loop MonitorGetCount() {
        if !CurrentWorkspace.Has(A_Index)
            CurrentWorkspace[A_Index] := 1
        if !RequestedWorkspace.Has(A_Index)
            RequestedWorkspace[A_Index] := CurrentWorkspace[A_Index]
    }
}

SyncRequestedWorkspaces() {
    global CurrentWorkspace, RequestedWorkspace
    RequestedWorkspace.Clear()
    Loop MonitorGetCount()
        RequestedWorkspace[A_Index] := CurrentWorkspace.Has(A_Index)
            ? CurrentWorkspace[A_Index] : 1
}

ProcessPendingWorkspaceSwitches(*) {
    global Switching, PendingWorkspaceSwitches, WorkspaceRestartScheduled
    if Switching || WorkspaceRestartScheduled || !PendingWorkspaceSwitches.Count
        return
    for monitor, request in PendingWorkspaceSwitches.Clone() {
        PendingWorkspaceSwitches.Delete(monitor)
        DebugLog("SWITCH_QUEUE_PROCESS", "target=D" request.workspace
            " monitor=" monitor " direction=" request.direction
            " rapid=" request.rapid
            " remainingMonitors=" PendingWorkspaceSwitches.Count)
        SwitchToWorkspaceOnMonitor(
            request.workspace, monitor, request.direction, request.rapid)
        break
    }
    if PendingWorkspaceSwitches.Count
        SetTimer(ProcessPendingWorkspaceSwitches, -1)
}

MarkWorkspaceSwitchProgress(stage) {
    global SwitchingLastProgressAt, SwitchingMonitor, SwitchingTargetWorkspace
    SwitchingLastProgressAt := A_TickCount
    DebugLog("SWITCH_PROGRESS", "stage=" stage " monitor=" SwitchingMonitor
        " target=D" SwitchingTargetWorkspace)
}

CheckWorkspaceEngineHealth(*) {
    global Switching, SwitchingMonitor, SwitchingStartedAt, SwitchingLastProgressAt
    global SwitchingTargetWorkspace, SwitchingDirection, SwitchingSoftRecoveryRequested
    global WORKSPACE_WATCHDOG_SOFT_MS, WORKSPACE_WATCHDOG_RESTART_MS
    global PendingWorkspaceSwitches, RequestedWorkspace, WorkspaceSlideSkipRequests
    global WorkspaceRestartScheduled

    CheckWorkspaceOverlayHealth()
    if WorkspaceRestartScheduled
        return
    if !Switching {
        if SwitchingStartedAt || SwitchingLastProgressAt {
            DebugLog("WATCHDOG_STATE_REPAIR", "reason=orphan-timestamps")
            SwitchingStartedAt := 0
            SwitchingLastProgressAt := 0
        }
        return
    }

    now := A_TickCount
    elapsed := SwitchingStartedAt ? now - SwitchingStartedAt : 0
    idle := SwitchingLastProgressAt ? now - SwitchingLastProgressAt : elapsed
    if !SwitchingSoftRecoveryRequested && idle >= WORKSPACE_WATCHDOG_SOFT_MS {
        SwitchingSoftRecoveryRequested := true
        if SwitchingMonitor {
            WorkspaceSlideSkipRequests[SwitchingMonitor] := true
            RequestedWorkspace[SwitchingMonitor] := SwitchingTargetWorkspace
            PendingWorkspaceSwitches[SwitchingMonitor] := {
                workspace: SwitchingTargetWorkspace,
                direction: SwitchingDirection,
                rapid: true
            }
        }
        DebugLog("WATCHDOG_SOFT_RECOVERY", "monitor=" SwitchingMonitor
            " target=D" SwitchingTargetWorkspace " elapsedMs=" elapsed
            " idleMs=" idle " action=finish-and-retry")
    }

    if elapsed >= WORKSPACE_WATCHDOG_RESTART_MS {
        DebugLog("WATCHDOG_HARD_RECOVERY", "monitor=" SwitchingMonitor
            " target=D" SwitchingTargetWorkspace " elapsedMs=" elapsed
            " idleMs=" idle " action=restart-and-resume")
        ScheduleWorkspaceEngineRestart("stalled-switch", SwitchingMonitor,
            SwitchingTargetWorkspace, SwitchingDirection)
    }
}

RestartWorkspaceEngine(*) {
    ScheduleWorkspaceEngineRestart("manual")
}

ScheduleWorkspaceEngineRestart(reason, monitor := 0, workspace := 0, direction := 0) {
    global WorkspaceRestartScheduled, WorkspaceRestartPreviewMode
    global WorkspaceStatePersistenceEnabled, Switching
    if WorkspaceRestartScheduled
        return false
    WorkspaceRestartScheduled := true

    if WorkspaceRestartPreviewMode {
        DebugLog("ENGINE_RESTART_PREVIEW", "reason=" reason " monitor=" monitor
            " workspace=" workspace " direction=" direction)
        return true
    }

    if !Switching
        try SaveWorkspaceState()
    if monitor && workspace
        WriteWorkspaceRecoveryRequest(monitor, workspace, direction, reason)
    ; A stalled transition may have partially hidden windows. Do not overwrite
    ; the last known-good state during OnExit; it will reveal all windows, then
    ; the new process will reapply that state and replay the pending request.
    WorkspaceStatePersistenceEnabled := false
    DebugLog("ENGINE_RESTART_SCHEDULE", "reason=" reason " monitor=" monitor
        " workspace=" workspace " direction=" direction " delayMs=80")
    SetTimer(PerformWorkspaceEngineRestart.Bind(reason), -80)
    return true
}

PerformWorkspaceEngineRestart(reason) {
    DebugLog("ENGINE_RESTART", "reason=" reason)
    Reload()
}

WriteWorkspaceRecoveryRequest(monitor, workspace, direction, reason) {
    global WORKSPACE_RECOVERY_PATH
    try {
        SplitPath(WORKSPACE_RECOVERY_PATH,, &recoveryDirectory)
        DirCreate(recoveryDirectory)
        if FileExist(WORKSPACE_RECOVERY_PATH)
            FileDelete(WORKSPACE_RECOVERY_PATH)
        FileAppend(MonitorGetName(monitor) "`t" workspace "`t" direction
            "`t" reason, WORKSPACE_RECOVERY_PATH, "UTF-8")
        DebugLog("RECOVERY_REQUEST_SAVE", "monitor=" monitor " target=D" workspace
            " direction=" direction " reason=" reason)
        return true
    } catch as error {
        DebugLog("RECOVERY_REQUEST_ERROR", "action=save message="
            DebugClean(error.Message))
        return false
    }
}

ResumePendingWorkspaceRecovery() {
    global WORKSPACE_RECOVERY_PATH, WORKSPACE_COUNT
    if !FileExist(WORKSPACE_RECOVERY_PATH)
        return false
    try {
        contents := Trim(FileRead(WORKSPACE_RECOVERY_PATH, "UTF-8"))
        FileDelete(WORKSPACE_RECOVERY_PATH)
        fields := StrSplit(contents, "`t")
        if fields.Length < 3
            throw Error("Recovery request is incomplete")
        deviceName := fields[1]
        workspace := Integer(fields[2])
        direction := Integer(fields[3])
        if workspace < 1 || workspace > WORKSPACE_COUNT
            throw Error("Recovery workspace is invalid")
        monitor := 0
        Loop MonitorGetCount() {
            if StrLower(MonitorGetName(A_Index)) = StrLower(deviceName) {
                monitor := A_Index
                break
            }
        }
        if !monitor
            throw Error("Recovery monitor is no longer connected")
        DebugLog("RECOVERY_REQUEST_RESUME", "monitor=" monitor
            " target=D" workspace " direction=" direction " delayMs=350")
        SetTimer(SwitchToWorkspaceOnMonitor.Bind(
            workspace, monitor, direction, true), -350)
        return true
    } catch as error {
        try {
            if FileExist(WORKSPACE_RECOVERY_PATH)
                FileDelete(WORKSPACE_RECOVERY_PATH)
        }
        DebugLog("RECOVERY_REQUEST_ERROR", "action=resume message="
            DebugClean(error.Message))
        return false
    }
}

ForgetWindow(hwnd) {
    global WindowWorkspace, HiddenByScript
    global WindowRestartIdentity, RestartActivationUntil
    global DisplacedWindows, WindowPlacements, PlacementRestores
    RememberClosedAppWorkspace(hwnd)
    for record in [DisplacedWindows, WindowPlacements, PlacementRestores] {
        if record.Has(hwnd)
            record.Delete(hwnd)
    }
    if WindowRestartIdentity.Has(hwnd)
        WindowRestartIdentity.Delete(hwnd)
    if RestartActivationUntil.Has(hwnd)
        RestartActivationUntil.Delete(hwnd)
    if WindowWorkspace.Has(hwnd) {
        slot := WindowWorkspace[hwnd]
        InvalidateWorkspaceFrame(slot.monitor, slot.workspace)
        WindowWorkspace.Delete(hwnd)
    }
    if HiddenByScript.Has(hwnd)
        HiddenByScript.Delete(hwnd)
    RemoveWindowFromWorkspaceOrders(hwnd)
    DeleteWindowSnapshot(hwnd)
}

HandleDisplayChange(*) {
    ; Windows broadcasts WM_DISPLAYCHANGE after monitor connect/disconnect,
    ; resolution changes, docking, and topology changes. Switching a monitor's
    ; input to a console disconnects it, often only for a second.
    global DISPLAY_SETTLE_MS
    DebugLog("DISPLAY_CHANGE", "settleMs=" DISPLAY_SETTLE_MS)
    BeginDisplayTopologyChange("display-change")
}

DisplayTopologyChanging() {
    ; Windows can move windows off a disconnecting monitor before this script
    ; receives WM_DISPLAYCHANGE, so the monitor list is checked directly too.
    global DisplayTopologyPending, MonitorTopologyKey
    if DisplayTopologyPending
        return true
    if CurrentMonitorSignature() = MonitorTopologyKey
        return false
    BeginDisplayTopologyChange("monitor-scan")
    return true
}

BeginDisplayTopologyChange(reason) {
    global DisplayTopologyPending, DisplayTopologyLastSeen, MonitorTopologyKey
    global PendingWorkspaceSwitches, PendingExternalActivations, DISPLAY_SETTLE_MS
    signature := CurrentMonitorSignature()
    DebugLog("DISPLAY_TOPOLOGY_CHANGE", "reason=" reason
        " pending=" DisplayTopologyPending " previous=" MonitorTopologyKey
        " current=" signature)
    DisplayTopologyPending := true
    DisplayTopologyLastSeen := signature
    PendingWorkspaceSwitches.Clear()
    PendingExternalActivations.Clear()
    SetTimer(SettleDisplayTopologyChange, -DISPLAY_SETTLE_MS)
}

SettleDisplayTopologyChange(*) {
    global DisplayTopologyPending, DisplayTopologyLastSeen, DISPLAY_SETTLE_MS
    global Switching, ExternalActivationHandling
    if !DisplayTopologyPending
        return
    if Switching || ExternalActivationHandling {
        SetTimer(SettleDisplayTopologyChange, -300)
        return
    }
    topology := ReadMonitorTopology()
    signature := MonitorTopologySignature(topology)
    settled := topology.Length > 0 && signature = DisplayTopologyLastSeen
    for entry in topology {
        if !entry.device
            settled := false
    }
    if !settled {
        DisplayTopologyLastSeen := signature
        DebugLog("DISPLAY_TOPOLOGY_WAIT", "current=" signature)
        SetTimer(SettleDisplayTopologyChange, -DISPLAY_SETTLE_MS)
        return
    }
    ReconcileDisplayTopology(topology)
}

ReconcileDisplayTopology(topology, reason := "settled") {
    ; Carry every window, workspace stack and active workspace from the old
    ; monitor numbering to the new one by device name. Windows whose monitor
    ; left wait for it: the ones Windows moved onto another monitor join the
    ; workspace shown there, the hidden ones stay hidden. When a monitor comes
    ; back, its windows return to their places and workspaces.
    global MonitorTopology, CurrentWorkspace, RequestedWorkspace, WindowWorkspace
    global HiddenByScript, WorkspaceWindowOrders, RecentAppWorkspaces
    global WindowPlacements, DisplacedWindows, DisplacedMonitors, DisplacedWindowOrders
    global DisplayTopologyPending, PendingWorkspaceSwitches, WorkspaceSlideSkipRequests
    global PendingExternalActivations, CarriedWorkspaceWindow, OverviewHotCornerMonitor
    previousCritical := Critical("On")
    try {
        oldTopology := MonitorTopology
        newIndex := Map()
        for index, entry in topology
            newIndex[entry.device] := index
        oldIndex := Map()
        for index, entry in oldTopology
            oldIndex[entry.device] := index
        DebugLog("DISPLAY_TOPOLOGY_RECONCILE", "reason=" reason
            " from=" MonitorTopologySignature(oldTopology)
            " to=" MonitorTopologySignature(topology))

        ; Frames, indicators and shields were drawn for the old layout.
        CloseWorkspaceOverview(false)
        ClearWorkspaceOverlays()
        ClearTaskbarActivationShields("display-change")
        ClearWorkspaceFrames()
        ClearDesktopBackgrounds()
        PendingWorkspaceSwitches.Clear()
        WorkspaceSlideSkipRequests.Clear()
        PendingExternalActivations.Clear()
        SetTimer(FinishWorkspaceWindowDrag, 0)
        CarriedWorkspaceWindow := 0
        OverviewHotCornerMonitor := 0
        ; Closed windows go first, while restart memory still uses old numbers.
        for hwnd in WindowWorkspace.Clone() {
            if !WinExist("ahk_id " hwnd)
                ForgetWindow(hwnd)
        }

        ; Each monitor keeps the workspace it showed, including one returning.
        current := Map()
        returningMonitors := Map()
        for index, entry in topology {
            if oldIndex.Has(entry.device) && CurrentWorkspace.Has(oldIndex[entry.device])
                current[index] := CurrentWorkspace[oldIndex[entry.device]]
            else if DisplacedMonitors.Has(entry.device) {
                current[index] := DisplacedMonitors[entry.device].workspace
                returningMonitors[entry.device] := true
                DisplacedMonitors.Delete(entry.device)
            } else
                current[index] := 1
        }
        for index, entry in oldTopology {
            if entry.device && !newIndex.Has(entry.device)
                DisplacedMonitors[entry.device] := {name: entry.name, monitor: entry,
                    workspace: CurrentWorkspace.Has(index) ? CurrentWorkspace[index] : 1}
        }
        CurrentWorkspace.Clear()
        RequestedWorkspace.Clear()
        for index, workspace in current {
            CurrentWorkspace[index] := workspace
            RequestedWorkspace[index] := workspace
        }

        ; Workspace stacks follow their monitor.
        orders := Map()
        for key, order in WorkspaceWindowOrders {
            parts := StrSplit(key, ":")
            monitor := Integer(parts[1])
            if monitor < 1 || monitor > oldTopology.Length
                continue
            device := oldTopology[monitor].device
            if newIndex.Has(device)
                orders[newIndex[device] ":" parts[2]] := order
            else
                DisplacedWindowOrders[device "|" parts[2]] := order
        }
        for key, order in DisplacedWindowOrders.Clone() {
            parts := StrSplit(key, "|")
            if !newIndex.Has(parts[1])
                continue
            orders[newIndex[parts[1]] ":" parts[2]] := order
            DisplacedWindowOrders.Delete(key)
        }
        WorkspaceWindowOrders.Clear()
        for key, order in orders
            WorkspaceWindowOrders[key] := order

        for key, record in RecentAppWorkspaces.Clone() {
            device := record.monitor >= 1 && record.monitor <= oldTopology.Length
                ? oldTopology[record.monitor].device : ""
            if newIndex.Has(device)
                record.monitor := newIndex[device]
            else
                RecentAppWorkspaces.Delete(key)
        }

        ; Windows whose monitor is back.
        homecoming := Map()
        for hwnd, home in DisplacedWindows.Clone() {
            alive := false
            try alive := WinExist("ahk_id " hwnd) && WinGetPID("ahk_id " hwnd) = home.pid
            if !alive {
                DisplacedWindows.Delete(hwnd)
                if !WindowWorkspace.Has(hwnd) && HiddenByScript.Has(hwnd)
                    HiddenByScript.Delete(hwnd)
                continue
            }
            if newIndex.Has(home.device) {
                homecoming[hwnd] := home
                DisplacedWindows.Delete(hwnd)
            }
        }

        moved := 0
        guests := 0
        waiting := 0
        for hwnd, slot in WindowWorkspace.Clone() {
            if homecoming.Has(hwnd)
                continue
            device := slot.monitor >= 1 && slot.monitor <= oldTopology.Length
                ? oldTopology[slot.monitor].device : ""
            if !device {
                ; Not numbered in the old layout. Reveal it for the scan to place.
                WindowWorkspace.Delete(hwnd)
                if HiddenByScript.Has(hwnd) {
                    ShowWindowFast(hwnd)
                    HiddenByScript.Delete(hwnd)
                }
                continue
            }
            if newIndex.Has(device) {
                monitor := newIndex[device]
                WindowWorkspace[hwnd] := {monitor: monitor, workspace: slot.workspace}
                ; Windows moved it off its monitor, e.g. while the monitor
                ; blinked off and back on.
                if WindowPlacements.Has(hwnd) && WindowPlacements[hwnd].device = device
                    && RestoreWindowPlacement(hwnd, WindowPlacements[hwnd],
                        oldTopology[slot.monitor], topology, monitor)
                    moved += 1
                continue
            }

            ; Its monitor left. A window already waiting keeps its first home.
            if !DisplacedWindows.Has(hwnd) {
                try pid := WinGetPID("ahk_id " hwnd)
                catch
                    pid := 0
                placement := WindowPlacements.Has(hwnd)
                    && WindowPlacements[hwnd].device = device ? WindowPlacements[hwnd] : false
                DisplacedWindows[hwnd] := {name: oldTopology[slot.monitor].name,
                    device: device, workspace: slot.workspace, pid: pid,
                    placement: placement, monitor: oldTopology[slot.monitor]}
            }
            if IsVisible(hwnd) && !HiddenByScript.Has(hwnd) {
                host := TopologyIndexForWindow(topology, hwnd)
                if host {
                    WindowWorkspace[hwnd] := {monitor: host, workspace: current[host]}
                    guests += 1
                    DebugLog("WINDOW_DISPLACED", "action=join-monitor host=" host
                        " workspace=D" current[host] " home=" device
                        " homeWorkspace=D" slot.workspace " " DebugDescribeWindow(hwnd))
                    continue
                }
            }
            WindowWorkspace.Delete(hwnd)
            waiting += 1
            DebugLog("WINDOW_DISPLACED", "action=wait-hidden home=" device
                " homeWorkspace=D" slot.workspace " " DebugDescribeWindow(hwnd))
        }

        returned := 0
        for hwnd, home in homecoming {
            monitor := newIndex[home.device]
            WindowWorkspace[hwnd] := {monitor: monitor, workspace: home.workspace}
            if home.placement
                RestoreWindowPlacement(hwnd, home.placement, home.monitor, topology, monitor)
            if home.workspace = current[monitor] {
                if HiddenByScript.Has(hwnd) {
                    ShowWindowFast(hwnd)
                    HiddenByScript.Delete(hwnd)
                }
            } else if IsVisible(hwnd) {
                CaptureWindowSnapshot(hwnd)
                HideWindowFast(hwnd)
                HiddenByScript[hwnd] := true
            }
            returned += 1
            DebugLog("WINDOW_RETURN", "monitor=" monitor " workspace=D" home.workspace
                " current=D" current[monitor] " " DebugDescribeWindow(hwnd))
        }
        for device in returningMonitors {
            monitor := newIndex[device]
            SetTimer(RestoreWorkspaceWindowOrder.Bind(monitor, current[monitor]), -150)
        }

        SetMonitorTopology(topology)
        DisplayTopologyPending := false
        for index, entry in topology
            DebugLog("MONITOR", "index=" index " name=" entry.name
                " bounds=" entry.left "," entry.top "," entry.right "," entry.bottom
                " current=D" current[index])
        DebugLog("DISPLAY_TOPOLOGY_COMMIT", "monitors=" topology.Length
            " moved=" moved " joined=" guests " waiting=" waiting " returned=" returned
            " displaced=" DisplacedWindows.Count " awayMonitors=" DisplacedMonitors.Count)
        SaveWorkspaceState()
        SetTimer(RefreshDesktopBackgrounds, -2000)
        for index, workspace in current
            SetTimer(VerifyWorkspaceTransition.Bind(index, workspace, 0), -400)
    } finally {
        Critical(previousCritical)
    }
}

TopologyIndexForRect(topology, rect) {
    ; The monitor holding most of the rectangle, else the nearest, as
    ; MonitorFromWindow does with MONITOR_DEFAULTTONEAREST.
    best := 0
    bestArea := 0
    for index, entry in topology {
        width := Min(rect.right, entry.right) - Max(rect.left, entry.left)
        height := Min(rect.bottom, entry.bottom) - Max(rect.top, entry.top)
        if width > 0 && height > 0 && width * height > bestArea {
            best := index
            bestArea := width * height
        }
    }
    if best
        return best
    bestDistance := -1
    for index, entry in topology {
        dx := rect.left > entry.right ? rect.left - entry.right
            : entry.left > rect.right ? entry.left - rect.right : 0
        dy := rect.top > entry.bottom ? rect.top - entry.bottom
            : entry.top > rect.bottom ? entry.top - rect.bottom : 0
        if bestDistance < 0 || dx * dx + dy * dy < bestDistance {
            best := index
            bestDistance := dx * dx + dy * dy
        }
    }
    return best
}

TopologyIndexForWindow(topology, hwnd) {
    record := ReadWindowPlacement(hwnd, topology)
    return record ? record.monitor : 0
}

GetWindowRectObject(hwnd) {
    rect := Buffer(16, 0)
    try {
        if !DllCall("GetWindowRect", "ptr", hwnd, "ptr", rect.Ptr)
            return false
    } catch
        return false
    return {left: NumGet(rect, 0, "int"), top: NumGet(rect, 4, "int"),
        right: NumGet(rect, 8, "int"), bottom: NumGet(rect, 12, "int")}
}

ReadWindowPlacement(hwnd, topology) {
    ; GetWindowPlacement and GetWindowRect read the window manager's own
    ; records, so a hung app cannot stall them.
    placement := Buffer(44, 0)
    NumPut("uint", 44, placement, 0)
    rect := GetWindowRectObject(hwnd)
    if !rect
        return false
    try {
        if !DllCall("GetWindowPlacement", "ptr", hwnd, "ptr", placement.Ptr)
            return false
    } catch
        return false
    showCmd := NumGet(placement, 8, "uint")
    ; A minimized window sits off screen; its restore position names its monitor.
    area := showCmd = 2
        ? {left: NumGet(placement, 28, "int"), top: NumGet(placement, 32, "int"),
            right: NumGet(placement, 36, "int"), bottom: NumGet(placement, 40, "int")}
        : rect
    monitor := TopologyIndexForRect(topology, area)
    return {placement: placement, showCmd: showCmd, monitor: monitor,
        device: monitor ? topology[monitor].device : "",
        left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom}
}

RecordWindowPlacements() {
    global WindowWorkspace, MonitorTopology
    placements := Map()
    for hwnd in WindowWorkspace {
        record := ReadWindowPlacement(hwnd, MonitorTopology)
        if record
            placements[hwnd] := record
    }
    return placements
}

RememberWindowPlacements() {
    global WindowPlacements, DisplayTopologyPending
    if DisplayTopologyPending
        return
    placements := RecordWindowPlacements()
    ; Keep the earlier record if the displays changed during this read.
    if DisplayTopologyChanging()
        return
    WindowPlacements := placements
}

MapWindowRect(rect, maximized, before, now) {
    ; Where a window belongs on its monitor as it is now. Unchanged monitors
    ; get the exact frame back.
    if before && SameMonitorGeometry(before, now)
        return {left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom}
    if maximized && before
        return {left: now.workLeft + rect.left - before.workLeft,
            top: now.workTop + rect.top - before.workTop,
            right: now.workRight + rect.right - before.workRight,
            bottom: now.workBottom + rect.bottom - before.workBottom}
    width := Min(rect.right - rect.left, now.workRight - now.workLeft)
    height := Min(rect.bottom - rect.top, now.workBottom - now.workTop)
    left := rect.left + (before ? now.left - before.left : 0)
    top := rect.top + (before ? now.top - before.top : 0)
    left := Max(now.workLeft, Min(left, now.workRight - width))
    top := Max(now.workTop, Min(top, now.workBottom - height))
    return {left: left, top: top, right: left + width, bottom: top + height}
}

MoveWindowFrame(hwnd, rect, responsive) {
    ; NOZORDER|NOACTIVATE|NOOWNERZORDER, posted to a hung app's thread.
    try return DllCall("SetWindowPos", "ptr", hwnd, "ptr", 0,
        "int", rect.left, "int", rect.top,
        "int", rect.right - rect.left, "int", rect.bottom - rect.top,
        "uint", responsive ? 0x0214 : 0x4214, "int") != 0
    catch
        return false
}

RestoreWindowPlacement(hwnd, record, before, topology, monitor) {
    global PlacementRestores
    ; Leave a window that is already on its monitor, such as one Windows
    ; itself put back.
    if TopologyIndexForWindow(topology, hwnd) = monitor
        return false
    now := topology[monitor]
    sameGeometry := !before || SameMonitorGeometry(before, now)
    minimized := record.showCmd = 2
    maximized := record.showCmd = 3
    visible := IsVisible(hwnd)
    responsive := IsWindowResponsive(hwnd)
    ; The placement holds the restore position and minimized or maximized
    ; state. It moves a minimized window home and keeps a hidden one hidden,
    ; but leaves a maximized window's frame on the monitor it is on.
    if (minimized || maximized) && sameGeometry {
        placement := Buffer(44, 0)
        DllCall("RtlMoveMemory", "ptr", placement.Ptr, "ptr", record.placement.Ptr, "uptr", 44)
        ; SW_HIDE, SW_SHOWMINNOACTIVE or SW_SHOWNA: never activate or reveal.
        NumPut("uint", !visible ? 0 : minimized ? 7 : 8, placement, 8)
        if !responsive
            NumPut("uint", NumGet(placement, 4, "uint") | 0x4, placement, 4) ; WPF_ASYNCWINDOWPLACEMENT
        try DllCall("SetWindowPlacement", "ptr", hwnd, "ptr", placement.Ptr)
    }
    target := false
    zoomed := DllCall("IsZoomed", "ptr", hwnd, "int") != 0
    if !minimized && zoomed = maximized && !DllCall("IsIconic", "ptr", hwnd, "int") {
        target := MapWindowRect(record, maximized, before, now)
        MoveWindowFrame(hwnd, target, responsive)
        ; An app that rescales itself for the new monitor's DPI is set again.
        PlacementRestores[hwnd] := {target: target, attempts: 0}
        SetTimer(VerifyRestoredWindowPlacements, -300)
    }
    DebugLog("WINDOW_PLACEMENT_RESTORE", "monitor=" monitor
        " state=" (minimized ? "minimized" : maximized ? "maximized" : "normal")
        " sameGeometry=" sameGeometry " responsive=" responsive
        " target=" (target ? target.left "," target.top "," target.right "," target.bottom
            : "placement") " " DebugDescribeWindow(hwnd))
    return true
}

VerifyRestoredWindowPlacements(*) {
    global PlacementRestores
    for hwnd, restore in PlacementRestores.Clone() {
        rect := WinExist("ahk_id " hwnd) ? GetWindowRectObject(hwnd) : false
        target := restore.target
        if !rect || rect.left = target.left && rect.top = target.top
            && rect.right = target.right && rect.bottom = target.bottom {
            PlacementRestores.Delete(hwnd)
            continue
        }
        if restore.attempts >= 2 {
            DebugLog("WINDOW_PLACEMENT_MISMATCH", "actual=" rect.left "," rect.top ","
                rect.right "," rect.bottom " target=" target.left "," target.top ","
                target.right "," target.bottom " " DebugDescribeWindow(hwnd))
            PlacementRestores.Delete(hwnd)
            continue
        }
        restore.attempts += 1
        MoveWindowFrame(hwnd, target, IsWindowResponsive(hwnd))
    }
    if PlacementRestores.Count
        SetTimer(VerifyRestoredWindowPlacements, -400)
}

AdoptReshownDisplacedWindows() {
    ; An app showed a window that is waiting for its disconnected monitor.
    ; Keep it on screen, in the workspace shown where it is, until then.
    global DisplacedWindows, WindowWorkspace, HiddenByScript, CurrentWorkspace
    for hwnd, home in DisplacedWindows {
        if WindowWorkspace.Has(hwnd) || !IsVisible(hwnd)
            continue
        MoveDisplacedWindowOnScreen(hwnd)
        if HiddenByScript.Has(hwnd)
            HiddenByScript.Delete(hwnd)
        monitor := GetWindowMonitor(hwnd)
        WindowWorkspace[hwnd] := {monitor: monitor,
            workspace: CurrentWorkspace.Has(monitor) ? CurrentWorkspace[monitor] : 1}
        DebugLog("WINDOW_DISPLACED", "action=shown-by-app monitor=" monitor
            " home=" home.device " homeWorkspace=D" home.workspace " "
            DebugDescribeWindow(hwnd))
        ScheduleWorkspaceStateSave()
    }
}

MoveDisplacedWindowOnScreen(hwnd) {
    ; A window that waited, hidden, for its monitor is still where that
    ; monitor was. Bring it onto the main monitor before showing it.
    global DisplacedWindows
    if DllCall("MonitorFromWindow", "ptr", hwnd, "uint", 0, "ptr") ; MONITOR_DEFAULTTONULL
        || DllCall("IsIconic", "ptr", hwnd, "int")
        return false
    now := ReadMonitorEntry(MonitorGetPrimary())
    rect := GetWindowRectObject(hwnd)
    if !now || !rect
        return false
    before := DisplacedWindows.Has(hwnd) ? DisplacedWindows[hwnd].monitor : false
    target := MapWindowRect(rect, DllCall("IsZoomed", "ptr", hwnd, "int") != 0, before, now)
    DebugLog("WINDOW_ONSCREEN", "target=" target.left "," target.top ","
        target.right "," target.bottom " " DebugDescribeWindow(hwnd))
    return MoveWindowFrame(hwnd, target, IsWindowResponsive(hwnd))
}

HandleSettingChange(wParam, *) {
    ; SPI_SETDESKWALLPAPER = 0x0014, SPI_SETWORKAREA = 0x002F. Wait for
    ; Explorer to finish the wallpaper transition before capturing it.
    if wParam = 0x0014 || wParam = 0x002F
        SetTimer(RefreshDesktopBackgrounds, -2000)
}

RestoreAllWindows(*) {
    global HiddenByScript, DisplacedWindows
    DebugLog("RESTORE_ALL_BEGIN", "count=" HiddenByScript.Count)
    for hwnd in HiddenByScript.Clone() {
        if WinExist("ahk_id " hwnd) {
            DebugLog("RESTORE_ALL_WINDOW", DebugDescribeWindow(hwnd))
            if DisplacedWindows.Has(hwnd)
                MoveDisplacedWindowOnScreen(hwnd)
            ShowWindowFast(hwnd)
        }
    }
    HiddenByScript.Clear()
    DebugLog("RESTORE_ALL_END", "count=0")
}

HandleAppExit(*) {
    DebugLog("APP_EXIT", "begin")
    RemoveForegroundWinEventHook()
    ClearTaskbarActivationShields("app-exit")
    SaveWorkspaceState()
    CloseWorkspaceOverview(false)
    ClearWorkspaceOverlays()
    RestoreAllWindows()
    ClearWindowSnapshots()
    ClearWorkspaceFrames()
    ClearDesktopBackgrounds()
    DebugLog("APP_EXIT", "complete")
}

ResetAndRevealAll(*) {
    global WindowRestartIdentity, RecentAppWorkspaces, RestartActivationUntil
    WindowRestartIdentity.Clear()
    RecentAppWorkspaces.Clear()
    RestartActivationUntil.Clear()
    global CarriedWorkspaceWindow
    SetTimer(FinishWorkspaceWindowDrag, 0)
    CarriedWorkspaceWindow := 0
    global CurrentWorkspace, WindowWorkspace, RequestedWorkspace
    global PendingWorkspaceSwitches, WorkspaceSlideSkipRequests
    global WorkspaceWindowOrders, PendingExternalActivations
    global DisplacedWindows, DisplacedMonitors, DisplacedWindowOrders
    global WindowPlacements, PlacementRestores, DisplayTopologyPending
    DebugLog("RESET", "begin")
    SetTimer(SettleDisplayTopologyChange, 0)
    DisplayTopologyPending := false
    ClearWorkspaceOverlays()
    ClearTaskbarActivationShields("reset")
    CloseWorkspaceOverview(false)
    RestoreAllWindows()
    WindowWorkspace.Clear()
    WorkspaceWindowOrders.Clear()
    for record in [DisplacedWindows, DisplacedMonitors, DisplacedWindowOrders,
        WindowPlacements, PlacementRestores]
        record.Clear()
    ClearWindowSnapshots()
    ClearWorkspaceFrames()
    ClearDesktopBackgrounds()
    CurrentWorkspace.Clear()
    RequestedWorkspace.Clear()
    PendingWorkspaceSwitches.Clear()
    WorkspaceSlideSkipRequests.Clear()
    PendingExternalActivations.Clear()
    InitializeMonitors()
    SyncRequestedWorkspaces()
    SaveWorkspaceState()
    ShowFeedbackForMonitor(GetMonitorUnderMouse(), 1, "Reset to")
    DebugLog("RESET", "complete")
}

BeginWorkspaceSlideAnimation(monitor, oldWorkspace, newWorkspace, direction, duration := 0,
    draggedHwnd := 0) {
    global WORKSPACE_SLIDE_MS, WorkspaceSlideAnimations
    if !duration
        duration := WORKSPACE_SLIDE_MS

    preparationStarted := A_TickCount
    CancelWorkspaceOverlay(monitor)
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    width := right - left
    height := bottom - top
    RefreshWorkspaceWindowSnapshots(monitor, oldWorkspace, draggedHwnd)
    outgoingCaptureStarted := A_TickCount
    outgoingFrame := CaptureMonitorWorkspaceFrame(monitor, oldWorkspace)
    ; The capture holds the live held window, which would slide away as a
    ; second copy. Paint over it with what lies beneath.
    if outgoingFrame && draggedHwnd
        PatchCarriedWindow(outgoingFrame, monitor, oldWorkspace, draggedHwnd)
    outgoingCaptureMs := A_TickCount - outgoingCaptureStarted
    if !outgoingFrame
        outgoingFrame := BuildWorkspaceFrameFromSnapshots(monitor, oldWorkspace, draggedHwnd)
    incomingWasCached := !draggedHwnd && GetWorkspaceFrame(monitor, newWorkspace) != false
    incomingStarted := A_TickCount
    incomingFrame := draggedHwnd ? false : GetWorkspaceFrame(monitor, newWorkspace)
    ; Without a cached frame, the incoming workspace is captured from its real
    ; windows once they are revealed behind the cover. Older Windows builds
    ; black out a window excluded from capture instead of omitting it. The
    ; outgoing frame stands in until then: at the starting offset the incoming
    ; half is entirely off screen.
    incomingPending := !incomingFrame && VerCompare(A_OSVersion, "10.0.19041") >= 0
    if incomingPending
        incomingFrame := outgoingFrame
    else if !incomingFrame
        incomingFrame := BuildWorkspaceFrameFromSnapshots(monitor, newWorkspace, draggedHwnd)
    incomingPreparationMs := A_TickCount - incomingStarted
    if !outgoingFrame || !incomingFrame {
        DebugLog("SLIDE_SKIP", "reason=frame-capture-failed monitor=" monitor
            " from=D" oldWorkspace " to=D" newWorkspace)
        return false
    }

    layer := CreatePhysicalPixelLayer()
    ; Layered so it can fade out over the revealed windows, and not
    ; click-through while it covers the switch: a click on an outgoing window
    ; would switch straight back.
    layer.Opt("-E0x20 +E0x80000")
    DllCall("SetLayeredWindowAttributes", "ptr", layer.Hwnd, "uint", 0, "uchar", 255,
        "uint", 2)
    ; Keep the real app in its existing Z-order and native mouse-capture loop.
    ; Only our own layer moves behind it; the app never becomes topmost.
    if draggedHwnd
        layer.Opt("-AlwaysOnTop")
    insertAfter := draggedHwnd ? draggedHwnd : -1
    state := {
        gui: layer, hwnd: 0, monitor: monitor,
        left: left, top: top, width: width, height: height,
        oldWorkspace: oldWorkspace, newWorkspace: newWorkspace,
        direction: direction, duration: duration, draggedHwnd: draggedHwnd,
        outgoingFrame: outgoingFrame, incomingFrame: incomingFrame,
        incomingPending: incomingPending, incomingExact: false,
        outgoingOffset: 0, incomingOffset: direction * width,
        bufferDc: 0, bufferBitmap: 0, oldBufferBitmap: 0, sourceDc: 0
    }

    state.hwnd := layer.Hwnd
    ; Size the still-hidden layer in physical pixels. Never use Gui.Show here:
    ; it can present a DPI-scaled intermediate frame before SetWindowPos fixes
    ; the dimensions, which looks like a zoom immediately before the slide.
    try DllCall("SetWindowPos", "ptr", state.hwnd, "ptr", insertAfter,
        "int", left, "int", top, "int", width, "int", height,
        "uint", 0x0010)
    if !InitializeWorkspaceSlideBackBuffer(state) {
        try layer.Destroy()
        DebugLog("SLIDE_SKIP", "reason=back-buffer-failed monitor=" monitor
            " resolution=" width "x" height " dpi=" GetMonitorDpi(monitor))
        return false
    }
    WorkspaceSlideAnimations[state.hwnd] := state
    try DllCall("SetWindowPos", "ptr", state.hwnd, "ptr", insertAfter,
        "int", left, "int", top, "int", width, "int", height,
        "uint", 0x0050)
    RenderWorkspaceSlideFrame(state)
    try DllCall("dwmapi\DwmFlush")
    DebugLog("SLIDE_BEGIN", "monitor=" monitor " from=D" oldWorkspace
        " to=D" newWorkspace " direction=" direction
        " carriedHwnd=" draggedHwnd
        " mode=double-buffered-bitblt durationMs=" state.duration
        " resolution=" width "x" height " dpi=" GetMonitorDpi(monitor)
        " geometry=" DebugWindowRenderGeometry(state.hwnd)
        " outgoingCaptureMs=" outgoingCaptureMs
        " incomingCached=" incomingWasCached
        " incomingPending=" incomingPending
        " incomingPreparationMs=" incomingPreparationMs
        " totalPreparationMs=" (A_TickCount - preparationStarted))
    return state
}

CompleteIncomingWorkspaceFrame(state, outgoingWindows) {
    started := A_TickCount
    ; A slow app can still be showing an outgoing window. Hiding is
    ; asynchronous, and the capture must not bake it into the new workspace.
    stillVisible := WaitForWindowsHidden(outgoingWindows, 260)
    ; Only this switch's cover may stand between the screen and the capture.
    CancelTaskbarActivationShield(state.monitor, 0, "incoming-capture")
    frame := false
    ; The cover stays on screen; screen captures alone look through it.
    if DllCall("SetWindowDisplayAffinity", "ptr", state.hwnd, "uint", 0x11, "int") {
        frame := CaptureMonitorWorkspaceFrame(state.monitor, state.newWorkspace)
        DllCall("SetWindowDisplayAffinity", "ptr", state.hwnd, "uint", 0, "int")
    }
    source := "screen"
    if frame && state.draggedHwnd {
        PatchCarriedWindow(frame, state.monitor, state.newWorkspace, state.draggedHwnd, true)
        source := "screen-patched"
    }
    if !frame {
        frame := BuildWorkspaceFrameFromSnapshots(state.monitor, state.newWorkspace,
            state.draggedHwnd)
        source := "snapshots"
    }
    if frame
        state.incomingFrame := frame
    state.incomingPending := false
    ; Only an untouched capture matches the revealed windows exactly.
    state.incomingExact := frame && source = "screen"
    DebugLog("SLIDE_INCOMING_CAPTURE", "monitor=" state.monitor
        " workspace=D" state.newWorkspace " source=" (frame ? source : "failed")
        " outgoingStillVisible=" stillVisible " elapsedMs=" (A_TickCount - started))
    return frame != false
}

WaitForWindowsHidden(windows, timeoutMs) {
    started := A_TickCount
    loop {
        visible := 0
        for hwnd in windows {
            if WinExist("ahk_id " hwnd) && IsVisible(hwnd)
                visible += 1
        }
        if !visible || A_TickCount - started >= timeoutMs
            return visible
        Sleep(8)
    }
}

RefreshWorkspaceWindowSnapshots(monitor, workspace, excludedHwnd := 0, within := false) {
    windows := GetOverviewWindows(monitor, workspace)
    for hwnd in windows {
        if hwnd = excludedHwnd
            continue
        ; Only on-screen windows can change; a window hidden by its own app
        ; has nothing to capture.
        if !WinExist("ahk_id " hwnd) || !IsVisible(hwnd)
            continue
        if within {
            rect := Buffer(16, 0)
            if !DllCall("GetWindowRect", "ptr", hwnd, "ptr", rect.Ptr)
                || NumGet(rect, 0, "int") >= within.right || NumGet(rect, 8, "int") <= within.left
                || NumGet(rect, 4, "int") >= within.bottom || NumGet(rect, 12, "int") <= within.top
                continue
        }
        try minimized := WinGetMinMax("ahk_id " hwnd) = -1
        catch
            minimized := false
        if !minimized
            CaptureWindowSnapshot(hwnd, !excludedHwnd)
    }
}

CaptureMonitorWorkspaceFrame(monitor, workspace) {
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    width := right - left
    height := bottom - top
    screenDc := DllCall("GetDC", "ptr", 0, "ptr")
    memoryDc := screenDc ? DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr") : 0
    bitmap := screenDc ? DllCall("CreateCompatibleBitmap", "ptr", screenDc,
        "int", width, "int", height, "ptr") : 0
    if !screenDc || !memoryDc || !bitmap {
        if bitmap
            DllCall("DeleteObject", "ptr", bitmap)
        if memoryDc
            DllCall("DeleteDC", "ptr", memoryDc)
        if screenDc
            DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
        return false
    }

    oldBitmap := DllCall("SelectObject", "ptr", memoryDc, "ptr", bitmap, "ptr")
    captured := DllCall("BitBlt", "ptr", memoryDc,
        "int", 0, "int", 0, "int", width, "int", height,
        "ptr", screenDc, "int", left, "int", top, "uint", 0x00CC0020, "int") != 0
    DllCall("SelectObject", "ptr", memoryDc, "ptr", oldBitmap)
    DllCall("DeleteDC", "ptr", memoryDc)
    DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
    if !captured {
        DllCall("DeleteObject", "ptr", bitmap)
        return false
    }
    return StoreWorkspaceFrame(monitor, workspace,
        {bitmap: bitmap, width: width, height: height})
}

BuildWorkspaceFrameFromSnapshots(monitor, workspace, excludedHwnd := 0) {
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    width := right - left
    height := bottom - top
    screenDc := DllCall("GetDC", "ptr", 0, "ptr")
    memoryDc := screenDc ? DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr") : 0
    bitmap := screenDc ? DllCall("CreateCompatibleBitmap", "ptr", screenDc,
        "int", width, "int", height, "ptr") : 0
    if !screenDc || !memoryDc || !bitmap {
        if bitmap
            DllCall("DeleteObject", "ptr", bitmap)
        if memoryDc
            DllCall("DeleteDC", "ptr", memoryDc)
        if screenDc
            DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
        return false
    }

    oldBitmap := DllCall("SelectObject", "ptr", memoryDc, "ptr", bitmap, "ptr")
    drawn := DrawWorkspaceFromSnapshots(memoryDc, screenDc, monitor, workspace, excludedHwnd)
    DllCall("SelectObject", "ptr", memoryDc, "ptr", oldBitmap)
    DllCall("DeleteDC", "ptr", memoryDc)
    DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
    DebugLog("SLIDE_FRAME_BUILD", "monitor=" monitor " workspace=D" workspace
        " windows=" drawn.windows " background=" drawn.background)
    return StoreWorkspaceFrame(monitor, workspace,
        {bitmap: bitmap, width: width, height: height})
}

PatchCarriedWindow(frame, monitor, workspace, carriedHwnd, refreshSnapshots := false) {
    ; The held window stays live above the slide, so a screen capture holds a
    ; second copy of it and its shadow. Repaint that area from the desktop and
    ; window snapshots to show what lies beneath it instead.
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    bounds := Buffer(16, 0)
    if DllCall("dwmapi\DwmGetWindowAttribute", "ptr", carriedHwnd, "uint", 9,
        "ptr", bounds.Ptr, "uint", 16, "int") != 0
        && !DllCall("GetWindowRect", "ptr", carriedHwnd, "ptr", bounds.Ptr)
        return false
    ; An inactive window's shadow reaches about 23, 6 and 54 px past its
    ; sides, top and bottom at 100% scaling, and the held window is active,
    ; whose shadow is larger.
    scale := GetMonitorDpi(monitor) / 96
    patchLeft := Max(left, NumGet(bounds, 0, "int") - Round(48 * scale))
    patchTop := Max(top, NumGet(bounds, 4, "int") - Round(24 * scale))
    patchRight := Min(right, NumGet(bounds, 8, "int") + Round(48 * scale))
    patchBottom := Min(bottom, NumGet(bounds, 12, "int") + Round(96 * scale))
    if patchRight <= patchLeft || patchBottom <= patchTop
        return false
    ; Revealed incoming windows can be captured afresh. Only the ones under
    ; the patch matter.
    if refreshSnapshots
        RefreshWorkspaceWindowSnapshots(monitor, workspace, carriedHwnd,
            {left: patchLeft, top: patchTop, right: patchRight, bottom: patchBottom})

    screenDc := DllCall("GetDC", "ptr", 0, "ptr")
    memoryDc := screenDc ? DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr") : 0
    if !memoryDc {
        if screenDc
            DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
        return false
    }
    oldBitmap := DllCall("SelectObject", "ptr", memoryDc, "ptr", frame.bitmap, "ptr")
    DllCall("IntersectClipRect", "ptr", memoryDc,
        "int", patchLeft - left, "int", patchTop - top,
        "int", patchRight - left, "int", patchBottom - top)
    drawn := DrawWorkspaceFromSnapshots(memoryDc, screenDc, monitor, workspace, carriedHwnd)
    DllCall("SelectObject", "ptr", memoryDc, "ptr", oldBitmap)
    DllCall("DeleteDC", "ptr", memoryDc)
    DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
    DebugLog("SLIDE_FRAME_PATCH", "monitor=" monitor " workspace=D" workspace
        " carriedHwnd=" carriedHwnd " rect=" (patchLeft - left) "," (patchTop - top)
        "," (patchRight - left) "," (patchBottom - top)
        " windows=" drawn.windows " background=" drawn.background)
    return true
}

DrawWorkspaceFromSnapshots(memoryDc, screenDc, monitor, workspace, excludedHwnd := 0) {
    global WindowSnapshots, OverviewPreviewMode
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
    width := right - left
    height := bottom - top
    ; Start from the real desktop, which is what shows around the windows once
    ; the workspace is revealed. A flat fill there reads as a dark flash.
    background := GetDesktopBackground(monitor, left, top, width, height)
    backgroundDrawn := false
    if background {
        backgroundDc := DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr")
        if backgroundDc {
            oldBackgroundBitmap := DllCall("SelectObject", "ptr", backgroundDc,
                "ptr", background.bitmap, "ptr")
            backgroundDrawn := DllCall("BitBlt", "ptr", memoryDc,
                "int", 0, "int", 0, "int", width, "int", height,
                "ptr", backgroundDc, "int", 0, "int", 0, "uint", 0x00CC0020, "int") != 0
            DllCall("SelectObject", "ptr", backgroundDc, "ptr", oldBackgroundBitmap)
            DllCall("DeleteDC", "ptr", backgroundDc)
        }
    }
    if !backgroundDrawn {
        backgroundRect := Buffer(16, 0)
        NumPut("int", 0, "int", 0, "int", width, "int", height, backgroundRect, 0)
        backgroundBrush := DllCall("CreateSolidBrush", "uint", 0x271811, "ptr")
        DllCall("FillRect", "ptr", memoryDc, "ptr", backgroundRect.Ptr, "ptr", backgroundBrush)
        DllCall("DeleteObject", "ptr", backgroundBrush)
    }

    windows := GetOverviewWindows(monitor, workspace)
    drawn := 0
    Loop windows.Length {
        hwnd := windows[windows.Length - A_Index + 1]
        if hwnd = excludedHwnd
            continue
        if !WinExist("ahk_id " hwnd)
            continue
        if !OverviewPreviewMode && !IsManageableWindow(hwnd)
            continue
        try minimized := WinGetMinMax("ahk_id " hwnd) = -1
        catch
            minimized := false
        if minimized
            continue
        if !WindowSnapshots.Has(hwnd)
            CaptureWindowSnapshot(hwnd, !excludedHwnd)
        if !WindowSnapshots.Has(hwnd)
            continue
        rect := Buffer(16, 0)
        if !DllCall("GetWindowRect", "ptr", hwnd, "ptr", rect.Ptr)
            continue
        windowLeft := NumGet(rect, 0, "int")
        windowTop := NumGet(rect, 4, "int")
        windowWidth := NumGet(rect, 8, "int") - windowLeft
        windowHeight := NumGet(rect, 12, "int") - windowTop
        if windowWidth <= 0 || windowHeight <= 0
            continue
        ; The invisible resize borders print as solid black. Draw only the
        ; visible frame so a floating window has no dark edge on the desktop.
        cropLeft := 0, cropTop := 0, cropRight := 0, cropBottom := 0
        frameRect := Buffer(16, 0)
        if DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 9,
            "ptr", frameRect.Ptr, "uint", 16, "int") = 0 {
            cropLeft := Max(0, NumGet(frameRect, 0, "int") - windowLeft)
            cropTop := Max(0, NumGet(frameRect, 4, "int") - windowTop)
            cropRight := Max(0, windowLeft + windowWidth - NumGet(frameRect, 8, "int"))
            cropBottom := Max(0, windowTop + windowHeight - NumGet(frameRect, 12, "int"))
            if cropLeft + cropRight >= windowWidth || cropTop + cropBottom >= windowHeight
                cropLeft := 0, cropTop := 0, cropRight := 0, cropBottom := 0
        }
        snapshot := WindowSnapshots[hwnd]
        scaleX := snapshot.width / windowWidth
        scaleY := snapshot.height / windowHeight
        DrawOverviewSnapshot(memoryDc, snapshot, {
            x: windowLeft - left + cropLeft, y: windowTop - top + cropTop,
            w: windowWidth - cropLeft - cropRight, h: windowHeight - cropTop - cropBottom
        }, {
            x: Round(cropLeft * scaleX), y: Round(cropTop * scaleY),
            w: Max(1, Round((windowWidth - cropLeft - cropRight) * scaleX)),
            h: Max(1, Round((windowHeight - cropTop - cropBottom) * scaleY))
        })
        drawn += 1
    }
    return {windows: drawn, background: backgroundDrawn ? "desktop" : "fill"}
}

GetWorkspaceFrame(monitor, workspace) {
    global WorkspaceFrames
    key := monitor ":" workspace
    return WorkspaceFrames.Has(key) ? WorkspaceFrames[key] : false
}

StoreWorkspaceFrame(monitor, workspace, frame) {
    global WorkspaceFrames
    key := monitor ":" workspace
    if WorkspaceFrames.Has(key) {
        previous := WorkspaceFrames[key]
        if previous.bitmap && previous.bitmap != frame.bitmap
            try DllCall("DeleteObject", "ptr", previous.bitmap)
    }
    WorkspaceFrames[key] := frame
    return frame
}

InvalidateWorkspaceFrame(monitor, workspace) {
    global WorkspaceFrames, DeferredWorkspaceFrameDeletes, Switching
    key := monitor ":" workspace
    if !WorkspaceFrames.Has(key)
        return
    frame := WorkspaceFrames[key]
    WorkspaceFrames.Delete(key)
    if frame.bitmap {
        if Switching
            DeferredWorkspaceFrameDeletes.Push(frame.bitmap)
        else
            try DllCall("DeleteObject", "ptr", frame.bitmap)
    }
    DebugLog("SLIDE_FRAME_INVALIDATE", "monitor=" monitor " workspace=D" workspace)
}

ClearWorkspaceFrames() {
    global WorkspaceFrames, DeferredWorkspaceFrameDeletes
    for key, frame in WorkspaceFrames.Clone() {
        if frame.bitmap
            try DllCall("DeleteObject", "ptr", frame.bitmap)
    }
    WorkspaceFrames.Clear()
    for bitmap in DeferredWorkspaceFrameDeletes {
        if bitmap
            try DllCall("DeleteObject", "ptr", bitmap)
    }
    DeferredWorkspaceFrameDeletes := []
}

FlushDeferredWorkspaceFrameDeletes() {
    global DeferredWorkspaceFrameDeletes
    for bitmap in DeferredWorkspaceFrameDeletes {
        if bitmap
            try DllCall("DeleteObject", "ptr", bitmap)
    }
    DeferredWorkspaceFrameDeletes := []
}

GetDesktopBackground(monitor, left, top, width, height) {
    global DesktopBackgroundsAttemptedAt
    background := FindDesktopBackground(monitor, left, top, width, height)
    ; Capture on demand when none fits the monitor's current work area, but
    ; do not retry a failing capture on every switch.
    if !background && (!DesktopBackgroundsAttemptedAt
        || A_TickCount - DesktopBackgroundsAttemptedAt >= 10000) {
        CaptureDesktopBackgrounds("missing")
        background := FindDesktopBackground(monitor, left, top, width, height)
    }
    return background
}

FindDesktopBackground(monitor, left, top, width, height) {
    global DesktopBackgrounds
    if !DesktopBackgrounds.Has(monitor)
        return false
    background := DesktopBackgrounds[monitor]
    return background.left = left && background.top = top
        && background.width = width && background.height = height ? background : false
}

CaptureDesktopBackgrounds(reason) {
    global DesktopBackgrounds, DesktopBackgroundsCapturedAt, DesktopBackgroundsAttemptedAt
    ; A hotkey interrupting this would capture again and free bitmaps in use.
    previousCritical := Critical("On")
    try {
        started := A_TickCount
        DesktopBackgroundsAttemptedAt := started
        ; Explorer renders the wallpaper and desktop icons into Progman, and a
        ; full-content print returns them even while app windows cover it.
        progman := WinExist("ahk_class Progman")
        if !progman || !IsWindowResponsive(progman) {
            DebugLog("DESKTOP_BACKGROUND_SKIP", "reason=" reason " progman=" progman)
            return false
        }
        rect := Buffer(16, 0)
        if !DllCall("GetWindowRect", "ptr", progman, "ptr", rect.Ptr)
            return false
        desktopLeft := NumGet(rect, 0, "int")
        desktopTop := NumGet(rect, 4, "int")
        desktopWidth := NumGet(rect, 8, "int") - desktopLeft
        desktopHeight := NumGet(rect, 12, "int") - desktopTop
        if desktopWidth <= 0 || desktopHeight <= 0
            return false

        screenDc := DllCall("GetDC", "ptr", 0, "ptr")
        desktopDc := screenDc ? DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr") : 0
        cropDc := screenDc ? DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr") : 0
        desktopBitmap := screenDc ? DllCall("CreateCompatibleBitmap", "ptr", screenDc,
            "int", desktopWidth, "int", desktopHeight, "ptr") : 0
        captured := 0
        printed := false
        if desktopDc && cropDc && desktopBitmap {
            oldDesktopBitmap := DllCall("SelectObject", "ptr", desktopDc,
                "ptr", desktopBitmap, "ptr")
            ; Printing into a monitor-sized bitmap with a shifted origin draws
            ; the wrong region, so print the whole desktop and crop it.
            printed := DllCall("PrintWindow", "ptr", progman, "ptr", desktopDc,
                "uint", 2, "int") != 0
            if printed {
                Loop MonitorGetCount() {
                    monitor := A_Index
                    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)
                    width := right - left
                    height := bottom - top
                    bitmap := DllCall("CreateCompatibleBitmap", "ptr", screenDc,
                        "int", width, "int", height, "ptr")
                    if !bitmap
                        continue
                    oldCropBitmap := DllCall("SelectObject", "ptr", cropDc, "ptr", bitmap, "ptr")
                    copied := DllCall("BitBlt", "ptr", cropDc,
                        "int", 0, "int", 0, "int", width, "int", height,
                        "ptr", desktopDc, "int", left - desktopLeft, "int", top - desktopTop,
                        "uint", 0x00CC0020, "int") != 0
                    DllCall("SelectObject", "ptr", cropDc, "ptr", oldCropBitmap)
                    if !copied {
                        DllCall("DeleteObject", "ptr", bitmap)
                        continue
                    }
                    if DesktopBackgrounds.Has(monitor)
                        try DllCall("DeleteObject", "ptr", DesktopBackgrounds[monitor].bitmap)
                    DesktopBackgrounds[monitor] := {bitmap: bitmap,
                        left: left, top: top, width: width, height: height}
                    captured += 1
                }
            }
            DllCall("SelectObject", "ptr", desktopDc, "ptr", oldDesktopBitmap)
        }
        if desktopBitmap
            DllCall("DeleteObject", "ptr", desktopBitmap)
        if cropDc
            DllCall("DeleteDC", "ptr", cropDc)
        if desktopDc
            DllCall("DeleteDC", "ptr", desktopDc)
        if screenDc
            DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
        if captured
            DesktopBackgroundsCapturedAt := A_TickCount
        DebugLog("DESKTOP_BACKGROUND_CAPTURE", "reason=" reason " printed=" printed
            " monitors=" captured " desktop=" desktopWidth "x" desktopHeight
            " elapsedMs=" (A_TickCount - started))
        return captured > 0
    } finally {
        Critical(previousCritical)
    }
}

ClearDesktopBackgrounds() {
    global DesktopBackgrounds, DesktopBackgroundsCapturedAt, DesktopBackgroundsAttemptedAt
    for monitor, background in DesktopBackgrounds {
        if background.bitmap
            try DllCall("DeleteObject", "ptr", background.bitmap)
    }
    DesktopBackgrounds.Clear()
    DesktopBackgroundsCapturedAt := 0
    DesktopBackgroundsAttemptedAt := 0
}

RefreshDesktopBackgrounds(*) {
    global Switching
    if Switching {
        SetTimer(RefreshDesktopBackgrounds, -300)
        return
    }
    CaptureDesktopBackgrounds("scheduled")
}

RefreshDesktopBackgroundsWhenIdle(*) {
    global DESKTOP_BACKGROUND_REFRESH_MS, DesktopBackgroundsCapturedAt
    global Switching, WorkspaceOverview, TaskbarActivationShields
    ; Desktop icons and slideshow wallpapers change without a notification.
    ; Refresh only while the user pauses, so a capture never delays a switch
    ; or stutters a fullscreen game.
    if DesktopBackgroundsCapturedAt
        && A_TickCount - DesktopBackgroundsCapturedAt < DESKTOP_BACKGROUND_REFRESH_MS
        return
    if Switching || WorkspaceOverview || TaskbarActivationShields.Count
        || A_TimeIdle < 1500 || IsForegroundFullscreen()
        return
    CaptureDesktopBackgrounds("idle")
}

InitializeWorkspaceSlideBackBuffer(state) {
    screenDc := DllCall("GetDC", "ptr", 0, "ptr")
    if !screenDc
        return false
    state.bufferDc := DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr")
    state.sourceDc := DllCall("CreateCompatibleDC", "ptr", screenDc, "ptr")
    state.bufferBitmap := DllCall("CreateCompatibleBitmap", "ptr", screenDc,
        "int", state.width, "int", state.height, "ptr")
    DllCall("ReleaseDC", "ptr", 0, "ptr", screenDc)
    if !state.bufferDc || !state.sourceDc || !state.bufferBitmap {
        DestroyWorkspaceSlideBackBuffer(state)
        return false
    }
    state.oldBufferBitmap := DllCall("SelectObject", "ptr", state.bufferDc,
        "ptr", state.bufferBitmap, "ptr")
    DebugLog("SLIDE_BUFFER_INIT", "monitor=" state.monitor
        " resolution=" state.width "x" state.height
        " bytes=" (state.width * state.height * 4)
        " bufferDc=" state.bufferDc " sourceDc=" state.sourceDc)
    return true
}

PaintWorkspaceSlide(hwnd) {
    global WorkspaceSlideAnimations
    if !WorkspaceSlideAnimations.Has(hwnd)
        return
    state := WorkspaceSlideAnimations[hwnd]
    paint := Buffer(72, 0)
    hdc := DllCall("BeginPaint", "ptr", hwnd, "ptr", paint.Ptr, "ptr")
    if hdc {
        RenderWorkspaceSlideFrame(state, hdc)
        DllCall("EndPaint", "ptr", hwnd, "ptr", paint.Ptr)
    }
}

RenderWorkspaceSlideFrame(state, destinationDc := 0) {
    if !state.bufferDc || !state.sourceDc
        return false

    ; The two frames cover every pixel, but clear the back buffer defensively
    ; without asking Windows to erase the visible animation window.
    DllCall("PatBlt", "ptr", state.bufferDc,
        "int", 0, "int", 0, "int", state.width, "int", state.height,
        "uint", 0x00000042)

    oldSourceBitmap := DllCall("SelectObject", "ptr", state.sourceDc,
        "ptr", state.outgoingFrame.bitmap, "ptr")
    DllCall("BitBlt", "ptr", state.bufferDc,
        "int", state.outgoingOffset, "int", 0,
        "int", state.width, "int", state.height,
        "ptr", state.sourceDc, "int", 0, "int", 0,
        "uint", 0x00CC0020)
    DllCall("SelectObject", "ptr", state.sourceDc, "ptr", state.incomingFrame.bitmap)
    DllCall("BitBlt", "ptr", state.bufferDc,
        "int", state.incomingOffset, "int", 0,
        "int", state.width, "int", state.height,
        "ptr", state.sourceDc, "int", 0, "int", 0,
        "uint", 0x00CC0020)
    DllCall("SelectObject", "ptr", state.sourceDc, "ptr", oldSourceBitmap)

    releaseDestination := false
    if !destinationDc {
        destinationDc := DllCall("GetDC", "ptr", state.hwnd, "ptr")
        releaseDestination := true
    }
    if !destinationDc
        return false
    result := DllCall("BitBlt", "ptr", destinationDc,
        "int", 0, "int", 0, "int", state.width, "int", state.height,
        "ptr", state.bufferDc, "int", 0, "int", 0,
        "uint", 0x00CC0020)
    if releaseDestination
        DllCall("ReleaseDC", "ptr", state.hwnd, "ptr", destinationDc)
    return result != 0
}

DestroyWorkspaceSlideBackBuffer(state) {
    if state.bufferDc && state.oldBufferBitmap
        try DllCall("SelectObject", "ptr", state.bufferDc, "ptr", state.oldBufferBitmap)
    if state.bufferBitmap
        try DllCall("DeleteObject", "ptr", state.bufferBitmap)
    if state.sourceDc
        try DllCall("DeleteDC", "ptr", state.sourceDc)
    if state.bufferDc
        try DllCall("DeleteDC", "ptr", state.bufferDc)
    state.bufferDc := 0
    state.sourceDc := 0
    state.bufferBitmap := 0
    state.oldBufferBitmap := 0
}

RunWorkspaceSlideAnimation(state) {
    global WorkspaceSlideSkipRequests
    if !state
        return

    started := A_TickCount
    previousPresented := started
    frameCount := 0
    intervalTotal := 0
    maxInterval := 0
    maxRenderMs := 0
    slowFrames := 0
    accelerated := false
    Loop {
        if WorkspaceSlideSkipRequests.Has(state.monitor) {
            WorkspaceSlideSkipRequests.Delete(state.monitor)
            accelerated := true
            progress := 1
            DebugLog("SLIDE_ACCELERATE", "monitor=" state.monitor
                " from=D" state.oldWorkspace " to=D" state.newWorkspace
                " elapsedMs=" (A_TickCount - started))
        } else {
            progress := Min(1, (A_TickCount - started) / state.duration)
        }
        ; Ease-in-out cubic gives the transition weight without overshoot.
        eased := progress < 0.5
            ? 4 * progress * progress * progress
            : 1 - (((-2 * progress + 2) ** 3) / 2)
        outgoingOffset := Round(-state.direction * state.width * eased)
        ; Keep both full-frame edges locked to the exact same pixel so rounding
        ; can never expose a one-pixel gap between workspaces.
        incomingOffset := outgoingOffset + (state.direction * state.width)
        state.outgoingOffset := outgoingOffset
        state.incomingOffset := incomingOffset

        renderStarted := A_TickCount
        RenderWorkspaceSlideFrame(state)
        flushStarted := A_TickCount
        try DllCall("dwmapi\DwmFlush")
        presented := A_TickCount
        renderMs := presented - renderStarted
        if renderMs > 250
            DebugLog("SLIDE_FRAME_SLOW", "monitor=" state.monitor
                " drawMs=" (flushStarted - renderStarted)
                " compositorWaitMs=" (presented - flushStarted))
        maxRenderMs := Max(maxRenderMs, renderMs)
        frameCount += 1
        if frameCount > 1 {
            interval := presented - previousPresented
            intervalTotal += interval
            maxInterval := Max(maxInterval, interval)
            if interval > 20
                slowFrames += 1
        }
        previousPresented := presented
        if progress >= 1
            break
        Sleep(1)
    }
    averageInterval := frameCount > 1 ? Round(intervalTotal / (frameCount - 1), 2) : 0
    DebugLog("SLIDE_COMPLETE", "monitor=" state.monitor " from=D" state.oldWorkspace
        " to=D" state.newWorkspace " elapsedMs=" (A_TickCount - started)
        " frames=" frameCount " averageIntervalMs=" averageInterval
        " maxIntervalMs=" maxInterval " maxRenderMs=" maxRenderMs
        " slowFramesOver20Ms=" slowFrames " accelerated=" accelerated)
}

FadeOutWorkspaceSlide(state) {
    global WORKSPACE_FADE_MS, PendingWorkspaceSwitches, WorkspaceSlideSkipRequests
    ; The real windows are in place under the cover now. A cached frame can
    ; be older than what an app drew while hidden, and a patched one only
    ; approximates what lay under a held window, so fade the cover out
    ; instead of cutting to the windows. A capture taken moments ago already
    ; matches them, and a queued switch should not wait.
    if !state || state.incomingExact || PendingWorkspaceSwitches.Count
        || WorkspaceSlideSkipRequests.Has(state.monitor)
        return
    ; Let input reach the revealed windows while the cover fades.
    try WinSetExStyle("+0x20", "ahk_id " state.hwnd)
    started := A_TickCount
    frames := 0
    loop {
        progress := Min(1, (A_TickCount - started) / WORKSPACE_FADE_MS)
        eased := progress < 0.5 ? 2 * progress * progress : 1 - ((-2 * progress + 2) ** 2) / 2
        DllCall("SetLayeredWindowAttributes", "ptr", state.hwnd, "uint", 0,
            "uchar", Round(255 * (1 - eased)), "uint", 2)
        try DllCall("dwmapi\DwmFlush")
        frames += 1
        if progress >= 1 || PendingWorkspaceSwitches.Count
            || WorkspaceSlideSkipRequests.Has(state.monitor)
            break
        Sleep(1)
    }
    DebugLog("SLIDE_FADE", "monitor=" state.monitor " to=D" state.newWorkspace
        " frames=" frames " elapsedMs=" (A_TickCount - started))
}

EndWorkspaceSlideAnimation(state) {
    global WorkspaceSlideAnimations
    if state {
        if WorkspaceSlideAnimations.Has(state.hwnd)
            WorkspaceSlideAnimations.Delete(state.hwnd)
        try state.gui.Destroy()
        DestroyWorkspaceSlideBackBuffer(state)
    }
    FlushDeferredWorkspaceFrameDeletes()
    if state
        DebugLog("SLIDE_END", "monitor=" state.monitor " from=D" state.oldWorkspace
            " to=D" state.newWorkspace)
}

ShowWorkspaceOverlay(monitor, workspace, direction := 0) {
    global SHOW_FEEDBACK, INDICATOR_MS, WorkspaceOverlays
    if !SHOW_FEEDBACK
        return

    ; Creating/showing a GUI pumps messages. A second update must not run
    ; between cancelling the old indicator and publishing its replacement,
    ; or the first GUI loses its owner and can remain visible indefinitely.
    previousCritical := Critical("On")
    try {
        CreateWorkspaceOverlay(monitor, workspace, direction)
    } finally {
        Critical(previousCritical)
    }
}

CreateWorkspaceOverlay(monitor, workspace, direction) {
    global INDICATOR_MS, WorkspaceOverlays
    DebugLog("OVERLAY_SHOW", "monitor=" monitor " workspace=D" workspace
        " direction=" direction)
    CancelWorkspaceOverlay(monitor)
    MonitorGetWorkArea(monitor, &left, &top, &right, &bottom)

    width := 78
    height := 44
    targetX := left + ((right - left - width) // 2)
    targetY := top + 20
    label := "D" workspace

    overlay := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 -DPIScale")
    overlay.BackColor := "111827"
    overlay.MarginX := 0
    overlay.MarginY := 0
    overlay.SetFont("s18 cFFFFFF w600", "Segoe UI")
    overlay.AddText("x0 y0 w78 h44 Center +0x200 BackgroundTrans", label)

    hwnd := overlay.Hwnd
    state := {
        gui: overlay, hwnd: hwnd, monitor: monitor,
        workspace: workspace,
        targetX: targetX, y: targetY, expiresAt: A_TickCount + INDICATOR_MS
    }
    state.dismissTimer := CancelWorkspaceOverlay.Bind(monitor, state)
    WorkspaceOverlays[monitor] := state
    try {
        SetTimer(state.dismissTimer, -INDICATOR_MS)
        overlay.Show("NA x" targetX " y" targetY " w" width " h" height)
        try WinSetRegion("0-0 W" width " H" height " R12-12", "ahk_id " hwnd)
        try WinSetTransparent(238, "ahk_id " hwnd)
    } catch as error {
        CancelWorkspaceOverlay(monitor, state)
        throw error
    }
}

AnimateWorkspaceOverlay(state) {
    global WorkspaceOverlays
    if !WorkspaceOverlays.Has(state.monitor)
        return
    if WorkspaceOverlays[state.monitor].hwnd != state.hwnd
        return

    t := Min(1, (A_TickCount - state.started) / state.duration)
    ease := 1 - ((1 - t) ** 3)
    x := state.startX + ((state.targetX - state.startX) * ease)
    alpha := Round(238 * Min(1, t / 0.45))
    try WinMove(Round(x), state.y,,, "ahk_id " state.hwnd)
    try WinSetTransparent(alpha, "ahk_id " state.hwnd)

    if t >= 1 {
        SetTimer(state.moveTimer, 0)
        SetTimer(BeginWorkspaceOverlayFade.Bind(state), -650)
    }
}

BeginWorkspaceOverlayFade(state) {
    global WorkspaceOverlays
    if !WorkspaceOverlays.Has(state.monitor)
        return
    if WorkspaceOverlays[state.monitor].hwnd != state.hwnd
        return

    state.fadeStarted := A_TickCount
    state.fadeTimer := FadeWorkspaceOverlay.Bind(state)
    SetTimer(state.fadeTimer, 16)
}

FadeWorkspaceOverlay(state) {
    global WorkspaceOverlays
    if !WorkspaceOverlays.Has(state.monitor)
        return
    if WorkspaceOverlays[state.monitor].hwnd != state.hwnd
        return

    t := Min(1, (A_TickCount - state.fadeStarted) / 150)
    try WinSetTransparent(Round(238 * (1 - t)), "ahk_id " state.hwnd)
    if t >= 1 {
        SetTimer(state.fadeTimer, 0)
        CancelWorkspaceOverlay(state.monitor)
    }
}

CancelWorkspaceOverlay(monitor, expectedState := false) {
    previousCritical := Critical("On")
    try {
        DestroyWorkspaceOverlay(monitor, expectedState)
    } finally {
        Critical(previousCritical)
    }
}

DestroyWorkspaceOverlay(monitor, expectedState := false) {
    global WorkspaceOverlays
    if !WorkspaceOverlays.Has(monitor)
        return

    state := WorkspaceOverlays[monitor]
    ; A delayed callback belongs to one instance, never its replacement.
    if expectedState && state != expectedState
        return
    ; Relinquish ownership before stopping timers or destroying the GUI. Those
    ; operations can dispatch pending timer/window messages re-entrantly; any
    ; duplicate cancellation must see that this overlay is already gone.
    WorkspaceOverlays.Delete(monitor)
    DebugLog("OVERLAY_CANCEL", "monitor=" monitor " workspace=D" state.workspace
        " hwnd=" state.hwnd)
    if state.HasOwnProp("moveTimer")
        try SetTimer(state.moveTimer, 0)
    if state.HasOwnProp("dismissTimer") {
        try SetTimer(state.dismissTimer, 0)
        ; The callback holds this state; release the reverse reference too.
        state.DeleteProp("dismissTimer")
    }
    if state.HasOwnProp("fadeTimer")
        try SetTimer(state.fadeTimer, 0)
    try state.gui.Hide()
    try state.gui.Destroy()
    catch as error {
        DebugLog("OVERLAY_DESTROY_ERROR", "monitor=" monitor
            " hwnd=" state.hwnd " message=" DebugClean(error.Message))
    }
}

CheckWorkspaceOverlayHealth() {
    global WorkspaceOverlays, CurrentWorkspace
    for monitor, state in WorkspaceOverlays.Clone() {
        if A_TickCount >= state.expiresAt
            || !CurrentWorkspace.Has(monitor)
            || CurrentWorkspace[monitor] != state.workspace
            CancelWorkspaceOverlay(monitor, state)
    }
}

ClearWorkspaceOverlays() {
    global WorkspaceOverlays
    for monitor, state in WorkspaceOverlays.Clone()
        CancelWorkspaceOverlay(monitor, state)
}

ShowFeedbackForMonitor(monitor, workspace, *) {
    ShowWorkspaceOverlay(monitor, workspace)
}

OpenDebugLog(*) {
    global DEBUG_LOG_PATH
    DebugLog("DEBUG_LOG_OPEN", "path=" DEBUG_LOG_PATH)
    try Run('notepad.exe "' DEBUG_LOG_PATH '"')
}

ScheduleWorkspaceStateSave(*) {
    global WorkspaceStatePersistenceEnabled
    if !WorkspaceStatePersistenceEnabled
        return
    SetTimer(SaveWorkspaceState, -250)
}

SaveWorkspaceState(*) {
    global CurrentWorkspace, WindowWorkspace, WORKSPACE_STATE_PATH, WORKSPACE_COUNT
    global WorkspaceStatePersistenceEnabled, WorkspaceWindowOrders, HiddenByScript
    global MonitorTopology, DisplayTopologyPending, DisplacedMonitors, DisplacedWindows
    if !WorkspaceStatePersistenceEnabled
        return
    ; Mid-change monitor numbers would save windows under the wrong monitor.
    ; The last state saved before the change stays until it settles.
    if DisplayTopologyPending {
        DebugLog("STATE_SAVE_SKIP", "reason=display-change")
        return
    }
    try {
        SplitPath(WORKSPACE_STATE_PATH,, &stateDirectory)
        DirCreate(stateDirectory)
        ; Refresh the stack for each workspace that is currently visible. Hidden
        ; workspaces keep the order captured immediately before they were left.
        for monitor, entry in MonitorTopology {
            if CurrentWorkspace.Has(monitor)
                RememberWorkspaceWindowOrder(monitor, CurrentWorkspace[monitor])
        }

        contents := "IMW_STATE_V2`n"
        for monitor, entry in MonitorTopology {
            workspace := CurrentWorkspace.Has(monitor) ? CurrentWorkspace[monitor] : 1
            contents .= "M`t" entry.name "`t" workspace "`n"
        }
        ; Disconnected monitors keep their workspace and geometry, which later
        ; versions read to put their windows back.
        for device, away in DisplacedMonitors {
            contents .= "M`t" away.name "`t" away.workspace
            if away.monitor {
                geometry := away.monitor
                for field in ["left", "top", "right", "bottom",
                    "workLeft", "workTop", "workRight", "workBottom"]
                    contents .= "`t" geometry.%field%
            }
            contents .= "`n"
        }
        savedWindows := 0
        for hwnd, slot in WindowWorkspace {
            if !WinExist("ahk_id " hwnd)
                continue
            if slot.monitor < 1 || slot.monitor > MonitorTopology.Length
                continue
            try pid := WinGetPID("ahk_id " hwnd)
            catch
                continue
            ; 0 marks a window its own app hid (tray apps, popups), which a
            ; restart must neither show nor treat as hidden by this script.
            shown := IsVisible(hwnd) || HiddenByScript.Has(hwnd) ? 1 : 0
            contents .= "W`t" hwnd "`t" pid "`t" MonitorTopology[slot.monitor].name
                . "`t" slot.workspace "`t" shown "`n"
            savedWindows += 1
        }
        ; Each window waiting for a disconnected monitor, with its place there.
        for hwnd, home in DisplacedWindows {
            try pid := WinExist("ahk_id " hwnd) ? WinGetPID("ahk_id " hwnd) : 0
            catch
                pid := 0
            if !pid || pid != home.pid
                continue
            shown := IsVisible(hwnd) || HiddenByScript.Has(hwnd) ? 1 : 0
            contents .= "H`t" hwnd "`t" pid "`t" home.name "`t" home.workspace "`t" shown
            if home.placement {
                record := home.placement
                contents .= "`t" record.showCmd "`t" NumGet(record.placement, 4, "uint")
                Loop 8 ; minimized and maximized positions, restore rectangle
                    contents .= "`t" NumGet(record.placement, 8 + A_Index * 4, "int")
                contents .= "`t" record.left "`t" record.top "`t" record.right
                    . "`t" record.bottom
            }
            contents .= "`n"
        }

        savedOrderEntries := 0
        for key, order in WorkspaceWindowOrders {
            rank := 0
            for hwnd in order {
                if !WinExist("ahk_id " hwnd) || !WindowWorkspace.Has(hwnd)
                    continue
                slot := WindowWorkspace[hwnd]
                if WorkspaceWindowOrderKey(slot.monitor, slot.workspace) != key
                    continue
                try pid := WinGetPID("ahk_id " hwnd)
                catch
                    continue
                rank += 1
                contents .= "O`t" hwnd "`t" pid "`t" MonitorTopology[slot.monitor].name
                    . "`t" slot.workspace "`t" rank "`n"
                savedOrderEntries += 1
            }
        }

        temporaryPath := WORKSPACE_STATE_PATH ".tmp"
        if FileExist(temporaryPath)
            FileDelete(temporaryPath)
        FileAppend(contents, temporaryPath, "UTF-8")
        FileMove(temporaryPath, WORKSPACE_STATE_PATH, true)
        DebugLog("STATE_SAVE", "path=" WORKSPACE_STATE_PATH
            " monitors=" MonitorTopology.Length " windows=" savedWindows
            " orderEntries=" savedOrderEntries " waiting=" DisplacedWindows.Count)
    } catch as error {
        DebugLog("STATE_SAVE_ERROR", "message=" DebugClean(error.Message))
    }
}

LoadWorkspaceState() {
    global CurrentWorkspace, WindowWorkspace, WORKSPACE_STATE_PATH, WORKSPACE_COUNT
    global WorkspaceWindowOrders, RestoredSelfHiddenWindows, HiddenByScript
    global MonitorTopology, DisplacedMonitors, DisplacedWindows
    if !FileExist(WORKSPACE_STATE_PATH) {
        DebugLog("STATE_LOAD", "result=missing path=" WORKSPACE_STATE_PATH)
        return false
    }

    monitorLookup := Map()
    for monitor, entry in MonitorTopology
        monitorLookup[entry.device] := monitor
    savedGeometry := Map()
    homes := Map()

    restoredMonitors := 0
    restoredWindows := 0
    restoredOrderEntries := 0
    rejectedWindows := 0
    try contents := FileRead(WORKSPACE_STATE_PATH, "UTF-8")
    catch as error {
        DebugLog("STATE_LOAD_ERROR", "message=" DebugClean(error.Message))
        return false
    }

    for line in StrSplit(contents, "`n", "`r") {
        if !line || line = "IMW_STATE_V1" || line = "IMW_STATE_V2"
            continue
        fields := StrSplit(line, "`t")
        if fields.Length >= 3 && fields[1] = "M" {
            deviceName := StrLower(fields[2])
            try workspace := Integer(fields[3])
            catch
                continue
            if workspace < 1 || workspace > WORKSPACE_COUNT
                continue
            if fields.Length >= 11 {
                try savedGeometry[deviceName] := {name: fields[2], device: deviceName,
                    left: Integer(fields[4]), top: Integer(fields[5]),
                    right: Integer(fields[6]), bottom: Integer(fields[7]),
                    workLeft: Integer(fields[8]), workTop: Integer(fields[9]),
                    workRight: Integer(fields[10]), workBottom: Integer(fields[11])}
            }
            if monitorLookup.Has(deviceName) {
                CurrentWorkspace[monitorLookup[deviceName]] := workspace
                restoredMonitors += 1
            } else
                DisplacedMonitors[deviceName] := {name: fields[2], workspace: workspace,
                    monitor: savedGeometry.Has(deviceName) ? savedGeometry[deviceName] : false}
            continue
        }
        if fields.Length >= 6 && fields[1] = "H" {
            try {
                hwnd := Integer(fields[2])
                expectedPid := Integer(fields[3])
                workspace := Integer(fields[5])
                shown := Integer(fields[6])
                actualPid := WinExist("ahk_id " hwnd) ? WinGetPID("ahk_id " hwnd) : 0
            } catch
                continue
            if !actualPid || actualPid != expectedPid
                || workspace < 1 || workspace > WORKSPACE_COUNT
                continue
            placement := false
            if fields.Length >= 20 {
                try {
                    stored := Buffer(44, 0)
                    NumPut("uint", 44, stored, 0)
                    NumPut("uint", Integer(fields[8]), stored, 4)
                    NumPut("uint", Integer(fields[7]), stored, 8)
                    Loop 8
                        NumPut("int", Integer(fields[8 + A_Index]), stored, 8 + A_Index * 4)
                    placement := {placement: stored, showCmd: Integer(fields[7]),
                        device: StrLower(fields[4]), monitor: 0,
                        left: Integer(fields[17]), top: Integer(fields[18]),
                        right: Integer(fields[19]), bottom: Integer(fields[20])}
                }
            }
            homes[hwnd] := {name: fields[4], device: StrLower(fields[4]),
                workspace: workspace, pid: expectedPid, shown: shown,
                placement: placement, monitor: false}
            continue
        }
        if fields.Length >= 6 && fields[1] = "O" {
            try {
                hwnd := Integer(fields[2])
                expectedPid := Integer(fields[3])
                deviceName := StrLower(fields[4])
                workspace := Integer(fields[5])
                rank := Integer(fields[6])
            } catch
                continue
            if !monitorLookup.Has(deviceName) || workspace < 1
                || workspace > WORKSPACE_COUNT || rank < 1
                || !WinExist("ahk_id " hwnd) || !WindowWorkspace.Has(hwnd)
                continue
            try actualPid := WinGetPID("ahk_id " hwnd)
            catch
                continue
            monitor := monitorLookup[deviceName]
            slot := WindowWorkspace[hwnd]
            if actualPid != expectedPid || slot.monitor != monitor
                || slot.workspace != workspace
                continue
            key := WorkspaceWindowOrderKey(monitor, workspace)
            if !WorkspaceWindowOrders.Has(key)
                WorkspaceWindowOrders[key] := []
            WorkspaceWindowOrders[key].Push(hwnd)
            restoredOrderEntries += 1
            continue
        }
        if fields.Length < 5 || fields[1] != "W"
            continue

        try {
            hwnd := Integer(fields[2])
            expectedPid := Integer(fields[3])
            deviceName := StrLower(fields[4])
            workspace := Integer(fields[5])
            ; Older state files have no flag; keep their show-everything rule.
            shown := fields.Length >= 6 ? Integer(fields[6]) : 1
        } catch {
            rejectedWindows += 1
            continue
        }
        if !monitorLookup.Has(deviceName) || workspace < 1 || workspace > WORKSPACE_COUNT
            || !WinExist("ahk_id " hwnd) {
            rejectedWindows += 1
            continue
        }
        try actualPid := WinGetPID("ahk_id " hwnd)
        catch {
            rejectedWindows += 1
            continue
        }
        if actualPid != expectedPid {
            rejectedWindows += 1
            continue
        }
        monitor := monitorLookup[deviceName]
        WindowWorkspace[hwnd] := {monitor: monitor, workspace: workspace}
        if !shown
            RestoredSelfHiddenWindows[hwnd] := true
        restoredWindows += 1
        DebugLog("STATE_WINDOW_RESTORE", "monitor=" monitor " workspace=D" workspace
            " shown=" shown " " DebugDescribeWindow(hwnd))
    }

    ; Windows that were waiting for a disconnected monitor.
    for hwnd, home in homes {
        home.monitor := savedGeometry.Has(home.device) ? savedGeometry[home.device] : false
        if monitorLookup.Has(home.device) {
            ; Their monitor came back while the engine was stopped.
            monitor := monitorLookup[home.device]
            if !WindowWorkspace.Has(hwnd)
                restoredWindows += 1
            WindowWorkspace[hwnd] := {monitor: monitor, workspace: home.workspace}
            if home.placement
                RestoreWindowPlacement(hwnd, home.placement, home.monitor,
                    MonitorTopology, monitor)
            if !home.shown && !IsVisible(hwnd)
                RestoredSelfHiddenWindows[hwnd] := true
            DebugLog("STATE_WINDOW_RETURN", "monitor=" monitor " workspace=D" home.workspace
                " " DebugDescribeWindow(hwnd))
            continue
        }
        DisplacedWindows[hwnd] := home
        ; The engine that saved it revealed it as it stopped. It waits hidden
        ; again, unless it was a guest on another monitor's workspace.
        if home.shown && !WindowWorkspace.Has(hwnd) {
            if IsVisible(hwnd)
                HideWindowFast(hwnd)
            HiddenByScript[hwnd] := true
        }
        DebugLog("STATE_WINDOW_WAIT", "home=" home.device " workspace=D" home.workspace
            " " DebugDescribeWindow(hwnd))
    }

    ; Release popups and overlays saved by older versions. Checked once every
    ; window is loaded, since a palette counts only while its owner is tracked.
    ; They are left as they are: showing one could bring back a finished popup.
    for hwnd in WindowWorkspace.Clone() {
        if IsWorkspaceWindowKind(hwnd)
            continue
        ReleaseWorkspaceWindow(hwnd)
        if RestoredSelfHiddenWindows.Has(hwnd)
            RestoredSelfHiddenWindows.Delete(hwnd)
        restoredWindows -= 1
        rejectedWindows += 1
    }

    DebugLog("STATE_LOAD", "result=ok monitors=" restoredMonitors
        " windows=" restoredWindows " rejected=" rejectedWindows
        " orderEntries=" restoredOrderEntries " waiting=" DisplacedWindows.Count
        " path=" WORKSPACE_STATE_PATH)
    return restoredMonitors || restoredWindows
}

ApplyRestoredWorkspaceVisibility() {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript, RestoredSelfHiddenWindows
    applied := 0
    for hwnd, slot in WindowWorkspace.Clone() {
        if !WinExist("ahk_id " hwnd) {
            ForgetWindow(hwnd)
            continue
        }
        if !CurrentWorkspace.Has(slot.monitor)
            continue
        ; Still hidden by its own app: showing it would pop it up now, and
        ; marking it script-hidden would pop it up on the next visit.
        if RestoredSelfHiddenWindows.Has(hwnd) && !IsVisible(hwnd) {
            DebugLog("STATE_APPLY_SELF_HIDDEN", "assigned=D" slot.workspace
                " " DebugDescribeWindow(hwnd))
            continue
        }
        expectedVisible := slot.workspace = CurrentWorkspace[slot.monitor]
        if expectedVisible {
            if !IsVisible(hwnd) {
                DebugLog("STATE_APPLY_SHOW", "current=D" CurrentWorkspace[slot.monitor]
                    " " DebugDescribeWindow(hwnd))
                ShowWindowFast(hwnd)
            }
            if HiddenByScript.Has(hwnd)
                HiddenByScript.Delete(hwnd)
        } else {
            if IsVisible(hwnd) {
                DebugLog("STATE_APPLY_HIDE", "current=D" CurrentWorkspace[slot.monitor]
                    " assigned=D" slot.workspace " " DebugDescribeWindow(hwnd))
                CaptureWindowSnapshot(hwnd)
                HideWindowFast(hwnd)
            }
            HiddenByScript[hwnd] := true
        }
        applied += 1
    }
    RestoredSelfHiddenWindows.Clear()
    DebugLog("STATE_APPLY", "windows=" applied)
    Loop MonitorGetCount()
        SetTimer(VerifyWorkspaceTransition.Bind(A_Index, CurrentWorkspace[A_Index], 0), -300)
}

InitializeDebugLogging() {
    global DEBUG_LOG_PATH, DEBUG_SESSION_ID
    try {
        SplitPath(DEBUG_LOG_PATH,, &logDirectory)
        DirCreate(logDirectory)
        RotateDebugLogIfNeeded()
        WriteDebugLogText("`n===== SESSION " DEBUG_SESSION_ID " =====`n")
    }
}

RotateDebugLogIfNeeded() {
    global DEBUG_LOG_PATH, DEBUG_PREVIOUS_LOG_PATH, DEBUG_MAX_BYTES, DebugLogFile
    if !FileExist(DEBUG_LOG_PATH) || FileGetSize(DEBUG_LOG_PATH) < DEBUG_MAX_BYTES
        return false
    ; An open handle would keep writing into the renamed file.
    if DebugLogFile {
        DebugLogFile.Close()
        DebugLogFile := false
    }
    if FileExist(DEBUG_PREVIOUS_LOG_PATH)
        FileDelete(DEBUG_PREVIOUS_LOG_PATH)
    FileMove(DEBUG_LOG_PATH, DEBUG_PREVIOUS_LOG_PATH, true)
    return true
}

DebugLog(event, details := "") {
    global DEBUG_LOG_PATH, DEBUG_SESSION_ID
    ; The engine runs for days, so rotating only at startup let one session
    ; grow the log far past its limit.
    static linesSinceSizeCheck := 0
    try {
        timestamp := FormatTime(, "yyyy-MM-dd HH:mm:ss") "." Format("{:03}", A_MSec)
        line := timestamp " [" DEBUG_SESSION_ID "] [" event "]"
        if details != ""
            line .= " " DebugClean(details)
        WriteDebugLogText(line "`n")
        linesSinceSizeCheck += 1
        if linesSinceSizeCheck >= 500 {
            linesSinceSizeCheck := 0
            if RotateDebugLogIfNeeded()
                WriteDebugLogText("===== SESSION " DEBUG_SESSION_ID " (continued) =====`n")
        }
    }
}

WriteDebugLogText(text) {
    global DEBUG_LOG_PATH, DebugLogFile
    ; Opening and closing the log for every line took about 8 ms each, which
    ; added up to most of a workspace switch. Keep it open and flush each
    ; line so a hang or crash still leaves it on disk.
    if !DebugLogFile
        DebugLogFile := FileOpen(DEBUG_LOG_PATH, "a", "UTF-8")
    DebugLogFile.Seek(0, 2) ; another engine instance may have appended
    DebugLogFile.Write(text)
    DebugLogFile.Read(0) ; flush the write buffer
}

DebugClean(value) {
    text := value ""
    text := StrReplace(text, "`r", "\\r")
    text := StrReplace(text, "`n", "\\n")
    text := StrReplace(text, "`t", " ")
    return text
}

FormatDebugArguments() {
    result := "["
    for index, argument in A_Args {
        if index > 1
            result .= ", "
        result .= '"' DebugClean(argument) '"'
    }
    return result "]"
}

DebugDescribeWindow(hwnd) {
    if !hwnd
        return "hwnd=0"
    exists := WinExist("ahk_id " hwnd) != 0
    if !exists
        return "hwnd=" hwnd " exists=false"
    try title := DebugClean(WinGetTitle("ahk_id " hwnd))
    catch
        title := "<error>"
    try processName := WinGetProcessName("ahk_id " hwnd)
    catch
        processName := "<error>"
    try className := WinGetClass("ahk_id " hwnd)
    catch
        className := "<error>"
    try minimized := WinGetMinMax("ahk_id " hwnd)
    catch
        minimized := "<error>"
    try monitor := GetWindowMonitor(hwnd)
    catch
        monitor := "<error>"
    quote := Chr(34)
    return "hwnd=" hwnd " title=" quote title quote " process=" processName
        . " class=" className " monitor=" monitor " visible=" IsVisible(hwnd)
        . " minmax=" minimized
}

DebugWorkspaceSummary(monitor) {
    global WindowWorkspace, HiddenByScript, WORKSPACE_COUNT
    counts := []
    Loop WORKSPACE_COUNT
        counts.Push(0)
    tracked := 0
    hidden := 0
    for hwnd, slot in WindowWorkspace {
        if slot.monitor != monitor
            continue
        tracked += 1
        if slot.workspace >= 1 && slot.workspace <= WORKSPACE_COUNT
            counts[slot.workspace] += 1
        if HiddenByScript.Has(hwnd)
            hidden += 1
    }
    result := "tracked=" tracked " hidden=" hidden
    Loop WORKSPACE_COUNT
        result .= " D" A_Index "=" counts[A_Index]
    return result
}

VerifyWorkspaceTransition(monitor, workspace, attempt := 0) {
    global CurrentWorkspace, WindowWorkspace, HiddenByScript, Switching
    global DisplayTopologyPending
    ; Scheduled before a display change, its monitor number may be stale.
    if DisplayTopologyPending
        return
    mismatchCount := 0
    mismatchDetails := ""
    released := 0
    for hwnd, slot in WindowWorkspace {
        if slot.monitor != monitor || !WinExist("ahk_id " hwnd)
            continue
        expectedVisible := slot.workspace = workspace
        actualVisible := IsVisible(hwnd)
        scriptHidden := HiddenByScript.Has(hwnd)
        ; A responsive app still keeping its window hidden a second after the
        ; show request hid it itself. Stop re-showing it on every visit, where
        ; each handoff would otherwise wait for it until timing out.
        if attempt >= 3 && expectedVisible && !actualVisible && scriptHidden
            && !Switching && CurrentWorkspace.Has(monitor)
            && CurrentWorkspace[monitor] = workspace && IsWindowResponsive(hwnd) {
            HiddenByScript.Delete(hwnd)
            released += 1
            DebugLog("WINDOW_SELF_HIDDEN_RELEASE", "workspace=D" workspace
                " " DebugDescribeWindow(hwnd))
            continue
        }
        if expectedVisible != actualVisible {
            mismatchCount += 1
            if mismatchCount <= 12
                mismatchDetails .= " | expected=" (expectedVisible ? "visible" : "hidden")
                    . " assigned=D" slot.workspace " scriptHidden=" scriptHidden
                    . " " DebugDescribeWindow(hwnd)
        }
    }
    actualWorkspace := CurrentWorkspace.Has(monitor) ? "D" CurrentWorkspace[monitor] : "missing"
    DebugLog("SWITCH_VERIFY", "attempt=" attempt " monitor=" monitor
        " expected=D" workspace " actual=" actualWorkspace
        " mismatches=" mismatchCount " active=" DebugDescribeWindow(WinExist("A"))
        mismatchDetails)
    if released
        ScheduleWorkspaceStateSave()
    if mismatchCount && attempt < 3
        SetTimer(VerifyWorkspaceTransition.Bind(monitor, workspace, attempt + 1), -250)
}

ShowHelp(*) {
    global WORKSPACE_COUNT
    MsgBox(
        "Independent Monitor Workspaces`n`n"
        . "Point the mouse at the monitor you want to control, then use:`n`n"
        . "Win+Ctrl+Left / Right   Previous or next workspace`n"
        . "Win+Ctrl+Space          Show all workspace windows`n"
        . "Win+Ctrl+1.." WORKSPACE_COUNT "       Open a numbered workspace`n"
        . "Win+Ctrl+Shift+1.." WORKSPACE_COUNT " Move the active window`n"
        . "Win+Ctrl+Shift+R        Restart and recover the workspace engine`n"
        . "Ctrl+Alt+Shift+R        Launch recovery even if the engine stopped`n"
        . "Win+Ctrl+Shift+Esc      Reveal everything and reset`n`n"
        . "Hold a window by its title bar and switch workspaces to carry it with you.`n"
        . "Move the pointer to a monitor's top-left corner and hold to open the overview.`n`n"
        . "Keep Windows itself on one native virtual desktop while using this script.",
        "Independent Monitor Workspaces",
        "Iconi"
    )
}
