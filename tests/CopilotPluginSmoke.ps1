#requires -Version 7.0
# Run without a build or GitHub sign-in:
# pwsh.exe -NoProfile -NonInteractive -File tests/CopilotPluginSmoke.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../plugins/copilot/copilot.ps1')

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-Quota {
    return @'
{"quota_reset_date":"2026-11-01","quota_snapshots":{"premium_interactions":{"credits_used":29326,"entitlement":1000000,"has_quota":true,"overage_count":0,"percent_remaining":17,"quota_remaining":42,"quota_reset_at":0,"token_based_billing":true,"unlimited":false}}}
'@ | ConvertFrom-Json
}

$fetched = [DateTimeOffset]::Parse('2026-10-26T09:05:28+00:00', [Globalization.CultureInfo]::InvariantCulture)
function Read-Quota($Quota) {
    return ConvertFrom-CopilotQuota $Quota 'reader_enterprise' 'example.ghe.com' $fetched
}

function Assert-Unavailable($Quota, [string]$Message) {
    $response = Read-Quota $Quota
    Assert-Condition ($response.text -ceq 'Unavailable' -and $response.protocolVersion -eq 1) $Message
}

$originalCulture = [Threading.Thread]::CurrentThread.CurrentCulture
$originalUICulture = [Threading.Thread]::CurrentThread.CurrentUICulture
try {
    foreach ($culture in @('en-US', 'de-DE', 'ar-SA')) {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
        [Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
        $response = Read-Quota (New-Quota)
        Assert-Condition ($response.text -ceq '2.9%') "Screenshot calculation or invariant percentage failed in $culture."
        Assert-Condition ($response.toolTip.Contains('29,326 / 1,000,000 AI credits used')) "Invariant usage/allowance failed in $culture."
        Assert-Condition ($response.toolTip.Contains('reader_enterprise@example.ghe.com')) 'Tooltip lost the selected account and host.'
        Assert-Condition ($response.toolTip.Contains('Quota reset: 2026-11-01')) 'Tooltip lost the supplied reset date.'
        Assert-Condition ($response.toolTip.Contains('Fetched: 2026-10-26 09:05:28 UTC')) 'Tooltip lost the UTC fetched timestamp.'
        $wire = $response | ConvertTo-Json -Compress | ConvertFrom-Json
        Assert-Condition ($wire.protocolVersion -eq 1 -and $wire.text -ceq '2.9%' -and $wire.toolTip -ceq $response.toolTip) 'Response must survive the process JSON protocol.'
    }
    Write-Output 'PASS: screenshot percentage, account, reset, timestamp and JSON remain invariant across cultures.'

    $quota = New-Quota
    $quota.quota_snapshots.premium_interactions.credits_used = 0
    Assert-Condition ((Read-Quota $quota).text -ceq '0.0%') 'Zero usage is a real zero, not unavailable.'
    $quota.quota_snapshots.premium_interactions.credits_used = 1250000
    Assert-Condition ((Read-Quota $quota).text -ceq '125.0%') 'Overage must not be clamped to 100 percent.'
    $quota.quota_snapshots.premium_interactions.credits_used = 2.5
    $quota.quota_snapshots.premium_interactions.entitlement = 10
    $response = Read-Quota $quota
    Assert-Condition ($response.text -ceq '25.0%' -and $response.toolTip.Contains('2.5 / 10 AI credits')) 'Numeric fractional credits must remain numeric and invariant.'
    Write-Output 'PASS: zero usage, overage and fractional credits.'

    foreach ($value in @(0, -1, $null, '1000000', 'bad', $true, [double]::NaN, [double]::PositiveInfinity, @{}, @(1, 2))) {
        $quota = New-Quota
        $quota.quota_snapshots.premium_interactions.entitlement = $value
        Assert-Unavailable $quota 'A zero, negative, null, string or malformed allowance must not produce a percentage.'
    }
    foreach ($value in @(-1, $null, '29326', 'bad', $false, [double]::NaN, [double]::NegativeInfinity, @{}, @(1, 2))) {
        $quota = New-Quota
        $quota.quota_snapshots.premium_interactions.credits_used = $value
        Assert-Unavailable $quota 'Negative, null, string or malformed usage must not produce a percentage.'
    }
    foreach ($field in @('credits_used', 'entitlement')) {
        $quota = New-Quota
        $quota.quota_snapshots.premium_interactions.PSObject.Properties.Remove($field)
        Assert-Unavailable $quota "Missing $field must not be coerced into a quota."
    }
    foreach ($json in @('null', '{}', '{"quota_snapshots":null}', '{"quota_snapshots":{}}',
        '{"quota_snapshots":{"premium_interactions":null}}', '{"quota_snapshots":{"premium_interactions":"bad"}}')) {
        Assert-Unavailable ($json | ConvertFrom-Json) 'Missing or malformed quota snapshots must be unavailable.'
    }
    Write-Output 'PASS: invalid numeric fields and missing quota snapshots never invent a percentage.'

    foreach ($field in @('has_quota', 'token_based_billing', 'unlimited')) {
        foreach ($value in @($null, 'true', 'false', 0, 1)) {
            $quota = New-Quota
            $quota.quota_snapshots.premium_interactions.$field = $value
            Assert-Unavailable $quota "Null or nonboolean $field must be unavailable."
        }
        $quota = New-Quota
        $quota.quota_snapshots.premium_interactions.PSObject.Properties.Remove($field)
        # Root-level flags must not hide missing snapshot-level fields.
        $quota | Add-Member -NotePropertyName $field -NotePropertyValue $true
        Assert-Unavailable $quota "Missing snapshot-level $field must be unavailable."
    }
    $quota = New-Quota
    $quota.quota_snapshots.premium_interactions.has_quota = $false
    Assert-Unavailable $quota 'has_quota=false must not display a percentage.'
    $quota = New-Quota
    $quota.quota_snapshots.premium_interactions.token_based_billing = $false
    $response = Read-Quota $quota
    Assert-Condition ($response.text -ceq 'Unavailable' -and $response.toolTip.Contains('not an AI-credit quota')) 'Legacy request quotas must be explained, not mislabelled as AI credits.'
    $quota = New-Quota
    $quota.quota_snapshots.premium_interactions.unlimited = $true
    $quota.quota_snapshots.premium_interactions.has_quota = $false
    $quota.quota_snapshots.premium_interactions.entitlement = 0
    $quota.quota_snapshots.premium_interactions.credits_used = $null
    $response = Read-Quota $quota
    Assert-Condition ($response.text -ceq 'Unlimited' -and -not $response.text.Contains('%')) 'Explicit unlimited must not divide by zero or show a percentage.'
    Write-Output 'PASS: strict snapshot booleans, legacy quotas and unlimited accounts.'

    foreach ($date in @($null, '', '2026-02-30', '11/01/2026', '2026-11-01T00:00:00', 'secret server error')) {
        $quota = New-Quota
        $quota.quota_reset_date = $date
        $response = Read-Quota $quota
        Assert-Condition ($response.toolTip.Contains('Quota reset: unknown (not supplied by GitHub)')) 'Invalid or missing reset dates must be explicitly unknown.'
        Assert-Condition (-not $response.toolTip.Contains('secret server error')) 'Raw reset values must never leak into the tooltip.'
    }
    $quota = New-Quota
    $quota.PSObject.Properties.Remove('quota_reset_date')
    $reset = [DateTimeOffset]::Parse('2026-11-01T00:00:00Z', [Globalization.CultureInfo]::InvariantCulture)
    $quota.quota_snapshots.premium_interactions.quota_reset_at = $reset.ToUnixTimeSeconds()
    Assert-Condition ((Read-Quota $quota).toolTip.Contains('Quota reset: 2026-11-01 00:00:00 UTC')) 'Valid Unix reset seconds must be used.'
    foreach ($seconds in @(0, -1, '1793491200', 1.5, 253402300800, $null)) {
        $quota.quota_snapshots.premium_interactions.quota_reset_at = $seconds
        Assert-Condition ((Read-Quota $quota).toolTip.Contains('Quota reset: unknown')) 'Invalid Unix timestamps must remain unknown.'
    }
    $quota = New-Quota
    $quota.quota_reset_date = '2026-11-01T01:00:00+01:00'
    Assert-Condition ((Read-Quota $quota).toolTip.Contains('Quota reset: 2026-11-01 00:00:00 UTC')) 'ISO timestamps must normalize to UTC.'
    $quota = ($quota | ConvertTo-Json -Depth 5) | ConvertFrom-Json
    Assert-Condition ((Read-Quota $quota).toolTip.Contains('Quota reset: 2026-11-01 00:00:00 UTC')) 'JSON timestamp materialization must preserve the reset date.'
    foreach ($typedDate in @($reset, $reset.UtcDateTime)) {
        $quota.quota_reset_date = $typedDate
        Assert-Condition ((Read-Quota $quota).toolTip.Contains('Quota reset: 2026-11-01 00:00:00 UTC')) 'Typed timezone-aware reset dates must remain UTC.'
    }
    $quota.quota_reset_date = [DateTime]::SpecifyKind($reset.UtcDateTime, [DateTimeKind]::Unspecified)
    Assert-Condition ((Read-Quota $quota).toolTip.Contains('Quota reset: unknown')) 'A typed reset timestamp without a timezone is not trustworthy.'
    $quota = New-Quota
    $shiftedFetched = [DateTimeOffset]::Parse('2026-10-26T11:05:28+02:00', [Globalization.CultureInfo]::InvariantCulture)
    $response = ConvertFrom-CopilotQuota $quota 'reader' 'github.com' $shiftedFetched
    Assert-Condition ($response.toolTip.Contains('Fetched: 2026-10-26 09:05:28 UTC')) 'Fetched timestamps must normalize to UTC.'
    Write-Output 'PASS: reset validation, unknown reset values and UTC normalization.'

    foreach ($hostName in @('github.com', 'GITHUB.COM', 'example.ghe.com', 'unit-2.example.ghe.com', 'A.GHE.COM')) {
        Assert-Condition (Test-CopilotHost $hostName) "Valid GitHub host rejected: $hostName"
    }
    foreach ($hostName in @($null, '', 'ghe.com', 'api.github.com', 'github.com.evil.test', 'example.ghe.com.evil.test',
        'https://github.com', 'example.ghe.com/path', 'example.ghe.com:443', 'x@ghe.com', ' github.com', "github.com`n",
        '--hostname', '-bad.ghe.com', 'bad-.ghe.com', 'a..ghe.com', 'example.ghe.com.', 'a_b.ghe.com',
        (('a' * 64) + '.ghe.com'), 123)) {
        Assert-Condition (-not (Test-CopilotHost $hostName)) 'An unsafe or unsupported host was accepted.'
    }
    foreach ($username in @('reader', 'reader-name', 'reader_enterprise', 'Reader_Enterprise', 'a1')) {
        Assert-Condition (Test-CopilotUsername $username) "Valid GitHub username rejected: $username"
    }
    foreach ($username in @($null, '', '--user', '-reader', 'reader name', "reader`n", 'reader@example.com',
        'reader/path', 'reader;command', 'reader"', ' reader', ('a' * 101), 123)) {
        Assert-Condition (-not (Test-CopilotUsername $username)) 'An unsafe or missing username was accepted.'
    }
    Assert-CopilotAccount ('{"login":"READER_ENTERPRISE"}' | ConvertFrom-Json) 'reader_enterprise'
    foreach ($identity in @('{"login":"other_enterprise"}', '{"login":null}', '{}', '{"login":123}', '{"login":"reader_enterprise "}')) {
        $rejected = $false
        try { Assert-CopilotAccount ($identity | ConvertFrom-Json) 'reader_enterprise' }
        catch { $rejected = $true }
        Assert-Condition $rejected 'Mismatched or missing authenticated login must be rejected.'
    }
    Write-Output 'PASS: public and EMU hosts/logins, injection rejection and exact case-insensitive account matching.'
} finally {
    [Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
    [Threading.Thread]::CurrentThread.CurrentUICulture = $originalUICulture
}
Write-Output 'Copilot plugin smoke passed (parser only; no credentials, network requests or AI sessions).'
