# Company Egress V1 Patchset

## 状态

- 设计：ProxyID-only / ADOPT / FREEZE
- 数据库：无 schema 变更、无 migration
- 服务器：本 patchset 不修改服务器或现有 sing-box
- 生产：NOT READY；必须通过完整 activation gate

## 已实现的源码面

### Company 核心

- `backend/internal/service/managed_proxy.go`
  - deployment config -> immutable ProxyID policy
  - platform/type 支持矩阵
  - Proxy 不变量、class、custom base URL、destination allowlist
  - EgressResolver 与 OAuth session ProxyID 绑定
- `backend/internal/repository/company_managed_proxy_health.go`
  - startup/periodic/on-demand health
  - 双 HTTPS evidence、固定出口 IP/country、TTL、fingerprint
- `backend/internal/repository/company_http_upstream.go`
  - AccountID 重新解析、覆盖调用方 proxy、目的域校验、redirect deny
- `backend/internal/repository/company_proxy_repository.go`
  - 被引用 Proxy 的普通 Update/Delete 拒绝
- `backend/internal/service/company_ws_dialer.go`
  - OpenAI/Grok route-aware WS decision

### 最小上游接缝

- config：company policy 配置与 release/startup 不变量
- DI/Wire：生产绑定 Company ProxyRepository、HTTPUpstream、Health、Resolver、OAuth providers
- Claude/OpenAI/Grok/Gemini OAuth：authorization/callback/exchange/refresh 固定 ProxyID
- Claude Usage：移除无 TLS profile 时的 direct-capable client fallback
- OpenAI quota/usage：进入网络前解析 route
- OpenAI privacy（Admin 与 refresh 后处理）、Codex PAT、Agent Identity、Codex models manifest：独立 client 前解析 route
- Account Usage：统一 route/health gate，Antigravity 在网络前拒绝
- Account Test：HTTP 与 realtime WS 使用 company decision
- OpenAI/Grok WS：统一项目 proxy parser/transport
- Grok OAuth：统一项目 proxy parser/transport；官方 token endpoint 固定
- Antigravity OAuth：company production provider 直接 UNSUPPORTED
- managed OpenAI 请求不允许本地插件接管；第三方 Web Search emulation 在 enforcement 下关闭
- ProxyService sentinel：受管 Proxy readonly 错误

### 测试与 CI

- ProxyInactive / ProxySoftDeleted
- duplicate ProxyID
- direct fallback / release bypass / Grok password / Batch startup rejection
- exact HTTPS host policy / custom base URL
- OAuth callback ProxyID mismatch
- WebSocket project parser
- Exit IPv4/country mismatch
- RouteHealth expired
- Company HTTP proxy override / host reject
- referenced Proxy update/delete reject
- `tools/check_company_egress_guard.py`
- Backend CI 中执行 company static guard

静态门保护 account-sensitive production files，禁止新增：

- `http.DefaultClient`
- raw `url.Parse(proxyURL)`
- `net.DefaultResolver` / direct Lookup
- direct `net.Dialer{}`
- empty `ProxyURL` client
- 旧 production Wire provider

例外必须按文件、规则、精确源码行和审计理由加入 allowlist。

## 明确未实现/不属于本 patchset

- 不新增 EgressRoute 表或 `route.enabled`
- 不生成 migration
- 不实现 Antigravity、Grok password/captcha、Gemini Batch、Vertex、Bedrock、Ollama、generic upstream、managed 第三方 Web Search emulation
- 不编辑 sing-box、systemd、nftables、DNS 或 IPv6
- 不录入部署环境 ProxyID/固定出口 IPv4
- 不宣称 kernel guard 已存在

## 验证门

合并/构建前：

1. static guard
2. `gofmt`/lint
3. company unit tests
4. upstream unit/integration tests
5. review `main...company/egress-v1`

生产前另需：

1. 配置真实 ProxyID 和 expected exit IPv4
2. startup preflight
3. staging
4. sing-box route
5. DNS containment
6. IPv6 deny
7. Sub2API UID nftables kill-switch
8. destructive leak tests

## 升级流程

每次上游升级保持固定流程：

1. fetch `upstream`
2. 从当前 company 分支建立升级分支
3. 明确记录目标上游 commit/tag
4. rebase 或 merge，上游源码冲突逐项审计
5. 运行 company static guard、测试、lint、build
6. 只审查 company patch 与上游差异
7. 生成可追溯 binary/config SHA
8. staging 后才进入生产部署

未来可提供三个职责分离脚本：

- `company-audit-upgrade`：只读差异和静态门
- `company-build-egress`：可复现构建与 SHA
- `company-deploy-egress`：有状态部署/回滚

另保留只读 `company-verify-egress`，检查 binary SHA、company config SHA、ProxyID policy、ManagedProxyHealth、本地 SOCKS listeners、nftables、Sub2API UID 公网连接、DNS/IPv6 拒绝。

本阶段不创建或运行这些服务器脚本。
