#!/usr/bin/env python3
"""Interactive Company egress operations without exposing node credentials."""

from __future__ import annotations

import argparse
import base64
import binascii
import getpass
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse


COUNTRIES = ("US", "SG", "JP", "KR", "HK", "TW")
ROUTES = Path("/etc/sub2api-egress/routes")
CONFIG = Path("/opt/sub2api/config.yaml")


class CompanyCtlError(RuntimeError):
    pass


def prompt(label: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    value = input(f"{label}{suffix}: ").strip()
    return value or default


def secret(label: str, required: bool = False) -> str:
    value = getpass.getpass(f"{label} (hidden, blank=skip): ").strip()
    if required and not value:
        raise CompanyCtlError(f"{label} is required")
    return value


def checked_port(raw: object, label: str) -> int:
    try:
        value = int(raw)
    except (TypeError, ValueError) as exc:
        raise CompanyCtlError(f"{label} must be an integer port") from exc
    if not 1 <= value <= 65535:
        raise CompanyCtlError(f"{label} must be between 1 and 65535")
    return value


def public_ipv4(raw: str, label: str) -> str:
    try:
        value = ipaddress.ip_address(raw.strip())
    except (ValueError, binascii.Error) as exc:
        raise CompanyCtlError(f"{label} must be a public IPv4") from exc
    if value.version != 4 or not value.is_global or str(value) != raw.strip():
        raise CompanyCtlError(f"{label} must be a canonical public IPv4")
    return str(value)


def parse_uri(raw: str, expected_scheme: str) -> tuple[urllib.parse.SplitResult, dict[str, str]]:
    parsed = urllib.parse.urlsplit(raw.strip())
    if parsed.scheme.lower() != expected_scheme:
        raise CompanyCtlError(f"expected {expected_scheme} URI")
    if not parsed.hostname or parsed.port is None:
        raise CompanyCtlError(f"{expected_scheme} URI must contain host and port")
    public_ipv4(parsed.hostname, f"{expected_scheme} server")
    checked_port(parsed.port, f"{expected_scheme} server_port")
    query = {
        key.lower(): values[-1]
        for key, values in urllib.parse.parse_qs(parsed.query, keep_blank_values=True).items()
    }
    return parsed, query


def query_value(query: dict[str, str], *names: str, default: str = "") -> str:
    for name in names:
        value = query.get(name.lower())
        if value:
            return value
    return default


def normalized_pin(raw: str) -> str:
    value = raw.strip()
    if re.fullmatch(r"[0-9a-fA-F]{64}", value):
        return base64.b64encode(bytes.fromhex(value)).decode("ascii")
    try:
        decoded = base64.b64decode(value, validate=True)
    except ValueError as exc:
        raise CompanyCtlError("pinSHA256 must be 64 hex characters or base64") from exc
    if len(decoded) != 32:
        raise CompanyCtlError("pinSHA256 must decode to 32 bytes")
    return value


def derive_tcp_public_key_pin(server: str, port: int, server_name: str) -> str:
    try:
        handshake = subprocess.run(
            ["openssl", "s_client", "-servername", server_name, "-connect", f"{server}:{port}"],
            input=b"",
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=12,
            check=True,
        ).stdout
        public_key = subprocess.run(
            ["openssl", "x509", "-pubkey", "-noout"],
            input=handshake,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        ).stdout
        der = subprocess.run(
            ["openssl", "pkey", "-pubin", "-outform", "DER"],
            input=public_key,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=True,
        ).stdout
    except (OSError, subprocess.SubprocessError) as exc:
        raise CompanyCtlError(f"cannot derive AnyTLS public key pin for {server}:{port}") from exc
    if not der:
        raise CompanyCtlError("AnyTLS server returned no certificate public key")
    return base64.b64encode(hashlib.sha256(der).digest()).decode("ascii")


def tls_options(query: dict[str, str], server: str, port: int, protocol: str, fallback_pin: str = "") -> tuple[dict, str]:
    server_name = query_value(query, "sni", "server_name")
    if not re.fullmatch(r"(?=.{1,253}$)[A-Za-z0-9.-]+", server_name):
        raise CompanyCtlError(f"{protocol} requires an explicit TLS server name")
    raw_pin = query_value(query, "pinsha256", "pin_sha256", "certificate_public_key_sha256")
    if raw_pin:
        pin = normalized_pin(raw_pin)
    elif protocol == "anytls":
        print(f"Deriving pinned AnyTLS certificate identity from {server}:{port} ...")
        pin = derive_tcp_public_key_pin(server, port, server_name)
    elif fallback_pin:
        pin = fallback_pin
        print(f"{protocol}: using the same-node HY2 pin; a mismatch will fail closed")
    else:
        raise CompanyCtlError(f"{protocol} requires pinSHA256")
    alpn = [value for value in query_value(query, "alpn").split(",") if value]
    tls = {
        "enabled": True,
        "server_name": server_name,
        "insecure": False,
        "certificate_public_key_sha256": [pin],
    }
    if alpn:
        tls["alpn"] = alpn
    return tls, pin


def hy2_ports(query: dict[str, str], base_port: int, role: str) -> list[int]:
    suggested = [base_port]
    raw = query_value(query, "mport", "server_ports")
    for token in raw.split(","):
        token = token.strip()
        if not token:
            continue
        start = re.split(r"[:-]", token, maxsplit=1)[0]
        try:
            candidate = checked_port(start, "HY2 explicit port")
        except CompanyCtlError:
            continue
        if candidate not in suggested:
            suggested.append(candidate)
        if len(suggested) == 3:
            break
    default = ",".join(str(value) for value in suggested)
    raw_selected = prompt(f"{role} HY2 exact ports (1-3, comma separated)", default)
    selected = [checked_port(value.strip(), "HY2 explicit port") for value in raw_selected.split(",") if value.strip()]
    if not 1 <= len(selected) <= 3 or len(selected) != len(set(selected)):
        raise CompanyCtlError("HY2 requires 1 to 3 unique exact ports")
    return selected


def build_group(role: str) -> list[dict]:
    raw_anytls = secret(f"{role} AnyTLS URI")
    raw_hy2 = secret(f"{role} Hysteria2 URI")
    raw_tuic = secret(f"{role} TUIC URI")
    if not any((raw_anytls, raw_hy2, raw_tuic)):
        raise CompanyCtlError(f"{role} requires at least one protocol")

    outbounds: list[dict] = []
    hy2_pin = ""
    if raw_anytls:
        parsed, query = parse_uri(raw_anytls, "anytls")
        password = urllib.parse.unquote(parsed.username or "")
        if not password:
            raise CompanyCtlError("AnyTLS password is missing")
        tls, _ = tls_options(query, parsed.hostname or "", parsed.port or 0, "anytls")
        outbounds.append({
            "type": "anytls", "tag": f"{role}-anytls", "server": parsed.hostname,
            "server_port": parsed.port, "password": password, "tls": tls,
        })

    if raw_hy2:
        parsed, query = parse_uri(raw_hy2, "hysteria2")
        password = urllib.parse.unquote(parsed.username or "")
        if not password:
            raise CompanyCtlError("Hysteria2 password is missing")
        tls, hy2_pin = tls_options(query, parsed.hostname or "", parsed.port or 0, "hysteria2")
        ports = hy2_ports(query, parsed.port or 0, role)
        outbound = {
            "type": "hysteria2", "tag": f"{role}-hy2", "server": parsed.hostname,
            "password": password, "tls": tls,
        }
        if len(ports) == 1:
            outbound["server_port"] = ports[0]
        else:
            outbound["server_ports"] = [str(value) for value in ports]
            outbound["hop_interval"] = "30s"
        outbounds.append(outbound)

    if raw_tuic:
        parsed, query = parse_uri(raw_tuic, "tuic")
        uuid = urllib.parse.unquote(parsed.username or "")
        password = urllib.parse.unquote(parsed.password or "")
        if not password and ":" in uuid:
            uuid, password = uuid.split(":", 1)
        if not uuid or not password:
            raise CompanyCtlError("TUIC UUID/password is missing")
        tls, _ = tls_options(query, parsed.hostname or "", parsed.port or 0, "tuic", hy2_pin)
        outbounds.append({
            "type": "tuic", "tag": f"{role}-tuic", "server": parsed.hostname,
            "server_port": parsed.port, "uuid": uuid, "password": password,
            "congestion_control": query_value(query, "congestion_control", default="bbr"),
            "udp_relay_mode": query_value(query, "udp_relay_mode", default="native"),
            "tls": tls,
        })
    return outbounds


def secure_unlink(path: Path) -> None:
    try:
        size = path.stat().st_size
        path.write_bytes(b"\x00" * size)
        path.unlink()
    except FileNotFoundError:
        pass


def route_add() -> None:
    country = prompt("Country US/SG/JP/KR/HK/TW").upper()
    if country not in COUNTRIES:
        raise CompanyCtlError("unsupported country")
    route_key = prompt("Route key", f"{country.lower()}-a")
    if not re.fullmatch(r"[a-z][a-z0-9-]{1,15}", route_key):
        raise CompanyCtlError("invalid route key")
    proxy_id = int(prompt("ProxyID"))
    socks_port = checked_port(prompt("Unified SOCKS port"), "SOCKS port")
    api_port = checked_port(prompt("Local selector API port", str(socks_port + 8000)), "API port")
    primary_ip = public_ipv4(prompt("Primary expected exit IPv4"), "primary exit")
    disaster_ip_raw = prompt("Disaster expected exit IPv4 (blank=none)")
    disaster_ip = public_ipv4(disaster_ip_raw, "disaster exit") if disaster_ip_raw else ""
    if disaster_ip == primary_ip:
        raise CompanyCtlError("primary and disaster exit IP must differ")

    primary = build_group("primary")
    disaster = build_group("disaster") if disaster_ip else []
    outbounds = primary + disaster
    candidates = []
    for index, outbound in enumerate(outbounds):
        role = "primary" if outbound["tag"].startswith("primary-") else "disaster"
        role_index = index if role == "primary" else index - len(primary)
        candidates.append({
            "subscription_tag": outbound["tag"],
            "role": role,
            "priority": (10 + role_index * 10) if role == "primary" else (110 + role_index * 10),
            "probe_port": socks_port + index + 1,
        })
    spec = {
        "version": 1, "route_key": route_key, "country_code": country,
        "proxy_id": proxy_id, "socks_port": socks_port, "api_port": api_port,
        "expected_exit_ipv4": primary_ip, "disaster_exit_ipv4": disaster_ip,
        "failure_threshold": 3, "candidates": candidates,
    }
    temp_dir = Path(tempfile.mkdtemp(prefix="companyctl-route-", dir="/root"))
    spec_path = temp_dir / "route.json"
    selected_path = temp_dir / "selected.json"
    try:
        spec_path.write_text(json.dumps(spec, indent=2) + "\n", encoding="utf-8")
        selected_path.write_text(json.dumps({"outbounds": outbounds}, indent=2) + "\n", encoding="utf-8")
        os.chmod(spec_path, 0o600)
        os.chmod(selected_path, 0o600)
        subprocess.run(
            ["/usr/local/sbin/company-route-add", "--spec", str(spec_path), "--subscription", str(selected_path)],
            check=True,
        )
    except subprocess.CalledProcessError as exc:
        raise CompanyCtlError("route activation failed and was rolled back") from exc
    finally:
        secure_unlink(selected_path)
        secure_unlink(spec_path)
        shutil.rmtree(temp_dir, ignore_errors=True)


def route_list() -> None:
    if not ROUTES.is_dir():
        print("No managed international routes")
        return
    for path in sorted(ROUTES.glob("*/metadata.json")):
        route = json.loads(path.read_text(encoding="utf-8"))
        state_path = Path("/var/lib/sub2api-route-control") / f"{route['route_key']}.json"
        try:
            state = json.loads(state_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            state = {"current": "unknown"}
        print(
            f"{route['route_key']} country={route['country_code']} proxy_id={route['proxy_id']} "
            f"socks=127.0.0.1:{route['socks_port']} selector={state.get('current', 'unknown')} "
            f"primary={route['expected_exit_ipv4']} disaster={route.get('disaster_exit_ipv4') or '-'}"
        )


def load_config() -> dict:
    try:
        import yaml
    except ImportError as exc:
        raise CompanyCtlError("python3-yaml is required") from exc
    return yaml.safe_load(CONFIG.read_text(encoding="utf-8")) or {}


def psql(database: str, sql: str) -> str:
    return subprocess.run(
        ["sudo", "-u", "postgres", "psql", "-X", "-At", "-F", "\t", "-d", database, "-c", sql],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
    ).stdout


def verify() -> None:
    cfg = load_config()
    cn = next((item for item in (cfg.get("company_egress") or {}).get("managed_proxies", []) if item.get("class") == "CN_DIRECT"), None)
    if not cn:
        raise CompanyCtlError("CN_DIRECT policy is missing")
    database = str((cfg.get("database") or {}).get("dbname") or "")
    port_value = psql(database, f"SELECT port FROM proxies WHERE id={int(cn['proxy_id'])} AND deleted_at IS NULL;").strip()
    cn_port = checked_port(port_value, "CN SOCKS port")
    binary_sha = hashlib.sha256(Path("/opt/sub2api/sub2api").read_bytes()).hexdigest()
    os.execv(
        "/usr/local/sbin/company-verify-egress",
        ["company-verify-egress", "--sha256", binary_sha, "--cn-socks-port", str(cn_port), "--cn-exit-ip", str(cn["expected_exit_ipv4"])],
    )


def account_audit() -> None:
    cfg = load_config()
    policies = {int(item["proxy_id"]): item["class"] for item in (cfg.get("company_egress") or {}).get("managed_proxies", [])}
    database = str((cfg.get("database") or {}).get("dbname") or "")
    rows = psql(database, "SELECT id,name,platform,type,COALESCE(proxy_id::text,'') FROM accounts WHERE deleted_at IS NULL ORDER BY id;")
    failures = 0
    international = {"anthropic", "openai", "grok", "gemini"}
    china = {"deepseek", "kimi", "zhipu"}
    for line in rows.splitlines():
        account_id, name, platform, account_type, proxy_raw = line.split("\t")
        required = "INTERNATIONAL_PROXY" if platform in international else "CN_DIRECT" if platform in china else ""
        if not required:
            continue
        proxy_id = int(proxy_raw) if proxy_raw else 0
        actual = policies.get(proxy_id, "")
        status = "PASS" if actual == required else "FAIL"
        failures += status == "FAIL"
        print(f"{status} account={account_id} name={name} platform={platform}/{account_type} proxy_id={proxy_id or '-'} class={actual or '-'}")
    if failures:
        raise CompanyCtlError(f"account audit failed: {failures} account(s)")


def main() -> int:
    if os.geteuid() != 0:
        print("REFUSING: run companyctl with sudo", file=sys.stderr)
        return 1
    if len(sys.argv) > 1 and sys.argv[1] == "deploy":
        os.execv(
            "/usr/local/sbin/company-deploy-egress",
            ["company-deploy-egress", *sys.argv[2:]],
        )
    parser = argparse.ArgumentParser(prog="companyctl")
    sub = parser.add_subparsers(dest="command", required=True)
    route = sub.add_parser("route")
    route_sub = route.add_subparsers(dest="route_command", required=True)
    route_sub.add_parser("add")
    route_sub.add_parser("list")
    sub.add_parser("verify")
    account = sub.add_parser("account")
    account_sub = account.add_subparsers(dest="account_command", required=True)
    account_sub.add_parser("audit")
    args = parser.parse_args()
    try:
        if args.command == "route" and args.route_command == "add":
            route_add()
        elif args.command == "route":
            route_list()
        elif args.command == "verify":
            verify()
        elif args.command == "account":
            account_audit()
    except (CompanyCtlError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"REFUSING: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
