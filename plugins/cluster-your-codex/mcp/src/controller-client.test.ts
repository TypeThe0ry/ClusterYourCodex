import { createHash } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ControllerClient, ControllerRequestError } from "./controller-client.js";
import { optionalPlanId, parseJobDraft, parseJobId, rejectCredentialPayload } from "./validation.js";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

describe("Codex controller bridge", () => {
  const testToken = "test-only-token-material-0123456789abcdef";
  const tokenSource = { getToken: vi.fn(async () => testToken) };

  it("loads bearer authorization for authenticated controller routes", async () => {
    const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(
        JSON.stringify({
          fleetRevision: 0,
          observedAt: "2026-08-23T01:00:00Z",
          controller: {},
          codex: {},
          nodes: [],
          recentJobs: [],
        }),
        { status: 200 },
      ),
    );
    const client = new ControllerClient({ fetchImpl, tokenSource });

    await client.fleet();

    const init = fetchImpl.mock.calls[0]?.[1];
    expect(new Headers(init?.headers).get("authorization")).toBe(`Bearer ${testToken}`);
  });

  it("rejects non-JavaScript-safe fleet revisions", async () => {
    const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(
        JSON.stringify({
          fleetRevision: Number.MAX_SAFE_INTEGER + 1,
          observedAt: "2026-08-23T01:00:00Z",
          controller: {},
          codex: {},
          nodes: [],
          recentJobs: [],
        }),
        { status: 200 },
      ),
    );
    const client = new ControllerClient({ fetchImpl, tokenSource });

    await expect(client.fleet()).rejects.toMatchObject({ code: "invalid_response" });
  });

  it("rejects fleet timestamps that JavaScript would normalize or parse without a timezone", async () => {
    for (const observedAt of [
      "2026-02-31T01:00:00Z",
      "2026-08-23T01:00:00.000",
      "2026-08-23T01:00:00z",
      "2026-08-23T01:00:00+24:00",
      "2026-08-23T01:00:00.1234567890Z",
    ]) {
      const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
        new Response(JSON.stringify({
          fleetRevision: 0,
          observedAt,
          controller: {},
          codex: {},
          nodes: [],
          recentJobs: [],
        }), { status: 200 }),
      );
      await expect(new ControllerClient({ fetchImpl, tokenSource }).fleet()).rejects.toMatchObject({
        code: "invalid_response",
      });
    }
  });

  it("keeps health public and does not load the token file", async () => {
    const healthTokenSource = { getToken: vi.fn(async () => testToken) };
    const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({ status: "ok", apiVersion: "cyc.dev/v1" }), { status: 200 }),
    );
    const client = new ControllerClient({ fetchImpl, tokenSource: healthTokenSource });

    await client.health();

    expect(healthTokenSource.getToken).not.toHaveBeenCalled();
    expect(new Headers(fetchImpl.mock.calls[0]?.[1]?.headers).has("authorization")).toBe(false);
  });

  it("sends every mutating request as application/json", async () => {
    const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({
        job: { id: "6ea73b30-ac48-4391-89d4-e55e76334b99" },
        run: {
          id: "607292ff-ebce-46a8-865f-ee55ee5794f7",
          jobId: "6ea73b30-ac48-4391-89d4-e55e76334b99",
        },
        planBinding: null,
        version: 0,
        cancelRequested: false,
      }), { status: 200 }),
    );
    const client = new ControllerClient({ fetchImpl, tokenSource });

    await client.cancel("6ea73b30-ac48-4391-89d4-e55e76334b99");

    const init = fetchImpl.mock.calls[0]?.[1];
    expect(new Headers(init?.headers).get("content-type")).toBe("application/json");
    expect(init?.body).toBe("{}");
  });

  it("does not echo controller response bodies in errors", async () => {
    const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({ privateKey: "must-not-leak" }), { status: 500 }),
    );
    const client = new ControllerClient({ fetchImpl });

    const error = await client.health().catch((caught: unknown) => caught);
    expect(error).toBeInstanceOf(ControllerRequestError);
    expect(String(error)).not.toContain("must-not-leak");
  });

  it("preserves only structured placement evidence from controller errors", async () => {
    const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(
        JSON.stringify({
          error: {
            code: "no_eligible_node",
            message: "untrusted body message",
            placement: {
              policy: "performance",
              candidates: [
                {
                  nodeId: "0cb8d4c4-ef55-4c14-8821-014815489a16",
                  nodeName: "Linux builder",
                  eligible: false,
                  scoreComponents: [],
                  rejectionReasons: [{ code: "wrong_os", detail: "requires windows" }],
                  credentialRef: "must-not-leak",
                },
              ],
            },
          },
        }),
        { status: 409 },
      ),
    );
    const client = new ControllerClient({ fetchImpl, tokenSource });

    const error = await client.fleet().catch((caught: unknown) => caught);

    expect(error).toBeInstanceOf(ControllerRequestError);
    expect((error as ControllerRequestError).code).toBe("no_eligible_node");
    expect((error as ControllerRequestError).placement?.candidates[0]?.nodeName).toBe("Linux builder");
    expect(JSON.stringify(error)).not.toContain("must-not-leak");
    expect(String(error)).not.toContain("untrusted body message");
  });

  it("uploads exact digest-bound bytes with authentication, Content-Length, and strict receipt validation", async () => {
    const fixture = await snapshotFixture();
    const fetchImpl = vi.fn<typeof fetch>().mockImplementation(async (_input, init) => {
      const headers = new Headers(init?.headers);
      expect(init?.method).toBe("PUT");
      expect(headers.get("authorization")).toBe(`Bearer ${testToken}`);
      expect(headers.get("content-type")).toBe("application/vnd.cyc.snapshot.tar+zstd");
      expect(headers.get("content-length")).toBe(String(fixture.bytes.length));
      expect(Buffer.from(init?.body as ArrayBuffer)).toEqual(fixture.bytes);
      return new Response(
        JSON.stringify({
          apiVersion: "cyc.dev/snapshot/v1",
          format: "tar+zstd",
          digest: fixture.digest,
          sizeBytes: fixture.bytes.length,
          createdAt: "2026-08-23T00:00:00Z",
        }),
        {
          status: 201,
          headers: {
            etag: `"${fixture.digest}"`,
            "x-cyc-snapshot-size": String(fixture.bytes.length),
            "x-cyc-snapshot-version": "cyc.dev/snapshot/v1",
            "x-cyc-snapshot-format": "tar+zstd",
          },
        },
      );
    });
    const client = new ControllerClient({ fetchImpl, tokenSource });

    const metadata = await client.uploadSnapshot({
      archivePath: fixture.path,
      digest: fixture.digest,
      sizeBytes: fixture.bytes.length,
    });

    expect(metadata.digest).toBe(fixture.digest);
    expect(String(fetchImpl.mock.calls[0]?.[0])).toContain(fixture.digest.slice("sha256:".length));
    expect(JSON.stringify(metadata)).not.toContain(testToken);
  });

  it("sanitizes snapshot HTTP failures and enforces upload timeout", async () => {
    const fixture = await snapshotFixture();
    const failingFetch = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({ error: { code: "invalid_snapshot", secret: "must-not-leak" } }), {
        status: 422,
      }),
    );
    const failing = new ControllerClient({ fetchImpl: failingFetch, tokenSource });
    const failed = await failing
      .uploadSnapshot({ archivePath: fixture.path, digest: fixture.digest, sizeBytes: fixture.bytes.length })
      .catch((error: unknown) => error);
    expect(failed).toBeInstanceOf(ControllerRequestError);
    expect(String(failed)).not.toContain("must-not-leak");
    expect(String(failed)).not.toContain(testToken);

    const hangingFetch = vi.fn<typeof fetch>().mockImplementation(
      async (_input, init) =>
        await new Promise<Response>((_resolve, reject) => {
          init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")), {
            once: true,
          });
        }),
    );
    const timingOut = new ControllerClient({ fetchImpl: hangingFetch, tokenSource, timeoutMs: 5 });
    await expect(
      timingOut.uploadSnapshot({ archivePath: fixture.path, digest: fixture.digest, sizeBytes: fixture.bytes.length }),
    ).rejects.toThrow(/timed out during PUT/);
  });

  it("plans and submits the unchanged job with the returned plan id", async () => {
    const job = parseJobDraft({
      kind: "test",
      source: {
        type: "snapshot",
        digest: `sha256:${"a".repeat(64)}`,
        sizeBytes: 42,
      },
      steps: [{ name: "test", shell: "bash", script: "pnpm test" }],
    });
    const plan = {
      apiVersion: "cyc.dev/placement-plan-binding/v1",
      planId: "65fa1374-3954-4a3c-9cc6-08745ab18be4",
      jobId: job.id,
      jobDigest: "9".repeat(64),
      createdAt: "2026-08-23T00:00:00Z",
      expiresAt: "2026-08-23T00:01:00Z",
      fleetRevision: 7,
      nodeRevision: 2,
      policyRevision: 3,
      decision: {
        nodeId: "813c91ba-843d-4c74-ac85-d28060b9f3c4",
        score: 1,
        explanation: {
          policy: "balanced",
          selectedNodeId: "813c91ba-843d-4c74-ac85-d28060b9f3c4",
          candidates: [{
            nodeId: "813c91ba-843d-4c74-ac85-d28060b9f3c4",
            nodeName: "P1",
            eligible: true,
            score: 1,
            scoreComponents: [{ key: "priority", value: 1, detail: "configured priority" }],
            rejectionReasons: [],
          }],
        },
      },
    };
    // Deliberately reverse top-level key order: semantic binding equality must
    // not depend on JSON object insertion order.
    const retainedPlan = {
      decision: plan.decision,
      policyRevision: plan.policyRevision,
      nodeRevision: plan.nodeRevision,
      fleetRevision: plan.fleetRevision,
      expiresAt: plan.expiresAt,
      createdAt: plan.createdAt,
      jobDigest: plan.jobDigest,
      jobId: plan.jobId,
      planId: plan.planId,
      apiVersion: plan.apiVersion,
    };
    const requests: Array<{ url: string; body: Record<string, unknown> }> = [];
    const fetchImpl = vi.fn<typeof fetch>().mockImplementation(async (input, init) => {
      const body = JSON.parse(String(init?.body)) as Record<string, unknown>;
      requests.push({ url: String(input), body });
      if (String(input).endsWith("/v1/plans")) {
        return new Response(JSON.stringify(plan), { status: 200 });
      }
      return new Response(
        JSON.stringify({
          job,
          run: {
            id: "607292ff-ebce-46a8-865f-ee55ee5794f7",
            jobId: job.id,
            nodeId: plan.decision.nodeId,
            state: "queued",
            createdAt: "2026-08-23T00:00:00Z",
            artifactIds: [],
          },
          planBinding: retainedPlan,
          version: 0,
          cancelRequested: false,
        }),
        { status: 200 },
      );
    });
    const client = new ControllerClient({ fetchImpl, tokenSource });

    const result = await client.planAndSubmit(job);

    expect(result.plan.planId).toBe(plan.planId);
    expect(requests).toHaveLength(2);
    expect(requests[0]?.body).toEqual({ job });
    expect(requests[1]?.body).toEqual({ job, planId: plan.planId });
  });

  it("rejects unsafe or extensible placement binding wire documents", async () => {
    const job = parseJobDraft({
      kind: "test",
      source: { type: "snapshot", digest: `sha256:${"a".repeat(64)}`, sizeBytes: 42 },
      steps: [{ name: "test", shell: "bash", script: "true" }],
    });
    const base = {
      apiVersion: "cyc.dev/placement-plan-binding/v1",
      planId: "65fa1374-3954-4a3c-9cc6-08745ab18be4",
      jobId: job.id,
      jobDigest: "9".repeat(64),
      createdAt: "2026-08-23T00:00:00Z",
      expiresAt: "2026-08-23T00:01:00Z",
      fleetRevision: 1,
      nodeRevision: 1,
      policyRevision: 3,
      decision: {
        nodeId: "813c91ba-843d-4c74-ac85-d28060b9f3c4",
        score: 1,
        explanation: {
          policy: "balanced",
          selectedNodeId: "813c91ba-843d-4c74-ac85-d28060b9f3c4",
          candidates: [{
            nodeId: "813c91ba-843d-4c74-ac85-d28060b9f3c4",
            nodeName: "P1",
            eligible: true,
            score: 1,
            scoreComponents: [{ key: "priority", value: 1, detail: "configured priority" }],
            rejectionReasons: [],
          }],
        },
      },
    };
    const selected = base.decision.explanation.candidates[0]!;
    for (const body of [
      { ...base, fleetRevision: Number.MAX_SAFE_INTEGER + 1 },
      { ...base, createdAt: "2026-02-31T00:00:00Z" },
      { ...base, createdAt: "2026-08-23T00:00:00.000" },
      {
        ...base,
        createdAt: "2026-08-23T00:00:00.000000002Z",
        expiresAt: "2026-08-23T00:00:00.000000001Z",
      },
      { ...base, mutableDecision: true },
      { ...base, decision: { ...base.decision, explanation: {
        ...base.decision.explanation,
        candidates: [{ ...selected, scoreComponents: [{ ...selected.scoreComponents[0]!, value: 2 }] }],
      } } },
      { ...base, decision: { ...base.decision, explanation: {
        ...base.decision.explanation,
        candidates: [selected, selected],
      } } },
      { ...base, decision: { ...base.decision, explanation: {
        ...base.decision.explanation,
        candidates: [{ ...selected, nodeName: "P1\nspoof" }],
      } } },
      { ...base, decision: { ...base.decision, explanation: {
        ...base.decision.explanation,
        candidates: [{ ...selected, scoreComponents: [
          { key: "same", value: 0, detail: "first" },
          { key: "same", value: 1, detail: "second" },
        ] }],
      } } },
      { ...base, decision: { ...base.decision, explanation: {
        ...base.decision.explanation,
        candidates: [selected, {
          nodeId: "0cb8d4c4-ef55-4c14-8821-014815489a16",
          nodeName: "offline",
          eligible: false,
          scoreComponents: [],
          rejectionReasons: [
            { code: "offline", detail: "first" },
            { code: "offline", detail: "duplicate" },
          ],
        }],
      } } },
    ]) {
      const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
        new Response(JSON.stringify(body), { status: 200 }),
      );
      await expect(new ControllerClient({ fetchImpl, tokenSource }).plan(job)).rejects.toMatchObject({
        code: "invalid_response",
      });
    }
  });
});

describe("JobSpec validation", () => {
  const baseJob = {
    kind: "build",
    source: {
      type: "git",
      repository: "https://example.test/repo.git",
      revision: "0123456789abcdef0123456789abcdef01234567",
    },
    steps: [{ name: "build", shell: "bash", script: "make" }],
  };

  it("adds the protocol version and a unique id", () => {
    const parsed = parseJobDraft(baseJob);
    expect(parsed.apiVersion).toBe("cyc.dev/v1");
    expect(parsed.id).toMatch(/^[0-9a-f-]{36}$/);
  });

  it("requires UUID identifiers at the MCP route boundary", () => {
    const id = "6ea73b30-ac48-4391-89d4-e55e76334b99";
    expect(parseJobId(id)).toBe(id);
    expect(optionalPlanId(id)).toBe(id);
    expect(optionalPlanId(undefined)).toBeUndefined();
    expect(() => parseJobId("../jobs")).toThrow(/UUID/);
    expect(() => optionalPlanId("plan-1")).toThrow(/UUID/);
  });

  it("rejects credential-bearing fields before they reach the controller", () => {
    expect(() => parseJobDraft({ ...baseJob, credentials: { password: "unsafe" } })).toThrow(
      /Credential-bearing field/,
    );
    expect(() =>
      rejectCredentialPayload({ workspacePath: "C:/repo", nested: [{ authorization: "Bearer unsafe" }] }),
    ).toThrow(/Credential-bearing field/);
  });

  it("requires an immutable Git object and a credential-free HTTPS repository", () => {
    expect(() =>
      parseJobDraft({
        ...baseJob,
        source: { ...baseJob.source, revision: "main" },
      }),
    ).toThrow(/complete lowercase Git object ID/);
    expect(() =>
      parseJobDraft({
        ...baseJob,
        source: { ...baseJob.source, repository: "https://user:secret@example.test/repo.git" },
      }),
    ).toThrow(/public HTTPS URL/);
  });

  it("rejects non-public repository hosts and unknown wire fields", () => {
    for (const repository of [
      "https://localhost/repo.git",
      "https://builder.local/repo.git",
      "https://10.0.0.8/repo.git",
      "https://192.168.1.8/repo.git",
      "https://[::1]/repo.git",
      "https://[::ffff:c0a8:0101]/repo.git",
    ]) {
      expect(() =>
        parseJobDraft({ ...baseJob, source: { ...baseJob.source, repository } }),
      ).toThrow(/host must be public/);
    }
    expect(() => parseJobDraft({ ...baseJob, apiVersion: "cyc.dev/v2" })).toThrow(/apiVersion/);
    expect(() => parseJobDraft({ ...baseJob, unsupportedField: true })).toThrow(/unsupportedField/);
    expect(() => parseJobDraft({ ...baseJob, source: { ...baseJob.source, branch: "main" } })).toThrow(
      /branch/,
    );
  });

  it("validates requirements, steps, artifacts, identifiers, and bounded timeouts", () => {
    expect(() => parseJobDraft({ ...baseJob, id: "not-a-uuid" })).toThrow(/job.id/);
    expect(() => parseJobDraft({ ...baseJob, requirements: { minCpuCores: 0 } })).toThrow(/minCpuCores/);
    expect(() => parseJobDraft({ ...baseJob, requirements: { capabilities: [" "] } })).toThrow(
      /capabilities/,
    );
    expect(() => parseJobDraft({ ...baseJob, steps: [{ name: "build", shell: "fish", script: "make" }] })).toThrow(
      /shell/,
    );
    expect(() =>
      parseJobDraft({ ...baseJob, steps: [{ name: "build", script: "make", workingDirectory: "../escape" }] }),
    ).toThrow(/workingDirectory/);
    expect(() => parseJobDraft({ ...baseJob, timeoutSeconds: 86_401 })).toThrow(/timeoutSeconds/);
    expect(() => parseJobDraft({ ...baseJob, artifacts: { include: [".git/config"] } })).toThrow(/\.git/);
    expect(() => parseJobDraft({ ...baseJob, artifacts: { exclude: ["target/**"] } })).toThrow(/exclude/);
  });

  it("requires snapshot sizeBytes in the strict 1 through 64 MiB range", () => {
    const snapshot = {
      ...baseJob,
      source: { type: "snapshot", digest: `sha256:${"a".repeat(64)}` },
    };
    expect(() => parseJobDraft(snapshot)).toThrow(/sizeBytes/);
    expect(() => parseJobDraft({ ...snapshot, source: { ...snapshot.source, sizeBytes: 0 } })).toThrow(/sizeBytes/);
    expect(() =>
      parseJobDraft({ ...snapshot, source: { ...snapshot.source, sizeBytes: 64 * 1024 * 1024 + 1 } }),
    ).toThrow(/sizeBytes/);
    expect(parseJobDraft({ ...snapshot, source: { ...snapshot.source, sizeBytes: 1 } }).source).toMatchObject({
      sizeBytes: 1,
    });
  });

  it("preserves legacy jobs without materializing resourceRequest", () => {
    const parsed = parseJobDraft({
      ...baseJob,
      requirements: { minCpuCores: 4, minMemoryMiB: 2048 },
    });
    expect(parsed).not.toHaveProperty("resourceRequest");
  });

  it("accepts an explicit atomically reservable resource request", () => {
    const resourceRequest = {
      slots: 1,
      cpuCores: 8,
      memoryMiB: 16_384,
      diskMiB: 40_960,
      gpu: { deviceId: "GPU-4070", vendor: "nvidia", vramMiB: 6_144, exclusive: true },
    } as const;
    const parsed = parseJobDraft({
      ...baseJob,
      requirements: {
        minCpuCores: 4,
        minMemoryMiB: 8_192,
        gpu: { vendor: "nvidia", minVramMiB: 4_096, exclusive: true },
      },
      resourceRequest,
    });
    expect(parsed.resourceRequest).toEqual(resourceRequest);
  });

  it("rejects invalid or legacy-weakening resource reservations", () => {
    expect(() => parseJobDraft({ ...baseJob, resourceRequest: { slots: 0 } })).toThrow(/slots/);
    expect(() =>
      parseJobDraft({
        ...baseJob,
        requirements: { minCpuCores: 8, minMemoryMiB: 4096 },
        resourceRequest: { cpuCores: 4, memoryMiB: 2048 },
      }),
    ).toThrow(/must not weaken/);
    expect(() =>
      parseJobDraft({
        ...baseJob,
        requirements: { gpu: { vendor: "nvidia", minVramMiB: 4096, exclusive: true } },
        resourceRequest: { gpu: { vendor: "amd", vramMiB: 8192, exclusive: false } },
      }),
    ).toThrow(/must not conflict/);
    expect(() =>
      parseJobDraft({
        ...baseJob,
        resourceRequest: { cpuCores: 1, unsupportedField: 1 },
      }),
    ).toThrow(/unsupportedField/);
    expect(() =>
      parseJobDraft({
        ...baseJob,
        requirements: { gpu: { vendor: "nvidia" } },
        resourceRequest: { gpu: { vramMiB: 8192 } },
      }),
    ).toThrow(/must not conflict/);
  });
});

async function snapshotFixture(): Promise<{ path: string; bytes: Buffer; digest: `sha256:${string}` }> {
  const directory = await mkdtemp(join(tmpdir(), "cyc-mcp-upload-"));
  temporaryDirectories.push(directory);
  const path = join(directory, "fixture.tar.zst");
  const bytes = Buffer.from("bounded snapshot fixture");
  const digest = `sha256:${createHash("sha256").update(bytes).digest("hex")}` as const;
  await writeFile(path, bytes);
  return { path, bytes, digest };
}
