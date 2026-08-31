# Sub2API Company Egress V1（ProxyID-only）

## 1. 权威基线

- 官方仓库：`Wei-Shaw/sub2api`
- 固定 commit：`e8cb019fabf8b55199436229044cbf9aa7a82564`
- tree：`f08b15f70e98dd19ac3f22cd3ab9cd3957ccd69f`
- commit message：
  - `Merge pull request #6078 from YogaSakti/fix/responses-custom-tool-call-id`
  - `fix(openai): keep restored tool-call item IDs typed`

本文是 Company Egress V1 的最终设计权威。V1 不创建 `egress_routes`，不增加 migration，不修改现有 Account/Proxy 数据库结构。

## 2. 安全目标与边界

托管账号的生产出站必须满足：

```text
Account.ID
  -> Account.ProxyID
  -> immutable company policy keyed by ProxyID
  -> existing Proxy record
  -> ManagedProxyHealth READY_PRIMARY / READY_DISASTER
  -> exact provider destination allowlist
  -> CompanyHTTPUpstream or route-aware WS/OAuth factory
  -> socks5h://literal-loopback-IP:port
  -> isolated sing-box instance
  -> fixed country/IPv4 egress
```

失败、缺字段、不支持的平台、代理不健康、域名不在白名单或解析策略不合规时均 FAIL CLOSED。

CompanyHTTPUpstream 是 HTTP 防御层，不是唯一安全边界。最终防泄漏还依赖 sing-box Guard、DNS containment、IPv6 deny 和按 Sub2API UID 的 nftables kill-switch。

## 3. ProxyID-only 配置

```yaml
company_egress:
  development_bypass: false
  managed_proxies:
    - proxy_id: <US_A_PROXY_ID>
      class: INTERNATIONAL_PROXY
      country_code: US
      expected_exit_ipv4: <PRIMARY_FIXED_PUBLIC_IPV4>
      disaster_exit_ipv4: <OPTIONAL_DISASTER_FIXED_PUBLIC_IPV4>
```

配置只引用现有 `Proxy.ID`。环境相关的 ID 和固定出口 IPv4 不写入源码。

生产不允许普通 runtime switch 关闭 enforcement 后继续服务。开发/测试可显式使用 `development_bypass`；release 模式使用该开关必须启动失败。

## 4. Managed Proxy 不变量

每个被 `company_egress.managed_proxies` 引用的 Proxy 必须：

- `protocol == socks5h`
- `host` 是 canonical literal loopback IPv4（`127.0.0.0/8`）
- 无 username/password
- `status == active`
- soft-deleted Proxy 由 repository 查询失败而拒绝
- `expires_at == NULL`
- `fallback_mode == none`
- `backup_proxy_id == NULL`
- 同一启动配置中 ProxyID 唯一
- 不同 ProxyID 不得共享同一个本地 endpoint
- 启动后 Proxy fingerprint 不得变化

Company ProxyRepository 禁止普通 Update/Delete 修改被引用 Proxy。数据库外直接篡改不属于应用授权路径；运行时 fingerprint 与 health gate 仍会 FAIL CLOSED。

`security.proxy_fallback.allow_direct_on_error=true` 在 company enforcement 启动时必须失败。AnyTLS/HY2/TUIC 的主备只在 sing-box 内处理，Sub2API 不得使用 direct fallback。

## 5. V1 支持矩阵

支持：

- Claude/Anthropic：OAuth、Setup Token、API Key
- OpenAI/Codex：OAuth、Setup Token、API Key
- Grok：OAuth、API Key
- Gemini 普通账号：OAuth、API Key（AI Studio、Code Assist、Google One）
- DeepSeek、Kimi、Zhipu：API Key
- 上述范围内的 inference、OAuth authorization/callback、token exchange、refresh、usage/quota、普通 Account Test
- OpenAI/Grok WebSocket

明确 UNSUPPORTED，任何托管路径在网络前拒绝：

- Antigravity
- Grok password/captcha auth
- Gemini Batch
- Vertex service_account
- Vertex Batch/GCS
- Bedrock
- Ollama Cloud
- generic upstream / `AccountTypeUpstream`
- 其他未列出的 platform/type
- 非官方 managed `base_url` 或 Anthropic `custom_base_url`
- OpenAI Codex Personal Access Token（PAT）
- OpenAI Agent Identity
- 由本地插件接管 managed OpenAI OAuth 出站
- Brave/Tavily 第三方 Web Search emulation（managed 请求保留在官方 AI 上游原生工具路径）

Batch Image 的 `enabled`、`queue_enabled` 或 `vertex_enabled` 在 company enforcement 下导致启动失败。

## 6. 路由类别

- Claude/OpenAI/Grok/Gemini -> `INTERNATIONAL_PROXY`
- DeepSeek/Kimi/Zhipu -> `CN_DIRECT`
- `CN_DIRECT.country_code == CN`

CN-DIRECT 仍使用内部 socks5h endpoint 进入 sing-box-cn，再由服务器直出；Sub2API 进程本身不获得 unrestricted public direct egress。

同一国家可以有多个固定出口 ProxyID。账号通过自己的 ProxyID 精确选中其中一个；端口可由部署规划，loopback IP 可在 `127.0.0.0/8` 内使用 canonical literal 地址，只要不变量和唯一 endpoint 约束成立。V1 不允许把 host 放宽到任意 RFC1918 网段。

## 7. 精确目的域名

仅允许 HTTPS/WSS、默认或显式 443、无 URL credentials、精确 hostname，不使用 wildcard：

- Anthropic：`api.anthropic.com`、`claude.ai`、`claude.com`、`platform.claude.com`
- OpenAI：`api.openai.com`、`auth.openai.com`、`chatgpt.com`
- Grok：`api.x.ai`、`auth.x.ai`、`accounts.x.ai`、`cli-chat-proxy.grok.com`、`us-east-1.api.x.ai`、`us-west-2.api.x.ai`、`eu-west-1.api.x.ai`
- Gemini：`generativelanguage.googleapis.com`、`cloudcode-pa.googleapis.com`、`accounts.google.com`、`oauth2.googleapis.com`、`cloudresourcemanager.googleapis.com`、`www.googleapis.com`
- DeepSeek：`api.deepseek.com`
- Kimi：`api.moonshot.cn`、`api.kimi.com`
- Zhipu：`open.bigmodel.cn`、`api.z.ai`

`daily-cloudcode-pa.googleapis.com` 只属于 Antigravity，不在 V1 allowlist。

数据库中保存的官方 `credentials.base_url` 可兼容；任何未通过上述精确策略的 relay/custom/Ollama URL 均拒绝。

## 8. RouteHealth

RouteHealth 是 runtime 状态，不新增数据库字段：

- `READY_PRIMARY`
- `READY_DISASTER`
- `UNHEALTHY`

唯一编译期探针：

- Probe A：`https://api.ipify.org?format=json`，只提供 IPv4 evidence
- Probe B：`https://cloudflare.com/cdn-cgi/trace`，提供 IPv4 和 `loc`

约束：

- exact HTTPS scheme/hostname/path/query
- 普通 TLS 证书验证
- redirect disabled
- 每个请求 10 秒超时
- body 上限 16 KiB
- 不允许管理员修改
- 不回退到上游默认 HTTP probes

READY 条件：

```text
A.IP == B.IP
B.loc == country_code

A.IP == expected_exit_ipv4
  -> READY_PRIMARY

A.IP == optional disaster_exit_ipv4
  -> READY_DISASTER
```

`disaster_exit_ipv4` 最多一个、可省略、必须是与主 IP 不同的 canonical public IPv4。主/灾备实际出口都必须由 Cloudflare `loc` 验证为同一 `country_code`。任何第三个 IP、TLS failure、redirect、parse failure、IPv6、私网/保留地址、missing loc、IP disagreement、country mismatch、Proxy 变化或 health TTL 过期均为 UNHEALTHY/FAIL CLOSED。

协议与灾备自动化由本地 sing-box selector/controller 完成：同一主 IP 内严格按 `AnyTLS -> HY2 -> TUIC`；三者连续失败至少 180 秒才允许切到灾备 AnyTLS。灾备失败选择 BLOCK；主 IP 连续恢复至少 180 秒后自动回切。Sub2API fallback 始终保持 `none`。

- startup preflight：所有配置 Proxy 必须先通过
- periodic probe interval：60 秒
- health TTL：120 秒
- 请求在证据需刷新时同步验证；不得使用过期 READY

## 9. DNS 与 SOCKS 事实

锁定依赖 `golang.org/x/net v0.56.0`。当前 `proxy.FromURL` 对 `socks5` 与 `socks5h` 进入同一个 SOCKS5 dialer；internal/socks 对 hostname 使用 FQDN SOCKS address，即 hostname 交给 SOCKS server。

V1 仍强制 `socks5h`，理由是 company canonical policy、明确远程 DNS 意图、统一 parser/config 语义与未来兼容性，不声称当前依赖的 `socks5` 必然本地解析。

DNS fail-closed 由 application no-pre-resolution、Guard、approved resolver 和 nftables 共同保证。

## 10. HTTP、OAuth 与 WebSocket

- HTTP 主路径由 CompanyHTTPUpstream 忽略调用方传入的 proxy string，重新按 AccountID 解析 ProxyID，并禁用 redirect。
- Claude Usage 即使无 TLS Profile 也必须走 CompanyHTTPUpstream。
- Claude/OpenAI/Grok/Gemini authorization 先按 ProxyID 解析并把 canonical ProxyURL 固定到现有 session；callback 必须携带 ProxyID，且重新解析出的唯一 endpoint 必须与 session.ProxyURL 完全一致。V1 不修改四套上游 session DTO。
- account refresh 每次重新解析 ProxyID 和 health。
- Grok OAuth 使用固定官方 token endpoint；Grok password auth 关闭。
- OpenAI/Grok WS 必须：`proxyurl.Parse -> proxyutil.ConfigureTransportProxy -> coderws`。
- WS 在 dial 前重新取得 EgressDecision，不能信任 Account.Proxy 或 raw proxy URL。
- OpenAI privacy 的生产 client factory 禁止空代理；Codex models manifest 在 managed 模式统一走 CompanyHTTPUpstream。
- Codex PAT 与 Agent Identity 不进入 V1 扩展实现，在统一 managed 入口直接拒绝。
- company enforcement 下插件不得接管 managed OpenAI HTTP/WS；可自行联网的第三方 Web Search emulation 不得执行。

## 11. Threat Model

单个 Sub2API process/UID 处理多个国家账号时，Linux UID/nftables 可以强制：

- no host public direct
- no unintended IPv6
- no direct DNS

Linux kernel 不知道 Account identity，不能单独强制 US account 只能访问 US SOCKS、SG account 只能访问 SG SOCKS。per-account 地理选择是应用不变量：

`ProxyID policy + immutable decision + route-aware factories + static CI + tests`。

Host guard 是 origin-leak boundary，不是 account-country selection engine。未来若需 kernel-level per-country/account isolation，应升级为 separate worker/UID/netns，不属于 V1。

## 11.1 Company 构建更新边界

- Company CI 必须注入 `BuildType=company`。
- Company build 的版本检查不得访问 `Wei-Shaw/sub2api` release API。
- 后端在线更新、在线 release 回退和本地 `.backup` 回退接口全部 fail closed。
- 前端不显示“立即更新”、官方 release 链接或在线回退；只显示 `Company managed build` 和批准脚本提示。
- 官方同步只在本机仓库通过 `company-update.ps1` 完成；CI 全绿后生成可追溯 artifact，再由 Linux 部署脚本校验 SHA、guard 和数据库备份后原子部署。
- 部署失败必须自动恢复上一 binary；不得用官方内置 updater 绕过 Company patch、CI 或 activation gate。

该边界只管理软件供应链，不替代 ProxyID、RouteHealth、sing-box Guard、DNS/IPv6 containment 或 Sub2API UID nftables kill-switch。

## 12. 生产启用顺序

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

不得先启用 managed production traffic 再补 kernel guard。

## 13. 结论

```text
FINAL DESIGN VERDICT: FREEZE
PROXYID-ONLY VERDICT: ADOPT
PRODUCTION READINESS: NOT READY
```

Phase 1 源码开发可以进行；在真实 ProxyID/固定出口配置、CI、构建、staging、DNS/IPv6/nftables 和泄漏测试全部通过前，禁止 managed production traffic。
