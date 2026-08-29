# Sub2API Company Egress V1 — Development Spec

## 0. Project

Repository:

Ye-0050101/sub2api-company

Upstream:

Wei-Shaw/sub2api

Production base commit:

e8cb019fabf8b55199436229044cbf9aa7a82564

Current development branch:

company/egress-v1

The company repository must remain easy to sync with upstream.

Primary rule:

- Prefer ADDING new files.
- Minimize modifications to upstream files.
- Do not rewrite provider-specific gateway logic.
- Do not mass-edit every ProxyID / Proxy call site.
- Keep upstream Git history.
- Keep upstream as remote `upstream`.
- Never update production directly from upstream install scripts.

---

# 1. Business Goal

Sub2API will manage approximately 15+ AI accounts.

Supported categories:

## International AI

Must use controlled international proxy route:

- Claude / Anthropic
- OpenAI / GPT
- Grok / xAI
- Gemini where applicable

Example:

Claude-US-01 → US-A
Claude-US-02 → US-A
GPT-US-01    → US-A
Grok-US-01   → US-A
Claude-SG-01 → SG-A

## Chinese AI

May use China/server direct egress:

- DeepSeek
- Kimi
- Zhipu

BUT:

Sub2API process itself must still NOT receive unrestricted direct Internet access.

Instead:

DeepSeek
  ↓
CN-DIRECT EgressRoute
  ↓
local SOCKS endpoint
  ↓
sing-box-cn
  ↓
direct
  ↓
DeepSeek API

Therefore "CN direct" means the final public source IP is the main server IP, not that Sub2API itself directly connects to the Internet.

---

# 2. Final Architecture

                     Sub2API
                        |
                  Account Route
                        |
       +----------------+----------------+
       |                |                |
      US-A             SG-A          CN-DIRECT
       |                |                |
127.0.0.1:11001 127.0.0.1:12001 127.0.0.1:13001
       |                |                |
 sing-box-US      sing-box-SG       sing-box-CN
    |     |          |     |             |
 AnyTLS  HY2       AnyTLS  HY2          direct
    |     |          |     |             |
    US VPS           SG VPS          Chinese AI APIs
      |                |
fixed US IP       fixed SG IP


Additional security layer:

Sub2API UID
    |
sing-box Guard TUN
    |
DNS interception / accidental direct handling
    |
nftables final kill switch

---

# 3. Security Invariants

These are mandatory.

1. No valid EgressRoute: FAIL CLOSED.

2. Route class or required country mismatch: FAIL CLOSED.

3. Empty or invalid effective proxy: FAIL CLOSED.

4. International providers must never use CN-DIRECT.

5. Claude/OpenAI/Grok/Gemini: INTERNATIONAL_PROXY only.

6. DeepSeek/Kimi/Zhipu: CN_DIRECT allowed.

7. EgressRoute stores ProxyID, never ProxyURL.

8. Managed Account.ProxyID must equal EgressRoute.ProxyID.

9. A route Proxy must be socks5h, use a literal internal IP, contain no credentials, use fallback_mode=none, have backup_proxy_id=NULL, expires_at=NULL, status=active and deleted_at=NULL.

10. A Proxy referenced by an EgressRoute cannot be modified or deleted through ordinary Proxy administration.

11. Core EgressRoute fields cannot be modified while the route is referenced.

12. Managed accounts cannot use custom_base_url.

13. security.proxy_fallback.allow_direct_on_error must be forced to false.

14. Sub2API itself must not have unrestricted public IPv4, public IPv6 or direct DNS access.

15. Proxy failure and AnyTLS/HY2 failure must never fall back to a Sub2API host-direct connection. AnyTLS/HY2 fallback is handled only inside sing-box.

16. OAuth, token exchange, token refresh, usage queries, account tests, WebSocket and normal inference requests for one account must use that account's EgressRoute.

17. Grok password authentication is disabled in V1.

18. AnyTLS/HY2 passwords, certificates and VPS secrets do NOT belong in Sub2API DB; their implementation remains outside Sub2API.

19. DNS leak prevention is primarily an OS/sing-box responsibility, not something to solve by invasive modifications throughout Sub2API.

---

# 4. Upstream Source Findings

Important facts found during source audit:

## Main HTTP upstream

Sub2API currently supports:

proxyURL == ""
→ direct connection

Therefore original behavior is not strict enough.

Configured invalid proxy generally returns an error rather than silently falling back, which is good.

## HTTPUpstream is NOT the only network path

Do not assume all Sub2API traffic goes through HTTPUpstream.

There are independent network paths including:

- Claude OAuth
- token refresh
- some usage fetch paths
- httpclient.GetClient
- http.DefaultClient
- net.Dialer
- prompt audit networking
- other provider-specific networking

Therefore:

Application EgressRoute controls account routing.

Linux/sing-box/nftables provide the final no-direct security boundary.

## DNS

Current code contains calls equivalent to:

net.DefaultResolver.LookupIP(...)

Therefore socks5h alone does not guarantee that all DNS resolution happens through the account proxy.

For the locked dependency `golang.org/x/net v0.56.0`, `proxy.FromURL` sends both `socks5` and `socks5h` through the same SOCKS5 dialer. When the target is a hostname, `internal/socks` encodes it as an FQDN SOCKS address and sends it to the SOCKS server. The current dependency evidence therefore does not support a claim that `socks5` necessarily performs local DNS while only `socks5h` performs remote DNS.

Company V1 still requires `protocol == socks5h` as canonical company policy, as an explicit and future-proof statement of remote-DNS intent, and to keep parser/configuration semantics uniform. DNS fail-closed requires application no-pre-resolution plus Guard, the approved resolver and nftables; the scheme label alone is not the security boundary.

---

# 5. EgressRoute Model

Add new entity:

EgressRoute

V1 fields:

id
route_key
name
route_class
country_code
proxy_id
expected_exit_ipv4
notes
created_at
updated_at
deleted_at

Examples:

US-A

route_key:
US-A

route_class:
INTERNATIONAL_PROXY

country_code:
US

proxy_id:
<FK to an existing internal socks5h Proxy>


SG-A

route_class:
INTERNATIONAL_PROXY

country_code:
SG

proxy_id:
<FK to an existing internal socks5h Proxy>


CN-DIRECT

route_class:
CN_DIRECT

country_code:
CN

proxy_id:
<FK to an existing internal socks5h Proxy>


Important:

Even CN-DIRECT uses an internal SOCKS endpoint from Sub2API's perspective.

Sub2API never gets a special unrestricted `direct` branch.

Current deployment fact: the main server public egress geolocates to China. CN-DIRECT therefore keeps `route_class = CN_DIRECT` and `country_code = CN`. Its real fixed `expected_exit_ipv4` is a deployment value that must be filled before activation and verified by RouteHealth.

EgressRoute does not duplicate ProxyURL. The runtime URL is resolved through the Proxy foreign key.

The referenced Proxy must use socks5h with a literal internal IP and no credentials. It must have fallback_mode=none, backup_proxy_id=NULL and expires_at=NULL.

It must also have status=active and deleted_at=NULL. service.Proxy.URL() does not check Status; IsActive() is separate logic, so URL construction is never proof that a Proxy is usable.

V1 does not add route.enabled or dns_addr.

Database constraints:

- route_key is UNIQUE
- proxy_id is UNIQUE and a foreign key to proxies.id

One Proxy row can belong to only one EgressRoute. UNIQUE proxy_id alone does not prevent two Proxy rows naming the same listener, so managed canonical `(protocol, host, port)` endpoint duplication must also be rejected.

A referenced route's core fields — route_key, route_class, country_code, proxy_id and required-country policy — are immutable until every account reference is removed.

A Proxy referenced by an EgressRoute is protected from ordinary modification and deletion.

---

# 6. Account Fields

Add minimal first-class fields:

EgressRouteID *int64

RequiredEgressCountry *string

Existing ProxyID *int64 remains present and, for a managed account, must equal EgressRoute.ProxyID at create, update, clone, bulk-update and request resolution time.

Managed accounts must not set or retain custom_base_url.

Do NOT globally embed/load the entire EgressRoute object into every Account hot-path query unless necessary.

Avoid unnecessary `WithEgressRoute()` changes throughout upstream repositories.

Resolver may independently query route policy by account ID.

---

# 7. Route Classes

Initial enum:

INTERNATIONAL_PROXY

CN_DIRECT

Platform policy:

Anthropic / Claude:
INTERNATIONAL_PROXY only

OpenAI:
INTERNATIONAL_PROXY only

Grok:
INTERNATIONAL_PROXY only

Gemini:
INTERNATIONAL_PROXY only

Antigravity:
UNSUPPORTED for managed V1; any managed Antigravity account must FAIL CLOSED. Do not infer a US or SG route. Any future support requires a separate V2 route audit.

Every account type not explicitly present in the managed V1 platform allowlist is UNSUPPORTED and FAIL CLOSED by default.

DeepSeek:
CN_DIRECT allowed

Kimi:
CN_DIRECT allowed

Zhipu:
CN_DIRECT allowed

Admin configuration must reject invalid combinations.

Runtime resolver must independently reject invalid combinations even if UI validation fails.

---

# 8. Internal Proxy Validation

Egress proxy endpoints must be tightly restricted.

Initial allowed format:

socks5h://<literal-internal-IP>:<port>

Do NOT allow:

public proxy IP
hostname proxy target
HTTP proxy
HTTPS proxy
arbitrary SOCKS endpoint

Initial allowed IP ranges can be:

127.0.0.0/8

and later:

10.200.0.0/16

Do not allow the whole 10.0.0.0/8 unless explicitly required.

Examples allowed:

socks5h://127.0.0.1:11001

socks5h://127.0.0.1:12001

socks5h://127.0.0.1:13001

Potential future:

socks5h://10.200.1.2:1080

---

# 9. EgressPolicyResolver

Create a small service interface such as:

type EgressPolicyResolver interface {
    ResolveForAccount(
        ctx context.Context,
        accountID int64,
    ) (*EgressDecision, error)
}

EgressDecision contains only runtime policy:

RouteID
RouteKey
RouteClass
CountryCode
ProxyID
ProxyURL
ExpectedExitIPv4

Resolver checks:

- account exists
- route assigned
- route exists
- required country exists
- country matches
- platform allowed for route class
- account ProxyID equals route ProxyID
- referenced Proxy exists
- referenced Proxy satisfies the socks5h/literal-internal-IP/no-credentials/no-fallback/no-expiry rules
- referenced Proxy status is active and deleted_at is NULL
- managed account has no custom_base_url
- runtime RouteHealth is READY and not expired

No valid result:
return error

Never return empty proxy as a normal successful decision.

security.proxy_fallback.allow_direct_on_error is a production startup invariant, not a per-request hot-path check. If it is true in company production mode, the process must FAIL STARTUP.

## Runtime RouteHealth

V1 has no database route.enabled field. Availability is represented separately by runtime RouteHealth:

READY

UNHEALTHY

EgressResolver may return EgressDecision only when the route is READY and its health record is within TTL.

V1 health rules:

- startup preflight: synchronously probe every EgressRoute referenced by a managed account before managed traffic is admitted
- production startup/activation: if any referenced managed route is not READY, managed service activation fails closed
- periodic probe interval: 60 seconds
- health TTL: 120 seconds from the last successful verified probe
- probe timeout: a company-owned bounded deadline; do not inherit administrator-configurable diagnostic probe behavior
- probe transport: derive the URL from the validated route Proxy and use the approved company parser/dialer; the current ProxyExitInfoProber is not a security authority because its defaults are HTTP, it accepts configured replacements, it returns the first success, and ipify supplies no country
- Probe A is exactly `https://api.ipify.org?format=json` and supplies IPv4 evidence only
- Probe B is exactly `https://cloudflare.com/cdn-cgi/trace` and supplies IPv4 plus `loc` CountryCode evidence
- both endpoints are a compile-time allowlist with exact HTTPS scheme, hostname, path and query where present; normal TLS verification, redirects disabled, bounded timeout and bounded body are mandatory
- administrators cannot modify either endpoint, and the verifier cannot fall back to upstream default HTTP probes
- READY requires `A.IP == B.IP`, `A.IP == expected_exit_ipv4`, and `B.loc == route.country_code`
- evidence IP must be canonical public IPv4
- TLS failure, redirect, parse failure, IPv6, private IP, missing `loc`, IP disagreement, IP mismatch or country mismatch immediately produces UNHEALTHY and FAIL CLOSED
- probe failure: immediately mark UNHEALTHY; do not retain READY until TTL
- stale/expired health: treat as UNHEALTHY and fail closed
- exit IP: canonical IPv4 returned by the probe must exactly equal expected_exit_ipv4
- exit country: normalized CountryCode must exactly equal route.country_code
- missing IP or CountryCode: cannot become READY
- mismatch: mark UNHEALTHY and fail managed requests closed
- recovery: only a later complete matching probe may return the route to READY

CN_DIRECT has no implicit exception in V1: its verified CountryCode must be CN and its actual exit IPv4 must equal expected_exit_ipv4. Any future exception requires an explicit, documented policy revision.

---

# 10. HTTPUpstream Strategy

Do NOT heavily modify:

backend/internal/repository/http_upstream.go

Prefer wrapper/decorator:

company_http_upstream.go

Concept:

type companyHTTPUpstream struct {
    base     service.HTTPUpstream
    resolver service.EgressPolicyResolver
}

For requests with a real accountID:

accountID
  ↓
resolver.ResolveForAccount()
  ↓
route ProxyID (must equal Account.ProxyID)
  ↓
validated Proxy record
  ↓
derived effective ProxyURL
  ↓
official HTTPUpstream

Ignore caller-selected ProxyURL as the final authority when company strict mode is active.

Keep original HTTPUpstream implementation as intact as possible.

Production DI should inject CompanyHTTPUpstream.

---

# 11. Important Exception: HTTPUpstream Is Not Enough

The following must also be checked and integrated with EgressRoute:

## Claude OAuth

Initial OAuth happens before the Account may exist.

Therefore account creation flow should select:

Required Country
+
EgressRoute

BEFORE starting OAuth.

OAuth session should preserve selected EgressRoute identity.

OAuth authorization, code exchange and subsequent created account must use the same route.

The session must also preserve the final ProxyID. Callback/code exchange must reject route or ProxyID drift.

## Token Refresh

Existing refresh logic may use legacy ProxyID.

Company version must resolve EgressRoute instead.

Claude, OpenAI, Grok and Gemini authorization, token exchange and refresh all use the same route and final ProxyID.

## Usage Queries

Some Claude usage paths currently bypass HTTPUpstream when TLS profile is absent.

Company V1 must route Claude usage through CompanyHTTPUpstream even when no TLS Profile is selected.

## Account Connectivity Tests

Where they already call HTTPUpstream with accountID, wrapper should automatically enforce the route.

## OpenAI/Grok/Gemini OAuth

Audit their independent clients and ensure the same invariant:

one account
→ one EgressRoute
→ OAuth/refresh/usage/inference all consistent

Do not assume they automatically use HTTPUpstream.

Grok password authentication is disabled in V1.

OpenAI/Grok WebSocket must resolve and validate the final ProxyID against EgressRoute.ProxyID before dialing.

Go 1.27 `net/http.Transport` supports both socks5 and socks5h Proxy URLs. The current WebSocket risk is not missing SOCKS5H support; it is that raw `url.Parse(proxyURL)` bypasses project `proxyurl.Parse` policy validation. The company dial path must be `proxyurl.Parse -> proxyutil.ConfigureTransportProxy -> coderws`, preserving the project's fail-fast parser, canonical normalization and approved transport construction.

---

# 12. Legacy Proxy

Do NOT remove upstream Proxy support.

Keep:

Proxy
ProxyID
existing upstream Proxy features

Reason:

Minimize upstream conflicts.

Company strict mode takes precedence for managed account egress.

Legacy features may remain for upstream compatibility.

Do not mass-edit all account.Proxy usages unless required for security-critical account flows.

For managed accounts:

- account.proxy_id must equal route.proxy_id
- custom_base_url is forbidden
- security.proxy_fallback.allow_direct_on_error is forced false
- Sub2API proxy fallback cannot be used for AnyTLS/HY2 failure

AnyTLS/HY2 primary/backup behavior remains entirely inside sing-box.

In company production mode, allow_direct_on_error=true causes startup failure. EgressResolver does not repeat this configuration check on every request.

Proxy administration must reject ordinary update/delete operations when the Proxy is referenced by an EgressRoute.

---

# 13. Database Migration

Add new `egress_routes` table.

Add nullable columns to existing accounts first:

egress_route_id

required_egress_country

Do NOT initially make egress_route_id NOT NULL because existing production accounts already exist.

Strict application logic determines schedulability / request rejection.

The new egress_routes table stores proxy_id as a UNIQUE FK to the existing proxies table and route_key is UNIQUE. It does not store proxy_url, enabled or dns_addr.

Applied migrations are immutable.

Never edit a migration after production has applied it.

Use a company migration namespace that avoids upstream numbering conflicts.

Example:

900000_company_001_egress_routes.sql

900001_company_002_xxx.sql

---

# 14. Files Preferably Added

Prefer new files such as:

backend/ent/schema/egress_route.go

backend/internal/service/egress_route.go

backend/internal/repository/egress_route_repo.go

backend/internal/repository/egress_policy_resolver.go

backend/internal/repository/company_http_upstream.go

backend/internal/handler/admin/egress_route_handler.go

company-specific tests

COMPANY_EGRESS_V1_SPEC.md

COMPANY_PATCHSET.md

---

# 15. Upstream Files Expected to Need Small Changes

Likely:

backend/ent/schema/account.go

backend/internal/service/account.go

backend/internal/service/account_service.go

backend/internal/repository/account_repo.go

backend/internal/repository/wire.go

OAuth service/handler paths

Claude usage path

OpenAI/Grok WebSocket path

Proxy admin update/delete guards

security.proxy_fallback setting enforcement

Admin account API

Account create/edit frontend

EgressRoute admin UI/router

Try to keep this list minimal.

---

# 16. Files/Subsystems We Prefer NOT to Modify

Unless absolutely necessary:

gateway_forward.go

http_upstream.go

provider request body transformations

Claude protocol transformations

OpenAI protocol transformations

Grok protocol transformations

Gemini protocol transformations

TLS fingerprint implementation

billing calculation

token counting

scheduler algorithms

AnyTLS implementation

HY2 implementation

sing-box implementation

generated Ent files

Never manually edit generated Ent code.

Modify Ent schema and regenerate instead.

---

# 17. DNS / Linux Security Plan

Do NOT attempt large invasive route-aware DNS rewrites throughout Go V1.

Current problem:

Sub2API may call:

net.DefaultResolver

Therefore final production layer will use:

sing-box Guard TUN
+
Sub2API UID-specific capture
+
dedicated service DNS/resolv.conf
+
DNS hijack where appropriate
+
nftables kill switch
+
public IPv6 denial

Important Linux issue:

Do not rely only on hijacking DNS sent to 127.0.0.53/systemd-resolved.

Sub2API service should eventually use a dedicated resolver path that is captured by the Guard network layer.

---

# 18. sing-box Roles

Three/four logical services may exist:

sing-box-US
→ US AnyTLS primary
→ US HY2 backup

sing-box-SG
→ SG AnyTLS primary
→ SG HY2 backup

sing-box-CN
→ approved Chinese AI domains direct

sing-box-GUARD
→ safety interception / DNS / unexpected Sub2API direct traffic

AnyTLS and HY2 for one country may terminate on the same VPS/public IP.

Manual failover first.

Do not introduce complex automatic cross-country failover in V1.

---

# 19. nftables Final Policy

Eventually enforce at kernel level.

Sub2API UID:

allow required local resources only:

- localhost
- PostgreSQL
- Redis
- approved internal EgressRoute endpoints
- approved Guard/TUN DNS path

deny:

- arbitrary public IPv4
- all unintended public IPv6
- direct DNS
- direct Anthropic/OpenAI/Grok/Gemini access

sing-box-US UID:

allow only exact US VPS IP/protocol/ports needed for AnyTLS/HY2

sing-box-SG UID:

allow only exact SG VPS IP/protocol/ports

CN service:

allow only explicit approved Chinese AI destinations/policy

Never use:

iptables -F

nft flush ruleset

ufw reset

because SSH/Nginx must not be destroyed.

## V1 Threat Model: UID Boundary versus Account Geography

A single Sub2API process/UID handles accounts assigned to multiple countries. Linux UID/nftables policy can enforce no host public direct, no unintended IPv6 and no direct DNS. It cannot see Account identity and therefore cannot independently enforce `US account -> only US SOCKS` or `SG account -> only SG SOCKS` when both local SOCKS endpoints are allowed to the same UID.

Per-account geographic selection is an application invariant enforced by EgressRoute, immutable EgressDecision, route-aware HTTP/WS/OAuth/Refresh/Usage/Batch factories, CI/static guards and tests. The host guard is the origin-leak boundary, not the account-country selection engine.

Kernel-level per-country/account isolation would require separate workers, UIDs and/or network namespaces. That is a V2 architecture and is outside V1.

---

# 20. Required Security Tests

At minimum:

AccountWithoutRoute
→ rejected

CountryMismatch
→ rejected

PlatformRouteClassMismatch
→ rejected

EmptyProxy
→ rejected

PublicProxyEndpoint
→ rejected

HostnameProxyEndpoint
→ rejected

WrongCallerProxy
→ ignored / replaced by account EgressRoute

CorrectUSRoute
→ US endpoint

CorrectSGRoute
→ SG endpoint

DeepSeekCNRoute
→ CN internal endpoint

ClaudeCNRoute
→ rejected

ProxyDown
→ request fails

No direct fallback
→ guaranteed by tests + OS layer

OAuth route consistency
→ authorization/token exchange/refresh same route

Usage route consistency
→ same account route

Account test route consistency
→ same account route

Later integration tests:

kill sing-box-US
→ US Claude request fails

kill AnyTLS/HY2
→ no host direct fallback

tcpdump physical interface
→ no Anthropic/OpenAI direct packets from Sub2API

DNS capture
→ no Sub2API DNS to ordinary host/ISP resolver

IPv6
→ no public IPv6 escape

ReferencedProxyMutation
→ rejected

ReferencedProxyDeletion
→ rejected

ReferencedRouteCoreMutation
→ rejected while referenced

AccountProxyRouteProxyMismatch
→ rejected

ManagedCustomBaseURL
→ rejected

GrokPasswordAuth
→ disabled

OpenAIWebSocketProxyIDMismatch
→ rejected before dial

ClaudeUsageWithoutTLSProfile
→ still routed through CompanyHTTPUpstream

DirectFallbackConfigTrue
→ production startup failure when true

ProxyInactive
→ FAIL CLOSED

ProxySoftDeleted
→ FAIL CLOSED

DuplicateRouteProxyID
→ DB/service reject

WebSocketRawProxyParserBypass
→ prohibited; route-aware dialer test requires proxyurl.Parse and approved transport

ExitIPv4Mismatch
→ route UNHEALTHY + FAIL CLOSED

ExitCountryMismatch
→ route UNHEALTHY + FAIL CLOSED

RouteHealthExpired
→ FAIL CLOSED

---

# 21. Repository Maintenance Rules

Static CI must reject new managed account-sensitive production use of:

- `http.DefaultClient`
- raw `url.Parse(proxyURL)`
- an empty-ProxyURL client
- direct `net.Dialer`
- an unapproved resolver
- an unapproved account outbound factory

An exception is permitted only when explicitly recorded in the audited allowlist. CI is a regression guard; it does not replace code review, route-aware factories or host containment.

Keep repository simple.

Long-lived:

main

Temporary:

company/egress-v1 during initial work

future:
feature/*
upgrade/upstream-*

Remote structure:

origin
→ Ye-0050101/sub2api-company

upstream
→ Wei-Shaw/sub2api

Do not mirror all upstream development branches into company repository.

---

# 22. Upstream Update SOP

Every update:

1. git fetch upstream --tags

2. Review upstream release / diff.

3. Do not immediately deploy.

4. Create temporary branch:

upgrade/upstream-X

5. Merge/rebase intended upstream version.

6. Review files listed in COMPANY_PATCHSET.md.

7. Run upstream tests.

8. Run company security tests.

9. Build company binary.

10. Deploy to staging.

11. Run leakage/fail-closed tests.

12. Only then merge to main.

13. Only then deploy production.

Never:

official install.sh
→ directly overwrite company production binary

Never:

git pull upstream
→ restart production without tests

---

# 23. COMPANY_PATCHSET.md Purpose

Maintain a short list of:

- every upstream file modified
- every company-specific file added
- security invariants
- upstream areas requiring review on upgrade

Goal:

Most company logic lives in new files.

Target:

~90% of customization in new files where practical.

Keep modifications to upstream core small and obvious.

---

# 24. Development Order

Production enforcement cannot be disabled by an ordinary runtime switch while the service continues handling managed traffic. Feature switches are permitted only in development and tests.

Production rollback means deploying the previously approved company binary/version. It must not mean disabling fail-closed enforcement in the current binary. A rollback target that cannot enforce these invariants must not serve managed accounts.

Production activation order is mandatory:

application code/tests
↓
staging
↓
sing-box routes
↓
DNS containment
↓
IPv6 deny
↓
nftables Sub2API UID kill-switch
↓
destructive leak tests
↓
enable managed accounts for production traffic

Managed accounts must not carry production traffic before the kernel guard, DNS containment and destructive leak tests are complete.

Phase 0:
freeze exact upstream production baseline

Phase 1:
EgressRoute schema/model/repository

Phase 2:
Account binding + validation

Phase 3:
CompanyHTTPUpstream wrapper

Phase 4:
Claude/OpenAI/Grok/Gemini OAuth and refresh consistency

Phase 5:
Claude usage and other usage/quota consistency

Phase 6:
OpenAI/Grok WebSocket and account-test consistency

Phase 7:
route class platform policy

Phase 8:
RouteHealth preflight/periodic probes, Proxy/route immutability, no-custom-base-URL and fail-closed tests

Phase 9:
build company binary

Phase 10:
staging deployment

Phase 11:
sing-box routes

Phase 12:
DNS containment

Phase 13:
IPv6 deny

Phase 14:
nftables Sub2API UID kill-switch

Phase 15:
destructive security testing

Phase 16:
enable managed accounts for production traffic

---

# 25. Current Instruction to Codex

Do NOT deploy anything to the production server yet.

Do NOT change firewall/DNS/networking yet.

First:

1. Verify exact repository/base state.
2. Read this spec.
3. Create COMPANY_PATCHSET.md.
4. Audit the exact production-base source.
5. Produce a file-level implementation plan.
6. Only after review begin Phase 1.

Security is more important than minimizing the number of code lines.

Upstream compatibility is the second priority.

Do not silently weaken TLS verification.

Do not introduce any direct fallback.

---

# 26. Final Evidence Audit Gate

The authoritative Phase 0.5 evidence record is `docs/company/EGRESS_FINAL_EVIDENCE_AUDIT_0.1.183.md`. Where an earlier planning statement conflicts with that evidence record, the evidence record controls until an explicit reviewed design decision updates this specification.

Final evidence resolutions at the fixed baseline:

- Managed Antigravity is UNSUPPORTED and always FAIL CLOSED in V1. Future support requires a separate V2 route audit; V1 does not infer US or SG.
- Gemini/Vertex batch providers and Vertex service-account token exchange are independent client paths and must receive EgressDecision; HTTPUpstream decoration cannot cover them.
- UNIQUE route `proxy_id` is not enough: two Proxy rows can name one canonical internal endpoint. Managed `(protocol, canonical_host, port)` duplication must be rejected to prevent route/port cross-wiring.
- RouteHealth evidence endpoints are locked to `https://api.ipify.org?format=json` and `https://cloudflare.com/cdn-cgi/trace` under the exact allowlist and validation rules in this specification. The existing ProxyExitInfoProber remains an administrator diagnostic only.
- CN-DIRECT keeps route class CN_DIRECT and country CN. CN-DIRECT, US-A and SG-A require real fixed `expected_exit_ipv4` deployment values before they can become READY.

Architecture design and production activation are separate gates:

`FINAL DESIGN VERDICT: FREEZE`

`PRODUCTION READINESS: NOT READY`

Phase 1 development may begin after this document-only correction is accepted. Managed production traffic remains forbidden until the fixed exit IPv4 values are populated and the sing-box, DNS containment, IPv6 deny, nftables UID kill-switch and destructive leak tests all pass.
