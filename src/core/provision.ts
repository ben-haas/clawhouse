import { buildTraefikComposeYaml, TraefikComposeInput } from './traefik';
import { buildCloudflareTunnelComposeYaml, CloudflareTunnelComposeInput } from './cloudflared';
import { DeployMode } from './deployMode';

export type ProvisionScriptInput =
  | {
      deployMode?: 'traefik';
      traefikCompose: TraefikComposeInput;
      openclawRuntimeImage?: string;
      composePath?: string;
    }
  | {
      deployMode: 'cloudflare-tunnel';
      cloudflareTunnelCompose: CloudflareTunnelComposeInput;
      cloudflareDns: {
        apiToken: string;
        zoneId: string;
        tunnelId: string;
        baseDomain: string;
      };
      openclawRuntimeImage?: string;
      composePath?: string;
    };

export function buildProvisionScript(input: ProvisionScriptInput): string {
  const deployMode: DeployMode = input.deployMode || 'traefik';
  const composePath = input.composePath || '/opt/traefik/docker-compose.yml';
  const sudoLiteral = '${SUDO}';
  const dockerPull = input.openclawRuntimeImage ? `${sudoLiteral} docker pull ${input.openclawRuntimeImage}` : '';

  const composeYaml = deployMode === 'cloudflare-tunnel'
    ? buildCloudflareTunnelComposeYaml((input as { cloudflareTunnelCompose: CloudflareTunnelComposeInput }).cloudflareTunnelCompose)
    : buildTraefikComposeYaml((input as { traefikCompose: TraefikComposeInput }).traefikCompose);

  const commonSteps = [
    'set -euo pipefail',
    'export DEBIAN_FRONTEND=noninteractive',
    'if [ "$(id -u)" -ne 0 ]; then SUDO="sudo -n"; else SUDO=""; fi',
    '${SUDO} apt-get update -y',
    '${SUDO} apt-get install -y ca-certificates curl gnupg lsb-release',
    'if ! command -v docker >/dev/null 2>&1; then curl -fsSL https://get.docker.com | ${SUDO} sh; fi',
    '${SUDO} systemctl enable --now docker',
    'if ! docker compose version >/dev/null 2>&1; then ${SUDO} apt-get install -y docker-compose-plugin; fi',
    'DAEMON_JSON="/etc/docker/daemon.json"',
    'if [[ ! -s "${DAEMON_JSON}" ]] || [[ "$(tr -d \' \\n\\t\' < "${DAEMON_JSON}" 2>/dev/null || echo \'\')" == "{}" ]]; then',
    '  ${SUDO} tee "${DAEMON_JSON}" >/dev/null <<\'JSON\'',
    '{',
    '  "min-api-version": "1.24"',
    '}',
    'JSON',
    '  ${SUDO} systemctl restart docker',
    'fi',
  ];

  const acmeSteps = deployMode === 'traefik' ? [
    '${SUDO} mkdir -p /opt/traefik',
    '${SUDO} touch /opt/traefik/acme.json',
    '${SUDO} chmod 600 /opt/traefik/acme.json',
  ] : [];

  const composeSteps = [
    `${sudoLiteral} tee ${composePath} >/dev/null <<'YAML'`,
    composeYaml,
    'YAML',
    `${sudoLiteral} docker compose -f ${composePath} up -d`,
    dockerPull,
  ];

  const dnsSteps = deployMode === 'cloudflare-tunnel'
    ? (() => {
        const { apiToken, zoneId, tunnelId, baseDomain } =
          (input as { cloudflareDns: { apiToken: string; zoneId: string; tunnelId: string; baseDomain: string } }).cloudflareDns;
        const wildcardName = `*.${baseDomain}`;
        const tunnelTarget = `${tunnelId}.cfargotunnel.com`;
        return [
          `echo "Creating wildcard DNS CNAME: ${wildcardName} -> ${tunnelTarget}"`,
          `curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/${zoneId}/dns_records" \\`,
          `  -H "Authorization: Bearer ${apiToken}" \\`,
          `  -H "Content-Type: application/json" \\`,
          `  --data '{"type":"CNAME","name":"${wildcardName}","content":"${tunnelTarget}","proxied":true,"ttl":1}'`,
        ];
      })()
    : [];

  return [...commonSteps, ...acmeSteps, ...composeSteps, ...dnsSteps].filter(Boolean).join('\n');
}
