import { buildProvisionScript } from '../src/index';

// --- Test 1: Traefik mode (existing behavior) ---
const traefikScript = buildProvisionScript({
  traefikCompose: {
    acmeEmail: 'you@example.com',
    wildcardDomain: 'h1.openclaw.example.com',
    vercelApiToken: 'token',
    vercelTeamId: 'team',
    enableDashboard: false,
    traefikImage: 'traefik:v3.1',
    certResolverName: 'le',
    entrypointName: 'websecure',
    entrypointPort: 443,
  },
  openclawRuntimeImage: 'openclaw-ttyd:local',
  composePath: '/opt/traefik/docker-compose.yml',
});

if (!traefikScript.includes('docker compose')) {
  throw new Error('[traefik] Expected docker compose commands in provision script');
}
if (!traefikScript.includes('acme.json')) {
  throw new Error('[traefik] Expected acme.json setup in traefik mode');
}
if (!traefikScript.includes('certificatesresolvers')) {
  throw new Error('[traefik] Expected certificatesresolvers in traefik mode');
}

console.log('OK: traefik mode');

// --- Test 2: Cloudflare Tunnel mode ---
const cfScript = buildProvisionScript({
  deployMode: 'cloudflare-tunnel',
  cloudflareTunnelCompose: {
    tunnelToken: 'test-tunnel-token',
    wildcardDomain: 'h1.openclaw.example.com',
    ttydSecret: 'test-secret',
    ttydTtlSeconds: 86400,
    traefikImage: 'traefik:v3.1',
    cloudflaredImage: 'cloudflare/cloudflared:latest',
    enableDashboard: false,
  },
  openclawRuntimeImage: 'openclaw-ttyd:local',
  composePath: '/opt/traefik/docker-compose.yml',
});

if (!cfScript.includes('docker compose')) {
  throw new Error('[cloudflare-tunnel] Expected docker compose commands in provision script');
}
if (!cfScript.includes('cloudflared')) {
  throw new Error('[cloudflare-tunnel] Expected cloudflared in CF tunnel mode');
}
if (!cfScript.includes('TUNNEL_TOKEN')) {
  throw new Error('[cloudflare-tunnel] Expected TUNNEL_TOKEN in CF tunnel mode');
}
if (cfScript.includes('acme')) {
  throw new Error('[cloudflare-tunnel] Should NOT contain acme in CF tunnel mode');
}
if (cfScript.includes('vercel')) {
  throw new Error('[cloudflare-tunnel] Should NOT contain vercel in CF tunnel mode');
}

console.log('OK: cloudflare-tunnel mode');
