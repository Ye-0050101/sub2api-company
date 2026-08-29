# Sub2API Company Egress V1 — Final Source Evidence Audit 0.1.183

Audit type: Phase 0.5 final evidence audit, documentation only

Official source authority: `Wei-Shaw/sub2api@e8cb019fabf8b55199436229044cbf9aa7a82564`

Company branch: `company/egress-v1`

Source changes, migrations, generators, deployment and host changes: not performed

## Evidence rules

- **OFFICIAL SOURCE**: directly observed in the fixed Sub2API tree.
- **LOCKED DEPENDENCY**: behavior observed in a version selected by `go.mod`/`go.sum`; supporting evidence, not an upstream guarantee.
- **DESIGN**: proposed company control, not implemented at this baseline.
- **HOST REQUIRED**: application source cannot establish the property.
- **UNKNOWN**: supplied evidence cannot prove the property. A security-sensitive UNKNOWN blocks design freeze.

## Executive verdict

The fixed source proves that account-level deterministic egress is architecturally feasible, but also proves that `HTTPUpstream` is only a partial transport boundary. OAuth, refresh, usage, WebSocket, Vertex service-account token exchange, Antigravity, Gemini/Vertex batch processing and numerous non-account clients construct independent clients. Empty proxy values are direct-capable in multiple production paths.

Four security-sensitive facts remain UNKNOWN:

1. Antigravity exists but has no approved V1 route-class assignment.
2. The two independent HTTPS RouteHealth evidence operators have not been selected and approved.
3. The real fixed public IPv4 values for CN-DIRECT, US-A and SG-A were not supplied or verified.
4. The final host policy and destructive leak tests have not been applied or evidenced.

Application route enforcement and an operating-system UID kill-switch are both required.

## 1. Baseline and tree identity

| Ref | Commit | Tree |
|---|---|---|
| fixed audit commit | `e8cb019fabf8b55199436229044cbf9aa7a82564` | `f08b15f70e98dd19ac3f22cd3ab9cd3957ccd69f` |
| `production-base-0.1.183` | `e8cb019fabf8b55199436229044cbf9aa7a82564` | `f08b15f70e98dd19ac3f22cd3ab9cd3957ccd69f` |
| local `main` at audit time | same audited source tree | `f08b15f70e98dd19ac3f22cd3ab9cd3957ccd69f` |

The commit is `Merge pull request #6078 from Wei-Shaw/codex/fix-multimodal-support-in-responses`. The upstream fetch URL is `https://github.com/Wei-Shaw/sub2api.git`; upstream push is disabled. The audit used the fixed object, not moving upstream main.

Verdict: **PASS DESIGN** for baseline provenance.

## 2. Production network primitive inventory

This inventory excludes `*_test.go`. “Direct-capable” means a path can construct a transport without mandatory EgressRoute; it does not assert every invocation is direct.

### 2.1 `http.DefaultClient`

| Production file | Role | Classification |
|---|---|---|
| `backend/internal/pkg/websearch/brave.go` | Brave search | non-account public outbound |
| `backend/internal/pkg/websearch/tavily.go` | Tavily search | non-account public outbound |
| `backend/internal/repository/grok_oauth_client.go` | Grok password-auth captcha | account-sensitive; disable in V1 |
| `backend/internal/service/batch_image_provider_gemini.go:477` | fallback from failed client construction | account-sensitive batch outbound |
| `backend/internal/service/content_moderation.go` | moderation endpoint | configured non-account outbound |
| `backend/internal/pkg/servertiming/http.go` | generic nil-client fallback | reusable direct-capable helper |

### 2.2 Explicit client and transport families

| Area | Production files | Route relevance |
|---|---|---|
| Central account transport | `repository/http_upstream.go`, `pkg/httpclient/pool.go`, `repository/req_client_pool.go`, `pkg/proxyutil/dialer.go` | partial boundary; empty proxy direct |
| OAuth/token | `repository/claude_oauth_service.go`, `repository/grok_oauth_client.go`, `pkg/xai/sso_device.go`, shared req pool | account-sensitive outside wrapper |
| Realtime | `service/openai_ws_client.go` | account-sensitive WebSocket |
| Google/Vertex/Antigravity | `pkg/antigravity/client.go`, `service/vertex_service_account.go`, `service/batch_image_provider_gemini.go`, `service/batch_image_provider_vertex.go` | account-sensitive independent clients |
| Login OAuth | WeChat, DingTalk, LinuxDo, email OAuth, OIDC handlers and `service/setting_oauth.go` | non-account public/configured |
| Payments/captcha | Airwallex, EasyPay, Turnstile | non-account public |
| Maintenance | GitHub release and pricing services | non-account public/configured |
| Security/search/monitor | prompt security, websearch manager, channel monitor | non-account configured |
| Storage/media | image storage, batch download/provider code | non-account or selected-account data |

Batch evidence is explicit: `NewGeminiAPIBatchImageProvider` calls `NewGeminiBatchHTTPClient("", nil)`; `batchImageDefaultHTTPClient` uses `httpclient.GetClient` with an empty proxy and falls back to `http.DefaultClient`. Vertex batch prediction and GCS stores use the same default client (`batch_image_provider_vertex.go:125-132,737-803`).

### 2.3 Dial, TLS and resolver primitives

| Primitive | Production paths |
|---|---|
| `net.Dialer` | httpclient pool, HTTPUpstream, proxyutil, TLS fingerprint, Antigravity, websearch manager, prompt security, channel monitor, email SMTP |
| TLS dial | `service/email_service.go` uses `tls.DialWithDialer` |
| WebSocket dial | `service/openai_ws_client.go:122` calls `coderws.Dial` |
| explicit resolver | `util/urlvalidator/validator.go:114` uses `LookupIP`; `service/channel_monitor_ssrf.go:97,129` uses `LookupIPAddr` |
| implicit resolver | every direct/default HTTP transport, TCP/SMTP dialer and hostname proxy endpoint |

No project reference to `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` or `NO_PROXY` was found. Go's default transport is environment-proxy aware, so `http.DefaultClient` is still nondeterministic unless replaced with an explicit transport.

Verdict: **NEEDS PATCH** for account paths and **HOST REQUIRED** for process-wide containment.

## 3. Current source-verified call graph

```text
Account
  -> HTTP inference / models / tests / some quota
     -> HTTPUpstream.Do / DoWithTLS
     -> proxyurl.Parse -> proxyutil.ConfigureTransportProxy
        -> non-empty proxy: HTTP/SOCKS
        -> empty proxy: direct net.Dialer

  -> OAuth exchange / refresh / helper calls
     -> raw session.ProxyURL or Account.ProxyID
     -> req_client_pool / httpclient / provider client
        -> empty or ignored lookup failure: direct-capable

  -> usage / quota
     -> mixed HTTPUpstream, httpclient, req and local-only calculations

  -> OpenAI/Grok WebSocket
     -> raw url.Parse(proxyURL) + http.ProxyURL, or nil HTTPClient
     -> coderws.Dial -> dependency default client when nil

  -> Gemini/Vertex batch
     -> independent batch/GCS client
     -> empty-proxy httpclient; error fallback http.DefaultClient

Non-account operation
  -> login OAuth / payments / captcha / SMTP / web search / monitor /
     release / pricing / moderation / storage / infrastructure
  -> independent library or client/dialer, without EgressRoute identity
```

## 4. Platform and operation evidence matrix

| Platform / operation | Current path | Direct/drift condition | Wrapper | Verdict |
|---|---|---|---|---|
| Claude authorization | `oauth_service.go:68-146` | browser URL is not server outbound; cookie/setup automation can be | no | NEEDS PATCH |
| Claude exchange | `oauth_service.go:147`; Claude repository client | callback ProxyID may replace raw session ProxyURL; lookup failure can leave empty | no | NEEDS PATCH |
| Claude refresh | `oauth_service.go:306` | ProxyID lookup failure can become empty | no | NEEDS PATCH |
| Claude usage | Claude usage repository | TLS profile through wrapper; nil profile via httpclient | partial | NEEDS PATCH |
| Claude inference/test | gateway/account test | empty caller proxy is direct | yes | NEEDS PATCH |
| OpenAI authorization/exchange/refresh | `openai_oauth_service.go:45,133,339` | raw session proxy; callback ProxyID/redirect override; empty refresh | no | NEEDS PATCH |
| OpenAI usage/quota | account usage and privacy/quota clients | independent httpclient/req clients | no | NEEDS PATCH |
| OpenAI HTTP inference/test | plugin/gateway/test | empty caller proxy direct | yes | NEEDS PATCH |
| OpenAI realtime/test | `openai_ws_*` | raw parser or nil dependency client | no | NEEDS PATCH |
| Grok OAuth/refresh | `grok_oauth_service.go:68,147,208,311` | raw session proxy, callback override, shared req | no | NEEDS PATCH |
| Grok password/captcha | Grok OAuth repository | captcha uses DefaultClient | no | UNSUPPORTED |
| Grok HTTP quota/media/inference/test | quota/media/gateway/test | empty caller proxy direct | yes | NEEDS PATCH |
| Grok realtime test | account test -> OpenAI WS dialer | separate WS path | no | NEEDS PATCH |
| Gemini OAuth/refresh | `gemini_oauth_service.go:101,445,675,733` | lookup failures; Drive/tier/project helpers | no | NEEDS PATCH |
| Gemini normal quota | account/Gemini quota services | principal calculation local | local | PASS DESIGN only for local calculation |
| Gemini inference/test | gateway/account test | empty caller proxy direct | yes | NEEDS PATCH |
| Gemini batch | batch Gemini provider | empty-proxy client, DefaultClient fallback | no | NEEDS PATCH |
| Vertex token | `vertex_service_account.go:179-250` | empty proxy direct client | no | NEEDS PATCH |
| Vertex batch/GCS | batch Vertex provider | independent empty-proxy client | no | NEEDS PATCH |
| Antigravity OAuth/refresh/quota | Antigravity services/client | own client, empty direct | no | UNKNOWN route class |
| Antigravity inference | gateway -> HTTPUpstream | empty caller proxy direct | yes | UNKNOWN route class |
| DeepSeek/Kimi/Zhipu | CN inference/test/balance/quota principal paths | empty caller proxy direct | yes | NEEDS PATCH |
| Composite | scheduler selects underlying account | must route selected account | indirect | NEEDS PATCH |
| Bedrock/Vertex Anthropic | HTTPUpstream plus Vertex token helper | mixed | partial | NEEDS PATCH |
| Upstream/Ollama Cloud | principal models/usage/inference | empty caller proxy direct | yes | route policy not specified |

The final rows prove that a seven-platform policy table is not a complete account-type enumeration.

## 5. `HTTPUpstream` boundary

`service.HTTPUpstream` is declared in `backend/internal/service/http_upstream_port.go`. `repository.NewHTTPUpstream` is at `repository/http_upstream.go:176` and is provided by repository Wire setup.

- `Do`/`DoWithTLS` carry `accountID`, so a decorator is feasible without changing the interface.
- `normalizeProxyURL` (`http_upstream.go:1206`) calls `proxyurl.Parse`.
- `proxyurl.Parse` (`pkg/proxyurl/parse.go:36`) accepts HTTP/HTTPS/SOCKS5/SOCKS5H, rejects malformed/unsupported non-empty values and normalizes SOCKS5 to SOCKS5H.
- Empty proxy yields nil and the transport retains a direct `net.Dialer`.
- Nil TLS profile delegates to ordinary `Do`; it is not itself a bypass.
- OpenAI H2-to-H1 and Grok target fallback retain the same base proxy transport; they are not network-direct fallbacks.

Wrapper feasibility: **PASS DESIGN**. Wrapper completeness as the sole boundary: **UNSUPPORTED**.

## 6. SOCKS and dependency behavior

Official source proves the project normalizes `socks5` to `socks5h` before approved HTTP transport configuration. The locked `golang.org/x/net v0.56.0` SOCKS implementation sends a hostname target to the SOCKS server when it is not already a literal address. Locked `github.com/coder/websocket v1.8.14` uses an HTTP client for the handshake and a default client when none is supplied.

Those are **LOCKED DEPENDENCY** facts, not substitutes for runtime tests. V1 must:

- require route Proxy protocol exactly `socks5h`;
- require the proxy endpoint to be a canonical literal internal IPv4;
- pass target hostnames without application pre-resolution;
- use `proxyurl.Parse` plus `proxyutil.ConfigureTransportProxy` for WebSocket and HTTP;
- test the built binary for remote target DNS through SOCKS.

Raw `url.Parse(proxyURL)` in `service/openai_ws_client.go:155` is a policy-parser bypass even if the current Go transport understands SOCKS. It does not enforce supported schemes, host presence or normalization.

## 7. Existing Proxy semantics and fallback risk

Official source facts:

- `Proxy.URL()` (`service/proxy.go:42`) only renders a URL; it does not check status, expiry or deletion.
- `IsActive()` and `IsExpired()` are separate (`service/proxy.go:33,38`).
- Ent Proxy records use soft delete; normal queries filter `deleted_at`, but service `Proxy` does not carry `DeletedAt`.
- admin Proxy service permits protocol/host/port/credential/status/expiry/fallback changes.
- delete protection counts account references, not future EgressRoute references.
- `ResolveProxyFallbackTarget` (`service/proxy_fallback.go:12`) can return nil for direct mode. The expiry worker can clear account proxy IDs.

Required route Proxy invariant:

```text
protocol == socks5h
host == canonical literal internal IPv4
username == "" and password == ""
status == active
deleted_at IS NULL
expires_at IS NULL
fallback_mode == none
backup_proxy_id IS NULL
```

`account.proxy_id` must equal `route.proxy_id`. Resolver queries need explicit `deleted_at IS NULL`; `Proxy.URL()` or stale cache is insufficient.

`security.proxy_fallback.allow_direct_on_error=true` is accepted by current configuration and used by release/pricing clients. Company production must fail startup when true; it need not be checked in every resolver request.

Verdict: **NEEDS PATCH**.

## 8. Proposed EgressRoute model validation

```text
EgressRoute
  id
  route_key UNIQUE
  route_class
  country_code
  proxy_id UNIQUE FK -> proxies.id
  expected_exit_ipv4
  notes
  created_at / updated_at / deleted_at

Account additions
  egress_route_id nullable FK
  required_egress_country
  existing proxy_id retained
```

V1 has no `proxy_url`, `enabled` or `dns_addr`. `expected_exit_ipv4` is enforced policy, not metadata.

UNIQUE `proxy_id` prevents one Proxy row belonging to multiple routes but does not prevent two Proxy rows naming the same internal endpoint. Service validation and preferably a database-normalized constraint must reject duplicate managed `(protocol, canonical_host, port)` tuples. Otherwise US-A and SG-A can be cross-labelled while dialing one listener.

While referenced, route core fields and all route-relevant Proxy fields must be immutable. Direct database/admin bypass must invalidate RouteHealth through a policy fingerprint.

Approved supplied mapping:

- Claude/OpenAI/Grok/Gemini -> `INTERNATIONAL_PROXY`.
- DeepSeek/Kimi/Zhipu -> `CN_DIRECT` through local SOCKS5H owned by `sing-box-cn`; Sub2API is never direct.
- Antigravity -> **UNKNOWN**; it exists in source but the policy does not assign it.
- Composite -> selected underlying account.
- Bedrock, Vertex, Upstream and Ollama Cloud variants require explicit mapping, not an implicit default.

Verdict: **NEEDS PATCH** and **UNKNOWN** for incomplete policy.

## 9. Managed custom base URL

Managed V1 must prohibit `custom_base_url`.

This is not only destination hardening. In Anthropic custom-relay mode, `buildCustomRelayURL` (`gateway_upstream_request.go:892`) appends legacy account proxy URL as a `proxy` query parameter. `gateway_upstream_request.go`, `gateway_forward.go` and `gateway_count_tokens.go` deliberately clear local `proxyURL` before calling HTTPUpstream. The Sub2API-to-relay hop is therefore direct-capable and entrusts proxying to the relay.

Required controls:

- reject flag and URL at create, update, clone, import and bulk mutation;
- reject a managed account that already retains either value;
- fail in EgressResolver/request handling as defense in depth;
- never log or forward credentials in a proxy query parameter.

Verdict: **UNSUPPORTED** for managed V1.

## 10. OAuth, refresh and route continuity

Claude/OpenAI/Grok/Gemini sessions persist raw `ProxyURL`, not `EgressRouteID`, final `ProxyID`, route fingerprint or generation. Exchange callbacks can supply a different ProxyID. Several lookup failures are ignored, allowing a previous or empty proxy to survive.

Required design:

1. Authorization start resolves READY EgressDecision and stores route ID, ProxyID, fingerprint and expiry in a signed server session.
2. Browser redirect alone is not server egress; every automatic/cookie helper request is.
3. Callback cannot override proxy. Exchange re-resolves the same route and rejects drift before outbound.
4. Refresh resolves current account route and never accepts caller raw proxy URL.
5. Enrichment/project/tier/privacy helper calls use the same decision.
6. Grok password authentication is disabled in V1.
7. Antigravity receives the same treatment after route class approval.

Verdict: **NEEDS PATCH**. Current OAuth/refresh is not route-consistent.

## 11. RouteHealth final security design

Existing `ProxyExitInfoProber` is not a security authority:

- defaults are plain HTTP ip-api/ipify (`proxy_probe_service.go:66-67`);
- configured targets can replace defaults;
- `ProbeProxy` returns first success;
- ipify supplies no country.

Required company verifier:

- exactly two independently operated, compile-time allowlisted HTTPS endpoints;
- normal TLS verification; redirects disabled or restricted to the exact allowlisted authority;
- bounded deadlines and response size;
- probe through exact validated route Proxy and approved parser/dialer;
- both responses return the same canonical public-unicast IPv4;
- reject IPv6, private, loopback, link-local, multicast and unspecified answers;
- country-bearing response has normalized ISO alpha-2 equal to route country;
- both IPv4 values equal `expected_exit_ipv4`;
- any error or mismatch immediately sets `UNHEALTHY`.

Runtime record:

```text
RouteID, ProxyID
RoutePolicyFingerprint, ProxyEndpointFingerprint
ExpectedIPv4, ExpectedCountry
ActualIPv4, ActualCountry
LastAttempt, LastSuccess, ExpiresAt
Generation, Status(READY|UNHEALTHY), Reason
```

Startup begins UNHEALTHY. Preflight must succeed before managed traffic. Target probe interval is 60 seconds and READY TTL 120 seconds. Any failure invalidates immediately; recovery requires a complete two-endpoint success. Resolver compares current fingerprints to the health record.

This can prevent wrong exit, route/proxy drift and stale health only after endpoint pair and fixed expected IPs are approved. They are currently UNKNOWN.

Verdict: **UNKNOWN**, freeze-blocking.

## 12. TOCTOU and concurrency

A boolean READY cache is insufficient. Decisions must be immutable snapshots from one joined account/route/proxy read with explicit non-deleted predicates and fingerprints. Resolver compares current fingerprints with RouteHealth under lock/atomic snapshot at the last possible point before client construction. The decision, not a re-read raw Proxy URL, goes to the transport.

Required controls:

- atomic immutable health snapshots and per-route probe singleflight;
- generation/fingerprint in cache keys;
- route/Proxy mutation invalidation before the change becomes usable;
- bounded resolver cache or event-driven invalidation;
- account rebind checks `account.proxy_id == route.proxy_id` in the same transaction.

An established connection may finish on a previously valid route after a concurrent administrative change. V1 must define in-flight semantics. Instant revocation requires pool eviction and policy-epoch validation on reuse. Kernel containment still prevents the old connection becoming unrestricted direct.

Verdict: **PASS DESIGN** for versioned snapshots; **NEEDS PATCH** at baseline.

## 13. DNS and IPv6 evidence

Local DNS occurs explicitly in URL validation and channel-monitor SSRF protection, and implicitly in direct/default dial paths. SOCKS target resolution can be remote only if callers preserve hostnames and use the approved dialer. Literal internal proxy IP removes proxy-endpoint DNS but not application SSRF lookups.

No application-wide `tcp4` or IPv6 prohibition exists. Direct Go dialers may use IPv6. Therefore:

- RouteHealth rejects IPv6 evidence;
- route target hostnames are not application-pre-resolved before SOCKS;
- Sub2API UID may query only the approved internal resolver;
- UID is denied arbitrary public IPv4, unintended IPv6 and direct DNS/DoT;
- public DoH is covered by the general public-egress deny.

Verdict: **HOST REQUIRED**. Current local DNS and IPv6 escape are possible.

## 14. Non-account outbound matrix

| Class | Source examples | Destination | Company treatment |
|---|---|---|---|
| User login OAuth | WeChat, DingTalk, LinuxDo, email OAuth, OIDC, setting OAuth | public/configured HTTPS | approved non-account local gateway or disable |
| Payment | Airwallex, EasyPay and other SDKs | public HTTPS | approved gateway; test dependency transports |
| Captcha | Turnstile/provider SDKs | public HTTPS | approved gateway or disable |
| Release/pricing | GitHub release/pricing | public/configured HTTPS | approved gateway or disable; reject direct-on-error |
| Web search | Brave, Tavily, manager | public HTTPS | approved gateway or disable; remove DefaultClient |
| SMTP | email TCP/TLS/STARTTLS | configured host | exact internal relay or approved egress |
| Moderation/security | configured OpenAI-compatible/Qwen endpoints | public/internal | destination allowlist plus approved egress |
| Channel monitor | configured URL, explicit DNS/literal-IP dial | public/internal | narrow allowlist; no broad public direct |
| Image/object storage | download/storage/GCS/S3-compatible | public/internal | approved gateway or exact internal service |
| Proxy diagnostics | current ProxyProber targets | public HTTP | admin diagnostic only, never health evidence |
| PostgreSQL/Redis | infrastructure clients | internal | exact address/port allowlist |

Third-party SDK transports are dependency-mediated and not fully proven by literal primitive search. Host policy must assume direct capability. Broad public IPv4 allowance for non-account traffic would destroy the origin-IP guarantee.

Verdict: **HOST REQUIRED** and **NEEDS PATCH** for explicit non-account factories.

## 15. Host fail-closed boundary

Required deployment boundary, not performed here:

- separate Sub2API and sing-box UIDs;
- allow Sub2API only loopback/local IPC, exact PostgreSQL/Redis/internal dependencies, exact local SOCKS listeners and approved internal DNS;
- deny every other public IPv4 and all unintended IPv6 for Sub2API UID;
- deny direct DNS/DoT except approved resolver;
- public egress belongs only to sing-box UIDs by route purpose;
- AnyTLS/HY2 fallback stays inside sing-box; tunnel/SOCKS failure never becomes application direct;
- destructive tests precede managed activation.

Mandatory order:

```text
application code/tests
-> staging
-> sing-box routes
-> DNS containment
-> IPv6 deny
-> nftables Sub2API UID kill-switch
-> destructive leak tests
-> managed production traffic
```

No ordinary production switch may disable enforcement while service continues. Rollback deploys a previously approved enforcing binary.

## 16. Final evidence matrix

| Property | Official source behavior | Company control | Verdict |
|---|---|---|---|
| deterministic account HTTP | accountID exists; caller proxy may be empty | decorator + resolver | NEEDS PATCH |
| OAuth/refresh continuity | raw session proxy and callback ProxyID | route-bound session/factory | NEEDS PATCH |
| WebSocket policy | raw parser; optional client | company WS dialer | NEEDS PATCH |
| batch Gemini/Vertex | independent empty-proxy client | route-aware factory | NEEDS PATCH |
| Proxy active/deleted | URL ignores state | joined resolver + locks | NEEDS PATCH |
| exit identity | diagnostic prober is weak | dual HTTPS health | UNKNOWN |
| DNS | explicit/implicit resolver paths | app changes + containment | HOST REQUIRED |
| IPv6 | generic `tcp` dialers | UID IPv6 deny | HOST REQUIRED |
| tunnel failure | empty/fallback paths exist | app fail closed + kernel deny | NEEDS PATCH / HOST REQUIRED |
| origin secrecy | many non-account clients | UID kill-switch | HOST REQUIRED |

## 17. Minimum Phase 1 patch set

1. Add EgressRoute/Account persistence through normal generators; never hand-edit generated code.
2. Add route repository, validation, referenced-Proxy locks and duplicate canonical endpoint rejection.
3. Add dual-HTTPS RouteHealth and versioned immutable EgressDecision.
4. Decorate HTTPUpstream while retaining raw upstream transport behind it.
5. Bind Claude/OpenAI/Grok/Gemini OAuth start, exchange, refresh and helpers to one route; disable Grok password auth.
6. Decide Antigravity and other account-type route policy before managed activation.
7. Route Claude no-TLS usage, OpenAI quota/Codex probes, Gemini helpers, Vertex token exchange and Gemini/Vertex batch through company clients.
8. Replace OpenAI/Grok WS raw parsing with `proxyurl.Parse`, approved dialer and final ProxyID validation.
9. Reject managed custom base URL at every mutation/request boundary.
10. Fail production startup when direct fallback is enabled or enforcement disabled.
11. Add CI guards for new DefaultClient, direct clients/dialers, raw proxy parser and resolver primitives.
12. After application tests, implement and destructively verify host boundary in mandatory order.

## 18. Required security tests

Application tests:

`NoRoute`, `RouteClassMismatch`, `CountryMismatch`, `AccountProxyRouteMismatch`, `ProxyInactive`, `ProxyDeleted`, `ProxySoftDeleted`, `ProxyExpired`, `ProxyFallbackDirect`, `ProxyFallbackBackup`, `ProxyCredentialsPresent`, `ProxyHostname`, `ProxyPublicIP`, `ProxyWrongProtocol`, `DuplicateRouteProxyID`, `DuplicateRouteEndpoint`, `ManagedCustomBaseURL`, `OAuthRouteDrift`, `OAuthProxyOverride`, `RefreshRouteDrift`, `ClaudeUsageNoTLS`, `OpenAIWSNoRoute`, `OpenAIWSProxyMismatch`, `OpenAIWSInvalidProxy`, `WebSocketRawProxyParserBypass`, `BatchProviderNoRoute`, `VertexTokenNoRoute`, `AntigravityRouteClassUnknown`, `RouteHealthNoPreflight`, `RouteHealthExpired`, `RouteHealthProxyChanged`, `RouteHealthFingerprintMismatch`, `ExitIPv4Mismatch`, `ExitCountryMismatch`, `ProbeHTTPSRequired`, `ProbeTLSFailure`, `ProbeRedirectRejected`, `ProbeIPDisagreement`, `ProbeIPv6Returned`, `ProbePrivateIPReturned`, `ProbeCountryMissing`, `ProbeCountryMismatch`, `ProbeExpectedIPMismatch`, `ProcessRestartBeforeHealth`, `DirectFallbackConfigTrue`.

Host/staging tests:

`TunnelDown`, `SOCKSDown`, `GuardDown`, `DNSBlocked`, `ExternalDNSDenied`, `IPv6Blocked`, `DirectProviderIPv4Blocked`, `DefaultClientPublicBlocked`, `NonAccountPublicDirectBlocked`, `InternalDBAllowed`, `InternalRedisAllowed`, `ApprovedResolverAllowed`, and restart before health recovery.

## 19. Answers to the fifteen final questions

1. **Can official source support account-level deterministic egress?** Architecturally yes: account identity reaches HTTPUpstream and company factories can be added. Current code does not enforce it. **PASS DESIGN / NEEDS PATCH**.
2. **Which exits can application enforce?** Account HTTP, OAuth/refresh, usage/quota, tests, Vertex/Antigravity/batch clients and WS after all receive EgressDecision and approved client/dialer. **NEEDS PATCH**.
3. **Which exits require host fail-closed?** Future/third-party clients, non-account public clients, local DNS, IPv6, defaults/environment and missed primitives. **HOST REQUIRED**.
4. **Any account-sensitive outbound outside EgressRoute?** Yes: current OAuth/refresh helpers, Claude no-TLS usage, OpenAI usage/privacy, WS, Antigravity, Vertex token exchange and Gemini/Vertex batch. Antigravity class is UNKNOWN. **NEEDS PATCH / UNKNOWN**.
5. **Any empty proxy to direct?** Yes in HTTPUpstream, httpclient/req, WS defaults, Vertex token, Antigravity and batch clients. **NEEDS PATCH**.
6. **Any proxy error to direct fallback?** Yes in legacy fallback/direct mutation and selected client fallbacks; `allow_direct_on_error` is configurable. Parser failures are fail-fast only in some paths. **NEEDS PATCH**.
7. **Any local DNS?** Yes, explicitly in URL/channel validation and implicitly in direct/default dialers. **HOST REQUIRED**.
8. **Any IPv6 escape?** Yes; generic dialers and absence of application/host IPv6 deny leave it possible. **HOST REQUIRED**.
9. **Does RouteHealth prevent wrong exit, port cross-wire, drift and stale health?** The fingerprinted dual-HTTPS design can after duplicate endpoint rejection. Exact endpoints are UNKNOWN and implementation absent. **UNKNOWN**.
10. **Can CN-DIRECT pin China's real fixed public IPv4?** Design can compare it, but real value/live evidence were not supplied. **UNKNOWN**.
11. **Can US-A pin the specified US VPS IPv4?** Architecturally yes; actual value/evidence not supplied. **UNKNOWN**.
12. **Can SG-A pin the specified Singapore VPS IPv4?** Architecturally yes; actual value/evidence not supplied. **UNKNOWN**.
13. **If AnyTLS/HY2/SOCKS/Guard fails, can code return to main-server direct?** Currently yes through empty proxy and legacy direct fallback. Target design and kernel must fail closed. **NEEDS PATCH / HOST REQUIRED**.
14. **After kernel enforcement, can origin-IP theoretically escape?** A correctly verified UID policy blocks ordinary escape, but rules/process identity/tests are absent here. Broad allowlists, another UID, privilege or misclassified dependency remain theoretical. **HOST REQUIRED / UNKNOWN until tested**.
15. **Enough evidence to freeze V1?** No: Antigravity mapping, probe operators, real exit IPs and host evidence remain unresolved. **DO NOT FREEZE**.

## FINAL DESIGN VERDICT

**DO NOT FREEZE**
