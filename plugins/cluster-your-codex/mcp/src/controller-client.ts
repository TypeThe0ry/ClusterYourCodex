import type {
  FleetInfo,
  HealthResponse,
  JobResponse,
  JobSpec,
  PlacementExplanation,
  PlacementPlanBindingV1,
  PlanResponse,
  SnapshotMetadata,
} from "./types.js";
import { FileBearerTokenSource, TokenSourceError, type BearerTokenSource } from "./token-source.js";
import { assertLoopbackControllerUrl } from "./controller-url.js";
import {
  SNAPSHOT_API_VERSION,
  SNAPSHOT_ARCHIVE_FORMAT,
  SNAPSHOT_MEDIA_TYPE,
  verifySnapshotArchive,
} from "./snapshot.js";

const DEFAULT_CONTROLLER_URL = "http://127.0.0.1:47831";

export class ControllerRequestError extends Error {
  readonly status: number | undefined;
  readonly requestId: string | undefined;
  readonly code: string | undefined;
  readonly placement: PlacementExplanation | undefined;

  constructor(
    message: string,
    options: { status?: number; requestId?: string; code?: string; placement?: PlacementExplanation } = {},
  ) {
    super(message);
    this.name = "ControllerRequestError";
    this.status = options.status;
    this.requestId = options.requestId;
    this.code = options.code;
    this.placement = options.placement;
  }
}

export class ControllerClient {
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch;
  private readonly tokenSource: BearerTokenSource;

  constructor(
    options: {
      baseUrl?: string;
      timeoutMs?: number;
      fetchImpl?: typeof fetch;
      tokenSource?: BearerTokenSource;
    } = {},
  ) {
    this.baseUrl = assertLoopbackControllerUrl(
      options.baseUrl ?? process.env.CLUSTERYOURCODEX_CONTROLLER_URL ?? DEFAULT_CONTROLLER_URL,
    );
    this.timeoutMs = options.timeoutMs ?? 15_000;
    if (!Number.isSafeInteger(this.timeoutMs) || this.timeoutMs < 1 || this.timeoutMs > 300_000) {
      throw new Error("controller timeoutMs must be an integer from 1 through 300000");
    }
    this.fetchImpl = options.fetchImpl ?? globalThis.fetch.bind(globalThis);
    this.tokenSource = options.tokenSource ?? new FileBearerTokenSource();
  }

  health(): Promise<HealthResponse> {
    return this.request("GET", "/v1/health");
  }

  async fleet(): Promise<FleetInfo> {
    const fleet = await this.request<FleetInfo>("GET", "/v1/fleet");
    if (
      !Number.isSafeInteger(fleet.fleetRevision) ||
      fleet.fleetRevision < 0 ||
      parseStrictRfc3339(fleet.observedAt) === undefined
    ) {
      throw new ControllerRequestError("Controller returned invalid fleet snapshot metadata", {
        code: "invalid_response",
      });
    }
    if (!Array.isArray(fleet.recentJobs)) {
      throw new ControllerRequestError("Controller returned invalid fleet jobs", { code: "invalid_response" });
    }
    fleet.recentJobs = fleet.recentJobs.map(parseJobResponse);
    return fleet;
  }

  async plan(job: JobSpec): Promise<PlanResponse> {
    return parsePlanBinding(await this.request<unknown>("POST", "/v1/plans", { job }));
  }

  async submit(job: JobSpec, planId?: string): Promise<JobResponse> {
    return parseJobResponse(await this.request<unknown>("POST", "/v1/jobs", planId === undefined ? { job } : { job, planId }));
  }

  async planAndSubmit(job: JobSpec): Promise<{ plan: PlanResponse; submission: JobResponse }> {
    const plan = await this.plan(job);
    if (plan.jobId !== job.id) {
      throw new ControllerRequestError("Controller placement plan did not bind the submitted job", {
        code: "plan_mismatch",
      });
    }
    const submission = await this.submit(job, plan.planId);
    if (submission.planBinding === null || !samePlanBinding(submission.planBinding, plan)) {
      throw new ControllerRequestError("Controller job did not retain the original placement plan", {
        code: "plan_mismatch",
      });
    }
    return { plan, submission };
  }

  async uploadSnapshot(input: {
    archivePath: string;
    digest: string;
    sizeBytes: number;
  }): Promise<SnapshotMetadata> {
    const bytes = await verifySnapshotArchive(input.archivePath, input.digest, input.sizeBytes);
    const digestHex = input.digest.slice("sha256:".length);
    const path = `/v1/snapshots/${digestHex}`;
    const abortController = new AbortController();
    const timeout = setTimeout(() => abortController.abort(), this.timeoutMs);
    const requestBody = new ArrayBuffer(bytes.length);
    new Uint8Array(requestBody).set(bytes);

    try {
      const headers = new Headers({
        authorization: `Bearer ${await this.tokenSource.getToken()}`,
        "content-length": String(bytes.length),
        "content-type": SNAPSHOT_MEDIA_TYPE,
      });
      const response = await this.fetchImpl(`${this.baseUrl}${path}`, {
        method: "PUT",
        headers,
        body: requestBody,
        signal: abortController.signal,
      });
      const requestId = safeRequestId(response.headers.get("x-request-id"));
      if (!response.ok) {
        const publicError = await readPublicControllerError(response);
        throw new ControllerRequestError(
          publicErrorMessage(response.status, publicError.code),
          compactErrorOptions(response.status, requestId, publicError.code, publicError.placement),
        );
      }
      validateSnapshotResponseHeaders(response.headers, input.digest, input.sizeBytes);
      return parseSnapshotMetadata(await response.json(), input.digest, input.sizeBytes);
    } catch (error) {
      if (error instanceof ControllerRequestError) throw error;
      if (error instanceof TokenSourceError) {
        throw new ControllerRequestError(error.message, { code: error.code });
      }
      if (isAbortError(error)) {
        throw new ControllerRequestError(`Controller timed out during PUT ${path}`);
      }
      throw new ControllerRequestError(`Local controller unavailable during PUT ${path}`);
    } finally {
      clearTimeout(timeout);
    }
  }

  async job(jobId: string): Promise<JobResponse> {
    return parseJobResponse(await this.request<unknown>("GET", `/v1/jobs/${encodeURIComponent(jobId)}`));
  }

  async cancel(jobId: string): Promise<JobResponse> {
    return parseJobResponse(await this.request<unknown>("POST", `/v1/jobs/${encodeURIComponent(jobId)}/cancel`));
  }

  private async request<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
    const abortController = new AbortController();
    const timeout = setTimeout(() => abortController.abort(), this.timeoutMs);

    try {
      const requestInit: RequestInit = {
        method,
        signal: abortController.signal,
      };
      const headers = new Headers();
      if (path !== "/v1/health") {
        headers.set("authorization", `Bearer ${await this.tokenSource.getToken()}`);
      }
      if (method === "POST") {
        headers.set("content-type", "application/json");
        requestInit.body = JSON.stringify(body ?? {});
      }
      requestInit.headers = headers;
      const response = await this.fetchImpl(`${this.baseUrl}${path}`, requestInit);
      const requestId = safeRequestId(response.headers.get("x-request-id"));

      if (!response.ok) {
        const publicError = await readPublicControllerError(response);
        throw new ControllerRequestError(
          publicErrorMessage(response.status, publicError.code),
          compactErrorOptions(response.status, requestId, publicError.code, publicError.placement),
        );
      }

      return (await response.json()) as T;
    } catch (error) {
      if (error instanceof ControllerRequestError) throw error;
      if (error instanceof TokenSourceError) {
        throw new ControllerRequestError(error.message, { code: error.code });
      }
      if (isAbortError(error)) {
        throw new ControllerRequestError(`Controller timed out during ${method} ${path}`);
      }
      throw new ControllerRequestError(`Local controller unavailable during ${method} ${path}`);
    } finally {
      clearTimeout(timeout);
    }
  }
}

function validateSnapshotResponseHeaders(headers: Headers, digest: string, sizeBytes: number): void {
  const expectedEtag = `"${digest}"`;
  if (headers.get("etag") !== expectedEtag) {
    throw new ControllerRequestError("Controller snapshot response digest did not match the upload", {
      code: "invalid_snapshot_response",
    });
  }
  if (headers.get("x-cyc-snapshot-size") !== String(sizeBytes)) {
    throw new ControllerRequestError("Controller snapshot response size did not match the upload", {
      code: "invalid_snapshot_response",
    });
  }
  if (headers.get("x-cyc-snapshot-version") !== SNAPSHOT_API_VERSION) {
    throw new ControllerRequestError("Controller snapshot response version was unsupported", {
      code: "invalid_snapshot_response",
    });
  }
  if (headers.get("x-cyc-snapshot-format") !== SNAPSHOT_ARCHIVE_FORMAT) {
    throw new ControllerRequestError("Controller snapshot response format was unsupported", {
      code: "invalid_snapshot_response",
    });
  }
}

function parseSnapshotMetadata(value: unknown, digest: string, sizeBytes: number): SnapshotMetadata {
  if (!isRecord(value)) {
    throw new ControllerRequestError("Controller returned invalid snapshot metadata", {
      code: "invalid_snapshot_response",
    });
  }
  if (
    value.apiVersion !== SNAPSHOT_API_VERSION ||
    value.format !== SNAPSHOT_ARCHIVE_FORMAT ||
    value.digest !== digest ||
    value.sizeBytes !== sizeBytes ||
    typeof value.createdAt !== "string" ||
    value.createdAt.length < 1 ||
    value.createdAt.length > 128
  ) {
    throw new ControllerRequestError("Controller returned mismatched snapshot metadata", {
      code: "invalid_snapshot_response",
    });
  }
  return {
    apiVersion: SNAPSHOT_API_VERSION,
    format: SNAPSHOT_ARCHIVE_FORMAT,
    digest: digest as `sha256:${string}`,
    sizeBytes,
    createdAt: value.createdAt,
  };
}

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return value !== null && typeof value === "object" && !Array.isArray(value);
}

const bindingUuidPattern = /^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const bindingDigestPattern = /^[0-9a-f]{64}$/;
const rfc3339Pattern = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|([+-])(\d{2}):(\d{2}))$/;
const bindingRejectionCodes = new Set([
  "disabled", "offline", "draining", "stale_node", "manual_node_required", "manual_node_mismatch",
  "wrong_os", "wrong_architecture", "missing_capability", "insufficient_cpu", "insufficient_memory",
  "insufficient_disk", "gpu_required", "gpu_unavailable", "gpu_vendor_mismatch", "insufficient_vram",
  "exclusive_gpu_unavailable", "policy_job_kind_denied", "battery_disallowed", "cpu_limit_exceeded",
  "cpu_ewma_limit_exceeded", "memory_limit_exceeded", "temperature_limit_exceeded", "slot_limit_reached",
  "containment_limit_reached",
]);

function invalidBinding(message = "Controller returned an invalid placement plan binding"): ControllerRequestError {
  return new ControllerRequestError(message, { code: "invalid_response" });
}

function hasOnlyKeys(value: Record<string, unknown>, keys: readonly string[]): boolean {
  const allowed = new Set(keys);
  return Object.keys(value).every((key) => allowed.has(key));
}

function safeNonnegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function parseStrictRfc3339(value: unknown): bigint | undefined {
  if (typeof value !== "string" || value.length < 20 || value.length > 64) return undefined;
  const match = rfc3339Pattern.exec(value);
  if (!match) return undefined;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (
    year < 1 || month < 1 || month > 12 || day < 1 || day > daysInMonth[month - 1]! ||
    hour > 23 || minute > 59 || second > 59
  ) return undefined;
  const offsetHour = match[10] === undefined ? 0 : Number(match[10]);
  const offsetMinute = match[11] === undefined ? 0 : Number(match[11]);
  if (offsetHour > 23 || offsetMinute > 59) return undefined;

  // Avoid Date.UTC's special 1900 offset for years 00-99. Component checks
  // above reject normalization, while the bigint result preserves all nine
  // RFC3339 fractional digits for exact createdAt/expiresAt ordering.
  const instant = new Date(0);
  instant.setUTCFullYear(year, month - 1, day);
  instant.setUTCHours(hour, minute, second, 0);
  if (!Number.isFinite(instant.getTime())) return undefined;
  const offsetSign = match[9] === "-" ? -1 : 1;
  const offsetMilliseconds = offsetSign * (offsetHour * 60 + offsetMinute) * 60_000;
  const fractionalNanoseconds = BigInt((match[7] ?? "").padEnd(9, "0") || "0");
  return BigInt(instant.getTime() - offsetMilliseconds) * 1_000_000n + fractionalNanoseconds;
}

function validBindingText(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0 &&
    new TextEncoder().encode(value).length <= 256 && !/[\u0000-\u001f\u007f-\u009f]/u.test(value);
}

function parsePlanBinding(value: unknown): PlacementPlanBindingV1 {
  if (!isRecord(value) || !hasOnlyKeys(value, [
    "apiVersion", "planId", "jobId", "jobDigest", "createdAt", "expiresAt",
    "fleetRevision", "nodeRevision", "policyRevision", "decision",
  ])) throw invalidBinding();
  const createdAt = parseStrictRfc3339(value.createdAt);
  const expiresAt = parseStrictRfc3339(value.expiresAt);
  if (
    value.apiVersion !== "cyc.dev/placement-plan-binding/v1" ||
    typeof value.planId !== "string" || !bindingUuidPattern.test(value.planId) ||
    typeof value.jobId !== "string" || !bindingUuidPattern.test(value.jobId) ||
    typeof value.jobDigest !== "string" || !bindingDigestPattern.test(value.jobDigest) ||
    createdAt === undefined || expiresAt === undefined || createdAt >= expiresAt ||
    !safeNonnegativeInteger(value.fleetRevision) || !safeNonnegativeInteger(value.nodeRevision) ||
    !safeNonnegativeInteger(value.policyRevision) || !isRecord(value.decision) ||
    !hasOnlyKeys(value.decision, ["nodeId", "score", "explanation"]) ||
    typeof value.decision.nodeId !== "string" || !bindingUuidPattern.test(value.decision.nodeId) ||
    typeof value.decision.score !== "number" || !Number.isSafeInteger(value.decision.score)
  ) throw invalidBinding();
  validateStrictPlacement(value.decision.explanation, value.decision.nodeId, value.decision.score);
  return value as unknown as PlacementPlanBindingV1;
}

function validateStrictPlacement(value: unknown, selectedNodeId: string, decisionScore: number): void {
  if (!isRecord(value) || !hasOnlyKeys(value, ["policy", "selectedNodeId", "candidates"]) ||
      !["balanced", "performance", "manual"].includes(String(value.policy)) ||
      value.selectedNodeId !== selectedNodeId || !Array.isArray(value.candidates) ||
      value.candidates.length < 1 || value.candidates.length > 256) throw invalidBinding("Controller returned invalid placement evidence");
  const ids = new Set<string>();
  let selected = 0;
  for (const entry of value.candidates) {
    if (!isRecord(entry) || !hasOnlyKeys(entry, ["nodeId", "nodeName", "eligible", "score", "scoreComponents", "rejectionReasons"]) ||
        typeof entry.nodeId !== "string" || !bindingUuidPattern.test(entry.nodeId) || ids.has(entry.nodeId) ||
        !validBindingText(entry.nodeName) ||
        typeof entry.eligible !== "boolean" ||
        (entry.score !== undefined && (typeof entry.score !== "number" || !Number.isSafeInteger(entry.score))) ||
        !Array.isArray(entry.scoreComponents) || entry.scoreComponents.length > 64 ||
        !Array.isArray(entry.rejectionReasons) || entry.rejectionReasons.length > 64) {
      throw invalidBinding("Controller returned invalid placement evidence");
    }
    ids.add(entry.nodeId);
    const componentKeys = new Set<string>();
    let componentSum = 0;
    for (const component of entry.scoreComponents) {
      if (!isRecord(component) || !hasOnlyKeys(component, ["key", "value", "detail"]) ||
          !validBindingText(component.key) || componentKeys.has(component.key) ||
          typeof component.value !== "number" || !Number.isSafeInteger(component.value) ||
          !validBindingText(component.detail) || !Number.isSafeInteger(componentSum + component.value)) {
        throw invalidBinding("Controller returned invalid placement evidence");
      }
      componentKeys.add(component.key);
      componentSum += component.value;
    }
    const rejectionCodes = new Set<string>();
    for (const rejection of entry.rejectionReasons) {
      if (!isRecord(rejection) || !hasOnlyKeys(rejection, ["code", "detail"]) ||
          typeof rejection.code !== "string" || !bindingRejectionCodes.has(rejection.code) || rejectionCodes.has(rejection.code) ||
          !validBindingText(rejection.detail)) {
        throw invalidBinding("Controller returned invalid placement evidence");
      }
      rejectionCodes.add(rejection.code);
    }
    if (entry.eligible) {
      if (entry.score === undefined || entry.scoreComponents.length < 1 || componentSum !== entry.score || entry.rejectionReasons.length !== 0) throw invalidBinding();
    } else if (entry.score !== undefined || entry.scoreComponents.length !== 0 || entry.rejectionReasons.length < 1) {
      throw invalidBinding();
    }
    if (entry.nodeId === selectedNodeId && entry.eligible && entry.score === decisionScore) selected += 1;
  }
  if (selected !== 1) throw invalidBinding();
}

function parseJobResponse(value: unknown): JobResponse {
  if (!isRecord(value) || !hasOnlyKeys(value, ["job", "run", "planBinding", "version", "cancelRequested"]) ||
      !isRecord(value.job) || !isRecord(value.run) || typeof value.job.id !== "string" || !bindingUuidPattern.test(value.job.id) ||
      typeof value.run.id !== "string" || !bindingUuidPattern.test(value.run.id) || value.run.jobId !== value.job.id ||
      !safeNonnegativeInteger(value.version) || typeof value.cancelRequested !== "boolean") {
    throw new ControllerRequestError("Controller returned an invalid job document", { code: "invalid_response" });
  }
  const binding = value.planBinding === null ? null : parsePlanBinding(value.planBinding);
  if (binding !== null && (binding.jobId !== value.job.id || value.run.nodeId !== binding.decision.nodeId)) {
    throw new ControllerRequestError("Controller returned a job with mismatched placement authority", { code: "invalid_response" });
  }
  return value as unknown as JobResponse;
}

function samePlanBinding(left: PlacementPlanBindingV1, right: PlacementPlanBindingV1): boolean {
  return deepEqual(left, right);
}

function deepEqual(left: unknown, right: unknown): boolean {
  if (Object.is(left, right)) return true;
  if (Array.isArray(left) || Array.isArray(right)) {
    return Array.isArray(left) && Array.isArray(right) && left.length === right.length &&
      left.every((value, index) => deepEqual(value, right[index]));
  }
  if (!isRecord(left) || !isRecord(right)) return false;
  const leftKeys = Object.keys(left).sort();
  const rightKeys = Object.keys(right).sort();
  return leftKeys.length === rightKeys.length && leftKeys.every((key, index) =>
    key === rightKeys[index] && deepEqual(left[key], right[key]));
}

function safeText(value: unknown, maximum: number): string | undefined {
  return typeof value === "string" && value.length > 0 && value.length <= maximum ? value : undefined;
}

function safeRequestId(value: string | null): string | undefined {
  return value && /^[A-Za-z0-9._:-]{1,128}$/.test(value) ? value : undefined;
}

function sanitizePlacement(value: unknown): PlacementExplanation | undefined {
  if (!isRecord(value) || !["balanced", "performance", "manual"].includes(String(value.policy))) return undefined;
  if (!Array.isArray(value.candidates) || value.candidates.length > 256) return undefined;
  const candidates: PlacementExplanation["candidates"] = [];

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

  const policy = value.policy as PlacementExplanation["policy"];
  const selectedNodeId = safeText(value.selectedNodeId, 64);
  return selectedNodeId === undefined ? { policy, candidates } : { policy, selectedNodeId, candidates };
}

async function readPublicControllerError(
  response: Response,
): Promise<{ code?: string; placement?: PlacementExplanation }> {
  try {
    const body = (await response.json()) as unknown;
    if (!isRecord(body) || !isRecord(body.error)) return {};
    const code = safeText(body.error.code, 64);
    const placement = sanitizePlacement(body.error.placement ?? body.error.details);
    return {
      ...(code && /^[a-z0-9_]+$/.test(code) ? { code } : {}),
      ...(placement ? { placement } : {}),
    };
  } catch {
    return {};
  }
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

function compactErrorOptions(
  status: number,
  requestId?: string,
  code?: string,
  placement?: PlacementExplanation,
): { status: number; requestId?: string; code?: string; placement?: PlacementExplanation } {
  return {
    status,
    ...(requestId ? { requestId } : {}),
    ...(code ? { code } : {}),
    ...(placement ? { placement } : {}),
  };
}
