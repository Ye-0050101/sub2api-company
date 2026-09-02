#!/usr/bin/env bash
set -Eeuo pipefail

binary=""
expected_sha=""
ops_dir=""
ops_manifest_sha=""
db_backup_confirmed=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) binary=$2; shift ;;
    --sha256) expected_sha=$2; shift ;;
    --ops-dir) ops_dir=$2; shift ;;
    --ops-sha256) ops_manifest_sha=$2; shift ;;
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
version_output=$("$binary" -version 2>&1 || true)
grep -Fq "company-" <<<"$version_output" || { echo "Refusing: binary is not a Company build" >&2; exit 1; }

required_ops=(company-deploy-egress company-verify-egress company-route company-route-add companyctl)
if [[ -n $ops_dir || -n $ops_manifest_sha ]]; then
  [[ $ops_dir == /* && -d $ops_dir && -n $ops_manifest_sha ]] || {
    echo "Refusing: --ops-dir and --ops-sha256 must be supplied together" >&2
    exit 1
  }
  [[ -f $ops_dir/SHA256SUMS ]] || { echo "Refusing: operations SHA256SUMS is missing" >&2; exit 1; }
  actual_ops_sha=$(sha256sum "$ops_dir/SHA256SUMS" | awk '{print $1}')
  [[ $actual_ops_sha == "$ops_manifest_sha" ]] || {
    echo "Refusing: operations manifest SHA256 mismatch" >&2
    exit 1
  }
  expected_files=$(printf '%s\n' "${required_ops[@]}" SHA256SUMS | sort)
  actual_files=$(find "$ops_dir" -mindepth 1 -maxdepth 1 -printf '%f
' | sort)
  [[ $actual_files == "$expected_files" ]] || {
    echo "Refusing: operations directory contains missing or unexpected files" >&2
    exit 1
  }
  [[ -z $(find "$ops_dir" -mindepth 1 -maxdepth 1 -type l -print -quit) ]] || {
    echo "Refusing: operations directory contains a symlink" >&2
    exit 1
  }
  manifest_names=$(awk 'NF == 2 && $1 ~ /^[0-9a-f]{64}$/ {print $2}' "$ops_dir/SHA256SUMS" | sort)
  expected_names=$(printf '%s\n' "${required_ops[@]}" | sort)
  [[ $manifest_names == "$expected_names" ]] || {
    echo "Refusing: operations manifest file set is invalid" >&2
    exit 1
  }
  (cd "$ops_dir" && sha256sum --strict -c SHA256SUMS) || {
    echo "Refusing: operations file SHA256 mismatch" >&2
    exit 1
  }
  bash -n "$ops_dir/company-deploy-egress" "$ops_dir/company-verify-egress" "$ops_dir/company-route-add"
  python3 - "$ops_dir/company-route" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding="utf-8")
compile(source, sys.argv[1], "exec")
PY
  python3 - "$ops_dir/companyctl" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding="utf-8")
compile(source, sys.argv[1], "exec")
PY
  github_pattern='https?://(github[.]com|raw[.]githubusercontent[.]com|api[.]github[.]com)|git[[:space:]]+clone'
  if grep -ERq "$github_pattern" "$ops_dir"; then
    echo "Refusing: server operations artifact must not access GitHub" >&2
    exit 1
  fi
fi

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
ops_backup_ready=0
if [[ -n $ops_dir ]]; then
  install -d -m 0755 "$rollback_dir/ops"
  for name in "${required_ops[@]}"; do
    if [[ -f /usr/local/sbin/$name ]]; then
      cp -a "/usr/local/sbin/$name" "$rollback_dir/ops/$name"
    fi
  done
  ops_backup_ready=1
fi

install -m 0755 "$release_dir/sub2api" /opt/sub2api/.sub2api.company.new
mv -f /opt/sub2api/.sub2api.company.new /opt/sub2api/sub2api

restore_ops() {
  [[ $ops_backup_ready -eq 1 ]] || return 0
  for name in "${required_ops[@]}"; do
    if [[ -f $rollback_dir/ops/$name ]]; then
      install -m 0755 "$rollback_dir/ops/$name" "/usr/local/sbin/.$name.company.rollback" || return 1
      mv -f "/usr/local/sbin/.$name.company.rollback" "/usr/local/sbin/$name" || return 1
    else
      rm -f "/usr/local/sbin/$name"
    fi
  done
}

install_ops() {
  [[ -n $ops_dir ]] || return 0
  for name in "${required_ops[@]}"; do
    install -m 0755 "$ops_dir/$name" "/usr/local/sbin/.$name.company.new" || return 1
    mv -f "/usr/local/sbin/.$name.company.new" "/usr/local/sbin/$name" || return 1
  done
}

rollback() {
  echo "Deployment failed; restoring previous binary and operations tools" >&2
  install -m 0755 "$rollback_dir/sub2api" /opt/sub2api/.sub2api.company.rollback
  mv -f /opt/sub2api/.sub2api.company.rollback /opt/sub2api/sub2api
  restore_ops || true
  systemctl restart sub2api.service || true
  exit 1
}

systemctl restart sub2api.service || rollback
for _ in $(seq 1 60); do
  if systemctl is-active --quiet sub2api.service && \
     curl --noproxy '*' --fail --silent --max-time 2 http://127.0.0.1:8080/health >/dev/null; then
    install_ops || rollback
    echo "Sub2API deployment healthy: $expected_sha"
    [[ -z $ops_dir ]] || echo "Company operations updated: $ops_manifest_sha"
    exit 0
  fi
  sleep 1
done
rollback
