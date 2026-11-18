# Independent Monitor Workspaces

[![Installer tests](https://github.com/Allaa-boutaleb/windows-per-monitor-workspaces/actions/workflows/installer-tests.yml/badge.svg)](https://github.com/Allaa-boutaleb/windows-per-monitor-workspaces/actions/workflows/installer-tests.yml)

<p align="center">
  <a href="assets/demo.mp4">
    <img src="assets/demo.gif" alt="Independent per-monitor workspace switching demo" width="100%">
  </a>
</p>

Independent, fast workspace switching for each monitor on Windows 11.

Windows virtual desktops switch every display together. This lightweight AutoHotkey v2 utility gives each monitor its own workspace state: point at a screen, switch, and only the windows on that screen change. Other monitors stay exactly where they are.

- Instant asynchronous switching with no staggered window-by-window delay
- Smooth slide-and-fade workspace indicator
- Native cursor-to-monitor detection across mixed DPI and scaling
- Automatic support for one, two, three, four, or more connected monitors
- Mission Control-style workspace overview with window previews
- Remembers every window when a display disconnects, such as a monitor switched to a game console, and puts each one back on the same monitor, in the same spot and workspace, when it returns
- No background service, driver, scheduled task, registry edit, telemetry, or administrator requirement

## Install in one command

Open PowerShell and run:

~~~powershell
irm https://raw.githubusercontent.com/Allaa-boutaleb/windows-per-monitor-workspaces/main/install.ps1 | iex
~~~

That is the entire setup. The installer downloads the readable workspace script and an isolated portable AutoHotkey v2 runtime into `%LOCALAPPDATA%\IndependentMonitorWorkspaces`, creates a normal per-user Startup shortcut plus a Start Menu recovery shortcut, and launches it. The installer resolves the actual on-disk paths when run from a packaged app, so Windows Explorer can still launch recovery through redirected local storage.

You do not need AutoHotkey, `winget`, administrator access, or anything preinstalled. The installer does not modify `PATH` or install AutoHotkey system-wide.

Prefer to inspect commands first? Read [install.ps1](install.ps1), then run it locally.

### Installer safeguards

- Downloads the pinned official [AutoHotkey v2.0.26 release](https://github.com/AutoHotkey/AutoHotkey/releases/tag/v2.0.26)
- Verifies the runtime ZIP against its pinned SHA-256 before extracting it
- Validates the workspace script with AutoHotkey before replacing a working install
- Builds updates in a staging directory and restores the previous files and Startup entry if any later step fails
- Retries temporary download failures
- Uses a native Windows Shell shortcut fallback if WScript shortcut creation is unavailable
- Leaves user-managed AutoHotkey installations untouched

## Controls

Point the mouse at the monitor you want to control, then use:

| Shortcut | Action |
|---|---|
| `Win+Ctrl+Left` / `Win+Ctrl+Right` | Previous / next workspace on that monitor |
| `Ctrl+Alt+Left` / `Ctrl+Alt+Right` | Logitech-friendly previous / next workspace shortcuts |
| `Win+Ctrl+Space` | Show or close the workspace overview on that monitor |
| `Win+Ctrl+1` ... `Win+Ctrl+3` | Open a numbered workspace on that monitor |
| `Win+Ctrl+Shift+1` ... `Win+Ctrl+Shift+3` | Move the active window to a workspace |
| `Win+Ctrl+Shift+R` | Restart the workspace engine without clearing assignments |
| `Ctrl+Alt+Shift+R` | Launch recovery when the workspace engine is no longer running |
| `Win+Ctrl+Shift+Esc` | Reveal every window and reset all workspace state |

Three workspaces are enabled by default. Change `WORKSPACE_COUNT := 3` near the top of the script to any value from 1 to 9.

Previous/next navigation has hard boundaries: moving right stops at the highest D-number, and moving left stops at D1. It never wraps directly from D3 to D1 or from D1 to D3.

To carry a window to another workspace, hold its title bar and start dragging, then press `Win+Ctrl+Left` / `Win+Ctrl+Right`, `Ctrl+Alt+Left` / `Ctrl+Alt+Right`, or a numbered workspace shortcut while keeping the mouse button held. The window stays with you as you switch; release it to leave it there. The monitor under the pointer controls which workspace switches. If you finish on another monitor, the window joins that monitor's active workspace using the usual window-position rule. While you hold the window, the desktops slide left or right behind it with the normal switching animation. The held window stays live above the slide, and the hot corner stays inactive until you release the mouse. This supports standard Windows window move/resize drags; file drags, text selection, and custom app drag systems are not treated as window moves.

Workspace changes use a 340 ms directional slide with no crossfade between the two desktops. Moving to a higher D-number slides the current workspace left and brings the next one in from the right; moving to a lower D-number reverses that motion. Two opaque, monitor-sized workspace frames are composed at the monitor's physical resolution in a persistent off-screen buffer and presented as one Desktop Window Manager-synchronized surface. The surface is created in per-monitor-v2 DPI mode and sized while hidden with physical-pixel coordinates, so no scaled or zoomed frame appears before the slide. Its edges remain pixel-locked, preventing wallpaper gaps, erase flicker, or DPI rescaling while real application positions and maximized state remain unchanged.

Workspaces hold app windows: the ones Windows shows on the taskbar and in Alt+Tab, their dialogs, and the palettes and frame shadows they own. On-screen displays such as a Caps Lock indicator, tray flyouts, notifications, tooltips, menus, and meeting or screen-sharing overlays such as Zoom's share toolbar and border are left to the apps that show them. They stay where their app puts them, and focusing one never switches a monitor's workspace.

The completed animation frame stays in place until every incoming app is visible. A workspace with no recent capture, such as one whose window just closed or the first visit after the engine restarts, is revealed under the outgoing frame and captured from the screen before it slides in, so it arrives exactly as it will look. A workspace shown from a remembered frame instead fades from that frame to its live windows over 120 ms, so anything an app drew while hidden appears smoothly. While you carry a window, both desktops are captured the same way, with the area around the held window repainted from snapshots so no second copy of it slides. Each workspace also remembers its full top-to-bottom window stack, so returning to a workspace restores all of its apps with the same overlapping or maximized app on top instead of whichever app responds first.

You can press the switching shortcuts repeatedly without waiting for an animation to finish. Additional input completes the active visual frame immediately, coalesces to the latest requested D-number, and uses a shorter 190 ms slide for the queued destination.

A watchdog monitors every transition. If progress pauses, it first completes the current visual frame and retries the requested workspace. If the engine remains stuck for 4.5 seconds, it automatically reveals managed windows, restarts from the last known-good state, and replays the requested D-number. `Win+Ctrl+Shift+R` and the tray menu provide the same safe restart while the engine is responsive. An app that stops responding cannot stall a switch: the engine checks each app before waiting on it, captures a hung app's window from the screen instead, and posts window requests to it rather than waiting for a reply. The installer also assigns `Ctrl+Alt+Shift+R` to the Windows Startup shortcut; Explorer owns that hotkey, so it can launch recovery even after the AutoHotkey process has stopped completely.

Clicking an app on the Windows taskbar also follows its workspace assignment. The utility intercepts clicks only within the taskbar's app-button area, freezes the current workspace before forwarding the click to Explorer, and hands that exact frame into the standard directional slide when the app belongs to another D-number. This prevents the app from flashing on the current workspace while preserving the same smooth D3-to-D1 motion used by the hotkeys. The correct D indicator appears, and the next previous/next shortcut continues from that workspace instead of jumping back to it. Non-taskbar activation retains an instant no-reopen fallback because Windows may reveal those windows before notifying other software.

When an app closes and reopens within ten minutes on the same monitor, the utility remembers its workspace. For example, an app updating on D3 returns to D3 while you continue working on D2. Matching uses the executable's installation path and window class, allowing common `app-<version>` and WindowsApps version-folder changes. It checks for replacement windows every 250 ms and suppresses their startup focus requests for two seconds; an explicit taskbar click still follows the app to its workspace. A brief appearance before detection is possible.

Restart memory lasts for the current workspace-engine session and also applies to a manual close and reopen. It covers an app's top-level windows; its dialogs and popups always open on the workspace you are using. Each closed window allows one replacement. Apps whose matching windows belong to different workspaces, reopen on another monitor, or change their executable path or window class beyond the supported version-folder patterns use normal placement. Resetting workspaces clears restart memory.

## Disconnecting and reconnecting monitors

Switching a monitor's input to a game console, unplugging it, or letting it drop off the cable while it sleeps disconnects it from Windows, often for only a second. The utility remembers that monitor's workspaces and puts everything back when it returns.

- Windows moves the apps on the monitor's visible workspace onto your other monitors. Each one joins the workspace shown where it landed, so it hides and reappears with that workspace while the monitor is away.
- Apps on the monitor's other workspaces stay hidden and wait for it.
- When the monitor returns, every app goes back to the same monitor, position, size, and maximized or minimized state, in the same D-number, and the monitor shows the workspace it was showing before. Apps on the other monitors keep their workspaces throughout.

A monitor that blinks off and back on, as many do while switching inputs, gets the same treatment, and windows Windows moved during the blink are put back. If a monitor returns at a different position or resolution, its apps keep their place relative to it and are fitted onto it. This memory survives workspace-engine restarts while the monitor is away. An app that shows a waiting window by itself keeps it on screen, in the workspace shown where it appears, until its monitor returns. `Win+Ctrl+Shift+Esc` reveals every waiting window on your main monitor and forgets the disconnected monitor.

## Workspace overview

Press `Win+Ctrl+Space`, or hold the pointer in a monitor's top-left corner for half a second, to see every workspace on that monitor. The active workspace uses live window thumbnails. Inactive workspaces use snapshots captured immediately before their windows were hidden. A window hidden since before the engine started shows a placeholder until its workspace is next shown.

The mouse corner is disabled while a fullscreen or borderless fullscreen app is focused, including games. `Win+Ctrl+Space` remains available, and the corner works again after leaving fullscreen or switching to a normal window.

- Click a `D1`, `D2`, or `D3` panel to switch to that workspace.
- Click a window preview to switch to its workspace, show the `D1`, `D2`, or `D3` indicator, and focus that window.
- Press `Esc`, click outside the panels, or press `Win+Ctrl+Space` again to close the overview.

Preview capture is best effort. Protected, elevated, or specialized application windows may show an older image or only their title.

## Debug log

The app records workspace switching diagnostics in `%LOCALAPPDATA%\IndependentMonitorWorkspaces\debug.log`. Right-click its tray icon and select **Open debug log** to inspect or share it. The log includes window titles and process names so workspace assignments and focus failures can be identified. It rotates to `debug.previous.log` at 4 MB.

Workspace assignments, each monitor's active D-number, each workspace's window stack, which windows their own apps had hidden, and the windows and active D-number of disconnected monitors are saved in `%LOCALAPPDATA%\IndependentMonitorWorkspacesState\workspace-state.tsv`. This state survives workspace-engine updates and restarts; stale windows are rejected by matching both their window handle and process ID. The short-term memory for other apps' replacement windows is kept separately in memory.

## Uninstall in one command

~~~powershell
irm https://raw.githubusercontent.com/Allaa-boutaleb/windows-per-monitor-workspaces/main/uninstall.ps1 | iex
~~~

Uninstalling reveals windows managed by the utility, removes its Startup entry, script, metadata, and isolated portable runtime. If you explicitly installed with your own AutoHotkey executable, that executable is never removed.

## Manual or offline installation

To use an existing AutoHotkey v2 executable:

~~~powershell
.\install.ps1 -SourceScriptPath .\IndependentMonitorWorkspaces.ahk -AutoHotkeyPath "C:\path\to\AutoHotkey64.exe"
~~~

For a fully offline install, download the official AutoHotkey v2.0.26 ZIP and this repository first:

~~~powershell
.\install.ps1 -SourceScriptPath .\IndependentMonitorWorkspaces.ahk -RuntimeArchivePath .\AutoHotkey_2.0.26.zip
~~~

The same checksum and syntax validation are applied to offline files.

## How it works

Windows exposes one active native virtual desktop across the full display topology. This utility stays on one native Windows desktop and maintains lightweight window groups for each physical monitor. Switching a monitor sends asynchronous show/hide requests only to windows assigned to that monitor.

Monitor targeting uses the native Windows `HMONITOR` device under the physical cursor instead of comparing logical screen coordinates. The entire engine runs per-monitor-v2 DPI-aware, keeping monitor bounds, captures, buffers, and animation windows in one physical-pixel coordinate space. This avoids wrong-monitor selection and rendering rescale artifacts on displays with different scaling factors.

Display count is dynamic. One monitor works like a normal workspace switcher; additional monitors receive independent state automatically. Workspaces belong to each monitor's `\\.\DISPLAYn` device rather than its position in Windows' monitor list, which reorders as displays come and go. The engine checks the monitor list with every 250 ms window scan and listens for Windows' display-change notification. While displays change, it learns nothing from windows Windows is moving between monitors and holds workspace switches. It waits 1.5 seconds for the change to settle, then carries every workspace to its monitor's new number. Window positions recorded during the last scan before the change are used to put back windows that Windows moved.

## Compatibility and requirements

- Windows 11
- Windows PowerShell 5.1 or PowerShell 7
- x64 Windows
- Windows 11 on Arm through Microsoft's built-in [x64 app emulation](https://learn.microsoft.com/windows/arm/apps-on-arm-x86-emulation)
- Multiple monitors are optional
- Internet access for the one-command installer; offline installation is supported

Standard locked-down enterprise policies can still block PowerShell scripts, GitHub downloads, WMI process inspection, or per-user Startup entries. The installer reports the failed step and preserves the prior installation, but it does not bypass organization security policy.

## Installer testing

The repository runs the installer suite on `windows-latest` with both Windows PowerShell 5.1 and PowerShell 7. It covers:

- Clean install with no `winget` and no AutoHotkey on `PATH`
- Paths containing spaces and non-ASCII characters
- WScript and native Windows Shell Startup shortcut paths
- Idempotent updates
- Invalid script, syntax, checksum, and malformed ZIP rejection
- Rollback after a post-swap failure
- Bundled and user-managed runtime removal behavior
- The live public GitHub download path

Run the same tests locally:

~~~powershell
.\tests\Test-Installer.ps1
~~~

## Limitations

- These are independent window workspaces, not separate native Windows virtual desktops.
- Keep Windows itself on one native virtual desktop while using the utility.
- Wallpaper and desktop icons do not change between workspaces.
- Elevated applications cannot be controlled by a non-elevated script. Running the utility as administrator is possible but generally unnecessary.
- A small number of specialized or protected application windows may ignore standard Windows show/hide messages.

If anything behaves unexpectedly, press `Win+Ctrl+Shift+Esc` to reveal everything and reset.

## License

[MIT](LICENSE)
