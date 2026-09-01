#!/usr/bin/env bash
set -Eeuo pipefail

env_file=""
binary=""
binary_sha=""
singbox=""
singbox_sha=""
confirmed=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) env_file=$2; shift ;;
    --binary) binary=$2; shift ;;
    --binary-sha256) binary_sha=$2; shift ;;
    --sing-box) singbox=$2; shift ;;
    --sing-box-sha256) singbox_sha=$2; shift ;;
    --confirm-fresh-install) confirmed=1 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "REFUSING: $*" >&2; return 1; }
require_var() { [[ -n ${!1:-} ]] || die "missing $1 in $env_file"; }
[[ $(id -u) -eq 0 ]] || die "run as root"
[[ $confirmed -eq 1 ]] || die "--confirm-fresh-install is required"
[[ $env_file == /* && -f $env_file ]] || die "--env must be an absolute file"
[[ $(stat -c %U:%G "$env_file") == root:root && $(stat -c %a "$env_file") == 600 ]] ||
  die "env must be root:root 0600"
[[ $binary == /* && -f $binary && -n $binary_sha ]] || die "binary and SHA256 are required"
[[ $singbox == /* && -f $singbox && -n $singbox_sha ]] || die "sing-box and SHA256 are required"
[[ $(sha256sum "$binary" | awk '{print $1}') == "$binary_sha" ]] || die "binary SHA256 mismatch"
[[ $(sha256sum "$singbox" | awk '{print $1}') == "$singbox_sha" ]] || die "sing-box SHA256 mismatch"
"$binary" -version 2>&1 | grep -Fq "company-" || die "binary is not a Company build"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for required in company-activate-egress.sh company-deploy-egress.sh company-postgresql16.sh company-verify-egress.sh company-route.py company-route-apply.sh
do
  [[ -f $script_dir/$required ]] || die "$required must be next to installer"
done

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a
for name in COMPANY_DOMAIN COMPANY_CN_EXIT_IPV4 COMPANY_CN_DNS_IPV4_1   COMPANY_CN_DNS_IPV4_2 COMPANY_DATABASE_NAME COMPANY_DATABASE_USER   COMPANY_DATABASE_PASSWORD COMPANY_ADMIN_EMAIL COMPANY_ADMIN_PASSWORD   COMPANY_CN_PROXY_ID COMPANY_CN_SOCKS_PORT COMPANY_ENABLE_PUBLIC_TLS
do
  require_var "$name"
done
[[ $COMPANY_DATABASE_NAME =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || die "invalid database name"
[[ $COMPANY_DATABASE_USER =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || die "invalid database user"
[[ $COMPANY_ADMIN_EMAIL == *@* && $COMPANY_ADMIN_EMAIL != admin@example.com ]] ||
  die "replace the example admin email"
[[ ${#COMPANY_ADMIN_PASSWORD} -ge 12 && $COMPANY_ADMIN_PASSWORD != *REPLACE* ]] ||
  die "admin password must be a non-example value with at least 12 characters"
[[ ${#COMPANY_DATABASE_PASSWORD} -ge 12 && $COMPANY_DATABASE_PASSWORD != *REPLACE* ]] ||
  die "database password must be a non-example value with at least 12 characters"
[[ $COMPANY_CN_PROXY_ID =~ ^[1-9][0-9]*$ ]] || die "invalid CN ProxyID"
[[ $COMPANY_CN_SOCKS_PORT =~ ^[1-9][0-9]*$ ]] || die "invalid CN SOCKS port"
[[ $COMPANY_ENABLE_PUBLIC_TLS == 0 || $COMPANY_ENABLE_PUBLIC_TLS == 1 ]] ||
  die "COMPANY_ENABLE_PUBLIC_TLS must be 0 or 1"
python3 - "$COMPANY_CN_EXIT_IPV4" "$COMPANY_CN_DNS_IPV4_1" "$COMPANY_CN_DNS_IPV4_2" <<'PY'
import ipaddress, sys
exit_address = ipaddress.ip_address(sys.argv[1])
if (
    exit_address.version != 4
    or str(exit_address) != sys.argv[1]
    or not exit_address.is_global
):
    raise SystemExit("COMPANY_CN_EXIT_IPV4 must be a canonical public IPv4")
for value in sys.argv[2:]:
    address = ipaddress.ip_address(value)
    if address.version != 4 or str(address) != value:
        raise SystemExit(f"not a canonical DNS IPv4: {value}")
PY

[[ $(. /etc/os-release; echo "$ID:$VERSION_ID") == ubuntu:22.04 ]] || die "Ubuntu 22.04 required"
[[ $(dpkg --print-architecture) == amd64 ]] || die "amd64 required"
[[ $(systemctl show sub2api.service -p LoadState --value) == not-found ]] ||
  die "Sub2API service already exists"
[[ ! -e /opt/sub2api && ! -e /etc/sub2api-egress ]] ||
  die "Sub2API paths already exist"
exec 9>/run/lock/sub2api-company-fresh-install.lock
flock -n 9 || die "another Company installation is running"

role_created=0
database_created=0
fresh_complete=0
rollback_fresh_install() {
  trap - ERR INT TERM
  [[ $fresh_complete -eq 0 ]] || return 0
  echo "Fresh installation failed; removing only resources created by this run" >&2
  systemctl disable --now sub2api.service sub2api-egress-guard.service     sub2api-egress-cn.service sub2api-cn-guard.service >/dev/null 2>&1 || true
  nft delete table inet sub2api_egress_guard >/dev/null 2>&1 || true
  nft delete table inet sub2api_cn_guard >/dev/null 2>&1 || true
  rm -f     /etc/systemd/system/sub2api.service     /etc/systemd/system/sub2api-egress-guard.service     /etc/systemd/system/sub2api-egress-cn.service     /etc/systemd/system/sub2api-cn-guard.service     /etc/nginx/sites-enabled/sub2api     /etc/nginx/sites-enabled/sub2api-acme     /etc/nginx/sites-available/sub2api     /etc/nginx/sites-available/sub2api-acme     /etc/nginx/conf.d/sub2api-websocket-map.conf
  rm -rf -- /etc/systemd/system/sub2api.service.d
  systemctl daemon-reload >/dev/null 2>&1 || true
  for target in /opt/sub2api /opt/sub2api-egress /etc/sub2api-egress; do
    case "$target" in
      /opt/sub2api|/opt/sub2api-egress|/etc/sub2api-egress) rm -rf -- "$target" ;;
      *) echo "Refusing unexpected cleanup target: $target" >&2 ;;
    esac
  done
  if [[ $database_created -eq 1 ]]; then
    sudo -u postgres dropdb --if-exists --force "$COMPANY_DATABASE_NAME" || true
  fi
  if [[ $role_created -eq 1 ]]; then
    sudo -u postgres dropuser --if-exists "$COMPANY_DATABASE_USER" || true
  fi
}
trap rollback_fresh_install ERR INT TERM

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates certbot curl nginx nftables openssl python3 python3-yaml redis-server
"$script_dir/company-postgresql16.sh"
systemctl enable --now redis-server.service
systemctl disable --now nginx.service || true

for user in sub2api sub2api-egress-cn; do
  id "$user" >/dev/null 2>&1 ||
    useradd --system --no-create-home --shell /usr/sbin/nologin "$user"
done
install -d -o sub2api -g sub2api -m 0750 /opt/sub2api /opt/sub2api/data /opt/sub2api/releases
install -d -o root -g root -m 0755 /opt/sub2api-egress/bin
install -o root -g root -m 0755 "$binary" /opt/sub2api/sub2api
install -o root -g root -m 0755 "$singbox" /opt/sub2api-egress/bin/sing-box
/opt/sub2api-egress/bin/sing-box version >/dev/null

role_count=$(sudo -u postgres psql -X -At -d postgres -v role="$COMPANY_DATABASE_USER"   -c "SELECT count(*) FROM pg_roles WHERE rolname=:'role';")
database_count=$(sudo -u postgres psql -X -At -d postgres -v db="$COMPANY_DATABASE_NAME"   -c "SELECT count(*) FROM pg_database WHERE datname=:'db';")
[[ $role_count == 0 && $database_count == 0 ]] || die "database role or database already exists"
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d postgres   -v db_password="$COMPANY_DATABASE_PASSWORD" <<SQL
CREATE ROLE $COMPANY_DATABASE_USER LOGIN PASSWORD :'db_password';
SQL
role_created=1
sudo -u postgres createdb --owner="$COMPANY_DATABASE_USER" "$COMPANY_DATABASE_NAME"
database_created=1

jwt_secret=$(openssl rand -hex 32)
totp_secret=$(openssl rand -hex 32)
runuser -u sub2api -- env   DATA_DIR=/opt/sub2api   AUTO_SETUP=true   DATABASE_HOST=127.0.0.1   DATABASE_PORT=5432   DATABASE_USER="$COMPANY_DATABASE_USER"   DATABASE_PASSWORD="$COMPANY_DATABASE_PASSWORD"   DATABASE_DBNAME="$COMPANY_DATABASE_NAME"   DATABASE_SSLMODE=disable   REDIS_HOST=127.0.0.1   REDIS_PORT=6379   ADMIN_EMAIL="$COMPANY_ADMIN_EMAIL"   ADMIN_PASSWORD="$COMPANY_ADMIN_PASSWORD"   SERVER_HOST=127.0.0.1   SERVER_PORT=8080   SERVER_MODE=release   JWT_SECRET="$jwt_secret"   TZ=Asia/Shanghai   /opt/sub2api/sub2api --company-bootstrap-fresh
unset jwt_secret

python3 - "$totp_secret" <<'PY'
from pathlib import Path
import sys, yaml
path = Path("/opt/sub2api/config.yaml")
cfg = yaml.safe_load(path.read_text()) or {}
cfg.setdefault("totp", {})["encryption_key"] = sys.argv[1]
cfg.setdefault("security", {}).setdefault("proxy_fallback", {})[
    "allow_direct_on_error"
] = False
cfg["company_egress"] = {
    "development_bypass": False,
    "managed_proxies": [],
}
cfg.setdefault("gateway", {}).setdefault("grok", {})["password_auth_enabled"] = False
cfg.setdefault("batch_image", {})["enabled"] = False
cfg["batch_image"]["queue_enabled"] = False
cfg["batch_image"]["vertex_enabled"] = False
path.write_text(yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False))
PY
unset totp_secret
chown sub2api:sub2api /opt/sub2api/config.yaml /opt/sub2api/.installed
chmod 0600 /opt/sub2api/config.yaml
chmod 0400 /opt/sub2api/.installed


sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d "$COMPANY_DATABASE_NAME"   -v proxy_id="$COMPANY_CN_PROXY_ID" -v proxy_port="$COMPANY_CN_SOCKS_PORT" <<'SQL'
INSERT INTO proxies (
  id,name,protocol,host,port,username,password,status,fallback_mode,
  backup_proxy_id,expires_at,created_at,updated_at,deleted_at
) VALUES (
  :proxy_id,'Company CN Direct','socks5h','127.0.0.1',:proxy_port,
  '','','active','none',NULL,NULL,NOW(),NOW(),NULL
);
SELECT setval(pg_get_serial_sequence('proxies','id'),(SELECT max(id) FROM proxies),true);
SQL

python3 - "$COMPANY_CN_PROXY_ID" "$COMPANY_CN_EXIT_IPV4" <<'PY'
from pathlib import Path
import sys, yaml
path = Path("/opt/sub2api/config.yaml")
cfg = yaml.safe_load(path.read_text()) or {}
cfg["company_egress"]["managed_proxies"] = [{
    "proxy_id": int(sys.argv[1]),
    "class": "CN_DIRECT",
    "country_code": "CN",
    "expected_exit_ipv4": sys.argv[2],
}]
path.write_text(yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False))
PY
chown sub2api:sub2api /opt/sub2api/config.yaml
chmod 0600 /opt/sub2api/config.yaml

install -o root -g root -m 0755 "$script_dir/company-activate-egress.sh"   /usr/local/sbin/company-activate-egress
install -o root -g root -m 0755 "$script_dir/company-deploy-egress.sh"   /usr/local/sbin/company-deploy-egress
install -o root -g root -m 0755 "$script_dir/company-verify-egress.sh"   /usr/local/sbin/company-verify-egress
install -o root -g root -m 0755 "$script_dir/company-route.py"   /usr/local/sbin/company-route
install -o root -g root -m 0755 "$script_dir/company-route-apply.sh"   /usr/local/sbin/company-route-add
install -o root -g root -m 0755 "$script_dir/company-install-fresh.sh"   /usr/local/sbin/company-install-fresh
install -o root -g root -m 0755 "$script_dir/company-postgresql16.sh"   /usr/local/sbin/company-postgresql16

/usr/local/sbin/company-activate-egress --env "$env_file"

/usr/local/sbin/company-verify-egress   --sha256 "$binary_sha"   --cn-socks-port "$COMPANY_CN_SOCKS_PORT"   --cn-exit-ip "$COMPANY_CN_EXIT_IPV4"

fresh_complete=1
trap - ERR INT TERM
echo "COMPANY_FRESH_INSTALL_READY=1"
echo "Next: add each US/SG/JP/KR fixed-exit route with company-route-add."
