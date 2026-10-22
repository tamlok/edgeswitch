# Run after a Release build: pwsh -NoProfile -STA -File tests/MaximizeWindowSmoke.ps1
# Uses disposable native windows; requires an idle interactive Windows desktop.
param([string]$AssemblyPath = 'bin/Release/net10.0-windows/EdgeSwitch.dll')

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or [Environment]::Version.Major -lt 10 -or
    [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Requires Windows and .NET 10 PowerShell: pwsh -NoProfile -STA.'
}
if (-not (Test-Path -LiteralPath $AssemblyPath -PathType Leaf)) {
    throw 'Build EdgeSwitch.csproj -c Release first.'
}
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2) | Out-Null
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Windows.Forms.Primitives, System.Drawing.Primitives, System.ComponentModel.Primitives -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class MaximizeWindowReceiver : Form
{
    public int MaximizeCommands;
    public int KeyboardMessages;

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == 0x112 && (message.WParam.ToInt64() & 0xFFF0) == 0xF030)
            MaximizeCommands++;
        if (message.Msg == 0x100 || message.Msg == 0x101 || message.Msg == 0x104 || message.Msg == 0x105)
            KeyboardMessages++;
        base.WndProc(ref message);
    }
}
'@
$assembly = [Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($AssemblyPath))
$flags = [Reflection.BindingFlags]'NonPublic,Static'
$native = $assembly.GetType('EdgeSwitch.NativeMethods')
$maximize = $native.GetMethod('TryMaximizeWindow', $flags)
$isZoomed = $native.GetMethod('IsZoomed', $flags)
$isFullscreen = $native.GetMethod('IsFullscreen', $flags)
$receiver = $null
$other = $null
$shiftPressed = $false
$previousForeground = [MaximizeWindowReceiver]::GetForegroundWindow()

function Assert-Condition([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Pump-Window {
    $until = [Environment]::TickCount64 + 200
    do {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 10
    } while ([Environment]::TickCount64 -lt $until)
}

function Focus-Receiver($window) {
    $window.Activate()
    [MaximizeWindowReceiver]::SetForegroundWindow($window.Handle) | Out-Null
    Pump-Window
    Assert-Condition ([MaximizeWindowReceiver]::GetForegroundWindow() -eq $window.Handle) 'Windows refused test-window focus.'
}

function Maximize-Receiver([uint32]$processId = $PID) {
    $maximize.Invoke($null, @($receiver.Handle, $processId))
}

function Reset-Receiver {
    $receiver.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    Focus-Receiver $receiver
    $receiver.MaximizeCommands = 0
    $receiver.KeyboardMessages = 0
}

try {
    foreach ($key in @(0x10, 0x11, 0x12, 0x5B, 0x5C)) {
        Assert-Condition ([MaximizeWindowReceiver]::GetAsyncKeyState($key) -ge 0) "Modifier $key is held; release it before running."
    }
    $receiver = [MaximizeWindowReceiver]::new()
    $receiver.Text = 'EdgeSwitch maximize smoke receiver'
    $receiver.Width = 480
    $receiver.Height = 180
    $receiver.Show()
    Reset-Receiver
    Assert-Condition (-not $isZoomed.Invoke($null, @($receiver.Handle))) 'Receiver must start in normal state.'
    Assert-Condition (Maximize-Receiver) 'Windows rejected maximize request.'
    Pump-Window
    Assert-Condition ($isZoomed.Invoke($null, @($receiver.Handle)) -and $receiver.MaximizeCommands -eq 1) 'One maximize command must actually maximize the window.'
    Assert-Condition ($receiver.KeyboardMessages -eq 0) 'Maximize injected keyboard input.'
    Assert-Condition (Maximize-Receiver) 'Already-maximized receiver was rejected.'
    Pump-Window
    Assert-Condition ($isZoomed.Invoke($null, @($receiver.Handle)) -and $receiver.MaximizeCommands -eq 1) 'Already-maximized window received another command or was restored.'
    Write-Output 'PASS: native maximize changes window state without keyboard input; repeated request leaves it maximized.'

    Reset-Receiver
    Assert-Condition (-not (Maximize-Receiver 0)) 'Wrong process identity was accepted.'
    Pump-Window
    Assert-Condition (-not $isZoomed.Invoke($null, @($receiver.Handle)) -and $receiver.MaximizeCommands -eq 0) 'Wrong process identity changed the window.'
    Write-Output 'PASS: wrong process identity receives no maximize command.'

    $other = [MaximizeWindowReceiver]::new()
    $other.Text = 'EdgeSwitch focus guard receiver'
    $other.Show()
    Focus-Receiver $other
    Assert-Condition (-not (Maximize-Receiver)) 'Background target was accepted.'
    Pump-Window
    Assert-Condition ($receiver.MaximizeCommands -eq 0 -and $other.MaximizeCommands -eq 0 -and
        -not $isZoomed.Invoke($null, @($receiver.Handle)) -and -not $isZoomed.Invoke($null, @($other.Handle))) 'Background request changed a window.'
    Write-Output 'PASS: background request leaves both windows unchanged.'
    $other.Close()

    $receiver.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
    Pump-Window
    Assert-Condition (-not (Maximize-Receiver)) 'Minimized target was accepted before activation/restoration.'
    Pump-Window
    Assert-Condition ($receiver.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized -and $receiver.MaximizeCommands -eq 0) 'Minimized target changed state.'
    Write-Output 'PASS: minimized target waits for the activation path to restore it.'

    Reset-Receiver
    $shiftPressed = $true
    [MaximizeWindowReceiver]::keybd_event(0x10, 0x2A, 0, [UIntPtr]::Zero)
    Pump-Window
    Assert-Condition ([MaximizeWindowReceiver]::GetAsyncKeyState(0x10) -lt 0) 'Shift setup failed.'
    $receiver.KeyboardMessages = 0
    Assert-Condition (Maximize-Receiver) 'Held modifier blocked native maximize.'
    Pump-Window
    Assert-Condition ($isZoomed.Invoke($null, @($receiver.Handle)) -and
        [MaximizeWindowReceiver]::GetAsyncKeyState(0x10) -lt 0 -and $receiver.KeyboardMessages -eq 0) 'Maximize failed or altered the held modifier.'
    [MaximizeWindowReceiver]::keybd_event(0x10, 0x2A, 2, [UIntPtr]::Zero)
    $shiftPressed = $false
    Pump-Window
    Write-Output 'PASS: maximize works with a held modifier and does not release it.'

    Reset-Receiver
    $receiver.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $receiver.Bounds = [System.Windows.Forms.Screen]::FromHandle($receiver.Handle).Bounds
    Focus-Receiver $receiver
    Assert-Condition ($isFullscreen.Invoke($null, @($receiver.Handle))) 'Borderless receiver does not cover its monitor.'
    Assert-Condition (Maximize-Receiver) 'Already-fullscreen receiver was rejected.'
    Pump-Window
    Assert-Condition ($isFullscreen.Invoke($null, @($receiver.Handle)) -and $receiver.MaximizeCommands -eq 0) 'Already-fullscreen window received a command or changed state.'
    Write-Output 'PASS: already-fullscreen window stays unchanged.'
} finally {
    if ($shiftPressed) {
        [MaximizeWindowReceiver]::keybd_event(0x10, 0x2A, 2, [UIntPtr]::Zero)
        Pump-Window
    }
    if ($null -ne $other) { $other.Dispose() }
    if ($null -ne $receiver) { $receiver.Dispose() }
    if ($previousForeground -ne [IntPtr]::Zero) {
        [MaximizeWindowReceiver]::SetForegroundWindow($previousForeground) | Out-Null
    }
}
