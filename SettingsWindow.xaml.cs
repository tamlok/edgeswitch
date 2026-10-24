using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using System.Text.Json;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Input;
using Microsoft.Win32;

namespace EdgeSwitch;

public partial class SettingsWindow : Window
{
    private readonly ToolbarSettings workingCopy;
    private readonly ObservableCollection<ProcessChoice> processChoices = new();
    private readonly Dictionary<string, ProcessChoice> choicesByName = new(StringComparer.OrdinalIgnoreCase);

    internal ToolbarSettings? SavedSettings { get; private set; }

    internal SettingsWindow(ToolbarSettings current)
    {
        ArgumentNullException.ThrowIfNull(current);
        workingCopy = new ToolbarSettings
        {
            Edge = current.Edge,
            MonitorDeviceName = current.MonitorDeviceName,
            CapturedProcesses = new List<string>(current.CapturedProcesses),
            HideDelayMilliseconds = current.HideDelayMilliseconds,
            AlwaysMakeRemoteDesktopSessionFullscreen = current.AlwaysMakeRemoteDesktopSessionFullscreen
        };

        InitializeComponent();
        Rect workArea = SystemParameters.WorkArea;
        if (workArea.Width > 0 && workArea.Height > 0)
        {
            MinWidth = Math.Min(MinWidth, workArea.Width);
            MinHeight = Math.Min(MinHeight, workArea.Height);
            Width = Math.Min(Width, workArea.Width);
            Height = Math.Min(Height, workArea.Height);
        }

        CaptureList.ItemsSource = processChoices;
        EdgePicker.ItemsSource = new EdgeChoice[]
        {
            new(ToolbarEdge.Left, "Left"),
            new(ToolbarEdge.LeftTop, "Left-top"),
            new(ToolbarEdge.LeftBottom, "Left-bottom"),
            new(ToolbarEdge.Top, "Top"),
            new(ToolbarEdge.TopLeft, "Top-left"),
            new(ToolbarEdge.TopRight, "Top-right"),
            new(ToolbarEdge.Right, "Right"),
            new(ToolbarEdge.RightTop, "Right-top"),
            new(ToolbarEdge.RightBottom, "Right-bottom"),
            new(ToolbarEdge.Bottom, "Bottom"),
            new(ToolbarEdge.BottomLeft, "Bottom-left"),
            new(ToolbarEdge.BottomRight, "Bottom-right")
        };
        EdgePicker.SelectedValue = workingCopy.Edge;
        HideDelayInput.Text = workingCopy.HideDelayMilliseconds.ToString(CultureInfo.CurrentCulture);
        AlwaysMakeRemoteDesktopSessionFullscreenCheckBox.IsChecked = workingCopy.AlwaysMakeRemoteDesktopSessionFullscreen;
        PopulateProcesses();
        PopulateMonitors();
        try
        {
            StartWithWindowsCheckBox.IsChecked = SettingsStore.IsStartupEnabled();
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException or SecurityException)
        {
            StartWithWindowsCheckBox.IsEnabled = false;
            SaveButton.IsEnabled = false;
            ShowError($"Could not read the Windows startup preference. Settings cannot be saved until access is restored. {exception.Message}");
        }
    }

    private void PopulateProcesses()
    {
        HashSet<string> selected = new(
            ToolbarSettings.NormalizeProcessNames(workingCopy.CapturedProcesses),
            StringComparer.OrdinalIgnoreCase);
        Dictionary<string, int> windowCounts = new(StringComparer.OrdinalIgnoreCase);
        foreach (string name in selected)
        {
            windowCounts.TryAdd(name, 0);
        }

        // Keep both Remote Desktop clients available even when they are not running.
        windowCounts.TryAdd("mstsc", 0);
        windowCounts.TryAdd("msrdc", 0);
        try
        {
            foreach (WindowEntry window in new WindowCatalog().GetWindows(null))
            {
                string name = ToolbarSettings.NormalizeProcessName(window.ProcessName);
                if (name.Length == 0)
                {
                    continue;
                }

                windowCounts.TryGetValue(name, out int count);
                windowCounts[name] = count + 1;
            }
        }
        catch (Win32Exception exception)
        {
            ShowError($"Could not list open windows. You can still add executable names manually. {exception.Message}");
        }

        List<string> names = new(windowCounts.Keys);
        names.Sort(StringComparer.OrdinalIgnoreCase);
        foreach (string name in names)
        {
            ProcessChoice choice = new(name, windowCounts[name], selected.Contains(name));
            processChoices.Add(choice);
            choicesByName.Add(name, choice);
        }
    }

    private void PopulateMonitors()
    {
        List<MonitorChoice> choices = new() { new("", "Automatic · outside edges") };
        MonitorChoice selected = choices[0];
        MonitorChoice? primary = null;
        List<DisplayMonitor> monitors;
        try
        {
            monitors = NativeMethods.GetMonitors();
        }
        catch (Win32Exception exception)
        {
            MonitorWarning.Text = $"Could not identify connected displays. Automatic placement is selected. {exception.Message}";
            MonitorWarning.Visibility = Visibility.Visible;
            MonitorPicker.ItemsSource = choices;
            MonitorPicker.SelectedItem = selected;
            return;
        }

        monitors.Sort(static (left, right) =>
        {
            int primaryOrder = right.IsPrimary.CompareTo(left.IsPrimary);
            return primaryOrder != 0
                ? primaryOrder
                : StringComparer.OrdinalIgnoreCase.Compare(left.DeviceName, right.DeviceName);
        });

        bool foundSavedMonitor = string.IsNullOrEmpty(workingCopy.MonitorDeviceName);
        foreach (DisplayMonitor monitor in monitors)
        {
            string friendlyName = monitor.DeviceName.StartsWith(@"\\.\", StringComparison.Ordinal)
                ? monitor.DeviceName[4..]
                : monitor.DeviceName;
            string displayName = $"{friendlyName} · {monitor.Bounds.Width} × {monitor.Bounds.Height}"
                + (monitor.IsPrimary ? " · primary" : "");
            MonitorChoice choice = new(monitor.DeviceName, displayName);
            choices.Add(choice);
            primary ??= choice;
            if (monitor.IsPrimary)
            {
                primary = choice;
            }

            if (string.Equals(monitor.DeviceName, workingCopy.MonitorDeviceName, StringComparison.OrdinalIgnoreCase))
            {
                selected = choice;
                foundSavedMonitor = true;
            }
        }

        if (!foundSavedMonitor)
        {
            selected = primary ?? choices[0];
            MonitorWarning.Text = primary is not null
                ? $"The saved display ({workingCopy.MonitorDeviceName}) is not connected. The primary display is selected as a fallback; you can choose another display or Automatic."
                : $"The saved display ({workingCopy.MonitorDeviceName}) is unavailable. No displays could be identified, so Automatic placement is selected.";
            MonitorWarning.Visibility = Visibility.Visible;
        }

        MonitorPicker.ItemsSource = choices;
        MonitorPicker.SelectedItem = selected;
    }

    private void AddProcessButton_Click(object sender, RoutedEventArgs e)
    {
        AddProcess(ProcessNameInput.Text);
    }

    private void ProcessNameInput_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            e.Handled = true;
            AddProcess(ProcessNameInput.Text);
        }
    }

    private void AddProcess(string rawName)
    {
        string name = ToolbarSettings.NormalizeProcessName(rawName);
        if (name.Length == 0)
        {
            ShowError("Enter a valid executable name, such as mstsc.exe, or choose an .exe file. Wildcards are not supported.");
            ProcessNameInput.Focus();
            ProcessNameInput.SelectAll();
            return;
        }

        if (choicesByName.TryGetValue(name, out ProcessChoice? existing))
        {
            existing.IsCaptured = true;
        }
        else
        {
            ProcessChoice choice = new(name, 0, true);
            int index = 0;
            while (index < processChoices.Count
                && StringComparer.OrdinalIgnoreCase.Compare(processChoices[index].ProcessName, name) < 0)
            {
                index++;
            }

            processChoices.Insert(index, choice);
            choicesByName.Add(name, choice);
        }

        ClearError();
        ProcessNameInput.Clear();
        ProcessNameInput.Focus();
    }

    private void BrowseButton_Click(object sender, RoutedEventArgs e)
    {
        OpenFileDialog picker = new()
        {
            Title = "Choose an executable to capture",
            Filter = "Windows executables (*.exe)|*.exe",
            DefaultExt = ".exe",
            CheckFileExists = true,
            CheckPathExists = true,
            Multiselect = false,
            ValidateNames = true
        };

        try
        {
            if (picker.ShowDialog(this) == true)
            {
                if (!string.Equals(Path.GetExtension(picker.FileName), ".exe", StringComparison.OrdinalIgnoreCase))
                {
                    ShowError("Choose a Windows executable with an .exe extension.");
                    return;
                }

                AddProcess(picker.FileName);
            }
        }
        catch (Exception exception) when (exception is Win32Exception
            or IOException or UnauthorizedAccessException or SecurityException or COMException)
        {
            ShowError($"Could not browse for an executable. You can type its name or path instead. {exception.Message}");
        }
    }

    private void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        if (EdgePicker.SelectedValue is not ToolbarEdge edge || !Enum.IsDefined(edge))
        {
            ShowError("Choose a toolbar location from the list.");
            EdgePicker.Focus();
            return;
        }

        if (MonitorPicker.SelectedItem is not MonitorChoice monitor)
        {
            ShowError("Choose a display, or Automatic for outside edges.");
            MonitorPicker.Focus();
            return;
        }

        if (!int.TryParse(HideDelayInput.Text, NumberStyles.Integer, CultureInfo.CurrentCulture, out int delay)
            || delay is < 200 or > 5000)
        {
            ShowError("Enter a whole-number hide delay from 200 to 5,000 milliseconds.");
            HideDelayInput.Focus();
            HideDelayInput.SelectAll();
            return;
        }

        workingCopy.Edge = edge;
        workingCopy.MonitorDeviceName = monitor.DeviceName;
        workingCopy.HideDelayMilliseconds = delay;
        workingCopy.AlwaysMakeRemoteDesktopSessionFullscreen = AlwaysMakeRemoteDesktopSessionFullscreenCheckBox.IsChecked == true;
        workingCopy.CapturedProcesses.Clear();
        foreach (ProcessChoice choice in processChoices)
        {
            if (choice.IsCaptured)
            {
                workingCopy.CapturedProcesses.Add(choice.ProcessName);
            }
        }

        try
        {
            SettingsStore.Save(workingCopy, StartWithWindowsCheckBox.IsChecked == true);
        }
        catch (Exception exception) when (exception is IOException
            or UnauthorizedAccessException or SecurityException or ArgumentException
            or InvalidDataException or JsonException or NotSupportedException)
        {
            ShowError("Could not save settings. Check that %LOCALAPPDATA%\\EdgeSwitch is writable "
                + $"and Windows startup preferences are accessible. {exception.Message}");
            return;
        }

        SavedSettings = workingCopy;
        DialogResult = true;
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    private void ShowError(string message)
    {
        ErrorMessage.Text = message;
        ErrorMessage.Visibility = Visibility.Visible;
        AutomationProperties.SetName(ErrorMessage, message);
        if (AutomationPeer.ListenerExists(AutomationEvents.LiveRegionChanged))
        {
            AutomationPeer? peer = UIElementAutomationPeer.FromElement(ErrorMessage)
                ?? UIElementAutomationPeer.CreatePeerForElement(ErrorMessage);
            peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        }
    }

    private void ClearError()
    {
        ErrorMessage.Text = "";
        ErrorMessage.Visibility = Visibility.Collapsed;
    }

    internal sealed class ProcessChoice : INotifyPropertyChanged
    {
        private bool isCaptured;

        internal ProcessChoice(string processName, int windowCount, bool captured)
        {
            ProcessName = processName;
            WindowCountText = windowCount switch
            {
                0 => "No capturable windows",
                1 => "1 open window",
                _ => $"{windowCount} open windows"
            };
            isCaptured = captured;
        }

        public string ProcessName { get; }
        public string DisplayName => ProcessName + ".exe";
        public string WindowCountText { get; }

        public bool IsCaptured
        {
            get => isCaptured;
            set
            {
                if (isCaptured == value)
                {
                    return;
                }

                isCaptured = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsCaptured)));
            }
        }

        public event PropertyChangedEventHandler? PropertyChanged;
    }

    internal sealed record EdgeChoice(ToolbarEdge Edge, string DisplayName);

    internal sealed record MonitorChoice(string DeviceName, string DisplayName);
}
