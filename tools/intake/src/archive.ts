// Archive unpacking for `intake scan` (pre-resolve). Unpack goes to a sibling
// `<name>.unpacked/` dir; originals are kept until gc (doc 01).
//
// Extraction writes into the sibling `<name>.unpacked.partial/` and renames it
// to `<name>.unpacked/` only after the tool exits 0, so `<name>.unpacked/`
// exists only for a clean extraction. A failed run removes the partial dir; a
// crashed run leaves it behind, where walkDirs never enters it and the next
// scan removes it before retrying. The partial dir is a sibling, so the rename
// never crosses a volume.

import { existsSync, lstatSync, mkdirSync, readdirSync, renameSync, rmSync } from "node:fs";
import { join } from "node:path";
import { ext, PARTIAL_UNPACK_SUFFIX } from "./util.ts";

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

/**
 * Extraction argv for an archive, or null when no tool for it is on PATH.
 * Every tool runs non-interactively (stdin ignored, `-y` / `-o`) and gets a
 * password switch, so an encrypted archive fails at once ("Wrong password")
 * instead of prompting: without one, p7zip and unzip ask on /dev/tty and
 * hang a scan run from a terminal, and 7zz reads the password from stdin.
 * - zip: Info-ZIP unzip; `-P ""` gives it an (empty) password.
 * - rar, 7z: 7-Zip. `7zz` (current 7-Zip) is preferred over `7z` (p7zip,
 *   frozen at 16.02/17.x), which lacks newer format revisions, e.g. RAR 7's
 *   compression algorithm version 1 ("Unsupported Method"). For both, `-p`
 *   with an empty value is a defined (empty) password and never prompts.
 *   unrar is not used: in a real-data run it hung past 60 s with stdin closed.
 */
function extractArgv(archiveExt: string, archive: string, outDir: string): string[] | null {
  switch (archiveExt) {
    case "zip": {
      const unzip = Bun.which("unzip");
      return unzip === null ? null : [unzip, "-qq", "-o", "-P", "", archive, "-d", outDir];
    }
    case "7z":
    case "rar": {
      const sevenZip = Bun.which("7zz") ?? Bun.which("7z");
      return sevenZip === null ? null : [sevenZip, "x", "-y", "-bd", "-p", `-o${outDir}`, archive];
    }
    default:
      return null;
  }
}

export async function unpackArchive(archivePath: string, dryRun: boolean): Promise<UnpackResult> {
  const x = ext(archivePath);
  const stem = archivePath.slice(0, -(x.length + 1));
  const target = stem + ".unpacked";
  const partial = stem + PARTIAL_UNPACK_SUFFIX;
  if (existsSync(target)) return { archive: archivePath, target, action: "already_unpacked" };
  const args = extractArgv(x, archivePath, partial);
  if (args === null) return { archive: archivePath, target, action: "tool_missing", error: `no tool for .${x}` };
  if (dryRun) return { archive: archivePath, target, action: "unpacked" };

  const failed = (error: string): UnpackResult => {
    try {
      rmSync(partial, { recursive: true, force: true });
    } catch {
      // left for the next scan, which removes it before retrying
    }
    return { archive: archivePath, target, action: "failed", error };
  };
  try {
    // A leftover from a run that died mid-extraction.
    rmSync(partial, { recursive: true, force: true });
    mkdirSync(partial, { recursive: true });
    const proc = Bun.spawn(args, { stdin: "ignore", stdout: "ignore", stderr: "pipe" });
    // Drain stderr while waiting: a tool that fills the pipe would block forever.
    const [code, err] = await Promise.all([proc.exited, new Response(proc.stderr).text()]);
    // Any non-zero exit is a failure, even when files appeared (7-Zip exits 1
    // or 2 after writing the members it could): the partial dir goes.
    if (code !== 0) return failed(err.trim().slice(0, 200) || `${args[0]} exited ${code}`);
    stripSymlinks(partial);
    renameSync(partial, target);
  } catch (e) {
    return failed(e instanceof Error ? e.message : String(e));
  }
  return { archive: archivePath, target, action: "unpacked" };
}
