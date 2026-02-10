const CLOUDFLARE_API_BASE = 'https://api.cloudflare.com/client/v4';

export interface CloudflareApiConfig {
  apiToken: string;
  zoneId: string;
}

export interface CloudflareApiRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: string;
}

/** Returns "{tunnelId}.cfargotunnel.com" */
export function buildTunnelCname(tunnelId: string): string {
  return `${tunnelId}.cfargotunnel.com`;
}

/** POST to /zones/{zoneId}/dns_records with CNAME payload */
export function buildCreateDnsRecordRequest(
  config: CloudflareApiConfig,
  record: { name: string; target: string; proxied?: boolean; ttl?: number }
): CloudflareApiRequest {
  return {
    url: `${CLOUDFLARE_API_BASE}/zones/${config.zoneId}/dns_records`,
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${config.apiToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      type: 'CNAME',
      name: record.name,
      content: record.target,
      proxied: record.proxied ?? true,
      ttl: record.ttl ?? 1,
    }),
  };
}

/** Convenience: creates "*.{wildcardDomain}" CNAME pointing to tunnel */
export function buildCreateWildcardDnsRecordRequest(
  config: CloudflareApiConfig,
  wildcardDomain: string,
  tunnelCname: string
): CloudflareApiRequest {
  return buildCreateDnsRecordRequest(config, {
    name: `*.${wildcardDomain}`,
    target: tunnelCname,
    proxied: true,
  });
}

/** GET /zones/{zoneId}/dns_records with optional name filter */
export function buildListDnsRecordsRequest(
  config: CloudflareApiConfig,
  nameFilter?: string
): CloudflareApiRequest {
  let url = `${CLOUDFLARE_API_BASE}/zones/${config.zoneId}/dns_records`;
  if (nameFilter) {
    url += `?name=${nameFilter}`;
  }
  return {
    url,
    method: 'GET',
    headers: {
      'Authorization': `Bearer ${config.apiToken}`,
    },
  };
}

/** DELETE /zones/{zoneId}/dns_records/{recordId} */
export function buildDeleteDnsRecordRequest(
  config: CloudflareApiConfig,
  recordId: string
): CloudflareApiRequest {
  return {
    url: `${CLOUDFLARE_API_BASE}/zones/${config.zoneId}/dns_records/${recordId}`,
    method: 'DELETE',
    headers: {
      'Authorization': `Bearer ${config.apiToken}`,
    },
  };
}
