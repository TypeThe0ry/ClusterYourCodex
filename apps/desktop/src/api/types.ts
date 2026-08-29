export type ControllerStatus = "ready" | "degraded" | "starting";
export type NodeStatus = "online" | "busy" | "offline" | "unknown";
export type JobStatus =
  | "queued"
  | "preparing"
  | "running"
  | "verifying"
  | "succeeded"
  | "failed"
  | "cancelled";

export interface HealthResponse {
  status: ControllerStatus;
  version: string;
  apiVersion: "cyc.dev/v1";
  startedAt?: string;
}

export interface ControllerHealthPayload {
  status: "ok";
  apiVersion: "cyc.dev/v1";
  controllerVersion: string;
  database: "ok";
}

export interface NodeResourceSummary {
  cpuPercent?: number;
  memoryUsedMiB?: number;
  memoryTotalMiB?: number;
  gpuPercent?: number;
  vramUsedMiB?: number;
  vramTotalMiB?: number;
}

export interface NodeSummary {
  id: string;
  name: string;
  address: string;
  os: "windows" | "linux" | "macos";
  arch: "x86_64" | "aarch64";
  status: NodeStatus;
  priority: number;
  capabilities: string[];
  resources?: NodeResourceSummary;
  lastSeenAt?: string;
  activeJobs: number;
  availability?: NodeAvailability;
  availabilityReasons?: string[];
  slots?: FleetSlotPayload;
  telemetry?: {
    observedAt: string;
    receivedAt: string;
    bootGeneration: number;
    bootId: string;
    sequence: number;
    cpuEwmaPercent: number;
    powerSource: "ac" | "battery" | "unknown";
    temperatureC?: number;
  };
}

export type NodeAvailability =
  | "available"
  | "degraded"
  | "draining"
  | "disabled"
  | "offline"
  | "stale";

export interface JobSummary {
  id: string;
  kind: JobKind;
  title?: string;
  status: JobStatus;
  nodeId?: string;
  nodeName?: string;
  createdAt: string;
  startedAt?: string;
  finishedAt?: string;
  exitCode?: number;
  elapsedMs?: number;
  placement?: PlacementExplanationPayload;
}

export interface FleetInfo {
  fleetRevision: number;
  observedAt: string;
  controller: {
    status: ControllerStatus;
    version: string;
    activeJobs: number;
    queuedJobs: number;
    completedToday: number;
  };
  codex: {
    connected: boolean;
    pluginVersion?: string;
    lastSeenAt?: string;
  };
  nodes: NodeSummary[];
  recentJobs?: JobSummary[];
}

export type JobKind =
  | "shell"
  | "build"
  | "test"
  | "lint"
  | "container"
  | "gpu"
  | "batch";

export interface GitSource {
  type: "git";
  repository: string;
  revision: string;
}

export interface SnapshotSource {
  type: "snapshot";
  digest: `sha256:${string}`;
  sizeBytes?: number;
}

export interface JobRequirements {
  os?: "windows" | "linux" | "macos";
  arch?: "x86_64" | "aarch64";
  capabilities?: string[];
  minCpuCores?: number;
  minMemoryMiB?: number;
  minDiskMiB?: number;
  gpu?: {
    vendor?: "nvidia" | "amd" | "intel" | "apple";
    minVramMiB?: number;
    exclusive?: boolean;
  };
}

export interface ResourceRequest {
  slots?: number;
  cpuCores?: number;
  memoryMiB?: number;
  diskMiB?: number;
  gpu?: {
    deviceId?: string;
    vendor?: "nvidia" | "amd" | "intel" | "apple";
    vramMiB?: number;
    exclusive?: boolean;
  };
}

export interface JobStep {
  name: string;
  shell?: "powershell" | "bash" | "zsh" | "cmd";
  script: string;
  workingDirectory?: string;
  timeoutSeconds?: number;
}

export interface JobSpec {
  apiVersion: "cyc.dev/v1";
  id: string;
  origin?: {
    codexSessionId?: string;
    projectId?: string;
    workspaceId?: string;
  };
  kind: JobKind;
  source: GitSource | SnapshotSource;
  requirements?: JobRequirements;
  resourceRequest?: ResourceRequest;
  steps: JobStep[];
  artifacts?: {
    include?: string[];
    exclude?: string[];
    retentionDays?: number;
  };
  timeoutSeconds?: number;
  placementPolicy?: "balanced" | "performance" | "manual";
  preferredNodeId?: string;
}

export interface PlanRequest {
  job: JobSpec;
}

export interface PlacementPlanBindingV1 {
  apiVersion: "cyc.dev/placement-plan-binding/v1";
  planId: string;
  jobId: string;
  jobDigest: string;
  createdAt: string;
  expiresAt: string;
  fleetRevision: number;
  nodeRevision: number;
  policyRevision: number;
  decision: {
    nodeId: string;
    score: number;
    explanation: PlacementExplanationPayload;
  };
}

export type PlanResponse = PlacementPlanBindingV1;

export interface SubmitJobRequest {
  job: JobSpec;
  planId?: string;
}

export interface JobResponse {
  job: JobSpec;
  run: RunPayload;
  /** Null is reserved for non-backfillable pre-binding controller rows. */
  planBinding: PlacementPlanBindingV1 | null;
  version: number;
  cancelRequested: boolean;
}

export type SubmitJobResponse = JobResponse;
export type CancelJobResponse = JobResponse;

export interface PlacementExplanationPayload {
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
}

export interface RunPayload {
  id: string;
  jobId: string;
  nodeId?: string;
  state: JobStatus;
  createdAt: string;
  startedAt?: string;
  finishedAt?: string;
  exitCode?: number;
  error?: string;
  placement?: PlacementExplanationPayload;
  artifactIds: string[];
}

export interface NodePayload {
  id: string;
  name: string;
  enabled: boolean;
  transport:
    | { type: "local" }
    | { type: "managed"; endpoint: string; credentialRef: string }
    | { type: "ssh"; host: string; port: number; username: string; credentialRef: string };
  os: "windows" | "linux" | "macos";
  arch: "x86_64" | "aarch64";
  status: "online" | "degraded" | "draining" | "offline";
  capabilities: string[];
  resources: {
    logicalCpuCores: number;
    availableCpuCores: number;
    memoryMib: number;
    availableMemoryMib: number;
    diskMib: number;
    availableDiskMib: number;
    gpus: Array<{
      vendor: "nvidia" | "amd" | "intel" | "apple";
      model: string;
      totalVramMib: number;
      availableVramMib: number;
      allocatable: boolean;
    }>;
  };
  load: { cpuPercent: number; queueDepth: number; runningJobs: number };
  priority: number;
  labels: Record<string, string>;
  cachedSources: string[];
  lastSeenAt?: string;
}

export interface FleetDocumentPayload<T> {
  document: T;
  revision?: number;
  digest?: string;
  observedAt: string;
  receivedAt: string;
}

export interface NodeConfigPayload {
  name: string;
  enabled: boolean;
  priority: number;
  labels: Record<string, string>;
  desiredState: "active" | "draining";
  capacity: {
    maxConcurrentJobs: number;
    allocatableCpuCores?: number;
    allocatableCpuPercent?: number;
    memoryLimitMiB?: number;
    allowedJobKinds: JobKind[];
    allowOnBattery: boolean;
    maxCpuPercent?: number;
    maxCpuEwmaPercent?: number;
    maxMemoryPercent?: number;
    maxTemperatureC?: number;
  };
}

export interface NodeInventoryPayload {
  transport: NodePayload["transport"];
  os: NodePayload["os"];
  arch: NodePayload["arch"];
  capabilities: string[];
  logicalCpuCores: number;
  memoryMiB: number;
  diskMiB: number;
  gpus: Array<{
    vendor: "nvidia" | "amd" | "intel" | "apple";
    model: string;
    totalVramMiB: number;
    stableId?: string;
    driverVersion?: string;
  }>;
  cpuModel: string;
  toolVersions: Record<string, string>;
  workerVersion: string;
  protocolVersion: number;
  containment: {
    backend: "legacy" | "linux_subreaper_process_group" | "macos_process_group" | "windows_job_object" | "unsupported";
    version: string;
    maxSafeSlots: number;
  };
}

export interface NodeTelemetryPayload {
  status: "online" | "degraded" | "draining" | "offline";
  availableCpuCores: number;
  availableMemoryMiB: number;
  availableDiskMiB: number;
  gpus: Array<{
    availableVramMiB: number;
    allocatable: boolean;
    stableId?: string;
    utilizationPercent?: number;
    temperatureC?: number;
  }>;
  load: { cpuPercent: number; queueDepth: number; runningJobs: number };
  cachedSources: string[];
  observedAt: string;
  bootGeneration: number;
  bootId: string;
  sequence: number;
  cpuEwmaPercent: number;
  activeRunIds: string[];
  powerSource: "ac" | "battery" | "unknown";
  battery?: { chargePercent?: number; charging?: boolean };
  temperatureC?: number;
}

export interface FleetSlotPayload {
  configured: number;
  containmentMaxSafe: number;
  effective: number;
  reserved: number;
  available: number;
}

export interface FleetReservationPayload {
  leaseId: string;
  runId: string;
  jobId: string;
  phase: string;
  slots: number;
  cpuCores: number;
  memoryMiB: number;
  diskMiB: number;
  gpuDeviceId?: string;
  gpuVramMiB: number;
  gpuExclusive: boolean;
  expiresAt: string;
}

export interface FleetNodeViewPayload {
  nodeId: string;
  config: FleetDocumentPayload<NodeConfigPayload>;
  inventory: FleetDocumentPayload<NodeInventoryPayload>;
  telemetry: FleetDocumentPayload<NodeTelemetryPayload>;
  availability: NodeAvailability;
  availabilityReasons: string[];
  effectiveSlots: FleetSlotPayload;
  effectiveResources: NodePayload["resources"];
  reservations: FleetReservationPayload[];
}

export interface JobViewPayload {
  job: JobSpec;
  run: RunPayload;
}

export interface FleetPayload {
  fleetRevision: number;
  observedAt: string;
  controller: { version: string; apiVersion: "cyc.dev/v1"; access: "loopback" };
  codex: { integration: "mcp"; status: string };
  nodes: NodePayload[];
  nodeViews?: FleetNodeViewPayload[];
  recentJobs: JobViewPayload[];
}
