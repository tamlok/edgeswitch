using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace EdgeSwitch;

[StructLayout(LayoutKind.Sequential)]
internal struct NativeRect
{
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;

    public readonly int Width => Right - Left;

    public readonly int Height => Bottom - Top;

    public readonly bool Contains(int x, int y) =>
        x >= Left && x < Right && y >= Top && y < Bottom;
}

[StructLayout(LayoutKind.Sequential)]
internal struct NativePoint
{
    public int X;
    public int Y;
}

internal readonly record struct DisplayMonitor(
    string DeviceName,
    NativeRect Bounds,
    bool IsPrimary,
    double Scale);

internal static class NativeMethods
{
    internal const int GwlExStyle = -20;
    internal const int WsExToolWindow = 0x00000080;
    internal const uint GwOwner = 4;
    internal const uint DwmaCloaked = 14;
    internal const int SwRestore = 9;

    private const int WsExAppWindow = 0x00040000;
    private const int WsExNoActivate = 0x08000000;
    private const int SwHide = 0;
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private const uint SwpNoZOrder = 0x0004;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpFrameChanged = 0x0020;
    private const uint SwpShowWindow = 0x0040;
    private const uint MonitorInfoPrimary = 0x00000001;
    private const uint ProcessQueryLimitedInformation = 0x00001000;
    private const int ErrorInsufficientBuffer = 122;
    private const int MaximumImagePathLength = 32768;

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal delegate bool EnumWindowsCallback(nint hwnd, nint parameter);

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private delegate bool MonitorEnumCallback(nint monitor, nint hdc, ref NativeRect bounds, nint parameter);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MonitorInfoEx
    {
        public uint Size;
        public NativeRect Monitor;
        public NativeRect Work;
        public uint Flags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
    }

    public static List<DisplayMonitor> GetMonitors()
    {
        List<DisplayMonitor> monitors = new();
        MonitorEnumCallback callback = (nint monitor, nint hdc, ref NativeRect bounds, nint parameter) =>
        {
            MonitorInfoEx info = new()
            {
                Size = (uint)Marshal.SizeOf<MonitorInfoEx>(),
                DeviceName = ""
            };
            if (!GetMonitorInfo(monitor, ref info))
            {
                return true;
            }

            // With the application's PerMonitorV2 awareness, effective DPI is
            // specific to this monitor; the monitor rectangle remains physical.
            if (GetDpiForMonitor(monitor, 0, out uint dpiX, out _) != 0 || dpiX == 0)
            {
                return true;
            }

            monitors.Add(new DisplayMonitor(
                info.DeviceName,
                info.Monitor,
                (info.Flags & MonitorInfoPrimary) != 0,
                dpiX / 96.0));
            return true;
        };

        bool enumerated = EnumDisplayMonitors(nint.Zero, nint.Zero, callback, nint.Zero);
        int error = Marshal.GetLastPInvokeError();
        GC.KeepAlive(callback);
        if (!enumerated)
        {
            throw new Win32Exception(error, "Windows could not enumerate displays.");
        }

        monitors.Sort(static (left, right) =>
        {
            int comparison = StringComparer.OrdinalIgnoreCase.Compare(left.DeviceName, right.DeviceName);
            if (comparison != 0)
            {
                return comparison;
            }

            comparison = left.Bounds.Left.CompareTo(right.Bounds.Left);
            return comparison != 0 ? comparison : left.Bounds.Top.CompareTo(right.Bounds.Top);
        });
        return monitors;
    }

    public static void ConfigureToolbar(nint hwnd)
    {
        // Extended styles are 32-bit values even in a 64-bit process; unlike
        // pointer-valued window slots, GWL_EXSTYLE is safe with GetWindowLongW.
        int previousStyle = GetWindowLong(hwnd, GwlExStyle);
        int error = Marshal.GetLastPInvokeError();
        if (previousStyle == 0 && error != 0)
        {
            throw new Win32Exception(error, "Windows could not read the toolbar styles.");
        }

        int style = (previousStyle | WsExToolWindow) & ~(WsExAppWindow | WsExNoActivate);
        if (SetWindowLong(hwnd, GwlExStyle, style) == 0)
        {
            error = Marshal.GetLastPInvokeError();
            if (error != 0)
            {
                throw new Win32Exception(error, "Windows could not configure the toolbar styles.");
            }
        }

        if (!SetWindowPos(hwnd, nint.Zero, 0, 0, 0, 0,
            SwpNoMove | SwpNoSize | SwpNoZOrder | SwpNoActivate | SwpFrameChanged))
        {
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "Windows could not apply the toolbar styles.");
        }
    }

    public static void MoveTopmost(nint hwnd, int x, int y, int width, int height)
    {
        if (!SetWindowPos(hwnd, new nint(-1), x, y, width, height, SwpNoActivate | SwpShowWindow))
        {
            throw new Win32Exception(Marshal.GetLastPInvokeError(), "Windows could not position the toolbar.");
        }
    }

    public static void HideWindow(nint hwnd)
    {
        ShowWindow(hwnd, SwHide);
    }

    internal static string? GetProcessName(uint processId, StringBuilder imagePath)
    {
        using SafeProcessHandle process = OpenProcess(ProcessQueryLimitedInformation, false, processId);
        if (process.IsInvalid)
        {
            return null;
        }

        while (true)
        {
            imagePath.Clear();
            uint length = (uint)imagePath.Capacity;
            if (QueryFullProcessImageName(process, 0, imagePath, ref length))
            {
                string name = ToolbarSettings.NormalizeProcessName(imagePath.ToString());
                return name.Length == 0 ? null : name;
            }

            if (Marshal.GetLastPInvokeError() != ErrorInsufficientBuffer ||
                imagePath.Capacity >= MaximumImagePathLength)
            {
                return null;
            }

            imagePath.EnsureCapacity(Math.Min(imagePath.Capacity * 2, MaximumImagePathLength));
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetCursorPos(out NativePoint point);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(nint hwnd, out NativeRect rect);

    [DllImport("user32.dll")]
    public static extern nint GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(nint hwnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(nint hwnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsIconic(nint hwnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool IsWindow(nint hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool EnumWindows(EnumWindowsCallback callback, nint parameter);

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern uint GetWindowThreadProcessId(nint hwnd, out uint processId);

    [DllImport("user32.dll", SetLastError = true)]
    internal static extern nint GetWindow(nint hwnd, uint command);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    internal static extern int GetWindowLong(nint hwnd, int index);

    [DllImport("user32.dll", EntryPoint = "GetWindowTextLengthW", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern int GetWindowTextLength(nint hwnd);

    [DllImport("user32.dll", EntryPoint = "GetWindowTextW", CharSet = CharSet.Unicode, SetLastError = true)]
    internal static extern int GetWindowText(nint hwnd, StringBuilder text, int maximumCount);

    [DllImport("dwmapi.dll")]
    internal static extern int DwmGetWindowAttribute(nint hwnd, uint attribute, out int value, uint valueSize);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool ShowWindowAsync(nint hwnd, int command);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static extern bool SetForegroundWindow(nint hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumDisplayMonitors(nint hdc, nint clip, MonitorEnumCallback callback, nint parameter);

    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfoEx info);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(nint monitor, int dpiType, out uint dpiX, out uint dpiY);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongW", SetLastError = true)]
    private static extern int SetWindowLong(nint hwnd, int index, int value);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(nint hwnd, nint insertAfter, int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(nint hwnd, int command);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeProcessHandle OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", EntryPoint = "QueryFullProcessImageNameW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageName(SafeProcessHandle process, uint flags, StringBuilder imagePath, ref uint size);
}
