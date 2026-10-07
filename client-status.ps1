#Requires -Version 5.1
<#
.SYNOPSIS
    Concise client-side diagnostic for a DSJumper-configured machine.

.DESCRIPTION
    Reports whether DSJumper is reachable (transport, not just a listening port)
    and whether local clients are configured to use it. Read-only: it never
    changes settings and never touches the production proxy core.

    It reuses the existing status.ps1 for health/transport so the health logic
    is not duplicated.

.PARAMETER DeepSeekCheck
    Runs the optional paid DeepSeek smoke test (via status.ps1). Requires
    DEEPSEEK_API_KEY; the key is never printed.
#>
[CmdletBinding()]
param(
    [int]$HttpPort = 0,
    [int]$SocksPort = 0,

    [string]$ConfigDir,
    [string]$StatePath,
    [string]$SettingsPath,
    [string]$StatusScript,

    [string]$GitExe = 'git',

    [ValidateSet('User', 'Process', 'Machine')]
    [string]$EnvScope = 'User',

    [switch]$DeepSeekCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $PWD.Path }
$scriptDir = Split-Path -Parent $scriptPath
$commonFile = Join-Path (Join-Path $scriptDir 'client-config') 'ClientCommon.ps1'
. $commonFile

if ([string]::IsNullOrWhiteSpace($ConfigDir)) { $ConfigDir = Join-Path $scriptDir 'client-config' }
if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = Join-Path $ConfigDir 'state.json' }
if ([string]::IsNullOrWhiteSpace($StatusScript)) { $StatusScript = Join-Path $scriptDir 'status.ps1' }

$defaults = Get-ClientDefaults -ConfigDir $ConfigDir
$targets = Get-ClientTargets -Defaults $defaults -HttpPort $HttpPort -SocksPort $SocksPort
if ([string]::IsNullOrWhiteSpace($SettingsPath)) { $SettingsPath = Get-DefaultVscodeSettingsPath -Defaults $defaults }
if ($targets.EnableAllProxy) {
    $targets.EnvironmentMap['ALL_PROXY'] = $targets.SocksProxyUrl
    $targets.EnvironmentMap['all_proxy'] = $targets.SocksProxyUrl
}

function Convert-ComponentToClientState {
    param([string]$State)
    switch ($State) {
        'HEALTHY'   { return 'PASS' }
        'UNMANAGED' { return 'PASS' }
        'STARTING'  { return 'PARTIAL' }
        default     { return 'FAIL' }
    }
}

# ---------------------------------------------------------------------------
# DSJumper reachability via status.ps1
# ---------------------------------------------------------------------------
$snapshotArguments = @{}
if ($DeepSeekCheck) { $snapshotArguments['ExtraArguments'] = @('-DeepSeekCheck') }
$snapshot = Get-StatusSnapshot -StatusScript $StatusScript -HttpPort $targets.HttpPort -SocksPort $targets.SocksPort @snapshotArguments

$httpStatus = if ($snapshot.Available) { Convert-ComponentToClientState $snapshot.HttpState } else { 'FAIL' }
$socksStatus = if ($snapshot.Available) { Convert-ComponentToClientState $snapshot.SocksState } else { 'FAIL' }
$transportStatus = if ($snapshot.HttpTransport -in @('PASS', 'PARTIAL')) { 'PASS' } else { 'FAIL' }

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
$envConflict = $false
$envOk = 0
$envTotal = 0
foreach ($name in $targets.EnvironmentMap.Keys) {
    $envTotal++
    $current = Get-EnvValue -Name $name -Scope $EnvScope
    $target = [string]$targets.EnvironmentMap[$name]
    if ($current -eq $target) { $envOk++ }
    elseif (-not [string]::IsNullOrWhiteSpace($current)) { $envConflict = $true }
}
if ($envConflict) { $environmentState = 'CONFLICT' }
elseif ($envTotal -gt 0 -and $envOk -eq $envTotal) { $environmentState = 'CONFIGURED' }
elseif ($envOk -gt 0) { $environmentState = 'PARTIAL' }
else { $environmentState = 'NOT_CONFIGURED' }

# ---------------------------------------------------------------------------
# Git
# ---------------------------------------------------------------------------
if (-not (Get-Command $GitExe -ErrorAction SilentlyContinue)) {
    $gitState = 'NOT INSTALLED'
} else {
    $gitAllSet = $true
    $gitAnySet = $false
    $gitConflict = $false
    foreach ($key in $targets.GitMap.Keys) {
        $current = Get-GitProxyValue -GitExe $GitExe -Key $key
        $target = [string]$targets.GitMap[$key]
        if ($current -eq $target) { $gitAnySet = $true }
        elseif ([string]::IsNullOrWhiteSpace($current)) { $gitAllSet = $false }
        else { $gitConflict = $true; $gitAllSet = $false }
    }
    if ($gitConflict) { $gitState = 'CONFLICT' }
    elseif ($gitAnySet -and $gitAllSet) { $gitState = 'CONFIGURED' }
    elseif (-not $gitAnySet) { $gitState = 'NOT NEEDED' }
    else { $gitState = 'PARTIAL' }
}

# ---------------------------------------------------------------------------
# VS Code
# ---------------------------------------------------------------------------
$codeInstalled = [bool](Get-Command code -ErrorAction SilentlyContinue)
$settingsContent = Read-TextFileRaw -Path $SettingsPath
if (-not $codeInstalled -and $null -eq $settingsContent) {
    $vscodeState = 'NOT INSTALLED'
} else {
    $rawProxy = Get-JsoncKeyRaw -Content $settingsContent -Key 'http.proxy'
    $currentProxy = if ($rawProxy) { $rawProxy.Trim('"') } else { $null }
    if ($currentProxy -eq $targets.HttpProxyUrl) { $vscodeState = 'CONFIGURED' }
    elseif (-not [string]::IsNullOrWhiteSpace($currentProxy)) { $vscodeState = 'CONFLICT' }
    elseif ($environmentState -in @('CONFIGURED', 'PARTIAL')) { $vscodeState = 'ENV-ONLY' }
    else { $vscodeState = 'NOT_CONFIGURED' }
}

# ---------------------------------------------------------------------------
# DeepSeek API
# ---------------------------------------------------------------------------
if ($DeepSeekCheck) {
    $classification = 'FAIL'
    $match = [regex]::Match([string]$snapshot.Raw, 'DeepSeek check\s*:\s*(?<value>.+)')
    if ($match.Success) {
        $text = $match.Groups['value'].Value
        if ($text -match 'SKIPPED') { $classification = 'NOT TESTED' }
        elseif ($text -match 'PASS') { $classification = 'PASS' }
        elseif ($text -match 'AUTH') { $classification = 'AUTH (401)' }
        elseif ($text -match 'FORBIDDEN') { $classification = 'FORBIDDEN (403)' }
        elseif ($text -match 'RATE') { $classification = 'RATE (429)' }
        elseif ($text -match 'SERVER') { $classification = 'SERVER (5xx)' }
    }
    $deepSeekState = $classification
} else {
    $deepSeekState = 'NOT TESTED'
}

# ---------------------------------------------------------------------------
# Overall
# ---------------------------------------------------------------------------
if (-not $snapshot.Available -or $httpStatus -eq 'FAIL' -or $transportStatus -eq 'FAIL') {
    $overall = 'UNREACHABLE'
} elseif ($environmentState -eq 'CONFLICT' -or $gitState -eq 'CONFLICT' -or $vscodeState -eq 'CONFLICT') {
    $overall = 'CONFLICT'
} elseif ($environmentState -eq 'CONFIGURED' -and
        $vscodeState -in @('CONFIGURED', 'ENV-ONLY', 'NOT INSTALLED') -and
        $gitState -in @('CONFIGURED', 'NOT NEEDED', 'NOT INSTALLED')) {
    $overall = 'READY'
} elseif ($environmentState -eq 'NOT_CONFIGURED' -and $vscodeState -eq 'NOT_CONFIGURED') {
    $overall = 'NOT_CONFIGURED'
} else {
    $overall = 'PARTIAL'
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host 'DSJumper Client Status'
Write-Host ''
Write-Host ("{0,-18} {1,-12} {2}" -f 'DSJumper HTTP', $httpStatus, $targets.HttpAddress)
Write-Host ("{0,-18} {1,-12} {2}" -f 'DSJumper SOCKS', $socksStatus, $targets.SocksAddress)
Write-Host ("{0,-18} {1,-12}" -f 'HTTPS transport', $transportStatus)
Write-Host ("{0,-18} {1,-12}" -f 'Environment', $environmentState)
Write-Host ("{0,-18} {1,-12}" -f 'Git', $gitState)
Write-Host ("{0,-18} {1,-12}" -f 'VS Code', $vscodeState)
Write-Host ("{0,-18} {1,-12}" -f 'DeepSeek API', $deepSeekState)
Write-Host ''
Write-Host ("{0,-18} {1}" -f 'Overall', $overall)

if ($snapshot.Available) {
    $egress = if ($snapshot.HttpEgress) { $snapshot.HttpEgress } else { 'unknown' }
    Write-Host ''
    Write-Host ("  DSJumper state: HTTP=$($snapshot.HttpState) SOCKS=$($snapshot.SocksState); egress=$egress")
    if ($snapshot.HttpState -eq 'UNMANAGED') { Write-Host '  Note: HTTP listener works but is outside the expected supervisor tree.' }
    if ($snapshot.HttpState -eq 'STARTING') { Write-Host '  Note: HTTP listener is not ready yet.' }
} else {
    Write-Host ''
    Write-Host ("  status.ps1 was not available at {0}" -f $StatusScript)
}

if ($environmentState -eq 'NOT_CONFIGURED') { Write-Host '  Hint: run .\install-client.ps1 to configure clients.' }
if ($environmentState -eq 'PARTIAL') { Write-Host '  Hint: run .\install-client.ps1 to complete client configuration.' }
if ($overall -eq 'UNREACHABLE') { Write-Host '  Hint: the DSJumper proxy core is not passing transport; check status.ps1.' }
Write-Host ''

switch ($overall) {
    'READY'          { exit 0 }
    'UNREACHABLE'    { exit 2 }
    default          { exit 1 }
}
