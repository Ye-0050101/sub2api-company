#!/usr/bin/env python3
"""Static guard for Company Egress V1 account-sensitive production paths."""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

PROTECTED_FILES = (
    "backend/internal/service/managed_proxy.go",
    "backend/internal/service/company_ws_dialer.go",
    "backend/internal/service/openai_ws_client.go",
    "backend/internal/service/oauth_service.go",
    "backend/internal/service/openai_oauth_service.go",
    "backend/internal/service/grok_oauth_service.go",
    "backend/internal/service/gemini_oauth_service.go",
    "backend/internal/service/gemini_token_provider.go",
    "backend/internal/service/claude_token_provider.go",
    "backend/internal/service/antigravity_oauth_service.go",
    "backend/internal/service/account_usage_service.go",
    "backend/internal/service/openai_quota_service.go",
    "backend/internal/service/account_test_service.go",
    "backend/internal/service/openai_codex_account_identity.go",
    "backend/internal/service/openai_codex_pat_service.go",
    "backend/internal/service/openai_codex_models_service.go",
    "backend/internal/service/openai_plugin_transport.go",
    "backend/internal/service/gateway_websearch_emulation.go",
    "backend/internal/repository/company_http_upstream.go",
    "backend/internal/repository/company_managed_proxy_health.go",
    "backend/internal/repository/claude_usage_service.go",
    "backend/internal/repository/grok_oauth_client.go",
    "backend/internal/repository/company_oauth_client.go",
)

SERVER_OPERATION_SCRIPTS = (
    "deploy/company-bootstrap-cn.sh",
    "deploy/company-activate-egress.sh",
    "deploy/company-deploy-egress.sh",
    "deploy/company-verify-egress.sh",
    "deploy/company-install-fresh.sh",
    "deploy/company-postgresql16.sh",
    "deploy/company-route-apply.sh",
    "deploy/company-route.py",
)

RULES = {
    "http-default-client": re.compile(r"\bhttp\.DefaultClient\b"),
    "raw-proxy-url-parser": re.compile(
        r"\burl\.Parse\(\s*(?:raw)?[Pp]roxy(?:URL|Url)?\s*\)"
    ),
    "default-dns-resolver": re.compile(r"\bnet\.DefaultResolver\b"),
    "direct-dns-lookup": re.compile(r"\b(?:LookupIP|LookupHost|LookupIPAddr)\s*\("),
    "direct-net-dialer": re.compile(r"\bnet\.Dialer\s*\{"),
    "empty-proxy-client": re.compile(r"\bProxyURL\s*:\s*\"\""),
}

# An exception must name the exact file, rule, and stripped source line.
# Keep this empty unless a reviewed source audit documents why the line cannot
# carry managed account traffic.
AUDIT_ALLOWLIST: dict[tuple[str, str, str], str] = {
    (
        "backend/internal/repository/grok_oauth_client.go",
        "http-default-client",
        "resp, err := http.DefaultClient.Do(req)",
    ): (
        "YesCaptcha create/poll is reachable only from Grok password auth; "
        "Company Egress startup rejects password_auth_enabled and the service "
        "checks the disabled flag before invoking this client."
    ),
}

REQUIRED_SOURCE = {
    ".github/workflows/backend-ci.yml": (
        "-X main.Version=company-${GITHUB_SHA}",
        "-X main.BuildType=company",
    ),
    "deploy/company-bootstrap-cn.sh": (
        "--confirm-first-install",
        "bundle SHA256 mismatch",
        "binary SHA256 mismatch",
        "for companion in company-activate-egress.sh company-postgresql16.sh company-route.py company-route-apply.sh; do",
        "/usr/local/sbin/company-activate-egress",
        "/usr/local/sbin/company-route-add",
    ),
    "deploy/company-activate-egress.sh": (
        "COMPANY_CN_DNS_IPV4_1",
        "sub2api_egress_guard",
        "COMPANY_EGRESS_ACTIVATED=1",
        "migration_us=0",
    ),
    "deploy/company-install-fresh.sh": (
        "--confirm-fresh-install",
        "--company-bootstrap-fresh",
        "COMPANY_FRESH_INSTALL_READY=1",
        "Fresh installation failed; removing only resources created by this run",
        "company-route-add",
        "company-postgresql16.sh",
        "Ubuntu 22.04 required",
    ),
    "deploy/company-postgresql16.sh": (
        "https://www.postgresql.org/media/keys/ACCC4CF8.asc",
        "https://apt.postgresql.org/pub/repos/apt",
        "Suites: jammy-pgdg",
        "Signed-By: /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc",
        "postgresql-16 postgresql-client-16 postgresql-contrib-16",
        "version_num >= 160000 && version_num < 170000",
    ),
    "deploy/company-route.py": (
        'ALLOWED_COUNTRIES = {"US", "SG", "JP", "KR", "HK", "TW"}',
        '"default": "block"',
        "disaster_exit_ipv4",
        "server_ports/port hopping is prohibited",
        "must not enable insecure TLS",
    ),
    "deploy/company-route-apply.sh": (
        "route core policy is immutable",
        "sub2api_route_control_guard",
        "allow_direct_on_error",
        "Route activation failed; restoring the previous application state",
        'die() { echo "REFUSING: $*" >&2; return 1; }',
    ),
    "deploy/company-verify-egress.sh": (
        "/etc/sub2api-egress/routes/*/metadata.json",
        "expected_disaster",
        "sub2api-route-$route_key-failover.timer",
        "probe_managed_route",
        "PostgreSQL 16 server_version_num",
    ),
    "deploy/company-deploy-egress.sh": (
        "--ops-dir",
        "operations manifest SHA256 mismatch",
        "required_ops=(company-deploy-egress company-verify-egress company-route company-route-add)",
        "restoring previous binary and operations tools",
    ),
    "tools/company-update.ps1": (
        "Company operations SHA256SUMS is missing.",
        "ops_sha256      = $opsManifestSha",
        "Operations file hash mismatch",
    ),
    "backend/cmd/server/main.go": (
        '"company-bootstrap-fresh"',
        'strings.TrimSpace(BuildType), "company"',
        "Company fresh bootstrap completed",
    ),
    "deploy/company-export-migration.sh": (
        "--stop-application",
        "SOURCE_APPLICATION_STOPPED=1",
    ),
    "backend/cmd/server/wire_gen.go": (
        "repository.NewCompanyHTTPUpstream(",
        "repository.NewCompanyManagedProxyHealth(",
        "repository.NewCompanyProxyRepository(",
        "service.ProvideCompanyOAuthService(",
        "service.ProvideCompanyOpenAIOAuthService(",
        "service.ProvideCompanyGrokOAuthService(",
        "service.ProvideCompanyAntigravityOAuthService(",
        "service.ProvideCompanyGeminiOAuthService(",
        "service.ProvideCompanyOpenAIQuotaService(",
        "service.ProvideCompanyAccountUsageService(",
        "repository.ProvideCompanyGrokOAuthClient(",
        "repository.CreateCompanyPrivacyReqClient",
    ),
    "backend/internal/repository/company_managed_proxy_health.go": (
        'companyProbeAInternationalURL = "https://api.ipify.org?format=json"',
        'companyProbeACNURL            = "https://api-ipv4.ip.sb/ip"',
        'companyProbeBURL              = "https://cloudflare.com/cdn-cgi/trace"',
        "case service.ManagedProxyClassCNDirect:",
        "companyProbeAPlainIPv4",
        "ManagedProxyHealthReadyPrimary",
        "ManagedProxyHealthReadyDisaster",
        "ManagedProxyHealthUnhealthy",
        "case policy.DisasterExitIPv4:",
    ),
    "backend/internal/config/company_egress.go": (
        "DisasterExitIPv4",
        'mapstructure:"disaster_exit_ipv4"',
    ),
    "backend/internal/service/openai_ws_client.go": (
        "proxyurl.Parse(proxy)",
        "proxyutil.ConfigureTransportProxy(transport, parsedProxyURL)",
    ),
    "backend/internal/repository/grok_oauth_client.go": (
        "proxyurl.Parse(proxyURL)",
        "proxyutil.ConfigureTransportProxy(transport, parsed)",
    ),
    "backend/internal/service/managed_proxy.go": (
        "OpenAI PAT and Agent Identity are outside Company Egress V1",
        'case "US", "SG", "JP", "KR", "HK", "TW":',
        "disaster_exit_ipv4 must differ from expected_exit_ipv4",
        "policy.DisasterExitIPv4",
    ),
    "backend/internal/service/managed_proxy_test.go": (
        "TestNewManagedProxyPoliciesInternationalCountries",
        '[]string{"JP", "KR", "HK", "TW"}',
        'CountryCode = "DE"',
    ),
    "backend/internal/service/update_service.go": (
        'buildTypeCompany = "company"',
        "ErrCompanyManagedUpdate",
        "if s.companyManaged()",
        "Company managed build: use company-update and company-deploy-egress",
    ),
    "backend/internal/service/update_service_test.go": (
        "TestUpdateServiceCompanyBuildNeverUsesOfficialReleaseOrMutatesBinary",
        "require.Zero(t, github.latestCalls)",
        "require.Zero(t, github.downloadCalls)",
    ),
    "frontend/src/components/common/VersionBadge.vue": (
        'v-if="isCompanyBuild"',
        "version.companyManagedHint",
        "if (isCompanyBuild.value || updating.value) return",
    ),
    "backend/internal/service/openai_codex_account_identity.go": (
        "resolveConfiguredManagedAccount(",
    ),
    "backend/internal/service/account_test_service.go": (
        "s.managedProxyResolver.ResolveForAccount(",
        "resolveCompanyWebSocketProxy(",
    ),
    "backend/internal/service/account_usage_service.go": (
        "s.managedProxyResolver.ResolveForAccount(",
        "s.httpUpstream.Do(",
    ),
    "backend/internal/service/openai_quota_service.go": (
        "resolveConfiguredManagedAccount(",
    ),
    "backend/internal/service/upstream_models.go": (
        "s.managedProxyResolver.ResolveForAccount(",
    ),
    "backend/internal/service/openai_codex_pat_service.go": (
        "OpenAI Codex PAT",
        "ErrManagedEgressUnsupported",
    ),
    "backend/internal/service/openai_codex_models_service.go": (
        "ValidateManagedDestination(",
        "request.useAPIKeyUpstream || request.managedEgress",
    ),
    "backend/internal/service/openai_plugin_transport.go": (
        "!managedEgress",
    ),
    "backend/internal/service/gateway_websearch_emulation.go": (
        "len(s.cfg.CompanyEgress.ManagedProxies) > 0",
    ),
}

FORBIDDEN_WIRING = (
    "repository.NewHTTPUpstream(configConfig)",
    "repository.NewProxyRepository(client, db)",
    "repository.NewGrokOAuthClient()",
    "service.NewAntigravityOAuthService(proxyRepository)",
    "return repository.CreatePrivacyReqClient",
)


def main() -> int:
    failures: list[str] = []

    for relative_path in SERVER_OPERATION_SCRIPTS:
        text = (ROOT / relative_path).read_text(encoding="utf-8")
        if (
            "https://github.com" in text
            or "https://raw.githubusercontent.com" in text
            or "https://api.github.com" in text
            or "git clone" in text
        ):
            failures.append(f"{relative_path}: server operation script must not access GitHub")

    for relative_path in (
        "deploy/company-install-fresh.sh",
        "deploy/company-bootstrap-cn.sh",
    ):
        source = (ROOT / relative_path).read_text(encoding="utf-8")
        for line_number, line in enumerate(source.splitlines(), start=1):
            if "apt-get install" not in line:
                continue
            if re.search(r"(?:^|\s)postgresql(?:-contrib)?(?:\s|\\|$)", line):
                failures.append(
                    f"{relative_path}:{line_number}: generic PostgreSQL meta-package is forbidden"
                )
    for relative in PROTECTED_FILES:
        path = ROOT / relative
        if not path.is_file():
            failures.append(f"missing protected file: {relative}")
            continue
        for line_number, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), start=1
        ):
            stripped = line.strip()
            for rule_name, pattern in RULES.items():
                if not pattern.search(line):
                    continue
                key = (relative, rule_name, stripped)
                if key in AUDIT_ALLOWLIST:
                    continue
                failures.append(
                    f"{relative}:{line_number}: {rule_name}: {stripped}"
                )

    for relative, required_items in REQUIRED_SOURCE.items():
        path = ROOT / relative
        if not path.is_file():
            failures.append(f"missing required file: {relative}")
            continue
        source = path.read_text(encoding="utf-8")
        for required in required_items:
            if required not in source:
                failures.append(f"{relative}: missing required guard: {required}")

    wire_path = ROOT / "backend/cmd/server/wire_gen.go"
    if wire_path.is_file():
        wire_source = wire_path.read_text(encoding="utf-8")
        for forbidden in FORBIDDEN_WIRING:
            if forbidden in wire_source:
                failures.append(
                    f"backend/cmd/server/wire_gen.go: forbidden production wiring: {forbidden}"
                )

    managed_source = (ROOT / "backend/internal/service/managed_proxy.go").read_text(
        encoding="utf-8"
    )
    if "daily-cloudcode-pa.googleapis.com" in managed_source:
        failures.append(
            "managed_proxy.go: Antigravity-only daily endpoint is forbidden"
        )

    if failures:
        print("Company Egress static guard FAILED:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print("Company Egress static guard passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
