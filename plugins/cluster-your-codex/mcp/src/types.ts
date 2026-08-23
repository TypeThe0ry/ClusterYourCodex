export type JobKind = "shell" | "build" | "test" | "lint" | "container" | "gpu" | "batch";
export type GpuVendor = "nvidia" | "amd" | "intel" | "apple";

export interface ResourceRequest {
  slots?: number;
  cpuCores?: number;
  memoryMiB?: number;
  diskMiB?: number;
  gpu?: {
    deviceId?: string;
    vendor?: GpuVendor;
    vramMiB?: number;
    exclusive?: boolean;
  };
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
  source:
    | { type: "git"; repository: string; revision: string }
    | { type: "snapshot"; digest: `sha256:${string}`; sizeBytes: number };
  requirements?: {
    os?: "windows" | "linux" | "macos";
    arch?: "x86_64" | "aarch64";
    capabilities?: string[];
    minCpuCores?: number;
    minMemoryMiB?: number;
    minDiskMiB?: number;
    gpu?: {
      vendor?: GpuVendor;
      minVramMiB?: number;
      exclusive?: boolean;
    };
  };
  /**
   * Consumable capacity reserved atomically for this run. Omit this field to
   * retain preview-client compatibility; the controller then derives one slot
   * and the CPU/memory/disk/GPU minima from `requirements`.
   */
  resourceRequest?: ResourceRequest;
  steps: Array<{
    name: string;
    shell?: "powershell" | "bash" | "zsh" | "cmd";
    script: string;
    workingDirectory?: string;
    timeoutSeconds?: number;
  }>;
  artifacts?: {
    include?: string[];
    exclude?: string[];
    retentionDays?: number;
  };
  timeoutSeconds?: number;
  placementPolicy?: "balanced" | "performance" | "manual";
  preferredNodeId?: string;
}

export type JobDraft = Omit<JobSpec, "apiVersion" | "id"> & {
  apiVersion?: "cyc.dev/v1";
  id?: string;
};

export interface HealthResponse {
  status: "ok";
  apiVersion: "cyc.dev/v1";
  controllerVersion: string;
  database: "ok";
}

export type NodeAvailability = "available" | "degraded" | "draining" | "disabled" | "offline" | "stale";

export interface FleetDocument<T> {
  document: T;
  revision?: number;
  digest?: string;
  observedAt: string;
  receivedAt: string;
}

export interface FleetNodeView {
  nodeId: string;
  config: FleetDocument<{
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
  }>;
  inventory: FleetDocument<{
    transport: Record<string, unknown> & { type: "local" | "managed" | "ssh" };
    os: "windows" | "linux" | "macos";
    arch: "x86_64" | "aarch64";
    capabilities: string[];
    logicalCpuCores: number;
    memoryMiB: number;
    diskMiB: number;
    gpus: Array<{
      vendor: GpuVendor;
      model: string;
      totalVramMiB: number;
      stableId?: string;
      driverVersion?: string;
    }>;
    cpuModel: string;
    toolVersions: Record<string, string>;
    workerVersion: string;
    protocolVersion: number;
    containment: { backend: string; version: string; maxSafeSlots: number };
  }>;
  telemetry: FleetDocument<{
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
  }>;
  availability: NodeAvailability;
  availabilityReasons: string[];
  effectiveSlots: {
    configured: number;
    containmentMaxSafe: number;
    effective: number;
    reserved: number;
    available: number;
  };
  effectiveResources: Record<string, unknown> & {
    logicalCpuCores: number;
    availableCpuCores: number;
    memoryMiB: number;
    availableMemoryMiB: number;
    diskMiB: number;
    availableDiskMiB: number;
  };
  reservations: Array<{
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
  }>;
}

export interface FleetInfo {
  fleetRevision: number;
  observedAt: string;
  controller: {
    version: string;
    apiVersion: "cyc.dev/v1";
    access: "loopback";
  };
  codex: {
    integration: "mcp";
    status: string;
  };
  nodes: Array<{
    id: string;
    name: string;
    enabled: boolean;
    transport: Record<string, unknown> & { type: "local" | "managed" | "ssh" };
    os: "windows" | "linux" | "macos";
    arch: "x86_64" | "aarch64";
    status: "online" | "degraded" | "draining" | "offline";
    capabilities: string[];
    resources: Record<string, unknown>;
    load: { cpuPercent: number; queueDepth: number; runningJobs: number };
    priority: number;
    labels: Record<string, string>;
    cachedSources: string[];
    lastSeenAt?: string;
  }>;
  /** Additive split-state view used for fresh occupancy and capacity decisions. */
  nodeViews?: FleetNodeView[];
  recentJobs: JobResponse[];
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
    explanation: PlacementExplanation;
  };
}

export type PlanResponse = PlacementPlanBindingV1;

export interface SnapshotMetadata {
  apiVersion: "cyc.dev/snapshot/v1";
  format: "tar+zstd";
  digest: `sha256:${string}`;
  sizeBytes: number;
  createdAt: string;
}

export type JobStatus = "queued" | "preparing" | "running" | "verifying" | "succeeded" | "failed" | "cancelled";

export interface PlacementExplanation {
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
  placement?: PlacementExplanation;
  artifactIds: string[];
}

export interface JobResponse {
  job: JobSpec;
  run: RunPayload;
  /** Null is reserved for non-backfillable pre-binding controller rows. */
  planBinding: PlacementPlanBindingV1 | null;
  version: number;
  cancelRequested: boolean;
}
