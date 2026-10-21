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
            $settings.CapturedProcesses.Clear()
            Invoke-Toolbar 'ShowFromTray'
            Pump-Layout
            Assert-Condition ($toolbar.ActualWidth -le 56 -and $toolbar.ActualHeight -le 56) "${edge}: clearing capture did not shrink toolbar."
        }
        Write-Output "PASS: $edge empty/captured/repeated-reveal/empty transitions."
    }

    $settings.Edge = [Enum]::Parse($edgeType, 'TopLeft')
    $settings.CapturedProcesses.Add($helper.ProcessName)
    Invoke-Toolbar 'ShowFromTray'
    Pump-Layout
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
