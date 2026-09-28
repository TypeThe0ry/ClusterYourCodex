import type { ClusterYourCodexDesktopBridge } from "./auth";

export interface LanDiscoveryAnnouncement {
  apiVersion: string;
  service: string;
  role: string;
  version: string;
  workerPublicUrl?: string;
}

export interface LanDiscoveryCandidate {
  address: string;
  port: number;
  announcement: LanDiscoveryAnnouncement;
  nextAction: string;
}

export interface LanDiscoveryResult {
  apiVersion: string;
  broadcast: boolean;
  candidates: LanDiscoveryCandidate[];
  pairingRequired: true;
  credentialsTransmitted: false;
}

export class DiscoveryClientError extends Error {
  readonly code: string;

  constructor(code: string) {
    super(code === "bridge_unavailable"
      ? "The secure desktop discovery bridge is unavailable."
      : "The local network discovery scan failed.");
    this.name = "DiscoveryClientError";
    this.code = code;
  }
}

function bridge(): ClusterYourCodexDesktopBridge {
  const result = globalThis.window?.__CLUSTER_YOUR_CODEX__;
  if (!result?.discoveryScan) throw new DiscoveryClientError("bridge_unavailable");
  return result;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringField(value: Record<string, unknown>, key: string): string {
  const result = value[key];
  if (typeof result !== "string" || result.length === 0 || result.length > 512) {
    throw new DiscoveryClientError("invalid_response");
  }
  return result;
}

function parseCandidate(value: unknown): LanDiscoveryCandidate {
  if (!isObject(value) || !isObject(value.announcement)) throw new DiscoveryClientError("invalid_response");
  const port = value.port;
  if (typeof port !== "number" || !Number.isInteger(port) || port < 1 || port > 65535) throw new DiscoveryClientError("invalid_response");
  const announcement = value.announcement;
  if (announcement.apiVersion !== "cyc.dev/discovery/v1"
    || announcement.service !== "clusteryourcodex"
    || announcement.role !== "controller") {
    throw new DiscoveryClientError("invalid_response");
  }
  return {
    address: stringField(value, "address"),
    port,
    nextAction: stringField(value, "nextAction"),
    announcement: {
      apiVersion: stringField(announcement, "apiVersion"),
      service: stringField(announcement, "service"),
      role: stringField(announcement, "role"),
      version: stringField(announcement, "version"),
      ...(announcement.workerPublicUrl === undefined || announcement.workerPublicUrl === null
        ? {}
        : { workerPublicUrl: stringField(announcement, "workerPublicUrl") }),
    },
  };
}

function parseResult(value: unknown): LanDiscoveryResult {
  if (!isObject(value)
    || value.apiVersion !== "cyc.dev/discovery/v1"
    || value.broadcast !== true
    || value.pairingRequired !== true
    || value.credentialsTransmitted !== false
    || !Array.isArray(value.candidates)) {
    throw new DiscoveryClientError("invalid_response");
  }
  return {
    apiVersion: stringField(value, "apiVersion"),
    broadcast: true,
    candidates: value.candidates.map(parseCandidate),
    pairingRequired: true,
    credentialsTransmitted: false,
  };
}

export const discoveryClient = {
  async scan(timeoutMs = 1_500): Promise<LanDiscoveryResult> {
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 100 || timeoutMs > 30_000) {
      throw new DiscoveryClientError("invalid_request");
    }
    try {
      return parseResult(await bridge().discoveryScan(timeoutMs));
    } catch (error) {
      if (error instanceof DiscoveryClientError) throw error;
      throw new DiscoveryClientError("scan_failed");
    }
  },
};
