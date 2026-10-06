import asyncio
import contextlib
import ipaddress
import re
import socket

import socks


LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 3128
SOCKS_HOST = "127.0.0.1"
SOCKS_PORT = 1080
HEADER_LIMIT = 16 * 1024
CONNECT_TIMEOUT = 15
HOST_RE = re.compile(r"[A-Za-z0-9.-]+\Z")


class BadRequest(Exception):
    pass


def parse_authority(authority: str) -> tuple[str, int]:
    if authority.startswith("["):
        closing = authority.find("]")
        if closing < 0 or authority[closing + 1 : closing + 2] != ":":
            raise BadRequest
        host = authority[1:closing]
        try:
            ipaddress.IPv6Address(host)
        except ValueError as error:
            raise BadRequest from error
        port_text = authority[closing + 2 :]
    else:
        host, separator, port_text = authority.rpartition(":")
        if not separator or not HOST_RE.fullmatch(host):
            raise BadRequest
        try:
            ipaddress.ip_address(host)
        except ValueError:
            labels = host.rstrip(".").split(".")
            if not labels or any(
                not label or len(label) > 63 or label.startswith("-") or label.endswith("-")
                for label in labels
            ):
                raise BadRequest

    if not port_text.isascii() or not port_text.isdecimal():
        raise BadRequest
    port = int(port_text)
    if not 1 <= port <= 65535:
        raise BadRequest
    return host, port


async def respond(writer: asyncio.StreamWriter, status: int, reason: str) -> None:
    writer.write(f"HTTP/1.1 {status} {reason}\r\nConnection: close\r\n\r\n".encode("ascii"))
    with contextlib.suppress(ConnectionError):
        await writer.drain()


def connect_through_socks(host: str, port: int) -> socket.socket:
    upstream = socks.socksocket(socket.AF_INET, socket.SOCK_STREAM)
    upstream.set_proxy(
        socks.SOCKS5,
        addr=SOCKS_HOST,
        port=SOCKS_PORT,
        rdns=True,
    )
    upstream.settimeout(CONNECT_TIMEOUT)
    try:
        upstream.connect((host, port))
    except Exception:
        upstream.close()
        raise
    upstream.setblocking(False)
    return upstream


async def relay(
    source: asyncio.StreamReader, destination: asyncio.StreamWriter
) -> None:
    while chunk := await source.read(64 * 1024):
        destination.write(chunk)
        await destination.drain()
    if destination.can_write_eof():
        destination.write_eof()


async def handle_client(
    client_reader: asyncio.StreamReader, client_writer: asyncio.StreamWriter
) -> None:
    upstream_writer = None
    try:
        request = await asyncio.wait_for(
            client_reader.readuntil(b"\r\n\r\n"), timeout=10
        )
        if len(request) > HEADER_LIMIT:
            raise BadRequest
        request_line = request.split(b"\r\n", 1)[0].split()
        if len(request_line) != 3 or request_line[0] != b"CONNECT":
            await respond(client_writer, 405, "Method Not Allowed")
            return
        if request_line[2] not in (b"HTTP/1.0", b"HTTP/1.1"):
            raise BadRequest
        host, port = parse_authority(request_line[1].decode("ascii"))
        upstream_socket = await asyncio.wait_for(
            asyncio.to_thread(connect_through_socks, host, port),
            timeout=CONNECT_TIMEOUT + 2,
        )
        upstream_reader, upstream_writer = await asyncio.open_connection(
            sock=upstream_socket
        )
        client_writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await client_writer.drain()
        await asyncio.gather(
            relay(client_reader, upstream_writer),
            relay(upstream_reader, client_writer),
        )
    except BadRequest:
        await respond(client_writer, 400, "Bad Request")
    except (asyncio.LimitOverrunError, asyncio.IncompleteReadError, UnicodeDecodeError):
        await respond(client_writer, 400, "Bad Request")
    except (OSError, asyncio.TimeoutError, socks.ProxyError):
        await respond(client_writer, 502, "Bad Gateway")
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        if upstream_writer is not None:
            upstream_writer.close()
            with contextlib.suppress(OSError, asyncio.CancelledError):
                await upstream_writer.wait_closed()
        client_writer.close()
        with contextlib.suppress(OSError, asyncio.CancelledError):
            await client_writer.wait_closed()


async def main() -> None:
    server = await asyncio.start_server(
        handle_client,
        LISTEN_HOST,
        LISTEN_PORT,
        limit=HEADER_LIMIT,
    )
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass