import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  ControllerVerificationLoop,
  MCP_RUNTIME_API_VERSION,
  McpRuntimeReceipt,
  resolveMcpRuntimeReceiptFile,
} from "./runtime-receipt.js";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  vi.useRealTimers();
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

describe("MCP active runtime receipt", () => {
  it("appears only after initialize, tools/list, and authenticated controller verification", async () => {
    const directory = await temporaryDirectory();
    const receiptFile = path.join(directory, "mcp-active-v1.json");
    let tick = 0;
    const receipt = new McpRuntimeReceipt({
      environment: { CYC_MCP_ACTIVE_RECEIPT_FILE: receiptFile },
      pid: 4242,
      bridgeVersion: "1.2.3",
      now: () => new Date(Date.UTC(2026, 7, 23, 0, 0, tick++)),
    });

    await receipt.noteInitialized();
    await receipt.noteToolsListed();
    await expect(stat(receiptFile)).rejects.toMatchObject({ code: "ENOENT" });
    await receipt.noteControllerVerified();
    await receipt.flush();

    const raw = await readFile(receiptFile, "utf8");
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    expect(parsed).toEqual({
      apiVersion: MCP_RUNTIME_API_VERSION,
      pid: 4242,
      startedAt: "2026-08-23T00:00:00.000Z",
      lastSeenAt: "2026-08-23T00:00:02.000Z",
      controllerVerifiedAt: "2026-08-23T00:00:01.000Z",
      bridgeVersion: "1.2.3",
    });
    expect(raw.toLowerCase()).not.toContain("token");
    expect(raw.toLowerCase()).not.toContain("secret");

    await receipt.noteControllerVerified();
    await receipt.flush();
    expect(JSON.parse(await readFile(receiptFile, "utf8"))).toMatchObject({
      pid: 4242,
      lastSeenAt: "2026-08-23T00:00:04.000Z",
      controllerVerifiedAt: "2026-08-23T00:00:03.000Z",
    });

    receipt.stopForTests();
    receipt.cleanupOwnedSync();
    await expect(stat(receiptFile)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("self-test mode never writes or removes an existing active receipt", async () => {
    const directory = await temporaryDirectory();
    const receiptFile = path.join(directory, "mcp-active-v1.json");
    const existing = '{"apiVersion":"cyc.dev/mcp-runtime/v1","pid":99,"startedAt":"old","lastSeenAt":"old","bridgeVersion":"0.1.0"}\n';
    await writeFile(receiptFile, existing);
    const receipt = new McpRuntimeReceipt({
      environment: {
        CYC_MCP_ACTIVE_RECEIPT_FILE: receiptFile,
        CYC_MCP_SELF_TEST: "1",
      },
      pid: 4242,
    });

    await receipt.noteInitialized();
    await receipt.noteToolsListed();
    await receipt.noteControllerVerified();
    receipt.cleanupOwnedSync();

    expect(await readFile(receiptFile, "utf8")).toBe(existing);
    expect(receipt.controllerVerificationEligible()).toBe(false);
  });

  it("periodically refreshes controller proof for the same live PID and uses an unref timer", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-23T00:00:00.000Z"));
    const directory = await temporaryDirectory();
    const receiptFile = path.join(directory, "mcp-active-v1.json");
    const receipt = new McpRuntimeReceipt({
      environment: { CYC_MCP_ACTIVE_RECEIPT_FILE: receiptFile },
      pid: 4242,
      now: () => new Date(Date.now()),
    });
    await receipt.noteInitialized();
    await receipt.noteToolsListed();
    expect(receipt.controllerVerificationEligible()).toBe(true);
    const verify = vi.fn(async () => ({ ok: true }));
    const loop = new ControllerVerificationLoop({
      enabled: receipt.controllerVerificationEligible(),
      verify,
      onVerified: () => receipt.noteControllerVerified(),
      intervalMs: 5_000,
    });

    await loop.start();
    await receipt.flush();
    const first = JSON.parse(await readFile(receiptFile, "utf8")) as McpReceiptShape;
    const timer = (loop as unknown as { timer?: NodeJS.Timeout }).timer;
    expect(timer?.hasRef()).toBe(false);

    await vi.advanceTimersByTimeAsync(5_000);
    await receipt.flush();
    const second = JSON.parse(await readFile(receiptFile, "utf8")) as McpReceiptShape;
    expect(second.pid).toBe(first.pid);
    expect(Date.parse(second.controllerVerifiedAt)).toBeGreaterThan(Date.parse(first.controllerVerifiedAt));
    expect(verify).toHaveBeenCalledTimes(2);
    loop.stop();
    receipt.stopForTests();
  });

  it("does not advance controller proof after a periodic verification failure", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-23T00:00:00.000Z"));
    const directory = await temporaryDirectory();
    const receiptFile = path.join(directory, "mcp-active-v1.json");
    const receipt = new McpRuntimeReceipt({
      environment: { CYC_MCP_ACTIVE_RECEIPT_FILE: receiptFile },
      pid: 4242,
      now: () => new Date(Date.now()),
    });
    await receipt.noteInitialized();
    await receipt.noteToolsListed();
    let succeeds = true;
    const loop = new ControllerVerificationLoop({
      enabled: true,
      verify: async () => {
        if (!succeeds) throw new Error("controller unavailable");
      },
      onVerified: () => receipt.noteControllerVerified(),
      intervalMs: 5_000,
    });
    await loop.start();
    await receipt.flush();
    const verifiedAt = (JSON.parse(await readFile(receiptFile, "utf8")) as McpReceiptShape).controllerVerifiedAt;

    succeeds = false;
    await vi.advanceTimersByTimeAsync(5_000);
    await receipt.flush();
    const afterFailure = JSON.parse(await readFile(receiptFile, "utf8")) as McpReceiptShape;
    expect(afterFailure.controllerVerifiedAt).toBe(verifiedAt);
    expect(Date.parse(afterFailure.lastSeenAt)).toBeGreaterThan(Date.parse(verifiedAt));
    loop.stop();
    receipt.stopForTests();
  });

  it("deduplicates in-flight verification and disables polling for self-test mode", async () => {
    vi.useFakeTimers();
    let release: (() => void) | undefined;
    const verify = vi.fn(() => new Promise<void>((resolve) => { release = resolve; }));
    const verified = vi.fn(async () => undefined);
    const loop = new ControllerVerificationLoop({ enabled: true, verify, onVerified: verified, intervalMs: 5_000 });
    const first = loop.start();
    const second = loop.verifyNow();
    expect(verify).toHaveBeenCalledTimes(1);
    release?.();
    await Promise.all([first, second]);
    expect(verified).toHaveBeenCalledTimes(1);
    loop.stop();

    const disabledVerify = vi.fn(async () => undefined);
    const disabled = new ControllerVerificationLoop({
      enabled: false,
      verify: disabledVerify,
      onVerified: async () => undefined,
    });
    await disabled.start();
    await vi.advanceTimersByTimeAsync(10_000);
    expect(disabledVerify).not.toHaveBeenCalled();
    expect((disabled as unknown as { timer?: NodeJS.Timeout }).timer).toBeUndefined();
  });

  it("derives the default receipt beside the controller token state", () => {
    expect(
      resolveMcpRuntimeReceiptFile(
        { CYC_CONTROLLER_TOKEN_FILE: "C:\\State\\controller.token" },
        "win32",
      ),
    ).toBe(path.win32.join("C:\\State", ".integration", "mcp-active-v1.json"));
    expect(
      resolveMcpRuntimeReceiptFile(
        { CYC_CONTROLLER_TOKEN_FILE: "C:\\State\\controller.token", CYC_MCP_SELF_TEST: "1" },
        "win32",
      ),
    ).toBeUndefined();
  });
});

interface McpReceiptShape {
  pid: number;
  lastSeenAt: string;
  controllerVerifiedAt: string;
}

async function temporaryDirectory(): Promise<string> {
  const directory = await mkdtemp(path.join(tmpdir(), "cyc-mcp-receipt-"));
  temporaryDirectories.push(directory);
  return directory;
}
