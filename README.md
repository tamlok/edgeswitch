# EdgeSwitch

<img src="Assets/EdgeSwitch.png" alt="EdgeSwitch icon" width="80" height="80">

[![CI](https://github.com/tamlok/edgeswitch/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/tamlok/edgeswitch/actions/workflows/ci.yml)

A Windows screen-edge toolbar for switching **local application windows**, particularly separate fullscreen Remote Desktop sessions. Built with C#/.NET 10, WPF, and Win32; no third-party packages.

![Illustrative EdgeSwitch toolbar with app icons and four Remote Desktop session labels](Assets/ToolbarPreview.png)

*Illustrative preview using sample windows and fictional session names.*

The application artwork is embedded from `Assets/EdgeSwitch.ico` for the executable, both windows, and the notification-area icon. The icon preserves transparency and includes sizes from 16 to 256 pixels; no separate icon file is needed beside the published executable.

## Run

Download `EdgeSwitch.exe` from the **[latest release](https://github.com/tamlok/edgeswitch/releases/latest)**. Releases also include `SHA256SUMS.txt` for verification. The release executable is framework-dependent: the .NET runtime is not bundled.

The prebuilt release requires Windows 10/11 x64 and the **.NET 10 Desktop Runtime (x64)**. To build from source, install the .NET 10 SDK, then run these commands from this directory:

```powershell
dotnet build EdgeSwitch.csproj -c Release
.\bin\Release\net10.0-windows\EdgeSwitch.exe
```

The toolbar starts on the **left edge**, with `mstsc.exe` selected. Left-click the **EdgeSwitch icon** at the start of the toolbar to show the **host desktop**; right-click the same icon to open Settings. “Host” means the machine running EdgeSwitch. The desktop action hides the toolbar and uses [Windows Shell MinimizeAll](https://learn.microsoft.com/en-us/windows/win32/shell/shell-minimizeall) to minimize local windows, not close them or disconnect Remote Desktop sessions. It is not a toggle: use the window entries to restore a session. Its notification-area icon also provides **Show toolbar**, **Settings**, and **Exit EdgeSwitch**. Windows may put the icon under **Show Hidden Icons**. Only one instance runs per Windows login session. Alt+F4 hides the toolbar; use the tray menu to quit.

### Switch Remote Desktop sessions

1. Run EdgeSwitch on the **local machine** that starts your Remote Desktop connections, not inside the remote desktop.
2. Open two or more Remote Desktop Connection (`mstsc.exe`) windows and connect to your hosts. They may be fullscreen.
3. Rest the pointer against the part of the left screen edge where the toolbar appears for about 150–250 ms. Move onto the revealed toolbar.
4. Click the session icon/name to switch to that window. Minimized windows are restored. The toolbar hides after a successful switch.

The compact toolbar shows the **EdgeSwitch icon**, a separator, then application entries. Each qualifying **window** gets its own entry, even when several belong to one process. Ordinary windows show **only their icon**; Remote Desktop (`mstsc.exe` and `msrdc.exe`) entries follow them and show an **icon beside the session name**, without a dash separator. Session names come from the window title with the conventional English “ - Remote Desktop Connection” or “ - Remote Desktop” suffix removed; other/localized titles are preserved. Long names are truncated visually, not in the tooltip. Hover an entry for its full title, executable, and process ID. Windows without an available window/class icon use the standard Windows application icon.

The toolbar sizes to its contents and scrolls along its selected edge when needed. With no matching windows, only the EdgeSwitch icon remains. Only the edge segment occupied by the toolbar triggers reveal, including its EdgeSwitch icon; hovering elsewhere on that edge does nothing. The window list refreshes once per second while visible or while the pointer is at an eligible screen edge, so the hidden trigger span tracks captured windows opening or closing on that cadence. Hovering reveals the toolbar **without taking keyboard focus** from the current application; clicking performs the activation.

The toolbar stays open while the pointer is over it or resting on its trigger segment, it has keyboard focus, or Settings is open. Otherwise it hides after the configured delay (700 ms by default). **Esc** or **Alt+F4** hides it immediately. After explicit hiding, move outside that segment before hovering over it again. Launching or selecting Show toolbar gives you four seconds to reach it. Transient native enumeration or positioning errors are reported without stopping the toolbar's timer; the last known window list is retained until a refresh succeeds.

## Settings

- **Captured executables:** check applications whose windows should appear. “Capture” means inclusion in the switcher, **not screen recording**, remote input injection, or launching apps. The list combines saved choices with processes that currently have capturable windows.
- **Add / Browse:** add an executable even when it is not running. Names and paths are accepted; matching uses the executable basename, case-insensitively, without `.exe`. Dotted names such as `my.client.exe` remain `my.client`. No wildcard matching. Programs with the same executable basename are captured together, regardless of installation directory.
- **Toolbar edge:** Centered **Left**, **Top**, **Right**, or **Bottom**, plus **Left-top**, **Left-bottom**, **Top-left**, **Top-right**, **Right-top**, **Right-bottom**, **Bottom-left**, and **Bottom-right**. The first word chooses the trigger edge and orientation; the second aligns the toolbar along that edge. For example, **Top-left** is horizontal at the top-left corner, while **Left-top** is vertical at the same corner. Hover only over the segment of the chosen edge where the toolbar appears to reveal it (subject to the Display setting below). Left avoids the Remote Desktop connection bar at the top. Use an edge different from any auto-hide taskbar or competing dock.
- **Display:** Automatic responds to exposed screen-edge segments within the toolbar's span, not seams between adjacent monitors. Selecting a particular display also permits its shared edges. A disconnected saved display falls back to the primary display with a warning.
- **Hide delay:** 200–5,000 milliseconds.
- **Save / Cancel:** Save persists and applies the changes; Cancel leaves the current configuration intact. An empty capture list is valid.

Settings are stored per user in `%LOCALAPPDATA%\EdgeSwitch\settings.json`. Saves replace the file through a same-directory temporary file. Unreadable or malformed settings produce a warning and use defaults without overwriting the original; a later explicit Save replaces it. Nothing is persisted until you save. Existing edge names and numeric values 0–3 retain their centered placement. Corner placements are saved as enum names such as `TopLeft` and `LeftTop`.

Classic `mstsc.exe` is the only default capture. Other clients, including `msrdc.exe` or Windows App hosts, can be added by their actual executable names. A client that keeps sessions as tabs inside a **single native window** contributes one entry: EdgeSwitch does not control its internal tabs.

## Fullscreen and Windows restrictions

EdgeSwitch checks the global pointer position rather than depending on mouse events delivered through a fullscreen client. When revealed, its activatable tool window is raised with `SetWindowPos(HWND_TOPMOST, …, SWP_NOACTIVATE)`. It reserves no desktop work area and places no input-blocking strip over the screen while hidden. Switching uses Windows' normal `SetForegroundWindow` policy; it does not change the foreground lock timeout or install keyboard/mouse hooks.

- Intended for ordinary desktop fullscreen windows, including classic Remote Desktop. This is **not** a guarantee over exclusive-rendering games, applications that continually reclaim the topmost position, or Windows' secure desktop (UAC, lock, sign-in).
- Windows can deny foreground activation. If activation is denied or a target closes, the toolbar reports the failure rather than claiming success. Privilege differences and protected windows can restrict discovery or switching; run the toolbar and target applications at the same privilege level where needed. Administrator rights are not normally required.
- Only visible, titled, unowned, non-tool, non-cloaked top-level windows in the current local desktop are listed, including minimized windows. Inaccessible processes are omitted. Windows on other virtual desktops may be cloaked and are not listed.
- Other applications' deliberately always-on-top windows can still cover an ordinary non-topmost target. EdgeSwitch does not rewrite target applications' window styles.

Win32 references: [foreground activation restrictions](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow), [window positioning and topmost behavior](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos).

## Publish a standalone executable

```powershell
dotnet publish EdgeSwitch.csproj -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
  -o artifacts/win-x64
```

Distribute `artifacts/win-x64/EdgeSwitch.exe`; the .NET runtime is bundled. The first publish may download Microsoft runtime packs. Use `win-arm64` instead of `win-x64` for ARM64 machines. The executable is unsigned; Windows may display a reputation warning.

## Publish a framework-dependent executable

This smaller release **does not bundle .NET**. The target PC must have the **.NET 10 Desktop Runtime (x64)** installed.

```powershell
dotnet publish EdgeSwitch.csproj -c Release -r win-x64 --self-contained false `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=false `
  -o artifacts/win-x64-framework-dependent
```

Copy `artifacts/win-x64-framework-dependent/EdgeSwitch.exe` to the target PC, exit its older EdgeSwitch instance, and launch the replacement. The `.pdb` is optional debugging data; saved settings remain in the user's existing settings file.

## CI and releases

Windows CI runs on pushes to `master`, pull requests, and manual workflow runs. It restores and builds the app with the .NET 10 SDK, then runs the default `tests/ToolbarCaptureSmoke.ps1` checks. The desktop-wide `-ExerciseHostDesktop` option is intentionally not enabled in CI. `global.json` keeps SDK selection on the latest installed stable .NET 10 feature band.

Pushing a stable version tag such as `v1.0.0` runs the same build/smoke checks, publishes the framework-dependent Windows x64 executable with that version, and creates a GitHub release containing `EdgeSwitch.exe` and `SHA256SUMS.txt`. The release is published only after the checksum is verified and both assets have been uploaded. Existing published releases are not overwritten.

## Verification

The single-icon desktop/settings update passed a Release build with zero warnings/errors, the default smoke, and the opt-in desktop-action smoke below. The existing logo's right-click opened the actual Settings dialog and Cancel returned without minimizing helper windows. Its primary click minimized four real native helper windows while keeping their handles and process alive; the toolbar was hidden but not minimized. The test restored the desktop's last minimize batch with `UndoMinimizeALL`, verified restored helper windows, and confirmed toolbar reveal still worked. A rendered toolbar retained one logo and the dashless session labels. These were local helper-window tests, not connected RDP sessions on another machine.

The dashless-label and exact-hover-span update passed the Release build and `tests/ToolbarCaptureSmoke.ps1`. All 12 placements passed first/middle/last in-span pixel hits, out-of-span and third-inward-pixel rejection, hidden/unmoved hit testing, dwell cancellation/restart, explicit hiding/rearm, and the existing capture-layout transitions. Hidden growth/shrink refresh and partially shared edges on a negative-origin/scaled synthetic monitor also passed. A rendered four-entry toolbar was inspected with icons directly beside session names. These are local native-window tests with controlled pointer inputs and synthetic RDP metadata, not another-machine or physical multi-display verification.

A captured-window visibility defect was reproduced locally: four windows were in the toolbar's model, but a stale 54×54 size cache left their viewport at zero. Pending WPF item/visibility layout is now applied before measuring and caching the toolbar. `tests/ToolbarCaptureSmoke.ps1` failed against the old binary and passed after the fix, covering empty-to-captured, repeated reveal, clearing and re-adding capture at all 12 positions, plus reachable Remote Desktop icon/name entries after label growth. The test uses disposable local native windows and synthetic RDP metadata, not sessions on another machine, and does not save or change user settings. The corrected four-entry rendered toolbar was inspected.

After `dotnet build EdgeSwitch.csproj -c Release`, run the regression from the repository root with PowerShell 7 on Windows, running on .NET 10 or newer:

```powershell
pwsh -NoProfile -STA -File tests/ToolbarCaptureSmoke.ps1
```

The default smoke does not minimize the desktop. To also exercise the logo's desktop action, opt in explicitly. **This briefly minimizes all local desktop windows**, not just the helper windows; the test uses `UndoMinimizeALL` to restore the minimize batch after observing its own helpers minimize.

```powershell
pwsh -NoProfile -STA -File tests/ToolbarCaptureSmoke.ps1 -ExerciseHostDesktop
```

The compact icon-toolbar update passed a Release build with zero warnings/errors and 257 assertions in a temporary hosted-WPF/native-window smoke harness. Coverage included distinct real window icons, icon reuse and HICON cleanup, a slow icon query bounded to 65 ms, empty/ordinary/mixed entries, all 12 placements, high-DPI rounding without unnecessary scrollbars, horizontal/vertical overflow, long/renamed/localized RDP labels, Settings access through the app icon, Escape hiding, minimized restoration, and visible activation-denied feedback. A vertical-overflow defect and fractional-DPI scrollbar defect were reproduced and fixed; rendered empty, icon-only, mixed horizontal/vertical, and long-label toolbars were inspected. RDP labels used synthetic metadata, not connected remote sessions. The rebuilt standalone executable was restarted and its compact UI plus app-icon Settings/Cancel flow passed UI Automation verification. The desktop denied pointer access and returned no foreground window during this run, so successful mouse-driven focus switching is **not** claimed as reverified.

The 12-location update passed a Release build with zero warnings/errors and 556 assertions in a temporary hosted-WPF smoke harness against the built application. All 12 choices passed Settings save/apply/reopen and native HWND position/orientation checks. Coverage included negative-origin and small/high-DPI synthetic monitor bounds, two-pixel trigger boundaries, Automatic shared-seam exclusion and exposed segments, explicit-display seams, focus-preserving reveal, dwell/hide/rearm transitions, Cancel isolation, legacy numeric settings, and invalid-edge rejection. Rendered Settings (including minimum-width layout), picker, horizontal toolbar, and vertical toolbar snapshots were inspected. Monitor topology and pointer/time probes were controlled inputs, not a physical multi-display or mouse-driven end-to-end test. Original user settings were restored after the smoke run.

Release build completed with zero warnings/errors. Before the final review fixes, the framework-dependent build and standalone x64 executable passed real mouse-driven smoke scenarios at 175% scaling: all four edges, focus-preserving reveal over a topmost borderless fullscreen window, switching two windows from one process, minimized restoration, auto-hide, closed-window removal, capture changes, Cancel isolation, save-error handling, and tray Show/Settings/Exit. Actual toolbar and Settings screenshots were inspected. Malformed-settings recovery was reproduced and fixed; malformed values, empty capture lists, and dotted executable-name save/load round trips passed.

Final review fixes keep the toolbar open while resting on the trigger edge and contain transient Win32 failures. The edge defect was reproduced with real input. The final behavior passed hosted WPF scenarios using real native windows and controlled pointer/time inputs at all four edges (stay visible, leave/hide, return/reveal). An invalid native handle probe verified error reporting and timer survival. The final published executable's toolbar and Settings open/Cancel flow passed UI Automation invocation. A final mouse-driven rerun became unavailable because Windows stopped granting pointer access (`GetCursorPos`: access denied; no foreground window), so that rerun is not claimed as passing.

**Not verified here:** connected Remote Desktop sessions, multiple physical displays/mixed-DPI transitions, ARM64, secure desktop, or exclusive fullscreen rendering. The local fullscreen-window exercise is not evidence of an actual connected RDP session test.
