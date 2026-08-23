import { isStrictRfc3339 } from "./client";

export type IntegrationState =
  | "not_found"
  | "not_installed"
  | "installed"
  | "restart_required"
  | "connected"
  | "stale"
  | "broken"
  | "version_mismatch";

export interface IntegrationStatus {
  state: IntegrationState;
  checkedAtMs: number;
  payloadAvailable: boolean;
  pluginEnabled: boolean;
  agentsIntegrated: boolean;
  payloadCatalogSha256?: string;
  buildCatalogSha256?: string;
  installManifestSha256?: string;
  agentsBlockSha256?: string;
  cliVersion?: string;
  installedVersion?: string;
  desiredVersion?: string;
  activeRuntime?: { pid: number; startedAt: string; bridgeVersion: string };
  message: string;
}

export interface IntegrationStep {
  id: string;
  passed: boolean;
  message: string;
}

export interface IntegrationActionResult {
  changed: boolean;
  restartRequired: boolean;
  steps: IntegrationStep[];
  status: IntegrationStatus;
}

export interface SelfTestExecutorIdentity {
  pid: number;
  startedAt: string;
  bridgeVersion: string;
  sessionId: string;
}

export interface IntegrationSelfTestResult {
  passed: boolean;
  durationMs: number;
  restartRecommended: boolean;
  checks: IntegrationStep[];
  selfTestExecutor?: SelfTestExecutorIdentity;
  status: IntegrationStatus;
}

export type FullRunCheckState = "running" | "passed" | "failed";
export type FullRunLayerState = "pending" | "running" | "passed" | "failed" | "skipped";
export type FullRunLayerId =
  | "plugin_check"
  | "fresh_heartbeat"
  | "source_snapshot"
  | "worker_selection"
  | "remote_execution"
  | "log_verification"
  | "artifact_verification"
  | "cleanup";

export interface FullRunCheckLayer {
  id: FullRunLayerId;
  state: FullRunLayerState;
  message: string;
}

export interface FullRunCheckResult {
  state: FullRunCheckState;
  layers: FullRunCheckLayer[];
  startedAt: string;
  finishedAt?: string;
  durationMs: number;
  failure?: { code: string; retryable: boolean };
  integration?: {
    activeRuntime: {
      pid: number;
      startedAt: string;
      bridgeVersion: string;
      initialReceiptVerifiedAt: string;
      finalReceiptVerifiedAt?: string;
      reverifiedAfterRun: boolean;
    };
    selfTestExecutor?: SelfTestExecutorIdentity & {
      initializeCompleted: boolean;
      toolsListCompleted: boolean;
      controllerRoundTripAt: string;
      mcpToolsExercised: string[];
    };
  };
  selectedNode?: { id: string; name: string; operatingSystem: string; architecture: string; heartbeatAt: string };
  transport?: { transport: "managed_https"; endpoint: string; tls: true; credentialReferencePresent: true };
  placement?: FullRunPlacementEvidence;
  finalFleet?: { fleetRevision: number; observedAt: string };
  snapshot?: { digest: string; sizeBytes: number };
  job?: { jobId: string; runId: string; state: string; exitCode?: number; observedStates: string[] };
  logs: Array<{ stream: "stdout" | "stderr"; sizeBytes: number; sha256: string; chunkCount: number }>;
  artifacts: Array<{ id: string; name: string; sizeBytes: number; sha256: string }>;
  cleanup?: {
    jobId: string;
    runId: string;
    relativeRoot: string;
    status: "removed";
    jobRootDeleted: true;
    terminalStateVersion: number;
    terminalAcknowledgedAt: string;
    observedAt: string;
    receivedAt: string;
    reservationReleasedAt: string;
    releaseReason: "removed_receipt";
  };
}

export interface FullRunPlacementEvidence {
  planId: string;
  jobDigest: string;
  score: number;
  fleetRevision: number;
  nodeRevision: number;
  policyRevision: number;
  explanation: {
    policy: "balanced" | "performance" | "manual";
    selectedNodeId?: string;
    candidates: Array<{
      nodeId: string;
      nodeName: string;
      eligible: boolean;
      score?: number;
      scoreComponents: Array<{ key: string; value: number; detail: string }>;
      rejectionReasons: Array<{ code: string; detail: string }>;
    }>;
  };
}

export interface FullRunEvidenceBaseline {
  integrationIdentity: string;
  integrationGeneration: number;
  fleetRevision: number;
  selectedNodeId: string;
  selectedNodeHeartbeatAt: string;
}

export interface FullRunEvidenceCurrent {
  controllerOnline: boolean;
  statusFresh: boolean;
  status?: IntegrationStatus;
  integrationGeneration: number;
  fleetRevision?: number;
  selectedNode?: {
    id: string;
    status: string;
    availability?: string;
    lastSeenAt?: string;
  };
}

export const INTEGRATION_STATUS_MAX_AGE_MS = 60_000;
const INTEGRATION_STATUS_MAX_FUTURE_SKEW_MS = 300_000;

export function integrationStatusIsFresh(status: Pick<IntegrationStatus, "checkedAtMs">, now = Date.now()): boolean {
  return Number.isSafeInteger(now) &&
    status.checkedAtMs >= now - INTEGRATION_STATUS_MAX_AGE_MS &&
    status.checkedAtMs <= now + INTEGRATION_STATUS_MAX_FUTURE_SKEW_MS;
}

function identityPart(value: string | number | boolean | undefined): string {
  const text = value === undefined ? "" : String(value);
  return `${text.length}:${text}`;
}

/** Identity evidence currently exposed by the native status contract. */
export function integrationStatusIdentity(status: IntegrationStatus): string {
  return [
    status.state,
    status.payloadAvailable,
    status.pluginEnabled,
    status.agentsIntegrated,
    status.payloadCatalogSha256,
    status.buildCatalogSha256,
    status.installManifestSha256,
    status.agentsBlockSha256,
    status.cliVersion,
    status.installedVersion,
    status.desiredVersion,
    status.activeRuntime?.pid,
    status.activeRuntime?.startedAt,
    status.activeRuntime?.bridgeVersion,
  ].map(identityPart).join("|");
}

export function fullRunStaleReason(
  baseline: FullRunEvidenceBaseline | undefined,
  current: FullRunEvidenceCurrent,
  now = Date.now(),
): string | undefined {
  if (!baseline) return "The PASS has no renderer freshness baseline.";
  if (!current.controllerOnline) return "The controller is offline.";
  if (!current.statusFresh || !current.status) return "Codex integration status is not freshly verified.";
  if (current.status.state !== "connected") return `Codex integration is ${current.status.state.replaceAll("_", " ")}.`;
  if (baseline.integrationGeneration !== current.integrationGeneration) return "The plugin was installed or repaired after this PASS.";
  if (baseline.integrationIdentity !== integrationStatusIdentity(current.status)) return "The verified integration identity changed after this PASS.";
  if (current.fleetRevision === undefined) return "No current fleet snapshot is available.";
  if (baseline.fleetRevision !== current.fleetRevision) return `Fleet revision changed from ${baseline.fleetRevision} to ${current.fleetRevision}.`;
  const selected = current.selectedNode;
  if (!selected || selected.id !== baseline.selectedNodeId) return "The worker selected by this PASS is no longer present.";
  if (selected.status !== "online" && selected.status !== "degraded") return "The worker selected by this PASS is no longer online.";
  if (selected.availability && selected.availability !== "available" && selected.availability !== "degraded") {
    return "The worker selected by this PASS is no longer schedulable.";
  }
  if (!selected.lastSeenAt || now - Date.parse(selected.lastSeenAt) > 15_000) {
    return "The worker selected by this PASS has missed the freshness grace window.";
  }
  return undefined;
}

export const fullRunLayerIds: FullRunLayerId[] = [
  "plugin_check",
  "fresh_heartbeat",
  "source_snapshot",
  "worker_selection",
  "remote_execution",
  "log_verification",
  "artifact_verification",
  "cleanup",
];

const fullRunMcpTools = [
  "fleet_info",
  "workspace_snapshot_pack",
  "fleet_snapshot_upload",
  "fleet_plan_submit",
  "fleet_job",
] as const;

const fullRunStates = new Set<FullRunCheckState>(["running", "passed", "failed"]);
const fullRunLayerStates = new Set<FullRunLayerState>(["pending", "running", "passed", "failed", "skipped"]);
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const shaPattern = /^[0-9a-f]{64}$/;
const digestPattern = /^sha256:[0-9a-f]{64}$/;

const integrationStates = new Set<IntegrationState>([
  "not_found",
  "not_installed",
  "installed",
  "restart_required",
  "connected",
  "stale",
  "broken",
  "version_mismatch",
]);

export class IntegrationApiError extends Error {
  readonly code?: string;
  readonly retryable: boolean;

  constructor(message: string, code?: string, retryable = false) {
    super(message);
    this.name = "IntegrationApiError";
    this.code = code;
    this.retryable = retryable;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function safeText(value: unknown, maximum = 512): string | undefined {
  return typeof value === "string" && value.length > 0 && value.length <= maximum &&
    !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/u.test(value)
    ? value
    : undefined;
}

function parseStatus(value: unknown): IntegrationStatus {
  if (!isRecord(value) || !integrationStates.has(value.state as IntegrationState)) {
    throw new IntegrationApiError("Desktop host returned invalid integration status", "invalid_native_response");
  }
  const checkedAtMs = Number.isSafeInteger(value.checkedAtMs) ? value.checkedAtMs as number : undefined;
  if (
    checkedAtMs === undefined ||
    checkedAtMs <= 0 ||
    !integrationStatusIsFresh({ checkedAtMs }) ||
    typeof value.payloadAvailable !== "boolean" ||
    typeof value.pluginEnabled !== "boolean" ||
    typeof value.agentsIntegrated !== "boolean"
  ) {
    throw new IntegrationApiError("Desktop host returned invalid integration status", "invalid_native_response");
  }
  const message = safeText(value.message);
  const payloadCatalogSha256 = safeText(value.payloadCatalogSha256, 64);
  const buildCatalogSha256 = safeText(value.buildCatalogSha256, 64);
  const installManifestSha256 = safeText(value.installManifestSha256, 64);
  const agentsBlockSha256 = safeText(value.agentsBlockSha256, 64);
  const installedVersion = safeText(value.installedVersion, 64);
  const desiredVersion = safeText(value.desiredVersion, 64);
  let activeRuntime: IntegrationStatus["activeRuntime"];
  if (value.activeRuntime !== undefined && value.activeRuntime !== null) {
    const pid = isRecord(value.activeRuntime) ? safeInteger(value.activeRuntime.pid, 1) : undefined;
    const startedAt = isRecord(value.activeRuntime) ? safeTimestamp(value.activeRuntime.startedAt) : undefined;
    const bridgeVersion = isRecord(value.activeRuntime) ? safeText(value.activeRuntime.bridgeVersion, 128) : undefined;
    if (!isRecord(value.activeRuntime) || pid === undefined || !startedAt || !bridgeVersion ||
      Date.parse(startedAt) > checkedAtMs) {
      throw new IntegrationApiError("Desktop host returned invalid active runtime identity", "invalid_native_response");
    }
    activeRuntime = { pid, startedAt, bridgeVersion };
  }
  const exactInstalledState = ["installed", "restart_required", "connected", "stale"].includes(String(value.state));
  if (
    !message ||
    (value.payloadAvailable && (!payloadCatalogSha256 || !shaPattern.test(payloadCatalogSha256) ||
      !buildCatalogSha256 || !shaPattern.test(buildCatalogSha256) ||
      !installManifestSha256 || !shaPattern.test(installManifestSha256))) ||
    (value.agentsIntegrated && (!agentsBlockSha256 || !shaPattern.test(agentsBlockSha256))) ||
    (exactInstalledState && (!value.payloadAvailable || !value.pluginEnabled || !value.agentsIntegrated ||
      !installedVersion || !desiredVersion || installedVersion !== desiredVersion)) ||
    (value.state === "connected" && (!value.pluginEnabled || !value.agentsIntegrated || !activeRuntime ||
      activeRuntime.bridgeVersion !== installedVersion)) ||
    (value.state !== "connected" && activeRuntime !== undefined)
  ) {
    throw new IntegrationApiError("Desktop host returned invalid integration status", "invalid_native_response");
  }
  return {
    state: value.state as IntegrationState,
    checkedAtMs,
    payloadAvailable: value.payloadAvailable,
    pluginEnabled: value.pluginEnabled,
    agentsIntegrated: value.agentsIntegrated,
    ...(payloadCatalogSha256 ? { payloadCatalogSha256 } : {}),
    ...(buildCatalogSha256 ? { buildCatalogSha256 } : {}),
    ...(installManifestSha256 ? { installManifestSha256 } : {}),
    ...(agentsBlockSha256 ? { agentsBlockSha256 } : {}),
    ...(safeText(value.cliVersion, 128) ? { cliVersion: safeText(value.cliVersion, 128) } : {}),
    ...(installedVersion ? { installedVersion } : {}),
    ...(desiredVersion ? { desiredVersion } : {}),
    ...(activeRuntime ? { activeRuntime } : {}),
    message,
  };
}

function parsePlacement(value: unknown): FullRunPlacementEvidence | undefined {
  if (!isRecord(value)) return undefined;
  const planId = safeText(value.planId, 64);
  const jobDigest = safeText(value.jobDigest, 64);
  const score = Number.isSafeInteger(value.score) ? value.score as number : undefined;
  const fleetRevision = safeInteger(value.fleetRevision);
  const nodeRevision = safeInteger(value.nodeRevision);
  const policyRevision = safeInteger(value.policyRevision);
  const explanation = value.explanation;
  if (!planId || !uuidPattern.test(planId) || !jobDigest || !shaPattern.test(jobDigest) || score === undefined ||
    fleetRevision === undefined || nodeRevision === undefined || policyRevision === undefined || !isRecord(explanation) ||
    !["balanced", "performance", "manual"].includes(String(explanation.policy)) ||
    !Array.isArray(explanation.candidates) || explanation.candidates.length < 1 || explanation.candidates.length > 256) {
    return undefined;
  }
  const selectedNodeId = safeText(explanation.selectedNodeId, 64);
  if (!selectedNodeId || !uuidPattern.test(selectedNodeId)) return undefined;
  const seen = new Set<string>();
  const candidates: FullRunPlacementEvidence["explanation"]["candidates"] = [];
  for (const item of explanation.candidates) {
    const nodeId = isRecord(item) ? safeText(item.nodeId, 64) : undefined;
    const nodeName = isRecord(item) ? safeText(item.nodeName, 256) : undefined;
    if (!isRecord(item) || !nodeId || !uuidPattern.test(nodeId) || seen.has(nodeId) || !nodeName ||
      typeof item.eligible !== "boolean" || !Array.isArray(item.scoreComponents) || item.scoreComponents.length > 64 ||
      !Array.isArray(item.rejectionReasons) || item.rejectionReasons.length > 64) return undefined;
    seen.add(nodeId);
    const candidateScore = Number.isSafeInteger(item.score) ? item.score as number : undefined;
    if ((item.eligible && candidateScore === undefined) || (!item.eligible && item.score !== undefined)) return undefined;
    const componentKeys = new Set<string>();
    let componentSum = 0;
    const scoreComponents = item.scoreComponents.map((component) => {
      const key = isRecord(component) ? safeText(component.key, 128) : undefined;
      const detail = isRecord(component) ? safeText(component.detail, 512) : undefined;
      const componentValue = isRecord(component) && Number.isSafeInteger(component.value) ? component.value as number : undefined;
      if (!key || componentKeys.has(key) || !detail || componentValue === undefined ||
        !Number.isSafeInteger(componentSum + componentValue)) return undefined;
      componentKeys.add(key);
      componentSum += componentValue;
      return { key, value: componentValue, detail };
    });
    const rejectionCodes = new Set<string>();
    const rejectionReasons = item.rejectionReasons.map((reason) => {
      const code = isRecord(reason) ? safeText(reason.code, 128) : undefined;
      const detail = isRecord(reason) ? safeText(reason.detail, 512) : undefined;
      if (!code || !/^[a-z0-9_]+$/.test(code) || rejectionCodes.has(code) || !detail) return undefined;
      rejectionCodes.add(code);
      return { code, detail };
    });
    if (scoreComponents.some((component) => !component) || rejectionReasons.some((reason) => !reason) ||
      (item.eligible
        ? scoreComponents.length < 1 || componentSum !== candidateScore || rejectionReasons.length !== 0
        : scoreComponents.length !== 0 || rejectionReasons.length < 1)) return undefined;
    candidates.push({
      nodeId,
      nodeName,
      eligible: item.eligible,
      ...(candidateScore !== undefined ? { score: candidateScore } : {}),
      scoreComponents: scoreComponents as Array<{ key: string; value: number; detail: string }>,
      rejectionReasons: rejectionReasons as Array<{ code: string; detail: string }>,
    });
  }
  const selected = candidates.find((candidate) => candidate.nodeId === selectedNodeId);
  if (!selected?.eligible || selected.score !== score) return undefined;
  return {
    planId,
    jobDigest,
    score,
    fleetRevision,
    nodeRevision,
    policyRevision,
    explanation: {
      policy: explanation.policy as "balanced" | "performance" | "manual",
      selectedNodeId,
      candidates,
    },
  };
}

function parseSteps(value: unknown): IntegrationStep[] {
  if (!Array.isArray(value) || value.length < 1 || value.length > 16) {
    throw new IntegrationApiError("Desktop host returned invalid integration checks", "invalid_native_response");
  }
  const seen = new Set<string>();
  return value.map((entry) => {
    if (!isRecord(entry) || typeof entry.passed !== "boolean") {
      throw new IntegrationApiError("Desktop host returned invalid integration checks", "invalid_native_response");
    }
    const id = safeText(entry.id, 64);
    const message = safeText(entry.message);
    if (!id || !/^[a-z0-9_]+$/.test(id) || seen.has(id) || !message) {
      throw new IntegrationApiError("Desktop host returned invalid integration checks", "invalid_native_response");
    }
    seen.add(id);
    return { id, passed: entry.passed, message };
  });
}

function safeInteger(value: unknown, minimum = 0): number | undefined {
  return Number.isSafeInteger(value) && (value as number) >= minimum ? value as number : undefined;
}

function safeTimestamp(value: unknown): string | undefined {
  const text = safeText(value, 64);
  return text && isStrictRfc3339(text) ? text : undefined;
}

function parseSelfTestExecutorIdentity(value: unknown): SelfTestExecutorIdentity | undefined {
  if (!isRecord(value)) return undefined;
  const pid = safeInteger(value.pid, 1);
  const startedAt = safeTimestamp(value.startedAt);
  const bridgeVersion = safeText(value.bridgeVersion, 128);
  const sessionId = safeText(value.sessionId, 64);
  if (pid === undefined || !startedAt || !bridgeVersion || !sessionId || !uuidPattern.test(sessionId) ||
    sessionId === "00000000-0000-0000-0000-000000000000") return undefined;
  return { pid, startedAt, bridgeVersion, sessionId };
}

function parseFullRunResult(value: unknown): FullRunCheckResult {
  if (!isRecord(value) || !fullRunStates.has(value.state as FullRunCheckState)) {
    throw new IntegrationApiError("Desktop host returned an invalid Full Run Check result", "invalid_native_response");
  }
  if (!Array.isArray(value.layers) || value.layers.length !== fullRunLayerIds.length) {
    throw new IntegrationApiError("Desktop host returned invalid Full Run Check layers", "invalid_native_response");
  }
  const seen = new Set<string>();
  const layers = value.layers.map((entry, index): FullRunCheckLayer => {
    if (!isRecord(entry)) throw new IntegrationApiError("Desktop host returned invalid Full Run Check layers", "invalid_native_response");
    const id = entry.id as FullRunLayerId;
    const state = entry.state as FullRunLayerState;
    const message = safeText(entry.message, 1_024);
    if (id !== fullRunLayerIds[index] || !fullRunLayerIds.includes(id) || seen.has(id) || !fullRunLayerStates.has(state) || !message) {
      throw new IntegrationApiError("Desktop host returned invalid Full Run Check layers", "invalid_native_response");
    }
    seen.add(id);
    return { id, state, message };
  });
  if (fullRunLayerIds.some((id) => !seen.has(id))) {
    throw new IntegrationApiError("Desktop host returned incomplete Full Run Check layers", "invalid_native_response");
  }

  const startedAt = safeTimestamp(value.startedAt);
  const finishedAtSupplied = value.finishedAt !== undefined;
  const finishedAt = finishedAtSupplied ? safeTimestamp(value.finishedAt) : undefined;
  const durationMs = safeInteger(value.durationMs);
  const terminal = value.state === "passed" || value.state === "failed";
  if (!startedAt || durationMs === undefined || (finishedAtSupplied && !finishedAt) || (terminal && !finishedAt) ||
    (!terminal && finishedAt !== undefined) ||
    (finishedAt && Date.parse(finishedAt) < Date.parse(startedAt))) {
    throw new IntegrationApiError("Desktop host returned invalid Full Run Check timing", "invalid_native_response");
  }

  const logStreams = new Set<string>();
  const logs = Array.isArray(value.logs) && value.logs.length <= 2 ? value.logs.map((entry) => {
    if (!isRecord(entry) || !["stdout", "stderr"].includes(String(entry.stream))) {
      throw new IntegrationApiError("Desktop host returned invalid Full Run Check log evidence", "invalid_native_response");
    }
    const sizeBytes = safeInteger(entry.sizeBytes);
    const chunkCount = safeInteger(entry.chunkCount, 1);
    if (sizeBytes === undefined || chunkCount === undefined || !shaPattern.test(String(entry.sha256)) || logStreams.has(String(entry.stream))) {
      throw new IntegrationApiError("Desktop host returned invalid Full Run Check log evidence", "invalid_native_response");
    }
    logStreams.add(String(entry.stream));
    return { stream: entry.stream as "stdout" | "stderr", sizeBytes, sha256: String(entry.sha256), chunkCount };
  }) : undefined;

  const artifactIds = new Set<string>();
  const artifactNames = new Set<string>();
  const artifacts = Array.isArray(value.artifacts) && value.artifacts.length <= 8 ? value.artifacts.map((entry) => {
    const id = isRecord(entry) ? safeText(entry.id, 64) : undefined;
    const name = isRecord(entry) ? safeText(entry.name, 256) : undefined;
    const sizeBytes = isRecord(entry) ? safeInteger(entry.sizeBytes) : undefined;
    if (!isRecord(entry) || !id || !uuidPattern.test(id) || artifactIds.has(id) || !name || artifactNames.has(name) ||
      sizeBytes === undefined || !shaPattern.test(String(entry.sha256))) {
      throw new IntegrationApiError("Desktop host returned invalid Full Run Check artifact evidence", "invalid_native_response");
    }
    artifactIds.add(id);
    artifactNames.add(name);
    return { id, name, sizeBytes, sha256: String(entry.sha256) };
  }) : undefined;
  if (!logs || !artifacts) {
    throw new IntegrationApiError("Desktop host returned invalid Full Run Check evidence", "invalid_native_response");
  }

  const result: FullRunCheckResult = {
    state: value.state as FullRunCheckState,
    layers,
    startedAt,
    ...(finishedAt ? { finishedAt } : {}),
    durationMs,
    logs,
    artifacts,
  };
  if (value.failure !== undefined) {
    const code = isRecord(value.failure) ? safeText(value.failure.code, 96) : undefined;
    if (!isRecord(value.failure) || !code || !/^[a-z0-9_]+$/.test(code) || typeof value.failure.retryable !== "boolean") {
      throw new IntegrationApiError("Desktop host returned invalid Full Run Check failure", "invalid_native_response");
    }
    result.failure = { code, retryable: value.failure.retryable };
  }
  if (value.integration !== undefined) {
    const item = value.integration;
    const active = isRecord(item) && isRecord(item.activeRuntime) ? item.activeRuntime : undefined;
    const activePid = active ? safeInteger(active.pid, 1) : undefined;
    const activeStartedAt = active ? safeTimestamp(active.startedAt) : undefined;
    const activeBridgeVersion = active ? safeText(active.bridgeVersion, 128) : undefined;
    const initialReceiptVerifiedAt = active ? safeTimestamp(active.initialReceiptVerifiedAt) : undefined;
    const finalReceiptSupplied = active?.finalReceiptVerifiedAt !== undefined;
    const finalReceiptVerifiedAt = active ? safeTimestamp(active.finalReceiptVerifiedAt) : undefined;
    if (!isRecord(item) || !active || activePid === undefined || !activeStartedAt || !activeBridgeVersion ||
      !initialReceiptVerifiedAt || typeof active.reverifiedAfterRun !== "boolean" ||
      (finalReceiptSupplied && !finalReceiptVerifiedAt) ||
      Date.parse(activeStartedAt) > Date.parse(initialReceiptVerifiedAt) ||
      (finalReceiptVerifiedAt && Date.parse(finalReceiptVerifiedAt) < Date.parse(initialReceiptVerifiedAt))) {
      throw new IntegrationApiError("Desktop host returned invalid Full Run Check integration evidence", "invalid_native_response");
    }
    result.integration = {
      activeRuntime: {
        pid: activePid,
        startedAt: activeStartedAt,
        bridgeVersion: activeBridgeVersion,
        initialReceiptVerifiedAt,
        ...(finalReceiptVerifiedAt ? { finalReceiptVerifiedAt } : {}),
        reverifiedAfterRun: active.reverifiedAfterRun,
      },
    };
    if (item.selfTestExecutor !== undefined) {
      const executor = item.selfTestExecutor;
      const executorPid = isRecord(executor) ? safeInteger(executor.pid, 1) : undefined;
      const executorStartedAt = isRecord(executor) ? safeTimestamp(executor.startedAt) : undefined;
      const executorVersion = isRecord(executor) ? safeText(executor.bridgeVersion, 128) : undefined;
      const sessionId = isRecord(executor) ? safeText(executor.sessionId, 64) : undefined;
      const controllerRoundTripAt = isRecord(executor) ? safeTimestamp(executor.controllerRoundTripAt) : undefined;
      const tools = isRecord(executor) && Array.isArray(executor.mcpToolsExercised)
        ? executor.mcpToolsExercised.map((tool) => safeText(tool, 64))
        : undefined;
      if (!isRecord(executor) || executorPid === undefined || executorPid === activePid || !executorStartedAt ||
        !executorVersion || executorVersion !== activeBridgeVersion || !sessionId || !uuidPattern.test(sessionId) ||
        sessionId === "00000000-0000-0000-0000-000000000000" || executor.initializeCompleted !== true ||
        executor.toolsListCompleted !== true || !controllerRoundTripAt || !tools || tools.some((tool) => !tool) ||
        tools.length < 1 || tools.length > fullRunMcpTools.length || new Set(tools).size !== tools.length ||
        tools.some((tool, index) => tool !== fullRunMcpTools[index]) ||
        Date.parse(executorStartedAt) > Date.parse(controllerRoundTripAt)) {
        throw new IntegrationApiError("Desktop host returned invalid isolated MCP executor evidence", "invalid_native_response");
      }
      result.integration.selfTestExecutor = {
        pid: executorPid,
        startedAt: executorStartedAt,
        bridgeVersion: executorVersion,
        sessionId,
        initializeCompleted: true,
        toolsListCompleted: true,
        controllerRoundTripAt,
        mcpToolsExercised: tools as string[],
      };
    }
  }
  if (value.selectedNode !== undefined) {
    const item = value.selectedNode;
    const id = isRecord(item) ? safeText(item.id, 64) : undefined;
    const name = isRecord(item) ? safeText(item.name, 128) : undefined;
    const operatingSystem = isRecord(item) ? safeText(item.operatingSystem, 16) : undefined;
    const architecture = isRecord(item) ? safeText(item.architecture, 16) : undefined;
    const heartbeatAt = isRecord(item) ? safeTimestamp(item.heartbeatAt) : undefined;
    if (!isRecord(item) || !id || !uuidPattern.test(id) || !name || !operatingSystem || !architecture || !heartbeatAt) {
      throw new IntegrationApiError("Desktop host returned invalid Full Run Check node evidence", "invalid_native_response");
    }
    result.selectedNode = { id, name, operatingSystem, architecture, heartbeatAt };
  }
  if (value.transport !== undefined) {
    const item = value.transport;
    const endpoint = isRecord(item) ? safeText(item.endpoint, 2_048) : undefined;
    let parsed: URL | undefined;
    try {
      parsed = endpoint ? new URL(endpoint) : undefined;
    } catch {
      parsed = undefined;
    }
    if (!isRecord(item) || item.transport !== "managed_https" || !endpoint || !parsed || parsed.protocol !== "https:" ||
      parsed.username !== "" || parsed.password !== "" || parsed.search !== "" || parsed.hash !== "" ||
      item.tls !== true || item.credentialReferencePresent !== true) {
      throw new IntegrationApiError("Desktop host returned invalid Full Run Check transport evidence", "invalid_native_response");
    }
    result.transport = { transport: "managed_https", endpoint, tls: true, credentialReferencePresent: true };
  }
  if (value.placement !== undefined) {
    const placement = parsePlacement(value.placement);
    if (!placement) {
      throw new IntegrationApiError("Desktop host returned invalid Full Run Check placement evidence", "invalid_native_response");
    }
    result.placement = placement;
  }
  if (value.finalFleet !== undefined) {
    const fleetRevision = isRecord(value.finalFleet) ? safeInteger(value.finalFleet.fleetRevision) : undefined;
    const observedAt = isRecord(value.finalFleet) ? safeTimestamp(value.finalFleet.observedAt) : undefined;
    if (!isRecord(value.finalFleet) || fleetRevision === undefined || !observedAt) {
      throw new IntegrationApiError("Desktop host returned invalid post-run fleet evidence", "invalid_native_response");
    }
    result.finalFleet = { fleetRevision, observedAt };
  }
  if (value.snapshot !== undefined) {
    const sizeBytes = isRecord(value.snapshot) ? safeInteger(value.snapshot.sizeBytes, 1) : undefined;
    if (!isRecord(value.snapshot) || !digestPattern.test(String(value.snapshot.digest)) || sizeBytes === undefined) {
      throw new IntegrationApiError("Desktop host returned invalid Full Run Check snapshot evidence", "invalid_native_response");
    }
    result.snapshot = { digest: String(value.snapshot.digest), sizeBytes };
  }
  if (value.job !== undefined) {
    const item = value.job;
    const jobId = isRecord(item) ? safeText(item.jobId, 64) : undefined;
    const runId = isRecord(item) ? safeText(item.runId, 64) : undefined;
    const state = isRecord(item) ? safeText(item.state, 32) : undefined;
    const exitCode = isRecord(item) && item.exitCode !== undefined && Number.isSafeInteger(item.exitCode)
      ? item.exitCode as number
      : undefined;
    const observedStates = isRecord(item) && Array.isArray(item.observedStates) && item.observedStates.length >= 1 && item.observedStates.length <= 7
      ? item.observedStates.map((entry) => safeText(entry, 32))
      : undefined;
    const allowedJobStates = ["queued", "preparing", "running", "verifying", "succeeded", "failed", "cancelled"];
    const observed = observedStates as string[] | undefined;
    const observedRanks = observed?.map((entry) => allowedJobStates.indexOf(entry));
    if (!jobId || !uuidPattern.test(jobId) || !runId || !uuidPattern.test(runId) || !state || !allowedJobStates.includes(state) ||
      (isRecord(item) && item.exitCode !== undefined && exitCode === undefined) ||
      !observed || observed.some((entry) => !entry) || new Set(observed).size !== observed.length ||
      observed.at(-1) !== state || observedRanks?.some((rank) => rank < 0) ||
      observedRanks?.some((rank, index) => index > 0 && rank <= observedRanks[index - 1]!)) {
      throw new IntegrationApiError("Desktop host returned invalid Full Run Check job evidence", "invalid_native_response");
    }
    result.job = { jobId, runId, state, ...(exitCode !== undefined ? { exitCode } : {}), observedStates: observed };
  }
  if (value.cleanup !== undefined) {
    const item = value.cleanup;
    const jobId = isRecord(item) ? safeText(item.jobId, 64) : undefined;
    const runId = isRecord(item) ? safeText(item.runId, 64) : undefined;
    const relativeRoot = isRecord(item) ? safeText(item.relativeRoot, 256) : undefined;
    const terminalStateVersion = isRecord(item) ? safeInteger(item.terminalStateVersion) : undefined;
    const terminalAcknowledgedAt = isRecord(item) ? safeTimestamp(item.terminalAcknowledgedAt) : undefined;
    const observedAt = isRecord(item) ? safeTimestamp(item.observedAt) : undefined;
    const receivedAt = isRecord(item) ? safeTimestamp(item.receivedAt) : undefined;
    const reservationReleasedAt = isRecord(item) ? safeTimestamp(item.reservationReleasedAt) : undefined;
    if (!isRecord(item) || !jobId || !uuidPattern.test(jobId) || !runId || !uuidPattern.test(runId) ||
      relativeRoot !== `jobs/${runId}` || item.status !== "removed" || item.jobRootDeleted !== true ||
      terminalStateVersion === undefined || !terminalAcknowledgedAt || !observedAt || !receivedAt || !reservationReleasedAt ||
      Date.parse(observedAt) < Date.parse(terminalAcknowledgedAt) || Date.parse(receivedAt) < Date.parse(terminalAcknowledgedAt) ||
      Date.parse(reservationReleasedAt) < Date.parse(terminalAcknowledgedAt) || item.releaseReason !== "removed_receipt") {
      throw new IntegrationApiError("Desktop host returned invalid Full Run Check cleanup evidence", "invalid_native_response");
    }
    result.cleanup = {
      jobId,
      runId,
      relativeRoot,
      status: "removed",
      jobRootDeleted: true,
      terminalStateVersion,
      terminalAcknowledgedAt,
      observedAt,
      receivedAt,
      reservationReleasedAt,
      releaseReason: "removed_receipt",
    };
  }

  if (result.state === "passed") {
    const parsedLogStreams = new Set(result.logs.map((log) => log.stream));
    if (result.failure || layers.some((layer) => layer.state !== "passed") || !result.integration ||
      !result.integration.activeRuntime.finalReceiptVerifiedAt || !result.integration.activeRuntime.reverifiedAfterRun ||
      !result.integration.selfTestExecutor || result.integration.selfTestExecutor.mcpToolsExercised.length !== fullRunMcpTools.length ||
      !result.selectedNode || !result.transport || !result.placement ||
      !result.finalFleet || result.finalFleet.fleetRevision < result.placement.fleetRevision ||
      result.placement.explanation.selectedNodeId !== result.selectedNode.id || !result.snapshot || !result.job ||
      result.job.state !== "succeeded" || result.job.exitCode !== 0 ||
      !result.cleanup || result.cleanup.jobId !== result.job.jobId || result.cleanup.runId !== result.job.runId ||
      Date.parse(result.integration.activeRuntime.initialReceiptVerifiedAt) < Date.parse(startedAt) ||
      Date.parse(result.integration.activeRuntime.finalReceiptVerifiedAt) > Date.parse(finishedAt!) ||
      Date.parse(result.integration.selfTestExecutor.startedAt) < Date.parse(startedAt) ||
      Date.parse(result.integration.selfTestExecutor.controllerRoundTripAt) > Date.parse(finishedAt!) ||
      Date.parse(result.finalFleet.observedAt) < Date.parse(startedAt) ||
      Date.parse(result.finalFleet.observedAt) > Date.parse(finishedAt!) ||
      Date.parse(result.selectedNode.heartbeatAt) < Date.parse(startedAt) ||
      logs.length !== 2 || parsedLogStreams.size !== 2 || !parsedLogStreams.has("stdout") || !parsedLogStreams.has("stderr") ||
      artifacts.length === 0) {
      throw new IntegrationApiError("Desktop host returned an unproven Full Run Check PASS", "invalid_native_response");
    }
  } else if (result.state === "failed") {
    const primaryFailures = layers.slice(0, -1).filter((layer) => layer.state === "failed");
    const primaryFailed = primaryFailures[0];
    const firstFailed = primaryFailed ? layers.indexOf(primaryFailed) : layers.length - 1;
    const suffix = layers.slice(firstFailed + 1, -1);
    const suffixIsSkipped = suffix.every((layer) => layer.state === "skipped");
    const suffixIsPassed = suffix.every((layer) => layer.state === "passed");
    const cleanupState = layers.at(-1)?.state;
    if (!result.failure || layers.some((layer) => layer.state === "pending" || layer.state === "running") ||
      primaryFailures.length > 1 || layers.slice(0, firstFailed).some((layer) => layer.state !== "passed") ||
      (!suffixIsSkipped && !suffixIsPassed) || !["passed", "failed", "skipped"].includes(String(cleanupState)) ||
      (primaryFailures.length === 0 && cleanupState !== "failed")) {
      throw new IntegrationApiError("Desktop host returned an unproven Full Run Check failure", "invalid_native_response");
    }
  } else {
    const primaryFailures = layers.slice(0, -1).filter((layer) => layer.state === "failed");
    const runningLayers = layers.filter((layer) => layer.state === "running");
    const firstUnpassed = layers.findIndex((layer) => layer.state !== "passed");
    const normalProgress = !result.failure && primaryFailures.length === 0 && runningLayers.length <= 1 &&
      (firstUnpassed < 0 || layers.slice(0, firstUnpassed).every((layer) => layer.state === "passed")) &&
      (firstUnpassed < 0 || ["pending", "running"].includes(layers[firstUnpassed]!.state)) &&
      (firstUnpassed < 0 || layers.slice(firstUnpassed + 1).every((layer) => layer.state === "pending"));
    const progressFailureIndex = primaryFailures[0] ? layers.indexOf(primaryFailures[0]) : layers.length - 1;
    const failedSuffix = layers.slice(progressFailureIndex + 1, -1);
    const failedProgress = Boolean(result.failure) && primaryFailures.length <= 1 && runningLayers.length <= 1 &&
      (runningLayers.length === 0 || runningLayers[0]?.id === "cleanup") &&
      (primaryFailures.length === 1 || layers.at(-1)?.state === "failed") &&
      layers.slice(0, progressFailureIndex)
        .every((layer) => layer.state === "passed") &&
      (failedSuffix.every((layer) => layer.state === "passed") || failedSuffix.every((layer) => layer.state === "skipped")) &&
      ["pending", "running", "passed", "failed", "skipped"].includes(String(layers.at(-1)?.state));
    if ((!result.failure && !normalProgress) || (result.failure && !failedProgress)) {
      throw new IntegrationApiError("Desktop host returned invalid Full Run Check progress", "invalid_native_response");
    }
  }
  return result;
}

function publicError(error: unknown): IntegrationApiError {
  if (error instanceof IntegrationApiError) return error;
  const code = isRecord(error) && /^[a-z0-9_]+$/.test(String(error.code)) ? String(error.code) : undefined;
  const retryable = isRecord(error) && error.retryable === true;
  const messages: Record<string, string> = {
    codex_not_found: "Codex Desktop or the Codex CLI was not found",
    codex_cli_broken: "The detected Codex CLI could not complete the request",
    integration_payload_unavailable: "The bundled Codex plugin payload is missing or incomplete",
    marketplace_install_failed: "The local ClusterYourCodex marketplace could not be registered",
    plugin_install_failed: "The ClusterYourCodex plugin could not be installed",
    integration_state_unavailable: "Integration health state could not be saved",
    integration_self_test_failed: "The plugin connection check could not be completed",
    integration_busy_retryable: "Another Codex integration operation is still finishing; retry shortly",
    full_run_check_busy: "A Full Run Check is already in progress",
    full_run_check_unavailable: "The Full Run Check native backend is unavailable",
  };
  return new IntegrationApiError(code ? messages[code] ?? "Codex integration operation failed" : "Desktop integration bridge is unavailable", code, retryable);
}

function bridge() {
  const value = globalThis.window?.__CLUSTER_YOUR_CODEX__;
  if (!value) throw new IntegrationApiError("Desktop integration bridge is unavailable", "bridge_unavailable");
  return value;
}

function progressBridge(): { fullRunCheckStatus: () => Promise<unknown> } {
  const value = bridge() as unknown as { fullRunCheckStatus?: () => Promise<unknown> };
  if (typeof value.fullRunCheckStatus !== "function") {
    throw new IntegrationApiError("Full Run Check progress bridge is unavailable", "bridge_unavailable");
  }
  return { fullRunCheckStatus: value.fullRunCheckStatus.bind(value) };
}

export function fullRunResultsExactlyMatch(
  commandResult: FullRunCheckResult,
  finalStatus: FullRunCheckResult,
): boolean {
  return JSON.stringify(commandResult) === JSON.stringify(finalStatus);
}

function wait(milliseconds: number): Promise<void> {
  return new Promise((resolve) => globalThis.setTimeout(resolve, milliseconds));
}

export class IntegrationClient {
  private async fullRunCheckRaw(): Promise<unknown> {
    try {
      return await bridge().fullRunCheck();
    } catch (error) {
      throw publicError(error);
    }
  }

  private async fullRunCheckStatusRaw(): Promise<unknown> {
    try {
      return await progressBridge().fullRunCheckStatus();
    } catch (error) {
      throw publicError(error);
    }
  }

  async status(): Promise<IntegrationStatus> {
    try {
      return parseStatus(await bridge().integrationStatus());
    } catch (error) {
      throw publicError(error);
    }
  }

  async installOrRepair(): Promise<IntegrationActionResult> {
    try {
      const value = await bridge().installOrRepairIntegration();
      if (!isRecord(value) || typeof value.changed !== "boolean" || typeof value.restartRequired !== "boolean") {
        throw new IntegrationApiError("Desktop host returned an invalid install result", "invalid_native_response");
      }
      const steps = parseSteps(value.steps);
      const status = parseStatus(value.status);
      if (steps.some((step) => !step.passed) || ["not_found", "not_installed", "broken", "version_mismatch"].includes(status.state) ||
        (status.state === "restart_required" && !value.restartRequired)) {
        throw new IntegrationApiError("Desktop host returned a contradictory install result", "invalid_native_response");
      }
      return {
        changed: value.changed,
        restartRequired: value.restartRequired,
        steps,
        status,
      };
    } catch (error) {
      throw publicError(error);
    }
  }

  async selfTest(): Promise<IntegrationSelfTestResult> {
    try {
      const value = await bridge().integrationSelfTest();
      if (
        !isRecord(value) ||
        typeof value.passed !== "boolean" ||
        typeof value.restartRecommended !== "boolean" ||
        !Number.isSafeInteger(value.durationMs) ||
        (value.durationMs as number) < 0
      ) {
        throw new IntegrationApiError("Desktop host returned an invalid connection check", "invalid_native_response");
      }
      const checks = parseSteps(value.checks);
      const status = parseStatus(value.status);
      const selfTestExecutor = value.selfTestExecutor === undefined
        ? undefined
        : parseSelfTestExecutorIdentity(value.selfTestExecutor);
      if (value.selfTestExecutor !== undefined && !selfTestExecutor) {
        throw new IntegrationApiError("Desktop host returned invalid isolated MCP executor identity", "invalid_native_response");
      }
      if (value.passed !== checks.every((check) => check.passed) ||
        (value.passed && (!selfTestExecutor || selfTestExecutor.bridgeVersion !== status.installedVersion ||
          Date.parse(selfTestExecutor.startedAt) > status.checkedAtMs ||
          selfTestExecutor.pid === status.activeRuntime?.pid)) ||
        (!value.passed && selfTestExecutor !== undefined)) {
        throw new IntegrationApiError("Desktop host returned contradictory connection checks", "invalid_native_response");
      }
      return {
        passed: value.passed,
        durationMs: value.durationMs as number,
        restartRecommended: value.restartRecommended,
        checks,
        ...(selfTestExecutor ? { selfTestExecutor } : {}),
        status,
      };
    } catch (error) {
      throw publicError(error);
    }
  }

  async fullRunCheck(): Promise<FullRunCheckResult> {
    try {
      return parseFullRunResult(await this.fullRunCheckRaw());
    } catch (error) {
      throw publicError(error);
    }
  }

  async fullRunCheckStatus(): Promise<FullRunCheckResult | null> {
    try {
      const value = await this.fullRunCheckStatusRaw();
      return value === null ? null : parseFullRunResult(value);
    } catch (error) {
      throw publicError(error);
    }
  }

  async fullRunCheckWithProgress(
    onProgress: (progress: FullRunCheckResult) => void,
    pollIntervalMs = 350,
  ): Promise<FullRunCheckResult> {
    if (!Number.isSafeInteger(pollIntervalMs) || pollIntervalMs < 250 || pollIntervalMs > 500) {
      throw new RangeError("Full Run Check polling must be between 250 and 500 ms");
    }
    let commandSettled = false;
    const command = this.fullRunCheckRaw().then(
      (value) => ({ ok: true as const, value }),
      (error: unknown) => ({ ok: false as const, error }),
    );
    const polling = (async () => {
      while (!commandSettled) {
        await wait(pollIntervalMs);
        if (commandSettled) break;
        try {
          const progress = await this.fullRunCheckStatus();
          // Ignore a terminal receipt left by an earlier invocation while the
          // new native operation is still publishing its first running frame.
          if (!commandSettled && progress?.state === "running") onProgress(progress);
        } catch {
          // A transient progress read is not terminal evidence. The exact
          // post-command read below remains mandatory and fail-closed.
        }
      }
    })();
    const outcome = await command;
    commandSettled = true;
    await polling;
    if (!outcome.ok) throw outcome.error;
    const commandResult = parseFullRunResult(outcome.value);
    const finalStatusValue = await this.fullRunCheckStatusRaw();
    const finalStatus = finalStatusValue === null ? null : parseFullRunResult(finalStatusValue);
    if (!finalStatus || JSON.stringify(outcome.value) !== JSON.stringify(finalStatusValue) ||
      !fullRunResultsExactlyMatch(commandResult, finalStatus)) {
      throw new IntegrationApiError(
        "Full Run Check command result did not match its final native status",
        "invalid_native_response",
      );
    }
    return commandResult;
  }
}

export const integrationClient = new IntegrationClient();
