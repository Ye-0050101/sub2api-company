#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "REFUSING: $*" >&2; return 1; }

[[ $(id -u) -eq 0 ]] || die "run as root"
[[ $(. /etc/os-release; echo "$ID:$VERSION_ID") == ubuntu:22.04 ]] ||
  die "Ubuntu 22.04 is required by this branch"
[[ $(dpkg --print-architecture) == amd64 ]] || die "amd64 is required"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl postgresql-common

if pg_lsclusters --no-header 2>/dev/null | grep -q .; then
  die "an existing PostgreSQL cluster was found; use a fresh VM"
fi

install -d -o root -g root -m 0755 /usr/share/postgresql-common/pgdg
curl --proto '=https' --tlsv1.2 --fail --show-error --location \
  --output /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
  https://www.postgresql.org/media/keys/ACCC4CF8.asc
chmod 0644 /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

cat >/etc/apt/sources.list.d/pgdg.sources <<'SOURCES'
Types: deb
URIs: https://apt.postgresql.org/pub/repos/apt
Suites: jammy-pgdg
Architectures: amd64
Components: main
Signed-By: /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
SOURCES
chmod 0644 /etc/apt/sources.list.d/pgdg.sources

apt-get update
apt-get install -y postgresql-16 postgresql-client-16 postgresql-contrib-16
systemctl enable --now postgresql.service

version_num=$(sudo -u postgres psql -X -Atqc 'SHOW server_version_num')
[[ $version_num =~ ^[0-9]+$ ]] || die "PostgreSQL server version is unreadable"
(( version_num >= 160000 && version_num < 170000 )) ||
  die "PostgreSQL 16 is required, got server_version_num=$version_num"

echo "POSTGRESQL_16_READY=1"
