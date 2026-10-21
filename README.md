# EdgeSwitch

A Windows screen-edge toolbar for switching **local application windows**, particularly separate fullscreen Remote Desktop sessions. Built with C#/.NET 10, WPF, and Win32; no third-party packages.

## Run

Requires Windows 10/11 and the **.NET 10 Desktop Runtime**. To build from source, install the .NET 10 SDK, then run these commands from this directory:

```powershell
dotnet build EdgeSwitch.csproj -c Release
.\bin\Release\net10.0-windows\EdgeSwitch.exe
```

The toolbar starts on the **left edge**, with `mstsc.exe` selected. Its notification-area icon provides **Show toolbar**, **Settings**, and **Exit EdgeSwitch**. Windows may put the icon under **Show Hidden Icons**. Only one instance runs per Windows login session. Alt+F4 hides the toolbar; use the tray menu to quit.

### Switch Remote Desktop sessions

1. Run EdgeSwitch on the **local machine** that starts your Remote Desktop connections, not inside the remote desktop.
2. Open two or more Remote Desktop Connection (`mstsc.exe`) windows and connect to your hosts. They may be fullscreen.
3. Rest the pointer against the left screen edge for about 150–250 ms. Move onto the revealed toolbar.
4. Click the session title to switch to that window. Minimized windows are restored. The toolbar hides after a successful switch.

Each qualifying **window** gets its own entry, even when several belong to one process. Entries show the current window title, executable, and process ID. The visible list refreshes once per second. Hovering reveals the toolbar **without taking keyboard focus** from the current application; clicking performs the activation.

The toolbar stays open while the pointer is over it or resting on its trigger edge, it has keyboard focus, or Settings is open. Otherwise it hides after the configured delay (700 ms by default). **Hide** or **Esc** hides it immediately. After explicit hiding, move away from the edge before hovering again. Launching or selecting Show toolbar gives you four seconds to reach it. Transient native enumeration or positioning errors are reported without stopping the toolbar's timer; the last known window list is retained until a refresh succeeds.

## Settings

- **Captured executables:** check applications whose windows should appear. “Capture” means inclusion in the switcher, **not screen recording**, remote input injection, or launching apps. The list combines saved choices with processes that currently have capturable windows.
- **Add / Browse:** add an executable even when it is not running. Names and paths are accepted; matching uses the executable basename, case-insensitively, without `.exe`. Dotted names such as `my.client.exe` remain `my.client`. No wildcard matching. Programs with the same executable basename are captured together, regardless of installation directory.
- **Toolbar edge:** Left, Top, Right, or Bottom. Left avoids the Remote Desktop connection bar at the top. Use an edge different from any auto-hide taskbar or competing dock.
- **Display:** Automatic responds to exposed screen-edge segments, not seams between adjacent monitors. Selecting a particular display also permits its shared edges. A disconnected saved display falls back to the primary display with a warning.
- **Hide delay:** 200–5,000 milliseconds.
- **Save / Cancel:** Save persists and applies the changes; Cancel leaves the current configuration intact. An empty capture list is valid.

Settings are stored per user in `%LOCALAPPDATA%\EdgeSwitch\settings.json`. Saves replace the file through a same-directory temporary file. Unreadable or malformed settings produce a warning and use defaults without overwriting the original; a later explicit Save replaces it. Nothing is persisted until you save.

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

## Verification

Release build completed with zero warnings/errors. Before the final review fixes, the framework-dependent build and standalone x64 executable passed real mouse-driven smoke scenarios at 175% scaling: all four edges, focus-preserving reveal over a topmost borderless fullscreen window, switching two windows from one process, minimized restoration, auto-hide, closed-window removal, capture changes, Cancel isolation, save-error handling, and tray Show/Settings/Exit. Actual toolbar and Settings screenshots were inspected. Malformed-settings recovery was reproduced and fixed; malformed values, empty capture lists, and dotted executable-name save/load round trips passed.

Final review fixes keep the toolbar open while resting on the trigger edge and contain transient Win32 failures. The edge defect was reproduced with real input. The final behavior passed hosted WPF scenarios using real native windows and controlled pointer/time inputs at all four edges (stay visible, leave/hide, return/reveal). An invalid native handle probe verified error reporting and timer survival. The final published executable's toolbar and Settings open/Cancel flow passed UI Automation invocation. A final mouse-driven rerun became unavailable because Windows stopped granting pointer access (`GetCursorPos`: access denied; no foreground window), so that rerun is not claimed as passing.

**Not verified here:** connected Remote Desktop sessions, multiple physical displays/mixed-DPI transitions, ARM64, secure desktop, or exclusive fullscreen rendering. The local fullscreen-window exercise is not evidence of an actual connected RDP session test.
