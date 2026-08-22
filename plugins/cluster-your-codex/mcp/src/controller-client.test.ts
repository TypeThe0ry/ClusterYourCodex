import { describe, expect, it, vi } from "vitest";
import { ControllerClient, ControllerRequestError } from "./controller-client.js";
import { parseJobDraft } from "./validation.js";

describe("Codex controller bridge", () => {
  const testToken = "test-only-token-material-0123456789abcdef";
  const tokenSource = { getToken: vi.fn(async () => testToken) };

  it("loads bearer authorization for authenticated controller routes", async () => {
    const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({ controller: {}, codex: {}, nodes: [] }), { status: 200 }),
    );
    const client = new ControllerClient({ fetchImpl, tokenSource });

    await client.fleet();

    const init = fetchImpl.mock.calls[0]?.[1];
    expect(new Headers(init?.headers).get("authorization")).toBe(`Bearer ${testToken}`);
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
      new Response(JSON.stringify({ job: {}, run: {} }), { status: 200 }),
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

  it("rejects credential-bearing fields before they reach the controller", () => {
    expect(() => parseJobDraft({ ...baseJob, credentials: { password: "unsafe" } })).toThrow(
      /Credential-bearing field/,
    );
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
});
