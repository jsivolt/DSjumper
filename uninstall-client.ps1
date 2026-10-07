#Requires -Version 5.1
<#
.SYNOPSIS
    Reverses install-client.ps1 using the saved state file.

.DESCRIPTION
    Restores the previous values of everything the installer changed:

      - environment variables: restores the prior value, or removes the variable
        if DSJumper was the one that created it
      - Git global http.proxy / https.proxy: restores the prior value, or unsets
      - VS Code settings.json: restores the prior raw value of each managed key,
        or removes the key if DSJumper added it

    Other user configuration is never touched. CLIENT-SIDE ONLY: the DSJumper
    production core is not affected.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigDir,
    [string]$StatePath,
    [string]$GitExe = 'git',

    [ValidateSet('User', 'Process', 'Machine')]
    [string]$EnvScope = 'User',

    [switch]$KeepState
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $PWD.Path }
$scriptDir = Split-Path -Parent $scriptPath
$commonFile = Join-Path (Join-Path $scriptDir 'client-config') 'ClientCommon.ps1'
. $commonFile

if ([string]::IsNullOrWhiteSpace($ConfigDir)) { $ConfigDir = Join-Path $scriptDir 'client-config' }
if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = Join-Path $ConfigDir 'state.json' }

Write-Head 'DSJumper client uninstaller (client-side only)'

$state = Read-ClientState -StatePath $StatePath
if ($null -eq $state) {
    Write-Skip "No state file found at $StatePath; nothing to roll back."
    exit 0
}

# Prefer the scope recorded at install time unless the caller overrode it.
$recordedScope = Get-Prop $state 'scope'
if ($recordedScope -and $PSBoundParameters.ContainsKey('EnvScope') -eq $false) { $EnvScope = [string]$recordedScope }

# ---------------------------------------------------------------------------
# Environment variables
# ---------------------------------------------------------------------------
Write-Head "Environment variables ($EnvScope scope)"
$envRecords = Get-Prop $state 'environment'
$envRestored = New-Object System.Collections.Generic.List[string]
if ($envRecords) {
    foreach ($property in $envRecords.PSObject.Properties) {
        $name = $property.Name
        $record = ConvertTo-HashtableDeep $property.Value
        if ($PSCmdlet.ShouldProcess("$EnvScope environment variable $name", 'restore')) {
            if ($record['hadValue']) {
                Set-EnvValue -Name $name -Value ([string]$record['previous']) -Scope $EnvScope
                Write-Ok "$name restored to '$($record['previous'])'"
            } else {
                Remove-EnvValue -Name $name -Scope $EnvScope
                Write-Ok "$name removed"
            }
            $envRestored.Add($name)
        }
    }
}
if ($envRestored.Count -eq 0) { Write-Skip 'No environment variables were managed by DSJumper.' }

# ---------------------------------------------------------------------------
# Git
# ---------------------------------------------------------------------------
Write-Head 'Git (global http.proxy / https.proxy)'
$gitRecords = Get-Prop $state 'git'
$gitRestored = New-Object System.Collections.Generic.List[string]
if ($gitRecords) {
    foreach ($property in $gitRecords.PSObject.Properties) {
        $key = $property.Name
        $record = ConvertTo-HashtableDeep $property.Value
        if (-not (Get-Command $GitExe -ErrorAction SilentlyContinue)) { Write-Warn 'Git not found; cannot restore Git settings.'; break }
        if ($PSCmdlet.ShouldProcess("git config --global $key", 'restore')) {
            if ($record['hadValue']) {
                [void](Set-GitProxyValue -GitExe $GitExe -Key $key -Value ([string]$record['previous']))
                Write-Ok "$key restored to '$($record['previous'])'"
            } else {
                [void](Remove-GitProxyValue -GitExe $GitExe -Key $key)
                Write-Ok "$key removed"
            }
            $gitRestored.Add($key)
        }
    }
}
if ($gitRestored.Count -eq 0) { Write-Skip 'No Git settings were managed by DSJumper.' }

# ---------------------------------------------------------------------------
# VS Code
# ---------------------------------------------------------------------------
Write-Head 'VS Code user settings'
$vscode = Get-Prop $state 'vscode'
if ($null -eq $vscode) {
    Write-Skip 'No VS Code settings were managed by DSJumper.'
} else {
    $settingsPath = [string](Get-Prop $vscode 'settingsPath')
    $fileExisted = [bool](Get-Prop $vscode 'fileExisted')
    $keyRecords = Get-Prop $vscode 'keys'
    if ([string]::IsNullOrWhiteSpace($settingsPath) -or $null -eq $keyRecords) {
        Write-Skip 'No VS Code settings were managed by DSJumper.'
    } else {
        $working = Read-TextFileRaw -Path $settingsPath
        $hadContent = ($null -ne $working)
        if (-not $hadContent) { $working = '' }
        $restored = New-Object System.Collections.Generic.List[string]
        foreach ($property in $keyRecords.PSObject.Properties) {
            $key = $property.Name
            $record = ConvertTo-HashtableDeep $property.Value
            if ($record['hadValue']) {
                $patch = Set-JsoncKey -Content $working -Key $key -ValueJson ([string]$record['previousRaw'])
                if ($patch.Changed) { $working = $patch.Content }
                $restored.Add($key)
                Write-Ok "$key restored"
            } else {
                $patch = Remove-JsoncKey -Content $working -Key $key
                if ($patch.Changed) { $working = $patch.Content }
                $restored.Add($key)
                Write-Ok "$key removed"
            }
        }
        if ($restored.Count -gt 0) {
            if ($PSCmdlet.ShouldProcess($settingsPath, 'write rolled-back settings')) {
                if (-not $fileExisted -and ($working -match '^\s*\{\s*\}\s*$')) {
                    if (Test-Path -LiteralPath $settingsPath) {
                        Remove-Item -LiteralPath $settingsPath -Force
                        Write-Ok 'settings.json created by DSJumper was removed.'
                    }
                } else {
                    if ($hadContent) {
                        $backup = Backup-FileTo -Path $settingsPath -BackupDir (Join-Path $ConfigDir 'backup')
                        if ($backup) { Write-Note "backup of current settings: $backup" }
                    }
                    Write-TextFileNoBom -Path $settingsPath -Content $working
                    Write-Ok 'settings.json rolled back.'
                }
            }
        } else {
            Write-Skip 'No VS Code settings were managed by DSJumper.'
        }
    }
}

# ---------------------------------------------------------------------------
# Remove state
# ---------------------------------------------------------------------------
if (-not $KeepState) {
    if ($PSCmdlet.ShouldProcess($StatePath, 'delete state file')) {
        if (Test-Path -LiteralPath $StatePath) { Remove-Item -LiteralPath $StatePath -Force }
        Write-Ok 'State file removed.'
    }
} else {
    Write-Note "State file kept at $StatePath."
}

Write-Head 'Rollback complete (client-side only).'
Write-Note 'Open a new terminal so restored environment variables take effect.'
exit 0
