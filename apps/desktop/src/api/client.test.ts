import { describe, expect, it, vi } from "vitest";
import { ControllerApiError, ControllerClient } from "./client";

describe("ControllerClient", () => {
  it("uses the fixed local health endpoint", async () => {
    const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(
        JSON.stringify({ status: "ok", controllerVersion: "0.1.0", apiVersion: "cyc.dev/v1", database: "ok" }),
        { status: 200, headers: { "content-type": "application/json" } },
      ),
    );
    const client = new ControllerClient({ baseUrl: "http://127.0.0.1:47831/", fetchImpl });

    await expect(client.health()).resolves.toMatchObject({ status: "ready" });
    expect(fetchImpl).toHaveBeenCalledWith(
      "http://127.0.0.1:47831/v1/health",
      expect.objectContaining({ method: "GET" }),
    );
  });

  it("encodes job identifiers and does not place payloads in the URL", async () => {
    const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({ jobId: "job/id", status: "cancelled", accepted: true }), {
        status: 200,
      }),
    );
    const client = new ControllerClient({ fetchImpl });

    await client.cancel("job/id");

    expect(fetchImpl).toHaveBeenCalledWith(
      "http://127.0.0.1:47831/v1/jobs/job%2Fid/cancel",
      expect.objectContaining({ method: "POST", body: undefined }),
    );
  });

  it("returns a redacted error instead of echoing the response body", async () => {
    const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({ password: "must-not-leak" }), { status: 500 }),
    );
    const client = new ControllerClient({ fetchImpl });

    const error = await client.fleet().catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(ControllerApiError);
    expect(String(error)).not.toContain("must-not-leak");
  });

  it("normalizes the controller wire model for the desktop dashboard", async () => {
    const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(
        JSON.stringify({
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
        }),
        { status: 200 },
      ),
    );
    const client = new ControllerClient({ fetchImpl });

    const fleet = await client.fleet();

    expect(fleet.codex.connected).toBe(true);
    expect(fleet.nodes[0]).toMatchObject({ name: "Build PC", address: "192.0.2.10:22", status: "online" });
    expect(fleet.nodes[0]?.resources?.memoryUsedMiB).toBe(8192);
  });
});
