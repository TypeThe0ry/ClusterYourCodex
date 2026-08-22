import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import type { IncomingMessage, ServerResponse } from "node:http";
import type { Plugin } from "vite";

const PROXY_PREFIX = "/__cyc_controller";
const DEFAULT_CONTROLLER_URL = "http://127.0.0.1:47831";
const MAX_REQUEST_BYTES = 2 * 1024 * 1024;

export function assertLoopbackControllerUrl(value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error("Development controller URL must be loopback HTTP(S)");
  }
  const hostname = url.hostname.replace(/^\[|\]$/g, "").toLowerCase();
  const ipv4 = hostname.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  const isLoopbackIpv4 = Boolean(
    ipv4 && ipv4.slice(1).every((part) => Number(part) <= 255) && Number(ipv4[1]) === 127,
  );
  const isLoopback = hostname === "localhost" || hostname === "::1" || isLoopbackIpv4;
  if (
    !["http:", "https:"].includes(url.protocol) ||
    !isLoopback ||
    url.username ||
    url.password ||
    (url.pathname !== "/" && url.pathname !== "") ||
    url.search ||
    url.hash
  ) {
    throw new Error("Development controller URL must be loopback HTTP(S)");
  }
  return url.origin;
}

function defaultTokenFile(): string {
  if (process.env.CYC_CONTROLLER_TOKEN_FILE?.trim()) {
    return path.resolve(process.env.CYC_CONTROLLER_TOKEN_FILE.trim());
  }
  const home = homedir();
  if (process.platform === "win32") {
    return path.join(process.env.LOCALAPPDATA || path.join(home, "AppData", "Local"), "ClusterYourCodex", "controller.token");
  }
  if (process.platform === "darwin") {
    return path.join(home, "Library", "Application Support", "ClusterYourCodex", "controller.token");
  }
  return path.join(process.env.XDG_DATA_HOME || path.join(home, ".local", "share"), "clusteryourcodex", "controller.token");
}

async function loadToken(): Promise<string> {
  const token = (await readFile(defaultTokenFile(), "utf8")).trim();
  if (token.length < 32 || token.length > 256 || /\s/.test(token) || /[^\x21-\x7e]/.test(token)) {
    throw new Error("invalid token");
  }
  return token;
}

function jsonError(response: ServerResponse, status: number, code: string, message: string): void {
  response.statusCode = status;
  response.setHeader("content-type", "application/json");
  response.end(JSON.stringify({ error: { code, message } }));
}

async function readRequestBody(request: IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += buffer.length;
    if (total > MAX_REQUEST_BYTES) throw new Error("request too large");
    chunks.push(buffer);
  }
  return chunks.length > 0 ? Buffer.concat(chunks) : Buffer.from("{}");
}

async function handleProxyRequest(
  request: IncomingMessage,
  response: ServerResponse,
  controllerOrigin: string,
): Promise<void> {
  const method = request.method;
  const requestUrl = request.url ?? "";
  if (!requestUrl.startsWith(`${PROXY_PREFIX}/`)) {
    jsonError(response, 404, "not_found", "development proxy route not found");
    return;
  }
  const controllerPath = requestUrl.slice(PROXY_PREFIX.length);
  if (!/^\/v1\/[A-Za-z0-9_./%-]+$/.test(controllerPath) || controllerPath.includes("..")) {
    jsonError(response, 400, "invalid_path", "controller path is invalid");
    return;
  }
  if (method !== "GET" && method !== "POST") {
    response.setHeader("allow", "GET, POST");
    jsonError(response, 405, "method_not_allowed", "controller method is not allowed");
    return;
  }
  if (method === "POST" && request.headers["content-type"]?.split(";", 1)[0]?.trim() !== "application/json") {
    jsonError(response, 415, "json_required", "mutating controller requests require application/json");
    return;
  }

  try {
    const headers = new Headers();
    if (controllerPath !== "/v1/health") {
      headers.set("authorization", `Bearer ${await loadToken()}`);
    }
    const ifMatch = request.headers["if-match"];
    if (typeof ifMatch === "string") headers.set("if-match", ifMatch);
    let body: string | undefined;
    if (method === "POST") {
      body = (await readRequestBody(request)).toString("utf8");
      headers.set("content-type", "application/json");
    }
    const upstream = await fetch(`${controllerOrigin}${controllerPath}`, { method, headers, body });
    response.statusCode = upstream.status;
    for (const name of ["content-type", "x-request-id", "etag"]) {
      const value = upstream.headers.get(name);
      if (value) response.setHeader(name, value);
    }
    response.end(Buffer.from(await upstream.arrayBuffer()));
  } catch {
    jsonError(response, 503, "dev_proxy_unavailable", "secure development controller proxy is unavailable");
  }
}

export function secureControllerProxy(): Plugin {
  const controllerOrigin = assertLoopbackControllerUrl(
    process.env.CYC_CONTROLLER_URL?.trim() || DEFAULT_CONTROLLER_URL,
  );
  return {
    name: "cluster-your-codex-secure-controller-proxy",
    apply: "serve",
    configureServer(server) {
      server.middlewares.use((request, response, next) => {
        if (!request.url?.startsWith(`${PROXY_PREFIX}/`)) {
          next();
          return;
        }
        void handleProxyRequest(request, response, controllerOrigin);
      });
    },
  };
}
