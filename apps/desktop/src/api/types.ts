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
}

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
}

export interface FleetInfo {
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

export interface PlanResponse {
  planId: string;
  jobId: string;
  createdAt: string;
  decision: {
    nodeId: string;
    score: number;
    explanation: PlacementExplanationPayload;
  };
}

export interface SubmitJobRequest {
  job: JobSpec;
  planId?: string;
}

export interface SubmitJobResponse {
  job: JobSpec;
  run: RunPayload;
}

export interface JobResponse {
  job: JobSpec;
  run: RunPayload;
}

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

export interface JobViewPayload {
  job: JobSpec;
  run: RunPayload;
}

export interface FleetPayload {
  controller: { version: string; apiVersion: "cyc.dev/v1"; access: "loopback" };
  codex: { integration: "mcp"; status: string };
  nodes: NodePayload[];
  recentJobs: JobViewPayload[];
}
