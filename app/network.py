"""Where this server can be reached from — so the iPhone can find it anywhere.

The phone remembers whichever address you typed into Settings once. When that
is a LAN address (``192.168.x.x``), it silently stops working the moment you
leave the house. Rather than asking you to notice and re-type a new address,
the server reports its own reachable addresses and the app learns the
permanent one by itself.

Discovery order for ``remote_url``, the one address to prefer from anywhere:

1. ``PUBLIC_URL`` — an explicit override for a custom domain or reverse proxy.
2. Tailscale Serve — the private HTTPS ``*.ts.net`` name created by
   ``scripts/setup-remote-access.sh``.
3. Plain Tailscale — the MagicDNS name plus the app's port, which works over
   the tailnet whenever the server is not bound to loopback only.

``direct_urls`` adds the addresses that need no proxy: the tailnet IP (which
works from anywhere even with MagicDNS turned off) and the LAN IP (which does
not). The client classifies them itself, so this stays a plain list.

Nothing here opens a port, changes routing, or contacts the network: it reads
the local Tailscale state and this machine's own interfaces.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import time
from typing import Any, Optional

from .config import BASE_DIR, settings

# Discovery shells out to the Tailscale CLI, so results are cached briefly.
# /api/config is polled on every app launch and connection test.
_CACHE_SECONDS = 60.0
_TAILSCALE_TIMEOUT = 4.0

_cache: dict[str, Any] = {}

_TAILSCALE_CANDIDATES = (
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    "/usr/local/bin/tailscale",
    "/opt/homebrew/bin/tailscale",
)


def _tailscale_binary() -> Optional[str]:
    found = shutil.which("tailscale")
    if found:
        return found
    for path in _TAILSCALE_CANDIDATES:
        if os.access(path, os.X_OK):
            return path
    return None


def _tailscale_json(*args: str) -> dict:
    """Run a Tailscale CLI command and parse its JSON, or return {}."""
    binary = _tailscale_binary()
    if not binary:
        return {}
    try:
        result = subprocess.run(
            [binary, *args],
            capture_output=True,
            text=True,
            timeout=_TAILSCALE_TIMEOUT,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return {}
    if result.returncode != 0 or not result.stdout.strip():
        return {}
    try:
        parsed = json.loads(result.stdout)
    except json.JSONDecodeError:
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _self_node() -> dict:
    """This machine's entry in `tailscale status`, only while it is connected."""
    status = _tailscale_json("status", "--json")
    if status.get("BackendState") != "Running":
        return {}
    self_node = status.get("Self")
    return self_node if isinstance(self_node, dict) else {}


def tailscale_dns_name() -> str:
    """This machine's MagicDNS name (``mac-mini.tailnet.ts.net``), or ""."""
    name = str(_self_node().get("DNSName") or "").rstrip(".")
    return name if name.endswith(".ts.net") else ""


def tailscale_ipv4() -> str:
    """This machine's tailnet IPv4 (``100.x.y.z``), which needs no MagicDNS."""
    for address in _self_node().get("TailscaleIPs") or []:
        text = str(address)
        parts = text.split(".")
        if len(parts) == 4 and parts[0] == "100" and all(p.isdigit() for p in parts):
            return text
    return ""


def tailscale_serve_url(port: int) -> str:
    """The HTTPS ``*.ts.net`` address Tailscale Serve proxies to ``port``."""
    config = _tailscale_json("serve", "status", "--json")
    web = config.get("Web")
    if not isinstance(web, dict):
        return ""
    needle = f":{port}"
    for host_port, entry in web.items():
        handlers = entry.get("Handlers") if isinstance(entry, dict) else None
        if not isinstance(handlers, dict):
            continue
        proxies_to_app = any(
            isinstance(handler, dict) and str(handler.get("Proxy") or "").endswith(needle)
            for handler in handlers.values()
        )
        if not proxies_to_app:
            continue
        host, _, listen_port = str(host_port).rpartition(":")
        host = host or str(host_port)
        if not host.endswith(".ts.net"):
            continue
        return f"https://{host}" if listen_port == "443" else f"https://{host}:{listen_port}"
    return ""


def _is_loopback_bind(host: str) -> bool:
    return host in ("127.0.0.1", "::1", "localhost")


def local_scheme() -> str:
    """`https` when run.py will find a certificate under ./certs, else `http`."""
    certs = BASE_DIR / "certs"
    return "https" if (certs / "cert.pem").is_file() and (certs / "key.pem").is_file() else "http"


def lan_address() -> str:
    """This machine's primary LAN IPv4, discovered without sending anything."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # Connecting a UDP socket only picks a route; no packet is sent.
        sock.connect(("192.0.2.1", 9))  # TEST-NET-1, never routed anywhere
        address = sock.getsockname()[0]
    except OSError:
        return ""
    finally:
        sock.close()
    return "" if not address or address.startswith("127.") else str(address)


def _discover() -> dict:
    scheme = local_scheme()
    port = settings.port
    loopback_only = _is_loopback_bind(settings.host)

    remote_url = ""
    remote_source = ""
    if settings.public_url:
        remote_url, remote_source = settings.public_url, "public_url"
    else:
        served = tailscale_serve_url(port)
        if served:
            remote_url, remote_source = served, "tailscale-serve"
        else:
            dns_name = tailscale_dns_name()
            if dns_name and not loopback_only:
                remote_url, remote_source = f"{scheme}://{dns_name}:{port}", "tailscale"

    # Addresses that reach this machine without going through a proxy. The
    # tailnet IP comes first: it works from anywhere on the tailnet and, unlike
    # the MagicDNS name, does not depend on Tailscale's DNS being enabled.
    direct_urls: list[str] = []
    tailnet_ip = ""
    if not loopback_only:
        tailnet_ip = tailscale_ipv4()
        if tailnet_ip:
            direct_urls.append(f"{scheme}://{tailnet_ip}:{port}")
        lan = lan_address()
        if lan and lan != tailnet_ip:
            direct_urls.append(f"{scheme}://{lan}:{port}")

    reachable_anywhere = bool(remote_url or tailnet_ip)
    return {
        "remote_url": remote_url,
        "remote_source": remote_source,
        "direct_urls": direct_urls,
        # False means every known address stops working once the phone leaves
        # this network — the app says so instead of failing silently.
        "reachable_anywhere": reachable_anywhere,
        "setup_hint": "" if reachable_anywhere else (
            "Run scripts/setup-remote-access.sh on this Mac to create one private "
            "address that also works on other Wi-Fi and cellular."
        ),
    }


def advertised_endpoints(*, refresh: bool = False) -> dict:
    """Addresses clients can save, newest discovery cached for a minute."""
    now = time.monotonic()
    if not refresh and _cache and now - _cache.get("at", 0.0) < _CACHE_SECONDS:
        return dict(_cache["value"])
    value = _discover()
    _cache.update(at=now, value=value)
    return dict(value)


def reset_cache() -> None:
    """Forget the cached discovery (used by the startup banner and tests)."""
    _cache.clear()
