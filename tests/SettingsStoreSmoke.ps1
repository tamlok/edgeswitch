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

function New-Plugin {
    return [Activator]::CreateInstance($assembly.GetType('EdgeSwitch.PluginConfiguration'), $true)
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

function Assert-RejectedSave($settings) {
    $previousContent = [IO.File]::ReadAllText($iniPath)
    $rejected = $false
    try { Save-Settings $settings }
    catch { $rejected = $_.Exception.GetBaseException() -is [IO.InvalidDataException] }
    Assert-Condition ($rejected -and [IO.File]::ReadAllText($iniPath) -ceq $previousContent -and
        [IO.Directory]::GetFiles($baseDirectory, 'settings.*.tmp').Length -eq 0) 'Invalid plugin settings must be rejected without changing the existing file or leaving temporary files.'
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
    Assert-Condition ($loaded.Settings.Plugins.Count -eq 0 -and $defaults.Plugins.Count -eq 0 -and
        -not (New-Plugin).Enabled) 'Missing INI and new plugin configurations must opt out of every plugin.'
    Write-Output 'PASS: missing INI uses defaults silently, opts out of plugins and creates no file.'

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
    Assert-Condition (-not [IO.File]::ReadAllText($iniPath).Contains('[Plugins]')) 'Settings without plugins must not write an empty Plugins section.'
    Write-Output 'PASS: all settings roundtrip in the application folder, independent of working directory/culture; Unicode and punctuation retained.'

    $plugins = Read-Ini "[pLuGiN.Future-Plugin]`nAccount =  測試=team;#，  `nEmpty = `n[PlUgInS]`nFUTURE-PLUGIN = true`n[Plugin.future-plugin]`nExtra=second=value`n[Plugin.Options_Only]`nHost=github.com"
    Assert-Condition ($plugins.Plugins.Count -eq 2 -and $plugins.Plugins['future-plugin'].Enabled -and
        -not $plugins.Plugins['OPTIONS_ONLY'].Enabled -and $plugins.Plugins['Future-Plugin'].Options['ACCOUNT'] -ceq '測試=team;#，' -and
        $plugins.Plugins['future-plugin'].Options['empty'] -ceq '' -and
        $plugins.Plugins['future-plugin'].Options['extra'] -ceq 'second=value') 'Plugin parsing must merge case-insensitive sections, preserve Unicode/equals/empty values and keep options-only plugins disabled.'
    Save-Settings $plugins
    $reloadedPlugins = (Load-Settings).Settings
    Assert-Condition ($reloadedPlugins.Plugins.Count -eq 2 -and $reloadedPlugins.Plugins['FUTURE-PLUGIN'].Enabled -and
        $reloadedPlugins.Plugins['future-plugin'].Options['Account'] -ceq '測試=team;#，' -and
        $reloadedPlugins.Plugins['future-plugin'].Options['Extra'] -ceq 'second=value' -and
        $reloadedPlugins.Plugins['future-plugin'].Options.ContainsKey('Empty') -and
        -not $reloadedPlugins.Plugins['options_only'].Enabled -and
        $reloadedPlugins.Plugins['options_only'].Options['HOST'] -ceq 'github.com') 'Saving must preserve unknown or missing plugin IDs, enable state and every option.'
    $normalizedPlugins = $store.GetMethod('NormalizeSettings', $flags).Invoke($null, @($plugins))
    $normalizedPlugins.Plugins['future-plugin'].Enabled = $false
    $normalizedPlugins.Plugins['future-plugin'].Options['Account'] = 'changed'
    $normalizedPlugins.Plugins.Remove('options_only') | Out-Null
    Assert-Condition ($plugins.Plugins.Count -eq 2 -and $plugins.Plugins['future-plugin'].Enabled -and
        $plugins.Plugins['future-plugin'].Options['account'] -ceq '測試=team;#，') 'Normalization must detach the plugin dictionary, configurations and options.'
    Write-Output 'PASS: plugin INI roundtrip preserves unknown IDs, case-insensitive keys, Unicode, punctuation and equals; options-only sections opt out; normalization is detached.'

    $padded = New-Settings
    $account = New-Plugin
    $account.Enabled = $true
    $account.Options['GitHubHost'] = ' github.com '
    $account.Options['GitHubUser'] = ' someone '
    $padded.Plugins['copilot'] = $account
    $applied = $store.GetMethod('Save', $flags).Invoke($null, @($padded, $false))
    Assert-Condition ($null -ne $applied -and
        $applied.Plugins['copilot'].Options['GitHubHost'] -ceq 'github.com' -and
        $applied.Plugins['copilot'].Options['GitHubUser'] -ceq 'someone' -and
        $applied.Plugins['copilot'].Options['GitHubUser'] -ceq (Load-Settings).Settings.Plugins['copilot'].Options['GitHubUser'] -and
        $padded.Plugins['copilot'].Options['GitHubUser'] -ceq ' someone ') 'Save must return the normalized settings it persisted without mutating input; live account selection must match restart.'
    Write-Output 'PASS: Save returns normalized account options for immediate application, matching the INI without mutating input.'

    $settings.Plugins = $plugins.Plugins
    $copy = $settings.Clone()
    Assert-Condition ($copy.Edge -eq $settings.Edge -and $copy.MonitorDeviceName -ceq $settings.MonitorDeviceName -and
        $copy.HideDelayMilliseconds -eq $settings.HideDelayMilliseconds -and
        $copy.AlwaysMakeRemoteDesktopSessionFullscreen -eq $settings.AlwaysMakeRemoteDesktopSessionFullscreen -and
        ($copy.CapturedProcesses -join '|') -ceq ($settings.CapturedProcesses -join '|') -and
        $copy.Plugins.Count -eq $settings.Plugins.Count) 'Clone must include all scalar, capture and plugin settings.'
    Assert-Condition (-not [object]::ReferenceEquals($copy.CapturedProcesses, $settings.CapturedProcesses) -and
        -not [object]::ReferenceEquals($copy.Plugins, $settings.Plugins)) 'Clone must detach the capture list and plugin dictionary.'
    foreach ($id in $settings.Plugins.Keys) {
        Assert-Condition (-not [object]::ReferenceEquals($copy.Plugins[$id], $settings.Plugins[$id]) -and
            -not [object]::ReferenceEquals($copy.Plugins[$id].Options, $settings.Plugins[$id].Options)) 'Clone must detach every plugin configuration and option dictionary.'
    }
    $copy.Edge = [Enum]::Parse($assembly.GetType('EdgeSwitch.ToolbarEdge'), 'Left')
    $copy.MonitorDeviceName = 'changed'
    $copy.HideDelayMilliseconds = 200
    $copy.AlwaysMakeRemoteDesktopSessionFullscreen = $true
    $copy.CapturedProcesses.Clear()
    $copy.Plugins['FUTURE-PLUGIN'].Enabled = $false
    $copy.Plugins['FUTURE-PLUGIN'].Options['ACCOUNT'] = 'changed'
    $copy.Plugins['options_only'].Options['AddedDefault'] = 'default in working copy only'
    $copy.Plugins.Remove('OPTIONS_ONLY') | Out-Null
    $copy.Plugins['new-plugin'] = New-Plugin
    Assert-Condition ($settings.Edge.ToString() -eq 'RightBottom' -and $settings.MonitorDeviceName -ceq '\\.\DISPLAY9' -and
        $settings.HideDelayMilliseconds -eq 1234 -and -not $settings.AlwaysMakeRemoteDesktopSessionFullscreen -and
        $settings.CapturedProcesses.Count -eq 3 -and $settings.Plugins.Count -eq 2 -and
        $settings.Plugins['future-plugin'].Enabled -and $settings.Plugins['future-plugin'].Options['account'] -ceq '測試=team;#，' -and
        $settings.Plugins['options_only'].Options.Count -eq 1 -and -not $settings.Plugins.ContainsKey('new-plugin')) 'Discarding a changed settings clone (Cancel) must leave every original setting and collection unchanged.'
    Write-Output 'PASS: clone copies all settings deeply; cancellation and working-copy defaults never mutate the original.'

    $partial = Read-Ini " ; comment`n[toolbar]`nMaXiMiZeOnActivate=false`nFutureKey=ignored`n[FutureSection]`nAnything=ignored"
    Assert-Condition (-not $partial.AlwaysMakeRemoteDesktopSessionFullscreen -and
        ($partial.CapturedProcesses -join '|') -eq ($defaults.CapturedProcesses -join '|')) 'Missing capture section should retain defaults; explicit false should override.'
    Assert-Condition ($partial.Plugins.Count -eq 0 -and (Read-Ini '[Plugins]').Plugins.Count -eq 0) 'Missing or empty plugin sections must not enable a plugin.'
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
        "[CapturedProcesses]`nnotanindex=mstsc", "[CapturedProcesses]`n0=", "[CapturedProcesses]`n0=*.exe",
        "[Plugins]`nexample=true`nEXAMPLE=false", "[Plugins]`nexample=true`n[plugins]`nExample=true",
        "[Plugins]`nexample=1", "[Plugins]`nbad.id=true", "[Plugins]`nexample=", "[Plugins]`n=true",
        "[Plugin.example]`nHost=first`nHOST=second", "[Plugin.example]`nHost=first`n[plugin.EXAMPLE]`nhost=second",
        "[Plugin.bad.id]`nHost=x", "[Plugin.]", "[Plugin.example]`nbad.key=value",
        "[Plugin.example]`nHost=value`0injected", "[Plugins]`n$('x' * 65)=true",
        "[Plugin.example]`n$('x' * 65)=value"
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

    foreach ($mutate in @(
        { param($candidate) $candidate.Plugins = $null },
        { param($candidate) $candidate.Plugins['example'] = $null },
        { param($candidate) $candidate.Plugins['example'].Options = $null },
        { param($candidate) $candidate.Plugins['bad.id'] = New-Plugin },
        { param($candidate) $candidate.Plugins[''] = New-Plugin },
        { param($candidate) $candidate.Plugins[('x' * 65)] = New-Plugin },
        { param($candidate) $candidate.Plugins['example'].Options['bad.key'] = 'value' },
        { param($candidate) $candidate.Plugins['example'].Options[''] = 'value' },
        { param($candidate) $candidate.Plugins['example'].Options[('x' * 65)] = 'value' },
        { param($candidate) $candidate.Plugins['example'].Options.GetType().GetMethod('Add').Invoke($candidate.Plugins['example'].Options, @('Unsafe', $null)) },
        { param($candidate) $candidate.Plugins['example'].Options['Unsafe'] = "value`n[Plugins]`nother=true" },
        { param($candidate) $candidate.Plugins['example'].Options['Unsafe'] = "value`rkey=injected" },
        { param($candidate) $candidate.Plugins['example'].Options['Unsafe'] = "value`0injected" },
        { param($candidate) $candidate.Plugins['example'].Options['Unsafe'] = "value$([char]0x2028)injected" },
        { param($candidate)
            $candidate.Plugins = [Activator]::CreateInstance($candidate.Plugins.GetType())
            $candidate.Plugins.Add('example', (New-Plugin))
            $candidate.Plugins.Add('EXAMPLE', (New-Plugin))
        },
        { param($candidate)
            $candidate.Plugins['example'].Options = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
            $candidate.Plugins['example'].Options.Add('Host', 'first')
            $candidate.Plugins['example'].Options.Add('HOST', 'second')
        }
    )) {
        $candidate = New-Settings
        $candidate.Plugins['example'] = New-Plugin
        & $mutate $candidate
        Assert-RejectedSave $candidate
    }
    $trimmedPlugin = New-Settings
    $trimmedPlugin.Plugins['example'] = New-Plugin
    $trimmedPlugin.Plugins['example'].Options['Value'] = '  測試=team;#，  '
    Save-Settings $trimmedPlugin
    Assert-Condition ((Load-Settings).Settings.Plugins['EXAMPLE'].Options['VALUE'] -ceq '測試=team;#，' -and
        $trimmedPlugin.Plugins['example'].Options['Value'] -ceq '  測試=team;#，  ') 'Saving plugin values must trim only the detached persisted copy, preserving Unicode and equals.'
    Save-Settings $settings
    $previousContent = [IO.File]::ReadAllText($iniPath)
    Write-Output 'PASS: invalid/null/duplicate plugin settings and multiline/NUL injection are rejected without altering the previous INI; save normalization leaves input options untouched.'

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
