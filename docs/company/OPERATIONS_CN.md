# Company CN Operations

## 固定边界

- 中国服务器不访问 GitHub，不在线构建，不运行上游内置 updater。
- 本机 Windows 运行 `tools/company-update.ps1`；GitHub Actions 完成测试和 Linux artifact 构建。
- artifact 通过 SCP 上传，服务器只校验 SHA256 并使用 `company-deploy-egress` 原子部署。
- 首次迁移包只通过 SCP 传输，必须保持 `0600`，不得上传网盘、聊天或 GitHub。
- 公司本地服务器与阿里云使用同一脚本，但公网 IPv4、DNS、域名和节点端口必须来自 root-only env。

## 首次迁移

源服务器：

```bash
company-export-migration.sh --stop-application
```

目标服务器准备 `/root/company-server.env`（从 `deploy/company-server.env.example` 复制，权限 `0600`），上传迁移包和CI binary后：

```bash
company-bootstrap-cn.sh \
  --env /root/company-server.env \
  --bundle /root/sub2api-company-migration-<timestamp>.tar.gz \
  --bundle-sha256 <sha256> \
  --binary /root/sub2api-linux-amd64-<commit> \
  --binary-sha256 <sha256> \
  --confirm-first-install

company-activate-egress.sh --env /root/company-server.env
```

两阶段是安全门，不是手工配置：base阶段失败不会开放网络；activate阶段只在数据库和配置完成后加载guard并启动服务。

## 后续更新

本机Windows：

```powershell
.\tools\company-update.ps1 -UpstreamRef <OFFICIAL_TAG_OR_COMMIT>
```

服务器：

```bash
company-deploy-egress --binary <artifact> --sha256 <sha256> --db-backup-confirmed
company-verify-egress \
  --sha256 <sha256> \
  --us-socks-port 11000 --us-exit-ip <US_FIXED_IPV4> \
  --cn-socks-port 13001 --cn-exit-ip <CN_FIXED_IPV4> \
  --domain <PUBLIC_DOMAIN>
```

部署失败自动恢复上一binary。服务器无需GitHub token、PAT、SSH私钥或构建工具链。

## 云服务器与公司局域网差异

- 阿里云DNS通常为 `100.100.2.136/138`；公司局域网必须填写公司批准的DNS，禁止复制云厂商地址。
- 公司局域网必须具备稳定CN公网出口；动态NAT地址不能满足 `expected_exit_ipv4`。
- 入站可使用固定公网IP/端口映射或Cloudflare Tunnel；这些不改变Sub2API UID出站kill-switch。
- US/SG/JP/KR均使用独立ProxyID和独立SOCKS endpoint，不能跨国家自动fallback。
