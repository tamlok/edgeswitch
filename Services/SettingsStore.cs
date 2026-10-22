using System;
using System.Collections.Generic;
using System.IO;
using System.Security;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace EdgeSwitch;

internal static class SettingsStore
{
    private const string StartupKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string StartupValueName = "EdgeSwitch";
    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter<ToolbarEdge>() }
    };

    public static ToolbarSettings Load(out string? warning)
    {
        warning = null;
        string path = "%LOCALAPPDATA%\\EdgeSwitch\\settings.json";
        try
        {
            path = GetSettingsPath();
            using JsonDocument document = JsonDocument.Parse(File.ReadAllText(path));
            return ReadSettings(document.RootElement);
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
            or InvalidDataException or UnauthorizedAccessException or SecurityException or JsonException or ArgumentException)
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

    public static void Save(ToolbarSettings settings, bool startWithWindows)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ToolbarSettings normalized = NormalizeSettings(settings);
        string json = JsonSerializer.Serialize(normalized, SerializerOptions);
        string path = GetSettingsPath();
        string directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        string temporaryPath = Path.Combine(directory, $"settings.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporaryPath, json);
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

    private static string GetSettingsPath()
    {
        string localApplicationData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localApplicationData))
        {
            throw new IOException("The Windows local application data folder is unavailable. Check your user profile.");
        }

        return Path.Combine(localApplicationData, "EdgeSwitch", "settings.json");
    }

    private static ToolbarSettings ReadSettings(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object)
        {
            throw new InvalidDataException("The settings JSON must contain an object.");
        }

        ToolbarSettings settings = new();
        if (root.TryGetProperty(nameof(ToolbarSettings.Edge), out JsonElement edge))
        {
            if (edge.ValueKind == JsonValueKind.String)
            {
                string? name = edge.GetString();
                if (!Enum.TryParse(name, ignoreCase: true, out ToolbarEdge parsed)
                    || !Enum.IsDefined(parsed)
                    || !string.Equals(name, parsed.ToString(), StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException("Edge must be a supported toolbar location.");
                }

                settings.Edge = parsed;
            }
            else if (edge.ValueKind == JsonValueKind.Number && edge.TryGetInt32(out int value)
                && Enum.IsDefined((ToolbarEdge)value))
            {
                settings.Edge = (ToolbarEdge)value;
            }
            else
            {
                throw new InvalidDataException("Edge must be a supported toolbar location.");
            }
        }

        if (root.TryGetProperty(nameof(ToolbarSettings.MonitorDeviceName), out JsonElement monitor))
        {
            if (monitor.ValueKind != JsonValueKind.String)
            {
                throw new InvalidDataException("MonitorDeviceName must be a display name or an empty string for Automatic.");
            }

            settings.MonitorDeviceName = monitor.GetString()!;
        }

        if (root.TryGetProperty(nameof(ToolbarSettings.CapturedProcesses), out JsonElement processes))
        {
            if (processes.ValueKind != JsonValueKind.Array)
            {
                throw new InvalidDataException("CapturedProcesses must be an array of executable names; an empty array captures nothing.");
            }

            List<string> names = new(processes.GetArrayLength());
            foreach (JsonElement process in processes.EnumerateArray())
            {
                if (process.ValueKind != JsonValueKind.String)
                {
                    throw new InvalidDataException("Every CapturedProcesses entry must be a nonempty executable name.");
                }

                names.Add(process.GetString()!);
            }

            settings.CapturedProcesses = names;
        }

        if (root.TryGetProperty(nameof(ToolbarSettings.HideDelayMilliseconds), out JsonElement delay))
        {
            if (delay.ValueKind != JsonValueKind.Number || !delay.TryGetInt32(out int milliseconds))
            {
                throw new InvalidDataException("HideDelayMilliseconds must be a whole number from 200 to 5000.");
            }

            settings.HideDelayMilliseconds = milliseconds;
        }

        if (root.TryGetProperty(nameof(ToolbarSettings.AlwaysMakeRemoteDesktopSessionFullscreen), out JsonElement fullscreen))
        {
            if (fullscreen.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            {
                throw new InvalidDataException("AlwaysMakeRemoteDesktopSessionFullscreen must be true or false.");
            }

            settings.AlwaysMakeRemoteDesktopSessionFullscreen = fullscreen.GetBoolean();
        }

        return NormalizeSettings(settings);
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

        if (settings.HideDelayMilliseconds is < 200 or > 5000)
        {
            throw new InvalidDataException("HideDelayMilliseconds must be a whole number from 200 to 5000.");
        }

        if (settings.CapturedProcesses is null)
        {
            throw new InvalidDataException("CapturedProcesses cannot be null. Use an empty array to capture nothing.");
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

        return new ToolbarSettings
        {
            Edge = settings.Edge,
            MonitorDeviceName = settings.MonitorDeviceName.Trim(),
            CapturedProcesses = names,
            HideDelayMilliseconds = settings.HideDelayMilliseconds,
            AlwaysMakeRemoteDesktopSessionFullscreen = settings.AlwaysMakeRemoteDesktopSessionFullscreen
        };
    }
}
