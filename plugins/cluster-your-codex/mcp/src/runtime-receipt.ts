import { randomUUID } from "node:crypto";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { readFileSync, unlinkSync } from "node:fs";
import nodePath from "node:path";
import { resolveControllerTokenFile, type TokenPathEnvironment } from "./token-source.js";

export const MCP_RUNTIME_API_VERSION = "cyc.dev/mcp-runtime/v1" as const;
export const MCP_BRIDGE_VERSION = "0.1.0-preview.15" as const;
const HEARTBEAT_INTERVAL_MS = 5_000;

export interface ControllerVerificationLoopOptions {
  enabled: boolean;
  verify: () => Promise<unknown>;
  onVerified: () => Promise<void>;
  intervalMs?: number;
}

export class ControllerVerificationLoop {
  private readonly enabled: boolean;
  private readonly verify: () => Promise<unknown>;
  private readonly onVerified: () => Promise<void>;
  private readonly intervalMs: number;
  private timer: NodeJS.Timeout | undefined;
  private inFlight: Promise<void> | undefined;

  constructor(options: ControllerVerificationLoopOptions) {
    this.enabled = options.enabled;
    this.verify = options.verify;
    this.onVerified = options.onVerified;
    this.intervalMs = options.intervalMs ?? HEARTBEAT_INTERVAL_MS;
    if (!Number.isSafeInteger(this.intervalMs) || this.intervalMs < 100) {
      throw new RangeError("controller verification interval must be at least 100 ms");
    }
  }

  start(): Promise<void> {
    if (!this.enabled) return Promise.resolve();
    if (this.timer === undefined) {
      this.timer = setInterval(() => void this.verifyNow(), this.intervalMs);
      this.timer.unref();
    }
    return this.verifyNow();
  }

  verifyNow(): Promise<void> {
    if (!this.enabled) return Promise.resolve();
    if (this.inFlight !== undefined) return this.inFlight;
    this.inFlight = (async () => {
      try {
        await this.verify();
        await this.onVerified();
      } catch {
        // Failed controller authentication never advances controllerVerifiedAt.
      }
    })().finally(() => {
      this.inFlight = undefined;
    });
    return this.inFlight;
  }

  stop(): void {
    if (this.timer !== undefined) clearInterval(this.timer);
    this.timer = undefined;
  }
}

export interface McpRuntimeEnvironment extends TokenPathEnvironment {
  CYC_MCP_ACTIVE_RECEIPT_FILE?: string;
  CYC_MCP_SELF_TEST?: string;
}

export interface McpRuntimeReceiptV1 {
  apiVersion: typeof MCP_RUNTIME_API_VERSION;
  pid: number;
  startedAt: string;
  lastSeenAt: string;
  controllerVerifiedAt: string;
  bridgeVersion: string;
}

export function resolveMcpRuntimeReceiptFile(
  environment: McpRuntimeEnvironment = process.env,
  platform: NodeJS.Platform = process.platform,
): string | undefined {
  if (environment.CYC_MCP_SELF_TEST === "1") return undefined;
  const pathApi = platform === "win32" ? nodePath.win32 : nodePath.posix;
  const explicit = environment.CYC_MCP_ACTIVE_RECEIPT_FILE?.trim();
  if (explicit) {
    if (!pathApi.isAbsolute(explicit)) throw new Error("CYC_MCP_ACTIVE_RECEIPT_FILE must be absolute");
    return pathApi.resolve(explicit);
  }
  return pathApi.join(
    pathApi.dirname(resolveControllerTokenFile(environment, platform)),
    ".integration",
    "mcp-active-v1.json",
  );
}

export class McpRuntimeReceipt {
  private readonly receiptFile: string | undefined;
  private readonly pid: number;
  private readonly startedAt: string;
  private readonly bridgeVersion: string;
  private readonly now: () => Date;
  private initialized = false;
  private listedTools = false;
  private controllerVerifiedAt: string | undefined;
  private active = false;
  private heartbeat: NodeJS.Timeout | undefined;
  private writeQueue: Promise<void> = Promise.resolve();

  constructor(options: {
    environment?: McpRuntimeEnvironment;
    platform?: NodeJS.Platform;
    pid?: number;
    bridgeVersion?: string;
    now?: () => Date;
  } = {}) {
    this.receiptFile = resolveMcpRuntimeReceiptFile(options.environment, options.platform);
    this.pid = options.pid ?? process.pid;
    this.bridgeVersion = options.bridgeVersion ?? MCP_BRIDGE_VERSION;
    this.now = options.now ?? (() => new Date());
    this.startedAt = this.now().toISOString();
  }

  noteInitialized(): Promise<void> {
    this.initialized = true;
    return this.maybeActivate();
  }

  noteToolsListed(): Promise<void> {
    this.listedTools = true;
    return this.maybeActivate();
  }

  noteControllerVerified(): Promise<void> {
    this.controllerVerifiedAt = this.now().toISOString();
    return this.maybeActivate();
  }

  controllerVerificationEligible(): boolean {
    return this.receiptFile !== undefined && this.initialized && this.listedTools;
  }

  registerProcessCleanup(additionalCleanup?: () => void): void {
    if (this.receiptFile === undefined) return;
    const cleanup = () => {
      try {
        additionalCleanup?.();
      } finally {
        this.cleanupOwnedSync();
      }
    };
    process.once("exit", cleanup);
    process.once("uncaughtExceptionMonitor", cleanup);
    process.once("SIGINT", () => {
      cleanup();
      process.exit(130);
    });
    process.once("SIGTERM", () => {
      cleanup();
      process.exit(143);
    });
  }

  async flush(): Promise<void> {
    await this.writeQueue;
  }

  cleanupOwnedSync(): void {
    this.stopForTests();
    if (this.receiptFile === undefined) return;
    try {
      const parsed = JSON.parse(readFileSync(this.receiptFile, "utf8")) as unknown;
      if (isReceipt(parsed) && parsed.pid === this.pid) unlinkSync(this.receiptFile);
    } catch {
      // Crash remnants are intentionally left for PID/TTL validation by Desktop.
    }
  }

  stopForTests(): void {
    if (this.heartbeat !== undefined) clearInterval(this.heartbeat);
    this.heartbeat = undefined;
  }

  private maybeActivate(): Promise<void> {
    if (
      this.receiptFile === undefined ||
      !this.initialized ||
      !this.listedTools ||
      this.controllerVerifiedAt === undefined
    ) {
      return this.writeQueue;
    }
    if (!this.active) {
      this.active = true;
      this.heartbeat = setInterval(() => void this.queueHeartbeat(), HEARTBEAT_INTERVAL_MS);
      this.heartbeat.unref();
    }
    return this.queueHeartbeat();
  }

  private queueHeartbeat(): Promise<void> {
    const receiptFile = this.receiptFile;
    if (receiptFile === undefined) return this.writeQueue;
    const receipt: McpRuntimeReceiptV1 = {
      apiVersion: MCP_RUNTIME_API_VERSION,
      pid: this.pid,
      startedAt: this.startedAt,
      lastSeenAt: this.now().toISOString(),
      controllerVerifiedAt: this.controllerVerifiedAt!,
      bridgeVersion: this.bridgeVersion,
    };
    this.writeQueue = this.writeQueue.then(() => writeReceiptAtomically(receiptFile, receipt)).catch(() => undefined);
    return this.writeQueue;
  }
}

async function writeReceiptAtomically(receiptPath: string, receipt: McpRuntimeReceiptV1): Promise<void> {
  await mkdir(nodePath.dirname(receiptPath), { recursive: true });
  const temporary = `${receiptPath}.${process.pid}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, `${JSON.stringify(receipt)}\n`, { encoding: "utf8", flag: "wx", mode: 0o600 });
    await rename(temporary, receiptPath);
  } catch (error) {
    try {
      unlinkSync(temporary);
    } catch {
      // The temporary may already have been renamed.
    }
    throw error;
  }
}

function isReceipt(value: unknown): value is McpRuntimeReceiptV1 {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const receipt = value as Record<string, unknown>;
  return (
    receipt.apiVersion === MCP_RUNTIME_API_VERSION &&
    Number.isSafeInteger(receipt.pid) &&
    typeof receipt.startedAt === "string" &&
    typeof receipt.lastSeenAt === "string" &&
    typeof receipt.controllerVerifiedAt === "string" &&
    typeof receipt.bridgeVersion === "string"
  );
}
