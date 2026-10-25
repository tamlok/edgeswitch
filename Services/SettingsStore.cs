using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security;
using System.Text;
using Microsoft.Win32;

namespace EdgeSwitch;

internal static class SettingsStore
{
    private const string StartupKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string StartupValueName = "EdgeSwitch";

    public static ToolbarSettings Load(out string? warning)
    {
        warning = null;
        string path = "settings.ini";
        try
        {
            path = GetSettingsPath();
            return ReadSettings(File.ReadAllText(path));
        }
        catch (FileNotFoundException)
        {
            return new ToolbarSettings();
        }
        catch (DirectoryNotFoundException)
        {
            return new ToolbarSettings();
        }
        catch (Exception exception) when (exception is IOException
            or InvalidDataException or UnauthorizedAccessException or SecurityException or ArgumentException)
        {
            warning = $"Could not load settings from \"{path}\". {exception.Message} "
                + "Default settings are being used. The existing settings file was not overwritten.";
            return new ToolbarSettings();
        }
    }

    public static bool IsStartupEnabled()
    {
        using RegistryKey? key = Registry.CurrentUser.OpenSubKey(StartupKeyPath);
        return key?.GetValue(StartupValueName) is not null;
    }

    public static ToolbarSettings Save(ToolbarSettings settings, bool startWithWindows)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ToolbarSettings normalized = NormalizeSettings(settings);
        string ini = WriteSettings(normalized);
        string path = GetSettingsPath();
        string directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        string temporaryPath = Path.Combine(directory, $"settings.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporaryPath, ini);
            string? command = startWithWindows ? GetStartupCommand() : null;
            using RegistryKey? startupKey = Registry.CurrentUser.OpenSubKey(StartupKeyPath);
            object? previousValue = startupKey?.GetValue(StartupValueName, null,
                RegistryValueOptions.DoNotExpandEnvironmentNames);
            RegistryValueKind previousKind = previousValue is null
                ? RegistryValueKind.String : startupKey!.GetValueKind(StartupValueName);
            bool startupChanged = !Equals(previousValue, command);
            using RegistryKey? writableKey = startupChanged
                ? Registry.CurrentUser.CreateSubKey(StartupKeyPath) : null;
            if (startupChanged)
            {
                if (command is null)
                    writableKey!.DeleteValue(StartupValueName, throwOnMissingValue: false);
                else
                    writableKey!.SetValue(StartupValueName, command, RegistryValueKind.String);
            }

            try
            {
                File.Move(temporaryPath, path, overwrite: true);
            }
            catch (Exception saveException) when (saveException is IOException
                or UnauthorizedAccessException or SecurityException)
            {
                if (startupChanged)
                {
                    try
                    {
                        if (previousValue is null)
                            writableKey!.DeleteValue(StartupValueName, throwOnMissingValue: false);
                        else
                            writableKey!.SetValue(StartupValueName, previousValue, previousKind);
                    }
                    catch (Exception rollbackException) when (rollbackException is IOException
                        or UnauthorizedAccessException or SecurityException)
                    {
                        throw new IOException("The settings file could not be saved and the previous Windows startup "
                            + "entry could not be restored. Check Windows Startup Apps and save your preference again. "
                            + $"{saveException.Message} {rollbackException.Message}",
                            new AggregateException(saveException, rollbackException));
                    }
                }

                throw;
            }
        }
        finally
        {
            try
            {
                File.Delete(temporaryPath);
            }
            catch (Exception exception) when (exception is IOException
                or UnauthorizedAccessException or SecurityException)
            {
                // Cleanup must not mask the original persistence error.
            }
        }
        return normalized;
    }

    private static string GetStartupCommand()
    {
        string? executable = Environment.ProcessPath;
        if (string.IsNullOrEmpty(executable) || !File.Exists(executable))
        {
            throw new IOException("The running executable could not be located. Run EdgeSwitch.exe again before enabling startup.");
        }

        string command = $"\"{executable}\"";
        if (string.Equals(Path.GetFileNameWithoutExtension(executable), "dotnet", StringComparison.OrdinalIgnoreCase))
        {
            string entryPath = Path.GetFullPath(Environment.GetCommandLineArgs()[0]);
            if (!File.Exists(entryPath))
                throw new IOException("The EdgeSwitch application file could not be located. Run EdgeSwitch.exe again before enabling startup.");
            command += $" \"{entryPath}\"";
        }

        if (command.Length > 260)
            throw new IOException("The Windows startup command exceeds 260 characters. Move EdgeSwitch to a shorter path and try again.");

        return command;
    }

    private static string GetSettingsPath() => Path.Combine(AppContext.BaseDirectory, "settings.ini");

    private static ToolbarSettings ReadSettings(string text)
    {
        Dictionary<string, string> toolbar = new(StringComparer.OrdinalIgnoreCase);
        SortedDictionary<int, string>? processes = null;
        Dictionary<string, PluginConfiguration> plugins = new(StringComparer.OrdinalIgnoreCase);
        HashSet<string> enabledKeys = new(StringComparer.OrdinalIgnoreCase);
        PluginConfiguration? sectionPlugin = null;
        string section = "";
        using StringReader reader = new(text);
        int lineNumber = 0;
        while (reader.ReadLine() is string rawLine)
        {
            lineNumber++;
            ReadOnlySpan<char> line = rawLine.AsSpan().Trim();
            if (line.IsEmpty || line[0] is ';' or '#')
                continue;
            if (line[0] == '[')
            {
                if (line[^1] != ']' || line[1..^1].Trim().IsEmpty)
                    throw new InvalidDataException($"Invalid INI section on line {lineNumber}.");
                section = line[1..^1].Trim().ToString();
                sectionPlugin = null;
                if (section.Equals("CapturedProcesses", StringComparison.OrdinalIgnoreCase))
                    processes ??= new SortedDictionary<int, string>();
                else if (section.StartsWith("Plugin.", StringComparison.OrdinalIgnoreCase))
                {
                    string id = section[7..];
                    if (!PluginConfiguration.IsIdentifier(id))
                        throw new InvalidDataException($"Invalid plugin identifier on line {lineNumber}.");
                    if (!plugins.TryGetValue(id, out sectionPlugin))
                    {
                        sectionPlugin = new PluginConfiguration();
                        plugins.Add(id, sectionPlugin);
                    }
                }
                continue;
            }

            int separator = line.IndexOf('=');
            if (separator <= 0)
                throw new InvalidDataException($"Invalid INI entry on line {lineNumber}; expected key=value.");
            bool isToolbar = section.Equals("Toolbar", StringComparison.OrdinalIgnoreCase);
            bool isPlugins = section.Equals("Plugins", StringComparison.OrdinalIgnoreCase);
            if (!isToolbar && !isPlugins && sectionPlugin is null
                && !section.Equals("CapturedProcesses", StringComparison.OrdinalIgnoreCase))
                continue;
            string key = line[..separator].Trim().ToString();
            string value = line[(separator + 1)..].Trim().ToString();
            if (isToolbar)
            {
                if (!toolbar.TryAdd(key, value))
                    throw new InvalidDataException($"Duplicate Toolbar key on line {lineNumber}: {key}.");
            }
            else if (isPlugins)
            {
                if (!PluginConfiguration.IsIdentifier(key) || !enabledKeys.Add(key))
                    throw new InvalidDataException($"Plugins needs unique valid identifiers (line {lineNumber}).");
                if (!bool.TryParse(value, out bool enabled))
                    throw new InvalidDataException($"Plugin enabled values must be true or false (line {lineNumber}).");
                if (!plugins.TryGetValue(key, out PluginConfiguration? configuration))
                {
                    configuration = new PluginConfiguration();
                    plugins.Add(key, configuration);
                }
                configuration.Enabled = enabled;
            }
            else if (sectionPlugin is not null)
            {
                if (!PluginConfiguration.IsIdentifier(key) || !sectionPlugin.Options.TryAdd(key, value))
                    throw new InvalidDataException($"Plugin options need unique valid keys (line {lineNumber}).");
            }
            else if (!int.TryParse(key, NumberStyles.None, CultureInfo.InvariantCulture, out int index)
                || !processes!.TryAdd(index, value))
            {
                throw new InvalidDataException($"CapturedProcesses needs unique nonnegative integer keys (line {lineNumber}).");
            }
        }

        ToolbarSettings settings = new() { Plugins = plugins };
        if (toolbar.TryGetValue("Edge", out string? edge))
        {
            if (!Enum.TryParse(edge, ignoreCase: true, out ToolbarEdge parsed)
                || !Enum.IsDefined(parsed)
                || !string.Equals(edge, parsed.ToString(), StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidDataException("Edge must be a supported toolbar location name.");
            }
            settings.Edge = parsed;
        }
        if (toolbar.TryGetValue("MonitorDeviceName", out string? monitor))
            settings.MonitorDeviceName = monitor;
        if (toolbar.TryGetValue("HideDelayMilliseconds", out string? delay))
        {
            if (!int.TryParse(delay, NumberStyles.None, CultureInfo.InvariantCulture, out int milliseconds))
                throw new InvalidDataException("HideDelayMilliseconds must be a whole number from 200 to 5000.");
            settings.HideDelayMilliseconds = milliseconds;
        }
        if (toolbar.TryGetValue("MaximizeOnActivate", out string? maximize))
        {
            if (!bool.TryParse(maximize, out bool enabled))
                throw new InvalidDataException("MaximizeOnActivate must be true or false.");
            settings.AlwaysMakeRemoteDesktopSessionFullscreen = enabled;
        }
        if (processes is not null)
        {
            settings.CapturedProcesses.Clear();
            settings.CapturedProcesses.AddRange(processes.Values);
        }
        return NormalizeSettings(settings);
    }

    private static string WriteSettings(ToolbarSettings settings)
    {
        StringBuilder text = new();
        text.AppendLine("[Toolbar]")
            .Append("Edge=").AppendLine(settings.Edge.ToString())
            .Append("MonitorDeviceName=").AppendLine(settings.MonitorDeviceName)
            .Append("HideDelayMilliseconds=").AppendLine(settings.HideDelayMilliseconds.ToString(CultureInfo.InvariantCulture))
            .Append("MaximizeOnActivate=").AppendLine(settings.AlwaysMakeRemoteDesktopSessionFullscreen ? "true" : "false")
            .AppendLine()
            .AppendLine("[CapturedProcesses]");
        for (int index = 0; index < settings.CapturedProcesses.Count; index++)
        {
            text.Append(index.ToString(CultureInfo.InvariantCulture)).Append('=')
                .AppendLine(settings.CapturedProcesses[index]);
        }
        if (settings.Plugins.Count != 0)
        {
            text.AppendLine().AppendLine("[Plugins]");
            foreach ((string id, PluginConfiguration configuration) in settings.Plugins)
                text.Append(id).Append('=').AppendLine(configuration.Enabled ? "true" : "false");
            foreach ((string id, PluginConfiguration configuration) in settings.Plugins)
            {
                if (configuration.Options.Count == 0)
                    continue;
                text.AppendLine().Append("[Plugin.").Append(id).AppendLine("]");
                foreach ((string key, string value) in configuration.Options)
                    text.Append(key).Append('=').AppendLine(value);
            }
        }
        return text.ToString();
    }

    private static ToolbarSettings NormalizeSettings(ToolbarSettings settings)
    {
        if (!Enum.IsDefined(settings.Edge))
        {
            throw new InvalidDataException("Edge must be a supported toolbar location.");
        }

        if (settings.MonitorDeviceName is null)
        {
            throw new InvalidDataException("MonitorDeviceName cannot be null. Use an empty string for Automatic.");
        }
        if (settings.MonitorDeviceName.AsSpan().IndexOfAny('\r', '\n', '\0') >= 0)
        {
            throw new InvalidDataException("MonitorDeviceName must be a single line without null characters.");
        }

        if (settings.HideDelayMilliseconds is < 200 or > 5000)
        {
            throw new InvalidDataException("HideDelayMilliseconds must be a whole number from 200 to 5000.");
        }

        if (settings.CapturedProcesses is null)
        {
            throw new InvalidDataException("CapturedProcesses cannot be null. Use an empty list to capture nothing.");
        }

        List<string> names = new(settings.CapturedProcesses.Count);
        HashSet<string> seen = new(StringComparer.OrdinalIgnoreCase);
        foreach (string? value in settings.CapturedProcesses)
        {
            string name = ToolbarSettings.NormalizeProcessName(value);
            if (name.Length == 0)
            {
                throw new InvalidDataException("CapturedProcesses contains an invalid or empty executable name. Wildcards are not supported.");
            }

            if (seen.Add(name))
            {
                names.Add(name);
            }
        }

        if (settings.Plugins is null)
            throw new InvalidDataException("Plugins cannot be null. Use an empty dictionary to disable all plugins.");
        Dictionary<string, PluginConfiguration> plugins = new(settings.Plugins.Count, StringComparer.OrdinalIgnoreCase);
        foreach ((string id, PluginConfiguration configuration) in settings.Plugins)
        {
            if (!PluginConfiguration.IsIdentifier(id) || configuration is null || configuration.Options is null)
                throw new InvalidDataException("Plugins must have valid identifiers and non-null configurations and options.");
            PluginConfiguration normalized = new() { Enabled = configuration.Enabled };
            if (!plugins.TryAdd(id, normalized))
                throw new InvalidDataException("Plugin identifiers must be unique, ignoring case.");
            foreach ((string key, string value) in configuration.Options)
            {
                if (!PluginConfiguration.IsIdentifier(key))
                    throw new InvalidDataException("Plugin option keys must be valid identifiers.");
                if (value is null || value.AsSpan().IndexOfAny("\r\n\0\u0085\u2028\u2029".AsSpan()) >= 0)
                    throw new InvalidDataException("Plugin option values must be non-null single lines without null characters.");
                if (!normalized.Options.TryAdd(key, value.Trim()))
                    throw new InvalidDataException("Plugin option keys must be unique, ignoring case.");
            }
        }

        return new ToolbarSettings
        {
            Edge = settings.Edge,
            MonitorDeviceName = settings.MonitorDeviceName.Trim(),
            CapturedProcesses = names,
            HideDelayMilliseconds = settings.HideDelayMilliseconds,
            AlwaysMakeRemoteDesktopSessionFullscreen = settings.AlwaysMakeRemoteDesktopSessionFullscreen,
            Plugins = plugins
        };
    }
}
