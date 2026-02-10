export interface CloudflareTunnelComposeInput {
  tunnelToken: string;
  wildcardDomain: string;
  ttydSecret: string;
  ttydTtlSeconds?: number;
  traefikImage?: string;
  cloudflaredImage?: string;
  enableDashboard?: boolean;
}

export function buildCloudflareTunnelComposeYaml(input: CloudflareTunnelComposeInput): string {
  const traefikImage = input.traefikImage || 'traefik:v3.1';
  const cloudflaredImage = input.cloudflaredImage || 'cloudflare/cloudflared:latest';
  const ttydTtlSeconds = input.ttydTtlSeconds ?? 86400;

  const enableDashboard = !!input.enableDashboard;
  const dashboardCmd = enableDashboard ? '      - "--api.dashboard=true"' : '';
  const dashboardPort = enableDashboard ? '      - "8080:8080"' : '';

  return [
    'services:',
    '  traefik:',
    `    image: ${traefikImage}`,
    '    container_name: traefik',
    '    restart: unless-stopped',
    '    command:',
    '      - "--providers.docker=true"',
    '      - "--providers.docker.exposedbydefault=false"',
    '      - "--entrypoints.web.address=:80"',
    dashboardCmd,
    '    environment:',
    '      - DOCKER_API_VERSION=1.45',
    '    ports:',
    '      - "80:80"',
    dashboardPort,
    '    volumes:',
    '      - /var/run/docker.sock:/var/run/docker.sock:ro',
    '',
    '  openclaw-forward-auth:',
    '    build:',
    '      context: ../../docker/forward-auth',
    '    container_name: openclaw-forward-auth',
    '    restart: unless-stopped',
    '    environment:',
    `      - OPENCLAW_TTYD_SECRET=${input.ttydSecret}`,
    `      - OPENCLAW_TTYD_TTL_SECONDS=${ttydTtlSeconds}`,
    '    labels:',
    '      - "traefik.enable=false"',
    '',
    '  cloudflared:',
    `    image: ${cloudflaredImage}`,
    '    container_name: cloudflared',
    '    restart: unless-stopped',
    `    command: tunnel --no-autoupdate run --token ${input.tunnelToken}`,
    '',
    'networks:',
    '  default:',
    '    name: traefik_default',
  ].filter(Boolean).join('\n');
}
