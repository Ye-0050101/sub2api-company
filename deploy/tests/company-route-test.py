#!/usr/bin/env python3

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "deploy" / "company-route.py"
SPEC = importlib.util.spec_from_file_location("company_route", MODULE_PATH)
company_route = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(company_route)


def subscription():
    def outbound(kind, tag, server, port):
        value = {
            "type": kind,
            "tag": tag,
            "server": server,
            "server_port": port,
            "password": "test-secret",
            "tls": {
                "enabled": True,
                "server_name": f"{tag}.example.com",
                "insecure": False,
            },
        }
        if kind == "tuic":
            value["uuid"] = "00000000-0000-4000-8000-000000000001"
        return value

    return {
        "outbounds": [
            outbound("anytls", "primary-anytls", "9.9.9.9", 443),
            outbound("hysteria2", "primary-hy2", "9.9.9.9", 8443),
            outbound("tuic", "disaster-tuic", "8.8.4.4", 9443),
            outbound("anytls", "unused", "208.67.222.222", 443),
        ]
    }


def route_spec(route_key="us-a", proxy_id=11, socks_port=11000):
    return {
        "version": 1,
        "route_key": route_key,
        "country_code": "US",
        "proxy_id": proxy_id,
        "socks_port": socks_port,
        "api_port": socks_port + 9000,
        "expected_exit_ipv4": "8.8.8.8",
        "disaster_exit_ipv4": "1.1.1.1",
        "failure_threshold": 3,
        "candidates": [
            {
                "subscription_tag": "primary-anytls",
                "role": "primary",
                "priority": 10,
                "probe_port": socks_port + 1,
            },
            {
                "subscription_tag": "primary-hy2",
                "role": "primary",
                "priority": 20,
                "probe_port": socks_port + 2,
            },
            {
                "subscription_tag": "disaster-tuic",
                "role": "disaster",
                "priority": 100,
                "probe_port": socks_port + 3,
            },
        ],
    }


class CompanyRouteTest(unittest.TestCase):
    def test_all_approved_international_countries(self):
        for index, country in enumerate(("US", "SG", "JP", "KR", "HK", "TW")):
            spec = route_spec(
                route_key=f"{country.lower()}-a",
                proxy_id=20 + index,
                socks_port=12000 + index * 100,
            )
            spec["country_code"] = country
            route = company_route.normalize(spec, subscription())
            self.assertEqual(route["country_code"], country)

    def test_same_country_supports_multiple_independent_proxy_ids(self):
        first = company_route.normalize(route_spec(), subscription())
        second = company_route.normalize(
            route_spec("us-b", proxy_id=12, socks_port=12000), subscription()
        )
        self.assertEqual(first["country_code"], "US")
        self.assertEqual(second["country_code"], "US")
        self.assertNotEqual(first["proxy_id"], second["proxy_id"])
        self.assertNotEqual(first["socks_port"], second["socks_port"])

    def test_primary_disaster_policy_and_strict_priority(self):
        route = company_route.normalize(route_spec(), subscription())
        self.assertEqual(route["expected_exit_ipv4"], "8.8.8.8")
        self.assertEqual(route["disaster_exit_ipv4"], "1.1.1.1")
        self.assertEqual(
            [item["role"] for item in route["candidates"]],
            ["primary", "primary", "disaster"],
        )
        rendered = company_route.sing_box_config(route, "test-secret")
        selector = next(
            item for item in rendered["outbounds"] if item["type"] == "selector"
        )
        self.assertEqual(selector["default"], "block")
        self.assertEqual(selector["outbounds"][-1], "block")
        selected_types = {
            item["type"] for item in rendered["outbounds"] if item["type"] not in {"selector", "block"}
        }
        self.assertEqual(selected_types, {"anytls", "hysteria2", "tuic"})
        rendered_text = json.dumps(rendered)
        self.assertNotIn('"unused"', rendered_text)

    def test_rejects_insecure_or_hostname_node(self):
        insecure = subscription()
        insecure["outbounds"][0]["tls"]["insecure"] = 1
        with self.assertRaisesRegex(company_route.RouteError, "insecure"):
            company_route.normalize(route_spec(), insecure)

        hostname = subscription()
        hostname["outbounds"][0]["server"] = "node.example.com"
        with self.assertRaisesRegex(company_route.RouteError, "canonical public IPv4"):
            company_route.normalize(route_spec(), hostname)

    def test_hysteria2_allows_at_most_three_exact_ports(self):
        selected = subscription()
        hy2 = selected["outbounds"][1]
        hy2.pop("server_port")
        hy2["server_ports"] = ["8443", "8444", "8445"]
        route = company_route.normalize(route_spec(), selected)
        candidate = route["candidates"][1]
        self.assertEqual(candidate["node_ports"], [8443, 8444, 8445])
        self.assertEqual(
            candidate["outbound"]["server_ports"],
            ["8443:8443", "8444:8444", "8445:8445"],
        )
        guard = company_route.guard(route, 999)
        self.assertIn("udp dport { 8443, 8444, 8445 }", guard)

        for invalid in (["8443:8500"], ["8443", "8444", "8445", "8446"]):
            bad = subscription()
            bad_hy2 = bad["outbounds"][1]
            bad_hy2.pop("server_port")
            bad_hy2["server_ports"] = invalid
            with self.assertRaises(company_route.RouteError):
                company_route.normalize(route_spec(), bad)

    def test_rejects_missing_disaster_candidate_and_unknown_country(self):
        no_disaster = route_spec()
        no_disaster["candidates"] = no_disaster["candidates"][:2]
        with self.assertRaisesRegex(company_route.RouteError, "disaster candidate"):
            company_route.normalize(no_disaster, subscription())

        unknown = route_spec()
        unknown["country_code"] = "DE"
        with self.assertRaisesRegex(company_route.RouteError, "US, SG, JP, KR, HK, or TW"):
            company_route.normalize(unknown, subscription())

    def test_render_contains_no_plaintext_subscription_file(self):
        route = company_route.normalize(route_spec(), subscription())
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "route"
            company_route.render(route, output)
            self.assertTrue((output / "config.json").is_file())
            self.assertTrue((output / "metadata.json").is_file())
            self.assertTrue((output / "clash-api.secret").is_file())
            self.assertFalse((output / "subscription.json").exists())


if __name__ == "__main__":
    unittest.main()
