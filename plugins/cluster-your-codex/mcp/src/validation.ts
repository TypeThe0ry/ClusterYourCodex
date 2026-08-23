import { randomUUID } from "node:crypto";
import { isIP } from "node:net";
import type { GpuVendor, JobDraft, JobKind, JobSpec, ResourceRequest } from "./types.js";
import { validateSnapshotDescriptor } from "./snapshot.js";

const kinds = new Set<JobKind>(["shell", "build", "test", "lint", "container", "gpu", "batch"]);
const gpuVendors = new Set<GpuVendor>(["nvidia", "amd", "intel", "apple"]);
const operatingSystems = new Set(["windows", "linux", "macos"]);
const architectures = new Set(["x86_64", "aarch64"]);
const shells = new Set(["powershell", "bash", "zsh", "cmd"]);
const placementPolicies = new Set(["balanced", "performance", "manual"]);
const forbiddenKeys = /^(authorization|cookie|session|credential|credentials|password|passwd|privatekey|private_key|secret|secrets|token|tokens|apikey|api_key|accesskey|access_key)$/i;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function rejectCredentialPayload(value: unknown, path = "payload"): void {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => rejectCredentialPayload(entry, `${path}[${index}]`));
    return;
  }
  if (!isRecord(value)) return;

  for (const [key, entry] of Object.entries(value)) {
    if (forbiddenKeys.test(key)) {
      throw new Error(`Credential-bearing field is not allowed in MCP payloads: ${path}.${key}`);
    }
    rejectCredentialPayload(entry, `${path}.${key}`);
  }
}

export function parseJobDraft(value: unknown): JobSpec {
  if (!isRecord(value)) throw new Error("job must be an object");
  rejectCredentialPayload(value, "job");
  assertOnlyKeys(
    value,
    [
      "apiVersion",
      "id",
      "origin",
      "kind",
      "source",
      "requirements",
      "resourceRequest",
      "steps",
      "artifacts",
      "timeoutSeconds",
      "placementPolicy",
      "preferredNodeId",
    ],
    "job",
  );

  if (value.apiVersion !== undefined && value.apiVersion !== "cyc.dev/v1") {
    throw new Error("job.apiVersion is unsupported");
  }
  if (value.id !== undefined) validateUuid(value.id, "job.id");
  validateOrigin(value.origin);
  if (typeof value.kind !== "string" || !kinds.has(value.kind as JobKind)) {
    throw new Error("job.kind is invalid");
  }
  validateSource(value.source);
  validateRequirements(value.requirements);
  validateSteps(value.steps);
  validateArtifacts(value.artifacts);
  validateTimeout(value.timeoutSeconds, "job.timeoutSeconds");
  if (
    value.placementPolicy !== undefined &&
    (typeof value.placementPolicy !== "string" || !placementPolicies.has(value.placementPolicy))
  ) {
    throw new Error("job.placementPolicy is invalid");
  }
  if (value.preferredNodeId !== undefined) validateUuid(value.preferredNodeId, "job.preferredNodeId");

  const draft = value as unknown as JobDraft;
  validateResourceRequest(draft.resourceRequest, draft.requirements);
  return {
    ...draft,
    apiVersion: "cyc.dev/v1",
    id: typeof draft.id === "string" ? draft.id : randomUUID(),
  };
}

function validateOrigin(value: unknown): void {
  if (value === undefined) return;
  if (!isRecord(value)) throw new Error("job.origin must be an object");
  assertOnlyKeys(value, ["codexSessionId", "projectId", "workspaceId"], "job.origin");
  for (const key of ["codexSessionId", "projectId", "workspaceId"] as const) {
    const entry = value[key];
    if (entry !== undefined && (typeof entry !== "string" || [...entry].length > 256)) {
      throw new Error(`job.origin.${key} must be a string no longer than 256 characters`);
    }
  }
}

function validateSource(value: unknown): void {
  if (!isRecord(value) || (value.type !== "git" && value.type !== "snapshot")) {
    throw new Error("job.source must be a git revision or snapshot digest");
  }
  if (value.type === "git") {
    assertOnlyKeys(value, ["type", "repository", "revision"], "job.source");
    validatePublicHttpsRepository(value.repository);
    if (
      typeof value.revision !== "string" ||
      !/^(?:[a-f0-9]{40}|[a-f0-9]{64})$/.test(value.revision)
    ) {
      throw new Error("job.source.revision must be a complete lowercase Git object ID");
    }
    return;
  }
  assertOnlyKeys(value, ["type", "digest", "sizeBytes"], "job.source");
  if (typeof value.digest !== "string" || typeof value.sizeBytes !== "number") {
    throw new Error("job.source snapshot requires digest and sizeBytes");
  }
  validateSnapshotDescriptor(value.digest, value.sizeBytes);
}

function validatePublicHttpsRepository(value: unknown): void {
  if (
    typeof value !== "string" ||
    value.trim() !== value ||
    /[\u0000-\u001f\u007f?#\\]/.test(value) ||
    !value.startsWith("https://")
  ) {
    throw new Error("job.source.repository must be a canonical public HTTPS URL");
  }
  const remainder = value.slice("https://".length);
  const slash = remainder.indexOf("/");
  if (slash <= 0 || slash === remainder.length - 1) {
    throw new Error("job.source.repository must contain a repository path");
  }
  const authority = remainder.slice(0, slash);
  const path = remainder.slice(slash + 1);
  if (
    authority.includes("@") ||
    path.split("/").some((segment) => segment === "" || segment === "." || segment === "..")
  ) {
    throw new Error(
      "job.source.repository must be a public HTTPS URL without userinfo or a non-canonical path",
    );
  }
  const host = repositoryHost(authority);
  if (!isPublicRepositoryHost(host)) {
    throw new Error("job.source.repository host must be public");
  }
  try {
    const parsed = new URL(value);
    if (parsed.protocol !== "https:" || parsed.username || parsed.password || !parsed.pathname || parsed.search || parsed.hash) {
      throw new Error();
    }
  } catch {
    throw new Error("job.source.repository must be a canonical public HTTPS URL");
  }
}

function repositoryHost(authority: string): string {
  if (authority.startsWith("[")) {
    const close = authority.indexOf("]");
    if (close <= 1) throw new Error("job.source.repository host is invalid");
    const host = authority.slice(1, close);
    const suffix = authority.slice(close + 1);
    if ((suffix !== "" && !validPortSuffix(suffix)) || isIP(host) !== 6) {
      throw new Error("job.source.repository host or port is invalid");
    }
    return host;
  }
  if ((authority.match(/:/g) ?? []).length > 1) {
    throw new Error("job.source.repository IPv6 hosts must use brackets");
  }
  const colon = authority.indexOf(":");
  const host = colon === -1 ? authority : authority.slice(0, colon);
  const port = colon === -1 ? "" : authority.slice(colon + 1);
  if (
    host.length === 0 ||
    !/^[A-Za-z0-9.-]+$/.test(host) ||
    host.startsWith(".") ||
    host.endsWith(".") ||
    (port !== "" && !validPort(port))
  ) {
    throw new Error("job.source.repository host or port is invalid");
  }
  return host;
}

function validPortSuffix(value: string): boolean {
  return value.startsWith(":") && validPort(value.slice(1));
}

function validPort(value: string): boolean {
  if (!/^\d+$/.test(value)) return false;
  const port = Number(value);
  return Number.isSafeInteger(port) && port >= 1 && port <= 65_535;
}

function isPublicRepositoryHost(value: string): boolean {
  const host = value.toLowerCase();
  if (host === "localhost" || host.endsWith(".localhost") || host.endsWith(".local")) return false;
  const version = isIP(host);
  if (version === 4) return isPublicIpv4(host);
  if (version === 6) return isPublicIpv6(host);
  return true;
}

function isPublicIpv4(value: string): boolean {
  const octets = value.split(".").map(Number);
  if (octets.length !== 4 || octets.some((octet) => !Number.isInteger(octet) || octet < 0 || octet > 255)) {
    return false;
  }
  const a = octets[0] ?? 0;
  const b = octets[1] ?? 0;
  return !(
    a === 0 ||
    a === 10 ||
    a === 127 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 198 && (b === 18 || b === 19)) ||
    a >= 224
  );
}

function isPublicIpv6(value: string): boolean {
  const words = expandIpv6(value);
  if (words === undefined) return false;
  if (
    words.every((word) => word === 0) ||
    (words.slice(0, 7).every((word) => word === 0) && words[7] === 1)
  ) {
    return false;
  }
  const first = words[0] ?? 0;
  if ((first & 0xfe00) === 0xfc00 || (first & 0xffc0) === 0xfe80 || (first & 0xff00) === 0xff00) {
    return false;
  }
  const ipv4Mapped = words.slice(0, 5).every((word) => word === 0) && words[5] === 0xffff;
  if (ipv4Mapped) {
    return isPublicIpv4(`${words[6]! >> 8}.${words[6]! & 0xff}.${words[7]! >> 8}.${words[7]! & 0xff}`);
  }
  return true;
}

function expandIpv6(value: string): number[] | undefined {
  let input = value;
  let ipv4Tail: number[] = [];
  const lastColon = input.lastIndexOf(":");
  const possibleIpv4 = lastColon === -1 ? input : input.slice(lastColon + 1);
  if (possibleIpv4.includes(".")) {
    if (!isIpv4Syntax(possibleIpv4)) return undefined;
    const octets = possibleIpv4.split(".").map(Number);
    ipv4Tail = [
      ((octets[0] ?? 0) << 8) | (octets[1] ?? 0),
      ((octets[2] ?? 0) << 8) | (octets[3] ?? 0),
    ];
    input = `${input.slice(0, lastColon)}:ipv4`;
  }
  const halves = input.split("::");
  if (halves.length > 2) return undefined;
  const parseHalf = (half: string): number[] | undefined => {
    if (half === "") return [];
    const parsed: number[] = [];
    for (const segment of half.split(":")) {
      if (segment === "ipv4") {
        parsed.push(...ipv4Tail);
      } else if (!/^[0-9a-f]{1,4}$/i.test(segment)) {
        return undefined;
      } else {
        parsed.push(Number.parseInt(segment, 16));
      }
    }
    return parsed;
  };
  const left = parseHalf(halves[0] ?? "");
  const right = parseHalf(halves[1] ?? "");
  if (left === undefined || right === undefined) return undefined;
  if (halves.length === 1) return left.length === 8 ? left : undefined;
  const zeros = 8 - left.length - right.length;
  return zeros >= 1 ? [...left, ...Array<number>(zeros).fill(0), ...right] : undefined;
}

function isIpv4Syntax(value: string): boolean {
  const octets = value.split(".");
  return octets.length === 4 && octets.every((octet) => /^\d{1,3}$/.test(octet) && Number(octet) <= 255);
}

function validateRequirements(value: unknown): void {
  if (value === undefined) return;
  if (!isRecord(value)) throw new Error("job.requirements must be an object");
  assertOnlyKeys(
    value,
    ["os", "arch", "capabilities", "minCpuCores", "minMemoryMiB", "minDiskMiB", "gpu"],
    "job.requirements",
  );
  if (value.os !== undefined && (typeof value.os !== "string" || !operatingSystems.has(value.os))) {
    throw new Error("job.requirements.os is invalid");
  }
  if (value.arch !== undefined && (typeof value.arch !== "string" || !architectures.has(value.arch))) {
    throw new Error("job.requirements.arch is invalid");
  }
  if (value.capabilities !== undefined) {
    if (
      !Array.isArray(value.capabilities) ||
      value.capabilities.some((entry) => typeof entry !== "string" || entry.trim() === "")
    ) {
      throw new Error("job.requirements.capabilities must contain non-empty strings");
    }
  }
  optionalSafeInteger(value.minCpuCores, "job.requirements.minCpuCores", 1, Number.MAX_SAFE_INTEGER);
  optionalSafeInteger(value.minMemoryMiB, "job.requirements.minMemoryMiB", 1, Number.MAX_SAFE_INTEGER);
  optionalSafeInteger(value.minDiskMiB, "job.requirements.minDiskMiB", 1, Number.MAX_SAFE_INTEGER);
  if (value.gpu !== undefined) validateGpuRequirement(value.gpu);
}

function validateGpuRequirement(value: unknown): void {
  if (!isRecord(value)) throw new Error("job.requirements.gpu must be an object");
  assertOnlyKeys(value, ["vendor", "minVramMiB", "exclusive"], "job.requirements.gpu");
  if (
    value.vendor !== undefined &&
    (typeof value.vendor !== "string" || !gpuVendors.has(value.vendor as GpuVendor))
  ) {
    throw new Error("job.requirements.gpu.vendor is invalid");
  }
  optionalSafeInteger(value.minVramMiB, "job.requirements.gpu.minVramMiB", 1, Number.MAX_SAFE_INTEGER);
  if (value.exclusive !== undefined && typeof value.exclusive !== "boolean") {
    throw new Error("job.requirements.gpu.exclusive must be a boolean");
  }
}

function validateSteps(value: unknown): void {
  if (!Array.isArray(value) || value.length === 0) {
    throw new Error("job.steps must contain at least one executable step");
  }
  for (const [index, step] of value.entries()) {
    if (!isRecord(step)) throw new Error(`job.steps[${index}] must be an object`);
    assertOnlyKeys(
      step,
      ["name", "shell", "script", "workingDirectory", "timeoutSeconds"],
      `job.steps[${index}]`,
    );
    if (typeof step.name !== "string" || step.name.trim() === "") {
      throw new Error(`job.steps[${index}].name must be non-empty`);
    }
    if (typeof step.script !== "string" || step.script.trim() === "") {
      throw new Error(`job.steps[${index}].script must be non-empty`);
    }
    if (step.shell !== undefined && (typeof step.shell !== "string" || !shells.has(step.shell))) {
      throw new Error(`job.steps[${index}].shell is invalid`);
    }
    if (step.workingDirectory !== undefined) {
      validatePortableRelative(step.workingDirectory, `job.steps[${index}].workingDirectory`, false);
    }
    validateTimeout(step.timeoutSeconds, `job.steps[${index}].timeoutSeconds`);
  }
}

function validateArtifacts(value: unknown): void {
  if (value === undefined) return;
  if (!isRecord(value)) throw new Error("job.artifacts must be an object");
  assertOnlyKeys(value, ["include", "exclude", "retentionDays"], "job.artifacts");
  const include = validateStringArray(value.include, "job.artifacts.include");
  const exclude = validateStringArray(value.exclude, "job.artifacts.exclude");
  include?.forEach((pattern, index) => {
    validatePortableRelative(pattern, `job.artifacts.include[${index}]`, true);
    if (pattern.split("/").includes(".git")) {
      throw new Error(`job.artifacts.include[${index}] must not include .git metadata`);
    }
  });
  exclude?.forEach((pattern, index) =>
    validatePortableRelative(pattern, `job.artifacts.exclude[${index}]`, true),
  );
  if (exclude !== undefined && !exclude.some((pattern) => pattern === ".git" || pattern === ".git/**")) {
    throw new Error("job.artifacts.exclude must contain .git/** (or .git)");
  }
  optionalSafeInteger(value.retentionDays, "job.artifacts.retentionDays", 1, 3650);
}

function validateStringArray(value: unknown, path: string): string[] | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value) || value.some((entry) => typeof entry !== "string")) {
    throw new Error(`${path} must be an array of strings`);
  }
  return value as string[];
}

function validatePortableRelative(value: unknown, path: string, glob: boolean): void {
  if (
    typeof value !== "string" ||
    value === "" ||
    value.includes("\0") ||
    value.includes("\\") ||
    value.startsWith("/") ||
    /^[A-Za-z]:/.test(value) ||
    (glob && value.startsWith("!")) ||
    value.split("/").some((segment) => segment === "" || segment === "." || segment === "..")
  ) {
    throw new Error(`${path} must be a portable job-relative ${glob ? "glob" : "path"}`);
  }
}

function validateTimeout(value: unknown, path: string): void {
  optionalSafeInteger(value, path, 1, 86_400);
}

function validateUuid(value: unknown, path: string): asserts value is string {
  if (typeof value !== "string" || !uuidPattern.test(value)) throw new Error(`${path} must be a UUID`);
}

function validateResourceRequest(
  request: ResourceRequest | undefined,
  requirements: JobDraft["requirements"],
): void {
  if (request === undefined) return;
  if (!isRecord(request)) throw new Error("job.resourceRequest must be an object");
  assertOnlyKeys(request, ["slots", "cpuCores", "memoryMiB", "diskMiB", "gpu"], "job.resourceRequest");

  optionalSafeInteger(request.slots, "job.resourceRequest.slots", 1, Number.MAX_SAFE_INTEGER);
  const cpuCores = optionalSafeInteger(
    request.cpuCores,
    "job.resourceRequest.cpuCores",
    1,
    Number.MAX_SAFE_INTEGER,
  ) ?? 1;
  const memoryMiB = optionalSafeInteger(
    request.memoryMiB,
    "job.resourceRequest.memoryMiB",
    0,
    Number.MAX_SAFE_INTEGER,
  ) ?? 0;
  const diskMiB = optionalSafeInteger(
    request.diskMiB,
    "job.resourceRequest.diskMiB",
    0,
    Number.MAX_SAFE_INTEGER,
  ) ?? 0;

  const legacyCpu = requirements?.minCpuCores ?? 1;
  const legacyMemory = requirements?.minMemoryMiB ?? 0;
  const legacyDisk = requirements?.minDiskMiB ?? 0;
  if (cpuCores < legacyCpu || memoryMiB < legacyMemory || diskMiB < legacyDisk) {
    throw new Error("job.resourceRequest must not weaken legacy requirements");
  }

  const gpu = request.gpu;
  const legacyGpu = requirements?.gpu;
  if (gpu === undefined) {
    if (legacyGpu !== undefined) {
      throw new Error("job.resourceRequest.gpu must not weaken legacy GPU requirements");
    }
    return;
  }
  if (!isRecord(gpu)) throw new Error("job.resourceRequest.gpu must be an object");
  assertOnlyKeys(gpu, ["deviceId", "vendor", "vramMiB", "exclusive"], "job.resourceRequest.gpu");
  if (
    gpu.deviceId !== undefined &&
    (typeof gpu.deviceId !== "string" ||
      gpu.deviceId.trim().length === 0 ||
      [...gpu.deviceId].length > 256 ||
      /[\u0000-\u001f\u007f]/.test(gpu.deviceId))
  ) {
    throw new Error("job.resourceRequest.gpu.deviceId must be a non-empty safe identifier");
  }
  if (
    gpu.vendor !== undefined &&
    (typeof gpu.vendor !== "string" || !gpuVendors.has(gpu.vendor as GpuVendor))
  ) {
    throw new Error("job.resourceRequest.gpu.vendor is invalid");
  }
  const vendor = gpu.vendor as GpuVendor | undefined;
  const vramMiB = optionalSafeInteger(
    gpu.vramMiB,
    "job.resourceRequest.gpu.vramMiB",
    0,
    Number.MAX_SAFE_INTEGER,
  ) ?? 0;
  if (gpu.exclusive !== undefined && typeof gpu.exclusive !== "boolean") {
    throw new Error("job.resourceRequest.gpu.exclusive must be a boolean");
  }
  if (legacyGpu !== undefined) {
    if (legacyGpu.vendor !== undefined && vendor !== legacyGpu.vendor) {
      throw new Error("job.resourceRequest.gpu.vendor must not conflict with legacy requirements");
    }
    if (vramMiB < (legacyGpu.minVramMiB ?? 0)) {
      throw new Error("job.resourceRequest.gpu.vramMiB must not weaken legacy requirements");
    }
    if ((legacyGpu.exclusive ?? true) && gpu.exclusive === false) {
      throw new Error("job.resourceRequest.gpu.exclusive must not weaken legacy requirements");
    }
  }
}

function optionalSafeInteger(
  value: unknown,
  path: string,
  minimum: number,
  maximum: number,
): number | undefined {
  if (value === undefined) return undefined;
  if (!Number.isSafeInteger(value) || (value as number) < minimum || (value as number) > maximum) {
    throw new Error(`${path} must be an integer from ${minimum} through ${maximum}`);
  }
  return value as number;
}

function assertOnlyKeys(value: Record<string, unknown>, allowed: readonly string[], path: string): void {
  const allowedSet = new Set(allowed);
  const unknown = Object.keys(value).find((key) => !allowedSet.has(key));
  if (unknown !== undefined) throw new Error(`${path}.${unknown} is not supported`);
}

export function parseJobId(value: unknown): string {
  validateUuid(value, "jobId");
  return value;
}

export function optionalPlanId(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  validateUuid(value, "planId");
  return value;
}
