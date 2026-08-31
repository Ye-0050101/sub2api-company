#!/usr/bin/env bash
set -Eeuo pipefail

expected_sha=""
socks_ports=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha256) expected_sha=$2; shift ;;
    --socks-ports) socks_ports=$2; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

failures=0
check() {
  local label=$1
  shift
  if "$@"; then echo "PASS $label"; else echo "FAIL $label"; failures=$((failures + 1)); fi
}

check "sub2api.service active" systemctl is-active --quiet sub2api.service
check "service user" test "$(systemctl show sub2api.service -p User --value)" = "sub2api"
check "service group" test "$(systemctl show sub2api.service -p Group --value)" = "sub2api"
check "binary exists" test -x /opt/sub2api/sub2api

binary_sha=$(sha256sum /opt/sub2api/sub2api | awk '{print $1}')
echo "INFO binary_sha256=$binary_sha"
if [[ -n $expected_sha ]]; then
  check "binary SHA256" test "$binary_sha" = "$expected_sha"
fi

for candidate in /opt/sub2api/config.yaml /opt/sub2api/.env; do
  if [[ -f $candidate ]]; then
    echo "INFO config_sha256[$candidate]=$(sha256sum "$candidate" | awk '{print $1}')"
  fi
done

guard_rules=$(nft list table inet sub2api_egress_guard 2>/dev/null || true)
sub2api_uid=$(id -u sub2api)
check "nftables guard table" test -n "$guard_rules"
check "UID kill-switch" grep -Eq "meta skuid[[:space:]]+(${sub2api_uid}|sub2api)" <<<"$guard_rules"
check "deny rule" grep -Eq "(drop|reject)" <<<"$guard_rules"
check "IPv6 deny" grep -Eq "(ip6|nfproto ipv6)" <<<"$guard_rules"
check "direct DNS deny" grep -Eq "(udp|tcp)[[:space:]]+dport[[:space:]]+53" <<<"$guard_rules"

if [[ -n $socks_ports ]]; then
  IFS=',' read -r -a ports <<<"$socks_ports"
  listeners=$(ss -H -lnt)
  for port in "${ports[@]}"; do
    check "SOCKS listener 127.0.0.1:$port" grep -Eq "127\\.0\\.0\\.1:${port}[[:space:]]" <<<"$listeners"
  done
fi

echo "INFO current Sub2API TCP connections:"
ss -H -ntp | grep -F '"sub2api"' || true

[[ $failures -eq 0 ]] || exit 1
