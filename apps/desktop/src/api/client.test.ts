import { describe, expect, it, vi } from "vitest";
import {
  ControllerTransportError,
  DesktopHostControllerTransport,
  DevelopmentProxyControllerTransport,
  mockControllerProvider,
} from "./auth";
import { ControllerApiError, ControllerClient } from "./client";

describe("ControllerClient", () => {
  it("uses the public health route through a transport provider", async () => {
    const transport = mockControllerProvider(async (request) => {
      expect(request).toEqual({ method: "GET", path: "/v1/health" });
      return {
        status: 200,
        body: { status: "ok", controllerVersion: "0.1.0", apiVersion: "cyc.dev/v1", database: "ok" },
      };
    });
    const client = new ControllerClient({ transport });

    await expect(client.health()).resolves.toMatchObject({ status: "ready", version: "0.1.0" });
  });

  it("encodes job identifiers and supplies an object body for every mutation", async () => {
    const transport = mockControllerProvider(async (request) => {
      expect(request).toEqual({ method: "POST", path: "/v1/jobs/job%2Fid/cancel", body: {} });
      return { status: 200, body: { job: {}, run: {} } };
    });
    const client = new ControllerClient({ transport });

    await client.cancel("job/id");
  });

  it("returns a redacted error instead of echoing the response body", async () => {
    const transport = mockControllerProvider(async () => ({
      status: 500,
      body: { password: "must-not-leak" },
    }));
    const client = new ControllerClient({ transport });

    const error = await client.fleet().catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(ControllerApiError);
    expect(String(error)).not.toContain("must-not-leak");
  });

  it("normalizes the controller wire model for the desktop dashboard", async () => {
    const transport = mockControllerProvider(async () => ({
      status: 200,
      body: {
        controller: { version: "0.1.0", apiVersion: "cyc.dev/v1", access: "loopback" },
        codex: { integration: "mcp", status: "available" },
        nodes: [
          {
            id: "813c91ba-843d-4c74-ac85-d28060b9f3c4",
            name: "Build PC",
            enabled: true,
            transport: { type: "ssh", host: "192.0.2.10", port: 22, username: "worker", credentialRef: "opaque-ref" },
            os: "linux",
            arch: "x86_64",
            status: "online",
            capabilities: ["docker"],
            resources: {
              logicalCpuCores: 16,
              availableCpuCores: 12,
              memoryMib: 32768,
              availableMemoryMib: 24576,
              diskMib: 100000,
              availableDiskMib: 80000,
              gpus: [],
            },
            load: { cpuPercent: 25, queueDepth: 0, runningJobs: 0 },
            priority: 100,
            labels: {},
            cachedSources: [],
          },
        ],
        recentJobs: [],
      },
    }));
    const client = new ControllerClient({ transport });

    const fleet = await client.fleet();

    expect(fleet.codex.connected).toBe(true);
    expect(fleet.nodes[0]).toMatchObject({ name: "Build PC", address: "192.0.2.10:22", status: "online" });
    expect(fleet.nodes[0]?.resources?.memoryUsedMiB).toBe(8192);
  });

  it("uses the desktop host proxy without exposing URL, headers, or token to the renderer", async () => {
    const controllerRequest = vi.fn(async () => ({
      status: 200,
      body: { controller: {}, codex: {}, nodes: [], recentJobs: [] },
    }));
    vi.stubGlobal("window", { __CLUSTER_YOUR_CODEX__: { controllerRequest } });
    try {
      const client = new ControllerClient({ transport: new DesktopHostControllerTransport() });
      await client.fleet();
      expect(controllerRequest).toHaveBeenCalledWith({ method: "GET", path: "/v1/fleet" });
      expect(JSON.stringify(controllerRequest.mock.calls)).not.toMatch(/authorization|bearer|token|https?:/i);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("fails clearly when the production desktop proxy is unavailable", async () => {
    const transport = new DesktopHostControllerTransport();
    await expect(transport.request({ method: "GET", path: "/v1/fleet" })).rejects.toThrow(
      "Desktop controller proxy is unavailable",
    );

    const error = await new ControllerClient({ transport }).health().catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(ControllerApiError);
    expect(error).toMatchObject({
      code: "transport_unavailable",
      message: "Desktop controller proxy is unavailable",
    });
  });

  it("keeps the Vite development token server-side", async () => {
    const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({ ok: true }), { status: 200, headers: { "content-type": "application/json" } }),
    );
    const transport = new DevelopmentProxyControllerTransport(fetchImpl);

    await transport.request({ method: "POST", path: "/v1/jobs/id/cancel", body: {} });

    const [url, init] = fetchImpl.mock.calls[0] ?? [];
    expect(url).toBe("/__cyc_controller/v1/jobs/id/cancel");
    expect(new Headers(init?.headers).has("authorization")).toBe(false);
    expect(new Headers(init?.headers).get("content-type")).toBe("application/json");
    expect(init?.body).toBe("{}");
  });

  it("keeps structured placement evidence and drops untrusted error fields", async () => {
    const transport = mockControllerProvider(async () => ({
      status: 409,
      body: {
        error: {
          code: "no_eligible_node",
          message: "untrusted message",
          placement: {
            policy: "balanced",
            candidates: [
              {
                nodeId: "c64c4600-6d93-4a4c-927d-9c27995386ec",
                nodeName: "GPU computer",
                eligible: false,
                scoreComponents: [],
                rejectionReasons: [{ code: "gpu_required", detail: "no GPU detected" }],
                credentialRef: "must-not-leak",
              },
            ],
          },
        },
      },
    }));
    const client = new ControllerClient({ transport });

    const error = await client.fleet().catch((caught: unknown) => caught);

    expect(error).toBeInstanceOf(ControllerApiError);
    expect((error as ControllerApiError).code).toBe("no_eligible_node");
    expect((error as ControllerApiError).placement?.candidates[0]?.nodeName).toBe("GPU computer");
    expect(JSON.stringify(error)).not.toContain("must-not-leak");
    expect(String(error)).not.toContain("untrusted message");
  });

  it("rejects traversal before it reaches the desktop host", async () => {
    const transport = new DesktopHostControllerTransport();
    await expect(transport.request({ method: "GET", path: "/v1/../secrets" })).rejects.toBeInstanceOf(
      ControllerTransportError,
    );
  });
});
