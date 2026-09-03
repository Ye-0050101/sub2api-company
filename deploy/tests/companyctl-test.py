#!/usr/bin/env python3

import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from unittest import mock
import unittest


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "deploy" / "companyctl.py"
SPEC = importlib.util.spec_from_file_location("companyctl", MODULE_PATH)
companyctl = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(companyctl)


class CompanyCtlTest(unittest.TestCase):
    def test_lan_http_render_keeps_egress_and_forwarded_identity_separate(self):
        rendered = companyctl.render_lan_http("192.168.1.175", "Hsaiapi.corp.example", ["172.16.40.0/24"])
        self.assertIn("listen 192.168.1.175:80", rendered)
        self.assertIn("server_name hsaiapi.corp.example 192.168.1.175;", rendered)
        self.assertIn("allow 172.16.40.0/24;", rendered)
        self.assertIn("deny all;", rendered)
        self.assertIn("return 444;", rendered)
        self.assertIn("proxy_pass http://127.0.0.1:8080;", rendered)
        self.assertIn("X-Forwarded-For $remote_addr", rendered)
        for forbidden in ("listen 0.0.0.0", "listen [::]", "ssl_certificate", "nft", "sing-box"):
            self.assertNotIn(forbidden, rendered)

    def test_lan_http_rejects_public_or_injected_configuration(self):
        for ip, host, nets in (
            ("0.0.0.0", "corp.example", ["192.168.1.0/24"]),
            ("8.8.8.8", "corp.example", ["192.168.1.0/24"]),
            ("::1", "corp.example", ["192.168.1.0/24"]),
            ("192.168.1.175", "corp.example;include /etc/passwd", ["192.168.1.0/24"]),
            ("192.168.1.175", "https://corp.example", ["192.168.1.0/24"]),
            ("192.168.1.175", "8.8.8.8", ["192.168.1.0/24"]),
            ("192.168.1.175", "192.168.1.176", ["192.168.1.0/24"]),
            ("192.168.1.175", "corp.example", ["0.0.0.0/0"]),
            ("192.168.1.175", "corp.example", ["192.168.1.4/24"]),
            ("192.168.1.175", "corp.example", []),
        ):
            with self.subTest(ip=ip, host=host, nets=nets):
                with self.assertRaises((companyctl.CompanyCtlError, ValueError)):
                    companyctl.render_lan_http(ip, host, nets)

    def test_lan_http_preview_does_not_apply(self):
        args = companyctl.argparse.Namespace(acknowledge_plaintext=True, check=True, listen_ip="192.168.1.175", server_name="corp.example", allow_cidr=["192.168.1.0/24"])
        with mock.patch.object(companyctl, "apply_lan_http") as apply, mock.patch("sys.stdout", new_callable=io.StringIO):
            companyctl.web_http(args)
            apply.assert_not_called()
        args.acknowledge_plaintext = False
        with self.assertRaisesRegex(companyctl.CompanyCtlError, "plaintext"):
            companyctl.web_http(args)

    def test_nginx_hidden_listeners_are_rejected(self):
        path = Path("/etc/nginx/conf.d/other.conf")
        for source in ("server { listen 0.0.0.0:80; }", "stream { server { listen 8080; } }"):
            with self.assertRaisesRegex(companyctl.CompanyCtlError, "unmanaged nginx listener"):
                companyctl.check_nginx_listener_scope(f"# configuration file {path}:\n{source}\n", set())
        companyctl.check_nginx_listener_scope(f"# configuration file {path}:\nmap $http_upgrade $connection_upgrade {{ default upgrade; }}\n", set())
        companyctl.check_nginx_listener_scope(f"# configuration file {path}:\nserver {{ listen 443; }}\n", {path})

    def test_verify_never_certifies_a_self_computed_hash(self):
        cfg = {"database": {"dbname": "test"}, "company_egress": {"managed_proxies": [{"class": "CN_DIRECT", "proxy_id": 4, "expected_exit_ipv4": "8.8.8.8"}]}}
        with mock.patch.object(companyctl, "load_config", return_value=cfg), mock.patch.object(companyctl, "psql", return_value="13001"), mock.patch.object(companyctl.os, "execv") as execute, mock.patch("sys.stdout", new_callable=io.StringIO):
            companyctl.verify()
            self.assertNotIn("--sha256", execute.call_args.args[1])
            companyctl.verify("A" * 64)
            self.assertEqual(execute.call_args.args[1][-2:], ["--sha256", "a" * 64])
            with self.assertRaises(companyctl.CompanyCtlError):
                companyctl.verify("not-a-release-hash")

    def test_fresh_http_failure_does_not_roll_back_valid_database(self):
        source = (ROOT / "deploy/company-install-fresh.sh").read_text()
        self.assertIn('--env "$env_file" --defer-http', source)
        self.assertLess(source.index("fresh_complete=1"), source.index("if ! /usr/local/sbin/companyctl web http"))
        self.assertIn("COMPANY_APPLICATION_READY_HTTP_FAILED=1", source)
        self.assertIn("COMPANY_APPLICATION_READY_HTTP_FAILED=1", (ROOT / "deploy/company-activate-egress.sh").read_text())

    @staticmethod
    def fake_web_command(*args, check=True):
        stdout = ""
        if args[:2] == ("ip", "-j"):
            stdout = json.dumps([{"addr_info": [{"local": "192.168.1.175"}]}])
        elif args[:2] == ("systemctl", "is-enabled"):
            stdout = "disabled\n"
        elif args == ("nginx", "-T"):
            stdout = "# configuration file /etc/nginx/nginx.conf:\nevents{}\nhttp{}\n"
        return subprocess.CompletedProcess(args, 0, stdout, "")

    @unittest.skipIf(os.name == "nt", "filesystem transaction requires Unix symlinks")
    def test_lan_http_apply_and_repeat_are_scoped(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            nginx = root / "nginx"
            (nginx / "sites-available").mkdir(parents=True)
            (nginx / "sites-enabled").mkdir()
            (nginx / "sites-available/default").write_text("default")
            (nginx / "sites-enabled/default").symlink_to(nginx / "sites-available/default")
            with mock.patch.object(companyctl, "web_command", side_effect=self.fake_web_command) as commands, mock.patch("sys.stdout", new_callable=io.StringIO):
                for _ in range(2):
                    companyctl.apply_lan_http("192.168.1.175", "corp.example", ["192.168.1.0/24"], disable_default=True, nginx_dir=nginx, backup_root=root / "backups")
                self.assertFalse((nginx / "sites-enabled/default").is_symlink())
                self.assertTrue((nginx / "sites-enabled/sub2api-company").is_symlink())
                self.assertIn(companyctl.HTTP_SITE_MARKER, (nginx / "sites-available/sub2api-company").read_text())
                self.assertTrue(all("sub2api.service" not in call.args for call in commands.call_args_list))

    @unittest.skipIf(os.name == "nt", "filesystem transaction requires Unix symlinks")
    def test_lan_http_failure_restores_manual_site_and_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            nginx = root / "nginx"
            (nginx / "sites-available").mkdir(parents=True)
            (nginx / "sites-enabled").mkdir()
            site = nginx / "sites-available/sub2api-company"
            site.write_text("previous HTTPS config")
            site.chmod(0o600)
            link = nginx / "sites-enabled/sub2api-company"
            link.symlink_to(site)
            def fail_probe(*args, check=True):
                if args[0] == "curl" and args[-1] == "http://corp.example/health":
                    raise subprocess.CalledProcessError(22, args)
                return self.fake_web_command(*args, check=check)
            with mock.patch.object(companyctl, "web_command", side_effect=fail_probe) as commands:
                with self.assertRaises(subprocess.CalledProcessError):
                    companyctl.apply_lan_http("192.168.1.175", "corp.example", ["192.168.1.0/24"], replace_existing=True, nginx_dir=nginx, backup_root=root / "backups")
                self.assertEqual(site.read_text(), "previous HTTPS config")
                self.assertEqual(site.stat().st_mode & 0o777, 0o600)
                self.assertEqual(link.resolve(), site.resolve())
                self.assertIn(mock.call("systemctl", "restart", "nginx.service"), commands.call_args_list)

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
