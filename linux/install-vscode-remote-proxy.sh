#!/usr/bin/env bash
#
# Install the DSJumper HTTP proxy into the VS Code Remote (SSH) server's
# Machine settings on this Linux host, so extensions running in the remote
# extension host reach the DeepSeek API through 127.0.0.1:3128.
#
# Why Machine settings (and not local User settings):
#   `http.proxy` is a machine-scoped setting. A value set in the client's local
#   User settings is not applied inside the remote extension host; it must be
#   set in the remote Machine/Remote settings. Extensions that use Node's global
#   `fetch` (undici) are also not covered by the local proxy forwarding, but VS
#   Code's extension host patches `globalThis.fetch` to honour `http.proxy`.
#
# TLS verification is intentionally kept enabled (`http.proxyStrictSSL: true`).
#
# Usage:
#   linux/install-vscode-remote-proxy.sh [PROXY_URL]
#
# Defaults to http://127.0.0.1:3128. The script only writes the VS Code Remote
# Machine settings file; it does not change any system-wide or shell proxy
# settings, and it does not touch the 1080 SOCKS tunnel or the 3128 bridge.

set -euo pipefail

PROXY_URL="${1:-http://127.0.0.1:3128}"
AGENT_FOLDER="${VSCODE_AGENT_FOLDER:-$HOME/.vscode-server}"
SETTINGS="$AGENT_FOLDER/data/Machine/settings.json"

case "$PROXY_URL" in
  http://*|https://*|socks://*|socks4://*|socks4a://*|socks5://*|socks5h://*) ;;
  *) echo "error: PROXY_URL must be a proxy URL, got: $PROXY_URL" >&2; exit 2 ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to merge settings JSON safely" >&2
  exit 2
fi

mkdir -p "$(dirname "$SETTINGS")"

SETTINGS="$SETTINGS" PROXY_URL="$PROXY_URL" python3 - <<'PY'
import json, os, sys

path = os.environ["SETTINGS"]
proxy = os.environ["PROXY_URL"]

try:
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read().strip()
    data = json.loads(text) if text else {}
    if not isinstance(data, dict):
        raise ValueError("settings root is not a JSON object")
except FileNotFoundError:
    data = {}
except (json.JSONDecodeError, ValueError) as exc:
    print(f"error: refusing to overwrite unparseable settings file {path}: {exc}", file=sys.stderr)
    sys.exit(3)

data["http.proxy"] = proxy
data["http.proxyStrictSSL"] = True
data["http.proxySupport"] = "override"
data["http.fetchAdditionalSupport"] = True
data["http.useLocalProxyConfiguration"] = False

tmp = path + ".dsjump.tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
print(f"wrote {path}")
PY

cat <<EOF

Next steps:
  1. Ensure the bridge is listening:  ss -ltn '( sport = :3128 )'
  2. Reload the VS Code window (Command Palette: "Developer: Reload Window")
     so the remote extension host picks up the Machine settings.
  3. Send a DeepSeek request. Verify with:
       tail -n 20 "\$HOME/.vscode-server/data/logs/"*/exthost*/Vizards.deepseek-v4-for-copilot/DeepSeek.log
     A working setup shows HTTP responses (for example kind=http status=401 for a
     bad key) instead of "kind=network code=UNABLE_TO_GET_ISSUER_CERT_LOCALLY".
EOF
