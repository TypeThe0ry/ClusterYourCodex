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
  PlanRequest,
  PlanResponse,
  SubmitJobRequest,
  SubmitJobResponse,
} from "./types";

const DEFAULT_CONTROLLER_URL = "http://127.0.0.1:47831";

export class ControllerApiError extends Error {
  readonly status?: number;
  readonly requestId?: string;

  constructor(message: string, options: { status?: number; requestId?: string } = {}) {
    super(message);
    this.name = "ControllerApiError";
    this.status = options.status;
    this.requestId = options.requestId;
  }
}

export interface ControllerClientOptions {
  baseUrl?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

export class ControllerClient {
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch;

  constructor(options: ControllerClientOptions = {}) {
    this.baseUrl = (options.baseUrl ?? DEFAULT_CONTROLLER_URL).replace(/\/$/, "");
    this.timeoutMs = options.timeoutMs ?? 8_000;
    this.fetchImpl = options.fetchImpl ?? globalThis.fetch.bind(globalThis);
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
    const controller = new AbortController();
    const timeout = globalThis.setTimeout(() => controller.abort(), this.timeoutMs);

    try {
      const response = await this.fetchImpl(`${this.baseUrl}${path}`, {
        method,
        body: body === undefined ? undefined : JSON.stringify(body),
        headers: body === undefined ? undefined : { "content-type": "application/json" },
        signal: controller.signal,
      });

      const requestId = response.headers.get("x-request-id") ?? undefined;
      if (!response.ok) {
        throw new ControllerApiError(
          `Controller request failed (${response.status} ${response.statusText})`,
          { status: response.status, requestId },
        );
      }

      return (await response.json()) as T;
    } catch (error) {
      if (error instanceof ControllerApiError) {
        throw error;
      }
      if (error instanceof DOMException && error.name === "AbortError") {
        throw new ControllerApiError(`Controller did not respond within ${this.timeoutMs} ms`);
      }
      throw new ControllerApiError("Could not reach the local ClusterYourCodex controller");
    } finally {
      globalThis.clearTimeout(timeout);
    }
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
  baseUrl: import.meta.env.VITE_CONTROLLER_URL || DEFAULT_CONTROLLER_URL,
});
