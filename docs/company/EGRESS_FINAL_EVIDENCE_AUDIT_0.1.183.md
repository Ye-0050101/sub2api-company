# Company Egress Final Evidence Audit 0.1.183

## Baseline evidence

| 项 | 证据 |
|---|---|
| repository | `Wei-Shaw/sub2api` |
| commit | `e8cb019fabf8b55199436229044cbf9aa7a82564` |
| tree | `f08b15f70e98dd19ac3f22cd3ab9cd3957ccd69f` |
| subject | `Merge pull request #6078 from YogaSakti/fix/responses-custom-tool-call-id` |
| body | `fix(openai): keep restored tool-call item IDs typed` |

错误的 `Wei-Shaw/codex/fix-multimodal-support-in-responses` metadata 不属于该 commit，已删除。

## Source evidence and decision

| 证据 | 风险 | V1 决议 |
|---|---|---|
| Account 已有 ProxyID/Proxy | 无需新增 route FK | ProxyID-only |
| HTTPUpstream 空 proxy 可直连 | 有效代理信息变空会绕过 | Company wrapper 重新按 AccountID 解析 |
| proxy fallback 可选择 direct | 代理故障可能清空目标 | enforcement 启动拒绝 direct fallback |
| Proxy.URL 不检查 Status | inactive 仍能生成 URL | resolver 强制 active；soft-delete 查询失败 |
| Admin Proxy CRUD 直接使用 repository | 仅改 ProxyService 不足 | Company ProxyRepository decorator |
| OAuth/Refresh 有独立 client | wrapper 不是唯一出口 | session/account ProxyID route-aware |
| Claude Usage 曾有 nil TLS direct-capable fallback | Usage 可绕过 | 两种 profile 都走 CompanyHTTPUpstream |
| OpenAI/Grok WS 独立 dial | raw parser/Account.Proxy 可绕过 | resolver + proxyurl + proxyutil + coderws |
| Grok OAuth 使用 raw proxy parser | policy normalization 被绕过 | 统一 proxyurl/proxyutil |
| OpenAI privacy/models 使用独立 client；PAT/Agent Identity 属边缘认证 | 空代理或扩大 patch 面 | privacy factory 禁止空代理；models 走 wrapper；PAT/Agent Identity UNSUPPORTED |
| OpenAI 插件与第三方 Web Search 可自行联网 | caller proxy 不是可强制边界 | managed 插件接管与 Web Search emulation 禁止 |
| Antigravity/Vertex/Batch 有独立 client | 扩大修改面且未审计 | V1 UNSUPPORTED，启动/入口前置拒绝 |

## SOCKS/DNS evidence

- 锁定：`golang.org/x/net v0.56.0`
- `proxy.FromURL` 的 socks5/socks5h 均进入同一 SOCKS5 dialer
- hostname 以 FQDN SOCKS address 发送给 SOCKS server
- V1 强制 socks5h 是 canonical/future-proof policy，不把“socks5 必然本地 DNS”写成当前依赖事实
- managed application path 不预解析 provider hostname
- 完整 DNS fail-closed 仍需 Guard + approved resolver + nftables

## Health evidence contract

编译期唯一 endpoint：

- `https://api.ipify.org?format=json`
- `https://cloudflare.com/cdn-cgi/trace`

READY 必须同时满足：

- 两个 probe 返回同一 canonical public IPv4
- IPv4 等于 `expected_exit_ipv4`
- Cloudflare `loc` 等于 `country_code`
- 正常 TLS、无 redirect、bounded timeout/body
- Proxy invariant 与 startup fingerprint 未变化
- evidence 未过 TTL

任何不一致均 FAIL CLOSED。

## Scope evidence

支持：Claude、OpenAI/Codex、Grok、Gemini ordinary、DeepSeek、Kimi、Zhipu 的已列账号类型与 OAuth/Refresh/Usage/Test/WS。

不支持：Antigravity、Grok password/captcha、Gemini/Vertex Batch、Vertex service account/GCS、Bedrock、Ollama Cloud、generic upstream、custom relay、Codex PAT、Agent Identity、managed 插件接管、managed 第三方 Web Search emulation。

## Threat-model evidence

应用层负责 per-account ProxyID/country 选择；UID/nftables 只能负责阻断 host public direct、IPv6 和 direct DNS。单 UID kernel policy 不能证明某个 Account 只使用某个国家 SOCKS。需要更强隔离时采用 worker/UID/netns V2。

## Verification status

- 文档与源码静态 guard：必须在每次 CI 执行
- Go 1.27 unit/integration/lint：合并前必须通过
- 生产 ProxyID/expected IP：部署时提供
- sing-box/DNS/IPv6/nftables/destructive leak test：尚未构成本源码提交的完成项

```text
FINAL DESIGN VERDICT: FREEZE
PROXYID-ONLY VERDICT: ADOPT
PRODUCTION READINESS: NOT READY
```

设计冻结允许继续源码开发和 staging；不等于允许 managed production traffic。
