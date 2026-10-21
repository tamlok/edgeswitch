using System.Globalization;

namespace EdgeSwitch;

internal sealed record WindowEntry(nint Handle, int ProcessId, string ProcessName, string Title)
{
    public string Subtitle => $"{ProcessName}.exe · PID {ProcessId.ToString(CultureInfo.InvariantCulture)}";
}
