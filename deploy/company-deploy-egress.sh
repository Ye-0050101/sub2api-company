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
if [[ $db_backup_confirmed -eq 1 ]]; then
  echo "INFO: --db-backup-confirmed is accepted for compatibility; a new verified backup is still mandatory"
fi
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
exec 8>/run/lock/sub2api-company-route.lock
flock -n 8 || { echo "A Company route operation is running" >&2; exit 1; }

database_name=$(python3 - /opt/sub2api/config.yaml <<'PY'
import re
import sys
import yaml

cfg = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
name = str((cfg.get("database") or {}).get("dbname") or "")
if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", name):
    raise SystemExit("database.dbname is missing or unsafe")
print(name)
PY
) || { echo "Refusing: cannot determine the application database" >&2; exit 1; }
backup_root=/var/backups/sub2api
backup_timestamp=$(date -u +%Y%m%dT%H%M%SZ)
database_backup="$backup_root/${database_name}-predeploy-${backup_timestamp}.dump"
database_backup_tmp="${database_backup}.tmp.$$"
install -d -o root -g postgres -m 0750 "$backup_root"
database_size_bytes=$(sudo -u postgres psql -X -At -d postgres \
  -c "SELECT pg_database_size('$database_name');")
[[ $database_size_bytes =~ ^[0-9]+$ ]] || {
  echo "Refusing: cannot determine PostgreSQL database size" >&2
  exit 1
}
available_bytes=$(df --output=avail -B1 "$backup_root" | tail -n 1 | tr -d ' ')
[[ $available_bytes =~ ^[0-9]+$ ]] || {
  echo "Refusing: cannot determine backup filesystem free space" >&2
  exit 1
}
minimum_backup_space=$((database_size_bytes * 2 + 64 * 1024 * 1024))
[[ $available_bytes -ge $minimum_backup_space ]] || {
  echo "Refusing: insufficient free space for a verified database backup" >&2
  echo "database_bytes=$database_size_bytes available_bytes=$available_bytes required_bytes=$minimum_backup_space" >&2
  exit 1
}
[[ ! -e $database_backup && ! -e $database_backup_tmp ]] || {
  echo "Refusing: database backup target already exists" >&2
  exit 1
}
install -o postgres -g postgres -m 0600 /dev/null "$database_backup_tmp"
if ! sudo -u postgres pg_dump --format=custom --no-owner --no-acl \
    --file "$database_backup_tmp" "$database_name"; then
  rm -f -- "$database_backup_tmp"
  echo "Refusing: PostgreSQL backup failed" >&2
  exit 1
fi
if ! pg_restore --list "$database_backup_tmp" >/dev/null; then
  rm -f -- "$database_backup_tmp"
  echo "Refusing: PostgreSQL backup validation failed" >&2
  exit 1
fi
chown root:root "$database_backup_tmp"
chmod 0600 "$database_backup_tmp"
mv -f "$database_backup_tmp" "$database_backup"
echo "DATABASE_BACKUP=$database_backup"
echo "DATABASE_BACKUP_SHA256=$(sha256sum "$database_backup" | awk '{print $1}')"

release_dir="/opt/sub2api/releases/${expected_sha}"
rollback_dir="/opt/sub2api/releases/rollback-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0755 "$release_dir" "$rollback_dir"
install -m 0755 "$binary" "$release_dir/sub2api"
cp -a /opt/sub2api/sub2api "$rollback_dir/sub2api"
cp -a /opt/sub2api/config.yaml "$rollback_dir/config.yaml"
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

rollback_running=0
new_binary_may_have_migrated=0
rollback() {
  trap - ERR INT TERM
  if [[ $rollback_running -eq 1 ]]; then
    exit 1
  fi
  rollback_running=1
  echo "Deployment failed; restoring previous binary, config, and operations tools" >&2
  echo "Database was not restored automatically; verified backup retained at: $database_backup" >&2
  systemctl stop sub2api.service >/dev/null 2>&1 || true
  install -m 0755 "$rollback_dir/sub2api" /opt/sub2api/.sub2api.company.rollback || true
  mv -f /opt/sub2api/.sub2api.company.rollback /opt/sub2api/sub2api || true
  cp -a "$rollback_dir/config.yaml" /opt/sub2api/config.yaml || true
  restore_ops || true
  if [[ $new_binary_may_have_migrated -eq 0 ]]; then
    systemctl restart sub2api.service || true
  else
    echo "Sub2API remains stopped because the new binary may have migrated the database." >&2
    echo "Restore the reported dump or explicitly verify old-binary schema compatibility before starting it." >&2
  fi
  exit 1
}
trap rollback ERR INT TERM

python3 - /opt/sub2api/config.yaml <<'PY' || rollback
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

install -m 0755 "$release_dir/sub2api" /opt/sub2api/.sub2api.company.new || rollback
mv -f /opt/sub2api/.sub2api.company.new /opt/sub2api/sub2api || rollback

new_binary_may_have_migrated=1
systemctl restart sub2api.service || rollback
for _ in $(seq 1 60); do
  if systemctl is-active --quiet sub2api.service && \
     curl --noproxy '*' --fail --silent --max-time 2 http://127.0.0.1:8080/health >/dev/null; then
    install_ops || rollback
    trap - ERR INT TERM
    echo "Sub2API deployment healthy: $expected_sha"
    [[ -z $ops_dir ]] || echo "Company operations updated: $ops_manifest_sha"
    exit 0
  fi
  sleep 1
done
rollback
