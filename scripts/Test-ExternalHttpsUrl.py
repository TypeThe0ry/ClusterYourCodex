#!/usr/bin/env python3
"""Fail-closed validation for externally fetched GA URLs.

The protected GA workflow runs on a hosted Linux runner, so an evidence or
asset URL must resolve to a publicly routable address.  This helper deliberately
rejects private, loopback, link-local, reserved, multicast, and otherwise
non-global addresses before curl is invoked.  Callers also disable redirects;
the URL checked here is therefore the exact endpoint that will be contacted.
"""

from __future__ import annotations

import ipaddress
import socket
import sys
from urllib.parse import urlsplit


def _fail(message: str) -> "NoReturn":
    raise SystemExit(f"external HTTPS URL rejected: {message}")


def validate(raw: str) -> None:
    if not raw or len(raw) > 2048 or any(character.isspace() for character in raw):
        _fail("URL is empty, oversized, or contains whitespace")
    try:
        parsed = urlsplit(raw)
        scheme = parsed.scheme.lower()
        host = parsed.hostname
        port = parsed.port
    except ValueError as error:
        _fail(f"URL cannot be parsed ({error})")
    if scheme != "https":
        _fail("scheme must be https")
    if not host:
        _fail("host is missing")
    if parsed.username is not None or parsed.password is not None:
        _fail("embedded credentials are not allowed")
    if parsed.fragment:
        _fail("fragments are not sent to the server and are not allowed")
    host = host.rstrip(".")
    if not host:
        _fail("host is empty")

    addresses = set()
    try:
        addresses.add(ipaddress.ip_address(host))
    except ValueError:
        try:
            infos = socket.getaddrinfo(
                host,
                port or 443,
                type=socket.SOCK_STREAM,
            )
        except OSError as error:
            _fail(f"host DNS resolution failed ({error})")
        for info in infos:
            try:
                addresses.add(ipaddress.ip_address(info[4][0]))
            except (IndexError, ValueError):
                continue
    if not addresses:
        _fail("host did not resolve to an IP address")
    non_global = sorted(str(address) for address in addresses if not address.is_global)
    if non_global:
        _fail("host resolves to non-global address(es): " + ", ".join(non_global))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: Test-ExternalHttpsUrl.py URL")
    validate(sys.argv[1])
    print("external HTTPS URL accepted")
