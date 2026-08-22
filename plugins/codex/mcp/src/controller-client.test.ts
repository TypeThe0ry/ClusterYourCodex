import { describe, expect, it, vi } from "vitest";
import { ControllerClient, ControllerRequestError } from "./controller-client.js";
import { parseJobDraft } from "./validation.js";

describe("Codex controller bridge", () => {
  it("sends no authorization or credential headers", async () => {
    const fetchImpl = vi.fn<typeof fetch>().mockResolvedValue(
      new Response(JSON.stringify({ controller: {}, codex: {}, nodes: [] }), { status: 200 }),
    );
    const client = new ControllerClient({ fetchImpl });

    await client.fleet();

    const init = fetchImpl.mock.calls[0]?.[1];
    expect(init?.headers).toBeUndefined();
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
});

describe("JobSpec validation", () => {
  const baseJob = {
    kind: "build",
    source: { type: "git", repository: "https://example.test/repo.git", revision: "0123456789abcdef" },
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
});
