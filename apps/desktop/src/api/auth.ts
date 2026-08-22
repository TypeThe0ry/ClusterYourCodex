export type ControllerMethod = "GET" | "POST";

export interface ControllerRequestEnvelope {
  method: ControllerMethod;
  path: string;
  body?: unknown;
}

export interface ControllerResponseEnvelope {
  status: number;
  statusText?: string;
  headers?: Record<string, string>;
  body?: unknown;
}

export interface ControllerTransport {
  request(request: ControllerRequestEnvelope): Promise<ControllerResponseEnvelope>;
}

export interface ClusterYourCodexDesktopBridge {
  /**
   * Runs an authenticated request in the desktop host. The renderer supplies
   * only method/path/body; the host owns the loopback base URL and token file.
   */
  controllerRequest: (request: ControllerRequestEnvelope) => Promise<ControllerResponseEnvelope>;
}

declare global {
  interface Window {
    __CLUSTER_YOUR_CODEX__?: ClusterYourCodexDesktopBridge;
  }
}

export class ControllerTransportError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ControllerTransportError";
  }
}

function assertSafeRequest(request: ControllerRequestEnvelope): void {
  if (!/^\/v1\/[A-Za-z0-9_./%-]+$/.test(request.path) || request.path.includes("..")) {
    throw new ControllerTransportError("Controller request path is invalid");
  }
  if (request.method !== "GET" && request.method !== "POST") {
    throw new ControllerTransportError("Controller request method is invalid");
  }
}

function normalizeResponse(response: ControllerResponseEnvelope): ControllerResponseEnvelope {
  if (!Number.isInteger(response?.status) || response.status < 100 || response.status > 599) {
    throw new ControllerTransportError("Desktop controller bridge returned an invalid response");
  }
  return response;
}

export class DesktopHostControllerTransport implements ControllerTransport {
  async request(request: ControllerRequestEnvelope): Promise<ControllerResponseEnvelope> {
    assertSafeRequest(request);
    const bridge = globalThis.window?.__CLUSTER_YOUR_CODEX__;
    if (!bridge?.controllerRequest) {
      throw new ControllerTransportError("Desktop controller proxy is unavailable");
    }
    try {
      return normalizeResponse(
        await bridge.controllerRequest(
          request.method === "POST" ? { ...request, body: request.body ?? {} } : request,
        ),
      );
    } catch (error) {
      if (error instanceof ControllerTransportError) throw error;
      throw new ControllerTransportError("Desktop controller proxy request failed");
    }
  }
}

export class DevelopmentProxyControllerTransport implements ControllerTransport {
  constructor(private readonly fetchImpl: typeof fetch = globalThis.fetch.bind(globalThis)) {}

  async request(request: ControllerRequestEnvelope): Promise<ControllerResponseEnvelope> {
    assertSafeRequest(request);
    const headers = new Headers();
    const init: RequestInit = { method: request.method };
    if (request.method === "POST") {
      headers.set("content-type", "application/json");
      init.body = JSON.stringify(request.body ?? {});
    }
    init.headers = headers;
    try {
      const response = await this.fetchImpl(`/__cyc_controller${request.path}`, init);
      let body: unknown;
      try {
        body = await response.json();
      } catch {
        body = undefined;
      }
      const responseHeaders: Record<string, string> = {};
      for (const name of ["content-type", "x-request-id", "etag"]) {
        const value = response.headers.get(name);
        if (value) responseHeaders[name] = value;
      }
      return {
        status: response.status,
        statusText: response.statusText,
        headers: responseHeaders,
        body,
      };
    } catch {
      throw new ControllerTransportError("Secure development controller proxy is unavailable");
    }
  }
}

/** Explicit dependency injection for unit tests; never used by production code. */
export function mockControllerProvider(
  handler: (request: ControllerRequestEnvelope) => ControllerResponseEnvelope | Promise<ControllerResponseEnvelope>,
): ControllerTransport {
  if (import.meta.env.MODE !== "test") {
    throw new ControllerTransportError("Mock controller provider is available only in tests");
  }
  return {
    async request(request) {
      assertSafeRequest(request);
      return normalizeResponse(await handler(request));
    },
  };
}

export function defaultControllerTransport(): ControllerTransport {
  return import.meta.env.DEV
    ? new DevelopmentProxyControllerTransport()
    : new DesktopHostControllerTransport();
}
