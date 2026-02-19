import { buildTraefikComposeYaml, TraefikComposeInput } from './traefik';
import { buildCloudflareTunnelComposeYaml, CloudflareTunnelComposeInput, decodeTunnelToken, buildCredentialsJson, buildCloudflaredConfigYaml } from './cloudflared';
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
      tunnelToken: string;
      cloudflareDns?: {
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
    '${SUDO} apt-get install -y ca-certificates curl gnupg jq lsb-release',
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

  const cloudflaredSteps: string[] = [];
  if (deployMode === 'cloudflare-tunnel') {
    const cfInput = input as { tunnelToken: string; cloudflareTunnelCompose: CloudflareTunnelComposeInput };
    const creds = decodeTunnelToken(cfInput.tunnelToken);
    const credentialsJson = buildCredentialsJson(creds);
    const initialIngress = [{ service: 'http_status:404' }];
    const configYaml = buildCloudflaredConfigYaml({ tunnelId: creds.tunnelId, ingress: initialIngress });

    cloudflaredSteps.push(
      `${sudoLiteral} mkdir -p /var/lib/openclaw/cloudflared`,
      `${sudoLiteral} tee /var/lib/openclaw/cloudflared/credentials.json >/dev/null <<'CREDS'`,
      credentialsJson,
      'CREDS',
      `if [ ! -f /var/lib/openclaw/cloudflared/ingress.json ]; then`,
      `  ${sudoLiteral} tee /var/lib/openclaw/cloudflared/ingress.json >/dev/null <<'INGRESS'`,
      JSON.stringify(initialIngress, null, 2),
      'INGRESS',
      'fi',
      `${sudoLiteral} tee /var/lib/openclaw/cloudflared/config.yml >/dev/null <<'CFGYML'`,
      configYaml,
      'CFGYML',
    );
  }

  const composeSteps = [
    `${sudoLiteral} tee ${composePath} >/dev/null <<'YAML'`,
    composeYaml,
    'YAML',
    `${sudoLiteral} docker compose -f ${composePath} up -d`,
    dockerPull,
  ];

  const dnsSteps: string[] = [];

  return [...commonSteps, ...acmeSteps, ...cloudflaredSteps, ...composeSteps, ...dnsSteps].filter(Boolean).join('\n');
}
