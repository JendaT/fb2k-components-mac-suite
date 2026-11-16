// Archive unpacking for `intake scan` (pre-resolve). Unpack goes to a sibling
// `<name>.unpacked/` dir; originals are kept until gc (doc 01).
//
// Extraction writes into the sibling `<name>.unpacked.partial/` and renames it
// to `<name>.unpacked/` only after the tool exits 0, so `<name>.unpacked/`
// exists only for a clean extraction. A failed run removes the partial dir; a
// crashed run leaves it behind, where walkDirs never enters it and the next
// scan removes it before retrying. The partial dir is a sibling, so the rename
// never crosses a volume.

import { existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, renameSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ext, PARTIAL_UNPACK_SUFFIX } from "./util.ts";
import {
  chooseCodePage, needsCodePage, readCentralDirectory, writeUtf8NamedCopy, type CentralDirectory, type CodePage,
} from "./zipnames.ts";

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
 * - zip: Info-ZIP unzip; `-P ""` gives it an (empty) password. (A zip
 *   with code-page names goes to 7-Zip instead, see zipCodePagePlan.)
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
      const sevenZip = findSevenZip();
      return sevenZip === null ? null : sevenZipArgv(sevenZip, archive, outDir);
    }
    default:
      return null;
  }
}

const findSevenZip = (): string | null => Bun.which("7zz") ?? Bun.which("7z");

const sevenZipArgv = (bin: string, archive: string, outDir: string): string[] => [
  bin, "x", "-y", "-bd", "-p", `-o${outDir}`, archive,
];

interface CodePagePlan {
  cd: CentralDirectory;
  cp: CodePage;
  sevenZip: string;
}

/**
 * A zip whose names are not all UTF-8-flagged or valid UTF-8 holds raw
 * Windows code-page bytes, which unzip does not decode (SMB and APFS refuse
 * what it writes) and 7-Zip on macOS does not either (it ignores `-mcp`).
 * So the names are decoded here with the code page chooseCodePage picks,
 * into a copy of the zip that carries them as flagged UTF-8, and 7-Zip
 * extracts that copy. Returns null for a zip that extracts as before: names
 * already UTF-8, or a central directory zipnames.ts does not read (ZIP64, a
 * split or damaged archive), which goes to unzip unchanged. Returns a
 * string (the error) when the names need a code page and no 7-Zip is on PATH.
 */
function zipCodePagePlan(archivePath: string): CodePagePlan | string | null {
  const cd = readCentralDirectory(archivePath);
  if (cd === null || !needsCodePage(cd)) return null;
  const { cp } = chooseCodePage(cd, archivePath);
  const sevenZip = findSevenZip();
  if (sevenZip === null) return `zip names are cp${cp}, not UTF-8: extracting them needs 7zz or 7z on PATH`;
  return { cd, cp, sevenZip };
}

export async function unpackArchive(archivePath: string, dryRun: boolean): Promise<UnpackResult> {
  const x = ext(archivePath);
  const stem = archivePath.slice(0, -(x.length + 1));
  const target = stem + ".unpacked";
  const partial = stem + PARTIAL_UNPACK_SUFFIX;
  if (existsSync(target)) return { archive: archivePath, target, action: "already_unpacked" };
  const codePage = x === "zip" ? zipCodePagePlan(archivePath) : null;
  if (typeof codePage === "string") return { archive: archivePath, target, action: "failed", error: codePage };
  const args = codePage === null ? extractArgv(x, archivePath, partial) : null;
  if (codePage === null && args === null)
    return { archive: archivePath, target, action: "tool_missing", error: `no tool for .${x}` };
  if (dryRun) return { archive: archivePath, target, action: "unpacked" };

  const failed = (error: string): UnpackResult => {
    try {
      rmSync(partial, { recursive: true, force: true });
    } catch {
      // left for the next scan, which removes it before retrying
    }
    return { archive: archivePath, target, action: "failed", error };
  };
  let copyDir: string | null = null; // temp dir of the UTF-8-named zip copy
  try {
    // A leftover from a run that died mid-extraction.
    rmSync(partial, { recursive: true, force: true });
    mkdirSync(partial, { recursive: true });
    let argv: string[];
    if (codePage !== null) {
      // Local temp dir, not the income volume: the copy is as large as the zip.
      copyDir = mkdtempSync(join(tmpdir(), "intake-zip-"));
      const copy = join(copyDir, "utf8-names.zip");
      writeUtf8NamedCopy(archivePath, copy, codePage.cd, codePage.cp);
      argv = sevenZipArgv(codePage.sevenZip, copy, partial);
    } else {
      argv = args!;
    }
    const proc = Bun.spawn(argv, { stdin: "ignore", stdout: "ignore", stderr: "pipe" });
    // Drain stderr while waiting: a tool that fills the pipe would block forever.
    const [code, err] = await Promise.all([proc.exited, new Response(proc.stderr).text()]);
    // Any non-zero exit is a failure, even when files appeared (7-Zip exits 1
    // or 2 after writing the members it could): the partial dir goes.
    if (code !== 0) return failed(err.trim().slice(0, 200) || `${argv[0]} exited ${code}`);
    stripSymlinks(partial);
    renameSync(partial, target);
  } catch (e) {
    return failed(e instanceof Error ? e.message : String(e));
  } finally {
    try {
      if (copyDir !== null) rmSync(copyDir, { recursive: true, force: true });
    } catch {
      // a leftover in the OS temp dir; nothing in income depends on it
    }
  }
  return { archive: archivePath, target, action: "unpacked" };
}
