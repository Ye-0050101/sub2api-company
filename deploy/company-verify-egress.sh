#!/usr/bin/env bash
set -Eeuo pipefail

expected_sha=""
socks_ports=""
us_socks_port=""
us_exit_ip=""
cn_socks_port=""
cn_exit_ip=""
public_domain=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha256) expected_sha=$2; shift ;;
    --socks-ports) socks_ports=$2; shift ;;
    --us-socks-port) us_socks_port=$2; shift ;;
    --us-exit-ip) us_exit_ip=$2; shift ;;
    --cn-socks-port) cn_socks_port=$2; shift ;;
    --cn-exit-ip) cn_exit_ip=$2; shift ;;
    --domain) public_domain=$2; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

probe_exit() {
  local label=$1 port=$2 probe_a_url=$3 expected_ip=$4 expected_country=$5
  local probe_a trace ip_a ip_b country
  probe_a=$(curl --proto '=https' -fsS --connect-timeout 8 --max-time 20 \
    --noproxy '' --proxy "socks5h://127.0.0.1:$port" "$probe_a_url") || return 1
  trace=$(curl --proto '=https' -fsS --connect-timeout 8 --max-time 20 \
    --noproxy '' --proxy "socks5h://127.0.0.1:$port" \
    https://cloudflare.com/cdn-cgi/trace) || return 1
  if [[ $probe_a_url == *format=json* ]]; then
    ip_a=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["ip"])' <<<"$probe_a") || return 1
  else
    ip_a=$(tr -d '[:space:]' <<<"$probe_a")
  fi
  ip_b=$(awk -F= '$1=="ip"{print $2}' <<<"$trace")
  country=$(awk -F= '$1=="loc"{print $2}' <<<"$trace")
  echo "INFO $label probe_a=$ip_a probe_b=$ip_b country=$country"
  [[ $ip_a == "$expected_ip" && $ip_b == "$expected_ip" && $country == "$expected_country" ]]
}

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

if [[ -n $us_socks_port || -n $us_exit_ip ]]; then
  check "US probe arguments complete" test -n "$us_socks_port" -a -n "$us_exit_ip"
  check "US egress service" systemctl is-active --quiet sub2api-egress-us-a.service
  check "US fixed exit" probe_exit US "$us_socks_port" \
    'https://api.ipify.org?format=json' "$us_exit_ip" US
fi

if [[ -n $cn_socks_port || -n $cn_exit_ip ]]; then
  check "CN probe arguments complete" test -n "$cn_socks_port" -a -n "$cn_exit_ip"
  check "CN egress service" systemctl is-active --quiet sub2api-egress-cn.service
  check "CN fixed exit" probe_exit CN "$cn_socks_port" \
    'https://api-ipv4.ip.sb/ip' "$cn_exit_ip" CN
fi

if [[ -n $public_domain ]]; then
  check "public HTTPS health" curl --proto '=https' -fsS --max-time 20 \
    "https://$public_domain/health"
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
