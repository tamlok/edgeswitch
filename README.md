# EdgeSwitch

<img src="Assets/EdgeSwitch.png" alt="EdgeSwitch icon" width="80" height="80">

[![CI](https://github.com/tamlok/edgeswitch/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/tamlok/edgeswitch/actions/workflows/ci.yml)

Switch between apps and Remote Desktop windows from a compact toolbar at the edge of your screen.

![EdgeSwitch toolbar with app icons and example Remote Desktop sessions](Assets/ToolbarPreview.png)

*Illustrative preview with fictional session names.*

## Download

**[Download EdgeSwitch for Windows x64](https://github.com/tamlok/edgeswitch/releases/latest/download/EdgeSwitch.exe)**

Requires **Windows 10/11 x64** and the **[.NET 10 Desktop Runtime (x64)](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)**. The runtime is **not bundled**.

Run `EdgeSwitch.exe`—there is no app installer. The executable is unsigned, so Windows may display a reputation warning.

## Use

Run EdgeSwitch on the computer where your Remote Desktop client windows are open. By default, it appears on the left edge and includes Remote Desktop Connection (`mstsc.exe`).

Rest the pointer against the part of the screen edge where the toolbar appears. It opens after a short pause; the rest of the edge does not trigger it.

| Action | What it does |
| --- | --- |
| Click an app icon or session name | Switch to that window, restoring it if minimized. |
| Left-click the EdgeSwitch icon | Minimize local windows to show the host desktop. Remote Desktop sessions stay open. |
| Right-click the EdgeSwitch icon | Open Settings. |
| Press **Esc** or **Alt+F4** | Hide the toolbar. |

The desktop action is not a toggle—select an app or session entry to restore it. After hiding the toolbar, move outside its edge segment before hovering there again.

The notification-area menu provides **Show toolbar**, **Settings**, and **Exit EdgeSwitch**. Check Windows' **Show Hidden Icons** if you cannot see it.

## Settings

- **Apps:** select which applications to include, or use **Add / Browse** for others such as `msrdc.exe`. “Capture” selects windows; it does not record your screen.
- **Position:** choose from 12 centered or corner-aligned locations. **Top-left** is horizontal; **Left-top** is vertical.
- **Display:** Automatic ignores seams between monitors. Select a specific display to allow its shared edges.
- **Hide delay:** adjust how quickly the toolbar hides when idle.
- **Always make remote desktop session fullscreen:** off by default. When enabled, clicking a desktop-session entry for `mstsc.exe` or `msrdc.exe` requests fullscreen using [Ctrl+Alt+Break (`VK_CANCEL`)](https://learn.microsoft.com/en-us/windows/win32/termserv/imsrdpclientadvancedsettings-hotkeyfullscreen), the Pause/Break key. Already-fullscreen sessions stay unchanged; ordinary apps, connection dialogs, and RemoteApps are not toggled. This does not apply just by revealing the toolbar.
- **Startup:** enable **Start EdgeSwitch when I sign in** to launch automatically when you sign in to Windows. Off by default; applies only to your account and needs no administrator rights.

Choose **Save** to apply your changes; **Cancel** leaves them unchanged. Toolbar settings are stored in `%LOCALAPPDATA%\EdgeSwitch\settings.json`. The startup preference uses the `EdgeSwitch` entry under `HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run`.

If you move the portable executable, run it from the new location and choose **Save** with startup enabled to update its path. Disable startup and save before deleting the executable. Windows **Startup Apps** can independently block automatic launch; if disabled there, re-enable EdgeSwitch there as well.

## Good to know

- If only the EdgeSwitch icon appears, check the selected apps in Settings and choose **Save**.
- Each window gets its own entry. Multiple sessions kept as tabs inside one window appear as a single entry.
- Hover over an entry to see its full window title.
- EdgeSwitch is intended for regular app and Remote Desktop fullscreen windows. Windows lock/UAC screens and exclusive-fullscreen games can block the toolbar or window switching.
- If Windows or the remote client refuses the fullscreen request, EdgeSwitch reports it rather than maximizing the window or repeatedly toggling. Release held modifier keys and click the session again, or use Ctrl+Alt+Break directly in the session.

## Build from source

On Windows with the **.NET 10 SDK** installed:

```powershell
dotnet build EdgeSwitch.csproj -c Release
.\bin\Release\net10.0-windows\EdgeSwitch.exe
```

Check fullscreen shortcut delivery and input guards on an idle interactive desktop using .NET 10 PowerShell. This uses disposable windows, not a connected RDP session:

```powershell
pwsh -NoProfile -STA -File tests/FullscreenShortcutSmoke.ps1
```
