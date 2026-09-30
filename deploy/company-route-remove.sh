#!/usr/bin/env bash
set -Eeuo pipefail

route_key=${1:-}
die() { echo "REFUSING: $*" >&2; return 1; }

[[ $(id -u) -eq 0 ]] || die "run as root"
[[ $route_key =~ ^[a-z][a-z0-9-]{1,15}$ ]] || die "route key is invalid"
[[ $route_key != us-a ]] || die "the us-a control route cannot be removed"
[[ -f /opt/sub2api/config.yaml ]] || die "Sub2API config is missing"
systemctl is-active --quiet sub2api.service || die "Sub2API must be healthy before removing a route"

exec 9>/run/lock/sub2api-company-route.lock
flock -n 9 || die "another Company route operation is running"

route_dir="/etc/sub2api-egress/routes/$route_key"
[[ -d $route_dir && -f $route_dir/metadata.json ]] || die "managed route does not exist"

values=$(python3 - "$route_dir/metadata.json" "$route_key" <<'PY'
import json, pathlib, sys
route = json.loads(pathlib.Path(sys.argv[1]).read_text())
if route.get("route_key") != sys.argv[2]:
    raise SystemExit("installed route metadata identity is inconsistent")
for key in ("proxy_id", "socks_port", "api_port"):
    value = route.get(key)
    if not isinstance(value, int) or value <= 0:
        raise SystemExit(f"invalid installed {key}")
print(route["proxy_id"], route["socks_port"], route["api_port"], route.get("country_code", ""), sep="|")
PY
)
IFS='|' read -r proxy_id socks_port api_port country_code <<<"$values"

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

account_refs=$(sudo -u postgres psql -X -At -d "$database" -c "SELECT count(*) FROM accounts WHERE proxy_id=$proxy_id;")
[[ $account_refs == 0 ]] || die "proxy_id $proxy_id is still referenced by $account_refs account row(s)"
backup_refs=$(sudo -u postgres psql -X -At -d "$database" -c "SELECT count(*) FROM proxies WHERE backup_proxy_id=$proxy_id AND deleted_at IS NULL;")
[[ $backup_refs == 0 ]] || die "proxy_id $proxy_id is still referenced as a backup proxy"
immutable=$(sudo -u postgres psql -X -At -F '|' -d "$database" -c \
  "SELECT protocol,host,port,status,COALESCE(username,''),COALESCE(password,''),fallback_mode,COALESCE(backup_proxy_id::text,''),COALESCE(expires_at::text,''),COALESCE(deleted_at::text,'') FROM proxies WHERE id=$proxy_id;")
[[ $immutable == "socks5h|127.0.0.1|$socks_port|active|||none|||" ]] ||
  die "managed proxy $proxy_id violates immutable removal policy"

install -d -o root -g root -m 0700 /var/backups/sub2api
backup=$(mktemp -d /var/backups/sub2api/route-remove.XXXXXX)
work=$(mktemp -d /etc/sub2api-egress/.route-remove.XXXXXX)
state_path="/var/lib/sub2api-route-control/$route_key.json"
table_name="sub2api_${route_key//-/_}_guard"
dropin="/etc/systemd/system/sub2api.service.d/30-company-route-$route_key.conf"

cp -a "$route_dir" "$backup/route"
install -o sub2api -g sub2api -m 0600 /opt/sub2api/config.yaml "$backup/config.yaml"
install -o root -g root -m 0640 /etc/sub2api-egress/sub2api/guard.nft "$backup/guard.nft"
[[ ! -f $state_path ]] || cp -a "$state_path" "$backup/state.json"
install -d -m 0700 "$backup/systemd"
for unit in \
  "sub2api-route-$route_key-guard.service" \
  "sub2api-egress-$route_key.service" \
  "sub2api-route-$route_key-failover.service" \
  "sub2api-route-$route_key-failover.timer"; do
  [[ ! -f /etc/systemd/system/$unit ]] || cp -a "/etc/systemd/system/$unit" "$backup/systemd/$unit"
done
[[ ! -f $dropin ]] || cp -a "$dropin" "$backup/systemd/sub2api-dropin.conf"

python3 - "$route_dir/metadata.json" /opt/sub2api/config.yaml "$work/config.yaml.new" <<'PY'
import json, pathlib, sys, yaml
route = json.loads(pathlib.Path(sys.argv[1]).read_text())
cfg = yaml.safe_load(pathlib.Path(sys.argv[2]).read_text()) or {}
if route["route_key"] == "us-a":
    raise SystemExit("the us-a control route cannot be removed")
company = cfg.setdefault("company_egress", {})
managed = company.setdefault("managed_proxies", [])
indexes = [i for i, item in enumerate(managed) if int(item.get("proxy_id", 0)) == route["proxy_id"]]
if len(indexes) != 1 or str(managed[indexes[0]].get("class") or "") != "INTERNATIONAL_PROXY":
    raise SystemExit("managed route policy is missing or ambiguous")
del managed[indexes[0]]
cfg.setdefault("security", {}).setdefault("proxy_fallback", {})["allow_direct_on_error"] = False
pathlib.Path(sys.argv[3]).write_text(yaml.safe_dump(cfg, allow_unicode=True, sort_keys=False), encoding="utf-8")
PY

managed_ids=$(python3 - "$work/config.yaml.new" <<'PY'
import pathlib, sys, yaml
cfg = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text()) or {}
items = (cfg.get("company_egress") or {}).get("managed_proxies") or []
ids = [int(item.get("proxy_id", 0)) for item in items]
if not ids or len(ids) != len(set(ids)) or any(value <= 0 for value in ids):
    raise SystemExit("invalid remaining managed proxy IDs")
print(",".join(map(str, ids)))
PY
)
ports=$(sudo -u postgres psql -X -At -F '|' -d "$database" -c \
  "SELECT id,protocol,host,port,status,COALESCE(username,''),COALESCE(password,''),fallback_mode,COALESCE(backup_proxy_id::text,''),COALESCE(expires_at::text,''),COALESCE(deleted_at::text,'') FROM proxies WHERE id IN ($managed_ids) ORDER BY id;")
port_list=""
row_count=0
while IFS='|' read -r id protocol host proxy_port status username password fallback backup_id expires deleted; do
  [[ -n $id ]] || continue
  row_count=$((row_count + 1))
  [[ $protocol == socks5h && $host == 127.0.0.1 && $status == active ]] || die "remaining managed proxy $id violates policy"
  [[ -z $username && -z $password && $fallback == none && -z $backup_id && -z $expires && -z $deleted ]] || die "remaining managed proxy $id violates immutable policy"
  if [[ -z $port_list ]]; then port_list=$proxy_port; else port_list="$port_list, $proxy_port"; fi
done <<<"$ports"
expected_rows=$(awk -F, '{print NF}' <<<"$managed_ids")
[[ $row_count -eq $expected_rows ]] || die "one or more remaining managed proxies are missing"

app_uid=$(id -u sub2api)
cat >"$work/guard.nft.new" <<NFT
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
nft -c -f "$work/guard.nft.new"

proxy_soft_deleted=0
rollback() {
  trap - ERR INT TERM
  echo "Route removal failed; restoring the previous route and application state" >&2
  systemctl stop sub2api.service >/dev/null 2>&1 || true
  if [[ $proxy_soft_deleted -eq 1 ]]; then
    sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d "$database" -c \
      "UPDATE proxies SET status='active',deleted_at=NULL,updated_at=NOW() WHERE id=$proxy_id;" >/dev/null 2>&1 || true
  fi
  install -o sub2api -g sub2api -m 0600 "$backup/config.yaml" /opt/sub2api/config.yaml || true
  install -o root -g root -m 0640 "$backup/guard.nft" /etc/sub2api-egress/sub2api/guard.nft || true
  rm -rf -- "$route_dir"
  cp -a "$backup/route" "$route_dir" || true
  for saved in "$backup"/systemd/sub2api-route-* "$backup"/systemd/sub2api-egress-*; do
    [[ -f $saved ]] || continue
    cp -a "$saved" "/etc/systemd/system/$(basename "$saved")" || true
  done
  if [[ -f $backup/systemd/sub2api-dropin.conf ]]; then
    install -d -m 0755 /etc/systemd/system/sub2api.service.d
    cp -a "$backup/systemd/sub2api-dropin.conf" "$dropin" || true
  fi
  if [[ -f $backup/state.json ]]; then
    install -o sub2api-egress-control -g sub2api-egress-control -m 0640 "$backup/state.json" "$state_path" || true
  fi
  systemctl daemon-reload || true
  systemctl restart sub2api-egress-guard.service || true
  systemctl enable --now "sub2api-route-$route_key-guard.service" || true
  systemctl enable --now "sub2api-egress-$route_key.service" || true
  systemctl start "sub2api-route-$route_key-failover.service" || true
  systemctl enable --now "sub2api-route-$route_key-failover.timer" || true
  systemctl start sub2api.service || true
  rm -rf -- "$work"
}
trap rollback ERR INT TERM

systemctl stop sub2api.service
systemctl disable --now "sub2api-route-$route_key-failover.timer"
systemctl stop "sub2api-route-$route_key-failover.service" >/dev/null 2>&1 || true
systemctl disable --now "sub2api-egress-$route_key.service"
systemctl disable --now "sub2api-route-$route_key-guard.service"
install -o sub2api -g sub2api -m 0600 "$work/config.yaml.new" /opt/sub2api/config.yaml
install -o root -g root -m 0640 "$work/guard.nft.new" /etc/sub2api-egress/sub2api/guard.nft
rm -f -- "$dropin"
systemctl daemon-reload
systemctl restart sub2api-egress-guard.service
systemctl start sub2api.service
healthy=0
for _ in $(seq 1 30); do
  if curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:8080/health >/dev/null; then
    healthy=1
    break
  fi
  sleep 1
done
[[ $healthy -eq 1 ]] || die "Sub2API did not become healthy after route removal"

changed=$(sudo -u postgres psql -X -qAt -v ON_ERROR_STOP=1 -d "$database" -c \
  "UPDATE proxies SET status='inactive',deleted_at=NOW(),updated_at=NOW() WHERE id=$proxy_id AND deleted_at IS NULL AND NOT EXISTS (SELECT 1 FROM accounts WHERE proxy_id=$proxy_id) RETURNING id;")
proxy_soft_deleted=1
[[ $changed == "$proxy_id" ]] || die "proxy row was not safely soft-deleted"

nft list table inet "$table_name" >/dev/null 2>&1 && nft delete table inet "$table_name"
rm -rf -- "$route_dir"
rm -f -- "$state_path" \
  "/etc/systemd/system/sub2api-route-$route_key-guard.service" \
  "/etc/systemd/system/sub2api-egress-$route_key.service" \
  "/etc/systemd/system/sub2api-route-$route_key-failover.service" \
  "/etc/systemd/system/sub2api-route-$route_key-failover.timer"
systemctl daemon-reload
systemctl is-active --quiet sub2api.service
curl --noproxy '*' -fsS --max-time 5 http://127.0.0.1:8080/health >/dev/null

trap - ERR INT TERM
rm -rf -- "$work"
echo "ROUTE_REMOVED route=$route_key proxy_id=$proxy_id country=$country_code socks=127.0.0.1:$socks_port backup=$backup"
