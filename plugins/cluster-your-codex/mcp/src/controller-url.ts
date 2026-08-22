export function assertLoopbackControllerUrl(value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error("Controller URL must be loopback HTTP(S)");
  }
  const hostname = url.hostname.replace(/^\[|\]$/g, "").toLowerCase();
  const ipv4 = hostname.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  const isLoopbackIpv4 = Boolean(
    ipv4 && ipv4.slice(1).every((part) => Number(part) <= 255) && Number(ipv4[1]) === 127,
  );
  if (
    !["http:", "https:"].includes(url.protocol) ||
    !(hostname === "localhost" || hostname === "::1" || isLoopbackIpv4) ||
    url.username ||
    url.password ||
    (url.pathname !== "/" && url.pathname !== "") ||
    url.search ||
    url.hash
  ) {
    throw new Error("Controller URL must be loopback HTTP(S)");
  }
  return url.origin;
}
