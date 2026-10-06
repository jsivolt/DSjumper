[CmdletBinding()]
param(
    [switch]$InstallPublicKey,
    [switch]$CheckOnly,
    [ValidateRange(1, 65535)]
    [int]$ListenPort = 1080,
    [ValidateRange(1, 65535)]
    [int]$TestPort = 1081
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$taskName = 'DeepSeek-S5-SOCKS'
$target = 'sihot@172.30.100.1'
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$sshExecutable = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
$keygenExecutable = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh-keygen.exe'
$powershellExecutable = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$identityFile = Join-Path $env:USERPROFILE '.ssh\id_ed25519_s5_proxy'
$supervisorFile = Join-Path $PSScriptRoot 'start-s5-socks.ps1'
$smokeFile = Join-Path $PSScriptRoot 'deepseek_smoke.py'
$requirementsFile = Join-Path $PSScriptRoot 'requirements.txt'
$pythonExecutable = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
$preflightSupervisor = $null

function Assert-NativeSuccess([string]$Operation) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed (exit $LASTEXITCODE)."
    }
}

function Test-TunnelEgress([int]$Port, [int]$SupervisorId = 0) {
    & curl.exe --silent --show-error --fail --retry 12 --retry-connrefused `
        --retry-delay 1 --connect-timeout 5 --max-time 30 `
        --proxy "socks5h://127.0.0.1:$Port" https://api.ipify.org `
        --write-out '\nHTTP %{http_code}\n' | Out-Host
    Assert-NativeSuccess 'SOCKS egress check'
    $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
    if ($listeners.Count -ne 1 -or $listeners[0].LocalAddress -ne '127.0.0.1') {
        throw "Port $Port must have exactly one loopback-only listener."
    }
    $sshProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($listeners[0].OwningProcess)"
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($sshProcess.ParentProcessId)"
    if ($sshProcess.Name -ne 'ssh.exe' -or $null -eq $parent -or
        $parent.Name -ne 'powershell.exe' -or
        $parent.CommandLine -notmatch [regex]::Escape($supervisorFile) -or
        ($SupervisorId -ne 0 -and $sshProcess.ParentProcessId -ne $SupervisorId)) {
        throw 'The listener does not belong to the expected supervisor.'
    }
    return $sshProcess
}

function Stop-PreflightSupervisor {
    if ($null -ne $preflightSupervisor) {
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($preflightSupervisor.Id)" |
            Where-Object { $_.Name -eq 'ssh.exe' })
        if (-not $preflightSupervisor.HasExited) {
            $preflightSupervisor.Kill()
            $preflightSupervisor.WaitForExit()
        }
        foreach ($child in $children) {
            Stop-Process -Id $child.ProcessId -ErrorAction SilentlyContinue
        }
        $preflightSupervisor.Dispose()
        $script:preflightSupervisor = $null
    }
}

try {
    if ($ListenPort -eq $TestPort) {
        throw 'ListenPort and TestPort must differ.'
    }
    foreach ($file in @($sshExecutable, $keygenExecutable, $powershellExecutable,
        $supervisorFile, $smokeFile, $requirementsFile)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Required file missing: $file. Install OpenSSH Client or copy all project files."
        }
    }
    [void](Get-Command curl.exe -ErrorAction Stop)
    [void](Get-Command Register-ScheduledTask -ErrorAction Stop)
    $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    $occupied = @(Get-NetTCPConnection -LocalPort $ListenPort,$TestPort -State Listen -ErrorAction SilentlyContinue)
    if (-not (Test-Path -LiteralPath $pythonExecutable)) {
        [void](Get-Command py.exe -ErrorAction Stop)
    }
    if ($CheckOnly) {
        Write-Output "Prerequisite check passed for $currentUser."
        Write-Output "Target: $target; project: $PSScriptRoot"
        $occupiedPorts = @($occupied | ForEach-Object { $_.LocalPort }) -join ', '
        Write-Output "Existing task: $($null -ne $existingTask); occupied ports: $occupiedPorts"
        Write-Output "Existing key: $(Test-Path -LiteralPath $identityFile); existing venv: $(Test-Path -LiteralPath $pythonExecutable)"
        Write-Output 'No files, tasks, SSH connections, or proxy settings were changed.'
        return
    }
    if ($null -ne $existingTask -or $occupied.Count -ne 0) {
        throw 'An existing task or listener was found. It will not be overwritten or stopped. Use -CheckOnly to inspect.'
    }

    Write-Output 'ZeroTier must already be joined/authorized. This script does not install software or change global proxies.'
    if (-not (Test-Path -LiteralPath $identityFile)) {
        if (Test-Path -LiteralPath "$identityFile.pub") {
            throw 'An orphan public key exists; refusing to overwrite it.'
        }
        [void](New-Item -ItemType Directory -Force -Path (Split-Path $identityFile))
        $keygen = Start-Process -FilePath $keygenExecutable -ArgumentList @(
            '-t', 'ed25519', '-f', "`"$identityFile`"", '-N', '""', '-C', 'windows-s5-proxy'
        ) -NoNewWindow -Wait -PassThru
        if ($keygen.ExitCode -ne 0) { throw 'SSH key generation failed.' }
        $keygen.Dispose()
        Write-Output 'Created a dedicated key without a passphrase for unattended reconnects.'
    }
    if (-not (Test-Path -LiteralPath "$identityFile.pub")) {
        throw 'Public key is missing. Existing private keys are never overwritten.'
    }

    $authenticationOptions = @('-T', '-i', $identityFile, '-o', 'IdentitiesOnly=yes',
        '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
        '-o', 'ConnectTimeout=10', '-o', 'ConnectionAttempts=1')
    & $sshExecutable @authenticationOptions $target true
    if ($LASTEXITCODE -ne 0 -and $InstallPublicKey) {
        Write-Output 'Verify any displayed S5 host fingerprint through a trusted channel before accepting.'
        Write-Output 'Enter the S5 account password only in the terminal. Only the public key will be sent.'
        $publicParts = (Get-Content -Raw -LiteralPath "$identityFile.pub").Trim() -split '\s+', 3
        if ($publicParts.Count -lt 2 -or $publicParts[0] -ne 'ssh-ed25519' -or
            $publicParts[1] -notmatch '^[A-Za-z0-9+/=]+$') {
            throw 'Unexpected dedicated public key format.'
        }
        $publicKey = "ssh-ed25519 $($publicParts[1])"
        $remoteScript = @'
set -eu
umask 077
mkdir -p "$HOME/.ssh"
if [ -L "$HOME/.ssh/authorized_keys" ]; then
    printf '%s\n' 'Refusing to modify symlinked authorized_keys.' >&2
    exit 1
fi
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"
if ! grep -Fq -- '__PUBLIC_KEY__' "$HOME/.ssh/authorized_keys"; then
    printf '\n%s\n' 'no-agent-forwarding,no-X11-forwarding,no-pty __PUBLIC_KEY__ windows-s5-proxy' >> "$HOME/.ssh/authorized_keys"
fi
'@
        $remoteScript = $remoteScript.Replace('__PUBLIC_KEY__', $publicKey).Replace("`r`n", "`n")
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remoteScript))
        & $sshExecutable -T -o StrictHostKeyChecking=ask -o ConnectTimeout=10 `
            -o ConnectionAttempts=1 -o NumberOfPasswordPrompts=1 $target "printf %s $encoded | base64 -d | sh"
        Assert-NativeSuccess 'S5 public-key installation'
        & $sshExecutable @authenticationOptions $target true
    }
    Assert-NativeSuccess 'Strict, noninteractive SSH authentication (use -InstallPublicKey for initial bootstrap)'

    if (-not (Test-Path -LiteralPath $pythonExecutable)) {
        & py.exe -3.12 -m venv (Join-Path $PSScriptRoot '.venv')
        Assert-NativeSuccess 'Python 3.12 environment creation'
    }
    & $pythonExecutable -m pip install --disable-pip-version-check -r $requirementsFile
    Assert-NativeSuccess 'SOCKS client dependency installation'

    $preflightSupervisor = Start-Process -FilePath $powershellExecutable -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$supervisorFile`"", '-ListenPort', $TestPort,
        '-IdentityFile', "`"$identityFile`""
    ) -WindowStyle Hidden -PassThru
    $preflightSsh = Test-TunnelEgress -Port $TestPort -SupervisorId $preflightSupervisor.Id
    Write-Output 'Preflight DeepSeek test: enter the API key at the hidden prompt. It is not saved.'
    & $pythonExecutable $smokeFile --port $TestPort
    Assert-NativeSuccess 'Preflight DeepSeek HTTP 200 test'
    Stop-PreflightSupervisor

    if ((Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue) -or
        (Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue)) {
        throw 'A task or production listener appeared during preflight; refusing to replace it.'
    }
    $actionArguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$supervisorFile`" -ListenPort $ListenPort -IdentityFile `"$identityFile`""
    $action = New-ScheduledTaskAction -Execute $powershellExecutable -Argument $actionArguments -WorkingDirectory $PSScriptRoot
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
    $settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
        -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    [void](Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Principal $principal `
        -Trigger $trigger -Settings $settings -Description 'Loopback-only S5 SOCKS tunnel; current-user logon, no stored password.')
    Write-Output "Registered $taskName for $currentUser."
    Start-ScheduledTask -TaskName $taskName -TaskPath '\'
    $productionSsh = Test-TunnelEgress -Port $ListenPort
    $oldChildId = $productionSsh.ProcessId
    Stop-Process -Id $oldChildId
    $replacementSsh = Test-TunnelEgress -Port $ListenPort -SupervisorId $productionSsh.ParentProcessId
    if ($replacementSsh.ProcessId -eq $oldChildId) { throw 'Reconnect did not replace the SSH child.' }
    Write-Output "Reconnect passed: SSH $oldChildId replaced by $($replacementSsh.ProcessId)."
    Write-Output 'Final DeepSeek test: enter the API key again if it is not in the process environment.'
    & $pythonExecutable $smokeFile --port $ListenPort
    Assert-NativeSuccess 'Final DeepSeek HTTP 200 test'
    Write-Output "Deployment passed. Task: $taskName; supervisor: $supervisorFile; proxy: socks5h://127.0.0.1:$ListenPort"
    Write-Output 'Starts at current-user logon, not at boot before login. Test an actual logout/login separately.'
} catch {
    Write-Error "Deployment failed: $($_.Exception.Message) Existing tasks/listeners are not replaced; any newly registered production task is retained for troubleshooting." -ErrorAction Continue
    exit 1
} finally {
    Stop-PreflightSupervisor
}