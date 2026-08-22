import { randomUUID } from "node:crypto";
import type { JobDraft, JobKind, JobSpec } from "./types.js";

const kinds = new Set<JobKind>(["shell", "build", "test", "lint", "container", "gpu", "batch"]);
const forbiddenKeys = /^(credential|credentials|password|passwd|privatekey|private_key|secret|secrets|token|tokens)$/i;

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function rejectCredentialFields(value: unknown, path = "job"): void {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => rejectCredentialFields(entry, `${path}[${index}]`));
    return;
  }
  if (!isRecord(value)) return;

  for (const [key, entry] of Object.entries(value)) {
    if (forbiddenKeys.test(key)) {
      throw new Error(`Credential-bearing field is not allowed in MCP payloads: ${path}.${key}`);
    }
    rejectCredentialFields(entry, `${path}.${key}`);
  }
}

export function parseJobDraft(value: unknown): JobSpec {
  if (!isRecord(value)) throw new Error("job must be an object");
  rejectCredentialFields(value);

  const draft = value as unknown as JobDraft;
  if (!kinds.has(draft.kind)) throw new Error("job.kind is invalid");
  if (!isRecord(draft.source) || (draft.source.type !== "git" && draft.source.type !== "snapshot")) {
    throw new Error("job.source must be a git revision or snapshot digest");
  }
  if (!Array.isArray(draft.steps) || draft.steps.length === 0) {
    throw new Error("job.steps must contain at least one executable step");
  }
  for (const [index, step] of draft.steps.entries()) {
    if (!isRecord(step) || typeof step.name !== "string" || typeof step.script !== "string" || !step.name || !step.script) {
      throw new Error(`job.steps[${index}] requires non-empty name and script fields`);
    }
  }

  return {
    ...draft,
    apiVersion: "cyc.dev/v1",
    id: typeof draft.id === "string" && draft.id.length > 0 ? draft.id : randomUUID(),
  };
}

export function parseJobId(value: unknown): string {
  if (typeof value !== "string" || value.trim().length === 0 || value.length > 256) {
    throw new Error("jobId must be a non-empty string no longer than 256 characters");
  }
  return value;
}

export function optionalPlanId(value: unknown): string | undefined {
  if (value === undefined) return undefined;
  if (typeof value !== "string" || value.trim().length === 0 || value.length > 256) {
    throw new Error("planId must be a non-empty string no longer than 256 characters");
  }
  return value;
}
