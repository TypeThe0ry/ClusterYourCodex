import { afterEach, describe, expect, it, vi } from "vitest";
import { discoveryClient, DiscoveryClientError } from "./discovery";

afterEach(() => vi.unstubAllGlobals());

describe("LAN discovery client", () => {
  it("parses credential-free controller candidates and preserves pairing boundary", async () => {
    const discoveryScan = vi.fn(async () => ({
      apiVersion: "cyc.dev/discovery/v1",
      broadcast: true,
      pairingRequired: true,
      credentialsTransmitted: false,
      candidates: [{
        address: "192.168.1.63",
        port: 47830,
        nextAction: "verify the SSH host key, then continue explicit install and pairing",
        announcement: {
          apiVersion: "cyc.dev/discovery/v1",
          service: "clusteryourcodex",
          role: "controller",
          version: "0.0.1",
          workerPublicUrl: null,
        },
      }],
    }));
    vi.stubGlobal("window", { __CLUSTER_YOUR_CODEX__: { discoveryScan } });

    const result = await discoveryClient.scan();
    expect(result.candidates[0]).toMatchObject({ address: "192.168.1.63", port: 47830 });
    expect(result.pairingRequired).toBe(true);
    expect(result.credentialsTransmitted).toBe(false);
    expect(discoveryScan).toHaveBeenCalledWith(1500);
  });

  it("rejects a response that tries to bypass explicit pairing", async () => {
    vi.stubGlobal("window", {
      __CLUSTER_YOUR_CODEX__: {
        discoveryScan: vi.fn(async () => ({
          apiVersion: "cyc.dev/discovery/v1",
          broadcast: true,
          pairingRequired: false,
          credentialsTransmitted: false,
          candidates: [],
        })),
      },
    });

    await expect(discoveryClient.scan()).rejects.toMatchObject({
      code: "invalid_response",
    } satisfies Partial<DiscoveryClientError>);
  });
});
