#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only operational health and ownership diagnostics for the DSjumper
    loopback proxy chain (SOCKS 1080 and HTTP CONNECT bridge 3128).

.DESCRIPTION
    Distinguishes "working" from "managed and healthy". This script NEVER:

      - stops processes
      - starts or restarts supervisors / listeners / scheduled tasks
      - modifies scheduled tasks or ports
      - modifies SSH configuration or proxy settings
      - calls the paid DeepSeek completion API (unless -DeepSeekCheck is given)

    It only reads task state, TCP listeners, process ancestry, log tails, and
    performs short-lived local proxy transport probes with curl.exe.

    State model:

      HEALTHY    expected listener exists, loopback-only, owned by the expected
                 supervisor process tree, and local proxy transport succeeds.
      UNMANAGED  listener exists and transport works, but it is not owned by the
                 expected supervisor process tree (e.g. a surviving orphan).
                 Reported, never killed.
      BLOCKED    the port is occupied by an unrecognized listener whose transport
                 fails. Reported, never killed or replaced.
      DEGRADED   the expected listener/process exists but transport (or the
                 loopback-only binding) check fails.
      STOPPED    expected task/supervisor/listener is absent.
      STARTING   task/supervisor exists but the expected listener is not ready.

    A port listening is NOT equivalent to HEALTHY. Transport working is NOT
    equivalent to MANAGED.

.PARAMETER DeepSeekCheck
    Explicitly runs the existing small DeepSeek smoke test (deepseek_smoke.py),
    which may incur usage charges. Requires DEEPSEEK_API_KEY in the environment;
    the script will not open an interactive paid prompt. Classifies 401/403/429/5xx
    separately and never prints the API key. Nothing is restarted.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$SocksPort = 1080,

    [ValidateRange(1, 65535)]
    [int]$HttpPort = 3128,

    [string]$SocksTaskName = 'DeepSeek-S5-SOCKS',
    [string]$HttpTaskName = 'DeepSeek-S5-HTTP-Bridge',

    [string]$SocksSupervisorScript = 'start-s5-socks.ps1',
    [string]$HttpSupervisorScript = 'start-http-bridge.ps1',

    [ValidateRange(1, 16)]
    [int]$MaxAncestorDepth = 8,

    [ValidateRange(3, 120)]
    [int]$TransportTimeoutSeconds = 20,

    [string[]]$TransportTargets = @('https://api.ipify.org', 'https://icanhazip.com'),

    [switch]$DeepSeekCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = if ($PSCommandPath) { $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } else { $PWD.Path }
$scriptDir = Split-Path -Parent $scriptPath
$venvPython = Join-Path $scriptDir '.venv\Scripts\python.exe'
$smokeFile = Join-Path $scriptDir 'deepseek_smoke.py'
$httpTransportMarker = '__DSJUMPER_HTTP__'

# ---------------------------------------------------------------------------
# Read-only helpers
# ---------------------------------------------------------------------------

function Get-ProcessTable {
    $table = @{}
    foreach ($process in (Get-CimInstance Win32_Process)) {
        $table[[int]$process.ProcessId] = $process
    }
    return $table
}

function Get-PortListener {
    param([int]$Port)
    return @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Sort-Object LocalAddress, OwningProcess)
}

function Test-LoopbackAddress {
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return $false }
    if ($Address -eq '127.0.0.1' -or $Address -eq '::1') { return $true }
    $parsed = $null
    if ([System.Net.IPAddress]::TryParse($Address, [ref]$parsed)) {
        return [System.Net.IPAddress]::IsLoopback($parsed)
    }
    return $false
}

function Get-AncestorChain {
    param([int]$ProcessId, [hashtable]$Table, [int]$MaxDepth)
    $chain = @()
    $current = $Table[$ProcessId]
    $guard = 0
    while ($null -ne $current -and $guard -lt $MaxDepth) {
        $parentId = [int]$current.ParentProcessId
        if ($parentId -le 0) { break }
        $parent = $Table[$parentId]
        if ($null -eq $parent) { break }
        $chain += $parent
        $current = $parent
        $guard++
    }
    return $chain
}

function Test-SupervisorOwnership {
    param([object[]]$Chain, [string]$SupervisorScript)
    if ([string]::IsNullOrWhiteSpace($SupervisorScript)) { return $false }
    $pattern = [regex]::Escape($SupervisorScript)
    foreach ($process in $Chain) {
        if ($process.CommandLine -and ($process.CommandLine -imatch $pattern)) {
            return $true
        }
    }
    return $false
}

# Removes credentials/key material from a command line before display. The SSH
# identity path is replaced, and bearer/API-key shaped tokens are masked. The
# private key contents were never in the command line to begin with.
function Protect-CommandLine {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
    $safe = $CommandLine
    $safe = [regex]::Replace($safe, '-i\s+("[^"]*"|\S+)', '-i <redacted-identity>')
    $safe = [regex]::Replace($safe, '(?i)(bearer\s+)[A-Za-z0-9_\-\.]{8,}', '$1<redacted>')
    $safe = [regex]::Replace($safe, '(?i)(api[_-]?key\s*[=:]\s*)\S+', '$1<redacted>')
    return ($safe -replace '\s+', ' ').Trim()
}

function Format-ProcessLabel {
    param($Process)
    if ($null -eq $Process) { return '(unknown)' }
    return ('{0}({1})' -f $Process.Name, $Process.ProcessId)
}

function Get-TaskStatus {
    param([string]$Name)
    $task = Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        return [pscustomobject]@{
            Name = $Name; Exists = $false; State = 'Absent'
            LastRunTime = $null; LastTaskResult = $null; NextRunTime = $null
        }
    }
    $info = Get-ScheduledTaskInfo -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        Name = $Name; Exists = $true; State = [string]$task.State
        LastRunTime = if ($info) { $info.LastRunTime } else { $null }
        LastTaskResult = if ($info) { $info.LastTaskResult } else { $null }
        NextRunTime = if ($info) { $info.NextRunTime } else { $null }
    }
}

function Get-LastLogEvent {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $lines = @(Get-Content -LiteralPath $Path -Tail 8 -ErrorAction SilentlyContinue |
        Where-Object { $_ -and $_.Trim().Length -gt 0 })
    if ($lines.Count -eq 0) { return $null }
    return $lines[$lines.Count - 1].Trim()
}

# ---------------------------------------------------------------------------
# Transport probes (short-lived curl.exe; local proxy only)
# ---------------------------------------------------------------------------

$script:CurlAvailable = [bool](Get-Command curl.exe -ErrorAction SilentlyContinue)

function Invoke-ProxyProbe {
    param([string]$Proxy, [string]$Url, [int]$TimeoutSeconds)
    if (-not $script:CurlAvailable) {
        return [pscustomobject]@{ Target = $Url; Ok = $false; HttpCode = ''; Body = ''; Error = 'curl.exe not found' }
    }
    $arguments = @(
        '--silent', '--show-error',
        '--connect-timeout', '5',
        '--max-time', "$TimeoutSeconds",
        '--proxy', $Proxy,
        '--write-out', ($httpTransportMarker + '%{http_code}'),
        $Url
    )
    $raw = ''
    $exitCode = -1
    try {
        $raw = (& curl.exe @arguments 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    } catch {
        return [pscustomobject]@{ Target = $Url; Ok = $false; HttpCode = ''; Body = ''; Error = $_.Exception.Message }
    }
    $markerIndex = $raw.LastIndexOf($httpTransportMarker)
    if ($markerIndex -ge 0) {
        $body = $raw.Substring(0, $markerIndex).Trim()
        $code = $raw.Substring($markerIndex + $httpTransportMarker.Length).Trim()
    } else {
        $body = $raw.Trim()
        $code = ''
    }
    $ok = ($exitCode -eq 0 -and $code -eq '200' -and $body.Length -gt 0)
    $errorText = ''
    if (-not $ok) {
        if ($code -and $code -ne '200') { $errorText = "HTTP $code" }
        elseif ($exitCode -ne 0) { $errorText = "curl exit $exitCode" }
        else { $errorText = 'empty response' }
    }
    return [pscustomobject]@{ Target = $Url; Ok = $ok; HttpCode = $code; Body = $body; Error = $errorText }
}

function Test-ProxyTransport {
    param([string]$Proxy, [string[]]$Targets, [int]$TimeoutSeconds)
    $results = @()
    foreach ($target in $Targets) {
        $results += Invoke-ProxyProbe -Proxy $Proxy -Url $target -TimeoutSeconds $TimeoutSeconds
    }
    if ($results.Count -eq 0) {
        return [pscustomobject]@{ Status = 'NOT-RUN'; Results = @(); EgressIp = ''; TransportOk = $false }
    }
    $passed = @($results | Where-Object { $_.Ok })
    if ($passed.Count -eq $results.Count -and $results.Count -gt 0) { $status = 'PASS' }
    elseif ($passed.Count -gt 0) { $status = 'PARTIAL' }
    else { $status = 'FAIL' }

    $egressIp = ''
    foreach ($result in $results) {
        if ($result.Ok) {
            $parsed = $null
            if ([System.Net.IPAddress]::TryParse($result.Body, [ref]$parsed)) {
                $egressIp = $parsed.ToString()
                break
            }
        }
    }
    $transportOk = ($status -eq 'PASS' -or $status -eq 'PARTIAL')
    return [pscustomobject]@{
        Status = $status; Results = $results; EgressIp = $egressIp; TransportOk = $transportOk
    }
}

# ---------------------------------------------------------------------------
# Component evaluation and state derivation
# ---------------------------------------------------------------------------

function Get-ComponentState {
    param(
        [bool]$TaskExists, [bool]$ListenerExists, [bool]$Managed,
        [bool]$LoopbackOnly, [bool]$TransportOk
    )
    if (-not $ListenerExists) {
        if ($TaskExists) { return 'STARTING' } else { return 'STOPPED' }
    }
    if (-not $Managed) {
        if ($TransportOk) { return 'UNMANAGED' } else { return 'BLOCKED' }
    }
    if (-not $LoopbackOnly) { return 'DEGRADED' }
    if ($TransportOk) { return 'HEALTHY' } else { return 'DEGRADED' }
}

function Get-ComponentReason {
    param(
        [string]$State, [int]$Port, [string]$SupervisorScript,
        [bool]$TaskExists, [bool]$LoopbackOnly, [string]$TransportStatus
    )
    switch ($State) {
        'HEALTHY'   { return "managed by $SupervisorScript, loopback-only, transport $TransportStatus" }
        'STARTING'  { return "task/supervisor present but no listener on $Port yet" }
        'STOPPED'   { return "task and listener on $Port are absent" }
        'UNMANAGED' { return "listener works but is outside the $SupervisorScript process tree (not killed)" }
        'BLOCKED'   { return "port $Port is held by an unrecognized listener and transport fails (not killed or replaced)" }
        'DEGRADED'  {
            if (-not $LoopbackOnly) { return 'listener exists but is not loopback-only' }
            return "local proxy transport failed ($TransportStatus)"
        }
        default     { return 'unknown' }
    }
}

function Get-ComponentStatus {
    param(
        [string]$Label, [int]$Port, [string]$TaskName, [string]$SupervisorScript,
        [string]$ProxyUrl, [hashtable]$Table, [string[]]$Targets, [int]$TimeoutSeconds
    )
    $task = Get-TaskStatus -Name $TaskName
    $listeners = @(Get-PortListener -Port $Port)

    $listener = $null
    $primary = $null
    $chain = @()
    if ($listeners.Count -gt 0) {
        $primary = $listeners[0]
        $primaryId = [int]$primary.OwningProcess
        $listener = $Table[$primaryId]
        $chain = @(Get-AncestorChain -ProcessId $primaryId -Table $Table -MaxDepth $MaxAncestorDepth)
    }

    $loopbackOnly = ($listeners.Count -gt 0) -and (@($listeners | Where-Object { -not (Test-LoopbackAddress $_.LocalAddress) }).Count -eq 0)
    $managed = Test-SupervisorOwnership -Chain $chain -SupervisorScript $SupervisorScript
    $transport = Test-ProxyTransport -Proxy $ProxyUrl -Targets $Targets -TimeoutSeconds $TimeoutSeconds

    $state = Get-ComponentState -TaskExists $task.Exists -ListenerExists ($listeners.Count -gt 0) `
        -Managed $managed -LoopbackOnly $loopbackOnly -TransportOk $transport.TransportOk
    $reason = Get-ComponentReason -State $state -Port $Port -SupervisorScript $SupervisorScript `
        -TaskExists $task.Exists -LoopbackOnly $loopbackOnly -TransportStatus $transport.Status

    return [pscustomobject]@{
        Label          = $Label
        Port           = $Port
        Task           = $task
        ListenerCount  = $listeners.Count
        Listeners      = $listeners
        Listener       = $primary
        Process        = $listener
        Chain          = $chain
        LoopbackOnly   = $loopbackOnly
        Managed        = $managed
        Supervisor     = $SupervisorScript
        Transport      = $transport
        State          = $state
        Reason         = $reason
    }
}

function Get-OverallState {
    param([string[]]$States)
    if ($States -contains 'BLOCKED') { return 'BLOCKED' }
    if ($States -contains 'DEGRADED') { return 'DEGRADED' }
    if ($States -contains 'STOPPED') { return 'STOPPED' }
    return 'HEALTHY'
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

function Get-LogPath {
    param([int]$Port, [string]$Kind)
    if ($Kind -eq 'socks') { return (Join-Path $scriptDir "s5-socks-$Port.log") }
    return (Join-Path $scriptDir "http-bridge-$Port.log")
}

function Write-ComponentReport {
    param($Component)
    $task = $Component.Task
    Write-Output ''
    Write-Output ("{0} {1}:" -f $Component.Label, $Component.Port)
    Write-Output ("  State            : {0}" -f $Component.State)
    if ($task.Exists) {
        $lastRun = if ($task.LastRunTime) { $task.LastRunTime.ToString('o') } else { 'n/a' }
        Write-Output ("  Task             : {0} ({1}; last result {2}; last run {3})" -f `
                $task.Name, $task.State, $task.LastTaskResult, $lastRun)
    } else {
        Write-Output ("  Task             : {0} (absent)" -f $task.Name)
    }

    if ($Component.ListenerCount -eq 0) {
        Write-Output  '  Listener         : none'
    } else {
        $addresses = @($Component.Listeners | ForEach-Object { '{0}:{1}' -f $_.LocalAddress, $_.LocalPort }) -join ', '
        Write-Output ("  Listener         : {0}" -f $addresses)
        Write-Output ("  PID              : {0}" -f $Component.Listener.OwningProcess)
        Write-Output ("  Process          : {0}" -f $Component.Process.Name)
        $parentLabel = if ($Component.Chain.Count -gt 0) { Format-ProcessLabel $Component.Chain[0] } else { '(unknown)' }
        Write-Output ("  Parent           : {0}" -f $parentLabel)
        if ($Component.ListenerCount -gt 1) {
            Write-Output ("  Note             : {0} listeners share this port" -f $Component.ListenerCount)
        }
    }

    Write-Output ("  Managed          : {0}" -f $(if ($Component.Managed) { 'yes' } else { 'no' }))
    Write-Output ("  Loopback-only    : {0}" -f $(if ($Component.LoopbackOnly) { 'yes' } else { 'no' }))

    if ($Component.Chain.Count -gt 0) {
        $chainText = @($Component.Chain | ForEach-Object { Format-ProcessLabel $_ }) -join ' <- '
        Write-Output ("  Ancestors        : {0} <- {1}" -f (Format-ProcessLabel $Component.Process), $chainText)
    } else {
        Write-Output  '  Ancestors        : (no listener; supervisor not resolvable)'
    }

    # SSH command identity (secrets never printed; identity path redacted).
    if ($null -ne $Component.Process -and $Component.Process.Name -eq 'ssh.exe') {
        Write-Output ("  SSH identity     : {0}" -f (Protect-CommandLine $Component.Process.CommandLine))
    }

    $transportBits = @($Component.Transport.Results | ForEach-Object {
        $result = if ($_.Ok) { 'ok' } else { $_.Error }
        '{0} {1} [{2}]' -f $_.Target, $(if ($_.HttpCode) { $_.HttpCode } else { '---' }), $result
    }) -join '; '
    if (-not $transportBits) { $transportBits = 'not run (no listener)' }
    Write-Output ("  Transport        : {0} ({1})" -f $Component.Transport.Status, $transportBits)
    Write-Output ("  Egress IP        : {0}" -f $(if ($Component.Transport.EgressIp) { $Component.Transport.EgressIp } else { '(unavailable)' }))

    $logPath = Get-LogPath -Port $Component.Port -Kind $(if ($Component.Label -eq 'SOCKS') { 'socks' } else { 'http' })
    $lastEvent = Get-LastLogEvent -Path $logPath
    Write-Output ("  Last log event   : {0}" -f $(if ($lastEvent) { $lastEvent } else { '(no log entries)' }))
    Write-Output ("  Diagnostic reason: {0}" -f $Component.Reason)
}

# ---------------------------------------------------------------------------
# Optional explicit DeepSeek smoke test (paid; never automatic)
# ---------------------------------------------------------------------------

function Invoke-DeepSeekCheck {
    param([bool]$UseHttpBridge, [int]$SocksPort)
    if ([string]::IsNullOrWhiteSpace($env:DEEPSEEK_API_KEY)) {
        Write-Output ''
        Write-Output 'DeepSeek check    : SKIPPED - DEEPSEEK_API_KEY is not set. Not opening an interactive paid prompt.'
        return
    }
    if (-not (Test-Path -LiteralPath $venvPython) -or -not (Test-Path -LiteralPath $smokeFile)) {
        Write-Output ''
        Write-Output 'DeepSeek check    : SKIPPED - deepseek_smoke.py or .venv is missing.'
        return
    }
    $arguments = @($smokeFile)
    $route = "socks5h://127.0.0.1:$SocksPort"
    if ($UseHttpBridge) {
        $arguments += '--http-proxy'
        $route = "http://127.0.0.1:$HttpPort"
    } else {
        $arguments += @('--port', "$SocksPort")
    }

    Write-Output ''
    Write-Output ("DeepSeek check    : running existing smoke test via {0} (may incur usage charges)..." -f $route)
    $output = ''
    $exitCode = -1
    try {
        $output = (& $venvPython @arguments 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    } catch {
        Write-Output 'DeepSeek check    : FAIL - smoke test could not be started.'
        return
    }

    # Never echo the raw output or the key; only a classified summary.
    if ($exitCode -eq 0) {
        Write-Output 'DeepSeek check    : PASS - HTTP 200 with a nonempty completion.'
        return
    }
    $classification = 'FAIL - see deepseek_smoke.py output locally (details suppressed)'
    $match = [regex]::Match($output, 'HTTP\s+(\d{3})')
    if ($match.Success) {
        $statusCode = [int]$match.Groups[1].Value
        if ($statusCode -eq 401) { $classification = 'AUTH - HTTP 401 (credentials rejected)' }
        elseif ($statusCode -eq 403) { $classification = 'FORBIDDEN - HTTP 403 (access denied)' }
        elseif ($statusCode -eq 429) { $classification = 'RATE/QUOTA - HTTP 429 (throttled or out of quota)' }
        elseif ($statusCode -ge 500) { $classification = "SERVER - HTTP $statusCode (upstream error)" }
        else { $classification = "FAIL - HTTP $statusCode" }
    }
    Write-Output ("DeepSeek check    : {0}" -f $classification)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$table = Get-ProcessTable

$socksProxy = "socks5h://127.0.0.1:$SocksPort"
$httpProxy = "http://127.0.0.1:$HttpPort"

# Probe a port's transport only if something is actually listening; otherwise
# skip a pointless multi-second wait and report the transport as not run.
$socksListeners = @(Get-PortListener -Port $SocksPort)
$httpListeners = @(Get-PortListener -Port $HttpPort)
$socksTargets = if ($socksListeners.Count -gt 0) { $TransportTargets } else { @() }
$httpTargets = if ($httpListeners.Count -gt 0) { $TransportTargets } else { @() }

$socks = Get-ComponentStatus -Label 'SOCKS' -Port $SocksPort -TaskName $SocksTaskName `
    -SupervisorScript $SocksSupervisorScript -ProxyUrl $socksProxy -Table $table `
    -Targets $socksTargets -TimeoutSeconds $TransportTimeoutSeconds

$http = Get-ComponentStatus -Label 'HTTP' -Port $HttpPort -TaskName $HttpTaskName `
    -SupervisorScript $HttpSupervisorScript -ProxyUrl $httpProxy -Table $table `
    -Targets $httpTargets -TimeoutSeconds $TransportTimeoutSeconds

$overall = Get-OverallState -States @($socks.State, $http.State)
$warnings = @(@($socks, $http) | Where-Object { $_.State -eq 'UNMANAGED' -or $_.State -eq 'STARTING' } | `
        ForEach-Object { '{0} {1}: {2}' -f $_.Label, $_.Port, $_.State })
$warningText = if ($warnings.Count -eq 0) { 'none' } else { $warnings -join '; ' }

Write-Output  'DSjumper status - read-only diagnostic'
Write-Output ("Timestamp         : {0}" -f (Get-Date -Format 'o'))
Write-Output ("Overall state     : {0}" -f $overall)
Write-Output ("Warnings          : {0}" -f $warningText)
Write-Output ("Transport targets : {0}" -f ($TransportTargets -join ', '))

Write-ComponentReport -Component $socks
Write-ComponentReport -Component $http

if ($DeepSeekCheck) {
    $useHttp = ($http.Transport.Status -in @('PASS', 'PARTIAL'))
    Invoke-DeepSeekCheck -UseHttpBridge $useHttp -SocksPort $SocksPort
} else {
    Write-Output ''
    Write-Output 'DeepSeek check    : skipped (default). Use -DeepSeekCheck to run the paid smoke test explicitly.'
}

Write-Output ''
Write-Output 'Read-only: no processes, tasks, ports, SSH, or proxy settings were changed.'
