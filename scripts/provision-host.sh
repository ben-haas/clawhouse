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
else
  : "${OPENCLAW_ACME_EMAIL:?Missing OPENCLAW_ACME_EMAIL}"
  : "${OPENCLAW_VERCEL_API_TOKEN:?Missing OPENCLAW_VERCEL_API_TOKEN}"
fi

# --- Common: install Docker & compose plugin ---
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl gnupg jq lsb-release

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
generate_cloudflared_config() {
  local tunnel_id="$1"
  local ingress_file="/var/lib/openclaw/cloudflared/ingress.json"
  local config_file="/var/lib/openclaw/cloudflared/config.yml"

  {
    echo "tunnel: ${tunnel_id}"
    echo "credentials-file: /etc/cloudflared/credentials.json"
    echo "ingress:"
    jq -r '.[] | if .hostname then "  - hostname: \(.hostname)\n    service: \(.service)" else "  - service: \(.service)" end' "$ingress_file"
  } > "$config_file"
}

if [ "${OPENCLAW_DEPLOY_MODE}" = "cloudflare-tunnel" ]; then
  # Decode tunnel token and set up local cloudflared config
  TUNNEL_JSON=$(echo "${OPENCLAW_CLOUDFLARE_TUNNEL_TOKEN}" | base64 -d)
  CF_ACCOUNT_TAG=$(echo "${TUNNEL_JSON}" | jq -r '.a')
  CF_TUNNEL_ID=$(echo "${TUNNEL_JSON}" | jq -r '.t')
  CF_TUNNEL_SECRET=$(echo "${TUNNEL_JSON}" | jq -r '.s')

  mkdir -p /var/lib/openclaw/cloudflared

  jq -n \
    --arg acct "$CF_ACCOUNT_TAG" \
    --arg tid "$CF_TUNNEL_ID" \
    --arg sec "$CF_TUNNEL_SECRET" \
    '{ AccountTag: $acct, TunnelID: $tid, TunnelSecret: $sec }' \
    > /var/lib/openclaw/cloudflared/credentials.json

  if [ ! -f /var/lib/openclaw/cloudflared/ingress.json ]; then
    echo '[{"service":"http_status:404"}]' > /var/lib/openclaw/cloudflared/ingress.json
  fi

  generate_cloudflared_config "$CF_TUNNEL_ID"

  # Ensure the network is always named `traefik_default` (matches instance labels).
  docker compose -p traefik --env-file .env -f deploy/cloudflare-tunnel/docker-compose.yml up -d --build

  echo
  echo "Traefik + cloudflared are up."
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
