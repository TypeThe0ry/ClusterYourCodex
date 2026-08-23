import type {
  CancelJobResponse,
  ControllerHealthPayload,
  FleetInfo,
  FleetPayload,
  HealthResponse,
  JobResponse,
  JobSummary,
  FleetNodeViewPayload,
  NodePayload,
  NodeSummary,
  PlacementExplanationPayload,
  PlacementPlanBindingV1,
  PlanRequest,
  PlanResponse,
  SubmitJobRequest,
  SubmitJobResponse,
} from "./types";
import {
  ControllerTransportError,
  MAX_RENDERER_REQUEST_TIMEOUT_MS,
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
    if (
      !Number.isSafeInteger(this.timeoutMs) ||
      this.timeoutMs <= 0 ||
      this.timeoutMs > MAX_RENDERER_REQUEST_TIMEOUT_MS
    ) {
      throw new RangeError(
        `Controller timeout must be an integer from 1 to ${MAX_RENDERER_REQUEST_TIMEOUT_MS} ms`,
      );
    }
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
    return this.request<unknown>("POST", "/v1/plans", payload).then(parsePlanBinding);
  }

  submit(payload: SubmitJobRequest): Promise<SubmitJobResponse> {
    return this.request<unknown>("POST", "/v1/jobs", payload).then(parseJobResponse);
  }

  job(jobId: string): Promise<JobResponse> {
    return this.request<unknown>("GET", `/v1/jobs/${encodeURIComponent(jobId)}`).then(parseJobResponse);
  }

  cancel(jobId: string): Promise<CancelJobResponse> {
    return this.request<unknown>("POST", `/v1/jobs/${encodeURIComponent(jobId)}/cancel`).then(parseJobResponse);
  }

  private async request<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
    let timeout: ReturnType<typeof globalThis.setTimeout> | undefined;
    const deadlineMs = Date.now() + this.timeoutMs;

    try {
      const rendererWaitMs = Math.max(0, deadlineMs - Date.now());
      const response = await Promise.race([
        this.transport.request(
          method === "POST"
            ? { method, path, deadlineMs, body: body ?? {} }
            : { method, path, deadlineMs },
        ),
        new Promise<never>((_, reject) => {
          timeout = globalThis.setTimeout(
            () => reject(new ControllerApiError(`Controller did not respond within ${this.timeoutMs} ms`)),
            rendererWaitMs,
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

const uuidPattern = /^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const sha256Pattern = /^[0-9a-f]{64}$/;
const rejectionCodes = new Set([
  "disabled", "offline", "draining", "stale_node", "manual_node_required", "manual_node_mismatch",
  "wrong_os", "wrong_architecture", "missing_capability", "insufficient_cpu", "insufficient_memory",
  "insufficient_disk", "gpu_required", "gpu_unavailable", "gpu_vendor_mismatch", "insufficient_vram",
  "exclusive_gpu_unavailable", "policy_job_kind_denied", "battery_disallowed", "cpu_limit_exceeded",
  "cpu_ewma_limit_exceeded", "memory_limit_exceeded", "temperature_limit_exceeded", "slot_limit_reached",
  "containment_limit_reached",
]);

function hasOnlyKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const allowed = new Set(keys);
  return Object.keys(value).every((key) => allowed.has(key));
}

export function isStrictRfc3339(value: unknown): value is string {
  if (typeof value !== "string" || value.length < 20 || value.length > 64) return false;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$/.exec(value);
  if (!match) return false;
  const [, yearText, monthText, dayText, hourText, minuteText, secondText, , zone] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > monthDays[month - 1]! ||
      hour > 23 || minute > 59 || second > 59) return false;
  if (zone !== "Z") {
    const offsetHour = Number(zone!.slice(1, 3));
    const offsetMinute = Number(zone!.slice(4, 6));
    if (offsetHour > 23 || offsetMinute > 59) return false;
  }
  return Number.isFinite(Date.parse(value));
}

function validTimestamp(value: unknown): value is string {
  return isStrictRfc3339(value);
}

function validEvidenceText(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0 &&
    new TextEncoder().encode(value).length <= 256 && !/[\u0000-\u001f\u007f-\u009f]/u.test(value);
}

function parsePlanBinding(value: unknown): PlacementPlanBindingV1 {
  const invalid = () => new ControllerApiError("Controller returned an invalid placement plan binding", {
    code: "invalid_response",
  });
  if (!isRecord(value) || !hasOnlyKeys(value, [
    "apiVersion", "planId", "jobId", "jobDigest", "createdAt", "expiresAt",
    "fleetRevision", "nodeRevision", "policyRevision", "decision",
  ])) throw invalid();
  if (
    value.apiVersion !== "cyc.dev/placement-plan-binding/v1" ||
    typeof value.planId !== "string" || !uuidPattern.test(value.planId) ||
    typeof value.jobId !== "string" || !uuidPattern.test(value.jobId) ||
    typeof value.jobDigest !== "string" || !sha256Pattern.test(value.jobDigest) ||
    !validTimestamp(value.createdAt) || !validTimestamp(value.expiresAt) ||
    Date.parse(value.createdAt) >= Date.parse(value.expiresAt) ||
    !safeNonnegativeInteger(value.fleetRevision) ||
    !safeNonnegativeInteger(value.nodeRevision) ||
    !safeNonnegativeInteger(value.policyRevision) ||
    !isRecord(value.decision) ||
    !hasOnlyKeys(value.decision, ["nodeId", "score", "explanation"]) ||
    typeof value.decision.nodeId !== "string" || !uuidPattern.test(value.decision.nodeId) ||
    typeof value.decision.score !== "number" || !Number.isSafeInteger(value.decision.score)
  ) throw invalid();
  const decisionNodeId = value.decision.nodeId;
  const decisionScore = value.decision.score;
  const explanation = parseStrictPlacement(value.decision.explanation);
  if (
    explanation.selectedNodeId !== decisionNodeId ||
    explanation.candidates.filter((candidate) => candidate.nodeId === decisionNodeId && candidate.eligible && candidate.score === decisionScore).length !== 1
  ) throw invalid();
  return {
    apiVersion: value.apiVersion,
    planId: value.planId,
    jobId: value.jobId,
    jobDigest: value.jobDigest,
    createdAt: value.createdAt,
    expiresAt: value.expiresAt,
    fleetRevision: value.fleetRevision,
    nodeRevision: value.nodeRevision,
    policyRevision: value.policyRevision,
    decision: { nodeId: decisionNodeId, score: decisionScore, explanation },
  };
}

function parseStrictPlacement(value: unknown): PlacementExplanationPayload {
  if (!isRecord(value) || !hasOnlyKeys(value, ["policy", "selectedNodeId", "candidates"]) ||
      !["balanced", "performance", "manual"].includes(String(value.policy)) ||
      typeof value.selectedNodeId !== "string" || !uuidPattern.test(value.selectedNodeId) ||
      !Array.isArray(value.candidates) || value.candidates.length < 1 || value.candidates.length > 256) {
    throw new ControllerApiError("Controller returned invalid placement evidence", { code: "invalid_response" });
  }
  const nodeIds = new Set<string>();
  const candidates = value.candidates.map((entry) => {
    if (!isRecord(entry) || !hasOnlyKeys(entry, ["nodeId", "nodeName", "eligible", "score", "scoreComponents", "rejectionReasons"]) ||
        typeof entry.nodeId !== "string" || !uuidPattern.test(entry.nodeId) || nodeIds.has(entry.nodeId) ||
        !validEvidenceText(entry.nodeName) ||
        typeof entry.eligible !== "boolean" ||
        (entry.score !== undefined && (typeof entry.score !== "number" || !Number.isSafeInteger(entry.score))) ||
        !Array.isArray(entry.scoreComponents) || entry.scoreComponents.length > 64 ||
        !Array.isArray(entry.rejectionReasons) || entry.rejectionReasons.length > 64) {
      throw new ControllerApiError("Controller returned invalid placement evidence", { code: "invalid_response" });
    }
    nodeIds.add(entry.nodeId);
    const componentKeys = new Set<string>();
    let componentSum = 0;
    const scoreComponents = entry.scoreComponents.map((component) => {
      if (!isRecord(component) || !hasOnlyKeys(component, ["key", "value", "detail"]) ||
          !validEvidenceText(component.key) || componentKeys.has(component.key) ||
          typeof component.value !== "number" || !Number.isSafeInteger(component.value) || typeof component.detail !== "string" ||
          !validEvidenceText(component.detail) || !Number.isSafeInteger(componentSum + component.value)) {
        throw new ControllerApiError("Controller returned invalid placement evidence", { code: "invalid_response" });
      }
      componentKeys.add(component.key);
      componentSum += component.value;
      return { key: component.key, value: component.value, detail: component.detail };
    });
    const rejectionCodeSet = new Set<string>();
    const rejectionReasons = entry.rejectionReasons.map((rejection) => {
      if (!isRecord(rejection) || !hasOnlyKeys(rejection, ["code", "detail"]) ||
          typeof rejection.code !== "string" || !rejectionCodes.has(rejection.code) || rejectionCodeSet.has(rejection.code) ||
          !validEvidenceText(rejection.detail)) {
        throw new ControllerApiError("Controller returned invalid placement evidence", { code: "invalid_response" });
      }
      rejectionCodeSet.add(rejection.code);
      return { code: rejection.code, detail: rejection.detail };
    });
    if (entry.eligible ? (entry.score === undefined || scoreComponents.length < 1 || componentSum !== entry.score || rejectionReasons.length !== 0) :
      (entry.score !== undefined || scoreComponents.length !== 0 || rejectionReasons.length < 1)) {
      throw new ControllerApiError("Controller returned invalid placement evidence", { code: "invalid_response" });
    }
    return { nodeId: entry.nodeId, nodeName: entry.nodeName, eligible: entry.eligible,
      ...(entry.score === undefined ? {} : { score: entry.score }), scoreComponents, rejectionReasons };
  });
  return { policy: value.policy as PlacementExplanationPayload["policy"], selectedNodeId: value.selectedNodeId, candidates };
}

function safeNonnegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function parseJobResponse(value: unknown): JobResponse {
  if (!isRecord(value) || !hasOnlyKeys(value, ["job", "run", "planBinding", "version", "cancelRequested"]) ||
      !isRecord(value.job) || !isRecord(value.run) || typeof value.job.id !== "string" || !uuidPattern.test(value.job.id) ||
      typeof value.run.id !== "string" || !uuidPattern.test(value.run.id) || value.run.jobId !== value.job.id ||
      !validTimestamp(value.run.createdAt) ||
      (value.run.startedAt !== undefined && !validTimestamp(value.run.startedAt)) ||
      (value.run.finishedAt !== undefined && !validTimestamp(value.run.finishedAt)) ||
      (validTimestamp(value.run.startedAt) && Date.parse(value.run.startedAt) < Date.parse(value.run.createdAt)) ||
      (validTimestamp(value.run.startedAt) && validTimestamp(value.run.finishedAt) && Date.parse(value.run.finishedAt) < Date.parse(value.run.startedAt)) ||
      !safeNonnegativeInteger(value.version) || typeof value.cancelRequested !== "boolean") {
    throw new ControllerApiError("Controller returned an invalid job document", { code: "invalid_response" });
  }
  const planBinding = value.planBinding === null ? null : parsePlanBinding(value.planBinding);
  if (planBinding !== null && (planBinding.jobId !== value.job.id || value.run.nodeId !== planBinding.decision.nodeId)) {
    throw new ControllerApiError("Controller returned a job with mismatched placement authority", { code: "invalid_response" });
  }
  return value as unknown as JobResponse;
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

export function nodeDashboardStatus(
  availability: NodeSummary["availability"],
  legacyStatus: NodePayload["status"],
  activeJobs: number,
): NodeSummary["status"] {
  if (availability) {
    switch (availability) {
      case "available":
      case "degraded":
        return activeJobs > 0 ? "busy" : "online";
      case "offline":
      case "stale":
      case "disabled":
        return "offline";
      case "draining":
        return "unknown";
    }
  }
  switch (legacyStatus) {
    case "online":
    case "degraded":
      return activeJobs > 0 ? "busy" : "online";
    case "offline":
      return "offline";
    case "draining":
      return "unknown";
  }
}

function normalizeNode(node: NodePayload, view?: FleetNodeViewPayload): NodeSummary {
  const telemetry = view?.telemetry.document;
  const inventory = view?.inventory.document;
  const resources = view?.effectiveResources ?? node.resources;
  const gpu = resources.gpus[0];
  const activeJobs = Math.max(
    node.load.runningJobs,
    telemetry?.activeRunIds.length ?? 0,
    view?.reservations.length ?? 0,
  );
  const status = nodeDashboardStatus(view?.availability, node.status, activeJobs);

  return {
    id: node.id,
    name: node.name,
    address: nodeAddress(node),
    os: inventory?.os ?? node.os,
    arch: inventory?.arch ?? node.arch,
    status,
    priority: node.priority,
    capabilities: inventory?.capabilities ?? node.capabilities,
    resources: {
      cpuPercent: telemetry?.load.cpuPercent ?? node.load.cpuPercent,
      memoryUsedMiB: Math.max(
        0,
        (inventory?.memoryMiB ?? node.resources.memoryMib) -
          (telemetry?.availableMemoryMiB ?? node.resources.availableMemoryMib),
      ),
      memoryTotalMiB: inventory?.memoryMiB ?? node.resources.memoryMib,
      vramUsedMiB: gpu ? Math.max(0, gpu.totalVramMib - gpu.availableVramMib) : undefined,
      vramTotalMiB: gpu?.totalVramMib,
    },
    lastSeenAt: view?.telemetry.receivedAt ?? node.lastSeenAt,
    activeJobs,
    availability: view?.availability,
    availabilityReasons: view?.availabilityReasons,
    slots: view?.effectiveSlots,
    telemetry: view
      ? {
          observedAt: view.telemetry.document.observedAt,
          receivedAt: view.telemetry.receivedAt,
          bootGeneration: view.telemetry.document.bootGeneration,
          bootId: view.telemetry.document.bootId,
          sequence: view.telemetry.document.sequence,
          cpuEwmaPercent: view.telemetry.document.cpuEwmaPercent,
          powerSource: view.telemetry.document.powerSource,
          temperatureC: view.telemetry.document.temperatureC,
        }
      : undefined,
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
    placement: view.run.placement,
  };
}

function normalizeFleet(payload: FleetPayload): FleetInfo {
  if (
    !Number.isSafeInteger(payload.fleetRevision) ||
    payload.fleetRevision < 0 ||
    !isStrictRfc3339(payload.observedAt)
  ) {
    throw new ControllerApiError("Controller returned invalid fleet snapshot metadata", {
      code: "invalid_response",
    });
  }
  const views = new Map((payload.nodeViews ?? []).map((view) => [view.nodeId, view]));
  const nodes = payload.nodes.map((node) => normalizeNode(node, views.get(node.id)));
  const nodeNames = new Map(nodes.map((node) => [node.id, node.name]));
  const recentJobs = payload.recentJobs.map((job) => normalizeJob(parseJobResponse(job), nodeNames));
  const runningStates = new Set(["preparing", "running", "verifying"]);
  const today = new Date().toDateString();

  return {
    fleetRevision: payload.fleetRevision,
    observedAt: payload.observedAt,
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
      // "available" means the controller supports an MCP integration route;
      // it is not evidence that Codex loaded the plugin. Only a real heartbeat
      // or the native MCP self-test may report a connected integration.
      connected: payload.codex.status === "connected",
    },
    nodes,
    recentJobs,
  };
}

/** Prevent an older overlapping fleet request from overwriting newer
 * telemetry. Equal revisions use the authoritative observedAt timestamp. */
export function preferNewerFleetSnapshot(
  current: FleetInfo | undefined,
  incoming: FleetInfo,
): FleetInfo {
  if (!current || incoming.fleetRevision > current.fleetRevision) return incoming;
  if (incoming.fleetRevision === current.fleetRevision && Date.parse(incoming.observedAt) > Date.parse(current.observedAt)) {
    return incoming;
  }
  return current;
}

export const controllerClient = new ControllerClient({
  transport: defaultControllerTransport(),
});
