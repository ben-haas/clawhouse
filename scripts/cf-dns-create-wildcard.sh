#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${OPENCLAW_CLOUDFLARE_API_TOKEN:?Missing OPENCLAW_CLOUDFLARE_API_TOKEN}"
: "${OPENCLAW_CLOUDFLARE_ZONE_ID:?Missing OPENCLAW_CLOUDFLARE_ZONE_ID}"
: "${OPENCLAW_CLOUDFLARE_TUNNEL_ID:?Missing OPENCLAW_CLOUDFLARE_TUNNEL_ID}"
: "${OPENCLAW_BASE_DOMAIN:?Missing OPENCLAW_BASE_DOMAIN}"
: "${OPENCLAW_HOST_SHARD:?Missing OPENCLAW_HOST_SHARD}"

OPENCLAW_SUBDOMAIN="${OPENCLAW_SUBDOMAIN:-openclaw}"

WILDCARD_NAME="*.${OPENCLAW_HOST_SHARD}.${OPENCLAW_SUBDOMAIN}.${OPENCLAW_BASE_DOMAIN}"
TUNNEL_TARGET="${OPENCLAW_CLOUDFLARE_TUNNEL_ID}.cfargotunnel.com"

echo "Creating DNS CNAME record:"
echo "  ${WILDCARD_NAME} -> ${TUNNEL_TARGET}"
echo

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
