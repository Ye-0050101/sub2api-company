# Egress Source Audit 0.1.183

## 审计对象

- commit：`e8cb019fabf8b55199436229044cbf9aa7a82564`
- tree：`f08b15f70e98dd19ac3f22cd3ab9cd3957ccd69f`
- 只以该 commit 源码为证据，不使用 upstream 最新 main 推测

## A. 当前真实网络调用图

```text
Inference/Test/most quota
  Account -> ProxyID/Proxy -> caller proxyURL -> HTTPUpstream

Company patch
  AccountID -> ManagedProxyResolver
  -> supported platform/type
  -> official base URL + exact destination
  -> ProxyID policy + current Proxy invariants
  -> ManagedProxyHealth READY
  -> CompanyHTTPUpstream
  -> proxyurl.Parse/proxyutil
  -> local socks5h

Independent paths
  OAuth/Refresh -> provider-specific clients
  OpenAI/Grok realtime -> coderws
  Claude Usage -> TLS/non-TLS variants
  OpenAI quota/privacy -> req client pool
  Antigravity/Vertex/Batch/etc. -> independent clients
```

结论：官方 `HTTPUpstream` 是主路径但不是唯一出口；company patch 必须覆盖独立路径并对 unsupported 功能前置拒绝。

## B. 平台出口矩阵

| 平台 | Inference | OAuth/Exchange | Refresh | Usage/Quota | Test | WS |
|---|---|---|---|---|---|---|
| Claude | CompanyHTTPUpstream | route-aware Claude client | account route | CompanyHTTPUpstream，含 nil TLS profile | CompanyHTTPUpstream | N/A |
| OpenAI/Codex | CompanyHTTPUpstream；models/Agent Identity 独立 client 先解析 route | session ProxyID + route；PAT 校验先解析 ProxyID | account route | resolver + quota/privacy client | CompanyHTTPUpstream | route-aware parser/transport/coderws |
| Grok | CompanyHTTPUpstream | fixed endpoint + route | account route | CompanyHTTPUpstream | HTTP/route-aware realtime | route-aware parser/transport/coderws |
| Gemini ordinary | CompanyHTTPUpstream | session ProxyID + route | account route | local quota或 route-aware Drive/Code Assist | CompanyHTTPUpstream | N/A |
| DeepSeek/Kimi/Zhipu | CompanyHTTPUpstream / CN_DIRECT | N/A | N/A | CompanyHTTPUpstream | CompanyHTTPUpstream | N/A |
| Antigravity | UNSUPPORTED | production provider 前置拒绝 | 前置拒绝 | Account Usage resolver 前置拒绝 | CompanyHTTPUpstream resolver 拒绝 | N/A |
| Vertex/Bedrock/Upstream/Ollama | resolver/type/base URL 拒绝 | UNSUPPORTED | UNSUPPORTED | UNSUPPORTED | UNSUPPORTED | UNSUPPORTED |
| Gemini/Vertex Batch | enforcement 启动时禁用 | N/A | N/A | N/A | N/A | N/A |

## C. Direct-capable production code

源码扫描仍存在下列通用/非托管网络原语：

- `http.DefaultClient`
  - `internal/pkg/websearch/tavily.go`
  - `internal/pkg/websearch/brave.go`
  - `internal/pkg/servertiming/http.go`
  - `internal/repository/grok_oauth_client.go` 的 YesCaptcha 路径
  - `internal/service/batch_image_provider_gemini.go`
  - `internal/service/content_moderation.go`
- 独立 `http.Client{}`
  - DingTalk/WeChat auth、prompt security audit、xAI device flow
  - company health probe、websearch、GitHub release、pricing
  - HTTPUpstream、Antigravity、payments、Turnstile、channel monitor
  - image storage、OpenAI WS、Vertex
- 直接/可直连 `net.Dialer{}`
  - prompt security audit、websearch、Antigravity
  - TLS fingerprint、HTTP client pool、HTTPUpstream、proxyutil forward dialer
  - channel monitor、SMTP
- `tls.DialWithDialer`
  - SMTP

这些并不都承载 managed AI account。Company V1 对 account-sensitive 路径实施应用路由；最终 UID nftables 必须阻止其余路径获得公网 direct。未批准的附加功能在严格 host guard 下应失败，不得为其放宽公网规则。

## D. DNS lookup 路径

显式 production lookup：

- `internal/util/urlvalidator/validator.go`：`net.DefaultResolver.LookupIP`
- `internal/service/channel_monitor_ssrf.go`：`net.DefaultResolver.LookupIPAddr`

隐式 DNS 还可能来自任何 direct `net/http`/`net.Dialer` 连接。Managed path 不在应用中预解析供应商 hostname；hostname 交给 SOCKS server。最终 direct DNS 由 nftables/approved resolver 阻断。

## E. 可以完全不改的上游文件

- Ent Account/Proxy schema
- Account migration
- Proxy migration
- 普通 Gateway 协议转换、计费、调度、响应转换主体
- sing-box 与服务器配置
- 前端

V1 不需要 `egress_routes` 或 Account 新字段。

## F. 必须少量修改的上游文件

- config 与 Wire/generated Wire
- OAuth session DTO（增加 ProxyID）
- Claude/OpenAI/Grok/Gemini OAuth service 接缝
- Claude usage、OpenAI quota/usage、Account Usage
- Account Test 与 OpenAI/Grok WS dial path
- Grok OAuth transport parser
- Proxy readonly error
- CI workflow

其余控制尽量新增 company 文件实现。

## G. 建议/已新增 company 文件

- `service/managed_proxy.go`
- `repository/company_managed_proxy_health.go`
- `repository/company_http_upstream.go`
- `repository/company_proxy_repository.go`
- `service/company_ws_dialer.go`
- 对应单元测试
- `tools/check_company_egress_guard.py`

## H. 最小数据模型

无新数据库模型。部署配置以现有 ProxyID 为 key：

```text
ProxyID (unique in config)
class
country_code
expected_exit_ipv4
```

Account.ProxyID 必须精确匹配 policy ProxyID；shadow account 与 parent ProxyID 必须一致。

## I. CompanyHTTPUpstream wrapper 可行性

可行，覆盖所有通过 `HTTPUpstream.Do/DoWithTLS` 的路径：

- 不信任调用方 proxyURL
- 由 AccountID 重新解析
- 验证 Proxy/health/destination
- 强制 redirect deny
- 复用官方连接池/TLS profile 逻辑

## J. wrapper 无法覆盖的路径

- provider OAuth/refresh client
- OpenAI/Grok WebSocket
- OpenAI privacy/quota、Codex PAT/models、Agent Identity 独立 client
- Antigravity、Vertex service account、Batch/GCS
- websearch、payments、email、third-party login、release/pricing 等非账号功能

前四类已分别 route-aware 或 UNSUPPORTED。managed OpenAI 不允许插件接管，第三方 Web Search emulation 在 enforcement 下不执行；其余非账号网络功能由功能配置和 host kernel guard 管理。

## K. 第一阶段最小 patch set

1. ProxyID policy + startup invariants
2. Proxy readonly repository decorator
3. dual-evidence health gate
4. CompanyHTTPUpstream
5. route-aware OAuth/Refresh/Usage/Test/WS
6. unsupported feature startup/entry rejection
7. static CI + targeted unit tests

不增加 migration，不改业务协议，不改服务器。

## L. 已知安全盲点

- 单 UID kernel policy 不能识别 Account identity 或区分 US/SG SOCKS。
- host guard 尚未部署/验收，因此 production NOT READY。
- fixed ProxyID/expected IP 尚未写入生产配置。
- 本地源码 patch 必须经 Go 1.27 CI、lint、unit/integration 才能构建。
- 非账号的 websearch/payment/email/update 等 outbound 会在严格 nftables 下失败；必须保持禁用、单独代理或拆分进程，不能放宽 Sub2API UID 公网权限。
- TLS 终点、供应商域名变更需显式源码审计并更新 compile-time allowlist。

## 结论

```text
FINAL DESIGN VERDICT: FREEZE
PROXYID-ONLY VERDICT: ADOPT
PRODUCTION READINESS: NOT READY
```
