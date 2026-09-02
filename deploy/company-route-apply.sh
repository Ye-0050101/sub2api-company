#!/usr/bin/env bash
set -Eeuo pipefail

spec=""
subscription=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec) spec=$2; shift ;;
    --subscription) subscription=$2; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

die() { echo "REFUSING: $*" >&2; return 1; }
[[ $(id -u) -eq 0 ]] || die "run as root"
[[ $spec == /* && -f $spec ]] || die "--spec must be an absolute file"
[[ $subscription == /* && -f $subscription ]] || die "--subscription must be an absolute file"
[[ $(stat -c %U:%G "$spec") == root:root && $(stat -c %a "$spec") == 600 ]] ||
  die "route spec must be root:root 0600"
[[ $(stat -c %U:%G "$subscription") == root:root && $(stat -c %a "$subscription") == 600 ]] ||
  die "subscription must be root:root 0600"
[[ -x /opt/sub2api-egress/bin/sing-box ]] || die "approved sing-box is missing"
[[ -f /opt/sub2api/config.yaml ]] || die "Sub2API config is missing"
systemctl is-active --quiet sub2api.service || die "Sub2API must be healthy before adding a route"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
route_tool=$script_dir/company-route.py
if [[ ! -f $route_tool ]]; then
  route_tool=/usr/local/sbin/company-route
fi
[[ -f $route_tool ]] || die "company-route tool is missing"
python3 -m py_compile "$route_tool"

exec 9>/run/lock/sub2api-company-route.lock
flock -n 9 || die "another Company route operation is running"

install -d -o root -g root -m 0700 /var/backups/sub2api
stage=$(mktemp -d /etc/sub2api-egress/.route-stage.XXXXXX)
backup=$(mktemp -d /var/backups/sub2api/route-add.XXXXXX)
route_installed=0
proxy_registered=0
app_stopped=0
app_config_changed=0
route_key=""
database=""

cleanup_stage() {
  case "$stage" in
    /etc/sub2api-egress/.route-stage.*) rm -rf -- "$stage" ;;
    *) ;;
  esac
}

rollback() {
  trap - ERR INT TERM
  echo "Route activation failed; restoring the previous application state" >&2
  if [[ $app_config_changed -eq 1 ]]; then
    systemctl stop sub2api.service >/dev/null 2>&1 || true
    [[ -f $backup/config.yaml ]] && install -o sub2api -g sub2api -m 0600 "$backup/config.yaml" /opt/sub2api/config.yaml
    [[ -f $backup/guard.nft ]] && install -o root -g root -m 0640 "$backup/guard.nft" /etc/sub2api-egress/sub2api/guard.nft
    [[ -n $route_key ]] && rm -f "/etc/systemd/system/sub2api.service.d/30-company-route-$route_key.conf"
    systemctl daemon-reload || true
    systemctl restart sub2api-egress-guard.service || true
    systemctl start sub2api.service || true
    app_config_changed=0
  fi
  if [[ $proxy_registered -eq 1 && -n $database ]]; then
    sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d "$database" -c       "DELETE FROM proxies WHERE id=$PROXY_ID AND NOT EXISTS (SELECT 1 FROM accounts WHERE proxy_id=$PROXY_ID);" || true
  fi
  if [[ $route_installed -eq 1 && -n $route_key ]]; then
    systemctl disable --now "sub2api-route-$route_key-failover.timer" >/dev/null 2>&1 || true
    systemctl stop "sub2api-route-$route_key-failover.service" >/dev/null 2>&1 || true
    systemctl disable --now "sub2api-egress-$route_key.service" >/dev/null 2>&1 || true
    systemctl disable --now "sub2api-route-$route_key-guard.service" >/dev/null 2>&1 || true
    nft delete table inet "sub2api_${route_key//-/_}_guard" >/dev/null 2>&1 || true
    rm -rf -- "/etc/sub2api-egress/routes/$route_key"
    rm -f       "/etc/systemd/system/sub2api-route-$route_key-guard.service"       "/etc/systemd/system/sub2api-egress-$route_key.service"       "/etc/systemd/system/sub2api-route-$route_key-failover.service"       "/etc/systemd/system/sub2api-route-$route_key-failover.timer"
    systemctl daemon-reload || true
  fi
  cleanup_stage
}
trap rollback ERR INT TERM
trap cleanup_stage EXIT

python3 "$route_tool" render --spec "$spec" --subscription "$subscription" --output "$stage/rendered"
# shellcheck disable=SC1091
source "$stage/rendered/route.env"
route_key=$ROUTE_KEY
route_dir="/etc/sub2api-egress/routes/$ROUTE_KEY"
[[ ! -e $route_dir ]] || die "route_key already exists; route core policy is immutable"

python3 - "$stage/rendered/metadata.json" /etc/sub2api-egress/routes <<'PY'
import json, pathlib, sys
candidate = json.loads(pathlib.Path(sys.argv[1]).read_text())
ports = {candidate["socks_port"], candidate["api_port"]}
ports.update(item["probe_port"] for item in candidate["candidates"])
for path in pathlib.Path(sys.argv[2]).glob("*/metadata.json"):
    other = json.loads(path.read_text())
    if other["proxy_id"] == candidate["proxy_id"]:
        raise SystemExit("proxy_id is already owned by another Company route")
    other_ports = {other["socks_port"], other["api_port"]}
    other_ports.update(item["probe_port"] for item in other["candidates"])
    if ports & other_ports:
        raise SystemExit("local ports collide with another Company route")
PY

database=$(python3 - <<'PY'
import yaml
cfg = yaml.safe_load(open("/opt/sub2api/config.yaml", encoding="utf-8")) or {}
name = str((cfg.get("database") or {}).get("dbname") or "")
if not name.replace("_", "").isalnum():
    raise SystemExit("invalid database name")
print(name)
PY
)
[[ -n $database ]] || die "database name is missing"

existing=$(sudo -u postgres psql -X -At -d "$database" -c "SELECT id FROM proxies WHERE id=$PROXY_ID;")
[[ -z $existing ]] || die "proxy_id $PROXY_ID already exists"
collision=$(sudo -u postgres psql -X -At -d "$database" -c   "SELECT id FROM proxies WHERE deleted_at IS NULL AND host='127.0.0.1' AND port=$SOCKS_PORT LIMIT 1;")
[[ -z $collision ]] || die "SOCKS endpoint is already used by proxy_id $collision"

route_user="sub2api-egress-$ROUTE_KEY"
id "$route_user" >/dev/null 2>&1 ||
  useradd --system --no-create-home --shell /usr/sbin/nologin "$route_user"
id sub2api-egress-control >/dev/null 2>&1 ||
  useradd --system --no-create-home --shell /usr/sbin/nologin sub2api-egress-control
route_uid=$(id -u "$route_user")
control_uid=$(id -u sub2api-egress-control)

install -d -o root -g root -m 0711 /etc/sub2api-egress/routes "$route_dir"
install -o root -g "$route_user" -m 0640 "$stage/rendered/config.json" "$route_dir/config.json"
install -o root -g sub2api-egress-control -m 0640 "$stage/rendered/metadata.json" "$route_dir/metadata.json"
install -o root -g sub2api-egress-control -m 0640 "$stage/rendered/clash-api.secret" "$route_dir/clash-api.secret"
install -o root -g root -m 0600 "$stage/rendered/route.env" "$route_dir/route.env"
route_installed=1
python3 "$route_tool" guard --metadata "$route_dir/metadata.json" --uid "$route_uid" >"$route_dir/guard.nft"
chmod 0640 "$route_dir/guard.nft"
/opt/sub2api-egress/bin/sing-box check -c "$route_dir/config.json"
nft -c -f "$route_dir/guard.nft"

if [[ $(readlink -f "$route_tool") != /usr/local/sbin/company-route ]]; then
  install -o root -g root -m 0755 "$route_tool" /usr/local/sbin/company-route
fi

cat >/etc/sub2api-egress/route-control-guard.nft <<NFT
table inet sub2api_route_control_guard {
 chain output { type filter hook output priority 0; policy accept;
  meta skuid $control_uid meta nfproto ipv6 counter reject
  meta skuid $control_uid oifname "lo" counter accept
  meta skuid $control_uid counter reject
 }
}
NFT
chmod 0640 /etc/sub2api-egress/route-control-guard.nft
nft -c -f /etc/sub2api-egress/route-control-guard.nft

cat >/etc/systemd/system/sub2api-route-control-guard.service <<'UNIT'
[Unit]
Description=Sub2API route controller loopback-only guard
Before=sub2api-route-*-failover.service
[Service]
Type=oneshot
ExecStartPre=-/usr/sbin/nft delete table inet sub2api_route_control_guard
ExecStart=/usr/sbin/nft -f /etc/sub2api-egress/route-control-guard.nft
RemainAfterExit=yes
CapabilityBoundingSet=CAP_NET_ADMIN
RestrictAddressFamilies=AF_UNIX AF_NETLINK
[Install]
WantedBy=multi-user.target
UNIT

table_name="sub2api_${ROUTE_KEY//-/_}_guard"
guard_service="sub2api-route-$ROUTE_KEY-guard.service"
egress_service="sub2api-egress-$ROUTE_KEY.service"
failover_service="sub2api-route-$ROUTE_KEY-failover.service"
timer_service="sub2api-route-$ROUTE_KEY-failover.timer"

cat >"/etc/systemd/system/$guard_service" <<UNIT
[Unit]
Description=Sub2API $ROUTE_KEY exact-node egress guard
Before=$egress_service
[Service]
Type=oneshot
ExecStartPre=-/usr/sbin/nft delete table inet $table_name
ExecStart=/usr/sbin/nft -f $route_dir/guard.nft
RemainAfterExit=yes
CapabilityBoundingSet=CAP_NET_ADMIN
RestrictAddressFamilies=AF_UNIX AF_NETLINK
[Install]
WantedBy=multi-user.target
UNIT

cat >"/etc/systemd/system/$egress_service" <<UNIT
[Unit]
Description=Sub2API isolated $ROUTE_KEY egress
After=network-online.target $guard_service
Requires=$guard_service
Before=sub2api.service
[Service]
Type=simple
User=$route_user
Group=$route_user
StateDirectory=sub2api-egress-$ROUTE_KEY
ExecStartPre=/opt/sub2api-egress/bin/sing-box check -c $route_dir/config.json
ExecStart=/opt/sub2api-egress/bin/sing-box run -c $route_dir/config.json
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

cat >"/etc/systemd/system/$failover_service" <<UNIT
[Unit]
Description=Sub2API strict $ROUTE_KEY failover controller
After=$egress_service sub2api-route-control-guard.service
Requires=$egress_service sub2api-route-control-guard.service
[Service]
Type=oneshot
User=sub2api-egress-control
Group=sub2api-egress-control
StateDirectory=sub2api-route-control
ExecStart=/usr/local/sbin/company-route failover --route-key $ROUTE_KEY
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
RestrictAddressFamilies=AF_UNIX AF_INET
CapabilityBoundingSet=
UNIT

cat >"/etc/systemd/system/$timer_service" <<UNIT
[Unit]
Description=Sub2API $ROUTE_KEY strict failover timer
[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=$failover_service
[Install]
WantedBy=timers.target
UNIT

chmod 0644   /etc/systemd/system/sub2api-route-control-guard.service   "/etc/systemd/system/$guard_service"   "/etc/systemd/system/$egress_service"   "/etc/systemd/system/$failover_service"   "/etc/systemd/system/$timer_service"

systemctl daemon-reload
systemctl enable --now sub2api-route-control-guard.service
systemctl enable --now "$guard_service"
systemctl enable --now "$egress_service"
route_installed=1
systemctl start "$failover_service"

probe_a=$(curl --proto '=https' -fsS --connect-timeout 8 --max-time 20   --noproxy '' --proxy "socks5h://127.0.0.1:$SOCKS_PORT"   'https://api.ipify.org?format=json')
probe_b=$(curl --proto '=https' -fsS --connect-timeout 8 --max-time 20   --noproxy '' --proxy "socks5h://127.0.0.1:$SOCKS_PORT"   'https://cloudflare.com/cdn-cgi/trace')
observed=$(python3 - "$probe_a" "$probe_b" "$EXPECTED_EXIT_IPV4"   "$DISASTER_EXIT_IPV4" "$COUNTRY_CODE" <<'PY'
import ipaddress, json, sys
a = str(json.loads(sys.argv[1]).get("ip") or "")
trace = dict(line.split("=", 1) for line in sys.argv[2].splitlines() if "=" in line)
b = trace.get("ip", "")
allowed = {sys.argv[3]}
if sys.argv[4]:
    allowed.add(sys.argv[4])
for value in (a, b):
    ip = ipaddress.ip_address(value)
    if ip.version != 4 or str(ip) != value or not ip.is_global:
        raise SystemExit("non-public or non-canonical route evidence")
if a != b or a not in allowed or trace.get("loc") != sys.argv[5]:
    raise SystemExit("route exit evidence does not match policy")
print(a)
PY
)

install -o sub2api -g sub2api -m 0600 /opt/sub2api/config.yaml "$backup/config.yaml"
install -o root -g root -m 0640 /etc/sub2api-egress/sub2api/guard.nft "$backup/guard.nft"

new_config="$stage/config.yaml.new"
python3 - "$route_dir/metadata.json" /opt/sub2api/config.yaml "$new_config" <<'PY'
import json, pathlib, sys, yaml
route = json.loads(pathlib.Path(sys.argv[1]).read_text())
cfg = yaml.safe_load(pathlib.Path(sys.argv[2]).read_text()) or {}
company = cfg.setdefault("company_egress", {})
company["development_bypass"] = False
managed = company.setdefault("managed_proxies", [])
if any(int(item.get("proxy_id", 0)) == route["proxy_id"] for item in managed):
    raise SystemExit("proxy_id already exists in Company policy")
entry = {
    "proxy_id": route["proxy_id"],
    "class": "INTERNATIONAL_PROXY",
    "country_code": route["country_code"],
    "expected_exit_ipv4": route["expected_exit_ipv4"],
}
if route["disaster_exit_ipv4"]:
    entry["disaster_exit_ipv4"] = route["disaster_exit_ipv4"]
managed.append(entry)
managed.sort(key=lambda item: int(item["proxy_id"]))
cfg.setdefault("security", {}).setdefault("proxy_fallback", {})[
    "allow_direct_on_error"
] = False
pathlib.Path(sys.argv[3]).write_text(
    yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False), encoding="utf-8"
)
PY

proxy_name="Company $COUNTRY_CODE $ROUTE_KEY"
sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d "$database"   -v proxy_id="$PROXY_ID" -v proxy_name="$proxy_name" -v proxy_port="$SOCKS_PORT" <<'SQL'
INSERT INTO proxies (
  id,name,protocol,host,port,username,password,status,fallback_mode,
  backup_proxy_id,expires_at,created_at,updated_at,deleted_at
) VALUES (
  :proxy_id, :'proxy_name', 'socks5h', '127.0.0.1', :proxy_port,
  '', '', 'active', 'none', NULL, NULL, NOW(), NOW(), NULL
);
SELECT setval(pg_get_serial_sequence('proxies','id'),(SELECT max(id) FROM proxies),true);
SQL
proxy_registered=1

managed_ids=$(python3 - "$new_config" <<'PY'
import pathlib, sys, yaml
cfg = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text()) or {}
items = (cfg.get("company_egress") or {}).get("managed_proxies") or []
ids = [int(item.get("proxy_id", 0)) for item in items]
if not ids or len(ids) != len(set(ids)) or any(value <= 0 for value in ids):
    raise SystemExit("invalid managed proxy IDs")
print(",".join(map(str, ids)))
PY
)

ports=$(sudo -u postgres psql -X -At -F '|' -d "$database" -c   "SELECT id,protocol,host,port,status,COALESCE(username,''),COALESCE(password,''),fallback_mode,COALESCE(backup_proxy_id::text,''),COALESCE(expires_at::text,''),COALESCE(deleted_at::text,'') FROM proxies WHERE id IN ($managed_ids) ORDER BY id;")

port_list=""
row_count=0
while IFS='|' read -r id protocol host proxy_port status username password fallback backup_id expires deleted; do
  [[ -n $id ]] || continue
  row_count=$((row_count + 1))
  [[ $protocol == socks5h && $host == 127.0.0.1 && $status == active ]] ||
    die "managed proxy $id violates protocol/host/status policy"
  [[ -z $username && -z $password && $fallback == none && -z $backup_id && -z $expires && -z $deleted ]] ||
    die "managed proxy $id violates immutable policy"
  if [[ -z $port_list ]]; then port_list=$proxy_port; else port_list="$port_list, $proxy_port"; fi
done <<<"$ports"
expected_rows=$(awk -F, '{print NF}' <<<"$managed_ids")
[[ $row_count -eq $expected_rows ]] || die "one or more managed proxies are missing"

app_uid=$(id -u sub2api)
new_guard="$stage/app-guard.nft.new"
cat >"$new_guard" <<NFT
table inet sub2api_egress_guard {
 chain output { type filter hook output priority 0; policy accept;
  meta skuid $app_uid meta nfproto ipv6 counter reject
  meta skuid $app_uid udp dport 53 counter reject
  meta skuid $app_uid tcp dport 53 counter reject
  meta skuid $app_uid oifname "lo" ct state established,related counter accept
  meta skuid $app_uid oifname "lo" ip daddr 127.0.0.1 tcp dport { 5432, 6379, $port_list } counter accept
  meta skuid $app_uid counter reject
 }
}
NFT
nft -c -f "$new_guard"

systemctl stop sub2api.service
app_stopped=1
app_config_changed=1
install -o sub2api -g sub2api -m 0600 "$new_config" /opt/sub2api/config.yaml
install -o root -g root -m 0640 "$new_guard" /etc/sub2api-egress/sub2api/guard.nft
install -d -m 0755 /etc/systemd/system/sub2api.service.d
cat >"/etc/systemd/system/sub2api.service.d/30-company-route-$ROUTE_KEY.conf" <<UNIT
[Unit]
Requires=$egress_service
After=$egress_service
UNIT
systemctl daemon-reload
systemctl restart sub2api-egress-guard.service
systemctl enable --now "$timer_service"
systemctl start sub2api.service

healthy=0
for _ in $(seq 1 30); do
  if curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:8080/health >/dev/null; then
    healthy=1
    break
  fi
  sleep 1
done
[[ $healthy -eq 1 ]] || die "Sub2API did not become healthy"
app_stopped=0
pp_config_changed=0

trap - ERR INT TERM
cleanup_stage
echo "ROUTE_READY route=$ROUTE_KEY proxy_id=$PROXY_ID country=$COUNTRY_CODE exit_ipv4=$observed socks=127.0.0.1:$SOCKS_PORT"
echo "The uploaded subscription file is no longer needed after operator verification."
