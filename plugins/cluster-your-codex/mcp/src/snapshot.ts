import { createHash, randomUUID } from "node:crypto";
import { link, lstat, mkdir, readFile, readdir, realpath, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve, sep } from "node:path";

export const SNAPSHOT_API_VERSION = "cyc.dev/snapshot/v1" as const;
export const SNAPSHOT_ARCHIVE_FORMAT = "tar+zstd" as const;
export const SNAPSHOT_MEDIA_TYPE = "application/vnd.cyc.snapshot.tar+zstd" as const;
export const MAX_SNAPSHOT_ARCHIVE_BYTES = 64 * 1024 * 1024;
const MAX_SNAPSHOT_ENTRIES = 10_000;
const MAX_SNAPSHOT_FILE_BYTES = 64 * 1024 * 1024;
const MAX_SNAPSHOT_EXPANDED_BYTES = 512 * 1024 * 1024;
const MAX_SNAPSHOT_PATH_BYTES = 1_024;
const TAR_BLOCK_BYTES = 512;
const ZSTD_RAW_BLOCK_BYTES = 128 * 1024;

export interface SnapshotDescriptor {
  apiVersion: typeof SNAPSHOT_API_VERSION;
  format: typeof SNAPSHOT_ARCHIVE_FORMAT;
  digest: `sha256:${string}`;
  sizeBytes: number;
}

export interface PackedSnapshot extends SnapshotDescriptor {
  archivePath: string;
  fileCount: number;
  expandedSizeBytes: number;
  skippedCount: number;
}

export interface PackWorkspaceOptions {
  workspacePath: string;
  outputPath?: string;
  include?: string[];
  deny?: string[];
}

interface SnapshotFile {
  absolutePath: string;
  portablePath: string;
  size: number;
  modifiedMs: number;
}

const DEFAULT_DENY_PATTERNS = [
  ".git",
  ".git/**",
  "**/.git",
  "**/.git/**",
  "node_modules",
  "node_modules/**",
  "**/node_modules",
  "**/node_modules/**",
  "target",
  "target/**",
  "**/target",
  "**/target/**",
  "dist",
  "dist/**",
  "**/dist",
  "**/dist/**",
  "build",
  "build/**",
  "**/build",
  "**/build/**",
  "out",
  "out/**",
  "**/out",
  "**/out/**",
  ".cache",
  ".cache/**",
  "**/.cache",
  "**/.cache/**",
  ".next",
  ".next/**",
  "**/.next",
  "**/.next/**",
  ".nuxt",
  ".nuxt/**",
  "**/.nuxt",
  "**/.nuxt/**",
  "__pycache__",
  "__pycache__/**",
  "**/__pycache__",
  "**/__pycache__/**",
  ".pytest_cache",
  ".pytest_cache/**",
  "**/.pytest_cache",
  "**/.pytest_cache/**",
  ".mypy_cache",
  ".mypy_cache/**",
  "**/.mypy_cache",
  "**/.mypy_cache/**",
  ".ruff_cache",
  ".ruff_cache/**",
  "**/.ruff_cache",
  "**/.ruff_cache/**",
  ".gradle",
  ".gradle/**",
  "**/.gradle",
  "**/.gradle/**",
  ".venv",
  ".venv/**",
  "**/.venv",
  "**/.venv/**",
  "venv",
  "venv/**",
  "**/venv",
  "**/venv/**",
  ".ssh",
  ".ssh/**",
  "**/.ssh",
  "**/.ssh/**",
  ".aws",
  ".aws/**",
  "**/.aws",
  "**/.aws/**",
  ".azure",
  ".azure/**",
  "**/.azure",
  "**/.azure/**",
  ".kube",
  ".kube/**",
  "**/.kube",
  "**/.kube/**",
  ".env",
  ".env.*",
  "**/.env",
  "**/.env.*",
  "*.pem",
  "**/*.pem",
  "*.key",
  "**/*.key",
  "*.p12",
  "**/*.p12",
  "*.pfx",
  "**/*.pfx",
  "*.jks",
  "**/*.jks",
  "keystore*",
  "**/keystore*",
  "keys.json",
  "**/keys.json",
  "keys.yaml",
  "**/keys.yaml",
  "keys.yml",
  "**/keys.yml",
  "id_rsa*",
  "**/id_rsa*",
  "id_ed25519*",
  "**/id_ed25519*",
  ".npmrc",
  "**/.npmrc",
  ".pypirc",
  "**/.pypirc",
  ".netrc",
  "**/.netrc",
] as const;

const SENSITIVE_BASENAME = /^(?:credentials?|secrets?|tokens?)(?:\..*)?$/i;

export async function packWorkspaceSnapshot(options: PackWorkspaceOptions): Promise<PackedSnapshot> {
  if (typeof options.workspacePath !== "string" || options.workspacePath.trim().length === 0) {
    throw new Error("workspacePath must be a non-empty path");
  }
  const requestedRoot = resolve(options.workspacePath);
  const root = await realpath(requestedRoot);
  const rootMetadata = await stat(root);
  if (!rootMetadata.isDirectory()) throw new Error("workspacePath must identify a directory");

  const include = validatePatterns(options.include ?? ["**"], "include");
  if (include.length === 0) throw new Error("include must contain at least one pattern");
  const customDeny = validatePatterns(options.deny ?? [], "deny");
  const deny = [...DEFAULT_DENY_PATTERNS, ...customDeny];
  const outputPath = options.outputPath === undefined ? undefined : resolve(options.outputPath);
  const files: SnapshotFile[] = [];
  const casePaths = new Map<string, string>();
  let skippedCount = 0;
  let expandedSizeBytes = 0;

  async function walk(directory: string): Promise<void> {
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((left, right) => Buffer.compare(Buffer.from(left.name), Buffer.from(right.name)));
    for (const entry of entries) {
      const absolutePath = join(directory, entry.name);
      const portablePath = toPortablePath(relative(root, absolutePath));
      if (outputPath !== undefined && samePath(absolutePath, outputPath)) {
        skippedCount += 1;
        continue;
      }
      if (isDenied(portablePath, deny)) {
        skippedCount += 1;
        continue;
      }
      validatePortablePath(portablePath, casePaths);
      if (entry.isSymbolicLink()) {
        throw new Error(`snapshot refuses symbolic links or reparse points: ${portablePath}`);
      }
      if (entry.isDirectory()) {
        await walk(absolutePath);
        continue;
      }
      if (!entry.isFile()) {
        throw new Error(`snapshot refuses non-regular filesystem entries: ${portablePath}`);
      }
      if (!matchesAny(portablePath, include)) {
        skippedCount += 1;
        continue;
      }
      const metadata = await lstat(absolutePath);
      if (!metadata.isFile() || metadata.isSymbolicLink()) {
        throw new Error(`snapshot entry changed type while scanning: ${portablePath}`);
      }
      if (metadata.size > MAX_SNAPSHOT_FILE_BYTES) {
        throw new Error(`snapshot file exceeds the 64 MiB per-file limit: ${portablePath}`);
      }
      expandedSizeBytes += metadata.size;
      if (expandedSizeBytes > MAX_SNAPSHOT_EXPANDED_BYTES) {
        throw new Error("snapshot workspace exceeds the 512 MiB expanded-size limit");
      }
      files.push({
        absolutePath,
        portablePath,
        size: metadata.size,
        modifiedMs: metadata.mtimeMs,
      });
      if (files.length > MAX_SNAPSHOT_ENTRIES) {
        throw new Error("snapshot workspace exceeds the 10000-entry limit");
      }
    }
  }

  await walk(root);
  files.sort((left, right) => Buffer.compare(Buffer.from(left.portablePath), Buffer.from(right.portablePath)));
  const tarParts: Buffer[] = [];
  for (const file of files) {
    const contents = await readFile(file.absolutePath);
    const after = await lstat(file.absolutePath);
    if (!after.isFile() || after.isSymbolicLink() || after.size !== file.size || after.mtimeMs !== file.modifiedMs) {
      throw new Error(`snapshot file changed while packing: ${file.portablePath}`);
    }
    appendTarFile(tarParts, file.portablePath, contents);
  }
  tarParts.push(Buffer.alloc(TAR_BLOCK_BYTES * 2));
  const archive = encodeRawZstdFrame(Buffer.concat(tarParts));
  if (archive.length < 1 || archive.length > MAX_SNAPSHOT_ARCHIVE_BYTES) {
    throw new Error("snapshot archive must be between 1 byte and 64 MiB");
  }
  const digestHex = createHash("sha256").update(archive).digest("hex");
  const digest = `sha256:${digestHex}` as const;
  const destination = outputPath ?? join(tmpdir(), "clusteryourcodex", "snapshots", `${digestHex}.tar.zst`);
  await installImmutableArchive(destination, archive, digestHex);

  return {
    apiVersion: SNAPSHOT_API_VERSION,
    format: SNAPSHOT_ARCHIVE_FORMAT,
    digest,
    sizeBytes: archive.length,
    archivePath: destination,
    fileCount: files.length,
    expandedSizeBytes,
    skippedCount,
  };
}

export async function verifySnapshotArchive(
  archivePath: string,
  expectedDigest: string,
  expectedSizeBytes: number,
): Promise<Buffer> {
  validateSnapshotDescriptor(expectedDigest, expectedSizeBytes);
  if (typeof archivePath !== "string" || archivePath.trim().length === 0) {
    throw new Error("archivePath must be a non-empty path");
  }
  const bytes = await readFile(resolve(archivePath));
  if (bytes.length !== expectedSizeBytes) throw new Error("snapshot archive size does not match sizeBytes");
  const observed = createHash("sha256").update(bytes).digest("hex");
  if (`sha256:${observed}` !== expectedDigest) throw new Error("snapshot archive bytes do not match digest");
  return bytes;
}

export function validateSnapshotDescriptor(digest: string, sizeBytes: number): asserts digest is `sha256:${string}` {
  if (!/^sha256:[a-f0-9]{64}$/.test(digest)) {
    throw new Error("snapshot digest must be sha256 followed by 64 lowercase hex digits");
  }
  if (!Number.isSafeInteger(sizeBytes) || sizeBytes < 1 || sizeBytes > MAX_SNAPSHOT_ARCHIVE_BYTES) {
    throw new Error("snapshot sizeBytes must be an integer from 1 through 67108864");
  }
}

function validatePatterns(patterns: string[], name: string): string[] {
  if (!Array.isArray(patterns) || patterns.length > 256) throw new Error(`${name} must be an array of at most 256 patterns`);
  return patterns.map((value, index) => {
    if (typeof value !== "string" || value.length < 1 || value.length > 1_024 || value.includes("\0")) {
      throw new Error(`${name}[${index}] must be a non-empty portable glob`);
    }
    const portable = value.replaceAll("\\", "/");
    if (isAbsolute(value) || portable.startsWith("/") || portable.split("/").includes("..")) {
      throw new Error(`${name}[${index}] must be relative and may not traverse parents`);
    }
    return portable.replace(/^\.\//, "");
  });
}

function isDenied(path: string, patterns: readonly string[]): boolean {
  const basename = path.slice(path.lastIndexOf("/") + 1);
  return SENSITIVE_BASENAME.test(basename) || matchesAny(path, patterns);
}

function matchesAny(path: string, patterns: readonly string[]): boolean {
  return patterns.some((pattern) => globToRegExp(pattern).test(path));
}

function globToRegExp(pattern: string): RegExp {
  let source = "^";
  for (let index = 0; index < pattern.length; index += 1) {
    const character = pattern[index];
    if (character === "*") {
      if (pattern[index + 1] === "*") {
        index += 1;
        if (pattern[index + 1] === "/") {
          index += 1;
          source += "(?:.*/)?";
        } else {
          source += ".*";
        }
      } else {
        source += "[^/]*";
      }
    } else if (character === "?") {
      source += "[^/]";
    } else {
      source += character?.replace(/[|\\{}()[\]^$+?.]/g, "\\$&") ?? "";
    }
  }
  return new RegExp(`${source}$`, "i");
}

function toPortablePath(value: string): string {
  return value.split(sep).join("/");
}

function validatePortablePath(path: string, casePaths: Map<string, string>): void {
  const bytes = Buffer.byteLength(path);
  if (bytes < 1 || bytes > MAX_SNAPSHOT_PATH_BYTES || /[\u0000-\u001f\u007f]/.test(path)) {
    throw new Error(`snapshot path is empty, oversized, or contains a control character: ${path}`);
  }
  let prefix = "";
  for (const segment of path.split("/")) {
    if (
      Buffer.byteLength(segment) > 255 ||
      segment.endsWith(".") ||
      segment.endsWith(" ") ||
      /[:*?"<>|]/.test(segment)
    ) {
      throw new Error(`snapshot path contains a non-portable component: ${path}`);
    }
    const stem = (segment.split(".")[0] ?? segment).toUpperCase();
    if (/^(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9]|LPT[1-9])$/.test(stem)) {
      throw new Error(`snapshot path contains a reserved filesystem device name: ${path}`);
    }
    if (segment.toLowerCase() === ".git") throw new Error("snapshot may not contain .git metadata");
    prefix = prefix.length === 0 ? segment : `${prefix}/${segment}`;
    const folded = prefix.toLowerCase();
    const existing = casePaths.get(folded);
    if (existing !== undefined && existing !== prefix) {
      throw new Error(`snapshot contains case-colliding paths: ${existing} and ${prefix}`);
    }
    casePaths.set(folded, prefix);
  }
}

function appendTarFile(parts: Buffer[], portablePath: string, contents: Buffer): void {
  const split = splitUstarPath(portablePath);
  if (split === undefined) {
    const longName = Buffer.concat([Buffer.from(portablePath, "utf8"), Buffer.from([0])]);
    parts.push(tarHeader("././@LongLink", "", longName.length, "L"), longName, tarPadding(longName.length));
    parts.push(tarHeader("snapshot-entry", "", contents.length, "0"), contents, tarPadding(contents.length));
    return;
  }
  parts.push(tarHeader(split.name, split.prefix, contents.length, "0"), contents, tarPadding(contents.length));
}

function splitUstarPath(path: string): { name: string; prefix: string } | undefined {
  if (Buffer.byteLength(path) <= 100) return { name: path, prefix: "" };
  for (let index = path.lastIndexOf("/"); index > 0; index = path.lastIndexOf("/", index - 1)) {
    const prefix = path.slice(0, index);
    const name = path.slice(index + 1);
    if (Buffer.byteLength(prefix) <= 155 && Buffer.byteLength(name) <= 100) return { name, prefix };
  }
  return undefined;
}

function tarHeader(name: string, prefix: string, size: number, type: "0" | "L"): Buffer {
  const header = Buffer.alloc(TAR_BLOCK_BYTES);
  writeTarText(header, 0, 100, name);
  writeTarOctal(header, 100, 8, 0o644);
  writeTarOctal(header, 108, 8, 0);
  writeTarOctal(header, 116, 8, 0);
  writeTarOctal(header, 124, 12, size);
  writeTarOctal(header, 136, 12, 0);
  header.fill(0x20, 148, 156);
  header.write(type, 156, 1, "ascii");
  header.write("ustar\0", 257, 6, "ascii");
  header.write("00", 263, 2, "ascii");
  writeTarText(header, 345, 155, prefix);
  const checksum = header.reduce((total, byte) => total + byte, 0);
  const encodedChecksum = checksum.toString(8).padStart(6, "0");
  header.write(encodedChecksum, 148, 6, "ascii");
  header[154] = 0;
  header[155] = 0x20;
  return header;
}

function writeTarText(header: Buffer, offset: number, length: number, value: string): void {
  const encoded = Buffer.from(value, "utf8");
  if (encoded.length > length) throw new Error("snapshot path cannot be represented in tar metadata");
  encoded.copy(header, offset);
}

function writeTarOctal(header: Buffer, offset: number, length: number, value: number): void {
  const encoded = value.toString(8).padStart(length - 1, "0");
  if (encoded.length >= length) throw new Error("snapshot value cannot be represented in tar metadata");
  header.write(encoded, offset, length - 1, "ascii");
  header[offset + length - 1] = 0;
}

function tarPadding(length: number): Buffer {
  const padding = (TAR_BLOCK_BYTES - (length % TAR_BLOCK_BYTES)) % TAR_BLOCK_BYTES;
  return Buffer.alloc(padding);
}

function encodeRawZstdFrame(contents: Buffer): Buffer {
  if (contents.length > 0xffff_ffff) throw new Error("snapshot tar stream is too large for its Zstandard frame");
  const header = Buffer.alloc(9);
  header.set([0x28, 0xb5, 0x2f, 0xfd], 0);
  header[4] = 0xa0; // Single segment plus a four-byte frame content size.
  header.writeUInt32LE(contents.length, 5);
  const blocks: Buffer[] = [header];
  for (let offset = 0; offset < contents.length; offset += ZSTD_RAW_BLOCK_BYTES) {
    const end = Math.min(contents.length, offset + ZSTD_RAW_BLOCK_BYTES);
    const block = contents.subarray(offset, end);
    const last = end === contents.length ? 1 : 0;
    const blockHeaderValue = (block.length << 3) | last;
    const blockHeader = Buffer.alloc(3);
    blockHeader.writeUIntLE(blockHeaderValue, 0, 3);
    blocks.push(blockHeader, block);
  }
  return Buffer.concat(blocks);
}

async function installImmutableArchive(destination: string, contents: Buffer, digestHex: string): Promise<void> {
  await mkdir(dirname(destination), { recursive: true });
  try {
    const existing = await readFile(destination);
    const existingDigest = createHash("sha256").update(existing).digest("hex");
    if (existing.length === contents.length && existingDigest === digestHex) return;
    throw new Error("snapshot output path already contains different bytes");
  } catch (error) {
    if (!isNotFound(error)) throw error;
  }

  const temporary = `${destination}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporary, contents, { flag: "wx", mode: 0o600 });
    await link(temporary, destination);
    await rm(temporary, { force: true });
  } catch (error) {
    await rm(temporary, { force: true }).catch(() => undefined);
    if (!isAlreadyExists(error)) throw error;
    const existing = await readFile(destination);
    const existingDigest = createHash("sha256").update(existing).digest("hex");
    if (existing.length !== contents.length || existingDigest !== digestHex) {
      throw new Error("snapshot output path appeared with different bytes");
    }
  }
}

function samePath(left: string, right: string): boolean {
  return process.platform === "win32" ? left.toLowerCase() === right.toLowerCase() : left === right;
}

function isNotFound(error: unknown): boolean {
  return error instanceof Error && "code" in error && error.code === "ENOENT";
}

function isAlreadyExists(error: unknown): boolean {
  return error instanceof Error && "code" in error && (error.code === "EEXIST" || error.code === "EPERM");
}
