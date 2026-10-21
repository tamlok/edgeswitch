using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace EdgeSwitch;

internal sealed class WindowCatalog
{
    /// <summary>
    /// Takes a fresh per-HWND snapshot, including minimized windows. A null
    /// filter captures every eligible process; an empty filter captures none.
    /// Windows belonging to inaccessible or exited processes are omitted.
    /// </summary>
    public List<WindowEntry> GetWindows(IReadOnlyCollection<string>? processNames = null)
    {
        List<WindowEntry> windows = new();
        HashSet<string>? filter = null;
        if (processNames is not null)
        {
            filter = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string value in processNames)
            {
                string name = ToolbarSettings.NormalizeProcessName(value);
                if (name.Length != 0)
                {
                    filter.Add(name);
                }
            }

            if (filter.Count == 0)
            {
                return windows;
            }
        }

        uint ownProcessId = (uint)Environment.ProcessId;
        // Cache failures too: a protected process with multiple HWNDs should
        // not cause repeated OpenProcess calls during a single enumeration.
        Dictionary<uint, string?> processCache = new();
        StringBuilder? imagePath = null;
        StringBuilder? titleBuffer = null;
        NativeMethods.EnumWindowsCallback callback = (hwnd, parameter) =>
        {
            if (!NativeMethods.IsWindowVisible(hwnd) ||
                NativeMethods.GetWindow(hwnd, NativeMethods.GwOwner) != nint.Zero ||
                (NativeMethods.GetWindowLong(hwnd, NativeMethods.GwlExStyle) & NativeMethods.WsExToolWindow) != 0)
            {
                return true;
            }

            if (NativeMethods.DwmGetWindowAttribute(hwnd, NativeMethods.DwmaCloaked,
                out int cloaked, sizeof(int)) != 0 || cloaked != 0)
            {
                return true;
            }

            int titleLength = NativeMethods.GetWindowTextLength(hwnd);
            if (titleLength <= 0 ||
                NativeMethods.GetWindowThreadProcessId(hwnd, out uint processId) == 0 ||
                processId == 0 || processId == ownProcessId)
            {
                return true;
            }

            if (!processCache.TryGetValue(processId, out string? processName))
            {
                imagePath ??= new StringBuilder(512);
                processName = NativeMethods.GetProcessName(processId, imagePath);
                processCache.Add(processId, processName);
            }

            if (processName is null || (filter is not null && !filter.Contains(processName)))
            {
                return true;
            }

            titleBuffer ??= new StringBuilder(256);
            titleBuffer.Clear();
            titleBuffer.EnsureCapacity(titleLength + 1);
            if (NativeMethods.GetWindowText(hwnd, titleBuffer, titleBuffer.Capacity) <= 0)
            {
                return true;
            }

            string title = titleBuffer.ToString();
            if (string.IsNullOrWhiteSpace(title) ||
                !NativeMethods.IsWindow(hwnd) ||
                !NativeMethods.IsWindowVisible(hwnd) ||
                NativeMethods.GetWindowThreadProcessId(hwnd, out uint currentProcessId) == 0 ||
                currentProcessId != processId)
            {
                return true;
            }

            windows.Add(new WindowEntry(hwnd, (int)processId, processName, title));
            return true;
        };

        bool enumerated = NativeMethods.EnumWindows(callback, nint.Zero);
        int error = Marshal.GetLastPInvokeError();
        GC.KeepAlive(callback);
        if (!enumerated)
        {
            throw new Win32Exception(error, "Windows could not enumerate application windows.");
        }

        windows.Sort(static (left, right) =>
        {
            int comparison = left.IsRemoteDesktop.CompareTo(right.IsRemoteDesktop);
            if (comparison != 0)
            {
                return comparison;
            }

            comparison = StringComparer.OrdinalIgnoreCase.Compare(left.Title, right.Title);
            if (comparison != 0)
            {
                return comparison;
            }

            comparison = StringComparer.OrdinalIgnoreCase.Compare(left.ProcessName, right.ProcessName);
            if (comparison != 0)
            {
                return comparison;
            }

            comparison = left.ProcessId.CompareTo(right.ProcessId);
            return comparison != 0 ? comparison : left.Handle.ToInt64().CompareTo(right.Handle.ToInt64());
        });
        return windows;
    }

    /// <summary>
    /// Requests restoration and foreground activation without bypassing Windows
    /// focus policy. False can also mean an asynchronous restore is still pending;
    /// callers may observe foreground/non-iconic state later without retrying focus.
    /// </summary>
    public bool TryActivate(WindowEntry entry)
    {
        if (!HasWindowIdentity(entry))
        {
            return false;
        }

        string? processName = NativeMethods.GetProcessName((uint)entry.ProcessId, new StringBuilder(512));
        if (!StringComparer.OrdinalIgnoreCase.Equals(processName, entry.ProcessName) ||
            !HasWindowIdentity(entry))
        {
            return false;
        }

        if (NativeMethods.IsIconic(entry.Handle) &&
            !NativeMethods.ShowWindowAsync(entry.Handle, NativeMethods.SwRestore))
        {
            return false;
        }

        if (!HasWindowIdentity(entry))
        {
            return false;
        }

        NativeMethods.SetForegroundWindow(entry.Handle);
        return NativeMethods.GetForegroundWindow() == entry.Handle && HasWindowIdentity(entry);
    }

    private static bool HasWindowIdentity(WindowEntry entry) =>
        entry.Handle != nint.Zero &&
        entry.ProcessId > 0 &&
        entry.ProcessId != Environment.ProcessId &&
        NativeMethods.IsWindow(entry.Handle) &&
        NativeMethods.GetWindowThreadProcessId(entry.Handle, out uint processId) != 0 &&
        processId == (uint)entry.ProcessId;
}
