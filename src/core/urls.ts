export interface BuildInstanceUrlsInput {
  instanceId: string;
  baseDomain: string;
  terminalToken: string;
  hostShard?: string;
  subdomain?: string;
  instancePrefix?: string;
}

export interface InstanceUrls {
  openclawUrl: string;
  ttydUrl: string;
  hostName: string;
  wildcardDomain: string;
}

export function buildInstanceUrls(input: BuildInstanceUrlsInput): InstanceUrls {
  const instancePrefix = input.instancePrefix || 'openclaw-';

  const wildcardDomain = input.hostShard
    ? `${input.hostShard}.${input.subdomain || 'openclaw'}.${input.baseDomain}`
    : input.baseDomain;
  const hostName = `${instancePrefix}${input.instanceId}.${wildcardDomain}`;

  return {
    wildcardDomain,
    hostName,
    openclawUrl: `https://${hostName}/`,
    ttydUrl: `https://${hostName}/terminal?token=${input.terminalToken}`,
  };
}

