# Run after a Release build: pwsh -NoProfile -File tests/SettingsStoreSmoke.ps1
# Real file IO and startup rollback, isolated from the user's settings and Run entry.
param([string]$AssemblyPath = 'bin/Release/net10.0-windows/EdgeSwitch.dll')

$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or [Environment]::Version.Major -lt 10) {
    throw 'Requires Windows and PowerShell running on .NET 10 or newer.'
}
if (-not (Test-Path -LiteralPath $AssemblyPath -PathType Leaf)) {
    throw 'Build EdgeSwitch.csproj -c Release first.'
}
$assembly = [Reflection.Assembly]::LoadFrom([IO.Path]::GetFullPath($AssemblyPath))
$flags = [Reflection.BindingFlags]'Public,NonPublic,Static'
$store = $assembly.GetType('EdgeSwitch.SettingsStore')
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class IniRegistrySandbox
{
    [DllImport("advapi32.dll")]
    private static extern int RegOverridePredefKey(IntPtr key, IntPtr replacement);
    public static int Redirect(IntPtr replacement) => RegOverridePredefKey(new IntPtr(-2147483647), replacement);
}
'@
$root = [IO.Path]::GetFullPath("artifacts/settings-smoke-$([Guid]::NewGuid().ToString('N'))")
$baseDirectory = [IO.Path]::Combine($root, 'application')
$otherDirectory = [IO.Path]::Combine($root, 'working-directory')
$iniPath = [IO.Path]::Combine($baseDirectory, 'settings.ini')
$registryPath = "Software\EdgeSwitchSmoke-$([Guid]::NewGuid().ToString('N'))"
$startupPath = 'Software\Microsoft\Windows\CurrentVersion\Run'
$previousBase = [AppContext]::GetData('APP_CONTEXT_BASE_DIRECTORY')
$previousDirectory = [Environment]::CurrentDirectory
$previousCulture = [Globalization.CultureInfo]::CurrentCulture
$sandbox = $null
$redirected = $false

function Assert-Condition([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function New-Settings {
    return [Activator]::CreateInstance($assembly.GetType('EdgeSwitch.ToolbarSettings'), $true)
}

function Read-Ini([string]$text) {
    return $store.GetMethod('ReadSettings', $flags).Invoke($null, @($text))
}

function Load-Settings {
    $arguments = @($null)
    $settings = $store.GetMethod('Load', $flags).Invoke($null, $arguments)
    return [pscustomobject]@{ Settings = $settings; Warning = $arguments[0] }
}

function Save-Settings($settings, [bool]$startup = $false) {
    $store.GetMethod('Save', $flags).Invoke($null, @($settings, $startup)) | Out-Null
}

function Assert-InvalidIni([string]$text) {
    try { Read-Ini $text | Out-Null }
    catch {
        Assert-Condition ($_.Exception.GetBaseException() -is [IO.InvalidDataException]) 'Malformed INI must report InvalidDataException.'
        return
    }
    throw "Malformed INI was accepted: $text"
}

try {
    [IO.Directory]::CreateDirectory($baseDirectory) | Out-Null
    [IO.Directory]::CreateDirectory($otherDirectory) | Out-Null
    $sandbox = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registryPath)
    $errorCode = [IniRegistrySandbox]::Redirect($sandbox.Handle.DangerousGetHandle())
    Assert-Condition ($errorCode -eq 0) "Could not isolate HKCU: $errorCode"
    $redirected = $true
    [AppContext]::SetData('APP_CONTEXT_BASE_DIRECTORY', $baseDirectory)
    [Environment]::CurrentDirectory = $otherDirectory
    [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('ar-SA')

    $loaded = Load-Settings
    $defaults = New-Settings
    Assert-Condition ($null -eq $loaded.Warning -and -not [IO.File]::Exists($iniPath)) 'Missing INI must use defaults silently without creating a file.'
    Assert-Condition (($loaded.Settings.CapturedProcesses -join '|') -eq ($defaults.CapturedProcesses -join '|') -and
        $loaded.Settings.AlwaysMakeRemoteDesktopSessionFullscreen -eq $defaults.AlwaysMakeRemoteDesktopSessionFullscreen) 'Missing INI changed model defaults.'
    Write-Output 'PASS: missing INI uses defaults silently and creates no file.'

    $settings = New-Settings
    $settings.Edge = [Enum]::Parse($assembly.GetType('EdgeSwitch.ToolbarEdge'), 'RightBottom')
    $settings.MonitorDeviceName = '\\.\DISPLAY9'
    $settings.HideDelayMilliseconds = 1234
    $settings.AlwaysMakeRemoteDesktopSessionFullscreen = $false
    $settings.CapturedProcesses.Clear()
    $settings.CapturedProcesses.Add('strange=app,semi;測試.exe')
    $settings.CapturedProcesses.Add('chrome.exe')
    $settings.CapturedProcesses.Add('CHROME.EXE')
    Save-Settings $settings
    $loaded = Load-Settings
    Assert-Condition ($null -eq $loaded.Warning -and [IO.File]::Exists($iniPath) -and
        -not [IO.File]::Exists([IO.Path]::Combine($otherDirectory, 'settings.ini'))) 'INI was not saved and loaded relative to the application directory.'
    Assert-Condition ($loaded.Settings.Edge -eq $settings.Edge -and $loaded.Settings.MonitorDeviceName -eq $settings.MonitorDeviceName -and
        $loaded.Settings.HideDelayMilliseconds -eq 1234 -and -not $loaded.Settings.AlwaysMakeRemoteDesktopSessionFullscreen -and
        ($loaded.Settings.CapturedProcesses -join '|') -ceq 'strange=app,semi;測試|chrome') 'INI roundtrip lost a setting, punctuation, Unicode, false, or normalization.'
    Write-Output 'PASS: all settings roundtrip in the application folder, independent of working directory/culture; Unicode and punctuation retained.'

    $partial = Read-Ini " ; comment`n[toolbar]`nMaXiMiZeOnActivate=false`nFutureKey=ignored`n[FutureSection]`nAnything=ignored"
    Assert-Condition (-not $partial.AlwaysMakeRemoteDesktopSessionFullscreen -and
        ($partial.CapturedProcesses -join '|') -eq ($defaults.CapturedProcesses -join '|')) 'Missing capture section should retain defaults; explicit false should override.'
    $empty = Read-Ini "[CapturedProcesses]`n# no entries`n[Toolbar]`nEdge = topleft`nHideDelayMilliseconds = 200"
    Assert-Condition ($empty.CapturedProcesses.Count -eq 0 -and $empty.Edge.ToString() -eq 'TopLeft' -and
        $empty.HideDelayMilliseconds -eq 200 -and $empty.AlwaysMakeRemoteDesktopSessionFullscreen -eq $defaults.AlwaysMakeRemoteDesktopSessionFullscreen) 'Empty capture section, named edge, whitespace or missing-key semantics failed.'
    Save-Settings $empty
    Assert-Condition ((Load-Settings).Settings.CapturedProcesses.Count -eq 0) 'Save/load turned capture-none back into defaults.'
    $ordered = Read-Ini "[CapturedProcesses]`n9 = msrdc`n2 = mstsc`n[Toolbar]`nHideDelayMilliseconds=5000"
    Assert-Condition (($ordered.CapturedProcesses -join '|') -eq 'mstsc|msrdc' -and $ordered.HideDelayMilliseconds -eq 5000) 'Capture indices or upper delay boundary failed.'
    Write-Output 'PASS: missing vs empty capture, explicit false, comments/case/whitespace, unknown fields, index order and delay boundaries.'

    foreach ($text in @(
        "not an INI entry", "[FutureSection]`nnot an INI entry",
        "[Toolbar`nEdge=Left", "[Toolbar]`nNoEquals", "[Toolbar]`nEdge=0", "[Toolbar]`nEdge=unknown",
        "[Toolbar]`nMaximizeOnActivate=1", "[Toolbar]`nMaximizeOnActivate=true`nmaximizeonactivate=false",
        "[Toolbar]`nHideDelayMilliseconds=199", "[Toolbar]`nHideDelayMilliseconds=5001",
        "[Toolbar]`nHideDelayMilliseconds=999999999999999999999", "[Toolbar]`nHideDelayMilliseconds=1.5",
        "[CapturedProcesses]`n0=mstsc`n0=msrdc", "[CapturedProcesses]`n-1=mstsc",
        "[CapturedProcesses]`nnotanindex=mstsc", "[CapturedProcesses]`n0=", "[CapturedProcesses]`n0=*.exe"
    )) { Assert-InvalidIni $text }
    $invalidText = "[Toolbar]`nMaximizeOnActivate=invalid"
    [IO.File]::WriteAllText($iniPath, $invalidText)
    $loaded = Load-Settings
    Assert-Condition ($loaded.Warning.Contains($iniPath) -and [IO.File]::ReadAllText($iniPath) -ceq $invalidText -and
        $loaded.Settings.AlwaysMakeRemoteDesktopSessionFullscreen -eq $defaults.AlwaysMakeRemoteDesktopSessionFullscreen) 'Corrupt INI must warn with its path, use defaults and leave the file intact.'
    Write-Output 'PASS: malformed values are rejected; corrupt-file Load warns and leaves original content untouched.'

    Save-Settings $settings
    $previousContent = [IO.File]::ReadAllText($iniPath)
    $settings.MonitorDeviceName = "DISPLAY`n[CapturedProcesses]"
    $rejected = $false
    try { Save-Settings $settings }
    catch { $rejected = $_.Exception.GetBaseException() -is [IO.InvalidDataException] }
    Assert-Condition ($rejected -and [IO.File]::ReadAllText($iniPath) -ceq $previousContent) 'Multiline monitor value injected INI content or altered the previous file.'
    $settings.MonitorDeviceName = ''

    $startup = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($startupPath)
    try { $startup.SetValue('EdgeSwitch', 'previous-startup-command', [Microsoft.Win32.RegistryValueKind]::String) }
    finally { $startup.Dispose() }
    $previousAttributes = [IO.File]::GetAttributes($iniPath)
    [IO.File]::SetAttributes($iniPath, $previousAttributes -bor [IO.FileAttributes]::ReadOnly)
    $rejected = $false
    try { Save-Settings $settings $false }
    catch { $rejected = $_.Exception.GetBaseException() -is [UnauthorizedAccessException] -or $_.Exception.GetBaseException() -is [IO.IOException] }
    finally { [IO.File]::SetAttributes($iniPath, $previousAttributes) }
    $startup = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($startupPath)
    try {
        Assert-Condition ($rejected -and $startup.GetValue('EdgeSwitch') -ceq 'previous-startup-command' -and
            $startup.GetValueKind('EdgeSwitch') -eq [Microsoft.Win32.RegistryValueKind]::String -and
            [IO.File]::ReadAllText($iniPath) -ceq $previousContent -and
            [IO.Directory]::GetFiles($baseDirectory, 'settings.*.tmp').Length -eq 0) 'Failed replacement must keep the previous INI, restore startup registration and clean its temporary file.'
    } finally { $startup.Dispose() }
    Save-Settings $settings $false
    Assert-Condition (-not $store.GetMethod('IsStartupEnabled', $flags).Invoke($null, @())) 'Successful Save did not apply startup-off in the isolated hive.'
    Write-Output 'PASS: unsafe values/read-only saves preserve the INI; failed replacement rolls back startup and cleans its temporary file.'
} finally {
    [Globalization.CultureInfo]::CurrentCulture = $previousCulture
    [Environment]::CurrentDirectory = $previousDirectory
    [AppContext]::SetData('APP_CONTEXT_BASE_DIRECTORY', $previousBase)
    if ($redirected -and [IniRegistrySandbox]::Redirect([IntPtr]::Zero) -ne 0) {
        throw 'Could not restore the process-local HKCU override.'
    }
    if ($null -ne $sandbox) {
        $sandbox.Dispose()
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryPath, $false)
    }
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}
