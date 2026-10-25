using System;
using System.Collections.Generic;
using System.ComponentModel;

namespace EdgeSwitch;

internal sealed class PluginConfiguration
{
    public bool Enabled { get; set; }
    public Dictionary<string, string> Options { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public PluginConfiguration Clone() => new()
    {
        Enabled = Enabled,
        Options = new Dictionary<string, string>(Options, StringComparer.OrdinalIgnoreCase)
    };

    internal static bool IsIdentifier(string value)
    {
        if (string.IsNullOrEmpty(value) || value.Length > 64)
            return false;
        foreach (char character in value)
            if (!char.IsAsciiLetterOrDigit(character) && character is not '-' and not '_')
                return false;
        return true;
    }
}

internal sealed class PluginManifest
{
    public int ProtocolVersion { get; set; }
    public string Name { get; set; } = "";
    public string Description { get; set; } = "";
    public string Executable { get; set; } = "";
    public string[] Arguments { get; set; } = Array.Empty<string>();
    public int RefreshSeconds { get; set; } = 300;
    public int TimeoutSeconds { get; set; } = 30;
    public List<PluginSettingDefinition> Settings { get; set; } = new();
}

internal sealed class PluginSettingDefinition
{
    public string Key { get; set; } = "";
    public string Label { get; set; } = "";
    public string DefaultValue { get; set; } = "";
}

internal sealed record PluginDefinition(string Id, string Directory, PluginManifest? Manifest, string? Error)
{
    public string Name => Manifest?.Name ?? Id;
}

internal sealed class PluginCard : INotifyPropertyChanged
{
    public string Name { get; }
    public string Text { get; private set; } = "Loading";
    public string ToolTip { get; private set; } = "Waiting for the first plugin reading.";

    internal PluginCard(string name) => Name = name;

    internal bool Update(string text, string toolTip)
    {
        bool resized = Text != text;
        if (resized)
        {
            Text = text;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Text)));
        }
        if (ToolTip != toolTip)
        {
            ToolTip = toolTip;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(ToolTip)));
        }
        return resized;
    }

    public event PropertyChangedEventHandler? PropertyChanged;
}
