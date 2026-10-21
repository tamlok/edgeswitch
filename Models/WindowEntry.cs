using System;
using System.Globalization;

namespace EdgeSwitch;

internal sealed record WindowEntry(nint Handle, int ProcessId, string ProcessName, string Title)
{
    public string Subtitle => $"{ProcessName}.exe · PID {ProcessId.ToString(CultureInfo.InvariantCulture)}";

    public bool IsRemoteDesktop => string.Equals(ProcessName, "mstsc", StringComparison.OrdinalIgnoreCase)
        || string.Equals(ProcessName, "msrdc", StringComparison.OrdinalIgnoreCase);

    public string SessionName
    {
        get
        {
            if (!IsRemoteDesktop)
                return "";
            const string connectionSuffix = " - Remote Desktop Connection";
            const string desktopSuffix = " - Remote Desktop";
            int suffixLength = Title.EndsWith(connectionSuffix, StringComparison.OrdinalIgnoreCase) ? connectionSuffix.Length
                : Title.EndsWith(desktopSuffix, StringComparison.OrdinalIgnoreCase) ? desktopSuffix.Length : 0;
            if (suffixLength == 0)
                return Title;
            string name = Title[..^suffixLength].Trim();
            return name.Length > 0 ? name : Title;
        }
    }
}
