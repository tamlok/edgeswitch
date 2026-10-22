using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace EdgeSwitch;

public partial class MainWindow : Window
{
    public static readonly DependencyProperty CardOrientationProperty = DependencyProperty.Register(
        nameof(CardOrientation), typeof(Orientation), typeof(MainWindow), new PropertyMetadata(Orientation.Vertical));

    public Orientation CardOrientation
    {
        get => (Orientation)GetValue(CardOrientationProperty);
        private set => SetValue(CardOrientationProperty, value);
    }

    private readonly WindowCatalog catalog = new();
    private readonly ObservableCollection<WindowCard> cards = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private ToolbarSettings settings;
    private List<DisplayMonitor> monitors = new();
    private DisplayMonitor? currentMonitor;
    private nint handle;
    private bool revealed;
    private bool settingsOpen;
    private bool switching;
    private bool edgeArmed = true;
    private string? dwellMonitor;
    private long dwellStarted;
    private long lastEngaged;
    private long keepVisibleUntil;
    private long statusMessageUntil;
    private long nextCatalogRefresh;
    private long nextMonitorRefresh;
    private nint lastActiveWindow;
    private bool layoutDirty = true;
    private Size toolbarSize;

    internal MainWindow(ToolbarSettings settings)
    {
        this.settings = settings;
        InitializeComponent();
        WindowItems.ItemsSource = cards;
        SourceInitialized += (_, _) =>
        {
            handle = new WindowInteropHelper(this).Handle;
            NativeMethods.ConfigureToolbar(handle);
        };
        timer.Tick += OnTick;
        Closing += (_, e) =>
        {
            // Alt+F4 hides a tray application; explicit Application.Shutdown
            // still closes its windows regardless of cancellation.
            e.Cancel = true;
            Conceal();
        };
        Closed += (_, _) => timer.Stop();
    }

    internal void Start()
    {
        // Initialize WPF's visual tree once. Subsequent hover reveals use only native
        // nonactivating show/position calls; the HWND remains activatable by a click.
        new WindowInteropHelper(this).EnsureHandle();
        RefreshMonitors();
        RefreshWindows();
        Show();
        ShowFromTray();
        timer.Start();
    }

    internal void ShowFromTray()
    {
        RefreshMonitors();
        RefreshWindows();
        NativeMethods.GetCursorPos(out NativePoint pointer);
        DisplayMonitor? monitor = EligibleMonitors().FirstOrDefault(m => m.Bounds.Contains(pointer.X, pointer.Y));
        if (monitor is null || monitor.Value.Bounds.Width == 0)
            monitor = EligibleMonitors().FirstOrDefault();
        if (monitor is not null && monitor.Value.Bounds.Width > 0)
            Reveal(monitor.Value);
        keepVisibleUntil = Environment.TickCount64 + 4000;
    }

    internal void OpenSettings()
    {
        if (settingsOpen)
            return;
        settingsOpen = true;
        ShowFromTray();
        try
        {
            var dialog = new SettingsWindow(settings) { Owner = this, WindowStartupLocation = WindowStartupLocation.CenterOwner };
            // The owner is intentionally narrow and at an edge; center Settings in the
            // selected display's work area instead of partly offscreen over the owner.
            dialog.WindowStartupLocation = WindowStartupLocation.CenterScreen;
            if (dialog.ShowDialog() == true && dialog.SavedSettings is not null)
            {
                settings = dialog.SavedSettings;
                currentMonitor = null;
                RefreshMonitors();
                RefreshWindows();
                ShowFromTray();
            }
        }
        finally
        {
            settingsOpen = false;
            lastEngaged = Environment.TickCount64;
        }
    }

    private void OnTick(object? sender, EventArgs e)
    {
        long now = Environment.TickCount64;
        if (now >= nextMonitorRefresh)
        {
            RefreshMonitors();
            nextMonitorRefresh = now + 2000;
        }
        if (revealed && now >= nextCatalogRefresh)
        {
            RefreshWindows();
            nextCatalogRefresh = now + 1000;
        }
        if (!NativeMethods.GetCursorPos(out NativePoint pointer))
            return;
        UpdatePointer(pointer, now);
    }

    private void UpdatePointer(NativePoint pointer, long now)
    {
        DisplayMonitor? edge = FindEdge(pointer, now);
        if (edge is null)
        {
            edgeArmed = true;
            dwellMonitor = null;
        }
        if (!revealed)
        {
            if (switching || !edgeArmed || edge is null)
                return;
            if (dwellMonitor != edge.Value.DeviceName)
            {
                dwellMonitor = edge.Value.DeviceName;
                dwellStarted = now;
            }
            else if (now - dwellStarted >= 150)
            {
                Reveal(edge.Value);
            }
            return;
        }

        if (!settingsOpen && edge is DisplayMonitor hoveredDisplay &&
            hoveredDisplay.DeviceName != currentMonitor?.DeviceName)
            Reveal(hoveredDisplay);

        nint foreground = NativeMethods.GetForegroundWindow();
        if (foreground != handle && !settingsOpen)
            lastActiveWindow = foreground;
        foreach (WindowCard card in cards)
            card.IsActive = card.Entry.Handle == lastActiveWindow;

        bool pointerInside = NativeMethods.GetWindowRect(handle, out NativeRect bounds) && bounds.Contains(pointer.X, pointer.Y);
        if (pointerInside || edge is not null || foreground == handle || settingsOpen || switching)
            lastEngaged = now;
        else if (now >= keepVisibleUntil && now - lastEngaged >= settings.HideDelayMilliseconds)
        {
            Conceal();
            return;
        }

        // Fullscreen clients can reorder the topmost band when activated. Only compete
        // while our transient toolbar is visible, and never take their keyboard focus.
        if (!settingsOpen && currentMonitor is DisplayMonitor display)
            Place(display);
    }

    private void RefreshMonitors()
    {
        try
        {
            monitors = NativeMethods.GetMonitors();
        }
        catch (Win32Exception exception)
        {
            // Retain the last good snapshot; the normal timer will query again.
            ReportError($"Could not refresh displays: {exception.Message}");
            return;
        }
        if (currentMonitor is DisplayMonitor current)
        {
            DisplayMonitor replacement = monitors.FirstOrDefault(m => m.DeviceName == current.DeviceName);
            currentMonitor = replacement.Bounds.Width > 0 ? replacement : monitors.FirstOrDefault(m => m.IsPrimary);
        }
    }

    private IEnumerable<DisplayMonitor> EligibleMonitors()
    {
        if (string.IsNullOrEmpty(settings.MonitorDeviceName))
            return monitors;
        DisplayMonitor selected = monitors.FirstOrDefault(m => m.DeviceName == settings.MonitorDeviceName);
        if (selected.Bounds.Width == 0)
            selected = monitors.FirstOrDefault(m => m.IsPrimary);
        return selected.Bounds.Width > 0 ? new[] { selected } : monitors;
    }

    private DisplayMonitor? FindEdge(NativePoint pointer, long now)
    {
        const int slop = 2;
        ToolbarEdge triggerEdge = settings.TriggerEdge;
        foreach (DisplayMonitor monitor in EligibleMonitors())
        {
            NativeRect b = monitor.Bounds;
            if (!b.Contains(pointer.X, pointer.Y))
                continue;
            bool hit = triggerEdge switch
            {
                ToolbarEdge.Left => pointer.X < b.Left + slop,
                ToolbarEdge.Top => pointer.Y < b.Top + slop,
                ToolbarEdge.Right => pointer.X >= b.Right - slop,
                ToolbarEdge.Bottom => pointer.Y >= b.Bottom - slop,
                _ => false
            };
            if (!hit)
                continue;
            int outsideX = triggerEdge switch { ToolbarEdge.Left => b.Left - 1, ToolbarEdge.Right => b.Right, _ => pointer.X };
            int outsideY = triggerEdge switch { ToolbarEdge.Top => b.Top - 1, ToolbarEdge.Bottom => b.Bottom, _ => pointer.Y };
            // On Automatic, ignore shared seams but retain exposed segments of uneven
            // display layouts. An explicit monitor deliberately allows its shared edge.
            if (string.IsNullOrEmpty(settings.MonitorDeviceName) && monitors.Any(m => m.Bounds.Contains(outsideX, outsideY)))
                continue;
            // Refresh before testing the span: windows may have opened or closed
            // while hidden, even when the pointer is outside the previous span.
            if (!revealed && now >= nextCatalogRefresh)
            {
                RefreshWindows();
                nextCatalogRefresh = now + 1000;
            }
            NativeRect toolbarBounds = GetToolbarBounds(monitor);
            bool withinSpan = triggerEdge is ToolbarEdge.Left or ToolbarEdge.Right
                ? pointer.Y >= toolbarBounds.Top && pointer.Y < toolbarBounds.Bottom
                : pointer.X >= toolbarBounds.Left && pointer.X < toolbarBounds.Right;
            if (withinSpan)
                return monitor;
        }
        return null;
    }

    private void Reveal(DisplayMonitor monitor)
    {
        currentMonitor = monitor;
        revealed = true;
        dwellMonitor = null;
        lastEngaged = Environment.TickCount64;
        lastActiveWindow = NativeMethods.GetForegroundWindow();
        Place(monitor);
    }

    private NativeRect GetToolbarBounds(DisplayMonitor monitor)
    {
        bool vertical = settings.TriggerEdge is ToolbarEdge.Left or ToolbarEdge.Right;
        Orientation orientation = vertical ? Orientation.Vertical : Orientation.Horizontal;
        if (CardOrientation != orientation)
        {
            CardOrientation = orientation;
            DockPanel.SetDock(AppButton, vertical ? Dock.Top : Dock.Left);
            DockPanel.SetDock(EntrySeparator, vertical ? Dock.Top : Dock.Left);
            EntrySeparator.Width = vertical ? double.NaN : 1;
            EntrySeparator.Height = vertical ? 1 : double.NaN;
            EntrySeparator.Margin = vertical ? new Thickness(2, 4, 2, 4) : new Thickness(4, 2, 4, 2);
            WindowScroller.VerticalScrollBarVisibility = vertical ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled;
            WindowScroller.HorizontalScrollBarVisibility = vertical ? ScrollBarVisibility.Disabled : ScrollBarVisibility.Auto;
            layoutDirty = true;
        }
        if (layoutDirty)
        {
            // Apply pending item/visibility changes before caching the natural size.
            ToolbarChrome.UpdateLayout();
            ToolbarChrome.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            toolbarSize = ToolbarChrome.DesiredSize;
            layoutDirty = false;
        }
        double scale = monitor.Scale > 0 ? monitor.Scale : 1;
        NativeRect b = monitor.Bounds;
        double maxWidth = Math.Min(vertical ? double.PositiveInfinity : 1040, b.Width / scale);
        double maxHeight = Math.Min(vertical ? 680 : double.PositiveInfinity, b.Height / scale);
        double desiredWidth = toolbarSize.Width;
        double desiredHeight = toolbarSize.Height;
        if (vertical && desiredHeight > maxHeight)
            desiredWidth += SystemParameters.VerticalScrollBarWidth;
        else if (!vertical && desiredWidth > maxWidth)
            desiredHeight += SystemParameters.HorizontalScrollBarHeight;
        desiredWidth = Math.Min(maxWidth, desiredWidth);
        desiredHeight = Math.Min(maxHeight, desiredHeight);
        // Round outward: a fractional-DIP shortage would create an unnecessary scrollbar.
        int width = Math.Min(b.Width, (int)Math.Ceiling(desiredWidth * scale));
        int height = Math.Min(b.Height, (int)Math.Ceiling(desiredHeight * scale));
        int x = settings.Edge switch
        {
            ToolbarEdge.Left or ToolbarEdge.LeftTop or ToolbarEdge.LeftBottom
                or ToolbarEdge.TopLeft or ToolbarEdge.BottomLeft => b.Left,
            ToolbarEdge.Right or ToolbarEdge.RightTop or ToolbarEdge.RightBottom
                or ToolbarEdge.TopRight or ToolbarEdge.BottomRight => b.Right - width,
            _ => b.Left + (b.Width - width) / 2
        };
        int y = settings.Edge switch
        {
            ToolbarEdge.Top or ToolbarEdge.TopLeft or ToolbarEdge.TopRight
                or ToolbarEdge.LeftTop or ToolbarEdge.RightTop => b.Top,
            ToolbarEdge.Bottom or ToolbarEdge.BottomLeft or ToolbarEdge.BottomRight
                or ToolbarEdge.LeftBottom or ToolbarEdge.RightBottom => b.Bottom - height,
            _ => b.Top + (b.Height - height) / 2
        };
        return new NativeRect { Left = x, Top = y, Right = x + width, Bottom = y + height };
    }

    private void Place(DisplayMonitor monitor)
    {
        NativeRect bounds = GetToolbarBounds(monitor);
        try
        {
            NativeMethods.MoveTopmost(handle, bounds.Left, bounds.Top, bounds.Width, bounds.Height);
        }
        catch (Win32Exception exception)
        {
            ReportError($"Could not show the toolbar: {exception.Message}");
        }
    }

    private void Conceal()
    {
        if (settingsOpen)
            return;
        NativeMethods.HideWindow(handle);
        revealed = false;
        edgeArmed = false;
        dwellMonitor = null;
        keepVisibleUntil = 0;
    }

    private void RefreshWindows()
    {
        List<WindowEntry> windows;
        try
        {
            windows = catalog.GetWindows(settings.CapturedProcesses);
        }
        catch (Win32Exception exception)
        {
            ReportError($"Window list may be out of date: {exception.Message}");
            return;
        }
        bool changed = false;
        var liveHandles = windows.Select(w => w.Handle).ToHashSet();
        for (int i = cards.Count - 1; i >= 0; i--)
            if (!liveHandles.Contains(cards[i].Entry.Handle))
            {
                cards.RemoveAt(i);
                changed = true;
            }
        for (int index = 0; index < windows.Count; index++)
        {
            WindowEntry entry = windows[index];
            WindowCard? existing = cards.FirstOrDefault(c => c.Entry.Handle == entry.Handle);
            if (existing is null)
            {
                cards.Insert(index, new WindowCard(entry));
                changed = true;
            }
            else
            {
                changed |= existing.Update(entry);
                int oldIndex = cards.IndexOf(existing);
                if (oldIndex != index)
                {
                    cards.Move(oldIndex, index);
                    changed = true;
                }
            }
        }
        layoutDirty |= changed;
        EntrySeparator.Visibility = windows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        WindowScroller.Visibility = windows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        AppButton.ToolTip = windows.Count > 0
            ? "Show host desktop (right-click for Settings)"
            : "Show host desktop (right-click for Settings)\nNo matching windows.";
        bool missingMonitor = !string.IsNullOrEmpty(settings.MonitorDeviceName) && !monitors.Any(m => m.DeviceName == settings.MonitorDeviceName);
        if (Environment.TickCount64 >= statusMessageUntil)
            SetStatus(missingMonitor ? "Saved display disconnected; using the primary display." : "");
    }

    private void SetStatus(string message)
    {
        if (StatusText.Text == message)
            return;
        StatusText.Text = message;
        StatusText.Visibility = message.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        layoutDirty = true;
    }

    private void ReportError(string message)
    {
        SetStatus(message);
        statusMessageUntil = Environment.TickCount64 + 4000;
        keepVisibleUntil = statusMessageUntil;
    }

    private async void OnWindowClick(object sender, RoutedEventArgs e)
    {
        if (switching || sender is not Button { Tag: WindowCard card })
            return;
        switching = true;
        try
        {
            WindowEntry entry = card.Entry;
            bool accepted = catalog.TryActivate(entry);
            if (!accepted || NativeMethods.IsIconic(entry.Handle))
                await Task.Delay(150);
            if (NativeMethods.GetForegroundWindow() == entry.Handle && !NativeMethods.IsIconic(entry.Handle))
            {
                if (settings.AlwaysMakeRemoteDesktopSessionFullscreen && entry.IsRemoteDesktop &&
                    !await catalog.TryMaximizeRemoteDesktopSessionAsync(entry))
                {
                    ReportError("Could not maximize this session. It may have closed, or Windows may have blocked the request.");
                    return;
                }

                Conceal();
            }
            else
            {
                RefreshWindows();
                ReportError("Could not activate this window. It may have closed, or Windows may have blocked focus.");
            }
        }
        finally
        {
            switching = false;
        }
    }

    private void OnHostDesktopClick(object sender, RoutedEventArgs e)
    {
        if (switching || settingsOpen)
            return;
        switching = true;
        try
        {
            // Stay out of the shell's minimize batch so hover can reveal us again.
            Conceal();
            NativeMethods.ShowHostDesktop();
        }
        catch (Exception exception) when (exception is COMException or TargetInvocationException or InvalidOperationException)
        {
            ShowFromTray();
            ReportError($"Could not show the host desktop: {exception.GetBaseException().Message}");
        }
        finally
        {
            switching = false;
        }
    }

    private void OnSettingsRightClick(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (!switching)
            OpenSettings();
    }
    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape)
        {
            Conceal();
            e.Handled = true;
        }
    }

    private sealed class WindowCard : INotifyPropertyChanged
    {
        private static readonly ImageSource DefaultIcon = CreateIconSource(System.Drawing.SystemIcons.Application.Handle);
        private bool isActive;
        public WindowEntry Entry { get; private set; }
        public string Title => Entry.Title;
        public bool IsRemoteDesktop => Entry.IsRemoteDesktop;
        public string SessionName => Entry.SessionName;
        public string ToolTip => $"{Title}\n{Entry.Subtitle}";
        public ImageSource Icon { get; private set; }
        public bool IsActive
        {
            get => isActive;
            set
            {
                if (isActive == value) return;
                isActive = value;
                PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsActive)));
            }
        }
        public event PropertyChangedEventHandler? PropertyChanged;
        public WindowCard(WindowEntry entry)
        {
            Entry = entry;
            Icon = LoadIcon(entry.Handle);
        }

        public bool Update(WindowEntry entry)
        {
            if (Entry == entry) return false;
            bool identityChanged = Entry.Handle != entry.Handle || Entry.ProcessId != entry.ProcessId
                || !string.Equals(Entry.ProcessName, entry.ProcessName, StringComparison.OrdinalIgnoreCase);
            Entry = entry;
            if (identityChanged)
                Icon = LoadIcon(entry.Handle);
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
            return true;
        }

        private static ImageSource CreateIconSource(nint icon)
        {
            BitmapSource image = Imaging.CreateBitmapSourceFromHIcon(icon, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            image.Freeze();
            return image;
        }

        private static ImageSource LoadIcon(nint hwnd)
        {
            nint icon = NativeMethods.CopyWindowIcon(hwnd);
            if (icon == nint.Zero)
                return DefaultIcon;
            try
            {
                return CreateIconSource(icon);
            }
            catch (Exception exception) when (exception is ArgumentException or Win32Exception)
            {
                return DefaultIcon;
            }
            finally
            {
                NativeMethods.DestroyIcon(icon);
            }
        }
    }
}
