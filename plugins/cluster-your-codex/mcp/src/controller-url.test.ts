import { describe, expect, it } from "vitest";
import { assertLoopbackControllerUrl } from "./controller-url.js";

describe("controller URL boundary", () => {
  it.each([
    ["http://127.0.0.1:47831", "http://127.0.0.1:47831"],
    ["https://localhost:8443", "https://localhost:8443"],
    ["http://127.99.1.2:9000", "http://127.99.1.2:9000"],
    ["http://[::1]:47831", "http://[::1]:47831"],
  ])("accepts loopback HTTP(S): %s", (input, expected) => {
    expect(assertLoopbackControllerUrl(input)).toBe(expected);
  });

  it.each([
    "http://controller.example.test:47831",
    "https://example.com",
    "ftp://127.0.0.1/file",
    "http://user:password@127.0.0.1:47831",
    "http://127.0.0.1:47831/v1",
    "http://localhost.evil.test:47831",
  ])("rejects non-loopback or credential-bearing URLs: %s", (input) => {
    expect(() => assertLoopbackControllerUrl(input)).toThrow("Controller URL must be loopback HTTP(S)");
  });
});
