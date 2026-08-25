import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  type CallToolRequest,
  type CallToolResult,
  type Tool,
} from "@modelcontextprotocol/sdk/types.js";
import { ControllerClient, ControllerRequestError } from "./controller-client.js";
import { optionalPlanId, parseJobDraft, parseJobId, rejectCredentialPayload } from "./validation.js";
import { MAX_SNAPSHOT_ARCHIVE_BYTES, packWorkspaceSnapshot, validateSnapshotDescriptor } from "./snapshot.js";
import { ControllerVerificationLoop, McpRuntimeReceipt } from "./runtime-receipt.js";

const jobSchema = {
  type: "object",
  additionalProperties: false,
  required: ["kind", "source", "steps"],
  properties: {
    apiVersion: { type: "string", const: "cyc.dev/v1" },
    id: { type: "string", description: "Optional UUID. The bridge creates one when omitted." },
    origin: {
      type: "object",
      additionalProperties: false,
      properties: {
        codexSessionId: { type: "string", maxLength: 256 },
        projectId: { type: "string", maxLength: 256 },
        workspaceId: { type: "string", maxLength: 256 },
      },
    },
    kind: { type: "string", enum: ["shell", "build", "test", "lint", "container", "gpu", "batch"] },
    source: {
      oneOf: [
        {
          type: "object",
          additionalProperties: false,
          required: ["type", "repository", "revision"],
          properties: {
            type: { const: "git" },
            repository: { type: "string", pattern: "^https://" },
            revision: { type: "string", pattern: "^(?:[a-f0-9]{40}|[a-f0-9]{64})$" },
          },
        },
        {
          type: "object",
          additionalProperties: false,
          required: ["type", "digest", "sizeBytes"],
          properties: {
            type: { const: "snapshot" },
            digest: { type: "string", pattern: "^sha256:[a-f0-9]{64}$" },
            sizeBytes: { type: "integer", minimum: 1, maximum: MAX_SNAPSHOT_ARCHIVE_BYTES },
          },
        },
      ],
    },
    requirements: {
      type: "object",
      additionalProperties: false,
      properties: {
        os: { type: "string", enum: ["windows", "linux", "macos"] },
        arch: { type: "string", enum: ["x86_64", "aarch64"] },
        capabilities: { type: "array", uniqueItems: true, items: { type: "string", minLength: 1 } },
        minCpuCores: { type: "integer", minimum: 1 },
        minMemoryMiB: { type: "integer", minimum: 1 },
        minDiskMiB: { type: "integer", minimum: 1 },
        gpu: {
          type: "object",
          additionalProperties: false,
          properties: {
            vendor: { type: "string", enum: ["nvidia", "amd", "intel", "apple"] },
            minVramMiB: { type: "integer", minimum: 1 },
            exclusive: { type: "boolean" },
          },
        },
      },
    },
    resourceRequest: {
      type: "object",
      additionalProperties: false,
      properties: {
        slots: { type: "integer", minimum: 1 },
        cpuCores: { type: "integer", minimum: 1 },
        memoryMiB: { type: "integer", minimum: 0 },
        diskMiB: { type: "integer", minimum: 0 },
        gpu: {
          type: "object",
          additionalProperties: false,
          properties: {
            deviceId: { type: "string", minLength: 1, maxLength: 256 },
            vendor: { type: "string", enum: ["nvidia", "amd", "intel", "apple"] },
            vramMiB: { type: "integer", minimum: 0 },
            exclusive: { type: "boolean" },
          },
        },
      },
    },
    steps: {
      type: "array",
      minItems: 1,
      items: {
        type: "object",
        additionalProperties: false,
        required: ["name", "script"],
        properties: {
          name: { type: "string", minLength: 1 },
          shell: { type: "string", enum: ["powershell", "bash", "zsh", "cmd"] },
          script: { type: "string", minLength: 1 },
          workingDirectory: { type: "string" },
          timeoutSeconds: { type: "integer", minimum: 1, maximum: 86400 },
        },
      },
    },
    artifacts: {
      type: "object",
      additionalProperties: false,
      properties: {
        include: { type: "array", items: { type: "string" } },
        exclude: { type: "array", items: { type: "string" } },
        retentionDays: { type: "integer", minimum: 1, maximum: 3650 },
      },
    },
    timeoutSeconds: { type: "integer", minimum: 1, maximum: 86400 },
    placementPolicy: { type: "string", enum: ["balanced", "performance", "manual"] },
    preferredNodeId: { type: "string" },
  },
} as const;

const tools: Tool[] = [
  {
    name: "fleet_info",
    title: "Inspect Codex compute fleet",
    description: "Read local controller health, connected computers, capabilities, current load, and recent delegated tasks. Call once before planning cluster work.",
    inputSchema: { type: "object", additionalProperties: false, properties: {} },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "fleet_plan",
    title: "Plan task placement",
    description: "Validate a versioned JobSpec and ask the local controller which eligible computer should run it, including placement reasons. This does not start the task.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["job"],
      properties: { job: jobSchema },
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "fleet_submit",
    title: "Submit delegated task",
    description: "Submit an exact JobSpec to the local controller, optionally binding it to a preceding placement plan. Returns a job id; starting is not success, so poll fleet_job.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["job"],
      properties: {
        job: jobSchema,
        planId: {
          type: "string",
          pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        },
      },
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  },
  {
    name: "fleet_plan_submit",
    title: "Plan and submit delegated task",
    description: "Validate one exact JobSpec, create a placement plan, verify that the plan is bound to the job id, and submit that unchanged job with the plan id in one call.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["job"],
      properties: { job: jobSchema },
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  },
  {
    name: "workspace_snapshot_pack",
    title: "Pack a safe workspace snapshot",
    description: "Pack committed and dirty workspace files into a deterministic tar.zst snapshot. Built-in deny rules always exclude common environment files, private keys, credentials, and build/cache trees; include and deny add selection rules.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["workspacePath"],
      properties: {
        workspacePath: { type: "string", minLength: 1, maxLength: 4096 },
        outputPath: { type: "string", minLength: 1, maxLength: 4096 },
        include: {
          type: "array",
          minItems: 1,
          maxItems: 256,
          uniqueItems: true,
          items: { type: "string", minLength: 1, maxLength: 1024 },
        },
        deny: {
          type: "array",
          maxItems: 256,
          uniqueItems: true,
          items: { type: "string", minLength: 1, maxLength: 1024 },
        },
      },
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "fleet_snapshot_upload",
    title: "Upload a verified workspace snapshot",
    description: "Re-hash an existing tar.zst archive, require its exact digest and bounded Content-Length, and upload it to the authenticated loopback controller. The controller response must echo the same digest, size, version, and format.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["archivePath", "digest", "sizeBytes"],
      properties: {
        archivePath: { type: "string", minLength: 1, maxLength: 4096 },
        digest: { type: "string", pattern: "^sha256:[a-f0-9]{64}$" },
        sizeBytes: { type: "integer", minimum: 1, maximum: MAX_SNAPSHOT_ARCHIVE_BYTES },
      },
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "fleet_job",
    title: "Inspect delegated task",
    description: "Read the current lifecycle state, native exit code, placement evidence, and returned artifact metadata for one delegated job.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["jobId"],
      properties: {
        jobId: {
          type: "string",
          pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        },
      },
    },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  {
    name: "fleet_cancel",
    title: "Cancel delegated task",
    description: "Request cancellation of one job owned by the current task. Poll fleet_job afterward until the controller reports a terminal state.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["jobId"],
      properties: {
        jobId: {
          type: "string",
          pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
        },
      },
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
  },
];

const controller = new ControllerClient();
const runtimeReceipt = new McpRuntimeReceipt();
let controllerVerification: ControllerVerificationLoop | undefined;

function startControllerVerificationWhenEligible(): void {
  if (!runtimeReceipt.controllerVerificationEligible()) return;
  controllerVerification ??= new ControllerVerificationLoop({
    enabled: true,
    // `fleet` is authenticated by the native controller token. Only a
    // successful response is allowed to advance controllerVerifiedAt.
    verify: () => controller.fleet(),
    onVerified: () => runtimeReceipt.noteControllerVerified(),
  });
  void controllerVerification.start();
}

const server = new Server(
  { name: "cluster-your-codex", version: "0.1.0-preview.9" },
  {
    capabilities: { tools: {} },
    instructions:
      "Use this server to plan and run meaningful Codex work on computers connected to the user's local ClusterYourCodex controller. Never place credentials in tool inputs.",
  },
);
server.oninitialized = () => {
  void runtimeReceipt.noteInitialized().then(startControllerVerificationWhenEligible);
};

function argumentsRecord(value: unknown): Record<string, unknown> {
  if (value === undefined) return {};
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("tool arguments must be an object");
  }
  const record = value as Record<string, unknown>;
  rejectCredentialPayload(record, "arguments");
  return record;
}

function assertArgumentKeys(args: Record<string, unknown>, allowed: readonly string[]): void {
  const allowedSet = new Set(allowed);
  const unknown = Object.keys(args).find((key) => !allowedSet.has(key));
  if (unknown !== undefined) throw new Error(`arguments.${unknown} is not supported`);
}

function success(value: unknown): CallToolResult {
  return {
    content: [{ type: "text", text: JSON.stringify(sanitizeToolOutput(value), null, 2) }],
  };
}

function failure(error: unknown): CallToolResult {
  const publicError =
    error instanceof ControllerRequestError
      ? {
          code: error.code ?? "controller_request_failed",
          message: error.message,
          ...(error.requestId ? { requestId: error.requestId } : {}),
          ...(error.placement ? { placement: error.placement } : {}),
        }
      : {
          code: "invalid_tool_input",
          message: error instanceof Error ? error.message : "ClusterYourCodex tool failed",
        };
  return {
    isError: true,
    content: [{ type: "text", text: JSON.stringify({ error: publicError }, null, 2) }],
  };
}

server.setRequestHandler(ListToolsRequestSchema, async () => {
  await runtimeReceipt.noteToolsListed();
  startControllerVerificationWhenEligible();
  return { tools };
});

const controllerBackedTools = new Set([
  "fleet_info",
  "fleet_plan",
  "fleet_submit",
  "fleet_plan_submit",
  "fleet_snapshot_upload",
  "fleet_job",
  "fleet_cancel",
]);

async function handleToolCall(request: CallToolRequest): Promise<CallToolResult> {
  try {
    const args = argumentsRecord(request.params.arguments);
    switch (request.params.name) {
      case "fleet_info": {
        assertArgumentKeys(args, []);
        const [health, fleet] = await Promise.all([controller.health(), controller.fleet()]);
        return success({ health, fleet });
      }
      case "fleet_plan": {
        assertArgumentKeys(args, ["job"]);
        const job = parseJobDraft(args.job);
        return success(await controller.plan(job));
      }
      case "fleet_submit": {
        assertArgumentKeys(args, ["job", "planId"]);
        const job = parseJobDraft(args.job);
        const planId = optionalPlanId(args.planId);
        return success(await controller.submit(job, planId));
      }
      case "fleet_plan_submit": {
        assertArgumentKeys(args, ["job"]);
        const job = parseJobDraft(args.job);
        return success(await controller.planAndSubmit(job));
      }
      case "workspace_snapshot_pack":
        assertArgumentKeys(args, ["workspacePath", "outputPath", "include", "deny"]);
        return success(await packWorkspaceSnapshot(parsePackWorkspaceArgs(args)));
      case "fleet_snapshot_upload": {
        assertArgumentKeys(args, ["archivePath", "digest", "sizeBytes"]);
        const upload = parseSnapshotUploadArgs(args);
        return success(await controller.uploadSnapshot(upload));
      }
      case "fleet_job":
        assertArgumentKeys(args, ["jobId"]);
        return success(await controller.job(parseJobId(args.jobId)));
      case "fleet_cancel":
        assertArgumentKeys(args, ["jobId"]);
        return success(await controller.cancel(parseJobId(args.jobId)));
      default:
        return failure(new Error(`Unknown ClusterYourCodex tool: ${request.params.name}`));
    }
  } catch (error) {
    return failure(error);
  }
}

server.setRequestHandler(CallToolRequestSchema, async (request): Promise<CallToolResult> => {
  const result = await handleToolCall(request);
  if (!result.isError && controllerBackedTools.has(request.params.name)) {
    await runtimeReceipt.noteControllerVerified();
  }
  return result;
});

function parsePackWorkspaceArgs(args: Record<string, unknown>): {
  workspacePath: string;
  outputPath?: string;
  include?: string[];
  deny?: string[];
} {
  const workspacePath = requiredString(args.workspacePath, "workspacePath", 4096);
  const outputPath = optionalString(args.outputPath, "outputPath", 4096);
  const include = optionalStringArray(args.include, "include", false);
  const deny = optionalStringArray(args.deny, "deny", true);
  return {
    workspacePath,
    ...(outputPath === undefined ? {} : { outputPath }),
    ...(include === undefined ? {} : { include }),
    ...(deny === undefined ? {} : { deny }),
  };
}

function parseSnapshotUploadArgs(args: Record<string, unknown>): {
  archivePath: string;
  digest: `sha256:${string}`;
  sizeBytes: number;
} {
  const archivePath = requiredString(args.archivePath, "archivePath", 4096);
  if (typeof args.digest !== "string") throw new Error("digest must be a string");
  if (typeof args.sizeBytes !== "number") throw new Error("sizeBytes must be a number");
  validateSnapshotDescriptor(args.digest, args.sizeBytes);
  return { archivePath, digest: args.digest, sizeBytes: args.sizeBytes };
}

function requiredString(value: unknown, name: string, maximum: number): string {
  if (typeof value !== "string" || value.trim().length === 0 || value.length > maximum) {
    throw new Error(`${name} must be a non-empty string no longer than ${maximum} characters`);
  }
  return value;
}

function optionalString(value: unknown, name: string, maximum: number): string | undefined {
  return value === undefined ? undefined : requiredString(value, name, maximum);
}

function optionalStringArray(value: unknown, name: string, emptyAllowed: boolean): string[] | undefined {
  if (value === undefined) return undefined;
  if (!Array.isArray(value) || value.length > 256 || (!emptyAllowed && value.length === 0)) {
    throw new Error(`${name} must be an array of ${emptyAllowed ? "zero to" : "one to"} 256 strings`);
  }
  return value.map((entry, index) => requiredString(entry, `${name}[${index}]`, 1024));
}

function sanitizeToolOutput(value: unknown, depth = 0): unknown {
  if (depth > 32) return "[truncated]";
  if (typeof value === "string") {
    return value.replace(/Bearer\s+[A-Za-z0-9._~+\/-]+=*/gi, "Bearer [redacted]");
  }
  if (Array.isArray(value)) return value.map((entry) => sanitizeToolOutput(entry, depth + 1));
  if (value === null || typeof value !== "object") return value;
  const result: Record<string, unknown> = {};
  for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
    if (/credential|password|passwd|private.?key|secret|authorization|token/i.test(key)) {
      result[key] = "[redacted]";
    } else {
      result[key] = sanitizeToolOutput(entry, depth + 1);
    }
  }
  return result;
}

async function main() {
  runtimeReceipt.registerProcessCleanup(() => controllerVerification?.stop());
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(() => {
  process.stderr.write("ClusterYourCodex MCP bridge failed to start.\n");
  process.exitCode = 1;
});
