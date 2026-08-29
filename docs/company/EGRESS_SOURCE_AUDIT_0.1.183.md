# Egress Source Audit 0.1.183

Audit status: Phase 0.5 source-consistency audit
Audited commit: e8cb019fabf8b55199436229044cbf9aa7a82564
Branch: company/egress-v1
Scope: production source at this exact commit; upstream main was not used as an authority
Change boundary: documentation only

## Executive finding

The target architecture is implementable, but HTTPUpstream is not the only outbound path. At this baseline, an empty ProxyURL means direct access in HTTPUpstream, the shared HTTP client pool, req clients, OAuth clients, and WebSocket dialing. A CompanyHTTPUpstream decorator can cover most account-bound inference, model discovery, HTTP connectivity tests, and several quota paths, but cannot alone enforce OAuth, refresh, every usage path, OpenAI/Grok WebSocket, or non-account process traffic.

Therefore the minimum safe design is layered:

Account EgressRoute resolution -> account-aware client/wrapper enforcement -> sing-box Guard -> nftables and IPv6 deny -> DNS containment.

The application layer must fail closed for account-bound traffic. The host layer remains the final control that prevents a missed code path from becoming unrestricted public direct egress.

V1 design decision: EgressRoute references the existing Proxy table by proxy_id and does not store proxy_url, enabled, or dns_addr. For managed accounts, account.proxy_id must equal route.proxy_id and custom_base_url is forbidden.

## Source-to-spec consistency

### Directly implementable

- A new Ent EgressRoute schema and nullable Account.egress_route_id are compatible with the existing Ent and embedded SQL migration layout.
- Account already carries ProxyID and Proxy, so adding route identity while retaining legacy proxy compatibility is structurally straightforward.
- HTTPUpstream already centralizes transport creation for a large fraction of account traffic and exposes accountID on both methods; it can be decorated without changing its public interface.
- Existing admin service/handler/router/wire patterns support route CRUD and account selection UI.
- proxyurl.Parse already accepts http, https, socks5, and socks5h, and normalizes socks5 to socks5h.
- Custom provider base URLs generally remain compatible with transport-level route enforcement when the request still passes a real account ID through HTTPUpstream.

### Paths or interfaces that differ from the specification

- The interface is backend/internal/service/http_upstream_port.go, while the implementation is backend/internal/repository/http_upstream.go. NewHTTPUpstream is provided from backend/internal/repository/wire.go.
- The primary admin account mutation path is backend/internal/service/admin_account.go plus backend/internal/handler/admin/account_handler.go, not account_service.go alone.
- Admin routes are registered centrally in backend/internal/server/routes/admin.go; adding only a handler file is insufficient.
- Migrations are embedded from backend/migrations through backend/internal/repository/migrations_runner.go and backend/migrations/migrations.go.
- Dependency injection spans repository/wire.go, service/wire.go, handler/wire.go, cmd/server/wire.go, and generated cmd/server/wire_gen.go.
- The current OAuth session objects store ProxyURL, not proxy_id, EgressRoute ID, country, or route version.
- Claude usage has a TLS-profile branch through HTTPUpstream and a non-TLS branch through httpclient.GetClient; it is not uniformly centralized.
- OpenAI and Grok realtime traffic uses a separate WebSocket dialer.
- The current code has no per-route DNS policy consumer; V1 therefore does not store dns_addr and leaves final DNS containment to Guard/nftables.
- backend/internal/config/config.go defaults security.proxy_fallback.allow_direct_on_error to false but still accepts a true override. repository/wire.go passes it to the GitHub release and pricing clients, so V1 must reject/override true at configuration load rather than merely rely on the default.
- Managed custom base URL is stored in Account.Extra and consumed through Account.IsCustomBaseURLEnabled/GetCustomBaseURL by gateway_forward.go, gateway_upstream_request.go, and gateway_count_tokens.go. Managed-account create/update validation must reject both the enable flag and URL.

## A. Current real network call graph

    Account request
      |
      +-- HTTP inference / model discovery / many quota and tests
      |     -> service.HTTPUpstream.Do / DoWithTLS
      |     -> repository.httpUpstreamService
      |     -> proxyurl.Parse
      |        +-- non-empty proxy -> HTTP proxy or SOCKS dialer
      |        +-- empty proxy -> direct net.Dialer
      |
      +-- OAuth authorization helpers / code exchange / refresh
      |     -> provider service resolves legacy Account.ProxyID or session.ProxyURL
      |     -> req_client_pool / provider-specific req or http.Client
      |        +-- non-empty proxy -> configured proxy
      |        +-- empty proxy -> direct transport
      |
      +-- Usage / quota
      |     +-- some providers -> HTTPUpstream
      |     +-- Claude non-TLS, OpenAI Codex, Gemini Drive/project helpers
      |           -> httpclient.GetClient or req client -> direct when empty
      |
      +-- Realtime / WebSocket
      |     -> openAIWSDialer / coderws.Dial
      |        +-- proxy supplied -> custom HTTP transport
      |        +-- empty -> default direct dial
      |
      +-- Account connectivity tests
            +-- most HTTP tests -> HTTPUpstream
            +-- Grok realtime test -> WebSocket dialer

    Non-account process traffic
      -> login OAuth, payment, email SMTP, release/pricing checks,
         Turnstile, web search, channel monitor, security moderation,
         image storage/download and other service clients
      -> independent http.Client / req.Client / net.Dialer

## B. Platform exit matrix

| Platform/operation | Current source path | Current effective exit | Wrapper coverage |
|---|---|---|---|
| Claude authorization | oauth_service.go -> Claude OAuth client; normal URL is returned to browser, cookie auto-auth performs server requests | Session ProxyURL; empty is direct | No |
| Claude callback/code exchange | oauth_service.go -> repository/claude_oauth_service.go -> req client | Callback input ProxyID can override session ProxyURL; empty is direct | No |
| Claude refresh | OAuthService.RefreshAccountToken -> Claude OAuth client | Legacy Account.ProxyID; missing/lookup failure can become empty/direct | No |
| Claude usage | account_usage_service.go -> repository/claude_usage_service.go | TLS profile uses HTTPUpstream; otherwise httpclient pool; empty is direct | Partial |
| Claude inference/test | gateway/account_test -> HTTPUpstream | Caller Account.Proxy or direct when empty | Yes, except non-HTTP helpers |
| OpenAI authorization | openai_oauth_service.go; URL returned to browser | Session stores resolved ProxyURL only | No |
| OpenAI code exchange | openai_oauth_service.go -> repository/openai_oauth_service.go -> shared req client | Input ProxyID can override session; empty is direct | No |
| OpenAI refresh | OpenAIOAuthService.RefreshAccountToken -> shared req client | Legacy Account.ProxyID; empty is direct | No |
| OpenAI usage/quota | openai_quota_service.go privacy client; account_usage_service.go Codex probe | Provider-specific clients using legacy proxy; empty is direct | No |
| OpenAI inference/test HTTP | plugin/gateway/test -> HTTPUpstream | Caller Account.Proxy or direct when empty | Yes |
| OpenAI realtime/test | openai_ws_* and openai_live.go | coderws with optional proxy; empty is direct | No |
| Grok authorization | grok_oauth_service.go | Session ProxyURL; empty is direct | No |
| Grok exchange/refresh | grok_oauth_service.go -> repository/grok_oauth_client.go | Shared req client; empty is direct | No |
| Grok password/captcha login | grok_oauth_client.go | Optional HTTP proxy; captcha create/poll uses http.DefaultClient directly | No |
| Grok quota/media/inference HTTP | grok_quota_service.go, grok_media.go, gateway -> HTTPUpstream | Caller legacy proxy; empty is direct | Yes |
| Grok realtime/account test | openAI WebSocket dialer, account_test_service.go | Optional proxy; empty is direct | No |
| Gemini authorization | gemini_oauth_service.go | Session ProxyURL; empty is direct | No |
| Gemini exchange/refresh | gemini_oauth_service.go -> repository/gemini_oauth_client.go | Shared req client; empty is direct | No |
| Gemini usage/quota | account usage, geminicli/drive_client.go, project/tier helpers | httpclient pool with optional legacy proxy; empty is direct; local quota code has no remote call | No or local-only |
| Gemini inference/test HTTP | Gemini gateways/account tests -> HTTPUpstream | Caller legacy proxy; empty is direct | Yes |
| DeepSeek/Kimi/Zhipu inference, balance, quota, tests | CN provider services -> HTTPUpstream in the principal paths | Caller legacy proxy; empty is direct | Yes |

Authorization URL generation performed only in the administrator's browser is not a server-side outbound. Automatic cookie/password flows and every code/token exchange are server-side outbound.

## C. Direct-capable production code

Direct-capable means the production path can construct or fall back to a client/dialer that reaches a target without a mandatory company route. It does not mean every invocation is currently direct.

### Central account transport

- backend/internal/repository/http_upstream.go — normalizeProxyURL returns the direct key and nil proxy for empty input; buildUpstreamTransport then uses a direct net.Dialer.
- backend/internal/pkg/httpclient/pool.go — empty ProxyURL builds a direct http.Transport.
- backend/internal/repository/req_client_pool.go — proxy is configured only when ProxyURL is non-empty.
- backend/internal/pkg/proxyutil/dialer.go — a nil proxy leaves the transport direct.
- backend/internal/pkg/tlsfingerprint/dialer.go — a missing base dialer falls back to net.Dialer.

### Account-bound provider clients outside the wrapper

- backend/internal/repository/claude_oauth_service.go
- backend/internal/repository/openai_oauth_service.go
- backend/internal/repository/grok_oauth_client.go
- backend/internal/repository/gemini_oauth_client.go
- backend/internal/repository/claude_usage_service.go
- backend/internal/pkg/geminicli/drive_client.go
- backend/internal/pkg/antigravity/client.go
- backend/internal/pkg/xai/sso_device.go
- backend/internal/service/account_usage_service.go
- backend/internal/service/gemini_oauth_service.go
- backend/internal/service/openai_quota_service.go
- backend/internal/service/openai_agent_identity.go
- backend/internal/service/openai_codex_pat_service.go
- backend/internal/service/openai_codex_models_service.go
- backend/internal/service/vertex_service_account.go
- backend/internal/service/openai_ws_client.go
- backend/internal/service/openai_live.go
- backend/internal/service/openai_ws_forwarder_ingress.go
- backend/internal/service/openai_ws_forwarder_v2.go
- backend/internal/service/openai_ws_pool.go
- backend/internal/service/openai_ws_v2_passthrough_adapter.go
- backend/internal/service/account_test_service.go — Grok realtime test is outside HTTPUpstream.
- backend/internal/service/batch_image_provider_gemini.go
- backend/internal/service/batch_image_provider_vertex.go

### Non-account application and infrastructure clients

- backend/internal/handler/auth_wechat_oauth.go
- backend/internal/handler/auth_dingtalk_client.go
- backend/internal/handler/auth_email_oauth.go
- backend/internal/handler/auth_linuxdo_oauth.go
- backend/internal/handler/auth_oidc_oauth.go
- backend/internal/service/setting_oauth.go
- backend/internal/payment/provider/airwallex.go
- backend/internal/payment/provider/easypay.go
- backend/internal/repository/github_release_service.go
- backend/internal/repository/pricing_service.go
- backend/internal/repository/turnstile_service.go
- backend/internal/repository/proxy_probe_service.go
- backend/internal/pkg/websearch/manager.go
- backend/internal/pkg/websearch/brave.go
- backend/internal/pkg/websearch/tavily.go
- backend/internal/securityaudit/prompt_outbound_security.go
- backend/internal/securityaudit/prompt_service.go
- backend/internal/securityaudit/prompt_qwen3guard.go
- backend/internal/service/channel_monitor_checker.go
- backend/internal/service/channel_monitor_ssrf.go
- backend/internal/service/content_moderation.go
- backend/internal/service/crs_sync_service.go
- backend/internal/service/email_service.go
- backend/internal/service/image_storage.go
- backend/internal/service/batch_image_download.go
- backend/internal/pkg/servertiming/http.go — generic fallback accepts nil/default clients.

The process also connects to configured internal infrastructure such as PostgreSQL, Redis, object storage, and SMTP. Those are not account EgressRoute traffic. Host enforcement must explicitly allow required internal destinations and deny unrestricted public direct access.

### Exact high-risk primitives found

- http.DefaultClient: websearch/brave.go, websearch/tavily.go, repository/grok_oauth_client.go, service/batch_image_provider_gemini.go, service/content_moderation.go, and generic servertiming fallback.
- Explicit http.Client or &http.Client: payment providers, xai/sso_device.go, prompt outbound security, websearch manager, servertiming, WeChat/DingTalk auth, httpclient pool, antigravity client, channel monitor, HTTPUpstream, Grok OAuth, release/pricing/Turnstile, image storage, OpenAI WebSocket, Vertex service-account flow.
- Explicit net.Dialer: websearch manager, TLS fingerprint dialer, antigravity client, proxyutil, httpclient pool, HTTPUpstream, prompt outbound security, channel monitor, and email SMTP.
- Explicit TLS dial: email_service.go uses tls.DialWithDialer.

## D. DNS lookup paths

### Explicit application lookups

- backend/internal/util/urlvalidator/validator.go: net.DefaultResolver.LookupIP. HTTPUpstream and httpclient validation can invoke it when host validation is enabled.
- backend/internal/service/channel_monitor_ssrf.go: net.DefaultResolver.LookupIPAddr in hostname validation and dial preparation.

### Implicit lookups

- Every direct net.Dialer or default http.Transport resolves target hostnames through the Go/OS resolver.
- HTTP and HTTPS proxy transports may resolve the proxy endpoint locally.
- SOCKS behavior depends on the parsed scheme and dialer. backend/internal/pkg/proxyurl/parse.go normalizes socks5 to socks5h, and proxyutil passes the hostname to the SOCKS dialer, which is the intended remote-resolution path.
- The OpenAI/Grok WebSocket client parses proxy URLs independently and uses http.ProxyURL; it is not proven to share proxyurl.Parse normalization or the same remote-DNS guarantee.
- Resolver calls used for SSRF validation intentionally resolve before connection, so even a later proxied request can cause a local DNS lookup.

Conclusion: socks5h is necessary for account traffic but is not sufficient for process-wide DNS containment. nftables/namespace policy must restrict DNS to approved internal resolvers, and the application must avoid pre-resolving route-bound public hostnames.

## E. Upstream files that can remain unchanged

The following can remain unchanged in the first minimal patch if the decorator and route-aware factories are introduced cleanly:

- Most HTTP inference implementations that already call service.HTTPUpstream with the real account ID, including the main Claude, OpenAI, Grok, Gemini, and CN provider gateway paths.
- backend/internal/service/http_upstream_port.go — its existing accountID parameter is sufficient for decoration.
- backend/internal/repository/http_upstream.go — retain transport, concurrency, fallback, TLS-profile, and metrics behavior behind the wrapper.
- backend/internal/pkg/proxyurl/parse.go — current socks5 to socks5h normalization is reusable.
- backend/internal/pkg/proxyutil/dialer.go — reusable after the effective route has been resolved and validated.
- Existing request/response translation, streaming, billing, scheduling, and provider protocol code that delegates outbound HTTP to HTTPUpstream.

This exemption does not apply to WebSocket or provider clients that construct their own clients.

## F. Upstream files requiring small changes

### Required for model and CRUD

- backend/ent/schema/account.go
- backend/internal/service/account.go
- backend/internal/service/account_service.go
- backend/internal/service/admin_service.go
- backend/internal/service/admin_account.go
- backend/internal/repository/account_repo.go
- backend/internal/handler/admin/account_handler.go
- backend/internal/server/routes/admin.go
- backend/internal/repository/wire.go
- backend/internal/service/wire.go
- backend/internal/handler/wire.go
- backend/cmd/server/wire.go
- frontend/src/api/admin/accounts.ts
- frontend/src/views/admin/AccountsView.vue
- frontend/src/components/account/CreateAccountModal.vue
- frontend/src/components/account/EditAccountModal.vue
- frontend/src/components/account/BulkEditAccountModal.vue
- frontend/src/router/index.ts

### Required to close account-path bypasses

- The four OAuth service/session packages and four provider OAuth repository clients listed in section C.
- backend/internal/repository/req_client_pool.go or a new route-aware factory replacing its account-bound use.
- backend/internal/repository/claude_usage_service.go
- backend/internal/service/account_usage_service.go
- backend/internal/service/openai_quota_service.go
- backend/internal/service/openai_ws_client.go and its forwarder/pool callers.
- backend/internal/service/account_test_service.go for realtime tests.
- Gemini Drive/project helpers and any OpenAI Codex helper that bypasses HTTPUpstream.
- backend/internal/config/config.go to force security.proxy_fallback.allow_direct_on_error=false.
- backend/internal/service/gateway_forward.go, gateway_upstream_request.go, and gateway_count_tokens.go as defense-in-depth checks against managed custom base URL.
- backend/internal/service/admin_proxy.go and backend/internal/repository/proxy_repo.go to reject ordinary update/delete of a route-referenced Proxy.

Generated Ent and Wire output will change only through the existing generators during implementation.

## G. Recommended company-owned additions

- backend/ent/schema/egress_route.go
- backend/internal/service/egress_route.go
- backend/internal/repository/egress_route_repo.go
- backend/internal/repository/company_egress_resolver.go
- backend/internal/repository/company_http_upstream.go
- backend/internal/repository/company_http_client_factory.go
- backend/internal/repository/company_ws_dialer.go
- backend/internal/handler/admin/egress_route_handler.go
- backend/migrations/900000_company_egress_routes.up.sql
- backend/migrations/900000_company_egress_routes.down.sql
- frontend/src/views/admin/EgressRoutesView.vue
- frontend/src/components/account/EgressRouteSelect.vue
- frontend/src/api/admin/egress-routes.ts

The factory and WebSocket dialer additions are needed because the HTTPUpstream wrapper cannot cover those paths.

## H. Minimum EgressRoute database model

Minimum route fields:

| Field | Purpose |
|---|---|
| id | Stable route identity |
| name | Administrator-facing name |
| route_class | INTERNATIONAL_PROXY or CN_DIRECT |
| proxy_id | FK to an existing protected Proxy record |
| country_code | Intended country/region policy |
| expected_exit_ipv4 | Optional verification target, not request-time enforcement |
| version | OAuth session drift and cache invalidation |
| created_at / updated_at | Auditability |

Minimum Account additions:

- egress_route_id: nullable during migration, mandatory under company enforcement for supported account platforms.
- egress_country: denormalized snapshot for UI/audit only; the route row remains authoritative.
- existing proxy_id: mandatory for managed accounts and exactly equal to EgressRoute.proxy_id.

Constraints:

- International platforms Claude/OpenAI/Grok/Gemini may bind only INTERNATIONAL_PROXY.
- DeepSeek/Kimi/Zhipu may bind only CN_DIRECT.
- The referenced Proxy must use socks5h, a literal internal IP, no credentials, fallback_mode=none, backup_proxy_id=NULL, and expires_at=NULL.
- A Proxy referenced by an EgressRoute cannot be changed or deleted by ordinary Proxy administration.
- EgressRoute core fields cannot be changed while any Account references the route.
- V1 has no route.enabled and no dns_addr.
- Managed accounts cannot use custom_base_url.
- Route version changes invalidate or reject in-flight OAuth sessions.

## I. Feasibility of CompanyHTTPUpstream

Feasible and high-value. Both Do and DoWithTLS already receive accountID, and most account HTTP calls provide the real account ID. The decorator can:

1. Resolve Account.egress_route_id by accountID.
2. Load the route, validate platform class, and obtain route.proxy_id.
3. Require Account.proxy_id == EgressRoute.proxy_id, load the Proxy, and validate socks5h/literal-internal-IP/no-credentials/no-fallback/no-backup/no-expiry.
4. Derive the effective proxy URL from the validated Proxy record.
5. Ignore the caller's legacy ProxyURL for company-enforced accounts.
6. Delegate to the unchanged HTTPUpstream implementation.
7. Fail closed on accountID zero, missing route, ProxyID mismatch, parse failure, or class mismatch according to an explicit call-site policy.

The provider graph must expose the decorated implementation as service.HTTPUpstream while retaining the raw implementation as an internal concrete dependency. A distinct provider function or concrete type is needed to avoid two providers for the same interface.

Caching route resolution is acceptable only with bounded TTL or versioned invalidation. Error text and metrics must not leak proxy credentials.

## J. Paths the wrapper cannot cover

- OAuth authorization-side automatic requests, code exchange, and refresh for Claude/OpenAI/Grok/Gemini.
- OAuth session integrity: current callback inputs can select a different ProxyID from the session.
- Claude usage when TLSProfile is nil.
- OpenAI quota/privacy clients and Codex account-usage probes.
- Gemini Drive, project discovery, tier and resource helpers.
- OpenAI/Grok WebSocket and realtime handshakes, pools, reconnects, and realtime account tests.
- Grok password login and captcha create/poll; the latter uses http.DefaultClient.
- Antigravity and Vertex helper clients where they construct their own transport.
- Non-account login OAuth, payments, SMTP, release/pricing/Turnstile, web search, channel monitoring, moderation/security, and image fetch/storage traffic.
- Explicit resolver/SSRF validation calls.
- Any future call site that supplies accountID zero or constructs its own client.

These paths require route-aware factories/dialers or host-level blocking. The wrapper must not be described as complete leak prevention.

## K. Phase 1 minimum patch set

1. Schema and migration: add EgressRoute with proxy_id FK plus nullable Account route fields; retain Account.proxy_id and enforce equality for managed accounts. Do not add proxy_url, enabled, or dns_addr.
2. Route CRUD and validation: repository, service, admin handler/routes, minimal UI selector, protected Proxy update/delete, and route core-field immutability while referenced.
3. Resolver: resolve by account ID, enforce platform class, ProxyID equality, Proxy shape, no custom_base_url, and fail-closed semantics.
4. HTTP decorator: wrap Do and DoWithTLS and change the Wire provider. Leave the raw HTTPUpstream implementation unchanged.
5. OAuth closure: bind Claude/OpenAI/Grok/Gemini authorization, exchange and refresh to the same route and ProxyID; remove callback route override. Disable Grok password auth.
6. Usage/test closure: force Claude usage through CompanyHTTPUpstream even without a TLS Profile; route OpenAI quota/Codex probes, Gemini helpers, and account realtime tests through route-aware clients.
7. WebSocket closure: validate final ProxyID against EgressRoute and require the route-aware dialer for OpenAI/Grok realtime, reconnect, pool, and tests.
8. Fallback closure: force security.proxy_fallback.allow_direct_on_error=false; keep AnyTLS/HY2 failover only inside sing-box.
9. Verification: prove missing/mismatched routes, invalid Proxy shape, protected mutation, custom base URL, OAuth drift and WebSocket drift fail before any dial.
10. Operational gate: nftables/Guard deny the Sub2API UID arbitrary public IPv4, public IPv6 and direct DNS; only approved internal resources and route endpoints are allowed.

No migration, business-code patch, generator run, deployment, or host change belongs to Phase 0.5.

## L. Known security blind spots

- HTTPUpstream request-host validation is configuration-dependent; when URL allowlisting/private-host blocking is disabled, custom base URLs may target internal networks. Egress routing does not replace SSRF validation.
- Managed accounts forbid custom_base_url in V1; unmanaged compatibility paths still retain the upstream SSRF/destination-policy risk.
- expected_exit_ipv4 is only data until a probe verifies it; per-request exit identity cannot be inferred from configuration alone.
- V1 intentionally stores no dns_addr; DNS containment is an external Guard/nftables responsibility.
- Resolver-based SSRF checks can leak DNS before a proxied connection.
- OAuth sessions currently store raw resolved ProxyURL, are not route-version bound, and allow callback override.
- Legacy ProxyID, proxy fallback chains, and shadow-account propagation can diverge from the new route unless migration rules are explicit.
- accountID zero is used by generic/non-account traffic; a global fail-closed choice could break system functions, while allowing it preserves a bypass. Each such caller needs classification.
- SOCKS5h behavior is not uniformly shared by WebSocket and every third-party library.
- Environment-provided HTTP proxy behavior and library defaults need tests; a wrapper should set transports explicitly.
- Go's OS resolver, IPv6 happy-eyeballs behavior, and direct fallback can escape application intent unless host controls deny them.
- Internal infrastructure allowlists can themselves become broad bypasses if destination ports or identities are not constrained.
- New upstream code may add another client after this audit; CI needs a guard for http.DefaultClient, direct http.Client, net.Dialer, tls.Dial, and resolver primitives.
- Transport retries and proxy fallback must never fall back from a failed route to direct.
- security.proxy_fallback.allow_direct_on_error must be forced false, and AnyTLS/HY2 fallback must remain inside sing-box.
- Logs, metrics, and admin APIs must redact credentials embedded in proxy URLs.

## Audit conclusion

At e8cb019, the specification's core data model and HTTPUpstream decoration are compatible with the source, but the security boundary must be broader than HTTPUpstream. Phase 1 should make route resolution the authority for every account-bound client family and use host controls as the final deny layer. Until that work and its tests are complete, no claim of leak-free egress is justified.
