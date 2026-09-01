#!/usr/bin/env python3
"""Validate selected subscription outbounds and control one Company route."""

from __future__ import annotations

import argparse
import copy
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

ALLOWED_COUNTRIES = {"US", "SG", "JP", "KR"}
ALLOWED_PROTOCOLS = {"anytls": "tcp", "hysteria2": "udp", "tuic": "udp"}
ROUTE_KEY_RE = re.compile(r"^[a-z][a-z0-9-]{1,15}$")
HOSTNAME_RE = re.compile(
    r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$"
)
CONFIG_ROOT = Path("/etc/sub2api-egress/routes")
PROBE_B_URL = "https://cloudflare.com/cdn-cgi/trace"


class RouteError(RuntimeError):
    pass


def run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
    )
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise RouteError(f"{' '.join(command)} failed: {detail}")
    return result


def public_ipv4(raw: object, field: str) -> str:
    value = str(raw or "").strip()
    try:
        address = ipaddress.ip_address(value)
    except ValueError as exc:
        raise RouteError(f"{field} must be a canonical public IPv4") from exc
    if address.version != 4 or str(address) != value or not address.is_global:
        raise RouteError(f"{field} must be a canonical public IPv4")
    return value


def port(raw: object, field: str) -> int:
    if isinstance(raw, bool):
        raise RouteError(f"{field} must be an integer port")
    try:
        value = int(raw)
    except (TypeError, ValueError) as exc:
        raise RouteError(f"{field} must be an integer port") from exc
    if not 1 <= value <= 65535:
        raise RouteError(f"{field} must be between 1 and 65535")
    return value


def load_json(path: Path, label: str, *, root_secret: bool = False) -> dict:
    if not path.is_absolute() or not path.is_file():
        raise RouteError(f"{label} must be an absolute regular file")
    if root_secret and getattr(os, "geteuid", lambda: 1)() == 0:
        stat = path.stat()
        if stat.st_uid != 0 or stat.st_mode & 0o077:
            raise RouteError(f"{label} must be root-owned and mode 0600")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RouteError(f"{label} is invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise RouteError(f"{label} must contain a JSON object")
    return value


def validate_outbound(raw: object, label: str) -> tuple[dict, str, str, int]:
    if not isinstance(raw, dict):
        raise RouteError(f"{label} must be an object")
    outbound = copy.deepcopy(raw)
    protocol = str(outbound.get("type") or "").strip().lower()
    if protocol not in ALLOWED_PROTOCOLS:
        raise RouteError(f"{label}.type must be anytls, hysteria2, or tuic")
    node_ip = public_ipv4(outbound.get("server"), f"{label}.server")
    node_port = port(outbound.get("server_port"), f"{label}.server_port")
    if "server_ports" in outbound:
        raise RouteError(f"{label}.server_ports/port hopping is prohibited")
    if str(outbound.get("detour") or "").strip() or "domain_resolver" in outbound:
        raise RouteError(f"{label} must not use detour or a DNS resolver")
    tls = outbound.get("tls")
    if not isinstance(tls, dict) or tls.get("enabled") is not True:
        raise RouteError(f"{label}.tls.enabled must be true")
    for key in ("insecure", "allow_insecure", "allowInsecure"):
        if tls.get(key) not in (None, False, 0):
            raise RouteError(f"{label}.tls.{key} must not enable insecure TLS")
    server_name = str(tls.get("server_name") or "").strip()
    if not HOSTNAME_RE.fullmatch(server_name):
        raise RouteError(f"{label}.tls.server_name must be an explicit hostname")
    if protocol in {"anytls", "hysteria2"} and not str(outbound.get("password") or ""):
        raise RouteError(f"{label}.password is required")
    if protocol == "tuic" and (
        not str(outbound.get("uuid") or "") or not str(outbound.get("password") or "")
    ):
        raise RouteError(f"{label}.uuid and password are required")
    return outbound, ALLOWED_PROTOCOLS[protocol], node_ip, node_port


def normalize(spec: dict, subscription: dict) -> dict:
    if spec.get("version") != 1:
        raise RouteError("route spec version must be 1")
    route_key = str(spec.get("route_key") or "").strip().lower()
    if not ROUTE_KEY_RE.fullmatch(route_key):
        raise RouteError("route_key must match [a-z][a-z0-9-]{1,15}")
    country = str(spec.get("country_code") or "").strip().upper()
    if country not in ALLOWED_COUNTRIES:
        raise RouteError("country_code must be US, SG, JP, or KR")
    proxy_id = int(spec.get("proxy_id") or 0)
    if proxy_id <= 0:
        raise RouteError("proxy_id must be positive")
    socks_port = port(spec.get("socks_port"), "socks_port")
    api_port = port(spec.get("api_port"), "api_port")
    primary_ip = public_ipv4(spec.get("expected_exit_ipv4"), "expected_exit_ipv4")
    disaster_raw = str(spec.get("disaster_exit_ipv4") or "").strip()
    disaster_ip = public_ipv4(disaster_raw, "disaster_exit_ipv4") if disaster_raw else ""
    if disaster_ip == primary_ip:
        raise RouteError("disaster_exit_ipv4 must differ from expected_exit_ipv4")
    threshold = int(spec.get("failure_threshold") or 3)
    if not 1 <= threshold <= 10:
        raise RouteError("failure_threshold must be between 1 and 10")

    outbounds = subscription.get("outbounds")
    if not isinstance(outbounds, list):
        raise RouteError("subscription must contain an outbounds array")
    by_tag: dict[str, dict] = {}
    for raw in outbounds:
        if isinstance(raw, dict) and isinstance(raw.get("tag"), str):
            tag = raw["tag"].strip()
            if tag:
                if tag in by_tag:
                    raise RouteError(f"duplicate subscription tag: {tag}")
                by_tag[tag] = raw

    raw_candidates = spec.get("candidates")
    if not isinstance(raw_candidates, list) or not 1 <= len(raw_candidates) <= 8:
        raise RouteError("candidates must contain between 1 and 8 entries")
    used_ports = {socks_port, api_port}
    source_tags: set[str] = set()
    priorities: set[int] = set()
    candidates = []
    for index, item in enumerate(raw_candidates):
        if not isinstance(item, dict):
            raise RouteError(f"candidates[{index}] must be an object")
        source_tag = str(item.get("subscription_tag") or "").strip()
        if source_tag not in by_tag or source_tag in source_tags:
            raise RouteError(f"candidates[{index}] has a missing or duplicate subscription_tag")
        source_tags.add(source_tag)
        role = str(item.get("role") or "").strip().lower()
        if role not in {"primary", "disaster"}:
            raise RouteError(f"candidates[{index}].role must be primary or disaster")
        if role == "disaster" and not disaster_ip:
            raise RouteError("disaster candidate requires disaster_exit_ipv4")
        probe_port = port(item.get("probe_port"), f"candidates[{index}].probe_port")
        if probe_port in used_ports:
            raise RouteError(f"duplicate route port: {probe_port}")
        used_ports.add(probe_port)
        priority = int(item.get("priority") or (index + 1) * 10)
        if not 1 <= priority <= 1000 or priority in priorities:
            raise RouteError("candidate priorities must be unique integers from 1 to 1000")
        priorities.add(priority)
        outbound, network, node_ip, node_port = validate_outbound(
            by_tag[source_tag], f"subscription outbound {source_tag!r}"
        )
        tag = f"company-{route_key}-{index + 1}"
        outbound["tag"] = tag
        candidates.append(
            {
                "tag": tag,
                "source_tag": source_tag,
                "role": role,
                "priority": priority,
                "probe_port": probe_port,
                "expected_exit_ipv4": primary_ip if role == "primary" else disaster_ip,
                "network": network,
                "node_ipv4": node_ip,
                "node_port": node_port,
                "outbound": outbound,
            }
        )
    if not any(item["role"] == "primary" for item in candidates):
        raise RouteError("at least one primary candidate is required")
    if disaster_ip and not any(item["role"] == "disaster" for item in candidates):
        raise RouteError("disaster_exit_ipv4 requires a disaster candidate")
    candidates.sort(key=lambda item: item["priority"])
    return {
        "version": 1,
        "route_key": route_key,
        "country_code": country,
        "proxy_id": proxy_id,
        "socks_port": socks_port,
        "api_port": api_port,
        "expected_exit_ipv4": primary_ip,
        "disaster_exit_ipv4": disaster_ip,
        "failure_threshold": threshold,
        "selector_tag": f"company-{route_key}-selector",
        "candidates": candidates,
    }


def metadata(route: dict) -> dict:
    keys = (
        "version", "route_key", "country_code", "proxy_id", "socks_port",
        "api_port", "expected_exit_ipv4", "disaster_exit_ipv4",
        "failure_threshold", "selector_tag",
    )
    candidate_keys = (
        "tag", "source_tag", "role", "priority", "probe_port",
        "expected_exit_ipv4", "network", "node_ipv4", "node_port",
    )
    return {key: route[key] for key in keys} | {
        "candidates": [
            {key: item[key] for key in candidate_keys} for item in route["candidates"]
        ]
    }


def sing_box_config(route: dict, secret: str) -> dict:
    unified = f"{route['route_key']}-unified-in"
    inbounds = [{
        "type": "socks", "tag": unified, "listen": "127.0.0.1",
        "listen_port": route["socks_port"],
    }]
    rules = [{"inbound": [unified], "action": "route", "outbound": route["selector_tag"]}]
    outbounds = []
    for candidate in route["candidates"]:
        probe_tag = f"{candidate['tag']}-probe-in"
        inbounds.append({
            "type": "socks", "tag": probe_tag, "listen": "127.0.0.1",
            "listen_port": candidate["probe_port"],
        })
        rules.append({"inbound": [probe_tag], "action": "route", "outbound": candidate["tag"]})
        outbounds.append(candidate["outbound"])
    outbounds.extend([
        {
            "type": "selector", "tag": route["selector_tag"],
            "outbounds": [item["tag"] for item in route["candidates"]] + ["block"],
            "default": "block", "interrupt_exist_connections": True,
        },
        {"type": "block", "tag": "block"},
    ])
    return {
        "log": {"level": "info", "timestamp": True},
        "inbounds": inbounds,
        "outbounds": outbounds,
        "route": {"rules": rules, "final": "block", "auto_detect_interface": True},
        "experimental": {"clash_api": {
            "external_controller": f"127.0.0.1:{route['api_port']}", "secret": secret,
        }},
    }


def render(route: dict, output: Path) -> None:
    if not output.is_absolute():
        raise RouteError("output must be an absolute path")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    secret = os.urandom(32).hex()
    (output / "config.json").write_text(
        json.dumps(sing_box_config(route, secret), indent=2) + "\n", encoding="utf-8"
    )
    (output / "metadata.json").write_text(
        json.dumps(metadata(route), indent=2) + "\n", encoding="utf-8"
    )
    (output / "clash-api.secret").write_text(secret + "\n", encoding="utf-8")
    env_lines = [
        f"ROUTE_KEY={route['route_key']}",
        f"COUNTRY_CODE={route['country_code']}",
        f"PROXY_ID={route['proxy_id']}",
        f"SOCKS_PORT={route['socks_port']}",
        f"API_PORT={route['api_port']}",
        f"EXPECTED_EXIT_IPV4={route['expected_exit_ipv4']}",
        f"DISASTER_EXIT_IPV4={route['disaster_exit_ipv4']}",
        f"FAILURE_THRESHOLD={route['failure_threshold']}",
    ]
    (output / "route.env").write_text("\n".join(env_lines) + "\n", encoding="utf-8")
    for path in output.iterdir():
        path.chmod(0o600)


def installed_route(route_key: str) -> tuple[dict, str]:
    route_dir = CONFIG_ROOT / route_key
    value = load_json(route_dir / "metadata.json", "installed route metadata")
    secret = (route_dir / "clash-api.secret").read_text(encoding="utf-8").strip()
    if not secret:
        raise RouteError("installed Clash API secret is empty")
    return value, secret


def clash(route: dict, secret: str, method: str, body: dict | None = None) -> dict:
    selector = urllib.parse.quote(route["selector_tag"], safe="")
    request = urllib.request.Request(
        f"http://127.0.0.1:{route['api_port']}/proxies/{selector}",
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"Authorization": f"Bearer {secret}", "Content-Type": "application/json"},
    )
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=3) as response:
            payload = response.read(65536)
        value = json.loads(payload or b"{}")
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
        raise RouteError(f"local Clash API failed: {exc}") from exc
    if not isinstance(value, dict):
        raise RouteError("local Clash API returned invalid data")
    return value


def candidate_healthy(candidate: dict, country: str) -> bool:
    result = run([
        "curl", "--proto", "=https", "--fail", "--silent", "--show-error",
        "--connect-timeout", "8", "--max-time", "20", "--noproxy", "",
        "--proxy", f"socks5h://127.0.0.1:{candidate['probe_port']}", PROBE_B_URL,
    ], check=False)
    if result.returncode != 0:
        return False
    evidence = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            evidence[key] = value
    try:
        observed = public_ipv4(evidence.get("ip"), "probe ip")
    except RouteError:
        return False
    return observed == candidate["expected_exit_ipv4"] and evidence.get("loc") == country


def failover(route_key: str) -> None:
    route, secret = installed_route(route_key)
    current = str(clash(route, secret, "GET").get("now") or "block")
    health = {
        item["tag"]: candidate_healthy(item, route["country_code"])
        for item in route["candidates"]
    }
    best = next((item["tag"] for item in route["candidates"] if health[item["tag"]]), None)
    state_dir = Path("/var/lib/sub2api-route-control")
    state_dir.mkdir(mode=0o750, parents=True, exist_ok=True)
    state_path = state_dir / f"{route_key}.json"
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        state = {}
    failures = int(state.get("consecutive_failures") or 0)

    if current == "block":
        if best is None:
            failures += 1
        else:
            clash(route, secret, "PUT", {"name": best})
            current, failures = best, 0
    elif health.get(current, False):
        failures = 0
        if best is not None and best != current:
            clash(route, secret, "PUT", {"name": best})
            current = best
    else:
        failures += 1
        if failures >= int(route["failure_threshold"]):
            target = best or "block"
            if target != current:
                clash(route, secret, "PUT", {"name": target})
            current = target
            if best is not None:
                failures = 0

    state_path.write_text(
        json.dumps({"current": current, "consecutive_failures": failures}, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )
    state_path.chmod(0o640)
    print(f"route={route_key} selector={current} failures={failures}")
    if current == "block" or not health.get(current, False):
        raise RouteError("route remains fail-closed while no selected candidate is healthy")


def guard(route: dict, uid: int) -> str:
    table = "sub2api_" + route["route_key"].replace("-", "_") + "_guard"
    lines = [
        f"table inet {table} {{",
        " chain output { type filter hook output priority 0; policy accept;",
        f"  meta skuid {uid} meta nfproto ipv6 counter reject",
        f'  meta skuid {uid} oifname "lo" counter accept',
    ]
    for item in route["candidates"]:
        lines.append(
            f"  meta skuid {uid} ip daddr {item['node_ipv4']} "
            f"{item['network']} dport {item['node_port']} counter accept"
        )
    lines.extend([f"  meta skuid {uid} counter reject", " }", "}", ""])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("validate", "render"):
        child = commands.add_parser(name)
        child.add_argument("--spec", required=True, type=Path)
        child.add_argument("--subscription", required=True, type=Path)
        if name == "render":
            child.add_argument("--output", required=True, type=Path)
    failover_parser = commands.add_parser("failover")
    failover_parser.add_argument("--route-key", required=True)
    guard_parser = commands.add_parser("guard")
    guard_parser.add_argument("--metadata", required=True, type=Path)
    guard_parser.add_argument("--uid", required=True, type=int)
    args = parser.parse_args()

    try:
        if args.command in {"validate", "render"}:
            route = normalize(
                load_json(args.spec, "route spec", root_secret=args.command == "render"),
                load_json(
                    args.subscription, "subscription", root_secret=args.command == "render"
                ),
            )
            if args.command == "validate":
                print(json.dumps(metadata(route), indent=2))
            else:
                render(route, args.output)
        elif args.command == "guard":
            route = load_json(args.metadata, "route metadata")
            if args.uid <= 0:
                raise RouteError("uid must be positive")
            print(guard(route, args.uid), end="")
        else:
            route_key = args.route_key.strip().lower()
            if not ROUTE_KEY_RE.fullmatch(route_key):
                raise RouteError("invalid route_key")
            failover(route_key)
    except RouteError as exc:
        print(f"REFUSING: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
