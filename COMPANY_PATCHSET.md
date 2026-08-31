# Company Egress V1 Patchset

## 状态

- 设计：ProxyID-only / ADOPT / FREEZE
- 数据库：无 schema 变更、无 migration
- 服务器：本 patchset 不修改服务器或现有 sing-box
- 生产：NOT READY；必须通过完整 activation gate

## 已实现的源码面

### 长期维护面

相对 `a0ac9b4` 的瘦身结果：

- 总差异文件：53（原实现为 59；增加的 3 个文件是升级/部署/验证脚本）
- 既有 `backend/internal` / `backend/cmd` 文件接缝：29（原实现为 40）
- 新增 company 核心/测试/运维文件：16；这些文件不与 upstream 同路径冲突
- 官方 `service/wire.go` 只保留 7 个 provider 名称替换
- 官方 `config.go` 只保留 Company 字段、默认值和 release 启动检查
- 四套 OAuth session DTO 已完全恢复官方版本；route 固定复用现有 `session.ProxyURL`

升级审查以“29 个既有接缝”为准，而不是把 company 新文件、运维脚本和文档误算成 53 个上游冲突点。

### Company 核心

- `backend/internal/service/managed_proxy.go`
  - deployment config -> immutable ProxyID policy
  - platform/type 支持矩阵
  - Proxy 不变量、class、custom base URL、destination allowlist
  - EgressResolver 与现有 OAuth session.ProxyURL 绑定，不修改上游 session DTO
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
- Claude/OpenAI/Grok/Gemini OAuth：authorization 固定 canonical ProxyURL；callback ProxyID 必填且 endpoint 必须与 session 一致；refresh 按账号重新解析
- Claude Usage：移除无 TLS profile 时的 direct-capable client fallback
- OpenAI quota/usage：进入网络前解析 route
- OpenAI privacy：生产 factory 禁止空代理；不再向 Admin/TokenRefresh 注入 resolver
- Codex models manifest：managed 模式走 CompanyHTTPUpstream
- Codex PAT / Agent Identity：V1 统一入口 UNSUPPORTED，不再深入修改其内部实现
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
- 不实现 Antigravity、Grok password/captcha、Gemini Batch、Vertex、Bedrock、Ollama、generic upstream、Codex PAT、Agent Identity、managed 第三方 Web Search emulation
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

已提供三个职责分离入口：

- `tools/company-update.ps1`
  - 临时分支 merge upstream，不 rebase、不 force push
  - 先把临时升级分支推送到 GitHub；正式分支保持不变
  - 等待临时分支 GitHub CI、Security Scan 和 embedded-site artifact 全绿
  - 验证后才以 atomic push 更新 `main` 与 `company/egress-v1`
  - 下载 CI 先构建前端、再以 `-tags embed` 生成的 Linux/amd64 网站 artifact；本机不安装 Go
  - 使用当前 Git credential，不索取或保存 PAT
  - 只操作本机仓库和 GitHub，绝不 SSH 或部署服务器
- `deploy/company-deploy-egress.sh`
  - 校验 service 用户、路径、binary SHA、数据库备份确认和 nftables kill-switch
  - 原子替换 `/opt/sub2api/sub2api`，健康失败自动恢复旧 binary
  - 不修改 sing-box、systemd、配置、数据库或防火墙
- `deploy/company-verify-egress.sh`
  - 只读检查 binary/config SHA、systemd、SOCKS listener、UID nftables、IPv6/DNS deny 和当前连接

本机更新命令：

```powershell
.\tools\company-update.ps1 -UpstreamRef <OFFICIAL_TAG_OR_COMMIT>
```

它只更新 GitHub 并下载经过 CI 验证的 Linux 网站 binary。上传服务器和运行 Linux 部署脚本是独立步骤。
