import type { IncomingMessage, ServerResponse } from "node:http";
import { describe, expect, it, vi } from "vitest";
import { assertLoopbackControllerUrl, isAllowedControllerRoute, secureControllerProxy } from "./secure-controller-proxy";

describe("secure Vite controller proxy", () => {
  it.each([
    ["http://127.0.0.1:47831", "http://127.0.0.1:47831"],
    ["https://localhost:47831", "https://localhost:47831"],
    ["http://127.42.7.9:9000", "http://127.42.7.9:9000"],
    ["http://[::1]:47831", "http://[::1]:47831"],
  ])("accepts loopback HTTP(S): %s", (input, expected) => {
    expect(assertLoopbackControllerUrl(input)).toBe(expected);
  });

  it.each([
    "http://192.168.1.10:47831",
    "https://example.com",
    "ftp://127.0.0.1/file",
    "http://user:password@127.0.0.1:47831",
    "http://127.0.0.1:47831/v1",
    "http://localhost.evil.test:47831",
  ])("rejects non-loopback or credential-bearing controller URLs: %s", (input) => {
    expect(() => assertLoopbackControllerUrl(input)).toThrow(/loopback HTTP/);
  });

  it.each([
    ["GET", "/v1/health"],
    ["GET", "/v1/fleet"],
    ["GET", "/v1/jobs/7f26f4f4-5bdd-4d39-84d4-d1b94c16cc9e"],
    ["POST", "/v1/plans"],
    ["POST", "/v1/jobs"],
    ["POST", "/v1/jobs/7f26f4f4-5bdd-4d39-84d4-d1b94c16cc9e/cancel"],
  ])("matches the native route allowlist: %s %s", (method, controllerPath) => {
    expect(isAllowedControllerRoute(method, controllerPath)).toBe(true);
  });

  it.each([
    ["GET", "/v1/pairings"],
    ["POST", "/v1/pairings"],
    ["GET", "/v1/jobs/../pairings"],
    ["GET", "/v1/jobs/./pairings"],
    ["GET", "/v1/jobs/%2e%2e/pairings"],
    ["GET", "/v1/jobs/%2E%2E/pairings"],
    ["GET", "/v1/jobs/id%2fpairings"],
    ["GET", "/v1/jobs/id%2Fpairings"],
    ["GET", "/v1/jobs/id%5c.."],
    ["GET", "/v1/jobs/id%5C.."],
    ["GET", "/v1/jobs/id%"],
    ["GET", "/v1/jobs/id%G0"],
    ["GET", "/v1/jobs/id%0"],
    ["GET", "/v1/jobs/id.with-dot"],
    ["GET", "/v1/jobs/id/extra"],
    ["POST", "/v1/jobs/../pairings/cancel"],
    ["POST", "/v1/jobs/id%2e%2e/cancel"],
    ["POST", "/v1/jobs/id%2f/cancel"],
    ["POST", "/v1/jobs/id%5c/cancel"],
    ["POST", "/v1/jobs/id%"],
    ["GET", "/v1/health?redirect=/v1/pairings"],
  ])("rejects routes outside the native allowlist: %s %s", (method, controllerPath) => {
    expect(isAllowedControllerRoute(method, controllerPath)).toBe(false);
  });

  it("rejects an encoded dot route before fetch can normalize it upstream", () => {
    const fetchImpl = vi.fn<typeof fetch>();
    vi.stubGlobal("fetch", fetchImpl);
    try {
      let middleware:
        | ((request: IncomingMessage, response: ServerResponse, next: () => void) => void)
        | undefined;
      const plugin = secureControllerProxy();
      if (typeof plugin.configureServer !== "function") throw new Error("proxy plugin has no server hook");
      plugin.configureServer({
        middlewares: {
          use(handler) {
            middleware = handler;
          },
        },
      } as never);
      expect(middleware).toBeDefined();

      const response = {
        statusCode: 0,
        setHeader: vi.fn(),
        end: vi.fn(),
      } as unknown as ServerResponse;
      middleware!({
        method: "GET",
        url: "/__cyc_controller/v1/jobs/%2e%2e/pairings",
        headers: {},
      } as unknown as IncomingMessage, response, vi.fn());

      expect(response.statusCode).toBe(400);
      expect(fetchImpl).not.toHaveBeenCalled();
    } finally {
      vi.unstubAllGlobals();
    }
  });
});
