import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { FileBearerTokenSource, resolveControllerTokenFile, TokenSourceError } from "./token-source.js";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true, force: true })));
});

describe("controller token source", () => {
  it("resolves platform defaults and the bridge-specific override", () => {
    expect(resolveControllerTokenFile({ LOCALAPPDATA: "C:\\Local" }, "win32", "C:\\Users\\test")).toBe(
      path.join("C:\\Local", "ClusterYourCodex", "controller.token"),
    );
    expect(resolveControllerTokenFile({ XDG_DATA_HOME: "/data" }, "linux", "/home/test")).toBe(
      "/data/clusteryourcodex/controller.token",
    );
    expect(resolveControllerTokenFile({}, "darwin", "/Users/test")).toBe(
      "/Users/test/Library/Application Support/ClusterYourCodex/controller.token",
    );
    expect(
      resolveControllerTokenFile({ CYC_CONTROLLER_TOKEN_FILE: "/custom/controller.token" }, "linux", "/home/test"),
    ).toBe("/custom/controller.token");
  });

  it("reads and trims a token without exposing the file path", async () => {
    const directory = await mkdtemp(path.join(tmpdir(), "cyc-token-"));
    temporaryDirectories.push(directory);
    const tokenFile = path.join(directory, "controller.token");
    const token = "test-only-token-material-0123456789abcdef";
    await writeFile(tokenFile, `${token}\n`, "utf8");

    await expect(new FileBearerTokenSource(tokenFile).getToken()).resolves.toBe(token);
  });

  it("returns a fixed redacted error when the token file is unavailable", async () => {
    const tokenFile = path.join(tmpdir(), "missing-cyc-token", "sensitive-name.token");
    const error = await new FileBearerTokenSource(tokenFile).getToken().catch((caught: unknown) => caught);

    expect(error).toBeInstanceOf(TokenSourceError);
    expect(String(error)).toBe("TokenSourceError: Controller token file is unavailable");
    expect(String(error)).not.toContain(tokenFile);
  });
});
