param(
    [ValidateRange(1, 65535)]
    [int]$ListenPort = 3128,
    [ValidateRange(1, 65535)]
    [int]$SocksPort = 1080,
    [string]$PythonPath = (Join-Path $PSScriptRoot '.venv\Scripts\python.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$logFile = Join-Path $PSScriptRoot "http-bridge-$ListenPort.log"
$outputFile = Join-Path $PSScriptRoot "http-bridge-$ListenPort.out.log"
$errorFile = Join-Path $PSScriptRoot "http-bridge-$ListenPort.stderr.log"
$retrySeconds = @(5, 10, 30)
$retryIndex = 0
$pproxyProcess = $null
$hasMutex = $false
$mutex = New-Object System.Threading.Mutex($false, "Local\DeepSeek-S5-HTTP-Bridge-$ListenPort")
$retryEvent = New-Object System.Threading.ManualResetEvent($false)

function Write-BridgeStatus([string]$Message) {
    if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 524288) {
        Move-Item -LiteralPath $logFile -Destination "$logFile.previous" -Force
    }
    [System.IO.File]::AppendAllText($logFile, "$(Get-Date -Format o) $Message`r`n")
}

function Get-ChildExitCode($Process) {
    # PowerShell 5.1 discards the exit code whenever output is redirected, so
    # this reports 'unavailable' rather than an empty or misleading value.
    try {
        if ($null -eq $Process.ExitCode) {
            return 'unavailable'
        }
        return [string]$Process.ExitCode
    } catch {
        return 'unavailable'
    }
}

try {
    try {
        $hasMutex = $mutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $hasMutex = $true
    }
    if (-not $hasMutex) {
        exit 0
    }
    if (-not (Test-Path -LiteralPath $PythonPath)) {
        throw 'The Python interpreter for pproxy is missing.'
    }

    # pproxy encodes the CONNECT authority as a SOCKS5 domain name (ATYP 0x03),
    # so destination hostnames are resolved through the 1080 tunnel, not locally.
    $pproxyArguments = @(
        '-m', 'pproxy',
        '-l', "http://127.0.0.1:$ListenPort",
        '-r', "socks5://127.0.0.1:$SocksPort"
    )

    Write-BridgeStatus "Supervisor started; PID=$PID; HTTP CONNECT 127.0.0.1:$ListenPort -> socks5://127.0.0.1:$SocksPort."
    while ($true) {
        $startedAt = [DateTime]::UtcNow
        # Never displace an existing loopback listener. If another bridge generation
        # already serves the port it keeps handling traffic until it exits, so an
        # interrupted handover never drops active DeepSeek connections.
        $existing = @(Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue)
        if ($existing.Count -gt 0) {
            Write-BridgeStatus "Port $ListenPort already served by PID=$($existing[0].OwningProcess); waiting instead of competing."
        } else {
            try {
                $pproxyProcess = Start-Process -FilePath $PythonPath -ArgumentList $pproxyArguments `
                    -WindowStyle Hidden -RedirectStandardOutput $outputFile -RedirectStandardError $errorFile -PassThru
                Write-BridgeStatus "pproxy started; PID=$($pproxyProcess.Id)."
                $pproxyProcess.WaitForExit()
                Write-BridgeStatus "pproxy exited; code=$(Get-ChildExitCode $pproxyProcess)."
            } catch {
                Write-BridgeStatus "pproxy launch or wait failed; type=$($_.Exception.GetType().Name)."
            } finally {
                if ($null -ne $pproxyProcess) {
                    if (-not $pproxyProcess.HasExited) {
                        $pproxyProcess.Kill()
                        $pproxyProcess.WaitForExit()
                    }
                    $pproxyProcess.Dispose()
                    $pproxyProcess = $null
                }
            }
        }
        if (([DateTime]::UtcNow - $startedAt).TotalSeconds -ge 60) {
            $retryIndex = 0
        }
        $delaySeconds = $retrySeconds[$retryIndex]
        Write-BridgeStatus "Retry in $delaySeconds seconds."
        [void]$retryEvent.WaitOne($delaySeconds * 1000)
        $retryIndex = [Math]::Min($retryIndex + 1, $retrySeconds.Count - 1)
    }
} finally {
    if ($hasMutex) {
        $mutex.ReleaseMutex()
    }
    $retryEvent.Dispose()
    $mutex.Dispose()
}
