import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { parseJobDraft } from "./validation.js";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../../../");

function resourceBoundJob() {
  return parseJobDraft({
    kind: "build",
    source: {
      type: "git",
      repository: "https://example.test/repo.git",
      revision: "0123456789abcdef0123456789abcdef01234567",
    },
    requirements: {
      minMemoryMiB: 8_192,
      minDiskMiB: 20_000,
      gpu: { vendor: "nvidia", minVramMiB: 6_144, exclusive: true },
    },
    resourceRequest: {
      slots: 1,
      cpuCores: 4,
      memoryMiB: 8_192,
      diskMiB: 20_000,
      gpu: { vendor: "nvidia", vramMiB: 6_144, exclusive: true },
    },
    steps: [{ name: "build", shell: "bash", script: "cargo build --locked" }],
  });
}

describe("JobSpec MiB wire contract", () => {
  it("writes canonical MiB spellings for every resource field", () => {
    const wire = JSON.parse(JSON.stringify(resourceBoundJob())) as Record<string, unknown>;
    const requirements = wire.requirements as Record<string, unknown>;
    const request = wire.resourceRequest as Record<string, unknown>;
    const requirementGpu = requirements.gpu as Record<string, unknown>;
    const requestGpu = request.gpu as Record<string, unknown>;

    expect(requirements).toMatchObject({ minMemoryMiB: 8_192, minDiskMiB: 20_000 });
    expect(requirements).not.toHaveProperty("minMemoryMib");
    expect(requirements).not.toHaveProperty("minDiskMib");
    expect(requirementGpu).toMatchObject({ minVramMiB: 6_144 });
    expect(requirementGpu).not.toHaveProperty("minVramMib");
    expect(request).toMatchObject({ memoryMiB: 8_192, diskMiB: 20_000 });
    expect(request).not.toHaveProperty("memoryMib");
    expect(request).not.toHaveProperty("diskMib");
    expect(requestGpu).toMatchObject({ vramMiB: 6_144 });
    expect(requestGpu).not.toHaveProperty("vramMib");
  });

  it("normalizes historical Mib spellings before sending a JobSpec", () => {
    const job = resourceBoundJob() as unknown as Record<string, unknown>;
    const requirements = { ...(job.requirements as Record<string, unknown>) };
    delete requirements.minMemoryMiB;
    requirements.minMemoryMib = 8_192;
    delete requirements.minDiskMiB;
    requirements.minDiskMib = 20_000;
    const requirementGpu = { ...(requirements.gpu as Record<string, unknown>) };
    delete requirementGpu.minVramMiB;
    requirementGpu.minVramMib = 6_144;
    requirements.gpu = requirementGpu;

    const resourceRequest = { ...(job.resourceRequest as Record<string, unknown>) };
    delete resourceRequest.memoryMiB;
    resourceRequest.memoryMib = 8_192;
    delete resourceRequest.diskMiB;
    resourceRequest.diskMib = 20_000;
    const requestGpu = { ...(resourceRequest.gpu as Record<string, unknown>) };
    delete requestGpu.vramMiB;
    requestGpu.vramMib = 6_144;
    resourceRequest.gpu = requestGpu;

    const parsed = parseJobDraft({ ...job, requirements, resourceRequest });
    const wire = JSON.parse(JSON.stringify(parsed)) as Record<string, unknown>;
    expect(wire.requirements).toMatchObject({ minMemoryMiB: 8_192, minDiskMiB: 20_000 });
    expect(wire.requirements).not.toHaveProperty("minMemoryMib");
    expect(wire.requirements).not.toHaveProperty("minDiskMib");
    expect((wire.requirements as Record<string, unknown>).gpu).toMatchObject({ minVramMiB: 6_144 });
    expect((wire.requirements as Record<string, unknown>).gpu).not.toHaveProperty("minVramMib");
    expect(wire.resourceRequest).toMatchObject({ memoryMiB: 8_192, diskMiB: 20_000 });
    expect(wire.resourceRequest).not.toHaveProperty("memoryMib");
    expect(wire.resourceRequest).not.toHaveProperty("diskMib");
    expect((wire.resourceRequest as Record<string, unknown>).gpu).toMatchObject({ vramMiB: 6_144 });
    expect((wire.resourceRequest as Record<string, unknown>).gpu).not.toHaveProperty("vramMib");
  });

  it("rejects a JobSpec that supplies canonical and historical spellings together", () => {
    const job = resourceBoundJob() as unknown as Record<string, unknown>;
    const requirements = {
      ...(job.requirements as Record<string, unknown>),
      minMemoryMib: 8_192,
    };
    expect(() => parseJobDraft({ ...job, requirements })).toThrow(/both minMemoryMiB and minMemoryMib/);

    const resourceRequest = {
      ...(job.resourceRequest as Record<string, unknown>),
      memoryMib: 8_192,
    };
    expect(() => parseJobDraft({ ...job, resourceRequest })).toThrow(/both memoryMiB and memoryMib/);
  });

  it("declares resourceRequest and all canonical fields in the public JSON schema", async () => {
    const schemaPath = resolve(repositoryRoot, "schemas/job-spec.schema.json");
    const schema = JSON.parse(await readFile(schemaPath, "utf8")) as {
      properties?: Record<string, unknown>;
    };
    const properties = schema.properties ?? {};
    const resourceRequest = properties.resourceRequest as {
      type?: string;
      additionalProperties?: boolean;
      properties?: Record<string, unknown>;
    } | undefined;

    expect(resourceRequest).toMatchObject({ type: "object", additionalProperties: false });
    expect(resourceRequest?.properties).toEqual(expect.objectContaining({
      memoryMiB: expect.objectContaining({ type: "integer", minimum: 0 }),
      diskMiB: expect.objectContaining({ type: "integer", minimum: 0 }),
      gpu: expect.objectContaining({
        properties: expect.objectContaining({
          vramMiB: expect.objectContaining({ type: "integer", minimum: 0 }),
        }),
      }),
    }));
    expect(properties.requirements).toEqual(expect.objectContaining({
      properties: expect.objectContaining({
        minMemoryMiB: expect.objectContaining({ type: "integer", minimum: 1 }),
        minDiskMiB: expect.objectContaining({ type: "integer", minimum: 1 }),
      }),
    }));
    const requirements = properties.requirements as { properties?: Record<string, unknown> };
    const requirementGpu = requirements.properties?.gpu as { properties?: Record<string, unknown> };
    expect(requirementGpu.properties).toEqual(expect.objectContaining({
      minVramMiB: expect.objectContaining({ type: "integer", minimum: 1 }),
    }));
  });
});
