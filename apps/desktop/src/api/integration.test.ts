import { afterEach, describe, expect, it, vi } from "vitest";
import {
  IntegrationApiError,
  IntegrationClient,
  fullRunStaleReason,
  integrationStatusIdentity,
  integrationStatusIsFresh,
  type IntegrationStatus,
} from "./integration";

const status = {
  state: "not_installed",
  checkedAtMs: Date.now(),
  payloadAvailable: true,
  pluginEnabled: false,
  agentsIntegrated: false,
  payloadCatalogSha256: "d".repeat(64),
  buildCatalogSha256: "e".repeat(64),
  installManifestSha256: "f".repeat(64),
  desiredVersion: "0.1.0",
  message: "Ready to install",
};

const activeRuntime = {
  pid: 4242,
  startedAt: "2026-08-23T00:59:00.000Z",
  bridgeVersion: "0.1.0",
};

const selfTestExecutor = {
  pid: 5252,
  startedAt: "2026-08-23T01:00:00.010Z",
  bridgeVersion: "0.1.0",
  sessionId: "8f26f4f4-5bdd-4d39-84d4-d1b94c16cc9e",
};

const fullRun = {
  state: "passed",
  layers: [
    "plugin_check", "fresh_heartbeat", "source_snapshot", "worker_selection",
    "remote_execution", "log_verification", "artifact_verification", "cleanup",
  ].map((id) => ({ id, state: "passed", message: `${id} passed` })),
  startedAt: "2026-08-23T01:00:00.000Z",
  finishedAt: "2026-08-23T01:00:01.000Z",
  durationMs: 1_000,
  integration: {
    activeRuntime: {
      pid: 4242,
      startedAt: "2026-08-23T00:59:00.000Z",
      bridgeVersion: "0.1.0",
      initialReceiptVerifiedAt: "2026-08-23T01:00:00.100Z",
      finalReceiptVerifiedAt: "2026-08-23T01:00:00.900Z",
      reverifiedAfterRun: true,
    },
    selfTestExecutor: {
      ...selfTestExecutor,
      initializeCompleted: true,
      toolsListCompleted: true,
      controllerRoundTripAt: "2026-08-23T01:00:00.500Z",
      mcpToolsExercised: ["fleet_info", "workspace_snapshot_pack", "fleet_snapshot_upload", "fleet_plan_submit", "fleet_job"],
    },
  },
  selectedNode: {
    id: "7f26f4f4-5bdd-4d39-84d4-d1b94c16cc9e",
    name: "fixture-worker",
    operatingSystem: "linux",
    architecture: "x86_64",
    heartbeatAt: "2026-08-23T01:00:00.000Z",
  },
  transport: {
    transport: "managed_https",
    endpoint: "https://worker.example.test:47832",
    tls: true,
    credentialReferencePresent: true,
  },
  placement: {
    planId: "65fa1374-3954-4a3c-9cc6-08745ab18be4",
    jobDigest: "9".repeat(64),
    score: 42,
    fleetRevision: 11,
    nodeRevision: 7,
    policyRevision: 3,
    explanation: {
      policy: "performance",
      selectedNodeId: "7f26f4f4-5bdd-4d39-84d4-d1b94c16cc9e",
      candidates: [{
        nodeId: "7f26f4f4-5bdd-4d39-84d4-d1b94c16cc9e",
        nodeName: "fixture-worker",
        eligible: true,
        score: 42,
        scoreComponents: [{ key: "priority", value: 42, detail: "performance priority" }],
        rejectionReasons: [],
      }],
    },
  },
  finalFleet: {
    fleetRevision: 17,
    observedAt: "2026-08-23T01:00:00.950Z",
  },
  snapshot: { digest: `sha256:${"a".repeat(64)}`, sizeBytes: 128 },
  job: {
    jobId: "0dc10ac1-e6d7-4e65-9984-135dc7b10c55",
    runId: "350f4340-7806-4374-854e-b94624422418",
    state: "succeeded",
    exitCode: 0,
    observedStates: ["queued", "running", "succeeded"],
  },
  logs: [
    { stream: "stdout", sizeBytes: 24, sha256: "b".repeat(64), chunkCount: 1 },
    { stream: "stderr", sizeBytes: 19, sha256: "d".repeat(64), chunkCount: 1 },
  ],
  artifacts: [{ id: "6b8b0852-5e2e-4d02-b9ba-e7ff2239af71", name: "full-run-proof.txt", sizeBytes: 16, sha256: "c".repeat(64) }],
  cleanup: {
    jobId: "0dc10ac1-e6d7-4e65-9984-135dc7b10c55",
    runId: "350f4340-7806-4374-854e-b94624422418",
    relativeRoot: "jobs/350f4340-7806-4374-854e-b94624422418",
    status: "removed",
    jobRootDeleted: true,
    terminalStateVersion: 4,
    terminalAcknowledgedAt: "2026-08-23T01:00:00.700Z",
    observedAt: "2026-08-23T01:00:00.800Z",
    receivedAt: "2026-08-23T01:00:00.850Z",
    reservationReleasedAt: "2026-08-23T01:00:00.850Z",
    releaseReason: "removed_receipt",
  },
};

const runningFullRun = {
  ...fullRun,
  state: "running",
  layers: fullRun.layers.map((layer, index) => ({
    ...layer,
    state: index === 0 ? "passed" : index === 1 ? "running" : "pending",
  })),
  finishedAt: undefined,
  durationMs: 125,
  integration: {
    ...fullRun.integration,
    activeRuntime: {
      ...fullRun.integration.activeRuntime,
      finalReceiptVerifiedAt: undefined,
      reverifiedAfterRun: false,
    },
    selfTestExecutor: undefined,
  },
  selectedNode: undefined,
  transport: undefined,
  placement: undefined,
  finalFleet: undefined,
  snapshot: undefined,
  job: {
    ...fullRun.job,
    state: "queued",
    exitCode: undefined,
    observedStates: ["queued"],
  },
  logs: [],
  artifacts: [],
  cleanup: undefined,
};

afterEach(() => vi.unstubAllGlobals());

describe("IntegrationClient", () => {
  it("expires Connected evidence instead of treating a historical receipt as fresh forever", () => {
    expect(integrationStatusIsFresh({ checkedAtMs: 1_000 }, 60_999)).toBe(true);
    expect(integrationStatusIsFresh({ checkedAtMs: 1_000 }, 61_001)).toBe(false);
  });

  it("marks an old PASS stale when controller, integration, or fleet evidence changes", () => {
    const connected = {
      ...status,
      state: "connected",
      pluginEnabled: true,
      agentsIntegrated: true,
      agentsBlockSha256: "1".repeat(64),
      installedVersion: "0.1.0",
      activeRuntime,
    } as IntegrationStatus;
    const baseline = {
    integrationIdentity: integrationStatusIdentity(connected),
    integrationGeneration: 2,
    fleetRevision: 11,
    selectedNodeId: "7f26f4f4-5bdd-4d39-84d4-d1b94c16cc9e",
    selectedNodeHeartbeatAt: "2026-08-23T01:00:00.000Z",
  };
    expect(fullRunStaleReason(baseline, {
      controllerOnline: true,
      statusFresh: true,
      status: connected,
      integrationGeneration: 2,
      fleetRevision: 11,
      selectedNode: { id: baseline.selectedNodeId, status: "online", availability: "available", lastSeenAt: "2026-08-23T01:00:01.000Z" },
    }, Date.parse("2026-08-23T01:00:01.000Z"))).toBeUndefined();
    expect(fullRunStaleReason(baseline, {
      controllerOnline: true,
      statusFresh: true,
      status: connected,
      integrationGeneration: 2,
      fleetRevision: 12,
      selectedNode: { id: baseline.selectedNodeId, status: "online", availability: "available", lastSeenAt: "2026-08-23T01:00:01.000Z" },
    }, Date.parse("2026-08-23T01:00:01.000Z"))).toMatch(/Fleet revision changed/);
    expect(fullRunStaleReason(baseline, {
      controllerOnline: false,
      statusFresh: true,
      status: connected,
      integrationGeneration: 2,
      fleetRevision: 11,
      selectedNode: { id: baseline.selectedNodeId, status: "online", availability: "available", lastSeenAt: "2026-08-23T01:00:01.000Z" },
    }, Date.parse("2026-08-23T01:00:01.000Z"))).toBe("The controller is offline.");
    expect(fullRunStaleReason(baseline, {
      controllerOnline: true,
      statusFresh: true,
      status: { ...connected, activeRuntime: { ...activeRuntime, pid: 9999 } },
      integrationGeneration: 2,
      fleetRevision: 11,
      selectedNode: { id: baseline.selectedNodeId, status: "online", availability: "available", lastSeenAt: "2026-08-23T01:00:01.000Z" },
    }, Date.parse("2026-08-23T01:00:01.000Z"))).toMatch(/integration identity changed/);
  });

  it("calls only the five zero-argument native integration operations", async () => {
    const integrationStatus = vi.fn(async () => status);
    const installOrRepairIntegration = vi.fn(async () => ({
      changed: true,
      restartRequired: true,
      steps: [{ id: "plugin", passed: true, message: "Installed" }],
      status: { ...status, state: "restart_required", pluginEnabled: true, agentsIntegrated: true, agentsBlockSha256: "1".repeat(64), installedVersion: "0.1.0" },
    }));
    const integrationSelfTest = vi.fn(async () => ({
      passed: true,
      durationMs: 12,
      restartRecommended: true,
      checks: [{ id: "mcp_initialize", passed: true, message: "Ready" }],
      selfTestExecutor,
      status: { ...status, state: "connected", pluginEnabled: true, agentsIntegrated: true, agentsBlockSha256: "1".repeat(64), installedVersion: "0.1.0", activeRuntime },
    }));
    const fullRunCheck = vi.fn(async () => fullRun);
    const fullRunCheckStatus = vi.fn(async () => runningFullRun);
    vi.stubGlobal("window", {
      __CLUSTER_YOUR_CODEX__: {
        controllerRequest: vi.fn(),
        integrationStatus,
        installOrRepairIntegration,
        integrationSelfTest,
        fullRunCheck,
        fullRunCheckStatus,
      },
    });
    const client = new IntegrationClient();

    await expect(client.status()).resolves.toMatchObject({ state: "not_installed" });
    await expect(client.installOrRepair()).resolves.toMatchObject({ restartRequired: true });
    await expect(client.selfTest()).resolves.toMatchObject({ passed: true });
    await expect(client.fullRunCheck()).resolves.toMatchObject({ state: "passed" });
    await expect(client.fullRunCheckStatus()).resolves.toMatchObject({ state: "running" });
    expect(integrationStatus).toHaveBeenCalledWith();
    expect(installOrRepairIntegration).toHaveBeenCalledWith();
    expect(integrationSelfTest).toHaveBeenCalledWith();
    expect(fullRunCheck).toHaveBeenCalledWith();
    expect(fullRunCheckStatus).toHaveBeenCalledWith();
  });

  it("polls running progress and requires the final status to exactly match the command result", async () => {
    let finished = false;
    const progress = vi.fn();
    vi.stubGlobal("window", {
      __CLUSTER_YOUR_CODEX__: {
        fullRunCheck: vi.fn(async () => {
          await new Promise((resolve) => setTimeout(resolve, 300));
          finished = true;
          return fullRun;
        }),
        fullRunCheckStatus: vi.fn(async () => finished ? fullRun : runningFullRun),
      },
    });

    await expect(new IntegrationClient().fullRunCheckWithProgress(progress, 250)).resolves.toMatchObject({ state: "passed" });
    expect(progress).toHaveBeenCalledWith(expect.objectContaining({ state: "running" }));
    expect(progress.mock.calls[0]?.[0]).not.toHaveProperty("finishedAt");

    vi.stubGlobal("window", {
      __CLUSTER_YOUR_CODEX__: {
        fullRunCheck: vi.fn(async () => fullRun),
        fullRunCheckStatus: vi.fn(async () => ({ ...fullRun, durationMs: 1_001 })),
      },
    });
    await expect(new IntegrationClient().fullRunCheckWithProgress(vi.fn(), 250)).rejects.toMatchObject({
      code: "invalid_native_response",
    });
  });

  it("rejects impossible running order but accepts an authentic late revalidation failure", async () => {
    const impossible = {
      ...runningFullRun,
      layers: runningFullRun.layers.map((layer, index) => index === 0
        ? { ...layer, state: "pending" }
        : index === 1
          ? { ...layer, state: "passed" }
          : layer),
    };
    vi.stubGlobal("window", {
      __CLUSTER_YOUR_CODEX__: { fullRunCheckStatus: vi.fn(async () => impossible) },
    });
    await expect(new IntegrationClient().fullRunCheckStatus()).rejects.toMatchObject({ code: "invalid_native_response" });

    const lateFailure = {
      ...fullRun,
      state: "failed",
      failure: { code: "plugin_runtime_changed", retryable: true },
      layers: fullRun.layers.map((layer, index) => index === 0 ? { ...layer, state: "failed" } : layer),
      integration: {
        ...fullRun.integration,
        activeRuntime: {
          ...fullRun.integration.activeRuntime,
          finalReceiptVerifiedAt: undefined,
          reverifiedAfterRun: false,
        },
      },
      finalFleet: undefined,
    };
    vi.stubGlobal("window", {
      __CLUSTER_YOUR_CODEX__: { fullRunCheck: vi.fn(async () => lateFailure) },
    });
    await expect(new IntegrationClient().fullRunCheck()).resolves.toMatchObject({
      state: "failed",
      failure: { code: "plugin_runtime_changed" },
    });
  });

  it("rejects unknown native states instead of treating them as connected", async () => {
    vi.stubGlobal("window", {
      __CLUSTER_YOUR_CODEX__: {
        integrationStatus: vi.fn(async () => ({ ...status, state: "available" })),
      },
    });
    const error = await new IntegrationClient().status().catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(IntegrationApiError);
    expect(error).toMatchObject({ code: "invalid_native_response" });
  });

  it("does not expose native error details", async () => {
    vi.stubGlobal("window", {
      __CLUSTER_YOUR_CODEX__: {
        integrationStatus: vi.fn(async () => {
          throw { code: "codex_cli_broken", stderr: "password=must-not-leak" };
        }),
      },
    });
    const error = await new IntegrationClient().status().catch((caught: unknown) => caught);
    expect(error).toMatchObject({ code: "codex_cli_broken" });
    expect(String(error)).not.toContain("must-not-leak");
  });

  it("rejects a Full Run PASS without downloaded proof evidence", async () => {
    vi.stubGlobal("window", {
      __CLUSTER_YOUR_CODEX__: {
        fullRunCheck: vi.fn(async () => ({ ...fullRun, artifacts: [] })),
      },
    });
    const error = await new IntegrationClient().fullRunCheck().catch((caught: unknown) => caught);
    expect(error).toMatchObject({ code: "invalid_native_response" });
  });

  it("rejects contradictory PASS receipts, duplicate checks, and regressing job states", async () => {
    const invalidResults = [
      { ...fullRun, job: { ...fullRun.job, exitCode: 1 } },
      { ...fullRun, job: { ...fullRun.job, observedStates: ["queued", "running", "preparing", "succeeded"] } },
      { ...fullRun, cleanup: { ...fullRun.cleanup, runId: "607292ff-ebce-46a8-865f-ee55ee5794f7" } },
      { ...fullRun, integration: { ...fullRun.integration, activeRuntime: { ...fullRun.integration.activeRuntime, reverifiedAfterRun: false } } },
      { ...fullRun, integration: { ...fullRun.integration, selfTestExecutor: undefined } },
      { ...fullRun, integration: { ...fullRun.integration, selfTestExecutor: { ...fullRun.integration.selfTestExecutor, pid: fullRun.integration.activeRuntime.pid } } },
      { ...fullRun, integration: { ...fullRun.integration, selfTestExecutor: { ...fullRun.integration.selfTestExecutor, initializeCompleted: false } } },
      { ...fullRun, integration: { ...fullRun.integration, selfTestExecutor: { ...fullRun.integration.selfTestExecutor, sessionId: "00000000-0000-0000-0000-000000000000" } } },
      { ...fullRun, finalFleet: undefined },
      { ...fullRun, finalFleet: { ...fullRun.finalFleet, fleetRevision: 10 } },
      { ...fullRun, finalFleet: { ...fullRun.finalFleet, observedAt: "2026-08-23 01:00:00Z" } },
    ];
    for (const invalidResult of invalidResults) {
      vi.stubGlobal("window", { __CLUSTER_YOUR_CODEX__: { fullRunCheck: vi.fn(async () => invalidResult) } });
      await expect(new IntegrationClient().fullRunCheck()).rejects.toMatchObject({ code: "invalid_native_response" });
    }

    vi.stubGlobal("window", {
      __CLUSTER_YOUR_CODEX__: {
        integrationSelfTest: vi.fn(async () => ({
          passed: true,
          durationMs: 1,
          restartRecommended: false,
          checks: [
            { id: "same", passed: true, message: "first" },
            { id: "same", passed: true, message: "duplicate" },
          ],
          selfTestExecutor,
          status: { ...status, state: "connected", pluginEnabled: true, agentsIntegrated: true, agentsBlockSha256: "1".repeat(64), installedVersion: "0.1.0", activeRuntime },
        })),
      },
    });
    await expect(new IntegrationClient().selfTest()).rejects.toMatchObject({ code: "invalid_native_response" });
  });

  it("rejects connected state without verified global AGENTS evidence", async () => {
    vi.stubGlobal("window", {
      __CLUSTER_YOUR_CODEX__: {
        integrationStatus: vi.fn(async () => ({ ...status, state: "connected", pluginEnabled: true })),
      },
    });
    const error = await new IntegrationClient().status().catch((caught: unknown) => caught);
    expect(error).toMatchObject({ code: "invalid_native_response" });
  });

  it("requires active runtime identity only for Connected status", async () => {
    const exactConnected = {
      ...status,
      state: "connected",
      pluginEnabled: true,
      agentsIntegrated: true,
      agentsBlockSha256: "1".repeat(64),
      installedVersion: "0.1.0",
    };
    for (const body of [exactConnected, { ...status, activeRuntime }]) {
      vi.stubGlobal("window", { __CLUSTER_YOUR_CODEX__: { integrationStatus: vi.fn(async () => body) } });
      await expect(new IntegrationClient().status()).rejects.toMatchObject({ code: "invalid_native_response" });
    }
  });

  it("rejects a Full Run PASS without controller placement evidence", async () => {
    vi.stubGlobal("window", {
      __CLUSTER_YOUR_CODEX__: {
        fullRunCheck: vi.fn(async () => ({ ...fullRun, placement: undefined })),
      },
    });
    const error = await new IntegrationClient().fullRunCheck().catch((caught: unknown) => caught);
    expect(error).toMatchObject({ code: "invalid_native_response" });
  });

  it("accepts a layered native failure but never promotes it to PASS", async () => {
    vi.stubGlobal("window", {
      __CLUSTER_YOUR_CODEX__: {
        fullRunCheck: vi.fn(async () => ({
          ...fullRun,
          state: "failed",
          failure: { code: "remote_execution_timeout", retryable: true },
          layers: fullRun.layers.map((layer) => layer.id === "remote_execution"
            ? { ...layer, state: "failed", message: "Timed out" }
            : layer.id === "log_verification" || layer.id === "artifact_verification"
              ? { ...layer, state: "skipped", message: "Skipped" }
              : layer),
          job: undefined,
          logs: [],
          artifacts: [],
        })),
      },
    });
    await expect(new IntegrationClient().fullRunCheck()).resolves.toMatchObject({
      state: "failed",
      failure: { code: "remote_execution_timeout", retryable: true },
    });
  });
});
