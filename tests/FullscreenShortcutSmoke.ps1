# Run after a Release build: pwsh -NoProfile -STA -File tests/FullscreenShortcutSmoke.ps1
# Uses real Windows input on disposable windows; requires an idle interactive desktop.
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
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Windows.Forms.Primitives, System.Drawing.Primitives, System.ComponentModel.Primitives, System.Collections -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class FullscreenKeyReceiver : Form
{
    public readonly List<KeyMessage> Messages = new();
    public readonly record struct KeyMessage(int Key, bool Down, bool Extended, bool Control, bool Alt);

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern short GetKeyState(int key);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == 0x100 || message.Msg == 0x101 || message.Msg == 0x104 || message.Msg == 0x105)
            Messages.Add(new KeyMessage((int)message.WParam, message.Msg == 0x100 || message.Msg == 0x104,
                (message.LParam.ToInt64() & 0x01000000) != 0, GetKeyState(0x11) < 0, GetKeyState(0x12) < 0));
        base.WndProc(ref message);
    }
}
'@
$assembly = [Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($AssemblyPath))
$flags = [Reflection.BindingFlags]'NonPublic,Static'
$native = $assembly.GetType('EdgeSwitch.NativeMethods')
$send = $native.GetMethod('TrySendFullscreenShortcut', $flags)
$isFullscreen = $native.GetMethod('IsFullscreen', $flags)
$receiver = $null
$other = $null
$shiftPressed = $false
$previousForeground = [FullscreenKeyReceiver]::GetForegroundWindow()

function Assert-Condition([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Pump-Input {
    $until = [Environment]::TickCount64 + 200
    do {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 10
    } while ([Environment]::TickCount64 -lt $until)
}

function Assert-ModifiersReleased {
    foreach ($key in @(0x10, 0x11, 0x12, 0x5B, 0x5C)) {
        Assert-Condition ([FullscreenKeyReceiver]::GetAsyncKeyState($key) -ge 0) "Modifier $key is held; release it before running."
    }
}

function Focus-Receiver($window) {
    $window.Activate()
    [FullscreenKeyReceiver]::SetForegroundWindow($window.Handle) | Out-Null
    Pump-Input
    Assert-Condition ([FullscreenKeyReceiver]::GetForegroundWindow() -eq $window.Handle) 'Windows refused test-window focus.'
}

function Send-Shortcut([uint32]$processId = $PID) {
    $send.Invoke($null, @($receiver.Handle, $processId))
}

try {
    Assert-ModifiersReleased
    $receiver = [FullscreenKeyReceiver]::new()
    $receiver.Text = 'EdgeSwitch fullscreen shortcut receiver'
    $receiver.Width = 480
    $receiver.Height = 180
    $receiver.Show()
    Focus-Receiver $receiver
    $receiver.Messages.Clear()
    Assert-Condition (Send-Shortcut) 'Windows rejected shortcut insertion.'
    Pump-Input
    $events = @($receiver.Messages)
    $breakDown = @($events | Where-Object { $_.Key -eq 3 -and $_.Down })
    $breakUp = @($events | Where-Object { $_.Key -eq 3 -and -not $_.Down })
    $observed = ($events | ForEach-Object { 'VK=0x{0:X2} down={1} extended={2} ctrl={3} alt={4}' -f $_.Key, $_.Down, $_.Extended, $_.Control, $_.Alt }) -join '; '
    Write-Output "Received: $observed"
    Assert-Condition ($breakDown.Count -eq 1 -and $breakUp.Count -eq 1) 'Expected exactly one Break press/release, not Pause.'
    Assert-Condition ($breakDown[0].Extended -and $breakUp[0].Extended -and
        $breakDown[0].Control -and $breakDown[0].Alt -and $breakUp[0].Control -and $breakUp[0].Alt) 'Break must be extended with Ctrl+Alt held.'
    Assert-Condition (@($events | Where-Object Key -eq 0x13).Count -eq 0) 'Pause was incorrectly injected.'
    Assert-ModifiersReleased
    Write-Output 'PASS: actual Windows receiver got one Ctrl+Alt+Break chord; modifiers released.'

    $receiver.Messages.Clear()
    Assert-Condition (-not (Send-Shortcut 0)) 'Wrong process identity was accepted.'
    Pump-Input
    Assert-Condition ($receiver.Messages.Count -eq 0) 'Wrong process identity received input.'
    Write-Output 'PASS: wrong process identity receives no shortcut.'

    $other = [FullscreenKeyReceiver]::new()
    $other.Text = 'EdgeSwitch focus guard receiver'
    $other.Show()
    Focus-Receiver $other
    $receiver.Messages.Clear()
    $other.Messages.Clear()
    Assert-Condition (-not (Send-Shortcut)) 'Background target was accepted.'
    Pump-Input
    Assert-Condition ($receiver.Messages.Count -eq 0 -and $other.Messages.Count -eq 0) 'Background request leaked input.'
    Write-Output 'PASS: background request sends no keys to either window.'
    $other.Close()
    Focus-Receiver $receiver

    Assert-ModifiersReleased
    $shiftPressed = $true
    [FullscreenKeyReceiver]::keybd_event(0x10, 0x2A, 0, [UIntPtr]::Zero)
    Pump-Input
    Assert-Condition ([FullscreenKeyReceiver]::GetAsyncKeyState(0x10) -lt 0) 'Shift setup failed.'
    $receiver.Messages.Clear()
    Assert-Condition (-not (Send-Shortcut)) 'Held modifier was ignored.'
    Pump-Input
    Assert-Condition ($receiver.Messages.Count -eq 0 -and [FullscreenKeyReceiver]::GetAsyncKeyState(0x10) -lt 0) 'Held modifier was released or input was injected.'
    [FullscreenKeyReceiver]::keybd_event(0x10, 0x2A, 2, [UIntPtr]::Zero)
    $shiftPressed = $false
    Pump-Input
    Assert-ModifiersReleased
    Write-Output 'PASS: held modifier blocks the shortcut and remains held.'

    $receiver.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $receiver.Bounds = [System.Windows.Forms.Screen]::FromHandle($receiver.Handle).Bounds
    Focus-Receiver $receiver
    Assert-Condition ($isFullscreen.Invoke($null, @($receiver.Handle))) 'Borderless receiver does not cover its monitor.'
    $receiver.Messages.Clear()
    Assert-Condition (Send-Shortcut) 'Already-fullscreen window was rejected.'
    Pump-Input
    Assert-Condition ($receiver.Messages.Count -eq 0) 'Already-fullscreen window received a toggle.'
    Write-Output 'PASS: already-fullscreen window receives no toggle.'
} finally {
    if ($shiftPressed) {
        [FullscreenKeyReceiver]::keybd_event(0x10, 0x2A, 2, [UIntPtr]::Zero)
        Pump-Input
    }
    if ($null -ne $other) { $other.Dispose() }
    if ($null -ne $receiver) { $receiver.Dispose() }
    if ($previousForeground -ne [IntPtr]::Zero) {
        [FullscreenKeyReceiver]::SetForegroundWindow($previousForeground) | Out-Null
    }
}
