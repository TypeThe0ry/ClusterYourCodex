export type JobKind = "shell" | "build" | "test" | "lint" | "container" | "gpu" | "batch";

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
    | { type: "snapshot"; digest: `sha256:${string}`; sizeBytes?: number };
  requirements?: {
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
  };
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

export interface FleetInfo {
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
  recentJobs: JobResponse[];
}

export interface PlanResponse {
  planId: string;
  jobId: string;
  createdAt: string;
  decision: {
    nodeId: string;
    score: number;
    explanation: Record<string, unknown>;
  };
}

export type JobStatus = "queued" | "preparing" | "running" | "verifying" | "succeeded" | "failed" | "cancelled";

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
  placement?: Record<string, unknown>;
  artifactIds: string[];
}

export interface JobResponse {
  job: JobSpec;
  run: RunPayload;
}
