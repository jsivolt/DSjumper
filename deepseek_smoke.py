import argparse
import getpass
import ipaddress
import os
import sys
import warnings

import requests


DEEPSEEK_URL = "https://api.deepseek.com/chat/completions"
TIMEOUT = (10, 60)


def read_api_key() -> str:
    api_key = os.environ.get("DEEPSEEK_API_KEY", "").strip()
    if not api_key:
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            api_key = getpass.getpass("DeepSeek API key (hidden, not saved): ").strip()
    if not api_key or any(character.isspace() for character in api_key):
        raise ValueError("A nonempty API key without whitespace is required.")
    return api_key


def main() -> int:
    parser = argparse.ArgumentParser(description="Test DeepSeek through VM3's SSH SOCKS tunnel.")
    parser.add_argument("--proxy-only", action="store_true", help="Check egress without an API key.")
    parser.add_argument("--port", type=int, default=1080, help="Loopback SOCKS port (default: 1080).")
    parser.add_argument(
        "--http-proxy",
        action="store_true",
        help="Use the local HTTP CONNECT bridge at 127.0.0.1:3128.",
    )
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("--port must be between 1 and 65535")
    proxy_url = (
        "http://127.0.0.1:3128"
        if args.http_proxy
        else f"socks5h://127.0.0.1:{args.port}"
    )

    try:
        with requests.Session() as client:
            client.trust_env = False
            client.proxies.update({"http": proxy_url, "https": proxy_url})
            with client.get(
                "https://api.ipify.org", timeout=TIMEOUT, allow_redirects=False
            ) as response:
                print(f"Proxy egress HTTP {response.status_code}", flush=True)
                if response.status_code != 200:
                    return 1
                egress_ip = ipaddress.ip_address(response.text.strip())
                print(f"Egress IP: {egress_ip}", flush=True)

            if args.proxy_only:
                return 0

            api_key = read_api_key()
            with client.post(
                DEEPSEEK_URL,
                headers={"Authorization": f"Bearer {api_key}"},
                json={
                    "model": "deepseek-chat",
                    "messages": [{"role": "user", "content": "Reply with only OK."}],
                    "max_tokens": 32,
                    "temperature": 0,
                    "stream": False,
                },
                timeout=TIMEOUT,
                allow_redirects=False,
            ) as response:
                print(f"DeepSeek chat/completions HTTP {response.status_code}", flush=True)
                if response.status_code != 200:
                    return 1
                result = response.json()
                content = result["choices"][0]["message"]["content"]
                if not isinstance(content, str) or not content.strip():
                    print("FAIL: DeepSeek returned no text completion.", file=sys.stderr)
                    return 1
                print("PASS: Received a nonempty DeepSeek chat completion.", flush=True)
                return 0
    except (getpass.GetPassWarning, EOFError):
        print("FAIL: Use an interactive terminal with hidden input or DEEPSEEK_API_KEY.", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("Cancelled.", file=sys.stderr)
        return 130
    except (requests.RequestException, ValueError, KeyError, IndexError, TypeError) as error:
        print(f"FAIL: {type(error).__name__}; error details suppressed to protect credentials.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())