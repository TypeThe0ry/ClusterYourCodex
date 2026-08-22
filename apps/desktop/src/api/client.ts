import type {
  CancelJobResponse,
  ControllerHealthPayload,
  FleetInfo,
  FleetPayload,
  HealthResponse,
  JobResponse,
  JobSummary,
  NodePayload,
  NodeSummary,
  PlacementExplanationPayload,
  PlanRequest,
  PlanResponse,
  SubmitJobRequest,
  SubmitJobResponse,
} from "./types";
import {
  ControllerTransportError,
  defaultControllerTransport,
  type ControllerTransport,
} from "./auth";

export class ControllerApiError extends Error {
  readonly status?: number;
  readonly requestId?: string;
  readonly code?: string;
  readonly placement?: PlacementExplanationPayload;

  constructor(
    message: string,
    options: {
      status?: number;
      requestId?: string;
      code?: string;
      placement?: PlacementExplanationPayload;
    } = {},
  ) {
    super(message);
    this.name = "ControllerApiError";
    this.status = options.status;
    this.requestId = options.requestId;
    this.code = options.code;
    this.placement = options.placement;
  }
}

export interface ControllerClientOptions {
  timeoutMs?: number;
  transport?: ControllerTransport;
}

export class ControllerClient {
  private readonly timeoutMs: number;
  private readonly transport: ControllerTransport;

  constructor(options: ControllerClientOptions = {}) {
    this.timeoutMs = options.timeoutMs ?? 8_000;
    this.transport = options.transport ?? defaultControllerTransport();
  }

  health(): Promise<HealthResponse> {
    return this.request<ControllerHealthPayload>("GET", "/v1/health").then((payload) => ({
      status: "ready",
      version: payload.controllerVersion,
      apiVersion: payload.apiVersion,
    }));
  }

  fleet(): Promise<FleetInfo> {
    return this.request<FleetPayload>("GET", "/v1/fleet").then(normalizeFleet);
  }

  plan(payload: PlanRequest): Promise<PlanResponse> {
    return this.request("POST", "/v1/plans", payload);
  }

  submit(payload: SubmitJobRequest): Promise<SubmitJobResponse> {
    return this.request("POST", "/v1/jobs", payload);
  }

  job(jobId: string): Promise<JobResponse> {
    return this.request("GET", `/v1/jobs/${encodeURIComponent(jobId)}`);
  }

  cancel(jobId: string): Promise<CancelJobResponse> {
    return this.request("POST", `/v1/jobs/${encodeURIComponent(jobId)}/cancel`);
  }

  private async request<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
    let timeout: ReturnType<typeof globalThis.setTimeout> | undefined;

    try {
      const response = await Promise.race([
        this.transport.request(method === "POST" ? { method, path, body: body ?? {} } : { method, path }),
        new Promise<never>((_, reject) => {
          timeout = globalThis.setTimeout(
            () => reject(new ControllerApiError(`Controller did not respond within ${this.timeoutMs} ms`)),
            this.timeoutMs,
          );
        }),
      ]);

      const requestId = safeRequestId(headerValue(response.headers, "x-request-id"));
      if (response.status < 200 || response.status >= 300) {
        const publicError = readPublicControllerError(response.body);
        throw new ControllerApiError(
          publicErrorMessage(response.status, publicError.code),
          {
            status: response.status,
            ...(requestId ? { requestId } : {}),
            ...(publicError.code ? { code: publicError.code } : {}),
            ...(publicError.placement ? { placement: publicError.placement } : {}),
          },
        );
      }

      return response.body as T;
    } catch (error) {
      if (error instanceof ControllerApiError) {
        throw error;
      }
      if (error instanceof ControllerTransportError) {
        throw new ControllerApiError(error.message, { code: "transport_unavailable" });
      }
      throw new ControllerApiError("Could not reach the local ClusterYourCodex controller");
    } finally {
      if (timeout !== undefined) globalThis.clearTimeout(timeout);
    }
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function safeText(value: unknown, maximum: number): string | undefined {
  return typeof value === "string" && value.length > 0 && value.length <= maximum ? value : undefined;
}

function safeRequestId(value: string | null): string | undefined {
  return value && /^[A-Za-z0-9._:-]{1,128}$/.test(value) ? value : undefined;
}

function headerValue(headers: Record<string, string> | undefined, name: string): string | null {
  if (!headers) return null;
  const match = Object.entries(headers).find(([key]) => key.toLowerCase() === name);
  return match?.[1] ?? null;
}

function sanitizePlacement(value: unknown): PlacementExplanationPayload | undefined {
  if (!isRecord(value) || !["balanced", "performance", "manual"].includes(String(value.policy))) return undefined;
  if (!Array.isArray(value.candidates) || value.candidates.length > 256) return undefined;
  const candidates: PlacementExplanationPayload["candidates"] = [];

  for (const candidateValue of value.candidates) {
    if (!isRecord(candidateValue)) return undefined;
    const nodeId = safeText(candidateValue.nodeId, 64);
    const nodeName = safeText(candidateValue.nodeName, 256);
    if (!nodeId || !nodeName || typeof candidateValue.eligible !== "boolean") return undefined;
    const scoreComponents = Array.isArray(candidateValue.scoreComponents)
      ? candidateValue.scoreComponents.flatMap((component) => {
          if (!isRecord(component)) return [];
          const key = safeText(component.key, 128);
          const detail = safeText(component.detail, 512);
          return key && detail && typeof component.value === "number" ? [{ key, value: component.value, detail }] : [];
        })
      : [];
    const rejectionReasons = Array.isArray(candidateValue.rejectionReasons)
      ? candidateValue.rejectionReasons.flatMap((reason) => {
          if (!isRecord(reason)) return [];
          const code = safeText(reason.code, 128);
          const detail = safeText(reason.detail, 512);
          return code && detail ? [{ code, detail }] : [];
        })
      : [];
    candidates.push({
      nodeId,
      nodeName,
      eligible: candidateValue.eligible,
      ...(typeof candidateValue.score === "number" ? { score: candidateValue.score } : {}),
      scoreComponents,
      rejectionReasons,
    });
  }

  const policy = value.policy as PlacementExplanationPayload["policy"];
  const selectedNodeId = safeText(value.selectedNodeId, 64);
  return selectedNodeId === undefined ? { policy, candidates } : { policy, selectedNodeId, candidates };
}

function readPublicControllerError(
  body: unknown,
): { code?: string; placement?: PlacementExplanationPayload } {
  if (!isRecord(body) || !isRecord(body.error)) return {};
  const code = safeText(body.error.code, 64);
  const placement = sanitizePlacement(body.error.placement ?? body.error.details);
  return {
    ...(code && /^[a-z0-9_]+$/.test(code) ? { code } : {}),
    ...(placement ? { placement } : {}),
  };
}

function publicErrorMessage(status: number, code?: string): string {
  if (status === 401 || status === 403) return "Controller authentication failed";
  switch (code) {
    case "no_eligible_node":
      return "No connected computer satisfies the job requirements";
    case "invalid_job":
      return "Controller rejected the JobSpec";
    case "plan_mismatch":
      return "Placement plan does not match this job";
    case "not_found":
      return "Requested controller resource was not found";
    default:
      return `Controller request failed (${status})`;
  }
}

function nodeAddress(node: NodePayload): string {
  switch (node.transport.type) {
    case "ssh":
      return `${node.transport.host}:${node.transport.port}`;
    case "managed":
      return node.transport.endpoint;
    case "local":
      return "This computer";
  }
}

function normalizeNode(node: NodePayload): NodeSummary {
  const gpu = node.resources.gpus[0];
  const status =
    node.status === "offline"
      ? "offline"
      : node.load.runningJobs > 0
        ? "busy"
        : node.status === "online"
          ? "online"
          : "unknown";

  return {
    id: node.id,
    name: node.name,
    address: nodeAddress(node),
    os: node.os,
    arch: node.arch,
    status,
    priority: node.priority,
    capabilities: node.capabilities,
    resources: {
      cpuPercent: node.load.cpuPercent,
      memoryUsedMiB: Math.max(0, node.resources.memoryMib - node.resources.availableMemoryMib),
      memoryTotalMiB: node.resources.memoryMib,
      vramUsedMiB: gpu ? Math.max(0, gpu.totalVramMib - gpu.availableVramMib) : undefined,
      vramTotalMiB: gpu?.totalVramMib,
    },
    lastSeenAt: node.lastSeenAt,
    activeJobs: node.load.runningJobs,
  };
}

function normalizeJob(
  view: FleetPayload["recentJobs"][number],
  nodeNames: ReadonlyMap<string, string>,
): JobSummary {
  const started = view.run.startedAt ? Date.parse(view.run.startedAt) : undefined;
  const finished = view.run.finishedAt ? Date.parse(view.run.finishedAt) : undefined;
  return {
    id: view.run.id,
    kind: view.job.kind,
    title: view.job.steps[0]?.name,
    status: view.run.state,
    nodeId: view.run.nodeId,
    nodeName: view.run.nodeId ? nodeNames.get(view.run.nodeId) : undefined,
    createdAt: view.run.createdAt,
    startedAt: view.run.startedAt,
    finishedAt: view.run.finishedAt,
    exitCode: view.run.exitCode,
    elapsedMs: started === undefined ? undefined : Math.max(0, (finished ?? Date.now()) - started),
  };
}

function normalizeFleet(payload: FleetPayload): FleetInfo {
  const nodes = payload.nodes.map(normalizeNode);
  const nodeNames = new Map(nodes.map((node) => [node.id, node.name]));
  const recentJobs = payload.recentJobs.map((job) => normalizeJob(job, nodeNames));
  const runningStates = new Set(["preparing", "running", "verifying"]);
  const today = new Date().toDateString();

  return {
    controller: {
      status: "ready",
      version: payload.controller.version,
      activeJobs: recentJobs.filter((job) => runningStates.has(job.status)).length,
      queuedJobs: recentJobs.filter((job) => job.status === "queued").length,
      completedToday: recentJobs.filter(
        (job) => job.status === "succeeded" && job.finishedAt && new Date(job.finishedAt).toDateString() === today,
      ).length,
    },
    codex: {
      connected: payload.codex.status === "available" || payload.codex.status === "connected",
    },
    nodes,
    recentJobs,
  };
}

export const controllerClient = new ControllerClient({
  transport: defaultControllerTransport(),
});
