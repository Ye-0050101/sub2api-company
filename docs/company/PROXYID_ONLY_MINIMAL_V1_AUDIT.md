# Sub2API Company Egress — ProxyID-Only Minimal V1 Audit

Audit type: Phase 0.5 architecture simplification audit, documentation only

Official source authority: `Wei-Shaw/sub2api@e8cb019fabf8b55199436229044cbf9aa7a82564`

Official tree: `f08b15f70e98dd19ac3f22cd3ab9cd3957ccd69f`

Company branch and pre-audit HEAD: `company/egress-v1@1aca6366351ffe4fa7b160f688e15479bf45e669`

Business source changes, migrations, generators, deployment and host changes: **not performed**

## 1. Executive decision

The V1 `EgressRoute` database model can be removed from the planned implementation. Existing `Account.ProxyID`, the referenced `Proxy`, an immutable company policy keyed by that existing ProxyID, and fail-closed `ManagedProxyHealth` are sufficient to implement the stated account-level egress invariant.

The recommended authority chain is:

```text
company production account classification
  -> Account.ProxyID
  -> existing Proxy row
  -> immutable startup ManagedProxyPolicy[ProxyID]
  -> READY ManagedProxyHealth[ProxyID, fingerprint]
  -> immutable ManagedProxyDecision
  -> approved HTTP / WS / OAuth / Refresh / Usage / Batch factory
```

`EgressRoute` would not add a network boundary. It would duplicate identity and policy state around the same Proxy row, require `Account.ProxyID == EgressRoute.ProxyID` synchronization, and add mutable database, CRUD, frontend and migration surfaces. The application still has to patch exactly the same independent outbound clients, and Linux still has to provide the origin-leak boundary.

This is an architecture verdict, not an implementation claim. At this audited commit, account-sensitive direct-capable paths remain present, `ManagedProxyResolver` and `ManagedProxyHealth` do not exist, and the host kill-switch is not deployed.

`PROXYID-ONLY VERDICT: ADOPT`

`PRODUCTION READINESS: NOT READY`

## 2. Evidence rules and baseline

- **OFFICIAL SOURCE** means directly observed in the fixed official tree.
- **LOCKED DEPENDENCY** means behavior verified for a version selected by the fixed `go.mod`/`go.sum`, not an upstream guarantee.
- **DESIGN** means a required company control that is not implemented at the baseline.
- **HOST REQUIRED** means the application cannot establish the property alone.
- **UNSUPPORTED** means the account or operation must be rejected before any outbound network activity.
- **UNKNOWN** means the fixed source cannot be classified safely. Any account-sensitive UNKNOWN would force this audit to REJECT.

The audited commit subject is `Merge pull request #6078 from YogaSakti/fix/responses-custom-tool-call-id`; its body is `fix(openai): keep restored tool-call item IDs typed`. The audit uses the fixed object and tree, not moving upstream `main`.

Account-sensitive UNKNOWN count within the fixed source and the closed V1 provider policy: **0**. This is possible because Antigravity, Bedrock, Ollama Cloud/upstream variants and any other unlisted account type are explicitly UNSUPPORTED rather than guessed. Future account-sensitive code is not implicitly trusted; it must pass the static audit gate described below.

## 3. Current upstream ProxyID behavior

### 3.1 Existing authority and persistence

Official source already has the required primary relation:

- `backend/ent/schema/account.go` defines nullable `proxy_id` and the Account-to-Proxy edge.
- `backend/internal/service/account.go` exposes `ProxyID *int64` and the loaded `Proxy *Proxy`.
- `backend/internal/repository/account_repo.go` persists, clears, bulk-loads and maps `ProxyID`; account queries preload Proxy records in principal request paths.
- account create, edit, bulk edit, import and OAuth APIs already accept a ProxyID.
- the current frontend account dialogs already expose the existing Proxy selector.

No new account column is required. In particular, ProxyID-only does not need `egress_route_id` or `required_egress_country`; class and expected country are derived from the immutable policy entry for the selected ProxyID.

### 3.2 Existing Proxy is not safe by itself

Official source also proves that a bare `Account.Proxy` or `Proxy.URL()` is insufficient:

- `backend/internal/service/proxy.go`: `Proxy.URL()` renders a URL but does not check status, expiry or deletion. `IsActive()` and `IsExpired()` are separate.
- `backend/ent/schema/proxy.go`: Proxy uses the project soft-delete mixin.
- `backend/internal/repository/proxy_repo.go`: normal `GetByID` is subject to the soft-delete query behavior, while the service `Proxy` value does not carry a `DeletedAt` field.
- `backend/internal/service/admin_proxy.go` and `backend/internal/service/proxy_service.go`: ordinary update paths can modify protocol, endpoint, credentials, status, expiry and fallback fields.
- delete protection currently counts Account references, not a company configuration reference.
- `backend/internal/service/proxy_fallback.go` and the expiry sweep can move an account to a backup or clear ProxyID. Clearing ProxyID is direct-capable under current callers.

Therefore a managed request must freshly resolve and validate the Proxy. It must not trust only a preloaded/stale `Account.Proxy`, a caller-supplied Proxy URL, or successful URL rendering.

### 3.3 Current empty-proxy behavior

- `backend/internal/repository/http_upstream.go`: `normalizeProxyURL("")` returns the direct key and nil Proxy; the transport retains a direct `net.Dialer`.
- `backend/internal/pkg/httpclient/pool.go` and `backend/internal/repository/req_client_pool.go`: empty proxy values construct direct-capable clients.
- `backend/internal/service/openai_ws_client.go`: raw `url.Parse(proxyURL)` is used when a proxy is present; absence can leave the WebSocket dependency using its default client behavior.
- `backend/internal/service/vertex_service_account.go`: missing Account Proxy returns an empty string and `newVertexServiceAccountHTTPClient("")` creates a direct client.
- Gemini/Vertex batch providers have independent empty-proxy/default clients.

For managed production, `ProxyID == nil`, Proxy lookup failure, invalid Proxy, unhealthy Proxy, empty effective URL or client-construction failure must all return an error before dialing. They may never select legacy direct/fallback behavior.

## 4. Managed status must not be inferred from ProxyID presence

The fixed Account schema has no trusted `managed` field. Defining “managed” as “ProxyID is present in managed policy” would be unsafe because removing or omitting ProxyID would silently reclassify the account as unmanaged and restore current direct behavior.

Minimal V1 therefore adopts this server-owned classification:

1. In company production mode, every account whose `(platform, account_type)` is in the supported company allowlist is managed whether ProxyID is present or not.
2. A supported managed account with nil ProxyID fails closed.
3. Antigravity and every unlisted account-sensitive `(platform, account_type)` are UNSUPPORTED and fail before outbound; they do not fall through as “unmanaged.”
4. Composite accounts resolve the selected underlying account and apply that account's classification and ProxyID.
5. OpenAI credential-shadow accounts use the credential-bearing parent. Minimal V1 requires shadow and parent ProxyID equality at mutation and resolution time; a missing or mismatched value fails closed.
6. The raw upstream behavior is retained only for development/test mode and explicitly audited non-account calls. Company production cannot use an ordinary runtime switch to disable enforcement while continuing to serve managed traffic.

This avoids a new database marker and avoids treating client-controlled Account `Extra` as a security authority. If the business later requires managed and unmanaged accounts of the same `(platform, account_type)` in one production process, that is a new architecture requirement and needs an independently protected server-owned marker; it must not be simulated by a nil ProxyID.

## 5. Managed Proxy Policy storage decision

| Option | Source impact | State/identity risk | Upgrade behavior | Decision |
|---|---|---|---|---|
| A. PostgreSQL new table | schema, migration, repository, CRUD and possibly Ent changes | recreates a second mutable policy object beside Proxy | largest fork/rebase surface | REJECT for Minimal V1 |
| B. Company configuration keyed by existing ProxyID | config struct, startup validation and example only | no second Proxy identity; environment policy is immutable for process lifetime | small, isolated and reviewable | **ADOPT** |
| C. Proxy extra/company metadata | current Proxy schema has no Extra/metadata field | requires schema change or unsafe field overloading | conflicts with upstream Proxy evolution | REJECT |
| D. Pure compile-time values | hard-codes environment-specific database IDs and exit IPs into the binary | no runtime identity duplication, but poor deployment portability | every endpoint/IP change requires a binary build | REJECT except for security constants |

The selected design is B: a company configuration block loaded once and validated during startup. Compile-time constants are retained only for provider class rules and the two health evidence endpoints.

Illustrative shape, not a committed public config API:

```yaml
company_egress:
  managed_proxies:
    - proxy_id: 21
      class: INTERNATIONAL_PROXY
      country: US
      expected_exit_ipv4: 203.0.113.10
    - proxy_id: 22
      class: INTERNATIONAL_PROXY
      country: SG
      expected_exit_ipv4: 203.0.113.20
    - proxy_id: 23
      class: CN_DIRECT
      country: CN
      expected_exit_ipv4: 203.0.113.30
```

The example addresses above are documentation placeholders and must not be deployed. Real values are production-readiness inputs.

Startup validation must reject:

- missing/zero/duplicate ProxyID;
- unsupported class or invalid normalized country;
- absent, non-canonical, private or non-IPv4 expected exit address;
- a missing, soft-deleted or invalid referenced Proxy;
- duplicate canonical managed endpoints `(protocol, host, port)` even when Proxy IDs differ;
- platform policy ambiguity;
- `security.proxy_fallback.allow_direct_on_error=true`;
- a company production configuration that disables enforcement.

Configuration is immutable for the process lifetime. A policy change requires reviewed configuration and restart/preflight; administrators cannot change it through the ordinary Proxy UI/API.

## 6. Managed Proxy invariant

Every policy-referenced Proxy must satisfy all of the following on startup, every resolution and every health probe:

```text
protocol == socks5h
host is a canonical literal IPv4 inside 127.0.0.0/8
host is not a hostname, public IP or IPv6 address
username == ""
password == ""
status == active
deleted_at == NULL
expires_at == NULL
fallback_mode == none
backup_proxy_id == NULL
```

Invalid data is not normalized and allowed to continue. It returns a typed fail-closed error. `Proxy.URL()` is called only after these checks.

The ordinary application Proxy update/delete paths must treat every configured managed Proxy as fully read-only in V1. Blocking all route-relevant fields is simpler and safer than allowing mutations followed by asynchronous reprobe. Raw database or stale-cache drift is still covered by a fingerprint mismatch and immediate resolver failure.

## 7. Complete fixed-source ProxyID bypass audit

“Through HTTPUpstream” below means the current call carries `accountID` and can be covered by the thin decorator. It does not mean current source is safe: an empty caller proxy is currently direct-capable.

| Platform / operation | Fixed-source path | Current Proxy behavior | Minimal V1 disposition |
|---|---|---|---|
| Claude inference | gateway -> `HTTPUpstream` | normally uses Account Proxy; empty is direct | decorator resolves Account.ProxyID and overwrites caller value |
| Claude OAuth authorization automation | `service/oauth_service.go` | session stores raw ProxyURL; browser redirect itself is not server outbound | bind selected ProxyID/fingerprint; automatic helper calls use decision |
| Claude code exchange | service + `repository/claude_oauth_service.go` | callback ProxyID can replace session URL; empty/lookup failure is direct-capable | re-resolve selected ProxyID; prohibit callback override |
| Claude refresh | `service/oauth_service.go` + repository client | Account.Proxy lookup failure can become empty | only Account.ProxyID; resolver error stops refresh |
| Claude Usage | `repository/claude_usage_service.go` | TLS-profile branch uses HTTPUpstream; nil-profile branch uses httpclient | both branches use CompanyHTTPUpstream/decision |
| Claude Account Test | `service/account_test_service.go` | HTTPUpstream with caller Account Proxy | decorator fail closed |
| OpenAI/Codex inference | OpenAI gateway -> `HTTPUpstream` | Account Proxy or empty direct | decorator fail closed |
| OpenAI OAuth/exchange/refresh | `service/openai_oauth_service.go`, `repository/openai_oauth_service.go` | raw session URL, callback override and independent req clients | ProxyID-bound session; re-resolve for every outbound |
| OpenAI usage/quota/privacy | `service/account_usage_service.go`, `service/openai_quota_service.go` and helpers | independent httpclient/req clients | decision-aware client factory |
| OpenAI models | `service/openai_codex_models_service.go`, `service/upstream_models.go` | mixed HTTPUpstream/httpclient behavior | resolve Account.ProxyID before discovery |
| OpenAI PAT | `service/openai_codex_pat_service.go` | independent httpclient | decision-aware client; nil is error |
| OpenAI Agent Identity | `service/openai_agent_identity.go` | independent httpclient | decision-aware client; nil is error |
| OpenAI WebSocket/realtime | `service/openai_ws_client.go` and `openai_ws_*` callers | raw URL parser and optional/default client | company WS dialer with immutable decision |
| OpenAI Account Test | account test, including realtime branch | HTTP path through wrapper; realtime through WS family | use matching HTTP or WS decision |
| OpenAI spark shadow | `credential_shadow.go`, WS/usage shadow paths | credentials resolve to parent while selected shadow may carry separate Proxy state | require shadow.ProxyID == parent.ProxyID; decision uses credential-bearing parent |
| Grok inference/quota/media | Grok services -> HTTPUpstream | Account Proxy or empty direct | decorator fail closed |
| Grok OAuth/refresh | `service/grok_oauth_service.go`, `repository/grok_oauth_client.go` | raw session/callback Proxy behavior and shared req client | ProxyID-bound session and decision-aware factory |
| Grok WebSocket/realtime test | OpenAI-compatible WS family | outside HTTPUpstream | company WS dialer |
| Grok captcha/password auth | Grok OAuth repository | captcha uses `http.DefaultClient` | managed password auth UNSUPPORTED; reject before captcha/network |
| Gemini inference | Gemini gateway -> HTTPUpstream | Account Proxy or empty direct | decorator fail closed |
| Gemini OAuth/refresh | `service/gemini_oauth_service.go`, `repository/gemini_oauth_client.go` | raw session/callback/lookup paths | ProxyID-bound session; no raw override |
| Gemini Drive | `pkg/geminicli/drive_client.go` | independent httpclient | decision-aware client |
| Gemini project/tier helpers | Gemini OAuth/service helpers | independent httpclient | same immutable decision as exchange/refresh |
| Gemini Account Test | account test -> HTTPUpstream | empty caller proxy direct | decorator fail closed |
| Gemini Batch | `batch_image_provider_gemini.go` | `NewGeminiBatchHTTPClient("", nil)` and DefaultClient fallback | job already has AccountID; provider resolves decision before every provider call; no fallback |
| Vertex service-account token | `service/vertex_service_account.go` | missing Account Proxy creates direct client | Gemini `service_account` is managed INTERNATIONAL; decision is mandatory |
| Vertex Batch/GCS | `batch_image_provider_vertex.go` | independent default client for token/API/GCS | existing job AccountID selects one decision for token, API and GCS |
| DeepSeek inference/balance/test | CN gateway/account services -> HTTPUpstream | empty caller proxy direct | supported account must resolve CN_DIRECT |
| Kimi inference/balance/quota/test | CN gateway/quota/account services -> HTTPUpstream | empty caller proxy direct | supported account must resolve CN_DIRECT |
| Zhipu inference/balance/quota/test | CN gateway/quota/account services -> HTTPUpstream | empty caller proxy direct | supported account must resolve CN_DIRECT |
| Antigravity OAuth/refresh/quota/inference/test | Antigravity service/client family | own clients plus HTTPUpstream; empty can be direct | **UNSUPPORTED**; reject at each dispatcher before outbound |
| Composite | scheduler selects an underlying account | composite itself is not the credential/network identity | resolve selected underlying account only |
| Bedrock, Ollama Cloud, generic upstream or other type | mixed provider-specific paths | route policy not supplied by the business requirement | **UNSUPPORTED** by default; separate audit required |

### 7.1 Direct-capable primitive summary

The fixed source contains production `http.DefaultClient`, explicit `http.Client{}`, `net.Dialer`, WebSocket dial, TLS dial and resolver paths. Account-sensitive members are the OAuth/refresh helpers, Grok password/captcha, Claude no-TLS Usage, OpenAI quota/privacy/PAT/identity/models, OpenAI/Grok WS, Vertex token exchange and Gemini/Vertex batch/GCS families described above. Non-account members include login OAuth, payment/captcha, release/pricing, web search, SMTP, moderation/security, channel monitor, storage and infrastructure clients.

ProxyID-only does not reduce this closure requirement. The account-sensitive paths must receive a decision or reject; non-account paths remain subject to an explicit destination/client allowlist and the Linux UID boundary.

### 7.2 SOCKS and DNS evidence

Locked `golang.org/x/net v0.56.0` sends both `socks5` and `socks5h` through the same SOCKS5 dialer. Its internal SOCKS implementation encodes hostname targets as FQDN SOCKS addresses, so the hostname is sent to the SOCKS server. V1 still requires the literal policy string `socks5h` for canonical company semantics and future-proof explicit remote-DNS intent, not because the locked dependency proves different DNS behavior for the two labels.

Go 1.27 `net/http.Transport` supports `socks5`/`socks5h` Proxy URLs. The WebSocket risk in the fixed source is the raw project-policy parser bypass, not absent Go SOCKS support.

## 8. Minimal ManagedProxyResolver

Proposed service boundary:

```text
ResolveForAccount(ctx, accountID) -> immutable ManagedProxyDecision
ResolveForProxyID(ctx, proxyID, intendedPlatform, intendedAccountType)
  -> immutable ManagedProxyDecision  // OAuth before Account creation only
```

`ResolveForAccount` performs, in order:

1. load Account and reject missing/deleted state;
2. classify `(platform, account_type)` using the closed company production policy;
3. reject Antigravity or every unlisted account type before outbound;
4. for composite/shadow, resolve the effective underlying/credential-bearing account and enforce ProxyID equality rules;
5. require `Account.ProxyID != nil`;
6. load the exact ProxyID through a non-deleted repository query;
7. find exactly one immutable policy entry for that ProxyID;
8. validate every Proxy invariant and provider class rule;
9. derive and compare the current policy/Proxy fingerprint;
10. require unexpired READY health for the same `(ProxyID, fingerprint)`;
11. render and parse the non-empty effective Proxy URL through `proxyurl.Parse`;
12. return one immutable snapshot.

Minimal decision:

```text
AccountID
EffectiveAccountID
ProxyID
ProxyURL
ProxyClass
Country
ExpectedExitIPv4
PolicyFingerprint
HealthEpoch
```

`PolicyFingerprint` is necessary even with application-level read-only enforcement because out-of-band database changes, stale objects and process configuration drift still exist. A separate database generation is not necessary. The fingerprint covers ProxyID, protocol, canonical host/port, credential presence/value hash, status, expiry, fallback mode, backup ID, configured class/country/expected IPv4 and the immutable policy version. Secrets are hashed and never logged. `HealthEpoch` is runtime-only and permits pool/cache invalidation after failure or successful reprobe.

No resolver result may contain an empty URL. Resolver errors are terminal for the managed operation.

## 9. CompanyHTTPUpstream remains useful but thin

The current `service.HTTPUpstream` interface already carries `accountID`. A decorator remains the lowest-conflict way to cover inference, many tests and many balance/quota paths:

```text
managed accountID
  -> ResolveForAccount(accountID)
  -> ignore/overwrite caller proxyURL
  -> delegate to raw HTTPUpstream with decision.ProxyURL

unsupported or resolver failure
  -> return error; never call raw HTTPUpstream

explicitly audited unmanaged/non-account path
  -> preserve raw upstream behavior
```

Both `Do` and `DoWithTLS` follow this rule. A nil TLS profile still goes through the decorator. The decorator does not query an EgressRoute, compare two Proxy IDs or read a route table.

The raw HTTPUpstream is not exported as an alternative dependency to account-sensitive services. Wire provides the decorator as the normal `service.HTTPUpstream`; only the decorator owns the raw implementation. Calls with absent/zero account identity require an explicit audit allowlist rather than silently being treated as managed account traffic.

CompanyHTTPUpstream is an HTTP defense layer, not the only security boundary. Independent OAuth, WebSocket, Batch, Vertex and helper clients still need company factories.

## 10. WebSocket design

Required managed handshake:

```text
AccountID
  -> ManagedProxyResolver
  -> immutable ManagedProxyDecision
  -> proxyurl.Parse(decision.ProxyURL)
  -> proxyutil.ConfigureTransportProxy(cloned explicit transport, parsed Proxy)
  -> explicit http.Client
  -> coderws
```

Prohibited managed paths:

- raw `url.Parse(proxyURL)`;
- caller-provided ProxyURL as authority;
- empty ProxyURL;
- nil/default WebSocket HTTP client;
- ProxyID lookup failure followed by a dial;
- pool reuse whose ProxyID/fingerprint/health epoch differs from the decision.

OpenAI and Grok realtime/account tests use the same company dialer. WS pool keys include ProxyID, policy fingerprint and health epoch. A health transition to UNHEALTHY prevents new handshakes and evicts reusable idle connections; in-flight connection revocation semantics are documented separately, while the host boundary prevents an old connection from turning into unrestricted direct egress.

## 11. OAuth and refresh continuity

OAuth start can occur before an Account exists, so it uses the narrow `ResolveForProxyID` entry point with the intended platform/account type. The server session stores:

```text
ProxyID
PolicyFingerprint
session expiry / normal OAuth state
```

It does not store a raw ProxyURL or EgressRouteID as authority.

Exchange must re-resolve the session ProxyID immediately before outbound and require it to equal the final selected/new Account ProxyID. Callback ProxyID/ProxyURL overrides are rejected. Every exchange helper (privacy, project, tier, Drive or equivalent) uses that one decision.

Refresh loads only the current Account.ProxyID and obtains a new decision. It never trusts a previous raw URL, callback override or ignored Proxy lookup error. Claude, OpenAI, Grok and Gemini follow the same pattern. Grok password authentication is disabled for managed V1.

## 12. Gemini, Vertex and Batch

The fixed Batch job already stores `AccountID`, and processor/download/cleanup paths resolve that account. No migration is required to bind Batch outbound to ProxyID.

Minimal implementation injects ManagedProxyResolver into the Gemini and Vertex providers. Each provider operation resolves the job AccountID and uses one decision for all related calls. Gemini may not call `NewGeminiBatchHTTPClient("", nil)`; construction failure may not fall back to `http.DefaultClient`. Vertex service-account token exchange, Vertex API and GCS upload/download all use the same decision. Nil AccountID, nil ProxyID or an unsupported account type fails before provider client construction.

## 13. Provider policy

The policy is a closed compile-time platform/account-type matrix combined with environment-specific ProxyID entries:

| Account family | Permitted Proxy class | Notes |
|---|---|---|
| Anthropic Claude OAuth/setup-token/API key | INTERNATIONAL_PROXY | country may be US or SG according to selected ProxyID |
| OpenAI/Codex supported OAuth/setup-token/API-key modes | INTERNATIONAL_PROXY | spark shadow must match parent ProxyID |
| Grok OAuth/API key | INTERNATIONAL_PROXY | password/captcha mode unsupported |
| Gemini OAuth/API key/service_account (Vertex) | INTERNATIONAL_PROXY | token, Drive, tier/project and Batch use same decision |
| DeepSeek supported API key/upstream mode | CN_DIRECT | configured country must be CN |
| Kimi supported API key/upstream mode | CN_DIRECT | configured country must be CN |
| Zhipu supported API key/upstream mode | CN_DIRECT | configured country must be CN |
| Composite | selected underlying account's rule | composite is not a dial identity |
| Antigravity | none | UNSUPPORTED / FAIL CLOSED |
| Bedrock, Ollama Cloud, generic upstream and every unlisted pair | none | UNSUPPORTED until separate audit |

`CN_DIRECT` still means Sub2API -> internal SOCKS5H -> `sing-box-cn` -> server public egress. It never means the Sub2API process dials the public provider directly. Its configured country is CN and its real fixed public IPv4 must be populated and verified before READY.

## 14. ManagedProxyHealth

Health is keyed by `(ProxyID, PolicyFingerprint)`, not by an EgressRoute identity. All accounts sharing a ProxyID share the same health evidence.

Locked evidence endpoints:

- Probe A: exact `https://api.ipify.org?format=json`, IPv4 evidence only.
- Probe B: exact `https://cloudflare.com/cdn-cgi/trace`, IPv4 plus `loc` CountryCode evidence.

Both endpoints are compile-time allowlist constants with exact HTTPS scheme, hostname, path and query where present, normal TLS verification, redirects disabled, bounded timeout and bounded body. Administrators cannot change them, and there is no fallback to the upstream default HTTP probe configuration.

Each probe uses the exact validated ProxyID and approved parser/transport. READY requires:

```text
A.IP == B.IP
A.IP == policy.expected_exit_ipv4
B.loc == policy.country
A.IP/B.IP are the same canonical public IPv4
health fingerprint == current Proxy/policy fingerprint
now < health expiry
```

TLS failure, redirect, parse failure, IPv6, private/non-public IP, missing loc, disagreement, IP mismatch, country mismatch or fingerprint drift sets UNHEALTHY immediately. Startup begins UNHEALTHY; a complete two-probe preflight is required before managed traffic. The frozen target cadence remains a 60-second probe interval and 120-second READY TTL. Any failed attempt invalidates readiness immediately; recovery requires a complete two-endpoint success.

A database generation/route-specific object is unnecessary. An immutable fingerprint plus runtime health epoch is enough because managed Proxy and policy are application-read-only and configuration is restart-bound.

## 15. Linux final security boundary

The application chooses the correct localhost listener. The host prevents origin escape.

Required Sub2API UID policy:

- allow exact localhost managed SOCKS endpoints;
- allow exact PostgreSQL, Redis, approved DNS and required internal services;
- deny arbitrary public IPv4 from the Sub2API UID;
- deny unintended public IPv6;
- deny external DNS/DoT and cover public DoH with the general public-egress deny;
- keep AnyTLS/HY2 fallback inside sing-box; tunnel/SOCKS failure never permits Sub2API direct fallback.

A single Linux UID cannot know Account identity. It can block origin-IP, IPv6 and DNS leakage, but it cannot enforce “US account -> only US SOCKS” when US and SG loopback listeners are both allowed. Geographic selection remains the application invariant:

```text
Account.ProxyID
+ ManagedProxyPolicy
+ immutable ManagedProxyDecision
+ route-aware HTTP/WS/OAuth/Refresh/Usage/Batch factories
+ tests and static CI
```

Kernel-level per-country/account isolation would require separate workers/UIDs/network namespaces and is outside Minimal V1.

Activation order remains mandatory:

```text
application code and tests
-> staging
-> sing-box routes
-> DNS containment
-> IPv6 deny
-> nftables Sub2API UID kill-switch
-> destructive leak tests
-> managed production traffic
```

## 16. EgressRoute V1 versus ProxyID-only Minimal V1

Counts below compare the current frozen `COMPANY_PATCHSET.md` plan with this audit's planned surface; they are architecture counts, not implemented diffs. The frozen plan names 59 existing files and 13 new company files, of which 8 are Go, 2 SQL and 3 frontend. ProxyID-only removes route persistence/UI work but retains the common outbound-bypass closure work.

| Dimension | EgressRoute V1 | ProxyID-only Minimal V1 |
|---|---:|---:|
| new database tables | 1 | 0 |
| new Account fields | 2 | 0 |
| migration files | 2 (one up/down pair) | 0 |
| planned new company Go files | 8 | 5 |
| planned new frontend files | 3 | 0 |
| named existing-file candidates | 59 | 50 maximum production/config/wiring candidates in the audit list below; centralization should reduce the final touched subset |
| frontend mandatory changes | new route page, API, select and account DTO work | 0; current Proxy selector is reusable |
| authority synchronization | Account.ProxyID, Account.EgressRouteID, Route.ProxyID, country and route health | Account.ProxyID, immutable policy lookup and Proxy health |
| database/CRUD TOCTOU | account + route + proxy + route health | account + proxy + immutable config + proxy health |
| upgrade conflict risk | high: Ent schema/generated code, migration, admin routes/UI | lower: reuses upstream Account/Proxy and isolates company factories |
| runtime object identity | Account, Route, Proxy, RouteHealth | Account, Proxy, policy value, ManagedProxyHealth |
| account-sensitive outbound patches | required | equally required |
| tests | route CRUD/FK/synchronization plus network tests | proxy policy/health/network tests only |
| account-per-proxy | yes | yes |
| fixed exit verification | yes, through RouteHealth | yes, through ManagedProxyHealth |
| fail closed | only after resolver/client/host patches | only after the same resolver/client/host patches |
| OAuth/WS consistency | requires separate patches | requires the same separate patches |
| DNS/IPv6 origin containment | host required | host required |

### What security capability does EgressRoute add?

No material V1 network-security capability that ProxyID-only cannot provide. EgressRoute adds database discoverability, mutable route administration, possible history/audit semantics and a named route identity. Those are governance/product features, not proof that bytes use the correct SOCKS endpoint. The byte-level guarantees still come from a validated Proxy, immutable decision, health evidence, patched client factories and host containment.

For the stated requirement—admins choose an existing ProxyID per account, same-country accounts may share it, and policy is reviewed configuration—those governance features do not justify a second identity and synchronization surface.

## 17. Exact planned patch surface

This is a Phase 1 plan only. No listed file is modified by this audit.

### 17.1 New company-owned Go files (5)

- `backend/internal/service/managed_proxy.go` — interfaces, policy/decision/error types.
- `backend/internal/repository/company_managed_proxy_resolver.go` — Account/Proxy resolution and invariant checks.
- `backend/internal/repository/company_http_upstream.go` — thin HTTPUpstream decorator.
- `backend/internal/repository/company_managed_proxy_health.go` — locked dual-HTTPS probes and runtime health.
- `backend/internal/repository/company_ws_dialer.go` — approved decision-aware WebSocket transport.

### 17.2 MUST MODIFY: existing production/config/wiring candidates (50)

Core configuration, lifecycle, account mutation and DI:

- `backend/internal/config/config.go`
- `deploy/config.example.yaml`
- `backend/internal/service/admin_proxy.go`
- `backend/internal/service/proxy_service.go`
- `backend/internal/service/admin_account.go`
- `backend/internal/service/admin_service.go`
- `backend/internal/handler/admin/account_handler.go`
- `backend/internal/handler/admin/account_codex_import.go`
- `backend/internal/handler/admin/account_data.go`
- `backend/internal/repository/wire.go`
- `backend/internal/service/wire.go`
- `backend/cmd/server/wire.go`
- `backend/cmd/server/wire_gen.go` (generated in Phase 1, never hand-edited)

OAuth and refresh session/client boundaries:

- `backend/internal/service/oauth_service.go`
- `backend/internal/service/openai_oauth_service.go`
- `backend/internal/service/grok_oauth_service.go`
- `backend/internal/service/gemini_oauth_service.go`
- `backend/internal/service/token_refresh_service.go`
- `backend/internal/pkg/oauth/oauth.go`
- `backend/internal/pkg/openai/oauth.go`
- `backend/internal/pkg/xai/oauth.go`
- `backend/internal/pkg/geminicli/oauth.go`
- `backend/internal/repository/claude_oauth_service.go`
- `backend/internal/repository/openai_oauth_service.go`
- `backend/internal/repository/grok_oauth_client.go`
- `backend/internal/repository/gemini_oauth_client.go`

Usage, quota, models, identity, Vertex and account tests:

- `backend/internal/repository/claude_usage_service.go`
- `backend/internal/service/account_usage_service.go`
- `backend/internal/service/openai_quota_service.go`
- `backend/internal/service/openai_agent_identity.go`
- `backend/internal/service/openai_codex_pat_service.go`
- `backend/internal/service/openai_codex_models_service.go`
- `backend/internal/pkg/geminicli/drive_client.go`
- `backend/internal/service/vertex_service_account.go`
- `backend/internal/service/account_test_service.go`
- `backend/internal/service/upstream_models.go`

WebSocket/realtime:

- `backend/internal/service/openai_ws_client.go`
- `backend/internal/service/openai_ws_forwarder_ingress.go`
- `backend/internal/service/openai_ws_forwarder_v2.go`
- `backend/internal/service/openai_ws_pool.go`
- `backend/internal/service/openai_ws_v2_passthrough_adapter.go`
- `backend/internal/service/openai_live.go`
- `backend/internal/service/openai_ws_http_bridge.go`
- `backend/internal/service/openai_ws_forwarder_support.go`

Batch and Antigravity rejection boundaries:

- `backend/internal/service/batch_image_provider_gemini.go`
- `backend/internal/service/batch_image_provider_vertex.go`
- `backend/internal/service/antigravity_gateway_service.go`
- `backend/internal/service/antigravity_oauth_service.go`
- `backend/internal/service/antigravity_token_refresher.go`
- `backend/internal/service/antigravity_quota_fetcher.go`

The list is deliberately an upper bound at source-file granularity: if the new central boundary preserves an existing caller interface, that caller should remain unmodified. Phase 1 may shrink this set, but it may not omit a bypass category or add a new account-sensitive factory without updating the audit.

### 17.3 MAY MODIFY

- existing Proxy/account frontend components, only to display a “company managed/read-only” badge or filter invalid choices; no new route page/select is required;
- `backend/internal/repository/account_repo.go`, only if Phase 1 chooses a single joined read rather than fresh Account and Proxy repository reads;
- `backend/internal/repository/req_client_pool.go`, only if a typed decision-aware factory cannot safely wrap it;
- `backend/internal/repository/http_upstream.go`, only for construction visibility needed to prevent raw implementation injection;
- existing test files, plus narrowly named company tests and a static CI script/workflow.

`backend/internal/pkg/proxyurl/parse.go` and `backend/internal/pkg/proxyutil/dialer.go` should normally remain unchanged and be reused. The current locked behavior already supplies the approved parser and transport configuration primitives.

### 17.4 NO LONGER NEEDED

All planned EgressRoute persistence, CRUD and frontend files are cancelled for Minimal V1:

- `backend/ent/schema/egress_route.go`
- `backend/internal/service/egress_route.go`
- `backend/internal/repository/egress_route_repo.go`
- `backend/internal/handler/admin/egress_route_handler.go`
- `backend/migrations/900000_company_egress_routes.up.sql`
- `backend/migrations/900000_company_egress_routes.down.sql`
- `frontend/src/views/admin/EgressRoutesView.vue`
- `frontend/src/components/account/EgressRouteSelect.vue`
- `frontend/src/api/admin/egress-routes.ts`

Also cancelled:

- Account `egress_route_id` and `required_egress_country` schema/domain/API/frontend edits;
- EgressRoute admin routes and Wire providers;
- route_key, route CRUD, route immutability and route-specific fingerprint/health;
- Account.ProxyID-to-Route.ProxyID synchronization and DuplicateRouteProxyID tests.

The common company files are renamed/simplified from `company_egress_*` to `company_managed_proxy_*`; CompanyHTTPUpstream and company WS dialer remain because they close real transport paths, not because a route table exists.

## 18. Upgrade and compatibility assessment

ProxyID-only is materially easier to rebase onto future Sub2API releases:

- it preserves upstream Account/Proxy schema and generated Ent code;
- it reuses existing account Proxy selectors, DTOs and repository mappings;
- it reuses `proxyurl`, `proxyutil` and the HTTPUpstream port;
- company-specific policy/health/resolver code is isolated in five files and configuration;
- it avoids migration ordering, route CRUD compatibility and dual-state backfill/rollback;
- rollback is a company binary/config rollback, not a database downgrade.

Compatibility cost remains at real outbound call sites. Upstream additions to OAuth, usage, WebSocket, batch or account factories can reintroduce direct capability, so the lower fork weight does not permit weaker CI. Every upstream sync must rerun the production primitive scan and provider matrix tests.

## 19. Security regression analysis and required tests

ProxyID-only removes dual-state mismatch classes but introduces reliance on correct immutable configuration and managed-account classification. Required tests include:

```text
ManagedAccountProxyNil
ManagedAccountProxyPolicyMissing
ManagedClassificationCannotBeBypassedByNilProxy
UnsupportedAccountType
ManagedAntigravityUnsupported
CompositeUsesSelectedAccount
ShadowParentProxyMismatch
ProxyNotFound
ProxyInactive
ProxySoftDeleted
ProxyExpired
ProxyFallbackDirect
ProxyFallbackBackup
ProxyCredentialsPresent
ProxyHostname
ProxyPublicIP
ProxyIPv6
ProxyWrongProtocol
DuplicateManagedProxyEndpoint
ManagedProxyReadOnlyUpdate
ManagedProxyDelete
ManagedCustomBaseURL
ProviderClassMismatch
ProviderCountryMismatch
OAuthProxyOverride
OAuthPolicyFingerprintDrift
RefreshUsesCurrentAccountProxyID
ClaudeUsageNoTLS
OpenAIPATNoProxy
OpenAIAgentIdentityNoProxy
OpenAIWSNoProxy
OpenAIWSRawProxyParserBypass
OpenAIWSPoolFingerprintMismatch
GrokPasswordAuthUnsupported
GeminiDriveNoProxy
GeminiBatchNoAccount
GeminiBatchNoProxy
GeminiBatchDefaultClientFallback
VertexTokenNoProxy
VertexBatchOrGCSNoProxy
ManagedProxyHealthNoPreflight
ManagedProxyHealthExpired
ManagedProxyFingerprintMismatch
ExitIPv4Mismatch
ExitCountryMismatch
ProbeTLSFailure
ProbeRedirectRejected
ProbeParseFailure
ProbeIPDisagreement
ProbeIPv6Returned
ProbePrivateIPReturned
ProbeCountryMissing
DirectFallbackConfigTrue
ProductionEnforcementDisabled
CIUnapprovedDefaultClient
CIEmptyProxyClient
CIUnapprovedResolver
CIUnapprovedOutboundFactory
```

Static CI must reject new managed account-sensitive production uses of:

- `http.DefaultClient`;
- raw `url.Parse(proxyURL)`;
- an empty-ProxyURL client;
- direct `net.Dialer`;
- an unapproved resolver;
- an unapproved account outbound factory;

unless the exact site is placed on a reviewed audit allowlist. The allowlist is deny-by-default and source-location-specific.

Host/staging leak tests remain: `TunnelDown`, `SOCKSDown`, `GuardDown`, `ExternalDNSDenied`, `IPv6Blocked`, `DirectProviderIPv4Blocked`, `DefaultClientPublicBlocked`, `NonAccountPublicDirectBlocked`, and positive tests for the exact internal dependencies/resolver/listeners.

## 20. Ten adoption conditions

| Condition | Can ProxyID-only satisfy it? | Fixed-source/design evidence |
|---|---|---|
| managed Account ProxyID mandatory | yes | classification is independent of ProxyID presence; nil is error |
| all account-sensitive outbound forced through ProxyID | yes after patch | complete matrix is classified; unsupported paths reject |
| nil Proxy cannot become direct | yes after patch | resolver never returns empty; decorator/factories stop |
| Proxy error cannot fallback direct | yes after patch | managed Proxy requires fallback none; production direct fallback fails startup |
| WS uses unified parser/dialer | yes after patch | approved chain uses proxyurl + proxyutil + explicit coderws client |
| OAuth/refresh cannot drift | yes after patch | session ProxyID/fingerprint and current Account ProxyID are revalidated |
| Batch/Vertex cannot dial independently | yes after patch | existing Batch AccountID and decision-aware provider factories |
| fixed country/IP policy | yes | immutable config keyed by existing ProxyID |
| health fail closed | yes after patch | `(ProxyID, fingerprint)` dual-HTTPS evidence and TTL |
| Linux UID blocks origin leak | yes as host control | required activation gate; not yet deployed/tested |

All ten are structurally achievable without EgressRoute. None is implemented by this document, and managed production remains forbidden until both the application and host gates pass.

## 21. Supersession plan

If this audit is accepted, the next documentation-only step should mark the EgressRoute-specific design in these existing files as `SUPERSEDED BY docs/company/PROXYID_ONLY_MINIMAL_V1_AUDIT.md`:

- `COMPANY_EGRESS_V1_SPEC.md`
- `COMPANY_PATCHSET.md`
- `docs/company/EGRESS_SOURCE_AUDIT_0.1.183.md`
- `docs/company/EGRESS_FINAL_EVIDENCE_AUDIT_0.1.183.md`

They are retained as historical evidence and are not deleted or modified in this audit.

## PROXYID-ONLY VERDICT

**ADOPT**

Reason: for the fixed official source and the closed V1 provider allowlist, EgressRoute adds state and upgrade conflict but no security property beyond what existing Account.ProxyID, strict Proxy policy, immutable decision, ProxyID-keyed health, complete client-factory closure and the host kill-switch can enforce. Account-sensitive UNKNOWN count is zero because every unlisted type is fail-closed rather than inferred.

## PRODUCTION READINESS

**NOT READY**

Phase 1 implementation, tests, real exit IPv4 configuration, sing-box deployment, DNS containment, IPv6 deny, nftables UID kill-switch and destructive leak tests are still pending.
