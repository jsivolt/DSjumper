# DSjumper

Persistent, loopback-only SSH SOCKS5 tunnel from VM2 to S5 for DeepSeek API traffic.

```text
VM2 Python client     -> 127.0.0.1:1080 -> SSH over ZeroTier -> S5 -> DeepSeek API
HTTP client (VS Code) -> 127.0.0.1:3128 -> 127.0.0.1:1080 -> SSH over ZeroTier -> S5 -> DeepSeek API
```

## Configuration

| Setting | Value |
| --- | --- |
| VM2 | Windows, user `celltester`, ZeroTier IP `172.30.200.3` |
| S5 | Ubuntu, ZeroTier IP `172.30.100.1` |
| SSH target | `sihot@172.30.100.1:22` |
| Client proxy | `socks5h://127.0.0.1:1080` |
| Scheduled task | `DeepSeek-S5-SOCKS` |
| Supervisor | [start-s5-socks.ps1](start-s5-socks.ps1) |
| HTTP bridge | `http://127.0.0.1:3128` -> `socks5://127.0.0.1:1080` |
| Bridge task | `DeepSeek-S5-HTTP-Bridge` |
| Bridge supervisor | [start-http-bridge.ps1](start-http-bridge.ps1) |
| Windows deployment | [deploy-s5-socks.ps1](deploy-s5-socks.ps1) |
| Linux user service | [linux/dsjump-socks.service](linux/dsjump-socks.service) |
| API test | [deepseek_smoke.py](deepseek_smoke.py) |
| Read-only status | [status.ps1](status.ps1) |
| Client installer | [install-client.ps1](install-client.ps1) |
| Client uninstaller | [uninstall-client.ps1](uninstall-client.ps1) |
| Client status | [client-status.ps1](client-status.ps1) |
| Client defaults/state | [client-config/](client-config) |

The workspace on VM2 is installed at `C:\Users\celltester\DSjumper`. On another
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

## HTTP CONNECT Bridge (3128)

Some clients, including VS Code, support only an HTTP proxy. A loopback-only
`pproxy` instance front-ends the SOCKS5 tunnel so that `http://127.0.0.1:3128`
accepts `CONNECT` and forwards to `socks5://127.0.0.1:1080`:

```powershell
& .\.venv\Scripts\python.exe -m pproxy -l http://127.0.0.1:3128 -r socks5://127.0.0.1:1080
```

`pproxy` encodes the `CONNECT` authority as a SOCKS5 domain name (ATYP `0x03`),
so destination hostnames are resolved through the tunnel rather than locally.
The listener binds `127.0.0.1` only. The bridge never modifies the `1080`
tunnel; it is only a client of it. [http_connect_socks.py](http_connect_socks.py)
is a standalone alternative implementation that is not used by the task.

The scheduled task `DeepSeek-S5-HTTP-Bridge` runs
[start-http-bridge.ps1](start-http-bridge.ps1) at current-user logon:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\celltester\DSjumper\start-http-bridge.ps1" -ListenPort 3128 -SocksPort 1080
```

The supervisor restarts `pproxy` if it exits and retries with the same bounded
5, 10, then 30 second delays, resetting after a run of at least 60 seconds. A
per-port mutex makes a duplicate supervisor exit immediately. It never displaces
an existing loopback listener: if another process already serves the port, the
supervisor waits and logs that instead of competing, so a handover cannot drop
active requests; it binds the port within one retry interval once that listener
exits. It uses the venv interpreter, which resolves `pproxy` from
`requirements.txt`.

VS Code reaches it through user settings only:

```json
"http.proxy": "http://127.0.0.1:3128",
"http.proxyStrictSSL": true
```

TLS verification stays with the client and is not weakened. No machine-wide
proxy settings are changed, and the bridge is not applied to unrelated clients.

Verify the bridge:

```powershell
netstat -ano | findstr :3128
curl.exe --silent --show-error --fail --connect-timeout 10 --max-time 30 --proxy http://127.0.0.1:3128 https://api.ipify.org
& .\.venv\Scripts\python.exe .\deepseek_smoke.py --proxy-only --http-proxy
& .\.venv\Scripts\python.exe .\deepseek_smoke.py --http-proxy
```

The `3128` and `1080` egress addresses must match, which confirms traffic still
leaves through S5. The `3128` listener must be part of the process tree rooted at
[start-http-bridge.ps1](start-http-bridge.ps1): a `python.exe` running `pproxy`
that descends from the supervisor `powershell.exe`. The listener may be a child
**or a grandchild**, because `pproxy`/Python can spawn another Python process, so
validate by walking the ancestor chain (`ParentProcessId` repeatedly) up to the
supervisor instead of checking a single parent link.

Never stop the production `3128` listener just to validate it. To test ownership
handling or any bridge change, start a separate instance on another port first.

## Windows Prerequisites

- Windows OpenSSH client and PowerShell 5.1.
- ZeroTier connectivity to S5 on SSH port 22.
- The dedicated public key authorized for `sihot` on S5.
- S5's verified host key present in the user's SSH known-hosts file.
- Python 3.12 and [requirements.txt](requirements.txt) for the smoke test and the HTTP CONNECT bridge (`pproxy`).

The installed key has no passphrase to support unattended reconnects. Its
Windows ACL is protected and restricted to `celltester`, SYSTEM, and
Administrators. Keep the private key on VM2; only its public key belongs on S5.
Do not commit either API credentials or private SSH keys.

## Deploy To Another Windows Computer

Install OpenSSH Client, Python 3.12 with the `py` launcher, and ZeroTier first.
Join and authorize the ZeroTier network, ensuring S5 is reachable. The deployment
script does not install system software or enroll a ZeroTier device.

Copy [deploy-s5-socks.ps1](deploy-s5-socks.ps1),
[start-s5-socks.ps1](start-s5-socks.ps1), [deepseek_smoke.py](deepseek_smoke.py),
and [requirements.txt](requirements.txt) into a stable folder such as
`$HOME\DSjumper`. Do not copy `.venv`, private keys, credentials, or logs from VM2.
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

## Linux Client Deployment

The PowerShell deployment, status, and client-configuration scripts are
Windows-specific. A Linux client uses OpenSSH and a systemd user service; the S5
server configuration does not otherwise change.

Install OpenSSH Client, Python virtual-environment support, and ZeroTier. Join
and authorize the ZeroTier network and confirm that `172.30.100.1:22` is
reachable. The client needs the dedicated public key authorized for `sihot` on
S5, and S5's host key must be verified through a trusted channel.

Create a dedicated key only if one does not already exist:

```bash
install -d -m 700 ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_s5_proxy -N '' -C linux-s5-proxy
chmod 600 ~/.ssh/id_ed25519_s5_proxy
```

Compare the S5 fingerprint obtained out of band with the key offered by the
network endpoint. `ssh-keyscan` only retrieves a candidate key; it does not
verify that key:

```bash
ssh-keyscan -T 5 -t ed25519 172.30.100.1 2>/dev/null | ssh-keygen -lf -
```

After verifying the fingerprint, trust it through SSH's interactive host-key
prompt or add the verified key to `~/.ssh/known_hosts`. Copy the client's
`.pub` key to S5 and authorize it for `sihot`; use the restrictions
`no-agent-forwarding,no-X11-forwarding,no-pty` before the public-key fields.
Keep the private key on the client. Then verify noninteractive authentication:

```bash
ssh -T -i ~/.ssh/id_ed25519_s5_proxy \
  -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
  sihot@172.30.100.1 true
```

Install and enable the included user service:

```bash
install -D -m 644 linux/dsjump-socks.service \
  ~/.config/systemd/user/dsjump-socks.service
systemctl --user daemon-reload
systemctl --user enable --now dsjump-socks.service
```

The service binds SOCKS5 to `127.0.0.1:1080`, checks SSH keepalives, and
restarts SSH after failure. User services normally run while the user manager
is active. To start at boot even before login, enable lingering for the user
(requires local sudo if it is not already enabled):

```bash
loginctl show-user "$USER" -p Linger
sudo loginctl enable-linger "$USER"
```

Prepare the Python environment and test the proxy without calling the paid
DeepSeek API:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
systemctl --user status dsjump-socks.service
ss -ltn '( sport = :1080 )'
curl --fail --proxy socks5h://127.0.0.1:1080 https://api.ipify.org
.venv/bin/python deepseek_smoke.py --proxy-only
```

Use `journalctl --user -u dsjump-socks.service -f` for service logs. The
`socks5h` scheme resolves destination names through the tunnel. The service
does not set global proxy variables or expose the SOCKS port beyond loopback.

The optional HTTP CONNECT bridge for clients such as VS Code requires the
Python dependencies from `requirements.txt`; it can be started with:

```bash
.venv/bin/python -m pproxy -l http://127.0.0.1:3128 -r socks5://127.0.0.1:1080
```

This command is foreground-only; the included Linux unit manages only the
SOCKS tunnel. The bridge must also bind to loopback and be separately supervised
if persistent HTTP-proxy access is required.

## Windows Smoke Tests

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
Get-ScheduledTask -TaskName 'DeepSeek-S5-HTTP-Bridge'
Get-ScheduledTaskInfo -TaskName 'DeepSeek-S5-HTTP-Bridge'
Get-NetTCPConnection -LocalPort 3128 -State Listen
```

For a combined health, ownership, and transport view that applies the state model
below, run [status.ps1](status.ps1) instead of assembling these commands by hand.

Both listeners must bind only to `127.0.0.1`. For `1080`, the owning process
should be `ssh.exe` with a parent PowerShell process running the supervisor,
because the supervisor starts SSH directly. For `3128`, do not check a single
parent link: the listener is a `python.exe` running `pproxy` somewhere below the
supervisor PowerShell process, and may be several generations down because
`pproxy`/Python can spawn another Python process. Walk the ancestor chain
(`ParentProcessId` repeatedly) until it reaches the supervisor or a non-matching
process.

Start or stop the task as needed:

```powershell
Start-ScheduledTask -TaskName 'DeepSeek-S5-SOCKS'
Stop-ScheduledTask -TaskName 'DeepSeek-S5-SOCKS'
```

Verify the listener disappears after stopping the task. Killing just the SSH
child while leaving the supervisor running triggers an automatic reconnect; it
does not permanently stop the tunnel.

The bridge task behaves the same way:

```powershell
Start-ScheduledTask -TaskName 'DeepSeek-S5-HTTP-Bridge'
Stop-ScheduledTask -TaskName 'DeepSeek-S5-HTTP-Bridge'
```

Stopping the bridge task terminates the supervisor but can leave its `pproxy`
child orphaned and still serving `3128`. That is intentional and safe: the
orphan keeps carrying traffic, and the next supervisor run detects the occupied
port and waits rather than competing or killing it. To hand the port back to the
task cleanly, stop the orphan `pproxy` for `3128` first (identify it with
`Get-NetTCPConnection -LocalPort 3128 -State Listen`), or simply log off and back
on so the task starts with the port free.

## Operational Status And State Model

[status.ps1](status.ps1) is a read-only operational diagnostic. It reports a
per-component state for `1080` and `3128`, derives an overall state, and clearly
distinguishes "working" from "managed and healthy". It never stops or starts
processes, restarts or modifies scheduled tasks, changes ports, SSH
configuration, or proxy settings, and it does not call the paid DeepSeek API
unless you explicitly pass `-DeepSeekCheck`.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\status.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\status.ps1 -DeepSeekCheck
```

### States

| State | Meaning |
| --- | --- |
| `HEALTHY` | expected listener exists, binds loopback only, is owned by the expected supervisor process tree, and local proxy transport succeeds. |
| `UNMANAGED` | listener exists and transport works, but it is not owned by the expected supervisor process tree (for example a surviving orphan). Reported, never killed. |
| `BLOCKED` | the port is occupied by an unrecognized listener whose transport fails. Reported, never killed or replaced. |
| `DEGRADED` | the expected listener/process exists, but transport fails, or the listener is not loopback-only. |
| `STOPPED` | the expected task/supervisor/listener is absent. |
| `STARTING` | the task/supervisor exists but the expected listener is not ready yet. |

Key semantics:

- A port listening is **not** equivalent to `HEALTHY`.
- Transport working is **not** equivalent to `MANAGED`.
- `UNMANAGED` and `BLOCKED` are diagnostic states, not automatic repair
  triggers. This tool never kills or replaces a listener.

### Ownership

Ownership is determined by walking the listener's ancestor chain
(`ParentProcessId` up to a bounded depth) and checking whether
`start-s5-socks.ps1` (for `1080`) or `start-http-bridge.ps1` (for `3128`) appears
in it, never by a single parent link. For `1080` the listener is `ssh.exe`, a
direct child of the supervisor; for `3128` the listener is a `python.exe`
running `pproxy`, often a grandchild. SSH command identity is printed with the
private-key path redacted; secrets are never shown.

### Transport checks

Each component is probed through its own local proxy
(`socks5h://127.0.0.1:1080` and `http://127.0.0.1:3128`) against two lightweight
HTTPS targets (`https://api.ipify.org` and `https://icanhazip.com`). If one
target fails while another succeeds, the result is `PARTIAL` and is treated as
an endpoint-specific failure, not immediately as a tunnel failure; only when all
targets fail is transport `FAIL`. The observed egress IP is reported so the
`3128` and `1080` egress addresses can be compared.

### Overall state

The overall state is the most severe component state (`BLOCKED` > `DEGRADED` >
`STOPPED`). A component that is working but not owned by the expected supervisor
(`UNMANAGED`) or still coming up (`STARTING`) is surfaced as an explicit warning
and left visible in its own section rather than being hidden or treated as a
failure.

### Optional DeepSeek check

`-DeepSeekCheck` runs the existing [deepseek_smoke.py](deepseek_smoke.py) smoke
test, which may incur usage charges. It requires `DEEPSEEK_API_KEY` in the
environment and will not open an interactive paid prompt. It classifies `401`,
`403`, `429`, and `5xx` separately, never prints the API key, and never restarts
anything.

## Client Setup (Zero-Friction, Client Side)

Phase 2 configures how *local clients on a Windows machine* reach the existing
DSJumper loopback proxy so a new machine does not need manual reconfiguration.
It is client-side only and never touches the production proxy core (no
supervisors, listeners, scheduled tasks, SSH, or ports).

```powershell
.\install-client.ps1                 # configure this machine
.\client-status.ps1                  # verify readiness
.\client-status.ps1 -DeepSeekCheck   # optional paid API check
.\uninstall-client.ps1               # roll back to previous values
```

### What install-client.ps1 configures

| Target | Setting | Value |
| --- | --- | --- |
| Environment (User scope) | `HTTP_PROXY`, `HTTPS_PROXY`, `http_proxy`, `https_proxy` | `http://127.0.0.1:3128` |
| Environment (User scope) | `NO_PROXY`, `no_proxy` | `localhost,127.0.0.1,::1` |
| Git (global) | `http.proxy`, `https.proxy` | `http://127.0.0.1:3128` |
| VS Code user `settings.json` | `http.proxy` | `http://127.0.0.1:3128` |
| VS Code user `settings.json` | `http.proxyStrictSSL` | `true` |
| VS Code user `settings.json` | `http.noProxy` | `["localhost", "127.0.0.1", "::1"]` |

`ALL_PROXY`/`all_proxy` are **not** set by default: they would force the SOCKS
proxy on every protocol, including tools that should stay local. Use
`-EnableAllProxy` to opt in.

Environment variables are **user-level**, not machine-level, and apply to newly
launched processes. `NO_PROXY` keeps loopback/local traffic off the proxy. The
installer patches only the VS Code keys it owns and preserves the rest of
`settings.json` (including comments and unrelated keys), so it does not replace
your whole settings file.

On Windows the environment is case-insensitive, so the upper- and lower-case
`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` names refer to the **same** variables. The
installer therefore writes three real user variables (`http_proxy`,
`https_proxy`, `no_proxy`) that satisfy both spellings; the mixed-case names in
the table are the lowercase ones on Windows.

### Health gating

Before changing anything, the installer runs the existing [status.ps1](status.ps1)
and requires the HTTP transport to pass ("a port is listening" is not enough). If
DSJumper is unreachable it aborts without configuring clients; use `-Force` to
override.

### Idempotency

Values that are already correct are left untouched; the installer does not rewrite
`settings.json` or re-set variables when nothing needs to change. Re-running is
safe.

### Conflicts

- If an environment variable, Git proxy, or VS Code key already holds an
  **unrelated** value, the installer leaves it alone and reports `CONFLICT`
  (exit code `2`). Use `-Force` to replace it; the prior value is still backed up.
- Git proxy changes are verified against `https://github.com`; if verification
  fails, the Git change is reverted automatically.

### Rollback

`install-client.ps1` records previous values in `client-config/state.json`
(no secrets) and backs up `settings.json` under `client-config/backup/`.
`uninstall-client.ps1` restores the exact previous values, or removes variables
and keys DSJumper created, then deletes the state file. Other user configuration
is never touched.

### Options

| Option | Effect |
| --- | --- |
| `-SkipEnvironment` / `-SkipGit` / `-SkipVsCode` | Skip a target |
| `-Force` | Replace conflicting values (still reversible) |
| `-EnableAllProxy` | Also set `ALL_PROXY`/`all_proxy` to the SOCKS proxy |
| `-EnvScope User\|Process\|Machine` | Environment scope (default `User`) |
| `-SettingsPath` / `-StatePath` / `-ConfigDir` | Override paths (used in tests) |
| `-StatusScript` | Override `status.ps1` |
| `-WhatIf` | Show planned changes without writing anything |
| `-DeepSeekCheck` | Optional paid API test (requires `DEEPSEEK_API_KEY`) |

### Intentionally not configured

- `ALL_PROXY` (see above).
- Git SSH remotes or `url.*.insteadOf` rewriting: SSH remotes do not use
  `http.proxy`, so GitHub-over-SSH is unaffected.
- Any machine-wide or system proxy settings.
- VS Code `http.proxySupport` and any unrelated settings.
- API keys: these scripts never read, store, or print secrets.

### Client status states

`client-status.ps1` reports `PASS`/`FAIL` for DSJumper (reusing `status.ps1` for
health/transport) and meaningful client states: `CONFIGURED`, `NOT_CONFIGURED`,
`PARTIAL`, `CONFLICT`, `NOT NEEDED`, `ENV-ONLY`, `NOT INSTALLED`, `NOT TESTED`.
The overall state is one of `READY`, `PARTIAL`, `CONFLICT`, `UNREACHABLE`, or
`NOT_CONFIGURED`.

Exit codes: `install-client.ps1` -> `0` ok, `2` conflicts, `1` preflight failed;
`client-status.ps1` -> `0` READY, `1` not ready, `2` unreachable.

### Troubleshooting

- Proxy works but `Environment NOT_CONFIGURED`: open a new terminal; new processes
  pick up the new variables.
- `CONFLICT`: an unrelated value exists; review it, then re-run with `-Force` if
  DSJumper should own that setting.
- `UNREACHABLE`: the proxy core is failing transport; run `status.ps1` first.
- VS Code still bypasses the proxy: confirm `http.proxy` in the user
  `settings.json` and reload the window.
- Restore everything: run `uninstall-client.ps1`.

## Logs And Troubleshooting

- [s5-socks-1080.log](s5-socks-1080.log): supervisor starts, child PIDs, exits, and retry delays. Rotates to a `.previous` file after exceeding approximately 512 KiB.
- [s5-socks-1080.stderr.log](s5-socks-1080.stderr.log): SSH diagnostics, overwritten each time the supervisor starts SSH.
- [http-bridge-3128.log](http-bridge-3128.log): bridge supervisor starts, `pproxy` PIDs, exits, and retry delays. Rotates like the tunnel log.
- [http-bridge-3128.out.log](http-bridge-3128.out.log) and [http-bridge-3128.stderr.log](http-bridge-3128.stderr.log): `pproxy` output, overwritten each time the supervisor starts `pproxy`.
- Bridge exit codes logged as `unavailable` are expected: Windows PowerShell 5.1 discards `Start-Process` exit codes whenever output is redirected, so the `pproxy` stderr file is the diagnostic source instead.
- Bridge logs `Port 3128 already served by PID=...; waiting` while another process holds the port; the bridge still works, and the supervisor takes over after that listener exits.
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
- HTTP bridge on `3128`: loopback-only listening, `curl.exe` ipify HTTP 200 through `http://127.0.0.1:3128`, and `deepseek_smoke.py --proxy-only --http-proxy` HTTP 200. The `3128` egress address matched the `1080` egress address, confirming traffic still leaves through S5.
- Bridge supervisor resilience: terminating the `pproxy` child on an isolated `3129` test port produced a replacement listener and restored egress; the temporary `3129` listener and its logs were removed afterward.
- Bridge handover: with `3128` already served, the supervisor logged `Port 3128 already served ...; waiting` and left the existing listener and its traffic untouched.
- Bridge process tree: the production `3128` listener was a grandchild of the supervisor (`start-http-bridge.ps1` powershell.exe -> venv `python.exe` pproxy launcher -> `python.exe` listener), confirming the listener may be more than one generation below the supervisor.
- Temporary preflight task and `1081` listener removed. No machine-wide proxy changes; no further S5 changes during persistent-task setup.

The logon trigger configuration was inspected, but an actual reboot/logon was
not exercised. The task is installed on VM2; these files alone do not register it
on another machine. The project currently contains a standalone smoke test, not
an integrated Agent application.

### Phase 2 client setup (verified 2026-10-07)

- Non-destructive suite (temporary paths, fake tools, stub status, sanitized
  PATH): 35/35 checks passed, covering fresh install, matching config
  (idempotent, no rewrite), conflicting proxy (no silent overwrite; `-Force`
  replaces with backup), Git conflict/absent, VS Code absent, DSJumper
  unavailable (aborts unless `-Force`), repeated install, and paths with spaces.
- Reversible live round-trip on VM2: `install-client.ps1` -> `client-status.ps1`
  (`READY`) -> `uninstall-client.ps1` -> restore verified (environment, Git, and
  `settings.json` restored exactly) -> reinstall -> idempotent no-op. 13/13 checks
  passed.
- Applied on VM2: user variables `http_proxy`/`https_proxy`/`no_proxy`; Git
  global `http.proxy`/`https.proxy`; VS Code user `http.noProxy` added (existing
  `http.proxy`/`http.proxyStrictSSL` already matched and were left untouched).
- Production core preserved throughout: `1080` and `3128` remained loopback,
  managed, and healthy (egress `72.211.255.176`).