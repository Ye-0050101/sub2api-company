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
        'companyProbeAURL      = "https://api.ipify.org?format=json"',
        'companyProbeBURL      = "https://cloudflare.com/cdn-cgi/trace"',
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
        "disaster_exit_ipv4 must differ from expected_exit_ipv4",
        "policy.DisasterExitIPv4",
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
