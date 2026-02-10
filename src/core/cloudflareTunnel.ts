const CLOUDFLARE_API_BASE = 'https://api.cloudflare.com/client/v4';

export interface CloudflareTunnelApiConfig {
  apiToken: string;
  accountId: string;
  tunnelId: string;
}

export interface TunnelIngressRule {
  hostname?: string;
  service: string;
  path?: string;
}

// Re-use CloudflareApiRequest from cloudflareDns
import type { CloudflareApiRequest } from './cloudflareDns';

/** GET /accounts/{accountId}/tunnels/{tunnelId}/configurations */
export function buildGetTunnelConfigRequest(
  config: CloudflareTunnelApiConfig
): CloudflareApiRequest {
  return {
    url: `${CLOUDFLARE_API_BASE}/accounts/${config.accountId}/tunnels/${config.tunnelId}/configurations`,
    method: 'GET',
    headers: {
      'Authorization': `Bearer ${config.apiToken}`,
    },
  };
}

/** PUT /accounts/{accountId}/tunnels/{tunnelId}/configurations */
export function buildPutTunnelConfigRequest(
  config: CloudflareTunnelApiConfig,
  tunnelConfig: { ingress: TunnelIngressRule[] }
): CloudflareApiRequest {
  return {
    url: `${CLOUDFLARE_API_BASE}/accounts/${config.accountId}/tunnels/${config.tunnelId}/configurations`,
    method: 'PUT',
    headers: {
      'Authorization': `Bearer ${config.apiToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ config: tunnelConfig }),
  };
}

/** Insert a rule before the catch-all, replacing any existing rule for the same hostname */
export function addIngressRule(
  existingRules: TunnelIngressRule[],
  newRule: TunnelIngressRule
): TunnelIngressRule[] {
  // Remove any existing rule with the same hostname
  const filtered = existingRules.filter(
    (r) => r.hostname !== newRule.hostname
  );
  // The catch-all rule has no hostname — insert before it
  const catchAllIndex = filtered.findIndex((r) => !r.hostname);
  if (catchAllIndex === -1) {
    // No catch-all found, append rule and add default catch-all
    return [...filtered, newRule, { service: 'http_status:404' }];
  }
  return [
    ...filtered.slice(0, catchAllIndex),
    newRule,
    ...filtered.slice(catchAllIndex),
  ];
}
