#!/usr/bin/env python3

import base64
import importlib.util
from pathlib import Path
import re
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

    def test_operations_keep_exact_probe_and_verified_backup_policy(self):
        install = (ROOT / "deploy" / "company-install-fresh.sh").read_text()
        activate = (ROOT / "deploy" / "company-activate-egress.sh").read_text()
        verify = (ROOT / "deploy" / "company-verify-egress.sh").read_text()
        deploy = (ROOT / "deploy" / "company-deploy-egress.sh").read_text()
        expected_urls = (
            "https://api.ipify.org?format=json",
            "https://cloudflare.com/cdn-cgi/trace",
        )
        for source in (install, activate, verify, deploy):
            for url in expected_urls:
                self.assertIn(url, source)
        self.assertIn('"insecure_skip_verify": False', install)
        self.assertIn('"insecure_skip_verify": False', activate)
        self.assertIn('"insecure_skip_verify": False', verify)
        self.assertIn('"insecure_skip_verify": False', deploy)
        self.assertIn("--format=custom", deploy)
        self.assertIn("pg_database_size", deploy)
        self.assertIn("available_bytes", deploy)
        self.assertIn("pg_restore --list", deploy)
        self.assertIn("DATABASE_BACKUP=", deploy)
        self.assertIn("DATABASE_BACKUP_SHA256=", deploy)
        self.assertIn("new_binary_may_have_migrated=1", deploy)
        self.assertIn("Sub2API remains stopped", deploy)
        self.assertIn("trap rollback ERR INT TERM", deploy)

    def test_update_closes_ubuntu22_branch_without_force(self):
        update = (ROOT / "tools" / "company-update.ps1").read_text()
        self.assertIn("company/egress-v1-ubuntu22.04", update)
        self.assertIn("Wait-CompanyChecks", update)
        self.assertIn("'push', '--atomic', 'origin'", update)
        self.assertIn("refs/heads/main", update)
        self.assertIn("refs/heads/{1}", update)
        self.assertIn("merge-base --is-ancestor", update)
        self.assertIn("ubuntu22_binary_sha256", update)
        self.assertIn("Ubuntu 22.04 operations file hash mismatch", update)
        self.assertLess(
            update.index("$ubuntuChecks = Wait-CompanyChecks"),
            update.index("'push', '--atomic', 'origin'"),
        )
        self.assertNotIn("--force", update)

    def test_route_success_clears_the_real_config_rollback_flag(self):
        apply = (ROOT / "deploy" / "company-route-apply.sh").read_text()
        self.assertIsNone(re.search(r"^pp_config_changed=", apply, re.MULTILINE))


if __name__ == "__main__":
    unittest.main()
