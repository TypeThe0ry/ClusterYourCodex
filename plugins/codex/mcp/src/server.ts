import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  type CallToolResult,
  type Tool,
} from "@modelcontextprotocol/sdk/types.js";
import { ControllerClient, ControllerRequestError } from "./controller-client.js";
import { optionalPlanId, parseJobDraft, parseJobId } from "./validation.js";

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
            repository: { type: "string", minLength: 1 },
            revision: { type: "string", minLength: 7 },
          },
        },
        {
          type: "object",
          additionalProperties: false,
          required: ["type", "digest"],
          properties: {
            type: { const: "snapshot" },
            digest: { type: "string", pattern: "^sha256:[a-f0-9]{64}$" },
            sizeBytes: { type: "integer", minimum: 0 },
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
        planId: { type: "string", minLength: 1, maxLength: 256 },
      },
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  },
  {
    name: "fleet_job",
    title: "Inspect delegated task",
    description: "Read the current lifecycle state, native exit code, placement evidence, and returned artifact metadata for one delegated job.",
    inputSchema: {
      type: "object",
      additionalProperties: false,
      required: ["jobId"],
      properties: { jobId: { type: "string", minLength: 1, maxLength: 256 } },
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
      properties: { jobId: { type: "string", minLength: 1, maxLength: 256 } },
    },
    annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
  },
];

const controller = new ControllerClient();
const server = new Server(
  { name: "cluster-your-codex", version: "0.1.0" },
  {
    capabilities: { tools: {} },
    instructions:
      "Use this server to plan and run meaningful Codex work on computers connected to the user's local ClusterYourCodex controller. Never place credentials in tool inputs.",
  },
);

function argumentsRecord(value: unknown): Record<string, unknown> {
  if (value === undefined) return {};
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("tool arguments must be an object");
  }
  return value as Record<string, unknown>;
}

function success(value: unknown): CallToolResult {
  return {
    content: [{ type: "text", text: JSON.stringify(value, null, 2) }],
  };
}

function failure(error: unknown): CallToolResult {
  const message =
    error instanceof ControllerRequestError || error instanceof Error
      ? error.message
      : "ClusterYourCodex tool failed";
  return {
    isError: true,
    content: [{ type: "text", text: message }],
  };
}

server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools }));

server.setRequestHandler(CallToolRequestSchema, async (request): Promise<CallToolResult> => {
  try {
    const args = argumentsRecord(request.params.arguments);
    switch (request.params.name) {
      case "fleet_info": {
        const [health, fleet] = await Promise.all([controller.health(), controller.fleet()]);
        return success({ health, fleet });
      }
      case "fleet_plan": {
        const job = parseJobDraft(args.job);
        return success(await controller.plan(job));
      }
      case "fleet_submit": {
        const job = parseJobDraft(args.job);
        const planId = optionalPlanId(args.planId);
        return success(await controller.submit(job, planId));
      }
      case "fleet_job":
        return success(await controller.job(parseJobId(args.jobId)));
      case "fleet_cancel":
        return success(await controller.cancel(parseJobId(args.jobId)));
      default:
        return failure(new Error(`Unknown ClusterYourCodex tool: ${request.params.name}`));
    }
  } catch (error) {
    return failure(error);
  }
});

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch(() => {
  process.stderr.write("ClusterYourCodex MCP bridge failed to start.\n");
  process.exitCode = 1;
});
