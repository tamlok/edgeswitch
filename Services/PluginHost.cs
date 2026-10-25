using System;
using System.Buffers;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
using Microsoft.Win32.SafeHandles;

namespace EdgeSwitch;

internal static class PluginCatalog
{
    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        MaxDepth = 16
    };

    internal static List<PluginDefinition> Discover()
    {
        List<PluginDefinition> plugins = new();
        string root = Path.Combine(AppContext.BaseDirectory, "plugins");
        try
        {
            if (!Directory.Exists(root))
                return plugins;
            foreach (string directory in Directory.GetDirectories(root))
            {
                string id = Path.GetFileName(directory);
                if (!PluginConfiguration.IsIdentifier(id))
                    continue;
                plugins.Add(Read(id, directory));
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SecurityException)
        {
            plugins.Add(new PluginDefinition("plugin-discovery", root, null, "Could not read the plugins folder. Check folder permissions."));
        }
        plugins.Sort(static (left, right) => StringComparer.OrdinalIgnoreCase.Compare(left.Id, right.Id));
        return plugins;
    }

    private static PluginDefinition Read(string id, string directory)
    {
        try
        {
            using FileStream stream = File.OpenRead(Path.Combine(directory, "plugin.json"));
            if (stream.Length > 32768)
                throw new InvalidDataException("plugin.json exceeds 32 KiB.");
            PluginManifest manifest = JsonSerializer.Deserialize<PluginManifest>(stream, JsonOptions)
                ?? throw new InvalidDataException("plugin.json must contain an object.");
            if (manifest.ProtocolVersion != 1)
                throw new InvalidDataException("Unsupported plugin protocol version (expected 1).");
            if (!IsSingleLine(manifest.Name, 64) || !IsSingleLine(manifest.Executable, 1024))
                throw new InvalidDataException("Plugin name or executable is missing or invalid.");
            if (manifest.Description is null || manifest.Description.Length > 1024 || manifest.Description.Contains('\0'))
                throw new InvalidDataException("Plugin description is invalid.");
            if (manifest.Arguments is null || manifest.Arguments.Length > 32)
                throw new InvalidDataException("Plugin arguments must be an array of at most 32 strings.");
            foreach (string argument in manifest.Arguments)
                if (argument is null || argument.Length > 4096 || argument.Contains('\0'))
                    throw new InvalidDataException("Invalid plugin argument.");
            if (manifest.RefreshSeconds is < 30 or > 86400 || manifest.TimeoutSeconds is < 1 or > 120
                || manifest.TimeoutSeconds > manifest.RefreshSeconds)
                throw new InvalidDataException("Refresh must be 30–86400 seconds; timeout 1–120 seconds and no longer than refresh.");
            if (manifest.Settings is null || manifest.Settings.Count > 32)
                throw new InvalidDataException("A plugin may declare at most 32 settings.");
            HashSet<string> keys = new(StringComparer.OrdinalIgnoreCase);
            foreach (PluginSettingDefinition field in manifest.Settings)
                if (field is null || !PluginConfiguration.IsIdentifier(field.Key) || !keys.Add(field.Key)
                    || !IsSingleLine(field.Label, 128) || field.DefaultValue is null
                    || field.DefaultValue.Length > 4096 || field.DefaultValue.AsSpan().IndexOfAny('\r', '\n', '\0') >= 0)
                    throw new InvalidDataException("Invalid or duplicate plugin setting.");
            return new PluginDefinition(id, directory, manifest, null);
        }
        catch (Exception exception) when (exception is IOException or JsonException or InvalidDataException
            or UnauthorizedAccessException or SecurityException or ArgumentException)
        {
            return new PluginDefinition(id, directory, null,
                exception is InvalidDataException ? exception.Message : "Could not read plugin.json. Check its JSON and folder permissions.");
        }
    }

    private static bool IsSingleLine(string value, int maximum) => !string.IsNullOrWhiteSpace(value)
        && value.Length <= maximum && value.AsSpan().IndexOfAny('\r', '\n', '\0') < 0;
}

internal sealed record PluginReading(string Text, string ToolTip);

internal sealed class PluginHost : IDisposable
{
    private readonly Dispatcher dispatcher;
    private readonly Action layoutChanged;
    private CancellationTokenSource? lifetime;
    private Task pending = Task.CompletedTask;
    private bool disposed;

    internal ObservableCollection<PluginCard> Cards { get; } = new();

    internal PluginHost(Dispatcher dispatcher, Action layoutChanged)
    {
        this.dispatcher = dispatcher;
        this.layoutChanged = layoutChanged;
    }

    internal void Reload(ToolbarSettings settings)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        Stop();
        Cards.Clear();
        lifetime = new CancellationTokenSource();
        CancellationToken cancellation = lifetime.Token;
        Dictionary<string, PluginDefinition> definitions = new(StringComparer.OrdinalIgnoreCase);
        foreach (PluginDefinition definition in PluginCatalog.Discover())
            definitions.TryAdd(definition.Id, definition);
        List<Task> tasks = new();
        foreach ((string id, PluginConfiguration configuration) in settings.Plugins)
        {
            if (!configuration.Enabled)
                continue;
            PluginDefinition definition = definitions.GetValueOrDefault(id)
                ?? new PluginDefinition(id, "", null, "Plugin is not installed. Restore its folder under plugins.");
            PluginCard card = new(definition.Name);
            Cards.Add(card);
            if (definition.Manifest is null)
            {
                card.Update("Unavailable", definition.Error ?? "Plugin could not be loaded.");
                continue;
            }
            Dictionary<string, string> options = new(StringComparer.OrdinalIgnoreCase);
            foreach (PluginSettingDefinition field in definition.Manifest.Settings)
                options[field.Key] = field.DefaultValue;
            foreach ((string key, string value) in configuration.Options)
                options[key] = value;
            tasks.Add(Task.Run(() => PollAsync(definition, options, card, cancellation)));
        }
        pending = Task.WhenAll(tasks);
        layoutChanged();
    }

    private async Task PollAsync(PluginDefinition definition, Dictionary<string, string> options,
        PluginCard card, CancellationToken cancellation)
    {
        try
        {
            while (true)
            {
                PluginReading reading = await RunAsync(definition, options, cancellation).ConfigureAwait(false);
                await dispatcher.InvokeAsync(() =>
                {
                    if (!cancellation.IsCancellationRequested && card.Update(reading.Text, reading.ToolTip))
                        layoutChanged();
                }, DispatcherPriority.Background, cancellation);
                await Task.Delay(TimeSpan.FromSeconds(definition.Manifest!.RefreshSeconds), cancellation).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
    }

    internal static async Task<PluginReading> RunAsync(PluginDefinition definition,
        Dictionary<string, string> options, CancellationToken cancellation)
    {
        PluginManifest manifest = definition.Manifest!;
        using CancellationTokenSource deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromSeconds(manifest.TimeoutSeconds));
        try
        {
            byte[] request = JsonSerializer.SerializeToUtf8Bytes(new { protocolVersion = 1, settings = options }, PluginCatalog.JsonOptions);
            if (request.Length > 16384)
                return new PluginReading("Unavailable", "Plugin settings exceed 16 KiB.");
            string executable = manifest.Executable;
            if (!Path.IsPathRooted(executable))
            {
                string local = Path.GetFullPath(Path.Combine(definition.Directory, executable));
                if (File.Exists(local) || executable.Contains(Path.DirectorySeparatorChar) || executable.Contains(Path.AltDirectorySeparatorChar))
                    executable = local;
            }
            ProcessStartInfo start = new(executable)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = definition.Directory,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            foreach (string argument in manifest.Arguments)
                start.ArgumentList.Add(argument);
            using PluginProcessJob job = new();
            using Process process = new() { StartInfo = start };
            cancellation.ThrowIfCancellationRequested();
            if (!process.Start())
                return new PluginReading("Unavailable", "Could not start the plugin executable.");
            try
            {
                job.Assign(process);
            }
            catch
            {
                if (!process.HasExited)
                    process.Kill(entireProcessTree: true);
                throw;
            }
            using CancellationTokenRegistration registration = deadline.Token.Register(job.Dispose);
            Task<string> stdout = ReadOutputAsync(process.StandardOutput.BaseStream, true, job, deadline.Token);
            Task<string> stderr = ReadOutputAsync(process.StandardError.BaseStream, false, job, deadline.Token);
            Task input = SendInputAsync(process.StandardInput.BaseStream, request, deadline.Token);
            await Task.WhenAll(stdout, stderr, input, process.WaitForExitAsync(deadline.Token)).ConfigureAwait(false);
            cancellation.ThrowIfCancellationRequested();
            if (process.ExitCode != 0)
                return new PluginReading("Unavailable", "Plugin exited unsuccessfully. Check its executable, dependencies and script execution policy.");
            using JsonDocument document = JsonDocument.Parse(await stdout.ConfigureAwait(false), new JsonDocumentOptions { MaxDepth = 8 });
            JsonElement root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("protocolVersion", out JsonElement version)
                || !version.TryGetInt32(out int protocol) || protocol != 1
                || !root.TryGetProperty("text", out JsonElement text) || text.ValueKind != JsonValueKind.String
                || !root.TryGetProperty("toolTip", out JsonElement tip) || tip.ValueKind != JsonValueKind.String)
                return new PluginReading("Unavailable", "Plugin returned an invalid protocol response.");
            string value = text.GetString()!;
            string tooltip = tip.GetString()!;
            if (string.IsNullOrWhiteSpace(value) || value.Length > 64 || value.AsSpan().IndexOfAny('\r', '\n', '\0') >= 0
                || tooltip.Length > 4096 || tooltip.Contains('\0'))
                return new PluginReading("Unavailable", "Plugin returned invalid or oversized display text.");
            return new PluginReading(value, tooltip);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        {
            return new PluginReading("Unavailable", "Plugin timed out. Its processes were stopped.");
        }
        catch (Exception exception) when (exception is IOException or Win32Exception or JsonException
            or InvalidDataException or UnauthorizedAccessException or SecurityException or ArgumentException or InvalidOperationException)
        {
            cancellation.ThrowIfCancellationRequested();
            return new PluginReading("Unavailable", deadline.IsCancellationRequested
                ? "Plugin timed out. Its processes were stopped."
                : "Plugin failed. Check its executable, dependencies and JSON output (16 KiB maximum).");
        }
    }

    private static async Task SendInputAsync(Stream stream, byte[] request, CancellationToken cancellation)
    {
        try
        {
            await stream.WriteAsync(request, cancellation).ConfigureAwait(false);
            await stream.FlushAsync(cancellation).ConfigureAwait(false);
        }
        finally
        {
            stream.Dispose();
        }
    }

    private static async Task<string> ReadOutputAsync(Stream stream, bool retain, PluginProcessJob job, CancellationToken cancellation)
    {
        byte[] buffer = ArrayPool<byte>.Shared.Rent(4096);
        using MemoryStream? output = retain ? new MemoryStream() : null;
        try
        {
            int length = 0;
            while (true)
            {
                int count = await stream.ReadAsync(buffer.AsMemory(0, 4096), cancellation).ConfigureAwait(false);
                if (count == 0)
                    break;
                length += count;
                if (length > 16384)
                    throw new InvalidDataException("Plugin output exceeds 16 KiB.");
                output?.Write(buffer, 0, count);
            }
            return output is null ? "" : new UTF8Encoding(false, true).GetString(output.GetBuffer(), 0, length);
        }
        catch
        {
            job.Dispose();
            throw;
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer);
        }
    }

    private void Stop()
    {
        CancellationTokenSource? previous = lifetime;
        lifetime = null;
        if (previous is null)
            return;
        previous.Cancel();
        _ = pending.ContinueWith(task =>
        {
            _ = task.Exception;
            previous.Dispose();
        }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    }

    public void Dispose()
    {
        if (disposed)
            return;
        disposed = true;
        Stop();
    }
}

// Closing this handle also stops descendants which keep stdout/stderr open after
// their parent exits. This is lifetime isolation, not a security sandbox.
internal sealed class PluginProcessJob : IDisposable
{
    private readonly SafeFileHandle handle;

    internal PluginProcessJob()
    {
        handle = CreateJobObjectW(0, null);
        if (handle.IsInvalid)
            throw new Win32Exception(Marshal.GetLastWin32Error());
        JobLimits limits = new() { Basic = new BasicLimits { LimitFlags = 0x2000 } }; // KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(handle, 9, ref limits, (uint)Marshal.SizeOf<JobLimits>()))
        {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error);
        }
    }

    internal void Assign(Process process)
    {
        if (!AssignProcessToJobObject(handle, process.Handle))
            throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    public void Dispose() => handle.Dispose();

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits
    {
        public long ProcessUserTime, JobUserTime;
        public uint LimitFlags;
        public nuint MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcessLimit;
        public nuint Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobLimits
    {
        public BasicLimits Basic;
        public IoCounters Io;
        public nuint ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateJobObjectW(nint attributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(SafeFileHandle job, int informationClass, ref JobLimits information, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(SafeFileHandle job, nint process);
}
