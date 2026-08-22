import type {
  FleetInfo,
  HealthResponse,
  JobResponse,
  JobSpec,
  PlacementExplanation,
  PlanResponse,
} from "./types.js";
import { FileBearerTokenSource, TokenSourceError, type BearerTokenSource } from "./token-source.js";
import { assertLoopbackControllerUrl } from "./controller-url.js";

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
    this.fetchImpl = options.fetchImpl ?? globalThis.fetch.bind(globalThis);
    this.tokenSource = options.tokenSource ?? new FileBearerTokenSource();
  }

  health(): Promise<HealthResponse> {
    return this.request("GET", "/v1/health");
  }

  fleet(): Promise<FleetInfo> {
    return this.request("GET", "/v1/fleet");
  }

  plan(job: JobSpec): Promise<PlanResponse> {
    return this.request("POST", "/v1/plans", { job });
  }

  submit(job: JobSpec, planId?: string): Promise<JobResponse> {
    return this.request("POST", "/v1/jobs", planId === undefined ? { job } : { job, planId });
  }

  job(jobId: string): Promise<JobResponse> {
    return this.request("GET", `/v1/jobs/${encodeURIComponent(jobId)}`);
  }

  cancel(jobId: string): Promise<JobResponse> {
    return this.request("POST", `/v1/jobs/${encodeURIComponent(jobId)}/cancel`);
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
      if (error instanceof DOMException && error.name === "AbortError") {
        throw new ControllerRequestError(`Controller timed out during ${method} ${path}`);
      }
      throw new ControllerRequestError(`Local controller unavailable during ${method} ${path}`);
    } finally {
      clearTimeout(timeout);
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
