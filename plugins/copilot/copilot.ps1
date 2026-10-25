#requires -Version 7.0
# Dot-source to use the parser without credentials or network IO.
function Get-CopilotProperty($Value, [string]$Name) {
    if ($Value -is [System.Collections.IDictionary]) { return $Value[$Name] }
    if ($Value -is [pscustomobject]) { return $Value.PSObject.Properties[$Name].Value }
    return $null
}

function Get-CopilotNumber($Value) {
    # Do not let PowerShell coerce null, booleans or strings into quota numbers.
    if ($Value -isnot [byte] -and $Value -isnot [sbyte] -and
        $Value -isnot [int16] -and $Value -isnot [uint16] -and
        $Value -isnot [int32] -and $Value -isnot [uint32] -and
        $Value -isnot [int64] -and $Value -isnot [uint64] -and
        $Value -isnot [single] -and $Value -isnot [double] -and $Value -isnot [decimal]) {
        return $null
    }
    try { return [decimal]$Value } catch { return $null }
}

function Test-CopilotHost($Value) {
    if ($Value -isnot [string] -or $Value.Length -gt 253) { return $false }
    if ($Value -ieq 'github.com') { return $true }
    return $Value -imatch '\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+ghe\.com\z'
}

function Test-CopilotUsername($Value) {
    # EMU logins include an underscore and enterprise shortcode.
    return $Value -is [string] -and $Value -cmatch '\A[A-Za-z0-9][A-Za-z0-9_-]{0,99}\z'
}

function Assert-CopilotAccount($Identity, [string]$Username) {
    $login = Get-CopilotProperty $Identity 'login'
    if (-not (Test-CopilotUsername $login) -or
        -not [string]::Equals($login, $Username, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The selected GitHub credential belongs to a different account. Check GitHub username and gh auth status.'
    }
}

function New-CopilotResponse([string]$Text, [string]$Detail, [string]$Account, [DateTimeOffset]$FetchedAt) {
    $timestamp = $FetchedAt.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'", [Globalization.CultureInfo]::InvariantCulture)
    $lines = @()
    if ($Account) { $lines += $Account }
    $lines += $Detail
    $lines += "Fetched: $timestamp"
    return [pscustomobject]@{ protocolVersion = 1; text = $Text; toolTip = $lines -join "`n" }
}

function Get-CopilotReset($Quota, $Snapshot) {
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $date = Get-CopilotProperty $Quota 'quota_reset_date'
    # Some ConvertFrom-Json versions materialize ISO timestamps as DateTime values.
    if ($date -is [DateTimeOffset]) {
        return $date.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'", $invariant)
    }
    if ($date -is [DateTime] -and $date.Kind -ne [DateTimeKind]::Unspecified) {
        return $date.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'", $invariant)
    }
    if ($date -is [string]) {
        $parsed = [DateTimeOffset]::MinValue
        if ($date -cmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z' -and
            [DateTimeOffset]::TryParseExact($date, 'yyyy-MM-dd', $invariant,
                [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
            return $parsed.ToString('yyyy-MM-dd', $invariant)
        }
        if ($date -cmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,7})?(?:Z|[+-][0-9]{2}:[0-9]{2})\z' -and
            [DateTimeOffset]::TryParse($date, $invariant, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss 'UTC'", $invariant)
        }
    }
    foreach ($source in @($Snapshot, $Quota)) {
        $seconds = Get-CopilotNumber (Get-CopilotProperty $source 'quota_reset_at')
        if ($null -ne $seconds -and $seconds -gt 0 -and $seconds -le 253402300799 -and
            [decimal]::Truncate($seconds) -eq $seconds) {
            return [DateTimeOffset]::FromUnixTimeSeconds([long]$seconds).ToString("yyyy-MM-dd HH:mm:ss 'UTC'", $invariant)
        }
    }
    return 'unknown (not supplied by GitHub)'
}

function ConvertFrom-CopilotQuota($Quota, [string]$Username, [string]$GitHubHost,
    [DateTimeOffset]$FetchedAt = [DateTimeOffset]::UtcNow) {
    $account = "$Username@$GitHubHost"
    $snapshot = Get-CopilotProperty (Get-CopilotProperty $Quota 'quota_snapshots') 'premium_interactions'
    $reset = Get-CopilotReset $Quota $snapshot
    $unknown = "GitHub did not provide a usable AI-credit quota. The undocumented quota API may have changed.`nQuota reset: $reset"
    $hasQuota = Get-CopilotProperty $snapshot 'has_quota'
    $tokenBilling = Get-CopilotProperty $snapshot 'token_based_billing'
    $unlimited = Get-CopilotProperty $snapshot 'unlimited'
    if ($hasQuota -isnot [bool] -or $tokenBilling -isnot [bool] -or $unlimited -isnot [bool]) {
        return New-CopilotResponse 'Unavailable' $unknown $account $FetchedAt
    }
    if (-not $tokenBilling) {
        return New-CopilotResponse 'Unavailable' "This account reports a legacy request quota, not an AI-credit quota.`nQuota reset: $reset" $account $FetchedAt
    }
    if ($unlimited) {
        return New-CopilotResponse 'Unlimited' "GitHub reports unlimited AI credits; no percentage applies.`nQuota reset: $reset" $account $FetchedAt
    }
    $used = Get-CopilotNumber (Get-CopilotProperty $snapshot 'credits_used')
    $allowance = Get-CopilotNumber (Get-CopilotProperty $snapshot 'entitlement')
    if (-not $hasQuota -or $null -eq $used -or $null -eq $allowance -or $used -lt 0 -or $allowance -le 0) {
        return New-CopilotResponse 'Unavailable' $unknown $account $FetchedAt
    }
    try { $percentage = ($used / $allowance) * [decimal]100 }
    catch { return New-CopilotResponse 'Unavailable' $unknown $account $FetchedAt }
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    $text = $percentage.ToString('F1', $invariant) + '%'
    $usage = $used.ToString('#,0.############################', $invariant)
    $limit = $allowance.ToString('#,0.############################', $invariant)
    return New-CopilotResponse $text "$usage / $limit AI credits used`nQuota reset: $reset" $account $FetchedAt
}

function Clear-CopilotTokens {
    foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')) {
        [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
    }
}

function Invoke-CopilotGh([string]$Executable, [string[]]$Arguments) {
    # Keep native stderr private so GitHub errors cannot expose credentials.
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Could not start GitHub CLI.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        # Drain both pipes concurrently; never surface raw GitHub errors or credentials.
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'GitHub CLI request failed.' }
        return $output
    } finally {
        $process.Dispose()
    }
}

function Invoke-CopilotRequest($Request) {
    $account = ''
    $token = $null
    $stageMessage = 'Invalid plugin request. Configure a GitHub host and an explicit GitHub username.'
    try {
        $version = Get-CopilotNumber (Get-CopilotProperty $Request 'protocolVersion')
        if ($null -eq $version -or $version -ne 1) { throw 'Unsupported protocol.' }
        $settings = Get-CopilotProperty $Request 'settings'
        $githubHost = Get-CopilotProperty $settings 'GitHubHost'
        $username = Get-CopilotProperty $settings 'GitHubUser'
        $stageMessage = 'GitHub host must be github.com or a hostname under ghe.com, without a URL, path or port.'
        if (-not (Test-CopilotHost $githubHost)) { throw 'Invalid host.' }
        $stageMessage = 'Set an explicit GitHub username (including the enterprise shortcode for a managed user).'
        if (-not (Test-CopilotUsername $username)) { throw 'Invalid username.' }
        $githubHost = $githubHost.ToLowerInvariant()
        $account = "$username@$githubHost"
        Clear-CopilotTokens
        # gh must use stored credentials for this specific account, never inherited tokens.
        [Environment]::SetEnvironmentVariable('GH_PROMPT_DISABLED', '1', [EnvironmentVariableTarget]::Process)
        $stageMessage = 'GitHub CLI (gh) is unavailable. Install it and sign in with gh auth login for the configured host and account.'
        $gh = (Get-Command gh.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $stageMessage = 'No stored credential is available for this GitHub host and username. Sign in with gh auth login and check gh auth status.'
        $token = (Invoke-CopilotGh $gh @('auth', 'token', '--hostname', $githubHost, '--user', $username)).Trim()
        if ([string]::IsNullOrWhiteSpace($token) -or $token -match '\s') { throw 'No usable credential.' }
        # Set both families: gh routes ghe.com hosts through its enterprise auth path.
        foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')) {
            [Environment]::SetEnvironmentVariable($name, $token, [EnvironmentVariableTarget]::Process)
        }
        $stageMessage = 'GitHub could not verify the selected account. Check sign-in, network access and enterprise authorization.'
        $identity = (Invoke-CopilotGh $gh @('api', '--hostname', $githubHost, '/user')) | ConvertFrom-Json -ErrorAction Stop
        $stageMessage = 'The selected GitHub credential belongs to a different account. Check GitHub username and gh auth status.'
        Assert-CopilotAccount $identity $username
        $stageMessage = 'Copilot AI-credit quota is unavailable. Check Copilot entitlement and enterprise authorization; the undocumented GitHub API may have changed.'
        $quota = (Invoke-CopilotGh $gh @('api', '--hostname', $githubHost, '/copilot_internal/user')) | ConvertFrom-Json -ErrorAction Stop
        return ConvertFrom-CopilotQuota $quota $username $githubHost
    } catch {
        return New-CopilotResponse 'Unavailable' $stageMessage $account ([DateTimeOffset]::UtcNow)
    } finally {
        Clear-CopilotTokens
        $token = $null
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    try {
        $request = [Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
        $response = Invoke-CopilotRequest $request
    } catch {
        $response = New-CopilotResponse 'Unavailable' 'Invalid plugin request or unexpected plugin failure.' '' ([DateTimeOffset]::UtcNow)
    }
    [Console]::Out.WriteLine(($response | ConvertTo-Json -Compress -Depth 4))
}
