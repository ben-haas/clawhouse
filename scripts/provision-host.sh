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

OPENCLAW_DEPLOY_MODE="${OPENCLAW_DEPLOY_MODE:-traefik}"

# --- Vars required in ALL modes ---
: "${OPENCLAW_BASE_DOMAIN:?Missing OPENCLAW_BASE_DOMAIN}"
: "${OPENCLAW_TTYD_SECRET:?Missing OPENCLAW_TTYD_SECRET}"

if [ "${OPENCLAW_DEPLOY_MODE}" = "cloudflare-tunnel" ]; then
  export OPENCLAW_WILDCARD_DOMAIN="${OPENCLAW_BASE_DOMAIN}"
else
  : "${OPENCLAW_HOST_SHARD:?Missing OPENCLAW_HOST_SHARD}"
  OPENCLAW_SUBDOMAIN="${OPENCLAW_SUBDOMAIN:-openclaw}"
  export OPENCLAW_WILDCARD_DOMAIN="${OPENCLAW_HOST_SHARD}.${OPENCLAW_SUBDOMAIN}.${OPENCLAW_BASE_DOMAIN}"
fi

# --- Mode-specific validation ---
if [ "${OPENCLAW_DEPLOY_MODE}" = "cloudflare-tunnel" ]; then
  : "${OPENCLAW_CLOUDFLARE_TUNNEL_TOKEN:?Missing OPENCLAW_CLOUDFLARE_TUNNEL_TOKEN}"
  : "${OPENCLAW_CLOUDFLARE_API_TOKEN:?Missing OPENCLAW_CLOUDFLARE_API_TOKEN}"
  : "${OPENCLAW_CLOUDFLARE_ZONE_ID:?Missing OPENCLAW_CLOUDFLARE_ZONE_ID}"
  : "${OPENCLAW_CLOUDFLARE_TUNNEL_ID:?Missing OPENCLAW_CLOUDFLARE_TUNNEL_ID}"
else
  : "${OPENCLAW_ACME_EMAIL:?Missing OPENCLAW_ACME_EMAIL}"
  : "${OPENCLAW_VERCEL_API_TOKEN:?Missing OPENCLAW_VERCEL_API_TOKEN}"
fi

# --- Common: install Docker & compose plugin ---
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release

if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
fi

systemctl enable --now docker

# Ensure the Docker daemon accepts API v1.24+ (Traefik v3.x hardcodes v1.24)
DAEMON_JSON="/etc/docker/daemon.json"
if [[ ! -s "${DAEMON_JSON}" ]] || [[ "$(tr -d ' \n\t' < "${DAEMON_JSON}" 2>/dev/null || echo '')" == "{}" ]]; then
  tee "${DAEMON_JSON}" >/dev/null <<'JSON'
{
  "min-api-version": "1.24"
}
JSON
  systemctl restart docker
fi

if ! docker compose version >/dev/null 2>&1; then
  apt-get install -y docker-compose-plugin
fi

# --- Mode-specific setup ---
if [ "${OPENCLAW_DEPLOY_MODE}" = "cloudflare-tunnel" ]; then
  # Ensure the network is always named `traefik_default` (matches instance labels).
  docker compose -p traefik --env-file .env -f deploy/cloudflare-tunnel/docker-compose.yml up -d --build

  # --- Create wildcard DNS record pointing to the tunnel ---
  WILDCARD_NAME="*.${OPENCLAW_BASE_DOMAIN}"
  TUNNEL_TARGET="${OPENCLAW_CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com"

  echo
  echo "Traefik + cloudflared are up."
  echo "Creating wildcard DNS CNAME: ${WILDCARD_NAME} -> ${TUNNEL_TARGET}"

  RESPONSE=$(curl -sS -X POST \
    "https://api.cloudflare.com/client/v4/zones/${OPENCLAW_CLOUDFLARE_ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${OPENCLAW_CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{
      \"type\": \"CNAME\",
      \"name\": \"${WILDCARD_NAME}\",
      \"content\": \"${TUNNEL_TARGET}\",
      \"proxied\": true,
      \"ttl\": 1
    }")

  echo "${RESPONSE}"
else
  mkdir -p /opt/traefik
  touch /opt/traefik/acme.json
  chmod 600 /opt/traefik/acme.json

  # Ensure the network is always named `traefik_default` (matches instance labels).
  docker compose -p traefik --env-file .env -f deploy/traefik/docker-compose.yml up -d --build

  echo
  echo "Traefik is up."
  echo "Expected wildcard DNS (A record): *.${OPENCLAW_WILDCARD_DOMAIN} -> <this host IP>"
fi
