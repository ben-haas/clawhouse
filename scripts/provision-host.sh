#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (or via sudo)." >&2
  exit 1
fi

if [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${OPENCLAW_BASE_DOMAIN:?Missing OPENCLAW_BASE_DOMAIN}"
: "${OPENCLAW_HOST_SHARD:?Missing OPENCLAW_HOST_SHARD}"
: "${OPENCLAW_ACME_EMAIL:?Missing OPENCLAW_ACME_EMAIL}"
: "${OPENCLAW_VERCEL_API_TOKEN:?Missing OPENCLAW_VERCEL_API_TOKEN}"
: "${OPENCLAW_TTYD_SECRET:?Missing OPENCLAW_TTYD_SECRET}"

OPENCLAW_SUBDOMAIN="${OPENCLAW_SUBDOMAIN:-openclaw}"
export OPENCLAW_WILDCARD_DOMAIN="${OPENCLAW_HOST_SHARD}.${OPENCLAW_SUBDOMAIN}.${OPENCLAW_BASE_DOMAIN}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

systemctl enable --now docker

if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-plugin
fi

mkdir -p /opt/traefik
touch /opt/traefik/acme.json
chmod 600 /opt/traefik/acme.json

# Ensure the network is always named `traefik_default` (matches instance labels).
docker compose -p traefik -f deploy/traefik/docker-compose.yml up -d --build

echo
echo "Traefik is up."
echo "Expected wildcard DNS (A record): *.${OPENCLAW_WILDCARD_DOMAIN} -> <this host IP>"
