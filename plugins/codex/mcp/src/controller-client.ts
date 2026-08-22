import type { FleetInfo, HealthResponse, JobResponse, JobSpec, PlanResponse } from "./types.js";

const DEFAULT_CONTROLLER_URL = "http://127.0.0.1:47831";

export class ControllerRequestError extends Error {
  readonly status: number | undefined;
  readonly requestId: string | undefined;

  constructor(message: string, options: { status?: number; requestId?: string } = {}) {
    super(message);
    this.name = "ControllerRequestError";
    this.status = options.status;
    this.requestId = options.requestId;
  }
}

export class ControllerClient {
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch;

  constructor(options: { baseUrl?: string; timeoutMs?: number; fetchImpl?: typeof fetch } = {}) {
    this.baseUrl = (options.baseUrl ?? process.env.CLUSTERYOURCODEX_CONTROLLER_URL ?? DEFAULT_CONTROLLER_URL).replace(/\/$/, "");
    this.timeoutMs = options.timeoutMs ?? 15_000;
    this.fetchImpl = options.fetchImpl ?? globalThis.fetch.bind(globalThis);
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
      if (body !== undefined) {
        requestInit.body = JSON.stringify(body);
        requestInit.headers = { "content-type": "application/json" };
      }
      const response = await this.fetchImpl(`${this.baseUrl}${path}`, requestInit);
      const requestId = response.headers.get("x-request-id") ?? undefined;

      if (!response.ok) {
        throw new ControllerRequestError(
          `Controller rejected ${method} ${path} (${response.status})`,
          requestId === undefined ? { status: response.status } : { status: response.status, requestId },
        );
      }

      return (await response.json()) as T;
    } catch (error) {
      if (error instanceof ControllerRequestError) throw error;
      if (error instanceof DOMException && error.name === "AbortError") {
        throw new ControllerRequestError(`Controller timed out during ${method} ${path}`);
      }
      throw new ControllerRequestError(`Local controller unavailable during ${method} ${path}`);
    } finally {
      clearTimeout(timeout);
    }
  }
}
