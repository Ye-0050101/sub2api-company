# Sub2API Company 部署与运维总手册

> 适用范围：Company Egress V1。本文以仓库现有脚本和代码为准，不把规划中的能力写成已经实现。
>
> 当前仓库有两个安装分支：Ubuntu 24.04 使用 `company/egress-v1`；Ubuntu 22.04 使用 `company/egress-v1-ubuntu22.04`。运行安装脚本前必须选择与目标服务器一致的分支。

## 1. 目标、范围与不变量

Company 版本的目标是在尽量保留官方 Sub2API 行为和升级路径的前提下，为托管账号增加一层不可绕过的出口约束：

- 国际 AI：Claude、OpenAI、Grok、Gemini 必须绑定 `INTERNATIONAL_PROXY` ProxyID，并由对应国家的 sing-box Route 出口。
- 中国 AI：DeepSeek、Kimi、Zhipu 必须绑定 `CN_DIRECT` ProxyID，经本机 CN SOCKS listener 后使用服务器的固定中国公网 IPv4。
- 托管账号没有 ProxyID、Proxy 不符合不变量、Route 健康证据过期、出口 IP/国家不匹配、代理失败或目标域名不在批准范围时，必须失败关闭，不能改走服务器公网直连。
- Sub2API 进程 UID 只能连接本机 PostgreSQL、Redis 和已登记的 SOCKS listeners；它的直接 DNS、IPv6 和其他公网连接由 nftables 拒绝。
- 国际 Route 的 sing-box UID 只能连接 Route 配置中明确列出的节点 IPv4 和端口；不允许任意公网、IPv6或直接 DNS。
- 每条国际 Route 对应一个 ProxyID、一个统一 SOCKS listener、一个国家、一个主出口 IPv4 A，以及可选的同国家灾备 IPv4 B。
- A/B 背后可以各有 AnyTLS、Hysteria2、TUIC 候选；A 的候选全部不可用后才选择 B，A/B 都不可用时进入 `block`。
- 同一国家可以建立多条 Route；多个账号既可共用一个固定出口，也可分别绑定不同 ProxyID。
- 不跨国家 fallback，不允许 Sub2API 的 `fallback_mode=direct`。

V1 支持范围：

- 国际：Claude、OpenAI/Codex OAuth、Grok、普通 Gemini；
- 中国：DeepSeek、Kimi、Zhipu；
- 账号推理、已审计的 OAuth/Refresh/Usage/Quota/Test 及 OpenAI/Grok WebSocket 路径。

V1 明确不支持或禁止：Antigravity、Grok password/captcha、Gemini Batch、Vertex service account/Batch/GCS、Bedrock、Ollama Cloud、generic upstream、custom relay、托管账号 `custom_base_url`、OpenAI Codex PAT、Agent Identity、managed 插件接管和 managed 第三方 Web Search emulation。

## 2. 安全边界与网络架构

### 2.1 入站网站访问

~~~text
管理员浏览器
    │
    ├─ 当前调试：SSH 加密隧道
    │             ↓
    │       127.0.0.1:8080
    │
    └─ 长期内网：公司 DNS/证书 + Nginx:443
                  ↓
             127.0.0.1:8080
                  ↓
              Sub2API
~~~

Sub2API 的 systemd 服务固定监听 `127.0.0.1:8080`。不要为了方便将它改成 `0.0.0.0:8080`。

### 2.2 出站 AI 访问

~~~text
国际托管账号
  → 账号 ProxyID
  → 127.0.0.1:<Route SOCKS>
  → sing-box selector
  → A: AnyTLS → HY2 → TUIC
  → B: AnyTLS → HY2 → TUIC（可选）
  → 全部失败：BLOCK

中国托管账号
  → CN ProxyID
  → 127.0.0.1:<CN SOCKS>
  → sing-box-cn direct
  → 服务器固定中国公网 IPv4
~~~

入站反向代理和出站 AI 代理是两件独立的事。Nginx 只负责让浏览器进入网站，不参与 AI 出口选择。

### 2.3 三层防线

1. 应用层：ProxyID policy、目标域名 allowlist、RouteHealth、HTTP/WS/OAuth 等已审计工厂、禁止空代理和 direct fallback。
2. Route 层：sing-box selector、固定出口 IP/国家探测、严格候选顺序、无健康候选时 `block`。
3. 内核层：按 Linux UID 的 nftables，拒绝 Sub2API 的公网直连、直接 DNS 和 IPv6，并限制每个 Route 只能连接批准的节点 IP/端口。

Linux UID/nftables 是“来源泄漏”边界，不知道 Account 身份。账号应使用哪个国家仍由应用的 ProxyID policy、账号绑定和运维记录保证。

## 3. 工作站与服务器职责

### 3.1 Windows 工作站

- 保存 Company Git 仓库；
- fetch/merge 官方 upstream；
- 运行静态门、触发 GitHub CI/Security；
- 下载 CI 生成的 Company Linux binary 和 `company-ops`；
- 校验 SHA256；
- 使用 SCP/批准的内网文件传输将产物上传服务器；
- 保存发布记录，但不保存真实节点密码到 Git。

### 3.2 Linux 服务器

- 运行 PostgreSQL、Redis、Sub2API、sing-box、systemd 和 nftables；
- 执行全新安装、Route 导入、验证、binary/ops 部署及回滚；
- 保存 root-only env、Route 配置、数据库和运行时状态；
- 不 clone/pull GitHub，不在服务器在线构建，不使用官方在线 updater/rollback。

“服务器不访问 GitHub”不等于完全离线：全新安装仍会访问 Ubuntu/PGDG 软件源；启用公网 TLS 时还会访问 ACME/Let’s Encrypt。

## 4. 分支与操作系统矩阵

| 目标系统 | 安装分支 | PostgreSQL | 当前状态 |
|---|---|---:|---|
| Ubuntu 24.04 amd64 | `company/egress-v1` | 系统包 | 有对应 fresh installer |
| Ubuntu 22.04 amd64 | `company/egress-v1-ubuntu22.04` | PGDG PostgreSQL 16 | 有对应 fresh installer 和 `company-postgresql16.sh` |
| 其他系统/架构 | 无 | 无 | 安装脚本会拒绝 |

不要绕过版本检查。Ubuntu 22.04 分支是兼容分支，不应拿来安装 Ubuntu 24.04；反之亦然。

## 5. 新空服务器部署

### 5.1 前置检查

目标必须是空服务器：不存在 `sub2api.service`、`/opt/sub2api`、`/etc/sub2api-egress`，数据库名和角色也不能与将要创建的值冲突。

~~~bash
. /etc/os-release
printf 'OS=%s %s\n' "$ID" "$VERSION_ID"
dpkg --print-architecture
systemctl show sub2api.service -p LoadState --value
test ! -e /opt/sub2api
test ! -e /etc/sub2api-egress
ip -br address
ip route
resolvectl dns
curl -4 --connect-timeout 8 --max-time 20 https://api-ipv4.ip.sb/ip
~~~

记录：

- 服务器固定 CN 公网 IPv4；
- 两个经公司批准的 IPv4 DNS；
- 局域网 IP，例如 `192.168.1.175`（仅为示例）；
- 服务器准确 Ubuntu 版本；
- binary、sing-box 和 ops 的 SHA256。

### 5.2 Windows 获取正确分支

CMD：

~~~cmd
cd /d C:\sub2api-company
git fetch origin
git switch company/egress-v1-ubuntu22.04
git pull --ff-only origin company/egress-v1-ubuntu22.04
git status --short
git rev-parse HEAD
~~~

Ubuntu 24.04 将分支名替换成 `company/egress-v1`。

PowerShell 对应写法：

~~~powershell
Set-Location C:\sub2api-company
git fetch origin
git switch company/egress-v1-ubuntu22.04
git pull --ff-only origin company/egress-v1-ubuntu22.04
git status --short
git rev-parse HEAD
~~~

### 5.3 上传安装包

示例：

~~~cmd
scp sub2api-linux-amd64 sing-box hsaiapi@192.168.1.175:/home/hsaiapi/company-install/
scp deploy\company-install-fresh.sh deploy\company-activate-egress.sh deploy\company-deploy-egress.sh deploy\company-verify-egress.sh deploy\company-route.py deploy\company-route-apply.sh deploy\companyctl.py deploy\company-server.env.example hsaiapi@192.168.1.175:/home/hsaiapi/company-install/deploy/
~~~

Ubuntu 22.04 还必须上传：

~~~cmd
scp deploy\company-postgresql16.sh hsaiapi@192.168.1.175:/home/hsaiapi/company-install/deploy/
~~~

### 5.4 创建 root-only env

在服务器执行：

~~~bash
sudo install -o root -g root -m 0600 \
  /home/hsaiapi/company-install/deploy/company-server.env.example \
  /root/company-server.env
sudo editor /root/company-server.env
sudo sed -i 's/\r$//' /root/company-server.env
sudo bash -n /root/company-server.env
sudo stat -c '%U:%G %a %n' /root/company-server.env
~~~

全新安装关键字段：

~~~ini
COMPANY_DOMAIN=hsaiapi.internal
COMPANY_CN_EXIT_IPV4=<服务器固定中国公网IPv4>
COMPANY_CN_DNS_IPV4_1=<批准DNS1>
COMPANY_CN_DNS_IPV4_2=<批准DNS2>
COMPANY_DATABASE_NAME=<数据库名>
COMPANY_DATABASE_USER=<数据库用户>
COMPANY_DATABASE_PASSWORD='<至少12字符的非示例值>'
COMPANY_ADMIN_EMAIL=<真实管理员邮箱>
COMPANY_ADMIN_PASSWORD='<至少12字符的非示例值>'
COMPANY_CN_PROXY_ID=<未占用正整数>
COMPANY_CN_SOCKS_PORT=13001
COMPANY_ENABLE_PUBLIC_TLS=0
~~~

即使关闭公网 TLS，`COMPANY_DOMAIN` 仍是脚本必填项；可以填写合法的内部名称，但脚本不会自动为它建立公司 DNS 或内网证书。

### 5.5 执行安装

先清理 Windows CRLF 并检查语法：

~~~bash
sudo sed -i 's/\r$//' /home/hsaiapi/company-install/deploy/company-*.sh \
  /home/hsaiapi/company-install/deploy/companyctl.py \
  /home/hsaiapi/company-install/deploy/company-route.py
sudo chmod 0755 /home/hsaiapi/company-install/deploy/company-*.sh \
  /home/hsaiapi/company-install/deploy/companyctl.py \
  /home/hsaiapi/company-install/deploy/company-route.py
sudo bash -n /home/hsaiapi/company-install/deploy/company-install-fresh.sh
~~~

计算 SHA256：

~~~bash
sha256sum /home/hsaiapi/company-install/sub2api-linux-amd64
sha256sum /home/hsaiapi/company-install/sing-box
~~~

Ubuntu 22.04：

~~~bash
sudo bash /home/hsaiapi/company-install/deploy/company-install-fresh.sh \
  --env /root/company-server.env \
  --binary /home/hsaiapi/company-install/sub2api-linux-amd64 \
  --binary-sha256 <BINARY_SHA256> \
  --sing-box /home/hsaiapi/company-install/sing-box \
  --sing-box-sha256 <SING_BOX_SHA256> \
  --confirm-fresh-install
~~~

成功标志：

~~~text
COMPANY_FRESH_INSTALL_READY=1
~~~

脚本会创建数据库和管理员、CN Proxy、CN listener、Sub2API UID kill-switch、systemd 服务并做一次验证。失败时只清理本轮创建的应用资源；不要在失败后手工删除未知目录，先阅读 `journalctl` 和脚本错误。

### 5.6 安装后最小验收

~~~bash
systemctl is-active postgresql redis-server sub2api.service \
  sub2api-egress-cn.service sub2api-egress-guard.service
curl --noproxy '*' -fsS http://127.0.0.1:8080/health
sudo companyctl route list
sudo companyctl verify
~~~

首次安装后 `companyctl route list` 显示 `No managed international routes` 是正常的，CN_DIRECT 不在国际 Route 列表中。

## 6. 网站访问方式

### 6.1 当前推荐：SSH 隧道

在可以访问虚拟机局域网 IP 的 Windows CMD 执行：

~~~cmd
ssh -N -L 18080:127.0.0.1:8080 hsaiapi@192.168.1.175
~~~

保持窗口打开，在浏览器访问：

~~~text
http://127.0.0.1:18080
~~~

这里显示 HTTP 是因为浏览器到 Windows 本机回环端口使用 HTTP；Windows 到服务器的传输由 SSH 加密。端口冲突时可以把本地 `18080` 改成其他未占用端口。

### 6.2 长期方案：同一虚拟机上的 Nginx HTTPS

虚拟机可以直接运行 Nginx，不需要第二个“反代 IP”。以示例 IP 为例：

~~~text
公司电脑 → 192.168.1.175:443 → Nginx → 127.0.0.1:8080 → Sub2API
~~~

正式内网 HTTPS 需要公司 IT 提供：

- 内部 DNS 名称到虚拟机 IP 的解析；
- 公司 CA 签发的证书及私钥，或公司批准的证书申请方式；
- 允许指定管理网段访问虚拟机 TCP 443 的防火墙规则。

当前脚本的 `COMPANY_ENABLE_PUBLIC_TLS=1` 使用 Certbot/Let’s Encrypt，适用于可从公网完成 ACME 验证且已有备案/批准域名的环境，不等同于内网 CA 自动配置。只有私有 IP 时不要直接开启该选项。

禁止：把 Sub2API 改成监听 `0.0.0.0:8080`、向整个局域网开放 8080、使用未受控的公网反向隧道。

## 7. CN_DIRECT

全新安装会创建：

~~~text
CN ProxyID
→ socks5h://127.0.0.1:<CN_SOCKS_PORT>
→ 独立 sing-box-cn UID
→ IPv4 HTTPS + 批准 DNS
→ 服务器固定中国公网 IPv4
~~~

CN guard：

- 拒绝该 UID 的 IPv6；
- 只允许配置的两个 DNS IPv4及 systemd-resolved 本地地址的 53/UDP、53/TCP；
- 允许 IPv4 TCP/443；
- 其余拒绝。

CN 出口健康证据要求 `api-ipv4.ip.sb` 与 Cloudflare trace 返回同一固定 IPv4，且 Cloudflare `loc=CN`。更换公司出口 NAT、公网 IPv4或 DNS 后，必须先更新 root-only env/policy/guard 并重新验证，不能只改数据库 Proxy 地址。

## 8. 使用 companyctl 增加国际 Route

### 8.1 支持模型

`sudo companyctl route add` 当前支持国家：

~~~text
US SG JP KR HK TW
~~~

一条 Route 的推荐命名与端口规划：

| Route | ProxyID | SOCKS | API | 用途 |
|---|---:|---:|---:|---|
| `us-a` | 10 | 11000 | 19000 | 美国固定 IP 组 A |
| `us-b` | 11 | 11010 | 19010 | 美国固定 IP 组 B |
| `sg-a` | 20 | 12000 | 20000 | 新加坡固定 IP 组 A |

这只是示例。所有 `route_key`、ProxyID、SOCKS/API/probe 端口必须全局不冲突。

### 8.2 交互导入

~~~bash
sudo companyctl route add
~~~

向导依次询问：

1. 国家；
2. `route_key`；
3. ProxyID；
4. 统一 SOCKS 端口；
5. 本机 selector API 端口；
6. 主出口 expected IPv4 A；
7. 可选灾备 expected IPv4 B；
8. A 的 AnyTLS、HY2、TUIC URI；
9. B 的 AnyTLS、HY2、TUIC URI。

链接使用隐藏输入，不会显示到终端，也不会进入普通 Shell 历史。导入临时文件位于 `/root` 下，完成或失败时覆盖后删除。

### 8.3 协议与 TLS 处理

- 节点服务器必须是 literal public IPv4，不接受 hostname 节点地址；
- 仅接受 AnyTLS、Hysteria2、TUIC；
- AnyTLS 通过 TCP TLS 握手取得并固定公钥 pin；
- HY2 从 URI 的 `pinSHA256` 读取 pin；
- TUIC 有显式 pin 时使用显式 pin，否则使用同节点 HY2 pin；若证书公钥不同，该 TUIC 候选失败关闭；
- 最终配置强制 `insecure=false`；
- 不允许 detour 和节点 DNS resolver。

### 8.4 HY2 端口跳跃

向导允许输入 1～3 个明确端口，例如：

~~~text
4433,4500,4600
~~~

多个端口会生成 sing-box `server_ports` 和 `hop_interval=30s`，三个端口会实际参与 HY2 跳跃。nftables 只放行这三个明确 UDP 端口。

不允许把 `30000-40000` 之类大范围直接加入 guard。向导可以从 URI 的范围中建议基础端口和少量边界端口，但操作者必须确认这些明确端口确实由服务端转发。端口跳跃不改变出口 IP，也不代替 A/B 灾备。

### 8.5 候选顺序与自动切换

~~~text
A AnyTLS → A HY2 → A TUIC
→ B AnyTLS → B HY2 → B TUIC
→ BLOCK
~~~

failover timer 每 60 秒检查一次。默认连续失败阈值为 3；当前候选异常但尚未达到切换阈值期间，请求会失败而不会直连。恢复后 controller 会选择优先级最高的健康候选。

Route 激活前会验证：

~~~text
api.ipify IPv4 == Cloudflare trace IPv4
且 IP 属于 A/B
且 Cloudflare loc == Route country
~~~

任何配置、探测、数据库、服务或应用健康失败都会触发 Route 添加回滚。

### 8.6 多国家、多固定 IP、多账号

~~~text
账号1 → ProxyID 10 → us-a → A=US-IP-1 / B=US-IP-2
账号2 → ProxyID 11 → us-b → A=US-IP-3 / B=US-IP-4
账号3 → ProxyID 20 → sg-a → A=SG-IP-1 / B=SG-IP-2
~~~

同一固定出口的三种协议属于同一 Route，不要为 AnyTLS/HY2/TUIC 分别创建三个 ProxyID。灾备 B 也不创建第二个 ProxyID。

Route 核心身份当前不可在线修改。替换国家、ProxyID、listener 或固定出口时，应创建新 `route_key` 和 ProxyID，验证 READY 后迁移账号；当前工具没有实现交互式 `route edit/remove`，停用旧 Route 需要单独审计操作，不能直接删除目录或数据库行。

## 9. ProxyID 与网页账号绑定

ProxyID 是 Sub2API 数据库中 Proxy 的 ID，也是应用 policy 的不可变索引：

~~~text
账号.proxy_id
→ Company managed policy
→ socks5h://127.0.0.1:<Route SOCKS>
→ sing-box Route
~~~

受管 Proxy 必须满足：

- `protocol=socks5h`；
- host 是 `127.0.0.0/8` 的 literal IPv4；
- 无用户名、无密码；
- `status=active`、`deleted_at=NULL`；
- `fallback_mode=none`；
- `backup_proxy_id=NULL`、`expires_at=NULL`。

网页操作顺序：

1. 先用 `companyctl route add` 创建并验证 Route；
2. 确认网页代理列表出现对应 Company Proxy；
3. 创建账号或启动 OAuth；
4. 国际账号明确选择所需国家 Route 的 Proxy；
5. DeepSeek/Kimi/Zhipu 选择 Company CN Direct；
6. 完成 Account Test；
7. 运行 `sudo companyctl account audit`。

不要选择“无代理”。Company build 会使受支持托管账号在缺少 ProxyID 时失败关闭，但正确绑定仍是上线前的人工责任。

`companyctl account audit` 当前检查平台需要 `INTERNATIONAL_PROXY` 还是 `CN_DIRECT`，不会知道业务人员原本希望某个国际账号使用 US 还是 SG。因此应另有账号—Route 台账，并人工核对具体国家。

不要在网页修改 Company Proxy 的主机、端口、协议、状态、凭据、有效期、备用代理或 fallback，也不要删除受管 Proxy。

## 10. 验证、审计与 fail-closed

### 10.1 日常验证

~~~bash
sudo companyctl route list
sudo companyctl verify
sudo companyctl account audit
~~~

`companyctl verify` 自动读取 CN policy、当前 binary SHA 和所有 `/etc/sub2api-egress/routes/*/metadata.json`，检查：

- Sub2API 服务用户和 binary SHA；
- PostgreSQL 16（当前 22.04分支 verifier 的明确要求）；
- CN 和国际 sing-box 服务；
- 国际 failover timers 和 nftables tables；
- 双证据固定 IPv4/国家；
- Sub2API UID kill-switch、IPv6 deny、direct DNS deny；
- 已指定 listeners 和当前 Sub2API TCP 连接。

### 10.2 最小状态检查

~~~bash
systemctl is-active sub2api.service
curl --noproxy '*' -fsS http://127.0.0.1:8080/health
sudo companyctl route list
sudo nft list table inet sub2api_egress_guard
sudo journalctl -u sub2api.service -n 80 --no-pager
~~~

### 10.3 fail-closed 验收

生产启用前至少做一次受控 BLOCK 泄漏验收：

- 暂停对应 failover timer；
- 通过本机 selector 控制面将 Route 切到 `block`；
- 证明经该 SOCKS 的请求失败；
- 证明 `sub2api` UID 直接公网请求失败；
- 恢复原 selector 和 timer；
- 再运行 `companyctl verify`。

该操作会短暂中断 Route，必须在维护窗口使用已审计脚本执行。本文不提供临时拼接的破坏性命令。

## 11. 跟随 upstream、构建与发布

### 11.1 Git remote 固定关系

~~~text
origin   = 公司仓库 Ye-0050101/sub2api-company
upstream = 官方 Wei-Shaw/sub2api
upstream push URL = DISABLED
~~~

检查：

~~~powershell
git remote -v
git remote get-url --push upstream
git status --short
~~~

禁止向 upstream push。

### 11.2 Ubuntu 24.04 主 Company 分支更新

在干净的 Windows 工作树执行：

~~~powershell
git switch company/egress-v1
.\tools\company-update.ps1 -UpstreamRef <OFFICIAL_TAG_OR_COMMIT>
~~~

当前脚本会：

1. fetch upstream 并验证目标继承冻结基线；
2. 建临时 `company/upgrade-*` 分支合并官方提交；
3. 运行 `tools/check_company_egress_guard.py`；
4. 推送临时分支到公司 GitHub；
5. 等待 CI 和 Security Scan；
6. 下载 Linux binary 和精确 `company-ops` artifact；
7. 验证每个 ops 文件与 manifest；
8. fast-forward `main` 和 `company/egress-v1` 并原子 push；
9. 输出 `dist/company/latest.json`；
10. 不操作服务器，不 force push。

它使用当前 Git credential manager 中已有的 GitHub 凭据，不要求把 PAT 写进参数或文件。

### 11.3 Ubuntu 22.04 兼容分支的真实限制

`tools/company-update.ps1` 当前硬编码要求位于 `company/egress-v1`，并不会自动更新 `company/egress-v1-ubuntu22.04`。因此 Ubuntu 22.04 的 upstream 跟进目前不是完全一键：

1. 先按上一节更新并验证 `company/egress-v1`；
2. 将已验证 Company 变化合并到 `company/egress-v1-ubuntu22.04`；
3. 保留 22.04/PGDG PostgreSQL 16 专属差异；
4. 再运行静态门和该分支 CI；
5. 只部署该分支生成且验证通过的 artifact。

在为 22.04 编写并验证专用自动更新包装器之前，不要声称它已实现单命令 upstream 升级。

## 12. 服务器更新与快速回滚

### 12.1 更新前

1. `sudo companyctl verify` 必须通过；
2. 停止写入或进入维护窗口；
3. 创建 PostgreSQL custom dump；
4. `pg_restore --list` 验证 dump；
5. 上传 binary、`company-ops` 和 SHA256；
6. 不从服务器访问 GitHub。

备份示例：

~~~bash
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
backup=/var/backups/sub2api/<DB>-$timestamp.dump
sudo install -d -o root -g root -m 0700 /var/backups/sub2api
sudo -u postgres pg_dump --format=custom --no-owner --no-acl <DB> >"$backup"
test -s "$backup"
pg_restore --list "$backup" >/dev/null
chmod 0600 "$backup"
sha256sum "$backup"
~~~

### 12.2 原子部署

~~~bash
sudo companyctl deploy \
  --binary /root/release/sub2api-linux-amd64 \
  --sha256 <BINARY_SHA256> \
  --ops-dir /root/release/company-ops \
  --ops-sha256 <OPS_MANIFEST_SHA256> \
  --db-backup-confirmed
~~~

部署脚本会验证：

- binary 是 Company build 且 SHA256 匹配；
- ops 目录只含精确允许的五个工具和 `SHA256SUMS`；
- manifest、各文件 hash、Shell/Python 语法；
- ops 不包含 GitHub 下载逻辑；
- Sub2API systemd 身份、工作目录和 nftables guard；
- 替换后本机 `/health`。

旧 binary/ops 会保存到 `/opt/sub2api/releases/rollback-<timestamp>`。启动或健康检查失败时脚本自动恢复上一 binary/ops 并重启。

### 12.3 数据库回滚边界

binary 自动回滚不能逆转数据库 migration。数据库变更是 forward-only；如果新版本已经改变 schema，完整回滚必须恢复更新前验证过的数据库 dump，并与对应旧 binary/ops 配套。不得只换回旧 binary 后继续运行未知 schema。

## 13. 日常运行手册

### 每日/值班检查

~~~bash
sudo companyctl route list
sudo companyctl verify
systemctl --failed
journalctl -u sub2api.service --since today --no-pager | tail -n 100
~~~

### 新增账号

1. 确定国家与固定出口 Route；
2. Route 不存在时先 `sudo companyctl route add`；
3. `sudo companyctl verify`；
4. 网页创建账号并选正确 ProxyID；
5. 网页 Account Test；
6. `sudo companyctl account audit`；
7. 更新账号—Route 台账。

### 新增一个固定 IP

不要修改旧 Route。创建新的 `route_key`、ProxyID、SOCKS/API 端口和 A/B，导入该固定 IP 的三协议候选，验证后再绑定账号。

### 服务重启后

~~~bash
systemctl is-active sub2api.service sub2api-egress-cn.service
sudo companyctl route list
sudo companyctl verify
~~~

## 14. 故障排查

### 网站打不开

~~~bash
systemctl is-active sub2api.service
ss -lntp | grep '127.0.0.1:8080'
curl --noproxy '*' -v http://127.0.0.1:8080/health
journalctl -u sub2api.service -n 100 --no-pager
~~~

SSH 隧道方式还需确认 Windows 隧道窗口仍在运行。本机健康正常但内网 HTTPS 异常时，检查 Nginx、证书、公司 DNS、443 防火墙；不要修改 AI egress guard 来修网站入站问题。

### Route 导入失败

~~~bash
sudo companyctl route list
systemctl status sub2api-egress-<route_key>.service --no-pager -l
journalctl -u sub2api-egress-<route_key>.service -n 100 --no-pager
journalctl -u sub2api-route-<route_key>-failover.service -n 100 --no-pager
sudo nft list table inet sub2api_<route_key下划线形式>_guard
~~~

常见原因：节点端口未监听、URI 使用 hostname、AnyTLS TLS 握手无法取得 pin、HY2 缺少 pin、TUIC 与 HY2 证书不一致、HY2 明确端口未在服务端转发、出口 IP/国家与 A/B 不匹配、本机端口或 ProxyID 冲突。

看到 `Route activation failed ... rolled back` 时先确认 `companyctl route list` 和数据库没有半成品，再修正输入重新创建；不要手工拼接 systemd/nft/SQL 跳过回滚。

### 应用无法启动

~~~bash
systemctl status sub2api.service --no-pager -l
journalctl -u sub2api.service -b -n 150 --no-pager
sudo nft list table inet sub2api_egress_guard
sudo -u postgres psql -X -Atqc 'SHOW server_version_num'
~~~

Company build 会在 direct fallback=true、managed policy 为空/重复、受管 Proxy 不合规或禁用功能开启时拒绝启动。这是安全行为，不应通过关闭 enforcement 绕过。

### 价格在线更新告警

Sub2API UID 不允许直接访问公网或 DNS，因此上游定价文件在线拉取可能失败。只要本地 `/opt/sub2api/data/model_pricing.json` 已加载且服务健康，这不等于 AI Route 泄漏。Company 生产流程应随发布包离线更新批准的数据文件，而不是放开公网。

## 15. 密钥、订阅和敏感信息

- 不把节点 UUID、密码、订阅 URL、管理员密码、数据库密码、OAuth token、cookie、私钥或真实 env 提交 Git；
- 不在工单、聊天截图和日志中粘贴完整 URI；已暴露的测试凭据在投产前轮换；
- `/root/company-server.env` 必须 `root:root 0600`；
- Route 的真实 sing-box 配置和 selector secret 由 root/专用服务组读取，不复制到普通用户目录；
- 使用 `getpass` 交互粘贴 URI；不要把 URI写在命令行参数、Shell history 或共享剪贴板日志；
- 上传临时订阅时设为 `root:root 0600`，选取节点后安全删除原订阅副本；
- binary、sing-box、ops、迁移包和数据库 dump 全部记录 SHA256；
- 不索取或传递 PAT、SSH 私钥和密码给自动化脚本；GitHub 使用当前工作站已授权凭据。

## 16. Production Readiness Checklist

### 代码与制品

- [ ] 使用正确 OS 分支和 CI artifact；
- [ ] Company build 标识正确，官方在线更新/回退入口关闭；
- [ ] CI 和 Security Scan 全绿；
- [ ] `tools/check_company_egress_guard.py` 通过；
- [ ] binary、sing-box、ops SHA256 已记录；
- [ ] 没有真实秘密进入 Git。

### 服务器

- [ ] Ubuntu 版本/amd64 符合对应分支；
- [ ] PostgreSQL/Redis/Sub2API/CN Route 正常；
- [ ] Sub2API 只监听 `127.0.0.1:8080`；
- [ ] CN 固定 IPv4和批准 DNS 已填写并验证；
- [ ] 所有国际 Route 的 A/B、国家、节点端口已验证；
- [ ] nftables、IPv6 deny、direct DNS deny、UID kill-switch 均在；
- [ ] `sudo companyctl verify` 全部 PASS；
- [ ] 受控 BLOCK 泄漏验收通过。

### 账号与入口

- [ ] 所有托管账号绑定正确 ProxyID；
- [ ] `sudo companyctl account audit` 通过；
- [ ] 国际账号具体国家与账号—Route 台账一致；
- [ ] 无托管 `custom_base_url`；
- [ ] 网页入口使用 SSH tunnel 或批准的 Nginx HTTPS；
- [ ] 未向局域网直接开放 8080。

### 发布与回滚

- [ ] 更新前数据库 dump 已通过 `pg_restore --list`；
- [ ] binary/ops 原子部署已演练；
- [ ] 自动 binary/ops 回滚已演练；
- [ ] 数据库 schema 回滚步骤和维护窗口已记录；
- [ ] Ubuntu 22.04 分支已单独完成合并与 CI，而不是误用 24.04 artifact。

## 17. 禁止事项

- 禁止托管账号选择“无代理”；
- 禁止启用 `security.proxy_fallback.allow_direct_on_error`；
- 禁止使用 Proxy 的 `fallback_mode=direct` 或普通 `backup_proxy_id` 实现灾备；
- 禁止跨国家 fallback；
- 禁止共享一个 ProxyID 表示多个国家；
- 禁止受管 Proxy 使用 hostname、凭据、非 `socks5h`、过期/禁用状态；
- 禁止托管账号 `custom_base_url`；
- 禁止在 Sub2API 进程中新增 `http.DefaultClient`、裸 `url.Parse(proxyURL)`、空 ProxyURL client、direct `net.Dialer` 或未批准 resolver；
- 禁止放开 Sub2API UID 公网/DNS/IPv6来“修复”上游在线更新；
- 禁止大范围开放 HY2 UDP 端口；只允许经确认的最多三个明确端口；
- 禁止关闭 kernel guard 后继续承载生产托管流量；
- 禁止在服务器 clone/pull GitHub、在线构建或使用官方在线 updater；
- 禁止 force push 公司主线、向 upstream push、跳过 CI/Security；
- 禁止直接编辑/删除受管 Route 的数据库行、systemd unit、nftables table 或 `/etc/sub2api-egress/routes`；
- 禁止把生产凭据、订阅 URL、env、数据库 dump 上传到 GitHub；
- 禁止在没有数据库恢复方案时部署包含 migration 的新版本。

## 18. 当前尚未自动化的事项

为避免误解，以下能力当前不是现有脚本的一键功能：

- Ubuntu 22.04 兼容分支自动跟进 upstream；
- 内网 DNS、公司 CA 证书签发和 Nginx 内网 HTTPS全自动配置；
- Route 在线编辑、删除和账号无损迁移；
- `companyctl account audit` 判断每个国际账号“业务期望国家”；
- 数据库 migration 的自动逆向回滚；
- 从任意订阅 URL 自动选择并永久保存节点。

这些事项应通过变更单、审核和后续版本化工具实现，不能用临时放宽安全边界代替。
