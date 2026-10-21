# Run from the repository root after a Release build, using .NET 10 PowerShell: pwsh -STA -File tests/ToolbarCaptureSmoke.ps1
# Real helper windows exercise enumeration and empty-to-populated layout without changing saved settings.
param([string]$AssemblyPath = 'bin/Release/net10.0-windows/EdgeSwitch.dll')

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or [Environment]::Version.Major -lt 10) {
    throw 'Requires Windows and PowerShell running on .NET 10 or newer.'
}
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Run with pwsh -STA.'
}
if (-not (Test-Path -LiteralPath $AssemblyPath -PathType Leaf)) {
    throw 'Build EdgeSwitch.csproj -c Release first.'
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2) | Out-Null
$assembly = [Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($AssemblyPath))
$flags = [Reflection.BindingFlags]'Public,NonPublic,Instance,Static'
$app = $null
$helper = $null

function Assert-Condition([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Invoke-Toolbar([string]$name, [object[]]$arguments = @()) {
    $toolbar.GetType().GetMethod($name, $flags).Invoke($toolbar, $arguments)
}

function Pump-Layout {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $callback = [Action]({ $frame.Continue = $false }.GetNewClosure())
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::ApplicationIdle, $callback) | Out-Null
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Get-ToolbarRectangle {
    $arguments = @([System.Windows.Interop.WindowInteropHelper]::new($toolbar).Handle,
        [Activator]::CreateInstance($assembly.GetType('EdgeSwitch.NativeRect')))
    $ok = $assembly.GetType('EdgeSwitch.NativeMethods').GetMethod('GetWindowRect', $flags).Invoke($null, $arguments)
    Assert-Condition $ok 'Could not read the actual toolbar HWND rectangle.'
    return $arguments[1]
}

function Test-ToolbarVisible {
    $handle = [System.Windows.Interop.WindowInteropHelper]::new($toolbar).Handle
    return $assembly.GetType('EdgeSwitch.NativeMethods').GetMethod('IsWindowVisible', $flags).Invoke($null, @($handle))
}

function New-EdgePoint($monitorBounds, [int]$along, [int]$inward = 0) {
    $point = [Activator]::CreateInstance($assembly.GetType('EdgeSwitch.NativePoint'))
    switch ($settings.GetType().GetProperty('TriggerEdge', $flags).GetValue($settings).ToString()) {
        'Left' { $point.X = $monitorBounds.Left + $inward; $point.Y = $along }
        'Right' { $point.X = $monitorBounds.Right - 1 - $inward; $point.Y = $along }
        'Top' { $point.X = $along; $point.Y = $monitorBounds.Top + $inward }
        'Bottom' { $point.X = $along; $point.Y = $monitorBounds.Bottom - 1 - $inward }
    }
    return $point
}

function Assert-ExactHoverSpan([string]$edge) {
    $bounds = Get-ToolbarRectangle
    $monitor = $toolbar.GetType().GetField('currentMonitor', $flags).GetValue($toolbar)
    $vertical = $settings.GetType().GetProperty('TriggerEdge', $flags).GetValue($settings).ToString() -in @('Left', 'Right')
    $start = if ($vertical) { $bounds.Top } else { $bounds.Left }
    $end = if ($vertical) { $bounds.Bottom } else { $bounds.Right }
    $middle = [int][Math]::Floor(($start + $end) / 2)
    $inside = New-EdgePoint $monitor.Bounds $middle
    $monitorStart = if ($vertical) { $monitor.Bounds.Top } else { $monitor.Bounds.Left }
    $outside = New-EdgePoint $monitor.Bounds $(if ($start -gt $monitorStart) { $start - 1 } else { $end })
    $deadline = $toolbar.GetType().GetField('nextCatalogRefresh', $flags)
    $oldDeadline = $deadline.GetValue($toolbar)
    $deadline.SetValue($toolbar, [long]::MaxValue)
    $now = [Environment]::TickCount64 # Strictly below MaxValue; don't trigger a catalog refresh in pixel probes.
    try {
        Invoke-Toolbar 'Conceal'
        foreach ($along in @($start, $middle, ($end - 1))) {
            $point = New-EdgePoint $monitor.Bounds $along
            Assert-Condition ($null -ne (Invoke-Toolbar 'FindEdge' @($point, $now))) "${edge}: first/middle/last span pixel should trigger."
        }
        foreach ($along in @(($start - 1), $end)) {
            $point = New-EdgePoint $monitor.Bounds $along
            Assert-Condition ($null -eq (Invoke-Toolbar 'FindEdge' @($point, $now))) "${edge}: outside the toolbar span must not trigger."
        }
        $secondPixel = New-EdgePoint $monitor.Bounds $middle 1
        $thirdPixel = New-EdgePoint $monitor.Bounds $middle 2
        Assert-Condition ($null -ne (Invoke-Toolbar 'FindEdge' @($secondPixel, $now))) "${edge}: second physical edge pixel should trigger."
        Assert-Condition ($null -eq (Invoke-Toolbar 'FindEdge' @($thirdPixel, $now))) "${edge}: third inward pixel must not trigger."
        Assert-Condition (-not (Test-ToolbarVisible)) "${edge}: hit testing must not reveal the toolbar."
        $after = Get-ToolbarRectangle
        Assert-Condition ($after.Left -eq $bounds.Left -and $after.Top -eq $bounds.Top -and
            $after.Right -eq $bounds.Right -and $after.Bottom -eq $bounds.Bottom) "${edge}: hit testing moved the hidden HWND."

        Invoke-Toolbar 'UpdatePointer' @($outside, $now)
        Invoke-Toolbar 'UpdatePointer' @($inside, ($now + 100))
        Assert-Condition (-not (Test-ToolbarVisible)) "${edge}: dwell revealed immediately."
        Invoke-Toolbar 'UpdatePointer' @($outside, ($now + 200))
        Assert-Condition ($null -eq $toolbar.GetType().GetField('dwellMonitor', $flags).GetValue($toolbar)) "${edge}: leaving the span must cancel dwell."
        Invoke-Toolbar 'UpdatePointer' @($inside, ($now + 250))
        Invoke-Toolbar 'UpdatePointer' @($inside, ($now + 399))
        Assert-Condition (-not (Test-ToolbarVisible)) "${edge}: incomplete restarted dwell revealed."
        Invoke-Toolbar 'UpdatePointer' @($inside, ($now + 400))
        Assert-Condition (Test-ToolbarVisible) "${edge}: completed in-span dwell did not reveal."
        Invoke-Toolbar 'Conceal'
        Invoke-Toolbar 'UpdatePointer' @($inside, ($now + 500))
        Invoke-Toolbar 'UpdatePointer' @($inside, ($now + 800))
        Assert-Condition (-not (Test-ToolbarVisible)) "${edge}: explicit hiding must remain disarmed within the span."
        Invoke-Toolbar 'UpdatePointer' @($outside, ($now + 900))
        Invoke-Toolbar 'UpdatePointer' @($inside, ($now + 1000))
        Invoke-Toolbar 'UpdatePointer' @($inside, ($now + 1150))
        Assert-Condition (Test-ToolbarVisible) "${edge}: leaving the span must rearm reveal."
    } finally {
        $deadline.SetValue($toolbar, $oldDeadline)
        Invoke-Toolbar 'ShowFromTray'
        Pump-Layout
    }
}

function Assert-HiddenSpanRefresh {
    $settings.Edge = [Enum]::Parse($edgeType, 'TopLeft')
    $settings.CapturedProcesses.Add($helper.ProcessName)
    Invoke-Toolbar 'ShowFromTray'
    Pump-Layout
    $expanded = Get-ToolbarRectangle
    $monitor = $toolbar.GetType().GetField('currentMonitor', $flags).GetValue($toolbar)
    $settings.CapturedProcesses.Clear()
    Invoke-Toolbar 'ShowFromTray'
    Pump-Layout
    $empty = Get-ToolbarRectangle
    Assert-Condition ($expanded.Right -gt $empty.Right) 'Growth probe needs a point beyond the empty toolbar span.'
    Invoke-Toolbar 'Conceal'
    $settings.CapturedProcesses.Add($helper.ProcessName)
    $deadline = $toolbar.GetType().GetField('nextCatalogRefresh', $flags)
    $oldDeadline = $deadline.GetValue($toolbar)
    $deadline.SetValue($toolbar, [long]0)
    $now = [Environment]::TickCount64
    $point = New-EdgePoint $monitor.Bounds ($expanded.Right - 1)
    try {
        Assert-Condition ($null -ne (Invoke-Toolbar 'FindEdge' @($point, $now))) 'Hidden refresh must include newly captured windows in the hover span.'
        Assert-Condition (-not (Test-ToolbarVisible)) 'Refreshing the hidden span must not show the HWND.'
        $settings.CapturedProcesses.Clear()
        Assert-Condition ($null -eq (Invoke-Toolbar 'FindEdge' @($point, ($now + 1001)))) 'Hidden refresh must remove the obsolete part of a shrinking span.'
        Assert-Condition (-not (Test-ToolbarVisible)) 'Shrinking a hidden span must not show the HWND.'
        Write-Output 'PASS: hidden capture growth/shrink updates the hover span without revealing.'
    } finally {
        $settings.CapturedProcesses.Clear()
        $deadline.SetValue($toolbar, $oldDeadline)
        Invoke-Toolbar 'ShowFromTray'
        Pump-Layout
    }
}

function New-SmokeMonitor([string]$name, [int]$left, [int]$top, [int]$right, [int]$bottom, [double]$scale) {
    $rect = [Activator]::CreateInstance($assembly.GetType('EdgeSwitch.NativeRect'))
    $rect.Left = $left; $rect.Top = $top; $rect.Right = $right; $rect.Bottom = $bottom
    return [Activator]::CreateInstance($assembly.GetType('EdgeSwitch.DisplayMonitor'), @($name, $rect, $true, $scale))
}

function Assert-SharedSpan {
    $monitorField = $toolbar.GetType().GetField('monitors', $flags)
    $oldMonitors = $monitorField.GetValue($toolbar)
    $oldDevice = $settings.MonitorDeviceName
    $deadline = $toolbar.GetType().GetField('nextCatalogRefresh', $flags)
    $oldDeadline = $deadline.GetValue($toolbar)
    $target = New-SmokeMonitor 'smoke-target' -1600 -900 0 0 1.5
    try {
        Invoke-Toolbar 'Conceal'
        $deadline.SetValue($toolbar, [long]::MaxValue)
        $settings.MonitorDeviceName = ''
        $bounds = Invoke-Toolbar 'GetToolbarBounds' @($target)
        $split = $bounds.Left + [int][Math]::Floor($bounds.Width / 2)
        $neighbor = New-SmokeMonitor 'smoke-neighbor' -1600 -1800 $split -900 1.5
        $listType = [Collections.Generic.List[object]].GetGenericTypeDefinition().MakeGenericType($assembly.GetType('EdgeSwitch.DisplayMonitor'))
        $monitors = [Activator]::CreateInstance($listType)
        $monitors.Add($target); $monitors.Add($neighbor)
        $monitorField.SetValue($toolbar, $monitors)
        $shared = New-EdgePoint $target.Bounds $bounds.Left
        $exposed = New-EdgePoint $target.Bounds ($bounds.Right - 1)
        $outside = New-EdgePoint $target.Bounds $bounds.Right
        $now = [Environment]::TickCount64
        Assert-Condition ($null -eq (Invoke-Toolbar 'FindEdge' @($shared, $now))) 'Automatic must exclude the shared part of the projected span.'
        Assert-Condition ($null -ne (Invoke-Toolbar 'FindEdge' @($exposed, $now))) 'Automatic must retain the exposed part of the projected span.'
        Assert-Condition ($null -eq (Invoke-Toolbar 'FindEdge' @($outside, $now))) 'Exposed edge beyond the projected span must not trigger.'
        $settings.MonitorDeviceName = 'smoke-target'
        Assert-Condition ($null -ne (Invoke-Toolbar 'FindEdge' @($shared, $now))) 'Explicit display must permit its in-span shared edge.'
        Assert-Condition ($null -eq (Invoke-Toolbar 'FindEdge' @($outside, $now))) 'Explicit display must still reject outside-span points.'
        Write-Output 'PASS: negative-origin/scaled span respects Automatic exposed segments and explicit-display seams.'
    } finally {
        $settings.MonitorDeviceName = $oldDevice
        $monitorField.SetValue($toolbar, $oldMonitors)
        $deadline.SetValue($toolbar, $oldDeadline)
        Invoke-Toolbar 'ShowFromTray'
        Pump-Layout
    }
}

function Get-EntryButton($card) {
    $container = $toolbar.FindName('WindowItems').ItemContainerGenerator.ContainerFromItem($card)
    Assert-Condition ($null -ne $container) 'Captured entry has no generated container.'
    $queue = [Collections.Generic.Queue[System.Windows.DependencyObject]]::new()
    $queue.Enqueue($container)
    while ($queue.Count -gt 0) {
        $visual = $queue.Dequeue()
        if ($visual -is [System.Windows.Controls.Button]) { return $visual }
        for ($index = 0; $index -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($visual); $index++) {
            $queue.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($visual, $index))
        }
    }
    throw 'Captured entry has no button.'
}

function Assert-CapturedVisible([string]$phase) {
    # Check only our helper PID: other interactive pwsh processes may also own windows.
    $cards = $toolbar.GetType().GetField('cards', $flags).GetValue($toolbar)
    $captured = @($cards | Where-Object { $_.Entry.ProcessId -eq $helper.Id })
    Assert-Condition ($captured.Count -eq 4) "${phase}: expected four helper windows in the real catalog."
    $scroller = $toolbar.FindName('WindowScroller')
    Assert-Condition ($scroller.ViewportWidth -gt 0 -and $scroller.ViewportHeight -gt 0) (
        "${phase}: four captured windows have no viewport; toolbar is $($toolbar.ActualWidth)x$($toolbar.ActualHeight).")
    foreach ($card in $captured) {
        $button = Get-EntryButton $card
        $button.BringIntoView()
        Pump-Layout
        Assert-Condition ($button.ActualWidth -gt 0 -and $button.ActualHeight -gt 0) "${phase}: zero-sized entry."
        $origin = $button.TranslatePoint([System.Windows.Point]::new(0, 0), $scroller)
        $bounds = [System.Windows.Rect]::new($origin.X, $origin.Y, $button.ActualWidth, $button.ActualHeight)
        $viewport = [System.Windows.Rect]::new(0, 0, $scroller.ViewportWidth, $scroller.ViewportHeight)
        Assert-Condition ($bounds.IntersectsWith($viewport)) "${phase}: entry cannot be scrolled into view."
    }
}

try {
    $childScript = @'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::PerMonitorV2) | Out-Null
$tag = [Guid]::NewGuid().ToString('N')
$windows = @(1..4 | ForEach-Object {
    $form = [System.Windows.Forms.Form]::new()
    $form.Text = "EdgeSwitch smoke $tag session $_"
    $form.Width = 260
    $form.Height = 160
    $form.Icon = [System.Drawing.SystemIcons]::Information
    $form.Show()
    $form
})
[Console]::WriteLine('READY')
[Console]::Out.Flush()
try { [System.Windows.Forms.Application]::Run($windows[0]) }
finally { foreach ($window in $windows) { $window.Dispose() } }
'@
    $start = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-STA', '-EncodedCommand',
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript)))) {
        $start.ArgumentList.Add($argument)
    }
    $helper = [Diagnostics.Process]::Start($start)
    $ready = $helper.StandardOutput.ReadLineAsync()
    Assert-Condition ($ready.Wait(15000) -and $ready.Result -eq 'READY') 'Helper windows did not start.'

    # Use the app's embedded resources without running App.OnStartup or acquiring its tray mutex.
    [System.Windows.Application].GetField('_resourceAssembly', [Reflection.BindingFlags]'NonPublic,Static').SetValue($null, $assembly)
    $app = [System.Windows.Application]::new()
    $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    [xml]$xml = [IO.File]::ReadAllText('App.xaml')
    $app.Resources = [System.Windows.Markup.XamlReader]::Parse(
        '<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">' +
        $xml.DocumentElement.ChildNodes[0].InnerXml + '</ResourceDictionary>')
    $settings = [Activator]::CreateInstance($assembly.GetType('EdgeSwitch.ToolbarSettings'), $true)
    $settings.CapturedProcesses.Clear()
    $edgeType = $assembly.GetType('EdgeSwitch.ToolbarEdge')
    $settings.Edge = [Enum]::Parse($edgeType, 'TopLeft')
    $toolbar = [Activator]::CreateInstance($assembly.GetType('EdgeSwitch.MainWindow'),
        [Reflection.BindingFlags]'Public,NonPublic,Instance', $null, @($settings), $null)
    Invoke-Toolbar 'Start'
    $toolbar.GetType().GetField('timer', $flags).GetValue($toolbar).Stop()
    Pump-Layout

    foreach ($edge in [Enum]::GetValues($edgeType)) {
        $settings.Edge = $edge
        $settings.CapturedProcesses.Clear()
        Invoke-Toolbar 'ShowFromTray'
        Pump-Layout
        Assert-Condition ($toolbar.ActualWidth -le 56 -and $toolbar.ActualHeight -le 56) "${edge}: empty toolbar is not icon-only."
        for ($cycle = 0; $cycle -lt 2; $cycle++) {
            $settings.CapturedProcesses.Add($helper.ProcessName)
            Invoke-Toolbar 'ShowFromTray'
            Pump-Layout
            Assert-CapturedVisible "${edge}, capture cycle $cycle"
            Invoke-Toolbar 'ShowFromTray'
            Pump-Layout
            Assert-CapturedVisible "${edge}, repeat reveal $cycle"
            if ($cycle -eq 0) { Assert-ExactHoverSpan $edge.ToString() }
            $settings.CapturedProcesses.Clear()
            Invoke-Toolbar 'ShowFromTray'
            Pump-Layout
            Assert-Condition ($toolbar.ActualWidth -le 56 -and $toolbar.ActualHeight -le 56) "${edge}: clearing capture did not shrink toolbar."
        }
        Write-Output "PASS: $edge capture transitions, exact hover boundaries, dwell and rearm."
    }

    Assert-HiddenSpanRefresh
    $settings.Edge = [Enum]::Parse($edgeType, 'TopLeft')
    $settings.CapturedProcesses.Add($helper.ProcessName)
    Invoke-Toolbar 'ShowFromTray'
    Pump-Layout
    Assert-SharedSpan
    $cards = $toolbar.GetType().GetField('cards', $flags).GetValue($toolbar)
    $captured = @($cards | Where-Object { $_.Entry.ProcessId -eq $helper.Id })
    # Synthetic RDP metadata tests label growth; the handles still belong to our real helper windows.
    foreach ($card in $captured) {
        $entry = [Activator]::CreateInstance($assembly.GetType('EdgeSwitch.WindowEntry'),
            @($card.Entry.Handle, $helper.Id, 'msrdc', 'session-with-a-long-host-name - Remote Desktop'))
        $card.GetType().GetMethod('Update', $flags).Invoke($card, @($entry)) | Out-Null
    }
    $toolbar.GetType().GetField('layoutDirty', $flags).SetValue($toolbar, $true)
    $monitor = $toolbar.GetType().GetField('currentMonitor', $flags).GetValue($toolbar)
    Invoke-Toolbar 'Place' @($monitor) # RefreshWindows would replace the synthetic metadata.
    Pump-Layout
    Assert-CapturedVisible 'Synthetic RDP labels'
    foreach ($card in $captured) {
        Assert-Condition ((Get-EntryButton $card).ActualWidth -gt 40) 'RDP session label was not included in layout.'
    }
    Write-Output 'PASS: four synthetic Remote Desktop icon/name entries remain reachable after label growth.'
} finally {
    if ($null -ne $app) { $app.Shutdown() }
    if ($null -ne $helper) {
        # These are only the disposable Forms created above, never the user's EdgeSwitch or sessions.
        for ($attempt = 0; $attempt -lt 4 -and -not $helper.HasExited; $attempt++) {
            $helper.Refresh()
            $helper.CloseMainWindow() | Out-Null
            $helper.WaitForExit(500) | Out-Null
        }
        if (-not $helper.HasExited) { $helper.Kill($true); $helper.WaitForExit() }
        $helper.Dispose()
    }
}
