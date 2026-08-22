import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";

export interface BearerTokenSource {
  getToken(): Promise<string>;
}

export class TokenSourceError extends Error {
  readonly code: "token_unavailable" | "token_invalid";

  constructor(code: "token_unavailable" | "token_invalid", message: string) {
    super(message);
    this.name = "TokenSourceError";
    this.code = code;
  }
}

export interface TokenPathEnvironment {
  CYC_CONTROLLER_TOKEN_FILE?: string;
  LOCALAPPDATA?: string;
  XDG_DATA_HOME?: string;
  HOME?: string;
  USERPROFILE?: string;
}

export function resolveControllerTokenFile(
  environment: TokenPathEnvironment = process.env,
  platform: NodeJS.Platform = process.platform,
  homeDirectory = homedir(),
): string {
  const pathApi = platform === "win32" ? path.win32 : path.posix;
  if (environment.CYC_CONTROLLER_TOKEN_FILE?.trim()) {
    return pathApi.resolve(environment.CYC_CONTROLLER_TOKEN_FILE.trim());
  }

  if (platform === "win32") {
    const localAppData = environment.LOCALAPPDATA?.trim() || pathApi.join(homeDirectory, "AppData", "Local");
    return pathApi.join(localAppData, "ClusterYourCodex", "controller.token");
  }
  if (platform === "darwin") {
    return pathApi.join(homeDirectory, "Library", "Application Support", "ClusterYourCodex", "controller.token");
  }

  const dataHome = environment.XDG_DATA_HOME?.trim() || pathApi.join(homeDirectory, ".local", "share");
  return pathApi.join(dataHome, "clusteryourcodex", "controller.token");
}

function validateBearerToken(value: string): string {
  const token = value.trim();
  if (token.length < 32 || token.length > 256 || /\s/.test(token) || /[^\x21-\x7e]/.test(token)) {
    throw new TokenSourceError("token_invalid", "Controller token file is invalid");
  }
  return token;
}

export class FileBearerTokenSource implements BearerTokenSource {
  constructor(private readonly tokenFile = resolveControllerTokenFile()) {}

  async getToken(): Promise<string> {
    try {
      return validateBearerToken(await readFile(this.tokenFile, "utf8"));
    } catch (error) {
      if (error instanceof TokenSourceError) throw error;
      throw new TokenSourceError("token_unavailable", "Controller token file is unavailable");
    }
  }
}
