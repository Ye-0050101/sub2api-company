#!/usr/bin/env python3

import base64
import importlib.util
from pathlib import Path
from unittest import mock
import unittest


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "deploy" / "companyctl.py"
SPEC = importlib.util.spec_from_file_location("companyctl", MODULE_PATH)
companyctl = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(companyctl)


class CompanyCtlTest(unittest.TestCase):
    def test_hex_pin_is_converted_to_base64(self):
        raw = "00" * 32
        self.assertEqual(
            companyctl.normalized_pin(raw),
            base64.b64encode(bytes(32)).decode("ascii"),
        )

    def test_hy2_selects_three_exact_ports(self):
        query = {"mport": "30000-41000,47807-47878"}
        with mock.patch("builtins.input", return_value=""):
            self.assertEqual(companyctl.hy2_ports(query, 50572, "primary"), [50572, 30000, 47807])

    def test_tuic_uri_credentials_are_parsed_without_logging(self):
        parsed, query = companyctl.parse_uri(
            "tuic://test-uuid:test-password@8.8.8.8:443?alpn=h3&sni=node.example.com",
            "tuic",
        )
        self.assertEqual(parsed.username, "test-uuid")
        self.assertEqual(parsed.password, "test-password")
        self.assertEqual(query["sni"], "node.example.com")

        parsed, _ = companyctl.parse_uri(
            "tuic://test-uuid%3Atest-password@8.8.8.8:443?sni=node.example.com",
            "tuic",
        )
        combined = companyctl.urllib.parse.unquote(parsed.username or "")
        self.assertEqual(combined.split(":", 1), ["test-uuid", "test-password"])


if __name__ == "__main__":
    unittest.main()
