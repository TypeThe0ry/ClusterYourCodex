#!/usr/bin/env node

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { createInterface } from "node:readline";

const EXPECTED_TOOLS = [
  "fleet_cancel",
  "fleet_info",
  "fleet_job",
  "fleet_plan",
  "fleet_plan_submit",
  "fleet_snapshot_upload",
  "fleet_submit",
  "workspace_snapshot_pack",
];
const REQUEST_TIMEOUT_MS = 10_000;
const STABILITY_WINDOW_MS = 250;
const SHUTDOWN_TIMEOUT_MS = 2_000;
const MAX_STDERR_CHARACTERS = 32_768;

function fail(message) {
  throw new Error(message);
}

const deployRootArgument = process.argv[2];
if (!deployRootArgument || process.argv.length !== 3) {
  fail("usage: node Test-McpDeployment.mjs <McpDeployRoot>");
}

const deployRoot = resolve(deployRootArgument);
const server = resolve(deployRoot, "dist", "server.js");
if (!existsSync(server)) fail(`MCP deployment is missing dist/server.js: ${server}`);

const child = spawn(process.execPath, [server], {
  cwd: deployRoot,
  env: {
    ...process.env,
    CYC_MCP_SELF_TEST: "1",
    NODE_OPTIONS: "",
    NODE_PATH: "",
  },
  stdio: ["pipe", "pipe", "pipe"],
  windowsHide: true,
});

let boundedStderr = "";
child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk) => {
  boundedStderr = (boundedStderr + chunk).slice(-MAX_STDERR_CHARACTERS);
});

const pending = new Map();
let stopping = false;
let unexpectedTermination = null;
const stdout = createInterface({ input: child.stdout, crlfDelay: Infinity });
stdout.on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }
  const waiter = pending.get(message?.id);
  if (!waiter) return;
  pending.delete(message.id);
  clearTimeout(waiter.timer);
  waiter.resolve(message);
});

function rejectPending(reason) {
  for (const waiter of pending.values()) {
    clearTimeout(waiter.timer);
    waiter.reject(reason);
  }
  pending.clear();
}

function exitedUnexpectedly(code, signal, cause) {
  const detail = cause ? `, cause=${cause.message}` : "";
  return new Error(
    `MCP deployment exited before the probe completed (code=${String(code)}, signal=${String(signal)}${detail}). stderr=${boundedStderr}`,
  );
}

child.once("error", (error) => {
  const failure = exitedUnexpectedly(child.exitCode, child.signalCode, error);
  if (!stopping) unexpectedTermination = failure;
  rejectPending(failure);
});
child.once("exit", (code, signal) => {
  const failure = exitedUnexpectedly(code, signal);
  if (!stopping) unexpectedTermination = failure;
  rejectPending(failure);
});

function send(value) {
  if (!child.stdin.write(`${JSON.stringify(value)}\n`)) {
    return new Promise((resolveDrain) => child.stdin.once("drain", resolveDrain));
  }
  return Promise.resolve();
}

async function request(id, method, params) {
  const response = new Promise((resolveResponse, rejectResponse) => {
    const timer = setTimeout(() => {
      pending.delete(id);
      rejectResponse(
        new Error(`MCP deployment timed out waiting for ${method}. stderr=${boundedStderr}`),
      );
    }, REQUEST_TIMEOUT_MS);
    pending.set(id, { resolve: resolveResponse, reject: rejectResponse, timer });
  });
  await send({ jsonrpc: "2.0", id, method, params });
  return response;
}

async function stopChild() {
  const preexistingTermination =
    unexpectedTermination ??
    (child.exitCode !== null || child.signalCode !== null
      ? exitedUnexpectedly(child.exitCode, child.signalCode)
      : null);
  stopping = true;
  stdout.close();
  child.stdin.end();
  if (child.exitCode === null && child.signalCode === null) {
    child.kill();
    await Promise.race([
      new Promise((resolveExit) => child.once("exit", resolveExit)),
      new Promise((resolveTimeout) => setTimeout(resolveTimeout, SHUTDOWN_TIMEOUT_MS)),
    ]);
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
  }
  if (preexistingTermination) throw preexistingTermination;
}

let smokeResult = null;
let primaryFailure = null;
try {
  const initialized = await request(1, "initialize", {
    protocolVersion: "2025-06-18",
    capabilities: {},
    clientInfo: { name: "cyc-release-smoke", version: "1.0.0" },
  });
  if (initialized.error) fail(`MCP initialize failed: ${JSON.stringify(initialized.error)}`);
  if (initialized.result?.protocolVersion !== "2025-06-18") {
    fail(`MCP returned an unexpected protocol version: ${String(initialized.result?.protocolVersion)}`);
  }

  await send({ jsonrpc: "2.0", method: "notifications/initialized", params: {} });
  const listed = await request(2, "tools/list", {});
  if (listed.error) fail(`MCP tools/list failed: ${JSON.stringify(listed.error)}`);
  const tools = Array.isArray(listed.result?.tools) ? listed.result.tools : [];
  const names = tools.map((tool) => tool?.name).sort();
  if (JSON.stringify(names) !== JSON.stringify(EXPECTED_TOOLS)) {
    fail(`MCP deployment exposed an unexpected tool set: ${JSON.stringify(names)}`);
  }

  // A server that prints the expected responses and then dies is not a usable
  // stdio deployment. Keep the pipe open for a bounded observation window and
  // require the process to remain alive until this probe initiates shutdown.
  await new Promise((resolveStabilityWindow) =>
    setTimeout(resolveStabilityWindow, STABILITY_WINDOW_MS),
  );
  if (unexpectedTermination) throw unexpectedTermination;
  if (child.exitCode !== null || child.signalCode !== null) {
    throw exitedUnexpectedly(child.exitCode, child.signalCode);
  }

  smokeResult = {
    schemaVersion: "cyc.dev/mcp-deployment-smoke/v1",
    protocolVersion: initialized.result.protocolVersion,
    toolCount: names.length,
    tools: names,
  };
} catch (error) {
  primaryFailure = error;
}
try {
  await stopChild();
} catch (error) {
  if (!primaryFailure) primaryFailure = error;
}
if (primaryFailure) throw primaryFailure;
process.stdout.write(`${JSON.stringify(smokeResult)}\n`);
