# ProxyID-only Minimal V1 Decision

## Decision

```text
PROXYID-ONLY VERDICT: ADOPT
FINAL DESIGN VERDICT: FREEZE
PRODUCTION READINESS: NOT READY
```

## Why

官方基线已经提供：

```text
Account.ProxyID -> Account.Proxy -> Proxy.URL() -> HTTPUpstream
```

因此 V1 不需要 EgressRoute 表、Account 新字段或 migration。需要补的是现有 ProxyID 周围的不可变 deployment policy、health/destination gate，以及不能经过 HTTPUpstream 的 OAuth/Refresh/Usage/WS 路径。

## Minimal V1

核心新增仅承担五类职责：

1. ProxyID policy/resolver
2. Proxy health evidence
3. HTTPUpstream defense wrapper
4. referenced Proxy readonly boundary
5. route-aware WebSocket boundary

上游文件只在 DI、OAuth session、Usage/Quota/Test/WS 接缝做少量修改。

## Supported

- Claude
- OpenAI/Codex
- Grok（无 password/captcha）
- Gemini ordinary（无 Batch/Vertex）
- DeepSeek
- Kimi
- Zhipu

覆盖 inference、OAuth、refresh、usage/quota、普通 account test 和 OpenAI/Grok WS。

## Unsupported

- Antigravity
- Grok password/captcha
- Gemini Batch
- Vertex service_account/Batch/GCS
- Bedrock
- Ollama Cloud
- generic upstream
- managed custom relay/base URL
- managed OpenAI plugin takeover
- managed third-party Web Search emulation

这些功能不再列入“约 50 个上游文件”的实现计划。V1 选择在启动或网络入口前拒绝，而不是为边缘路径扩大 patch。

## Upgrade invariant

每次上游升级只需：

```text
pin upstream commit
-> replay small company patch
-> static guard
-> Go tests/lint/build
-> review diff
-> staging
-> production activation gate
```

只读 `company-verify-egress` 将作为部署阶段的日常验证入口，但不在本源码阶段操作服务器。
