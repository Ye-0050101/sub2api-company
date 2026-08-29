# Sub2API Company Egress V1 — Planned Patch Surface

Status: planned only
Audited baseline: e8cb019fabf8b55199436229044cbf9aa7a82564
Target tag context: production-base-0.1.183
Implementation state: Phase 0.5 documentation only; none of the controls below is implemented by this file.

## Scope rule

Phase 1 must preserve upstream behavior except where an outbound request would otherwise violate an assigned EgressRoute. No server, firewall, sing-box, database, or production deployment change is part of this patch plan.

## Planned new company-owned files

- backend/ent/schema/egress_route.go
- backend/internal/service/egress_route.go
- backend/internal/repository/egress_route_repo.go
- backend/internal/repository/company_egress_resolver.go
- backend/internal/repository/company_http_upstream.go
- backend/internal/repository/company_egress_health.go
- backend/internal/repository/company_ws_dialer.go
- backend/internal/handler/admin/egress_route_handler.go
- backend/migrations/900000_company_egress_routes.up.sql
- backend/migrations/900000_company_egress_routes.down.sql
- frontend/src/views/admin/EgressRoutesView.vue
- frontend/src/components/account/EgressRouteSelect.vue
- frontend/src/api/admin/egress-routes.ts

Migration files are names reserved for Phase 1. They are not generated or created in Phase 0.5.

The EgressRoute table uses proxy_id as a UNIQUE foreign key to the existing Proxy table; route_key is also UNIQUE. It does not store proxy_url, enabled, or dns_addr in V1.

## Planned small upstream edits

### Account persistence and API

- backend/ent/schema/account.go — add nullable egress_route_id and required_egress_country; add route edge only if repository queries require it.
- backend/internal/service/account.go — expose the two fields in the domain model.
- backend/internal/service/account_service.go — extend generic create/update DTOs.
- backend/internal/service/admin_service.go — extend admin input/output types.
- backend/internal/service/admin_account.go — validate platform/route class, persist updates, clone and shadow-account propagation rules.
- backend/internal/repository/account_repo.go — map, create, update, bulk-update, snapshot, and reload the new fields.
- backend/internal/handler/admin/account_handler.go — request/response binding for create, edit, bulk edit, and clone.
- frontend/src/api/admin/accounts.ts — account DTO fields.
- frontend/src/components/account/CreateAccountModal.vue
- frontend/src/components/account/EditAccountModal.vue
- frontend/src/components/account/BulkEditAccountModal.vue
- frontend/src/views/admin/AccountsView.vue

### Route administration

- backend/internal/server/routes/admin.go — register EgressRoute admin endpoints.
- backend/internal/handler/wire.go — provide the handler.
- backend/internal/service/wire.go — provide route service/resolver dependencies.
- backend/internal/repository/wire.go — replace the raw HTTPUpstream provider with a decorated provider and provide route repository/resolver.
- backend/cmd/server/wire.go — include providers where required.
- frontend/src/router/index.ts — register the route-management page.

Route validation must require the referenced Proxy to be socks5h with a literal internal IP, no credentials, no fallback, no backup, no expiry, status=active and deleted_at=NULL. Ordinary Proxy update/delete is rejected while referenced, and route_key, route_class, country_code, proxy_id, expected_exit_ipv4, and required-country policy are immutable while the route is referenced.

Locked `golang.org/x/net v0.56.0` sends both socks5 and socks5h schemes through the same SOCKS5 dialer and encodes hostname targets as FQDN SOCKS addresses. V1 still requires socks5h as canonical/future-proof remote-DNS intent and uniform parser/configuration policy, not because the locked dependency proves different DNS behavior for the two labels.

Generated backend/cmd/server/wire_gen.go and Ent generated files may change only by running the project generators in Phase 1; they must not be hand-edited.

### Account-bound paths not covered by HTTPUpstream

- backend/internal/service/oauth_service.go
- backend/internal/service/openai_oauth_service.go
- backend/internal/service/grok_oauth_service.go
- backend/internal/service/gemini_oauth_service.go
- backend/internal/pkg/antigravity/client.go
- backend/internal/service/antigravity_oauth_service.go
- backend/internal/service/antigravity_quota_fetcher.go
- backend/internal/service/vertex_service_account.go
- backend/internal/service/batch_image_provider_gemini.go
- backend/internal/service/batch_image_provider_vertex.go
- backend/internal/service/admin_proxy.go
- backend/internal/repository/proxy_repo.go
- backend/internal/config/config.go
- backend/internal/service/gateway_forward.go
- backend/internal/service/gateway_upstream_request.go
- backend/internal/service/gateway_count_tokens.go
- backend/internal/pkg/oauth/oauth.go
- backend/internal/pkg/openai/oauth.go
- backend/internal/pkg/xai/oauth.go
- backend/internal/pkg/geminicli/oauth.go
- backend/internal/repository/claude_oauth_service.go
- backend/internal/repository/openai_oauth_service.go
- backend/internal/repository/grok_oauth_client.go
- backend/internal/repository/gemini_oauth_client.go
- backend/internal/repository/req_client_pool.go
- backend/internal/repository/claude_usage_service.go
- backend/internal/service/account_usage_service.go
- backend/internal/service/openai_quota_service.go
- backend/internal/service/openai_agent_identity.go
- backend/internal/service/openai_codex_pat_service.go
- backend/internal/service/openai_codex_models_service.go
- backend/internal/service/openai_ws_client.go
- backend/internal/pkg/proxyurl/parse.go
- backend/internal/pkg/proxyutil/dialer.go
- backend/internal/service/openai_ws_forwarder_ingress.go
- backend/internal/service/openai_ws_forwarder_v2.go
- backend/internal/service/openai_ws_pool.go
- backend/internal/service/openai_ws_v2_passthrough_adapter.go
- backend/internal/service/openai_live.go
- backend/internal/service/account_test_service.go
- backend/internal/pkg/geminicli/drive_client.go
- backend/internal/service/gemini_oauth_service.go

The exact edit subset must be kept minimal during implementation: first centralize route resolution and client construction, then change only callers that cannot pass through the wrapper.

## Planned enforcement order

1. Add the model, repository, validation, and admin CRUD without changing request routing.
2. Add a fail-closed EgressResolver keyed by account ID.
3. Add company-owned runtime RouteHealth with startup preflight, 60-second periodic probes and a 120-second READY TTL. Compile-time Probe A is exactly `https://api.ipify.org?format=json` for IPv4 evidence; Probe B is exactly `https://cloudflare.com/cdn-cgi/trace` for IPv4 plus `loc`. Require exact HTTPS scheme/host/path/query, normal TLS, redirects disabled, bounded timeout/body and no administrator override or upstream-probe fallback. READY requires A.IP == B.IP == expected_exit_ipv4 and B.loc == route.country_code; every error, invalid address or mismatch is immediately UNHEALTHY.
4. Decorate HTTPUpstream.Do and DoWithTLS. Resolve route.proxy_id, require account.proxy_id equality, validate active/non-deleted Proxy state and RouteHealth READY, then derive the effective URL. Missing, stale, unhealthy, inconsistent, or invalid routes return an error.
5. Bind Claude/OpenAI/Grok/Gemini OAuth authorization sessions to egress_route_id plus final proxy_id, and reject callback overrides or drift. Use the same route for exchange and refresh.
6. Route token exchange, refresh, usage/quota, model discovery, connectivity tests, batch Gemini/Vertex operations, Vertex service-account token exchange, and WebSocket handshakes through route-aware factories. Claude usage without a TLS Profile still uses CompanyHTTPUpstream.
7. Disable Grok password authentication in V1. Reject custom_base_url for managed accounts. In company production, allow_direct_on_error=true fails startup.
8. Validate OpenAI/Grok WebSocket final ProxyID against EgressRoute.ProxyID. Go 1.27 net/http supports socks5/socks5h Proxy URLs; the current defect is the raw parser policy bypass. The required chain is `proxyurl.Parse -> proxyutil.ConfigureTransportProxy -> coderws`; direct `url.Parse(proxyURL)` is prohibited.
9. Add the full fail-closed test set, including inactive/soft-deleted Proxy, duplicate route proxy_id, duplicate canonical route endpoint, raw WebSocket parser bypass, exit IP/country mismatch, expired/fingerprint-mismatched RouteHealth, batch-provider direct clients, and production direct-fallback startup failure.
10. Activate in strict order: application tests, staging, sing-box routes, DNS containment, IPv6 deny, nftables UID kill-switch, destructive leak tests, then managed production traffic.

## Required final security tests

- ProxyInactive -> FAIL CLOSED
- ProxySoftDeleted -> FAIL CLOSED
- DuplicateRouteProxyID -> DB/service reject
- WebSocketRawProxyParserBypass -> prohibited; route-aware dialer must use proxyurl.Parse and the approved transport
- ExitIPv4Mismatch -> RouteHealth UNHEALTHY and FAIL CLOSED
- ExitCountryMismatch -> RouteHealth UNHEALTHY and FAIL CLOSED
- RouteHealthExpired -> FAIL CLOSED
- DirectFallbackConfigTrue -> company production startup failure
- DuplicateRouteEndpoint -> DB/service reject two managed Proxy rows that normalize to the same protocol/host/port
- ManagedAntigravity -> UNSUPPORTED and FAIL CLOSED in V1; future support requires a separate V2 route audit
- BatchProviderNoRoute -> Gemini/Vertex batch client creation fails closed instead of using an empty-proxy client or http.DefaultClient

## Compatibility and rollback

- Keep legacy proxy_id during the migration window; EgressRoute is authoritative for every managed account.
- For every managed account, account.proxy_id must equal route.proxy_id.
- Feature switches may disable enforcement only in development/tests. Company production must not continue serving managed traffic with enforcement disabled.
- Do not silently translate a missing EgressRoute into legacy direct access.
- Production rollback deploys a previously approved company binary/version; it does not disable fail-closed enforcement at runtime.
- Existing public APIs remain compatible by adding nullable fields; company policy validation may reject previously accepted unsafe configurations.
- EgressRoute core fields and referenced Proxy records remain locked while referenced.
- A single Sub2API UID cannot let nftables select US versus SG per account. Per-account geography is enforced by immutable EgressDecision and route-aware factories/tests; the host guard only prevents origin/direct/DNS/IPv6 escape. Kernel-level per-country isolation is a future separate-worker/UID/netns V2.
- Managed platform selection is an explicit allowlist. Antigravity and every unlisted account type are UNSUPPORTED and FAIL CLOSED in V1.

## Explicit non-claims

This document does not claim that:

- Sub2API is currently unable to reach the public Internet directly.
- OAuth, refresh, usage, tests, inference, or WebSocket are currently route-enforced.
- DNS is currently contained.
- socks5h alone prevents every local lookup.
- sing-box Guard, nftables, IPv6 deny, or database migrations are deployed.
- the expected exit IP has been verified.
- the real fixed CN-DIRECT, US-A, or SG-A exit IPv4 values have been populated or verified.
- managed Antigravity is supported; it is explicitly UNSUPPORTED in V1.
- runtime RouteHealth exists or is READY.
- route.enabled or dns_addr exists in V1.

Those properties require Phase 1 code, tests, and the separately controlled host enforcement layers.

## Final evidence gate

This planned surface is subordinate to `docs/company/EGRESS_FINAL_EVIDENCE_AUDIT_0.1.183.md`. The architectural evidence gate is resolved by the locked probes and the explicit Antigravity exclusion.

`FINAL DESIGN VERDICT: FREEZE`

`PRODUCTION READINESS: NOT READY`

Phase 1 development may begin after document review, but managed production traffic remains prohibited until fixed exit IP values, sing-box, DNS containment, IPv6 deny, nftables UID kill-switch and destructive leak tests pass.

## Static CI audit gate

Managed account-sensitive production code may not add `http.DefaultClient`, raw `url.Parse(proxyURL)`, empty-ProxyURL clients, direct `net.Dialer`, unapproved resolvers or unapproved account outbound factories unless the exact site is explicitly added to the audited allowlist.
