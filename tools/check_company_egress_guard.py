#!/usr/bin/env python3
"""Static guard for Company Egress V1 account-sensitive production paths."""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# Scan the complete production Go tree rather than a hand-picked list of files.
# Generated ORM/protobuf sources and test-only packages are excluded explicitly;
# wire_gen.go remains in scope because it is the production dependency graph.
PRODUCTION_GO_ROOT = ROOT / "backend"
PRODUCTION_GO_EXCLUDED_DIRS = (
    ROOT / "backend/ent",
    ROOT / "backend/internal/integration",
    ROOT / "backend/internal/testutil",
)
PRODUCTION_GO_EXCLUDED_SUFFIXES = ("_test.go", ".pb.go")

GO_NETWORK_PACKAGES = {
    "net/http": "http",
    "net": "net",
    "crypto/tls": "tls",
    "net/url": "url",
}
GO_IMPORT_SPEC = re.compile(
    r'^\s*(?:import\s+)?(?:(?P<alias>[A-Za-z_][A-Za-z0-9_]*)\s+)?'
    r'"(?P<path>net/http|net|crypto/tls|net/url)"',
    re.MULTILINE,
)

SERVER_OPERATION_SCRIPTS = (
    "deploy/company-bootstrap-cn.sh",
    "deploy/company-activate-egress.sh",
    "deploy/company-deploy-egress.sh",
    "deploy/company-verify-egress.sh",
    "deploy/company-install-fresh.sh",
    "deploy/companyctl.py",
    "deploy/company-route-apply.sh",
    "deploy/company-route.py",
)

RULES = {
    "http-default-client": re.compile(r"\bhttp\.DefaultClient\b"),
    "http-default-convenience": re.compile(
        r"\bhttp\.(?:Get|Post|PostForm|Head)\s*\("
    ),
    # Require a composite literal. The negative look-behind prevents function
    # signatures such as `func f() *http.Client {` from being counted.
    "bare-http-client": re.compile(
        r"(?:&\s*|(?<![A-Za-z0-9_*]))http\.Client\s*\{"
    ),
    "raw-proxy-url-parser": re.compile(
        r"\burl\.Parse\(\s*(?:strings\.TrimSpace\(\s*)?"
        r"(?:raw)?[Pp]roxy(?:URL|Url)?\s*\)?\s*\)"
    ),
    "default-dns-resolver": re.compile(r"\bnet\.DefaultResolver\b"),
    "custom-dns-resolver": re.compile(
        r"(?:&\s*|(?<![A-Za-z0-9_*]))net\.Resolver\s*\{"
    ),
    "direct-dns-lookup": re.compile(
        r"\b(?:net\.)?Lookup(?:IP|IPAddr|NetIP|Host|Addr|CNAME|MX|NS|Port|SRV|TXT)\s*\("
    ),
    "direct-net-dialer": re.compile(
        r"(?:&\s*|(?<![A-Za-z0-9_*]))net\.Dialer\s*\{"
    ),
    "direct-net-dial": re.compile(
        r"\bnet\.(?:Dial|DialTimeout|DialTCP|DialUDP)\s*\("
    ),
    "direct-tls-dial": re.compile(r"\btls\.Dial(?:WithDialer)?\s*\("),
    "direct-tls-dialer": re.compile(
        r"(?:&\s*|(?<![A-Za-z0-9_*]))tls\.Dialer\s*\{"
    ),
    "empty-proxy-client": re.compile(r"\bProxyURL\s*:\s*\"\""),
}

@dataclass(frozen=True)
class AuditAllowance:
    """Reviewed occurrence count and reason for one file/rule pair."""

    expected_occurrences: int
    reason: str


# This is an exact audited baseline, not a wildcard suppression list. A new
# matching file, a new rule occurrence, or any audited occurrence-count change
# requires an explicit review and baseline update.
AUDIT_ALLOWLIST: dict[tuple[str, str], AuditAllowance] = {
    ("backend/internal/handler/auth_dingtalk_oauth.go", "bare-http-client"): AuditAllowance(
        1, "DingTalk user-login OAuth client; it cannot carry an AI account request."
    ),
    ("backend/internal/handler/auth_wechat_oauth.go", "bare-http-client"): AuditAllowance(
        2, "WeChat user-login OAuth clients; they cannot carry managed AI account traffic."
    ),
    ("backend/internal/payment/provider/airwallex.go", "bare-http-client"): AuditAllowance(
        2, "Payment-provider control plane, separate from account inference and account credentials."
    ),
    ("backend/internal/payment/provider/easypay.go", "bare-http-client"): AuditAllowance(
        2, "Payment-provider control plane, separate from account inference and account credentials."
    ),
    ("backend/internal/pkg/antigravity/client.go", "bare-http-client"): AuditAllowance(
        1, "Antigravity managed accounts are rejected by Company V1; non-empty proxies use proxyurl.Parse."
    ),
    ("backend/internal/pkg/antigravity/client.go", "direct-net-dialer"): AuditAllowance(
        1, "Transport dial timeout inside the Antigravity client; Company V1 rejects that platform."
    ),
    ("backend/internal/pkg/httpclient/pool.go", "bare-http-client"): AuditAllowance(
        1, "Reviewed shared client factory; managed callers must supply a resolved ProxyURL."
    ),
    ("backend/internal/pkg/httpclient/pool.go", "direct-net-dialer"): AuditAllowance(
        1, "Reviewed shared transport timeout; proxyurl.Parse and proxyutil replace routing when configured."
    ),
    ("backend/internal/pkg/proxyutil/dialer.go", "direct-net-dialer"): AuditAllowance(
        1, "Forward dialer connects only to the explicitly parsed SOCKS endpoint."
    ),
    ("backend/internal/pkg/servertiming/http.go", "http-default-client"): AuditAllowance(
        1, "Instrumentation wrapper preserves a caller-selected client; it does not select account routing."
    ),
    ("backend/internal/pkg/servertiming/http.go", "bare-http-client"): AuditAllowance(
        1, "Instrumentation-only nil fallback; managed paths provide their route-aware client."
    ),
    ("backend/internal/pkg/tlsfingerprint/dialer.go", "direct-net-dialer"): AuditAllowance(
        2, "TLS-profile transport primitive; managed HTTPUpstream supplies the approved proxy/base dialer."
    ),
    ("backend/internal/pkg/websearch/brave.go", "http-default-client"): AuditAllowance(
        1, "Provider-library nil fallback; Manager injects a client and Company disables emulation when enforced."
    ),
    ("backend/internal/pkg/websearch/tavily.go", "http-default-client"): AuditAllowance(
        1, "Provider-library nil fallback; Manager injects a client and Company disables emulation when enforced."
    ),
    ("backend/internal/pkg/websearch/manager.go", "bare-http-client"): AuditAllowance(
        1, "Legacy web-search factory; Company disables the entire emulation path when managed egress is active."
    ),
    ("backend/internal/pkg/websearch/manager.go", "direct-net-dialer"): AuditAllowance(
        1, "Legacy web-search transport; managed Company production cannot enter this path."
    ),
    ("backend/internal/pkg/websearch/manager.go", "raw-proxy-url-parser"): AuditAllowance(
        1, "Known legacy parser bypass, frozen at one occurrence; Company blocks managed web-search before it."
    ),
    ("backend/internal/pkg/xai/sso_device.go", "bare-http-client"): AuditAllowance(
        1, "Library fallback is not used by production Grok OAuth, which injects the Company OAuth client."
    ),
    ("backend/internal/repository/company_managed_proxy_health.go", "bare-http-client"): AuditAllowance(
        1, "Company RouteHealth probe client with compile-time HTTPS endpoints and route proxy transport."
    ),
    ("backend/internal/repository/github_release_service.go", "bare-http-client"): AuditAllowance(
        2, "Official release/update control plane; Company builds reject online update before network access."
    ),
    ("backend/internal/repository/grok_oauth_client.go", "http-default-client"): AuditAllowance(
        2, "YesCaptcha create/poll belongs to Grok password auth, rejected at Company startup."
    ),
    ("backend/internal/repository/grok_oauth_client.go", "bare-http-client"): AuditAllowance(
        1, "Grok OAuth client configures its transport through proxyurl.Parse and proxyutil."
    ),
    ("backend/internal/repository/http_upstream.go", "bare-http-client"): AuditAllowance(
        2, "Approved HTTPUpstream client construction after Company resolver and proxy normalization."
    ),
    ("backend/internal/repository/http_upstream.go", "direct-net-dialer"): AuditAllowance(
        1, "Approved HTTPUpstream transport timeout; managed requests already carry an immutable decision."
    ),
    ("backend/internal/repository/pricing_service.go", "bare-http-client"): AuditAllowance(
        1, "Non-account model-pricing metadata updater; Company startup forbids direct proxy fallback."
    ),
    ("backend/internal/repository/turnstile_service.go", "bare-http-client"): AuditAllowance(
        1, "User-facing Turnstile verification, not an AI account-sensitive outbound path."
    ),
    ("backend/internal/securityaudit/prompt_outbound_security.go", "bare-http-client"): AuditAllowance(
        1, "Dedicated administrator security-audit client with endpoint validation and bounded transport."
    ),
    ("backend/internal/securityaudit/prompt_outbound_security.go", "direct-net-dialer"): AuditAllowance(
        1, "Dedicated administrator security-audit dialer, outside managed account execution."
    ),
    ("backend/internal/service/batch_image_provider_gemini.go", "http-default-client"): AuditAllowance(
        1, "Gemini Batch is rejected by Company startup; this fallback cannot serve managed production."
    ),
    ("backend/internal/service/channel_monitor_checker.go", "bare-http-client"): AuditAllowance(
        1, "Administrative endpoint monitor using its SSRF-safe dial path, not account inference."
    ),
    ("backend/internal/service/channel_monitor_ssrf.go", "direct-net-dialer"): AuditAllowance(
        1, "Administrative monitor dialer validates resolved destination IPs against SSRF policy."
    ),
    ("backend/internal/service/channel_monitor_ssrf.go", "default-dns-resolver"): AuditAllowance(
        2, "Administrative monitor DNS is explicitly revalidated before socket connection."
    ),
    ("backend/internal/service/channel_monitor_ssrf.go", "direct-dns-lookup"): AuditAllowance(
        2, "Administrative monitor performs DNS rebinding/SSRF validation, outside managed accounts."
    ),
    ("backend/internal/service/content_moderation.go", "http-default-client"): AuditAllowance(
        1, "Optional site moderation service; configured ProxyID is separately fail-fast and not an AI account."
    ),
    ("backend/internal/service/email_service.go", "direct-net-dialer"): AuditAllowance(
        1, "SMTP delivery control plane, separate from all AI account credentials and routing."
    ),
    ("backend/internal/service/email_service.go", "direct-tls-dial"): AuditAllowance(
        1, "SMTP implicit-TLS connection, separate from managed AI account traffic."
    ),
    ("backend/internal/service/image_storage.go", "bare-http-client"): AuditAllowance(
        1, "Post-response image storage fetcher; it never selects or authenticates an AI account."
    ),
    ("backend/internal/service/openai_ws_client.go", "bare-http-client"): AuditAllowance(
        1, "Approved OpenAI WebSocket client after proxyurl.Parse and ConfigureTransportProxy."
    ),
    ("backend/internal/service/vertex_service_account.go", "bare-http-client"): AuditAllowance(
        2, "Vertex service-account and Batch/GCS are unsupported for Company V1 managed traffic."
    ),
    ("backend/internal/util/urlvalidator/validator.go", "default-dns-resolver"): AuditAllowance(
        1, "URL validation resolves destinations to enforce its SSRF policy; it does not issue account requests."
    ),
    ("backend/internal/util/urlvalidator/validator.go", "direct-dns-lookup"): AuditAllowance(
        1, "URL validation DNS lookup is used only for SSRF classification."
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
        "for companion in company-activate-egress.sh companyctl.py company-route.py company-route-apply.sh; do",
        "/usr/local/sbin/company-activate-egress",
        "/usr/local/sbin/companyctl",
        "/usr/local/sbin/company-route-add",
    ),
    "deploy/company-activate-egress.sh": (
        "COMPANY_CN_DNS_IPV4_1",
        "sub2api_egress_guard",
        "COMPANY_EGRESS_ACTIVATED=1",
        "migration_us=0",
        "--reconcile-config-only",
        "COMPANY_WEB_MODE",
        "COMPANY_HTTP_ACKNOWLEDGE_PLAINTEXT",
        "https://api.ipify.org?format=json",
        "https://cloudflare.com/cdn-cgi/trace",
    ),
    "deploy/company-install-fresh.sh": (
        "--confirm-fresh-install",
        "--company-bootstrap-fresh",
        "COMPANY_FRESH_INSTALL_READY=1",
        "Fresh installation failed; removing only resources created by this run",
        "company-route-add",
        "companyctl.py",
        '"insecure_skip_verify": False',
        "https://api.ipify.org?format=json",
        "https://cloudflare.com/cdn-cgi/trace",
    ),
    "deploy/config.example.yaml": (
        "https://api.ipify.org?format=json",
        "https://cloudflare.com/cdn-cgi/trace",
        "insecure_skip_verify: false",
    ),
    "deploy/company-route.py": (
        'ALLOWED_COUNTRIES = {"US", "SG", "JP", "KR", "HK", "TW"}',
        '"default": "block"',
        "disaster_exit_ipv4",
        "server_ports must contain 1 to 3 exact ports",
        "must not enable insecure TLS",
    ),
    "deploy/companyctl.py": (
        'COUNTRIES = ("US", "SG", "JP", "KR", "HK", "TW")',
        "certificate_public_key_sha256",
        "HY2 requires 1 to 3 unique exact ports",
        "getpass.getpass",
        "route activation failed and was rolled back",
        "account audit failed",
        "def render_lan_http(",
        "def status()",
        "--acknowledge-plaintext",
        "HTTP listener must be a literal RFC1918 IPv4",
        "binary integrity is not being certified",
    ),
    "deploy/company-route-apply.sh": (
        "route core policy is immutable",
        "sub2api_route_control_guard",
        "allow_direct_on_error",
        "Route activation failed; restoring the previous application state",
        'readlink -f "$route_tool"',
        'die() { echo "REFUSING: $*" >&2; return 1; }',
    ),
    "deploy/company-verify-egress.sh": (
        "/etc/sub2api-egress/routes/*/metadata.json",
        "expected_disaster",
        "sub2api-route-$route_key-failover.timer",
        "probe_managed_route",
        "exact HTTPS proxy probe policy",
    ),
    "deploy/company-deploy-egress.sh": (
        "--ops-dir",
        "operations manifest SHA256 mismatch",
        "required_ops=(company-deploy-egress company-verify-egress company-route company-route-add companyctl)",
        "restoring previous binary, config, and operations tools",
        "pg_restore --list",
        "DATABASE_BACKUP_SHA256=",
        "new_binary_may_have_migrated=1",
        "Sub2API remains stopped",
    ),
    "tools/company-update.ps1": (
        "Company operations SHA256SUMS is missing.",
        "ops_sha256      = $opsManifestSha",
        "Operations file hash mismatch",
        "company/egress-v1-ubuntu22.04",
        "'push', '--atomic', 'origin'",
        "refs/heads/main",
        "merge-base --is-ancestor",
        "ubuntu22_binary_sha256",
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
    "backend/internal/repository/proxy_probe_service.go": (
        "http.ErrUseLastResponse",
        "Probe targets are an audited exact list",
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
        "buildType.value === 'company' || isCompanyVersion(currentVersion.value)",
    ),
    "frontend/src/utils/companyBuild.ts": (
        "../../../COMPANY_VERSION?raw",
        "../../../backend/cmd/server/VERSION?raw",
        "/^company-[0-9a-f]{40}$/",
        "Company v${companyReleaseVersion}",
    ),
    "frontend/src/views/HomeView.vue": (
        'v-else-if="compactHomeEnabled"',
        'v-else-if="isCompanyVersion(siteVersion)"',
    ),
    "frontend/src/components/home/CompanyHome.vue": (
        "prefers-reduced-motion: reduce",
        "CompanyVersionBadge",
        "props.isAuthenticated ? props.dashboardPath : '/login'",
    ),
    "Dockerfile": (
        "COPY COMPANY_VERSION /app/COMPANY_VERSION",
        "COPY backend/cmd/server/VERSION /app/backend/cmd/server/VERSION",
    ),
    "deploy/Dockerfile": (
        "COPY COMPANY_VERSION /app/COMPANY_VERSION",
        "COPY backend/cmd/server/VERSION /app/backend/cmd/server/VERSION",
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


def production_go_files() -> tuple[Path, ...]:
    """Return every non-generated, non-test Go source used by the backend."""

    files: list[Path] = []
    for path in PRODUCTION_GO_ROOT.rglob("*.go"):
        if path.name.endswith(PRODUCTION_GO_EXCLUDED_SUFFIXES):
            continue
        if any(path.is_relative_to(directory) for directory in PRODUCTION_GO_EXCLUDED_DIRS):
            continue
        files.append(path)
    return tuple(sorted(files))


def normalize_go_network_package_aliases(source: str) -> str:
    """Normalize audited stdlib import aliases before regex rule matching."""

    normalized = source
    for match in GO_IMPORT_SPEC.finditer(source):
        import_path = match.group("path")
        canonical = GO_NETWORK_PACKAGES[import_path]
        alias = match.group("alias") or canonical
        if alias in {"_", canonical}:
            continue
        normalized = re.sub(rf"\b{re.escape(alias)}\.", f"{canonical}.", normalized)
    return normalized


def audit_production_network_primitives(failures: list[str]) -> None:
    """Freeze every direct-capable network primitive in production Go source."""

    files = production_go_files()
    if not files:
        failures.append("production Go scan found no files")
        return

    scanned_relatives = {path.relative_to(ROOT).as_posix() for path in files}
    findings: dict[tuple[str, str], list[tuple[int, str]]] = {}

    for path in files:
        relative = path.relative_to(ROOT).as_posix()
        original_source = path.read_text(encoding="utf-8")
        source = normalize_go_network_package_aliases(original_source)
        lines = original_source.splitlines()
        for rule_name, pattern in RULES.items():
            for match in pattern.finditer(source):
                line_number = source.count("\n", 0, match.start()) + 1
                line = lines[line_number - 1].strip() if lines else ""
                findings.setdefault((relative, rule_name), []).append(
                    (line_number, line)
                )

    for key, occurrences in sorted(findings.items()):
        relative, rule_name = key
        allowance = AUDIT_ALLOWLIST.get(key)
        if allowance is None:
            for line_number, line in occurrences:
                failures.append(f"{relative}:{line_number}: {rule_name}: {line}")
            continue
        if len(occurrences) != allowance.expected_occurrences:
            locations = ", ".join(str(line_number) for line_number, _ in occurrences)
            failures.append(
                f"{relative}: {rule_name}: audited occurrence count changed "
                f"(expected {allowance.expected_occurrences}, found {len(occurrences)} "
                f"at lines {locations or 'none'}); review: {allowance.reason}"
            )

    for (relative, rule_name), allowance in sorted(AUDIT_ALLOWLIST.items()):
        if rule_name not in RULES:
            failures.append(f"audit allowlist has unknown rule: {relative}: {rule_name}")
            continue
        if relative not in scanned_relatives:
            failures.append(f"audit allowlist file is not production-scanned: {relative}")
            continue
        actual = len(findings.get((relative, rule_name), ()))
        if actual == 0 and allowance.expected_occurrences != 0:
            failures.append(
                f"{relative}: {rule_name}: audited occurrences disappeared "
                f"(expected {allowance.expected_occurrences}); remove or re-audit allowance"
            )


def main() -> int:
    failures: list[str] = []

    company_version_path = ROOT / "COMPANY_VERSION"
    if not company_version_path.is_file() or not re.fullmatch(
        r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)",
        company_version_path.read_text(encoding="utf-8").strip(),
    ):
        failures.append("COMPANY_VERSION must contain one major.minor.patch release version")

    alias_fixture = 'import stdhttp "net/http"\nvar c = &stdhttp.Client{}\n'
    normalized_fixture = normalize_go_network_package_aliases(alias_fixture)
    if len(RULES["bare-http-client"].findall(normalized_fixture)) != 1:
        failures.append("Go network import-alias normalization self-test failed")

    for relative_path in SERVER_OPERATION_SCRIPTS:
        text = (ROOT / relative_path).read_text(encoding="utf-8")
        if (
            "https://github.com" in text
            or "https://raw.githubusercontent.com" in text
            or "https://api.github.com" in text
            or "git clone" in text
        ):
            failures.append(f"{relative_path}: server operation script must not access GitHub")
    audit_production_network_primitives(failures)

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
