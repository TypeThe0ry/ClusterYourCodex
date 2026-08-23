import { describe, expect, expectTypeOf, it, vi } from "vitest";
import {
  type ControllerRequestEnvelope,
  ControllerTransportError,
  DesktopHostControllerTransport,
  DevelopmentProxyControllerTransport,
  MAX_RENDERER_REQUEST_TIMEOUT_MS,
  mockControllerProvider,
} from "./auth";
import { ControllerApiError, ControllerClient, isStrictRfc3339, nodeDashboardStatus, preferNewerFleetSnapshot } from "./client";
import type { FleetInfo } from "./types";

const jobId = "fd33ef90-ee79-4e0c-8652-5cbe3b51cb14";
const runId = "607292ff-ebce-46a8-865f-ee55ee5794f7";
const nodeId = "813c91ba-843d-4c74-ac85-d28060b9f3c4";
const planBinding = {
  apiVersion: "cyc.dev/placement-plan-binding/v1",
  planId: "65fa1374-3954-4a3c-9cc6-08745ab18be4",
  jobId,
  jobDigest: "9".repeat(64),
  createdAt: "2026-08-23T01:00:00Z",
  expiresAt: "2026-08-23T01:01:00Z",
  fleetRevision: 11,
  nodeRevision: 4,
  policyRevision: 3,
  decision: {
    nodeId,
    score: 7,
    explanation: {
      policy: "balanced",
      selectedNodeId: nodeId,
      candidates: [{
        nodeId,
        nodeName: "Build PC",
        eligible: true,
        score: 7,
        scoreComponents: [{ key: "priority", value: 7, detail: "configured priority" }],
        rejectionReasons: [],
      }],
    },
  },
} as const;

const jobResponse = {
  job: {
    apiVersion: "cyc.dev/v1",
    id: jobId,
    kind: "build",
    source: { type: "git", repository: "https://example.test/repo.git", revision: "0".repeat(40) },
    steps: [{ name: "build", script: "cargo build" }],
  },
  run: { id: runId, jobId, nodeId, state: "queued", createdAt: "2026-08-23T01:00:01Z", artifactIds: [] },
  planBinding,
  version: 0,
  cancelRequested: false,
};

describe("ControllerClient", () => {
  it("rejects normalized or timezone-less dates and accepts strict RFC3339 offsets", () => {
    expect(isStrictRfc3339("2026-02-29T01:00:00Z")).toBe(false);
    expect(isStrictRfc3339("2026-08-23T01:00:00")).toBe(false);
    expect(isStrictRfc3339("2026-08-23T01:00:00+08:00")).toBe(true);
  });

  it("keeps a newer fleet revision when overlapping requests finish out of order", () => {
    const fleet = (revision: number, observedAt: string): FleetInfo => ({
      fleetRevision: revision,
      observedAt,
      controller: { status: "ready", version: "0.1.0", activeJobs: 0, queuedJobs: 0, completedToday: 0 },
      codex: { connected: false },
      nodes: [],
      recentJobs: [],
    });
    const current = fleet(9, "2026-08-23T01:00:09Z");
    expect(preferNewerFleetSnapshot(current, fleet(8, "2026-08-23T01:00:10Z"))).toBe(current);
    expect(preferNewerFleetSnapshot(current, fleet(9, "2026-08-23T01:00:10Z")).observedAt).toBe("2026-08-23T01:00:10Z");
  });

  it("maps every controller availability without counting unschedulable nodes as available", () => {
    expect(nodeDashboardStatus("available", "online", 0)).toBe("online");
    expect(nodeDashboardStatus("degraded", "degraded", 1)).toBe("busy");
    expect(nodeDashboardStatus("draining", "online", 2)).toBe("unknown");
    expect(nodeDashboardStatus("disabled", "online", 2)).toBe("offline");
    expect(nodeDashboardStatus("offline", "online", 0)).toBe("offline");
    expect(nodeDashboardStatus("stale", "online", 0)).toBe("offline");
    expect(nodeDashboardStatus(undefined, "degraded", 0)).toBe("online");
    expect(nodeDashboardStatus(undefined, "draining", 1)).toBe("unknown");
  });

  it("uses the public health route through a transport provider", async () => {
    const transport = mockControllerProvider(async (request) => {
      expect(request).toMatchObject({ method: "GET", path: "/v1/health" });
      expect(request.deadlineMs).toBeGreaterThan(Date.now());
      expect(request.deadlineMs - Date.now()).toBeLessThanOrEqual(MAX_RENDERER_REQUEST_TIMEOUT_MS);
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
      expect(request).toMatchObject({ method: "POST", path: "/v1/jobs/job%2Fid/cancel", body: {} });
      expect(request.deadlineMs).toEqual(expect.any(Number));
      return { status: 200, body: jobResponse };
    });
    const client = new ControllerClient({ transport });

    await client.cancel("job/id");
  });

  it("strictly validates public plan bindings and JavaScript integer bounds", async () => {
    const client = new ControllerClient({
      transport: mockControllerProvider(async () => ({ status: 200, body: planBinding })),
    });
    await expect(client.plan({ job: jobResponse.job as never })).resolves.toEqual(planBinding);

    const selected = planBinding.decision.explanation.candidates[0];
    const tampered = [
      { ...planBinding, fleetRevision: Number.MAX_SAFE_INTEGER + 1 },
      { ...planBinding, mutableScore: 1 },
      { ...planBinding, createdAt: "2026-02-29T01:00:00Z" },
      { ...planBinding, createdAt: "2026-08-23T01:00:00" },
      {
        ...planBinding,
        decision: { ...planBinding.decision, explanation: {
          ...planBinding.decision.explanation,
          candidates: [{ ...selected, scoreComponents: [{ ...selected.scoreComponents[0], value: 8 }] }],
        } },
      },
      {
        ...planBinding,
        decision: { ...planBinding.decision, explanation: {
          ...planBinding.decision.explanation,
          candidates: [selected, selected],
        } },
      },
      {
        ...planBinding,
        decision: { ...planBinding.decision, explanation: {
          ...planBinding.decision.explanation,
          candidates: [{ ...selected, nodeName: "P1\nspoof" }],
        } },
      },
      {
        ...planBinding,
        decision: { ...planBinding.decision, explanation: {
          ...planBinding.decision.explanation,
          candidates: [{ ...selected, scoreComponents: [
            { key: "same", value: 3, detail: "first" },
            { key: "same", value: 4, detail: "second" },
          ] }],
        } },
      },
      {
        ...planBinding,
        decision: { ...planBinding.decision, explanation: {
          ...planBinding.decision.explanation,
          candidates: [selected, {
            nodeId: "0cb8d4c4-ef55-4c14-8821-014815489a16",
            nodeName: "offline",
            eligible: false,
            scoreComponents: [],
            rejectionReasons: [
              { code: "offline", detail: "first" },
              { code: "offline", detail: "duplicate" },
            ],
          }],
        } },
      },
    ];
    for (const body of tampered) {
      const invalid = new ControllerClient({
        transport: mockControllerProvider(async () => ({ status: 200, body })),
      });
      await expect(invalid.plan({ job: jobResponse.job as never })).rejects.toMatchObject({ code: "invalid_response" });
    }
  });

  it("requires stable placement authority on new job responses and accepts explicit legacy null", async () => {
    const current = new ControllerClient({
      transport: mockControllerProvider(async () => ({ status: 200, body: jobResponse })),
    });
    await expect(current.job(jobId)).resolves.toEqual(jobResponse);

    const legacy = new ControllerClient({
      transport: mockControllerProvider(async () => ({ status: 200, body: { ...jobResponse, planBinding: null } })),
    });
    await expect(legacy.job(jobId)).resolves.toMatchObject({ planBinding: null });

    const missing = new ControllerClient({
      transport: mockControllerProvider(async () => {
        const { planBinding: _removed, ...body } = jobResponse;
        return { status: 200, body };
      }),
    });
    await expect(missing.job(jobId)).rejects.toMatchObject({ code: "invalid_response" });
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
        fleetRevision: 7,
        observedAt: "2026-08-23T01:00:00Z",
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

    expect(fleet.codex.connected).toBe(false);
    expect(fleet.nodes[0]).toMatchObject({ name: "Build PC", address: "192.0.2.10:22", status: "online" });
    expect(fleet.nodes[0]?.resources?.memoryUsedMiB).toBe(8192);
  });

  it("uses split-state nodeViews for fresh occupancy and atomic slot headroom", async () => {
    const nodeId = "813c91ba-843d-4c74-ac85-d28060b9f3c4";
    const node = {
      id: nodeId,
      name: "Build PC",
      enabled: true,
      transport: { type: "managed", endpoint: "https://worker.invalid", credentialRef: "opaque-ref" },
      os: "linux",
      arch: "x86_64",
      status: "online",
      capabilities: ["docker"],
      resources: {
        logicalCpuCores: 16,
        availableCpuCores: 16,
        memoryMib: 32768,
        availableMemoryMib: 32768,
        diskMib: 100000,
        availableDiskMib: 100000,
        gpus: [],
      },
      load: { cpuPercent: 0, queueDepth: 0, runningJobs: 0 },
      priority: 100,
      labels: {},
      cachedSources: [],
    };
    const documentTimes = { observedAt: "2026-08-23T01:00:00Z", receivedAt: "2026-08-23T01:00:01Z" };
    const transport = mockControllerProvider(async () => ({
      status: 200,
      body: {
        fleetRevision: 8,
        observedAt: "2026-08-23T01:00:00Z",
        controller: { version: "0.1.0", apiVersion: "cyc.dev/v1", access: "loopback" },
        codex: { integration: "mcp", status: "connected" },
        nodes: [node],
        nodeViews: [{
          nodeId,
          config: {
            ...documentTimes,
            revision: 2,
            document: {
              name: "Build PC",
              enabled: true,
              priority: 100,
              labels: {},
              desiredState: "active",
              capacity: { maxConcurrentJobs: 4, allowedJobKinds: [], allowOnBattery: false },
            },
          },
          inventory: {
            ...documentTimes,
            revision: 1,
            digest: "sha256:inventory",
            document: {
              transport: node.transport,
              os: "linux",
              arch: "x86_64",
              capabilities: ["docker"],
              logicalCpuCores: 16,
              memoryMiB: 32768,
              diskMiB: 100000,
              gpus: [],
              cpuModel: "fixture",
              toolVersions: { docker: "27" },
              workerVersion: "0.1.0",
              protocolVersion: 1,
              containment: { backend: "linux_subreaper_process_group", version: "1", maxSafeSlots: 1 },
            },
          },
          telemetry: {
            ...documentTimes,
            document: {
              status: "online",
              availableCpuCores: 5,
              availableMemoryMiB: 12288,
              availableDiskMiB: 90000,
              gpus: [],
              load: { cpuPercent: 72, queueDepth: 0, runningJobs: 1 },
              cachedSources: [],
              observedAt: documentTimes.observedAt,
              bootGeneration: 7,
              bootId: "0868ca2d-41ad-4919-8fc8-2229907c2ca6",
              sequence: 17,
              cpuEwmaPercent: 68,
              activeRunIds: ["607292ff-ebce-46a8-865f-ee55ee5794f7"],
              powerSource: "ac",
              temperatureC: 74,
            },
          },
          availability: "available",
          availabilityReasons: [],
          effectiveSlots: { configured: 4, containmentMaxSafe: 1, effective: 1, reserved: 1, available: 0 },
          effectiveResources: { ...node.resources, availableCpuCores: 3, availableMemoryMib: 8192 },
          reservations: [{
            leaseId: "b6de9847-bfd9-4829-a40b-73a451b4c86e",
            runId: "607292ff-ebce-46a8-865f-ee55ee5794f7",
            jobId: "fd33ef90-ee79-4e0c-8652-5cbe3b51cb14",
            phase: "execution",
            slots: 1,
            cpuCores: 2,
            memoryMiB: 4096,
            diskMiB: 0,
            gpuVramMiB: 0,
            gpuExclusive: false,
            expiresAt: "2026-08-23T01:02:00Z",
          }],
        }],
        recentJobs: [],
      },
    }));

    const fleet = await new ControllerClient({ transport }).fleet();

    expect(fleet.nodes[0]).toMatchObject({
      status: "busy",
      activeJobs: 1,
      availability: "available",
      slots: { configured: 4, effective: 1, reserved: 1, available: 0 },
      resources: { cpuPercent: 72, memoryUsedMiB: 20480, memoryTotalMiB: 32768 },
      telemetry: {
        bootGeneration: 7,
        sequence: 17,
        cpuEwmaPercent: 68,
        powerSource: "ac",
        temperatureC: 74,
      },
    });
    expect(fleet).toMatchObject({ fleetRevision: 8, observedAt: "2026-08-23T01:00:00Z" });
  });

  it("rejects fleet revisions that cannot round-trip through a JavaScript number", async () => {
    const transport = mockControllerProvider(async () => ({
      status: 200,
      body: {
        fleetRevision: Number.MAX_SAFE_INTEGER + 1,
        observedAt: "2026-08-23T01:00:00Z",
        controller: { version: "0.1.0", apiVersion: "cyc.dev/v1", access: "loopback" },
        codex: { integration: "mcp", status: "available" },
        nodes: [],
        recentJobs: [],
      },
    }));

    await expect(new ControllerClient({ transport }).fleet()).rejects.toMatchObject({
      code: "invalid_response",
    });
  });

  it("uses the desktop host proxy without exposing URL, headers, or token to the renderer", async () => {
    const controllerRequest = vi.fn(async () => ({
      status: 200,
      body: {
        fleetRevision: 0,
        observedAt: "2026-08-23T01:00:00Z",
        controller: {},
        codex: {},
        nodes: [],
        recentJobs: [],
      },
    }));
    vi.stubGlobal("window", { __CLUSTER_YOUR_CODEX__: { controllerRequest } });
    try {
      const client = new ControllerClient({ transport: new DesktopHostControllerTransport() });
      await client.fleet();
      expect(controllerRequest).toHaveBeenCalledWith({
        method: "GET",
        path: "/v1/fleet",
        deadlineMs: expect.any(Number),
      });
      expect(JSON.stringify(controllerRequest.mock.calls)).not.toMatch(/authorization|bearer|token|https?:/i);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("fails clearly when the production desktop proxy is unavailable", async () => {
    const transport = new DesktopHostControllerTransport();
    await expect(
      transport.request({ method: "GET", path: "/v1/fleet", deadlineMs: Date.now() + 1_000 }),
    ).rejects.toThrow(
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

    await transport.request({
      method: "POST",
      path: "/v1/jobs/id/cancel",
      deadlineMs: Date.now() + 1_000,
      body: {},
    });

    const [url, init] = fetchImpl.mock.calls[0] ?? [];
    expect(url).toBe("/__cyc_controller/v1/jobs/id/cancel");
    expect(new Headers(init?.headers).has("authorization")).toBe(false);
    expect(new Headers(init?.headers).get("content-type")).toBe("application/json");
    expect(init?.body).toBe("{}");
    expect(init?.signal).toBeInstanceOf(AbortSignal);
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
    await expect(
      transport.request({ method: "GET", path: "/v1/../secrets", deadlineMs: Date.now() + 1_000 }),
    ).rejects.toBeInstanceOf(ControllerTransportError);
  });

  it("rejects an expired deadline before invoking the desktop bridge", async () => {
    const controllerRequest = vi.fn();
    vi.stubGlobal("window", { __CLUSTER_YOUR_CODEX__: { controllerRequest } });
    try {
      const transport = new DesktopHostControllerTransport();
      await expect(
        transport.request({ method: "POST", path: "/v1/jobs", deadlineMs: Date.now() - 1, body: {} }),
      ).rejects.toThrow("deadline is invalid or expired");
      expect(controllerRequest).not.toHaveBeenCalled();
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("does not permit a renderer timeout above eight seconds", () => {
    expect(() => new ControllerClient({ timeoutMs: MAX_RENDERER_REQUEST_TIMEOUT_MS + 1 })).toThrow(
      RangeError,
    );
    expect(() => new ControllerClient({ timeoutMs: 0 })).toThrow(RangeError);
  });

  it("keeps the native request envelope deadline typed as an absolute number", () => {
    expectTypeOf<ControllerRequestEnvelope>().toMatchTypeOf<{
      method: "GET" | "POST";
      path: string;
      deadlineMs: number;
    }>();
  });
});
