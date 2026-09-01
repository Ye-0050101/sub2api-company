# Company Egress Operations

## 目标与固定边界

本项目继续跟随官方 Sub2API。Company 差异只负责托管账号的强制出口与受控发布：

- 国际 AI（Claude、OpenAI、Grok、Gemini）必须绑定 INTERNATIONAL_PROXY ProxyID。
- 中国 AI（DeepSeek、Kimi、Zhipu）必须绑定 CN_DIRECT ProxyID。
- 托管账号没有 ProxyID、Proxy 不健康、出口 IP/国家不匹配、代理失败或命中未支持旁路时一律失败，不允许直连。
- Sub2API UID 只能访问本机 PostgreSQL、Redis 和批准的 SOCKS listeners；直接公网、直接 DNS 和 IPv6 均由 nftables 拒绝。
- 每条国际 Route 对应一个 ProxyID、一个统一 SOCKS listener、一个主出口 IPv4 A，以及可选的同国家灾备 IPv4 B。
- 同一国家可以创建多条 Route。多个账号可以共用一个固定出口，也可以每个账号选择不同 Route/ProxyID。
- 不允许跨国家 fallback；A/B 都不可用时 selector 进入 BLOCK。
- 真实订阅、节点密码、服务器 env、数据库和 OAuth 数据不得进入 GitHub。
- 服务器不访问 GitHub、不在线构建，也不使用官方在线 updater/rollback。

## 文件职责

- tools/company-update.ps1：Windows 本机同步官方仓库、触发我们 GitHub 的 CI/Security，并下载验证后的 Linux binary。
- deploy/company-install-fresh.sh：全新 Ubuntu 22.04 amd64 空服务器安装。
- deploy/company-postgresql16.sh：通过 PostgreSQL 官方 PGDG 仓库固定安装 PostgreSQL 16。
- deploy/company-bootstrap-cn.sh：带现有数据库迁移包的安装。
- deploy/company-activate-egress.sh：创建 CN route、Sub2API UID kill-switch 与 systemd 服务。
- deploy/company-route.py：解析、验证和渲染指定的 AnyTLS/Hysteria2/TUIC 节点，并控制严格优先级 failover。
- deploy/company-route-apply.sh（服务器命令名 company-route-add）：原子创建国际 Route、ProxyID、guard、timer 和 Company policy。
- deploy/company-deploy-egress.sh：后续 binary 原子更新，健康失败自动恢复上一 binary。
- deploy/company-verify-egress.sh：只读检查 binary、服务、CN route、所有国际 Route、DNS/IPv6/direct kill-switch。

## 全新空服务器安装

条件：

- Ubuntu 22.04 amd64；
- PostgreSQL 固定为 16，不使用 Ubuntu 22.04 默认的 PostgreSQL 14；
- 固定中国公网出口 IPv4；
- 两个公司批准的 IPv4 DNS 地址（允许是内网 DNS）；
- 已在本机取得 CI 生成的 Company Linux binary；
- 已取得批准版本的 sing-box Linux amd64 binary；
- binary、sing-box、部署脚本和 env 通过 SCP/内网文件传输上传，不从服务器下载 GitHub 内容。

准备 root-only 配置。管理员密码和数据库密码均至少 12 个字符：

~~~bash
cp deploy/company-server.env.example /root/company-server.env
chmod 0600 /root/company-server.env
editor /root/company-server.env
~~~

没有已备案域名或只做内网验证时使用：

~~~ini
COMPANY_ENABLE_PUBLIC_TLS=0
~~~

首次安装：

~~~bash
./deploy/company-install-fresh.sh --env /root/company-server.env --binary /root/sub2api-linux-amd64 --binary-sha256 <BINARY_SHA256> --sing-box /root/sing-box --sing-box-sha256 <SING_BOX_SHA256> --confirm-fresh-install
~~~

脚本会：

1. 核对空机、系统架构、文件 SHA256 和 Company build；
2. 安装 PostgreSQL、Redis、nginx、nftables 等系统包；
3. 创建空数据库和初始管理员；
4. 创建唯一 CN ProxyID 与 127.0.0.1:13001（或 env 指定端口）；
5. 启动 CN SOCKS、DNS/IPv6 guard 和 Sub2API UID kill-switch；
6. 只做一次 CN 双证据出口检查；
7. 失败时删除本次创建的应用路径、systemd 单元、数据库和角色，保留上传的 env/binary/sing-box 供修正后重试。

此时只允许添加中国 AI 账号；国际 Route 尚未创建。

## 增加国际 Route

服务器不得自行拉取订阅。推荐在管理员本机下载订阅的 sing-box JSON，再通过 SCP 上传到服务器：

~~~bash
install -o root -g root -m 0600 /root/upload/provider-sbox.json /root/company-routes/provider-sbox.json
install -o root -g root -m 0600 /root/upload/us-a.json /root/company-routes/us-a.json
~~~

Route 模板：

- deploy/company-route.example.json
- deploy/company-subscription.selected.example.json

每条 Route 必须拥有独立的 route_key、proxy_id、socks_port、api_port 和 candidate probe_port，并填写主 expected_exit_ipv4 A 与可选的同国家 disaster_exit_ipv4 B。

候选顺序由 priority 决定：

~~~text
primary AnyTLS
→ primary Hysteria2
→ primary TUIC
→ disaster AnyTLS/Hysteria2/TUIC
→ BLOCK
~~~

增加 Route：

~~~bash
company-route-add --spec /root/company-routes/us-a.json --subscription /root/company-routes/provider-sbox.json
~~~

工具只复制 spec 指定的 outbound，并拒绝：

- 非 US/SG/JP/KR/HK/TW；
- 非 AnyTLS/Hysteria2/TUIC；
- hostname 节点地址（节点连接必须使用 literal public IPv4）；
- insecure / allowInsecure；
- port hopping；
- detour；
- 节点 DNS resolver；
- 重复 ProxyID、route_key 或本机端口；
- 已存在 Route 的核心字段变更。

激活前只做一轮双证据检查：

~~~text
api.ipify IPv4 == Cloudflare trace IPv4
且 IPv4 属于 A/B
且 Cloudflare loc == country_code
~~~

成功后删除上传的原始订阅副本；已选节点保存在 root 管理的 Route 配置中：

~~~bash
shred -u /root/company-routes/provider-sbox.json
~~~

不要删除 /etc/sub2api-egress/routes/<route_key>/config.json。

failover controller 每 60 秒对每个 candidate 做一次轻量 trace 检查。默认连续失败 3 次后切换，约为 3 分钟。等待期间请求只会失败，不会直连。主候选恢复后自动回到最高优先级可用候选。

## 多账号与多固定 IP

~~~text
OpenAI Account 1 → ProxyID 10 → US-A → A=IP1, B=IP2
OpenAI Account 2 → ProxyID 11 → US-B → A=IP3, B=IP4
Claude Account 3 → ProxyID 10 → 与 Account 1 共用 US-A
~~~

每个 ProxyID 的 A/B 是独立策略。一个账号只选择一个 ProxyID，B 不作为第二个 Sub2API Proxy；B 由该 ProxyID 后面的 sing-box selector 自动切换。

如需替换 Route 的固定 IP、国家、ProxyID 或 listener，创建新 route_key/ProxyID，验证 READY 后将账号改绑，再停用旧 Route。V1 不允许在线修改正在被账号引用的核心 Route 身份。

## 网页添加账号

正确顺序：

1. 先创建并验证 Route；
2. 确认网页代理列表出现对应 Company COUNTRY route_key；
3. 创建账号或启动 OAuth；
4. 国际账号明确选择对应 Company Proxy；
5. DeepSeek/Kimi/Zhipu 选择 Company CN Direct；
6. 完成 Account Test。

不要选择“无代理”。Company build 对托管账号的“无代理”是 fail-closed 错误，不是服务器直连。OAuth 必须在生成 authorization URL 前先选择 ProxyID。

不要在网页修改 Company Proxy 的协议、主机、端口、用户名、密码、状态、有效期、备用代理或 fallback；Company repository 会拒绝受管 Proxy 的普通修改/删除。

## 日常验证

~~~bash
company-verify-egress --sha256 <CURRENT_BINARY_SHA256> --cn-socks-port <CN_SOCKS_PORT> --cn-exit-ip <CN_FIXED_IPV4>
~~~

它会自动发现 /etc/sub2api-egress/routes/*/metadata.json 并逐条检查国际 Route，不需要逐个手写 US/SG/JP/KR/HK/TW 参数。

验证包含 Company binary SHA、Sub2API/CN/国际服务、每条 Route timer 与 nftables guard、A/B 固定出口与国家、DNS/IPv6/direct deny、本机 listeners 和当前 Sub2API TCP 连接。

## 跟随官方更新

所有源码操作都在 Windows 本机仓库完成：

~~~powershell
git switch company/egress-v1
.\tools\company-update.ps1 -UpstreamRef <OFFICIAL_TAG_OR_COMMIT>
~~~

脚本会：

1. fetch upstream，且 upstream push URL 必须为 DISABLED；
2. 在临时 company/upgrade-* 分支合并官方 commit；
3. 运行 Company 静态安全门；
4. 推送到我们自己的 Ye-0050101/sub2api-company；
5. 等待 CI 和 Security Scan 全绿；
6. 下载对应 Linux binary 和 SHA256；
7. 只做 fast-forward 更新，不 force push；
8. 不操作服务器。

本轮新增能力只修改一个官方运行入口文件和一个测试文件；安装、Route、验证、回滚均位于独立 Company deploy 文件，避免把节点和服务器逻辑侵入上游业务代码。

## 服务器更新与回滚

先备份数据库并验证备份可恢复，然后上传 CI binary：

~~~bash
company-deploy-egress --binary /root/sub2api-linux-amd64 --sha256 <SHA256> --ops-dir /root/company-ops --ops-sha256 <OPS_MANIFEST_SHA256> --db-backup-confirmed
company-verify-egress --sha256 <SHA256> --cn-socks-port <CN_SOCKS_PORT> --cn-exit-ip <CN_FIXED_IPV4>
~~~

company-deploy-egress 同时验证 binary、ops 精确文件集和各自 SHA256，保存上一 binary/ops 后原子替换并等待本机 /health；任一环节失败会恢复上一套。

数据库 migration 是 forward-only。若新版本已经修改数据库结构，binary 自动回滚不能逆转数据库，必须使用更新前验证过的数据库 dump 回滚。

## 生产启用门

只有以下条件全部满足才允许托管生产流量：

- 所有实际 Route 已创建并通过固定 IP/国家证据；
- 所有账号已绑定正确 ProxyID；
- company-verify-egress 全部 PASS；
- sing-box Route、DNS containment、IPv6 deny、Sub2API UID nftables kill-switch 均已启用；
- 做过一次 BLOCK 状态泄漏验收；
- 更新与数据库回滚流程已演练。

公司局域网服务器与阿里云使用同一套脚本。只替换固定 CN 公网出口、批准 DNS、域名/入口和国际节点参数，不复制阿里云专用 DNS。
