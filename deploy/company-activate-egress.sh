#!/usr/bin/env bash
set -Eeuo pipefail

env_file=""
reconcile_config_only=0
defer_http=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) env_file=$2; shift ;;
    --reconcile-config-only) reconcile_config_only=1 ;;
    --defer-http) defer_http=1 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "Refusing: $*" >&2; exit 1; }
[[ $(id -u) -eq 0 ]] || die "run as root"
[[ $env_file == /* && -f $env_file ]] || die "--env must be an absolute file"
[[ $(stat -c %U:%G "$env_file") == root:root && $(stat -c %a "$env_file") == 600 ]] || die "env must be root:root 0600"
set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

for name in COMPANY_DOMAIN COMPANY_CN_EXIT_IPV4 COMPANY_CN_DNS_IPV4_1 \
  COMPANY_CN_DNS_IPV4_2 COMPANY_DATABASE_NAME COMPANY_CN_PROXY_ID \
  COMPANY_CN_SOCKS_PORT COMPANY_ENABLE_PUBLIC_TLS
do
  [[ -n ${!name:-} ]] || die "missing $name"
done
[[ $COMPANY_ENABLE_PUBLIC_TLS == 0 || $COMPANY_ENABLE_PUBLIC_TLS == 1 ]] || die "COMPANY_ENABLE_PUBLIC_TLS must be 0 or 1"
web_mode=${COMPANY_WEB_MODE:-}
if [[ -z $web_mode ]]; then
  if [[ $COMPANY_ENABLE_PUBLIC_TLS == 1 ]]; then web_mode=public-https; else web_mode=preserve; fi
fi
[[ $web_mode == preserve || $web_mode == http || $web_mode == public-https ]] || die "COMPANY_WEB_MODE must be preserve, http or public-https"
web_http_args=()
if [[ $web_mode == http ]]; then
  [[ $COMPANY_ENABLE_PUBLIC_TLS == 0 ]] || die "HTTP mode requires COMPANY_ENABLE_PUBLIC_TLS=0"
  [[ ${COMPANY_HTTP_ACKNOWLEDGE_PLAINTEXT:-0} == 1 ]] || die "HTTP requires COMPANY_HTTP_ACKNOWLEDGE_PLAINTEXT=1"
  [[ -n ${COMPANY_WEB_LISTEN_IP:-} && -n ${COMPANY_WEB_ALLOW_CIDRS:-} ]] || die "HTTP listen IP and approved company CIDRs are required"
  web_http_args=(--listen-ip "$COMPANY_WEB_LISTEN_IP" --server-name "$COMPANY_DOMAIN" --acknowledge-plaintext)
  IFS=',' read -r -a web_cidrs <<<"$COMPANY_WEB_ALLOW_CIDRS"
  for web_cidr in "${web_cidrs[@]}"; do web_http_args+=(--allow-cidr "$web_cidr"); done
  python3 /usr/local/sbin/companyctl web http "${web_http_args[@]}" --check >/dev/null
elif [[ $web_mode == public-https ]]; then
  [[ $COMPANY_ENABLE_PUBLIC_TLS == 1 ]] || die "public-https requires COMPANY_ENABLE_PUBLIC_TLS=1"
elif [[ $COMPANY_ENABLE_PUBLIC_TLS != 0 ]]; then
  die "preserve mode requires COMPANY_ENABLE_PUBLIC_TLS=0"
fi

stage=/var/lib/sub2api-company-bootstrap
singbox=/opt/sub2api-egress/bin/sing-box
[[ -x /opt/sub2api/sub2api && -x $singbox && -f /opt/sub2api/config.yaml ]] || die "bootstrap base is incomplete"

reconcile_proxy_probe() {
  python3 - /opt/sub2api/config.yaml <<'PY'
import os
from pathlib import Path
import stat
import sys
import tempfile
import yaml

path = Path(sys.argv[1])
info = path.stat()
cfg = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
security = cfg.setdefault("security", {})
security.setdefault("proxy_fallback", {})["allow_direct_on_error"] = False
security["proxy_probe"] = {
    "insecure_skip_verify": False,
    "urls": [
        {"url": "https://api.ipify.org?format=json", "parser": "ipify"},
        {"url": "https://cloudflare.com/cdn-cgi/trace", "parser": "chatgpt-trace"},
    ],
}
temporary = None
try:
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=f".{path.name}.company.",
        delete=False,
    ) as handle:
        temporary = Path(handle.name)
        yaml.safe_dump(cfg, handle, allow_unicode=True, sort_keys=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.chown(temporary, info.st_uid, info.st_gid)
    os.chmod(temporary, stat.S_IMODE(info.st_mode))
    os.replace(temporary, path)
    temporary = None
finally:
    if temporary is not None:
        temporary.unlink(missing_ok=True)
PY
}

if [[ $reconcile_config_only -eq 1 ]]; then
  exec 9>/run/lock/sub2api-company-deploy.lock
  flock -n 9 || die "another Company deployment is running"
  exec 8>/run/lock/sub2api-company-route.lock
  flock -n 8 || die "a Company route operation is running"
  config_backup=$(mktemp /opt/sub2api/.config.yaml.reconcile.XXXXXX)
  cp -a /opt/sub2api/config.yaml "$config_backup"
  restore_reconciled_config() {
    trap - ERR INT TERM
    cp -a "$config_backup" /opt/sub2api/config.yaml
    rm -f -- "$config_backup"
    if [[ $(systemctl show sub2api.service -p LoadState --value) == loaded ]]; then
      systemctl restart sub2api.service || true
    fi
  }
  trap restore_reconciled_config ERR INT TERM
  reconcile_proxy_probe
  if [[ $(systemctl show sub2api.service -p LoadState --value) == loaded ]]; then
    systemctl restart sub2api.service
    healthy=0
    for _ in $(seq 1 60); do
      if curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:8080/health >/dev/null; then
        healthy=1
        break
      fi
      sleep 1
    done
    [[ $healthy -eq 1 ]] || die "application health failed after proxy probe reconciliation"
  fi
  trap - ERR INT TERM
  rm -f -- "$config_backup"
  echo "COMPANY_PROXY_PROBE_RECONCILED=1"
  exit 0
fi
[[ $(systemctl show sub2api.service -p LoadState --value) == not-found ]] || die "Sub2API is already activated"
reconcile_proxy_probe

migration_us=0
if [[ -f $stage/systemd/sub2api-egress-us-a.service ]]; then
  migration_us=1
  for name in COMPANY_US_EXIT_IPV4 COMPANY_US_NODE_IPV4 COMPANY_US_ANYTLS_PORT \
    COMPANY_US_HY2_PORT COMPANY_US_TUIC_PORT COMPANY_US_PROXY_ID COMPANY_US_SOCKS_PORT
  do
    [[ -n ${!name:-} ]] || die "missing $name for migrated US route"
  done
fi

cn_uid=$(id -u sub2api-egress-cn)
app_uid=$(id -u sub2api)
if [[ $migration_us -eq 1 ]]; then
  us_uid=$(id -u sub2api-egress-us-a)
fi

install -d -o root -g sub2api-egress-cn -m 0750 /etc/sub2api-egress/cn
cat >/etc/sub2api-egress/cn/config.json <<JSON
{"log":{"level":"info","timestamp":true},"dns":{"servers":[{"type":"local","tag":"local"}],"final":"local","strategy":"ipv4_only"},"inbounds":[{"type":"socks","tag":"socks-cn","listen":"127.0.0.1","listen_port":$COMPANY_CN_SOCKS_PORT}],"outbounds":[{"type":"direct","tag":"direct-cn","domain_resolver":{"server":"local","strategy":"ipv4_only"}}],"route":{"final":"direct-cn","auto_detect_interface":true}}
JSON
chown root:sub2api-egress-cn /etc/sub2api-egress/cn/config.json
chmod 0640 /etc/sub2api-egress/cn/config.json
"$singbox" check -c /etc/sub2api-egress/cn/config.json

cat >/etc/sub2api-egress/cn/guard.nft <<NFT
table inet sub2api_cn_guard {
 chain output { type filter hook output priority 0; policy accept;
  meta skuid $cn_uid meta nfproto ipv6 counter reject
  meta skuid $cn_uid ip daddr { $COMPANY_CN_DNS_IPV4_1, $COMPANY_CN_DNS_IPV4_2, 127.0.0.53, 127.0.0.54 } udp dport 53 counter accept
  meta skuid $cn_uid ip daddr { $COMPANY_CN_DNS_IPV4_1, $COMPANY_CN_DNS_IPV4_2, 127.0.0.53, 127.0.0.54 } tcp dport 53 counter accept
  meta skuid $cn_uid oifname "lo" ct state established,related counter accept
  meta skuid $cn_uid meta nfproto ipv4 tcp dport 443 counter accept
  meta skuid $cn_uid counter reject
 }
}
NFT
chmod 0640 /etc/sub2api-egress/cn/guard.nft
nft -c -f /etc/sub2api-egress/cn/guard.nft

cat >/etc/systemd/system/sub2api-cn-guard.service <<'UNIT'
[Unit]
Description=Sub2API CN egress guard
Before=sub2api-egress-cn.service
[Service]
Type=oneshot
ExecStartPre=-/usr/sbin/nft delete table inet sub2api_cn_guard
ExecStart=/usr/sbin/nft -f /etc/sub2api-egress/cn/guard.nft
RemainAfterExit=yes
CapabilityBoundingSet=CAP_NET_ADMIN
RestrictAddressFamilies=AF_UNIX AF_NETLINK
[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/sub2api-egress-cn.service <<'UNIT'
[Unit]
Description=Sub2API isolated CN direct egress
After=network-online.target sub2api-cn-guard.service
Requires=sub2api-cn-guard.service
Before=sub2api.service
[Service]
Type=simple
User=sub2api-egress-cn
Group=sub2api-egress-cn
StateDirectory=sub2api-egress-cn
ExecStartPre=/opt/sub2api-egress/bin/sing-box check -c /etc/sub2api-egress/cn/config.json
ExecStart=/opt/sub2api-egress/bin/sing-box run -c /etc/sub2api-egress/cn/config.json
Restart=on-failure
RestartSec=3s
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_NETLINK
CapabilityBoundingSet=
[Install]
WantedBy=multi-user.target
UNIT

if [[ $migration_us -eq 1 ]]; then
  install -m 0644 "$stage/systemd/sub2api-egress-us-a.service" /etc/systemd/system/sub2api-egress-us-a.service
install -m 0644 "$stage/systemd/sub2api-us-a-failover.service" /etc/systemd/system/sub2api-us-a-failover.service
install -m 0644 "$stage/systemd/sub2api-us-a-failover.timer" /etc/systemd/system/sub2api-us-a-failover.timer

cat >/etc/sub2api-egress/us-a/guard.nft <<NFT
table inet sub2api_us_a_guard {
 chain output { type filter hook output priority 0; policy accept;
  meta skuid $us_uid meta nfproto ipv6 counter reject
  meta skuid $us_uid oifname "lo" ct state established,related counter accept
  meta skuid $us_uid ip daddr $COMPANY_US_NODE_IPV4 tcp dport $COMPANY_US_ANYTLS_PORT counter accept
  meta skuid $us_uid ip daddr $COMPANY_US_NODE_IPV4 udp dport { $COMPANY_US_HY2_PORT, $COMPANY_US_TUIC_PORT } counter accept
  meta skuid $us_uid counter reject
 }
}
NFT
chmod 0640 /etc/sub2api-egress/us-a/guard.nft
nft -c -f /etc/sub2api-egress/us-a/guard.nft

cat >/etc/systemd/system/sub2api-us-a-guard.service <<'UNIT'
[Unit]
Description=Sub2API US-A egress guard
Before=sub2api-egress-us-a.service
[Service]
Type=oneshot
ExecStartPre=-/usr/sbin/nft delete table inet sub2api_us_a_guard
ExecStart=/usr/sbin/nft -f /etc/sub2api-egress/us-a/guard.nft
RemainAfterExit=yes
CapabilityBoundingSet=CAP_NET_ADMIN
RestrictAddressFamilies=AF_UNIX AF_NETLINK
[Install]
WantedBy=multi-user.target
UNIT
install -d -m 0755 /etc/systemd/system/sub2api-egress-us-a.service.d
cat >/etc/systemd/system/sub2api-egress-us-a.service.d/10-guard.conf <<'UNIT'
[Unit]
Requires=sub2api-us-a-guard.service
After=sub2api-us-a-guard.service
UNIT
fi

APP_SOCKS_PORTS=$COMPANY_CN_SOCKS_PORT
if [[ $migration_us -eq 1 ]]; then
  APP_SOCKS_PORTS="$COMPANY_US_SOCKS_PORT, $COMPANY_CN_SOCKS_PORT"
fi

install -d -m 0750 /etc/sub2api-egress/sub2api
cat >/etc/sub2api-egress/sub2api/guard.nft <<NFT
table inet sub2api_egress_guard {
 chain output { type filter hook output priority 0; policy accept;
  meta skuid $app_uid meta nfproto ipv6 counter reject
  meta skuid $app_uid udp dport 53 counter reject
  meta skuid $app_uid tcp dport 53 counter reject
  meta skuid $app_uid oifname "lo" ct state established,related counter accept
  meta skuid $app_uid oifname "lo" ip daddr 127.0.0.1 tcp dport { 5432, 6379, $APP_SOCKS_PORTS } counter accept
  meta skuid $app_uid counter reject
 }
}
NFT
chmod 0640 /etc/sub2api-egress/sub2api/guard.nft
nft -c -f /etc/sub2api-egress/sub2api/guard.nft

cat >/etc/systemd/system/sub2api-egress-guard.service <<'UNIT'
[Unit]
Description=Sub2API UID fail-closed egress guard
Before=sub2api.service
[Service]
Type=oneshot
ExecStartPre=-/usr/sbin/nft delete table inet sub2api_egress_guard
ExecStart=/usr/sbin/nft -f /etc/sub2api-egress/sub2api/guard.nft
RemainAfterExit=yes
CapabilityBoundingSet=CAP_NET_ADMIN
RestrictAddressFamilies=AF_UNIX AF_NETLINK
[Install]
WantedBy=multi-user.target
UNIT

cat >/etc/systemd/system/sub2api.service <<'UNIT'
[Unit]
Description=Sub2API Company
After=network-online.target postgresql.service redis-server.service sub2api-egress-guard.service sub2api-egress-cn.service
Requires=postgresql.service redis-server.service sub2api-egress-guard.service sub2api-egress-cn.service
[Service]
Type=simple
User=sub2api
Group=sub2api
WorkingDirectory=/opt/sub2api
ExecStartPre=+/usr/sbin/nft list table inet sub2api_egress_guard
ExecStart=/opt/sub2api/sub2api
Environment=GIN_MODE=release
Environment=TZ=Asia/Shanghai
Environment=SERVER_HOST=127.0.0.1
Environment=SERVER_PORT=8080
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/sub2api/data
RestrictAddressFamilies=AF_UNIX AF_INET
CapabilityBoundingSet=
[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now sub2api-cn-guard.service sub2api-egress-cn.service
if [[ $migration_us -eq 1 ]]; then
  install -d -m 0755 /etc/systemd/system/sub2api.service.d
  cat >/etc/systemd/system/sub2api.service.d/20-company-migrated-us.conf <<'UNIT'
[Unit]
Requires=sub2api-egress-us-a.service
After=sub2api-egress-us-a.service
UNIT
  systemctl daemon-reload
  systemctl enable --now sub2api-us-a-guard.service sub2api-egress-us-a.service
  systemctl start sub2api-us-a-failover.service
  systemctl enable --now sub2api-us-a-failover.timer
fi
systemctl enable --now sub2api-egress-guard.service sub2api.service

for _ in $(seq 1 60); do
  curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:8080/health >/dev/null && break
  sleep 1
done
curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:8080/health >/dev/null || die "application health failed"

if runuser -u sub2api -- curl --proto '=https' --noproxy '*' -fsS \
  --connect-timeout 3 --max-time 6 https://api.ipify.org >/dev/null 2>&1; then
  die "Sub2API UID can still reach public direct egress"
fi

if [[ $web_mode == http ]]; then
  if [[ $defer_http -eq 0 ]]; then
    if ! /usr/local/sbin/companyctl web http "${web_http_args[@]}" --disable-default-site; then
      echo "COMPANY_APPLICATION_READY_HTTP_FAILED=1" >&2
      echo "Egress/application remain activated. Do not rerun activation; retry companyctl web http after correcting web parameters." >&2
      exit 1
    fi
  fi
elif [[ $web_mode == public-https ]]; then
  install -d -o www-data -g www-data -m 0755 /var/www/certbot
  rm -f /etc/nginx/sites-enabled/default
  cat >/etc/nginx/sites-available/sub2api-acme <<NGINX
server { listen 80; server_name $COMPANY_DOMAIN; location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; } location / { return 503; } }
NGINX
  ln -sf /etc/nginx/sites-available/sub2api-acme /etc/nginx/sites-enabled/sub2api-acme
  nginx -t
  systemctl start nginx.service
  certbot certonly --webroot -w /var/www/certbot -d "$COMPANY_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email
  systemctl stop nginx.service
  rm -f /etc/nginx/sites-enabled/sub2api-acme
  cat >/etc/nginx/conf.d/sub2api-websocket-map.conf <<'NGINX'
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
NGINX
  cat >/etc/nginx/sites-available/sub2api <<NGINX
server { listen 80; server_name $COMPANY_DOMAIN; location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; } location / { return 301 https://\$host\$request_uri; } }
server { listen 443 ssl; server_name $COMPANY_DOMAIN; ssl_certificate /etc/letsencrypt/live/$COMPANY_DOMAIN/fullchain.pem; ssl_certificate_key /etc/letsencrypt/live/$COMPANY_DOMAIN/privkey.pem; ssl_protocols TLSv1.2 TLSv1.3; client_max_body_size 256m; location / { proxy_pass http://127.0.0.1:8080; proxy_http_version 1.1; proxy_set_header Host \$host; proxy_set_header X-Forwarded-Proto https; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection \$connection_upgrade; proxy_buffering off; proxy_read_timeout 900s; } }
NGINX
  ln -sf /etc/nginx/sites-available/sub2api /etc/nginx/sites-enabled/sub2api
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx <<'HOOK'
#!/usr/bin/env bash
set -e
/usr/sbin/nginx -t
/bin/systemctl reload nginx.service
HOOK
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx
  nginx -t
  systemctl enable --now nginx.service certbot.timer
fi

echo "COMPANY_EGRESS_ACTIVATED=1"
if [[ $migration_us -eq 1 ]]; then
  echo "Verify with: company-verify-egress --us-socks-port $COMPANY_US_SOCKS_PORT --us-exit-ip $COMPANY_US_EXIT_IPV4 --cn-socks-port $COMPANY_CN_SOCKS_PORT --cn-exit-ip $COMPANY_CN_EXIT_IPV4 --domain $COMPANY_DOMAIN"
else
  echo "Verify with: company-verify-egress --cn-socks-port $COMPANY_CN_SOCKS_PORT --cn-exit-ip $COMPANY_CN_EXIT_IPV4"
fi
