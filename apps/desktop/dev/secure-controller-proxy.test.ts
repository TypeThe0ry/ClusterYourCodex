import { describe, expect, it } from "vitest";
import { assertLoopbackControllerUrl } from "./secure-controller-proxy";

describe("secure Vite controller proxy", () => {
  it.each([
    ["http://127.0.0.1:47831", "http://127.0.0.1:47831"],
    ["https://localhost:47831", "https://localhost:47831"],
    ["http://127.42.7.9:9000", "http://127.42.7.9:9000"],
    ["http://[::1]:47831", "http://[::1]:47831"],
  ])("accepts loopback HTTP(S): %s", (input, expected) => {
    expect(assertLoopbackControllerUrl(input)).toBe(expected);
  });

  it.each([
    "http://192.168.1.10:47831",
    "https://example.com",
    "ftp://127.0.0.1/file",
    "http://user:password@127.0.0.1:47831",
    "http://127.0.0.1:47831/v1",
    "http://localhost.evil.test:47831",
  ])("rejects non-loopback or credential-bearing controller URLs: %s", (input) => {
    expect(() => assertLoopbackControllerUrl(input)).toThrow(/loopback HTTP/);
  });
});
