#!/usr/bin/env bash
set -Eeuo pipefail

output_dir=/root
database_name=jackye
stop_application=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) output_dir=$2; shift ;;
    --database) database_name=$2; shift ;;
    --stop-application) stop_application=1 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ $(id -u) -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
[[ $output_dir == /* && -d $output_dir ]] || { echo "Output directory must exist and be absolute" >&2; exit 2; }
[[ $database_name =~ ^[a-zA-Z0-9_]+$ ]] || { echo "Invalid database name" >&2; exit 2; }

for required in \
  /opt/sub2api/config.yaml \
  /opt/sub2api-egress/bin/sing-box \
  /etc/sub2api-egress/us-a/config.json \
  /etc/sub2api-egress/us-a/clash-api.secret \
  /usr/local/sbin/sub2api-us-a-failover \
  /etc/systemd/system/sub2api-egress-us-a.service \
  /etc/systemd/system/sub2api-us-a-failover.service \
  /etc/systemd/system/sub2api-us-a-failover.timer
do
  [[ -f $required ]] || { echo "Missing required migration input: $required" >&2; exit 1; }
done

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
stage=$(mktemp -d /root/sub2api-company-export.XXXXXX)
bundle="$output_dir/sub2api-company-migration-$timestamp.tar.gz"
application_was_stopped=0

cleanup() {
  case "$stage" in
    /root/sub2api-company-export.*) rm -rf -- "$stage" ;;
    *) echo "Refusing to clean unexpected path: $stage" >&2 ;;
  esac
}

restart_on_error() {
  trap - ERR
  cleanup
  if [[ $application_was_stopped -eq 1 ]]; then
    systemctl start sub2api.service || true
  fi
}
trap restart_on_error ERR
trap cleanup EXIT

if [[ $stop_application -eq 1 ]]; then
  systemctl stop sub2api.service
  for _ in $(seq 1 30); do
    state=$(systemctl is-active sub2api.service 2>/dev/null || true)
    [[ $state == inactive ]] && break
    sleep 1
  done
  [[ ${state:-} == inactive ]] || { echo "Sub2API did not stop" >&2; exit 1; }
  application_was_stopped=1
fi

install -d -m 0700 \
  "$stage/database" "$stage/application" "$stage/egress" \
  "$stage/systemd" "$stage/scripts" "$stage/optional-data"

sudo -u postgres pg_dump --format=custom --no-owner --no-acl "$database_name" >"$stage/database/$database_name.dump"
pg_restore --list "$stage/database/$database_name.dump" >/dev/null
chmod 0600 "$stage/database/$database_name.dump"

install -m 0600 /opt/sub2api/config.yaml "$stage/application/config.yaml"
install -m 0755 /opt/sub2api-egress/bin/sing-box "$stage/egress/sing-box"
install -m 0600 /etc/sub2api-egress/us-a/config.json "$stage/egress/us-a-config.json"
install -m 0600 /etc/sub2api-egress/us-a/clash-api.secret "$stage/egress/us-a-clash-api.secret"
install -m 0750 /usr/local/sbin/sub2api-us-a-failover "$stage/scripts/sub2api-us-a-failover"

for unit in sub2api-egress-us-a.service sub2api-us-a-failover.service sub2api-us-a-failover.timer; do
  install -m 0644 "/etc/systemd/system/$unit" "$stage/systemd/$unit"
done

for script in company-deploy-egress company-verify-egress; do
  [[ -f /usr/local/sbin/$script ]] && install -m 0755 "/usr/local/sbin/$script" "$stage/scripts/$script"
done

for source in /opt/sub2api/data /opt/sub2api/uploads /opt/sub2api/plugins /var/lib/sub2api; do
  if [[ -d $source ]]; then
    safe_name=$(sed 's#^/##; s#/#__#g' <<<"$source")
    cp -a -- "$source" "$stage/optional-data/$safe_name"
  fi
done

{
  echo "created_utc=$timestamp"
  echo "database=$database_name"
  echo "application_stopped=$stop_application"
  echo "source_binary_sha256=$(sha256sum /opt/sub2api/sub2api | awk '{print $1}')"
  echo "config_sha256=$(sha256sum /opt/sub2api/config.yaml | awk '{print $1}')"
  echo "database_sha256=$(sha256sum "$stage/database/$database_name.dump" | awk '{print $1}')"
  echo "singbox_sha256=$(sha256sum /opt/sub2api-egress/bin/sing-box | awk '{print $1}')"
} >"$stage/MANIFEST.txt"
chmod 0600 "$stage/MANIFEST.txt"

tar -czf "$bundle" -C "$stage" .
chmod 0600 "$bundle"

trap - ERR
echo "MIGRATION_BUNDLE=$bundle"
sha256sum "$bundle"
if [[ $application_was_stopped -eq 1 ]]; then
  echo "SOURCE_APPLICATION_STOPPED=1"
  echo "Rollback command: systemctl start sub2api.service"
fi
