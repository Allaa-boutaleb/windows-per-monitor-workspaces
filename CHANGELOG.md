# Changelog

## 1.2.24 - 2026-11-17

- Open a window its app hid and shows again, like Telegram's media viewer or a tray app, on the workspace the user is on. Telegram reuses one hidden viewer for every photo, so opening a photo switched the monitor to whichever workspace the viewer was first seen on
- Add a reopen case to the self-hidden window test

## 1.2.23 - 2026-11-10

- Remember a monitor's windows when it disconnects, as when its input is switched to a game console, and put them back when it returns. Any display change used to reveal every hidden window on every monitor and reset all monitors to D1
- Keep apps from a disconnected monitor's visible workspace in the workspace shown where Windows moved them, and keep the ones on its other workspaces hidden until it returns
- Return each app to its monitor, position, size, maximized or minimized state, and workspace on reconnect, and the monitor to the D-number it showed. Hidden apps move back without being shown
- Put back windows Windows moved while a monitor blinked off and on, and keep workspaces with their monitor when Windows renumbers the monitors
- Fit returning windows to a monitor that comes back at a different position or resolution
- Hold the window scan, workspace switches, taskbar-activation follow, and state saves until a display change settles, so windows Windows moves between monitors keep their workspaces
- Keep disconnected monitors' windows and active D-numbers in saved state, so an engine restart while a monitor is away keeps them waiting
- Bring a waiting window onto the main monitor when its app shows it or when everything is revealed, instead of showing it where the disconnected monitor was
- Add a display-reconnect regression test, and record the monitor layout in the older tests' harnesses as the engine does at startup

## 1.2.22 - 2026-10-26

- Slide a workspace in exactly as it will look when no recent capture of it exists. A window closing, moving, or restarting there, or an engine restart, discards that capture, and the frame rebuilt from window snapshots used to show a near-black screen until the windows appeared
- Reveal such a workspace's windows under the outgoing frame and capture them from the screen before the slide, with wallpaper, desktop icons, shadows, rounded corners, and windows hidden since before the engine started. The cover is excluded from that capture, and the capture waits for slow apps to finish hiding outgoing windows
- While carrying a window, capture both desktops from the screen too, and repaint only the area around the held window and its shadow from snapshots, so neither desktop holds a second copy of it. Desktops used to be built entirely from snapshots during a drag
- Fade the cover out over 120 ms after a slide that used a remembered or patched frame, so content an app drew while hidden crossfades in instead of jumping. A frame captured moments before the slide skips the fade, as does a queued switch
- Keep windows revealed before a slide beneath its cover, including always-on-top ones. An always-on-top window on a drag's destination waits for the slide to finish, because a drag's cover cannot sit above it
- Keep clicks during a slide from reaching the windows under the cover; they pass through once the cover starts fading
- Draw the real wallpaper and desktop icons behind frames that are still built from snapshots. Each monitor's desktop is captured at startup, after wallpaper or work-area changes, and every five minutes while the user pauses
- Stop snapshotting hidden windows, which print as solid black, so a maximized app on another workspace no longer slides in as a black screen
- Draw only each window's visible frame in snapshot-built frames, so floating windows have no black resize border
- Show the overview's preview placeholder for a window hidden since before the engine started, instead of an empty preview
- Add desktop-background, uncached-switch, fade, cover-order, and overview-placeholder regression tests, and run the drag animation test through the reveal and capture

## 1.2.21 - 2026-10-25

- Stop adopting on-screen displays, tray flyouts, notifications, tooltips, menus, and meeting or screen-sharing overlays as workspace windows, so a Caps Lock indicator no longer gets stuck on screen after a workspace visit
- Keep focusing a Zoom share toolbar, annotation bar, or similar overlay, or opening the tray overflow, from switching the monitor to another workspace
- Leave Zoom's screen-sharing toolbar and share preview on screen across workspaces. The toolbar has a taskbar button but is owned by a sharing overlay or a hidden toolbar holder, so every owner up the chain is now checked
- Release an adopted window once its app turns it into an overlay, and never switch workspaces when one is focused; Zoom attaches its share toolbar to the sharing overlay only after showing it
- Log window captures and animation frames that stall, to pinpoint slowdowns during screen sharing
- Release such windows saved by earlier versions on startup without popping them back up
- Limit restart memory to apps' top-level windows, so a newly opened dialog or popup is no longer hidden as the "restart" of one closed on another workspace
- Keep the debug log open instead of reopening it for every line, which took about 8 ms each and made up most of a workspace switch's delay
- Check visibility first in the 250 ms window scan
- Add transient-window regression tests

## 1.2.20 - 2026-10-23

- Prevent an app that stops responding from freezing the whole workspace engine, including its watchdog and hotkeys
- Check each app's UI thread before window captures, focus restores, and stack reordering; capture hung windows from the screen and post requests to them instead of waiting
- Skip snapshots of windows that are not on screen
- Stop restarts from popping up windows their own apps had hidden, such as tray apps, popups, and tooltips, or treating them as hidden by the engine
- Release windows that an app keeps hidden after a visit, so switches no longer wait on them until timing out
- Rotate the debug log during long sessions instead of only at startup
- Add hung-app and self-hidden-window regression tests, and fix test wrappers under Windows PowerShell 5.1

## 1.2.19 - 2026-09-20

- Prevent overlapping desktop-indicator updates from leaving a stale D-number permanently visible
- Tie dismissal callbacks to their own indicator and remove expired or incorrect labels during health checks
- Clear indicators on reset and shutdown; add native-window regression coverage for overlapping updates and cleanup

## 1.2.18 - 2026-09-12

- Return apps that restart within ten minutes to their previous workspace on the same monitor, including common updater version-folder changes
- Detect replacement windows in the background and suppress initial restart focus requests without switching the user's active workspace
- Avoid guessing when an app spans workspaces, consume one remembered assignment per replacement, and clear restart memory on reset
- Add regression coverage for replacement handles/processes, update paths, multiple windows, ambiguity, expiry, and taskbar activation

## 1.2.17 - 2026-09-09

- Animate left/right workspace switching while carrying a held window
- Keep the live held window above the slide and omit it from both desktop frames so no duplicate slides away

## 1.2.16 - 2026-09-09

- Suppress the overview mouse corner while a fullscreen or borderless fullscreen app is focused, including when the pointer reaches another monitor
- Keep the overview keyboard shortcut available during fullscreen use

## 1.2.15 - 2026-09-08

- Keep a held window visible and carry it into the selected workspace when switching during a native window drag
- Switch instantly during dragging and restore incoming windows behind the held window without activating them
- Finalize assignments on drop, including moves across monitors, and suppress the overview hot corner while the mouse button is held

## 1.2.14 - 2026-09-02

- Added hard boundaries to previous/next workspace navigation so D3 cannot wrap to D1 and D1 cannot wrap to D3
- Applied the same boundary behavior to rapid queued switching requests

## 1.2.13 - 2026-09-02

- Added an Explorer-owned `Ctrl+Alt+Shift+R` recovery hotkey to the installed Startup shortcut
- Made manual recovery launch the workspace engine even when its AutoHotkey process has already crashed or stopped
- Resolved packaged-app filesystem redirection to physical runtime and script paths before writing Windows shortcuts
- Anchored installed logs and saved workspace state to the resolved script location so installer and Explorer launches share the same data
- Added recovery-hotkey validation to both WScript and native Unicode shortcut installer paths
- Corrected the startup D-number indicator to show the active workspace on the monitor under the pointer

## 1.2.12 - 2026-09-01

- Added a transition watchdog that accelerates and retries a switch when progress stalls
- Added automatic engine restart after a prolonged stuck transition, preserving the last known-good state and replaying the requested D-number after startup
- Caught switch-time runtime errors and routed them through the same restart-and-resume recovery path
- Added `Win+Ctrl+Shift+R` and a tray command for manual engine restart without clearing workspace assignments
- Added switch heartbeat, soft recovery, hard recovery, restart, and recovery-replay diagnostics

## 1.2.11 - 2026-09-01

- Moved the complete workspace engine into per-monitor-v2 DPI awareness instead of applying it only to animation windows
- Unified monitor bounds, screen capture, GDI back buffers, and presentation surfaces in physical-pixel coordinates
- Added startup DPI-context diagnostics to distinguish each monitor's actual 96, 120, or 168 DPI rendering path

## 1.2.10 - 2026-09-01

- Created slide and taskbar-shield windows under per-monitor-v2 DPI awareness
- Sized animation surfaces while hidden with native physical-pixel coordinates, eliminating the scaled frame that appeared as a zoom before switching
- Added client-area, window-bounds, and window-DPI diagnostics for every slide and taskbar shield

## 1.2.9 - 2026-09-01

- Intercepted mouse clicks only within Windows taskbar app-button controls before Explorer activates the selected app
- Captured and displayed the current workspace before forwarding the click, preventing the selected app from flashing on the wrong D-number
- Handed the frozen pre-click frame directly into the standard directional workspace animation
- Restored smooth taskbar-triggered D3-to-D1 slides while retaining instant adoption as a fallback for non-taskbar activation

## 1.2.8 - 2026-09-01

- Replaced taskbar-triggered slide replay with an instant logical workspace adoption
- Kept the taskbar-selected app continuously visible instead of hiding and reopening it
- Updated outgoing and incoming window groups behind the selected app, then restored its top position
- Removed all external-activation slide frames to eliminate the visible “open here, then switch there” sequence

## 1.2.7 - 2026-09-01

- Replaced timer-only taskbar detection with a native Windows foreground-event hook
- Re-hid externally activated workspace windows immediately, before DWM presents them on the wrong workspace
- Prevented the premature app frame from entering the outgoing workspace capture
- Retained a faster polling fallback and deduplicated event/poll activation handling

## 1.2.6 - 2026-09-01

- Detected taskbar and other external foreground activation of apps assigned to an inactive workspace
- Converted an external app reveal into a real workspace transition, including the D-number indicator and persisted current-workspace state
- Promoted and refocused the exact selected app after its workspace finishes switching
- Added a taskbar-activation regression preview covering a D3-to-D1 Codex selection

## 1.2.5 - 2026-09-01

- Kept the completed animation frame visible until every incoming application acknowledges its show request
- Preserved and restored each workspace's complete window Z-order so repeated switches do not change which overlapping or maximized app is on top
- Persisted workspace window stacks across app restarts and installer updates
- Added handoff acknowledgement, retry, and stack diagnostics plus an eight-switch regression loop

## 1.2.4 - 2026-09-01

- Isolated visual regression preview modes from persistent user workspace state
- Excluded Windows XAML host and Raycast launcher/shutdown helper surfaces from workspace assignment

## 1.2.3 - 2026-09-01

- Accepted workspace hotkeys during an active animation instead of rejecting them
- Coalesced repeated input to the latest requested workspace and calculated Left/Right from that requested state
- Accelerated an in-progress slide to its final frame when another request arrives on the same monitor
- Added a shorter 190 ms transition for queued rapid-switch destinations
- Added automated interrupted-animation testing and queue/acceleration diagnostics

## 1.2.2 - 2026-09-01

- Replaced moving full-resolution Picture controls with a single custom-rendered animation surface
- Added a persistent 1:1-pixel GDI back buffer and one-operation frame presentation to eliminate child-control erase and rescale flicker
- Synchronized animation presentation with Desktop Window Manager and suppressed background erase messages
- Added aggregate rendering diagnostics for physical resolution, DPI, capture/preparation time, frame count, average/max frame interval, render time, and slow frames

## 1.2.1 - 2026-09-01

- Replaced transparent per-window animation controls with two opaque, monitor-sized workspace frames
- Locked the outgoing and incoming frame edges to the same pixel throughout the slide, eliminating background gaps caused by independent rounding
- Reduced repaint work to two full-frame controls and disabled background erase during animation redraws
- Cached complete workspace frames and invalidated them when window assignments change

## 1.2.0 - 2026-09-01

- Added a 340 ms directional workspace slide using captured window surfaces, with cubic ease-in-out motion
- Higher-numbered workspaces enter from the right while the current workspace exits left; lower-numbered workspaces use the reverse direction
- Kept real application windows stationary during animation so maximized windows and saved positions are not disturbed
- Removed opacity animation from the D-number indicator
- Added an automatic bidirectional slide preview for runtime regression testing

## 1.1.5 - 2026-09-01

- Persisted per-monitor active workspaces and window assignments across app restarts and installer updates
- Reapplied saved visibility immediately on startup so D1, D2, and D3 no longer collapse back into D1 after an update
- Excluded Windows input and Widgets helper windows from workspace management

## 1.1.4 - 2026-09-01

- Fixed a re-entrant D-number overlay cleanup race that could raise `Item has no value` while rapidly switching workspaces
- Excluded Raycast's UI-access helper window because it is not an app window and rejects normal workspace hide requests

## 1.1.3 - 2026-09-01

- Added persistent diagnostic logging for monitor state, window assignments, overview hit-testing, workspace transitions, show/hide calls, activation retries, and post-switch verification
- Added bounded log rotation at 4 MB and an `Open debug log` tray command
- Added delayed transition verification that records windows whose actual visibility does not match the selected workspace

## 1.1.2 - 2026-09-01

- Made app-preview selection wait for and verify the complete workspace switch before revealing the selected window
- Prevented a selected app from being shown if another workspace becomes active during the activation delay
- Refreshed the `D1`, `D2`, or `D3` indicator after focusing an app selected from the overview

## 1.1.1 - 2026-09-01

- Fixed overview window clicks to switch using the overview's original monitor instead of re-detecting the pointer target
- Restored and showed the exact selected window synchronously after switching workspaces
- Added foreground activation retries for slower and minimized applications

## 1.1.0 - 2026-09-01

- Added a fullscreen, per-monitor workspace overview with clickable `D1`, `D2`, and `D3` panels
- Added live thumbnails for visible windows and memory-bounded cached snapshots for hidden windows
- Added click-to-switch, click-to-focus, `Esc` dismissal, and `Win+Ctrl+Space` toggling
- Added a half-second top-left hot corner on every monitor
- Added multi-monitor preview coverage for mixed 100%, 125%, and high-DPI display scales

## 1.0.3 - 2026-09-01

- Replaced the multi-row workspace indicator with a minimal `D1`, `D2`, or `D3` label
- Removed monitor text, arrows, status wording, and workspace dots from the indicator
- Enabled three workspaces by default
- Added a safe preview mode and verified the indicator across all three connected display scales

## 1.0.2 - 2026-09-01

- Reduced the workspace indicator footprint and animation distance
- Vertically centered indicator text to prevent workspace dots from being clipped
- Scaled long status labels down automatically to fit the compact card

## 1.0.1 - 2026-07-11

- Replaced the winget dependency with a pinned, isolated portable AutoHotkey v2 runtime
- Added SHA-256 verification and AutoHotkey syntax validation before installation
- Added transactional updates with file and Startup-entry rollback
- Added native Windows Shell Startup shortcut fallback
- Added Unicode-path support for Windows PowerShell 5.1
- Added installer coverage for Windows PowerShell 5.1 and PowerShell 7

## 1.0.0 - 2026-07-11

- Independent workspace state for every connected monitor
- Native mixed-DPI cursor-to-monitor detection
- Instant asynchronous window switching
- Animated slide-and-fade workspace indicator
- Numbered workspace selection and window-moving shortcuts
- Automatic display-topology reset for docking and monitor changes
- One-command PowerShell installation and uninstallation
- Startup integration without services, drivers, scheduled tasks, or registry edits
