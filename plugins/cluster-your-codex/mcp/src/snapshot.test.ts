import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  MAX_SNAPSHOT_ARCHIVE_BYTES,
  packWorkspaceSnapshot,
  verifySnapshotArchive,
} from "./snapshot.js";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((path) => rm(path, { recursive: true, force: true })));
});

describe("workspace snapshot packer", () => {
  it("packs tracked and dirty files deterministically while enforcing the permanent denyset", async () => {
    const root = await temporaryDirectory("cyc-snapshot-workspace-");
    const output = await temporaryDirectory("cyc-snapshot-output-");
    await mkdir(join(root, "src"), { recursive: true });
    await mkdir(join(root, "node_modules", "dependency"), { recursive: true });
    await writeFile(join(root, "README.md"), "tracked\n");
    await writeFile(join(root, "src", "dirty.ts"), "export const dirty = true;\n");
    await writeFile(join(root, ".env"), "TOKEN=must-not-leak\n");
    await writeFile(join(root, "credentials.json"), '{"password":"must-not-leak"}\n');
    await writeFile(join(root, "private.pem"), "must-not-leak\n");
    await writeFile(join(root, "node_modules", "dependency", "index.js"), "must-not-leak\n");

    const first = await packWorkspaceSnapshot({ workspacePath: root, outputPath: join(output, "first.tar.zst") });
    await utimes(join(root, "README.md"), new Date(2_000_000), new Date(2_000_000));
    const second = await packWorkspaceSnapshot({ workspacePath: root, outputPath: join(output, "second.tar.zst") });

    expect(second.digest).toBe(first.digest);
    expect(second.sizeBytes).toBe(first.sizeBytes);
    expect(first.fileCount).toBe(2);
    const archive = await readFile(first.archivePath);
    expect(`sha256:${createHash("sha256").update(archive).digest("hex")}`).toBe(first.digest);
    expect(archive.length).toBe(first.sizeBytes);
    expect(first.sizeBytes).toBeGreaterThan(0);
    expect(first.sizeBytes).toBeLessThanOrEqual(MAX_SNAPSHOT_ARCHIVE_BYTES);

    const entries = readRawZstdTar(archive);
    expect([...entries.keys()]).toEqual(["README.md", "src/dirty.ts"]);
    expect(entries.get("src/dirty.ts")?.toString("utf8")).toBe("export const dirty = true;\n");
    expect(archive.includes(Buffer.from("must-not-leak"))).toBe(false);
  });

  it("applies caller include and deny patterns without weakening the permanent denyset", async () => {
    const root = await temporaryDirectory("cyc-snapshot-filter-");
    const output = await temporaryDirectory("cyc-snapshot-filter-output-");
    await mkdir(join(root, "src", "private"), { recursive: true });
    await mkdir(join(root, "docs"), { recursive: true });
    await writeFile(join(root, "src", "main.ts"), "main\n");
    await writeFile(join(root, "src", "private", "ignored.ts"), "private\n");
    await writeFile(join(root, "docs", "ignored.md"), "docs\n");
    await writeFile(join(root, "src", ".env.local"), "SECRET=denied\n");

    const packed = await packWorkspaceSnapshot({
      workspacePath: root,
      outputPath: join(output, "filtered.tar.zst"),
      include: ["src/**"],
      deny: ["src/private/**"],
    });

    const entries = readRawZstdTar(await readFile(packed.archivePath));
    expect([...entries.keys()]).toEqual(["src/main.ts"]);
    expect(packed.fileCount).toBe(1);
  });

  it("binds verification to the exact archive digest and size", async () => {
    const root = await temporaryDirectory("cyc-snapshot-verify-");
    const output = await temporaryDirectory("cyc-snapshot-verify-output-");
    await writeFile(join(root, "source.txt"), "exact bytes\n");
    const packed = await packWorkspaceSnapshot({ workspacePath: root, outputPath: join(output, "source.tar.zst") });

    await expect(verifySnapshotArchive(packed.archivePath, packed.digest, packed.sizeBytes)).resolves.toHaveLength(
      packed.sizeBytes,
    );
    await expect(verifySnapshotArchive(packed.archivePath, packed.digest, packed.sizeBytes + 1)).rejects.toThrow(
      /size does not match/,
    );
    await expect(
      verifySnapshotArchive(packed.archivePath, `sha256:${"f".repeat(64)}`, packed.sizeBytes),
    ).rejects.toThrow(/bytes do not match digest/);
  });
});

async function temporaryDirectory(prefix: string): Promise<string> {
  const path = await mkdtemp(join(tmpdir(), prefix));
  temporaryDirectories.push(path);
  return path;
}

function readRawZstdTar(archive: Buffer): Map<string, Buffer> {
  expect([...archive.subarray(0, 4)]).toEqual([0x28, 0xb5, 0x2f, 0xfd]);
  expect(archive[4]).toBe(0xa0);
  const declaredSize = archive.readUInt32LE(5);
  let offset = 9;
  const blocks: Buffer[] = [];
  for (;;) {
    const header = archive.readUIntLE(offset, 3);
    offset += 3;
    const last = (header & 1) === 1;
    const type = (header >> 1) & 0x3;
    const size = header >> 3;
    expect(type).toBe(0);
    blocks.push(archive.subarray(offset, offset + size));
    offset += size;
    if (last) break;
  }
  expect(offset).toBe(archive.length);
  const tar = Buffer.concat(blocks);
  expect(tar.length).toBe(declaredSize);
  return readTar(tar);
}

function readTar(tar: Buffer): Map<string, Buffer> {
  const entries = new Map<string, Buffer>();
  let offset = 0;
  let longName: string | undefined;
  while (offset + 512 <= tar.length) {
    const header = tar.subarray(offset, offset + 512);
    if (header.every((byte) => byte === 0)) break;
    const name = nullTerminated(header.subarray(0, 100));
    const prefix = nullTerminated(header.subarray(345, 500));
    const sizeText = nullTerminated(header.subarray(124, 136)).trim();
    const size = Number.parseInt(sizeText || "0", 8);
    const type = String.fromCharCode(header[156] ?? 0);
    offset += 512;
    const body = tar.subarray(offset, offset + size);
    offset += Math.ceil(size / 512) * 512;
    if (type === "L") {
      longName = nullTerminated(body);
      continue;
    }
    const path = longName ?? (prefix.length === 0 ? name : `${prefix}/${name}`);
    longName = undefined;
    entries.set(path, Buffer.from(body));
  }
  return entries;
}

function nullTerminated(value: Buffer): string {
  const end = value.indexOf(0);
  return value.subarray(0, end < 0 ? value.length : end).toString("utf8");
}
