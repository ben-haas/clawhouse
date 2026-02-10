#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

INSTANCE_ID="${1:-}"
if [ -z "${INSTANCE_ID}" ]; then
  echo "Usage: $0 <instanceId>" >&2
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (or via sudo) because we write to /var/lib/openclaw and chown volumes." >&2
  exit 1
fi

if [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${OPENCLAW_BASE_DOMAIN:?Missing OPENCLAW_BASE_DOMAIN}"

OPENCLAW_DEPLOY_MODE="${OPENCLAW_DEPLOY_MODE:-traefik}"

if [ "${OPENCLAW_DEPLOY_MODE}" = "cloudflare-tunnel" ]; then
  WILDCARD_DOMAIN="${OPENCLAW_BASE_DOMAIN}"
else
  : "${OPENCLAW_HOST_SHARD:?Missing OPENCLAW_HOST_SHARD}"
  OPENCLAW_SUBDOMAIN="${OPENCLAW_SUBDOMAIN:-openclaw}"
  WILDCARD_DOMAIN="${OPENCLAW_HOST_SHARD}.${OPENCLAW_SUBDOMAIN}.${OPENCLAW_BASE_DOMAIN}"
fi

OPENCLAW_RUNTIME_IMAGE="${OPENCLAW_RUNTIME_IMAGE:-openclaw-ttyd:local}"
HOSTNAME="openclaw-${INSTANCE_ID}.${WILDCARD_DOMAIN}"
CONTAINER="openclaw-${INSTANCE_ID}"
DATA_DIR="/var/lib/openclaw/instances/${INSTANCE_ID}"

AUTH_URL="${OPENCLAW_AUTH_URL:-http://openclaw-forward-auth:8080/}"
NETWORK="${OPENCLAW_DOCKER_NETWORK:-traefik_default}"

CPU_LIMIT="${OPENCLAW_CPU_LIMIT:-2}"
MEMORY_RESERVATION="${OPENCLAW_MEMORY_RESERVATION:-4g}"
MEMORY_LIMIT="${OPENCLAW_MEMORY_LIMIT:-6g}"
PIDS_LIMIT="${OPENCLAW_PIDS_LIMIT:-512}"

mkdir -p "${DATA_DIR}"
chown 1000:1000 "${DATA_DIR}"

docker pull "${OPENCLAW_RUNTIME_IMAGE}" >/dev/null 2>&1 || true
if ! docker image inspect "${OPENCLAW_RUNTIME_IMAGE}" >/dev/null 2>&1; then
  echo "Image ${OPENCLAW_RUNTIME_IMAGE} not found; building from docker/openclaw-ttyd …"
  docker build -t "${OPENCLAW_RUNTIME_IMAGE}" docker/openclaw-ttyd
fi

# --- Select entrypoint and TLS labels based on deploy mode ---
if [ "${OPENCLAW_DEPLOY_MODE}" = "cloudflare-tunnel" ]; then
  ENTRYPOINT="web"
  MAIN_TLS_LABELS=()
  TERMINAL_TLS_LABELS=()
else
  ENTRYPOINT="websecure"
  MAIN_TLS_LABELS=(
    --label "traefik.http.routers.${CONTAINER}.tls=true"
    --label "traefik.http.routers.${CONTAINER}.tls.certresolver=le"
    --label "traefik.http.routers.${CONTAINER}.tls.domains[0].main=${WILDCARD_DOMAIN}"
    --label "traefik.http.routers.${CONTAINER}.tls.domains[0].sans=*.${WILDCARD_DOMAIN}"
  )
  TERMINAL_TLS_LABELS=(
    --label "traefik.http.routers.${CONTAINER}-terminal.tls=true"
    --label "traefik.http.routers.${CONTAINER}-terminal.tls.certresolver=le"
    --label "traefik.http.routers.${CONTAINER}-terminal.tls.domains[0].main=${WILDCARD_DOMAIN}"
    --label "traefik.http.routers.${CONTAINER}-terminal.tls.domains[0].sans=*.${WILDCARD_DOMAIN}"
  )
fi

docker run -d \
  --name "${CONTAINER}" \
  --restart unless-stopped \
  --network "${NETWORK}" \
  --cpus="${CPU_LIMIT}" \
  --memory-reservation="${MEMORY_RESERVATION}" \
  --memory="${MEMORY_LIMIT}" \
  --memory-swap="${MEMORY_LIMIT}" \
  --pids-limit="${PIDS_LIMIT}" \
  -v "${DATA_DIR}:/home/node/.openclaw" \
  --label 'traefik.enable=true' \
  --label "traefik.docker.network=${NETWORK}" \
  --label "traefik.http.routers.${CONTAINER}.rule=Host(\`${HOSTNAME}\`)" \
  --label "traefik.http.routers.${CONTAINER}.service=${CONTAINER}" \
  --label "traefik.http.routers.${CONTAINER}.entrypoints=${ENTRYPOINT}" \
  "${MAIN_TLS_LABELS[@]}" \
  --label "traefik.http.services.${CONTAINER}.loadbalancer.server.port=18789" \
  --label "traefik.http.routers.${CONTAINER}-terminal.rule=Host(\`${HOSTNAME}\`) && PathPrefix(\`/terminal\`)" \
  --label "traefik.http.routers.${CONTAINER}-terminal.service=${CONTAINER}-terminal" \
  --label "traefik.http.routers.${CONTAINER}-terminal.priority=100" \
  --label "traefik.http.routers.${CONTAINER}-terminal.entrypoints=${ENTRYPOINT}" \
  "${TERMINAL_TLS_LABELS[@]}" \
  --label "traefik.http.middlewares.${CONTAINER}-terminal-strip.stripprefix.prefixes=/terminal" \
  --label "traefik.http.middlewares.${CONTAINER}-terminal-strip.stripprefix.forceSlash=true" \
  --label "traefik.http.middlewares.${CONTAINER}-inject-id.headers.customrequestheaders.X-Openclaw-Instance-Id=${INSTANCE_ID}" \
  --label "traefik.http.middlewares.${CONTAINER}-auth.forwardauth.address=${AUTH_URL}" \
  --label "traefik.http.middlewares.${CONTAINER}-auth.forwardauth.trustForwardHeader=true" \
  --label "traefik.http.routers.${CONTAINER}-terminal.middlewares=${CONTAINER}-inject-id,${CONTAINER}-auth,${CONTAINER}-terminal-strip" \
  --label "traefik.http.services.${CONTAINER}-terminal.loadbalancer.server.port=7681" \
  "${OPENCLAW_RUNTIME_IMAGE}"

# --- Per-instance tunnel route + DNS (cloudflare-tunnel mode only) ---
if [ "${OPENCLAW_DEPLOY_MODE}" = "cloudflare-tunnel" ]; then
  : "${OPENCLAW_CLOUDFLARE_API_TOKEN:?Missing OPENCLAW_CLOUDFLARE_API_TOKEN}"
  : "${OPENCLAW_CLOUDFLARE_ZONE_ID:?Missing OPENCLAW_CLOUDFLARE_ZONE_ID}"

  INGRESS_FILE="/var/lib/openclaw/cloudflared/ingress.json"
  CONFIG_FILE="/var/lib/openclaw/cloudflared/config.yml"

  # Read tunnel ID from credentials written during provisioning
  CF_TUNNEL_ID=$(jq -r '.TunnelID' /var/lib/openclaw/cloudflared/credentials.json)

  # Upsert ingress rule (idempotent — removes existing rule for same hostname first)
  echo "Adding tunnel ingress rule for ${HOSTNAME}…"
  UPDATED_INGRESS=$(jq --arg hostname "${HOSTNAME}" --arg service "http://traefik:80" '
    [.[] | select(.hostname != $hostname)]
    | if (.[-1].hostname // null) == null then
        .[:-1] + [{"hostname": $hostname, "service": $service}] + .[-1:]
      else
        . + [{"hostname": $hostname, "service": $service}, {"service": "http_status:404"}]
      end
  ' "$INGRESS_FILE")
  echo "$UPDATED_INGRESS" > "$INGRESS_FILE"

  # Regenerate config.yml from ingress.json
  generate_cloudflared_config() {
    local tunnel_id="$1"
    {
      echo "tunnel: ${tunnel_id}"
      echo "credentials-file: /etc/cloudflared/credentials.json"
      echo "ingress:"
      jq -r '.[] | if .hostname then "  - hostname: \(.hostname)\n    service: \(.service)" else "  - service: \(.service)" end' "$INGRESS_FILE"
    } > "$CONFIG_FILE"
  }
  generate_cloudflared_config "$CF_TUNNEL_ID"

  docker restart cloudflared

  # Create per-instance CNAME DNS record
  CF_API="https://api.cloudflare.com/client/v4"
  AUTH_HEADER="Authorization: Bearer ${OPENCLAW_CLOUDFLARE_API_TOKEN}"
  TUNNEL_TARGET="${CF_TUNNEL_ID}.cfargotunnel.com"

  cf_check() {
    local response="$1" action="$2"
    if [ "$(echo "$response" | jq -r '.success // empty' 2>/dev/null)" != "true" ]; then
      echo "Cloudflare API error (${action}):" >&2
      echo "$response" | jq -r '.errors[]? | "  [\(.code)] \(.message)"' 2>/dev/null >&2
      echo "  Response: ${response}" >&2
      exit 1
    fi
  }

  echo "Creating DNS CNAME: ${HOSTNAME} -> ${TUNNEL_TARGET}"
  DNS_RESULT=$(curl -sS -X POST "${CF_API}/zones/${OPENCLAW_CLOUDFLARE_ZONE_ID}/dns_records" \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"${HOSTNAME}\",\"content\":\"${TUNNEL_TARGET}\",\"proxied\":true,\"ttl\":1}")
  cf_check "$DNS_RESULT" "create DNS record"
fi

echo
echo "Instance created: ${INSTANCE_ID}"
echo
echo "Dashboard URL:"
./scripts/dashboard-url.sh "${INSTANCE_ID}" || true
echo
echo "Terminal URL:"
./scripts/terminal-url.sh "${INSTANCE_ID}" || true
