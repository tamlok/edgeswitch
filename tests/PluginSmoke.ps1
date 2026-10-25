# Run after a Release build: pwsh -NoProfile -STA -File tests/PluginSmoke.ps1
# Disposable real processes exercise the protocol, opt-in, cancellation and output limits.
param([string]$AssemblyPath = 'bin/Release/net10.0-windows/EdgeSwitch.dll')

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or [Environment]::Version.Major -lt 10 -or
    [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Requires Windows and .NET 10 PowerShell with -STA.'
}
Add-Type -AssemblyName WindowsBase
$assembly = [Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($AssemblyPath))
$flags = [Reflection.BindingFlags]'Public,NonPublic,Instance,Static'
$hostType = $assembly.GetType('EdgeSwitch.PluginHost')
$catalogType = $assembly.GetType('EdgeSwitch.PluginCatalog')
$root = [IO.Path]::GetFullPath("artifacts/plugin-smoke-$([Guid]::NewGuid().ToString('N'))")
$previousBase = [AppContext]::GetData('APP_CONTEXT_BASE_DIRECTORY')
$pluginHost = $null

function Assert-Condition([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Pump-Dispatcher {
    $frame = [Windows.Threading.DispatcherFrame]::new()
    $callback = [Action]({ $frame.Continue = $false }.GetNewClosure())
    [Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [Windows.Threading.DispatcherPriority]::ApplicationIdle, $callback) | Out-Null
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Wait-Until([scriptblock]$condition) {
    $end = [Environment]::TickCount64 + 10000
    do {
        Pump-Dispatcher
        if (& $condition) { return }
        Start-Sleep -Milliseconds 20
    } while ([Environment]::TickCount64 -lt $end)
    throw 'Timed out waiting for plugin state.'
}

function New-Plugin([string]$id, [string]$body, [int]$timeout = 5) {
    $directory = [IO.Path]::Combine($root, 'plugins', $id)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $script = '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); [Console]::In.ReadToEnd() | Out-Null; ' + $body
    $manifest = @{
        protocolVersion = 1; name = $id; executable = 'pwsh.exe'
        arguments = @('-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script)))
        refreshSeconds = 30; timeoutSeconds = $timeout
    }
    [IO.File]::WriteAllText([IO.Path]::Combine($directory, 'plugin.json'), ($manifest | ConvertTo-Json -Depth 4))
    return ($catalogType.GetMethod('Discover', $flags).Invoke($null, @()) | Where-Object Id -eq $id)
}

function Run-Plugin($definition) {
    $options = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $task = $hostType.GetMethod('RunAsync', $flags).Invoke($null, @($definition.PSObject.BaseObject, $options, [Threading.CancellationToken]::None))
    return $task.GetAwaiter().GetResult()
}

function New-Settings([string]$id, [bool]$enabled) {
    $settings = [Activator]::CreateInstance($assembly.GetType('EdgeSwitch.ToolbarSettings'), $true)
    $configuration = [Activator]::CreateInstance($assembly.GetType('EdgeSwitch.PluginConfiguration'), $true)
    $configuration.Enabled = $enabled
    $settings.Plugins.Add($id, $configuration)
    return $settings
}

function Reload-Plugins($settings) {
    $hostType.GetMethod('Reload', $flags).Invoke($pluginHost, @($settings.PSObject.BaseObject)) | Out-Null
}

try {
    [IO.Directory]::CreateDirectory($root) | Out-Null
    [AppContext]::SetData('APP_CONTEXT_BASE_DIRECTORY', $root)
    $good = New-Plugin 'valid' '[Console]::Write(''{"protocolVersion":1,"text":"42.1%","toolTip":"A valid quota reading"}'')'
    $reading = Run-Plugin $good
    Assert-Condition ($reading.Text -ceq '42.1%') 'A valid process result did not reach the toolbar reading.'

    foreach ($body in @(
        '[Console]::Write(''not JSON'')',
        '[Console]::Write(''{"protocolVersion":2,"text":"0%","toolTip":"invalid version"}'')',
        '[Console]::Write(''{"protocolVersion":1,"text":null,"toolTip":"no data"}'')',
        '[Console]::Write(''{"protocolVersion":"1","text":"0%","toolTip":"wrong type"}'')',
        '[Console]::Write(''{"protocolVersion":1,"text":"0%","toolTip":"failed process"}''); exit 3',
        '[Console]::Write((''x'' * 20000))',
        '[Console]::Error.Write((''secret'' * 4000)); Start-Sleep -Seconds 20'
    )) {
        $reading = Run-Plugin (New-Plugin 'invalid' $body)
        Assert-Condition ($reading.Text -eq 'Unavailable' -and -not $reading.ToolTip.Contains('secret')) 'Bad output/exit exposed a percentage or raw stderr.'
    }
    Write-Output 'PASS: actual process protocol; malformed/version/type/nonzero/oversized stdout and stderr fail without exposing a percentage or stderr.'

    $pidPath = [IO.Path]::Combine($root, 'descendant.pid')
    $quotedPath = $pidPath.Replace("'", "''")
    $body = '$start = New-Object Diagnostics.ProcessStartInfo; $start.FileName = ''pwsh.exe''; $start.Arguments = ''-NoProfile -NonInteractive -Command Start-Sleep -Seconds 30''; $start.UseShellExecute = $false; $start.CreateNoWindow = $true; $p = [Diagnostics.Process]::Start($start); [IO.File]::WriteAllText(''' + $quotedPath + ''', [string]$p.Id); Start-Sleep -Seconds 30'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $reading = Run-Plugin (New-Plugin 'timeout' $body 5)
    Assert-Condition ($reading.Text -eq 'Unavailable' -and $watch.Elapsed.TotalSeconds -lt 12) 'Timeout did not bound the process run.'
    Assert-Condition ([IO.File]::Exists($pidPath)) 'The timeout test did not start its descendant.'
    $descendant = [int][IO.File]::ReadAllText($pidPath)
    Wait-Until { $null -eq (Get-Process -Id $descendant -ErrorAction SilentlyContinue) }
    Write-Output 'PASS: timeout closes the job and terminates the plugin descendant.'

    $markerPath = [IO.Path]::Combine($root, 'started.pid')
    $quotedMarker = $markerPath.Replace("'", "''")
    # Publish readiness only after the PID file has been closed.
    $slow = New-Plugin 'lifecycle' ('[IO.File]::WriteAllText(''' + $quotedMarker + '.tmp'', [string]$PID); [IO.File]::Move(''' + $quotedMarker + '.tmp'', ''' + $quotedMarker + '''); Start-Sleep -Seconds 20; [Console]::Write(''{"protocolVersion":1,"text":"old","toolTip":"old generation"}'')') 30
    $pluginHost = [Activator]::CreateInstance($hostType, $flags, $null,
        @([Windows.Threading.Dispatcher]::CurrentDispatcher, [Action]{}), $null)
    $cards = $hostType.GetProperty('Cards', $flags).GetValue($pluginHost)
    $settings = New-Settings 'lifecycle' $false
    Reload-Plugins $settings
    Pump-Dispatcher
    Assert-Condition ($cards.Count -eq 0 -and -not [IO.File]::Exists($markerPath)) 'A disabled plugin was started or displayed.'
    $settings.Plugins['lifecycle'].Enabled = $true
    Reload-Plugins $settings
    Wait-Until { [IO.File]::Exists($markerPath) }
    $oldProcess = [int][IO.File]::ReadAllText($markerPath)
    $settings.Plugins['lifecycle'].Enabled = $false
    Reload-Plugins $settings
    Wait-Until { $null -eq (Get-Process -Id $oldProcess -ErrorAction SilentlyContinue) }
    Assert-Condition ($cards.Count -eq 0) 'Disable retained a stale toolbar card.'

    New-Plugin 'lifecycle' '[Console]::Write(''{"protocolVersion":1,"text":"new","toolTip":"new generation"}'')' | Out-Null
    $settings.Plugins['lifecycle'].Enabled = $true
    Reload-Plugins $settings
    Wait-Until { $cards.Count -eq 1 -and $cards[0].Text -eq 'new' }
    Assert-Condition ($cards[0].ToolTip -eq 'new generation') 'A cancelled generation overwrote the new reading.'
    Write-Output 'PASS: disabled plugins do not run; enabling polls; disable kills pending process; reload displays only the new generation.'

    $missing = New-Settings 'not-installed' $true
    Reload-Plugins $missing
    Assert-Condition ($cards.Count -eq 1 -and $cards[0].Text -eq 'Unavailable') 'A missing enabled plugin silently disappeared.'
    [IO.File]::WriteAllText([IO.Path]::Combine($root, 'plugins', 'valid', 'plugin.json'), '{broken')
    $discovered = $catalogType.GetMethod('Discover', $flags).Invoke($null, @())
    Assert-Condition (($discovered | Where-Object Id -eq 'valid').Error -and
        ($discovered | Where-Object Id -eq 'lifecycle').Manifest) 'A malformed manifest suppressed a healthy plugin.'
    Write-Output 'PASS: missing enabled plugins are visible errors; one malformed manifest does not block another plugin.'
} finally {
    if ($null -ne $pluginHost) { $pluginHost.Dispose() }
    [AppContext]::SetData('APP_CONTEXT_BASE_DIRECTORY', $previousBase)
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}
