#Requires -Version 5.1
<#
    ClientCommon.ps1 - shared helpers for the DSJumper client-side installer,
    uninstaller, and status commands. Dot-source this file; it defines functions
    only and performs no configuration changes on load.

    Design goals:
      - PowerShell 5.1 compatible and StrictMode-safe.
      - No secrets are ever read, stored, or printed by these helpers.
      - Configuration changes are value-scoped, reversible, and idempotent.
#>

Set-StrictMode -Version Latest

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Head { param([string]$Text) Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host ("  [ok]   " + $Text) -ForegroundColor Green }
function Write-Skip { param([string]$Text) Write-Host ("  [skip] " + $Text) -ForegroundColor DarkGray }
function Write-Warn { param([string]$Text) Write-Host ("  [warn] " + $Text) -ForegroundColor Yellow }
function Write-Err  { param([string]$Text) Write-Host ("  [fail] " + $Text) -ForegroundColor Red }
function Write-Note { param([string]$Text) Write-Host ("         " + $Text) -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

# Safe property access for objects read from ConvertFrom-Json under StrictMode.
function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-HashtableDeep {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) { $result[$key] = ConvertTo-HashtableDeep $InputObject[$key] }
        return $result
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $result = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-HashtableDeep $property.Value
        }
        return $result
    }
    if (($InputObject -is [System.Collections.IEnumerable]) -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) { $items += , (ConvertTo-HashtableDeep $item) }
        return , $items
    }
    return $InputObject
}

function ConvertTo-JsonStringLiteral {
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    $escaped = $Value -replace '\\', '\\'
    $escaped = $escaped -replace '"', '\"'
    return '"' + $escaped + '"'
}

function ConvertTo-JsonArray {
    param([string[]]$Items)
    $parts = @()
    foreach ($item in @($Items)) { $parts += (ConvertTo-JsonStringLiteral ([string]$item)) }
    return '[' + ($parts -join ', ') + ']'
}

function Normalize-JsonScalar {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return ($Value -replace '\s', '')
}

# ---------------------------------------------------------------------------
# Defaults, targets, and paths
# ---------------------------------------------------------------------------

function Get-ClientDefaults {
    param([Parameter(Mandatory)][string]$ConfigDir)
    $fallback = @{
        version                 = 1
        httpPort                = 3128
        socksPort               = 1080
        noProxy                 = @('localhost', '127.0.0.1', '::1')
        environmentProxyKeys    = @('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy')
        environmentNoProxyKeys  = @('NO_PROXY', 'no_proxy')
        enableAllProxyByDefault = $false
        vscode                  = @{
            settingsRelativePath = 'Code/User/settings.json'
            proxyKeys            = @('http.proxy')
            strictSslKey         = 'http.proxyStrictSSL'
            noProxyKey           = 'http.noProxy'
        }
        gitProxyKeys            = @('http.proxy', 'https.proxy')
    }
    $path = Join-Path $ConfigDir 'client-defaults.json'
    if (Test-Path -LiteralPath $path) {
        try {
            $parsed = ConvertTo-HashtableDeep (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
            if ($parsed) {
                foreach ($key in $parsed.Keys) { $fallback[$key] = $parsed[$key] }
            }
        } catch {
            Write-Warn "client-defaults.json could not be parsed; using built-in defaults."
        }
    }
    return $fallback
}

function Get-ClientTargets {
    param([hashtable]$Defaults, [int]$HttpPort, [int]$SocksPort)
    $resolvedHttp = if ($HttpPort -gt 0) { $HttpPort } else { [int]$Defaults['httpPort'] }
    $resolvedSocks = if ($SocksPort -gt 0) { $SocksPort } else { [int]$Defaults['socksPort'] }
    $httpProxy = "http://127.0.0.1:$resolvedHttp"
    $socksProxy = "socks5h://127.0.0.1:$resolvedSocks"
    $noProxyList = @($Defaults['noProxy'])
    $noProxy = ($noProxyList -join ',')

    $environmentMap = [ordered]@{}
    foreach ($key in @($Defaults['environmentProxyKeys'])) { $environmentMap[[string]$key] = $httpProxy }
    foreach ($key in @($Defaults['environmentNoProxyKeys'])) { $environmentMap[[string]$key] = $noProxy }

    $vscode = $Defaults['vscode']
    $vscodeMap = [ordered]@{}
    foreach ($key in @($vscode['proxyKeys'])) {
        $vscodeMap[[string]$key] = [pscustomobject]@{ Json = (ConvertTo-JsonStringLiteral $httpProxy); Value = $httpProxy }
    }
    $vscodeMap[[string]$vscode['strictSslKey']] = [pscustomobject]@{ Json = 'true'; Value = $true }
    $vscodeMap[[string]$vscode['noProxyKey']] = [pscustomobject]@{ Json = (ConvertTo-JsonArray $noProxyList); Value = $noProxyList }

    $gitMap = [ordered]@{}
    foreach ($key in @($Defaults['gitProxyKeys'])) { $gitMap[[string]$key] = $httpProxy }

    return [pscustomobject]@{
        HttpPort       = $resolvedHttp
        SocksPort      = $resolvedSocks
        HttpProxyUrl   = $httpProxy
        SocksProxyUrl  = $socksProxy
        HttpAddress    = "127.0.0.1:$resolvedHttp"
        SocksAddress   = "127.0.0.1:$resolvedSocks"
        NoProxy        = $noProxy
        NoProxyList    = $noProxyList
        EnvironmentMap = $environmentMap
        VscodeMap      = $vscodeMap
        GitMap         = $gitMap
        EnableAllProxy = [bool]$Defaults['enableAllProxyByDefault']
    }
}

function Get-DefaultVscodeSettingsPath {
    param([hashtable]$Defaults)
    $relative = 'Code/User/settings.json'
    if ($Defaults -and $Defaults.ContainsKey('vscode')) {
        $relative = [string]$Defaults['vscode']['settingsRelativePath']
    }
    $relative = $relative -replace '/', '\'
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) { return $null }
    return (Join-Path $env:APPDATA $relative)
}

function Get-DefaultConfigDir {
    param([string]$ScriptDir)
    return (Join-Path $ScriptDir 'client-config')
}

# ---------------------------------------------------------------------------
# Environment variables (scope-aware, reversible)
# ---------------------------------------------------------------------------

function Get-EnvValue {
    param([string]$Name, [string]$Scope = 'User')
    return [Environment]::GetEnvironmentVariable($Name, $Scope)
}

function Set-EnvValue {
    param([string]$Name, [string]$Value, [string]$Scope = 'User')
    [Environment]::SetEnvironmentVariable($Name, $Value, $Scope)
}

function Remove-EnvValue {
    param([string]$Name, [string]$Scope = 'User')
    [Environment]::SetEnvironmentVariable($Name, $null, $Scope)
}

# ---------------------------------------------------------------------------
# Git configuration (global scope only)
# ---------------------------------------------------------------------------

function Get-GitProxyValue {
    param([string]$GitExe, [string]$Key)
    if (-not (Get-Command $GitExe -ErrorAction SilentlyContinue)) { return $null }
    $output = & $GitExe config --global --get $Key 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    $text = ($output | Out-String).Trim()
    if ($text.Length -eq 0) { return $null }
    return $text
}

function Set-GitProxyValue {
    param([string]$GitExe, [string]$Key, [string]$Value)
    & $GitExe config --global $Key $Value | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Remove-GitProxyValue {
    param([string]$GitExe, [string]$Key)
    & $GitExe config --global --unset $Key 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------------------
# VS Code JSONC settings patching (line oriented; preserves formatting)
# ---------------------------------------------------------------------------

function Read-TextFileRaw {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-Content -LiteralPath $Path -Raw)
}

function Write-TextFileNoBom {
    param([string]$Path, [string]$Content)
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Backup-FileTo {
    param([string]$Path, [string]$BackupDir)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
    $leaf = [System.IO.Path]::GetFileName($Path)
    $destination = Join-Path $BackupDir ("$leaf.$stamp.bak")
    Copy-Item -LiteralPath $Path -Destination $destination -Force
    return $destination
}

function Get-JsoncValuePattern {
    return '"(?:[^"\\]|\\.)*"|true|false|null|\[[^\]]*\]|\{[^}]*\}|-?\d+(?:\.\d+)?'
}

# Sets one top-level JSON/JSONC property, preserving the rest of the file.
# Returns: Changed, Content, HadKey, PreviousRaw.
function Set-JsoncKey {
    param([string]$Content, [string]$Key, [string]$ValueJson)
    $result = [ordered]@{ Changed = $false; Content = $Content; HadKey = $false; PreviousRaw = $null }
    if ($null -eq $Content) { $Content = '' }

    $pattern = '(?m)^(?<indent>[ \t]*)"' + [regex]::Escape($Key) + '"(?<sep>[ \t]*:[ \t]*)(?<val>' + (Get-JsoncValuePattern) + ')(?<tail>[ \t]*,?[ \t]*)(?=\r?$)'
    $match = [regex]::Match($Content, $pattern)
    if ($match.Success) {
        $result.HadKey = $true
        $result.PreviousRaw = $match.Groups['val'].Value
        if ((Normalize-JsonScalar $result.PreviousRaw) -eq (Normalize-JsonScalar $ValueJson)) {
            return [pscustomobject]$result
        }
        $valueGroup = $match.Groups['val']
        $result.Changed = $true
        $result.Content = $Content.Substring(0, $valueGroup.Index) + $ValueJson + $Content.Substring($valueGroup.Index + $valueGroup.Length)
        return [pscustomobject]$result
    }

    # Key is absent: insert it into the root object.
    $newline = if ($Content -match "`r`n") { "`r`n" } else { "`n" }
    if ($Content.Trim().Length -eq 0) { $Content = '{' + $newline + '}' }
    $lines = @($Content -split "`r?`n")

    $closeIndex = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match '^\s*\}\s*,?\s*$') { $closeIndex = $i; break }
    }
    if ($closeIndex -lt 0) {
        $result.Changed = $true
        $result.Content = '{' + $newline + '    ' + (ConvertTo-JsonStringLiteral $Key) + ': ' + $ValueJson + $newline + '}' + $newline
        return [pscustomobject]$result
    }

    $indent = '    '
    foreach ($line in $lines) {
        $indentMatch = [regex]::Match($line, '^(?<indent>[ \t]+)"')
        if ($indentMatch.Success) { $indent = $indentMatch.Groups['indent'].Value; break }
    }

    $openIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\{') { $openIndex = $i; break }
    }
    $hasProperties = $false
    if ($openIndex -ge 0) {
        for ($i = $openIndex + 1; $i -lt $closeIndex; $i++) {
            $trimmed = $lines[$i].Trim()
            if ($trimmed.Length -gt 0 -and -not $trimmed.StartsWith('//')) { $hasProperties = $true; break }
        }
    }

    $newLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) { [void]$newLines.Add($line) }

    if ($hasProperties) {
        for ($i = $closeIndex - 1; $i -ge 0; $i--) {
            $trimmed = $lines[$i].Trim()
            if ($trimmed.Length -gt 0 -and -not $trimmed.StartsWith('//') -and $trimmed -ne '{') {
                if (-not $newLines[$i].TrimEnd().EndsWith(',')) {
                    $newLines[$i] = $newLines[$i].TrimEnd() + ','
                }
                break
            }
        }
    }
    $newLines.Insert($closeIndex, ($indent + (ConvertTo-JsonStringLiteral $Key) + ': ' + $ValueJson))

    $result.Changed = $true
    $result.Content = ($newLines -join $newline)
    return [pscustomobject]$result
}

# Removes one top-level JSON/JSONC property. Returns: Changed, Content, HadKey, PreviousRaw.
function Remove-JsoncKey {
    param([string]$Content, [string]$Key)
    $result = [ordered]@{ Changed = $false; Content = $Content; HadKey = $false; PreviousRaw = $null }
    if ([string]::IsNullOrWhiteSpace($Content)) { return [pscustomobject]$result }

    $pattern = '(?m)^(?<indent>[ \t]*)"' + [regex]::Escape($Key) + '"(?<sep>[ \t]*:[ \t]*)(?<val>' + (Get-JsoncValuePattern) + ')(?<tail>[ \t]*,?[ \t]*)\r?\n?'
    $match = [regex]::Match($Content, $pattern)
    if (-not $match.Success) { return [pscustomobject]$result }

    $result.HadKey = $true
    $result.PreviousRaw = $match.Groups['val'].Value
    $result.Changed = $true

    $remaining = $Content.Remove($match.Index, $match.Length)
    $newline = if ($remaining -match "`r`n") { "`r`n" } else { "`n" }
    $lines = @($remaining -split "`r?`n")

    $closeIndex = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match '^\s*\}\s*$') { $closeIndex = $i; break }
    }
    if ($closeIndex -ge 0) {
        for ($i = $closeIndex - 1; $i -ge 0; $i--) {
            $trimmed = $lines[$i].Trim()
            if ($trimmed.Length -gt 0 -and -not $trimmed.StartsWith('//') -and $trimmed -ne '{') {
                if ($lines[$i].TrimEnd().EndsWith(',')) {
                    $lines[$i] = $lines[$i].TrimEnd().TrimEnd(',')
                }
                break
            }
        }
    }
    $result.Content = ($lines -join $newline)
    return [pscustomobject]$result
}

# Reads the raw value of one top-level JSONC property, or $null if absent.
function Get-JsoncKeyRaw {
    param([string]$Content, [string]$Key)
    if ([string]::IsNullOrWhiteSpace($Content)) { return $null }
    $pattern = '(?m)^[ \t]*"' + [regex]::Escape($Key) + '"[ \t]*:[ \t]*(?<val>' + (Get-JsoncValuePattern) + ')'
    $match = [regex]::Match($Content, $pattern)
    if ($match.Success) { return $match.Groups['val'].Value }
    return $null
}

# ---------------------------------------------------------------------------
# State file (no secrets)
# ---------------------------------------------------------------------------

function Read-ClientState {
    param([string]$StatePath)
    if ([string]::IsNullOrWhiteSpace($StatePath) -or -not (Test-Path -LiteralPath $StatePath)) { return $null }
    try {
        return (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json)
    } catch {
        Write-Warn "State file could not be parsed: $StatePath"
        return $null
    }
}

function Save-ClientState {
    param([string]$StatePath, [hashtable]$State)
    $directory = Split-Path -Parent $StatePath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $json = $State | ConvertTo-Json -Depth 12
    Write-TextFileNoBom -Path $StatePath -Content $json
}

# ---------------------------------------------------------------------------
# DSJumper status integration (reuses status.ps1 rather than duplicating it)
# ---------------------------------------------------------------------------

function Get-StatusSnapshot {
    param(
        [string]$StatusScript,
        [int]$HttpPort,
        [int]$SocksPort,
        [int]$TimeoutSeconds = 20,
        [string[]]$ExtraArguments = @()
    )
    $snapshot = [ordered]@{
        Available      = $false
        Overall        = $null
        HttpState      = $null
        HttpTransport  = $null
        HttpEgress     = $null
        HttpAddress    = "127.0.0.1:$HttpPort"
        SocksState     = $null
        SocksTransport = $null
        SocksEgress    = $null
        SocksAddress   = "127.0.0.1:$SocksPort"
        Raw            = $null
    }
    if ([string]::IsNullOrWhiteSpace($StatusScript) -or -not (Test-Path -LiteralPath $StatusScript)) {
        return [pscustomobject]$snapshot
    }
    $powershellExe = Join-Path $PSHOME 'powershell.exe'
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $StatusScript,
        '-HttpPort', "$HttpPort", '-SocksPort', "$SocksPort",
        '-TransportTimeoutSeconds', "$TimeoutSeconds"
    ) + $ExtraArguments
    try {
        $raw = (& $powershellExe @arguments 2>&1 | Out-String)
    } catch {
        return [pscustomobject]$snapshot
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]$snapshot }
    $snapshot.Raw = $raw
    $snapshot.Available = $true

    $overallMatch = [regex]::Match($raw, 'Overall state\s*:\s*(?<value>\S+)')
    if ($overallMatch.Success) { $snapshot.Overall = $overallMatch.Groups['value'].Value }

    $current = $null
    foreach ($line in ($raw -split "`r?`n")) {
        $header = [regex]::Match($line, '^(?<label>SOCKS|HTTP)\s+(?<port>\d+):\s*$')
        if ($header.Success) { $current = $header.Groups['label'].Value; continue }
        if ($null -eq $current) { continue }
        $stateMatch = [regex]::Match($line, '^\s*State\s*:\s*(?<value>\S+)')
        if ($stateMatch.Success) {
            if ($current -eq 'HTTP') { $snapshot.HttpState = $stateMatch.Groups['value'].Value }
            else { $snapshot.SocksState = $stateMatch.Groups['value'].Value }
            continue
        }
        $transportMatch = [regex]::Match($line, '^\s*Transport\s*:\s*(?<value>\S+)')
        if ($transportMatch.Success) {
            if ($current -eq 'HTTP') { $snapshot.HttpTransport = $transportMatch.Groups['value'].Value }
            else { $snapshot.SocksTransport = $transportMatch.Groups['value'].Value }
            continue
        }
        $egressMatch = [regex]::Match($line, '^\s*Egress IP\s*:\s*(?<value>\S+)')
        if ($egressMatch.Success) {
            if ($current -eq 'HTTP') { $snapshot.HttpEgress = $egressMatch.Groups['value'].Value }
            else { $snapshot.SocksEgress = $egressMatch.Groups['value'].Value }
        }
    }
    return [pscustomobject]$snapshot
}

function Test-GitHubViaProxy {
    param([string]$ProxyUrl, [int]$TimeoutSeconds = 20)
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { return $null }
    $raw = (& curl.exe --silent --show-error --head --connect-timeout 5 --max-time "$TimeoutSeconds" `
            --proxy $ProxyUrl --write-out 'HTTP:%{http_code}' 'https://github.com/' 2>&1 | Out-String)
    $codeMatch = [regex]::Match($raw, 'HTTP:(\d{3})')
    $code = if ($codeMatch.Success) { $codeMatch.Groups[1].Value } else { '000' }
    $ok = ($code -eq '200' -or $code -eq '301' -or $code -eq '302')
    return [pscustomobject]@{ Ok = $ok; Code = $code }
}
