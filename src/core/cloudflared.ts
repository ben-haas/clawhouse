export interface CloudflareTunnelComposeInput {
  tunnelId: string;
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
    '    command: tunnel --no-autoupdate --config /etc/cloudflared/config.yml run',
    '    volumes:',
    '      - /var/lib/openclaw/cloudflared:/etc/cloudflared:ro',
    '',
    'networks:',
    '  default:',
    '    name: traefik_default',
  ].filter(Boolean).join('\n');
}

export interface TunnelCredentials {
  accountTag: string;
  tunnelId: string;
  tunnelSecret: string;
}

export function decodeTunnelToken(token: string): TunnelCredentials {
  const json = JSON.parse(atob(token));
  return {
    accountTag: json.a,
    tunnelId: json.t,
    tunnelSecret: json.s,
  };
}

export function buildCredentialsJson(creds: TunnelCredentials): string {
  return JSON.stringify({
    AccountTag: creds.accountTag,
    TunnelID: creds.tunnelId,
    TunnelSecret: creds.tunnelSecret,
  }, null, 2);
}

export interface CloudflaredIngressRule {
  hostname?: string;
  service: string;
}

export function buildCloudflaredConfigYaml(opts: {
  tunnelId: string;
  ingress: CloudflaredIngressRule[];
}): string {
  const lines = [
    `tunnel: ${opts.tunnelId}`,
    'credentials-file: /etc/cloudflared/credentials.json',
    'ingress:',
  ];
  for (const rule of opts.ingress) {
    if (rule.hostname) {
      lines.push(`  - hostname: ${rule.hostname}`);
      lines.push(`    service: ${rule.service}`);
    } else {
      lines.push(`  - service: ${rule.service}`);
    }
  }
  return lines.join('\n');
}
