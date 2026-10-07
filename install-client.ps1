#Requires -Version 5.1
<#
.SYNOPSIS
    Zero-friction, reversible client-side setup for a new Windows machine that
    should use the existing DSJumper loopback proxy (HTTP 3128 / SOCKS 1080).

.DESCRIPTION
    CLIENT-SIDE ONLY. This script never touches the DSJumper production core:
    it does not start/stop supervisors, listeners, scheduled tasks, SSH, or
    ports. It only configures how *local clients* reach the proxy:

      - user-level proxy environment variables (preserved and reversible)
      - global Git http.proxy / https.proxy (only when safe and verified)
      - VS Code user settings.json (only the keys DSJumper owns)

    It is idempotent: if a value is already correct it is left untouched, so
    re-running makes no unnecessary changes and does not rewrite files.

    Health is judged with the existing status.ps1 (transport probe), never by
    "a port is listening" alone.

    Previous values are saved to client-config/state.json (no secrets) so that
    uninstall-client.ps1 can restore them.

.PARAMETER DeepSeekCheck
    Also runs the optional paid DeepSeek smoke test via status.ps1. Off by
    default; requires DEEPSEEK_API_KEY and never prints the key.

.PARAMETER Force
    Replace conflicting values (not created by DSJumper) instead of leaving them
    alone. Previous values are still backed up for rollback.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
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

    [switch]$SkipEnvironment,
    [switch]$SkipGit,
    [switch]$SkipVsCode,
    [switch]$EnableAllProxy,
    [switch]$Force,
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
$backupDir = Join-Path $ConfigDir 'backup'

if ($EnableAllProxy -or $targets.EnableAllProxy) {
    $targets.EnvironmentMap['ALL_PROXY'] = $targets.SocksProxyUrl
    $targets.EnvironmentMap['all_proxy'] = $targets.SocksProxyUrl
}

$conflicts = New-Object System.Collections.Generic.List[string]
$changedEnvironment = New-Object System.Collections.Generic.List[string]
$changedGit = New-Object System.Collections.Generic.List[string]
$changedVscode = New-Object System.Collections.Generic.List[string]
$anyStateChange = $false

Write-Head 'DSJumper client installer (client-side only; production proxy untouched)'
Write-Host ("  proxy target : {0}" -f $targets.HttpProxyUrl)
Write-Host ("  SOCKS target : {0}" -f $targets.SocksProxyUrl)
Write-Host ("  state file   : {0}" -f $StatePath)
if ($WhatIfPreference) { Write-Warn 'WhatIf: no changes will be written.' }

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
Write-Head 'Preflight'

$psOk = ($PSVersionTable.PSVersion.Major -ge 5)
if ($psOk) { Write-Ok ("PowerShell {0}" -f $PSVersionTable.PSVersion) }
else { Write-Err 'PowerShell 5.1 or later is required.' }

$curlOk = [bool](Get-Command curl.exe -ErrorAction SilentlyContinue)
if ($curlOk) { Write-Ok 'curl.exe available (transport probes)' } else { Write-Warn 'curl.exe not found; transport probes limited.' }

if ($SkipGit) { Write-Skip 'Git step skipped by request.' }
elseif (Get-Command $GitExe -ErrorAction SilentlyContinue) { Write-Ok ("Git found: {0}" -f (Get-Command $GitExe).Source) }
else { Write-Warn 'Git not found; Git step will be skipped.' }

if ($SkipVsCode) { Write-Skip 'VS Code step skipped by request.' }
elseif (Get-Command code -ErrorAction SilentlyContinue) { Write-Ok ("VS Code found: {0}" -f (Get-Command code).Source) }
elseif ($SettingsPath -and (Test-Path -LiteralPath $SettingsPath)) { Write-Ok 'VS Code settings.json found.' }
else { Write-Warn 'VS Code not detected; VS Code step will be skipped.' }

# Health via the existing status.ps1 (transport, not just a listening port).
$snapshot = Get-StatusSnapshot -StatusScript $StatusScript -HttpPort $targets.HttpPort -SocksPort $targets.SocksPort
if (-not $snapshot.Available) {
    Write-Err "Could not run status.ps1 at $StatusScript."
    if (-not $Force) { Write-Host ''; Write-Host 'Aborting. Use -Force to configure clients anyway.'; exit 1 }
} else {
    Write-Host ("  DSJumper HTTP  : {0} (transport {1})" -f $snapshot.HttpState, $snapshot.HttpTransport)
    Write-Host ("  DSJumper SOCKS : {0} (transport {1})" -f $snapshot.SocksState, $snapshot.SocksTransport)
    $transportOk = ($snapshot.HttpTransport -in @('PASS', 'PARTIAL'))
    if (-not $transportOk) {
        Write-Err "DSJumper HTTP transport is not working (state=$($snapshot.HttpState), transport=$($snapshot.HttpTransport))."
        if (-not $Force) { Write-Host ''; Write-Host 'Aborting so clients are not pointed at a dead proxy. Use -Force to override.'; exit 1 }
        Write-Warn 'Continuing because -Force was supplied.'
    } else {
        Write-Ok 'DSJumper transport verified.'
    }
}

# ---------------------------------------------------------------------------
# Load existing state (preserve original previous values across re-runs)
# ---------------------------------------------------------------------------
$existingState = Read-ClientState -StatePath $StatePath
$state = @{
    version     = 1
    installedAt = if ($existingState) { Get-Prop $existingState 'installedAt' } else { (Get-Date -Format 'o') }
    updatedAt   = (Get-Date -Format 'o')
    scope       = $EnvScope
    environment = @{}
    git         = @{}
    vscode      = @{ settingsPath = $SettingsPath; fileExisted = $false; keys = @{} }
}
if ($existingState) {
    $prior = ConvertTo-HashtableDeep $existingState
    foreach ($section in @('environment', 'git')) {
        $records = Get-Prop $existingState $section
        if ($records) {
            foreach ($property in $records.PSObject.Properties) {
                $state[$section][$property.Name] = ConvertTo-HashtableDeep $property.Value
            }
        }
    }
    $priorVscode = Get-Prop $existingState 'vscode'
    if ($priorVscode) {
        $priorKeys = Get-Prop $priorVscode 'keys'
        if ($priorKeys) {
            foreach ($property in $priorKeys.PSObject.Properties) {
                $state.vscode.keys[$property.Name] = ConvertTo-HashtableDeep $property.Value
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 2. Environment variables
# ---------------------------------------------------------------------------
if ($SkipEnvironment) {
    Write-Head 'Environment variables'
    Write-Skip 'Skipped by request.'
} else {
    Write-Head ("Environment variables ($EnvScope scope)")
    foreach ($name in $targets.EnvironmentMap.Keys) {
        $target = [string]$targets.EnvironmentMap[$name]
        $current = Get-EnvValue -Name $name -Scope $EnvScope
        if ($current -eq $target) {
            Write-Skip "$name already $target"
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($current) -and -not $Force) {
            Write-Warn "$name already set to '$current' (unrelated); leaving unchanged. Use -Force to replace."
            $conflicts.Add("env:$name")
            continue
        }
        if (-not $state.environment.ContainsKey($name)) {
            $state.environment[$name] = @{
                hadValue = (-not [string]::IsNullOrWhiteSpace($current))
                previous = $current
                setValue = $target
            }
        }
        if ($PSCmdlet.ShouldProcess("$EnvScope environment variable $name", "set to $target")) {
            Set-EnvValue -Name $name -Value $target -Scope $EnvScope
            Write-Ok "$name = $target"
            $changedEnvironment.Add($name)
            $anyStateChange = $true
        }
    }
    if ($EnvScope -eq 'User' -and $changedEnvironment.Count -gt 0) {
        Write-Note 'New environment variables apply to newly launched processes (not this session).'
    }
}

# ---------------------------------------------------------------------------
# 3. Git
# ---------------------------------------------------------------------------
$gitChangedThisRun = New-Object System.Collections.Generic.List[string]
if ($SkipGit) {
    Write-Head 'Git'
    Write-Skip 'Skipped by request.'
} elseif (-not (Get-Command $GitExe -ErrorAction SilentlyContinue)) {
    Write-Head 'Git'
    Write-Skip 'Git is not installed; nothing to configure.'
} else {
    Write-Head 'Git (global http.proxy / https.proxy)'
    foreach ($key in $targets.GitMap.Keys) {
        $target = [string]$targets.GitMap[$key]
        $current = Get-GitProxyValue -GitExe $GitExe -Key $key
        if ($current -eq $target) {
            Write-Skip "$key already $target"
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($current) -and -not $Force) {
            Write-Warn "$key already set to '$current' (unrelated); leaving unchanged. Use -Force to replace."
            $conflicts.Add("git:$key")
            continue
        }
        if (-not $state.git.ContainsKey($key)) {
            $state.git[$key] = @{
                hadValue = (-not [string]::IsNullOrWhiteSpace($current))
                previous = $current
                setValue = $target
            }
        }
        if ($PSCmdlet.ShouldProcess("git config --global $key", "set to $target")) {
            if (Set-GitProxyValue -GitExe $GitExe -Key $key -Value $target) {
                Write-Ok "$key = $target"
                $gitChangedThisRun.Add($key)
                $changedGit.Add($key)
                $anyStateChange = $true
            } else {
                Write-Err "$key could not be set."
            }
        }
    }

    # Verify GitHub reachability through the resulting configuration.
    if ($gitChangedThisRun.Count -gt 0) {
        $probe = Test-GitHubViaProxy -ProxyUrl $targets.HttpProxyUrl
        if ($probe -and $probe.Ok) {
            Write-Ok "GitHub reachable through the proxy (HTTP $($probe.Code))."
        } else {
            Write-Warn 'GitHub verification failed; reverting Git proxy changes.'
            foreach ($key in $gitChangedThisRun) {
                $record = $state.git[$key]
                if ($record.hadValue) { [void](Set-GitProxyValue -GitExe $GitExe -Key $key -Value $record.previous) }
                else { [void](Remove-GitProxyValue -GitExe $GitExe -Key $key) }
                [void]$state.git.Remove($key)
                [void]$changedGit.Remove($key)
            }
            $conflicts.Add('git:verification')
        }
    }
}

# ---------------------------------------------------------------------------
# 4. VS Code
# ---------------------------------------------------------------------------
if ($SkipVsCode) {
    Write-Head 'VS Code'
    Write-Skip 'Skipped by request.'
} elseif ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    Write-Head 'VS Code'
    Write-Skip 'VS Code settings path could not be determined.'
} else {
    $codeInstalled = [bool](Get-Command code -ErrorAction SilentlyContinue)
    $existingContent = Read-TextFileRaw -Path $SettingsPath
    $fileExisted = ($null -ne $existingContent)
    $state.vscode.settingsPath = $SettingsPath
    $state.vscode.fileExisted = $fileExisted

    if (-not $codeInstalled -and -not $fileExisted) {
        Write-Head 'VS Code'
        Write-Skip 'VS Code is not installed; nothing to configure.'
    } else {
        Write-Head 'VS Code user settings'
        $working = if ($fileExisted) { $existingContent } else { '' }
        $newRecords = @{}
        foreach ($key in $targets.VscodeMap.Keys) {
            $entry = $targets.VscodeMap[$key]
            $existingRaw = Get-JsoncKeyRaw -Content $working -Key $key
            if ($null -ne $existingRaw -and
                    (Normalize-JsonScalar $existingRaw) -ne (Normalize-JsonScalar $entry.Json) -and
                    -not $Force) {
                Write-Warn "$key already set to $existingRaw (unrelated); leaving unchanged. Use -Force to replace."
                $conflicts.Add("vscode:$key")
                continue
            }
            $patch = Set-JsoncKey -Content $working -Key $key -ValueJson $entry.Json
            if ($patch.Changed) {
                $newRecords[$key] = @{
                    hadValue = $patch.HadKey
                    previousRaw = $patch.PreviousRaw
                    setValueJson = $entry.Json
                }
                $working = $patch.Content
                $changedVscode.Add($key)
            } else {
                Write-Skip "$key already configured"
            }
        }

        if ($changedVscode.Count -gt 0) {
            if ($PSCmdlet.ShouldProcess($SettingsPath, "patch keys: $($changedVscode -join ', ')")) {
                if ($fileExisted) {
                    $backup = Backup-FileTo -Path $SettingsPath -BackupDir $backupDir
                    if ($backup) { Write-Note "backup: $backup" }
                }
                Write-TextFileNoBom -Path $SettingsPath -Content $working
                foreach ($key in $changedVscode) {
                    if (-not $state.vscode.keys.ContainsKey($key)) { $state.vscode.keys[$key] = $newRecords[$key] }
                }
                Write-Ok ("patched: {0}" -f ($changedVscode -join ', '))
                $anyStateChange = $true
            }
        } else {
            Write-Ok 'VS Code settings already match DSJumper (no file written).'
        }
        Write-Note 'Only http.proxy, http.proxyStrictSSL, and http.noProxy are managed; other keys are untouched.'
    }
}

# ---------------------------------------------------------------------------
# 5. Persist state
# ---------------------------------------------------------------------------
if ($anyStateChange -and -not $WhatIfPreference) {
    Save-ClientState -StatePath $StatePath -State $state
    Write-Head 'State saved'
    Write-Ok "Rollback data written to $StatePath (no secrets)."
}

# ---------------------------------------------------------------------------
# 6. Optional paid DeepSeek check
# ---------------------------------------------------------------------------
if ($DeepSeekCheck) {
    Write-Head 'DeepSeek API check (explicitly requested)'
    $deepSnapshot = Get-StatusSnapshot -StatusScript $StatusScript -HttpPort $targets.HttpPort -SocksPort $targets.SocksPort -ExtraArguments @('-DeepSeekCheck')
    $match = [regex]::Match([string]$deepSnapshot.Raw, 'DeepSeek check\s*:\s*(?<value>.+)')
    if ($match.Success) { Write-Host ('  ' + $match.Groups['value'].Value.Trim()) }
    else { Write-Warn 'DeepSeek check produced no result.' }
}

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------
Write-Head 'Summary'
Write-Host ("  Environment changes : {0}" -f $(if ($changedEnvironment.Count) { $changedEnvironment -join ', ' } else { 'none' }))
Write-Host ("  Git changes         : {0}" -f $(if ($changedGit.Count) { $changedGit -join ', ' } else { 'none' }))
Write-Host ("  VS Code changes     : {0}" -f $(if ($changedVscode.Count) { $changedVscode -join ', ' } else { 'none' }))
Write-Host ("  Conflicts           : {0}" -f $(if ($conflicts.Count) { $conflicts -join ', ' } else { 'none' }))
Write-Note 'Run client-status.ps1 to verify readiness, and uninstall-client.ps1 to roll back.'

if ($conflicts.Count -gt 0) {
    Write-Warn 'Completed with conflicts; review the warnings above.'
    exit 2
}
Write-Ok 'Client configuration complete.'
exit 0
