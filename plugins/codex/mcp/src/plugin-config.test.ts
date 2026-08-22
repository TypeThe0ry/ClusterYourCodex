import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";

describe("Codex MCP configuration", () => {
  it("passes through only a token-file path variable, never a raw token", async () => {
    const configUrl = new URL("../../.mcp.json", import.meta.url);
    const config = JSON.parse(await readFile(configUrl, "utf8")) as {
      mcpServers: Record<string, { env_vars?: string[]; env?: Record<string, string> }>;
    };
    const server = config.mcpServers.cluster_your_codex;

    expect(server?.env_vars).toEqual(["CYC_CONTROLLER_TOKEN_FILE"]);
    expect(server?.env).toBeUndefined();
    expect(JSON.stringify(config)).not.toContain("Authorization");
    expect(JSON.stringify(config)).not.toContain("Bearer ");
  });
});
