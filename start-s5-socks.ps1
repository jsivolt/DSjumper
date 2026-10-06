param(
    [ValidateRange(1, 65535)]
    [int]$ListenPort = 1080,
    [string]$IdentityFile = (Join-Path $env:USERPROFILE '.ssh\id_ed25519_s5_proxy')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sshExecutable = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
$logFile = Join-Path $PSScriptRoot "s5-socks-$ListenPort.log"
$errorFile = Join-Path $PSScriptRoot "s5-socks-$ListenPort.stderr.log"
$retrySeconds = @(5, 10, 30)
$retryIndex = 0
$sshProcess = $null
$hasMutex = $false
$mutex = New-Object System.Threading.Mutex($false, "Local\DeepSeek-S5-SOCKS-$ListenPort")
$retryEvent = New-Object System.Threading.ManualResetEvent($false)

function Write-TunnelStatus([string]$Message) {
    if ((Test-Path -LiteralPath $logFile) -and (Get-Item -LiteralPath $logFile).Length -gt 524288) {
        Move-Item -LiteralPath $logFile -Destination "$logFile.previous" -Force
    }
    [System.IO.File]::AppendAllText($logFile, "$(Get-Date -Format o) $Message`r`n")
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
    if (-not (Test-Path -LiteralPath $sshExecutable) -or -not (Test-Path -LiteralPath $identityFile)) {
        throw 'SSH executable or dedicated identity is missing.'
    }

    $sshArguments = @(
        '-N', '-D', "127.0.0.1:$ListenPort",
        '-i', "`"$identityFile`"",
        '-o', 'IdentitiesOnly=yes',
        '-o', 'BatchMode=yes',
        '-o', 'StrictHostKeyChecking=yes',
        '-o', 'ServerAliveInterval=30',
        '-o', 'ServerAliveCountMax=3',
        '-o', 'ExitOnForwardFailure=yes',
        '-o', 'ConnectTimeout=10',
        '-o', 'ConnectionAttempts=1',
        'sihot@172.30.100.1'
    )

    Write-TunnelStatus "Supervisor started; PID=$PID; loopback port=$ListenPort."
    while ($true) {
        $startedAt = [DateTime]::UtcNow
        try {
            $sshProcess = Start-Process -FilePath $sshExecutable -ArgumentList $sshArguments `
                -WindowStyle Hidden -RedirectStandardError $errorFile -PassThru
            Write-TunnelStatus "SSH started; PID=$($sshProcess.Id)."
            $sshProcess.WaitForExit()
            Write-TunnelStatus "SSH exited; code=$($sshProcess.ExitCode)."
        } catch {
            Write-TunnelStatus "SSH launch or wait failed; type=$($_.Exception.GetType().Name)."
        } finally {
            if ($null -ne $sshProcess) {
                if (-not $sshProcess.HasExited) {
                    $sshProcess.Kill()
                    $sshProcess.WaitForExit()
                }
                $sshProcess.Dispose()
                $sshProcess = $null
            }
        }
        if (([DateTime]::UtcNow - $startedAt).TotalSeconds -ge 60) {
            $retryIndex = 0
        }
        $delaySeconds = $retrySeconds[$retryIndex]
        Write-TunnelStatus "Retry in $delaySeconds seconds."
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