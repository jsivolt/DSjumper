# DSjumper

Persistent, loopback-only SSH SOCKS5 tunnel from VM3 to S5 for DeepSeek API traffic.

```text
VM3 Python client -> 127.0.0.1:1080 -> SSH over ZeroTier -> S5 -> DeepSeek API
```

## Configuration

| Setting | Value |
| --- | --- |
| VM3 | Windows, user `celltester`, ZeroTier IP `172.30.200.3` |
| S5 | Ubuntu, ZeroTier IP `172.30.100.1` |
| SSH target | `sihot@172.30.100.1:22` |
| Client proxy | `socks5h://127.0.0.1:1080` |
| Scheduled task | `DeepSeek-S5-SOCKS` |
| Supervisor | [start-s5-socks.ps1](start-s5-socks.ps1) |
| Windows deployment | [deploy-s5-socks.ps1](deploy-s5-socks.ps1) |
| API test | [deepseek_smoke.py](deepseek_smoke.py) |

The workspace on VM3 is installed at `C:\Users\celltester\DSjumper`. On another
computer, run the scripts from a stable folder owned by the current user. The
supervisor defaults to the current user's `.ssh\id_ed25519_s5_proxy` identity;
`-IdentityFile` can specify a different existing key.

## Startup And Reconnection

The scheduled task starts at **celltester logon**, not before login at boot. It
uses the current user's interactive logon token, limited privileges, hidden
PowerShell, and no stored Windows password. Logging out ends this interactive
session; signing in starts the task again.

The task launches:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\celltester\DSjumper\start-s5-socks.ps1" -ListenPort 1080
```

The supervisor starts hidden SSH, waits for it to exit, and retries indefinitely
with bounded delays of 5, 10, then 30 seconds. After an SSH process runs for at
least 60 seconds, the retry delay resets to 5 seconds. A per-port mutex prevents
duplicate supervisors in the same Windows session. The task has no execution
time limit and retries supervisor failures at one-minute intervals, up to 999
times; a second task instance is ignored while one is running.

Effective SSH command:

```powershell
ssh.exe -N -D 127.0.0.1:1080 -i C:\Users\celltester\.ssh\id_ed25519_s5_proxy -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 sihot@172.30.100.1
```

SSH keepalives detect unresponsive connections so the supervisor can reconnect.
Binding failures terminate SSH instead of leaving an unusable tunnel running.
Do not run the command manually on `1080` while the scheduled task is active.

## Prerequisites

- Windows OpenSSH client and PowerShell 5.1.
- ZeroTier connectivity to S5 on SSH port 22.
- The dedicated public key authorized for `sihot` on S5.
- S5's verified host key present in the user's SSH known-hosts file.
- Python 3.12 and [requirements.txt](requirements.txt) for the smoke test.

The installed key has no passphrase to support unattended reconnects. Its
Windows ACL is protected and restricted to `celltester`, SYSTEM, and
Administrators. Keep the private key on VM3; only its public key belongs on S5.
Do not commit either API credentials or private SSH keys.

## Deploy To Another Windows Computer

Install OpenSSH Client, Python 3.12 with the `py` launcher, and ZeroTier first.
Join and authorize the ZeroTier network, ensuring S5 is reachable. The deployment
script does not install system software or enroll a ZeroTier device.

Copy [deploy-s5-socks.ps1](deploy-s5-socks.ps1),
[start-s5-socks.ps1](start-s5-socks.ps1), [deepseek_smoke.py](deepseek_smoke.py),
and [requirements.txt](requirements.txt) into a stable folder such as
`$HOME\DSjumper`. Do not copy `.venv`, private keys, credentials, or logs from VM3.
Run PowerShell as the user who should own the task, not as another administrator
account. In that folder, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\deploy-s5-socks.ps1 -CheckOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\deploy-s5-socks.ps1 -InstallPublicKey
```

`-CheckOnly` reports basic prerequisites, existing keys/tasks, and port conflicts
without changing files, starting SSH, or making API requests. It does not test
network reachability or API access. Existing tasks or listeners are never
overwritten or stopped by the deployment script; it is not an in-place updater.

The full deployment reuses the current user's dedicated key or generates a new
Ed25519 key without a passphrase, creates a local Python environment, and
installs its dependencies. `-InstallPublicKey` explicitly authorizes appending
the public key to S5 only when strict, key-only authentication fails. Existing
authorized keys are preserved. Verify S5's displayed host fingerprint through
a trusted channel before accepting it; enter any SSH password directly in the
terminal. Without this switch, the key must already be authorized and the host
must already be trusted.

Before registering the task, deployment tests the hidden supervisor on port
`1081`, including a real DeepSeek request. It then installs the current-user
logon task on `1080`, checks automatic SSH-child replacement, and performs the
final DeepSeek request. API keys are requested through hidden terminal prompts
and may need to be entered twice; they are never saved. Each API test may incur
usage charges. `-ListenPort` and `-TestPort` can select different, distinct ports.

Failures clean up the temporary supervisor and its SSH child. If a production
task was already created by this deployment before a later check failed, it is
retained for troubleshooting and the script exits nonzero; this is not a
successful deployment. Inspect its logs and task state before attempting a
rerun. After a successful deployment, separately test an actual logout/login.

## Smoke Tests

Run the following from a PowerShell terminal in the workspace. The existing
isolated environment is `.venv`; if rebuilding it, use:

```powershell
py -3.12 -m venv .venv
& .\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

Check proxy egress without an API key:

```powershell
curl.exe --silent --show-error --fail --connect-timeout 10 --max-time 30 --proxy socks5h://127.0.0.1:1080 https://api.ipify.org
& .\.venv\Scripts\python.exe .\deepseek_smoke.py --proxy-only
```

Run a real, small DeepSeek request:

```powershell
& .\.venv\Scripts\python.exe .\deepseek_smoke.py
```

The test first checks ipify, then posts to
`https://api.deepseek.com/chat/completions` using `deepseek-chat`, non-streaming
output, and a 32-token limit. It reads `DEEPSEEK_API_KEY` from the process
environment when present; otherwise it prompts for hidden input. Enter the key
directly in the terminal, never in chat or as a command-line argument. The script
does not save the key or print request headers, response bodies, or raw exception
details. The hidden-input prompt requires an interactive terminal. Each fresh
test prompts again if the environment variable is absent. Real API requests may
incur usage charges.

Exit code `0` means HTTP 200 and a nonempty completion, or successful egress when
using `--proxy-only`. Nonzero means failure or cancellation. Check `$LASTEXITCODE`
immediately after the test, before running another native executable.

The Python client uses a dedicated `requests.Session`, explicit per-client SOCKS
proxies, and `trust_env=False`. No machine-wide proxy settings are changed.
`socks5h` resolves destination hostnames through the tunnel rather than locally.
Do not apply this proxy globally to unrelated clients.

## Task Operations

Inspect the installed task and listener:

```powershell
Get-ScheduledTask -TaskName 'DeepSeek-S5-SOCKS'
Get-ScheduledTaskInfo -TaskName 'DeepSeek-S5-SOCKS'
Get-NetTCPConnection -LocalPort 1080 -State Listen
```

The listener must bind only to `127.0.0.1`. Its owning process should be `ssh.exe`,
with a parent PowerShell process running the supervisor.

Start or stop the task as needed:

```powershell
Start-ScheduledTask -TaskName 'DeepSeek-S5-SOCKS'
Stop-ScheduledTask -TaskName 'DeepSeek-S5-SOCKS'
```

Verify the listener disappears after stopping the task. Killing just the SSH
child while leaving the supervisor running triggers an automatic reconnect; it
does not permanently stop the tunnel.

## Logs And Troubleshooting

- [s5-socks-1080.log](s5-socks-1080.log): supervisor starts, child PIDs, exits, and retry delays. Rotates to a `.previous` file after exceeding approximately 512 KiB.
- [s5-socks-1080.stderr.log](s5-socks-1080.stderr.log): SSH diagnostics, overwritten each time the supervisor starts SSH.
- No listener: check task state, ZeroTier connectivity, and SSH diagnostics.
- Authentication failure: verify the dedicated key and S5 public-key authorization. Batch mode intentionally refuses password prompts.
- Host-key failure: verify S5's fingerprint through a trusted channel. Do not disable strict host checking or blindly replace known-host entries.
- Port conflict: identify the listener owner before stopping anything. Do not kill unrelated SSH processes.
- DeepSeek `401` or `403`: check API credentials and access. `429` may indicate quota or rate limiting. A working ipify check alone does not prove API authorization.

For future changes, test on a separate port before touching the production
listener. Start the supervisor in a separate terminal with `-ListenPort 1081`
and target it using `deepseek_smoke.py --port 1081`. Complete both egress and real
DeepSeek checks before switching production. Remove temporary tasks/listeners
afterward. The script itself stays foreground when launched directly; hidden
execution is provided by the scheduled task's launch options.

## Verified State

Verified on **2026-10-06**:

- Temporary `1081` tunnel: loopback-only listening, ipify HTTP 200, and DeepSeek HTTP 200 before production cutover.
- Production `1080` tunnel: scheduled-task-owned SSH, loopback-only listening, and ipify HTTP 200.
- Reconnect: terminating the SSH child produced a replacement under the same supervisor; listening and egress recovered within 8.7 seconds.
- Final DeepSeek smoke test after reconnect: HTTP 200 with a nonempty completion.
- Temporary preflight task and `1081` listener removed. No machine-wide proxy changes; no further S5 changes during persistent-task setup.

The logon trigger configuration was inspected, but an actual reboot/logon was
not exercised. The task is installed on VM3; these files alone do not register it
on another machine. The project currently contains a standalone smoke test, not
an integrated Agent application.