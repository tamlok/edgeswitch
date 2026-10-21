using System;
using System.Drawing;
using System.IO;
using System.Threading;
using System.Windows;
using Forms = System.Windows.Forms;

namespace EdgeSwitch;

internal static class Program
{
    [STAThread]
    public static void Main()
    {
        // Set awareness before WPF or the tray creates any native windows.
        Forms.Application.SetHighDpiMode(Forms.HighDpiMode.PerMonitorV2);
        var application = new App();
        application.InitializeComponent();
        application.Run();
    }
}

public partial class App : Application
{
    private Mutex? instance;
    private Forms.NotifyIcon? tray;
    private Icon? trayIcon;
    private Stream? trayIconStream;
    private bool ownsMutex;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        instance = new Mutex(true, @"Local\EdgeSwitch.Toolbar", out ownsMutex);
        if (!ownsMutex)
        {
            MessageBox.Show("EdgeSwitch is already running. Use its notification-area icon to show the toolbar or open Settings.",
                "EdgeSwitch", MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        ToolbarSettings settings = SettingsStore.Load(out string? warning);
        var toolbar = new MainWindow(settings);
        MainWindow = toolbar;
        trayIconStream = GetResourceStream(new Uri("pack://application:,,,/Assets/EdgeSwitch.ico"))?.Stream
            ?? throw new InvalidOperationException("The embedded EdgeSwitch icon is missing.");
        trayIcon = new Icon(trayIconStream, Forms.SystemInformation.SmallIconSize);

        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Show toolbar", null, (_, _) => Dispatcher.Invoke(toolbar.ShowFromTray));
        menu.Items.Add("Settings…", null, (_, _) => Dispatcher.Invoke(toolbar.OpenSettings));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Exit EdgeSwitch", null, (_, _) => Dispatcher.Invoke(() => Shutdown()));
        tray = new Forms.NotifyIcon
        {
            Icon = trayIcon,
            Text = "EdgeSwitch — hover at the screen edge",
            ContextMenuStrip = menu,
            Visible = true
        };
        tray.DoubleClick += (_, _) => Dispatcher.Invoke(toolbar.ShowFromTray);
        toolbar.Start();
        if (warning is not null)
        {
            MessageBox.Show(toolbar, warning, "EdgeSwitch settings", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (tray is not null)
        {
            tray.Visible = false;
            tray.ContextMenuStrip?.Dispose();
            tray.Dispose();
        }
        trayIcon?.Dispose();
        trayIconStream?.Dispose();
        if (ownsMutex)
            instance?.ReleaseMutex();
        instance?.Dispose();
        base.OnExit(e);
    }
}
