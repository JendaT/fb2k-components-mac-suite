// Archive unpacking for `intake scan` (pre-resolve). Unpack goes to a sibling
// `<name>.unpacked/` dir; originals are kept until gc (doc 01).

import { existsSync, lstatSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { ext } from "./util.ts";

/**
 * Remove any symlink inside a freshly-unpacked tree. Archives from untrusted
 * sources can carry symlink entries that point outside the unpacked dir; a
 * later copy/walk that followed one would escape the release root. Music
 * releases never legitimately contain symlinks, so stripping them is safe.
 * Returns the number removed.
 */
function stripSymlinks(dir: string): number {
  let removed = 0;
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return 0;
  }
  for (const n of names) {
    const p = join(dir, n);
    let st;
    try {
      st = lstatSync(p);
    } catch {
      continue;
    }
    if (st.isSymbolicLink()) {
      rmSync(p, { force: true });
      removed++;
    } else if (st.isDirectory()) {
      removed += stripSymlinks(p);
    }
  }
  return removed;
}

export interface UnpackResult {
  archive: string; // absolute path of the archive
  target: string; // absolute path of the unpacked dir
  action: "unpacked" | "already_unpacked" | "tool_missing" | "failed";
  error?: string;
}

function toolFor(archiveExt: string): { cmd: string[]; probe: string } | null {
  switch (archiveExt) {
    case "zip":
      return { cmd: ["unzip", "-qq", "-o"], probe: "unzip" };
    case "7z":
    case "rar":
      return { cmd: ["7z", "x", "-y"], probe: "7z" };
    default:
      return null;
  }
}

export async function unpackArchive(archivePath: string, dryRun: boolean): Promise<UnpackResult> {
  const x = ext(archivePath);
  const target = archivePath.slice(0, -(x.length + 1)) + ".unpacked";
  if (existsSync(target)) return { archive: archivePath, target, action: "already_unpacked" };
  const tool = toolFor(x);
  if (!tool || Bun.which(tool.probe) === null)
    return { archive: archivePath, target, action: "tool_missing", error: `no tool for .${x}` };
  if (dryRun) return { archive: archivePath, target, action: "unpacked" };

  mkdirSync(target, { recursive: true });
  const args =
    x === "zip"
      ? [...tool.cmd, archivePath, "-d", target]
      : [...tool.cmd, `-o${target}`, archivePath];
  const proc = Bun.spawn(args, { stdout: "ignore", stderr: "pipe" });
  const code = await proc.exited;
  if (code !== 0) {
    const err = await new Response(proc.stderr).text();
    return { archive: archivePath, target, action: "failed", error: err.trim().slice(0, 200) };
  }
  stripSymlinks(target);
  return { archive: archivePath, target, action: "unpacked" };
}
