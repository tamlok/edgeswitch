using System;
using System.Collections.Generic;
using System.IO;

namespace EdgeSwitch;

internal enum ToolbarEdge
{
    Left,
    Top,
    Right,
    Bottom
}

internal sealed class ToolbarSettings
{
    private static readonly char[] InvalidProcessNameCharacters = Path.GetInvalidFileNameChars();

    public ToolbarEdge Edge { get; set; } = ToolbarEdge.Left;

    public string MonitorDeviceName { get; set; } = "";

    public List<string> CapturedProcesses { get; set; } = new() { "mstsc" };

    public int HideDelayMilliseconds { get; set; } = 700;

    internal static string NormalizeProcessName(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return "";
        }

        string name = value.Trim();
        if (name.Length >= 2 && name[0] == '"' && name[^1] == '"')
        {
            name = name[1..^1].Trim();
        }

        name = Path.GetFileName(name);
        // Stored names are basenames. Removing arbitrary extensions again would
        // turn a valid dotted basename such as "foo.bar" into a different process.
        if (name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            name = Path.GetFileNameWithoutExtension(name);
        }

        name = name.Trim();
        if (name.Length == 0 || name.IndexOfAny(InvalidProcessNameCharacters) >= 0)
        {
            return "";
        }

        foreach (char character in name)
        {
            if (character != '.')
            {
                return name;
            }
        }

        return "";
    }

    internal static List<string> NormalizeProcessNames(IEnumerable<string>? values)
    {
        List<string> names = new();
        if (values is null)
        {
            return names;
        }

        HashSet<string> seen = new(StringComparer.OrdinalIgnoreCase);
        foreach (string value in values)
        {
            string name = NormalizeProcessName(value);
            if (name.Length != 0 && seen.Add(name))
            {
                names.Add(name);
            }
        }

        return names;
    }
}
