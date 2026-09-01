#!/usr/bin/env bash
set -Eeuo pipefail

env_file=""
bundle=""
bundle_sha=""
binary=""
binary_sha=""
confirmed=0
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) env_file=$2; shift ;;
    --bundle) bundle=$2; shift ;;
    --bundle-sha256) bundle_sha=$2; shift ;;
    --binary) binary=$2; shift ;;
    --binary-sha256) binary_sha=$2; shift ;;
    --confirm-first-install) confirmed=1 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "Refusing: $*" >&2; exit 1; }
require_var() { [[ -n ${!1:-} ]] || die "missing $1 in $env_file"; }

[[ $(id -u) -eq 0 ]] || die "run as root"
[[ $confirmed -eq 1 ]] || die "--confirm-first-install is required"
[[ $env_file == /* && -f $env_file ]] || die "--env must be an absolute file"
[[ $(stat -c %U:%G "$env_file") == root:root ]] || die "env file must be root:root"
[[ $(stat -c %a "$env_file") == 600 ]] || die "env file must have mode 0600"
[[ $bundle == /* && -f $bundle && -n $bundle_sha ]] || die "bundle and SHA256 are required"
[[ $binary == /* && -f $binary && -n $binary_sha ]] || die "binary and SHA256 are required"
[[ $(sha256sum "$bundle" | awk '{print $1}') == "$bundle_sha" ]] || die "bundle SHA256 mismatch"
[[ $(sha256sum "$binary" | awk '{print $1}') == "$binary_sha" ]] || die "binary SHA256 mismatch"
[[ -f $script_dir/company-activate-egress.sh ]] || die "company-activate-egress.sh must be next to bootstrap"

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

for name in \
  COMPANY_DOMAIN COMPANY_CN_EXIT_IPV4 COMPANY_CN_DNS_IPV4_1 COMPANY_CN_DNS_IPV4_2 \
  COMPANY_US_EXIT_IPV4 COMPANY_US_NODE_IPV4 COMPANY_US_ANYTLS_PORT \
  COMPANY_US_HY2_PORT COMPANY_US_TUIC_PORT COMPANY_DATABASE_NAME \
  COMPANY_DATABASE_USER COMPANY_US_PROXY_ID COMPANY_CN_PROXY_ID \
  COMPANY_US_SOCKS_PORT COMPANY_CN_SOCKS_PORT COMPANY_ENABLE_PUBLIC_TLS
do
  require_var "$name"
done

[[ $COMPANY_DATABASE_NAME =~ ^[a-zA-Z0-9_]+$ ]] || die "invalid database name"
[[ $COMPANY_DATABASE_USER =~ ^[a-zA-Z0-9_]+$ ]] || die "invalid database user"
[[ $COMPANY_DOMAIN =~ ^[a-zA-Z0-9.-]+$ ]] || die "invalid domain"

python3 - "$COMPANY_CN_EXIT_IPV4" "$COMPANY_CN_DNS_IPV4_1" "$COMPANY_CN_DNS_IPV4_2" \
  "$COMPANY_US_EXIT_IPV4" "$COMPANY_US_NODE_IPV4" <<'PY'
import ipaddress, sys
for value in sys.argv[1:]:
    address = ipaddress.ip_address(value)
    if address.version != 4:
        raise SystemExit(f"not IPv4: {value}")
PY

[[ $(. /etc/os-release; echo "$ID:$VERSION_ID") == ubuntu:24.04 ]] || die "Ubuntu 24.04 required"
[[ $(dpkg --print-architecture) == amd64 ]] || die "amd64 required"
[[ $(systemctl show sub2api.service -p LoadState --value) == not-found ]] || die "target is not fresh"
[[ ! -e /opt/sub2api && ! -e /etc/sub2api-egress ]] || die "Sub2API paths already exist"

exec 9>/run/lock/sub2api-company-bootstrap.lock
flock -n 9 || die "another bootstrap is running"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates certbot curl nginx nftables openssl postgresql \
  postgresql-contrib python3-yaml redis-server tar

if ! swapon --show=NAME --noheadings | grep -Fxq /swapfile; then
  [[ ! -e /swapfile ]] || die "/swapfile exists but is not active"
  fallocate -l 2G /swapfile
  chmod 0600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -Eq '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

systemctl enable --now postgresql.service redis-server.service
systemctl disable --now nginx.service || true

for user in sub2api sub2api-egress-us-a sub2api-egress-cn; do
  id "$user" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$user"
done

stage=/var/lib/sub2api-company-bootstrap
install -d -o root -g root -m 0700 "$stage"
tar -xzf "$bundle" -C "$stage"
[[ -f $stage/MANIFEST.txt && -f $stage/database/$COMPANY_DATABASE_NAME.dump ]] || die "invalid migration bundle"
pg_restore --list "$stage/database/$COMPANY_DATABASE_NAME.dump" >/dev/null

install -d -o sub2api -g sub2api -m 0750 /opt/sub2api /opt/sub2api/data /opt/sub2api/releases
install -o root -g root -m 0755 "$binary" /opt/sub2api/sub2api
install -o sub2api -g sub2api -m 0600 "$stage/application/config.yaml" /opt/sub2api/config.yaml
[[ -d $stage/optional-data/opt__sub2api__data ]] && {
  cp -a "$stage/optional-data/opt__sub2api__data/." /opt/sub2api/data/
  chown -R sub2api:sub2api /opt/sub2api/data
}

install -d -m 0755 /opt/sub2api-egress/bin
install -m 0755 "$stage/egress/sing-box" /opt/sub2api-egress/bin/sing-box
install -d -o root -g sub2api-egress-us-a -m 0750 /etc/sub2api-egress/us-a
install -m 0640 -o root -g sub2api-egress-us-a "$stage/egress/us-a-config.json" /etc/sub2api-egress/us-a/config.json
install -m 0600 "$stage/egress/us-a-clash-api.secret" /etc/sub2api-egress/us-a/clash-api.secret
install -m 0750 "$stage/scripts/sub2api-us-a-failover" /usr/local/sbin/sub2api-us-a-failover
for script in company-deploy-egress company-verify-egress; do
  [[ -f $stage/scripts/$script ]] && install -m 0755 "$stage/scripts/$script" "/usr/local/sbin/$script"
done
install -m 0755 "$script_dir/company-activate-egress.sh" /usr/local/sbin/company-activate-egress
install -m 0755 "$script_dir/company-bootstrap-cn.sh" /usr/local/sbin/company-bootstrap-cn

db_password=$(python3 - <<'PY'
from pathlib import Path
import os
import yaml
cfg = yaml.safe_load(Path('/opt/sub2api/config.yaml').read_text())
db = cfg.get('database') or {}
assert db.get('dbname') == os.environ['COMPANY_DATABASE_NAME']
assert db.get('user') == os.environ['COMPANY_DATABASE_USER']
password = str(db.get('password') or '')
assert password and '\n' not in password
print(password, end='')
PY
)

sudo -u postgres psql -v ON_ERROR_STOP=1 -v db_password="$db_password" <<SQL
CREATE ROLE $COMPANY_DATABASE_USER LOGIN PASSWORD :'db_password';
CREATE DATABASE $COMPANY_DATABASE_NAME OWNER $COMPANY_DATABASE_USER;
SQL

postgres_dump=/var/lib/postgresql/sub2api-company-bootstrap.dump
install -o postgres -g postgres -m 0600 "$stage/database/$COMPANY_DATABASE_NAME.dump" "$postgres_dump"
sudo -u postgres pg_restore --exit-on-error --no-owner --no-acl \
  --role="$COMPANY_DATABASE_USER" --dbname="$COMPANY_DATABASE_NAME" "$postgres_dump"
rm -f "$postgres_dump"
unset db_password

export COMPANY_CONFIG=/opt/sub2api/config.yaml
python3 - <<'PY'
import os
from pathlib import Path
import yaml
p = Path(os.environ['COMPANY_CONFIG'])
cfg = yaml.safe_load(p.read_text())
managed = (cfg.setdefault('company_egress', {})).setdefault('managed_proxies', [])
cn_id = int(os.environ['COMPANY_CN_PROXY_ID'])
us_id = int(os.environ['COMPANY_US_PROXY_ID'])
managed[:] = [x for x in managed if int(x.get('proxy_id', 0)) not in (us_id, cn_id)
              and x.get('class') != 'CN_DIRECT']
managed.append({'proxy_id': us_id, 'class': 'INTERNATIONAL_PROXY', 'country_code': 'US',
                'expected_exit_ipv4': os.environ['COMPANY_US_EXIT_IPV4']})
managed.append({'proxy_id': cn_id, 'class': 'CN_DIRECT', 'country_code': 'CN',
                'expected_exit_ipv4': os.environ['COMPANY_CN_EXIT_IPV4']})
cfg['company_egress']['development_bypass'] = False
cfg.setdefault('security', {}).setdefault('proxy_fallback', {})['allow_direct_on_error'] = False
p.write_text(yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False))
PY
chown sub2api:sub2api /opt/sub2api/config.yaml
chmod 0600 /opt/sub2api/config.yaml

sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$COMPANY_DATABASE_NAME" \
  -v us_id="$COMPANY_US_PROXY_ID" -v us_port="$COMPANY_US_SOCKS_PORT" \
  -v cn_id="$COMPANY_CN_PROXY_ID" -v cn_port="$COMPANY_CN_SOCKS_PORT" <<'SQL'
UPDATE proxies SET name='Company US-A Unified',protocol='socks5h',host='127.0.0.1',
 port=:us_port,username='',password='',status='active',fallback_mode='none',
 backup_proxy_id=NULL,expires_at=NULL,deleted_at=NULL,updated_at=NOW()
 WHERE id=:us_id;
INSERT INTO proxies (id,name,protocol,host,port,username,password,status,fallback_mode,
                     backup_proxy_id,expires_at,created_at,updated_at)
VALUES (:cn_id,'Company CN Direct','socks5h','127.0.0.1',:cn_port,'','','active','none',NULL,NULL,NOW(),NOW())
ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name,protocol=EXCLUDED.protocol,
 host=EXCLUDED.host,port=EXCLUDED.port,username='',password='',status='active',
 fallback_mode='none',backup_proxy_id=NULL,expires_at=NULL,deleted_at=NULL,updated_at=NOW();
UPDATE accounts SET proxy_id=:cn_id, updated_at=NOW()
 WHERE deleted_at IS NULL AND platform IN ('deepseek','kimi','zhipu');
SELECT setval(pg_get_serial_sequence('proxies','id'),(SELECT max(id) FROM proxies),true);
SQL

echo "BASE_AND_DATABASE_READY=1"
echo "Next: /usr/local/sbin/company-activate-egress --env $env_file"
