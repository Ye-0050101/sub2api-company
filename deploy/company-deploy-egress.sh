#!/usr/bin/env bash
set -Eeuo pipefail

binary=""
expected_sha=""
db_backup_confirmed=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) binary=$2; shift ;;
    --sha256) expected_sha=$2; shift ;;
    --db-backup-confirmed) db_backup_confirmed=1 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ $(id -u) -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
[[ $db_backup_confirmed -eq 1 ]] || {
  echo "Refusing: confirm a current database backup first" >&2
  exit 1
}
[[ -f $binary && -n $expected_sha ]] || { echo "Binary and SHA256 are required" >&2; exit 2; }

actual_sha=$(sha256sum "$binary" | awk '{print $1}')
[[ $actual_sha == "$expected_sha" ]] || { echo "Binary SHA256 mismatch" >&2; exit 1; }

service_user=$(systemctl show sub2api.service -p User --value)
service_group=$(systemctl show sub2api.service -p Group --value)
working_dir=$(systemctl show sub2api.service -p WorkingDirectory --value)
exec_start=$(systemctl show sub2api.service -p ExecStart --value)
[[ $service_user == "sub2api" && $service_group == "sub2api" ]] || {
  echo "Refusing: sub2api.service identity changed" >&2
  exit 1
}
[[ $working_dir == "/opt/sub2api" && $exec_start == *"/opt/sub2api/sub2api"* ]] || {
  echo "Refusing: sub2api.service paths changed" >&2
  exit 1
}

guard_rules=$(nft list table inet sub2api_egress_guard 2>/dev/null) || {
  echo "Refusing: nftables table inet sub2api_egress_guard is missing" >&2
  exit 1
}
sub2api_uid=$(id -u sub2api)
grep -Eq "meta skuid[[:space:]]+(${sub2api_uid}|sub2api)" <<<"$guard_rules" || {
  echo "Refusing: nftables guard does not bind the Sub2API UID" >&2
  exit 1
}
grep -Eq "(drop|reject)" <<<"$guard_rules" || { echo "Refusing: guard has no deny rule" >&2; exit 1; }
grep -Eq "(ip6|nfproto ipv6)" <<<"$guard_rules" || { echo "Refusing: IPv6 deny evidence is missing" >&2; exit 1; }
grep -Eq "(udp|tcp)[[:space:]]+dport[[:space:]]+53" <<<"$guard_rules" || {
  echo "Refusing: direct DNS deny evidence is missing" >&2
  exit 1
}

exec 9>/run/lock/sub2api-company-deploy.lock
flock -n 9 || { echo "Another company deployment is running" >&2; exit 1; }

release_dir="/opt/sub2api/releases/${expected_sha}"
rollback_dir="/opt/sub2api/releases/rollback-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0755 "$release_dir" "$rollback_dir"
install -m 0755 "$binary" "$release_dir/sub2api"
cp -a /opt/sub2api/sub2api "$rollback_dir/sub2api"

install -m 0755 "$release_dir/sub2api" /opt/sub2api/.sub2api.company.new
mv -f /opt/sub2api/.sub2api.company.new /opt/sub2api/sub2api

rollback() {
  echo "Deployment health check failed; restoring previous binary" >&2
  install -m 0755 "$rollback_dir/sub2api" /opt/sub2api/.sub2api.company.rollback
  mv -f /opt/sub2api/.sub2api.company.rollback /opt/sub2api/sub2api
  systemctl restart sub2api.service || true
  exit 1
}

systemctl restart sub2api.service || rollback
for _ in $(seq 1 20); do
  if systemctl is-active --quiet sub2api.service && \
     curl --noproxy '*' --fail --silent --max-time 2 http://127.0.0.1:8080/health >/dev/null; then
    echo "Sub2API deployment healthy: $expected_sha"
    exit 0
  fi
  sleep 1
done
rollback
